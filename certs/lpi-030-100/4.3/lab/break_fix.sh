#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100, Version 1.0)
# Topic 4.3: JavaScript Control Structures and Functions (Weight: 10)
# Official Curriculum Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# MDN JavaScript Reference: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Control_flow_and_error_handling
# MDN Functions Reference: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Functions
# ==============================================================================
# LAB TITLE: Production Utility Engine Break & Fix
#
# OBJECTIVE:
# Diagnose and fix common JavaScript production bugs related to control flow,
# loop conditions, switch fallthrough mechanics, variable scoping, and function
# return values.
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi-030-100-topic-4.3-lab"

echo "[+] Setting up LPI 030-100 Topic 4.3 Break & Fix Lab Environment..."
mkdir -p "${LAB_DIR}"
cd "${LAB_DIR}"

# Verify Node.js availability in environment
if ! command -v node &> /dev/null; then
    echo "[!] Node.js runtime not detected. Installing Node.js..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq nodejs
    elif command -v yum &> /dev/null; then
        sudo yum install -y nodejs
    else
        echo "[ERROR] Package manager not supported for automatic Node.js setup. Install Node.js manually."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# 1. Create Broken Production Module: app.js
# ------------------------------------------------------------------------------
cat << 'EOF' > app.js
/**
 * Enterprise Application Logic Engine
 * Topic 4.3: JavaScript Control Structures and Functions
 */

/**
 * Bug 1: Switch Statement Fallthrough
 * Calculates net price after discount based on customer tier.
 * Unintended fallthrough occurs due to omitted 'break' statements.
 */
function calculateDiscount(customerTier, basePrice) {
    let discountRate = 0;
    switch (customerTier.toLowerCase()) {
        case 'vip':
            discountRate += 0.30;
        case 'premium':
            discountRate += 0.20;
        case 'standard':
            discountRate += 0.10;
        default:
            discountRate += 0.05;
    }
    return basePrice * (1 - discountRate);
}

/**
 * Bug 2: Off-by-one Loop Boundary & NaN Aggregation
 * Calculates average processing latency across recorded telemetry batches.
 * Boundary condition 'i <= scores.length' causes out-of-bounds access scores[length] = undefined.
 * Adding numbers to 'undefined' turns total into NaN.
 */
function calculateAverageScore(scores) {
    if (!scores || scores.length === 0) return 0;
    let total = 0;
    for (let i = 0; i <= scores.length; i++) {
        total += scores[i];
    }
    return total / scores.length;
}

/**
 * Bug 3: Scope Leakage & Missing Default Return Path
 * Evaluates administrative authorization based on role and security clear level.
 * Leaves unhandled logical branches returning implicit 'undefined' instead of explicit 'false'.
 */
function authorizeAccess(userRole, securityLevel) {
    var isGranted;
    if (userRole === 'admin') {
        isGranted = true;
    } else if (userRole === 'operator' && securityLevel >= 3) {
        isGranted = true;
    } else if (userRole === 'guest') {
        isGranted = false;
    }
    // Missing explicit fallback return when userRole is unknown or security level fails criteria
    return isGranted;
}

module.exports = {
    calculateDiscount,
    calculateAverageScore,
    authorizeAccess
};
EOF

# ------------------------------------------------------------------------------
# 2. Create Verification Test Runner: test.js
# ------------------------------------------------------------------------------
cat << 'EOF' > test.js
const { calculateDiscount, calculateAverageScore, authorizeAccess } = require('./app');

let passed = 0;
let failed = 0;

function assertTest(testName, actual, expected) {
    const isSuccess = actual === expected;
    if (isSuccess) {
        console.log(` \x1b[32m✔ PASS\x1b[0m : ${testName}`);
        passed++;
    } else {
        console.log(` \x1b[31m✖ FAIL\x1b[0m : ${testName}`);
        console.log(`          Actual Result   : ${actual} (${typeof actual})`);
        console.log(`          Expected Result : ${expected} (${typeof expected})`);
        failed++;
    }
}

console.log("\n=======================================================");
console.log(" LPI 030-100 Topic 4.3 Test Suite Execution");
console.log("=======================================================\n");

// Test Suite 1: Control Structure - Switch Statements
const vipDiscountResult = calculateDiscount('vip', 100);
assertTest("VIP Tier Discount (30% discount on $100 -> $70)", vipDiscountResult, 70);

const standardDiscountResult = calculateDiscount('standard', 100);
assertTest("Standard Tier Discount (10% discount on $100 -> $90)", standardDiscountResult, 90);

// Test Suite 2: Control Structure - Iteration & Loop Boundaries
const avgResult = calculateAverageScore([80, 90, 100]);
assertTest("Telemetry Average Score ([80, 90, 100] -> 90)", avgResult, 90);

// Test Suite 3: Functions - Variable Scope & Return Values
const operatorLowSec = authorizeAccess('operator', 1);
assertTest("Operator with low security level must return boolean false", operatorLowSec, false);

const unknownRole = authorizeAccess('anonymous_guest', 5);
assertTest("Undefined user role must explicitly return boolean false", unknownRole, false);

console.log("\n-------------------------------------------------------");
console.log(` Test Execution Summary: ${passed} Passed | ${failed} Failed`);
console.log("-------------------------------------------------------\n");

if (failed > 0) {
    process.exit(1);
}
EOF

# ------------------------------------------------------------------------------
# 3. Output Student Lab Instructions
# ------------------------------------------------------------------------------
cat << EOF

================================================================================
 LPI CERTIFICATION EXAM 030-100 (v1.0) - TOPIC 4.3 LAB MANUAL
 Subject: JavaScript Control Structures and Functions
 Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/
================================================================================

[ENVIRONMENT OVERVIEW]
Working Directory: ${LAB_DIR}
Target Source   : app.js
Test Execution  : node test.js

[SYMPTOMS REPORTED]
Production monitoring reported three severe bugs in 'app.js':
1. VIP and Standard billing tiers are calculating wrong discount values ($35 instead of $70).
2. Telemetry latency metrics aggregation is returning 'NaN' across all clusters.
3. Access control policies return 'undefined' instead of explicit 'false' for invalid roles.

[STUDENT TASKS]
Inspect and repair '${LAB_DIR}/app.js' using clean JavaScript standards:

Task 1: Fix Switch Control Flow in 'calculateDiscount()'
  - Prevent unintended execution fallthrough into subsequent case blocks.
  - Ensure correct pricing assignment for 'vip', 'premium', 'standard', and 'default'.

Task 2: Fix Loop Off-By-One Boundary in 'calculateAverageScore()'
  - Correct the array bounds termination condition in the 'for' loop.
  - Eliminate out-of-bounds access causing 'undefined' addition and NaN evaluation.

Task 3: Refactor Function Scope & Guarantees in 'authorizeAccess()'
  - Modernize variable declaration: eliminate function-scoped 'var' in favor of 'let' or 'const'.
  - Ensure guaranteed execution pathways return a strict boolean value ('true' or 'false')
    under all inputs, preventing implicit 'undefined' leaks.

[DIAGNOSTIC TOOLING COMMANDS]
Run the following CLI commands inside ${LAB_DIR}:
  $ node test.js
  $ node -e "const app = require('./app'); console.log(app.calculateDiscount('vip', 100));"
  $ node -e "const app = require('./app'); console.log(app.calculateAverageScore([80,90,100]));"
  $ node -e "const app = require('./app'); console.log(app.authorizeAccess('unknown', 1));"

================================================================================
EOF

# ==============================================================================
# STEP-BY-STEP SOLUTION AND TECHNICAL ARCHITECTURE MANUAL (FOR INSTRUCTORS)
# ==============================================================================
#
# TECHNICAL BREAKDOWN OF BUGS & SRE DIAGNOSTICS:
#
# 1. Switch Statement Mechanics (Topic 4.3 - Conditional Control Structures)
#    - Mechanism: JavaScript 'switch' evaluates expressions using strict equality (===).
#      Without an explicit 'break', 'return', or 'throw' inside a matching 'case', execution
#      falls through unconditionally to all subsequent 'case' and 'default' code blocks.
#    - Root Cause: In 'calculateDiscount', matching 'case "vip"' accumulates 0.30, then falls
#      through into 'premium' (+0.20), 'standard' (+0.10), and 'default' (+0.05), totaling
#      0.65 discount rate (Price: $100 * (1 - 0.65) = $35).
#    - Solution: Terminate each block with 'break;' or return directly from case handlers.
#
# 2. For Loop Boundaries & Array Indexing (Topic 4.3 - Iteration Constructs)
#    - Mechanism: Array indices in JavaScript are zero-based (0 to array.length - 1).
#    - Root Cause: In 'calculateAverageScore', 'i <= scores.length' causes the final iteration
#      to evaluate scores[scores.length], which returns 'undefined'. In JS arithmetic,
#      number + undefined evaluates to NaN (Not-a-Number). Dividing NaN by length yields NaN.
#    - Solution: Change iteration condition from 'i <= scores.length' to 'i < scores.length'.
#
# 3. Function Return Values & Scope Hoisting (Topic 4.3 - Functions & Scope)
#    - Mechanism: In JS, functions without an explicit return statement evaluate to 'undefined'.
#      Legacy 'var' declarations are function-scoped and hoisted, increasing risk of variable leakage.
#    - Root Cause: 'authorizeAccess' lacks a fallback return statement when conditions in
#      'if / else if' blocks fail to match. The variable 'isGranted' remains uninitialized ('undefined').
#    - Solution: Refactor block logic to return boolean values directly or use a default 'return false;'
#      at function completion, and adopt block-scoped 'let' / 'const'.
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP SOLUTION MANIFEST OVERWRITE:
# ------------------------------------------------------------------------------
# Run the following block to restore production functionality and verify:
#
# cat << 'EOF_SOLUTION' > /tmp/lpi-030-100-topic-4.3-lab/app.js
# /**
#  * Enterprise Application Logic Engine (Production Fixed Version)
#  * Topic 4.3: JavaScript Control Structures and Functions
#  */
# 
# function calculateDiscount(customerTier, basePrice) {
#     let discountRate = 0;
#     switch (customerTier.toLowerCase()) {
#         case 'vip':
#             discountRate = 0.30;
#             break;
#         case 'premium':
#             discountRate = 0.20;
#             break;
#         case 'standard':
#             discountRate = 0.10;
#             break;
#         default:
#             discountRate = 0.05;
#             break;
#     }
#     return basePrice * (1 - discountRate);
# }
# 
# function calculateAverageScore(scores) {
#     if (!scores || scores.length === 0) return 0;
#     let total = 0;
#     for (let i = 0; i < scores.length; i++) {
#         total += scores[i];
#     }
#     return total / scores.length;
# }
# 
# function authorizeAccess(userRole, securityLevel) {
#     if (userRole === 'admin') {
#         return true;
#     }
#     if (userRole === 'operator' && securityLevel >= 3) {
#         return true;
#     }
#     return false; // Explicit default fallback return path
# }
# 
# module.exports = {
#     calculateDiscount,
#     calculateAverageScore,
#     authorizeAccess
# };
# EOF_SOLUTION
#
# VERIFICATION COMMAND:
# cd /tmp/lpi-030-100-topic-4.3-lab && node test.js
# Expected Output: Summary: 5 Passed | 0 Failed
# ==============================================================================