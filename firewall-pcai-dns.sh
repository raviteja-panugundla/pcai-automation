#!/bin/bash
# Connectivity check for required GreenLake & RedHat URLs (TCP-level)
# Unified Firewall Precheck Script (DEV + PCAI + PCAI Gen2)

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
echo "Checking TCP reachability for required URLs (region: $REGION, mode: $MODE)"
echo "--------------------------------------------------------------------------------"

PASS_COUNT=0
FAIL_COUNT=0

for url in "${URLS[@]}"; do
  host=$(echo "$url" | awk -F/ '{print $3}')
  printf "%-70s" "$host"

  if timeout 5 bash -c "</dev/tcp/$host/443" &>/dev/null; then
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
#!/bin/bash

INPUT_FILE="input.txt"

# Check if input.txt exists
if [[ ! -f "$INPUT_FILE" ]]; then
    echo "❌ ERROR: '$INPUT_FILE' not found."
    exit 1
fi

echo "DNS Forward/Reverse Validation - $(date)"
echo "-------------------------------------------------------------"

strip_domain() {
    echo "$1" | cut -d'.' -f1
}

declare -a summary
index=1

# Regex to identify an IPv4 address
IP_REGEX="^([0-9]{1,3}\.){3}[0-9]{1,3}$"

# Read two columns generically as col1 and col2
while read -r col1 col2 _; do

    # Skip empty lines
    [[ -z "$col1" || -z "$col2" ]] && continue
    
    # Skip header row (if it contains "IP" or "FQDN" headers)
    [[ "$col1" == "IP" || "$col1" == "FQDN" ]] && continue

    # --- AUTO-DETECT LOGIC ---
    # Check if the first column matches the IP pattern
    if [[ $col1 =~ $IP_REGEX ]]; then
        ip="$col1"
        fqdn="$col2"
    else
        # If col1 isn't an IP, assume the file is FQDN first
        ip="$col2"
        fqdn="$col1"
    fi
    # -------------------------

    echo "============================================================="
    echo "IP Address:   $ip"
    echo "FQDN:         $fqdn"
    echo "-------------------------------------------------------------"

    input_base=$(strip_domain "$fqdn")

    ### Reverse Lookup ###
    echo "[Reverse Lookup] nslookup $ip"
    rev_out=$(nslookup "$ip" 2>&1)
    echo "$rev_out"
    echo

    ptr_name=$(echo "$rev_out" | awk '/name = /{print $NF}' | sed 's/\.$//')
    ptr_base=$(strip_domain "$ptr_name")

    [[ -n "$ptr_name" ]] && echo "Resolved Name (PTR): $ptr_name" \
                          || echo "Resolved Name (PTR): Not Found"
    echo

    ### Forward Lookup ###
    echo "[Forward Lookup] nslookup $fqdn"
    fwd_out=$(nslookup "$fqdn" 2>&1)
    echo "$fwd_out"
    echo

    a_ip=$(echo "$fwd_out" | awk '/Address: /{print $2}' | tail -1)
    a_base=$(strip_domain "$(echo "$fwd_out" | awk '/Name:/{print $2}' | sed 's/\.$//')")

    [[ -n "$a_ip" ]] && echo "Resolved IP (A): $a_ip" \
                      || echo "Resolved IP (A): No forward entry"
    echo

    ### Comparison ###
    echo "Comparison Result:"

    hostname_ok=false
    # Check if bases match OR if full FQDNs match (handling different domain suffixes)
    if [[ "$ptr_base" == "$input_base" && "$a_base" == "$input_base" ]]; then
        hostname_ok=true
    fi

    ip_ok=false
    if [[ "$a_ip" == "$ip" ]]; then
        ip_ok=true
    fi

    if $hostname_ok && $ip_ok; then
        echo "  ✅ TRUE — Forward & Reverse match"
        summary+=("[$index] $ip $fqdn => TRUE")
    else
        echo "  ❌ FALSE — mismatch"
        # Detailed error logging for summary can go here if needed
        summary+=("[$index] $ip $fqdn => FALSE")
    fi

    echo
    ((index++))

done < "$INPUT_FILE"

# Final Summary
echo
echo "============================================================="
echo "Final Summary (TRUE/FALSE)"
echo "============================================================="

for result in "${summary[@]}"; do
    echo "$result"
done

echo "============================================================="
