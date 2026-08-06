#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100, Version 1.0)
# Topic 1.1: Software Development Basics (Weight: 2.5)
# Hands-On "Break & Fix" Production-Level Lab Script
#
# Official References:
# - LPI Web Development Essentials: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# - Git Documentation: https://git-scm.com/doc
# - Node.js Documentation: https://nodejs.org/en/docs/
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi030_topic1_1_lab"

echo "======================================================================"
echo " Setting up LPI 030-100 Topic 1.1 Break & Fix Lab Environment..."
echo "======================================================================"

# Clean up previous runs
rm -rf "${LAB_DIR}"
mkdir -p "${LAB_DIR}"
cd "${LAB_DIR}"

# Initialize Git Repository
git init -q
git config user.name "SRE Student"
git config user.email "student@production.local"

# Create initial clean project files
cat <<'EOF' > app.js
const http = require('http');

const PORT = process.env.PORT || 3000;

const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Web App Status: Operational\n');
});

server.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});
EOF

cat <<'EOF' > package.json
{
  "name": "lpi-dev-basics-app",
  "version": "1.0.0",
  "description": "LPI 030-100 Software Development Basics Demo App",
  "main": "app.js",
  "scripts": {
    "start": "node app.js",
    "build": "./scripts/build.sh"
  }
}
EOF

mkdir -p scripts
cat <<'EOF' > scripts/build.sh
#!/usr/bin/env bash
echo "Building web application assets..."
echo "Build pipeline completed successfully."
EOF

# Initial commit
git add .
git commit -m "Initial working commit" -q

# Branch creation for feature development
git checkout -b feature/login -q
cat <<'EOF' > app.js
const http = require('http');

const PORT = process.env.PORT || 3000;

// Feature branch: Auth endpoint added
const server = http.createServer((req, res) => {
    if (req.url === '/login') {
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        return res.end('Login Page\n');
    }
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Web App Status: Operational (with Auth)\n');
});

server.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});
EOF
git add app.js
git commit -m "Add login route functionality" -q

# Switch to main branch and make conflicting changes
git checkout main -q
cat <<'EOF' > app.js
const http = require('http');

const PORT = process.env.PORT || 3000;

// Main branch: Status string updated
const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Web App Status: Operational v1.1\n');
});

server.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});
EOF
git add app.js
git commit -m "Update status message in main" -q

# Trigger merge conflict without resolving
git merge feature/login -q || true

# Inject broken conflict markers combined with JavaScript syntax error
cat <<'EOF' > app.js
<<<<<<< HEAD
const http = require('http');

const PORT = process.env.PORT || 3000;

// Main branch: Status string updated
const server = http.createServer((req, res => {  // SYNTAX ERROR: missing closing parenthesis
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Web App Status: Operational v1.1\n');
});
=======
const http = require('http');

const PORT = process.env.PORT || 3000;

// Feature branch: Auth endpoint added
const server = http.createServer((req, res) => {
    if (req.url === '/login') {
        res.writeHead(200, { 'Content-Type': 'text/plain' });
        return res.end('Login Page\n');
    }
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Web App Status: Operational (with Auth)\n');
});
>>>>>>> feature/login

server.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});
EOF

# Break file execution permissions on build script
chmod -x scripts/build.sh

# Display setup information and instructions
echo ""
echo "======================================================================"
echo " [!] BREAK & FIX LAB READY: ${LAB_DIR}"
echo "======================================================================"
echo ""
echo "SCENARIO BACKGROUND:"
echo "A developer left an incomplete branch merge in production, introducing"
echo "unresolved Git conflict markers, a broken JavaScript file, and invalid"
echo "file permissions on key automation scripts."
echo ""
echo "SYMPTOMS TO INVESTIGATE:"
echo "1. Running 'git status' shows 'app.js' in an unmerged / conflict state."
echo "2. Executing 'node app.js' or 'npm start' throws a SyntaxError."
echo "3. Executing 'npm run build' fails with a 'Permission denied' error."
echo ""
echo "LAB OBJECTIVES:"
echo "1. Navigate to '${LAB_DIR}' and inspect the repository state."
echo "2. Resolve the Git merge conflict in 'app.js' cleanly."
echo "3. Fix the syntax error in 'app.js' to make the server operational."
echo "4. Finalize and commit the merge resolution in Git."
echo "5. Fix file permissions for 'scripts/build.sh' to allow asset building."
echo ""
echo "INITIAL DIAGNOSTIC COMMANDS:"
echo "  cd ${LAB_DIR}"
echo "  git status"
echo "  node app.js"
echo "  npm run build"
echo ""
echo "======================================================================"

# ==============================================================================
# STEP-BY-STEP SOLUTION (DO NOT READ UNTIL YOU HAVE ATTEMPTED THE LAB)
# ==============================================================================
#
# Step 1: Change directory to the lab environment:
#   cd /tmp/lpi030_topic1_1_lab
#
# Step 2: Inspect Git status to identify conflicted files:
#   git status
#   # Output indicates app.js has unmerged paths due to merge conflict.
#
# Step 3: Open `app.js` and locate conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`).
#   - Remove all conflict markers.
#   - Combine feature updates (login route + updated status response).
#   - Fix the arrow function syntax error on line 6:
#     - BROKEN:  const server = http.createServer((req, res => {
#     - CORRECT: const server = http.createServer((req, res) => {
#
#   Corrected content for app.js:
#   --------------------------------------------------------------------------
#   const http = require('http');
#
#   const PORT = process.env.PORT || 3000;
#
#   const server = http.createServer((req, res) => {
#       if (req.url === '/login') {
#           res.writeHead(200, { 'Content-Type': 'text/plain' });
#           return res.end('Login Page\n');
#       }
#       res.writeHead(200, { 'Content-Type': 'text/plain' });
#       res.end('Web App Status: Operational v1.1 (with Auth)\n');
#   });
#
#   server.listen(PORT, () => {
#       console.log(`Server running on port ${PORT}`);
#   });
#   --------------------------------------------------------------------------
#
# Step 4: Stage the fixed file and complete the Git merge commit:
#   git add app.js
#   git commit -m "Fix merge conflict and syntax error in app.js"
#
# Step 5: Test Node.js application execution:
#   npm start
#   # Or direct execution: node app.js
#   # Expected result: "Server running on port 3000"
#
# Step 6: Inspect and fix build script file permissions:
#   ls -la scripts/build.sh
#   chmod +x scripts/build.sh
#
# Step 7: Verify build script execution:
#   npm run build
#   # Expected output:
#   # Building web application assets...
#   # Build pipeline completed successfully.
# ==============================================================================