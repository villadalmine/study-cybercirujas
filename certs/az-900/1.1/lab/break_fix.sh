#!/usr/bin/env bash
#
# ==============================================================================
#  AZ-900 — Microsoft Azure Fundamentals (exam version 2026-07-20)
#  Domain 1 "Describe cloud concepts"
#  Topic  1.1 "Describe cloud computing"            (exam weight: 9.4)
# ==============================================================================
#
#  BREAK & FIX laboratory.
#
#  This script deploys a small, self-contained simulation of an Azure
#  subscription on a DISPOSABLE lab VM, then injects three controlled faults —
#  one per sub-objective of topic 1.1:
#
#     Fault 1 -> shared responsibility model   (who fixes what)
#     Fault 2 -> cloud deployment models       (public / private / hybrid, Arc)
#     Fault 3 -> consumption-based model       (CapEx vs OpEx, budgets, sizing)
#
#  SAFETY CONTRACT — read before running:
#     * It never calls Azure, never authenticates, never spends real money.
#       Every dollar figure is produced by a local metering loop.
#     * It never uses sudo, never installs packages, never edits /etc,
#       never touches firewall rules, systemd units or your DNS.
#     * Every file it creates lives under $LAB_ROOT (default
#       ~/az900-lab/1.1-describe-cloud-computing) and every socket it opens is
#       bound to 127.0.0.1 on an ephemeral high port.
#     * `cleanup` removes all of it, processes included.
#     * It refuses to run as root unless you insist (AZ900_ALLOW_ROOT=1),
#       because the file-permission lesson only works as an unprivileged user.
#
#  Official references (verify every claim against these, not against me):
#     https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
#     https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility
#     https://learn.microsoft.com/en-us/azure/azure-arc/overview
#     https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets
#     https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing
#     https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/overview
#     https://learn.microsoft.com/en-us/azure/advisor/advisor-reference-cost-recommendations
#
#  Usage:
#     ./az900-1.1-break-and-fix.sh              deploy + break + print the brief
#     ./az900-1.1-break-and-fix.sh status       dashboard of the whole estate
#     ./az900-1.1-break-and-fix.sh verify       grade your repair (exit 0 = done)
#     ./az900-1.1-break-and-fix.sh hint         progressive hints, no spoilers
#     ./az900-1.1-break-and-fix.sh solution     print the commented walkthrough
#     ./az900-1.1-break-and-fix.sh cleanup      destroy everything
#
# ==============================================================================

set -Eeuo pipefail

LAB_ROOT="${AZ900_LAB_ROOT:-$HOME/az900-lab/1.1-describe-cloud-computing}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

BIN="$LAB_ROOT/bin"
STATE="$LAB_ROOT/state"
LOGS="$LAB_ROOT/logs"
RUN="$LAB_ROOT/run"
PROVIDER="$LAB_ROOT/provider"
CUSTOMER="$LAB_ROOT/customer"
HYBRID="$LAB_ROOT/hybrid"
BILLING="$LAB_ROOT/billing"

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'
C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
if [[ ! -t 1 ]]; then C_RED=; C_GRN=; C_YEL=; C_BLU=; C_BLD=; C_OFF=; fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s[lab]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
warn() { printf '%s[lab]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[lab] FATAL:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Guard rails. A break & fix lab that damages a real machine is not a lab.
# ------------------------------------------------------------------------------
guard() {
    if [[ $EUID -eq 0 && "${AZ900_ALLOW_ROOT:-0}" != "1" ]]; then
        die "refusing to run as root: root bypasses the file-mode checks this lab teaches.
       Re-run as a normal user, or force it with AZ900_ALLOW_ROOT=1."
    fi

    case "$LAB_ROOT" in
        /|/home|/home/*/|/root|/etc*|/usr*|/var|/var/*|/boot*|/opt|"$HOME")
            die "LAB_ROOT='$LAB_ROOT' is not a disposable sandbox. Aborting." ;;
    esac
    [[ "$LAB_ROOT" == *az900-lab* ]] || \
        die "LAB_ROOT must contain 'az900-lab' so cleanup can never delete the wrong tree."

    for tool in awk sed grep stat date python3; do
        command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
    done

    if [[ "${AZ900_LAB_YES:-0}" != "1" ]]; then
        if [[ ! -t 0 ]]; then
            die "non-interactive run: set AZ900_LAB_YES=1 to confirm this is a throw-away VM."
        fi
        say ""
        say "${C_BLD}This lab writes only under:${C_OFF} $LAB_ROOT"
        say "It starts three loopback-only background processes and injects three faults."
        say "It does NOT use sudo, does NOT contact Azure and does NOT spend money."
        read -r -p "Confirm this is a disposable lab VM [type: yes] > " answer
        [[ "$answer" == "yes" ]] || die "not confirmed; nothing was created."
    fi
}

# ------------------------------------------------------------------------------
# Port allocation — loopback only, never bound to 0.0.0.0.
# ------------------------------------------------------------------------------
port_free() {
    if { exec 3<>"/dev/tcp/127.0.0.1/$1"; } 2>/dev/null; then
        exec 3<&- ; exec 3>&-
        return 1
    fi
    return 0
}

pick_port() {
    local p="$1"
    while :; do
        port_free "$p" && { printf '%s' "$p"; return 0; }
        p=$((p + 1))
        [[ $p -lt 34999 ]] || die "no free loopback port in the 34000-34999 range"
    done
}

# ------------------------------------------------------------------------------
# Helper writer: prepends a shebang and a hard-coded LAB_ROOT to a heredoc body.
# ------------------------------------------------------------------------------
write_helper() {
    local name="$1" dest="$BIN/$1"
    {
        echo '#!/usr/bin/env bash'
        printf 'LAB_ROOT=%q\n' "$LAB_ROOT"
        cat
    } >"$dest"
    chmod 0755 "$dest"
}

# ==============================================================================
# DEPLOY — stand up the simulated subscription
# ==============================================================================
deploy() {
    [[ -f "$STATE/lab.state" ]] && { info "lab already deployed at $LAB_ROOT"; return 0; }

    info "provisioning simulated subscription under $LAB_ROOT"
    mkdir -p "$BIN" "$STATE" "$LOGS" "$RUN" \
             "$PROVIDER" \
             "$CUSTOMER/app/wwwroot" "$CUSTOMER/keys" \
             "$HYBRID/onprem-datastore" \
             "$BILLING/orphans/disks"

    local port_app port_onprem port_decoy
    port_app="$(pick_port 34110)"
    port_onprem="$(pick_port $((port_app + 1)))"
    port_decoy="$(pick_port $((port_onprem + 1)))"   # allocated, never bound: the decoy

    cat >"$STATE/ports.env" <<EOF
PORT_APP=$port_app
PORT_ONPREM=$port_onprem
PORT_DECOY=$port_decoy
EOF

    # -- shared library sourced by every helper -------------------------------
    write_helper lab-common.sh <<'EOS'
# Shared definitions for the AZ-900 1.1 break & fix lab.
PROVIDER="$LAB_ROOT/provider"
CUSTOMER="$LAB_ROOT/customer"
DOCROOT="$CUSTOMER/app/wwwroot"
KEYS="$CUSTOMER/keys"
HYBRID="$LAB_ROOT/hybrid"
BILLING="$LAB_ROOT/billing"
ORPHANS="$BILLING/orphans"
STATE="$LAB_ROOT/state"
LOGS="$LAB_ROOT/logs"
RUN="$LAB_ROOT/run"
BIN="$LAB_ROOT/bin"

APP_CFG="$CUSTOMER/app/config.env"
ARC_CFG="$HYBRID/arc-connector.conf"
BUDGET_CFG="$BILLING/budget.conf"
DEK="$KEYS/dek.key"

WORKLOAD_MARKER="AZ900-1.1-WORKLOAD-OK"
HYBRID_MARKER="AZ900-1.1-HYBRID-OK"

# Managed disk, Premium SSD P-series, list price flattened to USD per GB-hour.
DISK_USD_GB_HOUR=0.000186
HOURS_PER_MONTH=730

if [ -f "$STATE/ports.env" ]; then . "$STATE/ports.env"; fi

# Illustrative pay-as-you-go list prices (East US, Linux, no reservation).
# Always price a real design with https://azure.microsoft.com/pricing/calculator/
# sku_spec NAME -> "vCPU  RAM_GiB  USD_per_hour"
sku_spec() {
    case "$1" in
        Standard_B1s)     echo "1  1   0.0104" ;;
        Standard_B2s)     echo "2  4   0.0416" ;;
        Standard_D2s_v5)  echo "2  8   0.0960" ;;
        Standard_D8s_v5)  echo "8  32  0.3840" ;;
        Standard_D64s_v5) echo "64 256 3.0720" ;;
        *)                echo "0  0   0.0000" ;;
    esac
}
sku_vcpu() { sku_spec "$1" | awk '{print $1}'; }
sku_ram()  { sku_spec "$1" | awk '{print $2}'; }
sku_rate() { sku_spec "$1" | awk '{print $3}'; }

cfg_get() {
    [ -f "$1" ] || return 0
    awk -F'=' -v k="$2" '
        $0 !~ /^[[:space:]]*#/ && $1 == k { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }
    ' "$1"
}

cfg_set() {
    local f="$1" k="$2" v="$3"
    if grep -qE "^$k=" "$f" 2>/dev/null; then
        sed -i "s|^$k=.*|$k=$v|" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >>"$f"
    fi
}

pid_alive() { [ -s "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

pid_stop() {
    local f="$1" p
    [ -s "$f" ] || return 0
    p="$(cat "$f")"
    if kill -0 "$p" 2>/dev/null; then
        kill "$p" 2>/dev/null || true
        sleep 0.4
        kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || true
    fi
    rm -f "$f"
}

# HTTP GET with curl when available, otherwise bash's /dev/tcp — zero deps.
http_get() {
    local host="$1" port="$2" path="$3" resp
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 3 "http://$host:$port$path" 2>/dev/null
        return
    fi
    { exec 3<>"/dev/tcp/$host/$port"; } 2>/dev/null || return 1
    printf 'GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$path" "$host" >&3
    resp="$(cat <&3)"
    exec 3<&- ; exec 3>&-
    case "$resp" in
        *' 200 '*) printf '%s' "${resp#*$'\r\n\r\n'}" ;;
        *) return 1 ;;
    esac
}

orphan_disk_gb() {
    local total=0 f gb
    for f in "$ORPHANS"/disks/*.disk; do
        [ -e "$f" ] || continue
        gb="$(cfg_get "$f" SIZE_GB)"
        total=$(( total + ${gb:-0} ))
    done
    printf '%s' "$total"
}

# current_burn -> "compute_h  disk_h  orphan_h  total_h  forecast_month"
# NOTE (exam-relevant): compute is billed while the VM resource is ALLOCATED.
# A workload you merely stopped is "Stopped (allocated)" and still bills compute;
# only "Stopped (deallocated)" releases it. So you cannot fix a budget by
# killing the process. See .../virtual-machines/states-billing
current_burn() {
    local sku rate gb orate osku
    sku="$(cfg_get "$APP_CFG" SKU)"
    rate="$(sku_rate "$sku")"
    gb="$(orphan_disk_gb)"
    orate=0
    if pid_alive "$ORPHANS/compute.pid"; then
        osku="$(cfg_get "$ORPHANS/orphan-vm.env" SKU)"
        orate="$(sku_rate "$osku")"
    fi
    awk -v c="$rate" -v g="$gb" -v dr="$DISK_USD_GB_HOUR" -v o="$orate" -v h="$HOURS_PER_MONTH" \
        'BEGIN { d = g * dr; t = c + d + o; printf "%.4f %.4f %.4f %.4f %.2f\n", c, d, o, t, t * h }'
}
EOS

    # -- provider plane: Microsoft-managed layers, immutable to the tenant ----
    cat >"$PROVIDER/fabric.status" <<'EOF'
# Azure platform health — MICROSOFT-MANAGED LAYERS
# Region: eastus2 | Scope: physical datacenter, network fabric, physical hosts
# You have no operational access to anything on this page. If one of these is
# degraded your only action is to open a support request and wait.
# https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility
physical_datacenter=Healthy
physical_network=Healthy
physical_hosts=Healthy
hypervisor=Healthy
platform_storage=Healthy
platform_identity=Healthy
last_incident=none
EOF
    cat >"$PROVIDER/responsibility-matrix.txt" <<'EOF'
Shared responsibility, by service model (customer = C, Microsoft = M, shared = S)
                                   On-prem  IaaS  PaaS  SaaS
Information and data                  C       C     C     C
Devices (mobile and PCs)              C       C     C     C
Accounts and identities               C       C     C     C
Identity and directory infrastructure C       S     S     S
Applications                          C       C     S     M
Network controls                      C       C     S     M
Operating system                      C       C     M     M
Physical hosts / network / datacenter C       M     M     M

Your workload runs on IaaS. Data, identities, applications, network controls
and the guest OS are YOURS. Everything under the hypervisor is Microsoft's.
Source: https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility
EOF

    write_helper fabric-loop <<'EOS'
set -uo pipefail
. "$LAB_ROOT/bin/lab-common.sh"
n=0
while :; do
    printf '%s fabric=Healthy hypervisor=Healthy storage=Healthy network=Healthy region=eastus2 scope=microsoft-managed\n' \
        "$(date -u +%FT%TZ)" >>"$LOGS/fabric.log"
    n=$(( n + 1 ))
    if [ $(( n % 120 )) -eq 0 ]; then
        tail -n 500 "$LOGS/fabric.log" >"$LOGS/fabric.log.tmp" && mv "$LOGS/fabric.log.tmp" "$LOGS/fabric.log"
    fi
    sleep 5
done
EOS

    write_helper provider-status <<'EOS'
set -euo pipefail
. "$LAB_ROOT/bin/lab-common.sh"
echo "=== Azure platform status (Microsoft-managed) ================================"
grep -v '^#' "$PROVIDER/fabric.status" | sed 's/^/  /'
echo "  heartbeat: $(tail -n 1 "$LOGS/fabric.log" 2>/dev/null || echo 'no heartbeat')"
echo "  note     : green here says NOTHING about your guest OS, data or config."
EOS

    # -- customer plane: the tenant's IaaS workload ---------------------------
    cat >"$CUSTOMER/app/config.env" <<EOF
# Tenant-managed workload configuration (customer side of the boundary).
WORKLOAD=contoso-invoices-api
SKU=Standard_B2s
LOCATION=eastus2
BIND_ADDRESS=127.0.0.1
PORT=$port_app
# Documented minimum for this workload; sizing below it is not "right-sizing".
MIN_VCPU=2
MIN_RAM_GIB=4
# Customer-managed key policy: the data plane refuses to unseal without a DEK
# whose file mode is exactly 0600.
ENCRYPTION_AT_REST=required
EOF

    head -c 32 /dev/urandom | base64 >"$CUSTOMER/keys/dek.key"
    chmod 0600 "$CUSTOMER/keys/dek.key"

    cat >"$CUSTOMER/app/wwwroot/index.html" <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><title>contoso-invoices-api</title></head>
<body>
<h1>contoso-invoices-api</h1>
<p>status: serving</p>
<p>marker: $( : )AZ900-1.1-WORKLOAD-OK</p>
<p>tier: IaaS — guest OS, data and network controls are the customer's responsibility.</p>
</body></html>
EOF

    write_helper start-app <<'EOS'
set -euo pipefail
. "$LAB_ROOT/bin/lab-common.sh"

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOGS/app.log" >&2; }

if pid_alive "$RUN/app.pid"; then
    log "INFO  workload already running (pid $(cat "$RUN/app.pid"))"
    exit 0
fi

port="$(cfg_get "$APP_CFG" PORT)"
sku="$(cfg_get "$APP_CFG" SKU)"
policy="$(cfg_get "$APP_CFG" ENCRYPTION_AT_REST)"

if [ "$policy" = "required" ]; then
    if [ ! -s "$DEK" ]; then
        log "FATAL data plane sealed: ENCRYPTION_AT_REST=required but no customer-managed"
        log "FATAL key at $DEK — the platform cannot supply it for you (IaaS: data is yours)"
        exit 78
    fi
    mode="$(stat -c '%a' "$DEK")"
    if [ "$mode" != "600" ]; then
        log "FATAL customer-managed key present but mode is 0$mode; refusing to unseal."
        log "FATAL the DEK must be readable only by its owner (0600)."
        exit 77
    fi
fi

nohup python3 -m http.server "$port" --bind 127.0.0.1 --directory "$DOCROOT" \
    >>"$LOGS/app.log" 2>&1 &
echo $! >"$RUN/app.pid"
sleep 0.6
if pid_alive "$RUN/app.pid"; then
    log "INFO  data plane unlocked; workload listening on 127.0.0.1:$port (SKU $sku)"
else
    rm -f "$RUN/app.pid"
    log "FATAL workload failed to bind 127.0.0.1:$port"
    exit 1
fi
EOS

    write_helper stop-app <<'EOS'
set -euo pipefail
. "$LAB_ROOT/bin/lab-common.sh"
pid_stop "$RUN/app.pid"
printf '%s INFO  workload stopped — VM state is now "Stopped (allocated)": compute is STILL billed.\n' \
    "$(date -u +%FT%TZ)" | tee -a "$LOGS/app.log"
EOS

    # -- hybrid plane: the "on-premises" private cloud segment ---------------
    cat >"$HYBRID/onprem-datastore/hr-record.json" <<EOF
{
  "record_id": "EMP-4471",
  "classification": "on-premises",
  "datacenter": "contoso-dc1",
  "sovereignty": "regulated data that must not leave the private cloud segment",
  "marker": "AZ900-1.1-HYBRID-OK"
}
EOF

    cat >"$HYBRID/arc-connector.conf" <<EOF
# Azure Arc style connector: projects the on-premises segment into the
# subscription so a single control plane spans both.
# https://learn.microsoft.com/en-us/azure/azure-arc/overview
CONNECTOR_NAME=contoso-dc1-connector
RESOURCE_GROUP=rg-contoso-hybrid
# One of: public | private | hybrid | multicloud
DEPLOYMENT_MODEL=hybrid
ONPREM_ENDPOINT=127.0.0.1:$port_onprem
REQUIRED_RECORD=/hr-record.json
EOF

    write_helper hybrid-probe <<'EOS'
set -euo pipefail
. "$LAB_ROOT/bin/lab-common.sh"

name="$(cfg_get "$ARC_CFG" CONNECTOR_NAME)"
rg="$(cfg_get "$ARC_CFG" RESOURCE_GROUP)"
model="$(cfg_get "$ARC_CFG" DEPLOYMENT_MODEL)"
ep="$(cfg_get "$ARC_CFG" ONPREM_ENDPOINT)"
rec="$(cfg_get "$ARC_CFG" REQUIRED_RECORD)"
host="${ep%%:*}"; port="${ep##*:}"
rc=0

echo "=== Arc connector probe ======================================================"
printf '  connector        : %s (resource group %s)\n' "$name" "$rg"
printf '  declared model   : %s\n' "$model"
printf '  on-prem endpoint : %s\n' "$ep"

if [ "$model" != "hybrid" ]; then
    printf '  MODEL            : FAIL — declared "%s". A public-only subscription does not\n' "$model"
    printf '                     extend the control plane over the private segment.\n'
    rc=1
else
    printf '  MODEL            : ok\n'
fi

if body="$(http_get "$host" "$port" "$rec")"; then
    if printf '%s' "$body" | grep -q "$HYBRID_MARKER"; then
        printf '  CONNECTIVITY     : ok — record %s retrieved over the connector\n' \
            "$(printf '%s' "$body" | awk -F'"' '/record_id/{print $4}')"
    else
        printf '  CONNECTIVITY     : FAIL — endpoint answered but the payload is not the\n'
        printf '                     on-premises record (wrong segment?)\n'
        rc=1
    fi
else
    printf '  CONNECTIVITY     : FAIL — connection refused to %s\n' "$ep"
    printf '                     the private segment is up or down? prove it, do not guess.\n'
    rc=1
fi
[ "$rc" -eq 0 ] && echo "  VERDICT          : hybrid deployment healthy" \
                || echo "  VERDICT          : hybrid deployment BROKEN"
exit "$rc"
EOS

    # -- billing plane: the consumption meter --------------------------------
    cat >"$BILLING/budget.conf" <<'EOF'
# Cost Management budget, subscription scope, monthly reset.
# https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets
BUDGET_USD=50
ALERT_PCT=80
CURRENCY=USD
EOF
    : >"$BILLING/meter.jsonl"
    echo "0.000000" >"$BILLING/accrued.usd"

    write_helper meter-loop <<'EOS'
set -uo pipefail
. "$LAB_ROOT/bin/lab-common.sh"
TICK=2
n=0
while :; do
    set -- $(current_burn)
    c="$1"; d="$2"; o="$3"; t="$4"; f="$5"
    acc="$(cat "$BILLING/accrued.usd" 2>/dev/null || echo 0)"
    acc="$(awk -v a="$acc" -v t="$t" -v s="$TICK" 'BEGIN{printf "%.6f", a + t*s/3600}')"
    echo "$acc" >"$BILLING/accrued.usd"
    printf '{"timestamp":"%s","compute_usd_hour":%s,"storage_usd_hour":%s,"orphan_usd_hour":%s,"total_usd_hour":%s,"forecast_usd_month":%s,"accrued_usd":%s}\n' \
        "$(date -u +%FT%TZ)" "$c" "$d" "$o" "$t" "$f" "$acc" >>"$BILLING/meter.jsonl"
    n=$(( n + 1 ))
    if [ $(( n % 200 )) -eq 0 ]; then
        tail -n 1000 "$BILLING/meter.jsonl" >"$BILLING/meter.tmp" && mv "$BILLING/meter.tmp" "$BILLING/meter.jsonl"
    fi
    sleep "$TICK"
done
EOS

    write_helper budget-check <<'EOS'
set -euo pipefail
. "$LAB_ROOT/bin/lab-common.sh"

budget="$(cfg_get "$BUDGET_CFG" BUDGET_USD)"
pct="$(cfg_get "$BUDGET_CFG" ALERT_PCT)"
sku="$(cfg_get "$APP_CFG" SKU)"
gb="$(orphan_disk_gb)"
set -- $(current_burn)
c="$1"; d="$2"; o="$3"; t="$4"; f="$5"
threshold="$(awk -v b="$budget" -v p="$pct" 'BEGIN{printf "%.2f", b*p/100}')"
acc="$(cat "$BILLING/accrued.usd" 2>/dev/null || echo 0)"

echo "=== Cost Management — subscription scope, monthly =============================="
printf '  workload SKU        : %-18s (%s vCPU / %s GiB) @ $%s/h\n' \
    "$sku" "$(sku_vcpu "$sku")" "$(sku_ram "$sku")" "$c"
printf '  unattached disks    : %s GB @ $%s/GB-h -> $%s/h\n' "$gb" "$DISK_USD_GB_HOUR" "$d"
printf '  untagged orphan VM  : $%s/h\n' "$o"
printf '  ---------------------------------------------------------------\n'
printf '  burn rate           : $%s/hour\n' "$t"
printf '  forecast (730 h)    : $%s / month\n' "$f"
printf '  budget              : $%s   alert threshold %s%% = $%s\n' "$budget" "$pct" "$threshold"
printf '  accrued this session: $%s\n' "$acc"

if awk -v f="$f" -v th="$threshold" 'BEGIN{exit !(f >= th)}'; then
    printf '  STATUS              : ALERT — forecast crosses the budget alert threshold.\n'
    printf '                        OpEx is metered per second: idle waste is real spend.\n'
    exit 1
fi
printf '  STATUS              : ok — forecast is under the alert threshold\n'
EOS

    write_helper orphan-vm <<'EOS'
set -uo pipefail
# Simulated forgotten VM: it does no work and burns no real CPU, it only exists
# so the meter can bill it. That is exactly the point.
while :; do sleep 60; done
EOS

    write_helper lab-status <<'EOS'
set -euo pipefail
. "$LAB_ROOT/bin/lab-common.sh"
st() { if pid_alive "$1"; then printf 'running (pid %s)' "$(cat "$1")"; else printf 'DOWN'; fi; }

echo
echo "########## AZ-900 1.1 — simulated subscription ################################"
"$BIN/provider-status"
echo
echo "=== Customer plane (your responsibility) ======================================"
printf '  workload           : %s\n' "$(st "$RUN/app.pid")"
printf '  endpoint           : http://127.0.0.1:%s/\n' "$(cfg_get "$APP_CFG" PORT)"
printf '  SKU                : %s\n' "$(cfg_get "$APP_CFG" SKU)"
printf '  encryption policy  : %s\n' "$(cfg_get "$APP_CFG" ENCRYPTION_AT_REST)"
if [ -s "$DEK" ]; then
    printf '  customer key (DEK) : present, mode 0%s\n' "$(stat -c '%a' "$DEK")"
else
    printf '  customer key (DEK) : MISSING at %s\n' "$DEK"
fi
printf '  last app log lines :\n'
tail -n 3 "$LOGS/app.log" 2>/dev/null | sed 's/^/    /' || echo '    (no log)'
echo
echo "=== Hybrid plane =============================================================="
printf '  on-prem listener   : %s\n' "$(st "$RUN/onprem.pid")"
printf '  declared model     : %s\n' "$(cfg_get "$ARC_CFG" DEPLOYMENT_MODEL)"
printf '  connector endpoint : %s\n' "$(cfg_get "$ARC_CFG" ONPREM_ENDPOINT)"
echo
echo "=== Billing plane ============================================================="
printf '  meter              : %s\n' "$(st "$RUN/meter.pid")"
"$BIN/budget-check" || true
echo "###############################################################################"
EOS

    # -- start the estate -----------------------------------------------------
    nohup "$BIN/fabric-loop" >>"$LOGS/fabric-loop.log" 2>&1 & echo $! >"$RUN/fabric.pid"
    nohup python3 -m http.server "$port_onprem" --bind 127.0.0.1 \
        --directory "$HYBRID/onprem-datastore" >>"$LOGS/onprem.log" 2>&1 &
    echo $! >"$RUN/onprem.pid"
    nohup "$BIN/meter-loop" >>"$LOGS/meter-loop.log" 2>&1 & echo $! >"$RUN/meter.pid"
    "$BIN/start-app" 2>>"$LOGS/app.log" || true

    chmod 0444 "$PROVIDER"/*.status "$PROVIDER"/*.txt
    chmod 0555 "$PROVIDER"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$PROVIDER/fabric.status" | awk '{print $1}' >"$STATE/provider.sha"
    fi

    echo "DEPLOYED" >"$STATE/lab.state"
    sleep 1
    info "estate is up and healthy — workload on http://127.0.0.1:$port_app/"
}

# ==============================================================================
# BREAK — three faults, one per sub-objective
# ==============================================================================
break_lab() {
    [[ -f "$STATE/lab.state" ]] || die "nothing deployed; run '$SELF' first"
    . "$BIN/lab-common.sh"
    [[ "$(cat "$STATE/lab.state")" == "BROKEN" ]] && { warn "faults already injected"; return 0; }

    info "injecting fault 1/3 — shared responsibility boundary"
    mkdir -p "$KEYS/quarantine"
    mv "$DEK" "$KEYS/quarantine/dek.key.bak"
    chmod 0644 "$KEYS/quarantine/dek.key.bak"
    "$BIN/stop-app" >/dev/null 2>&1 || true
    "$BIN/start-app" >/dev/null 2>&1 || true    # generate the FATAL evidence in app.log
    printf '%s automation="nightly-key-rotation" action=quarantine target=%s result=moved restore=NOT_PERFORMED\n' \
        "$(date -u +%FT%TZ)" "$DEK" >>"$LOGS/change-audit.log"

    info "injecting fault 2/3 — deployment model"
    cfg_set "$ARC_CFG" DEPLOYMENT_MODEL public
    cfg_set "$ARC_CFG" ONPREM_ENDPOINT "127.0.0.1:$PORT_DECOY"
    printf '%s automation="connector-refresh" action=rewrite target=arc-connector.conf keys="DEPLOYMENT_MODEL,ONPREM_ENDPOINT"\n' \
        "$(date -u +%FT%TZ)" >>"$LOGS/change-audit.log"

    info "injecting fault 3/3 — consumption model"
    cfg_set "$APP_CFG" SKU Standard_D64s_v5
    local i
    for i in 1 2 3 4; do
        cat >"$ORPHANS/disks/pvc-legacy-migration-$i.disk" <<EOF
# Managed disk left behind by a migration. Detached disks bill in full.
DISK_NAME=pvc-legacy-migration-$i
SIZE_GB=512
TIER=Premium_SSD
ATTACHED_TO=none
CREATED_BY=migration-2026-06
EOF
    done
    cat >"$ORPHANS/orphan-vm.env" <<'EOF'
NAME=vm-loadtest-temp-01
SKU=Standard_D8s_v5
OWNER_TAG=none
PURPOSE=load test, "just for an afternoon", never deleted
EOF
    nohup "$BIN/orphan-vm" >/dev/null 2>&1 & echo $! >"$ORPHANS/compute.pid"
    printf '%s automation="loadtest-harness" action=provision target=vm-loadtest-temp-01 teardown=NOT_PERFORMED\n' \
        "$(date -u +%FT%TZ)" >>"$LOGS/change-audit.log"

    echo "BROKEN" >"$STATE/lab.state"
    sleep 1
    info "three faults live. Read the brief below."
}

# ==============================================================================
# BRIEF
# ==============================================================================
brief() {
    . "$BIN/lab-common.sh"
    cat >"$LAB_ROOT/README.txt" <<EOF
===============================================================================
AZ-900 | Domain 1 "Describe cloud concepts" | 1.1 "Describe cloud computing"
BREAK & FIX — three faults are live in your simulated subscription
===============================================================================
Subscription root : $LAB_ROOT
Your tooling      : $BIN/lab-status
                    $BIN/provider-status
                    $BIN/start-app      $BIN/stop-app
                    $BIN/hybrid-probe
                    $BIN/budget-check
Grade your work   : $SELF verify      (exit 0 = all three repaired)
Hints             : $SELF hint
Tear down         : $SELF cleanup

GROUND RULES
  * You may change anything under customer/, hybrid/ and billing/.
  * You may NOT change anything under provider/. Those are Microsoft-managed
    layers; in a real subscription you have no such access. The boundary is
    the lesson, not an obstacle.
  * Do not delete the meter, the on-premises listener or the workload to make
    a check pass. Every check re-proves the service actually works.

-------------------------------------------------------------------------------
INCIDENT 1 — "The workload is down, but the Azure status page is green"
-------------------------------------------------------------------------------
SYMPTOM
  curl http://127.0.0.1:$PORT_APP/  ->  connection refused.
  $BIN/provider-status reports every Microsoft-managed layer Healthy.
  Your first instinct will be to blame the platform. Resist it.

WHAT YOU MUST ESTABLISH
  Which side of the shared responsibility boundary this fault lives on, and
  why "the platform is healthy" and "my service is up" are unrelated claims.
  Read $PROVIDER/responsibility-matrix.txt: this workload is IaaS, so the
  guest OS, the application, the network controls, the identities AND THE DATA
  (including the keys that unseal it) are yours.

DONE WHEN
  The endpoint returns HTTP 200 with the workload marker, the customer-managed
  key is back where the policy expects it, its file mode is exactly 0600, and
  no readable copy of it is left lying around in a quarantine directory.

CONCEPT
  Shared responsibility model.
  https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility

-------------------------------------------------------------------------------
INCIDENT 2 — "The regulated record cannot be read since the connector refresh"
-------------------------------------------------------------------------------
SYMPTOM
  $BIN/hybrid-probe reports the subscription as a public-only deployment and
  the on-premises segment as unreachable (connection refused).
  The private segment itself was never touched.

WHAT YOU MUST ESTABLISH
  Whether the private cloud segment is actually down, or whether the control
  plane is simply pointed at nothing — and the difference between a public
  deployment, a private deployment and a hybrid one that spans both under a
  single control plane (that is what Azure Arc does).
  Prove where the segment is listening; do not assume. \`ss -ltnp\` and the
  pid files under $RUN are your evidence.

DONE WHEN
  hybrid-probe exits 0: the deployment model is declared hybrid AND the record
  EMP-4471 is retrieved through the connector from the real private segment.

CONCEPT
  Cloud deployment models — public, private, hybrid, multicloud; Azure Arc.
  https://learn.microsoft.com/en-us/azure/azure-arc/overview

-------------------------------------------------------------------------------
INCIDENT 3 — "Finance says next month's forecast is 40x the budget"
-------------------------------------------------------------------------------
SYMPTOM
  $BIN/budget-check exits 1 with an ALERT: the forecast crosses the budget
  alert threshold. The meter ($BILLING/meter.jsonl) keeps accruing every 2 s,
  whether or not anyone is using anything.

WHAT YOU MUST ESTABLISH
  Where the burn comes from, itemised, and why consumption-based pricing
  (OpEx) punishes idle resources in a way that a bought-and-paid-for server
  (CapEx) never did: nobody bills you again for a rack you already own.
  Note the trap: stopping the workload process does NOT stop compute charges.
  A VM that is "Stopped (allocated)" still bills; only deallocation releases
  the compute. So you cannot pass this by turning things off.

DONE WHEN
  budget-check exits 0, with:
    - no untagged orphan VM still allocated,
    - no unattached managed disks left,
    - the workload SKU right-sized: it must still meet the workload's
      documented minimum (MIN_VCPU / MIN_RAM_GIB in $APP_CFG),
      and the forecast must sit below the alert threshold.
  There is exactly one SKU in the price book that satisfies both.

CONCEPT
  Consumption-based model, CapEx vs OpEx, budgets, right-sizing.
  https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets
  https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing
===============================================================================
EOF
    cat "$LAB_ROOT/README.txt"
    say ""
    say "${C_BLD}Brief saved to:${C_OFF} $LAB_ROOT/README.txt"
    say "${C_BLD}Start here   :${C_OFF} $BIN/lab-status"
}

# ==============================================================================
# VERIFY
# ==============================================================================
PASS_N=0; FAIL_N=0
chk() {
    local ok="$1" title="$2" detail="${3:-}"
    if [[ "$ok" == "0" ]]; then
        printf '  %sPASS%s  %s\n' "$C_GRN" "$C_OFF" "$title"; PASS_N=$((PASS_N + 1))
    else
        printf '  %sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$title"; FAIL_N=$((FAIL_N + 1))
        [[ -n "$detail" ]] && printf '        %s\n' "$detail"
    fi
}

verify() {
    [[ -f "$BIN/lab-common.sh" ]] || die "nothing deployed; run '$SELF' first"
    . "$BIN/lab-common.sh"

    say ""
    say "=== Integrity ================================================================="
    local rc=0
    if [[ -f "$STATE/provider.sha" ]] && command -v sha256sum >/dev/null 2>&1; then
        local now; now="$(sha256sum "$PROVIDER/fabric.status" | awk '{print $1}')"
        [[ "$now" == "$(cat "$STATE/provider.sha")" ]] || rc=1
        chk "$rc" "Microsoft-managed layers untouched" \
            "you edited provider/ — in a real subscription that access does not exist."
    fi
    rc=0; pid_alive "$RUN/meter.pid" || rc=1
    chk "$rc" "cost meter still running" "restart it: nohup $BIN/meter-loop &"
    rc=0; pid_alive "$RUN/onprem.pid" || rc=1
    chk "$rc" "private segment listener still running" "you must not delete the segment to pass"

    say ""
    say "=== Incident 1 — shared responsibility ========================================"
    rc=0; pid_alive "$RUN/app.pid" || rc=1
    chk "$rc" "workload process running" "run $BIN/start-app and read what it says"

    rc=0
    local body=""
    body="$(http_get 127.0.0.1 "$(cfg_get "$APP_CFG" PORT)" / || true)"
    printf '%s' "$body" | grep -q "$WORKLOAD_MARKER" || rc=1
    chk "$rc" "endpoint serves the workload (HTTP 200 + marker)" \
        "curl -i http://127.0.0.1:$(cfg_get "$APP_CFG" PORT)/"

    rc=0; [[ -s "$DEK" ]] || rc=1
    chk "$rc" "customer-managed key present at customer/keys/dek.key" \
        "the platform will never restore your data keys for you"

    rc=0
    if [[ -s "$DEK" ]]; then [[ "$(stat -c '%a' "$DEK")" == "600" ]] || rc=1; else rc=1; fi
    chk "$rc" "key file mode is exactly 0600" "chmod 600 $DEK"

    rc=0
    if compgen -G "$KEYS/quarantine/*" >/dev/null 2>&1; then rc=1; fi
    chk "$rc" "no stray readable copy of the key left behind" \
        "a world-readable backup of a DEK is the same incident with extra steps: rm -f $KEYS/quarantine/*"

    say ""
    say "=== Incident 2 — deployment model ============================================="
    rc=0; [[ "$(cfg_get "$ARC_CFG" DEPLOYMENT_MODEL)" == "hybrid" ]] || rc=1
    chk "$rc" "subscription declared as a hybrid deployment" \
        "DEPLOYMENT_MODEL in $ARC_CFG"

    rc=0; [[ "$(cfg_get "$ARC_CFG" ONPREM_ENDPOINT)" == "127.0.0.1:$PORT_ONPREM" ]] || rc=1
    chk "$rc" "connector points at the real private segment" \
        "find where it listens: ss -ltnp | grep -E '3[0-9]{4}'  (pid in $RUN/onprem.pid)"

    rc=0; "$BIN/hybrid-probe" >/dev/null 2>&1 || rc=1
    chk "$rc" "record EMP-4471 retrieved over the connector" "$BIN/hybrid-probe"

    say ""
    say "=== Incident 3 — consumption-based model ======================================"
    rc=0; ! pid_alive "$ORPHANS/compute.pid" || rc=1
    chk "$rc" "untagged orphan VM deallocated" \
        "kill \$(cat $ORPHANS/compute.pid) && rm -f $ORPHANS/compute.pid"

    rc=0; compgen -G "$ORPHANS/disks/*.disk" >/dev/null 2>&1 && rc=1
    chk "$rc" "no unattached managed disks billing" "rm -f $ORPHANS/disks/*.disk"

    local sku minv minr
    sku="$(cfg_get "$APP_CFG" SKU)"
    minv="$(cfg_get "$APP_CFG" MIN_VCPU)"; minr="$(cfg_get "$APP_CFG" MIN_RAM_GIB)"
    rc=0
    awk -v r="$(sku_rate "$sku")" 'BEGIN{exit !(r > 0)}' || rc=1
    [[ $rc -eq 0 ]] && { [[ "$(sku_vcpu "$sku")" -ge "$minv" ]] || rc=1; }
    [[ $rc -eq 0 ]] && { [[ "$(sku_ram  "$sku")" -ge "$minr" ]] || rc=1; }
    chk "$rc" "SKU '$sku' still meets the documented minimum (${minv} vCPU / ${minr} GiB)" \
        "under-sizing below the requirement is not right-sizing; blanking the SKU is not either"

    rc=0; "$BIN/budget-check" >/dev/null 2>&1 || rc=1
    chk "$rc" "forecast under the budget alert threshold" "$BIN/budget-check"

    say ""
    say "==============================================================================="
    if [[ $FAIL_N -eq 0 ]]; then
        say "  ${C_GRN}${C_BLD}ALL CHECKS PASSED${C_OFF} ($PASS_N/$PASS_N)"
        say "  You separated a platform fault from a tenant fault, restored a hybrid"
        say "  control plane, and turned an OpEx forecast back under budget."
        say "  Now say out loud, in one sentence each: what Microsoft owns in IaaS,"
        say "  what hybrid buys you that public alone does not, and why idle resources"
        say "  cost money in the cloud and nothing on a server you already bought."
        say "==============================================================================="
        return 0
    fi
    say "  ${C_RED}${C_BLD}$FAIL_N check(s) failing${C_OFF}, $PASS_N passing."
    say "  Hints: $SELF hint    Full walkthrough: $SELF solution"
    say "==============================================================================="
    return 1
}

# ==============================================================================
# HINTS
# ==============================================================================
hints() {
    cat <<EOF

INCIDENT 1
  1. Green platform status covers physical hosts, fabric and hypervisor only.
     Ask the workload itself why it will not start: tail $LOGS/app.log
  2. Something moved a file that the workload refuses to run without.
     Read $LOGS/change-audit.log — automation logs its own crimes.
  3. Restoring the file is half the fix. The start-up policy also checks the
     file mode, and a copy left in quarantine is still an exposed key.

INCIDENT 2
  1. "Connection refused" means nothing is listening THERE. It does not mean
     the private segment is down. Prove which port it actually holds:
       ss -ltnp | grep python    /    cat $RUN/onprem.pid
  2. Two keys in $HYBRID/arc-connector.conf were rewritten, not one.
  3. A subscription declared "public" is not hybrid even when the wire works.

INCIDENT 3
  1. Itemise before you cut: $BIN/budget-check breaks the burn into compute,
     storage and orphan lines.
  2. Three separate wastes: a forgotten VM still allocated, detached disks that
     bill in full, and a workload provisioned 64 vCPU wide for a 2 vCPU job.
  3. Stopping the workload does not help — "Stopped (allocated)" still bills.
     Check MIN_VCPU / MIN_RAM_GIB in $CUSTOMER/app/config.env, then pick the
     cheapest SKU in the price book (bin/lab-common.sh, sku_spec) that meets it.

EOF
}

# ==============================================================================
# CLEANUP
# ==============================================================================
cleanup() {
    [[ "$LAB_ROOT" == *az900-lab* ]] || die "refusing to delete '$LAB_ROOT'"
    [[ -d "$LAB_ROOT" ]] || { info "nothing to clean"; return 0; }
    local f p
    for f in "$RUN"/*.pid "$BILLING/orphans/compute.pid"; do
        [[ -s "$f" ]] || continue
        p="$(cat "$f")"
        kill "$p" 2>/dev/null || true
        sleep 0.2
        kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || true
    done
    chmod -R u+rwX "$LAB_ROOT" 2>/dev/null || true
    rm -rf "$LAB_ROOT"
    info "lab destroyed: $LAB_ROOT (no system state was ever modified)"
}

usage() {
    sed -n '2,45p' "$SELF" | sed 's/^#//;s/^ //'
}

# ==============================================================================
# DISPATCH
# ==============================================================================
case "${1:-run}" in
    run)             guard; deploy; break_lab; brief ;;
    deploy)          guard; deploy ;;
    break)           break_lab; brief ;;
    brief|readme)    brief ;;
    status)          exec "$BIN/lab-status" ;;
    verify|check)    verify ;;
    hint|hints)      hints ;;
    solution)        sed -n '/^# === SOLUTION/,/^# === END SOLUTION/p' "$SELF" ;;
    cleanup|destroy) cleanup ;;
    -h|--help|help)  usage ;;
    *)               die "unknown command '$1' — try: $SELF --help" ;;
esac


# ==============================================================================
# === SOLUTION — step-by-step walkthrough (do not read until you have tried) ===
# ==============================================================================
#
# Throughout: LAB=~/az900-lab/1.1-describe-cloud-computing
#             PORT_APP / PORT_ONPREM are in $LAB/state/ports.env
#
# ------------------------------------------------------------------------------
# STEP 0 — Triage. Never fix before you know which side of the boundary you are on.
# ------------------------------------------------------------------------------
#   $ LAB=~/az900-lab/1.1-describe-cloud-computing
#   $ $LAB/bin/lab-status
#
#   Expected: provider layers all Healthy, workload DOWN, connector endpoint
#   pointing at a port nothing is listening on, budget-check in ALERT.
#
#   $ cat $LAB/logs/change-audit.log
#   ... automation="nightly-key-rotation" action=quarantine ... restore=NOT_PERFORMED
#   ... automation="connector-refresh"   action=rewrite  keys="DEPLOYMENT_MODEL,ONPREM_ENDPOINT"
#   ... automation="loadtest-harness"    action=provision teardown=NOT_PERFORMED
#
#   Three separate automations, three separate incidents. All three are on the
#   customer side of the shared responsibility model. The platform is green and
#   green is irrelevant to all of them.
#
# ------------------------------------------------------------------------------
# INCIDENT 1 — Shared responsibility: the data plane will not unseal
# ------------------------------------------------------------------------------
#   Confirm the symptom, do not take it on faith:
#     $ . $LAB/state/ports.env
#     $ curl -sS -m 3 http://127.0.0.1:$PORT_APP/ ; echo "rc=$?"
#     curl: (7) Failed to connect to 127.0.0.1 port 34110: Connection refused
#     rc=7
#
#   Confirm the platform is NOT the cause:
#     $ $LAB/bin/provider-status
#     physical_hosts=Healthy  hypervisor=Healthy  platform_storage=Healthy ...
#
#   Ask the workload why it refuses to start:
#     $ tail -n 5 $LAB/logs/app.log
#     ... FATAL data plane sealed: ENCRYPTION_AT_REST=required but no customer-managed
#     ... FATAL key at .../customer/keys/dek.key — the platform cannot supply it for you
#
#   Locate what the automation quarantined:
#     $ ls -l $LAB/customer/keys/quarantine/
#     -rw-r--r-- 1 you you 45 ... dek.key.bak      <-- note the mode: 0644, exposed
#
#   Restore it, with the correct mode, and leave no readable copy behind:
#     $ mv $LAB/customer/keys/quarantine/dek.key.bak $LAB/customer/keys/dek.key
#     $ chmod 600 $LAB/customer/keys/dek.key
#     $ rmdir $LAB/customer/keys/quarantine
#     $ $LAB/bin/start-app
#     ... INFO  data plane unlocked; workload listening on 127.0.0.1:34110 (SKU ...)
#
#   Verify with the client, not with the pid:
#     $ curl -s http://127.0.0.1:$PORT_APP/ | grep -o 'AZ900-1.1-WORKLOAD-OK'
#     AZ900-1.1-WORKLOAD-OK
#
#   WHY IT MATTERS FOR THE EXAM
#     This workload is IaaS. Per the shared responsibility model, Microsoft owns
#     the physical datacenter, the physical network, the physical hosts and the
#     hypervisor; the customer owns the data, the identities, the applications,
#     the network controls and the guest OS, and shares identity infrastructure.
#     Data and the keys that protect it are ALWAYS the customer's, in every
#     service model including SaaS. A green service-health page can therefore
#     coexist indefinitely with a totally dead tenant workload — and if you had
#     opened a support ticket here you would have waited for a fix that was
#     never Microsoft's to make.
#     https://learn.microsoft.com/en-us/azure/security/fundamentals/shared-responsibility
#
# ------------------------------------------------------------------------------
# INCIDENT 2 — Deployment model: hybrid demoted to public
# ------------------------------------------------------------------------------
#   Read the probe's own diagnosis first:
#     $ $LAB/bin/hybrid-probe
#     declared model   : public
#     on-prem endpoint : 127.0.0.1:34112
#     MODEL            : FAIL — declared "public" ...
#     CONNECTIVITY     : FAIL — connection refused to 127.0.0.1:34112
#
#   "Connection refused" is a claim about a port, not about a segment. Prove
#   where the private segment actually listens:
#     $ ss -ltnp | grep -F 127.0.0.1
#     LISTEN 0 5 127.0.0.1:34110 ... users:(("python3",pid=...))   <- the workload
#     LISTEN 0 5 127.0.0.1:34111 ... users:(("python3",pid=...))   <- the on-prem segment
#     $ cat $LAB/run/onprem.pid          # same pid, cross-checked
#     $ . $LAB/state/ports.env ; echo "$PORT_ONPREM"
#     34111
#
#   The segment was never down. Only the control plane's view of it was wrong.
#   Repair both rewritten keys:
#     $ sed -i "s|^DEPLOYMENT_MODEL=.*|DEPLOYMENT_MODEL=hybrid|" $LAB/hybrid/arc-connector.conf
#     $ sed -i "s|^ONPREM_ENDPOINT=.*|ONPREM_ENDPOINT=127.0.0.1:$PORT_ONPREM|" $LAB/hybrid/arc-connector.conf
#     $ $LAB/bin/hybrid-probe
#     MODEL            : ok
#     CONNECTIVITY     : ok — record EMP-4471 retrieved over the connector
#     VERDICT          : hybrid deployment healthy
#
#   WHY IT MATTERS FOR THE EXAM
#     Public cloud   : resources on shared infrastructure owned and operated by
#                      the provider; no capital expense, effectively unlimited
#                      elastic capacity, least control over the substrate.
#     Private cloud  : resources dedicated to one organisation, in your own
#                      datacenter or hosted; maximum control and the usual
#                      answer to data-sovereignty or legacy-hardware constraints;
#                      you pay CapEx and you carry the maintenance.
#     Hybrid cloud   : both, joined under one control plane, so a workload can
#                      keep regulated data on-premises while bursting compute
#                      into the public cloud. That joining is exactly what
#                      Azure Arc provides — it projects on-premises and other-
#                      cloud machines, Kubernetes clusters and data services
#                      into Azure Resource Manager so one set of policies, RBAC
#                      and inventory covers them all.
#     Multicloud     : more than one public provider at once, usually driven by
#                      acquisitions, vendor risk or a service only one of them
#                      offers.
#     The failure you just repaired is the classic hybrid failure: the private
#     segment is perfectly healthy and completely unreachable, because hybrid is
#     a property of the control plane, not of the servers.
#     https://learn.microsoft.com/en-us/azure/azure-arc/overview
#
# ------------------------------------------------------------------------------
# INCIDENT 3 — Consumption-based model: a 40x forecast
# ------------------------------------------------------------------------------
#   Itemise before cutting anything:
#     $ $LAB/bin/budget-check
#     workload SKU        : Standard_D64s_v5   (64 vCPU / 256 GiB) @ $3.0720/h
#     unattached disks    : 2048 GB @ $0.000186/GB-h -> $0.3809/h
#     untagged orphan VM  : $0.3840/h
#     burn rate           : $3.8369/hour
#     forecast (730 h)    : $2801.00 / month
#     budget              : $50   alert threshold 80% = $40.00
#     STATUS              : ALERT
#
#   Three independent wastes. Deal with each, cheapest to prove first.
#
#   (a) The forgotten load-test VM — still allocated, still billing:
#       $ cat $LAB/billing/orphans/orphan-vm.env
#       NAME=vm-loadtest-temp-01   SKU=Standard_D8s_v5   OWNER_TAG=none
#       $ kill "$(cat $LAB/billing/orphans/compute.pid)" && rm -f $LAB/billing/orphans/compute.pid
#
#   (b) The detached managed disks — a disk attached to nothing bills in full:
#       $ grep -H SIZE_GB $LAB/billing/orphans/disks/*.disk
#       $ rm -f $LAB/billing/orphans/disks/*.disk
#
#   (c) Right-size the workload. Read the documented minimum, then pick the
#       cheapest SKU that still meets it — right-sizing is not shrinking:
#       $ grep -E 'MIN_(VCPU|RAM_GIB)' $LAB/customer/app/config.env
#       MIN_VCPU=2
#       MIN_RAM_GIB=4
#       Price book (bin/lab-common.sh, sku_spec):
#         Standard_B1s      1 vCPU /   1 GiB / $0.0104 h -> below the minimum, rejected
#         Standard_B2s      2 vCPU /   4 GiB / $0.0416 h -> $30.37/month  <= meets both
#         Standard_D2s_v5   2 vCPU /   8 GiB / $0.0960 h -> $70.08/month, over budget
#         Standard_D8s_v5   8 vCPU /  32 GiB / $0.3840 h -> way over
#         Standard_D64s_v5 64 vCPU / 256 GiB / $3.0720 h -> the incident
#       $ sed -i 's|^SKU=.*|SKU=Standard_B2s|' $LAB/customer/app/config.env
#       $ $LAB/bin/stop-app && $LAB/bin/start-app     # resize needs a restart
#
#   Confirm the meter agrees (it recomputes from live state every 2 s):
#     $ $LAB/bin/budget-check
#     burn rate           : $0.0416/hour
#     forecast (730 h)    : $30.37 / month
#     STATUS              : ok — forecast is under the alert threshold
#     $ tail -n 1 $LAB/billing/meter.jsonl
#
#   WHY IT MATTERS FOR THE EXAM
#     Cloud is a consumption-based model: you pay per second or per hour of what
#     is provisioned, on demand, with no up-front purchase and no capacity you
#     bought and never used. That is the CapEx -> OpEx shift. A server you own
#     is a sunk capital cost that idles for free; a VM you forgot is an
#     operating expense that bills forever, and the same elasticity that lets
#     you scale up in seconds lets you overspend in seconds. Hence Cost
#     Management budgets with alert thresholds, resource tagging to establish
#     ownership, and Azure Advisor cost recommendations to surface under-used
#     and orphaned resources. Note the trap you were protected from: a VM that
#     is merely "Stopped (allocated)" still incurs compute charges; only
#     "Stopped (deallocated)" releases the compute, and its disks keep billing
#     regardless.
#     https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets
#     https://learn.microsoft.com/en-us/azure/virtual-machines/states-billing
#     https://learn.microsoft.com/en-us/azure/advisor/advisor-reference-cost-recommendations
#
# ------------------------------------------------------------------------------
# STEP 4 — Grade and tear down
# ------------------------------------------------------------------------------
#   $ ~/az900-1.1-break-and-fix.sh verify     # expect: ALL CHECKS PASSED, exit 0
#   $ ~/az900-1.1-break-and-fix.sh cleanup    # removes every process and file
#
# ------------------------------------------------------------------------------
# EXAM-DAY SUMMARY OF THE THREE FAULTS
# ------------------------------------------------------------------------------
#   1. Platform healthy + workload dead  -> shared responsibility. In IaaS you
#      own data, keys, identities, apps, network controls and the guest OS.
#      Data and identities are yours in EVERY model, up to and including SaaS.
#   2. Private segment healthy + unreachable -> deployment models. Hybrid is a
#      control-plane property (Azure Arc), not a property of the hardware;
#      public/private/hybrid/multicloud differ in who owns the substrate, what
#      you control, and where the data is allowed to sit.
#   3. Nothing broken, everything billing -> consumption-based model. OpEx meters
#      provisioned capacity, not useful work; budgets, tags, deallocation and
#      right-sizing are the controls, and "I stopped it" is not deallocation.
# === END SOLUTION =============================================================