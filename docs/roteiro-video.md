# Roteiro do vídeo (máx. 7 minutos)

Antes de gravar, prepare dois terminais na VM e o navegador no host. Rode `vagrant destroy -f` antes para mostrar o provisionamento do zero.
Dica: com `vagrant up`, a instalação leva alguns minutos. Grave tudo e acelere (2x a 4x) os trechos de `apt-get` na edição.

| Tempo | O que mostrar | Comandos / tela |
|---|---|---|
| **0:00 – 0:30** | Apresentação: equipe, objetivo e arquitetura | README (diagrama) |
| **0:30 – 1:15** | Estrutura do repositório e configuração centralizada: rede, app e limites de alerta são todos variáveis | `tree -L 2`, `config/citizentech.conf` |
| **1:15 – 3:00** | **Provisionamento automático** de VM nova. Comente as etapas que aparecem no log: pacotes, hostname, IP, DNS, firewall, dependências, `app.env`, systemd, Nginx e health check | `vagrant up` (ou `sudo bash provision.sh`) |
| **3:00 – 3:40** | **Infra configurada** | `hostnamectl`, `ip -br a`, `resolvectl status`, `getent hosts app.citizentech.local`, `sudo ufw status` |
| **3:40 – 4:20** | **Aplicação hospedada** funcionando | Navegador `http://localhost:8080`, `curl http://app.citizentech.local/health`, `systemctl status citizentech-app`, `sudo cat /etc/citizentech/app.env` |
| **4:20 – 5:30** | **Monitoramento com alertas**: no terminal 1 rode `sudo tail -F /var/log/citizentech/alerts.log`, no terminal 2 gere carga e mostre WARNING/CRITICAL e depois RECOVERY | `sudo bash tools/simulate-load.sh cpu 40` · `sudo bash tools/simulate-load.sh mem 40` |
| **5:30 – 6:15** | **Tolerância a falhas**: matar o monitor (o PID muda e ele volta) e parar a aplicação (auto-heal) | `sudo bash tools/simulate-load.sh kill-monitor` · `sudo bash tools/simulate-load.sh stop-app` |
| **6:15 – 6:50** | **Auditoria e logs** + validação final 19/19 PASS | `sudo tail /var/log/citizentech/audit.log`, `sudo bash scripts/04-audit.sh --report`, `sudo bash provision.sh validate` |
| **6:50 – 7:00** | Conclusão | – |

## Falas-chave

- "Nenhuma configuração foi feita à mão: tudo vem do `provision.sh` e do arquivo `citizentech.conf`."
- "Os scripts são idempotentes: rodar de novo não quebra nada, só reaplica o estado desejado."
- "O monitor é um serviço systemd com reinício automático, e um guardião confere o heartbeat dele a cada minuto."
- "Cada etapa fica registrada com usuário, horário, status e duração, e o auditd registra quem alterou as configurações sensíveis."
