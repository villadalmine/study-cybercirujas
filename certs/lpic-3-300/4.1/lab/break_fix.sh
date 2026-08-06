#!/bin/bash
# ==============================================================================
# LPIC-3 Exam 300-300 (v3.0) - Topic 304.1: Samba Client Configuration
# Break & Fix Interactive Lab Environment
# ==============================================================================
# Target Exam Topic: Samba Client Configuration (Weight: 20)
# Reference: https://www.lpi.org/our-certifications/lpic-3-300-overview/
# WARNING: Execute this script ONLY within a disposable, dedicated lab VM.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Pre-flight Check: Root Elevation Verification
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
   echo "[ERROR] This break & fix environment script must be executed as root." >&2
   exit 1
fi

echo "========================================================================"
echo " LPIC-3 300-300 | Topic 304.1: Samba Client Configuration Break & Fix"
echo "========================================================================"
echo ""
echo "SCENARIO OVERVIEW:"
echo "An enterprise Linux node cannot negotiate SMB file sharing connections with"
echo "internal Samba/CIFS file servers. Automated backups and user mounts via"
echo "/etc/fstab and CLI tools (smbclient, mount.cifs) fail with security and"
echo "protocol mismatch errors."
echo ""
echo "SYMPTOMS OBSERVED:"
echo "  1. 'smbclient -L //localhost/finance' returns:"
echo "     'protocol negotiation failed: NT_STATUS_REVISION_MISMATCH' or"
echo "     'NT_STATUS_INVALID_PARAMETER'."
echo "  2. 'mount -a' fails to mount '/mnt/finance' returning:"
echo "     'CIFS: VFS: cifs_mount failed w/return code = -22' in dmesg."
echo "  3. Automated security audit flags insecure 0666 permissions on SMB credentials."
echo ""
echo "LAB OBJECTIVES:"
echo "  - Correct global Samba client protocol limits (client min/max protocol) and"
echo "    name resolution parameters inside /etc/samba/smb.conf."
echo "  - Fix mount options (vers=, sec=) in /etc/fstab for modern kernel CIFS."
echo "  - Reformat and secure the CIFS credentials file (/etc/samba/credentials/finance.creds)."
echo "  - Validate full client connectivity using smbclient and mount.cifs."
echo ""
echo "Applying controlled environment breakage..."
echo "------------------------------------------------------------------------"

# ------------------------------------------------------------------------------
# Package Installation & Target Directory Provisioning
# ------------------------------------------------------------------------------
if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq samba smbclient cifs-utils &>/dev/null || true
elif command -v dnf &>/dev/null; then
    dnf install -y -q samba samba-client cifs-utils &>/dev/null || true
fi

mkdir -p /etc/samba
mkdir -p /mnt/finance
mkdir -p /srv/samba/finance

# Backup smb.conf if original exists
if [[ -f /etc/samba/smb.conf && ! -f /etc/samba/smb.conf.bak_lpic3 ]]; then
    cp /etc/samba/smb.conf /etc/samba/smb.conf.bak_lpic3
fi

# ------------------------------------------------------------------------------
# INJECT BREAKAGE 1 & 2: Misconfigured /etc/samba/smb.conf (Global Client Directives)
# ------------------------------------------------------------------------------
cat <<'EOF' > /etc/samba/smb.conf
[global]
   workgroup = CORP
   security = user
   
   # BROKEN CLIENT CONFIGURATION (LPIC-3 304.1)
   # Forces dialect negotiation above server capability and breaks NTLMv2/resolution
   client min protocol = SMB3_11
   client max protocol = SMB3_11
   client NTLMv2 auth = no
   name resolve order = lmhosts

[finance]
   path = /srv/samba/finance
   read only = no
   guest ok = no
   valid users = smbuser
EOF

# Ensure test local user exists for Samba testing daemon
if ! id -u smbuser &>/dev/null; then
    useradd -M -s /sbin/nologin smbuser || true
fi
echo -e "SecretPass123!\nSecretPass123!" | smbpasswd -a -s smbuser &>/dev/null || true
chown -R smbuser:smbuser /srv/samba/finance

# Restart Samba daemon if present
systemctl restart smbd &>/dev/null || service smbd restart &>/dev/null || true

# ------------------------------------------------------------------------------
# INJECT BREAKAGE 3: Insecure & Syntax-Flawed CIFS Credentials File
# ------------------------------------------------------------------------------
mkdir -p /etc/samba/credentials
cat <<'EOF' > /etc/samba/credentials/finance.creds
user=smbuser
pass=SecretPass123!
domain=CORP
EOF
# Insecure permissions trigger compliance failure
chmod 0666 /etc/samba/credentials/finance.creds

# ------------------------------------------------------------------------------
# INJECT BREAKAGE 4: Obsolete /etc/fstab Mount Parameters
# ------------------------------------------------------------------------------
sed -i '\#/mnt/finance#d' /etc/fstab
echo "//localhost/finance /mnt/finance cifs credentials=/etc/samba/credentials/finance.creds,vers=1.0,sec=ntlm,uid=1000,gid=1000 0 0" >> /etc/fstab

echo ""
echo "[+] System misconfiguration injected successfully!"
echo "========================================================================"
echo "TROUBLESHOOTING INSTRUCTIONS FOR STUDENT:"
echo "1. Run: smbclient -L //localhost -U smbuser%SecretPass123!"
echo "   Observe negotiation failure caused by restrictive 'client min protocol'."
echo "2. Run: mount /mnt/finance"
echo "   Observe kernel error (inspect via 'dmesg | tail -n 20')."
echo "3. Inspect '/etc/samba/credentials/finance.creds' syntax and permissions."
echo "4. Update '/etc/samba/smb.conf', credentials file, and '/etc/fstab' to fix."
echo "========================================================================"
echo ""

exit 0

# ==============================================================================
# STEP-BY-STEP SOLUTION (UNCOMMENT AND EXECUTE TO REPAIR LAB)
# ==============================================================================
#
# STEP 1: Diagnose smbclient Protocol and Name Resolution Failures
#   Run debug lookup:
#     smbclient -L //localhost -U smbuser%SecretPass123! -d 3
#   Root Cause: 'client min protocol = SMB3_11' prevents standard SMB2/SMB3 dial-up.
#   'name resolve order = lmhosts' fails host resolution if lmhosts is empty.
#
# STEP 2: Repair /etc/samba/smb.conf Global Client Parameters
#   Edit /etc/samba/smb.conf under the [global] section:
#     [global]
#        workgroup = CORP
#        security = user
#        client min protocol = SMB2_10
#        client max protocol = SMB3
#        client NTLMv2 auth = yes
#        name resolve order = host bcast lmhosts
#
# STEP 3: Fix Syntax and File Permissions for CIFS Credentials
#   Correct keys in /etc/samba/credentials/finance.creds (use username= and password=):
#     username=smbuser
#     password=SecretPass123!
#     domain=CORP
#
#   Enforce strict root-only security permissions:
#     chown root:root /etc/samba/credentials/finance.creds
#     chmod 0600 /etc/samba/credentials/finance.creds
#
# STEP 4: Update /etc/fstab with Modern Dialects and Security Flags
#   Update /etc/fstab line to use vers=3.0 (or vers=2.1) and sec=ntlmssp:
#     //localhost/finance /mnt/finance cifs credentials=/etc/samba/credentials/finance.creds,vers=3.0,sec=ntlmssp,uid=1000,gid=1000 0 0
#
# STEP 5: Verification of Resolution
#   smbclient -L //localhost -U smbuser%SecretPass123!
#   mount -a
#   df -hT /mnt/finance
#   umount /mnt/finance
#
# ==============================================================================