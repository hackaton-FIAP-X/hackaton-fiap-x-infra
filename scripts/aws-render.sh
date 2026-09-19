#!/usr/bin/env bash
# Gera os arquivos dos overlays aws a partir do `terraform output` do stack
# terraform/aws: endpoints no ConfigMap, senhas no Secret, imagens do ECR.
#
# Tudo vai para k8s/*/overlays/aws/generated/ (git-ignored: tem senhas).
# Uso: APP_BUCKET=<bucket> IMAGE_TAG=<tag> ./scripts/aws-render.sh
# (o bucket e criado pela CLI em aws-lib.sh, nao pelo Terraform: ver ensure_app_bucket)
set -euo pipefail
# shellcheck source=./lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require terraform python3

TF_DIR="${TF_DIR:-${INFRA_DIR}/terraform/aws}"
APPS_GEN="${INFRA_DIR}/k8s/apps/overlays/aws/generated"
INFRA_GEN="${INFRA_DIR}/k8s/infra/overlays/aws/generated"
mkdir -p "${APPS_GEN}" "${INFRA_GEN}"

OUT="$(terraform -chdir="${TF_DIR}" output -json)"

IMAGE_TAG="${IMAGE_TAG:?informe IMAGE_TAG (a tag publicada no ECR)}" \
APP_BUCKET="${APP_BUCKET:?informe APP_BUCKET (bucket S3 da aplicacao)}" \
APPS_GEN="${APPS_GEN}" INFRA_GEN="${INFRA_GEN}" INFRA_DIR="${INFRA_DIR}" \
python3 - "${OUT}" <<'PY'
import json, os, sys

out = {k: v["value"] for k, v in json.loads(sys.argv[1]).items()}
apps, infra, tag = os.environ["APPS_GEN"], os.environ["INFRA_GEN"], os.environ["IMAGE_TAG"]
region, bucket = out["region"], os.environ["APP_BUCKET"]
s3_endpoint = f"https://s3.{region}.amazonaws.com"

def write(path, text, mode=0o600):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)

def configmap(name, data):
    lines = "".join(f'  {k}: "{v}"\n' for k, v in data.items())
    return f"apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {name}\ndata:\n{lines}"

db = {"DB_HOST": out["db_host"], "DB_PORT": out["db_port"]}
# RabbitMQ roda no cluster (k8s/infra/overlays/aws): host e porta ja sao os da
# base (rabbitmq.fiapx.svc.cluster.local:5672, sem TLS), nada a sobrescrever.
redis = {"REDIS_HOST": out["redis_host"], "REDIS_PORT": "6379"}

write(f"{apps}/auth-service.yaml", configmap("auth-service-config", {**db, **redis}))
write(f"{apps}/video-service.yaml", configmap("video-service-config", {
    **db, **redis,
    "STORAGE_BUCKET": bucket, "STORAGE_REGION": region,
    # o video-service exige endpoint; o regional do S3 atende path-style
    "STORAGE_ENDPOINT": s3_endpoint, "STORAGE_PUBLIC_ENDPOINT": s3_endpoint}))
write(f"{apps}/video-processor.yaml", configmap("video-processor-config", {
    "STORAGE_BUCKET": bucket, "STORAGE_REGION": region,
    # vazio = S3 padrao da regiao; credenciais pelo LabRole do no
    "STORAGE_ENDPOINT": ""}))

images = "".join(
    f"""---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {svc}
spec:
  template:
    spec:
      containers:
        - name: {svc}
          image: {out['ecr_repositories'][svc]}:{tag}
          imagePullPolicy: IfNotPresent
"""
    for svc in ("auth-service", "video-service", "video-processor"))
write(f"{apps}/images.yaml", images)

# Segredos: credenciais do S3 ficam VAZIAS de proposito — os pods usam o LabRole
# do no (cadeia padrao da AWS). Pepper, chaves do JWT e senha do Grafana vem do
# estado do Terraform (terraform/aws/secrets.tf): estaveis entre deploys e iguais
# para quem rodar, maquina local ou CD.
app_env = {
    "DB_USER": out["db_user"], "DB_PASSWORD": out["db_password"],
    "RABBITMQ_USER": out["mq_user"], "RABBITMQ_PASSWORD": out["mq_password"],
    "RABBITMQ_PASS": out["mq_password"],
    "STORAGE_ACCESS_KEY": "", "STORAGE_SECRET_KEY": "",
    "SPRING_DATA_REDIS_PASSWORD": "",
    "PASSWORD_PEPPER": out["password_pepper"],
    "JWT_PRIVATE_KEY": out["jwt_private_key"],
    "JWT_PUBLIC_KEY": out["jwt_public_key"],
}
write(f"{apps}/app.env", "".join(f"{k}={v}\n" for k, v in app_env.items()))
infra_env = {
    "GRAFANA_ADMIN_PASSWORD": out["grafana_admin_password"],
    # mesmo usuario/senha que os apps recebem acima (RABBITMQ_USER/PASSWORD)
    "RABBITMQ_DEFAULT_USER": out["mq_user"], "RABBITMQ_DEFAULT_PASS": out["mq_password"],
}
write(f"{infra}/infra.env", "".join(f"{k}={v}\n" for k, v in infra_env.items()))
print(f"overlays aws gerados (imagens :{tag}, bucket {bucket})")
PY
