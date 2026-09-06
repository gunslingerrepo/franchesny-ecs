import logging
import os
import sys
from datetime import datetime, timezone

from fastapi import FastAPI

# Log to stdout/stderr only — no file logging, per assessment requirements
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("finzla-app")

app = FastAPI(title="Finzla Platform Assessment Service")

APP_ENV = os.getenv("APP_ENV", "development")
APP_VERSION = os.getenv("APP_VERSION", "0.0.0")
GIT_COMMIT = os.getenv("GIT_COMMIT", "unknown")
BUILD_NUMBER = os.getenv("BUILD_NUMBER", "unknown")


@app.on_event("startup")
async def on_startup() -> None:
    logger.info(
        "service starting env=%s version=%s commit=%s build=%s",
        APP_ENV,
        APP_VERSION,
        GIT_COMMIT,
        BUILD_NUMBER,
    )


@app.get("/health")
async def health():
    """Liveness/readiness probe target for the ALB target group."""
    return {"status": "ok"}


@app.get("/version")
async def version():
    return {
        "version": APP_VERSION,
        "git_commit": GIT_COMMIT,
        "build_number": BUILD_NUMBER,
        "env": APP_ENV,
        "server_time_utc": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/")
async def root():
    return {"service": "finzla-platform-assessment", "see": ["/health", "/version"]}
