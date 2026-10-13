#!/usr/bin/env bash
#
# dms-n8n.sh — dead man's switch del monitoreo
# monitoreo-simple · https://github.com/fampalio/monitoreo-simple
#
# Corre en el servidor vigía (/usr/local/bin/dms-n8n), cada 5 min. Vigila lo
# que nadie más vigila: que el central, n8n y el workflow de alertas sigan
# vivos. Si se cae el central, las alertas de Telegram se caen con él; por eso
# avisa por correo, por el MTA del vigía, sin pasar por el central ni por el bot.
#
#   1. GET <N8N_URL>/healthz                          -> central, proxy y n8n vivos
#   2. GET <N8N_URL>/webhook/monitoreo-latido (token) -> hora de la última corrida
#      del workflow de alertas; más de 15 min          -> las alertas no corren
#
# Avisa a las 2 fallas seguidas (10 min), recuerda cada 6 h mientras siga
# caído y avisa cuando vuelve. Estado en /var/lib/monitoreo-dms/estado.
#
# Configuración: /etc/monitoreo/dms.env (ver config/dms.env.example).
#
# Uso:  dms-n8n                  (lo que corre el cron)
#       dms-n8n --probar-correo  (manda un correo de prueba y sale)
#
# Cron (/etc/cron.d/monitoreo-dms):
#   2-59/5 * * * * root /usr/local/bin/dms-n8n >> /var/log/dms-n8n.log 2>&1
#

set -uo pipefail
umask 077
# Cron corre sin locale: sin esto mailx no declara UTF-8 y Gmail muestra
# "estÃ¡" en vez de "está" (pasó con el primer aviso real).
export LC_ALL=C.UTF-8

ENV_FILE="/etc/monitoreo/dms.env"      # root, 600: lleva el token
STATE_DIR="/var/lib/monitoreo-dms"
STATE="$STATE_DIR/estado"
MAX_AGE=$((15 * 60))          # el workflow de alertas corre cada 5 min
FALLAS_PARA_AVISAR=2
RECORDATORIO=$((6 * 3600))

now=$(date +%s)
log() { echo "$(date -Is) $*"; }

# shellcheck source=/dev/null
. "$ENV_FILE" 2>/dev/null || { log "ERROR: no puedo leer $ENV_FILE"; exit 1; }
: "${N8N_URL:?falta N8N_URL en $ENV_FILE}"
: "${DEST:?falta DEST en $ENV_FILE}"
N8N_URL="${N8N_URL%/}"
URL_HEALTH="$N8N_URL/healthz"
URL_LATIDO="$N8N_URL/webhook/monitoreo-latido"

correo() {  # correo "asunto" "cuerpo"
  printf '%s\n\n-- \ndms-n8n en %s, %s\n' "$2" "$(hostname -s)" "$(date '+%F %T')" \
    | mail -s "$1" "$DEST"
}

duracion() {  # segundos -> "N min" / "N h M min"
  local s=$1
  if [ "$s" -ge 3600 ]; then echo "$((s / 3600)) h $(((s % 3600) / 60)) min"
  else echo "$((s / 60)) min"; fi
}

if [ "${1:-}" = "--probar-correo" ]; then
  # Con tildes a propósito: mailx no codifica el asunto, y los avisos las llevan.
  correo "[MONITOREO] Prueba del dead man's switch: ¿se ven bien las tildes? ñ á é" \
    "Si te llega esto, $(hostname -s) puede avisarte por correo cuando el central o las alertas se caigan.
Revisá que el asunto y este texto muestren bien: acción, conexión, ñandú."
  log "correo de prueba enviado a $DEST (rc=$?)"
  exit 0
fi

: "${LATIDO_TOKEN:?falta LATIDO_TOKEN en $ENV_FILE}"

# ---------------------------------------------------------------------------
# Chequeo
# ---------------------------------------------------------------------------
motivo=""
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$URL_HEALTH")
if [ "$code" = "000" ]; then
  motivo="el central o n8n no responden (sin conexión a $URL_HEALTH)"
elif [ "$code" != "200" ]; then
  motivo="n8n responde mal (healthz: HTTP $code)"
else
  resp=$(curl -s --max-time 15 -H "X-Latido-Token: $LATIDO_TOKEN" -w '\n%{http_code}' "$URL_LATIDO")
  code=${resp##*$'\n'}
  body=${resp%$'\n'*}
  updated=$(printf '%s' "$body" | jq -r '.updated // empty' 2>/dev/null)
  if [ "$code" != "200" ]; then
    motivo="n8n está vivo pero el latido de las alertas falla (HTTP $code)"
  elif [ -z "$body" ]; then
    # El latido no encontró /var/lib/metrics-alert/state.json: el workflow de
    # alertas nunca guardó su estado (no corre, o falla antes de guardar).
    # Pasa con un workflow importado pero sin publicar (n8n 2.x).
    motivo="n8n está vivo pero el workflow de alertas no guardó nunca su estado (no corre o falla antes de guardar)"
  elif ! [[ "$updated" =~ ^[0-9]+$ ]]; then
    motivo="el latido de las alertas no trae la hora de la última corrida"
  elif [ $((now - updated)) -gt "$MAX_AGE" ]; then
    motivo="n8n está vivo pero las alertas no corren hace $(duracion $((now - updated)))"
  fi
fi

# ---------------------------------------------------------------------------
# Estado anterior: estado fallas desde avisado
# ---------------------------------------------------------------------------
estado=ok fallas=0 desde=$now avisado=0
if [ -r "$STATE" ]; then
  read -r estado fallas desde avisado < "$STATE" || true
fi
[[ "$fallas" =~ ^[0-9]+$ ]] || fallas=0
[[ "$desde" =~ ^[0-9]+$ ]] || desde=$now
[[ "$avisado" =~ ^[0-9]+$ ]] || avisado=0

if [ -z "$motivo" ]; then
  if [ "$estado" = "falla" ] && [ "$avisado" -gt 0 ]; then
    correo "[MONITOREO] OK de nuevo: el central, n8n y las alertas" \
      "Volvió a andar todo: n8n responde y el workflow de alertas corre. Estuvo detectado como caído $(duracion $((now - desde)))."
    log "OK de nuevo después de $(duracion $((now - desde))); aviso enviado"
  else
    log "OK"
  fi
  estado=ok fallas=0 desde=$now avisado=0
else
  [ "$estado" = "falla" ] || desde=$now
  estado=falla
  fallas=$((fallas + 1))
  if [ "$fallas" -ge "$FALLAS_PARA_AVISAR" ] \
    && { [ "$avisado" -eq 0 ] || [ $((now - avisado)) -ge "$RECORDATORIO" ]; }; then
    asunto="[MONITOREO] CAIDO: $motivo"
    [ "$avisado" -gt 0 ] && asunto="[MONITOREO] SIGUE CAIDO (detectado hace $(duracion $((now - desde)))): $motivo"
    if correo "$asunto" \
      "$motivo.

Mientras esto siga así, las alertas de Telegram NO llegan.
Detectado hace $(duracion $((now - desde))) ($fallas chequeos seguidos).
Se vuelve a avisar cada $(duracion "$RECORDATORIO") hasta que se resuelva."; then
      avisado=$now
      log "FALLA ($fallas): $motivo; aviso enviado"
    else
      log "FALLA ($fallas): $motivo; NO se pudo enviar el correo"
    fi
  else
    log "FALLA ($fallas): $motivo"
  fi
fi

mkdir -p "$STATE_DIR"
printf '%s %s %s %s\n' "$estado" "$fallas" "$desde" "$avisado" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
