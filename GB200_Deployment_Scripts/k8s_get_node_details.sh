#!/bin/bash
#
# k8s_get_nodes_details.sh - GPU Node Information Tool for OKE
#
# Description:
#   Lists GPU instances in OCI/Kubernetes with detailed information including
#   GPU memory clusters, fabrics, capacity topology, and announcements.
#
# Dependencies:
#   - oci CLI (configured)
#   - kubectl (configured)
#   - jq
#
# Usage:
#   ./k8s_get_nodes_details.sh [OPTIONS] [instance-ocid] [OPTIONS]
#   Run with --help for full usage information.
#

set -o pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Cache settings
readonly CACHE_MAX_AGE=3600  # 1 hour in seconds

# Script directory and cache paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/cache"

# Cache file paths
FABRIC_CACHE="$CACHE_DIR/gpu_fabrics.txt"
CLUSTER_CACHE="$CACHE_DIR/gpu_clusters.txt"
NODE_STATE_CACHE="$CACHE_DIR/node_states.txt"
CAPACITY_TOPOLOGY_CACHE="$CACHE_DIR/capacity_topology_hosts.txt"
ANNOUNCEMENTS_LIST_CACHE="$CACHE_DIR/announcements_list.json"

# Global associative arrays for lookups
declare -gA INSTANCE_ANNOUNCEMENTS
declare -gA GPU_MEM_CLUSTER_ANNOUNCEMENTS

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

# Print error message to stderr
log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Print warning message to stderr
log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

# Print info message to stderr
log_info() {
    echo "$1" >&2
}

# Check if cache file is fresh (less than CACHE_MAX_AGE seconds old)
# Args: $1 = cache file path
# Returns: 0 if fresh, 1 if stale or missing
is_cache_fresh() {
    local cache_file="$1"
    
    [[ ! -f "$cache_file" ]] && return 1
    
    local cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
    [[ $cache_age -lt $CACHE_MAX_AGE ]]
}

# Safely create a temp file and echo its path
create_temp_file() {
    mktemp
}

# Lookup value from pipe-delimited cache file
# Args: $1 = cache file, $2 = key, $3 = field number (1-indexed)
lookup_cache() {
    local cache_file="$1"
    local key="$2"
    local field="$3"
    
    [[ ! -f "$cache_file" ]] && echo "N/A" && return 1
    
    local value=$(grep "^${key}|" "$cache_file" | head -n1 | cut -d'|' -f"$field")
    echo "${value:-N/A}"
}

#===============================================================================
# CACHE FETCH FUNCTIONS
#===============================================================================

# Fetch and cache GPU memory fabrics from OCI
fetch_gpu_fabrics() {
    [[ -z "$TENANCY_ID" ]] && { log_warn "TENANCY_ID not set. GPU fabric details unavailable."; return 1; }
    
    is_cache_fresh "$FABRIC_CACHE" && return 0
    
    log_info "Fetching GPU memory fabrics from OCI..."
    
    local raw_json=$(create_temp_file)
    
    if ! oci compute compute-gpu-memory-fabric list \
            --compartment-id "$TENANCY_ID" \
            --all \
            --output json > "$raw_json" 2>/dev/null; then
        rm -f "$raw_json"
        return 1
    fi
    
    # Write cache header
    {
        echo "# GPU Memory Fabrics"
        echo "# Format: DisplayName|Last5Chars|FabricOCID|State|AvailableHosts|TotalHosts"
    } > "$FABRIC_CACHE"
    
    # Process fabrics using single jq call
    jq -r '.data.items[] | "\(.["display-name"])|\(.id[-5:] | ascii_downcase)|\(.id)|\(.["lifecycle-state"])|\(.["available-host-count"])|\(.["total-host-count"])"' \
        "$raw_json" >> "$FABRIC_CACHE" 2>/dev/null
    
    rm -f "$raw_json"
    return 0
}

# Fetch and cache GPU memory clusters from OCI
fetch_gpu_clusters() {
    [[ -z "$COMPARTMENT_ID" ]] && { log_warn "COMPARTMENT_ID not set. GPU cluster details unavailable."; return 1; }
    
    is_cache_fresh "$CLUSTER_CACHE" && return 0
    
    log_info "Fetching GPU memory clusters from OCI..."
    
    local raw_json=$(create_temp_file)
    
    if ! oci compute compute-gpu-memory-cluster list \
            --compartment-id "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}" \
            --all \
            --output json > "$raw_json" 2>/dev/null; then
        rm -f "$raw_json"
        return 1
    fi
    
    # Write cache header
    {
        echo "# GPU Memory Clusters"
        echo "# Format: ClusterOCID|DisplayName|State|FabricSuffix"
    } > "$CLUSTER_CACHE"
    
    # Process clusters - extract fabric suffix from display name
    jq -r '.data.items[] | 
        .["display-name"] as $name |
        ($name | capture("fabric-(?<suffix>[a-z0-9]{5})") // {suffix: ""}) as $match |
        "\(.id)|\($name)|\(.["lifecycle-state"])|\($match.suffix)"' \
        "$raw_json" >> "$CLUSTER_CACHE" 2>/dev/null
    
    rm -f "$raw_json"
    return 0
}

# Fetch and cache Kubernetes node states
fetch_node_states() {
    {
        echo "# Node States"
        echo "# Format: ProviderID|NodeState"
    } > "$NODE_STATE_CACHE"
    
    kubectl get nodes -o json 2>/dev/null | jq -r '
        .items[] | 
        "\(.spec.providerID)|\(
            .status.conditions[] | 
            select(.type=="Ready") | 
            if .status=="True" then "Ready" 
            elif .status=="False" then "NotReady" 
            else "Unknown" end
        )"' >> "$NODE_STATE_CACHE" 2>/dev/null || true
}

# Fetch and cache capacity topology bare metal hosts
fetch_capacity_topology() {
    [[ -z "$TENANCY_ID" ]] && { log_warn "TENANCY_ID not set. Capacity topology unavailable."; return 1; }
    
    is_cache_fresh "$CAPACITY_TOPOLOGY_CACHE" && return 0
    
    log_info "Fetching capacity topology from OCI..."
    
    local topologies_json=$(create_temp_file)
    
    if ! oci compute capacity-topology list \
            --compartment-id "$TENANCY_ID" \
            --all \
            --output json > "$topologies_json" 2>/dev/null; then
        rm -f "$topologies_json"
        return 1
    fi
    
    # Write cache header
    {
        echo "# Capacity Topology Hosts"
        echo "# Format: InstanceOCID|HostLifecycleState|HostLifecycleDetails|TopologyOCID"
    } > "$CAPACITY_TOPOLOGY_CACHE"
    
    # Get topology IDs and fetch bare metal hosts for each
    local topology_ids=$(jq -r '.data.items[]?.id // empty' "$topologies_json" 2>/dev/null)
    
    for topo_id in $topology_ids; do
        [[ -z "$topo_id" ]] && continue
        
        local hosts_json=$(create_temp_file)
        
        if oci compute capacity-topology bare-metal-host list \
                --capacity-topology-id "$topo_id" \
                --all \
                --output json > "$hosts_json" 2>/dev/null; then
            
            jq -r --arg topo "$topo_id" '
                .data.items[]? | 
                "\(.["instance-id"] // "N/A")|\(.["lifecycle-state"] // "N/A")|\(.["lifecycle-details"] // "N/A")|\($topo)"
            ' "$hosts_json" >> "$CAPACITY_TOPOLOGY_CACHE" 2>/dev/null
        fi
        
        rm -f "$hosts_json"
    done
    
    rm -f "$topologies_json"
    return 0
}

# Build announcement lookup tables from cached data
build_announcement_lookup() {
    local compartment_id="$1"
    
    # Reset arrays
    INSTANCE_ANNOUNCEMENTS=()
    GPU_MEM_CLUSTER_ANNOUNCEMENTS=()
    
    # Refresh cache if needed
    if ! is_cache_fresh "$ANNOUNCEMENTS_LIST_CACHE"; then
        oci announce announcements list \
            --compartment-id "$compartment_id" \
            --all > "$ANNOUNCEMENTS_LIST_CACHE" 2>/dev/null || return 1
        
        # Fetch details for each announcement in parallel
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
        
        # Validate and check if ACTIVE
        jq -e '.data.id' "$detail_file" > /dev/null 2>&1 || continue
        
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
            
            # Add to instance lookup (avoid duplicates)
            if [[ -n "$resource_id" && "$resource_id" != "null" ]]; then
                if [[ -z "${INSTANCE_ANNOUNCEMENTS[$resource_id]}" ]]; then
                    INSTANCE_ANNOUNCEMENTS[$resource_id]="$short_ticket"
                elif [[ ! "${INSTANCE_ANNOUNCEMENTS[$resource_id]}" =~ "$short_ticket" ]]; then
                    INSTANCE_ANNOUNCEMENTS[$resource_id]="${INSTANCE_ANNOUNCEMENTS[$resource_id]},$short_ticket"
                fi
            fi
            
            # Add to GPU memory cluster lookup (avoid duplicates)
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

#===============================================================================
# LOOKUP FUNCTIONS
#===============================================================================

# Get cluster state from cache
get_cluster_state() {
    lookup_cache "$CLUSTER_CACHE" "$1" 3
}

# Get node state from cache
get_node_state_cached() {
    lookup_cache "$NODE_STATE_CACHE" "$1" 2
}

# Get capacity topology state for an instance
get_capacity_topology_state() {
    lookup_cache "$CAPACITY_TOPOLOGY_CACHE" "$1" 3
}

# Get fabric details from cluster OCID
# Returns: DisplayName|Last5Chars|FabricOCID|State|AvailableHosts|TotalHosts
get_fabric_from_cluster() {
    local cluster_ocid="$1"
    local default="N/A|N/A|N/A|N/A|0|0"
    
    [[ ! -f "$FABRIC_CACHE" || ! -f "$CLUSTER_CACHE" ]] && { echo "$default"; return 1; }
    
    local fabric_suffix=$(grep "^${cluster_ocid}|" "$CLUSTER_CACHE" | cut -d'|' -f4)
    [[ -z "$fabric_suffix" ]] && { echo "$default"; return 1; }
    
    local fabric_line=$(grep -v '^#' "$FABRIC_CACHE" | grep "|$fabric_suffix|" | head -n1)
    echo "${fabric_line:-$default}"
}

# Get announcements for a resource (instance and/or GPU memory cluster)
get_resource_announcements() {
    local instance_ocid="$1"
    local gpu_mem_cluster="$2"
    local result=""
    
    # Check instance-level announcements
    if [[ -n "$instance_ocid" && -n "${INSTANCE_ANNOUNCEMENTS[$instance_ocid]}" ]]; then
        result="${INSTANCE_ANNOUNCEMENTS[$instance_ocid]}"
    fi
    
    # Check GPU memory cluster level announcements
    if [[ -n "$gpu_mem_cluster" && "$gpu_mem_cluster" != "N/A" && -n "${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]}" ]]; then
        if [[ -z "$result" ]]; then
            result="${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]}"
        else
            # Append unique tickets
            for ticket in ${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]//,/ }; do
                [[ ! "$result" =~ "$ticket" ]] && result="${result},${ticket}"
            done
        fi
    fi
    
    echo "${result:--}"
}

#===============================================================================
# COLOR HELPER FUNCTIONS
#===============================================================================

# Get color for node state
color_node_state() {
    [[ "$1" == "Ready" ]] && echo "$GREEN" || echo "$RED"
}

# Get color for OCI instance state
color_oci_state() {
    [[ "$1" == "RUNNING" ]] && echo "$GREEN" || echo "$YELLOW"
}

# Get color for capacity topology state
color_cap_topo_state() {
    case "$1" in
        AVAILABLE) echo "$GREEN" ;;
        N/A)       echo "$YELLOW" ;;
        *)         echo "$RED" ;;
    esac
}

# Get color for announcement status
color_announcement() {
    [[ "$1" == "-" ]] && echo "$GREEN" || echo "$RED"
}

#===============================================================================
# DISPLAY FUNCTIONS
#===============================================================================

# List fabrics without active clusters
list_fabrics_without_clusters() {
    echo -e "${BOLD}${MAGENTA}=== GPU Memory Fabrics Without Active Clusters ===${NC}"
    echo ""
    
    [[ ! -f "$FABRIC_CACHE" || ! -f "$CLUSTER_CACHE" ]] && { echo -e "${YELLOW}Cache files not available${NC}"; return 1; }
    
    local all_fabric_suffixes=$(grep -v '^#' "$FABRIC_CACHE" | cut -d'|' -f2)
    local used_fabric_suffixes=$(grep -v '^#' "$CLUSTER_CACHE" | grep "|ACTIVE|" | cut -d'|' -f4 | sort -u)
    
    local found_unused=false
    local temp_output=$(create_temp_file)
    
    while read -r fabric_suffix; do
        if ! echo "$used_fabric_suffixes" | grep -q "^${fabric_suffix}$"; then
            found_unused=true
            local fabric_line=$(grep -v '^#' "$FABRIC_CACHE" | grep "|$fabric_suffix|" | head -n1)
            
            if [[ -n "$fabric_line" ]]; then
                IFS='|' read -r fabric_name _ fabric_ocid fabric_state avail_hosts total_hosts <<< "$fabric_line"
                echo "${fabric_name}|${fabric_ocid}|${fabric_state}|${avail_hosts}/${total_hosts}" >> "$temp_output"
            fi
        fi
    done <<< "$all_fabric_suffixes"
    
    if [[ "$found_unused" == "true" ]]; then
        # Print header
        printf "${BOLD}%-40s %-105s %-13s %-15s${NC}\n" \
            "Fabric Display Name" "GPU Memory Fabric OCID" "State" "Hosts"
        echo -e "${BLUE}$(printf '━%.0s' {1..170})${NC}"
        # Print data rows
        while IFS='|' read -r fabric_name fabric_ocid fabric_state hosts; do
            local state_color="$RED"
            [[ "$fabric_state" == "AVAILABLE" ]] && state_color="$GREEN"
            printf "${CYAN}%-40s${NC} ${WHITE}%-105s${NC} ${state_color}%-13s${NC} ${YELLOW}%-15s${NC}\n" \
                "$fabric_name" "$fabric_ocid" "$fabric_state" "$hosts"
        done < "$temp_output"
    else
        echo -e "${GREEN}All fabrics have active clusters${NC}"
    fi
    
    rm -f "$temp_output"
}

# List instances not in Kubernetes
list_instances_not_in_k8s() {
    local oci_temp="$1"
    local k8s_temp="$2"
    
    echo -e "${BOLD}${MAGENTA}=== GPU Instances Not in Kubernetes ===${NC}"
    echo ""
    
    local found_orphan=false
    
    while IFS='|' read -r display_name status instance_ocid gpu_mem; do
        [[ -z "$instance_ocid" ]] && continue
        
        if ! grep -q "^${instance_ocid}|" "$k8s_temp" 2>/dev/null; then
            if [[ "$status" == "RUNNING" ]]; then
                found_orphan=true
                echo -e "${CYAN}Display Name:${NC} $display_name"
                echo -e "  ${YELLOW}Instance OCID:${NC} $instance_ocid"
                echo -e "  ${YELLOW}OCI State:${NC} ${GREEN}${status}${NC}"
                
                if [[ "$gpu_mem" != "N/A" ]]; then
                    local gpu_mem_short="${gpu_mem: -12}"
                    echo -e "  ${YELLOW}GPU Mem Cluster:${NC} $gpu_mem_short"
                fi
                echo ""
            fi
        fi
    done < "$oci_temp"
    
    if [[ "$found_orphan" == "false" ]]; then
        echo -e "${GREEN}All running GPU instances are in Kubernetes${NC}"
    fi
}

#===============================================================================
# MAIN LIST FUNCTIONS
#===============================================================================

# List all GPU instances in compartment
list_all_instances() {
    local compartment_id="$1"
    local region="$2"
    
    # Validate required parameters
    [[ -z "$compartment_id" ]] && { log_error "COMPARTMENT_ID not set in variables.sh"; return 1; }
    [[ -z "$region" ]] && { log_error "REGION not set in variables.sh"; return 1; }
    
    # Fetch all cached data
    fetch_gpu_fabrics
    fetch_gpu_clusters
    
    echo -e "${BOLD}${MAGENTA}=== All GPU Instances in Compartment ===${NC}"
    echo -e "${CYAN}Compartment:${NC} $compartment_id"
    echo -e "${CYAN}Region:${NC} $region"
    echo ""
    
    # Create temp files
    local oci_temp=$(create_temp_file)
    local k8s_temp=$(create_temp_file)
    local output_temp=$(create_temp_file)
    
    # Fetch OCI instances
    log_info "Fetching instances from OCI..."
    oci compute instance list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json | jq -r '
            .data[] | 
            select(.shape | contains("GPU")) | 
            "\(.["display-name"])|\(.["lifecycle-state"])|\(.id)|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")"
        ' > "$oci_temp"
    
    # Fetch K8s GPU nodes
    log_info "Fetching GPU nodes from Kubernetes..."
    kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq -r '
        .items[] | 
        "\(.spec.providerID)|\(.metadata.name)|\(.metadata.labels["nvidia.com/gpu.clique"] // "N/A")"
    ' > "$k8s_temp"
    
    # Fetch additional data
    log_info "Fetching node states..."
    fetch_node_states
    
    log_info "Fetching announcements..."
    build_announcement_lookup "$compartment_id"
    
    log_info "Fetching capacity topology..."
    fetch_capacity_topology
    
    echo "Processing data..."
    echo ""
    
    # Print table header
    printf "${BOLD}%-28s %-15s %-11s %-10s %-95s %-12s %-12s %-40s %-10s %-18s${NC}\n" \
        "Display Name" "K8s Node" "Node State" "OCI State" "Instance OCID" "GPU Cluster" "Cluster St" "Clique ID" "CapTopo" "Announce"
    echo -e "${BLUE}$(printf '━%.0s' {1..280})${NC}"
    
    # Process and collect data for sorting
    while IFS='|' read -r display_name status instance_ocid gpu_mem; do
        local k8s_info=$(grep "^${instance_ocid}|" "$k8s_temp")
        [[ -z "$k8s_info" ]] && continue
        
        IFS='|' read -r _ node_name clique_id <<< "$k8s_info"
        
        # Get various states
        local node_state=$(get_node_state_cached "$instance_ocid")
        local cluster_state="N/A"
        [[ "$gpu_mem" != "N/A" ]] && cluster_state=$(get_cluster_state "$gpu_mem")
        local cap_topo_state=$(get_capacity_topology_state "$instance_ocid")
        local announcements=$(get_resource_announcements "$instance_ocid" "$gpu_mem")
        
        # Truncate for display
        local gpu_mem_display="$gpu_mem"
        [[ "$gpu_mem" != "N/A" && ${#gpu_mem} -gt 12 ]] && gpu_mem_display="${gpu_mem: -12}"
        
        local cluster_state_display="$cluster_state"
        [[ ${#cluster_state} -gt 12 ]] && cluster_state_display="${cluster_state:0:9}..."
        
        # Store for sorting (by GPU mem cluster, then display name)
        echo "${gpu_mem}|${display_name}|${node_name}|${node_state}|${status}|${instance_ocid}|${gpu_mem_display}|${cluster_state_display}|${clique_id}|${cap_topo_state}|${announcements}" >> "$output_temp"
    done < "$oci_temp"
    
    # Sort and display
    sort -t'|' -k1,1 -k2,2 "$output_temp" | while IFS='|' read -r _ dn nn ns st io gm cs cd ct ann; do
        local ns_color=$(color_node_state "$ns")
        local st_color=$(color_oci_state "$st")
        local ct_color=$(color_cap_topo_state "$ct")
        local ann_color=$(color_announcement "$ann")
        
        printf "%-28s %-15s ${ns_color}%-11s${NC} ${st_color}%-10s${NC} %-95s %-12s %-12s %-40s ${ct_color}%-10s${NC} ${ann_color}%-18s${NC}\n" \
            "$dn" "$nn" "$ns" "$st" "$io" "$gm" "$cs" "$cd" "$ct" "$ann"
    done
    
    echo ""
    
    # Show summary and additional info
    display_clique_summary "$oci_temp" "$k8s_temp"
    
    echo ""
    list_fabrics_without_clusters
    
    echo ""
    list_instances_not_in_k8s "$oci_temp" "$k8s_temp"
    
    # Cleanup
    rm -f "$oci_temp" "$k8s_temp" "$output_temp"
}

# Display summary by clique
display_clique_summary() {
    local oci_temp="$1"
    local k8s_temp="$2"
    
    local joined_temp=$(create_temp_file)
    
    # Join OCI and K8s data
    while IFS='|' read -r display_name status instance_ocid gpu_mem; do
        local k8s_info=$(grep "^${instance_ocid}|" "$k8s_temp")
        if [[ -n "$k8s_info" ]]; then
            IFS='|' read -r _ node_name clique_id <<< "$k8s_info"
            echo "${display_name}|${node_name}|${status}|${instance_ocid}|${gpu_mem}|${clique_id}" >> "$joined_temp"
        fi
    done < "$oci_temp"
    
    local unique_cliques=$(awk -F'|' '{print $6}' "$joined_temp" | sort -u)
    
    echo -e "${BOLD}${BLUE}=== Summary by GPU Clique ===${NC}"
    echo ""
    
    local summary_temp=$(create_temp_file)
    
    while read -r clique; do
        [[ -z "$clique" ]] && continue
        
        local clique_display="$clique"
        [[ "$clique" == "N/A" ]] && clique_display="N/A (No GPU or not in cluster)"
        
        local clique_size=$(grep -c "|${clique}\$" "$joined_temp")
        local clique_entries=$(grep "|${clique}\$" "$joined_temp")
        
        # Get unique GPU memory clusters for this clique
        declare -A gpu_clusters_count
        declare -A gpu_clusters_fabrics
        declare -A gpu_clusters_states
        
        while IFS='|' read -r _ _ _ instance_ocid gpu_mem _; do
            if [[ -n "$gpu_mem" && -z "${gpu_clusters_count[$gpu_mem]}" ]]; then
                gpu_clusters_count[$gpu_mem]=1
                if [[ "$gpu_mem" != "N/A" ]]; then
                    gpu_clusters_fabrics[$gpu_mem]=$(get_fabric_from_cluster "$gpu_mem")
                    gpu_clusters_states[$gpu_mem]=$(get_cluster_state "$gpu_mem")
                fi
            elif [[ -n "$gpu_mem" ]]; then
                ((gpu_clusters_count[$gpu_mem]++))
            fi
        done <<< "$clique_entries"
        
        # Get first cluster info for summary
        local first_gpu_mem=$(echo "${!gpu_clusters_count[@]}" | tr ' ' '\n' | sort | head -n1)
        local fabric_name="N/A"
        local fabric_ocid="N/A"
        local cluster_state="N/A"
        
        if [[ -n "$first_gpu_mem" && "$first_gpu_mem" != "N/A" ]]; then
            IFS='|' read -r fabric_name _ fabric_ocid _ _ _ <<< "${gpu_clusters_fabrics[$first_gpu_mem]}"
            cluster_state="${gpu_clusters_states[$first_gpu_mem]}"
        fi
        
        echo "${clique_display}|${clique_size}|${#gpu_clusters_count[@]}|${first_gpu_mem}|${cluster_state}|${fabric_name}|${fabric_ocid}" >> "$summary_temp"
        
        unset gpu_clusters_count gpu_clusters_fabrics gpu_clusters_states
    done <<< "$unique_cliques"
    
    # Print summary table
    printf "${BOLD}%-48s %-7s %-4s %-106s %-18s${NC}\n" \
        "Clique ID" "Nodes" "#Cl" "GPU Memory Cluster" "State"
    echo -e "${BLUE}$(printf '━%.0s' {1..200})${NC}"
    
    while IFS='|' read -r clique_id nodes clusters gpu_mem_cluster cluster_state fabric_name fabric_ocid; do
        printf "${CYAN}%-48s${NC} ${GREEN}%-7s${NC} ${YELLOW}%-4s${NC} ${MAGENTA}%-95s${NC} ${WHITE}%-12s${NC}\n" \
            "$clique_id" "$nodes" "$clusters" "$gpu_mem_cluster" "$cluster_state"
        
        if [[ "$fabric_name" != "N/A" && "$fabric_ocid" != "N/A" ]]; then
            printf "          ${BOLD}${MAGENTA}└─ Fabric:${NC} ${WHITE}%-40s${NC} ${CYAN}%s${NC}\n" \
                "$fabric_name" "$fabric_ocid"
        fi
        echo ""
    done < "$summary_temp"
    
    rm -f "$joined_temp" "$summary_temp"
}

# List all unique cliques with details
list_all_cliques() {
    echo -e "${BOLD}${MAGENTA}=== All GPU Cliques in Kubernetes Cluster ===${NC}"
    echo ""
    
    local cliques=$(kubectl get nodes -o json | jq -r '.items[].metadata.labels["nvidia.com/gpu.clique"]' | grep -v null | sort -u)
    
    [[ -z "$cliques" ]] && { echo -e "${YELLOW}No GPU cliques found in the cluster${NC}"; return 0; }
    
    local total_cliques=$(echo "$cliques" | wc -l)
    echo -e "${BOLD}${CYAN}Total Cliques Found:${NC} $total_cliques"
    echo ""
    
    # Fetch cached data
    local oci_data=$(create_temp_file)
    
    log_info "Fetching all instance details from OCI..."
    oci compute instance list \
        --compartment-id "$COMPARTMENT_ID" \
        --region "$REGION" \
        --all \
        --output json | jq -r '.data[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")"' > "$oci_data"
    
    while read -r clique_id; do
        [[ -z "$clique_id" ]] && continue
        
        echo -e "${BOLD}${BLUE}$(printf '━%.0s' {1..50})${NC}"
        echo -e "${BOLD}${YELLOW}Clique ID:${NC} $clique_id"
        
        local node_count=$(kubectl get nodes -o json | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
        echo -e "${BOLD}${CYAN}Node Count:${NC} $node_count"
        echo ""
        
        # Get nodes grouped by GPU memory cluster
        declare -A cluster_nodes
        local clique_data=$(kubectl get nodes -o json | jq -r --arg clique "$clique_id" '
            .items[] | 
            select(.metadata.labels["nvidia.com/gpu.clique"]==$clique) | 
            "\(.metadata.name)|\(.spec.providerID)"
        ')
        
        while IFS='|' read -r node ocid; do
            local gpu_mem_cluster=$(grep "^${ocid}|" "$oci_data" | cut -d'|' -f4)
            gpu_mem_cluster=${gpu_mem_cluster:-N/A}
            
            if [[ -z "${cluster_nodes[$gpu_mem_cluster]}" ]]; then
                cluster_nodes[$gpu_mem_cluster]="$node|$ocid"
            else
                cluster_nodes[$gpu_mem_cluster]="${cluster_nodes[$gpu_mem_cluster]}"$'\n'"$node|$ocid"
            fi
        done <<< "$clique_data"
        
        # Display grouped by GPU memory cluster
        for mem_cluster in $(echo "${!cluster_nodes[@]}" | tr ' ' '\n' | sort); do
            local cluster_node_count=$(echo "${cluster_nodes[$mem_cluster]}" | wc -l)
            echo -e "${BOLD}${GREEN}  GPU Mem Cluster: $mem_cluster${NC} ${CYAN}(Nodes: $cluster_node_count)${NC}"
            
            while IFS='|' read -r node ocid; do
                echo -e "    ${WHITE}$node${NC} - ${YELLOW}$ocid${NC}"
            done <<< "${cluster_nodes[$mem_cluster]}"
            echo ""
        done
        
        unset cluster_nodes
    done <<< "$cliques"
    
    rm -f "$oci_data"
    echo -e "${BOLD}${BLUE}$(printf '━%.0s' {1..50})${NC}"
}

# List cliques summary
list_cliques_summary() {
    echo -e "${BOLD}${MAGENTA}=== GPU Cliques Summary ===${NC}"
    echo ""
    
    local cliques=$(kubectl get nodes -o json | jq -r '.items[].metadata.labels["nvidia.com/gpu.clique"]' | grep -v null | sort -u)
    
    [[ -z "$cliques" ]] && { echo -e "${YELLOW}No GPU cliques found in the cluster${NC}"; return 0; }
    
    local oci_data=$(create_temp_file)
    
    log_info "Fetching all instance details from OCI..."
    oci compute instance list \
        --compartment-id "$COMPARTMENT_ID" \
        --region "$REGION" \
        --all \
        --output json | jq -r '.data[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")"' > "$oci_data"
    
    echo ""
    printf "${BOLD}%-40s %-15s %-20s${NC}\n" "Clique ID" "Total Nodes" "Memory Clusters"
    echo -e "${BLUE}$(printf '━%.0s' {1..75})${NC}"
    
    while read -r clique_id; do
        [[ -z "$clique_id" ]] && continue
        
        local node_count=$(kubectl get nodes -o json | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
        
        local clique_data=$(kubectl get nodes -o json | jq -r --arg clique "$clique_id" '
            .items[] | 
            select(.metadata.labels["nvidia.com/gpu.clique"]==$clique) | 
            .spec.providerID
        ')
        
        declare -A mem_clusters
        while read -r ocid; do
            [[ -z "$ocid" ]] && continue
            local gpu_mem_cluster=$(grep "^${ocid}|" "$oci_data" | cut -d'|' -f4)
            gpu_mem_cluster=${gpu_mem_cluster:-N/A}
            mem_clusters[$gpu_mem_cluster]=1
        done <<< "$clique_data"
        
        local cluster_list=$(echo "${!mem_clusters[@]}" | tr ' ' '\n' | sort | tr '\n' ',' | sed 's/,$//')
        
        printf "${CYAN}%-40s${NC} ${GREEN}%-15s${NC} ${YELLOW}%-20s${NC}\n" "$clique_id" "$node_count" "$cluster_list"
        
        unset mem_clusters
    done <<< "$cliques"
    
    rm -f "$oci_data"
}

# Get node info for a specific instance
get_node_info() {
    local instance_id="$1"
    local show_labels="$2"
    local show_clique="$3"
    local count_clique="$4"
    
    # Fetch all required cache data upfront
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_node_states
    fetch_capacity_topology
    build_announcement_lookup "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    
    # Get Kubernetes node info
    local provider_id="${instance_id}"
    local node_json=$(kubectl get nodes -o json 2>/dev/null)
    local node_name=$(echo "$node_json" | jq -r --arg id "$provider_id" '.items[] | select(.spec.providerID==$id) | .metadata.name')
    
    [[ -z "$node_name" ]] && { log_error "Could not find Kubernetes node for instance OCID: $instance_id"; return 1; }
    
    # Get OCI instance details
    log_info "Fetching OCI instance details..."
    local oci_instance_json=$(oci compute instance get --instance-id "$instance_id" --output json 2>/dev/null)
    
    local display_name=$(echo "$oci_instance_json" | jq -r '.data["display-name"] // "N/A"')
    local oci_state=$(echo "$oci_instance_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    local shape=$(echo "$oci_instance_json" | jq -r '.data.shape // "N/A"')
    local ad=$(echo "$oci_instance_json" | jq -r '.data["availability-domain"] // "N/A"')
    local fault_domain=$(echo "$oci_instance_json" | jq -r '.data["fault-domain"] // "N/A"')
    local gpu_memory_cluster=$(echo "$oci_instance_json" | jq -r '.data["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A"')
    local time_created=$(echo "$oci_instance_json" | jq -r '.data["time-created"] // "N/A"')
    
    # Get Kubernetes node details
    local node_data=$(echo "$node_json" | jq --arg name "$node_name" '.items[] | select(.metadata.name==$name)')
    local node_state=$(get_node_state_cached "$instance_id")
    local clique_id=$(echo "$node_data" | jq -r '.metadata.labels["nvidia.com/gpu.clique"] // "N/A"')
    local gpu_count=$(echo "$node_data" | jq -r '.status.capacity["nvidia.com/gpu"] // "N/A"')
    local gpu_product=$(echo "$node_data" | jq -r '.metadata.labels["nvidia.com/gpu.product"] // "N/A"')
    local gpu_memory=$(echo "$node_data" | jq -r '.metadata.labels["nvidia.com/gpu.memory"] // "N/A"')
    local kubelet_version=$(echo "$node_data" | jq -r '.status.nodeInfo.kubeletVersion // "N/A"')
    local os_image=$(echo "$node_data" | jq -r '.status.nodeInfo.osImage // "N/A"')
    local kernel_version=$(echo "$node_data" | jq -r '.status.nodeInfo.kernelVersion // "N/A"')
    local container_runtime=$(echo "$node_data" | jq -r '.status.nodeInfo.containerRuntimeVersion // "N/A"')
    
    # Get capacity topology state
    local cap_topo_state=$(get_capacity_topology_state "$instance_id")
    
    # Get announcements
    local announcements=$(get_resource_announcements "$instance_id" "$gpu_memory_cluster")
    
    # Get GPU memory cluster and fabric details
    local cluster_state="N/A"
    local fabric_name="N/A"
    local fabric_ocid="N/A"
    local fabric_state="N/A"
    local fabric_avail_hosts="N/A"
    local fabric_total_hosts="N/A"
    
    if [[ "$gpu_memory_cluster" != "N/A" && "$gpu_memory_cluster" != "null" ]]; then
        cluster_state=$(get_cluster_state "$gpu_memory_cluster")
        local fabric_info=$(get_fabric_from_cluster "$gpu_memory_cluster")
        IFS='|' read -r fabric_name _ fabric_ocid fabric_state fabric_avail_hosts fabric_total_hosts <<< "$fabric_info"
    fi
    
    # Get clique size
    local clique_size="N/A"
    if [[ "$clique_id" != "N/A" && "$clique_id" != "null" ]]; then
        clique_size=$(echo "$node_json" | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
    fi
    
    echo ""
    
    #---------------------------------------------------------------------------
    # Section: Instance Overview
    #---------------------------------------------------------------------------
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║                           INSTANCE DETAILS                                   ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${BOLD}${CYAN}=== OCI Instance ===${NC}"
    echo -e "  ${WHITE}Display Name:${NC}      $display_name"
    echo -e "  ${WHITE}Instance OCID:${NC}     ${YELLOW}$instance_id${NC}"
    echo -e "  ${WHITE}Shape:${NC}             $shape"
    echo -e "  ${WHITE}Availability Domain:${NC} $ad"
    echo -e "  ${WHITE}Fault Domain:${NC}      $fault_domain"
    echo -e "  ${WHITE}Created:${NC}           $time_created"
    
    local oci_state_color=$(color_oci_state "$oci_state")
    echo -e "  ${WHITE}OCI State:${NC}         ${oci_state_color}${oci_state}${NC}"
    echo ""
    
    #---------------------------------------------------------------------------
    # Section: Kubernetes Node
    #---------------------------------------------------------------------------
    echo -e "${BOLD}${CYAN}=== Kubernetes Node ===${NC}"
    echo -e "  ${WHITE}Node Name:${NC}         ${GREEN}$node_name${NC}"
    
    local node_state_color=$(color_node_state "$node_state")
    echo -e "  ${WHITE}Node State:${NC}        ${node_state_color}${node_state}${NC}"
    
    echo -e "  ${WHITE}Kubelet Version:${NC}   $kubelet_version"
    echo -e "  ${WHITE}OS Image:${NC}          $os_image"
    echo -e "  ${WHITE}Kernel:${NC}            $kernel_version"
    echo -e "  ${WHITE}Container Runtime:${NC} $container_runtime"
    echo ""
    
    #---------------------------------------------------------------------------
    # Section: GPU Information
    #---------------------------------------------------------------------------
    echo -e "${BOLD}${CYAN}=== GPU Information ===${NC}"
    echo -e "  ${WHITE}GPU Count:${NC}         $gpu_count"
    echo -e "  ${WHITE}GPU Product:${NC}       $gpu_product"
    echo -e "  ${WHITE}GPU Memory:${NC}        $gpu_memory MB"
    echo -e "  ${WHITE}GPU Clique ID:${NC}     ${YELLOW}$clique_id${NC}"
    echo -e "  ${WHITE}Clique Size:${NC}       $clique_size nodes"
    echo ""
    
    #---------------------------------------------------------------------------
    # Section: GPU Memory Cluster
    #---------------------------------------------------------------------------
    echo -e "${BOLD}${CYAN}=== GPU Memory Cluster ===${NC}"
    if [[ "$gpu_memory_cluster" != "N/A" && "$gpu_memory_cluster" != "null" ]]; then
        echo -e "  ${WHITE}Cluster OCID:${NC}      ${YELLOW}$gpu_memory_cluster${NC}"
        
        local cluster_state_color="$GREEN"
        [[ "$cluster_state" != "ACTIVE" ]] && cluster_state_color="$RED"
        echo -e "  ${WHITE}Cluster State:${NC}     ${cluster_state_color}${cluster_state}${NC}"
    else
        echo -e "  ${YELLOW}No GPU Memory Cluster assigned${NC}"
    fi
    echo ""
    
    #---------------------------------------------------------------------------
    # Section: GPU Memory Fabric
    #---------------------------------------------------------------------------
    echo -e "${BOLD}${CYAN}=== GPU Memory Fabric ===${NC}"
    if [[ "$fabric_name" != "N/A" ]]; then
        echo -e "  ${WHITE}Fabric Name:${NC}       $fabric_name"
        echo -e "  ${WHITE}Fabric OCID:${NC}       ${YELLOW}$fabric_ocid${NC}"
        
        local fabric_state_color="$GREEN"
        [[ "$fabric_state" != "AVAILABLE" ]] && fabric_state_color="$RED"
        echo -e "  ${WHITE}Fabric State:${NC}      ${fabric_state_color}${fabric_state}${NC}"
        
        echo -e "  ${WHITE}Host Capacity:${NC}     ${fabric_avail_hosts}/${fabric_total_hosts} available"
    else
        echo -e "  ${YELLOW}No GPU Memory Fabric information available${NC}"
    fi
    echo ""
    
    #---------------------------------------------------------------------------
    # Section: Capacity Topology
    #---------------------------------------------------------------------------
    echo -e "${BOLD}${CYAN}=== Capacity Topology ===${NC}"
    local cap_topo_color=$(color_cap_topo_state "$cap_topo_state")
    echo -e "  ${WHITE}Host Status:${NC}       ${cap_topo_color}${cap_topo_state}${NC}"
    echo ""
    
    #---------------------------------------------------------------------------
    # Section: Announcements
    #---------------------------------------------------------------------------
    echo -e "${BOLD}${CYAN}=== Announcements ===${NC}"
    if [[ "$announcements" != "-" ]]; then
        echo -e "  ${WHITE}Active Tickets:${NC}    ${RED}${announcements}${NC}"
        
        # Show details for each announcement
        for ticket in ${announcements//,/ }; do
            # Find the announcement file
            for detail_file in "$CACHE_DIR"/*.json; do
                [[ ! -f "$detail_file" ]] && continue
                [[ "$detail_file" == *"/announcements_list.json" ]] && continue
                [[ "$detail_file" == *"/ack_status_cache.json" ]] && continue
                
                local ref_ticket=$(jq -r '.data."reference-ticket-number" // ""' "$detail_file" 2>/dev/null)
                if [[ "${ref_ticket:0:8}" == "$ticket" ]]; then
                    local ann_summary=$(jq -r '.data.summary // "N/A"' "$detail_file")
                    local ann_type=$(jq -r '.data."announcement-type" // "N/A"' "$detail_file")
                    local ann_time=$(jq -r '.data."time-one-value" // "N/A"' "$detail_file")
                    echo ""
                    echo -e "  ${YELLOW}Ticket: ${ticket}${NC}"
                    echo -e "    ${WHITE}Type:${NC}    $ann_type"
                    echo -e "    ${WHITE}Summary:${NC} $ann_summary"
                    echo -e "    ${WHITE}Time:${NC}    $ann_time"
                    break
                fi
            done
        done
    else
        echo -e "  ${GREEN}No active announcements${NC}"
    fi
    echo ""
    
    #---------------------------------------------------------------------------
    # Optional: Show Labels
    #---------------------------------------------------------------------------
    if [[ "$show_labels" == "true" ]]; then
        echo -e "${BOLD}${CYAN}=== All Kubernetes Labels ===${NC}"
        echo "$node_data" | jq -r '.metadata.labels | to_entries | sort_by(.key) | .[] | "  \(.key): \(.value)"'
        echo ""
        
        echo -e "${BOLD}${CYAN}=== GPU Labels Only ===${NC}"
        echo "$node_data" | jq -r '.metadata.labels | to_entries | map(select(.key | contains("nvidia.com/gpu"))) | sort_by(.key) | .[] | "  \(.key): \(.value)"'
        echo ""
    fi
    
    #---------------------------------------------------------------------------
    # Optional: Count Clique Members
    #---------------------------------------------------------------------------
    if [[ "$count_clique" == "true" && "$clique_id" != "N/A" && "$clique_id" != "null" ]]; then
        echo -e "${BOLD}${CYAN}=== Nodes in Same Clique (${clique_id}) ===${NC}"
        echo ""
        
        # Get all nodes in this clique
        local clique_nodes=$(echo "$node_json" | jq -r --arg clique "$clique_id" '
            .items[] | 
            select(.metadata.labels["nvidia.com/gpu.clique"]==$clique) | 
            "\(.metadata.name)|\(.spec.providerID)"
        ')
        
        # Get OCI data for GPU memory cluster grouping
        local oci_data=$(create_temp_file)
        oci compute instance list \
            --compartment-id "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}" \
            --region "${EFFECTIVE_REGION:-$REGION}" \
            --all \
            --output json | jq -r '.data[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")"' > "$oci_data"
        
        # Group by GPU memory cluster
        declare -A cluster_nodes
        while IFS='|' read -r node ocid; do
            local mem_cluster=$(grep "^${ocid}|" "$oci_data" | cut -d'|' -f4)
            mem_cluster=${mem_cluster:-N/A}
            
            if [[ -z "${cluster_nodes[$mem_cluster]}" ]]; then
                cluster_nodes[$mem_cluster]="$node|$ocid"
            else
                cluster_nodes[$mem_cluster]="${cluster_nodes[$mem_cluster]}"$'\n'"$node|$ocid"
            fi
        done <<< "$clique_nodes"
        
        # Display grouped by GPU memory cluster
        for mem_cluster in $(echo "${!cluster_nodes[@]}" | tr ' ' '\n' | sort); do
            local cluster_node_count=$(echo "${cluster_nodes[$mem_cluster]}" | wc -l)
            local short_cluster="${mem_cluster: -12}"
            [[ "$mem_cluster" == "N/A" ]] && short_cluster="N/A"
            
            echo -e "  ${BOLD}${BLUE}GPU Memory Cluster: ${short_cluster}${NC} (${cluster_node_count} nodes)"
            
            while IFS='|' read -r node ocid; do
                local is_current=""
                [[ "$ocid" == "$instance_id" ]] && is_current=" ${MAGENTA}← current${NC}"
                echo -e "    ${GREEN}$node${NC} - ${YELLOW}$ocid${NC}${is_current}"
            done <<< "${cluster_nodes[$mem_cluster]}"
            echo ""
        done
        
        unset cluster_nodes
        rm -f "$oci_data"
    fi
    
    return 0
}

# List instances by GPU cluster
list_instances_by_gpu_cluster() {
    local gpu_cluster="$1"
    local compartment_id="$2"
    local region="$3"
    
    [[ -z "$gpu_cluster" ]] && { log_error "GPU cluster ID required"; return 1; }
    [[ -z "$compartment_id" ]] && { log_error "COMPARTMENT_ID not set in variables.sh"; return 1; }
    [[ -z "$region" ]] && { log_error "REGION not set in variables.sh"; return 1; }
    
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_node_states
    fetch_capacity_topology
    build_announcement_lookup "$compartment_id"
    
    echo -e "${BOLD}${MAGENTA}=== Instances in GPU Memory Cluster ===${NC}"
    echo -e "${CYAN}GPU Memory Cluster:${NC} $gpu_cluster"
    echo -e "${CYAN}Compartment:${NC} $compartment_id"
    echo -e "${CYAN}Region:${NC} $region"
    echo ""
    
    local cluster_state=$(get_cluster_state "$gpu_cluster")
    local cluster_state_color="$GREEN"
    [[ "$cluster_state" != "ACTIVE" ]] && cluster_state_color="$RED"
    echo -e "${CYAN}Cluster State:${NC} ${cluster_state_color}${cluster_state}${NC}"
    
    local fabric_info=$(get_fabric_from_cluster "$gpu_cluster")
    IFS='|' read -r fabric_name fabric_suffix fabric_ocid fabric_state avail_hosts total_hosts <<< "$fabric_info"
    
    if [[ "$fabric_name" != "N/A" ]]; then
        echo ""
        echo -e "${BOLD}${GREEN}=== GPU Memory Fabric ===${NC}"
        echo -e "${CYAN}Fabric Name:${NC}     $fabric_name"
        echo -e "${CYAN}Fabric OCID:${NC}     $fabric_ocid"
        local fabric_state_color="$GREEN"
        [[ "$fabric_state" != "AVAILABLE" ]] && fabric_state_color="$RED"
        echo -e "${CYAN}Fabric State:${NC}    ${fabric_state_color}${fabric_state}${NC}"
        echo -e "${CYAN}Host Capacity:${NC}   ${avail_hosts}/${total_hosts} available"
    fi
    
    echo ""
    
    local oci_data=$(create_temp_file)
    local k8s_data=$(create_temp_file)
    local output_temp=$(create_temp_file)
    
    log_info "Fetching instance details from OCI..."
    oci compute instance list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json | jq -r '.data[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")"' > "$oci_data"
    
    log_info "Fetching Kubernetes node data..."
    kubectl get nodes -l nvidia.com/gpu.present=true -o json | jq -r '
        .items[] | 
        "\(.spec.providerID)|\(.metadata.name)|\(.metadata.labels["nvidia.com/gpu.clique"] // "N/A")"
    ' > "$k8s_data"
    
    echo ""
    
    # Print table header
    printf "${BOLD}%-28s %-18s %-11s %-10s %-95s %-40s %-10s %-18s${NC}\n" \
        "Display Name" "K8s Node" "Node State" "OCI State" "Instance OCID" "Clique ID" "CapTopo" "Announce"
    echo -e "${BLUE}$(printf '━%.0s' {1..240})${NC}"
    
    # Process instances in this cluster
    grep "|${gpu_cluster}\$" "$oci_data" | while IFS='|' read -r instance_id display_name oci_state gpu_mem; do
        local k8s_info=$(grep "^${instance_id}|" "$k8s_data")
        [[ -z "$k8s_info" ]] && continue
        
        IFS='|' read -r _ node_name clique_id <<< "$k8s_info"
        
        local node_state=$(get_node_state_cached "$instance_id")
        local cap_topo_state=$(get_capacity_topology_state "$instance_id")
        local announcements=$(get_resource_announcements "$instance_id" "$gpu_mem")
        
        # Get colors
        local ns_color=$(color_node_state "$node_state")
        local st_color=$(color_oci_state "$oci_state")
        local ct_color=$(color_cap_topo_state "$cap_topo_state")
        local ann_color=$(color_announcement "$announcements")
        
        printf "%-28s %-18s ${ns_color}%-11s${NC} ${st_color}%-10s${NC} %-95s %-40s ${ct_color}%-10s${NC} ${ann_color}%-18s${NC}\n" \
            "$display_name" "$node_name" "$node_state" "$oci_state" "$instance_id" "$clique_id" "$cap_topo_state" "$announcements"
    done
    
    echo ""
    
    # Count total instances
    local total_count=$(grep -c "|${gpu_cluster}\$" "$oci_data" 2>/dev/null || echo 0)
    local k8s_count=$(grep "|${gpu_cluster}\$" "$oci_data" | while IFS='|' read -r id _ _ _; do
        grep -q "^${id}|" "$k8s_data" && echo "1"
    done | wc -l)
    
    echo -e "${CYAN}Total Instances:${NC} $total_count (${k8s_count} in Kubernetes)"
    
    rm -f "$oci_data" "$k8s_data" "$output_temp"
}

#===============================================================================
# HELP AND USAGE
#===============================================================================

show_help() {
    echo -e "${BOLD}Usage:${NC} $0 [OPTIONS] [instance-ocid] [OPTIONS]"
    echo ""
    echo "If no instance-ocid is provided, lists all GPU instances in the compartment with fabric details"
    echo ""
    echo -e "${BOLD}Global Options:${NC}"
    echo "  --compartment-id <ocid>   Override compartment ID from variables.sh"
    echo "  --region <region>         Override region from variables.sh"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --labels         Show all labels for the node"
    echo "  --clique         Show GPU clique information, OCI tags, cluster state, and fabric details"
    echo "  --count-clique   Count and list all nodes in the same clique with OCI tags and fabric info"
    echo "  --all            Show everything (labels + clique + count + OCI tags + fabric)"
    echo ""
    echo -e "${BOLD}Clique Analysis:${NC}"
    echo "  --list-cliques      List all unique cliques with nodes grouped by GPU memory cluster and fabric"
    echo "                      Also shows fabrics without active clusters and instances not in K8s"
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
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    # Source variables
    if [[ -f "$SCRIPT_DIR/variables.sh" ]]; then
        source "$SCRIPT_DIR/variables.sh"
    elif [[ -f "./variables.sh" ]]; then
        source "./variables.sh"
    else
        log_warn "variables.sh not found. Please ensure COMPARTMENT_ID, REGION, and TENANCY_ID are set."
    fi
    
    # Create cache directory
    mkdir -p "$CACHE_DIR"
    
    # Parse global options
    local custom_compartment=""
    local custom_region=""
    local args=("$@")
    local new_args=()
    local i=0
    
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --compartment-id)
                if [[ $((i + 1)) -lt ${#args[@]} ]]; then
                    custom_compartment="${args[$((i + 1))]}"
                    i=$((i + 2))
                else
                    log_error "--compartment-id requires a value"
                    exit 1
                fi
                ;;
            --region)
                if [[ $((i + 1)) -lt ${#args[@]} ]]; then
                    custom_region="${args[$((i + 1))]}"
                    i=$((i + 2))
                else
                    log_error "--region requires a value"
                    exit 1
                fi
                ;;
            *)
                new_args+=("${args[$i]}")
                i=$((i + 1))
                ;;
        esac
    done
    
    # Set effective values
    EFFECTIVE_COMPARTMENT_ID="${custom_compartment:-$COMPARTMENT_ID}"
    EFFECTIVE_REGION="${custom_region:-$REGION}"
    
    # Restore positional parameters
    set -- "${new_args[@]}"
    
    # Route to appropriate function based on arguments
    case "${1:-}" in
        "")
            list_all_instances "$EFFECTIVE_COMPARTMENT_ID" "$EFFECTIVE_REGION"
            ;;
        --list-cliques)
            list_all_cliques
            ;;
        --cliques-summary)
            list_cliques_summary
            ;;
        --list-cluster)
            [[ -z "$2" ]] && { log_error "GPU cluster ID required"; echo "Usage: $0 --list-cluster <gpu-cluster-id>"; exit 1; }
            list_instances_by_gpu_cluster "$2" "$EFFECTIVE_COMPARTMENT_ID" "$EFFECTIVE_REGION"
            ;;
        --help|-h)
            show_help
            ;;
        *)
            # Assume it's an instance OCID
            local instance_id="$1"
            local show_labels="false"
            local show_clique="false"
            local count_clique="false"
            
            shift
            while [[ $# -gt 0 ]]; do
                case $1 in
                    --labels)      show_labels="true"; shift ;;
                    --clique)      show_clique="true"; shift ;;
                    --count-clique) count_clique="true"; show_clique="true"; shift ;;
                    --all)         show_labels="true"; show_clique="true"; count_clique="true"; shift ;;
                    *)             log_error "Unknown option: $1"; exit 1 ;;
                esac
            done
            
            get_node_info "$instance_id" "$show_labels" "$show_clique" "$count_clique"
            ;;
    esac
}

# Run main function
main "$@"