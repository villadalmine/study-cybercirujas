#!/usr/bin/env bash
#
# ==============================================================================
#  CNPA — Cloud Native Platform Engineering Associate (exam version 2025-04-01)
#  Domain 5 — Platform Adoption & Enablement
#  Topic 5.3 — Developer Portals for Platform Adoption (Backstage)   (weight 2.0)
#
#  break_fix.sh — a controlled, reversible "break & fix" drill for a DISPOSABLE
#  lab VM. It injects ONE realistic Backstage software-catalog fault, tells the
#  student exactly which symptom to look for and what success looks like, and
#  ships the full step-by-step solution (commented, at the very bottom).
#
#  WHAT IT DOES / SAFETY MODEL
#    - Touches only files under the Backstage app directory, inside a clearly
#      namespaced lab folder (examples/cnpa-5.3-lab/) plus one marked config
#      block. No sudo, no system packages, no network mutations, nothing outside
#      the app tree. Everything is undone by:  ./break_fix.sh --restore
#    - The fault is a malformed catalog entity registered through a static
#      `file` location. The Backstage catalog is resilient: it records a
#      processing error for that ONE location and keeps serving every other
#      entity. Your existing catalog is never corrupted.
#
#  USAGE
#    ./break_fix.sh            # inject the fault (default)
#    ./break_fix.sh --check    # tell me whether I have fixed it yet
#    ./break_fix.sh --restore  # remove all lab artifacts, back to clean state
#    ./break_fix.sh --help
#
#  Point the script at your app if it is not auto-detected:
#    BACKSTAGE_DIR=/opt/backstage ./break_fix.sh
#
#  Reference sources (official):
#    - Descriptor format & entity validation:
#        https://backstage.io/docs/features/software-catalog/descriptor-format
#    - Entity references & naming rules:
#        https://backstage.io/docs/features/software-catalog/references
#    - Registering static locations in app-config:
#        https://backstage.io/docs/features/software-catalog/configuration
#    - CNPA curriculum:
#        https://github.com/cncf/curriculum/raw/master/CNPA_Curriculum.pdf
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# ------------------------------- presentation --------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'
else
  BOLD=''; RED=''; GRN=''; YLW=''; CYN=''; RST=''
fi
info()  { printf '%s[*]%s %s\n'  "$CYN"  "$RST" "$*"; }
ok()    { printf '%s[+]%s %s\n'  "$GRN"  "$RST" "$*"; }
warn()  { printf '%s[!]%s %s\n'  "$YLW"  "$RST" "$*" >&2; }
die()   { printf '%s[x]%s %s\n'  "$RED"  "$RST" "$*" >&2; exit 1; }
rule()  { printf '%s────────────────────────────────────────────────────────────────────────%s\n' "$BOLD" "$RST"; }

# --------------------------------- config ------------------------------------
BACKEND_PORT="${BACKEND_PORT:-7007}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
LAB_ID="cnpa-5.3-lab"
ENTITY_NAME_GOAL="payments-api-gateway"          # the valid name the student must land on
MARK_BEGIN="# >>> CNPA 5.3 LAB (managed by break_fix.sh; do not edit) >>>"
MARK_END="# <<< CNPA 5.3 LAB <<<"

# Locate a Backstage app directory. Order: env override -> CWD -> common paths.
detect_backstage_dir() {
  local candidates=()
  [[ -n "${BACKSTAGE_DIR:-}" ]] && candidates+=("$BACKSTAGE_DIR")
  candidates+=("$PWD" "$PWD/backstage" "$HOME/backstage" "/opt/backstage" "/srv/backstage")
  local d
  for d in "${candidates[@]}"; do
    if [[ -n "$d" && -f "$d/app-config.yaml" && -d "$d/packages/backend" ]]; then
      printf '%s\n' "$d"; return 0
    fi
  done
  return 1
}

BACKSTAGE_DIR="$(detect_backstage_dir || true)"
[[ -n "$BACKSTAGE_DIR" ]] || die "No Backstage app found. Set BACKSTAGE_DIR=/path/to/app (dir with app-config.yaml + packages/backend). Scaffold one with:  npx @backstage/create-app@latest"
BACKSTAGE_DIR="$(cd "$BACKSTAGE_DIR" && pwd)"     # absolutise

LAB_DIR="$BACKSTAGE_DIR/examples/$LAB_ID"
ENTITY_FILE="$LAB_DIR/broken-entity.yaml"
LOCAL_CFG="$BACKSTAGE_DIR/app-config.local.yaml"
DEDICATED_CFG="$BACKSTAGE_DIR/app-config.$LAB_ID.yaml"

# ------------------------------ arg parsing ----------------------------------
ACTION="break"
case "${1:-}" in
  ""|break|--break)      ACTION="break"   ;;
  --restore|restore)     ACTION="restore" ;;
  --check|check)         ACTION="check"   ;;
  -h|--help|help)        ACTION="help"    ;;
  *) die "Unknown argument: $1 (try --help)";;
esac

usage() {
  rule
  printf '%sCNPA 5.3 — Backstage catalog break & fix%s\n' "$BOLD" "$RST"
  cat <<EOF
  ./break_fix.sh            Inject the fault (default)
  ./break_fix.sh --check    Report whether the entity is now healthy
  ./break_fix.sh --restore  Remove every lab artifact
  ./break_fix.sh --help     This help

  App under test : $BACKSTAGE_DIR
  Backend URL    : http://localhost:$BACKEND_PORT
  Frontend URL   : http://localhost:$FRONTEND_PORT
EOF
  rule
}

# ------------------------ does the file define top-level catalog: -------------
has_toplevel_catalog() { [[ -f "$1" ]] && grep -Eq '^[[:space:]]*catalog:[[:space:]]*$' "$1"; }

# --------------------------------- BREAK -------------------------------------
do_break() {
  info "Injecting the CNPA 5.3 catalog fault into: $BACKSTAGE_DIR"

  # 1) Write the malformed Component entity. Exactly ONE defect: the entity name
  #    contains spaces and capitals, which the catalog validator rejects. Every
  #    other required field (type, lifecycle, owner) is present and valid so the
  #    student's job is unambiguous: make the name a valid entity name.
  mkdir -p "$LAB_DIR"
  cat > "$ENTITY_FILE" <<'YAML'
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  # ↓↓↓ THE BUG ↓↓↓  Entity names must match [A-Za-z0-9] plus [-_.] only, max 63
  #                  chars, and MUST NOT contain spaces. This value has both
  #                  spaces and capitals, so the catalog rejects the whole entity.
  name: Payments API Gateway
  description: Public payments ingress — CNPA 5.3 lab component
  tags:
    - cnpa
    - lab
  annotations:
    backstage.io/techdocs-ref: dir:.
spec:
  type: service
  lifecycle: production
  owner: platform-team
  system: payments
YAML
  ok "Wrote malformed entity: $ENTITY_FILE"

  # 2) Register the file as a STATIC catalog location so the backend ingests it
  #    on startup. Prefer app-config.local.yaml (auto-loaded, zero-flag restart).
  #    If that file already owns a top-level `catalog:` key, fall back to a
  #    dedicated config file to avoid a duplicate-key merge, and print the flag.
  local target="$ENTITY_FILE"
  if [[ ! -f "$LOCAL_CFG" ]] || ! has_toplevel_catalog "$LOCAL_CFG"; then
    if ! grep -qF "$MARK_BEGIN" "$LOCAL_CFG" 2>/dev/null; then
      {
        printf '\n%s\n' "$MARK_BEGIN"
        printf 'catalog:\n'
        printf '  locations:\n'
        printf '    - type: file\n'
        printf '      target: %s\n' "$target"
        printf '      rules:\n'
        printf '        - allow: [Component]\n'
        printf '%s\n' "$MARK_END"
      } >> "$LOCAL_CFG"
    fi
    ok "Registered location in: $LOCAL_CFG (auto-loaded — a normal restart picks it up)"
    LAB_START_HINT="yarn start          # from ${BACKSTAGE_DIR}"
  else
    cat > "$DEDICATED_CFG" <<YAML
# CNPA 5.3 lab — extra static catalog location.
# Append it at start time:  --config app-config.$LAB_ID.yaml
catalog:
  locations:
    - type: file
      target: $target
      rules:
        - allow: [Component]
YAML
    ok "Registered location in dedicated file: $DEDICATED_CFG"
    LAB_START_HINT="yarn start --config app-config.yaml --config app-config.local.yaml --config app-config.$LAB_ID.yaml"
  fi

  print_briefing
}

# ------------------------------ THE BRIEFING ---------------------------------
print_briefing() {
  echo
  rule
  printf '%sSCENARIO%s  A teammate onboarded a new service to the developer portal by\n' "$BOLD" "$RST"
  printf 'committing a catalog descriptor. The portal is up, every other component is\n'
  printf 'listed, but their new "Payments API Gateway" never shows up in the catalog.\n'
  rule
  printf '%sSTART / RESTART THE PORTAL%s\n' "$BOLD" "$RST"
  printf '  cd %s\n' "$BACKSTAGE_DIR"
  printf '  %s\n' "${LAB_START_HINT:-yarn start}"
  echo
  printf '%sSYMPTOM YOU WILL SEE%s\n' "$BOLD" "$RST"
  printf '  1) In the UI (http://localhost:%s) the component is ABSENT from the\n' "$FRONTEND_PORT"
  printf '     Catalog: searching "payments" returns nothing.\n'
  printf '  2) In the backend logs a processing error is printed for the lab location,\n'
  printf '     roughly:\n'
  printf '        %sbackstage:catalog Processor ... failed%s\n' "$YLW" "$RST"
  printf '        %sInputError: Malformed envelope, .metadata.name "Payments API Gateway"%s\n' "$YLW" "$RST"
  printf '        %sis not a valid entity name, expected a string ... [A-Za-z0-9] and [-_.]%s\n' "$YLW" "$RST"
  printf '  3) API confirmation (guest auth may be required in newer releases):\n'
  printf '        curl -s -o /dev/null -w "%%{http_code}\\n" \\\n'
  printf '          http://localhost:%s/api/catalog/entities/by-name/component/default/%s\n' "$BACKEND_PORT" "$ENTITY_NAME_GOAL"
  printf '        %s→ 404%s   (the entity was rejected, so it does not exist)\n' "$RED" "$RST"
  echo
  printf '%sYOUR GOAL%s  Make the descriptor a schema-valid Backstage Component so the\n' "$BOLD" "$RST"
  printf 'catalog ingests it. Success = the component "%s" appears in the\n' "$ENTITY_NAME_GOAL"
  printf 'Catalog UI, the by-name API returns %s200%s, and the location shows no error.\n' "$GRN" "$RST"
  printf '  Edit: %s\n' "$ENTITY_FILE"
  echo
  printf '  Check yourself at any time:   ./break_fix.sh --check\n'
  printf '  Clean everything up:          ./break_fix.sh --restore\n'
  rule
  warn "Do not read the commented SOLUTION at the bottom of this script until you have tried."
}

# -------------------------------- CHECK --------------------------------------
do_check() {
  local url="http://localhost:$BACKEND_PORT/api/catalog/entities/by-name/component/default/$ENTITY_NAME_GOAL"
  info "Probing: $url"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo 000)"
  case "$code" in
    200) ok  "HTTP 200 — '$ENTITY_NAME_GOAL' is in the catalog. FIXED. 🎉  Run --restore to clean up." ;;
    404) die "HTTP 404 — entity still missing. It is still being rejected or the backend has not reprocessed yet (default refresh ~100s; restart to force it)." ;;
    401|403) warn "HTTP $code — the catalog API requires auth in this release. Verify in the Catalog UI and in the backend logs instead." ;;
    000) die "No answer on port $BACKEND_PORT. Is the backend running? Start it and retry." ;;
    *)   warn "Unexpected HTTP $code. Cross-check the Catalog UI and the backend logs." ;;
  esac
}

# ------------------------------- RESTORE -------------------------------------
do_restore() {
  info "Removing CNPA 5.3 lab artifacts from: $BACKSTAGE_DIR"
  [[ -d "$LAB_DIR" ]] && { rm -rf "$LAB_DIR"; ok "Removed $LAB_DIR"; }
  [[ -f "$DEDICATED_CFG" ]] && { rm -f "$DEDICATED_CFG"; ok "Removed $DEDICATED_CFG"; }
  if [[ -f "$LOCAL_CFG" ]] && grep -qF "$MARK_BEGIN" "$LOCAL_CFG"; then
    sed -i.bak "/$(printf '%s' "$MARK_BEGIN" | sed 's/[][\/.*^$]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[][\/.*^$]/\\&/g')/d" "$LOCAL_CFG"
    rm -f "$LOCAL_CFG.bak"
    # Drop the file if it is now empty (only blank lines left).
    grep -Eq '[^[:space:]]' "$LOCAL_CFG" || rm -f "$LOCAL_CFG"
    ok "Stripped lab block from $LOCAL_CFG"
  fi
  ok "Clean. Restart the portal to drop the lab location from the running catalog."
}

# --------------------------------- main --------------------------------------
case "$ACTION" in
  help)    usage        ;;
  break)   do_break     ;;
  check)   do_check     ;;
  restore) do_restore   ;;
esac
exit 0

# ==============================================================================
#  ┌──────────────────────────────────────────────────────────────────────────┐
#  │  SOLUTION — step by step. Try the exercise before reading this.            │
#  └──────────────────────────────────────────────────────────────────────────┘
#
#  ROOT CAUSE
#    Backstage validates every catalog entity against the descriptor schema
#    BEFORE it enters the catalog. `metadata.name` is an *entity name* and must
#    obey the naming rules: only [A-Za-z0-9], the separators [-_.], length ≤ 63,
#    and it must start and end with an alphanumeric. Spaces and the pattern used
#    ("Payments API Gateway") are invalid, so the parser raises an InputError and
#    the entity is discarded — the location is processed, the file is read, but
#    the entity is refused. That is why the portal is otherwise healthy yet this
#    one component is simply absent.
#    Docs: https://backstage.io/docs/features/software-catalog/descriptor-format
#          https://backstage.io/docs/features/software-catalog/references
#
#  STEP 1 — Read the backend log and locate the failing entity.
#    The startup log names the offending location and value:
#      backstage:catalog InputError: Malformed envelope, .metadata.name
#      "Payments API Gateway" is not a valid entity name; expected a string that
#      is sequences of [a-zA-Z0-9] separated by [-_.], at most 63 characters ...
#    (If your app exposes it, the same error is visible in the UI under the
#     component's INSPECT ▸ errors, or Catalog ▸ location health.)
#
#  STEP 2 — Open the descriptor.
#      $EDITOR examples/cnpa-5.3-lab/broken-entity.yaml
#
#  STEP 3 — Fix metadata.name to a valid entity name (kebab-case is the norm):
#
#      apiVersion: backstage.io/v1alpha1
#      kind: Component
#      metadata:
#        name: payments-api-gateway        # <-- lowercase, hyphens, no spaces
#        description: Public payments ingress — CNPA 5.3 lab component
#        tags: [cnpa, lab]
#        annotations:
#          backstage.io/techdocs-ref: dir:.
#      spec:
#        type: service
#        lifecycle: production
#        owner: platform-team
#        system: payments
#
#    Keep the human-friendly label separate from the identifier if you want the
#    UI to still read "Payments API Gateway":
#        metadata:
#          name: payments-api-gateway
#          title: Payments API Gateway     # display-only, no character restriction
#
#  STEP 4 — Let the catalog reprocess.
#    The catalog re-reads locations on its refresh interval (default ~100s).
#    To see it immediately, restart the backend so it reprocesses on startup:
#        cd "$BACKSTAGE_DIR" && yarn start
#    (If you registered via the dedicated file, restart with the same
#     --config flags that break_fix.sh printed in the briefing.)
#
#  STEP 5 — Verify.
#      # UI: http://localhost:3000 → Catalog → search "payments" → the component
#      #     "Payments API Gateway" (name payments-api-gateway) is now listed.
#      # API:
#      curl -s -o /dev/null -w '%{http_code}\n' \
#        http://localhost:7007/api/catalog/entities/by-name/component/default/payments-api-gateway
#      #   → 200
#      # Or let the script judge it:
#      ./break_fix.sh --check          # expect: FIXED 🎉
#
#  STEP 6 — Tear down the lab when you are done.
#      ./break_fix.sh --restore
#
#  WHY THIS MATTERS FOR PLATFORM ADOPTION (the CNPA 5.3 lesson)
#    A developer portal is only adopted if self-service onboarding "just works".
#    The single most common reason a newly-registered service never appears is a
#    descriptor that fails schema validation — an invalid name, a missing
#    required spec field (type/lifecycle/owner for a Component), or an unknown
#    apiVersion. As a platform engineer you (a) surface these errors where the
#    developer will see them (location health / entity errors, not just backend
#    logs), and (b) shift them left with CI validation on the catalog-info.yaml
#    before merge — e.g. the Backstage CLI:
#        npx @backstage/cli repo lint            # repo-wide checks
#        # or a schema/CI step that rejects invalid catalog-info.yaml on PR.
#    Config reference for static & discovered locations:
#        https://backstage.io/docs/features/software-catalog/configuration
# ==============================================================================