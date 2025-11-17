#!/bin/bash
# Unified Firewall Precheck Script (DEV + PCAI)

echo "Select System Type:"
echo "  1) dev   - Developer system firewall rules"
echo "  2) pcai  - Standard PCAI system firewall rules"
read -p "Enter choice [dev/pcai]: " MODE

if [[ "$MODE" != "dev" && "$MODE" != "pcai" ]]; then
  echo "Invalid choice. Use dev or pcai."
  exit 1
fi

# Region selection
read -p "Enter region (e.g., jp1, us1, uk1, eu1) [default: jp1]: " REGION
REGION=${REGION:-jp1}

# ------------------------------
# URL LISTS
# ------------------------------

if [[ "$MODE" == "dev" ]]; then
  echo "Selected: Developer System (minimal rules)"
  URLS=(
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
  )
else
  echo "Selected: Standard PCAI System (full firewall rules)"
  URLS=(
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
    "https://pythonhosted.org"
    "https://files.pythonhosted.org"
    "https://pypi.python.org"
    "https://docs.opsramp.com"
    "https://us-docker.pkg.dev"
    "https://hooks.slack.com"
  )
fi

echo
echo "Checking TCP reachability for required URLs (region: $REGION)"
echo "--------------------------------------------------------------"

for url in "${URLS[@]}"; do
  host=$(echo "$url" | awk -F/ '{print $3}')
  printf "%-65s" "$host"

  if timeout 5 bash -c "</dev/tcp/$host/443" &>/dev/null; then
    echo "✅ Reachable"
  else
    echo "❌ Not reachable"
  fi
done

echo "--------------------------------------------------------------"
echo "Firewall check complete."

