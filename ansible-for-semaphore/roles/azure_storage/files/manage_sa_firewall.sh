#!/usr/bin/env bash
set -euo pipefail

VALID_ACTIONS=("enable" "disable")

# Defaults
DRY_RUN="true"

# Required inputs
ACTION=""
SOURCE_SUB=""
SOURCE_RG=""
DEST_SUB=""
DEST_RG=""
CLOUD_ENVIRONMENT=""

usage() {
  echo ""
  echo "Usage: $0 \\"
  echo "  --action=enable|disable \\"
  echo "  --source-subscription-id=SUB_ID --source-rg=RESOURCE_GROUP --source-sa=ACCOUNT_NAME \\"
  echo "  --dest-subscription-id=SUB_ID --dest-rg=RESOURCE_GROUP --dest-sa=ACCOUNT_NAME \\"
  echo "  --cloud=ENV [--dry-run]"
  exit 1
}

# Parse args
for arg in "$@"; do
  case $arg in
  --action=*)
    ACTION="${arg#*=}"
    ;;
  --source-subscription-id=*)
    SOURCE_SUB="${arg#*=}"
    ;;
  --source-rg=*)
    SOURCE_RG="${arg#*=}"
    ;;
  --dest-subscription-id=*)
    DEST_SUB="${arg#*=}"
    ;;
  --dest-rg=*)
    DEST_RG="${arg#*=}"
    ;;
  --cloud=*)
    CLOUD_ENVIRONMENT="${arg#*=}"
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
[[ -z "$CLOUD_ENVIRONMENT" ]] && echo "❌ Missing --cloud" && usage
[[ -z "$SOURCE_SUB" ]] && echo "❌ Missing --source-subscription-id" && usage
[[ -z "$SOURCE_RG" ]] && echo "❌ Missing --source-rg" && usage
[[ -z "$DEST_SUB" ]] && echo "❌ Missing --dest-subscription-id" && usage
[[ -z "$DEST_RG" ]] && echo "❌ Missing --dest-rg" && usage

# Fetch current default actions
get_default_action() {
  local sub="$1"
  local rg="$2"
  local sa="$3"
  az storage account show \
    --subscription "$sub" \
    -g "$rg" \
    -n "$sa" \
    --query "networkRuleSet.defaultAction" \
    --output tsv
}

if [[ "$DRY_RUN" == "true" ]]; then
  echo "✅ DRY RUN: Skipping actual Azure CLI calls."
  if [[ "$ACTION" == "enable" ]]; then
    current_source_action="Allow"
    current_dest_action="Allow"
  elif [[ "$ACTION" == "disable" ]]; then
    current_source_action="Deny"
    current_dest_action="Deny"
  fi
  source_sa_name="source-sa-test"
  dest_sa_name="destination-sa-test"
else
  az cloud set --name "$CLOUD_ENVIRONMENT"
  az account set --subscription "$SUBSCRIPTION_ID"
  source_sa_list=$(az storage account list --subscription "$SOURCE_SUB" --query "[?tags.Type=='Primary']")
  source_sa_name=$(echo "$source_sa_list" | jq -r '.[].name')

  dest_sa_list=$(az storage account list --subscription "$DEST_SUB" --query "[?tags.Type=='Primary']")
  dest_sa_name=$(echo "$dest_sa_list" | jq -r '.[].name')
  current_source_action=$(get_default_action "$SOURCE_SUB" "$SOURCE_RG" "$source_sa_name")
  current_dest_action=$(get_default_action "$DEST_SUB" "$DEST_RG" "$dest_sa_name")
fi

echo "🧱 Preparing to manage storage account firewall rules"
echo "  Source: $source_sa_name ($SOURCE_RG @ $SOURCE_SUB)"
echo "  Dest:   $dest_sa_name ($DEST_RG @ $DEST_SUB)"
echo "  Dry run: $DRY_RUN"
echo
echo "🔍 Current state $([[ "$DEBUG" == "true" ]] && echo "(DEBUG MODE)"):"
echo "  $source_sa_name default action: $current_source_action $([[ "$DEBUG" == "true" ]] && echo '[MOCK]')"
echo "  $dest_sa_name default action:   $current_dest_action $([[ "$DEBUG" == "true" ]] && echo '[MOCK]')"
echo

if [[ $ACTION == "enable" ]]; then
  if [[ "$current_source_action" == "Allow" && "$current_dest_action" == "Allow" ]]; then
    echo "✅ Both storage accounts already allow public access."
  else
    echo "🔐 Opening firewall rules..."

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "✅ DRY RUN: Would open default actions to 'Allow'"
    else
      echo "⚙️ Setting $source_sa_name and $dest_sa_name default actions to 'Allow'"
      #   az storage account update \
      #     --subscription "$SOURCE_SUB" \
      #     -g "$SOURCE_RG" \
      #     -n "$source_sa_name" \
      #     --default-action Allow

      #   az storage account update \
      #     --subscription "$DEST_SUB" \
      #     -g "$DEST_RG" \
      #     -n "$dest_sa_name" \
      #     --default-action Allow

      echo "⏳ Sleeping for 30 seconds to let changes propagate..."
      sleep 30
    fi
  fi
elif [[ $ACTION == "disable" ]]; then
  echo "🔒 Closing storage account firewall rules..."

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "✅ DRY RUN: Would set $source_sa_name and $dest_sa_name default actions to 'Deny'"
  else
    echo "⚙️ Setting $source_sa_name and $dest_sa_name default actions to 'Deny'"
    # az storage account update \
    #   --subscription "$SOURCE_SUB" \
    #   -g "$SOURCE_RG" \
    #   -n "$source_sa_name" \
    #   --default-action Deny

    # az storage account update \
    #   --subscription "$DEST_SUB" \
    #   -g "$DEST_RG" \
    #   -n "$dest_sa_name" \
    #   --default-action Deny

    echo "✅ Firewalls closed."
  fi
else
  echo "❌ Tried to execute an unknown action. $ACTION"
fi
