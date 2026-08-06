#!/usr/bin/env bash
# ==============================================================================
# LPI 050-100: Open Source Essentials - Topic 6.1: Development Tools
# Lab Scenario: Development Tools Breakdown - C Build Pipeline & Git Workspace
# Official Reference: https://www.lpi.org/our-certifications/open-source-essentials-overview/
# ==============================================================================
# This script sets up a controlled, safe lab environment inside /tmp/lpi_dev_tools_lab
# to demonstrate common developer tool failures involving gcc, make, and git.
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_dev_tools_lab"

echo "==============================================================================="
echo "[+] Initializing LPI 050-100 Topic 6.1 Break & Fix Lab in ${LAB_DIR}..."
echo "==============================================================================="

# Cleanup old lab directory if exists
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}"
cd "${LAB_DIR}"

# ------------------------------------------------------------------------------
# 1. Create C Source Code with Intentional Bug
# ------------------------------------------------------------------------------
cat << 'EOF' > utils.h
#ifndef UTILS_H
#define UTILS_H

void print_welcome_message(void);

#endif
EOF

cat << 'EOF' > utils.c
#include <stdio.h>
#include "utils.h"

void print_welcome_message(void) {
    printf("Hello from LPI 050-100 Development Tools Lab!\n");
}
EOF

# INTENTIONAL BUG 1: Wrong header file path inclusion ("util.h" instead of "utils.h")
cat << 'EOF' > main.c
#include <stdio.h>
#include "util.h"

int main(void) {
    print_welcome_message();
    return 0;
}
EOF

# ------------------------------------------------------------------------------
# 2. Create Broken Makefile (Spaces instead of Tab separator)
# ------------------------------------------------------------------------------
# INTENTIONAL BUG 2: Recipes use 4 spaces instead of TAB characters
cat << 'EOF' > Makefile
CC = gcc
CFLAGS = -Wall -Wextra -O2
TARGET = app
SRCS = main.c utils.c
OBJS = $(SRCS:.c=.o)

all: $(TARGET)

$(TARGET): $(OBJS)
    $(CC) $(CFLAGS) $(OBJS) -o $@

%.o: %.c
    $(CC) $(CFLAGS) -c $< -o $@

clean:
    rm -f $(OBJS) $(TARGET)
EOF

# ------------------------------------------------------------------------------
# 3. Setup Git Repository & Stage Build Artifacts
# ------------------------------------------------------------------------------
git init -q

# Pre-compile object files & binary outside make to simulate bad workflow
gcc -Wall -Wextra -O2 -c utils.c -o utils.o 2>/dev/null || true
gcc -Wall -Wextra -O2 -c main.c -o main.o 2>/dev/null || true
touch app

# INTENTIONAL BUG 3: Staging generated binary build artifacts into Git index
# INTENTIONAL BUG 4: Missing .gitignore file
git add main.c utils.c utils.h Makefile main.o utils.o app

# INTENTIONAL BUG 5: Unset local git identity to trigger git commit error
git config --local --unset-all user.name 2>/dev/null || true
git config --local --unset-all user.email 2>/dev/null || true

# ------------------------------------------------------------------------------
# Output Lab Instructions to Student
# ------------------------------------------------------------------------------
cat << EOF

[+] LAB SETUP COMPLETE!
Location: ${LAB_DIR}

===============================================================================
LAB SYMPTOMS & DIAGNOSTICS:
===============================================================================
1. Running 'make' fails immediately with:
   "Makefile:10: *** missing separator. Stop."
2. Manual compilation with 'gcc' fails with:
   "main.c:2:10: fatal error: util.h: No such file or directory"
3. Running 'git status' shows generated binary artifacts (main.o, utils.o, app)
   erroneously staged in the Git repository index.
4. Attempting 'git commit' fails due to missing Git author identity config.

===============================================================================
YOUR OBJECTIVES:
===============================================================================
1. Fix the header inclusion error in 'main.c' so it references 'utils.h'.
2. Fix the syntax error in 'Makefile' by ensuring rule recipe lines start with 
   a TAB character instead of spaces.
3. Create a '.gitignore' file to exclude '*.o' files and the 'app' binary.
4. Remove the staged binary artifacts from the Git index without deleting them 
   from the disk ('git rm --cached ...').
5. Configure local Git user details (user.name and user.email).
6. Verify that 'make clean && make' builds successfully and executing './app' works.
7. Perform a clean initial commit of the project source files and '.gitignore'.

To start working, execute:
  cd ${LAB_DIR}

===============================================================================
EOF

# ==============================================================================
# SOLUTION (STEP-BY-STEP) - DO NOT UNCOMMENT UNTIL YOU HAVE ATTEMPTED THE LAB
# ==============================================================================
#
# Step 1: Fix C header include in main.c
# --------------------------------------------------
# Open main.c and change:
#   #include "util.h"
# to:
#   #include "utils.h"
#
# CLI Command:
#   sed -i 's/#include "util.h"/#include "utils.h"/' /tmp/lpi_dev_tools_lab/main.c
#
#
# Step 2: Fix Makefile syntax (Tabs requirement)
# --------------------------------------------------
# In Makefile, replace leading 4 spaces on recipe lines with a true TAB character.
#
# CLI Command:
#   cd /tmp/lpi_dev_tools_lab
#   printf 'CC = gcc\nCFLAGS = -Wall -Wextra -O2\nTARGET = app\nSRCS = main.c utils.c\nOBJS = $(SRCS:.c=.o)\n\nall: $(TARGET)\n\n$(TARGET): $(OBJS)\n\t$(CC) $(CFLAGS) $(OBJS) -o $@\n\n%%.o: %%.c\n\t$(CC) $(CFLAGS) -c $< -o $@\n\nclean:\n\trm -f $(OBJS) $(TARGET)\n' > Makefile
#
# Test build:
#   make clean && make
#   ./app
#   Expected Output: Hello from LPI 050-100 Development Tools Lab!
#
#
# Step 3: Configure Git User Identity
# --------------------------------------------------
# CLI Commands:
#   git config --local user.name "Student SRE"
#   git config --local user.email "student@example.com"
#
#
# Step 4: Fix Git Index & Create .gitignore
# --------------------------------------------------
# Remove binary artifacts from Git staging area without deleting local files:
#   git rm --cached main.o utils.o app
#
# Create .gitignore file:
#   cat << 'EOF' > .gitignore
#   *.o
#   app
#   EOF
#
# Stage .gitignore and updated source files:
#   git add .gitignore main.c Makefile
#
# Check repository status:
#   git status
#   Expected Output: Clean staging area showing modified main.c, Makefile, and new .gitignore
#
# Create initial commit:
#   git commit -m "Fix build setup, headers, and gitignore configuration"
#
# Verify git log:
#   git log -n 1
# ==============================================================================