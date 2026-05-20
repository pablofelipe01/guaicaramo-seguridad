#!/usr/bin/env bash
# Builda APK release firmado y lo guarda en versiones/ con nombre versionado.
#
# Uso:
#   ./scripts/release_apk.sh                # usa la version de pubspec.yaml
#   ./scripts/release_apk.sh "fix-mapa"     # añade un sufijo descriptivo

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Leer version de pubspec.yaml — solo la parte semántica antes del + (build number)
VERSION=$(grep -E "^version:" pubspec.yaml | head -1 | awk '{print $2}' | cut -d+ -f1)
DATE=$(date +%Y-%m-%d)
SUFFIX="${1:-}"

if [ -n "$SUFFIX" ]; then
    NAME="guaicaramo_control_${VERSION}_${DATE}_${SUFFIX}.apk"
else
    NAME="guaicaramo_control_${VERSION}_${DATE}.apk"
fi

DEST="versiones/$NAME"

if [ ! -f "android/key.properties" ]; then
    echo "❌ Falta android/key.properties. Genera el keystore primero."
    exit 1
fi

if [ -f "$DEST" ]; then
    echo "⚠️  $DEST ya existe. Sobrescribir? [y/N]"
    read -r ans
    [ "$ans" = "y" ] || exit 1
fi

echo "🔨 Build APK release version=$VERSION ..."
flutter build apk --release

mkdir -p versiones
cp build/app/outputs/flutter-apk/app-release.apk "$DEST"

SIZE=$(du -h "$DEST" | cut -f1)
SHA=$(shasum -a 256 "$DEST" | awk '{print $1}')

echo ""
echo "✅ Listo:"
echo "   Archivo: $DEST"
echo "   Tamaño:  $SIZE"
echo "   SHA256:  $SHA"
echo ""
echo "Para instalar:"
echo "   adb install -r $DEST"
echo "   o copia el APK al teléfono y abre desde el explorador de archivos."
