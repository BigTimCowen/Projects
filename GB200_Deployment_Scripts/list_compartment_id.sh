#!/bin/bash
#===============================================================================
# list_compartments.sh - List OCI compartments in a tree structure
#===============================================================================

set -o pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#===============================================================================
# FUNCTIONS
#===============================================================================

log_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

log_info() {
    [[ "$DEBUG" == "true" ]] && echo -e "${CYAN}INFO:${NC} $1" >&2
}

check_dependencies() {
    local missing=()
    command -v oci &>/dev/null || missing+=("oci")
    command -v jq &>/dev/null || missing+=("jq")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing[*]}"
        return 1
    fi
    return 0
}

show_help() {
    cat << 'EOF'
Usage: ./list_compartments.sh [OPTIONS]

Lists all compartments in a tenancy with tree visualization.

Options:
  --tenancy-id <ocid>       Override tenancy ID from variables.sh
  --depth <n>               Max depth to display (default: 2, 0=unlimited)
  --all                     Show all levels (same as --depth 0)
  --include-deleted         Include deleted compartments
  --debug                   Show debug messages
  --help                    Show this help message

Examples:
  ./list_compartments.sh
  ./list_compartments.sh --depth 3
  ./list_compartments.sh --all
  ./list_compartments.sh --tenancy-id ocid1.tenancy.oc1..xxx
EOF
}

# Get compartments from OCI
fetch_compartments() {
    local tenancy_id="$1"
    local include_deleted="$2"
    
    local lifecycle_filter=""
    [[ "$include_deleted" == "true" ]] && lifecycle_filter="--lifecycle-state ALL"
    
    log_info "Fetching compartments from tenancy..."
    
    oci iam compartment list \
        --compartment-id "$tenancy_id" \
        --compartment-id-in-subtree true \
        --all \
        $lifecycle_filter \
        --output json 2>/dev/null
}

# Display compartment tree
display_tree() {
    local compartments_json="$1"
    local tenancy_id="$2"
    local max_depth="$3"
    
    # Get tenancy name
    local tenancy_name
    tenancy_name=$(oci iam tenancy get --tenancy-id "$tenancy_id" --output json 2>/dev/null | jq -r '.data.name // "Tenancy"')
    
    echo ""
    echo -e "${BOLD}${MAGENTA}Tenancy:${NC} ${GREEN}${tenancy_name}${NC} ${WHITE}(${YELLOW}${tenancy_id}${WHITE})${NC}"
    echo ""
    
    # Get root level compartments (parent = tenancy)
    local root_compartments
    root_compartments=$(echo "$compartments_json" | jq -r --arg tid "$tenancy_id" \
        '.data[] | select(.["compartment-id"] == $tid) | @base64')
    
    local root_count
    root_count=$(echo "$root_compartments" | grep -c . || echo 0)
    local root_index=0
    
    for comp_b64 in $root_compartments; do
        ((root_index++))
        local comp
        comp=$(echo "$comp_b64" | base64 -d)
        
        local name id state
        name=$(echo "$comp" | jq -r '.name')
        id=$(echo "$comp" | jq -r '.id')
        state=$(echo "$comp" | jq -r '.["lifecycle-state"]')
        
        # Determine prefix (last item or not)
        local prefix="├──"
        local child_prefix="│   "
        if [[ $root_index -eq $root_count ]]; then
            prefix="└──"
            child_prefix="    "
        fi
        
        # Color based on state
        local state_color="$GREEN"
        [[ "$state" != "ACTIVE" ]] && state_color="$RED"
        
        echo -e "${WHITE}${prefix}${NC} ${BOLD}${BLUE}${name}${NC} ${WHITE}[${state_color}${state}${WHITE}]${NC} ${WHITE}(${YELLOW}${id}${WHITE})${NC}"
        
        # Show children if depth allows
        if [[ "$max_depth" -eq 0 ]] || [[ "$max_depth" -gt 1 ]]; then
            display_children "$compartments_json" "$id" "$child_prefix" 2 "$max_depth"
        fi
    done
    
    echo ""
}

# Recursive function to display child compartments
display_children() {
    local compartments_json="$1"
    local parent_id="$2"
    local prefix="$3"
    local current_depth="$4"
    local max_depth="$5"
    
    # Check depth limit
    if [[ "$max_depth" -ne 0 ]] && [[ "$current_depth" -gt "$max_depth" ]]; then
        return
    fi
    
    # Get children of this compartment
    local children
    children=$(echo "$compartments_json" | jq -r --arg pid "$parent_id" \
        '.data[] | select(.["compartment-id"] == $pid) | @base64')
    
    [[ -z "$children" ]] && return
    
    local child_count
    child_count=$(echo "$children" | grep -c . || echo 0)
    local child_index=0
    
    for comp_b64 in $children; do
        ((child_index++))
        local comp
        comp=$(echo "$comp_b64" | base64 -d)
        
        local name id state
        name=$(echo "$comp" | jq -r '.name')
        id=$(echo "$comp" | jq -r '.id')
        state=$(echo "$comp" | jq -r '.["lifecycle-state"]')
        
        # Determine connector
        local connector="├──"
        local next_prefix="${prefix}│   "
        if [[ $child_index -eq $child_count ]]; then
            connector="└──"
            next_prefix="${prefix}    "
        fi
        
        # Color based on state
        local state_color="$GREEN"
        [[ "$state" != "ACTIVE" ]] && state_color="$RED"
        
        echo -e "${WHITE}${prefix}${connector}${NC} ${CYAN}${name}${NC} ${WHITE}[${state_color}${state}${WHITE}]${NC} ${WHITE}(${YELLOW}${id}${WHITE})${NC}"
        
        # Recurse for children
        display_children "$compartments_json" "$id" "$next_prefix" $((current_depth + 1)) "$max_depth"
    done
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    check_dependencies || exit 1
    
    # Source variables file
    if [[ -f "$SCRIPT_DIR/variables.sh" ]]; then
        source "$SCRIPT_DIR/variables.sh"
    elif [[ -f "./variables.sh" ]]; then
        source "./variables.sh"
    fi
    
    # Defaults
    local custom_tenancy=""
    local max_depth=2
    local include_deleted=false
    DEBUG=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tenancy-id)
                custom_tenancy="$2"
                shift 2
                ;;
            --depth)
                max_depth="$2"
                shift 2
                ;;
            --all)
                max_depth=0
                shift
                ;;
            --include-deleted)
                include_deleted=true
                shift
                ;;
            --debug)
                DEBUG=true
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
    
    # Set effective tenancy
    local effective_tenancy="${custom_tenancy:-$TENANCY_ID}"
    
    if [[ -z "$effective_tenancy" ]]; then
        log_error "TENANCY_ID not set. Use --tenancy-id or set in variables.sh"
        exit 1
    fi
    
    # Fetch compartments
    local compartments_json
    compartments_json=$(fetch_compartments "$effective_tenancy" "$include_deleted")
    
    if [[ -z "$compartments_json" || "$compartments_json" == "null" ]]; then
        log_error "Failed to fetch compartments"
        exit 1
    fi
    
    # Count compartments
    local total_count
    total_count=$(echo "$compartments_json" | jq '.data | length')
    log_info "Found $total_count compartments"
    
    # Display tree
    display_tree "$compartments_json" "$effective_tenancy" "$max_depth"
    
    # Summary
    local active_count inactive_count
    active_count=$(echo "$compartments_json" | jq '[.data[] | select(.["lifecycle-state"] == "ACTIVE")] | length')
    inactive_count=$(echo "$compartments_json" | jq '[.data[] | select(.["lifecycle-state"] != "ACTIVE")] | length')
    
    echo -e "${WHITE}Total: ${GREEN}${active_count} active${NC}"
    [[ "$inactive_count" -gt 0 ]] && echo -e "${WHITE}       ${RED}${inactive_count} inactive/deleted${NC}"
    echo ""
}

main "$@"