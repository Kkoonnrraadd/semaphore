#!/bin/bash
# set -x
#create backup VM and point to that as source

while getopts d:s: flag; do
  case "${flag}" in
  d) dest=${OPTARG} ;;
  s) source=${OPTARG} ;;
  esac
done

if [ -z "$dest" ] || [ -z "$source" ]; then
  echo 'Missing -s (source env ie az003) or -d (destination env ie az002)' >&2
  exit 1
fi
source="${source^}"
dest="${dest^}"

source_pass=$(az keyvault secret show --name "sysadmin-${source,,}" --vault-name "kv-mnfro-customer-mnfro" --query value -o tsv)
dest_pass=$(az keyvault secret show --name "sysadmin-${dest,,}" --vault-name "kv-mnfro-customer-mnfro" --query value -o tsv)

echo "Go to https://$dest.manufacturo.us and reset sysadmin password with the below credentials"
echo "Don't forget to go onto Open VPN for this step"
echo "Old Password: $source_pass"
echo "The KV password for $dest is $dest_pass"
