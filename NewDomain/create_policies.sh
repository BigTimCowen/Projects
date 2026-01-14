#!/bin/bash
set -euo pipefail

LOGFILE="create_gpu_policies_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "========================================="
echo "Creating GPU Group Policies - $(date)"
echo "========================================="

source ./variables.sh

set -x
# Get necessary OCIDs
DEFAULT_DOMAIN=$(oci iam domain list --compartment-id $TENANCY_OCID --query "data[?\"display-name\"=='Default'].id | [0]" --raw-output)
AI_DOMAIN_OCID=$(oci iam domain list --compartment-id $TENANCY_OCID --query "data[?\"description\"==\`$DOMAIN_DESCRIPTION\`].id | [0]" --raw-output)
AI_DOMAIN_ENDPOINT=""
AI_DOMAIN_ENDPOINT=$(oci iam domain list --compartment-id $TENANCY_OCID --query 'data[?"description"==\`$DOMAIN_DESCRIPTION\`].url | [0]' --raw-output)
AI_DOMAIN_NAME=$(oci iam domain list --compartment-id $TENANCY_OCID --query "data[?"description"==\`$DOMAIN_DESCRIPTION\`].[\"display-name\"] | [0] | [0]" --raw-output)
AI_GROUP_OCID=$(oci identity-domains groups list --endpoint $AI_DOMAIN_ENDPOINT  --query 'data.resources[?"display-name"==`'"$AI_GROUP_NAME"'`].id | [0]' --raw-output)
set +x

# Function to create policy
create_policy() {
    local policy_name="$1"
    local policy_desc="$2"
    local compartment="$3"
    shift 3
    local statements=("$@")
    
    echo "Creating: $policy_name"
    
    # Build JSON array of statements
    local json_statements="["
    for stmt in "${statements[@]}"; do
        json_statements+="\"$stmt\","
    done
    json_statements="${json_statements%,}]"  # Remove trailing comma and close array
    
    if oci iam policy create \
        --compartment-id "$compartment" \
        --name "$policy_name" \
        --description "$policy_desc" \
        --statements "$json_statements" \
        --query 'data.id' \
        --raw-output >/dev/null 2>&1; then
        echo "  ✓ Created successfully"
        return 0
    else
        echo "  ✗ Failed (may already exist)"
        return 1
    fi
}

# GPU Admins Policies
echo "========================================="
echo "GPU Admins Policies"
echo "========================================="

create_policy \
    "gpu-admins-announcements-subscriptions" \
    "Policy for Announcement and Subscription Management" \
    "$COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage cluster-family in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage cluster-node-pools in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage instance-family in compartment id $COMPARTMENT_OCID where request.operation='LaunchInstance'" \
    "Allow group id $GPU_ADMINS_OCID to inspect instance-family in compartment id $COMPARTMENT_OCID"

create_policy \
    "gpu-admins-compute-clusters" \
    "Compute cluster management for GPU admins" \
    "$COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage compute-clusters in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage compute-capacity-reservations in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage compute-capacity-reports in compartment id $COMPARTMENT_OCID"

create_policy \
    "gpu-admins-networking" \
    "Network management for GPU admins" \
    "$COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage virtual-network-family in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage load-balancers in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage network-security-groups in compartment id $COMPARTMENT_OCID"

create_policy \
    "gpu-admins-storage" \
    "Storage management for GPU admins" \
    "$COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage volume-family in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage file-family in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage object-family in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage buckets in compartment id $COMPARTMENT_OCID"

create_policy \
    "gpu-admins-container-registry" \
    "Container registry management" \
    "$COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage repos in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to read repos in tenancy" \
    "Allow group id $GPU_ADMINS_OCID to manage container-images in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to read container-image-signatures in compartment id $COMPARTMENT_OCID"

create_policy \
    "gpu-admins-monitoring" \
    "Monitoring and logging access" \
    "$COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to read metrics in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to manage alarms in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to read log-groups in compartment id $COMPARTMENT_OCID" \
    "Allow group id $GPU_ADMINS_OCID to read log-content in compartment id $COMPARTMENT_OCID"


echo ""
echo "========================================="
echo "Policy Creation Complete"
echo "========================================="
echo "Log file: $LOGFILE"



      
      "name": "Announcement-Subscription-Policy",
      "description": "Policy allowing administrators to see announcements and subscribe to topics",
      "statements": [
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage ons-topics in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage ons-subscriptions in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage announcements in tenancy"
      ],
      
      
      "name": "Cost-Management-Policies",
      "description": "Policy for cost management in tenancy",
      "statements": [
        "Allow group  'zoom-oci-training-domain'/'zoom-ai-admin'  to manage usage-report in tenancy"
      ],
    
      "name": "Domain-policies",
      description": "Policy for domain management in tenancy",
      "statements": [
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage domains in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to inspect policies in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage policies in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage dynamic-groups in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage limits in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to read groups in tenancy"
      ],
    
      "name": "HPC-Dynamic-group-policies",
      description": "Policy for HPC Dynamic group to manage compute resources in tenancy",
      "statements": [
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use compute-hpc-islands in tenancy",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use compute-network-blocks in tenancy",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use compute-local-blocks in tenancy",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use compute-bare-metal-hosts in tenancy",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use compute-gpu-memory-fabrics in tenancy",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to read app-catalog-listing in tenancy",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use tag-namespace in tenancy",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to manage all-resources in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to manage dns in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to manage cluster-node-pools in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to manage cluster-family in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to manage file-family in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to manage compute-management-family in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to manage instance-family in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to manage volume-family in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use ons-topics in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use subnets in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use virtual-network-family in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use vnics in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use network-security-groups in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to inspect compartments in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to {CLUSTER_JOIN} in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to read metrics in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use metrics in compartment 'GPU-AI' where target.metrics.namespace='gpu_infrastructure_health'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to use metrics in compartment 'GPU-AI' where target.metrics.namespace='rdma_infrastructure_health'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to read repos in compartment 'GPU-AI'",
        "Allow dynamic-group 'zoom-oci-training-domain'/'oci-hpc-dg' to manage repos in compartment 'GPU-AI'"
      ]
    
    
      "name": "HPC-Stack",
      description": "Policy for HPC Stack to manage compute resources in tenancy",
      "statements": [
        "allow service compute_management to use tag-namespace in tenancy",
        "allow service compute_management to manage compute-management-family in tenancy",
        "allow service compute_management to read app-catalog-listing in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to use cloud-shell in tenancy",
        "allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage compute-capacity-topology in tenancy",
        "allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to inspect compute-hpc-island in tenancy",
        "allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to inspect compute-network-block in tenancy",
        "allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to inspect compute-local-block in tenancy",
        "allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to inspect compute-bare-metal-host in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage compute-hpc-islands in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage compute-network-blocks in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage compute-local-blocks in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage compute-bare-metal-hosts in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage compute-gpu-memory-fabrics in tenancy",
        "Allow group  'zoom-oci-training-domain'/'zoom-ai-admin' to manage compute-clusters in tenancy",
        "allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage all-resources in compartment 'GPU-AI'",
        "allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage dns in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage orm-family in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to read orm-family in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage orm-stacks in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage orm-jobs in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage orm-config-source-providers in tenancy",
        "Allow any-user to manage all-resources in compartment 'GPU-AI' where all { request.principal.type = 'workload', request.principal.service_account = 'oke-azknnz-svcacct', request.principal.cluster_id = 'ocid1.cluster.oc1.us-dallas-1.aaaaaaaal24b4lbiwew3ardtkx2kevs7oqgl274puxkvwz6q7ccsigmdj6mq' }",
        "Allow any-user to manage all-resources in compartment 'GPU-AI' where all { request.principal.type = 'workload', request.principal.service_account = 'cluster-autoscaler', request.principal.cluster_id = 'ocid1.cluster.oc1.us-dallas-1.aaaaaaaal24b4lbiwew3ardtkx2kevs7oqgl274puxkvwz6q7ccsigmdj6mq' }",
        "Allow any-user to manage file-family in compartment 'GPU-AI' where request.principal.type = 'cluster'",
        "Allow any-user to use virtual-network-family in compartment 'GPU-AI' where request.principal.type = 'cluster'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage tag-namespaces in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage tag-defaults in tenancy",
        "Allow group  'zoom-oci-training-domain'/'zoom-ai-admin' to manage buckets in compartment 'GPU-AI'",
        "Allow group  'zoom-oci-training-domain'/'zoom-ai-admin' to manage objects in compartment 'GPU-AI'",
        "Allow group  'zoom-oci-training-domain'/'zoom-ai-admin' to read repos in compartment 'GPU-AI'",
        "Allow group  'zoom-oci-training-domain'/'zoom-ai-admin' to manage repos in compartment 'GPU-AI'"
      ]
      
    
      "name": "Network",
      description": "Policy for network management in tenancy",
      "statements": [
        "Allow group 'Default'/'Network' to manage virtual-network-family in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-network-admin' to manage virtual-network-family in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-network-admin' to inspect compartments in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-network-admin' to use cloud-shell in tenancy"
      ]
      
      
      "name": "OKE-Stack-Policy",
      "description": "OKE Stack Policies to create stack and manage AI Infrastructure",
      "statements": [
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage instance-family in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to use subnets in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage virtual-network-family in compartment  'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to inspect compartments in tenancy",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to use vnics in compartment  'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to use network-security-groups  in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to use private-ips  in compartment  'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage public-ips  in compartment  'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage volume-family in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage cluster-family in compartment  'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage vcns in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage subnets in compartment  'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage internet-gateways in  compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage nat-gateways in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage route-tables in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage security-lists in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to inspect clusters in compartment  'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to use cluster-node-pools in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to read cluster-work-requests in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage service-gateways in compartment  'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to use cloud-shell in  compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to read vaults in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to read keys in compartment 'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to use compute-capacity-reservations in compartment  'GPU-AI'",
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to read metrics in compartment 'GPU-AI'"
      ]
    

      "name": "Support-Policy",
      "description": "Policy for allowing people to log service requests",
      "statements": [
        "Allow group 'zoom-oci-training-domain'/'zoom-ai-admin' to manage tickets in tenancy"
      