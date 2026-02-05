#!/bin/bash
#===============================================================================
# OKE Node Deployment Script
#
# Purpose:  Interactive deployment of OKE worker nodes with instance configuration
# Author:   Generated for OCI/OKE infrastructure automation
# Usage:    ./deploy-oke-node.sh [--debug] [--help]
#
# Features:
#   - Interactive selection menus for all OCI resources
#   - Instance Configuration creation
#   - Multiple shape support with E5 Flex default
#   - Debug mode for command visibility
#   - Console history checking
#   - Cloud-init integration
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Global Variables
#-------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
DEBUG_MODE=false
DRY_RUN=false
USE_DEFAULTS=false
AUTO_APPROVE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Selected values (populated during interactive selection)
SELECTED_COMPARTMENT_ID=""
SELECTED_COMPARTMENT_NAME=""
SELECTED_AD=""
SELECTED_VCN_ID=""
SELECTED_VCN_NAME=""
SELECTED_SUBNET_ID=""
SELECTED_SUBNET_NAME=""
SELECTED_NSG_IDS=()                          # Array of selected NSG OCIDs
SELECTED_NSG_NAMES=""                        # Comma-separated NSG names for display
SELECTED_SHAPE=""
SELECTED_IMAGE_ID=""
SELECTED_IMAGE_NAME=""
SELECTED_OCPUS=""
SELECTED_MEMORY_GB=""
SELECTED_BOOT_VOLUME_SIZE_GB=""
SELECTED_BOOT_VOLUME_VPU=""
SELECTED_INSTANCE_NAME=""
SELECTED_SSH_KEY=""

# OKE/Kubeconfig values
SELECTED_OKE_CLUSTER_ID=""
SELECTED_OKE_CLUSTER_NAME=""
SELECTED_KUBECONFIG_BASE64=""
SELECTED_CLUSTER_DNS_IP="10.96.0.10"  # Default CoreDNS IP
SELECTED_OKE_VERSION=""                # Full version (e.g., 1.31.1)
SELECTED_OKE_VERSION_SHORT=""          # Short version for apt (e.g., 1-31)
SELECTED_API_SERVER_HOST=""            # API server endpoint from kubeconfig
SELECTED_API_SERVER_CA=""              # Base64-encoded CA cert from kubeconfig
SELECTED_API_SERVER_IP=""              # API server IP only (no protocol/port)
SELECTED_API_SERVER_PORT=""            # API server port only

# IMDS (Instance Metadata Service) values - populated at runtime
IMDS_TENANCY_ID=""
IMDS_COMPARTMENT_ID=""
IMDS_REGION=""
IMDS_AD=""
IMDS_SHAPE=""
IMDS_INSTANCE_ID=""
IMDS_VNIC_ID=""
IMDS_VCN_ID=""
IMDS_SUBNET_ID=""
IMDS_PRIVATE_IP=""

# Created resources
CREATED_INSTANCE_CONFIG_ID=""
CREATED_INSTANCE_ID=""

# Deployment mode control
DEPLOYMENT_MODE=""                          # "new" or "existing" - set in select_deployment_mode()
INSTANCE_NAME_OVERRIDE=""                   # Set if user wants to override display name from existing config

# Existing instance configuration (skip creation if set)
USE_EXISTING_INSTANCE_CONFIG=""          # Set via --instance-config-id or interactively

# NSG Validation mode globals
NSG_CHECK_MODE=false                     # --nsg-check: run NSG rule validation
NSG_FIX_MODE=false                       # --nsg-fix: validate + offer to add missing rules
NSG_DUMP_MODE=false                      # --nsg-dump: dump all raw rules
NSG_CP_NSG_IDS=()                        # Control plane NSGs (auto-discovered)
NSG_CP_NSG_NAMES=()
NSG_CP_SUBNET_ID=""
NSG_CP_SUBNET_CIDR=""
NSG_CP_ENDPOINT_IP=""
NSG_WORKER_NSG_IDS=()                    # Worker NSGs (auto-detected or selected)
NSG_WORKER_NSG_NAMES=()
NSG_WORKER_SUBNET_ID=""
NSG_WORKER_SUBNET_CIDR=""
NSG_TOTAL_CHECKS=0
NSG_PASSED_CHECKS=0
NSG_FAILED_CHECKS=0
NSG_WARNED_CHECKS=0
NSG_MISSING_RULES=()                     # Accumulate missing rules for --nsg-fix
declare -A NSG_RULES_CACHE               # Cache fetched rules per NSG

# Cluster CNI / Pod networking globals (populated during discovery)
CLUSTER_CNI_TYPE=""                       # OCI_VCN_IP_NATIVE or FLANNEL_OVERLAY
CLUSTER_POD_NSG_IDS=()                   # Pod NSGs from node pool (native CNI)
CLUSTER_POD_SUBNET_IDS=()                # Pod subnets from node pool (native CNI)

# Instance Metadata Service (IMDS) base URL
readonly IMDS_BASE="http://169.254.169.254/opc/v2"

#-------------------------------------------------------------------------------
# Utility Functions
#-------------------------------------------------------------------------------

# Read input with support for USE_DEFAULTS mode
# Usage: read_with_default "prompt" default_value variable_name
read_with_default() {
    local prompt="$1"
    local default="$2"
    local varname="$3"
    
    if [[ "$USE_DEFAULTS" == "true" ]]; then
        # In defaults mode, automatically use the default
        eval "$varname=\"$default\""
        return 0
    fi
    
    # Normal interactive read
    local input
    read -rp "$prompt" input
    if [[ -z "$input" ]]; then
        eval "$varname=\"$default\""
    else
        eval "$varname=\"$input\""
    fi
}

# Parse API server URL into IP and port components
# Sets SELECTED_API_SERVER_IP and SELECTED_API_SERVER_PORT from SELECTED_API_SERVER_HOST
parse_api_server_url() {
    local url="${SELECTED_API_SERVER_HOST:-}"
    if [[ -z "$url" ]]; then
        return 0
    fi
    
    # Strip protocol
    local stripped="$url"
    stripped="${stripped#https://}"
    stripped="${stripped#http://}"
    
    # Extract IP/hostname and port
    if [[ "$stripped" == *:* ]]; then
        SELECTED_API_SERVER_IP="${stripped%%:*}"
        SELECTED_API_SERVER_PORT="${stripped##*:}"
    else
        SELECTED_API_SERVER_IP="$stripped"
        SELECTED_API_SERVER_PORT="6443"  # Default K8s API port
    fi
    
    print_debug "API Server parsed: IP=$SELECTED_API_SERVER_IP PORT=$SELECTED_API_SERVER_PORT"
}

# Fetch instance metadata from IMDS
fetch_instance_metadata() {
    print_info "Fetching instance metadata from IMDS..."
    
    local imds_response
    imds_response=$(curl -sH "Authorization: Bearer Oracle" -L "${IMDS_BASE}/instance/" 2>/dev/null) || true
    
    if [[ -z "$imds_response" ]] || ! echo "$imds_response" | jq -e '.id' &>/dev/null; then
        print_warn "Could not fetch instance metadata from IMDS"
        print_info "Will use variables.sh or OCI CLI config for defaults"
        return 1
    fi
    
    # Extract metadata values
    IMDS_TENANCY_ID=$(echo "$imds_response" | jq -r '.tenantId // empty')
    IMDS_COMPARTMENT_ID=$(echo "$imds_response" | jq -r '.compartmentId // empty')
    IMDS_REGION=$(echo "$imds_response" | jq -r '.region // empty')
    IMDS_AD=$(echo "$imds_response" | jq -r '.availabilityDomain // empty')
    IMDS_SHAPE=$(echo "$imds_response" | jq -r '.shape // empty')
    IMDS_INSTANCE_ID=$(echo "$imds_response" | jq -r '.id // empty')
    
    # Try to get VNIC info for VCN/subnet defaults
    local vnic_response
    vnic_response=$(curl -sH "Authorization: Bearer Oracle" -L "${IMDS_BASE}/vnics/" 2>/dev/null) || true
    
    if echo "$vnic_response" | jq -e '.[0]' &>/dev/null; then
        IMDS_VNIC_ID=$(echo "$vnic_response" | jq -r '.[0].vnicId // empty')
        IMDS_SUBNET_ID=$(echo "$vnic_response" | jq -r '.[0].subnetCidrBlock // empty')  # Note: IMDS doesn't give subnet OCID directly
        IMDS_PRIVATE_IP=$(echo "$vnic_response" | jq -r '.[0].privateIp // empty')
        
        # Get the actual subnet OCID from the VNIC if we have oci cli
        if [[ -n "$IMDS_VNIC_ID" ]]; then
            local vnic_details
            vnic_details=$(oci network vnic get --vnic-id "$IMDS_VNIC_ID" 2>/dev/null) || true
            if echo "$vnic_details" | jq -e '.data' &>/dev/null; then
                IMDS_SUBNET_ID=$(echo "$vnic_details" | jq -r '.data["subnet-id"] // empty')
                
                # Get VCN from subnet
                if [[ -n "$IMDS_SUBNET_ID" ]]; then
                    local subnet_details
                    subnet_details=$(oci network subnet get --subnet-id "$IMDS_SUBNET_ID" 2>/dev/null) || true
                    if echo "$subnet_details" | jq -e '.data' &>/dev/null; then
                        IMDS_VCN_ID=$(echo "$subnet_details" | jq -r '.data["vcn-id"] // empty')
                    fi
                fi
            fi
        fi
    fi
    
    # Set defaults from IMDS if not already set in variables.sh
    if [[ -z "${TENANCY_ID:-}" && -n "$IMDS_TENANCY_ID" ]]; then
        TENANCY_ID="$IMDS_TENANCY_ID"
        print_debug "TENANCY_ID from IMDS: $TENANCY_ID"
    fi
    
    if [[ -z "${DEFAULT_COMPARTMENT_ID:-}" && -n "$IMDS_COMPARTMENT_ID" ]]; then
        DEFAULT_COMPARTMENT_ID="$IMDS_COMPARTMENT_ID"
        print_debug "DEFAULT_COMPARTMENT_ID from IMDS: $DEFAULT_COMPARTMENT_ID"
    fi
    
    if [[ -z "${REGION:-}" && -n "$IMDS_REGION" ]]; then
        REGION="$IMDS_REGION"
        print_debug "REGION from IMDS: $REGION"
    fi
    
    if [[ -z "${DEFAULT_VCN_ID:-}" && -n "${IMDS_VCN_ID:-}" ]]; then
        DEFAULT_VCN_ID="$IMDS_VCN_ID"
        print_debug "DEFAULT_VCN_ID from IMDS: $DEFAULT_VCN_ID"
    fi
    
    if [[ -z "${DEFAULT_SUBNET_ID:-}" && -n "${IMDS_SUBNET_ID:-}" ]]; then
        DEFAULT_SUBNET_ID="$IMDS_SUBNET_ID"
        print_debug "DEFAULT_SUBNET_ID from IMDS: $DEFAULT_SUBNET_ID"
    fi
    
    print_success "Instance metadata loaded"
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "IMDS Data:"
        echo "  Tenancy:     ${IMDS_TENANCY_ID:-N/A}"
        echo "  Compartment: ${IMDS_COMPARTMENT_ID:-N/A}"
        echo "  Region:      ${IMDS_REGION:-N/A}"
        echo "  AD:          ${IMDS_AD:-N/A}"
        echo "  Shape:       ${IMDS_SHAPE:-N/A}"
        echo "  VCN:         ${IMDS_VCN_ID:-N/A}"
        echo "  Subnet:      ${IMDS_SUBNET_ID:-N/A}"
    fi
    
    return 0
}

print_header() {
    echo -e "\n${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_section() {
    echo -e "\n${CYAN}${BOLD}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}───────────────────────────────────────────────────────────────${NC}\n"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_debug() {
    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo -e "${MAGENTA}[DEBUG]${NC} $1"
    fi
}

log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "${ENABLE_LOGGING:-true}" == "true" && -n "${LOG_FILE:-}" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

# Log a command being executed - writes to log AND displays on screen
# Usage: log_command "description" "command_string"
log_command() {
    local description="$1"
    local command_str="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "${ENABLE_LOGGING:-true}" == "true" && -n "${LOG_FILE:-}" ]]; then
        {
            echo ""
            echo "================================================================================"
            echo "[$timestamp] [EXEC] $description"
            echo "================================================================================"
            echo "COMMAND:"
            echo "$command_str"
            echo ""
        } >> "$LOG_FILE"
    fi
    
    # Also display on screen
    echo -e "  ${CYAN}[CMD]${NC} $description"
    echo -e "  ${YELLOW}$command_str${NC}"
}

# Log a command result - writes to log only (screen output handled by caller)
# Usage: log_command_result "exit_code" "output_text"
log_command_result() {
    local exit_code="$1"
    local output="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "${ENABLE_LOGGING:-true}" == "true" && -n "${LOG_FILE:-}" ]]; then
        {
            echo "EXIT CODE: $exit_code"
            echo "OUTPUT:"
            echo "$output"
            echo "--------------------------------------------------------------------------------"
            echo ""
        } >> "$LOG_FILE"
    fi
}

# Log a JSON block - writes to log AND optionally displays on screen
# Usage: log_json "label" "json_content" [show_on_screen=false]
log_json() {
    local label="$1"
    local json_content="$2"
    local show_on_screen="${3:-false}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Pretty print the JSON
    local pretty_json
    pretty_json=$(echo "$json_content" | jq '.' 2>/dev/null || echo "$json_content")
    
    if [[ "${ENABLE_LOGGING:-true}" == "true" && -n "${LOG_FILE:-}" ]]; then
        {
            echo "[$timestamp] [JSON] $label"
            echo "$pretty_json"
            echo ""
        } >> "$LOG_FILE"
    fi
    
    if [[ "$show_on_screen" == "true" || "$DEBUG_MODE" == "true" ]]; then
        echo -e "  ${CYAN}[$label]${NC}"
        echo "$pretty_json"
        echo ""
    fi
}

# Log cloud-init content (full file) - writes to log AND summary to screen
# Usage: log_cloud_init "cloud_init_file_path"
log_cloud_init() {
    local cloud_init_path="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ ! -f "$cloud_init_path" ]]; then
        log_message "WARN" "Cloud-init file not found for logging: $cloud_init_path"
        return 0
    fi
    
    local line_count
    line_count=$(wc -l < "$cloud_init_path")
    local byte_count
    byte_count=$(wc -c < "$cloud_init_path")
    
    if [[ "${ENABLE_LOGGING:-true}" == "true" && -n "${LOG_FILE:-}" ]]; then
        {
            echo ""
            echo "================================================================================"
            echo "[$timestamp] [CLOUD-INIT] Substituted cloud-init content ($line_count lines, $byte_count bytes)"
            echo "================================================================================"
            cat "$cloud_init_path"
            echo ""
            echo "================================================================================"
            echo ""
        } >> "$LOG_FILE"
    fi
    
    print_info "Cloud-init logged ($line_count lines, $byte_count bytes) → $LOG_FILE"
}

# Log a deployment step header
# Usage: log_step "Step Name"
log_step() {
    local step_name="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [[ "${ENABLE_LOGGING:-true}" == "true" && -n "${LOG_FILE:-}" ]]; then
        {
            echo ""
            echo "################################################################################"
            echo "# [$timestamp] $step_name"
            echo "################################################################################"
        } >> "$LOG_FILE"
    fi
}

# Execute OCI command with debug output
oci_exec() {
    local cmd="$*"
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo -e "\n${MAGENTA}[DEBUG] Executing command:${NC}"
        echo -e "${YELLOW}$cmd${NC}\n"
    fi
    
    log_message "CMD" "$cmd"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warn "DRY RUN - Command not executed"
        return 0
    fi
    
    # Execute and capture output
    local output
    local exit_code
    
    if output=$(eval "$cmd" 2>&1); then
        exit_code=0
    else
        exit_code=$?
    fi
    
    if [[ "$DEBUG_MODE" == "true" && -n "$output" ]]; then
        echo -e "${MAGENTA}[DEBUG] Output:${NC}"
        echo "$output" | head -50
        if [[ $(echo "$output" | wc -l) -gt 50 ]]; then
            echo -e "${YELLOW}... (output truncated)${NC}"
        fi
    fi
    
    echo "$output"
    return $exit_code
}

# Display a numbered selection menu
# Usage: display_menu "PROMPT" "ITEMS_JSON" "NAME_FIELD" "ID_FIELD" [DEFAULT_INDEX]
display_menu() {
    local prompt="$1"
    local items_json="$2"
    local name_field="$3"
    local id_field="$4"
    local default_index="${5:-}"
    
    local count
    count=$(echo "$items_json" | jq -r 'length')
    
    if [[ "$count" -eq 0 ]]; then
        print_error "No items available for selection"
        return 1
    fi
    
    # In USE_DEFAULTS mode, automatically select the default (or first item)
    if [[ "$USE_DEFAULTS" == "true" ]]; then
        local auto_idx="${default_index:-1}"
        local auto_name
        auto_name=$(echo "$items_json" | jq -r ".[$((auto_idx - 1))][\"$name_field\"] // \"Unknown\"")
        echo -e "  ${GREEN}[AUTO]${NC} Selected: $auto_name" >&2
        echo "$items_json" | jq -c ".[$((auto_idx - 1))]"
        return 0
    fi
    
    # All display output goes to stderr so it shows on screen
    # (stdout is captured by the calling function)
    echo -e "${BOLD}$prompt${NC}\n" >&2
    
    # Show default selection prominently if set
    if [[ -n "$default_index" ]]; then
        local default_name
        local default_id
        default_name=$(echo "$items_json" | jq -r ".[$((default_index - 1))][\"$name_field\"] // \"Unknown\"")
        default_id=$(echo "$items_json" | jq -r ".[$((default_index - 1))][\"$id_field\"] // \"N/A\"")
        echo -e "  ${GREEN}${BOLD}>>> Default [$default_index]: $default_name${NC}" >&2
        if [[ "$DEBUG_MODE" == "true" ]]; then
            echo -e "      ${MAGENTA}ID: $default_id${NC}" >&2
        fi
        echo "" >&2
    fi
    
    # Display items with numbers
    local i=1
    while IFS= read -r item; do
        local name
        local id
        name=$(echo "$item" | jq -r ".[\"$name_field\"] // \"Unknown\"")
        id=$(echo "$item" | jq -r ".[\"$id_field\"] // \"N/A\"")
        
        # Truncate long names
        if [[ ${#name} -gt 100 ]]; then
            name="${name:0:97}..."
        fi
        
        if [[ -n "$default_index" && "$i" -eq "$default_index" ]]; then
            echo -e "  ${GREEN}${BOLD}[$i]${NC} ${GREEN}$name${NC} ${GREEN}(default)${NC}" >&2
        else
            echo -e "  ${BOLD}[$i]${NC} $name" >&2
        fi
        
        if [[ "$DEBUG_MODE" == "true" ]]; then
            echo -e "      ${MAGENTA}ID: $id${NC}" >&2
        fi
        
        ((i++))
    done < <(echo "$items_json" | jq -c '.[]')
    
    echo "" >&2
    
    # Get selection (read from /dev/tty to handle stdin properly)
    local selection
    while true; do
        if [[ -n "$default_index" ]]; then
            echo -n "Enter selection [1-$count] (press Enter for default [$default_index]): " >&2
            read -r selection </dev/tty
            selection="${selection:-$default_index}"
        else
            echo -n "Enter selection [1-$count]: " >&2
            read -r selection </dev/tty
        fi
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "$count" ]]; then
            break
        else
            echo -e "${RED}[ERROR]${NC} Invalid selection. Please enter a number between 1 and $count" >&2
        fi
    done
    
    # Return the selected item (0-indexed for jq) - this goes to stdout
    local idx=$((selection - 1))
    echo "$items_json" | jq -c ".[$idx]"
}

# Spinner for long operations
spinner() {
    local pid=$1
    local message="${2:-Processing...}"
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    
    tput civis  # Hide cursor
    while kill -0 "$pid" 2>/dev/null; do
        for (( i=0; i<${#spinstr}; i++ )); do
            printf "\r${BLUE}[%s]${NC} %s" "${spinstr:$i:1}" "$message"
            sleep 0.1
        done
    done
    tput cnorm  # Show cursor
    printf "\r%*s\r" $((${#message} + 10)) ""  # Clear line
}

#-------------------------------------------------------------------------------
# Validation Functions
#-------------------------------------------------------------------------------

check_prerequisites() {
    print_section "Checking Prerequisites"
    
    # Check OCI CLI
    if ! command -v oci &>/dev/null; then
        print_error "OCI CLI is not installed or not in PATH"
        print_info "Install with: bash -c \"\$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)\""
        exit 1
    fi
    print_success "OCI CLI found: $(oci --version 2>&1 | head -1)"
    
    # Check jq
    if ! command -v jq &>/dev/null; then
        print_error "jq is not installed"
        print_info "Install with: sudo dnf install jq  OR  sudo apt install jq"
        exit 1
    fi
    print_success "jq found: $(jq --version)"
    
    # Check curl
    if ! command -v curl &>/dev/null; then
        print_error "curl is not installed"
        exit 1
    fi
    
    # Check variables.sh
    if [[ -f "${SCRIPT_DIR}/variables.sh" ]]; then
        print_success "variables.sh found"
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/variables.sh"
    else
        print_warn "variables.sh not found - using defaults"
    fi
    
    # Unset OCI_CLI_AUTH if empty (empty string causes OCI CLI errors)
    if [[ -z "${OCI_CLI_AUTH:-}" ]]; then
        unset OCI_CLI_AUTH
    fi
    
    # Pick up INSTANCE_CONFIG_ID from variables.sh if not already set via CLI
    if [[ -z "${USE_EXISTING_INSTANCE_CONFIG:-}" && -n "${INSTANCE_CONFIG_ID:-}" ]]; then
        USE_EXISTING_INSTANCE_CONFIG="$INSTANCE_CONFIG_ID"
        print_info "Using instance configuration from variables.sh: $USE_EXISTING_INSTANCE_CONFIG"
    fi
    
    # Fetch instance metadata from IMDS (this sets TENANCY_ID, REGION, etc.)
    fetch_instance_metadata || true
    
    # Check OCI CLI configuration
    local profile="${OCI_CLI_PROFILE:-DEFAULT}"
    
    print_info "Testing OCI CLI connectivity (profile: $profile)..."
    
    if ! oci iam region list --query 'data[0].name' --raw-output &>/dev/null; then
        print_error "OCI CLI authentication failed"
        print_info "Run 'oci setup config' to configure OCI CLI"
        exit 1
    fi
    print_success "OCI CLI authentication successful"
    
    # Check cloud-init.yml
    if [[ -f "${CLOUD_INIT_FILE:-./cloud-init.yml}" ]]; then
        print_success "cloud-init.yml found: ${CLOUD_INIT_FILE:-./cloud-init.yml}"
    else
        print_warn "cloud-init.yml not found at ${CLOUD_INIT_FILE:-./cloud-init.yml}"
        print_info "A basic cloud-init will be generated"
    fi
}

#-------------------------------------------------------------------------------
# OCI Resource Selection Functions
#-------------------------------------------------------------------------------

select_compartment() {
    print_section "Step 1: Select Compartment"
    
    # TENANCY_ID should be set from IMDS or variables.sh by now
    if [[ -z "${TENANCY_ID:-}" ]]; then
        print_error "TENANCY_ID not set"
        print_info "Either run from an OCI instance or set TENANCY_ID in variables.sh"
        exit 1
    fi
    
    #--- Try to default to current compartment (from IMDS or variables.sh) ---
    local default_cid="${DEFAULT_COMPARTMENT_ID:-}"
    local default_cname=""
    
    if [[ -n "$default_cid" ]]; then
        # Resolve compartment name
        if [[ "$default_cid" == "$TENANCY_ID" ]]; then
            default_cname=$(oci iam tenancy get --tenancy-id "$TENANCY_ID" \
                --query 'data.name' --raw-output 2>/dev/null || echo "Root")
            default_cname="${default_cname} (root)"
        else
            default_cname=$(oci iam compartment get --compartment-id "$default_cid" \
                --query 'data.name' --raw-output 2>/dev/null || echo "")
        fi
        
        if [[ -n "$default_cname" ]]; then
            echo -e "  Current compartment: ${CYAN}${BOLD}${default_cname}${NC}"
            echo -e "  OCID: ${default_cid}"
            echo ""
            
            if [[ "$USE_DEFAULTS" == "true" ]]; then
                echo -e "  ${GREEN}[AUTO]${NC} Using current compartment"
                SELECTED_COMPARTMENT_ID="$default_cid"
                SELECTED_COMPARTMENT_NAME="$default_cname"
                print_success "Selected: $SELECTED_COMPARTMENT_NAME"
                return 0
            fi
            
            read -rp "  Use this compartment? [Y/n]: " use_default </dev/tty
            if [[ "${use_default,,}" != "n" ]]; then
                SELECTED_COMPARTMENT_ID="$default_cid"
                SELECTED_COMPARTMENT_NAME="$default_cname"
                print_success "Selected: $SELECTED_COMPARTMENT_NAME"
                return 0
            fi
            
            echo ""
            print_info "Loading compartment list..."
        fi
    fi
    
    #--- Full compartment list (shown when user wants a different compartment) ---
    print_info "Fetching compartments..."
    
    local raw_output
    local compartments
    
    # Fetch compartments using tenancy as root compartment
    raw_output=$(oci iam compartment list \
        --compartment-id "$TENANCY_ID" \
        --compartment-id-in-subtree true \
        --access-level ACCESSIBLE \
        --all 2>&1) || true
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Raw OCI output (first 500 chars):"
        echo "${raw_output:0:500}"
    fi
    
    # Check if output looks like JSON
    if ! echo "$raw_output" | jq -e '.data' &>/dev/null; then
        print_error "Failed to fetch compartments. OCI CLI response:"
        echo "$raw_output" | head -10
        exit 1
    fi
    
    # Filter for ACTIVE compartments using jq
    compartments=$(echo "$raw_output" | jq -c '[.data[] | select(.["lifecycle-state"] == "ACTIVE")] | sort_by(.name)')
    
    # Add root compartment (tenancy) at the beginning
    local tenancy_name
    tenancy_name=$(oci iam tenancy get --tenancy-id "$TENANCY_ID" --query 'data.name' --raw-output 2>/dev/null || echo "Root")
    compartments=$(echo "$compartments" | jq --arg tid "$TENANCY_ID" --arg tname "$tenancy_name" \
        '[{"id": $tid, "name": ($tname + " (root)")}] + .')
    
    local count
    count=$(echo "$compartments" | jq 'length')
    print_info "Found $count compartments"
    
    if [[ "$count" -eq 0 ]]; then
        print_error "No compartments found"
        exit 1
    fi
    
    # Find default index - prefer IMDS compartment, then DEFAULT_COMPARTMENT_ID
    local default_idx=""
    
    if [[ -n "$default_cid" ]]; then
        default_idx=$(echo "$compartments" | jq --arg cid "$default_cid" \
            'to_entries | .[] | select(.value.id == $cid) | .key + 1' 2>/dev/null | head -1 || echo "")
    fi
    
    local selected
    selected=$(display_menu "Select a compartment:" "$compartments" "name" "id" "$default_idx")
    
    SELECTED_COMPARTMENT_ID=$(echo "$selected" | jq -r '.id')
    SELECTED_COMPARTMENT_NAME=$(echo "$selected" | jq -r '.name')
    
    print_success "Selected: $SELECTED_COMPARTMENT_NAME"
    print_debug "Compartment OCID: $SELECTED_COMPARTMENT_ID"
}

select_oke_cluster() {
    print_section "Step 2: Select OKE Cluster"
    
    print_info "Fetching OKE clusters..."
    
    local raw_output
    local clusters
    
    raw_output=$(oci ce cluster list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --lifecycle-state ACTIVE \
        --all 2>&1) || true
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Raw OCI output (first 500 chars):"
        echo "${raw_output:0:500}"
    fi
    
    if ! echo "$raw_output" | jq -e '.data' &>/dev/null; then
        print_warn "Failed to fetch OKE clusters or none found"
        print_info "You can still deploy a node, but kubeconfig will need manual configuration"
        return 1
    fi
    
    clusters=$(echo "$raw_output" | jq -c '.data | sort_by(.name)')
    
    local count
    count=$(echo "$clusters" | jq 'length')
    
    if [[ "$count" -eq 0 ]]; then
        print_warn "No active OKE clusters found in compartment"
        print_info "You can still deploy a node, but kubeconfig will need manual configuration"
        return 1
    fi
    
    print_info "Found $count OKE clusters"
    
    # Enhance display with version info - use jq to strip leading 'v' if present
    clusters=$(echo "$clusters" | jq -c '[.[] | . + {
        "display-info": (.name + " (v" + (.["kubernetes-version"] | ltrimstr("v")) + ")")
    }]')
    
    # Default to first cluster
    local default_idx="1"
    
    local selected
    selected=$(display_menu "Select OKE cluster to join:" "$clusters" "display-info" "id" "$default_idx")
    
    SELECTED_OKE_CLUSTER_ID=$(echo "$selected" | jq -r '.id')
    SELECTED_OKE_CLUSTER_NAME=$(echo "$selected" | jq -r '.name')
    SELECTED_OKE_VERSION=$(echo "$selected" | jq -r '.["kubernetes-version"] | ltrimstr("v")')
    
    # Create short version for apt repo (e.g., 1.34.1 -> 1-34)
    SELECTED_OKE_VERSION_SHORT=$(echo "$SELECTED_OKE_VERSION" | awk -F. '{print $1"-"$2}')
    
    print_success "Selected cluster: $SELECTED_OKE_CLUSTER_NAME"
    print_info "Kubernetes version: $SELECTED_OKE_VERSION (apt: $SELECTED_OKE_VERSION_SHORT)"
    
    # Get detailed cluster info for VCN and endpoint
    print_info "Fetching cluster details..."
    
    local cluster_details
    cluster_details=$(oci ce cluster get --cluster-id "$SELECTED_OKE_CLUSTER_ID" 2>&1) || true
    
    if echo "$cluster_details" | jq -e '.data' &>/dev/null; then
        # Extract VCN ID from cluster
        local cluster_vcn_id
        cluster_vcn_id=$(echo "$cluster_details" | jq -r '.data["vcn-id"] // empty')
        
        if [[ -n "$cluster_vcn_id" ]]; then
            DEFAULT_VCN_ID="$cluster_vcn_id"
            print_info "Cluster VCN: $cluster_vcn_id"
            
            # Try to get cluster's endpoint subnet
            local endpoint_subnet
            endpoint_subnet=$(echo "$cluster_details" | jq -r '.data["endpoint-config"]["subnet-id"] // empty')
            if [[ -n "$endpoint_subnet" ]]; then
                print_debug "Cluster endpoint subnet: $endpoint_subnet"
            fi
        fi
        
        # Extract service CIDR for DNS IP
        local service_cidr
        service_cidr=$(echo "$cluster_details" | jq -r '.data.options.kubernetesNetworkConfig.servicesCidr // "10.96.0.0/16"')
        local service_base
        service_base=$(echo "$service_cidr" | cut -d'/' -f1 | cut -d'.' -f1-3)
        SELECTED_CLUSTER_DNS_IP="${service_base}.10"
        print_debug "Cluster DNS IP: $SELECTED_CLUSTER_DNS_IP"
    fi
    
    # Try to get worker subnet from existing node pools
    print_info "Checking for existing node pools..."
    local node_pools_raw
    node_pools_raw=$(oci ce node-pool list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --cluster-id "$SELECTED_OKE_CLUSTER_ID" 2>&1) || true
    
    if echo "$node_pools_raw" | jq -e '.data[0]' &>/dev/null; then
        # Get the first node pool's subnet
        local node_pool_id
        node_pool_id=$(echo "$node_pools_raw" | jq -r '.data[0].id // empty')
        
        if [[ -n "$node_pool_id" ]]; then
            local node_pool_details
            node_pool_details=$(oci ce node-pool get --node-pool-id "$node_pool_id" 2>&1) || true
            
            if echo "$node_pool_details" | jq -e '.data' &>/dev/null; then
                # Get worker subnet from node pool placement config
                local worker_subnet
                worker_subnet=$(echo "$node_pool_details" | jq -r '.data["node-config-details"]["placement-configs"][0]["subnet-id"] // empty')
                
                if [[ -n "$worker_subnet" && "$worker_subnet" != "null" ]]; then
                    DEFAULT_SUBNET_ID="$worker_subnet"
                    print_info "Worker subnet from node pool: $worker_subnet"
                fi
                
                # Also get the node pool's AD if available
                local node_pool_ad
                node_pool_ad=$(echo "$node_pool_details" | jq -r '.data["node-config-details"]["placement-configs"][0]["availability-domain"] // empty')
                if [[ -n "$node_pool_ad" && "$node_pool_ad" != "null" ]]; then
                    IMDS_AD="$node_pool_ad"
                    print_info "AD from node pool: $node_pool_ad"
                fi
            fi
        fi
    fi
    
    # Now fetch kubeconfig
    print_info "Generating kubeconfig..."
    
    local endpoint_choice
    local endpoint_type="PUBLIC_ENDPOINT"
    
    if [[ "$USE_DEFAULTS" == "true" ]]; then
        endpoint_choice="1"
        echo -e "  ${GREEN}[AUTO]${NC} Using public endpoint"
    else
        echo -e "\n${BOLD}Select kubeconfig endpoint type:${NC}\n" >&2
        echo -e "  ${BOLD}[1]${NC} Public endpoint" >&2
        echo -e "  ${BOLD}[2]${NC} Private endpoint (VCN-native)" >&2
        echo "" >&2
        
        echo -n "Enter selection [1-2] (default: 1): " >&2
        read -r endpoint_choice </dev/tty
        endpoint_choice="${endpoint_choice:-1}"
    fi
    
    if [[ "$endpoint_choice" == "2" ]]; then
        endpoint_type="VCN_HOSTNAME"
    fi
    
    # Create kubeconfig - write to temp file then read
    local temp_kubeconfig
    temp_kubeconfig=$(mktemp)
    
    if ! oci ce cluster create-kubeconfig \
        --cluster-id "$SELECTED_OKE_CLUSTER_ID" \
        --file "$temp_kubeconfig" \
        --token-version 2.0.0 \
        --kube-endpoint "$endpoint_type" 2>&1; then
        print_error "Failed to generate kubeconfig"
        rm -f "$temp_kubeconfig"
        return 1
    fi
    
    local kubeconfig_content
    kubeconfig_content=$(cat "$temp_kubeconfig")
    rm -f "$temp_kubeconfig"
    
    if [[ -z "$kubeconfig_content" ]]; then
        print_error "Generated kubeconfig is empty"
        return 1
    fi
    
    # Base64 encode full kubeconfig for storage
    SELECTED_KUBECONFIG_BASE64=$(echo "$kubeconfig_content" | base64 -w 0)
    
    # Extract API server host from kubeconfig
    SELECTED_API_SERVER_HOST=$(echo "$kubeconfig_content" | grep -E '^\s+server:' | head -1 | awk '{print $2}')
    
    if [[ -z "$SELECTED_API_SERVER_HOST" ]]; then
        print_error "Could not extract API server host from kubeconfig"
        return 1
    fi
    
    parse_api_server_url
    print_success "API Server: $SELECTED_API_SERVER_IP:$SELECTED_API_SERVER_PORT"
    
    # Extract CA certificate from kubeconfig (already base64 encoded)
    SELECTED_API_SERVER_CA=$(echo "$kubeconfig_content" | grep -E '^\s+certificate-authority-data:' | head -1 | awk '{print $2}')
    
    if [[ -z "$SELECTED_API_SERVER_CA" ]]; then
        print_error "Could not extract CA certificate from kubeconfig"
        return 1
    fi
    
    print_success "CA Certificate: extracted ($(echo -n "$SELECTED_API_SERVER_CA" | wc -c) bytes)"
    
    return 0
}

select_availability_domain() {
    print_section "Step 3: Select Availability Domain"
    
    print_info "Fetching availability domains..."
    
    local raw_output
    local ads
    
    raw_output=$(oci iam availability-domain list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" 2>&1) || true
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Raw OCI output (first 500 chars):"
        echo "${raw_output:0:500}"
    fi
    
    if ! echo "$raw_output" | jq -e '.data' &>/dev/null; then
        print_error "Failed to fetch availability domains. OCI CLI response:"
        echo "$raw_output" | head -10
        exit 1
    fi
    
    ads=$(echo "$raw_output" | jq -c '.data')
    
    local count
    count=$(echo "$ads" | jq 'length')
    print_info "Found $count availability domains"
    
    # Find default index - use IMDS AD if available
    local default_idx=""
    if [[ -n "${IMDS_AD:-}" ]]; then
        default_idx=$(echo "$ads" | jq --arg ad "$IMDS_AD" \
            'to_entries | .[] | select(.value.name == $ad) | .key + 1' 2>/dev/null | head -1 || echo "")
        if [[ -n "$default_idx" ]]; then
            print_info "Default AD from instance metadata: $IMDS_AD"
        fi
    fi
    
    local selected
    selected=$(display_menu "Select an availability domain:" "$ads" "name" "name" "$default_idx")
    
    SELECTED_AD=$(echo "$selected" | jq -r '.name')
    
    print_success "Selected: $SELECTED_AD"
}

select_vcn() {
    print_section "Step 4: Select VCN"
    
    print_info "Fetching VCNs..."
    
    local raw_output
    local vcns
    
    raw_output=$(oci network vcn list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --lifecycle-state AVAILABLE \
        --all 2>&1) || true
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Raw OCI output (first 500 chars):"
        echo "${raw_output:0:500}"
    fi
    
    if ! echo "$raw_output" | jq -e '.data' &>/dev/null; then
        print_error "Failed to fetch VCNs. OCI CLI response:"
        echo "$raw_output" | head -10
        exit 1
    fi
    
    vcns=$(echo "$raw_output" | jq -c '.data | sort_by(.["display-name"])')
    
    local count
    count=$(echo "$vcns" | jq 'length')
    
    if [[ "$count" -eq 0 ]]; then
        print_error "No VCNs found in compartment $SELECTED_COMPARTMENT_NAME"
        exit 1
    fi
    
    print_info "Found $count VCNs"
    
    # Find default index - use IMDS VCN or DEFAULT_VCN_ID
    local default_idx=""
    local default_vcn="${DEFAULT_VCN_ID:-}"
    
    if [[ -n "$default_vcn" ]]; then
        default_idx=$(echo "$vcns" | jq --arg vid "$default_vcn" \
            'to_entries | .[] | select(.value.id == $vid) | .key + 1' 2>/dev/null | head -1 || echo "")
        if [[ -n "$default_idx" ]]; then
            print_info "Default VCN from instance metadata"
        fi
    fi
    
    local selected
    selected=$(display_menu "Select a VCN:" "$vcns" "display-name" "id" "$default_idx")
    
    SELECTED_VCN_ID=$(echo "$selected" | jq -r '.id')
    SELECTED_VCN_NAME=$(echo "$selected" | jq -r '.["display-name"]')
    
    print_success "Selected: $SELECTED_VCN_NAME"
    print_debug "VCN OCID: $SELECTED_VCN_ID"
}

select_subnet() {
    print_section "Step 5: Select Subnet"
    
    print_info "Fetching subnets in VCN..."
    
    local raw_output
    local subnets
    
    raw_output=$(oci network subnet list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --vcn-id "$SELECTED_VCN_ID" \
        --lifecycle-state AVAILABLE \
        --all 2>&1) || true
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Raw OCI output (first 500 chars):"
        echo "${raw_output:0:500}"
    fi
    
    if ! echo "$raw_output" | jq -e '.data' &>/dev/null; then
        print_error "Failed to fetch subnets. OCI CLI response:"
        echo "$raw_output" | head -10
        exit 1
    fi
    
    subnets=$(echo "$raw_output" | jq -c '.data | sort_by(.["display-name"])')
    
    local count
    count=$(echo "$subnets" | jq 'length')
    
    if [[ "$count" -eq 0 ]]; then
        print_error "No subnets found in VCN $SELECTED_VCN_NAME"
        exit 1
    fi
    
    print_info "Found $count subnets"
    
    # Enhance display with CIDR and public/private info
    subnets=$(echo "$subnets" | jq -c '[.[] | . + {
        "display-info": (.["display-name"] + " (" + .["cidr-block"] + ", " + 
            (if .["prohibit-public-ip-on-vnic"] then "private" else "public" end) + ")")
    }]')
    
    # Find default index - priority order:
    # 1. DEFAULT_SUBNET_ID (from node pool or IMDS)
    # 2. Subnet with "worker" in name (case-insensitive)
    # 3. First private subnet
    # 4. First subnet
    local default_idx=""
    
    # First try DEFAULT_SUBNET_ID (set from node pool or IMDS)
    if [[ -n "${DEFAULT_SUBNET_ID:-}" ]]; then
        default_idx=$(echo "$subnets" | jq --arg sid "$DEFAULT_SUBNET_ID" \
            'to_entries | .[] | select(.value.id == $sid) | .key + 1' 2>/dev/null | head -1 || echo "")
        if [[ -n "$default_idx" ]]; then
            local subnet_name
            subnet_name=$(echo "$subnets" | jq -r ".[$((default_idx - 1))][\"display-name\"]")
            print_info "Auto-selected subnet from cluster node pool: $subnet_name"
        fi
    fi
    
    # If no node pool subnet, try to find worker subnet by name
    if [[ -z "$default_idx" ]]; then
        default_idx=$(echo "$subnets" | jq \
            'to_entries | .[] | select(.value["display-name"] | test("worker"; "i")) | .key + 1' 2>/dev/null | head -1 || echo "")
        
        if [[ -n "$default_idx" ]]; then
            local worker_subnet_name
            worker_subnet_name=$(echo "$subnets" | jq -r ".[$((default_idx - 1))][\"display-name\"]")
            print_info "Auto-selected worker subnet by name: $worker_subnet_name"
        fi
    fi
    
    # If still no default, try to find first private subnet
    if [[ -z "$default_idx" ]]; then
        default_idx=$(echo "$subnets" | jq \
            'to_entries | .[] | select(.value["prohibit-public-ip-on-vnic"] == true) | .key + 1' 2>/dev/null | head -1 || echo "")
        if [[ -n "$default_idx" ]]; then
            print_info "Auto-selected first private subnet"
        fi
    fi
    
    # Fallback to first subnet
    default_idx="${default_idx:-1}"
    
    local selected
    selected=$(display_menu "Select a subnet:" "$subnets" "display-info" "id" "$default_idx")
    
    SELECTED_SUBNET_ID=$(echo "$selected" | jq -r '.id')
    SELECTED_SUBNET_NAME=$(echo "$selected" | jq -r '.["display-name"]')
    
    print_success "Selected: $SELECTED_SUBNET_NAME"
    print_debug "Subnet OCID: $SELECTED_SUBNET_ID"
}

select_nsg() {
    print_section "Step 5b: Select Network Security Group (NSG)"
    
    print_info "Fetching NSGs in VCN..."
    
    local raw_output
    local nsgs
    
    raw_output=$(oci network nsg list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --vcn-id "$SELECTED_VCN_ID" \
        --lifecycle-state AVAILABLE \
        --all 2>&1) || true
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Raw OCI output (first 500 chars):"
        echo "${raw_output:0:500}"
    fi
    
    if ! echo "$raw_output" | jq -e '.data' &>/dev/null; then
        print_warn "Failed to fetch NSGs - skipping NSG selection"
        return 0
    fi
    
    nsgs=$(echo "$raw_output" | jq -c '.data | sort_by(.["display-name"])')
    
    local count
    count=$(echo "$nsgs" | jq 'length')
    
    if [[ "$count" -eq 0 ]]; then
        print_warn "No NSGs found in VCN - instance will use security lists only"
        return 0
    fi
    
    print_info "Found $count NSGs"
    
    # Find default - match "worker" in name (case-insensitive)
    local default_idx=""
    default_idx=$(echo "$nsgs" | jq \
        'to_entries | .[] | select(.value["display-name"] | test("worker"; "i")) | .key + 1' 2>/dev/null | head -1 || echo "")
    
    if [[ -n "$default_idx" ]]; then
        local worker_nsg_name
        worker_nsg_name=$(echo "$nsgs" | jq -r ".[$((default_idx - 1))][\"display-name\"]")
        print_info "Auto-selected workers NSG: $worker_nsg_name"
    fi
    default_idx="${default_idx:-1}"
    
    # In USE_DEFAULTS mode, auto-select the workers NSG
    if [[ "$USE_DEFAULTS" == "true" ]]; then
        local auto_name
        auto_name=$(echo "$nsgs" | jq -r ".[$((default_idx - 1))][\"display-name\"]")
        local auto_id
        auto_id=$(echo "$nsgs" | jq -r ".[$((default_idx - 1))].id")
        SELECTED_NSG_IDS=("$auto_id")
        SELECTED_NSG_NAMES="$auto_name"
        echo -e "  ${GREEN}[AUTO]${NC} Selected NSG: $auto_name" >&2
        log_message "INFO" "Auto-selected NSG: $auto_name ($auto_id)"
        return 0
    fi
    
    # Display numbered list with multi-select option
    echo ""
    echo -e "${BOLD}Available NSGs:${NC}"
    echo ""
    
    # Show default prominently
    if [[ -n "$default_idx" ]]; then
        local def_name
        def_name=$(echo "$nsgs" | jq -r ".[$((default_idx - 1))][\"display-name\"]")
        echo -e "  ${GREEN}${BOLD}>>> Default [$default_idx]: $def_name${NC}"
        echo ""
    fi
    
    local i=1
    while IFS= read -r nsg; do
        local name nsg_id
        name=$(echo "$nsg" | jq -r '.["display-name"]')
        nsg_id=$(echo "$nsg" | jq -r '.id')
        
        if [[ "$i" -eq "$default_idx" ]]; then
            echo -e "  ${GREEN}${BOLD}[$i]${NC} ${GREEN}$name${NC} ${GREEN}(default)${NC}"
        else
            echo -e "  ${BOLD}[$i]${NC} $name"
        fi
        
        if [[ "$DEBUG_MODE" == "true" ]]; then
            echo -e "      ${MAGENTA}ID: $nsg_id${NC}"
        fi
        
        ((i++))
    done < <(echo "$nsgs" | jq -c '.[]')
    
    echo ""
    echo -e "  Enter one or more NSG numbers (comma-separated), or press Enter for default [$default_idx]"
    read -rp "  Selection: " nsg_selection </dev/tty
    nsg_selection="${nsg_selection:-$default_idx}"
    
    # Parse comma-separated selections
    SELECTED_NSG_IDS=()
    SELECTED_NSG_NAMES=""
    
    IFS=',' read -ra selections <<< "$nsg_selection"
    for sel in "${selections[@]}"; do
        sel=$(echo "$sel" | tr -d ' ')  # Trim whitespace
        if [[ "$sel" =~ ^[0-9]+$ ]] && [[ "$sel" -ge 1 ]] && [[ "$sel" -le "$count" ]]; then
            local idx=$((sel - 1))
            local nsg_id nsg_name
            nsg_id=$(echo "$nsgs" | jq -r ".[$idx].id")
            nsg_name=$(echo "$nsgs" | jq -r ".[$idx][\"display-name\"]")
            SELECTED_NSG_IDS+=("$nsg_id")
            if [[ -n "$SELECTED_NSG_NAMES" ]]; then
                SELECTED_NSG_NAMES="${SELECTED_NSG_NAMES}, ${nsg_name}"
            else
                SELECTED_NSG_NAMES="$nsg_name"
            fi
        else
            print_warn "Skipping invalid selection: $sel"
        fi
    done
    
    if [[ ${#SELECTED_NSG_IDS[@]} -eq 0 ]]; then
        print_warn "No valid NSGs selected - instance will use security lists only"
    else
        print_success "Selected NSG(s): $SELECTED_NSG_NAMES"
        for nsg_id in "${SELECTED_NSG_IDS[@]}"; do
            print_debug "NSG OCID: $nsg_id"
        done
        log_message "INFO" "Selected NSGs: $SELECTED_NSG_NAMES"
    fi
}

select_shape() {
    print_section "Step 6: Select Compute Shape"
    
    print_info "Fetching available shapes in $SELECTED_AD..."
    
    local raw_output
    local shapes
    
    raw_output=$(oci compute shape list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --availability-domain "$SELECTED_AD" \
        --all 2>&1) || true
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Raw OCI output (first 500 chars):"
        echo "${raw_output:0:500}"
    fi
    
    if ! echo "$raw_output" | jq -e '.data' &>/dev/null; then
        print_error "Failed to fetch shapes. OCI CLI response:"
        echo "$raw_output" | head -10
        exit 1
    fi
    
    # Deduplicate and sort shapes
    shapes=$(echo "$raw_output" | jq -c '[.data | group_by(.shape)[] | .[0]] | sort_by(.shape)')
    
    local count
    count=$(echo "$shapes" | jq 'length')
    print_info "Found $count shapes"
    
    # Categorize shapes for better display
    local categorized_shapes
    categorized_shapes=$(echo "$shapes" | jq -c '[.[] | . + {
        "category": (
            if (.shape | test("GPU|BM\\.GPU")) then "GPU"
            elif (.shape | test("HPC|BM\\.HPC")) then "HPC"
            elif (.shape | test("Optimized|BM\\.Optimized")) then "Optimized"
            elif (.shape | test("Dense|DenseIO")) then "DenseIO"
            elif (.shape | test("Standard")) then "Standard"
            elif (.shape | test("Flex")) then "Flex"
            else "Other"
            end
        ),
        "display-info": (
            .shape + 
            (if .ocpus then " (OCPUs: " + (.ocpus | tostring) + ")" else "" end) +
            (if ."memory-in-gbs" then " (Mem: " + (."memory-in-gbs" | tostring) + "GB)" else "" end) +
            (if .gpus and .gpus > 0 then " [" + (.gpus | tostring) + " GPU]" else "" end)
        )
    }] | sort_by(.category, .shape)')
    
    # Find default E5 Flex shape
    local default_idx=""
    local default_shape="${DEFAULT_SHAPE:-VM.Standard.E5.Flex}"
    default_idx=$(echo "$categorized_shapes" | jq --arg ds "$default_shape" \
        'to_entries | .[] | select(.value.shape == $ds) | .key + 1' 2>/dev/null | head -1 || echo "")
    
    # If E5 not found, try E4
    if [[ -z "$default_idx" ]]; then
        default_idx=$(echo "$categorized_shapes" | jq \
            'to_entries | .[] | select(.value.shape | test("E4|E5")) | .key + 1' 2>/dev/null | head -1 || echo "")
    fi
    
    echo -e "${BOLD}Available Shape Categories:${NC}"
    echo -e "  ${GREEN}Standard/Flex${NC} - General purpose (E4, E5 series)"
    echo -e "  ${YELLOW}GPU${NC} - GPU accelerated (A10, A100, H100)"
    echo -e "  ${CYAN}HPC${NC} - High Performance Computing"
    echo -e "  ${MAGENTA}DenseIO${NC} - High storage IOPS"
    echo ""
    
    local selected
    selected=$(display_menu "Select a shape:" "$categorized_shapes" "display-info" "shape" "$default_idx")
    
    SELECTED_SHAPE=$(echo "$selected" | jq -r '.shape')
    local is_flex
    is_flex=$(echo "$selected" | jq -r 'if .ocpuOptions then "true" else "false" end')
    
    print_success "Selected: $SELECTED_SHAPE"
    
    # If flex shape, get OCPU and memory configuration
    if [[ "$is_flex" == "true" ]] || [[ "$SELECTED_SHAPE" == *"Flex"* ]]; then
        print_info "Flex shape detected - configuring OCPUs and Memory"
        
        local min_ocpus max_ocpus default_ocpus
        min_ocpus=$(echo "$selected" | jq -r '.ocpuOptions.min // 1')
        max_ocpus=$(echo "$selected" | jq -r '.ocpuOptions.max // 64')
        default_ocpus="${DEFAULT_OCPUS:-2}"
        
        local min_mem max_mem default_mem
        min_mem=$(echo "$selected" | jq -r '.memoryOptions.minInGBs // 1')
        max_mem=$(echo "$selected" | jq -r '.memoryOptions.maxInGBs // 1024')
        default_mem="${DEFAULT_MEMORY_GB:-16}"
        
        if [[ "$USE_DEFAULTS" == "true" ]]; then
            SELECTED_OCPUS="$default_ocpus"
            # Memory: default ratio of 8GB per OCPU
            SELECTED_MEMORY_GB=$((SELECTED_OCPUS * 8))
            echo -e "  ${GREEN}[AUTO]${NC} OCPUs: $SELECTED_OCPUS, Memory: ${SELECTED_MEMORY_GB}GB"
        else
            echo ""
            read -rp "Enter number of OCPUs [$min_ocpus-$max_ocpus] (default: $default_ocpus): " ocpus_input
            SELECTED_OCPUS="${ocpus_input:-$default_ocpus}"
            
            # Memory must be a multiple of OCPUs (typically 1-64 GB per OCPU)
            local mem_per_ocpu=$((default_mem / default_ocpus))
            default_mem=$((SELECTED_OCPUS * mem_per_ocpu))
            
            read -rp "Enter memory in GB [$min_mem-$max_mem] (default: $default_mem): " mem_input
            SELECTED_MEMORY_GB="${mem_input:-$default_mem}"
        fi
        
        print_success "Configured: $SELECTED_OCPUS OCPUs, ${SELECTED_MEMORY_GB}GB Memory"
    fi
}

configure_boot_volume() {
    print_section "Step 6b: Configure Boot Volume"
    
    local default_size="${DEFAULT_BOOT_VOLUME_SIZE_GB:-100}"
    local default_vpu="${DEFAULT_BOOT_VOLUME_VPU:-10}"
    
    # Detect GPU shapes and suggest larger boot volume
    local is_gpu=false
    if [[ "$SELECTED_SHAPE" == *"GPU"* || "$SELECTED_SHAPE" == *"gpu"* ]]; then
        is_gpu=true
        if [[ "$default_size" -lt 200 ]]; then
            default_size="200"
            print_info "GPU shape detected - recommending 200GB+ boot volume for drivers/frameworks"
        fi
    fi
    
    if [[ "$USE_DEFAULTS" == "true" ]]; then
        SELECTED_BOOT_VOLUME_SIZE_GB="$default_size"
        SELECTED_BOOT_VOLUME_VPU="$default_vpu"
        echo -e "  ${GREEN}[AUTO]${NC} Boot Volume: ${SELECTED_BOOT_VOLUME_SIZE_GB}GB, VPU: ${SELECTED_BOOT_VOLUME_VPU} VPUs/GB"
    else
        # Boot volume size
        echo ""
        echo -e "${BOLD}Boot Volume Size:${NC}"
        echo "  Minimum: 50 GB"
        if [[ "$is_gpu" == "true" ]]; then
            echo -e "  ${YELLOW}Recommended for GPU: 200-500 GB (CUDA, drivers, container images)${NC}"
        fi
        echo ""
        read -rp "Enter boot volume size in GB [50-32768] (default: $default_size): " size_input </dev/tty
        SELECTED_BOOT_VOLUME_SIZE_GB="${size_input:-$default_size}"
        
        # Validate
        if [[ ! "$SELECTED_BOOT_VOLUME_SIZE_GB" =~ ^[0-9]+$ ]] || [[ "$SELECTED_BOOT_VOLUME_SIZE_GB" -lt 50 ]]; then
            print_warn "Invalid size. Using default: ${default_size}GB"
            SELECTED_BOOT_VOLUME_SIZE_GB="$default_size"
        fi
        
        # VPU selection
        echo ""
        echo -e "${BOLD}Boot Volume Performance (VPUs per GB):${NC}"
        echo ""
        echo "  [1] 10  VPUs/GB - Balanced          (default)"
        echo "  [2] 20  VPUs/GB - Higher Performance"
        echo "  [3] 30  VPUs/GB - Ultra High Performance"
        echo "  [4] 60  VPUs/GB - Ultra High (Tier 2)"
        echo "  [5] 120 VPUs/GB - Ultra High (Max)"
        echo "  [6] Custom value"
        echo ""
        read -rp "Select VPU tier [1-6] (default: 1): " vpu_choice </dev/tty
        vpu_choice="${vpu_choice:-1}"
        
        case "$vpu_choice" in
            1) SELECTED_BOOT_VOLUME_VPU="10" ;;
            2) SELECTED_BOOT_VOLUME_VPU="20" ;;
            3) SELECTED_BOOT_VOLUME_VPU="30" ;;
            4) SELECTED_BOOT_VOLUME_VPU="60" ;;
            5) SELECTED_BOOT_VOLUME_VPU="120" ;;
            6)
                read -rp "Enter custom VPU value [10-120]: " custom_vpu </dev/tty
                if [[ "$custom_vpu" =~ ^[0-9]+$ ]] && [[ "$custom_vpu" -ge 10 ]] && [[ "$custom_vpu" -le 120 ]]; then
                    SELECTED_BOOT_VOLUME_VPU="$custom_vpu"
                else
                    print_warn "Invalid VPU value. Using default: $default_vpu"
                    SELECTED_BOOT_VOLUME_VPU="$default_vpu"
                fi
                ;;
            *)
                SELECTED_BOOT_VOLUME_VPU="$default_vpu"
                ;;
        esac
    fi
    
    print_success "Boot Volume: ${SELECTED_BOOT_VOLUME_SIZE_GB}GB, ${SELECTED_BOOT_VOLUME_VPU} VPUs/GB"
    print_debug "Estimated IOPS: ~$((SELECTED_BOOT_VOLUME_SIZE_GB * SELECTED_BOOT_VOLUME_VPU)) (size * VPU)"
}

select_image() {
    print_section "Step 7: Select Image"
    
    print_info "Fetching images (platform + custom)..."
    
    local raw_output
    local platform_images
    local custom_images
    local all_images
    
    # Fetch platform images (Oracle Linux)
    raw_output=$(oci compute image list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --operating-system "Oracle Linux" \
        --shape "$SELECTED_SHAPE" \
        --lifecycle-state AVAILABLE \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --limit 20 2>&1) || true
    
    if echo "$raw_output" | jq -e '.data' &>/dev/null; then
        platform_images=$(echo "$raw_output" | jq -c '.data')
    else
        platform_images="[]"
    fi
    
    # Also try Ubuntu platform images
    raw_output=$(oci compute image list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --operating-system "Canonical Ubuntu" \
        --shape "$SELECTED_SHAPE" \
        --lifecycle-state AVAILABLE \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --limit 10 2>&1) || true
    
    local ubuntu_images="[]"
    if echo "$raw_output" | jq -e '.data' &>/dev/null; then
        ubuntu_images=$(echo "$raw_output" | jq -c '.data')
    fi
    
    # Fetch ALL custom images in the compartment (no OS filter)
    print_info "Fetching custom images in compartment..."
    raw_output=$(oci compute image list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --lifecycle-state AVAILABLE \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --all 2>&1) || true
    
    if echo "$raw_output" | jq -e '.data' &>/dev/null; then
        # Filter to only custom images (ones without operating-system set to standard names, or with compartment matching)
        # Custom images typically have the compartment-id matching and may have custom display names
        custom_images=$(echo "$raw_output" | jq -c --arg cid "$SELECTED_COMPARTMENT_ID" \
            '[.data[] | select(.["compartment-id"] == $cid)]')
    else
        custom_images="[]"
    fi
    
    # Merge all images: custom first, then platform
    # Add source label for clarity
    custom_images=$(echo "$custom_images" | jq -c '[.[] | . + {"image-source": "custom"}]')
    platform_images=$(echo "$platform_images" | jq -c '[.[] | . + {"image-source": "platform"}]')
    ubuntu_images=$(echo "$ubuntu_images" | jq -c '[.[] | . + {"image-source": "platform"}]')
    
    # Combine and deduplicate by ID
    all_images=$(echo "$custom_images $platform_images $ubuntu_images" | jq -s 'add | unique_by(.id)')
    
    local count
    count=$(echo "$all_images" | jq 'length')
    
    if [[ "$count" -eq 0 ]]; then
        print_error "No images found"
        exit 1
    fi
    
    local custom_count platform_count
    custom_count=$(echo "$all_images" | jq '[.[] | select(.["image-source"] == "custom")] | length')
    platform_count=$(echo "$all_images" | jq '[.[] | select(.["image-source"] == "platform")] | length')
    
    print_info "Found $count images ($custom_count custom, $platform_count platform)"
    
    # Enhance display with date and source
    all_images=$(echo "$all_images" | jq -c '[.[] | . + {
        "display-info": (
            (if .["image-source"] == "custom" then "[CUSTOM] " else "" end) +
            .["display-name"] + 
            " (" + (.["time-created"] | split("T")[0]) + ")"
        )
    }]')
    
    # Sort: custom images first, then by date
    all_images=$(echo "$all_images" | jq -c 'sort_by(.["image-source"], .["time-created"]) | reverse')
    
    # Find default - prefer OKE images if available
    local default_idx=""
    if [[ -n "${IMAGE_DISPLAY_NAME_FILTER:-}" ]]; then
        default_idx=$(echo "$all_images" | jq --arg filter "$IMAGE_DISPLAY_NAME_FILTER" \
            'to_entries | .[] | select(.value["display-name"] | test($filter; "i")) | .key + 1' 2>/dev/null | head -1 || echo "")
    fi
    
    # If no filter match, default to first custom image or first image
    if [[ -z "$default_idx" ]]; then
        default_idx=$(echo "$all_images" | jq \
            'to_entries | .[] | select(.value["image-source"] == "custom") | .key + 1' 2>/dev/null | head -1 || echo "1")
    fi
    default_idx="${default_idx:-1}"
    
    local selected
    selected=$(display_menu "Select an image:" "$all_images" "display-info" "id" "$default_idx")
    
    SELECTED_IMAGE_ID=$(echo "$selected" | jq -r '.id')
    SELECTED_IMAGE_NAME=$(echo "$selected" | jq -r '.["display-name"]')
    local image_source
    image_source=$(echo "$selected" | jq -r '.["image-source"]')
    
    print_success "Selected: $SELECTED_IMAGE_NAME"
    print_info "Image type: $image_source"
    print_debug "Image OCID: $SELECTED_IMAGE_ID"
}

configure_ssh_key() {
    print_section "Step 8: Configure SSH Key"
    
    local ssh_key=""
    
    # Check if SSH key is already configured
    if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
        print_info "Using SSH key from variables.sh"
        ssh_key="$SSH_PUBLIC_KEY"
    elif [[ -f "${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}" ]]; then
        local key_file="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
        print_info "Found SSH key file: $key_file"
        
        if [[ "$USE_DEFAULTS" == "true" ]]; then
            echo -e "  ${GREEN}[AUTO]${NC} Using existing SSH key"
            ssh_key=$(cat "$key_file")
        else
            read -rp "Use this key? [Y/n]: " use_existing
            if [[ "${use_existing,,}" != "n" ]]; then
                ssh_key=$(cat "$key_file")
            fi
        fi
    fi
    
    if [[ -z "$ssh_key" ]]; then
        if [[ "$USE_DEFAULTS" == "true" ]]; then
            print_error "No SSH key found and --defaults mode enabled"
            print_info "Please provide SSH_PUBLIC_KEY in variables.sh or ensure ~/.ssh/id_rsa.pub exists"
            exit 1
        fi
        echo -e "${BOLD}Enter SSH public key:${NC}"
        echo "(Paste your ssh-rsa or ssh-ed25519 key, then press Enter)"
        read -r ssh_key
    fi
    
    # Validate key format
    if [[ ! "$ssh_key" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
        print_error "Invalid SSH key format"
        exit 1
    fi
    
    SELECTED_SSH_KEY="$ssh_key"
    print_success "SSH key configured"
}

configure_instance_name() {
    print_section "Step 9: Configure Instance Name"
    
    local prefix="${INSTANCE_NAME_PREFIX:-oke-worker}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local default_name="${prefix}-${timestamp}"
    
    if [[ "$USE_DEFAULTS" == "true" ]]; then
        SELECTED_INSTANCE_NAME="$default_name"
        echo -e "  ${GREEN}[AUTO]${NC} Instance name: $SELECTED_INSTANCE_NAME"
    else
        read -rp "Enter instance name (default: $default_name): " name_input
        SELECTED_INSTANCE_NAME="${name_input:-$default_name}"
    fi
    
    print_success "Instance name: $SELECTED_INSTANCE_NAME"
}

configure_kubeconfig() {
    # This is now handled in select_oke_cluster (Step 2)
    # This function is kept for manual kubeconfig entry if OKE cluster selection was skipped
    
    if [[ -n "${SELECTED_API_SERVER_HOST:-}" && -n "${SELECTED_API_SERVER_CA:-}" ]]; then
        # Already configured from select_oke_cluster
        print_info "Kubeconfig already configured from OKE cluster selection"
        return 0
    fi
    
    # In USE_DEFAULTS mode, skip manual kubeconfig configuration
    if [[ "$USE_DEFAULTS" == "true" ]]; then
        print_warn "No kubeconfig configured - node may not join cluster automatically"
        return 0
    fi
    
    print_section "Kubeconfig Configuration"
    
    print_warn "No OKE cluster was selected earlier"
    echo -e "${BOLD}Select kubeconfig source:${NC}\n" >&2
    echo -e "  ${BOLD}[1]${NC} Use existing kubeconfig file" >&2
    echo -e "  ${BOLD}[2]${NC} Paste kubeconfig content" >&2
    echo -e "  ${BOLD}[3]${NC} Skip (configure manually later)" >&2
    echo "" >&2
    
    local choice
    echo -n "Enter selection [1-3] (default: 3): " >&2
    read -r choice </dev/tty
    choice="${choice:-3}"
    
    case "$choice" in
        1)
            load_kubeconfig_from_file
            ;;
        2)
            paste_kubeconfig_content
            ;;
        3)
            print_warn "Skipping kubeconfig configuration"
            print_info "You will need to configure cluster join manually"
            ;;
        *)
            print_error "Invalid selection"
            ;;
    esac
}

fetch_kubeconfig_from_oke() {
    print_info "Fetching OKE clusters..."
    
    local raw_output
    local clusters
    
    raw_output=$(oci ce cluster list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --lifecycle-state ACTIVE \
        --all 2>&1) || true
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Raw OCI output (first 500 chars):"
        echo "${raw_output:0:500}"
    fi
    
    if ! echo "$raw_output" | jq -e '.data' &>/dev/null; then
        print_warn "Failed to fetch OKE clusters or none found"
        print_info "Falling back to manual kubeconfig entry"
        paste_kubeconfig_content
        return
    fi
    
    clusters=$(echo "$raw_output" | jq -c '.data | sort_by(.name)')
    
    local count
    count=$(echo "$clusters" | jq 'length')
    
    if [[ "$count" -eq 0 ]]; then
        print_warn "No active OKE clusters found in compartment"
        print_info "Falling back to manual kubeconfig entry"
        paste_kubeconfig_content
        return
    fi
    
    print_info "Found $count OKE clusters"
    
    # Enhance display with version and endpoint info - strip leading 'v' if present
    clusters=$(echo "$clusters" | jq -c '[.[] | . + {
        "display-info": (.name + " (v" + (.["kubernetes-version"] | ltrimstr("v")) + ")")
    }]')
    
    local selected
    selected=$(display_menu "Select OKE cluster:" "$clusters" "display-info" "id" "1")
    
    SELECTED_OKE_CLUSTER_ID=$(echo "$selected" | jq -r '.id')
    SELECTED_OKE_CLUSTER_NAME=$(echo "$selected" | jq -r '.name')
    SELECTED_OKE_VERSION=$(echo "$selected" | jq -r '.["kubernetes-version"] | ltrimstr("v")')
    
    # Create short version for apt repo (e.g., 1.34.1 -> 1-34)
    SELECTED_OKE_VERSION_SHORT=$(echo "$SELECTED_OKE_VERSION" | awk -F. '{print $1"-"$2}')
    
    print_success "Selected cluster: $SELECTED_OKE_CLUSTER_NAME"
    print_info "Kubernetes version: $SELECTED_OKE_VERSION (apt: $SELECTED_OKE_VERSION_SHORT)"
    
    # Select endpoint type
    local endpoint_choice
    local endpoint_type="PUBLIC_ENDPOINT"
    
    if [[ "$USE_DEFAULTS" == "true" ]]; then
        endpoint_choice="1"
        echo -e "  ${GREEN}[AUTO]${NC} Using public endpoint"
    else
        echo ""
        echo -e "${BOLD}Select kubeconfig endpoint type:${NC}\n"
        echo -e "  ${BOLD}[1]${NC} Public endpoint"
        echo -e "  ${BOLD}[2]${NC} Private endpoint (VCN-native)"
        echo ""
        
        read -rp "Enter selection [1-2] (default: 1): " endpoint_choice
        endpoint_choice="${endpoint_choice:-1}"
    fi
    
    if [[ "$endpoint_choice" == "2" ]]; then
        endpoint_type="VCN_HOSTNAME"
    fi
    
    print_info "Generating kubeconfig with $endpoint_type..."
    
    # Create kubeconfig - write to temp file then read
    local temp_kubeconfig
    temp_kubeconfig=$(mktemp)
    
    if ! oci ce cluster create-kubeconfig \
        --cluster-id "$SELECTED_OKE_CLUSTER_ID" \
        --file "$temp_kubeconfig" \
        --token-version 2.0.0 \
        --kube-endpoint "$endpoint_type" 2>&1; then
        print_error "Failed to generate kubeconfig"
        rm -f "$temp_kubeconfig"
        return 1
    fi
    
    local kubeconfig_content
    kubeconfig_content=$(cat "$temp_kubeconfig")
    rm -f "$temp_kubeconfig"
    
    if [[ -z "$kubeconfig_content" ]]; then
        print_error "Generated kubeconfig is empty"
        return 1
    fi
    
    # Base64 encode full kubeconfig for storage
    SELECTED_KUBECONFIG_BASE64=$(echo "$kubeconfig_content" | base64 -w 0)
    
    #---------------------------------------------------------------------------
    # Extract API server host from kubeconfig
    #---------------------------------------------------------------------------
    SELECTED_API_SERVER_HOST=$(echo "$kubeconfig_content" | grep -E '^\s+server:' | head -1 | awk '{print $2}')
    
    if [[ -z "$SELECTED_API_SERVER_HOST" ]]; then
        print_error "Could not extract API server host from kubeconfig"
        return 1
    fi
    
    parse_api_server_url
    print_success "API Server Host: $SELECTED_API_SERVER_IP:$SELECTED_API_SERVER_PORT"
    
    #---------------------------------------------------------------------------
    # Extract CA certificate from kubeconfig (already base64 encoded)
    #---------------------------------------------------------------------------
    SELECTED_API_SERVER_CA=$(echo "$kubeconfig_content" | grep -E '^\s+certificate-authority-data:' | head -1 | awk '{print $2}')
    
    if [[ -z "$SELECTED_API_SERVER_CA" ]]; then
        print_error "Could not extract CA certificate from kubeconfig"
        return 1
    fi
    
    print_success "CA Certificate: extracted ($(echo -n "$SELECTED_API_SERVER_CA" | wc -c) bytes)"
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Kubeconfig preview:"
        echo "$kubeconfig_content" | head -20
        echo "..."
        print_debug "API Server: $SELECTED_API_SERVER_HOST"
        print_debug "CA Cert (first 50 chars): ${SELECTED_API_SERVER_CA:0:50}..."
    fi
    
    # Extract cluster DNS IP from cluster details
    local cluster_raw
    cluster_raw=$(oci ce cluster get \
        --cluster-id "$SELECTED_OKE_CLUSTER_ID" 2>&1) || true
    
    if echo "$cluster_raw" | jq -e '.data' &>/dev/null; then
        # Try to get service CIDR and derive DNS IP
        local service_cidr
        service_cidr=$(echo "$cluster_raw" | jq -r '.data.options.kubernetesNetworkConfig.servicesCidr // "10.96.0.0/16"')
        
        # DNS is typically .10 of the service CIDR (e.g., 10.96.0.10)
        local service_base
        service_base=$(echo "$service_cidr" | cut -d'/' -f1 | cut -d'.' -f1-3)
        SELECTED_CLUSTER_DNS_IP="${service_base}.10"
        
        print_info "Cluster DNS IP: $SELECTED_CLUSTER_DNS_IP"
    fi
}

load_kubeconfig_from_file() {
    local default_path="${KUBECONFIG_FILE:-$HOME/.kube/config}"
    
    read -rp "Enter kubeconfig file path (default: $default_path): " file_path
    file_path="${file_path:-$default_path}"
    
    if [[ ! -f "$file_path" ]]; then
        print_error "File not found: $file_path"
        configure_kubeconfig
        return
    fi
    
    # Validate it looks like a kubeconfig
    if ! grep -q "apiVersion" "$file_path" || ! grep -q "clusters" "$file_path"; then
        print_error "File does not appear to be a valid kubeconfig"
        configure_kubeconfig
        return
    fi
    
    local kubeconfig_content
    kubeconfig_content=$(cat "$file_path")
    
    SELECTED_KUBECONFIG_BASE64=$(echo "$kubeconfig_content" | base64 -w 0)
    
    # Extract API server host
    SELECTED_API_SERVER_HOST=$(echo "$kubeconfig_content" | grep -E '^\s+server:' | head -1 | awk '{print $2}')
    
    # Extract CA certificate (already base64 encoded in kubeconfig)
    SELECTED_API_SERVER_CA=$(echo "$kubeconfig_content" | grep -E '^\s+certificate-authority-data:' | head -1 | awk '{print $2}')
    
    parse_api_server_url
    print_success "Kubeconfig loaded from: $file_path"
    
    if [[ -n "$SELECTED_API_SERVER_IP" ]]; then
        print_success "API Server: $SELECTED_API_SERVER_IP:$SELECTED_API_SERVER_PORT"
    else
        print_warn "Could not extract API server host from kubeconfig"
    fi
    
    if [[ -n "$SELECTED_API_SERVER_CA" ]]; then
        print_success "CA Certificate: extracted"
    else
        print_warn "Could not extract CA certificate from kubeconfig"
    fi
    
    # Try to extract cluster info
    local cluster_name
    cluster_name=$(grep -A5 "clusters:" "$file_path" | grep "name:" | head -1 | awk '{print $2}')
    if [[ -n "$cluster_name" ]]; then
        print_info "Cluster context: $cluster_name"
    fi
    
    # Prompt for OKE version if not already set
    if [[ -z "$SELECTED_OKE_VERSION" ]]; then
        echo ""
        print_warn "OKE version not detected from kubeconfig"
        read -rp "Enter OKE Kubernetes version (e.g., 1.31.1): " version_input
        SELECTED_OKE_VERSION="${version_input:-1.31.1}"
        SELECTED_OKE_VERSION_SHORT=$(echo "$SELECTED_OKE_VERSION" | awk -F. '{print $1"-"$2}')
        print_info "OKE version set to: $SELECTED_OKE_VERSION (apt: $SELECTED_OKE_VERSION_SHORT)"
    fi
}

paste_kubeconfig_content() {
    echo -e "${BOLD}Paste your kubeconfig content below.${NC}"
    echo -e "${YELLOW}When finished, press Ctrl+D on a new line.${NC}\n"
    
    local kubeconfig_content
    kubeconfig_content=$(cat)
    
    if [[ -z "$kubeconfig_content" ]]; then
        print_warn "No content provided, skipping kubeconfig"
        SELECTED_KUBECONFIG_BASE64=""
        return
    fi
    
    # Validate it looks like a kubeconfig
    if ! echo "$kubeconfig_content" | grep -q "apiVersion"; then
        print_error "Content does not appear to be a valid kubeconfig"
        configure_kubeconfig
        return
    fi
    
    SELECTED_KUBECONFIG_BASE64=$(echo "$kubeconfig_content" | base64 -w 0)
    
    # Extract API server host
    SELECTED_API_SERVER_HOST=$(echo "$kubeconfig_content" | grep -E '^\s+server:' | head -1 | awk '{print $2}')
    
    # Extract CA certificate (already base64 encoded in kubeconfig)
    SELECTED_API_SERVER_CA=$(echo "$kubeconfig_content" | grep -E '^\s+certificate-authority-data:' | head -1 | awk '{print $2}')
    
    print_success "Kubeconfig content encoded"
    
    if [[ -n "$SELECTED_API_SERVER_HOST" ]]; then
        parse_api_server_url
        print_success "API Server: $SELECTED_API_SERVER_IP:$SELECTED_API_SERVER_PORT"
    else
        print_warn "Could not extract API server host"
        read -rp "Enter API server host (e.g., https://xxx.oraclecloud.com:6443): " api_input
        SELECTED_API_SERVER_HOST="$api_input"
        parse_api_server_url
    fi
    
    if [[ -n "$SELECTED_API_SERVER_CA" ]]; then
        print_success "CA Certificate: extracted"
    else
        print_warn "Could not extract CA certificate"
        echo "Enter base64-encoded CA certificate (or press Enter to skip):"
        read -r ca_input
        SELECTED_API_SERVER_CA="$ca_input"
    fi
    
    # Prompt for OKE version
    echo ""
    read -rp "Enter OKE Kubernetes version (e.g., 1.31.1): " version_input
    SELECTED_OKE_VERSION="${version_input:-1.31.1}"
    SELECTED_OKE_VERSION_SHORT=$(echo "$SELECTED_OKE_VERSION" | awk -F. '{print $1"-"$2}')
    print_info "OKE version set to: $SELECTED_OKE_VERSION (apt: $SELECTED_OKE_VERSION_SHORT)"
}

configure_node_labels_taints() {
    print_section "Step 10: Configure Node Labels and Taints (Optional)"
    
    local default_taint="newNode:NoSchedule"
    
    if [[ "$USE_DEFAULTS" == "true" ]]; then
        NODE_LABELS=""
        NODE_TAINTS="$default_taint"
        echo -e "  ${GREEN}[AUTO]${NC} Node labels: (none)"
        echo -e "  ${GREEN}[AUTO]${NC} Node taints: $NODE_TAINTS"
        print_success "Using default node configuration"
        return 0
    fi
    
    echo -e "${BOLD}Node Labels${NC} (comma-separated key=value pairs)" >&2
    echo -e "Example: ${CYAN}node-type=gpu,workload=training${NC}" >&2
    echo "" >&2
    
    echo -n "Enter node labels (or press Enter to skip): " >&2
    read -r labels_input </dev/tty
    NODE_LABELS="${labels_input:-}"
    
    if [[ -n "$NODE_LABELS" ]]; then
        print_success "Node labels: $NODE_LABELS"
    fi
    
    echo "" >&2
    echo -e "${BOLD}Node Taints${NC} (comma-separated key=value:effect)" >&2
    echo -e "Example: ${CYAN}nvidia.com/gpu=present:NoSchedule${NC}" >&2
    echo -e "Effects: NoSchedule, PreferNoSchedule, NoExecute" >&2
    echo "" >&2
    
    echo -n "Enter node taints (default: $default_taint): " >&2
    read -r taints_input </dev/tty
    NODE_TAINTS="${taints_input:-$default_taint}"
    
    print_success "Node taints: $NODE_TAINTS"
}

#-------------------------------------------------------------------------------
# Deployment Mode Selection (Early Branch)
#-------------------------------------------------------------------------------

select_deployment_mode() {
    print_section "Step 2: Deployment Mode"
    log_step "Deployment Mode Selection"
    
    if [[ "$USE_DEFAULTS" == "true" ]]; then
        DEPLOYMENT_MODE="new"
        echo -e "  ${GREEN}[AUTO]${NC} Creating new instance configuration (defaults mode)"
        log_message "INFO" "Deployment mode: new (defaults mode)"
        return 0
    fi
    
    echo ""
    echo -e "${BOLD}How would you like to deploy?${NC}"
    echo ""
    echo "  1) Create new instance configuration (full setup)"
    echo "     Configure shape, image, boot volume, networking, cloud-init, etc."
    echo ""
    echo "  2) Use existing instance configuration (skip to launch)"
    echo "     Select a previously created config and launch immediately."
    echo ""
    read -rp "Select option [1]: " mode_choice </dev/tty
    mode_choice="${mode_choice:-1}"
    
    case "$mode_choice" in
        2)
            DEPLOYMENT_MODE="existing"
            print_info "Using existing instance configuration"
            log_message "INFO" "Deployment mode: existing"
            ;;
        *)
            DEPLOYMENT_MODE="new"
            print_info "Creating new instance configuration"
            log_message "INFO" "Deployment mode: new"
            ;;
    esac
}

use_existing_config_flow() {
    print_section "Step 2b: Select Existing Instance Configuration"
    log_step "Use Existing Instance Configuration"
    
    # List existing instance configurations
    print_info "Fetching instance configurations..."
    local ic_list_cmd="oci compute-management instance-configuration list \\
    --compartment-id \"$SELECTED_COMPARTMENT_ID\" \\
    --sort-by TIMECREATED \\
    --sort-order DESC"
    log_command "List instance configurations" "$ic_list_cmd"
    
    local raw_output
    raw_output=$(oci compute-management instance-configuration list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --sort-by TIMECREATED \
        --sort-order DESC 2>&1) || true
    log_command_result "$?" "$raw_output"
    
    # Parse the results
    local list_json
    list_json=$(echo "$raw_output" | jq '[.data[] | {name: .["display-name"], id: .id, created: .["time-created"]}]' 2>/dev/null)
    
    if [[ -z "$list_json" ]] || ! echo "$list_json" | jq -e '.[0]' &>/dev/null; then
        print_warn "No instance configurations found in compartment"
        print_info "Switching to 'Create New' flow..."
        DEPLOYMENT_MODE="new"
        return 1
    fi
    
    local count
    count=$(echo "$list_json" | jq 'length')
    print_info "Found $count instance configurations"
    
    # Display numbered list
    echo ""
    printf "  ${BOLD}%-4s %-50s %-22s${NC}\n" "#" "Name" "Created"
    printf "  %-4s %-50s %-22s\n" "----" "--------------------------------------------------" "----------------------"
    
    local i=1
    while IFS= read -r config; do
        local name created created_fmt
        name=$(echo "$config" | jq -r '.name')
        created=$(echo "$config" | jq -r '.created')
        # Format: 2025-12-20T14:37:51Z → 2025-12-20 14:37 UTC
        created_fmt=$(echo "$created" | sed 's/T/ /; s/:[0-9][0-9]\.[0-9]*Z/ UTC/; s/:[0-9][0-9]Z/ UTC/')
        printf "  %-4s %-50s %-22s\n" "$i)" "${name:0:50}" "$created_fmt"
        ((i++))
    done < <(echo "$list_json" | jq -c '.[]')
    
    echo ""
    read -rp "Select instance configuration [1-$count]: " selection </dev/tty
    selection="${selection:-1}"
    
    if [[ "$selection" -lt 1 || "$selection" -gt "$count" ]] 2>/dev/null; then
        print_error "Invalid selection: $selection"
        exit 1
    fi
    
    local selected_config
    selected_config=$(echo "$list_json" | jq -c ".[$((selection - 1))]")
    CREATED_INSTANCE_CONFIG_ID=$(echo "$selected_config" | jq -r '.id')
    local selected_name
    selected_name=$(echo "$selected_config" | jq -r '.name')
    
    print_success "Selected: $selected_name"
    log_message "INFO" "Selected instance configuration: $selected_name ($CREATED_INSTANCE_CONFIG_ID)"
    
    #---------------------------------------------------------------------------
    # Fetch and display full details
    #---------------------------------------------------------------------------
    print_section "Instance Configuration Details"
    print_info "Fetching configuration details..."
    
    local ic_detail_cmd="oci compute-management instance-configuration get \\
    --instance-configuration-id \"$CREATED_INSTANCE_CONFIG_ID\""
    log_command "Get instance configuration details" "$ic_detail_cmd"
    
    local detail_output
    detail_output=$(oci compute-management instance-configuration get \
        --instance-configuration-id "$CREATED_INSTANCE_CONFIG_ID" 2>&1) || true
    log_command_result "$?" "$detail_output"
    
    if ! echo "$detail_output" | jq -e '.data' &>/dev/null; then
        print_error "Failed to fetch instance configuration details"
        print_error "$detail_output"
        exit 1
    fi
    
    # Extract launch details
    # OCI CLI responses may use kebab-case (launch-details) or camelCase (launchDetails)
    # depending on CLI version and how the config was created. We try both.
    local launch_details=""
    local key_format="kebab"  # Track which format we found for downstream parsing
    
    # Try kebab-case first (standard OCI CLI GET output)
    launch_details=$(echo "$detail_output" | jq '.data["instance-details"]["launch-details"] // empty' 2>/dev/null)
    
    if [[ -z "$launch_details" || "$launch_details" == "null" || "$launch_details" == '""' ]]; then
        # Try camelCase (some CLI versions / API responses)
        launch_details=$(echo "$detail_output" | jq '.data["instance-details"].launchDetails // empty' 2>/dev/null)
        key_format="camel"
    fi
    
    if [[ -z "$launch_details" || "$launch_details" == "null" || "$launch_details" == '""' ]]; then
        print_error "Instance configuration has no launch details"
        echo ""
        echo -e "${YELLOW}Diagnostic: Keys under .data[\"instance-details\"]:${NC}"
        echo "$detail_output" | jq '.data["instance-details"] | keys' 2>/dev/null || echo "  (unable to parse)"
        echo ""
        echo -e "${YELLOW}Diagnostic: First 20 lines of .data[\"instance-details\"]:${NC}"
        echo "$detail_output" | jq '.data["instance-details"]' 2>/dev/null | head -20 || echo "  (unable to parse)"
        exit 1
    fi
    
    print_debug "Launch details found using ${key_format}-case keys"
    
    # Helper: extract a field trying both kebab-case and camelCase
    # Usage: ic_field "$launch_details" "kebab-key" "camelKey" "default"
    ic_field() {
        local json="$1" kebab="$2" camel="$3" default="${4:-N/A}"
        local val
        val=$(echo "$json" | jq -r ".[\"$kebab\"] // empty" 2>/dev/null)
        if [[ -z "$val" || "$val" == "null" ]]; then
            val=$(echo "$json" | jq -r ".$camel // empty" 2>/dev/null)
        fi
        echo "${val:-$default}"
    }
    
    # Helper: extract a nested field (e.g., source-details.image-id)
    # Usage: ic_nested "$launch_details" "parent-kebab" "parentCamel" "child-kebab" "childCamel" "default"
    ic_nested() {
        local json="$1" pk="$2" pc="$3" ck="$4" cc="$5" default="${6:-N/A}"
        local val
        val=$(echo "$json" | jq -r ".[\"$pk\"][\"$ck\"] // empty" 2>/dev/null)
        if [[ -z "$val" || "$val" == "null" ]]; then
            val=$(echo "$json" | jq -r ".[\"$pk\"].$cc // empty" 2>/dev/null)
        fi
        if [[ -z "$val" || "$val" == "null" ]]; then
            val=$(echo "$json" | jq -r ".$pc[\"$ck\"] // empty" 2>/dev/null)
        fi
        if [[ -z "$val" || "$val" == "null" ]]; then
            val=$(echo "$json" | jq -r ".$pc.$cc // empty" 2>/dev/null)
        fi
        echo "${val:-$default}"
    }
    
    # Extract all config fields (auto-detect key format)
    local config_shape config_ad config_subnet_id config_display_name
    local config_boot_size config_boot_vpu config_image_id config_compartment_id
    config_shape=$(ic_field "$launch_details" "shape" "shape" "N/A")
    config_ad=$(ic_field "$launch_details" "availability-domain" "availabilityDomain" "N/A")
    config_display_name=$(ic_field "$launch_details" "display-name" "displayName" "N/A")
    config_compartment_id=$(ic_field "$launch_details" "compartment-id" "compartmentId" "N/A")
    
    config_subnet_id=$(ic_nested "$launch_details" "create-vnic-details" "createVnicDetails" "subnet-id" "subnetId" "N/A")
    config_boot_size=$(ic_nested "$launch_details" "source-details" "sourceDetails" "boot-volume-size-in-gbs" "bootVolumeSizeInGBs" "N/A")
    config_boot_vpu=$(ic_nested "$launch_details" "source-details" "sourceDetails" "boot-volume-vpus-per-gb" "bootVolumeVpusPerGB" "N/A")
    config_image_id=$(ic_nested "$launch_details" "source-details" "sourceDetails" "image-id" "imageId" "N/A")
    
    # Flex shape config
    local config_ocpus config_memory
    config_ocpus=$(ic_nested "$launch_details" "shape-config" "shapeConfig" "ocpus" "ocpus" "")
    config_memory=$(ic_nested "$launch_details" "shape-config" "shapeConfig" "memory-in-gbs" "memoryInGBs" "")
    
    # NSG IDs
    local config_nsg_json config_nsg_count
    config_nsg_json=$(ic_nested "$launch_details" "create-vnic-details" "createVnicDetails" "nsg-ids" "nsgIds" "[]")
    if [[ "$config_nsg_json" == "N/A" || -z "$config_nsg_json" ]]; then
        config_nsg_json="[]"
    fi
    config_nsg_count=$(echo "$config_nsg_json" | jq 'length' 2>/dev/null || echo "0")
    
    # Populate SELECTED_ globals so downstream functions (get_instance_details, completion log) work
    SELECTED_SHAPE="$config_shape"
    SELECTED_AD="$config_ad"
    SELECTED_BOOT_VOLUME_SIZE_GB="${config_boot_size:-100}"
    SELECTED_BOOT_VOLUME_VPU="${config_boot_vpu:-10}"
    SELECTED_INSTANCE_NAME="$config_display_name"
    SELECTED_IMAGE_ID="$config_image_id"
    if [[ -n "$config_ocpus" ]]; then
        SELECTED_OCPUS="$config_ocpus"
        SELECTED_MEMORY_GB="$config_memory"
    fi

    # Populate NSG IDs from config for pre-flight validation
    SELECTED_NSG_IDS=()
    if [[ -n "$config_nsg_json" && "$config_nsg_json" != "[]" && "$config_nsg_json" != "N/A" ]]; then
        while IFS= read -r nsg_id; do
            [[ -n "$nsg_id" ]] && SELECTED_NSG_IDS+=("$nsg_id")
        done < <(echo "$config_nsg_json" | jq -r '.[]' 2>/dev/null)
    fi

    # Populate subnet ID from config for pre-flight validation
    if [[ "$config_subnet_id" != "N/A" && "$config_subnet_id" != "null" && -n "$config_subnet_id" ]]; then
        SELECTED_SUBNET_ID="$config_subnet_id"
    fi
    
    #---------------------------------------------------------------------------
    # Resolve names from OCIDs for display
    #---------------------------------------------------------------------------
    print_info "Resolving resource names..."
    
    # Resolve image name
    local config_image_name="Unknown"
    if [[ "$config_image_id" != "N/A" && "$config_image_id" != "null" ]]; then
        local image_output
        image_output=$(oci compute image get \
            --image-id "$config_image_id" \
            --query 'data."display-name"' \
            --raw-output 2>/dev/null) || true
        if [[ -n "$image_output" && "$image_output" != "null" ]]; then
            config_image_name="$image_output"
        else
            config_image_name="${config_image_id:0:50}..."
        fi
    fi
    SELECTED_IMAGE_NAME="$config_image_name"
    
    # Resolve subnet name
    local config_subnet_name="Unknown"
    if [[ "$config_subnet_id" != "N/A" && "$config_subnet_id" != "null" ]]; then
        local subnet_output
        subnet_output=$(oci network subnet get \
            --subnet-id "$config_subnet_id" \
            --query 'data."display-name"' \
            --raw-output 2>/dev/null) || true
        if [[ -n "$subnet_output" && "$subnet_output" != "null" ]]; then
            config_subnet_name="$subnet_output"
        else
            config_subnet_name="${config_subnet_id:0:50}..."
        fi
    fi
    SELECTED_SUBNET_NAME="$config_subnet_name"
    
    # Resolve NSG names
    local config_nsg_names="None (security lists only)"
    if [[ "$config_nsg_count" -gt 0 ]]; then
        local nsg_names_arr=()
        while IFS= read -r nsg_id; do
            local nsg_name_output
            nsg_name_output=$(oci network nsg get \
                --nsg-id "$nsg_id" \
                --query 'data."display-name"' \
                --raw-output 2>/dev/null) || true
            if [[ -n "$nsg_name_output" && "$nsg_name_output" != "null" ]]; then
                nsg_names_arr+=("$nsg_name_output")
            else
                nsg_names_arr+=("${nsg_id:0:30}...")
            fi
        done < <(echo "$config_nsg_json" | jq -r '.[]')
        config_nsg_names=$(IFS=", "; echo "${nsg_names_arr[*]}")
    fi
    SELECTED_NSG_NAMES="$config_nsg_names"
    
    # SSH key check (metadata keys are always underscore-separated)
    local config_ssh_key
    config_ssh_key=$(echo "$launch_details" | jq -r '.metadata.ssh_authorized_keys // empty' 2>/dev/null)
    local ssh_display="Not configured"
    if [[ -n "$config_ssh_key" ]]; then
        ssh_display="${config_ssh_key:0:50}..."
    fi
    
    # Cloud-init check (metadata.user_data is always underscore-separated)
    local config_user_data
    config_user_data=$(echo "$launch_details" | jq -r '.metadata.user_data // empty' 2>/dev/null)
    local cloud_init_display="Not configured"
    local decoded_ci_file=""
    local ci_lines=0
    if [[ -n "$config_user_data" ]]; then
        decoded_ci_file=$(mktemp)
        echo "$config_user_data" | base64 -d > "$decoded_ci_file" 2>/dev/null
        if [[ -s "$decoded_ci_file" ]]; then
            ci_lines=$(wc -l < "$decoded_ci_file")
            cloud_init_display="${ci_lines} lines configured ✓"

            #--- Extract API server from cloud-init early (for summary box + preflight) ---
            if [[ -z "${SELECTED_API_SERVER_IP:-}" ]]; then
                local ci_api_ip=""

                # Method 1: /etc/oke/oke-apiserver write_files content
                ci_api_ip=$(awk '/path:.*oke-apiserver/{getline; if ($1 == "content:") print $2}' "$decoded_ci_file" 2>/dev/null)

                # Method 2: --apiserver-host flag in runcmd
                if [[ -z "$ci_api_ip" ]]; then
                    ci_api_ip=$(grep -oP '(?<=--apiserver-host\s)[^\s"]+' "$decoded_ci_file" 2>/dev/null | head -1)
                fi

                if [[ -n "$ci_api_ip" && "$ci_api_ip" != "__"* && "$ci_api_ip" != "<"* ]]; then
                    SELECTED_API_SERVER_IP="$ci_api_ip"
                    SELECTED_API_SERVER_PORT="${SELECTED_API_SERVER_PORT:-6443}"
                fi
            fi
        else
            rm -f "$decoded_ci_file"
            decoded_ci_file=""
        fi
    fi
    
    #---------------------------------------------------------------------------
    # Display summary box
    #---------------------------------------------------------------------------
    echo ""
    local box_width=78
    echo -e "${BOLD}╔$(printf '═%.0s' $(seq 1 $box_width))╗${NC}"
    printf "${BOLD}║${NC}  Instance Configuration: ${CYAN}%-51s${NC} ${BOLD}║${NC}\n" "$selected_name"
    echo -e "${BOLD}╠$(printf '═%.0s' $(seq 1 $box_width))╣${NC}"
    printf "${BOLD}║${NC}  %-20s │ %-53s${BOLD}║${NC}\n" "Shape" "$config_shape"
    if [[ -n "$config_ocpus" ]]; then
        printf "${BOLD}║${NC}  %-20s │ %-53s${BOLD}║${NC}\n" "OCPUs / Memory" "${config_ocpus} OCPUs / ${config_memory}GB"
    fi
    printf "${BOLD}║${NC}  %-20s │ %-53s${BOLD}║${NC}\n" "Boot Volume" "${config_boot_size}GB / ${config_boot_vpu} VPUs/GB"
    printf "${BOLD}║${NC}  %-20s │ %-53s${BOLD}║${NC}\n" "Availability Domain" "${config_ad##*:}"
    printf "${BOLD}║${NC}  %-20s │ %-53s${BOLD}║${NC}\n" "Image" "${config_image_name:0:53}"
    printf "${BOLD}║${NC}  %-20s │ %-53s${BOLD}║${NC}\n" "Subnet" "${config_subnet_name:0:53}"
    printf "${BOLD}║${NC}  %-20s │ %-53s${BOLD}║${NC}\n" "NSG(s)" "${config_nsg_names:0:53}"
    printf "${BOLD}║${NC}  %-20s │ %-53s${BOLD}║${NC}\n" "SSH Key" "$ssh_display"
    printf "${BOLD}║${NC}  %-20s │ %-53s${BOLD}║${NC}\n" "Cloud-Init" "$cloud_init_display"
    if [[ -n "${SELECTED_API_SERVER_IP:-}" ]]; then
        printf "${BOLD}║${NC}  %-20s │ %-53s${BOLD}║${NC}\n" "API Server" "${SELECTED_API_SERVER_IP}:${SELECTED_API_SERVER_PORT:-6443}"
    fi
    echo -e "${BOLD}╠$(printf '═%.0s' $(seq 1 $box_width))╣${NC}"
    printf "${BOLD}║${NC}  %-20s │ %-53s${BOLD}║${NC}\n" "Display Name" "$config_display_name"
    echo -e "${BOLD}╚$(printf '═%.0s' $(seq 1 $box_width))╝${NC}"
    
    #---------------------------------------------------------------------------
    # Cloud-init preview
    #---------------------------------------------------------------------------
    if [[ -n "$decoded_ci_file" && -s "$decoded_ci_file" ]]; then
        echo ""
        echo -e "${YELLOW}${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}${BOLD}│  Cloud-Init Preview (from existing config)                       │${NC}"
        echo -e "${YELLOW}${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        head -40 "$decoded_ci_file" | nl -ba
        if [[ $ci_lines -gt 40 ]]; then
            echo ""
            echo -e "${YELLOW}... ($((ci_lines - 40)) more lines)${NC}"
        fi
        
        # Log the full cloud-init
        log_cloud_init "$decoded_ci_file"
        rm -f "$decoded_ci_file"
    fi
    
    # Log the config details (with truncated secrets, handles both key formats)
    local config_log_json
    config_log_json=$(echo "$detail_output" | jq '.data | {
        "display-name": (.["display-name"] // .displayName),
        "id": .id,
        "time-created": (.["time-created"] // .timeCreated),
        "instance-details": (
            (.["instance-details"]["launch-details"] // .["instance-details"].launchDetails // {})
            | . + {"metadata": (.metadata // {} | to_entries | map(
                if .key == "user_data" then .value = "<base64-cloud-init: \(.value | length) chars>"
                elif .key == "ssh_authorized_keys" then .value = "\(.value | .[0:50])..."
                else . end
            ) | from_entries)}
        )
    }' 2>/dev/null || echo "$detail_output" | jq '.data' 2>/dev/null)
    log_json "Selected Instance Configuration (full details)" "$config_log_json"
    
    #---------------------------------------------------------------------------
    # Optional: Override display name
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${BOLD}Instance Display Name:${NC}"

    # Generate a sensible default when config has no name
    local default_instance_name=""
    local prefix="${INSTANCE_NAME_PREFIX:-oke-worker}"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)

    if [[ "$config_display_name" == "N/A" || "$config_display_name" == "null" || -z "$config_display_name" ]]; then
        # Build default: prefix-clusterShortName-timestamp or prefix-timestamp
        if [[ -n "${CLUSTER_NAME:-}" ]]; then
            # Use last segment of cluster name for brevity (e.g. "oke-gpu-quickstart-npejxs" → "npejxs")
            local cluster_suffix
            cluster_suffix=$(echo "$CLUSTER_NAME" | rev | cut -d'-' -f1 | rev)
            default_instance_name="${prefix}-${cluster_suffix}-${ts}"
        else
            default_instance_name="${prefix}-${ts}"
        fi
        echo -e "  Current name in config: ${YELLOW}N/A (not set)${NC}"
        echo -e "  Generated default:      ${CYAN}${default_instance_name}${NC}"
        read -rp "  Enter name or press Enter for default: " name_override </dev/tty
    else
        default_instance_name="$config_display_name"
        echo -e "  Current name in config: ${CYAN}${config_display_name}${NC}"
        read -rp "  Enter new name or press Enter to keep: " name_override </dev/tty
    fi

    if [[ -n "$name_override" ]]; then
        INSTANCE_NAME_OVERRIDE="$name_override"
        SELECTED_INSTANCE_NAME="$name_override"
        print_info "Display name will be set to: $name_override (after launch)"
        log_message "INFO" "Display name override: $name_override"
    else
        INSTANCE_NAME_OVERRIDE="$default_instance_name"
        SELECTED_INSTANCE_NAME="$default_instance_name"
        if [[ "$config_display_name" == "N/A" || "$config_display_name" == "null" || -z "$config_display_name" ]]; then
            print_info "Display name will be set to: $default_instance_name (after launch)"
            log_message "INFO" "Display name from generated default: $default_instance_name"
        else
            print_info "Keeping display name: $default_instance_name"
        fi
    fi
    
    log_step "DEPLOYMENT EXECUTION STARTED (Existing Config)"
    log_message "INFO" "Using existing config: $selected_name ($CREATED_INSTANCE_CONFIG_ID)"
    log_message "INFO" "Shape: $config_shape | Boot: ${config_boot_size}GB @ ${config_boot_vpu} VPU"
    log_message "INFO" "Image: $config_image_name"
    log_message "INFO" "Instance Name: $SELECTED_INSTANCE_NAME"
}

# Update instance display name after launch (used when overriding name from existing config)
update_instance_display_name() {
    if [[ -z "${INSTANCE_NAME_OVERRIDE:-}" || -z "${CREATED_INSTANCE_ID:-}" ]]; then
        return 0
    fi
    
    print_info "Updating instance display name to: $INSTANCE_NAME_OVERRIDE"
    
    local update_cmd="oci compute instance update \\
    --instance-id \"$CREATED_INSTANCE_ID\" \\
    --display-name \"$INSTANCE_NAME_OVERRIDE\" \\
    --force"
    log_command "Update instance display name" "$update_cmd"
    
    local raw_output
    raw_output=$(oci compute instance update \
        --instance-id "$CREATED_INSTANCE_ID" \
        --display-name "$INSTANCE_NAME_OVERRIDE" \
        --force 2>&1) || true
    log_command_result "$?" "$raw_output"
    
    if echo "$raw_output" | jq -e '.data.id' &>/dev/null; then
        print_success "Display name updated to: $INSTANCE_NAME_OVERRIDE"
        log_message "INFO" "Instance display name updated: $INSTANCE_NAME_OVERRIDE"
    else
        print_warn "Failed to update display name (instance launched with original name)"
        print_debug "Output: $raw_output"
    fi
}

#-------------------------------------------------------------------------------
# Instance Configuration and Deployment
#-------------------------------------------------------------------------------

select_instance_configuration() {
    # This function is now only called in the "create new" path.
    # The "use existing" path is handled by use_existing_config_flow() before we get here.
    
    # If --instance-config-id was provided via CLI, validate and use it
    if [[ -n "${USE_EXISTING_INSTANCE_CONFIG:-}" ]]; then
        print_section "Instance Configuration (CLI-provided)"
        log_step "Instance Configuration (CLI-provided)"
        
        print_info "Validating instance configuration..."
        local ic_get_cmd="oci compute-management instance-configuration get \\
    --instance-configuration-id \"$USE_EXISTING_INSTANCE_CONFIG\""
        log_command "Validate CLI-provided instance configuration" "$ic_get_cmd"
        
        local raw_output
        raw_output=$(oci compute-management instance-configuration get \
            --instance-configuration-id "$USE_EXISTING_INSTANCE_CONFIG" 2>&1) || true
        log_command_result "$?" "$raw_output"
        
        if ! echo "$raw_output" | jq -e '.data.id' &>/dev/null; then
            print_error "Failed to validate instance configuration: $USE_EXISTING_INSTANCE_CONFIG"
            print_error "$raw_output"
            exit 1
        fi
        
        local config_name
        config_name=$(echo "$raw_output" | jq -r '.data."display-name"')
        CREATED_INSTANCE_CONFIG_ID="$USE_EXISTING_INSTANCE_CONFIG"
        print_success "Using instance configuration: $config_name"
        print_debug "Instance Configuration OCID: $CREATED_INSTANCE_CONFIG_ID"
        
        log_message "INFO" "Using CLI-provided instance configuration: $config_name ($CREATED_INSTANCE_CONFIG_ID)"
        
        # Log full config details (handles both kebab-case and camelCase)
        local config_display
        config_display=$(echo "$raw_output" | jq '.data | {
            "display-name": (.["display-name"] // .displayName),
            "id": .id,
            "time-created": (.["time-created"] // .timeCreated),
            "instance-details": (
                (.["instance-details"]["launch-details"] // .["instance-details"].launchDetails // {})
                | . + {"metadata": (.metadata // {} | to_entries | map(
                    if .key == "user_data" then .value = "<base64-cloud-init: \(.value | length) chars>"
                    elif .key == "ssh_authorized_keys" then .value = "\(.value | .[0:50])..."
                    else . end
                ) | from_entries)}
            )
        }' 2>/dev/null || echo "$raw_output" | jq '.data' 2>/dev/null)
        log_json "CLI-provided Instance Configuration Details" "$config_display" "true"
        
        # Log embedded cloud-init (try both key formats)
        local existing_user_data
        existing_user_data=$(echo "$raw_output" | jq -r '
            .data["instance-details"]["launch-details"].metadata.user_data //
            .data["instance-details"].launchDetails.metadata.user_data //
            empty' 2>/dev/null)
        if [[ -n "$existing_user_data" ]]; then
            local decoded_cloud_init_file
            decoded_cloud_init_file=$(mktemp)
            echo "$existing_user_data" | base64 -d > "$decoded_cloud_init_file" 2>/dev/null
            if [[ -s "$decoded_cloud_init_file" ]]; then
                log_cloud_init "$decoded_cloud_init_file"
                local ci_lines
                ci_lines=$(wc -l < "$decoded_cloud_init_file")
                print_info "Config contains cloud-init ($ci_lines lines) - logged to $LOG_FILE"
            fi
            rm -f "$decoded_cloud_init_file"
        fi
        
        return 0
    fi
    
    # Default: always create new instance configuration
    create_instance_configuration
}

create_instance_configuration() {
    print_section "Creating Instance Configuration"
    log_step "Create Instance Configuration"
    
    local config_name="${INSTANCE_CONFIG_PREFIX:-oke-ic}-$(date +%Y%m%d-%H%M%S)"
    
    print_info "Building instance configuration: $config_name"
    
    # Prepare cloud-init
    local cloud_init_base64=""
    local cloud_init_file="${CLOUD_INIT_FILE:-./cloud-init.yml}"
    
    if [[ -f "$cloud_init_file" ]]; then
        print_info "Encoding cloud-init from: $cloud_init_file"
        
        # Build kubelet extra args
        local kubelet_extra_args="--feature-gates=DynamicResourceAllocation=true"
        if [[ -n "${NODE_TAINTS:-}" ]]; then
            kubelet_extra_args="${kubelet_extra_args} --register-with-taints=${NODE_TAINTS}"
        else
            # Default taint for new nodes
            kubelet_extra_args="${kubelet_extra_args} --register-with-taints=newNode:NoSchedule"
        fi
        if [[ -n "${NODE_LABELS:-}" ]]; then
            kubelet_extra_args="${kubelet_extra_args} --node-labels=${NODE_LABELS}"
        fi
        
        # Create temp file for cloud-init processing
        local temp_cloud_init
        temp_cloud_init=$(mktemp)
        cp "$cloud_init_file" "$temp_cloud_init"
        
        # Use sed for reliable substitution (handles large strings like CA cert)
        # Support both __VARIABLE__ format and <variable> format
        # IMPORTANT: Compound patterns must be replaced BEFORE simple patterns!
        
        # OKE Version Short - for apt repo (MUST be first to catch compound patterns)
        sed -i "s|__OKE_VERSION_SHORT__|${SELECTED_OKE_VERSION_SHORT:-1-31}|g" "$temp_cloud_init"
        sed -i "s|<oke_version_short>|${SELECTED_OKE_VERSION_SHORT:-1-31}|g" "$temp_cloud_init"
        # Fix kubernetes-1.`<oke version>` pattern BEFORE replacing <oke version>
        # Apt repo needs 1.34 format (dot separator), not 1-34 (hyphen)
        local oke_version_apt
        oke_version_apt=$(echo "${SELECTED_OKE_VERSION:-1.31.1}" | cut -d. -f1-2)  # e.g., 1.34
        sed -i "s|kubernetes-1\.\`<oke version>\`|kubernetes-${oke_version_apt}|g" "$temp_cloud_init"
        
        # OKE Version - handle multiple formats (AFTER compound patterns)
        sed -i "s|__OKE_VERSION__|${SELECTED_OKE_VERSION:-1.31.1}|g" "$temp_cloud_init"
        sed -i "s|<oke_version>|${SELECTED_OKE_VERSION:-1.31.1}|g" "$temp_cloud_init"
        sed -i "s|<oke version>|${SELECTED_OKE_VERSION:-1.31.1}|g" "$temp_cloud_init"
        
        # API Server - use parsed IP address for all <api_server_host> placeholders
        # The IP is extracted from the full URL (e.g., https://150.230.187.134:6443 -> 150.230.187.134)
        sed -i "s|__API_SERVER_HOST__|${SELECTED_API_SERVER_IP:-}|g" "$temp_cloud_init"
        sed -i "s|<api_server_host>|${SELECTED_API_SERVER_IP:-}|g" "$temp_cloud_init"
        sed -i "s|<apiserver_host>|${SELECTED_API_SERVER_IP:-}|g" "$temp_cloud_init"
        
        # API Server IP and Port as separate variables
        sed -i "s|__API_SERVER_IP__|${SELECTED_API_SERVER_IP:-}|g" "$temp_cloud_init"
        sed -i "s|<api_server_ip>|${SELECTED_API_SERVER_IP:-}|g" "$temp_cloud_init"
        sed -i "s|__API_SERVER_PORT__|${SELECTED_API_SERVER_PORT:-6443}|g" "$temp_cloud_init"
        sed -i "s|<api_server_port>|${SELECTED_API_SERVER_PORT:-6443}|g" "$temp_cloud_init"
        
        # API Server Full URL (for cases that need https://ip:port)
        sed -i "s|__API_SERVER_URL__|${SELECTED_API_SERVER_HOST:-}|g" "$temp_cloud_init"
        sed -i "s|<api_server_url>|${SELECTED_API_SERVER_HOST:-}|g" "$temp_cloud_init"
        
        # API Server Host Only (same as IP) for oke bootstrap command
        # oke bootstrap expects just the hostname/IP, no protocol or port
        sed -i "s|__API_SERVER_HOST_ONLY__|${SELECTED_API_SERVER_IP:-}|g" "$temp_cloud_init"
        sed -i "s|<api_server_host_only>|${SELECTED_API_SERVER_IP:-}|g" "$temp_cloud_init"
        sed -i "s|<apiserver_host_only>|${SELECTED_API_SERVER_IP:-}|g" "$temp_cloud_init"
        
        # API Server Key/CA - handle <api_server_key> as CA cert alias
        sed -i "s|<api_server_key>|${SELECTED_API_SERVER_CA:-}|g" "$temp_cloud_init"
        sed -i "s|<api_server_key|${SELECTED_API_SERVER_CA:-}|g" "$temp_cloud_init"
        
        # SSH Key
        sed -i "s|__SSH_PUBLIC_KEY__|${SELECTED_SSH_KEY:-}|g" "$temp_cloud_init"
        sed -i "s|<ssh_public_key>|${SELECTED_SSH_KEY:-}|g" "$temp_cloud_init"
        
        # Node Labels and Taints
        sed -i "s|__NODE_LABELS__|${NODE_LABELS:-}|g" "$temp_cloud_init"
        sed -i "s|<node_labels>|${NODE_LABELS:-}|g" "$temp_cloud_init"
        sed -i "s|__NODE_TAINTS__|${NODE_TAINTS:-newNode:NoSchedule}|g" "$temp_cloud_init"
        sed -i "s|<node_taints>|${NODE_TAINTS:-newNode:NoSchedule}|g" "$temp_cloud_init"
        
        # Kubelet Extra Args
        sed -i "s|__KUBELET_EXTRA_ARGS__|${kubelet_extra_args}|g" "$temp_cloud_init"
        sed -i "s|<kubelet_extra_args>|${kubelet_extra_args}|g" "$temp_cloud_init"
        
        # Handle CA cert separately (it's a very long base64 string)
        # Use a temp file approach to avoid sed argument length limits
        if [[ -n "${SELECTED_API_SERVER_CA:-}" ]]; then
            local ca_temp
            ca_temp=$(mktemp)
            echo -n "${SELECTED_API_SERVER_CA}" > "$ca_temp"
            # Use perl for large replacement (more reliable than sed for huge strings)
            if command -v perl &>/dev/null; then
                perl -i -pe "s|__API_SERVER_CA__|$(cat "$ca_temp")|g" "$temp_cloud_init"
                perl -i -pe "s|<api_server_ca>|$(cat "$ca_temp")|g" "$temp_cloud_init"
                perl -i -pe "s|<api_server_key>|$(cat "$ca_temp")|g" "$temp_cloud_init"
                perl -i -pe "s|<ca_cert>|$(cat "$ca_temp")|g" "$temp_cloud_init"
                # Handle malformed pattern <api_server_key" (missing closing >)
                perl -i -pe 's|<api_server_key"|'"$(cat "$ca_temp")"'"|g' "$temp_cloud_init"
            else
                # Fallback: use awk for all CA patterns
                local ca_content
                ca_content=$(cat "$ca_temp")
                awk -v ca="$ca_content" '{
                    gsub(/__API_SERVER_CA__/, ca)
                    gsub(/<api_server_ca>/, ca)
                    gsub(/<api_server_key>/, ca)
                    gsub(/<ca_cert>/, ca)
                    gsub(/<api_server_key"/, ca "\"")
                    print
                }' "$temp_cloud_init" > "${temp_cloud_init}.new"
                mv "${temp_cloud_init}.new" "$temp_cloud_init"
            fi
            rm -f "$ca_temp"
        fi
        
        # Legacy variables (for backward compatibility)
        sed -i "s|__OKE_CLUSTER_ID__|${SELECTED_OKE_CLUSTER_ID:-}|g" "$temp_cloud_init"
        sed -i "s|__OKE_API_ENDPOINT__|${SELECTED_API_SERVER_HOST:-}|g" "$temp_cloud_init"
        sed -i "s|__NODE_POOL_ID__|${NODE_POOL_ID:-}|g" "$temp_cloud_init"
        sed -i "s|__COMPARTMENT_ID__|${SELECTED_COMPARTMENT_ID}|g" "$temp_cloud_init"
        sed -i "s|__TENANCY_ID__|${TENANCY_ID:-}|g" "$temp_cloud_init"
        sed -i "s|__REGION__|${REGION:-}|g" "$temp_cloud_init"
        sed -i "s|__CLUSTER_DNS_IP__|${SELECTED_CLUSTER_DNS_IP:-10.96.0.10}|g" "$temp_cloud_init"
        
        # Validate required substitutions
        if [[ -z "${SELECTED_API_SERVER_HOST:-}" ]]; then
            print_warn "API server host not configured - node may not join cluster"
        fi
        if [[ -z "${SELECTED_API_SERVER_CA:-}" ]]; then
            print_warn "CA certificate not configured - node may not join cluster"
        fi
        
        # Check for any remaining unsubstituted variables (both __VAR__ and <var> formats)
        local unsubstituted_vars=""
        if grep -qE "__[A-Z_]+__|<[a-z_]+>" "$temp_cloud_init"; then
            unsubstituted_vars=$(grep -oE "__[A-Z_]+__|<[a-z_]+>" "$temp_cloud_init" | sort -u)
            print_warn "Some variables may not have been substituted:"
            echo "$unsubstituted_vars" | head -10
        fi
        
        # VERIFY: Ensure oke bootstrap --apiserver-host has IP only (no protocol/port)
        # This is a safety net - substitution above should already handle it
        if grep -q "\-\-apiserver-host" "$temp_cloud_init"; then
            local bootstrap_host
            bootstrap_host=$(grep -oP '(?<=--apiserver-host )[^ "'"'"']+' "$temp_cloud_init" | head -1)
            if [[ "$bootstrap_host" == *"://"* || "$bootstrap_host" == *":"* ]]; then
                print_warn "oke bootstrap --apiserver-host still has protocol/port: $bootstrap_host"
                print_info "Stripping protocol and port..."
                sed -i -E 's|(--apiserver-host )(https?://)?([^: "'"'"']+)(:[0-9]+)?|\1\3|g' "$temp_cloud_init"
                bootstrap_host=$(grep -oP '(?<=--apiserver-host )[^ "'"'"']+' "$temp_cloud_init" | head -1)
            fi
            print_info "oke bootstrap --apiserver-host: $bootstrap_host"
        fi
        
        # Validate cloud-init schema before proceeding
        if command -v cloud-init &>/dev/null; then
            print_info "Validating cloud-init schema..."
            local validation_output
            if validation_output=$(sudo cloud-init schema --config-file "$temp_cloud_init" 2>&1); then
                print_success "Cloud-init schema validation passed"
            else
                print_error "Cloud-init schema validation failed:"
                echo "$validation_output"
                rm -f "$temp_cloud_init"
                exit 1
            fi
        fi
        
        if [[ "$DEBUG_MODE" == "true" ]]; then
            print_debug "Cloud-init substitutions:"
            echo "  OKE_VERSION: ${SELECTED_OKE_VERSION:-1.31.1}"
            echo "  OKE_VERSION_SHORT: ${SELECTED_OKE_VERSION_SHORT:-1-31}"
            echo "  API_SERVER_URL: ${SELECTED_API_SERVER_HOST:-NOT SET}"
            echo "  API_SERVER_IP: ${SELECTED_API_SERVER_IP:-NOT SET}"
            echo "  API_SERVER_PORT: ${SELECTED_API_SERVER_PORT:-NOT SET}"
            echo "  API_SERVER_CA: $(echo -n "${SELECTED_API_SERVER_CA:-}" | wc -c) bytes"
            echo "  KUBELET_EXTRA_ARGS: ${kubelet_extra_args}"
            echo ""
            print_debug "Cloud-init content (first 80 lines):"
            head -80 "$temp_cloud_init"
        fi
        
        # Log the full substituted cloud-init to the log file
        log_cloud_init "$temp_cloud_init"
        
        cloud_init_base64=$(base64 -w 0 < "$temp_cloud_init")
        rm -f "$temp_cloud_init"
        print_info "Cloud-init encoded (OKE v${SELECTED_OKE_VERSION:-1.31.1})"
    else
        print_warn "Cloud-init file not found: $cloud_init_file"
    fi
    
    # Build shape config JSON for flex shapes
    local shape_config=""
    if [[ -n "${SELECTED_OCPUS:-}" ]]; then
        shape_config=",\"shapeConfig\": {\"ocpus\": $SELECTED_OCPUS, \"memoryInGBs\": $SELECTED_MEMORY_GB}"
    fi
    
    # Build source details
    local source_details
    source_details=$(cat <<EOF
{
    "sourceType": "image",
    "bootVolumeSizeInGBs": ${SELECTED_BOOT_VOLUME_SIZE_GB:-100},
    "bootVolumeVpusPerGB": ${SELECTED_BOOT_VOLUME_VPU:-10},
    "imageId": "$SELECTED_IMAGE_ID"
}
EOF
)
    
    # Build instance details JSON
    local instance_details
    instance_details=$(cat <<EOF
{
    "availabilityDomain": "$SELECTED_AD",
    "compartmentId": "$SELECTED_COMPARTMENT_ID",
    "shape": "$SELECTED_SHAPE"$shape_config,
    "sourceDetails": $source_details,
    "createVnicDetails": {
        "subnetId": "$SELECTED_SUBNET_ID",
        "assignPublicIp": false
    },
    "metadata": {
        "ssh_authorized_keys": "$SELECTED_SSH_KEY"
    },
    "displayName": "$SELECTED_INSTANCE_NAME"
}
EOF
)
    
    # Add NSG IDs if selected
    if [[ ${#SELECTED_NSG_IDS[@]} -gt 0 ]]; then
        local nsg_json="["
        local first=true
        for nsg_id in "${SELECTED_NSG_IDS[@]}"; do
            if [[ "$first" == "true" ]]; then
                nsg_json="${nsg_json}\"${nsg_id}\""
                first=false
            else
                nsg_json="${nsg_json},\"${nsg_id}\""
            fi
        done
        nsg_json="${nsg_json}]"
        instance_details=$(echo "$instance_details" | jq --argjson nsgs "$nsg_json" \
            '.createVnicDetails.nsgIds = $nsgs')
        print_debug "Added NSG IDs to VNIC details: $nsg_json"
    fi
    
    # Add cloud-init if available
    if [[ -n "$cloud_init_base64" ]]; then
        instance_details=$(echo "$instance_details" | jq --arg ci "$cloud_init_base64" \
            '.metadata.user_data = $ci')
    fi
    
    print_debug "Instance details JSON:"
    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo "$instance_details" | jq .
    fi
    
    # Create instance configuration JSON
    # Note: --instance-details expects the content directly, NOT wrapped in "instanceDetails"
    local config_json
    config_json=$(cat <<EOF
{
    "instanceType": "compute",
    "launchDetails": $instance_details
}
EOF
)
    
    # Write to temp file for OCI CLI
    local temp_config_file
    temp_config_file=$(mktemp)
    echo "$config_json" > "$temp_config_file"
    
    # Log the full JSON blocks
    log_json "Source Details" "$source_details"
    log_json "Instance Details (launchDetails)" "$instance_details"
    log_json "Full Instance Configuration JSON" "$config_json"
    
    print_info "Creating instance configuration..."
    
    local ic_create_cmd="oci compute-management instance-configuration create \\
    --compartment-id \"$SELECTED_COMPARTMENT_ID\" \\
    --display-name \"$config_name\" \\
    --instance-details \"file://$temp_config_file\""
    log_command "Create instance configuration" "$ic_create_cmd"
    
    local result
    local raw_output
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Config file contents:"
        cat "$temp_config_file" | jq .
        print_debug "Running: oci compute-management instance-configuration create ..."
    fi
    
    raw_output=$(oci compute-management instance-configuration create \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --display-name "$config_name" \
        --instance-details "file://$temp_config_file" 2>&1) || true
    log_command_result "$?" "$raw_output"
    
    rm -f "$temp_config_file"
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Raw output (first 500 chars):"
        echo "${raw_output:0:500}"
    fi
    
    if ! echo "$raw_output" | jq -e '.data.id' &>/dev/null; then
        print_error "Failed to create instance configuration"
        print_error "$raw_output"
        exit 1
    fi
    
    CREATED_INSTANCE_CONFIG_ID=$(echo "$raw_output" | jq -r '.data.id')
    print_success "Instance configuration created: $config_name"
    print_debug "Instance Configuration OCID: $CREATED_INSTANCE_CONFIG_ID"
    log_message "INFO" "Created instance configuration: $config_name ($CREATED_INSTANCE_CONFIG_ID)"
}

launch_instance() {
    print_section "Launching Instance"
    log_step "Launch Instance"
    
    print_info "Launching instance from configuration..."
    
    local launch_cmd="oci compute-management instance-configuration launch-compute-instance \\
    --instance-configuration-id \"$CREATED_INSTANCE_CONFIG_ID\""
    log_command "Launch instance from configuration" "$launch_cmd"
    
    local raw_output
    
    raw_output=$(oci compute-management instance-configuration launch-compute-instance \
        --instance-configuration-id "$CREATED_INSTANCE_CONFIG_ID" 2>&1) || true
    log_command_result "$?" "$raw_output"
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Raw output (first 500 chars):"
        echo "${raw_output:0:500}"
    fi
    
    if ! echo "$raw_output" | jq -e '.data.id' &>/dev/null; then
        print_error "Failed to launch instance"
        print_error "$raw_output"
        exit 1
    fi
    
    CREATED_INSTANCE_ID=$(echo "$raw_output" | jq -r '.data.id')
    print_success "Instance launch initiated"
    print_debug "Instance OCID: $CREATED_INSTANCE_ID"
    log_message "INFO" "Instance launched: $CREATED_INSTANCE_ID"
}

wait_for_instance() {
    print_section "Waiting for Instance to be Running"
    log_step "Wait for Instance"
    
    local timeout="${INSTANCE_WAIT_TIMEOUT_SECONDS:-600}"
    local interval="${INSTANCE_POLL_INTERVAL_SECONDS:-10}"
    local elapsed=0
    
    print_info "Timeout: ${timeout}s, Poll interval: ${interval}s"
    log_message "INFO" "Waiting for instance $CREATED_INSTANCE_ID (timeout: ${timeout}s, interval: ${interval}s)"
    
    local poll_cmd="oci compute instance get \\
    --instance-id \"$CREATED_INSTANCE_ID\""
    log_command "Poll instance state" "$poll_cmd"
    
    while [[ $elapsed -lt $timeout ]]; do
        local state
        local raw_output
        
        raw_output=$(oci compute instance get \
            --instance-id "$CREATED_INSTANCE_ID" 2>&1) || true
        
        if echo "$raw_output" | jq -e '.data["lifecycle-state"]' &>/dev/null; then
            state=$(echo "$raw_output" | jq -r '.data["lifecycle-state"]')
        else
            state="UNKNOWN"
        fi
        
        log_message "POLL" "[${elapsed}s] Instance state: $state"
        
        case "$state" in
            "RUNNING")
                echo ""
                print_success "Instance is RUNNING!"
                log_message "INFO" "Instance is RUNNING after ${elapsed}s"
                return 0
                ;;
            "TERMINATED"|"TERMINATING")
                echo ""
                print_error "Instance entered $state state"
                log_message "ERROR" "Instance entered $state state after ${elapsed}s"
                return 1
                ;;
            "PROVISIONING"|"STARTING")
                printf "\r${BLUE}[%ds]${NC} Instance state: ${YELLOW}%s${NC}     " "$elapsed" "$state"
                ;;
            *)
                printf "\r${BLUE}[%ds]${NC} Instance state: %s     " "$elapsed" "$state"
                ;;
        esac
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    
    echo ""
    print_error "Timeout waiting for instance to be RUNNING"
    log_message "ERROR" "Timeout after ${timeout}s waiting for instance to be RUNNING"
    return 1
}

get_instance_details() {
    print_section "Instance Details"
    log_step "Instance Details"
    
    local get_cmd="oci compute instance get \\
    --instance-id \"$CREATED_INSTANCE_ID\""
    log_command "Get instance details" "$get_cmd"
    
    local raw_output
    raw_output=$(oci compute instance get \
        --instance-id "$CREATED_INSTANCE_ID" 2>&1) || true
    log_command_result "$?" "$raw_output"
    
    if ! echo "$raw_output" | jq -e '.data' &>/dev/null; then
        print_error "Failed to fetch instance details"
        return 1
    fi
    
    local instance_info
    instance_info=$(echo "$raw_output" | jq '.data')
    
    local display_name lifecycle_state time_created shape ad
    display_name=$(echo "$instance_info" | jq -r '.["display-name"]')
    lifecycle_state=$(echo "$instance_info" | jq -r '.["lifecycle-state"]')
    time_created=$(echo "$instance_info" | jq -r '.["time-created"]')
    shape=$(echo "$instance_info" | jq -r '.shape')
    ad=$(echo "$instance_info" | jq -r '.["availability-domain"]')
    
    # Get VNIC and IP
    local vnic_list_cmd="oci compute vnic-attachment list \\
    --compartment-id \"$SELECTED_COMPARTMENT_ID\" \\
    --instance-id \"$CREATED_INSTANCE_ID\""
    log_command "List VNIC attachments" "$vnic_list_cmd"
    
    local vnic_raw
    vnic_raw=$(oci compute vnic-attachment list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --instance-id "$CREATED_INSTANCE_ID" 2>&1) || true
    log_command_result "$?" "$vnic_raw"
    
    local vnic_id=""
    if echo "$vnic_raw" | jq -e '.data[0]["vnic-id"]' &>/dev/null; then
        vnic_id=$(echo "$vnic_raw" | jq -r '.data[0]["vnic-id"]')
    fi
    
    local private_ip="Pending..."
    local public_ip="N/A"
    
    if [[ -n "$vnic_id" && "$vnic_id" != "null" ]]; then
        local vnic_get_cmd="oci network vnic get --vnic-id \"$vnic_id\""
        log_command "Get VNIC details" "$vnic_get_cmd"
        
        local vnic_info_raw
        vnic_info_raw=$(oci network vnic get --vnic-id "$vnic_id" 2>&1) || true
        log_command_result "$?" "$vnic_info_raw"
        
        if echo "$vnic_info_raw" | jq -e '.data' &>/dev/null; then
            private_ip=$(echo "$vnic_info_raw" | jq -r '.data["private-ip"] // "N/A"')
            public_ip=$(echo "$vnic_info_raw" | jq -r '.data["public-ip"] // "N/A"')
        fi
    fi
    
    echo ""
    echo -e "${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║                    INSTANCE SUMMARY                            ║${NC}"
    echo -e "${BOLD}╠════════════════════════════════════════════════════════════════╣${NC}"
    printf "${BOLD}║${NC} %-18s │ %-42s ${BOLD}║${NC}\n" "Display Name" "$display_name"
    printf "${BOLD}║${NC} %-18s │ %-42s ${BOLD}║${NC}\n" "State" "$lifecycle_state"
    printf "${BOLD}║${NC} %-18s │ %-42s ${BOLD}║${NC}\n" "Shape" "$shape"
    if [[ -n "${SELECTED_OCPUS:-}" ]]; then
        printf "${BOLD}║${NC} %-18s │ %-42s ${BOLD}║${NC}\n" "OCPUs / Memory" "${SELECTED_OCPUS} OCPUs / ${SELECTED_MEMORY_GB}GB"
    fi
    printf "${BOLD}║${NC} %-18s │ %-42s ${BOLD}║${NC}\n" "Boot Volume" "${SELECTED_BOOT_VOLUME_SIZE_GB}GB / ${SELECTED_BOOT_VOLUME_VPU} VPUs/GB"
    printf "${BOLD}║${NC} %-18s │ %-42s ${BOLD}║${NC}\n" "Availability Domain" "${ad##*:}"
    printf "${BOLD}║${NC} %-18s │ %-42s ${BOLD}║${NC}\n" "Private IP" "$private_ip"
    printf "${BOLD}║${NC} %-18s │ %-42s ${BOLD}║${NC}\n" "Public IP" "$public_ip"
    printf "${BOLD}║${NC} %-18s │ %-42s ${BOLD}║${NC}\n" "Created" "${time_created%%.*}"
    echo -e "${BOLD}╠════════════════════════════════════════════════════════════════╣${NC}"
    printf "${BOLD}║${NC} %-63s ${BOLD}║${NC}\n" "Instance OCID:"
    printf "${BOLD}║${NC} %-63s ${BOLD}║${NC}\n" "$CREATED_INSTANCE_ID"
    echo -e "${BOLD}╠════════════════════════════════════════════════════════════════╣${NC}"
    printf "${BOLD}║${NC} %-63s ${BOLD}║${NC}\n" "Instance Config OCID:"
    printf "${BOLD}║${NC} %-63s ${BOLD}║${NC}\n" "$CREATED_INSTANCE_CONFIG_ID"
    echo -e "${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # SSH connection hint
    if [[ "$private_ip" != "Pending..." && "$private_ip" != "N/A" ]]; then
        print_info "SSH connection: ssh opc@$private_ip"
    fi
    
    # Log the summary
    log_message "INFO" "Instance Summary: name=$display_name state=$lifecycle_state shape=$shape private_ip=$private_ip"
    log_message "INFO" "Instance OCID: $CREATED_INSTANCE_ID"
    log_message "INFO" "Instance Config OCID: $CREATED_INSTANCE_CONFIG_ID"
    
    # Log the full instance summary to the log file
    if [[ "${ENABLE_LOGGING:-true}" == "true" && -n "${LOG_FILE:-}" ]]; then
        {
            echo ""
            echo "================================================================================"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SUMMARY] Instance Summary"
            echo "================================================================================"
            echo "Display Name:        $display_name"
            echo "State:               $lifecycle_state"
            echo "Shape:               $shape"
            if [[ -n "${SELECTED_OCPUS:-}" ]]; then
                echo "OCPUs / Memory:      ${SELECTED_OCPUS} OCPUs / ${SELECTED_MEMORY_GB}GB"
            fi
            echo "Boot Volume:         ${SELECTED_BOOT_VOLUME_SIZE_GB}GB / ${SELECTED_BOOT_VOLUME_VPU} VPUs/GB"
            echo "Availability Domain: ${ad##*:}"
            echo "Private IP:          $private_ip"
            echo "Public IP:           $public_ip"
            echo "Created:             ${time_created%%.*}"
            echo "Instance OCID:       $CREATED_INSTANCE_ID"
            echo "Instance Config:     $CREATED_INSTANCE_CONFIG_ID"
            if [[ "$private_ip" != "Pending..." && "$private_ip" != "N/A" ]]; then
                echo "SSH Command:         ssh opc@$private_ip"
            fi
            echo "================================================================================"
            echo ""
        } >> "$LOG_FILE"
    fi
}

check_console_history() {
    print_section "Console History"
    
    if [[ -z "${CREATED_INSTANCE_ID:-}" ]]; then
        print_warn "No instance ID — skipping console history"
        return 0
    fi

    echo ""
    read -rp "Would you like to check the console history? [y/N]: " check_console </dev/tty
    
    if [[ "${check_console,,}" != "y" ]]; then
        print_info "Skipping console history check"
        return 0
    fi
    
    local max_wait="${CONSOLE_HISTORY_WAIT_SECONDS:-180}"
    local poll_interval=10
    local history_id=""
    local history_state=""

    #---------------------------------------------------------------------------
    # Step 1: Capture a fresh console history snapshot
    #---------------------------------------------------------------------------
    print_info "Requesting console history capture..."

    local capture_cmd="oci compute console-history capture \\
    --instance-id \"$CREATED_INSTANCE_ID\""
    log_command "Capture console history" "$capture_cmd"

    local capture_raw
    capture_raw=$(oci compute console-history capture \
        --instance-id "$CREATED_INSTANCE_ID" 2>&1) || true
    log_command_result "$?" "$capture_raw"

    if echo "$capture_raw" | jq -e '.data.id' &>/dev/null; then
        history_id=$(echo "$capture_raw" | jq -r '.data.id')
        history_state=$(echo "$capture_raw" | jq -r '.data["lifecycle-state"] // "REQUESTED"')
        print_info "Capture ID: $history_id"
        print_info "State: $history_state"
    else
        # Capture failed — show the raw error and fall back
        print_warn "Capture request failed"
        if [[ -n "$capture_raw" ]]; then
            echo -e "  ${RED}Response:${NC} $(echo "$capture_raw" | head -5)"
        fi

        echo ""
        print_info "Falling back to existing console history..."

        local list_cmd="oci compute console-history list \\
    --compartment-id \"$SELECTED_COMPARTMENT_ID\" \\
    --instance-id \"$CREATED_INSTANCE_ID\" \\
    --sort-by TIMECREATED --sort-order DESC \\
    --limit 1"
        log_command "List existing console history" "$list_cmd"

        local list_raw
        list_raw=$(oci compute console-history list \
            --compartment-id "$SELECTED_COMPARTMENT_ID" \
            --instance-id "$CREATED_INSTANCE_ID" \
            --sort-by TIMECREATED --sort-order DESC \
            --limit 1 2>&1) || true
        log_command_result "$?" "$list_raw"

        if echo "$list_raw" | jq -e '.data[0].id' &>/dev/null; then
            history_id=$(echo "$list_raw" | jq -r '.data[0].id')
            history_state=$(echo "$list_raw" | jq -r '.data[0]["lifecycle-state"] // "UNKNOWN"')
            print_info "Found existing capture: $history_id (state: $history_state)"
        else
            print_warn "No console history available for this instance"
            if [[ -n "$list_raw" ]]; then
                echo -e "  ${RED}Response:${NC} $(echo "$list_raw" | head -5)"
            fi
            return 0
        fi
    fi

    #---------------------------------------------------------------------------
    # Step 2: Poll lifecycle state until SUCCEEDED (or timeout)
    #---------------------------------------------------------------------------
    if [[ "$history_state" != "SUCCEEDED" ]]; then
        print_info "Waiting for capture to complete (timeout: ${max_wait}s)..."

        local poll_cmd="oci compute console-history get \\
    --instance-console-history-id \"$history_id\" \\
    --query 'data.\"lifecycle-state\"' --raw-output"
        log_command "Poll console history state" "$poll_cmd"

        local elapsed=0
        while [[ $elapsed -lt $max_wait ]]; do
            printf "\r  ${BLUE}[%d/%ds]${NC} Capture state: %-15s" "$elapsed" "$max_wait" "$history_state"
            sleep "$poll_interval"
            elapsed=$((elapsed + poll_interval))

            local status_raw
            status_raw=$(oci compute console-history get \
                --instance-console-history-id "$history_id" \
                --query 'data."lifecycle-state"' --raw-output 2>&1) || true

            if [[ -n "$status_raw" && "$status_raw" != *"ServiceError"* ]]; then
                history_state="$status_raw"
            else
                # Show the error on first failure
                if [[ $elapsed -eq $poll_interval ]]; then
                    echo ""
                    print_warn "Poll returned error: $(echo "$status_raw" | head -3)"
                fi
            fi

            if [[ "$history_state" == "SUCCEEDED" ]]; then
                printf "\r  ${GREEN}[%d/%ds]${NC} Capture state: SUCCEEDED        \n" "$elapsed" "$max_wait"
                break
            fi

            if [[ "$history_state" == "FAILED" ]]; then
                printf "\r  ${RED}[%d/%ds]${NC} Capture state: FAILED           \n" "$elapsed" "$max_wait"
                print_error "Console history capture failed"
                return 0
            fi
        done

        if [[ "$history_state" != "SUCCEEDED" ]]; then
            echo ""
            print_warn "Timed out waiting for capture (state: $history_state)"
            print_info "You can retrieve it later with:"
            echo "  oci compute console-history get-content \\"
            echo "      --instance-console-history-id \"$history_id\" \\"
            echo "      --file console-output.log"
            return 0
        fi
    else
        print_info "Capture already completed"
    fi

    #---------------------------------------------------------------------------
    # Step 3: Retrieve console history content
    #---------------------------------------------------------------------------
    print_info "Retrieving console output..."

    local content_cmd="oci compute console-history get-content \\
    --instance-console-history-id \"$history_id\" \\
    --length 1048576 \\
    --file -"
    log_command "Get console history content" "$content_cmd"

    local content
    content=$(oci compute console-history get-content \
        --instance-console-history-id "$history_id" \
        --length 1048576 \
        --file - 2>&1) || true

    # Check if we got an error instead of content
    if echo "$content" | grep -q "ServiceError\|\"code\":" 2>/dev/null; then
        print_warn "get-content returned an error:"
        echo -e "  ${RED}$(echo "$content" | head -10)${NC}"
        print_info "You can retry manually with:"
        echo "  oci compute console-history get-content \\"
        echo "      --instance-console-history-id \"$history_id\" \\"
        echo "      --file console-output.log"
        return 0
    fi

    if [[ -z "$content" ]]; then
        print_warn "Console history capture succeeded but content is empty"
        print_info "The instance may still be in early boot. Retry with:"
        echo "  oci compute console-history get-content \\"
        echo "      --instance-console-history-id \"$history_id\" \\"
        echo "      --file console-output.log"
        return 0
    fi

    local content_lines
    content_lines=$(echo "$content" | wc -l)
    local content_bytes
    content_bytes=$(echo "$content" | wc -c)

    print_info "Retrieved $content_lines lines ($content_bytes bytes)"

    #---------------------------------------------------------------------------
    # Step 4: Display and save
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━ CONSOLE OUTPUT (last 100 lines of $content_lines) ━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "$content" | tail -100
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Save full output to file
    local log_file="console-history-${CREATED_INSTANCE_ID##*.}.log"
    echo "$content" > "$log_file"
    print_info "Full console history: $log_file ($content_lines lines, $content_bytes bytes)"
    log_message "INFO" "Console history saved: $log_file ($content_lines lines, $content_bytes bytes)"

    #---------------------------------------------------------------------------
    # Step 5: Quick-scan for common bootstrap issues
    #---------------------------------------------------------------------------
    echo ""
    echo -e "  ${BOLD}Boot Diagnostics:${NC}"

    # Check for cloud-init completion
    if echo "$content" | grep -qi "Cloud-init.*finished\|Cloud-init v.*finished"; then
        echo -e "    ${GREEN}✅${NC} cloud-init finished"
    elif echo "$content" | grep -qi "cloud-init"; then
        echo -e "    ${YELLOW}⚠️${NC}  cloud-init started but may not have finished"
    else
        echo -e "    ${YELLOW}⚠️${NC}  no cloud-init output found (may still be booting)"
    fi

    # Check for oke-init / kubelet
    if echo "$content" | grep -qi "oke-init.*complete\|oke-init.*success\|Started oke-init"; then
        echo -e "    ${GREEN}✅${NC} oke-init service ran"
    elif echo "$content" | grep -qi "oke-init\|oke.bootstrap\|oke bootstrap"; then
        echo -e "    ${YELLOW}⚠️${NC}  oke-init referenced but completion not confirmed"
    fi

    if echo "$content" | grep -qi "kubelet.*started\|Started kubelet\|Starting Kubernetes"; then
        echo -e "    ${GREEN}✅${NC} kubelet started"
    fi

    # Check for errors
    local error_count
    error_count=$(echo "$content" | grep -cEi "FATAL|panic|kernel BUG|Oops:|segfault|oom-kill|Out of memory" || true)
    if [[ "$error_count" -gt 0 ]]; then
        echo -e "    ${RED}❌${NC} $error_count critical error(s) detected in console output"
        echo ""
        echo -e "  ${BOLD}Error lines:${NC}"
        echo "$content" | grep -Ei "FATAL|panic|kernel BUG|Oops:|segfault|oom-kill|Out of memory" | tail -10 | while IFS= read -r line; do
            echo -e "    ${RED}│${NC} ${line:0:120}"
        done
    else
        echo -e "    ${GREEN}✅${NC} no critical errors (FATAL/panic/OOM) in console output"
    fi

    # Check for connectivity issues
    if echo "$content" | grep -qi "Connection timed out.*12250\|Connection refused.*12250\|port 12250.*timed out"; then
        echo -e "    ${RED}❌${NC} port 12250 connectivity failure detected — check NSG rules"
    fi
    if echo "$content" | grep -qi "Connection timed out.*6443\|Connection refused.*6443"; then
        echo -e "    ${RED}❌${NC} port 6443 connectivity failure detected — check NSG/routing"
    fi

    echo ""
}

verify_node_registration() {
    print_section "Node Registration Verification"
    
    # Only attempt if we have kubeconfig
    if [[ -z "${SELECTED_KUBECONFIG_BASE64:-}" ]]; then
        print_warn "No kubeconfig configured - skipping node registration check"
        print_info "Verify manually with: kubectl get nodes"
        return 0
    fi
    
    echo ""
    read -rp "Would you like to verify node registration in the cluster? [y/N]: " verify_node
    
    if [[ "${verify_node,,}" != "y" ]]; then
        print_info "Skipping node registration verification"
        return 0
    fi
    
    # Create temporary kubeconfig
    local temp_kubeconfig
    temp_kubeconfig=$(mktemp)
    echo "${SELECTED_KUBECONFIG_BASE64}" | base64 -d > "$temp_kubeconfig"
    
    # Get instance hostname (used as node name)
    local instance_name="$SELECTED_INSTANCE_NAME"
    
    print_info "Waiting for node '$instance_name' to register with cluster..."
    print_info "(This may take 2-5 minutes for cloud-init to complete)"
    
    local max_attempts=30
    local attempt=1
    local wait_interval=10
    
    while [[ $attempt -le $max_attempts ]]; do
        printf "\r${BLUE}[Attempt %d/%d]${NC} Checking node registration..." "$attempt" "$max_attempts"
        
        # Check if node exists
        local node_status
        node_status=$(kubectl --kubeconfig="$temp_kubeconfig" get node "$instance_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        
        if [[ "$node_status" == "True" ]]; then
            echo ""
            print_success "Node '$instance_name' is registered and Ready!"
            echo ""
            kubectl --kubeconfig="$temp_kubeconfig" get node "$instance_name" -o wide
            rm -f "$temp_kubeconfig"
            return 0
        elif [[ -n "$node_status" ]]; then
            echo ""
            print_info "Node found but not Ready yet (status: $node_status)"
        fi
        
        sleep $wait_interval
        ((attempt++))
    done
    
    echo ""
    print_warn "Node registration check timed out"
    print_info "The node may still be initializing. Check manually with:"
    echo "  kubectl get nodes"
    echo "  kubectl describe node $instance_name"
    
    rm -f "$temp_kubeconfig"
}

#-------------------------------------------------------------------------------
# Cleanup/Delete Function
#-------------------------------------------------------------------------------

cleanup_resources() {
    print_header "OKE Node Cleanup"
    
    # Check prerequisites
    if ! command -v oci &>/dev/null; then
        print_error "OCI CLI is not installed"
        exit 1
    fi
    
    # Load variables.sh if present
    if [[ -f "${SCRIPT_DIR}/variables.sh" ]]; then
        source "${SCRIPT_DIR}/variables.sh"
    fi
    
    # Unset empty OCI_CLI_AUTH
    if [[ -z "${OCI_CLI_AUTH:-}" ]]; then
        unset OCI_CLI_AUTH
    fi
    
    # Fetch metadata for defaults
    fetch_instance_metadata || true
    
    # Select compartment
    select_compartment
    
    echo ""
    echo -e "${BOLD}What would you like to delete?${NC}"
    echo -e "  ${BOLD}[1]${NC} Instances (compute instances)"
    echo -e "  ${BOLD}[2]${NC} Instance Configurations"
    echo -e "  ${BOLD}[3]${NC} Both Instances and Configurations"
    echo -e "  ${BOLD}[4]${NC} Cancel"
    echo ""
    
    local delete_choice
    read -rp "Enter selection [1-4]: " delete_choice
    
    case "$delete_choice" in
        1)
            delete_instances
            ;;
        2)
            delete_instance_configurations
            ;;
        3)
            delete_instances
            delete_instance_configurations
            ;;
        4|*)
            print_info "Cleanup cancelled"
            exit 0
            ;;
    esac
    
    print_success "Cleanup complete"
}

delete_instances() {
    print_section "Delete Instances"
    
    print_info "Fetching instances in compartment..."
    
    local raw_output
    raw_output=$(oci compute instance list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --lifecycle-state RUNNING \
        --all 2>&1) || true
    
    if ! echo "$raw_output" | jq -e '.data' &>/dev/null; then
        print_warn "Could not fetch instances"
        return
    fi
    
    # Filter for oke-worker instances
    local instances
    instances=$(echo "$raw_output" | jq -c '[.data[] | select(.["display-name"] | test("oke-worker|oke-node"; "i"))]')
    
    local count
    count=$(echo "$instances" | jq 'length')
    
    if [[ "$count" -eq 0 ]]; then
        print_info "No OKE worker instances found"
        
        # Show all instances as alternative
        echo ""
        read -rp "Show all instances in compartment? [y/N]: " show_all
        if [[ "${show_all,,}" == "y" ]]; then
            instances=$(echo "$raw_output" | jq -c '.data')
            count=$(echo "$instances" | jq 'length')
            if [[ "$count" -eq 0 ]]; then
                print_info "No running instances found"
                return
            fi
        else
            return
        fi
    fi
    
    print_info "Found $count instances"
    
    # Enhance display
    instances=$(echo "$instances" | jq -c '[.[] | . + {
        "display-info": (.["display-name"] + " (" + .shape + ", " + (.["time-created"] | split("T")[0]) + ")")
    }]')
    
    echo ""
    echo -e "${BOLD}Select instances to delete (comma-separated, e.g., 1,3,5 or 'all'):${NC}"
    echo ""
    
    local i=1
    while IFS= read -r item; do
        local name id
        name=$(echo "$item" | jq -r '.["display-info"]')
        id=$(echo "$item" | jq -r '.id')
        echo -e "  ${BOLD}[$i]${NC} $name"
        if [[ "$DEBUG_MODE" == "true" ]]; then
            echo -e "      ${MAGENTA}$id${NC}"
        fi
        ((i++))
    done < <(echo "$instances" | jq -c '.[]')
    
    echo ""
    local selection
    read -rp "Enter selection (or 'q' to cancel): " selection
    
    if [[ "$selection" == "q" || -z "$selection" ]]; then
        print_info "No instances deleted"
        return
    fi
    
    local indices=()
    if [[ "$selection" == "all" ]]; then
        for ((j=1; j<=count; j++)); do
            indices+=($j)
        done
    else
        IFS=',' read -ra indices <<< "$selection"
    fi
    
    echo ""
    echo -e "${RED}${BOLD}WARNING: This will TERMINATE the following instances:${NC}"
    for idx in "${indices[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 1 ]] && [[ "$idx" -le "$count" ]]; then
            local name
            name=$(echo "$instances" | jq -r ".[$((idx-1))][\"display-name\"]")
            echo "  - $name"
        fi
    done
    echo ""
    
    read -rp "Are you sure? Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "Deletion cancelled"
        return
    fi
    
    # Delete selected instances
    for idx in "${indices[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 1 ]] && [[ "$idx" -le "$count" ]]; then
            local instance_id instance_name
            instance_id=$(echo "$instances" | jq -r ".[$((idx-1))].id")
            instance_name=$(echo "$instances" | jq -r ".[$((idx-1))][\"display-name\"]")
            
            print_info "Terminating: $instance_name..."
            
            if oci compute instance terminate \
                --instance-id "$instance_id" \
                --preserve-boot-volume false \
                --force 2>&1; then
                print_success "Terminated: $instance_name"
            else
                print_error "Failed to terminate: $instance_name"
            fi
        fi
    done
}

delete_instance_configurations() {
    print_section "Delete Instance Configurations"
    
    print_info "Fetching instance configurations..."
    
    local raw_output
    raw_output=$(oci compute-management instance-configuration list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --all 2>&1) || true
    
    if ! echo "$raw_output" | jq -e '.data' &>/dev/null; then
        print_warn "Could not fetch instance configurations"
        return
    fi
    
    # Filter for oke configs
    local configs
    configs=$(echo "$raw_output" | jq -c '[.data[] | select(.["display-name"] | test("oke-ic|oke-node|oke-config"; "i"))]')
    
    local count
    count=$(echo "$configs" | jq 'length')
    
    if [[ "$count" -eq 0 ]]; then
        print_info "No OKE instance configurations found"
        
        # Show all configs as alternative
        echo ""
        read -rp "Show all instance configurations in compartment? [y/N]: " show_all
        if [[ "${show_all,,}" == "y" ]]; then
            configs=$(echo "$raw_output" | jq -c '.data')
            count=$(echo "$configs" | jq 'length')
            if [[ "$count" -eq 0 ]]; then
                print_info "No instance configurations found"
                return
            fi
        else
            return
        fi
    fi
    
    print_info "Found $count instance configurations"
    
    # Enhance display
    configs=$(echo "$configs" | jq -c '[.[] | . + {
        "display-info": (.["display-name"] + " (" + (.["time-created"] | split("T")[0]) + ")")
    }]')
    
    echo ""
    echo -e "${BOLD}Select configurations to delete (comma-separated, e.g., 1,3,5 or 'all'):${NC}"
    echo ""
    
    local i=1
    while IFS= read -r item; do
        local name id
        name=$(echo "$item" | jq -r '.["display-info"]')
        id=$(echo "$item" | jq -r '.id')
        echo -e "  ${BOLD}[$i]${NC} $name"
        if [[ "$DEBUG_MODE" == "true" ]]; then
            echo -e "      ${MAGENTA}$id${NC}"
        fi
        ((i++))
    done < <(echo "$configs" | jq -c '.[]')
    
    echo ""
    local selection
    read -rp "Enter selection (or 'q' to cancel): " selection
    
    if [[ "$selection" == "q" || -z "$selection" ]]; then
        print_info "No configurations deleted"
        return
    fi
    
    local indices=()
    if [[ "$selection" == "all" ]]; then
        for ((j=1; j<=count; j++)); do
            indices+=($j)
        done
    else
        IFS=',' read -ra indices <<< "$selection"
    fi
    
    echo ""
    echo -e "${RED}${BOLD}WARNING: This will DELETE the following instance configurations:${NC}"
    for idx in "${indices[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 1 ]] && [[ "$idx" -le "$count" ]]; then
            local name
            name=$(echo "$configs" | jq -r ".[$((idx-1))][\"display-name\"]")
            echo "  - $name"
        fi
    done
    echo ""
    
    read -rp "Are you sure? Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "Deletion cancelled"
        return
    fi
    
    # Delete selected configurations
    for idx in "${indices[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 1 ]] && [[ "$idx" -le "$count" ]]; then
            local config_id config_name
            config_id=$(echo "$configs" | jq -r ".[$((idx-1))].id")
            config_name=$(echo "$configs" | jq -r ".[$((idx-1))][\"display-name\"]")
            
            print_info "Deleting: $config_name..."
            
            if oci compute-management instance-configuration delete \
                --instance-configuration-id "$config_id" \
                --force 2>&1; then
                print_success "Deleted: $config_name"
            else
                print_error "Failed to delete: $config_name"
            fi
        fi
    done
}

#-------------------------------------------------------------------------------
# NSG Validation Functions (--nsg-check / --nsg-fix / --nsg-dump)
#-------------------------------------------------------------------------------

nsg_check_pass() {
    local label="$1"
    echo -e "    ${GREEN}✅ PASS${NC}  $label"
    NSG_TOTAL_CHECKS=$((NSG_TOTAL_CHECKS + 1))
    NSG_PASSED_CHECKS=$((NSG_PASSED_CHECKS + 1))
}

nsg_check_fail() {
    local label="$1"
    echo -e "    ${RED}❌ FAIL${NC}  $label"
    NSG_TOTAL_CHECKS=$((NSG_TOTAL_CHECKS + 1))
    NSG_FAILED_CHECKS=$((NSG_FAILED_CHECKS + 1))
}

nsg_check_warn() {
    local label="$1"
    echo -e "    ${YELLOW}⚠️  WARN${NC}  $label"
    NSG_TOTAL_CHECKS=$((NSG_TOTAL_CHECKS + 1))
    NSG_WARNED_CHECKS=$((NSG_WARNED_CHECKS + 1))
}

# Fetch all rules for an NSG (cached)
nsg_fetch_rules() {
    local nsg_id="$1"
    if [[ -n "${NSG_RULES_CACHE[$nsg_id]+x}" ]]; then
        echo "${NSG_RULES_CACHE[$nsg_id]}"
        return 0
    fi

    local rules
    rules=$(oci network nsg rules list --nsg-id "$nsg_id" --all 2>/dev/null | jq '.data // []') || rules="[]"
    NSG_RULES_CACHE[$nsg_id]="$rules"
    echo "$rules"
}

# Check if a specific rule exists in an NSG
# Args: nsg_id direction protocol target port_min port_max [target_type]
nsg_check_rule_exists() {
    local nsg_id="$1"
    local direction="$2"
    local protocol="$3"
    local target="$4"
    local port_min="$5"
    local port_max="$6"
    local target_type="${7:-CIDR_BLOCK}"

    local rules
    rules=$(nsg_fetch_rules "$nsg_id")

    local target_field target_type_field
    if [[ "$direction" == "EGRESS" ]]; then
        target_field="destination"
        target_type_field="destination-type"
    else
        target_field="source"
        target_type_field="source-type"
    fi

    # Gather rules matching direction + (specific protocol OR protocol "all")
    local combined
    combined=$(echo "$rules" | jq "[.[] | select(
        .direction == \"$direction\" and
        (.protocol == \"$protocol\" or .protocol == \"all\")
    )]" 2>/dev/null)

    if ! echo "$combined" | jq -e '.[0]' &>/dev/null; then
        return 1
    fi

    # Filter by target (CIDR match, 0.0.0.0/0 catch-all, or NSG-to-NSG)
    local target_matches
    if [[ "$target_type" == "CIDR_BLOCK" ]]; then
        target_matches=$(echo "$combined" | jq "[.[] | select(
            (.[\"$target_field\"] == \"$target\") or
            (.[\"$target_field\"] == \"0.0.0.0/0\") or
            (.[\"$target_type_field\"] == \"NETWORK_SECURITY_GROUP\") or
            (.[\"$target_type_field\"] == \"SERVICE_CIDR_BLOCK\")
        )]" 2>/dev/null)
    elif [[ "$target_type" == "NETWORK_SECURITY_GROUP" ]]; then
        target_matches=$(echo "$combined" | jq "[.[] | select(
            (.[\"$target_field\"] == \"$target\" and .[\"$target_type_field\"] == \"NETWORK_SECURITY_GROUP\") or
            (.[\"$target_field\"] == \"0.0.0.0/0\")
        )]" 2>/dev/null)
    else
        target_matches=$(echo "$combined" | jq "[.[] | select(
            .[\"$target_field\"] == \"$target\" or
            .[\"$target_field\"] == \"0.0.0.0/0\"
        )]" 2>/dev/null)
    fi

    if ! echo "$target_matches" | jq -e '.[0]' &>/dev/null; then
        return 1
    fi

    # If any matching rule has protocol "all", ports are irrelevant
    local has_all_proto
    has_all_proto=$(echo "$target_matches" | jq '[.[] | select(.protocol == "all")] | length' 2>/dev/null)
    if [[ "$has_all_proto" -gt 0 ]]; then
        return 0
    fi

    # Check port range for TCP (6) / UDP (17)
    if [[ "$protocol" == "6" || "$protocol" == "17" ]]; then
        local port_key
        [[ "$protocol" == "6" ]] && port_key="tcp-options" || port_key="udp-options"

        local port_matches
        port_matches=$(echo "$target_matches" | jq "[.[] | select(
            .[\"$port_key\"] == null or
            (.[\"$port_key\"][\"destination-port-range\"].min <= $port_min and
             .[\"$port_key\"][\"destination-port-range\"].max >= $port_max)
        )]" 2>/dev/null)

        echo "$port_matches" | jq -e '.[0]' &>/dev/null && return 0
        return 1
    fi

    # Check ICMP type
    if [[ "$protocol" == "1" ]]; then
        local icmp_matches
        icmp_matches=$(echo "$target_matches" | jq "[.[] | select(
            .[\"icmp-options\"] == null or
            .[\"icmp-options\"].type == $port_min
        )]" 2>/dev/null)
        echo "$icmp_matches" | jq -e '.[0]' &>/dev/null && return 0
        return 1
    fi

    return 0
}

# Run a single check and accumulate results
nsg_run_check() {
    local label="$1"
    local nsg_id="$2"
    local nsg_name="$3"
    local direction="$4"
    local protocol="$5"
    local target="$6"
    local port_min="$7"
    local port_max="$8"
    local target_type="${9:-CIDR_BLOCK}"
    local critical="${10:-true}"

    if nsg_check_rule_exists "$nsg_id" "$direction" "$protocol" "$target" "$port_min" "$port_max" "$target_type"; then
        nsg_check_pass "$label"
    else
        if [[ "$critical" == "true" ]]; then
            nsg_check_fail "$label"
        else
            nsg_check_warn "$label"
        fi
        NSG_MISSING_RULES+=("$nsg_id|$nsg_name|$direction|$protocol|$target|$port_min|$port_max|$target_type|$label")
    fi
}

# Add a missing NSG rule (for --nsg-fix)
nsg_add_rule() {
    local nsg_id="$1"
    local nsg_name="$2"
    local direction="$3"
    local protocol="$4"
    local target="$5"
    local port_min="$6"
    local port_max="$7"
    local target_type="${8:-CIDR_BLOCK}"
    local description="${9:-Added by deploy-oke-node.sh --nsg-fix}"

    local target_field target_type_field
    if [[ "$direction" == "EGRESS" ]]; then
        target_field="destination"
        target_type_field="destinationType"
    else
        target_field="source"
        target_type_field="sourceType"
    fi

    # Build the rule JSON
    local rule_json
    if [[ "$protocol" == "6" || "$protocol" == "17" ]]; then
        local proto_key
        [[ "$protocol" == "6" ]] && proto_key="tcpOptions" || proto_key="udpOptions"
        rule_json="{
            \"direction\": \"$direction\",
            \"protocol\": \"$protocol\",
            \"$target_field\": \"$target\",
            \"$target_type_field\": \"$target_type\",
            \"isStateless\": false,
            \"description\": \"$description\",
            \"${proto_key}\": {
                \"destinationPortRange\": {
                    \"min\": $port_min,
                    \"max\": $port_max
                }
            }
        }"
    elif [[ "$protocol" == "1" ]]; then
        rule_json="{
            \"direction\": \"$direction\",
            \"protocol\": \"$protocol\",
            \"$target_field\": \"$target\",
            \"$target_type_field\": \"$target_type\",
            \"isStateless\": false,
            \"description\": \"$description\",
            \"icmpOptions\": {
                \"type\": $port_min,
                \"code\": $port_max
            }
        }"
    else
        rule_json="{
            \"direction\": \"$direction\",
            \"protocol\": \"all\",
            \"$target_field\": \"$target\",
            \"$target_type_field\": \"$target_type\",
            \"isStateless\": false,
            \"description\": \"$description\"
        }"
    fi

    local full_cmd="oci network nsg rules add \\
    --nsg-id \"$nsg_id\" \\
    --security-rules '[$rule_json]'"

    echo ""
    echo -e "    ${BOLD}Command to execute:${NC}"
    echo -e "    ${CYAN}$full_cmd${NC}"
    echo ""

    log_command "Add NSG rule to $nsg_name" "$full_cmd"

    if [[ "$NSG_FIX_MODE" != "true" ]]; then
        echo -e "    ${YELLOW}(Read-only mode — use --nsg-fix to execute)${NC}"
        return 0
    fi

    read -rp "    Execute this command? [y/N]: " confirm </dev/tty
    if [[ "${confirm,,}" != "y" ]]; then
        print_info "Skipped"
        return 0
    fi

    local result
    result=$(oci network nsg rules add \
        --nsg-id "$nsg_id" \
        --security-rules "[$rule_json]" 2>&1) || true
    log_command_result "$?" "$result"

    if echo "$result" | jq -e '.data' &>/dev/null; then
        print_success "Rule added to $nsg_name"
        # Invalidate cache
        unset "NSG_RULES_CACHE[$nsg_id]"
    else
        print_error "Failed to add rule: $result"
    fi
}

# Discover control plane and worker NSG details from cluster
nsg_discover_cluster_networking() {
    print_section "NSG Check: Discovering Cluster Networking"

    print_info "Fetching cluster details..."
    local cluster_json
    cluster_json=$(oci ce cluster get --cluster-id "$SELECTED_OKE_CLUSTER_ID" 2>&1) || true

    if ! echo "$cluster_json" | jq -e '.data' &>/dev/null; then
        print_error "Failed to fetch cluster details"
        exit 1
    fi

    #--- Cluster CNI type ---
    CLUSTER_CNI_TYPE=$(echo "$cluster_json" | jq -r '
        .data["cluster-pod-network-options"][0]["cni-type"] //
        .data.clusterPodNetworkOptions[0].cniType //
        "UNKNOWN"' 2>/dev/null) || CLUSTER_CNI_TYPE="UNKNOWN"
    
    local cni_display="$CLUSTER_CNI_TYPE"
    case "$CLUSTER_CNI_TYPE" in
        OCI_VCN_IP_NATIVE) cni_display="VCN-Native Pod Networking" ;;
        FLANNEL_OVERLAY)   cni_display="Flannel Overlay" ;;
    esac
    print_info "Cluster CNI: ${cni_display}"

    #--- Pod networking details from node pools (for native CNI validation) ---
    CLUSTER_POD_NSG_IDS=()
    CLUSTER_POD_SUBNET_IDS=()

    if [[ "$CLUSTER_CNI_TYPE" == "OCI_VCN_IP_NATIVE" ]]; then
        local np_output
        np_output=$(oci ce node-pool list \
            --compartment-id "$SELECTED_COMPARTMENT_ID" \
            --cluster-id "$SELECTED_OKE_CLUSTER_ID" \
            --all 2>/dev/null) || true

        if echo "$np_output" | jq -e '.data[0]' &>/dev/null; then
            # Extract pod NSG IDs from node pool pod network config
            while IFS= read -r nsg_id; do
                [[ -n "$nsg_id" && "$nsg_id" != "null" ]] && CLUSTER_POD_NSG_IDS+=("$nsg_id")
            done < <(echo "$np_output" | jq -r '
                [.data[]
                    | .["node-config-details"]["node-pool-pod-network-option-details"]["pod-nsg-ids"]? // []
                    | .[]
                ] | unique | .[]' 2>/dev/null) || true

            # Extract pod subnet IDs
            while IFS= read -r sub_id; do
                [[ -n "$sub_id" && "$sub_id" != "null" ]] && CLUSTER_POD_SUBNET_IDS+=("$sub_id")
            done < <(echo "$np_output" | jq -r '
                [.data[]
                    | .["node-config-details"]["node-pool-pod-network-option-details"]["pod-subnet-ids"]? // []
                    | .[]
                ] | unique | .[]' 2>/dev/null) || true

            if [[ ${#CLUSTER_POD_NSG_IDS[@]} -gt 0 ]]; then
                local pod_nsg_names=()
                for pid in "${CLUSTER_POD_NSG_IDS[@]}"; do
                    local pname
                    pname=$(oci network nsg get --nsg-id "$pid" \
                        --query 'data."display-name"' --raw-output 2>/dev/null) || pname="${pid:(-8)}"
                    pod_nsg_names+=("$pname")
                done
                print_info "Pod NSG(s): $(IFS=", "; echo "${pod_nsg_names[*]}")"
            fi

            if [[ ${#CLUSTER_POD_SUBNET_IDS[@]} -gt 0 ]]; then
                for psid in "${CLUSTER_POD_SUBNET_IDS[@]}"; do
                    local psname pscidr
                    psname=$(oci network subnet get --subnet-id "$psid" \
                        --query 'data."display-name"' --raw-output 2>/dev/null) || psname="unknown"
                    pscidr=$(oci network subnet get --subnet-id "$psid" \
                        --query 'data."cidr-block"' --raw-output 2>/dev/null) || pscidr="unknown"
                    print_info "Pod subnet: ${psname} (${pscidr})"
                done
            fi
        fi
    fi

    #--- Control plane endpoint config ---
    local endpoint_config
    endpoint_config=$(echo "$cluster_json" | jq '.data["endpoint-config"] // empty')

    if [[ -n "$endpoint_config" && "$endpoint_config" != "null" ]]; then
        NSG_CP_SUBNET_ID=$(echo "$endpoint_config" | jq -r '.["subnet-id"] // empty')

        local nsg_array
        nsg_array=$(echo "$endpoint_config" | jq -r '.["nsg-ids"] // []')
        if echo "$nsg_array" | jq -e '.[0]' &>/dev/null; then
            while IFS= read -r nsg_id; do
                NSG_CP_NSG_IDS+=("$nsg_id")
            done < <(echo "$nsg_array" | jq -r '.[]')
        fi
    fi

    # Endpoint IP
    local endpoints
    endpoints=$(echo "$cluster_json" | jq -r '.data.endpoints // empty')
    if [[ -n "$endpoints" && "$endpoints" != "null" ]]; then
        local private_ep
        private_ep=$(echo "$endpoints" | jq -r '.["private-endpoint"] // empty')
        if [[ -n "$private_ep" ]]; then
            NSG_CP_ENDPOINT_IP=$(echo "$private_ep" | sed 's/:.*//; s|https\?://||')
        fi
        if [[ -z "$NSG_CP_ENDPOINT_IP" ]]; then
            local public_ep
            public_ep=$(echo "$endpoints" | jq -r '.["public-endpoint"] // empty')
            [[ -n "$public_ep" ]] && NSG_CP_ENDPOINT_IP=$(echo "$public_ep" | sed 's/:.*//; s|https\?://||')
        fi
    fi

    # Resolve CP subnet CIDR
    if [[ -n "$NSG_CP_SUBNET_ID" ]]; then
        NSG_CP_SUBNET_CIDR=$(oci network subnet get \
            --subnet-id "$NSG_CP_SUBNET_ID" \
            --query 'data."cidr-block"' --raw-output 2>/dev/null) || true
        local cp_sub_name
        cp_sub_name=$(oci network subnet get \
            --subnet-id "$NSG_CP_SUBNET_ID" \
            --query 'data."display-name"' --raw-output 2>/dev/null) || true
        print_info "CP subnet: ${cp_sub_name:-unknown} ($NSG_CP_SUBNET_CIDR)"
    fi

    # Resolve CP NSG names
    if [[ ${#NSG_CP_NSG_IDS[@]} -gt 0 ]]; then
        for nsg_id in "${NSG_CP_NSG_IDS[@]}"; do
            local nname
            nname=$(oci network nsg get --nsg-id "$nsg_id" \
                --query 'data."display-name"' --raw-output 2>/dev/null) || nname="$nsg_id"
            NSG_CP_NSG_NAMES+=("$nname")
        done
        print_info "CP NSG(s): $(IFS=", "; echo "${NSG_CP_NSG_NAMES[*]}")"
    else
        print_warn "No control plane NSGs found on cluster endpoint config"
    fi

    print_info "CP endpoint IP: ${NSG_CP_ENDPOINT_IP:-unknown}"
}

# Select worker NSGs for validation (auto-detect from node pools or interactive)
nsg_select_worker_nsgs() {
    print_section "NSG Check: Select Worker NSGs"

    # Try auto-detect from node pools
    print_info "Checking node pools for worker NSG auto-detection..."
    local np_output
    np_output=$(oci ce node-pool list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --cluster-id "$SELECTED_OKE_CLUSTER_ID" \
        --all 2>/dev/null) || true

    local auto_worker_nsgs=()
    local auto_worker_subnet=""
    if echo "$np_output" | jq -e '.data[0]' &>/dev/null; then
        # NSGs from placement configs
        auto_worker_nsgs=($(echo "$np_output" | jq -r '
            [.data[].["node-config-details"]["placement-configs"[]
            | .["fault-domain-nsg-ids"]? // empty | .[]?] // [] | unique | .[]' 2>/dev/null)) || true

        # Fallback: node-pool level NSGs
        if [[ ${#auto_worker_nsgs[@]} -eq 0 ]]; then
            auto_worker_nsgs=($(echo "$np_output" | jq -r '
                [.data[].["node-config-details"]["nsg-ids"[]?] // [] | unique | .[]' 2>/dev/null)) || true
        fi

        # Worker subnet
        auto_worker_subnet=$(echo "$np_output" | jq -r '
            .data[0]["node-config-details"]["placement-configs"][0]["subnet-id"] // empty' 2>/dev/null) || true
    fi

    if [[ ${#auto_worker_nsgs[@]} -gt 0 ]]; then
        print_info "Auto-detected worker NSG(s) from node pools:"
        for nsg_id in "${auto_worker_nsgs[@]}"; do
            local nname
            nname=$(oci network nsg get --nsg-id "$nsg_id" \
                --query 'data."display-name"' --raw-output 2>/dev/null) || nname="$nsg_id"
            echo "    - $nname"
        done
        echo ""
        read -rp "  Use these worker NSGs? [Y/n]: " confirm </dev/tty
        if [[ "${confirm,,}" != "n" ]]; then
            NSG_WORKER_NSG_IDS=("${auto_worker_nsgs[@]}")
        fi
    fi

    # Manual selection if auto-detect didn't work or user declined
    if [[ ${#NSG_WORKER_NSG_IDS[@]} -eq 0 ]]; then
        print_info "Listing NSGs in compartment for manual selection..."
        local nsg_list
        nsg_list=$(oci network nsg list \
            --compartment-id "$SELECTED_COMPARTMENT_ID" \
            --lifecycle-state AVAILABLE \
            --all 2>/dev/null) || true

        local nsg_data
        nsg_data=$(echo "$nsg_list" | jq '[.data[] | {name: .["display-name"], id: .id}]' 2>/dev/null)

        if [[ -z "$nsg_data" ]] || ! echo "$nsg_data" | jq -e '.[0]' &>/dev/null; then
            print_error "No NSGs found in compartment"
            exit 1
        fi

        local nsg_count
        nsg_count=$(echo "$nsg_data" | jq 'length')

        echo ""
        printf "  ${BOLD}%-4s %-60s${NC}\n" "#" "NSG Name"
        printf "  %-4s %-60s\n" "----" "------------------------------------------------------------"

        local i=1
        while IFS= read -r nsg; do
            local name nsg_id
            name=$(echo "$nsg" | jq -r '.name')
            nsg_id=$(echo "$nsg" | jq -r '.id')
            local marker=""
            for cp_id in "${NSG_CP_NSG_IDS[@]}"; do
                [[ "$nsg_id" == "$cp_id" ]] && marker=" ${CYAN}[CP]${NC}"
            done
            printf "  %-4s %b\n" "$i)" "${name}${marker}"
            ((i++))
        done < <(echo "$nsg_data" | jq -c '.[]')

        echo ""
        echo -e "  Enter worker NSG number(s), comma-separated (e.g. 1,3):"
        read -rp "  Selection: " nsg_selections </dev/tty

        IFS=',' read -ra sel_array <<< "$nsg_selections"
        for sel in "${sel_array[@]}"; do
            sel=$(echo "$sel" | tr -d ' ')
            if [[ "$sel" -ge 1 && "$sel" -le "$nsg_count" ]] 2>/dev/null; then
                local wid
                wid=$(echo "$nsg_data" | jq -r ".[$((sel - 1))].id")
                NSG_WORKER_NSG_IDS+=("$wid")
            fi
        done
    fi

    # Resolve worker NSG names
    for nsg_id in "${NSG_WORKER_NSG_IDS[@]}"; do
        local nname
        nname=$(oci network nsg get --nsg-id "$nsg_id" \
            --query 'data."display-name"' --raw-output 2>/dev/null) || nname="$nsg_id"
        NSG_WORKER_NSG_NAMES+=("$nname")
    done

    if [[ ${#NSG_WORKER_NSG_IDS[@]} -eq 0 ]]; then
        print_error "No worker NSGs selected — cannot validate"
        exit 1
    fi

    print_success "Worker NSG(s): $(IFS=", "; echo "${NSG_WORKER_NSG_NAMES[*]}")"

    #--- Resolve worker subnet CIDR ---
    if [[ -n "$auto_worker_subnet" ]]; then
        NSG_WORKER_SUBNET_ID="$auto_worker_subnet"
    else
        # Get VCN from first worker NSG, list subnets
        local vcn_id
        vcn_id=$(oci network nsg get --nsg-id "${NSG_WORKER_NSG_IDS[0]}" \
            --query 'data."vcn-id"' --raw-output 2>/dev/null) || true
        if [[ -n "$vcn_id" ]]; then
            print_info "Listing subnets in VCN..."
            local subnet_list
            subnet_list=$(oci network subnet list \
                --compartment-id "$SELECTED_COMPARTMENT_ID" \
                --vcn-id "$vcn_id" \
                --all 2>/dev/null | jq '[.data[] | {name: .["display-name"], id: .id, cidr: .["cidr-block"]}]' 2>/dev/null)

            if echo "$subnet_list" | jq -e '.[0]' &>/dev/null; then
                local sub_count
                sub_count=$(echo "$subnet_list" | jq 'length')
                echo ""
                local i=1
                while IFS= read -r sub; do
                    local sname scidr
                    sname=$(echo "$sub" | jq -r '.name')
                    scidr=$(echo "$sub" | jq -r '.cidr')
                    printf "  %-4s %-40s %s\n" "$i)" "$sname" "$scidr"
                    ((i++))
                done < <(echo "$subnet_list" | jq -c '.[]')

                echo ""
                read -rp "  Select worker subnet [1-$sub_count]: " sub_sel </dev/tty
                sub_sel="${sub_sel:-1}"
                NSG_WORKER_SUBNET_ID=$(echo "$subnet_list" | jq -r ".[$((sub_sel - 1))].id")
            fi
        fi
    fi

    if [[ -n "$NSG_WORKER_SUBNET_ID" ]]; then
        NSG_WORKER_SUBNET_CIDR=$(oci network subnet get \
            --subnet-id "$NSG_WORKER_SUBNET_ID" \
            --query 'data."cidr-block"' --raw-output 2>/dev/null) || true
        local wk_sub_name
        wk_sub_name=$(oci network subnet get \
            --subnet-id "$NSG_WORKER_SUBNET_ID" \
            --query 'data."display-name"' --raw-output 2>/dev/null) || true
        print_info "Worker subnet: ${wk_sub_name:-unknown} ($NSG_WORKER_SUBNET_CIDR)"
    fi
}

# Run all validation checks
nsg_validate_rules() {
    print_header "NSG Rule Validation"

    local worker_target="${NSG_WORKER_SUBNET_CIDR:-0.0.0.0/0}"
    local cp_target="${NSG_CP_SUBNET_CIDR:-0.0.0.0/0}"

    if [[ "$worker_target" == "0.0.0.0/0" ]]; then
        print_warn "Worker subnet CIDR unknown — checks will be less specific"
    fi
    if [[ "$cp_target" == "0.0.0.0/0" ]]; then
        print_warn "CP subnet CIDR unknown — checks will be less specific"
    fi

    #=== CONTROL PLANE NSG CHECKS ===
    for idx in "${!NSG_CP_NSG_IDS[@]}"; do
        local cp_nsg_id="${NSG_CP_NSG_IDS[$idx]}"
        local cp_nsg_name="${NSG_CP_NSG_NAMES[$idx]}"

        print_section "Control Plane NSG: $cp_nsg_name"
        print_info "NSG ID: $cp_nsg_id"
        echo ""

        echo -e "  ${BOLD}Ingress (traffic INTO control plane):${NC}"

        nsg_run_check \
            "Ingress TCP/6443 from workers ($worker_target) — K8s API" \
            "$cp_nsg_id" "$cp_nsg_name" "INGRESS" "6" "$worker_target" 6443 6443

        nsg_run_check \
            "Ingress TCP/12250 from workers ($worker_target) — Node Bootstrap ⚡" \
            "$cp_nsg_id" "$cp_nsg_name" "INGRESS" "6" "$worker_target" 12250 12250

        nsg_run_check \
            "Ingress ICMP type 3/4 from workers — Path MTU Discovery" \
            "$cp_nsg_id" "$cp_nsg_name" "INGRESS" "1" "$worker_target" 3 4 "CIDR_BLOCK" "false"

        echo ""
        echo -e "  ${BOLD}Egress (traffic FROM control plane):${NC}"

        nsg_run_check \
            "Egress TCP/10250 to workers ($worker_target) — Kubelet" \
            "$cp_nsg_id" "$cp_nsg_name" "EGRESS" "6" "$worker_target" 10250 10250

        nsg_run_check \
            "Egress ICMP type 3/4 to workers — Path MTU Discovery" \
            "$cp_nsg_id" "$cp_nsg_name" "EGRESS" "1" "$worker_target" 3 4 "CIDR_BLOCK" "false"

        # NSG-to-NSG cross-references
        echo ""
        echo -e "  ${BOLD}NSG-to-NSG Cross-references:${NC}"
        for w_idx in "${!NSG_WORKER_NSG_IDS[@]}"; do
            local w_nsg_id="${NSG_WORKER_NSG_IDS[$w_idx]}"
            local w_nsg_name="${NSG_WORKER_NSG_NAMES[$w_idx]}"
            nsg_run_check \
                "Egress to Worker NSG ($w_nsg_name) TCP/10250 — Kubelet via NSG ref" \
                "$cp_nsg_id" "$cp_nsg_name" "EGRESS" "6" "$w_nsg_id" 10250 10250 "NETWORK_SECURITY_GROUP" "false"
        done
    done

    #=== WORKER NSG CHECKS ===
    for idx in "${!NSG_WORKER_NSG_IDS[@]}"; do
        local w_nsg_id="${NSG_WORKER_NSG_IDS[$idx]}"
        local w_nsg_name="${NSG_WORKER_NSG_NAMES[$idx]}"

        print_section "Worker NSG: $w_nsg_name"
        print_info "NSG ID: $w_nsg_id"
        echo ""

        echo -e "  ${BOLD}Egress (traffic FROM workers):${NC}"

        nsg_run_check \
            "Egress TCP/6443 to CP ($cp_target) — K8s API" \
            "$w_nsg_id" "$w_nsg_name" "EGRESS" "6" "$cp_target" 6443 6443

        nsg_run_check \
            "Egress TCP/12250 to CP ($cp_target) — Node Bootstrap ⚡" \
            "$w_nsg_id" "$w_nsg_name" "EGRESS" "6" "$cp_target" 12250 12250

        nsg_run_check \
            "Egress TCP/443 to 0.0.0.0/0 — OCI Services / OCIR" \
            "$w_nsg_id" "$w_nsg_name" "EGRESS" "6" "0.0.0.0/0" 443 443 "CIDR_BLOCK" "false"

        nsg_run_check \
            "Egress All to workers ($worker_target) — Pod-to-Pod" \
            "$w_nsg_id" "$w_nsg_name" "EGRESS" "all" "$worker_target" 0 0 "CIDR_BLOCK" "false"

        nsg_run_check \
            "Egress ICMP type 3/4 to CP — Path MTU Discovery" \
            "$w_nsg_id" "$w_nsg_name" "EGRESS" "1" "$cp_target" 3 4 "CIDR_BLOCK" "false"

        echo ""
        echo -e "  ${BOLD}Ingress (traffic INTO workers):${NC}"

        nsg_run_check \
            "Ingress TCP/10250 from CP ($cp_target) — Kubelet Health" \
            "$w_nsg_id" "$w_nsg_name" "INGRESS" "6" "$cp_target" 10250 10250

        nsg_run_check \
            "Ingress All from workers ($worker_target) — Pod-to-Pod" \
            "$w_nsg_id" "$w_nsg_name" "INGRESS" "all" "$worker_target" 0 0 "CIDR_BLOCK" "false"

        nsg_run_check \
            "Ingress TCP/30000-32767 — NodePort Services" \
            "$w_nsg_id" "$w_nsg_name" "INGRESS" "6" "0.0.0.0/0" 30000 32767 "CIDR_BLOCK" "false"

        nsg_run_check \
            "Ingress ICMP type 3/4 from CP — Path MTU Discovery" \
            "$w_nsg_id" "$w_nsg_name" "INGRESS" "1" "$cp_target" 3 4 "CIDR_BLOCK" "false"

        # NSG-to-NSG cross-references
        echo ""
        echo -e "  ${BOLD}NSG-to-NSG Cross-references:${NC}"
        for cp_idx in "${!NSG_CP_NSG_IDS[@]}"; do
            local c_nsg_id="${NSG_CP_NSG_IDS[$cp_idx]}"
            local c_nsg_name="${NSG_CP_NSG_NAMES[$cp_idx]}"
            nsg_run_check \
                "Egress to CP NSG ($c_nsg_name) TCP/6443 — API via NSG ref" \
                "$w_nsg_id" "$w_nsg_name" "EGRESS" "6" "$c_nsg_id" 6443 6443 "NETWORK_SECURITY_GROUP" "false"
            nsg_run_check \
                "Egress to CP NSG ($c_nsg_name) TCP/12250 — Bootstrap via NSG ref" \
                "$w_nsg_id" "$w_nsg_name" "EGRESS" "6" "$c_nsg_id" 12250 12250 "NETWORK_SECURITY_GROUP" "false"
        done
    done
}

# Dump all raw rules for debugging
nsg_dump_rules() {
    print_header "Full NSG Rule Dump"

    local format_rule='.[] | "\(.direction)  \(if .protocol == "6" then "TCP" elif .protocol == "17" then "UDP" elif .protocol == "1" then "ICMP" elif .protocol == "all" then "ALL" else .protocol end)  \(if .direction == "EGRESS" then .destination else .source end)  \(if .["tcp-options"]["destination-port-range"] then "\(.["tcp-options"]["destination-port-range"].min)-\(.["tcp-options"]["destination-port-range"].max)" elif .["icmp-options"] then "type=\(.["icmp-options"].type) code=\(.["icmp-options"].code // "any")" else "all-ports" end)  \(.description // "-")"'

    for idx in "${!NSG_CP_NSG_IDS[@]}"; do
        local nsg_id="${NSG_CP_NSG_IDS[$idx]}"
        local nsg_name="${NSG_CP_NSG_NAMES[$idx]}"
        echo -e "\n${BOLD}CP NSG: $nsg_name${NC}"
        echo -e "${CYAN}$nsg_id${NC}\n"

        printf "  ${BOLD}%-8s %-6s %-42s %-18s %s${NC}\n" "DIR" "PROTO" "SOURCE/DEST" "PORTS" "DESCRIPTION"
        printf "  %-8s %-6s %-42s %-18s %s\n" "--------" "------" "------------------------------------------" "------------------" "--------------------"
        local rules
        rules=$(nsg_fetch_rules "$nsg_id")
        echo "$rules" | jq -r "$format_rule" 2>/dev/null | while IFS= read -r line; do
            printf "  %s\n" "$line"
        done
        echo ""
    done

    for idx in "${!NSG_WORKER_NSG_IDS[@]}"; do
        local nsg_id="${NSG_WORKER_NSG_IDS[$idx]}"
        local nsg_name="${NSG_WORKER_NSG_NAMES[$idx]}"
        echo -e "\n${BOLD}Worker NSG: $nsg_name${NC}"
        echo -e "${CYAN}$nsg_id${NC}\n"

        printf "  ${BOLD}%-8s %-6s %-42s %-18s %s${NC}\n" "DIR" "PROTO" "SOURCE/DEST" "PORTS" "DESCRIPTION"
        printf "  %-8s %-6s %-42s %-18s %s\n" "--------" "------" "------------------------------------------" "------------------" "--------------------"
        local rules
        rules=$(nsg_fetch_rules "$nsg_id")
        echo "$rules" | jq -r "$format_rule" 2>/dev/null | while IFS= read -r line; do
            printf "  %s\n" "$line"
        done
        echo ""
    done
}

# Print summary and offer fixes
nsg_print_summary() {
    print_header "NSG Validation Summary"

    echo -e "  ${BOLD}Total checks:${NC}  $NSG_TOTAL_CHECKS"
    echo -e "  ${GREEN}Passed:${NC}        $NSG_PASSED_CHECKS"
    echo -e "  ${RED}Failed:${NC}        $NSG_FAILED_CHECKS"
    echo -e "  ${YELLOW}Warnings:${NC}      $NSG_WARNED_CHECKS"
    echo ""

    if [[ $NSG_FAILED_CHECKS -eq 0 && $NSG_WARNED_CHECKS -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}✅ All checks passed! NSG rules look good.${NC}"
        return 0
    fi

    if [[ $NSG_FAILED_CHECKS -gt 0 ]]; then
        echo -e "  ${RED}${BOLD}❌ $NSG_FAILED_CHECKS critical rule(s) missing!${NC}"
        echo -e "  ${RED}These must be fixed for OKE nodes to bootstrap and communicate.${NC}"
    fi

    if [[ ${#NSG_MISSING_RULES[@]} -gt 0 ]]; then
        print_section "Missing Rules — Fix Commands"
        echo ""

        local i=1
        for rule_data in "${NSG_MISSING_RULES[@]}"; do
            IFS='|' read -r nsg_id nsg_name direction protocol target port_min port_max target_type label <<< "$rule_data"

            echo -e "  ${BOLD}$i) $label${NC}"
            echo -e "     NSG: $nsg_name"
            nsg_add_rule "$nsg_id" "$nsg_name" "$direction" "$protocol" "$target" "$port_min" "$port_max" "$target_type" "$label"
            ((i++))
        done
    fi
}

# Main entry point for NSG validation mode
nsg_check_main() {
    print_header "OKE NSG Rule Validator"

    # Initialize log
    LOG_FILE="${LOG_FILE:-./deploy-oke-node.log}"
    log_message "INFO" "NSG validation started"

    # Prerequisites
    check_prerequisites

    # Reuse existing select_compartment
    select_compartment

    # Lightweight cluster selection (we only need cluster ID + name, no kubeconfig)
    print_section "NSG Check: Select OKE Cluster"
    print_info "Fetching OKE clusters..."

    local raw_output
    raw_output=$(oci ce cluster list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --lifecycle-state ACTIVE \
        --all 2>&1) || true

    local list_json
    list_json=$(echo "$raw_output" | jq '[.data[] | {name: .name, id: .id, version: .["kubernetes-version"]}]' 2>/dev/null)

    if [[ -z "$list_json" ]] || ! echo "$list_json" | jq -e '.[0]' &>/dev/null; then
        print_error "No active OKE clusters found in compartment"
        exit 1
    fi

    local count
    count=$(echo "$list_json" | jq 'length')
    print_info "Found $count OKE cluster(s)"

    echo ""
    printf "  ${BOLD}%-4s %-45s %-12s${NC}\n" "#" "Cluster Name" "Version"
    printf "  %-4s %-45s %-12s\n" "----" "---------------------------------------------" "------------"

    local i=1
    while IFS= read -r cluster; do
        local name version
        name=$(echo "$cluster" | jq -r '.name')
        version=$(echo "$cluster" | jq -r '.version')
        printf "  %-4s %-45s %-12s\n" "$i)" "$name" "$version"
        ((i++))
    done < <(echo "$list_json" | jq -c '.[]')

    echo ""
    read -rp "  Select cluster [1-$count]: " selection </dev/tty
    selection="${selection:-1}"

    local selected
    selected=$(echo "$list_json" | jq -c ".[$((selection - 1))]")
    SELECTED_OKE_CLUSTER_ID=$(echo "$selected" | jq -r '.id')
    SELECTED_OKE_CLUSTER_NAME=$(echo "$selected" | jq -r '.name')
    print_success "Cluster: $SELECTED_OKE_CLUSTER_NAME"

    # Discover networking
    nsg_discover_cluster_networking
    nsg_select_worker_nsgs

    # Run validation
    nsg_validate_rules

    # Optional dump
    if [[ "$NSG_DUMP_MODE" == "true" ]]; then
        nsg_dump_rules
    fi

    # Summary + fix
    nsg_print_summary

    echo ""
    print_info "Log file: $LOG_FILE"
}

#-------------------------------------------------------------------------------
# CNI Compatibility Check: Validate instance config against cluster CNI type
#
# Compares the cluster's CNI (Native vs Flannel) against the instance
# configuration's VNIC settings (NSGs, subnets) and flags mismatches.
# Called from preflight_nsg_api_check after cluster networking is discovered.
#-------------------------------------------------------------------------------
preflight_cni_check() {
    if [[ -z "${CLUSTER_CNI_TYPE:-}" || "$CLUSTER_CNI_TYPE" == "UNKNOWN" ]]; then
        print_warn "Could not determine cluster CNI type — skipping CNI compatibility check"
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}CNI Compatibility Check:${NC}"
    echo ""

    local cni_issues=0
    local cni_warnings=0

    case "$CLUSTER_CNI_TYPE" in
    OCI_VCN_IP_NATIVE)
        echo -e "  Cluster CNI: ${CYAN}VCN-Native Pod Networking${NC}"
        echo -e "  Instance Config NSG(s): ${SELECTED_NSG_NAMES:-None}"
        echo ""

        #---------------------------------------------------------------
        # Check 1: Pod NSG must be in instance config nsgIds
        #---------------------------------------------------------------
        if [[ ${#CLUSTER_POD_NSG_IDS[@]} -eq 0 ]]; then
            echo -e "    ${YELLOW}⚠️${NC}  No pod NSGs found in node pool config — cannot validate pod NSG assignment"
            cni_warnings=$((cni_warnings + 1))
        else
            local pod_nsg_missing=()
            for pod_nsg_id in "${CLUSTER_POD_NSG_IDS[@]}"; do
                local found=false
                for config_nsg_id in "${SELECTED_NSG_IDS[@]}"; do
                    if [[ "$config_nsg_id" == "$pod_nsg_id" ]]; then
                        found=true
                        break
                    fi
                done
                if [[ "$found" == "false" ]]; then
                    # Resolve pod NSG name for display
                    local pod_nsg_name
                    pod_nsg_name=$(oci network nsg get --nsg-id "$pod_nsg_id" \
                        --query 'data."display-name"' --raw-output 2>/dev/null) || pod_nsg_name="${pod_nsg_id:(-12)}"
                    pod_nsg_missing+=("$pod_nsg_name ($pod_nsg_id)")
                fi
            done

            if [[ ${#pod_nsg_missing[@]} -eq 0 ]]; then
                echo -e "    ${GREEN}✅${NC} Pod NSG(s) present in instance config VNIC"
            else
                for missing in "${pod_nsg_missing[@]}"; do
                    echo -e "    ${RED}❌ CRITICAL${NC}  Pod NSG missing from instance config: ${RED}${missing}${NC}"
                    echo -e "       VCN-Native requires the pod NSG in createVnicDetails.nsgIds."
                    echo -e "       Without it, the VNIC won't receive pod traffic and bootstrap will fail."
                    cni_issues=$((cni_issues + 1))
                done
            fi
        fi

        #---------------------------------------------------------------
        # Check 2: Instance config should have at least 2 NSGs (workers + pods)
        #---------------------------------------------------------------
        local config_nsg_count=${#SELECTED_NSG_IDS[@]}
        if [[ $config_nsg_count -eq 0 ]]; then
            echo -e "    ${RED}❌ CRITICAL${NC}  Instance config has NO NSGs — VCN-Native requires workers + pods NSGs"
            cni_issues=$((cni_issues + 1))
        elif [[ $config_nsg_count -eq 1 ]]; then
            echo -e "    ${YELLOW}⚠️${NC}  Instance config has only 1 NSG — VCN-Native typically requires workers NSG + pods NSG"
            echo -e "       This is a known OCI issue: instance configs created from node pools"
            echo -e "       sometimes drop the pods NSG. Verify the attached NSG covers pod traffic."
            cni_warnings=$((cni_warnings + 1))
        else
            echo -e "    ${GREEN}✅${NC} Instance config has $config_nsg_count NSGs (workers + pods expected)"
        fi

        #---------------------------------------------------------------
        # Check 3: Pod subnet must exist (cluster-level sanity)
        #---------------------------------------------------------------
        if [[ ${#CLUSTER_POD_SUBNET_IDS[@]} -eq 0 ]]; then
            echo -e "    ${YELLOW}⚠️${NC}  No pod subnets found in node pool config"
            echo "       VCN-Native clusters should have a dedicated pod subnet."
            cni_warnings=$((cni_warnings + 1))
        else
            echo -e "    ${GREEN}✅${NC} Pod subnet(s) configured in node pool (${#CLUSTER_POD_SUBNET_IDS[@]} found)"
        fi
        ;;

    FLANNEL_OVERLAY)
        echo -e "  Cluster CNI: ${CYAN}Flannel Overlay${NC}"
        echo -e "  Instance Config NSG(s): ${SELECTED_NSG_NAMES:-None}"
        echo ""

        #---------------------------------------------------------------
        # Check 1: Flannel doesn't need pod NSGs
        #---------------------------------------------------------------
        if [[ ${#CLUSTER_POD_NSG_IDS[@]} -gt 0 ]]; then
            echo -e "    ${YELLOW}⚠️${NC}  Pod NSGs found in node pool config but cluster uses Flannel"
            echo "       Pod NSGs are not needed for Flannel — verify this is intentional."
            cni_warnings=$((cni_warnings + 1))
        fi

        #---------------------------------------------------------------
        # Check 2: Flannel typically needs just workers NSG
        #---------------------------------------------------------------
        local config_nsg_count=${#SELECTED_NSG_IDS[@]}
        if [[ $config_nsg_count -eq 0 ]]; then
            echo -e "    ${YELLOW}⚠️${NC}  Instance config has no NSGs — relying on security lists only"
            cni_warnings=$((cni_warnings + 1))
        elif [[ $config_nsg_count -eq 1 ]]; then
            echo -e "    ${GREEN}✅${NC} Instance config has 1 NSG (expected for Flannel)"
        else
            echo -e "    ${GREEN}✅${NC} Instance config has $config_nsg_count NSGs"
        fi

        #---------------------------------------------------------------
        # Check 3: Flannel needs VXLAN port 8472
        #---------------------------------------------------------------
        echo -e "    ${CYAN}ℹ️${NC}  Flannel requires UDP/8472 (VXLAN) between worker nodes"
        echo "       Ensure this is allowed in worker NSG or security lists."
        ;;

    *)
        echo -e "    ${YELLOW}⚠️${NC}  Unknown CNI type: $CLUSTER_CNI_TYPE"
        cni_warnings=$((cni_warnings + 1))
        ;;
    esac

    #--- Summary ---
    echo ""
    if [[ $cni_issues -gt 0 ]]; then
        echo -e "  ${RED}${BOLD}❌ $cni_issues CNI compatibility issue(s) found!${NC}"
        echo ""
        log_message "WARN" "CNI check ($CLUSTER_CNI_TYPE): $cni_issues critical issues, $cni_warnings warnings"

        # Count these toward the overall preflight failures
        NSG_TOTAL_CHECKS=$((NSG_TOTAL_CHECKS + cni_issues + cni_warnings))
        NSG_FAILED_CHECKS=$((NSG_FAILED_CHECKS + cni_issues))
        NSG_WARNED_CHECKS=$((NSG_WARNED_CHECKS + cni_warnings))
    elif [[ $cni_warnings -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠️  $cni_warnings CNI warning(s) — review above${NC}"
        echo ""
        log_message "INFO" "CNI check ($CLUSTER_CNI_TYPE): passed with $cni_warnings warnings"
        NSG_TOTAL_CHECKS=$((NSG_TOTAL_CHECKS + cni_warnings))
        NSG_WARNED_CHECKS=$((NSG_WARNED_CHECKS + cni_warnings))
    else
        echo -e "  ${GREEN}✅ CNI compatibility checks passed ($CLUSTER_CNI_TYPE)${NC}"
        echo ""
        log_message "INFO" "CNI check ($CLUSTER_CNI_TYPE): all checks passed"
    fi
}

#-------------------------------------------------------------------------------
# Pre-Flight Check: API Server + NSG Rule Validation (Create-New Flow)
#
# Runs automatically in the create-new flow after all selections are made.
# Bridges SELECTED_ globals to NSG_ globals and reuses the NSG validation engine.
#-------------------------------------------------------------------------------
preflight_nsg_api_check() {
    print_section "Pre-Flight: API Server & NSG Validation"

    # Guard: need cluster + API server to proceed
    if [[ -z "${SELECTED_OKE_CLUSTER_ID:-}" ]]; then
        print_warn "No OKE cluster selected — skipping pre-flight NSG check"
        return 0
    fi
    if [[ -z "${SELECTED_API_SERVER_IP:-}" ]]; then
        print_warn "No API server IP — skipping pre-flight connectivity check"
        return 0
    fi

    local preflight_failed=false

    #--- Part 1: API Server Connectivity ---
    echo -e "  ${BOLD}API Server Connectivity:${NC}"
    echo ""
    print_info "Control plane endpoint: ${SELECTED_API_SERVER_IP}:${SELECTED_API_SERVER_PORT:-6443}"

    # Only run connectivity tests if we're on an OCI instance (IMDS available)
    local imds_result
    imds_result=$(curl -s --connect-timeout 2 -H "Authorization: Bearer Oracle" \
        "http://169.254.169.254/opc/v2/instance/" 2>/dev/null) || true

    if [[ -n "$imds_result" && "$imds_result" != *"404"* ]]; then
        # We're on an OCI instance — test connectivity
        print_info "Running from OCI instance — testing API server connectivity..."

        # Test 6443
        if nc -zvw5 "$SELECTED_API_SERVER_IP" "${SELECTED_API_SERVER_PORT:-6443}" 2>&1 | grep -qi "succeeded\|connected\|open"; then
            echo -e "  ${GREEN}✅${NC} TCP/${SELECTED_API_SERVER_PORT:-6443} (K8s API) — reachable"
        else
            echo -e "  ${YELLOW}⚠️${NC}  TCP/${SELECTED_API_SERVER_PORT:-6443} (K8s API) — not reachable from this node"
            echo "     (New worker node may have different routing)"
        fi

        # Test 12250
        if nc -zvw5 "$SELECTED_API_SERVER_IP" 12250 2>&1 | grep -qi "succeeded\|connected\|open"; then
            echo -e "  ${GREEN}✅${NC} TCP/12250 (Bootstrap) — reachable"
        else
            echo -e "  ${YELLOW}⚠️${NC}  TCP/12250 (Bootstrap) — not reachable from this node"
            echo "     (Does not necessarily mean the worker will fail — depends on worker NSG rules)"
        fi
    else
        print_info "Not running on OCI instance (IMDS unavailable) — skipping connectivity test"
        print_info "NSG rule validation will still verify the rules are in place"
    fi

    echo ""

    #--- Part 2: Bridge SELECTED_ → NSG_ variables ---
    # Reset NSG validation state from any prior --nsg-check run
    NSG_CP_NSG_IDS=()
    NSG_CP_NSG_NAMES=()
    NSG_CP_SUBNET_ID=""
    NSG_CP_SUBNET_CIDR=""
    NSG_CP_ENDPOINT_IP=""
    NSG_WORKER_NSG_IDS=()
    NSG_WORKER_NSG_NAMES=()
    NSG_WORKER_SUBNET_ID=""
    NSG_WORKER_SUBNET_CIDR=""
    NSG_TOTAL_CHECKS=0
    NSG_PASSED_CHECKS=0
    NSG_FAILED_CHECKS=0
    NSG_WARNED_CHECKS=0
    NSG_MISSING_RULES=()
    CLUSTER_CNI_TYPE=""
    CLUSTER_POD_NSG_IDS=()
    CLUSTER_POD_SUBNET_IDS=()
    # Clear the rules cache (safe for associative arrays under set -e)
    for _cache_key in "${!NSG_RULES_CACHE[@]}"; do
        unset "NSG_RULES_CACHE[$_cache_key]"
    done

    # Discover CP networking from cluster
    print_info "Discovering cluster networking..."
    nsg_discover_cluster_networking

    # Map worker NSGs from create-new selections
    if [[ ${#SELECTED_NSG_IDS[@]} -eq 0 ]]; then
        print_warn "No worker NSGs selected — cannot validate NSG rules"
        print_warn "Instance will rely solely on subnet security lists"
        return 0
    fi

    NSG_WORKER_NSG_IDS=("${SELECTED_NSG_IDS[@]}")

    # Resolve worker NSG names
    for nsg_id in "${NSG_WORKER_NSG_IDS[@]}"; do
        local nname
        nname=$(oci network nsg get --nsg-id "$nsg_id" \
            --query 'data."display-name"' --raw-output 2>/dev/null) || nname="$nsg_id"
        NSG_WORKER_NSG_NAMES+=("$nname")
    done
    print_info "Worker NSG(s): $(IFS=", "; echo "${NSG_WORKER_NSG_NAMES[*]}")"

    # Resolve worker subnet CIDR
    if [[ -n "${SELECTED_SUBNET_ID:-}" ]]; then
        NSG_WORKER_SUBNET_ID="$SELECTED_SUBNET_ID"
        NSG_WORKER_SUBNET_CIDR=$(oci network subnet get \
            --subnet-id "$SELECTED_SUBNET_ID" \
            --query 'data."cidr-block"' --raw-output 2>/dev/null) || true
        print_info "Worker subnet CIDR: ${NSG_WORKER_SUBNET_CIDR:-unknown}"
    fi

    #--- Part 2b: CNI Compatibility Check ---
    preflight_cni_check

    #--- Part 3: Run NSG validation ---
    # Enable fix mode so missing rules can be added
    local saved_fix_mode="$NSG_FIX_MODE"
    NSG_FIX_MODE=true

    nsg_validate_rules

    #--- Part 4: Summary + Decision ---
    echo ""
    echo -e "  ${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${BOLD}  Pre-Flight NSG Summary${NC}"
    echo -e "  ${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    local cni_label="$CLUSTER_CNI_TYPE"
    case "$CLUSTER_CNI_TYPE" in
        OCI_VCN_IP_NATIVE) cni_label="VCN-Native Pod Networking" ;;
        FLANNEL_OVERLAY)   cni_label="Flannel Overlay" ;;
    esac
    echo -e "  ${BOLD}Cluster CNI:${NC}   $cni_label"
    echo -e "  ${BOLD}Total checks:${NC}  $NSG_TOTAL_CHECKS"
    echo -e "  ${GREEN}Passed:${NC}        $NSG_PASSED_CHECKS"
    echo -e "  ${RED}Failed:${NC}        $NSG_FAILED_CHECKS"
    echo -e "  ${YELLOW}Warnings:${NC}      $NSG_WARNED_CHECKS"
    echo ""

    if [[ $NSG_FAILED_CHECKS -eq 0 && $NSG_WARNED_CHECKS -eq 0 ]]; then
        echo -e "  ${GREEN}${BOLD}✅ All NSG checks passed! Safe to proceed.${NC}"
        log_message "INFO" "Pre-flight NSG check: all $NSG_TOTAL_CHECKS checks passed"
        NSG_FIX_MODE="$saved_fix_mode"
        return 0
    fi

    if [[ $NSG_FAILED_CHECKS -gt 0 ]]; then
        echo -e "  ${RED}${BOLD}❌ $NSG_FAILED_CHECKS critical rule(s) missing!${NC}"
        echo -e "  ${RED}The new node will NOT bootstrap correctly without these rules.${NC}"
        preflight_failed=true
    fi

    if [[ $NSG_WARNED_CHECKS -gt 0 && $NSG_FAILED_CHECKS -eq 0 ]]; then
        echo -e "  ${YELLOW}⚠️  $NSG_WARNED_CHECKS non-critical rule(s) missing (warnings only)${NC}"
    fi

    #--- Part 5: Offer to fix missing rules ---
    if [[ ${#NSG_MISSING_RULES[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}Missing Rules:${NC}"
        echo ""

        local i=1
        for rule_data in "${NSG_MISSING_RULES[@]}"; do
            IFS='|' read -r nsg_id nsg_name direction protocol target port_min port_max target_type label <<< "$rule_data"
            echo -e "    ${RED}$i)${NC} $label"
            echo -e "       NSG: $nsg_name | $direction | proto=$protocol | port=$port_min-$port_max"
            ((i++))
        done

        echo ""
        echo -e "  ${BOLD}Options:${NC}"
        echo -e "    ${BOLD}[1]${NC} Fix all missing rules now, then continue deployment"
        echo -e "    ${BOLD}[2]${NC} Continue deployment anyway (node may fail to bootstrap)"
        echo -e "    ${BOLD}[3]${NC} Abort deployment"
        echo ""

        local fix_choice
        if [[ "$AUTO_APPROVE" == "true" && "$preflight_failed" == "true" ]]; then
            print_info "[AUTO-APPROVE] Auto-fixing critical missing rules..."
            fix_choice="1"
        else
            read -rp "  Selection [1-3]: " fix_choice </dev/tty
        fi

        case "${fix_choice:-2}" in
            1)
                echo ""
                print_info "Adding missing NSG rules..."
                log_step "PRE-FLIGHT NSG FIX"
                log_message "INFO" "Adding ${#NSG_MISSING_RULES[@]} missing NSG rules"

                for rule_data in "${NSG_MISSING_RULES[@]}"; do
                    IFS='|' read -r nsg_id nsg_name direction protocol target port_min port_max target_type label <<< "$rule_data"
                    echo ""
                    echo -e "  ${BOLD}Adding: $label${NC}"
                    nsg_add_rule "$nsg_id" "$nsg_name" "$direction" "$protocol" "$target" "$port_min" "$port_max" "$target_type" "$label"
                done

                echo ""
                print_success "All missing rules added. Proceeding with deployment."
                log_message "INFO" "Pre-flight NSG fix complete — all rules added"
                ;;
            2)
                echo ""
                if [[ "$preflight_failed" == "true" ]]; then
                    print_warn "Continuing with missing CRITICAL rules — node bootstrap will likely fail!"
                    log_message "WARN" "User chose to continue with $NSG_FAILED_CHECKS critical missing rules"
                else
                    print_info "Continuing with non-critical warnings..."
                    log_message "INFO" "User chose to continue with $NSG_WARNED_CHECKS warnings"
                fi
                ;;
            3)
                echo ""
                print_info "Deployment aborted. Fix NSG rules and re-run."
                log_message "INFO" "Deployment aborted by user due to NSG pre-flight failures"
                exit 0
                ;;
            *)
                print_info "Invalid selection, continuing deployment..."
                ;;
        esac
    fi

    NSG_FIX_MODE="$saved_fix_mode"
}

#-------------------------------------------------------------------------------
# Validate Cloud-Init Function
#-------------------------------------------------------------------------------

validate_cloud_init() {
    print_header "Cloud-Init Validation"
    
    local cloud_init_file="${1:-${CLOUD_INIT_FILE:-./cloud-init.yml}}"
    
    if [[ ! -f "$cloud_init_file" ]]; then
        print_error "Cloud-init file not found: $cloud_init_file"
        exit 1
    fi
    
    print_info "Validating: $cloud_init_file"
    
    # Check if cloud-init is available
    if ! command -v cloud-init &>/dev/null; then
        print_error "cloud-init is not installed"
        print_info "Install with: sudo apt install cloud-init"
        exit 1
    fi
    
    # Check for unsubstituted variables
    echo ""
    print_info "Checking for unsubstituted variables..."
    local unsubstituted
    unsubstituted=$(grep -o "__[A-Z_]*__" "$cloud_init_file" 2>/dev/null | sort -u || true)
    
    if [[ -n "$unsubstituted" ]]; then
        print_warn "Found unsubstituted variables (these will be replaced at deployment):"
        echo "$unsubstituted" | while read -r var; do
            echo "  - $var"
        done
        echo ""
    else
        print_success "No unsubstituted variables found"
    fi
    
    # Validate YAML syntax first
    print_info "Checking YAML syntax..."
    if command -v python3 &>/dev/null; then
        if python3 -c "import yaml; yaml.safe_load(open('$cloud_init_file'))" 2>&1; then
            print_success "YAML syntax is valid"
        else
            print_error "YAML syntax error"
            exit 1
        fi
    fi
    
    # Validate cloud-init schema
    echo ""
    print_info "Validating cloud-init schema..."
    local validation_output
    local validation_exit_code
    
    validation_output=$(sudo cloud-init schema --config-file "$cloud_init_file" 2>&1) || validation_exit_code=$?
    
    if [[ -z "$validation_exit_code" || "$validation_exit_code" -eq 0 ]]; then
        print_success "Cloud-init schema validation passed"
        echo ""
        echo "$validation_output"
    else
        print_error "Cloud-init schema validation failed"
        echo ""
        echo "$validation_output"
        exit 1
    fi
    
    # Show cloud-init file summary
    echo ""
    print_section "Cloud-Init Summary"
    
    # Count modules/sections
    local packages_count=$(grep -c "^  - " "$cloud_init_file" 2>/dev/null | head -1 || echo "0")
    local write_files_count=$(grep -c "path:" "$cloud_init_file" 2>/dev/null || echo "0")
    local runcmd_lines=$(grep -A 1000 "^runcmd:" "$cloud_init_file" 2>/dev/null | grep -c "^  - " || echo "0")
    
    echo "  File: $cloud_init_file"
    echo "  Size: $(wc -c < "$cloud_init_file") bytes, $(wc -l < "$cloud_init_file") lines"
    echo "  Packages: ~$packages_count"
    echo "  Write files: $write_files_count"
    echo "  Run commands: ~$runcmd_lines"
    
    # Check for specific OKE requirements
    echo ""
    print_info "Checking OKE requirements..."
    
    local has_oke_package=false
    local has_apiserver=false
    local has_ca_cert=false
    local has_bootstrap=false
    
    grep -q "oci-oke-node" "$cloud_init_file" && has_oke_package=true
    grep -q "/etc/oke/oke-apiserver" "$cloud_init_file" && has_apiserver=true
    grep -q "/etc/kubernetes/ca.crt" "$cloud_init_file" && has_ca_cert=true
    grep -q "oke bootstrap" "$cloud_init_file" && has_bootstrap=true
    
    [[ "$has_oke_package" == "true" ]] && echo -e "  ${GREEN}✓${NC} OKE node package" || echo -e "  ${RED}✗${NC} OKE node package"
    [[ "$has_apiserver" == "true" ]] && echo -e "  ${GREEN}✓${NC} API server endpoint file" || echo -e "  ${RED}✗${NC} API server endpoint file"
    [[ "$has_ca_cert" == "true" ]] && echo -e "  ${GREEN}✓${NC} CA certificate file" || echo -e "  ${RED}✗${NC} CA certificate file"
    [[ "$has_bootstrap" == "true" ]] && echo -e "  ${GREEN}✓${NC} OKE bootstrap command" || echo -e "  ${RED}✗${NC} OKE bootstrap command"
    
    echo ""
    print_success "Validation complete"
}

#-------------------------------------------------------------------------------
# Main Script
#-------------------------------------------------------------------------------

show_help() {
    cat <<EOF
${BOLD}OKE Node Deployment Script${NC}

${BOLD}USAGE:${NC}
    $SCRIPT_NAME [OPTIONS]

${BOLD}DEPLOYMENT OPTIONS:${NC}
    --defaults      Run with all defaults, single confirmation at end
    --yes, -y       Auto-approve (use with --defaults for fully automated)
    --instance-config-id <OCID>
                    Use existing instance configuration (bypass all interactive steps)
    --debug         Enable debug mode (shows all OCI commands)
    --dry-run       Show what would be done without executing

${BOLD}NSG VALIDATION OPTIONS:${NC}
    --nsg-check     Validate CP & worker NSG rules for OKE compatibility
    --nsg-fix       Validate + interactively add missing rules (prompts before each)
    --nsg-dump      Validate + dump all raw NSG rules
    --nsg-check --nsg-dump
                    Combine flags: validate + dump raw rules
    --nsg-fix --nsg-dump --debug
                    Full diagnostic: validate, dump, fix, debug mode

${BOLD}UTILITY OPTIONS:${NC}
    --cleanup       Delete previously created resources (instances, configs)
    --validate      Validate cloud-init.yml without deploying
    --help, -h      Show this help message

${BOLD}DESCRIPTION:${NC}
    Interactive script to deploy OKE worker nodes.
    
    Step 1:  Compartment selection
    Step 2:  Deployment mode — Create New or Use Existing?
    
    If "Use Existing":
      → Select instance configuration → Review details → Launch
    
    If "Create New":
      Step 3:  OKE Cluster selection (gets kubeconfig, VCN info)
      Step 4:  Availability Domain selection
      Step 5:  VCN / Subnet / NSG selection
      Step 6:  Shape + Boot Volume configuration
      Step 7:  Image selection
      Step 8:  SSH key configuration
      Step 9:  Instance name configuration
      Step 10: Node labels and taints (optional)
      → Preview → Create instance configuration → Launch
    
    Then (both paths):
    - Instance launch and wait for RUNNING
    - Instance details and IP retrieval
    - Console history checking (optional)
    - Node registration verification

${BOLD}NSG VALIDATION:${NC}
    --nsg-check validates that CP and worker NSGs have all required rules:
      CP Ingress:     TCP/6443 (K8s API), TCP/12250 (node bootstrap)
      CP Egress:      TCP/10250 (kubelet) to workers
      Worker Egress:  TCP/6443, TCP/12250 to CP; TCP/443 to OCI services
      Worker Ingress: TCP/10250 from CP; pod-to-pod; NodePort (30000-32767)
      Both:           ICMP type 3/4 (path MTU); NSG-to-NSG cross-references

${BOLD}FILES:${NC}
    variables.sh    Configuration file (auto-sourced if present)
    cloud-init.yml  Cloud-init template for node bootstrap with kubeconfig support

${BOLD}LOG:${NC}
    deploy-oke-node.log  All OCI commands, JSON blocks, cloud-init, and results

${BOLD}EXAMPLES:${NC}
    $SCRIPT_NAME                  # Normal interactive mode (choose create vs reuse)
    $SCRIPT_NAME --defaults       # Use all defaults, create new config, confirm once
    $SCRIPT_NAME --defaults -y    # Fully automated with all defaults
    $SCRIPT_NAME --instance-config-id ocid1.instanceconfiguration.oc1...
                                  # Launch from specific instance configuration
    $SCRIPT_NAME --nsg-check      # Validate NSG rules (read-only)
    $SCRIPT_NAME --nsg-fix        # Validate + offer to add missing rules
    $SCRIPT_NAME --nsg-check --nsg-dump
                                  # Validate + dump all raw NSG rules
    $SCRIPT_NAME --debug          # Debug mode with command visibility
    $SCRIPT_NAME --dry-run        # Preview mode without execution
    $SCRIPT_NAME --cleanup        # Delete instances and configurations
    $SCRIPT_NAME --validate       # Validate cloud-init.yml schema

EOF
}

preview_deployment_artifacts() {
    echo ""
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  Deployment Artifacts Preview${NC}"
    echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    
    # Build kubelet extra args
    local kubelet_extra_args="--feature-gates=DynamicResourceAllocation=true"
    if [[ -n "${NODE_TAINTS:-}" ]]; then
        kubelet_extra_args="${kubelet_extra_args} --register-with-taints=${NODE_TAINTS}"
    else
        kubelet_extra_args="${kubelet_extra_args} --register-with-taints=newNode:NoSchedule"
    fi
    if [[ -n "${NODE_LABELS:-}" ]]; then
        kubelet_extra_args="${kubelet_extra_args} --node-labels=${NODE_LABELS}"
    fi
    
    # Generate cloud-init content using sed (handles large values like CA cert)
    local cloud_init_file="${CLOUD_INIT_FILE:-./cloud-init.yml}"
    local cloud_init_preview_file=""
    local cloud_init_content=""
    
    if [[ -f "$cloud_init_file" ]]; then
        # Create temp file for substitution
        cloud_init_preview_file="./cloud-init-preview-$(date +%Y%m%d-%H%M%S).yml"
        cp "$cloud_init_file" "$cloud_init_preview_file"
        
        # Use sed for reliable substitution - handle BOTH __VARIABLE__ and <variable> formats
        # IMPORTANT: Compound patterns must be replaced BEFORE simple patterns!
        
        # OKE Version Short - for apt repo (MUST be first to catch compound patterns)
        sed -i "s|__OKE_VERSION_SHORT__|${SELECTED_OKE_VERSION_SHORT:-1-31}|g" "$cloud_init_preview_file"
        sed -i "s|<oke_version_short>|${SELECTED_OKE_VERSION_SHORT:-1-31}|g" "$cloud_init_preview_file"
        # Fix kubernetes-1.`<oke version>` pattern BEFORE replacing <oke version>
        # Apt repo needs 1.34 format (dot separator), not 1-34 (hyphen)
        local oke_version_apt
        oke_version_apt=$(echo "${SELECTED_OKE_VERSION:-1.31.1}" | cut -d. -f1-2)  # e.g., 1.34
        sed -i "s|kubernetes-1\.\`<oke version>\`|kubernetes-${oke_version_apt}|g" "$cloud_init_preview_file"
        
        # OKE Version - handle multiple formats (AFTER compound patterns)
        sed -i "s|__OKE_VERSION__|${SELECTED_OKE_VERSION:-1.31.1}|g" "$cloud_init_preview_file"
        sed -i "s|<oke_version>|${SELECTED_OKE_VERSION:-1.31.1}|g" "$cloud_init_preview_file"
        sed -i "s|<oke version>|${SELECTED_OKE_VERSION:-1.31.1}|g" "$cloud_init_preview_file"
        
        # API Server - use parsed IP address for all <api_server_host> placeholders
        sed -i "s|__API_SERVER_HOST__|${SELECTED_API_SERVER_IP:-}|g" "$cloud_init_preview_file"
        sed -i "s|<api_server_host>|${SELECTED_API_SERVER_IP:-}|g" "$cloud_init_preview_file"
        sed -i "s|<apiserver_host>|${SELECTED_API_SERVER_IP:-}|g" "$cloud_init_preview_file"
        
        # API Server IP and Port as separate variables
        sed -i "s|__API_SERVER_IP__|${SELECTED_API_SERVER_IP:-}|g" "$cloud_init_preview_file"
        sed -i "s|<api_server_ip>|${SELECTED_API_SERVER_IP:-}|g" "$cloud_init_preview_file"
        sed -i "s|__API_SERVER_PORT__|${SELECTED_API_SERVER_PORT:-6443}|g" "$cloud_init_preview_file"
        sed -i "s|<api_server_port>|${SELECTED_API_SERVER_PORT:-6443}|g" "$cloud_init_preview_file"
        
        # API Server Full URL (for rare cases that need the full https://ip:port)
        sed -i "s|__API_SERVER_URL__|${SELECTED_API_SERVER_HOST:-}|g" "$cloud_init_preview_file"
        sed -i "s|<api_server_url>|${SELECTED_API_SERVER_HOST:-}|g" "$cloud_init_preview_file"
        
        # API Server Host Only (same as IP) for oke bootstrap command
        sed -i "s|__API_SERVER_HOST_ONLY__|${SELECTED_API_SERVER_IP:-}|g" "$cloud_init_preview_file"
        sed -i "s|<api_server_host_only>|${SELECTED_API_SERVER_IP:-}|g" "$cloud_init_preview_file"
        sed -i "s|<apiserver_host_only>|${SELECTED_API_SERVER_IP:-}|g" "$cloud_init_preview_file"
        
        # API Server Key/CA - handle <api_server_key> as CA cert alias
        sed -i "s|<api_server_key>|${SELECTED_API_SERVER_CA:-}|g" "$cloud_init_preview_file"
        sed -i "s|<api_server_key|${SELECTED_API_SERVER_CA:-}|g" "$cloud_init_preview_file"
        
        # SSH Key
        sed -i "s|__SSH_PUBLIC_KEY__|${SELECTED_SSH_KEY:-}|g" "$cloud_init_preview_file"
        sed -i "s|<ssh_public_key>|${SELECTED_SSH_KEY:-}|g" "$cloud_init_preview_file"
        
        # Node Labels and Taints
        sed -i "s|__NODE_LABELS__|${NODE_LABELS:-}|g" "$cloud_init_preview_file"
        sed -i "s|<node_labels>|${NODE_LABELS:-}|g" "$cloud_init_preview_file"
        sed -i "s|__NODE_TAINTS__|${NODE_TAINTS:-newNode:NoSchedule}|g" "$cloud_init_preview_file"
        sed -i "s|<node_taints>|${NODE_TAINTS:-newNode:NoSchedule}|g" "$cloud_init_preview_file"
        
        # Kubelet Extra Args
        sed -i "s|__KUBELET_EXTRA_ARGS__|${kubelet_extra_args}|g" "$cloud_init_preview_file"
        sed -i "s|<kubelet_extra_args>|${kubelet_extra_args}|g" "$cloud_init_preview_file"
        
        # Handle CA cert separately (large base64 string) - handle BOTH formats
        if [[ -n "${SELECTED_API_SERVER_CA:-}" ]]; then
            local ca_temp
            ca_temp=$(mktemp)
            echo -n "${SELECTED_API_SERVER_CA}" > "$ca_temp"
            if command -v perl &>/dev/null; then
                perl -i -pe "s|__API_SERVER_CA__|$(cat "$ca_temp")|g" "$cloud_init_preview_file"
                perl -i -pe "s|<api_server_ca>|$(cat "$ca_temp")|g" "$cloud_init_preview_file"
                perl -i -pe "s|<api_server_key>|$(cat "$ca_temp")|g" "$cloud_init_preview_file"
                perl -i -pe "s|<ca_cert>|$(cat "$ca_temp")|g" "$cloud_init_preview_file"
                # Handle malformed pattern with missing > like <api_server_key"
                perl -i -pe 's|<api_server_key"|'"$(cat "$ca_temp")"'"|g' "$cloud_init_preview_file"
            else
                local ca_content
                ca_content=$(cat "$ca_temp")
                awk -v ca="$ca_content" '{
                    gsub(/__API_SERVER_CA__/, ca)
                    gsub(/<api_server_ca>/, ca)
                    gsub(/<api_server_key>/, ca)
                    gsub(/<ca_cert>/, ca)
                    gsub(/<api_server_key"/, ca "\"")
                    print
                }' "$cloud_init_preview_file" > "${cloud_init_preview_file}.new"
                mv "${cloud_init_preview_file}.new" "$cloud_init_preview_file"
            fi
            rm -f "$ca_temp"
        fi
        
        # Legacy variables
        sed -i "s|__OKE_CLUSTER_ID__|${SELECTED_OKE_CLUSTER_ID:-}|g" "$cloud_init_preview_file"
        sed -i "s|__COMPARTMENT_ID__|${SELECTED_COMPARTMENT_ID}|g" "$cloud_init_preview_file"
        sed -i "s|__TENANCY_ID__|${TENANCY_ID:-}|g" "$cloud_init_preview_file"
        sed -i "s|__REGION__|${REGION:-}|g" "$cloud_init_preview_file"
        sed -i "s|__CLUSTER_DNS_IP__|${SELECTED_CLUSTER_DNS_IP:-10.96.0.10}|g" "$cloud_init_preview_file"
        
        cloud_init_content=$(cat "$cloud_init_preview_file")
    fi
    
    #---------------------------------------------------------------------------
    # 1. Cloud-Init Preview
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${YELLOW}${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}${BOLD}│  1. CLOUD-INIT (user_data)                                      │${NC}"
    echo -e "${YELLOW}${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"
    
    if [[ -n "$cloud_init_content" ]]; then
        # Show truncated version (first 60 lines) with line numbers
        echo -e "${CYAN}# File: $cloud_init_file (with variables substituted)${NC}"
        echo -e "${CYAN}# Showing first 60 lines...${NC}"
        echo ""
        echo "$cloud_init_content" | head -60 | nl -ba
        
        local total_lines
        total_lines=$(echo "$cloud_init_content" | wc -l)
        if [[ $total_lines -gt 60 ]]; then
            echo ""
            echo -e "${YELLOW}... ($((total_lines - 60)) more lines)${NC}"
        fi
        
        # Log the full cloud-init to the log file
        log_cloud_init "$cloud_init_preview_file"
        
        # Check for remaining unsubstituted variables (both __VAR__ and <var> formats)
        local unsubstituted_vars=""
        unsubstituted_vars=$(grep -oE "__[A-Z_]+__|<[a-z_]+>" "$cloud_init_preview_file" 2>/dev/null | sort -u || true)
        if [[ -n "$unsubstituted_vars" ]]; then
            echo ""
            echo -e "${RED}WARNING: Some variables were not substituted:${NC}"
            echo "$unsubstituted_vars"
        fi
        
        # VERIFY: Ensure oke bootstrap --apiserver-host has IP only (safety net)
        if grep -q "\-\-apiserver-host" "$cloud_init_preview_file"; then
            local preview_host
            preview_host=$(grep -oP '(?<=--apiserver-host )[^ "'"'"']+' "$cloud_init_preview_file" | head -1)
            if [[ "$preview_host" == *"://"* || "$preview_host" == *":"* ]]; then
                sed -i -E 's|(--apiserver-host )(https?://)?([^: "'"'"']+)(:[0-9]+)?|\1\3|g' "$cloud_init_preview_file"
            fi
        fi
        
        # Validate cloud-init schema
        echo ""
        echo -e "${CYAN}# Validating cloud-init schema...${NC}"
        if command -v cloud-init &>/dev/null; then
            local validation_output
            if validation_output=$(sudo cloud-init schema --config-file "$cloud_init_preview_file" 2>&1); then
                echo -e "${GREEN}✓ Cloud-init schema validation passed${NC}"
            else
                echo -e "${RED}✗ Cloud-init schema validation failed:${NC}"
                echo "$validation_output"
                echo ""
                if [[ "$AUTO_APPROVE" == "true" ]]; then
                    print_error "Cloud-init validation failed in auto-approve mode. Aborting."
                    exit 1
                fi
                read -rp "Continue anyway? [y/N]: " continue_anyway
                if [[ "${continue_anyway,,}" != "y" ]]; then
                    print_error "Deployment cancelled due to cloud-init validation failure"
                    exit 1
                fi
            fi
        else
            echo -e "${YELLOW}⚠ cloud-init not installed locally - skipping schema validation${NC}"
            echo -e "${YELLOW}  (validation will occur on the target instance)${NC}"
        fi
        
        echo ""
        echo -e "${GREEN}Full cloud-init saved to: $cloud_init_preview_file${NC}"
    else
        echo -e "${RED}No cloud-init.yml found${NC}"
    fi
    
    #---------------------------------------------------------------------------
    # 2. Instance Configuration JSON Preview
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${YELLOW}${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}${BOLD}│  2. INSTANCE CONFIGURATION JSON                                 │${NC}"
    echo -e "${YELLOW}${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"
    
    # Build shape config
    local shape_config=""
    if [[ -n "${SELECTED_OCPUS:-}" ]]; then
        shape_config=",
    \"shapeConfig\": {
        \"ocpus\": $SELECTED_OCPUS,
        \"memoryInGBs\": $SELECTED_MEMORY_GB
    }"
    fi
    
    # Build source details
    local source_details
    source_details=$(cat <<EOF
{
    "sourceType": "image",
    "imageId": "$SELECTED_IMAGE_ID",
    "bootVolumeSizeInGBs": ${SELECTED_BOOT_VOLUME_SIZE_GB:-100},
    "bootVolumeVpusPerGB": ${SELECTED_BOOT_VOLUME_VPU:-10}
}
EOF
)
    
    # Build instance details (truncated for display)
    local instance_details_display
    instance_details_display=$(cat <<EOF
{
    "availabilityDomain": "$SELECTED_AD",
    "compartmentId": "$SELECTED_COMPARTMENT_ID",
    "shape": "$SELECTED_SHAPE"$shape_config,
    "sourceDetails": $source_details,
    "createVnicDetails": {
        "subnetId": "$SELECTED_SUBNET_ID",
        "assignPublicIp": false
    },
    "metadata": {
        "ssh_authorized_keys": "${SELECTED_SSH_KEY:0:50}...",
        "user_data": "<base64-encoded cloud-init - $(echo -n "$cloud_init_content" | wc -c) bytes>"
    },
    "displayName": "$SELECTED_INSTANCE_NAME"
}
EOF
)
    
    # Add NSG IDs to display if selected
    if [[ ${#SELECTED_NSG_IDS[@]} -gt 0 ]]; then
        local nsg_json="["
        local first=true
        for nsg_id in "${SELECTED_NSG_IDS[@]}"; do
            if [[ "$first" == "true" ]]; then
                nsg_json="${nsg_json}\"${nsg_id}\""
                first=false
            else
                nsg_json="${nsg_json},\"${nsg_id}\""
            fi
        done
        nsg_json="${nsg_json}]"
        instance_details_display=$(echo "$instance_details_display" | jq --argjson nsgs "$nsg_json" \
            '.createVnicDetails.nsgIds = $nsgs')
    fi
    
    # Build full instance configuration for display
    # Note: This shows the structure expected by --instance-details
    local config_json_display
    config_json_display=$(cat <<EOF
{
    "instanceType": "compute",
    "launchDetails": $instance_details_display
}
EOF
)
    
    echo "$config_json_display" | jq '.' 2>/dev/null || echo "$config_json_display"
    
    # Save full config to file
    local config_preview_file="./instance-config-preview-$(date +%Y%m%d-%H%M%S).json"
    
    # Create the actual config with full SSH key and user_data for the saved file
    local cloud_init_base64
    cloud_init_base64=$(echo -n "$cloud_init_content" | base64 -w 0)
    
    local full_instance_details
    full_instance_details=$(cat <<EOF
{
    "availabilityDomain": "$SELECTED_AD",
    "compartmentId": "$SELECTED_COMPARTMENT_ID",
    "shape": "$SELECTED_SHAPE"$shape_config,
    "sourceDetails": $source_details,
    "createVnicDetails": {
        "subnetId": "$SELECTED_SUBNET_ID",
        "assignPublicIp": false
    },
    "metadata": {
        "ssh_authorized_keys": "$SELECTED_SSH_KEY",
        "user_data": "$cloud_init_base64"
    },
    "displayName": "$SELECTED_INSTANCE_NAME"
}
EOF
)
    
    # Add NSG IDs to full details if selected
    if [[ ${#SELECTED_NSG_IDS[@]} -gt 0 ]]; then
        local nsg_json="["
        local first=true
        for nsg_id in "${SELECTED_NSG_IDS[@]}"; do
            if [[ "$first" == "true" ]]; then
                nsg_json="${nsg_json}\"${nsg_id}\""
                first=false
            else
                nsg_json="${nsg_json},\"${nsg_id}\""
            fi
        done
        nsg_json="${nsg_json}]"
        full_instance_details=$(echo "$full_instance_details" | jq --argjson nsgs "$nsg_json" \
            '.createVnicDetails.nsgIds = $nsgs')
    fi
    
    local full_config_json
    full_config_json=$(cat <<EOF
{
    "instanceType": "compute",
    "launchDetails": $full_instance_details
}
EOF
)
    
    echo "$full_config_json" | jq '.' > "$config_preview_file" 2>/dev/null || echo "$full_config_json" > "$config_preview_file"
    echo ""
    echo -e "${GREEN}Full instance config saved to: $config_preview_file${NC}"
    
    # Log all JSON blocks to the log file
    log_step "Deployment Artifacts Preview"
    log_json "Source Details" "$source_details"
    log_json "Instance Details (Display - truncated user_data)" "$instance_details_display"
    log_json "Full Instance Configuration JSON (with base64 user_data)" "$full_config_json"
    
    #---------------------------------------------------------------------------
    # 3. OCI CLI Commands Preview
    #---------------------------------------------------------------------------
    echo ""
    echo -e "${YELLOW}${BOLD}┌─────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}${BOLD}│  3. OCI CLI COMMANDS TO BE EXECUTED                             │${NC}"
    echo -e "${YELLOW}${BOLD}└─────────────────────────────────────────────────────────────────┘${NC}"
    
    local config_name="oke-node-config-$(date +%Y%m%d-%H%M%S)"
    
    echo ""
    echo -e "${CYAN}# Step 1: Create Instance Configuration${NC}"
    echo "oci compute-management instance-configuration create \\"
    echo "    --compartment-id \"$SELECTED_COMPARTMENT_ID\" \\"
    echo "    --display-name \"$config_name\" \\"
    echo "    --instance-details \"file://$config_preview_file\""
    
    echo ""
    echo -e "${CYAN}# Step 2: Launch Instance from Configuration${NC}"
    echo "oci compute-management instance-configuration launch-compute-instance \\"
    echo "    --instance-configuration-id \"\${INSTANCE_CONFIG_OCID}\""
    
    echo ""
    echo -e "${CYAN}# Step 3: Wait for Instance to be Running${NC}"
    echo "oci compute instance get \\"
    echo "    --instance-id \"\${INSTANCE_OCID}\" \\"
    echo "    --query 'data.\"lifecycle-state\"'"
    
    echo ""
    echo -e "${CYAN}# Alternative: Direct Instance Launch (without Instance Configuration)${NC}"
    echo "oci compute instance launch \\"
    echo "    --availability-domain \"$SELECTED_AD\" \\"
    echo "    --compartment-id \"$SELECTED_COMPARTMENT_ID\" \\"
    echo "    --shape \"$SELECTED_SHAPE\" \\"
    if [[ -n "${SELECTED_OCPUS:-}" ]]; then
        echo "    --shape-config '{\"ocpus\": $SELECTED_OCPUS, \"memoryInGBs\": $SELECTED_MEMORY_GB}' \\"
    fi
    echo "    --subnet-id \"$SELECTED_SUBNET_ID\" \\"
    echo "    --image-id \"$SELECTED_IMAGE_ID\" \\"
    echo "    --display-name \"$SELECTED_INSTANCE_NAME\" \\"
    echo "    --user-data-file \"${cloud_init_preview_file:-./cloud-init.yml}\" \\"
    echo "    --ssh-authorized-keys-file \"\${SSH_KEY_FILE:-~/.ssh/id_rsa.pub}\""
    
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Log the CLI commands to the log file
    if [[ "${ENABLE_LOGGING:-true}" == "true" && -n "${LOG_FILE:-}" ]]; then
        {
            echo ""
            echo "================================================================================"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CLI-PREVIEW] OCI CLI Commands to be Executed"
            echo "================================================================================"
            echo ""
            echo "# Step 1: Create Instance Configuration"
            echo "oci compute-management instance-configuration create \\"
            echo "    --compartment-id \"$SELECTED_COMPARTMENT_ID\" \\"
            echo "    --display-name \"$config_name\" \\"
            echo "    --instance-details \"file://$config_preview_file\""
            echo ""
            echo "# Step 2: Launch Instance from Configuration"
            echo "oci compute-management instance-configuration launch-compute-instance \\"
            echo "    --instance-configuration-id \"\${INSTANCE_CONFIG_OCID}\""
            echo ""
            echo "# Step 3: Wait for Instance to be Running"
            echo "oci compute instance get \\"
            echo "    --instance-id \"\${INSTANCE_OCID}\" \\"
            echo "    --query 'data.\"lifecycle-state\"'"
            echo ""
            echo "# Alternative: Direct Instance Launch (without Instance Configuration)"
            echo "oci compute instance launch \\"
            echo "    --availability-domain \"$SELECTED_AD\" \\"
            echo "    --compartment-id \"$SELECTED_COMPARTMENT_ID\" \\"
            echo "    --shape \"$SELECTED_SHAPE\" \\"
            if [[ -n "${SELECTED_OCPUS:-}" ]]; then
                echo "    --shape-config '{\"ocpus\": $SELECTED_OCPUS, \"memoryInGBs\": $SELECTED_MEMORY_GB}' \\"
            fi
            echo "    --subnet-id \"$SELECTED_SUBNET_ID\" \\"
            echo "    --image-id \"$SELECTED_IMAGE_ID\" \\"
            echo "    --display-name \"$SELECTED_INSTANCE_NAME\" \\"
            echo "    --user-data-file \"${cloud_init_preview_file:-./cloud-init.yml}\" \\"
            echo "    --ssh-authorized-keys-file \"\${SSH_KEY_FILE:-~/.ssh/id_rsa.pub}\""
            echo ""
            echo "================================================================================"
        } >> "$LOG_FILE"
    fi
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --debug)
                DEBUG_MODE=true
                print_info "Debug mode enabled"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                print_info "Dry run mode enabled"
                shift
                ;;
            --defaults|--auto)
                USE_DEFAULTS=true
                print_info "Using defaults mode - will auto-select all defaults"
                shift
                ;;
            --yes|-y)
                AUTO_APPROVE=true
                shift
                ;;
            --instance-config-id)
                shift
                if [[ -z "${1:-}" ]]; then
                    print_error "--instance-config-id requires an OCID value"
                    exit 1
                fi
                USE_EXISTING_INSTANCE_CONFIG="$1"
                print_info "Using existing instance configuration: $USE_EXISTING_INSTANCE_CONFIG"
                shift
                ;;
            --cleanup|--delete)
                cleanup_resources
                exit 0
                ;;
            --nsg-check)
                NSG_CHECK_MODE=true
                shift
                # Check if --fix or --dump follows as additional flag
                continue
                ;;
            --nsg-fix)
                NSG_CHECK_MODE=true
                NSG_FIX_MODE=true
                shift
                continue
                ;;
            --nsg-dump)
                NSG_CHECK_MODE=true
                NSG_DUMP_MODE=true
                shift
                continue
                ;;
            --validate)
                shift
                validate_cloud_init "${1:-}"
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # NSG Check mode — early exit (does not proceed with deployment)
    if [[ "$NSG_CHECK_MODE" == "true" ]]; then
        nsg_check_main
        exit 0
    fi
    
    print_header "OKE Node Deployment Script"
    
    # Initialize log file
    if [[ "${ENABLE_LOGGING:-true}" == "true" ]]; then
        LOG_FILE="${LOG_FILE:-./deploy-oke-node.log}"
        {
            echo ""
            echo "################################################################################"
            echo "#"
            echo "#  OKE Node Deployment Log"
            echo "#  Started: $(date)"
            echo "#  User: $(whoami)@$(hostname)"
            echo "#  Script: $0"
            echo "#  Arguments: $*"
            echo "#  Log File: $LOG_FILE"
            echo "#"
            echo "################################################################################"
            echo ""
        } >> "$LOG_FILE"
        print_info "Logging to: $LOG_FILE"
    fi
    
    # Run deployment steps
    check_prerequisites
    
    # Step 1: Select Compartment (needed for all paths)
    select_compartment
    
    #---------------------------------------------------------------------------
    # EARLY BRANCH: --instance-config-id CLI flag bypasses everything
    #---------------------------------------------------------------------------
    if [[ -n "${USE_EXISTING_INSTANCE_CONFIG:-}" ]]; then
        print_info "CLI flag --instance-config-id provided, skipping interactive setup"
        select_instance_configuration
        launch_instance
        wait_for_instance
        
        # Apply display name override if set
        if [[ -n "${INSTANCE_NAME_OVERRIDE:-}" ]]; then
            update_instance_display_name
        fi
        
        get_instance_details
        check_console_history
        verify_node_registration
        
        print_header "Deployment Complete!"
        log_step "DEPLOYMENT COMPLETE"
        log_message "INFO" "Deployment completed successfully"
        log_message "INFO" "Instance OCID: ${CREATED_INSTANCE_ID:-unknown}"
        log_message "INFO" "Instance Config OCID: ${CREATED_INSTANCE_CONFIG_ID:-unknown}"
        log_message "INFO" "Log file: $LOG_FILE"
        print_info "Full deployment log: $LOG_FILE"
        return 0
    fi
    
    #---------------------------------------------------------------------------
    # Step 2: Deployment Mode — Create New or Use Existing?
    #---------------------------------------------------------------------------
    select_deployment_mode
    
    if [[ "$DEPLOYMENT_MODE" == "existing" ]]; then
        #-----------------------------------------------------------------------
        # USE EXISTING CONFIG FLOW
        #   Compartment → Select config → Show details → Confirm → Launch
        #-----------------------------------------------------------------------
        if use_existing_config_flow; then
            # Prompt for target OKE cluster (needed for pre-flight NSG validation)
            if [[ -z "${SELECTED_OKE_CLUSTER_ID:-}" ]]; then
                print_section "Select Target OKE Cluster"
                print_info "Fetching active OKE clusters in compartment..."

                local cluster_list_raw
                cluster_list_raw=$(oci ce cluster list \
                    --compartment-id "$SELECTED_COMPARTMENT_ID" \
                    --lifecycle-state ACTIVE \
                    --all 2>/dev/null) || true

                local cluster_list_json
                cluster_list_json=$(echo "$cluster_list_raw" | jq -c '[.data[] | {
                    name: .name,
                    id: .id,
                    version: (.["kubernetes-version"] | ltrimstr("v")),
                    endpoint: ((.endpoints["private-endpoint"] // .endpoints["public-endpoint"] // "unknown") | sub(":.*"; "") | sub("https?://"; ""))
                }]' 2>/dev/null) || cluster_list_json="[]"

                local cluster_count
                cluster_count=$(echo "$cluster_list_json" | jq 'length')

                if [[ "$cluster_count" -eq 0 ]]; then
                    print_warn "No active OKE clusters found — skipping pre-flight NSG check"
                else
                    echo ""
                    printf "  ${BOLD}%-4s %-40s %-10s %-20s${NC}\n" "#" "Cluster Name" "Version" "CP Endpoint"
                    printf "  %-4s %-40s %-10s %-20s\n" "----" "----------------------------------------" "----------" "--------------------"

                    # Auto-detect: try to match API server IP from instance config
                    local auto_match_idx=""
                    local ci=1
                    while IFS= read -r cl; do
                        local cname cver cep
                        cname=$(echo "$cl" | jq -r '.name')
                        cver=$(echo "$cl" | jq -r '.version')
                        cep=$(echo "$cl" | jq -r '.endpoint')

                        local marker=""
                        if [[ -n "${SELECTED_API_SERVER_IP:-}" && "$cep" == "$SELECTED_API_SERVER_IP" ]]; then
                            auto_match_idx="$ci"
                            marker=" ${GREEN}← matches config API server${NC}"
                        fi

                        printf "  %-4s %-40s %-10s %-20s" "$ci)" "$cname" "v$cver" "$cep"
                        [[ -n "$marker" ]] && echo -e "$marker" || echo ""
                        ((ci++))
                    done < <(echo "$cluster_list_json" | jq -c '.[]')

                    local default_sel="${auto_match_idx:-1}"
                    echo ""
                    echo -e "  Select the OKE cluster this node will join"
                    read -rp "  Selection [1-$cluster_count] (default: $default_sel): " cl_selection </dev/tty
                    cl_selection="${cl_selection:-$default_sel}"

                    if [[ "$cl_selection" =~ ^[0-9]+$ ]] && [[ "$cl_selection" -ge 1 ]] && [[ "$cl_selection" -le "$cluster_count" ]]; then
                        local selected_cl
                        selected_cl=$(echo "$cluster_list_json" | jq -c ".[$((cl_selection - 1))]")
                        SELECTED_OKE_CLUSTER_ID=$(echo "$selected_cl" | jq -r '.id')
                        SELECTED_OKE_CLUSTER_NAME=$(echo "$selected_cl" | jq -r '.name')
                        CLUSTER_NAME="$SELECTED_OKE_CLUSTER_NAME"
                        print_success "Target cluster: $SELECTED_OKE_CLUSTER_NAME"
                        log_message "INFO" "Target OKE cluster selected: $SELECTED_OKE_CLUSTER_NAME ($SELECTED_OKE_CLUSTER_ID)"
                    else
                        print_warn "Invalid selection — skipping pre-flight NSG check"
                    fi
                fi
            fi

            preflight_nsg_api_check

            # Final confirmation — after NSG validation so user knows the full picture
            echo ""
            if [[ "$AUTO_APPROVE" == "true" ]]; then
                echo -e "${GREEN}[AUTO-APPROVE]${NC} Proceeding with launch..."
            else
                read -rp "Proceed with launch? [Y/n]: " confirm </dev/tty
                if [[ "${confirm,,}" == "n" ]]; then
                    print_info "Deployment cancelled"
                    exit 0
                fi
            fi

            # Successfully selected an existing config — launch it
            launch_instance
            wait_for_instance
            
            # Apply display name override if user changed it
            if [[ -n "${INSTANCE_NAME_OVERRIDE:-}" ]]; then
                update_instance_display_name
            fi
            
            get_instance_details
            check_console_history
            verify_node_registration
            
            print_header "Deployment Complete!"
            log_step "DEPLOYMENT COMPLETE"
            log_message "INFO" "Deployment completed successfully (existing config)"
            log_message "INFO" "Instance Name: $SELECTED_INSTANCE_NAME"
            log_message "INFO" "Instance OCID: ${CREATED_INSTANCE_ID:-unknown}"
            log_message "INFO" "Instance Config OCID: ${CREATED_INSTANCE_CONFIG_ID:-unknown}"
            log_message "INFO" "Shape: $SELECTED_SHAPE | Boot: ${SELECTED_BOOT_VOLUME_SIZE_GB}GB @ ${SELECTED_BOOT_VOLUME_VPU} VPU"
            log_message "INFO" "Log file: $LOG_FILE"
            print_info "Full deployment log: $LOG_FILE"
            return 0
        else
            # use_existing_config_flow returned non-zero — no configs found, fall through to create new
            print_info "Continuing with 'Create New' flow..."
            DEPLOYMENT_MODE="new"
        fi
    fi
    
    #---------------------------------------------------------------------------
    # CREATE NEW FLOW
    #   Full interactive setup: Cluster → AD → VCN → Subnet → NSG → Shape →
    #   Boot Volume → Image → SSH → Name → Labels/Taints → Preview → Create → Launch
    #---------------------------------------------------------------------------
    select_oke_cluster || true  # Continue even if no OKE cluster (manual config possible)
    select_availability_domain
    select_vcn
    select_subnet
    select_nsg
    select_shape
    configure_boot_volume
    select_image
    configure_ssh_key
    configure_instance_name
    configure_kubeconfig  # Only prompts if not already configured from OKE cluster
    configure_node_labels_taints
    
    # Pre-flight: Verify API server reachability and NSG rules
    preflight_nsg_api_check
    
    # Confirmation
    print_section "Deployment Confirmation"
    echo -e "${BOLD}Summary of selections:${NC}"
    echo "  Compartment:  $SELECTED_COMPARTMENT_NAME"
    echo "  AD:           $SELECTED_AD"
    echo "  VCN:          $SELECTED_VCN_NAME"
    echo "  Subnet:       $SELECTED_SUBNET_NAME"
    if [[ -n "${SELECTED_NSG_NAMES:-}" ]]; then
        echo "  NSG(s):       $SELECTED_NSG_NAMES"
    else
        echo "  NSG(s):       None (security lists only)"
    fi
    echo "  Shape:        $SELECTED_SHAPE"
    if [[ -n "${SELECTED_OCPUS:-}" ]]; then
        echo "  Config:       $SELECTED_OCPUS OCPUs, ${SELECTED_MEMORY_GB}GB Memory"
    fi
    echo "  Boot Volume:  ${SELECTED_BOOT_VOLUME_SIZE_GB}GB, ${SELECTED_BOOT_VOLUME_VPU} VPUs/GB"
    echo "  Image:        $SELECTED_IMAGE_NAME"
    echo "  Name:         $SELECTED_INSTANCE_NAME"
    echo ""
    echo -e "${BOLD}OKE Cluster Configuration:${NC}"
    if [[ -n "${SELECTED_OKE_CLUSTER_NAME:-}" ]]; then
        echo "  Cluster:      $SELECTED_OKE_CLUSTER_NAME"
    fi
    if [[ -n "${SELECTED_OKE_VERSION:-}" ]]; then
        echo "  K8s Version:  $SELECTED_OKE_VERSION (apt: $SELECTED_OKE_VERSION_SHORT)"
    fi
    if [[ -n "${SELECTED_API_SERVER_HOST:-}" ]]; then
        echo "  API Server:   $SELECTED_API_SERVER_IP:$SELECTED_API_SERVER_PORT"
    fi
    if [[ -n "${SELECTED_API_SERVER_CA:-}" ]]; then
        echo "  CA Cert:      Configured ✓"
    else
        echo "  CA Cert:      Not configured ✗"
    fi
    if [[ -n "${NODE_LABELS:-}" ]]; then
        echo "  Node Labels:  $NODE_LABELS"
    fi
    if [[ -n "${NODE_TAINTS:-}" ]]; then
        echo "  Node Taints:  $NODE_TAINTS"
    else
        echo "  Node Taints:  newNode:NoSchedule (default)"
    fi
    echo ""
    
    # Generate cloud-init and instance config for preview
    preview_deployment_artifacts
    
    # Confirmation
    if [[ "$AUTO_APPROVE" == "true" ]]; then
        echo -e "${GREEN}[AUTO-APPROVE]${NC} Proceeding with deployment..."
    else
        read -rp "Proceed with deployment? [Y/n]: " confirm
        if [[ "${confirm,,}" == "n" ]]; then
            print_info "Deployment cancelled"
            exit 0
        fi
    fi
    
    # Deploy
    log_step "DEPLOYMENT EXECUTION STARTED (New Config)"
    log_message "INFO" "Deployment confirmed - executing"
    log_message "INFO" "Selections: compartment=$SELECTED_COMPARTMENT_NAME AD=$SELECTED_AD shape=$SELECTED_SHAPE"
    log_message "INFO" "Image: $SELECTED_IMAGE_NAME"
    log_message "INFO" "Subnet: $SELECTED_SUBNET_NAME NSG: ${SELECTED_NSG_NAMES:-none}"
    log_message "INFO" "Boot Volume: ${SELECTED_BOOT_VOLUME_SIZE_GB}GB, ${SELECTED_BOOT_VOLUME_VPU} VPUs/GB"
    log_message "INFO" "Instance Name: $SELECTED_INSTANCE_NAME"
    if [[ -n "${SELECTED_OKE_CLUSTER_NAME:-}" ]]; then
        log_message "INFO" "OKE Cluster: $SELECTED_OKE_CLUSTER_NAME (v${SELECTED_OKE_VERSION:-unknown})"
        log_message "INFO" "API Server: ${SELECTED_API_SERVER_IP:-unknown}:${SELECTED_API_SERVER_PORT:-unknown}"
    fi
    
    select_instance_configuration
    launch_instance
    wait_for_instance
    get_instance_details
    check_console_history
    verify_node_registration
    
    print_header "Deployment Complete!"
    
    log_step "DEPLOYMENT COMPLETE"
    log_message "INFO" "Deployment completed successfully (new config)"
    log_message "INFO" "Instance Name: $SELECTED_INSTANCE_NAME"
    log_message "INFO" "Instance OCID: ${CREATED_INSTANCE_ID:-unknown}"
    log_message "INFO" "Instance Config OCID: ${CREATED_INSTANCE_CONFIG_ID:-unknown}"
    log_message "INFO" "Shape: $SELECTED_SHAPE | Boot: ${SELECTED_BOOT_VOLUME_SIZE_GB}GB @ ${SELECTED_BOOT_VOLUME_VPU} VPU"
    log_message "INFO" "Log file: $LOG_FILE"
    
    print_info "Full deployment log: $LOG_FILE"
}

# Run main
main "$@"
