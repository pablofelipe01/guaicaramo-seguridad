"""mesh_probe_tx.py — emisor de traceroutes hacia los sitios fijos de la mesh.

Vive aparte de gateway.py a propósito. gateway.py atiende la portería: este
módulo no puede tumbarlo ni frenarlo, así que:

  - Todo corre en un hilo daemon propio, envuelto en try/except.
  - NO se usa interface.sendTraceRoute(): esa función llama waitForTraceRoute()
    y bloquea el hilo hasta 20s × (hopLimit+1). Aquí se manda el paquete con
    sendData(onResponse=...) y la respuesta llega por el hilo lector de
    meshtastic, sin bloquear a nadie.
  - Los sondeos salen con prioridad BACKGROUND (10), muy por debajo de la
    DEFAULT (64) del tráfico de portería: si el canal está ocupado atendiendo
    una placa, el traceroute espera.
  - NO se habla con Supabase. Se escribe un JSONL local que mesh_probe.py
    (timer de guaica-health) drena. El gateway no abre conexiones de red
    nuevas y un Supabase lento no puede colgarlo.

Apagado por defecto: MESH_PROBE_ENABLED=1 para encenderlo.
"""
from __future__ import annotations

import json
import logging
import os
import threading
import time
from datetime import datetime, timezone

log = logging.getLogger(__name__)

# ---------- configuración ----------
ENABLED = os.getenv("MESH_PROBE_ENABLED", "0") == "1"
# node_ids de los sitios fijos, coma-separados. Sin esto no se sondea nada.
SITES = [s.strip() for s in os.getenv("MESH_PROBE_SITES", "").split(",") if s.strip()]
# Cada cuánto se vuelve a sondear un sitio que respondió bien.
INTERVAL_MIN = int(os.getenv("MESH_PROBE_INTERVAL_MIN", "60"))
# Separación entre sondeos consecutivos. Nunca los 7 en ráfaga: se colisionan
# entre sí y con sus propias respuestas, y te inventas fallos que no existen.
STAGGER_SEC = int(os.getenv("MESH_PROBE_STAGGER_SEC", "480"))
# Si el nodo se anunció hace menos que esto, ya sabemos que está vivo: no se
# gasta aire. El estado en ese caso lo resuelve mesh_last_heard() en la vista.
SKIP_IF_HEARD_MIN = int(os.getenv("MESH_PROBE_SKIP_IF_HEARD_MIN", "20"))
# Cuánto se espera la respuesta antes de darla por perdida.
TIMEOUT_SEC = int(os.getenv("MESH_PROBE_TIMEOUT_SEC", "90"))
HOP_LIMIT = int(os.getenv("MESH_PROBE_HOP_LIMIT", "3"))
# Prioridad del paquete. BACKGROUND(10) cede el paso al tráfico de portería,
# pero es una desviación de la implementación de referencia de la librería, que
# usa DEFAULT(64). Configurable para poder aislarla si los sondeos fallan.
PRIORITY = os.getenv("MESH_PROBE_PRIORITY", "DEFAULT").upper()
# Tras un fallo se reintenta rápido para confirmar la caída en ~10 min en vez
# de esperar el intervalo completo.
RETRY_SEC = int(os.getenv("MESH_PROBE_RETRY_SEC", "300"))
MAX_RETRIES = int(os.getenv("MESH_PROBE_MAX_RETRIES", "3"))
JSONL_PATH = os.getenv(
    "MESH_PROBE_JSONL", "/home/pfac/guaica-health/state/mesh_probes.jsonl"
).strip()
# Tope de seguridad del archivo por si el timer que lo drena se muere.
JSONL_MAX_BYTES = int(os.getenv("MESH_PROBE_JSONL_MAX_BYTES", str(8 * 1024 * 1024)))
TICK_SEC = 15

UNK_SNR = -128  # el firmware manda esto cuando no conoce el SNR del salto


# ---------- helpers ----------
def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat()


def node_id_to_num(node_id: str) -> int | None:
    """'!0407f118' -> 67629336."""
    try:
        return int(node_id.lstrip("!"), 16)
    except (ValueError, AttributeError):
        return None


BROADCAST_NUM = 0xFFFFFFFF  # el firmware lo usa como "no sé quién relevó"


def num_to_node_id(num) -> str | None:
    try:
        n = int(num)
    except (ValueError, TypeError):
        return None
    if n == BROADCAST_NUM:
        return None  # relevo desconocido: hueco en la ruta, no un nodo
    return f"!{n:08x}"


class _Probe:
    """Un sondeo en vuelo."""

    __slots__ = ("node_id", "sent_at", "trigger", "deadline")

    def __init__(self, node_id: str, trigger: str) -> None:
        self.node_id = node_id
        self.sent_at = _now()
        self.trigger = trigger
        self.deadline = time.time() + TIMEOUT_SEC


class MeshProber:
    def __init__(self, conn_holder) -> None:
        self._conn = conn_holder
        self._lock = threading.Lock()
        self._pending: dict[int, _Probe] = {}       # packet_id -> _Probe
        self._next_due: dict[str, float] = {}       # node_id -> epoch
        self._failures: dict[str, int] = {}         # node_id -> fallos seguidos
        self._last_sent = 0.0
        # Arranque escalonado: el primer barrido se reparte a lo largo del
        # intervalo en vez de salir todo junto al iniciar el servicio.
        now = time.time()
        for i, node_id in enumerate(SITES):
            self._next_due[node_id] = now + 30 + i * STAGGER_SEC
            self._failures[node_id] = 0

    # ----- escritura del JSONL -----
    def _write(self, record: dict) -> None:
        if not JSONL_PATH:
            return
        try:
            os.makedirs(os.path.dirname(JSONL_PATH), exist_ok=True)
            if (
                os.path.exists(JSONL_PATH)
                and os.path.getsize(JSONL_PATH) > JSONL_MAX_BYTES
            ):
                log.warning(
                    "mesh_probe: %s superó %d bytes — ¿está corriendo el timer "
                    "que lo drena? Descarto el sondeo.",
                    JSONL_PATH,
                    JSONL_MAX_BYTES,
                )
                return
            line = json.dumps(record, ensure_ascii=False, default=str)
            with self._lock:
                with open(JSONL_PATH, "a", encoding="utf-8") as fh:
                    fh.write(line + "\n")
                    fh.flush()
        except Exception as e:  # noqa: BLE001
            log.debug("mesh_probe: no pude escribir el JSONL: %s", e)

    def _gateway_node_id(self) -> str | None:
        try:
            iface = self._conn.get()
            local = getattr(iface, "localNode", None)
            return num_to_node_id(getattr(local, "nodeNum", None))
        except Exception:  # noqa: BLE001
            return None

    # ----- parseo de la respuesta -----
    @staticmethod
    def _hops(route: list, snrs: list, origin: str | None, dest: str | None) -> list:
        """Convierte (route, snrTowards) en filas de traceroute_hops.

        snrs trae len(route)+1 entradas: el destino final agrega la suya. Si no
        cuadra, el firmware mandó algo inconsistente y el SNR de esa dirección
        entero deja de ser fiable -> se guarda la ruta sin SNR.
        """
        valid = len(snrs) == len(route) + 1
        chain = [origin] + [num_to_node_id(n) for n in route] + [dest]
        hops = []
        for i in range(len(chain) - 1):
            snr = None
            if valid:
                raw = snrs[i]
                # El firmware manda cuartos de dB, y -128 significa "no sé".
                if raw != UNK_SNR:
                    snr = raw / 4.0
            hops.append(
                {
                    "hop_index": i,
                    "from_node_id": chain[i],
                    "to_node_id": chain[i + 1],
                    "snr_db": snr,
                }
            )
        return hops

    def _on_response(self, packet: dict) -> None:
        """Callback del hilo lector de meshtastic. No debe lanzar jamás."""
        try:
            packet_id = (packet.get("decoded") or {}).get("requestId")
            with self._lock:
                probe = self._pending.pop(packet_id, None)
            if probe is None:
                return  # respuesta tardía: ya la dimos por timeout

            from google.protobuf.json_format import MessageToDict
            from meshtastic.protobuf import mesh_pb2, portnums_pb2

            decoded = packet.get("decoded") or {}
            portnum = decoded.get("portnum")
            es_traceroute = portnum in (
                "TRACEROUTE_APP", portnums_pb2.PortNum.TRACEROUTE_APP
            )
            if not es_traceroute:
                # NAK de routing u otra respuesta: el nodo NO fue alcanzado.
                razon = (decoded.get("routing") or {}).get("errorReason") or portnum
                self._fallo(probe, "error", f"respuesta {razon}")
                return

            rd = mesh_pb2.RouteDiscovery()
            rd.ParseFromString(packet["decoded"]["payload"])
            d = MessageToDict(rd)

            # La ida va del gateway (destino de esta respuesta) al nodo sondeado
            # (origen de esta respuesta). La vuelta, al revés.
            us = num_to_node_id(packet.get("to"))
            them = num_to_node_id(packet.get("from"))
            route = d.get("route", []) or []
            route_back = d.get("routeBack", []) or []
            snr_t = d.get("snrTowards", []) or []
            snr_b = d.get("snrBack", []) or []

            hops = [
                dict(h, direction="towards")
                for h in self._hops(route, snr_t, us, them)
            ]
            back_valid = "hopStart" in packet and len(snr_b) == len(route_back) + 1
            if back_valid:
                hops += [
                    dict(h, direction="back")
                    for h in self._hops(route_back, snr_b, them, us)
                ]

            now = _now()
            rtt = int((now - probe.sent_at).total_seconds() * 1000)
            snr_final = None
            if len(snr_t) == len(route) + 1 and snr_t[-1] != UNK_SNR:
                snr_final = snr_t[-1] / 4.0

            fwd = [num_to_node_id(n) for n in route]
            bwd = [num_to_node_id(n) for n in route_back]
            record = {
                "node_id": probe.node_id,
                "requested_at": _iso(probe.sent_at),
                "responded_at": _iso(now),
                "status": "ok",
                "rtt_ms": rtt,
                "hop_limit": HOP_LIMIT,
                "hops_towards": len(route),
                "hops_back": len(route_back) if back_valid else None,
                "asymmetric": (fwd != list(reversed(bwd))) if back_valid else None,
                "snr_final_db": snr_final,
                "route_text": " --> ".join([us or "?"] + fwd + [them or "?"]),
                "trigger": probe.trigger,
                "gateway_node_id": self._gateway_node_id(),
                "error": None,
                "hops": hops,
            }
            self._write(record)

            with self._lock:
                self._failures[probe.node_id] = 0
                self._next_due[probe.node_id] = time.time() + INTERVAL_MIN * 60
            log.info(
                "🛰️  traceroute %s OK — %d saltos, %d ms.",
                probe.node_id,
                len(route),
                rtt,
            )
        except Exception as e:  # noqa: BLE001
            log.debug("mesh_probe: fallo procesando respuesta: %s", e)

    def _fallo(self, probe: "_Probe", status: str, detalle: str) -> None:
        """Registra un sondeo fallido y reprograma el reintento."""
        now = time.time()
        with self._lock:
            fallos = self._failures.get(probe.node_id, 0) + 1
            self._failures[probe.node_id] = fallos
            espera = RETRY_SEC if fallos < MAX_RETRIES else INTERVAL_MIN * 60
            self._next_due[probe.node_id] = now + espera
        self._write(
            {
                "node_id": probe.node_id,
                "requested_at": _iso(probe.sent_at),
                "responded_at": _iso(_now()) if status == "error" else None,
                "status": status,
                "rtt_ms": None,
                "hop_limit": HOP_LIMIT,
                "hops_towards": None,
                "hops_back": None,
                "asymmetric": None,
                "snr_final_db": None,
                "route_text": None,
                "trigger": probe.trigger,
                "gateway_node_id": self._gateway_node_id(),
                "error": f"{detalle} (fallo {fallos})",
                "hops": [],
            }
        )
        log.warning(
            "🛰️❌ traceroute %s %s — %s (fallo %d/%d).",
            probe.node_id, status, detalle, fallos, MAX_RETRIES,
        )

    # ----- envío -----
    def _heard_recently(self, node_id: str) -> bool:
        try:
            iface = self._conn.get()
            node = (getattr(iface, "nodes", None) or {}).get(node_id)
            last = (node or {}).get("lastHeard")
            if not last:
                return False
            return (time.time() - last) < SKIP_IF_HEARD_MIN * 60
        except Exception:  # noqa: BLE001
            return False

    def _send(self, node_id: str, trigger: str) -> None:
        iface = self._conn.get()
        if iface is None:
            return  # radio caído / reconectando
        from meshtastic.protobuf import mesh_pb2, portnums_pb2

        packet = iface.sendData(
            mesh_pb2.RouteDiscovery(),
            destinationId=node_id,
            portNum=portnums_pb2.PortNum.TRACEROUTE_APP,
            wantResponse=True,
            onResponse=self._on_response,
            hopLimit=HOP_LIMIT,
            priority=getattr(
                mesh_pb2.MeshPacket.Priority, PRIORITY,
                mesh_pb2.MeshPacket.Priority.DEFAULT,
            ),
        )
        with self._lock:
            self._pending[packet.id] = _Probe(node_id, trigger)
            self._last_sent = time.time()
        log.info(
            "🛰️→ traceroute a %s (%s, id=%s, prio=%s, hopLimit=%d).",
            node_id, trigger, packet.id, PRIORITY, HOP_LIMIT,
        )

    def _expire(self) -> None:
        """Marca como timeout los sondeos cuya respuesta nunca llegó."""
        now = time.time()
        with self._lock:
            vencidos = [pid for pid, p in self._pending.items() if p.deadline < now]
            probes = [self._pending.pop(pid) for pid in vencidos]
        for probe in probes:
            self._fallo(probe, "timeout", f"sin respuesta en {TIMEOUT_SEC}s")

    def _tick(self) -> None:
        self._expire()
        now = time.time()
        # Un sondeo a la vez, separados por STAGGER_SEC.
        if now - self._last_sent < STAGGER_SEC:
            return
        with self._lock:
            vencidos = [n for n in SITES if self._next_due.get(n, 0) <= now]
            # El más atrasado primero.
            vencidos.sort(key=lambda n: self._next_due.get(n, 0))
        if not vencidos:
            return
        node_id = vencidos[0]

        if self._heard_recently(node_id):
            # Vivo y confirmado sin gastar aire.
            with self._lock:
                self._failures[node_id] = 0
                self._next_due[node_id] = now + INTERVAL_MIN * 60
            log.debug("mesh_probe: %s se oyó hace poco, salto el sondeo.", node_id)
            return

        trigger = "reintento" if self._failures.get(node_id, 0) else "heartbeat"
        self._send(node_id, trigger)

    def loop(self, stop_event: threading.Event) -> None:
        log.info(
            "🛰️  Emisor de traceroutes activo — %d sitios, cada %d min, "
            "uno cada %ds.",
            len(SITES),
            INTERVAL_MIN,
            STAGGER_SEC,
        )
        while not stop_event.wait(TICK_SEC):
            try:
                self._tick()
            except Exception as e:  # noqa: BLE001
                # Jamás debe tumbar el gateway.
                log.error("mesh_probe: excepción en el ciclo: %s", e)


def start(conn_holder, stop_event: threading.Event):
    """Arranca el emisor si está habilitado. Devuelve el hilo, o None."""
    if not ENABLED:
        log.info("🛰️  Emisor de traceroutes apagado (MESH_PROBE_ENABLED=0).")
        return None
    if not SITES:
        log.warning("🛰️  MESH_PROBE_ENABLED=1 pero MESH_PROBE_SITES vacío — no arranco.")
        return None
    prober = MeshProber(conn_holder)
    thread = threading.Thread(
        target=prober.loop, args=(stop_event,), name="mesh-prober", daemon=True
    )
    thread.start()
    return thread
