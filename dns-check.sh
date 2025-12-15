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
