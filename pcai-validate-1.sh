#!/bin/bash
# =============================================================================
# pcai-validate.sh — HPE PCAI E2E Network Validation Tool
# =============================================================================
# Usage:
#   bash pcai-validate.sh <networks-excel.xlsx> [OPTIONS]
#
# Options:
#   --local-only        Only validate the node this script runs on (no SSH)
#   --skip-firewall     Skip Phase 1 firewall/URL reachability checks
#   --skip-dns          Skip Phase 2 DNS forward/reverse checks
#   --skip-network      Skip Phase 3 network interface IP checks
#   --mode MODE         pcai-gen1 | pcai-gen2  (default: pcai-gen2)
#   --region REGION     jp1 | us1 | uk1 | eu1  (default: us1)
#   --ssh-user USER     SSH user for remote nodes (default: pcadmin)
#   --ssh-key FILE      Path to SSH private key
#
# One-liner on customer node (after SCP of xlsx):
#   bash <(curl -s https://raw.githubusercontent.com/raviteja-panugundla/pcai-automation/main/pcai-validate.sh) ~/networks-excel.xlsx
# =============================================================================

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
PASS="✅"; FAIL="❌"; WARN="⚠️ "; INFO="ℹ️ "

# ── Defaults ─────────────────────────────────────────────────────────────────
XLSX_FILE=""
LOCAL_ONLY=false
SKIP_FIREWALL=false
SKIP_DNS=false
SKIP_NETWORK=false
MODE="pcai-gen2"
REGION="us1"
SSH_USER="pcadmin"
SSH_KEY=""
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
declare -a FAILURES=()
TMPDIR_PCAI=$(mktemp -d /tmp/pcai-validate-XXXXXX)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# ── Argument Parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --local-only)    LOCAL_ONLY=true; shift ;;
    --skip-firewall) SKIP_FIREWALL=true; shift ;;
    --skip-dns)      SKIP_DNS=true; shift ;;
    --skip-network)  SKIP_NETWORK=true; shift ;;
    --mode)          MODE="$2"; shift 2 ;;
    --region)        REGION="$2"; shift 2 ;;
    --ssh-user)      SSH_USER="$2"; shift 2 ;;
    --ssh-key)       SSH_KEY="$2"; shift 2 ;;
    -*)              echo "Unknown option: $1"; exit 1 ;;
    *)               XLSX_FILE="$1"; shift ;;
  esac
done

if [[ -z "$XLSX_FILE" ]]; then
  echo -e "${RED}ERROR: No Excel file specified.${RESET}"
  echo "Usage: bash pcai-validate.sh <networks-excel.xlsx> [--local-only] [--mode pcai-gen2] [--region us1]"
  exit 1
fi

if [[ ! -f "$XLSX_FILE" ]]; then
  echo -e "${RED}ERROR: File not found: $XLSX_FILE${RESET}"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo -e "${RED}ERROR: python3 is required but not installed.${RESET}"
  exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=8 -o BatchMode=yes -o LogLevel=ERROR"
[[ -n "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

REPORT_FILE=""  # set after parsing xlsx (uses customer ID)

# ── Helper Functions ──────────────────────────────────────────────────────────
print_header() {
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  printf "║  %-60s║\n" "$1"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${RESET}"
}

print_section() {
  echo ""
  echo -e "${BOLD}${CYAN}─── $1 $(printf '─%.0s' {1..50} | head -c $((50 - ${#1})))${RESET}"
}

print_node_header() {
  echo ""
  echo -e "${BOLD}  ┌─ $1 ─┐${RESET}"
}

pass() { local msg="$1"; echo -e "    ${GREEN}${PASS} ${msg}${RESET}"; ((PASS_COUNT++)) || true; }
fail() { local msg="$1"; echo -e "    ${RED}${FAIL} ${msg}${RESET}"; ((FAIL_COUNT++)) || true; FAILURES+=("$msg"); }
warn() { local msg="$1"; echo -e "    ${YELLOW}${WARN} ${msg}${RESET}"; ((WARN_COUNT++)) || true; }
info() { local msg="$1"; echo -e "    ${CYAN}${INFO} ${msg}${RESET}"; }

tee_log() { tee -a "$REPORT_FILE"; }

# ── STEP 1: Parse xlsx with embedded Python ───────────────────────────────────
echo -e "${CYAN}Parsing Excel file: $XLSX_FILE ...${RESET}"

python3 << PYEOF
import zipfile, xml.etree.ElementTree as ET, re, sys, os

NS = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
TMPDIR = '${TMPDIR_PCAI}'
XLSX   = '${XLSX_FILE}'

def col_to_idx(col):
    r = 0
    for c in col.upper():
        r = r * 26 + (ord(c) - ord('A') + 1)
    return r - 1

try:
    with zipfile.ZipFile(XLSX) as z:
        files = {name: z.read(name) for name in z.namelist()}
except Exception as e:
    print(f"ERROR: Cannot open xlsx file: {e}", file=sys.stderr)
    sys.exit(1)

# Shared strings
shared = []
if 'xl/sharedStrings.xml' in files:
    root = ET.fromstring(files['xl/sharedStrings.xml'])
    for si in root.findall(f'{NS}si'):
        shared.append(''.join(t.text or '' for t in si.iter(f'{NS}t')))

# Sheet list
wb_root = ET.fromstring(files['xl/workbook.xml'])
sheet_list = {}
for sh in wb_root.iter(f'{NS}sheet'):
    name = sh.get('name')
    rid = sh.get('{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id')
    sheet_list[name] = rid

rels_root = ET.fromstring(files['xl/_rels/workbook.xml.rels'])
rel_map = {r.get('Id'): r.get('Target') for r in rels_root}

def read_sheet(name):
    rid = sheet_list.get(name)
    if not rid: return []
    target = rel_map.get(rid, '')
    ws_path = 'xl/' + target if not target.startswith('xl/') else target
    if ws_path not in files: return []
    ws_root = ET.fromstring(files[ws_path])
    rows = []
    for row in ws_root.iter(f'{NS}row'):
        cells = {}
        for cell in row.findall(f'{NS}c'):
            coord = cell.get('r', '')
            m = re.match(r'([A-Z]+)', coord)
            if not m: continue
            idx = col_to_idx(m.group(1))
            ct = cell.get('t', '')
            v = cell.find(f'{NS}v')
            istr = cell.find(f'{NS}is')
            if ct == 's' and v is not None and v.text:
                val = shared[int(v.text)] if int(v.text) < len(shared) else ''
            elif ct == 'inlineStr' and istr is not None:
                val = ''.join(t.text or '' for t in istr.iter(f'{NS}t'))
            elif v is not None and v.text:
                val = v.text
            else:
                val = None
            cells[idx] = val
        if cells:
            mx = max(cells.keys())
            rows.append([cells.get(i) for i in range(mx + 1)])
    return rows

# ── Interface purpose → DOCA interface name ───────────────────────────────────
PURPOSE_TO_IFACE = {
    'Worker Nodes Management':  'mgt@bond0',
    'Control Nodes Management': 'mgt@bond0',
    'Worker Nodes Data 1':      'stor0',
    'Worker Nodes Data 2':      'stor1',
    'Control Nodes Data':       'stor0',
    'Worker Nodes':             'prod@bond0',
}

# ── Parse General Info ────────────────────────────────────────────────────────
general = {}
for row in read_sheet('General-Info'):
    if row and len(row) >= 2 and row[0] and row[1] and row[0] != 'General-Info':
        general[str(row[0])] = str(row[1])

with open(f'{TMPDIR}/meta.env', 'w') as f:
    f.write(f"CUSTOMER_ID=\"{general.get('SCID Number','unknown')}\"\n")
    f.write(f"SOLUTION=\"{general.get('Solution','HPE PCAI')}\"\n")
    f.write(f"BASELINE=\"{general.get('Base Line','')}\"\n")

# ── Parse Node Inventory → nodes.tsv ─────────────────────────────────────────
# Format: comp_id \t hostname \t hw_model \t type \t mgt_ip \t stor0_ip \t stor1_ip \t prod_ip
with open(f'{TMPDIR}/nodes.tsv', 'w') as f:
    for row in read_sheet('Node Inventory'):
        if len(row) < 6 or not row[1] or row[0] == 'Rack ID': continue
        comp_id   = str(row[1]).strip()
        comp_type = str(row[2] or '').strip()
        hostname  = str(row[3] or '').strip()
        net_conns = str(row[5] or '').strip()
        hw_model  = str(row[6] if len(row) > 6 else '').strip()

        # Only process actual server nodes (DL325 / DL380a)
        if comp_type not in ('Server',): continue

        ifaces = {}
        for line in net_conns.split('\n'):
            line = line.strip()
            m = re.match(r'(.+)\[(.+)\]:(.+)', line)
            if m:
                purpose = m.group(2).strip()
                ip      = m.group(3).strip()
                iface   = PURPOSE_TO_IFACE.get(purpose)
                if iface:
                    ifaces[iface] = ip

        mgt  = ifaces.get('mgt@bond0', '')
        s0   = ifaces.get('stor0', '')
        s1   = ifaces.get('stor1', '')
        prod = ifaces.get('prod@bond0', '')

        f.write(f"{comp_id}\t{hostname}\t{hw_model}\t{comp_type}\t{mgt}\t{s0}\t{s1}\t{prod}\n")

# ── Parse GPU network prefixes → gpu_nets.tsv ─────────────────────────────────
# Format: iface \t ipv6_prefix
with open(f'{TMPDIR}/gpu_nets.tsv', 'w') as f:
    for i, sheet in enumerate(['GPU Compute Network 1', 'GPU Compute Network 2',
                                'GPU Compute Network 3', 'GPU Compute Network 4']):
        for row in read_sheet(sheet):
            if row and len(row) > 1 and row[1] and str(row[1]).startswith('fd7c'):
                prefix = ':'.join(str(row[1]).split(':')[:4]) + ':'
                f.write(f"gnd{i}\t{prefix}\n")
                break

# ── Parse DNS Entries → dns.tsv ───────────────────────────────────────────────
# Format: ip \t fqdn \t record_type
with open(f'{TMPDIR}/dns.tsv', 'w') as f:
    for row in read_sheet('DNS Entries'):
        if not row or len(row) < 2 or row[0] == 'IP Address' or not row[0]: continue
        ip          = str(row[0]).strip()
        fqdn        = str(row[1] or '').strip()
        record_type = str(row[4] or 'A Record only').strip() if len(row) > 4 else 'A Record only'
        if ip and fqdn:
            f.write(f"{ip}\t{fqdn}\t{record_type}\n")

# ── Parse Management Network → mgmt_net.env ──────────────────────────────────
with open(f'{TMPDIR}/mgmt_net.env', 'w') as f:
    for row in read_sheet('Management Network'):
        if row and row[0] == 'vLanId' and len(row) > 3:
            try:
                rows2 = read_sheet('Management Network')
                for r2 in rows2:
                    if r2 and r2[0] == 'vLanId' and len(r2) > 3:
                        continue
                    if r2 and r2[0] and str(r2[0]).replace('.','').isdigit():
                        f.write(f"MGMT_VLAN=\"{r2[0]}\"\n")
                        f.write(f"MGMT_NETWORK=\"{r2[1] or ''}\"\n")
                        f.write(f"MGMT_MASK=\"{r2[2] or ''}\"\n")
                        f.write(f"MGMT_GW=\"{r2[3] or ''}\"\n")
                        f.write(f"MGMT_DNS=\"{r2[5] or ''}\"\n")
                        f.write(f"MGMT_NTP=\"{r2[6] or ''}\"\n")
                        break
            except: pass
        break

print("PARSE_OK")
PYEOF

if [[ ! -f "${TMPDIR_PCAI}/nodes.tsv" ]]; then
  echo -e "${RED}ERROR: Failed to parse Excel file. Ensure it is a valid networks-excel.xlsx${RESET}"
  exit 1
fi

# Source parsed metadata
source "${TMPDIR_PCAI}/meta.env" 2>/dev/null || true

REPORT_FILE="pcai-validate-${CUSTOMER_ID}-${TIMESTAMP}.txt"

# ── Print Main Header ─────────────────────────────────────────────────────────
{
print_header "HPE PCAI E2E Validation Report"
echo -e "  ${BOLD}Customer ID : ${RESET}${CUSTOMER_ID}"
echo -e "  ${BOLD}Solution    : ${RESET}${SOLUTION}"
echo -e "  ${BOLD}Baseline    : ${RESET}${BASELINE}"
echo -e "  ${BOLD}Mode        : ${RESET}${MODE}"
echo -e "  ${BOLD}Region      : ${RESET}${REGION}"
echo -e "  ${BOLD}Date        : ${RESET}$(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  ${BOLD}Run on      : ${RESET}$(hostname -s) ($(hostname -I | awk '{print $1}'))"
echo -e "  ${BOLD}Excel file  : ${RESET}${XLSX_FILE}"
} | tee "$REPORT_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: FIREWALL / URL REACHABILITY
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_FIREWALL" == "false" ]]; then
  P1_PASS=0; P1_FAIL=0

  # Common URLs for all modes
  COMMON_URLS=(
    "https://${REGION}.data.cloud.hpe.com"
    "https://tunnel-${REGION}.data.cloud.hpe.com"
    "https://console-${REGION}.data.cloud.hpe.com"
    "https://device.cloud.hpe.com"
    "https://common.cloud.hpe.com"
    "https://marketplace.us1.greenlake-hpe.com"
    "https://solutionhub-metadata.s3.us-east-1.amazonaws.com"
    "https://gl-vas-harbor-prod-images.s3.us-west-2.amazonaws.com"
    "https://github.com"
    "https://raw.githubusercontent.com"
    "https://pypi.org"
  )

  # Mode-specific URLs
  if [[ "$MODE" == "pcai-gen2" ]]; then
    MODE_URLS=(
      "https://pythonhosted.org"
      "https://gateway.opsramp.net"
      "https://us-docker.pkg.dev"
      "https://authn.nvidia.com"
      "https://api.ngc.nvidia.com"
      "https://nvcr.io"
      "https://registry.ngc.nvidia.com"
      "https://ngc.download.nvidia.com"
      "https://catalog.ngc.nvidia.com"
      "https://login.nvidia.com"
      "https://update1.linux.hpe.com/repo/hpevme/"
    )
  else
    MODE_URLS=(
      "https://subscription.rhsm.redhat.com"
      "https://cdn.redhat.com"
      "https://pythonhosted.org"
      "https://gateway.opsramp.net"
      "https://us-docker.pkg.dev"
      "https://authn.nvidia.com"
      "https://api.ngc.nvidia.com"
      "https://nvcr.io"
    )
  fi

  ALL_URLS=("${COMMON_URLS[@]}" "${MODE_URLS[@]}")

  {
  print_section "PHASE 1: FIREWALL / URL REACHABILITY (Mode: ${MODE}, Region: ${REGION})"
  for url in "${ALL_URLS[@]}"; do
    host=$(echo "$url" | awk -F'/' '{print $3}')
    port=443
    # Try curl first
    if curl -k -s -o /dev/null --connect-timeout 5 -w "%{http_code}" "$url" 2>/dev/null | grep -qE '^[0-9]+$'; then
      pass "$(printf '%-55s' "$url")  REACHABLE (HTTPS)"
      ((P1_PASS++)) || true
    # TCP fallback
    elif (echo >/dev/tcp/$host/$port) &>/dev/null; then
      pass "$(printf '%-55s' "$url")  REACHABLE (TCP)"
      ((P1_PASS++)) || true
    else
      fail "$(printf '%-55s' "$url")  FAILED"
      ((P1_FAIL++)) || true
    fi
  done
  echo ""
  echo -e "  Phase 1 Result: ${GREEN}${P1_PASS} PASS${RESET}  ${RED}${P1_FAIL} FAIL${RESET}  (Total: ${#ALL_URLS[@]})"
  } | tee -a "$REPORT_FILE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: DNS VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_DNS" == "false" ]] && [[ -f "${TMPDIR_PCAI}/dns.tsv" ]]; then
  P2_PASS=0; P2_FAIL=0

  {
  print_section "PHASE 2: DNS FORWARD + REVERSE VALIDATION"

  while IFS=$'\t' read -r ip fqdn record_type; do
    [[ -z "$ip" || -z "$fqdn" ]] && continue
    label="$(printf '%-18s' "$ip") ↔ $(printf '%-45s' "$fqdn") [${record_type}]"

    # Forward lookup: FQDN → IP
    if [[ "$fqdn" == \** ]]; then
      # Wildcard entry — skip reverse, only check A record if possible
      resolved_ip=$(nslookup "$fqdn" 2>/dev/null | awk '/^Address:/ && !/#53/ {print $2; exit}')
      if [[ "$resolved_ip" == "$ip" ]]; then
        pass "$label  → Wildcard A ✓"
        ((P2_PASS++)) || true
      else
        warn "$label  → Wildcard (cannot fully verify)"
        ((P2_PASS++)) || true
      fi
      continue
    fi

    resolved_ip=$(getent hosts "$fqdn" 2>/dev/null | awk '{print $1; exit}')
    [[ -z "$resolved_ip" ]] && resolved_ip=$(nslookup "$fqdn" 2>/dev/null | awk '/^Address:/ && !/\#53/ {print $2; exit}')

    if [[ "$record_type" == "A Record only" ]]; then
      if [[ "$resolved_ip" == "$ip" ]]; then
        pass "$label  A ✓"
        ((P2_PASS++)) || true
      else
        fail "$label  A ✗ (resolved: ${resolved_ip:-NXDOMAIN})"
        ((P2_FAIL++)) || true
      fi
    else
      # A + PTR Record
      if [[ "$resolved_ip" != "$ip" ]]; then
        fail "$label  A ✗ (resolved: ${resolved_ip:-NXDOMAIN})"
        ((P2_FAIL++)) || true
        continue
      fi
      # Reverse lookup: IP → FQDN
      ptr_name=$(getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')
      [[ -z "$ptr_name" ]] && ptr_name=$(nslookup "$ip" 2>/dev/null | awk '/name =/ {print $NF}' | tr -d '.')
      fqdn_base="${fqdn%%.*}"
      ptr_base="${ptr_name%%.*}"
      if [[ "$ptr_base" == "$fqdn_base" ]] || [[ "$ptr_name" == "$fqdn" ]]; then
        pass "$label  A+PTR ✓"
        ((P2_PASS++)) || true
      else
        fail "$label  PTR ✗ (got: ${ptr_name:-NXDOMAIN})"
        ((P2_FAIL++)) || true
      fi
    fi
  done < "${TMPDIR_PCAI}/dns.tsv"

  echo ""
  echo -e "  Phase 2 Result: ${GREEN}${P2_PASS} PASS${RESET}  ${RED}${P2_FAIL} FAIL${RESET}"
  } | tee -a "$REPORT_FILE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: NETWORK INTERFACE IP VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════
if [[ "$SKIP_NETWORK" == "false" ]] && [[ -f "${TMPDIR_PCAI}/nodes.tsv" ]]; then
  P3_PASS=0; P3_FAIL=0
  MY_IP=$(hostname -I | awk '{print $1}')

  # Load GPU network prefixes
  declare -A GPU_PREFIXES=()
  while IFS=$'\t' read -r iface prefix; do
    GPU_PREFIXES["$iface"]="$prefix"
  done < "${TMPDIR_PCAI}/gpu_nets.tsv"

  # Function: extract IP for a given interface from ip -br a output
  get_iface_ip() {
    local output="$1" iface="$2"
    # Match exact interface name (anchor with ^)
    echo "$output" | awk -v iface="$iface" '
      $1 == iface {
        for(i=3;i<=NF;i++){
          split($i,a,"/")
          # Return first non-link-local IPv4 or IPv6 (not fe80)
          if(a[1] !~ /^fe80/ && a[1] !~ /^127\./){
            print a[1]; exit
          }
        }
      }'
  }

  get_iface_state() {
    local output="$1" iface="$2"
    echo "$output" | awk -v iface="$iface" '$1 == iface {print $2; exit}'
  }

  # Function: compare expected vs actual
  check_iface() {
    local iface="$1" actual_ip="$2" expected_ip="$3" state="$4" node_label="$5"
    local ip_label="$(printf '%-12s' "$iface")"

    if [[ -z "$state" ]]; then
      fail "${node_label} | ${ip_label} → interface NOT FOUND (expected IP: ${expected_ip})"
      ((P3_FAIL++)) || true
      return
    fi
    if [[ "$state" != "UP" ]]; then
      fail "${node_label} | ${ip_label} → state=${state} (expected: UP)"
      ((P3_FAIL++)) || true
    fi
    if [[ -z "$actual_ip" ]]; then
      fail "${node_label} | ${ip_label} → NO IP assigned (expected: ${expected_ip})"
      ((P3_FAIL++)) || true
    elif [[ "$actual_ip" == "$expected_ip" ]]; then
      pass "${node_label} | ${ip_label} ${state}   ${actual_ip}   (expected: ${expected_ip})"
      ((P3_PASS++)) || true
    else
      fail "${node_label} | ${ip_label} ${state}   got=${actual_ip}   expected=${expected_ip}   MISMATCH"
      ((P3_FAIL++)) || true
    fi
  }

  check_gpu_iface() {
    local iface="$1" actual_ip="$2" expected_prefix="$3" state="$4" node_label="$5"
    local ip_label="$(printf '%-12s' "$iface")"

    if [[ -z "$state" ]]; then
      warn "${node_label} | ${ip_label} → not present (GPU network may not be active)"
      return
    fi
    if [[ -z "$actual_ip" ]]; then
      warn "${node_label} | ${ip_label} → no IPv6 address (expected prefix: ${expected_prefix})"
    elif [[ "$actual_ip" == ${expected_prefix}* ]]; then
      pass "${node_label} | ${ip_label} ${state}   ${actual_ip}   prefix ✓ (${expected_prefix}...)"
      ((P3_PASS++)) || true
    else
      fail "${node_label} | ${ip_label} ${state}   got=${actual_ip}   expected prefix=${expected_prefix}   MISMATCH"
      ((P3_FAIL++)) || true
    fi
  }

  {
  print_section "PHASE 3: NETWORK INTERFACE IP VALIDATION"
  echo -e "  ${INFO} Comparing actual IPs (ip -br a) against networks-excel.xlsx"
  echo -e "  ${INFO} SSH User: ${SSH_USER}   Local-only: ${LOCAL_ONLY}"
  echo ""

  while IFS=$'\t' read -r comp_id hostname hw_model comp_type mgt_ip stor0_ip stor1_ip prod_ip; do
    [[ -z "$comp_id" ]] && continue

    # Determine node role
    if [[ "$hw_model" == "DL380a" ]]; then
      role="Worker"
    elif [[ "$hw_model" == "DL325" ]]; then
      role="Control"
    else
      role="Unknown"
    fi

    node_label="${comp_id} | ${hostname} | ${hw_model} | ${role}"
    print_node_header "${node_label}"

    # Get ip -br a output: local or remote
    ip_output=""
    is_local=false

    # Detect if this node is the one we're running on
    if [[ -n "$mgt_ip" ]] && hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$mgt_ip"; then
      is_local=true
    fi

    if [[ "$is_local" == "true" ]]; then
      info "Running locally on this node"
      ip_output=$(ip -br a 2>/dev/null)
    elif [[ "$LOCAL_ONLY" == "true" ]]; then
      warn "Skipping ${hostname} (--local-only mode, SSH skipped)"
      continue
    elif [[ -z "$mgt_ip" ]]; then
      warn "No management IP in Excel for ${hostname} — skipping"
      continue
    else
      info "SSH → ${SSH_USER}@${mgt_ip}"
      ip_output=$(ssh $SSH_OPTS "${SSH_USER}@${mgt_ip}" "ip -br a" 2>&1)
      if [[ $? -ne 0 ]]; then
        fail "${node_label} | SSH FAILED to ${mgt_ip} (check SSH keys / user: ${SSH_USER})"
        ((P3_FAIL++)) || true
        continue
      fi
    fi

    # Check mgt@bond0
    if [[ -n "$mgt_ip" ]]; then
      actual=$(get_iface_ip "$ip_output" "mgt@bond0")
      state=$(get_iface_state "$ip_output" "mgt@bond0")
      check_iface "mgt@bond0" "$actual" "$mgt_ip" "$state" "$node_label"
    fi

    # Check stor0
    if [[ -n "$stor0_ip" ]]; then
      actual=$(get_iface_ip "$ip_output" "stor0")
      state=$(get_iface_state "$ip_output" "stor0")
      check_iface "stor0" "$actual" "$stor0_ip" "$state" "$node_label"
    fi

    # Check stor1 (workers only)
    if [[ -n "$stor1_ip" ]]; then
      actual=$(get_iface_ip "$ip_output" "stor1")
      state=$(get_iface_state "$ip_output" "stor1")
      check_iface "stor1" "$actual" "$stor1_ip" "$state" "$node_label"
    fi

    # Check prod@bond0 (workers only)
    if [[ -n "$prod_ip" ]]; then
      actual=$(get_iface_ip "$ip_output" "prod@bond0")
      state=$(get_iface_state "$ip_output" "prod@bond0")
      check_iface "prod@bond0" "$actual" "$prod_ip" "$state" "$node_label"
    fi

    # Check GPU compute interfaces (gnd0, gnd1) for workers
    if [[ "$role" == "Worker" ]]; then
      for gnd_iface in gnd0 gnd1; do
        prefix="${GPU_PREFIXES[$gnd_iface]:-}"
        if [[ -n "$prefix" ]]; then
          actual=$(get_iface_ip "$ip_output" "$gnd_iface")
          state=$(get_iface_state "$ip_output" "$gnd_iface")
          check_gpu_iface "$gnd_iface" "$actual" "$prefix" "$state" "$node_label"
        fi
      done

      # Also check bond0 and slv0/slv1 exist (state check only)
      for bond_iface in bond0 slv0 slv1; do
        state=$(get_iface_state "$ip_output" "$bond_iface")
        if [[ -n "$state" ]]; then
          if [[ "$state" == "UP" ]]; then
            pass "${node_label} | $(printf '%-12s' "$bond_iface") ${state}   (interface present)"
            ((P3_PASS++)) || true
          else
            warn "${node_label} | $(printf '%-12s' "$bond_iface") ${state}   (expected: UP)"
          fi
        else
          warn "${node_label} | $(printf '%-12s' "$bond_iface") → not found (may not be configured yet)"
        fi
      done
    fi

  done < "${TMPDIR_PCAI}/nodes.tsv"

  echo ""
  echo -e "  Phase 3 Result: ${GREEN}${P3_PASS} PASS${RESET}  ${RED}${P3_FAIL} FAIL${RESET}  ${YELLOW}${WARN_COUNT} WARN${RESET}"
  } | tee -a "$REPORT_FILE"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# FINAL SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
{
echo ""
echo -e "${BOLD}${CYAN}"
echo "════════════════════════════════════════════════════════════════"
echo "  OVERALL VALIDATION SUMMARY"
echo "════════════════════════════════════════════════════════════════"
echo -e "${RESET}"
echo -e "  ${GREEN}${PASS} PASSED : ${PASS_COUNT}${RESET}"
echo -e "  ${RED}${FAIL} FAILED : ${FAIL_COUNT}${RESET}"
echo -e "  ${YELLOW}${WARN} WARNINGS: ${WARN_COUNT}${RESET}"
echo ""

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo -e "${RED}  Failed Checks:${RESET}"
  for f in "${FAILURES[@]}"; do
    echo -e "    ${RED}${FAIL} ${f}${RESET}"
  done
  echo ""
fi

if [[ $FAIL_COUNT -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}RESULT: ALL CHECKS PASSED ✅ — Infrastructure matches the plan${RESET}"
else
  echo -e "  ${RED}${BOLD}RESULT: ${FAIL_COUNT} CHECK(S) FAILED ❌ — Review failures above${RESET}"
fi

echo ""
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  Report saved: ${BOLD}${REPORT_FILE}${RESET}"
echo ""
} | tee -a "$REPORT_FILE"

# Cleanup temp files
rm -rf "${TMPDIR_PCAI}"

# Exit with failure if any checks failed
[[ $FAIL_COUNT -gt 0 ]] && exit 1 || exit 0
