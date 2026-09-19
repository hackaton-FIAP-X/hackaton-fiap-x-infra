#!/usr/bin/env bash
# Testa o stack terraform/aws inteiro (apply + destroy) contra o Floci, o
# emulador AWS local: sem conta, sem custo e sem gastar sessao do Learner Lab.
#
# Uso: ./scripts/tf-floci.sh            # apply, mostra os outputs e destroy
#      KEEP=1 ./scripts/tf-floci.sh     # nao destroi no fim
#
# O Floci emula a API; ele nao sobe um Kubernetes de verdade nem roda os pods.
# O teste de runtime continua sendo o kind (make up) e, no fim, o EKS real.
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require docker terraform aws curl

FLOCI_URL="${FLOCI_URL:-http://localhost:4566}"
FLOCI_IMAGE="${FLOCI_IMAGE:-floci/floci:2.1.0}"
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1

if ! curl -sf "${FLOCI_URL}/_floci/health" >/dev/null 2>&1; then
  log "subindo o Floci (${FLOCI_IMAGE})"
  docker rm -f floci >/dev/null 2>&1 || true
  docker run -d --name floci -p 4566:4566 \
    -v /var/run/docker.sock:/var/run/docker.sock "${FLOCI_IMAGE}" >/dev/null
  for _ in $(seq 1 30); do curl -sf "${FLOCI_URL}/_floci/health" >/dev/null 2>&1 && break; sleep 1; done
fi
curl -sf "${FLOCI_URL}/_floci/health" >/dev/null || die "Floci nao respondeu em ${FLOCI_URL}"

# O Learner Lab ja traz o LabRole; no Floci ele precisa existir antes do apply.
aws --endpoint-url "${FLOCI_URL}" iam get-role --role-name LabRole >/dev/null 2>&1 \
  || aws --endpoint-url "${FLOCI_URL}" iam create-role --role-name LabRole \
       --assume-role-policy-document '{"Version":"2012-10-17","Statement":[]}' >/dev/null

WORK="$(mktemp -d)"
if [[ "${KEEP:-0}" == "1" ]]; then
  log "KEEP=1: estado fica em ${WORK} (terraform -chdir=${WORK} destroy para limpar)"
else
  trap 'rm -rf "${WORK}"' EXIT
fi
cp "${INFRA_DIR}"/terraform/aws/*.tf "${WORK}/"
cp "${INFRA_DIR}"/terraform/floci/*_override.tf "${WORK}/"
cd "${WORK}"

log "terraform init"
terraform init -input=false -no-color >/dev/null
log "terraform apply (Floci)"
terraform apply -input=false -auto-approve -no-color
log "outputs:"
terraform output -no-color

if [[ "${KEEP:-0}" != "1" ]]; then
  # Limitacao do Floci 2.1: DeleteRepository do ECR responde OK mas nao apaga, e o
  # destroy espera o repositorio sumir para sempre. So no emulador tiramos o ECR
  # do estado; na AWS real o force_delete apaga normalmente.
  terraform state list | grep -E '^aws_ecr_(repository|lifecycle_policy)\.' \
    | xargs -r -d '\n' terraform state rm -no-color >/dev/null
  log "terraform destroy (Floci)"
  terraform destroy -input=false -auto-approve -no-color
  log "apply e destroy completos no Floci."
fi
