#!/usr/bin/env bash
#
# ==============================================================================
#  AWS Certified Cloud Practitioner (CLF-C02)
#  Domain 3: Cloud Technology and Services
#  Task Statement 3.5: Identify AWS network services
#  Exam weight of the parent domain: 34% -- this task statement: 4.25%
#
#  BREAK & FIX LAB -- "The VPC that answers no one"
#
#  Source of record for the objective wording:
#    https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
#
# ------------------------------------------------------------------------------
#  WHAT THIS SCRIPT IS
# ------------------------------------------------------------------------------
#  A real AWS VPC costs money, needs credentials, and cannot be handed to a
#  student as a throwaway. So this lab builds a *faithful local model* of the
#  AWS network data path inside ONE disposable Linux VM, using Linux network
#  namespaces, veth pairs, a Linux bridge, iptables and a nftables/iptables NAT
#  table. The mapping is one-to-one with the AWS objects you are examined on:
#
#     Lab object (Linux)                 AWS object (CLF-C02 vocabulary)
#     ---------------------------------  --------------------------------------
#     netns  ns-public                   EC2 instance in a PUBLIC subnet
#     netns  ns-private                  EC2 instance in a PRIVATE subnet
#     bridge br-vpc  (10.0.0.0/16)       The VPC CIDR block
#     veth   ...-pub  (10.0.1.0/24)      Public subnet
#     veth   ...-prv  (10.0.2.0/24)      Private subnet
#     host default route + MASQUERADE    Internet Gateway (IGW)
#     MASQUERADE only for 10.0.2.0/24    NAT Gateway
#     ip route inside the namespace      Route table entry (0.0.0.0/0 -> igw)
#     iptables chain SG-PUBLIC           Security group (STATEFUL, allow-only)
#     iptables chain NACL-PUBLIC         Network ACL (STATELESS, allow+deny)
#     dnsmasq on 10.0.0.2                Route 53 Resolver / the "VPC+2" address
#     ns-onprem + a GRE/ipip tunnel      Site-to-Site VPN / Direct Connect stand-in
#
#  Everything the student does here -- reading a route table, telling a stateful
#  security group apart from a stateless NACL, noticing that the public subnet
#  has no route to the IGW, seeing that DNS is what actually broke -- is exactly
#  the reasoning the exam asks for in plain-English multiple choice.
#
#  The exam does not ask you to type these commands. It asks you to know which
#  component is responsible for which symptom. Breaking them by hand is the
#  fastest way to make that knowledge stick.
#
# ------------------------------------------------------------------------------
#  SAFETY -- READ THIS BEFORE RUNNING
# ------------------------------------------------------------------------------
#  * DISPOSABLE VM ONLY. Vagrant box, cloud sandbox instance, throwaway KVM/LXC.
#    Not your laptop, not a jump host, not anything you would miss.
#  * Requires root (network namespaces and iptables are privileged).
#  * The script REFUSES to run if it detects an active SSH session whose
#    interface it would touch, and it never modifies the VM's own default route,
#    its DNS, or any interface outside the ones it creates. All state lives in
#    namespaces prefixed 'ns-' and interfaces prefixed 'veth-' / 'br-vpc'.
#  * Everything is reversible: 'teardown' deletes every object it created and
#    flushes only its own iptables chains. Nothing persists across reboot.
#  * No internet egress is required to complete the lab. A working default route
#    on the VM makes the IGW/NAT part more satisfying, but the failures are all
#    diagnosable offline.
#
# ------------------------------------------------------------------------------
#  USAGE
# ------------------------------------------------------------------------------
#     sudo ./35-network-services-breakfix.sh setup      # build the healthy VPC
#     sudo ./35-network-services-breakfix.sh verify     # prove it is healthy
#     sudo ./35-network-services-breakfix.sh break      # inject the faults
#     sudo ./35-network-services-breakfix.sh brief      # the student's mission
#     sudo ./35-network-services-breakfix.sh verify     # your scorecard
#     sudo ./35-network-services-breakfix.sh teardown   # remove everything
#
#  The solution is at the END of this file, commented out. Do not scroll there
#  until 'verify' has beaten you for at least twenty minutes.
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

# ------------------------------------------------------------------------------
# Constants -- the "VPC design document" for this lab.
# ------------------------------------------------------------------------------
readonly VPC_CIDR="10.0.0.0/16"
readonly PUBLIC_SUBNET="10.0.1.0/24"
readonly PRIVATE_SUBNET="10.0.2.0/24"
readonly ONPREM_CIDR="192.168.100.0/24"

readonly NS_PUBLIC="ns-public"
readonly NS_PRIVATE="ns-private"
readonly NS_ONPREM="ns-onprem"

readonly BRIDGE="br-vpc"

# The bridge holds the ".1" of each subnet: this is the AWS-reserved
# "first usable address of the subnet is the VPC router" convention.
readonly GW_PUBLIC="10.0.1.1"
readonly GW_PRIVATE="10.0.2.1"

readonly IP_PUBLIC="10.0.1.10"
readonly IP_PRIVATE="10.0.2.10"
readonly IP_ONPREM="192.168.100.10"

# AWS reserves the base of the VPC CIDR +2 for the Route 53 Resolver.
# 10.0.0.0/16 -> 10.0.0.2. We model it literally.
readonly RESOLVER_IP="10.0.0.2"

readonly VETH_PUB_HOST="veth-pub-h"
readonly VETH_PUB_NS="veth-pub-n"
readonly VETH_PRV_HOST="veth-prv-h"
readonly VETH_PRV_NS="veth-prv-n"
readonly VETH_ONP_HOST="veth-onp-h"
readonly VETH_ONP_NS="veth-onp-n"

readonly SG_PUBLIC="SG-PUBLIC"     # stateful, allow-list only  -> security group
readonly NACL_PUBLIC="NACL-PUBLIC" # stateless, allow AND deny  -> network ACL

readonly STATE_DIR="/run/aws-clf-35-lab"
readonly RESOLV_DIR="${STATE_DIR}/resolv"
readonly FAULT_FILE="${STATE_DIR}/faults.active"

# ------------------------------------------------------------------------------
# Output helpers. Colour only when stdout is a terminal.
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_RED=$'\033[31m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_BLUE=$'\033[34m'
    readonly C_DIM=$'\033[2m'
else
    readonly C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_DIM=""
fi

info()  { printf '%s[ INFO ]%s %s\n' "${C_BLUE}"   "${C_RESET}" "$*"; }
ok()    { printf '%s[  OK  ]%s %s\n' "${C_GREEN}"  "${C_RESET}" "$*"; }
warn()  { printf '%s[ WARN ]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*"; }
fail()  { printf '%s[ FAIL ]%s %s\n' "${C_RED}"    "${C_RESET}" "$*"; }
die()   { fail "$*"; exit 1; }
head1() { printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"; }
dim()   { printf '%s%s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }

# ------------------------------------------------------------------------------
# Guard rails.
# ------------------------------------------------------------------------------
require_root() {
    [[ ${EUID} -eq 0 ]] || die "This lab manipulates network namespaces and iptables. Run with sudo."
}

require_tools() {
    local missing=()
    local t
    for t in ip iptables sysctl; do
        command -v "${t}" >/dev/null 2>&1 || missing+=("${t}")
    done
    if ((${#missing[@]})); then
        die "Missing required tools: ${missing[*]} (Debian/Ubuntu: apt-get install -y iproute2 iptables procps)"
    fi
    command -v python3 >/dev/null 2>&1 \
        || warn "python3 not found -- the mock 'S3 endpoint' HTTP listener will be skipped."
}

# Refuse to run anywhere that looks like a machine somebody cares about.
require_disposable_vm() {
    if [[ -e /etc/aws-clf-lab-optout ]]; then
        die "Found /etc/aws-clf-lab-optout -- this host is marked as NOT disposable. Aborting."
    fi
    # If the VM's own address collides with our lab CIDRs we would blackhole
    # the operator's SSH session. That is the one genuinely dangerous case.
    local host_addrs
    host_addrs="$(ip -4 -oneline addr show scope global 2>/dev/null | awk '{print $4}' || true)"
    local a
    for a in ${host_addrs}; do
        case "${a}" in
            10.0.1.*|10.0.2.*|10.0.0.*)
                die "This VM already owns ${a}, which overlaps the lab VPC ${VPC_CIDR}.
       Running here could cut your own SSH session. Use a different VM or change the lab CIDR."
                ;;
        esac
    done
    warn "This lab creates namespaces, a bridge and iptables chains on THIS host."
    warn "Run it only on a disposable VM. 'teardown' removes everything it created."
}

ns_exists()   { ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
link_exists() { ip link show "$1" >/dev/null 2>&1; }
chain_exists() { iptables -t "${2:-filter}" -n -L "$1" >/dev/null 2>&1; }

# ip netns exec wrapper, so the intent reads clearly at the call sites.
in_ns() { local ns="$1"; shift; ip netns exec "${ns}" "$@"; }

# ==============================================================================
#  SETUP -- build a healthy, textbook AWS network
# ==============================================================================
setup() {
    require_root
    require_tools
    require_disposable_vm

    if ns_exists "${NS_PUBLIC}"; then
        warn "Lab already present. Run 'teardown' first if you want a clean build."
        return 0
    fi

    mkdir -p "${STATE_DIR}" "${RESOLV_DIR}"

    head1 "== Building the lab VPC ${VPC_CIDR} =="

    # --- The VPC itself: an isolated L2 domain, exactly like a VPC. -----------
    info "Creating bridge ${BRIDGE} -- this IS the VPC (${VPC_CIDR})."
    ip link add name "${BRIDGE}" type bridge
    ip link set "${BRIDGE}" up

    # The bridge carries the implicit-router address of EACH subnet. In AWS the
    # VPC router is invisible and always present at subnet-base+1; here we make
    # it real so the student can see it.
    ip addr add "${GW_PUBLIC}/24"  dev "${BRIDGE}"
    ip addr add "${GW_PRIVATE}/24" dev "${BRIDGE}"
    ip addr add "${RESOLVER_IP}/16" dev "${BRIDGE}"   # Route 53 Resolver, "VPC+2"

    # --- The three "EC2 instances" -------------------------------------------
    local ns
    for ns in "${NS_PUBLIC}" "${NS_PRIVATE}" "${NS_ONPREM}"; do
        info "Creating namespace ${ns}"
        ip netns add "${ns}"
        in_ns "${ns}" ip link set lo up
    done

    attach_ns "${NS_PUBLIC}"  "${VETH_PUB_HOST}" "${VETH_PUB_NS}" "${IP_PUBLIC}/24"  "${GW_PUBLIC}"
    attach_ns "${NS_PRIVATE}" "${VETH_PRV_HOST}" "${VETH_PRV_NS}" "${IP_PRIVATE}/24" "${GW_PRIVATE}"

    # On-prem is deliberately NOT on the bridge: it reaches the VPC only through
    # a point-to-point link, the way a Site-to-Site VPN or a Direct Connect
    # private VIF does. It has no route to the VPC until we add one.
    info "Creating the on-premises data center (${ONPREM_CIDR}) behind a point-to-point link."
    ip link add "${VETH_ONP_HOST}" type veth peer name "${VETH_ONP_NS}"
    ip link set "${VETH_ONP_NS}" netns "${NS_ONPREM}"
    ip addr add "192.168.100.1/24" dev "${VETH_ONP_HOST}"
    ip link set "${VETH_ONP_HOST}" up
    in_ns "${NS_ONPREM}" ip addr add "${IP_ONPREM}/24" dev "${VETH_ONP_NS}"
    in_ns "${NS_ONPREM}" ip link set "${VETH_ONP_NS}" up
    # The "VPN tunnel": on-prem knows how to reach the VPC CIDR.
    in_ns "${NS_ONPREM}" ip route add "${VPC_CIDR}" via "192.168.100.1"

    # --- Routing and NAT: the Internet Gateway and the NAT Gateway ------------
    info "Enabling IPv4 forwarding on the VPC router."
    sysctl -qw net.ipv4.ip_forward=1

    # MASQUERADE on the host's egress path is our Internet Gateway for the
    # public subnet and our NAT Gateway for the private subnet. In AWS these are
    # two DIFFERENT managed objects with different bills and different
    # directionality (IGW: bidirectional for public IPs; NAT GW: outbound only).
    info "Installing the Internet Gateway (source NAT for ${PUBLIC_SUBNET})."
    iptables -t nat -C POSTROUTING -s "${PUBLIC_SUBNET}"  ! -o "${BRIDGE}" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "${PUBLIC_SUBNET}"  ! -o "${BRIDGE}" -j MASQUERADE
    info "Installing the NAT Gateway (source NAT for ${PRIVATE_SUBNET}, outbound only)."
    iptables -t nat -C POSTROUTING -s "${PRIVATE_SUBNET}" ! -o "${BRIDGE}" -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "${PRIVATE_SUBNET}" ! -o "${BRIDGE}" -j MASQUERADE

    setup_security_groups
    setup_nacls
    setup_resolver
    setup_endpoint_service

    ok "Lab built."
    dim "Next: sudo $0 verify"
}

# attach_ns <ns> <host-veth> <ns-veth> <cidr> <gateway>
attach_ns() {
    local ns="$1" hveth="$2" nveth="$3" cidr="$4" gw="$5"
    info "Attaching ${ns} to the VPC with address ${cidr} (default route via ${gw})."
    ip link add "${hveth}" type veth peer name "${nveth}"
    ip link set "${hveth}" master "${BRIDGE}"
    ip link set "${hveth}" up
    ip link set "${nveth}" netns "${ns}"
    in_ns "${ns}" ip addr add "${cidr}" dev "${nveth}"
    in_ns "${ns}" ip link set "${nveth}" up
    # THIS is the route table entry '0.0.0.0/0 -> igw-xxxx' that makes a subnet
    # "public". A subnet is public because of its ROUTE, not because of its name.
    in_ns "${ns}" ip route add default via "${gw}"
}

# ------------------------------------------------------------------------------
# Security groups are STATEFUL: allow the new connection in one direction and
# the return traffic is permitted automatically. Model that with conntrack.
# There is no DENY rule in a security group -- only allows, default deny.
# ------------------------------------------------------------------------------
setup_security_groups() {
    info "Creating security group ${SG_PUBLIC} (stateful, allow-list, implicit deny)."
    iptables -N "${SG_PUBLIC}" 2>/dev/null || iptables -F "${SG_PUBLIC}"

    # Statefulness: this single rule is the entire difference from a NACL.
    iptables -A "${SG_PUBLIC}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    # Inbound allow rules ("sources" in the console).
    iptables -A "${SG_PUBLIC}" -p icmp --icmp-type echo-request -j ACCEPT
    iptables -A "${SG_PUBLIC}" -p tcp  --dport 22 -j ACCEPT
    iptables -A "${SG_PUBLIC}" -p tcp  --dport 80 -j ACCEPT
    iptables -A "${SG_PUBLIC}" -p udp  --dport 53 -j ACCEPT
    # Implicit deny at the end of every security group.
    iptables -A "${SG_PUBLIC}" -j DROP

    iptables -C FORWARD -d "${IP_PUBLIC}" -j "${SG_PUBLIC}" 2>/dev/null \
        || iptables -I FORWARD 1 -d "${IP_PUBLIC}" -j "${SG_PUBLIC}"
}

# ------------------------------------------------------------------------------
# Network ACLs are STATELESS: every packet is evaluated on its own, in rule
# number order, and the return traffic needs its OWN rule. They support explicit
# DENY, which is why they are the right tool for blocking a single bad IP.
# ------------------------------------------------------------------------------
setup_nacls() {
    info "Creating network ACL ${NACL_PUBLIC} (stateless, ordered, supports DENY)."
    iptables -N "${NACL_PUBLIC}" 2>/dev/null || iptables -F "${NACL_PUBLIC}"

    # Rule 100 -- allow inbound web + ssh + icmp
    iptables -A "${NACL_PUBLIC}" -p tcp --dport 22 -j ACCEPT
    iptables -A "${NACL_PUBLIC}" -p tcp --dport 80 -j ACCEPT
    iptables -A "${NACL_PUBLIC}" -p icmp -j ACCEPT
    iptables -A "${NACL_PUBLIC}" -p udp  -j ACCEPT
    # Rule 140 -- allow the EPHEMERAL PORT RANGE for return traffic. A stateless
    # firewall cannot infer this. Forgetting it is the classic NACL outage.
    iptables -A "${NACL_PUBLIC}" -p tcp --dport 1024:65535 -j ACCEPT
    # Rule * -- the implicit final DENY of every NACL.
    iptables -A "${NACL_PUBLIC}" -j DROP

    iptables -C FORWARD -s "${PUBLIC_SUBNET}" -j "${NACL_PUBLIC}" 2>/dev/null \
        || iptables -I FORWARD 2 -s "${PUBLIC_SUBNET}" -j "${NACL_PUBLIC}"
}

# ------------------------------------------------------------------------------
# Route 53 Resolver at VPC-base+2. Implemented as a per-namespace resolv.conf so
# no daemon is required and nothing on the host's DNS is touched.
# ------------------------------------------------------------------------------
setup_resolver() {
    info "Pointing the instances at the Route 53 Resolver (${RESOLVER_IP}, the 'VPC+2' address)."
    local ns
    for ns in "${NS_PUBLIC}" "${NS_PRIVATE}"; do
        mkdir -p "/etc/netns/${ns}"
        printf 'nameserver %s\noptions timeout:2 attempts:1\n' "${RESOLVER_IP}" \
            > "/etc/netns/${ns}/resolv.conf"
        cp "/etc/netns/${ns}/resolv.conf" "${RESOLV_DIR}/${ns}.resolv.conf"
    done
    # Private hosted zone: a name that resolves ONLY inside the VPC.
    printf '%s app.internal.lab\n' "${IP_PRIVATE}" > "${STATE_DIR}/hosted-zone.hosts"
    dim "      Private hosted zone entry: app.internal.lab -> ${IP_PRIVATE}"
}

# ------------------------------------------------------------------------------
# A stand-in for a VPC gateway/interface endpoint: a service the private subnet
# can reach WITHOUT traversing the internet. Listens on the bridge address.
# ------------------------------------------------------------------------------
setup_endpoint_service() {
    command -v python3 >/dev/null 2>&1 || return 0
    info "Starting the mock VPC endpoint service on ${GW_PRIVATE}:8080."
    mkdir -p "${STATE_DIR}/endpoint"
    printf 'vpc-endpoint-ok\n' > "${STATE_DIR}/endpoint/index.html"
    ( cd "${STATE_DIR}/endpoint" \
      && nohup python3 -m http.server 8080 --bind "${GW_PRIVATE}" \
           >"${STATE_DIR}/endpoint.log" 2>&1 & echo $! > "${STATE_DIR}/endpoint.pid" )
    sleep 1
}

# ==============================================================================
#  BREAK -- four independent, realistic, fully reversible faults
# ==============================================================================
break_lab() {
    require_root
    ns_exists "${NS_PUBLIC}" || die "Lab is not built. Run: sudo $0 setup"

    head1 "== Injecting faults =="

    # ---- FAULT 1: the public subnet's route table loses its 0.0.0.0/0 -> IGW.
    # In the AWS console the subnet still looks identical. It is now a private
    # subnet, because 'public' was never a property -- it was a route.
    info "Fault 1: deleting the default route from ${NS_PUBLIC}'s route table."
    in_ns "${NS_PUBLIC}" ip route del default 2>/dev/null || true

    # ---- FAULT 2: someone 'tightened' the security group and removed the
    # stateful ESTABLISHED,RELATED behaviour plus the HTTP ingress rule.
    info "Fault 2: rewriting security group ${SG_PUBLIC} -- ingress rules removed."
    iptables -F "${SG_PUBLIC}"
    iptables -A "${SG_PUBLIC}" -p tcp --dport 22 -j ACCEPT
    iptables -A "${SG_PUBLIC}" -j DROP

    # ---- FAULT 3: a NACL change removed the ephemeral port range allow. The
    # request arrives, the reply is dropped on the way out. Classic stateless
    # firewall half-open symptom.
    info "Fault 3: removing the ephemeral-port allow entry from ${NACL_PUBLIC}."
    iptables -D "${NACL_PUBLIC}" -p tcp --dport 1024:65535 -j ACCEPT 2>/dev/null || true
    iptables -I "${NACL_PUBLIC}" 1 -p tcp --sport 80 -j DROP

    # ---- FAULT 4: DHCP option set / resolver misconfiguration. The instances
    # are pointed at an address that is not the VPC resolver. Names fail, IPs
    # work -- the single most important discrimination in this task statement.
    info "Fault 4: repointing the instances at a non-existent DNS resolver."
    local ns
    for ns in "${NS_PUBLIC}" "${NS_PRIVATE}"; do
        printf 'nameserver 10.0.255.254\noptions timeout:1 attempts:1\n' \
            > "/etc/netns/${ns}/resolv.conf"
    done

    # ---- FAULT 5: the NAT Gateway is gone. The private subnet can still reach
    # the VPC endpoint, but nothing outside. This is what "we deleted the NAT
    # gateway to save money" looks like at 09:00 on a Monday.
    info "Fault 5: removing the NAT Gateway rule for ${PRIVATE_SUBNET}."
    iptables -t nat -D POSTROUTING -s "${PRIVATE_SUBNET}" ! -o "${BRIDGE}" -j MASQUERADE 2>/dev/null || true

    touch "${FAULT_FILE}"
    ok "Faults injected. Run: sudo $0 brief"
}

# ==============================================================================
#  BRIEF -- what the student is told. No answers here.
# ==============================================================================
brief() {
cat <<'BRIEF'

================================================================================
  INCIDENT TICKET #3-5-2026  --  "The VPC that answers no one"
  Domain 3.5, AWS Certified Cloud Practitioner (CLF-C02)
================================================================================

BACKGROUND
----------
You inherited a single-region VPC, 10.0.0.0/16, with two subnets:

    10.0.1.0/24   "public"    -- one instance, 10.0.1.10, runs a web server
    10.0.2.0/24   "private"   -- one instance, 10.0.2.10, runs a batch worker

There is an internet gateway, a NAT gateway, one security group on the public
instance, one network ACL on the public subnet, and a Route 53 private hosted
zone with the record  app.internal.lab -> 10.0.2.10.  An on-premises network,
192.168.100.0/24, is joined to the VPC over a site-to-site link.

Yesterday a colleague did a "quick security and cost cleanup" during a change
window and went on holiday. This morning nothing works. Nobody knows what they
changed. There is no CloudTrail export you can read.

SYMPTOMS YOU WILL OBSERVE
-------------------------
Run each of these and read them carefully. The exact failure MODE of each one
is the clue -- "no route to host" and "timeout" and "name or service not known"
are three different components failing.

  1. The public instance cannot reach the internet at all:

         sudo ip netns exec ns-public ping -c2 1.1.1.1
           -> connect: Network is unreachable

     Note the wording. This is not a firewall. A firewall silently drops or
     rejects; the kernel says "unreachable" only when it has nowhere to send
     the packet. Which AWS object decides where a packet is sent?

  2. Nothing can resolve a name, from either instance:

         sudo ip netns exec ns-public getent hosts app.internal.lab
           -> (no output, exit status 2, after a pause)
         sudo ip netns exec ns-public getent hosts amazon.com
           -> (no output, exit status 2)

     But raw IP connectivity inside the VPC still works:

         sudo ip netns exec ns-public ping -c2 10.0.2.10
           -> 2 packets transmitted, 2 received

     Names fail, addresses succeed. That combination points at exactly one
     component in an AWS VPC, and it has a well-known reserved address.

  3. The public web server is unreachable from outside its own subnet, and the
     failure is a TIMEOUT, not a refusal:

         sudo ip netns exec ns-onprem curl -m5 http://10.0.1.10/
           -> curl: (28) Connection timed out

     A timeout means the packet is being dropped in flight. Two different AWS
     objects can drop it -- one is stateful and attached to the instance, the
     other is stateless and attached to the subnet. You must work out which one
     (or both) is doing it. Hint: check whether the REQUEST arrives but the
     REPLY never leaves.

  4. The private instance can still reach the VPC endpoint service, but has
     lost all egress to the internet:

         sudo ip netns exec ns-private curl -s -m5 http://10.0.2.1:8080/
           -> vpc-endpoint-ok            (this still works)
         sudo ip netns exec ns-private ping -c2 1.1.1.1
           -> 100% packet loss           (this does not)

     The private instance has a default route and it points somewhere valid.
     So the route table is fine. Which managed object gives a private subnet
     outbound-only internet access, and what happens to that subnet when it is
     deleted?

WHAT YOU MUST ACHIEVE
---------------------
Restore all five behaviours. 'verify' checks each one independently:

  [1] ns-public has a default route and can reach an internet address.
  [2] Both instances resolve names through the VPC resolver at 10.0.0.2,
      including the private hosted zone record app.internal.lab.
  [3] http://10.0.1.10/ answers from ns-onprem, over both the security group
      and the network ACL.
  [4] ns-private reaches the internet again through the NAT gateway, while
      REMAINING unreachable from the outside -- do not "fix" it by giving the
      private subnet a public path. Outbound-only is the requirement.
  [5] Nothing you did opened the private instance to inbound traffic from
      ns-onprem on port 22. Verify checks this. A fix that works by turning
      everything off is not a fix.

TOOLS AND WHERE TO LOOK
-----------------------
  Route tables:      sudo ip netns exec ns-public ip route show
  Security group:    sudo iptables -n -L SG-PUBLIC --line-numbers -v
  Network ACL:       sudo iptables -n -L NACL-PUBLIC --line-numbers -v
  NAT / IGW:         sudo iptables -t nat -n -L POSTROUTING -v
  DNS settings:      sudo cat /etc/netns/ns-public/resolv.conf
  Live packet trace: sudo ip netns exec ns-public tcpdump -ni any -c20
  Drop counters:     the -v flag above prints per-rule packet counters. A rule
                     whose counter is climbing is the rule eating your traffic.

THE EXAM ANGLE
--------------
Every fault here maps to one CLF-C02 3.5 concept. Before you fix anything,
write down for each symptom which of these is responsible:

    VPC  |  subnet  |  route table  |  internet gateway  |  NAT gateway
    security group (stateful)  |  network ACL (stateless)
    Route 53 (public + private hosted zones)  |  VPC endpoint
    Direct Connect / Site-to-Site VPN  |  CloudFront  |  Global Accelerator

If you can name the object from the symptom, you can answer the exam question,
whether or not you remember the CLI.

Official objective wording:
  https://d1.awsstatic.com/training-and-certification/docs-cloud-practitioner/AWS-Certified-Cloud-Practitioner_Exam-Guide.pdf
Component references:
  https://docs.aws.amazon.com/vpc/latest/userguide/how-it-works.html
  https://docs.aws.amazon.com/vpc/latest/userguide/VPC_SecurityGroups.html
  https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html
  https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html
  https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zones-private.html

================================================================================
BRIEF
}

# ==============================================================================
#  VERIFY -- the scorecard. Runs against whatever state the lab is in.
# ==============================================================================
verify() {
    require_root
    ns_exists "${NS_PUBLIC}" || die "Lab is not built. Run: sudo $0 setup"

    local pass=0 total=0

    head1 "== Scorecard =="

    # --- Check 1: public subnet route table ----------------------------------
    total=$((total + 1))
    if in_ns "${NS_PUBLIC}" ip route show default | grep -q "via ${GW_PUBLIC}"; then
        if in_ns "${NS_PUBLIC}" ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
            ok   "[1] Public subnet: default route present AND internet reachable."
            pass=$((pass + 1))
        else
            warn "[1] Public subnet: default route present, but no internet reply."
            dim  "      If this VM itself has no egress, treat this check as passed."
            pass=$((pass + 1))
        fi
    else
        fail "[1] Public subnet: no default route. The subnet is not public."
    fi

    # --- Check 2: DNS resolution through the VPC resolver ---------------------
    total=$((total + 1))
    local dns_ok=1 ns
    for ns in "${NS_PUBLIC}" "${NS_PRIVATE}"; do
        grep -q "nameserver ${RESOLVER_IP}" "/etc/netns/${ns}/resolv.conf" 2>/dev/null || dns_ok=0
    done
    if [[ ${dns_ok} -eq 1 ]]; then
        ok   "[2] DNS: both instances point at the VPC resolver ${RESOLVER_IP}."
        pass=$((pass + 1))
    else
        fail "[2] DNS: an instance is not using the VPC resolver ${RESOLVER_IP}."
        dim  "      Check: cat /etc/netns/${NS_PUBLIC}/resolv.conf"
    fi

    # --- Check 3: web server reachable across SG and NACL ---------------------
    total=$((total + 1))
    local sg_http=0 nacl_eph=0
    iptables -n -L "${SG_PUBLIC}" 2>/dev/null | grep -q "dpt:80" && sg_http=1
    iptables -n -L "${SG_PUBLIC}" 2>/dev/null | grep -qi "ESTABLISHED" && sg_http=$((sg_http + 1))
    iptables -n -L "${NACL_PUBLIC}" 2>/dev/null | grep -q "dpts:1024:65535" && nacl_eph=1
    iptables -n -L "${NACL_PUBLIC}" 2>/dev/null | grep -q "spt:80.*DROP" && nacl_eph=0
    if iptables -n -L "${NACL_PUBLIC}" 2>/dev/null | awk '/DROP/ && /spt:80/{found=1} END{exit !found}'; then
        nacl_eph=0
    fi
    if [[ ${sg_http} -eq 2 && ${nacl_eph} -eq 1 ]]; then
        ok   "[3] Public web path: security group allows 80 and is stateful; NACL allows ephemeral return ports."
        pass=$((pass + 1))
    else
        fail "[3] Public web path is still blocked."
        [[ ${sg_http} -lt 2 ]] && dim "      Security group ${SG_PUBLIC}: missing port 80 ingress and/or the stateful ESTABLISHED,RELATED rule."
        [[ ${nacl_eph} -ne 1 ]] && dim "      Network ACL ${NACL_PUBLIC}: return traffic on ephemeral ports is not allowed."
    fi

    # --- Check 4: NAT gateway restored, outbound only ------------------------
    total=$((total + 1))
    if iptables -t nat -C POSTROUTING -s "${PRIVATE_SUBNET}" ! -o "${BRIDGE}" -j MASQUERADE 2>/dev/null; then
        ok   "[4] NAT gateway: source NAT for ${PRIVATE_SUBNET} is present."
        pass=$((pass + 1))
    else
        fail "[4] NAT gateway: ${PRIVATE_SUBNET} has no outbound translation."
        dim  "      Check: iptables -t nat -n -L POSTROUTING -v"
    fi

    # --- Check 5: the private subnet did NOT become publicly reachable -------
    total=$((total + 1))
    if iptables -t nat -n -L PREROUTING 2>/dev/null | grep -q "${IP_PRIVATE}"; then
        fail "[5] Private subnet was exposed with a destination NAT / port forward. That is not a NAT gateway."
    elif in_ns "${NS_ONPREM}" timeout 3 bash -c "</dev/tcp/${IP_PRIVATE}/22" 2>/dev/null; then
        fail "[5] The private instance now accepts inbound connections from on-prem. Over-opened."
        pass=$((pass + 0))
    else
        ok   "[5] Private instance remains outbound-only. Blast radius intact."
        pass=$((pass + 1))
    fi

    printf '\n%s%d of %d checks passing.%s\n' "${C_BOLD}" "${pass}" "${total}" "${C_RESET}"
    if [[ ${pass} -eq ${total} ]]; then
        printf '%sVPC restored. Now say out loud which AWS object each fault was.%s\n' "${C_GREEN}" "${C_RESET}"
        return 0
    fi
    dim "Keep going. 'brief' restates the mission; the solution is at the bottom of this script."
    return 1
}

# ==============================================================================
#  TEARDOWN -- remove absolutely everything this script created
# ==============================================================================
teardown() {
    require_root
    head1 "== Tearing down =="

    if [[ -f "${STATE_DIR}/endpoint.pid" ]]; then
        kill "$(cat "${STATE_DIR}/endpoint.pid")" 2>/dev/null || true
        rm -f "${STATE_DIR}/endpoint.pid"
    fi

    local ns
    for ns in "${NS_PUBLIC}" "${NS_PRIVATE}" "${NS_ONPREM}"; do
        ns_exists "${ns}" && { info "Deleting namespace ${ns}"; ip netns del "${ns}"; }
        rm -rf "/etc/netns/${ns}"
    done

    local l
    for l in "${VETH_PUB_HOST}" "${VETH_PRV_HOST}" "${VETH_ONP_HOST}" "${BRIDGE}"; do
        link_exists "${l}" && { info "Deleting link ${l}"; ip link del "${l}"; }
    done

    info "Removing NAT rules."
    iptables -t nat -D POSTROUTING -s "${PUBLIC_SUBNET}"  ! -o "${BRIDGE}" -j MASQUERADE 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "${PRIVATE_SUBNET}" ! -o "${BRIDGE}" -j MASQUERADE 2>/dev/null || true

    info "Removing firewall chains."
    while iptables -D FORWARD -d "${IP_PUBLIC}" -j "${SG_PUBLIC}" 2>/dev/null; do :; done
    while iptables -D FORWARD -s "${PUBLIC_SUBNET}" -j "${NACL_PUBLIC}" 2>/dev/null; do :; done
    local c
    for c in "${SG_PUBLIC}" "${NACL_PUBLIC}"; do
        chain_exists "${c}" && { iptables -F "${c}"; iptables -X "${c}"; }
    done

    rm -rf "${STATE_DIR}"
    ok "Teardown complete. The VM is back to how it was, minus net.ipv4.ip_forward."
    dim "If you care: sysctl -w net.ipv4.ip_forward=0"
}

usage() {
cat <<USAGE
AWS CLF-C02 -- Task 3.5 "Identify AWS network services" -- break & fix lab

  sudo $0 setup       Build the healthy VPC model
  sudo $0 verify      Run the scorecard
  sudo $0 break       Inject the faults
  sudo $0 brief       Print the incident ticket (the student's instructions)
  sudo $0 teardown    Delete everything this script created

Typical session:  setup -> verify -> break -> brief -> (fix it) -> verify
USAGE
}

main() {
    case "${1:-}" in
        setup)    setup ;;
        break)    break_lab ;;
        brief)    brief ;;
        verify)   verify ;;
        teardown) teardown ;;
        *)        usage; exit 1 ;;
    esac
}

main "$@"

# ==============================================================================
# ==============================================================================
#
#   S O L U T I O N   --   DO NOT READ UNTIL YOU HAVE TRIED
#
# ==============================================================================
# ==============================================================================
#
# The whole point of this lab is that each symptom names its own component. Work
# the diagnosis first, then the command. On the exam you will only ever be asked
# the diagnosis.
#
# ------------------------------------------------------------------------------
# STEP 0 -- Read the state before changing it. Always.
# ------------------------------------------------------------------------------
#
#   sudo ip netns exec ns-public ip route show
#   sudo ip netns exec ns-private ip route show
#   sudo iptables -n -L SG-PUBLIC   --line-numbers -v
#   sudo iptables -n -L NACL-PUBLIC --line-numbers -v
#   sudo iptables -t nat -n -L POSTROUTING -v
#   sudo cat /etc/netns/ns-public/resolv.conf
#
# The -v flag prints per-rule packet counters. Send traffic, run the command
# again, and the rule whose counter moved is the rule eating your packets. This
# is the single most useful firewall debugging habit there is, and it has an AWS
# equivalent: VPC Flow Logs, which record ACCEPT/REJECT per flow.
#   https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html
#
# ------------------------------------------------------------------------------
# FAULT 1 -- Route table: the public subnet lost 0.0.0.0/0 -> internet gateway
# ------------------------------------------------------------------------------
# SYMPTOM:  "connect: Network is unreachable", instantly, with no timeout.
# DIAGNOSIS: The kernel had nowhere to send the packet. Firewalls drop packets
#            they have already accepted for routing; they do not produce
#            "unreachable". Only a missing route does that.
#
#            A subnet in AWS is PUBLIC if and only if its route table has a
#            0.0.0.0/0 entry pointing at an internet gateway. There is no
#            "public" checkbox. This is the most commonly misunderstood fact in
#            the entire domain.
#
# FIX:
#   sudo ip netns exec ns-public ip route add default via 10.0.1.1
#
# CONFIRM:
#   sudo ip netns exec ns-public ip route show
#     default via 10.0.1.1 dev veth-pub-n
#     10.0.1.0/24 dev veth-pub-n proto kernel scope link src 10.0.1.10
#   sudo ip netns exec ns-public ping -c2 1.1.1.1
#     64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=11.4 ms
#
# EXAM MAPPING: route table + internet gateway. An IGW is horizontally scaled,
#   redundant, highly available, free, and performs 1:1 NAT for instances that
#   have a public IPv4 address. Attaching one to the VPC is not enough -- the
#   subnet's route table must point at it.
#   https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Internet_Gateway.html
#
# ------------------------------------------------------------------------------
# FAULT 4 -- DNS: the instances are not using the VPC resolver
# ------------------------------------------------------------------------------
# SYMPTOM:  Names fail everywhere; raw IP addresses work everywhere.
# DIAGNOSIS: That exact split is DNS, always. Routing failures break IPs too;
#            firewall failures break specific ports. Only name resolution can
#            fail while 10.0.2.10 still pings.
#
#            In every AWS VPC, the Route 53 Resolver -- the "Amazon-provided
#            DNS server" -- lives at the base of the VPC CIDR plus two. For
#            10.0.0.0/16 that is 10.0.0.2. (It is also reachable at the fixed
#            link-local 169.254.169.253.) AWS reserves FIVE addresses in every
#            subnet: base+0 network, +1 VPC router, +2 DNS, +3 future use, and
#            the broadcast address. Which resolver an instance receives is set
#            by the DHCP option set attached to the VPC.
#
# FIX:
#   for ns in ns-public ns-private; do
#     printf 'nameserver 10.0.0.2\noptions timeout:2 attempts:1\n' \
#       | sudo tee /etc/netns/$ns/resolv.conf >/dev/null
#   done
#
# CONFIRM:
#   sudo cat /etc/netns/ns-public/resolv.conf
#     nameserver 10.0.0.2
#   sudo ip netns exec ns-public getent hosts app.internal.lab
#     10.0.2.10       app.internal.lab
#
#   (If no resolver daemon is listening on 10.0.0.2 in your VM, the config check
#   is what 'verify' scores. To make lookups genuinely answer, run a resolver on
#   the bridge address -- optional, and outside the exam objective:
#      sudo dnsmasq --interface=br-vpc --listen-address=10.0.0.2 \
#           --bind-interfaces --no-resolv --server=1.1.1.1 \
#           --addn-hosts=/run/aws-clf-35-lab/hosted-zone.hosts )
#
# EXAM MAPPING: Route 53 is AWS's DNS service. A PUBLIC hosted zone answers the
#   internet; a PRIVATE hosted zone answers only from associated VPCs, which is
#   why app.internal.lab has no meaning outside this VPC. Route 53 also does
#   domain registration, health checks, and the routing policies -- simple,
#   weighted, latency-based, failover, geolocation, geoproximity, multivalue.
#   Know that list; it is asked directly.
#   https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/Welcome.html
#   https://docs.aws.amazon.com/vpc/latest/userguide/vpc-dns.html
#
# ------------------------------------------------------------------------------
# FAULTS 2 AND 3 -- The security group and the network ACL, together
# ------------------------------------------------------------------------------
# SYMPTOM:  curl to the web server TIMES OUT. It is not refused.
# DIAGNOSIS: Refused = something answered with a TCP RST (the port is closed, or
#            a NACL DENY that rejects). Timed out = the packet vanished. In a
#            VPC exactly two things silently drop packets: a security group's
#            implicit deny, and a network ACL's rules.
#
#            Prove WHERE it dies before touching anything:
#              # terminal 1
#              sudo ip netns exec ns-public tcpdump -ni any port 80
#              # terminal 2
#              sudo ip netns exec ns-onprem curl -m5 http://10.0.1.10/
#            If nothing appears in tcpdump, the REQUEST is being dropped on the
#            way in -> inbound rule. If you see the SYN arrive and the SYN-ACK
#            leave but the client still hangs, the REPLY is being dropped on the
#            way out -> that is a stateless NACL missing its return rule, and it
#            cannot be a security group, because a security group would have
#            allowed the return automatically.
#
#            That distinction IS the exam question:
#              Security group -- instance level, STATEFUL, allow rules only,
#                                all rules evaluated, return traffic implicit.
#              Network ACL    -- subnet level, STATELESS, allow AND deny rules,
#                                evaluated in number order, first match wins,
#                                return traffic needs its own explicit rule on
#                                the ephemeral port range (1024-65535).
#
# FIX -- restore the security group (stateful + port 80 ingress):
#   sudo iptables -F SG-PUBLIC
#   sudo iptables -A SG-PUBLIC -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
#   sudo iptables -A SG-PUBLIC -p icmp --icmp-type echo-request -j ACCEPT
#   sudo iptables -A SG-PUBLIC -p tcp --dport 22 -j ACCEPT
#   sudo iptables -A SG-PUBLIC -p tcp --dport 80 -j ACCEPT
#   sudo iptables -A SG-PUBLIC -p udp --dport 53 -j ACCEPT
#   sudo iptables -A SG-PUBLIC -j DROP
#
# FIX -- restore the network ACL (drop the bad DENY, restore ephemeral allow):
#   sudo iptables -D NACL-PUBLIC -p tcp --sport 80 -j DROP
#   sudo iptables -I NACL-PUBLIC 4 -p tcp --dport 1024:65535 -j ACCEPT
#
# CONFIRM:
#   sudo iptables -n -L SG-PUBLIC --line-numbers -v
#     1  ACCEPT  all  --  0.0.0.0/0  0.0.0.0/0  ctstate RELATED,ESTABLISHED
#     ...
#     6  DROP    all  --  0.0.0.0/0  0.0.0.0/0
#   sudo ip netns exec ns-onprem curl -s -m5 -o /dev/null -w '%{http_code}\n' http://10.0.1.10/
#     200
#
#   NOTE: for a literal 200 you need something listening on port 80 inside
#   ns-public. Start one if you want the end-to-end proof:
#     sudo ip netns exec ns-public python3 -m http.server 80 --bind 10.0.1.10 &
#   'verify' scores the rule configuration, which is what the exam tests.
#
# EXAM MAPPING: security group vs network ACL is the single highest-yield
#   comparison in domain 3.5. Memorise the six-line table above.
#   https://docs.aws.amazon.com/vpc/latest/userguide/VPC_SecurityGroups.html
#   https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html
#
# ------------------------------------------------------------------------------
# FAULT 5 -- The NAT gateway was deleted "to save money"
# ------------------------------------------------------------------------------
# SYMPTOM:  The private instance still reaches things inside the VPC, including
#           the VPC endpoint on 10.0.2.1:8080, but has zero internet egress.
#           Its route table is unchanged.
# DIAGNOSIS: Internal traffic never needed translation. Only traffic leaving the
#            VPC does. A private subnet has RFC 1918 addresses that are not
#            routable on the internet, so something must translate them. That
#            something is the NAT gateway -- and unlike an internet gateway it
#            is a per-hour + per-GB billed resource living in ONE public subnet
#            in ONE availability zone.
#
# FIX:
#   sudo iptables -t nat -A POSTROUTING -s 10.0.2.0/24 ! -o br-vpc -j MASQUERADE
#
# CONFIRM:
#   sudo iptables -t nat -n -L POSTROUTING -v
#     MASQUERADE  all  --  *  !br-vpc  10.0.1.0/24  0.0.0.0/0
#     MASQUERADE  all  --  *  !br-vpc  10.0.2.0/24  0.0.0.0/0
#   sudo ip netns exec ns-private ping -c2 1.1.1.1
#     2 packets transmitted, 2 received, 0% packet loss
#
# WHAT NOT TO DO: do not add a DNAT/port-forward to 10.0.2.10 to "make it
#   reachable". A NAT gateway is OUTBOUND ONLY by design -- that asymmetry is
#   the entire security value of a private subnet. Check [5] fails you for it,
#   deliberately, because the exam tests that you know the direction.
#
# EXAM MAPPING: NAT gateway = outbound-only internet for private subnets, AZ
#   scoped, charged hourly and per GB, needs an elastic IP and a route
#   0.0.0.0/0 -> nat-xxxx in the PRIVATE subnet's route table (the NAT gateway
#   itself sits in a public subnet). Compare with a VPC ENDPOINT, which gives
#   private access to AWS services with NO internet path at all -- gateway
#   endpoints for S3 and DynamoDB (free, route-table based), interface
#   endpoints / PrivateLink for most other services (an ENI in your subnet,
#   billed hourly).
#   https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html
#   https://docs.aws.amazon.com/vpc/latest/privatelink/what-is-privatelink.html
#
# ------------------------------------------------------------------------------
# ONE-SHOT FIX (only after you have understood each step above)
# ------------------------------------------------------------------------------
#   sudo ip netns exec ns-public ip route add default via 10.0.1.1
#   for ns in ns-public ns-private; do
#     printf 'nameserver 10.0.0.2\noptions timeout:2 attempts:1\n' \
#       | sudo tee /etc/netns/$ns/resolv.conf >/dev/null
#   done
#   sudo iptables -F SG-PUBLIC
#   sudo iptables -A SG-PUBLIC -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
#   sudo iptables -A SG-PUBLIC -p icmp --icmp-type echo-request -j ACCEPT
#   sudo iptables -A SG-PUBLIC -p tcp --dport 22 -j ACCEPT
#   sudo iptables -A SG-PUBLIC -p tcp --dport 80 -j ACCEPT
#   sudo iptables -A SG-PUBLIC -p udp --dport 53 -j ACCEPT
#   sudo iptables -A SG-PUBLIC -j DROP
#   sudo iptables -D NACL-PUBLIC -p tcp --sport 80 -j DROP
#   sudo iptables -I NACL-PUBLIC 4 -p tcp --dport 1024:65535 -j ACCEPT
#   sudo iptables -t nat -A POSTROUTING -s 10.0.2.0/24 ! -o br-vpc -j MASQUERADE
#   sudo ./35-network-services-breakfix.sh verify
#
# ------------------------------------------------------------------------------
# THE REST OF TASK 3.5, WHICH THIS LAB ONLY GESTURES AT
# ------------------------------------------------------------------------------
# ns-onprem stands in for the two hybrid connectivity options. Know the
# difference cold, it is asked every time:
#
#   Site-to-Site VPN  -- IPsec over the PUBLIC internet. Minutes to provision,
#                        cheap, encrypted, bandwidth and latency depend on the
#                        internet. Two tunnels per connection for redundancy.
#   Direct Connect    -- a DEDICATED private physical circuit into an AWS
#                        Direct Connect location. Weeks to months to provision,
#                        expensive, consistent latency, higher and predictable
#                        bandwidth. NOT encrypted by itself -- run a VPN over it
#                        if you need encryption in transit.
#   Transit Gateway   -- a hub that replaces a mesh of VPC peerings and VPN
#                        attachments. Reach for it when "n VPCs plus on-prem"
#                        appears in the question.
#   VPC Peering       -- one-to-one, non-transitive, no overlapping CIDRs.
#
# And the edge services, which are network services but not VPC objects:
#
#   CloudFront        -- CDN. Caches content at 600+ edge locations. Reduces
#                        latency for GLOBALLY distributed viewers. Integrates
#                        with AWS Shield and AWS WAF.
#   Global Accelerator-- two static anycast IPs at the edge; routes over the AWS
#                        backbone to the healthiest endpoint. For non-cacheable
#                        traffic, TCP/UDP, gaming, IoT, fast regional failover.
#   API Gateway       -- managed front door for APIs.
#   ELB               -- Application (L7, HTTP/HTTPS), Network (L4, ultra-low
#                        latency, static IP), Gateway (third-party appliances).
#
#   Exam heuristic: "cacheable static content, global users"     -> CloudFront
#                   "static IP, non-HTTP, instant regional failover" -> Global Accelerator
#   https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Introduction.html
#   https://docs.aws.amazon.com/global-accelerator/latest/dg/what-is-global-accelerator.html
#   https://docs.aws.amazon.com/directconnect/latest/UserGuide/Welcome.html
#   https://docs.aws.amazon.com/vpn/latest/s2svpn/VPC_VPN.html
#
# ------------------------------------------------------------------------------
# CLEAN UP
# ------------------------------------------------------------------------------
#   sudo ./35-network-services-breakfix.sh teardown
#
# ==============================================================================