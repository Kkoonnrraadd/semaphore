#!/bin/bash

# Simple Self-Service Test Script
# This focuses on the actual workflow you need: scheduled execution with dry-run preview

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Usage function
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Simple Self-Service Data Refresh for Semaphore

REQUIRED OPTIONS:
    -s, --source ENV        Source environment (e.g., qa2)
    -d, --dest ENV          Destination environment (e.g., dev)
    --source-sub-id ID      Source subscription ID
    --dest-sub-id ID        Destination subscription ID
    --source-ns NS          Source namespace (e.g., manufacturo)
    --dest-ns NS            Destination namespace (e.g., test)
    -c, --customer ALIAS    Customer alias

OPTIONAL:
    --dry-run              Preview mode - see what would happen
    --skip-steps STEPS     Skip steps (comma-separated: restore,stop,copy_attachments,etc.)
    --max-wait MINUTES     Max wait time (default: 40)
    --cloud CLOUD          Azure cloud (default: AzureUSGovernment)
    --verbose              Verbose output
    -h, --help             Show this help

EXAMPLES:
    # Dry run preview (RECOMMENDED FIRST)
    $0 -s qa2 -d dev --source-sub-id xxx --dest-sub-id yyy \\
       --source-ns manufacturo --dest-ns test -c qa2-services --dry-run

    # Production execution
    $0 -s qa2 -d dev --source-sub-id xxx --dest-sub-id yyy \\
       --source-ns manufacturo --dest-ns test -c qa2-services

    # Skip certain steps
    $0 -s qa2 -d dev --source-sub-id xxx --dest-sub-id yyy \\
       --source-ns manufacturo --dest-ns test -c qa2-services \\
       --skip-steps restore,stop --dry-run

EOF
}

# Default values
SOURCE_ENV=""
DEST_ENV=""
SOURCE_SUB_ID=""
DEST_SUB_ID=""
SOURCE_NS=""
DEST_NS=""
CUSTOMER=""
DRY_RUN="false"
SKIP_STEPS=""
MAX_WAIT="40"
CLOUD="AzureUSGovernment"
VERBOSE=""

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
        -c|--customer)
            CUSTOMER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --skip-steps)
            SKIP_STEPS="$2"
            shift 2
            ;;
        --max-wait)
            MAX_WAIT="$2"
            shift 2
            ;;
        --cloud)
            CLOUD="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE="-vvv"
            shift
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

# Validate required parameters
missing_params=()
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
    show_usage
    exit 1
fi

# Display configuration
print_status "Self-Service Data Refresh Configuration"
echo "======================================"
echo "Source:      $SOURCE_ENV ($SOURCE_NS)"
echo "Destination: $DEST_ENV ($DEST_NS)"
echo "Customer:    $CUSTOMER"
echo "Cloud:       $CLOUD"
echo "Dry Run:     $DRY_RUN"
echo "Max Wait:    $MAX_WAIT minutes"
echo "Skip Steps:  ${SKIP_STEPS:-none}"
echo

# Build extra vars
extra_vars="source_env=$SOURCE_ENV dest_env=$DEST_ENV"
extra_vars="$extra_vars source_sub_id=$SOURCE_SUB_ID dest_sub_id=$DEST_SUB_ID"
extra_vars="$extra_vars source_ns=$SOURCE_NS dest_ns=$DEST_NS"
extra_vars="$extra_vars customer=$CUSTOMER cloud=$CLOUD"
extra_vars="$extra_vars dry_run_mode=$DRY_RUN max_wait=$MAX_WAIT"

if [[ -n "$SKIP_STEPS" ]]; then
    extra_vars="$extra_vars skip_steps=[$SKIP_STEPS]"
fi

# Check if ansible-playbook is available
if ! command -v ansible-playbook &> /dev/null; then
    print_warning "ansible-playbook is not available in this environment"
    print_status "This script is designed for Semaphore environments with Ansible installed"
    print_status ""
    print_status "📋 In Semaphore, this would execute:"
    print_status "ansible-playbook playbooks/simple_self_service.yaml -i inventory/hosts.ini --extra-vars \"$extra_vars\" $VERBOSE"
    print_status ""
    print_status "🎯 The playbook would run these PowerShell scripts in order:"
    print_status "1. Step 0: Create restore point (RestorePointInTime.ps1)"
    print_status "2. Step 1: Stop destination environment (StopEnvironment.ps1)"
    print_status "3. Step 2a: Copy attachments (CopyAttachments.ps1)"
    print_status "4. Step 2b: Copy database (copy_database.ps1)"
    print_status "5. Step 3: Adjust resources (AdjustResources.ps1)"
    print_status "6. Step 6: Start environment (StartEnvironment.ps1)"
    print_status "7. Step 7: Delete temporary resources (DeleteResources.ps1)"
    print_status "8. Step 8: Manage permissions (ManagePermissions.ps1)"
    print_status ""
    print_success "Configuration validated successfully for Semaphore deployment!"
    exit 0
fi

# Run the playbook
print_status "Executing self-service refresh..."
ansible-playbook playbooks/simple_self_service.yaml \
    -i inventory/hosts.ini \
    --extra-vars "$extra_vars" \
    $VERBOSE

print_success "Execution completed!"
