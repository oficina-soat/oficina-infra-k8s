#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TERRAFORM_DIR="${TERRAFORM_DIR:-${REPO_ROOT}/terraform/environments/lab}"
AWS_REGION="${AWS_REGION:-}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
TF_STATE_KEY="${TF_STATE_KEY:-oficina/lab/terraform.tfstate}"
TF_STATE_REGION="${TF_STATE_REGION:-${AWS_REGION}}"
TF_STATE_DYNAMODB_TABLE="${TF_STATE_DYNAMODB_TABLE:-}"
TERRAFORM_ACTION="${TERRAFORM_ACTION:-apply}"
BACKEND_S3_TEMPLATE="${TERRAFORM_DIR}/backend.s3.tf.example"
EFFECTIVE_TF_STATE_BUCKET=""
backend_override_file=""

cleanup() {
  if [[ -n "${backend_override_file}" && -f "${backend_override_file}" ]]; then
    rm -f "${backend_override_file}"
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
  unset_if_empty "TF_STATE_BUCKET"
  unset_if_empty "TF_STATE_DYNAMODB_TABLE"
  unset_if_empty "TF_VAR_azs"
  unset_if_empty "TF_VAR_public_subnet_cidrs"
  unset_if_empty "TF_VAR_cluster_endpoint_public_access_cidrs"
  unset_if_empty "TF_VAR_eks_cluster_role_arn"
  unset_if_empty "TF_VAR_eks_node_role_arn"
  unset_if_empty "TF_VAR_eks_access_principal_arn"
  unset_if_empty "TF_VAR_terraform_shared_data_bucket_name"
}

aws_caller_identity() {
  aws sts get-caller-identity --output json
}

aws_caller_account_id() {
  aws sts get-caller-identity --query 'Account' --output text
}

resolve_shared_bucket_name() {
  if [[ -n "${TF_VAR_terraform_shared_data_bucket_name:-}" ]]; then
    printf '%s\n' "${TF_VAR_terraform_shared_data_bucket_name:-}"
    return
  fi

  printf 'tf-shared-%s-%s-%s\n' \
    "${TF_VAR_cluster_name}" \
    "$(aws_caller_account_id)" \
    "${TF_VAR_region}"
}

resolve_effective_backend_bucket() {
  if [[ -n "${TF_STATE_BUCKET:-}" ]]; then
    printf '%s\n' "${TF_STATE_BUCKET:-}"
    return
  fi

  resolve_shared_bucket_name
}

resolve_role_arn_by_name_fragment() {
  local fragment="$1"
  aws iam list-roles \
    --query "Roles[?contains(RoleName, '${fragment}')].Arn | [0]" \
    --output text 2>/dev/null
}

resolve_current_principal_arn() {
  local caller_arn assumed_role_name account_id
  caller_arn="$(aws sts get-caller-identity --query 'Arn' --output text)"

  if [[ "${caller_arn}" =~ ^arn:aws:sts::([0-9]{12}):assumed-role/([^/]+)/.+$ ]]; then
    account_id="${BASH_REMATCH[1]}"
    assumed_role_name="${BASH_REMATCH[2]}"
    printf 'arn:aws:iam::%s:role/%s\n' "${account_id}" "${assumed_role_name}"
    return
  fi

  printf '%s\n' "${caller_arn}"
}

validate_role_account_match() {
  local arn="$1"
  local label="$2"
  local current_account="$3"
  local arn_account=""

  if [[ "${arn}" =~ ^arn:aws:iam::([0-9]{12}):role/.+$ ]]; then
    arn_account="${BASH_REMATCH[1]}"
  fi

  if [[ -n "${arn_account}" && "${arn_account}" != "${current_account}" ]]; then
    echo "${label} aponta para a conta ${arn_account}, mas as credenciais AWS atuais estao na conta ${current_account}. Configure ${label} com uma role da mesma conta do runner." >&2
    exit 1
  fi
}

set_eks_role_defaults() {
  local current_account cluster_role_arn node_role_arn access_principal_arn
  current_account="$(aws_caller_account_id)"

  cluster_role_arn="${TF_VAR_eks_cluster_role_arn:-}"
  node_role_arn="${TF_VAR_eks_node_role_arn:-}"
  access_principal_arn="${TF_VAR_eks_access_principal_arn:-}"

  if [[ -z "${cluster_role_arn}" ]]; then
    cluster_role_arn="$(resolve_role_arn_by_name_fragment 'LabEksClusterRole')"

    if [[ -z "${cluster_role_arn}" || "${cluster_role_arn}" == "None" ]]; then
      echo "Nao foi possivel descobrir automaticamente a role do cluster EKS. Configure EKS_CLUSTER_ROLE_ARN nas vars do GitHub." >&2
      exit 1
    fi

    export TF_VAR_eks_cluster_role_arn="${cluster_role_arn}"
    log "Usando role descoberta para o cluster EKS: ${cluster_role_arn}"
  fi

  if [[ -z "${node_role_arn}" ]]; then
    node_role_arn="$(resolve_role_arn_by_name_fragment 'LabEksNodeRole')"

    if [[ -z "${node_role_arn}" || "${node_role_arn}" == "None" ]]; then
      echo "Nao foi possivel descobrir automaticamente a role dos nodes EKS. Configure EKS_NODE_ROLE_ARN nas vars do GitHub." >&2
      exit 1
    fi

    export TF_VAR_eks_node_role_arn="${node_role_arn}"
    log "Usando role descoberta para os nodes EKS: ${node_role_arn}"
  fi

  if [[ -z "${access_principal_arn}" ]]; then
    access_principal_arn="$(resolve_current_principal_arn)"
    export TF_VAR_eks_access_principal_arn="${access_principal_arn}"
    log "Usando principal de acesso ao cluster derivado das credenciais atuais: ${access_principal_arn}"
  fi

  validate_role_account_match "${TF_VAR_eks_cluster_role_arn}" "EKS_CLUSTER_ROLE_ARN" "${current_account}"
  validate_role_account_match "${TF_VAR_eks_node_role_arn}" "EKS_NODE_ROLE_ARN" "${current_account}"
}

terraform_state_manages_ecr_repository() {
  terraform -chdir="${TERRAFORM_DIR}" state list 2>/dev/null | grep -q '^module\.ecr\.aws_ecr_repository\.app\[0\]$'
}

aws_ecr_repository_exists() {
  aws ecr describe-repositories \
    --region "${AWS_REGION}" \
    --repository-names "${TF_VAR_ecr_repository_name}" >/dev/null 2>&1
}

set_ecr_repository_mode() {
  if terraform_state_manages_ecr_repository; then
    log "Repositorio ECR ${TF_VAR_ecr_repository_name} ja esta no state deste ambiente; mantendo gerenciamento pelo Terraform."
    export TF_VAR_create_ecr_repository="true"
  elif aws_ecr_repository_exists; then
    log "Repositorio ECR ${TF_VAR_ecr_repository_name} ja existe fora do state deste ambiente; reutilizando sem tentar recriar."
    export TF_VAR_create_ecr_repository="false"
  else
    log "Repositorio ECR ${TF_VAR_ecr_repository_name} ainda nao existe; habilitando criacao automatica."
    export TF_VAR_create_ecr_repository="true"
  fi
}

terraform_state_manages_shared_bucket_resource() {
  terraform -chdir="${TERRAFORM_DIR}" state list 2>/dev/null | grep -q '^module\.terraform_shared_data_bucket\[0\]\.aws_s3_bucket\.this$'
}

set_shared_bucket_mode() {
  local shared_bucket_name=""
  shared_bucket_name="$(resolve_shared_bucket_name)"
  export TF_VAR_terraform_shared_data_bucket_name="${shared_bucket_name}"

  if terraform_state_manages_shared_bucket_resource; then
    log "Bucket compartilhado ${shared_bucket_name} ja esta no state deste ambiente; mantendo gerenciamento pelo Terraform."
    export TF_VAR_create_terraform_shared_data_bucket="true"
  elif aws s3api head-bucket --bucket "${shared_bucket_name}" >/dev/null 2>&1; then
    log "Bucket compartilhado ${shared_bucket_name} ja existe fora do state deste ambiente; reutilizando sem tentar recriar."
    export TF_VAR_create_terraform_shared_data_bucket="false"
  else
    log "Bucket compartilhado ${shared_bucket_name} ainda nao existe; habilitando criacao automatica."
    export TF_VAR_create_terraform_shared_data_bucket="true"
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

terraform_remote_backend_args() {
  local args=(
    "-backend-config=bucket=${EFFECTIVE_TF_STATE_BUCKET}"
    "-backend-config=key=${TF_STATE_KEY}"
    "-backend-config=region=${TF_STATE_REGION}"
    "-backend-config=encrypt=true"
  )

  if [[ -n "${TF_STATE_DYNAMODB_TABLE:-}" ]]; then
    args+=("-backend-config=dynamodb_table=${TF_STATE_DYNAMODB_TABLE:-}")
  fi

  printf '%s\n' "${args[@]}"
}

terraform_init_remote() {
  mapfile -t backend_args < <(terraform_remote_backend_args)
  terraform -chdir="${TERRAFORM_DIR}" init -input=false -reconfigure "${backend_args[@]}"
}

terraform_migrate_state_remote() {
  mapfile -t backend_args < <(terraform_remote_backend_args)
  terraform -chdir="${TERRAFORM_DIR}" init -input=false -migrate-state -force-copy "${backend_args[@]}"
}

terraform_init_local() {
  terraform -chdir="${TERRAFORM_DIR}" init -input=false -reconfigure
}

disable_remote_backend_override() {
  if [[ -n "${backend_override_file}" && -f "${backend_override_file}" ]]; then
    rm -f "${backend_override_file}"
    backend_override_file=""
  fi
}

terraform_migrate_state_local() {
  disable_remote_backend_override
  terraform -chdir="${TERRAFORM_DIR}" init -input=false -migrate-state -force-copy
}

terraform_state_manages_shared_bucket() {
  terraform -chdir="${TERRAFORM_DIR}" state list 2>/dev/null | grep -q '^module\.terraform_shared_data_bucket\[0\]\.aws_s3_bucket\.this$'
}

aws_bucket_exists() {
  aws s3api head-bucket \
    --region "${TF_STATE_REGION}" \
    --bucket "${EFFECTIVE_TF_STATE_BUCKET}" >/dev/null 2>&1
}

remote_state_exists() {
  aws s3api head-object \
    --region "${TF_STATE_REGION}" \
    --bucket "${EFFECTIVE_TF_STATE_BUCKET}" \
    --key "${TF_STATE_KEY}" >/dev/null 2>&1
}

eks_cluster_exists() {
  aws eks describe-cluster \
    --region "${AWS_REGION}" \
    --name "${EKS_CLUSTER_NAME}" >/dev/null 2>&1
}

orphan_network_exists() {
  local vpc_ids=""
  vpc_ids="$(aws ec2 describe-vpcs \
    --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=${EKS_CLUSTER_NAME}-vpc" \
    --query 'Vpcs[].VpcId' \
    --output text 2>/dev/null || true)"

  [[ -n "${vpc_ids}" && "${vpc_ids}" != "None" ]]
}

fail_missing_remote_state_with_existing_resources() {
  if eks_cluster_exists; then
    echo "O cluster EKS ${EKS_CLUSTER_NAME} ja existe, mas o state remoto ${EFFECTIVE_TF_STATE_BUCKET}/${TF_STATE_KEY} nao foi encontrado. O runner perdeu o state local de execucoes anteriores. Para recuperar com seguranca, execute o workflow manual 'Cleanup Orphan Lab Infra', depois rode 'Terraform Apply Lab' para recriar a infraestrutura com state remoto persistido, e so entao volte ao workflow de deploy." >&2
    exit 1
  fi

  if orphan_network_exists; then
    echo "A rede do laboratorio ${EKS_CLUSTER_NAME} ainda existe na AWS, mas o state remoto ${EFFECTIVE_TF_STATE_BUCKET}/${TF_STATE_KEY} nao foi encontrado. Para evitar duplicacao de VPC/subnets e outros recursos orfaos, execute o workflow manual 'Cleanup Orphan Lab Infra', depois rode 'Terraform Apply Lab' para recriar a infraestrutura com state remoto persistido." >&2
    exit 1
  fi
}

run_apply() {
  EFFECTIVE_TF_STATE_BUCKET="$(resolve_effective_backend_bucket)"

  if aws_bucket_exists; then
    export TF_VAR_terraform_shared_data_bucket_name="${EFFECTIVE_TF_STATE_BUCKET}"

    if remote_state_exists; then
      log "Bucket ${EFFECTIVE_TF_STATE_BUCKET} e state remoto encontrados; configurando backend remoto."
      create_backend_override
      terraform_init_remote

      if terraform_state_manages_shared_bucket; then
        log "Bucket ${EFFECTIVE_TF_STATE_BUCKET} ja esta no state deste ambiente; mantendo gerenciamento pelo Terraform."
        export TF_VAR_create_terraform_shared_data_bucket="true"
      else
        log "Bucket ${EFFECTIVE_TF_STATE_BUCKET} existe fora do state deste ambiente; reutilizando sem tentar recriar."
        export TF_VAR_create_terraform_shared_data_bucket="false"
      fi
    else
      fail_missing_remote_state_with_existing_resources

      log "Bucket ${EFFECTIVE_TF_STATE_BUCKET} existe, mas o state remoto ainda nao foi criado. Executando bootstrap local e migrando o state ao final."
      export TF_VAR_create_terraform_shared_data_bucket="false"
      terraform_init_local
      set_shared_bucket_mode
      set_ecr_repository_mode
      terraform -chdir="${TERRAFORM_DIR}" apply -input=false -auto-approve

      log "Migrando o state local para o backend S3 em ${EFFECTIVE_TF_STATE_BUCKET}."
      create_backend_override
      terraform_migrate_state_remote
    fi
  else
    log "Bucket de backend ${EFFECTIVE_TF_STATE_BUCKET} ainda nao existe; executando bootstrap local para criar o bucket compartilhado."
    terraform_init_local
    set_shared_bucket_mode
    set_ecr_repository_mode
    terraform -chdir="${TERRAFORM_DIR}" apply -input=false -auto-approve

    log "Migrando o state local para o backend S3 em ${EFFECTIVE_TF_STATE_BUCKET}."
    create_backend_override
    terraform_migrate_state_remote
  fi

  export TF_VAR_terraform_shared_data_bucket_name="${EFFECTIVE_TF_STATE_BUCKET}"
  set_shared_bucket_mode
  set_ecr_repository_mode
  terraform -chdir="${TERRAFORM_DIR}" apply -input=false -auto-approve
}

run_destroy() {
  EFFECTIVE_TF_STATE_BUCKET="$(resolve_effective_backend_bucket)"

  if aws_bucket_exists; then
    export TF_VAR_terraform_shared_data_bucket_name="${EFFECTIVE_TF_STATE_BUCKET}"

    if ! remote_state_exists; then
      echo "O bucket de backend ${EFFECTIVE_TF_STATE_BUCKET} existe, mas o state remoto ${TF_STATE_KEY} nao foi encontrado. Sem esse state, o workflow nao consegue destruir a infraestrutura com seguranca." >&2
      exit 1
    fi

    log "Bucket ${EFFECTIVE_TF_STATE_BUCKET} existe; carregando state do backend remoto."
    create_backend_override
    terraform_init_remote

    if terraform_state_manages_shared_bucket; then
      log "O bucket de backend faz parte do state; migrando o state para backend local antes do destroy."
      export TF_VAR_create_terraform_shared_data_bucket="true"
      terraform_migrate_state_local
    else
      log "O bucket de backend e externo ao state deste ambiente; destruindo a infraestrutura sem tocar no bucket."
      export TF_VAR_create_terraform_shared_data_bucket="false"
    fi
  else
    echo "O bucket de backend ${EFFECTIVE_TF_STATE_BUCKET} nao existe. Sem state remoto persistente, o workflow nao consegue destruir a infraestrutura criada em execucoes anteriores do GitHub Actions." >&2
    exit 1
  fi

  export TF_VAR_terraform_shared_data_bucket_name="${EFFECTIVE_TF_STATE_BUCKET}"
  set_shared_bucket_mode
  set_ecr_repository_mode
  terraform -chdir="${TERRAFORM_DIR}" destroy -input=false -auto-approve
}

normalize_optional_envs

require_cmd aws
require_cmd terraform
require_non_empty "${AWS_REGION}" "AWS_REGION"
require_non_empty "${EKS_CLUSTER_NAME}" "EKS_CLUSTER_NAME"
require_non_empty "${TF_VAR_kubernetes_version:-}" "TF_VAR_kubernetes_version"
set_eks_role_defaults

case "${TERRAFORM_ACTION}" in
  apply)
    run_apply
    ;;
  destroy)
    run_destroy
    ;;
  *)
    echo "TERRAFORM_ACTION invalida: ${TERRAFORM_ACTION}. Use apply ou destroy." >&2
    exit 1
    ;;
esac
