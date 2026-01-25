#!/usr/bin/env bash
#
# OCI MCP Server - Setup with Multi-LLM API Configuration
#

set -e

# Configuration
INSTALL_DIR="${MCP_INSTALL_DIR:-/opt/oci-mcp-server}"
export INSTALL_DIR
MCP_USER="${MCP_USER:-$(whoami)}"
API_CONFIG_DIR="${HOME}/.config/ai-api"
API_CONFIG_FILE="${API_CONFIG_DIR}/config.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_step() { echo -e "${CYAN}>>>${NC} $1"; }
log_test() { echo -n "$1... "; }

# Read API key with paste support
# Usage: read_api_key "prompt text" variable_name
read_api_key() {
    local prompt="$1"
    echo ""
    echo "  1) Hidden input (more secure)"
    echo "  2) Visible input (supports paste)"
    read -p "Input mode [2]: " mode
    mode="${mode:-2}"
    
    case $mode in
        1) read -p "$prompt: " -s REPLY; echo "" ;;
        2) read -p "$prompt: " REPLY ;;
        *) REPLY="" ;;
    esac
}

setup_sudo() { [[ $EUID -eq 0 ]] && SUDO="" || SUDO="sudo"; }
mkdir -p "$API_CONFIG_DIR" 2>/dev/null && chmod 700 "$API_CONFIG_DIR" 2>/dev/null

# ============================================================================
# Menus
# ============================================================================

print_main_menu() {
    echo ""
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}         OCI MCP Server + LLM Setup (User: $MCP_USER)${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Install MCP Server"
    echo -e "  ${RED}2)${NC} Uninstall MCP Server"
    echo -e "  ${YELLOW}3)${NC} MCP Status"
    echo -e "  ${BLUE}4)${NC} MCP Config"
    echo ""
    echo -e "  ${CYAN}5)${NC} Configure LLM APIs  ${BOLD}→${NC}"
    echo -e "  ${YELLOW}6)${NC} View API Config"
    echo ""
    echo -e "  ${MAGENTA}7)${NC} Test All"
    echo -e "  ${MAGENTA}8)${NC} Send Test Message"
    echo ""
    echo -e "  ${BOLD}0)${NC} Exit"
    echo ""
}

print_llm_menu() {
    echo ""
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}                    LLM API Configuration${NC}"
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Claude (Anthropic)       ${GREEN}2)${NC} ChatGPT (OpenAI)"
    echo -e "  ${GREEN}3)${NC} Oracle GenAI             ${GREEN}4)${NC} Grok (xAI)"
    echo -e "  ${GREEN}5)${NC} Gemini (Google)          ${GREEN}6)${NC} Mistral"
    echo -e "  ${GREEN}7)${NC} Groq                     ${GREEN}8)${NC} Ollama (Local)"
    echo -e "  ${GREEN}9)${NC} Azure OpenAI             ${GREEN}10)${NC} AWS Bedrock"
    echo -e "  ${GREEN}11)${NC} Cohere                   ${GREEN}12)${NC} Perplexity"
    echo ""
    echo -e "  ${RED}99)${NC} Clear All API Config"
    echo -e "  ${BOLD}0)${NC} Back to Main Menu"
    echo ""
}

# ============================================================================
# Utility Functions
# ============================================================================

save_config() {
    local key="$1"
    local value="$2"
    
    if [[ -f "$API_CONFIG_FILE" ]]; then
        python3 -c "
import json
c = json.load(open('$API_CONFIG_FILE'))
c['$key'] = '$value'
json.dump(c, open('$API_CONFIG_FILE', 'w'), indent=2)
"
    else
        echo "{\"$key\": \"$value\"}" > "$API_CONFIG_FILE"
    fi
    chmod 600 "$API_CONFIG_FILE"
}

get_config() {
    local key="$1"
    [[ -f "$API_CONFIG_FILE" ]] && python3 -c "import json; print(json.load(open('$API_CONFIG_FILE')).get('$key',''))" 2>/dev/null || echo ""
}

# ============================================================================
# MCP Server Functions
# ============================================================================

check_mcp_status() {
    echo ""
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}                    MCP Server Status${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${CYAN}${BOLD}  Installation${NC}"
    echo -e "  ${BOLD}─────────────────────────────────────────────────────────${NC}"
    
    if [[ -d "$INSTALL_DIR" ]]; then
        printf "  %-20s" "Directory:"
        echo -e "${GREEN}$INSTALL_DIR${NC}"
        
        printf "  %-20s"  "Server script:"
        [[ -f "$INSTALL_DIR/server.py" ]] && echo -e "${GREEN}● Installed${NC}" || echo -e "${RED}● Missing${NC}"
        
        printf "  %-20s" "Virtual env:"
        [[ -d "$INSTALL_DIR/venv" ]] && echo -e "${GREEN}● Installed${NC}" || echo -e "${RED}● Missing${NC}"
        
        printf "  %-20s" "Config file:"
        [[ -f "$INSTALL_DIR/config/config.json" ]] && echo -e "${GREEN}● Present${NC}" || echo -e "${RED}● Missing${NC}"
        
        if [[ -f "$INSTALL_DIR/logs/audit.log" ]]; then
            printf "  %-20s" "Audit log:"
            echo -e "${GREEN}$(wc -l < "$INSTALL_DIR/logs/audit.log" 2>/dev/null || echo 0) entries${NC}"
        fi
    else
        echo -e "  Status:             ${RED}● NOT INSTALLED${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}${BOLD}  System Tools${NC}"
    echo -e "  ${BOLD}─────────────────────────────────────────────────────────${NC}"
    
    printf "  %-20s" "kubectl:"
    if command -v kubectl &>/dev/null; then
        echo -e "${GREEN}● $(kubectl version --client --short 2>/dev/null || echo 'Installed')${NC}"
    else
        echo -e "${RED}● Not found${NC}"
    fi
    
    printf "  %-20s" "oci:"
    if command -v oci &>/dev/null; then
        echo -e "${GREEN}● $(oci --version 2>/dev/null | head -1)${NC}"
    else
        echo -e "${RED}● Not found${NC}"
    fi
    
    printf "  %-20s" "helm:"
    if command -v helm &>/dev/null; then
        echo -e "${GREEN}● $(helm version --short 2>/dev/null)${NC}"
    else
        echo -e "${YELLOW}● Not found (optional)${NC}"
    fi
    
    printf "  %-20s" "aws:"
    if command -v aws &>/dev/null; then
        echo -e "${GREEN}● Installed${NC}"
    else
        echo -e "${YELLOW}● Not found (optional)${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}${BOLD}  Cluster Connection${NC}"
    echo -e "  ${BOLD}─────────────────────────────────────────────────────────${NC}"
    
    printf "  %-20s" "Kubernetes:"
    if kubectl cluster-info &>/dev/null 2>&1; then
        echo -e "${GREEN}● Connected${NC}"
        printf "  %-20s" "Nodes:"
        NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
        READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || echo 0)
        echo -e "${GREEN}$READY_COUNT/$NODE_COUNT ready${NC}"
    else
        echo -e "${RED}● Not connected${NC}"
    fi
    
    echo ""
}

do_uninstall() {
    echo ""
    [[ ! -d "$INSTALL_DIR" ]] && { log_warn "MCP Server is not installed"; return; }
    read -p "Remove $INSTALL_DIR? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] && { $SUDO rm -rf "$INSTALL_DIR"; log_ok "Uninstalled"; } || log_warn "Cancelled"
}

do_install() {
    echo ""
    
    if [[ -d "$INSTALL_DIR" ]]; then
        read -p "Already installed. Reinstall? (yes/no): " confirm
        [[ "$confirm" != "yes" ]] && { log_warn "Cancelled"; return; }
        $SUDO rm -rf "$INSTALL_DIR"
    fi
    
    [[ -f /etc/debian_version ]] && PKG_MANAGER="apt" || PKG_MANAGER="dnf"
    
    PYTHON_CMD=""
    if command -v python3 &>/dev/null; then
        PV=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        PM=$(echo "$PV" | cut -d. -f1); Pm=$(echo "$PV" | cut -d. -f2)
        [[ "$PM" -ge 3 && "$Pm" -ge 10 ]] && PYTHON_CMD="python3"
    fi
    
    if [[ -z "$PYTHON_CMD" ]]; then
        log_step "Installing Python 3.11..."
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            $SUDO apt update -qq && $SUDO apt install -y python3.11 python3.11-pip python3.11-venv
        else
            $SUDO dnf install -y python3.11 python3.11-pip
        fi
        PYTHON_CMD="python3.11"
    fi
    
    if ! $PYTHON_CMD -m pip --version &>/dev/null; then
        [[ "$PKG_MANAGER" == "apt" ]] && $SUDO apt install -y python3-pip python3-venv || $SUDO dnf install -y python3-pip
    fi
    
    if ! command -v kubectl &>/dev/null || ! command -v oci &>/dev/null; then
        log_fail "Missing kubectl or oci CLI"; return 1
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
    
    $SUDO chown -R "$MCP_USER":"$MCP_USER" "$INSTALL_DIR"
    deactivate
    
    echo ""
    log_ok "Installation complete!"
    echo "Connect: ssh $MCP_USER@<host> $INSTALL_DIR/run.sh"
}

mcp_config() {
    echo ""
    [[ ! -f "$INSTALL_DIR/config/config.json" ]] && { log_warn "MCP Server not installed"; return; }
    
    while true; do
        echo ""
        echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}${BOLD}                                           MCP Server Configuration${NC}"
        echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # Display configuration in columns
        python3 << 'PYEOF'
import json
import os

# ANSI colors
GREEN = '\033[0;32m'
RED = '\033[0;31m'
YELLOW = '\033[1;33m'
CYAN = '\033[0;36m'
MAGENTA = '\033[0;35m'
BLUE = '\033[0;34m'
BOLD = '\033[1m'
DIM = '\033[2m'
NC = '\033[0m'

install_dir = os.environ.get('INSTALL_DIR', '/opt/oci-mcp-server')
config_file = f"{install_dir}/config/config.json"

try:
    with open(config_file) as f:
        c = json.load(f)
except Exception as e:
    print(f"  {RED}Error reading config: {e}{NC}")
    exit(1)

timeout = c.get('timeout', 60)
allowlist = c.get('allowlist', {})
scripts = c.get('allowed_scripts', {})

# Get and sort patterns
kubectl_patterns = sorted(allowlist.get('kubectl', []))
oci_patterns = sorted(allowlist.get('oci', []))
helm_patterns = sorted(allowlist.get('helm', []))
bash_patterns = sorted(allowlist.get('bash', []))

# Calculate max rows needed
max_rows = max(len(kubectl_patterns), len(oci_patterns), len(helm_patterns), len(bash_patterns), 1)

# Column width - wider to show full patterns
col_w = 35

print(f"  {CYAN}Timeout:{NC} {GREEN}{timeout}s{NC}                                                        {DIM}Config: {install_dir}/config/config.json{NC}")
print()

# Print header row with numbers
print(f"  {GREEN}{BOLD}[1] kubectl{NC} ({len(kubectl_patterns)})                        {YELLOW}{BOLD}[2] oci{NC} ({len(oci_patterns)})                              {CYAN}{BOLD}[3] helm{NC} ({len(helm_patterns)})                 {MAGENTA}{BOLD}[4] bash{NC} ({len(bash_patterns)})")
print(f"  {'─'*35}  {'─'*35}  {'─'*35}  {'─'*35}")

# Print rows
for i in range(max_rows):
    row = "  "
    
    # kubectl column
    if i < len(kubectl_patterns):
        p = kubectl_patterns[i].replace('^', '').replace('$', '').replace('kubectl ', '')
        row += f"{GREEN}{p:<35}{NC}"
    else:
        row += " " * 35
    
    row += "  "
    
    # oci column
    if i < len(oci_patterns):
        p = oci_patterns[i].replace('^', '').replace('$', '').replace('oci ', '')
        row += f"{YELLOW}{p:<35}{NC}"
    else:
        row += " " * 35
    
    row += "  "
    
    # helm column
    if i < len(helm_patterns):
        p = helm_patterns[i].replace('^', '').replace('$', '').replace('helm ', '')
        row += f"{CYAN}{p:<35}{NC}"
    else:
        row += " " * 35
    
    row += "  "
    
    # bash column
    if i < len(bash_patterns):
        p = bash_patterns[i].replace('^', '').replace('$', '')
        row += f"{MAGENTA}{p:<35}{NC}"
    else:
        row += " " * 35
    
    print(row)

# Scripts section
print()
print(f"  {BLUE}{BOLD}[5] Allowed Scripts{NC} ({len(scripts)})")
print(f"  {'─'*80}")
if scripts:
    for name, path in sorted(scripts.items()):
        print(f"  {BLUE}●{NC} {name:<25} → {path}")
else:
    print(f"  {DIM}(none configured){NC}")

PYEOF

        echo ""
        echo -e "  ${BOLD}══════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "  Select: ${GREEN}[1]${NC} kubectl  ${YELLOW}[2]${NC} oci  ${CYAN}[3]${NC} helm  ${MAGENTA}[4]${NC} bash  ${BLUE}[5]${NC} scripts  │  ${BOLD}[6]${NC} timeout  ${BOLD}[7]${NC} edit  ${BOLD}[8]${NC} upgrade  ${BOLD}[0]${NC} back"
        echo ""
        
        read -p "mcp-config> " choice
        case $choice in
            1) modify_allowlist "kubectl" "${GREEN}" ;;
            2) modify_allowlist "oci" "${YELLOW}" ;;
            3) modify_allowlist "helm" "${CYAN}" ;;
            4) modify_allowlist "bash" "${MAGENTA}" ;;
            5) modify_scripts ;;
            6)
                echo ""
                read -p "Enter timeout in seconds [60]: " new_timeout
                new_timeout="${new_timeout:-60}"
                python3 -c "
import json
c = json.load(open('$INSTALL_DIR/config/config.json'))
c['timeout'] = int('$new_timeout')
json.dump(c, open('$INSTALL_DIR/config/config.json', 'w'), indent=2)
"
                log_ok "Timeout set to ${new_timeout}s"
                ;;
            7)
                ${EDITOR:-vi} "$INSTALL_DIR/config/config.json"
                log_ok "Config file edited"
                ;;
            8)
                upgrade_allowlist_patterns
                ;;
            0|b|back|q)
                return
                ;;
            *)
                echo "Invalid option"
                ;;
        esac
    done
}

upgrade_allowlist_patterns() {
    echo ""
    echo -e "${YELLOW}${BOLD}Upgrade Allowlist Patterns${NC}"
    echo ""
    echo "  1) Upgrade OCI patterns (read-only infrastructure commands)"
    echo "  2) Upgrade bash patterns (operational monitoring commands)"
    echo "  3) Upgrade ALL patterns"
    echo "  0) Cancel"
    echo ""
    read -p "Select: " upgrade_choice
    
    case $upgrade_choice in
        1) upgrade_oci_patterns ;;
        2) upgrade_bash_patterns ;;
        3) 
            upgrade_oci_patterns
            upgrade_bash_patterns
            ;;
        *) return ;;
    esac
}

upgrade_oci_patterns() {
    echo ""
    echo -e "${YELLOW}${BOLD}Upgrade OCI Allowlist Patterns${NC}"
    echo ""
    
    # Define all recommended patterns
    NEW_PATTERNS=(
        "^oci compute instance get .*"
        "^oci compute instance list .*"
        "^oci compute instance-pool get .*"
        "^oci compute instance-pool list .*"
        "^oci compute instance-pool list-instances .*"
        "^oci compute shape list .*"
        "^oci compute image list .*"
        "^oci compute image get .*"
        "^oci compute cluster-network list .*"
        "^oci compute cluster-network get .*"
        "^oci compute cluster-network list-instances .*"
        "^oci compute boot-volume-attachment list .*"
        "^oci compute boot-volume-attachment get .*"
        "^oci compute volume-attachment list .*"
        "^oci compute volume-attachment get .*"
        "^oci compute vnic-attachment list .*"
        "^oci compute vnic-attachment get .*"
        "^oci compute capacity-reservation list .*"
        "^oci compute capacity-reservation get .*"
        "^oci ce cluster get .*"
        "^oci ce cluster list .*"
        "^oci ce node-pool get .*"
        "^oci ce node-pool list .*"
        "^oci ce node list .*"
        "^oci ce cluster-addon list .*"
        "^oci ce cluster-addon get .*"
        "^oci ce virtual-node-pool list .*"
        "^oci ce virtual-node-pool get .*"
        "^oci ce work-request list .*"
        "^oci ce work-request get .*"
        "^oci ce work-request-error list .*"
        "^oci ce work-request-log-entry list .*"
        "^oci network vcn list .*"
        "^oci network vcn get .*"
        "^oci network subnet list .*"
        "^oci network subnet get .*"
        "^oci network nsg list .*"
        "^oci network nsg get .*"
        "^oci network nsg-security-rules list .*"
        "^oci network nsg-vnics list .*"
        "^oci network route-table list .*"
        "^oci network route-table get .*"
        "^oci network security-list list .*"
        "^oci network security-list get .*"
        "^oci network internet-gateway list .*"
        "^oci network internet-gateway get .*"
        "^oci network nat-gateway list .*"
        "^oci network nat-gateway get .*"
        "^oci network service-gateway list .*"
        "^oci network service-gateway get .*"
        "^oci network drg list .*"
        "^oci network drg get .*"
        "^oci network drg-attachment list .*"
        "^oci network drg-attachment get .*"
        "^oci network private-ip list .*"
        "^oci network private-ip get .*"
        "^oci network public-ip list .*"
        "^oci network public-ip get .*"
        "^oci network vnic get .*"
        "^oci lb load-balancer list .*"
        "^oci lb load-balancer get .*"
        "^oci lb load-balancer-health get .*"
        "^oci lb backend-set list .*"
        "^oci lb backend-set get .*"
        "^oci lb backend list .*"
        "^oci lb backend get .*"
        "^oci lb backend-health get .*"
        "^oci lb listener list .*"
        "^oci lb shape list .*"
        "^oci lb work-request list .*"
        "^oci bv boot-volume list .*"
        "^oci bv boot-volume get .*"
        "^oci bv volume list .*"
        "^oci bv volume get .*"
        "^oci bv volume-backup list .*"
        "^oci bv volume-backup get .*"
        "^oci bv boot-volume-backup list .*"
        "^oci bv boot-volume-backup get .*"
        "^oci bv volume-group list .*"
        "^oci bv volume-group get .*"
        "^oci fs file-system list .*"
        "^oci fs file-system get .*"
        "^oci fs mount-target list .*"
        "^oci fs mount-target get .*"
        "^oci fs export list .*"
        "^oci fs export get .*"
        "^oci fs snapshot list .*"
        "^oci os ns get\$"
        "^oci os ns get-metadata .*"
        "^oci os bucket list .*"
        "^oci os bucket get .*"
        "^oci os object list .*"
        "^oci os object head .*"
        "^oci iam compartment list .*"
        "^oci iam compartment get .*"
        "^oci iam availability-domain list .*"
        "^oci iam fault-domain list .*"
        "^oci iam region list\$"
        "^oci iam region-subscription list .*"
        "^oci iam user list .*"
        "^oci iam user get .*"
        "^oci iam group list .*"
        "^oci iam group get .*"
        "^oci iam policy list .*"
        "^oci iam policy get .*"
        "^oci iam dynamic-group list .*"
        "^oci iam dynamic-group get .*"
        "^oci iam tenancy get .*"
        "^oci limits service list .*"
        "^oci limits value list .*"
        "^oci limits resource-availability get .*"
        "^oci limits quota list .*"
        "^oci limits quota get .*"
        "^oci limits definition list .*"
        "^oci monitoring metric list .*"
        "^oci monitoring metric-data summarize-metrics-data .*"
        "^oci monitoring alarm list .*"
        "^oci monitoring alarm get .*"
        "^oci monitoring alarm-status list-alarms-status .*"
        "^oci logging log-group list .*"
        "^oci logging log-group get .*"
        "^oci logging log list .*"
        "^oci logging log get .*"
        "^oci audit event list .*"
        "^oci audit configuration get .*"
        "^oci resource-manager stack list .*"
        "^oci resource-manager stack get .*"
        "^oci resource-manager job list .*"
        "^oci resource-manager job get .*"
        "^oci generative-ai model list .*"
        "^oci generative-ai model get .*"
        "^oci generative-ai model-collection list-models .*"
        "^oci generative-ai-inference chat-result chat .*"
        "^oci generative-ai dedicated-ai-cluster list .*"
        "^oci generative-ai dedicated-ai-cluster get .*"
        "^oci generative-ai endpoint list .*"
        "^oci generative-ai endpoint get .*"
        "^oci search resource-summary search-resources .*"
    )
    
    upgrade_pattern_list "oci" "${NEW_PATTERNS[@]}"
    log_ok "OCI patterns upgraded!"
}

upgrade_bash_patterns() {
    echo ""
    echo -e "${MAGENTA}${BOLD}Upgrade Bash Allowlist Patterns${NC}"
    echo ""
    
    NEW_PATTERNS=(
        # System info
        "^cat /etc/os-release\$"
        "^cat /etc/hosts\$"
        "^cat /etc/resolv.conf\$"
        "^cat /etc/fstab\$"
        "^cat /etc/mtab\$"
        "^cat /proc/cpuinfo\$"
        "^cat /proc/meminfo\$"
        "^cat /proc/loadavg\$"
        "^cat /proc/uptime\$"
        "^cat /proc/version\$"
        "^cat /proc/mounts\$"
        "^cat /proc/net/dev\$"
        "^cat /proc/diskstats\$"
        "^hostname.*"
        "^uptime.*"
        "^date.*"
        "^timedatectl.*"
        "^uname .*"
        # Disk and filesystem
        "^df .*"
        "^free .*"
        "^lsblk.*"
        "^findmnt.*"
        "^mount\$"
        "^blkid\$"
        "^du .*"
        # Process monitoring
        "^ps .*"
        "^top -bn1.*"
        "^htop -t\$"
        "^pgrep .*"
        "^pidof .*"
        # Hardware info
        "^lscpu.*"
        "^lsmem.*"
        "^lspci.*"
        "^lsusb.*"
        "^lsmod\$"
        "^lshw .*"
        "^lsof .*"
        "^dmidecode .*"
        # Networking
        "^ip addr.*"
        "^ip link.*"
        "^ip route.*"
        "^ip neigh.*"
        "^ip -s link.*"
        "^ip -s neigh.*"
        "^ss .*"
        "^ss -s\$"
        "^netstat .*"
        "^ifconfig.*"
        "^route -n\$"
        "^arp -a\$"
        "^ping -c .*"
        "^traceroute .*"
        "^tracepath .*"
        "^mtr .*"
        "^nslookup .*"
        "^dig .*"
        "^host .*"
        "^curl -s .*"
        "^wget -q .*"
        "^ethtool .*"
        "^tc qdisc show.*"
        "^tc class show.*"
        "^iptables -L.*"
        "^iptables -S.*"
        "^iptables-save\$"
        "^nft list.*"
        "^conntrack -L.*"
        # Services and logs
        "^systemctl status .*"
        "^systemctl is-active .*"
        "^systemctl is-enabled .*"
        "^systemctl list-units.*"
        "^systemctl list-timers.*"
        "^systemctl show .*"
        "^journalctl .*"
        "^dmesg.*"
        # Text processing
        "^tail .*"
        "^head .*"
        "^less .*"
        "^grep .*"
        "^awk .*"
        "^sed .*"
        "^wc .*"
        "^sort .*"
        "^uniq .*"
        "^cut .*"
        # Files
        "^ls .*"
        "^stat .*"
        "^file .*"
        "^find .* -name .*"
        "^find .* -type .*"
        # Environment
        "^env\$"
        "^printenv.*"
        "^who\$"
        "^w\$"
        "^last.*"
        "^id\$"
        "^id .*"
        "^groups\$"
        "^ulimit .*"
        # Kernel
        "^sysctl .*"
        "^modinfo .*"
        # GPU - NVIDIA
        "^nvidia-smi.*"
        "^dcgmi .*"
        "^nvitop.*"
        "^nv-fabricmanager .*"
        "^gpustat.*"
        # GPU - AMD/Intel
        "^rocm-smi.*"
        "^xpu-smi.*"
        # InfiniBand/RDMA
        "^ibstat.*"
        "^ibstatus.*"
        "^ibhosts.*"
        "^iblinkinfo.*"
        "^ibnetdiscover.*"
        "^perfquery.*"
        "^rdma .*"
        "^mlnx_tune .*"
        "^show_gids.*"
        "^ibdev2netdev.*"
        # Container runtimes
        "^docker ps.*"
        "^docker stats.*"
        "^docker logs .*"
        "^docker inspect .*"
        "^docker images.*"
        "^docker network ls.*"
        "^docker volume ls.*"
        "^docker info\$"
        "^docker version\$"
        "^crictl ps.*"
        "^crictl pods.*"
        "^crictl images.*"
        "^crictl stats.*"
        "^crictl logs .*"
        "^crictl info\$"
        "^crictl version\$"
        "^ctr .*"
        "^nerdctl ps.*"
        "^podman ps.*"
        # Performance monitoring
        "^iostat.*"
        "^mpstat.*"
        "^vmstat.*"
        "^sar .*"
        "^pidstat.*"
        # NUMA
        "^numactl .*"
        "^numastat.*"
        # Cgroups
        "^lscgroup.*"
        "^cgget .*"
        # NFS
        "^nfsstat.*"
        "^showmount .*"
        "^rpcinfo .*"
        # Other
        "^getent .*"
        "^chronyc .*"
        "^ntpq .*"
        "^nccl-tests/.*"
    )
    
    upgrade_pattern_list "bash" "${NEW_PATTERNS[@]}"
    log_ok "Bash patterns upgraded!"
}

upgrade_pattern_list() {
    local list_type="$1"
    shift
    local patterns=("$@")
    
    python3 << PYEOF
import json

new_patterns = [
$(printf '    "%s",\n' "${patterns[@]}" | sed '$ s/,$//')
]

config_file = "$INSTALL_DIR/config/config.json"
c = json.load(open(config_file))

existing = set(c.get('allowlist', {}).get('$list_type', []))
new_set = set(new_patterns)

added = new_set - existing
custom = existing - new_set

# Merge: keep all existing + add new
merged = list(existing | new_set)
merged.sort()

c.setdefault('allowlist', {})['$list_type'] = merged
json.dump(c, open(config_file, 'w'), indent=2)

print(f"  Current patterns: {len(existing)}")
print(f"  New patterns added: {len(added)}")
print(f"  Total patterns: {len(merged)}")
if custom:
    print(f"  Custom patterns preserved: {len(custom)}")
PYEOF
}

modify_allowlist() {
    local list_type="$1"
    local color="$2"
    
    while true; do
        echo ""
        echo -e "${color}${BOLD}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${color}${BOLD}                    ${list_type} Allowlist${NC}"
        echo -e "${color}${BOLD}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # Show current patterns with numbers (sorted)
        python3 << PYEOF
import json
import os

GREEN = '\033[0;32m'
DIM = '\033[2m'
NC = '\033[0m'

install_dir = os.environ.get('INSTALL_DIR', '/opt/oci-mcp-server')
c = json.load(open(f"{install_dir}/config/config.json"))
patterns = c.get('allowlist', {}).get('$list_type', [])

# Sort and display with original index for removal
if patterns:
    # Create list of (original_index, pattern) then sort by pattern
    indexed = list(enumerate(patterns))
    indexed.sort(key=lambda x: x[1])
    for display_num, (orig_idx, p) in enumerate(indexed, 1):
        display = p.replace('^', '').replace('\$', '')
        print(f"  {GREEN}{display_num:3}.{NC} {display}")
    # Store mapping for removal
    print(f"\n  {DIM}(sorted alphabetically){NC}")
else:
    print(f"  {DIM}(no patterns configured){NC}")
PYEOF

        echo ""
        echo -e "  ${GREEN}[a]${NC} Add pattern    ${RED}[r]${NC} Remove by number    ${BOLD}[0]${NC} Back"
        echo ""
        
        read -p "${list_type}> " action
        case $action in
            a|A|add)
                echo ""
                echo -e "${color}${BOLD}Add ${list_type} Pattern${NC}"
                echo ""
                echo -e "${DIM}Patterns use regex. Examples:${NC}"
                case $list_type in
                    kubectl)
                        echo -e "  ${CYAN}^kubectl get .*${NC}              → allows: kubectl get pods, kubectl get nodes"
                        echo -e "  ${CYAN}^kubectl apply -f .*${NC}         → allows: kubectl apply -f file.yaml"
                        echo -e "  ${CYAN}^kubectl exec .* -- .*${NC}       → allows: kubectl exec pod -- command"
                        echo -e "  ${CYAN}^kubectl delete pod .*${NC}       → allows: kubectl delete pod <name>"
                        echo -e "  ${CYAN}^kubectl scale .* --replicas=.*${NC} → allows scaling"
                        ;;
                    oci)
                        echo -e "  ${CYAN}^oci compute instance list .*${NC}     → list instances"
                        echo -e "  ${CYAN}^oci compute instance action .*${NC}   → start/stop/reset"
                        echo -e "  ${CYAN}^oci ce node-pool update .*${NC}       → update node pools"
                        echo -e "  ${CYAN}^oci ce cluster update .*${NC}         → update cluster"
                        ;;
                    helm)
                        echo -e "  ${CYAN}^helm install .*${NC}       → install charts"
                        echo -e "  ${CYAN}^helm upgrade .*${NC}       → upgrade releases"
                        echo -e "  ${CYAN}^helm uninstall .*${NC}     → uninstall releases"
                        echo -e "  ${CYAN}^helm rollback .*${NC}      → rollback releases"
                        ;;
                    bash)
                        echo -e "  ${CYAN}^cat /var/log/.*${NC}       → read log files"
                        echo -e "  ${CYAN}^ps aux.*${NC}              → list processes"
                        echo -e "  ${CYAN}^systemctl status .*${NC}   → check service status"
                        echo -e "  ${CYAN}^tail -f .*${NC}            → follow log files"
                        ;;
                esac
                echo ""
                read -p "Pattern (empty to cancel): " pattern
                if [[ -n "$pattern" ]]; then
                    python3 -c "
import json
c = json.load(open('$INSTALL_DIR/config/config.json'))
c.setdefault('allowlist', {}).setdefault('$list_type', []).append('$pattern')
json.dump(c, open('$INSTALL_DIR/config/config.json', 'w'), indent=2)
"
                    log_ok "Added: $pattern"
                fi
                ;;
            r|R|remove|[1-9]|[1-9][0-9])
                if [[ "$action" =~ ^[0-9]+$ ]]; then
                    pnum="$action"
                else
                    echo ""
                    read -p "Pattern number to remove: " pnum
                fi
                if [[ -n "$pnum" ]]; then
                    python3 -c "
import json
c = json.load(open('$INSTALL_DIR/config/config.json'))
patterns = c.get('allowlist', {}).get('$list_type', [])

# Sort to match display order
indexed = list(enumerate(patterns))
indexed.sort(key=lambda x: x[1])

display_idx = int('$pnum') - 1
if 0 <= display_idx < len(indexed):
    orig_idx = indexed[display_idx][0]
    removed = patterns.pop(orig_idx)
    json.dump(c, open('$INSTALL_DIR/config/config.json', 'w'), indent=2)
    print(f'Removed: {removed}')
else:
    print('Invalid number')
"
                fi
                ;;
            0|b|back|q)
                return
                ;;
        esac
    done
}

modify_scripts() {
    while true; do
        echo ""
        echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}${BOLD}                    Allowed Scripts${NC}"
        echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # Show current scripts with numbers (sorted)
        python3 << 'PYEOF'
import json
import os

GREEN = '\033[0;32m'
CYAN = '\033[0;36m'
DIM = '\033[2m'
NC = '\033[0m'

install_dir = os.environ.get('INSTALL_DIR', '/opt/oci-mcp-server')
c = json.load(open(f"{install_dir}/config/config.json"))
scripts = c.get('allowed_scripts', {})

if scripts:
    for i, (name, path) in enumerate(sorted(scripts.items()), 1):
        print(f"  {GREEN}{i:3}.{NC} {name:<25} → {CYAN}{path}{NC}")
else:
    print(f"  {DIM}(no scripts configured){NC}")
PYEOF

        echo ""
        echo -e "  ${GREEN}[a]${NC} Add script    ${RED}[r]${NC} Remove script    ${BOLD}[0]${NC} Back"
        echo ""
        
        read -p "scripts> " action
        case $action in
            a|A|add)
                echo ""
                echo -e "${BLUE}${BOLD}Add Allowed Script${NC}"
                echo -e "${DIM}Scripts can be called by name via the MCP run_script tool${NC}"
                echo ""
                read -p "Script name (e.g., gpu-check): " sn
                read -p "Script path (e.g., /opt/scripts/gpu-check.sh): " sp
                if [[ -n "$sn" && -n "$sp" ]]; then
                    python3 -c "
import json
c = json.load(open('$INSTALL_DIR/config/config.json'))
c.setdefault('allowed_scripts', {})['$sn'] = '$sp'
json.dump(c, open('$INSTALL_DIR/config/config.json', 'w'), indent=2)
"
                    if [[ -f "$sp" ]]; then
                        log_ok "Added: $sn → $sp"
                    else
                        log_warn "Added: $sn → $sp (file not found)"
                    fi
                fi
                ;;
            r|R|remove)
                echo ""
                read -p "Script name to remove: " sn
                if [[ -n "$sn" ]]; then
                    python3 -c "
import json
c = json.load(open('$INSTALL_DIR/config/config.json'))
if '$sn' in c.get('allowed_scripts', {}):
    del c['allowed_scripts']['$sn']
    json.dump(c, open('$INSTALL_DIR/config/config.json', 'w'), indent=2)
    print('Removed: $sn')
else:
    print('Not found: $sn')
"
                fi
                ;;
            0|b|back|q)
                return
                ;;
        esac
    done
}

# ============================================================================
# LLM API Configuration Functions
# ============================================================================

configure_claude() {
    echo ""
    echo -e "${BOLD}=== Claude API (Anthropic) ===${NC}"
    echo "Get key: https://console.anthropic.com/settings/keys"
    
    # Check if we have an existing key
    local existing_key=$(get_config "claude_api_key")
    if [[ -n "$existing_key" ]]; then
        echo ""
        echo -e "Current key: ${GREEN}${existing_key:0:12}...${existing_key: -4}${NC}"
        echo ""
        echo "  1) Update API key"
        echo "  2) Select model"
        echo "  3) List available models"
        echo "  0) Back"
        read -p "Choice: " subchoice
        
        case $subchoice in
            1) ;; # Continue to key entry below
            2) select_claude_model "$existing_key"; return ;;
            3) list_claude_models "$existing_key"; return ;;
            *) return ;;
        esac
    fi
    
    read_api_key "API key (sk-ant-...)"
    local key="$REPLY"
    [[ -z "$key" ]] && { log_warn "Cancelled"; return; }
    
    echo ""
    read -p "Test API key? (y/n) [y]: " do_test
    do_test="${do_test:-y}"
    
    if [[ "$do_test" =~ ^[Nn] ]]; then
        save_config "claude_api_key" "$key"
        save_config "claude_endpoint" "https://api.anthropic.com/v1/messages"
        log_ok "Saved (not tested)"
        echo ""
        read -p "Select model now? (y/n) [y]: " do_model
        [[ "${do_model:-y}" =~ ^[Yy] ]] && select_claude_model "$key"
        return
    fi
    
    log_test "Testing"
    local model=$(get_config "claude_model")
    model="${model:-claude-sonnet-4-20250514}"
    
    RESP=$(curl -s --connect-timeout 10 -X POST https://api.anthropic.com/v1/messages \
        -H "Content-Type: application/json" -H "x-api-key: $key" -H "anthropic-version: 2023-06-01" \
        -d "{\"model\":\"$model\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>&1)
    
    if echo "$RESP" | grep -q '"content"'; then
        log_ok "Valid"
        save_config "claude_api_key" "$key"
        save_config "claude_endpoint" "https://api.anthropic.com/v1/messages"
        log_ok "Saved"
        echo ""
        read -p "Select model now? (y/n) [y]: " do_model
        [[ "${do_model:-y}" =~ ^[Yy] ]] && select_claude_model "$key"
    elif echo "$RESP" | grep -q "authentication_error\|invalid.*api.*key\|Invalid API"; then
        log_fail "Invalid API key"
    elif echo "$RESP" | grep -q "credit\|balance\|billing\|payment"; then
        log_fail "Key valid but no credits - add funds at console.anthropic.com"
        echo ""
        read -p "Save key anyway? (y/n) [n]: " save_anyway
        if [[ "$save_anyway" =~ ^[Yy] ]]; then
            save_config "claude_api_key" "$key"
            save_config "claude_endpoint" "https://api.anthropic.com/v1/messages"
            log_ok "Saved (add credits to use)"
        fi
    elif echo "$RESP" | grep -q "Could not resolve\|Connection refused\|timed out"; then
        log_fail "Network error - cannot reach api.anthropic.com"
        echo ""
        read -p "Save key anyway? (y/n) [n]: " save_anyway
        if [[ "$save_anyway" =~ ^[Yy] ]]; then
            save_config "claude_api_key" "$key"
            save_config "claude_endpoint" "https://api.anthropic.com/v1/messages"
            log_ok "Saved (verify connectivity)"
        fi
    else
        log_fail "Test failed"
        echo -e "${DIM}Response: ${RESP:0:200}${NC}"
        echo ""
        read -p "Save key anyway? (y/n) [n]: " save_anyway
        if [[ "$save_anyway" =~ ^[Yy] ]]; then
            save_config "claude_api_key" "$key"
            save_config "claude_endpoint" "https://api.anthropic.com/v1/messages"
            log_ok "Saved"
        fi
    fi
}

list_claude_models() {
    local key="$1"
    [[ -z "$key" ]] && key=$(get_config "claude_api_key")
    [[ -z "$key" ]] && { log_warn "No API key configured"; return; }
    
    echo ""
    log_test "Fetching available models"
    
    RESP=$(curl -s --connect-timeout 10 "https://api.anthropic.com/v1/models?limit=50" \
        -H "x-api-key: $key" -H "anthropic-version: 2023-06-01" 2>&1)
    
    if echo "$RESP" | grep -q '"data"'; then
        echo -e "${GREEN}OK${NC}"
        echo ""
        echo -e "${BOLD}Available Claude Models:${NC}"
        echo -e "${BOLD}─────────────────────────────────────────────────────────────────────────${NC}"
        
        # Parse and display models
        echo "$RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
models = data.get('data', [])

# Group by family
families = {}
for m in models:
    mid = m.get('id', '')
    name = m.get('display_name', mid)
    
    # Determine family
    if 'opus-4-5' in mid or 'opus-4.5' in mid:
        family = 'Opus 4.5'
    elif 'opus-4-1' in mid or 'opus-4.1' in mid:
        family = 'Opus 4.1'
    elif 'opus-4' in mid:
        family = 'Opus 4'
    elif 'sonnet-4-5' in mid or 'sonnet-4.5' in mid:
        family = 'Sonnet 4.5'
    elif 'sonnet-4' in mid:
        family = 'Sonnet 4'
    elif 'haiku-4-5' in mid or 'haiku-4.5' in mid:
        family = 'Haiku 4.5'
    elif 'haiku-4' in mid:
        family = 'Haiku 4'
    elif '3-5-sonnet' in mid or '3.5-sonnet' in mid:
        family = 'Claude 3.5 Sonnet'
    elif '3-5-haiku' in mid or '3.5-haiku' in mid:
        family = 'Claude 3.5 Haiku'
    elif '3-opus' in mid:
        family = 'Claude 3 Opus'
    elif '3-sonnet' in mid:
        family = 'Claude 3 Sonnet'
    elif '3-haiku' in mid:
        family = 'Claude 3 Haiku'
    else:
        family = 'Other'
    
    if family not in families:
        families[family] = []
    families[family].append((mid, name))

# Print grouped
order = ['Opus 4.5', 'Sonnet 4.5', 'Haiku 4.5', 'Opus 4.1', 'Opus 4', 'Sonnet 4', 'Haiku 4', 
         'Claude 3.5 Sonnet', 'Claude 3.5 Haiku', 'Claude 3 Opus', 'Claude 3 Sonnet', 'Claude 3 Haiku', 'Other']

for family in order:
    if family in families:
        print(f'\n  \033[1;36m{family}\033[0m')
        for mid, name in sorted(families[family]):
            print(f'    {mid}')
"
        echo ""
    else
        echo -e "${RED}Failed${NC}"
        echo -e "${DIM}${RESP:0:200}${NC}"
    fi
}

select_claude_model() {
    local key="$1"
    [[ -z "$key" ]] && key=$(get_config "claude_api_key")
    [[ -z "$key" ]] && { log_warn "No API key configured"; return; }
    
    echo ""
    log_test "Fetching available models"
    
    RESP=$(curl -s --connect-timeout 10 "https://api.anthropic.com/v1/models?limit=50" \
        -H "x-api-key: $key" -H "anthropic-version: 2023-06-01" 2>&1)
    
    if ! echo "$RESP" | grep -q '"data"'; then
        echo -e "${RED}Failed${NC}"
        echo ""
        echo "Common models (enter manually):"
        echo "  claude-opus-4-5-20251101"
        echo "  claude-sonnet-4-5-20250929"
        echo "  claude-sonnet-4-20250514"
        echo "  claude-haiku-4-5-20251015"
        echo "  claude-3-5-sonnet-20241022"
        echo ""
        read -p "Model ID: " model_id
        if [[ -n "$model_id" ]]; then
            save_config "claude_model" "$model_id"
            log_ok "Model set to: $model_id"
        fi
        return
    fi
    
    echo -e "${GREEN}OK${NC}"
    echo ""
    
    # Get current model
    local current_model=$(get_config "claude_model")
    [[ -n "$current_model" ]] && echo -e "Current model: ${GREEN}$current_model${NC}"
    echo ""
    
    # Parse models into array
    mapfile -t models < <(echo "$RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('data', []):
    print(m.get('id', ''))
" | sort)
    
    echo -e "${BOLD}Select a model:${NC}"
    echo ""
    
    # Display with numbers
    local i=1
    for model in "${models[@]}"; do
        [[ -z "$model" ]] && continue
        
        # Color code by type
        if [[ "$model" == *"opus"* ]]; then
            echo -e "  ${MAGENTA}$i)${NC} $model"
        elif [[ "$model" == *"sonnet"* ]]; then
            echo -e "  ${CYAN}$i)${NC} $model"
        elif [[ "$model" == *"haiku"* ]]; then
            echo -e "  ${GREEN}$i)${NC} $model"
        else
            echo -e "  $i) $model"
        fi
        ((i++))
    done
    
    echo ""
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    
    read -p "Select (1-$((i-1))): " selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -lt "$i" ]]; then
        local selected_model="${models[$((selection-1))]}"
        save_config "claude_model" "$selected_model"
        log_ok "Model set to: $selected_model"
    elif [[ "$selection" != "0" ]]; then
        log_warn "Cancelled"
    fi
}

configure_openai() {
    echo ""
    echo -e "${BOLD}=== OpenAI API (ChatGPT) ===${NC}"
    echo "Get key: https://platform.openai.com/api-keys"
    read_api_key "API key (sk-...)"
    local key="$REPLY"
    [[ -z "$key" ]] && { log_warn "Cancelled"; return; }
    
    log_test "Testing"
    RESP=$(curl -s --connect-timeout 10 https://api.openai.com/v1/models -H "Authorization: Bearer $key" 2>/dev/null)
    
    if echo "$RESP" | grep -q '"data"'; then
        log_ok "Valid"
        save_config "openai_api_key" "$key"
        save_config "openai_endpoint" "https://api.openai.com/v1"
        log_ok "Saved"
    else
        log_fail "Invalid key"
    fi
}

configure_oracle() {
    echo ""
    echo -e "${BOLD}=== Oracle GenAI ===${NC}"
    echo "Uses OCI CLI authentication (~/.oci/config)"
    
    if ! command -v oci &>/dev/null; then
        log_fail "OCI CLI not installed"
        echo "Install: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"
        return
    fi
    
    log_test "Checking OCI config"
    if oci iam region list --output table &>/dev/null; then
        log_ok "OK"
    else
        log_fail "Run: oci setup config"; return
    fi
    
    # Check if already configured
    local existing_comp=$(get_config "oracle_compartment_id")
    local existing_region=$(get_config "oracle_region")
    local existing_model=$(get_config "oracle_model")
    
    if [[ -n "$existing_comp" ]]; then
        echo ""
        echo -e "Current config:"
        echo -e "  Region: ${GREEN}$existing_region${NC}"
        echo -e "  Compartment: ${GREEN}${existing_comp:0:40}...${NC}"
        [[ -n "$existing_model" ]] && echo -e "  Model: ${GREEN}$existing_model${NC}"
        echo ""
        echo "  1) Update configuration"
        echo "  2) List available models"
        echo "  3) Select model"
        echo "  4) Test inference"
        echo "  0) Back"
        read -p "Choice: " subchoice
        
        case $subchoice in
            1) ;; # Continue to config below
            2) list_oracle_models "$existing_comp" "$existing_region"; return ;;
            3) select_oracle_model "$existing_comp" "$existing_region"; return ;;
            4) test_oracle_inference "$existing_comp" "$existing_region" "$existing_model"; return ;;
            *) return ;;
        esac
    fi
    
    echo ""
    echo "GenAI-enabled regions:"
    echo "  1) us-chicago-1      5) ap-tokyo-1"
    echo "  2) us-ashburn-1      6) ap-sydney-1"
    echo "  3) uk-london-1       7) sa-saopaulo-1"
    echo "  4) eu-frankfurt-1"
    read -p "Select [1]: " r
    case "${r:-1}" in
        1) REGION="us-chicago-1" ;; 2) REGION="us-ashburn-1" ;;
        3) REGION="uk-london-1" ;; 4) REGION="eu-frankfurt-1" ;;
        5) REGION="ap-tokyo-1" ;; 6) REGION="ap-sydney-1" ;;
        7) REGION="sa-saopaulo-1" ;; *) REGION="us-chicago-1" ;;
    esac
    
    echo ""
    echo "Enter Compartment OCID (or tenancy OCID to use root compartment)"
    echo -e "${DIM}Find at: OCI Console → Identity → Compartments${NC}"
    read -p "OCID: " comp
    [[ -z "$comp" ]] && { log_warn "Cancelled"; return; }
    
    log_test "Testing GenAI access"
    RESP=$(oci generative-ai model-collection list-models --compartment-id "$comp" --region "$REGION" 2>&1)
    
    if echo "$RESP" | grep -q '"items"'; then
        log_ok "Valid"
        save_config "oracle_compartment_id" "$comp"
        save_config "oracle_region" "$REGION"
        log_ok "Saved"
        
        # Count models
        model_count=$(echo "$RESP" | grep -c '"display-name"')
        echo -e "  ${CYAN}Found $model_count models available${NC}"
        
        echo ""
        read -p "Select a model now? (y/n) [y]: " do_model
        [[ "${do_model:-y}" =~ ^[Yy] ]] && select_oracle_model "$comp" "$REGION"
    elif echo "$RESP" | grep -q "NotAuthorized\|not authorized\|Access denied"; then
        log_fail "Access denied - missing IAM policy"
        echo ""
        echo -e "${YELLOW}Add this policy in OCI Console → Identity → Policies:${NC}"
        echo -e "${CYAN}Allow group <your-group> to manage generative-ai-family in tenancy${NC}"
    elif echo "$RESP" | grep -q "NotFound\|not found"; then
        log_fail "Compartment not found"
    else
        log_fail "Failed"
        echo -e "${DIM}${RESP:0:200}${NC}"
    fi
}

list_oracle_models() {
    local comp="$1"
    local region="$2"
    [[ -z "$comp" ]] && comp=$(get_config "oracle_compartment_id")
    [[ -z "$region" ]] && region=$(get_config "oracle_region")
    
    [[ -z "$comp" || -z "$region" ]] && { log_warn "Not configured"; return; }
    
    echo ""
    log_test "Fetching models from $region"
    
    RESP=$(oci generative-ai model-collection list-models --compartment-id "$comp" --region "$region" 2>&1)
    
    if ! echo "$RESP" | grep -q '"items"'; then
        echo -e "${RED}Failed${NC}"
        return
    fi
    
    echo -e "${GREEN}OK${NC}"
    echo ""
    echo -e "${BOLD}Available Oracle GenAI Models:${NC}"
    echo -e "${BOLD}─────────────────────────────────────────────────────────────────────────${NC}"
    
    echo "$RESP" | python3 -c "
import sys, json

data = json.load(sys.stdin)
models = data.get('data', {}).get('items', [])

# Group by vendor
vendors = {}
for m in models:
    vendor = m.get('vendor', 'unknown')
    name = m.get('display-name', '')
    mid = m.get('id', '')
    caps = ', '.join(m.get('capabilities', []))
    state = m.get('lifecycle-state', '')
    
    if state != 'ACTIVE':
        continue
    
    if vendor not in vendors:
        vendors[vendor] = []
    vendors[vendor].append((name, caps, mid))

for vendor in sorted(vendors.keys()):
    print(f'\n  \033[1;36m{vendor.upper()}\033[0m')
    for name, caps, mid in sorted(vendors[vendor]):
        print(f'    {name:<40} [{caps}]')
"
    echo ""
}

select_oracle_model() {
    local comp="$1"
    local region="$2"
    [[ -z "$comp" ]] && comp=$(get_config "oracle_compartment_id")
    [[ -z "$region" ]] && region=$(get_config "oracle_region")
    
    [[ -z "$comp" || -z "$region" ]] && { log_warn "Not configured"; return; }
    
    echo ""
    log_test "Fetching models"
    
    RESP=$(oci generative-ai model-collection list-models --compartment-id "$comp" --region "$region" 2>&1)
    
    if ! echo "$RESP" | grep -q '"items"'; then
        echo -e "${RED}Failed${NC}"
        return
    fi
    
    echo -e "${GREEN}OK${NC}"
    echo ""
    
    # Get current model
    local current_model=$(get_config "oracle_model")
    [[ -n "$current_model" ]] && echo -e "Current model: ${GREEN}$current_model${NC}"
    echo ""
    
    # Parse models into array
    mapfile -t models < <(echo "$RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('data', {}).get('items', []):
    if m.get('lifecycle-state') == 'ACTIVE':
        print(m.get('display-name', ''))
" | sort -u)
    
    echo -e "${BOLD}Select a model:${NC}"
    echo ""
    
    local i=1
    for model in "${models[@]}"; do
        [[ -z "$model" ]] && continue
        
        if [[ "$model" == *"cohere"* ]]; then
            echo -e "  ${CYAN}$i)${NC} $model"
        elif [[ "$model" == *"meta"* || "$model" == *"llama"* ]]; then
            echo -e "  ${MAGENTA}$i)${NC} $model"
        else
            echo -e "  $i) $model"
        fi
        ((i++))
    done
    
    echo ""
    echo -e "  ${BOLD}0)${NC} Cancel"
    echo ""
    
    read -p "Select (1-$((i-1))): " selection
    
    if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -lt "$i" ]]; then
        local selected_model="${models[$((selection-1))]}"
        save_config "oracle_model" "$selected_model"
        log_ok "Model set to: $selected_model"
    elif [[ "$selection" != "0" ]]; then
        log_warn "Cancelled"
    fi
}

test_oracle_inference() {
    local comp="$1"
    local region="$2"
    local model="$3"
    
    [[ -z "$comp" ]] && comp=$(get_config "oracle_compartment_id")
    [[ -z "$region" ]] && region=$(get_config "oracle_region")
    [[ -z "$model" ]] && model=$(get_config "oracle_model")
    
    [[ -z "$comp" || -z "$region" ]] && { log_warn "Not configured"; return; }
    [[ -z "$model" ]] && { log_warn "No model selected - use option 3 first"; return; }
    
    echo ""
    echo -e "${BOLD}Testing Oracle GenAI Inference${NC}"
    echo -e "  Region: ${CYAN}$region${NC}"
    echo -e "  Compartment: ${CYAN}${comp:0:50}...${NC}"
    echo -e "  Model: ${CYAN}$model${NC}"
    echo ""
    
    local msg="Hello! Please respond with a brief greeting."
    
    # Determine API format based on model vendor
    local api_format="GENERIC"
    local chat_request=""
    
    if [[ "$model" == cohere.* ]]; then
        api_format="COHERE"
        chat_request="{\"apiFormat\":\"COHERE\",\"message\":\"$msg\",\"maxTokens\":100}"
    else
        # GENERIC format for Meta, xAI, and others
        chat_request="{\"apiFormat\":\"GENERIC\",\"messages\":[{\"role\":\"USER\",\"content\":[{\"type\":\"TEXT\",\"text\":\"$msg\"}]}],\"maxTokens\":100}"
    fi
    
    local serving_mode="{\"servingType\":\"ON_DEMAND\",\"modelId\":\"$model\"}"
    
    echo -e "${DIM}API Format: $api_format${NC}"
    echo ""
    log_test "Sending test message"
    
    RESP=$(oci generative-ai-inference chat-result chat \
        --region "$region" \
        --compartment-id "$comp" \
        --serving-mode "$serving_mode" \
        --chat-request "$chat_request" 2>&1)
    
    if echo "$RESP" | grep -q '"chat-response"'; then
        log_ok "Success!"
        echo ""
        echo -e "${BOLD}Response:${NC}"
        echo "$RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    cr = d.get('data', {}).get('chat-response', {})
    
    # Try Cohere format
    if 'text' in cr:
        print(cr['text'])
    # Try Generic format
    elif 'choices' in cr:
        for c in cr.get('choices', []):
            msg = c.get('message', {})
            for content in msg.get('content', []):
                if content.get('type') == 'TEXT':
                    print(content.get('text', ''))
    else:
        print(json.dumps(cr, indent=2))
except Exception as e:
    print(f'Parse error: {e}')
"
    elif echo "$RESP" | grep -q "NotAuthorized\|not authorized"; then
        log_fail "Not authorized"
        echo ""
        echo -e "${YELLOW}Check IAM policy: Allow group <group> to use generative-ai-family in tenancy${NC}"
    elif echo "$RESP" | grep -q "ModelNotFound\|not found\|InvalidParameter"; then
        log_fail "Model not found or invalid"
        echo ""
        echo -e "${YELLOW}The model '$model' may not be available in region $region${NC}"
        echo "Try: List available models (option 2) and select a different one"
    else
        log_fail "Failed"
        echo ""
        echo -e "${DIM}Response:${NC}"
        echo "${RESP:0:500}"
    fi
}

configure_grok() {
    echo ""
    echo -e "${BOLD}=== Grok API (xAI) ===${NC}"
    echo "Get key: https://console.x.ai/"
    read_api_key "API key"
    local key="$REPLY"
    [[ -z "$key" ]] && { log_warn "Cancelled"; return; }
    
    log_test "Testing"
    RESP=$(curl -s --connect-timeout 10 https://api.x.ai/v1/models -H "Authorization: Bearer $key" 2>/dev/null)
    
    if echo "$RESP" | grep -q '"data"\|"id"'; then
        log_ok "Valid"
        save_config "grok_api_key" "$key"
        save_config "grok_endpoint" "https://api.x.ai/v1"
        log_ok "Saved"
    else
        log_fail "Invalid key"
    fi
}

configure_gemini() {
    echo ""
    echo -e "${BOLD}=== Gemini API (Google) ===${NC}"
    echo "Get key: https://aistudio.google.com/apikey"
    read_api_key "API key"
    local key="$REPLY"
    [[ -z "$key" ]] && { log_warn "Cancelled"; return; }
    
    log_test "Testing"
    RESP=$(curl -s --connect-timeout 10 "https://generativelanguage.googleapis.com/v1/models?key=$key" 2>/dev/null)
    
    if echo "$RESP" | grep -q '"models"'; then
        log_ok "Valid"
        save_config "gemini_api_key" "$key"
        save_config "gemini_endpoint" "https://generativelanguage.googleapis.com/v1"
        log_ok "Saved"
    else
        log_fail "Invalid key"
    fi
}

configure_mistral() {
    echo ""
    echo -e "${BOLD}=== Mistral API ===${NC}"
    echo "Get key: https://console.mistral.ai/api-keys/"
    read_api_key "API key"
    local key="$REPLY"
    [[ -z "$key" ]] && { log_warn "Cancelled"; return; }
    
    log_test "Testing"
    RESP=$(curl -s --connect-timeout 10 https://api.mistral.ai/v1/models -H "Authorization: Bearer $key" 2>/dev/null)
    
    if echo "$RESP" | grep -q '"data"'; then
        log_ok "Valid"
        save_config "mistral_api_key" "$key"
        save_config "mistral_endpoint" "https://api.mistral.ai/v1"
        log_ok "Saved"
    else
        log_fail "Invalid key"
    fi
}

configure_groq() {
    echo ""
    echo -e "${BOLD}=== Groq API ===${NC}"
    echo "Get key: https://console.groq.com/keys"
    read_api_key "API key (gsk_...)"
    local key="$REPLY"
    [[ -z "$key" ]] && { log_warn "Cancelled"; return; }
    
    log_test "Testing"
    RESP=$(curl -s --connect-timeout 10 https://api.groq.com/openai/v1/models -H "Authorization: Bearer $key" 2>/dev/null)
    
    if echo "$RESP" | grep -q '"data"'; then
        log_ok "Valid"
        save_config "groq_api_key" "$key"
        save_config "groq_endpoint" "https://api.groq.com/openai/v1"
        log_ok "Saved"
    else
        log_fail "Invalid key"
    fi
}

configure_ollama() {
    echo ""
    echo -e "${BOLD}=== Ollama (Local) ===${NC}"
    read -p "Ollama URL [http://localhost:11434]: " url
    url="${url:-http://localhost:11434}"
    
    log_test "Testing connection"
    RESP=$(curl -s --connect-timeout 5 "$url/api/tags" 2>/dev/null)
    
    if echo "$RESP" | grep -q '"models"'; then
        log_ok "Connected"
        save_config "ollama_endpoint" "$url"
        echo "Models:"
        echo "$RESP" | python3 -c "import sys,json; [print(f'  - {m[\"name\"]}') for m in json.load(sys.stdin).get('models',[])]" 2>/dev/null
        log_ok "Saved"
    else
        log_fail "Cannot connect to $url"
    fi
}

configure_azure_openai() {
    echo ""
    echo -e "${BOLD}=== Azure OpenAI ===${NC}"
    echo "Get from: Azure Portal > Azure OpenAI > Keys and Endpoint"
    read -p "Endpoint (https://xxx.openai.azure.com): " endpoint
    read_api_key "API key"
    local key="$REPLY"
    read -p "Deployment name: " deployment
    [[ -z "$key" || -z "$endpoint" ]] && { log_warn "Cancelled"; return; }
    
    log_test "Testing"
    RESP=$(curl -s --connect-timeout 10 "$endpoint/openai/deployments?api-version=2023-05-15" -H "api-key: $key" 2>/dev/null)
    
    if echo "$RESP" | grep -q '"data"\|"value"'; then
        log_ok "Valid"
        save_config "azure_openai_endpoint" "$endpoint"
        save_config "azure_openai_key" "$key"
        save_config "azure_openai_deployment" "$deployment"
        log_ok "Saved"
    else
        log_fail "Invalid configuration"
    fi
}

configure_bedrock() {
    echo ""
    echo -e "${BOLD}=== AWS Bedrock ===${NC}"
    echo "Uses AWS CLI credentials (~/.aws/credentials)"
    
    if ! command -v aws &>/dev/null; then
        log_fail "AWS CLI not installed"; return
    fi
    
    log_test "Checking AWS config"
    if aws sts get-caller-identity &>/dev/null; then
        log_ok "OK"
    else
        log_fail "Run: aws configure"; return
    fi
    
    read -p "AWS Region [us-east-1]: " region
    region="${region:-us-east-1}"
    
    log_test "Testing Bedrock access"
    if aws bedrock list-foundation-models --region "$region" &>/dev/null; then
        log_ok "Valid"
        save_config "bedrock_region" "$region"
        save_config "bedrock_enabled" "true"
        log_ok "Saved"
    else
        log_fail "Access denied"
    fi
}

configure_cohere() {
    echo ""
    echo -e "${BOLD}=== Cohere API ===${NC}"
    echo "Get key: https://dashboard.cohere.com/api-keys"
    read_api_key "API key"
    local key="$REPLY"
    [[ -z "$key" ]] && { log_warn "Cancelled"; return; }
    
    log_test "Testing"
    RESP=$(curl -s --connect-timeout 10 https://api.cohere.ai/v1/models -H "Authorization: Bearer $key" 2>/dev/null)
    
    if echo "$RESP" | grep -q '"models"'; then
        log_ok "Valid"
        save_config "cohere_api_key" "$key"
        save_config "cohere_endpoint" "https://api.cohere.ai/v1"
        log_ok "Saved"
    else
        log_fail "Invalid key"
    fi
}

configure_perplexity() {
    echo ""
    echo -e "${BOLD}=== Perplexity API ===${NC}"
    echo "Get key: https://www.perplexity.ai/settings/api"
    read_api_key "API key (pplx_...)"
    local key="$REPLY"
    [[ -z "$key" ]] && { log_warn "Cancelled"; return; }
    
    log_test "Testing"
    RESP=$(curl -s --connect-timeout 10 https://api.perplexity.ai/chat/completions \
        -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
        -d '{"model":"llama-3.1-sonar-small-128k-online","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' 2>/dev/null)
    
    if echo "$RESP" | grep -q '"choices"'; then
        log_ok "Valid"
        save_config "perplexity_api_key" "$key"
        save_config "perplexity_endpoint" "https://api.perplexity.ai"
        log_ok "Saved"
    else
        log_fail "Invalid key"
    fi
}

# ============================================================================
# View / Clear Config
# ============================================================================

view_api_config() {
    echo ""
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}                    API Configuration${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Config file:${NC} $API_CONFIG_FILE"
    echo ""
    
    if [[ ! -f "$API_CONFIG_FILE" ]]; then
        echo -e "  ${YELLOW}No APIs configured yet${NC}"
        echo ""
        return
    fi
    
    python3 << 'PYEOF'
import json
import os

# ANSI colors
GREEN = '\033[0;32m'
RED = '\033[0;31m'
YELLOW = '\033[1;33m'
CYAN = '\033[0;36m'
BOLD = '\033[1m'
DIM = '\033[2m'
NC = '\033[0m'

config_file = os.path.expanduser("~/.config/ai-api/config.json")

try:
    with open(config_file) as f:
        c = json.load(f)
except:
    print(f"  {YELLOW}No APIs configured yet{NC}")
    exit()

# Define API groups with their config keys
apis = [
    ("Claude (Anthropic)", "claude_api_key", "claude_endpoint"),
    ("OpenAI (ChatGPT)", "openai_api_key", "openai_endpoint"),
    ("Oracle GenAI", "oracle_compartment_id", "oracle_region"),
    ("Grok (xAI)", "grok_api_key", "grok_endpoint"),
    ("Gemini (Google)", "gemini_api_key", "gemini_endpoint"),
    ("Mistral", "mistral_api_key", "mistral_endpoint"),
    ("Groq", "groq_api_key", "groq_endpoint"),
    ("Ollama (Local)", "ollama_endpoint", None),
    ("Azure OpenAI", "azure_openai_key", "azure_openai_endpoint"),
    ("AWS Bedrock", "bedrock_enabled", "bedrock_region"),
    ("Cohere", "cohere_api_key", "cohere_endpoint"),
    ("Perplexity", "perplexity_api_key", "perplexity_endpoint"),
]

def mask_key(val):
    if not val:
        return ""
    if len(val) > 16:
        return f"{val[:8]}...{val[-4:]}"
    elif len(val) > 8:
        return f"{val[:4]}...{val[-2:]}"
    else:
        return "***"

def format_val(key, val):
    if not val:
        return f"{DIM}not set{NC}"
    if "key" in key.lower() or "secret" in key.lower():
        return f"{GREEN}{mask_key(val)}{NC}"
    return f"{GREEN}{val}{NC}"

print(f"  {BOLD}{'Provider':<22} {'Status':<12} {'Details':<40}{NC}")
print(f"  {'-'*22} {'-'*12} {'-'*40}")

configured_count = 0
for name, primary_key, secondary_key in apis:
    primary_val = c.get(primary_key, "")
    secondary_val = c.get(secondary_key, "") if secondary_key else ""
    
    if primary_val:
        configured_count += 1
        status = f"{GREEN}●  Configured{NC}"
        
        # Build details string
        if "key" in primary_key.lower():
            details = f"Key: {mask_key(primary_val)}"
        elif primary_key == "oracle_compartment_id":
            details = f"Compartment: {primary_val[:20]}..."
        elif primary_key == "bedrock_enabled":
            details = f"Enabled: {primary_val}"
        elif primary_key == "ollama_endpoint":
            details = f"URL: {primary_val}"
        else:
            details = f"{primary_val[:35]}..."
        
        # Add model info for Claude
        if name == "Claude (Anthropic)":
            model = c.get("claude_model", "")
            if model:
                details += f" | Model: {model}"
        
        # Add model info for Oracle
        if name == "Oracle GenAI":
            model = c.get("oracle_model", "")
            if model:
                details += f" | Model: {model}"
        
        # Add secondary info
        if secondary_val:
            if secondary_key == "oracle_region":
                details += f" | Region: {secondary_val}"
            elif secondary_key == "bedrock_region":
                details += f" | Region: {secondary_val}"
            elif secondary_key == "azure_openai_endpoint":
                details += f" | {secondary_val[:20]}..."
    else:
        status = f"{DIM}○  Not set{NC}"
        details = f"{DIM}—{NC}"
    
    print(f"  {name:<22} {status:<23} {details}")

print("")
print(f"  {BOLD}Summary:{NC} {GREEN}{configured_count}{NC} of {len(apis)} APIs configured")

# Show any extra keys not in standard list
known_keys = set()
for _, k1, k2 in apis:
    known_keys.add(k1)
    if k2:
        known_keys.add(k2)
known_keys.add("azure_openai_deployment")
known_keys.add("claude_model")
known_keys.add("oracle_model")

extra_keys = set(c.keys()) - known_keys
if extra_keys:
    print("")
    print(f"  {BOLD}Additional settings:{NC}")
    for k in sorted(extra_keys):
        print(f"    {CYAN}{k}:{NC} {format_val(k, c[k])}")

PYEOF
    echo ""
}

clear_api_config() {
    echo ""
    [[ ! -f "$API_CONFIG_FILE" ]] && { log_warn "No configuration"; return; }
    read -p "Clear ALL API configuration? (yes/no): " confirm
    [[ "$confirm" == "yes" ]] && { rm -f "$API_CONFIG_FILE"; log_ok "Cleared"; } || log_warn "Cancelled"
}

# ============================================================================
# LLM Submenu
# ============================================================================

llm_submenu() {
    while true; do
        print_llm_menu
        read -p "llm> " choice
        case $choice in
            1) configure_claude ;;
            2) configure_openai ;;
            3) configure_oracle ;;
            4) configure_grok ;;
            5) configure_gemini ;;
            6) configure_mistral ;;
            7) configure_groq ;;
            8) configure_ollama ;;
            9) configure_azure_openai ;;
            10) configure_bedrock ;;
            11) configure_cohere ;;
            12) configure_perplexity ;;
            99) clear_api_config ;;
            0|b|back) return ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# ============================================================================
# Comprehensive Testing
# ============================================================================

test_all() {
    echo ""
    echo -e "${MAGENTA}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}${BOLD}                  COMPREHENSIVE SYSTEM TEST${NC}"
    echo -e "${MAGENTA}${BOLD}════════════════════════════════════════════════════════════${NC}"
    
    # MCP Server Section
    echo ""
    echo -e "${BLUE}${BOLD}┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}${BOLD}│  MCP SERVER                                             │${NC}"
    echo -e "${BLUE}${BOLD}└─────────────────────────────────────────────────────────┘${NC}"
    echo ""
    log_test "  Installation"; [[ -d "$INSTALL_DIR" ]] && log_ok "Installed" || log_fail "Not installed"
    log_test "  Server script"; [[ -f "$INSTALL_DIR/server.py" ]] && log_ok "OK" || log_fail "Missing"
    log_test "  Virtualenv"; [[ -d "$INSTALL_DIR/venv" ]] && log_ok "OK" || log_fail "Missing"
    
    if [[ -d "$INSTALL_DIR/venv" ]]; then
        log_test "  MCP module"
        source "$INSTALL_DIR/venv/bin/activate" 2>/dev/null
        python -c "import mcp" 2>/dev/null && log_ok "OK" || log_fail "Missing"
        deactivate 2>/dev/null
    fi
    
    # System Tools Section
    echo ""
    echo -e "${CYAN}${BOLD}┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}${BOLD}│  SYSTEM TOOLS                                           │${NC}"
    echo -e "${CYAN}${BOLD}└─────────────────────────────────────────────────────────┘${NC}"
    echo ""
    log_test "  kubectl"; command -v kubectl &>/dev/null && log_ok "$(kubectl version --client --short 2>/dev/null || echo 'Found')" || log_fail "Missing"
    log_test "  oci"; command -v oci &>/dev/null && log_ok "$(oci --version 2>/dev/null | head -1)" || log_fail "Missing"
    log_test "  helm"; command -v helm &>/dev/null && log_ok "$(helm version --short 2>/dev/null)" || log_warn "Missing (optional)"
    log_test "  aws"; command -v aws &>/dev/null && log_ok "Found" || echo -e "${YELLOW}[SKIP]${NC} Not installed"
    
    # Kubernetes Section
    echo ""
    echo -e "${GREEN}${BOLD}┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${GREEN}${BOLD}│  KUBERNETES CLUSTER                                     │${NC}"
    echo -e "${GREEN}${BOLD}└─────────────────────────────────────────────────────────┘${NC}"
    echo ""
    log_test "  Cluster connection"
    if kubectl cluster-info &>/dev/null; then
        log_ok "Connected"
        log_test "  Node count"; log_ok "$(kubectl get nodes --no-headers 2>/dev/null | wc -l) nodes"
        log_test "  Ready nodes"; log_ok "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready') ready"
    else
        log_fail "Cannot connect"
    fi
    
    # API Connectivity Section
    echo ""
    echo -e "${YELLOW}${BOLD}┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}${BOLD}│  API ENDPOINT CONNECTIVITY                              │${NC}"
    echo -e "${YELLOW}${BOLD}└─────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    declare -A ENDPOINTS=(
        ["Claude"]="https://api.anthropic.com"
        ["OpenAI"]="https://api.openai.com"
        ["Gemini"]="https://generativelanguage.googleapis.com"
        ["Mistral"]="https://api.mistral.ai"
        ["Groq"]="https://api.groq.com"
        ["Cohere"]="https://api.cohere.ai"
        ["Perplexity"]="https://api.perplexity.ai"
        ["Grok"]="https://api.x.ai"
    )
    
    for name in Claude OpenAI Grok Gemini Mistral Groq Cohere Perplexity; do
        log_test "  $name"
        curl -s --connect-timeout 5 "${ENDPOINTS[$name]}" &>/dev/null && log_ok "Reachable" || log_warn "Unreachable"
    done
    
    # API Authentication Section
    echo ""
    echo -e "${MAGENTA}${BOLD}┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${MAGENTA}${BOLD}│  API AUTHENTICATION                                     │${NC}"
    echo -e "${MAGENTA}${BOLD}└─────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    # Claude
    KEY=$(get_config "claude_api_key")
    log_test "  Claude"
    if [[ -n "$KEY" ]]; then
        RESP=$(curl -s --connect-timeout 10 -X POST https://api.anthropic.com/v1/messages \
            -H "Content-Type: application/json" -H "x-api-key: $KEY" -H "anthropic-version: 2023-06-01" \
            -d '{"model":"claude-sonnet-4-20250514","max_tokens":5,"messages":[{"role":"user","content":"1"}]}' 2>/dev/null)
        echo "$RESP" | grep -q '"content"' && log_ok "Authenticated" || log_fail "Auth failed"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # OpenAI
    KEY=$(get_config "openai_api_key")
    log_test "  OpenAI"
    if [[ -n "$KEY" ]]; then
        RESP=$(curl -s --connect-timeout 10 https://api.openai.com/v1/models -H "Authorization: Bearer $KEY" 2>/dev/null)
        echo "$RESP" | grep -q '"data"' && log_ok "Authenticated" || log_fail "Auth failed"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # Oracle
    COMP=$(get_config "oracle_compartment_id")
    log_test "  Oracle GenAI"
    if [[ -n "$COMP" ]]; then
        REGION=$(get_config "oracle_region")
        oci generative-ai model-collection list-models --compartment-id "$COMP" --region "${REGION:-us-chicago-1}" &>/dev/null && log_ok "Authenticated" || log_fail "Auth failed"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # Grok
    KEY=$(get_config "grok_api_key")
    log_test "  Grok"
    if [[ -n "$KEY" ]]; then
        RESP=$(curl -s --connect-timeout 10 https://api.x.ai/v1/models -H "Authorization: Bearer $KEY" 2>/dev/null)
        echo "$RESP" | grep -q '"data"\|"id"' && log_ok "Authenticated" || log_fail "Auth failed"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # Gemini
    KEY=$(get_config "gemini_api_key")
    log_test "  Gemini"
    if [[ -n "$KEY" ]]; then
        RESP=$(curl -s --connect-timeout 10 "https://generativelanguage.googleapis.com/v1/models?key=$KEY" 2>/dev/null)
        echo "$RESP" | grep -q '"models"' && log_ok "Authenticated" || log_fail "Auth failed"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # Mistral
    KEY=$(get_config "mistral_api_key")
    log_test "  Mistral"
    if [[ -n "$KEY" ]]; then
        RESP=$(curl -s --connect-timeout 10 https://api.mistral.ai/v1/models -H "Authorization: Bearer $KEY" 2>/dev/null)
        echo "$RESP" | grep -q '"data"' && log_ok "Authenticated" || log_fail "Auth failed"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # Groq
    KEY=$(get_config "groq_api_key")
    log_test "  Groq"
    if [[ -n "$KEY" ]]; then
        RESP=$(curl -s --connect-timeout 10 https://api.groq.com/openai/v1/models -H "Authorization: Bearer $KEY" 2>/dev/null)
        echo "$RESP" | grep -q '"data"' && log_ok "Authenticated" || log_fail "Auth failed"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # Cohere
    KEY=$(get_config "cohere_api_key")
    log_test "  Cohere"
    if [[ -n "$KEY" ]]; then
        RESP=$(curl -s --connect-timeout 10 https://api.cohere.ai/v1/models -H "Authorization: Bearer $KEY" 2>/dev/null)
        echo "$RESP" | grep -q '"models"' && log_ok "Authenticated" || log_fail "Auth failed"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # Perplexity
    KEY=$(get_config "perplexity_api_key")
    log_test "  Perplexity"
    if [[ -n "$KEY" ]]; then
        RESP=$(curl -s --connect-timeout 10 https://api.perplexity.ai/chat/completions \
            -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
            -d '{"model":"llama-3.1-sonar-small-128k-online","messages":[{"role":"user","content":"1"}],"max_tokens":5}' 2>/dev/null)
        echo "$RESP" | grep -q '"choices"' && log_ok "Authenticated" || log_fail "Auth failed"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # Azure
    KEY=$(get_config "azure_openai_key")
    log_test "  Azure OpenAI"
    if [[ -n "$KEY" ]]; then
        ENDPOINT=$(get_config "azure_openai_endpoint")
        RESP=$(curl -s --connect-timeout 10 "$ENDPOINT/openai/deployments?api-version=2023-05-15" -H "api-key: $KEY" 2>/dev/null)
        echo "$RESP" | grep -q '"data"\|"value"' && log_ok "Authenticated" || log_fail "Auth failed"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # Bedrock
    log_test "  AWS Bedrock"
    if [[ "$(get_config bedrock_enabled)" == "true" ]]; then
        aws bedrock list-foundation-models --region "$(get_config bedrock_region)" &>/dev/null && log_ok "Authenticated" || log_fail "Auth failed"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # Ollama
    log_test "  Ollama"
    OLLAMA_URL=$(get_config "ollama_endpoint")
    if [[ -n "$OLLAMA_URL" ]]; then
        curl -s --connect-timeout 5 "$OLLAMA_URL/api/tags" &>/dev/null && log_ok "Connected" || log_fail "Not running"
    else
        echo -e "${YELLOW}[SKIP]${NC} Not configured"
    fi
    
    # Summary
    echo ""
    echo -e "${MAGENTA}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}${BOLD}                       TEST COMPLETE${NC}"
    echo -e "${MAGENTA}${BOLD}════════════════════════════════════════════════════════════${NC}"
}

send_test_message() {
    echo ""
    echo -e "${BOLD}=== Send Test Message ===${NC}"
    echo ""
    echo "1) Claude    2) OpenAI   3) Oracle   4) Grok     5) Gemini"
    echo "6) Mistral   7) Groq     8) Ollama   9) Cohere   10) Perplexity"
    read -p "Select provider: " p
    
    read -p "Message [Hello, reply briefly]: " msg
    msg="${msg:-Hello, reply briefly}"
    
    echo ""
    echo "Response:"
    
    case $p in
        1)
            KEY=$(get_config "claude_api_key")
            MODEL=$(get_config "claude_model")
            MODEL="${MODEL:-claude-sonnet-4-20250514}"
            [[ -z "$KEY" ]] && { log_fail "Not configured"; return; }
            echo -e "${DIM}Using model: $MODEL${NC}"
            echo ""
            curl -s -X POST https://api.anthropic.com/v1/messages \
                -H "Content-Type: application/json" -H "x-api-key: $KEY" -H "anthropic-version: 2023-06-01" \
                -d "{\"model\":\"$MODEL\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"$msg\"}]}" | \
                python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('content',[{}])[0].get('text','Error: '+str(r)))"
            ;;
        2)
            KEY=$(get_config "openai_api_key")
            [[ -z "$KEY" ]] && { log_fail "Not configured"; return; }
            curl -s -X POST https://api.openai.com/v1/chat/completions \
                -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
                -d "{\"model\":\"gpt-4o\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"$msg\"}]}" | \
                python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('choices',[{}])[0].get('message',{}).get('content','Error: '+str(r)))"
            ;;
        3)
            COMP=$(get_config "oracle_compartment_id")
            REGION=$(get_config "oracle_region")
            MODEL=$(get_config "oracle_model")
            MODEL="${MODEL:-cohere.command-r-plus}"
            [[ -z "$COMP" ]] && { log_fail "Not configured"; return; }
            
            echo -e "${DIM}Using model: $MODEL${NC}"
            echo ""
            
            local serving_mode="{\"servingType\":\"ON_DEMAND\",\"modelId\":\"$MODEL\"}"
            
            # Determine API format based on model vendor
            if [[ "$MODEL" == cohere.* ]]; then
                # Cohere format
                oci generative-ai-inference chat-result chat \
                    --region "${REGION:-us-chicago-1}" \
                    --compartment-id "$COMP" \
                    --serving-mode "$serving_mode" \
                    --chat-request "{\"apiFormat\":\"COHERE\",\"message\":\"$msg\",\"maxTokens\":100}" 2>&1 | \
                    python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('chat-response',{}).get('text',d))" 2>/dev/null || log_fail "Failed"
            else
                # GENERIC format for Meta, xAI, and others
                oci generative-ai-inference chat-result chat \
                    --region "${REGION:-us-chicago-1}" \
                    --compartment-id "$COMP" \
                    --serving-mode "$serving_mode" \
                    --chat-request "{\"apiFormat\":\"GENERIC\",\"messages\":[{\"role\":\"USER\",\"content\":[{\"type\":\"TEXT\",\"text\":\"$msg\"}]}],\"maxTokens\":100}" 2>&1 | \
                    python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    cr=d.get('data',{}).get('chat-response',{})
    if 'choices' in cr:
        for c in cr.get('choices',[]):
            for content in c.get('message',{}).get('content',[]):
                if content.get('type')=='TEXT':
                    print(content.get('text',''))
    else:
        print(json.dumps(cr,indent=2))
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null || log_fail "Failed"
            fi
            ;;
        4)
            KEY=$(get_config "grok_api_key")
            [[ -z "$KEY" ]] && { log_fail "Not configured"; return; }
            curl -s -X POST https://api.x.ai/v1/chat/completions \
                -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
                -d "{\"model\":\"grok-beta\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"$msg\"}]}" | \
                python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('choices',[{}])[0].get('message',{}).get('content','Error: '+str(r)))"
            ;;
        5)
            KEY=$(get_config "gemini_api_key")
            [[ -z "$KEY" ]] && { log_fail "Not configured"; return; }
            curl -s -X POST "https://generativelanguage.googleapis.com/v1/models/gemini-1.5-flash:generateContent?key=$KEY" \
                -H "Content-Type: application/json" \
                -d "{\"contents\":[{\"parts\":[{\"text\":\"$msg\"}]}]}" | \
                python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('candidates',[{}])[0].get('content',{}).get('parts',[{}])[0].get('text','Error: '+str(r)))"
            ;;
        6)
            KEY=$(get_config "mistral_api_key")
            [[ -z "$KEY" ]] && { log_fail "Not configured"; return; }
            curl -s -X POST https://api.mistral.ai/v1/chat/completions \
                -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
                -d "{\"model\":\"mistral-small-latest\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"$msg\"}]}" | \
                python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('choices',[{}])[0].get('message',{}).get('content','Error: '+str(r)))"
            ;;
        7)
            KEY=$(get_config "groq_api_key")
            [[ -z "$KEY" ]] && { log_fail "Not configured"; return; }
            curl -s -X POST https://api.groq.com/openai/v1/chat/completions \
                -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
                -d "{\"model\":\"llama-3.3-70b-versatile\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"$msg\"}]}" | \
                python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('choices',[{}])[0].get('message',{}).get('content','Error: '+str(r)))"
            ;;
        8)
            URL=$(get_config "ollama_endpoint")
            URL="${URL:-http://localhost:11434}"
            curl -s -X POST "$URL/api/generate" \
                -d "{\"model\":\"llama3.2\",\"prompt\":\"$msg\",\"stream\":false}" | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('response','Error'))"
            ;;
        9)
            KEY=$(get_config "cohere_api_key")
            [[ -z "$KEY" ]] && { log_fail "Not configured"; return; }
            curl -s -X POST https://api.cohere.ai/v1/chat \
                -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
                -d "{\"model\":\"command-r-plus\",\"message\":\"$msg\"}" | \
                python3 -c "import sys,json; print(json.load(sys.stdin).get('text','Error'))"
            ;;
        10)
            KEY=$(get_config "perplexity_api_key")
            [[ -z "$KEY" ]] && { log_fail "Not configured"; return; }
            curl -s -X POST https://api.perplexity.ai/chat/completions \
                -H "Content-Type: application/json" -H "Authorization: Bearer $KEY" \
                -d "{\"model\":\"llama-3.1-sonar-small-128k-online\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"$msg\"}]}" | \
                python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('choices',[{}])[0].get('message',{}).get('content','Error: '+str(r)))"
            ;;
        *) log_warn "Invalid selection" ;;
    esac
}

# ============================================================================
# Server Files
# ============================================================================

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
    "kubectl": [
      "^kubectl get .*",
      "^kubectl describe .*",
      "^kubectl logs .*",
      "^kubectl top .*",
      "^kubectl explain .*",
      "^kubectl api-resources.*",
      "^kubectl cluster-info.*",
      "^kubectl config view.*",
      "^kubectl config current-context.*",
      "^kubectl version.*",
      "^kubectl auth can-i .*",
      "^kubectl events .*",
      "^kubectl rollout status .*",
      "^kubectl rollout history .*"
    ],
    "oci": [
      "^oci compute instance get .*",
      "^oci compute instance list .*",
      "^oci compute instance-pool get .*",
      "^oci compute instance-pool list .*",
      "^oci compute instance-pool list-instances .*",
      "^oci compute shape list .*",
      "^oci compute image list .*",
      "^oci compute image get .*",
      "^oci compute cluster-network list .*",
      "^oci compute cluster-network get .*",
      "^oci compute cluster-network list-instances .*",
      "^oci compute boot-volume-attachment list .*",
      "^oci compute boot-volume-attachment get .*",
      "^oci compute volume-attachment list .*",
      "^oci compute volume-attachment get .*",
      "^oci compute vnic-attachment list .*",
      "^oci compute vnic-attachment get .*",
      "^oci compute capacity-reservation list .*",
      "^oci compute capacity-reservation get .*",
      "^oci ce cluster get .*",
      "^oci ce cluster list .*",
      "^oci ce node-pool get .*",
      "^oci ce node-pool list .*",
      "^oci ce node list .*",
      "^oci ce cluster-addon list .*",
      "^oci ce cluster-addon get .*",
      "^oci ce virtual-node-pool list .*",
      "^oci ce virtual-node-pool get .*",
      "^oci ce work-request list .*",
      "^oci ce work-request get .*",
      "^oci ce work-request-error list .*",
      "^oci ce work-request-log-entry list .*",
      "^oci network vcn list .*",
      "^oci network vcn get .*",
      "^oci network subnet list .*",
      "^oci network subnet get .*",
      "^oci network nsg list .*",
      "^oci network nsg get .*",
      "^oci network nsg-security-rules list .*",
      "^oci network nsg-vnics list .*",
      "^oci network route-table list .*",
      "^oci network route-table get .*",
      "^oci network security-list list .*",
      "^oci network security-list get .*",
      "^oci network internet-gateway list .*",
      "^oci network internet-gateway get .*",
      "^oci network nat-gateway list .*",
      "^oci network nat-gateway get .*",
      "^oci network service-gateway list .*",
      "^oci network service-gateway get .*",
      "^oci network drg list .*",
      "^oci network drg get .*",
      "^oci network drg-attachment list .*",
      "^oci network drg-attachment get .*",
      "^oci network private-ip list .*",
      "^oci network private-ip get .*",
      "^oci network public-ip list .*",
      "^oci network public-ip get .*",
      "^oci network vnic get .*",
      "^oci lb load-balancer list .*",
      "^oci lb load-balancer get .*",
      "^oci lb load-balancer-health get .*",
      "^oci lb backend-set list .*",
      "^oci lb backend-set get .*",
      "^oci lb backend list .*",
      "^oci lb backend get .*",
      "^oci lb backend-health get .*",
      "^oci lb listener list .*",
      "^oci lb shape list .*",
      "^oci lb work-request list .*",
      "^oci bv boot-volume list .*",
      "^oci bv boot-volume get .*",
      "^oci bv volume list .*",
      "^oci bv volume get .*",
      "^oci bv volume-backup list .*",
      "^oci bv volume-backup get .*",
      "^oci bv boot-volume-backup list .*",
      "^oci bv boot-volume-backup get .*",
      "^oci bv volume-group list .*",
      "^oci bv volume-group get .*",
      "^oci fs file-system list .*",
      "^oci fs file-system get .*",
      "^oci fs mount-target list .*",
      "^oci fs mount-target get .*",
      "^oci fs export list .*",
      "^oci fs export get .*",
      "^oci fs snapshot list .*",
      "^oci os ns get$",
      "^oci os ns get-metadata .*",
      "^oci os bucket list .*",
      "^oci os bucket get .*",
      "^oci os object list .*",
      "^oci os object head .*",
      "^oci iam compartment list .*",
      "^oci iam compartment get .*",
      "^oci iam availability-domain list .*",
      "^oci iam fault-domain list .*",
      "^oci iam region list$",
      "^oci iam region-subscription list .*",
      "^oci iam user list .*",
      "^oci iam user get .*",
      "^oci iam group list .*",
      "^oci iam group get .*",
      "^oci iam policy list .*",
      "^oci iam policy get .*",
      "^oci iam dynamic-group list .*",
      "^oci iam dynamic-group get .*",
      "^oci iam tenancy get .*",
      "^oci limits service list .*",
      "^oci limits value list .*",
      "^oci limits resource-availability get .*",
      "^oci limits quota list .*",
      "^oci limits quota get .*",
      "^oci limits definition list .*",
      "^oci monitoring metric list .*",
      "^oci monitoring metric-data summarize-metrics-data .*",
      "^oci monitoring alarm list .*",
      "^oci monitoring alarm get .*",
      "^oci monitoring alarm-status list-alarms-status .*",
      "^oci logging log-group list .*",
      "^oci logging log-group get .*",
      "^oci logging log list .*",
      "^oci logging log get .*",
      "^oci audit event list .*",
      "^oci audit configuration get .*",
      "^oci resource-manager stack list .*",
      "^oci resource-manager stack get .*",
      "^oci resource-manager job list .*",
      "^oci resource-manager job get .*",
      "^oci generative-ai model list .*",
      "^oci generative-ai model get .*",
      "^oci generative-ai model-collection list-models .*",
      "^oci generative-ai-inference chat-result chat .*",
      "^oci generative-ai dedicated-ai-cluster list .*",
      "^oci generative-ai dedicated-ai-cluster get .*",
      "^oci generative-ai endpoint list .*",
      "^oci generative-ai endpoint get .*",
      "^oci search resource-summary search-resources .*"
    ],
    "helm": [
      "^helm list.*",
      "^helm status .*",
      "^helm get .*",
      "^helm history .*",
      "^helm show .*",
      "^helm search .*",
      "^helm repo list.*",
      "^helm version.*"
    ],
    "bash": [
      "^cat /etc/os-release$",
      "^cat /etc/hosts$",
      "^cat /etc/resolv.conf$",
      "^cat /etc/fstab$",
      "^cat /etc/mtab$",
      "^cat /proc/cpuinfo$",
      "^cat /proc/meminfo$",
      "^cat /proc/loadavg$",
      "^cat /proc/uptime$",
      "^cat /proc/version$",
      "^cat /proc/mounts$",
      "^cat /proc/net/dev$",
      "^cat /proc/diskstats$",
      "^hostname.*",
      "^uptime.*",
      "^date.*",
      "^timedatectl.*",
      "^uname .*",
      "^df .*",
      "^free .*",
      "^ps .*",
      "^top -bn1.*",
      "^htop -t$",
      "^pgrep .*",
      "^pidof .*",
      "^lscpu.*",
      "^lsmem.*",
      "^lsblk.*",
      "^lspci.*",
      "^lsusb.*",
      "^lsmod$",
      "^lshw .*",
      "^lsof .*",
      "^findmnt.*",
      "^mount$",
      "^blkid$",
      "^ip addr.*",
      "^ip link.*",
      "^ip route.*",
      "^ip neigh.*",
      "^ip -s link.*",
      "^ip -s neigh.*",
      "^ss .*",
      "^netstat .*",
      "^ifconfig.*",
      "^route -n$",
      "^arp -a$",
      "^ping -c .*",
      "^traceroute .*",
      "^tracepath .*",
      "^mtr .*",
      "^nslookup .*",
      "^dig .*",
      "^host .*",
      "^curl -s .*",
      "^wget -q .*",
      "^systemctl status .*",
      "^systemctl is-active .*",
      "^systemctl is-enabled .*",
      "^systemctl list-units.*",
      "^systemctl list-timers.*",
      "^systemctl show .*",
      "^journalctl .*",
      "^dmesg.*",
      "^tail .*",
      "^head .*",
      "^less .*",
      "^grep .*",
      "^awk .*",
      "^sed .*",
      "^wc .*",
      "^sort .*",
      "^uniq .*",
      "^cut .*",
      "^ls .*",
      "^stat .*",
      "^file .*",
      "^find .* -name .*",
      "^find .* -type .*",
      "^du .*",
      "^env$",
      "^printenv.*",
      "^who$",
      "^w$",
      "^last.*",
      "^id$",
      "^id .*",
      "^groups$",
      "^ulimit .*",
      "^sysctl .*",
      "^modinfo .*",
      "^nvidia-smi.*",
      "^dcgmi .*",
      "^nvitop.*",
      "^nv-fabricmanager .*",
      "^ibstat.*",
      "^ibstatus.*",
      "^ibhosts.*",
      "^iblinkinfo.*",
      "^ibnetdiscover.*",
      "^perfquery.*",
      "^rdma .*",
      "^mlnx_tune .*",
      "^show_gids.*",
      "^ibdev2netdev.*",
      "^docker ps.*",
      "^docker stats.*",
      "^docker logs .*",
      "^docker inspect .*",
      "^docker images.*",
      "^docker network ls.*",
      "^docker volume ls.*",
      "^docker info$",
      "^docker version$",
      "^crictl ps.*",
      "^crictl pods.*",
      "^crictl images.*",
      "^crictl stats.*",
      "^crictl logs .*",
      "^crictl info$",
      "^crictl version$",
      "^ctr .*",
      "^nerdctl ps.*",
      "^podman ps.*",
      "^iostat.*",
      "^mpstat.*",
      "^vmstat.*",
      "^sar .*",
      "^pidstat.*",
      "^numactl .*",
      "^numastat.*",
      "^lscgroup.*",
      "^cgget .*",
      "^ethtool .*",
      "^tc qdisc show.*",
      "^tc class show.*",
      "^iptables -L.*",
      "^iptables -S.*",
      "^iptables-save$",
      "^nft list.*",
      "^conntrack -L.*",
      "^ss -s$",
      "^nfsstat.*",
      "^showmount .*",
      "^rpcinfo .*",
      "^getent .*",
      "^chronyc .*",
      "^ntpq .*",
      "^gpustat.*",
      "^rocm-smi.*",
      "^xpu-smi.*",
      "^nccl-tests/.*"
    ]
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

# ============================================================================
# Main
# ============================================================================

main() {
    setup_sudo
    
    while true; do
        print_main_menu
        read -p "> " choice
        case $choice in
            1) do_install ;;
            2) do_uninstall ;;
            3) check_mcp_status ;;
            4) mcp_config ;;
            5) llm_submenu ;;
            6) view_api_config ;;
            7) test_all ;;
            8) send_test_message ;;
            0|q|exit) echo "Bye!" && exit 0 ;;
            *) echo "Invalid option" ;;
        esac
    done
}

main