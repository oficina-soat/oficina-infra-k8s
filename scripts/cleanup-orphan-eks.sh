#!/usr/bin/env bash

set -euo pipefail

AWS_REGION="${AWS_REGION:-}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
NODE_GROUP_NAME="${NODE_GROUP_NAME:-${EKS_CLUSTER_NAME}-ng}"
NETWORK_INTERFACE_WAIT_SECONDS="${NETWORK_INTERFACE_WAIT_SECONDS:-600}"

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

list_cluster_vpcs() {
  aws ec2 describe-vpcs \
    --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=${EKS_CLUSTER_NAME}-vpc" \
    --query 'Vpcs[].VpcId' \
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
      exit 1
    fi

    log "Aguardando liberacao das interfaces de rede da VPC ${vpc_id}: ${interface_ids}"
    sleep 15
  done
}

delete_vpc_subnets() {
  local vpc_id="$1"
  local subnet_ids=""
  subnet_ids="$(aws ec2 describe-subnets \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'Subnets[].SubnetId' \
    --output text)"

  if [[ -z "${subnet_ids}" || "${subnet_ids}" == "None" ]]; then
    return
  fi

  for subnet_id in ${subnet_ids}; do
    log "Removendo subnet ${subnet_id} da VPC ${vpc_id}"
    aws ec2 delete-subnet \
      --region "${AWS_REGION}" \
      --subnet-id "${subnet_id}" >/dev/null
  done
}

delete_vpc_route_tables() {
  local vpc_id="$1"
  local association_ids=""
  local route_table_ids=""

  association_ids="$(aws ec2 describe-route-tables \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'RouteTables[].Associations[?Main!=`true`].RouteTableAssociationId' \
    --output text)"

  for association_id in ${association_ids}; do
    if [[ -n "${association_id}" && "${association_id}" != "None" ]]; then
      log "Desassociando route table association ${association_id} da VPC ${vpc_id}"
      aws ec2 disassociate-route-table \
        --region "${AWS_REGION}" \
        --association-id "${association_id}" >/dev/null
    fi
  done

  route_table_ids="$(aws ec2 describe-route-tables \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'RouteTables[?length(Associations[?Main==`true`])==`0`].RouteTableId' \
    --output text)"

  for route_table_id in ${route_table_ids}; do
    if [[ -n "${route_table_id}" && "${route_table_id}" != "None" ]]; then
      log "Removendo route table ${route_table_id} da VPC ${vpc_id}"
      aws ec2 delete-route-table \
        --region "${AWS_REGION}" \
        --route-table-id "${route_table_id}" >/dev/null
    fi
  done
}

delete_vpc_internet_gateways() {
  local vpc_id="$1"
  local igw_ids=""
  igw_ids="$(aws ec2 describe-internet-gateways \
    --region "${AWS_REGION}" \
    --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --query 'InternetGateways[].InternetGatewayId' \
    --output text)"

  for igw_id in ${igw_ids}; do
    if [[ -n "${igw_id}" && "${igw_id}" != "None" ]]; then
      log "Desanexando internet gateway ${igw_id} da VPC ${vpc_id}"
      aws ec2 detach-internet-gateway \
        --region "${AWS_REGION}" \
        --internet-gateway-id "${igw_id}" \
        --vpc-id "${vpc_id}" >/dev/null

      log "Removendo internet gateway ${igw_id}"
      aws ec2 delete-internet-gateway \
        --region "${AWS_REGION}" \
        --internet-gateway-id "${igw_id}" >/dev/null
    fi
  done
}

delete_vpc_security_groups() {
  local vpc_id="$1"
  local security_group_ids=""
  security_group_ids="$(aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text)"

  for security_group_id in ${security_group_ids}; do
    if [[ -n "${security_group_id}" && "${security_group_id}" != "None" ]]; then
      log "Removendo security group ${security_group_id} da VPC ${vpc_id}"
      aws ec2 delete-security-group \
        --region "${AWS_REGION}" \
        --group-id "${security_group_id}" >/dev/null
    fi
  done
}

delete_cluster_vpc() {
  local vpc_id="$1"

  log "Limpando recursos orfaos da VPC ${vpc_id}"
  wait_for_vpc_network_release "${vpc_id}"
  delete_vpc_subnets "${vpc_id}"
  delete_vpc_route_tables "${vpc_id}"
  delete_vpc_internet_gateways "${vpc_id}"
  delete_vpc_security_groups "${vpc_id}"

  log "Removendo VPC ${vpc_id}"
  aws ec2 delete-vpc \
    --region "${AWS_REGION}" \
    --vpc-id "${vpc_id}" >/dev/null
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

vpc_ids="$(list_cluster_vpcs)"

if [[ -n "${vpc_ids}" && "${vpc_ids}" != "None" ]]; then
  for vpc_id in ${vpc_ids}; do
    delete_cluster_vpc "${vpc_id}"
  done
else
  log "Nenhuma VPC com tag ${EKS_CLUSTER_NAME}-vpc encontrada; nada para limpar na rede"
fi

log "Cleanup da infraestrutura orfa concluido"
