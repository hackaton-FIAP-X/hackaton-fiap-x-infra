#!/usr/bin/env bash
# Sobe o FIAP X inteiro na AWS (Learner Lab): Terraform -> imagens no ECR ->
# deploy no EKS -> verify. Pensado para a demo: suba, grave, rode aws-down.sh.
#
# Pre-requisitos: credenciais da sessao do Learner Lab exportadas (AWS Details ->
# AWS CLI: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN),
# terraform >= 1.10, aws cli, kubectl, docker, e infra/.env (./scripts/gen-env.sh).
#
# Uso: ./scripts/aws-up.sh              # tudo
#      SKIP_TERRAFORM=1 ./scripts/aws-up.sh   # so imagens + deploy (infra ja existe)
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require terraform aws kubectl docker python3 curl

TF_DIR="${INFRA_DIR}/terraform/aws"
BOOT_DIR="${INFRA_DIR}/terraform/bootstrap"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

aws sts get-caller-identity >/dev/null 2>&1 \
  || die "sem credenciais AWS validas. Exporte as da sessao do Learner Lab (AWS Details -> AWS CLI)."
[[ -f "${INFRA_DIR}/.env" ]] || "${INFRA_DIR}/scripts/gen-env.sh"

# ---------------------------------------------------------------- terraform --
if [[ "${SKIP_TERRAFORM:-0}" != "1" ]]; then
  if [[ ! -f "${TF_DIR}/backend.hcl" ]]; then
    log "primeira vez: criando o bucket do estado (terraform/bootstrap)"
    terraform -chdir="${BOOT_DIR}" init -input=false >/dev/null
    terraform -chdir="${BOOT_DIR}" apply -input=false -auto-approve -var "region=${AWS_DEFAULT_REGION}"
    printf 'bucket = "%s"\nregion = "%s"\n' \
      "$(terraform -chdir="${BOOT_DIR}" output -raw state_bucket)" "${AWS_DEFAULT_REGION}" > "${TF_DIR}/backend.hcl"
  fi
  log "terraform apply (15-25 min na primeira vez: EKS, RDS e Amazon MQ demoram)"
  terraform -chdir="${TF_DIR}" init -input=false -backend-config=backend.hcl >/dev/null
  terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -var "region=${AWS_DEFAULT_REGION}"
fi

tf_out() { terraform -chdir="${TF_DIR}" output -raw "$1"; }
CLUSTER_NAME="$(tf_out cluster_name)"
ECR="$(tf_out ecr_registry)"

log "kubeconfig do EKS"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=600s

# ------------------------------------------------------------------ imagens --
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${INFRA_DIR}" rev-parse --short=12 HEAD)-$(date +%s)}"
log "build e push das imagens para o ECR (tag ${IMAGE_TAG})"
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR}" >/dev/null
"${INFRA_DIR}/scripts/build-images.sh"
IMAGE_REGISTRY="${ECR}/fiapx" "${INFRA_DIR}/scripts/push-images.sh" "${IMAGE_TAG}"

# ------------------------------------------------------------------- deploy --
IMAGE_TAG="${IMAGE_TAG}" "${INFRA_DIR}/scripts/aws-render.sh"
PROVIDER=aws "${INFRA_DIR}/scripts/deploy-addons.sh"

kubectl apply -f "${INFRA_DIR}/k8s/namespace.yaml"
kubectl -n "${NAMESPACE}" delete job create-videodb --ignore-not-found >/dev/null
kubectl apply -k "${INFRA_DIR}/k8s/infra/overlays/aws"
kubectl apply -k "${INFRA_DIR}/k8s/apps/overlays/aws"
log "aguardando o videodb no RDS e os servicos..."
kubectl -n "${NAMESPACE}" wait --for=condition=complete job/create-videodb --timeout=300s
for svc in "${SERVICES[@]}"; do
  kubectl -n "${NAMESPACE}" rollout status "deployment/${svc}" --timeout=600s
done
"${INFRA_DIR}/scripts/deploy-observability.sh"

log "aguardando o NLB do Ingress ganhar endereco..."
LB=""
for _ in $(seq 1 60); do
  LB="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "${LB}" ]] && break
  sleep 10
done
[[ -n "${LB}" ]] || die "o NLB nao recebeu endereco"
export BASE_URL="http://${LB}"
# DNS do NLB leva alguns minutos para propagar: o deploy-ingress espera a rota responder
INGRESS_TIMEOUT_S=600 "${INFRA_DIR}/scripts/deploy-ingress.sh"

VERIFY_TARGET=aws BASE_URL="${BASE_URL}" "${INFRA_DIR}/scripts/verify.sh"
log "no ar: ${BASE_URL}  (derrube com ./scripts/aws-down.sh)"
