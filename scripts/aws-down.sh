#!/usr/bin/env bash
# Derruba tudo da AWS. Primeiro remove o que o Kubernetes criou fora do
# Terraform (o NLB do Ingress): se ele ficar, a VPC nao consegue ser apagada e o
# destroy trava ate o timeout.
#
# Uso: ./scripts/aws-down.sh           # destroi o ambiente (o bucket do estado fica)
#      ALL=1 ./scripts/aws-down.sh     # tambem apaga o bucket do estado
set -euo pipefail
# shellcheck source=./aws-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/aws-lib.sh"

require terraform aws kubectl
require_aws_session

BUCKET="$(state_bucket)"
if ! aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then
  log "bucket do estado ${BUCKET} nao existe: nada a destruir."
  exit 0
fi
tf_init

if cluster_exists; then
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null
  log "removendo o Ingress NGINX (e o NLB que ele criou)"
  kubectl delete namespace ingress-nginx --ignore-not-found --wait=true --timeout=300s || true
  VPC_ID="$(tf_out vpc_id 2>/dev/null || true)"
  for _ in $(seq 1 30); do
    remaining="$(aws elbv2 describe-load-balancers \
      --query "length(LoadBalancers[?VpcId=='${VPC_ID}'])" --output text 2>/dev/null || echo 0)"
    [[ "${remaining}" == "0" || "${remaining}" == "None" ]] && break
    log "aguardando ${remaining} load balancer(s) sair(em)..."
    sleep 10
  done
fi

log "terraform destroy"
terraform -chdir="${TF_DIR}" destroy -input=false -auto-approve -var "region=${AWS_DEFAULT_REGION}"

if [[ "${ALL:-0}" == "1" ]]; then
  log "apagando o bucket do estado ${BUCKET} (todas as versoes)"
  while :; do
    batch="$(aws s3api list-object-versions --bucket "${BUCKET}" --max-items 500 --output json \
      --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][] }')"
    [[ "$(echo "${batch}" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("Objects") or []))')" == "0" ]] && break
    aws s3api delete-objects --bucket "${BUCKET}" --delete "${batch}" >/dev/null
  done
  aws s3api delete-bucket --bucket "${BUCKET}"
fi
rm -rf "${INFRA_DIR}/k8s/apps/overlays/aws/generated" "${INFRA_DIR}/k8s/infra/overlays/aws/generated"
log "AWS limpa."
