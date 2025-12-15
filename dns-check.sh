
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

# For storing result summary
declare -a summary

index=1

while read -r ip fqdn _; do

    [[ -z "$ip" || -z "$fqdn" ]] && continue
    [[ "$ip" == "IP" ]] && continue   # Skip header row

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
    if [[ "$ptr_base" == "$input_base" && "$a_base" == "$input_base" ]]; then
        hostname_ok=true
    fi

    ip_ok=false
    if [[ "$a_ip" == "$ip" ]]; then
        ip_ok=true
    fi

    if $hostname_ok && $ip_ok; then
        echo "  ✅ TRUE — Forward & Reverse match (hostname + IP)"
        summary+=("[$index] $ip $fqdn => TRUE")
    else
        echo "  ❌ FALSE — mismatch"
        [[ "$ptr_base" != "$input_base" ]] && echo "     - PTR hostname ($ptr_base) != expected ($input_base)"
        [[ "$a_base" != "$input_base" ]] && echo "     - Forward hostname ($a_base) != expected ($input_base)"
        [[ "$a_ip" != "$ip" ]] && echo "     - A record IP ($a_ip) != expected IP ($ip)"

        summary+=("[$index] $ip $fqdn => FALSE")
    fi

    echo
    ((index++))

done < "$INPUT_FILE"

# Final Summary
echo
echo "============================================================="
echo "Final Summary (TRUE/FALSE for all entries)"
echo "============================================================="

for result in "${summary[@]}"; do
    echo "$result"
done

echo "============================================================="
