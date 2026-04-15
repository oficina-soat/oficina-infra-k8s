#!/usr/bin/env bash

set -euo pipefail

AWS_REGION="${AWS_REGION:-}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
NODE_GROUP_NAME="${NODE_GROUP_NAME:-${EKS_CLUSTER_NAME}-ng}"
API_GATEWAY_NAME="${API_GATEWAY_NAME:-${EKS_CLUSTER_NAME}-http-api}"
API_GATEWAY_VPC_LINK_NAME="${API_GATEWAY_VPC_LINK_NAME:-${API_GATEWAY_NAME}-vpc-link}"
API_GATEWAY_LOG_GROUP_NAME="${API_GATEWAY_LOG_GROUP_NAME:-/aws/apigateway/${API_GATEWAY_NAME}}"
NETWORK_INTERFACE_WAIT_SECONDS="${NETWORK_INTERFACE_WAIT_SECONDS:-600}"
VPC_CLEANUP_WAIT_SECONDS="${VPC_CLEANUP_WAIT_SECONDS:-900}"
VPC_CLEANUP_POLL_SECONDS="${VPC_CLEANUP_POLL_SECONDS:-15}"
VPC_LINK_DELETE_WAIT_SECONDS="${VPC_LINK_DELETE_WAIT_SECONDS:-600}"
VPC_LINK_DELETE_POLL_SECONDS="${VPC_LINK_DELETE_POLL_SECONDS:-10}"

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

node_group_exists() {
  aws eks describe-nodegroup \
    --region "${AWS_REGION}" \
    --cluster-name "${EKS_CLUSTER_NAME}" \
    --nodegroup-name "${NODE_GROUP_NAME}" >/dev/null 2>&1
}

cluster_exists() {
  aws eks describe-cluster \
    --region "${AWS_REGION}" \
    --name "${EKS_CLUSTER_NAME}" >/dev/null 2>&1
}

list_api_gateway_ids() {
  aws apigatewayv2 get-apis \
    --region "${AWS_REGION}" \
    --query "Items[?Name==\`${API_GATEWAY_NAME}\`].ApiId" \
    --output text 2>/dev/null || true
}

list_api_gateway_vpc_link_ids() {
  aws apigatewayv2 get-vpc-links \
    --region "${AWS_REGION}" \
    --query "Items[?Name==\`${API_GATEWAY_VPC_LINK_NAME}\`].VpcLinkId" \
    --output text 2>/dev/null || true
}

api_gateway_vpc_link_exists() {
  local vpc_link_id="$1"

  aws apigatewayv2 get-vpc-link \
    --region "${AWS_REGION}" \
    --vpc-link-id "${vpc_link_id}" >/dev/null 2>&1
}

list_cluster_vpcs() {
  aws ec2 describe-vpcs \
    --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=${EKS_CLUSTER_NAME}-vpc" \
    --query 'Vpcs[].VpcId' \
    --output text
}

vpc_exists() {
  local vpc_id="$1"

  aws ec2 describe-vpcs \
    --region "${AWS_REGION}" \
    --vpc-ids "${vpc_id}" >/dev/null 2>&1
}

list_vpc_subnets() {
  local vpc_id="$1"

  aws ec2 describe-subnets \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'Subnets[].SubnetId' \
    --output text
}

list_vpc_route_table_associations() {
  local vpc_id="$1"

  aws ec2 describe-route-tables \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'RouteTables[].Associations[?Main!=`true`].RouteTableAssociationId' \
    --output text
}

list_vpc_route_tables() {
  local vpc_id="$1"

  aws ec2 describe-route-tables \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'RouteTables[?length(Associations[?Main==`true`])==`0`].RouteTableId' \
    --output text
}

list_vpc_internet_gateways() {
  local vpc_id="$1"

  aws ec2 describe-internet-gateways \
    --region "${AWS_REGION}" \
    --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --query 'InternetGateways[].InternetGatewayId' \
    --output text
}

list_vpc_security_groups() {
  local vpc_id="$1"

  aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text
}

list_vpc_network_interfaces() {
  local vpc_id="$1"

  aws ec2 describe-network-interfaces \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --output text
}

has_ids() {
  local ids="${1:-}"
  [[ -n "${ids}" && "${ids}" != "None" ]]
}

delete_api_gateways() {
  local api_ids=""
  api_ids="$(list_api_gateway_ids)"

  if ! has_ids "${api_ids}"; then
    log "Nenhum API Gateway com nome ${API_GATEWAY_NAME} encontrado; seguindo"
    return
  fi

  for api_id in ${api_ids}; do
    log "Removendo API Gateway ${api_id} (${API_GATEWAY_NAME})"
    aws apigatewayv2 delete-api \
      --region "${AWS_REGION}" \
      --api-id "${api_id}" >/dev/null 2>&1 || true
  done
}

wait_for_vpc_link_deletion() {
  local vpc_link_id="$1"
  local deadline=$((SECONDS + VPC_LINK_DELETE_WAIT_SECONDS))

  while api_gateway_vpc_link_exists "${vpc_link_id}"; do
    if (( SECONDS >= deadline )); then
      echo "O VPC Link ${vpc_link_id} ainda existe apos ${VPC_LINK_DELETE_WAIT_SECONDS}s" >&2
      exit 1
    fi

    log "Aguardando remocao do VPC Link ${vpc_link_id}"
    sleep "${VPC_LINK_DELETE_POLL_SECONDS}"
  done
}

delete_api_gateway_vpc_links() {
  local vpc_link_ids=""
  vpc_link_ids="$(list_api_gateway_vpc_link_ids)"

  if ! has_ids "${vpc_link_ids}"; then
    log "Nenhum VPC Link com nome ${API_GATEWAY_VPC_LINK_NAME} encontrado; seguindo"
    return
  fi

  for vpc_link_id in ${vpc_link_ids}; do
    log "Removendo VPC Link ${vpc_link_id} (${API_GATEWAY_VPC_LINK_NAME})"
    aws apigatewayv2 delete-vpc-link \
      --region "${AWS_REGION}" \
      --vpc-link-id "${vpc_link_id}" >/dev/null 2>&1 || true
    wait_for_vpc_link_deletion "${vpc_link_id}"
  done
}

delete_api_gateway_log_group() {
  local log_group_name=""
  log_group_name="$(aws logs describe-log-groups \
    --region "${AWS_REGION}" \
    --log-group-name-prefix "${API_GATEWAY_LOG_GROUP_NAME}" \
    --query "logGroups[?logGroupName==\`${API_GATEWAY_LOG_GROUP_NAME}\`].logGroupName" \
    --output text 2>/dev/null || true)"

  if [[ -z "${log_group_name}" || "${log_group_name}" == "None" ]]; then
    log "Nenhum log group do API Gateway ${API_GATEWAY_LOG_GROUP_NAME} encontrado; seguindo"
    return
  fi

  log "Removendo log group ${API_GATEWAY_LOG_GROUP_NAME}"
  aws logs delete-log-group \
    --region "${AWS_REGION}" \
    --log-group-name "${API_GATEWAY_LOG_GROUP_NAME}" >/dev/null 2>&1 || true
}

log_vpc_inventory() {
  local vpc_id="$1"

  log "Estado atual da VPC ${vpc_id}"
  printf 'subnets=%s\n' "$(list_vpc_subnets "${vpc_id}")"
  printf 'route_table_associations=%s\n' "$(list_vpc_route_table_associations "${vpc_id}")"
  printf 'route_tables=%s\n' "$(list_vpc_route_tables "${vpc_id}")"
  printf 'internet_gateways=%s\n' "$(list_vpc_internet_gateways "${vpc_id}")"
  printf 'security_groups=%s\n' "$(list_vpc_security_groups "${vpc_id}")"
  printf 'network_interfaces=%s\n' "$(list_vpc_network_interfaces "${vpc_id}")"
}

wait_for_vpc_network_release() {
  local vpc_id="$1"
  local deadline=$((SECONDS + NETWORK_INTERFACE_WAIT_SECONDS))
  local interface_ids=""

  while true; do
    interface_ids="$(list_vpc_network_interfaces "${vpc_id}")"

    if [[ -z "${interface_ids}" || "${interface_ids}" == "None" ]]; then
      return
    fi

    if (( SECONDS >= deadline )); then
      echo "A VPC ${vpc_id} ainda possui interfaces de rede apos ${NETWORK_INTERFACE_WAIT_SECONDS}s: ${interface_ids}" >&2
      return 1
    fi

    log "Aguardando liberacao das interfaces de rede da VPC ${vpc_id}: ${interface_ids}"
    sleep 15
  done
}

delete_vpc_subnets() {
  local vpc_id="$1"
  local subnet_ids=""
  local output=""
  subnet_ids="$(list_vpc_subnets "${vpc_id}")"

  if ! has_ids "${subnet_ids}"; then
    return
  fi

  for subnet_id in ${subnet_ids}; do
    log "Removendo subnet ${subnet_id} da VPC ${vpc_id}"
    if ! output="$(aws ec2 delete-subnet \
      --region "${AWS_REGION}" \
      --subnet-id "${subnet_id}" 2>&1)"; then
      log "Ainda nao foi possivel remover subnet ${subnet_id}: ${output}"
    fi
  done
}

delete_vpc_route_tables() {
  local vpc_id="$1"
  local association_ids=""
  local route_table_ids=""
  local output=""

  association_ids="$(list_vpc_route_table_associations "${vpc_id}")"

  for association_id in ${association_ids}; do
    if [[ -n "${association_id}" && "${association_id}" != "None" ]]; then
      log "Desassociando route table association ${association_id} da VPC ${vpc_id}"
      if ! output="$(aws ec2 disassociate-route-table \
        --region "${AWS_REGION}" \
        --association-id "${association_id}" 2>&1)"; then
        log "Ainda nao foi possivel desassociar route table association ${association_id}: ${output}"
      fi
    fi
  done

  route_table_ids="$(list_vpc_route_tables "${vpc_id}")"

  for route_table_id in ${route_table_ids}; do
    if [[ -n "${route_table_id}" && "${route_table_id}" != "None" ]]; then
      log "Removendo route table ${route_table_id} da VPC ${vpc_id}"
      if ! output="$(aws ec2 delete-route-table \
        --region "${AWS_REGION}" \
        --route-table-id "${route_table_id}" 2>&1)"; then
        log "Ainda nao foi possivel remover route table ${route_table_id}: ${output}"
      fi
    fi
  done
}

delete_vpc_internet_gateways() {
  local vpc_id="$1"
  local igw_ids=""
  local output=""
  igw_ids="$(list_vpc_internet_gateways "${vpc_id}")"

  for igw_id in ${igw_ids}; do
    if [[ -n "${igw_id}" && "${igw_id}" != "None" ]]; then
      log "Desanexando internet gateway ${igw_id} da VPC ${vpc_id}"
      if ! output="$(aws ec2 detach-internet-gateway \
        --region "${AWS_REGION}" \
        --internet-gateway-id "${igw_id}" \
        --vpc-id "${vpc_id}" 2>&1)"; then
        log "Ainda nao foi possivel desanexar internet gateway ${igw_id}: ${output}"
      fi

      log "Removendo internet gateway ${igw_id}"
      if ! output="$(aws ec2 delete-internet-gateway \
        --region "${AWS_REGION}" \
        --internet-gateway-id "${igw_id}" 2>&1)"; then
        log "Ainda nao foi possivel remover internet gateway ${igw_id}: ${output}"
      fi
    fi
  done
}

delete_vpc_security_groups() {
  local vpc_id="$1"
  local security_group_ids=""
  local output=""
  security_group_ids="$(list_vpc_security_groups "${vpc_id}")"

  for security_group_id in ${security_group_ids}; do
    if [[ -n "${security_group_id}" && "${security_group_id}" != "None" ]]; then
      log "Removendo security group ${security_group_id} da VPC ${vpc_id}"
      if ! output="$(aws ec2 delete-security-group \
        --region "${AWS_REGION}" \
        --group-id "${security_group_id}" 2>&1)"; then
        log "Ainda nao foi possivel remover security group ${security_group_id}: ${output}"
      fi
    fi
  done
}

delete_cluster_vpc() {
  local vpc_id="$1"
  local deadline=$((SECONDS + VPC_CLEANUP_WAIT_SECONDS))
  local output=""

  log "Limpando recursos orfaos da VPC ${vpc_id}"

  while vpc_exists "${vpc_id}"; do
    if ! wait_for_vpc_network_release "${vpc_id}"; then
      log "Interfaces de rede ainda existem na VPC ${vpc_id}; tentando limpar as demais dependencias antes de nova tentativa"
    fi
    delete_vpc_subnets "${vpc_id}"
    delete_vpc_route_tables "${vpc_id}"
    delete_vpc_internet_gateways "${vpc_id}"
    delete_vpc_security_groups "${vpc_id}"

    log "Removendo VPC ${vpc_id}"
    output=""
    if output="$(aws ec2 delete-vpc \
      --region "${AWS_REGION}" \
      --vpc-id "${vpc_id}" 2>&1)"; then
      log "VPC ${vpc_id} removida com sucesso"
      return
    fi

    if (( SECONDS >= deadline )); then
      log_vpc_inventory "${vpc_id}"
      echo "Nao foi possivel remover a VPC ${vpc_id} apos ${VPC_CLEANUP_WAIT_SECONDS}s: ${output}" >&2
      exit 1
    fi

    log "A VPC ${vpc_id} ainda nao pode ser removida: ${output}"
    log_vpc_inventory "${vpc_id}"
    sleep "${VPC_CLEANUP_POLL_SECONDS}"
  done
}

require_cmd aws
require_non_empty "${AWS_REGION}" "AWS_REGION"
require_non_empty "${EKS_CLUSTER_NAME}" "EKS_CLUSTER_NAME"

if node_group_exists; then
  log "Removendo node group ${NODE_GROUP_NAME} do cluster ${EKS_CLUSTER_NAME}"
  aws eks delete-nodegroup \
    --region "${AWS_REGION}" \
    --cluster-name "${EKS_CLUSTER_NAME}" \
    --nodegroup-name "${NODE_GROUP_NAME}" >/dev/null

  log "Aguardando remocao do node group ${NODE_GROUP_NAME}"
  aws eks wait nodegroup-deleted \
    --region "${AWS_REGION}" \
    --cluster-name "${EKS_CLUSTER_NAME}" \
    --nodegroup-name "${NODE_GROUP_NAME}"
else
  log "Node group ${NODE_GROUP_NAME} nao encontrado; seguindo"
fi

if cluster_exists; then
  log "Removendo cluster ${EKS_CLUSTER_NAME}"
  aws eks delete-cluster \
    --region "${AWS_REGION}" \
    --name "${EKS_CLUSTER_NAME}" >/dev/null

  log "Aguardando remocao do cluster ${EKS_CLUSTER_NAME}"
  aws eks wait cluster-deleted \
    --region "${AWS_REGION}" \
    --name "${EKS_CLUSTER_NAME}"
else
  log "Cluster ${EKS_CLUSTER_NAME} nao encontrado; nada para remover"
fi

delete_api_gateways
delete_api_gateway_vpc_links
delete_api_gateway_log_group

vpc_ids="$(list_cluster_vpcs)"

if [[ -n "${vpc_ids}" && "${vpc_ids}" != "None" ]]; then
  for vpc_id in ${vpc_ids}; do
    delete_cluster_vpc "${vpc_id}"
  done
else
  log "Nenhuma VPC com tag ${EKS_CLUSTER_NAME}-vpc encontrada; nada para limpar na rede"
fi

log "Cleanup da infraestrutura orfa concluido"
