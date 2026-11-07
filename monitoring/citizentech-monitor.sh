#!/usr/bin/env bash
# shellcheck disable=SC2155
# =============================================================================
#  citizentech-monitor - Monitor de infraestrutura (CPU, Memória, Disco,
#  serviços e HTTP) com alertas. Roda como serviço systemd (loop contínuo).
#
#  Uso:
#    citizentech-monitor            # loop contínuo (modo serviço)
#    citizentech-monitor --once     # uma coleta, imprime e sai
#    citizentech-monitor --status   # mostra últimas métricas e alertas
#
#  Sinais: HUP recarrega a configuração | TERM/INT encerra de forma limpa
# =============================================================================
set -uo pipefail   # sem -e de propósito: o monitor nunca deve morrer por um erro pontual

CONF="${MONITOR_CONF:-/etc/citizentech/monitor.conf}"

load_conf() {
  # Valores padrão (sobrescritos pelo arquivo de configuração)
  INTERVAL=15; CPU_WARN=70; CPU_CRIT=90; MEM_WARN=75; MEM_CRIT=90
  DISK_WARN=80; DISK_CRIT=90; DISK_PATHS="/"; ALERT_COOLDOWN=300
  ALERT_WEBHOOK_URL=""; MONITOR_SERVICES=""; AUTO_HEAL=true
  APP_HEALTH_URL=""; LOG_DIR=/var/log/citizentech
  # shellcheck source=/dev/null
  [[ -r "$CONF" ]] && source "$CONF"
  ALERT_LOG="$LOG_DIR/alerts.log"
  METRICS_LOG="$LOG_DIR/metrics.log"
  MONITOR_LOG="$LOG_DIR/monitor.log"
  STATE_DIR="${RUNTIME_DIRECTORY:-/run/citizentech-monitor}"
  HEARTBEAT="$STATE_DIR/heartbeat"
  mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null
}

ts()   { date '+%Y-%m-%dT%H:%M:%S%z'; }
mlog() { echo "$(ts) [$1] $2" >> "$MONITOR_LOG"; }

# ----------------------------------------------------------------------------
# Coletores
# ----------------------------------------------------------------------------
cpu_usage() {   # % de CPU em uso, amostra de 1s a partir de /proc/stat
  local _ u1 n1 s1 i1 w1 q1 sq1 st1 u2 n2 s2 i2 w2 q2 sq2 st2
  read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
  sleep 1
  read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
  local idle=$(( (i2 + w2) - (i1 + w1) ))
  local total=$(( (u2+n2+s2+i2+w2+q2+sq2+st2) - (u1+n1+s1+i1+w1+q1+sq1+st1) ))
  (( total > 0 )) || { echo 0; return; }
  echo $(( 100 * (total - idle) / total ))
}

mem_usage() {   # % de memória em uso (considera MemAvailable)
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ if (t>0) printf "%d", 100-(a*100/t); else print 0 }' /proc/meminfo
}

disk_usage() {  # % de uso do sistema de arquivos do caminho informado
  df -P "$1" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'
}

# ----------------------------------------------------------------------------
# Alertas (arquivo + syslog/journald + wall + webhook) com controle de repetição
# ----------------------------------------------------------------------------
declare -A LEVEL LAST_SENT

send_alert() {
  local sev="$1" key="$2" msg="$3"
  local line="$(ts) [$sev] host=$(hostname) recurso=$key $msg"
  echo "$line" >> "$ALERT_LOG"
  mlog ALERT "$key $sev $msg"
  case "$sev" in
    CRITICAL) logger -t citizentech-monitor -p user.crit    -- "$sev $key: $msg"
              command -v wall >/dev/null && echo "[CitizenTech] $sev $key: $msg" | wall 2>/dev/null ;;
    WARNING)  logger -t citizentech-monitor -p user.warning -- "$sev $key: $msg" ;;
    *)        logger -t citizentech-monitor -p user.notice  -- "$sev $key: $msg" ;;
  esac
  if [[ -n "$ALERT_WEBHOOK_URL" ]]; then
    local text="[$sev] $(hostname) - $key: $msg"
    curl -fsS -m 5 -H 'Content-Type: application/json' \
      -d "{\"text\":\"$text\",\"content\":\"$text\"}" "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 \
      || mlog WARN "falha ao enviar webhook"
  fi
}

# Avalia uma métrica percentual contra limites de aviso/crítico.
evaluate() {
  local key="$1" value="$2" warn="$3" crit="$4" unit="${5:-%}"
  local new="OK" now; now=$(date +%s)
  (( value >= crit )) && new="CRITICAL" || { (( value >= warn )) && new="WARNING"; }
  local old="${LEVEL[$key]:-OK}" last="${LAST_SENT[$key]:-0}"

  if [[ "$new" != "$old" ]]; then
    if [[ "$new" == "OK" ]]; then
      send_alert RECOVERY "$key" "normalizado: ${value}${unit} (era $old)"
    else
      send_alert "$new" "$key" "uso em ${value}${unit} (limite aviso=${warn}${unit} crítico=${crit}${unit})"
    fi
    LAST_SENT[$key]=$now
  elif [[ "$new" != "OK" ]] && (( now - last >= ALERT_COOLDOWN )); then
    send_alert "$new" "$key" "continua em ${value}${unit} (persistente)"
    LAST_SENT[$key]=$now
  fi
  LEVEL[$key]="$new"
}

check_services() {
  local svc
  for svc in $MONITOR_SERVICES; do
    systemctl cat "$svc.service" &>/dev/null || continue   # ignora serviços inexistentes
    if ! systemctl is-active --quiet "$svc"; then
      if [[ "${LEVEL[svc_$svc]:-OK}" == "OK" ]]; then
        send_alert CRITICAL "servico:$svc" "serviço parado"
      fi
      LEVEL[svc_$svc]="CRITICAL"
      if [[ "$AUTO_HEAL" == "true" ]]; then
        if systemctl restart "$svc" 2>/dev/null; then
          # espera a aplicação voltar a responder antes de declarar recuperação (evita falso 502)
          local w=0
          while (( w < 20 )); do
            if [[ -z "$APP_HEALTH_URL" ]] || curl -fsS -o /dev/null -m 2 "$APP_HEALTH_URL" 2>/dev/null; then break; fi
            sleep 1; w=$((w + 1))
          done
          send_alert RECOVERY "servico:$svc" "reiniciado automaticamente (auto-heal), respondendo após ${w}s"
          LEVEL[svc_$svc]="OK"
        fi
      fi
    elif [[ "${LEVEL[svc_$svc]:-OK}" != "OK" ]]; then
      send_alert RECOVERY "servico:$svc" "serviço ativo novamente"
      LEVEL[svc_$svc]="OK"
    fi
  done
}

check_http() {
  [[ -n "$APP_HEALTH_URL" ]] || { HTTP_CODE="-"; return; }
  HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$APP_HEALTH_URL" 2>/dev/null)"
  if [[ "$HTTP_CODE" =~ ^(2|3) ]]; then
    [[ "${LEVEL[http]:-OK}" != "OK" ]] && send_alert RECOVERY "http" "aplicação respondendo (HTTP $HTTP_CODE)"
    LEVEL[http]="OK"
  else
    [[ "${LEVEL[http]:-OK}" == "OK" ]] && send_alert CRITICAL "http" "health check falhou (HTTP ${HTTP_CODE:-000}) em $APP_HEALTH_URL"
    LEVEL[http]="CRITICAL"
  fi
}

collect() {
  local cpu mem path d disks=""
  cpu=$(cpu_usage); mem=$(mem_usage)
  evaluate cpu "$cpu" "$CPU_WARN" "$CPU_CRIT"
  evaluate memoria "$mem" "$MEM_WARN" "$MEM_CRIT"
  for path in $DISK_PATHS; do
    d=$(disk_usage "$path"); [[ -n "$d" ]] || continue
    evaluate "disco:$path" "$d" "$DISK_WARN" "$DISK_CRIT"
    disks+=" disco[$path]=${d}%"
  done
  check_services
  check_http
  local load; load=$(cut -d' ' -f1-3 /proc/loadavg)
  local line="$(ts) cpu=${cpu}% mem=${mem}%${disks} load=\"$load\" http=$HTTP_CODE"
  echo "$line" >> "$METRICS_LOG"
  echo "$(date +%s)" > "$HEARTBEAT"
  [[ "${ONCE:-0}" == 1 ]] && echo "$line"
}

show_status() {
  load_conf
  echo "== Últimas métricas ($METRICS_LOG)"; tail -n 5 "$METRICS_LOG" 2>/dev/null
  echo; echo "== Últimos alertas ($ALERT_LOG)"; tail -n 10 "$ALERT_LOG" 2>/dev/null
  if [[ -f "$HEARTBEAT" ]]; then
    echo; echo "== Heartbeat: $(( $(date +%s) - $(cat "$HEARTBEAT") ))s atrás"
  fi
}

# ----------------------------------------------------------------------------
case "${1:-}" in
  --once)   load_conf; ONCE=1; collect; exit 0 ;;
  --status) show_status; exit 0 ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
esac

load_conf
RUNNING=1
trap 'mlog INFO "HUP recebido: recarregando $CONF"; load_conf' HUP
trap 'mlog INFO "encerrando (sinal TERM/INT)"; RUNNING=0' TERM INT

mlog INFO "monitor iniciado (pid=$$, intervalo=${INTERVAL}s, conf=$CONF)"
logger -t citizentech-monitor -p user.notice "monitor iniciado pid=$$"

while (( RUNNING )); do
  collect
  # sleep em background + wait permite reagir a sinais imediatamente
  sleep "$INTERVAL" & wait $! 2>/dev/null
done
mlog INFO "monitor finalizado"
exit 0
