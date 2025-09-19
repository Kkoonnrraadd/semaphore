#!/bin/bash

set -euo pipefail

# Defaults
DRY_RUN="true"

# Inputs
SUBCRIPTION_ID=""
CLOUD_ENVIRONMENT=""

usage() {
  echo "Usage: $0 --action=enable|disable --type=ALERT_TYPE --dest-resource-group=RG --hub-resource-group=HUB-RG " \
    "--dest-subscription-id=ID --hub-subscription-id=HUB-ID [--dry-run]"
  exit 1
}

for arg in "$@"; do
  case $arg in
  --subscription-id=*)
    SUBSCRIPTION_ID="${arg#*=}"
    ;;
  --cloud=*)
    CLOUD_ENVIRONMENT="${arg#*=}"
    ;;
  --dry-run)
    DRY_RUN=true
    ;;
  *)
    echo "❌ Unknown argument: $arg"
    usage
    ;;
  esac
done

[[ -z "$CLOUD_ENVIRONMENT" ]] && echo "❌ Missing --cloud" && usage
[[ -z "$SUBSCRIPTION_ID" ]] && echo "❌ Missing --subscription-id" && usage

if [[ "$DRY_RUN" == "true" ]]; then
  echo "✅ DRY RUN: Skipping actual Azure CLI calls."
  echo "➡️ Would terragrunt init: $PWD"
  echo "➡️ Would run terragrunt apply --target='module.database' --auto-approve"
else
  az cloud set --name "$CLOUD_ENVIRONMENT"
  az account set --subscription "$SUBSCRIPTION_ID"
  terragrunt init -reconfigure -upgrade
#   terragrunt apply --target='module.database' --auto-approve
fi
