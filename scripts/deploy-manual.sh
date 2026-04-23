#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
UPDATE_KUBECONFIG="${UPDATE_KUBECONFIG:-false}"
IMAGE_REF="${IMAGE_REF:-}"
DEPLOY_APP="${DEPLOY_APP:-true}"
DEPLOY_KEYCLOAK="${DEPLOY_KEYCLOAK:-false}"
REGENERATE_JWT="${REGENERATE_JWT:-true}"
JWT_DIR="${JWT_DIR:-.tmp/jwt}"
OFICINA_AUTH_ISSUER="${OFICINA_AUTH_ISSUER:-oficina-api}"
OFICINA_AUTH_JWKS_URI="${OFICINA_AUTH_JWKS_URI:-file:/jwt/publicKey.pem}"
DB_SECRET_NAME="oficina-database-env"
APP_NAMESPACE="default"
APP_ENV_DIR="k8s/overlays/lab"

usage() {
  cat <<EOF
Uso:
  $(basename "$0")

Variaveis suportadas:
  IMAGE_REF              Imagem da aplicacao. Obrigatoria se DEPLOY_APP=true
  UPDATE_KUBECONFIG      true|false. Default: false
  EKS_CLUSTER_NAME       Obrigatoria se UPDATE_KUBECONFIG=true
  AWS_REGION             Regiao AWS. Default: us-east-1
  DEPLOY_APP             true|false. Default: true
  DEPLOY_KEYCLOAK        true|false. Default: false
  REGENERATE_JWT         true|false. Default: true
  JWT_DIR                Diretorio das chaves JWT. Default: .tmp/jwt
  OFICINA_AUTH_ISSUER    Issuer esperado pela aplicacao. Default: oficina-api
  OFICINA_AUTH_JWKS_URI  JWKS/public key location. Default: file:/jwt/publicKey.pem
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Comando obrigatorio nao encontrado: $1" >&2
    exit 1
  fi
}

require_non_empty() {
  local value="$1"
  local name="$2"
  if [[ -z "${value}" ]]; then
    echo "Variavel obrigatoria ausente: ${name}" >&2
    exit 1
  fi
}

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

secret_exists() {
  local namespace="$1"
  local secret_name="$2"
  kubectl get secret "${secret_name}" --namespace "${namespace}" >/dev/null 2>&1
}

show_app_diagnostics() {
  log "Diagnostico do deployment oficina-app"
  kubectl get deployment/oficina-app service/oficina-app \
    --namespace "${APP_NAMESPACE}" \
    --output wide || true
  kubectl get pods \
    --namespace "${APP_NAMESPACE}" \
    --selector app.kubernetes.io/name=oficina-app \
    --output wide || true
  kubectl describe deployment/oficina-app --namespace "${APP_NAMESPACE}" || true
  kubectl logs \
    --namespace "${APP_NAMESPACE}" \
    --selector app.kubernetes.io/name=oficina-app \
    --tail=120 \
    --all-containers=true || true
}

verify_app_service_endpoints() {
  local endpoint_ips=""

  endpoint_ips="$(
    kubectl get endpoints oficina-app \
      --namespace "${APP_NAMESPACE}" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true
  )"

  if [[ -z "${endpoint_ips}" ]]; then
    echo "Service oficina-app nao possui endpoints prontos apos o rollout." >&2
    show_app_diagnostics
    exit 1
  fi
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

render_overlay() {
  local escaped_image_ref
  local escaped_auth_issuer
  local escaped_auth_jwks_uri
  escaped_image_ref="$(escape_sed_replacement "${IMAGE_REF}")"
  escaped_auth_issuer="$(escape_sed_replacement "${OFICINA_AUTH_ISSUER}")"
  escaped_auth_jwks_uri="$(escape_sed_replacement "${OFICINA_AUTH_JWKS_URI}")"
  kubectl kustomize "${APP_ENV_DIR}" |
    sed "s|IMAGE_PLACEHOLDER|${escaped_image_ref}|g" |
    sed "s|OFICINA_AUTH_ISSUER_PLACEHOLDER|${escaped_auth_issuer}|g" |
    sed "s|OFICINA_AUTH_JWKS_URI_PLACEHOLDER|${escaped_auth_jwks_uri}|g"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd kubectl
require_cmd openssl
require_cmd sed

if [[ "${UPDATE_KUBECONFIG}" == "true" ]]; then
  require_cmd aws
  require_non_empty "${EKS_CLUSTER_NAME}" "EKS_CLUSTER_NAME"
fi

if [[ "${DEPLOY_APP}" == "true" ]]; then
  require_non_empty "${IMAGE_REF}" "IMAGE_REF"
fi

cd "${REPO_ROOT}"

log "Configuracao efetiva"
cat <<EOF
AWS_REGION=${AWS_REGION}
EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME}
UPDATE_KUBECONFIG=${UPDATE_KUBECONFIG}
IMAGE_REF=${IMAGE_REF}
APP_NAMESPACE=${APP_NAMESPACE}
APP_ENV_DIR=${APP_ENV_DIR}
DEPLOY_APP=${DEPLOY_APP}
DEPLOY_KEYCLOAK=${DEPLOY_KEYCLOAK}
REGENERATE_JWT=${REGENERATE_JWT}
JWT_DIR=${JWT_DIR}
OFICINA_AUTH_ISSUER=${OFICINA_AUTH_ISSUER}
OFICINA_AUTH_JWKS_URI=${OFICINA_AUTH_JWKS_URI}
DB_SECRET_NAME=${DB_SECRET_NAME}
EOF

if [[ "${UPDATE_KUBECONFIG}" == "true" ]]; then
  log "Atualizando kubeconfig do cluster ${EKS_CLUSTER_NAME}"
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}"
fi

if [[ "${DEPLOY_APP}" == "true" ]]; then
  if secret_exists "${APP_NAMESPACE}" "${DB_SECRET_NAME}"; then
    log "Usando secret opcional ${APP_NAMESPACE}/${DB_SECRET_NAME}."
  else
    log "Secret opcional ${APP_NAMESPACE}/${DB_SECRET_NAME} ausente; seguindo sem variaveis de banco."
  fi

  if [[ "${REGENERATE_JWT}" == "true" ]]; then
    log "Gerando novo par de chaves JWT"
    mkdir -p "${JWT_DIR}"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${JWT_DIR}/privateKey.pem"
    openssl pkey -in "${JWT_DIR}/privateKey.pem" -pubout -out "${JWT_DIR}/publicKey.pem"
  fi

  if [[ ! -f "${JWT_DIR}/privateKey.pem" || ! -f "${JWT_DIR}/publicKey.pem" ]]; then
    echo "Arquivos JWT nao encontrados em ${JWT_DIR}. Ajuste REGENERATE_JWT=true ou forneca os arquivos." >&2
    exit 1
  fi

  log "Aplicando secret oficina-jwt-keys"
  kubectl create secret generic oficina-jwt-keys \
    --from-file=privateKey.pem="${JWT_DIR}/privateKey.pem" \
    --from-file=publicKey.pem="${JWT_DIR}/publicKey.pem" \
    --namespace "${APP_NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "Aplicando ambiente de laboratorio da aplicacao"
  render_overlay | kubectl apply -f -

  log "Reiniciando deployment oficina-app para aplicar secrets/configmaps atualizados"
  kubectl rollout restart deployment/oficina-app --namespace "${APP_NAMESPACE}"

  kubectl rollout status deployment/mailhog --namespace "${APP_NAMESPACE}" --timeout=180s

  if ! kubectl rollout status deployment/oficina-app --namespace "${APP_NAMESPACE}" --timeout=300s; then
    show_app_diagnostics
    exit 1
  fi

  verify_app_service_endpoints
fi

if [[ "${DEPLOY_KEYCLOAK}" == "true" ]]; then
  log "Aplicando manifests do Keycloak"
  kubectl apply -k k8s/addons/keycloak
  kubectl rollout status deployment/keycloak --namespace keycloak --timeout=180s
fi

log "Deploy concluido"
log "Para acesso local, execute: ${REPO_ROOT}/scripts/start-port-forwards.sh"
