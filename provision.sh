#!/usr/bin/env bash
# =============================================================================
#  CitizenTech - Orquestrador do provisionamento completo
#
#  sudo bash provision.sh                 # executa tudo (01 -> 05)
#  sudo bash provision.sh infra app       # executa só as etapas escolhidas
#  Etapas: infra | app | monitor | audit | validate
# =============================================================================
source "$(dirname "$0")/scripts/lib/common.sh"

declare -A STEPS=(
  [infra]="01-infra.sh"
  [app]="02-app.sh"
  [monitor]="03-monitoring.sh"
  [audit]="04-audit.sh"
  [validate]="05-validate.sh"
)
ORDER=(infra app monitor audit validate)
SELECTED=("$@"); [[ ${#SELECTED[@]} -eq 0 ]] && SELECTED=("${ORDER[@]}")

for s in "${SELECTED[@]}"; do
  [[ -n "${STEPS[$s]:-}" ]] || die "Etapa desconhecida: $s (use: ${ORDER[*]})"
done

banner "PROVISIONAMENTO CITIZENTECH - run=$RUN_ID"
info "Host: $(hostname) | SO: $(. /etc/os-release; echo "$PRETTY_NAME") | Etapas: ${SELECTED[*]}"
T0=$(date +%s)
declare -A DUR

for s in "${ORDER[@]}"; do
  [[ " ${SELECTED[*]} " == *" $s "* ]] || continue
  t=$(date +%s)
  CURRENT_STEP="$s"
  bash "$PROJECT_ROOT/scripts/${STEPS[$s]}"
  DUR[$s]=$(( $(date +%s) - t ))
  audit "etapa_$s" OK "duracao=${DUR[$s]}s"
done

banner "RESUMO"
for s in "${ORDER[@]}"; do [[ -n "${DUR[$s]:-}" ]] && printf '  %-10s OK  (%ss)\n' "$s" "${DUR[$s]}" >&2; done
printf '  %-10s %ss\n\n' "TOTAL" "$(( $(date +%s) - T0 ))" >&2
ok "Provisionamento concluído. Acesse: http://$APP_DOMAIN (ou http://$(primary_ip))"
info "Logs: $PROVISION_LOG | Auditoria: $AUDIT_LOG | Alertas: $LOG_DIR/alerts.log"
