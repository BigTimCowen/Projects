#!/bin/bash

LOGFILE="oci_network_explorer.log"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
LIGHT_GREEN='\033[92m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
ORANGE='\033[0;33m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Cache settings
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/oci_network_explorer}"
CACHE_TTL_SECONDS="${CACHE_TTL_SECONDS:-3600}"  # Default 1 hour
PARALLEL_WORKERS="${PARALLEL_WORKERS:-10}"  # Default 10 parallel workers

# Global variables
FORCE_REFRESH=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--refresh)
            FORCE_REFRESH=true
            shift
            ;;
        -c|--clear-cache)
            echo -e "${YELLOW}Clearing cache directory: $CACHE_DIR${NC}"
            rm -rf "$CACHE_DIR"
            echo -e "${GREEN}Cache cleared.${NC}"
            exit 0
            ;;
        --cache-ttl)
            CACHE_TTL_SECONDS="$2"
            shift 2
            ;;
        -p|--parallel)
            PARALLEL_WORKERS="$2"
            shift 2
            ;;
        -h|--help)
            echo -e "${BOLD}${CYAN}OCI Network Explorer${NC}"
            echo ""
            echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
            echo ""
            echo -e "${BOLD}Options:${NC}"
            echo "  -r, --refresh       Force refresh all cached data"
            echo "  -c, --clear-cache   Clear the cache directory and exit"
            echo "  --cache-ttl SEC     Set cache TTL in seconds (default: 3600)"
            echo "  -p, --parallel NUM  Number of parallel workers (default: 10)"
            echo "  -h, --help          Show this help message"
            echo ""
            echo -e "${BOLD}Environment Variables:${NC}"
            echo "  CACHE_DIR           Cache directory (default: ~/.cache/oci_network_explorer)"
            echo "  CACHE_TTL_SECONDS   Cache TTL in seconds (default: 3600)"
            echo "  PARALLEL_WORKERS    Number of parallel workers (default: 10)"
            echo "  COMPARTMENT_ID      OCI Compartment OCID"
            echo "  REGION              OCI Region (default: us-phoenix-1)"
            echo ""
            exit 0
            ;;
        -*)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
        *)
            shift
            ;;
    esac
done

# Source variables if you have them
if [ -f ./variables.sh ]; then
    source ./variables.sh
fi

# Set defaults if not in variables.sh
COMPARTMENT_ID="${COMPARTMENT_ID:-your-compartment-id}"
REGION="${REGION:-us-phoenix-1}"

# Create cache directory
mkdir -p "$CACHE_DIR"

# Cache file paths
CACHE_PREFIX="${REGION}_$(echo $COMPARTMENT_ID | md5sum | cut -c1-8)"
CACHE_SUBNETS="$CACHE_DIR/${CACHE_PREFIX}_subnets.json"
CACHE_VCNS="$CACHE_DIR/${CACHE_PREFIX}_vcns.json"
CACHE_VNIC_ATTACHMENTS="$CACHE_DIR/${CACHE_PREFIX}_vnic_attachments.json"
CACHE_NSGS="$CACHE_DIR/${CACHE_PREFIX}_nsgs.json"
CACHE_VNIC_DETAILS_DIR="$CACHE_DIR/vnic_details"
CACHE_NSG_RULES_DIR="$CACHE_DIR/nsg_rules"
CACHE_COMPARTMENT="$CACHE_DIR/${CACHE_PREFIX}_compartment.json"

mkdir -p "$CACHE_VNIC_DETAILS_DIR"
mkdir -p "$CACHE_NSG_RULES_DIR"

# Fetch compartment name
get_compartment_name() {
    if [ -f "$CACHE_COMPARTMENT" ] && [ "$FORCE_REFRESH" != "true" ]; then
        local file_age=$(($(date +%s) - $(stat -c %Y "$CACHE_COMPARTMENT" 2>/dev/null || echo 0)))
        if [ "$file_age" -le "$CACHE_TTL_SECONDS" ]; then
            cat "$CACHE_COMPARTMENT" | jq -r '.name // "Unknown"'
            return
        fi
    fi
    
    local comp_data=$(oci iam compartment get \
        --compartment-id "$COMPARTMENT_ID" \
        --query 'data' 2>/dev/null)
    
    if [ -n "$comp_data" ] && [ "$comp_data" != "null" ]; then
        echo "$comp_data" > "$CACHE_COMPARTMENT"
        echo "$comp_data" | jq -r '.name // "Unknown"'
    else
        echo "Unknown"
    fi
}

COMPARTMENT_NAME=$(get_compartment_name)
export COMPARTMENT_NAME

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

is_cache_valid() {
    local cache_file="$1"
    
    if [ ! -f "$cache_file" ]; then
        return 1
    fi
    
    if [ "$FORCE_REFRESH" = true ]; then
        return 1
    fi
    
    local file_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
    
    if [ "$file_age" -gt "$CACHE_TTL_SECONDS" ]; then
        return 1
    fi
    
    return 0
}

fetch_with_cache() {
    local cache_file="$1"
    local description="$2"
    local fetch_command="$3"
    
    if is_cache_valid "$cache_file"; then
        echo -e "${GREEN}  ✓ Using cached $description${NC}" >&2
        cat "$cache_file"
    else
        echo -e "${YELLOW}  ↓ Fetching $description...${NC}" >&2
        local result
        result=$(eval "$fetch_command" 2>/dev/null)
        
        if [ -n "$result" ] && [ "$result" != "null" ]; then
            echo "$result" > "$cache_file"
            echo -e "${GREEN}  ✓ Cached $description${NC}" >&2
        else
            result="[]"
            echo "$result" > "$cache_file"
        fi
        
        echo "$result"
    fi
}

fetch_vnic_cached() {
    local vnic_id="$1"
    local cache_file="$CACHE_VNIC_DETAILS_DIR/${vnic_id}.json"
    
    if is_cache_valid "$cache_file"; then
        cat "$cache_file"
    else
        local result
        result=$(oci network vnic get \
            --region $REGION \
            --vnic-id "$vnic_id" \
            --query 'data' 2>/dev/null)
        
        if [ -n "$result" ] && [ "$result" != "null" ]; then
            echo "$result" > "$cache_file"
        fi
        
        echo "$result"
    fi
}

# Export functions for parallel execution
export -f fetch_vnic_cached is_cache_valid
export CACHE_VNIC_DETAILS_DIR CACHE_TTL_SECONDS FORCE_REFRESH REGION

load_base_data() {
    echo -e "${BOLD}Loading base data (Cache TTL: ${CACHE_TTL_SECONDS}s):${NC}"
    
    ALL_SUBNETS=$(fetch_with_cache "$CACHE_SUBNETS" "subnets" \
        "oci network subnet list --region $REGION --compartment-id $COMPARTMENT_ID --all --query 'data'")
    
    ALL_VCNS=$(fetch_with_cache "$CACHE_VCNS" "VCNs" \
        "oci network vcn list --region $REGION --compartment-id $COMPARTMENT_ID --all --query 'data'")
    
    ALL_VNIC_ATTACHMENTS=$(fetch_with_cache "$CACHE_VNIC_ATTACHMENTS" "VNIC attachments" \
        "oci compute vnic-attachment list --region $REGION --compartment-id $COMPARTMENT_ID --all --query 'data'")
    
    NSG_DATA=$(fetch_with_cache "$CACHE_NSGS" "NSGs" \
        "oci network nsg list --region $REGION --compartment-id $COMPARTMENT_ID --all --query 'data'")
    
    echo -e "${GREEN}Base data loaded.${NC}"
    echo ""
}

# ============================================================================
# OPTION 1: LIST VCN AND SUBNETS
# ============================================================================

list_vcn_subnets() {
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}VCN and Subnet Details${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Compartment:${NC} ${GREEN}$COMPARTMENT_NAME${NC}"
    echo -e "${CYAN}OCID:${NC}        ${YELLOW}$COMPARTMENT_ID${NC}"
    echo -e "${CYAN}Region:${NC}      ${WHITE}$REGION${NC}"
    echo ""
    
    load_base_data
    
    # Get VCN list
    VCN_IDS=$(echo "$ALL_VCNS" | jq -r '.[].id' 2>/dev/null)
    
    if [ -z "$VCN_IDS" ]; then
        echo -e "${RED}No VCNs found in compartment${NC}"
        return
    fi
    
    # Get NSG list
    NSG_LIST=$(echo "$NSG_DATA" | jq -r '.[].id' 2>/dev/null)
    
    echo -e "${YELLOW}Fetching NSG VNIC associations...${NC}"
    
    # Create temp directory for NSG VNIC data
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" RETURN
    
    NSG_VNIC_TEMP_DIR="$TEMP_DIR/nsg_vnics"
    mkdir -p "$NSG_VNIC_TEMP_DIR"
    
    # Pre-fetch NSG VNIC data in parallel
    for nsg_id in $NSG_LIST; do
        {
            local cache_file="$CACHE_DIR/nsg_vnics_${nsg_id}.json"
            if is_cache_valid "$cache_file"; then
                cat "$cache_file" > "$NSG_VNIC_TEMP_DIR/$nsg_id.json"
            else
                local vnic_data=$(oci network nsg vnics list \
                    --region $REGION \
                    --nsg-id $nsg_id \
                    --all \
                    --query 'data' 2>/dev/null)
                echo "$vnic_data" > "$cache_file"
                echo "$vnic_data" > "$NSG_VNIC_TEMP_DIR/$nsg_id.json"
            fi
        } &
    done
    wait
    
    echo -e "${YELLOW}Building subnet to NSG mapping from VNIC data...${NC}"
    
    # Build mapping of Subnet ID -> NSG IDs by iterating through each NSG's VNICs
    declare -A SUBNET_TO_NSG_IDS
    declare -A SUBNET_NSG_VNIC_COUNT  # Track VNIC count per subnet-nsg pair
    
    for nsg_id in $NSG_LIST; do
        # Get VNICs in this NSG
        local vnic_ids_in_nsg=$(cat "$NSG_VNIC_TEMP_DIR/$nsg_id.json" 2>/dev/null | jq -r '.[]."vnic-id"' 2>/dev/null)
        
        [ -z "$vnic_ids_in_nsg" ] && continue
        
        for vnic_id in $vnic_ids_in_nsg; do
            [ -z "$vnic_id" ] || [ "$vnic_id" = "null" ] && continue
            
            # Get VNIC details (with caching)
            local vnic_cache_file="$CACHE_VNIC_DETAILS_DIR/${vnic_id}.json"
            local vnic_info=""
            
            if is_cache_valid "$vnic_cache_file"; then
                vnic_info=$(cat "$vnic_cache_file")
            else
                vnic_info=$(oci network vnic get \
                    --region $REGION \
                    --vnic-id "$vnic_id" \
                    --query 'data' 2>/dev/null)
                [ -n "$vnic_info" ] && [ "$vnic_info" != "null" ] && echo "$vnic_info" > "$vnic_cache_file"
            fi
            
            [ -z "$vnic_info" ] || [ "$vnic_info" = "null" ] && continue
            
            local subnet_id=$(echo "$vnic_info" | jq -r '."subnet-id"' 2>/dev/null)
            
            [ -z "$subnet_id" ] || [ "$subnet_id" = "null" ] && continue
            
            # Add NSG to subnet mapping (avoid duplicates)
            if [ -n "${SUBNET_TO_NSG_IDS[$subnet_id]}" ]; then
                if [[ ! " ${SUBNET_TO_NSG_IDS[$subnet_id]} " =~ " $nsg_id " ]]; then
                    SUBNET_TO_NSG_IDS[$subnet_id]="${SUBNET_TO_NSG_IDS[$subnet_id]} $nsg_id"
                fi
            else
                SUBNET_TO_NSG_IDS[$subnet_id]="$nsg_id"
            fi
            
            # Increment VNIC count for this subnet-nsg pair
            local count_key="${subnet_id}|${nsg_id}"
            local current_count="${SUBNET_NSG_VNIC_COUNT[$count_key]:-0}"
            SUBNET_NSG_VNIC_COUNT[$count_key]=$((current_count + 1))
        done
    done
    
    echo -e "${GREEN}Data loaded.${NC}"
    echo ""
    
    for vcn_id in $VCN_IDS; do
        local VCN_INFO=$(echo "$ALL_VCNS" | jq -r ".[] | select(.id == \"$vcn_id\")")
        local VCN_NAME=$(echo "$VCN_INFO" | jq -r '."display-name"')
        local VCN_CIDR=$(echo "$VCN_INFO" | jq -r '."cidr-blocks"[0] // "N/A"')
        local VCN_STATE=$(echo "$VCN_INFO" | jq -r '."lifecycle-state" // "N/A"')
        
        # Color for state
        local state_color="$GREEN"
        [[ "$VCN_STATE" != "AVAILABLE" ]] && state_color="$RED"
        
        # Get subnets for this VCN
        local SUBNET_IDS=$(echo "$ALL_SUBNETS" | jq -r ".[] | select(.\"vcn-id\" == \"$vcn_id\") | .id" 2>/dev/null)
        
        # Count total VNICs in this VCN (sum of VNICs in all subnets of this VCN)
        local total_vnics_in_vcn=0
        for subnet_id in $SUBNET_IDS; do
            # Sum up VNIC counts for all NSGs in this subnet
            for nsg_id in $NSG_LIST; do
                local count_key="${subnet_id}|${nsg_id}"
                local count="${SUBNET_NSG_VNIC_COUNT[$count_key]:-0}"
                total_vnics_in_vcn=$((total_vnics_in_vcn + count))
            done
        done
        
        echo -e "${BOLD}${MAGENTA}VCN: ${GREEN}$VCN_NAME${NC} ${WHITE}[${CYAN}$VCN_CIDR${WHITE}]${NC} ${WHITE}[${state_color}$VCN_STATE${WHITE}]${NC} ${CYAN}(${total_vnics_in_vcn} VNICs)${NC} ${WHITE}(${YELLOW}$vcn_id${WHITE})${NC}"
        
        # Get NSG IDs for this VCN
        local VCN_NSG_IDS=$(echo "$NSG_DATA" | jq -r ".[] | select(.\"vcn-id\" == \"$vcn_id\") | .id" 2>/dev/null)
        
        if [ -z "$SUBNET_IDS" ]; then
            echo -e "  ${YELLOW}No subnets found in this VCN${NC}"
            echo ""
            continue
        fi
        
        # Track which NSGs have been shown under a subnet (for unmatched NSGs)
        declare -A MATCHED_NSG_IDS
        
        # Process each subnet
        for subnet_id in $SUBNET_IDS; do
            local SUBNET_INFO=$(echo "$ALL_SUBNETS" | jq -r ".[] | select(.id == \"$subnet_id\")")
            local SUBNET_NAME=$(echo "$SUBNET_INFO" | jq -r '."display-name"')
            local SUBNET_CIDR=$(echo "$SUBNET_INFO" | jq -r '."cidr-block"')
            local SUBNET_STATE=$(echo "$SUBNET_INFO" | jq -r '."lifecycle-state" // "N/A"')
            local PROHIBIT_PUBLIC=$(echo "$SUBNET_INFO" | jq -r '."prohibit-public-ip-on-vnic"')
            
            # Determine access type
            local ACCESS="Public"
            local access_color="${LIGHT_GREEN}"
            if [ "$PROHIBIT_PUBLIC" = "true" ]; then
                ACCESS="Private"
                access_color="${RED}"
            fi
            
            # State color
            local subnet_state_color="$GREEN"
            [[ "$SUBNET_STATE" != "AVAILABLE" ]] && subnet_state_color="$RED"
            
            # Print subnet info
            printf "  ${BOLD}${WHITE}Subnet:${NC} ${GREEN}%-30s${NC} ${WHITE}[${CYAN}%-18s${WHITE}]${NC} ${WHITE}[${access_color}%-7s${WHITE}]${NC} ${WHITE}[${subnet_state_color}%-9s${WHITE}]${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "$SUBNET_NAME" "$SUBNET_CIDR" "$ACCESS" "$SUBNET_STATE" "$subnet_id"
            
            # Get NSGs with VNICs in this subnet
            local nsg_ids_in_subnet="${SUBNET_TO_NSG_IDS[$subnet_id]}"
            
            if [ -n "$nsg_ids_in_subnet" ]; then
                # Convert to array and count
                local nsg_array=($nsg_ids_in_subnet)
                local nsg_count=${#nsg_array[@]}
                local i=0
                
                for nsg_id in "${nsg_array[@]}"; do
                    ((i++))
                    
                    # Mark this NSG as matched
                    MATCHED_NSG_IDS[$nsg_id]=1
                    
                    local nsg_name=$(echo "$NSG_DATA" | jq -r ".[] | select(.id == \"$nsg_id\") | .\"display-name\"")
                    local nsg_state=$(echo "$NSG_DATA" | jq -r ".[] | select(.id == \"$nsg_id\") | .\"lifecycle-state\" // \"N/A\"")
                    
                    local nsg_state_color="$GREEN"
                    [[ "$nsg_state" != "AVAILABLE" ]] && nsg_state_color="$RED"
                    
                    # Get VNIC count for this subnet-nsg pair
                    local count_key="${subnet_id}|${nsg_id}"
                    local vnic_count="${SUBNET_NSG_VNIC_COUNT[$count_key]:-0}"
                    
                    # Use └─ for last item, ├─ for others
                    local prefix="├─"
                    [[ $i -eq $nsg_count ]] && prefix="└─"
                    
                    printf "          ${BOLD}${BLUE}${prefix} NSG:${NC} ${WHITE}%-30s${NC} ${CYAN}(%d VNICs)${NC}              ${WHITE}[${nsg_state_color}%-9s${WHITE}]${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                        "$nsg_name" "$vnic_count" "$nsg_state" "$nsg_id"
                done
            fi
            
            echo ""
        done
        
        # Show unmatched NSGs in this VCN (NSGs with no VNICs in any subnet of this VCN)
        local unmatched_nsgs=()
        for nsg_id in $VCN_NSG_IDS; do
            [ -z "$nsg_id" ] && continue
            
            if [ -z "${MATCHED_NSG_IDS[$nsg_id]}" ]; then
                local nsg_name=$(echo "$NSG_DATA" | jq -r ".[] | select(.id == \"$nsg_id\") | .\"display-name\"")
                local nsg_state=$(echo "$NSG_DATA" | jq -r ".[] | select(.id == \"$nsg_id\") | .\"lifecycle-state\" // \"N/A\"")
                local vnic_count=$(cat "$NSG_VNIC_TEMP_DIR/$nsg_id.json" 2>/dev/null | jq 'length' 2>/dev/null)
                vnic_count=${vnic_count:-0}
                unmatched_nsgs+=("${nsg_name}|${nsg_state}|${nsg_id}|${vnic_count}")
            fi
        done
        
        if [ ${#unmatched_nsgs[@]} -gt 0 ]; then
            echo -e "  ${BOLD}${WHITE}NSGs without VNICs in subnets:${NC}"
            local i=0
            local total=${#unmatched_nsgs[@]}
            for nsg_entry in "${unmatched_nsgs[@]}"; do
                ((i++))
                IFS='|' read -r nsg_name nsg_state nsg_id vnic_count <<< "$nsg_entry"
                
                local nsg_state_color="$GREEN"
                [[ "$nsg_state" != "AVAILABLE" ]] && nsg_state_color="$RED"
                
                local prefix="├─"
                [[ $i -eq $total ]] && prefix="└─"
                
                printf "          ${BOLD}${BLUE}${prefix} NSG:${NC} ${WHITE}%-30s${NC} ${YELLOW}(%d VNICs total)${NC}         ${WHITE}[${nsg_state_color}%-9s${WHITE}]${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                    "$nsg_name" "$vnic_count" "$nsg_state" "$nsg_id"
            done
            echo ""
        fi
        
        # Clear matched NSGs for next VCN
        unset MATCHED_NSG_IDS
        
        echo ""
    done
}

# ============================================================================
# OPTION 2: LIST NSG WITH VNIC DETAILS
# ============================================================================

list_nsg_vnics() {
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}NSG with VNIC Details${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Compartment:${NC} ${GREEN}$COMPARTMENT_NAME${NC}"
    echo -e "${CYAN}OCID:${NC}        ${YELLOW}$COMPARTMENT_ID${NC}"
    echo -e "${CYAN}Region:${NC}      ${WHITE}$REGION${NC}"
    echo ""
    
    load_base_data
    
    NSG_LIST=$(echo "$NSG_DATA" | jq -r '.[].id' 2>/dev/null)
    
    if [ -z "$NSG_LIST" ]; then
        echo -e "${RED}No NSGs found in compartment${NC}"
        return
    fi
    
    # Create temp directory for NSG VNIC data
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" RETURN
    
    NSG_VNIC_TEMP_DIR="$TEMP_DIR/nsg_vnics"
    mkdir -p "$NSG_VNIC_TEMP_DIR"
    
    # Pre-fetch NSG VNIC data in parallel
    echo -e "${YELLOW}Fetching VNIC data for each NSG...${NC}"
    
    for nsg_id in $NSG_LIST; do
        {
            local cache_file="$CACHE_DIR/nsg_vnics_${nsg_id}.json"
            if is_cache_valid "$cache_file"; then
                cat "$cache_file" > "$NSG_VNIC_TEMP_DIR/$nsg_id.json"
            else
                local vnic_data=$(oci network nsg vnics list \
                    --region $REGION \
                    --nsg-id $nsg_id \
                    --all \
                    --query 'data' 2>/dev/null)
                echo "$vnic_data" > "$cache_file"
                echo "$vnic_data" > "$NSG_VNIC_TEMP_DIR/$nsg_id.json"
            fi
        } &
    done
    wait
    
    echo -e "${GREEN}NSG VNIC data fetched.${NC}"
    echo ""
    
    # Process each NSG
    for nsg_id in $NSG_LIST; do
        NSG_NAME=$(echo "$NSG_DATA" | jq -r ".[] | select(.id == \"$nsg_id\") | .\"display-name\"")
        
        [ -z "$NSG_NAME" ] && continue
        
        VNIC_DATA=$(cat "$NSG_VNIC_TEMP_DIR/$nsg_id.json" 2>/dev/null)
        VNIC_COUNT=$(echo "$VNIC_DATA" | jq 'length' 2>/dev/null)
        VNIC_COUNT=${VNIC_COUNT:-0}
        
        # Get VNIC IDs and count cached
        VNIC_IDS=$(echo "$VNIC_DATA" | jq -r '.[]."vnic-id"' 2>/dev/null)
        CACHED_COUNT=0
        if [ "$VNIC_COUNT" -gt 0 ] 2>/dev/null; then
            for vid in $VNIC_IDS; do
                if [ -f "$CACHE_VNIC_DETAILS_DIR/${vid}.json" ] && is_cache_valid "$CACHE_VNIC_DETAILS_DIR/${vid}.json"; then
                    ((CACHED_COUNT++))
                fi
            done
        fi
        
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${BLUE}NSG:${NC} ${BOLD}$NSG_NAME${NC} ${GREEN}($VNIC_COUNT VNICs attached (${CACHED_COUNT} cached))${NC} ${BLUE}ID:${NC} $nsg_id"
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        
        if [ "$VNIC_COUNT" -eq 0 ] 2>/dev/null; then
            echo -e "${YELLOW}  No VNICs attached to this NSG${NC}"
            echo ""
            continue
        fi
        
        echo ""
        
        # Fetch VNIC details
        VNIC_DETAILS=$(echo "$VNIC_IDS" | xargs -P $PARALLEL_WORKERS -I {} bash -c 'fetch_vnic_cached "$@"' _ {} | jq -s '.')
        
        # Print header
        printf "${BOLD}${CYAN}%-15s %-20s %-15s %-30s %-95s %-95s${NC}\n" \
            "PRIVATE IP" "SUBNET" "VCN" "HOSTNAME" "INSTANCE OCID" "VNIC OCID"
        printf "${BOLD}${CYAN}%-15s %-20s %-15s %-30s %-95s %-95s${NC}\n" \
            "---------------" "--------------------" "---------------" "------------------------------" "-----------------------------------------------------------------------------------------------" "-----------------------------------------------------------------------------------------------"
        
        for vnic_id in $VNIC_IDS; do
            VNIC_INFO=$(echo "$VNIC_DETAILS" | jq -r ".[] | select(.id == \"$vnic_id\")")
            
            [ -z "$VNIC_INFO" ] || [ "$VNIC_INFO" == "null" ] && continue
            
            SUBNET_ID=$(echo "$VNIC_INFO" | jq -r '."subnet-id"')
            PRIVATE_IP=$(echo "$VNIC_INFO" | jq -r '."private-ip"')
            HOSTNAME=$(echo "$VNIC_INFO" | jq -r '."hostname-label" // "N/A"')
            
            INSTANCE_ID=$(echo "$ALL_VNIC_ATTACHMENTS" | jq -r ".[] | select(.\"vnic-id\" == \"$vnic_id\") | .\"instance-id\"")
            [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "null" ] && INSTANCE_ID="N/A"
            
            SUBNET_INFO=$(echo "$ALL_SUBNETS" | jq -r ".[] | select(.id == \"$SUBNET_ID\")")
            if [ -n "$SUBNET_INFO" ] && [ "$SUBNET_INFO" != "null" ]; then
                SUBNET_NAME=$(echo "$SUBNET_INFO" | jq -r '."display-name"')
                VCN_ID=$(echo "$SUBNET_INFO" | jq -r '."vcn-id"')
                VCN_INFO=$(echo "$ALL_VCNS" | jq -r ".[] | select(.id == \"$VCN_ID\")")
                VCN_NAME=$(echo "$VCN_INFO" | jq -r '."display-name" // "N/A"')
            else
                SUBNET_NAME="N/A"
                VCN_NAME="N/A"
            fi
            
            printf "${BOLD}%-15s${NC} %-20s %-15s %-30s ${YELLOW}%-95s %-95s${NC}\n" \
                "$PRIVATE_IP" "$(echo "$SUBNET_NAME" | cut -c1-18)" "$(echo "$VCN_NAME" | cut -c1-13)" "$(echo "$HOSTNAME" | cut -c1-28)" "$INSTANCE_ID" "$vnic_id"
        done
        echo ""
    done
}

# ============================================================================
# OPTION 3: LIST NSG SECURITY RULES
# ============================================================================

# Helper functions for NSG rules
format_protocol() {
    local protocol=$1
    case $protocol in
        "6") echo "TCP" ;;
        "17") echo "UDP" ;;
        "1") echo "ICMP" ;;
        "all") echo "ALL" ;;
        *) echo "$protocol" ;;
    esac
}

resolve_nsg_name() {
    local nsg_id=$1
    local nsg_name=$(echo "$NSG_DATA" | jq -r ".[] | select(.id == \"$nsg_id\") | .\"display-name\"" 2>/dev/null)
    if [ -n "$nsg_name" ] && [ "$nsg_name" != "null" ]; then
        echo "$nsg_name"
    else
        echo "$(echo $nsg_id | cut -d'.' -f5 | cut -c1-12)..."
    fi
}

format_source_dest() {
    local type=$1
    local value=$2
    
    if [ "$type" == "CIDR_BLOCK" ]; then
        echo "$value"
    elif [ "$type" == "SERVICE_CIDR_BLOCK" ]; then
        echo "$value"
    elif [ "$type" == "NETWORK_SECURITY_GROUP" ]; then
        local nsg_name=$(resolve_nsg_name "$value")
        echo "NSG:${nsg_name}"
    else
        echo "$value"
    fi
}

format_port_range() {
    local min=$1
    local max=$2
    
    if [ "$min" == "null" ] || [ -z "$min" ]; then
        echo "ALL"
    elif [ "$min" == "$max" ]; then
        echo "$min"
    else
        echo "$min-$max"
    fi
}

truncate_desc() {
    local desc=$1
    local max_len=${2:-40}
    if [ "$desc" == "null" ] || [ -z "$desc" ]; then
        echo "-"
    elif [ ${#desc} -gt $max_len ]; then
        echo "${desc:0:$((max_len-3))}..."
    else
        echo "$desc"
    fi
}

list_nsg_rules() {
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}NSG Security Rules${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Compartment:${NC} ${GREEN}$COMPARTMENT_NAME${NC}"
    echo -e "${CYAN}OCID:${NC}        ${YELLOW}$COMPARTMENT_ID${NC}"
    echo -e "${CYAN}Region:${NC}      ${WHITE}$REGION${NC}"
    echo ""
    
    load_base_data
    
    NSG_LIST=$(echo "$NSG_DATA" | jq -r '.[].id' 2>/dev/null)
    
    if [ -z "$NSG_LIST" ]; then
        echo -e "${RED}No NSGs found in compartment${NC}"
        return
    fi
    
    NSG_COUNT=$(echo "$NSG_LIST" | wc -l)
    echo -e "${GREEN}Processing $NSG_COUNT NSG(s)${NC}"
    echo ""
    
    # Batch fetch all NSG rules in parallel
    echo -e "${YELLOW}Fetching NSG rules...${NC}"
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" RETURN
    
    for nsg_id in $NSG_LIST; do
        {
            local cache_file="$CACHE_NSG_RULES_DIR/${nsg_id}.json"
            if is_cache_valid "$cache_file"; then
                cat "$cache_file" > "$TEMP_DIR/$nsg_id.json"
            else
                local rules=$(oci network nsg rules list \
                    --region $REGION \
                    --nsg-id $nsg_id \
                    --all \
                    --query 'data' 2>/dev/null)
                echo "$rules" > "$cache_file"
                echo "$rules" > "$TEMP_DIR/$nsg_id.json"
            fi
        } &
    done
    wait
    
    echo -e "${GREEN}Rules fetched.${NC}"
    echo ""
    
    for nsg_id in $NSG_LIST; do
        NSG_NAME=$(echo "$NSG_DATA" | jq -r ".[] | select(.id == \"$nsg_id\") | .\"display-name\"")
        
        [ -z "$NSG_NAME" ] && continue
        
        RULES_FILE="$TEMP_DIR/$nsg_id.json"
        
        # Read rules data, handle null/empty
        RULES_DATA=$(cat "$RULES_FILE" 2>/dev/null)
        if [ -z "$RULES_DATA" ] || [ "$RULES_DATA" == "null" ]; then
            RULES_DATA="[]"
        fi
        
        INGRESS_COUNT=$(echo "$RULES_DATA" | jq '[.[] | select(.direction == "INGRESS")] | length' 2>/dev/null)
        EGRESS_COUNT=$(echo "$RULES_DATA" | jq '[.[] | select(.direction == "EGRESS")] | length' 2>/dev/null)
        INGRESS_COUNT=${INGRESS_COUNT:-0}
        EGRESS_COUNT=${EGRESS_COUNT:-0}
        
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${BLUE}NSG:${NC} ${BOLD}$NSG_NAME${NC} ${GREEN}(${INGRESS_COUNT} ingress / ${EGRESS_COUNT} egress)${NC} ${BLUE}ID:${NC} ${YELLOW}$nsg_id${NC}"
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        
        if [ "$INGRESS_COUNT" -eq 0 ] && [ "$EGRESS_COUNT" -eq 0 ]; then
            echo -e "${YELLOW}  No security rules defined for this NSG${NC}"
            echo ""
            continue
        fi
        
        echo ""
        
        # Print consolidated table header
        printf "${BOLD}${CYAN}%-4s %-8s %-8s %-30s %-12s %-12s %-80s${NC}\n" \
            "#" "DIR" "PROTO" "SOURCE/DESTINATION" "SRC PORTS" "DST PORTS" "DESCRIPTION"
        printf "${CYAN}%-4s %-8s %-8s %-30s %-12s %-12s %-80s${NC}\n" \
            "----" "--------" "--------" "------------------------------" "------------" "------------" "--------------------------------------------------------------------------------"
        
        # Rule counter - use file to persist across subshells
        local rule_counter_file=$(mktemp)
        echo "1" > "$rule_counter_file"
        
        # Process INGRESS rules first, then EGRESS
        echo "$RULES_DATA" | jq -c '.[] | select(.direction == "INGRESS")' 2>/dev/null | while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            
            local rule_num=$(cat "$rule_counter_file")
            
            local direction=$(echo "$rule" | jq -r '.direction')
            local protocol=$(echo "$rule" | jq -r '.protocol // "all"')
            local stateless=$(echo "$rule" | jq -r '."is-stateless" // false')
            local description=$(echo "$rule" | jq -r '.description // ""')
            
            local target target_type
            target=$(echo "$rule" | jq -r '.source // "N/A"')
            target_type=$(echo "$rule" | jq -r '."source-type" // "CIDR_BLOCK"')
            
            local tcp_options=$(echo "$rule" | jq -r '."tcp-options" // empty')
            local udp_options=$(echo "$rule" | jq -r '."udp-options" // empty')
            
            local src_port_min="null" src_port_max="null" dst_port_min="null" dst_port_max="null"
            
            if [ -n "$tcp_options" ] && [ "$tcp_options" != "null" ]; then
                src_port_min=$(echo "$tcp_options" | jq -r '."source-port-range".min // "null"')
                src_port_max=$(echo "$tcp_options" | jq -r '."source-port-range".max // "null"')
                dst_port_min=$(echo "$tcp_options" | jq -r '."destination-port-range".min // "null"')
                dst_port_max=$(echo "$tcp_options" | jq -r '."destination-port-range".max // "null"')
            fi
            
            if [ -n "$udp_options" ] && [ "$udp_options" != "null" ]; then
                src_port_min=$(echo "$udp_options" | jq -r '."source-port-range".min // "null"')
                src_port_max=$(echo "$udp_options" | jq -r '."source-port-range".max // "null"')
                dst_port_min=$(echo "$udp_options" | jq -r '."destination-port-range".min // "null"')
                dst_port_max=$(echo "$udp_options" | jq -r '."destination-port-range".max // "null"')
            fi
            
            # Format fields
            local protocol_fmt=$(format_protocol "$protocol")
            local target_fmt=$(format_source_dest "$target_type" "$target")
            local src_ports_fmt=$(format_port_range "$src_port_min" "$src_port_max")
            local dst_ports_fmt=$(format_port_range "$dst_port_min" "$dst_port_max")
            local desc_fmt=$(truncate_desc "$description" 80)
            
            local target_trunc="${target_fmt:0:28}"
            local dir_display="INGRESS"
            [ "$stateless" == "true" ] && dir_display="INGRESS*"
            
            local target_color="$WHITE"
            [ "$target_type" == "CIDR_BLOCK" ] && target_color="$CYAN"
            [ "$target_type" == "SERVICE_CIDR_BLOCK" ] && target_color="$MAGENTA"
            [ "$target_type" == "NETWORK_SECURITY_GROUP" ] && target_color="$YELLOW"
            
            printf "${WHITE}%-4s${NC} ${GREEN}%-8s${NC} ${ORANGE}%-8s${NC} ${target_color}%-30s${NC} ${WHITE}%-12s${NC} ${WHITE}${BOLD}%-12s${NC} %-80s\n" \
                "$rule_num" "$dir_display" "$protocol_fmt" "$target_trunc" "$src_ports_fmt" "$dst_ports_fmt" "$desc_fmt"
            
            echo $((rule_num + 1)) > "$rule_counter_file"
        done
        
        # Process EGRESS rules
        echo "$RULES_DATA" | jq -c '.[] | select(.direction == "EGRESS")' 2>/dev/null | while IFS= read -r rule; do
            [ -z "$rule" ] && continue
            
            local rule_num=$(cat "$rule_counter_file")
            
            local direction=$(echo "$rule" | jq -r '.direction')
            local protocol=$(echo "$rule" | jq -r '.protocol // "all"')
            local stateless=$(echo "$rule" | jq -r '."is-stateless" // false')
            local description=$(echo "$rule" | jq -r '.description // ""')
            
            local target target_type
            target=$(echo "$rule" | jq -r '.destination // "N/A"')
            target_type=$(echo "$rule" | jq -r '."destination-type" // "CIDR_BLOCK"')
            
            local tcp_options=$(echo "$rule" | jq -r '."tcp-options" // empty')
            local udp_options=$(echo "$rule" | jq -r '."udp-options" // empty')
            
            local src_port_min="null" src_port_max="null" dst_port_min="null" dst_port_max="null"
            
            if [ -n "$tcp_options" ] && [ "$tcp_options" != "null" ]; then
                src_port_min=$(echo "$tcp_options" | jq -r '."source-port-range".min // "null"')
                src_port_max=$(echo "$tcp_options" | jq -r '."source-port-range".max // "null"')
                dst_port_min=$(echo "$tcp_options" | jq -r '."destination-port-range".min // "null"')
                dst_port_max=$(echo "$tcp_options" | jq -r '."destination-port-range".max // "null"')
            fi
            
            if [ -n "$udp_options" ] && [ "$udp_options" != "null" ]; then
                src_port_min=$(echo "$udp_options" | jq -r '."source-port-range".min // "null"')
                src_port_max=$(echo "$udp_options" | jq -r '."source-port-range".max // "null"')
                dst_port_min=$(echo "$udp_options" | jq -r '."destination-port-range".min // "null"')
                dst_port_max=$(echo "$udp_options" | jq -r '."destination-port-range".max // "null"')
            fi
            
            # Format fields
            local protocol_fmt=$(format_protocol "$protocol")
            local target_fmt=$(format_source_dest "$target_type" "$target")
            local src_ports_fmt=$(format_port_range "$src_port_min" "$src_port_max")
            local dst_ports_fmt=$(format_port_range "$dst_port_min" "$dst_port_max")
            local desc_fmt=$(truncate_desc "$description" 80)
            
            local target_trunc="${target_fmt:0:28}"
            local dir_display="EGRESS"
            [ "$stateless" == "true" ] && dir_display="EGRESS*"
            
            local target_color="$WHITE"
            [ "$target_type" == "CIDR_BLOCK" ] && target_color="$CYAN"
            [ "$target_type" == "SERVICE_CIDR_BLOCK" ] && target_color="$MAGENTA"
            [ "$target_type" == "NETWORK_SECURITY_GROUP" ] && target_color="$YELLOW"
            
            printf "${WHITE}%-4s${NC} ${BLUE}%-8s${NC} ${ORANGE}%-8s${NC} ${target_color}%-30s${NC} ${WHITE}%-12s${NC} ${WHITE}${BOLD}%-12s${NC} %-80s\n" \
                "$rule_num" "$dir_display" "$protocol_fmt" "$target_trunc" "$src_ports_fmt" "$dst_ports_fmt" "$desc_fmt"
            
            echo $((rule_num + 1)) > "$rule_counter_file"
        done
        
        # Cleanup counter file
        rm -f "$rule_counter_file"
        
        echo ""
    done
    
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}Legend:${NC} ${GREEN}INGRESS${NC}=inbound  ${BLUE}EGRESS${NC}=outbound  ${ORANGE}Protocol${NC}  ${CYAN}CIDR${NC}  ${MAGENTA}Service${NC}  ${YELLOW}NSG Ref${NC}  ${WHITE}${BOLD}Ports${NC}  *=Stateless"
}

# ============================================================================
# MAIN MENU
# ============================================================================

show_menu() {
    clear
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║                                        OCI Network Explorer                                                 ║${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Compartment:${NC} ${GREEN}$COMPARTMENT_NAME${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}OCID:${NC}        ${YELLOW}$COMPARTMENT_ID${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Region:${NC}      ${WHITE}$REGION${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${BOLD}Cache TTL:${NC}   ${WHITE}${CACHE_TTL_SECONDS}s${NC}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                                                                                                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${GREEN}1)${NC} List VCN and Subnet Details                                                                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${GREEN}2)${NC} List NSG with VNIC Details                                                                               ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${GREEN}3)${NC} List NSG Security Rules                                                                                  ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                                                                                                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}r)${NC} Force Refresh Cache                                                                                      ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${YELLOW}c)${NC} Clear Cache                                                                                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}  ${RED}q)${NC} Quit                                                                                                     ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}║${NC}                                                                                                              ${BOLD}${CYAN}║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -ne "${BOLD}Select an option: ${NC}"
}

pause_for_input() {
    echo ""
    echo -ne "${BOLD}Press Enter to continue...${NC}"
    read
}

# Main interactive loop
main() {
    # Run option 1 automatically on startup
    clear
    START_TIME=$(date +%s.%N)
    list_vcn_subnets 2>&1 | tee -a "$LOGFILE"
    END_TIME=$(date +%s.%N)
    ELAPSED=$(echo "$END_TIME - $START_TIME" | bc)
    echo -e "${CYAN}Execution time: ${ELAPSED}s${NC}"
    pause_for_input
    
    while true; do
        show_menu
        read -r choice
        
        case $choice in
            1)
                clear
                START_TIME=$(date +%s.%N)
                list_vcn_subnets 2>&1 | tee -a "$LOGFILE"
                END_TIME=$(date +%s.%N)
                ELAPSED=$(echo "$END_TIME - $START_TIME" | bc)
                echo -e "${CYAN}Execution time: ${ELAPSED}s${NC}"
                pause_for_input
                ;;
            2)
                clear
                START_TIME=$(date +%s.%N)
                list_nsg_vnics 2>&1 | tee -a "$LOGFILE"
                END_TIME=$(date +%s.%N)
                ELAPSED=$(echo "$END_TIME - $START_TIME" | bc)
                echo -e "${CYAN}Execution time: ${ELAPSED}s${NC}"
                pause_for_input
                ;;
            3)
                clear
                START_TIME=$(date +%s.%N)
                list_nsg_rules 2>&1 | tee -a "$LOGFILE"
                END_TIME=$(date +%s.%N)
                ELAPSED=$(echo "$END_TIME - $START_TIME" | bc)
                echo -e "${CYAN}Execution time: ${ELAPSED}s${NC}"
                pause_for_input
                ;;
            r|R)
                FORCE_REFRESH=true
                echo -e "${YELLOW}Cache refresh enabled for next operation${NC}"
                sleep 1
                ;;
            c|C)
                echo -e "${YELLOW}Clearing cache directory: $CACHE_DIR${NC}"
                rm -rf "$CACHE_DIR"
                mkdir -p "$CACHE_DIR"
                mkdir -p "$CACHE_VNIC_DETAILS_DIR"
                mkdir -p "$CACHE_NSG_RULES_DIR"
                echo -e "${GREEN}Cache cleared.${NC}"
                sleep 1
                ;;
            q|Q)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${NC}"
                sleep 1
                ;;
        esac
    done
}

# Run main
main