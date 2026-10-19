# Esqueleto: App Flutter ↔ Mesh ↔ Gateway ↔ Datos/IA

Plantilla genérica para arrancar una **app nueva** con la misma arquitectura que
`guaicaramo-seguridad`: una app Flutter habla por la **red mesh Meshtastic (LoRa)**
con un **gateway** (script Python en una Raspberry Pi) que tiene internet y traduce
los mensajes mesh a operaciones sobre un **backend de datos** (Airtable o Supabase)
y/o un **modelo de IA**.

La gracia del patrón: la app puede operar **sin internet ni celular**, solo con
radio LoRa de largo alcance. El único nodo que necesita internet es el gateway.

```
┌─────────────┐   BLE     ┌──────────────┐   LoRa     ┌──────────────┐   USB/BLE   ┌─────────────┐   WiFi/Eth   ┌──────────────────┐
│  App Flutter│◄────────► │ Nodo Mesh A  │◄══════════►│ Nodo Mesh GW │◄───────────►│  Gateway Pi │◄────────────►│ Airtable /        │
│ (teléfono)  │           │ (radio del   │  (mesh,    │ (radio del   │  (serial)   │ (Python)    │   (internet) │ Supabase / IA     │
│             │           │  teléfono)   │  multi-hop)│  gateway)    │             │             │              │                  │
└─────────────┘           └──────────────┘            └──────────────┘             └─────────────┘              └──────────────────┘
```

> **Regla de oro:** la mesh es lenta y de payload chico. Todo el "peso" (consultas a
> base de datos, llamadas a IA, lógica) vive en el **gateway**. La app y el protocolo
> mesh solo mueven texto cortito.

---

## 0. Acceso al gateway de referencia

El gateway de este proyecto corre en una Raspberry Pi 5:

```bash
ssh pfac@pi5-gateway      # clave: 12345
```

Útil para mirar el `gateway.py` real, el `.env`, y los logs del servicio:

```bash
sudo journalctl -u guaicaramo-gateway -f      # logs en vivo
sudo systemctl status guaicaramo-gateway
```

> Para una app nueva normalmente se levanta **otro** servicio systemd con otro
> nombre y otro nodo mesh dedicado (ver §6). Puedes correr varios gateways en la
> misma Pi mientras cada uno tenga su propio radio/puerto serial.

---

## 1. El protocolo mesh (lo más importante)

Meshtastic solo entrega **mensajes de texto cortos** (payload útil ~200 bytes por
paquete). El protocolo de este patrón es **texto plano delimitado por `|`**:

```
PREFIJO|requestId|campo1|campo2|...
```

### Reglas del protocolo

1. **Un prefijo = una operación.** El gateway enrutará por el primer token (`CONSULTA`,
   `ENTRADA`, `SOLICITUD`, …). Elige prefijos cortos y únicos.
2. **`requestId` para correlación.** Cada petición que espera respuesta lleva un id
   único. La respuesta repite ese id para que la app sepa a qué Future corresponde
   (no se asume orden de llegada).
3. **Sanitizar los campos:** ningún campo de texto libre puede contener `|`.
   Reemplázalo (p.ej. por `/`) y recorta longitudes (40 chars cortos, 150 largos).
4. **DM, no broadcast.** La app manda *direct message* al `nodeNum` del gateway; el
   gateway solo procesa mensajes dirigidos a él.
5. **Cabe en un paquete.** Si la respuesta no cabe (~200 bytes), fragméntala
   (patrón `LIST_RESP|reqId|i|n|...`) y reensambla en la app por `reqId`.
6. **Idempotencia.** Asume reenvíos y duplicados. Una operación repetida no debe
   crear filas dobles (busca antes de crear).

### Tres tipos de mensaje

| Tipo | Quién inicia | Patrón |
| --- | --- | --- |
| **Request/response** | App → GW → App | `CONSULTA\|id\|...` → `RESPUESTA\|id\|estado\|...` |
| **Fire-and-forget** | App → GW | `ENTRADA\|...` (sin respuesta, o con ACK de Meshtastic) |
| **Push proactivo** | GW → App | El gateway sondea el backend y empuja `RESULTADO\|...` cuando algo cambia |

### Tabla de protocolo (ejemplo, adáptala a tu dominio)

| Mensaje (DM al gateway) | Acción del gateway | Respuesta |
| --- | --- | --- |
| `CONSULTA\|<id>\|<clave>` | Busca en backend | `RESPUESTA\|<id>\|OK\|<datos>` / `\|NO_EXISTE` / `\|ERROR\|<motivo>` |
| `CREAR\|<clave>\|<dato>` | Inserta fila | (ACK) |
| `PREGUNTA_IA\|<id>\|<texto>` | Llama al LLM | `RESP_IA\|<id>\|<respuesta-corta>` |
| `RESULTADO\|<clave>\|<estado>` | (push) backend cambió | — |

---

## 2. Estructura de la app Flutter

```
mi_app/
├── pubspec.yaml
├── lib/
│   ├── main.dart                     # MaterialApp + navegación (tabs/bottomnav)
│   ├── models/
│   │   └── data_models.dart          # enums de estado, *Result, modelos de dominio
│   ├── services/
│   │   ├── meshtastic_service.dart   # ★ CORAZÓN: conexión BLE + protocolo + correlación
│   │   └── foreground_connection.dart# servicio en 1er plano (mantiene BLE viva)
│   ├── screens/
│   │   ├── home_screen.dart          # pantalla principal de la app
│   │   ├── settings_screen.dart      # elegir nodo gateway, reset, diagnóstico
│   │   └── ...                       # una pantalla por flujo de negocio
│   └── widgets/                      # piezas reutilizables (indicadores, markers)
└── packages/
    └── meshtastic_flutter/           # paquete que habla el protocolo BLE de Meshtastic
```

### 2.1 La capa de servicio (request/response correlacionado)

El patrón clave en Flutter: cada petición crea un `Completer`, lo guarda en un mapa
`requestId → Completer`, manda el texto y arma un timeout. Cuando llega la respuesta,
se busca el `Completer` por `requestId` y se completa.

```dart
class MeshtasticService extends ChangeNotifier {
  // requestId -> Completer en vuelo
  final Map<String, Completer<ConsultaResult>> _pending = {};

  // Contador para ids únicos aunque se disparen varias consultas en el mismo ms.
  int _requestSeq = 0;
  String _newRequestId() {
    _requestSeq = (_requestSeq + 1) & 0xFFFF;
    return '${DateTime.now().millisecondsSinceEpoch}-$_requestSeq';
  }

  /// Envía `CONSULTA|<id>|<clave>` y espera `RESPUESTA|<id>|...`.
  Future<ConsultaResult> consultar({
    required String clave,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!isConnected) {
      return ConsultaResult.error('Sin conexión al nodo');
    }
    final requestId = _newRequestId();
    final completer = Completer<ConsultaResult>();
    _pending[requestId] = completer;

    final sent = await sendChatMessage(
      'CONSULTA|$requestId|$clave',
      destinationId: currentGatewayNodeId,
    );
    if (!sent) {
      _pending.remove(requestId);
      return ConsultaResult.error('No se pudo enviar al gateway');
    }

    // Timeout: si el gateway no contesta, resolvemos con estado timeout.
    Future.delayed(timeout, () {
      final p = _pending.remove(requestId);
      if (p != null && !p.isCompleted) p.complete(ConsultaResult.timeout());
    });

    return completer.future;
  }

  /// Llamado cuando llega CUALQUIER texto del gateway. Enruta por prefijo.
  void _onTextMessage(String text) {
    if (text.startsWith('RESPUESTA|')) {
      final parts = text.split('|');
      final requestId = parts[1];
      final completer = _pending.remove(requestId);
      completer?.complete(ConsultaResult.fromParts(parts));
      return;
    }
    if (text.startsWith('RESULTADO|')) {
      // Push proactivo: emite por un Stream para que la UI reaccione.
      _resultadoController.add(GatewayNotice.fromText(text));
      return;
    }
    // ... otros prefijos
  }

  /// Sanitiza texto libre para que no rompa el split por `|`.
  static String _sanitize(String? raw, {int max = 150}) {
    if (raw == null) return '';
    final s = raw.replaceAll('|', '/').trim();
    return s.length > max ? s.substring(0, max) : s;
  }
}
```

### 2.2 Conexión BLE persistente

Para que la app siga conectada al radio con la pantalla apagada (clave en campo):
usa un **foreground service** (`flutter_foreground_task` o similar) que mantenga
vivo el BLE y reconecte solo. En este proyecto: `lib/services/foreground_connection.dart`
+ `keepaliveInterval` + `reconnectDelay` en el service.

### 2.3 Pantalla de ajustes mínima

- Seleccionar / fijar el **nodeNum del gateway** (persistido en `shared_preferences`).
- Estado de conexión BLE (conectado / escaneando / error).
- Botón de reset de datos locales.

---

## 3. Estructura del gateway (Python)

```
gateway/
├── gateway.py            # todo el gateway (un solo archivo es suficiente)
├── requirements.txt      # meshtastic, requests, python-dotenv, (supabase/openai…)
├── .env                  # secretos (NO se commitea)
├── .env.example          # plantilla de variables
└── README.md
```

### 3.1 Anatomía de `gateway.py`

El archivo se organiza por secciones (mismo orden que el proyecto real):

```python
# ---------- Config ----------       # lee os.getenv(...) del .env
# ---------- Logging ----------       # logging con formato y nivel
# ---------- Backend client ----------# funciones airtable_*/supabase_* (buscar, crear, actualizar)
# ---------- Meshtastic helpers ----- # send_text(interface, dst, txt)
# ---------- Handlers de protocolo --- # un handler por prefijo
# ---------- Poller (push) ----------  # hilo que sondea el backend y notifica a la app
# ---------- HANDLERS registry ------- # dict prefijo -> función
# ---------- on_receive --------------# callback: enruta por prefijo al handler
# ---------- Bootstrap ---------------# build_interface, precheck, main, reconexión
```

### 3.2 El despachador (corazón del gateway)

```python
HANDLERS = {
    "CONSULTA":      handle_consulta,
    "CREAR":         handle_crear,
    "PREGUNTA_IA":   handle_pregunta_ia,
    # ... un prefijo por operación
}

def on_receive(packet, interface):
    """Callback de pub.subscribe('meshtastic.receive', ...)."""
    try:
        decoded = packet.get("decoded") or {}
        if decoded.get("portnum") != "TEXT_MESSAGE_APP":
            return
        text = decoded.get("text")
        if not text:
            return

        from_num = packet.get("from")
        to_num   = packet.get("to")
        my_num   = interface.localNode.nodeNum if interface.localNode else None

        # Solo DMs dirigidos a este nodo (ignora broadcast/tráfico ajeno).
        if my_num is not None and to_num != my_num:
            return

        prefix  = text.split("|", 1)[0]
        handler = HANDLERS.get(prefix)
        if handler is None:
            return

        log.info("📨 ← %s: %s", hex(from_num or 0), text)
        handler(interface, from_num, text.split("|"))
    except Exception:
        log.error("Excepción en on_receive:\n%s", traceback.format_exc())
```

### 3.3 Un handler típico (request/response)

```python
def handle_consulta(interface, from_num, parts):
    # parts = ["CONSULTA", requestId, clave]
    if len(parts) < 3:
        return
    request_id, clave = parts[1], parts[2]
    try:
        record = backend_find(clave)            # consulta al backend (Airtable/Supabase)
        if record is None:
            send_text(interface, from_num, f"RESPUESTA|{request_id}|NO_EXISTE")
            return
        nombre = record["fields"].get("nombre", "")
        send_text(interface, from_num, f"RESPUESTA|{request_id}|OK|{nombre}")
    except BackendError as e:
        send_text(interface, from_num, f"RESPUESTA|{request_id}|ERROR|{e}")
```

```python
def send_text(interface, destination_node, text):
    # wantAck=True pide confirmación de entrega en la mesh.
    interface.sendText(text, destinationId=destination_node, wantAck=True)
```

### 3.4 Push proactivo (hilo poller)

Cuando algo cambia en el backend sin que la app pregunte (p.ej. alguien aprobó algo
en Airtable), un hilo en background sondea cada N segundos y empuja el resultado al
nodo que originó la petición (guardado como `nodo_origen` en la fila):

```python
def poller_loop(stop_event):
    while not stop_event.is_set():
        try:
            interface = _conn.get()             # holder del interface vigente
            if interface is not None:
                for fila in backend_list_resueltas():
                    dst = int(fila["fields"]["nodo_origen"])
                    estado = fila["fields"]["estado"]
                    send_text(interface, dst, f"RESULTADO|{fila['clave']}|{estado}")
                    backend_mark_notificado(fila["id"])
        except Exception:
            log.error("poller:\n%s", traceback.format_exc())
        stop_event.wait(POLL_SECONDS)            # def. 20s
```

### 3.5 Bootstrap + reconexión

```python
def main():
    precheck()                                   # valida .env y dependencias
    interface = build_interface()                # serial / TCP / BLE según .env
    _conn.set(interface)
    pub.subscribe(on_receive,        "meshtastic.receive")
    pub.subscribe(on_connection,     "meshtastic.connection.established")
    pub.subscribe(on_connection_lost,"meshtastic.connection.lost")

    threading.Thread(target=poller_loop, args=(poller_stop,), daemon=True).start()

    while not stop:                              # bucle principal
        time.sleep(1)
        if _connection_lost.is_set():            # el radio se cayó → reconectar
            _connection_lost.clear()
            interface = reconnect_interface(interface, lambda: stop)
            _conn.set(interface)
```

> **Resiliencia clave:** el SO puede reasignar el puerto serial (`ttyUSB0`→`ttyUSB1`)
> tras una reconexión. Si el path del `.env` ya no existe, deja que Meshtastic
> autodetecte. Y usa un `_InterfaceHolder` con lock para que los hilos siempre lean
> el interface vivo, no uno muerto.

### 3.6 Modo simulador (desarrollo sin radio)

Agrega un `--simulate` que lea mensajes de stdin y use un interface falso. Permite
probar handlers sin hardware:

```bash
echo "CONSULTA|1|ABC123" | python gateway.py --simulate
```

---

## 4. Backend de datos: Airtable vs Supabase

| | **Airtable** | **Supabase (Postgres)** |
| --- | --- | --- |
| Mejor para | No-técnicos editan datos a mano; setup rapidísimo | Volumen, queries complejas, relacional, realtime |
| Acceso desde gateway | REST API + token (`requests`) | `supabase-py` o REST/PostgREST |
| Cambios manuales | UI de Airtable (excelente) | Studio / SQL |
| Realtime/push | Polling (como §3.4) | Realtime subscriptions (evitas el poller) |
| Costo a escala | Sube rápido por filas/API | Generoso, autoalojable |

**Recomendación:** empieza con **Airtable** si gente no técnica gestiona los datos
(es lo que hace este proyecto). Pásate a **Supabase** si necesitas miles de filas,
relaciones, o realtime nativo (que elimina el hilo poller).

### 4.1 Cliente Airtable (patrón del proyecto)

```python
def _airtable_headers():
    return {"Authorization": f"Bearer {AIRTABLE_API_TOKEN}",
            "Content-Type": "application/json"}

def backend_find(clave):
    resp = requests.get(
        f"https://api.airtable.com/v0/{BASE_ID}/{TABLE}",
        headers=_airtable_headers(),
        params={"filterByFormula": f"{{clave}}='{clave}'", "maxRecords": 1},
        timeout=AIRTABLE_TIMEOUT,
    )
    resp.raise_for_status()
    recs = resp.json().get("records", [])
    return recs[0] if recs else None
```

### 4.2 Cliente Supabase (alternativa)

```python
from supabase import create_client
sb = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)

def backend_find(clave):
    res = sb.table("registros").select("*").eq("clave", clave).limit(1).execute()
    return res.data[0] if res.data else None
```

> Con Supabase puedes reemplazar el **poller** (§3.4) por una **Realtime
> subscription**: el gateway se suscribe a cambios de la tabla y empuja el
> `RESULTADO|...` en el instante en que cambia, sin sondear.

---

## 5. Integrar IA

La IA vive en el **gateway** (tiene internet y CPU), no en la app. La mesh solo
transporta la pregunta y la respuesta como texto corto.

```python
# requirements.txt: anthropic  (recomendado) u openai

from anthropic import Anthropic
ai = Anthropic(api_key=ANTHROPIC_API_KEY)

def handle_pregunta_ia(interface, from_num, parts):
    # parts = ["PREGUNTA_IA", requestId, texto...]
    request_id = parts[1]
    pregunta = "|".join(parts[2:])               # el texto pudo traer pipes
    try:
        msg = ai.messages.create(
            model="claude-opus-4-8",             # último Opus; ver §nota
            max_tokens=120,                      # respuesta CORTA: cabe en la mesh
            system="Responde en una frase, máximo 160 caracteres.",
            messages=[{"role": "user", "content": pregunta}],
        )
        respuesta = msg.content[0].text.replace("|", "/")[:180]
        send_text(interface, from_num, f"RESP_IA|{request_id}|{respuesta}")
    except Exception as e:
        send_text(interface, from_num, f"RESP_IA|{request_id}|ERROR|{e}")
```

**Patrones de IA útiles en este esquema:**
- **Clasificación/extracción:** la app manda texto libre, el LLM devuelve una
  etiqueta o JSON corto que el gateway convierte en una operación de backend.
- **Consulta en lenguaje natural:** "¿cuántos entraron hoy?" → el gateway arma la
  query al backend, no el modelo.
- **Resumen para la pantalla chica:** el LLM comprime una respuesta larga a ~160
  chars (lo que cabe en un paquete mesh).

> **Restricción dura:** las respuestas de IA deben caber en ~200 bytes o hay que
> fragmentarlas (patrón `LIST_RESP`). Pídele al modelo respuestas cortas con
> `max_tokens` bajo y una instrucción de longitud en el `system`.
>
> **Modelos Claude:** usa los más recientes — Opus 4.8 (`claude-opus-4-8`),
> Sonnet 4.6 (`claude-sonnet-4-6`), Haiku 4.5 (`claude-haiku-4-5-20251001`).
> Para clasificación simple y barata, Haiku basta.

---

## 6. Despliegue del gateway (systemd en la Pi)

`/etc/systemd/system/mi-gateway.service`:

```ini
[Unit]
Description=Mi Gateway Mesh
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pfac
WorkingDirectory=/home/pfac/mi-app/gateway
EnvironmentFile=/home/pfac/mi-app/gateway/.env
ExecStart=/home/pfac/mi-app/gateway/.venv/bin/python gateway.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mi-gateway
sudo journalctl -u mi-gateway -f
```

> `Restart=always` + `RestartSec=5`: si el gateway crashea, systemd lo revive. Junto
> con la reconexión interna del radio, esto da un gateway que aguanta solo en campo.

---

## 7. Checklist para arrancar una app nueva

1. **Dominio y protocolo.** Lista las operaciones (consultar, crear, …) y asígnale
   a cada una un prefijo corto. Define el formato de cada mensaje y su respuesta.
   Documéntalo en una tabla como la de §1.
2. **Backend.** Crea la base (Airtable o Supabase) con las tablas/campos. Genera el
   token/clave de servicio.
3. **Hardware mesh.** Flashea 2+ nodos Meshtastic: uno para el gateway (conectado por
   USB a la Pi) y uno por teléfono (se enlaza por BLE). Anota el `nodeNum` del gateway.
4. **Gateway.** Copia la estructura de §3: `gateway.py` con su `HANDLERS`,
   `on_receive`, clientes de backend/IA, poller y bootstrap. Prueba con `--simulate`.
5. **App Flutter.** Copia la estructura de §2: `MeshtasticService` con el mapa
   `requestId → Completer`, el paquete `meshtastic_flutter`, foreground service y las
   pantallas del flujo. Fija el `nodeNum` del gateway en ajustes.
6. **Versionado.** Reusa el patrón de `scripts/release_apk.sh` + carpeta `versiones/`
   (los `.apk` van en `.gitignore`, se regeneran).
7. **Despliegue.** Sube el gateway a la Pi, crea el `.env`, instala el servicio
   systemd y verifica con `journalctl -f`.
8. **Prueba de campo.** Consulta extremo a extremo, verifica timeouts, reconexión
   (desconecta el USB del radio), y push proactivo.

---

## 8. Errores y trampas conocidas

- **`|` en texto libre rompe el `split`.** Sanitiza siempre (§2.1, §3.3).
- **Colisión de `requestId`.** Usa contador secuencial además del timestamp (§2.1).
- **Respuesta no cabe en un paquete.** Fragmenta y reensambla por `reqId`.
- **El puerto serial cambia tras reconectar.** Deja que Meshtastic autodetecte (§3.5).
- **Hilos usando un interface muerto.** Lee siempre del `_InterfaceHolder` con lock.
- **Prefijos que comparten texto.** `RESPUESTA_P` vs `RESPUESTA`: chequea el más
  específico primero con `startsWith`, o enruta por token exacto, no por substring.
- **Filas duplicadas.** Toda operación de creación busca antes de insertar (idempotencia).
- **Polling caro en Airtable.** Sube el intervalo o múdate a Supabase Realtime.

---

## 9. Referencias rápidas

- **Gateway de referencia:** `ssh pfac@pi5-gateway` (clave `12345`),
  `~/guaicaramo-seguridad/gateway/gateway.py`.
- **App de referencia:** este repo, `lib/services/meshtastic_service.dart` (protocolo
  y correlación) y `lib/screens/` (flujos de UI).
- **Protocolo real documentado:** `gateway/README.md`.
- **Meshtastic Python:** https://meshtastic.org/docs/software/python/cli/
- **Meshtastic (general):** https://meshtastic.org/docs/
