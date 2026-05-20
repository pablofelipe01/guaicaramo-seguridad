# Guaicaramo Control — Cómo instalar y usar

App para controlar el acceso de vehículos, chatear y ver nodos en el mapa
de la red Meshtastic de la finca. Funciona sin internet ni señal celular,
solo necesita Bluetooth + un nodo Meshtastic emparejado.

---

## 1. Instalar la app en tu celular Android

### La primera vez

1. Abre Google Drive en el celular.
2. Entra a la carpeta **Guaicaramo Control APKs** que te compartieron.
3. Toca el archivo `guaicaramo_control_0.1.X_YYYY-MM-DD.apk` (el más reciente).
4. Cuando termine de bajar, toca **Abrir** o ve a la app **Archivos** y ábrelo.
5. Android te va a preguntar:
   - **"Permitir instalar aplicaciones desconocidas desde esta fuente"** → **Permitir**.
   - **"Play Protect no analizó esta app"** → toca **Instalar de todos modos**.
6. Toca **Instalar**.
7. Cuando termine, toca **Abrir**.

### Actualizar a una versión nueva

Misma carpeta de Drive → bajar el APK más reciente → tocar → **Instalar**.
**No** tienes que desinstalar la versión anterior. Tu chat, vehículos
activos y configuración se mantienen.

---

## 2. Permisos la primera vez que abres la app

La app va a pedir tres permisos. **Todos son obligatorios** — sin ellos no puede
hablar con el nodo Meshtastic.

| Permiso | Para qué sirve |
|---|---|
| **Bluetooth (Buscar)** | Encontrar el nodo de radio |
| **Bluetooth (Conectar)** | Conectarse al nodo |
| **Ubicación** | Mostrar la posición de los nodos en el mapa (también requerido por Android para escanear Bluetooth) |

Toca **Permitir** en cada uno. Si tocaste "No" por accidente, ve a:
**Configuración del celular → Apps → Guaicaramo Control → Permisos** y actívalos.

---

## 3. Emparejar tu nodo Meshtastic

1. Enciende tu radio Meshtastic (Heltec V3, T114, etc.).
2. En la app aparece la pantalla **Seleccionar dispositivo**.
3. Espera unos segundos a que aparezca tu nodo en la lista. El nombre suele ser
   algo como `Meshtastic_a1b2`.
4. Toca tu nodo.
5. La app guarda el nodo y va a la pantalla principal. La próxima vez que abras
   se conecta sola.

> Si no aparece: verifica que el nodo esté **encendido** y **cerca** (1–2 m).
> Apaga y prende el Bluetooth del celular y dale **Escanear de nuevo**.

---

## 4. Las 5 pestañas

| Tab | Para qué |
|---|---|
| 🚗 **Recepción** | El portero pone CC + placa, la app pregunta al gateway si está autorizado. Si sí, registra entrada. Si no, pide aprobación a un supervisor. |
| 📋 **Solicitudes** | El supervisor ve aquí los pedidos de aprobación manual. Aprobar / Negar / Pendiente, con comentario opcional. |
| 💬 **Chat** | Mensajes directos a un nodo (DM) o broadcast a un canal. Indicador de entrega ✓✓ para DMs. |
| 🗺 **Mapa** | Los nodos con GPS aparecen en el mapa de la finca. Toca un nodo para enviarle un DM. |
| ⚙️ **Settings** | Estado del nodo conectado, qué nodo es el gateway, región LoRa, botón para borrar datos. |

---

## 5. Si algo sale mal

| Síntoma | Solución |
|---|---|
| "App not installed" al instalar | Una versión previa fue firmada con OTRA clave (rara vez). Desinstala la vieja primero, después instala. |
| No encuentra dispositivos Bluetooth | Verifica que diste permiso de Ubicación. Sin ese permiso, Android no permite escanear BLE. |
| Conectado pero "Esperando respuesta del gateway" indefinido | Pregunta a soporte si el gateway está corriendo. Verifica en Settings que el gateway elegido sea el correcto. |
| El mapa aparece en blanco con un mensaje | Falta el archivo de tiles offline. No es un bug del celular — soporte debe agregar el `.mbtiles` antes de generar el APK. |
| Se desconecta del nodo cada rato | El nodo puede estar lejos o con poca batería. Revisa el indicador de batería en Settings. |
| La app no aparece después de instalar | Mira en el cajón de apps por **Guaicaramo Control** o por el icono de la palma. |

---

## 6. Soporte

Si nada de lo anterior funciona, contacta a soporte con esta información:

- Modelo de celular y versión de Android.
- Versión de la app (verás "guaicaramo_control 0.1.X" al pie de la pantalla
  de Settings, o el nombre del APK que instalaste).
- Una captura de pantalla del error.

---

*Guaicaramo Control — v0.1.0 — Actualizado 2026-05-20*
