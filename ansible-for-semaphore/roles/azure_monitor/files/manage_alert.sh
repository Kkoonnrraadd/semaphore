#!/bin/bash

set -euo pipefail

REGION_ALIAS=""
RESOURCE_GROUP=""     # Dest environment resource group
HUB_RESOURCE_GROUP="" # Shared resource group
ACTION=""
CLOUD_ENVIRONMENT=""
SUBSCRIPTION_ID=""     # Dest environment subscription
HUB_SUBSCRIPTION_ID="" # Shared Subscription
DRY_RUN="true"

usage() {
  echo "Usage: $0 --action=enable|disable --type=ALERT_TYPE --dest-resource-group=RG --hub-resource-group=HUB-RG " \
    "--dest-subscription-id=ID --hub-subscription-id=HUB-ID [--dry-run]"
  exit 1
}

for arg in "$@"; do
  case $arg in
  --action=*)
    ACTION="${arg#*=}"
    ;;
  --region-alias=*)
    REGION_ALIAS="${arg#*=}"
    ;;
  --dest-resource-group=*)
    RESOURCE_GROUP="${arg#*=}"
    ;;
  --hub-resource-group=*)
    HUB_RESOURCE_GROUP="${arg#*=}"
    ;;
  --dest-subscription-id=*)
    SUBSCRIPTION_ID="${arg#*=}"
    ;;
  --hub-subscription-id=*)
    HUB_SUBSCRIPTION_ID="${arg#*=}"
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

[[ -z "$ACTION" ]] && echo "❌ Missing --action" && usage
[[ "$ACTION" != "enable" && "$ACTION" != "disable" ]] && echo "❌ Invalid --action: $ACTION" && usage
[[ -z "$CLOUD_ENVIRONMENT" ]] && echo "❌ Missing --cloud" && usage
[[ -z "$RESOURCE_GROUP" ]] && echo "❌ Missing --dest-region-alias" && usage
[[ -z "$REGION_ALIAS" ]] && echo "❌ Missing --dest-resource-group" && usage
[[ -z "$HUB_RESOURCE_GROUP" ]] && echo "❌ Missing --hub-resource-group" && usage
[[ -z "$SUBSCRIPTION_ID" ]] && echo "❌ Missing --dest-subscription-id" && usage
[[ -z "$HUB_SUBSCRIPTION_ID" ]] && echo "❌ Missing --hub-subscription-id" && usage

alert_name=""
webtests=""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "✅ DRY RUN: Skipping actual Azure CLI calls."
  alert_name="BACKEND_HEALTH_TEST"
  webtests='[{"name":"ENV_WEBTESTS_TEST_1"},{"name":"ENV_WEBTESTS_TEST_2"}]'
else
  az cloud set --name "$CLOUD_ENVIRONMENT"
  az account set --subscription "$SUBSCRIPTION_ID"
  alert_name=$(az monitor metrics alert list \
    --resource-group "$HUB_RESOURCE_GROUP" \
    --subscription "$HUB_SUBSCRIPTION_ID" \
    --query "[?contains(name,'$REGION_ALIAS')].{Name: name} | [0]" \
    --output tsv)
  webtests=$(az monitor app-insights "$TYPE" list \
    --subscription "$SUBSCRIPTION_ID" \
    --output json)
fi

modifyMetricAlertMonitor() {
  enabled=$1
  ENABLED="${enabled,,}" # normalize to lowercase true/false
  echo "🚀 Modifying Metrics alert $alert_name"
  if [[ "$ENABLED" == "true" ]]; then
    echo "Action: Enabling"
  else
    echo "Action: Disabling"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "🔎 DRY RUN: $ACTION monitor $alert_name in $RESOURCE_GROUP"
    echo "would modify: $alert_name"
  else
    echo "enable or disable"
    # az monitor metrics alert update \
    #   --enabled "true" \
    #   --name "$alert_name" \
    #   --resource-group "$HUB_RESOURCE_GROUP" \
    #   --subscription "$HUB_SUBSCRIPTION_ID"
  fi
}

modifyAppInsightsWebTestMonitor() {
  enabled=$1
  ENABLED="${enabled,,}" # normalize to lowercase true/false
  echo "🚀 Modifying Application Insight Webtests"
  if [[ "$ENABLED" == "true" ]]; then
    echo "Action: Enabling"
  else
    echo "Action: Disabling"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "🔎 DRY RUN: $ACTION monitor type webtest in $RESOURCE_GROUP"
    echo "$webtests" | jq -r '.[].name' | while read -r WEBTEST_NAME; do
      echo "would modify: $WEBTEST_NAME"
    done
  else
    echo "$webtests" | jq -r '.[].name' | while read -r WEBTEST_NAME; do
      echo "$WEBTEST_NAME"
      # az monitor app-insights $TYPE update \
      #   --name $($webtest.name) \
      #   --resource-group $RESOURCE_GROUP \
      #   --enabled $ENABLED \
      #   --subscription $SUBSCRIPTION_ID \
      #   --query "{name: name, enabled: enabled}"
    done
  fi
}

if [[ "$ACTION" == "enable" ]]; then
  echo "🚀 Enabling backend health"
  modifyMetricAlertMonitor "true"
  echo "✅ Enabled backend health"

  echo "🚀 Enabling webtests"
  modifyAppInsightsWebTestMonitor "true"
  echo "✅ Enabled webtests"
elif [[ "$ACTION" == "disable" ]]; then
  echo "🚀 Disabling backend health"
  modifyMetricAlertMonitor "false"
  echo "✅ Disabled backend health"

  echo "🚀 Disabling webtests"
  modifyAppInsightsWebTestMonitor "false"
  echo "✅ Disabled webtests"
else
  echo "❌ Invalid action: $ACTION"
  usage
fi
