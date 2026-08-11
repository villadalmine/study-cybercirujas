#!/usr/bin/env bash
#
# ============================================================================
#  LPIC-3 305 (exam 305-300, v3.0)
#  Topic 352.4 — Container Orchestration Platforms
#  Break & Fix lab: Docker Swarm scheduling / placement constraints
# ============================================================================
#
#  WHAT THIS SCRIPT DOES
#  ---------------------
#  It stands up a single-node Docker Swarm on a DISPOSABLE lab VM and deploys
#  a replicated service that CANNOT be scheduled. The orchestrator accepts the
#  service but never runs a single replica. Your job is to diagnose *why* the
#  scheduler refuses to place the tasks and make the service converge to the
#  desired state, using only the orchestration tooling (docker service /
#  docker node), without deleting and recreating the service by hand.
#
#  This exercises the core of objective 352.4: the split between the *desired
#  state* you declare and the *actual state* the orchestrator reconciles, and
#  the scheduler's node-selection logic (labels, constraints, task lifecycle).
#
#  Source of truth for the objective:
#    - LPI 305-300 objectives: https://www.lpi.org/our-certifications/exam-305-objectives/
#  Reference documentation used to build this lab:
#    - Swarm services:        https://docs.docker.com/engine/swarm/services/
#    - Placement constraints: https://docs.docker.com/engine/swarm/services/#control-service-placement
#    - Node management:       https://docs.docker.com/engine/swarm/manage-nodes/
#    - Task lifecycle/states: https://docs.docker.com/engine/swarm/how-swarm-mode-works/swarm-task-states/
#
#  SAFETY
#  ------
#  * Run ONLY on a throwaway VM. It initialises a Swarm and mutates node labels.
#  * It exposes nginx on 127.0.0.1:8080 only after the fix — nothing before it.
#  * It is fully reversible: pass 'clean' as the first argument to tear it down.
#  * It never touches data outside Docker's own Swarm/service state.
#
#  USAGE
#    ./352.4-break-and-fix.sh          # arm the broken scenario
#    ./352.4-break-and-fix.sh clean    # remove the service, labels and swarm
#
# ============================================================================

set -euo pipefail

SERVICE_NAME="orch-lab-web"
IMAGE="nginx:alpine"
REPLICAS=3
PUBLISH="127.0.0.1:8080:80"
REQUIRED_LABEL_KEY="tier"
REQUIRED_LABEL_VAL="frontend"
CONSTRAINT="node.labels.${REQUIRED_LABEL_KEY}==${REQUIRED_LABEL_VAL}"

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
rule() { printf '%s\n' "----------------------------------------------------------------------"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_docker() {
    command -v docker >/dev/null 2>&1 || die "docker is not installed on this VM."
    docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (permissions? is it running?)."
}

confirm_disposable() {
    say "This lab initialises a Docker Swarm and deliberately breaks a service."
    say "Run it ONLY on a disposable lab VM you are willing to reset."
    printf 'Type exactly  I-KNOW  to continue: '
    read -r ans
    [ "$ans" = "I-KNOW" ] || die "Aborted by user."
}

# ---------------------------------------------------------------------------
# Teardown path
# ---------------------------------------------------------------------------
if [ "${1:-}" = "clean" ]; then
    need_docker
    say "Cleaning up lab resources..."
    docker service rm "$SERVICE_NAME" >/dev/null 2>&1 || true
    NODE_ID="$(docker node ls --format '{{.ID}}' 2>/dev/null | head -n1 || true)"
    if [ -n "${NODE_ID:-}" ]; then
        docker node update --label-rm "$REQUIRED_LABEL_KEY" "$NODE_ID" >/dev/null 2>&1 || true
    fi
    # Leaving the swarm entirely is the cleanest reset for a throwaway VM.
    docker swarm leave --force >/dev/null 2>&1 || true
    say "Done. The VM is back to a plain (non-swarm) Docker engine."
    exit 0
fi

# ---------------------------------------------------------------------------
# Arm the broken scenario
# ---------------------------------------------------------------------------
need_docker
confirm_disposable

# 1) Ensure we are a swarm manager (idempotent — safe to run again).
if [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" != "active" ]; then
    say "Initialising a single-node swarm..."
    docker swarm init >/dev/null 2>&1 \
        || docker swarm init --advertise-addr 127.0.0.1 >/dev/null 2>&1 \
        || die "could not initialise the swarm."
fi

# 2) Pre-pull the image so the failure the student sees is unambiguous
#    (a scheduling failure, NOT a slow image pull).
docker pull "$IMAGE" >/dev/null 2>&1 || true

# 3) THE BREAK.
#    Deploy a replicated service pinned to nodes that carry the label
#    tier=frontend. This VM's only node has NO such label, so the scheduler
#    has zero candidate nodes and the tasks can never be placed.
#    (Idempotent: recreate if it already exists in some other state.)
docker service rm "$SERVICE_NAME" >/dev/null 2>&1 || true
say "Deploying the (intentionally unschedulable) service..."
docker service create \
    --name "$SERVICE_NAME" \
    --replicas "$REPLICAS" \
    --constraint "$CONSTRAINT" \
    --publish "$PUBLISH" \
    "$IMAGE" >/dev/null

# Give the reconciler a moment to try (and fail) to schedule.
sleep 3

rule
say "SCENARIO ARMED — Topic 352.4, Container Orchestration Platforms"
rule
say ""
say "SYMPTOM YOU WILL SEE"
say "  A service exists but is stuck at 0/${REPLICAS} replicas and never serves"
say "  traffic. 'docker service ls' shows something like:"
say ""
say "    NAME            MODE         REPLICAS   IMAGE"
say "    ${SERVICE_NAME}   replicated   0/${REPLICAS}        ${IMAGE}"
say ""
say "  curl http://127.0.0.1:8080  ->  connection refused"
say ""
say "  Live state right now:"
docker service ls --filter "name=${SERVICE_NAME}" || true
say ""
say "YOUR GOAL"
say "  Make the service converge to ${REPLICAS}/${REPLICAS} running replicas and have"
say "  'curl -s http://127.0.0.1:8080' return the nginx welcome page — WITHOUT"
say "  deleting and manually re-creating the service from scratch. Drive it"
say "  through the orchestrator's own reconciliation."
say ""
say "HINTS (the diagnostic ladder)"
say "  * 'docker service ls' tells you desired vs running — but not WHY."
say "  * 'docker service ps ${SERVICE_NAME} --no-trunc' shows each task's"
say "    CURRENT STATE and the scheduler's ERROR message. Read it carefully."
say "  * 'docker node ls' and 'docker node inspect <id>' show what the node"
say "    actually offers (labels, availability, role)."
say "  * Compare what the service DEMANDS against what the node PROVIDES."
say ""
say "When you think it is fixed, verify with:"
say "  docker service ps ${SERVICE_NAME}"
say "  curl -s http://127.0.0.1:8080 | head -n1"
say ""
say "To reset the VM at any time:  $0 clean"
rule

# ============================================================================
#  SOLUTION — STEP BY STEP  (uncomment / read only after you have tried)
# ============================================================================
#
#  1. Confirm the service is declared but not running any task:
#
#       docker service ls
#       # NAME            MODE         REPLICAS   IMAGE
#       # orch-lab-web    replicated   0/3        nginx:alpine
#
#  2. Ask the scheduler WHY. This is the single most important command in the
#     whole exercise — --no-trunc reveals the full error string:
#
#       docker service ps orch-lab-web --no-trunc
#       # ... CURRENT STATE   ERROR
#       # ... Pending 12s ago  "no suitable node (scheduling constraints not
#       #                        satisfied on 1 node)"
#
#     'Pending' (not 'Running', not 'Rejected') plus that message means the
#     orchestrator has an unmet PLACEMENT CONSTRAINT: there is no node it is
#     allowed to schedule onto. The task lifecycle never leaves NEW/PENDING.
#
#  3. See what the service demanded:
#
#       docker service inspect orch-lab-web \
#         --format '{{ .Spec.TaskTemplate.Placement.Constraints }}'
#       # [node.labels.tier==frontend]
#
#  4. See what the node actually offers — note there is no 'tier' label:
#
#       NODE_ID=$(docker node ls -q)
#       docker node inspect "$NODE_ID" --format '{{ .Spec.Labels }}'
#       # map[]
#
#     Diagnosis: the service requires nodes labelled tier=frontend; the only
#     node in this swarm has no such label, so the candidate set is empty and
#     the scheduler correctly refuses to place the replicas.
#
#  5. FIX — OPTION A (recommended: satisfy the constraint by labelling the node).
#     This is the production-correct move when the constraint expresses real
#     intent (e.g. "run this on frontend-tier hardware") and the node qualifies:
#
#       docker node update --label-add tier=frontend "$NODE_ID"
#
#     The reconciler notices the node now matches and schedules the tasks
#     automatically — no service edit needed. Watch it converge:
#
#       watch docker service ls        # 0/3 -> 3/3   (Ctrl-C to stop)
#       docker service ps orch-lab-web # all tasks -> Running
#
#     FIX — OPTION B (drop the constraint if it was a mistake). Note this is an
#     in-place rolling update of the service, still through the orchestrator —
#     you are NOT deleting and recreating it:
#
#       docker service update --constraint-rm 'node.labels.tier==frontend' orch-lab-web
#
#  6. Verify end to end:
#
#       docker service ls
#       # orch-lab-web   replicated   3/3   nginx:alpine
#       curl -s http://127.0.0.1:8080 | head -n1
#       # <!DOCTYPE html>
#
#  7. Tear the lab down when finished:
#
#       ./352.4-break-and-fix.sh clean
#
#  KEY TAKEAWAY
#  ------------
#  In an orchestration platform you declare DESIRED state; the control loop
#  continuously reconciles ACTUAL state toward it. A 0/N service is almost
#  never a crashing container — it is the scheduler telling you it has nowhere
#  legal to place the task. The fault is in the gap between what the service
#  DEMANDS (constraints, resources, images) and what the nodes PROVIDE
#  (labels, capacity, availability). 'docker service ps --no-trunc' is where
#  that gap is spelled out. The same mental model maps directly onto
#  Kubernetes: a Pod stuck in 'Pending' with 'FailedScheduling / node(s)
#  didn't match node selector / affinity' is the identical failure class, read
#  with 'kubectl describe pod' instead of 'docker service ps'.
# ============================================================================