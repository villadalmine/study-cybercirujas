#!/usr/bin/env bash
# ==============================================================================
# LPI-702: BSD Specialist (Exam 702-100, Version 1.0)
# Topic 713.1: Manage User Accounts and Groups (Exam Weight: 5)
# Reference: https://www.lpi.org/our-certifications/bsd-specialist-overview/
#
# Production Break & Fix Lab Script
# Target System: FreeBSD / BSD Systems
# ==============================================================================
# ARCHITECTURAL BACKGROUND & INTERNAL MECHANICS:
# FreeBSD user account management differs significantly from standard Linux:
# 1. Master Passwd & DB Indexing:
#    - /etc/master.passwd: Contains full user entries including password hashes,
#      login class, password change time, and account expiration.
#    - /etc/passwd: A sanitized, backwards-compatible version (no password hashes).
#    - /etc/pwd.db: Insecure Hashed DB (BDB format) readable by all users (no hashes).
#    - /etc/spwd.db: Secure Hashed DB (BDB format) restricted to root (0600) (contains hashes).
#    * CRITICAL MECHANIC: BSD libc user lookup functions (getpwnam, getpwuid) query
#      /etc/pwd.db and /etc/spwd.db via db(3), NOT /etc/master.passwd directly!
#      If /etc/master.passwd is manually edited without running `pwd_mkdb`, the live OS
#      state desynchronizes from the text file.
# 2. Management Utilities:
#    - `pw`: System account management tool (pw useradd, pw usermod, pw groupadd, etc.).
#    - `vipw`: Edits /etc/master.passwd safely with file locking and automatically invokes `pwd_mkdb`.
#    - `pwd_mkdb`: Rebuilds /etc/pwd.db, /etc/spwd.db, and /etc/passwd from /etc/master.passwd.
# 3. Shell Verification:
#    - Valid login shells must be listed in /etc/shells. If a user's shell is missing,
#      services like `ftpd`, `su`, or `chsh` will reject logins/operations.
# ==============================================================================

set -euo pipefail

RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LOG_PREFIX="[LPI-702 713.1 LAB]"

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}${LOG_PREFIX} ERROR: This lab script must be run as root on a disposable FreeBSD system.${NC}" >&2
        exit 1
    fi
}

check_bsd() {
    if [ "$(uname -s)" != "FreeBSD" ] && [ "$(uname -s)" != "OpenBSD" ] && [ "$(uname -s)" != "NetBSD" ]; then
        echo -e "${YELLOW}${LOG_PREFIX} WARNING: This lab targets BSD systems (FreeBSD pw/pwd_mkdb architecture). Current OS: $(uname -s)${NC}"
    fi
}

break_environment() {
    echo -e "${BLUE}${LOG_PREFIX} Initializing controlled break scenario for Topic 713.1...${NC}"

    # 1. Ensure target group and user exist cleanly
    if pw group show secops >/dev/null 2>&1; then
        pw groupdel secops -f || true
    fi
    if pw user show sre_user >/dev/null 2>&1; then
        pw userdel sre_user -r -f || true
    fi

    # Create base user and group using official FreeBSD utility `pw`
    pw groupadd secops -g 5001
    pw useradd sre_user -u 5001 -g secops -c "SRE Production Engineer" -d /home/sre_user -m -s /usr/local/bin/zsh -h 0 <<EOF
InitialLabPass123!
EOF

    echo -e "${GREEN}${LOG_PREFIX} Base user 'sre_user' (UID 5001) and group 'secops' (GID 5001) created successfully.${NC}"

    # --- INJECT BREAKAGES ---
    echo -e "${YELLOW}${LOG_PREFIX} Injecting production misconfigurations...${NC}"

    # Breakage 1: Remove /usr/local/bin/zsh from /etc/shells (or omit it)
    if [ -f /etc/shells ]; then
        sed -i '' '/\/usr\/local\/bin\/zsh/d' /etc/shells 2>/dev/null || sed -i '/\/usr\/local\/bin\/zsh/d' /etc/shells
    fi

    # Breakage 2: Manually manipulate /etc/master.passwd directly (Bypassing vipw and pwd_mkdb)
    # Change home directory path to invalid location and set shell to zsh in text file
    sed -i '' 's|/home/sre_user|/nonexistent_dir|g' /etc/master.passwd 2>/dev/null || sed -i 's|/home/sre_user|/nonexistent_dir|g' /etc/master.passwd

    # Breakage 3: Desynchronize /etc/spwd.db and /etc/pwd.db by intentionally altering /etc/master.passwd hash
    # Now /etc/master.passwd has different data than /etc/spwd.db indexed database!

    # Breakage 4: Corrupt permissions of /etc/spwd.db (Should be 0600 owned by root:wheel)
    chmod 0644 /etc/spwd.db

    # Breakage 5: Secondary group inconsistency
    # Add user to wheel in /etc/group directly without using `pw groupmod` or `pw usermod`
    echo "wheel:*:0:root,sre_user" >> /etc/group || true

    echo -e "${RED}${LOG_PREFIX} System states corrupted! Lab environment is now broken.${NC}"
}

print_symptoms() {
    cat << EOF

===============================================================================
               LPI-702 TOPIC 713.1 BREAK & FIX CHALLENGE
===============================================================================
STATUS: BREAK APPLIED

SYMPTOMS REPORTED BY ALERTING SYSTEM & USER:
1. User 'sre_user' cannot switch shell or log in via SSH/su (`su - sre_user` fails).
2. Password changes or account updates using `pw usermod` reveal discrepancies
   between getpwnam() system calls, `/etc/master.passwd`, and `/etc/spwd.db`.
3. Security Audit (e.g., `freebsd-update` or `security audit`) flags a critical
   file permission issue on system password databases.
4. User 'sre_user' reports home directory missing error upon execution attempt.
5. Shell assignment (/usr/local/bin/zsh) is rejected by authentication PAM stack.

YOUR OBJECTIVES:
1. Identify why system API calls read stale/inconsistent data compared to text configuration files.
2. Fix all permissions on system password databases to enforce security compliance.
3. Validate and restore valid login shell definitions in accordance with BSD standards.
4. Correctly align primary and supplementary group memberships using `pw` utilities.
5. Re-synchronize indexed databases (/etc/pwd.db, /etc/spwd.db, /etc/passwd) from /etc/master.passwd.

COMMANDS TO USE FOR DIAGNOSIS:
- `pw user show sre_user`
- `getent passwd sre_user` or `id sre_user`
- `ls -l /etc/pwd.db /etc/spwd.db /etc/master.passwd`
- `cat /etc/shells`
- `vipw` / `pwd_mkdb`

===============================================================================
EOF
}

main() {
    check_root
    check_bsd
    break_environment
    print_symptoms
}

main "$@"

# ==============================================================================
#                       STEP-BY-STEP SOLUTION (SRE GUIDE)
# ==============================================================================
# Execute the following steps to diagnose and repair the broken environment:
#
# STEP 1: DIAGNOSE PASSSWD DATABASE DESYNCHRONIZATION & PERMISSIONS
# ------------------------------------------------------------------------------
# Inspect file permissions of password databases:
#   # ls -l /etc/master.passwd /etc/passwd /etc/pwd.db /etc/spwd.db
# Notice /etc/spwd.db has 0644 permissions (Security Risk! Hashes exposed to unprivileged users).
#
# Check the difference between text file and indexed DB:
#   # grep sre_user /etc/master.passwd
#   Output shows: sre_user:...:/nonexistent_dir:/usr/local/bin/zsh
#   # getent passwd sre_user
#   Output shows: sre_user:...:/home/sre_user:/usr/local/bin/zsh
#
# Root Cause: Direct manual edit to /etc/master.passwd without `pwd_mkdb` caused DB desync.
#
# STEP 2: FIX FILE PERMISSIONS ON SECURE DATABASE
# ------------------------------------------------------------------------------
# Enforce 0600 on /etc/spwd.db and 0600/0644 on master.passwd:
#   # chmod 0600 /etc/spwd.db
#   # chmod 0600 /etc/master.passwd
#   # chmod 0644 /etc/pwd.db /etc/passwd
#
# STEP 3: REPAIR USER HOME DIRECTORY AND SHELL VALIDATION
# ------------------------------------------------------------------------------
# Ensure /usr/local/bin/zsh is a valid shell listed in /etc/shells:
#   # grep "/usr/local/bin/zsh" /etc/shells || echo "/usr/local/bin/zsh" >> /etc/shells
#
# Verify home directory path exists and set correct ownership:
#   # mkdir -p /home/sre_user
#   # chown -R sre_user:secops /home/sre_user
#   # chmod 0700 /home/sre_user
#
# STEP 4: USE VIPW OR PW UTILITY TO CORRECT ACCOUNT PROPERTIES & REBUILD DB
# ------------------------------------------------------------------------------
# Option A: Fix via `pw` utility (Recommended for SRE automation)
#   # pw usermod sre_user -d /home/sre_user -s /usr/local/bin/zsh -G wheel
#
# Option B: Fix manually via `vipw` and rebuild databases using `pwd_mkdb`
#   # vipw
#   (Correct home directory line to: /home/sre_user)
#   Save and exit. `vipw` automatically triggers `pwd_mkdb -p /etc/master.passwd`.
#
# If manual alignment of DB is needed directly:
#   # pwd_mkdb -p /etc/master.passwd
#
# STEP 5: VERIFICATION COMMANDS
# ------------------------------------------------------------------------------
# 1. Verify DB sync vs getpwnam API:
#    # getent passwd sre_user
#    Expected Output: sre_user:*:5001:5001:SRE Production Engineer:/home/sre_user:/usr/local/bin/zsh
#
# 2. Verify group membership:
#    # id sre_user
#    Expected Output: uid=5001(sre_user) gid=5001(secops) groups=5001(secops),0(wheel)
#
# 3. Test shell switching:
#    # su - sre_user -c "id"
#    Expected Output: uid=5001(sre_user) gid=5001(secops) groups=5001(secops),0(wheel)
#
# 4. Confirm security permissions:
#    # stat -f "%A %N" /etc/spwd.db /etc/master.passwd
#    Expected Output: 600 /etc/spwd.db
#                     600 /etc/master.passwd
# ==============================================================================