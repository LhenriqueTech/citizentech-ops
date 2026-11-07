# CitizenTech · Provisionamento automatizado em Linux

Projeto de **Operating Systems** (Global Solution). Um único comando cria a infraestrutura de uma VM Linux, instala e configura a aplicação web da nossa CitizenTech, a **Central de Controle do Semáforo Inteligente**, liga o monitoramento com alertas e registra tudo em logs de auditoria. Nada é feito à mão.

🎬 **Vídeo de demonstração (6 min):** [`docs/CitizenTech-GS-OperatingSystems.mp4`](docs/CitizenTech-GS-OperatingSystems.mp4). Todas as telas de terminal e do navegador são capturas reais da VM; a narração foi gerada com voz sintética (ElevenLabs).

```bash
sudo bash provision.sh
```

---

## 1. O percurso da equipe

| Etapa do enunciado | O que este projeto faz | Script |
|---|---|---|
| **01 · Preparar o ambiente** | Prepara a VM Ubuntu do zero para receber qualquer app web (Python, Node, Java, .NET ou estático). | `provision.sh` + `Vagrantfile` |
| **02 · A aplicação hospedada** | Baixa o código, detecta a stack, instala dependências, gera variáveis de ambiente, cria o serviço e publica no Nginx. | `scripts/02-app.sh` |
| **03 · A infraestrutura** | Configura rede/IP, DNS, hostname, firewall, monitoramento e auditoria. | `scripts/01-infra.sh`, `03-monitoring.sh`, `04-audit.sh` |
| **04 · Resultados e conclusão** | Valida tudo de ponta a ponta (checklist PASS/FAIL) e salva evidências técnicas. | `scripts/05-validate.sh` |

## 2. Atendimento aos critérios de avaliação (10 pts)

| Critério | Pts | Onde está |
|---|---|---|
| Script de provisionamento de infra (redes, DNS, IP) | 2 | `scripts/01-infra.sh`: hostname + FQDN, `/etc/hosts`, IP DHCP ou **estático via netplan**, DNS via `systemd-resolved`, teste de resolução, fuso/NTP, firewall UFW |
| Script de provisionamento da aplicação (dependências, configurações, orquestração) | 2 | `scripts/02-app.sh`: detecção da stack, runtimes e dependências, `/etc/citizentech/app.env`, serviço `systemd`, Nginx como proxy reverso e health check. `provision.sh` orquestra as etapas na ordem. |
| Script de monitoramento com alertas de CPU, Disco e Memória | 2 | `monitoring/citizentech-monitor.sh`: limites de aviso e crítico, alerta de recuperação, cooldown anti-spam, alertas em arquivo + syslog + `wall` + webhook (Teams/Slack/Discord); também checa serviços e HTTP |
| Monitoramento como serviço tolerante a falhas | 1 | `systemd/citizentech-monitor.service` (`Restart=always`, sem limite de reinícios, `OOMScoreAdjust=-900`, habilitado no boot) + **guardião** `citizentech-monitor-guard.timer`, que reinicia o monitor se ele travar (heartbeat). O monitor também faz *auto-heal* da aplicação e do Nginx. |
| Logs de auditoria e execução dos scripts | 1 | `scripts/lib/common.sh` grava cada etapa em `/var/log/citizentech/provision.log` (execução) e `/var/log/citizentech/audit.log` (quem, quando, o quê, OK/FAIL, duração). `04-audit.sh` configura o **auditd**, deixa o journald persistente, ativa a rotação de logs e gera o relatório. |
| Funcionamento completo da proposta | 2 | `scripts/05-validate.sh`: 19 verificações automáticas + evidências em `evidencias/<data>/` |

## 3. Arquitetura

```mermaid
flowchart LR
  U["Usuário / navegador"] -->|"HTTP :80"| N["Nginx (proxy reverso)"]
  subgraph VM["VM Ubuntu 22.04 - citizentech-srv01"]
    N -->|"127.0.0.1:5000"| A["citizentech-app.service<br/>Gunicorn / Node / Java / .NET"]
    A --- E["/etc/citizentech/app.env"]
    M["citizentech-monitor.service"] -->|"CPU, memória, disco, HTTP"| A
    M -->|"alertas"| L[("/var/log/citizentech<br/>alerts, metrics, audit")]
    M -->|"auto-heal"| A
    G["guard.timer (1 min)"] -->|"heartbeat"| M
    AU["auditd"] --> L
  end
```

## 3.1 A aplicação: Semáforo Inteligente

A CitizenTech da equipe é um **sistema de semáforos adaptativos**: cada cruzamento mede as filas por via e a Central decide o tempo de verde, em vez do ciclo fixo. Ambulâncias ganham **ondas verdes**. A pasta `app/` contém a **Central de Controle** que esta infraestrutura hospeda:

| Recurso | Detalhe |
|---|---|
| Dashboard web (`/`) | Cruzamentos em tempo real: filas N/S/L/O, semáforo, tempo restante, modo (adaptativo, onda verde, segurança), eventos e KPIs |
| API REST | `GET /api/cruzamentos`, `GET /api/cruzamentos/<id>`, `GET /api/metricas`, `GET /api/eventos`, `POST /api/sensores`, `POST /api/emergencias` |
| Algoritmo | Divide o ciclo (`CICLO_S`) entre NS e LO proporcionalmente às filas, respeitando o verde mínimo (`VERDE_MIN_S`); calcula a redução de espera em relação ao ciclo fixo |
| Segurança da API | `POST` exigem `Authorization: Bearer $API_TOKEN` (token em `/etc/citizentech/app.env`, permissão 640) |
| Persistência | Banco SQLite em `/var/lib/citizentech` (`DATA_DIR`), fora do código e preservado entre deploys |
| Sensores | Simulador embutido (um único worker do Gunicorn o executa, via `flock`) + `app/sensor_simulado.py`, que faz o papel do Raspberry de um cruzamento |
| Tolerância a falhas | Se um sensor para de enviar dados por 20 s, o cruzamento entra em **modo de segurança** (ciclo fixo) e volta sozinho quando os dados retornam |

```bash
# dentro da VM (vagrant ssh)
curl -s http://app.citizentech.local/api/metricas | jq
TOKEN=$(sudo grep ^API_TOKEN= /etc/citizentech/app.env | cut -d= -f2)
python3 /opt/citizentech/src/sensor_simulado.py C04 --url http://app.citizentech.local --token $TOKEN
curl -s -X POST http://app.citizentech.local/api/emergencias -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' -d '{"rota":["C01","C02","C03"],"duracao_s":40}'
```

## 4. Estrutura do repositório

```
.
├── provision.sh                 # orquestrador (executa 01 → 05)
├── Vagrantfile                  # VM Ubuntu 22.04 provisionada automaticamente
├── config/
│   ├── citizentech.conf         # TODAS as variáveis (rede, app, limites de alerta)
│   └── app.env.example          # modelo das variáveis de ambiente da aplicação
├── scripts/
│   ├── lib/common.sh            # logs, auditoria, tratamento de erro
│   ├── 01-infra.sh              # rede, IP, DNS, hostname, firewall, NTP
│   ├── 02-app.sh                # dependências, configuração, serviço, Nginx
│   ├── 03-monitoring.sh         # instala o monitor como serviço + teste de falha
│   ├── 04-audit.sh              # auditd, journald, logrotate, relatório
│   └── 05-validate.sh           # checklist + coleta de evidências
├── monitoring/
│   ├── citizentech-monitor.sh   # monitor de CPU/Memória/Disco/serviços/HTTP
│   └── citizentech-monitor-guard.sh
├── systemd/                     # units do monitor e do guardião
├── tools/simulate-load.sh       # provoca falhas e carga para a demonstração
├── app/                         # Semáforo Inteligente: API + dashboard (Flask, SQLite) + sensor_simulado.py
├── docs/                        # vídeo de demonstração + roteiro
└── evidencias/                  # saídas geradas pelo 05-validate.sh
```

## 5. Como executar

### Opção A: Vagrant + VirtualBox (recomendado, 100% automático)

```bash
git clone https://github.com/LhenriqueTech/citizentech-ops.git && cd citizentech-ops
vagrant up            # cria a VM e roda o provision.sh sozinho
```
Acesse **http://localhost:8080** ou **http://192.168.56.10**. Para repetir o provisionamento, rode `vagrant provision` (os scripts são idempotentes).

### Atalho no Windows (instala tudo sozinho)

Dê dois cliques em **`INSTALAR-E-SUBIR-VM.bat`**. Ele pede permissão de administrador e faz o resto:

1. Instala o VirtualBox e o Vagrant, se faltarem. Os instaladores precisam estar na pasta Downloads.
2. Gera um diagnóstico de virtualização em `diagnostico.txt`.
3. Roda `vagrant up`. Se a VM já existir, roda `vagrant provision`.

O andamento fica em `setup-windows.log` e em `vagrant-up.log`.

> Se o Windows estiver com a Plataforma de Máquina Virtual ou o Hyper-V ligados, o VirtualBox roda em modo de compatibilidade (NEM), que é mais lento mas funciona. O Vagrantfile já aumenta o tempo de espera do boot (`boot_timeout = 900`) e grava o console serial da VM em `vm-console.log`.

### Opção B: VM Ubuntu 22.04/24.04 já existente

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/LhenriqueTech/citizentech-ops.git && cd citizentech-ops
sudo bash provision.sh                    # tudo
sudo bash provision.sh infra app          # só algumas etapas
```

Etapas disponíveis: `infra`, `app`, `monitor`, `audit` e `validate`.

## 6. Trocando ou adicionando aplicações

Por padrão o provisionamento hospeda o Semáforo Inteligente de `app/`. Para hospedar outra parte da CitizenTech (por exemplo, a API Spring Boot ou o dashboard .NET de outra disciplina), edite `config/citizentech.conf` (ou passe as variáveis na linha de comando). A stack é detectada automaticamente pelos arquivos do projeto:

| Arquivo encontrado | Stack | Como sobe |
|---|---|---|
| `pom.xml` / `build.gradle` | Java (Spring Boot) | `mvn package` → `java -jar ... --server.port=$APP_PORT` |
| `*.csproj` | .NET | `dotnet publish` → `dotnet App.dll` (via `ASPNETCORE_URLS`) |
| `requirements.txt` / `pyproject.toml` | Python | venv + `pip install` → Gunicorn (`PYTHON_WSGI=app:app`) |
| `package.json` | Node.js | NodeSource + `npm ci` → `npm start` (lê `PORT`) |
| `index.html` | Estático / SPA | Nginx serve `dist/`, `build/` ou `public/` |

Exemplos:

```bash
# Spring Boot que está na pasta backend/ de outro repositório
sudo APP_SOURCE=git APP_REPO_URL=https://github.com/equipe/citizentech-java.git \
     APP_SUBDIR=backend APP_PORT=8080 APP_HEALTH_PATH=/actuator/health bash provision.sh

# Front-end React/Vite (build gerado e servido pelo Nginx)
sudo APP_SOURCE=git APP_REPO_URL=https://github.com/equipe/citizentech-web.git \
     APP_TYPE=static APP_BUILD_CMD="npm run build" bash provision.sh

# API Node que não tem /health
sudo APP_SOURCE=git APP_REPO_URL=https://github.com/equipe/citizentech-api.git APP_HEALTH_PATH=/ bash provision.sh
```

`config/app.env.example` é o modelo versionado (sem segredos). Segredos reais (URL de banco, chaves de API) vão direto em `/etc/citizentech/app.env` na VM. Esse arquivo tem permissão `640` e os valores que já estão no servidor são preservados quando o provisionamento roda de novo.

## 7. Monitoramento e alertas

| Recurso | Aviso | Crítico | Ação |
|---|---|---|---|
| CPU | 70% | 90% | alerta + recuperação |
| Memória | 75% | 90% | alerta + recuperação |
| Disco (`/`) | 80% | 90% | alerta + recuperação |
| Serviços (`citizentech-app`, `nginx`) | – | parado | alerta + **reinício automático** |
| HTTP `/health` | – | falha | alerta |

Os limites e o intervalo ficam em `config/citizentech.conf` e são gravados em `/etc/citizentech/monitor.conf`. Depois de editar, rode `systemctl reload citizentech-monitor`.

Onde aparecem os alertas:

- `/var/log/citizentech/alerts.log`: um alerta por linha.
- `/var/log/citizentech/metrics.log`: histórico de coletas.
- `journalctl -t citizentech-monitor`: syslog, com prioridade `crit` ou `warning`.
- `wall`: alertas críticos aparecem no terminal de quem estiver logado.
- Webhook: preencha `ALERT_WEBHOOK_URL` com a URL de entrada do Teams, Slack ou Discord.

```bash
citizentech-monitor --status       # últimas métricas, alertas e heartbeat
citizentech-monitor --once         # uma coleta agora
```

### Tolerância a falhas

| Falha | Quem recupera | Como demonstrar |
|---|---|---|
| Monitor morto (`kill -9`, crash) | systemd, com `Restart=always` em 5 s | `sudo bash tools/simulate-load.sh kill-monitor` |
| Monitor travado (sem heartbeat) | guardião (`timer` a cada 1 min) | `sudo bash tools/simulate-load.sh hang-monitor` |
| Aplicação ou Nginx parados | auto-heal do monitor + `Restart=always` | `sudo bash tools/simulate-load.sh stop-app` |
| Falta de memória | `OOMScoreAdjust=-900` (o kernel mata outros processos antes do monitor) | – |
| Reboot da VM | todos os serviços habilitados no boot | `sudo reboot` |

Para gerar carga e ver os alertas: `sudo bash tools/simulate-load.sh cpu 60`, `mem 60` ou `disk 30`.

## 8. Logs de auditoria e execução

| Arquivo | Conteúdo |
|---|---|
| `/var/log/citizentech/provision.log` | Execução detalhada: cada comando executado e a saída dele |
| `/var/log/citizentech/audit.log` | Trilha de auditoria: `data\|run\|user\|sudo_user\|host\|script\|action\|status\|detail` |
| `/var/log/citizentech/relatorio-auditoria-*.txt` | Relatório consolidado (`sudo bash scripts/04-audit.sh --report`) |
| `auditd` (`ausearch -k ct_config -i`) | Quem alterou rede, DNS, Nginx, serviços, `app.env` e usuários |
| `journalctl -t citizentech-provision` | As mesmas mensagens dos scripts, no journal persistente |

Os logs passam por rotação diária, com 14 dias de retenção e compressão (`/etc/logrotate.d/citizentech`).

```bash
grep 'status=FAIL' /var/log/citizentech/audit.log           # falhas
grep 'run=<RUN_ID>' /var/log/citizentech/audit.log          # uma execução inteira
sudo aureport -k -i --summary                               # resumo do auditd
```

## 9. Evidências técnicas

`sudo bash provision.sh validate` (ou `sudo bash scripts/05-validate.sh`) cria `evidencias/<data-hora>/` com o checklist e as saídas de `hostnamectl`, `ip`, `resolvectl`, `ufw`, `systemctl status`, `curl`, métricas, alertas, auditoria e `auditd`. Faça commit dessa pasta junto com o repositório.

### Resultado da execução de referência

Execução em 07/11/2026 numa VM Ubuntu 22.04 (VirtualBox 7.2.22 + Vagrant 2.4.9, Windows 11), já com o Semáforo Inteligente: **19 PASS / 0 FAIL**. As evidências estão em [`evidencias/20261107-181221/`](evidencias/20261107-181221/00-checklist.txt).

## 10. Solução de problemas

| Sintoma | Verifique |
|---|---|
| Etapa falhou | A mensagem mostra a etapa, a linha e as últimas linhas de `provision.log` |
| App não sobe | `journalctl -u citizentech-app -n 50` · confira `APP_PORT` e `APP_HEALTH_PATH` |
| 502 Bad Gateway | o app precisa escutar em `127.0.0.1:$APP_PORT` (use as variáveis `PORT`/`SERVER_PORT`) |
| DNS falha | `resolvectl status` · troque `DNS_SERVERS` |
| `vagrant up` para em "Waiting for machine to boot" | Veja `diagnostico.txt` e `vm-console.log`. Com o Hyper-V ligado, o boot é mais lento. |
| IP estático sem rede | use `NET_MODE=static` apenas na interface *host-only* (`NET_IFACE`) |

---
## Integrantes

| Nome | RM |
|---|---|
| Léo Masago | RM557768 |
| Eduardo Tomazela | RM556807 |
| Luiz Henrique | RM555235 |
