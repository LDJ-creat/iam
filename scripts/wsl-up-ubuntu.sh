#!/usr/bin/env bash

# If invoked via `sh`, re-exec with bash to support bash-only options/syntax.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -Eeuo pipefail

IAM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${IAM_ROOT}"

OUTPUT_DIR="${IAM_ROOT}/_output"
RUN_DIR="${OUTPUT_DIR}/run"
LOG_DIR="${OUTPUT_DIR}/logs"
CFG_DIR="${OUTPUT_DIR}/configs"
CERT_DIR="${CFG_DIR}/cert"
ENV_FILE_UNIX="${RUN_DIR}/environment.unix.sh"

DB_NET="iam-net"
MDB_CTN="iam-mariadb"
RDS_CTN="iam-redis"
MGO_CTN="iam-mongo"

PASSWORD="${PASSWORD:-iam123456}"

HOST_MARIADB_PORT="${HOST_MARIADB_PORT:-3306}"
HOST_REDIS_PORT="${HOST_REDIS_PORT:-6379}"
HOST_MONGO_PORT="${HOST_MONGO_PORT:-27017}"
MYSQL_ROOT_ARGS=""

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] missing required command: $1"
    exit 1
  }
}

ensure_go() {
  local go_version="1.21.4"
  local go_dir="${HOME}/.local/go${go_version}"

  if command -v go >/dev/null 2>&1; then
    return 0
  fi

  if [[ -x "${go_dir}/bin/go" ]]; then
    export GOROOT="${go_dir}"
    export PATH="${GOROOT}/bin:${PATH}"
    echo "[OK] using $(go version)"
    return 0
  fi

  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "[ERROR] unsupported CPU arch for auto Go install: ${arch}"
      echo "[ERROR] please install Go >= 1.21 manually and re-run."
      exit 1
      ;;
  esac

  local tarball="/tmp/go${go_version}.linux-${arch}.tar.gz"
  local url="https://go.dev/dl/go${go_version}.linux-${arch}.tar.gz"

  echo "[INFO] Go not found, installing Go ${go_version} ..."
  mkdir -p "${HOME}/.local"
  curl -fL "${url}" -o "${tarball}"
  rm -rf "${go_dir}"
  tar -C "${HOME}/.local" -xzf "${tarball}"
  mv "${HOME}/.local/go" "${go_dir}"

  export GOROOT="${go_dir}"
  export PATH="${GOROOT}/bin:${PATH}"

  command -v go >/dev/null 2>&1 || {
    echo "[ERROR] failed to install Go automatically"
    exit 1
  }
  echo "[OK] using $(go version)"
}

wait_http_ok() {
  local url="$1"
  local name="$2"
  local retries="${3:-60}"
  local sleep_sec="${4:-2}"

  for _ in $(seq 1 "${retries}"); do
    if curl --noproxy '*' -fsS "${url}" >/dev/null 2>&1; then
      echo "[OK] ${name} is healthy: ${url}"
      return 0
    fi
    sleep "${sleep_sec}"
  done

  echo "[ERROR] timeout waiting for ${name}: ${url}"
  return 1
}

is_port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -Eq "(^|:)${port}$"
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
    return $?
  fi

  return 1
}

get_mapped_port() {
  local ctn="$1"
  local container_port="$2"
  docker port "${ctn}" "${container_port}" | tail -n1 | sed 's/.*://'
}

ensure_docker_daemon() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  echo "[WARN] docker daemon is unavailable in WSL, trying to start Docker Desktop ..."
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "Start-Process 'C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe'" >/dev/null 2>&1 || true
  fi

  for _ in $(seq 1 90); do
    if docker info >/dev/null 2>&1; then
      echo "[OK] docker daemon is ready"
      return 0
    fi
    sleep 2
  done

  echo "[ERROR] docker daemon is unavailable in WSL."
  echo "[ERROR] please ensure Docker Desktop is running and WSL integration is enabled for Ubuntu-22.04."
  echo "[HINT] Docker Desktop -> Settings -> Resources -> WSL Integration -> enable Ubuntu-22.04"
  return 1
}

stop_binary_if_running() {
  local pid_file="$1"
  if [[ -f "${pid_file}" ]]; then
    local pid
    pid="$(cat "${pid_file}" || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" || true
      sleep 1
    fi
    rm -f "${pid_file}"
  fi
}

kill_process_on_port() {
  local port="$1"
  local pids=""

  if command -v ss >/dev/null 2>&1; then
    pids+=" $(ss -ltnp 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {print $NF}' | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u || true)"
  fi

  if command -v lsof >/dev/null 2>&1; then
    pids+=" $(lsof -t -iTCP:${port} -sTCP:LISTEN 2>/dev/null | sort -u || true)"
  fi

  pids="$(echo "${pids}" | tr ' ' '\n' | awk 'NF' | sort -u | tr '\n' ' ')"
  if [[ -n "${pids}" ]]; then
    echo "[INFO] port ${port} is occupied, killing stale pids: ${pids}"
    kill ${pids} >/dev/null 2>&1 || true
    sleep 1
    kill -9 ${pids} >/dev/null 2>&1 || true
    sleep 1
  fi

  if is_port_in_use "${port}" && command -v fuser >/dev/null 2>&1; then
    echo "[WARN] trying fuser to free port ${port}"
    fuser -k -n tcp "${port}" >/dev/null 2>&1 || true
    sleep 1
  fi

  if is_port_in_use "${port}"; then
    echo "[ERROR] port ${port} is still in use and cannot be reclaimed"
    if command -v ss >/dev/null 2>&1; then
      ss -ltnp 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {print}' || true
    fi
    return 1
  fi

  return 0
}

start_binary() {
  local name="$1"
  local bin="$2"
  local cfg="$3"
  local health_url="$4"
  shift 4

  local pid_file="${RUN_DIR}/${name}.pid"
  local log_file="${LOG_DIR}/${name}.log"

  for p in "$@"; do
    kill_process_on_port "${p}" || true
  done

  stop_binary_if_running "${pid_file}"

  if [[ ! -x "${bin}" ]]; then
    echo "[ERROR] binary not found: ${bin}"
    exit 1
  fi

  echo "[INFO] starting ${name} ..."
  nohup "${bin}" --config="${cfg}" >"${log_file}" 2>&1 &
  echo $! >"${pid_file}"

  wait_http_ok "${health_url}" "${name}" 90 2 || {
    echo "[ERROR] ${name} failed to become healthy, check log: ${log_file}"
    tail -n 80 "${log_file}" || true
    exit 1
  }
}

pick_port() {
  local preferred="$1"
  local selected="${preferred}"
  local max_tries=200

  if is_port_in_use "${selected}"; then
    kill_process_on_port "${selected}" >/dev/null 2>&1 || true
  fi

  if ! is_port_in_use "${selected}"; then
    echo "${selected}"
    return 0
  fi

  selected=$((preferred + 1))
  for _ in $(seq 1 "${max_tries}"); do
    if ! is_port_in_use "${selected}"; then
      echo "${selected}"
      return 0
    fi
    selected=$((selected + 1))
  done

  echo "[ERROR] failed to find available port near ${preferred}" >&2
  return 1
}

detect_mysql_root_args() {
  if docker exec "${MDB_CTN}" mysql -uroot -p"${PASSWORD}" -e 'select 1' >/dev/null 2>&1; then
    MYSQL_ROOT_ARGS="-uroot -p${PASSWORD}"
    return 0
  fi

  if docker exec "${MDB_CTN}" mysql -uroot -e 'select 1' >/dev/null 2>&1; then
    MYSQL_ROOT_ARGS="-uroot"
    return 0
  fi

  return 1
}

run_mysql_root_sql() {
  local sql="$1"
  local retries="${2:-40}"

  for _ in $(seq 1 "${retries}"); do
    if detect_mysql_root_args && docker exec "${MDB_CTN}" mysql ${MYSQL_ROOT_ARGS} -e "${sql}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

import_mysql_file() {
  local file="$1"
  local db="$2"
  local retries="${3:-40}"

  for _ in $(seq 1 "${retries}"); do
    if detect_mysql_root_args && cat "${file}" | docker exec -i "${MDB_CTN}" mysql ${MYSQL_ROOT_ARGS} "${db}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

generate_server_cert() {
  local name="$1"
  local san="$2"
  local key_file="${CERT_DIR}/${name}-key.pem"
  local csr_file="${CERT_DIR}/${name}.csr"
  local crt_file="${CERT_DIR}/${name}.pem"
  local cnf_file="${CERT_DIR}/${name}.cnf"

  cat >"${cnf_file}" <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[ dn ]
C = CN
ST = BeiJing
L = BeiJing
O = marmotedu
OU = ${name}
CN = ${name}

[ req_ext ]
subjectAltName = ${san}

[ v3_ext ]
subjectAltName = ${san}
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
EOF

  openssl genrsa -out "${key_file}" 2048 >/dev/null 2>&1
  openssl req -new -key "${key_file}" -out "${csr_file}" -config "${cnf_file}" >/dev/null 2>&1
  openssl x509 -req -in "${csr_file}" \
    -CA "${CERT_DIR}/ca.pem" -CAkey "${CERT_DIR}/ca-key.pem" -CAcreateserial \
    -out "${crt_file}" -days 36500 -sha256 -extensions v3_ext -extfile "${cnf_file}" >/dev/null 2>&1

  rm -f "${csr_file}" "${cnf_file}"
}

echo "[INFO] checking prerequisites ..."
require_cmd docker
require_cmd make
require_cmd curl
require_cmd tar
require_cmd openssl

ensure_go

export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
export GOSUMDB="${GOSUMDB:-off}"

ensure_docker_daemon || exit 1

mkdir -p "${RUN_DIR}" "${LOG_DIR}" "${CFG_DIR}" "${CERT_DIR}"

echo "[INFO] preparing docker network ..."
docker network create "${DB_NET}" >/dev/null 2>&1 || true

echo "[INFO] starting MariaDB/Redis/MongoDB containers ..."
docker rm -f "${MDB_CTN}" "${RDS_CTN}" "${MGO_CTN}" >/dev/null 2>&1 || true

docker run -d --name "${MDB_CTN}" --network "${DB_NET}" \
  --restart unless-stopped \
  -e MARIADB_ROOT_PASSWORD="${PASSWORD}" \
  -e MARIADB_DATABASE=iam \
  -e MARIADB_USER=iam \
  -e MARIADB_PASSWORD="${PASSWORD}" \
  -p 0:3306 mariadb:10.11 >/dev/null

docker run -d --name "${RDS_CTN}" --network "${DB_NET}" \
  --restart unless-stopped \
  -p 0:6379 redis:7 \
  redis-server --requirepass "${PASSWORD}" >/dev/null

docker run -d --name "${MGO_CTN}" --network "${DB_NET}" \
  --restart unless-stopped \
  -e MONGO_INITDB_ROOT_USERNAME=root \
  -e MONGO_INITDB_ROOT_PASSWORD="${PASSWORD}" \
  -p 0:27017 mongo:5.0 >/dev/null

HOST_MARIADB_PORT="$(get_mapped_port "${MDB_CTN}" "3306/tcp")"
HOST_REDIS_PORT="$(get_mapped_port "${RDS_CTN}" "6379/tcp")"
HOST_MONGO_PORT="$(get_mapped_port "${MGO_CTN}" "27017/tcp")"

echo "[INFO] mapped host ports: mariadb=${HOST_MARIADB_PORT}, redis=${HOST_REDIS_PORT}, mongo=${HOST_MONGO_PORT}"

echo "[INFO] waiting for databases ..."
for _ in $(seq 1 80); do
  if detect_mysql_root_args; then
    break
  fi
  sleep 2
done

if [[ -z "${MYSQL_ROOT_ARGS}" ]]; then
  echo "[ERROR] cannot authenticate mariadb root user in container: ${MDB_CTN}"
  echo "[HINT] check logs with: docker logs ${MDB_CTN}"
  exit 1
fi

# Stage 1: wait for mongod process to accept local TCP connections.
for _ in $(seq 1 120); do
  if docker exec "${MGO_CTN}" sh -c 'mongosh --quiet "mongodb://127.0.0.1:27017" --eval "db.runCommand({ ping: 1 }).ok" >/dev/null 2>&1' ; then
    break
  fi
  sleep 2
done

# Stage 2: wait for root auth to be ready.
for _ in $(seq 1 120); do
  if docker exec "${MGO_CTN}" sh -c 'mongosh --quiet -u root -p "'"${PASSWORD}"'" --authenticationDatabase admin --eval "db.runCommand({ ping: 1 }).ok" | grep -q 1'; then
    break
  fi
  sleep 2
done

docker exec "${MGO_CTN}" sh -c 'mongosh --quiet -u root -p "'"${PASSWORD}"'" --authenticationDatabase admin --eval "db.runCommand({ ping: 1 }).ok" | grep -q 1' || {
  echo "[ERROR] mongodb root user is not ready, please check container logs: docker logs ${MGO_CTN}"
  exit 1
}

echo "[INFO] initializing databases ..."
run_mysql_root_sql "CREATE DATABASE IF NOT EXISTS iam;" || {
  echo "[ERROR] failed to create iam database in mariadb"
  exit 1
}

run_mysql_root_sql "DROP USER IF EXISTS 'iam'@'%'; DROP USER IF EXISTS 'iam'@'localhost'; DROP USER IF EXISTS 'iam'@'127.0.0.1'; CREATE USER 'iam'@'%' IDENTIFIED BY '${PASSWORD}'; CREATE USER 'iam'@'localhost' IDENTIFIED BY '${PASSWORD}'; CREATE USER 'iam'@'127.0.0.1' IDENTIFIED BY '${PASSWORD}'; GRANT ALL PRIVILEGES ON iam.* TO 'iam'@'%'; GRANT ALL PRIVILEGES ON iam.* TO 'iam'@'localhost'; GRANT ALL PRIVILEGES ON iam.* TO 'iam'@'127.0.0.1'; FLUSH PRIVILEGES;" || {
  echo "[ERROR] failed to create/grant privileges for user iam"
  exit 1
}

docker exec "${MDB_CTN}" mysql -h127.0.0.1 -uiam -p"${PASSWORD}" -e 'select 1' >/dev/null 2>&1 || {
  echo "[ERROR] iam mysql user verification failed"
  exit 1
}

import_mysql_file "${IAM_ROOT}/configs/iam.sql" "iam" || {
  echo "[ERROR] failed to import configs/iam.sql"
  exit 1
}

docker exec -i "${MGO_CTN}" mongosh --quiet -u root -p "${PASSWORD}" --authenticationDatabase admin <<JS
use iam_analytics
if (!db.getUser('iam')) {
  db.createUser({ user: 'iam', pwd: '${PASSWORD}', roles: ['dbOwner'] })
}
JS

echo "[INFO] generating certs and config files ..."

# Normalize potential CRLF from Windows checkout to avoid bash parse errors in WSL.
tr -d '\r' < "${IAM_ROOT}/scripts/install/environment.sh" > "${ENV_FILE_UNIX}"

# gencerts/genconfig depend on scripts/lib/*.sh. Normalize these files in-place
# to make WSL execution robust when repository was checked out with CRLF.
for f in \
  "${IAM_ROOT}/scripts/genconfig.sh" \
  "${IAM_ROOT}/scripts/common.sh" \
  "${IAM_ROOT}/scripts/lib/init.sh" \
  "${IAM_ROOT}/scripts/lib/util.sh" \
  "${IAM_ROOT}/scripts/lib/logging.sh" \
  "${IAM_ROOT}/scripts/lib/color.sh" \
  "${IAM_ROOT}/scripts/lib/version.sh" \
  "${IAM_ROOT}/scripts/lib/golang.sh"; do
  sed -i 's/\r$//' "${f}"
done

export IAM_CONFIG_DIR="${CFG_DIR}"
export IAM_LOG_DIR="${LOG_DIR}"
export PASSWORD="${PASSWORD}"
export MARIADB_PASSWORD="${PASSWORD}"
export IAM_APISERVER_HOST=127.0.0.1
export IAM_AUTHZ_SERVER_HOST=127.0.0.1
export IAM_PUMP_HOST=127.0.0.1
export IAM_WATCHER_HOST=127.0.0.1

IAM_APISERVER_GRPC_PORT="$(pick_port 8081)"
IAM_APISERVER_INSECURE_PORT="$(pick_port 8080)"
IAM_APISERVER_SECURE_PORT="$(pick_port 8443)"
IAM_AUTHZ_SERVER_INSECURE_PORT="$(pick_port 9090)"
IAM_AUTHZ_SERVER_SECURE_PORT="$(pick_port 9443)"
IAM_PUMP_HEALTH_PORT="$(pick_port 7070)"
IAM_WATCHER_HEALTH_PORT="$(pick_port 5050)"

if [[ "${IAM_APISERVER_INSECURE_PORT}" != "8080" || "${IAM_AUTHZ_SERVER_INSECURE_PORT}" != "9090" || "${IAM_PUMP_HEALTH_PORT}" != "7070" || "${IAM_WATCHER_HEALTH_PORT}" != "5050" ]]; then
  echo "[WARN] default ports are occupied, switched to available ports: apiserver=${IAM_APISERVER_INSECURE_PORT}, authz=${IAM_AUTHZ_SERVER_INSECURE_PORT}, pump=${IAM_PUMP_HEALTH_PORT}, watcher=${IAM_WATCHER_HEALTH_PORT}"
fi

export IAM_APISERVER_GRPC_BIND_PORT="${IAM_APISERVER_GRPC_PORT}"
export IAM_APISERVER_INSECURE_BIND_PORT="${IAM_APISERVER_INSECURE_PORT}"
export IAM_APISERVER_SECURE_BIND_PORT="${IAM_APISERVER_SECURE_PORT}"
export IAM_AUTHZ_SERVER_INSECURE_BIND_PORT="${IAM_AUTHZ_SERVER_INSECURE_PORT}"
export IAM_AUTHZ_SERVER_SECURE_BIND_PORT="${IAM_AUTHZ_SERVER_SECURE_PORT}"
export MARIADB_HOST=127.0.0.1:${HOST_MARIADB_PORT}
export REDIS_HOST=127.0.0.1
export REDIS_PORT=${HOST_REDIS_PORT}
export REDIS_PASSWORD="${PASSWORD}"
export MONGO_HOST=127.0.0.1
export MONGO_PORT=${HOST_MONGO_PORT}
export MONGO_ADMIN_USERNAME=root
export MONGO_ADMIN_PASSWORD="${PASSWORD}"
export MONGO_USERNAME=iam
export MONGO_PASSWORD="${PASSWORD}"
export IAM_PUMP_COLLECTION_NAME=iam_analytics
export IAM_PUMP_MONGO_URL="mongodb://iam:${PASSWORD}@127.0.0.1:${HOST_MONGO_PORT}/iam_analytics?authSource=iam_analytics"
export IAM_APISERVER_INSECURE_BIND_ADDRESS=0.0.0.0
export IAM_AUTHZ_SERVER_INSECURE_BIND_ADDRESS=0.0.0.0
export CONFIG_USER_CLIENT_CERTIFICATE="${CERT_DIR}/admin.pem"
export CONFIG_USER_CLIENT_KEY="${CERT_DIR}/admin-key.pem"
export CONFIG_SERVER_CERTIFICATE_AUTHORITY="${CERT_DIR}/ca.pem"

source "${ENV_FILE_UNIX}"

# Generate CA and service certs locally with openssl (no cfssl required).
openssl genrsa -out "${CERT_DIR}/ca-key.pem" 2048 >/dev/null 2>&1
openssl req -x509 -new -nodes -key "${CERT_DIR}/ca-key.pem" -sha256 -days 36500 \
  -subj "/C=CN/ST=BeiJing/L=BeiJing/O=marmotedu/OU=iam/CN=iam-ca" \
  -out "${CERT_DIR}/ca.pem" >/dev/null 2>&1

generate_server_cert "iam-apiserver" "DNS:localhost,IP:127.0.0.1,DNS:iam.api.marmotedu.com"
generate_server_cert "iam-authz-server" "DNS:localhost,IP:127.0.0.1,DNS:iam.authz.marmotedu.com"

bash "${IAM_ROOT}/scripts/genconfig.sh" "${ENV_FILE_UNIX}" configs/iam-apiserver.yaml > "${CFG_DIR}/iam-apiserver.yaml"
bash "${IAM_ROOT}/scripts/genconfig.sh" "${ENV_FILE_UNIX}" configs/iam-authz-server.yaml > "${CFG_DIR}/iam-authz-server.yaml"
bash "${IAM_ROOT}/scripts/genconfig.sh" "${ENV_FILE_UNIX}" configs/iam-pump.yaml > "${CFG_DIR}/iam-pump.yaml"
bash "${IAM_ROOT}/scripts/genconfig.sh" "${ENV_FILE_UNIX}" configs/iam-watcher.yaml > "${CFG_DIR}/iam-watcher.yaml"

sed -i -E "s#^(health-check-address: ).*#\\10.0.0.0:${IAM_PUMP_HEALTH_PORT}#" "${CFG_DIR}/iam-pump.yaml"
sed -i -E "s#^(health-check-address: ).*#\\10.0.0.0:${IAM_WATCHER_HEALTH_PORT}#" "${CFG_DIR}/iam-watcher.yaml"

echo "[INFO] building binaries ..."
make build BINS="iam-apiserver iam-authz-server iam-pump iam-watcher"

# Re-check dependency containers after build in case Docker daemon restarted during compilation.
for c in "${MDB_CTN}" "${RDS_CTN}" "${MGO_CTN}"; do
  running="$(docker inspect -f '{{.State.Running}}' "${c}" 2>/dev/null || echo false)"
  if [[ "${running}" != "true" ]]; then
    echo "[ERROR] dependency container is not running: ${c}"
    echo "[HINT] docker logs ${c}"
    exit 1
  fi
done

BIN_DIR="${OUTPUT_DIR}/platforms/linux/amd64"

echo "[INFO] starting IAM services in background ..."
start_binary "iam-apiserver" "${BIN_DIR}/iam-apiserver" "${CFG_DIR}/iam-apiserver.yaml" "http://127.0.0.1:${IAM_APISERVER_INSECURE_PORT}/healthz" "${IAM_APISERVER_INSECURE_PORT}" "${IAM_APISERVER_SECURE_PORT}" "${IAM_APISERVER_GRPC_PORT}"
start_binary "iam-authz-server" "${BIN_DIR}/iam-authz-server" "${CFG_DIR}/iam-authz-server.yaml" "http://127.0.0.1:${IAM_AUTHZ_SERVER_INSECURE_PORT}/healthz" "${IAM_AUTHZ_SERVER_INSECURE_PORT}" "${IAM_AUTHZ_SERVER_SECURE_PORT}"
start_binary "iam-pump" "${BIN_DIR}/iam-pump" "${CFG_DIR}/iam-pump.yaml" "http://127.0.0.1:${IAM_PUMP_HEALTH_PORT}/healthz" "${IAM_PUMP_HEALTH_PORT}"
start_binary "iam-watcher" "${BIN_DIR}/iam-watcher" "${CFG_DIR}/iam-watcher.yaml" "http://127.0.0.1:${IAM_WATCHER_HEALTH_PORT}/healthz" "${IAM_WATCHER_HEALTH_PORT}"

echo "[INFO] verifying login API ..."
LOGIN_RESP="$(curl --noproxy '*' -sS -XPOST -H 'Content-Type: application/json' -d '{"username":"admin","password":"Admin@2021"}' "http://127.0.0.1:${IAM_APISERVER_INSECURE_PORT}/login" || true)"
TOKEN="$(echo "${LOGIN_RESP}" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)"
if [[ -z "${TOKEN}" ]]; then
  echo "[WARN] login token check failed. You can inspect logs in ${LOG_DIR}."
else
  echo "[OK] login token acquired."
fi

cat <<EOF

[DONE] IAM local stack is up (WSL + Ubuntu mode)
  - mariadb:         127.0.0.1:${HOST_MARIADB_PORT}
  - redis:           127.0.0.1:${HOST_REDIS_PORT}
  - mongo:           127.0.0.1:${HOST_MONGO_PORT}
  - iam-apiserver:   http://127.0.0.1:${IAM_APISERVER_INSECURE_PORT}/healthz
  - iam-authz-server:http://127.0.0.1:${IAM_AUTHZ_SERVER_INSECURE_PORT}/healthz
  - iam-pump:        http://127.0.0.1:${IAM_PUMP_HEALTH_PORT}/healthz
  - iam-watcher:     http://127.0.0.1:${IAM_WATCHER_HEALTH_PORT}/healthz

Logs:
  ${LOG_DIR}

PID files:
  ${RUN_DIR}

To stop quickly:
  kill \
    \$(cat ${RUN_DIR}/iam-apiserver.pid) \
    \$(cat ${RUN_DIR}/iam-authz-server.pid) \
    \$(cat ${RUN_DIR}/iam-pump.pid) \
    \$(cat ${RUN_DIR}/iam-watcher.pid)

To stop dependency containers:
  docker rm -f ${MDB_CTN} ${RDS_CTN} ${MGO_CTN}

EOF
