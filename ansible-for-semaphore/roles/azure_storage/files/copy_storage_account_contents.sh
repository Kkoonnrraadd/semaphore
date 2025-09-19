#!/usr/bin/env bash
set -euo pipefail

# Defaults
DRY_RUN="true"

# Required inputs
SOURCE_SUB=""
DEST_SUB=""
CLOUD_ENVIRONMENT=""

usage() {
  echo ""
  echo "Usage: $0 \\"
  echo "  --source-subscription-id=SUB_ID --dest-subscription-id=SUB_ID --cloud=ENV [--dry-run]"
  exit 1
}

# Parse args
for arg in "$@"; do
  case $arg in
  --source-subscription-id=*)
    SOURCE_SUB="${arg#*=}"
    ;;
  --dest-subscription-id=*)
    DEST_SUB="${arg#*=}"
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
[[ -z "$CLOUD_ENVIRONMENT" ]] && echo "❌ Missing --cloud" && usage
[[ -z "$SOURCE_SUB" ]] && echo "❌ Missing --source-subscription-id" && usage
[[ -z "$DEST_SUB" ]] && echo "❌ Missing --dest-subscription-id" && usage

if [[ "$DRY_RUN" == "true" ]]; then
  echo "✅ DRY RUN: Skipping actual Azure CLI calls."
  source_sa_name="source-storage-account-test"
  source_blob="source-blob-storage-endpoint-test"

  dest_sa_name="destination-storage-account-test"
  dest_blob="destination-blob-storage-endpoint-test"
else
  az cloud set --name "$CLOUD_ENVIRONMENT"
  az account set --subscription "$SUBSCRIPTION_ID"
  source_sa_list=$(az storage account list --subscription "$SOURCE_SUB" --query "[?tags.Type=='Primary']")
  source_sa_name=$(echo "$source_sa_list" | jq -r '.[].name')
  source_blob=$(echo "$source_sa_list" | jq -r '.[].primaryEndpoints.blob')

  dest_sa_list=$(az storage account list --subscription "$DEST_SUB" --query "[?tags.Type=='Primary']")
  dest_sa_name=$(echo "$dest_sa_list" | jq -r '.[].name')
  dest_blob=$(echo "$dest_sa_list" | jq -r '.[].primaryEndpoints.blob')
fi

end=$(date -u -d "2 hours" '+%Y-%m-%dT%H:%MZ')

echo "🧱 Preparing to copy storage account contents"
echo "  Source: $source_sa_name ($source_blob @ $SOURCE_SUB)"
echo "  Dest:   $dest_sa_name ($dest_blob @ $DEST_SUB)"
echo "  Dry run: $DRY_RUN"
echo

for containerName in "ewp-attachments" "core-attachments" "reports" "file-storage" "nc-attachments" "integrator-plus-site-files"; do

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "✅ DRY RUN: Would copy $containerName"
    echo "  az storage container generate-sas --account-name $source_sa_name --name $containerName --permissions acdlrw --expiry $end --auth-mode login --as-user"
    echo "  az storage container generate-sas --account-name $dest_sa_name --name $containerName --permissions acdlrw --expiry $end --auth-mode login --as-user"
    echo
    echo "🧪 DRY RUN: Would copy blob using azcopy:"
    echo "  azcopy copy \"$source_blob$containerName?<source_sas>\" \"$dest_blob$containerName?<dest_sas>\" --recursive"
  else
    echo "⚙️ Copying $containerName"

    #generate SAS tokens
    source_sas=$(az storage container generate-sas --account-name "$source_sa_name" --name "$containerName" --permissions acdlrw --expiry "$end" --auth-mode login --as-user)
    source_sas=$(echo "$source_sas" | tr -d '"')
    dest_sas=$(az storage container generate-sas --account-name "$dest_sa_name" --name "$containerName" --permissions acdlrw --expiry "$end" --auth-mode login --as-user)
    dest_sas=$(echo "$dest_sas" | tr -d '"')

    # azcopy copy "$source_blob$containerName?$source_sas" "$dest_blob$containerName?$dest_sas" --recursive
  fi
done

echo "All containers copied successfully"
