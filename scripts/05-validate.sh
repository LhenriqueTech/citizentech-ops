#!/usr/bin/env bash
# =============================================================================
#  05 - Validação ponta a ponta + coleta de evidências técnicas
#  Executa um checklist (PASS/FAIL) e salva as evidências em
#  evidencias/<data-hora>/ dentro do repositório.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

EVID_DIR="$PROJECT_ROOT/evidencias/$(date +%Y%m%d-%H%M%S)"
PASS=0; FAIL=0
RESULTS=()

check() {
  local desc="$1"; shift
  if "$@" &>/dev/null; then
    RESULTS+=("[PASS] $desc"); PASS=$((PASS+1)); ok "PASS - $desc"
  else
    RESULTS+=("[FAIL] $desc"); FAIL=$((FAIL+1)); warn "FAIL - $desc"
  fi
}

http_ok() { curl -fsS -o /dev/null -m 5 -H "Host: $APP_DOMAIN" "http://127.0.0.1$APP_HEALTH_PATH"; }
app_ok()  { [[ ! -f /etc/systemd/system/citizentech-app.service ]] || systemctl is-active --quiet citizentech-app; }

run_checks() {
  check "Hostname configurado ($HOST_NAME)"            test "$(hostname)" = "$HOST_NAME"
  check "Resolução local de $APP_DOMAIN"               getent hosts "$APP_DOMAIN"
  check "DNS externo (github.com)"                     getent hosts github.com
  check "Rota padrão / conectividade"                  ip route show default
  check "Firewall UFW ativo"                           bash -c "ufw status | grep -q 'Status: active'"
  check "Fuso horário $TIMEZONE"                       bash -c "timedatectl show -p Timezone --value | grep -qx '$TIMEZONE'"
  check "Usuário de serviço $APP_USER"                 id "$APP_USER"
  check "Arquivo de variáveis /etc/citizentech/app.env" test -s /etc/citizentech/app.env
  check "Serviço da aplicação ativo"                   app_ok
  check "Serviço da aplicação habilitado no boot"      bash -c "[[ ! -f /etc/systemd/system/citizentech-app.service ]] || systemctl is-enabled --quiet citizentech-app"
  check "Nginx ativo"                                  systemctl is-active --quiet nginx
  check "Aplicação responde via Nginx ($APP_DOMAIN)"   http_ok
  check "Monitor ativo"                                systemctl is-active --quiet citizentech-monitor
  check "Monitor habilitado no boot"                   systemctl is-enabled --quiet citizentech-monitor
  check "Guardião (timer) ativo"                       systemctl is-active --quiet citizentech-monitor-guard.timer
  check "Métricas sendo gravadas"                      test -s "$LOG_DIR/metrics.log"
  check "auditd ativo"                                 systemctl is-active --quiet auditd
  check "Log de auditoria dos scripts"                 test -s "$AUDIT_LOG"
  check "Log de execução dos scripts"                  test -s "$PROVISION_LOG"
}

collect_evidence() {
  mkdir -p "$EVID_DIR"
  local c
  declare -A cmds=(
    [01-hostname.txt]="hostnamectl; echo; cat /etc/hosts"
    [02-rede-ip.txt]="ip -br addr; echo; ip route; echo; cat /etc/netplan/*.yaml 2>/dev/null"
    [03-dns.txt]="resolvectl status 2>/dev/null || cat /etc/resolv.conf; echo; getent hosts $APP_DOMAIN; dig +short github.com"
    [04-firewall.txt]="ufw status verbose"
    [05-servicos.txt]="systemctl status citizentech-app nginx citizentech-monitor citizentech-monitor-guard.timer auditd --no-pager -l"
    [06-app-http.txt]="curl -si -H 'Host: $APP_DOMAIN' http://127.0.0.1$APP_HEALTH_PATH; echo; curl -s -H 'Host: $APP_DOMAIN' http://127.0.0.1/ | head -n 30"
    [07-app-env-chaves.txt]="sed -E 's/=.*/=*** (oculto)/' /etc/citizentech/app.env; echo; cat /etc/systemd/system/citizentech-app.service 2>/dev/null"
    [08-dependencias.txt]="cat $APP_BASE/dependencias-python.txt 2>/dev/null; node -v 2>/dev/null; java -version 2>&1 | head -1; dotnet --version 2>/dev/null; python3 --version; nginx -v 2>&1"
    [09-monitor-metricas.txt]="/usr/local/bin/citizentech-monitor --status; echo; cat /etc/citizentech/monitor.conf"
    [10-alertas.txt]="cat $LOG_DIR/alerts.log 2>/dev/null; echo; journalctl -t citizentech-monitor -t citizentech-guard --no-pager -n 50"
    [11-auditoria-scripts.txt]="tail -n 200 $AUDIT_LOG"
    [12-auditd.txt]="auditctl -l; echo; aureport -k -i --summary 2>/dev/null; echo; ausearch -k ct_config -i 2>/dev/null | tail -n 40"
    [13-recursos.txt]="uptime; free -h; df -h; echo; sar -u 1 3 2>/dev/null"
    [14-provision-log.txt]="tail -n 300 $PROVISION_LOG"
  )
  for c in "${!cmds[@]}"; do
    { echo "\$ ${cmds[$c]}"; echo; bash -c "${cmds[$c]}" 2>&1; } > "$EVID_DIR/$c" || true
  done
  printf '%s\n' "${RESULTS[@]}" "" "PASS=$PASS FAIL=$FAIL" > "$EVID_DIR/00-checklist.txt"
  [[ -n "${SUDO_USER:-}" ]] && chown -R "$SUDO_USER" "$PROJECT_ROOT/evidencias" 2>/dev/null || true
  info "Evidências salvas em $EVID_DIR"
}

banner "05 - VALIDAÇÃO E EVIDÊNCIAS"
step "checklist"  run_checks
step "evidencias" collect_evidence
printf '\n%s\n' "${RESULTS[@]}" >&2
printf '\nResultado: %s PASS / %s FAIL\n' "$PASS" "$FAIL" >&2
audit "resultado_validacao" "$([[ $FAIL -eq 0 ]] && echo OK || echo FAIL)" "pass=$PASS fail=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
ok "Ambiente 100% funcional: http://$APP_DOMAIN"
