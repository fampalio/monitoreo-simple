#!/usr/bin/env bash
#
# vps-metrics.sh — recolector de métricas de un servidor
# monitoreo-simple · https://github.com/fampalio/monitoreo-simple
#
# Escribe un JSON con el estado del host: CPU, RAM, disco, load, uptime,
# servicios systemd y el certificado TLS que vence primero.
# Sin dependencias externas: coreutils, /proc, systemctl y openssl.
#
# Uso:  vps-metrics.sh [ruta_salida.json]
# Lo llama metrics-push.sh cada 5 min; a mano sirve para probarlo.
#
# Qué servicios vigilar y el rol del servidor salen de
# /etc/monitoreo/metrics.conf (ver config/metrics.conf.example).
#

set -uo pipefail

OUT="${1:-/var/www/metrics/$(hostname -s).json}"
HOST="$(hostname -s)"
CONF="${METRICS_CONF:-/etc/monitoreo/metrics.conf}"

# ---------------------------------------------------------------------------
# Perfil del servidor. Formato de SERVICES: "etiqueta:unidad_systemd".
# Listá sólo lo que tiene que estar corriendo: un servicio que apagaste a
# propósito y quedó en la lista genera una alerta falsa de "servicio caído".
# ---------------------------------------------------------------------------
ROLE=""
SERVICES=()
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

# ---------------------------------------------------------------------------
# CPU: dos lecturas de /proc/stat separadas por 1s, delta de jiffies.
# ---------------------------------------------------------------------------
read_cpu_total_idle() {
  local line
  line=$(grep -m1 '^cpu ' /proc/stat)
  # shellcheck disable=SC2206
  local f=($line)
  local user=${f[1]} nice=${f[2]} system=${f[3]} idle=${f[4]}
  local iowait=${f[5]} irq=${f[6]} softirq=${f[7]} steal=${f[8]:-0}
  local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  local idle_all=$((idle + iowait))
  echo "$total $idle_all"
}

read -r t1 i1 < <(read_cpu_total_idle)
sleep 1
read -r t2 i2 < <(read_cpu_total_idle)

dt=$((t2 - t1))
di=$((i2 - i1))
if [ "$dt" -gt 0 ]; then
  cpu_pct=$(awk -v dt="$dt" -v di="$di" 'BEGIN { printf "%.1f", (dt - di) * 100 / dt }')
else
  cpu_pct="0.0"
fi

cpu_cores=$(nproc 2>/dev/null || echo 1)

# ---------------------------------------------------------------------------
# Load average
# ---------------------------------------------------------------------------
read -r load1 load5 load15 _ < /proc/loadavg

# ---------------------------------------------------------------------------
# Memoria (kB desde /proc/meminfo)
# ---------------------------------------------------------------------------
mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
mem_used_kb=$((mem_total_kb - mem_avail_kb))
mem_pct=$(awk -v u="$mem_used_kb" -v t="$mem_total_kb" 'BEGIN { printf "%.1f", (t>0) ? u*100/t : 0 }')
mem_total_gb=$(awk -v t="$mem_total_kb" 'BEGIN { printf "%.1f", t/1048576 }')
mem_used_gb=$(awk -v u="$mem_used_kb" 'BEGIN { printf "%.1f", u/1048576 }')

# Swap
swap_total_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)
swap_free_kb=$(awk '/^SwapFree:/{print $2}' /proc/meminfo)
swap_used_kb=$((swap_total_kb - swap_free_kb))
swap_pct=$(awk -v u="$swap_used_kb" -v t="$swap_total_kb" 'BEGIN { printf "%.1f", (t>0) ? u*100/t : 0 }')

# ---------------------------------------------------------------------------
# Disco raíz
# ---------------------------------------------------------------------------
disk_line=$(df -PB1 / | awk 'NR==2')
disk_total_b=$(echo "$disk_line" | awk '{print $2}')
disk_used_b=$(echo "$disk_line" | awk '{print $3}')
disk_pct=$(awk -v u="$disk_used_b" -v t="$disk_total_b" 'BEGIN { printf "%.1f", (t>0) ? u*100/t : 0 }')
disk_total_h=$(awk -v t="$disk_total_b" 'BEGIN { printf "%.1f", t/1073741824 }')
disk_used_h=$(awk -v u="$disk_used_b" 'BEGIN { printf "%.1f", u/1073741824 }')

# ---------------------------------------------------------------------------
# Uptime
# ---------------------------------------------------------------------------
uptime_s=$(awk '{printf "%d", $1}' /proc/uptime)
uptime_days=$((uptime_s / 86400))
uptime_hours=$(((uptime_s % 86400) / 3600))

# ---------------------------------------------------------------------------
# Servicios
# ---------------------------------------------------------------------------
svc_json=""
for entry in "${SERVICES[@]}"; do
  label="${entry%%:*}"
  unit="${entry##*:}"
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    state="active"
  elif systemctl list-unit-files "$unit.service" >/dev/null 2>&1 \
    && systemctl list-unit-files "$unit.service" 2>/dev/null | grep -q "$unit"; then
    state="inactive"
  else
    state="absent"
  fi
  [ -n "$svc_json" ] && svc_json="$svc_json,"
  svc_json="$svc_json{\"name\":\"$label\",\"unit\":\"$unit\",\"state\":\"$state\"}"
done

# ---------------------------------------------------------------------------
# Certificados TLS: el que vence primero entre los que sirve un vhost
# HABILITADO (Apache y nginx). No se recorre /etc/letsencrypt/live: ahí suelen
# quedar decenas de certificados vencidos sin uso que tapan a los reales.
# Un vhost habilitado que apunta a un archivo inexistente cuenta como 0 días:
# nginx/Apache no van a volver a arrancar con esa config.
# Requiere root para leer /etc/letsencrypt.
# ---------------------------------------------------------------------------
cert_files() {
  local d dirs=()
  # Sólo los servidores web que están corriendo: un nginx deshabilitado con un
  # sitio que apunta a un certificado borrado no debe contar.
  systemctl is-active --quiet apache2 2>/dev/null && dirs+=(/etc/apache2/sites-enabled)
  systemctl is-active --quiet nginx 2>/dev/null && dirs+=(/etc/nginx/sites-enabled /etc/nginx/conf.d)
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    # -R: sites-enabled son enlaces simbólicos y -r no los sigue
    grep -RhoiE '^[[:space:]]*(SSLCertificateFile|ssl_certificate)[[:space:]]+[^;[:space:]]+' "$d"/ 2>/dev/null
  done | awk '{print $2}' | tr -d '"' | sort -u
}

cert_days=""
cert_name=""
min_days=99999
now_epoch=$(date +%s)
while IFS= read -r cert; do
  if [ ! -r "$cert" ]; then
    d=0
    name="$cert (no existe)"
  else
    end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
    [ -z "$end" ] && continue
    end_epoch=$(date -d "$end" +%s 2>/dev/null) || continue
    d=$(((end_epoch - now_epoch) / 86400))
    name="$(basename "$(dirname "$cert")")"
  fi
  if [ "$d" -lt "$min_days" ]; then
    min_days=$d
    cert_name=$name
  fi
done < <(cert_files)
[ "$min_days" -ne 99999 ] && cert_days=$min_days

# ---------------------------------------------------------------------------
# Escribir JSON (atómico: temp + mv)
# ---------------------------------------------------------------------------
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<EOF
{
  "host": "$HOST",
  "role": "$ROLE",
  "timestamp": $(date +%s),
  "generated": "$(date -Is)",
  "cpu": {
    "percent": $cpu_pct,
    "cores": $cpu_cores,
    "load1": $load1,
    "load5": $load5,
    "load15": $load15
  },
  "memory": {
    "percent": $mem_pct,
    "used_gb": $mem_used_gb,
    "total_gb": $mem_total_gb,
    "swap_percent": $swap_pct
  },
  "disk": {
    "percent": $disk_pct,
    "used_gb": $disk_used_h,
    "total_gb": $disk_total_h
  },
  "uptime": {
    "seconds": $uptime_s,
    "days": $uptime_days,
    "hours": $uptime_hours
  },
  "services": [$svc_json],
  "cert_days_left": ${cert_days:-null},
  "cert_name": $([ -n "$cert_name" ] && echo "\"$cert_name\"" || echo null)
}
EOF

mkdir -p "$(dirname "$OUT")"
mv "$TMP" "$OUT"
chmod 644 "$OUT"
trap - EXIT

echo "OK: $OUT"
