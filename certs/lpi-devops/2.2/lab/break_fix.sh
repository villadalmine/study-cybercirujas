#!/usr/bin/env bash
# ==============================================================================
# LPI DevOps Tools Engineer (Exam 701-100, Version 1.0)
# Topic 2.2: Container Deployment and Orchestration (Weight: 8.33)
# Official Reference: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/
#
# LAB BREAK & FIX: Multi-Service Container Orchestration & Networking Failure
# Author: Principal Platform Architect & Senior SRE Instructor
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_701_topic_2_2_lab"
STACK_NAME="lpi-prod-stack"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}[+] Initializing LPI 701-100 Topic 2.2 Break & Fix Scenario...${NC}"

# Check prerequisites
if ! command -v docker &> /dev/null; then
    echo -e "${RED}[!] Error: docker binary is not installed or not in PATH.${NC}"
    exit 1
fi

DOCKER_COMPOSE_CMD=""
if docker compose version &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD="docker-compose"
else
    echo -e "${RED}[!] Error: Neither 'docker compose' nor 'docker-compose' plugin was found.${NC}"
    exit 1
fi

# Cleanup previous run if exists
if [ -d "$LAB_DIR" ]; then
    echo -e "${YELLOW}[*] Cleaning up existing lab environment at ${LAB_DIR}...${NC}"
    (cd "$LAB_DIR" && $DOCKER_COMPOSE_CMD down -v --remove-orphans &>/dev/null || true)
    rm -rf "$LAB_DIR"
fi

mkdir -p "$LAB_DIR/config" "$LAB_DIR/app"

# Setup dummy web application script (simulates a Python microservice)
cat << 'EOF' > "$LAB_DIR/app/server.py"
import os
import time
import socket
import sys

print("[INFO] Microservice initializing...", flush=True)

# Test environment configuration write access
try:
    with open('/app/config/runtime.log', 'a') as f:
        f.write(f"Started at {time.time()}\n")
except Exception as e:
    print(f"[FATAL] Storage write failure on config volume: {e}", flush=True)
    sys.exit(1)

print("[INFO] Configuration volume validated. Testing DB connectivity...", flush=True)

db_host = os.getenv("DB_HOST", "db")
db_port = int(os.getenv("DB_PORT", "5432"))

try:
    s = socket.create_connection((db_host, db_port), timeout=3)
    print(f"[SUCCESS] Connected to database at {db_host}:{db_port}", flush=True)
    s.close()
except Exception as e:
    print(f"[FATAL] Cannot connect to database target '{db_host}:{db_port}': {e}", flush=True)
    sys.exit(2)

print("[INFO] Microservice successfully started and ready for traffic.", flush=True)
while True:
    time.sleep(3600)
EOF

# Setup App Dockerfile
cat << 'EOF' > "$LAB_DIR/app/Dockerfile"
FROM python:3.11-alpine
WORKDIR /app
COPY server.py /app/server.py
CMD ["python", "-u", "/app/server.py"]
EOF

# Create the BROKEN docker-compose.yml manifest
# BUGS INTRODUCED:
# 1. Network Isolation: 'web' is on 'frontend-net', but 'db' is strictly on 'backend-net'. 'web' cannot resolve/reach 'db'.
# 2. Volume Permissions/Mount mode: 'config-volume' mounted read-only (:ro) on 'web', causing server.py to fail on open('/app/config/runtime.log', 'a').
# 3. Healthcheck misconfiguration: 'redis' healthcheck probes port 6380 instead of 6379, rendering container 'unhealthy'.
cat << 'EOF' > "$LAB_DIR/docker-compose.yml"
version: '3.8'

services:
  web:
    build: ./app
    container_name: lpi-web-api
    restart: always
    environment:
      DB_HOST: lpi-postgres-db
      DB_PORT: 5432
    volumes:
      - config-data:/app/config:ro
    networks:
      - frontend-net
    depends_on:
      redis:
        condition: service_healthy

  redis:
    image: redis:7-alpine
    container_name: lpi-redis-cache
    restart: always
    networks:
      - frontend-net
    healthcheck:
      test: ["CMD-SHELL", "nc -z 127.0.0.1 6380 || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 3
      start_period: 2s

  db:
    image: postgres:15-alpine
    container_name: lpi-postgres-db
    restart: always
    environment:
      POSTGRES_DB: appdb
      POSTGRES_USER: appuser
      POSTGRES_PASSWORD: secretpassword
    networks:
      - backend-net

networks:
  frontend-net:
    driver: bridge
  backend-net:
    driver: bridge
    internal: true

volumes:
  config-data:
EOF

echo -e "${YELLOW}[*] Building and deploying broken container stack...${NC}"
(
    cd "$LAB_DIR"
    $DOCKER_COMPOSE_CMD build &>/dev/null
    $DOCKER_COMPOSE_CMD up -d &>/dev/null || true
)

# Wait a few seconds for services to attempt boot
sleep 6

echo -e "${GREEN}[+] Lab Setup Complete!${NC}"
echo -e "================================================================================"
echo -e "${RED}SCENARIO OVERVIEW & TROUBLESHOOTING MISSION${RED}"
echo -e "================================================================================"
echo -e "Target Certification: LPI DevOps Tools Engineer (Exam 701-100)"
echo -e "Topic 2.2: Container Deployment and Orchestration"
echo -e "Official Ref: https://www.lpi.org/our-certifications/devops-tools-engineer-overview/"
echo -e ""
echo -e "SYMPTOMS REPORTED BY PRODUCTION MONITORING:"
echo -e "1. The application stack defined in '${LAB_DIR}/docker-compose.yml' is failing to start."
echo -e "2. Container 'lpi-web-api' fails or hangs in dependency waiting loops."
echo -e "3. Container 'lpi-redis-cache' reports UNHEALTHY status."
echo -e "4. Database DNS/Network resolution between application microservices is failing."
echo -e ""
echo -e "YOUR GOALS AS SRE/PLATFORM ARCHITECT:"
echo -e "1. Diagnose why 'lpi-redis-cache' is flagged as unhealthy using Docker inspection tools."
echo -e "2. Identify why 'lpi-web-api' crashes upon startup (inspect container logs)."
echo -e "3. Troubleshoot Docker network topology to restore connectivity between 'web' and 'db'."
echo -e "4. Fix '${LAB_DIR}/docker-compose.yml' without compromising network security best practices."
echo -e ""
echo -e "RECOMMENDED DIAGNOSTIC COMMANDS TO EXECUTE:"
echo -e "  cd ${LAB_DIR}"
echo -e "  ${DOCKER_COMPOSE_CMD} ps"
echo -e "  ${DOCKER_COMPOSE_CMD} logs web"
echo -e "  docker inspect lpi-redis-cache --format '{{json .State.Health}}' | jq"
echo -e "  docker network inspect lpi_701_topic_2_2_lab_frontend-net"
echo -e ""
echo -e "================================================================================"
echo -e "${YELLOW}To view the complete step-by-step solution, inspect the bottom of this script file.${NC}"
echo -e "================================================================================"

exit 0

# ==============================================================================
#                      SOLUTION & DETAILED EXPLANATION
# ==============================================================================
#
# ROOT CAUSE ANALYSIS:
# --------------------
# 1. Healthcheck Failure (redis service):
#    - The healthcheck test script in compose uses `nc -z 127.0.0.1 6380`.
#    - Redis defaults to port 6379 inside the container. Checking 6380 returns exit code 1.
#    - Because `web` service specifies `depends_on: redis: condition: service_healthy`,
#      `web` will never start if `redis` stays unhealthy.
#
# 2. Read-Only Volume Failure (web service):
#    - The `config-data` volume is mounted with `:ro` mode (`config-data:/app/config:ro`).
#    - The application (`server.py`) attempts to append to `/app/config/runtime.log`.
#    - This triggers a `PermissionError: [Errno 30] Read-only file system` and causes `web` to crash.
#
# 3. Network Isolation / DNS Resolution Failure (web -> db connectivity):
#    - `web` is assigned strictly to `frontend-net`.
#    - `db` is assigned strictly to `backend-net`.
#    - Because Docker bridge networks isolate containers across user-defined networks,
#      `web` cannot resolve `lpi-postgres-db` nor route traffic to it.
#
# ==============================================================================
# STEP-BY-STEP FIX PROCEDURE:
# ==============================================================================
#
# Step 1: Diagnose Stack State
# $ cd /tmp/lpi_701_topic_2_2_lab
# $ docker compose ps
# EXPECTED OUTPUT:
# NAME              IMAGE                COMMAND                  SERVICE   STATUS
# lpi-postgres-db   postgres:15-alpine   "docker-entrypoint.s…"   db        running
# lpi-redis-cache    redis:7-alpine       "docker-entrypoint.s…"   redis     running (unhealthy)
#
# Step 2: Fix Redis Healthcheck
# Modify `docker-compose.yml` under `redis.healthcheck`:
# Change port 6380 to 6379, or use `redis-cli ping`:
#   healthcheck:
#     test: ["CMD", "redis-cli", "ping"]
#
# Step 3: Fix Volume Mount Permissions
# Modify `docker-compose.yml` under `web.volumes`:
# Change `:ro` to `:rw` (or drop `:ro` since `:rw` is default):
#   volumes:
#     - config-data:/app/config:rw
#
# Step 4: Fix Network Bridge Routing
# Attach `web` service to BOTH `frontend-net` and `backend-net`:
#   services:
#     web:
#       networks:
#         - frontend-net
#         - backend-net
#
# ==============================================================================
# FULL SYNTACTICALLY VALID SOLUTION MANIFEST (docker-compose.yml)
# ==============================================================================
#
# version: '3.8'
#
# services:
#   web:
#     build: ./app
#     container_name: lpi-web-api
#     restart: always
#     environment:
#       DB_HOST: lpi-postgres-db
#       DB_PORT: 5432
#     volumes:
#       - config-data:/app/config:rw
#     networks:
#       - frontend-net
#       - backend-net
#     depends_on:
#       redis:
#         condition: service_healthy
#
#   redis:
#     image: redis:7-alpine
#     container_name: lpi-redis-cache
#     restart: always
#     networks:
#       - frontend-net
#     healthcheck:
#       test: ["CMD-SHELL", "redis-cli ping | grep PONG || exit 1"]
#       interval: 5s
#       timeout: 3s
#       retries: 3
#       start_period: 2s
#
#   db:
#     image: postgres:15-alpine
#     container_name: lpi-postgres-db
#     restart: always
#     environment:
#       POSTGRES_DB: appdb
#       POSTGRES_USER: appuser
#       POSTGRES_PASSWORD: secretpassword
#     networks:
#       - backend-net
#
# networks:
#   frontend-net:
#     driver: bridge
#   backend-net:
#     driver: bridge
#     internal: true
#
# volumes:
#   config-data:
#
# ==============================================================================
# VERIFICATION COMMANDS AFTER APPLYING FIX:
# ==============================================================================
# $ docker compose up -d --build
# $ docker compose ps
# EXPECTED OUTPUT:
# NAME              IMAGE                SERVICE   STATUS
# lpi-postgres-db   postgres:15-alpine   db        running
# lpi-redis-cache    redis:7-alpine       redis     running (healthy)
# lpi-web-api       lpi_701_topic_2_2_lab-web web   running
#
# $ docker compose logs web
# EXPECTED LOG OUTPUT:
# [INFO] Microservice initializing...
# [INFO] Configuration volume validated. Testing DB connectivity...
# [SUCCESS] Connected to database at lpi-postgres-db:5432
# [INFO] Microservice successfully started and ready for traffic.
# ==============================================================================