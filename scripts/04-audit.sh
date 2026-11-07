#!/usr/bin/env bash
# shellcheck disable=SC2155
# =============================================================================
#  04 - Auditoria e logs
#  auditd (quem alterou configs/app/scripts), journald persistente,
#  rotação de logs e relatório de auditoria das execuções.
#    sudo bash scripts/04-audit.sh            # configura + relatório
#    sudo bash scripts/04-audit.sh --report   # só o relatório
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

configure_auditd() {
  cat > /etc/audit/rules.d/citizentech.rules <<RULES
## Gerado por $SCRIPT_NAME - $(date -Is)
## Consulta: sudo ausearch -k <chave> -i   |   sudo aureport -k -i
-w /etc/hosts                  -p wa -k ct_rede
-w /etc/netplan/               -p wa -k ct_rede
-w /etc/systemd/resolved.conf.d/ -p wa -k ct_dns
-w /etc/hostname               -p wa -k ct_rede
-w /etc/citizentech/           -p wa -k ct_config
-w /etc/nginx/                 -p wa -k ct_nginx
-w /etc/systemd/system/citizentech-app.service     -p wa -k ct_servicos
-w /etc/systemd/system/citizentech-monitor.service -p wa -k ct_servicos
-w $APP_BASE/bin/              -p wa -k ct_app
-w /usr/local/bin/citizentech-monitor -p x -k ct_exec_monitor
-w /usr/sbin/useradd           -p x  -k ct_usuarios
-w /etc/passwd                 -p wa -k ct_usuarios
-w /etc/sudoers                -p wa -k ct_sudo
RULES
  # Pastas compartilhadas (vboxsf/9p) não suportam watch do auditd
  if [[ "$(stat -f -c %T "$PROJECT_ROOT")" =~ ^(ext2/ext3|ext4|xfs|btrfs)$ ]]; then
    echo "-w $PROJECT_ROOT/scripts/ -p wa -k ct_scripts" >> /etc/audit/rules.d/citizentech.rules
  fi
  run systemctl enable auditd
  if ! run augenrules --load; then
    warn "augenrules falhou; tentando reiniciar o auditd."
    run service auditd restart || warn "auditd indisponível neste ambiente."
  fi
  info "Regras ativas: $(auditctl -l 2>/dev/null | grep -c ' ct_' || echo 0)"
}

configure_journald() {
  mkdir -p /etc/systemd/journald.conf.d /var/log/journal
  cat > /etc/systemd/journald.conf.d/citizentech.conf <<J
# Gerado por $SCRIPT_NAME - journal persistente entre reboots
[Journal]
Storage=persistent
SystemMaxUse=300M
J
  run systemctl restart systemd-journald
}

configure_logrotate() {
  cat > /etc/logrotate.d/citizentech <<L
$LOG_DIR/*.log {
    daily
    rotate 14
    maxsize 20M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0640 root adm
}
L
  run logrotate -d /etc/logrotate.d/citizentech
  chgrp -R adm "$LOG_DIR" 2>/dev/null || true
}

report() {
  local out="$LOG_DIR/relatorio-auditoria-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "=================== RELATÓRIO DE AUDITORIA CITIZENTECH ==================="
    echo "Gerado em: $(date)   Host: $(hostname -f 2>/dev/null || hostname)"
    echo
    echo "--- Execuções de scripts (início/fim) ---"
    grep -E 'action=script_(inicio|fim)' "$AUDIT_LOG" | tail -n 30 | awk -F'|' '{print $1, $2, $6, $7, $8, $9}' || true
    echo
    echo "--- Totais por status ---"
    awk -F'|' '{print $8}' "$AUDIT_LOG" | sort | uniq -c || true
    echo
    echo "--- Falhas registradas ---"
    grep 'status=FAIL' "$AUDIT_LOG" | tail -n 20 || echo "(nenhuma)"
    echo
    echo "--- Etapas da última execução (run=$RUN_ID) ---"
    grep "run=$RUN_ID" "$AUDIT_LOG" | awk -F'|' '{print $1, $6, $7, $8}' || true
    echo
    echo "--- Eventos auditd (alterações monitoradas) ---"
    aureport -k -i --summary 2>/dev/null | head -n 25 || echo "(auditd indisponível)"
    echo
    echo "--- Últimos alertas do monitor ---"
    tail -n 15 "$LOG_DIR/alerts.log" 2>/dev/null || echo "(nenhum)"
  } | tee "$out"
  chmod 640 "$out"
  ok "Relatório salvo em $out"
}

if [[ "${1:-}" == "--report" ]]; then
  report; exit 0
fi

banner "04 - AUDITORIA E LOGS"
step "auditd"      configure_auditd
step "journald"    configure_journald
step "logrotate"   configure_logrotate
step "relatorio"   report
ok "Auditoria configurada. Logs: $PROVISION_LOG | $AUDIT_LOG"
