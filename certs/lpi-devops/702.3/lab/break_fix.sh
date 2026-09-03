#!/usr/bin/env bash
#
# ==============================================================================
# LPI DevOps Tools Engineer — Exam 701-100, objectives version 2.0.0
# Topic 702.3 — Container Image Building (exam weight: 8.33)
#
# BREAK & FIX LABORATORY — run this ONLY on a disposable lab VM.
#
# What it does: it creates a self-contained container build project under
# $LAB_DIR, injects five realistic, production-grade defects into the
# Dockerfile and its build context, and gives you acceptance criteria. It
# never uses sudo, never touches system configuration, and only creates
# resources under $LAB_DIR plus images/containers prefixed with "lab7023".
#
# Official references:
#   LPI 701-100 objectives   https://www.lpi.org/our-certifications/exam-701-objectives/
#   Dockerfile reference     https://docs.docker.com/reference/dockerfile/
#   Multi-stage builds       https://docs.docker.com/build/building/multi-stage/
#   Build context            https://docs.docker.com/build/concepts/context/
#   podman-build(1)          https://docs.podman.io/en/latest/markdown/podman-build.1.html
#   OCI image annotations    https://github.com/opencontainers/image-spec/blob/main/annotations.md
# ==============================================================================

set -euo pipefail

LAB_DIR="${LAB_DIR:-$HOME/lab-702.3-image-building}"
IMG_TAG="lab7023/hello:1.0.0"
PROBE_TAG="lab7023/probe:latest"
CTR="lab7023-run"
BASE_BUILD="docker.io/library/alpine:3.20"
BASE_PROBE="docker.io/library/busybox:1.36"
BUILD_LOG="$LAB_DIR/.build.log"
REBUILD_LOG="$LAB_DIR/.rebuild.log"
MAX_IMAGE_BYTES=$((12 * 1024 * 1024))
MAX_STOP_SECONDS=3
BUILD_FLAGS=()
PASS=0
FAIL=0

if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; N=""
fi

die() { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
ok()  { printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; PASS=$((PASS + 1)); }
ko()  { printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"; if [ $# -gt 1 ]; then printf '        hint: %s\n' "$2"; fi; FAIL=$((FAIL + 1)); }

detect_engine() {
  if [ -z "${ENGINE:-}" ]; then
    if command -v podman >/dev/null 2>&1; then ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then ENGINE=docker
    else die "no container engine found. Install podman or docker."
    fi
  fi
  "$ENGINE" info >/dev/null 2>&1 || die "$ENGINE is installed but not usable (daemon down, or missing permissions)."
  if [ "$ENGINE" = "docker" ]; then
    export DOCKER_BUILDKIT=1
    BUILD_FLAGS=(--progress=plain)
  fi
}

confirm_disposable() {
  [ "${LAB_CONFIRM:-}" = "yes" ] && return 0
  cat <<'WARN'

  This lab writes a broken build project to disk and builds/runs containers.
  It is designed for a THROWAWAY lab VM. Do not run it on a workstation you
  care about, on a CI runner, or on any host with production images cached.

WARN
  local ans=""
  read -r -p "Type 'yes' to continue: " ans || ans=""
  [ "$ans" = "yes" ] || die "aborted by user."
}

preflight() {
  command -v tar >/dev/null 2>&1 || die "tar is required."
  printf 'Pulling base images (%s, %s)...\n' "$BASE_BUILD" "$BASE_PROBE"
  "$ENGINE" pull "$BASE_BUILD" >/dev/null || die "cannot pull $BASE_BUILD — this lab needs registry access."
  "$ENGINE" pull "$BASE_PROBE" >/dev/null || die "cannot pull $BASE_PROBE — this lab needs registry access."
}

scaffold() {
  rm -rf "$LAB_DIR"
  mkdir -p "$LAB_DIR/src" "$LAB_DIR/secrets" "$LAB_DIR/build-cache"

  cat >"$LAB_DIR/src/main.c" <<'C_EOF'
/* hello-702-3: a long-running PID 1 that reports its identity and exits
 * cleanly on SIGTERM. Signal handling is the whole point: an image whose
 * ENTRYPOINT is not PID 1 will never see this handler run. */
#include <stdio.h>
#include <signal.h>
#include <unistd.h>

static volatile sig_atomic_t terminate = 0;

static void on_term(int signum)
{
    (void)signum;
    terminate = 1;
}

int main(void)
{
    struct sigaction sa;
    sa.sa_handler = on_term;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    printf("hello from 702.3 -- pid=%d uid=%d gid=%d\n",
           (int)getpid(), (int)getuid(), (int)getgid());
    fflush(stdout);

    while (!terminate)
        sleep(1);

    printf("SIGTERM received, shutting down cleanly\n");
    fflush(stdout);
    return 0;
}
C_EOF

  # A deliberately fake credential. It exists only to prove that a careless
  # build context ships secrets inside image layers.
  cat >"$LAB_DIR/secrets/deploy.key" <<'K_EOF'
-----BEGIN OPENSSH PRIVATE KEY-----
FAKE-NOT-A-REAL-KEY-702-3-LAB-MATERIAL-DO-NOT-USE
AAAAB3NzaC1yc2EAAAADAQABAAABgQDlabsevenzerotwothreeFAKEFAKEFAKE
-----END OPENSSH PRIVATE KEY-----
K_EOF
  chmod 600 "$LAB_DIR/secrets/deploy.key"

  # A large artifact that has no business being in the build context.
  dd if=/dev/zero of="$LAB_DIR/build-cache/blob.bin" bs=1M count=25 status=none

  if command -v git >/dev/null 2>&1; then
    ( cd "$LAB_DIR" && git init -q && git add -A >/dev/null 2>&1 || true )
  else
    mkdir -p "$LAB_DIR/.git/objects"
    printf 'ref: refs/heads/main\n' >"$LAB_DIR/.git/HEAD"
  fi

  # ---- the broken Dockerfile: five injected faults -------------------------
  cat >"$LAB_DIR/Dockerfile" <<'D_EOF'
FROM docker.io/library/alpine:3.20 AS build
WORKDIR /src
COPY . .
RUN apk add --no-cache build-base
RUN gcc -O2 -o /src/hello src/main.c

FROM scratch
COPY --from=builder /src/hello /app/hello
COPY . /opt/context
CMD /app/hello
D_EOF

  # Note the absence of .dockerignore — that is fault 2, not an oversight.
  rm -f "$LAB_DIR/.dockerignore"
}

brief() {
  cat <<EOF

${B}=== TOPIC 702.3 — CONTAINER IMAGE BUILDING — BREAK & FIX ===${N}

Lab directory : $LAB_DIR
Engine        : $ENGINE
Target image  : $IMG_TAG
Edit          : $LAB_DIR/Dockerfile   (and add $LAB_DIR/.dockerignore)
Do NOT edit   : $LAB_DIR/src/main.c   (the application is correct)

The project builds a tiny C service in a multi-stage build and ships it in a
minimal final image. The application source compiles cleanly. Everything that
is broken is in the ${B}build definition${N}, which is exactly what 702.3 examines.

${B}--- FAULT 1: the build never reaches the final stage ---${N}
SYMPTOM   $ENGINE build ... fails almost immediately with an error such as
          "invalid from flag value builder: stage not found" (BuildKit) or
          "error creating build container: builder: image not known" (buildah).
GOAL      The build must complete and produce $IMG_TAG. Understand that a stage
          is addressable only by the name given in FROM ... AS <name>, or by its
          numeric index (COPY --from=0).

${B}--- FAULT 2: the build context is a data leak and a performance bug ---${N}
SYMPTOM   The build transfers ~25 MB of context; the resulting image contains
          /opt/context with .git/, build-cache/blob.bin and secrets/deploy.key.
          The image is roughly 25 MB for a binary of well under 1 MB. Deleting
          the file in a later layer would NOT help: layers are immutable and
          every intermediate layer is still pullable.
GOAL      The final image must be under 12 MiB and must contain no .git, no
          blob.bin and no deploy.key at any path. The context sent to the
          builder must be trimmed with a .dockerignore file at the context root.

${B}--- FAULT 3: every rebuild pays for the toolchain again ---${N}
SYMPTOM   Change one character in src/main.c, rebuild, and the "apk add
          --no-cache build-base" step runs from scratch — ~50 MB downloaded
          for a one-line source edit. In CI this is the difference between a
          30-second and a 4-minute pipeline.
GOAL      After touching src/main.c the rebuild must reuse the cached
          dependency layer (the build log must show CACHED / "Using cache"),
          and in the Dockerfile the dependency-install instruction must appear
          before any instruction that copies application source.

${B}--- FAULT 4: the image builds, then refuses to start ---${N}
SYMPTOM   Two different runtime failures, in sequence, both reported as
          "no such file or directory" — read the ${B}object${N} of the error, not
          just the message:
            a) the runtime cannot exec /bin/sh
            b) once (a) is fixed, the runtime cannot exec /app/hello, even
               though the file is demonstrably present in the image
GOAL      $ENGINE run --rm $IMG_TAG must print "hello from 702.3 ...".
          Both failures are one concept each: what a shell-form CMD implies,
          and what a dynamically linked ELF needs at exec time.

${B}--- FAULT 5: the container has no identity and does not stop ---${N}
SYMPTOM   The process runs as uid 0, it is not PID 1, "$ENGINE stop" hangs for
          the full grace period and then SIGKILLs, and the image carries no
          OCI metadata — nothing says what it is, which version, or where it
          came from.
GOAL      The container output must show pid=1 and a non-zero uid; the container
          must stop in under ${MAX_STOP_SECONDS}s; and the image must carry the label
          org.opencontainers.image.version.

${B}Commands${N}
  $0 verify      run the acceptance checks
  $0 hint N      progressive hint for fault N (1-5)
  $0 reset       throw away your edits, re-inject the original faults
  $0 clean       remove the lab directory and all lab images/containers

The step-by-step solution is at the bottom of this script, commented out.
Read it only after you have tried: sed -n '/BEGIN SOLUTION/,\$p' "\$0"

EOF
}

hint() {
  case "${1:-}" in
    1) cat <<'EOF'
FAULT 1 — Compare "FROM ... AS build" with "COPY --from=builder". Stage names
are literal. Useful drills:
  grep -n '^FROM\|--from=' Dockerfile
  # a stage can also be referenced positionally: COPY --from=0
  # ...and --from= also accepts an *image* reference, which is the trick used
  # by the verifier to inspect a shell-less image.
EOF
;;
    2) cat <<'EOF'
FAULT 2 — Two independent problems:
  (a) the final stage copies the whole context: "COPY . /opt/context". Nothing
      in the runtime image needs the build context. Remove it and copy only
      the compiled artifact from the build stage.
  (b) there is no .dockerignore, so the client uploads .git/, secrets/ and a
      25 MB blob to the builder on every build. Create one at the context root.
      Its patterns are matched against paths relative to the context root, not
      against the Dockerfile's WORKDIR.
Verify what actually shipped:
  docker history --no-trunc lab7023/hello:1.0.0
  docker image inspect --format '{{.Size}}' lab7023/hello:1.0.0
EOF
;;
    3) cat <<'EOF'
FAULT 3 — Layer cache invalidation is positional: when an instruction's cache
entry is invalidated, every instruction after it is rebuilt too. "COPY . ."
hashes the whole context, so any source edit invalidates it — and the "apk add"
line sits *after* it. Order instructions from least to most volatile:
  base image -> system packages -> dependency manifests -> application source.
Copy only what you compile (COPY src/main.c ...), not the entire context.
EOF
;;
    4) cat <<'EOF'
FAULT 4 — Two exec failures, two concepts:
  (a) "CMD /app/hello" is the *shell form*: the runtime executes
      ["/bin/sh","-c","/app/hello"]. A scratch image has no /bin/sh. Use the
      exec form: ENTRYPOINT ["/app/hello"].
  (b) gcc produces a dynamically linked ELF; scratch has no interpreter and no
      libc, so exec fails with ENOENT on the *interpreter*, not on the binary.
      Prove it inside the build stage:
        file /src/hello ; ldd /src/hello
      Either link statically (musl makes this painless) or ship a base image
      that provides the loader and libc.
EOF
;;
    5) cat <<'EOF'
FAULT 5 — Three details that separate a demo image from a shippable one:
  - USER: without it the process runs as root. In a scratch image there is no
    /etc/passwd, so use a numeric UID:GID (e.g. USER 10001:10001).
  - PID 1 / signals: exec-form ENTRYPOINT makes your binary PID 1, so it
    receives SIGTERM directly from "docker stop" / "podman stop".
  - Metadata: LABEL org.opencontainers.image.title / .version / .source, and
    build with an explicit -t name:version tag (":latest" is not a version).
EOF
;;
    *) die "usage: $0 hint <1-5>" ;;
  esac
}

verify() {
  [ -f "$LAB_DIR/Dockerfile" ] || die "lab not found at $LAB_DIR — run: $0 start"
  printf '\n%s== 702.3 acceptance checks ==%s\n\n' "$B" "$N"

  if "$ENGINE" build ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} -t "$IMG_TAG" "$LAB_DIR" >"$BUILD_LOG" 2>&1; then
    ok "C1  image builds and is tagged $IMG_TAG"
  else
    ko "C1  build failed" "tail -25 $BUILD_LOG"
    summary
    return
  fi

  # --- cache behaviour on a source-only change ------------------------------
  touch "$LAB_DIR/src/main.c"
  "$ENGINE" build ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} -t "$IMG_TAG" "$LAB_DIR" >"$REBUILD_LOG" 2>&1 || true
  if grep -Eqi 'CACHED|Using cache' "$REBUILD_LOG"; then
    ok "C2  rebuild after a source edit reuses cached layers"
  else
    ko "C2  rebuild after touching src/main.c reused no cache" "see $REBUILD_LOG ; $0 hint 3"
  fi

  local deps_line src_line
  deps_line="$(grep -n -m1 -E '^[[:space:]]*RUN[[:space:]].*apk[[:space:]]+add' "$LAB_DIR/Dockerfile" | cut -d: -f1 || true)"
  src_line="$(grep -n -m1 -E '^[[:space:]]*COPY[[:space:]]+[^-]' "$LAB_DIR/Dockerfile" | cut -d: -f1 || true)"
  if [ -n "$deps_line" ] && [ -n "$src_line" ] && [ "$deps_line" -lt "$src_line" ]; then
    ok "C3  dependency install precedes the application source COPY"
  else
    ko "C3  instructions are ordered most-volatile-first" "$0 hint 3"
  fi

  # --- image size and layer contents ----------------------------------------
  local size
  size="$("$ENGINE" image inspect --format '{{.Size}}' "$IMG_TAG" 2>/dev/null || echo 0)"
  if [ "$size" -gt 0 ] && [ "$size" -lt "$MAX_IMAGE_BYTES" ]; then
    ok "C4  final image is $((size / 1024)) KiB (< $((MAX_IMAGE_BYTES / 1024 / 1024)) MiB)"
  else
    ko "C4  final image is $((size / 1024)) KiB — the build context is being shipped" "$0 hint 2"
  fi

  # Inspecting a shell-less image: graft its filesystem into busybox with
  # COPY --from=<image>. This is the generic technique for auditing scratch
  # and distroless images without a debugger sidecar.
  local probe_dir listing
  probe_dir="$(mktemp -d)"
  cat >"$probe_dir/Dockerfile" <<EOF
FROM $BASE_PROBE
COPY --from=$IMG_TAG / /probe
CMD ["sh","-c","find /probe | head -400"]
EOF
  if "$ENGINE" build ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} -t "$PROBE_TAG" "$probe_dir" >/dev/null 2>&1 &&
     listing="$("$ENGINE" run --rm "$PROBE_TAG" 2>/dev/null)"; then
    if printf '%s\n' "$listing" | grep -Eq 'deploy\.key|blob\.bin|/\.git(/|$)'; then
      ko "C5  image layers still contain secrets/.git/build artefacts" "$0 hint 2"
    else
      ok "C5  no credentials, VCS metadata or build artefacts in the layers"
    fi
    if printf '%s\n' "$listing" | grep -q '/probe/app/hello'; then
      ok "C6  the compiled artefact is present at /app/hello"
    else
      ko "C6  /app/hello is missing from the final image" "COPY --from=<stage> the built binary"
    fi
  else
    ko "C5  could not probe the image layers" "the image may be unbuildable"
    ko "C6  could not probe the image layers" ""
  fi
  rm -rf "$probe_dir"

  # --- runtime behaviour ----------------------------------------------------
  "$ENGINE" rm -f "$CTR" >/dev/null 2>&1 || true
  local logs="" started=0
  if "$ENGINE" run -d --name "$CTR" "$IMG_TAG" >/dev/null 2>&1; then
    started=1
    sleep 2
    logs="$("$ENGINE" logs "$CTR" 2>&1 || true)"
  fi

  if [ "$started" -eq 1 ] && printf '%s\n' "$logs" | grep -q 'hello from 702.3'; then
    ok "C7  the container starts and the application runs"
  else
    ko "C7  the container does not run" "$ENGINE run --rm $IMG_TAG   # read the object of the ENOENT; $0 hint 4"
  fi

  if printf '%s\n' "$logs" | grep -q 'pid=1 '; then
    ok "C8  the application is PID 1 (exec form, no shell wrapper)"
  else
    ko "C8  the application is not PID 1" "$0 hint 5"
  fi

  local uid
  uid="$(printf '%s\n' "$logs" | sed -n 's/.*uid=\([0-9][0-9]*\).*/\1/p' | head -1)"
  if [ -n "$uid" ] && [ "$uid" -ne 0 ]; then
    ok "C9  the container runs as a non-root user (uid=$uid)"
  else
    ko "C9  the container runs as root (uid=${uid:-unknown})" "$0 hint 5"
  fi

  if [ "$started" -eq 1 ]; then
    local t0 elapsed
    t0=$SECONDS
    "$ENGINE" stop -t 10 "$CTR" >/dev/null 2>&1 || true
    elapsed=$((SECONDS - t0))
    if [ "$elapsed" -lt "$MAX_STOP_SECONDS" ]; then
      ok "C10 SIGTERM is delivered to the application (stopped in ${elapsed}s)"
    else
      ko "C10 stop took ${elapsed}s — the process never saw SIGTERM" "$0 hint 5"
    fi
  else
    ko "C10 stop not measured — container never started" ""
  fi
  "$ENGINE" rm -f "$CTR" >/dev/null 2>&1 || true

  if "$ENGINE" image inspect "$IMG_TAG" 2>/dev/null | grep -q 'org.opencontainers.image.version'; then
    ok "C11 the image carries OCI provenance labels"
  else
    ko "C11 the image has no org.opencontainers.image.version label" "$0 hint 5"
  fi

  summary
}

summary() {
  printf '\n  %s%d passed%s, %s%d failed%s\n\n' "$G" "$PASS" "$N" "$R" "$FAIL" "$N"
  if [ "$FAIL" -eq 0 ]; then
    printf '  %sLab complete.%s Now do the release step by hand:\n' "$G" "$N"
    printf '    %s tag %s registry.example.com/team/hello:1.0.0\n' "$ENGINE" "$IMG_TAG"
    printf '    %s login registry.example.com && %s push registry.example.com/team/hello:1.0.0\n\n' "$ENGINE" "$ENGINE"
  else
    printf '  Keep going: %s hint <1-5>\n\n' "$0"
    exit 1
  fi
}

status() {
  printf 'engine     : %s\n' "$ENGINE"
  printf 'lab dir    : %s\n' "$LAB_DIR"
  printf 'dockerfile : %s\n' "$LAB_DIR/Dockerfile"
  "$ENGINE" images --filter 'reference=lab7023/*' 2>/dev/null || true
}

clean() {
  "$ENGINE" rm -f "$CTR" >/dev/null 2>&1 || true
  "$ENGINE" rmi -f "$IMG_TAG" "$PROBE_TAG" >/dev/null 2>&1 || true
  rm -rf "$LAB_DIR"
  printf 'Lab removed: %s (images lab7023/* deleted)\n' "$LAB_DIR"
}

usage() {
  cat <<USAGE
Usage: $0 <command>

  start        scaffold the lab, inject the faults, print the mission brief
  brief        re-print the mission brief (symptoms + acceptance criteria)
  verify       run the acceptance checks against your build
  hint <1-5>   progressive hint for a specific fault
  status       show engine, paths and lab images
  reset        discard your edits and re-inject the original faults
  clean        remove the lab directory and every image it created

Environment: LAB_DIR (default $HOME/lab-702.3-image-building)
             ENGINE  (podman | docker; autodetected)
             LAB_CONFIRM=yes  skip the disposable-VM prompt
USAGE
}

main() {
  case "${1:-}" in
    start)  detect_engine; confirm_disposable; preflight; scaffold; brief ;;
    reset)  detect_engine; scaffold; printf 'Faults re-injected in %s\n' "$LAB_DIR" ;;
    brief)  detect_engine; brief ;;
    verify) detect_engine; verify ;;
    hint)   hint "${2:-}" ;;
    status) detect_engine; status ;;
    clean)  detect_engine; clean ;;
    *)      usage; exit 1 ;;
  esac
}

main "$@"
exit 0

# =============================================================================
# BEGIN SOLUTION — read only after attempting the lab
# =============================================================================
#
# STEP 0 — Reproduce and read the failure precisely
# -----------------------------------------------------------------------------
#   cd ~/lab-702.3-image-building
#   docker build -t lab7023/hello:1.0.0 .        # or: podman build -t ...
#
#   Expected first failure (BuildKit):
#     ERROR: failed to solve: invalid from flag value builder: stage not found
#   Expected first failure (buildah/podman):
#     Error: error creating build container: builder: image not known
#
#   The build never produced an image, so nothing downstream can be diagnosed
#   yet. Always fix the build in the order the builder reports it.
#
#
# STEP 1 — FAULT 1: the stage reference
# -----------------------------------------------------------------------------
#   grep -n '^FROM\|--from=' Dockerfile
#     1:FROM docker.io/library/alpine:3.20 AS build
#     7:COPY --from=builder /src/hello /app/hello
#
#   The stage is named "build"; the COPY asks for "builder". A stage is
#   addressable by its AS name or by its zero-based index (COPY --from=0).
#   --from= also accepts an image reference, which is how you inspect a
#   shell-less image (used by check C5 in this script).
#   Fix: COPY --from=build /src/hello /app/hello
#   Ref: https://docs.docker.com/build/building/multi-stage/
#
#
# STEP 2 — FAULT 4a/4b: why the image builds but will not exec
# -----------------------------------------------------------------------------
#   docker run --rm lab7023/hello:1.0.0
#     OCI runtime create failed: exec: "/bin/sh": stat /bin/sh: no such file or directory
#
#   "CMD /app/hello" is the SHELL form: the runtime runs
#   ["/bin/sh","-c","/app/hello"]. A scratch image contains no shell. Switch to
#   the exec form, which also makes the binary PID 1:
#     ENTRYPOINT ["/app/hello"]
#
#   Re-run. The error moves:
#     exec /app/hello: no such file or directory
#
#   The binary IS there. ENOENT here refers to the ELF *interpreter*, not the
#   program. Prove it from inside the build stage:
#     docker build --target build -t lab7023/dbg .
#     docker run --rm lab7023/dbg sh -c 'file /src/hello; ldd /src/hello'
#       /src/hello: ELF 64-bit LSB pie executable, dynamically linked,
#                   interpreter /lib/ld-musl-x86_64.so.1
#   scratch provides no loader and no libc. Two valid production answers:
#     (a) link statically:  gcc -O2 -static -o /src/hello src/main.c
#     (b) use a runtime base that ships the loader (alpine:3.20, or a
#         distroless/base image) instead of scratch.
#   This lab takes (a) — musl makes static linking cheap and the result is a
#   ~1 MB image with no OS packages and therefore almost no CVE surface.
#   Ref: https://docs.docker.com/reference/dockerfile/#entrypoint
#
#
# STEP 3 — FAULT 2: stop shipping the build context
# -----------------------------------------------------------------------------
#   docker image inspect --format '{{.Size}}' lab7023/hello:1.0.0   # ~26 MB
#   docker history --no-trunc lab7023/hello:1.0.0
#
#   "COPY . /opt/context" in the final stage bakes .git/, build-cache/blob.bin
#   and secrets/deploy.key into a layer. Deleting them in a later layer does
#   NOT remove them: layers are immutable and independently pullable, so the
#   credential remains extractable from the image forever. The only correct
#   response to a secret that reached a layer is to rotate the secret.
#
#   Delete that instruction. Then trim what is even uploaded to the builder by
#   creating the context-root file .dockerignore:
#
#       .git
#       .gitignore
#       secrets/
#       build-cache/
#       *.log
#       Dockerfile
#       .dockerignore
#       README.lab
#
#   Patterns are matched against paths relative to the context root.
#   Ref: https://docs.docker.com/build/concepts/context/#dockerignore-files
#
#   For build-time credentials that must never persist, the answer is a secret
#   mount, not a COPY and not an ARG:
#     RUN --mount=type=secret,id=npmrc  cat /run/secrets/npmrc
#     docker build --secret id=npmrc,src=$HOME/.npmrc .
#
#
# STEP 4 — FAULT 3: instruction order and the layer cache
# -----------------------------------------------------------------------------
#   Cache invalidation is positional: once an instruction misses, every later
#   instruction is rebuilt. "COPY . ." hashes the whole context and sits BEFORE
#   "apk add build-base", so editing one comment re-downloads the toolchain.
#
#   Order from least volatile to most volatile:
#     base image -> system packages -> dependency manifests -> app source
#   and copy only what you compile (COPY src/main.c) rather than the context.
#
#   Verify:
#     touch src/main.c && docker build --progress=plain -t lab7023/hello:1.0.0 .
#     # the apk step must report CACHED (buildah prints "--> Using cache")
#
#
# STEP 5 — FAULT 5: runtime identity, signals and provenance
# -----------------------------------------------------------------------------
#   - USER: default is root. scratch has no /etc/passwd, so use a numeric pair:
#       USER 10001:10001
#     (With a real base image you would create the account: adduser -D -u 10001 app)
#   - Signals: exec-form ENTRYPOINT makes the binary PID 1, so "docker stop"
#     delivers SIGTERM to it. With a shell wrapper, sh does not forward signals,
#     the grace period expires and the runtime SIGKILLs — no clean shutdown,
#     no connection draining. Measure it:  time docker stop -t 10 <ctr>
#   - Provenance: OCI labels plus a real version tag. ":latest" is not a
#     version; it is a mutable pointer that makes rollbacks unprovable.
#   Ref: https://github.com/opencontainers/image-spec/blob/main/annotations.md
#
#
# STEP 6 — The corrected Dockerfile
# -----------------------------------------------------------------------------
#   # syntax=docker/dockerfile:1
#   FROM docker.io/library/alpine:3.20 AS build
#   RUN apk add --no-cache build-base
#   WORKDIR /src
#   COPY src/main.c ./src/main.c
#   RUN gcc -O2 -static -o /src/hello src/main.c \
#    && strip /src/hello \
#    && chmod 0555 /src/hello
#
#   FROM scratch
#   LABEL org.opencontainers.image.title="hello-702-3" \
#         org.opencontainers.image.version="1.0.0" \
#         org.opencontainers.image.licenses="MIT" \
#         org.opencontainers.image.source="https://example.invalid/lab/702.3"
#   COPY --from=build /src/hello /app/hello
#   USER 10001:10001
#   ENTRYPOINT ["/app/hello"]
#
#   Note the "# syntax=" line: it pins the BuildKit frontend so features such
#   as --mount=type=secret and heredocs are available regardless of the local
#   Docker version. buildah ignores it harmlessly.
#
#
# STEP 7 — Build, verify, release
# -----------------------------------------------------------------------------
#   docker build -t lab7023/hello:1.0.0 .
#   docker image inspect --format '{{.Size}}' lab7023/hello:1.0.0   # ~1 MB
#   docker run --rm lab7023/hello:1.0.0
#     hello from 702.3 -- pid=1 uid=10001 gid=10001
#
#   Audit a shell-less image by grafting it into busybox:
#     printf 'FROM busybox:1.36\nCOPY --from=lab7023/hello:1.0.0 / /probe\n' \
#       | docker build -t lab7023/probe -f - .
#     docker run --rm lab7023/probe find /probe
#
#   Release (tag then push; the tag is the artefact identity):
#     docker tag lab7023/hello:1.0.0 registry.example.com/team/hello:1.0.0
#     docker login registry.example.com
#     docker push registry.example.com/team/hello:1.0.0
#
#   Then:  ./break-fix-702.3.sh verify     # all 11 checks must pass
#
#
# STEP 8 — Exam notes worth memorising (702.3)
# -----------------------------------------------------------------------------
#   * CMD vs ENTRYPOINT: ENTRYPOINT is the executable, CMD supplies default
#     arguments; "docker run img args" replaces CMD, not ENTRYPOINT
#     (--entrypoint overrides ENTRYPOINT). Exec form ["a","b"] does no shell
#     expansion; shell form does, at the cost of a /bin/sh PID 1.
#   * COPY vs ADD: ADD additionally fetches URLs and auto-extracts local tar
#     archives. Prefer COPY; use ADD only when you want that behaviour.
#   * ARG vs ENV: ARG exists only during the build and is scoped per stage
#     (ARG before the first FROM is global); ENV persists into the running
#     container. Neither is a secret store — both are visible in image history.
#   * Each RUN/COPY/ADD creates a layer; other instructions only add metadata.
#   * WORKDIR creates the directory and is preferred over "RUN cd" (which does
#     not persist across instructions).
#   * EXPOSE is documentation plus a hint for -P; it publishes nothing.
#   * HEALTHCHECK requires a command inside the image — a scratch image cannot
#     have a useful one, which is one reason platforms prefer external probes.
#   * podman build/buildah bud accept the same Dockerfile and the same flags;
#     buildah additionally builds without a daemon and without root.
#
# =============================================================================
# END SOLUTION
# =============================================================================