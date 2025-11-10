# This generates a script on the host to test for internet connectivity and highlight potential issues.
# This requires oci cli to be on the host
# v1.0
#

cat > /tmp/oci-network-audit.sh << 'EOF'
#!/bin/bash
# OCI Network Security Audit Script
# Validates Security Lists and NSGs for proper egress rules

set -e

echo "=========================================="
echo "OCI Network Security Audit"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get instance metadata
INSTANCE_ID=$(curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/id 2>/dev/null || echo "UNKNOWN")
REGION=$(curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/region 2>/dev/null || echo "UNKNOWN")
COMPARTMENT_ID=$(curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/compartmentId 2>/dev/null || echo "UNKNOWN")

echo "Instance ID: $INSTANCE_ID"
echo "Region: $REGION"
echo "Compartment ID: $COMPARTMENT_ID"
echo ""

if [ "$INSTANCE_ID" = "UNKNOWN" ]; then
    echo -e "${RED}ERROR: Could not fetch instance metadata. Are you running this on an OCI instance?${NC}"
    echo "If running remotely, you'll need to manually set INSTANCE_ID"
    exit 1
fi

# Get VNIC information
echo "=========================================="
echo "1. Getting VNIC Information"
echo "=========================================="

VNIC_ATTACHMENTS=$(oci compute vnic-attachment list \
    --instance-id "$INSTANCE_ID" \
    --compartment-id "$COMPARTMENT_ID" \
    2>/dev/null)

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to get VNIC attachments. Check OCI CLI configuration.${NC}"
    exit 1
fi

VNIC_ID=$(echo "$VNIC_ATTACHMENTS" | jq -r '.data[0]."vnic-id"')
echo "Primary VNIC ID: $VNIC_ID"

# Get VNIC details
VNIC_DETAILS=$(oci network vnic get --vnic-id "$VNIC_ID" 2>/dev/null)
SUBNET_ID=$(echo "$VNIC_DETAILS" | jq -r '.data."subnet-id"')
PRIVATE_IP=$(echo "$VNIC_DETAILS" | jq -r '.data."private-ip"')
PUBLIC_IP=$(echo "$VNIC_DETAILS" | jq -r '.data."public-ip" // "None"')

echo "Subnet ID: $SUBNET_ID"
echo "Private IP: $PRIVATE_IP"
echo "Public IP: $PUBLIC_IP"

# Get NSGs attached to VNIC
NSG_IDS=$(echo "$VNIC_DETAILS" | jq -r '.data."nsg-ids"[]?' 2>/dev/null)
if [ -n "$NSG_IDS" ]; then
    echo "NSGs attached to VNIC:"
    echo "$NSG_IDS" | while read nsg; do
        echo "  - $nsg"
    done
else
    echo "No NSGs attached to VNIC"
fi
echo ""

# Get Subnet details
echo "=========================================="
echo "2. Getting Subnet Information"
echo "=========================================="

SUBNET_DETAILS=$(oci network subnet get --subnet-id "$SUBNET_ID" 2>/dev/null)
VCN_ID=$(echo "$SUBNET_DETAILS" | jq -r '.data."vcn-id"')
ROUTE_TABLE_ID=$(echo "$SUBNET_DETAILS" | jq -r '.data."route-table-id"')
SECURITY_LIST_IDS=$(echo "$SUBNET_DETAILS" | jq -r '.data."security-list-ids"[]')

echo "VCN ID: $VCN_ID"
echo "Route Table ID: $ROUTE_TABLE_ID"
echo "Security List IDs:"
echo "$SECURITY_LIST_IDS" | while read sl; do
    echo "  - $sl"
done
echo ""

# Check VCN for Internet Gateway
echo "=========================================="
echo "3. Checking Internet Gateway"
echo "=========================================="

IGW=$(oci network internet-gateway list \
    --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$VCN_ID" 2>/dev/null)

IGW_COUNT=$(echo "$IGW" | jq '.data | length')
if [ "$IGW_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Internet Gateway found${NC}"
    echo "$IGW" | jq -r '.data[] | "  ID: \(.id)\n  State: \(."lifecycle-state")\n  Name: \(."display-name")"'
else
    echo -e "${RED}✗ No Internet Gateway found!${NC}"
    echo "  Your VCN needs an Internet Gateway for outbound connectivity"
fi
echo ""

# Check Route Table
echo "=========================================="
echo "4. Checking Route Table"
echo "=========================================="

ROUTE_TABLE=$(oci network route-table get --rt-id "$ROUTE_TABLE_ID" 2>/dev/null)
echo "Route Table: $(echo "$ROUTE_TABLE" | jq -r '.data."display-name"')"
echo ""
echo "Routes:"

ROUTES=$(echo "$ROUTE_TABLE" | jq -r '.data."route-rules"[]?')
if [ -n "$ROUTES" ]; then
    echo "$ROUTE_TABLE" | jq -r '.data."route-rules"[] | "  Destination: \(."destination") → \(."network-entity-id")"'
    
    # Check for default route to IGW
    DEFAULT_ROUTE=$(echo "$ROUTE_TABLE" | jq -r '.data."route-rules"[] | select(."destination" == "0.0.0.0/0") | ."network-entity-id"')
    if [ -n "$DEFAULT_ROUTE" ] && [[ "$DEFAULT_ROUTE" == *"internetgateway"* ]]; then
        echo -e "${GREEN}✓ Default route to Internet Gateway exists${NC}"
    else
        echo -e "${RED}✗ No default route to Internet Gateway!${NC}"
        echo "  Add route: 0.0.0.0/0 → Internet Gateway"
    fi
else
    echo -e "${YELLOW}⚠ No routes configured${NC}"
fi
echo ""

# Analyze Security Lists
echo "=========================================="
echo "5. Analyzing Security Lists"
echo "=========================================="

check_egress_rules() {
    local rules=$1
    local name=$2
    
    # Check for allow all egress
    local allow_all=$(echo "$rules" | jq -r '.[] | select(.destination == "0.0.0.0/0" and .protocol == "all")')
    
    if [ -n "$allow_all" ]; then
        echo -e "  ${GREEN}✓ Allow all egress (0.0.0.0/0 all protocols)${NC}"
        return 0
    fi
    
    # Check for HTTP/HTTPS
    local http=$(echo "$rules" | jq -r '.[] | select(.destination == "0.0.0.0/0" and .protocol == "6") | select(."tcp-options"."destination-port-range".min == 80 or ."tcp-options"."destination-port-range".min == 443)')
    
    if [ -n "$http" ]; then
        echo -e "  ${GREEN}✓ HTTP/HTTPS egress allowed${NC}"
    else
        echo -e "  ${RED}✗ No HTTP/HTTPS egress rule${NC}"
    fi
    
    # Check for ICMP
    local icmp=$(echo "$rules" | jq -r '.[] | select(.destination == "0.0.0.0/0" and .protocol == "1")')
    
    if [ -n "$icmp" ]; then
        echo -e "  ${GREEN}✓ ICMP egress allowed${NC}"
    else
        echo -e "  ${YELLOW}⚠ No ICMP egress rule${NC}"
    fi
    
    # Show all egress rules
    echo ""
    echo "  All Egress Rules:"
    if [ "$(echo "$rules" | jq 'length')" -eq 0 ]; then
        echo -e "  ${RED}✗ NO EGRESS RULES CONFIGURED!${NC}"
        echo "  ${RED}  This is why you have no outbound connectivity${NC}"
    else
        echo "$rules" | jq -r '.[] | "    • Dest: \(.destination) | Proto: \(.protocol) | Stateless: \(.["is-stateless"]) | Desc: \(.description // "N/A")"'
    fi
}

echo "$SECURITY_LIST_IDS" | while read SL_ID; do
    echo "----------------------------------------"
    SL=$(oci network security-list get --security-list-id "$SL_ID" 2>/dev/null)
    SL_NAME=$(echo "$SL" | jq -r '.data."display-name"')
    
    echo "Security List: $SL_NAME"
    echo "ID: $SL_ID"
    echo ""
    
    EGRESS_RULES=$(echo "$SL" | jq '.data."egress-security-rules"')
    check_egress_rules "$EGRESS_RULES" "$SL_NAME"
    echo ""
done

# Analyze NSGs
echo "=========================================="
echo "6. Analyzing Network Security Groups"
echo "=========================================="

if [ -n "$NSG_IDS" ]; then
    echo "$NSG_IDS" | while read NSG_ID; do
        echo "----------------------------------------"
        NSG=$(oci network nsg get --nsg-id "$NSG_ID" 2>/dev/null)
        NSG_NAME=$(echo "$NSG" | jq -r '.data."display-name"')
        
        echo "NSG: $NSG_NAME"
        echo "ID: $NSG_ID"
        echo ""
        
        # Get NSG rules
        NSG_RULES=$(oci network nsg rules list --nsg-id "$NSG_ID" 2>/dev/null)
        
        # Filter egress rules
        EGRESS_RULES=$(echo "$NSG_RULES" | jq '[.data[] | select(.direction == "EGRESS")]')
        
        echo "Egress Rules:"
        check_egress_rules "$EGRESS_RULES" "$NSG_NAME"
        echo ""
    done
else
    echo "No NSGs attached to this instance"
fi
echo ""

# Summary and Recommendations
echo "=========================================="
echo "7. Summary & Recommendations"
echo "=========================================="

echo ""
echo "Current Status:"
echo "  Instance: $INSTANCE_ID"
echo "  Private IP: $PRIVATE_IP"
echo "  Public IP: $PUBLIC_IP"
echo ""

# Determine issues
ISSUES=()

if [ "$IGW_COUNT" -eq 0 ]; then
    ISSUES+=("No Internet Gateway in VCN")
fi

if [ -z "$DEFAULT_ROUTE" ] || [[ "$DEFAULT_ROUTE" != *"internetgateway"* ]]; then
    ISSUES+=("No default route to Internet Gateway")
fi

# Check if ANY security list or NSG has proper egress
HAS_EGRESS=false
echo "$SECURITY_LIST_IDS" | while read SL_ID; do
    SL=$(oci network security-list get --security-list-id "$SL_ID" 2>/dev/null)
    EGRESS_COUNT=$(echo "$SL" | jq '.data."egress-security-rules" | length')
    if [ "$EGRESS_COUNT" -gt 0 ]; then
        HAS_EGRESS=true
    fi
done

if [ "$HAS_EGRESS" = false ]; then
    ISSUES+=("No egress rules in Security Lists")
fi

echo "Issues Found: ${#ISSUES[@]}"
if [ ${#ISSUES[@]} -gt 0 ]; then
    echo ""
    for issue in "${ISSUES[@]}"; do
        echo -e "  ${RED}✗ $issue${NC}"
    done
    
    echo ""
    echo "Recommended Fixes:"
    echo ""
    echo "1. Add Egress Rule to Security List:"
    echo "   oci network security-list update \\"
    echo "     --security-list-id <SECURITY_LIST_ID> \\"
    echo "     --egress-security-rules '[{\"destination\":\"0.0.0.0/0\",\"protocol\":\"all\",\"isStateless\":false}]'"
    echo ""
    echo "2. Or in OCI Console:"
    echo "   Networking → VCN → Security Lists → Add Egress Rule"
    echo "   Destination: 0.0.0.0/0, Protocol: All"
    echo ""
else
    echo -e "${GREEN}✓ Network configuration appears correct${NC}"
    echo ""
    echo "If you still have connectivity issues, check:"
    echo "  - Instance firewall (iptables/firewalld)"
    echo "  - OS-level network configuration"
    echo "  - DNS resolution"
fi

echo ""
echo "=========================================="
echo "Audit Complete"
echo "=========================================="
EOF

chmod +x /tmp/oci-network-audit.sh