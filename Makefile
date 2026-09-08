# PLT-4 — atalhos da plataforma FIAP X.
# Todos os alvos apenas embrulham os scripts em scripts/, que continuam
# utilizaveis diretamente (bash puro, sem dependencia de make).

SHELL := /bin/bash
.DEFAULT_GOAL := help

NAMESPACE ?= fiapx
CLUSTER   ?= fiapx

.PHONY: help env up addons deploy observability ingress images verify demo load \
        ps logs top hpa down compose-up compose-down compose-logs validate

help: ## Lista os alvos disponiveis
	@echo "FIAP X — plataforma"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Caminho rapido:  make env && make up && make verify && make demo"

env: ## Cria o .env a partir do template (preencha os CHANGE_ME)
	@if [ -f .env ]; then \
		echo "[infra] .env ja existe — nada a fazer."; \
	else \
		cp .env.example .env; \
		echo "[infra] .env criado. Edite e troque os CHANGE_ME antes de 'make up'."; \
	fi

# ------------------------------------------------------------------ kind ----

up: ## Sobe tudo do zero: cluster + addons + imagens + infra + servicos + observabilidade + ingress
	./scripts/kind-up.sh
	./scripts/deploy-addons.sh
	./scripts/build-images.sh
	./scripts/load-images.sh
	./scripts/deploy-infra.sh
	./scripts/deploy-apps.sh
	./scripts/deploy-observability.sh
	./scripts/deploy-ingress.sh
	@echo
	@echo "[infra] pronto. Rode 'make verify' e depois 'make demo'."

addons: ## Instala Ingress NGINX e metrics-server no cluster (PLT-3)
	./scripts/deploy-addons.sh

deploy: ## Reaplica apenas os manifests (infra + servicos)
	./scripts/deploy-infra.sh
	./scripts/deploy-apps.sh

observability: ## Aplica Prometheus + Grafana (PLT-7)
	./scripts/deploy-observability.sh

ingress: ## Aplica o Ingress da aplicacao (PLT-3)
	./scripts/deploy-ingress.sh

images: ## Reconstroi as imagens dos 3 servicos e carrega no kind
	./scripts/build-images.sh
	./scripts/load-images.sh

verify: ## Checa os criterios de aceite (PLT-1 e PLT-2)
	./scripts/verify.sh

demo: ## Abre os port-forwards e imprime as URLs (Ctrl-C encerra)
	./scripts/demo.sh

load: ## Teste de carga k6 (PLT-10)
	@if [ -f k6/upload-load-test.js ]; then \
		k6 run k6/upload-load-test.js; \
	else \
		echo "[infra] k6/upload-load-test.js ainda nao existe — PLT-10 pendente."; \
		echo "[infra] Depende dos endpoints de upload (trilha B)."; \
		exit 1; \
	fi

ps: ## Estado dos pods, PVCs, services e HPA
	kubectl -n $(NAMESPACE) get pods,pvc,svc,hpa,ingress

top: ## Consumo de CPU/memoria dos pods (requer metrics-server)
	kubectl top pods -n $(NAMESPACE)

hpa: ## Acompanha o HPA do worker escalando (Ctrl-C encerra)
	kubectl -n $(NAMESPACE) get hpa video-processor -w

logs: ## Logs de um servico:  make logs SVC=video-service
	@test -n "$(SVC)" || { echo "uso: make logs SVC=<auth-service|video-service|video-processor>"; exit 1; }
	kubectl -n $(NAMESPACE) logs -f deploy/$(SVC)

down: ## Destroi o cluster kind (apaga os volumes)
	./scripts/down.sh

# -------------------------------------------------------- docker compose ----

compose-up: ## Sobe o ambiente completo via docker compose (sem Kubernetes)
	docker compose up -d --build
	@echo "[infra] RabbitMQ :15672 | MinIO :9001 | Mailhog :8025"

compose-down: ## Derruba o docker compose e remove os volumes
	docker compose down -v

compose-logs: ## Segue os logs do docker compose
	docker compose logs -f

# ---------------------------------------------------------------- checks ----

validate: ## Roda localmente as mesmas checagens da CI
	@set -e; \
	for o in k8s/infra/overlays/local k8s/apps/overlays/local; do \
		test -f "$$o/.env" || sed 's/CHANGE_ME.*/validate-placeholder-0123456789ab/' .env.example > "$$o/.env"; \
	done; \
	kubectl kustomize k8s/infra/overlays/local > /dev/null && echo "kustomize infra: OK"; \
	kubectl kustomize k8s/apps/overlays/local  > /dev/null && echo "kustomize apps : OK"; \
	command -v shellcheck >/dev/null && shellcheck -S warning scripts/*.sh && echo "shellcheck    : OK" || true
