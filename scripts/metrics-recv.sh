#!/usr/bin/env bash
#
# metrics-recv.sh — receptor de métricas en el servidor central
# monitoreo-simple · https://github.com/fampalio/monitoreo-simple
#
# Se instala SOLO en el central (/usr/local/bin/metrics-recv) y corre como el
# usuario `metrics`. Lo disparan:
#   - los demás servidores, por SSH, a través de `command=` en
#     /home/metrics/.ssh/authorized_keys (la clave fija el host, no el cliente);
#   - el propio central, desde metrics-push con `runuser -u metrics`.
#
# Lee el JSON por stdin y:
#   1. lo publica en /var/www/metrics/<host>.json (lo leen el dashboard y n8n);
#   2. si HIST_DIR existe, agrega una línea al historial del día, fuera del
#      webroot: <HIST_DIR>/<host>-AAAA-MM-DD.ndjson
#
# El repo no trae la rotación del historial: ~300 KB por host y por día.
# Si no lo querés, no crees HIST_DIR.
#
# Hosts aceptados: /etc/monitoreo/recv.env (ver config/recv.env.example).
#

set -euo pipefail
umask 022

ENV_FILE="/etc/monitoreo/recv.env"
DEST_DIR="/var/www/metrics"
HIST_DIR="/var/lib/monitoreo/activo"
MAX_BYTES=32768

HOST="${1:-}"

# shellcheck source=/dev/null
. "$ENV_FILE" 2>/dev/null || { echo "no puedo leer $ENV_FILE" >&2; exit 1; }

# Whitelist explícita: el nombre lo pone command= en authorized_keys, y además
# tiene que estar en HOSTS. Sólo letras, números y guiones: termina en un
# nombre de archivo.
[[ "$HOST" =~ ^[a-z0-9-]+$ ]] || { echo "host no autorizado" >&2; exit 1; }
case " ${HOSTS:-} " in
  *" $HOST "*) ;;
  *) echo "host no autorizado" >&2; exit 1 ;;
esac

# TMP en el mismo directorio de destino, para que el mv final sea atómico.
TMP="$(mktemp "$DEST_DIR/.recv.XXXXXX")"
trap 'rm -f "$TMP" "$TMP.in"' EXIT

# Límite de tamaño: evita que un cliente comprometido llene el disco. Si el
# payload es más grande, queda cortado y falla la validación de abajo.
head -c "$MAX_BYTES" > "$TMP.in"

if [ ! -s "$TMP.in" ]; then
  echo "payload vacío" >&2
  exit 1
fi

# Validar: JSON bien formado, objeto, y con el mismo "host" que fija la clave
# (la clave de srv-b no puede publicar métricas a nombre de srv-c).
# Escribe en TMP el JSON tal cual y devuelve por stdout la línea compacta.
if ! LINE="$(python3 - "$TMP.in" "$TMP" "$HOST" <<'PY'
import json, sys
src, dst, host = sys.argv[1:4]
try:
    with open(src, encoding="utf-8") as f:
        data = json.load(f)
except (ValueError, OSError):
    sys.exit(1)
if not isinstance(data, dict) or data.get("host") != host:
    sys.exit(1)
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(json.dumps(data, ensure_ascii=False, separators=(",", ":")))
PY
)"; then
  echo "JSON inválido o host distinto de $HOST, descartado" >&2
  exit 1
fi

# 1. Publicación atómica (mismo filesystem: mv es un rename).
chmod 644 "$TMP"
mv "$TMP" "$DEST_DIR/$HOST.json"

# 2. Historial: una línea por muestra. Un solo writer por host, y la línea
#    (~1 KB) entra en una sola escritura con O_APPEND.
if [ -d "$HIST_DIR" ]; then
  printf '%s\n' "$LINE" >> "$HIST_DIR/$HOST-$(date +%F).ndjson"
fi

echo "recibido: $HOST"
