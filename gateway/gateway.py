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

  SOLICITUD_V|<cedula>|<placa>|<comment>
  SOLICITUD_P|<cedula>|<nombre>|<comment>
  SOLICITUD_F|<cedula>|<comment>
      → visitante NO registrado: crea una fila PENDIENTE en la tabla maestra
        (Placas / Personas / FinDeSemana) sin autorizar. Alguien la aprueba
        luego en Airtable y la siguiente consulta ya devuelve APROBADO.

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
AIRTABLE_ITEMS_TABLE = os.getenv("AIRTABLE_ITEMS_TABLE", "Items").strip()
AIRTABLE_FINDESEMANA_TABLE = os.getenv(
    "AIRTABLE_FINDESEMANA_TABLE", "FinDeSemana"
).strip()

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


def _format_acompanantes(parts_slice: list[str]) -> str:
    """Toma una lista de 8 elementos (cc1, nom1, cc2, nom2, ...) y devuelve
    un texto multilínea para guardar en Airtable.

    Ignora pares con CC vacía. Formato por línea:
      - "CC - Nombre"  si hay nombre
      - "CC"           si solo hay CC
    """
    lines = []
    for i in range(0, min(len(parts_slice), 8), 2):
        cc = parts_slice[i].strip() if i < len(parts_slice) else ""
        if not cc:
            continue
        nombre = parts_slice[i + 1].strip() if i + 1 < len(parts_slice) else ""
        if nombre:
            lines.append(f"{cc} - {nombre}")
        else:
            lines.append(cc)
    return "\n".join(lines)


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


def airtable_find_findesemana(cedula: str) -> dict[str, Any] | None:
    """Busca una cédula exacta en la tabla FinDeSemana."""
    cedula_clean = cedula.strip()
    formula = f"{{cedula}} = '{cedula_clean}'"
    params = {"filterByFormula": formula, "maxRecords": 1}
    resp = requests.get(
        _airtable_url(AIRTABLE_FINDESEMANA_TABLE),
        headers=_airtable_headers(),
        params=params,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code != 200:
        raise AirtableError(
            f"GET FinDeSemana HTTP {resp.status_code}: {resp.text[:200]}"
        )
    records = resp.json().get("records", [])
    return records[0] if records else None


def airtable_find_active_findesemana(cedula: str) -> dict[str, Any] | None:
    """Busca el último Registro de entrada fin-de-semana sin salida."""
    cedula_clean = cedula.strip()
    formula = (
        "AND("
        f"{{cedula}} = '{cedula_clean}',"
        "{tipo} = 'ENTRADA',"
        "{categoria} = 'FIN_DE_SEMANA',"
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


def airtable_create_record(table: str, fields: dict[str, Any]) -> str:
    """Crea una fila en cualquier tabla. typecast=True permite que Airtable
    cree opciones de singleSelect al vuelo (ej: estado='PENDIENTE')."""
    resp = requests.post(
        _airtable_url(table),
        headers=_airtable_headers(),
        json={"fields": fields, "typecast": True},
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code not in (200, 201):
        raise AirtableError(
            f"POST {table} HTTP {resp.status_code}: {resp.text[:200]}"
        )
    return resp.json().get("id", "")


def airtable_update_record(table: str, record_id: str, fields: dict[str, Any]) -> None:
    """Actualiza una fila en cualquier tabla."""
    url = f"{_airtable_url(table)}/{record_id}"
    resp = requests.patch(
        url,
        headers=_airtable_headers(),
        json={"fields": fields, "typecast": True},
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code != 200:
        raise AirtableError(
            f"PATCH {table} HTTP {resp.status_code}: {resp.text[:200]}"
        )


def airtable_create_registro(fields: dict[str, Any]) -> str:
    # typecast=true permite que Airtable cree nuevas opciones de singleSelect
    # al vuelo (ej: categoria='FIN_DE_SEMANA' que no estaba pre-definida).
    resp = requests.post(
        _airtable_url(AIRTABLE_REGISTROS_TABLE),
        headers=_airtable_headers(),
        json={"fields": fields, "typecast": True},
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
    """Envía un texto como DM a un nodo.

    wantAck=True hace que el stack Meshtastic reintente hasta 3 veces si el
    destino no acusa recibo dentro del timeout. Sin esto, una pérdida puntual
    de paquete deja al portero esperando para siempre (hasta su timeout de 30s).
    """
    try:
        interface.sendText(text, destinationId=destination_node, wantAck=True)
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
    """ENTRADA_V|<cedula>|<placa>|<aprobadoPor>[|<a1cc>|<a1nom>|<a2cc>|<a2nom>|<a3cc>|<a3nom>|<a4cc>|<a4nom>]

    Las 8 partes finales (acompañantes) son opcionales — formatos viejos
    sin acompañantes (4 partes) siguen funcionando.
    """
    if len(parts) < 4:
        log.warning("ENTRADA_V formato inválido: %s", parts)
        return
    _, cedula, placa, approved_by = parts[0], parts[1], parts[2].upper(), parts[3]
    acompanantes_text = _format_acompanantes(parts[4:12])
    log.info(
        "🚗 ENTRADA_V placa=%s aprobadoPor=%s%s",
        placa,
        approved_by,
        f" +acomp({acompanantes_text.count(chr(10)) + 1 if acompanantes_text else 0})"
        if acompanantes_text else "",
    )

    try:
        fields = {
            "tipo": "ENTRADA",
            "categoria": "VEHICULO",
            "cedula": cedula,
            "placa": placa,
            "entry_time": _now_iso(),
            "approved_by": approved_by,
            "status": "APROBADO",
            "nodo_origen": _node_hex(from_num),
        }
        if acompanantes_text:
            fields["acompanantes"] = acompanantes_text
        record_id = airtable_create_registro(fields)
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
    """REGISTRO_MANUAL|<status>|<cedula>|<placa>|<supervisor>|<comment>[|<a1cc>|<a1nom>|...|<a4nom>]

    Las 8 partes finales (acompañantes) son opcionales.
    """
    if len(parts) < 6:
        log.warning("REGISTRO_MANUAL formato inválido: %s", parts)
        return
    status = parts[1]
    cedula = parts[2]
    placa = parts[3].upper()
    supervisor = parts[4]
    comment = parts[5] if len(parts) > 5 else ""
    acompanantes_text = _format_acompanantes(parts[6:14])

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
        if acompanantes_text:
            fields["acompanantes"] = acompanantes_text
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


# ---------- Handlers de fin de semana ----------


def handle_consulta_findesemana(interface, from_num: int, parts: list[str]) -> None:
    """CONSULTA_F|<requestId>|<cedula>.

    Busca en tabla FinDeSemana. Si CC existe → APROBADO con nombre y área.
    Si no → NO_APROBADO. El campo `estado` controla solicitudes pendientes:
    vacío (filas históricas) o AUTORIZADO → vale; PENDIENTE/RECHAZADO → no.
    """
    if len(parts) < 3:
        log.warning("CONSULTA_F formato inválido: %s", parts)
        return
    request_id, cedula = parts[1], parts[2]
    log.info(
        "🗓️ CONSULTA_F req=%s cedula=%s de %s",
        request_id, cedula, _node_hex(from_num),
    )

    try:
        record = airtable_find_findesemana(cedula)
        if record is None:
            send_text(interface, from_num,
                      f"RESPUESTA_F|{request_id}|NO_APROBADO")
            return
        f = record.get("fields", {})
        estado = (f.get("estado") or "").strip().upper()
        if estado in ("PENDIENTE", "RECHAZADO"):
            log.info("FinDeSemana %s en estado %s → NO_APROBADO.", cedula, estado)
            send_text(interface, from_num,
                      f"RESPUESTA_F|{request_id}|NO_APROBADO")
            return
        nombre = _truncate(f.get("nombre", ""), 40)
        area = _truncate(f.get("area", ""), 30)
        send_text(
            interface, from_num,
            f"RESPUESTA_F|{request_id}|APROBADO|{nombre}|{area}",
        )
    except AirtableError as e:
        log.error("AirtableError en CONSULTA_F: %s", e)
        send_text(interface, from_num,
                  f"RESPUESTA_F|{request_id}|ERROR|{str(e)[:50]}")
    except Exception:
        log.error("Excepción en CONSULTA_F:\n%s", traceback.format_exc())
        send_text(interface, from_num, f"RESPUESTA_F|{request_id}|ERROR|interno")


def handle_entrada_findesemana(interface, from_num: int, parts: list[str]) -> None:
    """ENTRADA_F|<cedula>|<aprobadoPor>."""
    if len(parts) < 3:
        log.warning("ENTRADA_F formato inválido: %s", parts)
        return
    _, cedula, approved_by = parts[0], parts[1], parts[2]
    log.info("🗓️ ENTRADA_F cedula=%s aprobadoPor=%s", cedula, approved_by)

    try:
        record_id = airtable_create_registro(
            {
                "tipo": "ENTRADA",
                "categoria": "FIN_DE_SEMANA",
                "cedula": cedula,
                "entry_time": _now_iso(),
                "approved_by": approved_by,
                "status": "APROBADO",
                "nodo_origen": _node_hex(from_num),
            }
        )
        log.info("✓ Entrada fin-de-semana creada (record %s)", record_id)
    except AirtableError as e:
        log.error("AirtableError en ENTRADA_F: %s", e)
    except Exception:
        log.error("Excepción en ENTRADA_F:\n%s", traceback.format_exc())


def handle_salida_findesemana(interface, from_num: int, parts: list[str]) -> None:
    """SALIDA_F|<cedula>."""
    if len(parts) < 2:
        log.warning("SALIDA_F formato inválido: %s", parts)
        return
    cedula = parts[1]
    log.info("🚪 SALIDA_F cedula=%s", cedula)

    try:
        record = airtable_find_active_findesemana(cedula)
        if record is None:
            log.warning("No hay entrada fin-de-semana activa para CC %s.", cedula)
            airtable_create_registro(
                {
                    "tipo": "SALIDA",
                    "categoria": "FIN_DE_SEMANA",
                    "cedula": cedula,
                    "exit_time": _now_iso(),
                    "nodo_origen": _node_hex(from_num),
                    "status": "SALIDA_SIN_ENTRADA",
                }
            )
            return
        airtable_update_registro(record["id"], {"exit_time": _now_iso()})
        log.info("✓ Salida fin-de-semana actualizada (record %s)", record["id"])
    except AirtableError as e:
        log.error("AirtableError en SALIDA_F: %s", e)
    except Exception:
        log.error("Excepción en SALIDA_F:\n%s", traceback.format_exc())


def handle_registro_manual_findesemana(interface, from_num: int, parts: list[str]) -> None:
    """REGISTRO_MANUAL_F|<status>|<cedula>|<supervisor>|<comment>."""
    if len(parts) < 5:
        log.warning("REGISTRO_MANUAL_F formato inválido: %s", parts)
        return
    status, cedula, supervisor = parts[1], parts[2], parts[3]
    comment = parts[4] if len(parts) > 4 else ""
    log.info(
        "🗓️ REGISTRO_MANUAL_F cedula=%s status=%s supervisor=%s",
        cedula, status, supervisor,
    )

    try:
        fields = {
            "tipo": "ENTRADA" if status == "APROBADO" else "MANUAL",
            "categoria": "FIN_DE_SEMANA",
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
        log.info("✓ Registro manual fin-de-semana creado (record %s)", record_id)
    except AirtableError as e:
        log.error("AirtableError en REGISTRO_MANUAL_F: %s", e)
    except Exception:
        log.error("Excepción en REGISTRO_MANUAL_F:\n%s", traceback.format_exc())


# ---------- Handlers de items (órdenes de salida) ----------


def _airtable_items_url() -> str:
    return _airtable_url(AIRTABLE_ITEMS_TABLE)


def airtable_list_authorized_items() -> list[dict[str, Any]]:
    """Devuelve items con autorizado=true y usado=false."""
    formula = "AND({autorizado} = TRUE(), {usado} != TRUE())"
    params = {"filterByFormula": formula, "pageSize": 100}
    resp = requests.get(
        _airtable_items_url(),
        headers=_airtable_headers(),
        params=params,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code != 200:
        raise AirtableError(
            f"GET Items HTTP {resp.status_code}: {resp.text[:200]}"
        )
    return resp.json().get("records", [])


def airtable_find_item(numero: str) -> dict[str, Any] | None:
    formula = f"{{numero}} = '{numero.strip()}'"
    params = {"filterByFormula": formula, "maxRecords": 1}
    resp = requests.get(
        _airtable_items_url(),
        headers=_airtable_headers(),
        params=params,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code != 200:
        raise AirtableError(
            f"GET Items HTTP {resp.status_code}: {resp.text[:200]}"
        )
    records = resp.json().get("records", [])
    return records[0] if records else None


def airtable_mark_item_used(record_id: str, from_num: int) -> None:
    url = f"{_airtable_items_url()}/{record_id}"
    body = {
        "fields": {
            "usado": True,
            "fecha_salida": _now_iso(),
            "nodo_origen": _node_hex(from_num),
        }
    }
    resp = requests.patch(
        url,
        headers=_airtable_headers(),
        json=body,
        timeout=REQUEST_TIMEOUT_SECONDS,
    )
    if resp.status_code != 200:
        raise AirtableError(
            f"PATCH Items HTTP {resp.status_code}: {resp.text[:200]}"
        )


def _truncate(s: str, n: int) -> str:
    """Recorta y reemplaza pipes para no romper el split."""
    s = (s or "").replace("|", "/").replace("\n", " ").strip()
    return s if len(s) <= n else s[:n]


def handle_listar_items(interface, from_num: int, parts: list[str]) -> None:
    """LISTAR_ITEMS|<requestId>. Responde N veces con LIST_RESP."""
    if len(parts) < 2:
        log.warning("LISTAR_ITEMS formato inválido: %s", parts)
        return
    request_id = parts[1]
    log.info("📦 LISTAR_ITEMS req=%s de %s", request_id, _node_hex(from_num))

    try:
        records = airtable_list_authorized_items()
    except AirtableError as e:
        log.error("AirtableError en LISTAR_ITEMS: %s", e)
        # Respondemos lista vacía para que la app no se quede colgada.
        send_text(interface, from_num, f"LIST_RESP|{request_id}|0|0")
        return
    except Exception:
        log.error("Excepción en LISTAR_ITEMS:\n%s", traceback.format_exc())
        send_text(interface, from_num, f"LIST_RESP|{request_id}|0|0")
        return

    total = len(records)
    if total == 0:
        send_text(interface, from_num, f"LIST_RESP|{request_id}|0|0")
        return

    for i, record in enumerate(records, start=1):
        f = record.get("fields", {})
        numero = _truncate(f.get("numero", ""), 16)
        nombre = _truncate(f.get("nombre", ""), 30)
        concepto = _truncate(f.get("concepto", ""), 70)
        destino = _truncate(f.get("destino", ""), 25)
        autorizado_por = _truncate(f.get("autorizado_por", ""), 25)
        area = _truncate(f.get("area", ""), 20)
        msg = (
            f"LIST_RESP|{request_id}|{i}|{total}|"
            f"{numero}|{nombre}|{concepto}|{destino}|"
            f"{autorizado_por}|{area}"
        )
        send_text(interface, from_num, msg)


def handle_consulta_item(interface, from_num: int, parts: list[str]) -> None:
    """CONSULTA_ITEM|<requestId>|<numero>.

    Responde con ITEM_RESP|<requestId>|<numero>|<status>[...|<campos>].
    status: AUTORIZADO / YA_USADO / NO_AUTORIZADO / NO_EXISTE / ERROR
    """
    if len(parts) < 3:
        log.warning("CONSULTA_ITEM formato inválido: %s", parts)
        return
    request_id = parts[1]
    numero = parts[2].strip()
    log.info("📦 CONSULTA_ITEM req=%s numero=%s de %s",
             request_id, numero, _node_hex(from_num))

    try:
        record = airtable_find_item(numero)
        if record is None:
            send_text(
                interface, from_num,
                f"ITEM_RESP|{request_id}|{numero}|NO_EXISTE",
            )
            return

        f = record.get("fields", {})
        autorizado = bool(f.get("autorizado"))
        usado = bool(f.get("usado"))

        if not autorizado:
            send_text(
                interface, from_num,
                f"ITEM_RESP|{request_id}|{numero}|NO_AUTORIZADO",
            )
            return

        status = "YA_USADO" if usado else "AUTORIZADO"
        nombre = _truncate(f.get("nombre", ""), 30)
        concepto = _truncate(f.get("concepto", ""), 70)
        destino = _truncate(f.get("destino", ""), 25)
        autorizado_por = _truncate(f.get("autorizado_por", ""), 25)
        area = _truncate(f.get("area", ""), 20)

        msg = (
            f"ITEM_RESP|{request_id}|{numero}|{status}|"
            f"{nombre}|{concepto}|{destino}|"
            f"{autorizado_por}|{area}"
        )
        send_text(interface, from_num, msg)

    except AirtableError as e:
        log.error("AirtableError en CONSULTA_ITEM: %s", e)
        send_text(
            interface, from_num,
            f"ITEM_RESP|{request_id}|{numero}|ERROR|{str(e)[:50]}",
        )
    except Exception:
        log.error("Excepción en CONSULTA_ITEM:\n%s", traceback.format_exc())
        send_text(
            interface, from_num,
            f"ITEM_RESP|{request_id}|{numero}|ERROR|interno",
        )


def handle_salida_item(interface, from_num: int, parts: list[str]) -> None:
    """SALIDA_ITEM|<numero>. Marca el item como usado en Airtable."""
    if len(parts) < 2:
        log.warning("SALIDA_ITEM formato inválido: %s", parts)
        return
    numero = parts[1].strip()
    log.info("📦 SALIDA_ITEM numero=%s de %s", numero, _node_hex(from_num))

    try:
        record = airtable_find_item(numero)
        if record is None:
            log.warning("Item %s no existe en Airtable.", numero)
            return
        airtable_mark_item_used(record["id"], from_num)
        send_text(interface, from_num, f"SALIDA_ITEM_OK|{numero}")
        log.info("✓ Item %s marcado como usado (%s)", numero, record["id"])
    except AirtableError as e:
        log.error("AirtableError en SALIDA_ITEM: %s", e)
    except Exception:
        log.error("Excepción en SALIDA_ITEM:\n%s", traceback.format_exc())


# ---------- Handlers de solicitudes de aprobación (visitante no registrado) ----------
#
# Cuando el portero consulta y el visitante NO está en la lista, la app envía
# una SOLICITUD_* al gateway. El gateway crea la fila en la tabla maestra en
# estado PENDIENTE (sin autorizar). Alguien la aprueba luego en Airtable
# (marca autorizado / estado=AUTORIZADO) y la siguiente consulta ya da APROBADO.


def handle_solicitud_vehiculo(interface, from_num: int, parts: list[str]) -> None:
    """SOLICITUD_V|<cedula>|<placa>|<comment>. Crea fila PENDIENTE en Placas."""
    if len(parts) < 3:
        log.warning("SOLICITUD_V formato inválido: %s", parts)
        return
    cedula = parts[1].strip()
    placa = parts[2].upper().strip()
    comment = parts[3] if len(parts) > 3 else ""
    log.info(
        "🚗 SOLICITUD_V placa=%s cedula=%s de %s",
        placa, cedula, _node_hex(from_num),
    )

    try:
        existing = airtable_find_placa(placa)
        if existing is not None:
            if bool(existing.get("fields", {}).get("autorizado")):
                log.info("Placa %s ya autorizada — no se crea solicitud.", placa)
                return
            airtable_update_record(
                AIRTABLE_PLACAS_TABLE, existing["id"], {"estado": "PENDIENTE"}
            )
            log.info("✓ Placa %s marcada PENDIENTE (fila existente).", placa)
            return
        record_id = airtable_create_record(
            AIRTABLE_PLACAS_TABLE,
            {
                "placa": placa,
                "cedula": cedula,
                "autorizado": False,
                "estado": "PENDIENTE",
                "notas": comment,
            },
        )
        log.info("✓ Solicitud de placa creada PENDIENTE (record %s)", record_id)
    except AirtableError as e:
        log.error("AirtableError en SOLICITUD_V: %s", e)
    except Exception:
        log.error("Excepción en SOLICITUD_V:\n%s", traceback.format_exc())


def handle_solicitud_persona(interface, from_num: int, parts: list[str]) -> None:
    """SOLICITUD_P|<cedula>|<nombre>|<comment>. Crea fila PENDIENTE en Personas."""
    if len(parts) < 2:
        log.warning("SOLICITUD_P formato inválido: %s", parts)
        return
    cedula = parts[1].strip()
    nombre = parts[2].strip() if len(parts) > 2 else ""
    comment = parts[3] if len(parts) > 3 else ""
    log.info(
        "🚶 SOLICITUD_P cedula=%s de %s", cedula, _node_hex(from_num),
    )

    try:
        existing = airtable_find_persona(cedula)
        if existing is not None:
            if bool(existing.get("fields", {}).get("autorizado")):
                log.info("Persona %s ya autorizada — no se crea solicitud.", cedula)
                return
            airtable_update_record(
                AIRTABLE_PERSONAS_TABLE, existing["id"], {"estado": "PENDIENTE"}
            )
            log.info("✓ Persona %s marcada PENDIENTE (fila existente).", cedula)
            return
        fields = {
            "cedula": cedula,
            "autorizado": False,
            "estado": "PENDIENTE",
            "notas": comment,
        }
        if nombre:
            fields["nombre"] = nombre
        record_id = airtable_create_record(AIRTABLE_PERSONAS_TABLE, fields)
        log.info("✓ Solicitud de persona creada PENDIENTE (record %s)", record_id)
    except AirtableError as e:
        log.error("AirtableError en SOLICITUD_P: %s", e)
    except Exception:
        log.error("Excepción en SOLICITUD_P:\n%s", traceback.format_exc())


def handle_solicitud_findesemana(interface, from_num: int, parts: list[str]) -> None:
    """SOLICITUD_F|<cedula>|<comment>. Crea fila PENDIENTE en FinDeSemana."""
    if len(parts) < 2:
        log.warning("SOLICITUD_F formato inválido: %s", parts)
        return
    cedula = parts[1].strip()
    comment = parts[2] if len(parts) > 2 else ""
    log.info(
        "🗓️ SOLICITUD_F cedula=%s de %s", cedula, _node_hex(from_num),
    )

    try:
        existing = airtable_find_findesemana(cedula)
        if existing is not None:
            estado = (existing.get("fields", {}).get("estado") or "").strip().upper()
            if estado in ("", "AUTORIZADO"):
                log.info("FinDeSemana %s ya vale — no se crea solicitud.", cedula)
                return
            airtable_update_record(
                AIRTABLE_FINDESEMANA_TABLE, existing["id"], {"estado": "PENDIENTE"}
            )
            log.info("✓ FinDeSemana %s marcada PENDIENTE (fila existente).", cedula)
            return
        record_id = airtable_create_record(
            AIRTABLE_FINDESEMANA_TABLE,
            {
                "cedula": cedula,
                "estado": "PENDIENTE",
                "resumen": comment,
            },
        )
        log.info("✓ Solicitud fin-de-semana creada PENDIENTE (record %s)", record_id)
    except AirtableError as e:
        log.error("AirtableError en SOLICITUD_F: %s", e)
    except Exception:
        log.error("Excepción en SOLICITUD_F:\n%s", traceback.format_exc())


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
    "LISTAR_ITEMS": handle_listar_items,
    "CONSULTA_ITEM": handle_consulta_item,
    "SALIDA_ITEM": handle_salida_item,
    "CONSULTA_F": handle_consulta_findesemana,
    "ENTRADA_F": handle_entrada_findesemana,
    "SALIDA_F": handle_salida_findesemana,
    "REGISTRO_MANUAL_F": handle_registro_manual_findesemana,
    "SOLICITUD_V": handle_solicitud_vehiculo,
    "SOLICITUD_P": handle_solicitud_persona,
    "SOLICITUD_F": handle_solicitud_findesemana,
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
