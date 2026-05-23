#!/bin/bash
# Connectivity & DNS Precheck Script (HPE GreenLake / RedHat / PCAI)
# Refined for HTTPS strictness and enterprise proxy environments.

echo "Select System Type:"
echo "  1) dev        - Developer system firewall rules"
echo "  2) pcai-gen1  - Standard PCAI system firewall rules"
echo "  3) pcai-gen2  - PCAI Gen2 system firewall rules"
echo
read -p "Enter choice [1/2/3]: " CHOICE

case "$CHOICE" in
  1) MODE="dev" ;;
  2) MODE="pcai-gen1" ;;
  3) MODE="pcai-gen2" ;;
  *) echo "Invalid choice. Exit."; exit 1 ;;
esac

read -p "Enter region (e.g., jp1, us1) [default: jp1]: " REGION
REGION=${REGION:-jp1}

# ------------------------------
# URL LISTS (Strict HTTPS used where provided)
# ------------------------------
COMMON_URLS=(
  "https://${REGION}.data.cloud.hpe.com" "https://tunnel-${REGION}.data.cloud.hpe.com"
  "https://console-${REGION}.data.cloud.hpe.com" "https://device.cloud.hpe.com"
  "https://common.cloud.hpe.com" "https://h30689.www3.hpe.com"
  "https://marketplace.us1.greenlake-hpe.com" "https://midway.ext.hpe.com"
  "https://solutionhub-metadata.s3.us-east-1.amazonaws.com"
  "https://gl-vas-harbor-prod-images.s3.us-west-2.amazonaws.com"
  "https://github.com/HPEEzmeral"
  "https://pypi.org" "https://authn.nvidia.com" "https://api.ngc.nvidia.com"
  "https://nvcr.io" "https://registry.ngc.nvidia.com" "https://ngc.download.nvidia.com"
  "https://catalog.ngc.nvidia.com" "https://login.nvidia.com"
)

case "$MODE" in
  dev)
    MODE_SPECIFIC_URLS=("https://subscription.rhsm.redhat.com" "https://cdn.redhat.com" "https://mirrors.fedoraproject.org") ;;
  pcai-gen1)
    MODE_SPECIFIC_URLS=("https://mirrors.fedoraproject.org" "https://subscription.rhsm.redhat.com" "https://cdn.redhat.com" "https://pythonhosted.org" "https://files.pythonhosted.org" "https://docs.opsramp.com" "https://us-docker.pkg.dev" "https://hooks.slack.com") ;;
  pcai-gen2)
    MODE_SPECIFIC_URLS=("https://pythonhosted.org" "https://files.pythonhosted.org" "https://docs.opsramp.com" "https://us-docker.pkg.dev" "https://s3.us-west-2.amazonaws.com" "https://hooks.slack.com" "https://update1.linux.hpe.com/repo/hpevme/") ;;
esac

URLS=("${COMMON_URLS[@]}" "${MODE_SPECIFIC_URLS[@]}")

# ------------------------------
# CONNECTIVITY CHECK
# ------------------------------
echo -e "\n--- Checking Connectivity (HTTPS Primary) ---"
PASS_COUNT=0
FAIL_COUNT=0

for url in "${URLS[@]}"; do
    # Extract host reliably and determine port
    host=$(echo "$url" | sed -e 's|^[^/]*//||' -e 's|/.*$||')
    
    # Check if URL explicitly uses http, otherwise default to 443 (HTTPS)
    if [[ "$url" =~ ^http:// ]]; then
        port=80
    else
        port=443
    fi

    printf "%-65s" "$host"

    # 1. Attempt curl (Best for HTTPS handshake & Proxies)
    if curl -skL --connect-timeout 5 "$url" -o /dev/null &>/dev/null; then
        echo "✅ Reachable (HTTPS)"
        ((PASS_COUNT++))
    # 2. Fallback to raw TCP (Useful if curl is missing or restricted)
    elif timeout 3 bash -c "</dev/tcp/$host/$port" &>/dev/null; then
        echo "✅ Reachable (TCP)"
        ((PASS_COUNT++))
    else
        echo "❌ FAILED"
        ((FAIL_COUNT++))
    fi
done
# ------------------------------
# DNS VALIDATION
# ------------------------------
INPUT_FILE="input.txt"

if [[ ! -f "$INPUT_FILE" ]]; then
    echo -e "\nNo '$INPUT_FILE' found. Skipping DNS checks."
else
    echo -e "\n--- DNS Forward/Reverse Validation ---"

    declare -a summary

    while IFS=$'\t' read -r ip fqdn node_type component_id record_type temp_ip; do

        # Skip empty/header/comment lines
        [[ -z "$ip" || "$ip" =~ ^# || "$ip" == "IP Address" ]] && continue

        # Trim spaces
        record_type=$(echo "$record_type" | xargs)

        # Skip wildcard direct validation
        if [[ "$fqdn" == \** ]]; then
            echo "⚠️ Wildcard DNS entry detected: $fqdn (Skipping validation)"
            summary+=("$ip $fqdn [$record_type] => SKIPPED-WILDCARD")
            continue
        fi

        # Forward lookup
        resolved_ip=$(getent hosts "$fqdn" | awk '{print $1}' | head -n1)

        # Reverse lookup
        resolved_name=$(getent hosts "$ip" | awk '{print $2}' | head -n1)

        # Normalize short hostnames
        input_base=$(echo "$fqdn" | cut -d. -f1 | tr '[:upper:]' '[:lower:]')
        res_base=$(echo "$resolved_name" | cut -d. -f1 | tr '[:upper:]' '[:lower:]')

        status="FALSE"

        # ---------------------------------------
        # A Record only
        # ---------------------------------------
        if [[ "$record_type" == "A Record" ]]; then

            if [[ "$resolved_ip" == "$ip" ]]; then
                status="TRUE"
                echo "✅ [A] $fqdn -> $ip"
            else
                echo "❌ [A] $fqdn mismatch (Resolved: $resolved_ip Expected: $ip)"
            fi

        # ---------------------------------------
        # A + PTR Record
        # ---------------------------------------
        elif [[ "$record_type" == "A and PTR Record" ]]; then

            if [[ "$resolved_ip" == "$ip" && "$input_base" == "$res_base" ]]; then
                status="TRUE"
                echo "✅ [A+PTR] $fqdn <-> $ip"
            else
                echo "❌ [A+PTR] $fqdn mismatch (A: $resolved_ip PTR: $resolved_name)"
            fi

        else
            echo "⚠️ Unknown record type for $fqdn : $record_type"
        fi

        summary+=("$ip $fqdn [$record_type] => $status")

    done < "$INPUT_FILE"
fi
# ------------------------------
# FINAL REPORT
# ------------------------------
echo -e "\n================ FINAL SUMMARY ================"
echo "Connectivity: ✅ $PASS_COUNT | ❌ $FAIL_COUNT"
if [[ ${#summary[@]} -gt 0 ]]; then
    echo "------------------------------------------------"
    for entry in "${summary[@]}"; do echo "$entry"; done
fi
echo "================================================"
