#!/usr/bin/env bash

set -euo pipefail

AWS_REGION="${AWS_REGION:-}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-eks-lab}"
DB_IDENTIFIER="${DB_IDENTIFIER:-oficina-postgres-lab}"
DB_PARAMETER_GROUP_NAME="${DB_PARAMETER_GROUP_NAME:-${DB_IDENTIFIER}-pg}"
DB_SUBNET_GROUP_NAME="${DB_SUBNET_GROUP_NAME:-${DB_IDENTIFIER}-subnet-group}"
DB_MONITORING_ROLE_NAME="${DB_MONITORING_ROLE_NAME:-${DB_IDENTIFIER}-rds-monitoring}"
DB_APP_SECRET_NAME="${DB_APP_SECRET_NAME:-oficina/lab/database/app}"
AUTH_DB_SECRET_NAME="${AUTH_DB_SECRET_NAME:-oficina/lab/database/auth-lambda}"
JWT_SECRET_NAME="${JWT_SECRET_NAME:-oficina/lab/jwt}"
AUTH_LAMBDA_FUNCTION_NAME="${AUTH_LAMBDA_FUNCTION_NAME:-oficina-auth-lambda-lab}"
NOTIFICACAO_LAMBDA_FUNCTION_NAME="${NOTIFICACAO_LAMBDA_FUNCTION_NAME:-oficina-notificacao-lambda-lab}"
AUTH_LAMBDA_LOG_GROUP_NAME="${AUTH_LAMBDA_LOG_GROUP_NAME:-/aws/lambda/${AUTH_LAMBDA_FUNCTION_NAME}}"
AUTH_LAMBDA_LEGACY_LOG_GROUP_NAME="${AUTH_LAMBDA_LEGACY_LOG_GROUP_NAME:-/aws/lambda/OficinaAuthLambdaNative}"
NOTIFICACAO_LAMBDA_LOG_GROUP_NAME="${NOTIFICACAO_LAMBDA_LOG_GROUP_NAME:-/aws/lambda/${NOTIFICACAO_LAMBDA_FUNCTION_NAME}}"
AUTH_LAMBDA_SECURITY_GROUP_NAME="${AUTH_LAMBDA_SECURITY_GROUP_NAME:-${AUTH_LAMBDA_FUNCTION_NAME}-sg}"
NOTIFICACAO_LAMBDA_SECURITY_GROUP_NAME="${NOTIFICACAO_LAMBDA_SECURITY_GROUP_NAME:-${EKS_CLUSTER_NAME}-notificacao-lambda}"
ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-oficina}"
LAMBDA_ARTIFACT_BUCKET="${LAMBDA_ARTIFACT_BUCKET:-${TF_STATE_BUCKET:-}}"
AUTH_LAMBDA_ARTIFACT_PREFIX="${AUTH_LAMBDA_ARTIFACT_PREFIX:-oficina/lab/lambda/oficina-auth-lambda}"
NOTIFICACAO_LAMBDA_ARTIFACT_PREFIX="${NOTIFICACAO_LAMBDA_ARTIFACT_PREFIX:-oficina/lab/lambda/oficina-notificacao-lambda}"
DELETE_RUNTIME_SECRETS="${DELETE_RUNTIME_SECRETS:-true}"
DELETE_LAMBDA_ARTIFACT_OBJECTS="${DELETE_LAMBDA_ARTIFACT_OBJECTS:-false}"
SKIP_FINAL_DB_SNAPSHOT="${SKIP_FINAL_DB_SNAPSHOT:-true}"
DB_FINAL_SNAPSHOT_IDENTIFIER="${DB_FINAL_SNAPSHOT_IDENTIFIER:-${DB_IDENTIFIER}-final-$(date '+%Y%m%d%H%M%S')}"
NETWORK_INTERFACE_WAIT_SECONDS="${NETWORK_INTERFACE_WAIT_SECONDS:-600}"
NETWORK_INTERFACE_POLL_SECONDS="${NETWORK_INTERFACE_POLL_SECONDS:-15}"

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

trim_none() {
  if [[ "${1:-}" == "None" ]]; then
    return
  fi

  printf '%s' "${1:-}"
}

function_exists() {
  local function_name="$1"

  aws lambda get-function \
    --region "${AWS_REGION}" \
    --function-name "${function_name}" >/dev/null 2>&1
}

db_exists() {
  aws rds describe-db-instances \
    --region "${AWS_REGION}" \
    --db-instance-identifier "${DB_IDENTIFIER}" >/dev/null 2>&1
}

cluster_vpc_id() {
  local vpc_id=""

  vpc_id="$(
    aws eks describe-cluster \
      --region "${AWS_REGION}" \
      --name "${EKS_CLUSTER_NAME}" \
      --query 'cluster.resourcesVpcConfig.vpcId' \
      --output text 2>/dev/null || true
  )"

  trim_none "${vpc_id}"
}

db_vpc_id() {
  local vpc_id=""

  vpc_id="$(
    aws rds describe-db-instances \
      --region "${AWS_REGION}" \
      --db-instance-identifier "${DB_IDENTIFIER}" \
      --query 'DBInstances[0].DBSubnetGroup.VpcId' \
      --output text 2>/dev/null || true
  )"

  trim_none "${vpc_id}"
}

db_security_group_ids() {
  local ids=""

  ids="$(
    aws rds describe-db-instances \
      --region "${AWS_REGION}" \
      --db-instance-identifier "${DB_IDENTIFIER}" \
      --query 'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId' \
      --output text 2>/dev/null || true
  )"

  trim_none "${ids}"
}

db_port() {
  local port=""

  port="$(
    aws rds describe-db-instances \
      --region "${AWS_REGION}" \
      --db-instance-identifier "${DB_IDENTIFIER}" \
      --query 'DBInstances[0].Endpoint.Port' \
      --output text 2>/dev/null || true
  )"

  trim_none "${port}"
}

db_master_secret_arn() {
  local arn=""

  arn="$(
    aws rds describe-db-instances \
      --region "${AWS_REGION}" \
      --db-instance-identifier "${DB_IDENTIFIER}" \
      --query 'DBInstances[0].MasterUserSecret.SecretArn' \
      --output text 2>/dev/null || true
  )"

  trim_none "${arn}"
}

resolve_security_group_id_by_name() {
  local group_name="$1"
  local vpc_id="$2"
  local group_id=""

  if [[ -z "${group_name}" || -z "${vpc_id}" ]]; then
    return
  fi

  group_id="$(
    aws ec2 describe-security-groups \
      --region "${AWS_REGION}" \
      --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${group_name}" \
      --query 'SecurityGroups[0].GroupId' \
      --output text 2>/dev/null || true
  )"

  trim_none "${group_id}"
}

resolve_auth_lambda_security_group_id() {
  local group_id=""
  local vpc_id=""

  if function_exists "${AUTH_LAMBDA_FUNCTION_NAME}"; then
    group_id="$(
      aws lambda get-function-configuration \
        --region "${AWS_REGION}" \
        --function-name "${AUTH_LAMBDA_FUNCTION_NAME}" \
        --query 'VpcConfig.SecurityGroupIds[0]' \
        --output text 2>/dev/null || true
    )"
    group_id="$(trim_none "${group_id}")"

    if [[ -n "${group_id}" ]]; then
      printf '%s\n' "${group_id}"
      return
    fi
  fi

  vpc_id="$(cluster_vpc_id)"
  if [[ -z "${vpc_id}" ]]; then
    vpc_id="$(db_vpc_id)"
  fi

  resolve_security_group_id_by_name "${AUTH_LAMBDA_SECURITY_GROUP_NAME}" "${vpc_id}"
}

delete_lambda_function() {
  local function_name="$1"

  if ! function_exists "${function_name}"; then
    log "Lambda ${function_name} nao encontrada; seguindo"
    return
  fi

  log "Removendo Lambda ${function_name}"
  aws lambda delete-function \
    --region "${AWS_REGION}" \
    --function-name "${function_name}" >/dev/null

  while function_exists "${function_name}"; do
    log "Aguardando remocao da Lambda ${function_name}"
    sleep 5
  done
}

delete_log_group_if_exists() {
  local log_group_name="$1"
  local found=""

  found="$(
    aws logs describe-log-groups \
      --region "${AWS_REGION}" \
      --log-group-name-prefix "${log_group_name}" \
      --query "logGroups[?logGroupName==\`${log_group_name}\`].logGroupName" \
      --output text 2>/dev/null || true
  )"
  found="$(trim_none "${found}")"

  if [[ -z "${found}" ]]; then
    log "Log group ${log_group_name} nao encontrado; seguindo"
    return
  fi

  log "Removendo log group ${log_group_name}"
  aws logs delete-log-group \
    --region "${AWS_REGION}" \
    --log-group-name "${log_group_name}" >/dev/null
}

ecr_repository_exists() {
  local repository_name="$1"

  if [[ -z "${repository_name}" ]]; then
    return 1
  fi

  aws ecr describe-repositories \
    --region "${AWS_REGION}" \
    --repository-names "${repository_name}" >/dev/null 2>&1
}

delete_ecr_repository_if_exists() {
  local repository_name="$1"

  if ! ecr_repository_exists "${repository_name}"; then
    log "Repositorio ECR ${repository_name} nao encontrado; seguindo"
    return
  fi

  log "Removendo repositorio ECR ${repository_name}"
  aws ecr delete-repository \
    --region "${AWS_REGION}" \
    --repository-name "${repository_name}" \
    --force >/dev/null
}

list_security_group_network_interfaces() {
  local security_group_id="$1"

  aws ec2 describe-network-interfaces \
    --region "${AWS_REGION}" \
    --filters "Name=group-id,Values=${security_group_id}" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --output text 2>/dev/null || true
}

wait_for_security_group_release() {
  local security_group_id="$1"
  local deadline=$((SECONDS + NETWORK_INTERFACE_WAIT_SECONDS))
  local interface_ids=""

  while true; do
    interface_ids="$(list_security_group_network_interfaces "${security_group_id}")"

    if [[ -z "${interface_ids}" || "${interface_ids}" == "None" ]]; then
      return
    fi

    if (( SECONDS >= deadline )); then
      echo "O security group ${security_group_id} ainda possui ENIs apos ${NETWORK_INTERFACE_WAIT_SECONDS}s: ${interface_ids}" >&2
      exit 1
    fi

    log "Aguardando liberacao de ENIs do security group ${security_group_id}: ${interface_ids}"
    sleep "${NETWORK_INTERFACE_POLL_SECONDS}"
  done
}

delete_security_group_if_released() {
  local security_group_id="$1"

  if [[ -z "${security_group_id}" ]]; then
    return
  fi

  wait_for_security_group_release "${security_group_id}"

  if aws ec2 delete-security-group --region "${AWS_REGION}" --group-id "${security_group_id}" >/dev/null 2>&1; then
    log "Security group ${security_group_id} removido"
    return
  fi

  log "Security group ${security_group_id} mantido porque a AWS ainda reporta dependencia nele"
}

revoke_db_ingress_from_security_group() {
  local security_group_id="$1"
  local db_group_ids=""
  local target_port=""
  local db_group_id=""
  local output=""
  local status=0

  if [[ -z "${security_group_id}" ]] || ! db_exists; then
    return
  fi

  db_group_ids="$(db_security_group_ids)"
  target_port="$(db_port)"

  if [[ -z "${db_group_ids}" || -z "${target_port}" ]]; then
    return
  fi

  for db_group_id in ${db_group_ids}; do
    [[ -n "${db_group_id}" && "${db_group_id}" != "None" ]] || continue

    log "Revogando acesso ${security_group_id} -> ${db_group_id}:${target_port}"
    set +e
    output="$(
      aws ec2 revoke-security-group-ingress \
        --region "${AWS_REGION}" \
        --group-id "${db_group_id}" \
        --ip-permissions "IpProtocol=tcp,FromPort=${target_port},ToPort=${target_port},UserIdGroupPairs=[{GroupId=${security_group_id}}]" 2>&1
    )"
    status=$?
    set -e

    if [[ ${status} -ne 0 ]] && ! grep -Eq "InvalidPermission.NotFound|InvalidGroup.NotFound" <<<"${output}"; then
      echo "${output}" >&2
      exit "${status}"
    fi
  done
}

cleanup_auth_lambda() {
  local auth_lambda_sg_id=""

  auth_lambda_sg_id="$(resolve_auth_lambda_security_group_id)"
  revoke_db_ingress_from_security_group "${auth_lambda_sg_id}"
  delete_lambda_function "${AUTH_LAMBDA_FUNCTION_NAME}"
  delete_log_group_if_exists "${AUTH_LAMBDA_LOG_GROUP_NAME}"
  delete_log_group_if_exists "${AUTH_LAMBDA_LEGACY_LOG_GROUP_NAME}"
  delete_security_group_if_released "${auth_lambda_sg_id}"
}

cleanup_notificacao_lambda() {
  delete_lambda_function "${NOTIFICACAO_LAMBDA_FUNCTION_NAME}"
  delete_log_group_if_exists "${NOTIFICACAO_LAMBDA_LOG_GROUP_NAME}"
}

delete_lambda_artifact_prefix() {
  local prefix="$1"

  if [[ -z "${LAMBDA_ARTIFACT_BUCKET}" || -z "${prefix}" ]]; then
    return
  fi

  log "Removendo objetos em s3://${LAMBDA_ARTIFACT_BUCKET}/${prefix}"
  aws s3 rm "s3://${LAMBDA_ARTIFACT_BUCKET}/${prefix}" \
    --region "${AWS_REGION}" \
    --recursive >/dev/null 2>&1 || true
}

disable_db_deletion_protection() {
  aws rds modify-db-instance \
    --region "${AWS_REGION}" \
    --db-instance-identifier "${DB_IDENTIFIER}" \
    --no-deletion-protection \
    --apply-immediately >/dev/null
}

delete_db_instance() {
  if is_truthy "${SKIP_FINAL_DB_SNAPSHOT}"; then
    aws rds delete-db-instance \
      --region "${AWS_REGION}" \
      --db-instance-identifier "${DB_IDENTIFIER}" \
      --skip-final-snapshot \
      --delete-automated-backups >/dev/null
    return
  fi

  aws rds delete-db-instance \
    --region "${AWS_REGION}" \
    --db-instance-identifier "${DB_IDENTIFIER}" \
    --final-db-snapshot-identifier "${DB_FINAL_SNAPSHOT_IDENTIFIER}" \
    --delete-automated-backups >/dev/null
}

delete_db_alarm_if_exists() {
  local alarm_name="$1"
  local found=""

  found="$(
    aws cloudwatch describe-alarms \
      --region "${AWS_REGION}" \
      --alarm-names "${alarm_name}" \
      --query 'MetricAlarms[0].AlarmName' \
      --output text 2>/dev/null || true
  )"
  found="$(trim_none "${found}")"

  if [[ -z "${found}" ]]; then
    return
  fi

  log "Removendo alarme ${alarm_name}"
  aws cloudwatch delete-alarms \
    --region "${AWS_REGION}" \
    --alarm-names "${alarm_name}" >/dev/null
}

delete_db_monitoring_role_if_exists() {
  local role_name="$1"

  if ! aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    return
  fi

  aws iam detach-role-policy \
    --role-name "${role_name}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole" >/dev/null 2>&1 || true

  log "Removendo IAM role ${role_name}"
  aws iam delete-role --role-name "${role_name}" >/dev/null 2>&1 || true
}

delete_db_log_groups_by_prefix() {
  local prefix="/aws/rds/instance/${DB_IDENTIFIER}/"
  local log_groups=""
  local log_group_name=""

  log_groups="$(
    aws logs describe-log-groups \
      --region "${AWS_REGION}" \
      --log-group-name-prefix "${prefix}" \
      --query 'logGroups[].logGroupName' \
      --output text 2>/dev/null || true
  )"

  for log_group_name in ${log_groups}; do
    [[ -n "${log_group_name}" && "${log_group_name}" != "None" ]] || continue
    log "Removendo log group ${log_group_name}"
    aws logs delete-log-group \
      --region "${AWS_REGION}" \
      --log-group-name "${log_group_name}" >/dev/null 2>&1 || true
  done
}

delete_db_parameter_group_if_unused() {
  local in_use=""

  in_use="$(
    aws rds describe-db-instances \
      --region "${AWS_REGION}" \
      --query "DBInstances[?DBParameterGroups[?DBParameterGroupName==\`${DB_PARAMETER_GROUP_NAME}\`]].DBInstanceIdentifier" \
      --output text 2>/dev/null || true
  )"

  if [[ -n "${in_use}" && "${in_use}" != "None" ]]; then
    log "Parameter group ${DB_PARAMETER_GROUP_NAME} mantido porque ainda esta em uso por ${in_use}"
    return
  fi

  aws rds delete-db-parameter-group \
    --region "${AWS_REGION}" \
    --db-parameter-group-name "${DB_PARAMETER_GROUP_NAME}" >/dev/null 2>&1 || true
}

delete_db_subnet_group_if_unused() {
  local in_use=""

  in_use="$(
    aws rds describe-db-instances \
      --region "${AWS_REGION}" \
      --query "DBInstances[?DBSubnetGroup.DBSubnetGroupName==\`${DB_SUBNET_GROUP_NAME}\`].DBInstanceIdentifier" \
      --output text 2>/dev/null || true
  )"

  if [[ -n "${in_use}" && "${in_use}" != "None" ]]; then
    log "Subnet group ${DB_SUBNET_GROUP_NAME} mantido porque ainda esta em uso por ${in_use}"
    return
  fi

  aws rds delete-db-subnet-group \
    --region "${AWS_REGION}" \
    --db-subnet-group-name "${DB_SUBNET_GROUP_NAME}" >/dev/null 2>&1 || true
}

delete_db_security_group_if_unused() {
  local security_group_id="$1"
  local in_use=""
  local network_interfaces=""

  if [[ -z "${security_group_id}" ]]; then
    return
  fi

  in_use="$(
    aws rds describe-db-instances \
      --region "${AWS_REGION}" \
      --query "DBInstances[?length(VpcSecurityGroups[?VpcSecurityGroupId==\`${security_group_id}\`]) > \`0\`].DBInstanceIdentifier" \
      --output text 2>/dev/null || true
  )"

  if [[ -n "${in_use}" && "${in_use}" != "None" ]]; then
    log "Security group ${security_group_id} mantido porque ainda esta em uso por instancias RDS (${in_use})"
    return
  fi

  network_interfaces="$(
    aws ec2 describe-network-interfaces \
      --region "${AWS_REGION}" \
      --filters "Name=group-id,Values=${security_group_id}" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' \
      --output text 2>/dev/null || true
  )"

  if [[ -n "${network_interfaces}" && "${network_interfaces}" != "None" ]]; then
    log "Security group ${security_group_id} mantido porque ainda esta em uso por interfaces de rede (${network_interfaces})"
    return
  fi

  aws ec2 delete-security-group \
    --region "${AWS_REGION}" \
    --group-id "${security_group_id}" >/dev/null 2>&1 || true
}

cleanup_database() {
  local db_sg_ids=""
  local db_master_secret=""

  db_master_secret="$(db_master_secret_arn)"
  db_sg_ids="$(db_security_group_ids)"

  if db_exists; then
    log "Desabilitando deletion protection da instancia ${DB_IDENTIFIER}"
    disable_db_deletion_protection
    log "Removendo instancia RDS ${DB_IDENTIFIER}"
    delete_db_instance
    aws rds wait db-instance-deleted \
      --region "${AWS_REGION}" \
      --db-instance-identifier "${DB_IDENTIFIER}"
  else
    log "Instancia RDS ${DB_IDENTIFIER} nao encontrada; seguindo"
  fi

  delete_db_log_groups_by_prefix
  delete_db_alarm_if_exists "${DB_IDENTIFIER}-cpu-utilization-high"
  delete_db_alarm_if_exists "${DB_IDENTIFIER}-free-storage-low"
  delete_db_alarm_if_exists "${DB_IDENTIFIER}-freeable-memory-low"
  delete_db_monitoring_role_if_exists "${DB_MONITORING_ROLE_NAME}"
  delete_db_parameter_group_if_unused
  delete_db_subnet_group_if_unused

  for db_sg_id in ${db_sg_ids}; do
    [[ -n "${db_sg_id}" && "${db_sg_id}" != "None" ]] || continue
    delete_db_security_group_if_unused "${db_sg_id}"
  done

  if is_truthy "${DELETE_RUNTIME_SECRETS}" && [[ -n "${db_master_secret}" ]]; then
    delete_secret_if_exists "${db_master_secret}"
  fi
}

delete_secret_if_exists() {
  local secret_id="$1"

  if [[ -z "${secret_id}" ]]; then
    return
  fi

  if ! aws secretsmanager describe-secret --region "${AWS_REGION}" --secret-id "${secret_id}" >/dev/null 2>&1; then
    return
  fi

  log "Removendo secret ${secret_id}"
  aws secretsmanager delete-secret \
    --region "${AWS_REGION}" \
    --secret-id "${secret_id}" \
    --force-delete-without-recovery >/dev/null
}

cleanup_runtime_secrets() {
  local auth_db_field=""

  delete_secret_if_exists "${JWT_SECRET_NAME}"
  delete_secret_if_exists "${JWT_SECRET_NAME}/privateKeyPem"
  delete_secret_if_exists "${JWT_SECRET_NAME}/publicKeyPem"
  delete_secret_if_exists "${DB_APP_SECRET_NAME}"
  delete_secret_if_exists "${AUTH_DB_SECRET_NAME}"

  for auth_db_field in engine host port dbname username password; do
    delete_secret_if_exists "${AUTH_DB_SECRET_NAME}/${auth_db_field}"
  done
}

require_cmd aws
require_non_empty "${AWS_REGION}" "AWS_REGION"

aws sts get-caller-identity >/dev/null

cleanup_auth_lambda
cleanup_notificacao_lambda
delete_ecr_repository_if_exists "${ECR_REPOSITORY_NAME}"
cleanup_database

if is_truthy "${DELETE_RUNTIME_SECRETS}"; then
  cleanup_runtime_secrets
fi

if is_truthy "${DELETE_LAMBDA_ARTIFACT_OBJECTS}"; then
  delete_lambda_artifact_prefix "${AUTH_LAMBDA_ARTIFACT_PREFIX}"
  delete_lambda_artifact_prefix "${NOTIFICACAO_LAMBDA_ARTIFACT_PREFIX}"
fi

log "Cleanup da suite AWS concluido"
