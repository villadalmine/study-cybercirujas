# teach-plat — shortcuts for the whole workflow.
# Typical use:
#   make install
#   make generate CERT=lpi-010-160 TOPIC=1.1 BACKEND=claude
#   make serve
#   make publish MSG="content 1.1"

VENV    := .venv
# The one place the graph builder is pinned: `make graph-setup` and the
# graph.yml workflow (which reads this line) install exactly this, so a CI
# rebuild and a local one produce the same graph.
GRAPHIFY_VERSION := 0.9.91
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

.PHONY: groundedness groundedness-setup groundedness-deep
.PHONY: killercoda-test killercoda-export killercoda-diff preflight docker-run smoke determinism test-e2e test-lab-e2e lab-images lab-validate
.PHONY: lock help setup status cert next install list show generate serve lab-up lab-down lab-status git-init publish clean image-cluster deploy-local test audit batch quality verify metrics clean-registry check-models probe-models mcp-setup mcp-check graph graph-setup wiki verify-ci labels-check

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

preflight: ## check what make setup needs (python3 >= 3.11 with venv, git) and say what is missing
	@command -v git >/dev/null 2>&1 || { echo "ERROR: git not found. Debian/Ubuntu: sudo apt install git"; exit 1; }
	@command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found. Install Python 3.11 or newer (Debian/Ubuntu: sudo apt install python3 python3-venv)"; exit 1; }
	@python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' || { echo "ERROR: Python 3.11+ required, found $$(python3 --version 2>&1)"; exit 1; }
	@python3 -c 'import venv, ensurepip' 2>/dev/null || { echo "ERROR: python3 has no venv/ensurepip. Debian/Ubuntu: sudo apt install python3-venv"; exit 1; }
	@echo "preflight OK: $$(python3 --version), $$(git --version)"

install: preflight ## create the venv and install the CLI
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q --require-hashes -r requirements.lock
	$(VENV)/bin/pip install -q --no-deps -e .
	@echo "OK: $(TEACH)"

lock: ## regenerate requirements.lock from pyproject.toml (needs uv; keeps the current pins unless pyproject.toml asks for others)
	uv pip compile pyproject.toml --extra lab --universal --python-version 3.11 --generate-hashes \
		--custom-compile-command 'make lock' -o requirements.lock

list: ## certification catalog
	$(TEACH) cert list

show: ## syllabus and status (CERT=)
	$(TEACH) cert show $(CERT)

generate: ## generate content with AI (CERT= TOPIC= BACKEND=litellm|claude|codex|gemini|custom FORCE=1)
	$(TEACH) cert generate $(CERT) $(GEN_FLAGS)

serve: ## API + web (HOST= PORT=)
	@test -x $(TEACH) || { echo "ERROR: $(TEACH) not found — run 'make setup' first"; exit 1; }
	@echo "Site: http://$(HOST):$(PORT)   API docs: http://$(HOST):$(PORT)/docs   (Ctrl-C to stop)"
	$(TEACH) serve --host $(HOST) --port $(PORT)

docker-run: ## run the public image instead of the source (PORT=)
	@command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found — https://docs.docker.com/get-docker/ (or use: make setup && make serve)"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "ERROR: docker is installed but the daemon is not reachable (is Docker running? are you in the docker group?)"; exit 1; }
	@echo "Site: http://localhost:$(PORT)   API docs: http://localhost:$(PORT)/docs   (Ctrl-C to stop)"
	docker run --rm -p $(PORT):8000 ghcr.io/villadalmine/study-cybercirujas:latest

smoke: ## start the real server on a free port and hit the site, API and CLI (free, offline)
	@test -x $(VENV)/bin/python3 || { echo "ERROR: run 'make setup' first"; exit 1; }
	$(VENV)/bin/python3 -m unittest tests.test_smoke -v

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
		(git commit -s -m "$(MSG)" && git push)

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

# The commit a deploy published, as an annotated tag (docs/DEPLOY.md → Tag what is published).
# Local only: it prints the push, it never pushes.
.PHONY: site-tag
SITE_REF    ?= HEAD
SITE_SUFFIX ?=
IMAGE_TAG   ?=
site-tag: ## tag the deployed commit site-YYYY-MM-DD (UTC) with its release and image (SITE_REF= IMAGE_TAG= SITE_SUFFIX=.2)
	@ref=$$(git rev-parse --verify --quiet "$(SITE_REF)^{commit}") || { echo "ERROR: SITE_REF=$(SITE_REF) is not a commit"; exit 1; }; \
	tag="site-$$(date -u +%Y-%m-%d)$(SITE_SUFFIX)"; \
	if git rev-parse --verify --quiet "refs/tags/$$tag" >/dev/null; then \
		echo "ERROR: $$tag already exists; a second deploy today: SITE_SUFFIX=.2"; exit 1; fi; \
	rel=$$(git describe --tags --match 'v[0-9]*' --abbrev=0 "$$ref" 2>/dev/null || echo none); \
	git tag -a "$$tag" "$$ref" -m "site: $$tag" -m "release: $$rel" -m "image: $(or $(IMAGE_TAG),not given)" && \
	echo "OK: $$tag -> $$(git rev-parse --short "$$ref") (release $$rel). Publish it: git push origin $$tag"

milestone: ## work the declared milestone to completion, then stop
	@scripts/run_milestone.sh

publish-complete: ## build+deploy if a certification became complete (same TAG to both)
	$(VENV)/bin/python3 scripts/publish_if_complete.py $(if $(DRY),--dry-run,)

test: ## every fast test: units, offline smoke of site/API/CLI, labs, determinism, study-lab schema (no key, no network)
	$(VENV)/bin/python3 -m unittest discover tests -v
	$(VENV)/bin/python3 -m pytest tests/lab -m "not slow" -q

test-lab-e2e: ## study-lab runner end-to-end with Docker (STUDY_LAB_E2E_K8S=1 adds the kind lab)
	$(VENV)/bin/python3 -m pytest tests/lab -m slow -v

killercoda-export: ## generate the Killercoda scenario tree into build/killercoda (publish: docs/RUN-A-LAB-ANYWHERE.md)
	rm -rf build/killercoda
	scripts/study-lab export --target killercoda --all --out build/killercoda

killercoda-test: ## prove a lab like Killercoda runs it, in an Ubuntu 24.04 VM you are root in (LAB=cka/1.1); see docs/RUN-A-LAB-ANYWHERE.md
	@test -n "$(LAB)" || { echo "usage: make killercoda-test LAB=cka/1.1"; exit 1; }
	sudo -E env HOME=/root KUBECONFIG=/root/.kube/config $(abspath $(VENV))/bin/python -m teach.lab test --target killercoda --evidence build/killercoda-evidence $(LAB)

killercoda-diff: killercoda-export ## compare build/killercoda with a local clone of the mirror (MIRROR=path)
	diff -rq -x .git -x .github -x README.md -x CONTRIBUTING.md -x CODEOWNERS -x .gitattributes build/killercoda $(or $(MIRROR),../study-cybercirujas-killercoda) && echo "mirror is up to date"

lab-images: ## build the study-lab runner images (study-lab:k8s, study-lab:linux)
	docker build -t study-lab:k8s deploy/study-lab/k8s
	docker build -t study-lab:linux deploy/study-lab/linux

lab-validate: ## validate every lab.yaml against the v2 schema (REPORT=file.json)
	scripts/study-lab validate certs $(if $(REPORT),--report $(REPORT))

determinism: ## derived files and validators twice, byte for byte, with network and models blocked
	$(VENV)/bin/python3 -m unittest tests.test_determinism -v

test-e2e: ## slow: clone this repo fresh, make setup, serve, hit site/API/CLI, run a Docker lab, clean up
	@# Clones the committed HEAD, not the working tree: commit first, or set
	@# SRC=<url> to test the public repository exactly as a newcomer gets it.
	bash tests/e2e/clone_and_run.sh
	@# The study-lab e2e runs from this checkout's venv. CI's e2e job has none
	@# (clone_and_run.sh builds its own in a temp clone); the Labs workflow
	@# runs the study-lab e2e there instead.
	@if [ -x $(VENV)/bin/python3 ]; then $(MAKE) test-lab-e2e; \
	else echo "skip study-lab e2e: no $(VENV) here (run 'make setup'; CI runs it in .github/workflows/labs.yml)"; fi

audit: ## list pending/corrupt combos without regenerating anything
	$(VENV)/bin/python3 scripts/fix_corrupted_content.py --audit-only

batch: ## generate a batch bounded by pipeline.yaml (CERT= LANG= [TOPICS=])
	$(VENV)/bin/python3 scripts/run_batch.py $(CERT) --lang $(if $(LANG),$(LANG),es) \
	  $(if $(BACKEND),--backend $(BACKEND)) $(if $(TOPICS),--topics $(TOPICS))

clean: ## remove the venv
	rm -rf $(VENV)

quality: ## floor report, then score every topic and write its meta.yaml quality block (no model, offline)
	$(VENV)/bin/python3 scripts/quality_report.py $(CERT)
	$(VENV)/bin/python3 scripts/quality_score.py $(if $(CERT),certs/$(CERT))
	$(VENV)/bin/python3 scripts/quality_score.py --report $(if $(CERT),certs/$(CERT))

GROUND := $(VENV)/bin/python3 scripts/check_groundedness.py --fetch --write $(if $(DIRS),$(DIRS),--base $(if $(BASE),$(BASE),origin/main))

groundedness-setup: ## install the groundedness classifier (torch CPU, GLiClass) and download its pinned weights
	$(VENV)/bin/pip install -q -r requirements-groundedness.txt
	$(VENV)/bin/python3 scripts/check_groundedness.py --download

groundedness: ## claims not supported by their sources, GLiClass prefilter (topics changed vs BASE=origin/main, or DIRS=)
	$(GROUND)

groundedness-deep: ## the same, suspects confirmed by Granite Guardian on your llama-server (GUARDIAN_URL=)
	$(GROUND) --deep

clean-registry: ## prune old image tags and reclaim registry space (KEEP=3, APPLY=1)
	@# Dry run unless APPLY=1. Never prunes a tag any deployment is using, and
	@# aborts rather than guess if it cannot read what is deployed.
	$(VENV)/bin/python3 scripts/clean_registry.py --keep $(if $(KEEP),$(KEEP),3) $(if $(APPLY),--apply,)

metrics: ## real spend per stage/day/window from usage.jsonl + quota-history (free)
	$(VENV)/bin/python3 scripts/metrics_report.py

check-updates: ## refresh upstream curriculum facts and report drift (spends a few completions)
	@# Chain: sync scrapes what each vendor CURRENTLY publishes (AI-assisted,
	@# writes catalog.yaml upstream fields only) -> the matrix regenerates the
	@# "Exam versions" table in STATUS.md -> check_versions prints the verdict
	@# per cert. Found in practice 2026-09-03: lpi-devops was assumed "one
	@# objective behind" and upstream had shipped a full v2.0 overhaul.
	@# --backend claude explicitly: without it the sync falls to the litellm
	@# default and dies on whatever .env holds (a 401 on the first run).
	$(TEACH) tracker sync --backend claude
	$(VENV)/bin/python3 scripts/status_matrix.py
	$(VENV)/bin/python3 scripts/check_versions.py

check-models: ## do the bot's models still exist, at the price shown? (free, no key)
	$(VENV)/bin/python3 scripts/check_models.py

probe-models: ## do the bot's models ANSWER, read the material, and speak each language?
	@# Spends the bot's own OpenRouter key (LITELLM_API_KEY_BOT in .env), never
	@# the subscription and never the translation key. Three liveness/reasoning
	@# calls per model plus one per language, against a real topic of this
	@# corpus: $0.27 measured for the full pass, $0.008 with LANGS="".
	@# --dry-run prints the worst case and sends nothing. UPDATE=1 writes what
	@# it found into models.yaml, which is what the page builds its model menu,
	@# its effort selector and its per-language filtering from.
	$(VENV)/bin/python3 scripts/probe_models.py $(if $(UPDATE),--update,) $(if $(TIER),--tier $(TIER),) $(if $(LANGS),--langs "$(LANGS)",)

check-docs: ## docs consistent with the repo: links, anchors, paths, make/teach commands, generated files (free)
	$(VENV)/bin/python3 scripts/check_docs.py

graph: ## rebuild the code graph + derived wiki (tree-sitter AST — no LLM, no quota; CI does it on main)
	@test -x $(VENV)/bin/graphify || { echo "graphify not installed: make graph-setup"; exit 1; }
	$(VENV)/bin/graphify update .
	$(VENV)/bin/graphify export wiki

mcp-setup: ## one-time: install the MCP SDK, for `teach` and `graphify` over MCP
	@# Not a dependency of the deployed app — the pod serves HTTP and has no
	@# use for stdio tools. Both servers in .mcp.json need it; without it they
	@# fail at startup with ModuleNotFoundError and the tests skip.
	$(VENV)/bin/pip install -q -e '.[mcp]'
	@echo "OK — .mcp.json servers can start now: make mcp-check"

mcp-check: ## drive the study MCP server over stdio and print what it answers
	$(VENV)/bin/python3 -m unittest tests.test_mcp_server -v

graph-setup: ## one-time: install graphifyy into the venv (~40 tree-sitter grammars)
	@# Pinned (GRAPHIFY_VERSION, top of this file): the docs job and graph.yml read it
	@# from here, so local and CI run the same graphify.
	$(VENV)/bin/pip install -q graphifyy==$(GRAPHIFY_VERSION)
	@echo "OK: $(VENV)/bin/graphify — now: make graph"

wiki: ## update the OpenWiki wiki — COSTS API credits, never runs unattended (docs/DEVTOOLS.md)
	@command -v openwiki >/dev/null 2>&1 || { echo "openwiki not installed: npm install -g openwiki"; exit 1; }
	OPENWIKI_TELEMETRY_DISABLED=1 openwiki --update

verify: ## checks that cost no API budget (floor + manifests + k8s APIs + tests)
	$(VENV)/bin/python3 scripts/quality_report.py
	$(VENV)/bin/python3 scripts/check_manifests.py
	$(VENV)/bin/python3 scripts/check_k8s_apis.py
	$(VENV)/bin/python3 scripts/check_provenance.py
	$(VENV)/bin/python3 scripts/check_source_chain.py
	$(VENV)/bin/python3 scripts/quality_score.py --check
	$(VENV)/bin/python3 scripts/check_sources.py
	$(VENV)/bin/python3 scripts/check_versions.py
	$(VENV)/bin/python3 scripts/check_syllabus.py
	$(VENV)/bin/python3 scripts/check_labels.py
	$(VENV)/bin/python3 scripts/status_matrix.py --check
	$(VENV)/bin/python3 scripts/check_units.py
	$(VENV)/bin/python3 scripts/check_config.py
	$(VENV)/bin/python3 scripts/check_graph.py
	$(VENV)/bin/python3 scripts/check_docs.py --no-generated
	$(VENV)/bin/python3 scripts/gen_api_docs.py --check
	$(VENV)/bin/python3 scripts/gen_readme_table.py --check
	$(VENV)/bin/python3 -m unittest discover tests
	@echo
	@echo "Network, run separately (still no API quota):"
	@echo "  scripts/check_citations.py     do the cited URLs resolve?"
	@echo "  scripts/check_api_facts.py     do manifests use APIs the tracked release serves?"
	@echo "  scripts/check_models.py        do the study bot's models still exist, at that price?"
	@echo "Costs quota, sample only:"
	@echo "  scripts/check_claims.py        does the cited page SAY what we claim?"
	@echo "Costs the bot key (\$$0.27 measured), never the subscription:"
	@echo "  scripts/probe_models.py        do they answer, read our material, speak each language?"

labels-check: ## every label a form, the labeler, a workflow or check_pr names exists in .github/labels.yml (free)
	$(VENV)/bin/python3 scripts/check_labels.py

verify-ci: ## the free checks that hold on ANY clean clone — what CI runs, and what a contributor runs
	@# `make verify` minus three checks that describe the owner's workstation,
	@# not the commit: check_units reads ~/.config/systemd, check_config reads
	@# the local usage log, and status_matrix --check counts rendered videos,
	@# which are gitignored, so on a fresh clone every video column reads as
	@# missing and the check fails (found by cloning fresh on 2026-10-14).
	@# check_graph is skipped too: graphify is an optional install.
	$(VENV)/bin/python3 scripts/quality_report.py
	$(VENV)/bin/python3 scripts/check_manifests.py
	$(VENV)/bin/python3 scripts/check_k8s_apis.py
	$(VENV)/bin/python3 scripts/check_provenance.py
	$(VENV)/bin/python3 scripts/check_source_chain.py
	$(VENV)/bin/python3 scripts/quality_score.py --check
	$(VENV)/bin/python3 scripts/check_sources.py
	$(VENV)/bin/python3 scripts/check_versions.py
	$(VENV)/bin/python3 scripts/check_syllabus.py
	$(VENV)/bin/python3 scripts/check_labels.py
	$(VENV)/bin/python3 scripts/gen_api_docs.py --check
	$(VENV)/bin/python3 scripts/gen_readme_table.py --check
	$(VENV)/bin/python3 -m unittest discover tests

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

# ---------------------------------------------------------------------------
# Before you push (CONTRIBUTING.md -> "Check before you push").
# ---------------------------------------------------------------------------

.PHONY: pr-check install-hooks uninstall-hooks

BASE     ?= origin/main
PR_BODY  ?=
PR_TITLE ?=
QUICK    ?=

pr-check: ## the checks CI runs on a PR, locally, one line each (QUICK=1 skips the 4-min unit tests; BASE= PR_BODY=draft.md PR_TITLE=)
	@$(VENV)/bin/python3 scripts/pr_check.py --base $(BASE) $(if $(QUICK),--quick) $(if $(PR_BODY),--body-file $(PR_BODY)) $(if $(PR_TITLE),--title "$(PR_TITLE)")

install-hooks: ## OPTIONAL: run `make pr-check` before every `git push` (this clone only; undo: make uninstall-hooks)
	@test "$$(git config core.hooksPath)" = ".githooks" || { echo "run 'make setup' first (it sets core.hooksPath to .githooks)"; exit 1; }
	git config --local pr-check.prepush true
	@echo "OK: git push now runs make pr-check (.githooks/pre-push, switched on by .git/config). Undo: make uninstall-hooks"

uninstall-hooks: ## switch the pre-push check off again
	-git config --local --unset pr-check.prepush
	@echo "OK: git push no longer runs make pr-check"
