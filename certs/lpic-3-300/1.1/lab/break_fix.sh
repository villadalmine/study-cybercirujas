#!/usr/bin/env bash
# ==============================================================================
# LPIC-3 Exam 300-300 (v3.0) - Topic 1.1: Samba Basics (Weight: 20)
# LAB EXERCISE: Break & Fix Scenario - Production Samba Configuration Debugging
# Target OS: Debian/Ubuntu or RHEL/Rocky Linux (Disposable Lab VM)
# Official Reference: https://www.lpi.org/our-certifications/lpic-3-300-overview/
# ==============================================================================
#
# ARCHITECTURAL BACKGROUND & MECHANICS:
# ------------------------------------
# Samba consists of core daemons:
#   - smbd: Handles File/Print services, SMB/CIFS protocol negotiations, user authentication, and locking.
#   - nmbd: Provides NetBIOS Name Service (NBNS) resolution and browsing functionality over IPv4.
#   - winbindd: Handles domain membership, ID mapping (UID/GID <-> SID), and NSS/PAM integration.
#
# Configuration Mechanics & Passdb Backend:
#   Samba relies on `/etc/samba/smb.conf` parsed by `testparm`.
#   User authentication in modern standalone/member servers relies on `passdb backend = tdbsam`
#   (Trivial Database format stored in `/var/lib/samba/private/passdb.tdb`).
#   POSIX directory permissions on Linux interact with Samba share definitions (`valid users`,
#   `create mask`, `directory mask`, `read only`). Both layers (POSIX + Samba ACLs) must allow access.
#
# SCENARIO OVERVIEW:
# ------------------
# A junior administrator attempted to set up a secure production Samba share named `[finance]`
# located at `/srv/samba/finance` for the user `finuser`.
#
# Following their changes:
# 1. The Samba daemon fails to load or logs errors upon startup.
# 2. `testparm` identifies syntax errors and deprecated parameters in `smb.conf`.
# 3. Connection attempts via `smbclient` return `NT_STATUS_ACCESS_DENIED` or `NT_STATUS_LOGON_FAILURE`.
# 4. Write operations fail even if authentication succeeds due to file permission and share mask mismatches.
#
# OBJECTIVES FOR THE STUDENT:
# ---------------------------
# 1. Run `testparm -s` to diagnose syntax errors, deprecated parameters, and structural flaws in `/etc/samba/smb.conf`.
# 2. Fix the `[global]` directives (security mode, passdb backend, server max protocol).
# 3. Fix the `[finance]` share configuration directives (`valid users`, `read only`, masks).
# 4. Create and enable the `finuser` Samba user in the `tdbsam` backend via `smbpasswd` or `pdbedit`.
# 5. Fix POSIX filesystem permissions on `/srv/samba/finance`.
# 6. Verify client access with `smbclient` and inspect active connections using `smbstatus`.
#
# ==============================================================================

set -euo pipefail

# Ensure execution as root
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This lab setup script must be executed with root privileges." >&2
   exit 1
fi

echo "======================================================================"
echo "[+] LPIC-3 300-300 Topic 1.1 Lab Setup: Deploying Misconfigured Samba"
echo "======================================================================"

# 1. Detect Package Manager & Install Dependencies
if command -v apt-get &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq samba samba-common smbclient >/dev/null
    SAMBA_SERVICE="smbd"
    SMB_CONF_PATH="/etc/samba/smb.conf"
elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    PKG_MGR=$(command -v dnf || command -v yum)
    $PKG_MGR install -y -q samba samba-client >/dev/null
    SAMBA_SERVICE="smb"
    SMB_CONF_PATH="/etc/samba/smb.conf"
else
    echo "[ERROR] Unsupported Linux distribution. Requires Debian/Ubuntu or RHEL/CentOS/Rocky." >&2
    exit 1
fi

# 2. Setup System User and Share Directory Structure
USERNAME="finuser"
SHARE_DIR="/srv/samba/finance"

if ! id "$USERNAME" &>/dev/null; then
    useradd -m -s /usr/sbin/nologin "$USERNAME"
fi

# Set system user password
echo "$USERNAME:ComplexLabPass123!" | chpasswd

# Prepare filesystem directory
mkdir -p "$SHARE_DIR"

# 3. Inject Misconfigurations (The "Break" Phase)

# Misconfiguration A: Strict POSIX Permissions (Restricts daemon/user access at OS level)
chown root:root "$SHARE_DIR"
chmod 0700 "$SHARE_DIR"

# Misconfiguration B: Broken /etc/samba/smb.conf
cat <<'EOF' > "$SMB_CONF_PATH"
[global]
   workgroup = WORKGROUP
   server string = LPIC3 Production Samba Lab
   netbios name = SAMBALAB
   
   # ERR 1: Security = share is deprecated and invalid in modern Samba
   security = share
   
   # ERR 2: Invalid passdb backend target directory
   passdb backend = tdbsam:/var/lib/samba/nonexistent_path/passdb.tdb
   
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file

   # ERR 3: Invalid protocol string breaks daemon parsing
   server max protocol = SMB3_INVALID_TOKEN

[finance]
   comment = Financial Department Sensitive Data Share
   path = /srv/samba/finance
   
   # ERR 4: Contradictory access flags and user restrictions
   read only = yes
   writable = yes
   valid users = invalid_user_account
   invalid users = finuser
   
   # ERR 5: Mask parameters revoke all read/write permissions on created files
   create mask = 0000
   directory mask = 0000
   browseable = yes
EOF

# Misconfiguration C: Purge user from Samba TDB backend
(pdbedit -x -u "$USERNAME" &>/dev/null) || true

# 4. Restart Samba Service to Apply Broken State
systemctl restart "$SAMBA_SERVICE" &>/dev/null || true

echo ""
echo "======================================================================"
echo "[!] LAB BREAK COMPLETE: Samba has been misconfigured."
echo "======================================================================"
echo ""
echo "STUDENT TROUBLESHOOTING PROMPT:"
echo "-------------------------------"
echo "Target User:      $USERNAME"
echo "Target Password:  ComplexLabPass123!"
echo "Target Share:     //localhost/finance"
echo "Target Directory: $SHARE_DIR"
echo ""
echo "SYMPTOMS TO OBSERVE:"
echo "1. Run: testparm -s"
echo "   Observe configuration parsing errors, invalid directives, and warnings."
echo "2. Run: smbclient //127.0.0.1/finance -U finuser"
echo "   Observe connection failure: NT_STATUS_LOGON_FAILURE or NT_STATUS_ACCESS_DENIED."
echo "3. Run: systemctl status $SAMBA_SERVICE"
echo "   Observe service errors or degraded states."
echo ""
echo "YOUR TASK:"
echo "- Correct /etc/samba/smb.conf syntax and parameters."
echo "- Provision and enable '$USERNAME' in the Samba passdb backend."
echo "- Fix POSIX ownership and permissions on $SHARE_DIR."
echo "- Successfully execute:"
echo "  smbclient //localhost/finance -U finuser%ComplexLabPass123! -c 'put /etc/hostname test.txt; ls'"
echo "- Verify active connection status using 'smbstatus'."
echo ""
echo "Review the step-by-step solution guide commented at the bottom of this script."
echo "======================================================================"

exit 0


# ==============================================================================
# LPIC-3 (300-300) TOPIC 1.1 - STEP-BY-STEP SOLUTION GUIDE
# ==============================================================================
#
# STEP 1: Diagnostic Phase - Audit smb.conf with testparm
# ---------------------------------------------------------
# Run testparm to parse `/etc/samba/smb.conf`:
#   # testparm -s /etc/samba/smb.conf
#
# Expected Diagnostic Output:
#   Load smb config files from /etc/samba/smb.conf
#   Error: Unknown option 'server max protocol = SMB3_INVALID_TOKEN'
#   ERROR: 'security = share' is not supported in this version of Samba.
#   ...
#
# STEP 2: Remediation - Write Production-Grade smb.conf
# -----------------------------------------------------
# Replace `/etc/samba/smb.conf` with a valid configuration:
#
# cat <<'EOF' > /etc/samba/smb.conf
# [global]
#    workgroup = WORKGROUP
#    server string = LPIC3 Production Samba Lab
#    netbios name = SAMBALAB
#    security = user
#    passdb backend = tdbsam
#    log file = /var/log/samba/log.%m
#    max log size = 1000
#    logging = file
#    server max protocol = SMB3
#
# [finance]
#    comment = Financial Department Data Share
#    path = /srv/samba/finance
#    read only = no
#    browseable = yes
#    valid users = finuser
#    create mask = 0664
#    directory mask = 0775
# EOF
#
# Verify syntax with testparm:
#   # testparm -s
# Expected output: "Loaded services file OK."
#
# STEP 3: User Authentication & Passdb Management (tdbsam)
# -------------------------------------------------------
# Add system user 'finuser' to Samba's TDB password database:
#   # smbpasswd -a finuser
#   (Enter: ComplexLabPass123!)
#
# Verify account entry using pdbedit:
#   # pdbedit -L -v finuser
# Expected output snippet:
#   Unix username:        finuser
#   NT username:          
#   Account Flags:        [U          ]
#   User SID:             S-1-5-21-...
#
# Ensure user is enabled (if disabled):
#   # smbpasswd -e finuser
#
# STEP 4: Linux POSIX Permissions & SELinux Alignment
# ---------------------------------------------------
# Grant proper POSIX ownership and read/write permissions to the share path:
#   # chown -R finuser:finuser /srv/samba/finance
#   # chmod 0775 /srv/samba/finance
#
# If SELinux is active (RHEL/Rocky/Fedora):
#   # chcon -t samba_share_t /srv/samba/finance
#   # semanage fcontext -a -t samba_share_t "/srv/samba/finance(/.*)?"
#   # restorecon -R -v /srv/samba/finance
#
# STEP 5: Service Restart
# ----------------------
# Restart Samba services to load new passdb and smb.conf:
# On Debian/Ubuntu:
#   # systemctl restart smbd nmbd
# On RHEL/Rocky:
#   # systemctl restart smb nmb
#
# STEP 6: Empirical Verification via CLI
# --------------------------------------
# Test non-interactive file upload and listing via smbclient:
#   # smbclient //localhost/finance -U finuser%ComplexLabPass123! -c "put /etc/hostname test.txt; ls"
#
# Expected Output:
#   putting file /etc/hostname as \test.txt (0.1 kb/s) (average 0.1 kb/s)
#     .                                   D        0  Thu Aug  6 12:41:00 2026
#     ..                                  D        0  Thu Aug  6 12:41:00 2026
#     test.txt                            A       12  Thu Aug  6 12:41:00 2026
#
# Inspect active Samba server locks and client connection protocol via smbstatus:
#   # smbstatus
#
# Expected Output:
#   Samba version 4.x.x
#   PID     Username     Group        Machine               Protocol Version                  Encryption           Signing              
#   --------------------------------------------------------------------------------------------------------------------------------------
#   4582    finuser      finuser      127.0.0.1 (ipv4:127.0.0.1:42104) SMB3_11                -                    -                    
#
#   Service      pid     Machine       Connected at                     Encryption   Signing              
#   --------------------------------------------------------------------------------------------------
#   finance      4582    127.0.0.1     Thu Aug  6 12:41:00 2026 EDT     -            -                    
#
#   Locked files:
#   Pid          User(s)           DenyMode   Access        R/W        Oplock           SharePath                        Name
#   ------------------------------------------------------------------------------------------------------------------------
#   4582         finuser           DENY_NONE  0x100081      RDONLY     NONE             /srv/samba/finance               .
# ==============================================================================