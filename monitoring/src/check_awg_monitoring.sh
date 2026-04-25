#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/wgexporter/monitoring.env}"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

EXPORTER_PORT="${EXPORTER_PORT:-9586}"
PERSISTENT_EXPORTER_PORT="${PERSISTENT_EXPORTER_PORT:-9587}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
EXPORTER_USER="${EXPORTER_USER:-wgexporter}"
WG_IFACES="${WG_IFACES:-awg0}"

echo "== Services =="
for svc in wgexporter awg-persistent-traffic prometheus grafana-server; do
  if systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$svc"; then
      echo "$svc: OK"
    else
      echo "$svc: FAIL"
      systemctl status "$svc" --no-pager || true
    fi
  else
    echo "$svc: not installed"
  fi
done

echo
echo "== Exporter permission checks =="
for iface in $WG_IFACES; do
  if sudo -u "$EXPORTER_USER" sudo -n /usr/local/bin/wg show "$iface" dump >/dev/null 2>&1; then
    echo "$iface: sudo wg wrapper OK"
  else
    echo "$iface: sudo wg wrapper FAIL"
  fi
done

echo
echo "== HTTP endpoints =="
for url in \
  "http://127.0.0.1:${EXPORTER_PORT}/metrics" \
  "http://127.0.0.1:${PERSISTENT_EXPORTER_PORT}/metrics" \
  "http://127.0.0.1:${PROMETHEUS_PORT}/-/healthy"; do
  if curl -fsS --max-time 3 "$url" >/tmp/awg-monitoring-check.out 2>/tmp/awg-monitoring-check.err; then
    echo "$url: OK"
  else
    echo "$url: FAIL"
    cat /tmp/awg-monitoring-check.err || true
  fi
done

echo
echo "== Raw WireGuard metrics sample =="
curl -fsS --max-time 3 "http://127.0.0.1:${EXPORTER_PORT}/metrics" \
  | grep -E '^(wireguard_received_bytes_total|wireguard_sent_bytes_total|wireguard_latest_handshake)' \
  | head -n 10 || true

echo
echo "== Persistent traffic metrics sample =="
curl -fsS --max-time 3 "http://127.0.0.1:${PERSISTENT_EXPORTER_PORT}/metrics" \
  | grep -E '^(awg_persistent_received_bytes_total|awg_persistent_sent_bytes_total|awg_persistent_traffic_scrape_success)' \
  | head -n 20 || true

echo
echo "== Listening ports =="
ss -ltnp | grep -E ":(${EXPORTER_PORT}|${PERSISTENT_EXPORTER_PORT}|${PROMETHEUS_PORT}|${GRAFANA_PORT})" || true

echo
echo "== Prometheus target query sample =="
curl -fsS --max-time 5 "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/query?query=up" | head -c 800 || true
echo
