#!/bin/bash
# This script creates IAM users in the AI group for the new domain.
# It reads the USERS array, creates each user, and adds them to the specified group.
# Modify the Users array to include the desired users, their descriptions, and target groups.
# Usage: ./create_users_in_ai_group.sh
# Note that username and email address are the same.

set -euo pipefail

LOGFILE="create_users_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "========================================="
echo "Creating IAM Users - $(date)"
echo "========================================="

# Source variables
source ./variables.sh

# Get Domain OCID
echo "Fetching AI Domain OCID..."
AI_DOMAIN=$(oci iam domain list \
    --compartment-id "$TENANCY_OCID" \
    --query "data[?description=='Main Domain for AI Users'].id | [0]" \
    --raw-output)

if [[ -z "$AI_DOMAIN" || "$AI_DOMAIN" == "null" ]]; then
    echo "ERROR: AI Domain not found"
    exit 1
fi

echo "AI Domain OCID: $AI_DOMAIN"
echo ""

# Define users (format: "email|description|group")
USERS=(
    "alice.johnson@example.com|GPU Cluster Admin|AI-Administrators"
    "diana.prince@example.com|Research Lead|AI-Administrators"
    "eve.adams@example.com|DevOps Engineer|AI-Administrators"
)

SUCCESS_COUNT=0
FAIL_COUNT=0

for user_info in "${USERS[@]}"; do
    IFS='|' read -r email description group <<< "$user_info"
    
    echo "----------------------------------------"
    echo "Processing: $email"
    echo "  Description: $description"
    echo "  Target Group: $group"
    
    # Create user
    if USER_OCID=$(oci iam user create \
        --compartment-id "$TENANCY_OCID" \
        --name "$email" \
        --description "$description" \
        --email "$email" \
        --domain-id "$AI_DOMAIN" \
        --query 'data.id' \
        --raw-output 2>/dev/null); then
        
        echo "  ✓ User created: $USER_OCID"
        
        # Get group OCID
        GROUP_OCID=$(oci iam group list \
            --compartment-id "$TENANCY_OCID" \
            --domain-id "$AI_DOMAIN" \
            --query "data[?\"display-name\"==\`$group\`].id | [0]" \
            --raw-output 2>/dev/null || true)
        
        if [[ -n "$GROUP_OCID" && "$GROUP_OCID" != "null" ]]; then
            # Add user to group
            if oci iam group add-user \
                --user-id "$USER_OCID" \
                --group-id "$GROUP_OCID" \
                --domain-id "$AI_DOMAIN" >/dev/null 2>&1; then
                echo "  ✓ Added to group: $group ($GROUP_OCID)"
            else
                echo "  ⚠ Could not add to group (may already be member)"
            fi
        else
            echo "  ⚠ Group '$group' not found - user created but not added to group"
        fi
        
        ((SUCCESS_COUNT++))
    else
        echo "  ✗ Failed to create user (may already exist)"
        ((FAIL_COUNT++))
    fi
    
    echo ""
done

echo "========================================="
echo "Summary"
echo "========================================="
echo "Successfully created: $SUCCESS_COUNT users"
echo "Failed/Skipped: $FAIL_COUNT users"
echo "Completed at: $(date)"
echo "Log file: $LOGFILE"
echo "========================================="