#!/usr/bin/env bash
#
# OCI MCP Server - Interactive Setup
#

set -e

# Configuration
INSTALL_DIR="${MCP_INSTALL_DIR:-/opt/oci-mcp-server}"
MCP_USER="${MCP_USER:-$(whoami)}"
PYTHON_MIN_VERSION="3.10"
FIRST_RUN=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

setup_sudo() {
    if [[ $EUID -eq 0 ]]; then
        SUDO=""
    else
        SUDO="sudo"
    fi
}

print_banner() {
    echo ""
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}       OCI MCP Server Setup - User: $MCP_USER${NC}"
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Install   ${RED}2)${NC} Uninstall   ${YELLOW}3)${NC} Status   ${BLUE}4)${NC} Config   ${CYAN}5)${NC} Test   ${BOLD}0)${NC} Exit"
    echo ""
}

print_prompt() {
    echo ""
    echo -e "[${GREEN}1${NC}:Install ${RED}2${NC}:Uninstall ${YELLOW}3${NC}:Status ${BLUE}4${NC}:Config ${CYAN}5${NC}:Test ${BOLD}0${NC}:Exit]"
}

check_status() {
    echo ""
    echo -e "${BOLD}=== Installation Status ===${NC}"
    
    if [[ -d "$INSTALL_DIR" ]]; then
        echo -e "Directory: ${GREEN}EXISTS${NC} | Server: $([[ -f "$INSTALL_DIR/server.py" ]] && echo -e "${GREEN}OK${NC}" || echo -e "${RED}MISSING${NC}") | Venv: $([[ -d "$INSTALL_DIR/venv" ]] && echo -e "${GREEN}OK${NC}" || echo -e "${RED}MISSING${NC}") | Config: $([[ -f "$INSTALL_DIR/config/config.json" ]] && echo -e "${GREEN}OK${NC}" || echo -e "${RED}MISSING${NC}")"
        if [[ -f "$INSTALL_DIR/logs/audit.log" ]]; then
            echo -e "Audit log: ${GREEN}$(wc -l < "$INSTALL_DIR/logs/audit.log" 2>/dev/null || echo "0") entries${NC}"
        fi
    else
        echo -e "Status: ${RED}NOT INSTALLED${NC}"
    fi
    
    echo ""
    echo -e "${BOLD}Tools:${NC} kubectl: $(command -v kubectl &>/dev/null && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}") | oci: $(command -v oci &>/dev/null && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}") | helm: $(command -v helm &>/dev/null && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}✗${NC}")"
}

do_uninstall() {
    echo ""
    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_warn "MCP Server is not installed"
        return
    fi
    
    read -p "Remove $INSTALL_DIR? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        $SUDO rm -rf "$INSTALL_DIR"
        log_info "Uninstalled"
    else
        log_info "Cancelled"
    fi
}

do_install() {
    echo ""
    
    if [[ -d "$INSTALL_DIR" ]]; then
        read -p "Already installed. Reinstall? (yes/no): " confirm
        [[ "$confirm" != "yes" ]] && { log_info "Cancelled"; return; }
        $SUDO rm -rf "$INSTALL_DIR"
    fi
    
    # Detect package manager
    if [[ -f /etc/debian_version ]]; then
        PKG_MANAGER="apt"
    else
        PKG_MANAGER="dnf"
    fi
    
    # Check Python
    PYTHON_CMD=""
    if command -v python3 &> /dev/null; then
        PV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        PM=$(echo "$PV" | cut -d. -f1); Pm=$(echo "$PV" | cut -d. -f2)
        [[ "$PM" -ge 3 ]] && [[ "$Pm" -ge 10 ]] && PYTHON_CMD="python3"
    fi
    
    if [[ -z "$PYTHON_CMD" ]]; then
        log_step "Installing Python 3.11..."
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            $SUDO apt update && $SUDO apt install -y python3.11 python3.11-pip python3.11-venv
        else
            $SUDO dnf install -y python3.11 python3.11-pip
        fi
        PYTHON_CMD="python3.11"
    fi
    
    # Check pip
    if ! $PYTHON_CMD -m pip --version &> /dev/null; then
        [[ "$PKG_MANAGER" == "apt" ]] && $SUDO apt install -y python3-pip python3-venv || $SUDO dnf install -y python3-pip
    fi
    
    # Check tools
    if ! command -v kubectl &> /dev/null || ! command -v oci &> /dev/null; then
        log_error "Missing kubectl or oci CLI"
        return 1
    fi
    
    log_step "Creating $INSTALL_DIR..."
    $SUDO mkdir -p "$INSTALL_DIR"/{config,logs,scripts}
    $SUDO chown -R "$MCP_USER":"$MCP_USER" "$INSTALL_DIR"
    
    log_step "Creating virtualenv..."
    $PYTHON_CMD -m venv "$INSTALL_DIR/venv"
    source "$INSTALL_DIR/venv/bin/activate"
    
    log_step "Installing MCP..."
    pip install --upgrade pip -q && pip install mcp -q
    
    log_step "Creating server files..."
    create_server_file
    create_config_file
    create_wrapper_file
    create_test_file
    
    $SUDO chown -R "$MCP_USER":"$MCP_USER" "$INSTALL_DIR"
    deactivate
    
    echo ""
    log_info "Installation complete!"
    echo ""
    echo "Connect from Claude Desktop:"
    echo "  ssh $MCP_USER@<host> $INSTALL_DIR/run.sh"
}

create_server_file() {
    cat > "$INSTALL_DIR/server.py" << 'SERVEREOF'
#!/usr/bin/env python3
import asyncio, json, logging, re, os
from datetime import datetime, timezone
from pathlib import Path
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

INSTALL_DIR = Path(__file__).parent
CONFIG = json.load(open(INSTALL_DIR / "config" / "config.json"))
TIMEOUT = CONFIG.get("timeout", 60)

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger("mcp")

audit_logger = logging.getLogger("audit")
ah = logging.FileHandler(INSTALL_DIR / "logs" / "audit.log")
ah.setFormatter(logging.Formatter('%(asctime)s - %(message)s'))
audit_logger.addHandler(ah)
audit_logger.setLevel(logging.INFO)

def audit(tool, params, result, ok, ms):
    audit_logger.info(json.dumps({"ts": datetime.now(timezone.utc).isoformat(), "tool": tool, "params": params, "ok": ok, "ms": round(ms,2), "len": len(result)}))

class Validator:
    def __init__(self, al):
        self.kubectl = [re.compile(p) for p in al.get("kubectl", [])]
        self.oci = [re.compile(p) for p in al.get("oci", [])]
        self.helm = [re.compile(p) for p in al.get("helm", [])]
        self.bash = [re.compile(p) for p in al.get("bash", [])]
        self.block = [re.compile(r';\s*rm\s'), re.compile(r'\|\s*rm\s'), re.compile(r'>\s*/'), re.compile(r'\$\('), re.compile(r'`'), re.compile(r'&&\s*rm'), re.compile(r'\|\|'), re.compile(r'eval\s'), re.compile(r'exec\s')]
    def blocked(self, c): return any(p.search(c) for p in self.block)
    def ok_kubectl(self, c): return not self.blocked(c) and any(p.match(c) for p in self.kubectl)
    def ok_oci(self, c): return not self.blocked(c) and any(p.match(c) for p in self.oci)
    def ok_helm(self, c): return not self.blocked(c) and any(p.match(c) for p in self.helm)
    def ok_bash(self, c): return not self.blocked(c) and any(p.match(c) for p in self.bash)

async def run(cmd, timeout=60):
    try:
        env = os.environ.copy()
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/opt/oracle-cli/bin:" + env.get("PATH", "")
        env.setdefault("KUBECONFIG", os.path.expanduser("~/.kube/config"))
        p = await asyncio.create_subprocess_shell(cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env=env)
        o, e = await asyncio.wait_for(p.communicate(), timeout=timeout)
        return o.decode(errors='replace'), e.decode(errors='replace'), p.returncode or 0
    except asyncio.TimeoutError: return "", f"Timeout {timeout}s", 124
    except Exception as x: return "", str(x), 1

server = Server("oci-infrastructure")
v = Validator(CONFIG["allowlist"])

@server.list_tools()
async def list_tools():
    return [
        Tool(name="kubectl", description="Run kubectl", inputSchema={"type":"object","properties":{"command":{"type":"string"},"namespace":{"type":"string"}},"required":["command"]}),
        Tool(name="oci", description="Run oci cli", inputSchema={"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}),
        Tool(name="helm", description="Run helm", inputSchema={"type":"object","properties":{"command":{"type":"string"},"namespace":{"type":"string"}},"required":["command"]}),
        Tool(name="run_script", description="Run allowed script", inputSchema={"type":"object","properties":{"script_name":{"type":"string"},"args":{"type":"array","items":{"type":"string"}}},"required":["script_name"]}),
        Tool(name="get_pod_logs", description="Get pod logs", inputSchema={"type":"object","properties":{"pod_name":{"type":"string"},"namespace":{"type":"string"},"container":{"type":"string"},"tail":{"type":"integer"},"previous":{"type":"boolean"}},"required":["pod_name","namespace"]}),
        Tool(name="get_gpu_status", description="GPU status", inputSchema={"type":"object","properties":{"node_name":{"type":"string"}}}),
        Tool(name="get_cluster_health", description="Cluster health", inputSchema={"type":"object","properties":{}}),
        Tool(name="bash", description="Run allowed bash", inputSchema={"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}),
    ]

@server.call_tool()
async def call_tool(name, args):
    t0 = datetime.now()
    try:
        r = await {"kubectl":h_kubectl,"oci":h_oci,"helm":h_helm,"run_script":h_script,"get_pod_logs":h_logs,"get_gpu_status":h_gpu,"get_cluster_health":h_health,"bash":h_bash}.get(name, lambda a:f"Unknown: {name}")(args)
        audit(name, args, r, True, (datetime.now()-t0).total_seconds()*1000)
        return [TextContent(type="text", text=r)]
    except Exception as x:
        audit(name, args, str(x), False, (datetime.now()-t0).total_seconds()*1000)
        return [TextContent(type="text", text=f"Error: {x}")]

async def h_kubectl(a):
    c = f"kubectl {a['command'].strip()}"
    if ns := a.get("namespace"):
        if "-n " not in c: c = f"kubectl -n {ns} {a['command'].strip()}"
    if not v.ok_kubectl(c): return f"Not allowed: {c}"
    o,e,rc = await run(c, TIMEOUT)
    return o if rc==0 else f"Failed({rc}): {e or o}"

async def h_oci(a):
    c = f"oci {a['command'].strip()}"
    if not v.ok_oci(c): return f"Not allowed: {c}"
    o,e,rc = await run(c, TIMEOUT)
    return o if rc==0 else f"Failed({rc}): {e or o}"

async def h_helm(a):
    c = f"helm {a['command'].strip()}"
    if ns := a.get("namespace"):
        if "-n " not in c: c = f"helm -n {ns} {a['command'].strip()}"
    if not v.ok_helm(c): return f"Not allowed: {c}"
    o,e,rc = await run(c, TIMEOUT)
    return o if rc==0 else f"Failed({rc}): {e or o}"

async def h_bash(a):
    c = a["command"].strip()
    if not v.ok_bash(c): return f"Not allowed: {c}"
    o,e,rc = await run(c, TIMEOUT)
    return o if rc==0 else f"Failed({rc}): {e or o}"

async def h_script(a):
    sn = a["script_name"]
    allowed = CONFIG.get("allowed_scripts", {})
    if sn not in allowed: return f"Not allowed: {sn}. Available: {list(allowed.keys())}"
    args = a.get("args", [])
    for x in args:
        if v.blocked(x): return f"Blocked arg: {x}"
    o,e,rc = await run(f"{allowed[sn]} {' '.join(repr(x) for x in args)}", TIMEOUT*2)
    return o if rc==0 else f"Failed({rc}): {e or o}"

async def h_logs(a):
    c = f"kubectl logs -n {a['namespace']} {a['pod_name']}"
    if x := a.get("container"): c += f" -c {x}"
    c += f" --tail={a.get('tail',100)}"
    if a.get("previous"): c += " --previous"
    if not v.ok_kubectl(c): return "Not allowed"
    o,e,rc = await run(c, TIMEOUT)
    return o if rc==0 else f"Failed: {e or o}"

async def h_gpu(a):
    r = []
    c = f"kubectl get node {a['node_name']} -o wide" if a.get("node_name") else "kubectl get nodes -l 'nvidia.com/gpu.present=true' -o wide"
    o,e,rc = await run(c, TIMEOUT)
    r.append(f"=== Nodes ===\n{o if rc==0 else e}")
    o,_,_ = await run("kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds -o name 2>/dev/null | head -1 | xargs -I {} kubectl exec -n kube-system {} -- nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null || echo 'N/A'", TIMEOUT)
    r.append(f"=== GPU ===\n{o}")
    return "\n\n".join(r)

async def h_health(a):
    checks = [("Nodes","kubectl get nodes -o wide"),("Unhealthy","kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded|head -20"),("GPU","kubectl get nodes -l nvidia.com/gpu.present=true -o custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type==\"Ready\")].status,GPU:.status.allocatable.nvidia\\.com/gpu"),("Top","kubectl top nodes 2>/dev/null||echo N/A")]
    r = []
    for n,c in checks:
        o,e,rc = await run(c, TIMEOUT)
        r.append(f"=== {n} ===\n{o if rc==0 else e}")
    return "\n\n".join(r)

async def main():
    logger.info("Starting MCP Server")
    async with stdio_server() as (r,w):
        await server.run(r, w, server.create_initialization_options())

if __name__ == "__main__":
    asyncio.run(main())
SERVEREOF
    chmod +x "$INSTALL_DIR/server.py"
}

create_config_file() {
    cat > "$INSTALL_DIR/config/config.json" << 'CONFIGEOF'
{
  "timeout": 60,
  "allowlist": {
    "kubectl": ["^kubectl get .*","^kubectl describe .*","^kubectl logs .*","^kubectl top .*","^kubectl explain .*","^kubectl api-resources.*","^kubectl cluster-info.*","^kubectl config view.*","^kubectl config current-context.*","^kubectl version.*","^kubectl auth can-i .*","^kubectl events .*","^kubectl rollout status .*","^kubectl rollout history .*"],
    "oci": ["^oci compute instance get .*","^oci compute instance list .*","^oci compute instance-pool get .*","^oci compute instance-pool list .*","^oci ce cluster get .*","^oci ce cluster list .*","^oci ce node-pool get .*","^oci ce node-pool list .*","^oci ce cluster-addon list .*","^oci ce cluster-addon get .*","^oci limits service list .*","^oci limits value list .*","^oci limits resource-availability get .*","^oci network vcn list .*","^oci network subnet list .*","^oci network nsg list .*","^oci network nsg-security-rules list .*","^oci iam compartment list .*","^oci iam compartment get .*","^oci monitoring metric-data summarize-metrics-data .*","^oci bv boot-volume list .*","^oci bv volume list .*"],
    "helm": ["^helm list.*","^helm status .*","^helm get .*","^helm history .*","^helm show .*","^helm search .*","^helm repo list.*","^helm version.*"],
    "bash": ["^cat /etc/os-release$","^hostname$","^uptime$","^df -h$","^free -h$","^nvidia-smi.*","^nccl-tests/.*"]
  },
  "allowed_scripts": {}
}
CONFIGEOF
}

create_wrapper_file() {
    cat > "$INSTALL_DIR/run.sh" << WRAPEOF
#!/usr/bin/env bash
cd "$INSTALL_DIR"
source venv/bin/activate
exec python server.py
WRAPEOF
    chmod +x "$INSTALL_DIR/run.sh"
}

create_test_file() {
    cat > "$INSTALL_DIR/test.sh" << TESTEOF
#!/usr/bin/env bash
cd "$INSTALL_DIR" && source venv/bin/activate
echo "=== OCI MCP Server Test ==="
echo "Python: \$(python --version)"
echo -n "MCP: " && python -c "import mcp; print('OK')"
echo "kubectl: \$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
echo "oci: \$(oci --version 2>/dev/null | head -1)"
echo "helm: \$(helm version --short 2>/dev/null || echo 'N/A')"
echo "=== Cluster Test ==="
kubectl get nodes --no-headers 2>/dev/null | head -3 || echo "No access"
echo "=== Done ==="
TESTEOF
    chmod +x "$INSTALL_DIR/test.sh"
}

view_config() {
    echo ""
    [[ ! -f "$INSTALL_DIR/config/config.json" ]] && { log_warn "Not installed"; return; }
    
    echo "Config: 1)View 2)Edit 3)Scripts 4)Add-Script 0)Back"
    read -p "> " c
    case $c in
        1) echo "" && cat "$INSTALL_DIR/config/config.json" ;;
        2) vi "$INSTALL_DIR/config/config.json" ;;
        3) echo "" && python3 -c "import json; s=json.load(open('$INSTALL_DIR/config/config.json')).get('allowed_scripts',{}); print('\n'.join(f'  {k}: {v}' for k,v in s.items()) or '  (none)')" ;;
        4) read -p "Name: " sn && read -p "Path: " sp && [[ -n "$sn" && -n "$sp" ]] && python3 -c "import json; c=json.load(open('$INSTALL_DIR/config/config.json')); c.setdefault('allowed_scripts',{})['$sn']='$sp'; json.dump(c,open('$INSTALL_DIR/config/config.json','w'),indent=2); print('Added')" ;;
    esac
}

run_tests() {
    echo ""
    [[ -f "$INSTALL_DIR/test.sh" ]] && "$INSTALL_DIR/test.sh" || log_warn "Not installed"
}

main() {
    setup_sudo
    print_banner
    
    while true; do
        read -p "> " choice
        case $choice in
            1) do_install ;;
            2) do_uninstall ;;
            3) check_status ;;
            4) view_config ;;
            5) run_tests ;;
            0|q|exit) echo "Bye!" && exit 0 ;;
            *) echo "Invalid. [1:Install 2:Uninstall 3:Status 4:Config 5:Test 0:Exit]" ;;
        esac
        print_prompt
    done
}

main