"""
NimbusCart API
Flask REST API for the NimbusCart product catalog.

Routes:
    GET  /health  -> 200 {"status": "ok"}  (no DB dependency, used for infra health checks)
    GET  /items   -> JSON array of products from the `products` table
    POST /items   -> inserts a row (name, price, stock), returns the created row with its id

The API owns its schema: on startup it retries the DB connection until it
succeeds, then runs CREATE TABLE IF NOT EXISTS. Nothing outside the app
(not Terraform, not a human with psql) is supposed to touch the schema.
"""

import os
import time
import logging

from flask import Flask, jsonify, request
import psycopg2
import psycopg2.extras

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("nimbuscart-api")

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "nimbuscart")
DB_USER = os.environ.get("DB_USER", "nimbuscart")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "nimbuscart")

MAX_STARTUP_RETRIES = int(os.environ.get("DB_STARTUP_RETRIES", "30"))
RETRY_DELAY_SECONDS = float(os.environ.get("DB_STARTUP_RETRY_DELAY", "2"))


def get_connection():
    """Short-lived connection per request. Simple and predictable for a
    tiny catalog app; a connection pool would be the next step at scale."""
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,
    )


def init_schema_with_retry():
    """Block startup until the DB is reachable, then create the schema
    if it doesn't already exist. This is what lets the container come up
    against a DB that isn't ready yet (e.g. RDS still provisioning) and
    also makes re-deploys idempotent."""
    for attempt in range(1, MAX_STARTUP_RETRIES + 1):
        try:
            conn = get_connection()
            with conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        CREATE TABLE IF NOT EXISTS products (
                            id SERIAL PRIMARY KEY,
                            name TEXT NOT NULL,
                            price NUMERIC(10, 2) NOT NULL,
                            stock INTEGER NOT NULL
                        );
                        """
                    )
            conn.close()
            log.info("Schema ready (attempt %d).", attempt)
            return
        except Exception as exc:  # noqa: BLE001 - we want to retry on any connection error
            log.warning(
                "DB not ready yet (attempt %d/%d): %s",
                attempt,
                MAX_STARTUP_RETRIES,
                exc,
            )
            time.sleep(RETRY_DELAY_SECONDS)

    log.error("Giving up on DB after %d attempts. /items will fail until DB is reachable.",
               MAX_STARTUP_RETRIES)


@app.get("/health")
def health():
    # Deliberately no DB call here - this is the infra-level liveness check
    # and must return 200 even if the database is down or still booting.
    return jsonify(status="ok"), 200


@app.get("/items")
def list_items():
    try:
        conn = get_connection()
        with conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute("SELECT id, name, price, stock FROM products ORDER BY id;")
                rows = cur.fetchall()
        conn.close()
        items = [
            {"id": r["id"], "name": r["name"], "price": float(r["price"]), "stock": r["stock"]}
            for r in rows
        ]
        return jsonify(items), 200
    except Exception as exc:  # noqa: BLE001
        log.exception("GET /items failed")
        return jsonify(error=str(exc)), 503


@app.post("/items")
def create_item():
    body = request.get_json(silent=True) or {}
    name = body.get("name")
    price = body.get("price")
    stock = body.get("stock")

    if not isinstance(name, str) or not name.strip():
        return jsonify(error="`name` is required"), 400
    if not isinstance(price, (int, float)):
        return jsonify(error="`price` must be a number"), 400
    if not isinstance(stock, int):
        return jsonify(error="`stock` must be an integer"), 400

    try:
        conn = get_connection()
        with conn:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                cur.execute(
                    "INSERT INTO products (name, price, stock) VALUES (%s, %s, %s) "
                    "RETURNING id, name, price, stock;",
                    (name.strip(), price, stock),
                )
                row = cur.fetchone()
        conn.close()
        created = {"id": row["id"], "name": row["name"], "price": float(row["price"]), "stock": row["stock"]}
        return jsonify(created), 201
    except Exception as exc:  # noqa: BLE001
        log.exception("POST /items failed")
        return jsonify(error=str(exc)), 503


# Run schema init at import time so it happens both under `python app.py`
# and under gunicorn.
init_schema_with_retry()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
