# This script is used to quickly assess the instance configured and what network / security rules are provided.
# This requires that oci cli to be configured on the host.
# v1.0
#
#
# 1. Get your instance OCID (from metadata)
INSTANCE_ID=$(curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/id)
COMPARTMENT_ID=$(curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/compartmentId)

echo "Instance ID: $INSTANCE_ID"
echo "Compartment ID: $COMPARTMENT_ID"

# 2. Get VNIC and Subnet info
VNIC_ID=$(oci compute vnic-attachment list --instance-id "$INSTANCE_ID" --compartment-id "$COMPARTMENT_ID" | jq -r '.data[0]."vnic-id"')
SUBNET_ID=$(oci network vnic get --vnic-id "$VNIC_ID" | jq -r '.data."subnet-id"')
VCN_ID=$(oci network subnet get --subnet-id "$SUBNET_ID" | jq -r '.data."vcn-id"')

echo "VNIC ID: $VNIC_ID"
echo "Subnet ID: $SUBNET_ID"
echo "VCN ID: $VCN_ID"

# 3. Get Security List IDs
SECURITY_LIST_IDS=$(oci network subnet get --subnet-id "$SUBNET_ID" | jq -r '.data."security-list-ids"[]')

echo "Security Lists:"
echo "$SECURITY_LIST_IDS"

# 4. Check each Security List's egress rules
for SL_ID in $SECURITY_LIST_IDS; do
    echo ""
    echo "Security List: $SL_ID"
    oci network security-list get --security-list-id "$SL_ID" | jq '.data."egress-security-rules"'
done

# 5. Check NSGs attached to VNIC
NSG_IDS=$(oci network vnic get --vnic-id "$VNIC_ID" | jq -r '.data."nsg-ids"[]?')

if [ -n "$NSG_IDS" ]; then
    echo ""
    echo "NSGs attached:"
    for NSG_ID in $NSG_IDS; do
        echo ""
        echo "NSG: $NSG_ID"
        oci network nsg rules list --nsg-id "$NSG_ID" | jq '[.data[] | select(.direction == "EGRESS")]'
    done
fi

# 6. Check Internet Gateway
echo ""
echo "Internet Gateways:"
oci network internet-gateway list --compartment-id "$COMPARTMENT_ID" --vcn-id "$VCN_ID" | jq '.data[] | {id: .id, name: ."display-name", state: ."lifecycle-state"}'

# 7. Check Route Table
ROUTE_TABLE_ID=$(oci network subnet get --subnet-id "$SUBNET_ID" | jq -r '.data."route-table-id"')
echo ""
echo "Route Table Rules:"
oci network route-table get --rt-id "$ROUTE_TABLE_ID" | jq '.data."route-rules"'