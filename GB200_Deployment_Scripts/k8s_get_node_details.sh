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
#   Optional: OKE_CLUSTER_ID to specify which OKE cluster to manage
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
readonly GRAY='\033[0;90m'
readonly ORANGE='\033[38;5;208m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Cache settings
readonly CACHE_MAX_AGE=3600  # 1 hour in seconds

# Script directory and cache paths
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CACHE_DIR="${HOME}/cache"

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

# Network gateway cache files
readonly IGW_CACHE="${CACHE_DIR}/internet_gateways.txt"
readonly SGW_CACHE="${CACHE_DIR}/service_gateways.txt"
readonly NAT_CACHE="${CACHE_DIR}/nat_gateways.txt"
readonly DRG_CACHE="${CACHE_DIR}/drg_attachments.txt"
readonly LPG_CACHE="${CACHE_DIR}/local_peering_gateways.txt"
readonly RPC_CACHE="${CACHE_DIR}/remote_peering_connections.txt"
readonly RT_CACHE="${CACHE_DIR}/route_tables.txt"
readonly NSG_RULES_CACHE="${CACHE_DIR}/nsg_rules.txt"
readonly SL_CACHE="${CACHE_DIR}/security_lists.txt"

# Known shortnames for subnets and NSGs
readonly NETWORK_SHORTNAMES=("bastion" "cp" "operator" "int_lb" "pub_lb" "pods" "workers" "fss" "lustre")

# Global associative arrays for lookups (must use declare -gA for global scope)
declare -gA INSTANCE_ANNOUNCEMENTS
declare -gA GPU_MEM_CLUSTER_ANNOUNCEMENTS

# Global arrays for interactive GPU management selection
declare -gA FABRIC_INDEX_MAP      # f1 -> fabric_ocid
declare -gA CLUSTER_INDEX_MAP     # g1 -> cluster_ocid
declare -gA IC_INDEX_MAP          # i1 -> instance_config_ocid
declare -gA CC_INDEX_MAP          # c1 -> compute_cluster_ocid

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

# Refresh all cache files
refresh_all_caches() {
    echo -e "${BOLD}${CYAN}Refreshing all caches...${NC}"
    
    # List of all cache files
    local cache_files=(
        "$FABRIC_CACHE"
        "$CLUSTER_CACHE"
        "$INSTANCE_CONFIG_CACHE"
        "$NODE_STATE_CACHE"
        "$CAPACITY_TOPOLOGY_CACHE"
        "$ANNOUNCEMENTS_LIST_CACHE"
        "$OKE_ENV_CACHE"
        "$COMPUTE_CLUSTER_CACHE"
        "$NETWORK_RESOURCES_CACHE"
        "$IGW_CACHE"
        "$SGW_CACHE"
        "$NAT_CACHE"
        "$DRG_CACHE"
        "$LPG_CACHE"
        "$RPC_CACHE"
        "$RT_CACHE"
        "$NSG_RULES_CACHE"
        "$SL_CACHE"
    )
    
    local removed_count=0
    for cache_file in "${cache_files[@]}"; do
        if [[ -f "$cache_file" ]]; then
            rm -f "$cache_file"
            ((removed_count++))
        fi
    done
    
    echo -e "${GREEN}✓${NC} Removed ${removed_count} cache file(s) from ${CACHE_DIR}"
    echo ""
    echo -e "${WHITE}Cache will be refreshed on next command execution.${NC}"
    echo -e "${GRAY}Tip: Run without arguments to refresh and list all instances${NC}"
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
        echo "# Format: DisplayName|Last5Chars|FabricOCID|State|HealthyHosts|AvailableHosts|TotalHosts|CurrentFirmware|TargetFirmware|FirmwareUpdateState"
        jq -r '.data.items[] | "\(.["display-name"])|\(.id[-5:] | ascii_downcase)|\(.id)|\(.["lifecycle-state"])|\(.["healthy-host-count"] // 0)|\(.["available-host-count"] // 0)|\(.["total-host-count"] // 0)|\(.["current-firmware-bundle-id"] // "N/A")|\(.["target-firmware-bundle-id"] // "N/A")|\(.["firmware-update-state"] // "N/A")"' "$raw_json" 2>/dev/null
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
        echo "# Format: ClusterOCID|DisplayName|State|FabricSuffix|InstanceConfigurationId|ComputeClusterId|Size"
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
                # Try gpu-memory-fabric-id first, then fallback to extracting from display name
                jq -r '
                    .data["display-name"] as $name |
                    (.data["gpu-memory-fabric-id"] // "") as $fabric_id |
                    (if $fabric_id != "" and $fabric_id != null then 
                        ($fabric_id[-5:] | ascii_downcase)
                     else 
                        (($name | capture("fabric-(?<suffix>[a-z0-9]{5})") // {suffix: ""}).suffix)
                     end) as $fabric_suffix |
                    "\(.data.id)|\($name)|\(.data["lifecycle-state"])|\($fabric_suffix)|\(.data["instance-configuration-id"] // "N/A")|\(.data["compute-cluster-id"] // "N/A")|\(.data["size"] // 0)"
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
    
    # Check if OKE_CLUSTER_ID from variables.sh differs from cached value
    # If so, we need to refresh the cache
    local configured_cluster_id="${OKE_CLUSTER_ID:-}"
    local cached_cluster_id=""
    
    if [[ -f "$OKE_ENV_CACHE" ]]; then
        cached_cluster_id=$(grep "^OKE_CLUSTER_ID|" "$OKE_ENV_CACHE" 2>/dev/null | cut -d'|' -f2)
    fi
    
    # Invalidate cache if configured cluster differs from cached
    if [[ -n "$configured_cluster_id" && "$configured_cluster_id" != "N/A" && "$configured_cluster_id" != "$cached_cluster_id" ]]; then
        log_info "OKE_CLUSTER_ID changed, refreshing cache..."
        rm -f "$OKE_ENV_CACHE"
    fi
    
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
    
    # Get OKE cluster info
    # Priority: 1) OKE_CLUSTER_ID from variables.sh, 2) Auto-discover first active cluster
    local cluster_json
    local cluster_name cluster_ocid cluster_state cluster_version pod_network vcn_ocid
    
    if [[ -n "$configured_cluster_id" && "$configured_cluster_id" != "N/A" ]]; then
        # Use specific cluster from variables.sh
        log_info "Using OKE_CLUSTER_ID from variables.sh: $configured_cluster_id"
        cluster_json=$(oci ce cluster get --cluster-id "$configured_cluster_id" --output json 2>/dev/null)
        
        if [[ -n "$cluster_json" ]]; then
            cluster_name=$(echo "$cluster_json" | jq -r '.data.name // "N/A"')
            cluster_ocid=$(echo "$cluster_json" | jq -r '.data.id // "N/A"')
            cluster_state=$(echo "$cluster_json" | jq -r '.data["lifecycle-state"] // "N/A"')
            cluster_version=$(echo "$cluster_json" | jq -r '.data["kubernetes-version"] // "N/A"')
            pod_network=$(echo "$cluster_json" | jq -r '.data["cluster-pod-network-options"][0]["cni-type"] // "N/A"')
            vcn_ocid=$(echo "$cluster_json" | jq -r '.data["vcn-id"] // "N/A"')
        else
            log_warn "Failed to fetch cluster with OKE_CLUSTER_ID from variables.sh, falling back to auto-discovery"
            # List to find cluster ID, then get full details
            cluster_json=$(oci ce cluster list --compartment-id "$compartment_id" --region "$region" --lifecycle-state ACTIVE --limit 1 --output json 2>/dev/null)
            cluster_ocid=$(echo "$cluster_json" | jq -r '.data[0].id // "N/A"')
            
            # Fetch full details using cluster get
            if [[ "$cluster_ocid" != "N/A" && -n "$cluster_ocid" ]]; then
                cluster_json=$(oci ce cluster get --cluster-id "$cluster_ocid" --output json 2>/dev/null)
                cluster_name=$(echo "$cluster_json" | jq -r '.data.name // "N/A"')
                cluster_state=$(echo "$cluster_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                cluster_version=$(echo "$cluster_json" | jq -r '.data["kubernetes-version"] // "N/A"')
                pod_network=$(echo "$cluster_json" | jq -r '.data["cluster-pod-network-options"][0]["cni-type"] // "N/A"')
                vcn_ocid=$(echo "$cluster_json" | jq -r '.data["vcn-id"] // "N/A"')
            fi
        fi
    else
        # Auto-discover first active cluster - list to find ID, then get full details
        cluster_json=$(oci ce cluster list --compartment-id "$compartment_id" --region "$region" --lifecycle-state ACTIVE --limit 1 --output json 2>/dev/null)
        cluster_ocid=$(echo "$cluster_json" | jq -r '.data[0].id // "N/A"')
        
        # Fetch full details using cluster get (includes kubernetes-version)
        if [[ "$cluster_ocid" != "N/A" && -n "$cluster_ocid" ]]; then
            cluster_json=$(oci ce cluster get --cluster-id "$cluster_ocid" --output json 2>/dev/null)
            cluster_name=$(echo "$cluster_json" | jq -r '.data.name // "N/A"')
            cluster_state=$(echo "$cluster_json" | jq -r '.data["lifecycle-state"] // "N/A"')
            cluster_version=$(echo "$cluster_json" | jq -r '.data["kubernetes-version"] // "N/A"')
            pod_network=$(echo "$cluster_json" | jq -r '.data["cluster-pod-network-options"][0]["cni-type"] // "N/A"')
            vcn_ocid=$(echo "$cluster_json" | jq -r '.data["vcn-id"] // "N/A"')
        else
            cluster_name="N/A"
            cluster_state="N/A"
            cluster_version="N/A"
            pod_network="N/A"
            vcn_ocid="N/A"
        fi
    fi
    
    # Get cluster addons/plugins if we have a cluster OCID
    local cluster_addons=""
    if [[ "$cluster_ocid" != "N/A" && "$cluster_ocid" != "null" && -n "$cluster_ocid" ]]; then
        # Use OCI CE cluster list-addons to get installed addons
        local addons_json
        addons_json=$(oci ce cluster list-addons --cluster-id "$cluster_ocid" --all 2>/dev/null)
        
        if [[ -n "$addons_json" ]]; then
            # Extract active addon names with versions and join with commas
            local addon_lines
            addon_lines=$(echo "$addons_json" | jq -r '.data[] | select(.["lifecycle-state"] == "ACTIVE") | .name + " (" + (.["current-installed-version"] // "N/A") + ")"' 2>/dev/null)
            
            if [[ -n "$addon_lines" ]]; then
                # Join lines with ", "
                cluster_addons=$(echo "$addon_lines" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
            else
                cluster_addons="None installed"
            fi
        else
            cluster_addons="Unable to retrieve"
        fi
    fi
    [[ -z "$cluster_addons" ]] && cluster_addons="N/A"
    
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
        echo "OKE_CLUSTER_ID|${cluster_ocid}"
        echo "CLUSTER_STATE|${cluster_state}"
        echo "CLUSTER_VERSION|${cluster_version}"
        echo "CLUSTER_ADDONS|${cluster_addons}"
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
        echo "# Format: SUBNET|NAME|CIDR|ACCESS|STATE|OCID|RT_OCID|SL_IDS"
        echo "# Format: NSG|NAME||STATE|OCID"
        
        # Process subnets (include route-table-id and security-list-ids)
        echo "$subnet_json" | jq -r '.data[] | "SUBNET|\(."display-name" // "N/A")|\(."cidr-block" // "N/A")|\(if ."prohibit-public-ip-on-vnic" then "Private" else "Public" end)|\(."lifecycle-state" // "N/A")|\(.id // "N/A")|\(."route-table-id" // "N/A")|\((."security-list-ids" // []) | join(","))"' 2>/dev/null
        
        # Process NSGs
        echo "$nsg_json" | jq -r '.data[] | "NSG|\(."display-name" // "N/A")||\(."lifecycle-state" // "N/A")|\(.id // "N/A")"' 2>/dev/null
    } > "$NETWORK_RESOURCES_CACHE"
}

#===============================================================================
# NETWORK GATEWAY FUNCTIONS
#===============================================================================

# Fetch and cache Internet Gateways
fetch_internet_gateways() {
    local compartment_id="$1"
    local vcn_ocid="$2"
    
    is_cache_fresh "$IGW_CACHE" && return 0
    
    log_info "Fetching Internet Gateways..."
    
    local result
    result=$(oci network internet-gateway list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_ocid" \
        --all \
        --output json 2>/dev/null) || { touch "$IGW_CACHE"; return 1; }
    
    # Cache format: VCN_ID|IGW_ID|STATE|DISPLAY_NAME
    echo "$result" | jq -r '.data[] | "\(.["vcn-id"])|\(.id)|\(.["lifecycle-state"])|\(.["display-name"] // "N/A")"' > "$IGW_CACHE" 2>/dev/null
    [[ ! -s "$IGW_CACHE" ]] && touch "$IGW_CACHE"
}

# Fetch and cache Service Gateways
fetch_service_gateways() {
    local compartment_id="$1"
    local vcn_ocid="$2"
    
    is_cache_fresh "$SGW_CACHE" && return 0
    
    log_info "Fetching Service Gateways..."
    
    local result
    result=$(oci network service-gateway list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_ocid" \
        --all \
        --output json 2>/dev/null) || { touch "$SGW_CACHE"; return 1; }
    
    # Cache format: VCN_ID|SGW_ID|STATE|DISPLAY_NAME
    echo "$result" | jq -r '.data[] | "\(.["vcn-id"])|\(.id)|\(.["lifecycle-state"])|\(.["display-name"] // "N/A")"' > "$SGW_CACHE" 2>/dev/null
    [[ ! -s "$SGW_CACHE" ]] && touch "$SGW_CACHE"
}

# Fetch and cache NAT Gateways
fetch_nat_gateways() {
    local compartment_id="$1"
    local vcn_ocid="$2"
    
    is_cache_fresh "$NAT_CACHE" && return 0
    
    log_info "Fetching NAT Gateways..."
    
    local result
    result=$(oci network nat-gateway list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_ocid" \
        --all \
        --output json 2>/dev/null) || { touch "$NAT_CACHE"; return 1; }
    
    # Cache format: VCN_ID|NAT_ID|STATE|DISPLAY_NAME
    echo "$result" | jq -r '.data[] | "\(.["vcn-id"])|\(.id)|\(.["lifecycle-state"])|\(.["display-name"] // "N/A")"' > "$NAT_CACHE" 2>/dev/null
    [[ ! -s "$NAT_CACHE" ]] && touch "$NAT_CACHE"
}

# Fetch and cache DRG Attachments
fetch_drg_attachments() {
    local compartment_id="$1"
    
    is_cache_fresh "$DRG_CACHE" && return 0
    
    log_info "Fetching DRG Attachments..."
    
    local result
    result=$(oci network drg-attachment list \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>/dev/null) || { touch "$DRG_CACHE"; return 1; }
    
    # Cache format: VCN_ID|DRG_ID|STATE|DISPLAY_NAME
    # Handle both DRGv1 and DRGv2 formats
    echo "$result" | jq -r '.data[] | 
        (if .["vcn-id"] != null then .["vcn-id"] 
         elif .["network-details"] != null and .["network-details"]["id"] != null then .["network-details"]["id"] 
         else null end) as $vcn |
        select($vcn != null) |
        "\($vcn)|\(.["drg-id"])|\(.["lifecycle-state"])|\(.["display-name"] // "N/A")"' > "$DRG_CACHE" 2>/dev/null
    [[ ! -s "$DRG_CACHE" ]] && touch "$DRG_CACHE"
}

# Fetch and cache Local Peering Gateways
fetch_local_peering_gateways() {
    local compartment_id="$1"
    local vcn_ocid="$2"
    
    is_cache_fresh "$LPG_CACHE" && return 0
    
    log_info "Fetching Local Peering Gateways..."
    
    local result
    result=$(oci network local-peering-gateway list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_ocid" \
        --all \
        --output json 2>/dev/null) || { touch "$LPG_CACHE"; return 1; }
    
    # Cache format: VCN_ID|LPG_ID|STATE|PEERING_STATUS|DISPLAY_NAME
    echo "$result" | jq -r '.data[] | "\(.["vcn-id"])|\(.id)|\(.["lifecycle-state"])|\(.["peering-status"])|\(.["display-name"] // "N/A")"' > "$LPG_CACHE" 2>/dev/null
    [[ ! -s "$LPG_CACHE" ]] && touch "$LPG_CACHE"
}

# Fetch and cache Remote Peering Connections
fetch_remote_peering_connections() {
    local compartment_id="$1"
    
    is_cache_fresh "$RPC_CACHE" && return 0
    
    log_info "Fetching Remote Peering Connections..."
    
    local result
    result=$(oci network remote-peering-connection list \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>/dev/null) || { touch "$RPC_CACHE"; return 1; }
    
    # Cache format: DRG_ID|RPC_ID|STATE|PEERING_STATUS
    echo "$result" | jq -r '.data[] | "\(.["drg-id"])|\(.id)|\(.["lifecycle-state"])|\(.["peering-status"])"' > "$RPC_CACHE" 2>/dev/null
    [[ ! -s "$RPC_CACHE" ]] && touch "$RPC_CACHE"
}

# Fetch and cache Route Tables
fetch_route_tables() {
    local compartment_id="$1"
    local vcn_ocid="$2"
    
    is_cache_fresh "$RT_CACHE" && return 0
    
    log_info "Fetching Route Tables..."
    
    local result
    result=$(oci network route-table list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_ocid" \
        --all \
        --output json 2>/dev/null) || { touch "$RT_CACHE"; return 1; }
    
    # Cache format: RT_ID|VCN_ID|DISPLAY_NAME|STATE|ROUTE_COUNT
    echo "$result" | jq -r '.data[] | "\(.id)|\(.["vcn-id"])|\(.["display-name"])|\(.["lifecycle-state"])|\(.["route-rules"] | length)"' > "$RT_CACHE" 2>/dev/null
    [[ ! -s "$RT_CACHE" ]] && touch "$RT_CACHE"
}

# Fetch and cache NSG rules for all NSGs
fetch_nsg_rules() {
    local compartment_id="$1"
    local vcn_ocid="$2"
    
    is_cache_fresh "$NSG_RULES_CACHE" && return 0
    
    log_info "Fetching NSG rules..."
    
    # Get all NSGs
    local nsgs_json
    nsgs_json=$(oci network nsg list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_ocid" \
        --all \
        --output json 2>/dev/null) || { touch "$NSG_RULES_CACHE"; return 1; }
    
    # Clear existing cache
    > "$NSG_RULES_CACHE"
    
    # Get rule counts for each NSG
    echo "$nsgs_json" | jq -r '.data[].id' 2>/dev/null | while read -r nsg_id; do
        [[ -z "$nsg_id" ]] && continue
        
        local result ingress_count egress_count
        result=$(oci network nsg rules list \
            --nsg-id "$nsg_id" \
            --all \
            --output json 2>/dev/null)
        
        if [[ -n "$result" ]]; then
            ingress_count=$(echo "$result" | jq '[.data[] | select(.direction=="INGRESS")] | length' 2>/dev/null) || ingress_count=0
            egress_count=$(echo "$result" | jq '[.data[] | select(.direction=="EGRESS")] | length' 2>/dev/null) || egress_count=0
        else
            ingress_count=0
            egress_count=0
        fi
        
        # Cache format: NSG_ID|INGRESS_COUNT|EGRESS_COUNT
        echo "${nsg_id}|${ingress_count:-0}|${egress_count:-0}" >> "$NSG_RULES_CACHE"
    done
    
    [[ ! -s "$NSG_RULES_CACHE" ]] && touch "$NSG_RULES_CACHE"
}

# Fetch and cache Security Lists
fetch_security_lists() {
    local compartment_id="$1"
    local vcn_ocid="$2"
    
    is_cache_fresh "$SL_CACHE" && return 0
    
    log_info "Fetching Security Lists..."
    
    local result
    result=$(oci network security-list list \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_ocid" \
        --all \
        --output json 2>/dev/null) || { touch "$SL_CACHE"; return 1; }
    
    # Cache format: SL_ID|VCN_ID|DISPLAY_NAME|STATE|INGRESS_COUNT|EGRESS_COUNT
    echo "$result" | jq -r '.data[] | "\(.id)|\(.["vcn-id"])|\(.["display-name"])|\(.["lifecycle-state"])|\(.["ingress-security-rules"] | length)|\(.["egress-security-rules"] | length)"' > "$SL_CACHE" 2>/dev/null
    [[ ! -s "$SL_CACHE" ]] && touch "$SL_CACHE"
}

# Fetch all network gateway caches
fetch_all_network_gateways() {
    local compartment_id="$1"
    local vcn_ocid="$2"
    
    [[ "$vcn_ocid" == "N/A" || -z "$vcn_ocid" ]] && return 1
    
    fetch_internet_gateways "$compartment_id" "$vcn_ocid"
    fetch_service_gateways "$compartment_id" "$vcn_ocid"
    fetch_nat_gateways "$compartment_id" "$vcn_ocid"
    fetch_drg_attachments "$compartment_id"
    fetch_local_peering_gateways "$compartment_id" "$vcn_ocid"
    fetch_remote_peering_connections "$compartment_id"
    fetch_route_tables "$compartment_id" "$vcn_ocid"
    fetch_nsg_rules "$compartment_id" "$vcn_ocid"
    fetch_security_lists "$compartment_id" "$vcn_ocid"
}

# Check if VCN has an Internet Gateway
has_internet_gateway() {
    local vcn_id="$1"
    [[ ! -f "$IGW_CACHE" ]] && { echo "false"; return; }
    grep -q "^${vcn_id}|" "$IGW_CACHE" 2>/dev/null && echo "true" || echo "false"
}

# Check if VCN has a Service Gateway
has_service_gateway() {
    local vcn_id="$1"
    [[ ! -f "$SGW_CACHE" ]] && { echo "false"; return; }
    grep -q "^${vcn_id}|" "$SGW_CACHE" 2>/dev/null && echo "true" || echo "false"
}

# Check if VCN has a NAT Gateway
has_nat_gateway() {
    local vcn_id="$1"
    [[ ! -f "$NAT_CACHE" ]] && { echo "false"; return; }
    grep -q "^${vcn_id}|" "$NAT_CACHE" 2>/dev/null && echo "true" || echo "false"
}

# Check if VCN has a DRG Attachment
has_drg_attachment() {
    local vcn_id="$1"
    [[ ! -f "$DRG_CACHE" ]] && { echo "false"; return; }
    grep -q "^${vcn_id}|" "$DRG_CACHE" 2>/dev/null && echo "true" || echo "false"
}

# Check if VCN has a Local Peering Gateway
has_local_peering_gateway() {
    local vcn_id="$1"
    [[ ! -f "$LPG_CACHE" ]] && { echo "false"; return; }
    grep -q "^${vcn_id}|" "$LPG_CACHE" 2>/dev/null && echo "true" || echo "false"
}

# Check if VCN has a Remote Peering Connection (via DRG)
has_remote_peering_connection() {
    local vcn_id="$1"
    
    [[ ! -f "$DRG_CACHE" || ! -f "$RPC_CACHE" ]] && { echo "false"; return; }
    
    # Get DRG ID for this VCN
    local drg_id
    drg_id=$(grep "^${vcn_id}|" "$DRG_CACHE" 2>/dev/null | head -1 | cut -d'|' -f2)
    [[ -z "$drg_id" ]] && { echo "false"; return; }
    
    # Check if this DRG has an RPC
    if grep "^${drg_id}|" "$RPC_CACHE" 2>/dev/null | grep -qv "|TERMINATED|"; then
        echo "true"
    else
        echo "false"
    fi
}

# Check if VCN has Route Tables with rules
has_route_table() {
    local vcn_id="$1"
    
    [[ ! -f "$RT_CACHE" ]] && { echo "false"; return; }
    
    # Check for route tables with at least one rule
    local found="false"
    while IFS='|' read -r _ vid _ state count; do
        if [[ "$vid" == "$vcn_id" && "$state" == "AVAILABLE" && "$count" -gt 0 ]]; then
            found="true"
            break
        fi
    done < "$RT_CACHE"
    echo "$found"
}

# Get route table name by ID
get_route_table_name() {
    local rt_id="$1"
    
    [[ ! -f "$RT_CACHE" ]] && { echo "N/A"; return; }
    [[ -z "$rt_id" || "$rt_id" == "N/A" ]] && { echo "N/A"; return; }
    
    local name
    name=$(grep "^${rt_id}|" "$RT_CACHE" 2>/dev/null | head -1 | cut -d'|' -f3)
    echo "${name:-N/A}"
}

# Get route table rule count by ID
get_route_table_rule_count() {
    local rt_id="$1"
    
    [[ ! -f "$RT_CACHE" ]] && { echo "0"; return; }
    [[ -z "$rt_id" || "$rt_id" == "N/A" ]] && { echo "0"; return; }
    
    local count
    count=$(grep "^${rt_id}|" "$RT_CACHE" 2>/dev/null | head -1 | cut -d'|' -f5)
    echo "${count:-0}"
}

# Get NSG ingress/egress counts
get_nsg_rule_counts() {
    local nsg_id="$1"
    
    [[ -z "$nsg_id" ]] && { echo "0|0"; return; }
    [[ ! -f "$NSG_RULES_CACHE" ]] && { echo "0|0"; return; }
    
    local line
    line=$(grep "^${nsg_id}|" "$NSG_RULES_CACHE" 2>/dev/null | head -1)
    
    if [[ -n "$line" ]]; then
        local ingress egress
        ingress=$(echo "$line" | cut -d'|' -f2)
        egress=$(echo "$line" | cut -d'|' -f3)
        echo "${ingress:-0}|${egress:-0}"
    else
        echo "0|0"
    fi
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
    local vcn_name="${3:-N/A}"
    
    [[ "$vcn_ocid" == "N/A" || -z "$vcn_ocid" ]] && return 1
    
    # Fetch/refresh caches
    fetch_network_resources "$compartment_id" "$vcn_ocid"
    fetch_all_network_gateways "$compartment_id" "$vcn_ocid"
    
    [[ ! -f "$NETWORK_RESOURCES_CACHE" ]] && return 1
    
    echo -e "${BOLD}${WHITE}Network Resources:${NC}"
    
    # Build gateway indicators for VCN
    local has_igw has_sgw has_nat has_drg has_lpg has_rpc has_rt
    has_igw=$(has_internet_gateway "$vcn_ocid" 2>/dev/null) || has_igw="false"
    has_sgw=$(has_service_gateway "$vcn_ocid" 2>/dev/null) || has_sgw="false"
    has_nat=$(has_nat_gateway "$vcn_ocid" 2>/dev/null) || has_nat="false"
    has_drg=$(has_drg_attachment "$vcn_ocid" 2>/dev/null) || has_drg="false"
    has_lpg=$(has_local_peering_gateway "$vcn_ocid" 2>/dev/null) || has_lpg="false"
    has_rpc=$(has_remote_peering_connection "$vcn_ocid" 2>/dev/null) || has_rpc="false"
    has_rt=$(has_route_table "$vcn_ocid" 2>/dev/null) || has_rt="false"
    
    local igw_box sgw_box nat_box drg_box lpg_box rpc_box rt_box
    [[ "$has_igw" == "true" ]] && igw_box="${GREEN}[X]${NC}" || igw_box="${WHITE}[ ]${NC}"
    [[ "$has_sgw" == "true" ]] && sgw_box="${GREEN}[X]${NC}" || sgw_box="${WHITE}[ ]${NC}"
    [[ "$has_nat" == "true" ]] && nat_box="${GREEN}[X]${NC}" || nat_box="${WHITE}[ ]${NC}"
    [[ "$has_drg" == "true" ]] && drg_box="${GREEN}[X]${NC}" || drg_box="${WHITE}[ ]${NC}"
    [[ "$has_lpg" == "true" ]] && lpg_box="${GREEN}[X]${NC}" || lpg_box="${WHITE}[ ]${NC}"
    [[ "$has_rpc" == "true" ]] && rpc_box="${GREEN}[X]${NC}" || rpc_box="${WHITE}[ ]${NC}"
    [[ "$has_rt" == "true" ]] && rt_box="${GREEN}[X]${NC}" || rt_box="${WHITE}[ ]${NC}"
    
    local gateway_indicators="IGW:${igw_box} SGW:${sgw_box} NAT:${nat_box} DRG:${drg_box} LPG:${lpg_box} RPC:${rpc_box} RT:${rt_box}"
    
    # Display VCN line with gateway indicators
    echo -e "${BOLD}${MAGENTA}VCN:${NC} ${GREEN}${vcn_name}${NC} ${WHITE}[${NC}${gateway_indicators}${WHITE}]${NC} ${WHITE}(${YELLOW}${vcn_ocid}${WHITE})${NC}"
    echo ""
    
    # Build arrays of subnets and NSGs
    declare -A subnets_by_shortname
    declare -A nsgs_by_shortname
    declare -a unmatched_subnets
    declare -a unmatched_nsgs
    declare -a subnet_shortnames
    
    # Read subnets (now with route-table-id)
    while IFS='|' read -r type name cidr access state ocid rt_ocid; do
        [[ "$type" != "SUBNET" ]] && continue
        local shortname
        shortname=$(get_shortname_match "$name")
        if [[ -n "$shortname" ]]; then
            subnets_by_shortname[$shortname]="${name}|${cidr}|${access}|${ocid}|${rt_ocid}"
            subnet_shortnames+=("$shortname")
        else
            unmatched_subnets+=("${name}|${cidr}|${access}|${ocid}|${rt_ocid}")
        fi
    done < <(grep "^SUBNET|" "$NETWORK_RESOURCES_CACHE" 2>/dev/null)
    
    # Read NSGs
    while IFS='|' read -r type name _ state ocid; do
        [[ "$type" != "NSG" ]] && continue
        local shortname
        shortname=$(get_shortname_match "$name")
        if [[ -n "$shortname" ]]; then
            if [[ -n "${nsgs_by_shortname[$shortname]:-}" ]]; then
                nsgs_by_shortname[$shortname]="${nsgs_by_shortname[$shortname]}#${name}|${ocid}"
            else
                nsgs_by_shortname[$shortname]="${name}|${ocid}"
            fi
        else
            unmatched_nsgs+=("${name}|${ocid}")
        fi
    done < <(grep "^NSG|" "$NETWORK_RESOURCES_CACHE" 2>/dev/null)
    
    # Display subnets with their matching NSGs
    local shortname
    for shortname in "${subnet_shortnames[@]}"; do
        local subnet_info="${subnets_by_shortname[$shortname]}"
        [[ -z "$subnet_info" ]] && continue
        
        local name cidr access ocid rt_ocid
        IFS='|' read -r name cidr access ocid rt_ocid <<< "$subnet_info"
        
        local access_color
        [[ "$access" == "Private" ]] && access_color="$RED" || access_color="$LIGHT_GREEN"
        
        # Get route table info
        local rt_name rt_rules rt_display
        rt_name=$(get_route_table_name "$rt_ocid")
        rt_rules=$(get_route_table_rule_count "$rt_ocid")
        rt_display="${rt_name} (${rt_rules})"
        
        # Subnet line with route table
        printf "  ${BOLD}${WHITE}Subnet:${NC} ${GREEN}%-30s${NC} ${WHITE}[${CYAN}%-15s${WHITE}]${NC} ${WHITE}[${access_color}%-7s${WHITE}]${NC} ${WHITE}RT:${NC} ${CYAN}%-28s${NC}${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
            "$name" "$cidr" "$access" "$rt_display" "$ocid"
        
        # Display matching NSGs
        local nsg_list="${nsgs_by_shortname[$shortname]:-}"
        if [[ -n "$nsg_list" ]]; then
            local nsg_entries
            IFS='#' read -ra nsg_entries <<< "$nsg_list"
            local nsg_count=${#nsg_entries[@]}
            local i=0
            for nsg_entry in "${nsg_entries[@]}"; do
                ((i++))
                local nsg_name nsg_ocid
                IFS='|' read -r nsg_name nsg_ocid <<< "$nsg_entry"
                
                # Get NSG rule counts
                local rule_counts ingress egress rules_display
                rule_counts=$(get_nsg_rule_counts "$nsg_ocid")
                ingress=$(echo "$rule_counts" | cut -d'|' -f1)
                egress=$(echo "$rule_counts" | cut -d'|' -f2)
                rules_display="In:${ingress} Out:${egress}"
                
                local prefix="├─"
                [[ $i -eq $nsg_count ]] && prefix="└─"
                
                # NSG line with rule counts - padding 37 to align with subnet OCID
                printf "          ${BOLD}${BLUE}${prefix} NSG:${NC} ${WHITE}%-30s${NC} ${CYAN}%-15s${NC}%-37s${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                    "$nsg_name" "$rules_display" "" "$nsg_ocid"
            done
        fi
        echo ""
    done
    
    # Display unmatched subnets
    if [[ ${#unmatched_subnets[@]} -gt 0 ]]; then
        for subnet_entry in "${unmatched_subnets[@]}"; do
            local name cidr access ocid rt_ocid
            IFS='|' read -r name cidr access ocid rt_ocid <<< "$subnet_entry"
            
            local access_color
            [[ "$access" == "Private" ]] && access_color="$RED" || access_color="$LIGHT_GREEN"
            
            # Get route table info
            local rt_name rt_rules rt_display
            rt_name=$(get_route_table_name "$rt_ocid")
            rt_rules=$(get_route_table_rule_count "$rt_ocid")
            rt_display="${rt_name} (${rt_rules})"
            
            printf "  ${BOLD}${WHITE}Subnet:${NC} ${GREEN}%-30s${NC} ${WHITE}[${CYAN}%-15s${WHITE}]${NC} ${WHITE}[${access_color}%-7s${WHITE}]${NC} ${WHITE}RT:${NC} ${CYAN}%-28s${NC}${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "$name" "$cidr" "$access" "$rt_display" "$ocid"
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
            local nsg_name nsg_ocid
            IFS='|' read -r nsg_name nsg_ocid <<< "$nsg_entry"
            
            # Get NSG rule counts
            local rule_counts ingress egress rules_display
            rule_counts=$(get_nsg_rule_counts "$nsg_ocid")
            ingress=$(echo "$rule_counts" | cut -d'|' -f1)
            egress=$(echo "$rule_counts" | cut -d'|' -f2)
            rules_display="In:${ingress} Out:${egress}"
            
            local prefix="├─"
            [[ $i -eq $total ]] && prefix="└─"
            
            # NSG line with rule counts - padding 37 to align with subnet OCID
            printf "          ${BOLD}${BLUE}${prefix} NSG:${NC} ${WHITE}%-30s${NC} ${CYAN}%-15s${NC}%-37s${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "$nsg_name" "$rules_display" "" "$nsg_ocid"
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

# Get GPU memory cluster size from cluster OCID
# Args: $1 = cluster OCID
get_cluster_size() {
    lookup_cache "$CLUSTER_CACHE" "$1" 7
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
        -)        echo "$GRAY" ;;
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
        CREATING) echo "$CYAN" ;;
        UPDATING|SCALING) echo "$YELLOW" ;;
        INACTIVE|FAILED|DELETED|DELETING) echo "$RED" ;;
        *)      echo "$WHITE" ;;
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
    local cluster_name cluster_ocid cluster_state cluster_version cluster_addons pod_network vcn_name vcn_ocid
    local compute_cluster_name compute_cluster_ocid
    
    tenancy_ocid=$(get_oke_env_value "TENANCY_OCID")
    compartment_name=$(get_oke_env_value "COMPARTMENT_NAME")
    ads=$(get_oke_env_value "ADS")
    cluster_name=$(get_oke_env_value "CLUSTER_NAME")
    cluster_ocid=$(get_oke_env_value "OKE_CLUSTER_ID")
    cluster_state=$(get_oke_env_value "CLUSTER_STATE")
    cluster_version=$(get_oke_env_value "CLUSTER_VERSION")
    cluster_addons=$(get_oke_env_value "CLUSTER_ADDONS")
    pod_network=$(get_oke_env_value "POD_NETWORK")
    vcn_name=$(get_oke_env_value "VCN_NAME")
    vcn_ocid=$(get_oke_env_value "VCN_OCID")
    compute_cluster_name=$(get_oke_env_value "COMPUTE_CLUSTER_NAME")
    compute_cluster_ocid=$(get_oke_env_value "COMPUTE_CLUSTER_OCID")
    
    # If cluster version is empty/N/A, fetch directly from OCI (same as manage_oke_cluster)
    if [[ -z "$cluster_version" || "$cluster_version" == "N/A" ]] && [[ -n "$cluster_ocid" && "$cluster_ocid" != "N/A" ]]; then
        local cluster_json
        cluster_json=$(oci ce cluster get --cluster-id "$cluster_ocid" --output json 2>/dev/null)
        if [[ -n "$cluster_json" ]]; then
            cluster_version=$(echo "$cluster_json" | jq -r '.data["kubernetes-version"] // "N/A"')
            # Update cache with the version
            if [[ -f "$OKE_ENV_CACHE" && -n "$cluster_version" && "$cluster_version" != "N/A" ]]; then
                if grep -q "^CLUSTER_VERSION|" "$OKE_ENV_CACHE" 2>/dev/null; then
                    sed -i "s/^CLUSTER_VERSION|.*/CLUSTER_VERSION|${cluster_version}/" "$OKE_ENV_CACHE"
                else
                    echo "CLUSTER_VERSION|${cluster_version}" >> "$OKE_ENV_CACHE"
                fi
            fi
        fi
    fi
    
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
    
    _print_row "OKE Version:" "$cluster_version"
    _print_row "Pod Network:" "$pod_network"
    _print_row "Cluster Addons:" "$cluster_addons"
    _print_row_with_ocid "VCN:" "$vcn_name" "$vcn_ocid"
    
    # Section separator
    echo -e "${BOLD}${BLUE}╠${h_line}╣${NC}"
    
    # Compute Cluster section
    _print_row_with_ocid "Compute Cluster:" "$compute_cluster_name" "$compute_cluster_ocid"
    
    # Bottom border
    echo -e "${BOLD}${BLUE}╚${h_line}╝${NC}"
    echo ""
    
    # Display network resources (subnets and NSGs grouped by shortname)
    display_network_resources "$compartment_id" "$vcn_ocid" "$vcn_name"
}

#===============================================================================
# DISPLAY FUNCTIONS
#===============================================================================

# List fabrics without active clusters
list_fabrics_without_clusters() {
    echo -e "${BOLD}${MAGENTA}=== GPU Memory Fabrics Without Clusters ===${NC}"
    echo ""
    
    if [[ ! -f "$FABRIC_CACHE" || ! -f "$CLUSTER_CACHE" ]]; then
        echo -e "${YELLOW}Cache files not available${NC}"
        return 1
    fi
    
    local all_fabric_suffixes
    all_fabric_suffixes=$(grep -v '^#' "$FABRIC_CACHE" | cut -d'|' -f2)
    
    local used_fabric_suffixes
    # Include ACTIVE, UPDATING, SCALING, and CREATING states when determining fabrics with clusters
    used_fabric_suffixes=$(grep -v '^#' "$CLUSTER_CACHE" | grep -E "\|ACTIVE\||\|UPDATING\||\|SCALING\||\|CREATING\|" | cut -d'|' -f4 | sort -u)
    
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
                # Format: DisplayName|Last5Chars|FabricOCID|State|HealthyHosts|AvailableHosts|TotalHosts|CurrentFirmware|TargetFirmware|FirmwareUpdateState
                local fabric_name fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts current_firmware target_firmware firmware_update_state
                IFS='|' read -r fabric_name _ fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts current_firmware target_firmware firmware_update_state <<< "$fabric_line"
                echo "${fabric_name}|${fabric_ocid}|${fabric_state}|${healthy_hosts}|${avail_hosts}|${total_hosts}|${current_firmware}|${target_firmware}|${firmware_update_state}" >> "$temp_output"
            fi
        fi
    done <<< "$all_fabric_suffixes"
    
    if [[ "$found_unused" == "true" ]]; then
        # Print header - aligned with clique summary
        printf "${BOLD}%-48s ┌─ GPU Memory Fabric ─┐${NC}\n" ""
        printf "${BOLD}%-48s %8s %6s %6s    %-12s${NC}\n" \
            "Fabric Display Name" "Healthy" "Avail" "Total" "State"
        print_separator 106
        
        # Print data rows
        local fabric_name fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts current_firmware target_firmware firmware_update_state
        while IFS='|' read -r fabric_name fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts current_firmware target_firmware firmware_update_state; do
            local state_color
            state_color=$(color_fabric_state "$fabric_state")
            
            # Color available hosts - light green if not 0
            local avail_color="$WHITE"
            [[ "$avail_hosts" != "0" && "$avail_hosts" != "N/A" ]] && avail_color="$LIGHT_GREEN"
            
            printf "${CYAN}%-48s${NC} ${WHITE}%8s${NC} ${avail_color}%6s${NC} ${WHITE}%6s${NC}    ${state_color}%-12s${NC}\n" \
                "$fabric_name" "$healthy_hosts" "$avail_hosts" "$total_hosts" "$fabric_state"
            printf "          ${WHITE}├─${NC} ${BOLD}${ORANGE}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "Fabric:" "$fabric_name" "$fabric_ocid"
            
            # Display firmware bundle IDs if available
            if [[ "$current_firmware" != "N/A" && -n "$current_firmware" ]]; then
                local current_short="${current_firmware: -5}"
                local target_short="${target_firmware: -5}"
                local firmware_color="$WHITE"
                
                # Highlight in red if current != target
                if [[ "$current_firmware" != "$target_firmware" && "$target_firmware" != "N/A" && -n "$target_firmware" ]]; then
                    firmware_color="$RED"
                fi
                
                # Color firmware update state
                local update_state_color="$WHITE"
                case "$firmware_update_state" in
                    UP_TO_DATE|COMPLETED) update_state_color="$GREEN" ;;
                    IN_PROGRESS|UPDATING) update_state_color="$YELLOW" ;;
                    FAILED|ERROR) update_state_color="$RED" ;;
                esac
                
                printf "          ${WHITE}└─${NC} ${BOLD}${ORANGE}Firmware:${NC} ${update_state_color}%-12s${NC} ${firmware_color}current: %-10s target: %-10s${NC}\n" \
                    "$firmware_update_state" "$current_short" "$target_short"
            fi
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
    
    # Delete the console history to clean up
    log_info "Cleaning up console history..."
    if oci compute console-history delete \
        --instance-console-history-id "$console_history_id" \
        --force 2>/dev/null; then
        echo -e "${GREEN}✓ Console history deleted: ${console_history_id}${NC}"
    else
        echo -e "${YELLOW}⚠ Failed to delete console history: ${console_history_id}${NC}"
    fi
    echo ""
    
    return 0
}

# List instances not in Kubernetes with interactive console history option
list_instances_not_in_k8s() {
    local oci_temp="$1"
    local k8s_temp="$2"
    local interactive="${3:-true}"  # Default to interactive mode
    
    # Dynamic header based on instance filter
    local instance_filter="${INSTANCE_FILTER:-gpu}"
    local header_text all_running_text
    case "$instance_filter" in
        gpu)
            header_text="GPU Instances Not in Kubernetes"
            all_running_text="All running GPU instances are in Kubernetes"
            ;;
        non-gpu)
            header_text="Non-GPU Instances Not in Kubernetes"
            all_running_text="All running non-GPU instances are in Kubernetes"
            ;;
        all)
            header_text="Instances Not in Kubernetes"
            all_running_text="All running instances are in Kubernetes"
            ;;
        *)
            header_text="GPU Instances Not in Kubernetes"
            all_running_text="All running GPU instances are in Kubernetes"
            ;;
    esac
    
    echo -e "${BOLD}${MAGENTA}=== $header_text ===${NC}"
    echo ""
    
    # Collect instances not in k8s into a temp file for sorting
    local orphan_temp
    orphan_temp=$(create_temp_file) || return 1
    
    # oci_temp format: display_name|status|instance_ocid|gpu_mem|shape|time_created
    local display_name status instance_ocid gpu_mem shape time_created
    while IFS='|' read -r display_name status instance_ocid gpu_mem shape time_created; do
        [[ -z "$instance_ocid" ]] && continue
        
        # Skip bastion and operator instances - they're not supposed to be in K8s
        local display_name_lower="${display_name,,}"  # Convert to lowercase
        if [[ "$display_name_lower" == *bastion* || "$display_name_lower" == *operator* ]]; then
            continue
        fi
        
        if ! grep -q "^${instance_ocid}|" "$k8s_temp" 2>/dev/null; then
            if [[ "$status" == "RUNNING" ]]; then
                # Store with time_created for sorting
                echo "${time_created}|${display_name}|${instance_ocid}|${status}|${gpu_mem}" >> "$orphan_temp"
            fi
        fi
    done < "$oci_temp"
    
    local orphan_count
    orphan_count=$(wc -l < "$orphan_temp" 2>/dev/null) || orphan_count=0
    
    if [[ $orphan_count -eq 0 ]]; then
        echo -e "${GREEN}$all_running_text${NC}"
        rm -f "$orphan_temp"
        return 0
    fi
    
    # Sort by time_created (ascending - oldest first, newest last)
    local sorted_temp
    sorted_temp=$(create_temp_file) || { rm -f "$orphan_temp"; return 1; }
    sort -t'|' -k1,1 "$orphan_temp" > "$sorted_temp"
    
    # Read sorted data into arrays
    local -a orphan_names=()
    local -a orphan_ocids=()
    local -a orphan_states=()
    local -a orphan_gpu_mems=()
    local -a orphan_times=()
    
    while IFS='|' read -r time_created display_name instance_ocid status gpu_mem; do
        orphan_times+=("$time_created")
        orphan_names+=("$display_name")
        orphan_ocids+=("$instance_ocid")
        orphan_states+=("$status")
        orphan_gpu_mems+=("$gpu_mem")
    done < "$sorted_temp"
    
    rm -f "$orphan_temp" "$sorted_temp"
    
    # Display numbered list of instances not in kubernetes
    printf "${BOLD}%-4s %-35s %-10s %-15s %-22s %s${NC}\n" \
        "#" "Display Name" "OCI State" "GPU Mem Cluster" "Created" "Instance OCID"
    print_separator 180
    
    local i
    for ((i=0; i<orphan_count; i++)); do
        local gpu_mem_display="${orphan_gpu_mems[$i]}"
        [[ "$gpu_mem_display" != "N/A" && ${#gpu_mem_display} -gt 12 ]] && gpu_mem_display="...${gpu_mem_display: -9}"
        
        # Format time_created - show date and time portion
        local time_display="${orphan_times[$i]}"
        if [[ "$time_display" != "N/A" && -n "$time_display" ]]; then
            # Format: 2026-01-27T03:29:11.123Z -> 2026-01-27 03:29:11
            time_display="${time_display:0:19}"
            time_display="${time_display/T/ }"
        fi
        
        printf "${YELLOW}%-4s${NC} ${CYAN}%-35s${NC} ${GREEN}%-10s${NC} ${MAGENTA}%-15s${NC} ${GRAY}%-22s${NC} ${WHITE}%s${NC}\n" \
            "$((i+1))" \
            "$(truncate_string "${orphan_names[$i]}" 35)" \
            "${orphan_states[$i]}" \
            "$gpu_mem_display" \
            "$time_display" \
            "${orphan_ocids[$i]}"
    done
    
    echo ""
    echo -e "${YELLOW}Total instances not in kubernetes: ${orphan_count}${NC}"
    
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

# Non-interactive version for scripting - just list instances not in kubernetes
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
    
    # Get instance filter (default to "gpu" for backward compatibility)
    local instance_filter="${INSTANCE_FILTER:-gpu}"
    
    # Display OKE environment header
    display_oke_environment_header "$compartment_id" "$region"
    
    # Fetch all cached data
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_instance_configurations
    
    # Set header based on filter
    local header_text
    case "$instance_filter" in
        gpu)
            header_text="All GPU Instances in Compartment"
            ;;
        non-gpu)
            header_text="All Non-GPU Instances in Compartment"
            ;;
        all)
            header_text="All Instances in Compartment"
            ;;
        *)
            header_text="All GPU Instances in Compartment"
            instance_filter="gpu"
            ;;
    esac
    
    echo -e "${BOLD}${MAGENTA}=== $header_text ===${NC}"
    echo -e "${GRAY}(Filter: $instance_filter - change INSTANCE_FILTER in variables.sh)${NC}"
    echo ""
    
    # Create temp files
    local oci_temp k8s_temp output_temp
    oci_temp=$(create_temp_file) || return 1
    k8s_temp=$(create_temp_file) || { rm -f "$oci_temp"; return 1; }
    output_temp=$(create_temp_file) || { rm -f "$oci_temp" "$k8s_temp"; return 1; }
    
    # Build jq filter based on INSTANCE_FILTER
    local jq_filter
    case "$instance_filter" in
        gpu)
            jq_filter='select(.shape | test("GPU"; "i"))'
            ;;
        non-gpu)
            jq_filter='select(.shape | test("GPU"; "i") | not)'
            ;;
        all)
            jq_filter='.'
            ;;
    esac
    
    # Fetch OCI instances with appropriate filter
    log_info "Fetching instances from OCI (filter: $instance_filter)..."
    oci compute instance list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json 2>/dev/null | jq -r "
            .data[] | 
            $jq_filter | 
            select(.[\"lifecycle-state\"] != \"TERMINATED\") |
            \"\(.[\"display-name\"])|\(.[\"lifecycle-state\"])|\(.id)|\(.[\"freeform-tags\"][\"oci:compute:gpumemorycluster\"] // \"N/A\")|\(.shape)|\(.[\"time-created\"] // \"N/A\")\"
        " > "$oci_temp"
    
    # Fetch K8s nodes based on filter
    log_info "Fetching nodes from Kubernetes..."
    if [[ "$instance_filter" == "gpu" ]]; then
        kubectl get nodes -l nvidia.com/gpu.present=true -o json 2>/dev/null | jq -r '
            .items[] | 
            "\(.spec.providerID)|\(.metadata.name)|\(.metadata.labels["nvidia.com/gpu.clique"] // "N/A")"
        ' > "$k8s_temp"
    elif [[ "$instance_filter" == "non-gpu" ]]; then
        kubectl get nodes -l 'nvidia.com/gpu.present!=true' -o json 2>/dev/null | jq -r '
            .items[] | 
            "\(.spec.providerID)|\(.metadata.name)|N/A"
        ' > "$k8s_temp"
    else
        # All nodes
        kubectl get nodes -o json 2>/dev/null | jq -r '
            .items[] | 
            "\(.spec.providerID)|\(.metadata.name)|\(.metadata.labels["nvidia.com/gpu.clique"] // "N/A")"
        ' > "$k8s_temp"
    fi
    
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
    
    # Print table header with spanning headers
    # Column positions: DisplayName(28) Node(15) State(11) CliqueID(40) State(10) OCID(95) Name(12) State(12) State(10) Announce(18)
    # K8s spans Node+State+CliqueID (67), OCI Instance spans State+OCID (106), GPU Mem Cluster spans Name+State (25), CapTopo spans State (10)
    printf "${BOLD}%-28s%-67s%-125s%-31s%-12s%-11s${NC}\n" \
    "" \
    "┌───────────────────────────────── K8s ───────────────────────────┐" \
    "┌──────────────────────────────────────────── OCI Instance ─────────────────────────────────────────────┐" \
    "┌─ GPU Mem Cluster ─┐" \
    "CapTopo" \
    "Maintenance"
    printf "${BOLD}%-28s %-15s %-7s %-43s %-11s %-95s %-9s %-9s %-10s %-18s${NC}\n" \
        "Display Name" "Node" "State" "Clique ID" "State" "Instance OCID" "Name" "State" "State" "Announce"
    print_separator 280
    
    # Process and collect data for sorting
    local display_name status instance_ocid gpu_mem shape time_created
    while IFS='|' read -r display_name status instance_ocid gpu_mem shape time_created; do
        [[ -z "$instance_ocid" ]] && continue
        
        local k8s_info node_name clique_id node_state
        k8s_info=$(grep "^${instance_ocid}|" "$k8s_temp" 2>/dev/null)
        
        if [[ -n "$k8s_info" ]]; then
            # Instance is in Kubernetes
            IFS='|' read -r _ node_name clique_id <<< "$k8s_info"
            node_state=$(get_node_state_cached "$instance_ocid")
        else
            # Instance is NOT in Kubernetes
            node_name="-"
            clique_id="-"
            node_state="-"
        fi
        
        # Get various states
        local cluster_state cap_topo_state announcements
        cluster_state="N/A"
        [[ "$gpu_mem" != "N/A" ]] && cluster_state=$(get_cluster_state "$gpu_mem")
        cap_topo_state=$(get_capacity_topology_state "$instance_ocid")
        announcements=$(get_resource_announcements "$instance_ocid" "$gpu_mem")
        
        # Truncate for display
        local gpu_mem_display="$gpu_mem"
        [[ "$gpu_mem" != "N/A" && ${#gpu_mem} -gt 12 ]] && gpu_mem_display="...${gpu_mem: -9}"
        
        local cluster_state_display
        cluster_state_display=$(truncate_string "$cluster_state" 12)
        
        # Truncate display name to 28 characters
        local display_name_truncated
        display_name_truncated=$(truncate_string "$display_name" 28)
        
        # Store for sorting (by GPU mem cluster, then display name)
        echo "${gpu_mem}|${display_name_truncated}|${node_name}|${node_state}|${status}|${instance_ocid}|${gpu_mem_display}|${cluster_state_display}|${clique_id}|${cap_topo_state}|${announcements}" >> "$output_temp"
    done < "$oci_temp"
    
    # Sort and display
    sort -t'|' -k1,1 -k2,2 "$output_temp" | while IFS='|' read -r _ dn nn ns st io gm cs ci ct ann; do
        local ns_color st_color ct_color ann_color cs_color
        ns_color=$(color_node_state "$ns")
        st_color=$(color_oci_state "$st")
        ct_color=$(color_cap_topo_state "$ct")
        ann_color=$(color_announcement "$ann")
        cs_color=$(color_cluster_state "$cs")
        
        printf "%-28s %-15s ${ns_color}%-7s${NC} %-43s ${st_color}%-11s${NC} %-92s %-5s ${cs_color}%-8s${NC} ${ct_color}%-10s${NC} ${ann_color}%-18s${NC}\n" \
            "$dn" "$nn" "$ns" "$ci" "$st" "$io" "$gm" "$cs" "$ct" "$ann"
    done
    
    echo ""
    
    # Show GPU-specific summary and additional info (skip for non-gpu filter or if no GPU memory infrastructure)
    if [[ "$instance_filter" != "non-gpu" ]]; then
        # Check if any GPU memory fabrics or clusters exist in cache
        local has_gpu_memory_infra=false
        if [[ -f "$FABRIC_CACHE" ]] && grep -qv '^#' "$FABRIC_CACHE" 2>/dev/null; then
            has_gpu_memory_infra=true
        fi
        if [[ -f "$CLUSTER_CACHE" ]] && grep -qv '^#' "$CLUSTER_CACHE" 2>/dev/null; then
            has_gpu_memory_infra=true
        fi
        
        # Also check if any instances actually have GPU memory cluster tags (field 4 != N/A)
        local has_gpu_mem_instances=false
        if awk -F'|' '$4 != "N/A" && $4 != "" {found=1; exit} END {exit !found}' "$oci_temp" 2>/dev/null; then
            has_gpu_mem_instances=true
        fi
        
        if [[ "$has_gpu_memory_infra" == "true" || "$has_gpu_mem_instances" == "true" ]]; then
            display_clique_summary "$oci_temp" "$k8s_temp"
            
            echo ""
            list_fabrics_without_clusters
        fi
    fi
    
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
    
    # Join OCI and K8s data (oci_temp format: display_name|status|instance_ocid|gpu_mem|shape|time_created)
    local display_name status instance_ocid gpu_mem shape time_created
    while IFS='|' read -r display_name status instance_ocid gpu_mem shape time_created; do
        [[ -z "$instance_ocid" ]] && continue
        
        local k8s_info
        k8s_info=$(grep "^${instance_ocid}|" "$k8s_temp" 2>/dev/null)
        if [[ -n "$k8s_info" ]]; then
            local node_name clique_id
            IFS='|' read -r _ node_name clique_id <<< "$k8s_info"
            # joined format: display_name|node_name|status|instance_ocid|gpu_mem|clique_id
            echo "${display_name}|${node_name}|${status}|${instance_ocid}|${gpu_mem}|${clique_id}" >> "$joined_temp"
        elif [[ "$gpu_mem" != "N/A" && -n "$gpu_mem" ]]; then
            # Instance has GPU memory cluster tag but not in K8s yet
            # Use "NOT_IN_K8S" as clique_id placeholder
            echo "${display_name}|-|${status}|${instance_ocid}|${gpu_mem}|NOT_IN_K8S" >> "$joined_temp"
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
        [[ "$clique" == "NOT_IN_K8S" ]] && clique_display="NOT_IN_K8S (Instances not joined to cluster)"
        
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
        declare -A gpu_clusters_sizes
        
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
                    gpu_clusters_sizes[$gm]=$(get_cluster_size "$gm")
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
        local current_firmware="N/A"
        local target_firmware="N/A"
        local firmware_update_state="N/A"
        local gpu_cluster_size="N/A"
        
        if [[ -n "$first_gpu_mem" && "$first_gpu_mem" != "N/A" ]]; then
            # Fabric format: DisplayName|Last5Chars|FabricOCID|State|HealthyHosts|AvailableHosts|TotalHosts|CurrentFirmware|TargetFirmware|FirmwareUpdateState
            local fabric_line="${gpu_clusters_fabrics[$first_gpu_mem]}"
            IFS='|' read -r fabric_name _ fabric_ocid _ healthy_hosts available_hosts total_hosts current_firmware target_firmware firmware_update_state <<< "$fabric_line"
            cluster_state="${gpu_clusters_states[$first_gpu_mem]}"
            instance_config_id="${gpu_clusters_instance_configs[$first_gpu_mem]}"
            compute_cluster_id="${gpu_clusters_compute_clusters[$first_gpu_mem]}"
            gpu_cluster_size="${gpu_clusters_sizes[$first_gpu_mem]}"
        fi
        
        # Format: clique_display|clique_size|num_clusters|first_gpu_mem|cluster_state|fabric_name|fabric_ocid|instance_config_id|compute_cluster_id|healthy_hosts|available_hosts|total_hosts|current_firmware|target_firmware|firmware_update_state|gpu_cluster_size
        echo "${clique_display}|${clique_size}|${#gpu_clusters_count[@]}|${first_gpu_mem}|${cluster_state}|${fabric_name}|${fabric_ocid}|${instance_config_id}|${compute_cluster_id}|${healthy_hosts}|${available_hosts}|${total_hosts}|${current_firmware}|${target_firmware}|${firmware_update_state}|${gpu_cluster_size}" >> "$summary_temp"
        
        unset gpu_clusters_count gpu_clusters_fabrics gpu_clusters_states gpu_clusters_instance_configs gpu_clusters_compute_clusters gpu_clusters_sizes
    done <<< "$unique_cliques"
    
    # Track which GPU memory clusters have been displayed
    local displayed_clusters=""
    while IFS='|' read -r _ _ _ inst_ocid gm _; do
        [[ -n "$gm" && "$gm" != "N/A" ]] && displayed_clusters="${displayed_clusters}${gm}|"
    done < "$joined_temp"
    
    # Find GPU memory clusters that exist but have no instances
    if [[ -f "$CLUSTER_CACHE" ]]; then
        while IFS='|' read -r cluster_ocid cluster_name cluster_state cluster_fabric_suffix instance_config_id compute_cluster_id cluster_size; do
            [[ "$cluster_ocid" =~ ^#.*$ ]] && continue
            [[ -z "$cluster_ocid" ]] && continue
            # Only include active-ish states
            [[ "$cluster_state" != "ACTIVE" && "$cluster_state" != "UPDATING" && "$cluster_state" != "SCALING" && "$cluster_state" != "CREATING" ]] && continue
            # Skip if already displayed
            [[ "$displayed_clusters" == *"${cluster_ocid}|"* ]] && continue
            
            # This cluster has no instances - add to summary
            local fabric_info
            fabric_info=$(get_fabric_from_cluster "$cluster_ocid")
            local fabric_name fabric_ocid healthy_hosts available_hosts total_hosts current_firmware target_firmware firmware_update_state
            IFS='|' read -r fabric_name _ fabric_ocid _ healthy_hosts available_hosts total_hosts current_firmware target_firmware firmware_update_state <<< "$fabric_info"
            
            # Format: clique_display|clique_size|num_clusters|first_gpu_mem|cluster_state|fabric_name|fabric_ocid|instance_config_id|compute_cluster_id|healthy_hosts|available_hosts|total_hosts|current_firmware|target_firmware|firmware_update_state|gpu_cluster_size
            echo "NO_INSTANCES (${cluster_name})|0|1|${cluster_ocid}|${cluster_state}|${fabric_name}|${fabric_ocid}|${instance_config_id}|${compute_cluster_id}|${healthy_hosts}|${available_hosts}|${total_hosts}|${current_firmware}|${target_firmware}|${firmware_update_state}|${cluster_size}" >> "$summary_temp"
        done < <(grep -v '^#' "$CLUSTER_CACHE" 2>/dev/null)
    fi
    
    # Print summary table
    # Clique ID, then counts, then State - GPU Memory Cluster moved to tree below
    # Add spanning headers for K8s, GPU Memory Fabric, and GPU Mem Cluster columns
    printf "${BOLD}%-48s   K8s  ┌─ GPU Memory Fabric ─┐  GPU Mem Cluster${NC}\n" ""
    printf "${BOLD}%-48s %6s %8s %6s %6s       %6s       %-12s${NC}\n" \
        "Clique ID" "Nodes" "Healthy" "Avail" "Total" "Size" "State"
    print_separator 106
    
    # Sort summary: N/A first, NOT_IN_K8S second, NO_INSTANCES third, then by clique ID
    local sorted_summary
    sorted_summary=$(sort -t'|' -k1,1 "$summary_temp" | awk -F'|' '
        /^N\/A / { na[NR] = $0; next }
        /^NOT_IN_K8S/ { notink8s[NR] = $0; next }
        /^NO_INSTANCES/ { noinst[NR] = $0; next }
        { other[NR] = $0 }
        END {
            for (i in na) print na[i]
            for (i in notink8s) print notink8s[i]
            for (i in other) print other[i]
            for (i in noinst) print noinst[i]
        }
    ')
    
    # Calculate totals
    local total_k8s_nodes=0
    local total_gpu_cluster_size=0
    
    local clique_id nodes clusters gpu_mem_cluster cluster_state fabric_name fabric_ocid instance_config_id compute_cluster_id healthy_hosts available_hosts total_hosts current_firmware target_firmware firmware_update_state gpu_cluster_size
    while IFS='|' read -r clique_id nodes clusters gpu_mem_cluster cluster_state fabric_name fabric_ocid instance_config_id compute_cluster_id healthy_hosts available_hosts total_hosts current_firmware target_firmware firmware_update_state gpu_cluster_size; do
        # Add to totals (skip N/A, NOT_IN_K8S, NO_INSTANCES for K8s nodes count)
        if [[ "$clique_id" != "N/A"* && "$clique_id" != "NOT_IN_K8S"* && "$clique_id" != "NO_INSTANCES"* ]]; then
            [[ "$nodes" =~ ^[0-9]+$ ]] && total_k8s_nodes=$((total_k8s_nodes + nodes))
        fi
        # Add to GPU cluster size totals
        [[ "$gpu_cluster_size" =~ ^[0-9]+$ ]] && total_gpu_cluster_size=$((total_gpu_cluster_size + gpu_cluster_size))
        
        # Color state based on value
        local state_color
        case "$cluster_state" in
            ACTIVE) state_color="$GREEN" ;;
            CREATING) state_color="$CYAN" ;;
            UPDATING|SCALING) state_color="$YELLOW" ;;
            INACTIVE|FAILED|DELETED|DELETING) state_color="$RED" ;;
            *) state_color="$WHITE" ;;
        esac
        
        # Color available hosts - light green if not 0
        local avail_color="$WHITE"
        [[ "$available_hosts" != "0" && "$available_hosts" != "N/A" ]] && avail_color="$LIGHT_GREEN"
        
        # Color clique ID - yellow for NO_INSTANCES entries
        local clique_color="$CYAN"
        [[ "$clique_id" == NO_INSTANCES* ]] && clique_color="$YELLOW"
        
        printf "${clique_color}%-48s${NC} ${WHITE}%6s${NC} ${WHITE}%8s${NC} ${avail_color}%6s${NC} ${WHITE}%6s${NC}       ${WHITE}%6s${NC}       ${state_color}%-12s${NC}\n" \
            "$clique_id" "$nodes" "$healthy_hosts" "$available_hosts" "$total_hosts" "$gpu_cluster_size" "$cluster_state"
        
        # GPU Memory Cluster
        if [[ "$gpu_mem_cluster" != "N/A" && "$gpu_mem_cluster" != "null" && -n "$gpu_mem_cluster" ]]; then
            local gpu_cluster_name
            gpu_cluster_name=$(lookup_cache "$CLUSTER_CACHE" "$gpu_mem_cluster" 2 2>/dev/null || echo "N/A")
            printf "          ${WHITE}├─${NC} ${BOLD}${MAGENTA}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "GPU Mem Cluster:" "$gpu_cluster_name" "$gpu_mem_cluster"
        fi
        
        if [[ "$compute_cluster_id" != "N/A" && "$compute_cluster_id" != "null" && -n "$compute_cluster_id" ]]; then
            local compute_cluster_name
            compute_cluster_name=$(get_compute_cluster_name "$compute_cluster_id")
            printf "          ${WHITE}├─${NC} ${BOLD}${BLUE}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "Compute Cluster:" "$compute_cluster_name" "$compute_cluster_id"
        fi
        
        if [[ "$fabric_name" != "N/A" && "$fabric_ocid" != "N/A" ]]; then
            printf "          ${WHITE}├─${NC} ${BOLD}${ORANGE}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "Fabric:" "$fabric_name" "$fabric_ocid"
            
            # Display firmware bundle IDs if available
            if [[ "$current_firmware" != "N/A" && -n "$current_firmware" ]]; then
                local current_short="${current_firmware: -5}"
                local target_short="${target_firmware: -5}"
                local firmware_color="$WHITE"
                
                # Highlight in red if current != target
                if [[ "$current_firmware" != "$target_firmware" && "$target_firmware" != "N/A" && -n "$target_firmware" ]]; then
                    firmware_color="$RED"
                fi
                
                # Color firmware update state
                local update_state_color="$WHITE"
                case "$firmware_update_state" in
                    UP_TO_DATE|COMPLETED) update_state_color="$GREEN" ;;
                    IN_PROGRESS|UPDATING) update_state_color="$YELLOW" ;;
                    FAILED|ERROR) update_state_color="$RED" ;;
                esac
                
                printf "          ${WHITE}├─${NC} ${BOLD}${ORANGE}Firmware:${NC} ${update_state_color}%-12s${NC} ${firmware_color}current: %-10s target: %-10s${NC}\n" \
                    "$firmware_update_state" "$current_short" "$target_short"
            fi
        fi
        
        if [[ "$instance_config_id" != "N/A" && "$instance_config_id" != "null" && -n "$instance_config_id" ]]; then
            local instance_config_name
            instance_config_name=$(get_instance_config_name "$instance_config_id")
            printf "          ${WHITE}└─${NC} ${BOLD}${GREEN}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "Instance Config:" "$instance_config_name" "$instance_config_id"
        fi
        echo ""
    done <<< "$sorted_summary"
    
    # Print totals
    print_separator 106
    printf "${BOLD}${WHITE}%-48s %6s %8s %6s %6s       %6s${NC}\n" \
        "TOTALS" "$total_k8s_nodes" "" "" "" "$total_gpu_cluster_size"
    echo -e "${GRAY}  Total K8s Nodes (in GPU cliques): ${WHITE}$total_k8s_nodes${NC}"
    echo -e "${GRAY}  Total GPU Memory Cluster Size: ${WHITE}$total_gpu_cluster_size${NC}"
    echo ""
    
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
    
    # Get OCI instance details FIRST
    log_info "Fetching OCI instance details..."
    local oci_instance_json
    oci_instance_json=$(oci compute instance get --instance-id "$instance_id" --output json 2>/dev/null)
    
    if [[ -z "$oci_instance_json" ]] || ! echo "$oci_instance_json" | jq -e '.data' > /dev/null 2>&1; then
        log_error "Could not find instance in OCI: $instance_id"
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
    
    # Try to get Kubernetes node info (optional - may not exist)
    local node_json node_name node_data
    local in_kubernetes="false"
    node_json=$(kubectl get nodes -o json 2>/dev/null)
    
    if [[ -n "$node_json" ]]; then
        node_name=$(echo "$node_json" | jq -r --arg id "$instance_id" '.items[] | select(.spec.providerID==$id) | .metadata.name')
        if [[ -n "$node_name" ]]; then
            in_kubernetes="true"
            node_data=$(echo "$node_json" | jq --arg name "$node_name" '.items[] | select(.metadata.name==$name)')
        fi
    fi
    
    # Extract Kubernetes node fields (defaults if not in K8s)
    local node_state clique_id gpu_count gpu_product gpu_memory
    local kubelet_version os_image kernel_version container_runtime
    
    if [[ "$in_kubernetes" == "true" ]]; then
        node_state=$(get_node_state_cached "$instance_id")
        clique_id=$(echo "$node_data" | jq -r '.metadata.labels["nvidia.com/gpu.clique"] // "N/A"')
        gpu_count=$(echo "$node_data" | jq -r '.status.capacity["nvidia.com/gpu"] // "N/A"')
        gpu_product=$(echo "$node_data" | jq -r '.metadata.labels["nvidia.com/gpu.product"] // "N/A"')
        gpu_memory=$(echo "$node_data" | jq -r '.metadata.labels["nvidia.com/gpu.memory"] // "N/A"')
        kubelet_version=$(echo "$node_data" | jq -r '.status.nodeInfo.kubeletVersion // "N/A"')
        os_image=$(echo "$node_data" | jq -r '.status.nodeInfo.osImage // "N/A"')
        kernel_version=$(echo "$node_data" | jq -r '.status.nodeInfo.kernelVersion // "N/A"')
        container_runtime=$(echo "$node_data" | jq -r '.status.nodeInfo.containerRuntimeVersion // "N/A"')
    else
        node_name="NOT IN KUBERNETES"
        node_state="N/A"
        clique_id="N/A"
        gpu_count="N/A"
        gpu_product="N/A"
        gpu_memory="N/A"
        kubelet_version="N/A"
        os_image="N/A"
        kernel_version="N/A"
        container_runtime="N/A"
    fi
    
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
    if [[ "$in_kubernetes" == "true" ]]; then
        echo -e "  ${WHITE}Node Name:${NC}         ${GREEN}$node_name${NC}"
        
        local node_state_color
        node_state_color=$(color_node_state "$node_state")
        echo -e "  ${WHITE}Node State:${NC}        ${node_state_color}${node_state}${NC}"
        
        echo -e "  ${WHITE}Kubelet Version:${NC}   $kubelet_version"
        echo -e "  ${WHITE}OS Image:${NC}          $os_image"
        echo -e "  ${WHITE}Kernel:${NC}            $kernel_version"
        echo -e "  ${WHITE}Container Runtime:${NC} $container_runtime"
    else
        echo -e "  ${YELLOW}Instance has not joined the Kubernetes cluster${NC}"
        echo -e "  ${GRAY}Use --console-history to check boot logs for issues${NC}"
    fi
    echo ""
    
    # GPU Information section
    echo -e "${BOLD}${CYAN}=== GPU Information ===${NC}"
    if [[ "$in_kubernetes" == "true" ]]; then
        echo -e "  ${WHITE}GPU Count:${NC}         $gpu_count"
        echo -e "  ${WHITE}GPU Product:${NC}       $gpu_product"
        echo -e "  ${WHITE}GPU Memory:${NC}        $gpu_memory MB"
        echo -e "  ${WHITE}GPU Clique ID:${NC}     ${YELLOW}$clique_id${NC}"
        echo -e "  ${WHITE}Clique Size:${NC}       $clique_size nodes"
    else
        echo -e "  ${YELLOW}GPU information not available (instance not in K8s)${NC}"
        echo -e "  ${WHITE}Shape:${NC}             $shape"
    fi
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
        if [[ "$in_kubernetes" == "true" ]]; then
            echo -e "${BOLD}${CYAN}=== All Kubernetes Labels ===${NC}"
            echo "$node_data" | jq -r '.metadata.labels | to_entries | sort_by(.key) | .[] | "  \(.key): \(.value)"'
            echo ""
            
            echo -e "${BOLD}${CYAN}=== GPU Labels Only ===${NC}"
            echo "$node_data" | jq -r '.metadata.labels | to_entries | map(select(.key | contains("nvidia.com/gpu"))) | sort_by(.key) | .[] | "  \(.key): \(.value)"'
            echo ""
        else
            echo -e "${BOLD}${CYAN}=== Kubernetes Labels ===${NC}"
            echo -e "  ${YELLOW}Instance not in Kubernetes - no labels available${NC}"
            echo ""
        fi
    fi
    
    # Optional: Count Clique Members
    if [[ "$count_clique" == "true" && "$clique_id" != "N/A" && "$clique_id" != "null" && "$in_kubernetes" == "true" ]]; then
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
    elif [[ "$count_clique" == "true" && "$in_kubernetes" != "true" ]]; then
        echo -e "${BOLD}${CYAN}=== Clique Information ===${NC}"
        echo -e "  ${YELLOW}Instance not in Kubernetes - clique information not available${NC}"
        echo ""
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
    
    # Print table header with spanning headers
    # Column positions: DisplayName(28) Node(18) State(11) CliqueID(40) State(10) OCID(95) State(10) Announce(18)
    # K8s spans Node+State+CliqueID (70), OCI Instance spans State+OCID (106), CapTopo spans State (10)
    printf "${BOLD}%-28s %-74s %-121s %-10s %-18s${NC}\n" \
        "" "┌─────────────────────────────────────── K8s ─────────────────────────────────────┐" "                                          ┌──────────────────────── OCI Instance ────────────────────────┐" "CapTopo" ""
    printf "${BOLD}%-28s %-18s %-11s %-40s %-10s %-95s %-10s %-18s${NC}\n" \
        "Display Name" "Node" "State" "Clique ID" "State" "Instance OCID" "State" "Announce"
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
        
        printf "%-28s %-18s ${ns_color}%-11s${NC} %-40s ${st_color}%-10s${NC} %-95s ${ct_color}%-10s${NC} ${ann_color}%-18s${NC}\n" \
            "$display_name" "$node_name" "$node_state" "$clique_id" "$oci_state" "$instance_id" "$cap_topo_state" "$announcements"
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
# GPU MEMORY FABRIC & CLUSTER MANAGEMENT
#===============================================================================

# Display interactive management menu
display_gpu_management_menu() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    # Clear and re-initialize index maps as associative arrays
    unset FABRIC_INDEX_MAP CLUSTER_INDEX_MAP IC_INDEX_MAP CC_INDEX_MAP 2>/dev/null
    declare -gA FABRIC_INDEX_MAP=()
    declare -gA CLUSTER_INDEX_MAP=()
    declare -gA IC_INDEX_MAP=()
    declare -gA CC_INDEX_MAP=()
    
    # Fetch all required data
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_instance_configurations
    fetch_compute_clusters
    
    # Get compartment name
    local compartment_name="N/A"
    if [[ -n "$compartment_id" ]]; then
        compartment_name=$(oci iam compartment get --compartment-id "$compartment_id" --query 'data.name' --raw-output 2>/dev/null) || compartment_name="N/A"
    fi
    
    # Get availability domain from compute clusters (first one found)
    local availability_domain="N/A"
    if [[ -f "$COMPUTE_CLUSTER_CACHE" ]]; then
        availability_domain=$(grep -v '^#' "$COMPUTE_CLUSTER_CACHE" 2>/dev/null | head -1 | cut -d'|' -f3)
        [[ -z "$availability_domain" ]] && availability_domain="N/A"
    fi
    
    echo ""
    echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║                                              GPU MEMORY FABRIC & CLUSTER MANAGEMENT                                                                   ║${NC}"
    echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # ========== ENVIRONMENT INFO ==========
    echo -e "${BOLD}${WHITE}Environment:${NC}"
    echo -e "  ${CYAN}Region:${NC}              ${WHITE}${region}${NC}"
    echo -e "  ${CYAN}Availability Domain:${NC} ${WHITE}${availability_domain}${NC}"
    echo -e "  ${CYAN}Compartment:${NC}         ${WHITE}${compartment_name}${NC}"
    echo -e "                       ${YELLOW}${compartment_id}${NC}"
    echo ""
    
    # ========== GPU MEMORY FABRICS WITH LINKED CLUSTERS ==========
    echo -e "${BOLD}${ORANGE}═══ GPU Memory Fabrics & Clusters ═══${NC}"
    echo ""
    
    # Header for fabrics - aligned columns (no firmware)
    printf "${BOLD}%-5s %-45s %-12s %8s %6s%6s  %s${NC}\n" \
        "ID" "Display Name" "State" "Healthy" "Avail" "Total" "OCID"
    print_separator 158
    
    local fabric_idx=0
    local cluster_idx=0
    
    if [[ -f "$FABRIC_CACHE" ]]; then
        while IFS='|' read -r fabric_name fabric_suffix fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts current_fw target_fw fw_state; do
            [[ "$fabric_name" =~ ^#.*$ ]] && continue
            [[ -z "$fabric_ocid" ]] && continue
            
            ((fabric_idx++))
            local fid="f${fabric_idx}"
            FABRIC_INDEX_MAP[$fid]="$fabric_ocid"
            
            # Color state
            local state_color
            case "$fabric_state" in
                AVAILABLE) state_color="$GREEN" ;;
                *) state_color="$RED" ;;
            esac
            
            # Color available hosts
            local avail_color="$WHITE"
            [[ "$avail_hosts" != "0" && "$avail_hosts" != "N/A" ]] && avail_color="$LIGHT_GREEN"
            
            # Print fabric line: main info with OCID on same line
            printf "${YELLOW}%-5s${NC} ${CYAN}%-45s${NC} ${state_color}%-12s${NC} ${WHITE}%8s${NC} ${avail_color}%6s${NC}${WHITE}%6s${NC}  ${YELLOW}%s${NC}\n" \
                "$fid" "$fabric_name" "$fabric_state" "$healthy_hosts" "$avail_hosts" "$total_hosts" "$fabric_ocid"
            
            # Find and display clusters for this fabric
            local clusters_found=0
            if [[ -f "$CLUSTER_CACHE" ]]; then
                # Collect clusters for this fabric (include ACTIVE, UPDATING, SCALING, CREATING states)
                local cluster_lines=()
                while IFS='|' read -r cluster_ocid cluster_name cluster_state cluster_fabric_suffix instance_config_id compute_cluster_id cluster_size; do
                    [[ "$cluster_ocid" =~ ^#.*$ ]] && continue
                    [[ -z "$cluster_ocid" ]] && continue
                    # Include ACTIVE, UPDATING, SCALING, and CREATING states
                    [[ "$cluster_state" != "ACTIVE" && "$cluster_state" != "UPDATING" && "$cluster_state" != "SCALING" && "$cluster_state" != "CREATING" ]] && continue
                    [[ "$cluster_fabric_suffix" != "$fabric_suffix" ]] && continue
                    
                    cluster_lines+=("$cluster_ocid|$cluster_name|$cluster_state|$cluster_fabric_suffix|$instance_config_id|$compute_cluster_id|$cluster_size")
                done < <(grep -v '^#' "$CLUSTER_CACHE" 2>/dev/null)
                
                local num_clusters=${#cluster_lines[@]}
                local cluster_i=0
                
                for cluster_line in "${cluster_lines[@]}"; do
                    ((cluster_i++))
                    ((cluster_idx++))
                    ((clusters_found++))
                    
                    local cluster_ocid cluster_name cluster_state cluster_fabric_suffix instance_config_id compute_cluster_id cluster_size
                    IFS='|' read -r cluster_ocid cluster_name cluster_state cluster_fabric_suffix instance_config_id compute_cluster_id cluster_size <<< "$cluster_line"
                    
                    local gid="g${cluster_idx}"
                    CLUSTER_INDEX_MAP[$gid]="$cluster_ocid"
                    
                    # Get instance config name (full name, no truncation)
                    local ic_name="N/A"
                    [[ "$instance_config_id" != "N/A" && -n "$instance_config_id" ]] && ic_name=$(get_instance_config_name "$instance_config_id")
                    
                    # Get compute cluster name
                    local cc_name="N/A"
                    [[ "$compute_cluster_id" != "N/A" && -n "$compute_cluster_id" ]] && cc_name=$(get_compute_cluster_name "$compute_cluster_id")
                    
                    # Tree connector
                    local connector="├──"
                    local continuation="│"
                    [[ $cluster_i -eq $num_clusters ]] && { connector="└──"; continuation=" "; }
                    
                    # Determine state color
                    local state_color="$GREEN"
                    case "$cluster_state" in
                        ACTIVE) state_color="$GREEN" ;;
                        CREATING) state_color="$CYAN" ;;
                        UPDATING|SCALING) state_color="$YELLOW" ;;
                        FAILED|INACTIVE|DELETED|DELETING) state_color="$RED" ;;
                        *) state_color="$WHITE" ;;
                    esac
                    
                    # Cluster line 1: ID, Name, State (aligned), Size (aligned with Total), OCID on same line
                    printf "     ${WHITE}${connector}${NC} ${YELLOW}%-4s${NC} ${MAGENTA}%-37s${NC} ${state_color}%-12s${NC} %8s %6s${WHITE}%6s${NC}  ${YELLOW}%s${NC}\n" \
                        "$gid" "$cluster_name" "$cluster_state" "" "" "$cluster_size" "$cluster_ocid"
                    
                    # Cluster line 2: Instance Configuration (full name)
                    printf "     ${WHITE}${continuation}${NC}            ${GRAY}Instance Config: ${GREEN}%s${NC}\n" "$ic_name"
                    
                    # Cluster line 3: Compute Cluster
                    printf "     ${WHITE}${continuation}${NC}            ${GRAY}Compute Cluster: ${BLUE}%s${NC}\n" "$cc_name"
                done
            fi
            
            # Show message if no clusters for this fabric
            if [[ $clusters_found -eq 0 ]]; then
                printf "     ${WHITE}└──${NC} ${GRAY}(no clusters)${NC}\n"
            fi
            
            echo ""
        done < <(grep -v '^#' "$FABRIC_CACHE" 2>/dev/null)
    fi
    
    [[ $fabric_idx -eq 0 ]] && echo -e "  ${YELLOW}No GPU Memory Fabrics found${NC}"
    echo ""
    
    # ========== INSTANCE CONFIGURATIONS ==========
    echo -e "${BOLD}${GREEN}═══ Instance Configurations ═══${NC}"
    echo ""
    printf "${BOLD}%-5s %-60s %s${NC}\n" "ID" "Instance Configuration Name" "OCID"
    print_separator 140
    
    local ic_idx=0
    if [[ -f "$INSTANCE_CONFIG_CACHE" ]]; then
        while IFS='|' read -r ic_ocid ic_name; do
            [[ "$ic_ocid" =~ ^#.*$ ]] && continue
            [[ -z "$ic_ocid" ]] && continue
            
            ((ic_idx++))
            local iid="i${ic_idx}"
            IC_INDEX_MAP[$iid]="$ic_ocid"
            
            printf "${YELLOW}%-5s${NC} ${WHITE}%-60s${NC} ${CYAN}%s${NC}\n" \
                "$iid" "$ic_name" "$ic_ocid"
        done < <(grep -v '^#' "$INSTANCE_CONFIG_CACHE" 2>/dev/null)
    fi
    
    [[ $ic_idx -eq 0 ]] && echo -e "  ${YELLOW}No Instance Configurations found${NC}"
    echo ""
    
    # ========== COMPUTE CLUSTERS ==========
    echo -e "${BOLD}${BLUE}═══ Compute Clusters ═══${NC}"
    echo ""
    printf "${BOLD}%-5s %-60s %s${NC}\n" "ID" "Compute Cluster Name" "OCID"
    print_separator 140
    
    local cc_idx=0
    if [[ -f "$COMPUTE_CLUSTER_CACHE" ]]; then
        while IFS='|' read -r cc_ocid cc_name cc_ad; do
            [[ "$cc_ocid" =~ ^#.*$ ]] && continue
            [[ -z "$cc_ocid" ]] && continue
            
            ((cc_idx++))
            local cid="c${cc_idx}"
            CC_INDEX_MAP[$cid]="$cc_ocid"
            
            printf "${YELLOW}%-5s${NC} ${WHITE}%-60s${NC} ${CYAN}%s${NC}\n" \
                "$cid" "$cc_name" "$cc_ocid"
        done < <(grep -v '^#' "$COMPUTE_CLUSTER_CACHE" 2>/dev/null)
    fi
    
    [[ $cc_idx -eq 0 ]] && echo -e "  ${YELLOW}No Compute Clusters found${NC}"
    echo ""
}

# Interactive prompt for GPU management
#===============================================================================
# INTERACTIVE MANAGEMENT MAIN MENU
#===============================================================================

interactive_management_main_menu() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    while true; do
        echo ""
        echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${BLUE}║                                                    OCI RESOURCE MANAGEMENT                                                                            ║${NC}"
        echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}Environment:${NC}"
        echo -e "  ${CYAN}Region:${NC}      ${WHITE}${region}${NC}"
        echo -e "  ${CYAN}Compartment:${NC} ${YELLOW}${compartment_id}${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}═══ Select a Resource to Manage ═══${NC}"
        echo ""
        echo -e "  ${GREEN}1${NC}) ${WHITE}OKE Cluster Environment${NC}       - View OKE cluster details, VCN, and compute cluster"
        echo -e "  ${GREEN}2${NC}) ${WHITE}Network Resources${NC}             - View subnets and NSGs grouped by function"
        echo -e "  ${GREEN}3${NC}) ${WHITE}GPU Memory Fabrics & Clusters${NC} - Manage GPU memory fabrics and clusters"
        echo -e "  ${GREEN}4${NC}) ${WHITE}Compute Instances${NC}             - View instance details, IPs, and volumes"
        echo ""
        echo -e "  ${RED}q${NC}) ${WHITE}Quit${NC}"
        echo ""
        echo -n -e "${BOLD}${CYAN}Enter selection [1-4, q]: ${NC}"
        
        local choice
        read -r choice
        
        # Empty input exits
        if [[ -z "$choice" ]]; then
            echo -e "${GREEN}Exiting management mode${NC}"
            break
        fi
        
        case "$choice" in
            1)
                manage_oke_cluster
                ;;
            2)
                manage_network_resources
                ;;
            3)
                interactive_gpu_management
                ;;
            4)
                manage_compute_instances
                ;;
            q|Q|quit|QUIT|exit|EXIT)
                echo ""
                echo -e "${GREEN}Exiting management mode${NC}"
                break
                ;;
            *)
                echo -e "${RED}Invalid selection. Please enter 1-4, or q.${NC}"
                ;;
        esac
    done
}

#--------------------------------------------------------------------------------
# Manage OKE Cluster - Display comprehensive OKE cluster details
#--------------------------------------------------------------------------------
manage_oke_cluster() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}                                                         OKE CLUSTER MANAGEMENT                                                                        ${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    
    # Fetch/refresh cache
    fetch_oke_environment "$compartment_id" "$region"
    
    # Read values from cache
    local cluster_ocid vcn_ocid
    cluster_ocid=$(get_oke_env_value "OKE_CLUSTER_ID")
    vcn_ocid=$(get_oke_env_value "VCN_OCID")
    
    if [[ -z "$cluster_ocid" || "$cluster_ocid" == "N/A" ]]; then
        echo -e "${YELLOW}No OKE cluster found in this compartment/region.${NC}"
        echo ""
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # Fetch cluster details
    local cluster_json
    cluster_json=$(oci ce cluster get --cluster-id "$cluster_ocid" --output json 2>/dev/null)
    
    if [[ -z "$cluster_json" ]]; then
        echo -e "${RED}Failed to fetch cluster details${NC}"
        echo ""
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # Extract cluster info
    local cluster_name cluster_state k8s_version
    cluster_name=$(echo "$cluster_json" | jq -r '.data.name // "N/A"')
    cluster_state=$(echo "$cluster_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    k8s_version=$(echo "$cluster_json" | jq -r '.data["kubernetes-version"] // "N/A"')
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Cluster Overview ═══${NC}"
    echo ""
    echo -e "${CYAN}Cluster Name:${NC}    ${WHITE}$cluster_name${NC}"
    echo -e "${CYAN}OCID:${NC}            ${YELLOW}$cluster_ocid${NC}"
    echo -e "${CYAN}State:${NC}           ${GREEN}$cluster_state${NC}"
    echo -e "${CYAN}K8s Version:${NC}     ${WHITE}$k8s_version${NC}"
    
    # Check for available upgrades
    echo ""
    echo -e "${BOLD}${WHITE}═══ Upgrade Status ═══${NC}"
    echo ""
    
    # Get available kubernetes versions for comparison
    local available_versions_json
    available_versions_json=$(oci ce cluster-options get --cluster-option-id all --output json 2>/dev/null)
    
    if [[ -n "$available_versions_json" ]]; then
        # Get list of versions newer than current
        local all_versions current_major current_minor
        current_major=$(echo "$k8s_version" | cut -d'.' -f1 | tr -d 'v')
        current_minor=$(echo "$k8s_version" | cut -d'.' -f2)
        
        # Extract versions and find upgrades
        local upgrade_versions
        upgrade_versions=$(echo "$available_versions_json" | jq -r --arg curr "$k8s_version" '
            (.data["kubernetes-versions"] // [])[] |
            select(. > $curr) | .
        ' 2>/dev/null | head -5 | tr '\n' ', ' | sed 's/,$//')
        
        if [[ -n "$upgrade_versions" ]]; then
            echo -e "${YELLOW}⬆ Upgrade Available!${NC}"
            echo -e "  Current Version:   ${WHITE}$k8s_version${NC}"
            echo -e "  Available Upgrades: ${GREEN}$upgrade_versions${NC}"
        else
            echo -e "${GREEN}✓ Cluster is running latest available version${NC}"
            echo -e "  Current Version:   ${WHITE}$k8s_version${NC}"
        fi
    else
        echo -e "${WHITE}Current Version: $k8s_version${NC}"
        echo -e "${WHITE}(Unable to check for available upgrades)${NC}"
    fi
    
    # Network info
    echo ""
    echo -e "${BOLD}${WHITE}═══ Network Configuration ═══${NC}"
    echo ""
    
    # Extract OCIDs
    local vcn_id endpoint_subnet_id svc_lb_subnet_id
    vcn_id=$(echo "$cluster_json" | jq -r '.data["vcn-id"] // "N/A"')
    endpoint_subnet_id=$(echo "$cluster_json" | jq -r '.data["endpoint-config"]["subnet-id"] // "N/A"')
    svc_lb_subnet_id=$(echo "$cluster_json" | jq -r '.data.options["service-lb-subnet-ids"][0] // "N/A"')
    local public_endpoint pods_cidr services_cidr cni_type
    public_endpoint=$(echo "$cluster_json" | jq -r '.data["endpoint-config"]["is-public-ip-enabled"] // false')
    pods_cidr=$(echo "$cluster_json" | jq -r '.data.options["kubernetes-network-config"]["pods-cidr"] // "N/A"')
    services_cidr=$(echo "$cluster_json" | jq -r '.data.options["kubernetes-network-config"]["services-cidr"] // "N/A"')
    cni_type=$(echo "$cluster_json" | jq -r '.data["cluster-pod-network-options"][0]["cni-type"] // "N/A"')
    
    # Resolve VCN name
    local vcn_name="N/A"
    if [[ "$vcn_id" != "N/A" && -n "$vcn_id" ]]; then
        vcn_name=$(oci network vcn get --vcn-id "$vcn_id" --query 'data."display-name"' --raw-output 2>/dev/null) || vcn_name="N/A"
    fi
    
    # Resolve Endpoint Subnet name
    local endpoint_subnet_name="N/A"
    if [[ "$endpoint_subnet_id" != "N/A" && -n "$endpoint_subnet_id" ]]; then
        endpoint_subnet_name=$(oci network subnet get --subnet-id "$endpoint_subnet_id" --query 'data."display-name"' --raw-output 2>/dev/null) || endpoint_subnet_name="N/A"
    fi
    
    # Resolve Service LB Subnet name
    local svc_lb_subnet_name="N/A"
    if [[ "$svc_lb_subnet_id" != "N/A" && -n "$svc_lb_subnet_id" ]]; then
        svc_lb_subnet_name=$(oci network subnet get --subnet-id "$svc_lb_subnet_id" --query 'data."display-name"' --raw-output 2>/dev/null) || svc_lb_subnet_name="N/A"
    fi
    
    # Display with names (OCIDs)
    echo -e "VCN:                 ${GREEN}$vcn_name${NC} ${YELLOW}($vcn_id)${NC}"
    echo -e "Endpoint Subnet:     ${GREEN}$endpoint_subnet_name${NC} ${YELLOW}($endpoint_subnet_id)${NC}"
    echo "Public Endpoint:     $public_endpoint"
    echo -e "Service LB Subnet:   ${GREEN}$svc_lb_subnet_name${NC} ${YELLOW}($svc_lb_subnet_id)${NC}"
    echo "Pods CIDR:           $pods_cidr"
    echo "Services CIDR:       $services_cidr"
    echo "CNI Type:            $cni_type"
    
    # Endpoints
    echo ""
    echo -e "${BOLD}${WHITE}═══ Cluster Endpoints ═══${NC}"
    echo ""
    echo "$cluster_json" | jq -r '
        (.data.endpoints // {}) |
        "Kubernetes API:      \(.kubernetes // "N/A")",
        "Public Endpoint:     \(.["public-endpoint"] // "N/A")",
        "Private Endpoint:    \(.["private-endpoint"] // "N/A")"
    ' 2>/dev/null
    
    # Addons - show all available with status (installed first, then available)
    echo ""
    echo -e "${BOLD}${WHITE}═══ Cluster Addons ═══${NC}"
    echo ""
    
    # Build addon map for selection (global for action handling)
    declare -gA ADDON_MAP=()
    declare -gA ADDON_STATUS=()
    declare -gA ADDON_VERSIONS=()
    local addon_idx=0
    
    # Try to detect installed addons via kubectl (check kube-system deployments/daemonsets)
    declare -A INSTALLED_ADDONS
    local kubectl_available=false
    if command -v kubectl &>/dev/null; then
        # Get deployments and daemonsets in kube-system
        local kube_resources
        kube_resources=$(kubectl get deployments,daemonsets -n kube-system -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
        if [[ -n "$kube_resources" ]]; then
            kubectl_available=true
            # Map common addon names to their k8s resource names
            echo "$kube_resources" | grep -qi "cert-manager" && INSTALLED_ADDONS["CertManager"]="ACTIVE"
            echo "$kube_resources" | grep -qi "coredns" && INSTALLED_ADDONS["CoreDNS"]="ACTIVE"
            echo "$kube_resources" | grep -qi "kube-proxy" && INSTALLED_ADDONS["KubeProxy"]="ACTIVE"
            echo "$kube_resources" | grep -qi "nvidia" && INSTALLED_ADDONS["NvidiaGpuPlugin"]="ACTIVE"
            echo "$kube_resources" | grep -qi "amd.*gpu" && INSTALLED_ADDONS["AmdGpuPlugin"]="ACTIVE"
            echo "$kube_resources" | grep -qi "vcn-native\|oci-native" && INSTALLED_ADDONS["OciVcnIpNative"]="ACTIVE"
            echo "$kube_resources" | grep -qi "flannel" && INSTALLED_ADDONS["Flannel"]="ACTIVE"
            echo "$kube_resources" | grep -qi "metrics-server" && INSTALLED_ADDONS["KubernetesMetricsServer"]="ACTIVE"
            echo "$kube_resources" | grep -qi "cluster-autoscaler" && INSTALLED_ADDONS["ClusterAutoscaler"]="ACTIVE"
            echo "$kube_resources" | grep -qi "dashboard" && INSTALLED_ADDONS["KubernetesDashboard"]="ACTIVE"
            echo "$kube_resources" | grep -qi "istio" && INSTALLED_ADDONS["Istio"]="ACTIVE"
            echo "$kube_resources" | grep -qi "weblogic" && INSTALLED_ADDONS["WeblogicKubernetesOperator"]="ACTIVE"
        fi
    fi
    
    # Get all available addon options
    local addon_options_json
    addon_options_json=$(oci ce addon-option list --kubernetes-version "$k8s_version" --all --output json 2>/dev/null)
    
    local has_addons=false
    
    # Collect addons into two arrays: installed and available
    declare -a installed_addons=()
    declare -a available_addons=()
    
    # Parse addon-option list - structure is .data[] with name, description, is-essential, versions[]
    if [[ -n "$addon_options_json" ]] && echo "$addon_options_json" | jq -e '.data' >/dev/null 2>&1; then
        while IFS=$'\t' read -r name description is_essential default_version; do
            [[ -z "$name" ]] && continue
            has_addons=true
            
            local essential_display="No"
            [[ "$is_essential" == "true" ]] && essential_display="Yes"
            
            # Truncate description for display
            local desc_display="${description:0:36}"
            
            # Store as: name|version|essential|description
            local addon_line="${name}|${default_version}|${essential_display}|${desc_display}"
            
            # Check if installed via kubectl detection
            if [[ -n "${INSTALLED_ADDONS[$name]:-}" ]]; then
                installed_addons+=("$addon_line")
            else
                available_addons+=("$addon_line")
            fi
        done < <(echo "$addon_options_json" | jq -r '.data[] | [.name, (.description // ""), ((.["is-essential"] // false) | tostring), ((.versions // [])[0]["version-number"] // "N/A")] | @tsv' 2>/dev/null)
    fi
    
    if [[ "$has_addons" == "true" ]]; then
        printf "${BOLD}%-4s %-25s %-12s %-20s %-10s %s${NC}\n" "#" "Addon Name" "Status" "Version" "Essential" "Description"
        printf "${WHITE}%-4s %-25s %-12s %-20s %-10s %s${NC}\n" "----" "-------------------------" "------------" "--------------------" "----------" "------------------------------------"
        
        # Display installed addons first (green)
        for addon_line in "${installed_addons[@]}"; do
            IFS='|' read -r name version essential desc <<< "$addon_line"
            ((addon_idx++))
            ADDON_MAP[$addon_idx]="$name"
            ADDON_VERSIONS[$addon_idx]="$version"
            ADDON_STATUS[$addon_idx]="INSTALLED"
            
            printf "${YELLOW}%-4s${NC} %-25s ${GREEN}%-12s${NC} %-20s %-10s %s\n" \
                "$addon_idx" "${name:0:25}" "INSTALLED" "${version:0:20}" "$essential" "$desc"
        done
        
        # Display available addons (white)
        for addon_line in "${available_addons[@]}"; do
            IFS='|' read -r name version essential desc <<< "$addon_line"
            ((addon_idx++))
            ADDON_MAP[$addon_idx]="$name"
            ADDON_VERSIONS[$addon_idx]="$version"
            ADDON_STATUS[$addon_idx]="NOT_INSTALLED"
            
            printf "${YELLOW}%-4s${NC} %-25s ${WHITE}%-12s${NC} %-20s %-10s %s\n" \
                "$addon_idx" "${name:0:25}" "AVAILABLE" "${version:0:20}" "$essential" "$desc"
        done
        
        echo ""
        if [[ "$kubectl_available" == "true" ]]; then
            echo -e "${WHITE}(${#installed_addons[@]} installed, ${#available_addons[@]} available - status detected via kubectl)${NC}"
        else
            echo -e "${WHITE}(kubectl not available - cannot detect installed status)${NC}"
        fi
    else
        echo -e "${YELLOW}Unable to fetch addon options for kubernetes version $k8s_version${NC}"
    fi
    
    # Node Pools
    echo ""
    echo -e "${BOLD}${WHITE}═══ Node Pools ═══${NC}"
    echo ""
    local nodepools_json
    nodepools_json=$(oci ce node-pool list --compartment-id "$compartment_id" --cluster-id "$cluster_ocid" --output json 2>/dev/null)
    
    if [[ -n "$nodepools_json" ]] && echo "$nodepools_json" | jq -e '.data' >/dev/null 2>&1; then
        local nodepool_count
        nodepool_count=$(echo "$nodepools_json" | jq '(.data // []) | length')
        
        if [[ "$nodepool_count" -gt 0 ]]; then
            printf "${BOLD}%-30s %-12s %-8s %-25s %s${NC}\n" "Node Pool Name" "State" "Size" "Shape" "K8s Version"
            printf "${WHITE}%-30s %-12s %-8s %-25s %s${NC}\n" "------------------------------" "------------" "--------" "-------------------------" "---------------"
            
            echo "$nodepools_json" | jq -r '
                (.data // [])[] |
                [
                    (.name // "N/A"),
                    (.["lifecycle-state"] // "N/A"),
                    ((.["node-config-details"]["size"] // .["node-pool-size"]) // "N/A" | tostring),
                    (.["node-shape"] // "N/A"),
                    (.["kubernetes-version"] // "N/A")
                ] | @tsv
            ' 2>/dev/null | while IFS=$'\t' read -r name state size shape version; do
                local state_color="$GREEN"
                [[ "$state" != "ACTIVE" ]] && state_color="$YELLOW"
                [[ "$state" == "FAILED" || "$state" == "DELETED" ]] && state_color="$RED"
                printf "%-30s ${state_color}%-12s${NC} %-8s %-25s %s\n" "${name:0:30}" "$state" "$size" "${shape:0:25}" "$version"
            done
            
            # Show node pool details with resolved subnet names
            echo ""
            echo -e "${BOLD}${WHITE}── Node Pool Details ──${NC}"
            
            # Process each node pool
            echo "$nodepools_json" | jq -r '
                (.data // [])[] |
                "\(.name // "Unknown")|\(.id // "N/A")|\(((.["node-config-details"]["placement-configs"] // []) | map(.["subnet-id"] // "N/A") | unique | join(",")))"
            ' 2>/dev/null | while IFS='|' read -r np_name np_id np_subnet_ids; do
                echo ""
                echo -e "  ${CYAN}$np_name${NC} ${YELLOW}($np_id)${NC}"
                
                # Resolve subnet names
                if [[ -n "$np_subnet_ids" && "$np_subnet_ids" != "N/A" ]]; then
                    IFS=',' read -ra subnet_array <<< "$np_subnet_ids"
                    local subnet_display=""
                    for subnet_id in "${subnet_array[@]}"; do
                        [[ -z "$subnet_id" || "$subnet_id" == "N/A" ]] && continue
                        local subnet_name
                        subnet_name=$(oci network subnet get --subnet-id "$subnet_id" --query 'data."display-name"' --raw-output 2>/dev/null) || subnet_name="N/A"
                        if [[ -n "$subnet_display" ]]; then
                            subnet_display="$subnet_display, $subnet_name ($subnet_id)"
                        else
                            subnet_display="$subnet_name ($subnet_id)"
                        fi
                    done
                    echo -e "    Subnets: ${GREEN}$subnet_display${NC}"
                else
                    echo "    Subnets: N/A"
                fi
            done
        else
            echo -e "${YELLOW}No node pools configured${NC}"
        fi
    else
        echo -e "${WHITE}No node pools found or unable to fetch${NC}"
    fi
    
    # Timestamps
    echo ""
    echo -e "${BOLD}${WHITE}═══ Timestamps ═══${NC}"
    echo ""
    local time_created time_updated
    # Try different possible field locations
    time_created=$(echo "$cluster_json" | jq -r '
        .data["time-created"] // 
        .data.timeCreated // 
        .data.metadata["time-created"] // 
        .data.metadata.timeCreated // 
        "N/A"' 2>/dev/null)
    time_updated=$(echo "$cluster_json" | jq -r '
        .data["time-updated"] // 
        .data.timeUpdated // 
        .data.metadata["time-updated"] // 
        .data.metadata["updated-time"] // 
        .data.metadata.timeUpdated //
        "N/A"' 2>/dev/null)
    echo "Created:             $time_created"
    if [[ "$time_updated" == "N/A" || -z "$time_updated" || "$time_updated" == "null" ]]; then
        echo "Updated:             (not tracked by OCI)"
    else
        echo "Updated:             $time_updated"
    fi
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Actions ═══${NC}"
    if [[ $addon_idx -gt 0 ]]; then
        echo -e "  ${YELLOW}1-${addon_idx}${NC}       - Addon numbers for 'info' command"
    fi
    echo -e "  ${CYAN}info #${NC}    - Show addon details and install instructions (e.g., 'info 3')"
    echo -e "  ${CYAN}refresh${NC}   - Refresh OKE cluster data"
    echo -e "  ${CYAN}back${NC}      - Return to main menu"
    echo ""
    echo -e "${WHITE}Note: Addon installation/removal is done via OCI Console or Terraform${NC}"
    echo ""
    
    while true; do
        local prompt_range=""
        [[ $addon_idx -gt 0 ]] && prompt_range="1-${addon_idx}, "
        echo -n -e "${BOLD}${CYAN}Enter # or command [${prompt_range}info/refresh/back]: ${NC}"
        local input
        read -r input
        
        # Empty input goes back
        if [[ -z "$input" ]]; then
            return
        fi
        
        case "$input" in
            [0-9]|[0-9][0-9]|[0-9][0-9][0-9])
                # Direct number input - treat as info command
                local addon_num="$input"
                if [[ -n "${ADDON_MAP[$addon_num]:-}" ]]; then
                    local addon_name="${ADDON_MAP[$addon_num]}"
                    local addon_version="${ADDON_VERSIONS[$addon_num]:-}"
                    local addon_status="${ADDON_STATUS[$addon_num]:-NOT_INSTALLED}"
                    
                    echo ""
                    echo -e "${BOLD}${CYAN}═══ Addon: $addon_name ═══${NC}"
                    echo ""
                    echo -e "  ${WHITE}Version:${NC}  $addon_version"
                    echo -e "  ${WHITE}Status:${NC}   $addon_status"
                    echo ""
                    
                    # Get detailed info from addon-option
                    local addon_detail
                    addon_detail=$(oci ce addon-option list --kubernetes-version "$k8s_version" --addon-name "$addon_name" --output json 2>/dev/null)
                    if [[ -n "$addon_detail" ]] && echo "$addon_detail" | jq -e '.data[0]' >/dev/null 2>&1; then
                        local description
                        description=$(echo "$addon_detail" | jq -r '.data[0].description // "N/A"')
                        local addon_group
                        addon_group=$(echo "$addon_detail" | jq -r '.data[0]["addon-group"] // "N/A"')
                        local is_essential
                        is_essential=$(echo "$addon_detail" | jq -r '.data[0]["is-essential"] // false')
                        
                        echo -e "  ${WHITE}Group:${NC}       $addon_group"
                        echo -e "  ${WHITE}Essential:${NC}   $is_essential"
                        echo -e "  ${WHITE}Description:${NC}"
                        echo "$description" | fold -s -w 70 | sed 's/^/    /'
                        
                        # Show available versions
                        echo ""
                        echo -e "  ${WHITE}Available Versions:${NC}"
                        echo "$addon_detail" | jq -r '.data[0].versions[]? | "    - \(.["version-number"]) (\(.status))"' 2>/dev/null | head -5
                    fi
                    
                    echo ""
                    echo -e "${BOLD}${WHITE}To Install/Remove:${NC}"
                    echo -e "  ${CYAN}OCI Console:${NC} Cluster Details → Resources → Add-ons"
                    echo -e "  ${CYAN}Terraform:${NC}   oci_containerengine_addon resource"
                    echo ""
                    echo -e "  ${WHITE}Terraform Example:${NC}"
                    echo -e "    resource \"oci_containerengine_addon\" \"${addon_name,,}\" {"
                    echo -e "      addon_name                    = \"$addon_name\""
                    echo -e "      cluster_id                    = \"$cluster_ocid\""
                    echo -e "      remove_addon_resources_on_delete = true"
                    echo -e "    }"
                    echo ""
                else
                    echo -e "${RED}Invalid addon number: $addon_num (valid: 1-${addon_idx})${NC}"
                fi
                ;;
            info\ [0-9]*|INFO\ [0-9]*)
                local addon_num="${input#* }"
                if [[ -n "${ADDON_MAP[$addon_num]:-}" ]]; then
                    local addon_name="${ADDON_MAP[$addon_num]}"
                    local addon_version="${ADDON_VERSIONS[$addon_num]:-}"
                    local addon_status="${ADDON_STATUS[$addon_num]:-NOT_INSTALLED}"
                    
                    echo ""
                    echo -e "${BOLD}${CYAN}═══ Addon: $addon_name ═══${NC}"
                    echo ""
                    echo -e "  ${WHITE}Version:${NC}  $addon_version"
                    echo -e "  ${WHITE}Status:${NC}   $addon_status"
                    echo ""
                    
                    # Get detailed info from addon-option
                    local addon_detail
                    addon_detail=$(oci ce addon-option list --kubernetes-version "$k8s_version" --addon-name "$addon_name" --output json 2>/dev/null)
                    if [[ -n "$addon_detail" ]] && echo "$addon_detail" | jq -e '.data[0]' >/dev/null 2>&1; then
                        local description
                        description=$(echo "$addon_detail" | jq -r '.data[0].description // "N/A"')
                        local addon_group
                        addon_group=$(echo "$addon_detail" | jq -r '.data[0]["addon-group"] // "N/A"')
                        local is_essential
                        is_essential=$(echo "$addon_detail" | jq -r '.data[0]["is-essential"] // false')
                        
                        echo -e "  ${WHITE}Group:${NC}       $addon_group"
                        echo -e "  ${WHITE}Essential:${NC}   $is_essential"
                        echo -e "  ${WHITE}Description:${NC}"
                        echo "$description" | fold -s -w 70 | sed 's/^/    /'
                        
                        # Show available versions
                        echo ""
                        echo -e "  ${WHITE}Available Versions:${NC}"
                        echo "$addon_detail" | jq -r '.data[0].versions[]? | "    - \(.["version-number"]) (\(.status))"' 2>/dev/null | head -5
                    fi
                    
                    echo ""
                    echo -e "${BOLD}${WHITE}To Install/Remove:${NC}"
                    echo -e "  ${CYAN}OCI Console:${NC} Cluster Details → Resources → Add-ons"
                    echo -e "  ${CYAN}Terraform:${NC}   oci_containerengine_addon resource"
                    echo ""
                    echo -e "  ${WHITE}Terraform Example:${NC}"
                    echo -e "    resource \"oci_containerengine_addon\" \"${addon_name,,}\" {"
                    echo -e "      addon_name                    = \"$addon_name\""
                    echo -e "      cluster_id                    = \"$cluster_ocid\""
                    echo -e "      remove_addon_resources_on_delete = true"
                    echo -e "    }"
                    echo ""
                else
                    echo -e "${RED}Invalid addon number: $addon_num${NC}"
                fi
                ;;
            enable\ [0-9]*|ENABLE\ [0-9]*|disable\ [0-9]*|DISABLE\ [0-9]*)
                echo -e "${YELLOW}Addon enable/disable is not available via OCI CLI.${NC}"
                echo -e "${WHITE}Use 'info #' to see installation instructions for OCI Console or Terraform.${NC}"
                ;;
            refresh|REFRESH)
                echo -e "${YELLOW}Refreshing OKE cluster data...${NC}"
                rm -f "$OKE_ENV_CACHE"
                manage_oke_cluster
                return
                ;;
            back|BACK|b|B|q|Q)
                return
                ;;
            *)
                echo -e "${RED}Unknown command. Enter a number (1-${addon_idx}), 'info #', 'refresh', or 'back'.${NC}"
                ;;
        esac
    done
}

#--------------------------------------------------------------------------------
# Manage Network Resources - Display subnets and NSGs with numbered selections
#--------------------------------------------------------------------------------
manage_network_resources() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    # Initialize resource index maps for this menu
    declare -gA NET_RESOURCE_MAP=()
    local resource_idx=0
    
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                                                       NETWORK RESOURCES MANAGEMENT                                                                     ${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Get VCN info from OKE environment cache
    fetch_oke_environment "$compartment_id" "$region"
    local vcn_ocid vcn_name
    vcn_ocid=$(get_oke_env_value "VCN_OCID")
    vcn_name=$(get_oke_env_value "VCN_NAME")
    
    if [[ -z "$vcn_ocid" || "$vcn_ocid" == "N/A" ]]; then
        echo -e "${YELLOW}No VCN found. Ensure OKE cluster is configured.${NC}"
        echo ""
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # Fetch network resources
    fetch_network_resources "$compartment_id" "$vcn_ocid"
    fetch_all_network_gateways "$compartment_id" "$vcn_ocid"
    
    echo -e "${BOLD}${WHITE}═══ Selectable Resources (enter # for details) ═══${NC}"
    echo ""
    
    # 1. VCN
    ((resource_idx++))
    NET_RESOURCE_MAP[$resource_idx]="VCN|$vcn_ocid"
    printf "  ${YELLOW}%2d${NC}) ${BOLD}${MAGENTA}VCN:${NC}          ${GREEN}%-35s${NC} ${YELLOW}(%s)${NC}\n" \
        "$resource_idx" "$vcn_name" "$vcn_ocid"
    
    echo ""
    echo -e "  ${BOLD}${WHITE}── Subnets ──${NC}"
    
    # Subnets
    if [[ -f "$NETWORK_RESOURCES_CACHE" ]]; then
        while IFS='|' read -r type name cidr access state ocid rt_ocid; do
            [[ "$type" != "SUBNET" ]] && continue
            ((resource_idx++))
            NET_RESOURCE_MAP[$resource_idx]="SUBNET|$ocid"
            
            local access_color
            [[ "$access" == "Private" ]] && access_color="$RED" || access_color="$LIGHT_GREEN"
            
            printf "  ${YELLOW}%2d${NC}) ${WHITE}Subnet:${NC} ${GREEN}%s${NC} ${YELLOW}(%s)${NC} ${WHITE}[${CYAN}%s${WHITE}] [${access_color}%s${WHITE}]${NC}\n" \
                "$resource_idx" "$name" "$ocid" "$cidr" "$access"
        done < <(grep "^SUBNET|" "$NETWORK_RESOURCES_CACHE" 2>/dev/null)
    fi
    
    echo ""
    # Build mappings from Route Tables and Security Lists to Subnet names
    declare -A RT_TO_SUBNETS
    declare -A SL_TO_SUBNETS
    declare -A ASSIGNED_SL_IDS
    
    if [[ -f "$NETWORK_RESOURCES_CACHE" ]]; then
        while IFS='|' read -r type name cidr access state ocid rt_ocid sl_ids; do
            [[ "$type" != "SUBNET" ]] && continue
            
            # Map route table to subnet
            if [[ -n "$rt_ocid" && "$rt_ocid" != "N/A" ]]; then
                if [[ -n "${RT_TO_SUBNETS[$rt_ocid]:-}" ]]; then
                    RT_TO_SUBNETS[$rt_ocid]="${RT_TO_SUBNETS[$rt_ocid]}, $name"
                else
                    RT_TO_SUBNETS[$rt_ocid]="$name"
                fi
            fi
            
            # Map security lists to subnet
            if [[ -n "$sl_ids" ]]; then
                IFS=',' read -ra sl_array <<< "$sl_ids"
                for sl_id in "${sl_array[@]}"; do
                    [[ -z "$sl_id" ]] && continue
                    ASSIGNED_SL_IDS["$sl_id"]=1
                    if [[ -n "${SL_TO_SUBNETS[$sl_id]:-}" ]]; then
                        SL_TO_SUBNETS[$sl_id]="${SL_TO_SUBNETS[$sl_id]}, $name"
                    else
                        SL_TO_SUBNETS[$sl_id]="$name"
                    fi
                done
            fi
        done < "$NETWORK_RESOURCES_CACHE"
    fi
    
    echo -e "  ${BOLD}${WHITE}── Network Security Groups ──${NC}"
    echo -e "  ${WHITE}(NSGs attach to VNICs, not subnets directly)${NC}"
    
    # NSGs
    if [[ -f "$NETWORK_RESOURCES_CACHE" ]]; then
        while IFS='|' read -r type name _ state ocid; do
            [[ "$type" != "NSG" ]] && continue
            ((resource_idx++))
            NET_RESOURCE_MAP[$resource_idx]="NSG|$ocid"
            
            # Get rule counts
            local rule_counts ingress egress
            rule_counts=$(get_nsg_rule_counts "$ocid")
            ingress=$(echo "$rule_counts" | cut -d'|' -f1)
            egress=$(echo "$rule_counts" | cut -d'|' -f2)
            
            printf "  ${YELLOW}%2d${NC}) ${WHITE}NSG:${NC} ${CYAN}%s${NC} ${YELLOW}(%s)${NC} ${WHITE}[In:${GREEN}%s${WHITE} Out:${GREEN}%s${WHITE}]${NC}\n" \
                "$resource_idx" "$name" "$ocid" "$ingress" "$egress"
        done < <(grep "^NSG|" "$NETWORK_RESOURCES_CACHE" 2>/dev/null)
    fi
    
    echo ""
    echo -e "  ${BOLD}${WHITE}── Security Lists ──${NC}"
    
    # Security Lists from SL_CACHE (format: SL_ID|VCN_ID|DISPLAY_NAME|STATE|INGRESS_COUNT|EGRESS_COUNT)
    local sl_count=0
    if [[ -f "$SL_CACHE" ]]; then
        while IFS='|' read -r sl_ocid sl_vcn sl_name sl_state sl_ingress sl_egress; do
            [[ -z "$sl_ocid" || "$sl_ocid" == "#"* ]] && continue
            [[ "$sl_vcn" != "$vcn_ocid" ]] && continue
            # Only show if assigned to a subnet
            [[ -z "${ASSIGNED_SL_IDS[$sl_ocid]:-}" ]] && continue
            ((resource_idx++))
            ((sl_count++))
            NET_RESOURCE_MAP[$resource_idx]="SECURITY_LIST|$sl_ocid"
            
            # Get assigned subnets
            local assigned_subnets="${SL_TO_SUBNETS[$sl_ocid]:-none}"
            
            printf "  ${YELLOW}%2d${NC}) ${WHITE}Security List:${NC} ${MAGENTA}%s${NC} ${YELLOW}(%s)${NC}\n" \
                "$resource_idx" "$sl_name" "$sl_ocid"
            printf "      ${WHITE}[In:${GREEN}%s${WHITE} Out:${GREEN}%s${WHITE}]${NC} ${WHITE}→ Subnets:${NC} ${CYAN}%s${NC}\n" "$sl_ingress" "$sl_egress" "$assigned_subnets"
        done < "$SL_CACHE"
    fi
    [[ $sl_count -eq 0 ]] && echo -e "  ${WHITE}(No security lists assigned to subnets)${NC}"
    
    echo ""
    echo -e "  ${BOLD}${WHITE}── Route Tables ──${NC}"
    
    # Route Tables from RT_CACHE (format: id|vcn-id|display-name|lifecycle-state|route-rules-count)
    if [[ -f "$RT_CACHE" ]]; then
        while IFS='|' read -r rt_ocid rt_vcn rt_name rt_state rt_rules; do
            [[ -z "$rt_ocid" || "$rt_ocid" == "#"* ]] && continue
            [[ "$rt_vcn" != "$vcn_ocid" ]] && continue
            ((resource_idx++))
            NET_RESOURCE_MAP[$resource_idx]="ROUTE_TABLE|$rt_ocid"
            
            # Get assigned subnets
            local assigned_subnets="${RT_TO_SUBNETS[$rt_ocid]:-none}"
            
            printf "  ${YELLOW}%2d${NC}) ${WHITE}Route Table:${NC} ${MAGENTA}%s${NC} ${YELLOW}(%s)${NC}\n" \
                "$resource_idx" "$rt_name" "$rt_ocid"
            printf "      ${WHITE}[Rules:${GREEN}%s${WHITE}]${NC} ${WHITE}→ Subnets:${NC} ${CYAN}%s${NC}\n" "$rt_rules" "$assigned_subnets"
        done < "$RT_CACHE"
    fi
    
    echo ""
    echo -e "  ${BOLD}${WHITE}── Gateways ──${NC}"
    
    # Internet Gateways (format: VCN_ID|IGW_ID|STATE|DISPLAY_NAME)
    if [[ -f "$IGW_CACHE" ]]; then
        while IFS='|' read -r igw_vcn igw_ocid igw_state igw_name; do
            [[ -z "$igw_ocid" || "$igw_vcn" != "$vcn_ocid" ]] && continue
            ((resource_idx++))
            NET_RESOURCE_MAP[$resource_idx]="GATEWAY|IGW|$igw_ocid"
            local state_color="$GREEN"
            [[ "$igw_state" != "AVAILABLE" ]] && state_color="$RED"
            printf "  ${YELLOW}%2d${NC}) ${WHITE}Internet GW:${NC}  ${ORANGE}%s${NC} ${YELLOW}(%s)${NC} ${WHITE}[${state_color}%s${WHITE}]${NC}\n" \
                "$resource_idx" "${igw_name:-N/A}" "$igw_ocid" "$igw_state"
        done < "$IGW_CACHE"
    fi
    
    # NAT Gateways (format: VCN_ID|NAT_ID|STATE|DISPLAY_NAME)
    if [[ -f "$NAT_CACHE" ]]; then
        while IFS='|' read -r nat_vcn nat_ocid nat_state nat_name; do
            [[ -z "$nat_ocid" || "$nat_vcn" != "$vcn_ocid" ]] && continue
            ((resource_idx++))
            NET_RESOURCE_MAP[$resource_idx]="GATEWAY|NAT|$nat_ocid"
            local state_color="$GREEN"
            [[ "$nat_state" != "AVAILABLE" ]] && state_color="$RED"
            printf "  ${YELLOW}%2d${NC}) ${WHITE}NAT GW:${NC}       ${ORANGE}%s${NC} ${YELLOW}(%s)${NC} ${WHITE}[${state_color}%s${WHITE}]${NC}\n" \
                "$resource_idx" "${nat_name:-N/A}" "$nat_ocid" "$nat_state"
        done < "$NAT_CACHE"
    fi
    
    # Service Gateways (format: VCN_ID|SGW_ID|STATE|DISPLAY_NAME)
    if [[ -f "$SGW_CACHE" ]]; then
        while IFS='|' read -r sgw_vcn sgw_ocid sgw_state sgw_name; do
            [[ -z "$sgw_ocid" || "$sgw_vcn" != "$vcn_ocid" ]] && continue
            ((resource_idx++))
            NET_RESOURCE_MAP[$resource_idx]="GATEWAY|SGW|$sgw_ocid"
            local state_color="$GREEN"
            [[ "$sgw_state" != "AVAILABLE" ]] && state_color="$RED"
            printf "  ${YELLOW}%2d${NC}) ${WHITE}Service GW:${NC}   ${ORANGE}%s${NC} ${YELLOW}(%s)${NC} ${WHITE}[${state_color}%s${WHITE}]${NC}\n" \
                "$resource_idx" "${sgw_name:-N/A}" "$sgw_ocid" "$sgw_state"
        done < "$SGW_CACHE"
    fi
    
    # DRG Attachments (format: VCN_ID|DRG_ID|STATE|DISPLAY_NAME)
    if [[ -f "$DRG_CACHE" ]]; then
        while IFS='|' read -r drg_vcn drg_ocid drg_state drg_name; do
            [[ -z "$drg_ocid" || "$drg_vcn" != "$vcn_ocid" ]] && continue
            ((resource_idx++))
            NET_RESOURCE_MAP[$resource_idx]="GATEWAY|DRG|$drg_ocid"
            local state_color="$GREEN"
            [[ "$drg_state" != "ATTACHED" && "$drg_state" != "AVAILABLE" ]] && state_color="$RED"
            printf "  ${YELLOW}%2d${NC}) ${WHITE}DRG Attach:${NC}   ${ORANGE}%s${NC} ${YELLOW}(%s)${NC} ${WHITE}[${state_color}%s${WHITE}]${NC}\n" \
                "$resource_idx" "${drg_name:-N/A}" "$drg_ocid" "$drg_state"
        done < "$DRG_CACHE"
    fi
    
    # Local Peering Gateways (format: VCN_ID|LPG_ID|STATE|PEERING_STATUS|DISPLAY_NAME)
    if [[ -f "$LPG_CACHE" ]]; then
        while IFS='|' read -r lpg_vcn lpg_ocid lpg_state lpg_peer lpg_name; do
            [[ -z "$lpg_ocid" || "$lpg_vcn" != "$vcn_ocid" ]] && continue
            ((resource_idx++))
            NET_RESOURCE_MAP[$resource_idx]="GATEWAY|LPG|$lpg_ocid"
            local state_color="$GREEN"
            [[ "$lpg_state" != "AVAILABLE" ]] && state_color="$RED"
            printf "  ${YELLOW}%2d${NC}) ${WHITE}Local Peer GW:${NC}${ORANGE}%s${NC} ${YELLOW}(%s)${NC} ${WHITE}[${state_color}%s${WHITE}]${NC}\n" \
                "$resource_idx" "${lpg_name:-N/A}" "$lpg_ocid" "$lpg_state"
        done < "$LPG_CACHE"
    fi
    
    local max_idx=$resource_idx
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Actions ═══${NC}"
    if [[ $max_idx -gt 0 ]]; then
        echo -e "  ${YELLOW}1-${max_idx}${NC}       - View resource details"
    fi
    echo -e "  ${CYAN}refresh${NC}   - Refresh network resources data"
    echo -e "  ${CYAN}back${NC}      - Return to main menu"
    echo ""
    
    while true; do
        local prompt_range=""
        [[ $max_idx -gt 0 ]] && prompt_range="1-${max_idx}, "
        echo -n -e "${BOLD}${CYAN}Enter # or command [${prompt_range}refresh/back]: ${NC}"
        local input
        read -r input
        
        # Empty input goes back
        if [[ -z "$input" ]]; then
            return
        fi
        
        # Check if it's a number
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            if [[ $input -ge 1 && $input -le $max_idx ]]; then
                local resource_info="${NET_RESOURCE_MAP[$input]}"
                view_network_resource_detail "$resource_info"
            else
                echo -e "${RED}Invalid selection. Enter 1-${max_idx}.${NC}"
            fi
        else
            case "$input" in
                refresh|REFRESH)
                    echo -e "${YELLOW}Refreshing network resources cache...${NC}"
                    rm -f "$NETWORK_RESOURCES_CACHE" "$RT_CACHE" "$IGW_CACHE" "$NAT_CACHE" "$SGW_CACHE" "$DRG_CACHE" "$LPG_CACHE" "$NSG_RULES_CACHE" "$SL_CACHE"
                    manage_network_resources
                    return
                    ;;
                back|BACK|b|B|q|Q)
                    return
                    ;;
                *)
                    echo -e "${RED}Unknown command. Enter a number (1-${max_idx}), 'refresh', or 'back'.${NC}"
                    ;;
            esac
        fi
    done
}

#--------------------------------------------------------------------------------
# View Network Resource Detail
#--------------------------------------------------------------------------------
view_network_resource_detail() {
    local resource_info="$1"
    local resource_type resource_ocid
    
    # Parse resource info (format: TYPE|OCID or GATEWAY|GW_TYPE|OCID)
    IFS='|' read -r resource_type resource_ocid extra_info <<< "$resource_info"
    
    echo ""
    
    case "$resource_type" in
        VCN)
            echo -e "${BOLD}${MAGENTA}=== VCN Details ===${NC}"
            
            local vcn_json
            vcn_json=$(oci network vcn get --vcn-id "$resource_ocid" --output json 2>/dev/null)
            
            if [[ -n "$vcn_json" ]]; then
                local vcn_name
                vcn_name=$(echo "$vcn_json" | jq -r '.data["display-name"] // "N/A"')
                echo -e "${WHITE}Name:${NC} ${GREEN}$vcn_name${NC}"
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$resource_ocid${NC}"
                echo ""
                
                # Extract basic info
                local vcn_state vcn_cidr vcn_cidrs vcn_dns vcn_created
                vcn_state=$(echo "$vcn_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                vcn_cidr=$(echo "$vcn_json" | jq -r '.data["cidr-block"] // "N/A"')
                vcn_cidrs=$(echo "$vcn_json" | jq -r '(.data["cidr-blocks"] // []) | if length > 0 then join(", ") else "N/A" end')
                vcn_dns=$(echo "$vcn_json" | jq -r '.data["dns-label"] // "N/A"')
                vcn_created=$(echo "$vcn_json" | jq -r '.data["time-created"] // "N/A"')
                
                # Extract and resolve default resource OCIDs
                local default_rt_id default_sl_id default_dhcp_id
                default_rt_id=$(echo "$vcn_json" | jq -r '.data["default-route-table-id"] // "N/A"')
                default_sl_id=$(echo "$vcn_json" | jq -r '.data["default-security-list-id"] // "N/A"')
                default_dhcp_id=$(echo "$vcn_json" | jq -r '.data["default-dhcp-options-id"] // "N/A"')
                
                # Resolve display names
                local default_rt_name="N/A" default_sl_name="N/A" default_dhcp_name="N/A"
                if [[ "$default_rt_id" != "N/A" && -n "$default_rt_id" ]]; then
                    default_rt_name=$(oci network route-table get --rt-id "$default_rt_id" --query 'data."display-name"' --raw-output 2>/dev/null) || default_rt_name="N/A"
                fi
                if [[ "$default_sl_id" != "N/A" && -n "$default_sl_id" ]]; then
                    default_sl_name=$(oci network security-list get --security-list-id "$default_sl_id" --query 'data."display-name"' --raw-output 2>/dev/null) || default_sl_name="N/A"
                fi
                if [[ "$default_dhcp_id" != "N/A" && -n "$default_dhcp_id" ]]; then
                    default_dhcp_name=$(oci network dhcp-options get --dhcp-id "$default_dhcp_id" --query 'data."display-name"' --raw-output 2>/dev/null) || default_dhcp_name="N/A"
                fi
                
                echo "State:                 $vcn_state"
                echo "CIDR Block:            $vcn_cidr"
                echo "CIDR Blocks:           $vcn_cidrs"
                echo "DNS Label:             $vcn_dns"
                echo -e "Default Route Table:   ${GREEN}$default_rt_name${NC} ${YELLOW}($default_rt_id)${NC}"
                echo -e "Default Security List: ${GREEN}$default_sl_name${NC} ${YELLOW}($default_sl_id)${NC}"
                echo -e "Default DHCP Options:  ${GREEN}$default_dhcp_name${NC} ${YELLOW}($default_dhcp_id)${NC}"
                echo "Time Created:          $vcn_created"
            else
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$resource_ocid${NC}"
                echo ""
                echo -e "${RED}Failed to fetch VCN details${NC}"
            fi
            ;;
            
        SUBNET)
            echo -e "${BOLD}${GREEN}=== Subnet Details ===${NC}"
            
            local subnet_json
            subnet_json=$(oci network subnet get --subnet-id "$resource_ocid" --output json 2>/dev/null)
            
            if [[ -n "$subnet_json" ]]; then
                local subnet_name
                subnet_name=$(echo "$subnet_json" | jq -r '.data["display-name"] // "N/A"')
                echo -e "${WHITE}Name:${NC} ${GREEN}$subnet_name${NC}"
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$resource_ocid${NC}"
                echo ""
                
                # Extract basic info
                local subnet_state subnet_cidr subnet_ad subnet_dns subnet_created
                local prohibit_public prohibit_internet vr_ip vr_mac
                subnet_state=$(echo "$subnet_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                subnet_cidr=$(echo "$subnet_json" | jq -r '.data["cidr-block"] // "N/A"')
                subnet_ad=$(echo "$subnet_json" | jq -r '.data["availability-domain"] // "Regional"')
                subnet_dns=$(echo "$subnet_json" | jq -r '.data["dns-label"] // "N/A"')
                prohibit_public=$(echo "$subnet_json" | jq -r '.data["prohibit-public-ip-on-vnic"] // false')
                prohibit_internet=$(echo "$subnet_json" | jq -r '.data["prohibit-internet-ingress"] // false')
                vr_ip=$(echo "$subnet_json" | jq -r '.data["virtual-router-ip"] // "N/A"')
                vr_mac=$(echo "$subnet_json" | jq -r '.data["virtual-router-mac"] // "N/A"')
                subnet_created=$(echo "$subnet_json" | jq -r '.data["time-created"] // "N/A"')
                
                # Extract resource OCIDs
                local rt_id dhcp_id
                rt_id=$(echo "$subnet_json" | jq -r '.data["route-table-id"] // "N/A"')
                dhcp_id=$(echo "$subnet_json" | jq -r '.data["dhcp-options-id"] // "N/A"')
                
                # Get security list IDs as array
                local sl_ids_json
                sl_ids_json=$(echo "$subnet_json" | jq -r '.data["security-list-ids"] // []')
                
                # Resolve route table name
                local rt_name="N/A"
                if [[ "$rt_id" != "N/A" && -n "$rt_id" ]]; then
                    rt_name=$(oci network route-table get --rt-id "$rt_id" --query 'data."display-name"' --raw-output 2>/dev/null) || rt_name="N/A"
                fi
                
                # Resolve DHCP options name
                local dhcp_name="N/A"
                if [[ "$dhcp_id" != "N/A" && -n "$dhcp_id" ]]; then
                    dhcp_name=$(oci network dhcp-options get --dhcp-id "$dhcp_id" --query 'data."display-name"' --raw-output 2>/dev/null) || dhcp_name="N/A"
                fi
                
                # Resolve security list names
                local sl_display=""
                local sl_count=0
                while IFS= read -r sl_id; do
                    [[ -z "$sl_id" || "$sl_id" == "null" ]] && continue
                    local sl_name
                    sl_name=$(oci network security-list get --security-list-id "$sl_id" --query 'data."display-name"' --raw-output 2>/dev/null) || sl_name="N/A"
                    ((sl_count++))
                    if [[ $sl_count -eq 1 ]]; then
                        sl_display="${GREEN}$sl_name${NC} ${YELLOW}($sl_id)${NC}"
                    else
                        sl_display="$sl_display"$'\n'"                       ${GREEN}$sl_name${NC} ${YELLOW}($sl_id)${NC}"
                    fi
                done < <(echo "$sl_ids_json" | jq -r '.[]' 2>/dev/null)
                [[ -z "$sl_display" ]] && sl_display="None"
                
                echo "State:                 $subnet_state"
                echo "CIDR Block:            $subnet_cidr"
                echo "Availability Domain:   $subnet_ad"
                echo "DNS Label:             $subnet_dns"
                echo "Prohibit Public IP:    $prohibit_public"
                echo "Prohibit Internet:     $prohibit_internet"
                echo -e "Route Table:           ${GREEN}$rt_name${NC} ${YELLOW}($rt_id)${NC}"
                echo -e "Security Lists:        $sl_display"
                echo -e "DHCP Options:          ${GREEN}$dhcp_name${NC} ${YELLOW}($dhcp_id)${NC}"
                echo "Virtual Router IP:     $vr_ip"
                echo "Virtual Router MAC:    $vr_mac"
                echo "Time Created:          $subnet_created"
            else
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$resource_ocid${NC}"
                echo ""
                echo -e "${RED}Failed to fetch subnet details${NC}"
            fi
            ;;
            
        NSG)
            echo -e "${BOLD}${CYAN}=== Network Security Group Details ===${NC}"
            
            local nsg_json
            nsg_json=$(oci network nsg get --nsg-id "$resource_ocid" --output json 2>/dev/null)
            local nsg_name="N/A"
            
            if [[ -n "$nsg_json" ]]; then
                nsg_name=$(echo "$nsg_json" | jq -r '.data["display-name"] // "N/A"')
            fi
            echo -e "${WHITE}Name:${NC} ${CYAN}$nsg_name${NC}"
            echo -e "${WHITE}OCID:${NC} ${YELLOW}$resource_ocid${NC}"
            echo ""
            
            # Build NSG OCID to name lookup from cache
            declare -A NSG_NAME_LOOKUP
            if [[ -f "$NETWORK_RESOURCES_CACHE" ]]; then
                while IFS='|' read -r type name _ state ocid; do
                    [[ "$type" == "NSG" && -n "$ocid" ]] && NSG_NAME_LOOKUP["$ocid"]="$name"
                done < "$NETWORK_RESOURCES_CACHE"
            fi
            
            local rules_json
            rules_json=$(oci network nsg rules list --nsg-id "$resource_ocid" --output json 2>/dev/null)
            
            if [[ -n "$rules_json" ]]; then
                local rule_count
                rule_count=$(echo "$rules_json" | jq '(.data // []) | length')
                echo -e "Found ${GREEN}$rule_count${NC} security rule(s)"
                echo ""
                
                # Count ingress and egress
                local ingress_count egress_count
                ingress_count=$(echo "$rules_json" | jq '[(.data // [])[] | select(.direction == "INGRESS")] | length')
                egress_count=$(echo "$rules_json" | jq '[(.data // [])[] | select(.direction == "EGRESS")] | length')
                
                # Display ingress rules
                if [[ "$ingress_count" -gt 0 ]]; then
                    echo -e "${BOLD}${GREEN}▼▼▼ INGRESS RULES (${ingress_count}) ▼▼▼${NC}"
                    echo ""
                    printf "${BOLD}%-6s | %-9s | %-8s | %-43s | %-9s | %-9s | %s${NC}\n" \
                        "Rule #" "Direction" "Protocol" "Source" "Src Ports" "Dst Ports" "Description"
                    printf "${WHITE}%-6s-+-%-9s-+-%-8s-+-%-43s-+-%-9s-+-%-9s-+-%s${NC}\n" \
                        "------" "---------" "--------" "-------------------------------------------" "---------" "---------" "---------------------------------------------"
                    
                    local ingress_rules
                    ingress_rules=$(echo "$rules_json" | jq -r '
                        (.data // [])[] | select(.direction == "INGRESS") |
                        [
                            .direction,
                            (if .protocol == "6" then "TCP"
                             elif .protocol == "17" then "UDP"
                             elif .protocol == "1" then "ICMP"
                             elif .protocol == "all" then "ALL"
                             else .protocol end),
                            (.source // .["source-type"] // "N/A"),
                            (if .["tcp-options"]["source-port-range"] then
                                "\(.["tcp-options"]["source-port-range"]["min"])-\(.["tcp-options"]["source-port-range"]["max"])"
                             elif .["udp-options"]["source-port-range"] then
                                "\(.["udp-options"]["source-port-range"]["min"])-\(.["udp-options"]["source-port-range"]["max"])"
                             else "ALL" end),
                            (if .["tcp-options"]["destination-port-range"] then
                                (if .["tcp-options"]["destination-port-range"]["min"] == .["tcp-options"]["destination-port-range"]["max"] then
                                    "\(.["tcp-options"]["destination-port-range"]["min"])"
                                else
                                    "\(.["tcp-options"]["destination-port-range"]["min"])-\(.["tcp-options"]["destination-port-range"]["max"])"
                                end)
                             elif .["udp-options"]["destination-port-range"] then
                                (if .["udp-options"]["destination-port-range"]["min"] == .["udp-options"]["destination-port-range"]["max"] then
                                    "\(.["udp-options"]["destination-port-range"]["min"])"
                                else
                                    "\(.["udp-options"]["destination-port-range"]["min"])-\(.["udp-options"]["destination-port-range"]["max"])"
                                end)
                             elif .["icmp-options"] then "ALL"
                             else "ALL" end),
                            (.description // "-")
                        ] | @tsv
                    ' 2>/dev/null)
                    
                    local rule_num=0
                    if [[ -n "$ingress_rules" ]]; then
                        while IFS=$'\t' read -r direction proto source src_ports dst_ports desc; do
                            ((rule_num++))
                            # Resolve NSG OCID to name if applicable
                            if [[ "$source" == ocid1.networksecuritygroup.* ]]; then
                                local resolved_name="${NSG_NAME_LOOKUP[$source]:-}"
                                [[ -n "$resolved_name" ]] && source="NSG: $resolved_name"
                            fi
                            printf "${YELLOW}%-6s${NC} | ${CYAN}%-9s${NC} | ${WHITE}%-8s${NC} | ${GREEN}%-43s${NC} | %-9s | %-9s | ${WHITE}%s${NC}\n" \
                                "$rule_num" "$direction" "$proto" "$source" "$src_ports" "$dst_ports" "$desc"
                        done <<< "$ingress_rules"
                    fi
                    echo ""
                fi
                
                # Display egress rules
                if [[ "$egress_count" -gt 0 ]]; then
                    echo -e "${BOLD}${RED}▲▲▲ EGRESS RULES (${egress_count}) ▲▲▲${NC}"
                    echo ""
                    printf "${BOLD}%-6s | %-9s | %-8s | %-43s | %-9s | %-9s | %s${NC}\n" \
                        "Rule #" "Direction" "Protocol" "Destination" "Src Ports" "Dst Ports" "Description"
                    printf "${WHITE}%-6s-+-%-9s-+-%-8s-+-%-43s-+-%-9s-+-%-9s-+-%s${NC}\n" \
                        "------" "---------" "--------" "-------------------------------------------" "---------" "---------" "---------------------------------------------"
                    
                    local egress_rules
                    egress_rules=$(echo "$rules_json" | jq -r '
                        (.data // [])[] | select(.direction == "EGRESS") |
                        [
                            .direction,
                            (if .protocol == "6" then "TCP"
                             elif .protocol == "17" then "UDP"
                             elif .protocol == "1" then "ICMP"
                             elif .protocol == "all" then "ALL"
                             else .protocol end),
                            (.destination // .["destination-type"] // "N/A"),
                            (if .["tcp-options"]["source-port-range"] then
                                "\(.["tcp-options"]["source-port-range"]["min"])-\(.["tcp-options"]["source-port-range"]["max"])"
                             elif .["udp-options"]["source-port-range"] then
                                "\(.["udp-options"]["source-port-range"]["min"])-\(.["udp-options"]["source-port-range"]["max"])"
                             else "ALL" end),
                            (if .["tcp-options"]["destination-port-range"] then
                                (if .["tcp-options"]["destination-port-range"]["min"] == .["tcp-options"]["destination-port-range"]["max"] then
                                    "\(.["tcp-options"]["destination-port-range"]["min"])"
                                else
                                    "\(.["tcp-options"]["destination-port-range"]["min"])-\(.["tcp-options"]["destination-port-range"]["max"])"
                                end)
                             elif .["udp-options"]["destination-port-range"] then
                                (if .["udp-options"]["destination-port-range"]["min"] == .["udp-options"]["destination-port-range"]["max"] then
                                    "\(.["udp-options"]["destination-port-range"]["min"])"
                                else
                                    "\(.["udp-options"]["destination-port-range"]["min"])-\(.["udp-options"]["destination-port-range"]["max"])"
                                end)
                             elif .["icmp-options"] then "ALL"
                             else "ALL" end),
                            (.description // "-")
                        ] | @tsv
                    ' 2>/dev/null)
                    
                    local rule_num=0
                    if [[ -n "$egress_rules" ]]; then
                        while IFS=$'\t' read -r direction proto dest src_ports dst_ports desc; do
                            ((rule_num++))
                            # Resolve NSG OCID to name if applicable
                            if [[ "$dest" == ocid1.networksecuritygroup.* ]]; then
                                local resolved_name="${NSG_NAME_LOOKUP[$dest]:-}"
                                [[ -n "$resolved_name" ]] && dest="NSG: $resolved_name"
                            fi
                            printf "${YELLOW}%-6s${NC} | ${MAGENTA}%-9s${NC} | ${WHITE}%-8s${NC} | ${GREEN}%-43s${NC} | %-9s | %-9s | ${WHITE}%s${NC}\n" \
                                "$rule_num" "$direction" "$proto" "$dest" "$src_ports" "$dst_ports" "$desc"
                        done <<< "$egress_rules"
                    fi
                fi
            else
                echo -e "${RED}Failed to fetch NSG rules${NC}"
            fi
            ;;
            
        ROUTE_TABLE)
            echo -e "${BOLD}${MAGENTA}=== Route Table Details ===${NC}"
            
            local rt_json
            rt_json=$(oci network route-table get --rt-id "$resource_ocid" --output json 2>/dev/null)
            
            if [[ -n "$rt_json" ]]; then
                local rt_name
                rt_name=$(echo "$rt_json" | jq -r '.data["display-name"] // "N/A"')
                echo -e "${WHITE}Name:${NC} ${MAGENTA}$rt_name${NC}"
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$resource_ocid${NC}"
                echo ""
                
                local rule_count
                rule_count=$(echo "$rt_json" | jq '(.data["route-rules"] // []) | length')
                echo -e "Found ${GREEN}$rule_count${NC} route rule(s)"
                echo ""
                
                if [[ "$rule_count" -gt 0 ]]; then
                    echo -e "${BOLD}${CYAN}▶▶▶ ROUTE RULES (${rule_count}) ▶▶▶${NC}"
                    echo ""
                    printf "${BOLD}%-6s | %-22s | %-12s | %-45s | %s${NC}\n" \
                        "Rule #" "Destination" "Type" "Target" "Description"
                    printf "${WHITE}%-6s-+-%-22s-+-%-12s-+-%-45s-+-%s${NC}\n" \
                        "------" "----------------------" "------------" "----------------------------------------------" "----------------------------------------"
                    
                    local rule_num=0
                    echo "$rt_json" | jq -r '
                        (.data["route-rules"] // [])[] |
                        [
                            (.destination // "N/A"),
                            (.["destination-type"] // "CIDR_BLOCK"),
                            (.["network-entity-id"] // "N/A"),
                            (.description // "-")
                        ] | @tsv
                    ' 2>/dev/null | while IFS=$'\t' read -r dest dtype target desc; do
                        ((rule_num++))
                        # Resolve target OCID to name
                        local target_display="$target"
                        if [[ "$target" == ocid1.internetgateway.* ]]; then
                            local gw_name
                            gw_name=$(oci network internet-gateway get --ig-id "$target" --query 'data."display-name"' --raw-output 2>/dev/null) || gw_name=""
                            [[ -n "$gw_name" ]] && target_display="IGW: $gw_name"
                        elif [[ "$target" == ocid1.natgateway.* ]]; then
                            local gw_name
                            gw_name=$(oci network nat-gateway get --nat-gateway-id "$target" --query 'data."display-name"' --raw-output 2>/dev/null) || gw_name=""
                            [[ -n "$gw_name" ]] && target_display="NAT: $gw_name"
                        elif [[ "$target" == ocid1.servicegateway.* ]]; then
                            local gw_name
                            gw_name=$(oci network service-gateway get --service-gateway-id "$target" --query 'data."display-name"' --raw-output 2>/dev/null) || gw_name=""
                            [[ -n "$gw_name" ]] && target_display="SGW: $gw_name"
                        elif [[ "$target" == ocid1.drg.* ]]; then
                            local gw_name
                            gw_name=$(oci network drg get --drg-id "$target" --query 'data."display-name"' --raw-output 2>/dev/null) || gw_name=""
                            [[ -n "$gw_name" ]] && target_display="DRG: $gw_name"
                        elif [[ "$target" == ocid1.localpeeringgateway.* ]]; then
                            local gw_name
                            gw_name=$(oci network local-peering-gateway get --local-peering-gateway-id "$target" --query 'data."display-name"' --raw-output 2>/dev/null) || gw_name=""
                            [[ -n "$gw_name" ]] && target_display="LPG: $gw_name"
                        fi
                        # Truncate if still too long
                        if [[ ${#target_display} -gt 45 ]]; then
                            target_display="${target_display:0:42}..."
                        fi
                        printf "${YELLOW}%-6s${NC} | ${GREEN}%-22s${NC} | ${WHITE}%-12s${NC} | ${CYAN}%-45s${NC} | ${WHITE}%s${NC}\n" \
                            "$rule_num" "${dest:0:22}" "${dtype:0:12}" "$target_display" "$desc"
                    done
                else
                    echo -e "${YELLOW}No route rules defined${NC}"
                fi
            else
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$resource_ocid${NC}"
                echo ""
                echo -e "${RED}Failed to fetch route table details${NC}"
            fi
            ;;
            
        SECURITY_LIST)
            echo -e "${BOLD}${MAGENTA}=== Security List Details ===${NC}"
            
            local sl_json
            sl_json=$(oci network security-list get --security-list-id "$resource_ocid" --output json 2>/dev/null)
            
            if [[ -n "$sl_json" ]]; then
                local sl_name
                sl_name=$(echo "$sl_json" | jq -r '.data["display-name"] // "N/A"')
                echo -e "${WHITE}Name:${NC} ${MAGENTA}$sl_name${NC}"
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$resource_ocid${NC}"
                echo ""
                
                local ingress_count egress_count
                ingress_count=$(echo "$sl_json" | jq '(.data["ingress-security-rules"] // []) | length')
                egress_count=$(echo "$sl_json" | jq '(.data["egress-security-rules"] // []) | length')
                local total_count=$((ingress_count + egress_count))
                echo -e "Found ${GREEN}$total_count${NC} security rule(s)"
                echo ""
                
                # Display ingress rules
                if [[ "$ingress_count" -gt 0 ]]; then
                    echo -e "${BOLD}${GREEN}▼▼▼ INGRESS RULES (${ingress_count}) ▼▼▼${NC}"
                    echo ""
                    printf "${BOLD}%-6s | %-8s | %-22s | %-9s | %-9s | %s${NC}\n" \
                        "Rule #" "Protocol" "Source" "Src Ports" "Dst Ports" "Description"
                    printf "${WHITE}%-6s-+-%-8s-+-%-22s-+-%-9s-+-%-9s-+-%s${NC}\n" \
                        "------" "--------" "----------------------" "---------" "---------" "-------------------------------------------------------------"
                    
                    local rule_num=0
                    echo "$sl_json" | jq -r '
                        (.data["ingress-security-rules"] // [])[] |
                        [
                            (if .protocol == "6" then "TCP"
                             elif .protocol == "17" then "UDP"
                             elif .protocol == "1" then "ICMP"
                             elif .protocol == "all" then "ALL"
                             else .protocol end),
                            (.source // "N/A"),
                            (if .["tcp-options"]["source-port-range"] then
                                "\(.["tcp-options"]["source-port-range"]["min"])-\(.["tcp-options"]["source-port-range"]["max"])"
                             elif .["udp-options"]["source-port-range"] then
                                "\(.["udp-options"]["source-port-range"]["min"])-\(.["udp-options"]["source-port-range"]["max"])"
                             else "ALL" end),
                            (if .["tcp-options"]["destination-port-range"] then
                                (if .["tcp-options"]["destination-port-range"]["min"] == .["tcp-options"]["destination-port-range"]["max"] then
                                    "\(.["tcp-options"]["destination-port-range"]["min"])"
                                else
                                    "\(.["tcp-options"]["destination-port-range"]["min"])-\(.["tcp-options"]["destination-port-range"]["max"])"
                                end)
                             elif .["udp-options"]["destination-port-range"] then
                                (if .["udp-options"]["destination-port-range"]["min"] == .["udp-options"]["destination-port-range"]["max"] then
                                    "\(.["udp-options"]["destination-port-range"]["min"])"
                                else
                                    "\(.["udp-options"]["destination-port-range"]["min"])-\(.["udp-options"]["destination-port-range"]["max"])"
                                end)
                             elif .["icmp-options"] then "ALL"
                             else "ALL" end),
                            (.description // "-")
                        ] | @tsv
                    ' 2>/dev/null | while IFS=$'\t' read -r proto source src_ports dst_ports desc; do
                        ((rule_num++))
                        printf "${YELLOW}%-6s${NC} | ${WHITE}%-8s${NC} | ${GREEN}%-22s${NC} | %-9s | %-9s | ${WHITE}%s${NC}\n" \
                            "$rule_num" "$proto" "${source:0:22}" "$src_ports" "$dst_ports" "$desc"
                    done
                    echo ""
                fi
                
                # Display egress rules
                if [[ "$egress_count" -gt 0 ]]; then
                    echo -e "${BOLD}${RED}▲▲▲ EGRESS RULES (${egress_count}) ▲▲▲${NC}"
                    echo ""
                    printf "${BOLD}%-6s | %-8s | %-22s | %-9s | %-9s | %s${NC}\n" \
                        "Rule #" "Protocol" "Destination" "Src Ports" "Dst Ports" "Description"
                    printf "${WHITE}%-6s-+-%-8s-+-%-22s-+-%-9s-+-%-9s-+-%s${NC}\n" \
                        "------" "--------" "----------------------" "---------" "---------" "-------------------------------------------------------------"
                    
                    local rule_num=0
                    echo "$sl_json" | jq -r '
                        (.data["egress-security-rules"] // [])[] |
                        [
                            (if .protocol == "6" then "TCP"
                             elif .protocol == "17" then "UDP"
                             elif .protocol == "1" then "ICMP"
                             elif .protocol == "all" then "ALL"
                             else .protocol end),
                            (.destination // "N/A"),
                            (if .["tcp-options"]["source-port-range"] then
                                "\(.["tcp-options"]["source-port-range"]["min"])-\(.["tcp-options"]["source-port-range"]["max"])"
                             elif .["udp-options"]["source-port-range"] then
                                "\(.["udp-options"]["source-port-range"]["min"])-\(.["udp-options"]["source-port-range"]["max"])"
                             else "ALL" end),
                            (if .["tcp-options"]["destination-port-range"] then
                                (if .["tcp-options"]["destination-port-range"]["min"] == .["tcp-options"]["destination-port-range"]["max"] then
                                    "\(.["tcp-options"]["destination-port-range"]["min"])"
                                else
                                    "\(.["tcp-options"]["destination-port-range"]["min"])-\(.["tcp-options"]["destination-port-range"]["max"])"
                                end)
                             elif .["udp-options"]["destination-port-range"] then
                                (if .["udp-options"]["destination-port-range"]["min"] == .["udp-options"]["destination-port-range"]["max"] then
                                    "\(.["udp-options"]["destination-port-range"]["min"])"
                                else
                                    "\(.["udp-options"]["destination-port-range"]["min"])-\(.["udp-options"]["destination-port-range"]["max"])"
                                end)
                             elif .["icmp-options"] then "ALL"
                             else "ALL" end),
                            (.description // "-")
                        ] | @tsv
                    ' 2>/dev/null | while IFS=$'\t' read -r proto dest src_ports dst_ports desc; do
                        ((rule_num++))
                        printf "${YELLOW}%-6s${NC} | ${WHITE}%-8s${NC} | ${GREEN}%-22s${NC} | %-9s | %-9s | ${WHITE}%s${NC}\n" \
                            "$rule_num" "$proto" "${dest:0:22}" "$src_ports" "$dst_ports" "$desc"
                    done
                fi
            else
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$resource_ocid${NC}"
                echo ""
                echo -e "${RED}Failed to fetch security list details${NC}"
            fi
            ;;
            
        GATEWAY)
            local gw_type="$resource_ocid"
            local gw_ocid="$extra_info"
            
            echo -e "${BOLD}${ORANGE}=== Gateway Details ($gw_type) ===${NC}"
            
            case "$gw_type" in
                IGW)
                    local igw_json
                    igw_json=$(oci network internet-gateway get --ig-id "$gw_ocid" --output json 2>/dev/null)
                    if [[ -n "$igw_json" ]]; then
                        local gw_name gw_state gw_enabled gw_vcn_id gw_created
                        gw_name=$(echo "$igw_json" | jq -r '.data["display-name"] // "N/A"')
                        gw_state=$(echo "$igw_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                        gw_enabled=$(echo "$igw_json" | jq -r '.data["is-enabled"] // false')
                        gw_vcn_id=$(echo "$igw_json" | jq -r '.data["vcn-id"] // "N/A"')
                        gw_created=$(echo "$igw_json" | jq -r '.data["time-created"] // "N/A"')
                        
                        # Resolve VCN name
                        local vcn_name="N/A"
                        if [[ "$gw_vcn_id" != "N/A" && -n "$gw_vcn_id" ]]; then
                            vcn_name=$(oci network vcn get --vcn-id "$gw_vcn_id" --query 'data."display-name"' --raw-output 2>/dev/null) || vcn_name="N/A"
                        fi
                        
                        echo -e "${WHITE}Name:${NC} ${ORANGE}$gw_name${NC}"
                        echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                        echo ""
                        echo "State:                 $gw_state"
                        echo "Is Enabled:            $gw_enabled"
                        echo -e "VCN:                   ${GREEN}$vcn_name${NC} ${YELLOW}($gw_vcn_id)${NC}"
                        echo "Time Created:          $gw_created"
                    else
                        echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                        echo ""
                        echo -e "${RED}Failed to fetch Internet Gateway details${NC}"
                    fi
                    ;;
                NAT)
                    local nat_json
                    nat_json=$(oci network nat-gateway get --nat-gateway-id "$gw_ocid" --output json 2>/dev/null)
                    if [[ -n "$nat_json" ]]; then
                        local gw_name gw_state gw_block gw_ip gw_vcn_id gw_created
                        gw_name=$(echo "$nat_json" | jq -r '.data["display-name"] // "N/A"')
                        gw_state=$(echo "$nat_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                        gw_block=$(echo "$nat_json" | jq -r '.data["block-traffic"] // false')
                        gw_ip=$(echo "$nat_json" | jq -r '.data["nat-ip"] // "N/A"')
                        gw_vcn_id=$(echo "$nat_json" | jq -r '.data["vcn-id"] // "N/A"')
                        gw_created=$(echo "$nat_json" | jq -r '.data["time-created"] // "N/A"')
                        
                        # Resolve VCN name
                        local vcn_name="N/A"
                        if [[ "$gw_vcn_id" != "N/A" && -n "$gw_vcn_id" ]]; then
                            vcn_name=$(oci network vcn get --vcn-id "$gw_vcn_id" --query 'data."display-name"' --raw-output 2>/dev/null) || vcn_name="N/A"
                        fi
                        
                        echo -e "${WHITE}Name:${NC} ${ORANGE}$gw_name${NC}"
                        echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                        echo ""
                        echo "State:                 $gw_state"
                        echo "Block Traffic:         $gw_block"
                        echo "Public IP:             $gw_ip"
                        echo -e "VCN:                   ${GREEN}$vcn_name${NC} ${YELLOW}($gw_vcn_id)${NC}"
                        echo "Time Created:          $gw_created"
                    else
                        echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                        echo ""
                        echo -e "${RED}Failed to fetch NAT Gateway details${NC}"
                    fi
                    ;;
                SGW)
                    local sgw_json
                    sgw_json=$(oci network service-gateway get --service-gateway-id "$gw_ocid" --output json 2>/dev/null)
                    if [[ -n "$sgw_json" ]]; then
                        local gw_name gw_state gw_block gw_vcn_id gw_services gw_created
                        gw_name=$(echo "$sgw_json" | jq -r '.data["display-name"] // "N/A"')
                        gw_state=$(echo "$sgw_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                        gw_block=$(echo "$sgw_json" | jq -r '.data["block-traffic"] // false')
                        gw_vcn_id=$(echo "$sgw_json" | jq -r '.data["vcn-id"] // "N/A"')
                        gw_services=$(echo "$sgw_json" | jq -r '(.data.services // []) | map(.["service-name"] // "unknown") | if length > 0 then join(", ") else "None" end')
                        gw_created=$(echo "$sgw_json" | jq -r '.data["time-created"] // "N/A"')
                        
                        # Resolve VCN name
                        local vcn_name="N/A"
                        if [[ "$gw_vcn_id" != "N/A" && -n "$gw_vcn_id" ]]; then
                            vcn_name=$(oci network vcn get --vcn-id "$gw_vcn_id" --query 'data."display-name"' --raw-output 2>/dev/null) || vcn_name="N/A"
                        fi
                        
                        echo -e "${WHITE}Name:${NC} ${ORANGE}$gw_name${NC}"
                        echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                        echo ""
                        echo "State:                 $gw_state"
                        echo "Block Traffic:         $gw_block"
                        echo -e "VCN:                   ${GREEN}$vcn_name${NC} ${YELLOW}($gw_vcn_id)${NC}"
                        echo "Services:              $gw_services"
                        echo "Time Created:          $gw_created"
                    else
                        echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                        echo ""
                        echo -e "${RED}Failed to fetch Service Gateway details${NC}"
                    fi
                    ;;
                DRG)
                    local drg_json
                    drg_json=$(oci network drg-attachment get --drg-attachment-id "$gw_ocid" --output json 2>/dev/null)
                    if [[ -n "$drg_json" ]]; then
                        local gw_name gw_state gw_drg_id gw_vcn_id gw_rt_id gw_created
                        gw_name=$(echo "$drg_json" | jq -r '.data["display-name"] // "N/A"')
                        gw_state=$(echo "$drg_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                        gw_drg_id=$(echo "$drg_json" | jq -r '.data["drg-id"] // "N/A"')
                        gw_vcn_id=$(echo "$drg_json" | jq -r '.data["vcn-id"] // "N/A"')
                        gw_rt_id=$(echo "$drg_json" | jq -r '.data["drg-route-table-id"] // "N/A"')
                        gw_created=$(echo "$drg_json" | jq -r '.data["time-created"] // "N/A"')
                        
                        # Resolve VCN name
                        local vcn_name="N/A"
                        if [[ "$gw_vcn_id" != "N/A" && -n "$gw_vcn_id" ]]; then
                            vcn_name=$(oci network vcn get --vcn-id "$gw_vcn_id" --query 'data."display-name"' --raw-output 2>/dev/null) || vcn_name="N/A"
                        fi
                        
                        # Resolve DRG name
                        local drg_name="N/A"
                        if [[ "$gw_drg_id" != "N/A" && -n "$gw_drg_id" ]]; then
                            drg_name=$(oci network drg get --drg-id "$gw_drg_id" --query 'data."display-name"' --raw-output 2>/dev/null) || drg_name="N/A"
                        fi
                        
                        # Resolve DRG Route Table name
                        local rt_name="N/A"
                        if [[ "$gw_rt_id" != "N/A" && -n "$gw_rt_id" ]]; then
                            rt_name=$(oci network drg-route-table get --drg-route-table-id "$gw_rt_id" --query 'data."display-name"' --raw-output 2>/dev/null) || rt_name="N/A"
                        fi
                        
                        echo -e "${WHITE}Name:${NC} ${ORANGE}$gw_name${NC}"
                        echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                        echo ""
                        echo "State:                 $gw_state"
                        echo -e "DRG:                   ${GREEN}$drg_name${NC} ${YELLOW}($gw_drg_id)${NC}"
                        echo -e "VCN:                   ${GREEN}$vcn_name${NC} ${YELLOW}($gw_vcn_id)${NC}"
                        if [[ "$gw_rt_id" != "N/A" && -n "$gw_rt_id" ]]; then
                            echo -e "DRG Route Table:       ${GREEN}$rt_name${NC} ${YELLOW}($gw_rt_id)${NC}"
                        fi
                        echo "Time Created:          $gw_created"
                    else
                        echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                        echo ""
                        echo -e "${RED}Failed to fetch DRG Attachment details${NC}"
                    fi
                    ;;
                LPG)
                    local lpg_json
                    lpg_json=$(oci network local-peering-gateway get --local-peering-gateway-id "$gw_ocid" --output json 2>/dev/null)
                    if [[ -n "$lpg_json" ]]; then
                        local gw_name gw_state gw_peer_status gw_peer_cidr gw_vcn_id gw_created
                        gw_name=$(echo "$lpg_json" | jq -r '.data["display-name"] // "N/A"')
                        gw_state=$(echo "$lpg_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                        gw_peer_status=$(echo "$lpg_json" | jq -r '.data["peering-status"] // "N/A"')
                        gw_peer_cidr=$(echo "$lpg_json" | jq -r '.data["peer-advertised-cidr"] // "N/A"')
                        gw_vcn_id=$(echo "$lpg_json" | jq -r '.data["vcn-id"] // "N/A"')
                        gw_created=$(echo "$lpg_json" | jq -r '.data["time-created"] // "N/A"')
                        
                        # Resolve VCN name
                        local vcn_name="N/A"
                        if [[ "$gw_vcn_id" != "N/A" && -n "$gw_vcn_id" ]]; then
                            vcn_name=$(oci network vcn get --vcn-id "$gw_vcn_id" --query 'data."display-name"' --raw-output 2>/dev/null) || vcn_name="N/A"
                        fi
                        
                        echo -e "${WHITE}Name:${NC} ${ORANGE}$gw_name${NC}"
                        echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                        echo ""
                        echo "State:                 $gw_state"
                        echo "Peering Status:        $gw_peer_status"
                        echo "Peer Advertised CIDR:  $gw_peer_cidr"
                        echo -e "VCN:                   ${GREEN}$vcn_name${NC} ${YELLOW}($gw_vcn_id)${NC}"
                        echo "Time Created:          $gw_created"
                    else
                        echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                        echo ""
                        echo -e "${RED}Failed to fetch Local Peering Gateway details${NC}"
                    fi
                    ;;
                *)
                    echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                    echo ""
                    echo -e "${YELLOW}Gateway type $gw_type details not implemented${NC}"
                    ;;
            esac
            ;;
            
        *)
            echo -e "${RED}Unknown resource type: $resource_type${NC}"
            ;;
    esac
    
    echo ""
}

#===============================================================================
# COMPUTE INSTANCE MANAGEMENT
#===============================================================================

manage_compute_instances() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}                                                         COMPUTE INSTANCE MANAGEMENT                                                                    ${NC}"
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}Environment:${NC}"
        echo -e "  ${CYAN}Region:${NC}      ${WHITE}${region}${NC}"
        echo -e "  ${CYAN}Compartment:${NC} ${YELLOW}${compartment_id}${NC}"
        echo ""
        
        # Fetch instances
        log_info "Fetching instances from OCI..."
        local instances_json
        instances_json=$(oci compute instance list \
            --compartment-id "$compartment_id" \
            --region "$region" \
            --all \
            --output json 2>/dev/null)
        
        if [[ -z "$instances_json" ]] || ! echo "$instances_json" | jq -e '.data' > /dev/null 2>&1; then
            echo -e "${RED}Failed to fetch instances${NC}"
            echo ""
            echo -e "Press Enter to return..."
            read -r
            return
        fi
        
        # Build instance index map
        declare -A INSTANCE_INDEX_MAP=()
        local instance_idx=0
        
        # Clear any old temp file
        rm -f /tmp/instance_map_$$
        
        # Fetch K8s nodes once for lookup (include taints)
        local k8s_nodes_json
        k8s_nodes_json=$(kubectl get nodes -o json 2>/dev/null)
        
        # Build lookup: providerID|nodeName|readyStatus|newNodeTaint
        local k8s_lookup
        k8s_lookup=$(echo "$k8s_nodes_json" | jq -r '
            .items[] | 
            (.spec.taints // [] | map(select(.key == "newNode")) | if length > 0 then .[0].effect else "N/A" end) as $newNodeTaint |
            "\(.spec.providerID)|\(.metadata.name)|\(.status.conditions[] | select(.type=="Ready") | .status)|\($newNodeTaint)"
        ' 2>/dev/null)
        
        # Display instances table
        echo -e "${BOLD}${WHITE}═══ Instances ═══${NC}"
        echo ""
        printf "${BOLD}%-5s %-32s %-12s %-8s %-12s %-26s %-15s %s${NC}\n" \
            "ID" "Display Name" "State" "K8s" "newNode" "Shape" "Avail Domain" "Instance OCID"
        print_separator 220
        
        echo "$instances_json" | jq -r '
            .data[] | 
            select(.["lifecycle-state"] != "TERMINATED") |
            "\(.["display-name"])|\(.["lifecycle-state"])|\(.shape)|\(.["availability-domain"])|\(.id)"
        ' 2>/dev/null | sort | while IFS='|' read -r name state shape ad ocid; do
            ((instance_idx++))
            local iid="i${instance_idx}"
            
            # Store in map (need to use a temp file since we're in a subshell)
            echo "${iid}|${ocid}" >> /tmp/instance_map_$$
            
            # Color state
            local state_color="$GREEN"
            case "$state" in
                RUNNING) state_color="$GREEN" ;;
                STOPPED) state_color="$RED" ;;
                STARTING|STOPPING) state_color="$YELLOW" ;;
                PROVISIONING) state_color="$CYAN" ;;
                *) state_color="$WHITE" ;;
            esac
            
            # Check if in K8s and get taint info
            local k8s_status="No"
            local k8s_color="$YELLOW"
            local new_node_taint="N/A"
            local new_node_color="$GRAY"
            
            local k8s_match
            k8s_match=$(echo "$k8s_lookup" | grep "$ocid" 2>/dev/null)
            
            if [[ -n "$k8s_match" ]]; then
                local k8s_ready
                k8s_ready=$(echo "$k8s_match" | cut -d'|' -f3)
                new_node_taint=$(echo "$k8s_match" | cut -d'|' -f4)
                
                if [[ "$k8s_ready" == "True" ]]; then
                    k8s_status="Ready"
                    k8s_color="$GREEN"
                else
                    k8s_status="NotRdy"
                    k8s_color="$RED"
                fi
                
                # Color the taint
                if [[ "$new_node_taint" != "N/A" ]]; then
                    new_node_color="$YELLOW"
                else
                    new_node_color="$GRAY"
                fi
            fi
            
            # Truncate long fields (but show full OCID)
            local name_trunc="${name:0:32}"
            local shape_trunc="${shape:0:26}"
            local ad_short="${ad##*:}"
            
            printf "${YELLOW}%-5s${NC} %-32s ${state_color}%-12s${NC} ${k8s_color}%-8s${NC} ${new_node_color}%-12s${NC} %-26s %-15s ${GRAY}%s${NC}\n" \
                "$iid" "$name_trunc" "$state" "$k8s_status" "$new_node_taint" "$shape_trunc" "$ad_short" "$ocid"
        done
        
        # Read map from temp file
        if [[ -f /tmp/instance_map_$$ ]]; then
            while IFS='|' read -r iid ocid; do
                INSTANCE_INDEX_MAP[$iid]="$ocid"
            done < /tmp/instance_map_$$
            rm -f /tmp/instance_map_$$
        fi
        
        local total_instances=${#INSTANCE_INDEX_MAP[@]}
        echo ""
        echo -e "${GRAY}Total: ${total_instances} instances (excluding TERMINATED)${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}═══ Actions ═══${NC}"
        echo -e "  ${YELLOW}i#${NC}      - View instance details (e.g., 'i1', 'i5')"
        echo -e "  ${YELLOW}ocid1...${NC} - View instance by OCID directly"
        echo -e "  ${MAGENTA}refresh${NC} - Refresh instance list"
        echo -e "  ${CYAN}back${NC}    - Return to main menu"
        echo ""
        echo -e "${GRAY}Tip: From command line, use:${NC}"
        echo -e "${GRAY}  $0 <instance-ocid>                  # Basic info (OCI + K8s)${NC}"
        echo -e "${GRAY}  $0 <instance-ocid> --details        # Full details (network, volumes)${NC}"
        echo -e "${GRAY}  $0 <instance-ocid> --console-history # Boot logs (debug cloud-init)${NC}"
        echo ""
        echo -n -e "${BOLD}${CYAN}Enter selection [i#/ocid/refresh/back]: ${NC}"
        
        local input
        read -r input
        
        # Empty input goes back
        if [[ -z "$input" ]]; then
            return
        fi
        
        case "$input" in
            refresh|REFRESH)
                echo -e "${YELLOW}Refreshing...${NC}"
                ;;
            quit|QUIT|q|Q|exit|EXIT|back|BACK|b|B)
                return
                ;;
            i[0-9]*)
                local instance_ocid="${INSTANCE_INDEX_MAP[$input]:-}"
                if [[ -z "$instance_ocid" ]]; then
                    echo -e "${RED}Invalid instance ID: $input${NC}"
                    sleep 1
                else
                    display_instance_details "$instance_ocid"
                    instance_actions_menu "$instance_ocid"
                fi
                ;;
            ocid1.instance.*)
                # Direct OCID input
                display_instance_details "$input"
                instance_actions_menu "$input"
                ;;
            *)
                echo -e "${RED}Unknown command: $input${NC}"
                sleep 1
                ;;
        esac
    done
}

#--------------------------------------------------------------------------------
# Instance Actions Menu - Reboot, Terminate, etc.
#--------------------------------------------------------------------------------
instance_actions_menu() {
    local instance_ocid="$1"
    
    # Get instance name for display
    local instance_name
    instance_name=$(oci compute instance get --instance-id "$instance_ocid" --query 'data."display-name"' --raw-output 2>/dev/null) || instance_name="Unknown"
    
    # Get current state
    local instance_state
    instance_state=$(oci compute instance get --instance-id "$instance_ocid" --query 'data."lifecycle-state"' --raw-output 2>/dev/null) || instance_state="Unknown"
    
    # Check if in K8s
    local k8s_node_name=""
    k8s_node_name=$(kubectl get nodes -o json 2>/dev/null | jq -r --arg ocid "$instance_ocid" '.items[] | select(.spec.providerID | contains($ocid)) | .metadata.name' 2>/dev/null)
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Instance Actions ═══${NC}"
    echo -e "  Instance: ${GREEN}$instance_name${NC}"
    echo -e "  State:    ${CYAN}$instance_state${NC}"
    if [[ -n "$k8s_node_name" ]]; then
        echo -e "  K8s Node: ${GREEN}$k8s_node_name${NC}"
    else
        echo -e "  K8s Node: ${YELLOW}Not in cluster${NC}"
    fi
    echo ""
    echo -e "  ${YELLOW}1${NC}) ${WHITE}Reboot Instance${NC}        - Graceful reboot (ACPI shutdown + start)"
    echo -e "  ${YELLOW}2${NC}) ${WHITE}Force Reboot Instance${NC}  - Hard reset (immediate power cycle)"
    echo -e "  ${YELLOW}3${NC}) ${WHITE}Stop Instance${NC}          - Graceful shutdown"
    echo -e "  ${YELLOW}4${NC}) ${WHITE}Start Instance${NC}         - Power on (if stopped)"
    if [[ -n "$k8s_node_name" ]]; then
        echo -e "  ${YELLOW}6${NC}) ${WHITE}Drain K8s Node${NC}         - Safely evict pods before maintenance"
        echo -e "  ${YELLOW}7${NC}) ${WHITE}Cordon K8s Node${NC}        - Mark node as unschedulable"
        echo -e "  ${YELLOW}8${NC}) ${WHITE}Uncordon K8s Node${NC}      - Mark node as schedulable"
    fi
    echo -e "  ${RED}5${NC}) ${WHITE}Terminate Instance${NC}     - ${RED}PERMANENTLY DELETE${NC} instance"
    echo ""
    echo -e "  ${MAGENTA}9${NC}) ${WHITE}View Console History${NC}   - Boot logs (debug cloud-init issues)"
    echo ""
    echo -e "  ${CYAN}Enter${NC}) Return to instance list"
    echo ""
    
    local prompt_range="1-5,9"
    [[ -n "$k8s_node_name" ]] && prompt_range="1-9"
    echo -n -e "${BOLD}${CYAN}Select action [${prompt_range}/Enter]: ${NC}"
    
    local action
    read -r action
    
    case "$action" in
        1)
            # Reboot (soft)
            echo ""
            echo -e "${YELLOW}Rebooting instance ${GREEN}$instance_name${NC}${YELLOW}...${NC}"
            echo -n -e "${CYAN}Confirm reboot? (yes/no): ${NC}"
            read -r confirm
            if [[ "$confirm" == "yes" ]]; then
                if oci compute instance action --instance-id "$instance_ocid" --action SOFTRESET 2>/dev/null; then
                    echo -e "${GREEN}✓ Reboot initiated successfully${NC}"
                else
                    echo -e "${RED}✗ Failed to reboot instance${NC}"
                fi
            else
                echo -e "${YELLOW}Reboot cancelled${NC}"
            fi
            echo ""
            echo -e "Press Enter to continue..."
            read -r
            ;;
        2)
            # Force Reboot (hard reset)
            echo ""
            echo -e "${YELLOW}Force rebooting instance ${GREEN}$instance_name${NC}${YELLOW}...${NC}"
            echo -e "${RED}WARNING: This is a hard reset and may cause data loss!${NC}"
            echo -n -e "${CYAN}Confirm force reboot? (yes/no): ${NC}"
            read -r confirm
            if [[ "$confirm" == "yes" ]]; then
                if oci compute instance action --instance-id "$instance_ocid" --action RESET 2>/dev/null; then
                    echo -e "${GREEN}✓ Force reboot initiated successfully${NC}"
                else
                    echo -e "${RED}✗ Failed to force reboot instance${NC}"
                fi
            else
                echo -e "${YELLOW}Force reboot cancelled${NC}"
            fi
            echo ""
            echo -e "Press Enter to continue..."
            read -r
            ;;
        3)
            # Stop instance
            echo ""
            echo -e "${YELLOW}Stopping instance ${GREEN}$instance_name${NC}${YELLOW}...${NC}"
            echo -n -e "${CYAN}Confirm stop? (yes/no): ${NC}"
            read -r confirm
            if [[ "$confirm" == "yes" ]]; then
                if oci compute instance action --instance-id "$instance_ocid" --action SOFTSTOP 2>/dev/null; then
                    echo -e "${GREEN}✓ Stop initiated successfully${NC}"
                else
                    echo -e "${RED}✗ Failed to stop instance${NC}"
                fi
            else
                echo -e "${YELLOW}Stop cancelled${NC}"
            fi
            echo ""
            echo -e "Press Enter to continue..."
            read -r
            ;;
        4)
            # Start instance
            echo ""
            echo -e "${YELLOW}Starting instance ${GREEN}$instance_name${NC}${YELLOW}...${NC}"
            echo -n -e "${CYAN}Confirm start? (yes/no): ${NC}"
            read -r confirm
            if [[ "$confirm" == "yes" ]]; then
                if oci compute instance action --instance-id "$instance_ocid" --action START 2>/dev/null; then
                    echo -e "${GREEN}✓ Start initiated successfully${NC}"
                else
                    echo -e "${RED}✗ Failed to start instance${NC}"
                fi
            else
                echo -e "${YELLOW}Start cancelled${NC}"
            fi
            echo ""
            echo -e "Press Enter to continue..."
            read -r
            ;;
        5)
            # Terminate instance
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║                    ⚠️  WARNING: TERMINATE  ⚠️                   ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${RED}This will PERMANENTLY DELETE the instance:${NC}"
            echo -e "  Name: ${GREEN}$instance_name${NC}"
            echo -e "  OCID: ${YELLOW}$instance_ocid${NC}"
            echo ""
            echo -e "${RED}This action cannot be undone!${NC}"
            echo ""
            
            # Check if in K8s
            if [[ -n "$k8s_node_name" ]]; then
                echo -e "${YELLOW}⚠️  This instance is a Kubernetes node: ${CYAN}$k8s_node_name${NC}"
                echo -e "${YELLOW}   Consider draining the node first (option 6)${NC}"
                echo ""
            fi
            
            echo -n -e "${RED}Type 'TERMINATE' to confirm deletion: ${NC}"
            read -r confirm
            if [[ "$confirm" == "TERMINATE" ]]; then
                echo ""
                echo -e "${YELLOW}Terminating instance...${NC}"
                if oci compute instance terminate --instance-id "$instance_ocid" --preserve-boot-volume false --force 2>/dev/null; then
                    echo -e "${GREEN}✓ Terminate initiated successfully${NC}"
                    echo -e "${YELLOW}Instance will be deleted. Boot volume will also be deleted.${NC}"
                else
                    echo -e "${RED}✗ Failed to terminate instance${NC}"
                fi
            else
                echo -e "${YELLOW}Termination cancelled${NC}"
            fi
            echo ""
            echo -e "Press Enter to continue..."
            read -r
            ;;
        6)
            # Drain K8s node
            if [[ -z "$k8s_node_name" ]]; then
                echo -e "${RED}This instance is not a Kubernetes node${NC}"
                sleep 1
            else
                echo ""
                echo -e "${YELLOW}Draining Kubernetes node ${GREEN}$k8s_node_name${NC}${YELLOW}...${NC}"
                echo -e "${WHITE}This will evict all pods (except DaemonSets) from the node.${NC}"
                echo ""
                echo -n -e "${CYAN}Confirm drain? (yes/no): ${NC}"
                read -r confirm
                if [[ "$confirm" == "yes" ]]; then
                    echo ""
                    echo -e "${YELLOW}Running: kubectl drain $k8s_node_name --ignore-daemonsets --delete-emptydir-data${NC}"
                    if kubectl drain "$k8s_node_name" --ignore-daemonsets --delete-emptydir-data 2>&1; then
                        echo -e "${GREEN}✓ Node drained successfully${NC}"
                    else
                        echo -e "${RED}✗ Failed to drain node (some pods may not be evictable)${NC}"
                    fi
                else
                    echo -e "${YELLOW}Drain cancelled${NC}"
                fi
                echo ""
                echo -e "Press Enter to continue..."
                read -r
            fi
            ;;
        7)
            # Cordon K8s node
            if [[ -z "$k8s_node_name" ]]; then
                echo -e "${RED}This instance is not a Kubernetes node${NC}"
                sleep 1
            else
                echo ""
                echo -e "${YELLOW}Cordoning Kubernetes node ${GREEN}$k8s_node_name${NC}${YELLOW}...${NC}"
                echo -e "${WHITE}This marks the node as unschedulable (existing pods continue running).${NC}"
                echo ""
                echo -n -e "${CYAN}Confirm cordon? (yes/no): ${NC}"
                read -r confirm
                if [[ "$confirm" == "yes" ]]; then
                    if kubectl cordon "$k8s_node_name" 2>&1; then
                        echo -e "${GREEN}✓ Node cordoned successfully${NC}"
                    else
                        echo -e "${RED}✗ Failed to cordon node${NC}"
                    fi
                else
                    echo -e "${YELLOW}Cordon cancelled${NC}"
                fi
                echo ""
                echo -e "Press Enter to continue..."
                read -r
            fi
            ;;
        8)
            # Uncordon K8s node
            if [[ -z "$k8s_node_name" ]]; then
                echo -e "${RED}This instance is not a Kubernetes node${NC}"
                sleep 1
            else
                echo ""
                echo -e "${YELLOW}Uncordoning Kubernetes node ${GREEN}$k8s_node_name${NC}${YELLOW}...${NC}"
                echo -e "${WHITE}This marks the node as schedulable again.${NC}"
                echo ""
                echo -n -e "${CYAN}Confirm uncordon? (yes/no): ${NC}"
                read -r confirm
                if [[ "$confirm" == "yes" ]]; then
                    if kubectl uncordon "$k8s_node_name" 2>&1; then
                        echo -e "${GREEN}✓ Node uncordoned successfully${NC}"
                    else
                        echo -e "${RED}✗ Failed to uncordon node${NC}"
                    fi
                else
                    echo -e "${YELLOW}Uncordon cancelled${NC}"
                fi
                echo ""
                echo -e "Press Enter to continue..."
                read -r
            fi
            ;;
        9)
            # View Console History
            echo ""
            echo -e "${CYAN}Fetching console history for ${GREEN}$instance_name${NC}${CYAN}...${NC}"
            get_console_history "$instance_ocid"
            echo ""
            echo -e "Press Enter to continue..."
            read -r
            ;;
        *)
            # Return to list
            ;;
    esac
}

#--------------------------------------------------------------------------------
# Display detailed instance information
#--------------------------------------------------------------------------------
display_instance_details() {
    local instance_ocid="$1"
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    echo ""
    echo -e "${BOLD}${CYAN}=== Instance Details ===${NC}"
    
    # Fetch instance details
    local instance_json
    instance_json=$(oci compute instance get --instance-id "$instance_ocid" --output json 2>/dev/null)
    
    if [[ -z "$instance_json" ]] || ! echo "$instance_json" | jq -e '.data' > /dev/null 2>&1; then
        echo -e "${RED}Failed to fetch instance details${NC}"
        return 1
    fi
    
    # Extract basic info
    local display_name state shape ad fd time_created
    display_name=$(echo "$instance_json" | jq -r '.data["display-name"] // "N/A"')
    state=$(echo "$instance_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    shape=$(echo "$instance_json" | jq -r '.data.shape // "N/A"')
    ad=$(echo "$instance_json" | jq -r '.data["availability-domain"] // "N/A"')
    fd=$(echo "$instance_json" | jq -r '.data["fault-domain"] // "N/A"')
    time_created=$(echo "$instance_json" | jq -r '.data["time-created"] // "N/A"')
    
    # Extract GPU memory cluster tag
    local gpu_mem_cluster
    gpu_mem_cluster=$(echo "$instance_json" | jq -r '.data["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A"')
    
    # Extract compute cluster ID
    local compute_cluster_id
    compute_cluster_id=$(echo "$instance_json" | jq -r '.data["compute-cluster-id"] // "N/A"')
    
    # Color state
    local state_color="$GREEN"
    case "$state" in
        RUNNING) state_color="$GREEN" ;;
        STOPPED) state_color="$RED" ;;
        STARTING|STOPPING) state_color="$YELLOW" ;;
        PROVISIONING) state_color="$CYAN" ;;
        *) state_color="$WHITE" ;;
    esac
    
    echo -e "${WHITE}Name:${NC}              ${GREEN}$display_name${NC}"
    echo -e "${WHITE}OCID:${NC}              ${YELLOW}$instance_ocid${NC}"
    echo ""
    echo -e "${WHITE}State:${NC}             ${state_color}$state${NC}"
    echo -e "${WHITE}Shape:${NC}             $shape"
    echo -e "${WHITE}Availability Domain:${NC} $ad"
    echo -e "${WHITE}Fault Domain:${NC}      $fd"
    echo -e "${WHITE}Time Created:${NC}      $time_created"
    
    if [[ "$gpu_mem_cluster" != "N/A" && "$gpu_mem_cluster" != "null" ]]; then
        local cluster_name
        cluster_name=$(lookup_cache "$CLUSTER_CACHE" "$gpu_mem_cluster" 2 2>/dev/null || echo "N/A")
        echo ""
        echo -e "${WHITE}GPU Memory Cluster:${NC} ${GREEN}$cluster_name${NC}"
        echo -e "                    ${YELLOW}$gpu_mem_cluster${NC}"
    fi
    
    if [[ "$compute_cluster_id" != "N/A" && "$compute_cluster_id" != "null" ]]; then
        local cc_name
        cc_name=$(get_compute_cluster_name "$compute_cluster_id")
        echo -e "${WHITE}Compute Cluster:${NC}   ${GREEN}$cc_name${NC}"
        echo -e "                    ${YELLOW}$compute_cluster_id${NC}"
    fi
    
    # ========== KUBERNETES STATUS ==========
    echo ""
    echo -e "${BOLD}${CYAN}=== Kubernetes Status ===${NC}"
    
    # Check if instance is in K8s
    local k8s_node_info
    k8s_node_info=$(kubectl get nodes -o json 2>/dev/null | jq -r --arg ocid "$instance_ocid" '
        .items[] | select(.spec.providerID | contains($ocid)) | 
        "\(.metadata.name)|\(.status.conditions[] | select(.type=="Ready") | .status)|\(.metadata.labels["nvidia.com/gpu.clique"] // "N/A")|\(.metadata.labels["nvidia.com/gpu.present"] // "false")"
    ' 2>/dev/null)
    
    if [[ -n "$k8s_node_info" ]]; then
        local k8s_node_name k8s_ready k8s_clique k8s_gpu_present
        IFS='|' read -r k8s_node_name k8s_ready k8s_clique k8s_gpu_present <<< "$k8s_node_info"
        
        local ready_color="$GREEN"
        [[ "$k8s_ready" != "True" ]] && ready_color="$RED"
        
        echo -e "  ${WHITE}In Kubernetes:${NC}   ${GREEN}Yes${NC}"
        echo -e "  ${WHITE}Node Name:${NC}       ${GREEN}$k8s_node_name${NC}"
        echo -e "  ${WHITE}Ready:${NC}           ${ready_color}$k8s_ready${NC}"
        if [[ "$k8s_gpu_present" == "true" ]]; then
            echo -e "  ${WHITE}GPU Present:${NC}     ${GREEN}Yes${NC}"
            [[ "$k8s_clique" != "N/A" ]] && echo -e "  ${WHITE}GPU Clique:${NC}      ${CYAN}$k8s_clique${NC}"
        fi
    else
        echo -e "  ${WHITE}In Kubernetes:${NC}   ${YELLOW}No${NC} (not joined or not found)"
    fi
    
    # ========== NETWORK / VNIC INFORMATION ==========
    echo ""
    echo -e "${BOLD}${CYAN}=== Network (VNICs) ===${NC}"
    
    # Get VNIC attachments
    local vnic_attachments
    vnic_attachments=$(oci compute vnic-attachment list \
        --compartment-id "$compartment_id" \
        --instance-id "$instance_ocid" \
        --output json 2>/dev/null)
    
    if [[ -n "$vnic_attachments" ]] && echo "$vnic_attachments" | jq -e '.data[]' > /dev/null 2>&1; then
        echo "$vnic_attachments" | jq -r '.data[] | "\(.["vnic-id"])|\(.["display-name"] // "N/A")|\(.["nic-index"] // 0)"' 2>/dev/null | \
        while IFS='|' read -r vnic_id vnic_attach_name nic_index; do
            [[ -z "$vnic_id" ]] && continue
            
            # Get VNIC details
            local vnic_json
            vnic_json=$(oci network vnic get --vnic-id "$vnic_id" --output json 2>/dev/null)
            
            if [[ -n "$vnic_json" ]] && echo "$vnic_json" | jq -e '.data' > /dev/null 2>&1; then
                local vnic_name private_ip public_ip subnet_id mac_addr is_primary
                vnic_name=$(echo "$vnic_json" | jq -r '.data["display-name"] // "N/A"')
                private_ip=$(echo "$vnic_json" | jq -r '.data["private-ip"] // "N/A"')
                public_ip=$(echo "$vnic_json" | jq -r '.data["public-ip"] // "N/A"')
                subnet_id=$(echo "$vnic_json" | jq -r '.data["subnet-id"] // "N/A"')
                mac_addr=$(echo "$vnic_json" | jq -r '.data["mac-address"] // "N/A"')
                is_primary=$(echo "$vnic_json" | jq -r '.data["is-primary"] // false')
                
                # Resolve subnet name
                local subnet_name="N/A"
                if [[ "$subnet_id" != "N/A" && -n "$subnet_id" ]]; then
                    subnet_name=$(oci network subnet get --subnet-id "$subnet_id" --query 'data."display-name"' --raw-output 2>/dev/null) || subnet_name="N/A"
                fi
                
                local primary_marker=""
                [[ "$is_primary" == "true" ]] && primary_marker=" ${GREEN}(Primary)${NC}"
                
                echo ""
                echo -e "  ${BOLD}${WHITE}NIC ${nic_index}:${NC} ${GREEN}$vnic_name${NC}${primary_marker}"
                echo -e "    ${WHITE}Private IP:${NC}  ${CYAN}$private_ip${NC}"
                if [[ "$public_ip" != "N/A" && "$public_ip" != "null" && -n "$public_ip" ]]; then
                    echo -e "    ${WHITE}Public IP:${NC}   ${CYAN}$public_ip${NC}"
                fi
                echo -e "    ${WHITE}MAC Address:${NC} $mac_addr"
                echo -e "    ${WHITE}Subnet:${NC}      ${GREEN}$subnet_name${NC}"
                echo -e "                  ${YELLOW}$subnet_id${NC}"
            fi
        done
    else
        echo -e "  ${YELLOW}No VNICs found${NC}"
    fi
    
    # ========== BOOT VOLUME ==========
    echo ""
    echo -e "${BOLD}${CYAN}=== Boot Volume ===${NC}"
    
    local boot_vol_attachments
    boot_vol_attachments=$(oci compute boot-volume-attachment list \
        --compartment-id "$compartment_id" \
        --availability-domain "$ad" \
        --instance-id "$instance_ocid" \
        --output json 2>/dev/null)
    
    if [[ -n "$boot_vol_attachments" ]] && echo "$boot_vol_attachments" | jq -e '.data[]' > /dev/null 2>&1; then
        echo "$boot_vol_attachments" | jq -r '.data[] | "\(.["boot-volume-id"])|\(.["lifecycle-state"])"' 2>/dev/null | \
        while IFS='|' read -r bv_id bv_attach_state; do
            [[ -z "$bv_id" ]] && continue
            
            # Get boot volume details
            local bv_json
            bv_json=$(oci bv boot-volume get --boot-volume-id "$bv_id" --output json 2>/dev/null)
            
            if [[ -n "$bv_json" ]] && echo "$bv_json" | jq -e '.data' > /dev/null 2>&1; then
                local bv_name bv_state bv_size_gb bv_vpus
                bv_name=$(echo "$bv_json" | jq -r '.data["display-name"] // "N/A"')
                bv_state=$(echo "$bv_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                bv_size_gb=$(echo "$bv_json" | jq -r '.data["size-in-gbs"] // "N/A"')
                bv_vpus=$(echo "$bv_json" | jq -r '.data["vpus-per-gb"] // "N/A"')
                
                local bv_state_color="$GREEN"
                [[ "$bv_state" != "AVAILABLE" ]] && bv_state_color="$YELLOW"
                
                echo -e "  ${WHITE}Name:${NC}   ${GREEN}$bv_name${NC}"
                echo -e "  ${WHITE}OCID:${NC}   ${YELLOW}$bv_id${NC}"
                echo -e "  ${WHITE}State:${NC}  ${bv_state_color}$bv_state${NC}"
                echo -e "  ${WHITE}Size:${NC}   ${bv_size_gb} GB"
                echo -e "  ${WHITE}VPUs:${NC}   ${bv_vpus} per GB"
            fi
        done
    else
        echo -e "  ${YELLOW}No boot volume found${NC}"
    fi
    
    # ========== BLOCK VOLUMES ==========
    echo ""
    echo -e "${BOLD}${CYAN}=== Block Volumes ===${NC}"
    
    local block_vol_attachments
    block_vol_attachments=$(oci compute volume-attachment list \
        --compartment-id "$compartment_id" \
        --instance-id "$instance_ocid" \
        --output json 2>/dev/null)
    
    local vol_count=0
    if [[ -n "$block_vol_attachments" ]] && echo "$block_vol_attachments" | jq -e '.data[]' > /dev/null 2>&1; then
        while IFS='|' read -r vol_id attach_state attach_type device is_readonly; do
            [[ -z "$vol_id" ]] && continue
            ((vol_count++))
            
            # Get block volume details
            local vol_json
            vol_json=$(oci bv volume get --volume-id "$vol_id" --output json 2>/dev/null)
            
            if [[ -n "$vol_json" ]] && echo "$vol_json" | jq -e '.data' > /dev/null 2>&1; then
                local vol_name vol_state vol_size_gb vol_vpus
                vol_name=$(echo "$vol_json" | jq -r '.data["display-name"] // "N/A"')
                vol_state=$(echo "$vol_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                vol_size_gb=$(echo "$vol_json" | jq -r '.data["size-in-gbs"] // "N/A"')
                vol_vpus=$(echo "$vol_json" | jq -r '.data["vpus-per-gb"] // "N/A"')
                
                local vol_state_color="$GREEN"
                [[ "$vol_state" != "AVAILABLE" ]] && vol_state_color="$YELLOW"
                
                local readonly_marker=""
                [[ "$is_readonly" == "true" ]] && readonly_marker=" ${YELLOW}(Read-Only)${NC}"
                
                echo ""
                echo -e "  ${BOLD}${WHITE}Volume ${vol_count}:${NC} ${GREEN}$vol_name${NC}${readonly_marker}"
                echo -e "    ${WHITE}OCID:${NC}       ${YELLOW}$vol_id${NC}"
                echo -e "    ${WHITE}State:${NC}      ${vol_state_color}$vol_state${NC}"
                echo -e "    ${WHITE}Size:${NC}       ${vol_size_gb} GB"
                echo -e "    ${WHITE}VPUs:${NC}       ${vol_vpus} per GB"
                echo -e "    ${WHITE}Attachment:${NC} $attach_type"
                [[ "$device" != "N/A" && -n "$device" ]] && echo -e "    ${WHITE}Device:${NC}     $device"
            fi
        done < <(echo "$block_vol_attachments" | jq -r '.data[] | "\(.["volume-id"])|\(.["lifecycle-state"])|\(.["attachment-type"])|\(.device // "N/A")|\(.["is-read-only"] // false)"' 2>/dev/null)
    fi
    
    [[ $vol_count -eq 0 ]] && echo -e "  ${GRAY}No block volumes attached${NC}"
}

#===============================================================================
# GPU MEMORY FABRIC & CLUSTER MANAGEMENT
#===============================================================================

interactive_gpu_management() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    while true; do
        display_gpu_management_menu
        
        echo -e "${BOLD}${WHITE}═══ Actions ═══${NC}"
        echo -e "  ${YELLOW}f#/g#/i#/c#${NC} - View resource details (e.g., 'f1', 'g2', 'i3', 'c1')"
        echo -e "  ${GREEN}create${NC}      - Create a new GPU Memory Cluster on a Fabric"
        echo -e "  ${YELLOW}update${NC}      - Update an existing GPU Memory Cluster (size/instance config)"
        echo -e "  ${RED}delete-ic${NC}   - Delete an Instance Configuration"
        echo -e "  ${BLUE}update-ic${NC}   - Update ALL GPU Memory Clusters with a selected Instance Configuration"
        echo -e "  ${MAGENTA}refresh${NC}     - Refresh data from OCI"
        echo -e "  ${CYAN}back${NC}        - Return to main menu"
        echo ""
        echo -n -e "${BOLD}${CYAN}Enter # or command [f#/g#/i#/c#/create/update/update-ic/delete-ic/refresh/back]: ${NC}"
        
        local input
        read -r input
        
        # Empty input goes back
        if [[ -z "$input" ]]; then
            return
        fi
        
        case "$input" in
            create|CREATE)
                create_gpu_memory_cluster_interactive
                ;;
            update|UPDATE)
                update_gpu_memory_cluster_interactive
                ;;
            update-ic|UPDATE-IC)
                update_all_clusters_instance_config
                ;;
            delete-ic|DELETE-IC)
                delete_instance_configuration_interactive
                ;;
            refresh|REFRESH)
                echo -e "${YELLOW}Refreshing cache...${NC}"
                rm -f "$FABRIC_CACHE" "$CLUSTER_CACHE" "$INSTANCE_CONFIG_CACHE" "$COMPUTE_CLUSTER_CACHE"
                ;;
            quit|QUIT|q|Q|exit|EXIT|back|BACK|b|B)
                return
                ;;
            f[0-9]*|g[0-9]*|i[0-9]*|c[0-9]*)
                view_gpu_resource "$input"
                ;;
            *)
                echo -e "${RED}Unknown command: $input${NC}"
                ;;
        esac
    done
}

# View details of a fabric or cluster
view_gpu_resource() {
    local resource_id="$1"
    
    case "$resource_id" in
        f[0-9]*)
            local fabric_ocid="${FABRIC_INDEX_MAP[$resource_id]:-}"
            if [[ -z "$fabric_ocid" ]]; then
                echo -e "${RED}Invalid fabric ID: $resource_id${NC}"
                return 1
            fi
            
            echo ""
            echo -e "${BOLD}${ORANGE}=== GPU Memory Fabric Details ===${NC}"
            
            # Fetch full details
            local fabric_json
            fabric_json=$(oci compute compute-gpu-memory-fabric get \
                --compute-gpu-memory-fabric-id "$fabric_ocid" \
                --output json 2>/dev/null)
            
            if [[ -n "$fabric_json" ]]; then
                local fabric_name
                fabric_name=$(echo "$fabric_json" | jq -r '.data["display-name"] // "N/A"')
                echo -e "${WHITE}Name:${NC} ${ORANGE}$fabric_name${NC}"
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$fabric_ocid${NC}"
                echo ""
                echo "$fabric_json" | jq -r '
                    .data | 
                    "State:             \(.["lifecycle-state"] // "N/A")",
                    "Healthy Hosts:     \(.["healthy-host-count"] // 0)",
                    "Available Hosts:   \(.["available-host-count"] // 0)",
                    "Total Hosts:       \(.["total-host-count"] // 0)",
                    "Current Firmware:  \(.["current-firmware-bundle-id"] // "N/A")",
                    "Target Firmware:   \(.["target-firmware-bundle-id"] // "N/A")",
                    "Firmware State:    \(.["firmware-update-state"] // "N/A")",
                    "Time Created:      \(.["time-created"] // "N/A")"
                '
            else
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$fabric_ocid${NC}"
                echo ""
                echo -e "${RED}Failed to fetch fabric details${NC}"
            fi
            ;;
            
        g[0-9]*)
            local cluster_ocid="${CLUSTER_INDEX_MAP[$resource_id]:-}"
            if [[ -z "$cluster_ocid" ]]; then
                echo -e "${RED}Invalid cluster ID: $resource_id${NC}"
                return 1
            fi
            
            echo ""
            echo -e "${BOLD}${MAGENTA}=== GPU Memory Cluster Details ===${NC}"
            
            # Fetch full details
            local cluster_json
            cluster_json=$(oci compute compute-gpu-memory-cluster get \
                --compute-gpu-memory-cluster-id "$cluster_ocid" \
                --output json 2>/dev/null)
            
            if [[ -n "$cluster_json" ]]; then
                local cluster_name
                cluster_name=$(echo "$cluster_json" | jq -r '.data["display-name"] // "N/A"')
                echo -e "${WHITE}Name:${NC} ${MAGENTA}$cluster_name${NC}"
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$cluster_ocid${NC}"
                echo ""
                
                local ic_id cc_id fabric_id
                ic_id=$(echo "$cluster_json" | jq -r '.data["instance-configuration-id"] // "N/A"')
                cc_id=$(echo "$cluster_json" | jq -r '.data["compute-cluster-id"] // "N/A"')
                fabric_id=$(echo "$cluster_json" | jq -r '.data["gpu-memory-fabric-id"] // "N/A"')
                
                local ic_name cc_name
                ic_name=$(get_instance_config_name "$ic_id")
                cc_name=$(get_compute_cluster_name "$cc_id")
                
                echo "$cluster_json" | jq -r '
                    .data | 
                    "State:                  \(.["lifecycle-state"] // "N/A")",
                    "Size:                   \(.["size"] // 0)",
                    "Availability Domain:    \(.["availability-domain"] // "N/A")",
                    "Time Created:           \(.["time-created"] // "N/A")"
                '
                echo -e "Instance Configuration: ${GREEN}$ic_name${NC} ${YELLOW}($ic_id)${NC}"
                echo -e "Compute Cluster:        ${GREEN}$cc_name${NC} ${YELLOW}($cc_id)${NC}"
                
                # Resolve fabric name
                local fabric_name="N/A"
                if [[ "$fabric_id" != "N/A" && -n "$fabric_id" ]]; then
                    fabric_name=$(oci compute compute-gpu-memory-fabric get --compute-gpu-memory-fabric-id "$fabric_id" --query 'data."display-name"' --raw-output 2>/dev/null) || fabric_name="N/A"
                fi
                echo -e "GPU Memory Fabric:      ${GREEN}$fabric_name${NC} ${YELLOW}($fabric_id)${NC}"
            else
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$cluster_ocid${NC}"
                echo ""
                echo -e "${RED}Failed to fetch cluster details${NC}"
            fi
            ;;
            
        i[0-9]*)
            local ic_ocid="${IC_INDEX_MAP[$resource_id]:-}"
            if [[ -z "$ic_ocid" ]]; then
                echo -e "${RED}Invalid instance config ID: $resource_id${NC}"
                return 1
            fi
            
            echo ""
            echo -e "${BOLD}${GREEN}=== Instance Configuration Details ===${NC}"
            
            local ic_json
            ic_json=$(oci compute-management instance-configuration get \
                --instance-configuration-id "$ic_ocid" \
                --output json 2>/dev/null)
            
            if [[ -n "$ic_json" ]]; then
                local ic_name ic_time_created ic_compartment
                ic_name=$(echo "$ic_json" | jq -r '.data["display-name"] // "N/A"')
                ic_time_created=$(echo "$ic_json" | jq -r '.data["time-created"] // "N/A"')
                ic_compartment=$(echo "$ic_json" | jq -r '.data["compartment-id"] // "N/A"')
                
                echo -e "${WHITE}Name:${NC}         ${GREEN}$ic_name${NC}"
                echo -e "${WHITE}OCID:${NC}         ${YELLOW}$ic_ocid${NC}"
                echo -e "${WHITE}Time Created:${NC} $ic_time_created"
                echo -e "${WHITE}Compartment:${NC}  $ic_compartment"
                
                # Show instance details from the configuration
                echo ""
                echo -e "${BOLD}${CYAN}Instance Details:${NC}"
                echo "$ic_json" | jq -r '
                    .data["instance-details"]["launch-details"] // {} |
                    "  Shape:              \(.shape // "N/A")",
                    "  Availability Domain: \(.["availability-domain"] // "N/A")",
                    "  Compartment:        \(.["compartment-id"][-20:] // "N/A")"
                ' 2>/dev/null
                
                # Show source details
                local source_type
                source_type=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["source-details"]["source-type"] // "N/A"' 2>/dev/null)
                echo -e "  Source Type:        $source_type"
                
                if [[ "$source_type" == "image" ]]; then
                    local image_id
                    image_id=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["source-details"]["image-id"] // "N/A"' 2>/dev/null)
                    echo -e "  Image ID:           ${YELLOW}...${image_id: -20}${NC}"
                fi
                
                # Show action option
                echo ""
                echo -e "${BOLD}${WHITE}Actions:${NC}"
                echo -e "  ${RED}delete${NC} - Delete this instance configuration"
                echo -e "  ${CYAN}Enter${NC}  - Return to menu"
                echo ""
                echo -n -e "${CYAN}Action [delete/Enter]: ${NC}"
                
                local action
                read -r action
                
                if [[ "$action" == "delete" || "$action" == "DELETE" ]]; then
                    # Store the ic_ocid for deletion
                    IC_INDEX_MAP["delete_target"]="$ic_ocid"
                    delete_single_instance_configuration "$ic_ocid" "$ic_name"
                fi
            else
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$ic_ocid${NC}"
                echo ""
                echo -e "${RED}Failed to fetch instance configuration details${NC}"
            fi
            ;;
            
        c[0-9]*)
            local cc_ocid="${CC_INDEX_MAP[$resource_id]:-}"
            if [[ -z "$cc_ocid" ]]; then
                echo -e "${RED}Invalid compute cluster ID: $resource_id${NC}"
                return 1
            fi
            
            echo ""
            echo -e "${BOLD}${BLUE}=== Compute Cluster Details ===${NC}"
            
            local cc_json
            cc_json=$(oci compute compute-cluster get \
                --compute-cluster-id "$cc_ocid" \
                --output json 2>/dev/null)
            
            if [[ -n "$cc_json" ]]; then
                local cc_name
                cc_name=$(echo "$cc_json" | jq -r '.data["display-name"] // "N/A"')
                echo -e "${WHITE}Name:${NC} ${BLUE}$cc_name${NC}"
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$cc_ocid${NC}"
                echo ""
                echo "$cc_json" | jq -r '
                    .data | 
                    "State:                \(.["lifecycle-state"] // "N/A")",
                    "Availability Domain:  \(.["availability-domain"] // "N/A")",
                    "Time Created:         \(.["time-created"] // "N/A")"
                '
            else
                echo -e "${WHITE}OCID:${NC} ${YELLOW}$cc_ocid${NC}"
                echo ""
                echo -e "${RED}Failed to fetch compute cluster details${NC}"
            fi
            ;;
            
        *)
            echo -e "${RED}Invalid resource ID format. Use f#, g#, i#, or c#${NC}"
            return 1
            ;;
    esac
}

# Create GPU Memory Cluster interactively
create_gpu_memory_cluster_interactive() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    echo ""
    echo -e "${BOLD}${GREEN}═══ Create GPU Memory Cluster ═══${NC}"
    echo ""
    
    # Refresh caches to get latest data
    echo -e "${YELLOW}Refreshing data from OCI...${NC}"
    rm -f "$FABRIC_CACHE" "$CLUSTER_CACHE" "$INSTANCE_CONFIG_CACHE" "$COMPUTE_CLUSTER_CACHE"
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_instance_configurations
    fetch_compute_clusters
    
    # Rebuild index maps
    display_gpu_management_menu > /dev/null 2>&1
    
    echo -e "${GREEN}✓ Data refreshed${NC}"
    echo ""
    
    # Display available GPU Memory Fabrics (only those with capacity)
    echo -e "${WHITE}GPU Memory Fabrics with Available Capacity:${NC}"
    echo ""
    printf "${BOLD}%-6s %-45s %-12s %8s %6s %6s  %-90s${NC}\n" \
        "ID" "Fabric Name" "State" "Healthy" "Avail" "Total" "Fabric OCID"
    print_separator 180
    
    local has_available=false
    local fabric_output_temp
    fabric_output_temp=$(mktemp)
    
    # Build map of fabric availability for later use
    declare -A FABRIC_AVAIL_MAP
    
    local fid
    for fid in "${!FABRIC_INDEX_MAP[@]}"; do
        local fabric_ocid="${FABRIC_INDEX_MAP[$fid]}"
        [[ -z "$fabric_ocid" ]] && continue
        
        # Get fabric info from cache
        local fabric_line
        fabric_line=$(grep "^[^#].*|${fabric_ocid}|" "$FABRIC_CACHE" 2>/dev/null | head -1)
        [[ -z "$fabric_line" ]] && fabric_line=$(grep "${fabric_ocid}" "$FABRIC_CACHE" 2>/dev/null | head -1)
        
        if [[ -n "$fabric_line" ]]; then
            local f_name f_suffix f_ocid f_state f_healthy f_avail f_total
            IFS='|' read -r f_name f_suffix f_ocid f_state f_healthy f_avail f_total _ _ _ <<< "$fabric_line"
            
            # Only include fabrics with available capacity
            if [[ "$f_avail" != "0" && "$f_avail" != "N/A" && -n "$f_avail" && "$f_avail" -gt 0 ]] 2>/dev/null; then
                has_available=true
                FABRIC_AVAIL_MAP[$fid]="$f_avail"
                
                # Store for sorting (numeric key|display data including OCID)
                local fid_num="${fid#f}"
                echo "${fid_num}|${fid}|${f_name}|${f_state}|${f_healthy}|${f_avail}|${f_total}|${fabric_ocid}" >> "$fabric_output_temp"
            fi
        fi
    done
    
    # Sort and display
    sort -t'|' -k1 -n "$fabric_output_temp" | while IFS='|' read -r _ fid f_name f_state f_healthy f_avail f_total f_ocid; do
        # State color
        local state_color="$GREEN"
        [[ "$f_state" != "AVAILABLE" && "$f_state" != "OCCUPIED" ]] && state_color="$RED"
        
        printf "${YELLOW}%-6s${NC} ${CYAN}%-45s${NC} ${state_color}%-12s${NC} %8s ${LIGHT_GREEN}%6s${NC} %6s  ${GRAY}%-90s${NC}\n" \
            "$fid" "$f_name" "$f_state" "$f_healthy" "$f_avail" "$f_total" "$f_ocid"
    done
    
    rm -f "$fabric_output_temp"
    
    echo ""
    
    if [[ "$has_available" != "true" ]]; then
        echo -e "${RED}No GPU Memory Fabrics have available capacity. Cannot create cluster.${NC}"
        return 1
    fi
    
    # Select Fabric
    echo -n -e "${CYAN}Select GPU Memory Fabric (f#): ${NC}"
    local fabric_input
    read -r fabric_input
    
    local fabric_ocid="${FABRIC_INDEX_MAP[$fabric_input]:-}"
    if [[ -z "$fabric_ocid" ]]; then
        echo -e "${RED}Invalid fabric selection: $fabric_input${NC}"
        return 1
    fi
    
    # Check fabric has availability
    local fabric_avail="${FABRIC_AVAIL_MAP[$fabric_input]:-0}"
    if [[ "$fabric_avail" -eq 0 ]] 2>/dev/null; then
        echo -e "${RED}Selected fabric has no available capacity${NC}"
        return 1
    fi
    
    # Get fabric suffix for display name
    local fabric_suffix="${fabric_ocid: -5}"
    local default_display_name="fabric-${fabric_suffix}"
    
    echo -e "${WHITE}Selected Fabric:${NC} ${YELLOW}$fabric_ocid${NC}"
    echo -e "${WHITE}Available Nodes:${NC} ${LIGHT_GREEN}$fabric_avail${NC}"
    echo ""
    
    # Display Compute Clusters
    echo -e "${WHITE}Available Compute Clusters:${NC}"
    echo ""
    printf "${BOLD}%-6s %-45s %-40s${NC}\n" \
        "ID" "Compute Cluster Name" "Availability Domain"
    print_separator 95
    
    local cc_output_temp
    cc_output_temp=$(mktemp)
    
    local cid
    for cid in "${!CC_INDEX_MAP[@]}"; do
        local cc_ocid="${CC_INDEX_MAP[$cid]}"
        [[ -z "$cc_ocid" ]] && continue
        
        # Get compute cluster info from cache
        local cc_line cc_name cc_ad
        cc_line=$(grep "^${cc_ocid}|" "$COMPUTE_CLUSTER_CACHE" 2>/dev/null | head -1)
        if [[ -n "$cc_line" ]]; then
            IFS='|' read -r _ cc_name cc_ad <<< "$cc_line"
        else
            cc_name="N/A"
            cc_ad="N/A"
        fi
        
        local cid_num="${cid#c}"
        echo "${cid_num}|${cid}|${cc_name}|${cc_ad}" >> "$cc_output_temp"
    done
    
    sort -t'|' -k1 -n "$cc_output_temp" | while IFS='|' read -r _ cid cc_name cc_ad; do
        printf "${YELLOW}%-6s${NC} ${CYAN}%-45s${NC} ${MAGENTA}%-40s${NC}\n" \
            "$cid" "$cc_name" "$cc_ad"
    done
    
    rm -f "$cc_output_temp"
    
    echo ""
    
    # Select Compute Cluster
    echo -n -e "${CYAN}Select Compute Cluster (c#): ${NC}"
    local cc_input
    read -r cc_input
    
    local cc_ocid="${CC_INDEX_MAP[$cc_input]:-}"
    if [[ -z "$cc_ocid" ]]; then
        echo -e "${RED}Invalid compute cluster selection: $cc_input${NC}"
        return 1
    fi
    
    # Get AD from compute cluster
    local cc_ad
    cc_ad=$(oci compute compute-cluster get \
        --compute-cluster-id "$cc_ocid" \
        --query 'data."availability-domain"' \
        --raw-output 2>/dev/null)
    
    echo -e "${WHITE}Selected Compute Cluster:${NC} ${YELLOW}$cc_ocid${NC}"
    echo -e "${WHITE}Availability Domain:${NC} ${MAGENTA}$cc_ad${NC}"
    echo ""
    
    # Display Instance Configurations
    echo -e "${WHITE}Available Instance Configurations:${NC}"
    echo ""
    printf "${BOLD}%-6s %-60s${NC}\n" \
        "ID" "Instance Configuration Name"
    print_separator 70
    
    local ic_output_temp
    ic_output_temp=$(mktemp)
    
    local iid
    for iid in "${!IC_INDEX_MAP[@]}"; do
        local ic_ocid="${IC_INDEX_MAP[$iid]}"
        [[ -z "$ic_ocid" ]] && continue
        
        # Get instance config info from cache
        local ic_line ic_name
        ic_line=$(grep "^${ic_ocid}|" "$INSTANCE_CONFIG_CACHE" 2>/dev/null | head -1)
        if [[ -n "$ic_line" ]]; then
            IFS='|' read -r _ ic_name <<< "$ic_line"
        else
            ic_name="N/A"
        fi
        
        local iid_num="${iid#i}"
        echo "${iid_num}|${iid}|${ic_name}" >> "$ic_output_temp"
    done
    
    sort -t'|' -k1 -n "$ic_output_temp" | while IFS='|' read -r _ iid ic_name; do
        printf "${YELLOW}%-6s${NC} ${CYAN}%-60s${NC}\n" \
            "$iid" "$ic_name"
    done
    
    rm -f "$ic_output_temp"
    
    echo ""
    
    # Select Instance Configuration
    echo -n -e "${CYAN}Select Instance Configuration (i#): ${NC}"
    local ic_input
    read -r ic_input
    
    local ic_ocid="${IC_INDEX_MAP[$ic_input]:-}"
    if [[ -z "$ic_ocid" ]]; then
        echo -e "${RED}Invalid instance configuration selection: $ic_input${NC}"
        return 1
    fi
    
    echo -e "${WHITE}Selected Instance Config:${NC} ${YELLOW}$ic_ocid${NC}"
    echo ""
    
    # Enter Size (default 1, max = fabric availability)
    echo -n -e "${CYAN}Enter cluster size (1-${fabric_avail}) [1]: ${NC}"
    local cluster_size
    read -r cluster_size
    cluster_size="${cluster_size:-1}"
    
    if ! [[ "$cluster_size" =~ ^[0-9]+$ ]] || [[ "$cluster_size" -lt 1 ]]; then
        echo -e "${RED}Invalid size: must be a positive integer${NC}"
        return 1
    fi
    
    if [[ "$cluster_size" -gt "$fabric_avail" ]]; then
        echo -e "${RED}Invalid size: requested $cluster_size but only $fabric_avail nodes available${NC}"
        return 1
    fi
    
    # Enter Display Name
    echo -n -e "${CYAN}Enter display name [${default_display_name}]: ${NC}"
    local display_name
    read -r display_name
    display_name="${display_name:-$default_display_name}"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Confirm Creation ═══${NC}"
    echo -e "  ${CYAN}Display Name:${NC}         $display_name"
    echo -e "  ${CYAN}Availability Domain:${NC}  $cc_ad"
    echo -e "  ${CYAN}Compartment ID:${NC}       $compartment_id"
    echo -e "  ${CYAN}Compute Cluster:${NC}      $cc_ocid"
    echo -e "  ${CYAN}Instance Config:${NC}      $ic_ocid"
    echo -e "  ${CYAN}GPU Memory Fabric:${NC}    $fabric_ocid"
    echo -e "  ${CYAN}Size:${NC}                 $cluster_size"
    echo ""
    
    echo -e "${BOLD}${WHITE}Command to execute:${NC}"
    echo -e "${GRAY}oci compute compute-gpu-memory-cluster create \\
    --availability-domain \"$cc_ad\" \\
    --compartment-id \"$compartment_id\" \\
    --compute-cluster-id \"$cc_ocid\" \\
    --instance-configuration-id \"$ic_ocid\" \\
    --gpu-memory-fabric-id \"$fabric_ocid\" \\
    --size $cluster_size \\
    --display-name \"$display_name\"${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Proceed with creation? (yes/no): ${NC}"
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${RED}Creation cancelled${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${GREEN}Creating GPU Memory Cluster...${NC}"
    
    # Create the cluster
    local result
    result=$(oci compute compute-gpu-memory-cluster create \
        --availability-domain "$cc_ad" \
        --compartment-id "$compartment_id" \
        --compute-cluster-id "$cc_ocid" \
        --instance-configuration-id "$ic_ocid" \
        --gpu-memory-fabric-id "$fabric_ocid" \
        --size "$cluster_size" \
        --display-name "$display_name" \
        --output json 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}GPU Memory Cluster creation initiated successfully!${NC}"
        echo ""
        local new_cluster_id
        new_cluster_id=$(echo "$result" | jq -r '.data.id // "N/A"')
        local new_cluster_state
        new_cluster_state=$(echo "$result" | jq -r '.data["lifecycle-state"] // "N/A"')
        
        echo -e "${WHITE}New Cluster OCID:${NC}  ${YELLOW}$new_cluster_id${NC}"
        echo -e "${WHITE}Initial State:${NC}     ${CYAN}$new_cluster_state${NC}"
        
        # Invalidate cluster and fabric caches (fabric available-host-count changes)
        rm -f "$CLUSTER_CACHE" "$FABRIC_CACHE"
    else
        echo -e "${RED}Failed to create GPU Memory Cluster:${NC}"
        echo "$result"
        return 1
    fi
}

# Update GPU Memory Cluster interactively
update_gpu_memory_cluster_interactive() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    
    echo ""
    echo -e "${BOLD}${YELLOW}═══ Update GPU Memory Cluster ═══${NC}"
    echo ""
    
    # Refresh caches to get latest data
    echo -e "${YELLOW}Refreshing data from OCI...${NC}"
    rm -f "$FABRIC_CACHE" "$CLUSTER_CACHE" "$INSTANCE_CONFIG_CACHE" "$COMPUTE_CLUSTER_CACHE"
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_instance_configurations
    fetch_compute_clusters
    
    # Rebuild index maps
    display_gpu_management_menu > /dev/null 2>&1
    
    echo -e "${GREEN}✓ Data refreshed${NC}"
    echo ""
    
    # List available GPU Memory Clusters
    echo -e "${WHITE}Available GPU Memory Clusters:${NC}"
    echo ""
    printf "${BOLD}%-6s %-35s %-10s %6s  %-40s %8s %6s %6s${NC}\n" \
        "ID" "Cluster Name" "State" "Size" "Fabric" "Healthy" "Avail" "Total"
    print_separator 130
    
    # Collect cluster lines for sorting
    local cluster_lines_temp
    cluster_lines_temp=$(mktemp)
    local has_clusters=false
    
    for gid in "${!CLUSTER_INDEX_MAP[@]}"; do
        local cluster_ocid="${CLUSTER_INDEX_MAP[$gid]}"
        [[ -z "$cluster_ocid" ]] && continue
        
        has_clusters=true
        
        # Get cluster info from cache
        local cluster_line
        cluster_line=$(grep "^${cluster_ocid}|" "$CLUSTER_CACHE" 2>/dev/null | head -1)
        
        if [[ -n "$cluster_line" ]]; then
            local c_name c_state c_fabric_suffix c_size
            IFS='|' read -r _ c_name c_state c_fabric_suffix _ _ c_size <<< "$cluster_line"
            
            # Get fabric info from suffix
            local fabric_name="N/A" f_healthy="N/A" f_avail="N/A" f_total="N/A"
            if [[ -n "$c_fabric_suffix" ]]; then
                local fabric_line
                fabric_line=$(grep -v '^#' "$FABRIC_CACHE" 2>/dev/null | grep "|${c_fabric_suffix}|" | head -1)
                if [[ -n "$fabric_line" ]]; then
                    IFS='|' read -r fabric_name _ _ _ f_healthy f_avail f_total _ _ _ <<< "$fabric_line"
                fi
            fi
            
            # Store for sorting: gid_num|gid|name|state|size|fabric|healthy|avail|total
            local gid_num="${gid#g}"
            echo "${gid_num}|${gid}|${c_name}|${c_state}|${c_size}|${fabric_name}|${f_healthy}|${f_avail}|${f_total}" >> "$cluster_lines_temp"
        fi
    done
    
    # Sort and display
    sort -t'|' -k1 -n "$cluster_lines_temp" | while IFS='|' read -r _ gid c_name c_state c_size fabric_name f_healthy f_avail f_total; do
        # Color state
        local state_color
        case "$c_state" in
            ACTIVE) state_color="${GREEN}" ;;
            CREATING) state_color="${CYAN}" ;;
            UPDATING|SCALING) state_color="${YELLOW}" ;;
            INACTIVE|FAILED|DELETED|DELETING) state_color="${RED}" ;;
            *) state_color="${WHITE}" ;;
        esac
        
        # Color available - highlight if > 0
        local avail_color="${WHITE}"
        [[ "$f_avail" != "N/A" && "$f_avail" != "0" ]] && avail_color="${LIGHT_GREEN}"
        
        printf "${YELLOW}%-6s${NC} ${MAGENTA}%-35s${NC} ${state_color}%-10s${NC} %6s  ${CYAN}%-40s${NC} %8s ${avail_color}%6s${NC} %6s\n" \
            "$gid" "$c_name" "$c_state" "$c_size" "$fabric_name" "$f_healthy" "$f_avail" "$f_total"
    done
    
    rm -f "$cluster_lines_temp"
    
    if [[ "$has_clusters" != "true" ]]; then
        echo -e "  ${YELLOW}No GPU Memory Clusters available${NC}"
        return 1
    fi
    
    echo ""
    
    # Select Cluster
    echo -n -e "${CYAN}Select GPU Memory Cluster to update (g#): ${NC}"
    local cluster_input
    read -r cluster_input
    
    # Validate input is not empty
    if [[ -z "$cluster_input" ]]; then
        echo -e "${RED}No cluster selected${NC}"
        return 1
    fi
    
    # Check if cluster exists in the map (safely access associative array)
    local cluster_ocid=""
    if [[ -n "${CLUSTER_INDEX_MAP[$cluster_input]+x}" ]]; then
        cluster_ocid="${CLUSTER_INDEX_MAP[$cluster_input]}"
    fi
    
    if [[ -z "$cluster_ocid" ]]; then
        echo -e "${RED}Invalid cluster selection: $cluster_input${NC}"
        return 1
    fi
    
    # Get current cluster details
    local cluster_json
    cluster_json=$(oci compute compute-gpu-memory-cluster get \
        --compute-gpu-memory-cluster-id "$cluster_ocid" \
        --output json 2>/dev/null)
    
    if [[ -z "$cluster_json" ]]; then
        echo -e "${RED}Failed to fetch cluster details${NC}"
        return 1
    fi
    
    local current_name current_size current_ic current_state fabric_id
    current_name=$(echo "$cluster_json" | jq -r '.data["display-name"] // "N/A"')
    current_size=$(echo "$cluster_json" | jq -r '.data["size"] // 0')
    current_ic=$(echo "$cluster_json" | jq -r '.data["instance-configuration-id"] // "N/A"')
    current_state=$(echo "$cluster_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    fabric_id=$(echo "$cluster_json" | jq -r '.data["gpu-memory-fabric-id"] // "N/A"')
    
    # Get fabric info for capacity display
    local fabric_healthy="N/A" fabric_avail="N/A" fabric_total="N/A" fabric_name="N/A"
    if [[ "$fabric_id" != "N/A" && -n "$fabric_id" ]]; then
        local fabric_json
        fabric_json=$(oci compute compute-gpu-memory-fabric get \
            --compute-gpu-memory-fabric-id "$fabric_id" \
            --output json 2>/dev/null)
        
        if [[ -n "$fabric_json" ]]; then
            fabric_name=$(echo "$fabric_json" | jq -r '.data["display-name"] // "N/A"')
            fabric_healthy=$(echo "$fabric_json" | jq -r '.data["healthy-host-count"] // 0')
            fabric_avail=$(echo "$fabric_json" | jq -r '.data["available-host-count"] // 0')
            fabric_total=$(echo "$fabric_json" | jq -r '.data["total-host-count"] // 0')
        fi
    fi
    
    local current_ic_name
    current_ic_name=$(get_instance_config_name "$current_ic")
    
    echo ""
    echo -e "${WHITE}Current Cluster Details:${NC}"
    echo -e "  ${CYAN}Name:${NC}                 $current_name"
    echo -e "  ${CYAN}State:${NC}                $current_state"
    echo -e "  ${CYAN}Current Size:${NC}         $current_size"
    echo -e "  ${CYAN}Instance Config:${NC}      $current_ic_name"
    echo -e "                        ${YELLOW}$current_ic${NC}"
    echo ""
    echo -e "${WHITE}Fabric Capacity:${NC}"
    echo -e "  ${CYAN}Fabric:${NC}               $fabric_name"
    echo -e "  ${CYAN}Healthy Hosts:${NC}        ${GREEN}$fabric_healthy${NC}"
    echo -e "  ${CYAN}Available Hosts:${NC}      ${YELLOW}$fabric_avail${NC}"
    echo -e "  ${CYAN}Total Hosts:${NC}          $fabric_total"
    echo ""
    
    # Update options
    echo -e "${WHITE}What would you like to update?${NC}"
    echo -e "  ${GREEN}1${NC} - Size only"
    echo -e "  ${GREEN}2${NC} - Instance Configuration only"
    echo -e "  ${GREEN}3${NC} - Both Size and Instance Configuration"
    echo -e "  ${RED}0${NC} - Cancel"
    echo ""
    echo -n -e "${CYAN}Select option: ${NC}"
    local option
    read -r option
    
    local new_size=""
    local new_ic=""
    
    case "$option" in
        1)
            echo -e "${WHITE}Current: ${CYAN}$current_size${NC} | Fabric: Healthy=${GREEN}$fabric_healthy${NC} Avail=${YELLOW}$fabric_avail${NC} Total=$fabric_total${NC}"
            echo -n -e "${CYAN}Enter new size: ${NC}"
            read -r new_size
            if ! [[ "$new_size" =~ ^[0-9]+$ ]] || [[ "$new_size" -lt 1 ]]; then
                echo -e "${RED}Invalid size: must be a positive integer${NC}"
                return 1
            fi
            ;;
        2)
            # Display Instance Configurations
            echo ""
            echo -e "${WHITE}Available Instance Configurations:${NC}"
            echo ""
            printf "${BOLD}%-6s %-60s %-90s${NC}\n" \
                "ID" "Instance Configuration Name" "Instance Configuration OCID"
            print_separator 160
            
            local ic_output_temp
            ic_output_temp=$(mktemp)
            
            local iid
            for iid in "${!IC_INDEX_MAP[@]}"; do
                local ic_ocid="${IC_INDEX_MAP[$iid]}"
                [[ -z "$ic_ocid" ]] && continue
                
                local ic_line ic_name
                ic_line=$(grep "^${ic_ocid}|" "$INSTANCE_CONFIG_CACHE" 2>/dev/null | head -1)
                if [[ -n "$ic_line" ]]; then
                    IFS='|' read -r _ ic_name <<< "$ic_line"
                else
                    ic_name="N/A"
                fi
                
                local iid_num="${iid#i}"
                echo "${iid_num}|${iid}|${ic_name}|${ic_ocid}" >> "$ic_output_temp"
            done
            
            sort -t'|' -k1 -n "$ic_output_temp" | while IFS='|' read -r _ iid ic_name ic_ocid; do
                printf "${YELLOW}%-6s${NC} ${CYAN}%-60s${NC} ${GRAY}%-90s${NC}\n" \
                    "$iid" "$ic_name" "$ic_ocid"
            done
            
            rm -f "$ic_output_temp"
            echo ""
            
            echo -n -e "${CYAN}Select new Instance Configuration (i#): ${NC}"
            local ic_input
            read -r ic_input
            new_ic="${IC_INDEX_MAP[$ic_input]:-}"
            if [[ -z "$new_ic" ]]; then
                echo -e "${RED}Invalid instance configuration selection: $ic_input${NC}"
                return 1
            fi
            ;;
        3)
            echo -e "${WHITE}Current: ${CYAN}$current_size${NC} | Fabric: Healthy=${GREEN}$fabric_healthy${NC} Avail=${YELLOW}$fabric_avail${NC} Total=$fabric_total${NC}"
            echo -n -e "${CYAN}Enter new size: ${NC}"
            read -r new_size
            if ! [[ "$new_size" =~ ^[0-9]+$ ]] || [[ "$new_size" -lt 1 ]]; then
                echo -e "${RED}Invalid size: must be a positive integer${NC}"
                return 1
            fi
            
            # Display Instance Configurations
            echo ""
            echo -e "${WHITE}Available Instance Configurations:${NC}"
            echo ""
            printf "${BOLD}%-6s %-60s %-90s${NC}\n" \
                "ID" "Instance Configuration Name" "Instance Configuration OCID"
            print_separator 160
            
            local ic_output_temp
            ic_output_temp=$(mktemp)
            
            local iid
            for iid in "${!IC_INDEX_MAP[@]}"; do
                local ic_ocid="${IC_INDEX_MAP[$iid]}"
                [[ -z "$ic_ocid" ]] && continue
                
                local ic_line ic_name
                ic_line=$(grep "^${ic_ocid}|" "$INSTANCE_CONFIG_CACHE" 2>/dev/null | head -1)
                if [[ -n "$ic_line" ]]; then
                    IFS='|' read -r _ ic_name <<< "$ic_line"
                else
                    ic_name="N/A"
                fi
                
                local iid_num="${iid#i}"
                echo "${iid_num}|${iid}|${ic_name}|${ic_ocid}" >> "$ic_output_temp"
            done
            
            sort -t'|' -k1 -n "$ic_output_temp" | while IFS='|' read -r _ iid ic_name ic_ocid; do
                printf "${YELLOW}%-6s${NC} ${CYAN}%-60s${NC} ${GRAY}%-90s${NC}\n" \
                    "$iid" "$ic_name" "$ic_ocid"
            done
            
            rm -f "$ic_output_temp"
            echo ""
            
            echo -n -e "${CYAN}Select new Instance Configuration (i#): ${NC}"
            local ic_input
            read -r ic_input
            new_ic="${IC_INDEX_MAP[$ic_input]:-}"
            if [[ -z "$new_ic" ]]; then
                echo -e "${RED}Invalid instance configuration selection: $ic_input${NC}"
                return 1
            fi
            ;;
        0)
            echo -e "${RED}Update cancelled${NC}"
            return 0
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            return 1
            ;;
    esac
    
    # Build update command
    echo ""
    echo -e "${BOLD}${WHITE}═══ Confirm Update ═══${NC}"
    echo -e "  ${CYAN}Cluster:${NC}      $current_name"
    echo -e "  ${CYAN}Cluster OCID:${NC} $cluster_ocid"
    
    if [[ -n "$new_size" ]]; then
        echo -e "  ${CYAN}Size:${NC}         $current_size → ${GREEN}$new_size${NC}"
    fi
    
    if [[ -n "$new_ic" ]]; then
        local new_ic_name
        new_ic_name=$(get_instance_config_name "$new_ic")
        echo -e "  ${CYAN}Instance Config:${NC} $current_ic_name → ${GREEN}$new_ic_name${NC}"
    fi
    
    echo ""
    
    # Build and display the command
    local cmd_display="oci compute compute-gpu-memory-cluster update \\
    --compute-gpu-memory-cluster-id \"$cluster_ocid\""
    
    [[ -n "$new_size" ]] && cmd_display="$cmd_display \\
    --size $new_size"
    [[ -n "$new_ic" ]] && cmd_display="$cmd_display \\
    --instance-configuration-id \"$new_ic\""
    
    echo -e "${BOLD}${WHITE}Command to execute:${NC}"
    echo -e "${GRAY}${cmd_display}${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Proceed with update? (yes/no): ${NC}"
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${RED}Update cancelled${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${GREEN}Updating GPU Memory Cluster...${NC}"
    
    # Build and execute update command
    local result
    local cmd_args="--compute-gpu-memory-cluster-id $cluster_ocid"
    
    [[ -n "$new_size" ]] && cmd_args="$cmd_args --size $new_size"
    [[ -n "$new_ic" ]] && cmd_args="$cmd_args --instance-configuration-id $new_ic"
    
    result=$(oci compute compute-gpu-memory-cluster update $cmd_args --output json 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}GPU Memory Cluster update initiated successfully!${NC}"
        echo ""
        
        # Parse the response - handle both .data and direct response formats
        local updated_state updated_size updated_name
        updated_state=$(echo "$result" | jq -r 'if .data then .data["lifecycle-state"] else .["lifecycle-state"] end // "N/A"' 2>/dev/null)
        updated_size=$(echo "$result" | jq -r 'if .data then .data["size"] else .["size"] end // "N/A"' 2>/dev/null)
        updated_name=$(echo "$result" | jq -r 'if .data then .data["display-name"] else .["display-name"] end // "N/A"' 2>/dev/null)
        
        # Fallback if jq fails
        [[ -z "$updated_state" || "$updated_state" == "null" ]] && updated_state="N/A"
        [[ -z "$updated_size" || "$updated_size" == "null" ]] && updated_size="N/A"
        [[ -z "$updated_name" || "$updated_name" == "null" ]] && updated_name="$current_name"
        
        # Display with color based on state
        echo -e "${WHITE}Cluster:${NC}  ${MAGENTA}${updated_name}${NC}"
        case "$updated_state" in
            ACTIVE)           echo -e "${WHITE}State:${NC}    ${GREEN}${updated_state}${NC}" ;;
            UPDATING|SCALING) echo -e "${WHITE}State:${NC}    ${YELLOW}${updated_state}${NC}" ;;
            FAILED|INACTIVE)  echo -e "${WHITE}State:${NC}    ${RED}${updated_state}${NC}" ;;
            CREATING)         echo -e "${WHITE}State:${NC}    ${CYAN}${updated_state}${NC}" ;;
            *)                echo -e "${WHITE}State:${NC}    ${WHITE}${updated_state}${NC}" ;;
        esac
        echo -e "${WHITE}Size:${NC}     ${CYAN}${updated_size}${NC}"
        
        # Invalidate cluster and fabric caches (fabric available-host-count changes)
        rm -f "$CLUSTER_CACHE" "$FABRIC_CACHE"
    else
        echo -e "${RED}Failed to update GPU Memory Cluster:${NC}"
        echo "$result"
        return 1
    fi
}

#--------------------------------------------------------------------------------
# Update ALL GPU Memory Clusters with a selected Instance Configuration
#--------------------------------------------------------------------------------
update_all_clusters_instance_config() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    
    echo ""
    echo -e "${BOLD}${BLUE}═══ Update All GPU Memory Clusters - Instance Configuration ═══${NC}"
    echo ""
    
    # Refresh caches to get latest data
    echo -e "${YELLOW}Refreshing data from OCI...${NC}"
    rm -f "$FABRIC_CACHE" "$CLUSTER_CACHE" "$INSTANCE_CONFIG_CACHE" "$COMPUTE_CLUSTER_CACHE"
    fetch_gpu_fabrics
    fetch_gpu_clusters
    fetch_instance_configurations
    fetch_compute_clusters
    
    # Rebuild index maps
    display_gpu_management_menu > /dev/null 2>&1
    
    echo -e "${GREEN}✓ Data refreshed${NC}"
    echo ""
    
    # Check if any instance configurations exist
    if [[ ${#IC_INDEX_MAP[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No Instance Configurations available${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return 0
    fi
    
    # Check if any clusters exist
    if [[ ${#CLUSTER_INDEX_MAP[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No GPU Memory Clusters available to update${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return 0
    fi
    
    # Display Instance Configurations
    echo -e "${WHITE}Available Instance Configurations:${NC}"
    echo ""
    printf "${BOLD}%-6s %-60s %-90s${NC}\n" \
        "ID" "Instance Configuration Name" "OCID"
    print_separator 160
    
    # Sort and display instance configs
    local ic_output_temp
    ic_output_temp=$(mktemp)
    
    local iid
    for iid in "${!IC_INDEX_MAP[@]}"; do
        local ic_ocid="${IC_INDEX_MAP[$iid]}"
        [[ -z "$ic_ocid" ]] && continue
        
        local ic_line ic_name
        ic_line=$(grep "^${ic_ocid}|" "$INSTANCE_CONFIG_CACHE" 2>/dev/null | head -1)
        if [[ -n "$ic_line" ]]; then
            IFS='|' read -r _ ic_name <<< "$ic_line"
        else
            ic_name="N/A"
        fi
        
        local iid_num="${iid#i}"
        echo "${iid_num}|${iid}|${ic_name}|${ic_ocid}" >> "$ic_output_temp"
    done
    
    sort -t'|' -k1 -n "$ic_output_temp" | while IFS='|' read -r _ iid ic_name ic_ocid; do
        printf "${YELLOW}%-6s${NC} ${GREEN}%-60s${NC} ${GRAY}%-90s${NC}\n" \
            "$iid" "$ic_name" "$ic_ocid"
    done
    
    rm -f "$ic_output_temp"
    echo ""
    
    # Select Instance Configuration
    echo -n -e "${CYAN}Select Instance Configuration to apply to ALL clusters (i#) or 'cancel': ${NC}"
    local ic_input
    read -r ic_input
    
    # Check for cancel
    if [[ "$ic_input" == "cancel" || "$ic_input" == "c" || -z "$ic_input" ]]; then
        echo -e "${YELLOW}Update cancelled${NC}"
        return 0
    fi
    
    local selected_ic_ocid="${IC_INDEX_MAP[$ic_input]:-}"
    if [[ -z "$selected_ic_ocid" ]]; then
        echo -e "${RED}Invalid instance configuration selection: $ic_input${NC}"
        return 1
    fi
    
    # Get selected IC name
    local selected_ic_name
    selected_ic_name=$(get_instance_config_name "$selected_ic_ocid")
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ GPU Memory Clusters to Update ═══${NC}"
    echo ""
    
    # Collect clusters to update (only ACTIVE, UPDATING, SCALING states that don't already have the selected IC)
    local clusters_to_update=()
    local cluster_names=()
    local cluster_current_ics=()
    local skipped_count=0
    
    for gid in "${!CLUSTER_INDEX_MAP[@]}"; do
        local cluster_ocid="${CLUSTER_INDEX_MAP[$gid]}"
        [[ -z "$cluster_ocid" ]] && continue
        
        # Get cluster info from cache
        local cluster_line
        cluster_line=$(grep "^${cluster_ocid}|" "$CLUSTER_CACHE" 2>/dev/null | head -1)
        
        if [[ -n "$cluster_line" ]]; then
            local c_name c_state c_fabric_suffix c_ic_id c_size
            IFS='|' read -r _ c_name c_state c_fabric_suffix c_ic_id _ c_size <<< "$cluster_line"
            
            # Only include active-ish clusters
            if [[ "$c_state" == "ACTIVE" || "$c_state" == "UPDATING" || "$c_state" == "SCALING" ]]; then
                # Skip if already has the selected instance configuration
                if [[ "$c_ic_id" == "$selected_ic_ocid" ]]; then
                    ((skipped_count++))
                    continue
                fi
                
                clusters_to_update+=("$cluster_ocid")
                cluster_names+=("$c_name")
                
                # Get current IC name
                local current_ic_name="N/A"
                if [[ -n "$c_ic_id" && "$c_ic_id" != "N/A" ]]; then
                    current_ic_name=$(get_instance_config_name "$c_ic_id")
                fi
                cluster_current_ics+=("$current_ic_name")
            fi
        fi
    done
    
    # Show skipped count if any
    if [[ $skipped_count -gt 0 ]]; then
        echo -e "${GREEN}Skipped ${skipped_count} cluster(s) already using ${selected_ic_name}${NC}"
        echo ""
    fi
    
    if [[ ${#clusters_to_update[@]} -eq 0 ]]; then
        echo -e "${GREEN}All active GPU Memory Clusters already have the selected Instance Configuration${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return 0
    fi
    
    # Display clusters that will be updated
    printf "${BOLD}%-40s %-50s${NC}\n" "Cluster Name" "Current Instance Config"
    print_separator 95
    
    for i in "${!clusters_to_update[@]}"; do
        printf "%-40s ${GRAY}%-50s${NC}\n" "${cluster_names[$i]}" "${cluster_current_ics[$i]}"
    done
    
    echo ""
    echo -e "${WHITE}Total clusters to update:${NC} ${CYAN}${#clusters_to_update[@]}${NC}"
    echo -e "${WHITE}New Instance Configuration:${NC} ${GREEN}$selected_ic_name${NC}"
    echo ""
    
    # Show commands that will be executed
    echo -e "${BOLD}${WHITE}Commands to execute:${NC}"
    echo ""
    for i in "${!clusters_to_update[@]}"; do
        local cluster_ocid="${clusters_to_update[$i]}"
        echo -e "${GRAY}oci compute compute-gpu-memory-cluster update \\
    --compute-gpu-memory-cluster-id \"$cluster_ocid\" \\
    --instance-configuration-id \"$selected_ic_ocid\"${NC}"
        echo ""
    done
    
    # Confirm
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║                    ⚠️  BULK UPDATE CONFIRMATION  ⚠️                              ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}This will update ${CYAN}${#clusters_to_update[@]}${NC}${WHITE} GPU Memory Cluster(s) to use:${NC}"
    echo -e "  ${GREEN}$selected_ic_name${NC}"
    echo -e "  ${GRAY}$selected_ic_ocid${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Type 'UPDATE ALL' to confirm: ${NC}"
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "UPDATE ALL" ]]; then
        echo -e "${YELLOW}Update cancelled${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${GREEN}Starting bulk update...${NC}"
    echo ""
    
    # Update each cluster
    local success_count=0
    local fail_count=0
    
    for i in "${!clusters_to_update[@]}"; do
        local cluster_ocid="${clusters_to_update[$i]}"
        local cluster_name="${cluster_names[$i]}"
        
        echo -n -e "  Updating ${CYAN}$cluster_name${NC}... "
        
        local result
        result=$(oci compute compute-gpu-memory-cluster update \
            --compute-gpu-memory-cluster-id "$cluster_ocid" \
            --instance-configuration-id "$selected_ic_ocid" \
            --output json 2>&1)
        local exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            echo -e "${GREEN}✓${NC}"
            ((success_count++))
        else
            echo -e "${RED}✗${NC}"
            echo -e "    ${RED}Error: $(echo "$result" | head -1)${NC}"
            ((fail_count++))
        fi
    done
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Update Summary ═══${NC}"
    echo -e "  ${GREEN}Successful:${NC} $success_count"
    echo -e "  ${RED}Failed:${NC}     $fail_count"
    echo ""
    
    # Invalidate caches
    rm -f "$CLUSTER_CACHE" "$FABRIC_CACHE"
    
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Delete a single Instance Configuration by OCID (called from view details)
#--------------------------------------------------------------------------------
delete_single_instance_configuration() {
    local ic_ocid="$1"
    local ic_name="$2"
    
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  WARNING: DELETE INSTANCE CONFIGURATION  ⚠️               ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}Instance Configuration:${NC} ${GREEN}$ic_name${NC}"
    echo -e "${WHITE}OCID:${NC}                   ${YELLOW}$ic_ocid${NC}"
    echo ""
    
    # Check if in use
    local clusters_using_ic=""
    if [[ -f "$CLUSTER_CACHE" ]]; then
        while IFS='|' read -r cluster_ocid cluster_name cluster_state _ cluster_ic_id _; do
            [[ "$cluster_ocid" =~ ^#.*$ ]] && continue
            [[ -z "$cluster_ocid" ]] && continue
            [[ "$cluster_state" == "DELETED" ]] && continue
            
            if [[ "$cluster_ic_id" == "$ic_ocid" ]]; then
                clusters_using_ic="${clusters_using_ic}${cluster_name} (${cluster_state})\n"
            fi
        done < "$CLUSTER_CACHE"
    fi
    
    if [[ -n "$clusters_using_ic" ]]; then
        echo -e "${RED}⚠️  WARNING: This instance configuration is used by:${NC}"
        echo -e "${YELLOW}$(echo -e "$clusters_using_ic")${NC}"
        echo ""
    fi
    
    echo -e "${RED}This action cannot be undone!${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm: ${NC}"
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Delete cancelled${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${YELLOW}Deleting Instance Configuration...${NC}"
    
    local result
    result=$(oci compute-management instance-configuration delete \
        --instance-configuration-id "$ic_ocid" \
        --force 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}✓ Instance Configuration deleted successfully${NC}"
        rm -f "$INSTANCE_CONFIG_CACHE"
    else
        echo -e "${RED}✗ Failed to delete:${NC}"
        echo "$result"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Delete Instance Configuration interactively
#--------------------------------------------------------------------------------
delete_instance_configuration_interactive() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    
    echo ""
    echo -e "${BOLD}${RED}═══ Delete Instance Configuration ═══${NC}"
    echo ""
    
    # Refresh caches to get latest data
    echo -e "${YELLOW}Refreshing data from OCI...${NC}"
    rm -f "$INSTANCE_CONFIG_CACHE" "$CLUSTER_CACHE"
    fetch_instance_configurations
    fetch_gpu_clusters
    
    # Rebuild index maps
    display_gpu_management_menu > /dev/null 2>&1
    
    echo -e "${GREEN}✓ Data refreshed${NC}"
    echo ""
    
    # Check if any instance configurations exist
    if [[ ${#IC_INDEX_MAP[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No Instance Configurations available to delete${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return 0
    fi
    
    # Display Instance Configurations
    echo -e "${WHITE}Available Instance Configurations:${NC}"
    echo ""
    printf "${BOLD}%-6s %-60s %-90s${NC}\n" \
        "ID" "Instance Configuration Name" "OCID"
    print_separator 160
    
    # Sort and display instance configs
    local ic_output_temp
    ic_output_temp=$(mktemp)
    
    local iid
    for iid in "${!IC_INDEX_MAP[@]}"; do
        local ic_ocid="${IC_INDEX_MAP[$iid]}"
        [[ -z "$ic_ocid" ]] && continue
        
        local ic_line ic_name
        ic_line=$(grep "^${ic_ocid}|" "$INSTANCE_CONFIG_CACHE" 2>/dev/null | head -1)
        if [[ -n "$ic_line" ]]; then
            IFS='|' read -r _ ic_name <<< "$ic_line"
        else
            ic_name="N/A"
        fi
        
        local iid_num="${iid#i}"
        echo "${iid_num}|${iid}|${ic_name}|${ic_ocid}" >> "$ic_output_temp"
    done
    
    sort -t'|' -k1 -n "$ic_output_temp" | while IFS='|' read -r _ iid ic_name ic_ocid; do
        printf "${YELLOW}%-6s${NC} ${GREEN}%-60s${NC} ${GRAY}%-90s${NC}\n" \
            "$iid" "$ic_name" "$ic_ocid"
    done
    
    rm -f "$ic_output_temp"
    echo ""
    
    # Select Instance Configuration to delete
    echo -n -e "${CYAN}Select Instance Configuration to delete (i#) or 'cancel': ${NC}"
    local ic_input
    read -r ic_input
    
    # Check for cancel
    if [[ "$ic_input" == "cancel" || "$ic_input" == "c" || -z "$ic_input" ]]; then
        echo -e "${YELLOW}Delete cancelled${NC}"
        return 0
    fi
    
    local ic_ocid="${IC_INDEX_MAP[$ic_input]:-}"
    if [[ -z "$ic_ocid" ]]; then
        echo -e "${RED}Invalid instance configuration selection: $ic_input${NC}"
        return 1
    fi
    
    # Get instance configuration details
    local ic_json ic_name ic_time_created
    ic_json=$(oci compute-management instance-configuration get \
        --instance-configuration-id "$ic_ocid" \
        --output json 2>/dev/null)
    
    if [[ -n "$ic_json" ]]; then
        ic_name=$(echo "$ic_json" | jq -r '.data["display-name"] // "N/A"')
        ic_time_created=$(echo "$ic_json" | jq -r '.data["time-created"] // "N/A"')
    else
        ic_name="Unknown"
        ic_time_created="Unknown"
    fi
    
    # Check if instance configuration is in use by any GPU memory clusters
    echo ""
    echo -e "${YELLOW}Checking if instance configuration is in use...${NC}"
    
    local clusters_using_ic=""
    if [[ -f "$CLUSTER_CACHE" ]]; then
        while IFS='|' read -r cluster_ocid cluster_name cluster_state _ cluster_ic_id _; do
            [[ "$cluster_ocid" =~ ^#.*$ ]] && continue
            [[ -z "$cluster_ocid" ]] && continue
            [[ "$cluster_state" == "DELETED" ]] && continue
            
            if [[ "$cluster_ic_id" == "$ic_ocid" ]]; then
                clusters_using_ic="${clusters_using_ic}${cluster_name} (${cluster_state})\n"
            fi
        done < "$CLUSTER_CACHE"
    fi
    
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    ⚠️  WARNING: DELETE INSTANCE CONFIGURATION  ⚠️               ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}Instance Configuration:${NC} ${GREEN}$ic_name${NC}"
    echo -e "${WHITE}OCID:${NC}                   ${YELLOW}$ic_ocid${NC}"
    echo -e "${WHITE}Created:${NC}                $ic_time_created"
    echo ""
    
    if [[ -n "$clusters_using_ic" ]]; then
        echo -e "${RED}⚠️  WARNING: This instance configuration is used by the following GPU Memory Clusters:${NC}"
        echo -e "${YELLOW}$(echo -e "$clusters_using_ic")${NC}"
        echo -e "${RED}Deleting this configuration may affect future cluster operations!${NC}"
        echo ""
    fi
    
    echo -e "${RED}This action cannot be undone!${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm deletion: ${NC}"
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Delete cancelled${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${YELLOW}Deleting Instance Configuration...${NC}"
    
    local result
    result=$(oci compute-management instance-configuration delete \
        --instance-configuration-id "$ic_ocid" \
        --force 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}✓ Instance Configuration deleted successfully${NC}"
        
        # Invalidate cache
        rm -f "$INSTANCE_CONFIG_CACHE"
        
        echo ""
        echo -e "Press Enter to continue..."
        read -r
    else
        echo -e "${RED}✗ Failed to delete Instance Configuration:${NC}"
        echo "$result"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return 1
    fi
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
    echo "  --details          Show full instance details including network, boot volume, block volumes"
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
    echo -e "${BOLD}GPU Management:${NC}"
    echo "  --manage            Interactive resource management mode"
    echo "                      - OKE Cluster environment view"
    echo "                      - Network resources (subnets, NSGs)"
    echo "                      - GPU Memory Fabrics & Clusters (create, update, view)"
    echo "                      - Compute Instances (view details, IPs, volumes)"
    echo ""
    echo -e "${BOLD}Setup & Maintenance:${NC}"
    echo "  --setup             Run initial setup to create/update variables.sh"
    echo "                      Auto-detects environment from IMDS and allows resource selection"
    echo "  --refresh           Clear all cached data to force fresh fetch from OCI"
    echo "                      Useful after infrastructure changes or stale data"
    echo ""
    echo -e "${BOLD}Interactive Features:${NC}"
    echo "  When listing GPU instances, if instances not in kubernetes (running in OCI but not in K8s)"
    echo "  are found, you will be prompted to select one to view its console history."
    echo "  This helps diagnose why an instance failed to join the Kubernetes cluster."
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                                                    # List all GPU instances with fabric info"
    echo "  $0 --refresh                                          # Clear cache and force fresh data"
    echo "  $0 --compartment-id ocid1.compartment.oc1..xxx        # Use different compartment"
    echo "  $0 --region us-ashburn-1                              # Use different region"
    echo "  $0 --list-cliques                                     # List all cliques with fabric details"
    echo "  $0 --cliques-summary                                  # Summary table of cliques with fabric"
    echo "  $0 --manage                                           # Interactive GPU fabric/cluster management"
    echo "  $0 --setup                                            # Run initial setup wizard"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx                 # Basic node info"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --labels        # Show labels"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --clique        # Show clique info + fabric"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --count-clique  # Show clique members + fabric"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --all           # Show everything"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --details       # Full details (network, volumes)"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --console-history  # View console history"
    echo "  $0 --list-cluster ocid1.xxx                           # List cluster instances + fabric"
}

#===============================================================================
# MAIN
#===============================================================================

#===============================================================================
# INITIAL SETUP FUNCTIONS
#===============================================================================

# IMDS v2 endpoint
readonly IMDS_BASE="http://169.254.169.254/opc/v2"
readonly IMDS_HEADER="Authorization: Bearer Oracle"

#--------------------------------------------------------------------------------
# Check if running on OCI instance with IMDS available
#--------------------------------------------------------------------------------
is_oci_instance() {
    curl -sS -H "$IMDS_HEADER" "${IMDS_BASE}/instance/" -o /dev/null 2>/dev/null
}

#--------------------------------------------------------------------------------
# Wait for IMDS to be available
#--------------------------------------------------------------------------------
wait_for_imds() {
    local timeout=60
    local elapsed=0
    
    echo -e "${YELLOW}Waiting for IMDS...${NC}"
    while true; do
        if curl -sS -H "$IMDS_HEADER" "${IMDS_BASE}/instance/" -o /dev/null 2>/dev/null; then
            echo -e "${GREEN}IMDS available${NC}"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        if [[ $elapsed -ge $timeout ]]; then
            echo -e "${RED}ERROR: Timeout waiting for IMDS${NC}" >&2
            return 1
        fi
    done
}

#--------------------------------------------------------------------------------
# Fetch instance metadata from IMDS
#--------------------------------------------------------------------------------
fetch_imds_metadata() {
    echo -e "${YELLOW}Fetching instance metadata...${NC}"
    
    local instance_json
    instance_json=$(curl -sH "$IMDS_HEADER" -L "${IMDS_BASE}/instance/" 2>/dev/null)
    
    if [[ -z "$instance_json" ]]; then
        echo -e "${RED}ERROR: Failed to fetch instance metadata${NC}" >&2
        return 1
    fi
    
    # Extract values
    SETUP_TENANCY_ID=$(echo "$instance_json" | jq -r '.tenantId // empty')
    SETUP_COMPARTMENT_ID=$(echo "$instance_json" | jq -r '.compartmentId // empty')
    SETUP_REGION=$(echo "$instance_json" | jq -r '.canonicalRegionName // empty')
    SETUP_AD=$(echo "$instance_json" | jq -r '.availabilityDomain // empty')
    
    if [[ -z "$SETUP_TENANCY_ID" || -z "$SETUP_COMPARTMENT_ID" || -z "$SETUP_REGION" ]]; then
        echo -e "${RED}ERROR: Missing required metadata fields${NC}" >&2
        return 1
    fi
    
    echo -e "${GREEN}Metadata fetched successfully${NC}"
    return 0
}

#--------------------------------------------------------------------------------
# Check OCI CLI with instance principal auth
#--------------------------------------------------------------------------------
check_oci_instance_principal() {
    if ! command -v oci &>/dev/null; then
        echo -e "${RED}ERROR: OCI CLI not found${NC}" >&2
        return 1
    fi
    
    if ! oci iam region list --auth instance_principal &>/dev/null; then
        echo -e "${RED}ERROR: Instance principal authentication failed${NC}" >&2
        return 1
    fi
    
    echo -e "${GREEN}OCI CLI available with instance principal auth${NC}"
    return 0
}

#--------------------------------------------------------------------------------
# Select from list helper for initial setup
#--------------------------------------------------------------------------------
setup_select_from_list() {
    local prompt="$1"
    local -n items_ref=$2
    local -n result_ref=$3
    local allow_skip="${4:-false}"
    
    if [[ ${#items_ref[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No items available${NC}"
        result_ref=""
        return 1
    fi
    
    declare -A local_map
    local idx=1
    for item in "${items_ref[@]}"; do
        local name=$(echo "$item" | cut -d'|' -f1)
        local id=$(echo "$item" | cut -d'|' -f2)
        local extra=$(echo "$item" | cut -d'|' -f3-)
        
        if [[ -n "$extra" ]]; then
            printf "${YELLOW}%3d${NC}) ${CYAN}%-50s${NC} ${GRAY}%s${NC}\n" "$idx" "$name" "$extra"
        else
            printf "${YELLOW}%3d${NC}) ${CYAN}%-50s${NC}\n" "$idx" "$name"
        fi
        
        local_map[$idx]="$id"
        ((idx++))
    done
    
    if [[ "$allow_skip" == "true" ]]; then
        echo -e "${GRAY}  0) Skip / Enter manually later${NC}"
    fi
    
    echo ""
    while true; do
        echo -n -e "${WHITE}$prompt ${NC}"
        read -r selection
        
        if [[ "$allow_skip" == "true" && "$selection" == "0" ]]; then
            result_ref=""
            return 0
        fi
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ -n "${local_map[$selection]:-}" ]]; then
            result_ref="${local_map[$selection]}"
            return 0
        fi
        
        echo -e "${RED}Invalid selection. Please try again.${NC}"
    done
}

#--------------------------------------------------------------------------------
# Run initial setup to create variables.sh
#--------------------------------------------------------------------------------
run_initial_setup() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${WHITE}  Initial Setup - Creating variables.sh${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Check if on OCI instance
    if ! is_oci_instance; then
        echo -e "${RED}ERROR: Not running on an OCI instance or IMDS not available${NC}"
        echo -e "${YELLOW}Please create variables.sh manually with:${NC}"
        echo -e "  REGION=\"your-region\""
        echo -e "  TENANCY_ID=\"ocid1.tenancy...\""
        echo -e "  COMPARTMENT_ID=\"ocid1.compartment...\""
        return 1
    fi
    
    wait_for_imds || return 1
    fetch_imds_metadata || return 1
    check_oci_instance_principal || return 1
    
    echo ""
    echo -e "${WHITE}Base environment detected:${NC}"
    echo -e "  Region: ${CYAN}$SETUP_REGION${NC}"
    echo -e "  Compartment: ${CYAN}${SETUP_COMPARTMENT_ID:0:50}...${NC}"
    echo -e "  AD: ${CYAN}$SETUP_AD${NC}"
    
    # Initialize variables
    local oke_cluster_id="" oke_cluster_name="" vcn_id=""
    local worker_subnet_id="" worker_nsg_id="" pod_subnet_id="" pod_nsg_id=""
    local cc_id="" ic_id="" gpu_fabric_id="" image_id=""
    
    # Select OKE Cluster
    echo ""
    echo -e "${BOLD}${CYAN}─── OKE Clusters ───${NC}"
    echo ""
    echo -e "${YELLOW}Fetching OKE clusters...${NC}"
    
    local clusters_json
    clusters_json=$(oci ce cluster list \
        --compartment-id "$SETUP_COMPARTMENT_ID" \
        --auth instance_principal \
        --lifecycle-state ACTIVE \
        --all \
        --output json 2>/dev/null)
    
    local -a clusters=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && clusters+=("$line")
    done < <(echo "$clusters_json" | jq -r '.data[] | "\(.name)|\(.id)|\(.["kubernetes-version"])"' 2>/dev/null)
    
    if [[ ${#clusters[@]} -eq 1 ]]; then
        oke_cluster_name=$(echo "${clusters[0]}" | cut -d'|' -f1)
        oke_cluster_id=$(echo "${clusters[0]}" | cut -d'|' -f2)
        local k8s_version=$(echo "${clusters[0]}" | cut -d'|' -f3)
        
        echo -e "${GREEN}Auto-selected (only cluster):${NC}"
        echo -e "  ${CYAN}Name:${NC}    ${WHITE}$oke_cluster_name${NC}"
        echo -e "  ${CYAN}Version:${NC} ${WHITE}$k8s_version${NC}"
        echo ""
        echo -n -e "${CYAN}Use this cluster? (y/n): ${NC}"
        read -r confirm
        [[ ! "$confirm" =~ ^[Yy]$ && -n "$confirm" ]] && oke_cluster_id=""
    elif [[ ${#clusters[@]} -gt 1 ]]; then
        setup_select_from_list "Select OKE Cluster:" clusters oke_cluster_id true
        [[ -n "$oke_cluster_id" ]] && oke_cluster_name=$(echo "$clusters_json" | jq -r --arg id "$oke_cluster_id" '.data[] | select(.id == $id) | .name')
    fi
    
    # Get VCN from cluster
    if [[ -n "$oke_cluster_id" ]]; then
        vcn_id=$(oci ce cluster get --cluster-id "$oke_cluster_id" --auth instance_principal --query 'data."vcn-id"' --raw-output 2>/dev/null)
        echo -e "${GREEN}Selected: ${WHITE}$oke_cluster_name${NC}"
    fi
    
    # Auto-detect network resources if VCN available
    if [[ -n "$vcn_id" ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}─── Network Configuration ───${NC}"
        echo ""
        echo -e "${YELLOW}Auto-detecting network resources...${NC}"
        
        local subnets_json nsgs_json
        subnets_json=$(oci network subnet list --compartment-id "$SETUP_COMPARTMENT_ID" --vcn-id "$vcn_id" --auth instance_principal --all --output json 2>/dev/null)
        nsgs_json=$(oci network nsg list --compartment-id "$SETUP_COMPARTMENT_ID" --vcn-id "$vcn_id" --auth instance_principal --all --output json 2>/dev/null)
        
        # Auto-detect by name patterns - get both ID and name
        local worker_subnet_name="" pod_subnet_name="" worker_nsg_name="" pod_nsg_name=""
        
        worker_subnet_id=$(echo "$subnets_json" | jq -r '.data[] | select(.["display-name"] | test("worker"; "i")) | .id' 2>/dev/null | head -1)
        [[ -n "$worker_subnet_id" ]] && worker_subnet_name=$(echo "$subnets_json" | jq -r --arg id "$worker_subnet_id" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        
        pod_subnet_id=$(echo "$subnets_json" | jq -r '.data[] | select(.["display-name"] | test("pod"; "i")) | .id' 2>/dev/null | head -1)
        [[ -n "$pod_subnet_id" ]] && pod_subnet_name=$(echo "$subnets_json" | jq -r --arg id "$pod_subnet_id" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        
        worker_nsg_id=$(echo "$nsgs_json" | jq -r '.data[] | select(.["display-name"] | test("worker"; "i")) | .id' 2>/dev/null | head -1)
        [[ -n "$worker_nsg_id" ]] && worker_nsg_name=$(echo "$nsgs_json" | jq -r --arg id "$worker_nsg_id" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        
        pod_nsg_id=$(echo "$nsgs_json" | jq -r '.data[] | select(.["display-name"] | test("pod"; "i")) | .id' 2>/dev/null | head -1)
        [[ -n "$pod_nsg_id" ]] && pod_nsg_name=$(echo "$nsgs_json" | jq -r --arg id "$pod_nsg_id" '.data[] | select(.id == $id) | .["display-name"]' 2>/dev/null)
        
        # Display detected with names
        echo ""
        echo -e "${BOLD}${WHITE}Auto-detected Network Configuration:${NC}"
        [[ -n "$worker_subnet_id" ]] && echo -e "  ${GREEN}✓${NC} Worker Subnet: ${WHITE}$worker_subnet_name${NC}" || echo -e "  ${YELLOW}○${NC} Worker Subnet: ${GRAY}(not detected)${NC}"
        [[ -n "$worker_nsg_id" ]] && echo -e "  ${GREEN}✓${NC} Worker NSG:    ${WHITE}$worker_nsg_name${NC}" || echo -e "  ${YELLOW}○${NC} Worker NSG:    ${GRAY}(not detected)${NC}"
        [[ -n "$pod_subnet_id" ]] && echo -e "  ${GREEN}✓${NC} Pod Subnet:    ${WHITE}$pod_subnet_name${NC}" || echo -e "  ${YELLOW}○${NC} Pod Subnet:    ${GRAY}(not detected)${NC}"
        [[ -n "$pod_nsg_id" ]] && echo -e "  ${GREEN}✓${NC} Pod NSG:       ${WHITE}$pod_nsg_name${NC}" || echo -e "  ${YELLOW}○${NC} Pod NSG:       ${GRAY}(not detected)${NC}"
        
        echo ""
        echo -n -e "${CYAN}Accept detected network settings? (y/n): ${NC}"
        read -r net_confirm
        if [[ "$net_confirm" =~ ^[Nn]$ ]]; then
            worker_subnet_id="" worker_nsg_id="" pod_subnet_id="" pod_nsg_id=""
        fi
    fi
    
    # Select Compute Cluster
    echo ""
    echo -e "${BOLD}${CYAN}─── Compute Cluster ───${NC}"
    echo ""
    echo -e "${YELLOW}Fetching compute clusters...${NC}"
    
    local cc_json
    cc_json=$(oci compute compute-cluster list \
        --compartment-id "$SETUP_COMPARTMENT_ID" \
        --availability-domain "$SETUP_AD" \
        --auth instance_principal \
        --all \
        --output json 2>/dev/null)
    
    local -a compute_clusters=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && compute_clusters+=("$line")
    done < <(echo "$cc_json" | jq -r '.data.items[] | "\(.["display-name"])|\(.id)"' 2>/dev/null)
    
    if [[ ${#compute_clusters[@]} -gt 0 ]]; then
        setup_select_from_list "Select Compute Cluster:" compute_clusters cc_id true
    else
        echo -e "${YELLOW}No compute clusters found${NC}"
    fi
    
    # Select Instance Configuration
    echo ""
    echo -e "${BOLD}${CYAN}─── Instance Configuration ───${NC}"
    echo ""
    echo -e "${YELLOW}Fetching instance configurations...${NC}"
    
    local ic_json
    ic_json=$(oci compute-management instance-configuration list \
        --compartment-id "$SETUP_COMPARTMENT_ID" \
        --auth instance_principal \
        --all \
        --output json 2>/dev/null)
    
    local -a instance_configs=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && instance_configs+=("$line")
    done < <(echo "$ic_json" | jq -r '.data[] | "\(.["display-name"])|\(.id)"' 2>/dev/null)
    
    if [[ ${#instance_configs[@]} -gt 0 ]]; then
        setup_select_from_list "Select Instance Configuration:" instance_configs ic_id true
    else
        echo -e "${YELLOW}No instance configurations found${NC}"
    fi
    
    # Select GPU Memory Fabric (only if fabrics exist in region)
    local fabric_json
    fabric_json=$(oci compute compute-gpu-memory-fabric list \
        --compartment-id "$SETUP_TENANCY_ID" \
        --auth instance_principal \
        --all \
        --output json 2>/dev/null)
    
    local -a fabrics=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && fabrics+=("$line")
    done < <(echo "$fabric_json" | jq -r --arg region "$SETUP_REGION" '.data.items[] | select(.id | contains($region)) | "\(.["display-name"])|\(.id)|\(.["lifecycle-state"]) avail=\(.["available-host-count"])"' 2>/dev/null)
    
    if [[ ${#fabrics[@]} -gt 0 ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}─── GPU Memory Fabric ───${NC}"
        echo ""
        setup_select_from_list "Select GPU Memory Fabric:" fabrics gpu_fabric_id true
    fi
    
    # Select Custom Image
    echo ""
    echo -e "${BOLD}${CYAN}─── Custom Image ───${NC}"
    echo ""
    echo -e "${YELLOW}Fetching custom images...${NC}"
    
    local images_json
    images_json=$(oci compute image list \
        --compartment-id "$SETUP_COMPARTMENT_ID" \
        --auth instance_principal \
        --all \
        --lifecycle-state AVAILABLE \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --output json 2>/dev/null)
    
    local -a images=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && images+=("$line")
    done < <(echo "$images_json" | jq -r --arg comp "$SETUP_COMPARTMENT_ID" '.data[] | select(.["compartment-id"] == $comp) | "\(.["display-name"][:50])|\(.id)|\(.["time-created"][:10])"' 2>/dev/null)
    
    if [[ ${#images[@]} -gt 0 ]]; then
        setup_select_from_list "Select Image:" images image_id true
    else
        echo -e "${YELLOW}No custom images found${NC}"
    fi
    
    # Display summary
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${WHITE}  Configuration Summary${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}${WHITE}Base Environment:${NC}"
    echo -e "  ${CYAN}Region:${NC}         $SETUP_REGION"
    echo -e "  ${CYAN}Tenancy:${NC}        $SETUP_TENANCY_ID"
    echo -e "  ${CYAN}Compartment:${NC}    $SETUP_COMPARTMENT_ID"
    echo -e "  ${CYAN}AD:${NC}             $SETUP_AD"
    echo ""
    echo -e "${BOLD}${WHITE}Selected Resources:${NC}"
    [[ -n "$oke_cluster_id" ]] && echo -e "  ${GREEN}✓${NC} OKE Cluster: $oke_cluster_name" || echo -e "  ${YELLOW}○${NC} OKE Cluster: (not set)"
    [[ -n "$worker_subnet_id" ]] && echo -e "  ${GREEN}✓${NC} Worker Subnet" || echo -e "  ${YELLOW}○${NC} Worker Subnet: (not set)"
    [[ -n "$worker_nsg_id" ]] && echo -e "  ${GREEN}✓${NC} Worker NSG" || echo -e "  ${YELLOW}○${NC} Worker NSG: (not set)"
    [[ -n "$pod_subnet_id" ]] && echo -e "  ${GREEN}✓${NC} Pod Subnet" || echo -e "  ${YELLOW}○${NC} Pod Subnet: (not set)"
    [[ -n "$pod_nsg_id" ]] && echo -e "  ${GREEN}✓${NC} Pod NSG" || echo -e "  ${YELLOW}○${NC} Pod NSG: (not set)"
    [[ -n "$cc_id" ]] && echo -e "  ${GREEN}✓${NC} Compute Cluster" || echo -e "  ${YELLOW}○${NC} Compute Cluster: (not set)"
    [[ -n "$ic_id" ]] && echo -e "  ${GREEN}✓${NC} Instance Config" || echo -e "  ${YELLOW}○${NC} Instance Config: (not set)"
    [[ -n "$gpu_fabric_id" ]] && echo -e "  ${GREEN}✓${NC} GPU Fabric" || echo -e "  ${YELLOW}○${NC} GPU Fabric: (not set)"
    [[ -n "$image_id" ]] && echo -e "  ${GREEN}✓${NC} Image" || echo -e "  ${YELLOW}○${NC} Image: (not set)"
    
    # Save configuration
    echo ""
    echo -n -e "${CYAN}Save configuration to variables.sh? (y/n): ${NC}"
    read -r save_choice
    
    if [[ ! "$save_choice" =~ ^[Yy]$ && -n "$save_choice" ]]; then
        echo -e "${YELLOW}Configuration not saved${NC}"
        return 1
    fi
    
    local output_file="./variables.sh"
    cat > "$output_file" <<EOF
#!/bin/bash
#===============================================================================
# OCI Environment Configuration
# Auto-generated on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
#===============================================================================

# Tenancy Variables
REGION="$SETUP_REGION"
TENANCY_ID="$SETUP_TENANCY_ID"

# Compartment where the OKE Cluster and worker nodes reside
COMPARTMENT_ID="$SETUP_COMPARTMENT_ID"

# OCI AD name for the region
AD="$SETUP_AD"

# OKE Cluster OCID (used by --manage to determine which cluster to display)
OKE_CLUSTER_ID="$oke_cluster_id"
CLUSTER_NAME="$oke_cluster_name"

# OKE Worker and POD Subnets
WORKER_SUBNET_ID="$worker_subnet_id"
WORKER_SUBNET_NSG_ID="$worker_nsg_id"
POD_SUBNET_ID="$pod_subnet_id"
POD_SUBNET_NSG_ID="$pod_nsg_id"

# Image for OKE Worker Nodes
IMAGE_ID="$image_id"

# Shape for GPU nodes
SHAPE_NAME="BM.GPU.GB200-v3.4"

# Compute Cluster OCID
CC_ID="$cc_id"

# Instance Configuration OCID
IC_ID="$ic_id"

# GPU Memory Fabric ID
GPU_MEMORY_FABRIC_ID="$gpu_fabric_id"

# GPU Memory Cluster size
GPU_MEMORY_CLUSTER_SIZE=18

# Instance filter for listing: "gpu", "non-gpu", or "all"
# gpu     = Only show GPU instances (BM.GPU.*)
# non-gpu = Only show non-GPU instances
# all     = Show all instances
INSTANCE_FILTER="gpu"
EOF

    chmod +x "$output_file"
    echo -e "${GREEN}Configuration saved to: ${WHITE}$output_file${NC}"
    echo ""
    
    return 0
}

#--------------------------------------------------------------------------------
# Check if variables.sh has required values populated
#--------------------------------------------------------------------------------
check_variables_populated() {
    # Check minimum required variables
    if [[ -z "${COMPARTMENT_ID:-}" || -z "${REGION:-}" || -z "${TENANCY_ID:-}" ]]; then
        return 1
    fi
    return 0
}

#===============================================================================
# MAIN FUNCTION
#===============================================================================

main() {
    # Check dependencies first
    check_dependencies || exit 1
    
    # Source variables file
    local variables_found=false
    if [[ -f "$SCRIPT_DIR/variables.sh" ]]; then
        # shellcheck source=/dev/null
        source "$SCRIPT_DIR/variables.sh"
        variables_found=true
    elif [[ -f "./variables.sh" ]]; then
        # shellcheck source=/dev/null
        source "./variables.sh"
        variables_found=true
    fi
    
    # Check if variables.sh exists and has required values
    if [[ "$variables_found" == "false" ]]; then
        echo -e "${YELLOW}variables.sh not found.${NC}"
        echo ""
        echo -n -e "${CYAN}Would you like to run initial setup? (y/n): ${NC}"
        read -r setup_choice
        
        if [[ "$setup_choice" =~ ^[Yy]$ || -z "$setup_choice" ]]; then
            if run_initial_setup; then
                # Re-source the newly created file
                source "./variables.sh"
            else
                echo -e "${RED}Setup failed or cancelled. Exiting.${NC}"
                exit 1
            fi
        else
            echo -e "${YELLOW}Please create variables.sh with COMPARTMENT_ID, REGION, and TENANCY_ID.${NC}"
            exit 1
        fi
    elif ! check_variables_populated; then
        echo -e "${YELLOW}variables.sh exists but required values (COMPARTMENT_ID, REGION, TENANCY_ID) are not set.${NC}"
        echo ""
        echo -n -e "${CYAN}Would you like to run setup to populate values? (y/n): ${NC}"
        read -r setup_choice
        
        if [[ "$setup_choice" =~ ^[Yy]$ || -z "$setup_choice" ]]; then
            if run_initial_setup; then
                # Re-source the file
                source "./variables.sh"
            else
                echo -e "${RED}Setup failed or cancelled.${NC}"
                exit 1
            fi
        fi
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
        --setup)
            run_initial_setup
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
        --manage)
            interactive_management_main_menu
            ;;
        --refresh)
            refresh_all_caches
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
            local show_instance_details="false"
            
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
                    --details)
                        show_instance_details="true"
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
            elif [[ "$show_instance_details" == "true" ]]; then
                display_instance_details "$instance_id"
            else
                get_node_info "$instance_id" "$show_labels" "$show_clique" "$count_clique"
            fi
            ;;
    esac
}

# Run main function
main "$@"