#!/usr/bin/env bash
# Gera os arquivos dos overlays aws a partir do `terraform output` do stack
# terraform/aws: endpoints no ConfigMap, senhas no Secret, imagens do ECR.
#
# Tudo vai para k8s/*/overlays/aws/generated/ (git-ignored: tem senhas).
# Uso: IMAGE_TAG=<tag> ./scripts/aws-render.sh
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
APPS_GEN="${APPS_GEN}" INFRA_GEN="${INFRA_GEN}" INFRA_DIR="${INFRA_DIR}" \
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}" \
python3 - "${OUT}" <<'PY'
import json, os, secrets, sys

out = {k: v["value"] for k, v in json.loads(sys.argv[1]).items()}
apps, infra, tag = os.environ["APPS_GEN"], os.environ["INFRA_GEN"], os.environ["IMAGE_TAG"]
region = out["region"]
s3_endpoint = f"https://s3.{region}.amazonaws.com"
tls = "true" if out.get("mq_tls", True) else "false"

def write(path, text, mode=0o600):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)

def configmap(name, data):
    lines = "".join(f'  {k}: "{v}"\n' for k, v in data.items())
    return f"apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {name}\ndata:\n{lines}"

db = {"DB_HOST": out["db_host"], "DB_PORT": out["db_port"]}
mq = {"RABBITMQ_HOST": out["mq_host"], "RABBITMQ_PORT": out["mq_port"],
      # AMQPS no Amazon MQ. A env do Spring vale para os dois servicos, mesmo o
      # video-service nao declarando ssl no application.yml dele.
      "SPRING_RABBITMQ_SSL_ENABLED": tls, "RABBITMQ_SSL_ENABLED": tls}
redis = {"REDIS_HOST": out["redis_host"], "REDIS_PORT": "6379"}

write(f"{apps}/auth-service.yaml", configmap("auth-service-config", {**db, **redis}))
write(f"{apps}/video-service.yaml", configmap("video-service-config", {
    **db, **mq, **redis,
    "STORAGE_BUCKET": out["bucket"], "STORAGE_REGION": region,
    # o video-service exige endpoint; o regional do S3 atende path-style
    "STORAGE_ENDPOINT": s3_endpoint, "STORAGE_PUBLIC_ENDPOINT": s3_endpoint}))
write(f"{apps}/video-processor.yaml", configmap("video-processor-config", {
    **mq, "STORAGE_BUCKET": out["bucket"], "STORAGE_REGION": region,
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
# do no (cadeia padrao da AWS). Chaves fixas nao funcionam no Learner Lab.
env_app = os.path.join(os.environ.get("INFRA_DIR", ""), ".env")
keys = {}
try:
    with open(env_app) as f:
        keys = dict(l.split("=", 1) for l in f.read().splitlines() if "=" in l and not l.startswith("#"))
except FileNotFoundError:
    pass
pepper = keys.get("PASSWORD_PEPPER") or secrets.token_hex(24)
app_env = {
    "DB_USER": out["db_user"], "DB_PASSWORD": out["db_password"],
    "RABBITMQ_USER": out["mq_user"], "RABBITMQ_PASSWORD": out["mq_password"],
    "RABBITMQ_PASS": out["mq_password"],
    "STORAGE_ACCESS_KEY": "", "STORAGE_SECRET_KEY": "",
    "SPRING_DATA_REDIS_PASSWORD": "",
    "PASSWORD_PEPPER": pepper,
    "JWT_PRIVATE_KEY": keys.get("JWT_PRIVATE_KEY", ""),
    "JWT_PUBLIC_KEY": keys.get("JWT_PUBLIC_KEY", ""),
}
missing = [k for k in ("JWT_PRIVATE_KEY", "JWT_PUBLIC_KEY") if not app_env[k] or app_env[k].startswith("CHANGE_ME")]
if missing:
    sys.exit(f"faltam {missing} em infra/.env — rode ./scripts/gen-env.sh antes")
write(f"{apps}/app.env", "".join(f"{k}={v}\n" for k, v in app_env.items()))

grafana = os.environ.get("GRAFANA_ADMIN_PASSWORD") or keys.get("GRAFANA_ADMIN_PASSWORD") or secrets.token_hex(12)
write(f"{infra}/infra.env", f"GRAFANA_ADMIN_PASSWORD={grafana}\n")
print(f"overlays aws gerados (imagens :{tag}, bucket {out['bucket']})")
PY
