# Branding assets

Colocar aquí los PNGs que usarán los generadores de Flutter:

- `icon.png` — logo cuadrado, mínimo 1024×1024 (recomendado con padding
  interno para que sirva como adaptive icon en Android).
- `splash.png` — opcional. PNG con fondo transparente o blanco para el splash.

Después de añadirlos:

```bash
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

Mientras no existan, la app usa el icono y splash genéricos de Flutter.
