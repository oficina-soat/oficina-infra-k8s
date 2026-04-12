#!/usr/bin/env bash

set -euo pipefail

AWS_REGION="${AWS_REGION:-}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
NODE_GROUP_NAME="${NODE_GROUP_NAME:-${EKS_CLUSTER_NAME}-ng}"

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

log "Cleanup do EKS concluido"
