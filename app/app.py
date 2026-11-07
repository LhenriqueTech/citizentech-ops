"""
CitizenTech · Semáforo Inteligente — Central de Controle

Aplicação web da solução CitizenTech: semáforos adaptativos que ajustam o tempo
de verde conforme a fila em cada via e abrem "ondas verdes" para ambulâncias.

- API REST (/api/...) para sensores, cruzamentos, emergências e métricas
- Banco SQLite em DATA_DIR (persistente, fora do código)
- Simulador de sensores embutido (um único worker o executa, via lock de arquivo)
- Dashboard web em tempo real (/)

Configuração por variáveis de ambiente (ver config/app.env.example).
"""
import fcntl
import math
import os
import random
import socket
import sqlite3
import threading
import time
from datetime import datetime

from flask import Flask, abort, jsonify, render_template, request

# ----------------------------------------------------------------------------- configuração
APP_NAME = os.getenv("APP_NAME", "CitizenTech")
APP_ENV = os.getenv("APP_ENV", "dev")
CIDADE = os.getenv("CIDADE", "São Paulo")
DATA_DIR = os.getenv("DATA_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "data"))
NUM_CRUZAMENTOS = int(os.getenv("NUM_CRUZAMENTOS", "6"))
CICLO_S = int(os.getenv("CICLO_S", "90"))            # duração total de um ciclo (NS + LO)
VERDE_MIN_S = int(os.getenv("VERDE_MIN_S", "15"))
SIMULADOR = os.getenv("SIMULADOR", "on").lower() == "on"
TICK_S = float(os.getenv("SIM_TICK_S", "2"))
API_TOKEN = os.getenv("API_TOKEN", "")               # se definido, exigido nos POST da API
DB_PATH = os.path.join(DATA_DIR, "semaforos.db")
VERSAO = "1.0.0"
STARTED = time.time()

CRUZAMENTOS = [
    ("C01", "Av. Paulista × R. Augusta"),
    ("C02", "Av. Paulista × Av. Brig. Luís Antônio"),
    ("C03", "Av. Rebouças × Av. Brasil"),
    ("C04", "Av. Faria Lima × Av. Juscelino K."),
    ("C05", "R. da Consolação × Av. Ipiranga"),
    ("C06", "Av. 23 de Maio × Av. Brasil"),
    ("C07", "Av. Sumaré × Av. Pacaembu"),
    ("C08", "Av. Ibirapuera × Av. Santo Amaro"),
][:max(1, min(8, NUM_CRUZAMENTOS))]

VIAS = ("N", "S", "L", "O")
app = Flask(__name__)


# ----------------------------------------------------------------------------- banco de dados
def db():
    os.makedirs(DATA_DIR, exist_ok=True)
    con = sqlite3.connect(DB_PATH, timeout=10)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    return con


def init_db():
    with db() as con:
        con.executescript("""
        CREATE TABLE IF NOT EXISTS cruzamentos (
            id TEXT PRIMARY KEY, nome TEXT NOT NULL,
            modo TEXT NOT NULL DEFAULT 'adaptativo',        -- adaptativo | emergencia | seguranca
            fase TEXT NOT NULL DEFAULT 'NS',                -- via com verde: NS ou LO
            fase_inicio REAL NOT NULL DEFAULT 0,
            verde_ns INTEGER NOT NULL DEFAULT 45, verde_lo INTEGER NOT NULL DEFAULT 45,
            fila_n INTEGER DEFAULT 0, fila_s INTEGER DEFAULT 0, fila_l INTEGER DEFAULT 0, fila_o INTEGER DEFAULT 0,
            fluxo INTEGER DEFAULT 0, ultima_leitura REAL DEFAULT 0, origem TEXT DEFAULT 'simulador',
            emergencia_ate REAL DEFAULT 0, emergencia_fase TEXT DEFAULT NULL
        );
        CREATE TABLE IF NOT EXISTS eventos (
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL,
            cruzamento TEXT, tipo TEXT NOT NULL, mensagem TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS leituras (
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, cruzamento TEXT NOT NULL,
            fila_total INTEGER NOT NULL, espera_adaptativa REAL NOT NULL, espera_fixa REAL NOT NULL
        );
        """)
        for cid, nome in CRUZAMENTOS:
            con.execute("INSERT OR IGNORE INTO cruzamentos (id, nome, fase_inicio) VALUES (?, ?, ?)",
                        (cid, nome, time.time()))


def evento(con, tipo, mensagem, cruzamento=None):
    con.execute("INSERT INTO eventos (ts, cruzamento, tipo, mensagem) VALUES (?, ?, ?, ?)",
                (time.time(), cruzamento, tipo, mensagem))
    con.execute("DELETE FROM eventos WHERE id < (SELECT MAX(id) - 500 FROM eventos)")


# ----------------------------------------------------------------------------- regra de decisão
def calcular_verdes(filas):
    """Divide o ciclo entre NS e LO proporcionalmente às filas (com verde mínimo)."""
    ns = filas["N"] + filas["S"]
    lo = filas["L"] + filas["O"]
    total = ns + lo
    if total == 0:
        return CICLO_S // 2, CICLO_S - CICLO_S // 2
    v_ns = round(CICLO_S * ns / total)
    v_ns = max(VERDE_MIN_S, min(CICLO_S - VERDE_MIN_S, v_ns))
    return v_ns, CICLO_S - v_ns


def espera_estimada(filas, v_ns, v_lo):
    """Espera média aproximada (s): cada veículo aguarda, em média, metade do vermelho da sua via."""
    ns, lo = filas["N"] + filas["S"], filas["L"] + filas["O"]
    return (ns * v_lo / 2 + lo * v_ns / 2) / max(1, ns + lo)


def aplicar_leitura(con, cid, filas, fluxo, origem):
    row = con.execute("SELECT * FROM cruzamentos WHERE id=?", (cid,)).fetchone()
    if row is None:
        abort(404, description=f"cruzamento {cid} não existe")
    v_ns, v_lo = calcular_verdes(filas)
    con.execute("""UPDATE cruzamentos SET fila_n=?, fila_s=?, fila_l=?, fila_o=?, fluxo=?,
                   verde_ns=?, verde_lo=?, ultima_leitura=?, origem=? WHERE id=?""",
                (filas["N"], filas["S"], filas["L"], filas["O"], fluxo, v_ns, v_lo, time.time(), origem, cid))
    fixa = espera_estimada(filas, CICLO_S // 2, CICLO_S // 2)
    adapt = espera_estimada(filas, v_ns, v_lo)
    con.execute("INSERT INTO leituras (ts, cruzamento, fila_total, espera_adaptativa, espera_fixa) VALUES (?,?,?,?,?)",
                (time.time(), cid, sum(filas.values()), adapt, fixa))
    con.execute("DELETE FROM leituras WHERE ts < ?", (time.time() - 900,))
    if row["modo"] == "seguranca":
        con.execute("UPDATE cruzamentos SET modo='adaptativo' WHERE id=?", (cid,))
        evento(con, "recuperacao", f"{row['nome']}: sensores voltaram, modo adaptativo retomado", cid)
    return v_ns, v_lo


def avancar_fases(con):
    """Troca a fase de cada cruzamento quando o verde atual termina; trata emergências e modo de segurança."""
    agora = time.time()
    for r in con.execute("SELECT * FROM cruzamentos").fetchall():
        if r["modo"] == "emergencia":
            if agora >= r["emergencia_ate"]:
                con.execute("UPDATE cruzamentos SET modo='adaptativo', emergencia_fase=NULL, fase_inicio=? WHERE id=?",
                            (agora, r["id"]))
                evento(con, "onda_verde", f"{r['nome']}: ambulância passou, voltando ao modo adaptativo", r["id"])
            continue
        # sem leitura há mais de 20 s: modo de segurança (ciclo fixo tradicional)
        if r["modo"] == "adaptativo" and agora - r["ultima_leitura"] > 20:
            con.execute("UPDATE cruzamentos SET modo='seguranca', verde_ns=?, verde_lo=? WHERE id=?",
                        (CICLO_S // 2, CICLO_S - CICLO_S // 2, r["id"]))
            evento(con, "alerta", f"{r['nome']}: sem dados dos sensores, ciclo fixo de segurança", r["id"])
            continue
        dur = r["verde_ns"] if r["fase"] == "NS" else r["verde_lo"]
        if agora - r["fase_inicio"] >= dur:
            nova = "LO" if r["fase"] == "NS" else "NS"
            con.execute("UPDATE cruzamentos SET fase=?, fase_inicio=? WHERE id=?", (nova, agora, r["id"]))


# ----------------------------------------------------------------------------- simulador de sensores
def _hora_pico_fator():
    h = datetime.now().hour + datetime.now().minute / 60
    return 0.6 + 0.8 * (math.exp(-((h - 8) ** 2) / 3) + math.exp(-((h - 18) ** 2) / 3))


def simulador():
    estado = {cid: {v: random.randint(3, 15) for v in VIAS} for cid, _ in CRUZAMENTOS}
    # cada cruzamento tem uma via "principal" mais carregada
    peso = {cid: dict(zip(VIAS, random.sample([1.6, 1.3, 0.8, 0.6], 4))) for cid, _ in CRUZAMENTOS}
    while True:
        try:
            with db() as con:
                pico = _hora_pico_fator()
                for cid, _ in CRUZAMENTOS:
                    r = con.execute("SELECT * FROM cruzamentos WHERE id=?", (cid,)).fetchone()
                    if r["origem"] == "sensor":
                        continue  # cruzamento com sensor externo (sensor_simulado.py): o simulador não interfere
                    verde = ("N", "S") if r["fase"] == "NS" else ("L", "O")
                    if r["modo"] == "emergencia":
                        verde = ("N", "S") if r["emergencia_fase"] == "NS" else ("L", "O")
                    f = estado[cid]
                    for v in VIAS:
                        chegada = random.random() * 2.3 * pico * peso[cid][v]
                        saida = random.uniform(2.5, 4.5) if v in verde else 0
                        f[v] = int(max(0, min(60, f[v] + chegada - saida)))
                    aplicar_leitura(con, cid, dict(f), int(sum(f.values()) * 2.4 * pico), "simulador")
                avancar_fases(con)
        except Exception as exc:  # o simulador nunca deve derrubar a aplicação
            app.logger.warning("simulador: %s", exc)
        time.sleep(TICK_S)


def iniciar_simulador():
    """Só um processo (worker do Gunicorn) roda o simulador: quem obtiver o lock."""
    if not SIMULADOR:
        return
    os.makedirs(DATA_DIR, exist_ok=True)
    fh = open(os.path.join(DATA_DIR, "simulador.lock"), "w")
    try:
        fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fh.close()
        return
    app.config["_SIM_LOCK"] = fh
    with db() as con:
        evento(con, "sistema", f"Central iniciada em {socket.gethostname()} (pid {os.getpid()}) com {len(CRUZAMENTOS)} cruzamentos")
    threading.Thread(target=simulador, name="simulador", daemon=True).start()


# ----------------------------------------------------------------------------- serialização
def cruzamento_json(r):
    agora = time.time()
    if r["modo"] == "emergencia":
        fase, restante = r["emergencia_fase"], max(0, int(r["emergencia_ate"] - agora))
    else:
        dur = r["verde_ns"] if r["fase"] == "NS" else r["verde_lo"]
        fase, restante = r["fase"], max(0, int(dur - (agora - r["fase_inicio"])))
    filas = {"N": r["fila_n"], "S": r["fila_s"], "L": r["fila_l"], "O": r["fila_o"]}
    return {
        "id": r["id"], "nome": r["nome"], "modo": r["modo"], "fase_verde": fase, "restante_s": restante,
        "verde_s": {"NS": r["verde_ns"], "LO": r["verde_lo"]}, "filas": filas, "fila_total": sum(filas.values()),
        "fluxo_veic_min": r["fluxo"], "origem": r["origem"],
        "ultima_leitura": datetime.fromtimestamp(r["ultima_leitura"]).isoformat(timespec="seconds") if r["ultima_leitura"] else None,
    }


def exigir_token():
    if API_TOKEN and request.headers.get("Authorization", "") != f"Bearer {API_TOKEN}":
        abort(401, description="token inválido ou ausente")


def disparar_onda_verde(rota, duracao, origem):
    ids = [c for c, _ in CRUZAMENTOS]
    rota = [c for c in rota if c in ids]
    if not rota:
        abort(400, description="rota vazia ou com cruzamentos inválidos")
    duracao = max(10, min(120, int(duracao)))
    agora = time.time()
    with db() as con:
        for i, cid in enumerate(rota):
            fase = random.choice(["NS", "LO"])
            con.execute("UPDATE cruzamentos SET modo='emergencia', emergencia_fase=?, emergencia_ate=? WHERE id=?",
                        (fase, agora + duracao + i * 6, cid))
        nomes = " → ".join(rota)
        evento(con, "onda_verde", f"🚑 Ambulância detectada ({origem}): onda verde aberta em {nomes} por ~{duracao}s")
    return {"rota": rota, "duracao_s": duracao, "status": "onda verde ativada"}


# ----------------------------------------------------------------------------- rotas web
@app.route("/")
def dashboard():
    return render_template("index.html", app_name=APP_NAME, cidade=CIDADE, host=socket.gethostname(),
                           env=APP_ENV, versao=VERSAO, cruzamentos=CRUZAMENTOS)


@app.route("/health")
def health():
    try:
        with db() as con:
            n = con.execute("SELECT COUNT(*) FROM cruzamentos").fetchone()[0]
        status, code = "ok", 200
    except Exception as exc:
        n, status, code = 0, f"erro: {exc}", 503
    return jsonify(status=status, app="semaforo-inteligente", versao=VERSAO, host=socket.gethostname(),
                   env=APP_ENV, cidade=CIDADE, cruzamentos=n, simulador=SIMULADOR,
                   uptime_s=int(time.time() - STARTED), time=datetime.now().isoformat(timespec="seconds")), code


@app.route("/api/cruzamentos")
def api_cruzamentos():
    with db() as con:
        return jsonify([cruzamento_json(r) for r in con.execute("SELECT * FROM cruzamentos ORDER BY id")])


@app.route("/api/cruzamentos/<cid>")
def api_cruzamento(cid):
    with db() as con:
        r = con.execute("SELECT * FROM cruzamentos WHERE id=?", (cid.upper(),)).fetchone()
    if r is None:
        abort(404, description="cruzamento não encontrado")
    return jsonify(cruzamento_json(r))


@app.route("/api/sensores", methods=["POST"])
def api_sensores():
    """Recebe a leitura de um cruzamento (formato do sensor de borda / MQTT)."""
    exigir_token()
    d = request.get_json(silent=True) or {}
    cid = str(d.get("cruzamento", "")).upper()
    try:
        filas = {v: max(0, int(d["filas"][v])) for v in VIAS}
    except (KeyError, TypeError, ValueError):
        abort(400, description="formato: {cruzamento, filas:{N,S,L,O}, fluxo}")
    with db() as con:
        v_ns, v_lo = aplicar_leitura(con, cid, filas, int(d.get("fluxo", 0)), "sensor")
    return jsonify(cruzamento=cid, comando={"verde_NS_s": v_ns, "verde_LO_s": v_lo}), 201


@app.route("/api/emergencias", methods=["POST"])
def api_emergencias():
    exigir_token()
    d = request.get_json(silent=True) or {}
    return jsonify(disparar_onda_verde(d.get("rota", []), d.get("duracao_s", 30), "API")), 201


@app.route("/painel/onda-verde", methods=["POST"])
def painel_onda_verde():
    """Botão de demonstração do dashboard: simula uma ambulância numa rota aleatória."""
    ids = [c for c, _ in CRUZAMENTOS]
    ini = random.randint(0, max(0, len(ids) - 3))
    return jsonify(disparar_onda_verde(ids[ini:ini + 3], 30, "painel")), 201


@app.route("/api/eventos")
def api_eventos():
    limit = max(1, min(100, int(request.args.get("limit", 20))))
    with db() as con:
        rows = con.execute("SELECT * FROM eventos ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    return jsonify([{"ts": datetime.fromtimestamp(r["ts"]).strftime("%H:%M:%S"), "cruzamento": r["cruzamento"],
                     "tipo": r["tipo"], "mensagem": r["mensagem"]} for r in rows])


@app.route("/api/metricas")
def api_metricas():
    with db() as con:
        cz = con.execute("SELECT * FROM cruzamentos").fetchall()
        m = con.execute("""SELECT AVG(espera_adaptativa) a, AVG(espera_fixa) f, COUNT(*) n
                           FROM leituras WHERE ts > ?""", (time.time() - 300,)).fetchone()
    agora = time.time()
    online = sum(1 for r in cz if agora - r["ultima_leitura"] < 20)
    ganho = (1 - m["a"] / m["f"]) * 100 if m["f"] else 0
    return jsonify(cruzamentos=len(cz), online=online,
                   em_emergencia=sum(1 for r in cz if r["modo"] == "emergencia"),
                   modo_seguranca=sum(1 for r in cz if r["modo"] == "seguranca"),
                   veiculos_em_fila=sum(r["fila_n"] + r["fila_s"] + r["fila_l"] + r["fila_o"] for r in cz),
                   espera_media_adaptativa_s=round(m["a"] or 0, 1), espera_media_ciclo_fixo_s=round(m["f"] or 0, 1),
                   reducao_espera_pct=round(ganho, 1), leituras_5min=m["n"])


@app.errorhandler(400)
@app.errorhandler(401)
@app.errorhandler(404)
def erro(e):
    return jsonify(erro=e.description), e.code


init_db()
iniciar_simulador()

if __name__ == "__main__":
    app.run(host=os.getenv("HOST", "127.0.0.1"), port=int(os.getenv("PORT", "5000")))
