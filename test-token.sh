#!/bin/bash
# Test Semaphore API with your token

SEMAPHORE_URL="http://localhost:3000"
API_TOKEN="="

echo "🚀 Testing Semaphore API with your token"
echo "========================================"

# Test token authentication
echo "🔐 Testing token authentication..."
PROJECTS=$(curl -s -H "Authorization: Bearer $API_TOKEN" "$SEMAPHORE_URL/api/projects")

if echo "$PROJECTS" | grep -q "id"; then
    echo "✅ Token authentication successful!"
    echo "📋 Your projects:"
    echo "$PROJECTS" | jq -r '.[] | "  ID: \(.id) - Name: \(.name)"' 2>/dev/null || echo "$PROJECTS"
else
    echo "❌ Token authentication failed"
    echo "Response: $PROJECTS"
    exit 1
fi

# Get first project ID for template creation
PROJECT_ID=$(echo "$PROJECTS" | jq -r '.[0].id' 2>/dev/null)
if [ "$PROJECT_ID" != "null" ] && [ -n "$PROJECT_ID" ]; then
    echo "🎯 Will use Project ID: $PROJECT_ID for template creation"
    
    # Get project resources
    echo "🔍 Getting project resources..."
    REPOSITORIES=$(curl -s -H "Authorization: Bearer $API_TOKEN" "$SEMAPHORE_URL/api/project/$PROJECT_ID/repositories")
    INVENTORIES=$(curl -s -H "Authorization: Bearer $API_TOKEN" "$SEMAPHORE_URL/api/project/$PROJECT_ID/inventory")
    ENVIRONMENTS=$(curl -s -H "Authorization: Bearer $API_TOKEN" "$SEMAPHORE_URL/api/project/$PROJECT_ID/environment")
    
    REPO_ID=$(echo "$REPOSITORIES" | jq -r '.[0].id' 2>/dev/null || echo "1")
    INVENTORY_ID=$(echo "$INVENTORIES" | jq -r '.[0].id' 2>/dev/null || echo "1")
    ENV_ID=$(echo "$ENVIRONMENTS" | jq -r '.[0].id' 2>/dev/null || echo "1")
    
    echo "📊 Resources found:"
    echo "  Repository ID: $REPO_ID"
    echo "  Inventory ID: $INVENTORY_ID" 
    echo "  Environment ID: $ENV_ID"
    
    echo "✅ Ready to create templates!"
    echo "Run: ./create-templates-with-token.sh"
else
    echo "❌ Could not find project ID"
fi
