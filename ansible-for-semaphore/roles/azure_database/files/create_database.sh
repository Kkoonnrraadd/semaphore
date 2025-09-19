#!/usr/bin/env bash

set -euo pipefail

# --- Defaults ---
DRY_RUN="false"
MAX_ATTEMPTS=600
SLEEP_SECONDS=5
# attempt=1

# Require inputs
ACTION=""
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
INTERVAL="-1 hour"
CLOUD_ENVIRONMENT=""

# --- Usage ---
usage() {
  echo "Usage: $0 --action='create-source-restore' --subscription-id=ID --resource-group=RG --cloud=ENV [--dry-run --interval '-2 hours']"
  exit 1
}

# --- Parse arguments ---
for arg in "$@"; do
  case $arg in
  --resource-group=*)
    RESOURCE_GROUP="${arg#*=}"
    ;;
  --cloud=*)
    CLOUD_ENVIRONMENT="${arg#*=}"
    ;;
  --interval=*)
    INTERVAL="${arg#*=}"
    ;;
  --subscription-id=*)
    SUBSCRIPTION_ID="${arg#*=}"
    ;;
  --action=*)
    ACTION="${arg#*=}"
    ;;
  --dry-run)
    DRY_RUN="true"
    ;;
  *)
    echo "❌ Unknown argument: $arg"
    usage
    ;;
  esac
done

[[ -z "$ACTION" ]] && echo "❌ Missing --action" && usage
[[ "$ACTION" != "create-source-restore" ]] && usage
[[ -z "$RESOURCE_GROUP" ]] && echo "❌ Missing --resource-group" && usage
[[ -z "$CLOUD_ENVIRONMENT" ]] && echo "❌ Missing --cloud" && usage
[[ -z "$SUBSCRIPTION_ID" ]] && echo "❌ Missing --subscription-id" && usage

if [[ "$DRY_RUN" == "true" ]]; then
  echo "✅ DRY RUN: Skipping actual Azure CLI calls."
  sql_server=$([[ $ACTION == "delete-destination-replica" ]] &&
    echo "TEST_-replica-_SERVER" || echo "TEST_SERVER")
  dbs=("TEST_DB_1-restored" "TEST_DB_2-restored" "TEST_DB_1-backup" "TEST_DB_2-backup")
else
  az cloud set --name "$CLOUD_ENVIRONMENT"
  az account set --subscription "$SUBSCRIPTION_ID"
  sql_server=$(az sql server list \
    --subscription "$SUBSCRIPTION_ID" \
    --query "[?tags.Type == 'Primary'] | [0].name" \
    --output tsv)
  [[ -z "$sql_server" ]] && {
    echo "❌ Failed to find SQL server"
    exit 1
  }
  dbs=()
  readarray -t dbs < <(
    az sql db list \
      --subscription "$SUBSCRIPTION_ID" \
      --resource-group "$RESOURCE_GROUP" \
      --server "$sql_server" \
      --output json | jq -r '.[].name'
  )
  if [[ ${#dbs[@]} -eq 0 ]]; then
    echo "❌ Failed to find databases for server $sql_server"
    exit 1
  fi
fi

echo "🔎 Subscription: $SUBSCRIPTION_ID"
echo "🔎 Server: $sql_server"
echo "🔎 Resource group: $RESOURCE_GROUP"
echo "🔧 Dry run: $DRY_RUN"
echo

# create-source-restore
if [[ $ACTION == "create-source-restore" ]]; then
  restore_point=$(date -u -d "$INTERVAL" '+%Y-%m-%dT%H:%M:%S')
  echo "🔎 Restore point: $restore_point"
  # Copy database step
  for db_name in "${dbs[@]}"; do
    if [[ "$db_name" != *Copy* && "$db_name" != *master* && "$db_name" != *restored* ]]; then
      restored_name="${db_name}-restored"

      if [[ "$DRY_RUN" == "true" ]]; then
        echo "➡️ Would restore: $restored_name from $db_name at $restore_point"
      else
        echo "🔍 Checking if $restored_name already exists..."
        if az sql db show \
          --resource-group "$RESOURCE_GROUP" \
          --server "$sql_server" \
          --name "$restored_name" &>/dev/null; then
          echo "⚠️  Database '$restored_name' already exists. Skipping restore."
        else
          echo "⚙️ Restoring: $restored_name from $db_name at $restore_point"
          az sql db restore \
            --dest-name "$restored_name" \
            --edition Standard \
            --name "$db_name" \
            --resource-group "$RESOURCE_GROUP" \
            --server "$sql_server" \
            --subscription "$SUBSCRIPTION_ID" \
            --service-objective S3 \
            --time "$restore_point" \
            --no-wait
        fi
      fi
    fi
  done
  # Validation step that the database restored and is 'Online'
  for db_name in "${dbs[@]}"; do
    if [[ "$db_name" != *Copy* && "$db_name" != *master* && "$db_name" != *restored* ]]; then
      restored_name="${db_name}-restored"
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "➡️ Would check for restore: $restored_name from $sql_server"
      else
        echo "🔍 Waiting for $restored_name to be restored and Online..."
        for ((i = 1; i <= MAX_ATTEMPTS; i++)); do
          status=$(az sql db show \
            --resource-group "$RESOURCE_GROUP" \
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
    fi
  done
else
  echo "❌ Tried to execute an unknown action. $ACTION"
fi
