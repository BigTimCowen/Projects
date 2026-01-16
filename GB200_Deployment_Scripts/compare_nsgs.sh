#!/bin/bash

LOGFILE="nsg_comparison.log"
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
echo -e "${BOLD}${CYAN}║              NSG Comparison Tool                              ║${NC}"
echo -e "${BOLD}${CYAN}║                    $(date '+%Y-%m-%d %H:%M:%S')                        ║${NC}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Source variables
if [ -f ./variables.sh ]; then
    source ./variables.sh
else
    echo -e "${RED}Error: variables.sh not found${NC}"
    exit 1
fi

# Check required variables
if [ -z "$COMPARTMENT_ID" ] || [ -z "$REGION" ]; then
    echo -e "${RED}Error: COMPARTMENT_ID and REGION must be set in variables.sh${NC}"
    exit 1
fi

echo -e "${BOLD}Compartment:${NC} $COMPARTMENT_ID"
echo -e "${BOLD}Region:${NC} $REGION"
echo ""

# Pre-fetch all NSGs for name resolution
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

NSG_COUNT=$(echo "$ALL_NSGS" | jq 'length')

if [ "$NSG_COUNT" -eq 0 ]; then
    echo -e "${RED}No NSGs found in compartment${NC}"
    exit 1
fi

echo -e "${GREEN}Found $NSG_COUNT NSG(s)${NC}"
echo ""

# Display NSGs with numbers
echo -e "${BOLD}${BLUE}Available NSGs:${NC}"
echo ""

declare -a NSG_IDS
declare -a NSG_NAMES_ARRAY

index=1
while IFS= read -r nsg; do
    nsg_id=$(echo "$nsg" | jq -r '.id')
    nsg_name=$(echo "$nsg" | jq -r '."display-name"')
    NSG_IDS[$index]=$nsg_id
    NSG_NAMES_ARRAY[$index]=$nsg_name
    printf "${CYAN}%2d.${NC} %s\n" "$index" "$nsg_name"
    ((index++))
done < <(echo "$ALL_NSGS" | jq -c '.[]')

echo ""

# Function to validate selection
validate_selection() {
    local selection=$1
    local max=$2
    
    if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    if [ "$selection" -lt 1 ] || [ "$selection" -gt "$max" ]; then
        return 1
    fi
    
    return 0
}

# Select first NSG
while true; do
    echo -ne "${BOLD}Select first NSG (1-$NSG_COUNT): ${NC}"
    read NSG1_SELECTION
    
    if validate_selection "$NSG1_SELECTION" "$NSG_COUNT"; then
        NSG1_ID=${NSG_IDS[$NSG1_SELECTION]}
        NSG1_NAME=${NSG_NAMES_ARRAY[$NSG1_SELECTION]}
        echo -e "${GREEN}Selected: $NSG1_NAME${NC}"
        break
    else
        echo -e "${RED}Invalid selection. Please enter a number between 1 and $NSG_COUNT${NC}"
    fi
done

echo ""

# Select second NSG
while true; do
    echo -ne "${BOLD}Select second NSG (1-$NSG_COUNT): ${NC}"
    read NSG2_SELECTION
    
    if [ "$NSG2_SELECTION" -eq "$NSG1_SELECTION" ]; then
        echo -e "${RED}Please select a different NSG${NC}"
        continue
    fi
    
    if validate_selection "$NSG2_SELECTION" "$NSG_COUNT"; then
        NSG2_ID=${NSG_IDS[$NSG2_SELECTION]}
        NSG2_NAME=${NSG_NAMES_ARRAY[$NSG2_SELECTION]}
        echo -e "${GREEN}Selected: $NSG2_NAME${NC}"
        break
    else
        echo -e "${RED}Invalid selection. Please enter a number between 1 and $NSG_COUNT${NC}"
    fi
done

echo ""
echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}Comparing:${NC}"
echo -e "${CYAN}NSG 1:${NC} $NSG1_NAME"
echo -e "${CYAN}NSG 2:${NC} $NSG2_NAME"
echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo ""

# Fetch rules for both NSGs
echo -e "${YELLOW}Fetching rules for both NSGs...${NC}"

NSG1_RULES=$(oci network nsg rules list \
    --region $REGION \
    --nsg-id $NSG1_ID \
    --all \
    --query 'data' 2>/dev/null)

NSG2_RULES=$(oci network nsg rules list \
    --region $REGION \
    --nsg-id $NSG2_ID \
    --all \
    --query 'data' 2>/dev/null)

echo -e "${GREEN}Rules fetched successfully${NC}"
echo ""

# Function to resolve NSG name from ID
resolve_nsg_name() {
    local nsg_id=$1
    if [ -n "${NSG_NAMES[$nsg_id]}" ]; then
        echo "NSG:${NSG_NAMES[$nsg_id]}"
    else
        echo "NSG:$(echo $nsg_id | cut -d'.' -f5 | cut -c1-12)..."
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
        resolve_nsg_name "$value"
    else
        echo "$value"
    fi
}

# Function to normalize a rule for comparison
normalize_rule() {
    local rule=$1
    
    direction=$(echo "$rule" | jq -r '.direction')
    protocol=$(echo "$rule" | jq -r '.protocol // "all"')
    source=$(echo "$rule" | jq -r '.source // "null"')
    source_type=$(echo "$rule" | jq -r '."source-type" // "CIDR_BLOCK"')
    destination=$(echo "$rule" | jq -r '.destination // "null"')
    destination_type=$(echo "$rule" | jq -r '."destination-type" // "CIDR_BLOCK"')
    stateless=$(echo "$rule" | jq -r '."is-stateless" // false')
    description=$(echo "$rule" | jq -r '.description // ""')
    
    # Format source and destination with names
    source_formatted=$(format_source_dest "$source_type" "$source")
    destination_formatted=$(format_source_dest "$destination_type" "$destination")
    
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
    
    # Create normalized signature (use original IDs for comparison, but include formatted names for display)
    echo "${direction}|${protocol}|${source}|${destination}|${src_port_min}|${src_port_max}|${dst_port_min}|${dst_port_max}|${stateless}|${source_formatted}|${destination_formatted}|${source_type}|${destination_type}"
}

# Function to format protocol
format_protocol() {
    case $1 in
        "6") echo "TCP" ;;
        "17") echo "UDP" ;;
        "1") echo "ICMP" ;;
        "all") echo "ALL" ;;
        *) echo "$1" ;;
    esac
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

# Function to display a rule
display_rule() {
    local rule_sig=$1
    local color=$2
    
    IFS='|' read -r direction protocol source destination src_port_min src_port_max dst_port_min dst_port_max stateless source_formatted destination_formatted source_type destination_type <<< "$rule_sig"
    
    proto_display=$(format_protocol "$protocol")
    src_ports=$(format_port_range "$src_port_min" "$src_port_max")
    dst_ports=$(format_port_range "$dst_port_min" "$dst_port_max")
    
    stateless_indicator=""
    if [ "$stateless" == "true" ]; then
        stateless_indicator=" ${RED}[STATELESS]${NC}"
    fi
    
    # Truncate source/destination to 40 chars
    if [ "$direction" == "INGRESS" ]; then
        target="${source_formatted:0:40}"
    else
        target="${destination_formatted:0:40}"
    fi
    
    # Color code based on type
    if [ "$direction" == "INGRESS" ]; then
        target_type="$source_type"
    else
        target_type="$destination_type"
    fi
    
    if [ "$target_type" == "CIDR_BLOCK" ]; then
        target_color="${CYAN}"
    elif [ "$target_type" == "SERVICE_CIDR_BLOCK" ]; then
        target_color="${MAGENTA}"
    elif [ "$target_type" == "NETWORK_SECURITY_GROUP" ]; then
        target_color="${YELLOW}"
    else
        target_color="${WHITE}"
    fi
    
    printf "  ${color}%-8s${NC} | ${ORANGE}%-8s${NC} | ${target_color}%-40s${NC} | ${WHITE}${BOLD}%-9s${NC} → ${WHITE}${BOLD}%-12s${NC}%b\n" \
        "$direction" "$proto_display" "$target" "$src_ports" "$dst_ports" "$stateless_indicator"
}

# Build rule signatures
declare -A NSG1_RULE_SIGS
declare -A NSG2_RULE_SIGS

while IFS= read -r rule; do
    sig=$(normalize_rule "$rule")
    # Use first 9 fields as key (excluding formatted names)
    key=$(echo "$sig" | cut -d'|' -f1-9)
    NSG1_RULE_SIGS["$key"]="$sig"
done < <(echo "$NSG1_RULES" | jq -c '.[]')

while IFS= read -r rule; do
    sig=$(normalize_rule "$rule")
    # Use first 9 fields as key (excluding formatted names)
    key=$(echo "$sig" | cut -d'|' -f1-9)
    NSG2_RULE_SIGS["$key"]="$sig"
done < <(echo "$NSG2_RULES" | jq -c '.[]')

# Find rules only in NSG1
echo -e "${BOLD}${RED}Rules ONLY in $NSG1_NAME:${NC}"
echo -e "${BOLD}  Direction | Protocol | Source/Destination                       | Src Ports → Dst Ports${NC}"
echo -e "  ----------|----------|------------------------------------------|---------------------------"

only_in_nsg1=0
for key in "${!NSG1_RULE_SIGS[@]}"; do
    if [ -z "${NSG2_RULE_SIGS[$key]}" ]; then
        display_rule "${NSG1_RULE_SIGS[$key]}" "$RED"
        ((only_in_nsg1++))
    fi
done

if [ "$only_in_nsg1" -eq 0 ]; then
    echo -e "  ${YELLOW}No unique rules${NC}"
fi

echo ""

# Find rules only in NSG2
echo -e "${BOLD}${GREEN}Rules ONLY in $NSG2_NAME:${NC}"
echo -e "${BOLD}  Direction | Protocol | Source/Destination                       | Src Ports → Dst Ports${NC}"
echo -e "  ----------|----------|------------------------------------------|---------------------------"

only_in_nsg2=0
for key in "${!NSG2_RULE_SIGS[@]}"; do
    if [ -z "${NSG1_RULE_SIGS[$key]}" ]; then
        display_rule "${NSG2_RULE_SIGS[$key]}" "$GREEN"
        ((only_in_nsg2++))
    fi
done

if [ "$only_in_nsg2" -eq 0 ]; then
    echo -e "  ${YELLOW}No unique rules${NC}"
fi

echo ""

# Find common rules
echo -e "${BOLD}${BLUE}Rules in BOTH NSGs (Common):${NC}"
echo -e "${BOLD}  Direction | Protocol | Source/Destination                       | Src Ports → Dst Ports${NC}"
echo -e "  ----------|----------|------------------------------------------|---------------------------"

common_rules=0
for key in "${!NSG1_RULE_SIGS[@]}"; do
    if [ -n "${NSG2_RULE_SIGS[$key]}" ]; then
        display_rule "${NSG1_RULE_SIGS[$key]}" "$BLUE"
        ((common_rules++))
    fi
done

if [ "$common_rules" -eq 0 ]; then
    echo -e "  ${YELLOW}No common rules${NC}"
fi

echo ""

# Summary
echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}Summary:${NC}"
echo -e "  Total rules in ${CYAN}$NSG1_NAME${NC}: ${#NSG1_RULE_SIGS[@]}"
echo -e "  Total rules in ${CYAN}$NSG2_NAME${NC}: ${#NSG2_RULE_SIGS[@]}"
echo -e "  ${RED}Only in $NSG1_NAME${NC}: $only_in_nsg1"
echo -e "  ${GREEN}Only in $NSG2_NAME${NC}: $only_in_nsg2"
echo -e "  ${BLUE}Common to both${NC}: $common_rules"

if [ "$only_in_nsg1" -eq 0 ] && [ "$only_in_nsg2" -eq 0 ]; then
    echo ""
    echo -e "${BOLD}${GREEN}✓ NSGs are identical!${NC}"
else
    echo ""
    echo -e "${BOLD}${YELLOW}⚠ NSGs have differences${NC}"
fi

echo -e "${BOLD}${MAGENTA}════════════════════════════════════════════════════════════════${NC}"
