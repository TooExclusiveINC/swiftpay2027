"""
SwiftPay Portal — stand-in application-tier service.
Deliberately simple: the point of this capstone is tier separation,
reverse-proxy config, and HA/DR — not real payment business logic.
"""
import os
import socket
from datetime import datetime

import psycopg2
from flask import Flask, jsonify

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "db1")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "swiftpay")
DB_USER = os.environ.get("DB_USER", "swiftpay_app")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")


def get_conn():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD, connect_timeout=3,
    )


@app.route("/healthz")
def healthz():
    return jsonify(status="ok", host=socket.gethostname(), time=datetime.utcnow().isoformat())


@app.route("/")
def index():
    return jsonify(message="SwiftPay Portal API", served_by=socket.gethostname())


@app.route("/balance/<int:account_id>")
def balance(account_id):
    try:
        with get_conn() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT balance_cents FROM accounts WHERE id = %s", (account_id,)
            )
            row = cur.fetchone()
            if row is None:
                return jsonify(error="account not found"), 404
            return jsonify(account_id=account_id, balance_cents=row[0], served_by=socket.gethostname())
    except Exception as exc:  # pragma: no cover - demo error path
        return jsonify(error=str(exc)), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8000)))
