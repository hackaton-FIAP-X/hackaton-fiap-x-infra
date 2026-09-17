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
git -C infra grep -nE 'MII[A-Za-z0-9+/]{40}' -- ':!*.example' || echo 'ok: nenhuma chave RSA versionada'
git -C infra grep -nEi 'password|secret|accesskey|pepper' -- ':!*.example' ':!docs/*'
# .env não aparece no status
git -C infra status --porcelain | grep -E '\.env$' || echo "ok: nenhum .env rastreado"
```

## Chaves

| Secret | Consumido por | Chaves |
|---|---|---|
| `infra-credentials` | Postgres, RabbitMQ, MinIO, Redis, Grafana | `POSTGRES_USER/PASSWORD`, `RABBITMQ_DEFAULT_USER/PASS`, `MINIO_ROOT_USER/PASSWORD`, `REDIS_PASSWORD`, `GRAFANA_ADMIN_PASSWORD` |
| `app-credentials` | os 3 serviços (`envFrom`) | `DB_USER/PASSWORD`, `RABBITMQ_USER/PASSWORD/PASS`, `STORAGE_ACCESS_KEY/SECRET_KEY`, `SPRING_DATA_REDIS_PASSWORD`, `PASSWORD_PEPPER`, `JWT_PRIVATE_KEY`, `JWT_PUBLIC_KEY` |

> Os dois `.env` saem do mesmo arquivo, então os valores de app **casam** com os da infra.
> Use `./scripts/gen-env.sh` (ou `make env`): ele gera senhas aleatórias já
> consistentes entre os pares (`POSTGRES_PASSWORD` = `DB_PASSWORD`, etc.).
>
> O `app-credentials` é gerado com hash no nome (`app-credentials-<hash>`): mudar
> um segredo e rodar `deploy-apps.sh` faz os pods rolarem sozinhos.
> Chaves a mais num Secret são apenas variáveis de ambiente não usadas — inofensivas.

### Chaves JWT do auth-service

Par RSA 2048 que assina os tokens (AUTH-3) e é publicado na JWKS (AUTH-4).
O `JwtKeyConfig` exige **Base64 de DER em uma linha** — PKCS8 na privada, X509 na
pública. PEM multi-linha não funciona.

```bash
./scripts/gen-jwt-keys.sh           # gera no infra/.env se ainda houver CHANGE_ME
./scripts/gen-jwt-keys.sh --force   # troca o par (tokens emitidos deixam de validar)
```

O script grava o `.env` com permissão `600`. A chave privada nunca sai do
Secret `app-credentials`; o `video-service` só enxerga a pública, pela JWKS.

## Próximo passo (se sobrar tempo)

Trocar o `.env` git-ignored por **Sealed Secrets** (controller Bitnami): o
`SealedSecret` é cifrado e pode ser versionado com segurança, e o CD (PLT-6)
não precisa de um `.env` fora do git.
