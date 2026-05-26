#!/usr/bin/env python3
"""
pcai-validate.py — HPE PCAI Post-Install E2E Infrastructure Validation
=======================================================================
Usage:
  python3 pcai-validate.py <networks-excel.xlsx> <base-configuration.json> <infra-layout.json>

Options:
  --mode   pcai-gen1|pcai-gen2   (default: pcai-gen2)
  --region jp1|us1|uk1|eu1       (default: us1)
  --skip-firewall                skip Phase 6 URL checks
  --skip-dns                     skip Phase 5 DNS checks
  --ssh-user  <username>         override SSH username for all nodes
  --key-file  <path/privkey.pem> use SSH private key file for all nodes
  --cipher    <cipher>           SSH cipher override (e.g. aes256-ctr)

Examples:
  # Password auth (from infra-layout.json creds):
  python3 pcai-validate.py networks.xlsx base-configuration.json infra-layout.json

  # Key file auth for all nodes (workers use pcadmin + key):
  python3 pcai-validate.py networks.xlsx base-configuration.json infra-layout.json \\
      --ssh-user pcadmin --key-file privkey.pem --cipher aes256-ctr

  # Control nodes (hpesupport) — no global override, prompts if creds wrong

Stdlib only — no pip install needed.
Python 3.6+ required (pre-installed on RHEL 10 / Ubuntu 24).
"""

import sys, os, json, re, subprocess, select, time, getpass, socket
import zipfile, xml.etree.ElementTree as ET
import urllib.request, urllib.error, ssl
from datetime import datetime
from collections import defaultdict

# ══════════════════════════════════════════════════════════════════════════════
# COLORS & REPORT HELPERS
# ══════════════════════════════════════════════════════════════════════════════

RED    = '\033[0;31m'
GREEN  = '\033[0;32m'
YELLOW = '\033[1;33m'
CYAN   = '\033[0;36m'
BOLD   = '\033[1m'
RESET  = '\033[0m'

REPORT_LINES = []  # plain text lines for file output

def _tee(plain, colored=None):
    print(colored if colored else plain)
    REPORT_LINES.append(plain)

def ok(msg):
    _tee(f'    [PASS] {msg}', f'    {GREEN}✅ {msg}{RESET}')

def fail(msg):
    _tee(f'    [FAIL] {msg}', f'    {RED}❌ {msg}{RESET}')

def warn(msg):
    _tee(f'    [WARN] {msg}', f'    {YELLOW}⚠️  {msg}{RESET}')

def info(msg):
    _tee(f'    [INFO] {msg}', f'    {CYAN}ℹ️  {msg}{RESET}')

def skip(msg):
    _tee(f'    [SKIP] {msg}', f'    {YELLOW}⏭  {msg}{RESET}')

def section(title):
    line = f'\n─── {title} ' + '─' * max(1, 60 - len(title))
    _tee(line, f'\n{BOLD}{CYAN}{line}{RESET}')

def node_header(label):
    _tee(f'\n  ┌─ {label}', f'\n  {BOLD}┌─ {label}{RESET}')

def header(title, subtitle=''):
    lines = [
        '╔══════════════════════════════════════════════════════════════╗',
        f'║  {title:<60}║',
    ]
    if subtitle:
        lines.append(f'║  {subtitle:<60}║')
    lines.append('╚══════════════════════════════════════════════════════════╝')
    for l in lines:
        _tee(l, f'{BOLD}{CYAN}{l}{RESET}')


class Report:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.warned = 0
        self.skipped = 0
        self.failures = []

    def record(self, status, msg, node=''):
        label = f'[{node}] {msg}' if node else msg
        if status == 'ok':
            ok(msg); self.passed += 1
        elif status == 'fail':
            fail(msg); self.failed += 1; self.failures.append(label)
        elif status == 'warn':
            warn(msg); self.warned += 1
        elif status == 'skip':
            skip(msg); self.skipped += 1

    def summary(self):
        section('OVERALL SUMMARY')
        _tee(f'  PASSED  : {self.passed}',  f'  {GREEN}✅ PASSED  : {self.passed}{RESET}')
        _tee(f'  FAILED  : {self.failed}',  f'  {RED}❌ FAILED  : {self.failed}{RESET}')
        _tee(f'  WARNINGS: {self.warned}',  f'  {YELLOW}⚠️  WARNINGS: {self.warned}{RESET}')
        _tee(f'  SKIPPED : {self.skipped}', f'  {YELLOW}⏭  SKIPPED : {self.skipped}{RESET}')
        if self.failures:
            _tee('\n  Failed checks:')
            for f in self.failures:
                _tee(f'    ❌ {f}', f'    {RED}❌ {f}{RESET}')
        verdict = 'ALL CHECKS PASSED ✅' if self.failed == 0 else f'{self.failed} FAILURE(S) ❌ — review above'
        color = GREEN if self.failed == 0 else RED
        _tee(f'\n  RESULT: {verdict}', f'\n  {BOLD}{color}RESULT: {verdict}{RESET}')


R = Report()

# ══════════════════════════════════════════════════════════════════════════════
# XLSX PARSER  (zipfile + xml.etree — stdlib only)
# ══════════════════════════════════════════════════════════════════════════════

NS = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'

def _col_idx(col):
    r = 0
    for c in col.upper():
        r = r * 26 + (ord(c) - ord('A') + 1)
    return r - 1

def parse_xlsx(path):
    with zipfile.ZipFile(path) as z:
        files = {n: z.read(n) for n in z.namelist()}

    shared = []
    if 'xl/sharedStrings.xml' in files:
        root = ET.fromstring(files['xl/sharedStrings.xml'])
        for si in root.findall(f'{NS}si'):
            shared.append(''.join(t.text or '' for t in si.iter(f'{NS}t')))

    wb_root = ET.fromstring(files['xl/workbook.xml'])
    sheet_list = {}
    for sh in wb_root.iter(f'{NS}sheet'):
        rid = sh.get('{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id')
        sheet_list[sh.get('name')] = rid

    rels = ET.fromstring(files['xl/_rels/workbook.xml.rels'])
    rel_map = {r.get('Id'): r.get('Target') for r in rels}

    def read(name):
        rid = sheet_list.get(name)
        if not rid: return []
        target = rel_map.get(rid, '')
        ws_path = 'xl/' + target if not target.startswith('xl/') else target
        if ws_path not in files: return []
        ws = ET.fromstring(files[ws_path])
        rows = []
        for row in ws.iter(f'{NS}row'):
            cells = {}
            for cell in row.findall(f'{NS}c'):
                m = re.match(r'([A-Z]+)', cell.get('r', ''))
                if not m: continue
                idx = _col_idx(m.group(1))
                ct = cell.get('t', '')
                v  = cell.find(f'{NS}v')
                is_ = cell.find(f'{NS}is')
                if ct == 's' and v is not None and v.text:
                    val = shared[int(v.text)] if int(v.text) < len(shared) else ''
                elif ct == 'inlineStr' and is_ is not None:
                    val = ''.join(t.text or '' for t in is_.iter(f'{NS}t'))
                elif v is not None and v.text:
                    val = v.text
                else:
                    val = None
                cells[idx] = val
            if cells:
                mx = max(cells.keys())
                rows.append([cells.get(i) for i in range(mx + 1)])
        return rows

    return read


PURPOSE_IFACE = {
    'Worker Nodes Management':  'mgt@bond0',
    'Control Nodes Management': 'mgt@bond0',
    'Worker Nodes Data 1':      'stor0',
    'Worker Nodes Data 2':      'stor1',
    'Control Nodes Data':       'stor0',
    'Worker Nodes':             'prod@bond0',
}


def load_excel(path):
    read = parse_xlsx(path)

    # General info
    meta = {}
    for row in read('General-Info'):
        if row and len(row) >= 2 and row[0] and row[1] and row[0] != 'General-Info':
            meta[str(row[0])] = str(row[1])

    # Node Inventory → expected interfaces per server
    expected_nodes = {}
    for row in read('Node Inventory'):
        if len(row) < 6 or not row[1] or row[0] == 'Rack ID': continue
        comp_id   = str(row[1]).strip()
        comp_type = str(row[2] or '').strip()
        hostname  = str(row[3] or '').strip()
        net_conns = str(row[5] or '').strip()
        hw_model  = str(row[6] if len(row) > 6 else '').strip()
        if comp_type not in ('Server',): continue
        ifaces = {}
        for line in net_conns.split('\n'):
            m = re.match(r'(.+)\[(.+)\]:(.+)', line.strip())
            if m:
                iface = PURPOSE_IFACE.get(m.group(2).strip())
                if iface:
                    ifaces[iface] = m.group(3).strip()
        expected_nodes[comp_id] = {
            'hostname': hostname, 'hw_model': hw_model,
            'comp_type': comp_type, 'interfaces': ifaces
        }

    # GPU network prefixes
    gpu_prefixes = {}
    for i, sheet in enumerate(['GPU Compute Network 1', 'GPU Compute Network 2',
                                'GPU Compute Network 3', 'GPU Compute Network 4']):
        for row in read(sheet):
            if row and len(row) > 1 and row[1] and str(row[1]).startswith('fd7c'):
                gpu_prefixes[f'gnd{i}'] = ':'.join(str(row[1]).split(':')[:4]) + ':'
                break

    # DNS entries
    dns_entries = []
    for row in read('DNS Entries'):
        if not row or len(row) < 2 or row[0] == 'IP Address' or not row[0]: continue
        dns_entries.append({
            'ip': str(row[0]).strip(),
            'fqdn': str(row[1] or '').strip(),
            'record_type': str(row[4] or 'A Record only').strip() if len(row) > 4 else 'A Record only'
        })

    # Network gateways per sheet
    gateways = {}
    for net_name in ['Management Network', 'Storage Network', 'Production Network']:
        for row in read(net_name):
            if row and row[0] == 'vLanId': continue
            if row and row[0] and str(row[0]).replace('.', '').isdigit():
                gw = row[3] if len(row) > 3 else None
                if gw:
                    gateways[net_name] = str(gw)
                break

    return meta, expected_nodes, gpu_prefixes, dns_entries, gateways


# ══════════════════════════════════════════════════════════════════════════════
# JSON CONFIG PARSERS
# ══════════════════════════════════════════════════════════════════════════════

def load_configs(base_cfg_path, infra_layout_path):
    """
    Returns a dict keyed by componentId with:
      ilo_ip, mgmt_ip, hostname, ilo_hostname, hw_type, creds{}
    """
    with open(base_cfg_path) as f:
        base = json.load(f)
    with open(infra_layout_path) as f:
        layout = json.load(f)

    # Build creds map from infra-layout (keyed by componentId)
    creds_map = {}

    def extract_creds(comp):
        cid = comp.get('componentId')
        if not cid: return
        hw_type = comp.get('type', '')
        creds = {}
        for c in comp.get('accessCredentials', []):
            t = c.get('target', '')
            creds[t] = {'user': c.get('userName', ''), 'pass': c.get('password', '')}
        creds_map[cid] = {'hw_type': hw_type, 'creds': creds}

    for rack in layout.get('racks', []):
        for s in rack.get('servers', []): extract_creds(s)
        for sw in rack.get('networkSwitches', []): extract_creds(sw)
        for pdu in rack.get('pdus', []): extract_creds(pdu)
        for stor in rack.get('storageArrays', []):
            extract_creds(stor)
            for sw in stor.get('networkSwitches', []): extract_creds(sw)
            for enc in stor.get('enclosures', []):
                for n in enc.get('nodes', []): extract_creds(n)

    # Build IPs map from base-configuration (keyed by componentId)
    nodes = {}

    def extract_ips(comp, extra=None):
        cid = comp.get('componentId')
        if not cid: return
        ilo_ip, mgmt_ip = '', ''
        for nc in comp.get('networkConnections', []):
            ip = (nc.get('ipAddress') or '').strip()
            purpose = nc.get('purpose', '')
            if not ip: continue
            if 'iLO Management' in purpose and 'Storage' not in purpose:
                ilo_ip = ip
            if purpose in ('Control Nodes Management', 'Worker Nodes Management',
                           'Network Management', 'Storage Management'):
                mgmt_ip = ip

        cm = creds_map.get(cid, {})
        nodes[cid] = {
            'ilo_ip':       ilo_ip,
            'mgmt_ip':      mgmt_ip,
            'hostname':     comp.get('hostName', ''),
            'ilo_hostname': comp.get('iloHostName', ''),
            'hw_type':      cm.get('hw_type', extra or ''),
            'creds':        cm.get('creds', {}),
            'comp_id':      cid,
        }

    for rack in base.get('infrastructure', {}).get('racks', []):
        for s in rack.get('servers', []): extract_ips(s)
        for sw in rack.get('networkSwitches', []): extract_ips(sw)
        for pdu in rack.get('pdus', []): extract_ips(pdu)
        for stor in rack.get('storageArrays', []):
            extract_ips(stor, 'Storage')
            for enc in stor.get('enclosures', []):
                for n in enc.get('nodes', []): extract_ips(n)

    return nodes


# ══════════════════════════════════════════════════════════════════════════════
# SSH HELPER  (sshpass → pty fallback, stdlib only)
# ══════════════════════════════════════════════════════════════════════════════

_SSHPASS_AVAIL = None

def _has_sshpass():
    global _SSHPASS_AVAIL
    if _SSHPASS_AVAIL is None:
        _SSHPASS_AVAIL = subprocess.run(
            ['which', 'sshpass'], capture_output=True).returncode == 0
    return _SSHPASS_AVAIL


def _ssh_sshpass(host, user, password, command, timeout=30):
    try:
        r = subprocess.run(
            ['sshpass', '-p', password, 'ssh',
             '-o', 'StrictHostKeyChecking=no',
             '-o', f'ConnectTimeout={min(timeout, 10)}',
             '-o', 'PasswordAuthentication=yes',
             '-o', 'PreferredAuthentications=password',
             '-o', 'LogLevel=ERROR',
             f'{user}@{host}', command],
            capture_output=True, text=True, timeout=timeout)
        if 'Permission denied' in r.stderr or 'Authentication failed' in r.stderr:
            return '', 1, 'auth_failed'
        if 'Connection refused' in r.stderr or 'No route to host' in r.stderr:
            return '', 1, 'unreachable'
        return r.stdout.strip(), r.returncode, 'ok'
    except subprocess.TimeoutExpired:
        return '', -1, 'timeout'
    except Exception as e:
        return '', -1, f'error: {e}'


def _ssh_pty(host, user, password, command, timeout=30):
    import pty
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        ['ssh',
         '-o', 'StrictHostKeyChecking=no',
         '-o', f'ConnectTimeout={min(timeout, 10)}',
         '-o', 'PasswordAuthentication=yes',
         '-o', 'PreferredAuthentications=password,keyboard-interactive',
         '-o', 'NumberOfPasswordPrompts=1',
         '-o', 'LogLevel=ERROR',
         '-tt', f'{user}@{host}', command],
        stdin=slave, stdout=slave, stderr=slave,
        preexec_fn=os.setsid, close_fds=True)
    os.close(slave)

    output = b''
    password_sent = False
    start = time.time()

    while True:
        if time.time() - start > timeout:
            proc.kill()
            break
        r, _, _ = select.select([master], [], [], 0.4)
        if r:
            try:
                chunk = os.read(master, 4096)
                output += chunk
            except OSError:
                break

            if not password_sent:
                if re.search(rb'[Pp]assword.*:', output):
                    time.sleep(0.2)  # let prompt fully flush
                    try:
                        os.write(master, password.encode() + b'\n')
                    except OSError:
                        break
                    password_sent = True
                    output = b''
                    time.sleep(0.5)  # give command time to start executing
                elif re.search(rb'[Pp]ermission denied|[Aa]uth.*fail', output):
                    proc.kill()
                    try: os.close(master)
                    except: pass
                    return '', 1, 'auth_failed'
                elif re.search(rb'[Cc]onnection refused|[Nn]o route|timed out', output):
                    proc.kill()
                    try: os.close(master)
                    except: pass
                    return '', 1, 'unreachable'
        elif proc.poll() is not None:
            # Process finished — drain remaining output (give pty buffer time to flush)
            time.sleep(0.3)
            try:
                while True:
                    r2, _, _ = select.select([master], [], [], 0.3)
                    if r2:
                        try: output += os.read(master, 4096)
                        except OSError: break
                    else:
                        break
            except: pass
            break

    try: os.close(master)
    except: pass

    if re.search(rb'[Pp]ermission denied|[Aa]uth.*fail', output):
        return '', 1, 'auth_failed'

    clean = re.sub(rb'\x1b\[[0-9;]*[a-zA-Z]', b'', output)  # strip ANSI
    clean = re.sub(rb'\r\n|\r', b'\n', clean)
    text  = clean.decode(errors='ignore')
    # Strip shell prompt lines (e.g. "user@host:~$ ") from output
    text  = re.sub(r'^[^\n]*@[^\n]*[\$#]\s*', '', text, flags=re.MULTILINE)
    return text.strip(), proc.poll() or 0, 'ok'


def _ssh_keyfile(host, user, key_file, command, timeout=30, cipher=None):
    """SSH using private key file (no password needed). Returns (output, rc, status)."""
    cmd = ['ssh',
           '-o', 'StrictHostKeyChecking=no',
           '-o', f'ConnectTimeout={min(timeout, 10)}',
           '-o', 'BatchMode=yes',
           '-o', 'LogLevel=ERROR',
           '-i', key_file]
    if cipher:
        cmd += ['-c', cipher]
    cmd += [f'{user}@{host}', command]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if 'Permission denied' in r.stderr or 'invalid key' in r.stderr.lower():
            return '', 1, 'auth_failed'
        if 'Connection refused' in r.stderr or 'No route to host' in r.stderr:
            return '', 1, 'unreachable'
        out = r.stdout.strip()
        return out, r.returncode, 'ok'
    except subprocess.TimeoutExpired:
        return '', -1, 'timeout'
    except Exception as e:
        return '', -1, f'error: {e}'


def ssh_run(host, user, command, timeout=30, password=None, key_file=None, cipher=None):
    """Run SSH command. Supports password auth or key file. Returns (output, rc, status)"""
    if key_file:
        return _ssh_keyfile(host, user, key_file, command, timeout, cipher)
    if _has_sshpass() and password:
        return _ssh_sshpass(host, user, password, command, timeout)
    if password:
        return _ssh_pty(host, user, password, command, timeout)
    return '', 1, 'auth_failed'


# ══════════════════════════════════════════════════════════════════════════════
# AUTH MANAGER — tries base-config creds, prompts on failure
# ══════════════════════════════════════════════════════════════════════════════

class AuthManager:
    def __init__(self, nodes):
        self.nodes     = nodes      # from load_configs()
        self._override = {}         # comp_id -> {'user':..,'pass':..,'key_file':..,'cipher':..}

    def _os_creds(self, comp_id):
        """Get OS SSH credentials for a node (from config or override)."""
        if comp_id in self._override:
            return self._override[comp_id]
        creds = self.nodes.get(comp_id, {}).get('creds', {})
        for target in ['OS', 'HOST']:
            if target in creds and (creds[target].get('pass') or creds[target].get('key_file')):
                return creds[target]
        return None

    def _ilo_creds(self, comp_id):
        creds = self.nodes.get(comp_id, {}).get('creds', {})
        return creds.get('ILO') or creds.get('ILO_FACTORY_DEFAULT')

    def _do_ssh(self, host, creds, command, timeout):
        """Run SSH using whatever auth method is in creds dict."""
        return ssh_run(
            host, creds['user'], command, timeout,
            password=creds.get('pass'),
            key_file=creds.get('key_file'),
            cipher=creds.get('cipher'),
        )

    def _prompt_auth(self, hostname, host, current_user):
        """
        Interactive prompt when auth fails.
        Returns new creds dict or None to skip.
        """
        print(f'\n  {YELLOW}⚠️  Auth failed for {hostname} ({host}) as {current_user}{RESET}')
        print(f'  Options:')
        print(f'    1) Enter different username + password')
        print(f'    2) Use SSH private key file')
        print(f'    Enter = skip this node')
        try:
            choice = input('  Choice [1/2/Enter to skip]: ').strip()
        except (EOFError, KeyboardInterrupt):
            return None

        if choice == '1':
            try:
                new_user = input(f'  Username [{current_user}]: ').strip() or current_user
                new_pass = getpass.getpass(f'  Password for {new_user}@{host}: ')
            except (EOFError, KeyboardInterrupt):
                return None
            return {'user': new_user, 'pass': new_pass} if new_pass else None

        elif choice == '2':
            try:
                key_path = input('  Path to private key file (e.g. privkey.pem): ').strip()
                new_user = input(f'  Username [{current_user}]: ').strip() or current_user
                cipher   = input('  Cipher (Enter for default, e.g. aes256-ctr): ').strip() or None
            except (EOFError, KeyboardInterrupt):
                return None
            if not key_path or not os.path.exists(key_path):
                print(f'  {RED}Key file not found: {key_path}{RESET}')
                return None
            return {'user': new_user, 'key_file': key_path, 'cipher': cipher}

        return None

    def ssh(self, comp_id, command, timeout=30):
        """
        SSH to node's mgmt IP. Returns (output, status).
        Prompts interactively if auth fails (offers password or key file).
        status: 'ok' | 'auth_failed' | 'unreachable' | 'skipped' | 'timeout'
        """
        node     = self.nodes.get(comp_id, {})
        host     = node.get('mgmt_ip', '')
        hostname = node.get('hostname', comp_id)

        if not host:
            warn(f'{hostname}: no management IP — skipping')
            return '', 'skipped'

        creds = self._os_creds(comp_id)
        if not creds:
            # No creds at all — prompt immediately
            print(f'\n  {YELLOW}⚠️  No credentials found for {hostname} ({host}){RESET}')
            creds = self._prompt_auth(hostname, host, 'root')
            if not creds:
                skip(f'{hostname} — SKIPPED (no credentials)')
                return '', 'skipped'

        out, rc, status = self._do_ssh(host, creds, command, timeout)

        if status == 'auth_failed':
            new_creds = self._prompt_auth(hostname, host, creds.get('user', '?'))
            if not new_creds:
                skip(f'{hostname} ({host}) — SKIPPED (auth failed)')
                return '', 'skipped'

            out, rc, status = self._do_ssh(host, new_creds, command, timeout)
            if status == 'ok':
                self._override[comp_id] = new_creds
            else:
                fail(f'{hostname} ({host}) — auth still failed after retry')
                return '', 'auth_failed'

        if status == 'unreachable':
            fail(f'{hostname} ({host}) — UNREACHABLE (check IP/network)')
            return '', 'unreachable'

        if status == 'timeout':
            fail(f'{hostname} ({host}) — SSH TIMEOUT')
            return '', 'timeout'

        return out, 'ok'

    def redfish(self, comp_id, path='/redfish/v1/Systems/1'):
        """GET Redfish endpoint on iLO. Returns (dict|None, status)."""
        node = self.nodes.get(comp_id, {})
        ilo_ip = node.get('ilo_ip', '')
        if not ilo_ip:
            return None, 'no_ilo_ip'
        creds = self._ilo_creds(comp_id)
        if not creds:
            return None, 'no_creds'
        url = f'https://{ilo_ip}{path}'
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        req = urllib.request.Request(url)
        import base64
        auth = base64.b64encode(f"{creds['user']}:{creds.get('pass','')}".encode()).decode()
        req.add_header('Authorization', f'Basic {auth}')
        req.add_header('Accept', 'application/json')
        try:
            with urllib.request.urlopen(req, timeout=10, context=ctx) as resp:
                return json.loads(resp.read()), 'ok'
        except urllib.error.HTTPError as e:
            return None, f'http_{e.code}'
        except Exception as e:
            return None, f'error: {e}'


# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — iLO REACHABILITY
# ══════════════════════════════════════════════════════════════════════════════

def phase1_ilo_reachability(nodes):
    section('PHASE 1 — iLO REACHABILITY')
    for comp_id, node in nodes.items():
        ilo_ip = node.get('ilo_ip', '')
        hostname = node.get('hostname', comp_id)
        ilo_host = node.get('ilo_hostname', '')
        if not ilo_ip:
            continue
        label = f'{hostname} | iLO {ilo_host} ({ilo_ip})'
        # TCP check on port 443
        try:
            s = socket.create_connection((ilo_ip, 443), timeout=5)
            s.close()
            R.record('ok', f'{label} — REACHABLE', hostname)
        except Exception:
            R.record('fail', f'{label} — NOT REACHABLE (check VLAN/IP)', hostname)


# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — iLO REDFISH: MODEL, HOSTNAME, HEALTH
# ══════════════════════════════════════════════════════════════════════════════

def phase2_redfish(nodes, expected_nodes, auth):
    section('PHASE 2 — HARDWARE VALIDATION (iLO Redfish)')
    for comp_id, node in nodes.items():
        hw_type   = node.get('hw_type', '')
        hostname  = node.get('hostname', comp_id)
        ilo_host  = node.get('ilo_hostname', '')
        ilo_ip    = node.get('ilo_ip', '')
        if not ilo_ip or not hw_type:
            continue

        node_header(f'{comp_id} | {hostname} | {hw_type}')

        data, status = auth.redfish(comp_id, '/redfish/v1/Systems/1')
        if status != 'ok' or not data:
            R.record('warn', f'{hostname} — Redfish unavailable ({status})', hostname)
            continue

        # Model check
        actual_model = data.get('Model', '') or data.get('model', '')
        expected_type = expected_nodes.get(comp_id, {}).get('hw_model', hw_type)
        if expected_type and expected_type.upper() in actual_model.upper():
            R.record('ok', f'Model: {actual_model} (expected: {expected_type})', hostname)
        elif actual_model:
            R.record('fail',
                f'Model mismatch: got "{actual_model}", expected "{expected_type}"', hostname)
        else:
            R.record('warn', f'Model not returned by Redfish', hostname)

        # Power state
        power = data.get('PowerState', '')
        if power == 'On':
            R.record('ok', f'PowerState: On', hostname)
        else:
            R.record('fail', f'PowerState: {power} (expected: On)', hostname)

        # Health
        health = (data.get('Status') or {}).get('Health', '')
        if health == 'OK':
            R.record('ok', f'Health: OK', hostname)
        elif health:
            R.record('warn', f'Health: {health} (expected: OK)', hostname)

        # iLO hostname
        mgr_data, mgr_status = auth.redfish(comp_id, '/redfish/v1/Managers/1')
        if mgr_status == 'ok' and mgr_data:
            actual_ilo_hostname = mgr_data.get('HostName', '')
            if ilo_host and actual_ilo_hostname:
                if actual_ilo_hostname.lower().startswith(ilo_host.lower().split('.')[0]):
                    R.record('ok', f'iLO hostname: {actual_ilo_hostname}', hostname)
                else:
                    R.record('fail',
                        f'iLO hostname: got "{actual_ilo_hostname}", expected "{ilo_host}"',
                        hostname)


# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — OS: HOSTNAME, INTERFACES (ip -br a), BONDS
# ══════════════════════════════════════════════════════════════════════════════

def _extract_ip(ip_br_output, iface):
    """Extract first non-link-local IP for an interface from ip -br a output.
    Also does fuzzy matching for VLAN-tagged variants (e.g. bond0.2022@bond0 for mgt@bond0)."""
    lines = ip_br_output.splitlines()

    # Exact match first
    for line in lines:
        parts = line.split()
        if not parts or parts[0] != iface:
            continue
        for part in parts[2:]:
            addr = part.split('/')[0]
            if not addr.startswith('fe80') and not addr.startswith('127.'):
                return addr, parts[1] if len(parts) > 1 else ''

    # Fuzzy match: strip VLAN tags — e.g. "bond0.2022@bond0" matches "mgt@bond0"
    # strategy: if expected iface is X@Y, look for anything@Y or X.NNNN@Y
    if '@' in iface:
        base_alias, base_dev = iface.split('@', 1)
        for line in lines:
            parts = line.split()
            if not parts: continue
            name = parts[0]
            if name.endswith(f'@{base_dev}') and name != iface:
                for part in parts[2:]:
                    addr = part.split('/')[0]
                    if not addr.startswith('fe80') and not addr.startswith('127.'):
                        return addr, (parts[1] if len(parts) > 1 else '') + f'[as {name}]'

    return '', ''


def _get_all_ifaces(ip_br_output):
    """Return list of all interface names from ip -br a output."""
    names = []
    for line in ip_br_output.splitlines():
        parts = line.split()
        if parts and re.match(r'[a-zA-Z0-9@._\-]+', parts[0]):
            names.append(parts[0])
    return names


def phase3_network_interfaces(nodes, expected_nodes, gpu_prefixes, auth):
    section('PHASE 3 — NETWORK INTERFACE VALIDATION (ip -br a)')

    # Collect all checks per server
    server_nodes = {k: v for k, v in nodes.items()
                    if k.startswith('server-') and v.get('mgmt_ip')}

    for comp_id, node in sorted(server_nodes.items()):
        hostname  = node.get('hostname', comp_id)
        hw_type   = node.get('hw_type', '')
        node_header(f'{comp_id} | {hostname} | {hw_type}')

        # Combine hostname + ip -br a in single SSH call to avoid pty timing issues
        combined_out, status = auth.ssh(comp_id,
            "echo '===HOSTNAME==='; hostname -s; echo '===IFACES==='; ip -br a")
        if status != 'ok':
            R.record(status, f'{hostname} — {status.upper()}', hostname)
            continue

        # Split combined output.
        # pty's -tt echoes the command back, which also contains the marker strings.
        # Use rfind to always pick the LAST occurrence (actual echo output, not command echo).
        hn_out = ''
        out = combined_out
        hi = combined_out.rfind('===HOSTNAME===')
        ii = combined_out.rfind('===IFACES===')
        if hi != -1 and ii != -1 and hi < ii:
            hn_section = combined_out[hi + len('===HOSTNAME==='):ii]
            out = combined_out[ii + len('===IFACES==='):]
            hn_lines = [l.strip() for l in hn_section.splitlines()
                        if l.strip() and '@' not in l and not l.strip().startswith('$')]
            hn_out = hn_lines[-1] if hn_lines else ''

        expected = expected_nodes.get(comp_id, {})
        exp_ifaces = expected.get('interfaces', {})

        # Hostname check
        expected_hn = expected.get('hostname', '')
        if expected_hn:
            if hn_out.lower() == expected_hn.lower():
                R.record('ok', f'Hostname: {hn_out}', hostname)
            else:
                R.record('fail',
                    f'Hostname: got "{hn_out}", expected "{expected_hn}"', hostname)

        # Interface IP checks
        found_any_iface = bool(_get_all_ifaces(out))
        for iface, expected_ip in exp_ifaces.items():
            actual_ip, state = _extract_ip(out, iface)
            # Strip fuzzy match marker from state for comparison
            state_clean = state.split('[')[0].strip()
            label = f'{iface:<14} {state_clean:<6} {actual_ip or "NO IP":<20}'

            if not actual_ip and not state:
                if not found_any_iface:
                    R.record('warn',
                        f'{iface}: no interfaces captured (SSH output empty?)', hostname)
                else:
                    R.record('fail',
                        f'{iface}: NOT FOUND (expected {expected_ip})', hostname)
            elif 'UP' not in state_clean:
                R.record('fail',
                    f'{iface}: state={state_clean} (expected UP)', hostname)
            elif actual_ip == expected_ip:
                fuzzy = f' [matched as {state.split("[as ")[-1].rstrip("]")}]' if '[as ' in state else ''
                R.record('ok', f'{label}expected={expected_ip}  ✓{fuzzy}', hostname)
            else:
                R.record('fail',
                    f'{iface}: got={actual_ip}, expected={expected_ip}  MISMATCH', hostname)

        # Show actual interfaces found (helpful when expected names don't match)
        if not found_any_iface and exp_ifaces:
            R.record('warn', f'No interfaces in SSH output — check SSH auth', hostname)
        elif found_any_iface and any(
                not _extract_ip(out, iface)[1] for iface in exp_ifaces):
            actual_names = _get_all_ifaces(out)
            info(f'  Interfaces found on {hostname}: {", ".join(actual_names)}')

        # GPU compute prefix checks (workers only)
        if 'DL380a' in hw_type or 'pcai' in node.get('hw_type','').lower():
            for gnd, prefix in gpu_prefixes.items():
                actual_ip, state = _extract_ip(out, gnd)
                if not state:
                    R.record('warn', f'{gnd}: not found (GPU may not be active)', hostname)
                elif actual_ip.startswith(prefix):
                    R.record('ok', f'{gnd:<14} {state:<6} {actual_ip}  prefix={prefix}✓', hostname)
                else:
                    R.record('fail',
                        f'{gnd}: got={actual_ip}, expected prefix={prefix}', hostname)

            # Bond & slave interface state checks
            for bond_iface in ('bond0', 'slv0', 'slv1'):
                _, state = _extract_ip(out, bond_iface)
                if state == 'UP':
                    R.record('ok', f'{bond_iface}: UP', hostname)
                elif state:
                    R.record('warn', f'{bond_iface}: state={state} (expected UP)', hostname)
                else:
                    R.record('warn', f'{bond_iface}: not found', hostname)


# ══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — GATEWAY REACHABILITY (ping from each worker)
# ══════════════════════════════════════════════════════════════════════════════

def phase4_gateway_ping(nodes, gateways, auth):
    section('PHASE 4 — GATEWAY REACHABILITY')
    # Run from workers (have OS)
    worker_ids = [k for k, v in nodes.items()
                  if k.startswith('server-') and 'DL380a' in v.get('hw_type','')]
    if not worker_ids:
        R.record('warn', 'No worker nodes found for gateway ping')
        return

    # Use first available worker
    for comp_id in worker_ids:
        for net_name, gw in gateways.items():
            if not gw: continue
            hostname = nodes[comp_id].get('hostname', comp_id)
            out, status = auth.ssh(comp_id, f'ping -c 2 -W 3 {gw}')
            label = f'{net_name} gateway {gw} (from {hostname})'
            if status != 'ok':
                R.record('warn', f'{label} — SSH unavailable, skipping', hostname)
                break
            if '2 received' in out or '2 packets received' in out or \
               '1 received' in out:
                R.record('ok', f'{label} — REACHABLE', hostname)
            else:
                R.record('fail', f'{label} — NOT REACHABLE', hostname)
        break  # one worker is enough for gateway check


# ══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — DNS VALIDATION
# ══════════════════════════════════════════════════════════════════════════════

def phase5_dns(nodes, dns_entries, auth):
    section('PHASE 5 — DNS FORWARD + REVERSE VALIDATION')
    # Run from first available worker
    worker = next((k for k, v in nodes.items()
                   if k.startswith('server-') and 'DL380a' in v.get('hw_type','')), None)
    if not worker:
        R.record('warn', 'No worker available for DNS checks'); return

    # Deduplicate DNS entries by (ip, fqdn) pair to avoid double-checking
    seen = set()
    unique_entries = []
    for entry in dns_entries:
        key = (entry['ip'], entry['fqdn'])
        if key not in seen:
            seen.add(key)
            unique_entries.append(entry)

    for entry in unique_entries:
        ip, fqdn, rtype = entry['ip'], entry['fqdn'], entry['record_type']
        label = f'{ip:<18} ↔ {fqdn:<45} [{rtype}]'

        # Forward lookup
        if fqdn.startswith('*'):
            R.record('ok', f'{label} — wildcard (skip verify)', fqdn)
            continue

        cmd = f'getent hosts {fqdn} 2>/dev/null || nslookup {fqdn} 2>/dev/null'
        out, status = auth.ssh(worker, cmd)
        if status != 'ok':
            R.record('warn', f'{label} — DNS worker unreachable', fqdn)
            continue

        resolved = ''
        for line in out.splitlines():
            parts = line.split()
            if parts and re.match(r'\d+\.\d+\.\d+\.\d+', parts[0]):
                resolved = parts[0]; break
            if 'Address:' in line and '#' not in line:
                resolved = line.split()[-1]; break

        if 'A Record only' in rtype:
            if resolved == ip:
                R.record('ok', f'{label}  A ✓', fqdn)
            else:
                R.record('fail', f'{label}  A ✗ (resolved: {resolved or "NXDOMAIN"})', fqdn)
        else:
            if resolved != ip:
                R.record('fail', f'{label}  A ✗ (resolved: {resolved or "NXDOMAIN"})', fqdn)
                continue
            # PTR check
            ptr_cmd = f'getent hosts {ip} 2>/dev/null || nslookup {ip} 2>/dev/null'
            ptr_out, _ = auth.ssh(worker, ptr_cmd)
            fqdn_base = fqdn.split('.')[0]
            ptr_match = any(fqdn_base in line for line in ptr_out.splitlines())
            if ptr_match:
                R.record('ok', f'{label}  A+PTR ✓', fqdn)
            else:
                R.record('fail', f'{label}  PTR ✗ (no match for {fqdn_base})', fqdn)


# ══════════════════════════════════════════════════════════════════════════════
# PHASE 6 — FIREWALL / URL REACHABILITY (from worker node)
# ══════════════════════════════════════════════════════════════════════════════

COMMON_URLS = [
    'https://{region}.data.cloud.hpe.com',
    'https://tunnel-{region}.data.cloud.hpe.com',
    'https://device.cloud.hpe.com',
    'https://common.cloud.hpe.com',
    'https://github.com',
    'https://raw.githubusercontent.com',
    'https://solutionhub-metadata.s3.us-east-1.amazonaws.com',
    'https://gl-vas-harbor-prod-images.s3.us-west-2.amazonaws.com',
]
GEN2_URLS = [
    'https://authn.nvidia.com',
    'https://api.ngc.nvidia.com',
    'https://nvcr.io',
    'https://registry.ngc.nvidia.com',
    'https://login.nvidia.com',
    'https://gateway.opsramp.net',
    'https://update1.linux.hpe.com/repo/hpevme/',
    'https://pypi.org',
]


def phase6_firewall(nodes, auth, mode='pcai-gen2', region='us1'):
    section(f'PHASE 6 — FIREWALL / URL REACHABILITY  (mode={mode}, region={region})')
    worker = next((k for k, v in nodes.items()
                   if k.startswith('server-') and 'DL380a' in v.get('hw_type','')), None)
    if not worker:
        R.record('warn', 'No worker available for firewall checks'); return

    hostname = nodes[worker].get('hostname', worker)
    info(f'Running URL checks from {hostname}')

    urls = [u.format(region=region) for u in COMMON_URLS]
    if 'gen2' in mode:
        urls += GEN2_URLS

    for url in urls:
        host = re.sub(r'https?://', '', url).split('/')[0]
        cmd = (f'curl -k -s -o /dev/null -w "%{{http_code}}" '
               f'--connect-timeout 5 {url} 2>/dev/null || '
               f'bash -c "echo >/dev/tcp/{host}/443" 2>/dev/null && echo TCP_OK || echo FAIL')
        out, status = auth.ssh(worker, cmd, timeout=20)
        if status != 'ok':
            R.record('warn', f'{url} — worker unreachable', url)
            break
        code = out.strip()
        label = f'{url:<60}'
        if code.isdigit() and int(code) < 600:
            R.record('ok', f'{label}  HTTP {code}')
        elif 'TCP_OK' in out:
            R.record('ok', f'{label}  TCP reachable')
        else:
            R.record('fail', f'{label}  FAILED')


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main():
    args = sys.argv[1:]
    if len(args) < 3 or '--help' in args:
        print(__doc__)
        sys.exit(0)

    xlsx_path         = args[0]
    base_cfg_path     = args[1]
    infra_layout_path = args[2]

    mode          = 'pcai-gen2'
    region        = 'us1'
    skip_firewall = False
    skip_dns      = False
    global_key_file = None   # override key file for all nodes
    global_ssh_user = None   # override SSH username for all nodes
    global_cipher   = None   # override SSH cipher

    i = 3
    while i < len(args):
        a = args[i]
        if a == '--mode'          and i+1 < len(args): mode   = args[i+1]; i += 2; continue
        if a == '--region'        and i+1 < len(args): region = args[i+1]; i += 2; continue
        if a == '--key-file'      and i+1 < len(args): global_key_file = args[i+1]; i += 2; continue
        if a == '--ssh-user'      and i+1 < len(args): global_ssh_user = args[i+1]; i += 2; continue
        if a == '--cipher'        and i+1 < len(args): global_cipher   = args[i+1]; i += 2; continue
        if a == '--skip-firewall': skip_firewall = True
        if a == '--skip-dns':      skip_dns      = True
        i += 1

    # ── Load data ─────────────────────────────────────────────────────────────
    print(f'{CYAN}Parsing Excel: {xlsx_path} ...{RESET}')
    try:
        meta, expected_nodes, gpu_prefixes, dns_entries, gateways = load_excel(xlsx_path)
    except Exception as e:
        print(f'{RED}ERROR: Cannot parse Excel: {e}{RESET}'); sys.exit(1)

    print(f'{CYAN}Parsing configs ...{RESET}')
    try:
        nodes = load_configs(base_cfg_path, infra_layout_path)
    except Exception as e:
        print(f'{RED}ERROR: Cannot parse JSON configs: {e}{RESET}'); sys.exit(1)

    auth = AuthManager(nodes)

    # Apply global SSH overrides (--key-file / --ssh-user / --cipher)
    if global_key_file or global_ssh_user:
        if global_key_file and not os.path.exists(global_key_file):
            print(f'{RED}ERROR: Key file not found: {global_key_file}{RESET}'); sys.exit(1)
        for comp_id in nodes:
            existing = auth._os_creds(comp_id) or {}
            auth._override[comp_id] = {
                'user':     global_ssh_user or existing.get('user', 'root'),
                'key_file': global_key_file,
                'pass':     None if global_key_file else existing.get('pass'),
                'cipher':   global_cipher,
            }

    customer_id = meta.get('SCID Number', 'unknown')
    timestamp   = datetime.now().strftime('%Y%m%d-%H%M%S')
    report_file = f'pcai-validate-{customer_id}-{timestamp}.txt'

    header(
        'HPE PCAI Post-Install E2E Validation',
        f'Customer: {customer_id}  |  {meta.get("Base Line","")}'
    )
    _tee(f'  Date    : {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}')
    _tee(f'  Excel   : {xlsx_path}')
    _tee(f'  Configs : {base_cfg_path}  +  {infra_layout_path}')
    _tee(f'  Mode    : {mode}   Region: {region}')
    ssh_method = 'key file' if global_key_file else ('sshpass' if _has_sshpass() else 'python pty')
    _tee(f'  SSH via : {ssh_method}')
    if global_key_file:
        _tee(f'  Key     : {global_key_file}  (user: {global_ssh_user or "from config"})')

    # ── Run phases ────────────────────────────────────────────────────────────
    phase1_ilo_reachability(nodes)
    phase2_redfish(nodes, expected_nodes, auth)
    phase3_network_interfaces(nodes, expected_nodes, gpu_prefixes, auth)
    phase4_gateway_ping(nodes, gateways, auth)
    if not skip_dns:
        phase5_dns(nodes, dns_entries, auth)
    if not skip_firewall:
        phase6_firewall(nodes, auth, mode, region)

    # ── Final summary ─────────────────────────────────────────────────────────
    R.summary()

    # ── Save report ───────────────────────────────────────────────────────────
    with open(report_file, 'w') as f:
        f.write('\n'.join(REPORT_LINES))
    _tee(f'\n  Report saved: {report_file}',
         f'\n  {BOLD}Report saved: {report_file}{RESET}')

    sys.exit(1 if R.failed > 0 else 0)


if __name__ == '__main__':
    main()
