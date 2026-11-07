#!/usr/bin/env bash
# Guardião: reinicia o monitor se ele estiver parado ou travado (heartbeat antigo).
set -uo pipefail
CONF=/etc/citizentech/monitor.conf
INTERVAL=15; LOG_DIR=/var/log/citizentech
# shellcheck source=/dev/null
[[ -r "$CONF" ]] && source "$CONF"
HB=/run/citizentech-monitor/heartbeat
MAX_AGE=$(( INTERVAL * 4 + 10 ))
reason=""

if ! systemctl is-active --quiet citizentech-monitor; then
  reason="serviço inativo"
elif [[ -f "$HB" ]]; then
  age=$(( $(date +%s) - $(cat "$HB") ))
  (( age > MAX_AGE )) && reason="heartbeat parado há ${age}s (máx ${MAX_AGE}s)"
fi

if [[ -n "$reason" ]]; then
  msg="$(date '+%Y-%m-%dT%H:%M:%S%z') [CRITICAL] host=$(hostname) recurso=monitor guardião reiniciou o monitor: $reason"
  echo "$msg" >> "$LOG_DIR/alerts.log"
  logger -t citizentech-guard -p user.crit "$msg"
  systemctl restart citizentech-monitor
fi
exit 0
