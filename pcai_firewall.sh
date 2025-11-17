#!/bin/bash
# Connectivity check for required GreenLake & RedHat URLs (TCP-level)

# Ask or accept region input (default: jp1)
read -p "Enter region (e.g., jp1, us1, uk1, eu1) [default: jp1]: " REGION
REGION=${REGION:-jp1}

URLS=(
  "https://console.greenlake.hpe.com"
  "https://${REGION}.data.cloud.hpe.com"
  "https://tunnel-${REGION}.data.cloud.hpe.com"
  "https://console-${REGION}.data.cloud.hpe.com"
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
  "https://docs.opsramp.com"
  "https://pythonhosted.org"
  "https://files.pythonhosted.org"
  "https://pypi.python.org"
  "https://us-docker.pkg.dev"
  "https://docs.opsramp.com"
  "https://hooks.slack.com"
)

echo
echo "Checking TCP reachability for required URLs in region: ${REGION}"
echo "-------------------------------------------"

for url in "${URLS[@]}"; do
  host=$(echo "$url" | awk -F/ '{print $3}')
  printf "%-65s" "$host"

  if timeout 5 bash -c "</dev/tcp/$host/443" &>/dev/null; then
    echo "✅ Reachable"
  else
    echo "❌ Not reachable"
  fi
done

echo "-------------------------------------------"
echo "Check complete."
