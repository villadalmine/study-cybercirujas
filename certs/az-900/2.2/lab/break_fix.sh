#!/usr/bin/env bash
# =============================================================================
#  AZ-900 (exam version 2026-07-20)
#  Topic 2.2 - Describe Azure compute and networking services   [weight 9.62]
#
#  BREAK & FIX LAB - "The web server that is up but unreachable"
#
#  What this script does
#  ---------------------
#  1. Provisions a THROW-AWAY Azure lab: 1 VNet, 1 subnet, 2 NSGs (subnet level
#     and NIC level), 1 Standard public IP, 1 Ubuntu 22.04 B1s VM running nginx.
#  2. Injects ONE controlled fault (chosen at random unless you pass --fault N)
#     at the Azure control plane or inside the guest, and snapshots the exact
#     state needed to roll it back.
#  3. Tells the student the SYMPTOM and the SUCCESS CRITERIA - not the cause.
#  4. `verify` re-tests the success criteria. `restore` undoes the fault.
#     `teardown` deletes the whole resource group.
#
#  Why these four faults: they are the four different layers a "site is down"
#  ticket can live in, and AZ-900 2.2 is exactly the vocabulary you need to
#  tell them apart - compute (the VM and its guest), the NIC, the subnet, and
#  the NSG rule evaluation order between them.
#
#  Safety rails (read them, they are the reason this is safe to run)
#  -----------------------------------------------------------------
#  * Every write is scoped to ONE resource group that must carry the tag
#    purpose=az900-break-fix-lab. Without that tag the script refuses to touch
#    anything, so it cannot be pointed at a shared or production group.
#  * Inbound 22/80 are allowed ONLY from the public IP you are running from.
#  * No fault ever removes your SSH path and no fault disables the Azure VM
#    agent, so `az vm run-command` and the serial console always remain as an
#    out-of-band recovery channel.
#  * `teardown` is the only destructive verb and it requires typing DELETE.
#  * Cost: 1x Standard_B1s + 1x Standard public IP. Run `teardown` when done.
#
#  Requirements: bash 4+, Azure CLI >= 2.60, an SSH client, curl.
#               `az login` already done, and a subscription where you may
#               create and delete resource groups.
#
#  Official sources
#  ----------------
#  AZ-900 study guide.......... https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
#  Azure VMs overview.......... https://learn.microsoft.com/en-us/azure/virtual-machines/overview
#  Virtual network overview.... https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-overview
#  NSG - how it works.......... https://learn.microsoft.com/en-us/azure/virtual-network/network-security-groups-overview
#  Public IP addresses......... https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/public-ip-addresses
#  Network Watcher IP flow..... https://learn.microsoft.com/en-us/azure/network-watcher/network-watcher-ip-flow-verify-overview
#  Effective security rules.... https://learn.microsoft.com/en-us/azure/virtual-network/diagnose-network-traffic-filter-problem
#  Run Command................. https://learn.microsoft.com/en-us/azure/virtual-machines/linux/run-command
#  IP 168.63.129.16............ https://learn.microsoft.com/en-us/azure/virtual-network/what-is-ip-address-168-63-129-16
# =============================================================================

set -Eeuo pipefail

# ----------------------------------------------------------------------------- config
LAB_TAG_KEY="purpose"
LAB_TAG_VALUE="az900-break-fix-lab"

RG="${LAB_RG:-rg-az900-breakfix}"
LOCATION="${LAB_LOCATION:-eastus}"
VNET="lab-vnet"
SUBNET="snet-web"
VNET_CIDR="10.20.0.0/16"
SUBNET_CIDR="10.20.1.0/24"
NSG_NIC="nsg-nic-web"
NSG_SUBNET="nsg-snet-web"
VM="vm-web01"
VM_SIZE="${LAB_VM_SIZE:-Standard_B1s}"
VM_IMAGE="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"
ADMIN_USER="azureuser"
PIP_NAME="pip-web01"

# Names of the objects the fault injector creates. Anything matching these is
# lab-injected and safe to delete on restore.
FAULT_RULE_HTTP="lab-fault-deny-http-in"
FAULT_RULE_EGRESS="lab-fault-deny-egress"
PLATFORM_ALLOW_RULE="lab-allow-platform-168-63-129-16"

STATE_DIR="${LAB_STATE_DIR:-$HOME/.az900-topic-2.2-lab}"
STATE_FILE="$STATE_DIR/state.env"
CLOUD_INIT="$STATE_DIR/cloud-init.yaml"

# ----------------------------------------------------------------------------- ui
if [[ -t 1 ]]; then
  B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
else
  B=""; R=""; G=""; Y=""; C=""; N=""
fi
log()  { printf '%s[lab]%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s[ ok]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[  !]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s[err]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
rule() { printf '%s\n' "-------------------------------------------------------------------------------"; }

trap 'die "aborted at line $LINENO (exit $?). The lab may be half-built; re-run the same verb, it is idempotent."' ERR

# ----------------------------------------------------------------------------- guards
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

preflight() {
  need az; need curl; need ssh
  az account show >/dev/null 2>&1 || die "not logged in. Run: az login"
  SUB_NAME="$(az account show --query name -o tsv)"
  SUB_ID="$(az account show --query id -o tsv)"
  mkdir -p "$STATE_DIR"
}

# Refuses to operate on any resource group that is not tagged as this lab.
# This is the single guard that makes every destructive verb below safe.
assert_lab_rg() {
  local tag
  az group show -n "$RG" >/dev/null 2>&1 || die "resource group '$RG' does not exist. Run: $0 provision"
  tag="$(az group show -n "$RG" --query "tags.${LAB_TAG_KEY}" -o tsv 2>/dev/null || true)"
  [[ "$tag" == "$LAB_TAG_VALUE" ]] || die "resource group '$RG' is NOT tagged ${LAB_TAG_KEY}=${LAB_TAG_VALUE}. Refusing to modify it."
}

confirm() {
  local prompt="$1" expected="$2" answer
  read -r -p "$prompt" answer
  [[ "$answer" == "$expected" ]] || die "confirmation mismatch; nothing was changed."
}

my_public_ip() {
  local ip
  ip="$(curl -fsS -m 10 https://ifconfig.me 2>/dev/null || curl -fsS -m 10 https://api.ipify.org)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not determine your public IP; set LAB_CLIENT_IP=x.x.x.x"
  printf '%s' "$ip"
}

# ----------------------------------------------------------------------------- state
save_state() { # save_state KEY VALUE
  touch "$STATE_FILE"
  grep -v "^${1}=" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null || true
  printf '%s=%q\n' "$1" "$2" >> "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}
load_state() { [[ -f "$STATE_FILE" ]] && . "$STATE_FILE" || true; }

discover() {
  NIC_ID="$(az vm show -g "$RG" -n "$VM" --query "networkProfile.networkInterfaces[0].id" -o tsv)"
  NIC_NAME="$(basename "$NIC_ID")"
  IPCONFIG="$(az network nic show --ids "$NIC_ID" --query "ipConfigurations[0].name" -o tsv)"
  PRIVATE_IP="$(az network nic show --ids "$NIC_ID" --query "ipConfigurations[0].privateIPAddress" -o tsv)"
  PIP_ID="$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query id -o tsv)"
  PUBLIC_IP="$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query ipAddress -o tsv)"
}

# ----------------------------------------------------------------------------- provision
write_cloud_init() {
  cat > "$CLOUD_INIT" <<'EOF'
#cloud-config
package_update: true
packages:
  - nginx
write_files:
  - path: /var/www/html/index.html
    permissions: '0644'
    content: |
      <!doctype html>
      <html><head><title>AZ-900 2.2 lab</title></head>
      <body><h1>vm-web01 is serving</h1>
      <p>If you can read this from the public IP, compute + NIC + subnet + NSG all agree.</p>
      </body></html>
  - path: /etc/nginx/conf.d/health.conf
    permissions: '0644'
    content: |
      server {
        listen 80;
        server_name _;
        location = /healthz { return 200 "ok\n"; add_header Content-Type text/plain; }
      }
runcmd:
  - [ systemctl, enable, --now, nginx ]
EOF
}

provision() {
  preflight
  rule
  log "Subscription : ${B}${SUB_NAME}${N} (${SUB_ID})"
  log "Resource grp : ${B}${RG}${N} in ${LOCATION}"
  log "Cost         : 1x ${VM_SIZE} + 1x Standard public IP until you run 'teardown'."
  rule
  confirm "Type the word ${B}build${N} to create the lab: " "build"

  local client_ip; client_ip="${LAB_CLIENT_IP:-$(my_public_ip)}"
  log "Your client IP is ${client_ip}; inbound 22/80 will be allowed only from ${client_ip}/32."

  az group create -n "$RG" -l "$LOCATION" \
    --tags "${LAB_TAG_KEY}=${LAB_TAG_VALUE}" "owner=az900-student" -o none
  ok "resource group"

  az network vnet create -g "$RG" -n "$VNET" \
    --address-prefixes "$VNET_CIDR" \
    --subnet-name "$SUBNET" --subnet-prefixes "$SUBNET_CIDR" -o none
  ok "vnet ${VNET} ${VNET_CIDR} / subnet ${SUBNET} ${SUBNET_CIDR}"

  # Two NSGs on purpose. Inbound traffic is filtered by the SUBNET NSG first and
  # then by the NIC NSG; outbound is filtered NIC first, then subnet. A packet
  # must be allowed by BOTH to arrive. This is the single most misread diagram
  # in the whole 2.2 objective.
  az network nsg create -g "$RG" -n "$NSG_SUBNET" -o none
  az network nsg create -g "$RG" -n "$NSG_NIC"    -o none

  az network nsg rule create -g "$RG" --nsg-name "$NSG_SUBNET" -n allow-http-in \
    --priority 200 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "${client_ip}/32" --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 80 \
    --description "baseline: HTTP from the student only" -o none
  az network nsg rule create -g "$RG" --nsg-name "$NSG_SUBNET" -n allow-ssh-in \
    --priority 210 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "${client_ip}/32" --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 22 \
    --description "baseline: SSH from the student only" -o none

  az network nsg rule create -g "$RG" --nsg-name "$NSG_NIC" -n allow-http-in \
    --priority 200 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "${client_ip}/32" --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 80 -o none
  az network nsg rule create -g "$RG" --nsg-name "$NSG_NIC" -n allow-ssh-in \
    --priority 210 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "${client_ip}/32" --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 22 -o none
  ok "NSGs: ${NSG_SUBNET} (subnet) + ${NSG_NIC} (NIC)"

  az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n "$SUBNET" \
    --network-security-group "$NSG_SUBNET" -o none
  ok "subnet NSG association"

  az network public-ip create -g "$RG" -n "$PIP_NAME" \
    --sku Standard --allocation-method Static --version IPv4 -o none
  ok "public IP (Standard SKU - default is deny inbound, the NSG is what opens it)"

  write_cloud_init
  az vm create -g "$RG" -n "$VM" \
    --image "$VM_IMAGE" --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" --generate-ssh-keys \
    --vnet-name "$VNET" --subnet "$SUBNET" \
    --nsg "$NSG_NIC" --public-ip-address "$PIP_NAME" \
    --custom-data "$CLOUD_INIT" \
    --os-disk-delete-option Delete --nic-delete-option Delete -o none
  ok "VM ${VM} created"

  discover
  save_state RG "$RG"; save_state VM "$VM"; save_state NIC_NAME "$NIC_NAME"
  save_state IPCONFIG "$IPCONFIG"; save_state PIP_ID "$PIP_ID"
  save_state PUBLIC_IP "$PUBLIC_IP"; save_state PRIVATE_IP "$PRIVATE_IP"
  save_state CLIENT_IP "$client_ip"; save_state ACTIVE_FAULT "none"

  log "waiting for cloud-init to finish installing nginx ..."
  local i http=000
  for i in $(seq 1 30); do
    http="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://${PUBLIC_IP}/healthz" || true)"
    [[ "$http" == "200" ]] && break
    sleep 10
  done
  [[ "$http" == "200" ]] || warn "healthz not 200 yet (got ${http:-none}); give cloud-init another minute."

  rule
  ok "Baseline is UP."
  echo "  Public IP  : ${B}${PUBLIC_IP}${N}"
  echo "  Private IP : ${PRIVATE_IP}"
  echo "  Web        : curl http://${PUBLIC_IP}/healthz    -> ok"
  echo "  SSH        : ssh ${ADMIN_USER}@${PUBLIC_IP}"
  rule
  echo "Next: ${B}$0 break${N}   (or ${B}$0 break --fault 3${N} to pick one)"
}

# ----------------------------------------------------------------------------- faults
brief() {
  local f="$1"
  rule
  printf '%sFAULT INJECTED - #%s%s\n' "$B" "$f" "$N"
  rule
  case "$f" in
    1)
      cat <<EOF
SYMPTOM
  From your workstation:
    curl -m 8 http://${PUBLIC_IP}/healthz
  hangs for the full timeout and returns exit code 28 (Operation timed out).
  There is NO "connection refused" - the packet dies silently.
  SSH on port 22 to the same public IP still works, and once inside the VM
    curl -s localhost/healthz   ->   ok
  so the application is healthy.

  A timeout on 80 with a working 22 to the same NIC means the packet is being
  dropped by a stateless filter on the way in, not by the guest.

YOUR OBJECTIVE
  Make http://${PUBLIC_IP}/healthz return 200 again, WITHOUT:
    - deleting or editing any rule named 'allow-http-in'
    - deleting an NSG or detaching it from the subnet or the NIC
    - opening port 80 to the whole Internet (it must stay scoped to ${CLIENT_IP}/32)
  You must find WHICH of the two NSGs is dropping the packet and why the
  existing Allow rule is not winning.

TOOLS YOU SHOULD REACH FOR
  az network nic list-effective-nsg
  az network watcher test-ip-flow
  az network nsg rule list --include-default -o table
EOF
      ;;
    2)
      cat <<EOF
SYMPTOM
  From your workstation both of these now fail instantly (not a timeout - the
  connection never even leaves in a useful direction):
    curl -m 8 http://${PUBLIC_IP}/healthz
    ssh ${ADMIN_USER}@${PUBLIC_IP}
  The public IP resource ${PIP_NAME} still EXISTS and still shows an address:
    az network public-ip show -g ${RG} -n ${PIP_NAME} --query ipAddress -o tsv
  The VM is Running and healthy - you can prove it out-of-band:
    az vm run-command invoke -g ${RG} -n ${VM} --command-id RunShellScript \\
      --scripts "curl -s localhost/healthz"

  An existing public IP that no longer reaches a running VM is the classic
  "the address exists but is attached to nothing" failure.

YOUR OBJECTIVE
  Restore reachability on the SAME address ${PUBLIC_IP} - do not create a new
  public IP, do not recreate the VM or the NIC, and do not change any NSG rule.
  Everything you need is a single control-plane association.

TOOLS YOU SHOULD REACH FOR
  az vm list-ip-addresses -o table
  az network nic show / az network nic ip-config show
  az network public-ip show --query ipConfiguration
EOF
      ;;
    3)
      cat <<EOF
SYMPTOM
  From your workstation:
    curl -m 8 http://${PUBLIC_IP}/healthz
  fails IMMEDIATELY with "Connection refused" (curl exit code 7), not a timeout.
  SSH works. Inside the VM, 'curl localhost/healthz' also says refused, and
    ss -lntp | grep ':80'
  returns nothing at all - nobody is listening.

  Refused vs timed out is the whole lesson: a TCP RST came back, so the packet
  DID traverse the public IP, the NSGs and the NIC and reached the guest OS.
  The network is innocent. This is a compute-layer (guest) failure.

YOUR OBJECTIVE
  Get nginx listening on :80 again AND surviving a reboot:
    systemctl is-enabled nginx  -> enabled
    systemctl is-active  nginx  -> active
  Note that a plain 'systemctl start nginx' will fail with
    "Unit nginx.service is masked."
  You must understand what masking is before you can undo it.

TOOLS YOU SHOULD REACH FOR
  systemctl status/is-enabled/list-unit-files nginx
  ls -l /etc/systemd/system/nginx.service
  journalctl -u nginx --no-pager -n 30
  az vm run-command invoke   (if you prefer to fix it without SSH)
EOF
      ;;
    4)
      cat <<EOF
SYMPTOM
  INBOUND is fine - http://${PUBLIC_IP}/healthz still returns 200 from your
  workstation, and SSH works. But the VM cannot start any conversation of its
  own. Inside the VM:
    curl -m 8 https://learn.microsoft.com/  ->  hangs, exit 28
    sudo apt-get update                     ->  hangs on every repository
    nslookup learn.microsoft.com            ->  still resolves fine (DNS is 168.63.129.16)

  Inbound working while outbound hangs proves the rule is directional. NSGs are
  stateful, so the return traffic of an INBOUND flow is allowed automatically -
  which is exactly why your web page still loads while the VM is cut off.

YOUR OBJECTIVE
  Make this succeed from inside the VM:
    curl -s -o /dev/null -w '%{http_code}\\n' -m 10 https://learn.microsoft.com/
  ...while keeping the rule named '${PLATFORM_ALLOW_RULE}' in place (that one is
  legitimate: it allows the Azure platform IP 168.63.129.16 that the VM agent
  and DNS depend on). Identify the offending rule by name, direction, priority
  and destination service tag before you remove it.

TOOLS YOU SHOULD REACH FOR
  az network nic list-effective-nsg
  az network nsg rule list --include-default -o table   (look at the Outbound defaults)
  az network watcher test-ip-flow --direction Outbound
EOF
      ;;
  esac
  rule
  echo "When you think it is fixed: ${B}$0 verify${N}"
  echo "If you get stuck            : ${B}$0 restore${N}  (rolls the fault back)"
  echo "The full worked solution is at the bottom of this script, commented out."
}

inject_1_nsg_shadow() {
  # Deny inbound 80 at the SUBNET NSG with priority 100, i.e. numerically LOWER
  # (= evaluated earlier, wins) than the allow-http-in rule at 200. The NIC NSG
  # still says Allow, so every per-NIC view of the config looks correct.
  az network nsg rule create -g "$RG" --nsg-name "$NSG_SUBNET" -n "$FAULT_RULE_HTTP" \
    --priority 100 --direction Inbound --access Deny --protocol Tcp \
    --source-address-prefixes Internet --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 80 \
    --description "az900 lab injected fault - subnet NSG shadows the NIC allow" -o none
  save_state ACTIVE_FAULT 1
}

inject_2_pip_detach() {
  # Dissociate the public IP from the NIC ipConfiguration. The PIP resource and
  # its address survive; only the association is gone.
  az network nic ip-config update -g "$RG" --nic-name "$NIC_NAME" -n "$IPCONFIG" \
    --public-ip-address "" -o none
  save_state ACTIVE_FAULT 2
}

inject_3_mask_nginx() {
  # Guest-layer fault via the VM agent (no SSH needed, and the agent stays up).
  az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript --scripts \
    "systemctl stop nginx; systemctl mask nginx; logger -t az900lab 'fault 3 injected: nginx masked'" \
    -o none
  save_state ACTIVE_FAULT 3
}

inject_4_egress_deny() {
  # First keep the platform channel open (168.63.129.16 serves DNS, DHCP and the
  # VM agent / Run Command). Losing it would remove your out-of-band recovery.
  az network nsg rule create -g "$RG" --nsg-name "$NSG_NIC" -n "$PLATFORM_ALLOW_RULE" \
    --priority 110 --direction Outbound --access Allow --protocol '*' \
    --source-address-prefixes '*' --source-port-ranges '*' \
    --destination-address-prefixes 168.63.129.16 --destination-port-ranges '*' \
    --description "keep the Azure platform IP reachable - do not delete" -o none
  az network nsg rule create -g "$RG" --nsg-name "$NSG_NIC" -n "$FAULT_RULE_EGRESS" \
    --priority 120 --direction Outbound --access Deny --protocol Tcp \
    --source-address-prefixes '*' --source-port-ranges '*' \
    --destination-address-prefixes Internet --destination-port-ranges 80 443 \
    --description "az900 lab injected fault - blocks all outbound web traffic" -o none
  save_state ACTIVE_FAULT 4
}

break_lab() {
  local fault="${1:-}"
  preflight; assert_lab_rg; load_state; discover
  [[ "${ACTIVE_FAULT:-none}" == "none" ]] || die "fault #${ACTIVE_FAULT} is already active. Run '$0 restore' first."
  if [[ -z "$fault" ]]; then fault=$(( (RANDOM % 4) + 1 )); fi
  [[ "$fault" =~ ^[1-4]$ ]] || die "--fault must be 1..4"

  log "injecting fault #${fault} into ${RG} ..."
  case "$fault" in
    1) inject_1_nsg_shadow ;;
    2) save_state PIP_ID "$PIP_ID"; inject_2_pip_detach ;;
    3) inject_3_mask_nginx ;;
    4) inject_4_egress_deny ;;
  esac
  # NSG changes converge in seconds; give the data plane a moment before the brief.
  sleep 15
  load_state
  brief "$fault"
}

# ----------------------------------------------------------------------------- verify
verify() {
  preflight; assert_lab_rg; load_state
  local f="${ACTIVE_FAULT:-none}"
  [[ "$f" != "none" ]] || { ok "no fault is active - the lab is at baseline."; return 0; }
  discover
  local http rc=1

  case "$f" in
    1|2)
      [[ -n "${PUBLIC_IP:-}" ]] || { warn "the VM has no public IP associated - not fixed yet."; return 1; }
      http="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://${PUBLIC_IP}/healthz" || true)"
      log "GET http://${PUBLIC_IP}/healthz -> ${http:-timeout}"
      [[ "$http" == "200" ]] && rc=0
      if [[ "$f" == "1" && "$rc" == "0" ]]; then
        az network nsg rule show -g "$RG" --nsg-name "$NSG_SUBNET" -n allow-http-in >/dev/null 2>&1 \
          || { warn "you deleted allow-http-in - the constraint said not to."; rc=1; }
      fi
      ;;
    3)
      http="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://${PUBLIC_IP}/healthz" || true)"
      local enabled
      enabled="$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
        --scripts "systemctl is-enabled nginx || true" \
        --query "value[0].message" -o tsv | tr -d '\r')"
      log "GET /healthz -> ${http:-timeout}; systemctl is-enabled nginx -> $(printf '%s' "$enabled" | grep -Eo 'enabled|disabled|masked' | tail -1)"
      [[ "$http" == "200" ]] && printf '%s' "$enabled" | grep -q '^enabled$\|[^a-z]enabled$' && rc=0
      ;;
    4)
      local out
      out="$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
        --scripts "curl -s -o /dev/null -w '%{http_code}' -m 10 https://learn.microsoft.com/ || echo TIMEOUT" \
        --query "value[0].message" -o tsv)"
      log "egress test from inside the VM -> $(printf '%s' "$out" | grep -Eo '20[0-9]|30[0-9]|TIMEOUT' | tail -1)"
      printf '%s' "$out" | grep -qE '20[0-9]|30[0-9]' && rc=0
      az network nsg rule show -g "$RG" --nsg-name "$NSG_NIC" -n "$PLATFORM_ALLOW_RULE" >/dev/null 2>&1 \
        || { warn "you removed ${PLATFORM_ALLOW_RULE}; it had to stay."; rc=1; }
      ;;
  esac

  rule
  if [[ "$rc" == "0" ]]; then
    ok "FIXED. Success criteria for fault #${f} are met."
    echo "Write down, in one sentence each: which layer failed, which command proved it,"
    echo "and why the OTHER two layers were exonerated. That sentence is the exam answer."
    save_state ACTIVE_FAULT "none"
  else
    warn "NOT fixed yet. Re-read the symptom - and notice which probes still succeed:"
    echo "  a probe that SUCCEEDS narrows the fault more than one that fails."
  fi
  rule
  return "$rc"
}

# ----------------------------------------------------------------------------- restore
restore() {
  preflight; assert_lab_rg; load_state; discover
  log "rolling back any injected fault in ${RG} ..."
  az network nsg rule delete -g "$RG" --nsg-name "$NSG_SUBNET" -n "$FAULT_RULE_HTTP"   -o none 2>/dev/null || true
  az network nsg rule delete -g "$RG" --nsg-name "$NSG_NIC"    -n "$FAULT_RULE_EGRESS" -o none 2>/dev/null || true
  az network nsg rule delete -g "$RG" --nsg-name "$NSG_NIC"    -n "$PLATFORM_ALLOW_RULE" -o none 2>/dev/null || true
  if [[ -n "${PIP_ID:-}" ]]; then
    az network nic ip-config update -g "$RG" --nic-name "$NIC_NAME" -n "$IPCONFIG" \
      --public-ip-address "$PIP_ID" -o none 2>/dev/null || true
  fi
  az vm run-command invoke -g "$RG" -n "$VM" --command-id RunShellScript \
    --scripts "systemctl unmask nginx; systemctl enable --now nginx" -o none 2>/dev/null || true
  save_state ACTIVE_FAULT "none"
  sleep 10
  discover
  local http; http="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://${PUBLIC_IP}/healthz" || true)"
  [[ "$http" == "200" ]] && ok "baseline restored (200 on http://${PUBLIC_IP}/healthz)" \
                         || warn "baseline probe returned '${http:-timeout}' - wait 30s and re-run '$0 verify'"
}

# ----------------------------------------------------------------------------- teardown
teardown() {
  preflight; assert_lab_rg
  rule
  warn "This DELETES the entire resource group '${RG}' in subscription '${SUB_NAME}'"
  warn "and every resource inside it. There is no undo."
  az resource list -g "$RG" --query "[].{name:name,type:type}" -o table || true
  rule
  confirm "Type ${B}DELETE${N} to destroy the lab: " "DELETE"
  az group delete -n "$RG" --yes --no-wait
  rm -f "$STATE_FILE"
  ok "deletion started (--no-wait). Check with: az group show -n ${RG}"
}

# ----------------------------------------------------------------------------- status / usage
status() {
  preflight; load_state
  az group show -n "$RG" >/dev/null 2>&1 || { warn "lab not provisioned."; return 0; }
  discover
  rule
  echo "RG           : $RG (${LOCATION})"
  echo "VM           : $VM  -> $(az vm get-instance-view -g "$RG" -n "$VM" --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv)"
  echo "NIC          : $NIC_NAME / ipconfig $IPCONFIG / private $PRIVATE_IP"
  echo "Public IP    : ${PUBLIC_IP:-<not associated>}"
  echo "Active fault : ${ACTIVE_FAULT:-none}"
  rule
  az network nic list-effective-nsg -g "$RG" -n "$NIC_NAME" \
    --query "value[].{nsg:networkSecurityGroup.id}" -o tsv 2>/dev/null | sed 's|.*/||;s|^|effective NSG: |' || true
}

usage() {
  cat <<EOF
AZ-900 topic 2.2 - break & fix lab

  $0 provision            build the disposable lab (VNet + NSGs + PIP + VM + nginx)
  $0 break [--fault N]    inject one fault (N = 1..4, default random) and brief the student
  $0 verify               re-test the success criteria of the active fault
  $0 restore              undo the injected fault, back to baseline
  $0 status               show the current lab topology and active fault
  $0 teardown             delete the whole resource group (asks for DELETE)

Environment overrides: LAB_RG, LAB_LOCATION, LAB_VM_SIZE, LAB_CLIENT_IP, LAB_STATE_DIR
EOF
}

# ----------------------------------------------------------------------------- main
main() {
  local verb="${1:-}"; shift || true
  case "$verb" in
    provision) provision ;;
    break)
      local f=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --fault) f="${2:-}"; shift 2 ;;
          *) die "unknown option: $1" ;;
        esac
      done
      break_lab "$f" ;;
    verify)   verify ;;
    restore)  restore ;;
    status)   status ;;
    teardown) teardown ;;
    ""|-h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}
main "$@"

# =============================================================================
#  SOLUTION - DO NOT READ UNTIL YOU HAVE TRIED
# =============================================================================
#
#  Shared first move for every fault: classify the failure by the SHAPE of the
#  failure, before touching any configuration.
#
#    $ curl -m 8 -o /dev/null -w '%{http_code} %{time_total}\n' http://<PIP>/healthz
#
#    200  0.04    -> the path is fine, the problem is elsewhere (fault 4)
#    000  8.00    -> timeout: something DROPS the packet silently. NSG deny,
#                    a missing/detached public IP, or a blackhole route.
#                    (curl exit 28)
#    exit 7, "Connection refused" -> a RST came back. The packet REACHED the
#                    guest and the guest had nothing on :80. Compute layer.
#
#  Azure drops (Deny) rather than rejects, so "timeout" points at the network
#  and "refused" points at the OS. That single distinction resolves fault 3 in
#  five seconds and is worth more than any portal blade.
#
# -----------------------------------------------------------------------------
#  FAULT 1 - Subnet NSG deny shadows the NIC NSG allow
# -----------------------------------------------------------------------------
#  Step 1. Confirm the app is healthy, so the fault is not compute:
#      $ ssh azureuser@<PIP> 'curl -s localhost/healthz'
#      ok
#
#  Step 2. Ask Azure to simulate the packet instead of guessing. Network Watcher
#  evaluates all effective rules in the real order and names the rule that wins:
#      $ az network watcher test-ip-flow -g rg-az900-breakfix --vm vm-web01 \
#          --direction Inbound --protocol TCP \
#          --local 10.20.1.4:80 --remote <YOUR_IP>:54321
#      {
#        "access": "Deny",
#        "ruleName": "securityRules/lab-fault-deny-http-in"
#      }
#  (If the region has no Network Watcher yet:
#      az network watcher configure -g NetworkWatcherRG -l eastus --enabled true)
#
#  Step 3. See BOTH NSGs that apply to the NIC - this is the step people skip:
#      $ az network nic list-effective-nsg -g rg-az900-breakfix -n <nic> \
#          --query "value[].networkSecurityGroup.id" -o tsv
#      .../networkSecurityGroups/nsg-nic-web
#      .../networkSecurityGroups/nsg-snet-web        <-- the second one
#
#  Step 4. List the subnet NSG rules by priority. Lower number = evaluated first
#  and, once a rule matches, evaluation STOPS:
#      $ az network nsg rule list -g rg-az900-breakfix --nsg-name nsg-snet-web \
#          --include-default -o table --query \
#          "sort_by([].{P:priority,Name:name,Dir:direction,Access:access,Port:destinationPortRange},&P)"
#      P     Name                    Dir       Access  Port
#      ----  ----------------------  --------  ------  ----
#      100   lab-fault-deny-http-in  Inbound   Deny    80     <-- wins
#      200   allow-http-in           Inbound   Allow   80     <-- never reached
#      210   allow-ssh-in            Inbound   Allow   22
#      65000 AllowVnetInBound        Inbound   Allow   *
#      65500 DenyAllInBound          Inbound   Deny    *
#
#  Step 5. Remove the offending rule (the constraint forbade touching
#  allow-http-in, and correctly so - the Allow was never the problem):
#      $ az network nsg rule delete -g rg-az900-breakfix \
#          --nsg-name nsg-snet-web -n lab-fault-deny-http-in
#      $ curl -s -o /dev/null -w '%{http_code}\n' http://<PIP>/healthz
#      200
#
#  What to retain: inbound is filtered SUBNET first, then NIC; outbound is NIC
#  first, then subnet; the traffic must be allowed by both. Within one NSG the
#  lowest priority number wins and evaluation stops there - so an Allow at 200
#  is dead code behind a Deny at 100.
#
# -----------------------------------------------------------------------------
#  FAULT 2 - Public IP dissociated from the NIC ipConfiguration
# -----------------------------------------------------------------------------
#  Step 1. Ask what addresses the VM actually has:
#      $ az vm list-ip-addresses -g rg-az900-breakfix -n vm-web01 -o table
#      VirtualMachine    PublicIPAddresses    PrivateIPAddresses
#      ----------------  -------------------  --------------------
#      vm-web01                               10.20.1.4
#  The PublicIPAddresses column is empty: the VM has no public frontend at all.
#
#  Step 2. Look at the public IP resource from the other side. It exists, it
#  still holds the address, but it is attached to nothing:
#      $ az network public-ip show -g rg-az900-breakfix -n pip-web01 \
#          --query "{ip:ipAddress, allocation:publicIPAllocationMethod, attachedTo:ipConfiguration}" -o json
#      { "ip": "20.x.x.x", "allocation": "Static", "attachedTo": null }
#  Static allocation is why the address survived the detach - a Standard SKU
#  public IP is always static, so re-attaching gives you the SAME address.
#
#  Step 3. Prove compute is healthy without any network path, using the agent:
#      $ az vm run-command invoke -g rg-az900-breakfix -n vm-web01 \
#          --command-id RunShellScript --scripts "curl -s localhost/healthz" \
#          --query "value[0].message" -o tsv
#      Enable succeeded: [stdout] ok [stderr]
#
#  Step 4. Re-associate the public IP with the NIC's ipConfiguration:
#      $ NIC=$(az vm show -g rg-az900-breakfix -n vm-web01 \
#              --query "networkProfile.networkInterfaces[0].id" -o tsv | xargs basename)
#      $ IPCFG=$(az network nic show -g rg-az900-breakfix -n "$NIC" \
#              --query "ipConfigurations[0].name" -o tsv)
#      $ az network nic ip-config update -g rg-az900-breakfix \
#          --nic-name "$NIC" -n "$IPCFG" --public-ip-address pip-web01 -o none
#      $ curl -s -o /dev/null -w '%{http_code}\n' http://<PIP>/healthz
#      200
#  (The detach is the same command with --public-ip-address "" - an empty string
#  is how the CLI expresses "remove the association".)
#
#  What to retain: a VM's public IP is not a property of the VM. It is a
#  separate resource associated with an ipConfiguration on a NIC. The VM, the
#  NIC, the private IP and the public IP have independent lifecycles - which is
#  precisely why you can rebuild a VM and keep the address.
#
# -----------------------------------------------------------------------------
#  FAULT 3 - nginx stopped and masked (compute layer)
# -----------------------------------------------------------------------------
#  Step 1. Read the error text, not just the failure:
#      $ curl -m 8 http://<PIP>/healthz
#      curl: (7) Failed to connect to 20.x.x.x port 80: Connection refused
#  Refused, not timed out => the SYN reached the guest and the guest answered
#  RST. Every network component in front of it is therefore working. Do not
#  open a single NSG blade.
#
#  Step 2. Confirm nothing is listening:
#      $ ssh azureuser@<PIP>
#      $ ss -lntp | grep ':80' || echo "nothing on 80"
#      nothing on 80
#
#  Step 3. Ask systemd why:
#      $ systemctl status nginx --no-pager
#      o nginx.service
#           Loaded: masked (Reason: Unit nginx.service is masked.)
#           Active: inactive (dead)
#      $ ls -l /etc/systemd/system/nginx.service
#      lrwxrwxrwx 1 root root 9 ... /etc/systemd/system/nginx.service -> /dev/null
#  A masked unit is symlinked to /dev/null: it cannot be started manually, by a
#  dependency, or at boot. This is why 'systemctl start nginx' returns
#      Failed to start nginx.service: Unit nginx.service is masked.
#  Masking is stronger than disabling - 'disable' only removes the boot-time
#  wants/ symlink; 'mask' blocks activation entirely.
#
#  Step 4. Unmask, then start AND enable so it survives a reboot:
#      $ sudo systemctl unmask nginx
#      Removed /etc/systemd/system/nginx.service.
#      $ sudo systemctl enable --now nginx
#      $ systemctl is-active nginx && systemctl is-enabled nginx
#      active
#      enabled
#      $ curl -s localhost/healthz
#      ok
#
#  Same fix without SSH, through the VM agent (useful when the fault IS the SSH
#  path - this is the out-of-band channel the lab always preserves):
#      $ az vm run-command invoke -g rg-az900-breakfix -n vm-web01 \
#          --command-id RunShellScript \
#          --scripts "systemctl unmask nginx; systemctl enable --now nginx; systemctl is-active nginx"
#
#  Step 5. Confirm from outside:
#      $ curl -s -o /dev/null -w '%{http_code}\n' http://<PIP>/healthz
#      200
#
#  What to retain: IaaS splits responsibility. Azure guarantees the VM runs;
#  what runs INSIDE it is yours. Run Command and the serial console are the
#  compute-layer tools that keep working when the guest network does not.
#
# -----------------------------------------------------------------------------
#  FAULT 4 - Outbound NSG rule blocks egress to the Internet service tag
# -----------------------------------------------------------------------------
#  Step 1. Note precisely what still works. Inbound HTTP returns 200 while
#  outbound hangs. NSGs are STATEFUL: the reply packets of a flow that was
#  allowed inbound need no outbound rule, so an outbound Deny is invisible to
#  your browser and lethal to apt, agents, backups and any API call the VM makes.
#
#  Step 2. From inside, distinguish DNS from transport:
#      $ nslookup learn.microsoft.com
#      Server: 168.63.129.16      <-- Azure-provided DNS still answers
#      Address: 168.63.129.16#53
#      Non-authoritative answer: ...
#      $ curl -v -m 8 https://learn.microsoft.com/
#      * Trying 23.x.x.x:443...
#      * Connection timed out after 8001 milliseconds
#  Name resolution fine, TCP handshake dead => a filter on the way OUT, not DNS.
#
#  Step 3. Simulate the outbound packet:
#      $ az network watcher test-ip-flow -g rg-az900-breakfix --vm vm-web01 \
#          --direction Outbound --protocol TCP \
#          --local 10.20.1.4:49152 --remote 23.221.222.250:443
#      {
#        "access": "Deny",
#        "ruleName": "securityRules/lab-fault-deny-egress"
#      }
#
#  Step 4. Read the rule before deleting it - direction, priority, destination:
#      $ az network nsg rule list -g rg-az900-breakfix --nsg-name nsg-nic-web \
#          --include-default -o table --query \
#          "sort_by([?direction=='Outbound'].{P:priority,Name:name,Access:access,Dest:destinationAddressPrefix,Port:destinationPortRange},&P)"
#      P      Name                                Access  Dest       Port
#      -----  ----------------------------------  ------  ---------  ----
#      110    lab-allow-platform-168-63-129-16    Allow   168.63...  *
#      120    lab-fault-deny-egress               Deny    Internet   80,443
#      65000  AllowVnetOutBound                   Allow   VirtualNetwork  *
#      65001  AllowInternetOutBound               Allow   Internet   *
#      65500  DenyAllOutBound                     Deny    *          *
#  'Internet' and 'VirtualNetwork' are SERVICE TAGS - Microsoft-maintained,
#  auto-updated address groups. Note default rule 65001: outbound Internet is
#  allowed by default, which is why only an explicit lower-priority Deny can
#  break it.
#
#  Step 5. Remove only the injected Deny, keeping the platform allow:
#      $ az network nsg rule delete -g rg-az900-breakfix \
#          --nsg-name nsg-nic-web -n lab-fault-deny-egress
#      $ az vm run-command invoke -g rg-az900-breakfix -n vm-web01 \
#          --command-id RunShellScript \
#          --scripts "curl -s -o /dev/null -w '%{http_code}' -m 10 https://learn.microsoft.com/" \
#          --query "value[0].message" -o tsv
#      Enable succeeded: [stdout] 200 [stderr]
#
#  What to retain: 168.63.129.16 is Azure's virtual public IP for DHCP, DNS,
#  health probes and the VM agent. Any real "deny all egress" design must allow
#  it explicitly or the VM loses DNS and Run Command - which is exactly how a
#  hardening change turns a reachable VM into an unrecoverable one.
#
# -----------------------------------------------------------------------------
#  Exam-level summary (topic 2.2)
# -----------------------------------------------------------------------------
#  * Compute:  the VM runs; what runs inside it is the customer's job. Run
#              Command / serial console are the out-of-band levers.
#  * NIC:      holds the ipConfiguration; the private IP and any public IP are
#              associated to it, each with its own lifecycle.
#  * Subnet:   carries its own NSG and, optionally, a route table (UDR).
#  * NSG:      stateful, priority-ordered (100-4096, lowest wins, first match
#              stops evaluation), evaluated at BOTH subnet and NIC, with default
#              rules at 65000+ that allow VNet and outbound Internet.
#  * Diagnosis order that never wastes time:
#              refused vs timeout -> test-ip-flow -> list-effective-nsg
#              -> show-next-hop -> only then read manifests by eye.
# =============================================================================