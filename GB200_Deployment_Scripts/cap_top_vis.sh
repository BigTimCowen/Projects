#!/bin/bash
#
# list_capacity_topology_tree.sh - Capacity Topology Visualization Tool
#
# Description:
#   Displays OCI Compute Capacity Topology in a hierarchical tree view showing
#   HPC Islands, Network Blocks, and Bare Metal Hosts with their states.
#
# Dependencies:
#   - oci CLI (configured)
#   - jq (JSON processor)
#
# Usage:
#   ./list_capacity_topology_tree.sh [OPTIONS]
#
# Options:
#   --summary           Show summary counts only (no tree)
#   --hosts             Show bare metal hosts in tree (default: hidden for large topologies)
#   --state <STATE>     Filter hosts by lifecycle state (ACTIVE, INACTIVE, etc.)
#   --instance <OCID>   Find specific instance in topology
#   --export <file>     Export topology data to JSON file
#   --help              Show this help message
#
# Configuration:
#   Requires variables.sh with TENANCY_ID
#
# Author: GPU Infrastructure Team
# Version: 1.0
#

set -o pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly LIGHT_GREEN='\033[92m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly ORANGE='\033[38;5;208m'
readonly GRAY='\033[0;90m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Script directory
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CACHE_DIR="${SCRIPT_DIR}/cache"

# Cache files
readonly TOPOLOGY_CACHE="${CACHE_DIR}/capacity_topology.json"
readonly HPC_ISLANDS_CACHE="${CACHE_DIR}/hpc_islands.json"
readonly NETWORK_BLOCKS_CACHE="${CACHE_DIR}/network_blocks.json"
readonly BARE_METAL_HOSTS_CACHE="${CACHE_DIR}/bare_metal_hosts.json"

# Cache age (15 minutes = 900 seconds, matching OCI refresh rate)
readonly CACHE_MAX_AGE=900

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_info() {
    echo "$1" >&2
}

is_cache_fresh() {
    local cache_file="$1"
    [[ ! -f "$cache_file" ]] && return 1
    local file_mtime
    file_mtime=$(stat -c %Y "$cache_file" 2>/dev/null) || return 1
    local current_time
    current_time=$(date +%s)
    local cache_age=$((current_time - file_mtime))
    [[ $cache_age -lt $CACHE_MAX_AGE ]]
}

# Get color for lifecycle state
color_lifecycle_state() {
    case "$1" in
        ACTIVE|AVAILABLE)   echo "$GREEN" ;;
        INACTIVE)           echo "$YELLOW" ;;
        DELETED|DELETING)   echo "$RED" ;;
        CREATING|UPDATING)  echo "$CYAN" ;;
        *)                  echo "$WHITE" ;;
    esac
}

# Helper to extract array from JSON (handles .data.items, .data, or root array)
get_json_array() {
    local file="$1"
    local result
    
    # Try .data.items first
    result=$(jq -e '.data.items' "$file" 2>/dev/null)
    if [[ $? -eq 0 && "$result" != "null" ]]; then
        echo "$result"
        return 0
    fi
    
    # Try .data (as array)
    result=$(jq -e '.data | if type == "array" then . else empty end' "$file" 2>/dev/null)
    if [[ $? -eq 0 && -n "$result" ]]; then
        echo "$result"
        return 0
    fi
    
    # Try root level array
    result=$(jq -e 'if type == "array" then . else empty end' "$file" 2>/dev/null)
    if [[ $? -eq 0 && -n "$result" ]]; then
        echo "$result"
        return 0
    fi
    
    echo "[]"
}

# Print separator line
print_separator() {
    local width="${1:-80}"
    echo -e "${BLUE}$(printf '━%.0s' $(seq 1 "$width"))${NC}"
}

#===============================================================================
# DATA FETCH FUNCTIONS
#===============================================================================

# Fetch capacity topology ID
fetch_capacity_topology() {
    [[ -z "$TENANCY_ID" ]] && { log_error "TENANCY_ID not set"; return 1; }
    
    if is_cache_fresh "$TOPOLOGY_CACHE"; then
        return 0
    fi
    
    log_info "Fetching capacity topology..."
    
    oci compute capacity-topology list \
        --compartment-id "$TENANCY_ID" \
        --all \
        --output json > "$TOPOLOGY_CACHE" 2>/dev/null
    
    if [[ ! -s "$TOPOLOGY_CACHE" ]]; then
        log_error "Failed to fetch capacity topology"
        return 1
    fi
}

# Get the first capacity topology ID
get_topology_id() {
    # Try multiple possible structures
    local id
    id=$(jq -r '.data.items[0].id // empty' "$TOPOLOGY_CACHE" 2>/dev/null)
    [[ -z "$id" ]] && id=$(jq -r '.data[0].id // empty' "$TOPOLOGY_CACHE" 2>/dev/null)
    [[ -z "$id" ]] && id=$(jq -r '.[0].id // empty' "$TOPOLOGY_CACHE" 2>/dev/null)
    echo "$id"
}

# Fetch HPC islands
fetch_hpc_islands() {
    local topology_id="$1"
    [[ -z "$topology_id" ]] && return 1
    
    if is_cache_fresh "$HPC_ISLANDS_CACHE"; then
        return 0
    fi
    
    log_info "Fetching HPC islands..."
    
    oci compute capacity-topology hpc-island list \
        --capacity-topology-id "$topology_id" \
        --all \
        --output json > "$HPC_ISLANDS_CACHE" 2>/dev/null
    
    [[ ! -s "$HPC_ISLANDS_CACHE" ]] && touch "$HPC_ISLANDS_CACHE"
}

# Fetch network blocks
fetch_network_blocks() {
    local topology_id="$1"
    [[ -z "$topology_id" ]] && return 1
    
    if is_cache_fresh "$NETWORK_BLOCKS_CACHE"; then
        return 0
    fi
    
    log_info "Fetching network blocks..."
    
    oci compute capacity-topology network-block list \
        --capacity-topology-id "$topology_id" \
        --all \
        --output json > "$NETWORK_BLOCKS_CACHE" 2>/dev/null
    
    [[ ! -s "$NETWORK_BLOCKS_CACHE" ]] && touch "$NETWORK_BLOCKS_CACHE"
}

# Fetch bare metal hosts
fetch_bare_metal_hosts() {
    local topology_id="$1"
    [[ -z "$topology_id" ]] && return 1
    
    if is_cache_fresh "$BARE_METAL_HOSTS_CACHE"; then
        return 0
    fi
    
    log_info "Fetching bare metal hosts..."
    
    oci compute capacity-topology bare-metal-host list \
        --capacity-topology-id "$topology_id" \
        --all \
        --output json > "$BARE_METAL_HOSTS_CACHE" 2>/dev/null
    
    [[ ! -s "$BARE_METAL_HOSTS_CACHE" ]] && touch "$BARE_METAL_HOSTS_CACHE"
}

# Fetch all capacity topology data
fetch_all_topology_data() {
    fetch_capacity_topology || return 1
    
    local topology_id
    topology_id=$(get_topology_id)
    
    if [[ -z "$topology_id" ]]; then
        log_error "No capacity topology found in tenancy"
        return 1
    fi
    
    fetch_hpc_islands "$topology_id"
    fetch_network_blocks "$topology_id"
    fetch_bare_metal_hosts "$topology_id"
    
    return 0
}

#===============================================================================
# DISPLAY FUNCTIONS
#===============================================================================

# Display topology summary
display_summary() {
    local topology_id
    topology_id=$(get_topology_id)
    
    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║                      CAPACITY TOPOLOGY SUMMARY                               ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Topology info
    local topology_name topology_ad
    topology_name=$(jq -r '.data.items[0]["display-name"] // .data[0]["display-name"] // .[0]["display-name"] // "N/A"' "$TOPOLOGY_CACHE" 2>/dev/null)
    topology_ad=$(jq -r '.data.items[0]["availability-domain"] // .data[0]["availability-domain"] // .[0]["availability-domain"] // "N/A"' "$TOPOLOGY_CACHE" 2>/dev/null)
    
    echo -e "${BOLD}${CYAN}Topology:${NC} ${WHITE}$topology_name${NC}"
    echo -e "${BOLD}${CYAN}AD:${NC}       ${WHITE}$topology_ad${NC}"
    echo -e "${BOLD}${CYAN}ID:${NC}       ${YELLOW}$topology_id${NC}"
    echo ""
    
    # Count HPC islands
    local island_count=0
    if [[ -f "$HPC_ISLANDS_CACHE" ]]; then
        local islands_arr
        islands_arr=$(get_json_array "$HPC_ISLANDS_CACHE")
        island_count=$(echo "$islands_arr" | jq 'length' 2>/dev/null) || island_count=0
    fi
    
    # Count network blocks
    local block_count=0
    if [[ -f "$NETWORK_BLOCKS_CACHE" ]]; then
        local blocks_arr
        blocks_arr=$(get_json_array "$NETWORK_BLOCKS_CACHE")
        block_count=$(echo "$blocks_arr" | jq 'length' 2>/dev/null) || block_count=0
    fi
    
    # Count and categorize bare metal hosts
    local total_hosts=0 active_hosts=0 inactive_hosts=0 other_hosts=0
    local hosts_with_instance=0 hosts_without_instance=0 unassigned_hosts=0
    if [[ -f "$BARE_METAL_HOSTS_CACHE" ]]; then
        local hosts_arr
        hosts_arr=$(get_json_array "$BARE_METAL_HOSTS_CACHE")
        total_hosts=$(echo "$hosts_arr" | jq 'length' 2>/dev/null) || total_hosts=0
        active_hosts=$(echo "$hosts_arr" | jq '[.[] | select(.["lifecycle-state"]=="ACTIVE")] | length' 2>/dev/null) || active_hosts=0
        inactive_hosts=$(echo "$hosts_arr" | jq '[.[] | select(.["lifecycle-state"]=="INACTIVE")] | length' 2>/dev/null) || inactive_hosts=0
        other_hosts=$((total_hosts - active_hosts - inactive_hosts))
        hosts_with_instance=$(echo "$hosts_arr" | jq '[.[] | select(.["instance-id"] != null)] | length' 2>/dev/null) || hosts_with_instance=0
        hosts_without_instance=$((total_hosts - hosts_with_instance))
        unassigned_hosts=$(echo "$hosts_arr" | jq '[.[] | select(.["compute-network-block-id"] == null)] | length' 2>/dev/null) || unassigned_hosts=0
    fi
    
    print_separator 80
    echo -e "${BOLD}${WHITE}Resource Counts:${NC}"
    echo ""
    printf "  ${CYAN}%-25s${NC} ${WHITE}%6d${NC}\n" "HPC Islands:" "$island_count"
    printf "  ${CYAN}%-25s${NC} ${WHITE}%6d${NC}\n" "Network Blocks:" "$block_count"
    printf "  ${CYAN}%-25s${NC} ${WHITE}%6d${NC}\n" "Bare Metal Hosts:" "$total_hosts"
    echo ""
    
    print_separator 80
    echo -e "${BOLD}${WHITE}Host Status:${NC}"
    echo ""
    printf "  ${GREEN}%-25s${NC} ${WHITE}%6d${NC}  ${GRAY}(%5.1f%%)${NC}\n" "Active:" "$active_hosts" "$(echo "scale=1; $active_hosts * 100 / $total_hosts" | bc 2>/dev/null || echo "0")"
    printf "  ${YELLOW}%-25s${NC} ${WHITE}%6d${NC}  ${GRAY}(%5.1f%%)${NC}\n" "Inactive:" "$inactive_hosts" "$(echo "scale=1; $inactive_hosts * 100 / $total_hosts" | bc 2>/dev/null || echo "0")"
    if [[ $other_hosts -gt 0 ]]; then
        printf "  ${RED}%-25s${NC} ${WHITE}%6d${NC}  ${GRAY}(%5.1f%%)${NC}\n" "Other:" "$other_hosts" "$(echo "scale=1; $other_hosts * 100 / $total_hosts" | bc 2>/dev/null || echo "0")"
    fi
    echo ""
    
    print_separator 80
    echo -e "${BOLD}${WHITE}Instance Allocation:${NC}"
    echo ""
    printf "  ${GREEN}%-25s${NC} ${WHITE}%6d${NC}  ${GRAY}(%5.1f%%)${NC}\n" "With Instance:" "$hosts_with_instance" "$(echo "scale=1; $hosts_with_instance * 100 / $total_hosts" | bc 2>/dev/null || echo "0")"
    printf "  ${YELLOW}%-25s${NC} ${WHITE}%6d${NC}  ${GRAY}(%5.1f%%)${NC}\n" "Without Instance:" "$hosts_without_instance" "$(echo "scale=1; $hosts_without_instance * 100 / $total_hosts" | bc 2>/dev/null || echo "0")"
    echo ""
    
    if [[ $unassigned_hosts -gt 0 ]]; then
        print_separator 80
        echo -e "${BOLD}${WHITE}Network Block Assignment:${NC}"
        echo ""
        printf "  ${GREEN}%-25s${NC} ${WHITE}%6d${NC}  ${GRAY}(%5.1f%%)${NC}\n" "In Network Block:" "$((total_hosts - unassigned_hosts))" "$(echo "scale=1; ($total_hosts - $unassigned_hosts) * 100 / $total_hosts" | bc 2>/dev/null || echo "0")"
        printf "  ${YELLOW}%-25s${NC} ${WHITE}%6d${NC}  ${GRAY}(%5.1f%%)${NC}\n" "Unassigned:" "$unassigned_hosts" "$(echo "scale=1; $unassigned_hosts * 100 / $total_hosts" | bc 2>/dev/null || echo "0")"
        echo ""
    fi
    
    echo -e "${GRAY}Note: Capacity topology data refreshes every 15 minutes${NC}"
    echo ""
}

# Display topology tree
display_tree() {
    local show_hosts="$1"
    local filter_state="$2"
    
    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║                      CAPACITY TOPOLOGY TREE                                  ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Get topology info
    local topology_name topology_id
    topology_name=$(jq -r '.data.items[0]["display-name"] // .data[0]["display-name"] // .[0]["display-name"] // "Capacity Topology"' "$TOPOLOGY_CACHE" 2>/dev/null)
    topology_id=$(get_topology_id)
    
    echo -e "${BOLD}${WHITE}📊 ${topology_name}${NC} ${GRAY}(${topology_id})${NC}"
    
    # Get HPC islands as array
    local islands_arr
    islands_arr=$(get_json_array "$HPC_ISLANDS_CACHE")
    
    local island_count
    island_count=$(echo "$islands_arr" | jq 'length' 2>/dev/null) || island_count=0
    
    if [[ "$island_count" -eq 0 ]]; then
        echo -e "   ${YELLOW}└── No HPC islands found${NC}"
        return
    fi
    
    # Get network blocks and hosts arrays
    local blocks_arr hosts_arr
    blocks_arr=$(get_json_array "$NETWORK_BLOCKS_CACHE")
    hosts_arr=$(get_json_array "$BARE_METAL_HOSTS_CACHE")
    
    # Save to temp files to avoid subshell issues
    local islands_tmp blocks_tmp hosts_tmp
    islands_tmp=$(mktemp)
    blocks_tmp=$(mktemp)
    hosts_tmp=$(mktemp)
    
    echo "$islands_arr" > "$islands_tmp"
    echo "$blocks_arr" > "$blocks_tmp"
    echo "$hosts_arr" > "$hosts_tmp"
    
    local island_idx=0
    
    # Iterate through islands using process substitution
    while IFS= read -r island_b64; do
        [[ -z "$island_b64" ]] && continue
        ((island_idx++))
        
        local island_id island_state island_total island_compute
        island_id=$(echo "$island_b64" | base64 -d | jq -r '.id')
        island_state=$(echo "$island_b64" | base64 -d | jq -r '.["lifecycle-state"] // "UNKNOWN"')
        island_total=$(echo "$island_b64" | base64 -d | jq -r '.["total-compute-bare-metal-host-count"] // .["total-host-count"] // 0')
        island_compute=$(echo "$island_b64" | base64 -d | jq -r '.["compute-bare-metal-host-count"] // .["compute-host-count"] // 0')
        
        local island_prefix="├──"
        local island_child_prefix="│   "
        [[ $island_idx -eq $island_count ]] && island_prefix="└──" && island_child_prefix="    "
        
        local state_color
        state_color=$(color_lifecycle_state "$island_state")
        
        # Extract short ID (last part after the last dot)
        local island_short="${island_id##*.}"
        
        echo -e "   ${island_prefix} ${BOLD}${ORANGE}🏝️  HPC Island:${NC} ${WHITE}${island_short}${NC} ${state_color}[${island_state}]${NC} ${CYAN}(Total: ${island_total}, Compute: ${island_compute})${NC}"
        
        # Get network blocks for this island
        local blocks_for_island
        blocks_for_island=$(jq -r --arg island "$island_id" '.[] | select(.["compute-hpc-island-id"] == $island) | @base64' "$blocks_tmp" 2>/dev/null)
        
        if [[ -z "$blocks_for_island" ]]; then
            echo -e "   ${island_child_prefix}└── ${YELLOW}No network blocks${NC}"
            continue
        fi
        
        local block_count_for_island
        block_count_for_island=$(echo "$blocks_for_island" | grep -c .)
        local block_idx=0
        
        while IFS= read -r block_b64; do
            [[ -z "$block_b64" ]] && continue
            ((block_idx++))
            
            local block_id block_state block_total block_compute
            block_id=$(echo "$block_b64" | base64 -d | jq -r '.id')
            block_state=$(echo "$block_b64" | base64 -d | jq -r '.["lifecycle-state"] // "UNKNOWN"')
            block_total=$(echo "$block_b64" | base64 -d | jq -r '.["total-compute-bare-metal-host-count"] // .["total-host-count"] // 0')
            block_compute=$(echo "$block_b64" | base64 -d | jq -r '.["compute-bare-metal-host-count"] // .["compute-host-count"] // 0')
            
            local block_prefix="├──"
            local block_child_prefix="│   "
            [[ $block_idx -eq $block_count_for_island ]] && block_prefix="└──" && block_child_prefix="    "
            
            local block_state_color
            block_state_color=$(color_lifecycle_state "$block_state")
            
            local block_short="${block_id##*.}"
            
            echo -e "   ${island_child_prefix}${block_prefix} ${BOLD}${BLUE}🔲 Network Block:${NC} ${WHITE}${block_short}${NC} ${block_state_color}[${block_state}]${NC} ${CYAN}(Total: ${block_total}, Compute: ${block_compute})${NC}"
            
            # Show hosts if requested
            if [[ "$show_hosts" == "true" ]]; then
                local hosts_for_block
                if [[ -n "$filter_state" ]]; then
                    hosts_for_block=$(jq -r --arg block "$block_id" --arg state "$filter_state" \
                        '.[] | select(.["compute-network-block-id"] == $block and .["lifecycle-state"] == $state) | @base64' "$hosts_tmp" 2>/dev/null)
                else
                    hosts_for_block=$(jq -r --arg block "$block_id" \
                        '.[] | select(.["compute-network-block-id"] == $block) | @base64' "$hosts_tmp" 2>/dev/null)
                fi
                
                if [[ -z "$hosts_for_block" ]]; then
                    local filter_msg=""
                    [[ -n "$filter_state" ]] && filter_msg=" (filtered by $filter_state)"
                    echo -e "   ${island_child_prefix}${block_child_prefix}└── ${GRAY}No hosts${filter_msg}${NC}"
                    continue
                fi
                
                local host_count_for_block
                host_count_for_block=$(echo "$hosts_for_block" | grep -c .)
                local host_idx=0
                
                while IFS= read -r host_b64; do
                    [[ -z "$host_b64" ]] && continue
                    ((host_idx++))
                    
                    local host_id host_state host_shape instance_id host_details
                    host_id=$(echo "$host_b64" | base64 -d | jq -r '.id')
                    host_state=$(echo "$host_b64" | base64 -d | jq -r '.["lifecycle-state"] // "UNKNOWN"')
                    host_shape=$(echo "$host_b64" | base64 -d | jq -r '.["instance-shape"] // .["compute-shape"] // "N/A"')
                    instance_id=$(echo "$host_b64" | base64 -d | jq -r '.["instance-id"] // empty')
                    host_details=$(echo "$host_b64" | base64 -d | jq -r '.["lifecycle-details"] // empty')
                    
                    local host_prefix="├──"
                    [[ $host_idx -eq $host_count_for_block ]] && host_prefix="└──"
                    
                    local host_state_color
                    host_state_color=$(color_lifecycle_state "$host_state")
                    
                    local host_short="${host_id##*.}"
                    
                    # Format instance info
                    local instance_info=""
                    if [[ -n "$instance_id" ]]; then
                        local instance_short="${instance_id##*.}"
                        instance_info=" ${GREEN}→ Instance: ${instance_short}${NC}"
                    fi
                    
                    # Format details
                    local details_info=""
                    if [[ -n "$host_details" && "$host_details" != "null" ]]; then
                        details_info=" ${GRAY}(${host_details})${NC}"
                    fi
                    
                    echo -e "   ${island_child_prefix}${block_child_prefix}${host_prefix} ${WHITE}🖥️  ${host_short}${NC} ${host_state_color}[${host_state}]${NC} ${MAGENTA}${host_shape}${NC}${instance_info}${details_info}"
                done <<< "$hosts_for_block"
            else
                # Show host count summary
                local block_active block_inactive block_total_hosts
                block_active=$(jq --arg block "$block_id" '[.[] | select(.["compute-network-block-id"] == $block and .["lifecycle-state"] == "ACTIVE")] | length' "$hosts_tmp" 2>/dev/null) || block_active=0
                block_inactive=$(jq --arg block "$block_id" '[.[] | select(.["compute-network-block-id"] == $block and .["lifecycle-state"] == "INACTIVE")] | length' "$hosts_tmp" 2>/dev/null) || block_inactive=0
                block_total_hosts=$(jq --arg block "$block_id" '[.[] | select(.["compute-network-block-id"] == $block)] | length' "$hosts_tmp" 2>/dev/null) || block_total_hosts=0
                
                if [[ $block_total_hosts -gt 0 ]]; then
                    echo -e "   ${island_child_prefix}${block_child_prefix}└── ${GRAY}Hosts: ${block_total_hosts} total (${NC}${GREEN}${block_active} active${NC}${GRAY}, ${NC}${YELLOW}${block_inactive} inactive${NC}${GRAY})${NC}"
                fi
            fi
        done <<< "$blocks_for_island"
    done < <(jq -r '.[] | @base64' "$islands_tmp" 2>/dev/null)
    
    # Show unassigned hosts (those with null compute-network-block-id)
    local unassigned_hosts
    unassigned_hosts=$(jq -r '.[] | select(.["compute-network-block-id"] == null) | @base64' "$hosts_tmp" 2>/dev/null)
    
    if [[ -n "$unassigned_hosts" ]]; then
        local unassigned_count
        unassigned_count=$(echo "$unassigned_hosts" | grep -c .)
        
        echo ""
        echo -e "   ${BOLD}${YELLOW}⚠️  Unassigned Hosts${NC} ${GRAY}(not in any network block: ${unassigned_count})${NC}"
        
        if [[ "$show_hosts" == "true" ]]; then
            local host_idx=0
            while IFS= read -r host_b64; do
                [[ -z "$host_b64" ]] && continue
                ((host_idx++))
                
                local host_id host_state host_shape instance_id host_details
                host_id=$(echo "$host_b64" | base64 -d | jq -r '.id')
                host_state=$(echo "$host_b64" | base64 -d | jq -r '.["lifecycle-state"] // "UNKNOWN"')
                host_shape=$(echo "$host_b64" | base64 -d | jq -r '.["instance-shape"] // .["compute-shape"] // "N/A"')
                instance_id=$(echo "$host_b64" | base64 -d | jq -r '.["instance-id"] // empty')
                host_details=$(echo "$host_b64" | base64 -d | jq -r '.["lifecycle-details"] // empty')
                
                local host_prefix="├──"
                [[ $host_idx -eq $unassigned_count ]] && host_prefix="└──"
                
                local host_state_color
                host_state_color=$(color_lifecycle_state "$host_state")
                
                local host_short="${host_id##*.}"
                
                # Format instance info
                local instance_info=""
                if [[ -n "$instance_id" ]]; then
                    local instance_short="${instance_id##*.}"
                    instance_info=" ${GREEN}→ Instance: ${instance_short}${NC}"
                fi
                
                # Format details
                local details_info=""
                if [[ -n "$host_details" && "$host_details" != "null" ]]; then
                    details_info=" ${GRAY}(${host_details})${NC}"
                fi
                
                echo -e "       ${host_prefix} ${WHITE}🖥️  ${host_short}${NC} ${host_state_color}[${host_state}]${NC} ${MAGENTA}${host_shape}${NC}${instance_info}${details_info}"
            done <<< "$unassigned_hosts"
        else
            local unassigned_active unassigned_inactive
            unassigned_active=$(jq '[.[] | select(.["compute-network-block-id"] == null and .["lifecycle-state"] == "ACTIVE")] | length' "$hosts_tmp" 2>/dev/null) || unassigned_active=0
            unassigned_inactive=$(jq '[.[] | select(.["compute-network-block-id"] == null and .["lifecycle-state"] == "INACTIVE")] | length' "$hosts_tmp" 2>/dev/null) || unassigned_inactive=0
            echo -e "       └── ${GRAY}Hosts: ${unassigned_count} total (${NC}${GREEN}${unassigned_active} active${NC}${GRAY}, ${NC}${YELLOW}${unassigned_inactive} inactive${NC}${GRAY})${NC}"
        fi
    fi
    
    # Cleanup temp files
    rm -f "$islands_tmp" "$blocks_tmp" "$hosts_tmp"
    
    echo ""
    if [[ "$show_hosts" != "true" ]]; then
        echo -e "${GRAY}Tip: Use --hosts to show individual bare metal hosts${NC}"
    fi
    echo ""
}

# Find instance in topology
find_instance() {
    local instance_id="$1"
    
    echo ""
    echo -e "${BOLD}${CYAN}Searching for instance: ${YELLOW}$instance_id${NC}"
    echo ""
    
    local hosts_arr
    hosts_arr=$(get_json_array "$BARE_METAL_HOSTS_CACHE")
    
    local host_info
    host_info=$(echo "$hosts_arr" | jq -r --arg inst "$instance_id" '.[] | select(.["instance-id"] == $inst)' 2>/dev/null)
    
    if [[ -z "$host_info" || "$host_info" == "null" ]]; then
        echo -e "${YELLOW}Instance not found in capacity topology${NC}"
        return 1
    fi
    
    local host_id host_state host_shape network_block_id host_details
    host_id=$(echo "$host_info" | jq -r '.id')
    host_state=$(echo "$host_info" | jq -r '.["lifecycle-state"]')
    host_shape=$(echo "$host_info" | jq -r '.["instance-shape"] // .["compute-shape"] // "N/A"')
    network_block_id=$(echo "$host_info" | jq -r '.["compute-network-block-id"]')
    host_details=$(echo "$host_info" | jq -r '.["lifecycle-details"] // "N/A"')
    
    # Get network block info
    local blocks_arr
    blocks_arr=$(get_json_array "$NETWORK_BLOCKS_CACHE")
    
    local block_info
    block_info=$(echo "$blocks_arr" | jq -r --arg block "$network_block_id" '.[] | select(.id == $block)' 2>/dev/null)
    
    local hpc_island_id
    hpc_island_id=$(echo "$block_info" | jq -r '.["compute-hpc-island-id"]')
    
    # Get HPC island info  
    local islands_arr
    islands_arr=$(get_json_array "$HPC_ISLANDS_CACHE")
    
    local island_info
    island_info=$(echo "$islands_arr" | jq -r --arg island "$hpc_island_id" '.[] | select(.id == $island)' 2>/dev/null)
    
    local host_state_color
    host_state_color=$(color_lifecycle_state "$host_state")
    
    echo -e "${BOLD}${WHITE}Instance Location in Topology:${NC}"
    echo ""
    echo -e "  ${CYAN}HPC Island:${NC}     ${YELLOW}${hpc_island_id}${NC}"
    echo -e "  ${CYAN}Network Block:${NC}  ${YELLOW}${network_block_id}${NC}"
    echo -e "  ${CYAN}Host ID:${NC}        ${YELLOW}${host_id}${NC}"
    echo ""
    echo -e "  ${CYAN}Host State:${NC}     ${host_state_color}${host_state}${NC}"
    echo -e "  ${CYAN}Shape:${NC}          ${WHITE}${host_shape}${NC}"
    echo -e "  ${CYAN}Details:${NC}        ${WHITE}${host_details}${NC}"
    echo ""
}

# Export topology data
export_topology() {
    local output_file="$1"
    
    log_info "Exporting topology data to $output_file..."
    
    local topology_id
    topology_id=$(get_topology_id)
    
    # Get arrays using helper
    local topo_arr islands_arr blocks_arr hosts_arr
    topo_arr=$(get_json_array "$TOPOLOGY_CACHE")
    islands_arr=$(get_json_array "$HPC_ISLANDS_CACHE")
    blocks_arr=$(get_json_array "$NETWORK_BLOCKS_CACHE")
    hosts_arr=$(get_json_array "$BARE_METAL_HOSTS_CACHE")
    
    jq -n \
        --argjson topology "$(echo "$topo_arr" | jq '.[0] // {}')" \
        --argjson islands "$islands_arr" \
        --argjson blocks "$blocks_arr" \
        --argjson hosts "$hosts_arr" \
        '{
            topology: $topology,
            hpc_islands: $islands,
            network_blocks: $blocks,
            bare_metal_hosts: $hosts,
            exported_at: now | todate
        }' > "$output_file"
    
    echo -e "${GREEN}Exported to: $output_file${NC}"
}

#===============================================================================
# HELP
#===============================================================================

show_help() {
    echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
    echo ""
    echo "Displays OCI Compute Capacity Topology in a hierarchical tree view."
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --summary           Show summary counts only (no tree)"
    echo "  --hosts             Show bare metal hosts in tree"
    echo "  --state <STATE>     Filter hosts by lifecycle state"
    echo "                      Valid: ACTIVE, INACTIVE, DELETED, CREATING, UPDATING"
    echo "  --instance <OCID>   Find specific instance in topology"
    echo "  --export <file>     Export topology data to JSON file"
    echo "  --refresh           Force refresh of cached data"
    echo "  --help              Show this help message"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                           # Show tree with block summaries"
    echo "  $0 --summary                 # Show counts only"
    echo "  $0 --hosts                   # Show all hosts in tree"
    echo "  $0 --hosts --state ACTIVE    # Show only ACTIVE hosts"
    echo "  $0 --instance ocid1.xxx      # Find instance location"
    echo "  $0 --export topology.json    # Export data to JSON"
    echo ""
    echo -e "${GRAY}Note: Capacity topology data refreshes every 15 minutes in OCI${NC}"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    # Source variables
    if [[ -f "$SCRIPT_DIR/variables.sh" ]]; then
        source "$SCRIPT_DIR/variables.sh"
    elif [[ -f "./variables.sh" ]]; then
        source "./variables.sh"
    fi
    
    # Create cache directory
    mkdir -p "$CACHE_DIR"
    
    # Parse arguments
    local show_summary=false
    local show_hosts=false
    local filter_state=""
    local find_instance_id=""
    local export_file=""
    local force_refresh=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --summary)
                show_summary=true
                shift
                ;;
            --hosts)
                show_hosts=true
                shift
                ;;
            --state)
                filter_state="$2"
                shift 2
                ;;
            --instance)
                find_instance_id="$2"
                shift 2
                ;;
            --export)
                export_file="$2"
                shift 2
                ;;
            --refresh)
                force_refresh=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    # Force refresh if requested
    if [[ "$force_refresh" == "true" ]]; then
        rm -f "$TOPOLOGY_CACHE" "$HPC_ISLANDS_CACHE" "$NETWORK_BLOCKS_CACHE" "$BARE_METAL_HOSTS_CACHE"
    fi
    
    # Fetch data
    fetch_all_topology_data || exit 1
    
    # Execute requested action
    if [[ -n "$find_instance_id" ]]; then
        find_instance "$find_instance_id"
    elif [[ -n "$export_file" ]]; then
        export_topology "$export_file"
    elif [[ "$show_summary" == "true" ]]; then
        display_summary
    else
        display_summary
        display_tree "$show_hosts" "$filter_state"
    fi
}

main "$@"