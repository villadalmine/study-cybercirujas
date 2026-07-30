# teach-plat — atajos para todo el flujo.
# Uso típico:
#   make install
#   make generate CERT=lpi-010-160 TOPIC=1.1 BACKEND=claude
#   make serve
#   make publish MSG="contenido 1.1"

VENV    := .venv
TEACH   := $(VENV)/bin/teach
CERT    ?= lpi-010-160
BACKEND ?=
TOPIC   ?=
FORCE   ?=
LANG    ?=
HOST    ?= 127.0.0.1
PORT    ?= 8000
MSG     ?= actualiza contenido generado
TAG     ?= $(shell date +%Y%m%d%H%M%S)
REGISTRY ?= registry.registry:5000

GEN_FLAGS := $(if $(TOPIC),--topic $(TOPIC)) $(if $(FORCE),--force) $(if $(BACKEND),--backend $(BACKEND)) $(if $(LANG),--lang $(LANG))

.PHONY: help install list show generate serve lab-up lab-down lab-status git-init publish clean image-cluster deploy-local test audit batch quality verify

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

install: ## crea el venv e instala la CLI
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -e .
	@echo "OK: $(TEACH)"

list: ## catálogo de certificaciones
	$(TEACH) cert list

show: ## temario y estado (CERT=)
	$(TEACH) cert show $(CERT)

generate: ## genera contenido con AI (CERT= TOPIC= BACKEND=litellm|claude|codex|gemini|custom FORCE=1)
	$(TEACH) cert generate $(CERT) $(GEN_FLAGS)

serve: ## API + web (HOST= PORT=)
	$(TEACH) serve --host $(HOST) --port $(PORT)

lab-up: ## levanta el lab de un tema (CERT= TOPIC=)
	$(TEACH) lab up $(CERT) $(TOPIC)

lab-down: ## destruye el lab (CERT= TOPIC=)
	$(TEACH) lab down $(CERT) $(TOPIC)

lab-status: ## estado del lab (CERT= TOPIC=)
	$(TEACH) lab status $(CERT) $(TOPIC)

git-init: ## inicializa el repo git (una sola vez)
	git init -b main
	git add -A
	git commit -m "teach-plat: esqueleto inicial"

publish: ## commit + push del contenido generado al repo que publica la página (MSG=)
	git add catalog.yaml certs/
	git diff --cached --quiet && echo "Nada nuevo para publicar" || \
		(git commit -m "$(MSG)" && git push)

image-cluster: ## builda la imagen in-cluster: Kaniko como pod simple, contexto local por stdin (sin git/workflow)
	tar --exclude .git --exclude .venv --exclude '*.egg-info' --exclude __pycache__ -czf - . | \
	kubectl run kaniko-teach-plat --rm -i --restart=Never -n kaniko \
	  --image=gcr.io/kaniko-project/executor:latest -- \
	  --dockerfile=deploy/Dockerfile --context=tar://stdin \
	  --destination=$(REGISTRY)/teach-plat:$(TAG) \
	  --insecure --skip-tls-verify --snapshot-mode=redo --compression=zstd --compression-level=1

deploy-local: ## helm upgrade con values-local.yaml (TAG=)
	helm upgrade --install study deploy/helm -n teach-plat --create-namespace \
	  -f deploy/helm/values-local.yaml --set image.tag=$(TAG)

test: ## corre los tests (stdlib unittest, sin dependencias extra)
	$(VENV)/bin/python3 -m unittest discover tests -v

audit: ## lista combos pendientes/corruptos sin regenerar nada
	$(VENV)/bin/python3 scripts/fix_corrupted_content.py --audit-only

batch: ## genera un lote acotado por pipeline.yaml (CERT= LANG= [TOPICS=])
	$(VENV)/bin/python3 scripts/run_batch.py $(CERT) --lang $(if $(LANG),$(LANG),es) \
	  $(if $(BACKEND),--backend $(BACKEND)) $(if $(TOPICS),--topics $(TOPICS))

clean: ## borra el venv
	rm -rf $(VENV)

quality: ## informe de calidad del material (no genera nada)
	$(VENV)/bin/python3 scripts/quality_report.py $(CERT)

verify: ## verificaciones sin costo de API (citas + manifiestos + piso + tests)
	$(VENV)/bin/python3 scripts/quality_report.py
	$(VENV)/bin/python3 scripts/check_manifests.py
	$(VENV)/bin/python3 -m unittest discover tests
	@echo "Citas: scripts/check_citations.py (usa red, corre aparte)"
