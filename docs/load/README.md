# Relatorios de carga (PLT-10)

Gerados por `k6/upload-load-test.js` (`make load`). Cada execucao grava
`<timestamp>-summary.json` e `<timestamp>-summary.txt` aqui.

O teste dispara N uploads **simultaneos** (default 50) e falha se:

- algum upload for recusado (`uploads_rejected > 0`);
- algum upload aceito (202) nao estiver persistido (`requests_lost > 0`);
- com `WAIT_FOR_PROCESSING=true`, algum video nao chegar a `COMPLETED`
  (`videos_not_completed > 0`);
- com `P95_MAX_MS=<ms>`, o p95 do upload passar desse valor (sem a variável,
  a latência só é reportada — não é critério do PLT-10).

## Resultado de referência (kind local, 2026-09-16)

Cluster kind (1 control-plane + 2 workers) numa máquina de 16 CPUs / 8 GB,
`video-service` com 2 réplicas e limite de 1 CPU cada, sem o `video-processor`
implementado. Quatro execuções seguidas de 50 uploads simultâneos:

| Execução | Aceitos | Perdidos | p50 | p95 | máx |
|---|---|---|---|---|---|
| 1ª (JVM fria) | 50 | **0** | 2,8s | 3,5s | 3,7s |
| 2ª | 50 | **0** | 503ms | 619ms | 695ms |
| 3ª | 50 | **0** | 482ms | 616ms | 714ms |
| 4ª | 50 | **0** | 396ms | 591ms | 620ms |

Em todas, 0% de falhas HTTP e todo upload aceito estava persistido. Os vídeos
ficaram em `QUEUED`, como esperado sem worker.

A primeira execução é lenta por aquecimento da JVM (JIT e pools de conexão
frios), não por gargalo: a partir da segunda o p95 estabiliza em ~600ms. **Na
gravação da demo, rode uma vez antes para aquecer.**

O relatório completo da última execução está nos arquivos `*-summary.*` ao lado.
