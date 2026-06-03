# Guaicaramo Control — Gateway

Script Python que corre en una Raspberry Pi (o cualquier máquina con un nodo
Meshtastic conectado por USB/BLE/TCP) y traduce los mensajes de la red mesh a
operaciones sobre Airtable.

## Lo que hace

| Mensaje recibido (DM al gateway)                                  | Acción                                                                                          |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `CONSULTA\|<requestId>\|<cedula>\|<placa>`                        | Busca placa en tabla `Placas`. Responde `RESPUESTA\|<requestId>\|APROBADO\|<conductor>` / `NO_APROBADO` / `ERROR\|<motivo>`. |
| `ENTRADA_V\|<cedula>\|<placa>\|<aprobadoPor>`                     | Inserta fila en `Registros` con `tipo=ENTRADA`, `entry_time` actual, `approved_by`.            |
| `SALIDA_V\|<placa>`                                               | Busca el último `ENTRADA` sin salida para esa placa y le pone `exit_time`.                     |
| `REGISTRO_MANUAL\|<status>\|<cedula>\|<placa>\|<supervisor>\|<c>` | Inserta fila con la aprobación manual (status = `APROBADO` / `NEGADO` / `PENDIENTE`).          |
| `SOLICITUD_V\|<reqId>\|<cedula>\|<placa>\|<nombre>\|<comment>`     | Visitante no registrado: crea/actualiza fila `PENDIENTE` en `Placas` (`autorizado=false`, `estado=PENDIENTE`, `conductor=<nombre>`). Responde `RESP_SOL`. |
| `SOLICITUD_P\|<reqId>\|<cedula>\|<nombre>\|<comment>`             | Igual en `Personas`. Responde `RESP_SOL`.                                                      |
| `SOLICITUD_F\|<reqId>\|<cedula>\|<comment>`                       | Igual en `FinDeSemana` (`estado=PENDIENTE`). Responde `RESP_SOL`.                              |

> **Respuesta `RESP_SOL\|<reqId>\|<resultado>`** — resultado ∈ `REGISTRADA` (creada/actualizada a PENDIENTE), `RECHAZADA` (existe y está `RECHAZADO`, no se reabre), `YA_VIGENTE` (ya daría APROBADO; reconsultar), `ERROR`.
>
> **Sin duplicados:** la `SOLICITUD_*` busca por placa/cédula antes de crear.
> Si la fila **ya existe** nunca crea otra: la reusa.
> - Ya vigente (daría `APROBADO`) → `YA_VIGENTE`, no toca nada.
> - `RECHAZADO` → `RECHAZADA`, no la reabre (un admin debe hacerlo en Airtable).
> - Cualquier otro caso (no autorizada, vencida, pendiente) → la pone `PENDIENTE` → `REGISTRADA`.
>
> **Aprobación asíncrona:** quien aprueba en Airtable marca `autorizado` (Placas/Personas) o `estado=AUTORIZADO` (FinDeSemana). La siguiente `CONSULTA` normal ya devuelve `APROBADO`.

## Esquema Airtable

### Tabla `Placas`

Lista blanca de vehículos. Una placa por fila.

| Campo        | Tipo               | Notas                                                |
| ------------ | ------------------ | ---------------------------------------------------- |
| `placa`      | Single line text   | Primary key. Mayúsculas, sin guiones. Ej: `ABC123`. |
| `cedula`     | Single line text   | CC del titular.                                      |
| `conductor`  | Single line text   | Nombre del titular (vuelve a la app si está aprobado).|
| `autorizado` | Checkbox           | `true` para permitir el acceso.                      |
| `vence`      | Date               | Opcional. Si está vencida, se rechaza automáticamente.|
| `notas`      | Long text          | Libre.                                               |

### Tabla `Registros`

Histórico de eventos. Una fila por ENTRADA, SALIDA o registro manual.

| Campo           | Tipo               | Notas                                                            |
| --------------- | ------------------ | ---------------------------------------------------------------- |
| `tipo`          | Single select      | `ENTRADA`, `SALIDA`, `MANUAL`, `SALIDA_SIN_ENTRADA`.             |
| `cedula`        | Single line text   |                                                                  |
| `placa`         | Single line text   |                                                                  |
| `entry_time`    | Date+Time          | Fecha/hora de entrada. Vacío en SALIDA huérfana.                 |
| `exit_time`     | Date+Time          | Fecha/hora de salida. Se llena al recibir `SALIDA_V`.            |
| `approved_by`   | Single line text   | `GATEWAY` o el nombre del supervisor que aprobó.                 |
| `status`        | Single select      | `APROBADO`, `NEGADO`, `PENDIENTE`, `SALIDA_SIN_ENTRADA`.         |
| `supervisor`    | Single line text   | Solo cuando viene de `REGISTRO_MANUAL`.                          |
| `comment`       | Long text          | Comentario del supervisor.                                       |
| `rejected_time` | Date+Time          | Cuando `status` es `NEGADO`/`PENDIENTE` desde `REGISTRO_MANUAL`. |
| `nodo_origen`   | Single line text   | `!xxxxxxxx` — ID hexadecimal del nodo que envió el mensaje.      |

> Si renombras tablas, ajusta `AIRTABLE_PLACAS_TABLE` / `AIRTABLE_REGISTROS_TABLE` en `.env`.

## Setup

```bash
# 1. Clonar/sincronizar este directorio en el Pi
# 2. Crear venv y dependencias
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 3. Configurar credenciales
cp .env.example .env
# editar .env con tu AIRTABLE_API_TOKEN, AIRTABLE_BASE_ID, y la conexión Meshtastic

# 4. Probar
python gateway.py
```

### Conexión Meshtastic

Definir solo UNA en `.env`:

- `MESHTASTIC_SERIAL=/dev/ttyUSB0` — radio conectada por USB (lo normal en el Pi).
- `MESHTASTIC_TCP=192.168.1.50` — radio en modo TCP/MQTT bridge en la LAN.
- `MESHTASTIC_BLE=AA:BB:CC:DD:EE:FF` — emparejada por Bluetooth (sólo Linux fiable).

### Token de Airtable

1. Crear un Personal Access Token en https://airtable.com/create/tokens.
2. Scopes mínimos: `data.records:read`, `data.records:write`, `schema.bases:read`.
3. Workspaces/Bases: añadir la base de Guaicaramo.

## Modo simulación (sin radio)

Para probar handlers contra Airtable sin tener nodo Meshtastic conectado:

```bash
python gateway.py --simulate
# Cada línea de stdin es:  <from_hex> <mensaje>
!7c1a5974 CONSULTA|abc|99887766|XYZ123
!7c1a5974 ENTRADA_V|99887766|XYZ123|GATEWAY
!7c1a5974 SALIDA_V|XYZ123
```

## Logs

```
2026-05-20 10:30:01 INFO | 🚦 Guaicaramo Control Gateway — iniciando.
2026-05-20 10:30:02 INFO | ✅ Airtable OK — tabla Placas accesible.
2026-05-20 10:30:02 INFO | 🔌 Abriendo Serial: /dev/ttyUSB0
2026-05-20 10:30:04 INFO | 📡 Conectado al nodo Meshtastic (nodeNum=!49b54674)
2026-05-20 10:30:04 INFO | 🟢 Listo. Esperando mensajes…
2026-05-20 10:31:22 INFO | 📨 ← !7c1a5974: CONSULTA|1684583482000|99887766|XYZ123
2026-05-20 10:31:22 INFO | 🚗 CONSULTA req=1684583482000 placa=XYZ123 cedula=99887766 de !7c1a5974
2026-05-20 10:31:23 INFO | 📤 → !7c1a5974: RESPUESTA|1684583482000|APROBADO|Juan Pérez
```

## Autoarranque (systemd)

`/etc/systemd/system/guaicaramo-gateway.service`:

```ini
[Unit]
Description=Guaicaramo Control Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/guaicaramo-seguridad/gateway
EnvironmentFile=/home/pi/guaicaramo-seguridad/gateway/.env
ExecStart=/home/pi/guaicaramo-seguridad/gateway/.venv/bin/python gateway.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now guaicaramo-gateway
sudo journalctl -u guaicaramo-gateway -f
```

## Troubleshooting

| Síntoma                                           | Probable causa                                                              |
| ------------------------------------------------- | --------------------------------------------------------------------------- |
| `AIRTABLE_API_TOKEN no configurado`               | `.env` no se cargó (¿está al lado de `gateway.py`?). Revisa `pip install python-dotenv`. |
| `RESPUESTA \| ... \| ERROR \| GET Placas HTTP 401` | Token inválido o sin permisos sobre esa base.                              |
| `RESPUESTA \| ... \| ERROR \| GET Placas HTTP 404` | El nombre de la tabla en `.env` no coincide con Airtable.                  |
| El portero nunca recibe respuesta                 | El gateway no recibe el DM. Verifica que el portero usa el `gateway_node_id` correcto en Settings. |
| `meshtastic` no encuentra el nodo                 | Permisos del usuario sobre `/dev/ttyUSB0` (añadir a grupo `dialout`).      |

## Estrés-test

```bash
# Desde otro terminal con el simulador corriendo:
for i in $(seq 1 5); do
  echo "!7c1a5974 CONSULTA|req-$i|99887766|XYZ123"
done | python gateway.py --simulate
```

Cada `RESPUESTA` debe llevar el `req-N` correcto. Si ves cross-talk (req-2 contestada como si fuera req-1), reporta el bug.
