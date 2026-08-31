#!/usr/bin/env bash
#==============================================================================
#  LPIC-1 v5.0 -- Exam 102-500 -- Topic 110.3: Securing data with encryption
#  BREAK & FIX LAB -- RUN ONLY ON A DISPOSABLE LABORATORY VM
#
#  What this script does
#  ---------------------
#  1. Builds a self-contained, known-good lab inside two throwaway accounts
#     (lpicclient -> lpicserver, over ssh to localhost) plus a GnuPG keyring
#     and an encrypted file, and PROVES the golden state works before it
#     touches anything.
#  2. Snapshots that golden state under /root/lpic-110.3-lab/backup.
#  3. Injects five independent faults, all of them confined to the two lab
#     accounts.  It never edits /etc/ssh/*, never restarts or reconfigures
#     sshd, never touches a pre-existing user, and never writes outside
#     /home/lpicclient, /home/lpicserver and /root/lpic-110.3-lab.
#  4. Prints the mission brief.
#
#  Usage
#  -----
#     ./110.3-break-and-fix.sh break     # build the lab and break it (default)
#     ./110.3-break-and-fix.sh verify    # grade the repair
#     ./110.3-break-and-fix.sh status    # dump the current state of the lab
#     ./110.3-break-and-fix.sh restore   # delete the lab entirely (full reset)
#
#  Non-interactive:  LAB_CONFIRM=yes ./110.3-break-and-fix.sh break
#
#  Official sources
#     https://www.lpi.org/our-certifications/exam-101-objectives/
#     https://www.lpi.org/our-certifications/exam-102-objectives/   (110.3)
#     https://man.openbsd.org/sshd.8      (AUTHORIZED_KEYS, StrictModes)
#     https://man.openbsd.org/ssh_config.5
#     https://www.gnupg.org/documentation/manuals/gnupg/
#==============================================================================

set -uo pipefail

LAB_ID="lpic1-110.3"
CLIENT_USER="lpicclient"
SERVER_USER="lpicserver"
CLIENT_HOME="/home/${CLIENT_USER}"
SERVER_HOME="/home/${SERVER_USER}"
LAB_ROOT="/root/lpic-110.3-lab"
BACKUP_DIR="${LAB_ROOT}/backup"
STATE_FILE="${LAB_ROOT}/lab.state"
SECRET_DIR="${CLIENT_HOME}/lab"
SECRET_PLAIN="${SECRET_DIR}/secret.txt"
SECRET_CIPHER="${SECRET_DIR}/secret.txt.gpg"
SSH_FLAG_FILE="${SERVER_HOME}/lab/ssh-flag"
GPG_UID="LPIC Lab Client <lab-client@example.invalid>"
SSH_PORT=22
KH_HOSTS="localhost,127.0.0.1"

if [ -t 1 ]; then
    C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
    C_B=$'\033[1;34m'; C_0=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi

log()  { printf '%s[ .. ]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { fail "$*"; exit 1; }
rule() { printf '%s\n' "------------------------------------------------------------------------"; }

as_client() { su - "$CLIENT_USER" -c "$1"; }

#------------------------------------------------------------------------------
# Preflight
#------------------------------------------------------------------------------
need_root() {
    [ "$(id -u)" -eq 0 ] || die "This lab must run as root (it creates users and edits their homes)."
}

detect_ssh_port() {
    local p
    p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
    [ -n "${p:-}" ] && SSH_PORT="$p"
    if [ "$SSH_PORT" != "22" ]; then
        KH_HOSTS="[localhost]:${SSH_PORT},[127.0.0.1]:${SSH_PORT}"
    fi
}

preflight() {
    local missing=() c
    for c in ssh ssh-keygen ssh-keyscan sshd gpg gpgconf su useradd userdel chmod chown awk; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ ${#missing[@]} -eq 0 ] || die "Missing required commands: ${missing[*]} (install openssh-server, openssh-clients, gnupg2)."

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-active --quiet sshd 2>/dev/null && ! systemctl is-active --quiet ssh 2>/dev/null; then
            warn "sshd is not active; trying to start it."
            systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null || true
        fi
    fi
    pgrep -x sshd >/dev/null 2>&1 || die "sshd is not running. Start it and re-run: systemctl start sshd"

    detect_ssh_port
    log "sshd is listening on port ${SSH_PORT}."

    if grep -REis '^[[:space:]]*(AllowUsers|AllowGroups|DenyUsers|DenyGroups)' \
         /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | grep -q .; then
        warn "sshd restricts logins with Allow*/Deny* directives. The lab users may need to be added there."
    fi
    if sshd -T 2>/dev/null | grep -qi '^pubkeyauthentication no'; then
        die "sshd has 'PubkeyAuthentication no'. This lab needs public key authentication enabled."
    fi
}

confirm_disposable() {
    if [ "${LAB_CONFIRM:-}" = "yes" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        die "Refusing to run non-interactively without LAB_CONFIRM=yes."
    fi
    rule
    cat <<EOF
${C_R}WARNING${C_0} -- this script deliberately breaks a working configuration.

It creates two throwaway users (${CLIENT_USER}, ${SERVER_USER}) and damages ONLY
their SSH and GnuPG setup.  It does not modify /etc/ssh, does not restart sshd,
and does not touch any other account.  Even so, run it on a laboratory VM you
can throw away, never on a machine you care about.

Host: $(hostname) -- Kernel: $(uname -r)
EOF
    rule
    printf 'Type exactly BREAK IT to continue: '
    local answer; read -r answer
    [ "$answer" = "BREAK IT" ] || die "Aborted by the operator."
}

#------------------------------------------------------------------------------
# Golden state
#------------------------------------------------------------------------------
rand_token() { head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

create_users() {
    local u home
    for u in "$CLIENT_USER" "$SERVER_USER"; do
        if id "$u" >/dev/null 2>&1; then
            die "User '$u' already exists. Run '$0 restore' first, or pick a clean VM."
        fi
        useradd -m -s /bin/bash -c "LPIC-1 110.3 lab account" "$u" \
            || die "useradd $u failed."
    done
    for home in "$CLIENT_HOME" "$SERVER_HOME"; do
        chmod 0700 "$home"
    done
    ok "Created lab accounts ${CLIENT_USER} and ${SERVER_USER} (passwords locked; key auth only)."
}

build_ssh() {
    install -d -m 0700 -o "$CLIENT_USER" -g "$CLIENT_USER" "${CLIENT_HOME}/.ssh"
    install -d -m 0700 -o "$SERVER_USER" -g "$SERVER_USER" "${SERVER_HOME}/.ssh"
    install -d -m 0755 -o "$SERVER_USER" -g "$SERVER_USER" "${SERVER_HOME}/lab"
    install -d -m 0700 -o "$CLIENT_USER" -g "$CLIENT_USER" "$SECRET_DIR"

    ssh-keygen -q -t ed25519 -N '' -C "${LAB_ID} client key" \
        -f "${CLIENT_HOME}/.ssh/id_ed25519" </dev/null \
        || die "ssh-keygen failed."
    chown "${CLIENT_USER}:${CLIENT_USER}" "${CLIENT_HOME}/.ssh/id_ed25519" "${CLIENT_HOME}/.ssh/id_ed25519.pub"
    chmod 0600 "${CLIENT_HOME}/.ssh/id_ed25519"
    chmod 0644 "${CLIENT_HOME}/.ssh/id_ed25519.pub"

    install -m 0600 -o "$SERVER_USER" -g "$SERVER_USER" \
        "${CLIENT_HOME}/.ssh/id_ed25519.pub" "${SERVER_HOME}/.ssh/authorized_keys"

    printf 'SSH-OK-%s\n' "$LAB_TOKEN" > "$SSH_FLAG_FILE"
    chown "${SERVER_USER}:${SERVER_USER}" "$SSH_FLAG_FILE"
    chmod 0644 "$SSH_FLAG_FILE"

    {
        printf '# %s lab -- genuine host keys, harvested with ssh-keyscan\n' "$LAB_ID"
        ssh-keyscan -p "$SSH_PORT" -t rsa,ecdsa,ed25519 localhost 127.0.0.1 2>/dev/null
    } > "${CLIENT_HOME}/.ssh/known_hosts"
    chown "${CLIENT_USER}:${CLIENT_USER}" "${CLIENT_HOME}/.ssh/known_hosts"
    chmod 0644 "${CLIENT_HOME}/.ssh/known_hosts"
    grep -q 'ssh-' "${CLIENT_HOME}/.ssh/known_hosts" || die "ssh-keyscan returned no host key for localhost:${SSH_PORT}."

    cat > "${CLIENT_HOME}/.ssh/config" <<EOF
# ${LAB_ID} lab -- client configuration (ssh_config(5))
Host localhost
    HostName localhost
    Port ${SSH_PORT}
    User ${SERVER_USER}
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
    chown "${CLIENT_USER}:${CLIENT_USER}" "${CLIENT_HOME}/.ssh/config"
    chmod 0600 "${CLIENT_HOME}/.ssh/config"

    command -v restorecon >/dev/null 2>&1 && restorecon -RF "$CLIENT_HOME" "$SERVER_HOME" >/dev/null 2>&1

    local out
    out="$(as_client "ssh -o BatchMode=yes -o ConnectTimeout=8 ${SERVER_USER}@localhost 'cat ${SSH_FLAG_FILE}'" 2>&1)"
    if [ "$out" != "SSH-OK-${LAB_TOKEN}" ]; then
        printf '%s\n' "$out" >&2
        die "Golden SSH state does not work; refusing to break an already broken system."
    fi
    ok "Golden state proven: ${CLIENT_USER} authenticates to ${SERVER_USER}@localhost with a key."
}

build_gpg() {
    as_client "gpg --batch --quiet --passphrase '' --pinentry-mode loopback \
               --quick-generate-key '${GPG_UID}' default default never" >/dev/null 2>&1 \
        || die "gpg --quick-generate-key failed (GnuPG 2.1+ required)."

    printf 'GPG-OK-%s\n' "$LAB_TOKEN" > "$SECRET_PLAIN"
    chown "${CLIENT_USER}:${CLIENT_USER}" "$SECRET_PLAIN"
    chmod 0600 "$SECRET_PLAIN"

    as_client "gpg --batch --yes --quiet --trust-model always \
               --recipient '${GPG_UID}' --output '${SECRET_CIPHER}' --encrypt '${SECRET_PLAIN}'" \
        || die "gpg --encrypt failed."
    rm -f "$SECRET_PLAIN"

    local out
    out="$(as_client "gpg --batch --yes --quiet --decrypt '${SECRET_CIPHER}'" 2>/dev/null)"
    [ "$out" = "GPG-OK-${LAB_TOKEN}" ] || die "Golden GnuPG state does not decrypt; aborting before any damage."
    ok "Golden state proven: ${CLIENT_USER} decrypts ${SECRET_CIPHER} with the private key."
}

snapshot() {
    install -d -m 0700 "$LAB_ROOT" "$BACKUP_DIR"
    tar -C /home -cpf "${BACKUP_DIR}/golden-homes.tar" "${CLIENT_USER#/}" "${SERVER_USER}" 2>/dev/null \
        || tar -C /home -cpf "${BACKUP_DIR}/golden-homes.tar" "$CLIENT_USER" "$SERVER_USER"
    chmod 0600 "${BACKUP_DIR}/golden-homes.tar"
    {
        printf 'LAB_ID=%s\n' "$LAB_ID"
        printf 'LAB_TOKEN=%s\n' "$LAB_TOKEN"
        printf 'SSH_PORT=%s\n' "$SSH_PORT"
        printf 'CREATED_USERS=yes\n'
    } > "$STATE_FILE"
    chmod 0600 "$STATE_FILE"
    ok "Golden snapshot stored in ${BACKUP_DIR} (instructor escape hatch, root-only)."
}

#------------------------------------------------------------------------------
# The five faults
#------------------------------------------------------------------------------
fault_1_server_modes() {
    # sshd StrictModes: refuses a key whose directory chain is writable by others.
    chmod 0777 "$SERVER_HOME"
    chmod 0777 "${SERVER_HOME}/.ssh"
    chmod 0666 "${SERVER_HOME}/.ssh/authorized_keys"
    ok "Fault 1 injected (server side)."
}

fault_2_known_hosts() {
    # Host key mismatch: exactly what a MITM would look like.
    local tmpd fake
    tmpd="$(mktemp -d)"
    ssh-keygen -q -t ed25519 -N '' -C 'not-the-real-host' -f "${tmpd}/fake" </dev/null
    fake="$(awk '{print $1" "$2}' "${tmpd}/fake.pub")"
    {
        printf '# %s lab -- known_hosts\n' "$LAB_ID"
        printf '%s %s\n' "$KH_HOSTS" "$fake"
    } > "${CLIENT_HOME}/.ssh/known_hosts"
    chown "${CLIENT_USER}:${CLIENT_USER}" "${CLIENT_HOME}/.ssh/known_hosts"
    chmod 0644 "${CLIENT_HOME}/.ssh/known_hosts"
    rm -rf "$tmpd"
    ok "Fault 2 injected (client side)."
}

fault_3_ssh_config() {
    # IdentitiesOnly yes + an IdentityFile that does not exist = no key is ever offered.
    cat > "${CLIENT_HOME}/.ssh/config" <<EOF
# ${LAB_ID} lab -- client configuration (ssh_config(5))
Host localhost
    HostName localhost
    Port ${SSH_PORT}
    User ${SERVER_USER}
    IdentityFile ~/.ssh/id_ed25519_backup
    IdentitiesOnly yes
EOF
    chown "${CLIENT_USER}:${CLIENT_USER}" "${CLIENT_HOME}/.ssh/config"
    chmod 0600 "${CLIENT_HOME}/.ssh/config"
    ok "Fault 3 injected (client side)."
}

fault_4_private_key_mode() {
    # ssh(1) refuses to use a private key readable by group or other.
    chmod 0644 "${CLIENT_HOME}/.ssh/id_ed25519"
    ok "Fault 4 injected (client side)."
}

fault_5_gnupg() {
    as_client "gpgconf --kill all" >/dev/null 2>&1
    pkill -u "$CLIENT_USER" gpg-agent >/dev/null 2>&1
    install -d -m 0700 -o "$CLIENT_USER" -g "$CLIENT_USER" "${CLIENT_HOME}/keys-backup"
    mv "${CLIENT_HOME}/.gnupg/private-keys-v1.d" "${CLIENT_HOME}/keys-backup/private-keys-v1.d"
    chown -R "${CLIENT_USER}:${CLIENT_USER}" "${CLIENT_HOME}/keys-backup"
    chmod 0777 "${CLIENT_HOME}/.gnupg"
    ok "Fault 5 injected (GnuPG)."
}

#------------------------------------------------------------------------------
# Mission brief
#------------------------------------------------------------------------------
brief() {
    rule
    cat <<EOF
${C_Y}LPIC-1 110.3 -- BREAK & FIX -- MISSION BRIEF${C_0}

TOPOLOGY
  Two throwaway accounts on this VM:
    ${CLIENT_USER}  -- the client. Owns an ed25519 keypair, an ssh client
                     configuration, a known_hosts file and a GnuPG keyring.
    ${SERVER_USER}  -- the target. Owns ~/.ssh/authorized_keys and a flag file.
  Passwords are locked on both accounts: public key authentication is the only
  way in. sshd itself is untouched and correctly configured.

  You work as root and step into the client with:  su - ${CLIENT_USER}

WHAT IS BROKEN
  Five independent faults, spread over two subsystems (OpenSSH client/server
  key authentication, and GnuPG). They are layered on purpose: the first error
  message hides the next one. Peel the onion, one error at a time.

SYMPTOMS YOU WILL SEE
  1) Run as ${CLIENT_USER}:   ssh ${SERVER_USER}@localhost
     A large banner reading
       WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
       ... POSSIBLE DNS SPOOFING / someone could be eavesdropping ...
       Host key verification failed.
     The session never even reaches the authentication phase.

  2) Once that is past, the connection ends in
       Permission denied (publickey).
     with, along the way, one or more of:
       Warning: Identity file ~/.ssh/id_ed25519_backup not accessible
       @@@ WARNING: UNPROTECTED PRIVATE KEY FILE! @@@
       ... this private key will be ignored.

  3) Even with a correct client, the server may still reject you. The client
     sees only "Permission denied (publickey)"; the reason is written on the
     SERVER side, in the sshd log:
       journalctl -u sshd -n 50      (or: tail -n 50 /var/log/auth.log)
       Authentication refused: bad ownership or modes for directory ...

  4) Run as ${CLIENT_USER}:   gpg --decrypt ~/lab/secret.txt.gpg
       gpg: WARNING: unsafe permissions on homedir '/home/${CLIENT_USER}/.gnupg'
       gpg: decryption failed: No secret key
     The plaintext no longer exists anywhere on disk. Nothing was deleted for
     good, though: everything you need is still inside ${CLIENT_HOME}.

YOUR OBJECTIVE
  A. As ${CLIENT_USER}, make this succeed without any prompt and without any
     command-line override (no -o StrictHostKeyChecking=no, no -i flag, no
     editing of /etc/ssh):
        ssh -o BatchMode=yes ${SERVER_USER}@localhost cat ${SSH_FLAG_FILE}
     It must print a line starting with SSH-OK-
  B. As ${CLIENT_USER}, make this print a line starting with GPG-OK-
        gpg --decrypt ${SECRET_CIPHER}
     with no permission warnings from gpg.
  C. Do it the secure way. Deleting known_hosts and blindly accepting whatever
     key appears is NOT a fix: verify the host key fingerprint against the
     server's own /etc/ssh/ssh_host_ed25519_key.pub before you trust it.

TOOLS THAT WILL DO THE WORK FOR YOU
  ssh -v / -vv          the client tells you which keys it offers and why
  journalctl -u sshd    the server tells you why it refused them
  ls -ld / ls -l        modes and ownership of ~, ~/.ssh and every file in it
  ssh-keygen -lf FILE   fingerprint of a key file
  ssh-keygen -F HOST    show the known_hosts entry for a host
  ssh-keygen -R HOST    remove the known_hosts entry for a host
  ssh-keyscan -p ${SSH_PORT} localhost
  sshd -T | grep -i -e strictmodes -e pubkey -e authorizedkeysfile
  gpgconf --list-dirs   where GnuPG really keeps its state
  gpg --list-secret-keys / gpg --list-packets FILE

GRADE YOURSELF
  ${C_B}$0 verify${C_0}
FULL RESET (removes both lab accounts and starts over)
  ${C_B}$0 restore${C_0}
EOF
    rule
}

#------------------------------------------------------------------------------
# Verify
#------------------------------------------------------------------------------
check() {
    local label="$1" result="$2" detail="${3:-}"
    if [ "$result" = "pass" ]; then
        printf '%s[PASS]%s %s\n' "$C_G" "$C_0" "$label"
    else
        printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$label"
        [ -n "$detail" ] && printf '       %s\n' "$detail"
        VERIFY_RC=1
    fi
}

mode_of() { stat -c '%a' "$1" 2>/dev/null; }
owner_of() { stat -c '%U' "$1" 2>/dev/null; }

verify() {
    [ -f "$STATE_FILE" ] || die "No lab state found. Run '$0 break' first."
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    VERIFY_RC=0
    rule
    printf '%sLPIC-1 110.3 -- verification%s\n' "$C_Y" "$C_0"
    rule

    pgrep -x sshd >/dev/null 2>&1 \
        && check "sshd is running" pass \
        || check "sshd is running" fail "systemctl start sshd"

    local m
    m="$(mode_of "${CLIENT_HOME}/.ssh/id_ed25519")"
    { [ "$m" = "600" ] || [ "$m" = "400" ]; } \
        && check "client private key mode is 0600 (mode ${m})" pass \
        || check "client private key mode" fail "~/.ssh/id_ed25519 is mode ${m:-missing}; ssh ignores group/other readable keys"

    m="$(mode_of "${SERVER_HOME}/.ssh")"
    [ "$m" = "700" ] \
        && check "server ~/.ssh mode is 0700" pass \
        || check "server ~/.ssh mode" fail "${SERVER_HOME}/.ssh is mode ${m:-missing}; StrictModes rejects it"

    m="$(mode_of "$SERVER_HOME")"
    case "$m" in
        700|750|755) check "server home is not group/other writable (mode ${m})" pass ;;
        *)           check "server home permissions" fail "${SERVER_HOME} is mode ${m:-missing}" ;;
    esac

    m="$(mode_of "${SERVER_HOME}/.ssh/authorized_keys")"
    { [ "$m" = "600" ] || [ "$m" = "644" ]; } \
        && check "authorized_keys is not writable by group/other (mode ${m})" pass \
        || check "authorized_keys permissions" fail "mode ${m:-missing}; 0600 is the correct value"

    local live stored
    live="$(ssh-keyscan -p "$SSH_PORT" -t ed25519 localhost 2>/dev/null | awk '{print $3}' | head -n1)"
    stored="$(as_client "ssh-keygen -F localhost 2>/dev/null" | awk '/ssh-ed25519/{print $3}' | head -n1)"
    if [ -n "$live" ] && [ "$live" = "$stored" ]; then
        check "known_hosts holds the real host key for localhost" pass
    else
        check "known_hosts host key" fail "the stored entry does not match the key sshd actually presents"
    fi

    local out
    out="$(as_client "ssh -o BatchMode=yes -o ConnectTimeout=8 ${SERVER_USER}@localhost 'cat ${SSH_FLAG_FILE}'" 2>&1)"
    if [ "$out" = "SSH-OK-${LAB_TOKEN}" ]; then
        check "OBJECTIVE A -- non-interactive public key login works" pass
    else
        check "OBJECTIVE A -- non-interactive public key login" fail "$(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"
    fi

    m="$(mode_of "${CLIENT_HOME}/.gnupg")"
    [ "$m" = "700" ] \
        && check "GnuPG home directory mode is 0700" pass \
        || check "GnuPG home directory mode" fail "${CLIENT_HOME}/.gnupg is mode ${m:-missing}"

    [ "$(owner_of "${CLIENT_HOME}/.gnupg")" = "$CLIENT_USER" ] \
        && check "GnuPG home directory is owned by ${CLIENT_USER}" pass \
        || check "GnuPG home directory ownership" fail "must be owned by ${CLIENT_USER}"

    out="$(as_client "gpg --batch --yes --quiet --decrypt '${SECRET_CIPHER}'" 2>/dev/null)"
    if [ "$out" = "GPG-OK-${LAB_TOKEN}" ]; then
        check "OBJECTIVE B -- the encrypted file decrypts" pass
    else
        check "OBJECTIVE B -- the encrypted file decrypts" fail "gpg --decrypt did not return the expected plaintext"
    fi

    rule
    if [ "$VERIFY_RC" -eq 0 ]; then
        printf '%sALL CHECKS PASSED. The lab is repaired.%s\n' "$C_G" "$C_0"
    else
        printf '%sNOT DONE YET. Work through the failures above, top to bottom.%s\n' "$C_R" "$C_0"
    fi
    rule
    return "$VERIFY_RC"
}

#------------------------------------------------------------------------------
# Status / restore
#------------------------------------------------------------------------------
status() {
    [ -f "$STATE_FILE" ] || die "No lab state found. Run '$0 break' first."
    rule
    printf 'Client home  : %s\n' "$CLIENT_HOME"
    ls -ld "$CLIENT_HOME" "${CLIENT_HOME}/.ssh" "${CLIENT_HOME}/.gnupg" 2>&1
    ls -l  "${CLIENT_HOME}/.ssh" 2>&1
    rule
    printf 'Server home  : %s\n' "$SERVER_HOME"
    ls -ld "$SERVER_HOME" "${SERVER_HOME}/.ssh" 2>&1
    ls -l  "${SERVER_HOME}/.ssh" 2>&1
    rule
    printf 'GnuPG secret keys as seen by %s:\n' "$CLIENT_USER"
    as_client "gpg --list-secret-keys" 2>&1
    rule
}

restore() {
    [ -f "$STATE_FILE" ] || warn "No lab state file; removing whatever is left anyway."
    local u
    for u in "$CLIENT_USER" "$SERVER_USER"; do
        if id "$u" >/dev/null 2>&1; then
            pkill -KILL -u "$u" >/dev/null 2>&1
            sleep 1
            userdel -r "$u" >/dev/null 2>&1 || warn "userdel -r $u reported an error; check /home/$u."
        fi
    done
    rm -rf "$LAB_ROOT"
    ok "Lab removed. Nothing outside the two lab accounts was ever modified."
}

#------------------------------------------------------------------------------
# break
#------------------------------------------------------------------------------
do_break() {
    [ -f "$STATE_FILE" ] && die "A lab is already deployed. Run '$0 restore' first."
    preflight
    confirm_disposable
    LAB_TOKEN="$(rand_token)"
    log "Building the golden state..."
    create_users
    build_ssh
    build_gpg
    snapshot
    log "Injecting faults..."
    fault_1_server_modes
    fault_2_known_hosts
    fault_3_ssh_config
    fault_4_private_key_mode
    fault_5_gnupg
    brief
}

need_root
case "${1:-break}" in
    break|make|setup) do_break ;;
    verify|check|grade) verify ;;
    status|show) status ;;
    restore|reset|clean) restore ;;
    *) die "Usage: $0 {break|verify|status|restore}" ;;
esac

#==============================================================================
#
#   S O L U T I O N   --   step by step
#
#   Stop here if you have not tried yet. Reading the answer costs you the only
#   thing this lab is worth: the diagnostic reflex.
#
#------------------------------------------------------------------------------
#   STEP 0 -- Reproduce, verbosely, and read the FIRST error only
#------------------------------------------------------------------------------
#   # su - lpicclient
#   $ ssh -v lpicserver@localhost
#
#   Rule of the trade: ssh fails in a fixed order -- transport and host key
#   first, then authentication, then the session. Whatever the first error is,
#   everything after it is invisible. Fix one, re-run, read the next.
#
#------------------------------------------------------------------------------
#   FAULT 2 -- Host key verification failed  (client: ~/.ssh/known_hosts)
#------------------------------------------------------------------------------
#   Symptom:
#     @@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@@
#     Offending ECDSA key in /home/lpicclient/.ssh/known_hosts:2
#     Host key verification failed.
#
#   Diagnosis -- compare what is stored against what the server really has:
#     $ ssh-keygen -F localhost                       # the stored entry
#     $ ssh-keyscan -t ed25519 localhost | ssh-keygen -lf -
#     # ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub   # ground truth, as root
#   The last two fingerprints must be identical to each other. If they are, the
#   server is genuine and the stale entry in known_hosts is the liar.
#
#   Fix -- remove the bad entry, then re-learn the key and VERIFY it:
#     $ ssh-keygen -R localhost
#     $ ssh-keygen -R 127.0.0.1
#     $ ssh-keyscan -t rsa,ecdsa,ed25519 localhost 127.0.0.1 >> ~/.ssh/known_hosts
#     $ ssh-keygen -F localhost | ssh-keygen -lf -    # compare with ground truth
#   NEVER "solve" this with StrictHostKeyChecking=no. That switch turns off the
#   only defence ssh has against a man in the middle; in production this banner
#   means "prove the server was rebuilt" before you touch anything.
#
#------------------------------------------------------------------------------
#   FAULT 3 -- No key is ever offered  (client: ~/.ssh/config)
#------------------------------------------------------------------------------
#   Symptom:
#     Warning: Identity file /home/lpicclient/.ssh/id_ed25519_backup not accessible:
#              No such file or directory
#     ... Permission denied (publickey).
#   With -v you also see that the client offers nothing:
#     debug1: Authentications that can continue: publickey
#     debug1: No more authentication methods to try.
#
#   Diagnosis -- print the configuration ssh actually computes for this host:
#     $ ssh -G localhost | grep -i -e identityfile -e identitiesonly -e user -e port
#     $ cat ~/.ssh/config
#   'IdentitiesOnly yes' tells ssh to offer ONLY the keys named by IdentityFile.
#   Point it at a file that does not exist and no key is ever presented, no
#   matter what is in ~/.ssh.
#
#   Fix -- point IdentityFile at the key that really exists:
#     $ sed -i 's|id_ed25519_backup|id_ed25519|' ~/.ssh/config
#     $ chmod 600 ~/.ssh/config       # ssh refuses a group/world writable config
#     $ ssh -G localhost | grep -i identityfile
#
#------------------------------------------------------------------------------
#   FAULT 4 -- UNPROTECTED PRIVATE KEY FILE  (client: ~/.ssh/id_ed25519)
#------------------------------------------------------------------------------
#   Symptom:
#     @@@@@ WARNING: UNPROTECTED PRIVATE KEY FILE! @@@@@
#     Permissions 0644 for '/home/lpicclient/.ssh/id_ed25519' are too open.
#     This private key will be ignored.
#
#   Diagnosis:
#     $ ls -l ~/.ssh/id_ed25519
#   A private key readable by group or other is, from ssh's point of view, a key
#   that has already leaked. It refuses to use it rather than pretend otherwise.
#
#   Fix:
#     $ chmod 600 ~/.ssh/id_ed25519
#     $ ls -l ~/.ssh/id_ed25519       # -rw------- lpicclient lpicclient
#   Canonical modes for ~/.ssh: directory 700, private keys 600, everything else
#   (config, known_hosts, authorized_keys, *.pub) 600 or 644 -- never writable
#   by anyone but the owner.
#
#------------------------------------------------------------------------------
#   FAULT 1 -- StrictModes rejects the key  (server: /home/lpicserver)
#------------------------------------------------------------------------------
#   Symptom, client side, and this is the whole difficulty:
#     Permission denied (publickey).
#   even with -vvv. The client did offer the right key; the server threw it
#   away and, by design, will not say why over the wire. The reason is logged
#   on the SERVER:
#     # journalctl -u sshd -n 50 --no-pager      # systemd distributions
#     # tail -n 50 /var/log/auth.log             # Debian/Ubuntu file log
#     # tail -n 50 /var/log/secure               # RHEL/Fedora file log
#     sshd[...]: Authentication refused: bad ownership or modes for directory
#                /home/lpicserver/.ssh
#
#   Diagnosis -- inspect the whole path, not just the file:
#     # ls -ld /home/lpicserver /home/lpicserver/.ssh
#     # ls -l  /home/lpicserver/.ssh/authorized_keys
#     # sshd -T | grep -i -e strictmodes -e authorizedkeysfile
#   With 'StrictModes yes' (the default) sshd refuses authorized_keys if the
#   home directory, ~/.ssh or authorized_keys itself is writable by group or
#   other, or is not owned by that user or root. A world-writable home means
#   any local user could append their own key -- so sshd treats the file as
#   untrustworthy and falls through to the next authentication method.
#
#   Fix -- as root:
#     # chmod 0700 /home/lpicserver
#     # chmod 0700 /home/lpicserver/.ssh
#     # chmod 0600 /home/lpicserver/.ssh/authorized_keys
#     # chown -R lpicserver:lpicserver /home/lpicserver/.ssh
#     # restorecon -RF /home/lpicserver     # SELinux systems only (ssh_home_t)
#
#   Now objective A must hold:
#     # su - lpicclient -c 'ssh -o BatchMode=yes lpicserver@localhost \
#           cat /home/lpicserver/lab/ssh-flag'
#     SSH-OK-xxxxxxxxxxxx
#
#------------------------------------------------------------------------------
#   FAULT 5 -- GnuPG: unsafe homedir and a missing secret keyring
#------------------------------------------------------------------------------
#   Symptom:
#     $ gpg --decrypt ~/lab/secret.txt.gpg
#     gpg: WARNING: unsafe permissions on homedir '/home/lpicclient/.gnupg'
#     gpg: encrypted with 255-bit ECDH key, ID ..., created ...
#     gpg: decryption failed: No secret key
#
#   Diagnosis -- two distinct problems, in this order:
#     $ gpgconf --list-dirs homedir           # where GnuPG really looks
#     $ ls -ld ~/.gnupg                       # drwxrwxrwx -> the warning
#     $ gpg --list-secret-keys                # empty: no private key at all
#     $ gpg --list-keys                       # the PUBLIC key is still there
#     $ gpg --list-packets ~/lab/secret.txt.gpg | head
#         -> "keyid <ID>": which key the file was encrypted TO
#   Since GnuPG 2.1 the private material no longer lives in secring.gpg: it is
#   one file per key under ~/.gnupg/private-keys-v1.d/, named after the keygrip.
#   Lose that directory and the public keyring still looks perfectly healthy
#   while nothing can be decrypted. Find where it went:
#     $ find /home/lpicclient -name 'private-keys-v1.d' -type d
#     /home/lpicclient/keys-backup/private-keys-v1.d
#
#   Fix -- restore the keyring and lock the homedir down:
#     $ gpgconf --kill all                    # drop any cached agent state
#     $ mv ~/keys-backup/private-keys-v1.d ~/.gnupg/
#     $ chmod 700 ~/.gnupg
#     $ chmod 700 ~/.gnupg/private-keys-v1.d
#     $ chmod 600 ~/.gnupg/private-keys-v1.d/*.key
#     $ chown -R lpicclient:lpicclient ~/.gnupg
#     $ gpg --list-secret-keys                # sec ed25519 ... [SC] / ssb [E]
#     $ gpg --decrypt ~/lab/secret.txt.gpg
#     GPG-OK-xxxxxxxxxxxx
#   GnuPG insists on 0700 for the homedir for the same reason ssh insists on
#   0600 for a private key: a secret every account on the box can read is not
#   a secret. And note which subkey did the work -- the [E] encryption subkey,
#   not the [SC] primary; that split is why gpg --list-secret-keys is the right
#   command here and gpg --list-keys is not.
#
#------------------------------------------------------------------------------
#   STEP 6 -- Grade, then reset
#------------------------------------------------------------------------------
#     # ./110.3-break-and-fix.sh verify        # all ten checks must be PASS
#     # ./110.3-break-and-fix.sh restore       # delete both lab accounts
#
#------------------------------------------------------------------------------
#   WHAT TO CARRY OUT OF THIS LAB (110.3 exam-relevant)
#------------------------------------------------------------------------------
#   * "Permission denied (publickey)" is a server verdict with a client-side
#     display. When the client's -vvv output shows the key being offered, stop
#     reading the client and go read the sshd log.
#   * Permissions are not cosmetics in OpenSSH and GnuPG: 0700 on ~/.ssh and
#     ~/.gnupg, 0600 on private keys and authorized_keys. Both tools fail
#     closed, and both tell you exactly which path offended them.
#   * IdentitiesOnly / IdentityFile in ~/.ssh/config silently override what is
#     present in ~/.ssh. 'ssh -G <host>' prints the effective configuration and
#     settles the argument in one command.
#   * known_hosts is the trust anchor of the whole protocol. The correct
#     response to a changed host key is to verify the fingerprint out of band
#     (ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub on the console), never to
#     disable the check.
#   * GnuPG >= 2.1 stores secrets in ~/.gnupg/private-keys-v1.d/. Backing up
#     ~/.gnupg without that directory backs up nothing that matters. Two
#     supported ways to move a key properly:
#       gpg --export-secret-keys --armor <KEYID> > private.asc   (then gpg --import)
#       gpg --export-secret-subkeys ...                          (leave the primary offline)
#   * Also on the 110.3 objective, and worth practising next in this same lab:
#     ssh-agent / ssh-add for passphrase-protected keys, ssh -L and ssh -R port
#     forwarding, ~/.ssh/authorized_keys option fields (command=, from=,
#     no-port-forwarding), gpg --gen-revoke (make the revocation certificate the
#     day you make the key), and gpg --verify for detached signatures.
#==============================================================================