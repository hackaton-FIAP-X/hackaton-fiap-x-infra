#!/usr/bin/env bash
# Sobe (ou atualiza) o FIAP X na AWS: Terraform -> imagens no ECR -> deploy no
# EKS -> verify. Usado igual na maquina de um dev e no CD.
#
# Credenciais: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY e AWS_SESSION_TOKEN da
# sessao do Learner Lab (AWS Details -> AWS CLI). No CD vem dos secrets do repo.
#
# Opcoes (variaveis de ambiente):
#   ONLY_IF_UP=1   nao cria nada: se o cluster nao existe, sai sem erro. E o modo do
#                  deploy automatico a cada merge — o ambiente so nasce pelo botao
#                  "up", para um merge nao ligar o EKS e gastar o credito do lab.
#   SKIP_BUILD=1   nao roda build-images.sh (o CD ja construiu as imagens :local)
#   IMAGE_TAG=...  tag das imagens no ECR (default: SHA do commit + timestamp)
set -euo pipefail
# shellcheck source=./aws-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/aws-lib.sh"

require terraform aws kubectl docker python3 curl
require_aws_session

if [[ "${ONLY_IF_UP:-0}" == "1" ]] && ! cluster_exists; then
  log "ambiente AWS desligado (cluster ${CLUSTER_NAME} nao existe): nada a atualizar."
  log "para criar: Actions -> 'AWS - ambiente' -> acao up (ou ./scripts/aws-up.sh)."
  exit 0
fi

# ---------------------------------------------------------------- terraform --
ensure_state_bucket
tf_init
migrate_legacy_state
ensure_app_bucket
log "terraform apply (15-25 min na primeira vez: EKS e RDS demoram)"
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -var "region=${AWS_DEFAULT_REGION}"

ECR="$(tf_out ecr_registry)"
log "kubeconfig do EKS"
aws eks update-kubeconfig --name "$(tf_out cluster_name)" --region "${AWS_DEFAULT_REGION}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=600s

# ------------------------------------------------------------------ imagens --
IMAGE_TAG="${IMAGE_TAG:-$(git -C "${INFRA_DIR}" rev-parse --short=12 HEAD)-$(date +%s)}"
aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR}" >/dev/null
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  "${INFRA_DIR}/scripts/build-images.sh"
fi
log "push das imagens para o ECR (tag ${IMAGE_TAG})"
IMAGE_REGISTRY="${ECR}/fiapx" "${INFRA_DIR}/scripts/push-images.sh" "${IMAGE_TAG}"

# ------------------------------------------------------------------- deploy --
APP_BUCKET="$(app_bucket)" IMAGE_TAG="${IMAGE_TAG}" "${INFRA_DIR}/scripts/aws-render.sh"
PROVIDER=aws "${INFRA_DIR}/scripts/deploy-addons.sh"

kubectl apply -f "${INFRA_DIR}/k8s/namespace.yaml"
kubectl -n "${NAMESPACE}" delete job create-videodb --ignore-not-found >/dev/null
kubectl apply -k "${INFRA_DIR}/k8s/infra/overlays/aws"
# os servicos declaram a topologia no RabbitMQ ao subir: ele vem antes
log "aguardando o RabbitMQ (volume EBS novo leva ~1 min)..."
kubectl -n "${NAMESPACE}" rollout status statefulset/rabbitmq --timeout=600s
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
log "no ar: ${BASE_URL}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Ambiente AWS no ar"
    echo "- API: ${BASE_URL} (\`/auth\`, \`/videos\`)"
    echo "- Imagens: \`${ECR}/fiapx/*:${IMAGE_TAG}\`"
    echo "- Grafana: \`kubectl -n fiapx port-forward svc/grafana 3000:3000\`"
  } >> "${GITHUB_STEP_SUMMARY}"
fi
