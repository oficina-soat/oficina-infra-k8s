#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TERRAFORM_DIR="${TERRAFORM_DIR:-${REPO_ROOT}/terraform/environments/lab}"
AWS_REGION="${AWS_REGION:-}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
IMAGE_REF="${IMAGE_REF:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
TF_STATE_KEY="${TF_STATE_KEY:-oficina/lab/terraform.tfstate}"
TF_STATE_REGION="${TF_STATE_REGION:-${AWS_REGION}}"
TF_STATE_DYNAMODB_TABLE="${TF_STATE_DYNAMODB_TABLE:-}"
K8S_DATABASE_ENV_FILE="${K8S_DATABASE_ENV_FILE:-}"
DEPLOY_APP="${DEPLOY_APP:-false}"
DEPLOY_KEYCLOAK="${DEPLOY_KEYCLOAK:-false}"
REGENERATE_JWT="${REGENERATE_JWT:-true}"
db_env_file=""
ecr_repository_url_file=""

cleanup() {
  if [[ -n "${db_env_file}" && -f "${db_env_file}" ]]; then
    rm -f "${db_env_file}"
  fi

  if [[ -n "${ecr_repository_url_file}" && -f "${ecr_repository_url_file}" ]]; then
    rm -f "${ecr_repository_url_file}"
  fi
}

trap cleanup EXIT

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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

unset_if_empty() {
  local name="$1"

  if [[ -v "${name}" && -z "${!name}" ]]; then
    unset "${name}"
  fi
}

normalize_optional_envs() {
  unset_if_empty "DEPLOY_APP"
  unset_if_empty "IMAGE_REF"
  unset_if_empty "K8S_DATABASE_ENV_FILE"
}

resolve_image_ref() {
  if [[ -n "${IMAGE_REF:-}" ]]; then
    return
  fi

  require_non_empty "${IMAGE_TAG}" "IMAGE_TAG"

  local repository_url=""
  require_non_empty "${ecr_repository_url_file}" "ecr_repository_url_file"

  repository_url="$(<"${ecr_repository_url_file}")"

  if [[ -z "${repository_url}" ]]; then
    echo "Nao foi possivel obter ecr_repository_url do Terraform para montar IMAGE_REF." >&2
    exit 1
  fi

  IMAGE_REF="${repository_url}:${IMAGE_TAG}"
  export IMAGE_REF
  log "IMAGE_REF resolvido automaticamente para ${IMAGE_REF}."
}

normalize_optional_envs

require_cmd aws
require_cmd kubectl
require_cmd terraform
require_non_empty "${AWS_REGION}" "AWS_REGION"
require_non_empty "${EKS_CLUSTER_NAME}" "EKS_CLUSTER_NAME"
require_non_empty "${TF_VAR_kubernetes_version:-}" "TF_VAR_kubernetes_version"

if [[ "${DEPLOY_APP}" == "true" && -z "${IMAGE_REF:-}" ]]; then
  ecr_repository_url_file="$(mktemp)"
fi

TERRAFORM_ECR_REPOSITORY_URL_FILE="${ecr_repository_url_file:-}" \
TERRAFORM_ACTION=apply \
bash "${REPO_ROOT}/scripts/ci-terraform.sh"

if [[ "${DEPLOY_APP}" == "true" ]]; then
  resolve_image_ref
fi

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}"

if [[ "${DEPLOY_APP}" == "true" && -n "${K8S_DATABASE_ENV_FILE:-}" ]]; then
  db_env_file="$(mktemp)"
  printf '%s' "${K8S_DATABASE_ENV_FILE:-}" > "${db_env_file}"

  kubectl create secret generic oficina-database-env \
    --namespace default \
    --from-env-file="${db_env_file}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

IMAGE_REF="${IMAGE_REF:-}" \
AWS_REGION="${AWS_REGION}" \
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME}" \
UPDATE_KUBECONFIG=false \
DEPLOY_APP="${DEPLOY_APP}" \
DEPLOY_KEYCLOAK="${DEPLOY_KEYCLOAK}" \
REGENERATE_JWT="${REGENERATE_JWT}" \
bash "${REPO_ROOT}/scripts/deploy-manual.sh"
