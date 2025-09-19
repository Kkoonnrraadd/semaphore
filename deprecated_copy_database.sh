#!/usr/bin/env bash
set -euo pipefail

# Defaults
DRY_RUN="false"
MAX_ATTEMPTS=600
SLEEP_SECONDS=5
attempt=1

# Required inputs
SOURCE_RESOURCE_GROUP=""
SOURCE_SUBSCRIPTION_ID=""
DEST_RESOURCE_GROUP=""
DEST_SUBSCRIPTION_ID=""
CLOUD_ENVIRONMENT=""

usage() {
  echo ""
  echo "Usage: $0 \\"
  echo "  --source-resource-group=SOURCE_RESOURCE_GROUP --source-subscription-id=SOURCE_ID \\"
  echo "  --dest-resource-group=DEST_RESOURCE_GROUP --dest-subscription-id=DEST_ID --cloud=ENV [--dry-run]"
  exit 1
}

# Parse args
for arg in "$@"; do
  case $arg in
  --cloud=*) CLOUD_ENVIRONMENT="${arg#*=}" ;;
  --source-resource-group=*) SOURCE_RESOURCE_GROUP="${arg#*=}" ;;
  --source-subscription-id=*) SOURCE_SUBSCRIPTION_ID="${arg#*=}" ;;
  --dest-resource-group=*) DEST_RESOURCE_GROUP="${arg#*=}" ;;
  --dest-subscription-id=*) DEST_SUBSCRIPTION_ID="${arg#*=}" ;;
  --dry-run) DRY_RUN="true" ;;
  *) echo "❌ Unknown argument: $arg" && usage ;;
  esac
done

# Validate
[[ -z "$SOURCE_RESOURCE_GROUP" ]] && echo "❌ Missing --source-resource-group" && usage
[[ -z "$SOURCE_SUBSCRIPTION_ID" ]] && echo "❌ Missing --source-subscription-id" && usage
[[ -z "$DEST_RESOURCE_GROUP" ]] && echo "❌ Missing --dest-resource-group" && usage
[[ -z "$DEST_SUBSCRIPTION_ID" ]] && echo "❌ Missing --dest-subscription-id" && usage

AZURE_DOMAIN=$([[ $CLOUD_ENVIRONMENT == "AzureUSGovernment" ]] &&
  echo "https://database.usgovcloudapi.net" || echo "https://database.windows.net")

if [[ "$DRY_RUN" == "true" ]]; then
  echo "✅ DRY RUN: Skipping actual Azure CLI calls."
  source_sql_server="SOURCE_TEST_SERVER"
  source_dbs=("TEST_DB_1-restored" "TEST_DB_2-restored" "TEST_DB_1" "TEST_DB_2")
  dest_sql_server="DEST_TEST_SERVER"
  dest_elasticpool="DEST_ELASTICPOOL_TEST"
  dest_server_fqdn="DEST_TEST_SERVER.FQDOMAIN"
else
  az cloud set --name "$CLOUD_ENVIRONMENT"
  az account set --subscription "$SOURCE_SUBSCRIPTION_ID"
  source_sql_server=$(az sql server list \
    --subscription "$SOURCE_SUBSCRIPTION_ID" \
    --query "[?tags.Type == 'Primary'] | [0].name" \
    --output tsv)
  [[ -z "$source_sql_server" ]] && {
    echo "❌ Failed to find Source SQL server"
    exit 1
  }
  source_dbs=()
  readarray -t source_dbs < <(
    az sql db list \
      --subscription "$SOURCE_SUBSCRIPTION_ID" \
      --resource-group "$SOURCE_RESOURCE_GROUP" \
      --server "$source_sql_server" \
      --output json | jq -r '.[].name'
  )
  if [[ ${#source_dbs[@]} -eq 0 ]]; then
    echo "❌ Failed to find databases for server $source_sql_server"
    exit 1
  fi
  dest_sql_server=$(az sql server list \
    --subscription "$DEST_SUBSCRIPTION_ID" \
    --query "[?tags.Type == 'Primary'] | [0].name" \
    --output tsv)
  [[ -z "$dest_sql_server" ]] && {
    echo "❌ Failed to find Destination SQL server"
    exit 1
  }
  dest_elasticpool=$(az sql elastic-pool list \
    --subscription "$DEST_SUBSCRIPTION_ID" \
    --server "$dest_sql_server" \
    --resource-group "$DEST_RESOURCE_GROUP" \
    --query "[0].name" \
    -o tsv)
  dest_server_fqdn=$(az sql server list \
    --subscription "$DEST_SUBSCRIPTION_ID" \
    --query "[?tags.Type == 'Primary'] | [0].fullyQualifiedDomainName" \
    -o tsv)
fi

if [[ "$source_sql_server" == "$dest_sql_server" ]]; then
  echo "❌ Source and destination must differ. $source_sql_server != $dest_sql_server"
  exit 1
fi

echo "📋 Copying SQL DB using T-SQL:"
echo "  From:                    $source_sql_server: ${source_dbs[*]}"
echo "  Source Resource Group:   $SOURCE_RESOURCE_GROUP"
echo "  Source Subscription ID:  $SOURCE_SUBSCRIPTION_ID"
echo "  To:                      $dest_sql_server: ${source_dbs[*]}"
echo "  Dest Resource Group:     $DEST_RESOURCE_GROUP"
echo "  Dest Subscription ID:    $DEST_SUBSCRIPTION_ID"
echo "  Dest Elastic Pool:       $dest_elasticpool"
echo "  Dest FQDN:               $dest_server_fqdn"
echo "  Cloud:                   $CLOUD_ENVIRONMENT"
echo "  AZURE_DOMAIN:            $AZURE_DOMAIN"
echo "  Dry Run:                 $DRY_RUN"
echo ""

verifyCopied() {
  resource_group=$1
  sql_server=$2
  for db_name in "${source_dbs[@]}"; do
    if [[ "$db_name" != *Copy* && "$db_name" != *master* && "$db_name" != *restored* ]]; then
      restored_name="${db_name}-restored"
      echo "🔍 Waiting for $restored_name to be restored and Online..."
      for ((i = 1; i <= MAX_ATTEMPTS; i++)); do
        status=$(az sql db show \
          --resource-group "$resource_group" \
          --server "$sql_server" \
          --name "$restored_name" \
          --query "status" -o tsv 2>/dev/null)

        if [[ "$status" == "Online" ]]; then
          echo "✅ $restored_name is Online after $((i * SLEEP_SECONDS)) seconds."
          break
        elif [[ "$status" == "Restoring" || "$status" == "Creating" ]]; then
          echo "⌛ [$i/$MAX_ATTEMPTS] $restored_name status: $status — waiting..."
        elif [[ -z "$status" ]]; then
          echo "⌛ [$i/$MAX_ATTEMPTS] $restored_name not found yet, waiting..."
        else
          echo "⚠️ Unexpected status '$status'."
        fi
        sleep "$SLEEP_SECONDS"

        if [[ $i -eq $MAX_ATTEMPTS ]]; then
          total_minutes=$(((MAX_ATTEMPTS * SLEEP_SECONDS) / 60))
          echo "❌ Timeout: $restored_name did not reach Online within $total_minutes minutes."
          exit 1
        fi
      done
    fi
  done
}

verifyCopied "$SOURCE_RESOURCE_GROUP" "$source_sql_server"

for db_name in "${source_dbs[@]}"; do
  if [[ "$db_name" != *Copy* && "$db_name" != *master* && "$db_name" != *restored* ]]; then
    restored_name="${db_name}-restored"

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "➡️ Would copy: $restored_name from $source_sql_server to $dest_sql_server"
      echo "✅ DRY RUN: Would run:"
      echo "  CREATE DATABASE [$restored_name] AS COPY OF [$source_sql_server].[$restored_name] (SERVICE_OBJECTIVE = ELASTIC_POOL( name = [$dest_elasticpool] ));"
    else
      echo "⚙️ Copying: $restored_name from $source_sql_server to $dest_sql_server"
      # ACCESS_TOKEN=$(az account get-access-token --resource "$AZURE_DOMAIN" --query accessToken -o tsv)
      # sqlcmd -S "$dest_sql_server" \
      #   -Q "CREATE DATABASE [$restored_name] AS COPY OF [$source_sql_server].[$restored_name] (SERVICE_OBJECTIVE = ELASTIC_POOL( name = [$dest_elasticpool] ));" \
      #   -G \
      #   -C \
      #   -l 30 \
      #   -t 600 \
      #   -N \
      #   -M 1 \
      #   -U '' \
      #   -P "$ACCESS_TOKEN"
      # break
      # while [[ $attempt -le $MAX_ATTEMPTS ]]; do
      #   state_desc=$(sqlcmd \
      #     -S "$dest_sql_server" \
      #     -d master \
      #     -G \
      #     -C \
      #     -U '' \
      #     -P "$ACCESS_TOKEN" \
      #     -Q "SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name = '$restored_name'" -h -1 -W | tr -d '\r')

      #   if [[ "$state_desc" == "ONLINE" ]]; then
      #     echo "✅ Database $restored_name is ONLINE (copied)"
      #     break
      #   else
      #     sleep $SLEEP_SECONDS
      #     ((attempt++))
      #   fi
      done

      if [[ $attempt -gt $MAX_ATTEMPTS ]]; then
        echo "❌ ERROR: Database $restored_name did not come ONLINE within $((MAX_ATTEMPTS * SLEEP_SECONDS / 60)) minutes"
        exit 1
      fi
    fi
  fi
done

echo "✅ Copy operation initiated successfully."

verifyCopied "$DEST_RESOURCE_GROUP" "$dest_sql_server"

echo "✅ Copy operation completed successfully."
