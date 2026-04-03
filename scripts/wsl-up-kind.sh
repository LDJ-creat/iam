#!/usr/bin/env bash

# If invoked via `sh`, re-exec with bash to support bash-only syntax.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -Eeuo pipefail

IAM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${IAM_ROOT}"

NAMESPACE="${NAMESPACE:-iam}"
CLUSTER_NAME="${CLUSTER_NAME:-iam-dev}"
KUBECONFIG_CONTEXT="kind-${CLUSTER_NAME}"
PASSWORD="${PASSWORD:-iam123456}"
INGRESS_HOST="${INGRESS_HOST:-iam.local}"

# Keep defaults fast for daily reuse. Set RECREATE_CLUSTER=1 for a clean rebuild.
RECREATE_CLUSTER="${RECREATE_CLUSTER:-0}"
INSTALL_INGRESS="${INSTALL_INGRESS:-1}"

MARIADB_RELEASE="${MARIADB_RELEASE:-iam-mariadb}"
REDIS_RELEASE="${REDIS_RELEASE:-iam-redis}"
MONGODB_RELEASE="${MONGODB_RELEASE:-iam-mongodb}"

CFG_DIR="${IAM_ROOT}/deployments/iam/configs"
CERT_DIR="${IAM_ROOT}/deployments/iam/cert"
KIND_CFG="/tmp/kind-iam.yaml"
HELM_VALUES="/tmp/iam-kind-values.yaml"
INGRESS_FILE="/tmp/iam-ingress.yaml"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERROR] missing required command: $1"
    exit 1
  }
}

ensure_kind() {
  if command -v kind >/dev/null 2>&1; then
    return 0
  fi
  echo "[INFO] kind not found, installing kind..."
  curl -Lo /tmp/kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
  chmod +x /tmp/kind
  sudo mv /tmp/kind /usr/local/bin/kind
}

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    return 0
  fi
  echo "[INFO] helm not found, installing helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get_helm.sh
  chmod 700 /tmp/get_helm.sh
  /tmp/get_helm.sh
}

ensure_scripts_lf() {
  local f
  for f in \
    "${IAM_ROOT}/scripts/genconfig.sh" \
    "${IAM_ROOT}/scripts/common.sh" \
    "${IAM_ROOT}/scripts/lib/init.sh" \
    "${IAM_ROOT}/scripts/lib/util.sh" \
    "${IAM_ROOT}/scripts/lib/logging.sh" \
    "${IAM_ROOT}/scripts/lib/color.sh" \
    "${IAM_ROOT}/scripts/lib/version.sh" \
    "${IAM_ROOT}/scripts/lib/golang.sh" \
    "${IAM_ROOT}/scripts/install/environment.sh"; do
    if [[ -f "${f}" ]]; then
      sed -i 's/\r$//' "${f}"
    fi
  done
}

create_or_reuse_kind_cluster() {
  cat >"${KIND_CFG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 80
        protocol: TCP
      - containerPort: 30443
        hostPort: 443
        protocol: TCP
EOF

  if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    if [[ "${RECREATE_CLUSTER}" == "1" ]]; then
      echo "[INFO] RECREATE_CLUSTER=1, deleting existing kind cluster ${CLUSTER_NAME}"
      kind delete cluster --name "${CLUSTER_NAME}"
    else
      echo "[INFO] reusing existing kind cluster ${CLUSTER_NAME}"
      local node_name="${CLUSTER_NAME}-control-plane"
      local running
      running="$(docker inspect -f '{{.State.Running}}' "${node_name}" 2>/dev/null || echo false)"
      if [[ "${running}" != "true" ]]; then
        echo "[INFO] starting stopped kind node container: ${node_name}"
        docker start "${node_name}" >/dev/null
      fi
    fi
  fi

  if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    echo "[INFO] creating kind cluster ${CLUSTER_NAME}"
    env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy -u ALL_PROXY -u all_proxy \
      kind create cluster --config "${KIND_CFG}"
  fi

  kubectl config use-context "${KUBECONFIG_CONTEXT}" >/dev/null
  kubectl wait --for=condition=Ready nodes --all --timeout=240s
}

deploy_dependencies() {
  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
  helm repo update >/dev/null

  helm upgrade --install "${MARIADB_RELEASE}" bitnami/mariadb -n "${NAMESPACE}" \
    --set auth.rootPassword="${PASSWORD}" \
    --set auth.database=iam \
    --set auth.username=iam \
    --set auth.password="${PASSWORD}" \
    --set primary.persistence.size=5Gi >/dev/null

  helm upgrade --install "${REDIS_RELEASE}" bitnami/redis -n "${NAMESPACE}" \
    --set auth.enabled=true \
    --set auth.password="${PASSWORD}" \
    --set master.persistence.size=2Gi \
    --set replica.replicaCount=0 >/dev/null

  helm upgrade --install "${MONGODB_RELEASE}" bitnami/mongodb -n "${NAMESPACE}" \
    --set auth.rootUser=root \
    --set auth.rootPassword="${PASSWORD}" \
    --set auth.usernames[0]=iam \
    --set auth.passwords[0]="${PASSWORD}" \
    --set auth.databases[0]=iam_analytics \
    --set persistence.size=5Gi >/dev/null

  kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/instance="${MARIADB_RELEASE}" --timeout=900s
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/instance="${REDIS_RELEASE}" --timeout=900s
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/instance="${MONGODB_RELEASE}" --timeout=900s
}

generate_configs_and_certs() {
  mkdir -p "${CFG_DIR}" "${CERT_DIR}"
  ensure_scripts_lf

  export IAM_APISERVER_INSECURE_BIND_ADDRESS=0.0.0.0
  export IAM_AUTHZ_SERVER_INSECURE_BIND_ADDRESS=0.0.0.0

  export MARIADB_HOST="${MARIADB_RELEASE}.${NAMESPACE}.svc.cluster.local:3306"
  export MARIADB_PASSWORD="${PASSWORD}"
  export REDIS_HOST="${REDIS_RELEASE}-master.${NAMESPACE}.svc.cluster.local"
  export REDIS_PORT=6379
  export REDIS_PASSWORD="${PASSWORD}"
  export MONGO_HOST="${MONGODB_RELEASE}.${NAMESPACE}.svc.cluster.local"
  export MONGO_PORT=27017
  export MONGO_ADMIN_USERNAME=root
  export MONGO_ADMIN_PASSWORD="${PASSWORD}"
  export MONGO_USERNAME=iam
  export MONGO_PASSWORD="${PASSWORD}"
  export IAM_PUMP_COLLECTION_NAME=iam_analytics
  export IAM_PUMP_MONGO_URL="mongodb://iam:${PASSWORD}@${MONGODB_RELEASE}.${NAMESPACE}.svc.cluster.local:27017/iam_analytics?authSource=iam_analytics"

  export IAM_APISERVER_HOST=iam-apiserver
  export IAM_AUTHZ_SERVER_HOST=iam-authz-server
  export IAM_PUMP_HOST=iam-pump
  export IAM_WATCHER_HOST=iam-watcher

  bash "${IAM_ROOT}/scripts/genconfig.sh" "${IAM_ROOT}/scripts/install/environment.sh" configs/iam-apiserver.yaml > "${CFG_DIR}/iam-apiserver.yaml"
  bash "${IAM_ROOT}/scripts/genconfig.sh" "${IAM_ROOT}/scripts/install/environment.sh" configs/iam-authz-server.yaml > "${CFG_DIR}/iam-authz-server.yaml"
  bash "${IAM_ROOT}/scripts/genconfig.sh" "${IAM_ROOT}/scripts/install/environment.sh" configs/iam-pump.yaml > "${CFG_DIR}/iam-pump.yaml"
  bash "${IAM_ROOT}/scripts/genconfig.sh" "${IAM_ROOT}/scripts/install/environment.sh" configs/iam-watcher.yaml > "${CFG_DIR}/iam-watcher.yaml"
  bash "${IAM_ROOT}/scripts/genconfig.sh" "${IAM_ROOT}/scripts/install/environment.sh" configs/iamctl.yaml > "${CFG_DIR}/iamctl.yaml"

  openssl genrsa -out "${CERT_DIR}/ca-key.pem" 2048 >/dev/null 2>&1
  openssl req -x509 -new -nodes -key "${CERT_DIR}/ca-key.pem" -sha256 -days 36500 \
    -subj "/C=CN/ST=BeiJing/L=BeiJing/O=marmotedu/OU=iam/CN=iam-ca" \
    -out "${CERT_DIR}/ca.pem" >/dev/null 2>&1

  cat > /tmp/iam-apiserver.cnf <<EOF
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
OU = iam-apiserver
CN = iam-apiserver

[ req_ext ]
subjectAltName = DNS:localhost,IP:127.0.0.1,DNS:iam-apiserver,DNS:iam-apiserver.${NAMESPACE},DNS:iam-apiserver.${NAMESPACE}.svc

[ v3_ext ]
subjectAltName = DNS:localhost,IP:127.0.0.1,DNS:iam-apiserver,DNS:iam-apiserver.${NAMESPACE},DNS:iam-apiserver.${NAMESPACE}.svc
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
EOF

  openssl genrsa -out "${CERT_DIR}/iam-apiserver-key.pem" 2048 >/dev/null 2>&1
  openssl req -new -key "${CERT_DIR}/iam-apiserver-key.pem" -out /tmp/iam-apiserver.csr -config /tmp/iam-apiserver.cnf >/dev/null 2>&1
  openssl x509 -req -in /tmp/iam-apiserver.csr \
    -CA "${CERT_DIR}/ca.pem" -CAkey "${CERT_DIR}/ca-key.pem" -CAcreateserial \
    -out "${CERT_DIR}/iam-apiserver.pem" -days 36500 -sha256 -extensions v3_ext -extfile /tmp/iam-apiserver.cnf >/dev/null 2>&1

  cat > /tmp/iam-authz.cnf <<EOF
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
OU = iam-authz-server
CN = iam-authz-server

[ req_ext ]
subjectAltName = DNS:localhost,IP:127.0.0.1,DNS:iam-authz-server,DNS:iam-authz-server.${NAMESPACE},DNS:iam-authz-server.${NAMESPACE}.svc

[ v3_ext ]
subjectAltName = DNS:localhost,IP:127.0.0.1,DNS:iam-authz-server,DNS:iam-authz-server.${NAMESPACE},DNS:iam-authz-server.${NAMESPACE}.svc
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
EOF

  openssl genrsa -out "${CERT_DIR}/iam-authz-server-key.pem" 2048 >/dev/null 2>&1
  openssl req -new -key "${CERT_DIR}/iam-authz-server-key.pem" -out /tmp/iam-authz.csr -config /tmp/iam-authz.cnf >/dev/null 2>&1
  openssl x509 -req -in /tmp/iam-authz.csr \
    -CA "${CERT_DIR}/ca.pem" -CAkey "${CERT_DIR}/ca-key.pem" -CAcreateserial \
    -out "${CERT_DIR}/iam-authz-server.pem" -days 36500 -sha256 -extensions v3_ext -extfile /tmp/iam-authz.cnf >/dev/null 2>&1
}

import_schema_and_apply_configmaps() {
  kubectl -n "${NAMESPACE}" exec "${MARIADB_RELEASE}-0" -- \
    mysql -uroot -p"${PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS iam;" >/dev/null

  cat "${IAM_ROOT}/configs/iam.sql" | kubectl -n "${NAMESPACE}" exec -i "${MARIADB_RELEASE}-0" -- \
    mysql -uroot -p"${PASSWORD}" iam >/dev/null

  kubectl -n "${NAMESPACE}" delete configmap iam iam-cert --ignore-not-found >/dev/null
  kubectl -n "${NAMESPACE}" create configmap iam --from-file="${CFG_DIR}/" >/dev/null
  kubectl -n "${NAMESPACE}" create configmap iam-cert --from-file="${CERT_DIR}/" >/dev/null
}

deploy_iam() {
  cat > "${HELM_VALUES}" <<EOF
image:
  pullPolicy: IfNotPresent
imagePullSecrets: []
apiServer:
  image:
    repository: ccr.ccs.tencentyun.com/marmotedu/iam-apiserver-amd64
authzServer:
  image:
    repository: ccr.ccs.tencentyun.com/marmotedu/iam-authz-server-amd64
pump:
  image:
    repository: ccr.ccs.tencentyun.com/marmotedu/iam-pump-amd64
watcher:
  image:
    repository: ccr.ccs.tencentyun.com/marmotedu/iam-watcher-amd64
iamctl:
  image:
    repository: ccr.ccs.tencentyun.com/marmotedu/iamctl-amd64
ingress:
  enabled: false
EOF

  helm upgrade --install iam "${IAM_ROOT}/deployments/iam" -n "${NAMESPACE}" -f "${HELM_VALUES}" >/dev/null

  kubectl -n "${NAMESPACE}" rollout status deploy/iam-apiserver --timeout=600s
  kubectl -n "${NAMESPACE}" rollout status deploy/iam-authz-server --timeout=600s
  kubectl -n "${NAMESPACE}" rollout status deploy/iam-pump --timeout=600s
  kubectl -n "${NAMESPACE}" rollout status deploy/iam-watcher --timeout=600s
  kubectl -n "${NAMESPACE}" rollout status deploy/iamctl --timeout=600s
}

install_ingress_and_route() {
  if [[ "${INSTALL_INGRESS}" != "1" ]]; then
    echo "[INFO] INSTALL_INGRESS=0, skip ingress setup"
    return 0
  fi

  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml >/dev/null

  # Replace controller image with a mirror that is typically reachable in CN networks.
  kubectl -n ingress-nginx set image deploy/ingress-nginx-controller \
    controller=m.daocloud.io/registry.k8s.io/ingress-nginx/controller:v1.15.1 >/dev/null

  # Workaround: admission jobs may fail due to registry reachability; create secret and bypass webhook in dev env.
  mkdir -p /tmp/ing-adm
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -subj "/CN=ingress-nginx-admission" \
    -keyout /tmp/ing-adm/key.pem -out /tmp/ing-adm/cert.pem >/dev/null 2>&1
  kubectl -n ingress-nginx create secret tls ingress-nginx-admission \
    --cert=/tmp/ing-adm/cert.pem --key=/tmp/ing-adm/key.pem \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found >/dev/null
  kubectl -n ingress-nginx delete job ingress-nginx-admission-create ingress-nginx-admission-patch --ignore-not-found >/dev/null

  kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=600s

  cat > "${INGRESS_FILE}" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: iam-apiserver
  namespace: ${NAMESPACE}
spec:
  ingressClassName: nginx
  rules:
  - host: ${INGRESS_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: iam-apiserver
            port:
              number: 8080
EOF

  kubectl apply -f "${INGRESS_FILE}" >/dev/null
}

verify_login() {
  kubectl -n "${NAMESPACE}" port-forward svc/iam-apiserver 28080:8080 >/tmp/iam-apiserver-pf.log 2>&1 &
  local pf_pid=$!
  sleep 3

  local resp token
  resp="$(curl --noproxy '*' -sS -XPOST -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"Admin@2021"}' \
    'http://127.0.0.1:28080/login' || true)"
  token="$(echo "${resp}" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

  kill "${pf_pid}" >/dev/null 2>&1 || true
  wait "${pf_pid}" >/dev/null 2>&1 || true

  if [[ -z "${token}" ]]; then
    echo "[WARN] login verification failed: ${resp}"
  else
    echo "[OK] login token acquired via iam-apiserver service"
  fi
}

print_summary() {
  echo
  echo "[DONE] kind-based IAM stack is up"
  echo "  - context: ${KUBECONFIG_CONTEXT}"
  echo "  - namespace: ${NAMESPACE}"
  echo "  - ingress host: ${INGRESS_HOST}"
  echo
  kubectl -n "${NAMESPACE}" get pods
  echo
  if [[ "${INSTALL_INGRESS}" == "1" ]]; then
    cat <<EOF
Quick verify through ingress controller (Windows PowerShell):

  wsl --% -d Ubuntu-22.04 -- kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 38080:80

  # New terminal:
  #   healthz
  #   $h = @{ Host = '${INGRESS_HOST}' }
  #   Invoke-RestMethod -Uri 'http://127.0.0.1:38080/healthz' -Headers $h -Method Get
  #   login
  #   $body = '{"username":"admin","password":"Admin@2021"}'
  #   Invoke-RestMethod -Uri 'http://127.0.0.1:38080/login' -Headers $h -Method Post -ContentType 'application/json' -Body $body
EOF
  fi
}

main() {
  echo "[INFO] checking prerequisites ..."
  require_cmd docker
  require_cmd kubectl
  require_cmd curl
  require_cmd openssl
  ensure_kind
  ensure_helm

  create_or_reuse_kind_cluster
  deploy_dependencies
  generate_configs_and_certs
  import_schema_and_apply_configmaps
  deploy_iam
  install_ingress_and_route
  verify_login
  print_summary
}

main "$@"
