#!/usr/bin/env python3
"""
Sensor de borda simulado (o "Raspberry" de um cruzamento).

Envia a cada poucos segundos a contagem de veículos por via para a Central:
    python3 sensor_simulado.py C01
    python3 sensor_simulado.py C03 --url http://app.citizentech.local --token SEU_TOKEN

Enquanto ele roda, o cruzamento passa a usar estes dados (origem "sensor").
Se ele parar, a Central detecta a falta de dados e coloca o cruzamento em
modo de segurança (ciclo fixo), como na proposta do Semáforo Inteligente.
"""
import argparse
import json
import random
import time
import urllib.request


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cruzamento")
    p.add_argument("--url", default="http://127.0.0.1")
    p.add_argument("--token", default="")
    p.add_argument("--intervalo", type=float, default=3)
    a = p.parse_args()
    filas = {v: random.randint(5, 20) for v in "NSLO"}
    while True:
        for v in filas:
            filas[v] = max(0, min(60, filas[v] + random.randint(-4, 5)))
        corpo = json.dumps({"cruzamento": a.cruzamento, "filas": filas, "fluxo": sum(filas.values()) * 2}).encode()
        req = urllib.request.Request(f"{a.url}/api/sensores", data=corpo, method="POST",
                                     headers={"Content-Type": "application/json",
                                              **({"Authorization": f"Bearer {a.token}"} if a.token else {})})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                cmd = json.loads(r.read())["comando"]
            print(f"{time.strftime('%H:%M:%S')} {a.cruzamento} filas={filas} -> verde NS {cmd['verde_NS_s']}s / LO {cmd['verde_LO_s']}s", flush=True)
        except Exception as e:
            print(f"{time.strftime('%H:%M:%S')} falha ao enviar: {e}", flush=True)
        time.sleep(a.intervalo)


if __name__ == "__main__":
    main()
