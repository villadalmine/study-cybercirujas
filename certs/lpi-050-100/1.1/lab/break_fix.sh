#!/usr/bin/env bash
# ==============================================================================
# LPI 050-100: Open Source Essentials
# Topic 1.1: Software Components (Weight: 5)
# Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/
#
# Lab Title: Break & Fix - Shared Library & Dynamic Linker Component Failure
# Role: Senior SRE Instructor & Principal Platform Architect
# ==============================================================================

set -euo pipefail

# Colors for terminal formatting
RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LAB_DIR="/opt/lpi_lab_1_1"
BIN_DIR="${LAB_DIR}/bin"
LIB_DIR="${LAB_DIR}/lib"
SRC_DIR="${LAB_DIR}/src"
APP_BIN="${BIN_DIR}/sre_component_app"
CONF_FILE="/etc/ld.so.conf.d/lpi_sre_component.conf"

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}[ERROR] This script must be executed as root (or via sudo) to configure environment components.${NC}" >&2
        exit 1
    fi
}

check_dependencies() {
    local deps=("gcc" "make" "ldd" "ldconfig")
    local missing=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}[INFO] Installing missing build/system tools: ${missing[*]}...${NC}"
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq build-essential libc6-dev
        elif command -v dnf &>/dev/null; then
            dnf install -y -quiet gcc make glibc-devel
        elif command -v yum &>/dev/null; then
            yum install -y -quiet gcc make glibc-devel
        else
            echo -e "${RED}[ERROR] Package manager not supported. Please install: ${missing[*]}${NC}" >&2
            exit 1
        fi
    fi
}

setup_environment() {
    echo -e "${BLUE}[STEP 1/3] Setting up workspace directory structure...${NC}"
    mkdir -p "${BIN_DIR}" "${LIB_DIR}" "${SRC_DIR}"

    # Create C source for shared library component
    cat << 'EOF' > "${SRC_DIR}/libcomponent.c"
#include <stdio.h>

void execute_software_component(void) {
    printf("\n========================================================\n");
    printf("  [SUCCESS] System Architecture Component Chain Verified:\n");
    printf("  Hardware -> Linux Kernel -> System Call Interface\n");
    printf("  -> User Space Shared Library (libcomponent.so)\n");
    printf("  -> Application Binary Executable (sre_component_app)\n");
    printf("========================================================\n\n");
}
EOF

    # Create C source for application binary
    cat << 'EOF' > "${SRC_DIR}/main.c"
#include <stdio.h>

extern void execute_software_component(void);

int main(void) {
    printf("[INIT] Launching SRE Software Component Stack...\n");
    execute_software_component();
    return 0;
}
EOF

    # Compile shared library and binary executable
    echo -e "${BLUE}[STEP 2/3] Compiling software components...${NC}"
    gcc -shared -fPIC -o "${LIB_DIR}/libcomponent.so" "${SRC_DIR}/libcomponent.c"
    gcc -o "${APP_BIN}" "${SRC_DIR}/main.c" -L"${LIB_DIR}" -lcomponent
    chmod 755 "${APP_BIN}" "${LIB_DIR}/libcomponent.so"
}

inject_failure() {
    echo -e "${BLUE}[STEP 3/3] Injecting production fault into software component lookup path...${NC}"
    
    # Ensure system dynamic loader configuration does not know about custom LIB_DIR
    rm -f "${CONF_FILE}"
    
    # Refresh cache to commit broken configuration
    ldconfig
}

print_student_briefing() {
    echo -e "\n${RED}======================================================================${NC}"
    echo -e "${RED}         BREAK & FIX LAB: TOPIC 1.1 - SOFTWARE COMPONENTS            ${NC}"
    echo -e "${RED}======================================================================${NC}\n"
    echo -e "Official Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/\n"
    echo -e "${YELLOW}SCENARIO DESCRIPTION:${NC}"
    echo -e "An internal deployment updated a key application component stack under '${LAB_DIR}'."
    echo -e "When attempting to run the binary executable, the system throws a runtime error"
    echo -e "indicating that a required software library component cannot be loaded into user space.\n"
    echo -e "${YELLOW}SYMPTOMS:${NC}"
    echo -e "Executing '${APP_BIN}' fails immediately at the dynamic linking phase.\n"
    echo -e "${YELLOW}STUDENT OBJECTIVES:${NC}"
    echo -e "1. Execute '${APP_BIN}' and observe the exact runtime library error."
    echo -e "2. Use binary investigation tools (e.g., 'ldd') to inspect the shared library dependencies."
    echo -e "3. Locate the missing shared object ('libcomponent.so') on the filesystem."
    echo -e "4. Configure the system's dynamic linker cache permanently using '/etc/ld.so.conf.d/'"
    echo -e "   and update the runtime bindings cache using 'ldconfig'."
    echo -e "5. Verify that '${APP_BIN}' executes successfully and output indicates all components loaded.\n"
    echo -e "${GREEN}To begin debugging, execute:${NC}"
    echo -e "  ${APP_BIN}\n"
}

main() {
    check_root
    check_dependencies
    setup_environment
    inject_failure
    print_student_briefing
}

main "$@"

# ==============================================================================
#                           STUDENT SOLUTION (SPOILERS)
# ==============================================================================
#
# DIAGNOSIS STEP-BY-STEP:
#
# Step 1: Run the broken application binary to inspect error output.
#   /opt/lpi_lab_1_1/bin/sre_component_app
#   Expected Output:
#     /opt/lpi_lab_1_1/bin/sre_component_app: error while loading shared libraries:
#     libcomponent.so: cannot open shared object file: No such file or directory
#
# Step 2: Use 'ldd' to inspect dynamic library dependencies of the ELF executable.
#   ldd /opt/lpi_lab_1_1/bin/sre_component_app
#   Expected Output:
#     linux-vdso.so.1 (0x00007ffc...)
#     libcomponent.so => not found
#     libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f...)
#     /lib64/ld-linux-x86-64.so.2 (0x00007f...)
#
# Step 3: Locate the shared library binary component on the filesystem.
#   find /opt -name "libcomponent.so" 2>/dev/null
#   Found Path: /opt/lpi_lab_1_1/lib/libcomponent.so
#
# Step 4: Fix the dynamic library resolution path permanently for production.
#   Option A (Permanent & Production Standard):
#     echo "/opt/lpi_lab_1_1/lib" > /etc/ld.so.conf.d/lpi_sre_component.conf
#     ldconfig
#
#   Option B (Temporary Session Fix for Testing):
#     export LD_LIBRARY_PATH="/opt/lpi_lab_1_1/lib:${LD_LIBRARY_PATH:-}"
#
# Step 5: Verify the fix with ldd and execution.
#   ldd /opt/lpi_lab_1_1/bin/sre_component_app
#   /opt/lpi_lab_1_1/bin/sre_component_app
#
# CLEANUP (To reset the VM after completing the lab):
#   rm -rf /opt/lpi_lab_1_1 /etc/ld.so.conf.d/lpi_sre_component.conf
#   ldconfig
# ==============================================================================