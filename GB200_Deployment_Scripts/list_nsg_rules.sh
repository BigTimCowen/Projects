#!/bin/bash

LOGFILE="nsg_rules_evaluation.log"
exec > >(tee -a $LOGFILE) 2>&1

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
ORANGE='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BOLD}${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║          NSG Security Rules Evaluation Report                 ║${NC}"
echo -e "${BOLD}${CYAN}║                    $(date '+%Y-%m-%d %H:%M:%S')                        ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Source variables if you have them
if [ -f ./variables.sh ]; then
    source ./variables.sh
fi

# Set defaults if not in variables.sh
COMPARTMENT_ID="${COMPARTMENT_ID:-your-compartment-id}"
REGION="${REGION:-us-phoenix-1}"

# Optional: Filter by specific NSG (can be OCID or Name)
NSG_FILTER="${1:-}"

echo -e "${BOLD}Compartment:${NC} $COMPARTMENT_ID"
echo -e "${BOLD}Region:${NC} $REGION"
echo ""

# Pre-fetch all NSGs to get names for NSG references
echo -e "${YELLOW}Pre-fetching all NSGs for name resolution...${NC}"
ALL_NSGS=$(oci network nsg list \
    --region $REGION \
    --compartment-id $COMPARTMENT_ID \
    --all \
    --query 'data' 2>/dev/null)

# Create associative array for NSG ID to Name mapping
declare -A NSG_NAMES
while IFS= read -r nsg; do
    nsg_id=$(echo "$nsg" | jq -r '.id')
    nsg_name=$(echo "$nsg" | jq -r '."display-name"')
    NSG_NAMES[$nsg_id]=$nsg_name
done < <(echo "$ALL_NSGS" | jq -c '.[]')

# Get NSGs to process
if [ -z "$NSG_FILTER" ]; then
    # No filter - process all NSGs
    NSG_DATA="$ALL_NSGS"
    NSG_LIST=$(echo "$NSG_DATA" | jq -r '.[].id')
elif [[ "$NSG_FILTER" == ocid1.networksecuritygroup.* ]]; then
    # Filter is an OCID
    echo -e "${YELLOW}Filtering by NSG OCID: $NSG_FILTER${NC}"
    NSG_LIST="$NSG_FILTER"
    NSG_DATA=$(oci network nsg get \
        --region $REGION \
        --nsg-id $NSG_FILTER \
        --query 'data' 2>/dev/null | jq -s '.')
else
    # Filter is a name - search for matching NSGs
    echo -e "${YELLOW}Searching for NSG name containing: '$NSG_FILTER'${NC}"
    NSG_DATA=$(echo "$ALL_NSGS" | jq -c "[.[] | select(.\"display-name\" | contains(\"$NSG_FILTER\"))]")
    NSG_LIST=$(echo "$NSG_DATA" | jq -r '.[].id')
    
    if [ -z "$NSG_LIST" ]; then
        echo -e "${RED}No NSGs found matching name: '$NSG_FILTER'${NC}"
        echo -e "${YELLOW}Available NSGs:${NC}"
        echo "$ALL_NSGS" | jq -r '.[] | "  - " + ."display-name"'
        exit 1
    fi
    
    MATCH_COUNT=$(echo "$NSG_LIST" | wc -l)
    echo -e "${GREEN}Found $MATCH_COUNT matching NSG(s):${NC}"
    echo "$NSG_DATA" | jq -r '.[] | "  - " + ."display-name" + " (" + .id + ")"'
    echo ""
fi

# Check if we got any NSGs
if [ -z "$NSG_LIST" ]; then
    echo -e "${RED}No NSGs found${NC}"
    exit 0
fi

NSG_COUNT=$(echo "$NSG_LIST" | wc -l)
echo -e "${GREEN}Processing $NSG_COUNT NSG(s)${NC}"
echo ""

# Batch fetch all NSG rules in parallel
echo -e "${YELLOW}Batch fetching all NSG rules (parallel)...${NC}"
TEMP_DIR=$(mktemp -d)

# Fetch rules for all NSGs in parallel
echo "$NSG_LIST" | xargs -P 10 -I {} bash -c "
    oci network nsg rules list \
        --region $REGION \
        --nsg-id {} \
        --all \
        --query 'data' 2>/dev/null > $TEMP_DIR/{}.json
"

echo -e "${GREEN}Batch fetch complete.${NC}"
echo ""

# Function to format protocol
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

# Function to resolve NSG name from ID
resolve_nsg_name() {
    local nsg_id=$1
    if [ -n "${NSG_NAMES[$nsg_id]}" ]; then
        echo "${NSG_NAMES[$nsg_id]}"
    else
        echo "$(echo $nsg_id | cut -d'.' -f5 | cut -c1-12)..."
    fi
}

# Function to format source/destination
format_source_dest() {
    local type=$1
    local value=$2
    
    if [ "$type" == "CIDR_BLOCK" ]; then
        echo "$value"
    elif [ "$type" == "SERVICE_CIDR_BLOCK" ]; then
        echo "$value"
    elif [ "$type" == "NETWORK_SECURITY_GROUP" ]; then
        # Resolve NSG ID to name
        local nsg_name=$(resolve_nsg_name "$value")
        echo "NSG:${nsg_name}"
    else
        echo "$value"
    fi
}

# Function to format port range
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

# Function to get numeric port for sorting
get_port_number() {
    local min=$1
    local max=$2
    
    if [ "$min" == "null" ] || [ -z "$min" ]; then
        echo "99999"  # ALL ports go to end
    else
        echo "$min"
    fi
}

# Function to truncate description
truncate_desc() {
    local desc=$1
    if [ "$desc" == "null" ] || [ -z "$desc" ]; then
        echo "-"
    elif [ ${#desc} -gt 80 ]; then
        echo "${desc:0:77}..."
    else
        echo "$desc"
    fi
}

# Function to print table header
print_table_header() {
    local direction=$1
    if [ "$direction" == "INGRESS" ]; then
        echo -e "${BOLD}${GREEN}Rule # | Direction | Protocol | Source                         | Src Ports | Dst Ports    | Description                                                                      ${NC}"
        echo -e "${GREEN}-------|-----------|----------|--------------------------------|-----------|--------------|-----------------------------------------------------------------------------------${NC}"
    else
        echo -e "${BOLD}${BLUE}Rule # | Direction | Protocol | Destination                    | Src Ports | Dst Ports    | Description                                                                      ${NC}"
        echo -e "${BLUE}-------|-----------|----------|--------------------------------|-----------|--------------|-----------------------------------------------------------------------------------${NC}"
    fi
}

# Function to process a single rule and return formatted data
process_rule_data() {
    local rule=$1
    local direction=$2
    
    protocol=$(echo "$rule" | jq -r '.protocol // "all"')
    
    if [ "$direction" == "INGRESS" ]; then
        target=$(echo "$rule" | jq -r '.source // "N/A"')
        target_type=$(echo "$rule" | jq -r '."source-type" // "CIDR_BLOCK"')
    else
        target=$(echo "$rule" | jq -r '.destination // "N/A"')
        target_type=$(echo "$rule" | jq -r '."destination-type" // "CIDR_BLOCK"')
    fi
    
    stateless=$(echo "$rule" | jq -r '."is-stateless" // false')
    description=$(echo "$rule" | jq -r '.description // ""')
    
    # TCP/UDP options
    tcp_options=$(echo "$rule" | jq -r '."tcp-options" // empty')
    udp_options=$(echo "$rule" | jq -r '."udp-options" // empty')
    
    src_port_min="null"
    src_port_max="null"
    dst_port_min="null"
    dst_port_max="null"
    
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
    
    # Get port number for sorting
    dst_port_num=$(get_port_number "$dst_port_min" "$dst_port_max")
    
    # Output: dst_port_num|protocol|target|target_type|src_port_min|src_port_max|dst_port_min|dst_port_max|stateless|description
    echo "$dst_port_num|$protocol|$target|$target_type|$src_port_min|$src_port_max|$dst_port_min|$dst_port_max|$stateless|$description"
}

# Function to print formatted rule
print_rule() {
    local rule_num=$1
    local direction=$2
    local rule_data=$3
    local color=$4
    
    IFS='|' read -r dst_port_num protocol target target_type src_port_min src_port_max dst_port_min dst_port_max stateless description <<< "$rule_data"
    
    # Format all fields as plain text first
    protocol_plain=$(format_protocol "$protocol")
    target_plain=$(format_source_dest "$target_type" "$target")
    src_ports_plain=$(format_port_range "$src_port_min" "$src_port_max")
    dst_ports_plain=$(format_port_range "$dst_port_min" "$dst_port_max")
    description_plain=$(truncate_desc "$description")
    
    # Truncate target to 30 chars for proper alignment
    target_truncated="${target_plain:0:30}"
    
    # Direction indicator
    dir_display="$direction"
    if [ "$stateless" == "true" ]; then
        dir_display="${dir_display}*"
    fi
    
    # Print table row with colors
    printf "${color}%-6s${NC} | ${color}%-9s${NC} | ${ORANGE}%-8s${NC} | " "$rule_num" "$dir_display" "$protocol_plain"
    
    # Color code the target based on type
    if [ "$target_type" == "CIDR_BLOCK" ]; then
        printf "${CYAN}%-30s${NC} | " "$target_truncated"
    elif [ "$target_type" == "SERVICE_CIDR_BLOCK" ]; then
        printf "${MAGENTA}%-30s${NC} | " "$target_truncated"
    elif [ "$target_type" == "NETWORK_SECURITY_GROUP" ]; then
        printf "${YELLOW}%-30s${NC} | " "$target_truncated"
    else
        printf "${WHITE}%-30s${NC} | " "$target_truncated"
    fi
    
    printf "${WHITE}${BOLD}%-9s${NC} | ${WHITE}${BOLD}%-12s${NC} | ${color}%-80s${NC}\n" "$src_ports_plain" "$dst_ports_plain" "$description_plain"
}

# Process each NSG
for nsg_id in $NSG_LIST; do
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    
    # Get NSG details from pre-fetched data
    NSG_NAME="${NSG_NAMES[$nsg_id]}"
    
    if [ -z "$NSG_NAME" ]; then
        echo -e "${RED}ERROR: Unable to find NSG $nsg_id${NC}"
        continue
    fi
    
    echo -e "${BOLD}${BLUE}NSG Name:${NC} ${BOLD}${WHITE}$NSG_NAME${NC}"
    echo ""
    
    # Load rules from temp file
    RULES_FILE="$TEMP_DIR/$nsg_id.json"
    
    if [ ! -f "$RULES_FILE" ]; then
        echo -e "${YELLOW}  ⚠ No rules file found for this NSG${NC}"
        echo ""
        continue
    fi
    
    RULES_DATA=$(cat "$RULES_FILE")
    RULE_COUNT=$(echo "$RULES_DATA" | jq 'length' 2>/dev/null)
    RULE_COUNT=${RULE_COUNT:-0}
    
    if [ "$RULE_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}  ⚠ No security rules defined for this NSG${NC}"
        echo ""
        continue
    fi
    
    echo -e "${GREEN}Found $RULE_COUNT security rule(s)${NC}"
    echo ""
    
    # Separate ingress and egress rules
    INGRESS_RULES=$(echo "$RULES_DATA" | jq -c '[.[] | select(.direction == "INGRESS")]')
    EGRESS_RULES=$(echo "$RULES_DATA" | jq -c '[.[] | select(.direction == "EGRESS")]')
    
    INGRESS_COUNT=$(echo "$INGRESS_RULES" | jq 'length')
    EGRESS_COUNT=$(echo "$EGRESS_RULES" | jq 'length')
    
    # Display Ingress Rules
    if [ "$INGRESS_COUNT" -gt 0 ]; then
        echo -e "${BOLD}${GREEN}▼▼▼ INGRESS RULES ($INGRESS_COUNT) ▼▼▼${NC}"
        echo ""
        print_table_header "INGRESS"
        
        # Process and sort rules by destination port
        declare -a sorted_rules=()
        while IFS= read -r rule; do
            rule_data=$(process_rule_data "$rule" "INGRESS")
            sorted_rules+=("$rule_data")
        done < <(echo "$INGRESS_RULES" | jq -c '.[]')
        
        # Sort by destination port (first field)
        IFS=$'\n' sorted_rules=($(sort -t'|' -k1 -n <<<"${sorted_rules[*]}"))
        unset IFS
        
        # Print sorted rules
        rule_num=1
        for rule_data in "${sorted_rules[@]}"; do
            print_rule "$rule_num" "INGRESS" "$rule_data" "$GREEN"
            ((rule_num++))
        done
        echo ""
        
        unset sorted_rules
    fi
    
    # Display Egress Rules
    if [ "$EGRESS_COUNT" -gt 0 ]; then
        echo -e "${BOLD}${BLUE}▲▲▲ EGRESS RULES ($EGRESS_COUNT) ▲▲▲${NC}"
        echo ""
        print_table_header "EGRESS"
        
        # Process and sort rules by destination port
        declare -a sorted_rules=()
        while IFS= read -r rule; do
            rule_data=$(process_rule_data "$rule" "EGRESS")
            sorted_rules+=("$rule_data")
        done < <(echo "$EGRESS_RULES" | jq -c '.[]')
        
        # Sort by destination port (first field)
        IFS=$'\n' sorted_rules=($(sort -t'|' -k1 -n <<<"${sorted_rules[*]}"))
        unset IFS
        
        # Print sorted rules
        rule_num=1
        for rule_data in "${sorted_rules[@]}"; do
            print_rule "$rule_num" "EGRESS" "$rule_data" "$BLUE"
            ((rule_num++))
        done
        echo ""
        
        unset sorted_rules
    fi
    
    echo ""
done

# Cleanup temp directory
rm -rf "$TEMP_DIR"

echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}Evaluation completed at $(date)${NC}"
echo ""
echo -e "${BOLD}Legend:${NC}"
echo -e "  ${GREEN}Green${NC} - Ingress rules (inbound traffic)"
echo -e "  ${BLUE}Blue${NC} - Egress rules (outbound traffic)"
echo -e "  ${ORANGE}Orange${NC} - Protocol"
echo -e "  ${CYAN}Cyan${NC} - CIDR blocks"
echo -e "  ${MAGENTA}Magenta${NC} - Service CIDR blocks"
echo -e "  ${YELLOW}Yellow${NC} - NSG references"
echo -e "  ${WHITE}${BOLD}White/Bold${NC} - Port numbers"
echo -e "  * - Stateless rule (return traffic must be explicitly allowed)"
