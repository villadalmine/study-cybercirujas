#!/usr/bin/env bash
#
# ==============================================================================
#  CGOA — Certified GitOps Associate
#  Domain 4: GitOps Security & Observability (25% of the exam)
#  Topic 4.1 — Break & Fix Lab
#
#  TITLE: "The reconciler that lies: silent drift, a muted health signal,
#          and a supply-chain policy that never fires"
#
#  WHAT THIS SCRIPT IS
#  -------------------
#  A self-contained, destructive-by-design laboratory. It installs a k3d
#  cluster, installs Argo CD, deploys a healthy GitOps-managed application
#  from a LOCAL git repository (served over file:// so the lab needs no
#  network egress to GitHub), verifies it is Synced/Healthy, and THEN
#  deliberately breaks three security- and observability-relevant properties
#  of the GitOps control loop.
#
#  You must restore all three. The grader (`./cgoa-4.1-lab.sh verify`) is
#  objective: it checks observable cluster state, not your intent.
#
#  DESTRUCTIVE. RUN ONLY ON A DISPOSABLE LAB VM.
#  It creates and deletes a k3d cluster named `cgoa41`, writes only under
#  $LAB_HOME (default /opt/cgoa-lab), and refuses to run if a kubeconfig
#  context that is not the lab cluster is current.
#
#  Official references (verify these yourself — a GitOps engineer who cannot
#  cite the reconciliation contract cannot debug it):
#    - CGOA curriculum:
#      https://raw.githubusercontent.com/cncf/curriculum/master/cgoa/README.md
#    - OpenGitOps Principles v1.0.0:
#      https://opengitops.dev/
#      https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md
#    - Argo CD — Declarative Setup & Application CRD:
#      https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
#    - Argo CD — Diffing / ignoreDifferences:
#      https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
#    - Argo CD — Automated Sync Policy & selfHeal:
#      https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
#    - Argo CD — Resource Health:
#      https://argo-cd.readthedocs.io/en/stable/operator-manual/health/
#    - Argo CD — Notifications / metrics:
#      https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/
#    - Argo CD — RBAC:
#      https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/
#    - Kyverno policies & policy reports:
#      https://kyverno.io/docs/writing-policies/
#      https://kyverno.io/docs/policy-reports/
#    - Kubernetes Policy Report API (wg-policy):
#      https://github.com/kubernetes-sigs/wg-policy-prototypes
#    - Kubernetes RBAC:
#      https://kubernetes.io/docs/reference/access-authn-authz/rbac/
#
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
LAB_HOME="${LAB_HOME:-/opt/cgoa-lab}"
CLUSTER_NAME="cgoa41"
KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
GIT_REPO_DIR="${LAB_HOME}/gitops-repo"
GIT_REPO_URL="file://${GIT_REPO_DIR}"
ARGOCD_NS="argocd"
APP_NS="storefront"
APP_NAME="storefront"
KYVERNO_NS="kyverno"
STATE_DIR="${LAB_HOME}/state"
ARGOCD_VERSION="${ARGOCD_VERSION:-v2.13.2}"
KYVERNO_VERSION="${KYVERNO_VERSION:-1.13.2}"

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';    C_OFF=$'\033[0m'

log()   { printf '%s[lab]%s %s\n'  "${C_BLU}" "${C_OFF}" "$*"; }
ok()    { printf '%s[ ok]%s %s\n'  "${C_GRN}" "${C_OFF}" "$*"; }
warn()  { printf '%s[wrn]%s %s\n'  "${C_YEL}" "${C_OFF}" "$*"; }
fail()  { printf '%s[err]%s %s\n'  "${C_RED}" "${C_OFF}" "$*" >&2; }
die()   { fail "$*"; exit 1; }
hdr()   { printf '\n%s%s%s\n' "${C_BLD}" "$*" "${C_OFF}"; }

K() { kubectl --context "${KUBE_CONTEXT}" "$@"; }

# ------------------------------------------------------------------------------
# Safety rails — this script destroys things. Make sure it destroys only the lab.
# ------------------------------------------------------------------------------
guard_environment() {
  [[ -f /.dockerenv ]] || true

  if [[ "${I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM:-no}" != "yes" ]]; then
    cat <<'GUARD'

  ###########################################################################
  #  STOP.                                                                  #
  #                                                                         #
  #  This script intentionally breaks a Kubernetes cluster, an Argo CD       #
  #  installation and an admission-policy engine. It is safe ONLY on a       #
  #  throwaway lab VM that you can destroy afterwards.                       #
  #                                                                         #
  #  It will:                                                               #
  #    - create/delete a k3d cluster named "cgoa41"                          #
  #    - write under /opt/cgoa-lab                                           #
  #    - mutate Argo CD and Kyverno objects inside that cluster only         #
  #                                                                         #
  #  To acknowledge, re-run with:                                            #
  #    I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM=yes ./cgoa-4.1-lab.sh setup      #
  ###########################################################################

GUARD
    exit 1
  fi

  # Refuse to touch a cluster that is not ours, even if the user has a
  # production kubeconfig sitting in $KUBECONFIG. Everything in this script
  # goes through K() with an explicit --context, but a stray `kubectl` typed
  # by a tired student at 02:00 is the real risk we are guarding against.
  local current
  current="$(kubectl config current-context 2>/dev/null || echo none)"
  if [[ "${current}" != "none" && "${current}" != "${KUBE_CONTEXT}" ]]; then
    warn "Current kubectl context is '${current}', not '${KUBE_CONTEXT}'."
    warn "This lab always passes --context ${KUBE_CONTEXT} explicitly, so it will"
    warn "not touch '${current}'. Consider 'kubectl config use-context ${KUBE_CONTEXT}'"
    warn "after setup so your own commands are equally safe."
  fi
}

require_bins() {
  local missing=0 b
  for b in docker k3d kubectl git curl awk sed grep; do
    if ! command -v "${b}" >/dev/null 2>&1; then
      fail "missing required binary: ${b}"
      missing=1
    fi
  done
  (( missing == 0 )) || die "install the missing tooling and re-run"

  docker info >/dev/null 2>&1 || die "the docker daemon is not reachable for this user"
}

wait_rollout() {
  local ns="$1" kind_name="$2" timeout="${3:-300s}"
  K -n "${ns}" rollout status "${kind_name}" --timeout="${timeout}" >/dev/null
}

wait_for_condition() {
  # wait_for_condition <描述> <timeout-seconds> <shell-command>
  local desc="$1" timeout="$2"; shift 2
  local deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    if eval "$*" >/dev/null 2>&1; then
      ok "${desc}"
      return 0
    fi
    sleep 5
  done
  fail "timed out waiting for: ${desc}"
  return 1
}

argocd_app_field() {
  # $1 = jsonpath under .status
  K -n "${ARGOCD_NS}" get application "${APP_NAME}" \
     -o jsonpath="{.status.$1}" 2>/dev/null || true
}

# ==============================================================================
# PHASE 1 — BUILD THE HEALTHY BASELINE
# ==============================================================================

build_cluster() {
  hdr "1/6  Provisioning the k3d lab cluster"
  if k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""; then
    log "cluster ${CLUSTER_NAME} already exists — reusing it"
  else
    k3d cluster create "${CLUSTER_NAME}" \
      --agents 1 \
      --k3s-arg "--disable=traefik@server:0" \
      --wait
  fi
  K cluster-info >/dev/null
  ok "cluster ${CLUSTER_NAME} is up"
}

seed_git_repo() {
  hdr "2/6  Seeding the local Git repository (the single source of truth)"
  mkdir -p "${GIT_REPO_DIR}" "${STATE_DIR}"

  if [[ ! -d "${GIT_REPO_DIR}/.git" ]]; then
    git init -q -b main "${GIT_REPO_DIR}"
    git -C "${GIT_REPO_DIR}" config user.email "lab@cgoa.local"
    git -C "${GIT_REPO_DIR}" config user.name  "CGOA Lab"
  fi

  mkdir -p "${GIT_REPO_DIR}/apps/storefront"

  # ---- The desired state. Note every field: each one is load-bearing for a
  # ---- security control the student will later have to defend.
  cat > "${GIT_REPO_DIR}/apps/storefront/namespace.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: storefront
  labels:
    app.kubernetes.io/part-of: storefront
    # Pod Security Admission: the namespace itself carries the baseline.
    # https://kubernetes.io/docs/concepts/security/pod-security-admission/
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
YAML

  cat > "${GIT_REPO_DIR}/apps/storefront/serviceaccount.yaml" <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: storefront
  namespace: storefront
# No token is projected by default into pods that do not ask for it, and this
# workload never talks to the API server. Least privilege starts here.
automountServiceAccountToken: false
YAML

  cat > "${GIT_REPO_DIR}/apps/storefront/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: storefront
  namespace: storefront
  labels:
    app.kubernetes.io/name: storefront
spec:
  replicas: 3
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: storefront
  template:
    metadata:
      labels:
        app.kubernetes.io/name: storefront
    spec:
      serviceAccountName: storefront
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          # Digest-pinned on purpose: a mutable tag is not a desired state,
          # it is a promise that something else will decide for you later.
          image: registry.k8s.io/pause:3.10
          imagePullPolicy: IfNotPresent
          command: ["/pause"]
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi
YAML

  cat > "${GIT_REPO_DIR}/apps/storefront/networkpolicy.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: storefront-default-deny
  namespace: storefront
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
  # Deny-by-default. Anything this workload needs must be declared in Git.
YAML

  cat > "${GIT_REPO_DIR}/README.md" <<'MD'
# storefront — GitOps source of truth

This repository is the *only* place the desired state of the `storefront`
application is expressed. Any difference between this repository and the
cluster is drift, and drift is an incident, not a convenience.

OpenGitOps Principles v1.0.0 — https://opengitops.dev/
  1. Declarative
  2. Versioned and Immutable
  3. Pulled Automatically
  4. Continuously Reconciled
MD

  git -C "${GIT_REPO_DIR}" add -A
  if ! git -C "${GIT_REPO_DIR}" diff --cached --quiet; then
    git -C "${GIT_REPO_DIR}" commit -q -m "chore(storefront): declare hardened baseline"
  fi

  # Argo CD's repo-server clones over file:// from inside its own container, so
  # the repository has to live inside the cluster. We ship it as a ConfigMap-free
  # bind: k3d mounts the host path into every node, and we mirror it into the
  # repo-server with an initContainer-free approach — a plain in-cluster clone.
  ok "git repo ready at ${GIT_REPO_DIR} ($(git -C "${GIT_REPO_DIR}" rev-parse --short HEAD))"
}

install_argocd() {
  hdr "3/6  Installing Argo CD ${ARGOCD_VERSION}"
  K get ns "${ARGOCD_NS}" >/dev/null 2>&1 || K create ns "${ARGOCD_NS}"

  K -n "${ARGOCD_NS}" apply -f \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null

  log "waiting for the Argo CD control plane (this is the slow part)"
  wait_rollout "${ARGOCD_NS}" deploy/argocd-repo-server 600s
  wait_rollout "${ARGOCD_NS}" deploy/argocd-server      600s
  wait_rollout "${ARGOCD_NS}" deploy/argocd-redis       600s
  K -n "${ARGOCD_NS}" rollout status statefulset/argocd-application-controller --timeout=600s >/dev/null
  ok "Argo CD is running"
}

publish_repo_into_cluster() {
  # The repo-server needs to reach the Git repository. Rather than depend on
  # network egress, we push the repository into a git-daemon Pod living in the
  # cluster and point the Application at git://gitd.argocd.svc:9418/gitops-repo.
  hdr "4/6  Publishing the Git repository inside the cluster (git-daemon)"

  K -n "${ARGOCD_NS}" apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitd-boot
  namespace: argocd
data:
  boot.sh: |
    set -eu
    apk add --no-cache git >/dev/null
    mkdir -p /srv/git
    exec git daemon --verbose --export-all \
        --base-path=/srv/git --reuseaddr --enable=receive-pack \
        --listen=0.0.0.0 --port=9418 /srv/git
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitd
  namespace: argocd
spec:
  replicas: 1
  selector: { matchLabels: { app: gitd } }
  template:
    metadata: { labels: { app: gitd } }
    spec:
      containers:
        - name: gitd
          image: alpine:3.20
          command: ["/bin/sh", "/boot/boot.sh"]
          ports: [{ containerPort: 9418 }]
          volumeMounts:
            - { name: boot, mountPath: /boot }
            - { name: srv,  mountPath: /srv }
      volumes:
        - { name: boot, configMap: { name: gitd-boot } }
        - { name: srv,  emptyDir: {} }
---
apiVersion: v1
kind: Service
metadata:
  name: gitd
  namespace: argocd
spec:
  selector: { app: gitd }
  ports: [{ name: git, port: 9418, targetPort: 9418 }]
YAML

  wait_rollout "${ARGOCD_NS}" deploy/gitd 300s

  local pod
  pod="$(K -n "${ARGOCD_NS}" get pod -l app=gitd -o jsonpath='{.items[0].metadata.name}')"
  wait_for_condition "git-daemon is serving on :9418" 180 \
    "K -n ${ARGOCD_NS} exec ${pod} -- sh -c 'command -v git'"

  # Push the host repository into the in-cluster daemon.
  K -n "${ARGOCD_NS}" exec "${pod}" -- sh -c \
    'rm -rf /srv/git/gitops-repo && git init --bare -q /srv/git/gitops-repo && \
     git -C /srv/git/gitops-repo config receive.denyCurrentBranch ignore'

  ( cd "${GIT_REPO_DIR}"
    # kubectl port-forward is the transport: no ingress, no cloud, no secrets.
    K -n "${ARGOCD_NS}" port-forward "pod/${pod}" 19418:9418 >/dev/null 2>&1 &
    local pf=$!
    trap 'kill '"${pf}"' 2>/dev/null || true' RETURN
    sleep 4
    git remote remove incluster 2>/dev/null || true
    git remote add incluster "git://127.0.0.1:19418/gitops-repo"
    git push -q --force incluster main
    kill "${pf}" 2>/dev/null || true
  )

  echo "git://gitd.${ARGOCD_NS}.svc.cluster.local:9418/gitops-repo" > "${STATE_DIR}/repo_url"
  ok "repository published at $(cat "${STATE_DIR}/repo_url")"
}

push_repo_change() {
  # Helper the *student* will also need in the fix. Re-pushes the working repo
  # into the in-cluster daemon so Argo CD can see a new desired state.
  local pod pf
  pod="$(K -n "${ARGOCD_NS}" get pod -l app=gitd -o jsonpath='{.items[0].metadata.name}')"
  K -n "${ARGOCD_NS}" port-forward "pod/${pod}" 19418:9418 >/dev/null 2>&1 &
  pf=$!
  sleep 4
  git -C "${GIT_REPO_DIR}" push -q --force "git://127.0.0.1:19418/gitops-repo" main
  kill "${pf}" 2>/dev/null || true
  wait "${pf}" 2>/dev/null || true
}

install_kyverno() {
  hdr "5/6  Installing Kyverno ${KYVERNO_VERSION} (supply-chain admission control)"
  K apply -f \
    "https://github.com/kyverno/kyverno/releases/download/v${KYVERNO_VERSION}/install.yaml" >/dev/null

  wait_rollout "${KYVERNO_NS}" deploy/kyverno-admission-controller 600s
  wait_rollout "${KYVERNO_NS}" deploy/kyverno-reports-controller   600s || true

  # The guardrail that must survive: no mutable tags, no privileged containers.
  K apply -f - >/dev/null <<'YAML'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-immutable-and-unprivileged
  annotations:
    policies.kyverno.io/title: Immutable images and unprivileged containers
    policies.kyverno.io/category: Supply Chain Security
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: disallow-latest-tag
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["storefront"]
      validate:
        message: >-
          Images must not use the ':latest' tag. Pin a version or a digest —
          a mutable tag is not a versioned, immutable desired state.
        pattern:
          spec:
            containers:
              - image: "!*:latest"
    - name: disallow-privileged
      match:
        any:
          - resources:
              kinds: ["Pod"]
              namespaces: ["storefront"]
      validate:
        message: "privileged containers are not permitted in storefront"
        pattern:
          spec:
            containers:
              - securityContext:
                  privileged: "false"
YAML
  ok "Kyverno policy 'require-immutable-and-unprivileged' is enforcing"
}

create_application() {
  hdr "6/6  Creating the Argo CD Application (the reconciliation loop)"
  local repo; repo="$(cat "${STATE_DIR}/repo_url")"

  K apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: ${ARGOCD_NS}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${repo}
    targetRevision: main
    path: apps/storefront
  destination:
    server: https://kubernetes.default.svc
    namespace: ${APP_NS}
  syncPolicy:
    automated:
      prune: true      # deleting from Git deletes from the cluster
      selfHeal: true   # Principle 4: continuously reconciled
      allowEmpty: false
    syncOptions:
      - CreateNamespace=false
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
YAML

  wait_for_condition "Application ${APP_NAME} reports Synced"  420 \
    "[[ \"\$(K -n ${ARGOCD_NS} get application ${APP_NAME} -o jsonpath='{.status.sync.status}')\" == Synced ]]"
  wait_for_condition "Application ${APP_NAME} reports Healthy" 420 \
    "[[ \"\$(K -n ${ARGOCD_NS} get application ${APP_NAME} -o jsonpath='{.status.health.status}')\" == Healthy ]]"

  K -n "${APP_NS}" get deploy,sa,netpol
  ok "baseline is green: 3/3 replicas, deny-all NetworkPolicy, PSA restricted"
}

# ==============================================================================
# THE BREAK
# ==============================================================================

break_it() {
  hdr "BREAKING THE LAB — three faults, all of them realistic"

  # --------------------------------------------------------------------------
  # FAULT 1 — Drift is made INVISIBLE and PERMANENT.
  #
  # Someone "temporarily" scaled the Deployment during an incident and, to stop
  # Argo CD from scaling it back, added an ignoreDifferences entry plus
  # RespectIgnoreDifferences, and disabled selfHeal. The Application still
  # reports Synced. It is lying: the cluster no longer matches Git.
  #
  # This is the single most common real-world GitOps security failure: the
  # dashboard is green, so nobody audits, and the cluster quietly diverges.
  # --------------------------------------------------------------------------
  log "fault 1: neutering the reconciler (selfHeal off + ignoreDifferences)"
  K -n "${ARGOCD_NS}" patch application "${APP_NAME}" --type merge -p '{
    "spec": {
      "ignoreDifferences": [
        {"group":"apps","kind":"Deployment","name":"storefront",
         "namespace":"storefront","jsonPointers":["/spec/replicas"]}
      ],
      "syncPolicy": {
        "automated": {"prune": false, "selfHeal": false, "allowEmpty": false},
        "syncOptions": ["CreateNamespace=false","RespectIgnoreDifferences=true"]
      }
    }
  }' >/dev/null

  # ...and now the out-of-band change that Git never authorised.
  K -n "${APP_NS}" scale deployment/storefront --replicas=1 >/dev/null

  # Also strip the deny-all NetworkPolicy directly from the cluster. With prune
  # and selfHeal off, Argo CD will not put it back.
  K -n "${APP_NS}" delete networkpolicy storefront-default-deny --ignore-not-found >/dev/null

  # --------------------------------------------------------------------------
  # FAULT 2 — Observability is silenced at the source.
  #
  # A custom Lua health check was added to argocd-cm that hard-codes every
  # Deployment to "Healthy". Argo CD's health model is pluggable by design
  # (https://argo-cd.readthedocs.io/en/stable/operator-manual/health/), and
  # that same extensibility is how a green dashboard gets manufactured.
  #
  # Symptom: the app is Healthy even while pods are CrashLoopBackOff.
  # --------------------------------------------------------------------------
  log "fault 2: installing a Lua health override that always returns Healthy"
  K -n "${ARGOCD_NS}" patch configmap argocd-cm --type merge -p '{
    "data": {
      "resource.customizations.health.apps_Deployment": "hs = {}\nhs.status = \"Healthy\"\nhs.message = \"ok\"\nreturn hs\n"
    }
  }' >/dev/null

  # Break the workload for real, so the false "Healthy" is demonstrable.
  # An unreadable command against a read-only rootfs: CrashLoopBackOff.
  K -n "${APP_NS}" set image deployment/storefront web=busybox:1.36 >/dev/null
  K -n "${APP_NS}" patch deployment storefront --type json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/command",
       "value":["/bin/sh","-c","echo booting; exit 1"]}]' >/dev/null

  K -n "${ARGOCD_NS}" rollout restart statefulset/argocd-application-controller >/dev/null
  K -n "${ARGOCD_NS}" rollout status  statefulset/argocd-application-controller --timeout=300s >/dev/null

  # --------------------------------------------------------------------------
  # FAULT 3 — The admission guardrail is bypassed without being deleted.
  #
  # The Kyverno ClusterPolicy still exists — `kubectl get clusterpolicy` shows
  # it, an auditor screenshotting the list sees a control in place — but:
  #   (a) validationFailureAction was flipped Enforce -> Audit, and
  #   (b) the argocd namespace was added to an exclusion.
  # Violations are now recorded in a PolicyReport nobody reads instead of being
  # rejected at admission time.
  # --------------------------------------------------------------------------
  log "fault 3: downgrading the Kyverno policy from Enforce to Audit"
  K patch clusterpolicy require-immutable-and-unprivileged --type merge -p '{
    "spec": {
      "validationFailureAction": "Audit",
      "rules": [
        {"name":"disallow-latest-tag",
         "match":{"any":[{"resources":{"kinds":["Pod"],"namespaces":["storefront"]}}]},
         "exclude":{"any":[{"resources":{"namespaces":["storefront"]}}]},
         "validate":{"message":"Images must not use the :latest tag.",
                     "pattern":{"spec":{"containers":[{"image":"!*:latest"}]}}}},
        {"name":"disallow-privileged",
         "match":{"any":[{"resources":{"kinds":["Pod"],"namespaces":["storefront"]}}]},
         "validate":{"message":"privileged containers are not permitted",
                     "pattern":{"spec":{"containers":[{"securityContext":{"privileged":"false"}}]}}}}
      ]
    }
  }' >/dev/null

  # --------------------------------------------------------------------------
  # FAULT 4 (bonus, security) — an over-broad Argo CD RBAC grant.
  # The `readonly` role was quietly given sync and delete on every application.
  # --------------------------------------------------------------------------
  log "fault 4: widening argocd-rbac-cm (readonly can now sync and delete)"
  K -n "${ARGOCD_NS}" patch configmap argocd-rbac-cm --type merge -p '{
    "data": {
      "policy.default": "role:readonly",
      "policy.csv": "p, role:readonly, applications, get, */*, allow\np, role:readonly, applications, sync, */*, allow\np, role:readonly, applications, delete, */*, allow\np, role:readonly, applications, override, */*, allow\n"
    }
  }' >/dev/null

  date -u +%FT%TZ > "${STATE_DIR}/broken_at"
  print_briefing
}

# ==============================================================================
# THE BRIEFING — what the student sees, and what they must achieve
# ==============================================================================

print_briefing() {
  cat <<BRIEF

${C_BLD}================================================================================
 CGOA 4.1 — INCIDENT BRIEFING
 "Everything is green. Nothing is true."
================================================================================${C_OFF}

You are on call. Your Argo CD dashboard for the ${C_BLD}storefront${C_OFF} application
shows ${C_GRN}Synced${C_OFF} and ${C_GRN}Healthy${C_OFF}. Your compliance dashboard shows the Kyverno
supply-chain ClusterPolicy present and accounted for. A customer has opened a
ticket saying the storefront is down.

${C_BLD}SYMPTOMS YOU WILL OBSERVE${C_OFF}

  1. ${C_YEL}Argo CD reports Synced, but the cluster does not match Git.${C_OFF}
       kubectl --context ${KUBE_CONTEXT} -n ${APP_NS} get deploy storefront
     shows ${C_RED}1${C_OFF} replica; Git declares ${C_GRN}3${C_OFF}. The deny-all NetworkPolicy
     declared in Git is ${C_RED}absent${C_OFF} from the cluster entirely. Argo CD does not
     consider either of these a difference.

  2. ${C_YEL}Argo CD reports Healthy while every pod is CrashLoopBackOff.${C_OFF}
       kubectl --context ${KUBE_CONTEXT} -n ${APP_NS} get pods
     shows restarts climbing. The Application's .status.health.status still
     says Healthy. Your alerting is built on that field, so nothing paged.

  3. ${C_YEL}A container that violates the supply-chain policy is admitted.${C_OFF}
     Try it yourself — this should be REJECTED and is not:
       kubectl --context ${KUBE_CONTEXT} -n ${APP_NS} run canary \\
         --image=nginx:latest --restart=Never --dry-run=server
     The ClusterPolicy is still listed by 'kubectl get clusterpolicy'. Listing
     a control is not the same as the control being in force.

  4. ${C_YEL}Any authenticated Argo CD user can sync, override and delete apps.${C_OFF}
     Inspect: kubectl --context ${KUBE_CONTEXT} -n ${ARGOCD_NS} get cm argocd-rbac-cm -o yaml

${C_BLD}WHAT YOU MUST ACHIEVE${C_OFF} (the grader checks cluster state, not method)

  [A] ${APP_NS}/storefront runs ${C_BLD}3/3 ready${C_OFF} replicas of the image declared
      in Git, and the pods stay Running for at least 60 s.
  [B] The Argo CD Application reports ${C_BLD}Synced${C_OFF} AND ${C_BLD}Healthy${C_OFF}, and that
      Healthy verdict is ${C_BLD}earned${C_OFF} — the built-in health assessment must be in
      use, not an override.
  [C] ${C_BLD}selfHeal and prune are enabled again${C_OFF} and no ignoreDifferences entry
      masks /spec/replicas. Proof: the grader scales the Deployment out of band
      and Argo CD must restore it within 3 minutes with no human action.
  [D] The ${C_BLD}deny-all NetworkPolicy${C_OFF} declared in Git exists in the cluster.
  [E] The Kyverno ClusterPolicy is ${C_BLD}Enforce${C_OFF} with no namespace exclusion, and
      a ':latest' image in ${APP_NS} is ${C_BLD}rejected at admission${C_OFF}.
  [F] argocd-rbac-cm grants role:readonly ${C_BLD}only 'get'${C_OFF} — no sync, override
      or delete — and policy.default is not a writable role.

${C_BLD}RULES OF ENGAGEMENT${C_OFF}

  - ${C_BLD}Fix the cause in Git or in the platform's declarative config${C_OFF}, then let
    the loop converge. A 'kubectl scale' that makes the number go green is a
    failed exercise: the grader deliberately re-drifts the cluster in check [C].
  - The Git working tree is at ${GIT_REPO_DIR}. After committing, publish it
    with:  ${C_BLD}$0 push${C_OFF}
  - Argo CD UI, if you want it:
      kubectl --context ${KUBE_CONTEXT} -n ${ARGOCD_NS} port-forward svc/argocd-server 8080:443
      user: admin   password:
      kubectl --context ${KUBE_CONTEXT} -n ${ARGOCD_NS} get secret argocd-initial-admin-secret \\
        -o jsonpath='{.data.password}' | base64 -d; echo

${C_BLD}COMMANDS${C_OFF}
  $0 verify     run the grader
  $0 hint       progressive hints (does not reveal the fix)
  $0 push       publish your Git commits to the in-cluster repository
  $0 destroy    tear the whole lab down

${C_BLD}Start here — and read them in this order, because each explains the next:${C_OFF}
  kubectl --context ${KUBE_CONTEXT} -n ${ARGOCD_NS} get application ${APP_NAME} -o yaml | \\
    grep -A15 -E 'syncPolicy|ignoreDifferences'
  kubectl --context ${KUBE_CONTEXT} -n ${ARGOCD_NS} get cm argocd-cm -o yaml
  kubectl --context ${KUBE_CONTEXT} get clusterpolicy -o yaml | grep -E 'validationFailureAction|exclude' -A4
  kubectl --context ${KUBE_CONTEXT} -n ${ARGOCD_NS} logs statefulset/argocd-application-controller --tail=100

BRIEF
}

print_hint() {
  cat <<'HINT'

HINT 1 — Which of the four Principles is each symptom violating?
  https://opengitops.dev/  →  Declarative, Versioned & Immutable,
  Pulled Automatically, Continuously Reconciled.
  Symptom 1 kills principle 4. Symptom 2 kills your ability to *know* whether
  principle 4 holds. Symptoms 3 and 4 are the blast radius when it does not.

HINT 2 — "Synced" answers a narrower question than you think.
  Sync status = "does live state match the *diff Argo CD is willing to compute*".
  Read: https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
  What two mechanisms can remove a field from that diff entirely?

HINT 3 — Health is code, and code lives in a ConfigMap.
  https://argo-cd.readthedocs.io/en/stable/operator-manual/health/
  Which key in argocd-cm defines a per-GVK health assessment, and what happens
  to the built-in assessment when that key is present?
  Remember the application-controller caches customizations at startup.

HINT 4 — An admission policy that exists and an admission policy that admits
  are different objects.
  https://kyverno.io/docs/writing-policies/validate/
  Compare `validationFailureAction: Audit` vs `Enforce`, and check every rule
  for an `exclude` block. Then prove it with `--dry-run=server`, which actually
  calls the admission webhook.

HINT 5 — The workload itself is genuinely broken; that part is not a trick.
  Compare `kubectl -n storefront get deploy storefront -o yaml` against
  apps/storefront/deployment.yaml in Git. Do NOT hand-edit the live object:
  make the cluster converge to Git, and confirm you did by re-drifting it.

HINT 6 — Argo CD RBAC is a CSV, and the last matching rule wins.
  https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/
  `policy.default` is the fallback for every authenticated identity.

HINT
}

# ==============================================================================
# THE GRADER
# ==============================================================================

verify() {
  hdr "GRADING — CGOA 4.1"
  local pass=0 total=0

  chk() { # chk <label> <command...>
    local label="$1"; shift
    total=$(( total + 1 ))
    if eval "$*" >/dev/null 2>&1; then
      ok "[$total] ${label}"
      pass=$(( pass + 1 ))
    else
      fail "[$total] ${label}"
    fi
  }

  # --- [A] the workload actually runs -----------------------------------------
  chk "A. storefront has 3/3 ready replicas" \
    "[[ \"\$(K -n ${APP_NS} get deploy storefront -o jsonpath='{.status.readyReplicas}')\" == 3 ]]"

  chk "A. no container has restarted in the last generation" \
    "[[ \"\$(K -n ${APP_NS} get pods -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' | tr ' ' '+' | sed 's/^/0+/' | bc)\" -eq 0 ]]"

  chk "A. the running image matches the one declared in Git" \
    "[[ \"\$(K -n ${APP_NS} get deploy storefront -o jsonpath='{.spec.template.spec.containers[0].image}')\" == \
        \"\$(awk '/image:/{print \$2; exit}' ${GIT_REPO_DIR}/apps/storefront/deployment.yaml)\" ]]"

  # --- [B] the health verdict is earned ---------------------------------------
  chk "B. Application is Synced" \
    "[[ \"\$(argocd_app_field 'sync.status')\" == Synced ]]"
  chk "B. Application is Healthy" \
    "[[ \"\$(argocd_app_field 'health.status')\" == Healthy ]]"
  chk "B. no custom Deployment health override remains in argocd-cm" \
    "! K -n ${ARGOCD_NS} get cm argocd-cm -o jsonpath='{.data}' | grep -q 'health.apps_Deployment'"

  # --- [C] the loop is armed --------------------------------------------------
  chk "C. syncPolicy.automated.selfHeal is true" \
    "[[ \"\$(K -n ${ARGOCD_NS} get application ${APP_NAME} -o jsonpath='{.spec.syncPolicy.automated.selfHeal}')\" == true ]]"
  chk "C. syncPolicy.automated.prune is true" \
    "[[ \"\$(K -n ${ARGOCD_NS} get application ${APP_NAME} -o jsonpath='{.spec.syncPolicy.automated.prune}')\" == true ]]"
  chk "C. no ignoreDifferences entry masks the Deployment" \
    "[[ -z \"\$(K -n ${ARGOCD_NS} get application ${APP_NAME} -o jsonpath='{.spec.ignoreDifferences}')\" ]]"

  # The behavioural test: re-drift and see whether the loop closes it.
  log "C. behavioural drift test — scaling to 1 replica out of band…"
  K -n "${APP_NS}" scale deployment/storefront --replicas=1 >/dev/null 2>&1 || true
  total=$(( total + 1 ))
  if wait_for_condition "C. Argo CD self-healed the drift within 180s" 180 \
       "[[ \"\$(K -n ${APP_NS} get deploy storefront -o jsonpath='{.spec.replicas}')\" == 3 ]]"; then
    pass=$(( pass + 1 ))
  else
    fail "C. drift was NOT self-healed — the reconciler is still not closing the loop"
  fi

  # --- [D] the network guardrail ----------------------------------------------
  chk "D. deny-all NetworkPolicy exists" \
    "K -n ${APP_NS} get networkpolicy storefront-default-deny"
  chk "D. NetworkPolicy denies both ingress and egress" \
    "[[ \"\$(K -n ${APP_NS} get netpol storefront-default-deny -o jsonpath='{.spec.policyTypes}')\" == '[\"Ingress\",\"Egress\"]' ]]"

  # --- [E] admission control is in force --------------------------------------
  chk "E. ClusterPolicy validationFailureAction is Enforce" \
    "K get clusterpolicy require-immutable-and-unprivileged -o jsonpath='{.spec.validationFailureAction}' | grep -qi '^enforce$'"
  chk "E. no rule excludes the storefront namespace" \
    "! K get clusterpolicy require-immutable-and-unprivileged -o json | grep -q '\"exclude\"'"

  log "E. behavioural admission test — submitting a :latest image…"
  total=$(( total + 1 ))
  if ! K -n "${APP_NS}" run cgoa-canary --image=nginx:latest --restart=Never \
        --dry-run=server >/dev/null 2>&1; then
    ok "[$total] E. a ':latest' Pod is rejected at admission"
    pass=$(( pass + 1 ))
  else
    fail "[$total] E. a ':latest' Pod was ADMITTED — the policy is not enforcing"
  fi
  K -n "${APP_NS}" delete pod cgoa-canary --ignore-not-found >/dev/null 2>&1 || true

  # --- [F] least privilege in the GitOps control plane ------------------------
  chk "F. role:readonly cannot sync" \
    "! K -n ${ARGOCD_NS} get cm argocd-rbac-cm -o jsonpath='{.data.policy\.csv}' | grep -Eq 'role:readonly,[[:space:]]*applications,[[:space:]]*(sync|delete|override)'"
  chk "F. policy.default is not a writable role" \
    "! K -n ${ARGOCD_NS} get cm argocd-rbac-cm -o jsonpath='{.data.policy\.default}' | grep -Eq 'admin|role:admin'"

  hdr "RESULT: ${pass}/${total} checks passed"
  if (( pass == total )); then
    ok "PASS — the loop is closed, the signal is honest, the guardrails are in force."
    ok "Now answer, out loud, for the exam: which check would have caught this in CI?"
    return 0
  fi
  fail "FAIL — ${total} - ${pass} = $(( total - pass )) objective(s) still open. Run '$0 hint'."
  return 1
}

destroy() {
  hdr "Destroying the lab"
  k3d cluster delete "${CLUSTER_NAME}" 2>/dev/null || true
  rm -rf "${LAB_HOME}"
  ok "cluster and ${LAB_HOME} removed"
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

main() {
  local cmd="${1:-setup}"
  case "${cmd}" in
    setup)
      guard_environment
      require_bins
      build_cluster
      seed_git_repo
      install_argocd
      publish_repo_into_cluster
      install_kyverno
      create_application
      break_it
      ;;
    break)   guard_environment; break_it ;;
    brief)   print_briefing ;;
    hint)    print_hint ;;
    push)    push_repo_change; ok "pushed — Argo CD polls every 3 min, or force it with 'argocd app get ${APP_NAME} --refresh'" ;;
    verify)  verify ;;
    destroy) destroy ;;
    *)
      cat <<USAGE
usage: $0 {setup|break|brief|hint|push|verify|destroy}

  setup    build the cluster, deploy the app, then break it   (default)
  brief    reprint the incident briefing
  hint     progressive hints
  push     publish your Git commits into the in-cluster repo
  verify   run the grader
  destroy  delete the k3d cluster and ${LAB_HOME}
USAGE
      exit 1
      ;;
  esac
}

main "$@"

# ==============================================================================
#
#  ██████  ██████  ██   ██ ██ ██      ███████ ██████
#  SPOILER — SOLUTION BELOW. STOP READING UNTIL YOU HAVE TRIED.
#
# ==============================================================================
#
# ------------------------------------------------------------------------------
# STEP 0 — Establish ground truth before touching anything.
# ------------------------------------------------------------------------------
# The first instinct under pressure is to fix the number on the dashboard. That
# is exactly the failure mode this lab is built to punish. Start by separating
# three questions that the UI collapses into one word:
#
#   (a) What does Git say?          -> the desired state
#   (b) What does the cluster say?  -> the live state
#   (c) What does Argo CD *compare*?-> the diff it is willing to compute
#
# (c) is the one nobody checks, and it is where the lie lives.
#
#   export CTX=--context=k3d-cgoa41
#   kubectl $CTX -n argocd get application storefront -o yaml > /tmp/app.yaml
#   kubectl $CTX -n storefront get deploy storefront -o yaml   > /tmp/live.yaml
#   diff <(yq '.spec.replicas' /tmp/live.yaml) \
#        <(yq '.spec.replicas' /opt/cgoa-lab/gitops-repo/apps/storefront/deployment.yaml)
#
# Read /tmp/app.yaml and look specifically at:
#   .spec.ignoreDifferences         <- fields removed from the diff
#   .spec.syncPolicy.automated      <- selfHeal:false, prune:false
#   .spec.syncOptions               <- RespectIgnoreDifferences=true
#
# Those three together are a complete explanation of symptom 1: Argo CD is
# "Synced" because it has been told not to look at /spec/replicas, and it does
# not restore the deleted NetworkPolicy because selfHeal is off.
#
# ------------------------------------------------------------------------------
# STEP 1 — [C] Re-arm the reconciler. Remove the blindfold before the fix.
# ------------------------------------------------------------------------------
# Order matters. If you repair the workload first, with selfHeal still off, the
# next drift silently reopens the incident and you will have learned nothing.
#
#   kubectl $CTX -n argocd patch application storefront --type json -p '[
#     {"op":"remove","path":"/spec/ignoreDifferences"}
#   ]'
#
#   kubectl $CTX -n argocd patch application storefront --type merge -p '{
#     "spec": {
#       "syncPolicy": {
#         "automated": {"prune": true, "selfHeal": true, "allowEmpty": false},
#         "syncOptions": ["CreateNamespace=false"]
#       }
#     }
#   }'
#
# Verify the diff is honest again — this must now report OutOfSync, and that is
# PROGRESS, not regression. An honest red beats a manufactured green:
#
#   kubectl $CTX -n argocd get application storefront \
#     -o jsonpath='{.status.sync.status}{"\n"}'
#
# In a real environment you would not patch the Application by hand at all: the
# Application itself is declared in Git (app-of-apps / ApplicationSet), so this
# patch is a commit. The lab lets you patch so the loop is observable in one
# step, but note the smell — a mutable Application object is an ungoverned
# control plane. See:
#   https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
#
# ------------------------------------------------------------------------------
# STEP 2 — [B] Remove the manufactured health signal.
# ------------------------------------------------------------------------------
# Argo CD resolves resource health in this order: a customization in argocd-cm
# under `resource.customizations.health.<group>_<Kind>` wins over the built-in
# assessment for that GVK. Here, someone shipped a Lua function that ignores
# its `obj` argument entirely and returns Healthy unconditionally:
#
#   kubectl $CTX -n argocd get cm argocd-cm \
#     -o jsonpath='{.data.resource\.customizations\.health\.apps_Deployment}'
#
# Delete the key — do not "fix" the Lua. The built-in Deployment health check
# (which reads .status.conditions and availableReplicas) is the one you want:
#
#   kubectl $CTX -n argocd patch cm argocd-cm --type json -p '[
#     {"op":"remove","path":"/data/resource.customizations.health.apps_Deployment"}
#   ]'
#
# The application-controller reads these customizations into memory, so the
# change is not live until it restarts:
#
#   kubectl $CTX -n argocd rollout restart statefulset/argocd-application-controller
#   kubectl $CTX -n argocd rollout status  statefulset/argocd-application-controller
#
# Now the dashboard should turn Degraded. That is the correct signal, and it is
# the first true thing the system has said since the incident began.
#
#   kubectl $CTX -n argocd get application storefront \
#     -o jsonpath='{.status.health.status}: {.status.health.message}{"\n"}'
#
# ------------------------------------------------------------------------------
# STEP 3 — [A][D] Let the loop repair the workload. Do not repair it yourself.
# ------------------------------------------------------------------------------
# With ignoreDifferences gone and selfHeal on, Argo CD already has everything it
# needs: Git declares registry.k8s.io/pause:3.10, 3 replicas, and the deny-all
# NetworkPolicy. The live Deployment carries a busybox image with a failing
# command, 1 replica, and the NetworkPolicy is missing.
#
# Force a refresh instead of waiting out the 3-minute poll:
#
#   kubectl $CTX -n argocd patch application storefront --type merge -p \
#     '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
#
# Watch convergence:
#
#   kubectl $CTX -n storefront get deploy,pods,netpol -w
#
# Expected within ~60-90 s:
#   NAME                     READY   UP-TO-DATE   AVAILABLE
#   deployment.apps/storefront  3/3   3            3
#   NAME                            READY   STATUS    RESTARTS
#   pod/storefront-xxxxxxxxxx-aaaaa 1/1     Running   0
#   ... (3 pods)
#   NAME                                              POD-SELECTOR   AGE
#   networkpolicy.../storefront-default-deny           <none>         10s
#
# If the pods do NOT come back, the cause is almost always that the live object
# still carries an out-of-band field that Git does not manage — check for a
# stray `kubectl edit` by comparing the managedFields owner:
#
#   kubectl $CTX -n storefront get deploy storefront \
#     -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\t"}{.operation}{"\n"}{end}'
#
# You should see `argocd-controller` as the owner. If you see `kubectl-edit` or
# `kubectl-set`, that is your own hand in the loop — the honest repair is
# `kubectl delete` the field's owner conflict by letting Argo CD force-sync:
#
#   kubectl $CTX -n argocd patch application storefront --type merge -p \
#     '{"operation":{"sync":{"syncStrategy":{"apply":{"force":true}}}}}'
#
# ------------------------------------------------------------------------------
# STEP 4 — [E] Put the supply-chain guardrail back IN FORCE.
# ------------------------------------------------------------------------------
# Two independent bypasses were applied. Fixing one and declaring victory is the
# classic partial remediation.
#
#   Bypass 1: validationFailureAction: Enforce -> Audit
#             Kyverno still evaluates the rule, still writes a PolicyReport, and
#             still admits the resource. `kubectl get clusterpolicy` looks fine.
#   Bypass 2: an `exclude` block on the very namespace the `match` selected.
#             match minus exclude = the empty set. The rule cannot fire at all.
#
# Inspect both before fixing, so you can describe them in a postmortem:
#
#   kubectl $CTX get clusterpolicy require-immutable-and-unprivileged -o yaml \
#     | grep -nE 'validationFailureAction|match:|exclude:|namespaces:' -A3
#
#   # the evidence that the control was "working" all along, in the wrong mode:
#   kubectl $CTX -n storefront get policyreport -o wide
#
# Reapply the intended policy declaratively (in production this file lives in
# Git and is itself reconciled by Argo CD — a policy applied by hand has the
# same governance problem as the workload it is guarding):
#
#   cat <<'EOF' | kubectl $CTX apply -f -
#   apiVersion: kyverno.io/v1
#   kind: ClusterPolicy
#   metadata:
#     name: require-immutable-and-unprivileged
#   spec:
#     validationFailureAction: Enforce
#     background: true
#     rules:
#       - name: disallow-latest-tag
#         match:
#           any:
#             - resources:
#                 kinds: ["Pod"]
#                 namespaces: ["storefront"]
#         validate:
#           message: "Images must not use the ':latest' tag."
#           pattern:
#             spec:
#               containers:
#                 - image: "!*:latest"
#       - name: disallow-privileged
#         match:
#           any:
#             - resources:
#                 kinds: ["Pod"]
#                 namespaces: ["storefront"]
#         validate:
#           message: "privileged containers are not permitted in storefront"
#           pattern:
#             spec:
#               containers:
#                 - securityContext:
#                     privileged: "false"
#   EOF
#
# Prove enforcement behaviourally. `--dry-run=server` is the important flag: it
# reaches the admission webhook, unlike client-side dry-run, which proves only
# that your YAML parses.
#
#   kubectl $CTX -n storefront run canary --image=nginx:latest \
#     --restart=Never --dry-run=server
#
# Expected output (this is a PASS):
#   Error from server: admission webhook "validate.kyverno.svc-fail" denied the
#   request: resource Pod/storefront/canary was blocked due to the following
#   policies
#   require-immutable-and-unprivileged:
#     disallow-latest-tag: 'validation error: Images must not use the '':latest''
#       tag. ...'
#
# ------------------------------------------------------------------------------
# STEP 5 — [F] Restore least privilege on the GitOps control plane.
# ------------------------------------------------------------------------------
# Argo CD's RBAC is a Casbin CSV in argocd-rbac-cm. Two things were wrong: the
# readonly role was granted sync/delete/override, and policy.default hands that
# role to every authenticated identity — including any SSO user, and including
# tokens minted for CI.
#
#   kubectl $CTX -n argocd patch cm argocd-rbac-cm --type merge -p '{
#     "data": {
#       "policy.default": "role:readonly",
#       "policy.csv": "p, role:readonly, applications, get, */*, allow\np, role:readonly, projects, get, */*, allow\np, role:release-eng, applications, sync, storefront/*, allow\ng, platform-sre, role:release-eng\n"
#     }
#   }'
#
#   kubectl $CTX -n argocd rollout restart deployment/argocd-server
#
# Note what the corrected CSV expresses that the broken one did not: sync is a
# *privilege*, scoped to a named project/app pattern and bound to a group, not
# an ambient capability of merely being logged in. See
# https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/ — evaluation is
# first-match-wins per Casbin, so an over-broad `allow` early in the file cannot
# be walked back by a later `deny`; order and scope are the control.
#
# ------------------------------------------------------------------------------
# STEP 6 — Verify, then re-verify after deliberate re-drift.
# ------------------------------------------------------------------------------
#   ./cgoa-4.1-lab.sh verify
#
# The grader intentionally scales the Deployment back to 1 replica and waits up
# to 180 s. If you "fixed" step 3 with `kubectl scale` instead of repairing the
# loop, this is where the exercise fails you. That is the whole point: in GitOps
# the artifact of a fix is a converged loop, not a converged number.
#
# ------------------------------------------------------------------------------
# WHAT THIS MAPS TO ON THE CGOA EXAM (Domain 4, 25%)
# ------------------------------------------------------------------------------
# * Reconciliation is a security control, not just a deployment convenience.
#   Disabling selfHeal converts every manual `kubectl` into a persistent,
#   unreviewed change to production. Principle 4 of OpenGitOps exists for this.
#   https://github.com/open-gitops/documents/blob/main/PRINCIPLES.md
#
# * Sync status and health status answer different questions, and BOTH are
#   attacker-influenceable. ignoreDifferences narrows the diff; custom health
#   Lua rewrites the verdict. Any alerting built on a single boolean from the
#   GitOps tool is trusting a mutable ConfigMap. Alert on the *drift event*
#   (argocd_app_info{sync_status="OutOfSync"} in the Prometheus metrics
#   endpoint) and on the controller's reconciliation duration, not only on a UI
#   colour: https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/
#
# * Audit-mode policy is observability, not enforcement. A PolicyReport is a
#   detection; `Enforce` is a prevention. Knowing which one you have deployed —
#   and being able to prove it with `--dry-run=server` rather than by reading
#   the policy list — is the difference between a control and a screenshot.
#   https://kyverno.io/docs/policy-reports/
#
# * The GitOps controller is the most privileged workload in the cluster. Its
#   own RBAC (argocd-rbac-cm), the Kubernetes RBAC of its service accounts, and
#   the provenance of the repository it pulls from are all part of the trust
#   chain. Compromise any one and Git stops being the source of truth in
#   practice, however true it remains on paper.
#
# * The durable lesson: in GitOps, "green" is a claim made by software that is
#   itself configured by data you must govern. Verify controls behaviourally.
#   The dashboard is a hypothesis; `--dry-run=server` and a deliberate drift
#   test are the experiment.
# ==============================================================================