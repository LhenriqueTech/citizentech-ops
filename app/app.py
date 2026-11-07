"""
CitizenTech - aplicação de exemplo.
Substitua esta pasta pela aplicação da outra disciplina, ou aponte
APP_SOURCE=git / APP_REPO_URL em config/citizentech.conf.
"""
import os
import platform
import socket
import time
from datetime import datetime

from flask import Flask, jsonify, render_template, request

app = Flask(__name__)
STARTED = time.time()

# Dados de exemplo: solicitações de cidadãos (zeladoria urbana)
REQUESTS = [
    {"id": 1, "tipo": "Iluminação pública", "bairro": "Centro", "status": "Em andamento"},
    {"id": 2, "tipo": "Buraco na via", "bairro": "Vila Mariana", "status": "Aberto"},
    {"id": 3, "tipo": "Coleta de lixo", "bairro": "Mooca", "status": "Concluído"},
]


@app.route("/")
def index():
    return render_template(
        "index.html",
        app_name=os.getenv("APP_NAME", "CitizenTech"),
        env=os.getenv("APP_ENV", "dev"),
        host=socket.gethostname(),
        requests=REQUESTS,
    )


@app.route("/health")
def health():
    return jsonify(
        status="ok",
        host=socket.gethostname(),
        env=os.getenv("APP_ENV", "dev"),
        uptime_s=int(time.time() - STARTED),
        python=platform.python_version(),
        time=datetime.now().isoformat(timespec="seconds"),
    )


@app.route("/api/solicitacoes", methods=["GET", "POST"])
def solicitacoes():
    if request.method == "POST":
        data = request.get_json(silent=True) or {}
        item = {
            "id": len(REQUESTS) + 1,
            "tipo": data.get("tipo", "Outro"),
            "bairro": data.get("bairro", "-"),
            "status": "Aberto",
        }
        REQUESTS.append(item)
        return jsonify(item), 201
    return jsonify(REQUESTS)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=int(os.getenv("PORT", "5000")))
