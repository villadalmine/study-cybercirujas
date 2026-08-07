#!/usr/bin/env bash
# ==============================================================================
# LPI Web Development Essentials (Exam 030-100, v1.0)
# Topic 4.1: JavaScript Execution and Syntax (Weight: 2.5)
# Lab Break-and-Fix Scenario: Production Node.js Microservice Execution Failure
# ==============================================================================
# Official Reference:
# https://www.lpi.org/our-certifications/web-development-essentials-overview/
# MDN JS Grammar & Types: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Grammar_and_types
# MDN Strict Mode: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Strict_mode
# Node.js Command Line Options: https://nodejs.org/api/cli.html
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi030-topic41-lab"

echo "[+] Setting up LPI 030-100 Topic 4.1 Break-and-Fix Lab in ${LAB_DIR}..."

mkdir -p "${LAB_DIR}"

# Inject the broken JavaScript microservice script into the lab directory
cat << 'EOF' > "${LAB_DIR}/telemetry_service.js"
"use strict";

/**
 * Production Telemetry Processor Microservice
 * Exam Topic 4.1: JavaScript Execution, Scope, Hoisting, and Strict Mode Rules
 */

const APP_VERSION = "2.4.0";
let totalEventsProcessed = 0;

function initializeService() {
    console.log("[INFO] Starting Telemetry Engine v" + APP_VERSION);

    // BUG 1 (Temporal Dead Zone): Attempting to access 'serviceRegion' before lexical initialization
    console.log("[INFO] Target Data Center Region: " + serviceRegion);
    let serviceRegion = "us-east-1";

    // BUG 2 (Strict Mode Violation): Un-declared variable allocation attaches to implicit global state
    metricsCollector = {
        startTime: Date.now(),
        status: "ACTIVE"
    };
}

function processMetricPayload(rawPayload) {
    // BUG 3 (Hoisting & NaN logic failure): 'multiplier' is used in calculation before its declaration line
    for (let i = 0; i < rawPayload.items.length; i++) {
        let item = rawPayload.items[i];
        
        let itemScore = item.value * multiplier;
        if (isNaN(itemScore)) {
            throw new TypeError("Calculation resulted in NaN due to undefined variable scope!");
        }
        totalEventsProcessed += 1;
    }

    var multiplier = 1.5;
    return totalEventsProcessed;
}

// Entry Point Execution Block
try {
    initializeService();

    const sampleData = { items: [{ id: 101, value: 42 }, { id: 102, value: 84 }] };
    const processedCount = processMetricPayload(sampleData);

    console.log("[SUCCESS] Batch processing complete. Records processed: " + processedCount);
} catch (error) {
    console.error("[CRITICAL FAILURE] Unhandled Exception during Execution Phase:");
    console.error(error.stack);
    process.exit(1);
}
EOF

# Create a automated validator script for the student
cat << 'EOF' > "${LAB_DIR}/validate.sh"
#!/usr/bin/env bash
echo "[+] Validating telemetry_service.js..."
if node --check /tmp/lpi030-topic41-lab/telemetry_service.js && node /tmp/lpi030-topic41-lab/telemetry_service.js; then
    echo ""
    echo "=========================================================================="
    echo "[VERIFICATION SUCCESSFUL] All JavaScript execution & syntax errors resolved!"
    echo "=========================================================================="
    exit 0
else
    echo ""
    echo "=========================================================================="
    echo "[VERIFICATION FAILED] Execution errors still present in telemetry_service.js"
    echo "=========================================================================="
    exit 1
fi
EOF
chmod +x "${LAB_DIR}/validate.sh"

echo "=========================================================================="
echo " LAB ENVIRONMENT READY: ${LAB_DIR}"
echo "=========================================================================="
echo "SCENARIO OVERVIEW:"
echo "You are deployed as an SRE on a production system running a Node.js telemetry"
echo "ingestion microservice. Following a recent update, the service fails to"
echo "start up and crashes repeatedly during execution."
echo ""
echo "SYMPTOMS OBSERVED:"
echo "1. Startup crash: ReferenceError complaining about accessing a variable before"
echo "   initialization."
echo "2. Secondary crash (upon fixing startup): ReferenceError caused by strict mode"
echo "   ('use strict') forbidding undeclared global variables."
echo "3. Data corruption crash (upon fixing scope): TypeError triggered because a variable"
echo "   is hoisted as 'undefined' during iteration, causing NaN computations."
echo ""
echo "STUDENT OBJECTIVES:"
echo "1. Navigate to: cd ${LAB_DIR}"
echo "2. Execute 'node telemetry_service.js' to observe the stack trace."
echo "3. Refactor '${LAB_DIR}/telemetry_service.js' to resolve:"
echo "   - Temporal Dead Zone (TDZ) lexical scope ordering."
echo "   - Strict mode variable declaration compliance ('let' / 'const')."
echo "   - Variable hoisting order to ensure correct numeric processing."
echo "4. Verify your fix by executing: bash ${LAB_DIR}/validate.sh"
echo "=========================================================================="
echo "Start troubleshooting by running:"
echo "  cd ${LAB_DIR} && node telemetry_service.js"
echo "=========================================================================="

# ==============================================================================
# SOLUTION & STEP-BY-STEP TECHNICAL EXPLANATION (FOR INSTRUCTOR / STUDENT REFERENCE)
# ==============================================================================
#
# TECHNICAL MECHANICS & ARCHITECTURE DEEP DIVE (LPI 030-100 Topic 4.1):
#
# 1. JavaScript Engine Execution Context (Creation Phase vs. Execution Phase):
#    When V8 / Node.js executes JavaScript, it executes in two main phases:
#    a. Creation (Parsing & Allocation) Phase:
#       - The engine creates the Global Execution Context and Function Execution Contexts.
#       - Allocates memory for function declarations and variables.
#       - Declarations made with `var` are hoisted and initialized with `undefined`.
#       - Declarations made with `let` and `const` are hoisted into the block's Lexical Environment
#         record, but remain UNINITIALIZED. This state between entry into scope and the actual
#         initialization line is known as the Temporal Dead Zone (TDZ). Accessing a variable
#         in the TDZ throws a `ReferenceError`.
#    b. Execution Phase:
#       - Code runs line-by-line in single-threaded event-loop execution.
#
# 2. Strict Mode Mechanics ('use strict'):
#    - Strict mode changes silent runtime failures into explicit thrown errors.
#    - Prevents accidental global variable creation (assigning to an identifier without `var`,
#      `let`, or `const` throws `ReferenceError: metricsCollector is not defined` instead of
#      creating a property on `globalThis`).
#    - Enforces strict parsing rules for function parameter uniqueness and read-only property mutations.
#
# 3. Scope Differences (`var` vs `let` / `const`):
#    - `var` is function-scoped (or globally scoped if declared outside a function). It ignores block
#      constructs like `if` and `for`. Because it is hoisted and initialized to `undefined`, accessing it
#      before declaration yields `undefined` (resulting in `number * undefined = NaN`).
#    - `let` and `const` are block-scoped (`{ ... }`), preventing variable leaks outside loops and blocks.
#
# OFFICIAL REFERENCES & CITATIONS:
# - LPI Web Development Essentials 030-100: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# - MDN Grammar & Types: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Grammar_and_types
# - MDN Strict Mode: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Strict_mode
# - Node.js CLI Flags (`--check`, `--inspect`): https://nodejs.org/api/cli.html
#
# ------------------------------------------------------------------------------
# STEP-BY-STEP DIAGNOSTIC PROCEDURE & REAL CLI COMMANDS:
# ------------------------------------------------------------------------------
# Step 1: Perform static syntax check using Node CLI syntax analyzer:
#   $ node --check /tmp/lpi030-topic41-lab/telemetry_service.js
#   Expected CLI Output:
#     (Command exits zero because syntax is structurally valid, but runtime lexical errors exist)
#
# Step 2: Execute script to catch the first runtime error (Temporal Dead Zone):
#   $ node /tmp/lpi030-topic41-lab/telemetry_service.js
#   Expected CLI Output:
#     [CRITICAL FAILURE] Unhandled Exception during Execution Phase:
#     ReferenceError: Cannot access 'serviceRegion' before initialization
#         at initializeService (/tmp/lpi030-topic41-lab/telemetry_service.js:18:43)
#         at Object.<anonymous> (/tmp/lpi030-topic41-lab/telemetry_service.js:46:5)
#
# Step 3: Fix BUG 1 by placing `let serviceRegion = "us-east-1";` BEFORE `console.log(...)`.
#
# Step 4: Re-run script to catch second runtime error (Strict Mode Violation):
#   $ node /tmp/lpi030-topic41-lab/telemetry_service.js
#   Expected CLI Output:
#     [CRITICAL FAILURE] Unhandled Exception during Execution Phase:
#     ReferenceError: metricsCollector is not defined
#         at initializeService (/tmp/lpi030-topic41-lab/telemetry_service.js:22:22)
#
# Step 5: Fix BUG 2 by declaring `const metricsCollector = { ... }`.
#
# Step 6: Re-run script to catch third runtime error (Hoisting / NaN failure):
#   $ node /tmp/lpi030-topic41-lab/telemetry_service.js
#   Expected CLI Output:
#     [CRITICAL FAILURE] Unhandled Exception during Execution Phase:
#     TypeError: Calculation resulted in NaN due to undefined variable scope!
#         at processMetricPayload (/tmp/lpi030-topic41-lab/telemetry_service.js:35:19)
#
# Step 7: Fix BUG 3 by moving `const multiplier = 1.5;` above the `for` loop block and changing `var` to `const`.
#
# ------------------------------------------------------------------------------
# COMPLETE SYNTACTICALLY VALID SOLUTION (telemetry_service.js):
# ------------------------------------------------------------------------------
# To apply the solution directly via CLI, run:
#
# cat << 'EOF' > /tmp/lpi030-topic41-lab/telemetry_service.js
# "use strict";
# 
# const APP_VERSION = "2.4.0";
# let totalEventsProcessed = 0;
# 
# function initializeService() {
#     console.log("[INFO] Starting Telemetry Engine v" + APP_VERSION);
# 
#     // FIX 1: Declared 'serviceRegion' before accessing it (TDZ Resolved)
#     let serviceRegion = "us-east-1";
#     console.log("[INFO] Target Data Center Region: " + serviceRegion);
# 
#     // FIX 2: Added explicit declaration identifier ('const') for strict mode compliance
#     const metricsCollector = {
#         startTime: Date.now(),
#         status: "ACTIVE"
#     };
# }
# 
# function processMetricPayload(rawPayload) {
#     // FIX 3: Defined block-scoped 'multiplier' before processing elements to prevent undefined hoisting
#     const multiplier = 1.5;

#     for (let i = 0; i < rawPayload.items.length; i++) {
#         let item = rawPayload.items[i];
#         
#         let itemScore = item.value * multiplier;
#         if (isNaN(itemScore)) {
#             throw new TypeError("Calculation resulted in NaN due to undefined variable scope!");
#         }
#         totalEventsProcessed += 1;
#     }
# 
#     return totalEventsProcessed;
# }
# 
# try {
#     initializeService();
# 
#     const sampleData = { items: [{ id: 101, value: 42 }, { id: 102, value: 84 }] };
#     const processedCount = processMetricPayload(sampleData);
# 
#     console.log("[SUCCESS] Batch processing complete. Records processed: " + processedCount);
# } catch (error) {
#     console.error("[CRITICAL FAILURE] Unhandled Exception during Execution Phase:");
#     console.error(error.stack);
#     process.exit(1);
# }
# EOF
#
# Then run validation:
#   bash /tmp/lpi030-topic41-lab/validate.sh
# ==============================================================================