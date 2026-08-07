#!/bin/bash
# ==============================================================================
# LPI 030-100 (Web Development Essentials v1.0)
# Topic 4.2: JavaScript Data Structures (Weight: 7.5)
# Production Break & Fix Lab Script
# Reference: https://www.lpi.org/our-certifications/web-development-essentials-overview/
# ==============================================================================

set -euo pipefail

LAB_DIR="/tmp/lpi_js_datastructures_lab"

echo "======================================================================"
echo " LPI 030-100 Topic 4.2: JavaScript Data Structures - Lab Initializer"
echo "======================================================================"

# Step 1: Ensure Node.js runtime is installed
if ! command -v node &> /dev/null; then
    echo "[!] Node.js is required for this lab but was not found."
    echo "[!] Attempting automated package installation..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -y && sudo apt-get install -y nodejs
    elif command -v yum &> /dev/null; then
        sudo yum install -y nodejs
    else
        echo "[E] Package manager not supported. Please install Node.js manually."
        exit 1
    fi
fi

# Step 2: Prepare Lab Directory
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR"

# Step 3: Write Broken Analytics Module (analytics.js)
cat << 'EOF' > "$LAB_DIR/analytics.js"
/**
 * Production Analytics & Data Processing Engine
 * Contains subtle JavaScript Data Structure mechanical bugs:
 * 1. Array mutation & lexicographical default sorting bug
 * 2. Shallow object cloning mutation bug (Reference leak)
 * 3. Object key coercion & truthiness check bug (Map/Set misapplication)
 */

// Bug 1: Should return a new sorted array of top latency values (ascending)
function processLatencyMetrics(rawMetrics) {
    // BROKEN: .sort() mutates rawMetrics directly in-place and defaults to string lexicographical sorting
    return rawMetrics.sort();
}

// Bug 2: Should return an isolated tenant configuration derived from baseConfig
function createTenantConfig(baseConfig, overrides) {
    // BROKEN: Object.assign shallow clone creates shared references for nested properties
    const newConfig = Object.assign({}, baseConfig);
    
    if (overrides.rateLimit) {
        newConfig.features.rateLimit.maxRequests = overrides.rateLimit;
    }
    if (overrides.tenantName) {
        newConfig.tenantName = overrides.tenantName;
    }
    return newConfig;
}

// Bug 3: Should aggregate user activity sessions into unique user set and access counts
function aggregateUserSessions(sessionLogs) {
    // BROKEN: Uses plain object for arbitrary keys (coerces keys to strings & inherits prototype properties)
    // and relies on O(N) array search instead of ES6 Map and Set data structures
    const userCounts = {};
    const uniqueUsers = [];

    for (const log of sessionLogs) {
        const userId = log.userId;

        // Deduplication using O(N) array search instead of O(1) Set membership
        if (!uniqueUsers.includes(userId)) {
            uniqueUsers.push(userId);
        }

        // Object key coercion bug: Integer 101 and String "101" collide on Object keys
        // Truthiness bug: userCounts[userId] evaluation fails if count is falsy
        if (userCounts[userId]) {
            userCounts[userId] += 1;
        } else {
            userCounts[userId] = 1;
        }
    }

    return {
        uniqueUsers: uniqueUsers,
        userCounts: userCounts
    };
}

module.exports = {
    processLatencyMetrics,
    createTenantConfig,
    aggregateUserSessions
};
EOF

# Step 4: Write Diagnostic Test Suite (test.js)
cat << 'EOF' > "$LAB_DIR/test.js"
const analytics = require('./analytics.js');
const assert = require('assert');

console.log("--> Running LPI 030-100 Topic 4.2 Diagnostic Verification Suite...\n");

let passed = 0;
let failed = 0;

function runTest(name, fn) {
    try {
        fn();
        console.log(`\x1b[32m[PASS]\x1b[0m ${name}`);
        passed++;
    } catch (err) {
        console.log(`\x1b[31m[FAIL]\x1b[0m ${name}`);
        console.log(`       Reason: ${err.message}\n`);
        failed++;
    }
}

// Test 1: Array Immutability and Numeric Sorting
runTest("1. Latency Array Processing (Immutability & Numeric Sorting)", () => {
    const originalMetrics = [120, 45, 8, 300, 95];
    const originalCopy = [...originalMetrics];
    
    const sorted = analytics.processLatencyMetrics(originalMetrics);
    
    assert.deepStrictEqual(
        sorted, 
        [8, 45, 95, 120, 300], 
        `Expected numeric sort [8, 45, 95, 120, 300], but got [${sorted.join(', ')}]`
    );
    
    assert.deepStrictEqual(
        originalMetrics, 
        originalCopy, 
        `Original array was mutated! Input arrays must remain immutable.`
    );
});

// Test 2: Deep Object Isolation (Reference vs Value)
runTest("2. Tenant Configuration (Deep Object Isolation)", () => {
    const defaultGlobalState = {
        env: 'production',
        features: {
            rateLimit: { enabled: true, maxRequests: 100 }
        }
    };

    const tenantA = analytics.createTenantConfig(defaultGlobalState, { rateLimit: 500, tenantName: 'TenantA' });
    
    assert.strictEqual(tenantA.features.rateLimit.maxRequests, 500);
    assert.strictEqual(
        defaultGlobalState.features.rateLimit.maxRequests, 
        100, 
        `Global baseConfig was mutated! Tenant override affected shared reference.`
    );
});

// Test 3: Map & Set Data Structures (Type Preservation & O(1) Operations)
runTest("3. User Session Aggregation (Map/Set Data Structures)", () => {
    const userIdNum = 101;
    const userIdStr = "101";

    const sessionLogs = [
        { userId: userIdNum, action: 'login' },
        { userId: userIdStr, action: 'view_page' },
        { userId: userIdNum, action: 'logout' }
    ];

    const result = analytics.aggregateUserSessions(sessionLogs);
    
    // Result userCounts must be an instance of Map to distinguish number 101 from string "101"
    assert(
        result.userCounts instanceof Map, 
        `userCounts must be an instance of ES6 Map to prevent key coercion.`
    );
    
    assert.strictEqual(
        result.userCounts.get(userIdNum), 
        2, 
        `Expected count of 2 for numeric key 101.`
    );
    assert.strictEqual(
        result.userCounts.get(userIdStr), 
        1, 
        `Expected count of 1 for string key "101".`
    );

    // uniqueUsers must be an instance of Set for O(1) unique membership
    assert(
        result.uniqueUsers instanceof Set, 
        `uniqueUsers must be an instance of ES6 Set for O(1) unique membership.`
    );
    assert.strictEqual(result.uniqueUsers.size, 2);
});

console.log(`\n----------------------------------------------------------------------`);
console.log(`Summary: ${passed} Passed, ${failed} Failed.`);
if (failed > 0) {
    console.log(`\x1b[31mLab Status: BROKEN (Fix required)\x1b[0m`);
    process.exit(1);
} else {
    console.log(`\x1b[32mLab Status: RESOLVED (All tests passing)\x1b[0m`);
    process.exit(0);
}
EOF

# Step 5: Execute Initial Test Run to Demonstrate Failure State
echo ""
echo "[*] Setting up broken state in: $LAB_DIR"
echo "[*] Executing diagnostic test runner..."
echo "----------------------------------------------------------------------"
node "$LAB_DIR/test.js" || true
echo "----------------------------------------------------------------------"

echo ""
echo "======================================================================"
echo " LAB SETUP COMPLETE - INSTRUCTIONS FOR STUDENT"
echo "======================================================================"
echo "Target File: $LAB_DIR/analytics.js"
echo "Test Runner: node $LAB_DIR/test.js"
echo ""
echo "SYMPTOMS OBSERVED:"
echo "1. Array Sort & Immutability Bug:"
echo "   'processLatencyMetrics' sorts numbers lexicographically as strings"
echo "   ([120, 45, 8, 300, 95] -> [120, 300, 45, 8, 95]) AND mutates the caller's input array."
echo "2. Object Reference Mutation Bug:"
echo "   Modifying nested configuration properties in 'createTenantConfig' mutates"
echo "   the shared base configuration object across tenant contexts."
echo "3. Key Coercion & Data Structure Misuse:"
echo "   'aggregateUserSessions' uses a plain Object and Array search, causing key"
echo "   coercion (number 101 and string '101' collide) and suboptimal O(N) deduplication."
echo ""
echo "STUDENT OBJECTIVES:"
echo "Refactor '$LAB_DIR/analytics.js' to fulfill the following requirements:"
echo "1. In 'processLatencyMetrics': return a new, non-mutated array sorted numerically"
echo "   ascending using an explicit comparator (a, b) => a - b."
echo "2. In 'createTenantConfig': create an isolated deep copy of baseConfig using"
echo "   'structuredClone()' (or deep copy logic) before mutating nested properties."
echo "3. In 'aggregateUserSessions': replace plain Object and Array logic with ES6 Set"
echo "   for 'uniqueUsers' and ES6 Map for 'userCounts' to preserve key types and guarantee O(1) lookups."
echo ""
echo "Run 'node $LAB_DIR/test.js' to verify your solution."
echo "======================================================================"

# ==============================================================================
# STEP-BY-STEP SOLUTION (Hidden/Commented for Student Reference)
# ==============================================================================
#
# To resolve the lab, update /tmp/lpi_js_datastructures_lab/analytics.js with:
#
# cat << 'SOL_EOF' > /tmp/lpi_js_datastructures_lab/analytics.js
# /**
#  * Production Analytics & Data Processing Engine (Fixed Solution)
#  * LPI 030-100 Topic 4.2 - JavaScript Data Structures
#  */
#
# // Fix 1: Non-mutating numeric array sorting
# function processLatencyMetrics(rawMetrics) {
#     // Create a shallow copy via spread operator [...] to ensure original array immutability,
#     // and provide numeric comparator function (a, b) => a - b to override default string sorting.
#     return [...rawMetrics].sort((a, b) => a - b);
# }
#
# // Fix 2: Deep object isolation using structuredClone
# function createTenantConfig(baseConfig, overrides) {
#     // Object.assign or spread {...obj} only perform shallow copy.
#     // Use structuredClone() to clone nested object references recursively.
#     const newConfig = structuredClone(baseConfig);
#     
#     if (overrides.rateLimit) {
#         newConfig.features.rateLimit.maxRequests = overrides.rateLimit;
#     }
#     if (overrides.tenantName) {
#         newConfig.tenantName = overrides.tenantName;
#     }
#     return newConfig;
# }
#
# // Fix 3: Key-type preservation and O(1) operations with Map and Set
# function aggregateUserSessions(sessionLogs) {
#     // Set provides O(1) unique insertion without array scanning
#     const uniqueUsers = new Set();
#     // Map accepts keys of any data type (preserving number vs string distinctness)
#     const userCounts = new Map();

#     for (const log of sessionLogs) {
#         const userId = log.userId;

#         uniqueUsers.add(userId);

#         const currentCount = userCounts.get(userId) || 0;
#         userCounts.set(userId, currentCount + 1);
#     }

#     return {
#         uniqueUsers: uniqueUsers,
#         userCounts: userCounts
#     };
# }

# module.exports = {
#     processLatencyMetrics,
#     createTenantConfig,
#     aggregateUserSessions
# };
# SOL_EOF
#
# Execute test runner to confirm resolution:
# node /tmp/lpi_js_datastructures_lab/test.js
#
# Expected Verification Output:
# [PASS] 1. Latency Array Processing (Immutability & Numeric Sorting)
# [PASS] 2. Tenant Configuration (Deep Object Isolation)
# [PASS] 3. User Session Aggregation (Map/Set Data Structures)
# Summary: 3 Passed, 0 Failed.
# Lab Status: RESOLVED (All tests passing)
# ==============================================================================