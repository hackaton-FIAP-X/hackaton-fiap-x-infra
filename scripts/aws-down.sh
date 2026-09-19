#!/usr/bin/env bash
# Derruba tudo da AWS. Primeiro remove o que o Kubernetes criou fora do
# Terraform (o NLB do Ingress): se ele ficar, a VPC nao consegue ser apagada e o
# destroy trava ate o timeout.
#
# Uso: ./scripts/aws-down.sh           # destroi o stack terraform/aws
#      ALL=1 ./scripts/aws-down.sh     # tambem o bucket do estado (bootstrap)
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require terraform aws kubectl

TF_DIR="${INFRA_DIR}/terraform/aws"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
aws sts get-caller-identity >/dev/null 2>&1 || die "sem credenciais AWS validas."

CLUSTER_NAME="$(terraform -chdir="${TF_DIR}" output -raw cluster_name 2>/dev/null || true)"
if [[ -n "${CLUSTER_NAME}" ]] && aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" >/dev/null
  log "removendo o Ingress NGINX (e o NLB que ele criou)"
  kubectl delete namespace ingress-nginx --ignore-not-found --wait=true --timeout=300s || true
  for _ in $(seq 1 30); do
    remaining="$(aws elbv2 describe-load-balancers --query \
      "length(LoadBalancers[?VpcId=='$(terraform -chdir="${TF_DIR}" output -raw vpc_id 2>/dev/null)'])" \
      --output text 2>/dev/null || echo 0)"
    [[ "${remaining}" == "0" || "${remaining}" == "None" ]] && break
    log "aguardando ${remaining} load balancer(s) sair(em)..."
    sleep 10
  done
fi

log "terraform destroy"
terraform -chdir="${TF_DIR}" destroy -input=false -auto-approve -var "region=${AWS_DEFAULT_REGION}"

if [[ "${ALL:-0}" == "1" ]]; then
  log "removendo o bucket do estado"
  terraform -chdir="${INFRA_DIR}/terraform/bootstrap" destroy -input=false -auto-approve
  rm -f "${TF_DIR}/backend.hcl"
fi
rm -rf "${INFRA_DIR}/k8s/apps/overlays/aws/generated" "${INFRA_DIR}/k8s/infra/overlays/aws/generated"
log "AWS limpa."
