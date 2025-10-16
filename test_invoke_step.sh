#!/bin/bash
# Test script for invoke_step.ps1 enhancements
# Tests prerequisite steps, smart propagation, and parameter detection

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}🧪 TESTING invoke_step.ps1 ENHANCEMENTS${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════${NC}"
echo ""

# Configuration
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
INVOKE_STEP="$SCRIPT_DIR/scripts/step_wrappers/invoke_step.ps1"

# Test counter
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function to run test
run_test() {
    local test_name=$1
    local test_command=$2
    local expected_pattern=$3
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${YELLOW}Test $TESTS_RUN: $test_name${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    echo -e "${YELLOW}Command:${NC}"
    echo "  $test_command"
    echo ""
    
    # Run the command and capture output
    if eval "$test_command" > /tmp/test_output_$TESTS_RUN.log 2>&1; then
        echo -e "${GREEN}✅ Command executed successfully${NC}"
        
        # Check for expected pattern if provided
        if [ -n "$expected_pattern" ]; then
            if grep -q "$expected_pattern" /tmp/test_output_$TESTS_RUN.log; then
                echo -e "${GREEN}✅ Found expected pattern: $expected_pattern${NC}"
                TESTS_PASSED=$((TESTS_PASSED + 1))
            else
                echo -e "${RED}❌ Expected pattern not found: $expected_pattern${NC}"
                echo ""
                echo -e "${YELLOW}Output:${NC}"
                cat /tmp/test_output_$TESTS_RUN.log
                TESTS_FAILED=$((TESTS_FAILED + 1))
            fi
        else
            TESTS_PASSED=$((TESTS_PASSED + 1))
        fi
    else
        echo -e "${RED}❌ Command failed with exit code: $?${NC}"
        echo ""
        echo -e "${YELLOW}Output:${NC}"
        cat /tmp/test_output_$TESTS_RUN.log
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST SUITE
# ═══════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}📋 Pre-flight Checks${NC}"
echo "   • invoke_step.ps1 exists: $([ -f "$INVOKE_STEP" ] && echo "✅" || echo "❌")"
echo "   • PowerShell available: $(command -v pwsh >/dev/null 2>&1 && echo "✅" || echo "❌")"
echo ""

# Test 1: Basic parameter parsing
run_test \
    "Basic parameter parsing (DryRun)" \
    "pwsh $INVOKE_STEP ScriptPath=restore/RestorePointInTime.ps1 Source=gov001 DryRun=true 2>&1 | head -50" \
    "Parsed: DryRun = true"

# Test 2: Boolean parameter conversion
run_test \
    "Boolean parameter conversion" \
    "pwsh $INVOKE_STEP ScriptPath=restore/RestorePointInTime.ps1 DryRun=true Force=false 2>&1 | grep -E '(DryRun|Force)'" \
    "DryRun = True"

# Test 3: Integer parameter parsing
run_test \
    "Integer parameter parsing" \
    "pwsh $INVOKE_STEP ScriptPath=restore/RestorePointInTime.ps1 MaxWaitMinutes=60 2>&1 | grep MaxWaitMinutes" \
    "MaxWaitMinutes = 60"

# Test 4: Dynamic repository path detection
run_test \
    "Dynamic repository path detection" \
    "pwsh $INVOKE_STEP ScriptPath=restore/RestorePointInTime.ps1 DryRun=true 2>&1 | grep -A5 'Detecting latest repository'" \
    "Detecting latest repository"

# Test 5: Prerequisite steps execution
run_test \
    "Prerequisite steps execution (0A, 0B, 0C)" \
    "pwsh $INVOKE_STEP ScriptPath=restore/RestorePointInTime.ps1 Source=gov001 DryRun=true 2>&1 | grep -E '(STEP 0A|STEP 0B|STEP 0C)'" \
    "STEP 0A"

# Test 6: Environment parameter detection
run_test \
    "Environment parameter detection" \
    "ENVIRONMENT=gov001 pwsh $INVOKE_STEP ScriptPath=restore/RestorePointInTime.ps1 DryRun=true 2>&1 | grep -E '(Using ENVIRONMENT|Using Source)'" \
    ""

# Test 7: Missing ScriptPath error
echo ""
echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}Test $((TESTS_RUN + 1)): Missing ScriptPath parameter (should fail)${NC}"
echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────${NC}"
echo ""

TESTS_RUN=$((TESTS_RUN + 1))
if pwsh $INVOKE_STEP Source=gov001 2>&1 | grep -q "ScriptPath parameter is required"; then
    echo -e "${GREEN}✅ Correctly detected missing ScriptPath${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}❌ Failed to detect missing ScriptPath${NC}"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test 8: Target script parameter validation
run_test \
    "Target script parameter validation" \
    "pwsh $INVOKE_STEP ScriptPath=restore/RestorePointInTime.ps1 Source=gov001 DryRun=true 2>&1 | grep 'Target script accepts'" \
    "Target script accepts"

# Test 9: Smart propagation wait detection (simulate)
echo ""
echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────${NC}"
echo -e "${YELLOW}Test $((TESTS_RUN + 1)): Smart propagation wait (manual check)${NC}"
echo -e "${CYAN}───────────────────────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "${YELLOW}ℹ️  This test requires manual verification:${NC}"
echo "   1. Run the script twice in succession"
echo "   2. First run should wait 30 seconds (if permissions needed)"
echo "   3. Second run should skip wait (already has permissions)"
echo ""
TESTS_RUN=$((TESTS_RUN + 1))
echo -e "${CYAN}⏭️  Skipping automated test (requires Azure credentials)${NC}"

# ═══════════════════════════════════════════════════════════════════════════
# TEST SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}📊 TEST SUMMARY${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "   Tests Run:    $TESTS_RUN"
echo -e "   ${GREEN}Tests Passed: $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "   ${RED}Tests Failed: $TESTS_FAILED${NC}"
else
    echo -e "   ${GREEN}Tests Failed: $TESTS_FAILED${NC}"
fi
echo ""

# Calculate success rate
if [ $TESTS_RUN -gt 0 ]; then
    SUCCESS_RATE=$((TESTS_PASSED * 100 / TESTS_RUN))
    echo "   Success Rate: $SUCCESS_RATE%"
fi

echo ""
if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED!${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}❌ SOME TESTS FAILED${NC}"
    echo ""
    echo "Review the output above for details"
    echo ""
    exit 1
fi

