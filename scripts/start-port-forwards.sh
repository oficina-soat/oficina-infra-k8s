#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/common.sh"

AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
UPDATE_KUBECONFIG="${UPDATE_KUBECONFIG:-false}"
APP_NAMESPACE="default"
FORWARD_APP="${FORWARD_APP:-true}"
FORWARD_MAILHOG="${FORWARD_MAILHOG:-true}"
FORWARD_KEYCLOAK="${FORWARD_KEYCLOAK:-false}"
PORT_FORWARD_SUMMARY=""

usage() {
  cat <<EOF
Uso:
  $(basename "$0")

Variaveis suportadas:
  UPDATE_KUBECONFIG  true|false. Default: false
  EKS_CLUSTER_NAME   Obrigatoria se UPDATE_KUBECONFIG=true
  AWS_REGION         Regiao AWS. Default: us-east-1
  FORWARD_APP        true|false. Default: true
  FORWARD_MAILHOG    true|false. Default: true
  FORWARD_KEYCLOAK   true|false. Default: false
EOF
}

service_exists() {
  local namespace="$1"
  local service_name="$2"
  kubectl get svc "${service_name}" --namespace "${namespace}" >/dev/null 2>&1
}

start_port_forward() {
  local namespace="$1"
  local service_name="$2"
  local ports="$3"
  local slug="$4"
  local summary_line="$5"
  local pf_dir="${REPO_ROOT}/.tmp/port-forward"
  local log_file="${pf_dir}/${slug}.log"
  local pid_file="${pf_dir}/${slug}.pid"

  if ! service_exists "${namespace}" "${service_name}"; then
    log "Port-forward ignorado: service ${namespace}/${service_name} nao existe"
    return 0
  fi

  mkdir -p "${pf_dir}"

  if [[ -f "${pid_file}" ]]; then
    local existing_pid
    existing_pid="$(cat "${pid_file}")"
    if kill -0 "${existing_pid}" >/dev/null 2>&1; then
      log "Port-forward ja ativo para ${namespace}/${service_name} (pid ${existing_pid})"
      PORT_FORWARD_SUMMARY+="${summary_line}"$'\n'
      return 0
    fi
    rm -f "${pid_file}"
  fi

  log "Iniciando port-forward para ${namespace}/${service_name} em ${ports}"
  nohup kubectl --namespace "${namespace}" port-forward "svc/${service_name}" ${ports} >"${log_file}" 2>&1 &
  local pf_pid=$!
  echo "${pf_pid}" > "${pid_file}"
  sleep 2

  if ! kill -0 "${pf_pid}" >/dev/null 2>&1; then
    echo "Falha ao iniciar port-forward para ${namespace}/${service_name}. Veja ${log_file}" >&2
    exit 1
  fi

  PORT_FORWARD_SUMMARY+="${summary_line}"$'\n'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd kubectl

if [[ "${UPDATE_KUBECONFIG}" == "true" ]]; then
  require_cmd aws
  require_non_empty "${EKS_CLUSTER_NAME}" "EKS_CLUSTER_NAME"
  log "Atualizando kubeconfig do cluster ${EKS_CLUSTER_NAME}"
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}"
fi

log "Configuracao efetiva"
cat <<EOF
UPDATE_KUBECONFIG=${UPDATE_KUBECONFIG}
AWS_REGION=${AWS_REGION}
EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME}
APP_NAMESPACE=${APP_NAMESPACE}
FORWARD_APP=${FORWARD_APP}
FORWARD_MAILHOG=${FORWARD_MAILHOG}
FORWARD_KEYCLOAK=${FORWARD_KEYCLOAK}
EOF

if [[ "${FORWARD_APP}" == "true" ]]; then
  start_port_forward "${APP_NAMESPACE}" "oficina-app" "8080:8080" "oficina-app" "Aplicacao: http://localhost:8080"
fi

if [[ "${FORWARD_MAILHOG}" == "true" ]]; then
  start_port_forward "default" "mailhog" "8025:8025 1025:1025" "mailhog" "MailHog UI: http://localhost:8025 | SMTP: localhost:1025"
fi

if [[ "${FORWARD_KEYCLOAK}" == "true" ]]; then
  start_port_forward "keycloak" "keycloak" "8081:8080" "keycloak" "Keycloak: http://localhost:8081"
fi

log "Encaminhamentos ativos"
cat <<EOF
${PORT_FORWARD_SUMMARY}Logs e PIDs: ${REPO_ROOT}/.tmp/port-forward
EOF
