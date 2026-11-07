#!/usr/bin/env bash
# =============================================================================
#  Ferramenta de demonstração (para o vídeo): provoca situações que o monitor
#  deve detectar e mostra os alertas/recuperações em tempo real.
#
#  sudo ./tools/simulate-load.sh cpu  [segundos]   # CPU a 100%
#  sudo ./tools/simulate-load.sh mem  [segundos]   # ocupa memória acima do limite
#  sudo ./tools/simulate-load.sh disk [segundos]   # enche o disco acima do limite
#  sudo ./tools/simulate-load.sh kill-monitor      # kill -9 no monitor (systemd revive)
#  sudo ./tools/simulate-load.sh stop-app          # derruba a aplicação (auto-heal)
#  sudo ./tools/simulate-load.sh hang-monitor      # congela o monitor (guardião revive)
# =============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Use sudo." >&2; exit 1; }
CONF=/etc/citizentech/monitor.conf
INTERVAL=15; MEM_CRIT=90; DISK_CRIT=90; LOG_DIR=/var/log/citizentech
# shellcheck source=/dev/null
[[ -r $CONF ]] && source "$CONF"
DUR="${2:-60}"
ALERTS="$LOG_DIR/alerts.log"

follow() { echo ">> Acompanhando alertas (Ctrl+C para sair)..."; timeout "$1" tail -n 0 -F "$ALERTS" || true; }
command -v stress-ng >/dev/null || apt-get install -y -q stress-ng >/dev/null

case "${1:-}" in
  cpu)
    echo ">> Estressando todas as CPUs por ${DUR}s"
    stress-ng --cpu 0 --cpu-load 100 --timeout "${DUR}s" --quiet &
    follow $((DUR + INTERVAL * 2 + 5)) ;;
  mem)
    target=$(( MEM_CRIT + 3 ))
    echo ">> Ocupando memória até ~${target}% por ${DUR}s"
    read -r total avail <<<"$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print t, a}' /proc/meminfo)"
    need_kb=$(( total * target / 100 - (total - avail) ))
    (( need_kb > 0 )) || need_kb=65536
    stress-ng --vm 1 --vm-bytes "${need_kb}k" --vm-keep --timeout "${DUR}s" --quiet &
    follow $((DUR + INTERVAL * 2 + 5)) ;;
  disk)
    f=/var/tmp/citizentech-disk-fill.bin
    trap 'rm -f "$f"; echo ">> Arquivo removido"' EXIT
    read -r size used <<<"$(df -B1 --output=size,used / | tail -1)"
    need=$(( size * (DISK_CRIT + 2) / 100 - used ))
    if (( need > 0 )); then
      echo ">> Criando arquivo de $((need/1024/1024)) MB para passar de ${DISK_CRIT}% no /"
      fallocate -l "$need" "$f"
    fi
    df -h /
    follow $((DUR)) ;;
  kill-monitor)
    pid=$(systemctl show -p MainPID --value citizentech-monitor)
    echo ">> kill -9 $pid"; kill -9 "$pid"
    for i in $(seq 1 10); do sleep 1; n=$(systemctl show -p MainPID --value citizentech-monitor)
      [[ "$n" != 0 && "$n" != "$pid" ]] && { echo ">> Monitor de volta: PID $pid -> $n (${i}s)"; break; }; done
    systemctl status citizentech-monitor --no-pager | head -n 5 ;;
  stop-app)
    echo ">> Parando citizentech-app (o monitor deve reiniciar em até ${INTERVAL}s)"
    systemctl stop citizentech-app
    follow $((INTERVAL * 2 + 5))
    systemctl is-active citizentech-app ;;
  hang-monitor)
    pid=$(systemctl show -p MainPID --value citizentech-monitor)
    echo ">> Congelando o monitor (SIGSTOP pid $pid). O guardião deve reiniciá-lo em ~1-2 min."
    kill -STOP "$pid"
    follow 180 ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
