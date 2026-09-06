# --- build stage: install deps into a venv ---
FROM python:3.12-slim AS builder

WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# --- runtime stage: minimal image, non-root user ---
FROM python:3.12-slim AS runtime

# Build-time metadata, injected by CI (git SHA, build number, semantic version)
ARG APP_VERSION=0.0.0
ARG GIT_COMMIT=unknown
ARG BUILD_NUMBER=unknown

ENV APP_VERSION=${APP_VERSION} \
    GIT_COMMIT=${GIT_COMMIT} \
    BUILD_NUMBER=${BUILD_NUMBER} \
    APP_ENV=production \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Non-root user — never run the app as root in the container
RUN groupadd --gid 1000 appuser \
    && useradd --uid 1000 --gid appuser --shell /usr/sbin/nologin --create-home appuser

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY src/ ./src/

RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 8080

# No shell form — avoids running as PID 1 via a shell, cleaner signal handling
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8080"]
