#!/bin/bash

# OCI POC Setup Script with User Group Management
# Creates compartment
# Groups - OCI-HPC-POC-Group, 
# Dynamic group - tc_instance_principal
# adds user from OCI Shell session running script
# Creates policies for HPC deployment

set -e  # Exit on any error

echo "=== OCI POC Setup Script Starting ==="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get tenancy OCID (needed for compartment creation)
print_status "Getting tenancy OCID..."
TENANCY_OCID=$(oci iam compartment list --all --query "data[?\"lifecycle-state\"=='ACTIVE' && \"name\"=='root'].id | [0]" --raw-output 2>/dev/null)

# Alternative method if the above doesn't work - get from config
if [ -z "$TENANCY_OCID" ] || [ "$TENANCY_OCID" = "null" ]; then
    print_status "Trying alternative method to get tenancy OCID..."
    TENANCY_OCID=$(oci iam region list --query "data[0].key" --raw-output 2>/dev/null | head -1)
    if [ -n "$TENANCY_OCID" ]; then
        # Get tenancy from config file
        TENANCY_OCID=$(grep -E "^tenancy\s*=" ~/.oci/config | head -1 | cut -d'=' -f2 | tr -d ' ')
    fi
fi

# Final fallback - use a simple compartment list to extract tenancy
if [ -z "$TENANCY_OCID" ] || [ "$TENANCY_OCID" = "null" ]; then
    print_status "Using compartment list to determine tenancy..."
    TENANCY_OCID=$(oci iam compartment list --compartment-id-in-subtree false --query "data[0].\"compartment-id\"" --raw-output 2>/dev/null)
fi

if [ -z "$TENANCY_OCID" ] || [ "$TENANCY_OCID" = "null" ]; then
    print_error "Failed to get tenancy OCID. Please check your OCI CLI configuration."
    exit 1
fi

print_status "Tenancy OCID: $TENANCY_OCID"
echo

# Get current user OCID from environment variable
print_status "Getting current user from OCI Cloud Shell environment..."
CURRENT_USER_OCID="$OCI_CS_USER_OCID"

if [ -z "$CURRENT_USER_OCID" ] || [ "$CURRENT_USER_OCID" = "null" ]; then
    print_error "OCI_CS_USER_OCID environment variable not found or empty."
    print_error "Please ensure you're running this in OCI Cloud Shell."
    exit 1
fi

# Get username for display
CURRENT_USERNAME=$(oci iam user get --user-id "$CURRENT_USER_OCID" --query "data.name" --raw-output 2>/dev/null)
print_status "Detected user: $CURRENT_USERNAME ($CURRENT_USER_OCID)"
echo

# Step 1: Create POC compartment
print_status "Creating POC compartment..."

# Check if compartment already exists
EXISTING_COMPARTMENT=$(oci iam compartment list --compartment-id "$TENANCY_OCID" --name "POC" --lifecycle-state "ACTIVE" 2>/dev/null | jq -r '.data[0].id // empty')

if [ -n "$EXISTING_COMPARTMENT" ]; then
    print_warning "Compartment 'POC' already exists with OCID: $EXISTING_COMPARTMENT"
    POC_OCID="$EXISTING_COMPARTMENT"
else
    # Create the compartment
    CREATE_RESULT=$(oci iam compartment create \
        --compartment-id "$TENANCY_OCID" \
        --name "POC" \
        --description "Proof of Concept compartment for HPC deployment" \
        --wait-for-state "ACTIVE" \
        --max-wait-seconds 300)
    
    POC_OCID=$(echo "$CREATE_RESULT" | jq -r '.data.id')
    
    if [ -z "$POC_OCID" ] || [ "$POC_OCID" = "null" ]; then
        print_error "Failed to create POC compartment"
        exit 1
    fi
    
    print_status "POC compartment created successfully!"
fi

print_status "POC Compartment OCID: $POC_OCID"
echo

# Step 2: Create user group
print_status "Creating user group 'OCI-HPC-POC-Group'..."

# Check if group already exists
EXISTING_GROUP=$(oci iam group list --name "OCI-HPC-POC-Group" 2>/dev/null | jq -r '.data[0].id // empty')

if [ -n "$EXISTING_GROUP" ]; then
    print_warning "Group 'OCI-HPC-POC-Group' already exists with OCID: $EXISTING_GROUP"
    GROUP_OCID="$EXISTING_GROUP"
else
    # Create the group
    CREATE_GROUP_RESULT=$(oci iam group create \
        --compartment-id "$TENANCY_OCID" \
        --name "OCI-HPC-POC-Group" \
        --description "Group for users with access to POC HPC resources")
    
    GROUP_OCID=$(echo "$CREATE_GROUP_RESULT" | jq -r '.data.id')
    
    if [ -z "$GROUP_OCID" ] || [ "$GROUP_OCID" = "null" ]; then
        print_error "Failed to create user group"
        exit 1
    fi
    
    print_status "User group created successfully!"
fi

print_status "Group OCID: $GROUP_OCID"
echo

# Step 3: Add current user to the group
print_status "Adding current user to OCI-HPC-POC-Group..."

# Check if user is already in the group
USER_IN_GROUP=$(oci iam group list-users --group-id "$GROUP_OCID" --query "data[?id=='$CURRENT_USER_OCID'].id | [0]" --raw-output 2>/dev/null)

if [ -n "$USER_IN_GROUP" ] && [ "$USER_IN_GROUP" != "null" ]; then
    print_warning "User $CURRENT_USERNAME is already in the group"
else
    # Add user to group
    oci iam group add-user \
        --group-id "$GROUP_OCID" \
        --user-id "$CURRENT_USER_OCID" >/dev/null
    
    print_status "User $CURRENT_USERNAME added to group successfully!"
fi
echo

# Step 4: Create dynamic group
print_status "Creating dynamic group 'tc_instance_principal'..."

# Check if dynamic group already exists
EXISTING_DG=$(oci iam dynamic-group list --name "tc_instance_principal" 2>/dev/null | jq -r '.data[0].id // empty')

if [ -n "$EXISTING_DG" ]; then
    print_warning "Dynamic group 'tc_instance_principal' already exists with OCID: $EXISTING_DG"
else
    # Create the dynamic group
    MATCHING_RULE="Any {instance.compartment.id = '$POC_OCID'}"
    
    CREATE_DG_RESULT=$(oci iam dynamic-group create \
        --compartment-id "$TENANCY_OCID" \
        --name "tc_instance_principal" \
        --description "Dynamic group for instances in POC compartment" \
        --matching-rule "$MATCHING_RULE")
    
    DG_OCID=$(echo "$CREATE_DG_RESULT" | jq -r '.data.id')
    
    if [ -z "$DG_OCID" ] || [ "$DG_OCID" = "null" ]; then
        print_error "Failed to create dynamic group"
        exit 1
    fi
    
    print_status "Dynamic group created successfully!"
    print_status "Dynamic group OCID: $DG_OCID"
fi
echo

# Step 5: Create policy
print_status "Creating policy 'OCI-HPC-Deployment-Policies'..."

# Check if policy already exists
EXISTING_POLICY=$(oci iam policy list --compartment-id "$TENANCY_OCID" --name "OCI-HPC-Deployment-Policies" 2>/dev/null | jq -r '.data[0].id // empty')

if [ -n "$EXISTING_POLICY" ]; then
    print_warning "Policy 'OCI-HPC-Deployment-Policies' already exists with OCID: $EXISTING_POLICY"
else
    # Define policy statements with proper replacements
    POLICY_STATEMENTS='[
        "allow service compute_management to use tag-namespace in tenancy",
        "allow service compute_management to manage compute-management-family in tenancy",
        "allow service compute_management to read app-catalog-listing in tenancy",
        "allow group OCI-HPC-POC-Group to manage all-resources in compartment POC",
        "allow dynamic-group tc_instance_principal to read app-catalog-listing in tenancy",
        "allow dynamic-group tc_instance_principal to use tag-namespace in tenancy",
        "allow dynamic-group tc_instance_principal to manage compute-management-family in compartment POC",
        "allow dynamic-group tc_instance_principal to manage instance-family in compartment POC",
        "allow dynamic-group tc_instance_principal to use virtual-network-family in compartment POC",
        "allow dynamic-group tc_instance_principal to use volumes in compartment POC",
        "allow dynamic-group tc_instance_principal to manage dns in compartment POC",
        "allow dynamic-group tc_instance_principal to read metrics in compartment POC"
    ]'
    
    # Create the policy
    CREATE_POLICY_RESULT=$(oci iam policy create \
        --compartment-id "$TENANCY_OCID" \
        --name "OCI-HPC-Deployment-Policies" \
        --description "Policies for HPC deployment in POC compartment" \
        --statements "$POLICY_STATEMENTS")
    
    POLICY_OCID=$(echo "$CREATE_POLICY_RESULT" | jq -r '.data.id')
    
    if [ -z "$POLICY_OCID" ] || [ "$POLICY_OCID" = "null" ]; then
        print_error "Failed to create policy"
        exit 1
    fi
    
    print_status "Policy created successfully!"
    print_status "Policy OCID: $POLICY_OCID"
fi
echo

# Summary
print_status "=== Setup Complete! ==="
echo
print_status "Summary of created resources:"
print_status "• Compartment 'POC': $POC_OCID"
print_status "• User Group 'OCI-HPC-POC-Group': $GROUP_OCID"
print_status "• Current User '$CURRENT_USERNAME' added to group"
print_status "• Dynamic Group 'tc_instance_principal': References instances in POC compartment"
print_status "• Policy 'OCI-HPC-Deployment-Policies': Contains all required permissions"
echo
print_status "Your OCI environment is now ready for HPC deployment!"
print_status "You have full access to the POC compartment through the OCI-HPC-POC-Group!"