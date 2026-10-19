#!/usr/bin/env bash
# error_watch.sh — alertador en tiempo real de ERRORES del gateway Guaicaramo.
# Sigue el journal de guaicaramo-gateway, filtra solo errores accionables
# (NO los NO_APROBADO normales) y los empuja a Telegram con anti-spam.
# Pensado para correr como servicio systemd (Restart=always).
#
# 2026-10-19: menos ruido. Se ignoran los avisos que no requieren acción
# (traceroutes, reintentos de Airtable que luego se recuperan) y cada TIPO de
# error se avisa como máximo una vez cada SIG_COOLDOWN; las repeticiones se
# cuentan y se informan en el siguiente aviso de ese tipo.
set -uo pipefail

HDIR=/home/pfac/guaica-health
source "$HDIR/secrets.env"

UNIT="guaicaramo-gateway"
COOLDOWN=20          # segundos mínimos entre mensajes a Telegram (cualquier tipo)
SIG_COOLDOWN=1800    # segundos mínimos entre avisos del MISMO tipo de error
last=0
declare -A sig_last=()
declare -A sig_count=()

send_telegram() {
  # $1 = texto. Sin parse_mode para evitar errores de formato (igual que run_check.sh).
  curl -s --max-time 25 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null 2>&1
}

# Patrones de ERROR accionable. Excluye tráfico normal (CONSULTA/RESPUESTA/NO_APROBADO/ENTRADA/SALIDA).
ERR_RE='ERROR|Error |Traceback|Exception|AirtableError|BlockingIO|Errno 11|serial port disconnected|returned no data|Killed|OOM|MemoryError|🚨|❌|Failed|Main process exited|start-limit|Stopped guaicaramo'

# Ruido que coincide con ERR_RE pero no requiere acción:
#  - 🛰️  traceroutes de diagnóstico (un sitio lejano que no contesta es normal).
#  - "intento N falló … reintento en" de Airtable: se reintenta solo; si se
#    agotan los intentos queda un "AirtableError …", que sí se avisa.
IGNORE_RE='🛰️|intento [0-9]+ falló'

# Tipo de error: el mensaje sin fecha/proceso, sin números ni ids de nodo y
# recortado, para que el mismo error con distinto timestamp/URL cuente igual.
signature() {
  local msg="${1#*| }"
  msg=$(sed -E 's/![0-9a-f]{8}/!X/g; s/[0-9]+/N/g' <<<"$msg")
  printf '%s' "${msg:0:80}"
}

send_telegram "✅ Alertador de errores del gateway ACTIVO ($(date '+%Y-%m-%d %H:%M')). Te avisaré aquí de cada error del $UNIT (mismo tipo de error: máx. 1 aviso cada $((SIG_COOLDOWN / 60)) min)."

# -n 0: solo eventos nuevos. --line-buffered: sin retraso por buffering del pipe.
journalctl -u "$UNIT" -f -n 0 --output=short-iso 2>&1 \
  | grep -E --line-buffered "$ERR_RE" \
  | grep -Ev --line-buffered "$IGNORE_RE" \
  | while IFS= read -r line; do
      now=$(date +%s)
      sig=$(signature "$line")
      if [ $((now - ${sig_last[$sig]:-0})) -ge "$SIG_COOLDOWN" ] \
         && [ $((now - last)) -ge "$COOLDOWN" ]; then
        extra=""
        n=${sig_count[$sig]:-0}
        [ "$n" -gt 0 ] && extra=$'\n'"(se repitió $n veces más desde el aviso anterior)"
        send_telegram "🚨 Gateway Guaicaramo — ERROR:"$'\n'"$line$extra"
        last=$now
        sig_last[$sig]=$now
        sig_count[$sig]=0
      else
        sig_count[$sig]=$(( ${sig_count[$sig]:-0} + 1 ))
      fi
    done
