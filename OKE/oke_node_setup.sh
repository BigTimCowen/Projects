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
SELECTED_SHAPE=""
SELECTED_IMAGE_ID=""
SELECTED_IMAGE_NAME=""
SELECTED_OCPUS=""
SELECTED_MEMORY_GB=""
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
        if [[ ${#name} -gt 50 ]]; then
            name="${name:0:47}..."
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
    
    print_info "Fetching compartments..."
    
    # TENANCY_ID should be set from IMDS or variables.sh by now
    if [[ -z "${TENANCY_ID:-}" ]]; then
        print_error "TENANCY_ID not set"
        print_info "Either run from an OCI instance or set TENANCY_ID in variables.sh"
        exit 1
    fi
    
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
    local default_cid="${DEFAULT_COMPARTMENT_ID:-}"
    
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
    
    print_success "API Server: $SELECTED_API_SERVER_HOST"
    
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
    
    print_success "API Server Host: $SELECTED_API_SERVER_HOST"
    
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
    
    print_success "Kubeconfig loaded from: $file_path"
    
    if [[ -n "$SELECTED_API_SERVER_HOST" ]]; then
        print_success "API Server Host: $SELECTED_API_SERVER_HOST"
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
        print_success "API Server Host: $SELECTED_API_SERVER_HOST"
    else
        print_warn "Could not extract API server host"
        read -rp "Enter API server host (e.g., https://xxx.oraclecloud.com:6443): " api_input
        SELECTED_API_SERVER_HOST="$api_input"
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
# Instance Configuration and Deployment
#-------------------------------------------------------------------------------

create_instance_configuration() {
    print_section "Creating Instance Configuration"
    
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
        
        # API Server Host - handle multiple formats
        sed -i "s|__API_SERVER_HOST__|${SELECTED_API_SERVER_HOST:-}|g" "$temp_cloud_init"
        sed -i "s|<api_server_host>|${SELECTED_API_SERVER_HOST:-}|g" "$temp_cloud_init"
        sed -i "s|<apiserver_host>|${SELECTED_API_SERVER_HOST:-}|g" "$temp_cloud_init"
        
        # API Server Host (without https:// prefix) for oke bootstrap command
        # oke bootstrap expects just the hostname, no protocol or port
        local api_server_host_only="${SELECTED_API_SERVER_HOST:-}"
        api_server_host_only="${api_server_host_only#https://}"
        api_server_host_only="${api_server_host_only#http://}"
        api_server_host_only="${api_server_host_only%%:*}"  # Remove port
        sed -i "s|__API_SERVER_HOST_ONLY__|${api_server_host_only}|g" "$temp_cloud_init"
        sed -i "s|<api_server_host_only>|${api_server_host_only}|g" "$temp_cloud_init"
        sed -i "s|<apiserver_host_only>|${api_server_host_only}|g" "$temp_cloud_init"
        
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
            echo "  API_SERVER_HOST: ${SELECTED_API_SERVER_HOST:-NOT SET}"
            echo "  API_SERVER_CA: $(echo -n "${SELECTED_API_SERVER_CA:-}" | wc -c) bytes"
            echo "  KUBELET_EXTRA_ARGS: ${kubelet_extra_args}"
            echo ""
            print_debug "Cloud-init content (first 80 lines):"
            head -80 "$temp_cloud_init"
        fi
        
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
    "bootVolumeSizeInGBs": ${DEFAULT_BOOT_VOLUME_SIZE_GB:-100},
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
    
    print_info "Creating instance configuration..."
    
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
}

launch_instance() {
    print_section "Launching Instance"
    
    print_info "Launching instance from configuration..."
    
    local raw_output
    
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_debug "Running: oci compute-management instance-configuration launch-compute-instance ..."
    fi
    
    raw_output=$(oci compute-management instance-configuration launch-compute-instance \
        --instance-configuration-id "$CREATED_INSTANCE_CONFIG_ID" 2>&1) || true
    
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
}

wait_for_instance() {
    print_section "Waiting for Instance to be Running"
    
    local timeout="${INSTANCE_WAIT_TIMEOUT_SECONDS:-600}"
    local interval="${INSTANCE_POLL_INTERVAL_SECONDS:-10}"
    local elapsed=0
    
    print_info "Timeout: ${timeout}s, Poll interval: ${interval}s"
    
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
        
        case "$state" in
            "RUNNING")
                echo ""
                print_success "Instance is RUNNING!"
                return 0
                ;;
            "TERMINATED"|"TERMINATING")
                echo ""
                print_error "Instance entered $state state"
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
    return 1
}

get_instance_details() {
    print_section "Instance Details"
    
    local raw_output
    raw_output=$(oci compute instance get \
        --instance-id "$CREATED_INSTANCE_ID" 2>&1) || true
    
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
    local vnic_raw
    vnic_raw=$(oci compute vnic-attachment list \
        --compartment-id "$SELECTED_COMPARTMENT_ID" \
        --instance-id "$CREATED_INSTANCE_ID" 2>&1) || true
    
    local vnic_id=""
    if echo "$vnic_raw" | jq -e '.data[0]["vnic-id"]' &>/dev/null; then
        vnic_id=$(echo "$vnic_raw" | jq -r '.data[0]["vnic-id"]')
    fi
    
    local private_ip="Pending..."
    local public_ip="N/A"
    
    if [[ -n "$vnic_id" && "$vnic_id" != "null" ]]; then
        local vnic_info_raw
        vnic_info_raw=$(oci network vnic get --vnic-id "$vnic_id" 2>&1) || true
        
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
}

check_console_history() {
    print_section "Console History"
    
    echo ""
    read -rp "Would you like to check the console history? [y/N]: " check_console
    
    if [[ "${check_console,,}" != "y" ]]; then
        print_info "Skipping console history check"
        return 0
    fi
    
    print_info "Waiting ${CONSOLE_HISTORY_WAIT_SECONDS:-120}s for console output to be available..."
    print_info "(Press Ctrl+C to skip waiting)"
    
    local wait_time="${CONSOLE_HISTORY_WAIT_SECONDS:-120}"
    local elapsed=0
    
    while [[ $elapsed -lt $wait_time ]]; do
        printf "\r${BLUE}[%d/%ds]${NC} Waiting for console history..." "$elapsed" "$wait_time"
        sleep 10
        elapsed=$((elapsed + 10))
        
        # Check if console history is available
        local history_raw
        history_raw=$(oci compute console-history list \
            --compartment-id "$SELECTED_COMPARTMENT_ID" \
            --instance-id "$CREATED_INSTANCE_ID" \
            --lifecycle-state SUCCEEDED 2>&1) || true
        
        if echo "$history_raw" | jq -e '.data[0].id' &>/dev/null; then
            local history_id
            history_id=$(echo "$history_raw" | jq -r '.data[0].id')
            if [[ -n "$history_id" && "$history_id" != "null" ]]; then
                break
            fi
        fi
    done
    echo ""
    
    # Capture console history
    print_info "Capturing console history..."
    
    local capture_raw
    capture_raw=$(oci compute console-history capture \
        --instance-id "$CREATED_INSTANCE_ID" 2>&1) || true
    
    if ! echo "$capture_raw" | jq -e '.data.id' &>/dev/null; then
        print_warn "Could not capture console history"
        return 0
    fi
    
    local history_id
    history_id=$(echo "$capture_raw" | jq -r '.data.id')
    
    # Wait for capture to complete
    print_info "Waiting for capture to complete..."
    sleep 15
    
    # Get console history content
    local content
    content=$(oci compute console-history get-content \
        --instance-console-history-id "$history_id" \
        --length 10000000 \
        --file - 2>/dev/null) || true
    
    if [[ -n "$content" ]]; then
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━ CONSOLE OUTPUT ━━━━━━━━━━━━━━━━━━━━${NC}"
        echo "$content" | tail -100
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        
        # Save full output to file
        local log_file="console-history-${CREATED_INSTANCE_ID##*.}.log"
        echo "$content" > "$log_file"
        print_info "Full console history saved to: $log_file"
    else
        print_warn "No console history content available yet"
    fi
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

${BOLD}OPTIONS:${NC}
    --defaults      Run with all defaults, single confirmation at end
    --yes, -y       Auto-approve (use with --defaults for fully automated)
    --debug         Enable debug mode (shows all OCI commands)
    --dry-run       Show what would be done without executing
    --cleanup       Delete previously created resources (instances, configs)
    --validate      Validate cloud-init.yml without deploying
    --help, -h      Show this help message

${BOLD}DESCRIPTION:${NC}
    Interactive script to deploy OKE worker nodes with:
    
    Step 1:  Compartment selection
    Step 2:  OKE Cluster selection (gets kubeconfig, VCN info)
    Step 3:  Availability Domain selection
    Step 4:  VCN selection (defaults to cluster's VCN)
    Step 5:  Subnet selection
    Step 6:  Shape selection (E5 Flex default, GPU shapes highlighted)
    Step 7:  Image selection (filtered for OKE compatibility)
    Step 8:  SSH key configuration
    Step 9:  Instance name configuration
    Step 10: Node labels and taints (optional)
    
    Then:
    - Instance Configuration creation
    - Instance launch and monitoring
    - Console history checking

${BOLD}FILES:${NC}
    variables.sh    Configuration file (auto-sourced if present)
    cloud-init.yml  Cloud-init template for node bootstrap with kubeconfig support

${BOLD}EXAMPLES:${NC}
    $SCRIPT_NAME                  # Normal interactive mode
    $SCRIPT_NAME --defaults       # Use all defaults, confirm once at end
    $SCRIPT_NAME --defaults -y    # Fully automated with all defaults
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
        
        # API Server Host - handle multiple formats
        sed -i "s|__API_SERVER_HOST__|${SELECTED_API_SERVER_HOST:-}|g" "$cloud_init_preview_file"
        sed -i "s|<api_server_host>|${SELECTED_API_SERVER_HOST:-}|g" "$cloud_init_preview_file"
        sed -i "s|<apiserver_host>|${SELECTED_API_SERVER_HOST:-}|g" "$cloud_init_preview_file"
        
        # API Server Host (without https:// prefix) for oke bootstrap command
        # oke bootstrap expects just the hostname, no protocol or port
        local api_server_host_only="${SELECTED_API_SERVER_HOST:-}"
        api_server_host_only="${api_server_host_only#https://}"
        api_server_host_only="${api_server_host_only#http://}"
        api_server_host_only="${api_server_host_only%%:*}"  # Remove port
        sed -i "s|__API_SERVER_HOST_ONLY__|${api_server_host_only}|g" "$cloud_init_preview_file"
        sed -i "s|<api_server_host_only>|${api_server_host_only}|g" "$cloud_init_preview_file"
        sed -i "s|<apiserver_host_only>|${api_server_host_only}|g" "$cloud_init_preview_file"
        
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
        
        # Check for remaining unsubstituted variables (both __VAR__ and <var> formats)
        local unsubstituted_vars=""
        unsubstituted_vars=$(grep -oE "__[A-Z_]+__|<[a-z_]+>" "$cloud_init_preview_file" 2>/dev/null | sort -u || true)
        if [[ -n "$unsubstituted_vars" ]]; then
            echo ""
            echo -e "${RED}WARNING: Some variables were not substituted:${NC}"
            echo "$unsubstituted_vars"
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
    "bootVolumeSizeInGBs": ${BOOT_VOLUME_SIZE_GB:-100}
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
            --cleanup|--delete)
                cleanup_resources
                exit 0
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
    
    print_header "OKE Node Deployment Script"
    
    # Initialize log file
    if [[ "${ENABLE_LOGGING:-true}" == "true" ]]; then
        LOG_FILE="${LOG_FILE:-./deploy-oke-node.log}"
        echo "=== Deployment started: $(date) ===" >> "$LOG_FILE"
    fi
    
    # Run deployment steps
    check_prerequisites
    
    select_compartment
    select_oke_cluster || true  # Continue even if no OKE cluster (manual config possible)
    select_availability_domain
    select_vcn
    select_subnet
    select_shape
    select_image
    configure_ssh_key
    configure_instance_name
    configure_kubeconfig  # Only prompts if not already configured from OKE cluster
    configure_node_labels_taints
    
    # Confirmation
    print_section "Deployment Confirmation"
    echo -e "${BOLD}Summary of selections:${NC}"
    echo "  Compartment:  $SELECTED_COMPARTMENT_NAME"
    echo "  AD:           $SELECTED_AD"
    echo "  VCN:          $SELECTED_VCN_NAME"
    echo "  Subnet:       $SELECTED_SUBNET_NAME"
    echo "  Shape:        $SELECTED_SHAPE"
    if [[ -n "${SELECTED_OCPUS:-}" ]]; then
        echo "  Config:       $SELECTED_OCPUS OCPUs, ${SELECTED_MEMORY_GB}GB Memory"
    fi
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
        echo "  API Server:   $SELECTED_API_SERVER_HOST"
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
    create_instance_configuration
    launch_instance
    wait_for_instance
    get_instance_details
    check_console_history
    verify_node_registration
    
    print_header "Deployment Complete!"
    
    log_message "INFO" "Deployment completed successfully"
}

# Run main
main "$@"