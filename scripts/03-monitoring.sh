#!/usr/bin/env bash
# =============================================================================
#  03 - Monitoramento de infraestrutura
#  Instala o monitor (CPU, Memória, Disco, serviços, HTTP) como serviço
#  systemd tolerante a falhas + guardião (timer) + teste de funcionamento.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

MON_CONF=/etc/citizentech/monitor.conf

install_monitor() {
  install -m 755 "$PROJECT_ROOT/monitoring/citizentech-monitor.sh"       /usr/local/bin/citizentech-monitor
  install -m 755 "$PROJECT_ROOT/monitoring/citizentech-monitor-guard.sh" /usr/local/bin/citizentech-monitor-guard
  audit "binarios_monitor" OK "/usr/local/bin/citizentech-monitor{,-guard}"
}

write_monitor_conf() {
  mkdir -p /etc/citizentech
  cat > "$MON_CONF" <<CONF
# Gerado por $SCRIPT_NAME - $(date -Is)
# Após editar: sudo systemctl reload citizentech-monitor
INTERVAL=$MONITOR_INTERVAL
CPU_WARN=$CPU_WARN
CPU_CRIT=$CPU_CRIT
MEM_WARN=$MEM_WARN
MEM_CRIT=$MEM_CRIT
DISK_WARN=$DISK_WARN
DISK_CRIT=$DISK_CRIT
DISK_PATHS="$DISK_PATHS"
ALERT_COOLDOWN=$ALERT_COOLDOWN
ALERT_WEBHOOK_URL="$ALERT_WEBHOOK_URL"
MONITOR_SERVICES="$MONITOR_SERVICES"
AUTO_HEAL=$AUTO_HEAL
APP_HEALTH_URL="http://127.0.0.1$APP_HEALTH_PATH"
LOG_DIR=$LOG_DIR
CONF
  chmod 640 "$MON_CONF"
  info "Limites: CPU ${CPU_WARN}/${CPU_CRIT}% | MEM ${MEM_WARN}/${MEM_CRIT}% | DISCO ${DISK_WARN}/${DISK_CRIT}% | intervalo ${MONITOR_INTERVAL}s"
}

install_units() {
  install -m 644 "$PROJECT_ROOT"/systemd/citizentech-monitor*.service /etc/systemd/system/
  install -m 644 "$PROJECT_ROOT"/systemd/citizentech-monitor-guard.timer /etc/systemd/system/
  run systemctl daemon-reload
  run systemctl enable --now citizentech-monitor.service
  run systemctl restart citizentech-monitor.service
  run systemctl enable --now citizentech-monitor-guard.timer
}

test_monitor() {
  info "Coleta de teste:"
  /usr/local/bin/citizentech-monitor --once | tee -a "$PROVISION_LOG" >&2
  sleep 3
  systemctl is-active --quiet citizentech-monitor || die "Serviço do monitor não está ativo."

  info "Teste de tolerância a falhas: matando o monitor com SIGKILL..."
  local pid_old pid_new i
  pid_old="$(systemctl show -p MainPID --value citizentech-monitor)"
  kill -9 "$pid_old"
  for i in $(seq 1 15); do
    sleep 1
    pid_new="$(systemctl show -p MainPID --value citizentech-monitor)"
    [[ "$pid_new" != "0" && "$pid_new" != "$pid_old" ]] && systemctl is-active --quiet citizentech-monitor && break
  done
  [[ "$pid_new" != "$pid_old" && "$pid_new" != "0" ]] || die "Monitor não voltou após kill -9."
  ok "Monitor reiniciado automaticamente pelo systemd (PID $pid_old -> $pid_new em ~${i}s)."
  audit "teste_tolerancia_falhas" OK "pid $pid_old -> $pid_new"
}

banner "03 - MONITORAMENTO (CPU, Memória, Disco + alertas)"
step "instalar_monitor"    install_monitor
step "config_monitor"      write_monitor_conf
step "servico_monitor"     install_units
step "teste_monitor"       test_monitor
ok "Monitoramento ativo. Alertas em $LOG_DIR/alerts.log | journalctl -t citizentech-monitor"
