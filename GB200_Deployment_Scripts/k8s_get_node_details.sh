#!/bin/bash

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Source variables from variables.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/variables.sh" ]]; then
    source "$SCRIPT_DIR/variables.sh"
elif [[ -f "./variables.sh" ]]; then
    source "./variables.sh"
else
    echo -e "${YELLOW}Warning: variables.sh not found. Please ensure COMPARTMENT_ID, REGION, and TENANCY_ID are set.${NC}"
fi

# Cache directory
CACHE_DIR="${SCRIPT_DIR}/cache"
mkdir -p "$CACHE_DIR"

FABRIC_CACHE="$CACHE_DIR/gpu_fabrics.txt"
CLUSTER_CACHE="$CACHE_DIR/gpu_clusters.txt"
NODE_STATE_CACHE="$CACHE_DIR/node_states.txt"
ANNOUNCEMENTS_LIST_CACHE="$CACHE_DIR/announcements_list.json"
ANNOUNCEMENTS_CACHE_MAX_AGE=3600  # 1 hour

# Declare global associative arrays for announcement lookups
declare -gA INSTANCE_ANNOUNCEMENTS
declare -gA GPU_MEM_CLUSTER_ANNOUNCEMENTS

# Function to build announcement lookup from cached data
build_announcement_lookup() {
    local compartment_id="$1"
    
    # Reset arrays
    INSTANCE_ANNOUNCEMENTS=()
    GPU_MEM_CLUSTER_ANNOUNCEMENTS=()
    
    # Check if cache exists and is fresh enough
    local need_refresh=false
    if [[ ! -f "$ANNOUNCEMENTS_LIST_CACHE" ]]; then
        need_refresh=true
    else
        local cache_age=$(($(date +%s) - $(stat -c %Y "$ANNOUNCEMENTS_LIST_CACHE" 2>/dev/null || echo 0)))
        if [[ $cache_age -gt $ANNOUNCEMENTS_CACHE_MAX_AGE ]]; then
            need_refresh=true
        fi
    fi
    
    if [[ "$need_refresh" == "true" ]]; then
        oci announce announcements list \
            --compartment-id "$compartment_id" \
            --all > "$ANNOUNCEMENTS_LIST_CACHE" 2>/dev/null || return 1
        
        # Fetch details for each announcement
        local announcement_ids=$(jq -r '.data.items[].id' "$ANNOUNCEMENTS_LIST_CACHE" 2>/dev/null)
        for ann_id in $announcement_ids; do
            local detail_file="$CACHE_DIR/${ann_id##*.}.json"
            if [[ ! -f "$detail_file" || ! -s "$detail_file" ]]; then
                oci announce announcements get --announcement-id "$ann_id" > "$detail_file" 2>/dev/null &
            fi
        done
        wait
    fi
    
    # Process cached announcement details
    for detail_file in "$CACHE_DIR"/*.json; do
        [[ ! -f "$detail_file" ]] && continue
        [[ "$detail_file" == *"/announcements_list.json" ]] && continue
        [[ "$detail_file" == *"/ack_status_cache.json" ]] && continue
        
        # Validate file has announcement data
        if ! jq -e '.data.id' "$detail_file" > /dev/null 2>&1; then
            continue
        fi
        
        local lifecycle_state=$(jq -r '.data."lifecycle-state" // "N/A"' "$detail_file")
        [[ "$lifecycle_state" != "ACTIVE" ]] && continue
        
        local reference_ticket=$(jq -r '.data."reference-ticket-number" // "N/A"' "$detail_file")
        local short_ticket="${reference_ticket:0:8}"
        
        # Extract affected resources
        local resource_count=$(jq '.data."affected-resources" | length' "$detail_file" 2>/dev/null || echo 0)
        
        for ((i=0; i<resource_count; i++)); do
            # Get instance/resource ID
            local resource_id=$(jq -r ".data.\"affected-resources\"[$i] | 
                if .properties then
                    (.properties[] | select(.name == \"resourceId\" or .name == \"instanceId\") | .value) // null
                else
                    (.\"resource-id\" // .\"instance-id\" // null)
                end" "$detail_file" 2>/dev/null)
            
            # Get GPU memory cluster
            local gpu_mem_cluster=$(jq -r ".data.\"affected-resources\"[$i] |
                if .properties then
                    (.properties[] | select(.name == \"gpuMemoryCluster\") | .value) // null
                else
                    null
                end" "$detail_file" 2>/dev/null)
            
            # Add to instance lookup
            if [[ -n "$resource_id" && "$resource_id" != "null" ]]; then
                if [[ -z "${INSTANCE_ANNOUNCEMENTS[$resource_id]}" ]]; then
                    INSTANCE_ANNOUNCEMENTS[$resource_id]="$short_ticket"
                elif [[ ! "${INSTANCE_ANNOUNCEMENTS[$resource_id]}" =~ "$short_ticket" ]]; then
                    INSTANCE_ANNOUNCEMENTS[$resource_id]="${INSTANCE_ANNOUNCEMENTS[$resource_id]},$short_ticket"
                fi
            fi
            
            # Add to GPU memory cluster lookup
            if [[ -n "$gpu_mem_cluster" && "$gpu_mem_cluster" != "null" ]]; then
                if [[ -z "${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]}" ]]; then
                    GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]="$short_ticket"
                elif [[ ! "${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]}" =~ "$short_ticket" ]]; then
                    GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]="${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]},$short_ticket"
                fi
            fi
        done
    done
}

# Function to get announcements for a resource
get_resource_announcements() {
    local instance_ocid="$1"
    local gpu_mem_cluster="$2"
    local result=""
    
    # Check instance-level
    if [[ -n "$instance_ocid" && -n "${INSTANCE_ANNOUNCEMENTS[$instance_ocid]}" ]]; then
        result="${INSTANCE_ANNOUNCEMENTS[$instance_ocid]}"
    fi
    
    # Check GPU memory cluster level
    if [[ -n "$gpu_mem_cluster" && "$gpu_mem_cluster" != "N/A" && -n "${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]}" ]]; then
        if [[ -z "$result" ]]; then
            result="${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]}"
        else
            for ticket in ${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]//,/ }; do
                [[ ! "$result" =~ "$ticket" ]] && result="${result},${ticket}"
            done
        fi
    fi
    
    echo "${result:--}"
}

CAPACITY_TOPOLOGY_CACHE="$CACHE_DIR/capacity_topology_hosts.txt"

# Function to fetch and cache capacity topology bare metal hosts
fetch_capacity_topology() {
    if [[ -z "$TENANCY_ID" ]]; then
        echo -e "${YELLOW}Warning: TENANCY_ID not set. Capacity topology details will not be available.${NC}" >&2
        return 1
    fi
    
    # Check if cache is fresh (less than 1 hour old)
    if [[ -f "$CAPACITY_TOPOLOGY_CACHE" ]]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$CAPACITY_TOPOLOGY_CACHE" 2>/dev/null || echo 0)))
        if [[ $cache_age -lt 3600 ]]; then
            return 0
        fi
    fi
    
    echo "Fetching capacity topology from OCI..." >&2
    
    # Get list of capacity topologies (at tenancy level)
    local topologies_json=$(mktemp)
    oci compute capacity-topology list \
        --compartment-id "$TENANCY_ID" \
        --all \
        --output json > "$topologies_json" 2>/dev/null || {
        rm -f "$topologies_json"
        return 1
    }
    
    # Initialize cache file
    echo "# Capacity Topology Hosts" > "$CAPACITY_TOPOLOGY_CACHE"
    echo "# Format: InstanceOCID|HostLifecycleState|HostLifecycleDetails|TopologyOCID" >> "$CAPACITY_TOPOLOGY_CACHE"
    
    # Get topology IDs from data.items
    local topology_ids=$(jq -r '.data.items[]?.id // empty' "$topologies_json" 2>/dev/null)
    
    for topo_id in $topology_ids; do
        [[ -z "$topo_id" ]] && continue
        
        # Get bare metal hosts for this topology
        local hosts_json=$(mktemp)
        oci compute capacity-topology bare-metal-host list \
            --capacity-topology-id "$topo_id" \
            --all \
            --output json > "$hosts_json" 2>/dev/null || {
            rm -f "$hosts_json"
            continue
        }
        
        # Extract host details - instance-id maps to instance OCID
        jq -r '.data.items[]? | "\(.["instance-id"] // "N/A")|\(.["lifecycle-state"] // "N/A")|\(.["lifecycle-details"] // "N/A")|\("'"$topo_id"'")"' "$hosts_json" >> "$CAPACITY_TOPOLOGY_CACHE" 2>/dev/null
        
        rm -f "$hosts_json"
    done
    
    rm -f "$topologies_json"
    return 0
}

# Function to get capacity topology host state details for an instance
get_capacity_topology_state() {
    local instance_ocid="$1"
    
    if [[ ! -f "$CAPACITY_TOPOLOGY_CACHE" ]]; then
        echo "N/A"
        return 1
    fi
    
    local host_line=$(grep "^${instance_ocid}|" "$CAPACITY_TOPOLOGY_CACHE" | head -n1)
    
    if [[ -n "$host_line" ]]; then
        # Return lifecycle-state-details (3rd field)
        local state_details=$(echo "$host_line" | cut -d'|' -f3)
        echo "${state_details:-N/A}"
    else
        echo "N/A"
    fi
}

# Function to fetch and cache GPU memory fabrics
fetch_gpu_fabrics() {
    if [[ -z "$TENANCY_ID" ]]; then
        echo -e "${YELLOW}Warning: TENANCY_ID not set. GPU fabric details will not be available.${NC}" >&2
        return 1
    fi
    
    # Check if cache is fresh (less than 1 hour old)
    if [[ -f "$FABRIC_CACHE" ]]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$FABRIC_CACHE" 2>/dev/null || stat -f %m "$FABRIC_CACHE" 2>/dev/null)))
        if [[ $cache_age -lt 3600 ]]; then
            return 0
        fi
    fi
    
    echo "Fetching GPU memory fabrics from OCI..." >&2
    
    local raw_json=$(mktemp)
    
    oci compute compute-gpu-memory-fabric list \
        --compartment-id "$TENANCY_ID" \
        --all \
        --output json > "$raw_json" 2>/dev/null || {
        rm -f "$raw_json"
        return 1
    }
    
    # Process fabrics into cache
    echo "# GPU Memory Fabrics" > "$FABRIC_CACHE"
    echo "# Format: DisplayName|Last5Chars|FabricOCID|State|AvailableHosts|TotalHosts" >> "$FABRIC_CACHE"
    
    local fabric_count=$(jq '.data.items | length' "$raw_json")
    
    for ((i=0; i<fabric_count; i++)); do
        local display_name=$(jq -r ".data.items[$i].\"display-name\"" "$raw_json")
        local fabric_ocid=$(jq -r ".data.items[$i].id" "$raw_json")
        local state=$(jq -r ".data.items[$i].\"lifecycle-state\"" "$raw_json")
        local available_hosts=$(jq -r ".data.items[$i].\"available-host-count\"" "$raw_json")
        local total_hosts=$(jq -r ".data.items[$i].\"total-host-count\"" "$raw_json")
        
        local last5="${fabric_ocid: -5}"
        last5=$(echo "$last5" | tr '[:upper:]' '[:lower:]')
        
        echo "$display_name|$last5|$fabric_ocid|$state|$available_hosts|$total_hosts" >> "$FABRIC_CACHE"
    done
    
    rm -f "$raw_json"
    return 0
}

# Function to fetch and cache GPU memory clusters
fetch_gpu_clusters() {
    if [[ -z "$COMPARTMENT_ID" ]]; then
        echo -e "${YELLOW}Warning: COMPARTMENT_ID not set. GPU cluster details will not be available.${NC}" >&2
        return 1
    fi
    
    # Check if cache is fresh (less than 1 hour old)
    if [[ -f "$CLUSTER_CACHE" ]]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$CLUSTER_CACHE" 2>/dev/null || stat -f %m "$CLUSTER_CACHE" 2>/dev/null)))
        if [[ $cache_age -lt 3600 ]]; then
            return 0
        fi
    fi
    
    echo "Fetching GPU memory clusters from OCI..." >&2
    
    local raw_json=$(mktemp)
    
    oci compute compute-gpu-memory-cluster list \
        --compartment-id "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}" \
        --all \
        --output json > "$raw_json" 2>/dev/null || {
        rm -f "$raw_json"
        return 1
    }
    
    # Process clusters into cache
    echo "# GPU Memory Clusters" > "$CLUSTER_CACHE"
    echo "# Format: ClusterOCID|DisplayName|State|FabricSuffix" >> "$CLUSTER_CACHE"
    
    local cluster_count=$(jq '.data.items | length' "$raw_json")
    
    for ((i=0; i<cluster_count; i++)); do
        local cluster_ocid=$(jq -r ".data.items[$i].id" "$raw_json")
        local display_name=$(jq -r ".data.items[$i].\"display-name\"" "$raw_json")
        local state=$(jq -r ".data.items[$i].\"lifecycle-state\"" "$raw_json")
        
        # Extract fabric suffix from cluster name
        local fabric_suffix=""
        if [[ "$display_name" =~ fabric-([a-z0-9]{5}) ]]; then
            fabric_suffix="${BASH_REMATCH[1]}"
        elif [[ "$display_name" =~ -([a-z0-9]{5})$ ]]; then
            fabric_suffix="${BASH_REMATCH[1]}"
        fi
        
        echo "$cluster_ocid|$display_name|$state|$fabric_suffix" >> "$CLUSTER_CACHE"
    done
    
    rm -f "$raw_json"
    return 0
}

# Function to fetch and cache node states
fetch_node_states() {
    echo "# Node States" > "$NODE_STATE_CACHE"
    echo "# Format: ProviderID|NodeState" >> "$NODE_STATE_CACHE"
    
    kubectl get nodes -o json 2>/dev/null | jq -r '.items[] | 
        "\(.spec.providerID)|\(
            .status.conditions[] | 
            select(.type=="Ready") | 
            if .status=="True" then "Ready" 
            elif .status=="False" then "NotReady" 
            else "Unknown" end
        )"' >> "$NODE_STATE_CACHE" 2>/dev/null || true
}

# Function to get cluster state from OCID
get_cluster_state() {
    local cluster_ocid="$1"
    
    if [[ ! -f "$CLUSTER_CACHE" ]]; then
        echo "N/A"
        return 1
    fi
    
    # Match on full OCID
    local state=$(grep "^${cluster_ocid}|" "$CLUSTER_CACHE" | cut -d'|' -f3)
    echo "${state:-N/A}"
}

# Function to get fabric details from cluster OCID
get_fabric_from_cluster() {
    local cluster_ocid="$1"
    
    if [[ ! -f "$FABRIC_CACHE" ]] || [[ ! -f "$CLUSTER_CACHE" ]]; then
        echo "N/A|N/A|N/A|N/A|0|0"
        return 1
    fi
    
    # Get fabric suffix from cluster cache - match on full OCID
    local fabric_suffix=$(grep "^${cluster_ocid}|" "$CLUSTER_CACHE" | cut -d'|' -f4)
    
    if [[ -z "$fabric_suffix" ]]; then
        echo "N/A|N/A|N/A|N/A|0|0"
        return 1
    fi
    
    # Find matching fabric
    local fabric_line=$(grep -v '^#' "$FABRIC_CACHE" | grep "|$fabric_suffix|" | head -n1)
    
    if [[ -n "$fabric_line" ]]; then
        echo "$fabric_line"
        return 0
    else
        echo "N/A|N/A|N/A|N/A|0|0"
        return 1
    fi
}

# Function to get node state from cache
get_node_state_cached() {
    local instance_id="$1"
    
    if [[ ! -f "$NODE_STATE_CACHE" ]]; then
        echo "N/A"
        return 1
    fi
    
    local state=$(grep "^${instance_id}|" "$NODE_STATE_CACHE" | cut -d'|' -f2)
    echo "${state:-N/A}"
}

# Function to list fabrics without clusters
list_fabrics_without_clusters() {
    echo -e "${BOLD}${MAGENTA}=== GPU Memory Fabrics Without Active Clusters ===${NC}"
    echo ""
    
    if [[ ! -f "$FABRIC_CACHE" ]] || [[ ! -f "$CLUSTER_CACHE" ]]; then
        echo -e "${YELLOW}Cache files not available${NC}"
        return 1
    fi
    
    # Get all fabric suffixes
    local all_fabric_suffixes=$(grep -v '^#' "$FABRIC_CACHE" | cut -d'|' -f2)
    
    # Get all cluster fabric suffixes (only ACTIVE clusters)
    local used_fabric_suffixes=$(grep -v '^#' "$CLUSTER_CACHE" | grep "|ACTIVE|" | cut -d'|' -f4 | sort -u)
    
    local found_unused=false
    local temp_output=$(mktemp)
    
    while read -r fabric_suffix; do
        # Check if this suffix is used by any ACTIVE cluster
        if ! echo "$used_fabric_suffixes" | grep -q "^${fabric_suffix}$"; then
            found_unused=true
            
            # Get fabric details
            local fabric_line=$(grep -v '^#' "$FABRIC_CACHE" | grep "|$fabric_suffix|" | head -n1)
            IFS='|' read -r fabric_name fabric_suf fabric_ocid fabric_state avail_hosts total_hosts <<< "$fabric_line"
            
            echo "$fabric_name|$fabric_ocid|$fabric_state|${avail_hosts}/${total_hosts}" >> "$temp_output"
        fi
    done <<< "$all_fabric_suffixes"
    
    if [[ "$found_unused" == false ]]; then
        echo -e "${GREEN}All fabrics have active clusters${NC}"
    else
        # Print column headers
        printf "${BOLD}%-40s %-105s %-15s %s${NC}\n" \
            "Fabric Name" "Fabric OCID" "State" "Hosts (Avail/Total)"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        # Print data
        while IFS='|' read -r fabric_name fabric_ocid fabric_state hosts; do
            printf "${CYAN}%-40s${NC} ${YELLOW}%-105s${NC} ${MAGENTA}%-15s${NC} ${GREEN}%s${NC}\n" \
                "$fabric_name" "$fabric_ocid" "$fabric_state" "$hosts"
        done < "$temp_output"
    fi
    
    rm -f "$temp_output"
}

# Function to list instances not in K8s cluster
list_instances_not_in_k8s() {
    local oci_data_file="$1"  # Optional: path to existing OCI data file
    
    echo -e "${BOLD}${MAGENTA}=== GPU Instances Not in Kubernetes Cluster ===${NC}"
    echo ""
    
    # Create temp files
    local oci_temp=$(mktemp)
    local oci_normalized=$(mktemp)
    local k8s_temp=$(mktemp)
    
    # Use provided OCI data or fetch fresh data
    if [[ -n "$oci_data_file" ]] && [[ -f "$oci_data_file" ]]; then
        # Use existing OCI data - need to determine format and normalize
        # All sources should now be filtering for GPU instances already
        # Check first line to determine format
        local first_line=$(head -n1 "$oci_data_file")
        local field_count=$(echo "$first_line" | awk -F'|' '{print NF}')
        
        if [[ $field_count -eq 4 ]]; then
            # Could be either format, check if first field looks like an OCID
            local first_field=$(echo "$first_line" | cut -d'|' -f1)
            if [[ "$first_field" =~ ^ocid1\.instance\. ]]; then
                # Format: instance_id|display_name|state|gpu_cluster (correct format)
                cp "$oci_data_file" "$oci_normalized"
            else
                # Format: display_name|status|instance_ocid|gpu_mem (needs reordering)
                # Reorder to: instance_ocid|display_name|status|gpu_mem
                awk -F'|' '{print $3"|"$1"|"$2"|"$4}' "$oci_data_file" > "$oci_normalized"
            fi
        else
            # Unknown format, copy as-is and hope for the best
            cp "$oci_data_file" "$oci_normalized"
        fi
    else
        # Fetch all instances from OCI in the correct format
        oci compute instance list \
            --compartment-id "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}" \
            --region "${EFFECTIVE_REGION:-$REGION}" \
            --all \
            --output json | jq -r '.data[] | select(."shape" | contains("GPU")) | "\(.id)|\(."display-name")|\(."lifecycle-state")|\(."freeform-tags"."oci:compute:gpumemorycluster" // "N/A")"' > "$oci_normalized" 2>/dev/null
    fi
    
    # Fetch only GPU K8s nodes (not all nodes)
    kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq -r '.items[] | .spec.providerID' > "$k8s_temp" 2>/dev/null
    
    local found_orphaned=false
    local temp_output=$(mktemp)
    
    # Find instances not in K8s
    while IFS='|' read -r instance_id display_name state gpu_cluster; do
        if ! grep -q "^${instance_id}$" "$k8s_temp"; then
            found_orphaned=true
            
            # Get cluster state
            local cluster_state="N/A"
            if [[ "$gpu_cluster" != "N/A" ]]; then
                cluster_state=$(get_cluster_state "$gpu_cluster")
            fi
            
            # Truncate for display
            local gpu_cluster_display="$gpu_cluster"
            if [[ "$gpu_cluster" != "N/A" && ${#gpu_cluster} -gt 20 ]]; then
                gpu_cluster_display="...${gpu_cluster: -17}"
            fi
            
            echo "$display_name|$instance_id|$state|$gpu_cluster_display|$cluster_state" >> "$temp_output"
        fi
    done < "$oci_normalized"
    
    if [[ "$found_orphaned" == false ]]; then
        echo -e "${GREEN}All GPU instances are in the Kubernetes cluster${NC}"
    else
        # Print column headers
        printf "${BOLD}%-30s %-95s %-12s %-23s %s${NC}\n" \
            "Display Name" "Instance OCID" "OCI State" "GPU Cluster" "Cluster State"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        # Print data
        while IFS='|' read -r display_name instance_id state gpu_cluster cluster_state; do
            # Color code the state
            local state_color="${GREEN}"
            if [[ "$state" != "RUNNING" ]]; then
                state_color="${YELLOW}"
            fi
            
            printf "${WHITE}%-30s${NC} ${YELLOW}%-95s${NC} ${state_color}%-12s${NC} ${CYAN}%-23s${NC} ${MAGENTA}%s${NC}\n" \
                "$display_name" "$instance_id" "$state" "$gpu_cluster" "$cluster_state"
        done < "$temp_output"
    fi
    
    rm -f "$oci_temp" "$oci_normalized" "$k8s_temp" "$temp_output"
}

# Function to list all unique cliques
list_all_cliques() {
    echo -e "${BOLD}${MAGENTA}=== All GPU Cliques in Kubernetes Cluster ===${NC}"
    echo ""
    
    # Fetch fabrics and clusters first
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_node_states
    
    # Get all unique cliques (GPU nodes only)
    local cliques=$(kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq -r '.items[].metadata.labels["nvidia.com/gpu.clique"]' | grep -v null | sort -u)
    
    if [[ -z "$cliques" ]]; then
        echo -e "${YELLOW}No GPU cliques found in the cluster${NC}"
        return 0
    fi
    
    local total_cliques=$(echo "$cliques" | wc -l)
    echo -e "${BOLD}${CYAN}Total Cliques Found:${NC} $total_cliques"
    echo ""
    
    # Create temp file for OCI data
    local oci_data=$(mktemp)
    
    # Fetch all instances from OCI once
    echo "Fetching all instance details from OCI..."
    oci compute instance list \
        --compartment-id "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}" \
        --region "${EFFECTIVE_REGION:-$REGION}" \
        --all \
        --output json | jq -r '.data[] | select(."shape" | contains("GPU")) | "\(.id)|\(."display-name")|\(."lifecycle-state")|\(."freeform-tags"."oci:compute:gpumemorycluster" // "N/A")"' > "$oci_data"
    
    # Iterate through each clique
    while read -r clique_id; do
        [[ -z "$clique_id" ]] && continue
        
        echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}${YELLOW}Clique ID:${NC} $clique_id"
        
        # Get all GPU nodes in this clique
        local node_count=$(kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
        echo -e "${BOLD}${CYAN}Node Count:${NC} $node_count"
        echo ""
        
        # Get nodes grouped by GPU memory cluster
        declare -A cluster_nodes
        declare -A cluster_fabrics
        declare -A cluster_states
        local clique_data=$(kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq -r --arg clique "$clique_id" '
            .items[] | 
            select(.metadata.labels["nvidia.com/gpu.clique"]==$clique) | 
            "\(.metadata.name)|\(.spec.providerID)"
        ')
        
        while IFS='|' read -r node ocid; do
            # Look up GPU memory cluster from cached OCI data - get FULL OCID
            local gpu_mem_cluster=$(grep "^${ocid}|" "$oci_data" | cut -d'|' -f4)
            gpu_mem_cluster=${gpu_mem_cluster:-N/A}
            
            # Get fabric and cluster state info if we haven't fetched it for this cluster yet
            if [[ -z "${cluster_fabrics[$gpu_mem_cluster]}" ]] && [[ "$gpu_mem_cluster" != "N/A" ]]; then
                local fabric_info=$(get_fabric_from_cluster "$gpu_mem_cluster")
                cluster_fabrics[$gpu_mem_cluster]="$fabric_info"
                
                local cluster_state=$(get_cluster_state "$gpu_mem_cluster")
                cluster_states[$gpu_mem_cluster]="$cluster_state"
            fi
            
            # Append to the cluster group
            if [[ -z "${cluster_nodes[$gpu_mem_cluster]}" ]]; then
                cluster_nodes[$gpu_mem_cluster]="$node|$ocid"
            else
                cluster_nodes[$gpu_mem_cluster]="${cluster_nodes[$gpu_mem_cluster]}"$'\n'"$node|$ocid"
            fi
        done <<< "$clique_data"
        
        # Display grouped by GPU memory cluster with fabric info
        for mem_cluster in $(echo "${!cluster_nodes[@]}" | tr ' ' '\n' | sort); do
            local cluster_node_count=$(echo "${cluster_nodes[$mem_cluster]}" | wc -l)
            
            echo -e "${BOLD}${GREEN}  GPU Mem Cluster: $mem_cluster${NC} ${CYAN}(Nodes: $cluster_node_count)${NC}"
            
            # Show cluster state
            if [[ -n "${cluster_states[$mem_cluster]}" ]]; then
                echo -e "    ${YELLOW}├─ Cluster State:${NC} ${cluster_states[$mem_cluster]}"
            fi
            
            # Show fabric info if available
            if [[ -n "${cluster_fabrics[$mem_cluster]}" ]]; then
                IFS='|' read -r fabric_name fabric_suffix fabric_ocid fabric_state avail_hosts total_hosts <<< "${cluster_fabrics[$mem_cluster]}"
                
                if [[ "$fabric_name" != "N/A" ]]; then
                    echo -e "    ${MAGENTA}├─ Fabric Name:${NC} $fabric_name"
                    echo -e "    ${MAGENTA}├─ Fabric OCID:${NC} $fabric_ocid"
                    echo -e "    ${MAGENTA}├─ Fabric State:${NC} $fabric_state"
                    echo -e "    ${MAGENTA}└─ Hosts:${NC} ${avail_hosts}/${total_hosts} available"
                    echo ""
                fi
            fi
            
            while IFS='|' read -r node ocid; do
                local node_state=$(get_node_state_cached "$ocid")
                local state_color="${GREEN}"
                if [[ "$node_state" != "Ready" ]]; then
                    state_color="${RED}"
                fi
                echo -e "    ${WHITE}$node${NC} ${state_color}($node_state)${NC} - ${YELLOW}$ocid${NC}"
            done <<< "${cluster_nodes[$mem_cluster]}"
            echo ""
        done
        
        unset cluster_nodes
        unset cluster_fabrics
        unset cluster_states
    done <<< "$cliques"
    
    # Cleanup
    # Don't cleanup yet - pass to list_instances_not_in_k8s
    
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Show fabrics without clusters
    list_fabrics_without_clusters
    echo ""
    
    # Show instances not in K8s - pass the OCI data file
    list_instances_not_in_k8s "$oci_data"
    
    # Now cleanup
    rm -f "$oci_data"
}

# Function to get summary of all cliques
list_cliques_summary() {
    echo -e "${BOLD}${MAGENTA}=== GPU Cliques Summary ===${NC}"
    echo ""
    
    # Fetch fabrics and clusters first
    fetch_gpu_fabrics
    fetch_gpu_clusters
    
    # Get all unique cliques (GPU nodes only)
    local cliques=$(kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq -r '.items[].metadata.labels["nvidia.com/gpu.clique"]' | grep -v null | sort -u)
    
    if [[ -z "$cliques" ]]; then
        echo -e "${YELLOW}No GPU cliques found in the cluster${NC}"
        return 0
    fi
    
    # Create temp file for OCI data
    local oci_data=$(mktemp)
    
    # Fetch all instances from OCI once
    echo "Fetching all instance details from OCI..."
    oci compute instance list \
        --compartment-id "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}" \
        --region "${EFFECTIVE_REGION:-$REGION}" \
        --all \
        --output json | jq -r '.data[] | select(."shape" | contains("GPU")) | "\(.id)|\(."display-name")|\(."lifecycle-state")|\(."freeform-tags"."oci:compute:gpumemorycluster" // "N/A")"' > "$oci_data"
    
    echo ""
    
    # Collect summary data
    local temp_output=$(mktemp)
    
    while read -r clique_id; do
        [[ -z "$clique_id" ]] && continue
        
        # Get all GPU nodes in this clique
        local node_count=$(kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
        
        # Get unique GPU memory clusters for this clique
        local clique_data=$(kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq -r --arg clique "$clique_id" '
            .items[] | 
            select(.metadata.labels["nvidia.com/gpu.clique"]==$clique) | 
            .spec.providerID
        ')
        
        declare -A mem_clusters
        local first_cluster=""
        
        while read -r ocid; do
            [[ -z "$ocid" ]] && continue
            # Get FULL cluster OCID
            local gpu_mem_cluster=$(grep "^${ocid}|" "$oci_data" | cut -d'|' -f4)
            gpu_mem_cluster=${gpu_mem_cluster:-N/A}
            mem_clusters[$gpu_mem_cluster]=1
            
            if [[ -z "$first_cluster" ]] && [[ "$gpu_mem_cluster" != "N/A" ]]; then
                first_cluster="$gpu_mem_cluster"
            fi
        done <<< "$clique_data"
        
        local cluster_count="${#mem_clusters[@]}"
        
        # Get fabric and cluster state for first cluster
        local fabric_display="N/A"
        local fabric_ocid_display="N/A"
        local cluster_state="N/A"
        if [[ -n "$first_cluster" ]]; then
            local fabric_info=$(get_fabric_from_cluster "$first_cluster")
            IFS='|' read -r fabric_name fabric_suffix fabric_ocid fabric_state avail_hosts total_hosts <<< "$fabric_info"
            fabric_display="$fabric_name"
            fabric_ocid_display="$fabric_ocid"
            
            # Get cluster state
            cluster_state=$(get_cluster_state "$first_cluster")
        fi
        
        # Don't truncate - show full values
        local clique_display="$clique_id"
        local fabric_ocid_short="$fabric_ocid_display"
        
        echo "$clique_display|$node_count|$cluster_count|$first_cluster|$cluster_state|$fabric_display|$fabric_ocid_short" >> "$temp_output"
        
        unset mem_clusters
    done <<< "$cliques"
    
    # Print column headers
    printf "${BOLD}%-48s %-7s %-4s %-106s %-18s${NC}\n" \
        "Clique ID" "Nodes" "#Cl" "GPU Memory Cluster" "State"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Print data
    while IFS='|' read -r clique_id nodes clusters gpu_mem_cluster cluster_state fabric_name fabric_ocid; do
        # Print main line
        printf "${CYAN}%-48s${NC} ${GREEN}%-7s${NC} ${YELLOW}%-4s${NC} ${MAGENTA}%-95s${NC} ${WHITE}%-12s${NC}\n" \
            "$clique_id" "$nodes" "$clusters" "$gpu_mem_cluster" "$cluster_state"
        # Print fabric details on second line if available
        if [[ "$fabric_name" != "N/A" && "$fabric_ocid" != "N/A" ]]; then
            printf "          ${BOLD}${MAGENTA}└─ Fabric:${NC} ${WHITE}%-40s${NC} ${CYAN}%s${NC}\n" \
                "$fabric_name" "$fabric_ocid"
        fi
        echo ""
    done < "$temp_output"
    
    # Cleanup temp_output but keep oci_data for list_instances_not_in_k8s
    rm -f "$temp_output"
    
    echo ""
    
    # Show fabrics without clusters
    list_fabrics_without_clusters
    echo ""
    
    # Show instances not in K8s - pass the OCI data file
    list_instances_not_in_k8s "$oci_data"
    
    # Now cleanup oci_data
    rm -f "$oci_data"
}

# Function to get node name from instance OCID
get_node_info() {
    local instance_id="$1"
    local show_labels="$2"
    local show_clique="$3"
    local count_clique="$4"
    
    # Fetch fabrics and clusters first
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_node_states
    
    local provider_id="${instance_id}"
    local node_name=$(kubectl get nodes -o jsonpath="{.items[?(@.spec.providerID=='${provider_id}')].metadata.name}" 2>/dev/null)
    
    if [[ -z "$node_name" ]]; then
        echo -e "${RED}Could not find Kubernetes node for instance OCID: $instance_id${NC}"
        return 1
    fi
    
    echo -e "${BOLD}${CYAN}Node Name:${NC} $node_name"
    echo -e "${BOLD}${CYAN}Instance OCID:${NC} $instance_id"
    
    # Get and show node state
    local node_state=$(get_node_state_cached "$instance_id")
    local state_color="${GREEN}"
    if [[ "$node_state" != "Ready" ]]; then
        state_color="${RED}"
    fi
    echo -e "${BOLD}${CYAN}Node State:${NC} ${state_color}$node_state${NC}"
    
    # Show labels if requested
    if [[ "$show_labels" == "true" ]]; then
        echo ""
        echo -e "${BOLD}${MAGENTA}=== All Labels ===${NC}"
        kubectl get node "$node_name" -o json | jq -r '.metadata.labels | to_entries | .[] | "\(.key): \(.value)"'
        
        echo ""
        echo -e "${BOLD}${MAGENTA}=== GPU Labels Only ===${NC}"
        kubectl get node "$node_name" -o json | jq -r '.metadata.labels | to_entries | map(select(.key | contains("nvidia.com/gpu"))) | .[] | "\(.key): \(.value)"'
    fi
    
    # Show clique ID if requested
    if [[ "$show_clique" == "true" ]]; then
        local clique_id=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.clique}' 2>/dev/null)
        local clique_size=$(kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
        
        echo ""
        echo -e "${BOLD}${GREEN}=== GPU Clique Information ===${NC}"
        echo -e "${CYAN}GPU Clique ID:${NC} ${clique_id:-N/A}"
        echo -e "${CYAN}GPU Clique Size:${NC} ${clique_size:-N/A}"
        
        # Get OCI gpu-memory-cluster tag
        echo ""
        echo -e "${BOLD}${GREEN}=== OCI Instance Tags ===${NC}"
        local gpu_memory_cluster=$(oci compute instance get --instance-id "$instance_id" --query 'data."freeform-tags"."oci:compute:gpumemorycluster"' --raw-output 2>/dev/null)
        echo -e "${CYAN}GPU Memory Cluster (OCI Tag):${NC} ${gpu_memory_cluster:-N/A}"
        
        # Show cluster state
        if [[ -n "$gpu_memory_cluster" ]] && [[ "$gpu_memory_cluster" != "N/A" ]] && [[ "$gpu_memory_cluster" != "null" ]]; then
            local cluster_state=$(get_cluster_state "$gpu_memory_cluster")
            echo -e "${CYAN}GPU Memory Cluster State:${NC} $cluster_state"
        fi
        
        # Get fabric info
        if [[ -n "$gpu_memory_cluster" ]] && [[ "$gpu_memory_cluster" != "N/A" ]] && [[ "$gpu_memory_cluster" != "null" ]]; then
            echo ""
            echo -e "${BOLD}${GREEN}=== GPU Memory Fabric ===${NC}"
            
            local fabric_info=$(get_fabric_from_cluster "$gpu_memory_cluster")
            IFS='|' read -r fabric_name fabric_suffix fabric_ocid fabric_state avail_hosts total_hosts <<< "$fabric_info"
            
            if [[ "$fabric_name" != "N/A" ]]; then
                echo -e "${MAGENTA}Fabric Name:${NC} $fabric_name"
                echo -e "${MAGENTA}Fabric OCID:${NC} $fabric_ocid"
                echo -e "${MAGENTA}Fabric Suffix:${NC} $fabric_suffix"
                echo -e "${MAGENTA}Fabric State:${NC} $fabric_state"
                echo -e "${MAGENTA}Host Capacity:${NC} ${avail_hosts}/${total_hosts} available"
            else
                echo -e "${YELLOW}Fabric information not found${NC}"
            fi
        fi
    fi
    
    # Count nodes with same clique ID if requested
    if [[ "$count_clique" == "true" ]]; then
        local clique_id=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.clique}' 2>/dev/null)
        
        if [[ -n "$clique_id" && "$clique_id" != "null" ]]; then
            echo ""
            echo -e "${BOLD}${BLUE}=== All Nodes in Same Clique ($clique_id) ===${NC}"
            echo ""
            
            # Get all GPU nodes with same clique
            local nodes_json=$(kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)]')
            local nodes_with_clique=$(echo "$nodes_json" | jq -r '.[] | "\(.metadata.name)|\(.spec.providerID)"')
            
            # Create temp file for OCI data
            local oci_temp=$(mktemp)
            oci compute instance list \
                --compartment-id "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}" \
                --region "${EFFECTIVE_REGION:-$REGION}" \
                --all \
                --output json | jq -r '.data[] | "\(.id)|\(."display-name")|\(."lifecycle-state")|\(."freeform-tags"."oci:compute:gpumemorycluster" // "N/A")"' > "$oci_temp"
            
            # Group by GPU memory cluster
            declare -A cluster_nodes
            declare -A cluster_fabrics
            declare -A cluster_states
            
            while IFS='|' read -r node_name provider_id; do
                # Get FULL cluster OCID
                local gpu_mem=$(grep "^${provider_id}|" "$oci_temp" | cut -d'|' -f4)
                gpu_mem=${gpu_mem:-N/A}
                
                # Get fabric and cluster state info if we haven't fetched it for this cluster yet
                if [[ -z "${cluster_fabrics[$gpu_mem]}" ]] && [[ "$gpu_mem" != "N/A" ]]; then
                    local fabric_info=$(get_fabric_from_cluster "$gpu_mem")
                    cluster_fabrics[$gpu_mem]="$fabric_info"
                    
                    local cluster_state=$(get_cluster_state "$gpu_mem")
                    cluster_states[$gpu_mem]="$cluster_state"
                fi
                
                if [[ -z "${cluster_nodes[$gpu_mem]}" ]]; then
                    cluster_nodes[$gpu_mem]="$node_name|$provider_id"
                else
                    cluster_nodes[$gpu_mem]="${cluster_nodes[$gpu_mem]}"$'\n'"$node_name|$provider_id"
                fi
            done <<< "$nodes_with_clique"
            
            # Display by GPU memory cluster
            for gpu_mem in $(echo "${!cluster_nodes[@]}" | tr ' ' '\n' | sort); do
                local count=$(echo "${cluster_nodes[$gpu_mem]}" | wc -l)
                echo -e "${BOLD}${GREEN}GPU Mem Cluster: $gpu_mem${NC} ${CYAN}(Nodes: $count)${NC}"
                
                # Show cluster state
                if [[ -n "${cluster_states[$gpu_mem]}" ]]; then
                    echo -e "  ${YELLOW}├─ Cluster State:${NC} ${cluster_states[$gpu_mem]}"
                fi
                
                # Show fabric info if available
                if [[ -n "${cluster_fabrics[$gpu_mem]}" ]]; then
                    IFS='|' read -r fabric_name fabric_suffix fabric_ocid fabric_state avail_hosts total_hosts <<< "${cluster_fabrics[$gpu_mem]}"
                    
                    if [[ "$fabric_name" != "N/A" ]]; then
                        echo -e "  ${MAGENTA}├─ Fabric Name:${NC} $fabric_name"
                        echo -e "  ${MAGENTA}├─ Fabric OCID:${NC} $fabric_ocid"
                        echo -e "  ${MAGENTA}├─ Fabric State:${NC} $fabric_state"
                        echo -e "  ${MAGENTA}└─ Hosts:${NC} ${avail_hosts}/${total_hosts} available"
                        echo ""
                    fi
                fi
                
                while IFS='|' read -r node provider_id; do
                    local oci_info=$(grep "^${provider_id}|" "$oci_temp")
                    IFS='|' read -r ocid display_name state gpu_cluster <<< "$oci_info"
                    
                    local node_state=$(get_node_state_cached "$provider_id")
                    local state_color="${GREEN}"
                    if [[ "$node_state" != "Ready" ]]; then
                        state_color="${RED}"
                    fi
                    
                    if [[ "$node" == "$(kubectl get nodes -o jsonpath="{.items[?(@.spec.providerID=='${instance_id}')].metadata.name}")" ]]; then
                        echo -e "  ${BOLD}${WHITE}► $node${NC} ${state_color}($node_state)${NC} ${YELLOW}(this node)${NC}"
                    else
                        echo -e "  ${WHITE}  $node${NC} ${state_color}($node_state)${NC}"
                    fi
                    echo -e "    ${CYAN}Display Name:${NC} $display_name"
                    echo -e "    ${CYAN}State:${NC} $state"
                    echo -e "    ${CYAN}Instance OCID:${NC} $provider_id"
                    echo ""
                done <<< "${cluster_nodes[$gpu_mem]}"
            done
            
            rm -f "$oci_temp"
            unset cluster_nodes
            unset cluster_fabrics
            unset cluster_states
        fi
    fi
}

# Function to list all GPU instances in compartment
list_all_instances() {
    local compartment_id="$1"
    local region="$2"
    
    # Fetch fabrics and clusters first
    fetch_gpu_fabrics
    fetch_gpu_clusters
    
    if [[ -z "$compartment_id" ]]; then
        echo -e "${RED}Error: COMPARTMENT_ID not set in variables.sh${NC}"
        return 1
    fi
    
    if [[ -z "$region" ]]; then
        echo -e "${RED}Error: REGION not set in variables.sh${NC}"
        return 1
    fi
    
    echo -e "${BOLD}${MAGENTA}=== All GPU Instances in Compartment ===${NC}"
    echo -e "${CYAN}Compartment:${NC} $compartment_id"
    echo -e "${CYAN}Region:${NC} $region"
    echo ""
    
    # Create temp files
    local oci_temp=$(mktemp)
    local k8s_temp=$(mktemp)
    
    # Fetch all instances from OCI
    echo "Fetching instances from OCI..."
    oci compute instance list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json | jq -r '.data[] | select(."shape" | contains("GPU")) | "\(."display-name")|\(."lifecycle-state")|\(.id)|\(."freeform-tags"."oci:compute:gpumemorycluster" // "N/A")"' > "$oci_temp"
    
    # Fetch all K8s GPU nodes only
    echo "Fetching GPU nodes from Kubernetes..."
    kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq -r '.items[] | "\(.spec.providerID)|\(.metadata.name)|\(.metadata.labels."nvidia.com/gpu.clique" // "N/A")"' > "$k8s_temp"
    
    # Fetch node states once
    echo "Fetching node states..."
    fetch_node_states
    
    # Fetch announcements
    echo "Fetching announcements..."
    build_announcement_lookup "$compartment_id"
    
    # Fetch capacity topology
    echo "Fetching capacity topology..."
    fetch_capacity_topology
    
    echo "Processing data..."
    echo ""
    
    # Print table header
    printf "${BOLD}%-28s %-15s %-11s %-10s %-95s %-12s %-12s %-40s %-10s %-18s${NC}\n" \
        "Display Name" "K8s Node" "Node State" "OCI State" "Instance OCID" "GPU Cluster" "Cluster St" "Clique ID" "CapTopo" "Announce"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Join the data and print (only include GPU nodes)
    local output_temp=$(mktemp)
    
    while IFS='|' read -r display_name status instance_ocid gpu_mem; do
        local k8s_info=$(grep "^${instance_ocid}|" "$k8s_temp")
        if [[ -n "$k8s_info" ]]; then
            # Only include if it's in K8s GPU nodes
            IFS='|' read -r ocid node_name clique_id <<< "$k8s_info"
            
            # Get node state from cache
            local node_state=$(get_node_state_cached "$instance_ocid")
            
            # Get cluster state using FULL OCID
            local cluster_state="N/A"
            if [[ "$gpu_mem" != "N/A" ]]; then
                cluster_state=$(get_cluster_state "$gpu_mem")
            fi
            
            # Truncate GPU mem cluster for display
            local gpu_mem_display="$gpu_mem"
            if [[ "$gpu_mem" != "N/A" && ${#gpu_mem} -gt 12 ]]; then
                gpu_mem_display="${gpu_mem: -12}"
            fi
            
            # Truncate cluster state for display
            local cluster_state_display="$cluster_state"
            if [[ ${#cluster_state} -gt 12 ]]; then
                cluster_state_display="${cluster_state:0:9}..."
            fi
            
            # Don't truncate - show full clique ID
            local clique_display="$clique_id"
            
            # Get capacity topology state for this instance
            local cap_topo_state=$(get_capacity_topology_state "$instance_ocid")
            
            # Get announcements for this instance
            local announcements=$(get_resource_announcements "$instance_ocid" "$gpu_mem")
            
            # Store for sorting: gpu_mem|display_name|rest_of_line
            echo "$gpu_mem|$display_name|%-28s %-15s %-11s %-10s %-95s %-12s %-12s %s\n||$display_name||$node_name||$node_state||$status||$instance_ocid||$gpu_mem_display||$cluster_state_display||$clique_display||$gpu_mem||$cap_topo_state||$announcements" >> "$output_temp"
        fi
    done < "$oci_temp"
    
    # Sort by GPU memory cluster (column 1), then display name (column 2)
    sort -t'|' -k1,1 -k2,2 "$output_temp" | while IFS='|' read -r gpu_mem display_name format_str _ dn _ nn _ ns _ st _ io _ gm _ cs _ cd _ gpu_mem_full _ ct _ ann; do
        # Color code node state
        local node_state_color="${GREEN}"
        if [[ "$ns" != "Ready" ]]; then
            node_state_color="${RED}"
        fi
        
        # Color code OCI state
        local oci_state_color="${GREEN}"
        if [[ "$st" != "RUNNING" ]]; then
            oci_state_color="${YELLOW}"
        fi
        
        # Color code capacity topology state
        local cap_topo_color="${RED}"
        if [[ "$ct" == "AVAILABLE" ]]; then
            cap_topo_color="${GREEN}"
        elif [[ "$ct" == "N/A" ]]; then
            cap_topo_color="${YELLOW}"
        fi
        
        # Color code announcements
        local announce_color="${GREEN}"
        if [[ "$ann" != "-" ]]; then
            announce_color="${RED}"
        fi
        
        printf "%-28s %-15s ${node_state_color}%-11s${NC} ${oci_state_color}%-10s${NC} %-95s %-12s %-12s %-40s ${cap_topo_color}%-10s${NC} ${announce_color}%-18s${NC}\n" \
            "$dn" "$nn" "$ns" "$st" "$io" "$gm" "$cs" "$cd" "$ct" "$ann"
    done
    
    rm -f "$output_temp"
    
    echo ""
    
    # Create joined temp file for summary - store FULL gpu_mem OCID
    local joined_temp=$(mktemp)
    while IFS='|' read -r display_name status instance_ocid gpu_mem; do
        local k8s_info=$(grep "^${instance_ocid}|" "$k8s_temp")
        if [[ -n "$k8s_info" ]]; then
            IFS='|' read -r ocid node_name clique_id <<< "$k8s_info"
            # Store FULL gpu_mem OCID for lookups
            echo "$display_name|$node_name|$status|$instance_ocid|$gpu_mem|$clique_id" >> "$joined_temp"
        fi
    done < "$oci_temp"
    
    # Get unique cliques
    local unique_cliques=$(awk -F'|' '{print $6}' "$joined_temp" | sort -u)
    
    # Display summary by clique
    echo -e "${BOLD}${BLUE}=== Summary by GPU Clique ===${NC}"
    echo ""
    
    # Collect summary data
    local summary_temp=$(mktemp)
    
    while read -r clique; do
        [[ -z "$clique" ]] && continue
        
        if [[ "$clique" == "N/A" ]]; then
            local clique_display="N/A (No GPU or not in cluster)"
        else
            local clique_display="$clique"
        fi
        
        local clique_size=$(grep -c "|${clique}\$" "$joined_temp")
        
        # Get all entries for this clique from joined file
        local clique_entries=$(grep "|${clique}\$" "$joined_temp")
        
        # Get unique GPU memory clusters for this clique
        declare -A gpu_clusters_count
        declare -A gpu_clusters_fabrics
        declare -A gpu_clusters_states
        
        while IFS='|' read -r display_name node_name status instance_ocid gpu_mem clique_id; do
            if [[ -n "$gpu_mem" ]]; then
                if [[ -z "${gpu_clusters_count[$gpu_mem]}" ]]; then
                    gpu_clusters_count[$gpu_mem]=1
                    
                    # Fetch fabric and cluster state info using FULL OCID
                    if [[ "$gpu_mem" != "N/A" ]]; then
                        local fabric_info=$(get_fabric_from_cluster "$gpu_mem")
                        gpu_clusters_fabrics[$gpu_mem]="$fabric_info"
                        
                        local cluster_state=$(get_cluster_state "$gpu_mem")
                        gpu_clusters_states[$gpu_mem]="$cluster_state"
                    fi
                else
                    ((gpu_clusters_count[$gpu_mem]++))
                fi
            fi
        done <<< "$clique_entries"
        
        # Get first cluster info for summary
        local first_gpu_mem=$(echo "${!gpu_clusters_count[@]}" | tr ' ' '\n' | sort | head -n1)
        local fabric_name="N/A"
        local fabric_ocid="N/A"
        local cluster_state="N/A"
        
        if [[ -n "$first_gpu_mem" ]] && [[ "$first_gpu_mem" != "N/A" ]]; then
            IFS='|' read -r fabric_name fabric_suffix fabric_ocid fabric_state avail_hosts total_hosts <<< "${gpu_clusters_fabrics[$first_gpu_mem]}"
            cluster_state="${gpu_clusters_states[$first_gpu_mem]}"
        fi
        
        # Don't truncate - show full values
        local fabric_ocid_short="$fabric_ocid"
        
        echo "$clique_display|$clique_size|${#gpu_clusters_count[@]}|$first_gpu_mem|$cluster_state|$fabric_name|$fabric_ocid_short" >> "$summary_temp"
        
        unset gpu_clusters_count
        unset gpu_clusters_fabrics
        unset gpu_clusters_states
    done <<< "$unique_cliques"
    
    # Print column headers
    printf "${BOLD}%-48s %-7s %-4s %-106s %-18s${NC}\n" \
        "Clique ID" "Nodes" "#Cl" "GPU Memory Cluster" "State"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Print data
    while IFS='|' read -r clique_id nodes clusters gpu_mem_cluster cluster_state fabric_name fabric_ocid; do
        # Print main line
        printf "${CYAN}%-48s${NC} ${GREEN}%-7s${NC} ${YELLOW}%-4s${NC} ${MAGENTA}%-95s${NC} ${WHITE}%-12s${NC}\n" \
            "$clique_id" "$nodes" "$clusters" "$gpu_mem_cluster" "$cluster_state"
        # Print fabric details on second line if available
        if [[ "$fabric_name" != "N/A" && "$fabric_ocid" != "N/A" ]]; then
            printf "          ${BOLD}${MAGENTA}└─ Fabric:${NC} ${WHITE}%-40s${NC} ${CYAN}%s${NC}\n" \
                "$fabric_name" "$fabric_ocid"
        fi
        echo ""
    done < "$summary_temp"
    
    # Cleanup most temp files but keep oci_temp for list_instances_not_in_k8s
    rm -f "$k8s_temp" "$joined_temp" "$summary_temp"
    
    echo ""
    
    # Show fabrics without clusters
    list_fabrics_without_clusters
    echo ""
    
    # Show instances not in K8s - pass the OCI data file
    list_instances_not_in_k8s "$oci_temp"
    
    # Now cleanup oci_temp
    rm -f "$oci_temp"
}

# Function to list all instances in a GPU memory cluster
list_instances_by_gpu_cluster() {
    local gpu_cluster="$1"
    local compartment_id="$2"
    local region="$3"
    
    # Fetch fabrics and clusters first
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_node_states
    
    if [[ -z "$gpu_cluster" ]]; then
        echo -e "${RED}Error: GPU cluster ID required${NC}"
        return 1
    fi
    
    if [[ -z "$compartment_id" ]]; then
        echo -e "${RED}Error: COMPARTMENT_ID not set in variables.sh${NC}"
        return 1
    fi
    
    if [[ -z "$region" ]]; then
        echo -e "${RED}Error: REGION not set in variables.sh${NC}"
        return 1
    fi
    
    echo -e "${BOLD}${MAGENTA}=== Instances in GPU Memory Cluster: $gpu_cluster ===${NC}"
    echo -e "${CYAN}Compartment:${NC} $compartment_id"
    echo -e "${CYAN}Region:${NC} $region"
    echo ""
    
    # Get cluster state
    local cluster_state=$(get_cluster_state "$gpu_cluster")
    echo -e "${BOLD}${GREEN}=== GPU Memory Cluster ===${NC}"
    echo -e "${YELLOW}Cluster State:${NC} $cluster_state"
    echo ""
    
    # Get fabric info
    local fabric_info=$(get_fabric_from_cluster "$gpu_cluster")
    IFS='|' read -r fabric_name fabric_suffix fabric_ocid fabric_state avail_hosts total_hosts <<< "$fabric_info"
    
    if [[ "$fabric_name" != "N/A" ]]; then
        echo -e "${BOLD}${GREEN}=== GPU Memory Fabric ===${NC}"
        echo -e "${MAGENTA}Fabric Name:${NC} $fabric_name"
        echo -e "${MAGENTA}Fabric OCID:${NC} $fabric_ocid"
        echo -e "${MAGENTA}Fabric State:${NC} $fabric_state"
        echo -e "${MAGENTA}Host Capacity:${NC} ${avail_hosts}/${total_hosts} available"
        echo ""
    fi
    
    # Create temp file for OCI data
    local oci_data=$(mktemp)
    
    # Fetch all instances from OCI once
    echo "Fetching all instance details from OCI..."
    oci compute instance list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json | jq -r '.data[] | "\(.id)|\(."display-name")|\(."lifecycle-state")|\(."freeform-tags"."oci:compute:gpumemorycluster" // "N/A")"' > "$oci_data"
    
    echo ""
    
    # Filter for the specific GPU cluster (only GPU nodes)
    grep "|${gpu_cluster}\$" "$oci_data" | while IFS='|' read -r instance_id display_name state gpu_mem; do
        # Check if this instance is a GPU node in K8s
        local node_name=$(kubectl get nodes -l nvidia.com/gpu.present=true -o jsonpath="{.items[?(@.spec.providerID=='${instance_id}')].metadata.name}" 2>/dev/null)
        
        if [[ -n "$node_name" ]]; then
            echo -e "${BOLD}${CYAN}Display Name:${NC} $display_name"
            
            # Get node state
            local node_state=$(get_node_state_cached "$instance_id")
            local node_state_color="${GREEN}"
            if [[ "$node_state" != "Ready" ]]; then
                node_state_color="${RED}"
            fi
            echo -e "${BOLD}${CYAN}Node State:${NC} ${node_state_color}$node_state${NC}"
            
            # Color code the OCI state
            if [[ "$state" == "RUNNING" ]]; then
                echo -e "${BOLD}${CYAN}OCI State:${NC} ${GREEN}$state${NC}"
            else
                echo -e "${BOLD}${CYAN}OCI State:${NC} ${YELLOW}$state${NC}"
            fi
            
            echo -e "  ${GREEN}$node_name${NC} - ${YELLOW}$instance_id${NC}"
            local clique_id=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.clique}' 2>/dev/null)
            if [[ -n "$clique_id" && "$clique_id" != "null" ]]; then
                echo -e "${BOLD}${CYAN}GPU Clique ID:${NC} $clique_id"
            fi
            echo ""
        fi
    done
    
    # Cleanup
    rm -f "$oci_data"
}

# Main script

# Parse global options first
CUSTOM_COMPARTMENT=""
CUSTOM_REGION=""

# Check for --compartment-id option
args=("$@")
new_args=()
i=0
while [[ $i -lt ${#args[@]} ]]; do
    if [[ "${args[$i]}" == "--compartment-id" ]]; then
        if [[ $((i + 1)) -lt ${#args[@]} ]]; then
            CUSTOM_COMPARTMENT="${args[$((i + 1))]}"
            i=$((i + 2))
        else
            echo -e "${RED}Error: --compartment-id requires a value${NC}"
            exit 1
        fi
    elif [[ "${args[$i]}" == "--region" ]]; then
        if [[ $((i + 1)) -lt ${#args[@]} ]]; then
            CUSTOM_REGION="${args[$((i + 1))]}"
            i=$((i + 2))
        else
            echo -e "${RED}Error: --region requires a value${NC}"
            exit 1
        fi
    else
        new_args+=("${args[$i]}")
        i=$((i + 1))
    fi
done

# Use custom values if provided, otherwise use defaults from variables.sh
EFFECTIVE_COMPARTMENT_ID="${CUSTOM_COMPARTMENT:-$COMPARTMENT_ID}"
EFFECTIVE_REGION="${CUSTOM_REGION:-$REGION}"

# Restore positional parameters without the global options
set -- "${new_args[@]}"

if [ -z "$1" ]; then
    # No arguments - list all GPU instances in compartment
    list_all_instances "$EFFECTIVE_COMPARTMENT_ID" "$EFFECTIVE_REGION"
    exit 0
fi

# Check for clique listing options
if [[ "$1" == "--list-cliques" ]]; then
    list_all_cliques
    exit 0
fi

if [[ "$1" == "--cliques-summary" ]]; then
    list_cliques_summary
    exit 0
fi

# Check if listing by GPU cluster
if [[ "$1" == "--list-cluster" ]]; then
    if [[ -z "$2" ]]; then
        echo -e "${RED}Error: GPU cluster ID required${NC}"
        echo "Usage: $0 --list-cluster <gpu-cluster-id>"
        exit 1
    fi
    
    gpu_cluster="$2"
    list_instances_by_gpu_cluster "$gpu_cluster" "$EFFECTIVE_COMPARTMENT_ID" "$EFFECTIVE_REGION"
    exit $?
fi

# Check if showing help
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo -e "${BOLD}Usage:${NC} $0 [OPTIONS] [instance-ocid] [OPTIONS]"
    echo ""
    echo "If no instance-ocid is provided, lists all GPU instances in the compartment with fabric details"
    echo ""
    echo -e "${BOLD}Global Options:${NC}"
    echo "  --compartment-id <ocid>   Override compartment ID from variables.sh"
    echo "  --region <region>          Override region from variables.sh"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --labels         Show all labels for the node"
    echo "  --clique         Show GPU clique information, OCI tags, cluster state, and fabric details"
    echo "  --count-clique   Count and list all nodes in the same clique with OCI tags and fabric info"
    echo "  --all            Show everything (labels + clique + count + OCI tags + fabric)"
    echo ""
    echo -e "${BOLD}Clique Analysis:${NC}"
    echo "  --list-cliques   List all unique cliques with nodes grouped by GPU memory cluster and fabric"
    echo "                   Also shows fabrics without active clusters and instances not in K8s"
    echo "  --cliques-summary   Show summary table of all cliques with fabric info"
    echo "                      Also shows fabrics without active clusters and instances not in K8s"
    echo ""
    echo -e "${BOLD}GPU Cluster Search:${NC}"
    echo "  --list-cluster <gpu-cluster-id>"
    echo "    List all instances in a specific GPU memory cluster with fabric details"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                                                    # List all GPU instances with fabric info"
    echo "  $0 --compartment-id ocid1.compartment.oc1..xxx        # Use different compartment"
    echo "  $0 --region us-ashburn-1                              # Use different region"
    echo "  $0 --list-cliques                                     # List all cliques with fabric details"
    echo "  $0 --cliques-summary                                  # Summary table of cliques with fabric"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx                 # Basic node info"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --labels        # Show labels"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --clique        # Show clique info + fabric"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --count-clique  # Show clique members + fabric"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --all           # Show everything"
    echo "  $0 --list-cluster ocid1.xxx                           # List cluster instances + fabric"
    exit 0
fi

instance_id="$1"
show_labels="false"
show_clique="false"
count_clique="false"

# Parse options
shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --labels)
            show_labels="true"
            shift
            ;;
        --clique)
            show_clique="true"
            shift
            ;;
        --count-clique)
            count_clique="true"
            show_clique="true"  # Auto-enable clique display when counting
            shift
            ;;
        --all)
            show_labels="true"
            show_clique="true"
            count_clique="true"
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

get_node_info "$instance_id" "$show_labels" "$show_clique" "$count_clique"