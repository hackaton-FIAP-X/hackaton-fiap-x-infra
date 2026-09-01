# infra — Plataforma FIAP X

Repositório de plataforma do Hackathon FIAP X (Sistema de Processamento de Vídeos).
Sobe um cluster **kind** local com a infra de apoio e os três serviços.

Cobre as tarefas **PLT-1** (manifests Kubernetes dos serviços) e **PLT-2**
(infra de apoio no cluster com persistência) da trilha Plataforma.

> Ingress + HPA (PLT-3), CI (PLT-5), CD/GHCR (PLT-6), Prometheus/Grafana (PLT-7),
> k6 (PLT-10) e o `docker-compose` completo (PLT-4) entram nas próximas levas.

---

## Pré-requisitos

| Ferramenta | Uso |
|---|---|
| Docker (Engine ou Desktop com integração WSL ativada) | build das imagens, runtime do kind |
| [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) ≥ 0.23 | cluster Kubernetes local |
| [`kubectl`](https://kubernetes.io/docs/tasks/tools/) ≥ 1.29 | aplicar manifests (`apply -k` já embute o Kustomize) |
| `bash` | scripts em `scripts/` |

Não precisa de `make`, `helm` nem `kustomize` avulso.

---

## Subir tudo

```bash
cd infra

# 1. Segredos: preencha uma vez (nada disso vai pro git)
cp .env.example .env
$EDITOR .env                       # troque todos os CHANGE_ME

# 2. Cluster
./scripts/kind-up.sh

# 3. Imagens dos serviços (a partir dos Dockerfiles de cada repo) -> para dentro do kind
./scripts/build-images.sh
./scripts/load-images.sh

# 4. Infra de apoio (PLT-2) e serviços (PLT-1)
./scripts/deploy-infra.sh
./scripts/deploy-apps.sh

# 5. Conferir os critérios de aceite
./scripts/verify.sh
```

Derrubar: `./scripts/down.sh` (apaga o cluster e os volumes).

---

## O que sobe

Namespace único: **`fiapx`**. DNS interno: `<serviço>.fiapx.svc.cluster.local`.

### Infra de apoio (PLT-2) — `k8s/infra/`

| Componente | Workload | Persistência | Portas (ClusterIP) |
|---|---|---|---|
| PostgreSQL 16 | StatefulSet | PVC 1Gi (`standard`) | 5432 — bancos `authdb`, `videodb` |
| RabbitMQ 3.13 | StatefulSet | PVC 1Gi | 5672 (amqp), 15672 (management) |
| MinIO | StatefulSet | PVC 2Gi | 9000 (api), 9001 (console) — buckets `fiapx-videos`, `fiapx-outputs` |
| Redis 7 | StatefulSet | PVC 512Mi (AOF) | 6379 |
| Mailhog | Deployment | — (efêmero) | 1025 (smtp), 8025 (ui) |

**Persistência**: `StatefulSet` + `volumeClaimTemplates`. O kind traz a StorageClass
`standard` (local-path). O PVC é retido quando o pod morre — `kubectl delete pod
postgres-0` **não perde dado** (checado em `scripts/verify.sh`).
Ressalva: `./scripts/down.sh` / `kind delete cluster` apagam os volumes. Para o
hackathon isso é aceitável.

### Serviços (PLT-1) — `k8s/apps/`

Para cada um de `auth-service` (8080), `video-service` (8081), `video-processor` (8082):
`Deployment` + `Service` (ClusterIP) + `ConfigMap` (config não-secreta) + `envFrom`
do `Secret` `app-credentials`. Probes de liveness/readiness/startup em
`/actuator/health` (Actuator já exposto pelos serviços). `startupProbe` folgada
porque a imagem de dev compila no start.

---

## Acesso local (port-forward)

Enquanto o Ingress não existe (PLT-3):

```bash
kubectl -n fiapx port-forward svc/auth-service 8080:8080
kubectl -n fiapx port-forward svc/minio 9001:9001        # console: http://localhost:9001
kubectl -n fiapx port-forward svc/rabbitmq 15672:15672   # management: http://localhost:15672
kubectl -n fiapx port-forward svc/mailhog 8025:8025      # inbox: http://localhost:8025
```

---

## Segredos

Nenhum segredo em texto plano no repositório. Detalhes em
[`docs/secrets.md`](docs/secrets.md). Resumo: só `.env.example` (com `CHANGE_ME`)
é versionado; o `.env` real é git-ignored; o Kustomize `secretGenerator`
materializa os `Secret` apenas dentro do cluster.

---

## Estrutura

```
infra/
├── kind/kind-config.yaml          # 1 control-plane + 2 workers
├── scripts/                       # bash puro, sem make
├── k8s/
│   ├── namespace.yaml
│   ├── infra/{base,overlays/local} # PLT-2
│   └── apps/{base,overlays/local}  # PLT-1
├── .env.example                   # template de segredos (CHANGE_ME)
└── docs/secrets.md
```
