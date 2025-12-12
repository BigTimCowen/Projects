#!/bin/bash
# v1.0.0
# OCI POC Setup Script with User Group Management
# Creates compartment
# Groups - OCI-HPC-POC-Group, 
# Dynamic group - fn_dg
#dynamic group - oci_hpc_instance_principal
# adds user from OCI Shell session running script
# Creates policies for HPC deployment
# Creates TAG_NAMESPACE for tagging unhealthy GPUs
# Run this script in the OCI Shell of an admin users of the tenancy

POC_COMPARTMENT_NAME="POC"
HPC_DYNAMIC_GROUP_NAME="oci_hpc_instance_principal"
HPC_FN_DYNAMIC_GROUP_NAME="fn_dg"
HPC_GROUP_NAME="OCI-HPC-POC-Group"
HPC_POLICY_NAME="OCI-HPC-Deployment-Policies"
TAG_NAMESPACE="ComputeInstanceHostActions"
TAG_NAMESPACE_DESCRIPTION="Compute Instance Actions Tag Namespace"
TAG_NAME="CustomerReportedHostStatus"
TAG_NAME_DESCRIPTION="host is unhealthy and needs manual intervention before returning to the previous pool post-recycle"
TAG_VALUE="unhealthy"

HOME_REGION_KEY=$(oci iam tenancy get --tenancy-id $OCI_TENANCY --query "data.\"home-region-key\"" --raw-output)
HOME_REGION=$(oci iam region list --query "data[?key=='$HOME_REGION_KEY'].name | [0]" --raw-output)

echo "Home region: $HOME_REGION"


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m' # No Color (reset)S

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
TENANCY_OCID=$OCI_TENANCY
TENANCY_NAME=$(oci iam compartment get --compartment-id "$OCI_TENANCY" --output json | jq -r '.data.description')
EXISTING_COMPARTMENT=$(oci iam compartment list --compartment-id "$TENANCY_OCID" --name "$POC_COMPARTMENT_NAME" --lifecycle-state "ACTIVE" 2>/dev/null | jq -r '.data[0].id // empty')

print_status "Tenancy Name: $TENANCY_NAME"
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


delete_resource_manager() {

    COMPARTMENT_ID=$EXISTING_COMPARTMENT
    SEARCH_TERM="Oracle Cloud HPC cluster"
    DRY_RUN=false

    # Get all compartments including root
    #oci iam compartment list --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --lifecycle-state ACTIVE --query 'data[*].{Name:name, OCID:id, State:"lifecycle-state", Description:description}' --output table

    while [ -z "$COMPARTMENT_ID" ]; do
        read -p "What is the Compartment OCID? " COMPARTMENT_ID
    done

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --search-term)
                SEARCH_TERM="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    echo -e "${CYAN}OCI Resource Manager Stack Deletion Script"
    echo "=============================================="
    echo "Compartment: $COMPARTMENT_ID"
    echo "Searching for Resource Manager Stacks that contain the Search term: $SEARCH_TERM"
    echo "Mode: $([ "$DRY_RUN" == true ] && echo "DRY RUN" || echo "DELETE")"
    echo -e "${NC}"

    # Step 1: Get all Resource Manager stacks
    echo "Getting all Resource Manager stacks in compartment..."
    ALL_STACKS=$(oci resource-manager stack list --compartment-id "$COMPARTMENT_ID" --all 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to get Resource Manager stacks"
        return 1
    fi

    # Step 2: Filter stacks by description containing search term
    echo "Filtering stacks with description containing '$SEARCH_TERM'..."
    FILTERED_STACKS=$(echo "$ALL_STACKS" | jq -r ".data[] | select(.description != null) | select(.description | contains(\"$SEARCH_TERM\")) | select(.\"lifecycle-state\" == \"ACTIVE\") | .id + \"|\" + .\"display-name\" + \"|\" + .\"lifecycle-state\" + \"|\" + .description")

    if [[ -z "$FILTERED_STACKS" ]]; then
        echo "No Resource Manager stacks found with description containing '$SEARCH_TERM'"
        return 0
    fi

    # Step 3: Display found stacks
    echo ""
    echo "Found Resource Manager stacks with description containing '$SEARCH_TERM':"
    echo "======================================================================"
    printf "%-40s %-15s %-15s %s\n" "DISPLAY NAME" "STATE" "OCID" "DESCRIPTION"
    echo "$(printf '%*s' 120 | tr ' ' '-')"

    echo "$FILTERED_STACKS" | while IFS='|' read -r ocid name state description; do
        printf "%-40s %-15s %-15s %s\n" "$name" "$state" "${ocid:0:15}..." "${description:0:50}..."
    done

    # Count stacks
    STACK_COUNT=$(echo "$FILTERED_STACKS" | wc -l)
    echo ""
    echo "Total stacks: $STACK_COUNT"

    # Step 4: Confirm deletion
    if [[ "$DRY_RUN" == false ]]; then
        echo ""
        echo "WARNING: This will permanently delete $STACK_COUNT Resource Manager stack(s)!"
        echo "Note: Any running jobs will be terminated and all associated resources may be affected."
        read -p "Type 'yes' to confirm deletion: " confirm
        
        if [[ "$confirm" != "yes" ]]; then
            echo "Deletion cancelled"
            return 0
        fi
        
        # Step 5: Delete stacks
        echo ""
        echo "Deleting Resource Manager stacks..."
        echo "$FILTERED_STACKS" | while IFS='|' read -r ocid name state description; do
            echo "Deleting: $name ($ocid)"
            
            # Check for running jobs first
            RUNNING_JOBS=$(oci resource-manager job list --stack-id "$ocid" --lifecycle-state IN_PROGRESS --query "length(data)" --raw-output 2>/dev/null)
            
            if [[ "$RUNNING_JOBS" -gt 0 ]]; then
                echo "  ⚠ Warning: Stack has $RUNNING_JOBS running job(s). Cancelling jobs first..."
                # Cancel running jobs
                oci resource-manager job list --stack-id "$ocid" --lifecycle-state IN_PROGRESS --query "data[*].id" --raw-output 2>/dev/null | while read -r job_id; do
                    if [[ -n "$job_id" ]]; then
                        echo "    Cancelling job: $job_id"
                        oci resource-manager job cancel --job-id "$job_id" --force 2>/dev/null
                    fi
                done
                echo "    Waiting for jobs to cancel..."
                sleep 10
            fi
            
            # Delete the stack
            oci resource-manager stack delete --stack-id "$ocid" --force 2>/dev/null
            DELETE_RESULT=$?
            
            if [[ $DELETE_RESULT -eq 0 ]]; then
                echo "  ✓ Deletion initiated successfully"
            else
                echo "  ✗ Deletion failed (exit code: $DELETE_RESULT)"
                # Try to get more specific error info
                echo "  Attempting to get stack details..."
                oci resource-manager stack get --stack-id "$ocid" --query "data.\"lifecycle-state\"" --raw-output 2>/dev/null || echo "  Stack may have dependencies or active resources"
            fi
            echo ""
        done
        
    else
        echo ""
        echo "This is a dry run and if actually ran would delete $STACK_COUNT Resource Manager stacks"
        
        # Show what would be deleted in dry run mode
        echo ""
        echo "Stacks that would be deleted:"
        echo "$FILTERED_STACKS" | while IFS='|' read -r ocid name state description; do
            echo "  - $name ($ocid)"
            echo "    Description: $description"
            echo "    State: $state"
            echo ""
        done
    fi
}

delete_images() {

                COMPARTMENT_ID=$EXISTING_COMPARTMENT
                SEARCH_TERM="OFED"
                DRY_RUN=false


                # Get all compartments including root
                #oci iam compartment list --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --lifecycle-state ACTIVE --query 'data[*].{Name:name, OCID:id, State:"lifecycle-state", Description:description}' --output table

                while [ -z $COMPARTMENT_ID ]; do
                        read -p "What is the Compartment OCID? " COMPARTMENT_ID
                done


                # Parse arguments
                while [[ $# -gt 0 ]]; do
                    case $1 in
                            --dry-run)
                            DRY_RUN=true
                            shift
                            ;;
                            --search-term)
                            SEARCH_TERM="$2"
                            shift 2
                            ;;
                            *)
                            shift
                            ;;
                    esac
                done

                echo -e "${CYAN}OCI Custom Image Deletion Script"
                echo "================================"
                echo "Compartment: $COMPARTMENT_ID"
                echo "Searching for Custom Images that contain the Search term: $SEARCH_TERM"
                echo "Mode: $([ "$DRY_RUN" == true ] && echo "DRY RUN" || echo "DELETE")"
                echo -e "${NC}"

                # Step 1: Get all images (avoiding JMESPath filtering)
                echo "Getting all images in compartment..."
                ALL_IMAGES=$(oci compute image list --all --compartment-id "$COMPARTMENT_ID" 2>/dev/null)

                if [[ $? -ne 0 ]]; then
                    echo "Error: Failed to get images"
                    return 1
                fi

                # Step 2: Filter using jq instead of JMESPath
                echo "Filtering images containing '$SEARCH_TERM'..."
                FILTERED_IMAGES=$(echo "$ALL_IMAGES" | jq -r ".data[] | select(.\"display-name\" | contains(\"$SEARCH_TERM\")) | select(.publisher != \"Oracle\" and .publisher != \"Canonical\") | .id + \"|\" + .\"display-name\" + \"|\" + .\"lifecycle-state\"")

                if [[ -z "$FILTERED_IMAGES" ]]; then
                    echo "No custom images found containing '$SEARCH_TERM'"
                    return 0
                fi

                # Step 3: Display found images
                echo ""
                echo "Found custom images containing '$SEARCH_TERM':"
                echo "=============================================="
                printf "%-50s %-15s %s\n" "DISPLAY NAME" "STATE" "OCID"
                echo "$(printf '%*s' 100 | tr ' ' '-')"

                echo "$FILTERED_IMAGES" | while IFS='|' read -r ocid name state; do
                printf "%-50s %-15s %s\n" "$name" "$state" "${ocid:0:40}..."
                done

                # Count images
                IMAGE_COUNT=$(echo "$FILTERED_IMAGES" | wc -l)
                echo ""
                echo "Total images: $IMAGE_COUNT"
                

                # Step 4: Confirm deletion
                if [[ "$DRY_RUN" == false ]]; then
                echo ""
                echo "WARNING: This will permanently delete $IMAGE_COUNT image(s)!"
                read -p "Type 'yes' to confirm deletion: " confirm
                
                if [[ "$confirm" != "yes" ]]; then
                        echo "Deletion cancelled"
                        exit 0
                fi
                
                # Step 5: Delete images
                echo ""
                echo "Deleting images..."
                echo "$FILTERED_IMAGES" | while IFS='|' read -r ocid name state; do
                        echo "Deleting: $name ($ocid)"
                        oci compute image delete --image-id "$ocid" --force
                        if [[ $? -eq 0 ]]; then
                        echo "  ✓ Deletion initiated successfully"
                        else
                        echo "  ✗ Deletion failed"
                        fi
                        echo ""
                done
                else
                echo ""
                if [[ "$DRY_RUN" ]]; then
                        echo "This is a dry run and if actually ran would delete $IMAGE_COUNT images"
                fi
                fi

}

create_tag_namespace() {
    # Step 5: Create tag_namespace
    print_status "Creating tag_namespace $TAG_NAMESPACE ..."

    # Check if namespace already exists
    EXISTING_NAMESPACE=$(oci iam tag-namespace list --compartment-id $OCI_TENANCY --query "data[?name=='$TAG_NAMESPACE'].id | [0]" --raw-output)

    if [ -n "$EXISTING_NAMESPACE" ]; then
        print_warning "Namespace "$TAG_NAMESPACE" already exists with OCID: $EXISTING_NAMESPACE"
    else
            ## This will create the ComputeInstanceHostActions namespace and corresponding tags for tagging GPUs

    print_status "Creating Tag Namespace $TAG_NAMESPACE" 
    oci iam tag-namespace create --compartment-id $OCI_TENANCY --name $TAG_NAMESPACE --description "$TAG_NAMESPACE_DESCRIPTION" --region $HOME_REGION
  
    sleep 10

    print_status "Searching for newly created Tag Namespace's ocid for $TAG_NAMESPACE"
    NAMESPACE_OCID=$(oci iam tag-namespace list --compartment-id $OCI_TENANCY --query "data[?name=='$TAG_NAMESPACE'].id | [0]" --raw-output)

    print_status "Creating Tag Value, $TAG_NAME for $TAG_VALUE"
    # Create a tag key with description
    oci iam tag create --tag-namespace-id $NAMESPACE_OCID --name $TAG_NAME --description "$TAG_NAME_DESCRIPTION" --validator '{"validator-type": "ENUM", "values": ["'"$TAG_VALUE"'"]}' --region $HOME_REGION
    
    print_status "$TAG_NAMESPACE - Tag Namespace created successfully!"
    print_status "$TAG_NAMESPACE - Tag Namespace OCID: $NAMESPACE_OCID"
    print_status "$TAG_NAME - Tag Name created successfully!"

    fi
}

delete_tag_namespace() {
    ## This will delete the corresponding ComputeInstanceHostActions namespace

    print_status "Searching for created TAG Namespace's ocid for $TAG_NAMESPACE"
    NAMESPACE_OCID=$(oci iam tag-namespace list --compartment-id $OCI_TENANCY --query "data[?name=='ComputeInstanceHostActions'].id | [0]" --raw-output)
  
    print_status "Retiring $TAG_NAMESPACE with $NAMESPACE_OCID"
    oci iam tag-namespace retire --tag-namespace-id $NAMESPACE_OCID --region $HOME_REGION
    
    print_status "Deleting $TAG_NAMESPACE with $NAMESPACE_OCID"
    oci iam tag-namespace cascade-delete --tag-namespace-id $NAMESPACE_OCID --region $HOME_REGION

    print_status "Delete Comlpete."

}

create_poc() {

set -e  # Exit on any error

echo "=== OCI POC Setup Script Starting ==="
echo



# Step 1: Create POC compartment
print_status "Creating $POC_COMPARTMENT_NAME compartment..."

# Check if compartment already exists
EXISTING_COMPARTMENT=$(oci iam compartment list --compartment-id "$TENANCY_OCID" --name "$POC_COMPARTMENT_NAME" --lifecycle-state "ACTIVE" 2>/dev/null | jq -r '.data[0].id // empty')

if [ -n "$EXISTING_COMPARTMENT" ]; then
    print_warning "Compartment '$POC_COMPARTMENT_NAME' already exists with OCID: $EXISTING_COMPARTMENT"
    POC_OCID="$EXISTING_COMPARTMENT"
else
    # Create the compartment
    CREATE_RESULT=$(oci iam compartment create \
        --compartment-id "$TENANCY_OCID" \
        --name "$POC_COMPARTMENT_NAME" \
        --description "Proof of Concept compartment for HPC deployment" \
        --wait-for-state "ACTIVE" \
        --region "$HOME_REGION" \
        --max-wait-seconds 300)
    
    POC_OCID=$(echo "$CREATE_RESULT" | jq -r '.data.id')
    
    if [ -z "$POC_OCID" ] || [ "$POC_OCID" = "null" ]; then
        print_error "Failed to create $POC_COMPARTMENT_NAME compartment"
        exit 1
    fi
    
    print_status "$POC_COMPARTMENT_NAME compartment created successfully!"
fi

print_status "$POC_COMPARTMENT_NAME Compartment OCID: $POC_OCID"
echo

# Step 2: Create user group
print_status "Creating user group $HPC_GROUP_NAME..."

# Check if group already exists
EXISTING_GROUP=$(oci iam group list --name "$HPC_GROUP_NAME" 2>/dev/null | jq -r '.data[0].id // empty')

if [ -n "$EXISTING_GROUP" ]; then
    print_warning "Group '$HPC_GROUP_NAME' already exists with OCID: $EXISTING_GROUP"
    GROUP_OCID="$EXISTING_GROUP"
else
    # Create the group
    CREATE_GROUP_RESULT=$(oci iam group create \
        --compartment-id "$TENANCY_OCID" \
        --name "$HPC_GROUP_NAME" \
        --region "$HOME_REGION" \
        --description "Group for users with access to POC HPC resources")
    
    GROUP_OCID=$(echo "$CREATE_GROUP_RESULT" | jq -r '.data.id')
    
    if [ -z "$GROUP_OCID" ] || [ "$GROUP_OCID" = "null" ]; then
        print_error "Failed to create user group"
        exit 1
    fi
    
    print_status "$HPC_GROUP_NAME group created successfully!"
fi

print_status "$HPC_GROUP_NAME OCID: $GROUP_OCID"
echo

# Step 3: Add current user to the group
print_status "Adding current user to $HPC_GROUP_NAME..."

# Check if user is already in the group
USER_IN_GROUP=$(oci iam group list-users --group-id "$GROUP_OCID" --query "data[?id=='$CURRENT_USER_OCID'].id | [0]" --raw-output 2>/dev/null)

if [ -n "$USER_IN_GROUP" ] && [ "$USER_IN_GROUP" != "null" ]; then
    print_warning "User $CURRENT_USERNAME is already in the group"
else
    # Add user to group
    oci iam group add-user \
        --group-id "$GROUP_OCID" \
        --user-id "$CURRENT_USER_OCID" \
        --region "$HOME_REGION" >/dev/null
    
    print_status "User $CURRENT_USERNAME added to $HPC_GROUP_NAME successfully!"
fi
echo

# Step 4: Create hpc dynamic group
print_status "Creating dynamic group $HPC_DYNAMIC_GROUP_NAME..."

# Check if dynamic group already exists
EXISTING_DG=$(oci iam dynamic-group list --name "$HPC_DYNAMIC_GROUP_NAME" 2>/dev/null | jq -r '.data[0].id // empty')

if [ -n "$EXISTING_DG" ]; then
    print_warning "Dynamic group $HPC_DYNAMIC_GROUP_NAME already exists with OCID: $EXISTING_DG"
else
    # Create the dynamic group
    MATCHING_RULE="ALL {resource.type = 'fnfunc', resource.compartment.id = '$POC_OCID'}"
    
    CREATE_DG_RESULT=$(oci iam dynamic-group create \
        --compartment-id "$TENANCY_OCID" \
        --name "$HPC_DYNAMIC_GROUP_NAME" \
        --description "Dynamic group for instances in POC compartment" \
        --matching-rule "$MATCHING_RULE" \
        --region "$HOME_REGION")
    
    DG_OCID=$(echo "$CREATE_DG_RESULT" | jq -r '.data.id')
    
    if [ -z "$DG_OCID" ] || [ "$DG_OCID" = "null" ]; then
        print_error "Failed to create dynamic group"
        exit 1
    fi
    
    print_status "$HPC_DYNAMIC_GROUP_NAME dynamic group created successfully!"
    print_status "$HPC_DYNAMIC_GROUP_NAME dynamic group OCID: $DG_OCID"
fi
echo

# Step 5: Create fn dynamic group
print_status "Creating dynamic group $HPC_FN_DYNAMIC_GROUP_NAME..."

# Check if dynamic group already exists
EXISTING_DG=$(oci iam dynamic-group list --name "$HPC_FN_DYNAMIC_GROUP_NAME" 2>/dev/null | jq -r '.data[0].id // empty')

if [ -n "$EXISTING_DG" ]; then
    print_warning "Dynamic group $HPC_FN_DYNAMIC_GROUP_NAME already exists with OCID: $EXISTING_DG"
else
    # Create the dynamic group
    MATCHING_RULE="ALL {instance.compartment.id = '$POC_OCID'}"
    
    CREATE_DG_RESULT1=$(oci iam dynamic-group create \
        --compartment-id "$TENANCY_OCID" \
        --name "$HPC_FN_DYNAMIC_GROUP_NAME" \
        --description "Dynamic group for instances in POC compartment" \
        --matching-rule "$MATCHING_RULE" \
        --region "$HOME_REGION")
    
    DG_OCID1=$(echo "$CREATE_DG_RESULT1" | jq -r '.data.id')
    
    if [ -z "$DG_OCID1" ] || [ "$DG_OCID1" = "null" ]; then
        print_error "Failed to create dynamic group"
        exit 1
    fi
    
    print_status "$HPC_FN_DYNAMIC_GROUP_NAME dynamic group created successfully!"
    print_status "$HPC_FN_DYNAMIC_GROUP_NAME dynamic group OCID: $DG_OCID1"
fi
echo

# Step 5: Create policy
print_status "Creating policy $HPC_POLICY_NAME ..."

# Check if policy already exists
EXISTING_POLICY=$(oci iam policy list --compartment-id "$TENANCY_OCID" --name "$HPC_POLICY_NAME" 2>/dev/null | jq -r '.data[0].id // empty')

if [ -n "$EXISTING_POLICY" ]; then
    print_warning "Policy "$HPC_POLICY_NAME" already exists with OCID: $EXISTING_POLICY"
else
    # Define policy statements with proper replacements
    POLICY_STATEMENTS='[
        "Allow dynamic-group '$HPC_FN_DYNAMIC_GROUP_NAME' to manage all-resources in compartment '$POC_COMPARTMENT_NAME'",
        "allow service compute_management to use tag-namespace in tenancy",
        "allow service compute_management to manage compute-management-family in tenancy",
        "allow service compute_management to read app-catalog-listing in tenancy",
        "allow group '$HPC_GROUP_NAME' to manage all-resources in compartment '$POC_COMPARTMENT_NAME'",
        "Allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to use queue-push in compartment '$POC_COMPARTMENT_NAME'",
        "Allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to use queue-pull in compartment '$POC_COMPARTMENT_NAME'",
        "allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to manage queues in compartment '$POC_COMPARTMENT_NAME'",
        "allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to read app-catalog-listing in tenancy",
        "allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to use tag-namespace in tenancy",
        "allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to manage compute-management-family in compartment '$POC_COMPARTMENT_NAME'",
        "allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to manage instance-family in compartment '$POC_COMPARTMENT_NAME'",
        "allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to use virtual-network-family in compartment '$POC_COMPARTMENT_NAME'",
        "allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to use volumes in compartment '$POC_COMPARTMENT_NAME'",
        "allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to manage dns in compartment '$POC_COMPARTMENT_NAME'",
        "Allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to manage compute-bare-metal-hosts in tenancy",
        "allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to read metrics in compartment '$POC_COMPARTMENT_NAME'",
        "Allow group '$HPC_GROUP_NAME' to use compute-hpc-islands in tenancy",
        "Allow group '$HPC_GROUP_NAME' to use compute-network-blocks in tenancy",
        "Allow group '$HPC_GROUP_NAME' to use compute-local-blocks in tenancy",
        "Allow group '$HPC_GROUP_NAME' to use compute-bare-metal-hosts in tenancy",
        "Allow group '$HPC_GROUP_NAME' to use compute-gpu-memory-fabrics in tenancy",
        "Allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to use ons-family in compartment '$POC_COMPARTMENT_NAME'",
        "Allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to use stream-family in compartment '$POC_COMPARTMENT_NAME'",
        "Allow dynamic-group '$HPC_DYNAMIC_GROUP_NAME' to read all-resources in compartment '$POC_COMPARTMENT_NAME'",
        "Allow group '$HPC_GROUP_NAME' to read metrics in tenancy where all {request.principal.type = 'serviceconnector', request.principal.compartment.id = '$POC_OCID'}
        "Allow group '$HPC_GROUP_NAME' to use stream-push in compartment id '$POC_OCID' where all {request.principal.type='serviceconnector', request.principal.compartment.id='$POC_OCID'}
    ]'
    
    # Create the policy
    CREATE_POLICY_RESULT=$(oci iam policy create \
        --compartment-id "$TENANCY_OCID" \
        --name "$HPC_POLICY_NAME" \
        --description "Policies for HPC deployment in POC compartment" \
        --statements "$POLICY_STATEMENTS" \
        --region "$HOME_REGION")
    
    POLICY_OCID=$(echo "$CREATE_POLICY_RESULT" | jq -r '.data.id')
    
    if [ -z "$POLICY_OCID" ] || [ "$POLICY_OCID" = "null" ]; then
        print_error "Failed to create policy, $HPC_POLICY_NAME"
        exit 1
    fi
    
    print_status "$HPC_POLICY_NAME - Policy created successfully!"
    print_status "$HPC_POLICY_NAME - Policy OCID: $POLICY_OCID"
fi
echo

create_tag_namespace


# Summary
print_status "=== Setup Complete! ==="
echo
print_status "Summary of created resources:"
print_status "• Compartment $POC_COMPARTMENT_NAME: $POC_OCID"
print_status "• User Group $HPC_GROUP_NAME : $GROUP_OCID"
print_status "• Current User '$CURRENT_USERNAME' added to group"
print_status "• Dynamic Group $HPC_FN_DYNAMIC_GROUP_NAME : References instances in $POC_COMPARTMENT_NAME compartment"
print_status "• Dynamic Group $HPC_DYNAMIC_GROUP_NAME : References instances in $POC_COMPARTMENT_NAME compartment"
print_status "• Policy $HPC_POLICY_NAME : Contains all required permissions"
print_status "• Tag Namespace $TAG_NAMESPACE, $TAG_NAME with value $TAG_VALUE created in root compartment"
echo
print_status "Your OCI environment is now ready for HPC deployment and for you to upload the HPC Images!"
print_status "You have full access to the $POC_COMPARTMENT_NAME compartment through the $HPC_GROUP_NAME!"

}

delete_bv_backups() {
    COMPARTMENT_ID=$EXISTING_COMPARTMENT
    DRY_RUN=false

    # Get all compartments including root
    ##oci iam compartment list --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --lifecycle-state ACTIVE --query 'data[*].{Name:name, OCID:id, State:"lifecycle-state", Description:description}' --output table

    while [ -z "$COMPARTMENT_ID" ]; do
        read -p "What is the Compartment OCID? " COMPARTMENT_ID
    done

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    echo -e "${CYAN}Simple OCI Boot Volume Backup Script"
    echo "================================"
    echo "Compartment: $COMPARTMENT_ID"
    echo "Mode: $([ "$DRY_RUN" == true ] && echo "DRY RUN" || echo "DELETE")"
    echo -e "${NC}"

    # Step 1: Get all boot volume backups
    echo "Getting all boot volume backups in compartment..."
    
    # Get backup IDs for processing - only AVAILABLE backups
    BACKUP_IDS_RAW=$(oci bv boot-volume-backup list --compartment-id "$COMPARTMENT_ID" --lifecycle-state AVAILABLE --query "data[*].id" --raw-output 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to get boot volume backups"
        return 1
    fi

    # Convert JSON array to newline-separated list
    BACKUP_IDS=$(echo "$BACKUP_IDS_RAW" | jq -r '.[]' 2>/dev/null)
    
    # If jq fails, try parsing the raw output directly
    if [[ $? -ne 0 || -z "$BACKUP_IDS" ]]; then
        # Fallback: try to extract OCIDs directly from raw output
        BACKUP_IDS=$(echo "$BACKUP_IDS_RAW" | grep -o 'ocid1\.bootvolumebackup\.[^"]*' 2>/dev/null)
    fi

    # Count backups
    BV_BACKUP_COUNT=$(echo "$BACKUP_IDS" | grep -c "ocid1.bootvolumebackup" 2>/dev/null)
    echo ""
    echo "Total AVAILABLE boot volume backups to process: $BV_BACKUP_COUNT"

    if [[ $BV_BACKUP_COUNT -eq 0 ]]; then
        echo "No backups found to delete."
        return 0
    fi

    # Step 4: Confirm deletion
    if [[ "$DRY_RUN" == "false" ]]; then
        echo ""
        echo "WARNING: This will permanently delete $BV_BACKUP_COUNT boot volume backup(s)!"
        read -p "Type 'yes' to confirm deletion: " confirm
        
        if [[ "$confirm" != "yes" ]]; then
            echo "Deletion cancelled"
            return 0
        fi
        
        # Step 5: Delete boot volume backups
        echo ""
        echo "Deleting boot volume backups..."
        
        # Debug: Show what we're processing
        echo "Debug: Processing backup IDs:"
        echo "$BACKUP_IDS" | head -3
        echo ""
        
        while IFS= read -r backup_id; do
            # Skip empty lines
            if [[ -z "$backup_id" ]]; then
                continue
            fi
            
            # Clean up any extra whitespace or quotes
            backup_id=$(echo "$backup_id" | tr -d '"' | xargs)
            
            if [[ "$backup_id" =~ ^ocid1\.bootvolumebackup\. ]]; then
                # Double-check the backup state before deletion
                BACKUP_STATE=$(oci bv boot-volume-backup get --boot-volume-backup-id "$backup_id" --query "data.\"lifecycle-state\"" --raw-output 2>/dev/null)
                BACKUP_NAME=$(oci bv boot-volume-backup get --boot-volume-backup-id "$backup_id" --query "data.\"display-name\"" --raw-output 2>/dev/null)
                
                if [[ "$BACKUP_STATE" != "AVAILABLE" ]]; then
                    echo "Skipping: ${BACKUP_NAME:-Unknown} ($backup_id) - State: $BACKUP_STATE"
                    continue
                fi
                
                echo "Deleting: ${BACKUP_NAME:-Unknown} ($backup_id) - State: $BACKUP_STATE"
                
                # Delete with --force flag and wait for termination
                oci bv boot-volume-backup delete --boot-volume-backup-id "$backup_id" --force --wait-for-state TERMINATED 2>/dev/null
                DELETE_RESULT=$?
                
                if [[ $DELETE_RESULT -eq 0 ]]; then
                    echo "  ✓ Deletion completed successfully"
                else
                    echo "  ✗ Deletion failed (exit code: $DELETE_RESULT)"
                    # Try to get more specific error info
                    echo "  Attempting deletion without wait state..."
                    oci bv boot-volume-backup delete --boot-volume-backup-id "$backup_id" --force 2>&1 | head -1
                fi
                echo ""
            else
                echo "Skipping invalid backup ID: '$backup_id'"
            fi
        done <<< "$BACKUP_IDS"
        
    else
        echo ""
        echo "This is a dry run and if actually ran would delete $BV_BACKUP_COUNT AVAILABLE boot volume backups"
        
        # Show what would be deleted in dry run mode
        echo ""
        echo "AVAILABLE backups that would be deleted:"
        while IFS= read -r backup_id; do
            # Skip empty lines
            if [[ -z "$backup_id" ]]; then
                continue
            fi
            
            # Clean up any extra whitespace or quotes
            backup_id=$(echo "$backup_id" | tr -d '"' | xargs)
            
            if [[ "$backup_id" =~ ^ocid1\.bootvolumebackup\. ]]; then
                BACKUP_STATE=$(oci bv boot-volume-backup get --boot-volume-backup-id "$backup_id" --query "data.\"lifecycle-state\"" --raw-output 2>/dev/null)
                BACKUP_NAME=$(oci bv boot-volume-backup get --boot-volume-backup-id "$backup_id" --query "data.\"display-name\"" --raw-output 2>/dev/null)
                echo "  - ${BACKUP_NAME:-Unknown} ($backup_id) - State: $BACKUP_STATE"
            fi
        done <<< "$BACKUP_IDS"
    fi
}

delete_poc() {


    EXISTING_COMPARTMENT=$(oci iam compartment list --compartment-id "$TENANCY_OCID" --name "$POC_COMPARTMENT_NAME" --lifecycle-state "ACTIVE" 2>/dev/null | jq -r '.data[0].id // empty')
    EXISTING_GROUP=$(oci iam group list --name "$HPC_GROUP_NAME" 2>/dev/null | jq -r '.data[0].id // empty')
    EXISTING_POLICY=$(oci iam policy list --compartment-id "$TENANCY_OCID" --name "$HPC_POLICY_NAME" 2>/dev/null | jq -r '.data[0].id // empty')
    EXISTING_DG=$(oci iam dynamic-group list --name "$HPC_DYNAMIC_GROUP_NAME" 2>/dev/null | jq -r '.data[0].id // empty')
    EXISTING_NAMESPACE=$(oci iam tag-namespace list --compartment-id $OCI_TENANCY --query "data[?name=='$TAG_NAMESPACE'].id | [0]" --raw-output)

    echo
    print_status "• Tenancy Name: $TENANCY_NAME"
    echo -e  "${YELLOW}Summary of created resources targeted to be deleted:${NC}"
    print_status "• Compartment Name: $POC_COMPARTMENT_NAME, ocid: $EXISTING_COMPARTMENT"
    print_status "• User Group Name: $HPC_GROUP_NAME, ocid: $EXISTING_GROUP"
    print_status "• Policy Name: $HPC_POLICY_NAME, ocid: $EXISTING_POLICY"
    print_status "• Dynamic Group Name: $HPC_DYNAMIC_GROUP_NAME, ocid: $EXISTING_DG"
    print_status "• Tag Namespace: $TAG_NAMESPACE, ocid: $EXISTING_NAMESPACE"
    delete_resource_manager --dry-run
    delete_bv_backups --dry-run
    delete_images --dry-run

        echo -e "${RED}Please confirm you want to delete the POC environment in this tenancy. (You must type 'yes')${NC}"
        read dele

        if [ $dele == "yes" ]; then
            


            if [ -n "$EXISTING_GROUP" ]; then
            print_status "Deleting User Group Name: $HPC_GROUP_NAME, ocid $EXISTING_GROUP"
            oci iam group delete --group-id "$EXISTING_GROUP" --region "$HOME_REGION"
            fi

            if [ -n "$EXISTING_POLICY" ]; then
            print_status "Deleting Policy Name: $HPC_POLICY_NAME, ocid $EXISTING_POLICY"
            oci iam policy delete  --policy-id "$EXISTING_POLICY" --region "$HOME_REGION"
            fi

            if [ -n "$EXISTING_DG" ]; then
            print_status "Deleting Dynamic Group Name: $HPC_DYNAMIC_GROUP_NAME, ocid $EXISTING_DG"    
            oci iam dynamic-group delete --dynamic-group-id "$EXISTING_DG" --region "$HOME_REGION"
            fi

            echo -e ""
            delete_resource_manager

            echo -e ""
            delete_bv_backups

            echo -e ""
            delete_images

            echo -e ""
            delete_tag_namespace

            if [ -n "$EXISTING_COMPARTMENT" ]; then 
            print_status "Deleting Compartment Name: $POC_COMPARTMENT_NAME, ocid $EXISTING_COMPARTMENT"
            oci iam compartment delete --compartment-id "$EXISTING_COMPARTMENT" --region $HOME_REGION
            fi

            echo -e "${GREEN}Clean up of environment complete, exiting.${NC}"
        fi
}

main() {
    echo -e "${CYAN}What would you like to do,
                        ${YELLOW}1. Create POC Environment?
                        2. Clean up tenancy for POC Environment?${NC}"

    read action

    if [ $action -eq 1 ]; then
        create_poc
    elif [ $action -eq 2 ]; then

            delete_poc
    fi


}

main "$@"