#!/usr/bin/env bash
# =============================================================================
#  Falha controlada: um script que usa a mesma biblioteca de logs dos scripts
#  de provisionamento e falha de propósito (copia um arquivo que não existe).
#  Serve para provar que erros ficam registrados em provision.log, audit.log
#  e no journal, com etapa, linha, comando e código de saída.
#
#    sudo bash tools/falha-controlada.sh ; echo "código de saída: $?"
# =============================================================================
source "$(dirname "$0")/../scripts/lib/common.sh"

etapa_ok()     { run test -d /etc/citizentech; }
etapa_falha()  { run cp /etc/citizentech/arquivo-que-nao-existe.conf /tmp/; }

banner "TESTE - FALHA CONTROLADA"
step "verificar_diretorio_config" etapa_ok
step "copiar_config_inexistente"  etapa_falha
step "nunca_executada"            etapa_ok    # não deve rodar: o script para no erro anterior
