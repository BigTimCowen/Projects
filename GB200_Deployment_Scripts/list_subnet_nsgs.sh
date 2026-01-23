#!/bin/bash
#
# list_network_resources.sh - List all Subnets and NSGs in a compartment
#
# Description:
#   Lists all VCNs, Subnets, and Network Security Groups in the specified
#   compartment with their OCIDs and key details.
#
# Dependencies:
#   - oci CLI (configured)
#   - jq (JSON processor)
#
# Usage:
#   ./list_network_resources.sh [OPTIONS]
#
# Options:
#   --compartment-id <ocid>   Override compartment ID from variables.sh
#   --region <region>         Override region from variables.sh
#   --vcn-id <ocid>           Filter by specific VCN
#   --json                    Output in JSON format
#   --help                    Show this help message
#
# Configuration:
#   Requires variables.sh with COMPARTMENT_ID and REGION
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
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Script directory
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Debug mode (off by default)
DEBUG=false

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_info() {
    [[ "$DEBUG" == "true" ]] && echo -e "${CYAN}[INFO]${NC} $1" >&2
}

print_separator() {
    local width="${1:-120}"
    echo -e "${BLUE}$(printf '━%.0s' $(seq 1 "$width"))${NC}"
}

check_dependencies() {
    local missing=()
    command -v oci &>/dev/null || missing+=("oci")
    command -v jq &>/dev/null || missing+=("jq")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        return 1
    fi
    return 0
}

show_help() {
    cat << 'EOF'
Usage: ./list_network_resources.sh [OPTIONS]

Lists all VCNs, Subnets, and Network Security Groups in a compartment.

Options:
  --compartment-id <ocid>   Override compartment ID from variables.sh
  --region <region>         Override region from variables.sh
  --vcn-id <ocid>           Filter by specific VCN
  --json                    Output in JSON format
  --debug                   Show debug/info messages
  --help                    Show this help message

Examples:
  ./list_network_resources.sh
  ./list_network_resources.sh --region us-phoenix-1
  ./list_network_resources.sh --vcn-id ocid1.vcn.oc1.phx.xxx
  ./list_network_resources.sh --json > network_resources.json
EOF
}

#===============================================================================
# MAIN FUNCTIONS
#===============================================================================

list_vcns() {
    local compartment_id="$1"
    local region="$2"
    
    oci network vcn list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json 2>/dev/null
}

list_subnets() {
    local compartment_id="$1"
    local region="$2"
    local vcn_id="$3"
    
    local cmd="oci network subnet list --compartment-id $compartment_id --region $region --all --output json"
    [[ -n "$vcn_id" ]] && cmd="$cmd --vcn-id $vcn_id"
    
    eval "$cmd" 2>/dev/null
}

list_nsgs() {
    local compartment_id="$1"
    local region="$2"
    local vcn_id="$3"
    
    local cmd="oci network nsg list --compartment-id $compartment_id --region $region --all --output json"
    [[ -n "$vcn_id" ]] && cmd="$cmd --vcn-id $vcn_id"
    
    eval "$cmd" 2>/dev/null
}

get_nsg_rules_count() {
    local nsg_id="$1"
    local region="$2"
    
    local count
    count=$(oci network nsg rules list \
        --nsg-id "$nsg_id" \
        --region "$region" \
        --all \
        --output json 2>/dev/null | jq '.data | length' 2>/dev/null)
    
    echo "${count:-0}"
}

display_formatted_output() {
    local compartment_id="$1"
    local region="$2"
    local vcn_filter="$3"
    
    echo ""
    echo -e "${BOLD}${WHITE}Network Resources${NC} - ${CYAN}Region:${NC} ${WHITE}$region${NC} ${CYAN}Compartment:${NC} ${WHITE}(${YELLOW}$compartment_id${WHITE})${NC}"
    [[ -n "$vcn_filter" ]] && echo -e "${CYAN}VCN Filter:${NC} ${WHITE}(${YELLOW}$vcn_filter${WHITE})${NC}"
    echo ""
    
    # Get VCNs
    log_info "Fetching VCNs..."
    local vcns_json
    vcns_json=$(list_vcns "$compartment_id" "$region")
    
    if [[ -z "$vcns_json" || "$vcns_json" == "null" ]]; then
        log_error "Failed to fetch VCNs or no VCNs found"
        return 1
    fi
    
    local vcn_ids
    if [[ -n "$vcn_filter" ]]; then
        vcn_ids="$vcn_filter"
    else
        vcn_ids=$(echo "$vcns_json" | jq -r '.data[]?.id // empty')
    fi
    
    [[ -z "$vcn_ids" ]] && { echo -e "${YELLOW}No VCNs found in compartment${NC}"; return 0; }
    
    # Process each VCN
    local vcn_id
    for vcn_id in $vcn_ids; do
        [[ -z "$vcn_id" ]] && continue
        
        local vcn_name vcn_cidr vcn_state
        vcn_name=$(echo "$vcns_json" | jq -r --arg id "$vcn_id" '.data[] | select(.id==$id) | .["display-name"] // "N/A"')
        vcn_cidr=$(echo "$vcns_json" | jq -r --arg id "$vcn_id" '.data[] | select(.id==$id) | .["cidr-blocks"][0] // "N/A"')
        vcn_state=$(echo "$vcns_json" | jq -r --arg id "$vcn_id" '.data[] | select(.id==$id) | .["lifecycle-state"] // "N/A"')
        
        echo -e "${BOLD}${MAGENTA}VCN: ${GREEN}$vcn_name${NC} ${WHITE}[${CYAN}$vcn_cidr${WHITE}]${NC} ${WHITE}[${GREEN}$vcn_state${WHITE}]${NC} ${WHITE}(${YELLOW}$vcn_id${WHITE})${NC}"
        
        # Get Subnets for this VCN
        log_info "Fetching subnets for VCN: $vcn_name..."
        local subnets_json
        subnets_json=$(list_subnets "$compartment_id" "$region" "$vcn_id")
        
        # Get NSGs for this VCN
        log_info "Fetching NSGs for VCN: $vcn_name..."
        local nsgs_json
        nsgs_json=$(list_nsgs "$compartment_id" "$region" "$vcn_id")
        
        # Known shortnames for subnets and NSGs
        local known_shortnames=("bastion" "cp" "operator" "int_lb" "pub_lb" "pods" "workers" "fss" "lustre")
        
        if [[ -n "$subnets_json" && "$subnets_json" != "null" ]]; then
            local subnet_count
            subnet_count=$(echo "$subnets_json" | jq '.data | length')
            
            if [[ "$subnet_count" -gt 0 ]]; then
                # Process each subnet and find related NSGs
                echo "$subnets_json" | jq -r '.data[] | "\(."display-name" // "N/A")|\(."cidr-block" // "N/A")|\(if ."prohibit-public-ip-on-vnic" then "Private" else "Public" end)|\(."lifecycle-state" // "N/A")|\(.id // "N/A")"' | \
                while IFS='|' read -r subnet_name cidr access state subnet_ocid; do
                    local access_color state_color
                    [[ "$access" == "Private" ]] && access_color="$RED" || access_color="$LIGHT_GREEN"
                    [[ "$state" == "AVAILABLE" ]] && state_color="$GREEN" || state_color="$RED"
                    
                    # Print subnet info with aligned OCID
                    printf "  ${BOLD}${WHITE}Subnet:${NC} ${GREEN}%-30s${NC} ${WHITE}[${CYAN}%-18s${WHITE}]${NC} ${WHITE}[${access_color}%-7s${WHITE}]${NC} ${WHITE}[${state_color}%-9s${WHITE}]${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                        "$subnet_name" "$cidr" "$access" "$state" "$subnet_ocid"
                    
                    # Find which shortname this subnet matches
                    local subnet_name_lower matched_shortname=""
                    subnet_name_lower=$(echo "$subnet_name" | tr '[:upper:]' '[:lower:]')
                    
                    for shortname in "${known_shortnames[@]}"; do
                        if [[ "$subnet_name_lower" == *"$shortname"* ]]; then
                            matched_shortname="$shortname"
                            break
                        fi
                    done
                    
                    # Find matching NSGs by the same shortname
                    local matched_nsgs=()
                    if [[ -n "$matched_shortname" && -n "$nsgs_json" && "$nsgs_json" != "null" ]]; then
                        while IFS='|' read -r nsg_name nsg_state nsg_ocid; do
                            [[ -z "$nsg_name" ]] && continue
                            
                            local nsg_name_lower
                            nsg_name_lower=$(echo "$nsg_name" | tr '[:upper:]' '[:lower:]')
                            
                            if [[ "$nsg_name_lower" == *"$matched_shortname"* ]]; then
                                matched_nsgs+=("${nsg_name}|${nsg_state}|${nsg_ocid}")
                            fi
                        done < <(echo "$nsgs_json" | jq -r '.data[] | "\(."display-name" // "N/A")|\(."lifecycle-state" // "N/A")|\(.id // "N/A")"')
                    fi
                    
                    # Display matched NSGs
                    local nsg_count_matched=${#matched_nsgs[@]}
                    if [[ $nsg_count_matched -gt 0 ]]; then
                        local i=0
                        for nsg_entry in "${matched_nsgs[@]}"; do
                            ((i++))
                            local nsg_name nsg_state nsg_ocid
                            IFS='|' read -r nsg_name nsg_state nsg_ocid <<< "$nsg_entry"
                            
                            local nsg_state_color
                            [[ "$nsg_state" == "AVAILABLE" ]] && nsg_state_color="$GREEN" || nsg_state_color="$RED"
                            
                            # Use └─ for last item, ├─ for others
                            local prefix="├─"
                            [[ $i -eq $nsg_count_matched ]] && prefix="└─"
                            
                            # NSG line: 10 spaces + "├─ NSG: " (8 display) + 30 name = 48
                            # Need 24 spaces to reach position 72 where [state] starts
                            printf "          ${BOLD}${BLUE}${prefix} NSG:${NC} ${WHITE}%-30s${NC}                        ${WHITE}[${nsg_state_color}%-9s${WHITE}]${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                                "$nsg_name" "$nsg_state" "$nsg_ocid"
                        done
                    fi
                    
                    echo ""
                done
            else
                echo -e "  ${YELLOW}No subnets found in this VCN${NC}"
            fi
        else
            echo -e "  ${YELLOW}No subnets found in this VCN${NC}"
        fi
        
        # Show unmatched NSGs (NSGs that don't match any known shortname or whose shortname has no subnet)
        if [[ -n "$nsgs_json" && "$nsgs_json" != "null" ]]; then
            # Build list of shortnames that have subnets
            local shortnames_with_subnets=""
            if [[ -n "$subnets_json" && "$subnets_json" != "null" ]]; then
                while read -r subnet_name; do
                    local subnet_name_lower
                    subnet_name_lower=$(echo "$subnet_name" | tr '[:upper:]' '[:lower:]')
                    for shortname in "${known_shortnames[@]}"; do
                        if [[ "$subnet_name_lower" == *"$shortname"* ]]; then
                            shortnames_with_subnets="$shortnames_with_subnets $shortname"
                            break
                        fi
                    done
                done < <(echo "$subnets_json" | jq -r '.data[]."display-name" // empty')
            fi
            
            # Find unmatched NSGs
            local unmatched_nsgs=()
            while IFS='|' read -r nsg_name nsg_state nsg_ocid; do
                [[ -z "$nsg_name" ]] && continue
                
                local nsg_name_lower nsg_shortname="" matched=false
                nsg_name_lower=$(echo "$nsg_name" | tr '[:upper:]' '[:lower:]')
                
                # Find which shortname this NSG matches
                for shortname in "${known_shortnames[@]}"; do
                    if [[ "$nsg_name_lower" == *"$shortname"* ]]; then
                        nsg_shortname="$shortname"
                        break
                    fi
                done
                
                # Check if this shortname has a matching subnet
                if [[ -n "$nsg_shortname" ]]; then
                    if [[ "$shortnames_with_subnets" == *"$nsg_shortname"* ]]; then
                        matched=true
                    fi
                fi
                
                [[ "$matched" == "false" ]] && unmatched_nsgs+=("${nsg_name}|${nsg_state}|${nsg_ocid}")
            done < <(echo "$nsgs_json" | jq -r '.data[] | "\(."display-name" // "N/A")|\(."lifecycle-state" // "N/A")|\(.id // "N/A")"')
            
            if [[ ${#unmatched_nsgs[@]} -gt 0 ]]; then
                echo -e "  ${BOLD}${WHITE}Unmatched NSGs:${NC}"
                local i=0
                local total=${#unmatched_nsgs[@]}
                for nsg_entry in "${unmatched_nsgs[@]}"; do
                    ((i++))
                    local nsg_name nsg_state nsg_ocid nsg_state_color
                    IFS='|' read -r nsg_name nsg_state nsg_ocid <<< "$nsg_entry"
                    [[ "$nsg_state" == "AVAILABLE" ]] && nsg_state_color="$GREEN" || nsg_state_color="$RED"
                    
                    local prefix="├─"
                    [[ $i -eq $total ]] && prefix="└─"
                    
                    # Same alignment as matched NSGs: 24 spaces after 30-char name
                    printf "          ${BOLD}${BLUE}${prefix} NSG:${NC} ${WHITE}%-30s${NC}                        ${WHITE}[${nsg_state_color}%-9s${WHITE}]${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                        "$nsg_name" "$nsg_state" "$nsg_ocid"
                done
                echo ""
            fi
        fi
        
        echo ""
    done
}

output_json() {
    local compartment_id="$1"
    local region="$2"
    local vcn_filter="$3"
    
    local result="{}"
    
    # Get VCNs
    local vcns_json
    vcns_json=$(list_vcns "$compartment_id" "$region")
    
    local vcn_ids
    if [[ -n "$vcn_filter" ]]; then
        vcn_ids="$vcn_filter"
    else
        vcn_ids=$(echo "$vcns_json" | jq -r '.data[]?.id // empty')
    fi
    
    local vcn_array="[]"
    
    for vcn_id in $vcn_ids; do
        [[ -z "$vcn_id" ]] && continue
        
        local vcn_data
        vcn_data=$(echo "$vcns_json" | jq --arg id "$vcn_id" '.data[] | select(.id==$id)')
        
        local subnets_json
        subnets_json=$(list_subnets "$compartment_id" "$region" "$vcn_id")
        
        local nsgs_json
        nsgs_json=$(list_nsgs "$compartment_id" "$region" "$vcn_id")
        
        local vcn_with_resources
        vcn_with_resources=$(echo "$vcn_data" | jq \
            --argjson subnets "${subnets_json:-"{\"data\":[]}"}" \
            --argjson nsgs "${nsgs_json:-"{\"data\":[]}"}" \
            '. + {subnets: $subnets.data, nsgs: $nsgs.data}')
        
        vcn_array=$(echo "$vcn_array" | jq --argjson vcn "$vcn_with_resources" '. + [$vcn]')
    done
    
    jq -n \
        --arg compartment "$compartment_id" \
        --arg region "$region" \
        --argjson vcns "$vcn_array" \
        '{compartment_id: $compartment, region: $region, vcns: $vcns}'
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
    
    # Parse arguments
    local custom_compartment=""
    local custom_region=""
    local vcn_filter=""
    local json_output=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --compartment-id)
                custom_compartment="$2"
                shift 2
                ;;
            --region)
                custom_region="$2"
                shift 2
                ;;
            --vcn-id)
                vcn_filter="$2"
                shift 2
                ;;
            --json)
                json_output=true
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
    
    # Set effective values
    local effective_compartment="${custom_compartment:-$COMPARTMENT_ID}"
    local effective_region="${custom_region:-$REGION}"
    
    # Validate
    if [[ -z "$effective_compartment" ]]; then
        log_error "COMPARTMENT_ID not set. Use --compartment-id or set in variables.sh"
        exit 1
    fi
    if [[ -z "$effective_region" ]]; then
        log_error "REGION not set. Use --region or set in variables.sh"
        exit 1
    fi
    
    # Output
    if [[ "$json_output" == "true" ]]; then
        output_json "$effective_compartment" "$effective_region" "$vcn_filter"
    else
        display_formatted_output "$effective_compartment" "$effective_region" "$vcn_filter"
    fi
}

main "$@"