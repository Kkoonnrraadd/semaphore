#!/bin/bash

set -euo pipefail

# Initialize variables
RESOURCE_GROUP=""
AKS_CLUSTER_NAME=""
CLOUD_ENVIRONMENT=""
SUBSCRIPTION_ID=""
ACTION=""
DRY_RUN="true"

usage() {
  echo "Usage: $0 --action=start|stop --resource-group=NAME --cluster-name=NAME --cloud=ENV --subscription-id=ID"
  exit 1
}

# Parse keyword args
for arg in "$@"; do
  case $arg in
  --resource-group=*)
    RESOURCE_GROUP="${arg#*=}"
    ;;
  --cluster-name=*)
    AKS_CLUSTER_NAME="${arg#*=}"
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
    DRY_RUN=true
    ;;
  *)
    echo "❌ Unknown argument: $arg"
    usage
    ;;
  esac
done

[[ -z "$ACTION" ]] && echo "❌ Missing --action" && usage
[[ "$ACTION" != "start" && "$ACTION" != "stop" ]] && echo "❌ Invalid --action: $ACTION" && usage
[[ -z "$RESOURCE_GROUP" ]] && echo "❌ Missing --resource-group" && usage
[[ -z "$AKS_CLUSTER_NAME" ]] && echo "❌ Missing --cluster-name" && usage
[[ -z "$CLOUD_ENVIRONMENT" ]] && echo "❌ Missing --cloud" && usage
[[ -z "$SUBSCRIPTION_ID" ]] && echo "❌ Missing --subscription-id" && usage

echo "📝 Action plan:"
echo "  ▶ Action:        $ACTION"
echo "  ▶ Cluster:       $AKS_CLUSTER_NAME"
echo "  ▶ Resource Group:$RESOURCE_GROUP"
echo "  ▶ Subscription:  $SUBSCRIPTION_ID"
echo "  ▶ Cloud:         $CLOUD_ENVIRONMENT"
echo "  ▶ Dry Run:       $DRY_RUN"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "✅ DRY RUN: Skipping actual Azure CLI calls."
else
  az cloud set --name "$CLOUD_ENVIRONMENT"
  az account set --subscription "$SUBSCRIPTION_ID"
fi

# TODO: Scale in scale out instead of start/stop
if [[ "$ACTION" == "start" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Started"
  else
    echo "words"
    # az aks start --name "$AKS_CLUSTER_NAME" --resource-group "$RESOURCE_GROUP"
  fi
elif [[ "$ACTION" == "stop" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Stopped"
  else
    echo "words"
    # az aks stop --name "$AKS_CLUSTER_NAME" --resource-group "$RESOURCE_GROUP"
  fi
fi
