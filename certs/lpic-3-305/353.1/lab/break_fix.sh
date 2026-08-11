#!/usr/bin/env bash
#
# =============================================================================
# LPIC-3 305  —  Exam 305-300 (Objectives version 3.0)
# Topic 353.1: Cloud Management Tools   (exam weight: 3.33)
# -----------------------------------------------------------------------------
# BREAK & FIX LAB  —  OpenStack unified client configuration (clouds.yaml)
#
# Objective mapping (353.1): configure and drive an OpenStack cloud with the
# unified 'openstack' CLI / openstacksdk, whose behaviour is governed by the
# clouds.yaml configuration file and its auth plugins.
#
# What this lab does: it lays down a WORKING isolated OpenStack client config,
# proves it is valid, then deliberately introduces ONE realistic configuration
# fault. Your job is to diagnose the symptom and repair the file. The complete
# step-by-step solution is at the very bottom of this file, commented out.
#
# SAFE BY DESIGN: everything lives under ~/openstack-lab and is selected via the
# OS_CLIENT_CONFIG_FILE environment variable, so your real
# ~/.config/openstack/clouds.yaml is never read or modified. Run it on a
# DISPOSABLE lab VM anyway — that is the intended target.
#
# Sources (official):
#   - LPI 305-300 objectives: https://www.lpi.org/our-certifications/exam-305-objectives/
#   - clouds.yaml / config:   https://docs.openstack.org/openstacksdk/latest/user/config/configuration.html
#   - openstack CLI config:   https://docs.openstack.org/python-openstackclient/latest/configuration/index.html
#   - Password auth plugin:   https://docs.openstack.org/keystoneauth/latest/authentication-plugins.html
# =============================================================================

set -u

# ---- constants -------------------------------------------------------------
LAB_DIR="${HOME}/openstack-lab"
CLOUDS="${LAB_DIR}/clouds.yaml"
CHECK="${LAB_DIR}/check-lab.sh"
CLOUD_NAME="lab"
export OS_CLIENT_CONFIG_FILE="${CLOUDS}"

# ---- tiny output helpers ---------------------------------------------------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'; Z=$'\033[0m'
else B=""; G=""; R=""; Y=""; C=""; Z=""; fi
say()  { printf '%s\n' "$*"; }
head1(){ printf '\n%s%s%s\n' "$B" "$*" "$Z"; }

# ---- safety guard ----------------------------------------------------------
if [ "${LPIC_LAB_CONFIRM:-}" != "yes" ]; then
  say "${Y}This script DELIBERATELY BREAKS an OpenStack client configuration for practice.${Z}"
  say ""
  say "It is fully isolated to:   ${LAB_DIR}"
  say "selected via OS_CLIENT_CONFIG_FILE, so your real"
  say "~/.config/openstack/clouds.yaml is NOT touched."
  say ""
  say "Run it ONLY on a disposable lab VM. To proceed:"
  say ""
  say "    ${C}LPIC_LAB_CONFIRM=yes $0${Z}"
  say ""
  exit 1
fi

# ---- best-effort tooling install (non-fatal) -------------------------------
ensure_tools() {
  if python3 -c 'import openstack' >/dev/null 2>&1; then return 0; fi
  say "${Y}[*] openstacksdk not found — attempting a best-effort install...${Z}"
  local APT="apt-get"
  [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && APT="sudo apt-get"
  if command -v apt-get >/dev/null 2>&1; then
    $APT update -qq >/dev/null 2>&1
    $APT install -y python3-openstacksdk python3-openstackclient >/dev/null 2>&1
  fi
  if ! python3 -c 'import openstack' >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
    pip3 install --user --quiet openstacksdk python-openstackclient >/dev/null 2>&1
  fi
  if python3 -c 'import openstack' >/dev/null 2>&1; then
    say "${G}[*] openstacksdk is available.${Z}"
  else
    say "${Y}[!] Could not install openstacksdk. The lab will fall back to a"
    say "    grep-based structural check — that is fine for this exercise.${Z}"
  fi
  return 0
}

# ---- authoritative offline PASS/FAIL checker (written to disk) -------------
write_checker() {
  cat > "${CHECK}" <<'CHECKSCRIPT_EOF'
#!/usr/bin/env bash
# Offline PASS/FAIL check for the OpenStack 'lab' cloud (no network needed).
export OS_CLIENT_CONFIG_FILE="${OS_CLIENT_CONFIG_FILE:-$HOME/openstack-lab/clouds.yaml}"
CLOUDS="$OS_CLIENT_CONFIG_FILE"

py_out="$(python3 - <<'PY'
import sys
try:
    from openstack.config import OpenStackConfig
except Exception:
    sys.exit(3)                      # SDK unavailable -> caller uses grep fallback
try:
    cloud = OpenStackConfig().get_one("lab")
except Exception as e:
    print("loader error: %s" % e); sys.exit(1)
auth = dict(cloud.config.get("auth") or {})
req = ["auth_url", "username", "password", "project_name"]
missing = [k for k in req if not auth.get(k)]
if missing:
    print("credentials NOT found under an 'auth:' mapping; missing: " + ", ".join(missing))
    sys.exit(1)
print("auth_url=%s  username=%s  project=%s" %
      (auth["auth_url"], auth["username"], auth["project_name"]))
sys.exit(0)
PY
)"
rc=$?

if [ "$rc" -eq 3 ]; then
  if grep -qE '^[[:space:]]+auth:[[:space:]]*$' "$CLOUDS" \
     && grep -qE '^[[:space:]]{6,}auth_url:' "$CLOUDS"; then
    echo "PASS (grep): an 'auth:' block contains a nested auth_url."
    exit 0
  fi
  echo "FAIL (grep): no 'auth:' block with a nested auth_url in $CLOUDS."
  exit 1
fi

if [ "$rc" -eq 0 ]; then
  echo "PASS: cloud 'lab' has a complete auth section -> $py_out"
else
  echo "FAIL: $py_out"
fi
exit $rc
CHECKSCRIPT_EOF
  chmod +x "${CHECK}"
}

# ---- the two states of the config file -------------------------------------
write_good_config() {
  cat > "${CLOUDS}" <<'YAML'
clouds:
  lab:
    region_name: RegionOne
    identity_api_version: 3
    auth:
      auth_url: https://keystone.lab.example.internal:5000/v3
      username: labadmin
      password: "s3cr3t-lab-pw"
      project_name: labproject
      user_domain_name: Default
      project_domain_name: Default
YAML
  chmod 600 "${CLOUDS}"
}

write_broken_config() {
  # THE FAULT: the six credential keys are hoisted to the cloud's top level.
  # There is NO 'auth:' sub-mapping, so the password auth plugin finds nothing.
  cat > "${CLOUDS}" <<'YAML'
clouds:
  lab:
    region_name: RegionOne
    identity_api_version: 3
    auth_url: https://keystone.lab.example.internal:5000/v3
    username: labadmin
    password: "s3cr3t-lab-pw"
    project_name: labproject
    user_domain_name: Default
    project_domain_name: Default
YAML
  chmod 600 "${CLOUDS}"
}

# ---- show the symptom through the REAL tool --------------------------------
show_cli_symptom() {
  command -v openstack >/dev/null 2>&1 || return 0
  say "${C}\$ openstack --os-cloud ${CLOUD_NAME} token issue${Z}"
  openstack --os-cloud "${CLOUD_NAME}" token issue 2>&1 | head -n 6 | sed 's/^/    /'
}

# ===========================================================================
# MAIN
# ===========================================================================
mkdir -p "${LAB_DIR}"
ensure_tools
write_checker

head1 "[1/3] Building a WORKING OpenStack client config"
write_good_config
say "Wrote ${CLOUDS}"
say "Baseline verification:"
bash "${CHECK}" | sed 's/^/    /'

head1 "[2/3] Breaking it (one controlled fault)"
write_broken_config
say "The file ${CLOUDS} has been altered."

head1 "[3/3] Reproduce the failure"
say "Offline check now reports:"
bash "${CHECK}" | sed 's/^/    /'
say ""
say "And the real client reports:"
show_cli_symptom

# ---- brief the student -----------------------------------------------------
cat <<BRIEF

${B}================ YOUR MISSION ================${Z}

${B}SYMPTOM${Z}
  Any 'openstack' command against this cloud aborts immediately — before any
  network traffic — with:

      ${R}Missing value auth-url required for auth plugin password${Z}

  ...even though a line that clearly contains an auth URL, a username and a
  password is sitting right there in ${CLOUDS}.
  The offline checker (${CHECK##*/}) reports FAIL for the same reason.

${B}WHAT YOU MUST ACHIEVE${Z}
  Repair ${CLOUDS} so that BOTH of these succeed:

    1) ${C}bash ${CHECK}${Z}
       must print:  ${G}PASS: cloud 'lab' has a complete auth section ...${Z}

    2) ${C}openstack --os-cloud ${CLOUD_NAME} token issue${Z}
       must no longer print "Missing value auth-url ...".
       (There is no real cloud behind the endpoint, so it will then fail while
        trying to REACH keystone.lab.example.internal — a connection/timeout
        error. That transition is exactly the proof that your CLIENT-side
        configuration is now valid. Press Ctrl-C if it hangs on the connection.)

${B}HINTS${Z}
  * Read the error literally: the tool is looking for auth-url in a place it is
    not finding it. WHERE does the password auth plugin expect credentials?
  * Compare your file against the clouds.yaml schema in the official docs:
      https://docs.openstack.org/openstacksdk/latest/user/config/configuration.html
  * Look at the INDENTATION and the mapping the credential keys belong to.
  * You may edit the file by hand, or re-run this script anytime to reset the
    lab to its broken starting state:  ${C}LPIC_LAB_CONFIRM=yes $0${Z}

${B}=============================================${Z}

BRIEF

exit 0

# ===========================================================================
# SOLUTION  —  step by step  (do not read until you have tried it)
# ===========================================================================
#
# ROOT CAUSE
#   The unified OpenStack client (openstacksdk / os-client-config) does NOT read
#   credentials from the top level of a cloud entry. The password auth plugin
#   reads auth_url, username, password, project_name, user_domain_name and
#   project_domain_name from a dedicated 'auth:' sub-mapping of the cloud.
#   In the broken file those six keys were hoisted up to the same level as
#   region_name (directly under 'lab:'), and there is no 'auth:' block at all.
#   With an empty auth section, the plugin has no auth_url, so keystoneauth
#   raises MissingRequiredOptions BEFORE any HTTP request is attempted — hence:
#       "Missing value auth-url required for auth plugin password"
#   Reference:
#     https://docs.openstack.org/openstacksdk/latest/user/config/configuration.html
#     https://docs.openstack.org/keystoneauth/latest/authentication-plugins.html
#
# STEP 1 — Look at the broken file and spot that the credentials are NOT nested:
#     cat ~/openstack-lab/clouds.yaml
#   Notice auth_url/username/password/project_name are indented with 4 spaces
#   (siblings of region_name), and there is no 'auth:' key anywhere.
#
# STEP 2 — Reintroduce the 'auth:' mapping and indent the six credential keys
#   one level deeper (6 spaces) so they live under it. The corrected file:
#
#     clouds:
#       lab:
#         region_name: RegionOne
#         identity_api_version: 3
#         auth:
#           auth_url: https://keystone.lab.example.internal:5000/v3
#           username: labadmin
#           password: "s3cr3t-lab-pw"
#           project_name: labproject
#           user_domain_name: Default
#           project_domain_name: Default
#
#   Do it non-interactively (idempotent) if you prefer:
#
#     install -m 600 /dev/stdin ~/openstack-lab/clouds.yaml <<'FIX'
#     clouds:
#       lab:
#         region_name: RegionOne
#         identity_api_version: 3
#         auth:
#           auth_url: https://keystone.lab.example.internal:5000/v3
#           username: labadmin
#           password: "s3cr3t-lab-pw"
#           project_name: labproject
#           user_domain_name: Default
#           project_domain_name: Default
#     FIX
#
# STEP 3 — Verify offline (the authoritative success criterion):
#     bash ~/openstack-lab/check-lab.sh
#   Expected:
#     PASS: cloud 'lab' has a complete auth section -> auth_url=... username=labadmin project=labproject
#
# STEP 4 — Confirm with the real tool. The client-side config error is gone;
#   it now fails only while trying to reach the (fake) endpoint, which proves
#   the configuration itself is valid:
#     export OS_CLIENT_CONFIG_FILE=~/openstack-lab/clouds.yaml
#     openstack --os-cloud lab token issue        # now a CONNECTION error, not a config error
#   (On a real cloud this returns a scoped token. Ctrl-C if it hangs.)
#
# STEP 5 — Inspect the merged configuration the client actually uses. Note that
#   --os-cloud and the OS_CLOUD environment variable are interchangeable:
#     OS_CLOUD=lab openstack configuration show          # password stays masked
#     OS_CLOUD=lab openstack configuration show --unmask # reveals the password — handle with care
#
# KEY TAKEAWAY
#   In clouds.yaml the connection metadata (region_name, identity_api_version,
#   interface, cacert, ...) lives at the cloud level, but every credential the
#   auth plugin needs MUST be nested under 'auth:'. A misplaced or missing
#   'auth:' block produces a "Missing value auth-url ..." error that looks like
#   a missing value even when the value is present at the wrong depth.
# ===========================================================================