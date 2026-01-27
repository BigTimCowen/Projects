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

# Debug mode (set via --debug command line flag)
DEBUG_MODE=false

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
readonly BOOT_VOLUME_CACHE="${CACHE_DIR}/boot_volumes.txt"
readonly IMAGE_CACHE="${CACHE_DIR}/images.txt"

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

# Action log file for tracking changes (create, update, delete operations)
ACTION_LOG_FILE="${ACTION_LOG_FILE:-./k8s_nodes_actions_$(date +%Y%m%d).log}"

# Log action to file and display command on screen
# Args: $1 = action type (e.g., REBOOT, TERMINATE), $2 = command being executed
log_action() {
    local action_type="$1"
    local command="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Display command on screen
    echo ""
    echo -e "${YELLOW}Executing:${NC}"
    echo -e "${GRAY}$command${NC}"
    echo ""
    
    # Log to file
    {
        echo "========================================"
        echo "Timestamp: $timestamp"
        echo "Action: $action_type"
        echo "Command: $command"
        echo "========================================"
        echo ""
    } >> "$ACTION_LOG_FILE" 2>/dev/null
}

# Log action result to file
# Args: $1 = result (SUCCESS/FAILED), $2 = optional details
log_action_result() {
    local result="$1"
    local details="${2:-}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    {
        echo "Result: $result"
        [[ -n "$details" ]] && echo "Details: $details"
        echo "Completed: $timestamp"
        echo ""
    } >> "$ACTION_LOG_FILE" 2>/dev/null
}

# Check if a value is a valid OCID (not empty, not N/A, not null)
# Args: $1 = value to check
# Returns: 0 if valid, 1 if invalid
is_valid_ocid() {
    local val="$1"
    [[ -n "$val" && "$val" != "N/A" && "$val" != "null" ]]
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
    
    # Write cache header and data (now includes time-created)
    {
        echo "# Instance Configurations"
        echo "# Format: InstanceConfigOCID|DisplayName|TimeCreated"
        jq -r '.data[]? | "\(.id)|\(.["display-name"] // "N/A")|\(.["time-created"] // "N/A")"' "$raw_json" 2>/dev/null
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

# Extract and display user-data (cloud-init) from an instance configuration
# Args: $1 = instance configuration OCID
get_instance_config_user_data() {
    local ic_ocid="$1"
    
    if [[ -z "$ic_ocid" ]]; then
        log_error "Instance configuration OCID required"
        return 1
    fi
    
    # Validate OCID format
    if [[ ! "$ic_ocid" =~ ^ocid1\.instanceconfiguration\. ]]; then
        log_error "Invalid instance configuration OCID format: $ic_ocid"
        echo "Expected format: ocid1.instanceconfiguration.oc1.<region>.<unique-id>" >&2
        return 1
    fi
    
    log_info "Fetching instance configuration..." >&2
    
    local ic_json
    ic_json=$(oci compute-management instance-configuration get \
        --instance-configuration-id "$ic_ocid" \
        --output json 2>/dev/null)
    
    if [[ -z "$ic_json" ]] || ! echo "$ic_json" | jq -e '.data' > /dev/null 2>&1; then
        log_error "Failed to fetch instance configuration: $ic_ocid"
        return 1
    fi
    
    local ic_name
    ic_name=$(echo "$ic_json" | jq -r '.data["display-name"] // "N/A"')
    
    # Extract user_data (base64 encoded)
    local user_data_b64
    user_data_b64=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["metadata"]["user_data"] // empty' 2>/dev/null)
    
    if [[ -z "$user_data_b64" ]]; then
        echo "# No user-data found in instance configuration: $ic_name" >&2
        echo "# OCID: $ic_ocid" >&2
        return 0
    fi
    
    # Output header as comments (to stderr so stdout is just the yaml)
    echo "# Instance Configuration: $ic_name" >&2
    echo "# OCID: $ic_ocid" >&2
    echo "# Decoded cloud-init user-data:" >&2
    echo "#" >&2
    
    # Decode and output to stdout (handles gzip compressed data)
    decode_user_data "$user_data_b64"
    
    return 0
}

#--------------------------------------------------------------------------------
# Decode base64 user_data, handling gzip compression
# Args: $1 = base64 encoded user_data
# Output: decoded (and decompressed if gzip) data to stdout
#--------------------------------------------------------------------------------
decode_user_data() {
    local user_data_b64="$1"
    
    [[ -z "$user_data_b64" ]] && return 1
    
    # Decode to temp file
    local tmp_decoded
    tmp_decoded=$(mktemp)
    echo "$user_data_b64" | base64 -d > "$tmp_decoded" 2>/dev/null
    
    # Check if gzip compressed (magic bytes: 1f 8b)
    local magic_bytes
    magic_bytes=$(xxd -l 2 -p "$tmp_decoded" 2>/dev/null)
    
    if [[ "$magic_bytes" == "1f8b" ]]; then
        # Gzip compressed - decompress
        gunzip -c "$tmp_decoded" 2>/dev/null
    else
        # Plain text
        cat "$tmp_decoded"
    fi
    
    rm -f "$tmp_decoded"
    return 0
}

#--------------------------------------------------------------------------------
# Decode base64 user_data to file, handling gzip compression
# Args: $1 = base64 encoded user_data, $2 = output filename
# Returns: 0 on success, 1 on failure
#--------------------------------------------------------------------------------
decode_user_data_to_file() {
    local user_data_b64="$1"
    local output_file="$2"
    
    [[ -z "$user_data_b64" || -z "$output_file" ]] && return 1
    
    # Decode to temp file
    local tmp_decoded
    tmp_decoded=$(mktemp)
    echo "$user_data_b64" | base64 -d > "$tmp_decoded" 2>/dev/null
    
    # Check if gzip compressed (magic bytes: 1f 8b)
    local magic_bytes
    magic_bytes=$(xxd -l 2 -p "$tmp_decoded" 2>/dev/null)
    
    local result=0
    if [[ "$magic_bytes" == "1f8b" ]]; then
        # Gzip compressed - decompress
        if gunzip -c "$tmp_decoded" > "$output_file" 2>/dev/null; then
            result=0
        else
            result=1
        fi
    else
        # Plain text
        if cp "$tmp_decoded" "$output_file" 2>/dev/null; then
            result=0
        else
            result=1
        fi
    fi
    
    rm -f "$tmp_decoded"
    return $result
}

#--------------------------------------------------------------------------------
# Check if user_data is gzip compressed
# Args: $1 = base64 encoded user_data
# Returns: 0 if gzip compressed, 1 if not
#--------------------------------------------------------------------------------
is_user_data_gzip() {
    local user_data_b64="$1"
    
    [[ -z "$user_data_b64" ]] && return 1
    
    # Decode to temp file and check magic bytes
    local tmp_decoded
    tmp_decoded=$(mktemp)
    echo "$user_data_b64" | base64 -d > "$tmp_decoded" 2>/dev/null
    
    local magic_bytes
    magic_bytes=$(xxd -l 2 -p "$tmp_decoded" 2>/dev/null)
    
    rm -f "$tmp_decoded"
    
    [[ "$magic_bytes" == "1f8b" ]]
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
        echo "# Format: ComputeClusterOCID|DisplayName|AvailabilityDomain|LifecycleState"
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
            
            # OCI returns .data.items[] for paginated results
            jq -r '(.data.items // .data // [])[] | "\(.id)|\(.["display-name"] // "N/A")|\(.["availability-domain"] // "N/A")|\(.["lifecycle-state"] // "UNKNOWN")"' "$raw_json" >> "$COMPUTE_CLUSTER_CACHE" 2>/dev/null
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
    if is_valid_ocid "$cluster_ocid"; then
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
    if is_valid_ocid "$vcn_ocid"; then
        vcn_name=$(oci network vcn get --vcn-id "$vcn_ocid" --query 'data."display-name"' --raw-output 2>/dev/null) || vcn_name="N/A"
    fi
    
    # Get subnet and NSG info
    local worker_subnet_name="N/A" worker_subnet_ocid="N/A"
    local worker_nsg_name="N/A" worker_nsg_ocid="N/A"
    local pod_subnet_name="N/A" pod_subnet_ocid="N/A"
    local pod_nsg_name="N/A" pod_nsg_ocid="N/A"
    
    if is_valid_ocid "$vcn_ocid"; then
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
        echo "# Format: SUBNET|NAME|CIDR|ACCESS|STATE|OCID|RT_OCID|SL_IDS|DNS_LABEL"
        echo "# Format: NSG|NAME||STATE|OCID"
        
        # Process subnets (include route-table-id, security-list-ids, and dns-label)
        echo "$subnet_json" | jq -r '.data[] | "SUBNET|\(."display-name" // "N/A")|\(."cidr-block" // "N/A")|\(if ."prohibit-public-ip-on-vnic" then "Private" else "Public" end)|\(."lifecycle-state" // "N/A")|\(.id // "N/A")|\(."route-table-id" // "N/A")|\((."security-list-ids" // []) | join(","))|\(."dns-label" // "")"' 2>/dev/null
        
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

# Get security list name by ID (SL_CACHE format: SL_ID|VCN_ID|DISPLAY_NAME|STATE|INGRESS_COUNT|EGRESS_COUNT)
get_security_list_name() {
    local sl_id="$1"
    
    [[ ! -f "$SL_CACHE" ]] && { echo ""; return; }
    [[ -z "$sl_id" || "$sl_id" == "N/A" ]] && { echo ""; return; }
    
    local name
    name=$(grep "^${sl_id}|" "$SL_CACHE" 2>/dev/null | head -1 | cut -d'|' -f3)
    echo "${name:-}"
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
    
    # Read subnets (now with route-table-id, security-list-ids, and dns-label)
    while IFS='|' read -r type name cidr access state ocid rt_ocid sl_ids dns_label; do
        [[ "$type" != "SUBNET" ]] && continue
        local shortname
        shortname=$(get_shortname_match "$name")
        if [[ -n "$shortname" ]]; then
            subnets_by_shortname[$shortname]="${name}|${cidr}|${access}|${ocid}|${rt_ocid}|${sl_ids}|${dns_label}"
            subnet_shortnames+=("$shortname")
        else
            unmatched_subnets+=("${name}|${cidr}|${access}|${ocid}|${rt_ocid}|${sl_ids}|${dns_label}")
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
        
        local name cidr access ocid rt_ocid sl_ids dns_label
        IFS='|' read -r name cidr access ocid rt_ocid sl_ids dns_label <<< "$subnet_info"
        
        local access_color
        [[ "$access" == "Private" ]] && access_color="$RED" || access_color="$LIGHT_GREEN"
        
        # Get route table info
        local rt_name rt_rules rt_display
        rt_name=$(get_route_table_name "$rt_ocid")
        rt_rules=$(get_route_table_rule_count "$rt_ocid")
        rt_display="${rt_name} (${rt_rules})"
        
        # DNS label display with fixed width (one space after colon)
        local dns_display
        if [[ -n "$dns_label" ]]; then
            dns_display=$(printf "DNS: %-12s" "$dns_label")
        else
            dns_display=$(printf "%-17s" "")
        fi
        
        # Get security list names
        local sl_display=""
        if [[ -n "$sl_ids" ]]; then
            local sl_names=""
            IFS=',' read -ra sl_array <<< "$sl_ids"
            for sl_id in "${sl_array[@]}"; do
                [[ -z "$sl_id" ]] && continue
                local sl_name
                sl_name=$(get_security_list_name "$sl_id")
                if [[ -n "$sl_name" ]]; then
                    [[ -n "$sl_names" ]] && sl_names+=", "
                    sl_names+="$sl_name"
                fi
            done
            [[ -n "$sl_names" ]] && sl_display="${sl_names}"
        fi
        
        # Subnet line with route table and DNS label
        printf "  ${BOLD}${WHITE}Subnet:${NC} ${GREEN}%-30s${NC} ${WHITE}[${CYAN}%-15s${WHITE}]${NC} ${WHITE}[${access_color}%-7s${WHITE}]${NC} ${MAGENTA}%-17s${NC} ${WHITE}RT:${NC} ${CYAN}%-25s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
            "$name" "$cidr" "$access" "$dns_display" "$rt_display" "$ocid"
        
        # Count total items for tree display (SL + NSGs)
        local nsg_list="${nsgs_by_shortname[$shortname]:-}"
        local has_sl=false
        local has_nsg=false
        [[ -n "$sl_display" ]] && has_sl=true
        [[ -n "$nsg_list" ]] && has_nsg=true
        
        # Display security lists if any
        if [[ "$has_sl" == "true" ]]; then
            local sl_prefix="└─"
            [[ "$has_nsg" == "true" ]] && sl_prefix="├─"
            printf "          ${MAGENTA}${sl_prefix} SL:${NC}  ${WHITE}%s${NC}\n" "$sl_display"
        fi
        
        # Display matching NSGs
        if [[ "$has_nsg" == "true" ]]; then
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
                
                # NSG line with rule counts - aligned with subnet OCID
                printf "          ${BLUE}${prefix} NSG:${NC} ${WHITE}%-30s${NC} ${CYAN}%-15s${NC} %-51s ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                    "$nsg_name" "$rules_display" "" "$nsg_ocid"
            done
        fi
        echo ""
    done
    
    # Display unmatched subnets
    if [[ ${#unmatched_subnets[@]} -gt 0 ]]; then
        for subnet_entry in "${unmatched_subnets[@]}"; do
            local name cidr access ocid rt_ocid sl_ids dns_label
            IFS='|' read -r name cidr access ocid rt_ocid sl_ids dns_label <<< "$subnet_entry"
            
            local access_color
            [[ "$access" == "Private" ]] && access_color="$RED" || access_color="$LIGHT_GREEN"
            
            # Get route table info
            local rt_name rt_rules rt_display
            rt_name=$(get_route_table_name "$rt_ocid")
            rt_rules=$(get_route_table_rule_count "$rt_ocid")
            rt_display="${rt_name} (${rt_rules})"
            
            # DNS label display with fixed width (one space after colon)
            local dns_display
            if [[ -n "$dns_label" ]]; then
                dns_display=$(printf "DNS: %-12s" "$dns_label")
            else
                dns_display=$(printf "%-17s" "")
            fi
            
            # Get security list names
            local sl_display=""
            if [[ -n "$sl_ids" ]]; then
                local sl_names=""
                IFS=',' read -ra sl_array <<< "$sl_ids"
                for sl_id in "${sl_array[@]}"; do
                    [[ -z "$sl_id" ]] && continue
                    local sl_name
                    sl_name=$(get_security_list_name "$sl_id")
                    if [[ -n "$sl_name" ]]; then
                        [[ -n "$sl_names" ]] && sl_names+=", "
                        sl_names+="$sl_name"
                    fi
                done
                [[ -n "$sl_names" ]] && sl_display="${sl_names}"
            fi
            
            printf "  ${BOLD}${WHITE}Subnet:${NC} ${GREEN}%-30s${NC} ${WHITE}[${CYAN}%-15s${WHITE}]${NC} ${WHITE}[${access_color}%-7s${WHITE}]${NC} ${MAGENTA}%-17s${NC} ${WHITE}RT:${NC} ${CYAN}%-25s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "$name" "$cidr" "$access" "$dns_display" "$rt_display" "$ocid"
            
            # Display security lists if any
            if [[ -n "$sl_display" ]]; then
                printf "          ${MAGENTA}└─ SL:${NC}  ${WHITE}%s${NC}\n" "$sl_display"
            fi
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
            
            # NSG line with rule counts - aligned with subnet OCID
            printf "          ${BLUE}${prefix} NSG:${NC} ${WHITE}%-30s${NC} ${CYAN}%-15s${NC} %-51s ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
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

# Get color for firmware update state
color_firmware_state() {
    case "$1" in
        UP_TO_DATE|COMPLETED) echo "$GREEN" ;;
        IN_PROGRESS|UPDATING) echo "$YELLOW" ;;
        FAILED|ERROR) echo "$RED" ;;
        *) echo "$WHITE" ;;
    esac
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
                local update_state_color
                update_state_color=$(color_firmware_state "$firmware_update_state")
                
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

#===============================================================================
# UNIFIED CONSOLE HISTORY FUNCTION
# Single function for capturing and displaying console history
# Used by both CLI (--console-history) and interactive modes
#===============================================================================

# Capture and display console history for an instance
# Args: 
#   $1 = instance OCID (required)
#   $2 = region (optional, defaults to EFFECTIVE_REGION or REGION)
#   $3 = instance display name (optional, for display purposes)
#   $4 = auto_cleanup - "true" to delete history after display (default: "true")
#   $5 = interactive - "true" for interactive prompts (default: "false")
#
# Returns: 0 on success, 1 on failure
# Output: Console history content to stdout
#
fetch_and_display_console_history() {
    local instance_ocid="$1"
    local region="${2:-${EFFECTIVE_REGION:-$REGION}}"
    local instance_name="${3:-$instance_ocid}"
    local auto_cleanup="${4:-true}"
    local interactive="${5:-false}"
    
    # Validate required args
    if [[ -z "$instance_ocid" ]]; then
        echo -e "${RED}Error: Instance OCID required${NC}" >&2
        return 1
    fi
    
    if [[ -z "$region" ]]; then
        echo -e "${RED}Error: Region not set${NC}" >&2
        return 1
    fi
    
    local console_history_id=""
    local capture_cmd=""
    local status_cmd=""
    local content_cmd=""
    
    # ========== STEP 1: Capture Console History ==========
    echo ""
    echo -e "${YELLOW}Capturing console history...${NC}"
    echo ""
    
    capture_cmd="oci --region \"$region\" compute console-history capture --instance-id \"$instance_ocid\" --output json"
    echo -e "${GRAY}Command: ${capture_cmd}${NC}"
    echo ""
    
    local capture_result
    capture_result=$(oci --region "$region" compute console-history capture \
        --instance-id "$instance_ocid" \
        --output json 2>&1)
    local capture_exit=$?
    
    if [[ $capture_exit -ne 0 ]]; then
        echo -e "${RED}✗ Failed to capture console history${NC}"
        echo -e "${GRAY}Exit code: $capture_exit${NC}"
        echo -e "${GRAY}Output: $capture_result${NC}"
        return 1
    fi
    
    console_history_id=$(echo "$capture_result" | jq -r '.data.id // empty' 2>/dev/null)
    
    if [[ -z "$console_history_id" ]]; then
        echo -e "${RED}✗ Failed to get console history ID from response${NC}"
        echo -e "${GRAY}Response: $capture_result${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✓ Console history capture initiated${NC}"
    echo -e "  ${CYAN}History ID:${NC} ${YELLOW}$console_history_id${NC}"
    echo ""
    
    # ========== STEP 2: Wait for Capture to Complete ==========
    echo -e "${YELLOW}Waiting for capture to complete...${NC}"
    
    status_cmd="oci --region \"$region\" compute console-history get --instance-console-history-id \"$console_history_id\" --output json"
    echo -e "${GRAY}Polling command: ${status_cmd}${NC}"
    echo ""
    
    local max_wait=60
    local wait_count=0
    local capture_state="REQUESTED"
    local status_json=""
    
    while [[ "$capture_state" != "SUCCEEDED" && "$capture_state" != "FAILED" && $wait_count -lt $max_wait ]]; do
        sleep 2
        ((wait_count+=2))
        
        status_json=$(oci --region "$region" compute console-history get \
            --instance-console-history-id "$console_history_id" \
            --output json 2>/dev/null)
        
        capture_state=$(echo "$status_json" | jq -r '.data["lifecycle-state"] // "UNKNOWN"' 2>/dev/null)
        echo -ne "\r  ${YELLOW}Status:${NC} ${WHITE}${capture_state}${NC} (${wait_count}s)    "
    done
    echo ""
    
    if [[ "$capture_state" != "SUCCEEDED" ]]; then
        echo ""
        echo -e "${RED}✗ Console history capture failed or timed out${NC}"
        echo -e "  ${CYAN}Final State:${NC} ${YELLOW}$capture_state${NC}"
        
        # Cleanup on failure if we have an ID
        if [[ -n "$console_history_id" && "$auto_cleanup" == "true" ]]; then
            oci --region "$region" compute console-history delete \
                --instance-console-history-id "$console_history_id" \
                --force 2>/dev/null
        fi
        return 1
    fi
    
    # Show final status details
    echo ""
    echo -e "${GREEN}✓ Console history capture completed${NC}"
    echo -e "  ${CYAN}Lifecycle State:${NC} ${GREEN}$capture_state${NC}"
    
    # Extract additional details from status_json
    local time_created availability_domain
    time_created=$(echo "$status_json" | jq -r '.data["time-created"] // "N/A"' 2>/dev/null)
    availability_domain=$(echo "$status_json" | jq -r '.data["availability-domain"] // "N/A"' 2>/dev/null)
    echo -e "  ${CYAN}Time Created:${NC}    ${WHITE}${time_created}${NC}"
    echo -e "  ${CYAN}AD:${NC}              ${WHITE}${availability_domain}${NC}"
    echo ""
    
    # ========== STEP 3: Fetch Console History Content ==========
    echo -e "${BOLD}${MAGENTA}─── Console Output ───────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    content_cmd="oci --region \"$region\" compute console-history get-content --instance-console-history-id \"$console_history_id\" --length 10000000 --file -"
    echo -e "${GRAY}Command: ${content_cmd}${NC}"
    echo ""
    
    # Use temp file for reliability
    local temp_output temp_error
    temp_output=$(mktemp)
    temp_error=$(mktemp)
    
    # Capture the raw command output for display if empty
    local raw_output
    raw_output=$(oci --region "$region" compute console-history get-content \
        --instance-console-history-id "$console_history_id" \
        --length 10000000 \
        --file "$temp_output" 2>&1)
    local fetch_exit=$?
    
    echo -e "${BOLD}${MAGENTA}─── Output ───────────────────────────────────────────────────────────────────────${NC}"
    
    if [[ $fetch_exit -eq 0 ]]; then
        if [[ -s "$temp_output" ]]; then
            cat "$temp_output"
        else
            echo -e "${YELLOW}(Console history is empty - no serial console output captured)${NC}"
            echo ""
            echo -e "${WHITE}OCI CLI raw output:${NC}"
            if [[ -n "$raw_output" ]]; then
                echo -e "${GRAY}${raw_output}${NC}"
            else
                echo -e "${GRAY}(no output returned)${NC}"
            fi
            echo ""
            echo -e "${WHITE}Note: This can happen if:${NC}"
            echo -e "${GRAY}  - The instance has not produced any serial console output${NC}"
            echo -e "${GRAY}  - Serial console logging is not enabled on the instance${NC}"
            echo -e "${GRAY}  - The instance was recently created/rebooted${NC}"
        fi
    else
        echo -e "${RED}Failed to fetch console history content${NC}"
        echo -e "${GRAY}Exit code: $fetch_exit${NC}"
        echo -e "${WHITE}OCI CLI output:${NC}"
        echo -e "${GRAY}${raw_output}${NC}"
        if [[ -s "$temp_error" ]]; then
            echo -e "${WHITE}Stderr:${NC}"
            cat "$temp_error"
        fi
    fi
    
    echo ""
    echo -e "${BOLD}${MAGENTA}─── End of Console Output ────────────────────────────────────────────────────────${NC}"
    echo ""
    
    # ========== STEP 4: Save Option (Interactive Only) ==========
    if [[ "$interactive" == "true" && -s "$temp_output" ]]; then
        echo -n -e "${CYAN}Save to file? [y/N]: ${NC}"
        local save_choice
        read -r save_choice
        
        if [[ "$save_choice" =~ ^[Yy] ]]; then
            local safe_name
            safe_name=$(echo "$instance_name" | tr ' ' '_' | tr -cd '[:alnum:]_-')
            local filename="${safe_name}_console_$(date +%Y%m%d_%H%M%S).log"
            
            echo -n -e "${CYAN}Filename [${filename}]: ${NC}"
            local custom_filename
            read -r custom_filename
            [[ -n "$custom_filename" ]] && filename="$custom_filename"
            
            if cp "$temp_output" "$filename" 2>/dev/null; then
                echo -e "${GREEN}✓ Console output saved to: ${WHITE}$(pwd)/${filename}${NC}"
            else
                echo -e "${RED}Failed to save console output${NC}"
            fi
        fi
        echo ""
    fi
    
    # Cleanup temp files
    rm -f "$temp_output" "$temp_error"
    
    # ========== STEP 5: Cleanup Console History ==========
    if [[ "$auto_cleanup" == "true" ]]; then
        echo -e "${GRAY}Cleaning up console history...${NC}"
        local delete_cmd="oci --region \"$region\" compute console-history delete --instance-console-history-id \"$console_history_id\" --force"
        echo -e "${GRAY}Command: ${delete_cmd}${NC}"
        
        if oci --region "$region" compute console-history delete \
            --instance-console-history-id "$console_history_id" \
            --force 2>/dev/null; then
            echo -e "${GREEN}✓ Console history deleted${NC}"
        else
            echo -e "${YELLOW}⚠ Failed to delete console history (may need manual cleanup)${NC}"
            echo -e "${GRAY}History ID: ${console_history_id}${NC}"
        fi
    else
        echo -e "${WHITE}Console history retained:${NC} ${YELLOW}$console_history_id${NC}"
    fi
    
    echo ""
    return 0
}

# CLI wrapper for console history (--console-history flag)
# Args: $1 = instance OCID
get_console_history() {
    local instance_ocid="$1"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                              CONSOLE HISTORY                                       ${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${WHITE}Instance OCID:${NC} ${YELLOW}$instance_ocid${NC}"
    echo -e "${WHITE}Region:${NC}        ${WHITE}$region${NC}"
    
    # Call unified function with auto_cleanup=true, interactive=false
    fetch_and_display_console_history "$instance_ocid" "$region" "$instance_ocid" "true" "false"
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
        state_color=$(color_cluster_state "$cluster_state")
        
        # Color available hosts - light green if not 0
        local avail_color="$WHITE"
        [[ "$available_hosts" != "0" && "$available_hosts" != "N/A" ]] && avail_color="$LIGHT_GREEN"
        
        # Color clique ID - yellow for NO_INSTANCES entries
        local clique_color="$CYAN"
        [[ "$clique_id" == NO_INSTANCES* ]] && clique_color="$YELLOW"
        
        printf "${clique_color}%-48s${NC} ${WHITE}%6s${NC} ${WHITE}%8s${NC} ${avail_color}%6s${NC} ${WHITE}%6s${NC}       ${WHITE}%6s${NC}       ${state_color}%-12s${NC}\n" \
            "$clique_id" "$nodes" "$healthy_hosts" "$available_hosts" "$total_hosts" "$gpu_cluster_size" "$cluster_state"
        
        # Fabric (first)
        if [[ "$fabric_name" != "N/A" && "$fabric_ocid" != "N/A" ]]; then
            printf "          ${WHITE}├─${NC} ${BOLD}${ORANGE}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "Fabric:" "$fabric_name" "$fabric_ocid"
        fi
        
        # GPU Memory Cluster
        if is_valid_ocid "$gpu_mem_cluster"; then
            local gpu_cluster_name
            gpu_cluster_name=$(lookup_cache "$CLUSTER_CACHE" "$gpu_mem_cluster" 2 2>/dev/null || echo "N/A")
            printf "          ${WHITE}├─${NC} ${BOLD}${MAGENTA}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "GPU Mem Cluster:" "$gpu_cluster_name" "$gpu_mem_cluster"
        fi
        
        # Compute Cluster
        if is_valid_ocid "$compute_cluster_id"; then
            local compute_cluster_name
            compute_cluster_name=$(get_compute_cluster_name "$compute_cluster_id")
            printf "          ${WHITE}├─${NC} ${BOLD}${BLUE}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "Compute Cluster:" "$compute_cluster_name" "$compute_cluster_id"
        fi
        
        # Instance Config
        if is_valid_ocid "$instance_config_id"; then
            local instance_config_name
            instance_config_name=$(get_instance_config_name "$instance_config_id")
            printf "          ${WHITE}├─${NC} ${BOLD}${GREEN}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                "Instance Config:" "$instance_config_name" "$instance_config_id"
        fi
        
        # Firmware (last)
        if [[ "$fabric_name" != "N/A" && "$fabric_ocid" != "N/A" ]]; then
            if [[ "$current_firmware" != "N/A" && -n "$current_firmware" ]]; then
                local current_short="${current_firmware: -5}"
                local target_short="${target_firmware: -5}"
                local firmware_color="$WHITE"
                
                # Highlight in red if current != target
                if [[ "$current_firmware" != "$target_firmware" && "$target_firmware" != "N/A" && -n "$target_firmware" ]]; then
                    firmware_color="$RED"
                fi
                
                # Color firmware update state
                local update_state_color
                update_state_color=$(color_firmware_state "$firmware_update_state")
                
                printf "          ${WHITE}└─${NC} ${BOLD}${ORANGE}Firmware:${NC} ${update_state_color}%-12s${NC} ${firmware_color}current: %-10s target: %-10s${NC}\n" \
                    "$firmware_update_state" "$current_short" "$target_short"
            fi
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
                if is_valid_ocid "$instance_config_id"; then
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
                if is_valid_ocid "$ic"; then
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
        
        # Check cordon/drain status
        local node_json
        node_json=$(kubectl get node "$node_name" -o json 2>/dev/null)
        local is_unschedulable
        is_unschedulable=$(echo "$node_json" | jq -r '.spec.unschedulable // false' 2>/dev/null)
        
        # Get pod count on this node
        local pod_count
        pod_count=$(kubectl get pods --all-namespaces --field-selector=spec.nodeName="$node_name",status.phase=Running -o json 2>/dev/null | jq '.items | length' 2>/dev/null)
        [[ -z "$pod_count" ]] && pod_count="0"
        
        # Get daemonset pod count
        local ds_pod_count
        ds_pod_count=$(kubectl get pods --all-namespaces --field-selector=spec.nodeName="$node_name",status.phase=Running -o json 2>/dev/null | \
            jq '[.items[] | select(.metadata.ownerReferences[]?.kind == "DaemonSet")] | length' 2>/dev/null)
        [[ -z "$ds_pod_count" ]] && ds_pod_count="0"
        
        # Determine scheduling status
        local sched_status="Schedulable"
        local sched_color="$GREEN"
        if [[ "$is_unschedulable" == "true" ]]; then
            # Check if drained (cordoned + only daemonset pods)
            local non_ds_pods=$((pod_count - ds_pod_count))
            if [[ $non_ds_pods -le 0 ]]; then
                sched_status="Drained"
                sched_color="$RED"
            else
                sched_status="Cordoned"
                sched_color="$YELLOW"
            fi
        fi
        
        echo -e "  ${WHITE}Schedule Status:${NC}   ${sched_color}${sched_status}${NC}"
        echo -e "  ${WHITE}Running Pods:${NC}      ${CYAN}${pod_count}${NC} ${GRAY}(${ds_pod_count} DaemonSet)${NC}"
        
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
        
        if is_valid_ocid "$instance_config_id"; then
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
                if is_valid_ocid "$ic"; then
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
    if is_valid_ocid "$instance_config_id"; then
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
        # Sort fabrics by state: OCCUPIED first, then AVAILABLE, PROVISIONING, UNAVAILABLE
        local sorted_fabrics
        sorted_fabrics=$(grep -v '^#' "$FABRIC_CACHE" 2>/dev/null | awk -F'|' '
            {
                state = $4
                # Assign sort order based on state
                if (state == "OCCUPIED") order = 1
                else if (state == "AVAILABLE") order = 2
                else if (state == "PROVISIONING") order = 3
                else if (state == "UNAVAILABLE") order = 4
                else order = 5
                print order "|" $0
            }
        ' | sort -t'|' -k1,1n | cut -d'|' -f2-)
        
        while IFS='|' read -r fabric_name fabric_suffix fabric_ocid fabric_state healthy_hosts avail_hosts total_hosts current_fw target_fw fw_state; do
            [[ -z "$fabric_ocid" ]] && continue
            
            ((fabric_idx++))
            local fid="f${fabric_idx}"
            FABRIC_INDEX_MAP[$fid]="$fabric_ocid"
            
            # Color state
            local state_color
            case "$fabric_state" in
                OCCUPIED) state_color="$GREEN" ;;
                AVAILABLE) state_color="$GREEN" ;;
                PROVISIONING) state_color="$CYAN" ;;
                UNAVAILABLE) state_color="$RED" ;;
                *) state_color="$WHITE" ;;
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
                    local state_color
                    state_color=$(color_cluster_state "$cluster_state")
                    
                    # Cluster line 1: ID, Name, State (aligned), Size (aligned with Total), OCID on same line
                    printf "     ${WHITE}${connector}${NC} ${YELLOW}%-4s${NC} ${MAGENTA}%-37s${NC} ${state_color}%-12s${NC} %8s %6s${WHITE}%6s${NC}  ${YELLOW}%s${NC}\n" \
                        "$gid" "$cluster_name" "$cluster_state" "" "" "$cluster_size" "$cluster_ocid"
                    
                    # Cluster line 2: Compute Cluster
                    printf "     ${WHITE}${continuation}${NC}            ${GRAY}Compute Cluster: ${BLUE}%s${NC}\n" "$cc_name"
                    
                    # Cluster line 3: Instance Configuration (full name)
                    printf "     ${WHITE}${continuation}${NC}            ${GRAY}Instance Config: ${GREEN}%s${NC}\n" "$ic_name"
                done
            fi
            
            # Show message if no clusters for this fabric
            if [[ $clusters_found -eq 0 ]]; then
                printf "     ${WHITE}└──${NC} ${GRAY}(no clusters)${NC}\n"
            fi
            
            echo ""
        done <<< "$sorted_fabrics"
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
        while IFS='|' read -r ic_ocid ic_name _; do
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
    printf "${BOLD}%-5s %-50s %-12s %s${NC}\n" "ID" "Compute Cluster Name" "Status" "OCID"
    print_separator 140
    
    local cc_idx=0
    if [[ -f "$COMPUTE_CLUSTER_CACHE" ]]; then
        while IFS='|' read -r cc_ocid cc_name cc_ad cc_state; do
            [[ "$cc_ocid" =~ ^#.*$ ]] && continue
            [[ -z "$cc_ocid" ]] && continue
            
            # Default state if not present (old cache format)
            [[ -z "$cc_state" ]] && cc_state="UNKNOWN"
            
            # Skip deleted clusters
            [[ "$cc_state" == "DELETED" ]] && continue
            
            ((cc_idx++))
            local cid="c${cc_idx}"
            CC_INDEX_MAP[$cid]="$cc_ocid"
            
            # Color-code the status
            local state_color="$GREEN"
            case "$cc_state" in
                ACTIVE) state_color="$GREEN" ;;
                CREATING|UPDATING) state_color="$YELLOW" ;;
                DELETING) state_color="$RED" ;;
                *) state_color="$GRAY" ;;
            esac
            
            printf "${YELLOW}%-5s${NC} ${WHITE}%-50s${NC} ${state_color}%-12s${NC} ${CYAN}%s${NC}\n" \
                "$cid" "$cc_name" "$cc_state" "$cc_ocid"
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
        echo -e "  ${GREEN}5${NC}) ${WHITE}Instance Configurations${NC}       - Create, view, compare, and delete instance configs"
        echo -e "  ${GREEN}6${NC}) ${WHITE}Compute Clusters${NC}              - Create, view, and delete compute clusters"
        echo -e "  ${GREEN}7${NC}) ${WHITE}GPU Instance Tagging${NC}          - Manage ComputeInstanceHostActions namespace and tags"
        echo ""
        echo -e "  ${CYAN}c${NC}) ${WHITE}Cache Stats${NC}                   - View cache status, age, and refresh options"
        echo -e "  ${RED}q${NC}) ${WHITE}Quit${NC}"
        echo ""
        echo -n -e "${BOLD}${CYAN}Enter selection [1-7, c, q]: ${NC}"
        
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
            5)
                manage_instance_configurations
                ;;
            6)
                manage_compute_clusters
                ;;
            7)
                manage_gpu_instance_tagging
                ;;
            c|C|cache|CACHE)
                display_cache_stats
                ;;
            q|Q|quit|QUIT|exit|EXIT)
                echo ""
                echo -e "${GREEN}Exiting management mode${NC}"
                break
                ;;
            *)
                echo -e "${RED}Invalid selection. Please enter 1-7, c, or q.${NC}"
                ;;
        esac
    done
}

#--------------------------------------------------------------------------------
# Helper: Format time duration for cache display
#--------------------------------------------------------------------------------
_format_cache_duration() {
    local seconds=$1
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}s"
    elif [[ $seconds -lt 3600 ]]; then
        echo "$((seconds / 60))m $((seconds % 60))s"
    else
        echo "$((seconds / 3600))h $((seconds % 3600 / 60))m"
    fi
}

#--------------------------------------------------------------------------------
# Helper: Get cache status line for a single cache file
#--------------------------------------------------------------------------------
_get_cache_status_line() {
    local cache_file="$1"
    local cache_name="$2"
    local ttl="${3:-3600}"  # Default 1 hour
    
    if [[ ! -f "$cache_file" ]]; then
        printf "  ${GRAY}%-30s${NC} ${RED}%-12s${NC} %8s %10s %12s %10s\n" \
            "$cache_name" "NOT CACHED" "-" "-" "-" "-"
        return
    fi
    
    local file_mtime
    file_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    local current_time=$(date +%s)
    local age=$((current_time - file_mtime))
    local expires_in=$((ttl - age))
    
    # Count entries (lines for txt, items for json)
    local entry_count=0
    if [[ "$cache_file" == *.json ]]; then
        entry_count=$(jq 'if type == "array" then length else 1 end' "$cache_file" 2>/dev/null || echo 0)
    else
        entry_count=$(wc -l < "$cache_file" 2>/dev/null || echo 0)
    fi
    
    # File size
    local file_size
    file_size=$(du -h "$cache_file" 2>/dev/null | cut -f1)
    
    # Determine status
    local status status_color
    if [[ $expires_in -le 0 ]]; then
        status="EXPIRED"
        status_color="$RED"
    elif [[ $expires_in -lt 300 ]]; then  # < 5 minutes
        status="EXPIRING"
        status_color="$YELLOW"
    else
        status="VALID"
        status_color="$GREEN"
    fi
    
    # Format times
    local age_fmt expires_fmt
    age_fmt=$(_format_cache_duration $age)
    if [[ $expires_in -gt 0 ]]; then
        expires_fmt=$(_format_cache_duration $expires_in)
    else
        expires_fmt="NOW"
    fi
    
    printf "  %-30s ${status_color}%-12s${NC} %8s %10s %12s %10s\n" \
        "$cache_name" "$status" "$entry_count" "$file_size" "$age_fmt" "$expires_fmt"
}

#--------------------------------------------------------------------------------
# Display Cache Statistics - Show all cache files with status, age, and TTL
#--------------------------------------------------------------------------------
display_cache_stats() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                                                              CACHE STATISTICS                                                                          ${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${WHITE}Cache Directory:${NC} ${YELLOW}${CACHE_DIR}${NC}"
    echo ""
    
    # Header
    printf "${BOLD}  %-30s %-12s %8s %10s %12s %10s${NC}\n" \
        "Cache Name" "Status" "Entries" "Size" "Age" "Expires In"
    print_separator 100
    
    echo ""
    echo -e "${BOLD}${WHITE}=== GPU Resources ===${NC}"
    _get_cache_status_line "$FABRIC_CACHE" "GPU Memory Fabrics" 3600
    _get_cache_status_line "$CLUSTER_CACHE" "GPU Memory Clusters" 3600
    _get_cache_status_line "$COMPUTE_CLUSTER_CACHE" "Compute Clusters" 3600
    
    echo ""
    echo -e "${BOLD}${WHITE}=== Compute Resources ===${NC}"
    _get_cache_status_line "$INSTANCE_CONFIG_CACHE" "Instance Configurations" 3600
    _get_cache_status_line "$BOOT_VOLUME_CACHE" "Boot Volumes" 3600
    _get_cache_status_line "$IMAGE_CACHE" "Images" 3600
    _get_cache_status_line "$CAPACITY_TOPOLOGY_CACHE" "Capacity Topology Hosts" 3600
    
    echo ""
    echo -e "${BOLD}${WHITE}=== OKE Resources ===${NC}"
    _get_cache_status_line "$OKE_ENV_CACHE" "OKE Environment" 3600
    _get_cache_status_line "$NODE_STATE_CACHE" "Node States" 300
    
    echo ""
    echo -e "${BOLD}${WHITE}=== Network Resources ===${NC}"
    _get_cache_status_line "$NETWORK_RESOURCES_CACHE" "Network Resources" 3600
    _get_cache_status_line "$IGW_CACHE" "Internet Gateways" 3600
    _get_cache_status_line "$SGW_CACHE" "Service Gateways" 3600
    _get_cache_status_line "$NAT_CACHE" "NAT Gateways" 3600
    _get_cache_status_line "$DRG_CACHE" "DRG Attachments" 3600
    _get_cache_status_line "$LPG_CACHE" "Local Peering Gateways" 3600
    _get_cache_status_line "$RPC_CACHE" "Remote Peering Connections" 3600
    _get_cache_status_line "$RT_CACHE" "Route Tables" 3600
    _get_cache_status_line "$NSG_RULES_CACHE" "NSG Rules" 3600
    _get_cache_status_line "$SL_CACHE" "Security Lists" 3600
    
    echo ""
    echo -e "${BOLD}${WHITE}=== Other ===${NC}"
    _get_cache_status_line "$ANNOUNCEMENTS_LIST_CACHE" "Announcements" 3600
    
    echo ""
    print_separator 100
    echo ""
    
    # Show total cache size
    local total_size="0"
    if [[ -d "$CACHE_DIR" ]]; then
        total_size=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)
    fi
    echo -e "${WHITE}Total Cache Size:${NC} ${CYAN}${total_size}${NC}"
    echo ""
    
    # Legend
    echo -e "${BOLD}${WHITE}Status Legend:${NC}"
    echo -e "  ${GREEN}VALID${NC}     - Cache is fresh and within TTL"
    echo -e "  ${YELLOW}EXPIRING${NC}  - Cache will expire within 5 minutes"
    echo -e "  ${RED}EXPIRED${NC}   - Cache has exceeded TTL and will be refreshed on next use"
    echo -e "  ${RED}NOT CACHED${NC} - No cache file exists"
    echo ""
    
    echo -e "${BOLD}${WHITE}═══ Actions ═══${NC}"
    echo -e "  ${YELLOW}1${NC} - Clear GPU caches (fabrics, clusters)"
    echo -e "  ${YELLOW}2${NC} - Clear Compute caches (instances, boot volumes, images)"
    echo -e "  ${YELLOW}3${NC} - Clear Network caches"
    echo -e "  ${YELLOW}4${NC} - Clear OKE caches"
    echo -e "  ${RED}a${NC} - Clear ALL caches"
    echo -e "  ${CYAN}Enter${NC} - Return to menu"
    echo ""
    echo -n -e "${CYAN}Action [1-4/a/Enter]: ${NC}"
    
    local action
    read -r action
    
    case "$action" in
        1)
            echo -e "${YELLOW}Clearing GPU caches...${NC}"
            rm -f "$FABRIC_CACHE" "$CLUSTER_CACHE" "$COMPUTE_CLUSTER_CACHE"
            echo -e "${GREEN}✓ GPU caches cleared${NC}"
            sleep 1
            display_cache_stats
            ;;
        2)
            echo -e "${YELLOW}Clearing Compute caches...${NC}"
            rm -f "$INSTANCE_CONFIG_CACHE" "$BOOT_VOLUME_CACHE" "$IMAGE_CACHE" "$CAPACITY_TOPOLOGY_CACHE"
            echo -e "${GREEN}✓ Compute caches cleared${NC}"
            sleep 1
            display_cache_stats
            ;;
        3)
            echo -e "${YELLOW}Clearing Network caches...${NC}"
            rm -f "$NETWORK_RESOURCES_CACHE" "$IGW_CACHE" "$SGW_CACHE" "$NAT_CACHE" "$DRG_CACHE" \
                  "$LPG_CACHE" "$RPC_CACHE" "$RT_CACHE" "$NSG_RULES_CACHE" "$SL_CACHE"
            echo -e "${GREEN}✓ Network caches cleared${NC}"
            sleep 1
            display_cache_stats
            ;;
        4)
            echo -e "${YELLOW}Clearing OKE caches...${NC}"
            rm -f "$OKE_ENV_CACHE" "$NODE_STATE_CACHE"
            echo -e "${GREEN}✓ OKE caches cleared${NC}"
            sleep 1
            display_cache_stats
            ;;
        a|A|all|ALL)
            echo -e "${YELLOW}Clearing ALL caches...${NC}"
            rm -f "$CACHE_DIR"/*.txt "$CACHE_DIR"/*.json 2>/dev/null
            echo -e "${GREEN}✓ All caches cleared${NC}"
            sleep 1
            display_cache_stats
            ;;
        *)
            return
            ;;
    esac
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
        while IFS='|' read -r type name cidr access state ocid rt_ocid sl_ids dns_label; do
            [[ "$type" != "SUBNET" ]] && continue
            ((resource_idx++))
            NET_RESOURCE_MAP[$resource_idx]="SUBNET|$ocid"
            
            local access_color
            [[ "$access" == "Private" ]] && access_color="$RED" || access_color="$LIGHT_GREEN"
            
            # DNS label display (one space after colon, extended column)
            local dns_display
            if [[ -n "$dns_label" ]]; then
                dns_display=$(printf "DNS: %-13s" "$dns_label")
            else
                dns_display=$(printf "%-18s" "")
            fi
            
            # Use printf for alignment
            printf "  ${YELLOW}%2d${NC}) ${WHITE}Subnet:${NC} ${GREEN}%-35s${NC} ${WHITE}[${CYAN}%-18s${WHITE}]${NC} ${WHITE}[${access_color}%-7s${WHITE}]${NC} ${MAGENTA}%-18s${NC} ${YELLOW}(%s)${NC}\n" \
                "$resource_idx" "$name" "$cidr" "$access" "$dns_display" "$ocid"
        done < <(grep "^SUBNET|" "$NETWORK_RESOURCES_CACHE" 2>/dev/null)
    fi
    
    echo ""
    # Build mappings from Route Tables and Security Lists to Subnet names
    declare -A RT_TO_SUBNETS
    declare -A SL_TO_SUBNETS
    declare -A ASSIGNED_SL_IDS
    
    if [[ -f "$NETWORK_RESOURCES_CACHE" ]]; then
        while IFS='|' read -r type name cidr access state ocid rt_ocid sl_ids dns_label; do
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
            
            printf "  ${YELLOW}%2d${NC}) ${WHITE}NSG:${NC} ${CYAN}%-40s${NC} ${WHITE}[In:${GREEN}%-3s${WHITE} Out:${GREEN}%-3s${WHITE}]${NC}      ${YELLOW}(%s)${NC}\n" \
                "$resource_idx" "$name" "$ingress" "$egress" "$ocid"
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
            ((resource_idx++))
            ((sl_count++))
            NET_RESOURCE_MAP[$resource_idx]="SECURITY_LIST|$sl_ocid"
            
            # Get assigned subnets
            local assigned_subnets="${SL_TO_SUBNETS[$sl_ocid]:-}"
            local subnet_display
            if [[ -n "$assigned_subnets" ]]; then
                subnet_display="→ ${assigned_subnets}"
                echo -e "  ${YELLOW}$(printf '%2d' $resource_idx)${NC}) ${WHITE}SL:${NC} ${MAGENTA}${sl_name}${NC} ${WHITE}[In:${GREEN}${sl_ingress}${WHITE} Out:${GREEN}${sl_egress}${WHITE}]${NC} ${YELLOW}(${sl_ocid})${NC} ${CYAN}${subnet_display}${NC}"
            else
                echo -e "  ${YELLOW}$(printf '%2d' $resource_idx)${NC}) ${WHITE}SL:${NC} ${MAGENTA}${sl_name}${NC} ${WHITE}[In:${GREEN}${sl_ingress}${WHITE} Out:${GREEN}${sl_egress}${WHITE}]${NC} ${YELLOW}(${sl_ocid})${NC} ${GRAY}(not assigned)${NC}"
            fi
        done < "$SL_CACHE"
    fi
    [[ $sl_count -eq 0 ]] && echo -e "  ${WHITE}(No security lists found)${NC}"
    
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
            
            printf "  ${YELLOW}%2d${NC}) ${WHITE}RT:${NC} ${MAGENTA}%-30s${NC} ${WHITE}[Rules:${GREEN}%-2s${WHITE}]${NC} ${YELLOW}(%s)${NC} ${WHITE}→${NC} ${CYAN}%s${NC}\n" \
                "$resource_idx" "$rt_name" "$rt_rules" "$rt_ocid" "$assigned_subnets"
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
            printf "  ${YELLOW}%2d${NC}) ${WHITE}Internet GW:${NC}   ${ORANGE}%-40s${NC} ${WHITE}[${state_color}%-9s${WHITE}]${NC} ${YELLOW}(%s)${NC}\n" \
                "$resource_idx" "${igw_name:-N/A}" "$igw_state" "$igw_ocid"
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
            printf "  ${YELLOW}%2d${NC}) ${WHITE}NAT GW:${NC}        ${ORANGE}%-40s${NC} ${WHITE}[${state_color}%-9s${WHITE}]${NC} ${YELLOW}(%s)${NC}\n" \
                "$resource_idx" "${nat_name:-N/A}" "$nat_state" "$nat_ocid"
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
            printf "  ${YELLOW}%2d${NC}) ${WHITE}Service GW:${NC}    ${ORANGE}%-40s${NC} ${WHITE}[${state_color}%-9s${WHITE}]${NC} ${YELLOW}(%s)${NC}\n" \
                "$resource_idx" "${sgw_name:-N/A}" "$sgw_state" "$sgw_ocid"
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
            printf "  ${YELLOW}%2d${NC}) ${WHITE}DRG Attach:${NC}    ${ORANGE}%-40s${NC} ${WHITE}[${state_color}%-9s${WHITE}]${NC} ${YELLOW}(%s)${NC}\n" \
                "$resource_idx" "${drg_name:-N/A}" "$drg_state" "$drg_ocid"
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
            printf "  ${YELLOW}%2d${NC}) ${WHITE}Local Peer GW:${NC} ${ORANGE}%-40s${NC} ${WHITE}[${state_color}%-9s${WHITE}]${NC} ${YELLOW}(%s)${NC}\n" \
                "$resource_idx" "${lpg_name:-N/A}" "$lpg_state" "$lpg_ocid"
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
        
        # Fetch K8s nodes once for lookup (include taints and unschedulable status)
        local k8s_nodes_json
        k8s_nodes_json=$(kubectl get nodes -o json 2>/dev/null)
        
        # Fetch pods per node
        local pods_per_node
        pods_per_node=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running -o json 2>/dev/null | \
            jq -r '.items[] | .spec.nodeName' 2>/dev/null | sort | uniq -c | awk '{print $2"|"$1}')
        
        # Build lookup: providerID|nodeName|readyStatus|newNodeTaint|unschedulable
        local k8s_lookup
        k8s_lookup=$(echo "$k8s_nodes_json" | jq -r '
            .items[] | 
            (.spec.taints // [] | map(select(.key == "newNode")) | if length > 0 then .[0].effect else "N/A" end) as $newNodeTaint |
            (.spec.unschedulable // false) as $unschedulable |
            "\(.spec.providerID)|\(.metadata.name)|\(.status.conditions[] | select(.type=="Ready") | .status)|\($newNodeTaint)|\($unschedulable)"
        ' 2>/dev/null)
        
        # Display instances table
        echo -e "${BOLD}${WHITE}═══ Instances ═══${NC}"
        echo ""
        printf "${BOLD}%-5s %-32s %-12s %-8s %-8s %-5s %-26s %-15s %-16s %s${NC}\n" \
            "ID" "Display Name" "State" "K8s" "Cordon" "Pods" "Shape" "Avail Domain" "Created" "Instance OCID"
        print_separator 240
        
        # Sort by time-created (ascending - oldest first, newest last)
        echo "$instances_json" | jq -r '
            .data[] | 
            select(.["lifecycle-state"] != "TERMINATED") |
            "\(.["time-created"] // "N/A")|\(.["display-name"])|\(.["lifecycle-state"])|\(.shape)|\(.["availability-domain"])|\(.id)"
        ' 2>/dev/null | sort -t'|' -k1,1 | while IFS='|' read -r time_created name state shape ad ocid; do
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
            
            # Check if in K8s and get taint/cordon info
            local k8s_status="No"
            local k8s_color="$YELLOW"
            local cordon_status="-"
            local cordon_color="$GRAY"
            local pod_count="-"
            local pod_color="$GRAY"
            local k8s_node_name=""
            
            local k8s_match
            k8s_match=$(echo "$k8s_lookup" | grep "$ocid" 2>/dev/null)
            
            if [[ -n "$k8s_match" ]]; then
                local k8s_ready unschedulable
                k8s_node_name=$(echo "$k8s_match" | cut -d'|' -f2)
                k8s_ready=$(echo "$k8s_match" | cut -d'|' -f3)
                unschedulable=$(echo "$k8s_match" | cut -d'|' -f5)
                
                if [[ "$k8s_ready" == "True" ]]; then
                    k8s_status="Ready"
                    k8s_color="$GREEN"
                else
                    k8s_status="NotRdy"
                    k8s_color="$RED"
                fi
                
                # Check cordon status
                if [[ "$unschedulable" == "true" ]]; then
                    cordon_status="Cordon"
                    cordon_color="$YELLOW"
                else
                    cordon_status="-"
                    cordon_color="$GRAY"
                fi
                
                # Get pod count for this node
                local node_pods
                node_pods=$(echo "$pods_per_node" | grep "^${k8s_node_name}|" | cut -d'|' -f2)
                if [[ -n "$node_pods" ]]; then
                    pod_count="$node_pods"
                    pod_color="$CYAN"
                else
                    pod_count="0"
                    pod_color="$GRAY"
                fi
            fi
            
            # Truncate long fields (but show full OCID)
            local name_trunc="${name:0:32}"
            local shape_trunc="${shape:0:26}"
            local ad_short="${ad##*:}"
            
            # Format time_created - show date and time portion
            local time_display="$time_created"
            if [[ "$time_display" != "N/A" && -n "$time_display" ]]; then
                # Format: 2026-01-27T03:29:11.123Z -> 2026-01-27 03:29
                time_display="${time_display:0:16}"
                time_display="${time_display/T/ }"
            fi
            
            printf "${YELLOW}%-5s${NC} %-32s ${state_color}%-12s${NC} ${k8s_color}%-8s${NC} ${cordon_color}%-8s${NC} ${pod_color}%-5s${NC} %-26s %-15s ${GRAY}%-16s${NC} ${GRAY}%s${NC}\n" \
                "$iid" "$name_trunc" "$state" "$k8s_status" "$cordon_status" "$pod_count" "$shape_trunc" "$ad_short" "$time_display" "$ocid"
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
        echo -e "  ${YELLOW}i#${NC}         - View instance details (e.g., 'i1', 'i5')"
        echo -e "  ${YELLOW}ocid1...${NC}   - View instance by OCID directly"
        echo -e "  ${GREEN}p${NC}          - View all instances with OCI properties (shape, mem, boot vol, cloud-init)"
        echo -e "  ${MAGENTA}refresh${NC}    - Refresh instance list"
        echo -e "  ${CYAN}back${NC}       - Return to main menu"
        echo ""
        echo -e "${GRAY}Tip: From command line, use:${NC}"
        echo -e "${GRAY}  $0 <instance-ocid>                  # Basic info (OCI + K8s)${NC}"
        echo -e "${GRAY}  $0 <instance-ocid> --details        # Full details (network, volumes)${NC}"
        echo -e "${GRAY}  $0 <instance-ocid> --console-history # Boot logs (debug cloud-init)${NC}"
        echo ""
        echo -n -e "${BOLD}${CYAN}Enter selection [i#/ocid/p/refresh/back]: ${NC}"
        
        local input
        read -r input
        
        # Empty input goes back
        if [[ -z "$input" ]]; then
            return
        fi
        
        case "$input" in
            properties|PROPERTIES|props|p)
                display_instances_properties_view
                ;;
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
                    # Loop to handle refresh requests
                    while true; do
                        display_instance_details "$instance_ocid"
                        local ret=$?
                        [[ $ret -ne 2 ]] && break  # Exit loop unless refresh requested
                    done
                fi
                ;;
            ocid1.instance.*)
                # Direct OCID input - loop to handle refresh requests
                while true; do
                    display_instance_details "$input"
                    local ret=$?
                    [[ $ret -ne 2 ]] && break  # Exit loop unless refresh requested
                done
                ;;
            *)
                echo -e "${RED}Unknown command: $input${NC}"
                sleep 1
                ;;
        esac
    done
}

#--------------------------------------------------------------------------------
# Display all instances with OCI properties in consolidated view
# Shows: Name, State, Shape config, Boot Vol, Image, Oracle-Tags, Cloud-Init
# Uses parallel fetching and caching for boot volumes and images
#--------------------------------------------------------------------------------
display_instances_properties_view() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    local max_parallel=10  # Max parallel API calls
    
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}                                                                                    INSTANCE PROPERTIES VIEW                                                                                                                          ${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Check cache freshness (1 hour = 3600 seconds)
    local cache_max_age=3600
    local bv_cache_valid=false
    local img_cache_valid=false
    
    if [[ -f "$BOOT_VOLUME_CACHE" ]]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$BOOT_VOLUME_CACHE" 2>/dev/null || echo 0)))
        [[ $cache_age -lt $cache_max_age ]] && bv_cache_valid=true
    fi
    if [[ -f "$IMAGE_CACHE" ]]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$IMAGE_CACHE" 2>/dev/null || echo 0)))
        [[ $cache_age -lt $cache_max_age ]] && img_cache_valid=true
    fi
    
    echo -e "${YELLOW}Fetching instances...${NC}"
    
    # Fetch all instances with full details
    local instances_json
    instances_json=$(oci compute instance list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$instances_json" ]] || ! echo "$instances_json" | jq -e '.data[]' > /dev/null 2>&1; then
        echo -e "${RED}No instances found${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # Count instances
    local total_count
    total_count=$(echo "$instances_json" | jq '[.data[] | select(.["lifecycle-state"] != "TERMINATED")] | length')
    echo -e "${GREEN}Found ${total_count} instances${NC}"
    
    # Extract unique image IDs and instance OCIDs for parallel fetching
    local unique_images unique_instances
    unique_images=$(echo "$instances_json" | jq -r '.data[] | select(.["lifecycle-state"] != "TERMINATED") | .["image-id"] // empty' | sort -u | grep -v '^$')
    unique_instances=$(echo "$instances_json" | jq -r '.data[] | select(.["lifecycle-state"] != "TERMINATED") | "\(.id)|\(.["availability-domain"])"')
    
    # ========== PARALLEL BOOT VOLUME FETCHING ==========
    if [[ "$bv_cache_valid" == "true" ]]; then
        echo -e "${CYAN}Using cached boot volume data (< 1 hour old)${NC}"
    else
        echo -e "${YELLOW}Fetching boot volumes in parallel...${NC}"
        
        # Create temp directory for parallel results
        local tmp_bv_dir="/tmp/bv_fetch_$$"
        mkdir -p "$tmp_bv_dir"
        
        local bv_count=0
        local bv_total
        bv_total=$(echo "$unique_instances" | grep -c . 2>/dev/null) || bv_total=0
        [[ ! "$bv_total" =~ ^[0-9]+$ ]] && bv_total=0
        
        # Fetch boot volume attachments and details in parallel
        while IFS='|' read -r inst_ocid inst_ad; do
            [[ -z "$inst_ocid" ]] && continue
            
            # Run in background
            (
                # Get boot volume attachment - try with instance's compartment first
                local bv_attach_json
                bv_attach_json=$(oci compute boot-volume-attachment list \
                    --compartment-id "$compartment_id" \
                    --availability-domain "$inst_ad" \
                    --instance-id "$inst_ocid" \
                    --output json 2>/dev/null)
                
                local bv_id
                bv_id=$(echo "$bv_attach_json" | jq -r '.data[0]["boot-volume-id"] // empty' 2>/dev/null)
                
                if [[ -n "$bv_id" && "$bv_id" != "null" && "$bv_id" != "None" && "$bv_id" != "" ]]; then
                    # Get boot volume details using size-in-gbs and vpus-per-gb
                    local bv_json
                    bv_json=$(oci bv boot-volume get --boot-volume-id "$bv_id" --output json 2>/dev/null)
                    
                    if [[ -n "$bv_json" ]]; then
                        local bv_size bv_vpus
                        bv_size=$(echo "$bv_json" | jq -r '.data["size-in-gbs"] // empty' 2>/dev/null)
                        bv_vpus=$(echo "$bv_json" | jq -r '.data["vpus-per-gb"] // empty' 2>/dev/null)
                        
                        # Only write if we got values
                        if [[ -n "$bv_size" && "$bv_size" != "null" ]]; then
                            [[ -z "$bv_vpus" || "$bv_vpus" == "null" ]] && bv_vpus="-"
                            echo "${inst_ocid}|${bv_size}|${bv_vpus}" > "${tmp_bv_dir}/${inst_ocid##*.}"
                        fi
                    fi
                fi
            ) &
            
            ((bv_count++))
            
            # Limit parallel jobs
            if (( bv_count % max_parallel == 0 )); then
                wait
                printf "\r${GRAY}  Boot volumes: %d/%d${NC}          " "$bv_count" "$bv_total"
            fi
        done <<< "$unique_instances"
        
        # Wait for remaining jobs
        wait
        printf "\r${GRAY}  Boot volumes: %d/%d - Done${NC}          \n" "$bv_total" "$bv_total"
        
        # Consolidate results into cache
        if [[ -d "$tmp_bv_dir" ]] && ls "${tmp_bv_dir}"/* >/dev/null 2>&1; then
            cat "${tmp_bv_dir}"/* > "$BOOT_VOLUME_CACHE" 2>/dev/null
            local cached_count
            cached_count=$(wc -l < "$BOOT_VOLUME_CACHE" 2>/dev/null || echo 0)
            echo -e "${GREEN}  Cached ${cached_count} boot volumes${NC}"
        else
            echo -e "${YELLOW}  No boot volume data retrieved${NC}"
        fi
        rm -rf "$tmp_bv_dir"
    fi
    
    # ========== PARALLEL IMAGE FETCHING ==========
    if [[ "$img_cache_valid" == "true" ]]; then
        echo -e "${CYAN}Using cached image data (< 1 hour old)${NC}"
    else
        echo -e "${YELLOW}Fetching images in parallel...${NC}"
        
        local tmp_img_dir="/tmp/img_fetch_$$"
        mkdir -p "$tmp_img_dir"
        
        local img_count=0
        local img_total
        img_total=$(echo "$unique_images" | wc -l)
        
        while read -r image_id; do
            [[ -z "$image_id" ]] && continue
            
            # Check if already in cache
            if grep -q "^${image_id}|" "$IMAGE_CACHE" 2>/dev/null; then
                ((img_count++))
                continue
            fi
            
            # Run in background
            (
                local img_name
                img_name=$(oci compute image get --image-id "$image_id" \
                    --query 'data."display-name"' --raw-output 2>/dev/null) || img_name="-"
                echo "${image_id}|${img_name}" > "${tmp_img_dir}/${image_id##*.}"
            ) &
            
            ((img_count++))
            
            # Limit parallel jobs
            if (( img_count % max_parallel == 0 )); then
                wait
                printf "\r${GRAY}  Images: %d/%d${NC}          " "$img_count" "$img_total"
            fi
        done <<< "$unique_images"
        
        # Wait for remaining jobs
        wait
        printf "\r${GRAY}  Images: %d/%d - Done${NC}          \n" "$img_total" "$img_total"
        
        # Consolidate results into cache (append new entries)
        if [[ -d "$tmp_img_dir" ]]; then
            cat "${tmp_img_dir}"/* >> "$IMAGE_CACHE" 2>/dev/null
            rm -rf "$tmp_img_dir"
        fi
    fi
    
    # ========== BUILD DISPLAY DATA ==========
    echo -e "${YELLOW}Building display...${NC}"
    
    local tmp_data="/tmp/instance_props_$$"
    rm -f "$tmp_data"
    
    # Load caches into associative arrays for fast lookup
    declare -A BV_CACHE_MAP
    declare -A IMG_CACHE_MAP
    
    if [[ -f "$BOOT_VOLUME_CACHE" && -s "$BOOT_VOLUME_CACHE" ]]; then
        local bv_loaded=0
        while IFS='|' read -r inst_id bv_sz bv_vp; do
            if [[ -n "$inst_id" && -n "$bv_sz" ]]; then
                BV_CACHE_MAP["$inst_id"]="${bv_sz}|${bv_vp}"
                ((bv_loaded++))
            fi
        done < "$BOOT_VOLUME_CACHE"
        echo -e "${GRAY}  Loaded ${bv_loaded} boot volume entries from cache${NC}"
    else
        echo -e "${YELLOW}  No boot volume cache available${NC}"
    fi
    
    if [[ -f "$IMAGE_CACHE" && -s "$IMAGE_CACHE" ]]; then
        local img_loaded=0
        while IFS='|' read -r img_id img_nm; do
            if [[ -n "$img_id" ]]; then
                IMG_CACHE_MAP["$img_id"]="$img_nm"
                ((img_loaded++))
            fi
        done < "$IMAGE_CACHE"
        echo -e "${GRAY}  Loaded ${img_loaded} image entries from cache${NC}"
    fi
    
    # Process each instance using cached data
    while IFS='|' read -r ocid name state shape ocpus memory gpus net_bw max_vnics ad image_id launch_mode user_data created_by created_on; do
        [[ -z "$ocid" ]] && continue
        
        # Get boot volume from cache - use size-in-gbs and vpus-per-gb values
        local bv_size="-" bv_vpus="-"
        if [[ -n "${BV_CACHE_MAP[$ocid]:-}" ]]; then
            IFS='|' read -r bv_size bv_vpus <<< "${BV_CACHE_MAP[$ocid]}"
            # Ensure we have valid values
            [[ -z "$bv_size" || "$bv_size" == "null" ]] && bv_size="-"
            [[ -z "$bv_vpus" || "$bv_vpus" == "null" ]] && bv_vpus="-"
        fi
        
        # Get image name from cache
        local image_name="-"
        if [[ -n "$image_id" && "$image_id" != "null" && -n "${IMG_CACHE_MAP[$image_id]:-}" ]]; then
            image_name="${IMG_CACHE_MAP[$image_id]:0:35}"
        fi
        
        # Cloud-init fingerprint (last 7 chars)
        local ci_fp="-"
        if [[ -n "$user_data" && "$user_data" != "null" && "$user_data" != "" ]]; then
            ci_fp="${user_data: -7}"
        fi
        
        # Handle null values
        [[ "$gpus" == "null" || -z "$gpus" ]] && gpus="0"
        [[ "$net_bw" == "null" || -z "$net_bw" ]] && net_bw="-"
        [[ "$max_vnics" == "null" || -z "$max_vnics" ]] && max_vnics="-"
        [[ "$launch_mode" == "null" || -z "$launch_mode" ]] && launch_mode="-"
        [[ "$created_by" == "null" || -z "$created_by" ]] && created_by="-"
        [[ "$created_on" == "null" || -z "$created_on" ]] && created_on="-"
        
        # Format created_on date
        [[ "$created_on" != "-" ]] && created_on="${created_on:0:10}"
        
        # Store data
        echo "${name}|${state}|${shape}|${ocpus}|${memory}|${gpus}|${net_bw}|${max_vnics}|${bv_size}|${bv_vpus}|${image_name}|${launch_mode}|${created_by}|${created_on}|${ci_fp}" >> "$tmp_data"
        
    done < <(echo "$instances_json" | jq -r '
        .data[] | 
        select(.["lifecycle-state"] != "TERMINATED") |
        "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.shape)|\(.["shape-config"]["ocpus"] // "")|\(.["shape-config"]["memory-in-gbs"] // "")|\(.["shape-config"]["gpus"] // "0")|\(.["shape-config"]["networking-bandwidth-in-gbps"] // "")|\(.["shape-config"]["max-vnic-attachments"] // "")|\(.["availability-domain"])|\(.["image-id"] // "")|\(.["launch-mode"] // "")|\(.metadata.user_data // "")|\(.["defined-tags"]["Oracle-Tags"]["CreatedBy"] // "")|\(.["defined-tags"]["Oracle-Tags"]["CreatedOn"] // "")"
    ' 2>/dev/null)
    
    if [[ ! -f "$tmp_data" ]]; then
        echo -e "${RED}No instance data collected${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # Display header
    echo ""
    printf "${BOLD}%-35s %-8s %-22s %5s %6s %3s %6s %4s %5s %4s %-35s %-10s %-45s %-10s %-7s${NC}\n" \
        "Display Name" "State" "Shape" "OCPUs" "Mem" "GPU" "NetBW" "VNIC" "BV GB" "VPUs" "Image Name" "LaunchMode" "CreatedBy" "CreatedOn" "CI"
    print_separator 255
    
    # Display data sorted by name
    sort -t'|' -k1,1 "$tmp_data" | while IFS='|' read -r name state shape ocpus memory gpus net_bw max_vnics bv_size bv_vpus image_name launch_mode created_by created_on ci_fp; do
        # Color state
        local state_color="$GREEN"
        case "$state" in
            RUNNING) state_color="$GREEN" ;;
            STOPPED) state_color="$RED" ;;
            STARTING|STOPPING) state_color="$YELLOW" ;;
            PROVISIONING) state_color="$CYAN" ;;
            *) state_color="$WHITE" ;;
        esac
        
        # GPU display
        local gpu_disp="$gpus"
        [[ "$gpus" == "0" ]] && gpu_disp="-"
        
        # Truncate fields
        local name_t="${name:0:35}"
        local shape_t="${shape:0:22}"
        local created_by_t="${created_by:0:45}"
        
        printf "%-35s ${state_color}%-8s${NC} ${CYAN}%-22s${NC} %5s %6s ${GREEN}%3s${NC} %6s %4s %5s %4s %-35s %-10s ${BLUE}%-45s${NC} ${GRAY}%-10s${NC} ${MAGENTA}%-7s${NC}\n" \
            "$name_t" "$state" "$shape_t" "$ocpus" "$memory" "$gpu_disp" "$net_bw" "$max_vnics" "$bv_size" "$bv_vpus" "$image_name" "$launch_mode" "$created_by_t" "$created_on" "$ci_fp"
    done
    
    rm -f "$tmp_data"
    
    echo ""
    print_separator 255
    echo ""
    echo -e "${BOLD}${WHITE}Column Legend:${NC}"
    echo -e "  ${WHITE}OCPUs${NC}      - Number of OCPUs (shape-config.ocpus)"
    echo -e "  ${WHITE}Mem${NC}        - Memory in GB (shape-config.memory-in-gbs)"
    echo -e "  ${WHITE}GPU${NC}        - Number of GPUs (shape-config.gpus)"
    echo -e "  ${WHITE}NetBW${NC}      - Network bandwidth in Gbps (shape-config.networking-bandwidth-in-gbps)"
    echo -e "  ${WHITE}VNIC${NC}       - Max VNIC attachments (shape-config.max-vnic-attachments)"
    echo -e "  ${WHITE}BV GB${NC}      - Boot Volume size in GB (boot-volume.size-in-gbs)"
    echo -e "  ${WHITE}VPUs${NC}       - Boot Volume VPUs/GB (boot-volume.vpus-per-gb) [10=Balanced, 20=Higher, 30+=Ultra]"
    echo -e "  ${WHITE}LaunchMode${NC} - NATIVE, EMULATED, PARAVIRTUALIZED, or CUSTOM (instance.launch-mode)"
    echo -e "  ${BLUE}CreatedBy${NC}  - Oracle-Tags CreatedBy (defined-tags.Oracle-Tags.CreatedBy)"
    echo -e "  ${GRAY}CreatedOn${NC}  - Oracle-Tags CreatedOn date (defined-tags.Oracle-Tags.CreatedOn)"
    echo -e "  ${WHITE}CI${NC}         - Cloud-Init fingerprint (last 7 chars of metadata.user_data)"
    echo ""
    echo -e "${GRAY}Instances with matching CI fingerprints have identical cloud-init configurations${NC}"
    echo ""
    
    # Show cache info
    echo -e "${BOLD}${WHITE}Cache Info:${NC}"
    if [[ -f "$BOOT_VOLUME_CACHE" ]]; then
        local bv_cache_age=$(($(date +%s) - $(stat -c %Y "$BOOT_VOLUME_CACHE" 2>/dev/null || echo 0)))
        local bv_cache_count=$(wc -l < "$BOOT_VOLUME_CACHE" 2>/dev/null || echo 0)
        echo -e "  ${WHITE}Boot Volumes:${NC} ${bv_cache_count} cached, age: $((bv_cache_age / 60)) min"
    fi
    if [[ -f "$IMAGE_CACHE" ]]; then
        local img_cache_age=$(($(date +%s) - $(stat -c %Y "$IMAGE_CACHE" 2>/dev/null || echo 0)))
        local img_cache_count=$(wc -l < "$IMAGE_CACHE" 2>/dev/null || echo 0)
        echo -e "  ${WHITE}Images:${NC}       ${img_cache_count} cached, age: $((img_cache_age / 60)) min"
    fi
    echo ""
    echo -e "${BOLD}${WHITE}Options:${NC}"
    echo -e "  ${MAGENTA}refresh${NC} - Clear cache and re-fetch all data"
    echo -e "  ${CYAN}Enter${NC}   - Return to menu"
    echo ""
    echo -n -e "${CYAN}Action [refresh/Enter]: ${NC}"
    
    local action
    read -r action
    
    case "$action" in
        refresh|REFRESH|r|R)
            echo -e "${YELLOW}Clearing cache...${NC}"
            rm -f "$BOOT_VOLUME_CACHE" "$IMAGE_CACHE"
            echo -e "${GREEN}Cache cleared. Re-running...${NC}"
            sleep 1
            display_instances_properties_view
            ;;
        *)
            return
            ;;
    esac
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
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                                           INSTANCE DETAILS                                                     ${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    
    # Fetch instance details
    local instance_json
    instance_json=$(oci compute instance get --instance-id "$instance_ocid" --output json 2>/dev/null)
    
    if [[ -z "$instance_json" ]] || ! echo "$instance_json" | jq -e '.data' > /dev/null 2>&1; then
        echo -e "${RED}Failed to fetch instance details${NC}"
        return 1
    fi
    
    # ========== CACHE VNIC AND VOLUME DATA (fetch once) ==========
    echo -ne "${GRAY}Loading instance data...${NC}"
    
    # Cache VNIC attachments
    local cached_vnic_attachments
    cached_vnic_attachments=$(oci compute vnic-attachment list \
        --compartment-id "$compartment_id" \
        --instance-id "$instance_ocid" \
        --output json 2>/dev/null)
    
    # Get availability domain for boot volume query
    local ad_for_query
    ad_for_query=$(echo "$instance_json" | jq -r '.data["availability-domain"] // "N/A"')
    
    # Cache boot volume attachments
    local cached_boot_vol_attachments
    cached_boot_vol_attachments=$(oci compute boot-volume-attachment list \
        --compartment-id "$compartment_id" \
        --availability-domain "$ad_for_query" \
        --instance-id "$instance_ocid" \
        --output json 2>/dev/null)
    
    # Cache block volume attachments
    local cached_block_vol_attachments
    cached_block_vol_attachments=$(oci compute volume-attachment list \
        --compartment-id "$compartment_id" \
        --instance-id "$instance_ocid" \
        --output json 2>/dev/null)
    
    # Pre-fetch all individual VNIC details and build lookup JSON
    local cached_vnic_details="{}"
    local cached_subnet_names="{}"
    local cached_nsg_names="{}"
    local all_subnet_ids=""
    local all_nsg_ids=""
    
    if [[ -n "$cached_vnic_attachments" ]]; then
        local vnic_ids
        vnic_ids=$(echo "$cached_vnic_attachments" | jq -r '.data[]["vnic-id"] // empty' 2>/dev/null)
        for vnic_id in $vnic_ids; do
            [[ -z "$vnic_id" ]] && continue
            local vnic_data
            vnic_data=$(oci network vnic get --vnic-id "$vnic_id" --output json 2>/dev/null)
            if [[ -n "$vnic_data" ]]; then
                cached_vnic_details=$(echo "$cached_vnic_details" | jq --arg id "$vnic_id" --argjson data "$vnic_data" '. + {($id): $data}' 2>/dev/null)
                # Collect subnet and NSG IDs for batch lookup
                local subnet_id nsg_list
                subnet_id=$(echo "$vnic_data" | jq -r '.data["subnet-id"] // empty' 2>/dev/null)
                [[ -n "$subnet_id" ]] && all_subnet_ids="$all_subnet_ids $subnet_id"
                nsg_list=$(echo "$vnic_data" | jq -r '.data["nsg-ids"] // [] | .[]' 2>/dev/null)
                [[ -n "$nsg_list" ]] && all_nsg_ids="$all_nsg_ids $nsg_list"
            fi
        done
    fi
    echo -ne "\r${GRAY}Loading instance data.. ${NC}"
    
    # Pre-fetch subnet names and route tables
    for subnet_id in $(echo "$all_subnet_ids" | tr ' ' '\n' | sort -u); do
        [[ -z "$subnet_id" ]] && continue
        local subnet_json subnet_name rt_id rt_name
        subnet_json=$(oci network subnet get --subnet-id "$subnet_id" --output json 2>/dev/null)
        if [[ -n "$subnet_json" ]]; then
            subnet_name=$(echo "$subnet_json" | jq -r '.data["display-name"] // "-"')
            rt_id=$(echo "$subnet_json" | jq -r '.data["route-table-id"] // empty')
            rt_name="-"
            if [[ -n "$rt_id" ]]; then
                rt_name=$(oci network route-table get --rt-id "$rt_id" --query 'data."display-name"' --raw-output 2>/dev/null) || rt_name="-"
            fi
            cached_subnet_names=$(echo "$cached_subnet_names" | jq --arg id "$subnet_id" --arg name "$subnet_name" --arg rt "$rt_name" '. + {($id): {"name": $name, "rt": $rt}}' 2>/dev/null)
        fi
    done
    
    # Pre-fetch NSG names
    for nsg_id in $(echo "$all_nsg_ids" | tr ' ' '\n' | sort -u); do
        [[ -z "$nsg_id" ]] && continue
        local nsg_name
        nsg_name=$(oci network nsg get --nsg-id "$nsg_id" --query 'data."display-name"' --raw-output 2>/dev/null) || nsg_name="N/A"
        cached_nsg_names=$(echo "$cached_nsg_names" | jq --arg id "$nsg_id" --arg name "$nsg_name" '. + {($id): $name}' 2>/dev/null)
    done
    echo -ne "\r${GRAY}Loading instance data...${NC}"
    
    # Pre-fetch all individual boot volume details and build lookup JSON
    local cached_boot_vol_details="{}"
    local cached_backup_policies="{}"
    
    if [[ -n "$cached_boot_vol_attachments" ]]; then
        local bv_ids
        bv_ids=$(echo "$cached_boot_vol_attachments" | jq -r '.data[]["boot-volume-id"] // empty' 2>/dev/null)
        for bv_id in $bv_ids; do
            [[ -z "$bv_id" ]] && continue
            local bv_data
            bv_data=$(oci bv boot-volume get --boot-volume-id "$bv_id" --output json 2>/dev/null)
            if [[ -n "$bv_data" ]]; then
                cached_boot_vol_details=$(echo "$cached_boot_vol_details" | jq --arg id "$bv_id" --argjson data "$bv_data" '. + {($id): $data}' 2>/dev/null)
            fi
            # Get backup policy
            local backup_assign backup_policy="None"
            backup_assign=$(oci bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment \
                --asset-id "$bv_id" --query 'data[0]."policy-id"' --raw-output 2>/dev/null)
            if [[ -n "$backup_assign" && "$backup_assign" != "null" ]]; then
                backup_policy=$(oci bv volume-backup-policy get --policy-id "$backup_assign" --query 'data."display-name"' --raw-output 2>/dev/null) || backup_policy="Custom"
            fi
            cached_backup_policies=$(echo "$cached_backup_policies" | jq --arg id "$bv_id" --arg policy "$backup_policy" '. + {($id): $policy}' 2>/dev/null)
        done
    fi
    echo -ne "\r${GRAY}Loading instance data....${NC}"
    
    # Pre-fetch all individual block volume details and build lookup JSON
    local cached_block_vol_details="{}"
    if [[ -n "$cached_block_vol_attachments" ]]; then
        local vol_ids
        vol_ids=$(echo "$cached_block_vol_attachments" | jq -r '.data[]["volume-id"] // empty' 2>/dev/null)
        for vol_id in $vol_ids; do
            [[ -z "$vol_id" ]] && continue
            local vol_data
            vol_data=$(oci bv volume get --volume-id "$vol_id" --output json 2>/dev/null)
            if [[ -n "$vol_data" ]]; then
                cached_block_vol_details=$(echo "$cached_block_vol_details" | jq --arg id "$vol_id" --argjson data "$vol_data" '. + {($id): $data}' 2>/dev/null)
            fi
            # Get backup policy
            local backup_assign backup_policy="None"
            backup_assign=$(oci bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment \
                --asset-id "$vol_id" --query 'data[0]."policy-id"' --raw-output 2>/dev/null)
            if [[ -n "$backup_assign" && "$backup_assign" != "null" ]]; then
                backup_policy=$(oci bv volume-backup-policy get --policy-id "$backup_assign" --query 'data."display-name"' --raw-output 2>/dev/null) || backup_policy="Custom"
            fi
            cached_backup_policies=$(echo "$cached_backup_policies" | jq --arg id "$vol_id" --arg policy "$backup_policy" '. + {($id): $policy}' 2>/dev/null)
        done
    fi
    
    # Clear loading message
    echo -ne "\r\033[K"
    
    # Extract basic info
    local display_name state shape ad fd time_created launch_mode image_id
    display_name=$(echo "$instance_json" | jq -r '.data["display-name"] // "N/A"')
    state=$(echo "$instance_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    shape=$(echo "$instance_json" | jq -r '.data.shape // "N/A"')
    ad=$(echo "$instance_json" | jq -r '.data["availability-domain"] // "N/A"')
    fd=$(echo "$instance_json" | jq -r '.data["fault-domain"] // "N/A"')
    time_created=$(echo "$instance_json" | jq -r '.data["time-created"] // "N/A"')
    launch_mode=$(echo "$instance_json" | jq -r '.data["launch-mode"] // "N/A"')
    image_id=$(echo "$instance_json" | jq -r '.data["image-id"] // empty')
    
    # Extract shape config
    local shape_ocpus shape_memory_gb shape_gpus shape_gpu_desc shape_nvmes shape_network_bw shape_max_nics
    shape_ocpus=$(echo "$instance_json" | jq -r '.data["shape-config"]["ocpus"] // "N/A"')
    shape_memory_gb=$(echo "$instance_json" | jq -r '.data["shape-config"]["memory-in-gbs"] // "N/A"')
    shape_gpus=$(echo "$instance_json" | jq -r '.data["shape-config"]["gpus"] // "0"')
    shape_gpu_desc=$(echo "$instance_json" | jq -r '.data["shape-config"]["gpu-description"] // empty')
    shape_nvmes=$(echo "$instance_json" | jq -r '.data["shape-config"]["local-disks"] // "0"')
    shape_network_bw=$(echo "$instance_json" | jq -r '.data["shape-config"]["networking-bandwidth-in-gbps"] // "N/A"')
    shape_max_nics=$(echo "$instance_json" | jq -r '.data["shape-config"]["max-vnic-attachments"] // "N/A"')
    
    # Extract GPU memory cluster tag
    local gpu_mem_cluster
    gpu_mem_cluster=$(echo "$instance_json" | jq -r '.data["freeform-tags"]["oci:compute:gpumemorycluster"] // empty')
    
    # Extract compute cluster ID
    local compute_cluster_id
    compute_cluster_id=$(echo "$instance_json" | jq -r '.data["compute-cluster-id"] // empty')
    
    # Check for OKE-related tags (created by)
    local oke_cluster_id oke_nodepool_id
    oke_cluster_id=$(echo "$instance_json" | jq -r '.data["defined-tags"]["oke-apisystem"]["ClusterId"] // empty')
    oke_nodepool_id=$(echo "$instance_json" | jq -r '.data["defined-tags"]["oke-apisystem"]["NodePoolId"] // empty')
    [[ -z "$oke_cluster_id" ]] && oke_cluster_id=$(echo "$instance_json" | jq -r '.data["freeform-tags"]["oke-clusterId"] // empty')
    [[ -z "$oke_nodepool_id" ]] && oke_nodepool_id=$(echo "$instance_json" | jq -r '.data["freeform-tags"]["oke-nodePoolId"] // empty')
    
    # Check for instance pool / instance configuration
    local instance_pool_id instance_config_id
    instance_pool_id=$(echo "$instance_json" | jq -r '.data["metadata"]["oci:compute:instancepool:id"] // empty')
    instance_config_id=$(echo "$instance_json" | jq -r '.data["metadata"]["oci:compute:instanceconfiguration:id"] // empty')
    
    # Extract Oracle-Tags
    local oracle_created_by oracle_created_on
    oracle_created_by=$(echo "$instance_json" | jq -r '.data["defined-tags"]["Oracle-Tags"]["CreatedBy"] // empty')
    oracle_created_on=$(echo "$instance_json" | jq -r '.data["defined-tags"]["Oracle-Tags"]["CreatedOn"] // empty')
    
    # Color state
    local state_color="$GREEN"
    case "$state" in
        RUNNING) state_color="$GREEN" ;;
        STOPPED) state_color="$RED" ;;
        STARTING|STOPPING) state_color="$YELLOW" ;;
        PROVISIONING) state_color="$CYAN" ;;
        *) state_color="$WHITE" ;;
    esac
    
    # ========== BASIC INFO (Compact) ==========
    echo ""
    echo -e "${BOLD}${WHITE}─── Basic Info ────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    printf "${WHITE}%-10s${NC}${GREEN}%s${NC}\n" "Name:" "$display_name"
    printf "${WHITE}%-10s${NC}${YELLOW}%s${NC}\n" "OCID:" "$instance_ocid"
    printf "${WHITE}%-10s${NC}${state_color}%-12s${NC}  ${WHITE}%-10s${NC}%-22s  ${WHITE}%-8s${NC}%s\n" "State:" "$state" "Created:" "${time_created:0:19}" "Launch:" "$launch_mode"
    printf "${WHITE}%-10s${NC}%-30s  ${WHITE}%-10s${NC}%s\n" "AD:" "${ad##*:}" "FD:" "${fd##*-}"
    
    # ========== SHAPE & COMPUTE (Compact) ==========
    echo ""
    echo -e "${BOLD}${WHITE}─── Shape & Resources ─────────────────────────────────────────────────────────────────────────────────────────${NC}"
    printf "${WHITE}%-10s${NC}${CYAN}%-30s${NC}  ${WHITE}%-8s${NC}%-8s  ${WHITE}%-8s${NC}%-10s\n" "Shape:" "$shape" "OCPUs:" "$shape_ocpus" "Memory:" "${shape_memory_gb} GB"
    
    local gpu_info="N/A"
    if [[ "$shape_gpus" != "0" && "$shape_gpus" != "N/A" ]]; then
        gpu_info="${shape_gpus}x ${shape_gpu_desc:-GPU}"
    fi
    printf "${WHITE}%-10s${NC}${GREEN}%-30s${NC}  ${WHITE}%-8s${NC}%-8s  ${WHITE}%-8s${NC}%-10s\n" "GPUs:" "$gpu_info" "NetBW:" "${shape_network_bw}Gb" "VNICs:" "$shape_max_nics"
    
    # ========== IMAGE (Single Line) ==========
    echo ""
    echo -e "${BOLD}${WHITE}─── Image ─────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    if [[ -n "$image_id" ]]; then
        local image_name image_os image_os_version
        local image_json
        image_json=$(oci compute image get --image-id "$image_id" --output json 2>/dev/null)
        if [[ -n "$image_json" ]]; then
            image_name=$(echo "$image_json" | jq -r '.data["display-name"] // "N/A"')
            image_os=$(echo "$image_json" | jq -r '.data["operating-system"] // "N/A"')
            image_os_version=$(echo "$image_json" | jq -r '.data["operating-system-version"] // "N/A"')
            printf "${GRAY}%-80s %-15s %s${NC}\n" "Name" "OS" "OCID"
            printf "${GREEN}%-80s${NC} %-15s ${YELLOW}%s${NC}\n" "${image_name:0:78}" "$image_os $image_os_version" "$image_id"
        fi
    else
        echo -e "${GRAY}Image information not available${NC}"
    fi
    
    # ========== CLUSTER/OKE ASSOCIATIONS (Compact) ==========
    if [[ -n "$gpu_mem_cluster" || -n "$compute_cluster_id" || -n "$oke_cluster_id" || -n "$instance_config_id" ]]; then
        echo ""
        echo -e "${BOLD}${WHITE}─── Associations ──────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        
        if [[ -n "$gpu_mem_cluster" ]]; then
            local cluster_name
            cluster_name=$(lookup_cache "$CLUSTER_CACHE" "$gpu_mem_cluster" 2 2>/dev/null || echo "N/A")
            printf "${WHITE}%-18s${NC}${GREEN}%s${NC}\n" "GPU Mem Cluster:" "$cluster_name"
            printf "${WHITE}%-18s${NC}${YELLOW}%s${NC}\n" "" "$gpu_mem_cluster"
        fi
        if [[ -n "$compute_cluster_id" ]]; then
            local cc_name
            cc_name=$(get_compute_cluster_name "$compute_cluster_id")
            printf "${WHITE}%-18s${NC}${GREEN}%s${NC}\n" "Compute Cluster:" "$cc_name"
            printf "${WHITE}%-18s${NC}${YELLOW}%s${NC}\n" "" "$compute_cluster_id"
        fi
        if [[ -n "$oke_cluster_id" ]]; then
            printf "${WHITE}%-18s${NC}${YELLOW}%s${NC}\n" "OKE Cluster:" "$oke_cluster_id"
        fi
        if [[ -n "$oke_nodepool_id" ]]; then
            printf "${WHITE}%-18s${NC}${YELLOW}%s${NC}\n" "OKE Node Pool:" "$oke_nodepool_id"
        fi
        if [[ -n "$instance_config_id" ]]; then
            local ic_name
            ic_name=$(get_instance_config_name "$instance_config_id")
            printf "${WHITE}%-18s${NC}${GREEN}%s${NC}\n" "Instance Config:" "$ic_name"
            printf "${WHITE}%-18s${NC}${YELLOW}%s${NC}\n" "" "$instance_config_id"
        fi
    fi
    
    # ========== KUBERNETES STATUS (Compact) ==========
    echo ""
    echo -e "${BOLD}${WHITE}─── Kubernetes ────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    
    local k8s_node_info
    k8s_node_info=$(kubectl get nodes -o json 2>/dev/null | jq -r --arg ocid "$instance_ocid" '
        .items[] | select(.spec.providerID | contains($ocid)) | 
        "\(.metadata.name)|\(.status.conditions[] | select(.type=="Ready") | .status)|\(.metadata.labels["nvidia.com/gpu.clique"] // "N/A")|\(.metadata.labels["nvidia.com/gpu.present"] // "false")|\(.spec.unschedulable // false)"
    ' 2>/dev/null)
    
    if [[ -n "$k8s_node_info" ]]; then
        local k8s_node_name k8s_ready k8s_clique k8s_gpu_present k8s_unschedulable
        IFS='|' read -r k8s_node_name k8s_ready k8s_clique k8s_gpu_present k8s_unschedulable <<< "$k8s_node_info"
        
        local ready_color="$GREEN"
        [[ "$k8s_ready" != "True" ]] && ready_color="$RED"
        
        # Get pod count on this node
        local k8s_pod_count k8s_ds_pod_count
        k8s_pod_count=$(kubectl get pods --all-namespaces --field-selector=spec.nodeName="$k8s_node_name",status.phase=Running -o json 2>/dev/null | jq '.items | length' 2>/dev/null)
        [[ -z "$k8s_pod_count" ]] && k8s_pod_count="0"
        k8s_ds_pod_count=$(kubectl get pods --all-namespaces --field-selector=spec.nodeName="$k8s_node_name",status.phase=Running -o json 2>/dev/null | \
            jq '[.items[] | select(.metadata.ownerReferences[]?.kind == "DaemonSet")] | length' 2>/dev/null)
        [[ -z "$k8s_ds_pod_count" ]] && k8s_ds_pod_count="0"
        
        # Determine scheduling status
        local sched_status="Schedulable"
        local sched_color="$GREEN"
        if [[ "$k8s_unschedulable" == "true" ]]; then
            local non_ds_pods=$((k8s_pod_count - k8s_ds_pod_count))
            if [[ $non_ds_pods -le 0 ]]; then
                sched_status="Drained"
                sched_color="$RED"
            else
                sched_status="Cordoned"
                sched_color="$YELLOW"
            fi
        fi
        
        printf "${WHITE}%-10s${NC}${GREEN}%-14s${NC}  ${WHITE}%-8s${NC}${GREEN}%-22s${NC}  ${WHITE}%-8s${NC}${ready_color}%-8s${NC}  ${WHITE}%-10s${NC}${sched_color}%-12s${NC}  ${WHITE}%-6s${NC}${CYAN}%-5s${NC}\n" \
            "Status:" "In Cluster" "Node:" "$k8s_node_name" "Ready:" "$k8s_ready" "Schedule:" "$sched_status" "Pods:" "$k8s_pod_count"
        
        if [[ "$k8s_gpu_present" == "true" ]]; then
            local clique_info="N/A"
            [[ "$k8s_clique" != "N/A" ]] && clique_info="$k8s_clique"
            printf "${WHITE}%-10s${NC}${GREEN}%-14s${NC}  ${WHITE}%-8s${NC}${CYAN}%-22s${NC}\n" "GPU:" "Present" "Clique:" "$clique_info"
        fi
    else
        printf "${WHITE}%-10s${NC}${YELLOW}%-50s${NC}\n" "Status:" "Not in cluster (not joined or not found)"
    fi
    
    # ========== NETWORK / VNIC INFORMATION (Single Line per VNIC) ==========
    echo ""
    echo -e "${BOLD}${WHITE}─── Network (VNICs) ───────────────────────────────────────────────────────────────────────────────────────────${NC}"
    
    if [[ -n "$cached_vnic_attachments" ]] && echo "$cached_vnic_attachments" | jq -e '.data[]' > /dev/null 2>&1; then
        # Print header
        printf "${GRAY}%-3s %-20s %-15s %-15s %-10s %-18s %-12s %-6s %s${NC}\n" "NIC" "Name" "Private IP" "Public IP" "Subnet" "NSG" "Route Table" "VLAN" "OCID"
        
        echo "$cached_vnic_attachments" | jq -r '.data[] | "\(.["vnic-id"])|\(.["display-name"] // "N/A")|\(.["nic-index"] // 0)|\(.["vlan-tag"] // "")"' 2>/dev/null | \
        while IFS='|' read -r vnic_id vnic_attach_name nic_index vlan_tag; do
            [[ -z "$vnic_id" ]] && continue
            
            # Get VNIC details from cache
            local vnic_json
            vnic_json=$(echo "$cached_vnic_details" | jq --arg id "$vnic_id" '.[$id]' 2>/dev/null)
            
            if [[ -n "$vnic_json" && "$vnic_json" != "null" ]] && echo "$vnic_json" | jq -e '.data' > /dev/null 2>&1; then
                local vnic_name private_ip public_ip subnet_id mac_addr is_primary
                vnic_name=$(echo "$vnic_json" | jq -r '.data["display-name"] // "N/A"')
                private_ip=$(echo "$vnic_json" | jq -r '.data["private-ip"] // "N/A"')
                public_ip=$(echo "$vnic_json" | jq -r '.data["public-ip"] // empty')
                subnet_id=$(echo "$vnic_json" | jq -r '.data["subnet-id"] // "N/A"')
                mac_addr=$(echo "$vnic_json" | jq -r '.data["mac-address"] // "N/A"')
                is_primary=$(echo "$vnic_json" | jq -r '.data["is-primary"] // false')
                
                # Get NSG names from cache
                local nsg_ids nsg_names=""
                nsg_ids=$(echo "$vnic_json" | jq -r '.data["nsg-ids"] // [] | .[]' 2>/dev/null)
                if [[ -n "$nsg_ids" ]]; then
                    while read -r nsg_id; do
                        [[ -z "$nsg_id" ]] && continue
                        local nsg_name
                        nsg_name=$(echo "$cached_nsg_names" | jq -r --arg id "$nsg_id" '.[$id] // "N/A"' 2>/dev/null)
                        [[ "$nsg_name" == "null" ]] && nsg_name="N/A"
                        if [[ -n "$nsg_names" ]]; then
                            nsg_names="${nsg_names},${nsg_name}"
                        else
                            nsg_names="$nsg_name"
                        fi
                    done <<< "$nsg_ids"
                fi
                [[ -z "$nsg_names" ]] && nsg_names="-"
                
                # Get subnet name from cache
                local subnet_name="-"
                local route_table_name="-"
                if [[ "$subnet_id" != "N/A" && -n "$subnet_id" ]]; then
                    subnet_name=$(echo "$cached_subnet_names" | jq -r --arg id "$subnet_id" '.[$id].name // "-"' 2>/dev/null)
                    route_table_name=$(echo "$cached_subnet_names" | jq -r --arg id "$subnet_id" '.[$id].rt // "-"' 2>/dev/null)
                    [[ "$subnet_name" == "null" ]] && subnet_name="-"
                    [[ "$route_table_name" == "null" ]] && route_table_name="-"
                fi
                
                local nic_display="$nic_index"
                [[ "$is_primary" == "true" ]] && nic_display="${nic_index}*"
                
                # Format public IP and VLAN display
                local pub_ip_display="-"
                [[ -n "$public_ip" && "$public_ip" != "null" ]] && pub_ip_display="$public_ip"
                local vlan_display="-"
                [[ -n "$vlan_tag" ]] && vlan_display="$vlan_tag"
                
                # Single line with all info
                printf "%-3s ${GREEN}%-20s${NC} ${CYAN}%-15s${NC} ${CYAN}%-15s${NC} %-10s %-18s %-12s %-6s ${YELLOW}%s${NC}\n" \
                    "$nic_display" "${vnic_name:0:18}" "$private_ip" "$pub_ip_display" "${subnet_name:0:8}" "${nsg_names:0:16}" "${route_table_name:0:10}" "$vlan_display" "$vnic_id"
            fi
        done
    else
        echo -e "${YELLOW}No VNICs found${NC}"
    fi
    
    # ========== BOOT VOLUME (with extended details) ==========
    echo ""
    echo -e "${BOLD}${WHITE}─── Boot Volume ───────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    
    if [[ -n "$cached_boot_vol_attachments" ]] && echo "$cached_boot_vol_attachments" | jq -e '.data[]' > /dev/null 2>&1; then
        # Print header (aligned with block volumes)
        printf "${GRAY}%-24s %-9s %-5s %-3s %-5s %-6s %-8s %-4s %-4s %-4s %-6s %s${NC}\n" "Name" "State" "Size" "VPU" "Type" "Backup" "BkupMgd" "Repl" "VGrp" "Hydr" "EncKey" "OCID"
        
        echo "$cached_boot_vol_attachments" | jq -r '.data[] | "\(.["boot-volume-id"])|\(.["lifecycle-state"])"' 2>/dev/null | \
        while IFS='|' read -r bv_id bv_attach_state; do
            [[ -z "$bv_id" ]] && continue
            
            # Get boot volume details from cache
            local bv_json
            bv_json=$(echo "$cached_boot_vol_details" | jq --arg id "$bv_id" '.[$id]' 2>/dev/null)
            
            if [[ -n "$bv_json" && "$bv_json" != "null" ]] && echo "$bv_json" | jq -e '.data' > /dev/null 2>&1; then
                local bv_name bv_state bv_size_gb bv_vpus
                bv_name=$(echo "$bv_json" | jq -r '.data["display-name"] // "N/A"')
                bv_state=$(echo "$bv_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                bv_size_gb=$(echo "$bv_json" | jq -r '.data["size-in-gbs"] // "N/A"')
                bv_vpus=$(echo "$bv_json" | jq -r '.data["vpus-per-gb"] // "N/A"')
                
                # Get additional fields
                local kms_key_id volume_group_id is_hydrated
                kms_key_id=$(echo "$bv_json" | jq -r '.data["kms-key-id"] // empty')
                volume_group_id=$(echo "$bv_json" | jq -r '.data["volume-group-id"] // empty')
                is_hydrated=$(echo "$bv_json" | jq -r '.data["is-hydrated"] // "N/A"')
                
                # Get backup policy from cache
                local backup_policy="None"
                local cached_policy
                cached_policy=$(echo "$cached_backup_policies" | jq -r --arg id "$bv_id" '.[$id] // "None"' 2>/dev/null)
                [[ -n "$cached_policy" && "$cached_policy" != "null" ]] && backup_policy="$cached_policy"
                
                # Backup managed by: Volume (direct) or VolGroup (if in volume group)
                local backup_managed="Volume"
                [[ -n "$volume_group_id" ]] && backup_managed="VolGroup"
                
                # Check cross-region replication
                local repl_status="-"
                local replicas
                replicas=$(echo "$bv_json" | jq -r '.data["boot-volume-replicas"] // [] | length' 2>/dev/null)
                [[ "$replicas" -gt 0 ]] && repl_status="Yes"
                
                # Format displays
                local bv_state_color="$GREEN"
                [[ "$bv_state" != "AVAILABLE" ]] && bv_state_color="$YELLOW"
                
                # Encryption: Oracle managed (no kms-key-id) or Customer (has kms-key-id/Vault)
                local enc_display="Oracle"
                [[ -n "$kms_key_id" ]] && enc_display="Cust"
                
                local vg_display="-"
                [[ -n "$volume_group_id" ]] && vg_display="Yes"
                
                local hydr_display="-"
                [[ "$is_hydrated" == "true" ]] && hydr_display="Yes"
                [[ "$is_hydrated" == "false" ]] && hydr_display="No"
                
                printf "${GREEN}%-24s${NC} ${bv_state_color}%-9s${NC} %-5s %-3s %-5s %-6s %-8s %-4s %-4s %-4s %-6s ${YELLOW}%s${NC}\n" \
                    "${bv_name:0:22}" "$bv_state" "${bv_size_gb}GB" "$bv_vpus" "boot" "${backup_policy:0:6}" "$backup_managed" "$repl_status" "$vg_display" "$hydr_display" "$enc_display" "$bv_id"
            fi
        done
    else
        echo -e "${YELLOW}No boot volume found${NC}"
    fi
    
    # ========== BLOCK VOLUMES (with extended details) ==========
    echo ""
    echo -e "${BOLD}${WHITE}─── Block Volumes ─────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    
    local vol_count=0
    if [[ -n "$cached_block_vol_attachments" ]] && echo "$cached_block_vol_attachments" | jq -e '.data[]' > /dev/null 2>&1; then
        # Print header (aligned with boot volume)
        printf "${GRAY}%-24s %-9s %-5s %-3s %-5s %-6s %-8s %-4s %-4s %-4s %-6s %s${NC}\n" "Name" "State" "Size" "VPU" "Type" "Backup" "BkupMgd" "Repl" "VGrp" "Hydr" "EncKey" "OCID"
        
        while IFS='|' read -r vol_id attach_state attach_type device is_readonly; do
            [[ -z "$vol_id" ]] && continue
            ((vol_count++))
            
            # Get block volume details from cache
            local vol_json
            vol_json=$(echo "$cached_block_vol_details" | jq --arg id "$vol_id" '.[$id]' 2>/dev/null)
            
            if [[ -n "$vol_json" && "$vol_json" != "null" ]] && echo "$vol_json" | jq -e '.data' > /dev/null 2>&1; then
                local vol_name vol_state vol_size_gb vol_vpus is_hydrated
                vol_name=$(echo "$vol_json" | jq -r '.data["display-name"] // "N/A"')
                vol_state=$(echo "$vol_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                vol_size_gb=$(echo "$vol_json" | jq -r '.data["size-in-gbs"] // "N/A"')
                vol_vpus=$(echo "$vol_json" | jq -r '.data["vpus-per-gb"] // "N/A"')
                is_hydrated=$(echo "$vol_json" | jq -r '.data["is-hydrated"] // "N/A"')
                
                # Get additional fields
                local kms_key_id volume_group_id
                kms_key_id=$(echo "$vol_json" | jq -r '.data["kms-key-id"] // empty')
                volume_group_id=$(echo "$vol_json" | jq -r '.data["volume-group-id"] // empty')
                
                # Get backup policy from cache
                local backup_policy="None"
                local cached_policy
                cached_policy=$(echo "$cached_backup_policies" | jq -r --arg id "$vol_id" '.[$id] // "None"' 2>/dev/null)
                [[ -n "$cached_policy" && "$cached_policy" != "null" ]] && backup_policy="$cached_policy"
                
                # Backup managed by: Volume (direct) or VolGroup (if in volume group)
                local backup_managed="Volume"
                [[ -n "$volume_group_id" ]] && backup_managed="VolGroup"
                
                # Check cross-region replication
                local repl_status="-"
                local replicas
                replicas=$(echo "$vol_json" | jq -r '.data["block-volume-replicas"] // [] | length' 2>/dev/null)
                [[ "$replicas" -gt 0 ]] && repl_status="Yes"
                
                # Format displays
                local vol_state_color="$GREEN"
                [[ "$vol_state" != "AVAILABLE" ]] && vol_state_color="$YELLOW"
                
                local name_display="${vol_name:0:22}"
                [[ "$is_readonly" == "true" ]] && name_display="${vol_name:0:19}*RO"
                
                # Encryption: Oracle managed (no kms-key-id) or Customer (has kms-key-id/Vault)
                local enc_display="Oracle"
                [[ -n "$kms_key_id" ]] && enc_display="Cust"
                
                local vg_display="-"
                [[ -n "$volume_group_id" ]] && vg_display="Yes"
                
                local hydr_display="-"
                [[ "$is_hydrated" == "true" ]] && hydr_display="Yes"
                [[ "$is_hydrated" == "false" ]] && hydr_display="No"
                
                printf "${GREEN}%-24s${NC} ${vol_state_color}%-9s${NC} %-5s %-3s %-5s %-6s %-8s %-4s %-4s %-4s %-6s ${YELLOW}%s${NC}\n" \
                    "$name_display" "$vol_state" "${vol_size_gb}GB" "$vol_vpus" "$attach_type" "${backup_policy:0:6}" "$backup_managed" "$repl_status" "$vg_display" "$hydr_display" "$enc_display" "$vol_id"
            fi
        done < <(echo "$cached_block_vol_attachments" | jq -r '.data[] | "\(.["volume-id"])|\(.["lifecycle-state"])|\(.["attachment-type"])|\(.device // "N/A")|\(.["is-read-only"] // false)"' 2>/dev/null)
    fi
    
    [[ $vol_count -eq 0 ]] && echo -e "${GRAY}No block volumes attached${NC}"
    
    # Check for user_data (cloud-init)
    local user_data_b64
    user_data_b64=$(echo "$instance_json" | jq -r '.data.metadata.user_data // empty')
    
    local has_cloud_init="false"
    if [[ -n "$user_data_b64" ]]; then
        has_cloud_init="true"
        local ud_decoded_size
        ud_decoded_size=$(echo "$user_data_b64" | base64 -d 2>/dev/null | wc -c)
        echo ""
        echo -e "${BOLD}${WHITE}─── Cloud-Init ────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        local gzip_indicator=""
        is_user_data_gzip "$user_data_b64" && gzip_indicator=" (gzip)"
        printf "${WHITE}%-10s${NC}${GREEN}%-15s${NC}  ${WHITE}%-8s${NC}%-15s\n" "Status:" "Present${gzip_indicator}" "Size:" "~${ud_decoded_size} bytes"
    fi
    
    # Check if in K8s (do once, before loop)
    local k8s_node_name=""
    k8s_node_name=$(kubectl get nodes -o json 2>/dev/null | jq -r --arg ocid "$instance_ocid" '.items[] | select(.spec.providerID | contains($ocid)) | .metadata.name' 2>/dev/null)
    
    # ========== ACTIONS LOOP ==========
    while true; do
        # Show actions menu
        echo ""
        echo -e "${BOLD}${WHITE}─── Actions ───────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        
        # Line 0: Refresh/view details
        echo -e "  ${GREEN}r${NC}) Refresh instance details"
        
        # Line 1: Cloud-init + Console history
        if [[ "$has_cloud_init" == "true" ]]; then
            echo -e "  ${MAGENTA}1${NC}) View cloud-init    ${MAGENTA}2${NC}) Save cloud-init    ${MAGENTA}3${NC}) Compare cloud-init    ${YELLOW}4${NC}) Console history"
        else
            echo -e "  ${GRAY}1) View cloud-init    2) Save cloud-init    3) Compare cloud-init${NC}    ${YELLOW}4${NC}) Console history"
        fi
        
        # Line 2: Instance lifecycle actions
        echo -e "  ${CYAN}5${NC}) Reboot             ${CYAN}6${NC}) Force reboot       ${CYAN}7${NC}) Stop instance         ${CYAN}8${NC}) Start instance     ${RED}9${NC}) ${RED}TERMINATE${NC}"
        
        # Line 3: K8s node actions (only if in K8s)
        if [[ -n "$k8s_node_name" ]]; then
            echo -e "  ${BLUE}d${NC}) Drain K8s node     ${BLUE}c${NC}) Cordon node        ${BLUE}u${NC}) Uncordon node"
        fi
        
        echo ""
        echo -e "  ${WHITE}Enter${NC}) Return to list"
        echo ""
        echo -n -e "${CYAN}Select [r/1-9/d/c/u/Enter]: ${NC}"
        
        local action
        read -r action
        
        case "$action" in
        r|R|refresh|REFRESH|details|DETAILS)
            # Re-display instance details by calling self recursively (but without re-fetching)
            # Actually, just break and let the caller loop handle it by re-calling display_instance_details
            echo ""
            echo -e "${YELLOW}Refreshing instance details...${NC}"
            # Return special code to indicate refresh
            return 2
            ;;
        1|cloud-init|cloudinit|ci|view|VIEW)
            if [[ "$has_cloud_init" == "true" ]]; then
                echo ""
                echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
                echo -e "${BOLD}${MAGENTA}                                    CLOUD-INIT USER-DATA                                                       ${NC}"
                echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
                echo -e "${GRAY}Instance: ${WHITE}$display_name${NC}"
                echo -e "${GRAY}OCID:     ${YELLOW}$instance_ocid${NC}"
                echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
                echo ""
                
                # Check if gzip compressed and show message
                if is_user_data_gzip "$user_data_b64"; then
                    echo -e "${GRAY}(gzip compressed - decompressing)${NC}"
                    echo ""
                fi
                
                # Decode and display (handles gzip)
                decode_user_data "$user_data_b64"
                
                echo ""
                echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -n -e "${CYAN}Press Enter to continue...${NC}"
                read -r
            else
                echo -e "${YELLOW}No cloud-init user-data found for this instance${NC}"
                sleep 1
            fi
            ;;
        2|save|SAVE|s|S)
            if [[ "$has_cloud_init" == "true" ]]; then
                local safe_name
                safe_name=$(echo "$display_name" | tr ' ' '_' | tr -cd '[:alnum:]_-')
                local filename="${safe_name}_cloud-init.yml"
                
                echo ""
                echo -n -e "${CYAN}Save as [${filename}]: ${NC}"
                local custom_filename
                read -r custom_filename
                [[ -n "$custom_filename" ]] && filename="$custom_filename"
                
                local gzip_msg=""
                if is_user_data_gzip "$user_data_b64"; then
                    gzip_msg=" ${GRAY}(decompressed from gzip)${NC}"
                fi
                
                if decode_user_data_to_file "$user_data_b64" "$filename"; then
                    echo -e "${GREEN}✓ Cloud-init saved to: ${WHITE}$(pwd)/${filename}${NC}${gzip_msg}"
                else
                    echo -e "${RED}Failed to save cloud-init${NC}"
                fi
                echo ""
                echo -n -e "${CYAN}Press Enter to continue...${NC}"
                read -r
            else
                echo -e "${YELLOW}No cloud-init user-data found for this instance${NC}"
                sleep 1
            fi
            ;;
        3|compare|COMPARE)
            if [[ "$has_cloud_init" == "true" ]]; then
                compare_instance_cloud_init "$instance_ocid" "$display_name" "$user_data_b64"
            else
                echo -e "${YELLOW}No cloud-init user-data found for this instance${NC}"
                sleep 1
            fi
            ;;
        4|console|CONSOLE|con|CON|history|HISTORY)
            capture_console_history "$instance_ocid" "$display_name"
            ;;
        5|reboot|REBOOT)
            echo ""
            echo -e "${YELLOW}Rebooting instance ${GREEN}$display_name${NC}${YELLOW}...${NC}"
            echo -n -e "${CYAN}Confirm reboot? (yes/no): ${NC}"
            local confirm
            read -r confirm
            if [[ "$confirm" == "yes" ]]; then
                log_action "REBOOT" "oci compute instance action --instance-id $instance_ocid --action SOFTRESET"
                if oci compute instance action --instance-id "$instance_ocid" --action SOFTRESET 2>/dev/null; then
                    echo -e "${GREEN}✓ Reboot initiated successfully${NC}"
                    log_action_result "SUCCESS" "Instance $display_name reboot initiated"
                else
                    echo -e "${RED}✗ Failed to reboot instance${NC}"
                    log_action_result "FAILED" "Instance $display_name reboot failed"
                fi
            else
                echo -e "${YELLOW}Reboot cancelled${NC}"
            fi
            echo ""
            echo -n -e "${CYAN}Press Enter to continue...${NC}"
            read -r
            ;;
        6|force|FORCE)
            echo ""
            echo -e "${YELLOW}Force rebooting instance ${GREEN}$display_name${NC}${YELLOW}...${NC}"
            echo -e "${RED}WARNING: This is a hard reset and may cause data loss!${NC}"
            echo -n -e "${CYAN}Confirm force reboot? (yes/no): ${NC}"
            local confirm
            read -r confirm
            if [[ "$confirm" == "yes" ]]; then
                log_action "FORCE_REBOOT" "oci compute instance action --instance-id $instance_ocid --action RESET"
                if oci compute instance action --instance-id "$instance_ocid" --action RESET 2>/dev/null; then
                    echo -e "${GREEN}✓ Force reboot initiated successfully${NC}"
                    log_action_result "SUCCESS" "Instance $display_name force reboot initiated"
                else
                    echo -e "${RED}✗ Failed to force reboot instance${NC}"
                    log_action_result "FAILED" "Instance $display_name force reboot failed"
                fi
            else
                echo -e "${YELLOW}Force reboot cancelled${NC}"
            fi
            echo ""
            echo -n -e "${CYAN}Press Enter to continue...${NC}"
            read -r
            ;;
        7|stop|STOP)
            echo ""
            echo -e "${YELLOW}Stopping instance ${GREEN}$display_name${NC}${YELLOW}...${NC}"
            echo -n -e "${CYAN}Confirm stop? (yes/no): ${NC}"
            local confirm
            read -r confirm
            if [[ "$confirm" == "yes" ]]; then
                log_action "STOP" "oci compute instance action --instance-id $instance_ocid --action SOFTSTOP"
                if oci compute instance action --instance-id "$instance_ocid" --action SOFTSTOP 2>/dev/null; then
                    echo -e "${GREEN}✓ Stop initiated successfully${NC}"
                    log_action_result "SUCCESS" "Instance $display_name stop initiated"
                else
                    echo -e "${RED}✗ Failed to stop instance${NC}"
                    log_action_result "FAILED" "Instance $display_name stop failed"
                fi
            else
                echo -e "${YELLOW}Stop cancelled${NC}"
            fi
            echo ""
            echo -n -e "${CYAN}Press Enter to continue...${NC}"
            read -r
            ;;
        8|start|START)
            echo ""
            echo -e "${YELLOW}Starting instance ${GREEN}$display_name${NC}${YELLOW}...${NC}"
            echo -n -e "${CYAN}Confirm start? (yes/no): ${NC}"
            local confirm
            read -r confirm
            if [[ "$confirm" == "yes" ]]; then
                log_action "START" "oci compute instance action --instance-id $instance_ocid --action START"
                if oci compute instance action --instance-id "$instance_ocid" --action START 2>/dev/null; then
                    echo -e "${GREEN}✓ Start initiated successfully${NC}"
                    log_action_result "SUCCESS" "Instance $display_name start initiated"
                else
                    echo -e "${RED}✗ Failed to start instance${NC}"
                    log_action_result "FAILED" "Instance $display_name start failed"
                fi
            else
                echo -e "${YELLOW}Start cancelled${NC}"
            fi
            echo ""
            echo -n -e "${CYAN}Press Enter to continue...${NC}"
            read -r
            ;;
        9|terminate|TERMINATE)
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║                    ⚠️  WARNING: TERMINATE  ⚠️                   ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${RED}This will PERMANENTLY DELETE the instance:${NC}"
            echo -e "  Name: ${GREEN}$display_name${NC}"
            echo -e "  OCID: ${YELLOW}$instance_ocid${NC}"
            echo ""
            echo -e "${RED}This action cannot be undone!${NC}"
            echo ""
            
            if [[ -n "$k8s_node_name" ]]; then
                echo -e "${YELLOW}⚠️  This instance is a Kubernetes node: ${CYAN}$k8s_node_name${NC}"
                echo -e "${YELLOW}   Consider draining the node first (option d)${NC}"
                echo ""
            fi
            
            echo -n -e "${RED}Type 'TERMINATE' to confirm deletion: ${NC}"
            local confirm
            read -r confirm
            if [[ "$confirm" == "TERMINATE" ]]; then
                echo ""
                echo -e "${YELLOW}Terminating instance...${NC}"
                log_action "TERMINATE" "oci compute instance terminate --instance-id $instance_ocid --preserve-boot-volume false --force"
                if oci compute instance terminate --instance-id "$instance_ocid" --preserve-boot-volume false --force 2>/dev/null; then
                    echo -e "${GREEN}✓ Terminate initiated successfully${NC}"
                    echo -e "${YELLOW}Instance will be deleted. Boot volume will also be deleted.${NC}"
                    log_action_result "SUCCESS" "Instance $display_name terminate initiated"
                else
                    echo -e "${RED}✗ Failed to terminate instance${NC}"
                    log_action_result "FAILED" "Instance $display_name terminate failed"
                fi
            else
                echo -e "${YELLOW}Termination cancelled${NC}"
            fi
            echo ""
            echo -n -e "${CYAN}Press Enter to continue...${NC}"
            read -r
            ;;
        d|D|drain|DRAIN)
            if [[ -z "$k8s_node_name" ]]; then
                echo -e "${RED}This instance is not a Kubernetes node${NC}"
                sleep 1
            else
                echo ""
                echo -e "${YELLOW}Draining Kubernetes node ${GREEN}$k8s_node_name${NC}${YELLOW}...${NC}"
                echo -e "${WHITE}This will evict all pods (except DaemonSets) from the node.${NC}"
                echo ""
                echo -n -e "${CYAN}Confirm drain? (yes/no): ${NC}"
                local confirm
                read -r confirm
                if [[ "$confirm" == "yes" ]]; then
                    echo ""
                    log_action "K8S_DRAIN" "kubectl drain $k8s_node_name --ignore-daemonsets --delete-emptydir-data"
                    if kubectl drain "$k8s_node_name" --ignore-daemonsets --delete-emptydir-data 2>&1; then
                        echo -e "${GREEN}✓ Node drained successfully${NC}"
                        log_action_result "SUCCESS" "Node $k8s_node_name drained"
                    else
                        echo -e "${RED}✗ Failed to drain node (some pods may not be evictable)${NC}"
                        log_action_result "FAILED" "Node $k8s_node_name drain failed"
                    fi
                else
                    echo -e "${YELLOW}Drain cancelled${NC}"
                fi
                echo ""
                echo -n -e "${CYAN}Press Enter to continue...${NC}"
                read -r
            fi
            ;;
        c|C|cordon|CORDON)
            if [[ -z "$k8s_node_name" ]]; then
                echo -e "${RED}This instance is not a Kubernetes node${NC}"
                sleep 1
            else
                echo ""
                echo -e "${YELLOW}Cordoning Kubernetes node ${GREEN}$k8s_node_name${NC}${YELLOW}...${NC}"
                echo -e "${WHITE}This marks the node as unschedulable (existing pods continue running).${NC}"
                echo ""
                echo -n -e "${CYAN}Confirm cordon? (yes/no): ${NC}"
                local confirm
                read -r confirm
                if [[ "$confirm" == "yes" ]]; then
                    log_action "K8S_CORDON" "kubectl cordon $k8s_node_name"
                    if kubectl cordon "$k8s_node_name" 2>&1; then
                        echo -e "${GREEN}✓ Node cordoned successfully${NC}"
                        log_action_result "SUCCESS" "Node $k8s_node_name cordoned"
                    else
                        echo -e "${RED}✗ Failed to cordon node${NC}"
                        log_action_result "FAILED" "Node $k8s_node_name cordon failed"
                    fi
                else
                    echo -e "${YELLOW}Cordon cancelled${NC}"
                fi
                echo ""
                echo -n -e "${CYAN}Press Enter to continue...${NC}"
                read -r
            fi
            ;;
        u|U|uncordon|UNCORDON)
            if [[ -z "$k8s_node_name" ]]; then
                echo -e "${RED}This instance is not a Kubernetes node${NC}"
                sleep 1
            else
                echo ""
                echo -e "${YELLOW}Uncordoning Kubernetes node ${GREEN}$k8s_node_name${NC}${YELLOW}...${NC}"
                echo -e "${WHITE}This marks the node as schedulable again.${NC}"
                echo ""
                echo -n -e "${CYAN}Confirm uncordon? (yes/no): ${NC}"
                local confirm
                read -r confirm
                if [[ "$confirm" == "yes" ]]; then
                    log_action "K8S_UNCORDON" "kubectl uncordon $k8s_node_name"
                    if kubectl uncordon "$k8s_node_name" 2>&1; then
                        echo -e "${GREEN}✓ Node uncordoned successfully${NC}"
                        log_action_result "SUCCESS" "Node $k8s_node_name uncordoned"
                    else
                        echo -e "${RED}✗ Failed to uncordon node${NC}"
                        log_action_result "FAILED" "Node $k8s_node_name uncordon failed"
                    fi
                else
                    echo -e "${YELLOW}Uncordon cancelled${NC}"
                fi
                echo ""
                echo -n -e "${CYAN}Press Enter to continue...${NC}"
                read -r
            fi
            ;;
        *)
            # Return to instance list (exit the actions loop)
            break
            ;;
    esac
    done  # End of actions loop
}

#--------------------------------------------------------------------------------
# Interactive console history - entry point from instance details menu
# Args: $1 = instance OCID, $2 = instance display name
#--------------------------------------------------------------------------------
capture_console_history() {
    local instance_ocid="$1"
    local instance_name="$2"
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    echo ""
    echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${YELLOW}                                         CONSOLE HISTORY                                                        ${NC}"
    echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${WHITE}Instance:${NC} ${GREEN}$instance_name${NC}"
    echo -e "${WHITE}OCID:${NC}     ${YELLOW}$instance_ocid${NC}"
    echo ""
    
    # Check for existing console history captures
    echo -e "${YELLOW}Checking for existing console history captures...${NC}"
    
    local existing_history
    existing_history=$(oci --region "$region" compute console-history list \
        --compartment-id "$compartment_id" \
        --instance-id "$instance_ocid" \
        --lifecycle-state "SUCCEEDED" \
        --sort-by "TIMECREATED" \
        --sort-order "DESC" \
        --limit 5 \
        --output json 2>/dev/null)
    
    local history_count=0
    [[ -n "$existing_history" ]] && history_count=$(echo "$existing_history" | jq -r '.data | length' 2>/dev/null) || history_count=0
    [[ ! "$history_count" =~ ^[0-9]+$ ]] && history_count=0
    
    if [[ $history_count -gt 0 ]]; then
        echo ""
        echo -e "${WHITE}Recent console history captures:${NC}"
        echo ""
        
        declare -a HISTORY_LIST=()
        local idx=0
        
        printf "  ${GRAY}%-4s %-25s %-20s${NC}\n" "#" "Time Created" "State"
        echo -e "  ${GRAY}────────────────────────────────────────────────────────────${NC}"
        
        while IFS='|' read -r hist_id hist_time hist_state; do
            [[ -z "$hist_id" ]] && continue
            ((idx++))
            HISTORY_LIST+=("$hist_id")
            printf "  ${YELLOW}%-4s${NC} ${WHITE}%-25s${NC} ${GREEN}%-20s${NC}\n" "${idx})" "${hist_time:0:19}" "$hist_state"
        done < <(echo "$existing_history" | jq -r '.data[] | "\(.id)|\(.["time-created"])|\(.["lifecycle-state"])"' 2>/dev/null)
        
        echo ""
        echo -e "  ${CYAN}n${NC}) Capture new console history"
        echo -e "  ${WHITE}b${NC}) Back"
        echo ""
        echo -n -e "${CYAN}Select existing capture [1-${idx}] or 'n' for new: ${NC}"
        local choice
        read -r choice
        
        if [[ "$choice" == "n" || "$choice" == "N" ]]; then
            # Capture new using unified function (auto_cleanup=true, interactive=true)
            fetch_and_display_console_history "$instance_ocid" "$region" "$instance_name" "true" "true"
            echo ""
            echo -n -e "${CYAN}Press Enter to continue...${NC}"
            read -r
        elif [[ "$choice" == "b" || "$choice" == "B" || -z "$choice" ]]; then
            return
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#HISTORY_LIST[@]} ]]; then
            local selected_id="${HISTORY_LIST[$((choice-1))]}"
            # Display existing history content
            _display_existing_console_history "$selected_id" "$instance_name" "$region"
            echo ""
            echo -n -e "${CYAN}Press Enter to continue...${NC}"
            read -r
        else
            echo -e "${RED}Invalid selection${NC}"
            sleep 1
        fi
    else
        echo ""
        echo -e "${GRAY}No existing console history captures found.${NC}"
        echo ""
        # Automatically capture new console history using unified function
        fetch_and_display_console_history "$instance_ocid" "$region" "$instance_name" "true" "true"
        echo ""
        echo -n -e "${CYAN}Press Enter to continue...${NC}"
        read -r
    fi
}

#--------------------------------------------------------------------------------
# Display existing console history content (for viewing previously captured history)
# Args: $1 = console history OCID, $2 = instance display name, $3 = region
#--------------------------------------------------------------------------------
_display_existing_console_history() {
    local history_id="$1"
    local instance_name="$2"
    local region="${3:-${EFFECTIVE_REGION:-$REGION}}"
    
    echo ""
    echo -e "${YELLOW}Fetching console output...${NC}"
    
    # Build the command (for display)
    local cmd="oci --region \"$region\" compute console-history get-content --instance-console-history-id \"$history_id\" --length 10000000 --file -"
    echo -e "${GRAY}Command: ${cmd}${NC}"
    echo ""
    
    # Use temp file for reliability
    local temp_output temp_error
    temp_output=$(mktemp)
    temp_error=$(mktemp)
    
    # Capture raw output for display if empty
    local raw_output
    raw_output=$(oci --region "$region" compute console-history get-content \
        --instance-console-history-id "$history_id" \
        --length 10000000 \
        --file "$temp_output" 2>&1)
    local exit_code=$?
    
    echo -e "${BOLD}${CYAN}─── Console Output ───────────────────────────────────────────────────────────────${NC}"
    echo ""
    
    if [[ $exit_code -eq 0 ]]; then
        if [[ -s "$temp_output" ]]; then
            cat "$temp_output"
            echo ""
            echo -e "${BOLD}${CYAN}─── End of Console Output ────────────────────────────────────────────────────────${NC}"
            echo ""
            
            # Option to save
            echo -n -e "${CYAN}Save to file? [y/N]: ${NC}"
            local save_choice
            read -r save_choice
            
            if [[ "$save_choice" =~ ^[Yy] ]]; then
                local safe_name
                safe_name=$(echo "$instance_name" | tr ' ' '_' | tr -cd '[:alnum:]_-')
                local filename="${safe_name}_console_$(date +%Y%m%d_%H%M%S).log"
                
                echo -n -e "${CYAN}Filename [${filename}]: ${NC}"
                local custom_filename
                read -r custom_filename
                [[ -n "$custom_filename" ]] && filename="$custom_filename"
                
                if cp "$temp_output" "$filename" 2>/dev/null; then
                    echo -e "${GREEN}✓ Console output saved to: ${WHITE}$(pwd)/${filename}${NC}"
                else
                    echo -e "${RED}Failed to save console output${NC}"
                fi
            fi
        else
            echo -e "${YELLOW}(Console history is empty - no serial console output captured)${NC}"
            echo ""
            echo -e "${WHITE}OCI CLI raw output:${NC}"
            if [[ -n "$raw_output" ]]; then
                echo -e "${GRAY}${raw_output}${NC}"
            else
                echo -e "${GRAY}(no output returned)${NC}"
            fi
            echo ""
            echo -e "${WHITE}Note: This can happen if:${NC}"
            echo -e "${GRAY}  - The instance has not produced any serial console output${NC}"
            echo -e "${GRAY}  - Serial console logging is not enabled on the instance${NC}"
            echo -e "${GRAY}  - The instance was recently created/rebooted${NC}"
            echo ""
            echo -e "${BOLD}${CYAN}─── End of Console Output ────────────────────────────────────────────────────────${NC}"
        fi
    else
        echo -e "${RED}Failed to fetch console history content${NC}"
        echo -e "${GRAY}Exit code: ${exit_code}${NC}"
        echo -e "${WHITE}OCI CLI output:${NC}"
        echo -e "${GRAY}${raw_output}${NC}"
        if [[ -s "$temp_error" ]]; then
            echo -e "${WHITE}Stderr:${NC}"
            cat "$temp_error"
        fi
        echo ""
        echo -e "${BOLD}${CYAN}─── End of Console Output ────────────────────────────────────────────────────────${NC}"
    fi
    
    # Cleanup temp files
    rm -f "$temp_output" "$temp_error"
}

#--------------------------------------------------------------------------------
# Compare instance cloud-init - offers choice of another instance or instance config
# Args: $1 = instance OCID, $2 = instance display name, $3 = instance user_data base64
#--------------------------------------------------------------------------------
compare_instance_cloud_init() {
    local instance_ocid="$1"
    local instance_name="$2"
    local instance_ud_b64="$3"
    
    echo ""
    echo -e "${BOLD}${BLUE}═══ Compare Cloud-Init ═══${NC}"
    echo ""
    echo -e "${WHITE}Current Instance:${NC} ${GREEN}$instance_name${NC}"
    echo ""
    echo -e "${BOLD}${WHITE}Compare against:${NC}"
    echo -e "  ${YELLOW}1${NC}) Another Compute Instance"
    echo -e "  ${YELLOW}2${NC}) An Instance Configuration"
    echo -e "  ${CYAN}q${NC}) Cancel"
    echo ""
    echo -n -e "${CYAN}Select option [1/2/q]: ${NC}"
    
    local choice
    read -r choice
    
    case "$choice" in
        1)
            compare_instance_to_instance "$instance_ocid" "$instance_name" "$instance_ud_b64"
            ;;
        2)
            compare_instance_to_config "$instance_ocid" "$instance_name" "$instance_ud_b64"
            ;;
        *)
            return
            ;;
    esac
}

#--------------------------------------------------------------------------------
# Compare instance cloud-init to another instance
# Args: $1 = instance OCID, $2 = instance display name, $3 = instance user_data base64
#--------------------------------------------------------------------------------
compare_instance_to_instance() {
    local instance_ocid="$1"
    local instance_name="$2"
    local instance_ud_b64="$3"
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    
    echo ""
    echo -e "${BOLD}${BLUE}═══ Compare to Another Instance ═══${NC}"
    echo ""
    echo -e "${YELLOW}Fetching compute instances...${NC}"
    
    # Get list of instances
    local instances_json
    instances_json=$(oci compute instance list \
        --compartment-id "$compartment_id" \
        --lifecycle-state RUNNING \
        --output json 2>/dev/null)
    
    if [[ -z "$instances_json" ]] || ! echo "$instances_json" | jq -e '.data[]' > /dev/null 2>&1; then
        echo -e "${RED}No running instances found${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # List instances (excluding current one)
    local inst_idx=0
    declare -A COMPARE_INST_MAP=()
    
    printf "${BOLD}%-4s %-50s %-25s${NC}\n" "#" "Instance Name" "Shape"
    print_separator 90
    
    while IFS='|' read -r inst_ocid inst_name inst_shape; do
        [[ -z "$inst_ocid" ]] && continue
        [[ "$inst_ocid" == "$instance_ocid" ]] && continue  # Skip current instance
        
        ((inst_idx++))
        COMPARE_INST_MAP[$inst_idx]="$inst_ocid|$inst_name"
        printf "${YELLOW}%-4s${NC} ${WHITE}%-50s${NC} ${CYAN}%-25s${NC}\n" "$inst_idx" "${inst_name:0:50}" "$inst_shape"
    done < <(echo "$instances_json" | jq -r '.data[] | "\(.id)|\(.["display-name"])|\(.shape)"' 2>/dev/null)
    
    if [[ $inst_idx -eq 0 ]]; then
        echo -e "${GRAY}No other instances found to compare${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Select instance to compare against (1-${inst_idx}): ${NC}"
    local select_choice
    read -r select_choice
    
    if [[ -z "${COMPARE_INST_MAP[$select_choice]:-}" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    local other_ocid other_name
    IFS='|' read -r other_ocid other_name <<< "${COMPARE_INST_MAP[$select_choice]}"
    
    echo ""
    echo -e "${YELLOW}Fetching instance details...${NC}"
    
    # Get the other instance's user_data
    local other_ud_b64
    other_ud_b64=$(oci compute instance get \
        --instance-id "$other_ocid" \
        --query 'data.metadata.user_data' \
        --raw-output 2>/dev/null)
    
    if [[ -z "$other_ud_b64" || "$other_ud_b64" == "null" ]]; then
        echo -e "${YELLOW}The selected instance has no cloud-init user_data${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # Create temp files for diff
    local tmp1 tmp2
    tmp1=$(mktemp)
    tmp2=$(mktemp)
    
    # Decode user_data (handles gzip compression)
    decode_user_data_to_file "$instance_ud_b64" "$tmp1"
    decode_user_data_to_file "$other_ud_b64" "$tmp2"
    
    echo ""
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${MAGENTA}                                           INSTANCE CLOUD-INIT COMPARISON                                                                              ${NC}"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${WHITE}Comparing:${NC}"
    echo -e "  ${RED}- Instance A:${NC} ${GREEN}$instance_name${NC}"
    echo -e "  ${GREEN}+ Instance B:${NC} ${BLUE}$other_name${NC}"
    echo ""
    
    if diff -q "$tmp1" "$tmp2" > /dev/null 2>&1; then
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                                                 ✓ CLOUD-INIT IS IDENTICAL                                                                              ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                                                 ✗ CLOUD-INIT DIFFERS                                                                                    ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${BOLD}${WHITE}Differences:${NC}"
        echo ""
        
        local diff_output
        diff_output=$(diff -u "$tmp1" "$tmp2" 2>/dev/null | tail -n +4)
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^@@ ]]; then
                echo -e "${YELLOW}${line}${NC}"
            elif [[ "$line" =~ ^- ]]; then
                echo -e "${RED}${line}${NC}  ${GRAY}← $instance_name${NC}"
            elif [[ "$line" =~ ^\+ ]]; then
                echo -e "${GREEN}${line}${NC}  ${GRAY}← $other_name${NC}"
            elif [[ "$line" =~ ^[[:space:]] ]]; then
                echo -e "${GRAY}${line}${NC}"
            fi
        done <<< "$diff_output"
    fi
    
    rm -f "$tmp1" "$tmp2"
    
    echo ""
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Press Enter to return..."
    read -r
}

#--------------------------------------------------------------------------------
# Compare instance cloud-init against an instance configuration
# Args: $1 = instance OCID, $2 = instance display name, $3 = instance user_data base64
#--------------------------------------------------------------------------------
compare_instance_to_config() {
    local instance_ocid="$1"
    local instance_name="$2"
    local instance_ud_b64="$3"
    
    echo ""
    echo -e "${BOLD}${BLUE}═══ Compare Instance Cloud-Init to Instance Configuration ═══${NC}"
    echo ""
    echo -e "${WHITE}Instance:${NC} ${GREEN}$instance_name${NC}"
    echo ""
    
    # Refresh instance config cache
    fetch_instance_configurations > /dev/null 2>&1
    
    if [[ ! -f "$INSTANCE_CONFIG_CACHE" ]]; then
        echo -e "${RED}No instance configurations found${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # List configs
    local ic_idx=0
    declare -A COMPARE_IC_MAP=()
    
    printf "${BOLD}%-4s %-70s${NC}\n" "#" "Instance Configuration Name"
    print_separator 90
    
    while IFS='|' read -r ic_ocid ic_name _; do
        [[ "$ic_ocid" =~ ^#.*$ ]] && continue
        [[ -z "$ic_ocid" ]] && continue
        
        ((ic_idx++))
        COMPARE_IC_MAP[$ic_idx]="$ic_ocid|$ic_name"
        printf "${YELLOW}%-4s${NC} ${WHITE}%-70s${NC}\n" "$ic_idx" "$ic_name"
    done < <(grep -v '^#' "$INSTANCE_CONFIG_CACHE" 2>/dev/null)
    
    if [[ $ic_idx -eq 0 ]]; then
        echo -e "${GRAY}No instance configurations found${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Select instance configuration to compare against (1-${ic_idx}): ${NC}"
    local choice
    read -r choice
    
    if [[ -z "${COMPARE_IC_MAP[$choice]:-}" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    local ic_ocid ic_name
    IFS='|' read -r ic_ocid ic_name <<< "${COMPARE_IC_MAP[$choice]}"
    
    echo ""
    echo -e "${YELLOW}Fetching instance configuration...${NC}"
    
    # Get instance config user_data
    local ic_ud_b64
    ic_ud_b64=$(oci compute-management instance-configuration get \
        --instance-configuration-id "$ic_ocid" \
        --query 'data["instance-details"]["launch-details"]["metadata"]["user_data"]' \
        --raw-output 2>/dev/null)
    
    if [[ -z "$ic_ud_b64" || "$ic_ud_b64" == "null" ]]; then
        echo -e "${YELLOW}Instance configuration has no user_data${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # Create temp files for diff
    local tmp_instance tmp_ic
    tmp_instance=$(mktemp)
    tmp_ic=$(mktemp)
    
    # Decode user_data (handles gzip compression)
    decode_user_data_to_file "$instance_ud_b64" "$tmp_instance"
    decode_user_data_to_file "$ic_ud_b64" "$tmp_ic"
    
    echo ""
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${MAGENTA}                                              CLOUD-INIT COMPARISON                                                                                    ${NC}"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${WHITE}Comparing:${NC}"
    echo -e "  ${RED}- (Instance):${NC}        ${GREEN}$instance_name${NC}"
    echo -e "  ${GREEN}+ (Instance Config):${NC} ${BLUE}$ic_name${NC}"
    echo ""
    
    if diff -q "$tmp_instance" "$tmp_ic" > /dev/null 2>&1; then
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                                           ✓ CLOUD-INIT IS IDENTICAL - NO DRIFT DETECTED                                                               ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                                           ✗ DRIFT DETECTED - CLOUD-INIT DIFFERS                                                                        ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${BOLD}${WHITE}Differences:${NC}"
        echo ""
        
        # Show annotated diff
        local diff_output
        diff_output=$(diff -u "$tmp_instance" "$tmp_ic" 2>/dev/null | tail -n +4)
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^@@ ]]; then
                echo -e "${YELLOW}${line}${NC}"
            elif [[ "$line" =~ ^- ]]; then
                echo -e "${RED}${line}${NC}  ${GRAY}← Instance (current)${NC}"
            elif [[ "$line" =~ ^\+ ]]; then
                echo -e "${GREEN}${line}${NC}  ${GRAY}← Instance Config (expected)${NC}"
            elif [[ "$line" =~ ^[[:space:]] ]]; then
                echo -e "${GRAY}${line}${NC}"
            fi
        done <<< "$diff_output"
    fi
    
    # Cleanup
    rm -f "$tmp_instance" "$tmp_ic"
    
    echo ""
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Press Enter to return..."
    read -r
}

#===============================================================================
# INSTANCE CONFIGURATION MANAGEMENT
#===============================================================================

manage_instance_configurations() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    # Build instance config index map
    declare -A LOCAL_IC_INDEX_MAP=()
    
    while true; do
        echo ""
        echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${GREEN}                                                    INSTANCE CONFIGURATION MANAGEMENT                                                                    ${NC}"
        echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}Environment:${NC}"
        echo -e "  ${CYAN}Region:${NC}      ${WHITE}${region}${NC}"
        echo -e "  ${CYAN}Compartment:${NC} ${YELLOW}${compartment_id}${NC}"
        echo ""
        
        # Fetch and display instance configurations
        fetch_instance_configurations > /dev/null 2>&1
        
        echo -e "${BOLD}${WHITE}═══ Instance Configurations ═══${NC}"
        echo ""
        printf "${BOLD}%-5s %-55s %-20s %s${NC}\n" "ID" "Name" "Created" "OCID"
        print_separator 160
        
        local ic_idx=0
        LOCAL_IC_INDEX_MAP=()
        
        if [[ -f "$INSTANCE_CONFIG_CACHE" ]]; then
            # Read from cache (now includes time-created)
            while IFS='|' read -r ic_ocid ic_name ic_time_created; do
                [[ "$ic_ocid" =~ ^#.*$ ]] && continue
                [[ -z "$ic_ocid" ]] && continue
                
                ((ic_idx++))
                local iid="i${ic_idx}"
                LOCAL_IC_INDEX_MAP[$iid]="$ic_ocid"
                IC_INDEX_MAP[$iid]="$ic_ocid"
                
                # Format time_created from cache
                local time_display="N/A"
                if [[ -n "$ic_time_created" && "$ic_time_created" != "N/A" ]]; then
                    time_display="${ic_time_created:0:16}"
                    time_display="${time_display/T/ }"
                fi
                
                printf "${YELLOW}%-5s${NC} ${WHITE}%-55s${NC} ${GRAY}%-20s${NC} ${CYAN}%s${NC}\n" \
                    "$iid" "${ic_name:0:55}" "$time_display" "$ic_ocid"
            done < <(grep -v '^#' "$INSTANCE_CONFIG_CACHE" 2>/dev/null)
        fi
        
        if [[ $ic_idx -eq 0 ]]; then
            echo -e "  ${GRAY}No instance configurations found${NC}"
        fi
        
        echo ""
        echo -e "${GRAY}Total: ${ic_idx} instance configurations${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}═══ Actions ═══${NC}"
        echo -e "  ${YELLOW}i#${NC}          - View instance configuration details and user-data (e.g., 'i1', 'i2')"
        echo -e "  ${GREEN}create${NC}      - Create a new Instance Configuration"
        echo -e "  ${YELLOW}rename${NC}      - Rename an Instance Configuration (with recommended name)"
        echo -e "  ${RED}delete${NC}      - Delete an Instance Configuration"
        echo -e "  ${BLUE}update-all${NC}  - Update ALL GPU Memory Clusters with a selected Instance Configuration"
        echo -e "  ${MAGENTA}compare${NC}     - Compare cloud-init between two instance configurations"
        echo -e "  ${MAGENTA}refresh${NC}     - Refresh data from OCI"
        echo -e "  ${CYAN}back${NC}        - Return to main menu"
        echo ""
        echo -n -e "${BOLD}${CYAN}Enter selection [i#/create/rename/delete/update-all/compare/refresh/back]: ${NC}"
        
        local input
        read -r input
        
        # Empty input goes back
        if [[ -z "$input" ]]; then
            return
        fi
        
        case "$input" in
            create|CREATE)
                create_instance_configuration_interactive
                ;;
            rename|RENAME)
                rename_instance_configuration_interactive
                ;;
            delete|DELETE)
                delete_instance_configuration_interactive
                ;;
            update-all|UPDATE-ALL)
                update_all_clusters_instance_config
                ;;
            compare|COMPARE)
                compare_instance_configurations
                ;;
            refresh|REFRESH)
                echo -e "${YELLOW}Refreshing cache...${NC}"
                rm -f "$INSTANCE_CONFIG_CACHE"
                ;;
            quit|QUIT|q|Q|exit|EXIT|back|BACK|b|B)
                return
                ;;
            i[0-9]*)
                view_instance_configuration_detail "$input"
                ;;
            *)
                echo -e "${RED}Unknown command: $input${NC}"
                ;;
        esac
    done
}

#--------------------------------------------------------------------------------
# View Instance Configuration Detail with user-data decoding
#--------------------------------------------------------------------------------
view_instance_configuration_detail() {
    local ic_id="$1"
    local ic_ocid="${IC_INDEX_MAP[$ic_id]:-}"
    
    if [[ -z "$ic_ocid" ]]; then
        echo -e "${RED}Invalid instance config ID: $ic_id${NC}"
        return 1
    fi
    
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}                       INSTANCE CONFIGURATION DETAILS                          ${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════${NC}"
    
    local ic_json
    ic_json=$(oci compute-management instance-configuration get \
        --instance-configuration-id "$ic_ocid" \
        --output json 2>/dev/null)
    
    if [[ -z "$ic_json" ]]; then
        echo -e "${RED}Failed to fetch instance configuration details${NC}"
        echo ""
        echo -e "Press Enter to return..."
        read -r
        return 1
    fi
    
    local ic_name ic_time_created ic_compartment
    ic_name=$(echo "$ic_json" | jq -r '.data["display-name"] // "N/A"')
    ic_time_created=$(echo "$ic_json" | jq -r '.data["time-created"] // "N/A"')
    ic_compartment=$(echo "$ic_json" | jq -r '.data["compartment-id"] // "N/A"')
    
    echo ""
    echo -e "${WHITE}Name:${NC}         ${GREEN}$ic_name${NC}"
    echo -e "${WHITE}OCID:${NC}         ${YELLOW}$ic_ocid${NC}"
    echo -e "${WHITE}Time Created:${NC} $ic_time_created"
    echo -e "${WHITE}Compartment:${NC}  ${GRAY}...${ic_compartment: -30}${NC}"
    
    # Show instance details from the configuration
    echo ""
    echo -e "${BOLD}${CYAN}Instance Details:${NC}"
    local shape ad boot_size boot_vpus image_id subnet_id
    shape=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["shape"] // "N/A"')
    ad=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["availability-domain"] // "N/A"')
    boot_size=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["source-details"]["bootVolumeSizeInGBs"] // "N/A"')
    boot_vpus=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["source-details"]["bootVolumeVpusPerGB"] // "N/A"')
    image_id=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["source-details"]["image-id"] // "N/A"')
    subnet_id=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["create-vnic-details"]["subnet-id"] // "N/A"')
    local max_pods
    max_pods=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["metadata"]["oke-max-pods"] // "N/A"')
    
    echo -e "  ${WHITE}Shape:${NC}              $shape"
    echo -e "  ${WHITE}Availability Domain:${NC} $ad"
    echo -e "  ${WHITE}Boot Volume Size:${NC}   ${boot_size} GB"
    echo -e "  ${WHITE}Boot Volume VPUs:${NC}   ${boot_vpus} VPUs/GB"
    echo -e "  ${WHITE}Max Pods:${NC}           $max_pods"
    echo -e "  ${WHITE}Image ID:${NC}           ${GRAY}...${image_id: -25}${NC}"
    echo -e "  ${WHITE}Subnet ID:${NC}          ${GRAY}...${subnet_id: -25}${NC}"
    
    # Check for user_data
    local user_data_b64
    user_data_b64=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["metadata"]["user_data"] // empty' 2>/dev/null)
    
    local has_user_data="false"
    [[ -n "$user_data_b64" ]] && has_user_data="true"
    
    # Check for SSH keys
    local ssh_keys
    ssh_keys=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["metadata"]["ssh_authorized_keys"] // empty' 2>/dev/null)
    
    if [[ -n "$ssh_keys" ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}SSH Keys:${NC}"
        echo -e "  ${GREEN}✓ SSH authorized keys are configured${NC}"
    fi
    
    if [[ "$has_user_data" == "true" ]]; then
        echo ""
        echo -e "${BOLD}${CYAN}User Data:${NC}"
        echo -e "  ${GREEN}✓ Cloud-init user-data is configured ($(echo "$user_data_b64" | wc -c) bytes encoded)${NC}"
    fi
    
    # Show actions
    echo ""
    echo -e "${BOLD}${WHITE}Actions:${NC}"
    if [[ "$has_user_data" == "true" ]]; then
        echo -e "  ${MAGENTA}view${NC}     - View decoded cloud-init user-data"
        echo -e "  ${MAGENTA}save${NC}     - Save user-data to file"
    fi
    echo -e "  ${YELLOW}rename${NC}   - Rename this instance configuration"
    echo -e "  ${RED}delete${NC}   - Delete this instance configuration"
    echo -e "  ${CYAN}Enter${NC}    - Return to menu"
    echo ""
    echo -n -e "${CYAN}Action [view/save/rename/delete/Enter]: ${NC}"
    
    local action
    read -r action
    
    case "$action" in
        view|VIEW|v|V)
            if [[ "$has_user_data" == "true" ]]; then
                echo ""
                echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
                echo -e "${BOLD}${MAGENTA}                         DECODED CLOUD-INIT USER-DATA                          ${NC}"
                echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
                echo ""
                
                # Check if gzip compressed and decompress
                if is_user_data_gzip "$user_data_b64"; then
                    echo -e "${GRAY}(gzip compressed - decompressing)${NC}"
                    echo ""
                fi
                decode_user_data "$user_data_b64"
                
                echo ""
                echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -n -e "${CYAN}Press Enter to continue...${NC}"
                read -r
            else
                echo -e "${YELLOW}No user-data found${NC}"
            fi
            ;;
        save|SAVE|s|S)
            if [[ "$has_user_data" == "true" ]]; then
                local safe_name
                safe_name=$(echo "$ic_name" | tr ' ' '_' | tr -cd '[:alnum:]_-')
                local filename="${safe_name}_cloud-init.yml"
                
                echo ""
                echo -n -e "${CYAN}Save as [${filename}]: ${NC}"
                local custom_filename
                read -r custom_filename
                [[ -n "$custom_filename" ]] && filename="$custom_filename"
                
                local gzip_msg=""
                if is_user_data_gzip "$user_data_b64"; then
                    gzip_msg=" ${GRAY}(decompressed from gzip)${NC}"
                fi
                
                if decode_user_data_to_file "$user_data_b64" "$filename"; then
                    echo -e "${GREEN}✓ User-data saved to: ${WHITE}$(pwd)/${filename}${NC}${gzip_msg}"
                else
                    echo -e "${RED}Failed to save user-data${NC}"
                fi
                echo ""
                echo -n -e "${CYAN}Press Enter to continue...${NC}"
                read -r
            else
                echo -e "${YELLOW}No user-data found${NC}"
            fi
            ;;
        rename|RENAME|r|R)
            rename_single_instance_configuration "$ic_ocid" "$ic_name" "$ic_json"
            ;;
        delete|DELETE|d|D)
            delete_single_instance_configuration "$ic_ocid" "$ic_name"
            ;;
        *)
            # Return to menu
            ;;
    esac
}

#--------------------------------------------------------------------------------
# Compare two Instance Configurations
#--------------------------------------------------------------------------------
compare_instance_configurations() {
    echo ""
    echo -e "${BOLD}${MAGENTA}═══ Compare Instance Configurations ═══${NC}"
    echo ""
    
    # Refresh cache
    fetch_instance_configurations > /dev/null 2>&1
    
    if [[ ! -f "$INSTANCE_CONFIG_CACHE" ]]; then
        echo -e "${RED}No instance configurations found${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # List configs
    local ic_idx=0
    declare -A COMPARE_IC_MAP=()
    
    printf "${BOLD}%-4s %-60s${NC}\n" "#" "Name"
    print_separator 80
    
    while IFS='|' read -r ic_ocid ic_name _; do
        [[ "$ic_ocid" =~ ^#.*$ ]] && continue
        [[ -z "$ic_ocid" ]] && continue
        
        ((ic_idx++))
        COMPARE_IC_MAP[$ic_idx]="$ic_ocid|$ic_name"
        printf "${YELLOW}%-4s${NC} ${WHITE}%-60s${NC}\n" "$ic_idx" "$ic_name"
    done < <(grep -v '^#' "$INSTANCE_CONFIG_CACHE" 2>/dev/null)
    
    if [[ $ic_idx -lt 2 ]]; then
        echo ""
        echo -e "${YELLOW}Need at least 2 instance configurations to compare${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Select first configuration (1-${ic_idx}): ${NC}"
    local choice1
    read -r choice1
    
    if [[ -z "${COMPARE_IC_MAP[$choice1]:-}" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return
    fi
    
    echo -n -e "${CYAN}Select second configuration (1-${ic_idx}): ${NC}"
    local choice2
    read -r choice2
    
    if [[ -z "${COMPARE_IC_MAP[$choice2]:-}" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return
    fi
    
    local ocid1 name1 ocid2 name2
    IFS='|' read -r ocid1 name1 <<< "${COMPARE_IC_MAP[$choice1]}"
    IFS='|' read -r ocid2 name2 <<< "${COMPARE_IC_MAP[$choice2]}"
    
    echo ""
    echo -e "${BOLD}Comparing:${NC}"
    echo -e "  ${GREEN}A:${NC} $name1"
    echo -e "  ${BLUE}B:${NC} $name2"
    echo ""
    echo -e "${YELLOW}Fetching full configuration details...${NC}"
    
    # Get FULL instance configuration JSON for both
    local json1 json2
    json1=$(oci compute-management instance-configuration get \
        --instance-configuration-id "$ocid1" \
        --output json 2>/dev/null)
    
    json2=$(oci compute-management instance-configuration get \
        --instance-configuration-id "$ocid2" \
        --output json 2>/dev/null)
    
    if [[ -z "$json1" || -z "$json2" ]]; then
        echo -e "${RED}Failed to fetch configuration details${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # Extract launch-details for comparison
    local launch1 launch2
    launch1=$(echo "$json1" | jq '.data["instance-details"]["launch-details"]')
    launch2=$(echo "$json2" | jq '.data["instance-details"]["launch-details"]')
    
    echo ""
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${MAGENTA}                                                    CONFIGURATION COMPARISON                                                                            ${NC}"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    
    # Compare key fields individually
    local has_diff=false
    
    # Shape
    local shape1 shape2
    shape1=$(echo "$launch1" | jq -r '.shape // "N/A"')
    shape2=$(echo "$launch2" | jq -r '.shape // "N/A"')
    echo ""
    echo -e "${BOLD}${WHITE}Shape:${NC}"
    if [[ "$shape1" == "$shape2" ]]; then
        echo -e "  ${GREEN}✓ Same:${NC} $shape1"
    else
        echo -e "  ${RED}✗ Different:${NC}"
        echo -e "    ${GREEN}$name1:${NC} $shape1"
        echo -e "    ${BLUE}$name2:${NC} $shape2"
        has_diff=true
    fi
    
    # Availability Domain
    local ad1 ad2
    ad1=$(echo "$launch1" | jq -r '.["availability-domain"] // "N/A"')
    ad2=$(echo "$launch2" | jq -r '.["availability-domain"] // "N/A"')
    echo ""
    echo -e "${BOLD}${WHITE}Availability Domain:${NC}"
    if [[ "$ad1" == "$ad2" ]]; then
        echo -e "  ${GREEN}✓ Same:${NC} $ad1"
    else
        echo -e "  ${RED}✗ Different:${NC}"
        echo -e "    ${GREEN}$name1:${NC} $ad1"
        echo -e "    ${BLUE}$name2:${NC} $ad2"
        has_diff=true
    fi
    
    # Boot Volume Size
    local bvsize1 bvsize2
    bvsize1=$(echo "$launch1" | jq -r '.["source-details"]["boot-volume-size-in-gbs"] // "N/A"')
    bvsize2=$(echo "$launch2" | jq -r '.["source-details"]["boot-volume-size-in-gbs"] // "N/A"')
    echo ""
    echo -e "${BOLD}${WHITE}Boot Volume Size (GB):${NC}"
    if [[ "$bvsize1" == "$bvsize2" ]]; then
        echo -e "  ${GREEN}✓ Same:${NC} $bvsize1"
    else
        echo -e "  ${RED}✗ Different:${NC}"
        echo -e "    ${GREEN}$name1:${NC} $bvsize1"
        echo -e "    ${BLUE}$name2:${NC} $bvsize2"
        has_diff=true
    fi
    
    # Boot Volume VPUs
    local bvvpus1 bvvpus2
    bvvpus1=$(echo "$launch1" | jq -r '.["source-details"]["boot-volume-vpus-per-gb"] // "N/A"')
    bvvpus2=$(echo "$launch2" | jq -r '.["source-details"]["boot-volume-vpus-per-gb"] // "N/A"')
    echo ""
    echo -e "${BOLD}${WHITE}Boot Volume VPUs/GB:${NC}"
    if [[ "$bvvpus1" == "$bvvpus2" ]]; then
        echo -e "  ${GREEN}✓ Same:${NC} $bvvpus1"
    else
        echo -e "  ${RED}✗ Different:${NC}"
        echo -e "    ${GREEN}$name1:${NC} $bvvpus1"
        echo -e "    ${BLUE}$name2:${NC} $bvvpus2"
        has_diff=true
    fi
    
    # Image ID - show full OCID
    local img1 img2
    img1=$(echo "$launch1" | jq -r '.["source-details"]["image-id"] // "N/A"')
    img2=$(echo "$launch2" | jq -r '.["source-details"]["image-id"] // "N/A"')
    echo ""
    echo -e "${BOLD}${WHITE}Image ID:${NC}"
    if [[ "$img1" == "$img2" ]]; then
        echo -e "  ${GREEN}✓ Same:${NC}"
        echo -e "    $img1"
    else
        echo -e "  ${RED}✗ Different:${NC}"
        echo -e "    ${GREEN}$name1:${NC}"
        echo -e "      $img1"
        echo -e "    ${BLUE}$name2:${NC}"
        echo -e "      $img2"
        has_diff=true
    fi
    
    # Subnet ID - show full OCID
    local subnet1 subnet2
    subnet1=$(echo "$launch1" | jq -r '.["create-vnic-details"]["subnet-id"] // "N/A"')
    subnet2=$(echo "$launch2" | jq -r '.["create-vnic-details"]["subnet-id"] // "N/A"')
    echo ""
    echo -e "${BOLD}${WHITE}Subnet ID:${NC}"
    if [[ "$subnet1" == "$subnet2" ]]; then
        echo -e "  ${GREEN}✓ Same:${NC}"
        echo -e "    $subnet1"
    else
        echo -e "  ${RED}✗ Different:${NC}"
        echo -e "    ${GREEN}$name1:${NC}"
        echo -e "      $subnet1"
        echo -e "    ${BLUE}$name2:${NC}"
        echo -e "      $subnet2"
        has_diff=true
    fi
    
    # NSG IDs - show full OCIDs
    local nsg1 nsg2
    nsg1=$(echo "$launch1" | jq -r '.["create-vnic-details"]["nsg-ids"] // []' | jq -r '.[]' 2>/dev/null | sort)
    nsg2=$(echo "$launch2" | jq -r '.["create-vnic-details"]["nsg-ids"] // []' | jq -r '.[]' 2>/dev/null | sort)
    echo ""
    echo -e "${BOLD}${WHITE}NSG IDs:${NC}"
    if [[ "$nsg1" == "$nsg2" ]]; then
        if [[ -n "$nsg1" ]]; then
            echo -e "  ${GREEN}✓ Same:${NC}"
            echo "$nsg1" | while read -r nsg; do
                echo -e "    $nsg"
            done
        else
            echo -e "  ${GREEN}✓ Same:${NC} (none)"
        fi
    else
        echo -e "  ${RED}✗ Different:${NC}"
        echo -e "    ${GREEN}$name1:${NC}"
        if [[ -n "$nsg1" ]]; then
            echo "$nsg1" | while read -r nsg; do
                echo -e "      $nsg"
            done
        else
            echo -e "      (none)"
        fi
        echo -e "    ${BLUE}$name2:${NC}"
        if [[ -n "$nsg2" ]]; then
            echo "$nsg2" | while read -r nsg; do
                echo -e "      $nsg"
            done
        else
            echo -e "      (none)"
        fi
        has_diff=true
    fi
    
    # Metadata fields (excluding user_data which we'll handle separately)
    echo ""
    echo -e "${BOLD}${WHITE}Metadata Fields:${NC}"
    local meta1_keys meta2_keys
    meta1_keys=$(echo "$launch1" | jq -r '.metadata // {} | keys[]' 2>/dev/null | grep -v '^user_data$' | sort)
    meta2_keys=$(echo "$launch2" | jq -r '.metadata // {} | keys[]' 2>/dev/null | grep -v '^user_data$' | sort)
    
    # Find all unique keys
    local all_meta_keys
    all_meta_keys=$(echo -e "${meta1_keys}\n${meta2_keys}" | sort -u | grep -v '^$')
    
    if [[ -z "$all_meta_keys" ]]; then
        echo -e "  ${GRAY}(no metadata fields other than user_data)${NC}"
    else
        while read -r key; do
            [[ -z "$key" ]] && continue
            local val1 val2
            val1=$(echo "$launch1" | jq -r ".metadata[\"$key\"] // \"(not set)\"")
            val2=$(echo "$launch2" | jq -r ".metadata[\"$key\"] // \"(not set)\"")
            
            if [[ "$val1" == "$val2" ]]; then
                echo -e "  ${GREEN}✓${NC} ${WHITE}$key:${NC} $val1"
            else
                echo -e "  ${RED}✗${NC} ${WHITE}$key:${NC}"
                echo -e "      ${GREEN}$name1:${NC} $val1"
                echo -e "      ${BLUE}$name2:${NC} $val2"
                has_diff=true
            fi
        done <<< "$all_meta_keys"
    fi
    
    # User Data comparison - improved display
    echo ""
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${MAGENTA}                                                  CLOUD-INIT USER-DATA COMPARISON                                                                       ${NC}"
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${WHITE}Legend:${NC}"
    echo -e "  ${RED}- Lines only in:${NC} ${GREEN}$name1${NC}"
    echo -e "  ${GREEN}+ Lines only in:${NC} ${BLUE}$name2${NC}"
    echo ""
    
    local ud1 ud2
    ud1=$(echo "$launch1" | jq -r '.metadata.user_data // empty')
    ud2=$(echo "$launch2" | jq -r '.metadata.user_data // empty')
    
    # Create temp files for diff
    local tmp1 tmp2
    tmp1=$(mktemp)
    tmp2=$(mktemp)
    
    if [[ -n "$ud1" ]]; then
        decode_user_data_to_file "$ud1" "$tmp1" || echo "# Failed to decode user_data" > "$tmp1"
    else
        echo "# No user_data" > "$tmp1"
    fi
    
    if [[ -n "$ud2" ]]; then
        decode_user_data_to_file "$ud2" "$tmp2" || echo "# Failed to decode user_data" > "$tmp2"
    else
        echo "# No user_data" > "$tmp2"
    fi
    
    if diff -q "$tmp1" "$tmp2" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Cloud-init user-data is identical${NC}"
    else
        echo -e "${RED}✗ Cloud-init user-data is DIFFERENT${NC}"
        echo ""
        
        # Show side-by-side differences with context
        echo -e "${BOLD}${WHITE}Differences found:${NC}"
        echo ""
        
        # Use diff to find changed lines and display them more clearly
        local diff_output
        diff_output=$(diff -u "$tmp1" "$tmp2" 2>/dev/null | tail -n +4)  # Skip header lines
        
        local in_change=false
        local line_num=0
        while IFS= read -r line; do
            ((line_num++))
            
            if [[ "$line" =~ ^@@ ]]; then
                # Context marker - show section
                echo ""
                echo -e "${YELLOW}${line}${NC}"
                in_change=true
            elif [[ "$line" =~ ^- ]]; then
                # Line removed (in config 1 only)
                echo -e "${RED}${line}${NC}  ${GRAY}← ${name1}${NC}"
            elif [[ "$line" =~ ^\+ ]]; then
                # Line added (in config 2 only)
                echo -e "${GREEN}${line}${NC}  ${GRAY}← ${name2}${NC}"
            elif [[ "$line" =~ ^[[:space:]] ]] && [[ "$in_change" == "true" ]]; then
                # Context line
                echo -e "${GRAY}${line}${NC}"
            fi
        done <<< "$diff_output"
        
        has_diff=true
    fi
    
    # Cleanup
    rm -f "$tmp1" "$tmp2"
    
    # Summary
    echo ""
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    if [[ "$has_diff" == "true" ]]; then
        echo -e "${RED}✗ Configurations have differences${NC}"
    else
        echo -e "${GREEN}✓ Configurations are identical${NC}"
    fi
    echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    
    echo ""
    echo -e "Press Enter to return..."
    read -r
}

#--------------------------------------------------------------------------------
# Rename Instance Configuration interactively
#--------------------------------------------------------------------------------
rename_instance_configuration_interactive() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    echo ""
    echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${YELLOW}                                    RENAME INSTANCE CONFIGURATION                                               ${NC}"
    echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Refresh cache
    fetch_instance_configurations > /dev/null 2>&1
    
    if [[ ! -f "$INSTANCE_CONFIG_CACHE" ]]; then
        echo -e "${RED}No instance configurations found${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # List configs
    local ic_idx=0
    declare -A RENAME_IC_MAP=()
    
    printf "${BOLD}%-4s %-70s${NC}\n" "#" "Current Name"
    print_separator 100
    
    while IFS='|' read -r ic_ocid ic_name _; do
        [[ "$ic_ocid" =~ ^#.*$ ]] && continue
        [[ -z "$ic_ocid" ]] && continue
        
        ((ic_idx++))
        RENAME_IC_MAP[$ic_idx]="$ic_ocid|$ic_name"
        printf "${YELLOW}%-4s${NC} ${WHITE}%-70s${NC}\n" "$ic_idx" "$ic_name"
    done < <(grep -v '^#' "$INSTANCE_CONFIG_CACHE" 2>/dev/null)
    
    if [[ $ic_idx -eq 0 ]]; then
        echo -e "${GRAY}No instance configurations found${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Select instance configuration to rename (1-${ic_idx}): ${NC}"
    local choice
    read -r choice
    
    if [[ -z "${RENAME_IC_MAP[$choice]:-}" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    local ic_ocid ic_current_name
    IFS='|' read -r ic_ocid ic_current_name <<< "${RENAME_IC_MAP[$choice]}"
    
    echo ""
    echo -e "${BOLD}${WHITE}Selected:${NC} ${CYAN}$ic_current_name${NC}"
    echo -e "${GRAY}OCID: $ic_ocid${NC}"
    echo ""
    
    # Fetch full details to generate recommended name
    echo -e "${YELLOW}Fetching configuration details...${NC}"
    local ic_json
    ic_json=$(oci compute-management instance-configuration get \
        --instance-configuration-id "$ic_ocid" \
        --output json 2>/dev/null)
    
    if [[ -z "$ic_json" ]]; then
        echo -e "${RED}Failed to fetch instance configuration details${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # Extract details for recommended name
    local shape network_type oke_version
    shape=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["shape"] // "unknown"')
    
    # Determine network type from metadata
    local native_networking
    native_networking=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["metadata"]["oke-native-pod-networking"] // "false"')
    if [[ "$native_networking" == "true" ]]; then
        network_type="native"
    else
        network_type="flannel"
    fi
    
    # Try to extract kubernetes version from user_data
    local user_data_b64
    user_data_b64=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["metadata"]["user_data"] // empty')
    oke_version="unknown"
    if [[ -n "$user_data_b64" ]]; then
        local decoded_ud
        decoded_ud=$(echo "$user_data_b64" | base64 -d 2>/dev/null)
        # Look for kubernetes version in the apt source or package name
        # e.g., kubernetes-1.33 or oci-oke-node-all-1.33.1
        local extracted_version
        extracted_version=$(echo "$decoded_ud" | grep -oP 'kubernetes-\K[0-9]+\.[0-9]+' | head -1)
        if [[ -z "$extracted_version" ]]; then
            extracted_version=$(echo "$decoded_ud" | grep -oP 'oci-oke-node-all-\K[0-9]+\.[0-9]+' | head -1)
        fi
        if [[ -n "$extracted_version" ]]; then
            oke_version="$extracted_version"
        fi
    fi
    
    # Count existing configs with similar pattern to determine next number
    local base_pattern="${shape}-ic-oke-${oke_version}-${network_type}"
    local existing_count=0
    if [[ -f "$INSTANCE_CONFIG_CACHE" ]]; then
        existing_count=$(grep -c "${base_pattern}" "$INSTANCE_CONFIG_CACHE" 2>/dev/null) || existing_count=0
        [[ ! "$existing_count" =~ ^[0-9]+$ ]] && existing_count=0
    fi
    local next_num=$((existing_count + 1))
    
    # Generate recommended name
    local recommended_name="${shape}-ic-oke-${oke_version}-${network_type}-${next_num}"
    
    echo ""
    echo -e "${BOLD}${WHITE}Detected Configuration:${NC}"
    echo -e "  ${CYAN}Shape:${NC}        $shape"
    echo -e "  ${CYAN}Network Type:${NC} $network_type"
    echo -e "  ${CYAN}OKE Version:${NC}  $oke_version"
    echo ""
    
    echo -e "${BOLD}${WHITE}Naming Convention:${NC} ${GRAY}<shape>-ic-oke-<version>-<network_type>-<#>${NC}"
    echo ""
    echo -e "${BOLD}${GREEN}Recommended Name:${NC} ${WHITE}$recommended_name${NC}"
    echo ""
    
    echo -n -e "${CYAN}Enter new name [${recommended_name}]: ${NC}"
    local new_name
    read -r new_name
    
    # Use recommended name if empty
    [[ -z "$new_name" ]] && new_name="$recommended_name"
    
    # Don't rename if same name
    if [[ "$new_name" == "$ic_current_name" ]]; then
        echo -e "${YELLOW}New name is the same as current name. No changes made.${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    echo ""
    echo -e "${BOLD}${WHITE}Rename Summary:${NC}"
    echo -e "  ${RED}Current:${NC} $ic_current_name"
    echo -e "  ${GREEN}New:${NC}     $new_name"
    echo ""
    
    # Show command to be executed
    echo -e "${BOLD}${YELLOW}─── Command to Execute ───${NC}"
    echo ""
    printf "%s\n" "oci compute-management instance-configuration update \\"
    printf "%s\n" "  --instance-configuration-id \"$ic_ocid\" \\"
    printf "%s\n" "  --display-name \"$new_name\""
    echo ""
    
    # Log file for the action
    local log_file="instance_config_rename_$(date +%Y%m%d_%H%M%S).log"
    
    echo -e "${BOLD}${YELLOW}═══ CONFIRM RENAME ═══${NC}"
    echo ""
    echo -e "${WHITE}Log file: ${CYAN}${log_file}${NC}"
    echo ""
    echo -n -e "${CYAN}Type 'RENAME' to confirm: ${NC}"
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "RENAME" ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # Log the command
    {
        echo "=========================================="
        echo "Instance Configuration Rename"
        echo "Timestamp: $(date)"
        echo "=========================================="
        echo ""
        echo "OCID: $ic_ocid"
        echo "Current Name: $ic_current_name"
        echo "New Name: $new_name"
        echo ""
        echo "Command:"
        echo "oci compute-management instance-configuration update \\"
        echo "  --instance-configuration-id \"$ic_ocid\" \\"
        echo "  --display-name \"$new_name\""
        echo ""
        echo "=========================================="
        echo "Execution Output:"
        echo "=========================================="
    } > "$log_file"
    
    # Execute the rename
    echo ""
    echo -e "${YELLOW}Renaming instance configuration...${NC}"
    
    local result
    result=$(oci compute-management instance-configuration update \
        --instance-configuration-id "$ic_ocid" \
        --display-name "$new_name" 2>&1)
    local exit_code=$?
    
    # Log the result
    echo "$result" >> "$log_file"
    
    if [[ $exit_code -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                 INSTANCE CONFIGURATION RENAMED SUCCESSFULLY                ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${WHITE}Old Name:${NC} ${RED}$ic_current_name${NC}"
        echo -e "${WHITE}New Name:${NC} ${GREEN}$new_name${NC}"
        echo -e "${WHITE}Log:${NC}      ${WHITE}$log_file${NC}"
        echo ""
        
        # Invalidate cache
        rm -f "$INSTANCE_CONFIG_CACHE"
        
        echo -e "${GREEN}✓ Rename complete!${NC}"
    else
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                    FAILED TO RENAME INSTANCE CONFIGURATION                 ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${RED}Error:${NC}"
        echo "$result"
        echo ""
        echo -e "${WHITE}Log file: ${CYAN}$log_file${NC}"
    fi
    
    echo ""
    echo -e "Press Enter to return..."
    read -r
}

#--------------------------------------------------------------------------------
# Rename a single Instance Configuration (called from detail view)
# Args: $1 = OCID, $2 = current name, $3 = JSON (optional, will fetch if not provided)
#--------------------------------------------------------------------------------
rename_single_instance_configuration() {
    local ic_ocid="$1"
    local ic_current_name="$2"
    local ic_json="${3:-}"
    
    echo ""
    echo -e "${BOLD}${YELLOW}─── Rename Instance Configuration ───${NC}"
    echo ""
    
    # Fetch JSON if not provided
    if [[ -z "$ic_json" ]]; then
        echo -e "${YELLOW}Fetching configuration details...${NC}"
        ic_json=$(oci compute-management instance-configuration get \
            --instance-configuration-id "$ic_ocid" \
            --output json 2>/dev/null)
        
        if [[ -z "$ic_json" ]]; then
            echo -e "${RED}Failed to fetch instance configuration details${NC}"
            echo -e "Press Enter to continue..."
            read -r
            return
        fi
    fi
    
    # Extract details for recommended name
    local shape network_type oke_version
    shape=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["shape"] // "unknown"')
    
    # Determine network type from metadata
    local native_networking
    native_networking=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["metadata"]["oke-native-pod-networking"] // "false"')
    if [[ "$native_networking" == "true" ]]; then
        network_type="native"
    else
        network_type="flannel"
    fi
    
    # Try to extract kubernetes version from user_data
    local user_data_b64
    user_data_b64=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["metadata"]["user_data"] // empty')
    oke_version="unknown"
    if [[ -n "$user_data_b64" ]]; then
        local decoded_ud
        decoded_ud=$(echo "$user_data_b64" | base64 -d 2>/dev/null)
        local extracted_version
        extracted_version=$(echo "$decoded_ud" | grep -oP 'kubernetes-\K[0-9]+\.[0-9]+' | head -1)
        if [[ -z "$extracted_version" ]]; then
            extracted_version=$(echo "$decoded_ud" | grep -oP 'oci-oke-node-all-\K[0-9]+\.[0-9]+' | head -1)
        fi
        if [[ -n "$extracted_version" ]]; then
            oke_version="$extracted_version"
        fi
    fi
    
    # Count existing configs with similar pattern
    local base_pattern="${shape}-ic-oke-${oke_version}-${network_type}"
    local existing_count=0
    if [[ -f "$INSTANCE_CONFIG_CACHE" ]]; then
        existing_count=$(grep -c "${base_pattern}" "$INSTANCE_CONFIG_CACHE" 2>/dev/null) || existing_count=0
        [[ ! "$existing_count" =~ ^[0-9]+$ ]] && existing_count=0
    fi
    local next_num=$((existing_count + 1))
    
    # Generate recommended name
    local recommended_name="${shape}-ic-oke-${oke_version}-${network_type}-${next_num}"
    
    echo -e "${WHITE}Current Name:${NC}     ${CYAN}$ic_current_name${NC}"
    echo -e "${WHITE}Shape:${NC}            $shape"
    echo -e "${WHITE}Network Type:${NC}     $network_type"
    echo -e "${WHITE}OKE Version:${NC}      $oke_version"
    echo ""
    echo -e "${BOLD}${GREEN}Recommended:${NC}      ${WHITE}$recommended_name${NC}"
    echo ""
    
    echo -n -e "${CYAN}Enter new name [${recommended_name}]: ${NC}"
    local new_name
    read -r new_name
    
    [[ -z "$new_name" ]] && new_name="$recommended_name"
    
    if [[ "$new_name" == "$ic_current_name" ]]; then
        echo -e "${YELLOW}New name is the same as current name. No changes made.${NC}"
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    # Show command
    echo ""
    echo -e "${BOLD}${YELLOW}Command:${NC}"
    echo -e "oci compute-management instance-configuration update \\"
    echo -e "  --instance-configuration-id \"$ic_ocid\" \\"
    echo -e "  --display-name \"$new_name\""
    echo ""
    
    echo -n -e "${CYAN}Type 'RENAME' to confirm: ${NC}"
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "RENAME" ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    # Log file
    local log_file="instance_config_rename_$(date +%Y%m%d_%H%M%S).log"
    
    {
        echo "=========================================="
        echo "Instance Configuration Rename"
        echo "Timestamp: $(date)"
        echo "=========================================="
        echo "OCID: $ic_ocid"
        echo "Current Name: $ic_current_name"
        echo "New Name: $new_name"
        echo ""
        echo "Command:"
        echo "oci compute-management instance-configuration update \\"
        echo "  --instance-configuration-id \"$ic_ocid\" \\"
        echo "  --display-name \"$new_name\""
        echo ""
        echo "=========================================="
        echo "Execution Output:"
        echo "=========================================="
    } > "$log_file"
    
    echo ""
    echo -e "${YELLOW}Renaming...${NC}"
    
    local result
    result=$(oci compute-management instance-configuration update \
        --instance-configuration-id "$ic_ocid" \
        --display-name "$new_name" 2>&1)
    local exit_code=$?
    
    echo "$result" >> "$log_file"
    
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}✓ Renamed successfully!${NC}"
        echo -e "  ${RED}Old:${NC} $ic_current_name"
        echo -e "  ${GREEN}New:${NC} $new_name"
        rm -f "$INSTANCE_CONFIG_CACHE"
    else
        echo -e "${RED}✗ Failed to rename${NC}"
        echo "$result"
    fi
    
    echo -e "${WHITE}Log: $log_file${NC}"
    echo ""
    echo -e "Press Enter to continue..."
    read -r
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
        echo -e "  ${MAGENTA}refresh${NC}     - Refresh data from OCI"
        echo -e "  ${CYAN}back${NC}        - Return to main menu"
        echo ""
        echo -n -e "${BOLD}${CYAN}Enter # or command [f#/g#/i#/c#/create/update/refresh/back]: ${NC}"
        
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
                
                # Check if user_data exists
                local has_user_data="false"
                local user_data_b64
                user_data_b64=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["metadata"]["user_data"] // empty' 2>/dev/null)
                [[ -n "$user_data_b64" ]] && has_user_data="true"
                
                # Check for other metadata
                local ssh_keys
                ssh_keys=$(echo "$ic_json" | jq -r '.data["instance-details"]["launch-details"]["metadata"]["ssh_authorized_keys"] // empty' 2>/dev/null)
                if [[ -n "$ssh_keys" ]]; then
                    echo ""
                    echo -e "${BOLD}${CYAN}SSH Keys:${NC}"
                    echo -e "  ${GRAY}(SSH authorized keys are configured)${NC}"
                fi
                
                if [[ "$has_user_data" == "true" ]]; then
                    echo ""
                    echo -e "${BOLD}${CYAN}User Data:${NC}"
                    echo -e "  ${GREEN}✓ Cloud-init user-data is configured${NC}"
                fi
                
                # Show action option
                echo ""
                echo -e "${BOLD}${WHITE}Actions:${NC}"
                if [[ "$has_user_data" == "true" ]]; then
                    echo -e "  ${MAGENTA}user-data${NC}  - View decoded cloud-init user-data"
                    echo -e "  ${MAGENTA}save${NC}       - Save user-data to file (cloud-init.yml)"
                fi
                echo -e "  ${RED}delete${NC}     - Delete this instance configuration"
                echo -e "  ${CYAN}Enter${NC}      - Return to menu"
                echo ""
                echo -n -e "${CYAN}Action [user-data/save/delete/Enter]: ${NC}"
                
                local action
                read -r action
                
                if [[ "$action" == "user-data" || "$action" == "userdata" || "$action" == "ud" ]]; then
                    if [[ "$has_user_data" == "true" ]]; then
                        echo ""
                        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
                        echo -e "${BOLD}${MAGENTA}                         DECODED CLOUD-INIT USER-DATA                          ${NC}"
                        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
                        echo ""
                        # Decode and display the user-data (handles gzip)
                        if is_user_data_gzip "$user_data_b64"; then
                            echo -e "${GRAY}(gzip compressed - decompressing)${NC}"
                            echo ""
                        fi
                        decode_user_data "$user_data_b64"
                        echo ""
                        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════${NC}"
                        echo ""
                        echo -n -e "${CYAN}Press Enter to continue...${NC}"
                        read -r
                    else
                        echo -e "${YELLOW}No user-data found in this instance configuration${NC}"
                    fi
                elif [[ "$action" == "save" || "$action" == "SAVE" ]]; then
                    if [[ "$has_user_data" == "true" ]]; then
                        # Generate safe filename from instance config name
                        local safe_name
                        safe_name=$(echo "$ic_name" | tr ' ' '_' | tr -cd '[:alnum:]_-')
                        local filename="${safe_name}_cloud-init.yml"
                        
                        echo ""
                        echo -n -e "${CYAN}Save as [${filename}]: ${NC}"
                        local custom_filename
                        read -r custom_filename
                        [[ -n "$custom_filename" ]] && filename="$custom_filename"
                        
                        # Decode and save (handles gzip)
                        local gzip_msg=""
                        if is_user_data_gzip "$user_data_b64"; then
                            gzip_msg=" ${GRAY}(decompressed from gzip)${NC}"
                        fi
                        
                        if decode_user_data_to_file "$user_data_b64" "$filename"; then
                            echo -e "${GREEN}✓ User-data saved to: ${WHITE}$(pwd)/${filename}${NC}${gzip_msg}"
                        else
                            echo -e "${RED}Failed to save user-data${NC}"
                        fi
                        echo ""
                        echo -n -e "${CYAN}Press Enter to continue...${NC}"
                        read -r
                    else
                        echo -e "${YELLOW}No user-data found in this instance configuration${NC}"
                    fi
                elif [[ "$action" == "delete" || "$action" == "DELETE" ]]; then
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
    printf "${BOLD}%-6s %-40s %-35s %-12s${NC}\n" \
        "ID" "Compute Cluster Name" "Availability Domain" "Status"
    print_separator 95
    
    local cc_output_temp
    cc_output_temp=$(mktemp)
    
    local cid
    for cid in "${!CC_INDEX_MAP[@]}"; do
        local cc_ocid="${CC_INDEX_MAP[$cid]}"
        [[ -z "$cc_ocid" ]] && continue
        
        # Get compute cluster info from cache
        local cc_line cc_name cc_ad cc_state
        cc_line=$(grep "^${cc_ocid}|" "$COMPUTE_CLUSTER_CACHE" 2>/dev/null | head -1)
        if [[ -n "$cc_line" ]]; then
            IFS='|' read -r _ cc_name cc_ad cc_state <<< "$cc_line"
            # Default state if not present (old cache format)
            [[ -z "$cc_state" ]] && cc_state="UNKNOWN"
        else
            cc_name="N/A"
            cc_ad="N/A"
            cc_state="UNKNOWN"
        fi
        
        # Skip deleted clusters
        [[ "$cc_state" == "DELETED" ]] && continue
        
        local cid_num="${cid#c}"
        echo "${cid_num}|${cid}|${cc_name}|${cc_ad}|${cc_state}" >> "$cc_output_temp"
    done
    
    sort -t'|' -k1 -n "$cc_output_temp" | while IFS='|' read -r _ cid cc_name cc_ad cc_state; do
        # Color-code the status
        local state_color="$GREEN"
        case "$cc_state" in
            ACTIVE) state_color="$GREEN" ;;
            CREATING|UPDATING) state_color="$YELLOW" ;;
            DELETING) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        printf "${YELLOW}%-6s${NC} ${CYAN}%-40s${NC} ${MAGENTA}%-35s${NC} ${state_color}%-12s${NC}\n" \
            "$cid" "$cc_name" "$cc_ad" "$cc_state"
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
# Manage Compute Clusters - Main menu for compute cluster operations
#--------------------------------------------------------------------------------
manage_compute_clusters() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}                                         COMPUTE CLUSTER MANAGEMENT                                              ${NC}"
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}Environment:${NC}"
        echo -e "  ${CYAN}Region:${NC}      ${WHITE}${region}${NC}"
        echo -e "  ${CYAN}Compartment:${NC} ${YELLOW}${compartment_id}${NC}"
        echo ""
        
        # ========== Show Existing Compute Clusters ==========
        echo -e "${BOLD}${MAGENTA}─── Existing Compute Clusters ───${NC}"
        echo ""
        
        # Refresh compute cluster cache
        fetch_compute_clusters "$compartment_id" "$region"
        
        # Build array for selection
        declare -a CC_LIST=()
        local cc_count=0
        
        if [[ -f "$COMPUTE_CLUSTER_CACHE" ]] && [[ -s "$COMPUTE_CLUSTER_CACHE" ]]; then
            printf "  ${GRAY}%-4s %-45s %-35s %-12s${NC}\n" "#" "Display Name" "Availability Domain" "Status"
            echo -e "  ${GRAY}──────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
            while IFS='|' read -r cc_ocid cc_name cc_ad cc_state; do
                [[ -z "$cc_ocid" || "$cc_ocid" == "#"* ]] && continue
                
                # Default state if not present (old cache format)
                [[ -z "$cc_state" ]] && cc_state="UNKNOWN"
                
                # Skip deleted clusters
                [[ "$cc_state" == "DELETED" ]] && continue
                ((cc_count++))
                CC_LIST+=("$cc_ocid|$cc_name|$cc_ad|$cc_state")
                
                # Color-code the status
                local state_color="$GREEN"
                case "$cc_state" in
                    ACTIVE) state_color="$GREEN" ;;
                    CREATING|UPDATING) state_color="$YELLOW" ;;
                    DELETING) state_color="$RED" ;;
                    *) state_color="$GRAY" ;;
                esac
                
                printf "  ${YELLOW}%-4s${NC} ${WHITE}%-45s${NC} ${CYAN}%-35s${NC} ${state_color}%-12s${NC}\n" "$cc_count)" "$cc_name" "$cc_ad" "$cc_state"
            done < <(grep -v '^#' "$COMPUTE_CLUSTER_CACHE" 2>/dev/null)
            
            if [[ $cc_count -eq 0 ]]; then
                echo -e "  ${GRAY}(No existing compute clusters found)${NC}"
            else
                echo ""
                echo -e "  ${WHITE}Total: ${GREEN}${cc_count}${WHITE} compute cluster(s)${NC}"
            fi
        else
            echo -e "  ${GRAY}(No existing compute clusters found)${NC}"
        fi
        echo ""
        
        # ========== Menu Options ==========
        echo -e "${BOLD}${WHITE}═══ Actions ═══${NC}"
        echo ""
        echo -e "  ${GREEN}c${NC}) ${WHITE}Create${NC}  - Create a new compute cluster"
        if [[ $cc_count -gt 0 ]]; then
            echo -e "  ${RED}d${NC}) ${WHITE}Delete${NC}  - Delete an existing compute cluster"
            echo -e "  ${CYAN}v${NC}) ${WHITE}View${NC}    - View compute cluster details (enter number)"
        fi
        echo -e "  ${CYAN}r${NC}) ${WHITE}Refresh${NC} - Refresh compute cluster list"
        echo -e "  ${WHITE}b${NC}) ${WHITE}Back${NC}    - Return to main menu"
        echo ""
        echo -n -e "${BOLD}${CYAN}Enter selection [c/d/v/r/b] or cluster number: ${NC}"
        
        local choice
        read -r choice
        
        case "$choice" in
            c|C|create|CREATE)
                create_compute_cluster_interactive
                ;;
            d|D|delete|DELETE)
                if [[ $cc_count -eq 0 ]]; then
                    echo -e "${YELLOW}No compute clusters available to delete${NC}"
                    sleep 1
                else
                    delete_compute_cluster_interactive
                fi
                ;;
            v|V|view|VIEW)
                if [[ $cc_count -gt 0 ]]; then
                    echo -n -e "${CYAN}Enter cluster number to view [1-${cc_count}]: ${NC}"
                    local view_num
                    read -r view_num
                    if [[ "$view_num" =~ ^[0-9]+$ ]] && [[ $view_num -ge 1 ]] && [[ $view_num -le $cc_count ]]; then
                        local selected="${CC_LIST[$((view_num-1))]}"
                        local sel_ocid sel_name sel_ad sel_state
                        IFS='|' read -r sel_ocid sel_name sel_ad sel_state <<< "$selected"
                        view_compute_cluster_details "$sel_ocid" "$sel_name"
                    else
                        echo -e "${RED}Invalid selection${NC}"
                        sleep 1
                    fi
                else
                    echo -e "${YELLOW}No compute clusters available to view${NC}"
                    sleep 1
                fi
                ;;
            r|R|refresh|REFRESH)
                rm -f "$COMPUTE_CLUSTER_CACHE"
                echo -e "${GREEN}Cache cleared, refreshing...${NC}"
                sleep 1
                ;;
            b|B|back|BACK|"")
                return
                ;;
            [0-9]*)
                # Direct number selection for viewing
                if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le $cc_count ]]; then
                    local selected="${CC_LIST[$((choice-1))]}"
                    local sel_ocid sel_name sel_ad sel_state
                    IFS='|' read -r sel_ocid sel_name sel_ad sel_state <<< "$selected"
                    view_compute_cluster_details "$sel_ocid" "$sel_name"
                else
                    echo -e "${RED}Invalid selection${NC}"
                    sleep 1
                fi
                ;;
            *)
                echo -e "${RED}Invalid selection${NC}"
                sleep 1
                ;;
        esac
    done
}

#--------------------------------------------------------------------------------
# View Compute Cluster details
#--------------------------------------------------------------------------------
view_compute_cluster_details() {
    local cc_ocid="$1"
    local cc_name="$2"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Compute Cluster Details ═══${NC}"
    echo ""
    echo -e "${YELLOW}Fetching details for: ${WHITE}${cc_name}${NC}"
    echo ""
    
    local cc_json
    cc_json=$(oci compute compute-cluster get --compute-cluster-id "$cc_ocid" 2>/dev/null)
    
    if [[ -z "$cc_json" ]]; then
        echo -e "${RED}Failed to fetch compute cluster details${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    echo "$cc_json" | jq -r '
        .data | 
        "  Display Name:        \(.["display-name"] // "N/A")",
        "  OCID:                \(.id)",
        "  Availability Domain: \(.["availability-domain"] // "N/A")",
        "  Lifecycle State:     \(.["lifecycle-state"] // "N/A")",
        "  Time Created:        \(.["time-created"] // "N/A")"
    '
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Delete Compute Cluster interactively
#--------------------------------------------------------------------------------
delete_compute_cluster_interactive() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    echo ""
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${RED}                                       DELETE COMPUTE CLUSTER                                                     ${NC}"
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Fetch and display compute clusters
    fetch_compute_clusters "$compartment_id" "$region"
    
    declare -a CC_LIST=()
    local cc_count=0
    
    if [[ -f "$COMPUTE_CLUSTER_CACHE" ]] && [[ -s "$COMPUTE_CLUSTER_CACHE" ]]; then
        printf "  ${GRAY}%-4s %-45s %-35s %-12s${NC}\n" "#" "Display Name" "Availability Domain" "Status"
        echo -e "  ${GRAY}──────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        while IFS='|' read -r cc_ocid cc_name cc_ad cc_state; do
            [[ -z "$cc_ocid" || "$cc_ocid" == "#"* ]] && continue
            
            # Default state if not present (old cache format)
            [[ -z "$cc_state" ]] && cc_state="UNKNOWN"
            
            # Skip deleted clusters
            [[ "$cc_state" == "DELETED" ]] && continue
            ((cc_count++))
            CC_LIST+=("$cc_ocid|$cc_name|$cc_ad|$cc_state")
            
            # Color-code the status
            local state_color="$GREEN"
            case "$cc_state" in
                ACTIVE) state_color="$GREEN" ;;
                CREATING|UPDATING) state_color="$YELLOW" ;;
                DELETING) state_color="$RED" ;;
                *) state_color="$GRAY" ;;
            esac
            
            printf "  ${YELLOW}%-4s${NC} ${WHITE}%-45s${NC} ${CYAN}%-35s${NC} ${state_color}%-12s${NC}\n" "$cc_count)" "$cc_name" "$cc_ad" "$cc_state"
        done < <(grep -v '^#' "$COMPUTE_CLUSTER_CACHE" 2>/dev/null)
    fi
    
    if [[ $cc_count -eq 0 ]]; then
        echo -e "  ${GRAY}(No compute clusters found to delete)${NC}"
        echo ""
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Enter cluster number to delete [1-${cc_count}] or 'b' to go back: ${NC}"
    local del_choice
    read -r del_choice
    
    if [[ "$del_choice" == "b" || "$del_choice" == "B" || -z "$del_choice" ]]; then
        return
    fi
    
    if ! [[ "$del_choice" =~ ^[0-9]+$ ]] || [[ $del_choice -lt 1 ]] || [[ $del_choice -gt $cc_count ]]; then
        echo -e "${RED}Invalid selection${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    local selected="${CC_LIST[$((del_choice-1))]}"
    local sel_ocid sel_name sel_ad sel_state
    IFS='|' read -r sel_ocid sel_name sel_ad sel_state <<< "$selected"
    
    echo ""
    echo -e "${BOLD}${WHITE}Selected Compute Cluster:${NC}"
    echo -e "  ${CYAN}Display Name:${NC}        ${WHITE}${sel_name}${NC}"
    echo -e "  ${CYAN}OCID:${NC}                ${YELLOW}${sel_ocid}${NC}"
    echo -e "  ${CYAN}Availability Domain:${NC} ${WHITE}${sel_ad}${NC}"
    echo -e "  ${CYAN}Status:${NC}              ${WHITE}${sel_state}${NC}"
    echo ""
    
    # Use global DEBUG_MODE
    local debug_flag=""
    if [[ "$DEBUG_MODE" == "true" ]]; then
        debug_flag="--debug"
    fi
    
    # ========== Show Command ==========
    echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${YELLOW}                                          COMMAND TO EXECUTE                                                     ${NC}"
    echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local cmd="oci compute compute-cluster delete \\
    --compute-cluster-id \"${sel_ocid}\" \\
    --force"
    
    [[ -n "$debug_flag" ]] && cmd="${cmd} \\
    ${debug_flag}"
    
    echo -e "${WHITE}${cmd}${NC}"
    echo ""
    
    # Log file for the action
    local log_file="compute_cluster_delete_$(date +%Y%m%d_%H%M%S).log"
    
    echo -e "${BOLD}${RED}═══ CONFIRM DELETION ═══${NC}"
    echo ""
    echo -e "${RED}WARNING: This action cannot be undone!${NC}"
    echo -e "${WHITE}Log file: ${CYAN}${log_file}${NC}"
    echo ""
    echo -n -e "${CYAN}Type 'DELETE' to confirm, or anything else to cancel: ${NC}"
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        echo -e "Press Enter to return..."
        read -r
        return
    fi
    
    # ========== Execute the Command ==========
    echo ""
    echo -e "${YELLOW}Deleting Compute Cluster...${NC}"
    
    # Log the command
    {
        echo "=========================================="
        echo "Compute Cluster Deletion"
        echo "Timestamp: $(date)"
        echo "=========================================="
        echo ""
        echo "Display Name:        ${sel_name}"
        echo "OCID:                ${sel_ocid}"
        echo "Availability Domain: ${sel_ad}"
        echo "Debug Mode:          ${debug_flag:-disabled}"
        echo ""
        echo "Command:"
        echo "oci compute compute-cluster delete \\"
        echo "    --compute-cluster-id \"${sel_ocid}\" \\"
        echo "    --force ${debug_flag}"
        echo ""
        echo "=========================================="
        echo "Execution Output:"
        echo "=========================================="
    } > "$log_file"
    
    local result
    if [[ -n "$debug_flag" ]]; then
        result=$(oci compute compute-cluster delete \
            --compute-cluster-id "${sel_ocid}" \
            --force \
            --debug 2>&1)
    else
        result=$(oci compute compute-cluster delete \
            --compute-cluster-id "${sel_ocid}" \
            --force 2>&1)
    fi
    local exit_code=$?
    
    # Log the result
    echo "$result" >> "$log_file"
    
    if [[ $exit_code -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                                        COMPUTE CLUSTER DELETED                                                   ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${CYAN}Display Name:${NC} ${WHITE}${sel_name}${NC}"
        echo -e "  ${CYAN}OCID:${NC}         ${YELLOW}${sel_ocid}${NC}"
        echo ""
        echo -e "  ${WHITE}Log file: ${CYAN}${log_file}${NC}"
        echo ""
        
        # Invalidate compute cluster cache
        rm -f "$COMPUTE_CLUSTER_CACHE"
        echo -e "${GRAY}(Compute cluster cache cleared)${NC}"
        
        # Log success
        {
            echo ""
            echo "=========================================="
            echo "Result: SUCCESS"
            echo "=========================================="
        } >> "$log_file"
    else
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                                      COMPUTE CLUSTER DELETION FAILED                                            ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${RED}Error:${NC}"
        echo "$result"
        echo ""
        echo -e "  ${WHITE}Log file: ${CYAN}${log_file}${NC}"
        
        # Log failure
        {
            echo ""
            echo "=========================================="
            echo "Result: FAILED"
            echo "Exit Code: ${exit_code}"
            echo "=========================================="
        } >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Create Compute Cluster interactively
#--------------------------------------------------------------------------------
create_compute_cluster_interactive() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    local selected_ad="${AD:-}"
    local shape_name="${SHAPE_NAME:-GPU}"
    
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}                                       CREATE COMPUTE CLUSTER                                                    ${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Validate required variables
    local missing_vars=""
    [[ -z "$compartment_id" ]] && missing_vars+="COMPARTMENT_ID "
    [[ -z "$selected_ad" ]] && missing_vars+="AD "
    
    if [[ -n "$missing_vars" ]]; then
        echo -e "${RED}Missing required variables in variables.sh:${NC}"
        echo -e "${YELLOW}  $missing_vars${NC}"
        echo ""
        echo -e "${WHITE}Please run ${CYAN}--setup${WHITE} or manually configure variables.sh${NC}"
        echo ""
        echo -e "Press Enter to return..."
        read -r
        return 1
    fi
    
    echo -e "${BOLD}${WHITE}Current Environment:${NC}"
    echo -e "  ${CYAN}Region:${NC}              ${WHITE}${region}${NC}"
    echo -e "  ${CYAN}Compartment:${NC}         ${YELLOW}${compartment_id}${NC}"
    echo -e "  ${CYAN}Availability Domain:${NC} ${WHITE}${selected_ad}${NC}"
    echo -e "  ${CYAN}Shape:${NC}               ${WHITE}${shape_name}${NC}"
    [[ "$DEBUG_MODE" == "true" ]] && echo -e "  ${CYAN}Debug Mode:${NC}          ${YELLOW}ENABLED${NC}"
    echo ""
    
    # ========== Enter Display Name ==========
    echo -e "${BOLD}${MAGENTA}─── Compute Cluster Display Name ───${NC}"
    echo ""
    
    # Default name based on shape from variables.sh
    local default_name="${shape_name}-Compute-Cluster"
    echo -e "${WHITE}Common naming patterns:${NC}"
    echo -e "  ${GRAY}- <shape>-Compute-Cluster (e.g., BM.GPU.H100.8-Compute-Cluster)${NC}"
    echo -e "  ${GRAY}- <project>-cc-<ad> (e.g., ml-training-cc-ad1)${NC}"
    echo ""
    
    echo -n -e "${CYAN}Enter display name [${default_name}]: ${NC}"
    local display_name
    read -r display_name
    
    [[ -z "$display_name" ]] && display_name="$default_name"
    
    echo -e "${GREEN}✓ Display Name: ${WHITE}${display_name}${NC}"
    echo ""
    
    # Use global DEBUG_MODE (set via --debug command line flag)
    local debug_flag=""
    if [[ "$DEBUG_MODE" == "true" ]]; then
        debug_flag="--debug"
    fi
    
    # ========== Show Command and Confirm ==========
    echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${YELLOW}                                          COMMAND TO EXECUTE                                                     ${NC}"
    echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local cmd="oci compute compute-cluster create \\
    --availability-domain \"${selected_ad}\" \\
    --compartment-id \"${compartment_id}\" \\
    --display-name \"${display_name}\""
    
    [[ -n "$debug_flag" ]] && cmd="${cmd} \\
    ${debug_flag}"
    
    echo -e "${WHITE}${cmd}${NC}"
    echo ""
    
    # Log file for the action
    local log_file="compute_cluster_create_$(date +%Y%m%d_%H%M%S).log"
    
    echo -e "${BOLD}${RED}═══ CONFIRM CREATION ═══${NC}"
    echo ""
    echo -e "${YELLOW}This will create a new Compute Cluster.${NC}"
    echo -e "${WHITE}Log file: ${CYAN}${log_file}${NC}"
    echo ""
    echo -n -e "${CYAN}Type 'CREATE' to confirm, or anything else to cancel: ${NC}"
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "CREATE" ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        echo -e "Press Enter to return..."
        read -r
        return 0
    fi
    
    # ========== Execute the Command ==========
    echo ""
    echo -e "${YELLOW}Creating Compute Cluster...${NC}"
    
    # Log the command
    {
        echo "=========================================="
        echo "Compute Cluster Creation"
        echo "Timestamp: $(date)"
        echo "=========================================="
        echo ""
        echo "Display Name:        ${display_name}"
        echo "Availability Domain: ${selected_ad}"
        echo "Compartment ID:      ${compartment_id}"
        echo "Region:              ${region}"
        echo "Debug Mode:          ${debug_flag:-disabled}"
        echo ""
        echo "Command:"
        echo "oci compute compute-cluster create \\"
        echo "    --availability-domain \"${selected_ad}\" \\"
        echo "    --compartment-id \"${compartment_id}\" \\"
        echo "    --display-name \"${display_name}\" ${debug_flag}"
        echo ""
        echo "=========================================="
        echo "Execution Output:"
        echo "=========================================="
    } > "$log_file"
    
    local result
    if [[ -n "$debug_flag" ]]; then
        result=$(oci compute compute-cluster create \
            --availability-domain "${selected_ad}" \
            --compartment-id "${compartment_id}" \
            --display-name "${display_name}" \
            --debug 2>&1)
    else
        result=$(oci compute compute-cluster create \
            --availability-domain "${selected_ad}" \
            --compartment-id "${compartment_id}" \
            --display-name "${display_name}" 2>&1)
    fi
    local exit_code=$?
    
    # Log the result
    echo "$result" >> "$log_file"
    
    if [[ $exit_code -eq 0 ]]; then
        local new_ocid
        new_ocid=$(echo "$result" | jq -r '.data.id // empty' 2>/dev/null)
        local new_state
        new_state=$(echo "$result" | jq -r '.data["lifecycle-state"] // "UNKNOWN"' 2>/dev/null)
        
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                                        COMPUTE CLUSTER CREATED                                                  ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${CYAN}Display Name:${NC}        ${WHITE}${display_name}${NC}"
        echo -e "  ${CYAN}OCID:${NC}                ${YELLOW}${new_ocid}${NC}"
        echo -e "  ${CYAN}Availability Domain:${NC} ${WHITE}${selected_ad}${NC}"
        echo -e "  ${CYAN}State:${NC}               ${GREEN}${new_state}${NC}"
        echo ""
        echo -e "  ${WHITE}Log file: ${CYAN}${log_file}${NC}"
        echo ""
        
        # Invalidate compute cluster cache
        rm -f "$COMPUTE_CLUSTER_CACHE"
        echo -e "${GRAY}(Compute cluster cache cleared - will refresh on next access)${NC}"
        
        # Log success
        {
            echo ""
            echo "=========================================="
            echo "Result: SUCCESS"
            echo "New OCID: ${new_ocid}"
            echo "State: ${new_state}"
            echo "=========================================="
        } >> "$log_file"
    else
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                                      COMPUTE CLUSTER CREATION FAILED                                            ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${RED}Error:${NC}"
        echo "$result"
        echo ""
        echo -e "  ${WHITE}Log file: ${CYAN}${log_file}${NC}"
        
        # Log failure
        {
            echo ""
            echo "=========================================="
            echo "Result: FAILED"
            echo "Exit Code: ${exit_code}"
            echo "=========================================="
        } >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#===============================================================================
# GPU INSTANCE TAGGING MANAGEMENT
#===============================================================================

# Default tag namespace and tag settings for GPU instance host actions
GPU_TAG_NAMESPACE="${GPU_TAG_NAMESPACE:-ComputeInstanceHostActions}"
GPU_TAG_NAMESPACE_DESCRIPTION="${GPU_TAG_NAMESPACE_DESCRIPTION:-Compute Instance Actions Tag Namespace}"
GPU_TAG_NAME="${GPU_TAG_NAME:-CustomerReportedHostStatus}"
GPU_TAG_NAME_DESCRIPTION="${GPU_TAG_NAME_DESCRIPTION:-host is unhealthy and needs manual intervention before returning to the previous pool post-recycle}"
GPU_TAG_VALUES="${GPU_TAG_VALUES:-unhealthy}"

#--------------------------------------------------------------------------------
# Get tenancy home region (required for IAM operations)
# OCI Command: oci iam region-subscription list --tenancy-id <TENANCY_ID>
#--------------------------------------------------------------------------------
get_home_region() {
    local tenancy_ocid="${TENANCY_ID:-$TENANCY_OCID}"
    
    if [[ -z "$tenancy_ocid" ]]; then
        echo ""
        return 1
    fi
    
    local home_region
    # Query home region from tenancy's region subscriptions
    home_region=$(oci iam region-subscription list \
        --tenancy-id "$tenancy_ocid" \
        --query "data[?\"is-home-region\"==\`true\`].\"region-name\" | [0]" \
        --raw-output 2>/dev/null)
    
    echo "$home_region"
}

#--------------------------------------------------------------------------------
# Manage GPU Instance Tagging - Main menu
#--------------------------------------------------------------------------------
manage_gpu_instance_tagging() {
    local tenancy_ocid="${TENANCY_ID:-$TENANCY_OCID}"
    local home_region
    
    # Get home region for IAM operations
    echo -e "${GRAY}Detecting home region...${NC}"
    home_region=$(get_home_region)
    
    if [[ -z "$home_region" ]]; then
        echo ""
        echo -e "${RED}Error: Could not determine home region.${NC}"
        echo -e "${YELLOW}Please ensure TENANCY_ID or TENANCY_OCID is set in variables.sh${NC}"
        echo ""
        echo -e "Press Enter to return..."
        read -r
        return 1
    fi
    
    while true; do
        echo ""
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${MAGENTA}                                        GPU INSTANCE TAGGING                                                     ${NC}"
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}Configuration:${NC}"
        echo -e "  ${CYAN}Tenancy:${NC}     ${YELLOW}${tenancy_ocid}${NC}"
        echo -e "  ${CYAN}Home Region:${NC} ${WHITE}${home_region}${NC}"
        echo -e "  ${CYAN}Namespace:${NC}   ${WHITE}${GPU_TAG_NAMESPACE}${NC}"
        echo -e "  ${CYAN}Tag Name:${NC}    ${WHITE}${GPU_TAG_NAME}${NC}"
        echo -e "  ${CYAN}Tag Values:${NC}  ${WHITE}${GPU_TAG_VALUES}${NC}"
        echo ""
        echo -e "${GRAY}Home region derived from: oci iam region-subscription list --tenancy-id \"\$TENANCY_ID\" --query \"data[?\\\"is-home-region\\\"==\\\`true\\\`].\\\"region-name\\\" | [0]\"${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}═══ Actions ═══${NC}"
        echo ""
        echo -e "  ${GREEN}1${NC}) ${WHITE}Create namespace and tag${NC}      - Create ${GPU_TAG_NAMESPACE} namespace with ${GPU_TAG_NAME} tag"
        echo -e "  ${CYAN}2${NC}) ${WHITE}Validate namespace and tag${NC}    - Check if namespace exists with proper tag configuration"
        echo -e "  ${RED}3${NC}) ${WHITE}Delete namespace${NC}              - Retire and cascade-delete the namespace"
        echo ""
        echo -e "  ${WHITE}b${NC}) Back to main menu"
        echo ""
        echo -n -e "${BOLD}${CYAN}Enter selection [1-3/b]: ${NC}"
        
        local choice
        read -r choice
        
        case "$choice" in
            1)
                create_gpu_tagging_namespace "$tenancy_ocid" "$home_region"
                ;;
            2)
                validate_gpu_tagging_namespace "$tenancy_ocid" "$home_region"
                ;;
            3)
                delete_gpu_tagging_namespace "$tenancy_ocid" "$home_region"
                ;;
            b|B|back|BACK|"")
                return
                ;;
            *)
                echo -e "${RED}Invalid selection${NC}"
                sleep 1
                ;;
        esac
    done
}

#--------------------------------------------------------------------------------
# Create GPU Tagging Namespace and Tag
#--------------------------------------------------------------------------------
create_gpu_tagging_namespace() {
    local tenancy_ocid="$1"
    local home_region="$2"
    
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}                                  CREATE TAG NAMESPACE AND TAG                                                    ${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Use global DEBUG_MODE
    local debug_flag=""
    if [[ "$DEBUG_MODE" == "true" ]]; then
        debug_flag="--debug"
    fi
    
    # Step 1: Check if namespace already exists
    echo -e "${YELLOW}Step 1: Checking if namespace already exists...${NC}"
    echo ""
    
    local check_cmd="oci iam tag-namespace list --compartment-id \"$tenancy_ocid\" --all --query \"data[?name=='${GPU_TAG_NAMESPACE}']\" --output json"
    echo -e "${GRAY}$check_cmd${NC}"
    echo ""
    
    local existing_ns
    existing_ns=$(oci iam tag-namespace list \
        --compartment-id "$tenancy_ocid" \
        --all \
        --query "data[?name=='${GPU_TAG_NAMESPACE}']" \
        --output json 2>/dev/null)
    
    local namespace_ocid
    namespace_ocid=$(echo "$existing_ns" | jq -r '.[0].id // empty' 2>/dev/null)
    
    if [[ -n "$namespace_ocid" ]]; then
        local ns_state
        ns_state=$(echo "$existing_ns" | jq -r '.[0]["lifecycle-state"] // "UNKNOWN"' 2>/dev/null)
        
        echo -e "${YELLOW}⚠ Namespace '${GPU_TAG_NAMESPACE}' already exists${NC}"
        echo -e "  ${CYAN}OCID:${NC}  ${YELLOW}${namespace_ocid}${NC}"
        echo -e "  ${CYAN}State:${NC} ${WHITE}${ns_state}${NC}"
        echo ""
        
        if [[ "$ns_state" == "ACTIVE" ]]; then
            echo -e "${WHITE}Checking if tag '${GPU_TAG_NAME}' exists...${NC}"
            echo ""
            
            local existing_tag
            existing_tag=$(oci iam tag list \
                --tag-namespace-id "$namespace_ocid" \
                --all \
                --query "data[?name=='${GPU_TAG_NAME}']" \
                --output json 2>/dev/null)
            
            local tag_ocid
            tag_ocid=$(echo "$existing_tag" | jq -r '.[0].id // empty' 2>/dev/null)
            
            if [[ -n "$tag_ocid" ]]; then
                echo -e "${GREEN}✓ Tag '${GPU_TAG_NAME}' already exists${NC}"
                echo -e "  ${CYAN}OCID:${NC} ${YELLOW}${tag_ocid}${NC}"
                echo ""
                echo -e "${WHITE}No action needed - namespace and tag are already configured.${NC}"
            else
                echo -e "${YELLOW}Tag '${GPU_TAG_NAME}' does not exist. Creating...${NC}"
                echo ""
                _create_gpu_tag "$namespace_ocid" "$home_region" "$debug_flag"
            fi
        else
            echo -e "${RED}Namespace is in state '${ns_state}' - cannot create tag${NC}"
        fi
        
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    echo -e "${GREEN}✓ Namespace does not exist. Proceeding with creation...${NC}"
    echo ""
    
    # Step 2: Create namespace
    echo -e "${YELLOW}Step 2: Creating tag namespace '${GPU_TAG_NAMESPACE}'...${NC}"
    echo ""
    
    local create_ns_cmd="oci iam tag-namespace create \\
    --compartment-id \"$tenancy_ocid\" \\
    --name \"${GPU_TAG_NAMESPACE}\" \\
    --description \"${GPU_TAG_NAMESPACE_DESCRIPTION}\" \\
    --region \"$home_region\""
    
    echo -e "${BOLD}${YELLOW}Command to execute:${NC}"
    echo -e "${GRAY}$create_ns_cmd${NC}"
    echo ""
    
    echo -n -e "${CYAN}Execute this command? [y/N]: ${NC}"
    local confirm
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo -e "${YELLOW}Operation cancelled${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    echo ""
    log_action "CREATE_TAG_NAMESPACE" "$create_ns_cmd"
    
    local ns_result
    ns_result=$(oci iam tag-namespace create \
        --compartment-id "$tenancy_ocid" \
        --name "${GPU_TAG_NAMESPACE}" \
        --description "${GPU_TAG_NAMESPACE_DESCRIPTION}" \
        --region "$home_region" \
        --output json $debug_flag 2>&1)
    local ns_exit=$?
    
    if [[ $ns_exit -eq 0 ]]; then
        namespace_ocid=$(echo "$ns_result" | jq -r '.data.id // empty' 2>/dev/null)
        echo -e "${GREEN}✓ Namespace created successfully${NC}"
        echo -e "  ${CYAN}OCID:${NC} ${YELLOW}${namespace_ocid}${NC}"
        log_action_result "SUCCESS" "Namespace ${GPU_TAG_NAMESPACE} created: ${namespace_ocid}"
        echo ""
        
        # Wait for namespace to be active
        echo -e "${YELLOW}Waiting for namespace to become active...${NC}"
        sleep 5
        
        # Step 3: Create tag
        echo ""
        echo -e "${YELLOW}Step 3: Creating tag '${GPU_TAG_NAME}' in namespace...${NC}"
        echo ""
        
        _create_gpu_tag "$namespace_ocid" "$home_region" "$debug_flag"
    else
        echo -e "${RED}✗ Failed to create namespace${NC}"
        echo -e "${GRAY}Error: $ns_result${NC}"
        log_action_result "FAILED" "Namespace creation failed"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Helper: Create GPU tag in namespace
#--------------------------------------------------------------------------------
_create_gpu_tag() {
    local namespace_ocid="$1"
    local home_region="$2"
    local debug_flag="$3"
    
    # Build validator JSON for enum values
    local values_json
    values_json=$(echo "${GPU_TAG_VALUES}" | tr ',' '\n' | jq -R . | jq -s '.')
    local validator_json="{\"validator-type\": \"ENUM\", \"values\": ${values_json}}"
    
    local create_tag_cmd="oci iam tag create \\
    --tag-namespace-id \"$namespace_ocid\" \\
    --name \"${GPU_TAG_NAME}\" \\
    --description \"${GPU_TAG_NAME_DESCRIPTION}\" \\
    --validator '${validator_json}' \\
    --region \"$home_region\""
    
    echo -e "${BOLD}${YELLOW}Command to execute:${NC}"
    echo -e "${GRAY}$create_tag_cmd${NC}"
    echo ""
    
    echo -n -e "${CYAN}Execute this command? [y/N]: ${NC}"
    local confirm
    read -r confirm
    
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo -e "${YELLOW}Tag creation cancelled${NC}"
        return
    fi
    
    echo ""
    log_action "CREATE_TAG" "$create_tag_cmd"
    
    local tag_result
    tag_result=$(oci iam tag create \
        --tag-namespace-id "$namespace_ocid" \
        --name "${GPU_TAG_NAME}" \
        --description "${GPU_TAG_NAME_DESCRIPTION}" \
        --validator "$validator_json" \
        --region "$home_region" \
        --output json $debug_flag 2>&1)
    local tag_exit=$?
    
    if [[ $tag_exit -eq 0 ]]; then
        local tag_ocid
        tag_ocid=$(echo "$tag_result" | jq -r '.data.id // empty' 2>/dev/null)
        echo -e "${GREEN}✓ Tag created successfully${NC}"
        echo -e "  ${CYAN}OCID:${NC} ${YELLOW}${tag_ocid}${NC}"
        log_action_result "SUCCESS" "Tag ${GPU_TAG_NAME} created: ${tag_ocid}"
    else
        echo -e "${RED}✗ Failed to create tag${NC}"
        echo -e "${GRAY}Error: $tag_result${NC}"
        log_action_result "FAILED" "Tag creation failed"
    fi
}

#--------------------------------------------------------------------------------
# Validate GPU Tagging Namespace and Tag
#--------------------------------------------------------------------------------
validate_gpu_tagging_namespace() {
    local tenancy_ocid="$1"
    local home_region="$2"
    
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                                  VALIDATE TAG NAMESPACE AND TAG                                                  ${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local all_valid=true
    
    # Step 1: Check namespace exists
    echo -e "${YELLOW}Step 1: Checking for namespace '${GPU_TAG_NAMESPACE}'...${NC}"
    echo ""
    
    local check_cmd="oci iam tag-namespace list --compartment-id \"$tenancy_ocid\" --all --query \"data[?name=='${GPU_TAG_NAMESPACE}']\" --output json"
    echo -e "${GRAY}$check_cmd${NC}"
    echo ""
    
    local existing_ns
    existing_ns=$(oci iam tag-namespace list \
        --compartment-id "$tenancy_ocid" \
        --all \
        --query "data[?name=='${GPU_TAG_NAMESPACE}']" \
        --output json 2>/dev/null)
    
    local namespace_ocid ns_state ns_description
    namespace_ocid=$(echo "$existing_ns" | jq -r '.[0].id // empty' 2>/dev/null)
    
    if [[ -z "$namespace_ocid" ]]; then
        echo -e "${RED}✗ Namespace '${GPU_TAG_NAMESPACE}' does NOT exist${NC}"
        all_valid=false
    else
        ns_state=$(echo "$existing_ns" | jq -r '.[0]["lifecycle-state"] // "UNKNOWN"' 2>/dev/null)
        ns_description=$(echo "$existing_ns" | jq -r '.[0].description // "N/A"' 2>/dev/null)
        
        echo -e "${GREEN}✓ Namespace '${GPU_TAG_NAMESPACE}' exists${NC}"
        echo -e "  ${CYAN}OCID:${NC}        ${YELLOW}${namespace_ocid}${NC}"
        echo -e "  ${CYAN}State:${NC}       ${WHITE}${ns_state}${NC}"
        echo -e "  ${CYAN}Description:${NC} ${WHITE}${ns_description}${NC}"
        
        if [[ "$ns_state" != "ACTIVE" ]]; then
            echo -e "${RED}  ⚠ Namespace is not ACTIVE (state: ${ns_state})${NC}"
            all_valid=false
        fi
    fi
    
    echo ""
    
    # Step 2: Check tag exists
    if [[ -n "$namespace_ocid" && "$ns_state" == "ACTIVE" ]]; then
        echo -e "${YELLOW}Step 2: Checking for tag '${GPU_TAG_NAME}' in namespace...${NC}"
        echo ""
        
        local tag_list_cmd="oci iam tag list --tag-namespace-id \"$namespace_ocid\" --all --output json"
        echo -e "${GRAY}$tag_list_cmd${NC}"
        echo ""
        
        local existing_tags
        existing_tags=$(oci iam tag list \
            --tag-namespace-id "$namespace_ocid" \
            --all \
            --output json 2>/dev/null)
        
        local tag_info
        tag_info=$(echo "$existing_tags" | jq -r ".data[] | select(.name==\"${GPU_TAG_NAME}\")" 2>/dev/null)
        
        if [[ -z "$tag_info" ]]; then
            echo -e "${RED}✗ Tag '${GPU_TAG_NAME}' does NOT exist in namespace${NC}"
            all_valid=false
        else
            local tag_ocid tag_state tag_description validator_type validator_values
            tag_ocid=$(echo "$tag_info" | jq -r '.id // empty')
            tag_state=$(echo "$tag_info" | jq -r '.["lifecycle-state"] // "UNKNOWN"')
            tag_description=$(echo "$tag_info" | jq -r '.description // "N/A"')
            validator_type=$(echo "$tag_info" | jq -r '.validator["validator-type"] // "NONE"')
            validator_values=$(echo "$tag_info" | jq -r '.validator.values // [] | join(", ")')
            
            echo -e "${GREEN}✓ Tag '${GPU_TAG_NAME}' exists${NC}"
            echo -e "  ${CYAN}OCID:${NC}        ${YELLOW}${tag_ocid}${NC}"
            echo -e "  ${CYAN}State:${NC}       ${WHITE}${tag_state}${NC}"
            echo -e "  ${CYAN}Description:${NC} ${WHITE}${tag_description}${NC}"
            echo -e "  ${CYAN}Validator:${NC}   ${WHITE}${validator_type}${NC}"
            if [[ -n "$validator_values" ]]; then
                echo -e "  ${CYAN}Values:${NC}      ${WHITE}${validator_values}${NC}"
            fi
            
            if [[ "$tag_state" != "ACTIVE" ]]; then
                echo -e "${RED}  ⚠ Tag is not ACTIVE (state: ${tag_state})${NC}"
                all_valid=false
            fi
            
            # Check if expected values are present
            local expected_values
            IFS=',' read -ra expected_values <<< "${GPU_TAG_VALUES}"
            for val in "${expected_values[@]}"; do
                if ! echo "$validator_values" | grep -q "$val"; then
                    echo -e "${YELLOW}  ⚠ Expected value '${val}' not found in validator${NC}"
                fi
            done
        fi
        
        echo ""
        
        # List all tags in namespace
        echo -e "${YELLOW}All tags in namespace:${NC}"
        echo ""
        printf "  ${GRAY}%-30s %-12s %-15s %s${NC}\n" "Name" "State" "Validator" "OCID"
        echo "$existing_tags" | jq -r '.data[] | "\(.name)|\(.["lifecycle-state"])|\(.validator["validator-type"] // "NONE")|\(.id)"' 2>/dev/null | \
        while IFS='|' read -r t_name t_state t_validator t_ocid; do
            local state_color="$GREEN"
            [[ "$t_state" != "ACTIVE" ]] && state_color="$YELLOW"
            printf "  ${WHITE}%-30s${NC} ${state_color}%-12s${NC} %-15s ${YELLOW}%s${NC}\n" "$t_name" "$t_state" "$t_validator" "$t_ocid"
        done
    else
        echo -e "${YELLOW}Step 2: Skipping tag check (namespace not available)${NC}"
    fi
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Validation Summary ═══${NC}"
    echo ""
    if [[ "$all_valid" == "true" ]]; then
        echo -e "${GREEN}✓ All validation checks PASSED${NC}"
        echo -e "${WHITE}  The GPU instance tagging namespace and tag are properly configured.${NC}"
    else
        echo -e "${RED}✗ Some validation checks FAILED${NC}"
        echo -e "${WHITE}  Use option 1 to create the missing namespace/tag.${NC}"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Delete GPU Tagging Namespace
#--------------------------------------------------------------------------------
delete_gpu_tagging_namespace() {
    local tenancy_ocid="$1"
    local home_region="$2"
    
    echo ""
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${RED}                                      DELETE TAG NAMESPACE                                                        ${NC}"
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Use global DEBUG_MODE
    local debug_flag=""
    if [[ "$DEBUG_MODE" == "true" ]]; then
        debug_flag="--debug"
    fi
    
    # Step 1: Find namespace
    echo -e "${YELLOW}Step 1: Finding namespace '${GPU_TAG_NAMESPACE}'...${NC}"
    echo ""
    
    local check_cmd="oci iam tag-namespace list --compartment-id \"$tenancy_ocid\" --all --query \"data[?name=='${GPU_TAG_NAMESPACE}']\" --output json"
    echo -e "${GRAY}$check_cmd${NC}"
    echo ""
    
    local existing_ns
    existing_ns=$(oci iam tag-namespace list \
        --compartment-id "$tenancy_ocid" \
        --all \
        --query "data[?name=='${GPU_TAG_NAMESPACE}']" \
        --output json 2>/dev/null)
    
    local namespace_ocid ns_state
    namespace_ocid=$(echo "$existing_ns" | jq -r '.[0].id // empty' 2>/dev/null)
    
    if [[ -z "$namespace_ocid" ]]; then
        echo -e "${YELLOW}Namespace '${GPU_TAG_NAMESPACE}' does not exist. Nothing to delete.${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    ns_state=$(echo "$existing_ns" | jq -r '.[0]["lifecycle-state"] // "UNKNOWN"' 2>/dev/null)
    
    echo -e "${WHITE}Found namespace:${NC}"
    echo -e "  ${CYAN}Name:${NC}  ${WHITE}${GPU_TAG_NAMESPACE}${NC}"
    echo -e "  ${CYAN}OCID:${NC}  ${YELLOW}${namespace_ocid}${NC}"
    echo -e "  ${CYAN}State:${NC} ${WHITE}${ns_state}${NC}"
    echo ""
    
    if [[ "$ns_state" == "DELETED" ]]; then
        echo -e "${YELLOW}Namespace is already in DELETED state${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    # Warning
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                      ⚠️  WARNING  ⚠️                             ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${RED}This will:${NC}"
    echo -e "${WHITE}  1. Retire the namespace (mark as inactive)${NC}"
    echo -e "${WHITE}  2. Cascade-delete the namespace and ALL tags within it${NC}"
    echo ""
    echo -e "${RED}This action cannot be undone!${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm: ${NC}"
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Operation cancelled${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    echo ""
    
    # Step 2: Retire namespace (required before delete)
    if [[ "$ns_state" == "ACTIVE" ]]; then
        echo -e "${YELLOW}Step 2: Retiring namespace...${NC}"
        echo ""
        
        local retire_cmd="oci iam tag-namespace retire \\
    --tag-namespace-id \"$namespace_ocid\" \\
    --region \"$home_region\""
        
        echo -e "${GRAY}$retire_cmd${NC}"
        echo ""
        
        log_action "RETIRE_TAG_NAMESPACE" "$retire_cmd"
        
        local retire_result
        retire_result=$(oci iam tag-namespace retire \
            --tag-namespace-id "$namespace_ocid" \
            --region "$home_region" \
            $debug_flag 2>&1)
        local retire_exit=$?
        
        if [[ $retire_exit -eq 0 ]]; then
            echo -e "${GREEN}✓ Namespace retired successfully${NC}"
            log_action_result "SUCCESS" "Namespace retired"
        else
            echo -e "${RED}✗ Failed to retire namespace${NC}"
            echo -e "${GRAY}Error: $retire_result${NC}"
            log_action_result "FAILED" "Namespace retire failed"
            echo ""
            echo -e "Press Enter to continue..."
            read -r
            return
        fi
        
        echo ""
        echo -e "${YELLOW}Waiting for retire to complete...${NC}"
        sleep 3
    else
        echo -e "${YELLOW}Step 2: Namespace already retired (state: ${ns_state}), skipping retire...${NC}"
    fi
    
    echo ""
    
    # Step 3: Cascade delete
    echo -e "${YELLOW}Step 3: Cascade-deleting namespace and all tags...${NC}"
    echo ""
    
    local delete_cmd="oci iam tag-namespace cascade-delete \\
    --tag-namespace-id \"$namespace_ocid\" \\
    --region \"$home_region\""
    
    echo -e "${GRAY}$delete_cmd${NC}"
    echo ""
    
    log_action "CASCADE_DELETE_TAG_NAMESPACE" "$delete_cmd"
    
    local delete_result
    delete_result=$(oci iam tag-namespace cascade-delete \
        --tag-namespace-id "$namespace_ocid" \
        --region "$home_region" \
        $debug_flag 2>&1)
    local delete_exit=$?
    
    if [[ $delete_exit -eq 0 ]]; then
        echo -e "${GREEN}✓ Namespace cascade-delete initiated successfully${NC}"
        echo -e "${YELLOW}Note: The delete operation runs asynchronously. It may take a few minutes to complete.${NC}"
        log_action_result "SUCCESS" "Namespace cascade-delete initiated"
    else
        echo -e "${RED}✗ Failed to delete namespace${NC}"
        echo -e "${GRAY}Error: $delete_result${NC}"
        log_action_result "FAILED" "Namespace cascade-delete failed"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Create Instance Configuration interactively
#--------------------------------------------------------------------------------
create_instance_configuration_interactive() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    local ad="${AD:-}"
    local worker_subnet="${WORKER_SUBNET_ID:-}"
    local worker_nsg="${WORKER_SUBNET_NSG_ID:-}"
    local image_id="${IMAGE_ID:-}"
    
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}                                    CREATE INSTANCE CONFIGURATION                                               ${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Validate required variables
    local missing_vars=""
    [[ -z "$compartment_id" ]] && missing_vars+="COMPARTMENT_ID "
    [[ -z "$region" ]] && missing_vars+="REGION "
    [[ -z "$ad" ]] && missing_vars+="AD "
    [[ -z "$worker_subnet" ]] && missing_vars+="WORKER_SUBNET_ID "
    [[ -z "$worker_nsg" ]] && missing_vars+="WORKER_SUBNET_NSG_ID "
    
    if [[ -n "$missing_vars" ]]; then
        echo -e "${RED}Missing required variables in variables.sh:${NC}"
        echo -e "${YELLOW}  $missing_vars${NC}"
        echo ""
        echo -e "${WHITE}Please run ${CYAN}--setup${WHITE} or manually configure variables.sh${NC}"
        echo ""
        echo -e "Press Enter to return..."
        read -r
        return 1
    fi
    
    echo -e "${BOLD}${WHITE}Current Environment:${NC}"
    echo -e "  ${CYAN}Region:${NC}           ${WHITE}${region}${NC}"
    echo -e "  ${CYAN}Compartment:${NC}      ${YELLOW}...${compartment_id: -20}${NC}"
    echo -e "  ${CYAN}Availability Domain:${NC} ${WHITE}${ad}${NC}"
    echo -e "  ${CYAN}Worker Subnet:${NC}    ${YELLOW}...${worker_subnet: -20}${NC}"
    echo -e "  ${CYAN}Worker NSG:${NC}       ${YELLOW}...${worker_nsg: -20}${NC}"
    if [[ -n "$image_id" ]]; then
        echo -e "  ${CYAN}Image ID:${NC}         ${YELLOW}...${image_id: -20}${NC}"
    else
        echo -e "  ${CYAN}Image ID:${NC}         ${GRAY}(will select after shape)${NC}"
    fi
    echo ""
    
    # ========== STEP 1: Cloud-init file selection ==========
    echo -e "${BOLD}${MAGENTA}─── Step 1: Cloud-Init Configuration ───${NC}"
    echo ""
    
    local cloud_init_file="cloud-init.yml"
    local cwd
    cwd=$(pwd)
    
    # Check for cloud-init files in current directory (using associative array to avoid duplicates)
    declare -A found_files_map
    local found_files=()
    
    # First pass: collect all matching files, using basename as key to prevent duplicates
    for f in "$cwd"/*.yml "$cwd"/*.yaml "$cwd"/cloud-init*; do
        [[ -f "$f" ]] || continue
        local bname
        bname=$(basename "$f")
        # Only add if not already in map
        if [[ -z "${found_files_map[$bname]:-}" ]]; then
            found_files_map[$bname]="$f"
            found_files+=("$f")
        fi
    done
    
    if [[ ${#found_files[@]} -gt 0 ]]; then
        echo -e "${WHITE}Found cloud-init files in current directory ($cwd):${NC}"
        local idx=0
        for f in "${found_files[@]}"; do
            ((idx++))
            local fname
            fname=$(basename "$f")
            echo -e "  ${YELLOW}${idx}${NC}) $fname"
        done
        echo ""
    fi
    
    echo -n -e "${CYAN}Enter cloud-init file path [${cloud_init_file}]: ${NC}"
    local input_file
    read -r input_file
    
    # Handle numeric selection
    if [[ "$input_file" =~ ^[0-9]+$ ]] && [[ $input_file -ge 1 ]] && [[ $input_file -le ${#found_files[@]} ]]; then
        cloud_init_file="${found_files[$((input_file-1))]}"
    elif [[ -n "$input_file" ]]; then
        cloud_init_file="$input_file"
    fi
    
    # Validate file exists
    if [[ ! -f "$cloud_init_file" ]]; then
        echo -e "${RED}Error: Cloud-init file not found: ${cloud_init_file}${NC}"
        echo -e "Press Enter to return..."
        read -r
        return 1
    fi
    
    echo ""
    echo -e "${GREEN}✓ Using cloud-init file: ${WHITE}${cloud_init_file}${NC}"
    echo ""
    
    # Show preview of cloud-init
    echo -e "${BOLD}${MAGENTA}─── Cloud-Init Preview (first 30 lines) ───${NC}"
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    head -30 "$cloud_init_file"
    local total_lines
    total_lines=$(wc -l < "$cloud_init_file")
    if [[ $total_lines -gt 30 ]]; then
        echo -e "${GRAY}... (${total_lines} total lines, showing first 30)${NC}"
    fi
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    echo -n -e "${CYAN}Is this the correct cloud-init file? [Y/n]: ${NC}"
    local confirm_ci
    read -r confirm_ci
    if [[ "$confirm_ci" =~ ^[Nn] ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        echo -e "Press Enter to return..."
        read -r
        return 0
    fi
    
    # ========== STEP 2: Network Type Selection ==========
    echo ""
    echo -e "${BOLD}${MAGENTA}─── Step 2: Network Type ───${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) ${WHITE}flannel${NC}     - OKE Flannel CNI (overlay networking)"
    echo -e "  ${GREEN}2${NC}) ${WHITE}native${NC}      - OCI VCN Native Pod Networking"
    echo ""
    echo -n -e "${CYAN}Select network type [1]: ${NC}"
    local net_choice
    read -r net_choice
    
    local network_type="flannel"
    local max_pods="60"
    case "$net_choice" in
        2|native|NATIVE)
            network_type="native"
            max_pods="60"
            ;;
        *)
            network_type="flannel"
            max_pods="60"
            ;;
    esac
    echo -e "${GREEN}✓ Network type: ${WHITE}${network_type}${NC}"
    
    # ========== STEP 3: Shape Selection ==========
    echo ""
    echo -e "${BOLD}${MAGENTA}─── Step 3: Instance Shape ───${NC}"
    echo ""
    echo -e "${WHITE}Common GPU shapes:${NC}"
    echo -e "  ${GREEN}1${NC}) BM.GPU.GB200-v3.4  (4x GB200 NVL72)"
    echo -e "  ${GREEN}2${NC}) BM.GPU.H100.8      (8x H100 80GB)"
    echo -e "  ${GREEN}3${NC}) BM.GPU.H200.8      (8x H200 141GB)"
    echo -e "  ${GREEN}4${NC}) BM.GPU.A100-v2.8   (8x A100 80GB)"
    echo -e "  ${GREEN}5${NC}) BM.GPU4.8          (8x A100 40GB)"
    echo -e "  ${GREEN}6${NC}) Custom (enter shape name)"
    echo ""
    
    local shape_name="${SHAPE_NAME:-BM.GPU.H100.8}"
    echo -n -e "${CYAN}Select shape [${shape_name}]: ${NC}"
    local shape_choice
    read -r shape_choice
    
    case "$shape_choice" in
        1) shape_name="BM.GPU.GB200-v3.4" ;;
        2) shape_name="BM.GPU.H100.8" ;;
        3) shape_name="BM.GPU.H200.8" ;;
        4) shape_name="BM.GPU.A100-v2.8" ;;
        5) shape_name="BM.GPU4.8" ;;
        6)
            echo -n -e "${CYAN}Enter custom shape name: ${NC}"
            read -r shape_name
            ;;
        "") ;; # Keep default
        *)
            # If they typed a shape name directly
            if [[ "$shape_choice" =~ ^BM\. ]]; then
                shape_name="$shape_choice"
            fi
            ;;
    esac
    echo -e "${GREEN}✓ Shape: ${WHITE}${shape_name}${NC}"
    
    # ========== STEP 3b: Image Selection ==========
    echo ""
    echo -e "${BOLD}${MAGENTA}─── Step 3b: Image Selection ───${NC}"
    echo ""
    
    echo -e "${YELLOW}Fetching compatible images for ${WHITE}${shape_name}${YELLOW}...${NC}"
    
    # Fetch compatible images for the shape
    local images_json
    images_json=$(oci compute image list \
        --compartment-id "$compartment_id" \
        --shape "$shape_name" \
        --lifecycle-state "AVAILABLE" \
        --sort-by "TIMECREATED" \
        --sort-order "DESC" \
        --limit 15 \
        --output json 2>/dev/null)
    
    local images_count=0
    [[ -n "$images_json" ]] && images_count=$(echo "$images_json" | jq -r '.data | length' 2>/dev/null) || images_count=0
    [[ ! "$images_count" =~ ^[0-9]+$ ]] && images_count=0
    
    if [[ $images_count -eq 0 ]]; then
        if [[ -z "$image_id" ]]; then
            echo -e "${RED}No compatible images found and no IMAGE_ID in variables.sh${NC}"
            echo -e "${WHITE}Please set IMAGE_ID in variables.sh or choose a different shape.${NC}"
            echo ""
            echo -e "Press Enter to return..."
            read -r
            return 1
        fi
        echo -e "${YELLOW}No compatible images found for ${WHITE}${shape_name}${NC}"
        echo -e "${WHITE}Using IMAGE_ID from variables.sh: ${YELLOW}...${image_id: -30}${NC}"
        echo ""
        echo -n -e "${CYAN}Continue with this image? [Y/n]: ${NC}"
        local img_confirm
        read -r img_confirm
        if [[ "$img_confirm" =~ ^[Nn] ]]; then
            echo -e "${YELLOW}Cancelled.${NC}"
            echo -e "Press Enter to return..."
            read -r
            return 1
        fi
    else
        echo ""
        echo -e "${WHITE}Compatible images for ${CYAN}${shape_name}${WHITE}:${NC}"
        echo ""
        
        # Build array of images
        declare -a IMAGE_LIST=()
        local img_idx=0
        
        printf "  ${GRAY}%-4s %-70s %-20s${NC}\n" "#" "Image Name" "OS Version"
        echo -e "  ${GRAY}────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        
        while IFS='|' read -r img_ocid img_name img_os img_os_ver; do
            [[ -z "$img_ocid" ]] && continue
            ((img_idx++))
            IMAGE_LIST+=("$img_ocid")
            
            # Truncate name if too long
            local display_name="${img_name:0:68}"
            [[ ${#img_name} -gt 68 ]] && display_name="${display_name}..."
            
            printf "  ${YELLOW}%-4s${NC} ${WHITE}%-70s${NC} ${CYAN}%-20s${NC}\n" "${img_idx})" "$display_name" "$img_os_ver"
        done < <(echo "$images_json" | jq -r '.data[] | "\(.id)|\(.["display-name"] // "N/A")|\(.["operating-system"] // "N/A")|\(.["operating-system-version"] // "N/A")"' 2>/dev/null)
        
        echo ""
        if [[ -n "$image_id" ]]; then
            echo -e "  ${GREEN}0${NC}) Use IMAGE_ID from variables.sh: ${YELLOW}...${image_id: -25}${NC} ${WHITE}(default)${NC}"
            echo ""
            echo -n -e "${CYAN}Select image [0]: ${NC}"
        else
            echo -n -e "${CYAN}Select image [1]: ${NC}"
        fi
        local img_choice
        read -r img_choice
        
        # Default based on whether IMAGE_ID exists
        if [[ -z "$img_choice" ]]; then
            if [[ -n "$image_id" ]]; then
                img_choice="0"
            else
                img_choice="1"
            fi
        fi
        
        if [[ "$img_choice" == "0" ]] && [[ -n "$image_id" ]]; then
            echo -e "${GREEN}✓ Using IMAGE_ID from variables.sh${NC}"
        elif [[ "$img_choice" =~ ^[0-9]+$ ]] && [[ $img_choice -ge 1 ]] && [[ $img_choice -le ${#IMAGE_LIST[@]} ]]; then
            image_id="${IMAGE_LIST[$((img_choice-1))]}"
            echo -e "${GREEN}✓ Selected image: ${WHITE}...${image_id: -30}${NC}"
        else
            echo -e "${RED}Invalid selection${NC}"
            if [[ -n "$image_id" ]]; then
                echo -e "${YELLOW}Using IMAGE_ID from variables.sh${NC}"
            else
                echo -e "${RED}No valid image selected. Aborting.${NC}"
                echo -e "Press Enter to return..."
                read -r
                return 1
            fi
        fi
    fi
    echo ""
    
    # ========== STEP 4: Boot Volume Configuration ==========
    echo ""
    echo -e "${BOLD}${MAGENTA}─── Step 4: Boot Volume Configuration ───${NC}"
    echo ""
    
    local boot_volume_size="512"
    echo -n -e "${CYAN}Boot volume size in GB [${boot_volume_size}]: ${NC}"
    local bv_size_input
    read -r bv_size_input
    [[ -n "$bv_size_input" ]] && boot_volume_size="$bv_size_input"
    echo -e "${GREEN}✓ Boot volume size: ${WHITE}${boot_volume_size} GB${NC}"
    
    local boot_volume_vpus="20"
    echo ""
    echo -e "${WHITE}VPUs per GB (performance):${NC}"
    echo -e "  ${GRAY}10 = Balanced, 20 = Higher Performance, 30+ = Ultra High Performance${NC}"
    echo -n -e "${CYAN}Boot volume VPUs per GB [${boot_volume_vpus}]: ${NC}"
    local bv_vpus_input
    read -r bv_vpus_input
    [[ -n "$bv_vpus_input" ]] && boot_volume_vpus="$bv_vpus_input"
    echo -e "${GREEN}✓ Boot volume VPUs/GB: ${WHITE}${boot_volume_vpus}${NC}"
    
    # ========== STEP 5: Max Pods Configuration ==========
    echo ""
    echo -e "${BOLD}${MAGENTA}─── Step 5: OKE Max Pods ───${NC}"
    echo ""
    echo -n -e "${CYAN}Max pods per node [${max_pods}]: ${NC}"
    local max_pods_input
    read -r max_pods_input
    [[ -n "$max_pods_input" ]] && max_pods="$max_pods_input"
    echo -e "${GREEN}✓ Max pods: ${WHITE}${max_pods}${NC}"
    
    # ========== STEP 6: Generate Display Name ==========
    echo ""
    echo -e "${BOLD}${MAGENTA}─── Step 6: Display Name ───${NC}"
    echo ""
    
    # Get OKE cluster version for naming
    local oke_version="unknown"
    if [[ -n "${OKE_CLUSTER_ID:-}" ]]; then
        oke_version=$(oci ce cluster get --cluster-id "$OKE_CLUSTER_ID" --query 'data["kubernetes-version"]' --raw-output 2>/dev/null | sed 's/v//' | cut -d'.' -f1,2 || echo "unknown")
    fi
    [[ "$oke_version" == "null" || -z "$oke_version" ]] && oke_version="unknown"
    
    # Count existing instance configs with similar naming pattern
    local base_pattern="${shape_name}-ic-oke-${network_type}"
    local existing_count=0
    if [[ -f "$INSTANCE_CONFIG_CACHE" ]]; then
        existing_count=$(grep -c "${base_pattern}" "$INSTANCE_CONFIG_CACHE" 2>/dev/null) || existing_count=0
        # Ensure we have a valid number
        [[ ! "$existing_count" =~ ^[0-9]+$ ]] && existing_count=0
    fi
    local next_num=$((existing_count + 1))
    
    local display_name="${shape_name}-ic-oke-${oke_version}-${network_type}-${next_num}"
    
    echo -e "${WHITE}Auto-generated display name: ${CYAN}${display_name}${NC}"
    echo -n -e "${CYAN}Accept or enter custom name [${display_name}]: ${NC}"
    local name_input
    read -r name_input
    [[ -n "$name_input" ]] && display_name="$name_input"
    echo -e "${GREEN}✓ Display name: ${WHITE}${display_name}${NC}"
    
    # ========== STEP 7: Compare with Existing Configs ==========
    echo ""
    echo -e "${BOLD}${MAGENTA}─── Existing Instance Configurations ───${NC}"
    echo ""
    
    # Refresh instance configs
    fetch_instance_configurations > /dev/null 2>&1
    
    if [[ -f "$INSTANCE_CONFIG_CACHE" ]]; then
        local ic_count=0
        printf "${BOLD}%-4s %-60s %s${NC}\n" "#" "Name" "OCID"
        print_separator 120
        while IFS='|' read -r ic_ocid ic_name _; do
            [[ "$ic_ocid" =~ ^#.*$ ]] && continue
            [[ -z "$ic_ocid" ]] && continue
            ((ic_count++))
            printf "${YELLOW}%-4s${NC} ${WHITE}%-60s${NC} ${GRAY}...%s${NC}\n" \
                "$ic_count" "${ic_name:0:60}" "${ic_ocid: -20}"
        done < <(grep -v '^#' "$INSTANCE_CONFIG_CACHE" 2>/dev/null)
        
        if [[ $ic_count -eq 0 ]]; then
            echo -e "  ${GRAY}(No existing instance configurations found)${NC}"
        fi
    else
        echo -e "  ${GRAY}(No existing instance configurations found)${NC}"
    fi
    echo ""
    
    echo -n -e "${CYAN}Compare with existing config? Enter number or press Enter to continue: ${NC}"
    local compare_choice
    read -r compare_choice
    
    if [[ -n "$compare_choice" && "$compare_choice" =~ ^[0-9]+$ ]]; then
        local compare_idx=0
        local compare_ocid=""
        while IFS='|' read -r ic_ocid ic_name _; do
            [[ "$ic_ocid" =~ ^#.*$ ]] && continue
            [[ -z "$ic_ocid" ]] && continue
            ((compare_idx++))
            if [[ $compare_idx -eq $compare_choice ]]; then
                compare_ocid="$ic_ocid"
                break
            fi
        done < <(grep -v '^#' "$INSTANCE_CONFIG_CACHE" 2>/dev/null)
        
        if [[ -n "$compare_ocid" ]]; then
            echo ""
            echo -e "${BOLD}${CYAN}─── Comparing with: ${ic_name} ───${NC}"
            # Get user-data from existing config
            local existing_ud
            existing_ud=$(oci compute-management instance-configuration get \
                --instance-configuration-id "$compare_ocid" \
                --query 'data["instance-details"]["launch-details"]["metadata"]["user_data"]' \
                --raw-output 2>/dev/null)
            
            if [[ -n "$existing_ud" && "$existing_ud" != "null" ]]; then
                echo ""
                echo -e "${WHITE}Existing cloud-init (first 20 lines):${NC}"
                echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo "$existing_ud" | base64 -d 2>/dev/null | head -20
                echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            fi
            echo ""
            echo -e "Press Enter to continue..."
            read -r
        fi
    fi
    
    # ========== STEP 8: Build and Show Command ==========
    echo ""
    echo -e "${BOLD}${MAGENTA}─── Configuration Summary ───${NC}"
    echo ""
    echo -e "  ${WHITE}Display Name:${NC}       ${CYAN}${display_name}${NC}"
    echo -e "  ${WHITE}Shape:${NC}              ${WHITE}${shape_name}${NC}"
    echo -e "  ${WHITE}Network Type:${NC}       ${WHITE}${network_type}${NC}"
    echo -e "  ${WHITE}Boot Volume:${NC}        ${WHITE}${boot_volume_size} GB @ ${boot_volume_vpus} VPUs/GB${NC}"
    echo -e "  ${WHITE}Max Pods:${NC}           ${WHITE}${max_pods}${NC}"
    echo -e "  ${WHITE}Cloud-Init:${NC}         ${WHITE}${cloud_init_file}${NC}"
    echo -e "  ${WHITE}Region:${NC}             ${WHITE}${region}${NC}"
    echo -e "  ${WHITE}Compartment:${NC}        ${YELLOW}...${compartment_id: -25}${NC}"
    echo -e "  ${WHITE}AD:${NC}                 ${WHITE}${ad}${NC}"
    echo -e "  ${WHITE}Worker Subnet:${NC}      ${YELLOW}...${worker_subnet: -25}${NC}"
    echo -e "  ${WHITE}Worker NSG:${NC}         ${YELLOW}...${worker_nsg: -25}${NC}"
    echo -e "  ${WHITE}Image ID:${NC}           ${YELLOW}...${image_id: -25}${NC}"
    echo ""
    
    # Encode cloud-init
    local base64_cloud_init
    base64_cloud_init=$(base64 -w 0 "$cloud_init_file")
    
    # Build the JSON payload
    local instance_details_json
    instance_details_json=$(cat <<EOF
{
  "instanceType": "compute",
  "launchDetails": {
    "availabilityDomain": "${ad}",
    "compartmentId": "${compartment_id}",
    "createVnicDetails": {
      "assignIpv6Ip": false,
      "assignPublicIp": false,
      "assignPrivateDnsRecord": true,
      "subnetId": "${worker_subnet}",
      "nsgIds": [
        "${worker_nsg}"
      ]
    },
    "metadata": {
      "user_data": "${base64_cloud_init}",
      "oke-max-pods": "${max_pods}"
    },
    "shape": "${shape_name}",
    "sourceDetails": {
      "bootVolumeSizeInGBs": "${boot_volume_size}",
      "bootVolumeVpusPerGB": "${boot_volume_vpus}",
      "sourceType": "image",
      "imageId": "${image_id}"
    },
    "agentConfig": {
      "isMonitoringDisabled": false,
      "isManagementDisabled": false,
      "pluginsConfig": [
        { "name": "WebLogic Management Service", "desiredState": "DISABLED" },
        { "name": "Vulnerability Scanning", "desiredState": "DISABLED" },
        { "name": "Oracle Java Management Service", "desiredState": "DISABLED" },
        { "name": "Oracle Autonomous Linux", "desiredState": "DISABLED" },
        { "name": "OS Management Service Agent", "desiredState": "DISABLED" },
        { "name": "OS Management Hub Agent", "desiredState": "DISABLED" },
        { "name": "Management Agent", "desiredState": "DISABLED" },
        { "name": "Custom Logs Monitoring", "desiredState": "ENABLED" },
        { "name": "Compute RDMA GPU Monitoring", "desiredState": "ENABLED" },
        { "name": "Compute Instance Run Command", "desiredState": "ENABLED" },
        { "name": "Compute Instance Monitoring", "desiredState": "ENABLED" },
        { "name": "Compute HPC RDMA Auto-Configuration", "desiredState": "ENABLED" },
        { "name": "Compute HPC RDMA Authentication", "desiredState": "ENABLED" },
        { "name": "Cloud Guard Workload Protection", "desiredState": "DISABLED" },
        { "name": "Block Volume Management", "desiredState": "DISABLED" },
        { "name": "Bastion", "desiredState": "DISABLED" }
      ]
    },
    "isPvEncryptionInTransitEnabled": false,
    "instanceOptions": {
      "areLegacyImdsEndpointsDisabled": false
    },
    "availabilityConfig": {
      "recoveryAction": "RESTORE_INSTANCE"
    }
  }
}
EOF
)
    
    echo -e "${BOLD}${YELLOW}─── Configuration Summary ───${NC}"
    echo ""
    echo -e "  ${CYAN}Shape:${NC}       ${WHITE}${shape_name}${NC}"
    echo -e "  ${CYAN}Image:${NC}       ${WHITE}...${image_id: -40}${NC}"
    echo -e "  ${CYAN}Boot Vol:${NC}    ${WHITE}${boot_volume_size} GB @ ${boot_volume_vpus} VPUs/GB${NC}"
    echo -e "  ${CYAN}Max Pods:${NC}    ${WHITE}${max_pods}${NC}"
    echo -e "  ${CYAN}Network:${NC}     ${WHITE}${network_type}${NC}"
    echo ""
    
    echo -e "${BOLD}${YELLOW}─── Command to Execute ───${NC}"
    echo ""
    printf "%s\n" "oci --region \"${region}\" \\"
    printf "%s\n" "  compute-management instance-configuration create \\"
    printf "%s\n" "  --compartment-id \"${compartment_id}\" \\"
    printf "%s\n" "  --display-name \"${display_name}\" \\"
    printf "%s\n" "  --instance-details '<JSON payload with ${#base64_cloud_init} char user_data>'"
    echo ""
    
    # Log file for the action
    local log_file="instance_config_create_$(date +%Y%m%d_%H%M%S).log"
    
    echo -e "${BOLD}${RED}═══ CONFIRM CREATION ═══${NC}"
    echo ""
    echo -e "${YELLOW}This will create a new Instance Configuration.${NC}"
    echo -e "${WHITE}Log file: ${CYAN}${log_file}${NC}"
    echo ""
    echo -n -e "${CYAN}Type 'CREATE' to confirm: ${NC}"
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "CREATE" ]]; then
        echo -e "${YELLOW}Cancelled.${NC}"
        echo -e "Press Enter to return..."
        read -r
        return 0
    fi
    
    # Execute the command
    echo ""
    echo -e "${YELLOW}Creating Instance Configuration...${NC}"
    
    # Log the command (without the full base64)
    {
        echo "=========================================="
        echo "Instance Configuration Creation"
        echo "Timestamp: $(date)"
        echo "=========================================="
        echo ""
        echo "Display Name: ${display_name}"
        echo "Shape: ${shape_name}"
        echo "Image ID: ${image_id}"
        echo "Network Type: ${network_type}"
        echo "Boot Volume: ${boot_volume_size} GB @ ${boot_volume_vpus} VPUs/GB"
        echo "Max Pods: ${max_pods}"
        echo "Cloud-Init File: ${cloud_init_file}"
        echo ""
        echo "Command:"
        echo "oci --region \"${region}\" \\"
        echo "  compute-management instance-configuration create \\"
        echo "  --compartment-id \"${compartment_id}\" \\"
        echo "  --display-name \"${display_name}\" \\"
        echo "  --instance-details '<JSON payload>'"
        echo ""
        echo "=========================================="
        echo "Execution Output:"
        echo "=========================================="
    } > "$log_file"
    
    local result
    result=$(oci --region "${region}" \
        compute-management instance-configuration create \
        --compartment-id "${compartment_id}" \
        --display-name "${display_name}" \
        --instance-details "${instance_details_json}" 2>&1)
    local exit_code=$?
    
    # Log the result
    echo "$result" >> "$log_file"
    
    if [[ $exit_code -eq 0 ]]; then
        local new_ocid
        new_ocid=$(echo "$result" | jq -r '.data.id // empty' 2>/dev/null)
        
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                    INSTANCE CONFIGURATION CREATED                          ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${WHITE}Name:${NC} ${CYAN}${display_name}${NC}"
        echo -e "${WHITE}OCID:${NC} ${YELLOW}${new_ocid}${NC}"
        echo -e "${WHITE}Log:${NC}  ${WHITE}${log_file}${NC}"
        echo ""
        
        # Invalidate cache
        rm -f "$INSTANCE_CONFIG_CACHE"
        
        echo -e "${GREEN}✓ Instance Configuration created successfully!${NC}"
    else
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                    FAILED TO CREATE INSTANCE CONFIGURATION                 ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${RED}Error:${NC}"
        echo "$result"
        echo ""
        echo -e "${WHITE}Log file: ${CYAN}${log_file}${NC}"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
    
    # Refresh the menu to show new instance config
    display_gpu_management_menu > /dev/null 2>&1
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
    echo "  --debug                   Enable debug mode for OCI CLI commands (verbose output)"
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
    echo -e "${BOLD}Instance Configuration:${NC}"
    echo "  --get-user-data <instance-config-ocid>"
    echo "    Extract and display the decoded cloud-init user-data from an instance configuration"
    echo "    Useful for reviewing or backing up cloud-init configurations"
    echo ""
    echo -e "${BOLD}Resource Management:${NC}"
    echo "  --manage            Interactive resource management mode"
    echo "                      - OKE Cluster environment view"
    echo "                      - Network resources (subnets, NSGs)"
    echo "                      - GPU Memory Fabrics & Clusters (create, update, view)"
    echo "                      - Compute Instances (view details, IPs, volumes)"
    echo "                      - Instance Configurations (create, view, compare, delete)"
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
    echo "  $0 --manage                                           # Interactive resource management"
    echo "  $0 --manage --debug                                   # Resource management with debug output"
    echo "  $0 --setup                                            # Run initial setup wizard"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx                 # Basic node info"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --labels        # Show labels"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --clique        # Show clique info + fabric"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --count-clique  # Show clique members + fabric"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --all           # Show everything"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --details       # Full details (network, volumes)"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --console-history  # View console history"
    echo "  $0 --list-cluster ocid1.xxx                           # List cluster instances + fabric"
    echo "  $0 --get-user-data ocid1.instanceconfig.oc1.xxx       # Extract cloud-init from config"
    echo "  $0 --get-user-data ocid1.instanceconfig.oc1.xxx > cloud-init.yml  # Save to file"
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
            --debug)
                DEBUG_MODE=true
                i=$((i + 1))
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
        --get-user-data)
            if [[ -z "${2:-}" ]]; then
                log_error "Instance configuration OCID required"
                echo "Usage: $0 --get-user-data <instance-config-ocid>"
                exit 1
            fi
            get_instance_config_user_data "$2"
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
                # Loop to handle refresh requests
                while true; do
                    display_instance_details "$instance_id"
                    local ret=$?
                    [[ $ret -ne 2 ]] && break  # Exit loop unless refresh requested
                done
            else
                get_node_info "$instance_id" "$show_labels" "$show_clique" "$count_clique"
            fi
            ;;
    esac
}

# Run main function
main "$@"