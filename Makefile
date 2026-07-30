# teach-plat — shortcuts for the whole workflow.
# Typical use:
#   make install
#   make generate CERT=lpi-010-160 TOPIC=1.1 BACKEND=claude
#   make serve
#   make publish MSG="content 1.1"

VENV    := .venv
TEACH   := $(VENV)/bin/teach
CERT    ?= lpi-010-160
BACKEND ?=
TOPIC   ?=
FORCE   ?=
LANG    ?=
HOST    ?= 127.0.0.1
PORT    ?= 8000
MSG     ?= update generated content
TAG     ?= $(shell date +%Y%m%d%H%M%S)
REGISTRY ?= registry.registry:5000

GEN_FLAGS := $(if $(TOPIC),--topic $(TOPIC)) $(if $(FORCE),--force) $(if $(BACKEND),--backend $(BACKEND)) $(if $(LANG),--lang $(LANG))

.PHONY: help install list show generate serve lab-up lab-down lab-status git-init publish clean image-cluster deploy-local test audit batch quality verify

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

install: ## create the venv and install the CLI
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -e .
	@echo "OK: $(TEACH)"

list: ## certification catalog
	$(TEACH) cert list

show: ## syllabus and status (CERT=)
	$(TEACH) cert show $(CERT)

generate: ## generate content with AI (CERT= TOPIC= BACKEND=litellm|claude|codex|gemini|custom FORCE=1)
	$(TEACH) cert generate $(CERT) $(GEN_FLAGS)

serve: ## API + web (HOST= PORT=)
	$(TEACH) serve --host $(HOST) --port $(PORT)

lab-up: ## bring up a topic lab (CERT= TOPIC=)
	$(TEACH) lab up $(CERT) $(TOPIC)

lab-down: ## tear down the lab (CERT= TOPIC=)
	$(TEACH) lab down $(CERT) $(TOPIC)

lab-status: ## lab status (CERT= TOPIC=)
	$(TEACH) lab status $(CERT) $(TOPIC)

git-init: ## initialise the git repo (once)
	git init -b main
	git add -A
	git commit -m "teach-plat: initial skeleton"

publish: ## commit + push generated content to the repo that publishes the site (MSG=)
	git add catalog.yaml certs/
	git diff --cached --quiet && echo "Nothing new to publish" || \
		(git commit -m "$(MSG)" && git push)

image-cluster: ## build the image in-cluster: Kaniko as a plain pod, local context over stdin (no git/workflow)
	tar --exclude .git --exclude .venv --exclude '*.egg-info' --exclude __pycache__ -czf - . | \
	kubectl run kaniko-teach-plat --rm -i --restart=Never -n kaniko \
	  --image=gcr.io/kaniko-project/executor:latest -- \
	  --dockerfile=deploy/Dockerfile --context=tar://stdin \
	  --destination=$(REGISTRY)/teach-plat:$(TAG) \
	  --insecure --skip-tls-verify --snapshot-mode=redo --compression=zstd --compression-level=1

deploy-local: ## helm upgrade with values-local.yaml (TAG=)
	helm upgrade --install study deploy/helm -n teach-plat --create-namespace \
	  -f deploy/helm/values-local.yaml --set image.tag=$(TAG)

test: ## run the tests (stdlib unittest, no extra dependencies)
	$(VENV)/bin/python3 -m unittest discover tests -v

audit: ## list pending/corrupt combos without regenerating anything
	$(VENV)/bin/python3 scripts/fix_corrupted_content.py --audit-only

batch: ## generate a batch bounded by pipeline.yaml (CERT= LANG= [TOPICS=])
	$(VENV)/bin/python3 scripts/run_batch.py $(CERT) --lang $(if $(LANG),$(LANG),es) \
	  $(if $(BACKEND),--backend $(BACKEND)) $(if $(TOPICS),--topics $(TOPICS))

clean: ## remove the venv
	rm -rf $(VENV)

quality: ## quality report for the material (generates nothing)
	$(VENV)/bin/python3 scripts/quality_report.py $(CERT)

verify: ## checks that cost no API budget (floor + manifests + k8s APIs + tests)
	$(VENV)/bin/python3 scripts/quality_report.py
	$(VENV)/bin/python3 scripts/check_manifests.py
	$(VENV)/bin/python3 scripts/check_k8s_apis.py
	$(VENV)/bin/python3 -m unittest discover tests
	@echo "Citations: scripts/check_citations.py (uses the network, run separately)"
