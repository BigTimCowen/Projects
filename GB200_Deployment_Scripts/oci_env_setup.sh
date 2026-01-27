#!/bin/bash
#===============================================================================
# OCI Environment Setup Script - Interactive Mode
# Auto-populates OCI variables from Instance Metadata Service (IMDS)
# and allows interactive selection of resources
#
# Run this from an operator node within the same compartment as your GPU resources
#
# Usage:
#   ./oci_env_setup.sh                    # Interactive mode
#   ./oci_env_setup.sh --export           # Output export commands
#   source oci_env_setup.sh               # Source to set variables in current shell
#===============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# IMDS v2 endpoint
IMDS_BASE="http://169.254.169.254/opc/v2"
IMDS_HEADER="Authorization: Bearer Oracle"

# Global variables for selections
declare -A RESOURCE_MAP

#-------------------------------------------------------------------------------
# Utility functions
#-------------------------------------------------------------------------------
print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${WHITE}  $1${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
}

print_section() {
    echo ""
    echo -e "${BOLD}${CYAN}─── $1 ───${NC}"
    echo ""
}

print_separator() {
    local width="${1:-80}"
    printf '%*s\n' "$width" '' | tr ' ' '─'
}

#-------------------------------------------------------------------------------
# Wait for IMDS to be available
#-------------------------------------------------------------------------------
wait_for_imds() {
    local timeout=60
    local elapsed=0
    
    echo -e "${YELLOW}Waiting for IMDS...${NC}"
    while true; do
        if curl -sS -H "$IMDS_HEADER" "${IMDS_BASE}/instance/" -o /dev/null 2>/dev/null; then
            echo -e "${GREEN}IMDS available${NC}"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        if [[ $elapsed -ge $timeout ]]; then
            echo -e "${RED}ERROR: Timeout waiting for IMDS${NC}" >&2
            return 1
        fi
    done
}

#-------------------------------------------------------------------------------
# Fetch instance metadata
#-------------------------------------------------------------------------------
fetch_metadata() {
    echo -e "${YELLOW}Fetching instance metadata...${NC}"
    
    local instance_json
    instance_json=$(curl -sH "$IMDS_HEADER" -L "${IMDS_BASE}/instance/" 2>/dev/null)
    
    if [[ -z "$instance_json" ]]; then
        echo -e "${RED}ERROR: Failed to fetch instance metadata${NC}" >&2
        return 1
    fi
    
    # Extract values
    TENANCY_ID=$(echo "$instance_json" | jq -r '.tenantId // empty')
    COMPARTMENT_ID=$(echo "$instance_json" | jq -r '.compartmentId // empty')
    REGION=$(echo "$instance_json" | jq -r '.canonicalRegionName // empty')
    AD=$(echo "$instance_json" | jq -r '.availabilityDomain // empty')
    INSTANCE_ID=$(echo "$instance_json" | jq -r '.id // empty')
    DISPLAY_NAME=$(echo "$instance_json" | jq -r '.displayName // empty')
    SHAPE=$(echo "$instance_json" | jq -r '.shape // empty')
    
    # Validate required fields
    if [[ -z "$TENANCY_ID" || -z "$COMPARTMENT_ID" || -z "$REGION" ]]; then
        echo -e "${RED}ERROR: Missing required metadata fields${NC}" >&2
        return 1
    fi
    
    echo -e "${GREEN}Metadata fetched successfully${NC}"
    return 0
}

#-------------------------------------------------------------------------------
# Check OCI CLI availability
#-------------------------------------------------------------------------------
check_oci_cli() {
    if ! command -v oci &>/dev/null; then
        echo -e "${RED}ERROR: OCI CLI not found. Please install OCI CLI.${NC}" >&2
        return 1
    fi
    
    # Test instance principal auth
    if ! oci iam region list --auth instance_principal &>/dev/null; then
        echo -e "${RED}ERROR: Instance principal authentication failed.${NC}" >&2
        echo -e "${YELLOW}Ensure this instance has a dynamic group with appropriate policies.${NC}" >&2
        return 1
    fi
    
    echo -e "${GREEN}OCI CLI available with instance principal auth${NC}"
    return 0
}

#-------------------------------------------------------------------------------
# Interactive selection helper
#-------------------------------------------------------------------------------
select_from_list() {
    local prompt="$1"
    local -n items_ref=$2
    local -n result_ref=$3
    local allow_skip="${4:-false}"
    
    if [[ ${#items_ref[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No items available${NC}"
        result_ref=""
        return 1
    fi
    
    local idx=1
    for item in "${items_ref[@]}"; do
        local name=$(echo "$item" | cut -d'|' -f1)
        local id=$(echo "$item" | cut -d'|' -f2)
        local extra=$(echo "$item" | cut -d'|' -f3-)
        
        if [[ -n "$extra" ]]; then
            printf "${YELLOW}%3d${NC}) ${CYAN}%-50s${NC} ${GRAY}%s${NC}\n" "$idx" "$name" "$extra"
        else
            printf "${YELLOW}%3d${NC}) ${CYAN}%-50s${NC}\n" "$idx" "$name"
        fi
        
        RESOURCE_MAP[$idx]="$id"
        ((idx++))
    done
    
    if [[ "$allow_skip" == "true" ]]; then
        echo -e "${GRAY}  0) Skip / Enter manually later${NC}"
    fi
    
    echo ""
    while true; do
        echo -n -e "${WHITE}$prompt ${NC}"
        read -r selection
        
        if [[ "$allow_skip" == "true" && "$selection" == "0" ]]; then
            result_ref=""
            return 0
        fi
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ -n "${RESOURCE_MAP[$selection]:-}" ]]; then
            result_ref="${RESOURCE_MAP[$selection]}"
            return 0
        fi
        
        echo -e "${RED}Invalid selection. Please try again.${NC}"
    done
}

#-------------------------------------------------------------------------------
# Import existing configuration from variables.sh
#-------------------------------------------------------------------------------
import_existing_config() {
    local config_file="${1:-variables.sh}"
    
    if [[ ! -f "$config_file" ]]; then
        return 1
    fi
    
    echo -e "${CYAN}Found existing configuration: ${WHITE}$config_file${NC}"
    echo ""
    
    # Source the file to get variables
    source "$config_file" 2>/dev/null || return 1
    
    # Map sourced variables to our internal variables
    OKE_CLUSTER_ID="${OKE_CLUSTER_ID:-}"
    OKE_CLUSTER_NAME="${CLUSTER_NAME:-}"
    WORKER_SUBNET_ID="${WORKER_SUBNET_ID:-}"
    WORKER_SUBNET_NSG_ID="${WORKER_SUBNET_NSG_ID:-}"
    POD_SUBNET_ID="${POD_SUBNET_ID:-}"
    POD_SUBNET_NSG_ID="${POD_SUBNET_NSG_ID:-}"
    CC_ID="${CC_ID:-}"
    IC_ID="${IC_ID:-}"
    GPU_MEMORY_FABRIC_ID="${GPU_MEMORY_FABRIC_ID:-}"
    IMAGE_ID="${IMAGE_ID:-}"
    
    # Display what was imported
    echo -e "${BOLD}${WHITE}Imported Configuration:${NC}"
    echo ""
    
    local has_empty=false
    
    # Check each value and display status
    display_import_status "OKE Cluster ID" "$OKE_CLUSTER_ID" has_empty
    display_import_status "OKE Cluster Name" "$OKE_CLUSTER_NAME" has_empty
    display_import_status "Worker Subnet" "$WORKER_SUBNET_ID" has_empty
    display_import_status "Worker NSG" "$WORKER_SUBNET_NSG_ID" has_empty
    display_import_status "Pod Subnet" "$POD_SUBNET_ID" has_empty
    display_import_status "Pod NSG" "$POD_SUBNET_NSG_ID" has_empty
    display_import_status "Compute Cluster" "$CC_ID" has_empty
    display_import_status "Instance Config" "$IC_ID" has_empty
    display_import_status "GPU Memory Fabric" "$GPU_MEMORY_FABRIC_ID" has_empty
    display_import_status "Image ID" "$IMAGE_ID" has_empty
    
    echo ""
    
    if [[ "$has_empty" == "true" ]]; then
        echo -e "${YELLOW}Some values are not populated. You can fill them in during setup.${NC}"
    else
        echo -e "${GREEN}All values are populated.${NC}"
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# Display import status for a single field
#-------------------------------------------------------------------------------
display_import_status() {
    local field_name="$1"
    local field_value="$2"
    local -n empty_flag=$3
    
    if [[ -n "$field_value" ]]; then
        printf "  ${GREEN}✓${NC} ${CYAN}%-20s${NC} ${WHITE}%.50s${NC}\n" "$field_name:" "$field_value"
    else
        printf "  ${YELLOW}○${NC} ${CYAN}%-20s${NC} ${GRAY}(empty)${NC}\n" "$field_name:"
        empty_flag=true
    fi
}

#-------------------------------------------------------------------------------
# Check if a resource needs selection (empty or user wants to change)
#-------------------------------------------------------------------------------
needs_selection() {
    local current_value="$1"
    local resource_name="$2"
    
    if [[ -z "$current_value" ]]; then
        return 0  # Empty, needs selection
    fi
    
    # Value exists - ask if user wants to change it
    echo ""
    echo -e "${CYAN}$resource_name is already set:${NC}"
    echo -e "  ${WHITE}$current_value${NC}"
    echo -n -e "${CYAN}Keep this value? (y/n): ${NC}"
    read -r keep_choice
    
    if [[ "$keep_choice" =~ ^[Nn]$ ]]; then
        return 0  # User wants to change
    fi
    
    return 1  # Keep current value
}
select_oke_cluster() {
    print_section "OKE Clusters"
    
    echo -e "${YELLOW}Fetching OKE clusters...${NC}"
    
    local clusters_json
    clusters_json=$(oci ce cluster list \
        --compartment-id "$COMPARTMENT_ID" \
        --auth instance_principal \
        --lifecycle-state ACTIVE \
        --all \
        --output json 2>/dev/null) || { echo -e "${RED}Failed to fetch OKE clusters${NC}"; return 1; }
    
    local -a clusters=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && clusters+=("$line")
    done < <(echo "$clusters_json" | jq -r '.data[] | "\(.name)|\(.id)|\(.["kubernetes-version"])"' 2>/dev/null)
    
    if [[ ${#clusters[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No active OKE clusters found in compartment${NC}"
        OKE_CLUSTER_ID=""
        OKE_CLUSTER_NAME=""
        return 0
    fi
    
    # If only one cluster, auto-select it
    if [[ ${#clusters[@]} -eq 1 ]]; then
        local single_cluster="${clusters[0]}"
        OKE_CLUSTER_NAME=$(echo "$single_cluster" | cut -d'|' -f1)
        OKE_CLUSTER_ID=$(echo "$single_cluster" | cut -d'|' -f2)
        local k8s_version=$(echo "$single_cluster" | cut -d'|' -f3)
        
        echo ""
        echo -e "${GREEN}Auto-selected (only cluster in compartment):${NC}"
        echo -e "  ${CYAN}Name:${NC}    ${WHITE}$OKE_CLUSTER_NAME${NC}"
        echo -e "  ${CYAN}Version:${NC} ${WHITE}$k8s_version${NC}"
        echo ""
        
        echo -n -e "${CYAN}Use this cluster? (y/n): ${NC}"
        read -r confirm
        
        if [[ ! "$confirm" =~ ^[Yy]$ && -n "$confirm" ]]; then
            echo -e "${YELLOW}Cluster selection skipped${NC}"
            OKE_CLUSTER_ID=""
            OKE_CLUSTER_NAME=""
            return 0
        fi
        
        echo -e "${GREEN}Selected: ${WHITE}$OKE_CLUSTER_NAME${NC}"
        fetch_cluster_network_info
        return 0
    fi
    
    # Multiple clusters - show selection
    echo ""
    printf "${BOLD}%-4s %-50s %-20s${NC}\n" "ID" "Cluster Name" "K8s Version"
    print_separator 80
    
    RESOURCE_MAP=()
    select_from_list "Select OKE Cluster:" clusters OKE_CLUSTER_ID true
    
    if [[ -n "$OKE_CLUSTER_ID" ]]; then
        OKE_CLUSTER_NAME=$(echo "$clusters_json" | jq -r --arg id "$OKE_CLUSTER_ID" '.data[] | select(.id == $id) | .name')
        echo -e "${GREEN}Selected: ${WHITE}$OKE_CLUSTER_NAME${NC}"
        
        # Fetch cluster details for VCN/subnet info
        fetch_cluster_network_info
    fi
}

#-------------------------------------------------------------------------------
# Fetch cluster network info
#-------------------------------------------------------------------------------
fetch_cluster_network_info() {
    if [[ -z "$OKE_CLUSTER_ID" ]]; then
        return
    fi
    
    echo -e "${YELLOW}Fetching cluster network configuration...${NC}"
    
    local cluster_json
    cluster_json=$(oci ce cluster get \
        --cluster-id "$OKE_CLUSTER_ID" \
        --auth instance_principal \
        --output json 2>/dev/null) || return 1
    
    VCN_ID=$(echo "$cluster_json" | jq -r '.data["vcn-id"] // empty')
    
    echo -e "${CYAN}VCN ID: ${WHITE}$VCN_ID${NC}"
}

#-------------------------------------------------------------------------------
# Fetch all subnets and NSGs once for efficiency
#-------------------------------------------------------------------------------
fetch_network_resources() {
    if [[ -z "${VCN_ID:-}" ]]; then
        echo -e "${YELLOW}No VCN detected. Network resources will need to be entered manually.${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}Fetching network resources from VCN...${NC}"
    
    # Fetch subnets
    SUBNETS_JSON=$(oci network subnet list \
        --compartment-id "$COMPARTMENT_ID" \
        --vcn-id "$VCN_ID" \
        --auth instance_principal \
        --all \
        --output json 2>/dev/null) || { echo -e "${RED}Failed to fetch subnets${NC}"; return 1; }
    
    # Fetch NSGs
    NSGS_JSON=$(oci network nsg list \
        --compartment-id "$COMPARTMENT_ID" \
        --vcn-id "$VCN_ID" \
        --auth instance_principal \
        --all \
        --output json 2>/dev/null) || { echo -e "${RED}Failed to fetch NSGs${NC}"; return 1; }
    
    echo -e "${GREEN}Network resources fetched${NC}"
    return 0
}

#-------------------------------------------------------------------------------
# Auto-detect and confirm network resources (subnets and NSGs)
#-------------------------------------------------------------------------------
select_network_resources() {
    print_section "Network Configuration (Subnets & NSGs)"
    
    if [[ -z "${VCN_ID:-}" ]]; then
        WORKER_SUBNET_ID=""
        WORKER_SUBNET_NSG_ID=""
        POD_SUBNET_ID=""
        POD_SUBNET_NSG_ID=""
        return 0
    fi
    
    # Fetch network resources
    fetch_network_resources || return 1
    
    # Auto-detect worker subnet (look for "worker" in name, case-insensitive)
    local worker_subnet_match
    worker_subnet_match=$(echo "$SUBNETS_JSON" | jq -r '.data[] | select(.["display-name"] | test("worker"; "i")) | "\(.["display-name"])|\(.id)|\(.["cidr-block"])"' 2>/dev/null | head -1)
    
    # Auto-detect pod subnet (look for "pod" in name, case-insensitive)
    local pod_subnet_match
    pod_subnet_match=$(echo "$SUBNETS_JSON" | jq -r '.data[] | select(.["display-name"] | test("pod"; "i")) | "\(.["display-name"])|\(.id)|\(.["cidr-block"])"' 2>/dev/null | head -1)
    
    # Auto-detect worker NSG (look for "worker" in name, case-insensitive)
    local worker_nsg_match
    worker_nsg_match=$(echo "$NSGS_JSON" | jq -r '.data[] | select(.["display-name"] | test("worker"; "i")) | "\(.["display-name"])|\(.id)"' 2>/dev/null | head -1)
    
    # Auto-detect pod NSG (look for "pod" in name, case-insensitive)
    local pod_nsg_match
    pod_nsg_match=$(echo "$NSGS_JSON" | jq -r '.data[] | select(.["display-name"] | test("pod"; "i")) | "\(.["display-name"])|\(.id)"' 2>/dev/null | head -1)
    
    # Extract IDs and names from matches
    local worker_subnet_name="" worker_subnet_cidr=""
    local pod_subnet_name="" pod_subnet_cidr=""
    local worker_nsg_name=""
    local pod_nsg_name=""
    
    if [[ -n "$worker_subnet_match" ]]; then
        worker_subnet_name=$(echo "$worker_subnet_match" | cut -d'|' -f1)
        WORKER_SUBNET_ID=$(echo "$worker_subnet_match" | cut -d'|' -f2)
        worker_subnet_cidr=$(echo "$worker_subnet_match" | cut -d'|' -f3)
    fi
    
    if [[ -n "$pod_subnet_match" ]]; then
        pod_subnet_name=$(echo "$pod_subnet_match" | cut -d'|' -f1)
        POD_SUBNET_ID=$(echo "$pod_subnet_match" | cut -d'|' -f2)
        pod_subnet_cidr=$(echo "$pod_subnet_match" | cut -d'|' -f3)
    fi
    
    if [[ -n "$worker_nsg_match" ]]; then
        worker_nsg_name=$(echo "$worker_nsg_match" | cut -d'|' -f1)
        WORKER_SUBNET_NSG_ID=$(echo "$worker_nsg_match" | cut -d'|' -f2)
    fi
    
    if [[ -n "$pod_nsg_match" ]]; then
        pod_nsg_name=$(echo "$pod_nsg_match" | cut -d'|' -f1)
        POD_SUBNET_NSG_ID=$(echo "$pod_nsg_match" | cut -d'|' -f2)
    fi
    
    # Display detected defaults
    echo ""
    echo -e "${BOLD}${WHITE}Auto-detected Network Configuration:${NC}"
    echo ""
    printf "${BOLD}%-20s %-45s %-18s${NC}\n" "Resource" "Name" "CIDR/ID"
    print_separator 90
    
    if [[ -n "$WORKER_SUBNET_ID" ]]; then
        printf "${GREEN}%-20s${NC} ${CYAN}%-45s${NC} ${GRAY}%-18s${NC}\n" "Worker Subnet" "$worker_subnet_name" "$worker_subnet_cidr"
    else
        printf "${YELLOW}%-20s${NC} ${GRAY}%-45s${NC}\n" "Worker Subnet" "(not detected)"
    fi
    
    if [[ -n "$WORKER_SUBNET_NSG_ID" ]]; then
        printf "${GREEN}%-20s${NC} ${CYAN}%-45s${NC}\n" "Worker NSG" "$worker_nsg_name"
    else
        printf "${YELLOW}%-20s${NC} ${GRAY}%-45s${NC}\n" "Worker NSG" "(not detected)"
    fi
    
    if [[ -n "$POD_SUBNET_ID" ]]; then
        printf "${GREEN}%-20s${NC} ${CYAN}%-45s${NC} ${GRAY}%-18s${NC}\n" "Pod Subnet" "$pod_subnet_name" "$pod_subnet_cidr"
    else
        printf "${YELLOW}%-20s${NC} ${GRAY}%-45s${NC}\n" "Pod Subnet" "(not detected)"
    fi
    
    if [[ -n "$POD_SUBNET_NSG_ID" ]]; then
        printf "${GREEN}%-20s${NC} ${CYAN}%-45s${NC}\n" "Pod NSG" "$pod_nsg_name"
    else
        printf "${YELLOW}%-20s${NC} ${GRAY}%-45s${NC}\n" "Pod NSG" "(not detected)"
    fi
    
    echo ""
    
    # Ask if user wants to modify
    echo -n -e "${CYAN}Use these network settings? (y/n/m to modify): ${NC}"
    read -r network_choice
    
    case "$network_choice" in
        [Nn])
            echo -e "${YELLOW}Skipping network configuration. Set manually later.${NC}"
            WORKER_SUBNET_ID=""
            WORKER_SUBNET_NSG_ID=""
            POD_SUBNET_ID=""
            POD_SUBNET_NSG_ID=""
            ;;
        [Mm])
            # Allow modification of each
            modify_network_resources
            ;;
        *)
            echo -e "${GREEN}Network configuration accepted${NC}"
            ;;
    esac
}

#-------------------------------------------------------------------------------
# Modify network resources interactively
#-------------------------------------------------------------------------------
modify_network_resources() {
    echo ""
    echo -e "${WHITE}Modify network resources (press Enter to keep current selection):${NC}"
    
    # Worker Subnet
    echo ""
    echo -e "${BOLD}${CYAN}Worker Subnet:${NC}"
    select_single_subnet "worker" WORKER_SUBNET_ID
    
    # Worker NSG
    echo ""
    echo -e "${BOLD}${CYAN}Worker NSG:${NC}"
    select_single_nsg "worker" WORKER_SUBNET_NSG_ID
    
    # Pod Subnet
    echo ""
    echo -e "${BOLD}${CYAN}Pod Subnet:${NC}"
    select_single_subnet "pod" POD_SUBNET_ID
    
    # Pod NSG
    echo ""
    echo -e "${BOLD}${CYAN}Pod NSG:${NC}"
    select_single_nsg "pod" POD_SUBNET_NSG_ID
}

#-------------------------------------------------------------------------------
# Select a single subnet
#-------------------------------------------------------------------------------
select_single_subnet() {
    local resource_type="$1"
    local -n result_var=$2
    
    local current_name=""
    if [[ -n "$result_var" ]]; then
        current_name=$(echo "$SUBNETS_JSON" | jq -r --arg id "$result_var" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        echo -e "  Current: ${GREEN}$current_name${NC}"
    else
        echo -e "  Current: ${YELLOW}(none)${NC}"
    fi
    
    # List available subnets
    local -a subnets=()
    local idx=1
    RESOURCE_MAP=()
    
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local name=$(echo "$line" | cut -d'|' -f1)
            local id=$(echo "$line" | cut -d'|' -f2)
            local cidr=$(echo "$line" | cut -d'|' -f3)
            
            printf "  ${YELLOW}%2d${NC}) ${CYAN}%-40s${NC} ${GRAY}%s${NC}\n" "$idx" "$name" "$cidr"
            RESOURCE_MAP[$idx]="$id"
            ((idx++))
        fi
    done < <(echo "$SUBNETS_JSON" | jq -r '.data[] | "\(.["display-name"])|\(.id)|\(.["cidr-block"])"' 2>/dev/null)
    
    echo -e "  ${GRAY} 0) Clear selection${NC}"
    echo -e "  ${GRAY}  ) Press Enter to keep current${NC}"
    
    echo -n -e "  ${WHITE}Select ${resource_type} subnet: ${NC}"
    read -r selection
    
    if [[ -z "$selection" ]]; then
        echo -e "  ${GREEN}Keeping current selection${NC}"
    elif [[ "$selection" == "0" ]]; then
        result_var=""
        echo -e "  ${YELLOW}Cleared${NC}"
    elif [[ -n "${RESOURCE_MAP[$selection]:-}" ]]; then
        result_var="${RESOURCE_MAP[$selection]}"
        local new_name=$(echo "$SUBNETS_JSON" | jq -r --arg id "$result_var" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        echo -e "  ${GREEN}Selected: $new_name${NC}"
    else
        echo -e "  ${RED}Invalid selection, keeping current${NC}"
    fi
}

#-------------------------------------------------------------------------------
# Select a single NSG
#-------------------------------------------------------------------------------
select_single_nsg() {
    local resource_type="$1"
    local -n result_var=$2
    
    local current_name=""
    if [[ -n "$result_var" ]]; then
        current_name=$(echo "$NSGS_JSON" | jq -r --arg id "$result_var" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        echo -e "  Current: ${GREEN}$current_name${NC}"
    else
        echo -e "  Current: ${YELLOW}(none)${NC}"
    fi
    
    # List available NSGs
    local idx=1
    RESOURCE_MAP=()
    
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local name=$(echo "$line" | cut -d'|' -f1)
            local id=$(echo "$line" | cut -d'|' -f2)
            
            printf "  ${YELLOW}%2d${NC}) ${CYAN}%-50s${NC}\n" "$idx" "$name"
            RESOURCE_MAP[$idx]="$id"
            ((idx++))
        fi
    done < <(echo "$NSGS_JSON" | jq -r '.data[] | "\(.["display-name"])|\(.id)"' 2>/dev/null)
    
    echo -e "  ${GRAY} 0) Clear selection${NC}"
    echo -e "  ${GRAY}  ) Press Enter to keep current${NC}"
    
    echo -n -e "  ${WHITE}Select ${resource_type} NSG: ${NC}"
    read -r selection
    
    if [[ -z "$selection" ]]; then
        echo -e "  ${GREEN}Keeping current selection${NC}"
    elif [[ "$selection" == "0" ]]; then
        result_var=""
        echo -e "  ${YELLOW}Cleared${NC}"
    elif [[ -n "${RESOURCE_MAP[$selection]:-}" ]]; then
        result_var="${RESOURCE_MAP[$selection]}"
        local new_name=$(echo "$NSGS_JSON" | jq -r --arg id "$result_var" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        echo -e "  ${GREEN}Selected: $new_name${NC}"
    else
        echo -e "  ${RED}Invalid selection, keeping current${NC}"
    fi
}

#-------------------------------------------------------------------------------
# Fetch and select Compute Cluster
#-------------------------------------------------------------------------------
select_compute_cluster() {
    print_section "Compute Cluster"
    
    echo -e "${YELLOW}Fetching compute clusters...${NC}"
    
    local clusters_json
    clusters_json=$(oci compute compute-cluster list \
        --compartment-id "$COMPARTMENT_ID" \
        --availability-domain "$AD" \
        --auth instance_principal \
        --all \
        --output json 2>/dev/null) || { echo -e "${RED}Failed to fetch compute clusters${NC}"; return 1; }
    
    local -a clusters=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && clusters+=("$line")
    done < <(echo "$clusters_json" | jq -r '.data.items[] | "\(.["display-name"])|\(.id)"' 2>/dev/null)
    
    if [[ ${#clusters[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No compute clusters found in AD${NC}"
        CC_ID=""
        return 0
    fi
    
    echo ""
    printf "${BOLD}%-4s %-60s${NC}\n" "ID" "Compute Cluster Name"
    print_separator 70
    
    RESOURCE_MAP=()
    select_from_list "Select Compute Cluster:" clusters CC_ID true
    
    if [[ -n "$CC_ID" ]]; then
        local cc_name
        cc_name=$(echo "$clusters_json" | jq -r --arg id "$CC_ID" '.data.items[] | select(.id == $id) | .["display-name"]')
        echo -e "${GREEN}Selected: ${WHITE}$cc_name${NC}"
    fi
}

#-------------------------------------------------------------------------------
# Fetch and select Instance Configuration
#-------------------------------------------------------------------------------
select_instance_configuration() {
    print_section "Instance Configuration"
    
    echo -e "${YELLOW}Fetching instance configurations...${NC}"
    
    local configs_json
    configs_json=$(oci compute-management instance-configuration list \
        --compartment-id "$COMPARTMENT_ID" \
        --auth instance_principal \
        --all \
        --output json 2>/dev/null) || { echo -e "${RED}Failed to fetch instance configurations${NC}"; return 1; }
    
    local -a configs=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && configs+=("$line")
    done < <(echo "$configs_json" | jq -r '.data[] | "\(.["display-name"])|\(.id)"' 2>/dev/null)
    
    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No instance configurations found${NC}"
        IC_ID=""
        return 0
    fi
    
    echo ""
    printf "${BOLD}%-4s %-60s${NC}\n" "ID" "Instance Configuration Name"
    print_separator 70
    
    RESOURCE_MAP=()
    select_from_list "Select Instance Configuration:" configs IC_ID true
    
    if [[ -n "$IC_ID" ]]; then
        local ic_name
        ic_name=$(echo "$configs_json" | jq -r --arg id "$IC_ID" '.data[] | select(.id == $id) | .["display-name"]')
        echo -e "${GREEN}Selected: ${WHITE}$ic_name${NC}"
    fi
}

#-------------------------------------------------------------------------------
# Fetch and select GPU Memory Fabric
#-------------------------------------------------------------------------------
select_gpu_memory_fabric() {
    # Fetch fabrics first to check if any exist
    local fabrics_json
    fabrics_json=$(oci compute compute-gpu-memory-fabric list \
        --compartment-id "$TENANCY_ID" \
        --auth instance_principal \
        --all \
        --output json 2>/dev/null) || { return 0; }
    
    # Filter to current region
    local -a fabrics=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && fabrics+=("$line")
    done < <(echo "$fabrics_json" | jq -r --arg region "$REGION" '.data.items[] | select(.id | contains($region)) | "\(.["display-name"])|\(.id)|\(.["lifecycle-state"]) avail=\(.["available-host-count"])/\(.["total-host-count"])"' 2>/dev/null)
    
    # Skip section entirely if no fabrics found
    if [[ ${#fabrics[@]} -eq 0 ]]; then
        GPU_MEMORY_FABRIC_ID=""
        return 0
    fi
    
    # Only show section if fabrics exist
    print_section "GPU Memory Fabric"
    
    echo -e "${CYAN}Found ${#fabrics[@]} GPU memory fabric(s) in region${NC}"
    echo ""
    printf "${BOLD}%-4s %-45s %-30s${NC}\n" "ID" "Fabric Name" "Status"
    print_separator 85
    
    RESOURCE_MAP=()
    select_from_list "Select GPU Memory Fabric:" fabrics GPU_MEMORY_FABRIC_ID true
    
    if [[ -n "$GPU_MEMORY_FABRIC_ID" ]]; then
        local fabric_name
        fabric_name=$(echo "$fabrics_json" | jq -r --arg id "$GPU_MEMORY_FABRIC_ID" '.data.items[] | select(.id == $id) | .["display-name"]')
        echo -e "${GREEN}Selected: ${WHITE}$fabric_name${NC}"
    fi
}

#-------------------------------------------------------------------------------
# Fetch and select Image (custom images only)
#-------------------------------------------------------------------------------
select_image() {
    print_section "Compute Image (Custom Images)"
    
    echo -e "${YELLOW}Fetching custom images in compartment...${NC}"
    
    # List only custom images (images where compartment-id matches our compartment)
    # Platform images have a different compartment-id (Oracle's)
    local images_json
    images_json=$(oci compute image list \
        --compartment-id "$COMPARTMENT_ID" \
        --auth instance_principal \
        --all \
        --lifecycle-state AVAILABLE \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --output json 2>/dev/null) || { echo -e "${RED}Failed to fetch images${NC}"; return 1; }
    
    # Filter to only custom images (compartment-id matches our compartment)
    local -a images=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && images+=("$line")
    done < <(echo "$images_json" | jq -r --arg comp "$COMPARTMENT_ID" '.data[] | select(.["compartment-id"] == $comp) | "\(.["display-name"][:60])|\(.id)|\(.["time-created"][:10])"' 2>/dev/null)
    
    if [[ ${#images[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No custom images found in compartment${NC}"
        echo -e "${GRAY}Note: Only custom images are shown, not platform images${NC}"
        IMAGE_ID=""
        return 0
    fi
    
    echo -e "${CYAN}Found ${#images[@]} custom image(s)${NC}"
    echo ""
    printf "${BOLD}%-4s %-60s %-12s${NC}\n" "ID" "Image Name" "Created"
    print_separator 80
    
    RESOURCE_MAP=()
    select_from_list "Select Image:" images IMAGE_ID true
    
    if [[ -n "$IMAGE_ID" ]]; then
        local image_name
        image_name=$(echo "$images_json" | jq -r --arg id "$IMAGE_ID" '.data[] | select(.id == $id) | .["display-name"]')
        echo -e "${GREEN}Selected: ${WHITE}$image_name${NC}"
    fi
}

#-------------------------------------------------------------------------------
# Display summary and output configuration
#-------------------------------------------------------------------------------
display_summary() {
    print_header "Configuration Summary"
    
    echo ""
    echo -e "${BOLD}${WHITE}Base Environment (from IMDS):${NC}"
    echo -e "  ${CYAN}Region:${NC}              $REGION"
    echo -e "  ${CYAN}Tenancy ID:${NC}          $TENANCY_ID"
    echo -e "  ${CYAN}Compartment ID:${NC}      $COMPARTMENT_ID"
    echo -e "  ${CYAN}Availability Domain:${NC} $AD"
    
    echo ""
    echo -e "${BOLD}${WHITE}Selected Resources:${NC}"
    echo -e "  ${CYAN}OKE Cluster:${NC}         ${OKE_CLUSTER_ID:-${YELLOW}Not selected${NC}}"
    echo -e "  ${CYAN}Worker Subnet:${NC}       ${WORKER_SUBNET_ID:-${YELLOW}Not selected${NC}}"
    echo -e "  ${CYAN}Worker NSG:${NC}          ${WORKER_SUBNET_NSG_ID:-${YELLOW}Not selected${NC}}"
    echo -e "  ${CYAN}Pod Subnet:${NC}          ${POD_SUBNET_ID:-${YELLOW}Not selected${NC}}"
    echo -e "  ${CYAN}Pod NSG:${NC}             ${POD_SUBNET_NSG_ID:-${YELLOW}Not selected${NC}}"
    echo -e "  ${CYAN}Compute Cluster:${NC}     ${CC_ID:-${YELLOW}Not selected${NC}}"
    echo -e "  ${CYAN}Instance Config:${NC}     ${IC_ID:-${YELLOW}Not selected${NC}}"
    echo -e "  ${CYAN}GPU Memory Fabric:${NC}   ${GPU_MEMORY_FABRIC_ID:-${YELLOW}Not selected${NC}}"
    echo -e "  ${CYAN}Image:${NC}               ${IMAGE_ID:-${YELLOW}Not selected${NC}}"
}

#-------------------------------------------------------------------------------
# Output configuration file
#-------------------------------------------------------------------------------
output_config_file() {
    local output_file="${1:-variables.sh}"
    
    cat > "$output_file" <<EOF
#!/bin/bash
#===============================================================================
# OCI Environment Configuration
# Auto-generated on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Instance: ${DISPLAY_NAME:-unknown}
#===============================================================================

# Tenancy Variables (populated from IMDS)
REGION="${REGION}"
TENANCY_ID="${TENANCY_ID}"

# Compartment where the OKE Cluster and worker nodes will be created
COMPARTMENT_ID="${COMPARTMENT_ID}"

# OCI AD name for the region used
AD="${AD}"

# OKE Cluster
OKE_CLUSTER_ID="${OKE_CLUSTER_ID:-}"
CLUSTER_NAME="${OKE_CLUSTER_NAME:-}"

# OKE Worker and POD Subnets
WORKER_SUBNET_ID="${WORKER_SUBNET_ID:-}"
WORKER_SUBNET_NSG_ID="${WORKER_SUBNET_NSG_ID:-}"
POD_SUBNET_ID="${POD_SUBNET_ID:-}"
POD_SUBNET_NSG_ID="${POD_SUBNET_NSG_ID:-}"

# Image to be used for the OKE Cluster / Worker Nodes
IMAGE_ID="${IMAGE_ID:-}"

# Shape for GPU nodes
SHAPE_NAME="BM.GPU.GB200-v3.4"

# Display names for new resources
INSTANCE_CONFIG_DISPLAY_NAME="GB200-OKE-Worker-Config"
COMPUTE_CLUSTER_DISPLAY_NAME="GB200-OKE-Compute-Cluster"

# Compute Cluster OCID
CC_ID="${CC_ID:-}"

# Instance Configuration to use OCID
IC_ID="${IC_ID:-}"

# GPU Memory Fabric ID
GPU_MEMORY_FABRIC_ID="${GPU_MEMORY_FABRIC_ID:-}"

# GPU Memory Fabric Cluster size (GB200 typically 18)
GPU_MEMORY_CLUSTER_SIZE=18

# Instance filter for listing: "gpu", "non-gpu", or "all"
# gpu     = Only show GPU instances (BM.GPU.*)
# non-gpu = Only show non-GPU instances  
# all     = Show all instances
INSTANCE_FILTER="gpu"
EOF

    chmod +x "$output_file"
    echo -e "${GREEN}Configuration saved to: ${WHITE}$output_file${NC}"
}

#-------------------------------------------------------------------------------
# Interactive mode
#-------------------------------------------------------------------------------
run_interactive() {
    print_header "OCI Environment Setup - Interactive Mode"
    
    # Check prerequisites
    if ! curl -sS -H "$IMDS_HEADER" "${IMDS_BASE}/instance/" -o /dev/null 2>/dev/null; then
        echo -e "${RED}ERROR: Not running on an OCI instance or IMDS not available${NC}" >&2
        exit 1
    fi
    
    wait_for_imds || exit 1
    fetch_metadata || exit 1
    check_oci_cli || exit 1
    
    echo ""
    echo -e "${WHITE}Base environment detected:${NC}"
    echo -e "  Region: ${CYAN}$REGION${NC}"
    echo -e "  Compartment: ${CYAN}${COMPARTMENT_ID:0:50}...${NC}"
    echo -e "  AD: ${CYAN}$AD${NC}"
    
    # Initialize optional variables
    OKE_CLUSTER_ID=""
    OKE_CLUSTER_NAME=""
    VCN_ID=""
    WORKER_SUBNET_ID=""
    WORKER_SUBNET_NSG_ID=""
    POD_SUBNET_ID=""
    POD_SUBNET_NSG_ID=""
    CC_ID=""
    IC_ID=""
    GPU_MEMORY_FABRIC_ID=""
    IMAGE_ID=""
    SUBNETS_JSON=""
    NSGS_JSON=""
    
    # Check for existing configuration
    local imported_config=false
    if [[ -f "variables.sh" ]]; then
        echo ""
        print_separator 80
        echo ""
        echo -n -e "${CYAN}Import existing configuration from variables.sh? (y/n): ${NC}"
        read -r import_choice
        
        if [[ "$import_choice" =~ ^[Yy]$ || -z "$import_choice" ]]; then
            if import_existing_config "variables.sh"; then
                imported_config=true
                echo ""
                echo -n -e "${CYAN}Fill in empty values only? (y) or reconfigure all? (n): ${NC}"
                read -r fill_empty_choice
                
                if [[ "$fill_empty_choice" =~ ^[Nn]$ ]]; then
                    imported_config=false  # Reconfigure everything
                fi
            fi
        fi
    fi
    
    # Run selections based on whether we imported config
    if [[ "$imported_config" == "true" ]]; then
        # Only select resources that are empty
        run_selective_setup
    else
        # Full setup
        run_full_setup
    fi
    
    # Display summary
    display_summary
    
    # Save configuration - default to variables.sh
    echo ""
    echo -e "${WHITE}Save configuration to file${NC}"
    echo -n -e "${CYAN}Enter filename [variables.sh] (or 'n' to skip): ${NC}"
    read -r filename
    
    if [[ "$filename" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}Configuration not saved to file${NC}"
    else
        filename="${filename:-variables.sh}"
        output_config_file "$filename"
    fi
    
    echo ""
    echo -e "${GREEN}Setup complete!${NC}"
}

#-------------------------------------------------------------------------------
# Run full setup (all selections)
#-------------------------------------------------------------------------------
run_full_setup() {
    select_oke_cluster
    select_network_resources
    select_compute_cluster
    select_instance_configuration
    select_gpu_memory_fabric
    select_image
}

#-------------------------------------------------------------------------------
# Run selective setup (only empty values)
#-------------------------------------------------------------------------------
run_selective_setup() {
    # OKE Cluster - if empty or no VCN
    if [[ -z "$OKE_CLUSTER_ID" ]]; then
        select_oke_cluster
    else
        echo ""
        echo -e "${GREEN}✓ OKE Cluster already set:${NC} ${WHITE}${OKE_CLUSTER_NAME:-$OKE_CLUSTER_ID}${NC}"
        # Still need to fetch VCN info for network resources
        fetch_cluster_network_info
    fi
    
    # Network resources - check if any are empty
    if [[ -z "$WORKER_SUBNET_ID" || -z "$WORKER_SUBNET_NSG_ID" || -z "$POD_SUBNET_ID" || -z "$POD_SUBNET_NSG_ID" ]]; then
        select_network_resources_selective
    else
        echo -e "${GREEN}✓ Network resources already set${NC}"
    fi
    
    # Compute Cluster
    if [[ -z "$CC_ID" ]]; then
        select_compute_cluster
    else
        echo -e "${GREEN}✓ Compute Cluster already set:${NC} ${WHITE}${CC_ID:0:50}...${NC}"
    fi
    
    # Instance Configuration
    if [[ -z "$IC_ID" ]]; then
        select_instance_configuration
    else
        echo -e "${GREEN}✓ Instance Configuration already set:${NC} ${WHITE}${IC_ID:0:50}...${NC}"
    fi
    
    # GPU Memory Fabric
    if [[ -z "$GPU_MEMORY_FABRIC_ID" ]]; then
        select_gpu_memory_fabric
    else
        echo -e "${GREEN}✓ GPU Memory Fabric already set:${NC} ${WHITE}${GPU_MEMORY_FABRIC_ID:0:50}...${NC}"
    fi
    
    # Image
    if [[ -z "$IMAGE_ID" ]]; then
        select_image
    else
        echo -e "${GREEN}✓ Image already set:${NC} ${WHITE}${IMAGE_ID:0:50}...${NC}"
    fi
}

#-------------------------------------------------------------------------------
# Select network resources - selective mode (only empty values)
#-------------------------------------------------------------------------------
select_network_resources_selective() {
    print_section "Network Configuration (Subnets & NSGs)"
    
    if [[ -z "${VCN_ID:-}" ]]; then
        echo -e "${YELLOW}No VCN detected. Network resources will need to be entered manually.${NC}"
        return 0
    fi
    
    # Fetch network resources
    fetch_network_resources || return 1
    
    # Show current status
    echo -e "${BOLD}${WHITE}Current Network Configuration:${NC}"
    echo ""
    
    local worker_subnet_name="" pod_subnet_name="" worker_nsg_name="" pod_nsg_name=""
    
    if [[ -n "$WORKER_SUBNET_ID" ]]; then
        worker_subnet_name=$(echo "$SUBNETS_JSON" | jq -r --arg id "$WORKER_SUBNET_ID" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        printf "  ${GREEN}✓${NC} ${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Worker Subnet:" "$worker_subnet_name"
    else
        printf "  ${YELLOW}○${NC} ${CYAN}%-20s${NC} ${GRAY}(needs selection)${NC}\n" "Worker Subnet:"
    fi
    
    if [[ -n "$WORKER_SUBNET_NSG_ID" ]]; then
        worker_nsg_name=$(echo "$NSGS_JSON" | jq -r --arg id "$WORKER_SUBNET_NSG_ID" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        printf "  ${GREEN}✓${NC} ${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Worker NSG:" "$worker_nsg_name"
    else
        printf "  ${YELLOW}○${NC} ${CYAN}%-20s${NC} ${GRAY}(needs selection)${NC}\n" "Worker NSG:"
    fi
    
    if [[ -n "$POD_SUBNET_ID" ]]; then
        pod_subnet_name=$(echo "$SUBNETS_JSON" | jq -r --arg id "$POD_SUBNET_ID" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        printf "  ${GREEN}✓${NC} ${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Pod Subnet:" "$pod_subnet_name"
    else
        printf "  ${YELLOW}○${NC} ${CYAN}%-20s${NC} ${GRAY}(needs selection)${NC}\n" "Pod Subnet:"
    fi
    
    if [[ -n "$POD_SUBNET_NSG_ID" ]]; then
        pod_nsg_name=$(echo "$NSGS_JSON" | jq -r --arg id "$POD_SUBNET_NSG_ID" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        printf "  ${GREEN}✓${NC} ${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Pod NSG:" "$pod_nsg_name"
    else
        printf "  ${YELLOW}○${NC} ${CYAN}%-20s${NC} ${GRAY}(needs selection)${NC}\n" "Pod NSG:"
    fi
    
    echo ""
    
    # Only select empty values
    if [[ -z "$WORKER_SUBNET_ID" ]]; then
        echo -e "${BOLD}${CYAN}Select Worker Subnet:${NC}"
        select_single_subnet "worker" WORKER_SUBNET_ID
    fi
    
    if [[ -z "$WORKER_SUBNET_NSG_ID" ]]; then
        echo -e "${BOLD}${CYAN}Select Worker NSG:${NC}"
        select_single_nsg "worker" WORKER_SUBNET_NSG_ID
    fi
    
    if [[ -z "$POD_SUBNET_ID" ]]; then
        echo -e "${BOLD}${CYAN}Select Pod Subnet:${NC}"
        select_single_subnet "pod" POD_SUBNET_ID
    fi
    
    if [[ -z "$POD_SUBNET_NSG_ID" ]]; then
        echo -e "${BOLD}${CYAN}Select Pod NSG:${NC}"
        select_single_nsg "pod" POD_SUBNET_NSG_ID
    fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    local mode="${1:-interactive}"
    
    case "$mode" in
        --export|-e)
            wait_for_imds || exit 1
            fetch_metadata || exit 1
            echo "export REGION=\"$REGION\""
            echo "export TENANCY_ID=\"$TENANCY_ID\""
            echo "export COMPARTMENT_ID=\"$COMPARTMENT_ID\""
            echo "export AD=\"$AD\""
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  (none)      Interactive mode - select resources interactively"
            echo "  --export    Output export commands for basic variables"
            echo "  --help      Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                              # Interactive selection"
            echo "  source <($0 --export)           # Set basic variables"
            echo "  source $0                       # Source basic variables"
            ;;
        interactive|--interactive|-i|*)
            run_interactive
            ;;
    esac
}

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
else
    # Being sourced - just set the basic variables
    if curl -sS -H "$IMDS_HEADER" "${IMDS_BASE}/instance/" -o /dev/null 2>/dev/null; then
        wait_for_imds && fetch_metadata && {
            export REGION TENANCY_ID COMPARTMENT_ID AD
            echo "OCI variables set: REGION=$REGION COMPARTMENT_ID=${COMPARTMENT_ID:0:30}..."
        }
    else
        echo "WARNING: IMDS not available, variables not set" >&2
    fi
fi