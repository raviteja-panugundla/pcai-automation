#!/bin/bash
# Connectivity check for required GreenLake & RedHat URLs (HTTP/HTTPS level)
# Unified Firewall Precheck Script (DEV + PCAI + PCAI Gen2)

echo "Select System Type:"
echo "  1) dev         - Developer system firewall rules"
echo "  2) pcai-gen1   - Standard PCAI system firewall rules"
echo "  3) pcai-gen2   - PCAI Gen2 system firewall rules"
echo
read -p "Enter choice [1/2/3]: " CHOICE

case "$CHOICE" in
  1) MODE="dev" ;;
  2) MODE="pcai-gen1" ;;
  3) MODE="pcai-gen2" ;;
  *)
    echo "Invalid choice. Use 1, 2, or 3."
    exit 1
    ;;
esac

# Region selection
read -p "Enter region (e.g., jp1, us1, uk1, eu1) [default: jp1]: " REGION
REGION=${REGION:-jp1}

# ------------------------------
# COMMON URLS (shared by all modes)
# ------------------------------
COMMON_URLS=(
  "https://${REGION}.data.cloud.hpe.com"
  "https://tunnel-${REGION}.data.cloud.hpe.com"
  "https://console-${REGION}.data.cloud.hpe.com"
  "https://device.cloud.hpe.com"
  "https://common.cloud.hpe.com"
  "https://h30689.www3.hpe.com"
  "https://marketplace.us1.greenlake-hpe.com"
  "https://midway.ext.hpe.com"
  "https://solutionhub-metadata.s3.us-east-1.amazonaws.com"
  "https://gl-vas-harbor-prod-images.s3.us-west-2.amazonaws.com"
  "https://mirrors.fedoraproject.org"
  "https://github.com/HPEEzmeral"
  "https://pypi.org"
)

# ------------------------------
# MODE-SPECIFIC URLS
# ------------------------------
case "$MODE" in
  dev)
    echo "Selected: Developer System (minimal rules)"
    MODE_SPECIFIC_URLS=(
      "https://subscription.rhn.redhat.com"
      "https://subscription.rhsm.redhat.com"
      "https://cdn.redhat.com"
    )
    ;;
   
  pcai-gen1)
    echo "Selected: Standard PCAI System (full firewall rules)"
    MODE_SPECIFIC_URLS=(
      "https://subscription.rhn.redhat.com"
      "https://subscription.rhsm.redhat.com"
      "https://cdn.redhat.com"
      "https://pythonhosted.org"
      "https://files.pythonhosted.org"
      "https://pypi.python.org"
      "https://docs.opsramp.com"
      "https://us-docker.pkg.dev"
      "https://hooks.slack.com"
    )
    ;;
   
  pcai-gen2)
    echo "Selected: PCAI Gen2 System (full firewall rules)"
    MODE_SPECIFIC_URLS=(
      "https://pythonhosted.org"
      "https://files.pythonhosted.org"
      "https://pypi.python.org"
      "https://docs.opsramp.com"
      "https://us-docker.pkg.dev"
      "https://s3.us-west-2.amazonaws.com"
      "https://hooks.slack.com"
    )
    ;;
esac

# Combine common and mode-specific URLs
URLS=("${COMMON_URLS[@]}" "${MODE_SPECIFIC_URLS[@]}")

echo
echo "Checking Reachability (using curl) for required URLs (region: $REGION, mode: $MODE)"
echo "--------------------------------------------------------------------------------"

PASS_COUNT=0
FAIL_COUNT=0

for url in "${URLS[@]}"; do
  # Print the URL clearly
  printf "%-70s" "$url"

  # Use curl to check connectivity
  # -k : Ignore SSL errors (matches your manual test)
  # -s : Silent mode (no progress bar)
  # -o /dev/null : Discard output
  # --connect-timeout 5 : Fail if it takes too long
  if curl -k -s -o /dev/null --connect-timeout 5 "$url"; then
    echo "✅ Reachable"
    ((PASS_COUNT++))
  else
    echo "❌ Not reachable"
    ((FAIL_COUNT++))
  fi
done

echo "--------------------------------------------------------------------------------"
echo "Firewall check complete."
echo "Summary: ✅ $PASS_COUNT passed | ❌ $FAIL_COUNT failed | Total: $((PASS_COUNT + FAIL_COUNT)) URLs"
