#!/usr/bin/env bash
# Funcoes comuns de aws-up.sh e aws-down.sh. Nao executa nada sozinho.
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TF_DIR="${INFRA_DIR}/terraform/aws"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-fiapx}"

require_aws_session() {
  aws sts get-caller-identity >/dev/null 2>&1 || die "sem credenciais AWS validas. \
Local: exporte AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY e AWS_SESSION_TOKEN da sessao do \
Learner Lab (AWS Details -> AWS CLI). CD: atualize os secrets com esses nomes no repo infra \
— as credenciais do lab expiram a cada sessao."
}

# Bucket do estado com nome FIXO por conta e regiao: qualquer maquina (ou o runner
# do CD, que nao guarda nada entre execucoes) chega sempre ao mesmo estado.
state_bucket() {
  echo "fiapx-tfstate-$(aws sts get-caller-identity --query Account --output text)-${AWS_DEFAULT_REGION}"
}

ensure_state_bucket() {
  local bucket
  bucket="$(state_bucket)"
  if aws s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1; then
    return 0
  fi
  log "criando o bucket do estado ${bucket}"
  create_bucket "${bucket}"
  aws s3api put-bucket-versioning --bucket "${bucket}" --versioning-configuration Status=Enabled
}

tf_init() {
  terraform -chdir="${TF_DIR}" init -input=false -reconfigure \
    -backend-config="bucket=$(state_bucket)" \
    -backend-config="region=${AWS_DEFAULT_REGION}" >/dev/null
}

cluster_exists() {
  aws eks describe-cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1
}

tf_out() { terraform -chdir="${TF_DIR}" output -raw "$1"; }

# Bucket da aplicacao (videos em fiapx/inputs/, ZIPs em fiapx/outputs/). Criado
# pela CLI, e nao pelo Terraform: o aws_s3_bucket do provider sempre le a config
# de object lock, e o SCP do Learner Lab nega s3:GetBucketObjectLockConfiguration.
app_bucket() {
  echo "fiapx-app-$(aws sts get-caller-identity --query Account --output text)-${AWS_DEFAULT_REGION}"
}

create_bucket() {
  if [[ "${AWS_DEFAULT_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$1" >/dev/null
  else
    aws s3api create-bucket --bucket "$1" \
      --create-bucket-configuration "LocationConstraint=${AWS_DEFAULT_REGION}" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "$1" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "$1" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
}

ensure_app_bucket() {
  local bucket
  bucket="$(app_bucket)"
  aws s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1 && return 0
  log "criando o bucket da aplicacao ${bucket}"
  create_bucket "${bucket}"
  # Videos originais nao precisam ficar para sempre num ambiente de demo. Nao e
  # essencial: se o lab negar, segue sem a regra.
  aws s3api put-bucket-lifecycle-configuration --bucket "${bucket}" --lifecycle-configuration \
    '{"Rules":[{"ID":"expira-videos-originais","Status":"Enabled","Filter":{"Prefix":"fiapx/inputs/"},"Expiration":{"Days":7}}]}' \
    || warn "sem lifecycle no bucket ${bucket} (negado pelo lab); os videos nao expiram sozinhos"
}

delete_app_bucket() {
  local bucket
  bucket="$(app_bucket)"
  aws s3api head-bucket --bucket "${bucket}" >/dev/null 2>&1 || return 0
  log "apagando o bucket da aplicacao ${bucket}"
  aws s3 rb "s3://${bucket}" --force >/dev/null
}

# Estados criados antes da troca (Amazon MQ + bucket no Terraform) ainda tem o
# aws_s3_bucket.app: qualquer plan/destroy o releria e bateria no SCP. Tira do
# estado e apaga o bucket antigo pela CLI. Idempotente: sem ele, nao faz nada.
migrate_legacy_state() {
  local legacy old
  legacy="$(terraform -chdir="${TF_DIR}" state list 2>/dev/null \
    | grep -E '^(aws_s3_bucket(_[a-z_]+)?\.app|random_id\.bucket_suffix)$' || true)"
  [[ -n "${legacy}" ]] || return 0
  old="$(terraform -chdir="${TF_DIR}" state pull | python3 -c '
import json, sys
for r in json.load(sys.stdin).get("resources", []):
    if r["type"] == "aws_s3_bucket" and r["name"] == "app":
        for i in r["instances"]:
            print(i["attributes"]["id"])')"
  log "migrando o estado: removendo o bucket antigo do Terraform (${old:-sem id})"
  xargs -d '\n' terraform -chdir="${TF_DIR}" state rm >/dev/null <<<"${legacy}"
  if [[ -n "${old}" ]] && aws s3api head-bucket --bucket "${old}" >/dev/null 2>&1; then
    aws s3 rb "s3://${old}" --force >/dev/null || warn "nao consegui apagar ${old}; apague pelo console do S3"
  fi
}
