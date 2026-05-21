#!/usr/bin/env python3
"""
Guaicaramo Control — Gateway Meshtastic ↔ Airtable.

Escucha mensajes en la red mesh y los traduce a operaciones en Airtable:

  CONSULTA|<requestId>|<cedula>|<placa>
      → busca la placa en la tabla `Placas` y responde
        RESPUESTA|<requestId>|APROBADO|<conductor>
        RESPUESTA|<requestId>|NO_APROBADO
        RESPUESTA|<requestId>|ERROR|<motivo>

  ENTRADA_V|<cedula>|<placa>|<aprobadoPor>
      → inserta fila nueva en `Registros` con tipo=ENTRADA.

  SALIDA_V|<placa>
      → busca el último registro de la placa con salida vacía y le pone exit_time.

  REGISTRO_MANUAL|<status>|<cedula>|<placa>|<supervisor>|<comment>
      → inserta fila en `Registros` con la aprobación manual (status puede ser
        APROBADO, NEGADO o PENDIENTE).

El gateway sólo procesa mensajes que llegan como DM (destino == este nodo).

Config: ver .env.example y README.md.
"""

from __future__ import annotations

import argparse
import logging
import os
import signal
import sys
import time
import traceback
import urllib.parse
from datetime import date, datetime, timezone
from typing import Any

import requests

try:
    from dotenv import load_dotenv
except ImportError:  # python-dotenv es opcional
    def load_dotenv(*_args, **_kwargs):  # type: ignore[no-redef]
        return False


load_dotenv()

# ---------- Config ----------

AIRTABLE_API_TOKEN = os.getenv("AIRTABLE_API_TOKEN", "").strip()
AIRTABLE_BASE_ID = os.getenv("AIRTABLE_BASE_ID", "").strip()
AIRTABLE_PLACAS_TABLE = os.getenv("AIRTABLE_PLACAS_TABLE", "Placas").strip()
AIRTABLE_REGISTROS_TABLE = os.getenv("AIRTABLE_REGISTROS_TABLE", "Registros").strip()
AIRTABLE_PERSONAS_TABLE = os.getenv("AIRTABLE_PERSONAS_TABLE", "Personas").strip()

# Conexión al nodo Meshtastic. Una de las tres debe estar definida.
MESHTASTIC_SERIAL = os.getenv("MESHTASTIC_SERIAL", "").strip()  # ej: /dev/ttyUSB0
MESHTASTIC_TCP = os.getenv("MESHTASTIC_TCP", "").strip()         # ej: 192.168.1.50
MESHTASTIC_BLE = os.getenv("MESHTASTIC_BLE", "").strip()         # ej: AA:BB:CC:DD:EE:FF

REQUEST_TIMEOUT_SECONDS = int(os.getenv("AIRTABLE_TIMEOUT", "15"))

# ---------- Logging ----------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("guaicaramo-gateway")


# ---------- Airtable client ----------


class AirtableError(RuntimeError):
    """Error al hablar con Airtable."""


def _airtable_headers() -> dict[str, str]:
    if not AIRTABLE_API_TOKEN:
        raise AirtableError("AIRTABLE_API_TOKEN no configurado")
    return {
        "Authorization": f"Bearer {AIRTABLE_API_TOKEN}",
        "Content-Type": "application/json",
    }


def _airtable_url(table: str) -> str:
    if not AIRTABLE_BASE_ID:
        raise AirtableError("AIRTABLE_BASE_ID no configurado")
    table_encoded = urllib.parse.quote(table)
    return f"https://api.airtable.com/v0/{AIRTABLE_BASE_ID}/{table_encoded}"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _is_expired(vence: str) -> bool:
    """Devuelve True si el valor de Airtable `vence` ya pasó.

    Soporta dos formatos:
      - dateTime ISO 8601 con tz, ej "2026-05-21T18:00:00.000Z" o "...+00:00".
        → comparación al segundo contra now(UTC).
      - date "YYYY-MM-DD" (campo viejo tipo date).
        → vigente hasta el FIN del día local (Bogotá). Lo convertimos a fin
          de día UTC para que coincida con cómo Airtable mostraría 23:59 local.

    Si el valor es inválido, retorna False (no rechazar por dato corrupto).
    """
    try:
        # dateTime con tz
        if "T" in vence:
            iso = vence.replace("Z", "+00:00")
            dt = datetime.fromisoformat(iso)
            if dt.tzinfo is None:
                # Si por algún motivo viene sin tz, asumir UTC.
                dt = dt.replace(tzinfo=timezone.utc)
            return dt < datetime.now(timezone.utc)
        # Solo date — vigente todo el día (UTC end-of-day para evitar romper
        # registros viejos durante la transición).
        d = date.fromisoformat(vence[:10])
        end_of_day_utc = datetime(d.year, d.month, d.day, 23, 59, 59,
                                  tzinfo=timezone.utc)
        return end_of_day_utc < datetime.now(timezone.utc)
    except (ValueError, TypeError):
        log.warning("Fecha de vencimiento inválida: %r", vence)
        return False


def airtable_find_placa(placa: str) -> dict[str, Any] | None:
    """Busca una placa exacta (case-insensitive) en la tabla Placas."""
    placa_upper = placa.upper().strip()
    # Airtable formula: UPPER({placa}) = 'XYZ123'
    formula = f"UPPER({{placa}}) = '{placa_upper}'"
    params = {"filterByFormula": formula, "maxRecords": 1}
    resp = requests.get(
        _airtable_url(AIRTABLE_PLACAS_TABLE),
        headers=_airtable_headers(),
        params=params,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code != 200:
        raise AirtableError(f"GET Placas HTTP {resp.status_code}: {resp.text[:200]}")
    records = resp.json().get("records", [])
    return records[0] if records else None


def airtable_find_persona(cedula: str) -> dict[str, Any] | None:
    """Busca una cédula exacta en la tabla Personas."""
    cedula_clean = cedula.strip()
    formula = f"{{cedula}} = '{cedula_clean}'"
    params = {"filterByFormula": formula, "maxRecords": 1}
    resp = requests.get(
        _airtable_url(AIRTABLE_PERSONAS_TABLE),
        headers=_airtable_headers(),
        params=params,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code != 200:
        raise AirtableError(
            f"GET Personas HTTP {resp.status_code}: {resp.text[:200]}"
        )
    records = resp.json().get("records", [])
    return records[0] if records else None


def airtable_create_registro(fields: dict[str, Any]) -> str:
    resp = requests.post(
        _airtable_url(AIRTABLE_REGISTROS_TABLE),
        headers=_airtable_headers(),
        json={"fields": fields},
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code not in (200, 201):
        raise AirtableError(
            f"POST Registros HTTP {resp.status_code}: {resp.text[:200]}"
        )
    return resp.json().get("id", "")


def airtable_update_registro(record_id: str, fields: dict[str, Any]) -> None:
    url = f"{_airtable_url(AIRTABLE_REGISTROS_TABLE)}/{record_id}"
    resp = requests.patch(
        url,
        headers=_airtable_headers(),
        json={"fields": fields},
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code != 200:
        raise AirtableError(
            f"PATCH Registros HTTP {resp.status_code}: {resp.text[:200]}"
        )


def airtable_find_active_entry(placa: str) -> dict[str, Any] | None:
    """Busca el registro de ENTRADA vehícular más reciente sin salida."""
    placa_upper = placa.upper().strip()
    formula = (
        "AND("
        f"UPPER({{placa}}) = '{placa_upper}',"
        "{tipo} = 'ENTRADA',"
        "{categoria} = 'VEHICULO',"
        "{exit_time} = BLANK()"
        ")"
    )
    params = {
        "filterByFormula": formula,
        "maxRecords": 1,
        "sort[0][field]": "entry_time",
        "sort[0][direction]": "desc",
    }
    resp = requests.get(
        _airtable_url(AIRTABLE_REGISTROS_TABLE),
        headers=_airtable_headers(),
        params=params,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code != 200:
        raise AirtableError(
            f"GET Registros HTTP {resp.status_code}: {resp.text[:200]}"
        )
    records = resp.json().get("records", [])
    return records[0] if records else None


def airtable_find_active_person(cedula: str) -> dict[str, Any] | None:
    """Busca el registro de ENTRADA peatonal más reciente sin salida."""
    cedula_clean = cedula.strip()
    formula = (
        "AND("
        f"{{cedula}} = '{cedula_clean}',"
        "{tipo} = 'ENTRADA',"
        "{categoria} = 'PEATON',"
        "{exit_time} = BLANK()"
        ")"
    )
    params = {
        "filterByFormula": formula,
        "maxRecords": 1,
        "sort[0][field]": "entry_time",
        "sort[0][direction]": "desc",
    }
    resp = requests.get(
        _airtable_url(AIRTABLE_REGISTROS_TABLE),
        headers=_airtable_headers(),
        params=params,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code != 200:
        raise AirtableError(
            f"GET Registros HTTP {resp.status_code}: {resp.text[:200]}"
        )
    records = resp.json().get("records", [])
    return records[0] if records else None


# ---------- Meshtastic helpers ----------


def send_text(interface, destination_node: int, text: str) -> None:
    """Envía un texto como DM a un nodo. Maneja excepciones del SDK."""
    try:
        interface.sendText(text, destinationId=destination_node, wantAck=False)
        log.info("📤 → %s: %s", _node_hex(destination_node), text)
    except Exception as e:
        log.error("✗ Error enviando a %s: %s", _node_hex(destination_node), e)


def _node_hex(node_num: int) -> str:
    return f"!{node_num & 0xFFFFFFFF:08x}"


# ---------- Handlers de protocolo ----------


def handle_consulta(interface, from_num: int, parts: list[str]) -> None:
    """CONSULTA|<requestId>|<cedula>|<placa>."""
    if len(parts) < 4:
        log.warning("CONSULTA formato inválido: %s", parts)
        return
    request_id, cedula, placa = parts[1], parts[2], parts[3]
    log.info(
        "🚗 CONSULTA req=%s placa=%s cedula=%s de %s",
        request_id, placa, cedula, _node_hex(from_num),
    )

    try:
        record = airtable_find_placa(placa)
        if record is None:
            send_text(interface, from_num, f"RESPUESTA|{request_id}|NO_APROBADO")
            return

        fields = record.get("fields", {})
        authorized = bool(fields.get("autorizado"))
        if not authorized:
            send_text(interface, from_num, f"RESPUESTA|{request_id}|NO_APROBADO")
            return

        # Verificar vencimiento si existe.
        # Airtable retorna dateTime en ISO 8601 con tz (UTC):
        #   "2026-05-21T18:00:00.000Z" o "2026-05-21" si el campo es solo date.
        vence = fields.get("vence")
        if vence and _is_expired(vence):
            log.info("Placa %s vencida (%s).", placa, vence)
            send_text(interface, from_num, f"RESPUESTA|{request_id}|NO_APROBADO")
            return

        conductor = (fields.get("conductor") or "").strip()
        send_text(
            interface,
            from_num,
            f"RESPUESTA|{request_id}|APROBADO|{conductor}",
        )

    except AirtableError as e:
        log.error("AirtableError en CONSULTA: %s", e)
        send_text(interface, from_num, f"RESPUESTA|{request_id}|ERROR|{str(e)[:50]}")
    except Exception:
        log.error("Excepción en CONSULTA:\n%s", traceback.format_exc())
        send_text(interface, from_num, f"RESPUESTA|{request_id}|ERROR|interno")


def handle_entrada(interface, from_num: int, parts: list[str]) -> None:
    """ENTRADA_V|<cedula>|<placa>|<aprobadoPor>."""
    if len(parts) < 4:
        log.warning("ENTRADA_V formato inválido: %s", parts)
        return
    _, cedula, placa, approved_by = parts[0], parts[1], parts[2].upper(), parts[3]
    log.info("🚗 ENTRADA_V placa=%s aprobadoPor=%s", placa, approved_by)

    try:
        record_id = airtable_create_registro(
            {
                "tipo": "ENTRADA",
                "categoria": "VEHICULO",
                "cedula": cedula,
                "placa": placa,
                "entry_time": _now_iso(),
                "approved_by": approved_by,
                "status": "APROBADO",
                "nodo_origen": _node_hex(from_num),
            }
        )
        log.info("✓ Entrada creada (record %s)", record_id)
    except AirtableError as e:
        log.error("AirtableError en ENTRADA_V: %s", e)
    except Exception:
        log.error("Excepción en ENTRADA_V:\n%s", traceback.format_exc())


def handle_salida(interface, from_num: int, parts: list[str]) -> None:
    """SALIDA_V|<placa>."""
    if len(parts) < 2:
        log.warning("SALIDA_V formato inválido: %s", parts)
        return
    placa = parts[1].upper()
    log.info("🚪 SALIDA_V placa=%s", placa)

    try:
        record = airtable_find_active_entry(placa)
        if record is None:
            log.warning("No hay entrada activa para %s — creando registro de salida huérfano.", placa)
            airtable_create_registro(
                {
                    "tipo": "SALIDA",
                    "categoria": "VEHICULO",
                    "placa": placa,
                    "exit_time": _now_iso(),
                    "nodo_origen": _node_hex(from_num),
                    "status": "SALIDA_SIN_ENTRADA",
                }
            )
            return
        airtable_update_registro(record["id"], {"exit_time": _now_iso()})
        log.info("✓ Salida actualizada (record %s)", record["id"])
    except AirtableError as e:
        log.error("AirtableError en SALIDA_V: %s", e)
    except Exception:
        log.error("Excepción en SALIDA_V:\n%s", traceback.format_exc())


def handle_registro_manual(interface, from_num: int, parts: list[str]) -> None:
    """REGISTRO_MANUAL|<status>|<cedula>|<placa>|<supervisor>|<comment>."""
    if len(parts) < 6:
        log.warning("REGISTRO_MANUAL formato inválido: %s", parts)
        return
    status = parts[1]
    cedula = parts[2]
    placa = parts[3].upper()
    supervisor = parts[4]
    comment = parts[5] if len(parts) > 5 else ""

    log.info(
        "🚗 REGISTRO_MANUAL placa=%s status=%s supervisor=%s",
        placa, status, supervisor,
    )

    try:
        fields = {
            "tipo": "ENTRADA" if status == "APROBADO" else "MANUAL",
            "categoria": "VEHICULO",
            "cedula": cedula,
            "placa": placa,
            "approved_by": supervisor,
            "status": status,
            "supervisor": supervisor,
            "comment": comment,
            "nodo_origen": _node_hex(from_num),
        }
        if status == "APROBADO":
            fields["entry_time"] = _now_iso()
        else:
            fields["rejected_time"] = _now_iso()
        record_id = airtable_create_registro(fields)
        log.info("✓ Registro manual creado (record %s)", record_id)
    except AirtableError as e:
        log.error("AirtableError en REGISTRO_MANUAL: %s", e)
    except Exception:
        log.error("Excepción en REGISTRO_MANUAL:\n%s", traceback.format_exc())


# ---------- Handlers de peatones ----------


def handle_consulta_persona(interface, from_num: int, parts: list[str]) -> None:
    """CONSULTA_P|<requestId>|<cedula>."""
    if len(parts) < 3:
        log.warning("CONSULTA_P formato inválido: %s", parts)
        return
    request_id, cedula = parts[1], parts[2]
    log.info(
        "🚶 CONSULTA_P req=%s cedula=%s de %s",
        request_id, cedula, _node_hex(from_num),
    )

    try:
        record = airtable_find_persona(cedula)
        if record is None:
            send_text(interface, from_num, f"RESPUESTA_P|{request_id}|NO_APROBADO")
            return

        fields = record.get("fields", {})
        if not bool(fields.get("autorizado")):
            send_text(interface, from_num, f"RESPUESTA_P|{request_id}|NO_APROBADO")
            return

        vence = fields.get("vence")
        if vence and _is_expired(vence):
            log.info("Persona %s vencida (%s).", cedula, vence)
            send_text(interface, from_num,
                      f"RESPUESTA_P|{request_id}|NO_APROBADO")
            return

        nombre = (fields.get("nombre") or "").strip()
        send_text(interface, from_num,
                  f"RESPUESTA_P|{request_id}|APROBADO|{nombre}")

    except AirtableError as e:
        log.error("AirtableError en CONSULTA_P: %s", e)
        send_text(interface, from_num,
                  f"RESPUESTA_P|{request_id}|ERROR|{str(e)[:50]}")
    except Exception:
        log.error("Excepción en CONSULTA_P:\n%s", traceback.format_exc())
        send_text(interface, from_num, f"RESPUESTA_P|{request_id}|ERROR|interno")


def handle_entrada_persona(interface, from_num: int, parts: list[str]) -> None:
    """ENTRADA_P|<cedula>|<aprobadoPor>."""
    if len(parts) < 3:
        log.warning("ENTRADA_P formato inválido: %s", parts)
        return
    _, cedula, approved_by = parts[0], parts[1], parts[2]
    log.info("🚶 ENTRADA_P cedula=%s aprobadoPor=%s", cedula, approved_by)

    try:
        record_id = airtable_create_registro(
            {
                "tipo": "ENTRADA",
                "categoria": "PEATON",
                "cedula": cedula,
                "entry_time": _now_iso(),
                "approved_by": approved_by,
                "status": "APROBADO",
                "nodo_origen": _node_hex(from_num),
            }
        )
        log.info("✓ Entrada peatonal creada (record %s)", record_id)
    except AirtableError as e:
        log.error("AirtableError en ENTRADA_P: %s", e)
    except Exception:
        log.error("Excepción en ENTRADA_P:\n%s", traceback.format_exc())


def handle_salida_persona(interface, from_num: int, parts: list[str]) -> None:
    """SALIDA_P|<cedula>."""
    if len(parts) < 2:
        log.warning("SALIDA_P formato inválido: %s", parts)
        return
    cedula = parts[1]
    log.info("🚪 SALIDA_P cedula=%s", cedula)

    try:
        record = airtable_find_active_person(cedula)
        if record is None:
            log.warning("No hay entrada peatonal activa para CC %s.", cedula)
            airtable_create_registro(
                {
                    "tipo": "SALIDA",
                    "categoria": "PEATON",
                    "cedula": cedula,
                    "exit_time": _now_iso(),
                    "nodo_origen": _node_hex(from_num),
                    "status": "SALIDA_SIN_ENTRADA",
                }
            )
            return
        airtable_update_registro(record["id"], {"exit_time": _now_iso()})
        log.info("✓ Salida peatonal actualizada (record %s)", record["id"])
    except AirtableError as e:
        log.error("AirtableError en SALIDA_P: %s", e)
    except Exception:
        log.error("Excepción en SALIDA_P:\n%s", traceback.format_exc())


def handle_registro_manual_persona(interface, from_num: int, parts: list[str]) -> None:
    """REGISTRO_MANUAL_P|<status>|<cedula>|<supervisor>|<comment>."""
    if len(parts) < 5:
        log.warning("REGISTRO_MANUAL_P formato inválido: %s", parts)
        return
    status = parts[1]
    cedula = parts[2]
    supervisor = parts[3]
    comment = parts[4] if len(parts) > 4 else ""

    log.info(
        "🚶 REGISTRO_MANUAL_P cedula=%s status=%s supervisor=%s",
        cedula, status, supervisor,
    )

    try:
        fields = {
            "tipo": "ENTRADA" if status == "APROBADO" else "MANUAL",
            "categoria": "PEATON",
            "cedula": cedula,
            "approved_by": supervisor,
            "status": status,
            "supervisor": supervisor,
            "comment": comment,
            "nodo_origen": _node_hex(from_num),
        }
        if status == "APROBADO":
            fields["entry_time"] = _now_iso()
        else:
            fields["rejected_time"] = _now_iso()
        record_id = airtable_create_registro(fields)
        log.info("✓ Registro manual peatonal creado (record %s)", record_id)
    except AirtableError as e:
        log.error("AirtableError en REGISTRO_MANUAL_P: %s", e)
    except Exception:
        log.error("Excepción en REGISTRO_MANUAL_P:\n%s", traceback.format_exc())


# Mapa prefijo → handler. on_receive hace exact match con dict.get(prefix),
# no startswith, así que el orden no importa y no hay colisión entre
# CONSULTA y CONSULTA_P (son keys distintas).
HANDLERS = {
    "CONSULTA_P": handle_consulta_persona,
    "ENTRADA_P": handle_entrada_persona,
    "SALIDA_P": handle_salida_persona,
    "REGISTRO_MANUAL_P": handle_registro_manual_persona,
    "CONSULTA": handle_consulta,
    "ENTRADA_V": handle_entrada,
    "SALIDA_V": handle_salida,
    "REGISTRO_MANUAL": handle_registro_manual,
}


# ---------- Recepción de paquetes ----------


def on_receive(packet: dict[str, Any], interface) -> None:
    """Callback registrado en pub.subscribe('meshtastic.receive', ...)."""
    try:
        decoded = packet.get("decoded") or {}
        if decoded.get("portnum") != "TEXT_MESSAGE_APP":
            return

        # `text` ya viene decodificado en utf-8 por la lib.
        text = decoded.get("text")
        if not text:
            payload = decoded.get("payload")
            if isinstance(payload, (bytes, bytearray)):
                text = payload.decode("utf-8", errors="replace")
        if not text:
            return

        from_num = packet.get("from")
        to_num = packet.get("to")
        my_num = interface.localNode.nodeNum if interface.localNode else None

        # Solo procesar DMs dirigidos a este nodo.
        if my_num is not None and to_num != my_num:
            return

        prefix = text.split("|", 1)[0]
        handler = HANDLERS.get(prefix)
        if handler is None:
            return

        log.info("📨 ← %s: %s", _node_hex(from_num or 0), text)
        parts = text.split("|")
        handler(interface, from_num, parts)
    except Exception:
        log.error("Excepción en on_receive:\n%s", traceback.format_exc())


def on_connection(interface, topic=None) -> None:  # noqa: ARG001
    try:
        my_num = interface.localNode.nodeNum if interface.localNode else None
        log.info("📡 Conectado al nodo Meshtastic (nodeNum=%s)", _node_hex(my_num or 0))
    except Exception:
        log.info("📡 Conectado al nodo Meshtastic.")


# ---------- Bootstrap ----------


def build_interface():
    """Crea el interface según las env vars."""
    if MESHTASTIC_SERIAL:
        log.info("🔌 Abriendo Serial: %s", MESHTASTIC_SERIAL)
        from meshtastic.serial_interface import SerialInterface
        return SerialInterface(devPath=MESHTASTIC_SERIAL)
    if MESHTASTIC_TCP:
        log.info("🌐 Abriendo TCP: %s", MESHTASTIC_TCP)
        from meshtastic.tcp_interface import TCPInterface
        return TCPInterface(hostname=MESHTASTIC_TCP)
    if MESHTASTIC_BLE:
        log.info("🦷 Abriendo BLE: %s", MESHTASTIC_BLE)
        from meshtastic.ble_interface import BLEInterface
        return BLEInterface(address=MESHTASTIC_BLE)
    raise SystemExit(
        "Configura MESHTASTIC_SERIAL, MESHTASTIC_TCP o MESHTASTIC_BLE en .env"
    )


def precheck() -> None:
    """Valida config crítica y avisa antes de arrancar."""
    missing = []
    if not AIRTABLE_API_TOKEN:
        missing.append("AIRTABLE_API_TOKEN")
    if not AIRTABLE_BASE_ID:
        missing.append("AIRTABLE_BASE_ID")
    if missing:
        log.warning(
            "⚠️ Faltan variables: %s. CONSULTA responderá ERROR hasta configurarlas.",
            ", ".join(missing),
        )
    else:
        # Ping para verificar credenciales / nombre de tabla.
        try:
            resp = requests.get(
                _airtable_url(AIRTABLE_PLACAS_TABLE),
                headers=_airtable_headers(),
                params={"maxRecords": 1},
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
            if resp.status_code == 200:
                log.info("✅ Airtable OK — tabla Placas accesible.")
            else:
                log.warning(
                    "⚠️ Airtable respondió %d en tabla %s: %s",
                    resp.status_code, AIRTABLE_PLACAS_TABLE, resp.text[:200],
                )
        except Exception as e:
            log.warning("⚠️ No se pudo verificar Airtable: %s", e)


def run_simulator() -> None:
    """Modo --simulate: lee mensajes desde stdin para probar handlers sin radio."""
    log.info("🧪 Modo simulador. Formato por línea: <from_hex> <mensaje>")
    log.info("Ejemplo: !7c1a5974 CONSULTA|123|999|ABC123")

    class _FakeInterface:
        class _LocalNode:
            nodeNum = 0x49b54674
        localNode = _LocalNode()

        def sendText(self, text, destinationId=None, wantAck=False):  # noqa: ARG002
            log.info("[SIM] sendText(%s, dst=%s)", text, _node_hex(destinationId or 0))

    iface = _FakeInterface()
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                from_hex, text = line.split(" ", 1)
            except ValueError:
                log.warning("Línea inválida: %s", line)
                continue
            try:
                from_num = int(from_hex.lstrip("!"), 16)
            except ValueError:
                log.warning("from_hex inválido: %s", from_hex)
                continue
            packet = {
                "from": from_num,
                "to": iface.localNode.nodeNum,
                "decoded": {"portnum": "TEXT_MESSAGE_APP", "text": text},
            }
            on_receive(packet, iface)
    except KeyboardInterrupt:
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Guaicaramo Control Gateway")
    parser.add_argument(
        "--simulate",
        action="store_true",
        help="Modo simulación: lee mensajes desde stdin sin abrir radio.",
    )
    args = parser.parse_args()

    log.info("🚦 Guaicaramo Control Gateway — iniciando.")
    precheck()

    if args.simulate:
        run_simulator()
        return 0

    try:
        from pubsub import pub
    except ImportError:
        log.error(
            "Falta `pypubsub` (viene con el paquete `meshtastic`). pip install meshtastic"
        )
        return 1

    interface = build_interface()
    pub.subscribe(on_receive, "meshtastic.receive")
    pub.subscribe(on_connection, "meshtastic.connection.established")

    stop = False

    def _shutdown(signum, frame):  # noqa: ARG001
        nonlocal stop
        log.info("🛑 Señal %s recibida — cerrando.", signum)
        stop = True

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    log.info("🟢 Listo. Esperando mensajes…")
    try:
        while not stop:
            time.sleep(1)
    finally:
        try:
            interface.close()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
