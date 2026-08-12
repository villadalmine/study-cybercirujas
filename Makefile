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

.PHONY: help setup status cert next install list show generate serve lab-up lab-down lab-status git-init publish clean image-cluster deploy-local test audit batch quality verify

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

publish: ## commit + push ONE certification (MSG= CERT=<id>; ALL=1 to stage everything)
	@# Staging all of certs/ picks up whatever another agent is generating RIGHT
	@# NOW: its files are on disk but its syllabus status is only set at the end,
	@# so the pre-commit hook refuses the commit and the finished work cannot be
	@# published either. Reported by Antigravity 2026-08-06 and hit again the next
	@# morning. Pass CERT= to stage one certification and leave in-flight work alone.
	@if [ -z "$(ALL)" ]; then \
		echo "staging certs/$(CERT) and its syllabus only"; \
		$(TEACH) status; \
		git add catalog.yaml STATUS.md certs/$(CERT) certs/$(CERT).md 2>/dev/null || true; \
		$(VENV)/bin/python3 scripts/unstage_inflight.py; \
	else \
		echo "WARNING: ALL=1 — staging every certification. If another agent is"; \
		echo "         generating, this picks up its half-written topics."; \
		$(VENV)/bin/python3 -c "from teach.core import claims; a=claims.active(); \
		print('  in flight right now: ' + (', '.join('/'.join(c) for c in a) if a else 'nothing')); \
		import sys; sys.exit(0)"; \
		$(TEACH) status; \
		git add catalog.yaml STATUS.md certs/; \
	fi
	@git diff --cached --quiet && echo "Nothing new to publish" || \
		(git commit -m "$(MSG)" && git push)

image-cluster: ## build the image in-cluster: Kaniko as a plain pod, local context over stdin (no git/workflow)
	@# Remove a pod left behind by an interrupted build. `kubectl run --rm` only
	@# cleans up if it survives to the end, so a build killed by a timeout leaves
	@# one Completed and every later build dies with AlreadyExists — and the real
	@# error is invisible, because the failure surfaces as `tar: Wrote only 4096 of
	@# 10240 bytes` from the broken pipe.
	-kubectl delete pod kaniko-teach-plat -n kaniko --ignore-not-found --wait=true
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
	$(VENV)/bin/python3 scripts/check_provenance.py
	$(VENV)/bin/python3 scripts/check_sources.py
	$(VENV)/bin/python3 scripts/check_versions.py
	$(VENV)/bin/python3 scripts/check_syllabus.py
	$(VENV)/bin/python3 scripts/status_matrix.py --check
	$(VENV)/bin/python3 -m unittest discover tests
	@echo
	@echo "Network, run separately (still no API quota):"
	@echo "  scripts/check_citations.py     do the cited URLs resolve?"
	@echo "  scripts/check_api_facts.py     do manifests use APIs the tracked release serves?"
	@echo "Costs quota, sample only:"
	@echo "  scripts/check_claims.py        does the cited page SAY what we claim?"

# ---------------------------------------------------------------------------
# The paved path. Everything below is one command that does the whole thing in
# the right order, so nobody has to reconstruct the sequence by reading code.
#
# This exists because the alternative is observed, not hypothetical: when the
# official route is unclear or fails, an agent reads the repo, infers an order,
# and writes its own runner — which then skips the claim system and the budget
# and reports success it did not achieve. A command that always works is a
# better guardrail than a rule that says "do not do that".
# ---------------------------------------------------------------------------

.PHONY: cert next status setup

setup: ## install the venv AND the pre-commit hook (run this first, once)
	$(MAKE) install
	git config core.hooksPath .githooks
	@echo
	@echo "Ready. The hook now refuses commits that break the four fixed rules."
	@echo "Next: make status"

status: ## where everything stands: what is missing, and is what exists sound?
	@echo "=== pending work ==="
	@$(VENV)/bin/python3 scripts/fix_corrupted_content.py --audit-only 2>/dev/null | head -20 || true
	@echo
	@echo "=== traceability / bookkeeping / ordering ==="
	@$(VENV)/bin/python3 scripts/check_provenance.py || true
	@echo
	@echo "=== being generated right now, by anyone ==="
	@$(VENV)/bin/python3 -c "from teach.core import claims; a=claims.active(); print('\n'.join(map(str,a)) if a else '  (nothing)')"
	@echo
	@echo "=== spend so far ==="
	@$(VENV)/bin/python3 scripts/usage_report.py 2>/dev/null | head -8 || true

cert: ## take ONE certification from wherever it is to finished (CERT= [BACKEND=])
	@test -n "$(CERT)" || { echo "Usage: make cert CERT=<id> [BACKEND=claude] [TRANSLATE_BACKEND=litellm]"; exit 1; }
	$(VENV)/bin/python3 scripts/run_cert.py $(CERT) \
	  $(if $(BACKEND),--backend $(BACKEND),) \
	  $(if $(TRANSLATE_BACKEND),--translate-backend $(TRANSLATE_BACKEND),) \
	  $(if $(DRY),--dry-run,)
	@# Refresh the matrix here rather than relying on someone remembering.
	@# STATUS.md is generated from disk, so it is always truthful about the moment
	@# it ran — including mid-flight work by another agent, which is correct: a
	@# topic being generated genuinely is not finished yet.
	@test -n "$(DRY)" || $(TEACH) status

next: ## do whatever comes next, deciding for you which certification needs it
	@$(VENV)/bin/python3 scripts/next_work.py $(if $(BACKEND),--backend $(BACKEND),) $(if $(DRY),--dry-run,)
