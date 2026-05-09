#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"

AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-${OFICINA_EKS_CLUSTER_NAME}}"
UPDATE_KUBECONFIG="${UPDATE_KUBECONFIG:-auto}"
APP_NAMESPACE="default"
FORWARD_APP="${FORWARD_APP:-true}"
FORWARD_MAILHOG="${FORWARD_MAILHOG:-true}"
PORT_FORWARD_SUMMARY=""

usage() {
  cat <<EOF
Uso:
  $(basename "$0")

Variaveis suportadas:
  UPDATE_KUBECONFIG  auto|true|false. Default: auto
  EKS_CLUSTER_NAME   Nome do cluster EKS. Default: ${OFICINA_EKS_CLUSTER_NAME}
  AWS_REGION         Regiao AWS. Default: us-east-1
  FORWARD_APP        true|false. Default: true
  FORWARD_MAILHOG    true|false. Default: true
EOF
}

current_kube_server() {
  kubectl config view --minify --output=jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true
}

eks_cluster_endpoint() {
  aws eks describe-cluster \
    --region "${AWS_REGION}" \
    --name "${EKS_CLUSTER_NAME}" \
    --query 'cluster.endpoint' \
    --output text 2>/dev/null || true
}

update_kubeconfig() {
  log "Atualizando kubeconfig do cluster ${EKS_CLUSTER_NAME}"
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}"
}

ensure_kubeconfig() {
  case "${UPDATE_KUBECONFIG}" in
    true)
      require_cmd aws
      require_non_empty "${EKS_CLUSTER_NAME}" "EKS_CLUSTER_NAME"
      update_kubeconfig
      ;;
    auto)
      if ! command -v aws >/dev/null 2>&1; then
        log "AWS CLI nao encontrado; usando kubeconfig atual."
        return 0
      fi

      require_non_empty "${EKS_CLUSTER_NAME}" "EKS_CLUSTER_NAME"

      local current_server expected_endpoint
      current_server="$(current_kube_server)"
      expected_endpoint="$(eks_cluster_endpoint)"

      if [[ -z "${expected_endpoint}" || "${expected_endpoint}" == "None" ]]; then
        log "Nao foi possivel consultar o endpoint do cluster ${EKS_CLUSTER_NAME}; usando kubeconfig atual."
        return 0
      fi

      if [[ "${current_server}" != "${expected_endpoint}" ]]; then
        log "Kubeconfig aponta para endpoint diferente do cluster ativo; atualizando."
        update_kubeconfig
      fi
      ;;
    false)
      ;;
    *)
      echo "UPDATE_KUBECONFIG deve ser auto, true ou false." >&2
      exit 1
      ;;
  esac
}

ensure_cluster_access() {
  if kubectl get namespace "${APP_NAMESPACE}" >/dev/null 2>&1; then
    return 0
  fi

  echo "Nao foi possivel acessar o cluster Kubernetes com o kubeconfig atual." >&2
  echo "Tente novamente com UPDATE_KUBECONFIG=true EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME} AWS_REGION=${AWS_REGION}." >&2
  exit 1
}

service_exists() {
  local namespace="$1"
  local service_name="$2"
  kubectl get svc "${service_name}" --namespace "${namespace}" >/dev/null 2>&1
}

local_port_open() {
  local port="$1"
  bash -c ":</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
}

port_forward_ports_open() {
  local ports="$1"
  local mapping local_port

  for mapping in ${ports}; do
    local_port="${mapping%%:*}"
    if ! local_port_open "${local_port}"; then
      return 1
    fi
  done

  return 0
}

pid_is_port_forward() {
  local pid="$1"
  local service_name="$2"
  local command_line

  command_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
  [[ "${command_line}" == *"kubectl"* && "${command_line}" == *"port-forward"* && "${command_line}" == *"svc/${service_name}"* ]]
}

wait_for_port_forward() {
  local pid="$1"
  local ports="$2"
  local log_file="$3"
  local attempt

  for attempt in {1..10}; do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      echo "Falha ao iniciar port-forward. Ultimas linhas de ${log_file}:" >&2
      tail -40 "${log_file}" >&2 || true
      return 1
    fi

    if port_forward_ports_open "${ports}"; then
      return 0
    fi

    sleep 1
  done

  echo "Port-forward iniciou, mas as portas locais nao ficaram acessiveis: ${ports}. Veja ${log_file}" >&2
  tail -40 "${log_file}" >&2 || true
  return 1
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
    if kill -0 "${existing_pid}" >/dev/null 2>&1 && pid_is_port_forward "${existing_pid}" "${service_name}" && port_forward_ports_open "${ports}"; then
      log "Port-forward ja ativo para ${namespace}/${service_name} (pid ${existing_pid})"
      PORT_FORWARD_SUMMARY+="${summary_line}"$'\n'
      return 0
    fi
    rm -f "${pid_file}"
  fi

  log "Iniciando port-forward para ${namespace}/${service_name} em ${ports}"
  : > "${log_file}"
  if command -v setsid >/dev/null 2>&1; then
    setsid kubectl --namespace "${namespace}" port-forward "svc/${service_name}" ${ports} >"${log_file}" 2>&1 &
  else
    nohup kubectl --namespace "${namespace}" port-forward "svc/${service_name}" ${ports} >"${log_file}" 2>&1 &
  fi
  local pf_pid=$!
  echo "${pf_pid}" > "${pid_file}"

  if ! wait_for_port_forward "${pf_pid}" "${ports}" "${log_file}"; then
    rm -f "${pid_file}"
    exit 1
  fi

  PORT_FORWARD_SUMMARY+="${summary_line}"$'\n'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_cmd kubectl

ensure_kubeconfig
ensure_cluster_access

log "Configuracao efetiva"
cat <<EOF
UPDATE_KUBECONFIG=${UPDATE_KUBECONFIG}
AWS_REGION=${AWS_REGION}
EKS_CLUSTER_NAME=${EKS_CLUSTER_NAME}
APP_NAMESPACE=${APP_NAMESPACE}
FORWARD_APP=${FORWARD_APP}
FORWARD_MAILHOG=${FORWARD_MAILHOG}
EOF

if [[ "${FORWARD_APP}" == "true" ]]; then
  start_port_forward "${APP_NAMESPACE}" "${OFICINA_APP_NAME}" "8080:8080" "${OFICINA_APP_NAME}" "Aplicacao: http://localhost:8080"
fi

if [[ "${FORWARD_MAILHOG}" == "true" ]]; then
  start_port_forward "default" "mailhog" "8025:8025 1025:1025" "mailhog" "MailHog UI: http://localhost:8025 | SMTP: localhost:1025"
fi

log "Encaminhamentos ativos"
cat <<EOF
${PORT_FORWARD_SUMMARY}Logs e PIDs: ${REPO_ROOT}/.tmp/port-forward
EOF
