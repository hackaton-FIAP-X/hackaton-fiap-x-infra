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
make env            # cria .env a partir do template
$EDITOR .env        # troque todos os CHANGE_ME
make up             # cluster + addons + imagens + infra + serviços + observabilidade + ingress
make verify         # checa os critérios de aceite
make demo           # abre os port-forwards e imprime as URLs
```

`make up` leva ~10 min numa máquina limpa (a maior parte é o build das imagens Java).

Sem `make`, na mesma ordem:

```bash
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
| MinIO | StatefulSet | PVC 2Gi | 9000 (api), 9001 (console) — buckets `fiapx-videos`, `fiapx-outputs` |
| Redis 7 | StatefulSet | PVC 512Mi (AOF) | 6379 |
| Mailhog | Deployment | — | 1025 (smtp), 8025 (ui) |

**Persistência**: `StatefulSet` + `volumeClaimTemplates` sobre a StorageClass
`standard` do kind. O PVC é retido quando o pod morre — `kubectl delete pod
postgres-0` **não perde dado** (checado por `make verify`).
Ressalva: `make down` / `kind delete cluster` apagam os volumes.

### Serviços (PLT-1) — `k8s/apps/`

`Deployment` + `Service` (ClusterIP) + `ConfigMap` + `envFrom` do Secret
`app-credentials`, para `auth-service` (8080), `video-service` (8081) e
`video-processor` (8082). Probes de liveness/readiness/startup em
`/actuator/health`; a `startupProbe` é folgada porque a imagem de dev compila
no start.

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

```
http://localhost/auth/actuator/health
http://localhost/videos/actuator/health
```

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
