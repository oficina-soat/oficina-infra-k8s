#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"

AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
UPDATE_KUBECONFIG="${UPDATE_KUBECONFIG:-false}"
IMAGE_REF="${IMAGE_REF:-}"
DEPLOY_APP="${DEPLOY_APP:-auto}"
REGENERATE_JWT="${REGENERATE_JWT:-false}"
JWT_DIR="${JWT_DIR:-.tmp/jwt}"
OFICINA_AUTH_ISSUER="${OFICINA_AUTH_ISSUER:-oficina-api}"
OFICINA_AUTH_JWKS_URI="${OFICINA_AUTH_JWKS_URI:-file:/jwt/publicKey.pem}"
OFICINA_AUTH_FORCE_LEGACY="${OFICINA_AUTH_FORCE_LEGACY:-false}"
API_GATEWAY_ID="${API_GATEWAY_ID:-}"
API_GATEWAY_NAME="${API_GATEWAY_NAME:-${EKS_CLUSTER_NAME:+${EKS_CLUSTER_NAME}-http-api}}"
OBSERVABILITY_ENABLED="${OBSERVABILITY_ENABLED:-true}"
OBSERVABILITY_APP_LOG_GROUP_NAME="${OFICINA_OBSERVABILITY_APP_LOG_GROUP_NAME}"
OBSERVABILITY_PROMETHEUS_LOG_GROUP_NAME="${EKS_CLUSTER_NAME:+/aws/containerinsights/${EKS_CLUSTER_NAME}/prometheus}"
OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS="${OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS:-true}"
OBSERVABILITY_AWS_CREDENTIALS_SECRET_ENABLED="${OBSERVABILITY_AWS_CREDENTIALS_SECRET_ENABLED:-true}"
OBSERVABILITY_AWS_CREDENTIALS_SECRET_NAME="${OBSERVABILITY_AWS_CREDENTIALS_SECRET_NAME:-oficina-observability-aws-credentials}"
OBSERVABILITY_FLUENT_BIT_IMAGE="public.ecr.aws/aws-observability/aws-for-fluent-bit:2.34.3.20260423"
OBSERVABILITY_CWAGENT_IMAGE="public.ecr.aws/cloudwatch-agent/cloudwatch-agent:1.300066.1b1374"
DB_SECRET_NAME="${DB_SECRET_NAME:-${OFICINA_DB_K8S_SECRET_NAME}}"
APP_NAMESPACE="default"
PLATFORM_ENV_DIR="${PLATFORM_ENV_DIR:-${OFICINA_PLATFORM_OVERLAY_DIR}}"
APP_ENV_DIR="${APP_ENV_DIR:-${OFICINA_APP_OVERLAY_DIR}}"

usage() {
  cat <<EOF
Uso:
  $(basename "$0")

Variaveis suportadas:
  IMAGE_REF              Imagem da aplicacao. Quando ausente, aplica somente a plataforma
  UPDATE_KUBECONFIG      true|false. Default: false
  EKS_CLUSTER_NAME       Obrigatoria para renderizar os overlays do laboratorio
  AWS_REGION             Regiao AWS. Default: us-east-1
  REGENERATE_JWT         true|false. Default: false; chaves ausentes em JWT_DIR ainda sao geradas
  JWT_DIR                Diretorio das chaves JWT. Default: .tmp/jwt
  OFICINA_AUTH_ISSUER    Issuer esperado pela aplicacao. Default: oficina-api
  OFICINA_AUTH_JWKS_URI  JWKS/public key location. Default: file:/jwt/publicKey.pem
  OFICINA_AUTH_FORCE_LEGACY true|false. Default: false
  API_GATEWAY_ID         Opcional; ID do HTTP API usado para descobrir o issuer publico
  API_GATEWAY_NAME       Opcional; default <EKS_CLUSTER_NAME>-http-api
  OBSERVABILITY_ENABLED                    true|false. Default: true
  OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS true|false. Default: true
  OBSERVABILITY_AWS_CREDENTIALS_SECRET_ENABLED true|false. Default: true
EOF
}

normalize_url_like_value() {
  local value="$1"

  if [[ "${value}" == http://* || "${value}" == https://* ]]; then
    printf '%s' "${value%/}"
    return
  fi

  printf '%s' "${value}"
}

resolve_api_gateway_id() {
  if [[ -n "${API_GATEWAY_ID}" ]]; then
    printf '%s' "${API_GATEWAY_ID}"
    return
  fi

  if [[ -z "${API_GATEWAY_NAME}" ]] || ! command -v aws >/dev/null 2>&1; then
    return
  fi

  aws --region "${AWS_REGION}" apigatewayv2 get-apis \
    --query "Items[?Name=='${API_GATEWAY_NAME}'].ApiId | [0]" \
    --output text 2>/dev/null | sed '/^None$/d'
}

api_gateway_endpoint() {
  local api_id="$1"

  aws --region "${AWS_REGION}" apigatewayv2 get-api \
    --api-id "${api_id}" \
    --query 'ApiEndpoint' \
    --output text 2>/dev/null | sed '/^None$/d'
}

prepare_auth_config() {
  local api_id=""
  local should_migrate_legacy="false"
  local legacy_auth_issuer="${OFICINA_AUTH_ISSUER}"
  local legacy_auth_jwks_uri="${OFICINA_AUTH_JWKS_URI}"

  OFICINA_AUTH_ISSUER="$(normalize_url_like_value "${OFICINA_AUTH_ISSUER}")"
  OFICINA_AUTH_JWKS_URI="$(normalize_url_like_value "${OFICINA_AUTH_JWKS_URI}")"

  if [[ "${OFICINA_AUTH_FORCE_LEGACY}" != "true" && "${OFICINA_AUTH_ISSUER}" == "oficina-api" ]] \
    && [[ -z "${OFICINA_AUTH_JWKS_URI}" || "${OFICINA_AUTH_JWKS_URI}" == "file:/jwt/publicKey.pem" ]]; then
    should_migrate_legacy="true"
    OFICINA_AUTH_ISSUER=""
    OFICINA_AUTH_JWKS_URI=""
  fi

  if [[ -z "${OFICINA_AUTH_ISSUER}" ]]; then
    api_id="$(resolve_api_gateway_id || true)"
    if [[ -n "${api_id}" ]]; then
      OFICINA_AUTH_ISSUER="$(normalize_url_like_value "$(api_gateway_endpoint "${api_id}")")"
    fi
  fi

  if [[ -z "${OFICINA_AUTH_JWKS_URI}" && ( "${OFICINA_AUTH_ISSUER}" == http://* || "${OFICINA_AUTH_ISSUER}" == https://* ) ]]; then
    OFICINA_AUTH_JWKS_URI="${OFICINA_AUTH_ISSUER}/.well-known/jwks.json"
  fi

  if [[ "${should_migrate_legacy}" == "true" && -n "${OFICINA_AUTH_ISSUER}" && -n "${OFICINA_AUTH_JWKS_URI}" ]]; then
    log "Migrando configuracao legada de JWT para o issuer publico ${OFICINA_AUTH_ISSUER}."
  elif [[ "${should_migrate_legacy}" == "true" ]]; then
    OFICINA_AUTH_ISSUER="${legacy_auth_issuer}"
    OFICINA_AUTH_JWKS_URI="${legacy_auth_jwks_uri}"
    log "API Gateway nao encontrado; mantendo configuracao legada de JWT."
  fi
}

secret_exists() {
  local namespace="$1"
  local secret_name="$2"
  kubectl get secret "${secret_name}" --namespace "${namespace}" >/dev/null 2>&1
}

show_app_diagnostics() {
  log "Diagnostico do deployment ${OFICINA_APP_NAME}"
  kubectl get "deployment/${OFICINA_APP_NAME}" "service/${OFICINA_APP_NAME}" \
    --namespace "${APP_NAMESPACE}" \
    --output wide || true
  kubectl get pods \
    --namespace "${APP_NAMESPACE}" \
    --selector "app.kubernetes.io/name=${OFICINA_APP_NAME}" \
    --output wide || true
  kubectl describe "deployment/${OFICINA_APP_NAME}" --namespace "${APP_NAMESPACE}" || true
  kubectl logs \
    --namespace "${APP_NAMESPACE}" \
    --selector "app.kubernetes.io/name=${OFICINA_APP_NAME}" \
    --tail=120 \
    --all-containers=true || true
}

verify_app_service_endpoints() {
  local endpoint_ips=""

  endpoint_ips="$(
    kubectl get endpoints "${OFICINA_APP_NAME}" \
      --namespace "${APP_NAMESPACE}" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true
  )"

  if [[ -z "${endpoint_ips}" ]]; then
    echo "Service ${OFICINA_APP_NAME} nao possui endpoints prontos apos o rollout." >&2
    show_app_diagnostics
    exit 1
  fi
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'
}

render_platform_overlay() {
  local escaped_observability_app_log_group_name
  local escaped_observability_prometheus_log_group_name
  local escaped_observability_fluent_bit_image
  local escaped_observability_cwagent_image
  local observability_cwagent_replicas
  local observability_node_os_selector
  escaped_observability_app_log_group_name="$(escape_sed_replacement "${OBSERVABILITY_APP_LOG_GROUP_NAME}")"
  escaped_observability_prometheus_log_group_name="$(escape_sed_replacement "${OBSERVABILITY_PROMETHEUS_LOG_GROUP_NAME}")"
  escaped_observability_fluent_bit_image="$(escape_sed_replacement "${OBSERVABILITY_FLUENT_BIT_IMAGE}")"
  escaped_observability_cwagent_image="$(escape_sed_replacement "${OBSERVABILITY_CWAGENT_IMAGE}")"
  if is_truthy "${OBSERVABILITY_ENABLED}"; then
    observability_node_os_selector="linux"
  else
    observability_node_os_selector="disabled"
  fi
  if is_truthy "${OBSERVABILITY_ENABLED}" && is_truthy "${OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS}"; then
    observability_cwagent_replicas="1"
  else
    observability_cwagent_replicas="0"
  fi
  kubectl kustomize "${PLATFORM_ENV_DIR}" |
    sed "s|OBSERVABILITY_CLUSTER_NAME_PLACEHOLDER|${EKS_CLUSTER_NAME}|g" |
    sed "s|OBSERVABILITY_AWS_REGION_PLACEHOLDER|${AWS_REGION}|g" |
    sed "s|OBSERVABILITY_APP_LOG_GROUP_PLACEHOLDER|${escaped_observability_app_log_group_name}|g" |
    sed "s|OBSERVABILITY_PROMETHEUS_LOG_GROUP_PLACEHOLDER|${escaped_observability_prometheus_log_group_name}|g" |
    sed "s|OBSERVABILITY_CWAGENT_REPLICAS_PLACEHOLDER|${observability_cwagent_replicas}|g" |
    sed "s|OBSERVABILITY_NODE_OS_SELECTOR_PLACEHOLDER|${observability_node_os_selector}|g" |
    sed "s|OBSERVABILITY_FLUENT_BIT_IMAGE_PLACEHOLDER|${escaped_observability_fluent_bit_image}|g" |
    sed "s|OBSERVABILITY_CWAGENT_IMAGE_PLACEHOLDER|${escaped_observability_cwagent_image}|g"
}

render_app_overlay() {
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

cleanup_legacy_observability_resources() {
  log "Removendo recursos legados de observabilidade no namespace ${APP_NAMESPACE}, se existirem"
  kubectl delete \
    daemonset/fluent-bit \
    deployment/cwagent-prometheus \
    serviceaccount/fluent-bit \
    serviceaccount/cwagent-prometheus \
    configmap/oficina-fluent-bit-config \
    configmap/oficina-prometheus-cwagentconfig \
    configmap/oficina-prometheus-config \
    --namespace "${APP_NAMESPACE}" \
    --ignore-not-found
}

prepare_observability_aws_credentials_secret() {
  if ! is_truthy "${OBSERVABILITY_ENABLED}" || ! is_truthy "${OBSERVABILITY_AWS_CREDENTIALS_SECRET_ENABLED}"; then
    return
  fi

  if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    log "Credenciais AWS nao estao em variaveis de ambiente; coletores usarao a cadeia padrao da AWS."
    return
  fi

  local secret_args=()
  secret_args+=(--from-literal="AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}")
  secret_args+=(--from-literal="AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}")
  secret_args+=(--from-literal="AWS_REGION=${AWS_REGION}")
  secret_args+=(--from-literal="AWS_DEFAULT_REGION=${AWS_REGION}")

  if [[ -n "${AWS_SESSION_TOKEN:-}" ]]; then
    secret_args+=(--from-literal="AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}")
  fi

  log "Criando/atualizando secret ${OBSERVABILITY_AWS_CREDENTIALS_SECRET_NAME} para os coletores de observabilidade."
  kubectl create secret generic "${OBSERVABILITY_AWS_CREDENTIALS_SECRET_NAME}" \
    --namespace amazon-cloudwatch \
    "${secret_args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

wait_observability_rollout() {
  if ! is_truthy "${OBSERVABILITY_ENABLED}"; then
    return
  fi

  log "Reiniciando coletores de observabilidade para aplicar configmaps atualizados"
  kubectl rollout restart daemonset/fluent-bit --namespace amazon-cloudwatch
  kubectl rollout status daemonset/fluent-bit --namespace amazon-cloudwatch --timeout=180s

  if is_truthy "${OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS}"; then
    kubectl rollout restart deployment/cwagent-prometheus --namespace amazon-cloudwatch
    kubectl rollout status deployment/cwagent-prometheus --namespace amazon-cloudwatch --timeout=180s
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd kubectl
require_cmd sed
prepare_auth_config
require_non_empty "${EKS_CLUSTER_NAME}" "EKS_CLUSTER_NAME"

case "${DEPLOY_APP}" in
  auto)
    if [[ -n "${IMAGE_REF}" ]]; then
      DEPLOY_APP="true"
    else
      DEPLOY_APP="false"
    fi
    ;;
  true | false)
    ;;
  *)
    echo "DEPLOY_APP invalido: ${DEPLOY_APP}. Use auto, true ou false." >&2
    exit 1
    ;;
esac

if [[ "${UPDATE_KUBECONFIG}" == "true" ]]; then
  require_cmd aws
fi

if [[ "${DEPLOY_APP}" == "true" ]]; then
  require_cmd openssl
  require_non_empty "${EKS_CLUSTER_NAME}" "EKS_CLUSTER_NAME"
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
PLATFORM_ENV_DIR=${PLATFORM_ENV_DIR}
APP_ENV_DIR=${APP_ENV_DIR}
DEPLOY_APP=${DEPLOY_APP}
REGENERATE_JWT=${REGENERATE_JWT}
JWT_DIR=${JWT_DIR}
OFICINA_AUTH_ISSUER=${OFICINA_AUTH_ISSUER}
OFICINA_AUTH_JWKS_URI=${OFICINA_AUTH_JWKS_URI}
OFICINA_AUTH_FORCE_LEGACY=${OFICINA_AUTH_FORCE_LEGACY}
OBSERVABILITY_ENABLED=${OBSERVABILITY_ENABLED}
OBSERVABILITY_APP_LOG_GROUP_NAME=${OBSERVABILITY_APP_LOG_GROUP_NAME}
OBSERVABILITY_PROMETHEUS_LOG_GROUP_NAME=${OBSERVABILITY_PROMETHEUS_LOG_GROUP_NAME}
OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS=${OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS}
OBSERVABILITY_AWS_CREDENTIALS_SECRET_ENABLED=${OBSERVABILITY_AWS_CREDENTIALS_SECRET_ENABLED}
OBSERVABILITY_AWS_CREDENTIALS_SECRET_NAME=${OBSERVABILITY_AWS_CREDENTIALS_SECRET_NAME}
OBSERVABILITY_FLUENT_BIT_IMAGE=${OBSERVABILITY_FLUENT_BIT_IMAGE}
OBSERVABILITY_CWAGENT_IMAGE=${OBSERVABILITY_CWAGENT_IMAGE}
DB_SECRET_NAME=${DB_SECRET_NAME}
EOF

if [[ "${UPDATE_KUBECONFIG}" == "true" ]]; then
  log "Atualizando kubeconfig do cluster ${EKS_CLUSTER_NAME}"
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}"
fi

log "Aplicando dependencias base do laboratorio"
render_platform_overlay | kubectl apply -f -
prepare_observability_aws_credentials_secret
cleanup_legacy_observability_resources
wait_observability_rollout

kubectl rollout status deployment/mailhog --namespace "${APP_NAMESPACE}" --timeout=180s

if [[ "${DEPLOY_APP}" == "true" ]]; then
  if secret_exists "${APP_NAMESPACE}" "${DB_SECRET_NAME}"; then
    log "Usando secret opcional ${APP_NAMESPACE}/${DB_SECRET_NAME}."
  else
    log "Secret opcional ${APP_NAMESPACE}/${DB_SECRET_NAME} ausente; seguindo sem variaveis de banco."
  fi

  if [[ "${REGENERATE_JWT}" == "true" || ! -f "${JWT_DIR}/privateKey.pem" || ! -f "${JWT_DIR}/publicKey.pem" ]]; then
    log "Gerando par de chaves JWT em ${JWT_DIR}"
    mkdir -p "${JWT_DIR}"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${JWT_DIR}/privateKey.pem"
    openssl pkey -in "${JWT_DIR}/privateKey.pem" -pubout -out "${JWT_DIR}/publicKey.pem"
  fi

  if [[ ! -f "${JWT_DIR}/privateKey.pem" || ! -f "${JWT_DIR}/publicKey.pem" ]]; then
    echo "Arquivos JWT nao encontrados em ${JWT_DIR}. Ajuste REGENERATE_JWT=true ou forneca os arquivos." >&2
    exit 1
  fi

  log "Aplicando secret ${OFICINA_JWT_K8S_SECRET_NAME}"
  kubectl create secret generic "${OFICINA_JWT_K8S_SECRET_NAME}" \
    --from-file=privateKey.pem="${JWT_DIR}/privateKey.pem" \
    --from-file=publicKey.pem="${JWT_DIR}/publicKey.pem" \
    --namespace "${APP_NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "Aplicando ambiente de laboratorio da aplicacao"
  render_app_overlay | kubectl apply -f -

  log "Reiniciando deployment ${OFICINA_APP_NAME} para aplicar secrets/configmaps atualizados"
  kubectl rollout restart "deployment/${OFICINA_APP_NAME}" --namespace "${APP_NAMESPACE}"

  if ! kubectl rollout status "deployment/${OFICINA_APP_NAME}" --namespace "${APP_NAMESPACE}" --timeout=300s; then
    show_app_diagnostics
    exit 1
  fi

  verify_app_service_endpoints
fi

log "Deploy concluido"
log "Para acesso local, execute: ${REPO_ROOT}/scripts/manual/start-port-forwards.sh"
