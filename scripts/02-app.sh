#!/usr/bin/env bash
# =============================================================================
#  02 - Provisionamento da aplicação
#  Baixa o código, detecta a stack (Python, Node, Java, .NET ou estático),
#  instala dependências, gera variáveis de ambiente, cria o serviço systemd
#  e publica atrás do Nginx (proxy reverso). Ao final faz health check.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

SRC_DIR="$APP_BASE/src"
APP_DIR="$SRC_DIR${APP_SUBDIR:+/$APP_SUBDIR}"
BIN_DIR="$APP_BASE/bin"
ENV_DIR="/etc/citizentech"
ENV_FILE="$ENV_DIR/app.env"
SERVICE="citizentech-app"
START_CMD=""

install_prereqs() {
  apt_install git rsync nginx curl ca-certificates unzip build-essential
}

create_app_user() {
  if ! id "$APP_USER" &>/dev/null; then
    run useradd --system --home-dir "$APP_BASE" --shell /usr/sbin/nologin "$APP_USER"
    audit "usuario_criado" OK "$APP_USER"
  fi
  mkdir -p "$APP_BASE" "$BIN_DIR" "$ENV_DIR"
}

fetch_code() {
  case "$APP_SOURCE" in
    git)
      [[ -n "$APP_REPO_URL" ]] || die "APP_SOURCE=git, mas APP_REPO_URL está vazio."
      git config --global --add safe.directory "$SRC_DIR" 2>/dev/null || true
      if [[ -d "$SRC_DIR/.git" ]]; then
        run git -C "$SRC_DIR" fetch --depth 1 origin "$APP_BRANCH"
        run git -C "$SRC_DIR" reset --hard FETCH_HEAD
      else
        rm -rf "$SRC_DIR"
        run git clone --depth 1 --branch "$APP_BRANCH" "$APP_REPO_URL" "$SRC_DIR"
      fi
      audit "codigo_git" OK "repo=$APP_REPO_URL branch=$APP_BRANCH commit=$(git -C "$SRC_DIR" rev-parse --short HEAD)"
      ;;
    local)
      local src="$APP_LOCAL_PATH"
      [[ "$src" = /* ]] || src="$PROJECT_ROOT/$src"
      [[ -d "$src" ]] || die "Pasta local da aplicação não encontrada: $src"
      mkdir -p "$SRC_DIR"
      run rsync -a --delete --exclude .git --exclude node_modules --exclude venv \
                --exclude target --exclude bin --exclude obj "$src/" "$SRC_DIR/"
      audit "codigo_local" OK "origem=$src"
      ;;
    *) die "APP_SOURCE inválido: $APP_SOURCE (use local ou git)";;
  esac
  [[ -d "$APP_DIR" ]] || die "APP_DIR não existe: $APP_DIR (verifique APP_SUBDIR)"
}

detect_type() {
  if [[ "$APP_TYPE" == "auto" ]]; then
    if   [[ -f "$APP_DIR/pom.xml" || -f "$APP_DIR/build.gradle" || -f "$APP_DIR/build.gradle.kts" ]]; then APP_TYPE=java
    elif compgen -G "$APP_DIR/*.csproj" >/dev/null || compgen -G "$APP_DIR/*/*.csproj" >/dev/null; then APP_TYPE=dotnet
    elif [[ -f "$APP_DIR/requirements.txt" || -f "$APP_DIR/pyproject.toml" ]]; then APP_TYPE=python
    elif [[ -f "$APP_DIR/package.json" ]]; then APP_TYPE=node
    elif [[ -f "$APP_DIR/index.html" ]]; then APP_TYPE=static
    else die "Não foi possível detectar o tipo da aplicação em $APP_DIR (defina APP_TYPE)."
    fi
  fi
  info "Tipo da aplicação: $APP_TYPE"
  audit "tipo_app" OK "$APP_TYPE"
}

ensure_node() {
  local cur
  cur="$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)"
  if [[ -z "$cur" || "$cur" -lt "$NODE_MAJOR" ]]; then
    run curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh
    run bash /tmp/nodesource_setup.sh
    # shellcheck disable=SC2034
    apt_updated=0; apt_install nodejs
  fi
  info "Node $(node -v) / npm $(npm -v)"
}

npm_deps() {
  if [[ -f "$APP_DIR/package-lock.json" ]]; then run npm --prefix "$APP_DIR" ci
  else run npm --prefix "$APP_DIR" install; fi
}

install_deps_python() {
  apt_install python3 python3-venv python3-pip python3-dev
  local venv="$APP_BASE/venv"
  [[ -d "$venv" ]] || run python3 -m venv "$venv"
  run "$venv/bin/pip" install --upgrade pip wheel
  if   [[ -f "$APP_DIR/requirements.txt" ]]; then run "$venv/bin/pip" install -r "$APP_DIR/requirements.txt"
  elif [[ -f "$APP_DIR/pyproject.toml"  ]]; then run "$venv/bin/pip" install "$APP_DIR"; fi
  run "$venv/bin/pip" install gunicorn
  "$venv/bin/pip" freeze > "$APP_BASE/dependencias-python.txt"
  START_CMD="$venv/bin/gunicorn --workers $GUNICORN_WORKERS --bind 127.0.0.1:$APP_PORT --access-logfile - $PYTHON_WSGI"
}

install_deps_node() {
  ensure_node
  npm_deps
  START_CMD="/usr/bin/npm start"
}

install_deps_java() {
  apt_install "openjdk-${JAVA_VERSION}-jdk-headless" maven
  local jar=""
  if [[ -f "$APP_DIR/pom.xml" ]]; then
    if [[ -f "$APP_DIR/mvnw" ]]; then chmod +x "$APP_DIR/mvnw"; (cd "$APP_DIR" && run ./mvnw -B -q -DskipTests package)
    else (cd "$APP_DIR" && run mvn -B -q -DskipTests package); fi
    jar="$(find "$APP_DIR/target" -maxdepth 1 -name '*.jar' ! -name '*original*' ! -name '*-plain.jar' | head -1)"
  else
    [[ -f "$APP_DIR/gradlew" ]] || die "Projeto Gradle sem gradlew."
    chmod +x "$APP_DIR/gradlew"; (cd "$APP_DIR" && run ./gradlew build -x test --no-daemon)
    jar="$(find "$APP_DIR/build/libs" -maxdepth 1 -name '*.jar' ! -name '*-plain.jar' | head -1)"
  fi
  [[ -n "$jar" ]] || die "Nenhum .jar gerado no build."
  START_CMD="/usr/bin/java $JAVA_OPTS -jar $jar --server.port=$APP_PORT --server.address=127.0.0.1"
}

install_deps_dotnet() {
  apt_install "dotnet-sdk-${DOTNET_VERSION}"
  export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_CLI_HOME=/tmp
  local proj
  proj="$(find "$APP_DIR" -maxdepth 2 -name '*.csproj' | head -1)"
  run dotnet publish "$proj" -c Release -o "$APP_BASE/publish"
  START_CMD="/usr/bin/dotnet $APP_BASE/publish/$(basename "$proj" .csproj).dll"
}

install_deps_static() {
  if [[ -f "$APP_DIR/package.json" && -n "$APP_BUILD_CMD" ]]; then ensure_node; npm_deps; fi
}

install_dependencies() {
  "install_deps_$APP_TYPE"
  if [[ -n "$APP_BUILD_CMD" ]]; then
    (cd "$APP_DIR" && run bash -c "$APP_BUILD_CMD")
    audit "build" OK "$APP_BUILD_CMD"
  fi
  [[ -n "$APP_START_CMD" ]] && START_CMD="$APP_START_CMD"
  chown -R "$APP_USER:$APP_USER" "$APP_BASE"
}

write_environment() {
  local tmp; tmp="$(mktemp)"
  [[ -f "$PROJECT_ROOT/config/app.env.example" ]] && cp "$PROJECT_ROOT/config/app.env.example" "$tmp"
  # Preserva valores já existentes no servidor (ex.: segredos colocados à mão)
  if [[ -f "$ENV_FILE" ]]; then
    while IFS='=' read -r k v; do
      [[ -z "$k" || "$k" == \#* ]] && continue
      grep -qE "^${k}=" "$tmp" || echo "$k=$v" >> "$tmp"
    done < "$ENV_FILE"
  fi
  set_kv "$tmp" PORT            "$APP_PORT"
  set_kv "$tmp" SERVER_PORT     "$APP_PORT"
  set_kv "$tmp" ASPNETCORE_URLS "http://127.0.0.1:$APP_PORT"
  set_kv "$tmp" APP_ENV         "$APP_ENV"
  set_kv "$tmp" NODE_ENV        "$APP_ENV"
  set_kv "$tmp" HOST            "127.0.0.1"
  install -m 640 -o root -g "$APP_USER" "$tmp" "$ENV_FILE"
  rm -f "$tmp"
  audit "variaveis_ambiente" OK "$ENV_FILE ($(grep -cvE '^\s*(#|$)' "$ENV_FILE") variáveis)"
}

write_service() {
  if [[ "$APP_TYPE" == "static" ]]; then
    info "Aplicação estática: servida direto pelo Nginx (sem serviço de backend)."
    systemctl disable --now "$SERVICE" &>/dev/null || true
    return
  fi
  cat > "$BIN_DIR/start-app.sh" <<EOF
#!/usr/bin/env bash
# Gerado por $SCRIPT_NAME - $(date -Is)
set -a; source $ENV_FILE; set +a
cd $APP_DIR
exec $START_CMD
EOF
  chmod 750 "$BIN_DIR/start-app.sh"; chown root:"$APP_USER" "$BIN_DIR/start-app.sh"

  cat > "/etc/systemd/system/$SERVICE.service" <<EOF
# Gerado por $SCRIPT_NAME - $(date -Is)
[Unit]
Description=CitizenTech - Aplicação Web ($APP_TYPE)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_DIR/start-app.sh
Restart=always
RestartSec=5
TimeoutStartSec=120
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable "$SERVICE"
  run systemctl restart "$SERVICE"
  audit "servico_app" OK "cmd=$START_CMD"
}

configure_nginx() {
  local conf=/etc/nginx/sites-available/citizentech
  if [[ "$APP_TYPE" == "static" ]]; then
    local root="${STATIC_ROOT:+$APP_DIR/$STATIC_ROOT}"
    if [[ -z "$root" ]]; then
      for d in dist build public .; do [[ -f "$APP_DIR/$d/index.html" ]] && { root="$APP_DIR/$d"; break; }; done
    fi
    [[ -n "$root" ]] || die "index.html não encontrado para app estático."
    chmod o+x "$APP_BASE" "$SRC_DIR"
    cat > "$conf" <<EOF
# Gerado por $SCRIPT_NAME - $(date -Is)
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $APP_DOMAIN $HOST_NAME _;
    root $root;
    index index.html;
    access_log /var/log/nginx/citizentech_access.log;
    error_log  /var/log/nginx/citizentech_error.log;
    location = /health { access_log off; default_type application/json; return 200 '{"status":"ok"}'; }
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF
  else
    cat > "$conf" <<EOF
# Gerado por $SCRIPT_NAME - $(date -Is)
upstream citizentech_backend { server 127.0.0.1:$APP_PORT; keepalive 16; }
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $APP_DOMAIN $HOST_NAME _;
    client_max_body_size 20m;
    access_log /var/log/nginx/citizentech_access.log;
    error_log  /var/log/nginx/citizentech_error.log;
    location / {
        proxy_pass http://citizentech_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF
  fi
  rm -f /etc/nginx/sites-enabled/default
  ln -sf "$conf" /etc/nginx/sites-enabled/citizentech
  run nginx -t
  run systemctl enable nginx
  run systemctl restart nginx
}

health_check() {
  local url_local="http://127.0.0.1:$APP_PORT$APP_HEALTH_PATH" i
  if [[ "$APP_TYPE" != "static" ]]; then
    info "Aguardando a aplicação responder em $url_local ..."
    for i in $(seq 1 60); do
      curl -fsS -o /dev/null -m 3 "$url_local" && break
      [[ $i -eq 60 ]] && { journalctl -u "$SERVICE" -n 30 --no-pager >&2; die "Aplicação não respondeu em 120s."; }
      sleep 2
    done
    ok "Backend respondeu após ~$((i*2))s."
  fi
  local code=""
  for i in $(seq 1 15); do   # o Nginx leva alguns instantes para aplicar a nova configuração
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -H "Host: $APP_DOMAIN" "http://127.0.0.1$APP_HEALTH_PATH")"
    [[ "$code" =~ ^(2|3) ]] && break
    sleep 1
  done
  [[ "$code" =~ ^(2|3) ]] || die "Nginx devolveu HTTP $code para $APP_HEALTH_PATH"
  ok "Aplicação publicada: http://$APP_DOMAIN  (HTTP $code via Nginx)"
  audit "health_check" OK "http=$code"
}

banner "02 - APLICAÇÃO (código, dependências, configuração, serviço)"
step "pre_requisitos"     install_prereqs
step "usuario_app"        create_app_user
step "codigo_fonte"       fetch_code
step "deteccao_stack"     detect_type
step "dependencias"       install_dependencies
step "variaveis_ambiente" write_environment
step "servico_systemd"    write_service
step "nginx"              configure_nginx
step "health_check"       health_check
ok "Aplicação provisionada com sucesso."
