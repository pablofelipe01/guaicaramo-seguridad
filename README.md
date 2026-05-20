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

Las posiciones GPS y nodos conocidos **no** se persisten — se reconstruyen
desde la mesh en cada sesión.

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
