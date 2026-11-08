# Capturas de tela

Telas reais do ambiente (VM Ubuntu 22.04 `citizentech-srv01`, VirtualBox + Vagrant no Windows 11).

| Arquivo | O que mostra |
|---|---|
| `01-provisionamento-automatico.jpg` | Log do `provision.sh` executando as 5 etapas até `19 PASS / 0 FAIL` |
| `02-infra-rede-dns-hostname-firewall.jpg` | hostname, IP, `/etc/hosts`, DNS (systemd-resolved), UFW e fuso/NTP |
| `03-aplicacao-servico-systemd.jpg` | `citizentech-app.service` ativo, `/health`, variáveis (mascaradas), diretório de dados e dependências |
| `04-api-semaforo-inteligente.jpg` | API REST: métricas, sensor de borda, modo de segurança, token e onda verde |
| `05-dashboard-semaforo-inteligente.jpg` | Dashboard da Central no navegador (`localhost:8080`) |
| `06-dashboard-onda-verde-ambulancia.jpg` | Dashboard com onda verde ativa para ambulância |
| `07-monitor-servico-systemd.jpg` | Monitor rodando como serviço, guardião (timer) e limites |
| `08-alerta-cpu.jpg` | CPU a 100% → CRITICAL → RECOVERY |
| `09-alerta-memoria.jpg` | Memória a 80% → WARNING → RECOVERY |
| `10-alerta-disco.jpg` | Disco a 83% → WARNING → RECOVERY |
| `11-tolerancia-falhas-kill-autoheal.jpg` | `kill -9` no monitor (novo PID) e auto-heal da aplicação |
| `12-logs-auditoria.jpg` | `audit.log`, `provision.log`, regras e relatório do auditd |
| `13-validacao-19-pass.jpg` | Checklist final: 19 PASS / 0 FAIL |
| `14-teste-falha-script.jpg` | Falha controlada em script registrada nos logs |
| `15-teste-monitor-parado.jpg` | `systemctl stop` no monitor e recuperação pelo guardião |
| `16-teste-reboot-vm.jpg` | Serviços ativos depois da reinicialização da VM |
