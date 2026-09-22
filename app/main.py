import os
from datetime import datetime, timezone

import boto3
import psycopg2
from fastapi import FastAPI, HTTPException

app = FastAPI()

DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
AWS_REGION = os.environ["AWS_REGION"]
HOSTNAME = os.environ.get("HOSTNAME", "unknown")


def get_connection(connect_timeout=5):
    # No password in an env var or a Secret — this generates a 15-minute
    # IAM auth token on every connection, using whatever credentials the
    # pod's IRSA service account provides. boto3 picks those up from the
    # AWS_ROLE_ARN / AWS_WEB_IDENTITY_TOKEN_FILE env vars EKS injects
    # automatically, no explicit STS code needed here.
    client = boto3.client("rds", region_name=AWS_REGION)
    token = client.generate_db_auth_token(
        DBHostname=DB_HOST, Port=DB_PORT, DBUsername=DB_USER
    )
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=token,
        sslmode="require",
        connect_timeout=connect_timeout,
    )


@app.get("/healthz")
def healthz():
    # Liveness: is the process itself alive. Deliberately doesn't touch
    # Aurora — during the DR drill, a failed database should show up as
    # failed requests, not as Kubernetes restarting otherwise-fine pods.
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    # Readiness: can this pod actually serve a real request right now.
    # This one DOES touch Aurora on purpose, so a failover pulls this
    # pod out of the Service's endpoints until it can reach the database
    # again — the real, measurable signal the DR drill is built around.
    try:
        conn = get_connection(connect_timeout=2)
        with conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
        conn.close()
        return {"status": "ready"}
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"database unreachable: {e}")


@app.get("/visits")
def visits():
    try:
        conn = get_connection()
        with conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO visits (served_by) VALUES (%s) RETURNING id, visited_at",
                (HOSTNAME,),
            )
            row = cur.fetchone()
            cur.execute("SELECT count(*) FROM visits")
            total = cur.fetchone()[0]
        conn.close()
        return {
            "id": row[0],
            "visited_at": row[1].isoformat(),
            "served_by": HOSTNAME,
            "total_visits": total,
        }
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))
