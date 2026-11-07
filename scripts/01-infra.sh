#!/usr/bin/env bash
# =============================================================================
#  01 - Provisionamento de infraestrutura
#  Hostname, IP (DHCP ou estático via netplan), DNS (systemd-resolved),
#  resolução local (/etc/hosts), fuso/NTP, pacotes base e firewall (UFW).
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

IFACE="${NET_IFACE:-$(primary_iface)}"

install_base_packages() {
  apt_install ca-certificates curl wget git jq bc rsync ufw dnsutils \
              net-tools iproute2 sysstat htop logrotate auditd audispd-plugins \
              stress-ng
}

configure_hostname() {
  local fqdn="$HOST_NAME.$DOMAIN"
  run hostnamectl set-hostname "$HOST_NAME"
  backup_once /etc/hosts
  sed -i '/# BEGIN CITIZENTECH/,/# END CITIZENTECH/d' /etc/hosts
  local app_ip
  app_ip="$(primary_ip)"
  [[ "$NET_MODE" == "static" ]] && app_ip="${STATIC_IP%/*}"
  cat >> /etc/hosts <<EOF
# BEGIN CITIZENTECH (gerado por $SCRIPT_NAME em $(date -Is))
127.0.1.1   $fqdn $HOST_NAME
${app_ip:-127.0.0.1}   $APP_DOMAIN
# END CITIZENTECH
EOF
  info "Hostname: $(hostnamectl --static) | FQDN: $fqdn | $APP_DOMAIN -> ${app_ip:-127.0.0.1}"
}

configure_network() {
  [[ -n "$IFACE" ]] || die "Não foi possível detectar a interface de rede (defina NET_IFACE)."
  info "Interface: $IFACE | modo: $NET_MODE"
  if [[ "$NET_MODE" == "static" ]]; then
    local np=/etc/netplan/60-citizentech.yaml dns_list
    dns_list="$(echo "$DNS_SERVERS" | sed 's/ /, /g')"
    {
      echo "# Gerado por $SCRIPT_NAME - $(date -Is)"
      echo "network:"
      echo "  version: 2"
      echo "  renderer: networkd"
      echo "  ethernets:"
      echo "    $IFACE:"
      echo "      dhcp4: false"
      echo "      addresses: [$STATIC_IP]"
      [[ -n "$STATIC_GW" ]] && { echo "      routes:"; echo "        - to: default"; echo "          via: $STATIC_GW"; }
      echo "      nameservers:"
      echo "        addresses: [$dns_list]"
      echo "        search: [$DOMAIN]"
    } > "$np"
    chmod 600 "$np"
    run netplan generate
    run netplan apply
    audit "netplan_static" OK "iface=$IFACE ip=$STATIC_IP gw=${STATIC_GW:--}"
  else
    info "Modo DHCP: IP atual mantido ($(primary_ip))."
  fi
  ip -br addr | tee -a "$PROVISION_LOG" >&2
}

configure_dns() {
  if systemctl is-active --quiet systemd-resolved; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/citizentech.conf <<EOF
# Gerado por $SCRIPT_NAME - $(date -Is)
[Resolve]
DNS=$DNS_SERVERS
FallbackDNS=$FALLBACK_DNS
Domains=$DOMAIN
DNSStubListener=yes
EOF
    run systemctl restart systemd-resolved
  else
    backup_once /etc/resolv.conf
    { echo "# Gerado por $SCRIPT_NAME"; echo "search $DOMAIN"
      for d in $DNS_SERVERS; do echo "nameserver $d"; done; } > /etc/resolv.conf
  fi
  # Teste de resolução externa e local
  local tries=0
  until getent hosts github.com >/dev/null; do
    tries=$((tries+1)); [[ $tries -ge 10 ]] && die "DNS externo não respondeu."
    sleep 2
  done
  getent hosts "$APP_DOMAIN" >/dev/null || die "Resolução local de $APP_DOMAIN falhou."
  ok "DNS OK: github.com -> $(getent hosts github.com | awk '{print $1; exit}') | $APP_DOMAIN -> $(getent hosts "$APP_DOMAIN" | awk '{print $1}')"
}

configure_time() {
  run timedatectl set-timezone "$TIMEZONE"
  run timedatectl set-ntp true || warn "NTP não pôde ser ativado (ambiente sem systemd-timesyncd?)."
  info "Data/hora: $(date) ($TIMEZONE)"
}

configure_firewall() {
  run ufw default deny incoming
  run ufw default allow outgoing
  for rule in $FIREWALL_ALLOW; do run ufw allow "$rule"; done
  run ufw --force enable
  ufw status verbose | tee -a "$PROVISION_LOG" >&2
}

configure_sysstat() {
  # Habilita coleta histórica de CPU/memória/disco (comando "sar")
  [[ -f /etc/default/sysstat ]] && sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
  run systemctl enable --now sysstat || warn "sysstat não iniciou."
}

banner "01 - INFRAESTRUTURA (rede, DNS, hostname, IP)"
step "pacotes_base"   install_base_packages
step "hostname"       configure_hostname
step "rede_ip"        configure_network
step "dns"            configure_dns
step "fuso_ntp"       configure_time
step "firewall"       configure_firewall
step "sysstat"        configure_sysstat
ok "Infraestrutura provisionada com sucesso."
