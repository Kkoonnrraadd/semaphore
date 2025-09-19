#!/usr/bin/env bash

set -euo pipefail

VALID_ACTIONS=("delete-destination-backup" "delete-source-restore" "delete-destination-replica")
ACTIONS_STRING=$(
  IFS="|"
  echo "${VALID_ACTIONS[*]}"
)

# --- Defaults ---
DRY_RUN="true"

# Require inputs
ACTION=""
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
CLOUD_ENVIRONMENT=""

# --- Usage ---
usage() {
  echo "Usage: $0 --action=ACTION($ACTIONS_STRING) subscription-id=ID --resource-group=RG --cloud=ENV [--dry-run]"
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
if [[ ! " ${VALID_ACTIONS[*]} " =~ ${ACTION} ]]; then
  ACTIONS_STRING=$(
    IFS="|"
    echo "${VALID_ACTIONS[*]}"
  )
  echo "❌ Invalid --action: '$ACTION'"
  echo "✅ Valid actions: $ACTIONS_STRING"
  usage
fi
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

deleteDb() {
  db_name=$1
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "➡️ Would delete: $db_name from $sql_server"
  else
    if az sql db show \
      --name "$db_name" \
      --server "$sql_server" \
      --resource-group "$RESOURCE_GROUP" \
      --subscription "$SUBSCRIPTION_ID" \
      --only-show-errors >/dev/null 2>&1; then

      echo "⚠️  Deleting database $db_name from $sql_server..."
      # az sql db delete \
      #   --name "$db_name" \
      #   --server "$sql_server" \
      #   --resource-group "$RESOURCE_GROUP" \
      #   --subscription "$SUBSCRIPTION_ID" \
      #   --yes \
      #   --only-show-errors
    else
      echo "✅ Database $db_name does not exist on $sql_server — skipping delete."
    fi
  fi
}

echo "🔎 Subscription: $SUBSCRIPTION_ID"
echo "🔎 Server: $sql_server"
echo "🔎 Resource group: $RESOURCE_GROUP"
echo "🔧 Dry run: $DRY_RUN"
echo

# create-source-restore
if [[ $ACTION == "delete-destination-backup" ]]; then
  for db_name in "${dbs[@]}"; do
    if [[ "$db_name" != *Copy* && "$db_name" != *master* && "$db_name" != *restored* ]]; then
      deleteDb "${db_name}-backup"
    fi
  done
# delete-source-restore
elif [[ $ACTION == "delete-source-restore" ]]; then
  for db_name in "${dbs[@]}"; do
    if [[ "$db_name" != *Copy* && "$db_name" != *master* && "$db_name" != *backup* ]]; then
      deleteDb "${db_name}-restored"
    fi
  done
elif [[ $ACTION == "delete-destination-replica" ]]; then
  if [[ "$sql_server" != *replica* ]]; then
    echo "❌ Expected 'replica' in SQL server name: $sql_server"
    exit 1
  fi

  deleteDb "eworkin-plus"
  deleteDb "integratorplusext"
else
  echo "❌ Tried to execute an unknown action. $ACTION"
fi
