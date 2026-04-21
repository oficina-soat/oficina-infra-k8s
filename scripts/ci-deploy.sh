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
K8S_DATABASE_SECRET_ID="${K8S_DATABASE_SECRET_ID:-oficina/lab/database/app}"
K8S_JWT_SECRET_ID="${K8S_JWT_SECRET_ID:-oficina/lab/jwt}"
FETCH_RUNTIME_SECRETS_FROM_AWS="${FETCH_RUNTIME_SECRETS_FROM_AWS:-true}"
DEPLOY_APP="${DEPLOY_APP:-auto}"
DEPLOY_KEYCLOAK="${DEPLOY_KEYCLOAK:-false}"
REGENERATE_JWT="${REGENERATE_JWT:-true}"
db_env_file=""
ecr_repository_url_file=""
jwt_tmp_dir=""

cleanup() {
  if [[ -n "${db_env_file}" && -f "${db_env_file}" ]]; then
    rm -f "${db_env_file}"
  fi

  if [[ -n "${ecr_repository_url_file}" && -f "${ecr_repository_url_file}" ]]; then
    rm -f "${ecr_repository_url_file}"
  fi

  if [[ -n "${jwt_tmp_dir}" && -d "${jwt_tmp_dir}" ]]; then
    rm -rf "${jwt_tmp_dir}"
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
  unset_if_empty "IMAGE_TAG"
  unset_if_empty "K8S_DATABASE_ENV_FILE"
  unset_if_empty "K8S_DATABASE_SECRET_ID"
  unset_if_empty "K8S_JWT_SECRET_ID"
}

is_truthy() {
  case "${1:-}" in
    true | TRUE | True | 1 | yes | YES | Yes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_deploy_app_mode() {
  case "${DEPLOY_APP}" in
    auto | true | false)
      ;;
    *)
      echo "DEPLOY_APP invalido: ${DEPLOY_APP}. Use auto, true ou false." >&2
      exit 1
      ;;
  esac
}

should_evaluate_app_deploy() {
  [[ "${DEPLOY_APP}" != "false" ]]
}

secretmanager_secret_exists() {
  local secret_id="$1"

  aws secretsmanager describe-secret \
    --region "${AWS_REGION}" \
    --secret-id "${secret_id}" >/dev/null 2>&1
}

fetch_secret_string_to_file() {
  local secret_id="$1"
  local output_file="$2"

  require_cmd jq

  if ! aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "${secret_id}" \
    --output json | jq -r '.SecretString // empty' > "${output_file}"; then
    echo "Nao foi possivel ler o SecretString de ${secret_id}." >&2
    return 1
  fi

  if [[ ! -s "${output_file}" ]]; then
    echo "Secret ${secret_id} nao possui SecretString legivel." >&2
    return 1
  fi
}

write_secret_string_as_env_file() {
  local input_file="$1"
  local output_file="$2"

  if jq -e 'type == "object"' "${input_file}" >/dev/null 2>&1; then
    jq -r 'to_entries[] | select(.value != null) | "\(.key)=\(.value | tostring)"' "${input_file}" > "${output_file}"
  else
    cp "${input_file}" "${output_file}"
  fi
}

ensure_env_line() {
  local file="$1"
  local key="$2"
  local value="$3"

  if ! grep -q "^${key}=" "${file}"; then
    printf '\n%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

ensure_database_ssl_envs() {
  local file="$1"

  ensure_env_line "${file}" "QUARKUS_DATASOURCE_REACTIVE_POSTGRESQL_SSL_MODE" "require"
  ensure_env_line "${file}" "QUARKUS_DATASOURCE_REACTIVE_TRUST_ALL" "true"
}

apply_database_secret_from_file() {
  local env_file="$1"

  ensure_database_ssl_envs "${env_file}"

  kubectl create secret generic oficina-database-env \
    --namespace default \
    --from-env-file="${env_file}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

prepare_database_secret() {
  local secret_string_file=""

  if [[ -n "${K8S_DATABASE_ENV_FILE:-}" ]]; then
    db_env_file="$(mktemp)"
    printf '%s' "${K8S_DATABASE_ENV_FILE:-}" > "${db_env_file}"
    log "Criando/atualizando secret Kubernetes oficina-database-env a partir de K8S_DATABASE_ENV_FILE."
    apply_database_secret_from_file "${db_env_file}"
    return
  fi

  if ! is_truthy "${FETCH_RUNTIME_SECRETS_FROM_AWS}"; then
    log "Busca de runtime secrets na AWS desabilitada; nao criarei oficina-database-env automaticamente."
    return
  fi

  if [[ -z "${K8S_DATABASE_SECRET_ID:-}" ]]; then
    log "K8S_DATABASE_SECRET_ID ausente; nao criarei oficina-database-env automaticamente."
    return
  fi

  if ! secretmanager_secret_exists "${K8S_DATABASE_SECRET_ID}"; then
    log "Secret Manager ${K8S_DATABASE_SECRET_ID} nao encontrado; o deploy seguira apenas se a aplicacao nao exigir banco no startup."
    return
  fi

  secret_string_file="$(mktemp)"
  db_env_file="$(mktemp)"

  if ! fetch_secret_string_to_file "${K8S_DATABASE_SECRET_ID}" "${secret_string_file}"; then
    rm -f "${secret_string_file}"
    exit 1
  fi

  write_secret_string_as_env_file "${secret_string_file}" "${db_env_file}"
  rm -f "${secret_string_file}"

  log "Criando/atualizando secret Kubernetes oficina-database-env a partir do Secrets Manager ${K8S_DATABASE_SECRET_ID}."
  apply_database_secret_from_file "${db_env_file}"
}

prepare_jwt_secret_from_secrets_manager() {
  local secret_string_file=""
  local private_key=""
  local public_key=""

  if ! is_truthy "${FETCH_RUNTIME_SECRETS_FROM_AWS}"; then
    return
  fi

  if [[ -z "${K8S_JWT_SECRET_ID:-}" ]]; then
    return
  fi

  if ! secretmanager_secret_exists "${K8S_JWT_SECRET_ID}"; then
    log "Secret Manager ${K8S_JWT_SECRET_ID} nao encontrado; o deploy gerara um novo par JWT local para o cluster."
    return
  fi

  secret_string_file="$(mktemp)"

  if ! fetch_secret_string_to_file "${K8S_JWT_SECRET_ID}" "${secret_string_file}"; then
    rm -f "${secret_string_file}"
    exit 1
  fi

  if ! jq -e 'type == "object"' "${secret_string_file}" >/dev/null 2>&1; then
    rm -f "${secret_string_file}"
    echo "Secret ${K8S_JWT_SECRET_ID} deve ser JSON com chaves privateKey/publicKey ou privateKey.pem/publicKey.pem." >&2
    exit 1
  fi

  private_key="$(
    jq -r '.["privateKey.pem"] // .privateKeyPem // .privateKey // .private_key // .private_key_pem // .PRIVATE_KEY // .JWT_PRIVATE_KEY // empty' "${secret_string_file}"
  )"
  public_key="$(
    jq -r '.["publicKey.pem"] // .publicKeyPem // .publicKey // .public_key // .public_key_pem // .PUBLIC_KEY // .JWT_PUBLIC_KEY // empty' "${secret_string_file}"
  )"
  rm -f "${secret_string_file}"

  if [[ -z "${private_key}" || -z "${public_key}" ]]; then
    echo "Secret ${K8S_JWT_SECRET_ID} nao contem privateKey/publicKey legiveis." >&2
    exit 1
  fi

  jwt_tmp_dir="$(mktemp -d)"
  printf '%s\n' "${private_key}" > "${jwt_tmp_dir}/privateKey.pem"
  printf '%s\n' "${public_key}" > "${jwt_tmp_dir}/publicKey.pem"

  export JWT_DIR="${jwt_tmp_dir}"
  export REGENERATE_JWT="false"
  log "Usando chaves JWT do Secrets Manager ${K8S_JWT_SECRET_ID}."
}

ecr_repository_name_from_url() {
  local repository_url="$1"

  printf '%s\n' "${repository_url#*/}"
}

ecr_image_tag_exists() {
  local repository_name="$1"
  local image_tag="$2"

  aws ecr describe-images \
    --region "${AWS_REGION}" \
    --repository-name "${repository_name}" \
    --image-ids imageTag="${image_tag}" >/dev/null 2>&1
}

latest_ecr_image_tag() {
  local repository_name="$1"

  require_cmd jq

  if ! aws ecr describe-images \
    --region "${AWS_REGION}" \
    --repository-name "${repository_name}" \
    --output json \
    | jq -r '[.imageDetails[] | select(.imageTags and (.imageTags | length > 0))] | sort_by(.imagePushedAt) | last | .imageTags[0] // empty'; then
    return 1
  fi
}

resolve_image_ref() {
  if [[ -n "${IMAGE_REF:-}" ]]; then
    log "Usando IMAGE_REF informado: ${IMAGE_REF}."
    return
  fi

  local repository_url=""
  local repository_name=""
  local resolved_tag=""
  require_non_empty "${ecr_repository_url_file}" "ecr_repository_url_file"

  repository_url="$(<"${ecr_repository_url_file}")"

  if [[ -z "${repository_url}" ]]; then
    echo "Nao foi possivel obter ecr_repository_url do Terraform para montar IMAGE_REF." >&2
    exit 1
  fi

  repository_name="$(ecr_repository_name_from_url "${repository_url}")"

  if [[ -n "${IMAGE_TAG:-}" ]]; then
    if ! ecr_image_tag_exists "${repository_name}" "${IMAGE_TAG}"; then
      if [[ "${DEPLOY_APP}" == "auto" ]]; then
        log "Imagem ${repository_url}:${IMAGE_TAG} nao encontrada no ECR; pulando deploy da aplicacao."
        return 1
      fi

      echo "Imagem ${repository_url}:${IMAGE_TAG} nao encontrada no ECR." >&2
      exit 1
    fi

    resolved_tag="${IMAGE_TAG}"
  else
    resolved_tag="$(latest_ecr_image_tag "${repository_name}")"

    if [[ -z "${resolved_tag}" || "${resolved_tag}" == "null" || "${resolved_tag}" == "None" ]]; then
      if [[ "${DEPLOY_APP}" == "auto" ]]; then
        log "Nenhuma imagem tagueada encontrada no ECR ${repository_name}; pulando deploy da aplicacao."
        return 1
      fi

      echo "Nenhuma imagem tagueada encontrada no ECR ${repository_name}." >&2
      exit 1
    fi
  fi

  IMAGE_REF="${repository_url}:${resolved_tag}"
  IMAGE_TAG="${resolved_tag}"
  export IMAGE_REF
  export IMAGE_TAG
  log "IMAGE_REF resolvido automaticamente para ${IMAGE_REF}."
}

normalize_optional_envs
DEPLOY_APP="${DEPLOY_APP:-auto}"
K8S_DATABASE_SECRET_ID="${K8S_DATABASE_SECRET_ID:-oficina/lab/database/app}"
K8S_JWT_SECRET_ID="${K8S_JWT_SECRET_ID:-oficina/lab/jwt}"
FETCH_RUNTIME_SECRETS_FROM_AWS="${FETCH_RUNTIME_SECRETS_FROM_AWS:-true}"
validate_deploy_app_mode

require_cmd aws
require_cmd kubectl
require_cmd terraform
require_non_empty "${AWS_REGION}" "AWS_REGION"
require_non_empty "${EKS_CLUSTER_NAME}" "EKS_CLUSTER_NAME"
require_non_empty "${TF_VAR_kubernetes_version:-}" "TF_VAR_kubernetes_version"

if should_evaluate_app_deploy && [[ -z "${IMAGE_REF:-}" ]]; then
  ecr_repository_url_file="$(mktemp)"
fi

TERRAFORM_ECR_REPOSITORY_URL_FILE="${ecr_repository_url_file:-}" \
TERRAFORM_ACTION=apply \
bash "${REPO_ROOT}/scripts/ci-terraform.sh"

if should_evaluate_app_deploy; then
  if resolve_image_ref; then
    DEPLOY_APP="true"
    export DEPLOY_APP
  else
    DEPLOY_APP="false"
    export DEPLOY_APP
  fi
fi

aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}"

if [[ "${DEPLOY_APP}" == "true" ]]; then
  prepare_database_secret
  prepare_jwt_secret_from_secrets_manager
fi

IMAGE_REF="${IMAGE_REF:-}" \
AWS_REGION="${AWS_REGION}" \
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME}" \
UPDATE_KUBECONFIG=false \
DEPLOY_APP="${DEPLOY_APP}" \
DEPLOY_KEYCLOAK="${DEPLOY_KEYCLOAK}" \
REGENERATE_JWT="${REGENERATE_JWT}" \
bash "${REPO_ROOT}/scripts/deploy-manual.sh"
