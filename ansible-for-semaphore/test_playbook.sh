#!/bin/bash

# Self-Service Refresh Testing Script
# This script helps test the Ansible playbook locally before deploying to Semaphore

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK_DIR="${SCRIPT_DIR}/playbooks"
INVENTORY_DIR="${SCRIPT_DIR}/inventory"
LOGS_DIR="${SCRIPT_DIR}/logs"

# Create logs directory
mkdir -p "${LOGS_DIR}"

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Self-Service Data Refresh Testing Script

OPTIONS:
    -s, --source ENV        Source environment (REQUIRED)
    -d, --dest ENV          Destination environment (REQUIRED)
    -c, --customer ALIAS    Customer alias (REQUIRED)
    --source-sub-id ID      Source subscription ID (REQUIRED)
    --dest-sub-id ID        Destination subscription ID (REQUIRED) 
    --source-ns NS          Source namespace (REQUIRED)
    --dest-ns NS            Destination namespace (REQUIRED)
    -o, --operation OP      Operation to perform (default: full)
                           Options: full, copy_database, restore_point, etc.
    --dry-run              Enable dry run mode (preview only)
    --check                Perform syntax check only
    --list-tasks           List all tasks without executing
    --validate-only        Just validate parameters and configuration (skip ansible check)
    --verbose              Enable verbose output (-vvv)
    --show-outputs         Show only script outputs (forces dry run)
    --max-wait MINUTES     Maximum wait time in minutes (default: 30)
    --skip-steps STEPS     Comma-separated list of steps to skip
                           Options: restore,stop,copy_attachments,copy_database,
                                   adjust_resources,start,cleanup,permissions
    -h, --help             Show this help message

EXAMPLES:
    # Dry run (all parameters required)
    $0 -s gov002 -d gov001 -c gov001-test \
       --source-sub-id xxx --dest-sub-id yyy \
       --source-ns manufacturo --dest-ns test --dry-run

    # Full refresh with all required parameters
    $0 -s gov002 -d gov001 -c gov001-test \
       --source-sub-id xxx --dest-sub-id yyy \
       --source-ns manufacturo --dest-ns test

    # Copy database only (skip environment stop/start)
    $0 -o copy_database --skip-steps stop,start,adjust_resources

    # Syntax check
    $0 --check

    # List all tasks
    $0 --list-tasks

    # Verbose dry run
    $0 --dry-run --verbose

EOF
}

# Default values - REQUIRED PARAMETERS
SOURCE_ENV=""
DEST_ENV=""
SOURCE_SUB_ID=""
DEST_SUB_ID=""
SOURCE_NS=""
DEST_NS=""
CUSTOMER=""
# Optional parameters
OPERATION="full"
DRY_RUN="false"
CHECK_ONLY="false"
LIST_TASKS="false"
VALIDATE_ONLY="false"
VERBOSE=""
MAX_WAIT="30"
SKIP_STEPS=""
SHOW_OUTPUTS_ONLY="false"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--source)
            SOURCE_ENV="$2"
            shift 2
            ;;
        -d|--dest)
            DEST_ENV="$2"
            shift 2
            ;;
        -c|--customer)
            CUSTOMER="$2"
            shift 2
            ;;
        --source-sub-id)
            SOURCE_SUB_ID="$2"
            shift 2
            ;;
        --dest-sub-id)
            DEST_SUB_ID="$2"
            shift 2
            ;;
        --source-ns)
            SOURCE_NS="$2"
            shift 2
            ;;
        --dest-ns)
            DEST_NS="$2"
            shift 2
            ;;
        -o|--operation)
            OPERATION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --check)
            CHECK_ONLY="true"
            shift
            ;;
        --list-tasks)
            LIST_TASKS="true"
            shift
            ;;
        --validate-only)
            VALIDATE_ONLY="true"
            shift
            ;;
        --verbose)
            VERBOSE="-vvv"
            shift
            ;;
        --show-outputs|--outputs-only)
            SHOW_OUTPUTS_ONLY="true"
            DRY_RUN="true"  # Force dry run when showing outputs only
            shift
            ;;
        --max-wait)
            MAX_WAIT="$2"
            shift 2
            ;;
        --skip-steps)
            SKIP_STEPS="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Function to validate required parameters
validate_parameters() {
    local missing_params=()
    
    [[ -z "$SOURCE_ENV" ]] && missing_params+=("--source")
    [[ -z "$DEST_ENV" ]] && missing_params+=("--dest")
    [[ -z "$SOURCE_SUB_ID" ]] && missing_params+=("--source-sub-id")
    [[ -z "$DEST_SUB_ID" ]] && missing_params+=("--dest-sub-id")
    [[ -z "$SOURCE_NS" ]] && missing_params+=("--source-ns")
    [[ -z "$DEST_NS" ]] && missing_params+=("--dest-ns")
    [[ -z "$CUSTOMER" ]] && missing_params+=("--customer")
    
    if [[ ${#missing_params[@]} -gt 0 ]]; then
        print_error "Missing required parameters: ${missing_params[*]}"
        echo
        print_status "All parameters are required. Use --help for examples."
        echo
        print_status "Quick example:"
        echo "  $0 -s gov002 -d gov001 -c gov001-test \\"
        echo "     --source-sub-id YOUR_SOURCE_SUB_ID \\"
        echo "     --dest-sub-id YOUR_DEST_SUB_ID \\"
        echo "     --source-ns manufacturo --dest-ns test --dry-run"
        exit 1
    fi
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check if ansible is installed
    if ! command -v ansible-playbook &> /dev/null; then
        print_warning "ansible-playbook is not found in PATH"
        print_status "Checking alternative locations..."
        
        # Check common installation paths
        local ansible_paths=(
            "/usr/local/bin/ansible-playbook"
            "/usr/bin/ansible-playbook"
            "$HOME/.local/bin/ansible-playbook"
            "$(which python3 2>/dev/null | sed 's/python3$/ansible-playbook/')"
        )
        
        local found_ansible=""
        for path in "${ansible_paths[@]}"; do
            if [[ -f "$path" ]]; then
                found_ansible="$path"
                print_status "Found ansible-playbook at: $path"
                break
            fi
        done
        
        if [[ -z "$found_ansible" ]]; then
            print_error "ansible-playbook is not installed or not accessible"
            print_status "Please install Ansible or ensure it's in your PATH"
            exit 1
        fi
        
        # Export the found path for use in run_playbook
        export ANSIBLE_PLAYBOOK_PATH="$found_ansible"
    else
        export ANSIBLE_PLAYBOOK_PATH="ansible-playbook"
    fi
    
    # Check if required files exist
    if [[ ! -f "${PLAYBOOK_DIR}/self_service_refresh.yaml" ]]; then
        print_error "Playbook not found: ${PLAYBOOK_DIR}/self_service_refresh.yaml"
        exit 1
    fi
    
    if [[ ! -f "${INVENTORY_DIR}/hosts.ini" ]]; then
        print_error "Inventory not found: ${INVENTORY_DIR}/hosts.ini"
        exit 1
    fi
    
    # Check if Azure CLI is available (for production runs)
    if [[ "${DRY_RUN}" != "true" ]] && ! command -v az &> /dev/null; then
        print_warning "Azure CLI (az) is not installed. This may cause issues in production runs."
    fi
    
    print_success "Prerequisites check passed"
}

# Function to build extra vars
build_extra_vars() {
    local extra_vars=()
    
    # Required parameters
    extra_vars+=("source_env=${SOURCE_ENV}")
    extra_vars+=("dest_env=${DEST_ENV}")
    extra_vars+=("source_sub_id=${SOURCE_SUB_ID}")
    extra_vars+=("dest_sub_id=${DEST_SUB_ID}")
    extra_vars+=("source_ns=${SOURCE_NS}")
    extra_vars+=("dest_ns=${DEST_NS}")
    extra_vars+=("customer=${CUSTOMER}")
    
    # Optional parameters
    extra_vars+=("op=${OPERATION}")
    extra_vars+=("dry_run_mode=${DRY_RUN}")
    extra_vars+=("max_wait=${MAX_WAIT}")
    
    # Handle skip steps
    if [[ -n "${SKIP_STEPS}" ]]; then
        IFS=',' read -ra STEPS <<< "${SKIP_STEPS}"
        for step in "${STEPS[@]}"; do
            case "$step" in
                restore) extra_vars+=("skip_restore_step=true") ;;
                stop) extra_vars+=("skip_stop_step=true") ;;
                copy_attachments) extra_vars+=("skip_copy_attachments_step=true") ;;
                copy_database) extra_vars+=("skip_copy_database_step=true") ;;
                adjust_resources) extra_vars+=("skip_adjust_resources_step=true") ;;
                start) extra_vars+=("skip_start_step=true") ;;
                cleanup) extra_vars+=("skip_cleanup_step=true") ;;
                permissions) extra_vars+=("skip_permissions_step=true") ;;
                *) print_warning "Unknown skip step: $step" ;;
            esac
        done
    fi
    
    # Join array elements with spaces
    printf "%s " "${extra_vars[@]}"
}

# Function to run the playbook
run_playbook() {
    local extra_vars
    extra_vars=$(build_extra_vars)
    
    local ansible_cmd=(
        "${ANSIBLE_PLAYBOOK_PATH:-ansible-playbook}"
        "${PLAYBOOK_DIR}/self_service_refresh.yaml"
        -i "${INVENTORY_DIR}/hosts.ini"
        --extra-vars "${extra_vars}"
    )
    
    # Add additional flags based on options
    if [[ "${CHECK_ONLY}" == "true" ]]; then
        ansible_cmd+=(--check --diff)
        print_status "Running syntax check..."
    elif [[ "${LIST_TASKS}" == "true" ]]; then
        ansible_cmd+=(--list-tasks)
        print_status "Listing tasks..."
    else
        if [[ "${DRY_RUN}" == "true" ]]; then
            print_status "Running in DRY RUN mode..."
        else
            print_status "Running playbook..."
        fi
    fi
    
    if [[ -n "${VERBOSE}" ]]; then
        ansible_cmd+=("${VERBOSE}")
    fi
    
    # Create log file
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local log_file="${LOGS_DIR}/run_${timestamp}.log"
    
    print_status "Command: ${ansible_cmd[*]}"
    print_status "Log file: ${log_file}"
    
    # Run the command and capture output (always verbose for dry runs to capture script outputs)
    if [[ "${VERBOSE}" == "" && "${DRY_RUN}" == "true" ]]; then
        # Add verbose output for dry runs to capture script outputs
        ansible_cmd+=("-v")
    fi
    
    if "${ansible_cmd[@]}" 2>&1 | tee "${log_file}"; then
        print_success "Playbook execution completed successfully"
        print_status "Log saved to: ${log_file}"
        
        # Auto-show script outputs for dry runs
        if [[ "${DRY_RUN}" == "true" && -f "./extract_script_outputs.sh" ]]; then
            echo ""
            ./extract_script_outputs.sh "${log_file}"
        fi
    else
        print_error "Playbook execution failed"
        print_status "Check log file for details: ${log_file}"
        exit 1
    fi
}

# Function to display configuration
show_config() {
    cat << EOF

${BLUE}========================================${NC}
${BLUE}  Self-Service Refresh Test Configuration${NC}
${BLUE}========================================${NC}

${YELLOW}Environment:${NC}
  Source:      ${SOURCE_ENV} (${SOURCE_NS})
  Destination: ${DEST_ENV} (${DEST_NS})
  Customer:    ${CUSTOMER}

${YELLOW}Subscriptions:${NC}
  Source:      ${SOURCE_SUB_ID}
  Destination: ${DEST_SUB_ID}

${YELLOW}Operation:${NC}
  Type:        ${OPERATION}
  Dry Run:     ${DRY_RUN}
  Max Wait:    ${MAX_WAIT} minutes

${YELLOW}Control:${NC}
  Check Only:  ${CHECK_ONLY}
  List Tasks:  ${LIST_TASKS}
  Verbose:     ${VERBOSE:-false}
  Skip Steps:  ${SKIP_STEPS:-none}

${YELLOW}Files:${NC}
  Playbook:    ${PLAYBOOK_DIR}/self_service_refresh.yaml
  Inventory:   ${INVENTORY_DIR}/hosts.ini
  Logs:        ${LOGS_DIR}/

EOF
}

# Main execution
main() {
    print_status "Starting Self-Service Refresh Test"
    
    # Validate required parameters (unless just showing help/usage)
    if [[ "${CHECK_ONLY}" != "true" && "${LIST_TASKS}" != "true" ]]; then
        validate_parameters
    fi
    
    show_config
    
    # Skip ansible checks if validate-only mode
    if [[ "${VALIDATE_ONLY}" != "true" ]]; then
        check_prerequisites
    fi
    
    # Exit early if validate-only mode
    if [[ "${VALIDATE_ONLY}" == "true" ]]; then
        print_success "✅ Parameter validation completed successfully!"
        print_status "Configuration looks good. You can now run without --validate-only"
        exit 0
    fi
    
    # Ask for confirmation if not in dry run or check mode
    if [[ "${DRY_RUN}" != "true" && "${CHECK_ONLY}" != "true" && "${LIST_TASKS}" != "true" ]]; then
        print_warning "You are about to run the playbook in PRODUCTION mode!"
        read -p "Are you sure you want to continue? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            print_status "Operation cancelled by user"
            exit 0
        fi
    fi
    
    run_playbook
    
    print_success "Test completed successfully!"
    
    # Show script output summary 
    if [[ "${SHOW_OUTPUTS_ONLY}" == "true" && -f "${LOG_FILE}" ]]; then
        show_script_outputs_summary
    elif [[ "${DRY_RUN}" == "true" && "${SHOW_OUTPUTS_ONLY}" != "true" && -f "${LOG_FILE}" ]]; then
        show_script_outputs_summary
    fi
}

# Function to show a clean summary of script outputs
show_script_outputs_summary() {
    if [[ ! -f "${LOG_FILE}" ]]; then
        return
    fi
    
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}                                        📊 SCRIPT OUTPUTS SUMMARY                                                   ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Extract script output sections from the log
    local in_script_output=false
    local current_step=""
    local has_outputs=false
    
    while IFS= read -r line; do
        # Look for step headers and extract step information
        if [[ "$line" =~ "self_service_refresh : Step "[0-9]+" - " ]]; then
            current_step=$(echo "$line" | grep -o "Step [0-9]* - [^*]*" | sed 's/\*//g' | xargs)
            in_script_output=false
        elif [[ "$line" =~ "self_service_refresh : Display.*result" ]]; then
            in_script_output=false
        fi
        
        # Look for script output sections (using the actual format from logs)
        if [[ "$line" =~ "📤 STDOUT:" ]]; then
            in_script_output=true
            if [[ -n "$current_step" ]]; then
                echo -e "${CYAN}🔸 ${current_step}${NC}"
                echo "─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
                has_outputs=true
            fi
            continue
        fi
        
        # Look for end of script output section
        if [[ "$line" =~ "📤 STDERR:" ]] || [[ "$line" =~ "Command:" ]] || [[ "$line" =~ "[0m[1m#" ]]; then
            if [[ "$in_script_output" == "true" && "$has_outputs" == "true" ]]; then
                echo ""
            fi
            in_script_output=false
            continue
        fi
        
        # Print script output lines
        if [[ "$in_script_output" == "true" ]] && [[ ! "$line" =~ ^[[:space:]]*$ ]]; then
            # Clean up the line (remove Ansible formatting and leading spaces)
            clean_line=$(echo "$line" | sed 's/\[0;32m//g; s/\[0m//g; s/^[[:space:]]*//g')
            if [[ -n "$clean_line" && "$clean_line" != "(no output)" ]]; then
                echo "  $clean_line"
                has_outputs=true
            fi
        fi
    done < "${LOG_FILE}"
    
    if [[ "$has_outputs" != "true" ]]; then
        echo -e "${YELLOW}ℹ️  No script outputs found in this dry run.${NC}"
        echo "   This might be because:"
        echo "   • PowerShell scripts are missing"
        echo "   • Scripts don't produce output in dry run mode"
        echo "   • Use --verbose for more detailed output"
    fi
    
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Run main function
main "$@"
