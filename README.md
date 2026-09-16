# infra — Plataforma FIAP X

Repositório de plataforma do Hackathon FIAP X (Sistema de Processamento de Vídeos).
Sobe um cluster **kind** local com a infra de apoio, os três serviços, Ingress,
HPA e observabilidade — ou tudo via **docker compose**, se você não quiser Kubernetes.

Trilha PLT (Plataforma): **PLT-1, PLT-2, PLT-3, PLT-4, PLT-5 e PLT-7 entregues.**
Pendentes: PLT-6 (CD/GHCR), PLT-8 (notificação por e-mail), PLT-9 (script do banco,
mora em `docs/database/schema.sql`), PLT-10 (carga com k6).

---

## Pré-requisitos

| Ferramenta | Uso |
|---|---|
| Docker (Engine ou Desktop com integração WSL ativada) | build das imagens, runtime do kind |
| [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) ≥ 0.23 | cluster Kubernetes local |
| [`kubectl`](https://kubernetes.io/docs/tasks/tools/) ≥ 1.29 | aplicar manifests (`apply -k` já embute o Kustomize) |
| `make` (opcional) | atalhos; os scripts em `scripts/` funcionam sem ele |

Não precisa de `helm` nem de `kustomize` avulso.

---

## Subir tudo (kind) — um comando

```bash
cd infra
make env            # cria .env e gera o par RSA dos JWT
$EDITOR .env        # troque os CHANGE_ME restantes (senhas e PASSWORD_PEPPER)
make up             # cluster + addons + imagens + infra + serviços + observabilidade + ingress
make verify         # checa os critérios de aceite
make demo           # abre os port-forwards e imprime as URLs
```

`make up` leva ~10 min numa máquina limpa (a maior parte é o build das imagens Java).

Sem `make`, na mesma ordem:

```bash
cp .env.example .env && ./scripts/gen-jwt-keys.sh   # e preencha as senhas
./scripts/kind-up.sh
./scripts/deploy-addons.sh        # Ingress NGINX + metrics-server
./scripts/build-images.sh && ./scripts/load-images.sh
./scripts/deploy-infra.sh
./scripts/deploy-apps.sh
./scripts/deploy-observability.sh
./scripts/deploy-ingress.sh
./scripts/verify.sh
```

Derrubar: `make down` (apaga o cluster e os volumes).

## Subir tudo (docker compose) — sem Kubernetes

```bash
cd infra
make env && $EDITOR .env
make compose-up
```

Caminho mais leve para desenvolver. Não tem Ingress nem HPA — para a demo de
escalabilidade use o kind.

---

## O que sobe

Namespace único: **`fiapx`**. DNS interno: `<serviço>.fiapx.svc.cluster.local`.

### Infra de apoio (PLT-2) — `k8s/infra/`

| Componente | Workload | Persistência | Portas |
|---|---|---|---|
| PostgreSQL 16 | StatefulSet | PVC 1Gi | 5432 — bancos `authdb`, `videodb` |
| RabbitMQ 3.13 | StatefulSet | PVC 1Gi | 5672 (amqp), 15672 (mgmt), 15692 (métricas) |
| MinIO | StatefulSet | PVC 2Gi | 9000 (api), 9001 (console) — bucket `fiapx` (prefixos `inputs/`, `outputs/`) |
| Redis 7 | StatefulSet | PVC 512Mi (AOF) | 6379 |
| Mailhog | Deployment | — | 1025 (smtp), 8025 (ui) |

**Persistência**: `StatefulSet` + `volumeClaimTemplates` sobre a StorageClass
`standard` do kind. O PVC é retido quando o pod morre — `kubectl delete pod
postgres-0` **não perde dado** (checado por `make verify`).
Ressalva: `make down` / `kind delete cluster` apagam os volumes.

### Serviços (PLT-1) — `k8s/apps/`

`Deployment` + `Service` (ClusterIP) + `ConfigMap` + `envFrom` do Secret
`app-credentials`, para `auth-service` (8080), `video-service` (8081) e
`video-processor` (8082). As chaves de ambiente seguem os `application.yml` de
cada serviço (`DB_*`, `REDIS_*`, `STORAGE_*`…) — não as `SPRING_*` padrão.

Pods rodam como não-root com UID/GID numéricos (`10001`): as imagens declaram
`USER` por nome e, sem UID numérico, o kubelet recusa o pod com `runAsNonRoot`.
Só o `video-processor` fica como root, porque ainda usa o Dockerfile de dev —
sai da exceção quando a WRK-9 entregar a imagem dele.

`build-images.sh` usa o `Dockerfile.prod` do serviço quando existe (hoje, o
auth-service — AUTH-8) e o `Dockerfile` padrão nos demais.

#### auth-service

| O que | De onde vem |
|---|---|
| `POST /auth/register`, `POST /auth/login` | Ingress em `/auth` |
| `GET /.well-known/jwks.json` | Ingress (chave pública — permite validar o token no jwt.io) |
| Assinatura RS256 | `JWT_PRIVATE_KEY` / `JWT_PUBLIC_KEY`, gerados por `./scripts/gen-jwt-keys.sh` |
| Hash de senha (Argon2id + pepper) | `PASSWORD_PEPPER` |
| Rate limit do login (10/min por IP) | Redis do cluster (`REDIS_HOST`) |

Sem `PASSWORD_PEPPER` e sem o par RSA o serviço **não inicia** (fail-fast
intencional da trilha A). O `video-service` valida os tokens offline pela
JWKS interna (`http://auth-service.fiapx.svc.cluster.local:8080/.well-known/jwks.json`).

O rate limit identifica o cliente pelo `X-Forwarded-For`. O ingress-nginx, no
default (`use-forwarded-headers: false`), reescreve esse header com o IP real
da conexão — então não dá para forjar IP pelo Ingress. Não habilite
`use-forwarded-headers` sem um proxy confiável na frente.

### Ingress e escala (PLT-3) — `k8s/ingress/`

- **Ingress NGINX** roteando `http://localhost/auth` → auth-service e
  `http://localhost/videos` → video-service (`proxy-body-size: 5g` para os uploads).
- **HPA** do `video-processor`: **2 a 10 réplicas, alvo de 70% de CPU**, com
  `scaleUp` agressivo e `scaleDown` conservador (300s de estabilização).
- `video-service` com **2 réplicas**.
- `metrics-server` instalado com `--kubelet-insecure-tls` (obrigatório no kind;
  sem isso o HPA fica em `<unknown>` e nunca escala).

Ver a escalada ao vivo: `make hpa` — e `make top` para o consumo.

### Observabilidade (PLT-7) — `k8s/observability/`

- **Prometheus** com service discovery por annotation (`prometheus.io/scrape`):
  pega os 3 serviços em `/actuator/prometheus` e o RabbitMQ em `:15692`. Como é
  SD, réplicas novas criadas pelo HPA entram sozinhas no scrape.
- **Grafana** com datasource e dashboard provisionados. Painel
  **FIAP X — Visão Geral** (`k8s/observability/base/grafana/dashboard-fiapx.json`,
  versionado): profundidade da fila, réplicas ativas, vídeos processados,
  latência p95, falhas por código, duração do processamento, heap e CPU.

> Os painéis de `videos_processed_total`, `videos_failed_total` e
> `video_processing_seconds` ficam vazios até a **WRK-8** instrumentar o worker.

---

## Acesso

Com o Ingress (PLT-3):

```bash
curl -X POST http://localhost/auth/register -H 'Content-Type: application/json' \
  -d '{"name":"Alice","email":"alice@fiapx.local","password":"senha-forte-123"}'

TOKEN=$(curl -s -X POST http://localhost/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"alice@fiapx.local","password":"senha-forte-123"}' | sed 's/.*"token":"\([^"]*\)".*/\1/')

curl http://localhost/videos -H "Authorization: Bearer $TOKEN"
curl http://localhost/.well-known/jwks.json
```

`make verify` roda esse fluxo automaticamente (register, 409 no duplicado, login,
`iss`/`alg` do token, 401 com senha errada, token aceito pelo video-service,
401 sem token e 429 no rate limit).

O resto via `make demo`, que abre os port-forwards:

| Serviço | URL |
|---|---|
| auth-service / video-service / video-processor | `localhost:8080` / `8081` / `8082` |
| Grafana | http://localhost:3000 (admin / `GRAFANA_ADMIN_PASSWORD`) |
| Prometheus | http://localhost:9090 |
| RabbitMQ | http://localhost:15672 |
| MinIO console | http://localhost:9001 |
| Mailhog | http://localhost:8025 |

---

## Segredos

Nenhum segredo em texto plano no repositório — ver [`docs/secrets.md`](docs/secrets.md).
Só `.env.example` (com `CHANGE_ME`) é versionado; o `.env` real é git-ignored; o
Kustomize `secretGenerator` materializa os `Secret` apenas dentro do cluster.

## CI (PLT-5)

`.github/workflows/ci.yml` roda a cada PR: `kustomize build` dos 4 overlays,
validação contra os schemas do Kubernetes (`kubeconform -strict`), `shellcheck`
nos scripts, estrutura do `docker-compose.yml`, JSON do dashboard, e falha se
algum `.env` tiver sido versionado.

Rodar as mesmas checagens localmente: `make validate`.

---

## Estrutura

```
infra/
├── Makefile                        # atalhos (make help)
├── docker-compose.yml              # ambiente completo sem Kubernetes (PLT-4)
├── kind/kind-config.yaml           # 1 control-plane + 2 workers, portas 80/443
├── scripts/                        # bash puro, sem dependência de make
├── k8s/
│   ├── namespace.yaml
│   ├── infra/{base,overlays/local}          # PLT-2
│   ├── apps/{base,overlays/local}           # PLT-1 + HPA (PLT-3)
│   ├── ingress/{base,overlays/local}        # PLT-3
│   └── observability/{base,overlays/local}  # PLT-7
├── .env.example                    # template de segredos (CHANGE_ME)
└── docs/secrets.md
```
