#!/bin/bash

INPUT_FILE="input.txt"


# Check if input.txt exists
if [[ ! -f "$INPUT_FILE" ]]; then
    echo "❌ ERROR: '$INPUT_FILE' not found in the current directory."
    echo "Please create input.txt with format: <IP> <FQDN>"
    exit 1
fi

echo "DNS Forward/Reverse Validation - $(date)"
echo "-------------------------------------------------------------"

strip_domain() {
    echo "$1" | cut -d'.' -f1
}

while read -r ip fqdn; do
    [[ -z "$ip" || -z "$fqdn" ]] && continue

    echo "============================================================="
    echo "IP Address:   $ip"
    echo "FQDN:         $fqdn"
    echo "-------------------------------------------------------------"

    # Expected base hostname from input file
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

    # Hostname match rules
    hostname_ok=false
    if [[ "$ptr_base" == "$input_base" && "$a_base" == "$input_base" ]]; then
        hostname_ok=true
    fi

    ip_ok=false
    if [[ "$a_ip" == "$ip" ]]; then
        ip_ok=true
    fi

    if $hostname_ok && $ip_ok; then
        echo "  ✅ TRUE — Forward & Reverse match (hostname + IP)"
    else
        echo "  ❌ FALSE — mismatch"
        [[ "$ptr_base" != "$input_base" ]] && echo "     - PTR hostname ($ptr_base) != expected ($input_base)"
        [[ "$a_base" != "$input_base" ]] && echo "     - Forward hostname ($a_base) != expected ($input_base)"
        [[ "$a_ip" != "$ip" ]] && echo "     - A record IP ($a_ip) != expected IP ($ip)"
    fi

    echo

done < "$INPUT_FILE"
