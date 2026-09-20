# Relatório de carga — ambiente AWS (20/09/2026)

Teste de escalabilidade e de não-perda de requisições do FIAP X, executado
contra o **ambiente real na AWS** (EKS), não contra o kind local.

## Ambiente medido

| Item | Valor |
|---|---|
| Cluster | EKS 1.31, 3 nós `t3.large` (2 vCPU / 8 GiB cada) |
| Entrada | Ingress NGINX exposto por NLB |
| Banco | RDS PostgreSQL 16 (`db.t3.micro`) |
| Cache | ElastiCache Redis 7 |
| Mensageria | RabbitMQ 3.13 no cluster (1 réplica, disco efêmero) |
| Storage | S3 (`fiapx-app-<conta>-us-east-1`) |
| Réplicas iniciais | video-service 2, video-processor 2 (HPA em repouso) |
| Vídeo usado | `k6/fixtures/sample-3s.mp4` (3 s, 14 KB) |

Comando: `k6 run -e BASE_URL=<NLB> -e UPLOADS=<n> -e WAIT_FOR_PROCESSING=true k6/upload-load-test.js`

O teste sobe N uploads **ao mesmo tempo** e só passa se: nenhum upload for
recusado, todo upload aceito estiver persistido e todo vídeo chegar a
`COMPLETED`.

---

## Resultado — cenário do enunciado (50 uploads simultâneos)

| Métrica | Resultado |
|---|---|
| Uploads aceitos | **50 / 50** |
| Persistidos | **50 / 50** |
| Processados até `COMPLETED` | **50 / 50** |
| Requisições perdidas | **0** |
| Uploads recusados | **0** |
| p95 do upload | **1,44 s** |
| Falhas HTTP | **0,00 %** |
| Duração total | 8 s |

Saída completa: `evidencias/k6-50-oficial.txt`.

## Resultado — estresse (300 uploads simultâneos, 6× o cenário)

| Métrica | Resultado |
|---|---|
| Uploads aceitos | **300 / 300** |
| Persistidos | **300 / 300** |
| Processados até `COMPLETED` | **300 / 300** |
| Requisições perdidas | **0** |
| p95 do upload | **3,95 s** |
| Falhas HTTP | **0,00 %** |

Saída completa: `evidencias/k6-300-final.txt`.

---

## Escalonamento automático observado

Trecho real do HPA durante o pico (`evidencias/hpa-escalonamento-300.txt`):

```
18:15:41  video-service: cpu=  2% replicas= 2   video-processor: cpu=  2% replicas= 2
18:15:52  video-service: cpu= 24% replicas= 2   video-processor: cpu=142% replicas= 2(quer  5)
18:16:02  video-service: cpu= 24% replicas= 2   video-processor: cpu=142% replicas= 5
18:16:13  video-service: cpu=146% replicas= 2(quer 5)  video-processor: cpu=142% replicas= 5
18:16:24  video-service: cpu= 37% replicas= 5   video-processor: cpu=191% replicas= 5
```

Os dois serviços saem de 2 réplicas e escalam em menos de 30 segundos após o
pico. Terminado o processamento, voltam sozinhos ao mínimo (janela de 5 min).

---

## O que a medição corrigiu

Os três problemas abaixo **só apareceram sob carga real** e foram corrigidos
neste mesmo ciclo — cada um foi medido antes e depois.

### 1. video-service não escalava (gargalo de entrada)

Só o worker tinha HPA. Com 300 uploads simultâneos e 2 réplicas fixas, as
requisições enfileiravam e o cliente desistia aos 60 s.

| | p95 do upload | Uploads recusados | Perdidos |
|---|---|---|---|
| Antes (2 réplicas fixas) | 59,2 s | 40 | 5 |
| Depois (HPA 2–8 @ 70 %) | 4,96 s | 11 | 2 |

### 2. RabbitMQ reiniciava no meio do pico

A sonda de liveness usava `rabbitmq-diagnostics status`, que é cara: sob CPU
alta ela passava dos 15 s, o Kubernetes matava o broker e, com disco efêmero, o
que estava em fila ia junto. Era a causa dos vídeos perdidos que sobravam.
Trocada por `ping`, que responde no próprio processo, com mais tolerância a
falha.

| | Reinícios do broker | Perdidos |
|---|---|---|
| Antes | sim, durante o pico | 2 |
| Depois | nenhum | **0** |

### 3. O próprio teste contava errado acima de 100 uploads

A API limita a listagem a 100 itens por página e o script lia só a primeira.
Com 300 uploads, ele acusava "200 perdidos" que estavam apenas na página
seguinte. O script passou a paginar. **Nenhum vídeo estava perdido de fato** —
mas o número errado teria ido para a apresentação.

---

## Como reproduzir

```bash
export AWS_DEFAULT_REGION=us-east-1
aws eks update-kubeconfig --name fiapx
LB=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# cenário do enunciado
k6 run -e BASE_URL="http://$LB" -e UPLOADS=50 -e WAIT_FOR_PROCESSING=true \
  k6/upload-load-test.js

# acompanhar o escalonamento em outro terminal
watch -n2 kubectl -n fiapx get hpa
```

## Arquivos

| Arquivo | Conteúdo |
|---|---|
| `evidencias/k6-50-oficial.txt` | terminal completo do cenário de 50 |
| `evidencias/k6-300-final.txt` | terminal completo do estresse de 300 |
| `evidencias/k6-demo.txt` | execução de 300 **antes** das correções (comparação) |
| `evidencias/hpa-escalonamento-50.txt` | HPA durante o cenário de 50 |
| `evidencias/hpa-escalonamento-300.txt` | HPA durante o estresse |
| `evidencias/estado-do-cluster.txt` | pods, HPAs, filas e nós ao final |
| `<timestamp>-summary.{txt,json}` | resumo bruto gerado pelo k6 |
