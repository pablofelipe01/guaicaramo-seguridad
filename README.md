# Guaicaramo Control

App Flutter para controlar accesos vehiculares, chatear y ver el mapa de nodos
GPS en la red **Meshtastic** (LoRa + BLE) de la plantación **Guaicaramo**
(15.000 hectáreas, sin cobertura celular ni WiFi).

Se comunica por Bluetooth a una radio Meshtastic. Las consultas a Airtable
viajan por la mesh hasta un **gateway** Python que corre en una Raspberry Pi
con internet.

---

## Funciones

1. **Recepción de vehículos** — el portero introduce CC + placa, la app
   consulta al gateway si la placa está autorizada (tabla `Placas` en
   Airtable). Si no, pide aprobación manual a un supervisor por mesh.
2. **Chat mesh** — DMs entre nodos + canales broadcast. Indicadores de entrega
   con ACK/NACK.
3. **Mapa offline** — tiles MBTiles pre-empacados muestran cada nodo de la red
   con su posición GPS y track de sesión. Tap en un nodo abre DM con él.
4. **Solicitudes** — vista de supervisor para aprobar/negar/poner pendiente
   solicitudes de aprobación manual.
5. **Gerentes UEA (con o sin internet)** — ingreso y salida de Gerentes de
   Unidades Externas. Es el único módulo que **no usa la malla ni el gateway**:
   habla directo con Airtable por HTTPS cuando el teléfono tiene internet (WiFi
   o datos). La lista de gerentes y quién está dentro quedan guardados en el
   teléfono; sin internet el vigilante sigue registrando y cada movimiento
   queda en cola con su hora real hasta que vuelva la conexión. Ver
   [Gerentes UEA](#gerentes-uea).

---

## Estructura

```
guaicaramo-seguridad/
├── lib/
│   ├── main.dart                       # Startup + DeviceSelection + MainScreen
│   ├── models/data_models.dart         # ChatMessage, MeshNode, VehicleEntry, etc.
│   ├── services/meshtastic_service.dart # BLE + mesh + persistencia + GPS
│   ├── screens/
│   │   ├── recepcion_screen.dart       # CC + placa → consulta gateway → entrada
│   │   ├── requests_screen.dart        # Solicitudes de aprobación manual
│   │   ├── chat_screen.dart            # DMs + canales con badges
│   │   ├── map_screen.dart             # FlutterMap + MBTiles + nodos GPS
│   │   └── settings_screen.dart        # Nodo, gateway, región LoRa, borrar datos
│   └── widgets/
│       ├── battery_indicator.dart
│       ├── delivery_indicator.dart
│       └── node_marker.dart
├── packages/
│   └── meshtastic_flutter/             # Fork local del SDK (BLE + protobuf)
├── assets/
│   ├── maps/                           # ← Colocar guaicaramo.mbtiles aquí
│   └── branding/                       # ← Logo de la app (ver iconos)
├── gateway/                            # Script Python para el Pi (ver gateway/README.md)
└── android/, ios/                       # Plataformas
```

---

## Stack

| Componente   | Tecnología                                          |
| ------------ | --------------------------------------------------- |
| App          | Flutter 3.38+, Dart 3.10+                           |
| BLE/mesh     | `meshtastic_flutter` (fork en `packages/`)          |
| Mapa offline | `flutter_map` + `flutter_map_mbtiles` (tiles MBTiles) |
| Persistencia | `shared_preferences` (JSON)                         |
| Gateway      | Python 3 + `meshtastic` + Airtable REST API         |

---

## Setup

### App Flutter

```bash
flutter pub get
flutter run                  # debug en device conectado
flutter analyze              # lint
flutter test                 # widget tests
flutter build apk --release  # APK release (requiere keystore)
```

### Gateway Python

Ver [`gateway/README.md`](gateway/README.md). Resumen:

```bash
cd gateway
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env  # editar
python gateway.py
```

---

## Mapa offline

El mapa **no funciona sin el archivo MBTiles**. La pantalla detecta su ausencia
y muestra instrucciones.

Para generarlo:

1. Instalar [Mobile Atlas Creator](https://mobac.sourceforge.io/) (gratis).
2. Source: OpenStreetMap Mapnik o ESRI World Imagery.
3. Área: bounding box de Guaicaramo (~12×13 km, centro `4.36, -72.83`).
4. Zoom: 10 a 17.
5. Output format: **MBTiles SQLite**.
6. Tamaño esperado: 100–250 MB.
7. Copiar a `assets/maps/guaicaramo.mbtiles`.
8. Reinstalar la app (el asset se copia al storage al primer arranque).

---

## Branding (icono + splash)

El proyecto ya tiene configurados `flutter_launcher_icons` y
`flutter_native_splash` en `pubspec.yaml`. Para aplicarlos:

1. Coloca tu logo en `assets/branding/icon.png` (PNG cuadrado, mínimo
   1024×1024, idealmente con padding interno para que se vea bien en circular
   adaptive icons de Android).
2. (Opcional) Coloca un PNG para splash en `assets/branding/splash.png`.
3. Corre:
   ```bash
   dart run flutter_launcher_icons
   dart run flutter_native_splash:create
   ```
4. Verifica los archivos generados en `android/app/src/main/res/` y
   `ios/Runner/Assets.xcassets/`.

> Si no agregas el logo, la app sigue usando el icono y splash genéricos de
> Flutter — todo funciona, solo se ve sin marca.

---

## Protocolo mesh

Todos los mensajes son texto plano sobre `TEXT_MESSAGE_APP`.

### App → Gateway

| Mensaje                                                             | Propósito                          |
| ------------------------------------------------------------------- | ---------------------------------- |
| `CONSULTA\|<requestId>\|<cedula>\|<placa>`                          | Verifica autorización de placa     |
| `ENTRADA_V\|<cedula>\|<placa>\|<aprobadoPor>`                       | Registra entrada                   |
| `SALIDA_V\|<placa>`                                                 | Registra salida                    |
| `REGISTRO_MANUAL\|<status>\|<cedula>\|<placa>\|<supervisor>\|<com>` | Registra aprobación manual         |

### Gateway → App

| Mensaje                                            | Propósito                       |
| -------------------------------------------------- | ------------------------------- |
| `RESPUESTA\|<requestId>\|APROBADO\|<conductor>`    | Placa autorizada                |
| `RESPUESTA\|<requestId>\|NO_APROBADO`              | Placa no autorizada             |
| `RESPUESTA\|<requestId>\|ERROR\|<motivo>`          | Error consultando Airtable      |

### App ↔ App (supervisor)

| Mensaje                                  | Propósito                                  |
| ---------------------------------------- | ------------------------------------------ |
| `SOLICITUD_V\|<cedula>\|<placa>`         | Portero pide aprobación manual             |
| `APROBADO\|<supervisor>\|<comment?>`     | Supervisor aprueba                         |
| `NEGADO\|<supervisor>\|<comment?>`       | Supervisor niega                           |
| `PENDIENTE\|<supervisor>\|<comment?>`    | Supervisor pone en espera                  |

---

## Persistencia

| Key SharedPreferences      | Contenido                                       |
| -------------------------- | ----------------------------------------------- |
| `saved_device_address`     | MAC/UUID del nodo BLE                           |
| `saved_device_name`        | Nombre legible del nodo                         |
| `lora_region`              | Código de región LoRa (US, EU_433, EU_868)     |
| `gateway_node_id`          | nodeNum del gateway elegido                    |
| `vehicle_entries`          | JSON array de `VehicleEntry` (cap diario)      |
| `vehicle_requests`         | JSON array de `VehicleRequest` (cap diario)    |
| `message_history`          | JSON array de `ChatMessage` (cap 100)          |
| `last_session_date`        | YYYY-MM-DD; al cambiar, limpia datos no activos |
| `gerentes_airtable_token`  | Token de Airtable del módulo Gerentes (solo en el teléfono) |
| `openai_api_key`           | Clave de OpenAI para el dictado de observaciones (solo en el teléfono) |
| `gerentes_lista_v2`        | Lista de gerentes UEA + fecha de actualización  |
| `gerentes_visitas_v2`      | Ingresos/salidas de gerentes con estado de sync. Lo pendiente nunca se borra; lo sincronizado y cerrado se conserva 7 días |

Las posiciones GPS y nodos conocidos **no** se persisten — se reconstruyen
desde la mesh en cada sesión.

---

## Gerentes UEA

Módulo independiente (`lib/models/gerentes_models.dart`,
`lib/services/gerentes_service.dart`, `lib/services/gerentes_airtable.dart`,
`lib/screens/gerentes_screen.dart`). No toca la malla, el gateway ni los demás
módulos; solo se conecta a la app como una pestaña más.

**Tablas** (base `apptwIqTras1uPNOc`, accedidas por ID de tabla y de campo, así
que renombrar columnas no rompe la app):

- `Gerentes Unidades Externas` — se descarga completa al teléfono.
- `Ingresos Gerentes Unidades Externas` — una fila por visita: `Gerente`
  (vínculo), `fecha_hora_ingreso`, `fecha_hora_salida`, `placa_ingreso`,
  `nota_vigilante`. Las búsquedas usan los nombres `fecha_hora_ingreso` /
  `fecha_hora_salida`: si se renombran, la app avisa "cambió la estructura".

**Configuración (una vez por teléfono, con internet):** pestaña Gtes → ícono de
llave → pegar el token → *Guardar y probar*. Use un Personal Access Token
dedicado con scopes `data.records:read` + `data.records:write` y acceso solo a
la base de Guaicaramo. El token **no va dentro del APK** (los APK se comparten
por WhatsApp/Drive); queda solo en el almacenamiento privado del teléfono.

**Sincronización:** cada registro intenta subir de inmediato; si no hay
internet queda en cola y se reintenta solo (15 s → 30 s → cada minuto), al
volver a la app y con el botón *Sincronizar*. Con internet, cada 2 min se
refresca quién está dentro (incluidas otras porterías) y cada 30 min la lista
de gerentes. Reintentar no duplica: si un envío quedó sin respuesta, antes de
repetirlo se busca en Airtable la fila por gerente + hora exacta.

**Dictado de observaciones:** el micrófono del campo *Observación* (ingreso y
salida) graba en mono a 16 kHz (máx. 90 s, ~4 KB/s) y transcribe en español
con la API de OpenAI (`gpt-transcribe`; si la cuenta no tiene acceso, usa
`gpt-4o-mini-transcribe`). El texto se agrega al campo para que el vigilante lo
revise antes de registrar. **Necesita internet**: sin conexión el micrófono lo
avisa y la observación se escribe a mano. La clave de OpenAI se configura en
Gtes → ⚙ → *Dictado por voz (OpenAI)* o al tocar el micrófono por primera vez;
se valida con medio segundo de silencio y queda solo en el teléfono (use una
clave de proyecto con límite de gasto). El audio se envía a OpenAI y se borra
del teléfono al terminar.

---

## Estado del proyecto

- [x] **Fase 1** — Cimientos (BLE, conexión, persistencia, 5 tabs).
- [x] **Fase 2** — Chat (DMs + canales + ACK).
- [x] **Fase 3** — Recepción de vehículos (CONSULTA + supervisor).
- [x] **Fase 4** — Mapa con MBTiles offline + tracks GPS.
- [x] **Fase 5** — Gateway Python con Airtable.
- [x] **Fase 6** — Pulido (este documento, configuración de branding, verificación).

Pendientes que **requieren tu acción**:

- Crear las tablas `Placas` y `Registros` en Airtable (esquema en `gateway/README.md`).
- Generar y agregar `assets/maps/guaicaramo.mbtiles`.
- Agregar `assets/branding/icon.png` (y splash) y correr los generadores.
- Configurar firma de release para Android (keystore) e iOS (Apple Developer).
- Probar end-to-end con hardware real.
