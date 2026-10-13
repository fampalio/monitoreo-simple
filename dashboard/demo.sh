#!/usr/bin/env bash
#
# demo.sh — muestra el dashboard con los datos de ejemplo, sin servidores.
# Copia index.html y ejemplo/*.json a un directorio temporal, les pone la hora
# actual (si no, las tarjetas salen "obsoleto") y los sirve en
# http://localhost:8000/ (otro puerto: PORT=8080 ./demo.sh). Ctrl+C para cortar.
#
# Requiere python3 y jq.
#

set -euo pipefail

PORT="${PORT:-8000}"
cd "$(dirname "$0")"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
mkdir -p "$DIR/metrics"
cp index.html "$DIR/"
now=$(date +%s)
for f in ejemplo/*.json; do
  jq --argjson t "$now" '.timestamp = $t | .generated = (now | todate)' "$f" > "$DIR/metrics/$(basename "$f")"
done

echo "Dashboard de ejemplo en http://localhost:$PORT/"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIR"
