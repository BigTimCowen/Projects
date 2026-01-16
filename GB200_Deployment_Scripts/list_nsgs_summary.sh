#!/bin/bash

LOGFILE="nsg_subnet_mapping.log"
exec > >(tee -a $LOGFILE) 2>&1

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${BOLD}${CYAN}NSG to Subnet Mapping - $(date)${NC}"
echo -e "${BOLD}${CYAN}==========================================${NC}"

# Source variables if you have them
if [ -f ./variables.sh ]; then
    source ./variables.sh
fi

# Set defaults if not in variables.sh
COMPARTMENT_ID="${COMPARTMENT_ID:-your-compartment-id}"
REGION="${REGION:-us-phoenix-1}"

# Optional: Filter by specific NSG
NSG_ID="${1:-}"

echo -e "${BOLD}Compartment:${NC} $COMPARTMENT_ID"
echo -e "${BOLD}Region:${NC} $REGION"
echo ""

# Pre-fetch all subnets in the compartment
echo -e "${YELLOW}Pre-fetching subnets...${NC}"
ALL_SUBNETS=$(oci network subnet list \
    --region $REGION \
    --compartment-id $COMPARTMENT_ID \
    --all \
    --query 'data' 2>/dev/null)

echo -e "${GREEN}Pre-fetch complete.${NC}"
echo ""

# Get NSGs
if [ -z "$NSG_ID" ]; then
    echo -e "${YELLOW}Fetching all NSGs in compartment...${NC}"
    NSG_DATA=$(oci network nsg list \
        --region $REGION \
        --compartment-id $COMPARTMENT_ID \
        --all \
        --query 'data' 2>/dev/null)
    NSG_LIST=$(echo "$NSG_DATA" | jq -r '.[].id')
else
    echo -e "${YELLOW}Using specified NSG: $NSG_ID${NC}"
    NSG_LIST="$NSG_ID"
    NSG_DATA=$(oci network nsg get \
        --region $REGION \
        --nsg-id $NSG_ID \
        --query 'data' 2>/dev/null | jq -s '.')
fi

# Check if we got any NSGs
if [ -z "$NSG_LIST" ]; then
    echo -e "${RED}No NSGs found in compartment${NC}"
    exit 0
fi

# Process each NSG
for nsg_id in $NSG_LIST; do
    echo -e "${BOLD}${MAGENTA}========================================${NC}"
    
    # Get NSG name from pre-fetched data
    NSG_NAME=$(echo "$NSG_DATA" | jq -r ".[] | select(.id == \"$nsg_id\") | .\"display-name\"")
    
    if [ -z "$NSG_NAME" ]; then
        echo -e "${RED}ERROR: Unable to find NSG $nsg_id${NC}"
        continue
    fi
    
    echo -e "${BOLD}${BLUE}NSG Name:${NC} ${BOLD}$NSG_NAME${NC}"
    echo -e "${BOLD}${BLUE}NSG OCID:${NC} $nsg_id"
    echo ""
    
    # Get all VNICs attached to this NSG in one call
    VNIC_DATA=$(oci network nsg vnics list \
        --region $REGION \
        --nsg-id $nsg_id \
        --all \
        --query 'data' 2>/dev/null)
    
    VNIC_COUNT=$(echo "$VNIC_DATA" | jq 'length' 2>/dev/null)
    VNIC_COUNT=${VNIC_COUNT:-0}
    
    if [ "$VNIC_COUNT" -eq 0 ] 2>/dev/null; then
        echo -e "${YELLOW}  No VNICs attached to this NSG${NC}"
        echo ""
        continue
    fi
    
    # Get all VNIC IDs
    VNIC_IDS=$(echo "$VNIC_DATA" | jq -r '.[]."vnic-id"')
    
    echo -e "${BOLD}${GREEN}Attached Subnets:${NC}"
    echo ""
    
    # Batch fetch all VNIC details
    VNIC_DETAILS=$(echo "$VNIC_IDS" | xargs -P 10 -I {} oci network vnic get \
        --region $REGION \
        --vnic-id {} \
        --query 'data' 2>/dev/null | jq -s '.')
    
    # Track unique subnets to avoid duplicates
    declare -A SEEN_SUBNETS
    
    # Process each VNIC
    for vnic_id in $VNIC_IDS; do
        # Get VNIC info from batch results
        VNIC_INFO=$(echo "$VNIC_DETAILS" | jq -r ".[] | select(.id == \"$vnic_id\")")
        
        if [ -z "$VNIC_INFO" ] || [ "$VNIC_INFO" == "null" ]; then
            continue
        fi
        
        SUBNET_ID=$(echo "$VNIC_INFO" | jq -r '."subnet-id"')
        
        # Skip if we've already seen this subnet for this NSG
        if [ -n "${SEEN_SUBNETS[$SUBNET_ID]}" ]; then
            continue
        fi
        
        SEEN_SUBNETS[$SUBNET_ID]=1
        
        # Get Subnet details from pre-fetched data
        SUBNET_INFO=$(echo "$ALL_SUBNETS" | jq -r ".[] | select(.id == \"$SUBNET_ID\")")
        
        if [ -n "$SUBNET_INFO" ] && [ "$SUBNET_INFO" != "null" ]; then
            SUBNET_NAME=$(echo "$SUBNET_INFO" | jq -r '."display-name"')
            
            echo -e "  ${CYAN}Subnet Name:${NC} ${BOLD}$SUBNET_NAME${NC}"
            echo -e "  ${CYAN}Subnet ID:${NC} $SUBNET_ID"
            echo ""
        fi
    done
    
    unset SEEN_SUBNETS
done

echo -e "${BOLD}${MAGENTA}========================================${NC}"
echo -e "${BOLD}${CYAN}Mapping completed at $(date)${NC}"
