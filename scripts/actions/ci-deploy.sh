#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"

TERRAFORM_DIR="${TERRAFORM_DIR:-${OFICINA_TERRAFORM_ENV_DIR}}"
AWS_REGION="${AWS_REGION:-}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
IMAGE_REF="${IMAGE_REF:-}"
IMAGE_TAG="${IMAGE_TAG:-}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
TF_STATE_KEY="${TF_STATE_KEY:-${OFICINA_TF_STATE_KEY}}"
TF_STATE_REGION="${TF_STATE_REGION:-${AWS_REGION}}"
TF_STATE_DYNAMODB_TABLE="${TF_STATE_DYNAMODB_TABLE:-}"
K8S_DATABASE_ENV_FILE="${K8S_DATABASE_ENV_FILE:-}"
K8S_DATABASE_SECRET_ID="${K8S_DATABASE_SECRET_ID:-${OFICINA_DB_APP_SECRET_ID}}"
K8S_JWT_SECRET_ID="${K8S_JWT_SECRET_ID:-${OFICINA_JWT_SECRET_ID}}"
K8S_JWT_SECRET_PRIVATE_KEY_FIELD="${K8S_JWT_SECRET_PRIVATE_KEY_FIELD:-privateKeyPem}"
K8S_JWT_SECRET_PUBLIC_KEY_FIELD="${K8S_JWT_SECRET_PUBLIC_KEY_FIELD:-publicKeyPem}"
K8S_JWT_SECRET_KMS_KEY_ID="${K8S_JWT_SECRET_KMS_KEY_ID:-}"
FETCH_RUNTIME_SECRETS_FROM_AWS="${FETCH_RUNTIME_SECRETS_FROM_AWS:-true}"
DEPLOY_APP="${DEPLOY_APP:-auto}"
REGENERATE_JWT="${REGENERATE_JWT:-false}"
ROTATE_JWT_SECRET="${ROTATE_JWT_SECRET:-false}"
OFICINA_AUTH_ISSUER="${OFICINA_AUTH_ISSUER:-}"
OFICINA_AUTH_JWKS_URI="${OFICINA_AUTH_JWKS_URI:-}"
OFICINA_AUTH_FORCE_LEGACY="${OFICINA_AUTH_FORCE_LEGACY:-false}"
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

normalize_optional_envs() {
  unset_if_empty "DEPLOY_APP"
  unset_if_empty "IMAGE_REF"
  unset_if_empty "IMAGE_TAG"
  unset_if_empty "K8S_DATABASE_ENV_FILE"
  unset_if_empty "K8S_DATABASE_SECRET_ID"
  unset_if_empty "K8S_JWT_SECRET_ID"
  unset_if_empty "K8S_JWT_SECRET_PRIVATE_KEY_FIELD"
  unset_if_empty "K8S_JWT_SECRET_PUBLIC_KEY_FIELD"
  unset_if_empty "K8S_JWT_SECRET_KMS_KEY_ID"
  unset_if_empty "ROTATE_JWT_SECRET"
  unset_if_empty "OFICINA_AUTH_ISSUER"
  unset_if_empty "OFICINA_AUTH_JWKS_URI"
  unset_if_empty "OFICINA_AUTH_FORCE_LEGACY"
}

generate_jwt_keypair() {
  local jwt_dir="$1"

  require_cmd openssl
  mkdir -p "${jwt_dir}"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${jwt_dir}/privateKey.pem"
  openssl pkey -in "${jwt_dir}/privateKey.pem" -pubout -out "${jwt_dir}/publicKey.pem"
  chmod 600 "${jwt_dir}/privateKey.pem"
  chmod 644 "${jwt_dir}/publicKey.pem"
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

create_or_rotate_jwt_secret_in_secrets_manager() {
  local tmp_dir=""
  local secret_json_file=""

  require_cmd jq
  require_non_empty "${K8S_JWT_SECRET_ID}" "K8S_JWT_SECRET_ID"
  require_non_empty "${K8S_JWT_SECRET_PRIVATE_KEY_FIELD}" "K8S_JWT_SECRET_PRIVATE_KEY_FIELD"
  require_non_empty "${K8S_JWT_SECRET_PUBLIC_KEY_FIELD}" "K8S_JWT_SECRET_PUBLIC_KEY_FIELD"

  tmp_dir="$(mktemp -d)"
  secret_json_file="${tmp_dir}/jwt-secret.json"

  generate_jwt_keypair "${tmp_dir}"

  jq -n \
    --rawfile privateKeyPem "${tmp_dir}/privateKey.pem" \
    --rawfile publicKeyPem "${tmp_dir}/publicKey.pem" \
    --arg privateKeyField "${K8S_JWT_SECRET_PRIVATE_KEY_FIELD}" \
    --arg publicKeyField "${K8S_JWT_SECRET_PUBLIC_KEY_FIELD}" \
    '{($privateKeyField): $privateKeyPem, ($publicKeyField): $publicKeyPem}' \
    > "${secret_json_file}"

  if secretmanager_secret_exists "${K8S_JWT_SECRET_ID}"; then
    log "Rotacionando secret JWT no Secrets Manager ${K8S_JWT_SECRET_ID}."
    aws secretsmanager put-secret-value \
      --region "${AWS_REGION}" \
      --secret-id "${K8S_JWT_SECRET_ID}" \
      --secret-string "file://${secret_json_file}" >/dev/null
  else
    log "Criando secret JWT compartilhado no Secrets Manager ${K8S_JWT_SECRET_ID}."
    if [[ -n "${K8S_JWT_SECRET_KMS_KEY_ID}" ]]; then
      aws secretsmanager create-secret \
        --region "${AWS_REGION}" \
        --name "${K8S_JWT_SECRET_ID}" \
        --kms-key-id "${K8S_JWT_SECRET_KMS_KEY_ID}" \
        --description "Chaves JWT compartilhadas da Oficina no ambiente ${OFICINA_ENVIRONMENT_NAME}" \
        --secret-string "file://${secret_json_file}" >/dev/null
    else
      aws secretsmanager create-secret \
        --region "${AWS_REGION}" \
        --name "${K8S_JWT_SECRET_ID}" \
        --description "Chaves JWT compartilhadas da Oficina no ambiente ${OFICINA_ENVIRONMENT_NAME}" \
        --secret-string "file://${secret_json_file}" >/dev/null
    fi
  fi

  rm -rf "${tmp_dir}"
}

ensure_jwt_secret_in_secrets_manager() {
  if [[ "${ROTATE_JWT_SECRET}" == "true" ]]; then
    create_or_rotate_jwt_secret_in_secrets_manager
    return
  fi

  if secretmanager_secret_exists "${K8S_JWT_SECRET_ID}"; then
    log "Usando secret JWT existente no Secrets Manager ${K8S_JWT_SECRET_ID}."
    return
  fi

  create_or_rotate_jwt_secret_in_secrets_manager
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

env_file_value() {
  local file="$1"
  local key="$2"
  local line=""
  local value=""

  line="$(awk -v key="${key}" 'index($0, key "=") == 1 { line = $0 } END { if (line != "") print line }' "${file}")"
  if [[ -z "${line}" ]]; then
    return 1
  fi

  value="${line#*=}"
  if [[ -z "${value}" ]]; then
    return 1
  fi

  printf '%s' "${value}"
}

first_env_file_value() {
  local file="$1"
  shift

  local key=""
  local value=""

  for key in "$@"; do
    if value="$(env_file_value "${file}" "${key}")"; then
      printf '%s' "${value}"
      return 0
    fi
  done

  return 1
}

set_env_line() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file=""

  tmp_file="$(mktemp)"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { written = 0 }
    index($0, key "=") == 1 {
      if (!written) {
        print key "=" value
        written = 1
      }
      next
    }
    { print }
    END {
      if (!written) {
        print key "=" value
      }
    }
  ' "${file}" > "${tmp_file}"
  mv "${tmp_file}" "${file}"
}

normalize_postgres_url() {
  local url="$1"

  url="${url#jdbc:}"

  if [[ "${url}" == postgres://* ]]; then
    url="postgresql://${url#postgres://}"
  fi

  printf '%s' "${url}"
}

ensure_database_quarkus_envs() {
  local file="$1"
  local value=""
  local host=""
  local port=""
  local database=""

  if value="$(first_env_file_value \
    "${file}" \
    "QUARKUS_DATASOURCE_REACTIVE_URL" \
    "quarkus.datasource.reactive.url" \
    "QUARKUS_DATASOURCE_JDBC_URL" \
    "quarkus.datasource.jdbc.url" \
    "DATABASE_URL" \
    "DATABASE_URI" \
    "DB_URL" \
    "DB_URI" \
    "JDBC_DATABASE_URL" \
    "JDBC_URL" \
    "POSTGRESQL_URL" \
    "POSTGRESQL_URI" \
    "POSTGRES_URL" \
    "POSTGRES_URI" \
    "SPRING_DATASOURCE_URL" \
    "url" \
    "jdbcUrl" \
    "jdbc_url")"; then
    set_env_line "${file}" "QUARKUS_DATASOURCE_REACTIVE_URL" "$(normalize_postgres_url "${value}")"
  fi

  if value="$(first_env_file_value \
    "${file}" \
    "QUARKUS_DATASOURCE_USERNAME" \
    "quarkus.datasource.username" \
    "DATABASE_USERNAME" \
    "DATABASE_USER" \
    "DB_USERNAME" \
    "DB_USER" \
    "DB_USER_NAME" \
    "POSTGRES_USERNAME" \
    "POSTGRES_USER" \
    "PGUSER" \
    "db_username" \
    "dbUser" \
    "username" \
    "user")"; then
    set_env_line "${file}" "QUARKUS_DATASOURCE_USERNAME" "${value}"
  fi

  if value="$(first_env_file_value \
    "${file}" \
    "QUARKUS_DATASOURCE_PASSWORD" \
    "quarkus.datasource.password" \
    "DATABASE_PASSWORD" \
    "DB_PASSWORD" \
    "POSTGRES_PASSWORD" \
    "PGPASSWORD" \
    "db_password" \
    "dbPassword" \
    "password")"; then
    set_env_line "${file}" "QUARKUS_DATASOURCE_PASSWORD" "${value}"
  fi

  if ! env_file_value "${file}" "QUARKUS_DATASOURCE_REACTIVE_URL" >/dev/null; then
    if host="$(first_env_file_value "${file}" "DATABASE_HOST" "DB_HOST" "POSTGRES_HOST" "PGHOST" "host" "hostname" "endpoint")" \
      && database="$(first_env_file_value "${file}" "DATABASE_NAME" "DB_NAME" "POSTGRES_DB" "PGDATABASE" "dbname" "database" "databaseName" "db_name" "database_name")"; then
      port="$(first_env_file_value "${file}" "DATABASE_PORT" "DB_PORT" "POSTGRES_PORT" "PGPORT" "port" || true)"
      port="${port:-5432}"
      set_env_line "${file}" "QUARKUS_DATASOURCE_REACTIVE_URL" "postgresql://${host}:${port}/${database}"
    fi
  fi

  if ! env_file_value "${file}" "QUARKUS_DATASOURCE_REACTIVE_URL" >/dev/null; then
    echo "Secret de banco nao contem QUARKUS_DATASOURCE_REACTIVE_URL nem dados suficientes para monta-la." >&2
    echo "Informe QUARKUS_DATASOURCE_REACTIVE_URL ou os campos host/port/dbname, username e password em ${K8S_DATABASE_SECRET_ID} ou K8S_DATABASE_ENV_FILE." >&2
    exit 1
  fi
}

ensure_database_ssl_envs() {
  local file="$1"

  ensure_env_line "${file}" "QUARKUS_DATASOURCE_REACTIVE_POSTGRESQL_SSL_MODE" "require"
  ensure_env_line "${file}" "QUARKUS_DATASOURCE_REACTIVE_TRUST_ALL" "true"
}

apply_database_secret_from_file() {
  local env_file="$1"

  ensure_database_quarkus_envs "${env_file}"
  ensure_database_ssl_envs "${env_file}"

  kubectl create secret generic "${OFICINA_DB_K8S_SECRET_NAME}" \
    --namespace default \
    --from-env-file="${env_file}" \
    --dry-run=client -o yaml | kubectl apply -f -
}

prepare_database_secret() {
  local secret_string_file=""

  if [[ -n "${K8S_DATABASE_ENV_FILE:-}" ]]; then
    db_env_file="$(mktemp)"
    printf '%s' "${K8S_DATABASE_ENV_FILE:-}" > "${db_env_file}"
    log "Criando/atualizando secret Kubernetes ${OFICINA_DB_K8S_SECRET_NAME} a partir de K8S_DATABASE_ENV_FILE."
    apply_database_secret_from_file "${db_env_file}"
    return
  fi

  if ! is_truthy "${FETCH_RUNTIME_SECRETS_FROM_AWS}"; then
    log "Busca de runtime secrets na AWS desabilitada; nao criarei ${OFICINA_DB_K8S_SECRET_NAME} automaticamente."
    return
  fi

  if [[ -z "${K8S_DATABASE_SECRET_ID:-}" ]]; then
    log "K8S_DATABASE_SECRET_ID ausente; nao criarei ${OFICINA_DB_K8S_SECRET_NAME} automaticamente."
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

  log "Criando/atualizando secret Kubernetes ${OFICINA_DB_K8S_SECRET_NAME} a partir do Secrets Manager ${K8S_DATABASE_SECRET_ID}."
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

  ensure_jwt_secret_in_secrets_manager

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
    jq -r --arg field "${K8S_JWT_SECRET_PRIVATE_KEY_FIELD}" '.[$field] // .["privateKey.pem"] // .privateKeyPem // .privateKey // .private_key // .private_key_pem // .PRIVATE_KEY // .JWT_PRIVATE_KEY // empty' "${secret_string_file}"
  )"
  public_key="$(
    jq -r --arg field "${K8S_JWT_SECRET_PUBLIC_KEY_FIELD}" '.[$field] // .["publicKey.pem"] // .publicKeyPem // .publicKey // .public_key // .public_key_pem // .PUBLIC_KEY // .JWT_PUBLIC_KEY // empty' "${secret_string_file}"
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

prepare_app_auth_config_from_terraform() {
  local api_gateway_endpoint=""
  local should_migrate_legacy="false"
  local legacy_auth_issuer="${OFICINA_AUTH_ISSUER:-}"
  local legacy_auth_jwks_uri="${OFICINA_AUTH_JWKS_URI:-}"

  if [[ "${OFICINA_AUTH_FORCE_LEGACY}" != "true" && "${OFICINA_AUTH_ISSUER:-}" == "oficina-api" ]] \
    && [[ -z "${OFICINA_AUTH_JWKS_URI:-}" || "${OFICINA_AUTH_JWKS_URI:-}" == "file:/jwt/publicKey.pem" ]]; then
    should_migrate_legacy="true"
    OFICINA_AUTH_ISSUER=""
    OFICINA_AUTH_JWKS_URI=""
  fi

  if [[ -z "${OFICINA_AUTH_ISSUER:-}" ]]; then
    if api_gateway_endpoint="$(terraform -chdir="${TERRAFORM_DIR}" output -raw api_gateway_endpoint 2>/dev/null)" && [[ -n "${api_gateway_endpoint}" && "${api_gateway_endpoint}" != "null" ]]; then
      OFICINA_AUTH_ISSUER="${api_gateway_endpoint%/}"
    fi
  fi

  if [[ -z "${OFICINA_AUTH_JWKS_URI:-}" && -n "${OFICINA_AUTH_ISSUER:-}" ]]; then
    OFICINA_AUTH_JWKS_URI="${OFICINA_AUTH_ISSUER%/}/.well-known/jwks.json"
  fi

  if [[ "${should_migrate_legacy}" == "true" && -n "${OFICINA_AUTH_ISSUER:-}" && -n "${OFICINA_AUTH_JWKS_URI:-}" ]]; then
    log "Migrando configuracao legada de JWT para o issuer publico ${OFICINA_AUTH_ISSUER}."
  elif [[ "${should_migrate_legacy}" == "true" ]]; then
    OFICINA_AUTH_ISSUER="${legacy_auth_issuer}"
    OFICINA_AUTH_JWKS_URI="${legacy_auth_jwks_uri}"
    log "API Gateway nao encontrado; mantendo configuracao legada de JWT."
  fi

  export OFICINA_AUTH_ISSUER
  export OFICINA_AUTH_JWKS_URI
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
K8S_DATABASE_SECRET_ID="${K8S_DATABASE_SECRET_ID:-${OFICINA_DB_APP_SECRET_ID}}"
K8S_JWT_SECRET_ID="${K8S_JWT_SECRET_ID:-${OFICINA_JWT_SECRET_ID}}"
K8S_JWT_SECRET_PRIVATE_KEY_FIELD="${K8S_JWT_SECRET_PRIVATE_KEY_FIELD:-privateKeyPem}"
K8S_JWT_SECRET_PUBLIC_KEY_FIELD="${K8S_JWT_SECRET_PUBLIC_KEY_FIELD:-publicKeyPem}"
K8S_JWT_SECRET_KMS_KEY_ID="${K8S_JWT_SECRET_KMS_KEY_ID:-}"
FETCH_RUNTIME_SECRETS_FROM_AWS="${FETCH_RUNTIME_SECRETS_FROM_AWS:-true}"
ROTATE_JWT_SECRET="${ROTATE_JWT_SECRET:-false}"
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
bash "${REPO_ROOT}/scripts/actions/ci-terraform.sh"

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
  prepare_app_auth_config_from_terraform
fi

IMAGE_REF="${IMAGE_REF:-}" \
AWS_REGION="${AWS_REGION}" \
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME}" \
UPDATE_KUBECONFIG=false \
DEPLOY_APP="${DEPLOY_APP}" \
REGENERATE_JWT="${REGENERATE_JWT}" \
OFICINA_AUTH_ISSUER="${OFICINA_AUTH_ISSUER:-}" \
OFICINA_AUTH_JWKS_URI="${OFICINA_AUTH_JWKS_URI:-}" \
OFICINA_AUTH_FORCE_LEGACY="${OFICINA_AUTH_FORCE_LEGACY:-false}" \
OBSERVABILITY_ENABLED="${OBSERVABILITY_ENABLED:-true}" \
OBSERVABILITY_APP_LOG_GROUP_NAME="${OBSERVABILITY_APP_LOG_GROUP_NAME:-${OFICINA_OBSERVABILITY_APP_LOG_GROUP_NAME}}" \
OBSERVABILITY_PROMETHEUS_LOG_GROUP_NAME="${OBSERVABILITY_PROMETHEUS_LOG_GROUP_NAME:-/aws/containerinsights/${EKS_CLUSTER_NAME}/prometheus}" \
OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS="${OBSERVABILITY_ENABLE_K8S_RESOURCE_METRICS:-true}" \
OBSERVABILITY_FLUENT_BIT_IMAGE="${OBSERVABILITY_FLUENT_BIT_IMAGE:-public.ecr.aws/aws-observability/aws-for-fluent-bit:2.34.3.20260423}" \
OBSERVABILITY_CWAGENT_IMAGE="${OBSERVABILITY_CWAGENT_IMAGE:-public.ecr.aws/cloudwatch-agent/cloudwatch-agent:1.300066.1}" \
bash "${REPO_ROOT}/scripts/manual/deploy-manual.sh"
