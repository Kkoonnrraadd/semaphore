#!/bin/bash
# Semaphore Template Creation Script for Self-Service Data Refresh
# Creates project, views, and templates for both full workflow and individual steps

set -e  # Exit on any error

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

SEMAPHORE_URL="http://localhost:3000"
API_TOKEN="YOUR_API_TOKEN_HERE"

# Script path within Semaphore execution environment
# Note: The actual wrapper scripts now dynamically detect the latest repository folder
# This path is just for template registration - the wrapper handles the dynamic resolution
SCRIPT_PATH="/tmp/semaphore/project_1/repository_1_template_1/scripts/main/semaphore_wrapper.ps1"

# Repository configuration
REPOSITORY_NAME="semaphore-scripts"
REPOSITORY_URL="https://github.com/Kkoonnrraadd/semaphore.git"
REPOSITORY_BRANCH="main"

# Project and View names
PROJECT_NAME="SELF-SERVICE-DATA-REFRESH"
VIEW_MAIN="REFRESH"
VIEW_TASKS="STEPS"

# ═══════════════════════════════════════════════════════════════════════════
# COLORS FOR OUTPUT
# ═══════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_section() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Function to make API call with error handling
api_call() {
    local method=$1
    local endpoint=$2
    local data=$3
    
    local response=$(curl -s -w "HTTP_CODE:%{http_code}" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -X "$method" \
        ${data:+-d "$data"} \
        "$SEMAPHORE_URL$endpoint")
    
    local http_code=$(echo "$response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    echo "$http_code|$response_body"
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: CREATE OR GET PROJECT
# ═══════════════════════════════════════════════════════════════════════════

create_or_get_project() {
    log_section "STEP 1: CREATE OR GET PROJECT"
    
    log_info "Checking for existing project '$PROJECT_NAME'..."
    
    # Get all projects
    local result=$(api_call "GET" "/api/projects" "")
    local http_code=$(echo "$result" | cut -d'|' -f1)
    local response=$(echo "$result" | cut -d'|' -f2-)
    
    if [ "$http_code" != "200" ]; then
        log_error "Failed to get projects (HTTP: $http_code)"
        echo "Response: $response"
        exit 1
    fi
    
    # Check if project exists
    PROJECT_ID=$(echo "$response" | jq -r ".[] | select(.name == \"$PROJECT_NAME\") | .id" 2>/dev/null)
    
    if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "null" ]; then
        log_info "Project '$PROJECT_NAME' not found, creating new project..."
        
        local project_data='{
            "name": "'"$PROJECT_NAME"'",
            "alert": false,
            "max_parallel_tasks": 5
        }'
        
        result=$(api_call "POST" "/api/projects" "$project_data")
        http_code=$(echo "$result" | cut -d'|' -f1)
        response=$(echo "$result" | cut -d'|' -f2-)
        
        if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
            PROJECT_ID=$(echo "$response" | jq -r '.id')
            log_success "Project created with ID: $PROJECT_ID"
        else
            log_error "Failed to create project (HTTP: $http_code)"
            echo "Response: $response"
        exit 1
        fi
    else
        log_success "Project '$PROJECT_NAME' found with ID: $PROJECT_ID"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: GET OR CREATE PROJECT RESOURCES
# ═══════════════════════════════════════════════════════════════════════════

get_or_create_resources() {
    log_section "STEP 2: GET OR CREATE PROJECT RESOURCES"
    
    # Get or create repository
    log_info "Getting repositories for project $PROJECT_ID..."
    local result=$(api_call "GET" "/api/project/$PROJECT_ID/repositories" "")
    local http_code=$(echo "$result" | cut -d'|' -f1)
    local response=$(echo "$result" | cut -d'|' -f2-)
    
    REPO_ID=$(echo "$response" | jq -r '.[0].id' 2>/dev/null || echo "")
    
    if [ -z "$REPO_ID" ] || [ "$REPO_ID" = "null" ]; then
        log_info "No repository found, creating new repository..."
        
        # Get SSH key ID (usually "None" type key)
        local key_result=$(api_call "GET" "/api/project/$PROJECT_ID/keys" "")
        local key_id=$(echo "$key_result" | cut -d'|' -f2- | jq -r '[.[] | select(.type == "none")] | .[0].id' 2>/dev/null)
        
        if [ -z "$key_id" ] || [ "$key_id" = "null" ]; then
            log_warning "No 'None' key found, using first available key"
            key_id=$(echo "$key_result" | cut -d'|' -f2- | jq -r '.[0].id' 2>/dev/null || echo "1")
        fi
        
        log_info "Using SSH key ID: $key_id"
        
        local repo_data='{
            "name": "'"$REPOSITORY_NAME"'",
            "project_id": '$PROJECT_ID',
            "git_url": "'"$REPOSITORY_URL"'",
            "git_branch": "'"$REPOSITORY_BRANCH"'",
            "ssh_key_id": '$key_id'
        }'
        result=$(api_call "POST" "/api/project/$PROJECT_ID/repositories" "$repo_data")
        http_code=$(echo "$result" | cut -d'|' -f1)
        response=$(echo "$result" | cut -d'|' -f2-)
        
        if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
            REPO_ID=$(echo "$response" | jq -r '.id')
            log_success "Repository created with ID: $REPO_ID"
        else
            log_error "Failed to create repository (HTTP: $http_code)"
            echo "Response: $response"
            exit 1
        fi
    else
        log_success "Repository ID: $REPO_ID"
    fi
    
    # Get or create inventory
    log_info "Getting inventories for project $PROJECT_ID..."
    result=$(api_call "GET" "/api/project/$PROJECT_ID/inventory" "")
    http_code=$(echo "$result" | cut -d'|' -f1)
    response=$(echo "$result" | cut -d'|' -f2-)
    
    INVENTORY_ID=$(echo "$response" | jq -r '.[0].id' 2>/dev/null || echo "")
    
    if [ -z "$INVENTORY_ID" ] || [ "$INVENTORY_ID" = "null" ]; then
        log_info "No inventory found, creating new inventory..."
        local inventory_data='{
            "name": "localhost",
            "project_id": '$PROJECT_ID',
            "inventory": "localhost ansible_connection=local",
            "type": "static"
        }'
        result=$(api_call "POST" "/api/project/$PROJECT_ID/inventory" "$inventory_data")
        http_code=$(echo "$result" | cut -d'|' -f1)
        response=$(echo "$result" | cut -d'|' -f2-)
        
        if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
            INVENTORY_ID=$(echo "$response" | jq -r '.id')
            log_success "Inventory created with ID: $INVENTORY_ID"
        else
            log_error "Failed to create inventory (HTTP: $http_code)"
            exit 1
        fi
    else
        log_success "Inventory ID: $INVENTORY_ID"
    fi
    
    # Get or create environment
    log_info "Getting environments for project $PROJECT_ID..."
    result=$(api_call "GET" "/api/project/$PROJECT_ID/environment" "")
    http_code=$(echo "$result" | cut -d'|' -f1)
    response=$(echo "$result" | cut -d'|' -f2-)
    
    ENV_ID=$(echo "$response" | jq -r '.[0].id' 2>/dev/null || echo "")
    
    if [ -z "$ENV_ID" ] || [ "$ENV_ID" = "null" ]; then
        log_info "No environment found, creating new environment..."
        local env_data='{
            "name": "Empty",
            "project_id": '$PROJECT_ID',
            "json": "{}"
        }'
        result=$(api_call "POST" "/api/project/$PROJECT_ID/environment" "$env_data")
        http_code=$(echo "$result" | cut -d'|' -f1)
        response=$(echo "$result" | cut -d'|' -f2-)
        
        if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
            ENV_ID=$(echo "$response" | jq -r '.id')
            log_success "Environment created with ID: $ENV_ID"
        else
            log_error "Failed to create environment (HTTP: $http_code)"
            exit 1
        fi
    else
        log_success "Environment ID: $ENV_ID"
    fi
    
    log_info "Resources summary:"
    echo "  Repository ID: $REPO_ID"
    echo "  Inventory ID: $INVENTORY_ID"
    echo "  Environment ID: $ENV_ID"
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: CREATE VIEWS
# ═══════════════════════════════════════════════════════════════════════════

create_views() {
    log_section "STEP 3: CREATE VIEWS"
    
    # Create main view (WIDOK)
    log_info "Creating view '$VIEW_MAIN'..."
    
    local view_main_data='{
        "title": "'"$VIEW_MAIN"'",
        "project_id": '$PROJECT_ID',
        "position": 1
    }'
    
    local result=$(api_call "POST" "/api/project/$PROJECT_ID/views" "$view_main_data")
    local http_code=$(echo "$result" | cut -d'|' -f1)
    local response=$(echo "$result" | cut -d'|' -f2-)
    
    if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
        VIEW_MAIN_ID=$(echo "$response" | jq -r '.id')
        log_success "View '$VIEW_MAIN' created with ID: $VIEW_MAIN_ID"
    else
        log_error "Failed to create view '$VIEW_MAIN' (HTTP: $http_code)"
        echo "Response: $response"
        exit 1
    fi
    
    # Create tasks view (TASKI)
    log_info "Creating view '$VIEW_TASKS'..."
    
    local view_tasks_data='{
        "title": "'"$VIEW_TASKS"'",
        "project_id": '$PROJECT_ID',
        "position": 2
    }'
    
    result=$(api_call "POST" "/api/project/$PROJECT_ID/views" "$view_tasks_data")
    http_code=$(echo "$result" | cut -d'|' -f1)
    response=$(echo "$result" | cut -d'|' -f2-)
    
    if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
        VIEW_TASKS_ID=$(echo "$response" | jq -r '.id')
        log_success "View '$VIEW_TASKS' created with ID: $VIEW_TASKS_ID"
    else
        log_error "Failed to create view '$VIEW_TASKS' (HTTP: $http_code)"
        echo "Response: $response"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: CREATE MAIN TEMPLATES (DRY RUN & PRODUCTION)
# ═══════════════════════════════════════════════════════════════════════════

create_main_templates() {
    log_section "STEP 4: CREATE MAIN WORKFLOW TEMPLATES"
    
    # Template 1: DRY RUN
    log_info "Creating DRY RUN template..."
    
    local dry_run_template='{
        "name": "Self-Service Data Refresh - DRY RUN",
        "description": "Preview what the data refresh would do (SAFE - no changes made). All parameters are OPTIONAL - the script auto-detects missing values from Azure. Defaults: Source=Destination, SourceNamespace='\''manufacturo'\'', DestinationNamespace='\''test'\''",
        "repository_id": '$REPO_ID',
        "inventory_id": '$INVENTORY_ID',
        "environment_id": '$ENV_ID',
        "view_id": '$VIEW_MAIN_ID',
        "playbook": "'"$SCRIPT_PATH"'",
        "survey_vars": [
            {
                "name": "RestoreDateTime",
                "title": "Restore Date/Time",
                "description": "Point in time to restore to (yyyy-MM-dd HH:mm:ss). Leave empty for 10 minutes ago. Script auto-detects if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "Timezone",
                "title": "Timezone",
                "description": "Timezone for restore datetime (e.g., Europe/Warsaw or America/New_York). Script uses system timezone if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "SourceNamespace",
                "title": "Source Namespace",
                "description": "Source namespace. Script auto-detects as '\''manufacturo'\'' if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "Source",
                "title": "Source Environment",
                "description": "Environment to copy data FROM (e.g., gov001). Script auto-detects from Azure if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "DestinationNamespace",
                "title": "Destination Namespace",
                "description": "Destination namespace. Script auto-detects as '\''test'\'' if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "Destination",
                "title": "Destination Environment",
                "description": "Environment to copy data TO (e.g., gov001). Script defaults to same as Source if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "InstanceAlias",
                "title": "Instance Alias",
                "description": "Instance identifier for the refreshed instance. Script uses INSTANCE_ALIAS environment variable if empty.",
                "default_value": "destination",
                "required": true
            },
            {
                "name": "InstanceAliasToRemove",
                "title": "Instance Alias To Remove",
                "description": "Instance Alias to remove during cleanup. Script uses INSTANCE_ALIAS_TO_REMOVE environment variable if empty.",
                "default_value": "source",
                "required": false
            },
            {
                "name": "Cloud",
                "title": "Azure Cloud",
                "description": "Azure cloud environment (AzureCloud or AzureUSGovernment). Script auto-detects if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "DryRun",
                "title": "Dry Run Mode",
                "description": "Enable dry run mode (preview only, no changes). FIXED to true for this template.",
                "default_value": "true",
                "required": false
            },
            {
                "name": "MaxWaitMinutes",
                "title": "Max Wait Minutes",
                "description": "Maximum minutes to wait for operations. Default: 60",
                "default_value": "",
                "required": false
            },
            {
                "name": "UseSasTokens",
                "title": "Use SAS Tokens",
                "description": "Use SAS tokens for large containers in storage account (true/false). Default: false",
                "default_value": "false",
                "required": false
            }
        ],
        "app": "powershell"
    }'
    
    local result=$(api_call "POST" "/api/project/$PROJECT_ID/templates" "$dry_run_template")
    local http_code=$(echo "$result" | cut -d'|' -f1)
    local response=$(echo "$result" | cut -d'|' -f2-)
    
    if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
        local template_id=$(echo "$response" | jq -r '.id')
        log_success "DRY RUN template created! (ID: $template_id)"
    else
        log_error "Failed to create DRY RUN template (HTTP: $http_code)"
        echo "Response: $response"
        return 1
    fi
    
    # Template 2: PRODUCTION
    log_info "Creating PRODUCTION template..."
    
    local production_template='{
        "name": "Self-Service Data Refresh - PRODUCTION",
        "description": "⚠️ PRODUCTION MODE - Execute actual data refresh operations. All parameters are OPTIONAL - the script auto-detects missing values from Azure. Defaults: Source=Destination, SourceNamespace='\''manufacturo'\'', DestinationNamespace='\''test'\''",
        "repository_id": '$REPO_ID',
        "inventory_id": '$INVENTORY_ID',
        "environment_id": '$ENV_ID',
        "view_id": '$VIEW_MAIN_ID',
        "playbook": "'"$SCRIPT_PATH"'",
        "survey_vars": [
            {
                "name": "RestoreDateTime",
                "title": "Restore Date/Time",
                "description": "Point in time to restore to (yyyy-MM-dd HH:mm:ss). Leave empty for 15 minutes ago. Script auto-detects if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "Timezone",
                "title": "Timezone",
                "description": "Timezone for restore datetime (e.g., Eastern Standard Time). Script uses system timezone if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "SourceNamespace",
                "title": "Source Namespace",
                "description": "Source namespace. Script auto-detects as '\''manufacturo'\'' if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "Source",
                "title": "Source Environment",
                "description": "Environment to copy data FROM (e.g., gov001). Script auto-detects from Azure if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "DestinationNamespace",
                "title": "Destination Namespace",
                "description": "Destination namespace. Script auto-detects as '\''test'\'' if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "Destination",
                "title": "Destination Environment",
                "description": "Environment to copy data TO (e.g., gov001). Script defaults to same as Source if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "InstanceAlias",
                "title": "Instance Alias",
                "description": "Instance identifier. Script uses INSTANCE_ALIAS environment variable if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "InstanceAliasToRemove",
                "title": "Instance Alias To Remove",
                "description": "Instance Alias to remove during cleanup. Script auto-calculates from InstanceAlias if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "Cloud",
                "title": "Azure Cloud",
                "description": "Azure cloud environment (AzureCloud or AzureUSGovernment). Script auto-detects if empty.",
                "default_value": "",
                "required": false
            },
            {
                "name": "DryRun",
                "title": "Dry Run Mode",
                "description": "Enable dry run mode (preview only, no changes). Set to false for PRODUCTION execution.",
                "default_value": "false",
                "required": false
            },
            {
                "name": "MaxWaitMinutes",
                "title": "Max Wait Minutes",
                "description": "Maximum minutes to wait for operations. Default: 60",
                "default_value": "",
                "required": false
            },
            {
                "name": "production_confirm",
                "title": "⚠️ PRODUCTION CONFIRMATION",
                "description": "Type CONFIRM to proceed with production changes",
                "default_value": "",
                "required": true
            }
        ],
        "app": "powershell"
    }'
    
    result=$(api_call "POST" "/api/project/$PROJECT_ID/templates" "$production_template")
    http_code=$(echo "$result" | cut -d'|' -f1)
    response=$(echo "$result" | cut -d'|' -f2-)
    
    if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
        local template_id=$(echo "$response" | jq -r '.id')
        log_success "PRODUCTION template created! (ID: $template_id)"
    else
        log_error "Failed to create PRODUCTION template (HTTP: $http_code)"
        echo "Response: $response"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5: CREATE INDIVIDUAL TASK TEMPLATES
# ═══════════════════════════════════════════════════════════════════════════

create_task_templates() {
    log_section "STEP 5: CREATE INDIVIDUAL TASK TEMPLATES"
    
    log_info "Creating Step 0 utility tasks (permissions and authentication)..."
    
    # Step 0A: Grant Permissions (FIRST - before authentication)
    log_info "Creating Step 0A: Grant Permissions..."
    create_template "Step 0A: Grant Permissions" \
        "Grant Azure permissions to SelfServiceRefresh service account (required before authentication)" \
        "permissions/Invoke-AzureFunctionPermission.ps1" \
        '[
            {"name":"Action","title":"Action","description":"Permission action","default_value":"Grant","required":true},
            {"name":"Environment","title":"Environment (OPTIONAL)","description":"Target environment. Auto-detected from Source or ENVIRONMENT env var","default_value":"","required":false},
            {"name":"ServiceAccount","title":"Service Account","description":"Service account name","default_value":"SelfServiceRefresh","required":true},
            {"name":"TimeoutSeconds","title":"Timeout Seconds","description":"API timeout in seconds","default_value":"60","required":false},
            {"name":"WaitForPropagation","title":"Wait For Propagation","description":"Wait time for permissions to propagate (seconds)","default_value":"30","required":false}
        ]'
    
    # Step 0B: Connect to Azure (AFTER permissions)
    log_info "Creating Step 0B: Connect to Azure..."
    create_template "Step 0B: Connect to Azure" \
        "Authenticate to Azure using Service Principal (after permissions are granted)" \
        "common/Connect-Azure.ps1" \
        '[
            {"name":"Cloud","title":"Azure Cloud (OPTIONAL)","description":"Azure cloud environment (AzureCloud or AzureUSGovernment). Auto-detected if empty","default_value":"","required":false}
        ]'
    
    # Step 0C: Auto-Detect Parameters (AFTER authentication)
    log_info "Creating Step 0C: Auto-Detect Parameters..."
    create_template "Step 0C: Auto-Detect Parameters" \
        "Automatically detect missing parameters from Azure subscription (requires authentication)" \
        "common/Get-AzureParameters.ps1" \
        '[
            {"name":"Source","title":"Source Environment (OPTIONAL)","description":"Source environment. Will auto-detect from Azure if empty","default_value":"","required":false},
            {"name":"Destination","title":"Destination Environment (OPTIONAL)","description":"Destination environment. Defaults to Source if empty","default_value":"","required":false},
            {"name":"SourceNamespace","title":"Source Namespace (OPTIONAL)","description":"Source namespace. Auto: '\''manufacturo'\''","default_value":"","required":false},
            {"name":"DestinationNamespace","title":"Destination Namespace (OPTIONAL)","description":"Destination namespace. Auto: '\''test'\''","default_value":"","required":false}
        ]'
    
    log_info "Creating main workflow tasks (Steps 1-12)..."
    
    # Task 1: Restore Point in Time
    log_info "Creating Task 1: Restore Point in Time..."
    create_template "Task 1: Restore Point in Time" \
        "Restore databases to a specific point in time. Parameters: RestoreDateTime, Timezone, Source, SourceNamespace, MaxWaitMinutes (all OPTIONAL - script auto-detects)" \
        "restore/RestorePointInTime.ps1" \
        '[
            {"name":"RestoreDateTime","title":"Restore Date/Time (OPTIONAL)","description":"Point in time to restore (yyyy-MM-dd HH:mm:ss). Auto: 15 min ago","default_value":"","required":false},
            {"name":"Timezone","title":"Timezone (OPTIONAL)","description":"Timezone for restore. Auto: system timezone","default_value":"","required":false},
            {"name":"Source","title":"Source Environment (OPTIONAL)","description":"Source environment. Auto-detected from Azure","default_value":"","required":false},
            {"name":"SourceNamespace","title":"Source Namespace (OPTIONAL)","description":"Source namespace. Auto: '\''manufacturo'\''","default_value":"","required":false},
            {"name":"MaxWaitMinutes","title":"Max Wait Minutes (OPTIONAL)","description":"Maximum wait time. Default: 60","default_value":"","required":false},
            {"name":"DryRun","title":"Dry Run Mode","description":"Preview only (true/false)","default_value":"true","required":true}
        ]'
    
    # Task 2: Stop Environment
    log_info "Creating Task 2: Stop Environment..."
    create_template "Task 2: Stop Environment" \
        "Stop the destination environment (AKS cluster, monitoring). Parameters: Destination, DestinationNamespace, Cloud (all OPTIONAL - script auto-detects)" \
        "environment/StopEnvironment.ps1" \
        '[
            {"name":"Destination","title":"Destination Environment (OPTIONAL)","description":"Environment to stop. Auto-detected from Azure","default_value":"","required":false},
            {"name":"DestinationNamespace","title":"Destination Namespace (OPTIONAL)","description":"Namespace. Auto: '\''test'\''","default_value":"","required":false},
            {"name":"Cloud","title":"Azure Cloud (OPTIONAL)","description":"Azure cloud. Auto-detected","default_value":"","required":false},
            {"name":"DryRun","title":"Dry Run Mode","description":"Preview only (true/false)","default_value":"true","required":true}
        ]'
    
    # Task 3: Copy Attachments
    log_info "Creating Task 3: Copy Attachments..."
    create_template "Task 3: Copy Attachments" \
        "Copy attachments from source to destination storage. Use SAS tokens for 3TB+ containers. Parameters: Source, Destination, SourceNamespace, DestinationNamespace (all OPTIONAL)" \
        "storage/CopyAttachments.ps1" \
        '[
            {"name":"Source","title":"Source Environment (OPTIONAL)","description":"Source environment. Auto-detected","default_value":"","required":false},
            {"name":"Destination","title":"Destination Environment (OPTIONAL)","description":"Destination environment. Auto: same as Source","default_value":"","required":false},
            {"name":"SourceNamespace","title":"Source Namespace (OPTIONAL)","description":"Source namespace. Auto: '\''manufacturo'\''","default_value":"","required":false},
            {"name":"DestinationNamespace","title":"Destination Namespace (OPTIONAL)","description":"Destination namespace. Auto: '\''test'\''","default_value":"","required":false},
            {"name":"UseSasTokens","title":"Use SAS Tokens (OPTIONAL)","description":"Use SAS tokens for large 3TB+ containers (true/false)","default_value":"false","required":false},
            {"name":"DryRun","title":"Dry Run Mode","description":"Preview only (true/false)","default_value":"true","required":true}
        ]'
    
    # Task 4: Copy Database
    log_info "Creating Task 4: Copy Database..."
    create_template "Task 4: Copy Database" \
        "Copy database from source to destination. Parameters: Source, Destination, SourceNamespace, DestinationNamespace (all OPTIONAL)" \
        "database/copy_database.ps1" \
        '[
            {"name":"Source","title":"Source Environment (OPTIONAL)","description":"Source environment. Auto-detected","default_value":"","required":false},
            {"name":"Destination","title":"Destination Environment (OPTIONAL)","description":"Destination environment. Auto: same as Source","default_value":"","required":false},
            {"name":"SourceNamespace","title":"Source Namespace (OPTIONAL)","description":"Source namespace. Auto: '\''manufacturo'\''","default_value":"","required":false},
            {"name":"DestinationNamespace","title":"Destination Namespace (OPTIONAL)","description":"Destination namespace. Auto: '\''test'\''","default_value":"","required":false},
            {"name":"DryRun","title":"Dry Run Mode","description":"Preview only (true/false)","default_value":"true","required":true}
        ]'
    
    # Task 5: Cleanup Environment Configuration
    log_info "Creating Task 5: Cleanup Environment Configuration..."
    create_template "Task 5: Cleanup Environment Configuration" \
        "Clean up source environment configurations (CORS, redirect URIs). Parameters: Destination, EnvironmentToClean, MultitenantToRemove, InstanceAliasToRemove, Domain, DestinationNamespace (OPTIONAL)" \
        "configuration/cleanup_environment_config.ps1" \
        '[
            {"name":"Destination","title":"Destination Environment (OPTIONAL)","description":"Destination environment. Auto-detected","default_value":"","required":false},
            {"name":"EnvironmentToClean","title":"Environment To Clean (OPTIONAL)","description":"Source environment to clean. Auto: same as Source","default_value":"","required":false},
            {"name":"MultitenantToRemove","title":"Multitenant To Remove (OPTIONAL)","description":"Namespace to remove. Auto: '\''manufacturo'\''","default_value":"","required":false},
            {"name":"InstanceAliasToRemove","title":"Instance Alias To Remove (OPTIONAL)","description":"Instance Alias to remove. Auto-calculated","default_value":"","required":false},
            {"name":"Domain","title":"Domain (OPTIONAL)","description":"Domain (cloud/us). Auto-detected from Cloud","default_value":"","required":false},
            {"name":"DestinationNamespace","title":"Destination Namespace (OPTIONAL)","description":"Destination namespace. Auto: '\''test'\''","default_value":"","required":false},
            {"name":"DryRun","title":"Dry Run Mode","description":"Preview only (true/false)","default_value":"true","required":true}
        ]'
    
    # Task 6: Revert SQL Users
    log_info "Creating Task 6: Revert SQL Users..."
    create_template "Task 6: Revert SQL Users" \
        "Revert source environment SQL users and roles. Parameters: Destination, DestinationNamespace, EnvironmentToRevert, MultitenantToRevert (OPTIONAL)" \
        "configuration/sql_configure_users.ps1" \
        '[
            {"name":"Destination","title":"Destination Environment (OPTIONAL)","description":"Destination environment. Auto-detected","default_value":"","required":false},
            {"name":"DestinationNamespace","title":"Destination Namespace (OPTIONAL)","description":"Destination namespace. Auto: '\''test'\''","default_value":"","required":false},
            {"name":"EnvironmentToRevert","title":"Environment To Revert (OPTIONAL)","description":"Source environment to revert. Auto: same as Source","default_value":"","required":false},
            {"name":"MultitenantToRevert","title":"Multitenant To Revert (OPTIONAL)","description":"Namespace to revert. Auto: '\''manufacturo'\''","default_value":"","required":false},
            {"name":"Revert","title":"Revert Mode","description":"Enable revert mode","default_value":"true","required":true},
            {"name":"AutoApprove","title":"Auto Approve","description":"Auto approve changes","default_value":"true","required":true},
            {"name":"StopOnFailure","title":"Stop On Failure","description":"Stop on first failure","default_value":"true","required":true},
            {"name":"DryRun","title":"Dry Run Mode","description":"Preview only (true/false)","default_value":"true","required":true}
        ]'
    
    # Task 7: Adjust Resources
    log_info "Creating Task 7: Adjust Resources..."
    create_template "Task 7: Adjust Database Resources" \
        "Adjust database resources and configurations. Parameters: Domain, InstanceAlias, Destination, DestinationNamespace (OPTIONAL)" \
        "configuration/adjust_db.ps1" \
        '[
            {"name":"Domain","title":"Domain (OPTIONAL)","description":"Domain (cloud/us). Auto-detected from Cloud","default_value":"","required":false},
            {"name":"InstanceAlias","title":"Instance Alias (OPTIONAL)","description":"Instance identifier. Auto: INSTANCE_ALIAS env var","default_value":"","required":false},
            {"name":"Destination","title":"Destination Environment (OPTIONAL)","description":"Destination environment. Auto-detected","default_value":"","required":false},
            {"name":"DestinationNamespace","title":"Destination Namespace (OPTIONAL)","description":"Destination namespace. Auto: '\''test'\''","default_value":"","required":false},
            {"name":"DryRun","title":"Dry Run Mode","description":"Preview only (true/false)","default_value":"true","required":true}
        ]'
    
    # Task 8: Delete Replicas
    log_info "Creating Task 8: Delete Replicas..."
    create_template "Task 8: Delete and Recreate Replicas" \
        "Delete and recreate replica databases. Parameters: Destination, Source, SourceNamespace, DestinationNamespace (OPTIONAL)" \
        "replicas/delete_replicas.ps1" \
        '[
            {"name":"Destination","title":"Destination Environment (OPTIONAL)","description":"Destination environment. Auto-detected","default_value":"","required":false},
            {"name":"Source","title":"Source Environment (OPTIONAL)","description":"Source environment. Auto-detected","default_value":"","required":false},
            {"name":"SourceNamespace","title":"Source Namespace (OPTIONAL)","description":"Source namespace. Auto: '\''manufacturo'\''","default_value":"","required":false},
            {"name":"DestinationNamespace","title":"Destination Namespace (OPTIONAL)","description":"Destination namespace. Auto: '\''test'\''","default_value":"","required":false},
            {"name":"DryRun","title":"Dry Run Mode","description":"Preview only (true/false)","default_value":"true","required":true}
        ]'
    
    # Task 9: Configure Users
    log_info "Creating Task 9: Configure SQL Users..."
    create_template "Task 9: Configure SQL Users" \
        "Configure SQL users and permissions. Parameters: Destination, DestinationNamespace (OPTIONAL)" \
        "configuration/sql_configure_users.ps1" \
        '[
            {"name":"Destination","title":"Destination Environment (OPTIONAL)","description":"Destination environment. Auto-detected","default_value":"","required":false},
            {"name":"DestinationNamespace","title":"Destination Namespace (OPTIONAL)","description":"Destination namespace. Auto: '\''test'\''","default_value":"","required":false},
            {"name":"AutoApprove","title":"Auto Approve","description":"Auto approve changes","default_value":"true","required":true},
            {"name":"StopOnFailure","title":"Stop On Failure","description":"Stop on first failure","default_value":"true","required":true},
            {"name":"BaselinesMode","title":"Baselines Mode","description":"Baselines mode (Off for production)","default_value":"Off","required":false},
            {"name":"DryRun","title":"Dry Run Mode","description":"Preview only (true/false)","default_value":"true","required":true}
        ]'
    
    # Task 10: Start Environment
    log_info "Creating Task 10: Start Environment..."
    create_template "Task 10: Start Environment" \
        "Start the destination environment (AKS cluster, monitoring). Parameters: Destination, DestinationNamespace (OPTIONAL)" \
        "environment/StartEnvironment.ps1" \
        '[
            {"name":"Destination","title":"Destination Environment (OPTIONAL)","description":"Destination environment. Auto-detected","default_value":"","required":false},
            {"name":"DestinationNamespace","title":"Destination Namespace (OPTIONAL)","description":"Destination namespace. Auto: '\''test'\''","default_value":"","required":false},
            {"name":"DryRun","title":"Dry Run Mode","description":"Preview only (true/false)","default_value":"true","required":true}
        ]'
    
    # Task 11: Cleanup
    log_info "Creating Task 11: Cleanup Restored Databases..."
    create_template "Task 11: Cleanup Restored Databases" \
        "Delete temporary restored databases with '-restored' suffix. Parameters: Source (OPTIONAL)" \
        "database/delete_restored_db.ps1" \
        '[
            {"name":"Source","title":"Source Environment (OPTIONAL)","description":"Source environment. Auto-detected from Azure","default_value":"","required":false},
            {"name":"DryRun","title":"Dry Run Mode","description":"Preview only (true/false)","default_value":"true","required":true}
        ]'
    
    # Task 12: Remove Permissions
    log_info "Creating Task 12: Remove Permissions..."
    create_template "Task 12: Remove Permissions" \
        "Remove permissions from SelfServiceRefresh service account. Parameters: Source (OPTIONAL)" \
        "permissions/Invoke-AzureFunctionPermission.ps1" \
        '[
            {"name":"Source","title":"Source Environment (OPTIONAL)","description":"Source environment. Auto-detected from Azure","default_value":"","required":false},
            {"name":"Action","title":"Action","description":"Permission action (Remove)","default_value":"Remove","required":true},
            {"name":"ServiceAccount","title":"Service Account","description":"Service account name","default_value":"SelfServiceRefresh","required":true},
            {"name":"TimeoutSeconds","title":"Timeout Seconds","description":"API timeout in seconds","default_value":"60","required":false},
            {"name":"WaitForPropagation","title":"Wait For Propagation","description":"Wait time for permissions to propagate","default_value":"30","required":false}
        ]'
}

# Helper function to create a template
create_template() {
    local name=$1
    local description=$2
    local script_path=$3
    local survey_vars=$4
    
    # Use universal step wrapper path
    local full_path="/tmp/semaphore/project_1/repository_1_template_1/scripts/step_wrappers/invoke_step.ps1"
    
    # Add ScriptPath as first survey variable (hidden from user, pre-filled)
    local wrapper_survey_vars=$(echo "$survey_vars" | jq --arg path "$script_path" '. = [{"name":"ScriptPath","title":"📁 Script (auto-configured)","description":"✓ Pre-configured script path - no need to modify","default_value":$path,"required":true,"type":"string"}] + .')
    
    local template_data=$(cat <<EOF
{
    "name": "$name",
    "description": "$description",
    "repository_id": $REPO_ID,
    "inventory_id": $INVENTORY_ID,
    "environment_id": $ENV_ID,
    "view_id": $VIEW_TASKS_ID,
    "playbook": "$full_path",
    "survey_vars": $wrapper_survey_vars,
    "app": "powershell"
}
EOF
)
    
    local result=$(api_call "POST" "/api/project/$PROJECT_ID/templates" "$template_data")
    local http_code=$(echo "$result" | cut -d'|' -f1)
    local response=$(echo "$result" | cut -d'|' -f2-)
    
    if [ "$http_code" = "201" ] || [ "$http_code" = "200" ]; then
        local template_id=$(echo "$response" | jq -r '.id')
        log_success "Template created: $name (ID: $template_id)"
        return 0
    else
        log_error "Failed to create template: $name (HTTP: $http_code)"
        echo "Response: $response"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════════════

main() {
    echo ""
    log_section "🚀 SEMAPHORE TEMPLATE CREATION SCRIPT"
    
    log_info "Configuration:"
    echo "  Semaphore URL: $SEMAPHORE_URL"
    echo "  Script Path: $SCRIPT_PATH"
    echo "  Project Name: $PROJECT_NAME"
    echo "  Main View: $VIEW_MAIN"
    echo "  Tasks View: $VIEW_TASKS"
    echo ""
    
    # Execute all steps
    create_or_get_project
    get_or_create_resources
    create_views
    create_main_templates
    # create_task_templates - disabled for now due to refactor 
    
    # Final summary
    log_section "🎉 SETUP COMPLETE"
    
    log_success "All templates created successfully!"
        echo ""
    log_info "Summary:"
    echo "  📁 Project: $PROJECT_NAME (ID: $PROJECT_ID)"
    echo "  📋 View '$VIEW_MAIN': Contains 2 main workflow templates"
    echo "     • Self-Service Data Refresh - DRY RUN"
    echo "     • Self-Service Data Refresh - PRODUCTION"
    echo "  📋 View '$VIEW_TASKS': Contains 15 individual task templates"
    echo "     🔧 Step 0: Utilities (permissions & authentication)"
    echo "        • Step 0A: Grant Permissions"
    echo "        • Step 0B: Connect to Azure"
    echo "        • Step 0C: Auto-Detect Parameters"
    echo "     ⚙️  Steps 1-12: Main workflow"
    echo "        • Task 1: Restore Point in Time"
    echo "        • Task 2: Stop Environment"
    echo "        • Task 3: Copy Attachments"
    echo "        • Task 4: Copy Database"
    echo "        • Task 5: Cleanup Environment Configuration"
    echo "        • Task 6: Revert SQL Users"
    echo "        • Task 7: Adjust Database Resources"
    echo "        • Task 8: Delete and Recreate Replicas"
    echo "        • Task 9: Configure SQL Users"
    echo "        • Task 10: Start Environment"
    echo "        • Task 11: Cleanup Restored Databases"
    echo "        • Task 12: Remove Permissions"
        echo ""
        log_info "Key features:"
    echo "  ✅ All parameters are OPTIONAL - script auto-detects from Azure"
    echo "  ✅ Default values: Source=Destination, SourceNamespace='manufacturo', DestinationNamespace='test'"
    echo "  ✅ Script path: $SCRIPT_PATH"
    echo "  ✅ Robust parameter handling via semaphore_wrapper.ps1"
    echo ""
    log_success "You can now use these templates in Semaphore UI!"
    echo ""
}

# Run main function
main "$@"
