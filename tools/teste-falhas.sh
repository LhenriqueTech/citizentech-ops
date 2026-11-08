#!/usr/bin/env bash
# =============================================================================
#  Testes de falha da infraestrutura, com evidências em evidencias/testes-falha/
#
#    sudo bash tools/teste-falhas.sh script       # erro controlado num script -> logs
#    sudo bash tools/teste-falhas.sh monitor      # systemctl stop no monitor -> guardião recupera
#    sudo bash tools/teste-falhas.sh pre-reboot   # registra o estado antes de reiniciar a VM
#    sudo bash tools/teste-falhas.sh pos-reboot   # confere os serviços depois do reboot
#
#  O reboot em si é feito de fora (vagrant reload) ou com: sudo reboot
# =============================================================================
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Use sudo." >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/evidencias/testes-falha"
LOG=/var/log/citizentech
SERVICOS="citizentech-app nginx citizentech-monitor citizentech-monitor-guard.timer auditd"
mkdir -p "$OUT"

cap() {  # cap <arquivo> <comando...>: registra o comando e a saída
  local f="$OUT/$1"; shift
  { echo "\$ $*"; bash -c "$*" 2>&1; echo; } >> "$f"
}
cabecalho() { echo "=== $1 | $(date '+%Y-%m-%d %H:%M:%S %z') | host $(hostname) ===" > "$OUT/$2"; echo >> "$OUT/$2"; }
marca() { date '+%Y-%m-%dT%H:%M:%S%z'; }

teste_script() {
  local f=01-falha-controlada-script.txt; cabecalho "TESTE 1 - Falha controlada em script" $f
  local t; t="$(marca)"
  cap $f "bash $ROOT/tools/falha-controlada.sh 2>&1 | tail -n 12; echo \"código de saída: \${PIPESTATUS[0]}\""
  cap $f "awk -v t='$t' '\$1>=t' $LOG/audit.log | grep falha-controlada | cut -d'|' -f1,6-9"
  cap $f "awk -v t='$t' '\$1>=t' $LOG/provision.log | grep -E 'ERROR' | head -n 3"
  cap $f "journalctl -t citizentech-provision --since '-5min' -p err --no-pager | tail -n 3"
}

teste_monitor() {
  local f=02-monitor-parado-recuperado.txt; cabecalho "TESTE 2 - Monitor interrompido manualmente (systemctl stop)" $f
  local t; t="$(marca)"
  cap $f "systemctl is-active citizentech-monitor; systemctl show -p MainPID --value citizentech-monitor"
  cap $f "systemctl stop citizentech-monitor; systemctl is-active citizentech-monitor"
  cap $f "systemctl list-timers citizentech-monitor-guard.timer --no-pager | head -n 2"
  local i
  for i in $(seq 1 30); do systemctl is-active --quiet citizentech-monitor && break; sleep 5; done
  echo "# monitor voltou após ~$((i * 5))s sem intervenção manual" >> "$OUT/$f"; echo >> "$OUT/$f"
  cap $f "systemctl is-active citizentech-monitor; systemctl show -p MainPID --value citizentech-monitor"
  cap $f "awk -v t='$t' '\$1>=t' $LOG/alerts.log | grep -i guardi"
  cap $f "journalctl -t citizentech-guard --since '-5min' --no-pager | tail -n 2"
  # administração do serviço: restart e reload
  cap $f "systemctl restart citizentech-monitor && systemctl is-active citizentech-monitor"
  cap $f "systemctl reload citizentech-monitor && sleep 1 && tail -n 1 $LOG/monitor.log"
}

teste_pre_reboot() {
  local f=03-reboot-vm.txt; cabecalho "TESTE 3 - Reinicialização da VM" $f
  echo "## ANTES do reboot" >> "$OUT/$f"
  cap $f "cat /proc/sys/kernel/random/boot_id; uptime -s"
  cap $f "for s in $SERVICOS; do printf '%-36s %-8s %s\n' \$s \$(systemctl is-enabled \$s) \$(systemctl is-active \$s); done"
}

teste_pos_reboot() {
  local f=03-reboot-vm.txt
  echo "## DEPOIS do reboot (vagrant reload) - nenhum script foi executado manualmente" >> "$OUT/$f"; echo >> "$OUT/$f"
  sleep 20   # dá tempo para o monitor fazer algumas coletas
  cap $f "cat /proc/sys/kernel/random/boot_id; uptime -s"
  cap $f "for s in $SERVICOS; do printf '%-36s %-8s %s\n' \$s \$(systemctl is-enabled \$s) \$(systemctl is-active \$s); done"
  cap $f "curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://app.citizentech.local/health; curl -s http://app.citizentech.local/api/metricas | jq -c '{cruzamentos, online, reducao_espera_pct}'"
  cap $f "journalctl -b -u citizentech-monitor -u citizentech-app --no-pager | grep -E 'Started' | tail -n 2"
  cap $f "tail -n 2 $LOG/metrics.log"
}

case "${1:-}" in
  script) teste_script ;;
  monitor) teste_monitor ;;
  pre-reboot) teste_pre_reboot ;;
  pos-reboot) teste_pos_reboot ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
echo "evidência gravada em $OUT"
