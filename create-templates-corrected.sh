#!/bin/bash
# Corrected Semaphore Template Creation Script with proper PowerShell paths
# This script creates templates with correct script paths and flags

set -e  # Exit on any error

# Configuration
SEMAPHORE_URL="http://localhost:3000"
API_TOKEN="pwdjkq1cz3yea0apfjv-_nh-pdluwydeqdmmsxr1oxw="
CONFIG_FILE="/home/kgluza/Manufacturo/semaphore/scripts/self_service_defaults.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
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

# Function to get project resources
get_project_resources() {
    log_info "Getting project resources..."
    
    # Get projects
    PROJECTS_RESPONSE=$(curl -s -w "HTTP_CODE:%{http_code}" \
        -H "Authorization: Bearer $API_TOKEN" \
        "$SEMAPHORE_URL/api/projects")
    
    HTTP_CODE=$(echo "$PROJECTS_RESPONSE" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    PROJECTS_JSON=$(echo "$PROJECTS_RESPONSE" | sed 's/HTTP_CODE:[0-9]*$//')
    
    if [ "$HTTP_CODE" != "200" ]; then
        log_error "Failed to get projects (HTTP: $HTTP_CODE)"
        echo "Response: $PROJECTS_JSON"
        exit 1
    fi
    
    log_success "Projects retrieved successfully"
    
    PROJECT_ID=$(echo "$PROJECTS_JSON" | jq -r '.[0].id')
    if [ "$PROJECT_ID" = "null" ] || [ -z "$PROJECT_ID" ]; then
        log_error "No projects found"
        exit 1
    fi
    
    log_success "Using Project ID: $PROJECT_ID"
    
    # Get repositories
    REPOS_RESPONSE=$(curl -s -w "HTTP_CODE:%{http_code}" \
        -H "Authorization: Bearer $API_TOKEN" \
        "$SEMAPHORE_URL/api/project/$PROJECT_ID/repositories")
    
    HTTP_CODE=$(echo "$REPOS_RESPONSE" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    REPOS_JSON=$(echo "$REPOS_RESPONSE" | sed 's/HTTP_CODE:[0-9]*$//')
    REPO_ID=$(echo "$REPOS_JSON" | jq -r '.[0].id' 2>/dev/null || echo "1")
    
    # Get inventories
    INVENTORY_RESPONSE=$(curl -s -w "HTTP_CODE:%{http_code}" \
        -H "Authorization: Bearer $API_TOKEN" \
        "$SEMAPHORE_URL/api/project/$PROJECT_ID/inventory")
    
    HTTP_CODE=$(echo "$INVENTORY_RESPONSE" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    INVENTORY_JSON=$(echo "$INVENTORY_RESPONSE" | sed 's/HTTP_CODE:[0-9]*$//')
    INVENTORY_ID=$(echo "$INVENTORY_JSON" | jq -r '.[0].id' 2>/dev/null || echo "1")
    
    # Get environments
    ENV_RESPONSE=$(curl -s -w "HTTP_CODE:%{http_code}" \
        -H "Authorization: Bearer $API_TOKEN" \
        "$SEMAPHORE_URL/api/project/$PROJECT_ID/environment")
    
    HTTP_CODE=$(echo "$ENV_RESPONSE" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    ENV_JSON=$(echo "$ENV_RESPONSE" | sed 's/HTTP_CODE:[0-9]*$//')
    ENV_ID=$(echo "$ENV_JSON" | jq -r '.[0].id' 2>/dev/null || echo "1")
    
    # Get views
    VIEWS_RESPONSE=$(curl -s -w "HTTP_CODE:%{http_code}" \
        -H "Authorization: Bearer $API_TOKEN" \
        "$SEMAPHORE_URL/api/project/$PROJECT_ID/views")
    
    HTTP_CODE=$(echo "$VIEWS_RESPONSE" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    VIEWS_JSON=$(echo "$VIEWS_RESPONSE" | sed 's/HTTP_CODE:[0-9]*$//')
    VIEW_ID=$(echo "$VIEWS_JSON" | jq -r '.[0].id' 2>/dev/null || echo "1")
    
    log_info "Resources found:"
    echo "  Repository ID: $REPO_ID"
    echo "  Inventory ID: $INVENTORY_ID"
    echo "  Environment ID: $ENV_ID"
    echo "  View ID: $VIEW_ID"
}

# # Step 1: Create simple empty template
# create_simple_template() {
#     log_info "Step 1: Creating simple empty template..."
    
#     local simple_template='{
#         "name": "Simple Test Template - Corrected",
#         "description": "A simple test template with no parameters",
#         "repository_id": '$REPO_ID',
#         "inventory_id": '$INVENTORY_ID',
#         "environment_id": '$ENV_ID',
#         "view_id": '$VIEW_ID',
#         "playbook": "echo \"Hello from Semaphore!\"",
#         "survey_vars": [],
#         "app": "bash"
#     }'
    
#     local response=$(curl -s -w "HTTP_CODE:%{http_code}" \
#         -H "Authorization: Bearer $API_TOKEN" \
#         -H "Content-Type: application/json" \
#         -X POST \
#         -d "$simple_template" \
#         "$SEMAPHORE_URL/api/project/$PROJECT_ID/templates")
    
#     local http_code=$(echo "$response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
#     local response_body=$(echo "$response" | sed 's/HTTP_CODE:[0-9]*$//')
    
#     if [ "$http_code" = "201" ]; then
#         local template_id=$(echo "$response_body" | jq -r '.id')
#         log_success "Simple template created! (ID: $template_id)"
#         return 0
#     else
#         log_error "Failed to create simple template (HTTP: $http_code)"
#         echo "Response: $response_body"
#         return 1
#     fi
# }

# # Step 2: Create template with parameters
# create_parameter_template() {
#     log_info "Step 2: Creating template with parameters..."
    
#     local parameter_template='{
#         "name": "Parameter Test Template - Corrected",
#         "description": "A template with basic parameters",
#         "repository_id": '$REPO_ID',
#         "inventory_id": '$INVENTORY_ID',
#         "environment_id": '$ENV_ID',
#         "view_id": '$VIEW_ID',
#         "playbook": "echo \"Source: {{ source_env }}\" && echo \"Destination: {{ dest_env }}\"",
#         "survey_vars": [
#             {
#                 "name": "source_env",
#                 "title": "Source Environment",
#                 "description": "Environment to copy data FROM",
#                 "default_value": "gov001",
#                 "required": true
#             },
#             {
#                 "name": "dest_env", 
#                 "title": "Destination Environment",
#                 "description": "Environment to copy data TO",
#                 "default_value": "gov001",
#                 "required": true
#             }
#         ],
#         "app": "bash"
#     }'
    
#     local response=$(curl -s -w "HTTP_CODE:%{http_code}" \
#         -H "Authorization: Bearer $API_TOKEN" \
#         -H "Content-Type: application/json" \
#         -X POST \
#         -d "$parameter_template" \
#         "$SEMAPHORE_URL/api/project/$PROJECT_ID/templates")
    
#     local http_code=$(echo "$response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
#     local response_body=$(echo "$response" | sed 's/HTTP_CODE:[0-9]*$//')
    
#     if [ "$http_code" = "201" ]; then
#         local template_id=$(echo "$response_body" | jq -r '.id')
#         log_success "Parameter template created! (ID: $template_id)"
#         return 0
#     else
#         log_error "Failed to create parameter template (HTTP: $http_code)"
#         echo "Response: $response_body"
#         return 1
#     fi
# }

# Step 3: Create template using configuration file with CORRECTED PowerShell paths
create_config_template() {
    log_info "Step 3: Creating template using configuration file (CORRECTED PATHS)..."
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        return 1
    fi
    
    # Read configuration file
    local config=$(cat "$CONFIG_FILE")
    local defaults=$(echo "$config" | jq -r '.self_service_defaults')
    
    # Extract values from config
    local source_env=$(echo "$defaults" | jq -r '.source')
    local dest_env=$(echo "$defaults" | jq -r '.destination')
    local source_ns=$(echo "$defaults" | jq -r '.source_namespace')
    local dest_ns=$(echo "$defaults" | jq -r '.destination_namespace')
    local customer=$(echo "$defaults" | jq -r '.customer_alias')
    local customer_to_remove=$(echo "$defaults" | jq -r '.customer_alias_to_remove')
    local restore_datetime=$(echo "$defaults" | jq -r '.restore_date_time')
    local timezone=$(echo "$defaults" | jq -r '.timezone')
    local cloud=$(echo "$defaults" | jq -r '.cloud')
    local max_wait=$(echo "$defaults" | jq -r '.max_wait_minutes')
    

    # Create DRY RUN template with ALL parameters visible to users
    local dry_run_template='{
        "name": "Self-Service Data Refresh - DRY RUN (PowerShell) - COMPLETE",
        "description": "Preview what the data refresh would do (SAFE - no changes made)",
        "repository_id": '$REPO_ID',
        "inventory_id": '$INVENTORY_ID',
        "environment_id": '$ENV_ID',
        "view_id": '$VIEW_ID',
        "playbook": "/scripts/main/semaphore_wrapper.ps1",
        "survey_vars": [
            {
                "name": "RestoreDateTime",
                "title": "Restore Date/Time",
                "description": "Point in time to restore to (yyyy-MM-dd HH:mm:ss)",
                "default_value": "'$restore_datetime'",
                "required": true
            },
            {
                "name": "Timezone",
                "title": "Timezone",
                "description": "Timezone for restore datetime",
                "default_value": "'$timezone'",
                "required": true
            },
            {
                "name": "SourceNamespace",
                "title": "Source Namespace",
                "description": "Source namespace (e.g., manufacturo)",
                "default_value": "'$source_ns'",
                "required": true
            },
            {
                "name": "Source",
                "title": "Source Environment",
                "description": "Environment to copy data FROM (e.g., gov001)",
                "default_value": "'$source_env'",
                "required": true
            },
            {
                "name": "DestinationNamespace",
                "title": "Destination Namespace",
                "description": "Destination namespace (e.g., test)",
                "default_value": "'$dest_ns'",
                "required": true
            },
            {
                "name": "Destination",
                "title": "Destination Environment",
                "description": "Environment to copy data TO (e.g., gov001)",
                "default_value": "'$dest_env'",
                "required": true
            },
            {
                "name": "CustomerAlias",
                "title": "Customer Alias",
                "description": "Customer identifier for this refresh",
                "default_value": "'$customer'",
                "required": true
            },
            {
                "name": "CustomerAliasToRemove",
                "title": "Customer Alias To Remove",
                "description": "Customer alias to remove (optional)",
                "default_value": "'$customer_to_remove'",
                "required": false
            },
            {
                "name": "Cloud",
                "title": "Azure Cloud",
                "description": "Azure cloud environment",
                "default_value": "'$cloud'",
                "required": true
            },
            {
                "name": "DryRun",
                "title": "Dry Run Mode",
                "description": "Enable dry run mode (preview only, no changes)",
                "default_value": "true",
                "required": true
            },
            {
                "name": "MaxWaitMinutes",
                "title": "Max Wait Minutes",
                "description": "Maximum minutes to wait for operations",
                "default_value": "'$max_wait'",
                "required": true
            }
        ],
        "app": "powershell"
    }'
    
    local response=$(curl -s -w "HTTP_CODE:%{http_code}" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$dry_run_template" \
        "$SEMAPHORE_URL/api/project/$PROJECT_ID/templates")
    
    local http_code=$(echo "$response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    if [ "$http_code" = "201" ]; then
        local template_id=$(echo "$response_body" | jq -r '.id')
        log_success "DRY RUN template created! (ID: $template_id) with 11 complete parameters"
        log_info "Script path: /scripts/main/semaphore_wrapper.ps1 (All parameters visible to users)"
    else
        log_error "Failed to create DRY RUN template (HTTP: $http_code)"
        echo "Response: $response_body"
        return 1
    fi
    
    # Create PRODUCTION template with ALL parameters visible to users
    local production_template='{
        "name": "Self-Service Data Refresh - PRODUCTION (PowerShell) - COMPLETE",
        "description": "Execute actual data refresh operations (⚠️ PRODUCTION MODE)",
        "repository_id": '$REPO_ID',
        "inventory_id": '$INVENTORY_ID',
        "environment_id": '$ENV_ID',
        "view_id": '$VIEW_ID',
        "playbook": "/scripts/main/semaphore_wrapper.ps1",
        "survey_vars": [
            {
                "name": "RestoreDateTime",
                "title": "Restore Date/Time",
                "description": "Point in time to restore to (yyyy-MM-dd HH:mm:ss)",
                "default_value": "'$restore_datetime'",
                "required": true
            },
            {
                "name": "Timezone",
                "title": "Timezone",
                "description": "Timezone for restore datetime",
                "default_value": "'$timezone'",
                "required": true
            },
            {
                "name": "SourceNamespace",
                "title": "Source Namespace",
                "description": "Source namespace (e.g., manufacturo)",
                "default_value": "'$source_ns'",
                "required": true
            },
            {
                "name": "Source",
                "title": "Source Environment",
                "description": "Environment to copy data FROM (e.g., gov001)",
                "default_value": "'$source_env'",
                "required": true
            },
            {
                "name": "DestinationNamespace",
                "title": "Destination Namespace",
                "description": "Destination namespace (e.g., test)",
                "default_value": "'$dest_ns'",
                "required": true
            },
            {
                "name": "Destination",
                "title": "Destination Environment",
                "description": "Environment to copy data TO (e.g., gov001)",
                "default_value": "'$dest_env'",
                "required": true
            },
            {
                "name": "CustomerAlias",
                "title": "Customer Alias",
                "description": "Customer identifier for this refresh",
                "default_value": "'$customer'",
                "required": true
            },
            {
                "name": "CustomerAliasToRemove",
                "title": "Customer Alias To Remove",
                "description": "Customer alias to remove (optional)",
                "default_value": "'$customer_to_remove'",
                "required": false
            },
            {
                "name": "Cloud",
                "title": "Azure Cloud",
                "description": "Azure cloud environment",
                "default_value": "'$cloud'",
                "required": true
            },
            {
                "name": "DryRun",
                "title": "Dry Run Mode",
                "description": "Enable dry run mode (preview only, no changes)",
                "default_value": "false",
                "required": true
            },
            {
                "name": "MaxWaitMinutes",
                "title": "Max Wait Minutes",
                "description": "Maximum minutes to wait for operations",
                "default_value": "'$max_wait'",
                "required": true
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
    
    local response=$(curl -s -w "HTTP_CODE:%{http_code}" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$production_template" \
        "$SEMAPHORE_URL/api/project/$PROJECT_ID/templates")
    
    local http_code=$(echo "$response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    if [ "$http_code" = "201" ]; then
        local template_id=$(echo "$response_body" | jq -r '.id')
        log_success "PRODUCTION template created! (ID: $template_id) with 12 complete parameters"
        log_info "Script path: /scripts/main/semaphore_wrapper.ps1 (All parameters visible to users)"
        log_success "Both DRY RUN and PRODUCTION templates created successfully!"
        return 0
    else
        log_error "Failed to create PRODUCTION template (HTTP: $http_code)"
        echo "Response: $response_body"
        return 1
    fi
}

# Main execution
main() {
    echo "🚀 Corrected Semaphore Template Creation Script"
    echo "==============================================="
    echo ""
    
    # Get project resources
    get_project_resources
    echo ""
    
    # # Step 1: Simple template
    # if create_simple_template; then
    #     log_success "Step 1 completed successfully!"
    #     echo ""
        
    #     # Step 2: Parameter template
    #     if create_parameter_template; then
    #         log_success "Step 2 completed successfully!"
    #         echo ""
            
    # Step 3: Config file template
    if create_config_template; then
        log_success "Step 3 completed successfully!"
        echo ""
        log_success "🎉 All templates created successfully with COMPLETE parameter set!"
        echo ""
        log_info "Key features:"
        echo "  ✅ Script path: /scripts/main/semaphore_wrapper.ps1 (robust parameter handling)"
        echo "  ✅ All parameters included: 11 for DRY RUN, 12 for PRODUCTION (includes confirmation)"
        echo "  ✅ Full user control: All parameters visible and editable by users"
        echo "  ✅ Default values: Loaded from configuration file for convenience"
        echo "  ✅ Parameter mapping: Robust handling of any parameter order/format"
        echo "  ✅ Type conversion: Proper boolean and integer parameter handling"
    else
        log_error "Step 3 failed - config file template creation failed"
        exit 1
    fi
    #     else
    #         log_error "Step 2 failed - parameter template creation failed"
    #         exit 1
    #     fi
    # else
    #     log_error "Step 1 failed - simple template creation failed"
    #     exit 1
    # fi
}

# Run main function
main "$@"

#             {
#                 "name": "max_wait",
#                 "title": "Max Wait Minutes",
#                 "description": "Maximum minutes to wait for operations",
#                 "default_value": "'$max_wait'",
#                 "required": true
#             }


#             {
#                 "name": "max_wait",
#                 "title": "Max Wait Minutes",
#                 "description": "Maximum minutes to wait for operations",
#                 "default_value": "'$max_wait'",
#                 "required": true
#             },

#                         {
#                 "name": "source_ns",
#                 "title": "Source Namespace",
#                 "description": "Source namespace (e.g., manufacturo)",
#                 "default_value": "'$source_ns'",
#                 "required": true
#             },
#             {
#                 "name": "source_env",
#                 "title": "Source Environment",
#                 "description": "Environment to copy data FROM (e.g., gov001)",
#                 "default_value": "'$source_env'",
#                 "required": true
#             },
#             {
#                 "name": "dest_ns",
#                 "title": "Destination Namespace",
#                 "description": "Destination namespace (e.g., test)",
#                 "default_value": "'$dest_ns'",
#                 "required": true
#             },
#             {
#                 "name": "dest_env",
#                 "title": "Destination Environment",
#                 "description": "Environment to copy data TO (e.g., gov001)",
#                 "default_value": "'$dest_env'",
#                 "required": true
#             },
#             {
#                 "name": "customer",
#                 "title": "Customer Alias",
#                 "description": "Customer identifier for this refresh",
#                 "default_value": "'$customer'",
#                 "required": true
#             },
#             {
#                 "name": "customer_to_remove",
#                 "title": "Customer Alias To Remove",
#                 "description": "Customer alias to remove (optional)",
#                 "default_value": "'$customer_to_remove'",
#                 "required": false
#             },
#             {
#                 "name": "cloud",
#                 "title": "Azure Cloud",
#                 "description": "Azure cloud environment",
#                 "default_value": "'$cloud'",
#                 "required": true
#             },