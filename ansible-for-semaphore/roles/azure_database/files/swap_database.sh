#!/usr/bin/env bash
set -euo pipefail

# Defaults
DRY_RUN="true"

# Required inputs
RESOURCE_GROUP=""
SUBSCRIPTION_ID=""
MODE=""
CLOUD_ENVIRONMENT=""

usage() {
  echo "Usage: $0 --resource-group=RG --mode='restore|backup' --subscription-id=ID --cloud=ENV --target [backup|restore] [--dry-run]"
  exit 1
}

# Parse args
for arg in "$@"; do
  case $arg in
  --cloud=*)
    CLOUD_ENVIRONMENT="${arg#*=}"
    ;;
  --resource-group=*)
    RESOURCE_GROUP="${arg#*=}"
    ;;
  --subscription-id=*)
    SUBSCRIPTION_ID="${arg#*=}"
    ;;
  --mode=*)
    MODE="${arg#*=}"
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

# Validate inputs
[[ -z "$MODE" ]] && usage
[[ "$MODE" != "restore" && "$MODE" != "backup" ]] && usage
[[ -z "$RESOURCE_GROUP" ]] && echo "❌ Missing --resource-group" && usage
[[ -z "$CLOUD_ENVIRONMENT" ]] && echo "❌ Missing --cloud" && usage
[[ -z "$SUBSCRIPTION_ID" ]] && echo "❌ Missing --subscription-id" && usage

if [[ "$DRY_RUN" == "true" ]]; then
  echo "✅ DRY RUN: Skipping actual Azure CLI calls."
  sql_server="TEST_SERVER"
  dbs=("TEST_DB_1-restored" "TEST_DB_2-restored" "TEST_DB_1-backup" "TEST_DB_2-backup" "TEST_DB_1" "TEST_DB_2")
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

declare -A db_roles

for db in "${dbs[@]}"; do
  if [[ "$db" == *-restore ]]; then
    base="${db%-restore}"
    db_roles["$base,restore"]="$db"
  elif [[ "$db" == *-backup ]]; then
    base="${db%-backup}"
    db_roles["$base,backup"]="$db"
  else
    base="$db"
    db_roles["$base,original"]="$db"
  fi
done

# Confirm intention
echo "📝 Planned rename operations on:"
echo "🔎 Subscription: $SUBSCRIPTION_ID"
echo "🔎 Server: $sql_server"
echo "🔎 Resource group: $RESOURCE_GROUP"
echo "🔧 Dry run: $DRY_RUN"
echo

for key in "${!db_roles[@]}"; do
  IFS=',' read -r base role <<<"$key"

  original="${db_roles[$base, original]:-}"
  restore="${db_roles[$base, restore]:-}"
  backup="${db_roles[$base, backup]:-}"

  case "$MODE" in
  restore)
    if [[ -n "$original" && -n "$restore" && -z "$backup" ]]; then
      echo "🔁 $original → ${base}-backup"
      echo "🔁 $restore → $base"
      # az sql db copy \
      #   --resource-group $RESOURCE_GROUP \
      #   --server $sql_server \
      #   --name $original \
      #   --dest-name ${base}-backup
      # az sql db copy \
      #   --resource-group $RESOURCE_GROUP \
      #   --server $sql_server \
      #   --name $restore \
      #   --dest-name $base
    fi
    ;;
  backup)
    if [[ -n "$original" && -n "$backup" && -z "$restore" ]]; then
      echo "🔁 $original → ${base}-restore"
      echo "🔁 $backup → $base"
    #   az sql db copy \
    #     --resource-group $RESOURCE_GROUP \
    #     --server $sql_server \
    #     --name $original \
    #     --dest-name ${base}-restore
    #   az sql db copy \
    #     --resource-group $RESOURCE_GROUP \
    #     --server $sql_server \
    #     --name $backup \
    #     --dest-name $base
    fi
    ;;
  *)
    echo "❌ Found incompatible swap configuration - mode: $MODE"
    usage
    ;;
  esac
done
