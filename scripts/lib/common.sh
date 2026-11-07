#!/usr/bin/env bash
# =============================================================================
#  Biblioteca comum: configuração, logs de execução, trilha de auditoria e
#  tratamento de erros. Todos os scripts fazem "source" deste arquivo.
# =============================================================================
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config/citizentech.conf}"
export PROJECT_ROOT CONFIG_FILE

if [[ $EUID -ne 0 ]]; then
  echo "Este script precisa ser executado como root (use sudo)." >&2
  exit 1
fi

# shellcheck source=../../config/citizentech.conf
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

LOG_DIR="${LOG_DIR:-/var/log/citizentech}"
PROVISION_LOG="$LOG_DIR/provision.log"
AUDIT_LOG="$LOG_DIR/audit.log"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
CURRENT_STEP="inicio"
LAST_CMD=""
SCRIPT_START=$(date +%s)
export RUN_ID LOG_DIR DEBIAN_FRONTEND=noninteractive

mkdir -p "$LOG_DIR"
chmod 750 "$LOG_DIR"
touch "$PROVISION_LOG" "$AUDIT_LOG"
chmod 640 "$PROVISION_LOG" "$AUDIT_LOG"

if [[ -t 2 ]]; then
  C_RESET=$'\e[0m'; C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BOLD=$'\e[1m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""
fi

# ---------------------------------------------------------------------------
# Log de execução: arquivo + terminal + syslog/journald
# ---------------------------------------------------------------------------
_log() {
  local level="$1" color="$2" prio="$3"; shift 3
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') [$level] [$SCRIPT_NAME] [run=$RUN_ID] $*"
  echo "$line" >> "$PROVISION_LOG"
  printf '%s%s%s\n' "$color" "$line" "$C_RESET" >&2
  logger -t citizentech-provision -p "user.$prio" -- "[$SCRIPT_NAME] $*" 2>/dev/null || true
}
info()  { _log INFO  "$C_BLUE"   info    "$@"; }
ok()    { _log OK    "$C_GREEN"  notice  "$@"; }
warn()  { _log WARN  "$C_YELLOW" warning "$@"; }
error() { _log ERROR "$C_RED"    err     "$@"; }
die()   { error "$@"; audit "$CURRENT_STEP" FAIL "$*"; exit 1; }
banner(){ printf '\n%s==================== %s ====================%s\n' "$C_BOLD" "$*" "$C_RESET" >&2; info "$*"; }

# ---------------------------------------------------------------------------
# Trilha de auditoria: uma linha por ação, formato chave=valor (fácil de grep)
# ---------------------------------------------------------------------------
audit() {
  local action="$1" status="$2" detail="${3:-}"
  printf '%s|run=%s|user=%s|sudo_user=%s|host=%s|script=%s|action=%s|status=%s|detail=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$RUN_ID" "$(id -un)" "${SUDO_USER:--}" \
    "$(hostname)" "$SCRIPT_NAME" "$action" "$status" "$detail" >> "$AUDIT_LOG"
}

# Executa um comando, mandando a saída para o log de provisionamento.
run() {
  info "exec: $*"
  LAST_CMD="$*"
  "$@" >> "$PROVISION_LOG" 2>&1
  LAST_CMD=""
}

# Executa uma etapa (função) registrando início/fim na auditoria.
step() {
  local name="$1"; shift
  CURRENT_STEP="$name"
  info "==> $name"
  "$@"
  audit "$name" OK
  ok "<== $name concluído"
}

apt_updated=0
apt_update()  { [[ $apt_updated -eq 1 ]] || { run apt-get update -q; apt_updated=1; }; }
apt_install() { apt_update; run apt-get install -y -q --no-install-recommends "$@"; }

# Faz backup (uma única vez) de um arquivo de sistema antes de alterá-lo.
backup_once() {
  local f="$1"
  if [[ -f "$f" && ! -f "$f.orig-citizentech" ]]; then
    cp -a "$f" "$f.orig-citizentech"
    audit "backup" OK "$f"
  fi
}

# Define CHAVE=valor num arquivo .env (cria ou substitui).
set_kv() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

primary_iface() { ip -o route show default 2>/dev/null | awk '{print $5; exit}'; }
primary_ip()    { ip -o -4 addr show dev "$(primary_iface)" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }

# ---------------------------------------------------------------------------
# Tratamento de erro e encerramento
# ---------------------------------------------------------------------------
on_error() {
  local rc=$? line="$1" cmd="${LAST_CMD:-$2}"
  error "Falha (rc=$rc) na etapa '$CURRENT_STEP', linha $line: $cmd"
  error "Últimas linhas do log ($PROVISION_LOG):"
  tail -n 15 "$PROVISION_LOG" >&2 || true
  audit "$CURRENT_STEP" FAIL "rc=$rc linha=$line cmd=$cmd"
}
on_exit() {
  local rc=$?
  local dur=$(( $(date +%s) - SCRIPT_START ))
  if [[ $rc -eq 0 ]]; then audit "script_fim" OK "duracao=${dur}s"
  else audit "script_fim" FAIL "rc=$rc duracao=${dur}s"; fi
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR
trap on_exit EXIT

audit "script_inicio" OK "args=$* config=$CONFIG_FILE"
