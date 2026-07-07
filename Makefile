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
HOST    ?= 127.0.0.1
PORT    ?= 8000
MSG     ?= actualiza contenido generado

GEN_FLAGS := $(if $(TOPIC),--topic $(TOPIC)) $(if $(FORCE),--force) $(if $(BACKEND),--backend $(BACKEND))

.PHONY: help install list show generate serve lab-up lab-down lab-status git-init publish clean

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

clean: ## borra el venv
	rm -rf $(VENV)
