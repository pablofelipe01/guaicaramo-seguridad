# Versiones de Guaicaramo Control

Aquí se guardan los APKs release firmados, en orden cronológico. La idea es
tener un histórico de builds para poder volver a una versión anterior si una
nueva introduce regresiones en campo.

## Convención de nombres

```
guaicaramo_control_<version>_<YYYY-MM-DD>[_<sufijo>].apk
```

Ejemplos:
- `guaicaramo_control_0.1.0_2026-05-20.apk` — primer release.
- `guaicaramo_control_0.1.1_2026-05-25_fix-gps.apk` — patch con sufijo descriptivo.

La `version` viene de `pubspec.yaml`. Antes de cada release, bumpa el campo
`version: 0.X.Y+N` ahí.

## Cómo generar un release nuevo

```bash
# 1. (Opcional) Bumpa la version en pubspec.yaml
#    version: 0.1.1+2

# 2. Corre el script
./scripts/release_apk.sh

# 3. (Opcional) Con sufijo descriptivo
./scripts/release_apk.sh "fix-gps"
```

El script firma con el keystore en `android/keystore.jks` (que NO se commitea —
ver `android/key.properties`).

## Cómo instalar en el teléfono

### Vía USB (rápido para devs)

```bash
adb install -r versiones/guaicaramo_control_0.1.0_2026-05-20.apk
```

### Vía explorador de archivos (para usuarios finales)

1. Copia el APK al celular (USB, Google Drive, AirDrop a Android via Quick Share, etc.).
2. En el celular, abre la app **Archivos**, navega al APK y tap.
3. Android pedirá permiso "Instalar apps desconocidas" para esa fuente — concédelo.
4. Tap "Instalar".

## "App not installed" — troubleshooting

| Mensaje | Causa | Solución |
|---|---|---|
| "App not installed as package conflicts with an existing package" | Ya tienes una versión instalada firmada con OTRA clave (ej: APK debug previo) | Desinstala el viejo primero: `adb uninstall com.guaicaramo.guaicaramo_control` |
| "App not installed because it conflicts" + downgrade | Estás instalando una versión más antigua que la actual | Desinstala la nueva primero, o bumpa el versionCode |
| "Untrusted certificate" / "blocked by Play Protect" | Android desconfía de fuentes externas | Permitir "Instalar apps de esta fuente" en Configuración → Seguridad |
| Falla silenciosa con adb | El device no está autorizado | Habilita "Depuración USB" + acepta el diálogo de autorización en el cel |

> ⚠️ **Importante**: nunca cambies el keystore. Si pierdes `android/keystore.jks`
> ya no podrás actualizar in-place las apps instaladas — los usuarios tendrán
> que desinstalar y reinstalar.

## Histórico

| Version | Fecha | APK | Notas |
|---|---|---|---|
| 0.1.0 | 2026-05-20 | `guaicaramo_control_0.1.0_2026-05-20.apk` | Primer release: chat, recepción, mapa offline, gateway Airtable. |
| 0.1.1 | 2026-05-20 | `guaicaramo_control_0.1.1_2026-05-20_fix-gateway-id.apk` | Fix: gateway por defecto cambiado a `!9ea29bc4` (Heltec V3 de Guaicaramo). Limpieza de nodos preloaded de sirius_porteria. |
| 0.2.0 | 2026-05-20 | `guaicaramo_control_0.2.0_2026-05-20_peatones.apk` | **Peatones**: toggle Vehículo/Peatón en Recepción. Nueva tabla `Personas` en Airtable. Protocolo `CONSULTA_P`, `ENTRADA_P`, `SALIDA_P`, `REGISTRO_MANUAL_P` y respuestas `APROBADO_P`/`NEGADO_P`/`PENDIENTE_P`. RequestsScreen mezcla ambos tipos. |

Agrega filas a esta tabla con cada release.
