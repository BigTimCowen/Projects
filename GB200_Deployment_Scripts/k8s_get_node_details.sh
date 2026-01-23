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
#   - kubectl (configured with cluster access)
#   - jq (JSON processor)
#
# Usage:
#   ./k8s_get_nodes_details.sh [OPTIONS] [instance-ocid] [OPTIONS]
#   Run with --help for full usage information.
#
# Configuration:
#   Requires variables.sh with COMPARTMENT_ID, REGION, and TENANCY_ID
#
# Author: GPU Infrastructure Team
# Version: 2.2
#

set -o pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================

# Color codes (readonly to prevent accidental modification)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly LIGHT_GREEN='\033[92m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly ORANGE='\033[38;5;208m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Cache settings
readonly CACHE_MAX_AGE=3600  # 1 hour in seconds

# Script directory and cache paths
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CACHE_DIR="${SCRIPT_DIR}/cache"

# Cache file paths (derived from CACHE_DIR)
readonly FABRIC_CACHE="${CACHE_DIR}/gpu_fabrics.txt"
readonly CLUSTER_CACHE="${CACHE_DIR}/gpu_clusters.txt"
readonly INSTANCE_CONFIG_CACHE="${CACHE_DIR}/instance_configurations.txt"
readonly NODE_STATE_CACHE="${CACHE_DIR}/node_states.txt"
readonly CAPACITY_TOPOLOGY_CACHE="${CACHE_DIR}/capacity_topology_hosts.txt"
readonly ANNOUNCEMENTS_LIST_CACHE="${CACHE_DIR}/announcements_list.json"
readonly OKE_ENV_CACHE="${CACHE_DIR}/oke_environment.txt"
readonly COMPUTE_CLUSTER_CACHE="${CACHE_DIR}/compute_clusters.txt"
readonly NETWORK_RESOURCES_CACHE="${CACHE_DIR}/network_resources.txt"

# Known shortnames for subnets and NSGs
readonly NETWORK_SHORTNAMES=("bastion" "cp" "operator" "int_lb" "pub_lb" "pods" "workers" "fss" "lustre")

# Global associative arrays for lookups (must use declare -gA for global scope)
declare -gA INSTANCE_ANNOUNCEMENTS
declare -gA GPU_MEM_CLUSTER_ANNOUNCEMENTS

# Effective compartment/region (set in main after parsing args)
EFFECTIVE_COMPARTMENT_ID=""
EFFECTIVE_REGION=""

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

# Print info message to stderr (no color for cleaner output)
log_info() {
    echo "$1" >&2
}

# Check if cache file is fresh (less than CACHE_MAX_AGE seconds old)
# Args: $1 = cache file path
# Returns: 0 if fresh, 1 if stale or missing
is_cache_fresh() {
    local cache_file="$1"
    
    [[ ! -f "$cache_file" ]] && return 1
    
    local file_mtime
    file_mtime=$(stat -c %Y "$cache_file" 2>/dev/null) || return 1
    
    local current_time
    current_time=$(date +%s)
    
    local cache_age=$((current_time - file_mtime))
    [[ $cache_age -lt $CACHE_MAX_AGE ]]
}

# Safely create a temp file and echo its path
# Uses trap to ensure cleanup on script exit
create_temp_file() {
    local tmp
    tmp=$(mktemp) || { log_error "Failed to create temp file"; return 1; }
    echo "$tmp"
}

# Lookup value from pipe-delimited cache file
# Args: $1 = cache file, $2 = key, $3 = field number (1-indexed)
# Returns: field value or "N/A" if not found
lookup_cache() {
    local cache_file="$1"
    local key="$2"
    local field="$3"
    
    [[ ! -f "$cache_file" ]] && { echo "N/A"; return 1; }
    
    local line
    line=$(grep "^${key}|" "$cache_file" 2>/dev/null | head -n1)
    
    if [[ -n "$line" ]]; then
        local value
        value=$(echo "$line" | cut -d'|' -f"$field")
        echo "${value:-N/A}"
    else
        echo "N/A"
        return 1
    fi
}

# Check if required commands are available
check_dependencies() {
    local missing=()
    
    command -v oci &>/dev/null || missing+=("oci")
    command -v kubectl &>/dev/null || missing+=("kubectl")
    command -v jq &>/dev/null || missing+=("jq")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_error "Please install the missing dependencies and try again."
        return 1
    fi
    return 0
}

#===============================================================================
# CACHE FETCH FUNCTIONS
#===============================================================================

# Fetch and cache GPU memory fabrics from OCI
fetch_gpu_fabrics() {
    [[ -z "$TENANCY_ID" ]] && { log_warn "TENANCY_ID not set. GPU fabric details unavailable."; return 1; }
    
    is_cache_fresh "$FABRIC_CACHE" && return 0
    
    log_info "Fetching GPU memory fabrics from OCI..."
    
    local raw_json
    raw_json=$(create_temp_file) || return 1
    
    if ! oci compute compute-gpu-memory-fabric list \
            --compartment-id "$TENANCY_ID" \
            --all \
            --output json > "$raw_json" 2>/dev/null; then
        rm -f "$raw_json"
        log_warn "Failed to fetch GPU memory fabrics"
        return 1
    fi
    
    # Write cache header and data
    {
        echo "# GPU Memory Fabrics"
        echo "# Format: DisplayName|Last5Chars|FabricOCID|State|HealthyHosts|AvailableHosts|TotalHosts"
        jq -r '.data.items[] | "\(.["display-name"])|\(.id[-5:] | ascii_downcase)|\(.id)|\(.["lifecycle-state"])|\(.["healthy-host-count"] // 0)|\(.["available-host-count"] // 0)|\(.["total-host-count"] // 0)"' "$raw_json" 2>/dev/null
    } > "$FABRIC_CACHE"
    
    rm -f "$raw_json"
    return 0
}

# Fetch and cache GPU memory clusters from OCI
fetch_gpu_clusters() {
    local compartment="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    [[ -z "$compartment" ]] && { log_warn "COMPARTMENT_ID not set. GPU cluster details unavailable."; return 1; }
    
    is_cache_fresh "$CLUSTER_CACHE" && return 0
    
    log_info "Fetching GPU memory clusters from OCI..."
    
    local raw_json
    raw_json=$(create_temp_file) || return 1
    
    if ! oci compute compute-gpu-memory-cluster list \
            --compartment-id "$compartment" \
            --all \
            --output json > "$raw_json" 2>/dev/null; then
        rm -f "$raw_json"
        log_warn "Failed to fetch GPU memory clusters"
        return 1
    fi
    
    # Write cache header
    {
        echo "# GPU Memory Clusters"
        echo "# Format: ClusterOCID|DisplayName|State|FabricSuffix|InstanceConfigurationId|ComputeClusterId"
    } > "$CLUSTER_CACHE"
    
    # Get cluster IDs and fetch details for each to get instance-configuration-id and compute-cluster-id
    local cluster_ids
    cluster_ids=$(jq -r '.data.items[]?.id // empty' "$raw_json" 2>/dev/null)
    
    local cluster_id
    for cluster_id in $cluster_ids; do
        [[ -z "$cluster_id" ]] && continue
        
        local cluster_detail_file
        cluster_detail_file=$(create_temp_file) || continue
        
        if oci compute compute-gpu-memory-cluster get \
                --compute-gpu-memory-cluster-id "$cluster_id" \
                --output json > "$cluster_detail_file" 2>/dev/null; then
            
            # Validate JSON before processing
            if jq -e '.data' "$cluster_detail_file" > /dev/null 2>&1; then
                jq -r '
                    .data["display-name"] as $name |
                    ($name | capture("fabric-(?<suffix>[a-z0-9]{5})") // {suffix: ""}) as $match |
                    "\(.data.id)|\($name)|\(.data["lifecycle-state"])|\($match.suffix)|\(.data["instance-configuration-id"] // "N/A")|\(.data["compute-cluster-id"] // "N/A")"
                ' "$cluster_detail_file" >> "$CLUSTER_CACHE" 2>/dev/null
            fi
        fi
        
        rm -f "$cluster_detail_file"
    done
    
    rm -f "$raw_json"
    return 0
}

# Fetch and cache all instance configurations from OCI
fetch_instance_configurations() {
    local compartment="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    [[ -z "$compartment" ]] && { log_warn "COMPARTMENT_ID not set. Instance configurations unavailable."; return 1; }
    
    is_cache_fresh "$INSTANCE_CONFIG_CACHE" && return 0
    
    log_info "Fetching instance configurations from OCI..."
    
    local raw_json
    raw_json=$(create_temp_file) || return 1
    
    if ! oci compute-management instance-configuration list \
            --compartment-id "$compartment" \
            --all \
            --output json > "$raw_json" 2>/dev/null; then
        rm -f "$raw_json"
        log_warn "Failed to fetch instance configurations"
        return 1
    fi
    
    # Write cache header and data
    {
        echo "# Instance Configurations"
        echo "# Format: InstanceConfigOCID|DisplayName"
        jq -r '.data[]? | "\(.id)|\(.["display-name"] // "N/A")"' "$raw_json" 2>/dev/null
    } > "$INSTANCE_CONFIG_CACHE"
    
    rm -f "$raw_json"
    return 0
}

# Get instance configuration name from cache
# Args: $1 = instance configuration OCID
get_instance_config_name() {
    local config_id="$1"
    
    [[ -z "$config_id" || "$config_id" == "N/A" || "$config_id" == "null" ]] && { echo "N/A"; return 1; }
    
    # Ensure cache is populated
    fetch_instance_configurations
    
    # Lookup from cache
    lookup_cache "$INSTANCE_CONFIG_CACHE" "$config_id" 2
}

# Fetch and cache compute clusters from OCI
fetch_compute_clusters() {
    local compartment="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    [[ -z "$compartment" ]] && { log_warn "COMPARTMENT_ID not set. Compute clusters unavailable."; return 1; }
    
    is_cache_fresh "$COMPUTE_CLUSTER_CACHE" && return 0
    
    log_info "Fetching compute clusters from OCI..."
    
    # Write cache header
    {
        echo "# Compute Clusters"
        echo "# Format: ComputeClusterOCID|DisplayName|AvailabilityDomain"
    } > "$COMPUTE_CLUSTER_CACHE"
    
    # Get availability domains
    local ad_list
    ad_list=$(oci iam availability-domain list --compartment-id "$compartment" --region "$region" --query 'data[].name' --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null)
    
    # Fetch compute clusters from each AD
    local ad
    for ad in $ad_list; do
        [[ -z "$ad" ]] && continue
        
        local raw_json
        raw_json=$(create_temp_file) || continue
        
        if oci compute compute-cluster list \
                --compartment-id "$compartment" \
                --availability-domain "$ad" \
                --region "$region" \
                --all \
                --output json > "$raw_json" 2>/dev/null; then
            
            jq -r '.data.items[]? | "\(.id)|\(.["display-name"] // "N/A")|\(.["availability-domain"] // "N/A")"' "$raw_json" >> "$COMPUTE_CLUSTER_CACHE" 2>/dev/null
        fi
        
        rm -f "$raw_json"
    done
    
    return 0
}

# Get compute cluster name from cache
# Args: $1 = compute cluster OCID
get_compute_cluster_name() {
    local cluster_id="$1"
    
    [[ -z "$cluster_id" || "$cluster_id" == "N/A" || "$cluster_id" == "null" ]] && { echo "N/A"; return 1; }
    
    # Ensure cache is populated
    fetch_compute_clusters
    
    # Lookup from cache
    lookup_cache "$COMPUTE_CLUSTER_CACHE" "$cluster_id" 2
}

# Fetch and cache Kubernetes node states
fetch_node_states() {
    {
        echo "# Node States"
        echo "# Format: ProviderID|NodeState"
        kubectl get nodes -o json 2>/dev/null | jq -r '
            .items[] | 
            "\(.spec.providerID)|\(
                .status.conditions[] | 
                select(.type=="Ready") | 
                if .status=="True" then "Ready" 
                elif .status=="False" then "NotReady" 
                else "Unknown" end
            )"' 2>/dev/null
    } > "$NODE_STATE_CACHE"
}

# Fetch and cache capacity topology bare metal hosts
fetch_capacity_topology() {
    [[ -z "$TENANCY_ID" ]] && { log_warn "TENANCY_ID not set. Capacity topology unavailable."; return 1; }
    
    is_cache_fresh "$CAPACITY_TOPOLOGY_CACHE" && return 0
    
    log_info "Fetching capacity topology from OCI..."
    
    local topologies_json
    topologies_json=$(create_temp_file) || return 1
    
    if ! oci compute capacity-topology list \
            --compartment-id "$TENANCY_ID" \
            --all \
            --output json > "$topologies_json" 2>/dev/null; then
        rm -f "$topologies_json"
        log_warn "Failed to fetch capacity topologies"
        return 1
    fi
    
    # Write cache header
    {
        echo "# Capacity Topology Hosts"
        echo "# Format: InstanceOCID|HostLifecycleState|HostLifecycleDetails|TopologyOCID"
    } > "$CAPACITY_TOPOLOGY_CACHE"
    
    # Get topology IDs and fetch bare metal hosts for each
    local topology_ids
    topology_ids=$(jq -r '.data.items[]?.id // empty' "$topologies_json" 2>/dev/null)
    
    local topo_id
    for topo_id in $topology_ids; do
        [[ -z "$topo_id" ]] && continue
        
        local hosts_json
        hosts_json=$(create_temp_file) || continue
        
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

# Fetch and cache OKE environment information
fetch_oke_environment() {
    local compartment_id="$1"
    local region="$2"
    
    is_cache_fresh "$OKE_ENV_CACHE" && return 0
    
    log_info "Fetching OKE environment information..."
    
    # Get tenancy OCID
    local tenancy_ocid="${TENANCY_ID:-}"
    if [[ -z "$tenancy_ocid" ]]; then
        # Try to get from instance metadata if running on OCI
        tenancy_ocid=$(curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/ 2>/dev/null | jq -r '.tenantId // empty')
    fi
    
    # Get compartment name
    local compartment_name="N/A"
    if [[ -n "$tenancy_ocid" && -n "$compartment_id" ]]; then
        compartment_name=$(oci iam compartment get --compartment-id "$compartment_id" --query 'data.name' --raw-output 2>/dev/null) || compartment_name="N/A"
    fi
    
    # Get availability domains
    local ads=""
    ads=$(oci iam availability-domain list --compartment-id "$compartment_id" --region "$region" --query 'data[].name' --raw-output 2>/dev/null | jq -r 'join(", ")') || ads="N/A"
    
    # Get OKE cluster info (find first active cluster matching pattern or just first active)
    local cluster_json
    cluster_json=$(oci ce cluster list --compartment-id "$compartment_id" --region "$region" --lifecycle-state ACTIVE --limit 1 --output json 2>/dev/null)
    
    local cluster_name cluster_ocid cluster_state pod_network vcn_ocid
    cluster_name=$(echo "$cluster_json" | jq -r '.data[0].name // "N/A"')
    cluster_ocid=$(echo "$cluster_json" | jq -r '.data[0].id // "N/A"')
    cluster_state=$(echo "$cluster_json" | jq -r '.data[0]["lifecycle-state"] // "N/A"')
    pod_network=$(echo "$cluster_json" | jq -r '.data[0]["cluster-pod-network-options"][0]["cni-type"] // "N/A"')
    vcn_ocid=$(echo "$cluster_json" | jq -r '.data[0]["vcn-id"] // "N/A"')
    
    # Get VCN name
    local vcn_name="N/A"
    if [[ "$vcn_ocid" != "N/A" && "$vcn_ocid" != "null" && -n "$vcn_ocid" ]]; then
        vcn_name=$(oci network vcn get --vcn-id "$vcn_ocid" --query 'data."display-name"' --raw-output 2>/dev/null) || vcn_name="N/A"
    fi
    
    # Get subnet and NSG info
    local worker_subnet_name="N/A" worker_subnet_ocid="N/A"
    local worker_nsg_name="N/A" worker_nsg_ocid="N/A"
    local pod_subnet_name="N/A" pod_subnet_ocid="N/A"
    local pod_nsg_name="N/A" pod_nsg_ocid="N/A"
    
    if [[ "$vcn_ocid" != "N/A" && "$vcn_ocid" != "null" && -n "$vcn_ocid" ]]; then
        local subnet_json nsg_json
        subnet_json=$(oci network subnet list --vcn-id "$vcn_ocid" --compartment-id "$compartment_id" --output json 2>/dev/null)
        nsg_json=$(oci network nsg list --compartment-id "$compartment_id" --vcn-id "$vcn_ocid" --output json 2>/dev/null)
        
        # Worker subnet
        worker_subnet_name=$(echo "$subnet_json" | jq -r '.data[] | select(."display-name" | test("worker"; "i")) | ."display-name"' 2>/dev/null | head -n1)
        worker_subnet_ocid=$(echo "$subnet_json" | jq -r '.data[] | select(."display-name" | test("worker"; "i")) | .id' 2>/dev/null | head -n1)
        worker_subnet_name="${worker_subnet_name:-N/A}"
        worker_subnet_ocid="${worker_subnet_ocid:-N/A}"
        
        # Worker NSG
        worker_nsg_name=$(echo "$nsg_json" | jq -r '.data[] | select(."display-name" | test("worker"; "i")) | ."display-name"' 2>/dev/null | head -n1)
        worker_nsg_ocid=$(echo "$nsg_json" | jq -r '.data[] | select(."display-name" | test("worker"; "i")) | .id' 2>/dev/null | head -n1)
        worker_nsg_name="${worker_nsg_name:-N/A}"
        worker_nsg_ocid="${worker_nsg_ocid:-N/A}"
        
        # Pod subnet
        pod_subnet_name=$(echo "$subnet_json" | jq -r '.data[] | select(."display-name" | test("pod"; "i")) | ."display-name"' 2>/dev/null | head -n1)
        pod_subnet_ocid=$(echo "$subnet_json" | jq -r '.data[] | select(."display-name" | test("pod"; "i")) | .id' 2>/dev/null | head -n1)
        pod_subnet_name="${pod_subnet_name:-N/A}"
        pod_subnet_ocid="${pod_subnet_ocid:-N/A}"
        
        # Pod NSG
        pod_nsg_name=$(echo "$nsg_json" | jq -r '.data[] | select(."display-name" | test("pod"; "i")) | ."display-name"' 2>/dev/null | head -n1)
        pod_nsg_ocid=$(echo "$nsg_json" | jq -r '.data[] | select(."display-name" | test("pod"; "i")) | .id' 2>/dev/null | head -n1)
        pod_nsg_name="${pod_nsg_name:-N/A}"
        pod_nsg_ocid="${pod_nsg_ocid:-N/A}"
    fi
    
    # Get availability domains for compute cluster lookup
    local ad_list
    ad_list=$(oci iam availability-domain list --compartment-id "$compartment_id" --region "$region" --query 'data[].name' --raw-output 2>/dev/null | jq -r '.[]' 2>/dev/null)
    
    # Get compute cluster info (search across all ADs)
    local compute_cluster_name="N/A" compute_cluster_ocid="N/A"
    local ad
    for ad in $ad_list; do
        [[ -z "$ad" ]] && continue
        local compute_cluster_json
        compute_cluster_json=$(oci compute compute-cluster list \
            --compartment-id "$compartment_id" \
            --availability-domain "$ad" \
            --region "$region" \
            --limit 1 \
            --output json 2>/dev/null)
        
        local found_name found_ocid
        found_name=$(echo "$compute_cluster_json" | jq -r '.data.items[0]."display-name" // empty' 2>/dev/null)
        found_ocid=$(echo "$compute_cluster_json" | jq -r '.data.items[0].id // empty' 2>/dev/null)
        
        if [[ -n "$found_name" && -n "$found_ocid" ]]; then
            compute_cluster_name="$found_name"
            compute_cluster_ocid="$found_ocid"
            break
        fi
    done
    
    # Write cache
    {
        echo "TENANCY_OCID|${tenancy_ocid:-N/A}"
        echo "COMPARTMENT_NAME|${compartment_name}"
        echo "COMPARTMENT_OCID|${compartment_id}"
        echo "REGION|${region}"
        echo "ADS|${ads}"
        echo "CLUSTER_NAME|${cluster_name}"
        echo "CLUSTER_OCID|${cluster_ocid}"
        echo "CLUSTER_STATE|${cluster_state}"
        echo "POD_NETWORK|${pod_network}"
        echo "VCN_NAME|${vcn_name}"
        echo "VCN_OCID|${vcn_ocid}"
        echo "WORKER_SUBNET_NAME|${worker_subnet_name}"
        echo "WORKER_SUBNET_OCID|${worker_subnet_ocid}"
        echo "WORKER_NSG_NAME|${worker_nsg_name}"
        echo "WORKER_NSG_OCID|${worker_nsg_ocid}"
        echo "POD_SUBNET_NAME|${pod_subnet_name}"
        echo "POD_SUBNET_OCID|${pod_subnet_ocid}"
        echo "POD_NSG_NAME|${pod_nsg_name}"
        echo "POD_NSG_OCID|${pod_nsg_ocid}"
        echo "COMPUTE_CLUSTER_NAME|${compute_cluster_name}"
        echo "COMPUTE_CLUSTER_OCID|${compute_cluster_ocid}"
    } > "$OKE_ENV_CACHE"
}

# Get value from OKE environment cache
get_oke_env_value() {
    local key="$1"
    grep "^${key}|" "$OKE_ENV_CACHE" 2>/dev/null | cut -d'|' -f2
}

# Fetch and cache all network resources (subnets and NSGs)
fetch_network_resources() {
    local compartment_id="$1"
    local vcn_ocid="$2"
    
    is_cache_fresh "$NETWORK_RESOURCES_CACHE" && return 0
    
    [[ "$vcn_ocid" == "N/A" || -z "$vcn_ocid" ]] && return 1
    
    log_info "Fetching network resources..."
    
    # Fetch subnets and NSGs
    local subnet_json nsg_json
    subnet_json=$(oci network subnet list --vcn-id "$vcn_ocid" --compartment-id "$compartment_id" --output json 2>/dev/null)
    nsg_json=$(oci network nsg list --compartment-id "$compartment_id" --vcn-id "$vcn_ocid" --output json 2>/dev/null)
    
    # Write cache
    {
        echo "# Network Resources Cache"
        echo "# Format: TYPE|NAME|CIDR_OR_STATE|ACCESS_OR_STATE|OCID"
        
        # Process subnets
        echo "$subnet_json" | jq -r '.data[] | "SUBNET|\(."display-name" // "N/A")|\(."cidr-block" // "N/A")|\(if ."prohibit-public-ip-on-vnic" then "Private" else "Public" end)|\(."lifecycle-state" // "N/A")|\(.id // "N/A")"' 2>/dev/null
        
        # Process NSGs
        echo "$nsg_json" | jq -r '.data[] | "NSG|\(."display-name" // "N/A")||\(."lifecycle-state" // "N/A")|\(.id // "N/A")"' 2>/dev/null
    } > "$NETWORK_RESOURCES_CACHE"
}

# Find matching shortname for a resource name
get_shortname_match() {
    local name="$1"
    local name_lower
    name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    
    local shortname
    for shortname in "${NETWORK_SHORTNAMES[@]}"; do
        if [[ "$name_lower" == *"$shortname"* ]]; then
            echo "$shortname"
            return 0
        fi
    done
    echo ""
}

# Display network resources grouped by shortname
display_network_resources() {
    local compartment_id="$1"
    local vcn_ocid="$2"
    
    # Fetch/refresh cache
    fetch_network_resources "$compartment_id" "$vcn_ocid"
    
    [[ ! -f "$NETWORK_RESOURCES_CACHE" ]] && return 1
    
    echo -e "${BOLD}${WHITE}Network Resources:${NC}"
    
    # Build arrays of subnets and NSGs
    declare -A subnets_by_shortname
    declare -A nsgs_by_shortname
    declare -a unmatched_subnets
    declare -a unmatched_nsgs
    declare -a subnet_shortnames
    
    # Read subnets
    while IFS='|' read -r type name cidr access state ocid; do
        [[ "$type" != "SUBNET" ]] && continue
        local shortname
        shortname=$(get_shortname_match "$name")
        if [[ -n "$shortname" ]]; then
            subnets_by_shortname[$shortname]="${name}|${cidr}|${access}|${state}|${ocid}"
            subnet_shortnames+=("$shortname")
        else
            unmatched_subnets+=("${name}|${cidr}|${access}|${state}|${ocid}")
        fi
    done < <(grep "^SUBNET|" "$NETWORK_RESOURCES_CACHE" 2>/dev/null)
    
    # Read NSGs
    while IFS='|' read -r type name _ state ocid; do
        [[ "$type" != "NSG" ]] && continue
        local shortname
        shortname=$(get_shortname_match "$name")
        if [[ -n "$shortname" ]]; then
            # Append to existing or create new
            if [[ -n "${nsgs_by_shortname[$shortname]:-}" ]]; then
                nsgs_by_shortname[$shortname]="${nsgs_by_shortname[$shortname]}#${name}|${state}|${ocid}"
            else
                nsgs_by_shortname[$shortname]="${name}|${state}|${ocid}"
            fi
        else
            unmatched_nsgs+=("${name}|${state}|${ocid}")
        fi
    done < <(grep "^NSG|" "$NETWORK_RESOURCES_CACHE" 2>/dev/null)
    
    # Display subnets with their matching NSGs
    local shortname
    for shortname in "${subnet_shortnames[@]}"; do
        local subnet_info="${subnets_by_shortname[$shortname]}"
        [[ -z "$subnet_info" ]] && continue
        
        local name cidr access state ocid
        IFS='|' read -r name cidr access state ocid <<< "$subnet_info"
        
        local access_color state_color
        [[ "$access" == "Private" ]] && access_color="$RED" || access_color="$LIGHT_GREEN"
        [[ "$state" == "AVAILABLE" ]] && state_color="$GREEN" || state_color="$RED"
        
        # Format: Subnet: name [cidr] [access] [state] (ocid)
        # Positions: 10 + 30 + 2 + 18 + 3 + 7 + 3 + 9 + 2 = 84 before "("
        printf "  ${BOLD}${WHITE}Subnet:${NC} ${GREEN}%-30s${NC} ${WHITE}[${CYAN}%-18s${WHITE}]${NC} ${WHITE}[${access_color}%-7s${WHITE}]${NC} ${WHITE}[${state_color}%-9s${WHITE}]${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
            "$name" "$cidr" "$access" "$state" "$ocid"
        
        # Display matching NSGs
        local nsg_list="${nsgs_by_shortname[$shortname]:-}"
        if [[ -n "$nsg_list" ]]; then
            local nsg_entries
            IFS='#' read -ra nsg_entries <<< "$nsg_list"
            local nsg_count=${#nsg_entries[@]}
            local i=0
            for nsg_entry in "${nsg_entries[@]}"; do
                ((i++))
                local nsg_name nsg_state nsg_ocid
                IFS='|' read -r nsg_name nsg_state nsg_ocid <<< "$nsg_entry"
                
                local nsg_state_color
                [[ "$nsg_state" == "AVAILABLE" ]] && nsg_state_color="$GREEN" || nsg_state_color="$RED"
                
                local prefix="├─"
                [[ $i -eq $nsg_count ]] && prefix="└─"
                
                # NSG line: 10 spaces + "├─ NSG: " (8 display) + 30 name = 48
                # Need 24 spaces to reach position 72 where [state] starts
                printf "          ${BOLD}${BLUE}${prefix} NSG:${NC} ${WHITE}%-30s${NC}                        ${WHITE}[${nsg_state_color}%-9s${WHITE}]${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                    "$nsg_name" "$nsg_state" "$nsg_ocid"
            done
        fi
        echo ""
    done
    
    # Display unmatched subnets (subnets that don't match any known shortname)
    if [[ ${#unmatched_subnets[@]} -gt 0 ]]; then
        for subnet_entry in "${unmatched_subnets[@]}"; do
            local name cidr access state ocid
            IFS='|' read -r name cidr access state ocid <<< "$subnet_entry"
            
            local access_color state_color
            [[ "$access" == "Private" ]] && access_color="$RED" || access_color="$LIGHT_GREEN"
            [[ "$state" == "AVAILABLE" ]] && state_color="$GREEN" || state_color="$RED"
            
            printf "  ${BOLD}${WHITE}Subnet:${NC} ${GREEN}%-30s${NC} ${WHITE}[${CYAN}%-18s${WHITE}]${NC} ${WHITE}[${access_color}%-7s${WHITE}]${NC} ${WHITE}[${state_color}%-9s${WHITE}]${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "$name" "$cidr" "$access" "$state" "$ocid"
            echo ""
        done
    fi
    
    # Display unmatched NSGs if any
    if [[ ${#unmatched_nsgs[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}${WHITE}Unmatched NSGs:${NC}"
        local i=0
        local total=${#unmatched_nsgs[@]}
        for nsg_entry in "${unmatched_nsgs[@]}"; do
            ((i++))
            local nsg_name nsg_state nsg_ocid
            IFS='|' read -r nsg_name nsg_state nsg_ocid <<< "$nsg_entry"
            
            local nsg_state_color
            [[ "$nsg_state" == "AVAILABLE" ]] && nsg_state_color="$GREEN" || nsg_state_color="$RED"
            
            local prefix="├─"
            [[ $i -eq $total ]] && prefix="└─"
            
            # Same alignment as matched NSGs: 24 spaces after 30-char name
            printf "          ${BOLD}${BLUE}${prefix} NSG:${NC} ${WHITE}%-30s${NC}                        ${WHITE}[${nsg_state_color}%-9s${WHITE}]${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "$nsg_name" "$nsg_state" "$nsg_ocid"
        done
        echo ""
    fi
}

# Build announcement lookup tables from cached data
build_announcement_lookup() {
    local compartment_id="$1"
    
    # Reset arrays
    INSTANCE_ANNOUNCEMENTS=()
    GPU_MEM_CLUSTER_ANNOUNCEMENTS=()
    
    # Refresh cache if needed
    if ! is_cache_fresh "$ANNOUNCEMENTS_LIST_CACHE"; then
        log_info "Fetching announcements from OCI..."
        
        if ! oci announce announcements list \
                --compartment-id "$compartment_id" \
                --all > "$ANNOUNCEMENTS_LIST_CACHE" 2>/dev/null; then
            log_warn "Failed to fetch announcements"
            return 1
        fi
        
        # Fetch details for each announcement in parallel
        local announcement_ids
        announcement_ids=$(jq -r '.data.items[].id' "$ANNOUNCEMENTS_LIST_CACHE" 2>/dev/null)
        
        local ann_id
        for ann_id in $announcement_ids; do
            local detail_file="${CACHE_DIR}/${ann_id##*.}.json"
            if [[ ! -f "$detail_file" || ! -s "$detail_file" ]]; then
                oci announce announcements get --announcement-id "$ann_id" > "$detail_file" 2>/dev/null &
            fi
        done
        wait
    fi
    
    # Process cached announcement details
    local detail_file
    for detail_file in "$CACHE_DIR"/*.json; do
        [[ ! -f "$detail_file" ]] && continue
        [[ "$detail_file" == "$ANNOUNCEMENTS_LIST_CACHE" ]] && continue
        [[ "$detail_file" == *"/ack_status_cache.json" ]] && continue
        
        # Validate JSON has announcement data
        if ! jq -e '.data.id' "$detail_file" > /dev/null 2>&1; then
            continue
        fi
        
        # Only process ACTIVE announcements
        local lifecycle_state
        lifecycle_state=$(jq -r '.data."lifecycle-state" // "N/A"' "$detail_file")
        [[ "$lifecycle_state" != "ACTIVE" ]] && continue
        
        local reference_ticket
        reference_ticket=$(jq -r '.data."reference-ticket-number" // "N/A"' "$detail_file")
        local short_ticket="${reference_ticket:0:8}"
        
        # Extract affected resources count
        local resource_count
        resource_count=$(jq '.data."affected-resources" | length' "$detail_file" 2>/dev/null) || resource_count=0
        
        local i
        for ((i=0; i<resource_count; i++)); do
            # Get instance/resource ID
            local resource_id
            resource_id=$(jq -r ".data.\"affected-resources\"[$i] | 
                if .properties then
                    (.properties[] | select(.name == \"resourceId\" or .name == \"instanceId\") | .value) // null
                else
                    (.\"resource-id\" // .\"instance-id\" // null)
                end" "$detail_file" 2>/dev/null)
            
            # Get GPU memory cluster
            local gpu_mem_cluster
            gpu_mem_cluster=$(jq -r ".data.\"affected-resources\"[$i] |
                if .properties then
                    (.properties[] | select(.name == \"gpuMemoryCluster\") | .value) // null
                else
                    null
                end" "$detail_file" 2>/dev/null)
            
            # Add to instance lookup (avoid duplicates)
            if [[ -n "$resource_id" && "$resource_id" != "null" ]]; then
                if [[ -z "${INSTANCE_ANNOUNCEMENTS[$resource_id]:-}" ]]; then
                    INSTANCE_ANNOUNCEMENTS[$resource_id]="$short_ticket"
                elif [[ ! "${INSTANCE_ANNOUNCEMENTS[$resource_id]}" =~ $short_ticket ]]; then
                    INSTANCE_ANNOUNCEMENTS[$resource_id]="${INSTANCE_ANNOUNCEMENTS[$resource_id]},$short_ticket"
                fi
            fi
            
            # Add to GPU memory cluster lookup (avoid duplicates)
            if [[ -n "$gpu_mem_cluster" && "$gpu_mem_cluster" != "null" ]]; then
                if [[ -z "${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]:-}" ]]; then
                    GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]="$short_ticket"
                elif [[ ! "${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]}" =~ $short_ticket ]]; then
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
# Args: $1 = cluster OCID
get_cluster_state() {
    lookup_cache "$CLUSTER_CACHE" "$1" 3
}

# Get instance configuration ID from cluster OCID
# Args: $1 = cluster OCID
get_instance_config_from_cluster() {
    lookup_cache "$CLUSTER_CACHE" "$1" 5
}

# Get compute cluster ID from GPU memory cluster OCID
# Args: $1 = GPU memory cluster OCID
get_compute_cluster_from_gpu_cluster() {
    lookup_cache "$CLUSTER_CACHE" "$1" 6
}

# Get node state from cache
# Args: $1 = instance OCID (provider ID)
get_node_state_cached() {
    lookup_cache "$NODE_STATE_CACHE" "$1" 2
}

# Get capacity topology state for an instance
# Args: $1 = instance OCID
get_capacity_topology_state() {
    lookup_cache "$CAPACITY_TOPOLOGY_CACHE" "$1" 3
}

# Get fabric details from cluster OCID
# Args: $1 = cluster OCID
# Returns: DisplayName|Last5Chars|FabricOCID|State|AvailableHosts|TotalHosts
get_fabric_from_cluster() {
    local cluster_ocid="$1"
    local default="N/A|N/A|N/A|N/A|0|0"
    
    [[ ! -f "$FABRIC_CACHE" || ! -f "$CLUSTER_CACHE" ]] && { echo "$default"; return 1; }
    
    local fabric_suffix
    fabric_suffix=$(grep "^${cluster_ocid}|" "$CLUSTER_CACHE" 2>/dev/null | cut -d'|' -f4)
    [[ -z "$fabric_suffix" ]] && { echo "$default"; return 1; }
    
    local fabric_line
    fabric_line=$(grep -v '^#' "$FABRIC_CACHE" | grep "|${fabric_suffix}|" | head -n1)
    echo "${fabric_line:-$default}"
}

# Get announcements for a resource (instance and/or GPU memory cluster)
# Args: $1 = instance OCID, $2 = GPU memory cluster OCID
# Returns: comma-separated ticket numbers or "-" if none
get_resource_announcements() {
    local instance_ocid="$1"
    local gpu_mem_cluster="$2"
    local result=""
    
    # Check instance-level announcements
    if [[ -n "$instance_ocid" && -n "${INSTANCE_ANNOUNCEMENTS[$instance_ocid]:-}" ]]; then
        result="${INSTANCE_ANNOUNCEMENTS[$instance_ocid]}"
    fi
    
    # Check GPU memory cluster level announcements
    if [[ -n "$gpu_mem_cluster" && "$gpu_mem_cluster" != "N/A" && -n "${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]:-}" ]]; then
        if [[ -z "$result" ]]; then
            result="${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]}"
        else
            # Append unique tickets only
            local ticket
            for ticket in ${GPU_MEM_CLUSTER_ANNOUNCEMENTS[$gpu_mem_cluster]//,/ }; do
                [[ ! "$result" =~ $ticket ]] && result="${result},${ticket}"
            done
        fi
    fi
    
    echo "${result:--}"
}

#===============================================================================
# COLOR HELPER FUNCTIONS
#===============================================================================

# Get color for Kubernetes node state
color_node_state() {
    case "$1" in
        Ready)    echo "$GREEN" ;;
        NotReady) echo "$RED" ;;
        *)        echo "$YELLOW" ;;
    esac
}

# Get color for OCI instance state
color_oci_state() {
    case "$1" in
        RUNNING)    echo "$GREEN" ;;
        STOPPED)    echo "$RED" ;;
        TERMINATED) echo "$RED" ;;
        *)          echo "$YELLOW" ;;
    esac
}

# Get color for capacity topology state
color_cap_topo_state() {
    case "$1" in
        AVAILABLE) echo "$GREEN" ;;
        N/A)       echo "$YELLOW" ;;
        *)         echo "$RED" ;;
    esac
}

# Get color for cluster state
color_cluster_state() {
    case "$1" in
        ACTIVE) echo "$GREEN" ;;
        *)      echo "$RED" ;;
    esac
}

# Get color for fabric state
color_fabric_state() {
    case "$1" in
        AVAILABLE) echo "$GREEN" ;;
        *)         echo "$RED" ;;
    esac
}

# Get color for announcement status
color_announcement() {
    [[ "$1" == "-" ]] && echo "$GREEN" || echo "$RED"
}

#===============================================================================
# TABLE FORMATTING HELPERS
#===============================================================================

# Print a horizontal separator line
print_separator() {
    local width="${1:-80}"
    echo -e "${BLUE}$(printf '━%.0s' $(seq 1 "$width"))${NC}"
}

# Truncate string to max length with ellipsis
truncate_string() {
    local str="$1"
    local max_len="$2"
    
    if [[ ${#str} -gt $max_len ]]; then
        echo "${str:0:$((max_len-3))}..."
    else
        echo "$str"
    fi
}

#===============================================================================
# OKE ENVIRONMENT HEADER
#===============================================================================

# Display OKE environment header
display_oke_environment_header() {
    local compartment_id="$1"
    local region="$2"
    
    # Fetch/refresh cache
    fetch_oke_environment "$compartment_id" "$region"
    
    # Read values from cache
    local tenancy_ocid compartment_name ads
    local cluster_name cluster_ocid cluster_state pod_network vcn_name vcn_ocid
    local compute_cluster_name compute_cluster_ocid
    
    tenancy_ocid=$(get_oke_env_value "TENANCY_OCID")
    compartment_name=$(get_oke_env_value "COMPARTMENT_NAME")
    ads=$(get_oke_env_value "ADS")
    cluster_name=$(get_oke_env_value "CLUSTER_NAME")
    cluster_ocid=$(get_oke_env_value "CLUSTER_OCID")
    cluster_state=$(get_oke_env_value "CLUSTER_STATE")
    pod_network=$(get_oke_env_value "POD_NETWORK")
    vcn_name=$(get_oke_env_value "VCN_NAME")
    vcn_ocid=$(get_oke_env_value "VCN_OCID")
    compute_cluster_name=$(get_oke_env_value "COMPUTE_CLUSTER_NAME")
    compute_cluster_ocid=$(get_oke_env_value "COMPUTE_CLUSTER_OCID")
    
    # Box width for content (excluding border chars)
    local width=148
    local h_line
    h_line=$(printf '═%.0s' $(seq 1 $width))
    
    # Helper function to print a simple labeled row (no OCID)
    _print_row() {
        local label="$1"
        local value="$2"
        local label_width=18
        local value_width=$((width - 2 - label_width))
        printf "${BOLD}${BLUE}║${NC}  ${CYAN}%-${label_width}s${NC}${WHITE}%-${value_width}s${NC}${BOLD}${BLUE}║${NC}\n" "$label" "$value"
    }
    
    # Helper function to print a row with name and OCID (OCID in yellow)
    _print_row_with_ocid() {
        local label="$1"
        local name="$2"
        local ocid="$3"
        local label_width=18
        local combined="${name} (${ocid})"
        local combined_len=${#combined}
        local value_width=$((width - 2 - label_width))
        local padding=$((value_width - combined_len))
        [[ $padding -lt 0 ]] && padding=0
        printf "${BOLD}${BLUE}║${NC}  ${CYAN}%-${label_width}s${NC}${WHITE}%s${NC} ${YELLOW}(%s)${NC}%${padding}s${BOLD}${BLUE}║${NC}\n" "$label" "$name" "$ocid" ""
    }
    
    # Helper for OCID-only rows (like tenancy)
    _print_ocid_row() {
        local label="$1"
        local ocid="$2"
        local label_width=18
        local value_width=$((width - 2 - label_width))
        printf "${BOLD}${BLUE}║${NC}  ${CYAN}%-${label_width}s${NC}${YELLOW}%-${value_width}s${NC}${BOLD}${BLUE}║${NC}\n" "$label" "$ocid"
    }
    
    echo ""
    
    # Top border
    echo -e "${BOLD}${BLUE}╔${h_line}╗${NC}"
    
    # Title row - centered
    local title="OKE CLUSTER ENVIRONMENT"
    local title_len=${#title}
    local left_pad=$(( (width - title_len) / 2 ))
    local right_pad=$(( width - title_len - left_pad ))
    printf "${BOLD}${BLUE}║${NC}%${left_pad}s${BOLD}${WHITE}%s${NC}%${right_pad}s${BOLD}${BLUE}║${NC}\n" "" "$title" ""
    
    # Section separator
    echo -e "${BOLD}${BLUE}╠${h_line}╣${NC}"
    
    # Tenancy & Region section
    _print_ocid_row "Tenancy:" "$tenancy_ocid"
    _print_row "Region:" "$region"
    _print_row_with_ocid "Compartment:" "$compartment_name" "$compartment_id"
    _print_row "ADs:" "$ads"
    
    # Section separator
    echo -e "${BOLD}${BLUE}╠${h_line}╣${NC}"
    
    # OKE Cluster section - special handling for cluster with state
    local label_width=18
    local cluster_combined="${cluster_name} [${cluster_state}] (${cluster_ocid})"
    local cluster_combined_len=${#cluster_combined}
    local value_width=$((width - 2 - label_width))
    local cluster_padding=$((value_width - cluster_combined_len))
    [[ $cluster_padding -lt 0 ]] && cluster_padding=0
    printf "${BOLD}${BLUE}║${NC}  ${CYAN}%-${label_width}s${NC}${WHITE}%s${NC} ${GREEN}[%s]${NC} ${YELLOW}(%s)${NC}%${cluster_padding}s${BOLD}${BLUE}║${NC}\n" "OKE Cluster:" "$cluster_name" "$cluster_state" "$cluster_ocid" ""
    
    _print_row "Pod Network:" "$pod_network"
    _print_row_with_ocid "VCN:" "$vcn_name" "$vcn_ocid"
    
    # Section separator
    echo -e "${BOLD}${BLUE}╠${h_line}╣${NC}"
    
    # Compute Cluster section
    _print_row_with_ocid "Compute Cluster:" "$compute_cluster_name" "$compute_cluster_ocid"
    
    # Bottom border
    echo -e "${BOLD}${BLUE}╚${h_line}╝${NC}"
    echo ""
    
    # Display network resources (subnets and NSGs grouped by shortname)
    display_network_resources "$compartment_id" "$vcn_ocid"
}

#===============================================================================
# DISPLAY FUNCTIONS
#===============================================================================

# List fabrics without active clusters
list_fabrics_without_clusters() {
    echo -e "${BOLD}${MAGENTA}=== GPU Memory Fabrics Without Active Clusters ===${NC}"
    echo ""
    
    if [[ ! -f "$FABRIC_CACHE" || ! -f "$CLUSTER_CACHE" ]]; then
        echo -e "${YELLOW}Cache files not available${NC}"
        return 1
    fi
    
    local all_fabric_suffixes
    all_fabric_suffixes=$(grep -v '^#' "$FABRIC_CACHE" | cut -d'|' -f2)
    
    local used_fabric_suffixes
    used_fabric_suffixes=$(grep -v '^#' "$CLUSTER_CACHE" | grep "|ACTIVE|" | cut -d'|' -f4 | sort -u)
    
    local found_unused=false
    local temp_output
    temp_output=$(create_temp_file) || return 1
    
    local fabric_suffix
    while read -r fabric_suffix; do
        [[ -z "$fabric_suffix" ]] && continue
        
        if ! echo "$used_fabric_suffixes" | grep -q "^${fabric_suffix}$"; then
            found_unused=true
            local fabric_line
            fabric_line=$(grep -v '^#' "$FABRIC_CACHE" | grep "|${fabric_suffix}|" | head -n1)
            
            if [[ -n "$fabric_line" ]]; then
                # Format: DisplayName|Last5Chars|FabricOCID|State|HealthyHosts|AvailableHosts|TotalHosts
                local fabric_name fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts
                IFS='|' read -r fabric_name _ fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts <<< "$fabric_line"
                echo "${fabric_name}|${fabric_ocid}|${fabric_state}|${healthy_hosts}|${avail_hosts}|${total_hosts}" >> "$temp_output"
            fi
        fi
    done <<< "$all_fabric_suffixes"
    
    if [[ "$found_unused" == "true" ]]; then
        # Print header - aligned with clique summary
        printf "${BOLD}%-48s %-8s %-6s %-6s %-12s${NC}\n" \
            "Fabric Display Name" "Healthy" "Avail" "Total" "State"
        print_separator 96
        
        # Print data rows
        local fabric_name fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts
        while IFS='|' read -r fabric_name fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts; do
            local state_color
            state_color=$(color_fabric_state "$fabric_state")
            printf "${CYAN}%-48s${NC} ${YELLOW}%-8s${NC} ${WHITE}%-6s${NC} ${WHITE}%-6s${NC} ${state_color}%-12s${NC}\n" \
                "$fabric_name" "$healthy_hosts" "$avail_hosts" "$total_hosts" "$fabric_state"
            printf "          ${BOLD}${ORANGE}└─${NC} ${BOLD}${ORANGE}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "Fabric:" "$fabric_name" "$fabric_ocid"
            echo ""
        done < "$temp_output"
    else
        echo -e "${GREEN}All fabrics have active clusters${NC}"
    fi
    
    rm -f "$temp_output"
}

# Get console history for an instance
# Args: $1 = instance OCID
get_console_history() {
    local instance_ocid="$1"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    [[ -z "$instance_ocid" ]] && { log_error "Instance OCID required"; return 1; }
    [[ -z "$region" ]] && { log_error "REGION not set"; return 1; }
    
    echo ""
    echo -e "${BOLD}${CYAN}=== Console History for Instance ===${NC}"
    echo -e "${YELLOW}Instance OCID:${NC} $instance_ocid"
    echo -e "${YELLOW}Region:${NC} $region"
    echo ""
    
    log_info "Capturing console history (this may take a moment)..."
    
    local console_history_id
    console_history_id=$(oci --region "$region" compute console-history capture \
        --instance-id "$instance_ocid" 2>/dev/null | jq -r '.data.id // empty')
    
    if [[ -z "$console_history_id" ]]; then
        log_error "Failed to capture console history"
        return 1
    fi
    
    echo -e "${GREEN}Console history captured: ${console_history_id}${NC}"
    echo ""
    
    # Wait a moment for the capture to complete
    sleep 2
    
    # Fetch and display the console history
    echo -e "${BOLD}${MAGENTA}--- Console Output (last 10MB) ---${NC}"
    print_separator 80
    
    oci compute console-history get-content \
        --instance-console-history-id "$console_history_id" \
        --length 10000000 \
        --file - 2>/dev/null
    
    print_separator 80
    echo -e "${BOLD}${MAGENTA}--- End of Console Output ---${NC}"
    echo ""
    
    return 0
}

# List instances not in Kubernetes with interactive console history option
list_instances_not_in_k8s() {
    local oci_temp="$1"
    local k8s_temp="$2"
    local interactive="${3:-true}"  # Default to interactive mode
    
    echo -e "${BOLD}${MAGENTA}=== GPU Instances Not in Kubernetes ===${NC}"
    echo ""
    
    # Collect orphan instances into an array
    local -a orphan_names=()
    local -a orphan_ocids=()
    local -a orphan_states=()
    local -a orphan_gpu_mems=()
    local orphan_count=0
    
    # oci_temp format: display_name|status|instance_ocid|gpu_mem
    local display_name status instance_ocid gpu_mem
    while IFS='|' read -r display_name status instance_ocid gpu_mem; do
        [[ -z "$instance_ocid" ]] && continue
        
        if ! grep -q "^${instance_ocid}|" "$k8s_temp" 2>/dev/null; then
            if [[ "$status" == "RUNNING" ]]; then
                orphan_names+=("$display_name")
                orphan_ocids+=("$instance_ocid")
                orphan_states+=("$status")
                orphan_gpu_mems+=("$gpu_mem")
                ((orphan_count++))
            fi
        fi
    done < "$oci_temp"
    
    if [[ $orphan_count -eq 0 ]]; then
        echo -e "${GREEN}All running GPU instances are in Kubernetes${NC}"
        return 0
    fi
    
    # Display numbered list of orphan instances
    printf "${BOLD}%-4s %-35s %-10s %-15s %s${NC}\n" \
        "#" "Display Name" "OCI State" "GPU Mem Cluster" "Instance OCID"
    print_separator 160
    
    local i
    for ((i=0; i<orphan_count; i++)); do
        local gpu_mem_display="${orphan_gpu_mems[$i]}"
        [[ "$gpu_mem_display" != "N/A" && ${#gpu_mem_display} -gt 12 ]] && gpu_mem_display="...${gpu_mem_display: -9}"
        
        printf "${YELLOW}%-4s${NC} ${CYAN}%-35s${NC} ${GREEN}%-10s${NC} ${MAGENTA}%-15s${NC} ${WHITE}%s${NC}\n" \
            "$((i+1))" \
            "$(truncate_string "${orphan_names[$i]}" 35)" \
            "${orphan_states[$i]}" \
            "$gpu_mem_display" \
            "${orphan_ocids[$i]}"
    done
    
    echo ""
    echo -e "${YELLOW}Total orphan instances: ${orphan_count}${NC}"
    
    # Interactive mode - prompt for console history
    if [[ "$interactive" == "true" && -t 0 ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}Would you like to view console history for any of these instances?${NC}"
        echo -e "Enter instance number (1-${orphan_count}), or press Enter to skip: "
        
        local selection
        read -r selection
        
        if [[ -n "$selection" ]]; then
            # Validate input is a number
            if [[ "$selection" =~ ^[0-9]+$ ]]; then
                if [[ $selection -ge 1 && $selection -le $orphan_count ]]; then
                    local selected_idx=$((selection - 1))
                    echo ""
                    echo -e "${GREEN}Selected: ${orphan_names[$selected_idx]}${NC}"
                    get_console_history "${orphan_ocids[$selected_idx]}"
                else
                    log_error "Invalid selection. Please enter a number between 1 and ${orphan_count}"
                fi
            else
                log_error "Invalid input. Please enter a number."
            fi
        else
            echo -e "${CYAN}Skipping console history view.${NC}"
        fi
    fi
}

# Non-interactive version for scripting - just list orphans
list_instances_not_in_k8s_non_interactive() {
    local oci_temp="$1"
    local k8s_temp="$2"
    list_instances_not_in_k8s "$oci_temp" "$k8s_temp" "false"
}

#===============================================================================
# MAIN LIST FUNCTIONS
#===============================================================================

# List all GPU instances in compartment
list_all_instances() {
    local compartment_id="$1"
    local region="$2"
    
    # Validate required parameters
    if [[ -z "$compartment_id" ]]; then
        log_error "COMPARTMENT_ID not set. Use --compartment-id or set in variables.sh"
        return 1
    fi
    if [[ -z "$region" ]]; then
        log_error "REGION not set. Use --region or set in variables.sh"
        return 1
    fi
    
    # Display OKE environment header
    display_oke_environment_header "$compartment_id" "$region"
    
    # Fetch all cached data
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_instance_configurations
    
    echo -e "${BOLD}${MAGENTA}=== All GPU Instances in Compartment ===${NC}"
    echo ""
    
    # Create temp files
    local oci_temp k8s_temp output_temp
    oci_temp=$(create_temp_file) || return 1
    k8s_temp=$(create_temp_file) || { rm -f "$oci_temp"; return 1; }
    output_temp=$(create_temp_file) || { rm -f "$oci_temp" "$k8s_temp"; return 1; }
    
    # Fetch OCI instances
    log_info "Fetching instances from OCI..."
    oci compute instance list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json 2>/dev/null | jq -r '
            .data[] | 
            select(.shape | contains("GPU")) | 
            "\(.["display-name"])|\(.["lifecycle-state"])|\(.id)|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")"
        ' > "$oci_temp"
    
    # Fetch K8s GPU nodes
    log_info "Fetching GPU nodes from Kubernetes..."
    kubectl get nodes -l nvidia.com/gpu.present=true -o json 2>/dev/null | jq -r '
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
    
    log_info "Fetching compute clusters..."
    fetch_compute_clusters
    
    echo "Processing data..."
    echo ""
    
    # Print table header
    printf "${BOLD}%-28s %-15s %-11s %-10s %-95s %-12s %-12s %-40s %-10s %-18s${NC}\n" \
        "Display Name" "K8s Node" "Node State" "OCI State" "Instance OCID" "GPU Cluster" "Cluster St" "Clique ID" "CapTopo" "Announce"
    print_separator 280
    
    # Process and collect data for sorting
    local display_name status instance_ocid gpu_mem
    while IFS='|' read -r display_name status instance_ocid gpu_mem; do
        [[ -z "$instance_ocid" ]] && continue
        
        local k8s_info
        k8s_info=$(grep "^${instance_ocid}|" "$k8s_temp" 2>/dev/null)
        [[ -z "$k8s_info" ]] && continue
        
        local node_name clique_id
        IFS='|' read -r _ node_name clique_id <<< "$k8s_info"
        
        # Get various states
        local node_state cluster_state cap_topo_state announcements
        node_state=$(get_node_state_cached "$instance_ocid")
        cluster_state="N/A"
        [[ "$gpu_mem" != "N/A" ]] && cluster_state=$(get_cluster_state "$gpu_mem")
        cap_topo_state=$(get_capacity_topology_state "$instance_ocid")
        announcements=$(get_resource_announcements "$instance_ocid" "$gpu_mem")
        
        # Truncate for display
        local gpu_mem_display="$gpu_mem"
        [[ "$gpu_mem" != "N/A" && ${#gpu_mem} -gt 12 ]] && gpu_mem_display="...${gpu_mem: -9}"
        
        local cluster_state_display
        cluster_state_display=$(truncate_string "$cluster_state" 12)
        
        # Store for sorting (by GPU mem cluster, then display name)
        echo "${gpu_mem}|${display_name}|${node_name}|${node_state}|${status}|${instance_ocid}|${gpu_mem_display}|${cluster_state_display}|${clique_id}|${cap_topo_state}|${announcements}" >> "$output_temp"
    done < "$oci_temp"
    
    # Sort and display
    sort -t'|' -k1,1 -k2,2 "$output_temp" | while IFS='|' read -r _ dn nn ns st io gm cs ci ct ann; do
        local ns_color st_color ct_color ann_color
        ns_color=$(color_node_state "$ns")
        st_color=$(color_oci_state "$st")
        ct_color=$(color_cap_topo_state "$ct")
        ann_color=$(color_announcement "$ann")
        
        printf "%-28s %-15s ${ns_color}%-11s${NC} ${st_color}%-10s${NC} %-95s %-12s %-12s %-40s ${ct_color}%-10s${NC} ${ann_color}%-18s${NC}\n" \
            "$dn" "$nn" "$ns" "$st" "$io" "$gm" "$cs" "$ci" "$ct" "$ann"
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
    
    local joined_temp
    joined_temp=$(create_temp_file) || return 1
    
    # Join OCI and K8s data (oci_temp format: display_name|status|instance_ocid|gpu_mem)
    local display_name status instance_ocid gpu_mem
    while IFS='|' read -r display_name status instance_ocid gpu_mem; do
        [[ -z "$instance_ocid" ]] && continue
        
        local k8s_info
        k8s_info=$(grep "^${instance_ocid}|" "$k8s_temp" 2>/dev/null)
        if [[ -n "$k8s_info" ]]; then
            local node_name clique_id
            IFS='|' read -r _ node_name clique_id <<< "$k8s_info"
            # joined format: display_name|node_name|status|instance_ocid|gpu_mem|clique_id
            echo "${display_name}|${node_name}|${status}|${instance_ocid}|${gpu_mem}|${clique_id}" >> "$joined_temp"
        fi
    done < "$oci_temp"
    
    local unique_cliques
    unique_cliques=$(awk -F'|' '{print $6}' "$joined_temp" | sort -u)
    
    echo -e "${BOLD}${BLUE}=== Summary by GPU Clique ===${NC}"
    echo ""
    
    local summary_temp
    summary_temp=$(create_temp_file) || { rm -f "$joined_temp"; return 1; }
    
    local clique
    while read -r clique; do
        [[ -z "$clique" ]] && continue
        
        local clique_display="$clique"
        [[ "$clique" == "N/A" ]] && clique_display="N/A (No GPU or not in cluster)"
        
        local clique_size
        clique_size=$(grep -c "|${clique}\$" "$joined_temp" 2>/dev/null) || clique_size=0
        
        local clique_entries
        clique_entries=$(grep "|${clique}\$" "$joined_temp")
        
        # Get unique GPU memory clusters for this clique
        declare -A gpu_clusters_count
        declare -A gpu_clusters_fabrics
        declare -A gpu_clusters_states
        declare -A gpu_clusters_instance_configs
        declare -A gpu_clusters_compute_clusters
        
        # joined format: display_name|node_name|status|instance_ocid|gpu_mem|clique_id
        while IFS='|' read -r _ _ _ inst_ocid gm _; do
            # Track GPU memory clusters
            if [[ -n "$gm" && -z "${gpu_clusters_count[$gm]:-}" ]]; then
                gpu_clusters_count[$gm]=1
                if [[ "$gm" != "N/A" ]]; then
                    gpu_clusters_fabrics[$gm]=$(get_fabric_from_cluster "$gm")
                    gpu_clusters_states[$gm]=$(get_cluster_state "$gm")
                    gpu_clusters_instance_configs[$gm]=$(get_instance_config_from_cluster "$gm")
                    gpu_clusters_compute_clusters[$gm]=$(get_compute_cluster_from_gpu_cluster "$gm")
                fi
            elif [[ -n "$gm" ]]; then
                ((gpu_clusters_count[$gm]++))
            fi
        done <<< "$clique_entries"
        
        # Get first cluster info for summary
        local first_gpu_mem
        first_gpu_mem=$(echo "${!gpu_clusters_count[@]}" | tr ' ' '\n' | sort | head -n1)
        
        local fabric_name="N/A"
        local fabric_ocid="N/A"
        local cluster_state="N/A"
        local instance_config_id="N/A"
        local compute_cluster_id="N/A"
        local healthy_hosts="N/A"
        local available_hosts="N/A"
        local total_hosts="N/A"
        
        if [[ -n "$first_gpu_mem" && "$first_gpu_mem" != "N/A" ]]; then
            # Fabric format: DisplayName|Last5Chars|FabricOCID|State|HealthyHosts|AvailableHosts|TotalHosts
            local fabric_line="${gpu_clusters_fabrics[$first_gpu_mem]}"
            IFS='|' read -r fabric_name _ fabric_ocid _ healthy_hosts available_hosts total_hosts <<< "$fabric_line"
            cluster_state="${gpu_clusters_states[$first_gpu_mem]}"
            instance_config_id="${gpu_clusters_instance_configs[$first_gpu_mem]}"
            compute_cluster_id="${gpu_clusters_compute_clusters[$first_gpu_mem]}"
        fi
        
        # Format: clique_display|clique_size|num_clusters|first_gpu_mem|cluster_state|fabric_name|fabric_ocid|instance_config_id|compute_cluster_id|healthy_hosts|available_hosts|total_hosts
        echo "${clique_display}|${clique_size}|${#gpu_clusters_count[@]}|${first_gpu_mem}|${cluster_state}|${fabric_name}|${fabric_ocid}|${instance_config_id}|${compute_cluster_id}|${healthy_hosts}|${available_hosts}|${total_hosts}" >> "$summary_temp"
        
        unset gpu_clusters_count gpu_clusters_fabrics gpu_clusters_states gpu_clusters_instance_configs gpu_clusters_compute_clusters
    done <<< "$unique_cliques"
    
    # Print summary table
    # Clique ID, then counts, then State - GPU Memory Cluster moved to tree below
    printf "${BOLD}%-48s %-6s %-8s %-6s %-6s %-4s %-12s${NC}\n" \
        "Clique ID" "K8s" "Healthy" "Avail" "Total" "#Cl" "State"
    print_separator 96
    
    local clique_id nodes clusters gpu_mem_cluster cluster_state fabric_name fabric_ocid instance_config_id compute_cluster_id healthy_hosts available_hosts total_hosts
    while IFS='|' read -r clique_id nodes clusters gpu_mem_cluster cluster_state fabric_name fabric_ocid instance_config_id compute_cluster_id healthy_hosts available_hosts total_hosts; do
        printf "${CYAN}%-48s${NC} ${GREEN}%-6s${NC} ${YELLOW}%-8s${NC} ${WHITE}%-6s${NC} ${WHITE}%-6s${NC} ${YELLOW}%-4s${NC} ${WHITE}%-12s${NC}\n" \
            "$clique_id" "$nodes" "$healthy_hosts" "$available_hosts" "$total_hosts" "$clusters" "$cluster_state"
        
        # GPU Memory Cluster
        if [[ "$gpu_mem_cluster" != "N/A" && "$gpu_mem_cluster" != "null" && -n "$gpu_mem_cluster" ]]; then
            local gpu_cluster_name
            gpu_cluster_name=$(lookup_cache "$CLUSTER_CACHE" "$gpu_mem_cluster" 2 2>/dev/null || echo "N/A")
            printf "          ${BOLD}${MAGENTA}├─${NC} ${BOLD}${MAGENTA}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "GPU Mem Cluster:" "$gpu_cluster_name" "$gpu_mem_cluster"
        fi
        
        if [[ "$compute_cluster_id" != "N/A" && "$compute_cluster_id" != "null" && -n "$compute_cluster_id" ]]; then
            local compute_cluster_name
            compute_cluster_name=$(get_compute_cluster_name "$compute_cluster_id")
            printf "          ${BOLD}${BLUE}├─${NC} ${BOLD}${BLUE}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "Compute Cluster:" "$compute_cluster_name" "$compute_cluster_id"
        fi
        
        if [[ "$fabric_name" != "N/A" && "$fabric_ocid" != "N/A" ]]; then
            printf "          ${BOLD}${ORANGE}├─${NC} ${BOLD}${ORANGE}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "Fabric:" "$fabric_name" "$fabric_ocid"
        fi
        
        if [[ "$instance_config_id" != "N/A" && "$instance_config_id" != "null" && -n "$instance_config_id" ]]; then
            local instance_config_name
            instance_config_name=$(get_instance_config_name "$instance_config_id")
            printf "          ${BOLD}${GREEN}└─${NC} ${BOLD}${GREEN}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "Instance Config:" "$instance_config_name" "$instance_config_id"
        fi
        echo ""
    done < "$summary_temp"
    
    rm -f "$joined_temp" "$summary_temp"
}

# List all unique cliques with details
list_all_cliques() {
    echo -e "${BOLD}${MAGENTA}=== All GPU Cliques in Kubernetes Cluster ===${NC}"
    echo ""
    
    local cliques
    cliques=$(kubectl get nodes -o json 2>/dev/null | jq -r '.items[].metadata.labels["nvidia.com/gpu.clique"]' | grep -v null | sort -u)
    
    if [[ -z "$cliques" ]]; then
        echo -e "${YELLOW}No GPU cliques found in the cluster${NC}"
        return 0
    fi
    
    local total_cliques
    total_cliques=$(echo "$cliques" | wc -l)
    echo -e "${BOLD}${CYAN}Total Cliques Found:${NC} $total_cliques"
    echo ""
    
    # Fetch OCI data once
    local oci_data
    oci_data=$(create_temp_file) || return 1
    
    log_info "Fetching all instance details from OCI..."
    oci compute instance list \
        --compartment-id "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}" \
        --region "${EFFECTIVE_REGION:-$REGION}" \
        --all \
        --output json 2>/dev/null | jq -r '.data[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")"' > "$oci_data"
    
    # Fetch GPU cluster data for instance config lookup
    fetch_gpu_clusters
    fetch_instance_configurations
    
    local clique_id
    while read -r clique_id; do
        [[ -z "$clique_id" ]] && continue
        
        print_separator 50
        echo -e "${BOLD}${YELLOW}Clique ID:${NC} $clique_id"
        
        local node_count
        node_count=$(kubectl get nodes -o json 2>/dev/null | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
        echo -e "${BOLD}${CYAN}Node Count:${NC} $node_count"
        echo ""
        
        # Get nodes grouped by GPU memory cluster
        declare -A cluster_nodes
        local clique_data
        clique_data=$(kubectl get nodes -o json 2>/dev/null | jq -r --arg clique "$clique_id" '
            .items[] | 
            select(.metadata.labels["nvidia.com/gpu.clique"]==$clique) | 
            "\(.metadata.name)|\(.spec.providerID)"
        ')
        
        local node ocid
        while IFS='|' read -r node ocid; do
            [[ -z "$node" ]] && continue
            
            local gpu_mem_cluster
            gpu_mem_cluster=$(grep "^${ocid}|" "$oci_data" 2>/dev/null | cut -d'|' -f4)
            gpu_mem_cluster="${gpu_mem_cluster:-N/A}"
            
            if [[ -z "${cluster_nodes[$gpu_mem_cluster]:-}" ]]; then
                cluster_nodes[$gpu_mem_cluster]="$node|$ocid"
            else
                cluster_nodes[$gpu_mem_cluster]="${cluster_nodes[$gpu_mem_cluster]}"$'\n'"$node|$ocid"
            fi
        done <<< "$clique_data"
        
        # Display grouped by GPU memory cluster
        local mem_cluster
        for mem_cluster in $(echo "${!cluster_nodes[@]}" | tr ' ' '\n' | sort); do
            local cluster_node_count
            cluster_node_count=$(echo "${cluster_nodes[$mem_cluster]}" | wc -l)
            echo -e "${BOLD}${GREEN}  GPU Mem Cluster: $mem_cluster${NC} ${CYAN}(Nodes: $cluster_node_count)${NC}"
            
            # Show instance configuration for this cluster
            if [[ "$mem_cluster" != "N/A" ]]; then
                local instance_config_id
                instance_config_id=$(get_instance_config_from_cluster "$mem_cluster")
                if [[ "$instance_config_id" != "N/A" && "$instance_config_id" != "null" && -n "$instance_config_id" ]]; then
                    local instance_config_name
                    instance_config_name=$(get_instance_config_name "$instance_config_id")
                    echo -e "    ${BOLD}${YELLOW}Instance Config:${NC} ${WHITE}$instance_config_name${NC}"
                    echo -e "                    ${CYAN}$instance_config_id${NC}"
                fi
            fi
            
            while IFS='|' read -r node ocid; do
                echo -e "    ${WHITE}$node${NC} - ${YELLOW}$ocid${NC}"
            done <<< "${cluster_nodes[$mem_cluster]}"
            echo ""
        done
        
        unset cluster_nodes
    done <<< "$cliques"
    
    rm -f "$oci_data"
    print_separator 50
}

# List cliques summary
list_cliques_summary() {
    echo -e "${BOLD}${MAGENTA}=== GPU Cliques Summary ===${NC}"
    echo ""
    
    local cliques
    cliques=$(kubectl get nodes -o json 2>/dev/null | jq -r '.items[].metadata.labels["nvidia.com/gpu.clique"]' | grep -v null | sort -u)
    
    if [[ -z "$cliques" ]]; then
        echo -e "${YELLOW}No GPU cliques found in the cluster${NC}"
        return 0
    fi
    
    local oci_data
    oci_data=$(create_temp_file) || return 1
    
    log_info "Fetching all instance details from OCI..."
    oci compute instance list \
        --compartment-id "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}" \
        --region "${EFFECTIVE_REGION:-$REGION}" \
        --all \
        --output json 2>/dev/null | jq -r '.data[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")"' > "$oci_data"
    
    # Fetch GPU cluster data for instance config lookup
    fetch_gpu_clusters
    fetch_instance_configurations
    
    echo ""
    printf "${BOLD}%-40s %-15s %-20s${NC}\n" "Clique ID" "Total Nodes" "Memory Clusters"
    print_separator 75
    
    local clique_id
    while read -r clique_id; do
        [[ -z "$clique_id" ]] && continue
        
        local node_count
        node_count=$(kubectl get nodes -o json 2>/dev/null | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
        
        local clique_data
        clique_data=$(kubectl get nodes -o json 2>/dev/null | jq -r --arg clique "$clique_id" '
            .items[] | 
            select(.metadata.labels["nvidia.com/gpu.clique"]==$clique) | 
            .spec.providerID
        ')
        
        declare -A mem_clusters
        declare -A mem_cluster_instance_configs
        local ocid
        while read -r ocid; do
            [[ -z "$ocid" ]] && continue
            local gpu_mem_cluster
            gpu_mem_cluster=$(grep "^${ocid}|" "$oci_data" 2>/dev/null | cut -d'|' -f4)
            gpu_mem_cluster="${gpu_mem_cluster:-N/A}"
            mem_clusters[$gpu_mem_cluster]=1
            if [[ "$gpu_mem_cluster" != "N/A" && -z "${mem_cluster_instance_configs[$gpu_mem_cluster]:-}" ]]; then
                mem_cluster_instance_configs[$gpu_mem_cluster]=$(get_instance_config_from_cluster "$gpu_mem_cluster")
            fi
        done <<< "$clique_data"
        
        local cluster_list
        cluster_list=$(echo "${!mem_clusters[@]}" | tr ' ' '\n' | sort | tr '\n' ',' | sed 's/,$//')
        
        printf "${CYAN}%-40s${NC} ${GREEN}%-15s${NC} ${YELLOW}%-20s${NC}\n" "$clique_id" "$node_count" "$cluster_list"
        
        # Show instance configurations for each cluster
        local mc
        for mc in $(echo "${!mem_clusters[@]}" | tr ' ' '\n' | sort); do
            if [[ "$mc" != "N/A" && -n "${mem_cluster_instance_configs[$mc]:-}" ]]; then
                local ic="${mem_cluster_instance_configs[$mc]}"
                if [[ "$ic" != "N/A" && "$ic" != "null" && -n "$ic" ]]; then
                    local short_mc="...${mc: -12}"
                    local ic_name
                    ic_name=$(get_instance_config_name "$ic")
                    printf "  ${BOLD}${YELLOW}└─ ${short_mc} Instance Config:${NC} ${WHITE}%-40s${NC} ${CYAN}%s${NC}\n" "$ic_name" "$ic"
                fi
            fi
        done
        
        unset mem_clusters mem_cluster_instance_configs
    done <<< "$cliques"
    
    rm -f "$oci_data"
}

# Get detailed node info for a specific instance
get_node_info() {
    local instance_id="$1"
    local show_labels="$2"
    local show_clique="$3"
    local count_clique="$4"
    
    # Fetch all required cache data upfront
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_instance_configurations
    fetch_node_states
    fetch_capacity_topology
    build_announcement_lookup "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    
    # Get Kubernetes node info
    local node_json
    node_json=$(kubectl get nodes -o json 2>/dev/null)
    
    local node_name
    node_name=$(echo "$node_json" | jq -r --arg id "$instance_id" '.items[] | select(.spec.providerID==$id) | .metadata.name')
    
    if [[ -z "$node_name" ]]; then
        log_error "Could not find Kubernetes node for instance OCID: $instance_id"
        return 1
    fi
    
    # Get OCI instance details
    log_info "Fetching OCI instance details..."
    local oci_instance_json
    oci_instance_json=$(oci compute instance get --instance-id "$instance_id" --output json 2>/dev/null)
    
    if [[ -z "$oci_instance_json" ]]; then
        log_error "Failed to fetch OCI instance details"
        return 1
    fi
    
    # Extract OCI instance fields
    local display_name oci_state shape ad fault_domain gpu_memory_cluster time_created
    display_name=$(echo "$oci_instance_json" | jq -r '.data["display-name"] // "N/A"')
    oci_state=$(echo "$oci_instance_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    shape=$(echo "$oci_instance_json" | jq -r '.data.shape // "N/A"')
    ad=$(echo "$oci_instance_json" | jq -r '.data["availability-domain"] // "N/A"')
    fault_domain=$(echo "$oci_instance_json" | jq -r '.data["fault-domain"] // "N/A"')
    gpu_memory_cluster=$(echo "$oci_instance_json" | jq -r '.data["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A"')
    time_created=$(echo "$oci_instance_json" | jq -r '.data["time-created"] // "N/A"')
    
    # Extract Kubernetes node fields
    local node_data
    node_data=$(echo "$node_json" | jq --arg name "$node_name" '.items[] | select(.metadata.name==$name)')
    
    local node_state clique_id gpu_count gpu_product gpu_memory
    local kubelet_version os_image kernel_version container_runtime
    node_state=$(get_node_state_cached "$instance_id")
    clique_id=$(echo "$node_data" | jq -r '.metadata.labels["nvidia.com/gpu.clique"] // "N/A"')
    gpu_count=$(echo "$node_data" | jq -r '.status.capacity["nvidia.com/gpu"] // "N/A"')
    gpu_product=$(echo "$node_data" | jq -r '.metadata.labels["nvidia.com/gpu.product"] // "N/A"')
    gpu_memory=$(echo "$node_data" | jq -r '.metadata.labels["nvidia.com/gpu.memory"] // "N/A"')
    kubelet_version=$(echo "$node_data" | jq -r '.status.nodeInfo.kubeletVersion // "N/A"')
    os_image=$(echo "$node_data" | jq -r '.status.nodeInfo.osImage // "N/A"')
    kernel_version=$(echo "$node_data" | jq -r '.status.nodeInfo.kernelVersion // "N/A"')
    container_runtime=$(echo "$node_data" | jq -r '.status.nodeInfo.containerRuntimeVersion // "N/A"')
    
    # Get additional states
    local cap_topo_state announcements
    cap_topo_state=$(get_capacity_topology_state "$instance_id")
    announcements=$(get_resource_announcements "$instance_id" "$gpu_memory_cluster")
    
    # Get GPU memory cluster and fabric details
    local cluster_state="N/A"
    local instance_config_id="N/A"
    local fabric_name="N/A" fabric_ocid="N/A" fabric_state="N/A"
    local fabric_healthy_hosts="N/A" fabric_avail_hosts="N/A" fabric_total_hosts="N/A"
    
    if [[ "$gpu_memory_cluster" != "N/A" && "$gpu_memory_cluster" != "null" ]]; then
        cluster_state=$(get_cluster_state "$gpu_memory_cluster")
        instance_config_id=$(get_instance_config_from_cluster "$gpu_memory_cluster")
        local fabric_info
        fabric_info=$(get_fabric_from_cluster "$gpu_memory_cluster")
        # Format: DisplayName|Last5Chars|FabricOCID|State|HealthyHosts|AvailableHosts|TotalHosts
        IFS='|' read -r fabric_name _ fabric_ocid fabric_state fabric_healthy_hosts fabric_avail_hosts fabric_total_hosts <<< "$fabric_info"
    fi
    
    # Get clique size
    local clique_size="N/A"
    if [[ "$clique_id" != "N/A" && "$clique_id" != "null" ]]; then
        clique_size=$(echo "$node_json" | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
    fi
    
    echo ""
    
    # Display header
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║                           INSTANCE DETAILS                                   ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # OCI Instance section
    echo -e "${BOLD}${CYAN}=== OCI Instance ===${NC}"
    echo -e "  ${WHITE}Display Name:${NC}      $display_name"
    echo -e "  ${WHITE}Instance OCID:${NC}     ${YELLOW}$instance_id${NC}"
    echo -e "  ${WHITE}Shape:${NC}             $shape"
    echo -e "  ${WHITE}Availability Domain:${NC} $ad"
    echo -e "  ${WHITE}Fault Domain:${NC}      $fault_domain"
    echo -e "  ${WHITE}Created:${NC}           $time_created"
    
    local oci_state_color
    oci_state_color=$(color_oci_state "$oci_state")
    echo -e "  ${WHITE}OCI State:${NC}         ${oci_state_color}${oci_state}${NC}"
    echo ""
    
    # Kubernetes Node section
    echo -e "${BOLD}${CYAN}=== Kubernetes Node ===${NC}"
    echo -e "  ${WHITE}Node Name:${NC}         ${GREEN}$node_name${NC}"
    
    local node_state_color
    node_state_color=$(color_node_state "$node_state")
    echo -e "  ${WHITE}Node State:${NC}        ${node_state_color}${node_state}${NC}"
    
    echo -e "  ${WHITE}Kubelet Version:${NC}   $kubelet_version"
    echo -e "  ${WHITE}OS Image:${NC}          $os_image"
    echo -e "  ${WHITE}Kernel:${NC}            $kernel_version"
    echo -e "  ${WHITE}Container Runtime:${NC} $container_runtime"
    echo ""
    
    # GPU Information section
    echo -e "${BOLD}${CYAN}=== GPU Information ===${NC}"
    echo -e "  ${WHITE}GPU Count:${NC}         $gpu_count"
    echo -e "  ${WHITE}GPU Product:${NC}       $gpu_product"
    echo -e "  ${WHITE}GPU Memory:${NC}        $gpu_memory MB"
    echo -e "  ${WHITE}GPU Clique ID:${NC}     ${YELLOW}$clique_id${NC}"
    echo -e "  ${WHITE}Clique Size:${NC}       $clique_size nodes"
    echo ""
    
    # GPU Memory Cluster section
    echo -e "${BOLD}${CYAN}=== GPU Memory Cluster ===${NC}"
    if [[ "$gpu_memory_cluster" != "N/A" && "$gpu_memory_cluster" != "null" ]]; then
        echo -e "  ${WHITE}Cluster OCID:${NC}      ${YELLOW}$gpu_memory_cluster${NC}"
        
        local cluster_state_color
        cluster_state_color=$(color_cluster_state "$cluster_state")
        echo -e "  ${WHITE}Cluster State:${NC}     ${cluster_state_color}${cluster_state}${NC}"
        
        if [[ "$instance_config_id" != "N/A" && "$instance_config_id" != "null" && -n "$instance_config_id" ]]; then
            local instance_config_name
            instance_config_name=$(get_instance_config_name "$instance_config_id")
            echo -e "  ${WHITE}Instance Config:${NC}   ${WHITE}$instance_config_name${NC}"
            echo -e "                     ${CYAN}$instance_config_id${NC}"
        fi
    else
        echo -e "  ${YELLOW}No GPU Memory Cluster assigned${NC}"
    fi
    echo ""
    
    # GPU Memory Fabric section
    echo -e "${BOLD}${CYAN}=== GPU Memory Fabric ===${NC}"
    if [[ "$fabric_name" != "N/A" ]]; then
        echo -e "  ${WHITE}Fabric Name:${NC}       $fabric_name"
        echo -e "  ${WHITE}Fabric OCID:${NC}       ${YELLOW}$fabric_ocid${NC}"
        
        local fabric_state_color
        fabric_state_color=$(color_fabric_state "$fabric_state")
        echo -e "  ${WHITE}Fabric State:${NC}      ${fabric_state_color}${fabric_state}${NC}"
        
        echo -e "  ${WHITE}Healthy Hosts:${NC}     ${YELLOW}${fabric_healthy_hosts}${NC}"
        echo -e "  ${WHITE}Available Hosts:${NC}   ${fabric_avail_hosts}"
        echo -e "  ${WHITE}Total Hosts:${NC}       ${fabric_total_hosts}"
    else
        echo -e "  ${YELLOW}No GPU Memory Fabric information available${NC}"
    fi
    echo ""
    
    # Capacity Topology section
    echo -e "${BOLD}${CYAN}=== Capacity Topology ===${NC}"
    local cap_topo_color
    cap_topo_color=$(color_cap_topo_state "$cap_topo_state")
    echo -e "  ${WHITE}Host Status:${NC}       ${cap_topo_color}${cap_topo_state}${NC}"
    echo ""
    
    # Announcements section
    echo -e "${BOLD}${CYAN}=== Announcements ===${NC}"
    if [[ "$announcements" != "-" ]]; then
        echo -e "  ${WHITE}Active Tickets:${NC}    ${RED}${announcements}${NC}"
        
        # Show details for each announcement
        local ticket
        for ticket in ${announcements//,/ }; do
            local detail_file
            for detail_file in "$CACHE_DIR"/*.json; do
                [[ ! -f "$detail_file" ]] && continue
                [[ "$detail_file" == "$ANNOUNCEMENTS_LIST_CACHE" ]] && continue
                [[ "$detail_file" == *"/ack_status_cache.json" ]] && continue
                
                local ref_ticket
                ref_ticket=$(jq -r '.data."reference-ticket-number" // ""' "$detail_file" 2>/dev/null)
                if [[ "${ref_ticket:0:8}" == "$ticket" ]]; then
                    local ann_summary ann_type ann_time
                    ann_summary=$(jq -r '.data.summary // "N/A"' "$detail_file")
                    ann_type=$(jq -r '.data."announcement-type" // "N/A"' "$detail_file")
                    ann_time=$(jq -r '.data."time-one-value" // "N/A"' "$detail_file")
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
    
    # Optional: Show Labels
    if [[ "$show_labels" == "true" ]]; then
        echo -e "${BOLD}${CYAN}=== All Kubernetes Labels ===${NC}"
        echo "$node_data" | jq -r '.metadata.labels | to_entries | sort_by(.key) | .[] | "  \(.key): \(.value)"'
        echo ""
        
        echo -e "${BOLD}${CYAN}=== GPU Labels Only ===${NC}"
        echo "$node_data" | jq -r '.metadata.labels | to_entries | map(select(.key | contains("nvidia.com/gpu"))) | sort_by(.key) | .[] | "  \(.key): \(.value)"'
        echo ""
    fi
    
    # Optional: Count Clique Members
    if [[ "$count_clique" == "true" && "$clique_id" != "N/A" && "$clique_id" != "null" ]]; then
        echo -e "${BOLD}${CYAN}=== Nodes in Same Clique (${clique_id}) ===${NC}"
        echo ""
        
        local clique_nodes
        clique_nodes=$(echo "$node_json" | jq -r --arg clique "$clique_id" '
            .items[] | 
            select(.metadata.labels["nvidia.com/gpu.clique"]==$clique) | 
            "\(.metadata.name)|\(.spec.providerID)"
        ')
        
        local oci_data
        oci_data=$(create_temp_file) || return 0
        
        oci compute instance list \
            --compartment-id "${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}" \
            --region "${EFFECTIVE_REGION:-$REGION}" \
            --all \
            --output json 2>/dev/null | jq -r '.data[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")"' > "$oci_data"
        
        # Group by GPU memory cluster
        declare -A cluster_nodes
        local node ocid
        while IFS='|' read -r node ocid; do
            [[ -z "$node" ]] && continue
            
            local mem_cluster
            mem_cluster=$(grep "^${ocid}|" "$oci_data" 2>/dev/null | cut -d'|' -f4)
            mem_cluster="${mem_cluster:-N/A}"
            
            if [[ -z "${cluster_nodes[$mem_cluster]:-}" ]]; then
                cluster_nodes[$mem_cluster]="$node|$ocid"
            else
                cluster_nodes[$mem_cluster]="${cluster_nodes[$mem_cluster]}"$'\n'"$node|$ocid"
            fi
        done <<< "$clique_nodes"
        
        # Display grouped by GPU memory cluster
        local mem_cluster
        for mem_cluster in $(echo "${!cluster_nodes[@]}" | tr ' ' '\n' | sort); do
            local cluster_node_count
            cluster_node_count=$(echo "${cluster_nodes[$mem_cluster]}" | wc -l)
            local short_cluster="...${mem_cluster: -9}"
            [[ "$mem_cluster" == "N/A" ]] && short_cluster="N/A"
            
            echo -e "  ${BOLD}${BLUE}GPU Memory Cluster: ${short_cluster}${NC} (${cluster_node_count} nodes)"
            
            # Show instance configuration for this cluster
            if [[ "$mem_cluster" != "N/A" ]]; then
                local ic
                ic=$(get_instance_config_from_cluster "$mem_cluster")
                if [[ "$ic" != "N/A" && "$ic" != "null" && -n "$ic" ]]; then
                    local ic_name
                    ic_name=$(get_instance_config_name "$ic")
                    echo -e "    ${BOLD}${YELLOW}Instance Config:${NC} ${WHITE}$ic_name${NC}"
                    echo -e "                    ${CYAN}$ic${NC}"
                fi
            fi
            
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
    
    # Validate parameters
    [[ -z "$gpu_cluster" ]] && { log_error "GPU cluster ID required"; return 1; }
    [[ -z "$compartment_id" ]] && { log_error "COMPARTMENT_ID not set"; return 1; }
    [[ -z "$region" ]] && { log_error "REGION not set"; return 1; }
    
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_instance_configurations
    fetch_node_states
    fetch_capacity_topology
    build_announcement_lookup "$compartment_id"
    
    echo -e "${BOLD}${MAGENTA}=== Instances in GPU Memory Cluster ===${NC}"
    echo -e "${CYAN}GPU Memory Cluster:${NC} $gpu_cluster"
    echo -e "${CYAN}Compartment:${NC} $compartment_id"
    echo -e "${CYAN}Region:${NC} $region"
    echo ""
    
    local cluster_state
    cluster_state=$(get_cluster_state "$gpu_cluster")
    local cluster_state_color
    cluster_state_color=$(color_cluster_state "$cluster_state")
    echo -e "${CYAN}Cluster State:${NC} ${cluster_state_color}${cluster_state}${NC}"
    
    # Get and display instance configuration
    local instance_config_id
    instance_config_id=$(get_instance_config_from_cluster "$gpu_cluster")
    if [[ "$instance_config_id" != "N/A" && "$instance_config_id" != "null" && -n "$instance_config_id" ]]; then
        local instance_config_name
        instance_config_name=$(get_instance_config_name "$instance_config_id")
        echo -e "${CYAN}Instance Configuration:${NC} ${WHITE}$instance_config_name${NC}"
        echo -e "                        ${YELLOW}$instance_config_id${NC}"
    fi
    
    local fabric_info
    fabric_info=$(get_fabric_from_cluster "$gpu_cluster")
    # Format: DisplayName|Last5Chars|FabricOCID|State|HealthyHosts|AvailableHosts|TotalHosts
    local fabric_name fabric_suffix fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts
    IFS='|' read -r fabric_name fabric_suffix fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts <<< "$fabric_info"
    
    if [[ "$fabric_name" != "N/A" ]]; then
        echo ""
        echo -e "${BOLD}${GREEN}=== GPU Memory Fabric ===${NC}"
        echo -e "${CYAN}Fabric Name:${NC}     $fabric_name"
        echo -e "${CYAN}Fabric OCID:${NC}     $fabric_ocid"
        local fabric_state_color
        fabric_state_color=$(color_fabric_state "$fabric_state")
        echo -e "${CYAN}Fabric State:${NC}    ${fabric_state_color}${fabric_state}${NC}"
        echo -e "${CYAN}Healthy Hosts:${NC}   ${YELLOW}${healthy_hosts}${NC}"
        echo -e "${CYAN}Available Hosts:${NC} ${avail_hosts}"
        echo -e "${CYAN}Total Hosts:${NC}     ${total_hosts}"
    fi
    
    echo ""
    
    local oci_data k8s_data
    oci_data=$(create_temp_file) || return 1
    k8s_data=$(create_temp_file) || { rm -f "$oci_data"; return 1; }
    
    log_info "Fetching instance details from OCI..."
    oci compute instance list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json 2>/dev/null | jq -r '.data[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")"' > "$oci_data"
    
    log_info "Fetching Kubernetes node data..."
    kubectl get nodes -l nvidia.com/gpu.present=true -o json 2>/dev/null | jq -r '
        .items[] | 
        "\(.spec.providerID)|\(.metadata.name)|\(.metadata.labels["nvidia.com/gpu.clique"] // "N/A")"
    ' > "$k8s_data"
    
    echo ""
    
    # Print table header
    printf "${BOLD}%-28s %-18s %-11s %-10s %-95s %-40s %-10s %-18s${NC}\n" \
        "Display Name" "K8s Node" "Node State" "OCI State" "Instance OCID" "Clique ID" "CapTopo" "Announce"
    print_separator 240
    
    # Process instances in this cluster
    local instance_id display_name oci_state gpu_mem
    grep "|${gpu_cluster}\$" "$oci_data" 2>/dev/null | while IFS='|' read -r instance_id display_name oci_state gpu_mem; do
        local k8s_info
        k8s_info=$(grep "^${instance_id}|" "$k8s_data" 2>/dev/null)
        [[ -z "$k8s_info" ]] && continue
        
        local node_name clique_id
        IFS='|' read -r _ node_name clique_id <<< "$k8s_info"
        
        local node_state cap_topo_state announcements
        node_state=$(get_node_state_cached "$instance_id")
        cap_topo_state=$(get_capacity_topology_state "$instance_id")
        announcements=$(get_resource_announcements "$instance_id" "$gpu_mem")
        
        # Get colors
        local ns_color st_color ct_color ann_color
        ns_color=$(color_node_state "$node_state")
        st_color=$(color_oci_state "$oci_state")
        ct_color=$(color_cap_topo_state "$cap_topo_state")
        ann_color=$(color_announcement "$announcements")
        
        printf "%-28s %-18s ${ns_color}%-11s${NC} ${st_color}%-10s${NC} %-95s %-40s ${ct_color}%-10s${NC} ${ann_color}%-18s${NC}\n" \
            "$display_name" "$node_name" "$node_state" "$oci_state" "$instance_id" "$clique_id" "$cap_topo_state" "$announcements"
    done
    
    echo ""
    
    # Count total instances
    local total_count k8s_count
    total_count=$(grep -c "|${gpu_cluster}\$" "$oci_data" 2>/dev/null) || total_count=0
    k8s_count=$(grep "|${gpu_cluster}\$" "$oci_data" 2>/dev/null | while IFS='|' read -r id _ _ _; do
        grep -q "^${id}|" "$k8s_data" 2>/dev/null && echo "1"
    done | wc -l)
    
    echo -e "${CYAN}Total Instances:${NC} $total_count (${k8s_count} in Kubernetes)"
    
    rm -f "$oci_data" "$k8s_data"
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
    echo -e "${BOLD}Instance Options:${NC}"
    echo "  --labels           Show all labels for the node"
    echo "  --clique           Show GPU clique information, OCI tags, cluster state, and fabric details"
    echo "  --count-clique     Count and list all nodes in the same clique with OCI tags and fabric info"
    echo "  --all              Show everything (labels + clique + count + OCI tags + fabric)"
    echo "  --console-history  Capture and display console history for the instance"
    echo "                     Useful for debugging instances that fail to join Kubernetes"
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
    echo -e "${BOLD}Interactive Features:${NC}"
    echo "  When listing GPU instances, if orphan instances (running in OCI but not in K8s)"
    echo "  are found, you will be prompted to select one to view its console history."
    echo "  This helps diagnose why an instance failed to join the Kubernetes cluster."
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
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --console-history  # View console history"
    echo "  $0 --list-cluster ocid1.xxx                           # List cluster instances + fabric"
}

#===============================================================================
# MAIN
#===============================================================================

main() {
    # Check dependencies first
    check_dependencies || exit 1
    
    # Source variables file
    if [[ -f "$SCRIPT_DIR/variables.sh" ]]; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/variables.sh"
    elif [[ -f "./variables.sh" ]]; then
        # shellcheck source=/dev/null
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
    
    # Set effective values (global scope for other functions)
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
            if [[ -z "${2:-}" ]]; then
                log_error "GPU cluster ID required"
                echo "Usage: $0 --list-cluster <gpu-cluster-id>"
                exit 1
            fi
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
            local show_console_history="false"
            
            shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
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
                        show_clique="true"
                        shift
                        ;;
                    --all)
                        show_labels="true"
                        show_clique="true"
                        count_clique="true"
                        shift
                        ;;
                    --console-history)
                        show_console_history="true"
                        shift
                        ;;
                    *)
                        log_error "Unknown option: $1"
                        exit 1
                        ;;
                esac
            done
            
            if [[ "$show_console_history" == "true" ]]; then
                get_console_history "$instance_id"
            else
                get_node_info "$instance_id" "$show_labels" "$show_clique" "$count_clique"
            fi
            ;;
    esac
}

# Run main function
main "$@"