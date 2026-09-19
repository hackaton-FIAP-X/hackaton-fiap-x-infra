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
  if [[ "${AWS_DEFAULT_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${bucket}" >/dev/null
  else
    aws s3api create-bucket --bucket "${bucket}" \
      --create-bucket-configuration "LocationConstraint=${AWS_DEFAULT_REGION}" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "${bucket}" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-encryption --bucket "${bucket}" --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
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
