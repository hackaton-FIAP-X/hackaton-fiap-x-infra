# Estratégia de segredos

Critério de aceite da PLT-1: **nenhum segredo em texto plano no repositório**.

## Como funciona

1. **Versionado**: apenas `infra/.env.example`, com todas as chaves e valor `CHANGE_ME`.
2. **Git-ignored** (`infra/.gitignore`): `.env`, `*.local.env`, `k8s/**/overlays/*/.env`.
3. Você preenche **uma vez** `infra/.env` (cópia de `.env.example`).
4. Os scripts (`ensure_env` em `scripts/lib.sh`) copiam esse `.env` para
   `k8s/infra/overlays/local/.env` e `k8s/apps/overlays/local/.env` — ambos
   git-ignored, com valores idênticos.
5. O **Kustomize `secretGenerator`** lê esses `.env` e cria os `Secret`
   (`infra-credentials`, `app-credentials`) **somente no cluster**, no
   `kubectl apply -k`. Nada de Secret em YAML no repo.

## Verificação

```bash
# nenhum valor real rastreado pelo git
git -C infra grep -nEi 'password|secret|accesskey|jwt_secret' -- ':!*.example' ':!docs/*'
# .env não aparece no status
git -C infra status --porcelain | grep -E '\.env$' || echo "ok: nenhum .env rastreado"
```

## Chaves

| Secret | Consumido por | Chaves |
|---|---|---|
| `infra-credentials` | Postgres, RabbitMQ, MinIO, Redis (namespace `fiapx`) | `POSTGRES_USER/PASSWORD`, `RABBITMQ_DEFAULT_USER/PASS`, `MINIO_ROOT_USER/PASSWORD`, `REDIS_PASSWORD` |
| `app-credentials` | auth-service, video-service, video-processor (`envFrom`) | `SPRING_DATASOURCE_USERNAME/PASSWORD`, `SPRING_RABBITMQ_USERNAME/PASSWORD`, `RABBITMQ_USER/PASS`, `MINIO_ACCESS_KEY/SECRET_KEY`, `SPRING_DATA_REDIS_PASSWORD`, `JWT_SECRET` |

> Os dois `.env` saem do mesmo arquivo, então os valores de app **casam** com os da infra.
> Chaves a mais num Secret são apenas variáveis de ambiente não usadas — inofensivas.

## Próximo passo (se sobrar tempo)

Trocar o `.env` git-ignored por **Sealed Secrets** (controller Bitnami): o
`SealedSecret` é cifrado e pode ser versionado com segurança, e o CD (PLT-6)
não precisa de um `.env` fora do git.
