#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TERRAFORM_DIR="${TERRAFORM_DIR:-${REPO_ROOT}/terraform/environments/lab}"
AWS_REGION="${AWS_REGION:-}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
IMAGE_REF="${IMAGE_REF:-}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
TF_STATE_KEY="${TF_STATE_KEY:-oficina/lab/terraform.tfstate}"
TF_STATE_REGION="${TF_STATE_REGION:-${AWS_REGION}}"
TF_STATE_DYNAMODB_TABLE="${TF_STATE_DYNAMODB_TABLE:-}"
K8S_DATABASE_ENV_FILE="${K8S_DATABASE_ENV_FILE:-}"
DEPLOY_KEYCLOAK="${DEPLOY_KEYCLOAK:-false}"
REGENERATE_JWT="${REGENERATE_JWT:-true}"
BACKEND_S3_TEMPLATE="${TERRAFORM_DIR}/backend.s3.tf.example"
backend_override_file=""
db_env_file=""

cleanup() {
  if [[ -n "${db_env_file}" && -f "${db_env_file}" ]]; then
    rm -f "${db_env_file}"
  fi

  if [[ -n "${backend_override_file}" && -f "${backend_override_file}" ]]; then
    rm -f "${backend_override_file}"
  fi
}

trap cleanup EXIT

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_non_empty() {
  local value="$1"
  local name="$2"

  if [[ -z "${value}" ]]; then
    echo "Variavel obrigatoria ausente: ${name}" >&2
    exit 1
  fi
}

create_backend_override() {
  if [[ ! -f "${BACKEND_S3_TEMPLATE}" ]]; then
    echo "Template de backend S3 nao encontrado: ${BACKEND_S3_TEMPLATE}" >&2
    exit 1
  fi

  backend_override_file="$(mktemp "${TERRAFORM_DIR}/backend-ci-XXXXXX.tf")"
  cp "${BACKEND_S3_TEMPLATE}" "${backend_override_file}"
}

terraform_init_remote() {
  local backend_args=(
    "-backend-config=bucket=${TF_STATE_BUCKET}"
    "-backend-config=key=${TF_STATE_KEY}"
    "-backend-config=region=${TF_STATE_REGION}"
    "-backend-config=encrypt=true"
  )

  if [[ -n "${TF_STATE_DYNAMODB_TABLE}" ]]; then
    backend_args+=("-backend-config=dynamodb_table=${TF_STATE_DYNAMODB_TABLE}")
  fi

  terraform -chdir="${TERRAFORM_DIR}" init -input=false -reconfigure "${backend_args[@]}"
}

terraform_migrate_state_remote() {
  local backend_args=(
    "-backend-config=bucket=${TF_STATE_BUCKET}"
    "-backend-config=key=${TF_STATE_KEY}"
    "-backend-config=region=${TF_STATE_REGION}"
    "-backend-config=encrypt=true"
  )

  if [[ -n "${TF_STATE_DYNAMODB_TABLE}" ]]; then
    backend_args+=("-backend-config=dynamodb_table=${TF_STATE_DYNAMODB_TABLE}")
  fi

  terraform -chdir="${TERRAFORM_DIR}" init -input=false -migrate-state -reconfigure "${backend_args[@]}"
}

terraform_state_manages_shared_bucket() {
  terraform -chdir="${TERRAFORM_DIR}" state list 2>/dev/null | grep -q '^module\.terraform_shared_data_bucket\[0\]\.aws_s3_bucket\.this$'
}

aws_bucket_exists() {
  aws s3api head-bucket --bucket "${TF_STATE_BUCKET}" >/dev/null 2>&1
}

require_non_empty "${AWS_REGION}" "AWS_REGION"
require_non_empty "${EKS_CLUSTER_NAME}" "EKS_CLUSTER_NAME"
require_non_empty "${IMAGE_REF}" "IMAGE_REF"
require_non_empty "${TF_VAR_kubernetes_version:-}" "TF_VAR_kubernetes_version"

if [[ -n "${TF_STATE_BUCKET}" ]]; then
  create_backend_override
  export TF_VAR_terraform_shared_data_bucket_name="${TF_STATE_BUCKET}"

  if aws_bucket_exists; then
    log "Bucket ${TF_STATE_BUCKET} ja existe; configurando backend remoto."
    terraform_init_remote

    if terraform_state_manages_shared_bucket; then
      log "Bucket ${TF_STATE_BUCKET} ja esta no state deste ambiente; mantendo gerenciamento pelo Terraform."
      export TF_VAR_create_terraform_shared_data_bucket="true"
    else
      log "Bucket ${TF_STATE_BUCKET} existe fora do state deste ambiente; reutilizando sem tentar recriar."
      export TF_VAR_create_terraform_shared_data_bucket="false"
    fi
  else
    log "Bucket ${TF_STATE_BUCKET} ainda nao existe; executando bootstrap local para criar o bucket."
    export TF_VAR_create_terraform_shared_data_bucket="true"
    terraform -chdir="${TERRAFORM_DIR}" init -input=false -reconfigure
    terraform -chdir="${TERRAFORM_DIR}" apply -input=false -auto-approve

    log "Migrando o state local para o backend S3 em ${TF_STATE_BUCKET}."
    terraform_migrate_state_remote
  fi
else
  echo "TF_STATE_BUCKET ausente; usando backend local em ${TERRAFORM_DIR}/terraform.tfstate."
  terraform -chdir="${TERRAFORM_DIR}" init -input=false -reconfigure
fi

terraform -chdir="${TERRAFORM_DIR}" apply -input=false -auto-approve

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}"

if [[ -n "${K8S_DATABASE_ENV_FILE}" ]]; then
  db_env_file="$(mktemp)"
  printf '%s' "${K8S_DATABASE_ENV_FILE}" > "${db_env_file}"

  kubectl create secret generic oficina-database-env \
    --namespace default \
    --from-env-file="${db_env_file}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

IMAGE_REF="${IMAGE_REF}" \
AWS_REGION="${AWS_REGION}" \
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME}" \
UPDATE_KUBECONFIG=false \
DEPLOY_KEYCLOAK="${DEPLOY_KEYCLOAK}" \
REGENERATE_JWT="${REGENERATE_JWT}" \
bash "${REPO_ROOT}/scripts/deploy-manual.sh"
