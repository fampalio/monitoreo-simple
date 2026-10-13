#!/usr/bin/env bash
#
# metrics-push.sh — recolecta las métricas del host y las entrega al central
# monitoreo-simple · https://github.com/fampalio/monitoreo-simple
#
# Se instala en todos los servidores (/usr/local/bin/metrics-push) y corre
# como root (vps-metrics.sh necesita leer /etc/letsencrypt).
#   - En los demás: envía por SSH al usuario `metrics` del central; la clave
#     restringida con `command=` decide qué se ejecuta allá.
#   - En el central: entrega local a metrics-recv como el usuario `metrics`,
#     por el mismo camino de validación que los otros.
#
# Configuración: /etc/monitoreo/push.env (ver config/push.env.example).
#
# Cron (/etc/cron.d/monitoreo):
#   */5 * * * * root /usr/local/bin/metrics-push >> /var/log/metrics-push.log 2>&1
#

set -uo pipefail

ENV_FILE="/etc/monitoreo/push.env"
COLLECTOR="/usr/local/bin/vps-metrics.sh"
KEY="/root/.ssh/metrics_push"
# Clave de host del central fijada a mano (verificada contra la huella real),
# en un known_hosts propio: nada de aceptar la primera que aparezca.
KNOWN_HOSTS="/root/.ssh/known_hosts_metrics"
CENTRAL_USER="metrics"

# shellcheck source=/dev/null
. "$ENV_FILE" 2>/dev/null || { echo "$(date -Is) ERROR: no puedo leer $ENV_FILE"; exit 1; }
: "${CENTRAL_NAME:?falta CENTRAL_NAME en $ENV_FILE}"
: "${CENTRAL_ADDR:?falta CENTRAL_ADDR en $ENV_FILE}"
CENTRAL_PORT="${CENTRAL_PORT:-22}"

HOST="$(hostname -s)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# 1. Recolectar en local
if ! "$COLLECTOR" "$TMP" >/dev/null; then
  echo "$(date -Is) ERROR: falló el recolector"
  exit 1
fi

# 2. Entregar. Del lado del central, metrics-recv decide dónde se escribe.
if [ "$HOST" = "$CENTRAL_NAME" ]; then
  runuser -u "$CENTRAL_USER" -- /usr/local/bin/metrics-recv "$HOST" < "$TMP" >/dev/null
else
  # -T: sin pedir pty (restrict no la da y el cliente lo avisa en cada corrida)
  ssh -T -i "$KEY" \
    -p "$CENTRAL_PORT" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    "$CENTRAL_USER@$CENTRAL_ADDR" < "$TMP" >/dev/null
fi
rc=$?

if [ "$rc" -eq 0 ]; then
  echo "$(date -Is) OK: $HOST entregado a $CENTRAL_NAME"
else
  echo "$(date -Is) ERROR: $HOST no se pudo entregar a $CENTRAL_NAME (rc=$rc)"
  exit 1
fi
