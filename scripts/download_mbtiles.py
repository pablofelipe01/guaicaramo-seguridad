#!/usr/bin/env python3
"""
Descarga tiles OSM para un bounding box y los empaqueta en un archivo MBTiles
compatible con flutter_map_mbtiles.

Default: BBox que cubre Guaicaramo (centro 4.4665, -73.0587), zoom 10-16.

Uso típico:
    python scripts/download_mbtiles.py
    python scripts/download_mbtiles.py --zoom-max 17     # más detalle, más tiempo
    python scripts/download_mbtiles.py --resume          # reanudar si se cortó

Respeta la Tile Usage Policy de OSM (1 req/s, User-Agent identificable).
"""

from __future__ import annotations

import argparse
import math
import sqlite3
import sys
import time
from pathlib import Path

import requests

# ---------- Config por defecto ----------

# BBox por defecto cubre la mesh de Guaicaramo (ver Google Earth)
DEFAULT_LAT_MIN = 4.40
DEFAULT_LAT_MAX = 4.55
DEFAULT_LON_MIN = -73.20
DEFAULT_LON_MAX = -72.95

DEFAULT_ZOOM_MIN = 10
DEFAULT_ZOOM_MAX = 16

DEFAULT_OUTPUT = Path(__file__).resolve().parent.parent / "assets" / "maps" / "guaicaramo.mbtiles"

# Tile server. OSM Mapnik standard. Identificarse en User-Agent es obligatorio.
TILE_URL_TEMPLATE = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
USER_AGENT = "guaicaramo-control/0.1 (https://github.com/pablofelipe01/guaicaramo-seguridad)"

# Rate limit — OSM pide bulk downloading respetuoso.
REQUEST_INTERVAL_SECONDS = 1.0


# ---------- Helpers ----------


def deg_to_tile(lat: float, lon: float, zoom: int) -> tuple[int, int]:
    """Convierte lat/lon a coordenadas de tile (slippy map)."""
    n = 2.0 ** zoom
    x = int((lon + 180.0) / 360.0 * n)
    lat_rad = math.radians(lat)
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    return x, y


def tile_range(lat_min: float, lat_max: float, lon_min: float, lon_max: float, zoom: int):
    """Devuelve (x_min, x_max, y_min, y_max) — inclusive."""
    x_min, y_max = deg_to_tile(lat_min, lon_min, zoom)
    x_max, y_min = deg_to_tile(lat_max, lon_max, zoom)
    return min(x_min, x_max), max(x_min, x_max), min(y_min, y_max), max(y_min, y_max)


def tms_y(y: int, zoom: int) -> int:
    """Convierte y slippy (XYZ) a y TMS (MBTiles usa TMS, origen abajo)."""
    return (2 ** zoom) - 1 - y


def init_mbtiles(path: Path, bbox: tuple[float, float, float, float],
                 zoom_min: int, zoom_max: int) -> sqlite3.Connection:
    """Crea el archivo SQLite con el esquema MBTiles 1.3."""
    path.parent.mkdir(parents=True, exist_ok=True)
    new_file = not path.exists()
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS metadata (name TEXT, value TEXT);
        CREATE TABLE IF NOT EXISTS tiles (
            zoom_level INTEGER,
            tile_column INTEGER,
            tile_row INTEGER,
            tile_data BLOB,
            PRIMARY KEY (zoom_level, tile_column, tile_row)
        );
        CREATE INDEX IF NOT EXISTS tile_index
            ON tiles (zoom_level, tile_column, tile_row);
        """
    )
    if new_file:
        lat_min, lat_max, lon_min, lon_max = bbox
        meta = {
            "name": "guaicaramo",
            "type": "baselayer",
            "version": "1",
            "description": "Guaicaramo mesh — OSM tiles offline",
            "format": "png",
            "bounds": f"{lon_min},{lat_min},{lon_max},{lat_max}",
            "minzoom": str(zoom_min),
            "maxzoom": str(zoom_max),
            "attribution": "© OpenStreetMap contributors",
        }
        conn.executemany(
            "INSERT INTO metadata (name, value) VALUES (?, ?)",
            meta.items(),
        )
        conn.commit()
    return conn


def tile_exists(conn: sqlite3.Connection, z: int, x: int, y_tms: int) -> bool:
    cur = conn.execute(
        "SELECT 1 FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1",
        (z, x, y_tms),
    )
    return cur.fetchone() is not None


def insert_tile(conn: sqlite3.Connection, z: int, x: int, y_tms: int, data: bytes) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO tiles VALUES (?, ?, ?, ?)",
        (z, x, y_tms, data),
    )


def total_tile_count(bbox: tuple[float, float, float, float],
                     zoom_min: int, zoom_max: int) -> int:
    lat_min, lat_max, lon_min, lon_max = bbox
    total = 0
    for z in range(zoom_min, zoom_max + 1):
        x_min, x_max, y_min, y_max = tile_range(lat_min, lat_max, lon_min, lon_max, z)
        total += (x_max - x_min + 1) * (y_max - y_min + 1)
    return total


# ---------- Descarga ----------


def download_tile(session: requests.Session, z: int, x: int, y: int) -> bytes | None:
    url = TILE_URL_TEMPLATE.format(z=z, x=x, y=y)
    try:
        resp = session.get(url, timeout=30)
    except requests.RequestException as e:
        print(f"  ✗ {z}/{x}/{y}: {e}", file=sys.stderr)
        return None
    if resp.status_code == 200:
        return resp.content
    if resp.status_code == 429:
        # Rate limited. Back off.
        print(f"  ⏳ {z}/{x}/{y}: 429 — pausa 30s", file=sys.stderr)
        time.sleep(30)
        return download_tile(session, z, x, y)
    print(f"  ✗ {z}/{x}/{y}: HTTP {resp.status_code}", file=sys.stderr)
    return None


def main() -> int:
    p = argparse.ArgumentParser(description="Descarga tiles OSM → MBTiles.")
    p.add_argument("--lat-min", type=float, default=DEFAULT_LAT_MIN)
    p.add_argument("--lat-max", type=float, default=DEFAULT_LAT_MAX)
    p.add_argument("--lon-min", type=float, default=DEFAULT_LON_MIN)
    p.add_argument("--lon-max", type=float, default=DEFAULT_LON_MAX)
    p.add_argument("--zoom-min", type=int, default=DEFAULT_ZOOM_MIN)
    p.add_argument("--zoom-max", type=int, default=DEFAULT_ZOOM_MAX)
    p.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    p.add_argument(
        "--rate", type=float, default=REQUEST_INTERVAL_SECONDS,
        help="Segundos entre requests (default 1.0).",
    )
    p.add_argument(
        "--resume", action="store_true",
        help="Si el .mbtiles existe, saltar tiles ya descargados.",
    )
    args = p.parse_args()

    bbox = (args.lat_min, args.lat_max, args.lon_min, args.lon_max)
    total = total_tile_count(bbox, args.zoom_min, args.zoom_max)
    est_minutes = total * args.rate / 60

    print(f"📍 BBox: {args.lat_min},{args.lon_min} → {args.lat_max},{args.lon_max}")
    print(f"🔍 Zoom: {args.zoom_min}–{args.zoom_max}")
    print(f"🧮 Tiles esperados: {total}")
    print(f"⏱  Tiempo estimado: {est_minutes:.1f} min a {args.rate}s/req")
    print(f"📂 Salida: {args.output}")
    print()

    conn = init_mbtiles(args.output, bbox, args.zoom_min, args.zoom_max)
    session = requests.Session()
    session.headers.update({"User-Agent": USER_AGENT})

    downloaded = 0
    skipped = 0
    failed = 0
    last_commit = time.time()

    try:
        for z in range(args.zoom_min, args.zoom_max + 1):
            x_min, x_max, y_min, y_max = tile_range(*bbox, z)
            z_count = (x_max - x_min + 1) * (y_max - y_min + 1)
            print(f"━━━ Zoom {z}: {z_count} tiles ({x_min}..{x_max}, {y_min}..{y_max}) ━━━")

            for x in range(x_min, x_max + 1):
                for y in range(y_min, y_max + 1):
                    y_t = tms_y(y, z)

                    if args.resume and tile_exists(conn, z, x, y_t):
                        skipped += 1
                        continue

                    data = download_tile(session, z, x, y)
                    if data is None:
                        failed += 1
                        continue

                    insert_tile(conn, z, x, y_t, data)
                    downloaded += 1

                    # Commit periódico (no perder progreso si Ctrl+C).
                    if time.time() - last_commit > 30:
                        conn.commit()
                        last_commit = time.time()
                        progress = (downloaded + skipped + failed) / total * 100
                        print(
                            f"  📊 {downloaded + skipped + failed}/{total} "
                            f"({progress:.1f}%) — ok:{downloaded} skip:{skipped} fail:{failed}"
                        )

                    time.sleep(args.rate)
    except KeyboardInterrupt:
        print("\n🛑 Interrumpido — guardando progreso…")
    finally:
        conn.commit()
        conn.close()

    print()
    print(f"✅ Descargados: {downloaded}")
    print(f"⏭  Saltados:    {skipped}")
    print(f"❌ Fallidos:    {failed}")
    print(f"📦 Archivo:     {args.output}")
    return 0 if failed == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
