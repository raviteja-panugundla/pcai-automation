#!/bin/bash
# Improved connectivity check for required URLs

URLS=(
  "https://device.cloud.hpe.com"
  "https://common.cloud.hpe.com"
  "https://h30689.www3.hpe.com"
  "https://marketplace.us1.greenlake-hpe.com"
  "https://midway.ext.hpe.com"
  "https://subscription.rhn.redhat.com"
  "https://subscription.rhsm.redhat.com"
  "https://cdn.redhat.com"
  "https://solutionhub-metadata.s3.us-east-1.amazonaws.com"
  "https://gl-vas-harbor-prod-images.s3.us-west-2.amazonaws.com"
  "https://mirrors.fedoraproject.org"
  "https://github.com/HPEEzmeral"
  "https://pypi.org"
  "https://console.greenlake.hpe.com"
)

echo "Checking connectivity for required URLs..."
echo "-------------------------------------------"

for url in "${URLS[@]}"; do
  host=$(echo "$url" | awk -F/ '{print $3}')
  printf "%-65s" "$host"
  
  if curl -s -k -L --max-time 10 --output /dev/null "$url"; then
    echo "✅ Reachable"
  else
    echo "❌ Not reachable"
  fi
done

echo "-------------------------------------------"
echo "Check complete."
