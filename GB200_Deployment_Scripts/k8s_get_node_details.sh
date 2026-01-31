#!/bin/bash
#
# k8s_get_nodes_details.sh - GPU Node Information Tool for OKE
#
# Description:
#   Lists GPU instances in OCI/Kubernetes with detailed information including
#   GPU memory clusters, fabrics, capacity topology, and announcements.
#
# Dependencies on the node it is run from:
#   - oci CLI (configured)
#   - kubectl (configured with cluster access)
#   - jq (JSON processor)
#   - base64, gunzip, xxd (for user-data decoding)
#   - helm
#
# Usage:
#   ./k8s_get_nodes_details.sh [OPTIONS] [resource-ocid] [OPTIONS]
#   Run with --help for full usage information.
#
# Configuration:
#   If you have a variables.sh file already precreated will use the value in it, else will prompt to create one.
#   It'll query for the resources to populate the file accordingly.
#   It assumes that you are running the components for the AI stack in the same compartment, compute, network, storage.
#   Optional: OKE_CLUSTER_ID to specify which OKE cluster to manage
#
# Author: Tim Cowen
# Version: 2.2
# Please use at your own risk.
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
readonly CACHE_DIR="${SCRIPT_DIR}/cache"
readonly TEMP_DIR="${CACHE_DIR}/tmp"

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
readonly INSTANCE_CLUSTER_MAP_CACHE="${CACHE_DIR}/instance_cluster_map.txt"

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

# Logs directory setup
LOGS_DIR="${LOGS_DIR:-./logs}"
mkdir -p "$LOGS_DIR" 2>/dev/null

# Action log file for tracking changes (create, update, delete operations)
ACTION_LOG_FILE="${ACTION_LOG_FILE:-${LOGS_DIR}/k8s_nodes_actions_$(date +%Y%m%d).log}"

# Maintenance log file for maintenance operations
MAINTENANCE_LOG_FILE="${MAINTENANCE_LOG_FILE:-${LOGS_DIR}/k8s_maintenance_$(date +%Y%m%d).log}"

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
    # Ensure temp directory exists
    [[ ! -d "$TEMP_DIR" ]] && mkdir -p "$TEMP_DIR"
    tmp=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX") || { log_error "Failed to create temp file"; return 1; }
    echo "$tmp"
}

# Show progress bar for parallel operations
# Args: $1 = output_dir, $2 = file_pattern, $3 = total_count, $4 = description
# Runs in background, call with & and capture PID, then kill when done
show_parallel_progress() {
    local output_dir="$1"
    local file_pattern="$2"
    local total="$3"
    local desc="${4:-Processing}"
    
    local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_idx=0
    
    while true; do
        local completed
        completed=$(find "$output_dir" -name "$file_pattern" 2>/dev/null | wc -l)
        local pct=0
        [[ "$total" -gt 0 ]] && pct=$((completed * 100 / total))
        
        # Build progress bar (20 chars wide)
        local filled=$((pct / 5))
        local empty=$((20 - filled))
        local bar=""
        for ((i=0; i<filled; i++)); do bar+="█"; done
        for ((i=0; i<empty; i++)); do bar+="░"; done
        
        # Get spinner character
        local spin_char="${spinner:$spin_idx:1}"
        spin_idx=$(( (spin_idx + 1) % ${#spinner} ))
        
        # Print progress (carriage return to overwrite)
        printf "\r  ${CYAN}%s${NC} [${GREEN}%s${NC}] %3d%% (%d/%d) %s " "$spin_char" "$bar" "$pct" "$completed" "$total" "$desc"
        
        # Exit if complete
        [[ "$completed" -ge "$total" ]] && break
        
        sleep 0.2
    done
    printf "\r  ${GREEN}✓${NC} [████████████████████] 100%% (%d/%d) %s \n" "$total" "$total" "$desc"
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
        "$INSTANCE_CLUSTER_MAP_CACHE"
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
    
    # Check if cache exists and is fresh
    if is_cache_fresh "$CLUSTER_CACHE" && is_cache_fresh "$INSTANCE_CLUSTER_MAP_CACHE"; then
        # Even if cache is fresh, invalidate if any cluster is in a transitional state
        # This ensures we pick up new instances when clusters are scaling
        if [[ -f "$CLUSTER_CACHE" ]]; then
            local transitional_states
            transitional_states=$(grep -E "\|UPDATING\||\|SCALING\||\|CREATING\|" "$CLUSTER_CACHE" 2>/dev/null | wc -l)
            if [[ "$transitional_states" -gt 0 ]]; then
                log_info "Detected $transitional_states cluster(s) in transitional state - refreshing cache..."
            else
                return 0
            fi
        else
            return 0
        fi
    fi
    
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
    
    # Write cache headers
    {
        echo "# GPU Memory Clusters"
        echo "# Format: ClusterOCID|DisplayName|State|FabricSuffix|InstanceConfigurationId|ComputeClusterId|Size"
    } > "$CLUSTER_CACHE"
    
    {
        echo "# Instance to GPU Memory Cluster Mapping"
        echo "# Format: InstanceOCID|ClusterOCID|ClusterDisplayName"
    } > "$INSTANCE_CLUSTER_MAP_CACHE"
    
    # Get cluster IDs
    local cluster_ids
    cluster_ids=$(jq -r '.data.items[]?.id // empty' "$raw_json" 2>/dev/null)
    
    local cluster_count
    cluster_count=$(echo "$cluster_ids" | grep -c . 2>/dev/null | tr -d '[:space:]')
    [[ -z "$cluster_count" ]] && cluster_count=0
    
    if [[ "$cluster_count" -eq 0 ]]; then
        rm -f "$raw_json"
        return 0
    fi
    
    # Create temp directory for parallel outputs
    local parallel_temp="${TEMP_DIR}/gpu_cluster_parallel_$$"
    mkdir -p "$parallel_temp"
    
    # Export function and variables for xargs subshells
    export -f create_temp_file 2>/dev/null || true
    
    # Define worker function for parallel processing
    _fetch_single_cluster() {
        local cluster_id="$1"
        local output_dir="$2"
        [[ -z "$cluster_id" ]] && return
        
        local cluster_file="${output_dir}/cluster_${cluster_id##*.}.txt"
        local instance_file="${output_dir}/instances_${cluster_id##*.}.txt"
        
        # Fetch cluster details
        local cluster_json
        cluster_json=$(oci compute compute-gpu-memory-cluster get \
            --compute-gpu-memory-cluster-id "$cluster_id" \
            --output json 2>/dev/null)
        
        if [[ -n "$cluster_json" ]] && echo "$cluster_json" | jq -e '.data' > /dev/null 2>&1; then
            local cluster_display_name
            cluster_display_name=$(echo "$cluster_json" | jq -r '.data["display-name"] // "N/A"')
            
            # Write cluster cache line
            echo "$cluster_json" | jq -r '
                .data["display-name"] as $name |
                (.data["gpu-memory-fabric-id"] // "") as $fabric_id |
                (if $fabric_id != "" and $fabric_id != null then 
                    ($fabric_id[-5:] | ascii_downcase)
                 else 
                    (($name | capture("fabric-(?<suffix>[a-z0-9]{5})") // {suffix: ""}).suffix)
                 end) as $fabric_suffix |
                "\(.data.id)|\($name)|\(.data["lifecycle-state"])|\($fabric_suffix)|\(.data["instance-configuration-id"] // "N/A")|\(.data["compute-cluster-id"] // "N/A")|\(.data["size"] // 0)"
            ' > "$cluster_file" 2>/dev/null
            
            # Fetch instances for this cluster
            local instances_json
            instances_json=$(oci compute compute-gpu-memory-cluster-instance-summary list-compute-gpu-memory-cluster-instances \
                --compute-gpu-memory-cluster-id "$cluster_id" \
                --all \
                --output json 2>/dev/null)
            
            if [[ -n "$instances_json" ]]; then
                echo "$instances_json" | jq -r --arg cluster_id "$cluster_id" --arg cluster_name "$cluster_display_name" '
                    (.data.items // .data // [])[] | 
                    "\(.["instance-id"] // .id)|\($cluster_id)|\($cluster_name)"
                ' > "$instance_file" 2>/dev/null
            fi
        fi
    }
    export -f _fetch_single_cluster
    
    # Determine parallelism (max 8 to avoid API throttling)
    local parallel_jobs=8
    [[ "$cluster_count" -lt "$parallel_jobs" ]] && parallel_jobs="$cluster_count"
    
    log_info "Fetching $cluster_count clusters in parallel (jobs=$parallel_jobs)..."
    
    # Start progress bar in background
    show_parallel_progress "$parallel_temp" "cluster_*.txt" "$cluster_count" "GPU clusters" &
    local progress_pid=$!
    
    # Run parallel fetch
    echo "$cluster_ids" | xargs -P "$parallel_jobs" -I {} bash -c '_fetch_single_cluster "$@"' _ {} "$parallel_temp"
    
    # Stop progress bar
    kill "$progress_pid" 2>/dev/null
    wait "$progress_pid" 2>/dev/null
    printf "\r  ${GREEN}✓${NC} [████████████████████] 100%% (%d/%d) GPU clusters \n" "$cluster_count" "$cluster_count"
    
    # Aggregate results from parallel outputs
    cat "$parallel_temp"/cluster_*.txt >> "$CLUSTER_CACHE" 2>/dev/null
    cat "$parallel_temp"/instances_*.txt >> "$INSTANCE_CLUSTER_MAP_CACHE" 2>/dev/null
    
    # Cleanup
    rm -rf "$parallel_temp"
    rm -f "$raw_json"
    
    return 0
}

# Lookup GPU memory cluster OCID for an instance
get_instance_gpu_cluster() {
    local instance_ocid="$1"
    [[ -z "$instance_ocid" || ! -f "$INSTANCE_CLUSTER_MAP_CACHE" ]] && { echo "N/A"; return 1; }
    
    local result
    result=$(grep "^${instance_ocid}|" "$INSTANCE_CLUSTER_MAP_CACHE" 2>/dev/null | head -1 | cut -d'|' -f2)
    
    if [[ -n "$result" ]]; then
        echo "$result"
    else
        echo "N/A"
    fi
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
    tmp_decoded=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
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
    tmp_decoded=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
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
    tmp_decoded=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    echo "$user_data_b64" | base64 -d > "$tmp_decoded" 2>/dev/null
    
    local magic_bytes
    magic_bytes=$(xxd -l 2 -p "$tmp_decoded" 2>/dev/null)
    
    rm -f "$tmp_decoded"
    
    [[ "$magic_bytes" == "1f8b" ]]
}

#--------------------------------------------------------------------------------
# Interactive instance termination with details and confirmation
# Args: $1 = instance OCID
# Shows: instance details, running pods, termination command, confirmation
#--------------------------------------------------------------------------------
terminate_instance_interactive() {
    local instance_ocid="$1"
    
    if [[ -z "$instance_ocid" ]]; then
        log_error "Instance OCID required"
        return 1
    fi
    
    echo ""
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${RED}                              INSTANCE TERMINATION                                      ${NC}"
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Fetch instance details
    log_info "Fetching instance details..."
    local instance_json
    instance_json=$(oci compute instance get --instance-id "$instance_ocid" --output json 2>/dev/null)
    
    if [[ -z "$instance_json" || "$instance_json" == "null" ]]; then
        log_error "Failed to fetch instance details. Instance may not exist or you don't have access."
        return 1
    fi
    
    # Parse instance details
    local display_name lifecycle_state shape ad fault_domain
    local compartment_id time_created
    display_name=$(echo "$instance_json" | jq -r '.data["display-name"] // "N/A"')
    lifecycle_state=$(echo "$instance_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    shape=$(echo "$instance_json" | jq -r '.data.shape // "N/A"')
    ad=$(echo "$instance_json" | jq -r '.data["availability-domain"] // "N/A"')
    fault_domain=$(echo "$instance_json" | jq -r '.data["fault-domain"] // "N/A"')
    compartment_id=$(echo "$instance_json" | jq -r '.data["compartment-id"] // "N/A"')
    time_created=$(echo "$instance_json" | jq -r '.data["time-created"] // "N/A"')
    
    # Color for state
    local state_color="$GREEN"
    case "$lifecycle_state" in
        RUNNING) state_color="$GREEN" ;;
        STOPPED) state_color="$RED" ;;
        TERMINATED) state_color="$RED" ;;
        *) state_color="$YELLOW" ;;
    esac
    
    # Display instance details
    echo -e "${BOLD}${WHITE}Instance Details:${NC}"
    echo -e "  ${CYAN}Display Name:${NC}    $display_name"
    echo -e "  ${CYAN}OCID:${NC}            ${YELLOW}$instance_ocid${NC}"
    echo -e "  ${CYAN}State:${NC}           ${state_color}$lifecycle_state${NC}"
    echo -e "  ${CYAN}Shape:${NC}           $shape"
    echo -e "  ${CYAN}AD:${NC}              $ad"
    echo -e "  ${CYAN}Fault Domain:${NC}    $fault_domain"
    echo -e "  ${CYAN}Compartment:${NC}     $compartment_id"
    echo -e "  ${CYAN}Created:${NC}         ${time_created:0:19}"
    echo ""
    
    # Check if already terminated
    if [[ "$lifecycle_state" == "TERMINATED" ]]; then
        echo -e "${YELLOW}Instance is already terminated.${NC}"
        return 0
    fi
    
    # Check if instance is in K8s and show pods
    local k8s_node_name=""
    log_info "Checking K8s node status..."
    
    # Find K8s node by provider ID
    local k8s_nodes_json
    k8s_nodes_json=$(kubectl get nodes -o json 2>/dev/null)
    
    if [[ -n "$k8s_nodes_json" ]]; then
        k8s_node_name=$(echo "$k8s_nodes_json" | jq -r --arg ocid "$instance_ocid" '
            .items[] | select(.spec.providerID | contains($ocid)) | .metadata.name
        ' 2>/dev/null)
    fi
    
    if [[ -n "$k8s_node_name" && "$k8s_node_name" != "null" ]]; then
        echo -e "${BOLD}${WHITE}Kubernetes Node:${NC}"
        echo -e "  ${CYAN}Node Name:${NC}       $k8s_node_name"
        
        # Get node status
        local node_ready node_schedulable
        node_ready=$(kubectl get node "$k8s_node_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        node_schedulable=$(kubectl get node "$k8s_node_name" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)
        
        local ready_color="$GREEN"
        [[ "$node_ready" != "True" ]] && ready_color="$RED"
        echo -e "  ${CYAN}Ready:${NC}           ${ready_color}$node_ready${NC}"
        
        if [[ "$node_schedulable" == "true" ]]; then
            echo -e "  ${CYAN}Cordoned:${NC}        ${YELLOW}Yes${NC}"
        else
            echo -e "  ${CYAN}Cordoned:${NC}        No"
        fi
        echo ""
        
        # Get pods on this node
        echo -e "${BOLD}${WHITE}Pods Running on Node:${NC}"
        echo ""
        
        local node_pods
        node_pods=$(kubectl get pods --all-namespaces --field-selector "spec.nodeName=$k8s_node_name" -o wide 2>/dev/null)
        
        if [[ -n "$node_pods" ]]; then
            local pod_count
            pod_count=$(echo "$node_pods" | tail -n +2 | wc -l)
            echo -e "  ${CYAN}Total Pods:${NC} ${WHITE}$pod_count${NC}"
            echo ""
            
            # Print header
            echo "$node_pods" | head -1 | while IFS= read -r line; do
                echo -e "  ${BOLD}${WHITE}$line${NC}"
            done
            
            # Print pods with color coding
            echo "$node_pods" | tail -n +2 | while IFS= read -r line; do
                if echo "$line" | grep -q "Running"; then
                    echo -e "  ${GREEN}$line${NC}"
                elif echo "$line" | grep -q "Completed"; then
                    echo -e "  ${GRAY}$line${NC}"
                elif echo "$line" | grep -qE "Error|Failed|CrashLoopBackOff|ImagePullBackOff"; then
                    echo -e "  ${RED}$line${NC}"
                elif echo "$line" | grep -qE "Pending|ContainerCreating|Init"; then
                    echo -e "  ${YELLOW}$line${NC}"
                else
                    echo "  $line"
                fi
            done
            
            if [[ $pod_count -gt 0 ]]; then
                echo ""
                echo -e "  ${RED}⚠️  WARNING: $pod_count pod(s) are running on this node!${NC}"
                echo -e "  ${YELLOW}Consider draining the node first: kubectl drain $k8s_node_name --ignore-daemonsets --delete-emptydir-data --force${NC}"
            fi
        else
            echo -e "  ${GRAY}No pods found on this node${NC}"
        fi
        echo ""
    else
        echo -e "${GRAY}Instance is not registered as a Kubernetes node${NC}"
        echo ""
    fi
    
    # Show the command that will be executed
    local terminate_cmd="oci compute instance terminate --instance-id $instance_ocid --preserve-boot-volume false --force"
    
    echo -e "${BOLD}${WHITE}Command to Execute:${NC}"
    echo -e "  ${WHITE}$terminate_cmd${NC}"
    echo ""
    
    print_separator 90
    echo ""
    echo -e "${RED}⚠️  WARNING: This will PERMANENTLY TERMINATE the instance!${NC}"
    echo -e "${RED}    This action cannot be undone!${NC}"
    echo ""
    echo -e "${RED}    Instance: ${WHITE}$display_name${NC}"
    echo -e "${RED}    OCID:     ${WHITE}$instance_ocid${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'TERMINATE' to confirm: ${NC}"
    read -r confirm
    
    if [[ "$confirm" == "TERMINATE" ]]; then
        echo ""
        echo -e "${YELLOW}Executing: $terminate_cmd${NC}"
        
        # Log the action
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        {
            echo "========================================"
            echo "Timestamp: $timestamp"
            echo "Action: TERMINATE"
            echo "Instance: $display_name"
            echo "OCID: $instance_ocid"
            echo "K8s Node: ${k8s_node_name:-N/A}"
            echo "Command: $terminate_cmd"
            echo "========================================"
            echo ""
        } >> "$MAINTENANCE_LOG_FILE"
        
        if oci compute instance terminate --instance-id "$instance_ocid" --preserve-boot-volume false --force 2>&1; then
            echo ""
            echo -e "${GREEN}✓ Instance termination initiated${NC}"
            echo -e "${GRAY}  Instance will transition to TERMINATING state${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Terminated instance $display_name ($instance_ocid)" >> "$MAINTENANCE_LOG_FILE"
        else
            echo ""
            echo -e "${RED}✗ Failed to terminate instance${NC}"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: Terminate instance $display_name ($instance_ocid)" >> "$MAINTENANCE_LOG_FILE"
        fi
        
        echo ""
        echo -e "${GRAY}Log: $MAINTENANCE_LOG_FILE${NC}"
    else
        echo -e "${YELLOW}Cancelled (must type 'TERMINATE' exactly)${NC}"
    fi
    
    echo ""
}

#--------------------------------------------------------------------------------
# Get user-data from an instance OCID
# Args: $1 = instance OCID
# Output: decoded user-data to stdout
#--------------------------------------------------------------------------------
get_instance_user_data() {
    local instance_ocid="$1"
    
    if [[ -z "$instance_ocid" ]]; then
        log_error "Instance OCID required"
        return 1
    fi
    
    # Validate OCID format
    if [[ ! "$instance_ocid" =~ ^ocid1\.instance\. ]]; then
        log_error "Invalid instance OCID format: $instance_ocid"
        echo "Expected format: ocid1.instance.oc1.<region>.<unique-id>" >&2
        return 1
    fi
    
    log_info "Fetching instance metadata..." >&2
    
    local instance_json
    instance_json=$(oci compute instance get \
        --instance-id "$instance_ocid" \
        --output json 2>/dev/null)
    
    if [[ -z "$instance_json" ]] || ! echo "$instance_json" | jq -e '.data' > /dev/null 2>&1; then
        log_error "Failed to fetch instance: $instance_ocid"
        return 1
    fi
    
    local instance_name
    instance_name=$(echo "$instance_json" | jq -r '.data["display-name"] // "N/A"')
    
    # Extract user_data (base64 encoded)
    local user_data_b64
    user_data_b64=$(echo "$instance_json" | jq -r '.data.metadata.user_data // empty' 2>/dev/null)
    
    if [[ -z "$user_data_b64" ]]; then
        echo "# No user-data found in instance metadata: $instance_name" >&2
        echo "# OCID: $instance_ocid" >&2
        echo "" >&2
        echo "# Note: user_data is typically only available if the instance was launched with" >&2
        echo "# cloud-init user-data specified in the metadata." >&2
        return 0
    fi
    
    # Output header as comments (to stderr so stdout is just the yaml)
    echo "# Instance: $instance_name" >&2
    echo "# OCID: $instance_ocid" >&2
    echo "# Decoded cloud-init user-data:" >&2
    echo "#" >&2
    
    # Decode and output to stdout (handles gzip compressed data)
    decode_user_data "$user_data_b64"
    
    return 0
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
    
    # Get topology IDs
    local topology_ids
    topology_ids=$(jq -r '.data.items[]?.id // empty' "$topologies_json" 2>/dev/null)
    
    local topo_count
    topo_count=$(echo "$topology_ids" | grep -c . 2>/dev/null | tr -d '[:space:]')
    [[ -z "$topo_count" ]] && topo_count=0
    
    if [[ "$topo_count" -eq 0 ]]; then
        rm -f "$topologies_json"
        return 0
    fi
    
    # Create temp directory for parallel outputs
    local parallel_temp="${TEMP_DIR}/capacity_topo_parallel_$$"
    mkdir -p "$parallel_temp"
    
    # Define worker function for parallel processing
    _fetch_single_topology() {
        local topo_id="$1"
        local output_dir="$2"
        [[ -z "$topo_id" ]] && return
        
        local output_file="${output_dir}/topo_${topo_id##*.}.txt"
        
        local hosts_json
        hosts_json=$(oci compute capacity-topology bare-metal-host list \
            --capacity-topology-id "$topo_id" \
            --all \
            --output json 2>/dev/null)
        
        if [[ -n "$hosts_json" ]]; then
            echo "$hosts_json" | jq -r --arg topo "$topo_id" '
                .data.items[]? | 
                "\(.["instance-id"] // "N/A")|\(.["lifecycle-state"] // "N/A")|\(.["lifecycle-details"] // "N/A")|\($topo)"
            ' > "$output_file" 2>/dev/null
        fi
    }
    export -f _fetch_single_topology
    
    # Determine parallelism (max 8 to avoid API throttling)
    local parallel_jobs=8
    [[ "$topo_count" -lt "$parallel_jobs" ]] && parallel_jobs="$topo_count"
    
    log_info "Fetching $topo_count topologies in parallel (jobs=$parallel_jobs)..."
    
    # Start progress bar in background
    show_parallel_progress "$parallel_temp" "topo_*.txt" "$topo_count" "capacity topologies" &
    local progress_pid=$!
    
    # Run parallel fetch
    echo "$topology_ids" | xargs -P "$parallel_jobs" -I {} bash -c '_fetch_single_topology "$@"' _ {} "$parallel_temp"
    
    # Stop progress bar
    kill "$progress_pid" 2>/dev/null
    wait "$progress_pid" 2>/dev/null
    printf "\r  ${GREEN}✓${NC} [████████████████████] 100%% (%d/%d) capacity topologies \n" "$topo_count" "$topo_count"
    
    # Aggregate results from parallel outputs
    cat "$parallel_temp"/topo_*.txt >> "$CAPACITY_TOPOLOGY_CACHE" 2>/dev/null
    
    # Cleanup
    rm -rf "$parallel_temp"
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
    
    # Section separator - Helm Deployments
    echo -e "${BOLD}${BLUE}╠${h_line}╣${NC}"
    
    # Helm Deployments section - check for GPU-related helm releases
    local helm_available=false
    if command -v helm &>/dev/null && command -v kubectl &>/dev/null; then
        helm_available=true
    fi
    
    if [[ "$helm_available" == "true" ]]; then
        # Check gpu-operator namespace
        local gpu_operator_info gpu_op_json
        gpu_op_json=$(helm list -n gpu-operator -o json 2>/dev/null)
        if [[ -n "$gpu_op_json" && "$gpu_op_json" != "[]" ]]; then
            gpu_operator_info=$(echo "$gpu_op_json" | jq -r '.[0] | select(.name == "gpu-operator") | "\(.chart) [\(.status)] rev:\(.revision) updated:\(.updated | split(".")[0])"' 2>/dev/null)
        fi
        if [[ -n "$gpu_operator_info" && "$gpu_operator_info" != "null" ]]; then
            _print_row "GPU Operator:" "$gpu_operator_info"
        else
            _print_row "GPU Operator:" "Not installed"
        fi
        
        # Check nvidia-dra-driver-gpu namespace
        local dra_driver_info dra_json
        dra_json=$(helm list -n nvidia-dra-driver-gpu -o json 2>/dev/null)
        if [[ -n "$dra_json" && "$dra_json" != "[]" ]]; then
            dra_driver_info=$(echo "$dra_json" | jq -r '.[0] | select(.name == "nvidia-dra-driver-gpu") | "\(.chart) [\(.status)] rev:\(.revision) updated:\(.updated | split(".")[0])"' 2>/dev/null)
        fi
        if [[ -n "$dra_driver_info" && "$dra_driver_info" != "null" ]]; then
            _print_row "DRA Driver:" "$dra_driver_info"
        else
            _print_row "DRA Driver:" "Not installed"
        fi
    else
        _print_row "Helm Deploys:" "(helm/kubectl not available)"
    fi
    
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
    temp_output=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    temp_error=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    
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
    local instance_filter="${INSTANCE_FILTER:-all}"
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
    
    # oci_temp format: display_name|status|instance_ocid|gpu_mem_tag|shape|time_created
    local display_name status instance_ocid gpu_mem_tag shape time_created
    while IFS='|' read -r display_name status instance_ocid gpu_mem_tag shape time_created; do
        [[ -z "$instance_ocid" ]] && continue
        
        # Skip bastion and operator instances - they're not supposed to be in K8s
        local display_name_lower="${display_name,,}"  # Convert to lowercase
        if [[ "$display_name_lower" == *bastion* || "$display_name_lower" == *operator* ]]; then
            continue
        fi
        
        # Look up GPU memory cluster from API-based cache (preferred) or fall back to tag
        local gpu_mem
        gpu_mem=$(get_instance_gpu_cluster "$instance_ocid")
        [[ "$gpu_mem" == "N/A" && "$gpu_mem_tag" != "N/A" ]] && gpu_mem="$gpu_mem_tag"
        
        # Use grep without ^ anchor because providerID has oci:// prefix
        if ! grep -q "$instance_ocid" "$k8s_temp" 2>/dev/null; then
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
    local instance_filter="${INSTANCE_FILTER:-all}"
    
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
            header_text="All Instances in Compartment"
            instance_filter="all"
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
    
    # Fetch K8s nodes - fetch ALL nodes to avoid missing nodes without GPU labels
    # The label nvidia.com/gpu.present may not be set immediately on new nodes
    log_info "Fetching nodes from Kubernetes..."
    kubectl get nodes -o json 2>/dev/null | jq -r '
        .items[] | 
        "\(.spec.providerID)|\(.metadata.name)|\(.metadata.labels["nvidia.com/gpu.clique"] // "N/A")|\(.metadata.labels["nvidia.com/gpu.present"] // "false")"
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
    
    # Print table header with spanning headers
    # Column positions: DisplayName(28) Node(15) State(7) CliqueID(43) State(11) OCID(95) Name(12) State(10) State(10) Announce(18)
    printf "${BOLD}%-28s%-73s%-107s%-23s%-11s%-11s${NC}\n" \
    "" \
    "┌──────────────────────────── K8s ─────────────────────────────────┐" \
    "┌──────────────────────────────────── OCI Instance ─────────────────────────────────────────────────────┐" \
    "┌─── GPU Mem Cluster ───┐" \
    "  CapTopo" \
    "  Maintenance"
    printf "${BOLD}%-28s %-15s %-7s %-43s %-11s %-95s %-12s %-10s %-10s %-18s${NC}\n" \
        "Display Name" "Node" "State" "Clique ID" "State" "Instance OCID" "Name" "State" "State" "Announce"
    print_separator 280
    
    # Process and collect data for sorting
    local display_name status instance_ocid gpu_mem_tag shape time_created
    while IFS='|' read -r display_name status instance_ocid gpu_mem_tag shape time_created; do
        [[ -z "$instance_ocid" ]] && continue
        
        # Look up GPU memory cluster from API-based cache (preferred) or fall back to tag
        local gpu_mem
        gpu_mem=$(get_instance_gpu_cluster "$instance_ocid")
        [[ "$gpu_mem" == "N/A" && "$gpu_mem_tag" != "N/A" ]] && gpu_mem="$gpu_mem_tag"
        
        local k8s_info node_name clique_id node_state
        # k8s_temp format: providerID|nodeName|clique|gpuPresent
        k8s_info=$(grep "$instance_ocid" "$k8s_temp" 2>/dev/null)
        
        if [[ -n "$k8s_info" ]]; then
            # Instance is in Kubernetes
            IFS='|' read -r _ node_name clique_id _ <<< "$k8s_info"
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
        
        # Truncate for display - ensure consistent widths
        local gpu_mem_display="$gpu_mem"
        [[ "$gpu_mem" != "N/A" && ${#gpu_mem} -gt 12 ]] && gpu_mem_display="...${gpu_mem: -9}"
        [[ "$gpu_mem" == "N/A" ]] && gpu_mem_display="-"
        
        local cluster_state_display
        cluster_state_display=$(truncate_string "$cluster_state" 10)
        [[ "$cluster_state" == "N/A" ]] && cluster_state_display="-"
        
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
        
        printf "%-28s %-15s ${ns_color}%-7s${NC} %-43s ${st_color}%-11s${NC} %-95s %-12s ${cs_color}%-10s${NC} ${ct_color}%-10s${NC} ${ann_color}%-18s${NC}\n" \
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
        
        # Also check if any K8s nodes have clique labels (field 3 != N/A)
        # k8s_temp format: providerID|nodeName|clique|gpuPresent
        local has_k8s_cliques=false
        if awk -F'|' '$3 != "N/A" && $3 != "" {found=1; exit} END {exit !found}' "$k8s_temp" 2>/dev/null; then
            has_k8s_cliques=true
        fi
        
        # Also check if the instance-cluster map has entries (from GPU Memory Cluster API)
        local has_instance_cluster_map=false
        if [[ -f "$INSTANCE_CLUSTER_MAP_CACHE" ]] && grep -qv '^#' "$INSTANCE_CLUSTER_MAP_CACHE" 2>/dev/null; then
            has_instance_cluster_map=true
        fi
        
        if [[ "$has_gpu_memory_infra" == "true" || "$has_gpu_mem_instances" == "true" || "$has_k8s_cliques" == "true" || "$has_instance_cluster_map" == "true" ]]; then
            display_clique_summary "$oci_temp" "$k8s_temp"
        fi
    fi
    
    echo ""
    list_instances_not_in_k8s "$oci_temp" "$k8s_temp"
    
    # Cleanup
    rm -f "$oci_temp" "$k8s_temp" "$output_temp"
}

#--------------------------------------------------------------------------------
# List instances requiring maintenance attention
# Shows instances with DEGRADED capacity topology state or active announcements
#--------------------------------------------------------------------------------
list_maintenance_instances() {
    local compartment_id="${1:-$EFFECTIVE_COMPARTMENT_ID}"
    local region="${2:-$EFFECTIVE_REGION}"
    
    # Validate required parameters
    if [[ -z "$compartment_id" ]]; then
        log_error "COMPARTMENT_ID not set"
        return 1
    fi
    if [[ -z "$region" ]]; then
        log_error "REGION not set"
        return 1
    fi
    
    # Display header (minimal - no OKE/network info)
    echo ""
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${RED}                                    INSTANCES REQUIRING MAINTENANCE ATTENTION                                    ${NC}"
    echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${GRAY}Region: ${WHITE}$region${NC}  ${GRAY}Compartment: ${WHITE}$compartment_id${NC}"
    echo -e "${GRAY}Showing instances with: DEGRADED capacity topology state OR active maintenance announcements${NC}"
    echo ""
    
    # Fetch required data
    log_info "Fetching capacity topology data..."
    fetch_capacity_topology
    
    log_info "Fetching announcements..."
    build_announcement_lookup "$compartment_id"
    
    log_info "Fetching GPU memory clusters..."
    fetch_gpu_clusters
    
    log_info "Fetching GPU fabrics..."
    fetch_gpu_fabrics
    
    log_info "Fetching OCI instances..."
    local oci_temp
    oci_temp=$(create_temp_file) || return 1
    
    oci compute instance list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json 2>/dev/null | jq -r '
            .data[] | 
            select(.["lifecycle-state"] != "TERMINATED") |
            "\(.["display-name"])|\(.["lifecycle-state"])|\(.id)|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")|\(.shape)|\(.["availability-domain"])"
        ' > "$oci_temp"
    
    log_info "Fetching Kubernetes node data..."
    local k8s_temp
    k8s_temp=$(create_temp_file) || { rm -f "$oci_temp"; return 1; }
    
    # Format: providerID|nodeName|ready|unschedulable|serialNumber
    kubectl get nodes -o json 2>/dev/null | jq -r '
        .items[] | 
        "\(.spec.providerID)|\(.metadata.name)|\(.status.conditions[] | select(.type=="Ready") | .status)|\(.spec.unschedulable // false)|\(.metadata.labels["oci.oraclecloud.com/host.serial_number"] // "N/A")"
    ' > "$k8s_temp"
    
    log_info "Fetching pod counts per node..."
    local pods_per_node
    pods_per_node=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running -o json 2>/dev/null | \
        jq -r '.items[] | .spec.nodeName' 2>/dev/null | sort | uniq -c | awk '{print $2"|"$1}')
    
    echo ""
    
    # Print table header
    printf "${BOLD}%-4s %-26s %-10s %-18s %-6s %-6s %-5s %-10s %-14s %-16s %-20s %s${NC}\n" \
        "ID" "Display Name" "OCI State" "K8s Node" "Ready" "Cordon" "Pods" "CapTopo" "Serial Number" "Announcement" "Shape" "Instance OCID"
    print_separator 240
    
    # Process instances and filter for maintenance
    local found_count=0
    local output_temp
    output_temp=$(create_temp_file) || { rm -f "$oci_temp" "$k8s_temp"; return 1; }
    
    local display_name oci_state instance_ocid gpu_mem shape ad
    while IFS='|' read -r display_name oci_state instance_ocid gpu_mem shape ad; do
        [[ -z "$instance_ocid" ]] && continue
        
        # Get capacity topology state
        local cap_topo_state
        cap_topo_state=$(get_capacity_topology_state "$instance_ocid")
        [[ -z "$cap_topo_state" ]] && cap_topo_state="N/A"
        
        # Get announcements
        local announcements
        announcements=$(get_resource_announcements "$instance_ocid" "$gpu_mem")
        [[ -z "$announcements" ]] && announcements="-"
        
        # Check if this instance needs attention
        local needs_attention="false"
        if [[ "$cap_topo_state" == "DEGRADED" ]]; then
            needs_attention="true"
        fi
        if [[ "$announcements" != "-" && -n "$announcements" ]]; then
            needs_attention="true"
        fi
        
        # Skip if no maintenance needed
        [[ "$needs_attention" != "true" ]] && continue
        
        ((found_count++))
        
        # Get K8s info
        local k8s_node_name="N/A"
        local k8s_ready="N/A"
        local k8s_cordon="-"
        local k8s_pods="-"
        local k8s_serial="N/A"
        local k8s_info
        k8s_info=$(grep "$instance_ocid" "$k8s_temp" 2>/dev/null)
        if [[ -n "$k8s_info" ]]; then
            k8s_node_name=$(echo "$k8s_info" | cut -d'|' -f2)
            k8s_ready=$(echo "$k8s_info" | cut -d'|' -f3)
            local unschedulable
            unschedulable=$(echo "$k8s_info" | cut -d'|' -f4)
            k8s_serial=$(echo "$k8s_info" | cut -d'|' -f5)
            if [[ "$unschedulable" == "true" ]]; then
                k8s_cordon="Yes"
            else
                k8s_cordon="-"
            fi
            # Get pod count for this node
            local node_pod_count
            node_pod_count=$(echo "$pods_per_node" | grep "^${k8s_node_name}|" | cut -d'|' -f2)
            k8s_pods="${node_pod_count:-0}"
        fi
        
        # Store for output (sort by announcement ticket, then cap_topo state)
        # Put instances without announcements last by using zzz as placeholder
        local sort_ann="$announcements"
        [[ "$announcements" == "-" || -z "$announcements" ]] && sort_ann="zzz"
        echo "${sort_ann}|${cap_topo_state}|${announcements}|${display_name}|${oci_state}|${k8s_node_name}|${k8s_ready}|${k8s_cordon}|${k8s_pods}|${k8s_serial}|${shape}|${instance_ocid}" >> "$output_temp"
    done < "$oci_temp"
    
    # Build instance index map for interactive selection
    declare -A MAINT_INSTANCE_MAP
    local instance_idx=0
    
    # Sort by announcement ticket (field 1), then cap_topo (field 2)
    sort -t'|' -k1,1 -k2,2r "$output_temp" | while IFS='|' read -r sort_key cap_topo ann dn oci_st k8s_node k8s_rdy k8s_cordon k8s_pods k8s_serial shp ocid; do
        ((instance_idx++))
        
        # Store mapping in temp file (subshell workaround)
        echo "m${instance_idx}|${ocid}|${k8s_node}|${dn}|${k8s_cordon}" >> ${TEMP_DIR}/maint_map_$$
        
        # Color coding
        local oci_color="$GREEN"
        case "$oci_st" in
            RUNNING) oci_color="$GREEN" ;;
            STOPPED) oci_color="$RED" ;;
            *) oci_color="$YELLOW" ;;
        esac
        
        local k8s_rdy_color="$GREEN"
        [[ "$k8s_rdy" != "True" ]] && k8s_rdy_color="$RED"
        [[ "$k8s_rdy" == "N/A" ]] && k8s_rdy_color="$GRAY"
        
        local cordon_color="$GRAY"
        [[ "$k8s_cordon" == "Yes" ]] && cordon_color="$YELLOW"
        
        local pods_color="$CYAN"
        [[ "$k8s_pods" == "-" || "$k8s_pods" == "0" ]] && pods_color="$GRAY"
        
        local cap_color="$GREEN"
        [[ "$cap_topo" == "DEGRADED" ]] && cap_color="$RED"
        [[ "$cap_topo" == "N/A" ]] && cap_color="$GRAY"
        
        local ann_color="$GRAY"
        [[ "$ann" != "-" && -n "$ann" ]] && ann_color="$YELLOW"
        
        local serial_color="$GRAY"
        [[ "$k8s_serial" != "N/A" && -n "$k8s_serial" ]] && serial_color="$CYAN"
        
        # Truncate fields
        local dn_trunc="${dn:0:26}"
        local k8s_node_trunc="${k8s_node:0:18}"
        local shape_trunc="${shp:0:20}"
        local ann_trunc="${ann:0:16}"
        local serial_trunc="${k8s_serial:0:14}"
        
        printf "${YELLOW}%-4s${NC} %-26s ${oci_color}%-10s${NC} %-18s ${k8s_rdy_color}%-6s${NC} ${cordon_color}%-6s${NC} ${pods_color}%-5s${NC} ${cap_color}%-10s${NC} ${serial_color}%-14s${NC} ${ann_color}%-16s${NC} %-20s ${GRAY}%s${NC}\n" \
            "m${instance_idx}" "$dn_trunc" "$oci_st" "$k8s_node_trunc" "$k8s_rdy" "$k8s_cordon" "$k8s_pods" "$cap_topo" "$serial_trunc" "$ann_trunc" "$shape_trunc" "$ocid"
    done
    
    # Read instance map from temp file
    if [[ -f ${TEMP_DIR}/maint_map_$$ ]]; then
        while IFS='|' read -r idx ocid k8s_node dn cordon_status; do
            MAINT_INSTANCE_MAP[$idx]="${ocid}|${k8s_node}|${dn}|${cordon_status}"
        done < ${TEMP_DIR}/maint_map_$$
        rm -f ${TEMP_DIR}/maint_map_$$
    fi
    
    echo ""
    print_separator 240
    
    if [[ $found_count -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}✓ No instances require maintenance attention${NC}"
        echo -e "${GRAY}  All instances have healthy capacity topology and no active announcements${NC}"
        rm -f "$oci_temp" "$k8s_temp" "$output_temp"
        return 0
    fi
    
    echo ""
    echo -e "${YELLOW}Found ${WHITE}${found_count}${YELLOW} instance(s) requiring attention${NC}"
    echo ""
    
    # Show announcement details in column format
    echo -e "${BOLD}${CYAN}─── Announcement Details ─────────────────────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    printf "${BOLD}%-4s %-10s %-28s %-20s %-20s %-70s${NC}\n" \
        "ID" "Ticket" "Type" "Start" "End" "Description"
    print_separator 160
    
    # Collect unique announcements with index
    local ann_idx=0
    declare -A ANN_TICKET_MAP
    local shown_announcements=""
    
    # Extract unique tickets and sort them
    local sorted_tickets
    sorted_tickets=$(awk -F'|' '{print $3}' "$output_temp" 2>/dev/null | tr ',' '\n' | grep -v '^-$' | grep -v '^$' | sort -u)
    
    local ticket
    while read -r ticket; do
        [[ -z "$ticket" ]] && continue
        [[ "$shown_announcements" == *"|${ticket}|"* ]] && continue
        shown_announcements="${shown_announcements}|${ticket}|"
        
        ((ann_idx++))
        
        # Look up announcement details
        local ann_detail_file=""
        local cache_file
        for cache_file in "$CACHE_DIR"/*.json; do
            [[ ! -f "$cache_file" ]] && continue
            [[ "$cache_file" == "$ANNOUNCEMENTS_LIST_CACHE" ]] && continue
            
            local ref_ticket
            ref_ticket=$(jq -r '.data."reference-ticket-number" // ""' "$cache_file" 2>/dev/null)
            if [[ "${ref_ticket:0:8}" == "$ticket" ]]; then
                ann_detail_file="$cache_file"
                break
            fi
        done
        
        if [[ -n "$ann_detail_file" && -f "$ann_detail_file" ]]; then
            local ann_type ann_time_start ann_time_end ann_description
            ann_type=$(jq -r '.data["announcement-type"] // "N/A"' "$ann_detail_file" 2>/dev/null)
            ann_time_start=$(jq -r '.data["time-one-value"] // "N/A"' "$ann_detail_file" 2>/dev/null)
            ann_time_end=$(jq -r '.data["time-two-value"] // "N/A"' "$ann_detail_file" 2>/dev/null)
            ann_description=$(jq -r '.data.description // "N/A"' "$ann_detail_file" 2>/dev/null)
            
            # Format times
            local start_display="${ann_time_start:0:16}"
            local end_display="${ann_time_end:0:16}"
            [[ "$ann_time_start" == "N/A" || "$ann_time_start" == "null" ]] && start_display="-"
            [[ "$ann_time_end" == "N/A" || "$ann_time_end" == "null" ]] && end_display="-"
            
            # Truncate description to 70 chars
            local desc_trunc="${ann_description:0:70}"
            [[ ${#ann_description} -gt 70 ]] && desc_trunc="${desc_trunc}..."
            
            # Store mapping
            ANN_TICKET_MAP["a${ann_idx}"]="${ticket}|${ann_detail_file}"
            
            # Color based on type
            local type_color="$WHITE"
            case "$ann_type" in
                ACTION_REQUIRED) type_color="$RED" ;;
                EMERGENCY_MAINTENANCE) type_color="$RED" ;;
                SCHEDULED_MAINTENANCE) type_color="$YELLOW" ;;
                *) type_color="$CYAN" ;;
            esac
            
            printf "${YELLOW}%-4s${NC} %-10s ${type_color}%-28s${NC} %-20s %-20s ${GRAY}%-70s${NC}\n" \
                "a${ann_idx}" "$ticket" "$ann_type" "$start_display" "$end_display" "$desc_trunc"
        else
            ANN_TICKET_MAP["a${ann_idx}"]="${ticket}|"
            printf "${YELLOW}%-4s${NC} %-10s %-28s %-20s %-20s ${GRAY}%-70s${NC}\n" \
                "a${ann_idx}" "$ticket" "(not cached)" "-" "-" "Run --refresh to fetch details"
        fi
    done <<< "$sorted_tickets"
    
    echo ""
    echo -e "${BOLD}${WHITE}Legend:${NC}"
    echo -e "  ${RED}DEGRADED${NC}   - Capacity topology indicates degraded infrastructure"
    echo -e "  ${YELLOW}Cordon${NC}     - Node is cordoned (unschedulable) in Kubernetes"
    echo -e "  ${RED}ACTION_REQUIRED${NC} / ${RED}EMERGENCY_MAINTENANCE${NC} - Immediate attention needed"
    echo ""
    
    # Interactive menu
    while true; do
        echo -e "${BOLD}${WHITE}─── Actions ───${NC}"
        echo -e "  Enter ${YELLOW}m#${NC} (e.g., m1) to manage a single instance"
        echo -e "  Enter ${YELLOW}a#${NC} (e.g., a1) to view full announcement details"
        echo -e "  Enter ${YELLOW}list${NC} to show announcement details again"
        echo -e "  ${BOLD}View Pods:${NC}"
        echo -e "    ${YELLOW}pods m1${NC}            - View pods on a single node"
        echo -e "    ${YELLOW}pods m1,m2,m3${NC}      - View pods on multiple nodes (or ${YELLOW}pods all${NC})"
        echo -e "  ${BOLD}Bulk Operations:${NC}"
        echo -e "    ${YELLOW}cordon m1,m2,m3${NC}    - Cordon multiple nodes (or ${YELLOW}cordon all${NC})"
        echo -e "    ${YELLOW}drain m1,m2,m3${NC}     - Drain multiple nodes (or ${YELLOW}drain all${NC})"
        echo -e "    ${YELLOW}uncordon m1,m2,m3${NC}  - Uncordon multiple nodes (or ${YELLOW}uncordon all${NC})"
        echo -e "    ${YELLOW}terminate m1,m2,m3${NC} - Terminate multiple instances (or ${YELLOW}terminate all${NC})"
        echo -e "  Enter ${YELLOW}q${NC} to quit"
        echo ""
        echo -n -e "${CYAN}Selection: ${NC}"
        read -r selection
        
        [[ -z "$selection" || "$selection" == "q" || "$selection" == "Q" ]] && break
        
        # Show announcements list again
        if [[ "$selection" == "list" ]]; then
            echo ""
            echo -e "${BOLD}${CYAN}─── Announcement Details ─────────────────────────────────────────────────────────────────────────────────────────${NC}"
            echo ""
            printf "${BOLD}%-4s %-10s %-28s %-20s %-20s %-70s${NC}\n" \
                "ID" "Ticket" "Type" "Start" "End" "Description"
            print_separator 160
            
            local list_ann_idx=0
            local list_shown=""
            
            while read -r ticket; do
                [[ -z "$ticket" ]] && continue
                [[ "$list_shown" == *"|${ticket}|"* ]] && continue
                list_shown="${list_shown}|${ticket}|"
                
                ((list_ann_idx++))
                
                # Look up announcement details
                local ann_detail_file=""
                local cache_file
                for cache_file in "$CACHE_DIR"/*.json; do
                    [[ ! -f "$cache_file" ]] && continue
                    [[ "$cache_file" == "$ANNOUNCEMENTS_LIST_CACHE" ]] && continue
                    
                    local ref_ticket
                    ref_ticket=$(jq -r '.data."reference-ticket-number" // ""' "$cache_file" 2>/dev/null)
                    if [[ "${ref_ticket:0:8}" == "$ticket" ]]; then
                        ann_detail_file="$cache_file"
                        break
                    fi
                done
                
                if [[ -n "$ann_detail_file" && -f "$ann_detail_file" ]]; then
                    local ann_type ann_time_start ann_time_end ann_description
                    ann_type=$(jq -r '.data["announcement-type"] // "N/A"' "$ann_detail_file" 2>/dev/null)
                    ann_time_start=$(jq -r '.data["time-one-value"] // "N/A"' "$ann_detail_file" 2>/dev/null)
                    ann_time_end=$(jq -r '.data["time-two-value"] // "N/A"' "$ann_detail_file" 2>/dev/null)
                    ann_description=$(jq -r '.data.description // "N/A"' "$ann_detail_file" 2>/dev/null)
                    
                    local start_display="${ann_time_start:0:16}"
                    local end_display="${ann_time_end:0:16}"
                    [[ "$ann_time_start" == "N/A" || "$ann_time_start" == "null" ]] && start_display="-"
                    [[ "$ann_time_end" == "N/A" || "$ann_time_end" == "null" ]] && end_display="-"
                    
                    local desc_trunc="${ann_description:0:70}"
                    [[ ${#ann_description} -gt 70 ]] && desc_trunc="${desc_trunc}..."
                    
                    local type_color="$WHITE"
                    case "$ann_type" in
                        ACTION_REQUIRED) type_color="$RED" ;;
                        EMERGENCY_MAINTENANCE) type_color="$RED" ;;
                        SCHEDULED_MAINTENANCE) type_color="$YELLOW" ;;
                        *) type_color="$CYAN" ;;
                    esac
                    
                    printf "${YELLOW}%-4s${NC} %-10s ${type_color}%-28s${NC} %-20s %-20s ${GRAY}%-70s${NC}\n" \
                        "a${list_ann_idx}" "$ticket" "$ann_type" "$start_display" "$end_display" "$desc_trunc"
                else
                    printf "${YELLOW}%-4s${NC} %-10s %-28s %-20s %-20s ${GRAY}%-70s${NC}\n" \
                        "a${list_ann_idx}" "$ticket" "(not cached)" "-" "-" "Run --refresh to fetch details"
                fi
            done <<< "$sorted_tickets"
            echo ""
            continue
        fi
        
        # View pods on nodes
        if [[ "$selection" =~ ^pods[[:space:]]+(.*) ]]; then
            local pods_targets="${BASH_REMATCH[1]}"
            
            # Handle "all" keyword
            if [[ "$pods_targets" == "all" ]]; then
                pods_targets=$(echo "${!MAINT_INSTANCE_MAP[@]}" | tr ' ' ',')
            fi
            
            # Parse instance list
            local pods_target_list=()
            local pods_valid_nodes=()
            local pods_invalid=()
            local pods_non_k8s=()
            
            IFS=',' read -ra pods_target_list <<< "$pods_targets"
            
            for target in "${pods_target_list[@]}"; do
                target=$(echo "$target" | tr -d ' ')
                local inst_info="${MAINT_INSTANCE_MAP[$target]:-}"
                if [[ -z "$inst_info" ]]; then
                    pods_invalid+=("$target")
                    continue
                fi
                
                local inst_ocid inst_k8s_node inst_name inst_cordon
                IFS='|' read -r inst_ocid inst_k8s_node inst_name inst_cordon <<< "$inst_info"
                
                if [[ "$inst_k8s_node" == "N/A" || -z "$inst_k8s_node" ]]; then
                    pods_non_k8s+=("$target:$inst_name")
                    continue
                fi
                
                pods_valid_nodes+=("$target|$inst_k8s_node|$inst_name")
            done
            
            # Report invalid selections
            if [[ ${#pods_invalid[@]} -gt 0 ]]; then
                echo -e "${RED}Invalid selections: ${pods_invalid[*]}${NC}"
            fi
            if [[ ${#pods_non_k8s[@]} -gt 0 ]]; then
                echo -e "${YELLOW}Skipping (not in K8s): ${pods_non_k8s[*]}${NC}"
            fi
            
            if [[ ${#pods_valid_nodes[@]} -eq 0 ]]; then
                echo -e "${RED}No valid nodes selected${NC}"
                continue
            fi
            
            echo ""
            echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}${CYAN}  PODS ON ${#pods_valid_nodes[@]} NODE(S)${NC}"
            echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
            
            for node_entry in "${pods_valid_nodes[@]}"; do
                local idx node_name inst_name
                IFS='|' read -r idx node_name inst_name <<< "$node_entry"
                
                echo ""
                echo -e "${BOLD}${WHITE}─── [$idx] ${CYAN}$inst_name${NC} ${GRAY}(node: $node_name)${NC} ${BOLD}${WHITE}───${NC}"
                echo ""
                
                # Get pods on this node
                local node_pods
                node_pods=$(kubectl get pods --all-namespaces --field-selector "spec.nodeName=$node_name" -o wide 2>/dev/null)
                
                if [[ -n "$node_pods" ]]; then
                    # Count pods (excluding header)
                    local pod_count
                    pod_count=$(echo "$node_pods" | tail -n +2 | wc -l)
                    echo -e "${WHITE}Total Pods: ${CYAN}$pod_count${NC}"
                    echo ""
                    
                    # Print with color coding
                    echo "$node_pods" | head -1 | while IFS= read -r line; do
                        echo -e "${BOLD}${WHITE}$line${NC}"
                    done
                    
                    echo "$node_pods" | tail -n +2 | while IFS= read -r line; do
                        if echo "$line" | grep -q "Running"; then
                            echo -e "${GREEN}$line${NC}"
                        elif echo "$line" | grep -q "Completed"; then
                            echo -e "${GRAY}$line${NC}"
                        elif echo "$line" | grep -qE "Error|Failed|CrashLoopBackOff|ImagePullBackOff"; then
                            echo -e "${RED}$line${NC}"
                        elif echo "$line" | grep -qE "Pending|ContainerCreating|Init"; then
                            echo -e "${YELLOW}$line${NC}"
                        else
                            echo "$line"
                        fi
                    done
                else
                    echo -e "${GRAY}No pods found on this node${NC}"
                fi
            done
            
            echo ""
            echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
            echo ""
            continue
        fi
        
        # Check for bulk operations
        if [[ "$selection" =~ ^(cordon|drain|uncordon|terminate)[[:space:]]+(.*) ]]; then
            local bulk_action="${BASH_REMATCH[1]}"
            local bulk_targets="${BASH_REMATCH[2]}"
            
            # Handle "all" keyword
            if [[ "$bulk_targets" == "all" ]]; then
                bulk_targets=$(echo "${!MAINT_INSTANCE_MAP[@]}" | tr ' ' ',')
            fi
            
            # Parse instance list
            local target_list=()
            local valid_instances=()
            local invalid_instances=()
            local non_k8s_instances=()
            
            IFS=',' read -ra target_list <<< "$bulk_targets"
            
            for target in "${target_list[@]}"; do
                target=$(echo "$target" | tr -d ' ')  # Remove spaces
                local inst_info="${MAINT_INSTANCE_MAP[$target]:-}"
                if [[ -z "$inst_info" ]]; then
                    invalid_instances+=("$target")
                    continue
                fi
                
                local inst_ocid inst_k8s_node inst_name inst_cordon
                IFS='|' read -r inst_ocid inst_k8s_node inst_name inst_cordon <<< "$inst_info"
                
                # For K8s operations, check if node exists
                if [[ "$bulk_action" != "terminate" ]]; then
                    if [[ "$inst_k8s_node" == "N/A" || -z "$inst_k8s_node" ]]; then
                        non_k8s_instances+=("$target:$inst_name")
                        continue
                    fi
                fi
                
                valid_instances+=("$target|$inst_ocid|$inst_k8s_node|$inst_name|$inst_cordon")
            done
            
            # Report invalid selections
            if [[ ${#invalid_instances[@]} -gt 0 ]]; then
                echo -e "${RED}Invalid selections: ${invalid_instances[*]}${NC}"
            fi
            if [[ ${#non_k8s_instances[@]} -gt 0 ]]; then
                echo -e "${YELLOW}Skipping (not in K8s): ${non_k8s_instances[*]}${NC}"
            fi
            
            if [[ ${#valid_instances[@]} -eq 0 ]]; then
                echo -e "${RED}No valid instances selected${NC}"
                continue
            fi
            
            # Show confirmation with all instances and commands
            echo ""
            echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}${WHITE}  BULK ${bulk_action^^} - ${#valid_instances[@]} instance(s)${NC}"
            echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════════════════════════════${NC}"
            echo ""
            
            printf "${BOLD}%-6s %-28s %-20s %-60s${NC}\n" "ID" "Instance Name" "K8s Node" "Command"
            print_separator 120
            
            for inst_entry in "${valid_instances[@]}"; do
                local idx inst_ocid inst_k8s_node inst_name inst_cordon
                IFS='|' read -r idx inst_ocid inst_k8s_node inst_name inst_cordon <<< "$inst_entry"
                
                local cmd=""
                case "$bulk_action" in
                    cordon)
                        cmd="kubectl cordon ${inst_k8s_node}"
                        ;;
                    drain)
                        cmd="kubectl drain ${inst_k8s_node} --ignore-daemonsets --delete-emptydir-data --force"
                        ;;
                    uncordon)
                        cmd="kubectl uncordon ${inst_k8s_node}"
                        ;;
                    terminate)
                        cmd="oci compute instance terminate --instance-id ${inst_ocid} --preserve-boot-volume false --force"
                        ;;
                esac
                
                printf "${YELLOW}%-6s${NC} %-28s %-20s ${WHITE}%s${NC}\n" "$idx" "${inst_name:0:27}" "${inst_k8s_node:0:19}" "$cmd"
            done
            
            echo ""
            print_separator 120
            echo ""
            
            # Warning for destructive actions
            if [[ "$bulk_action" == "drain" ]]; then
                echo -e "${RED}⚠️  WARNING: This will evict all pods from ${#valid_instances[@]} node(s)!${NC}"
            elif [[ "$bulk_action" == "terminate" ]]; then
                echo -e "${RED}⚠️  WARNING: This will PERMANENTLY TERMINATE ${#valid_instances[@]} instance(s)!${NC}"
                echo -e "${RED}    This action cannot be undone!${NC}"
            fi
            
            echo ""
            local confirm_text="yes"
            [[ "$bulk_action" == "terminate" ]] && confirm_text="TERMINATE"
            
            echo -n -e "${RED}Type '${confirm_text}' to execute all ${#valid_instances[@]} commands: ${NC}"
            read -r confirm
            
            if [[ "$confirm" == "$confirm_text" ]]; then
                echo ""
                echo -e "${BOLD}${YELLOW}Executing bulk ${bulk_action}...${NC}"
                echo ""
                
                local success_count=0
                local fail_count=0
                
                for inst_entry in "${valid_instances[@]}"; do
                    local idx inst_ocid inst_k8s_node inst_name inst_cordon
                    IFS='|' read -r idx inst_ocid inst_k8s_node inst_name inst_cordon <<< "$inst_entry"
                    
                    local cmd="" log_cmd=""
                    case "$bulk_action" in
                        cordon)
                            cmd="kubectl cordon ${inst_k8s_node}"
                            log_cmd="CORDON: $cmd"
                            ;;
                        drain)
                            cmd="kubectl drain ${inst_k8s_node} --ignore-daemonsets --delete-emptydir-data --force"
                            log_cmd="DRAIN: $cmd"
                            ;;
                        uncordon)
                            cmd="kubectl uncordon ${inst_k8s_node}"
                            log_cmd="UNCORDON: $cmd"
                            ;;
                        terminate)
                            cmd="oci compute instance terminate --instance-id ${inst_ocid} --preserve-boot-volume false --force"
                            log_cmd="TERMINATE: $cmd"
                            ;;
                    esac
                    
                    echo -e "${YELLOW}[$idx] Executing:${NC} $cmd"
                    if eval "$cmd" 2>&1; then
                        echo -e "${GREEN}  ✓ Success: ${inst_name}${NC}"
                        ((success_count++))
                        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $log_cmd" >> "$MAINTENANCE_LOG_FILE"
                    else
                        echo -e "${RED}  ✗ Failed: ${inst_name}${NC}"
                        ((fail_count++))
                        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED $log_cmd" >> "$MAINTENANCE_LOG_FILE"
                    fi
                    echo ""
                done
                
                echo -e "${BOLD}${WHITE}═══ Bulk Operation Complete ═══${NC}"
                echo -e "  ${GREEN}Success:${NC} $success_count"
                echo -e "  ${RED}Failed:${NC}  $fail_count"
                echo -e "  ${GRAY}Log:${NC}     $MAINTENANCE_LOG_FILE"
            else
                echo -e "${YELLOW}Cancelled${NC}"
            fi
            echo ""
            continue
        fi
        
        if [[ "$selection" =~ ^m[0-9]+$ ]]; then
            # Instance management
            local inst_info="${MAINT_INSTANCE_MAP[$selection]:-}"
            if [[ -z "$inst_info" ]]; then
                echo -e "${RED}Invalid selection: $selection${NC}"
                continue
            fi
            
            local inst_ocid inst_k8s_node inst_name inst_cordon
            IFS='|' read -r inst_ocid inst_k8s_node inst_name inst_cordon <<< "$inst_info"
            
            echo ""
            echo -e "${BOLD}${WHITE}═══ Instance: ${CYAN}${inst_name}${NC} ${BOLD}${WHITE}═══${NC}"
            echo -e "  ${WHITE}OCID:${NC}     $inst_ocid"
            echo -e "  ${WHITE}K8s Node:${NC} $inst_k8s_node"
            echo -e "  ${WHITE}Cordoned:${NC} $inst_cordon"
            echo ""
            echo -e "${BOLD}${WHITE}Actions:${NC}"
            echo -e "  ${YELLOW}1${NC}) Cordon node (mark unschedulable)"
            echo -e "  ${YELLOW}2${NC}) Drain node (cordon + evict pods)"
            echo -e "  ${YELLOW}3${NC}) Uncordon node (mark schedulable)"
            echo -e "  ${YELLOW}4${NC}) Terminate instance"
            echo -e "  ${YELLOW}5${NC}) View instance details"
            echo -e "  ${YELLOW}b${NC}) Back"
            echo ""
            echo -n -e "${CYAN}Action: ${NC}"
            read -r action
            
            case "$action" in
                1)
                    # Cordon
                    if [[ "$inst_k8s_node" == "N/A" || -z "$inst_k8s_node" ]]; then
                        echo -e "${RED}Cannot cordon: Instance is not in Kubernetes${NC}"
                        continue
                    fi
                    echo ""
                    echo -e "${YELLOW}Command to execute:${NC}"
                    echo -e "  ${WHITE}kubectl cordon ${inst_k8s_node}${NC}"
                    echo ""
                    echo -n -e "${RED}Confirm cordon node '${inst_k8s_node}'? (yes/no): ${NC}"
                    read -r confirm
                    if [[ "$confirm" == "yes" ]]; then
                        echo ""
                        echo -e "${YELLOW}Executing: kubectl cordon ${inst_k8s_node}${NC}"
                        if kubectl cordon "$inst_k8s_node" 2>&1; then
                            echo -e "${GREEN}✓ Node cordoned successfully${NC}"
                            # Log action
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] CORDON: kubectl cordon ${inst_k8s_node}" >> "$MAINTENANCE_LOG_FILE"
                        else
                            echo -e "${RED}✗ Failed to cordon node${NC}"
                        fi
                    else
                        echo -e "${YELLOW}Cancelled${NC}"
                    fi
                    ;;
                2)
                    # Drain
                    if [[ "$inst_k8s_node" == "N/A" || -z "$inst_k8s_node" ]]; then
                        echo -e "${RED}Cannot drain: Instance is not in Kubernetes${NC}"
                        continue
                    fi
                    echo ""
                    echo -e "${YELLOW}Command to execute:${NC}"
                    echo -e "  ${WHITE}kubectl drain ${inst_k8s_node} --ignore-daemonsets --delete-emptydir-data --force${NC}"
                    echo ""
                    echo -e "${RED}⚠️  WARNING: This will evict all pods from the node!${NC}"
                    echo -n -e "${RED}Confirm drain node '${inst_k8s_node}'? (yes/no): ${NC}"
                    read -r confirm
                    if [[ "$confirm" == "yes" ]]; then
                        echo ""
                        echo -e "${YELLOW}Executing: kubectl drain ${inst_k8s_node} --ignore-daemonsets --delete-emptydir-data --force${NC}"
                        if kubectl drain "$inst_k8s_node" --ignore-daemonsets --delete-emptydir-data --force 2>&1; then
                            echo -e "${GREEN}✓ Node drained successfully${NC}"
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] DRAIN: kubectl drain ${inst_k8s_node} --ignore-daemonsets --delete-emptydir-data --force" >> "$MAINTENANCE_LOG_FILE"
                        else
                            echo -e "${RED}✗ Failed to drain node${NC}"
                        fi
                    else
                        echo -e "${YELLOW}Cancelled${NC}"
                    fi
                    ;;
                3)
                    # Uncordon
                    if [[ "$inst_k8s_node" == "N/A" || -z "$inst_k8s_node" ]]; then
                        echo -e "${RED}Cannot uncordon: Instance is not in Kubernetes${NC}"
                        continue
                    fi
                    echo ""
                    echo -e "${YELLOW}Command to execute:${NC}"
                    echo -e "  ${WHITE}kubectl uncordon ${inst_k8s_node}${NC}"
                    echo ""
                    echo -n -e "${CYAN}Confirm uncordon node '${inst_k8s_node}'? (yes/no): ${NC}"
                    read -r confirm
                    if [[ "$confirm" == "yes" ]]; then
                        echo ""
                        echo -e "${YELLOW}Executing: kubectl uncordon ${inst_k8s_node}${NC}"
                        if kubectl uncordon "$inst_k8s_node" 2>&1; then
                            echo -e "${GREEN}✓ Node uncordoned successfully${NC}"
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] UNCORDON: kubectl uncordon ${inst_k8s_node}" >> "$MAINTENANCE_LOG_FILE"
                        else
                            echo -e "${RED}✗ Failed to uncordon node${NC}"
                        fi
                    else
                        echo -e "${YELLOW}Cancelled${NC}"
                    fi
                    ;;
                4)
                    # Terminate
                    echo ""
                    echo -e "${YELLOW}Command to execute:${NC}"
                    echo -e "  ${WHITE}oci compute instance terminate --instance-id ${inst_ocid} --preserve-boot-volume false --force${NC}"
                    echo ""
                    echo -e "${RED}⚠️  WARNING: This will PERMANENTLY TERMINATE the instance!${NC}"
                    echo -e "${RED}    Instance: ${inst_name}${NC}"
                    echo -e "${RED}    OCID: ${inst_ocid}${NC}"
                    echo ""
                    echo -n -e "${RED}Type 'TERMINATE' to confirm: ${NC}"
                    read -r confirm
                    if [[ "$confirm" == "TERMINATE" ]]; then
                        echo ""
                        echo -e "${YELLOW}Executing: oci compute instance terminate --instance-id ${inst_ocid} --preserve-boot-volume false --force${NC}"
                        if oci compute instance terminate --instance-id "$inst_ocid" --preserve-boot-volume false --force 2>&1; then
                            echo -e "${GREEN}✓ Instance termination initiated${NC}"
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] TERMINATE: oci compute instance terminate --instance-id ${inst_ocid} --preserve-boot-volume false --force" >> "$MAINTENANCE_LOG_FILE"
                        else
                            echo -e "${RED}✗ Failed to terminate instance${NC}"
                        fi
                    else
                        echo -e "${YELLOW}Cancelled (must type 'TERMINATE' exactly)${NC}"
                    fi
                    ;;
                5)
                    # View details
                    display_instance_details "$inst_ocid"
                    ;;
                b|B)
                    ;;
                *)
                    echo -e "${RED}Invalid action${NC}"
                    ;;
            esac
            echo ""
            
        elif [[ "$selection" =~ ^a[0-9]+$ ]]; then
            # Announcement details
            local ann_info="${ANN_TICKET_MAP[$selection]:-}"
            if [[ -z "$ann_info" ]]; then
                echo -e "${RED}Invalid selection: $selection${NC}"
                continue
            fi
            
            local ann_ticket ann_file
            IFS='|' read -r ann_ticket ann_file <<< "$ann_info"
            
            echo ""
            echo -e "${BOLD}${YELLOW}═══ Announcement: ${ann_ticket} ═══${NC}"
            
            if [[ -n "$ann_file" && -f "$ann_file" ]]; then
                local full_ticket ann_type ann_summary ann_description ann_services
                local ann_time_start ann_time_end ann_time_created platform_type lifecycle_state
                
                full_ticket=$(jq -r '.data."reference-ticket-number" // "N/A"' "$ann_file")
                ann_type=$(jq -r '.data["announcement-type"] // "N/A"' "$ann_file")
                ann_summary=$(jq -r '.data.summary // "N/A"' "$ann_file")
                ann_description=$(jq -r '.data.description // "N/A"' "$ann_file")
                ann_services=$(jq -r '.data["affected-services"] // [] | join(", ")' "$ann_file")
                ann_time_start=$(jq -r '.data["time-one-value"] // "N/A"' "$ann_file")
                ann_time_end=$(jq -r '.data["time-two-value"] // "N/A"' "$ann_file")
                ann_time_created=$(jq -r '.data["time-created"] // "N/A"' "$ann_file")
                platform_type=$(jq -r '.data["platform-type"] // "N/A"' "$ann_file")
                lifecycle_state=$(jq -r '.data["lifecycle-state"] // "N/A"' "$ann_file")
                
                echo ""
                echo -e "  ${WHITE}Full Ticket:${NC}  $full_ticket"
                echo -e "  ${WHITE}Type:${NC}         $ann_type"
                echo -e "  ${WHITE}State:${NC}        $lifecycle_state"
                echo -e "  ${WHITE}Platform:${NC}     $platform_type"
                echo -e "  ${WHITE}Services:${NC}     $ann_services"
                echo -e "  ${WHITE}Created:${NC}      ${ann_time_created:0:19}"
                [[ "$ann_time_start" != "N/A" && "$ann_time_start" != "null" ]] && echo -e "  ${WHITE}Start Time:${NC}   ${ann_time_start:0:19}"
                [[ "$ann_time_end" != "N/A" && "$ann_time_end" != "null" ]] && echo -e "  ${WHITE}End Time:${NC}     ${ann_time_end:0:19}"
                echo ""
                echo -e "  ${WHITE}Summary:${NC}"
                echo -e "    ${CYAN}$ann_summary${NC}"
                echo ""
                if [[ "$ann_description" != "N/A" && "$ann_description" != "null" && -n "$ann_description" ]]; then
                    echo -e "  ${WHITE}Description:${NC}"
                    echo "$ann_description" | fold -s -w 90 | while IFS= read -r line; do
                        echo -e "    ${GRAY}${line}${NC}"
                    done
                fi
                
                # Show affected resources count
                local resource_count
                resource_count=$(jq '.data."affected-resources" | length' "$ann_file" 2>/dev/null) || resource_count=0
                echo ""
                echo -e "  ${WHITE}Affected Resources:${NC} $resource_count"
            else
                echo -e "${RED}  Announcement details not cached. Run --refresh to fetch.${NC}"
            fi
            echo ""
        else
            echo -e "${RED}Invalid selection. Use m# for instance or a# for announcement.${NC}"
        fi
    done
    
    # Cleanup
    rm -f "$oci_temp" "$k8s_temp" "$output_temp"
}

#--------------------------------------------------------------------------------
# List all announcements with affected resource details
# Shows all announcements and validates if affected instances still exist
#--------------------------------------------------------------------------------
list_all_announcements() {
    local compartment_id="${1:-$EFFECTIVE_COMPARTMENT_ID}"
    local region="${2:-$EFFECTIVE_REGION}"
    
    # Validate required parameters
    if [[ -z "$compartment_id" ]]; then
        log_error "COMPARTMENT_ID not set"
        return 1
    fi
    
    # Display header
    display_oke_environment_header "$compartment_id" "$region"
    
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}                                         ALL ANNOUNCEMENTS                                                       ${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Fetch announcements
    log_info "Fetching announcements from OCI..."
    
    # Force refresh of announcements cache
    rm -f "$ANNOUNCEMENTS_LIST_CACHE"
    
    if ! oci announce announcements list \
            --compartment-id "$compartment_id" \
            --all > "$ANNOUNCEMENTS_LIST_CACHE" 2>/dev/null; then
        log_error "Failed to fetch announcements"
        return 1
    fi
    
    # Get announcement count
    local ann_count
    ann_count=$(jq '.data.items | length' "$ANNOUNCEMENTS_LIST_CACHE" 2>/dev/null) || ann_count=0
    
    if [[ "$ann_count" -eq 0 ]]; then
        echo -e "${GREEN}✓ No announcements found${NC}"
        echo ""
        return 0
    fi
    
    echo -e "${GRAY}Found ${WHITE}${ann_count}${GRAY} announcement(s)${NC}"
    echo ""
    
    # Fetch all instances in compartment for validation
    log_info "Fetching instances for validation..."
    local instances_json
    instances_json=$(oci compute instance list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json 2>/dev/null)
    
    # Build instance lookup (OCID -> display_name|state)
    declare -A INSTANCE_LOOKUP
    if [[ -n "$instances_json" ]]; then
        while IFS='|' read -r ocid name state; do
            [[ -n "$ocid" ]] && INSTANCE_LOOKUP[$ocid]="${name}|${state}"
        done < <(echo "$instances_json" | jq -r '.data[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])"' 2>/dev/null)
    fi
    
    # Fetch details for each announcement
    log_info "Fetching announcement details..."
    local announcement_ids
    announcement_ids=$(jq -r '.data.items[].id' "$ANNOUNCEMENTS_LIST_CACHE" 2>/dev/null)
    
    # Fetch details in parallel
    local ann_id
    for ann_id in $announcement_ids; do
        local detail_file="${CACHE_DIR}/${ann_id##*.}.json"
        oci announce announcements get --announcement-id "$ann_id" > "$detail_file" 2>/dev/null &
    done
    wait
    
    echo ""
    
    # Print announcements table header
    printf "${BOLD}%-4s %-10s %-10s %-24s %-16s %-16s %-30s %-14s %-42s %-80s${NC}\n" \
        "ID" "Ticket" "State" "Type" "Start" "End" "Display Name" "OCI State" "Instance OCID" "Description"
    print_separator 260
    
    # Build announcement index map for interactive selection
    declare -A ANN_INDEX_MAP
    local ann_idx=0
    
    # Process each announcement
    for ann_id in $announcement_ids; do
        local detail_file="${CACHE_DIR}/${ann_id##*.}.json"
        
        if [[ ! -f "$detail_file" ]]; then
            continue
        fi
        
        ((ann_idx++))
        
        # Extract announcement fields
        local ref_ticket lifecycle_state ann_type description
        local time_one time_two resource_count
        
        ref_ticket=$(jq -r '.data."reference-ticket-number" // "N/A"' "$detail_file")
        lifecycle_state=$(jq -r '.data."lifecycle-state" // "N/A"' "$detail_file")
        ann_type=$(jq -r '.data."announcement-type" // "N/A"' "$detail_file")
        description=$(jq -r '.data.description // ""' "$detail_file")
        time_one=$(jq -r '.data."time-one-value" // "N/A"' "$detail_file")
        time_two=$(jq -r '.data."time-two-value" // "N/A"' "$detail_file")
        resource_count=$(jq '.data."affected-resources" | length' "$detail_file" 2>/dev/null) || resource_count=0
        
        # Store mapping
        ANN_INDEX_MAP["a${ann_idx}"]="${detail_file}"
        
        # Format times
        local start_display="${time_one:0:16}"
        local end_display="${time_two:0:16}"
        [[ "$time_one" == "N/A" || "$time_one" == "null" ]] && start_display="-"
        [[ "$time_two" == "N/A" || "$time_two" == "null" ]] && end_display="-"
        
        # Truncate description to 80 chars
        local desc_trunc="${description:0:80}"
        [[ ${#description} -gt 80 ]] && desc_trunc="${desc_trunc}..."
        
        # Color based on lifecycle state
        local state_color="$GREEN"
        case "$lifecycle_state" in
            ACTIVE) state_color="$YELLOW" ;;
            INACTIVE) state_color="$GRAY" ;;
            *) state_color="$WHITE" ;;
        esac
        
        # Color based on announcement type
        local type_color="$WHITE"
        case "$ann_type" in
            ACTION_REQUIRED) type_color="$RED" ;;
            SCHEDULED_MAINTENANCE) type_color="$YELLOW" ;;
            EMERGENCY_MAINTENANCE) type_color="$RED" ;;
            PRODUCTION_EVENT_NOTIFICATION) type_color="$CYAN" ;;
            *) type_color="$WHITE" ;;
        esac
        
        # Truncate ticket for display
        local ticket_display="${ref_ticket:0:10}"
        
        # If no affected resources, show one row with N/A for instance info
        if [[ $resource_count -eq 0 ]]; then
            printf "${YELLOW}%-4s${NC} %-10s ${state_color}%-10s${NC} ${type_color}%-24s${NC} %-16s %-16s ${GRAY}%-30s${NC} ${GRAY}%-14s${NC} ${GRAY}%-42s${NC} ${GRAY}%-80s${NC}\n" \
                "a${ann_idx}" "$ticket_display" "$lifecycle_state" "$ann_type" "$start_display" "$end_display" "-" "-" "-" "$desc_trunc"
        else
            # Loop through affected resources
            local i
            local first_row=true
            for ((i=0; i<resource_count; i++)); do
                # Get resource details
                local resource_id resource_name
                
                resource_id=$(jq -r ".data.\"affected-resources\"[$i] | 
                    if .properties then
                        (.properties[] | select(.name == \"resourceId\" or .name == \"instanceId\") | .value) // \"N/A\"
                    else
                        (.\"resource-id\" // .\"instance-id\" // \"N/A\")
                    end" "$detail_file" 2>/dev/null)
                
                resource_name=$(jq -r ".data.\"affected-resources\"[$i] |
                    if .properties then
                        (.properties[] | select(.name == \"resourceName\" or .name == \"instanceName\") | .value) // \"N/A\"
                    else
                        (.\"resource-name\" // .\"instance-name\" // \"N/A\")
                    end" "$detail_file" 2>/dev/null)
                
                # Check if instance still exists and get current state
                local instance_state="UNKNOWN"
                local instance_display_name="$resource_name"
                local inst_state_color="$GRAY"
                
                if [[ "$resource_id" != "N/A" && -n "$resource_id" ]]; then
                    if [[ -n "${INSTANCE_LOOKUP[$resource_id]:-}" ]]; then
                        local lookup_info="${INSTANCE_LOOKUP[$resource_id]}"
                        instance_display_name=$(echo "$lookup_info" | cut -d'|' -f1)
                        instance_state=$(echo "$lookup_info" | cut -d'|' -f2)
                        
                        case "$instance_state" in
                            RUNNING) inst_state_color="$GREEN" ;;
                            STOPPED) inst_state_color="$RED" ;;
                            TERMINATED) inst_state_color="$RED" ;;
                            *) inst_state_color="$YELLOW" ;;
                        esac
                    else
                        instance_state="DELETED"
                        inst_state_color="$RED"
                        [[ "$instance_display_name" == "N/A" ]] && instance_display_name="(deleted)"
                    fi
                fi
                
                # Truncate display name and OCID
                local name_trunc="${instance_display_name:0:30}"
                local ocid_trunc="N/A"
                if [[ "$resource_id" != "N/A" && -n "$resource_id" ]]; then
                    ocid_trunc="...${resource_id: -39}"
                fi
                
                # Print row - only show announcement details on first row
                if [[ "$first_row" == "true" ]]; then
                    printf "${YELLOW}%-4s${NC} %-10s ${state_color}%-10s${NC} ${type_color}%-24s${NC} %-16s %-16s %-30s ${inst_state_color}%-14s${NC} %-42s ${GRAY}%-80s${NC}\n" \
                        "a${ann_idx}" "$ticket_display" "$lifecycle_state" "$ann_type" "$start_display" "$end_display" "$name_trunc" "$instance_state" "$ocid_trunc" "$desc_trunc"
                    first_row=false
                else
                    # Continuation row - empty announcement columns
                    printf "%-4s %-10s %-10s %-24s %-16s %-16s %-30s ${inst_state_color}%-14s${NC} %-42s %-80s\n" \
                        "" "" "" "" "" "" "$name_trunc" "$instance_state" "$ocid_trunc" ""
                fi
            done
        fi
    done
    
    echo ""
    print_separator 260
    echo ""
    echo -e "${WHITE}Processed ${CYAN}${ann_idx}${WHITE} announcement(s)${NC}"
    echo ""
    
    # Show legend
    echo -e "${BOLD}${WHITE}Legend:${NC}"
    echo -e "  ${WHITE}States:${NC} ${YELLOW}ACTIVE${NC} (current) | ${GRAY}INACTIVE${NC} (past)"
    echo -e "  ${WHITE}Types:${NC}  ${RED}ACTION_REQUIRED${NC} / ${RED}EMERGENCY_MAINTENANCE${NC} (urgent) | ${YELLOW}SCHEDULED_MAINTENANCE${NC} (planned) | ${CYAN}PRODUCTION_EVENT_NOTIFICATION${NC} (info)"
    echo -e "  ${WHITE}Instance:${NC} ${GREEN}RUNNING${NC} | ${RED}STOPPED${NC} | ${RED}DELETED${NC} (no longer exists)"
    echo ""
    
    # Interactive menu
    while true; do
        echo -e "${BOLD}${WHITE}─── Actions ───${NC}"
        echo -e "  Enter ${YELLOW}a#${NC} (e.g., a1) to view full announcement details and affected resources"
        echo -e "  Enter ${YELLOW}q${NC} to quit"
        echo ""
        echo -n -e "${CYAN}Selection: ${NC}"
        read -r selection
        
        [[ -z "$selection" || "$selection" == "q" || "$selection" == "Q" ]] && break
        
        if [[ "$selection" =~ ^a[0-9]+$ ]]; then
            local detail_file="${ANN_INDEX_MAP[$selection]:-}"
            if [[ -z "$detail_file" || ! -f "$detail_file" ]]; then
                echo -e "${RED}Invalid selection: $selection${NC}"
                continue
            fi
            
            # Extract full announcement details
            local ref_ticket lifecycle_state ann_type summary description
            local time_created time_updated time_one time_two
            local affected_services platform_type resource_count
            
            ref_ticket=$(jq -r '.data."reference-ticket-number" // "N/A"' "$detail_file")
            lifecycle_state=$(jq -r '.data."lifecycle-state" // "N/A"' "$detail_file")
            ann_type=$(jq -r '.data."announcement-type" // "N/A"' "$detail_file")
            summary=$(jq -r '.data.summary // "N/A"' "$detail_file")
            description=$(jq -r '.data.description // "N/A"' "$detail_file")
            time_created=$(jq -r '.data."time-created" // "N/A"' "$detail_file")
            time_updated=$(jq -r '.data."time-updated" // "N/A"' "$detail_file")
            time_one=$(jq -r '.data."time-one-value" // "N/A"' "$detail_file")
            time_two=$(jq -r '.data."time-two-value" // "N/A"' "$detail_file")
            affected_services=$(jq -r '.data."affected-services" // [] | join(", ")' "$detail_file")
            platform_type=$(jq -r '.data."platform-type" // "N/A"' "$detail_file")
            resource_count=$(jq '.data."affected-resources" | length' "$detail_file" 2>/dev/null) || resource_count=0
            
            echo ""
            echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}${YELLOW}  Announcement: ${WHITE}${ref_ticket}${NC}"
            echo -e "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo -e "  ${WHITE}Type:${NC}         $ann_type"
            echo -e "  ${WHITE}State:${NC}        $lifecycle_state"
            echo -e "  ${WHITE}Platform:${NC}     $platform_type"
            echo -e "  ${WHITE}Services:${NC}     $affected_services"
            echo -e "  ${WHITE}Created:${NC}      ${time_created:0:19}"
            [[ "$time_updated" != "N/A" && "$time_updated" != "null" ]] && echo -e "  ${WHITE}Updated:${NC}      ${time_updated:0:19}"
            [[ "$time_one" != "N/A" && "$time_one" != "null" ]] && echo -e "  ${WHITE}Start Time:${NC}   ${time_one:0:19}"
            [[ "$time_two" != "N/A" && "$time_two" != "null" ]] && echo -e "  ${WHITE}End Time:${NC}     ${time_two:0:19}"
            echo ""
            echo -e "  ${WHITE}Summary:${NC}"
            echo -e "    ${CYAN}$summary${NC}"
            echo ""
            if [[ "$description" != "N/A" && "$description" != "null" && -n "$description" ]]; then
                echo -e "  ${WHITE}Description:${NC}"
                echo "$description" | fold -s -w 100 | while IFS= read -r line; do
                    echo -e "    ${GRAY}${line}${NC}"
                done
            fi
            
            # Show affected resources
            if [[ $resource_count -gt 0 ]]; then
                echo ""
                echo -e "  ${WHITE}Affected Resources (${resource_count}):${NC}"
                echo -e "  ${GRAY}─────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
                printf "  ${BOLD}%-40s %-30s %-16s %-22s${NC}\n" "Instance OCID" "Display Name" "OCI State" "GPU Memory Cluster"
                echo -e "  ${GRAY}─────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
                
                local i
                for ((i=0; i<resource_count; i++)); do
                    local resource_id resource_name gpu_mem_cluster
                    
                    resource_id=$(jq -r ".data.\"affected-resources\"[$i] | 
                        if .properties then
                            (.properties[] | select(.name == \"resourceId\" or .name == \"instanceId\") | .value) // \"N/A\"
                        else
                            (.\"resource-id\" // .\"instance-id\" // \"N/A\")
                        end" "$detail_file" 2>/dev/null)
                    
                    resource_name=$(jq -r ".data.\"affected-resources\"[$i] |
                        if .properties then
                            (.properties[] | select(.name == \"resourceName\" or .name == \"instanceName\") | .value) // \"N/A\"
                        else
                            (.\"resource-name\" // .\"instance-name\" // \"N/A\")
                        end" "$detail_file" 2>/dev/null)
                    
                    gpu_mem_cluster=$(jq -r ".data.\"affected-resources\"[$i] |
                        if .properties then
                            (.properties[] | select(.name == \"gpuMemoryCluster\") | .value) // \"N/A\"
                        else
                            \"N/A\"
                        end" "$detail_file" 2>/dev/null)
                    
                    # Check if instance still exists
                    local instance_state="UNKNOWN"
                    local instance_display_name="$resource_name"
                    local state_color="$GRAY"
                    
                    if [[ "$resource_id" != "N/A" && -n "$resource_id" ]]; then
                        if [[ -n "${INSTANCE_LOOKUP[$resource_id]:-}" ]]; then
                            local lookup_info="${INSTANCE_LOOKUP[$resource_id]}"
                            instance_display_name=$(echo "$lookup_info" | cut -d'|' -f1)
                            instance_state=$(echo "$lookup_info" | cut -d'|' -f2)
                            
                            case "$instance_state" in
                                RUNNING) state_color="$GREEN" ;;
                                STOPPED) state_color="$RED" ;;
                                TERMINATED) state_color="$RED" ;;
                                *) state_color="$YELLOW" ;;
                            esac
                        else
                            instance_state="NO LONGER EXISTS"
                            state_color="$RED"
                            [[ "$instance_display_name" == "N/A" ]] && instance_display_name="(deleted)"
                        fi
                    fi
                    
                    # Truncate OCID for display
                    local ocid_display="N/A"
                    if [[ "$resource_id" != "N/A" && -n "$resource_id" ]]; then
                        ocid_display="...${resource_id: -37}"
                    fi
                    
                    # Truncate GPU memory cluster
                    local gpu_display="N/A"
                    if [[ "$gpu_mem_cluster" != "N/A" && -n "$gpu_mem_cluster" ]]; then
                        gpu_display="...${gpu_mem_cluster: -19}"
                    fi
                    
                    printf "  %-40s %-30s ${state_color}%-16s${NC} %-22s\n" \
                        "$ocid_display" "${instance_display_name:0:30}" "$instance_state" "$gpu_display"
                done
            else
                echo ""
                echo -e "  ${GRAY}No specific resources listed for this announcement${NC}"
            fi
            echo ""
        else
            echo -e "${RED}Invalid selection. Use a# (e.g., a1) for announcement details.${NC}"
        fi
    done
}

# Display summary by clique
display_clique_summary() {
    local oci_temp="$1"
    local k8s_temp="$2"
    
    local joined_temp
    joined_temp=$(create_temp_file) || return 1
    
    # Debug: Check file contents
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${GRAY}[DEBUG] oci_temp has $(wc -l < "$oci_temp") lines${NC}" >&2
        echo -e "${GRAY}[DEBUG] k8s_temp has $(wc -l < "$k8s_temp") lines${NC}" >&2
        if [[ -f "$INSTANCE_CLUSTER_MAP_CACHE" ]]; then
            local map_count
            map_count=$(grep -v '^#' "$INSTANCE_CLUSTER_MAP_CACHE" 2>/dev/null | wc -l)
            echo -e "${GRAY}[DEBUG] Instance-to-cluster map has $map_count entries${NC}" >&2
        else
            echo -e "${GRAY}[DEBUG] Instance-to-cluster map cache NOT FOUND at $INSTANCE_CLUSTER_MAP_CACHE${NC}" >&2
        fi
    fi
    
    # APPROACH:
    # 1. Start from Instance-Cluster Map (instances in GPU memory clusters via API)
    # 2. For each instance, check if it's in K8s (k8s_temp)
    # 3. If in K8s, get the clique label
    # 4. Group by GPU Memory Cluster (not clique)
    
    local k8s_found=0 k8s_not_found=0
    local total_unhealthy=0
    
    # Process instances from the instance-cluster map cache
    # Format: InstanceOCID|ClusterOCID|ClusterDisplayName
    if [[ -f "$INSTANCE_CLUSTER_MAP_CACHE" ]]; then
        while IFS='|' read -r instance_ocid gpu_cluster_ocid cluster_name; do
            # Skip header lines
            [[ "$instance_ocid" == \#* ]] && continue
            [[ -z "$instance_ocid" ]] && continue
            
            # Get instance display name from oci_temp
            # oci_temp format: display_name|status|instance_ocid|gpu_mem_tag|shape|time_created
            local oci_line display_name status
            oci_line=$(grep "|${instance_ocid}|" "$oci_temp" 2>/dev/null | head -1)
            if [[ -n "$oci_line" ]]; then
                IFS='|' read -r display_name status _ _ _ _ <<< "$oci_line"
            else
                # Instance not in oci_temp (maybe filtered out or different compartment)
                display_name="(unknown)"
                status="UNKNOWN"
            fi
            
            # Check for unhealthy instances (DEGRADED cap_topo or has announcements)
            local cap_topo_state announcements
            cap_topo_state=$(get_capacity_topology_state "$instance_ocid" 2>/dev/null)
            announcements=$(get_resource_announcements "$instance_ocid" "$gpu_cluster_ocid" 2>/dev/null)
            if [[ "$cap_topo_state" == "DEGRADED" || ( -n "$announcements" && "$announcements" != "-" ) ]]; then
                ((total_unhealthy++))
            fi
            
            # Check if instance is in K8s
            # k8s_temp format: providerID|nodeName|clique|gpuPresent
            local k8s_info
            k8s_info=$(grep "$instance_ocid" "$k8s_temp" 2>/dev/null)
            
            if [[ -n "$k8s_info" ]]; then
                ((k8s_found++))
                local node_name clique_id
                IFS='|' read -r _ node_name clique_id _ <<< "$k8s_info"
                
                # Use K8s clique if available, otherwise mark as no clique
                if [[ -n "$clique_id" && "$clique_id" != "N/A" ]]; then
                    # joined format: display_name|node_name|status|instance_ocid|gpu_cluster_ocid|clique_id|in_k8s
                    echo "${display_name}|${node_name}|${status}|${instance_ocid}|${gpu_cluster_ocid}|${clique_id}|YES" >> "$joined_temp"
                else
                    # In K8s but no clique label
                    echo "${display_name}|${node_name}|${status}|${instance_ocid}|${gpu_cluster_ocid}|N/A|YES" >> "$joined_temp"
                fi
            else
                ((k8s_not_found++))
                # Instance is in GPU memory cluster but NOT in K8s
                echo "${display_name}|-|${status}|${instance_ocid}|${gpu_cluster_ocid}|N/A|NO" >> "$joined_temp"
            fi
        done < "$INSTANCE_CLUSTER_MAP_CACHE"
    else
        log_warn "Instance-cluster map cache not found. Run with --refresh to build cache."
    fi
    
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${GRAY}[DEBUG] Total from GPU clusters: K8s found=$k8s_found, NOT_IN_K8S=$k8s_not_found${NC}" >&2
        echo -e "${GRAY}[DEBUG] joined_temp has $(wc -l < "$joined_temp") lines${NC}" >&2
    fi
    
    echo -e "${BOLD}${BLUE}=== Summary by GPU Memory Cluster ===${NC}"
    echo ""
    
    local summary_temp
    summary_temp=$(create_temp_file) || { rm -f "$joined_temp"; return 1; }
    
    # Get unique GPU Memory Clusters (field 5)
    local unique_clusters
    unique_clusters=$(awk -F'|' '{print $5}' "$joined_temp" 2>/dev/null | sort -u)
    
    # Also add clusters from cache that have no instances yet
    if [[ -f "$CLUSTER_CACHE" ]]; then
        while IFS='|' read -r cluster_ocid cluster_name cluster_state _; do
            [[ "$cluster_ocid" =~ ^#.*$ ]] && continue
            [[ -z "$cluster_ocid" ]] && continue
            # Only include active-ish states
            [[ "$cluster_state" != "ACTIVE" && "$cluster_state" != "UPDATING" && "$cluster_state" != "SCALING" && "$cluster_state" != "CREATING" ]] && continue
            # Add if not already in list
            if ! echo "$unique_clusters" | grep -q "^${cluster_ocid}$"; then
                unique_clusters="${unique_clusters}"$'\n'"${cluster_ocid}"
            fi
        done < <(grep -v '^#' "$CLUSTER_CACHE" 2>/dev/null)
    fi
    
    # Process each GPU Memory Cluster
    local gpu_cluster_ocid
    while read -r gpu_cluster_ocid; do
        [[ -z "$gpu_cluster_ocid" ]] && continue
        
        # Get cluster info from cache
        local cluster_name cluster_state cluster_size instance_config_id compute_cluster_id
        local cluster_line
        cluster_line=$(grep "^${gpu_cluster_ocid}|" "$CLUSTER_CACHE" 2>/dev/null | head -1)
        
        if [[ -n "$cluster_line" ]]; then
            # CLUSTER_CACHE format: ClusterOCID|DisplayName|State|FabricSuffix|InstanceConfigID|ComputeClusterID|Size
            IFS='|' read -r _ cluster_name cluster_state _ instance_config_id compute_cluster_id cluster_size <<< "$cluster_line"
        else
            cluster_name="(unknown)"
            cluster_state="UNKNOWN"
            cluster_size="0"
            instance_config_id="N/A"
            compute_cluster_id="N/A"
        fi
        
        # Get fabric info
        local fabric_info fabric_name fabric_ocid healthy_hosts available_hosts total_hosts current_firmware target_firmware firmware_update_state
        fabric_info=$(get_fabric_from_cluster "$gpu_cluster_ocid")
        IFS='|' read -r fabric_name _ fabric_ocid _ healthy_hosts available_hosts total_hosts current_firmware target_firmware firmware_update_state <<< "$fabric_info"
        
        # Count instances in this cluster
        local cluster_entries total_instances in_k8s_count not_in_k8s_count
        cluster_entries=$(grep "|${gpu_cluster_ocid}|" "$joined_temp" 2>/dev/null)
        total_instances=$(echo "$cluster_entries" | grep -c . 2>/dev/null) || total_instances=0
        in_k8s_count=$(echo "$cluster_entries" | grep -c "|YES$" 2>/dev/null) || in_k8s_count=0
        not_in_k8s_count=$(echo "$cluster_entries" | grep -c "|NO$" 2>/dev/null) || not_in_k8s_count=0
        
        # Get unique cliques in this cluster
        local cliques_list
        cliques_list=$(echo "$cluster_entries" | awk -F'|' '$7=="YES" && $6!="N/A" {print $6}' | sort -u | tr '\n' ',' | sed 's/,$//')
        [[ -z "$cliques_list" ]] && cliques_list="-"
        
        # Format: cluster_name|gpu_cluster_ocid|cluster_state|cluster_size|in_k8s_count|not_in_k8s_count|cliques_list|fabric_name|fabric_ocid|instance_config_id|compute_cluster_id|healthy_hosts|available_hosts|total_hosts|current_firmware|target_firmware|firmware_update_state
        echo "${cluster_name}|${gpu_cluster_ocid}|${cluster_state}|${cluster_size}|${in_k8s_count}|${not_in_k8s_count}|${cliques_list}|${fabric_name}|${fabric_ocid}|${instance_config_id}|${compute_cluster_id}|${healthy_hosts}|${available_hosts}|${total_hosts}|${current_firmware}|${target_firmware}|${firmware_update_state}" >> "$summary_temp"
    done <<< "$unique_clusters"
    
    # Check if we have any data
    if [[ ! -s "$summary_temp" ]]; then
        echo -e "${YELLOW}No GPU Memory Clusters found.${NC}"
        rm -f "$joined_temp" "$summary_temp"
        return 0
    fi
    
    # Print summary table header - matching old format
    printf "${BOLD}%44s K8s  ┌─GPU Memory Fabric─┐ GPU Mem Cluster${NC}\n" ""
    printf "${BOLD}%-30s %-12s %5s  %7s %5s %5s       %4s       %-12s${NC}\n" \
        "GPU Memory Cluster" "State" "Nodes" "Healthy" "Avail" "Total" "Size" ""
    print_separator 110
    
    # Sort summary by cluster name
    local sorted_summary
    sorted_summary=$(sort -t'|' -k1,1 "$summary_temp")
    
    # Calculate totals
    local total_size=0 total_in_k8s=0 total_not_in_k8s=0
    local total_healthy=0 total_avail=0 total_hosts_sum=0
    local total_in_hops=0
    # Track unique fabrics to avoid double counting
    declare -A seen_fabrics
    
    # Get HoPS count from capacity topology (UNAVAILABLE state in lifecycle-details)
    if [[ -f "$CAPACITY_TOPOLOGY_CACHE" ]]; then
        total_in_hops=$(grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | awk -F'|' '$3 == "UNAVAILABLE"' | wc -l)
    fi
    
    while IFS='|' read -r cluster_name gpu_cluster_ocid cluster_state cluster_size in_k8s_count not_in_k8s_count cliques_list fabric_name fabric_ocid instance_config_id compute_cluster_id healthy_hosts available_hosts total_hosts current_firmware target_firmware firmware_update_state; do
        [[ -z "$cluster_name" ]] && continue
        
        # Add to totals
        [[ "$cluster_size" =~ ^[0-9]+$ ]] && total_size=$((total_size + cluster_size))
        [[ "$in_k8s_count" =~ ^[0-9]+$ ]] && total_in_k8s=$((total_in_k8s + in_k8s_count))
        [[ "$not_in_k8s_count" =~ ^[0-9]+$ ]] && total_not_in_k8s=$((total_not_in_k8s + not_in_k8s_count))
        
        # Add fabric totals (only count each fabric once)
        if [[ -n "$fabric_ocid" && "$fabric_ocid" != "N/A" && -z "${seen_fabrics[$fabric_ocid]:-}" ]]; then
            seen_fabrics[$fabric_ocid]=1
            [[ "$healthy_hosts" =~ ^[0-9]+$ ]] && total_healthy=$((total_healthy + healthy_hosts))
            [[ "$available_hosts" =~ ^[0-9]+$ ]] && total_avail=$((total_avail + available_hosts))
            [[ "$total_hosts" =~ ^[0-9]+$ ]] && total_hosts_sum=$((total_hosts_sum + total_hosts))
        fi
        
        # Color state based on value
        local state_color
        state_color=$(color_cluster_state "$cluster_state")
        
        # Color available hosts - light green if not 0
        local avail_color="$WHITE"
        [[ "$available_hosts" != "0" && "$available_hosts" != "N/A" ]] && avail_color="$LIGHT_GREEN"
        
        # Color not_in_k8s - yellow if > 0 (nodes not in k8s)
        local in_k8s_color="$GREEN"
        [[ "$not_in_k8s_count" -gt 0 ]] && in_k8s_color="$YELLOW"
        
        # Truncate cluster name if needed
        local cluster_name_display="${cluster_name:0:28}"
        
        # Main summary line - K8s Nodes shows "in_k8s/total" format if there are nodes not in k8s
        local k8s_display="$in_k8s_count"
        if [[ "$not_in_k8s_count" -gt 0 ]]; then
            k8s_display="${in_k8s_count}/${cluster_size}"
        fi
        
        printf "${MAGENTA}%-30s${NC} ${state_color}%-12s${NC} ${in_k8s_color}%5s${NC}  ${WHITE}%7s${NC} ${avail_color}%5s${NC} ${WHITE}%5s${NC}       ${WHITE}%4s${NC}\n" \
            "$cluster_name_display" "$cluster_state" "$k8s_display" "$healthy_hosts" "$available_hosts" "$total_hosts" "$cluster_size"
        
        # Determine which is the last item for tree drawing
        local has_cliques=false has_fabric=false has_compute=false has_config=false has_firmware=false
        [[ "$cliques_list" != "-" && -n "$cliques_list" ]] && has_cliques=true
        [[ "$fabric_name" != "N/A" && -n "$fabric_name" ]] && has_fabric=true
        is_valid_ocid "$compute_cluster_id" && has_compute=true
        is_valid_ocid "$instance_config_id" && has_config=true
        [[ "$current_firmware" != "N/A" && -n "$current_firmware" ]] && has_firmware=true
        
        # Tree view - all items including OCID and Cliques
        # Cliques (first in tree)
        if [[ "$has_cliques" == true ]]; then
            local tree_char="├"
            [[ "$has_fabric" == false && "$has_compute" == false && "$has_config" == false && "$has_firmware" == false ]] && tree_char="└"
            printf "  ${WHITE}%s─${NC} ${BOLD}${CYAN}Cliques:${NC}      ${CYAN}%s${NC}\n" "$tree_char" "$cliques_list"
        fi
        
        # GPU Memory Cluster OCID (aligned with other OCIDs)
        local tree_char="├"
        [[ "$has_fabric" == false && "$has_compute" == false && "$has_config" == false && "$has_firmware" == false ]] && tree_char="└"
        printf "  ${WHITE}%s─${NC} ${BOLD}${MAGENTA}GPU Cluster:${NC}  %-45s ${YELLOW}%s${NC}\n" "$tree_char" "${cluster_name:0:45}" "$gpu_cluster_ocid"
        
        # Fabric
        if [[ "$has_fabric" == true ]]; then
            tree_char="├"
            [[ "$has_compute" == false && "$has_config" == false && "$has_firmware" == false ]] && tree_char="└"
            printf "  ${WHITE}%s─${NC} ${BOLD}${ORANGE}Fabric:${NC}       %-45s ${YELLOW}%s${NC}\n" \
                "$tree_char" "${fabric_name:0:45}" "$fabric_ocid"
        fi
        
        # Compute Cluster
        if [[ "$has_compute" == true ]]; then
            local compute_cluster_name
            compute_cluster_name=$(get_compute_cluster_name "$compute_cluster_id")
            tree_char="├"
            [[ "$has_config" == false && "$has_firmware" == false ]] && tree_char="└"
            printf "  ${WHITE}%s─${NC} ${BOLD}${BLUE}Compute:${NC}      %-45s ${YELLOW}%s${NC}\n" \
                "$tree_char" "${compute_cluster_name:0:45}" "$compute_cluster_id"
        fi
        
        # Instance Config
        if [[ "$has_config" == true ]]; then
            local instance_config_name
            instance_config_name=$(get_instance_config_name "$instance_config_id")
            tree_char="├"
            [[ "$has_firmware" == false ]] && tree_char="└"
            printf "  ${WHITE}%s─${NC} ${BOLD}${GREEN}Inst Config:${NC}  %-45s ${YELLOW}%s${NC}\n" \
                "$tree_char" "${instance_config_name:0:45}" "$instance_config_id"
        fi
        
        # Firmware (always last if present)
        if [[ "$has_firmware" == true ]]; then
            # Get last 5 chars of firmware versions
            local current_short="${current_firmware: -5}"
            local target_short="${target_firmware: -5}"
            
            # Color firmware update state
            local update_state_color
            update_state_color=$(color_firmware_state "$firmware_update_state")
            
            # Highlight target in red if current != target
            local target_color="$YELLOW"
            if [[ "$current_firmware" != "$target_firmware" && "$target_firmware" != "N/A" && -n "$target_firmware" ]]; then
                target_color="$RED"
            fi
            
            printf "  ${WHITE}└─${NC} ${BOLD}${ORANGE}Firmware:${NC}     ${update_state_color}%-14s${NC} current: ${YELLOW}%-8s${NC} target: ${target_color}%s${NC}\n" \
                "$firmware_update_state" "$current_short" "$target_short"
        fi
        
        echo ""
    done <<< "$sorted_summary"
    
    # Print totals
    print_separator 110
    printf "${BOLD}${WHITE}%-30s %-12s %5s  %7s %5s %5s       %4s${NC}\n" \
        "TOTALS" "" "$total_in_k8s" "$total_healthy" "$total_avail" "$total_hosts_sum" "$total_size"
    echo ""
    echo -e "${GRAY}  Total GPU Memory Cluster Size: ${WHITE}$total_size${NC}"
    echo -e "${GRAY}    ├─ Total Instances in K8s:        ${GREEN}$total_in_k8s${NC}"
    echo -e "${GRAY}    └─ Total Instances NOT in K8s:    ${RED}$total_not_in_k8s${NC}"
    echo -e "${GRAY}  Total Fabric Available Hosts:  ${LIGHT_GREEN}$total_avail${NC}"
    echo ""
    echo -e "${GRAY}  Total Fabric Hosts:            ${WHITE}$total_hosts_sum${NC}"
    echo -e "${GRAY}    ├─ Total Fabric Healthy Hosts:    ${WHITE}$total_healthy${NC}"
    echo -e "${GRAY}    ├─ Total Unhealthy Instances:     ${RED}$total_unhealthy${NC}  ${GRAY}(DEGRADED or has Announcement)${NC}"
    echo -e "${GRAY}    └─ Total Instances in HoPS:       ${YELLOW}$total_in_hops${NC}  ${GRAY}(UNAVAILABLE in Capacity Topology)${NC}"
    echo ""
    
    # Show fabrics without GPU Memory Clusters
    if [[ -f "$FABRIC_CACHE" ]]; then
        local unused_fabrics_temp
        unused_fabrics_temp=$(create_temp_file) || { rm -f "$joined_temp" "$summary_temp"; return 1; }
        local unused_healthy=0 unused_avail=0 unused_total=0
        
        # Find fabrics not referenced by any cluster
        # FABRIC_CACHE format: DisplayName|Last5Chars|FabricOCID|State|HealthyHosts|AvailableHosts|TotalHosts|CurrentFirmware|TargetFirmware|FirmwareUpdateState
        while IFS='|' read -r fabric_name last5 fabric_ocid fabric_state healthy avail total current_fw target_fw fw_state; do
            [[ "$fabric_name" =~ ^#.*$ ]] && continue
            [[ -z "$fabric_ocid" ]] && continue
            
            # Check if this fabric is used by any cluster (check if it's in seen_fabrics)
            if [[ -z "${seen_fabrics[$fabric_ocid]:-}" ]]; then
                echo "${fabric_name}|${fabric_ocid}|${fabric_state}|${healthy}|${avail}|${total}|${current_fw}|${target_fw}|${fw_state}" >> "$unused_fabrics_temp"
                [[ "$healthy" =~ ^[0-9]+$ ]] && unused_healthy=$((unused_healthy + healthy))
                [[ "$avail" =~ ^[0-9]+$ ]] && unused_avail=$((unused_avail + avail))
                [[ "$total" =~ ^[0-9]+$ ]] && unused_total=$((unused_total + total))
            fi
        done < <(grep -v '^#' "$FABRIC_CACHE" 2>/dev/null)
        
        if [[ -s "$unused_fabrics_temp" ]]; then
            echo ""
            echo -e "${BOLD}${MAGENTA}=== GPU Memory Fabrics Without Clusters ===${NC}"
            echo ""
            printf "${BOLD}%-48s ┌─ GPU Memory Fabric ─┐${NC}\n" ""
            printf "${BOLD}%-48s %8s %6s %6s    %-12s${NC}\n" \
                "Fabric Display Name" "Healthy" "Avail" "Total" "State"
            print_separator 106
            
            while IFS='|' read -r fabric_name fabric_ocid fabric_state healthy avail total current_fw target_fw fw_state; do
                [[ -z "$fabric_name" ]] && continue
                
                local state_color avail_color
                state_color=$(color_fabric_state "$fabric_state")
                avail_color="$WHITE"
                [[ "$avail" != "0" && "$avail" != "N/A" ]] && avail_color="$LIGHT_GREEN"
                
                printf "${CYAN}%-48s${NC} ${WHITE}%8s${NC} ${avail_color}%6s${NC} ${WHITE}%6s${NC}    ${state_color}%-12s${NC}\n" \
                    "$fabric_name" "$healthy" "$avail" "$total" "$fabric_state"
                printf "          ${WHITE}├─${NC} ${BOLD}${ORANGE}%-18s${NC} ${WHITE}%-44s${NC} ${WHITE}(${YELLOW}%s${WHITE})${NC}\n" \
                    "Fabric:" "$fabric_name" "$fabric_ocid"
                
                # Firmware
                if [[ "$current_fw" != "N/A" && -n "$current_fw" ]]; then
                    local current_short="${current_fw: -5}"
                    local target_short="${target_fw: -5}"
                    local firmware_color="$WHITE"
                    [[ "$current_fw" != "$target_fw" && "$target_fw" != "N/A" ]] && firmware_color="$RED"
                    
                    local update_state_color
                    update_state_color=$(color_firmware_state "$fw_state")
                    
                    printf "          ${WHITE}└─${NC} ${BOLD}${ORANGE}Firmware:${NC} ${update_state_color}%-12s${NC} ${firmware_color}current: %-10s target: %-10s${NC}\n" \
                        "$fw_state" "$current_short" "$target_short"
                fi
                echo ""
            done < "$unused_fabrics_temp"
            
            print_separator 106
            printf "${BOLD}${WHITE}%-48s %8s %6s %6s${NC}\n" \
                "TOTALS (Unused Fabrics)" "$unused_healthy" "$unused_avail" "$unused_total"
            echo ""
        fi
        
        rm -f "$unused_fabrics_temp"
    fi
    
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
        # Use contains() because providerID format is "oci://ocid1.instance..." not just the OCID
        node_name=$(echo "$node_json" | jq -r --arg id "$instance_id" '.items[] | select(.spec.providerID | contains($id)) | .metadata.name')
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
    # Get all instances for general info
    local all_instances_json
    all_instances_json=$(create_temp_file) || { rm -f "$oci_data" "$k8s_data"; return 1; }
    
    oci compute instance list \
        --compartment-id "$compartment_id" \
        --region "$region" \
        --all \
        --output json 2>/dev/null > "$all_instances_json"
    
    # Get instances belonging to this GPU cluster via API (not freeform tag)
    log_info "Fetching instances in GPU cluster via API..."
    local cluster_instances_json
    cluster_instances_json=$(create_temp_file) || { rm -f "$oci_data" "$k8s_data" "$all_instances_json"; return 1; }
    
    oci compute compute-gpu-memory-cluster-instance-summary list-compute-gpu-memory-cluster-instances \
        --compute-gpu-memory-cluster-id "$gpu_cluster" \
        --all \
        --output json 2>/dev/null > "$cluster_instances_json"
    
    # Extract instance IDs from the cluster
    local cluster_instance_ids
    cluster_instance_ids=$(jq -r '(.data.items // .data // [])[] | .["instance-id"] // .id' "$cluster_instances_json" 2>/dev/null)
    
    # Build oci_data with only instances in this cluster
    for inst_id in $cluster_instance_ids; do
        [[ -z "$inst_id" ]] && continue
        jq -r --arg id "$inst_id" '
            .data[] | select(.id == $id) | 
            "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["freeform-tags"]["oci:compute:gpumemorycluster"] // "N/A")"
        ' "$all_instances_json" >> "$oci_data" 2>/dev/null
    done
    
    rm -f "$all_instances_json" "$cluster_instances_json"
    
    log_info "Fetching Kubernetes node data..."
    # Fetch ALL nodes to avoid missing nodes without GPU labels yet
    kubectl get nodes -o json 2>/dev/null | jq -r '
        .items[] | 
        "\(.spec.providerID)|\(.metadata.name)|\(.metadata.labels["nvidia.com/gpu.clique"] // "N/A")"
    ' > "$k8s_data"
    
    echo ""
    
    # Print table header with spanning headers
    # Column positions: DisplayName(28) Node(15) State(7) CliqueID(43) State(11) OCID(95) Name(12) State(10) State(10) Announce(18)
    printf "${BOLD}%-28s%-66s%-107s%-23s%-11s%-11s${NC}\n" \
    "" \
    "┌──────────────────────────── K8s ────────────────────────────┐" \
    "┌──────────────────────────────────── OCI Instance ──────────────────────────────────────┐" \
    "┌─ GPU Mem Cluster ─┐" \
    "CapTopo" \
    "Maintenance"
    printf "${BOLD}%-28s %-15s %-7s %-43s %-11s %-95s %-12s %-10s %-10s %-18s${NC}\n" \
        "Display Name" "Node" "State" "Clique ID" "State" "Instance OCID" "Name" "State" "State" "Announce"
    print_separator 280
    
    # Process instances in this cluster (oci_data now contains only instances in the cluster)
    local instance_id display_name oci_state gpu_mem_tag
    local instances_shown=0
    local instances_in_k8s=0
    while IFS='|' read -r instance_id display_name oci_state gpu_mem_tag; do
        [[ -z "$instance_id" ]] && continue
        ((instances_shown++))
        
        local k8s_info
        # k8s_data format: providerID|nodeName|clique
        k8s_info=$(grep "$instance_id" "$k8s_data" 2>/dev/null)
        
        local node_name clique_id node_state
        if [[ -n "$k8s_info" ]]; then
            ((instances_in_k8s++))
            IFS='|' read -r _ node_name clique_id <<< "$k8s_info"
            node_state=$(get_node_state_cached "$instance_id")
        else
            node_name="-"
            clique_id="-"
            node_state="-"
        fi
        
        # Get GPU memory cluster name
        local gpu_mem_name
        gpu_mem_name=$(get_cluster_name_from_id "$gpu_cluster" 2>/dev/null)
        [[ -z "$gpu_mem_name" || "$gpu_mem_name" == "N/A" ]] && gpu_mem_name="-"
        
        # Get GPU memory cluster state
        local gpu_mem_state
        gpu_mem_state=$(get_cluster_state "$gpu_cluster" 2>/dev/null)
        [[ -z "$gpu_mem_state" || "$gpu_mem_state" == "N/A" ]] && gpu_mem_state="-"
        
        local cap_topo_state announcements
        cap_topo_state=$(get_capacity_topology_state "$instance_id")
        announcements=$(get_resource_announcements "$instance_id" "$gpu_cluster")
        
        # Get colors
        local ns_color st_color ct_color ann_color gmc_color
        ns_color=$(color_node_state "$node_state")
        st_color=$(color_oci_state "$oci_state")
        ct_color=$(color_cap_topo_state "$cap_topo_state")
        ann_color=$(color_announcement "$announcements")
        gmc_color=$(color_cluster_state "$gpu_mem_state")
        
        printf "%-28s %-15s ${ns_color}%-7s${NC} %-43s ${st_color}%-11s${NC} %-95s %-12s ${gmc_color}%-10s${NC} ${ct_color}%-10s${NC} ${ann_color}%-18s${NC}\n" \
            "${display_name:0:27}" "${node_name:0:14}" "$node_state" "${clique_id:0:42}" "$oci_state" "$instance_id" "${gpu_mem_name:0:11}" "$gpu_mem_state" "$cap_topo_state" "$announcements"
    done < "$oci_data"
    
    echo ""
    
    echo -e "${CYAN}Total Instances:${NC} $instances_shown (${instances_in_k8s} in Kubernetes)"
    
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
        echo -e "  ${GREEN}8${NC}) ${WHITE}NVIDIA GPU Stack Health${NC}       - Check GPU Operator & DRA components per node"
        echo -e "  ${GREEN}9${NC}) ${WHITE}Resource Manager Stacks${NC}       - View stacks, jobs, logs, outputs, and state"
        echo -e "  ${GREEN}10${NC}) ${WHITE}Work Requests${NC}                - View work requests, status, errors, and logs"
        echo -e "  ${GREEN}11${NC}) ${WHITE}File Storage (FSS)${NC}           - Manage file systems, mount targets, and exports"
        echo -e "  ${GREEN}12${NC}) ${WHITE}Lustre File Systems${NC}          - Manage Lustre file systems and Object Storage links"
        echo -e "  ${GREEN}13${NC}) ${WHITE}Capacity Topology${NC}            - View host lifecycle states and details summary"
        echo ""
        echo -e "  ${CYAN}c${NC}) ${WHITE}Cache Stats${NC}                   - View cache status, age, and refresh options"
        echo -e "  ${RED}q${NC}) ${WHITE}Quit${NC}"
        echo ""
        echo -n -e "${BOLD}${CYAN}Enter selection [1-13, c, q]: ${NC}"
        
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
            8)
                manage_nvidia_gpu_stack_health
                ;;
            9)
                manage_resource_manager_stacks
                ;;
            10)
                manage_work_requests
                ;;
            11)
                manage_file_storage
                ;;
            12)
                manage_lustre_file_systems
                ;;
            13)
                manage_capacity_topology
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
                echo -e "${RED}Invalid selection. Please enter 1-12, c, or q.${NC}"
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
            rm -f "$FABRIC_CACHE" "$CLUSTER_CACHE" "$INSTANCE_CLUSTER_MAP_CACHE" "$COMPUTE_CLUSTER_CACHE"
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
    
    # Helm Deployments
    echo ""
    echo -e "${BOLD}${WHITE}═══ Helm Deployments (GPU) ═══${NC}"
    echo ""
    
    local helm_available=false
    if command -v helm &>/dev/null && command -v kubectl &>/dev/null; then
        helm_available=true
    fi
    
    if [[ "$helm_available" == "true" ]]; then
        printf "${BOLD}%-25s %-25s %-10s %-40s %-12s %-15s${NC}\n" \
            "Release Name" "Namespace" "Revision" "Updated" "Status" "Chart"
        printf "${WHITE}%-25s %-25s %-10s %-40s %-12s %-15s${NC}\n" \
            "-------------------------" "-------------------------" "----------" "----------------------------------------" "------------" "---------------"
        
        local found_helm_releases=false
        
        # Check gpu-operator namespace
        local gpu_op_json
        gpu_op_json=$(helm list -n gpu-operator -o json 2>/dev/null)
        if [[ -n "$gpu_op_json" && "$gpu_op_json" != "[]" ]]; then
            echo "$gpu_op_json" | jq -r '.[] | [.name, .namespace, (.revision | tostring), .updated, .status, .chart] | @tsv' 2>/dev/null | while IFS=$'\t' read -r name ns rev updated status chart; do
                local status_color="$GREEN"
                [[ "$status" != "deployed" ]] && status_color="$YELLOW"
                [[ "$status" == "failed" ]] && status_color="$RED"
                # Truncate updated timestamp
                local updated_trunc="${updated:0:40}"
                printf "%-25s %-25s %-10s %-40s ${status_color}%-12s${NC} %-15s\n" \
                    "${name:0:25}" "${ns:0:25}" "$rev" "$updated_trunc" "$status" "${chart:0:15}"
            done
            found_helm_releases=true
        fi
        
        # Check nvidia-dra-driver-gpu namespace
        local dra_json
        dra_json=$(helm list -n nvidia-dra-driver-gpu -o json 2>/dev/null)
        if [[ -n "$dra_json" && "$dra_json" != "[]" ]]; then
            echo "$dra_json" | jq -r '.[] | [.name, .namespace, (.revision | tostring), .updated, .status, .chart] | @tsv' 2>/dev/null | while IFS=$'\t' read -r name ns rev updated status chart; do
                local status_color="$GREEN"
                [[ "$status" != "deployed" ]] && status_color="$YELLOW"
                [[ "$status" == "failed" ]] && status_color="$RED"
                # Truncate updated timestamp
                local updated_trunc="${updated:0:40}"
                printf "%-25s %-25s %-10s %-40s ${status_color}%-12s${NC} %-15s\n" \
                    "${name:0:25}" "${ns:0:25}" "$rev" "$updated_trunc" "$status" "${chart:0:15}"
            done
            found_helm_releases=true
        fi
        
        # Check network-operator namespace (common for RDMA/networking)
        local netop_json
        netop_json=$(helm list -n network-operator -o json 2>/dev/null)
        if [[ -n "$netop_json" && "$netop_json" != "[]" ]]; then
            echo "$netop_json" | jq -r '.[] | [.name, .namespace, (.revision | tostring), .updated, .status, .chart] | @tsv' 2>/dev/null | while IFS=$'\t' read -r name ns rev updated status chart; do
                local status_color="$GREEN"
                [[ "$status" != "deployed" ]] && status_color="$YELLOW"
                [[ "$status" == "failed" ]] && status_color="$RED"
                local updated_trunc="${updated:0:40}"
                printf "%-25s %-25s %-10s %-40s ${status_color}%-12s${NC} %-15s\n" \
                    "${name:0:25}" "${ns:0:25}" "$rev" "$updated_trunc" "$status" "${chart:0:15}"
            done
            found_helm_releases=true
        fi
        
        if [[ "$found_helm_releases" == "false" ]]; then
            echo -e "${GRAY}No GPU-related helm releases found in gpu-operator, nvidia-dra-driver-gpu, or network-operator namespaces${NC}"
        fi
    else
        echo -e "${YELLOW}helm and/or kubectl not available - cannot check helm deployments${NC}"
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
                    # Check if this is a DRG OCID or a DRG Attachment OCID
                    if [[ "$gw_ocid" == ocid1.drg.* ]]; then
                        # This is a DRG OCID - get DRG details directly
                        local drg_json
                        drg_json=$(oci network drg get --drg-id "$gw_ocid" --output json 2>/dev/null)
                        if [[ -n "$drg_json" ]]; then
                            local gw_name gw_state gw_created gw_compartment
                            gw_name=$(echo "$drg_json" | jq -r '.data["display-name"] // "N/A"')
                            gw_state=$(echo "$drg_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                            gw_created=$(echo "$drg_json" | jq -r '.data["time-created"] // "N/A"')
                            gw_compartment=$(echo "$drg_json" | jq -r '.data["compartment-id"] // "N/A"')
                            
                            echo -e "${WHITE}Name:${NC} ${ORANGE}$gw_name${NC}"
                            echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                            echo ""
                            echo "State:                 $gw_state"
                            echo "Compartment:           $gw_compartment"
                            echo "Time Created:          $gw_created"
                            
                            # List DRG attachments for this DRG
                            echo ""
                            echo -e "${BOLD}${WHITE}DRG Attachments:${NC}"
                            local attachments
                            attachments=$(oci network drg-attachment list --drg-id "$gw_ocid" --all --output json 2>/dev/null)
                            if [[ -n "$attachments" ]]; then
                                local att_count
                                att_count=$(echo "$attachments" | jq '.data | length')
                                if [[ "$att_count" -gt 0 ]]; then
                                    echo "$attachments" | jq -r '.data[] | "  - \(.["display-name"] // "N/A") (\(.["attachment-type"] // "N/A")) - \(.["lifecycle-state"] // "N/A")"'
                                else
                                    echo -e "  ${GRAY}No attachments found${NC}"
                                fi
                            else
                                echo -e "  ${GRAY}Unable to fetch attachments${NC}"
                            fi
                        else
                            echo -e "${WHITE}OCID:${NC} ${YELLOW}$gw_ocid${NC}"
                            echo ""
                            echo -e "${RED}Failed to fetch DRG details${NC}"
                        fi
                    else
                        # This is a DRG Attachment OCID
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
        rm -f ${TEMP_DIR}/instance_map_$$
        
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
        printf "${BOLD}%-5s %-32s %-10s %-8s %-8s %-10s %-5s %-24s %-12s %-16s %s${NC}\n" \
            "ID" "Display Name" "State" "K8s" "Cordon" "Taint" "Pods" "Shape" "Avail Domain" "Created" "Instance OCID"
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
            echo "${iid}|${ocid}" >> ${TEMP_DIR}/instance_map_$$
            
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
            local taint_status="-"
            local taint_color="$GRAY"
            local pod_count="-"
            local pod_color="$GRAY"
            local k8s_node_name=""
            
            local k8s_match
            k8s_match=$(echo "$k8s_lookup" | grep "$ocid" 2>/dev/null)
            
            if [[ -n "$k8s_match" ]]; then
                local k8s_ready unschedulable new_node_taint
                k8s_node_name=$(echo "$k8s_match" | cut -d'|' -f2)
                k8s_ready=$(echo "$k8s_match" | cut -d'|' -f3)
                new_node_taint=$(echo "$k8s_match" | cut -d'|' -f4)
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
                    cordon_status="Yes"
                    cordon_color="$YELLOW"
                else
                    cordon_status="-"
                    cordon_color="$GRAY"
                fi
                
                # Check newNode taint
                if [[ "$new_node_taint" != "N/A" && -n "$new_node_taint" ]]; then
                    taint_status="newNode"
                    taint_color="$CYAN"
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
            local shape_trunc="${shape:0:24}"
            local ad_short="${ad##*:}"
            
            # Format time_created - show date and time portion
            local time_display="$time_created"
            if [[ "$time_display" != "N/A" && -n "$time_display" ]]; then
                # Format: 2026-01-27T03:29:11.123Z -> 2026-01-27 03:29
                time_display="${time_display:0:16}"
                time_display="${time_display/T/ }"
            fi
            
            printf "${YELLOW}%-5s${NC} %-32s ${state_color}%-10s${NC} ${k8s_color}%-8s${NC} ${cordon_color}%-8s${NC} ${taint_color}%-10s${NC} ${pod_color}%-5s${NC} %-24s %-12s ${GRAY}%-16s${NC} ${YELLOW}%s${NC}\n" \
                "$iid" "$name_trunc" "$state" "$k8s_status" "$cordon_status" "$taint_status" "$pod_count" "$shape_trunc" "$ad_short" "$time_display" "$ocid"
        done
        
        # Read map from temp file
        if [[ -f ${TEMP_DIR}/instance_map_$$ ]]; then
            while IFS='|' read -r iid ocid; do
                INSTANCE_INDEX_MAP[$iid]="$ocid"
            done < ${TEMP_DIR}/instance_map_$$
            rm -f ${TEMP_DIR}/instance_map_$$
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
        local tmp_bv_dir="${TEMP_DIR}/bv_fetch_$$"
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
        
        local tmp_img_dir="${TEMP_DIR}/img_fetch_$$"
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
    
    local tmp_data="${TEMP_DIR}/instance_props_$$"
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
        "\(.metadata.name)|\(.status.conditions[] | select(.type=="Ready") | .status)|\(.metadata.labels["nvidia.com/gpu.clique"] // "N/A")|\(.metadata.labels["nvidia.com/gpu.present"] // "false")|\(.spec.unschedulable // false)|\((.spec.taints // []) | map(select(.key == "newNode")) | if length > 0 then .[0].effect else "N/A" end)"
    ' 2>/dev/null)
    
    if [[ -n "$k8s_node_info" ]]; then
        local k8s_node_name k8s_ready k8s_clique k8s_gpu_present k8s_unschedulable k8s_new_node_taint
        IFS='|' read -r k8s_node_name k8s_ready k8s_clique k8s_gpu_present k8s_unschedulable k8s_new_node_taint <<< "$k8s_node_info"
        
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
        
        # Check for newNode taint
        local taint_info=""
        local taint_color="$GRAY"
        if [[ "$k8s_new_node_taint" != "N/A" && -n "$k8s_new_node_taint" ]]; then
            taint_info="newNode:${k8s_new_node_taint}"
            taint_color="$YELLOW"
        fi
        
        printf "${WHITE}%-10s${NC}${GREEN}%-14s${NC}  ${WHITE}%-8s${NC}${GREEN}%-22s${NC}  ${WHITE}%-8s${NC}${ready_color}%-8s${NC}  ${WHITE}%-10s${NC}${sched_color}%-12s${NC}  ${WHITE}%-6s${NC}${CYAN}%-5s${NC}\n" \
            "Status:" "In Cluster" "Node:" "$k8s_node_name" "Ready:" "$k8s_ready" "Schedule:" "$sched_status" "Pods:" "$k8s_pod_count"
        
        # Second line with GPU and taint info
        if [[ "$k8s_gpu_present" == "true" ]]; then
            local clique_info="N/A"
            [[ "$k8s_clique" != "N/A" ]] && clique_info="$k8s_clique"
            if [[ -n "$taint_info" ]]; then
                printf "${WHITE}%-10s${NC}${GREEN}%-14s${NC}  ${WHITE}%-8s${NC}${CYAN}%-22s${NC}  ${WHITE}%-8s${NC}${taint_color}%-20s${NC}\n" "GPU:" "Present" "Clique:" "$clique_info" "Taint:" "$taint_info"
            else
                printf "${WHITE}%-10s${NC}${GREEN}%-14s${NC}  ${WHITE}%-8s${NC}${CYAN}%-22s${NC}\n" "GPU:" "Present" "Clique:" "$clique_info"
            fi
        elif [[ -n "$taint_info" ]]; then
            printf "${WHITE}%-10s${NC}${taint_color}%-30s${NC}\n" "Taint:" "$taint_info"
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
    
    # ========== TAGS ==========
    echo ""
    echo -e "${BOLD}${WHITE}─── Tags ──────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
    
    # Defined Tags
    local defined_tags
    defined_tags=$(echo "$instance_json" | jq -r '.data["defined-tags"] // {}')
    
    local has_defined_tags="false"
    if [[ -n "$defined_tags" && "$defined_tags" != "{}" ]]; then
        has_defined_tags="true"
        echo -e "${CYAN}Defined Tags:${NC}"
        echo "$defined_tags" | jq -r 'to_entries[] | .key as $ns | .value | to_entries[] | "  \($ns).\(.key) = \(.value)"' 2>/dev/null | while read -r tag_line; do
            # Highlight unhealthy tags
            if [[ "$tag_line" == *"ComputeInstanceHostActions"* ]]; then
                echo -e "  ${RED}★ ${tag_line}${NC}"
            else
                echo -e "  ${GRAY}${tag_line}${NC}"
            fi
        done
    fi
    
    # Freeform Tags
    local freeform_tags
    freeform_tags=$(echo "$instance_json" | jq -r '.data["freeform-tags"] // {}')
    
    local has_freeform_tags="false"
    if [[ -n "$freeform_tags" && "$freeform_tags" != "{}" ]]; then
        has_freeform_tags="true"
        [[ "$has_defined_tags" == "true" ]] && echo ""
        echo -e "${CYAN}Freeform Tags:${NC}"
        echo "$freeform_tags" | jq -r 'to_entries[] | "  \(.key) = \(.value)"' 2>/dev/null | while read -r tag_line; do
            # Highlight GPU/cluster related tags
            if [[ "$tag_line" == *"gpumemorycluster"* || "$tag_line" == *"oke-"* ]]; then
                echo -e "  ${GREEN}${tag_line}${NC}"
            else
                echo -e "  ${GRAY}${tag_line}${NC}"
            fi
        done
    fi
    
    [[ "$has_defined_tags" == "false" && "$has_freeform_tags" == "false" ]] && echo -e "${GRAY}No tags${NC}"
    
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
        
        # Line 3: Unhealthy tagging options
        echo -e "  ${YELLOW}t${NC}) Tag unhealthy (keep running)     ${GREEN}rt${NC}) Remove unhealthy tag     ${RED}x${NC}) ${RED}Tag unhealthy + TERMINATE${NC}"
        
        # Line 4: K8s node actions (only if in K8s)
        if [[ -n "$k8s_node_name" ]]; then
            echo -e "  ${BLUE}d${NC}) Drain K8s node     ${BLUE}c${NC}) Cordon node        ${BLUE}u${NC}) Uncordon node"
        fi
        
        echo ""
        echo -e "  ${WHITE}Enter${NC}) Return to list"
        echo ""
        echo -n -e "${CYAN}Select [r/1-9/t/rt/x/d/c/u/Enter]: ${NC}"
        
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
        t|T|tag|TAG)
            # Tag instance as unhealthy (no terminate)
            tag_instance_unhealthy "$instance_ocid" "$display_name" "false"
            ;;
        rt|RT|removetag|REMOVETAG)
            # Remove unhealthy tag from instance
            remove_instance_unhealthy_tag "$instance_ocid" "$display_name"
            ;;
        x|X)
            # Tag instance as unhealthy AND terminate
            tag_instance_unhealthy "$instance_ocid" "$display_name" "true"
            ;;
        *)
            # Return to instance list (exit the actions loop)
            break
            ;;
    esac
    done  # End of actions loop
}

#--------------------------------------------------------------------------------
# Tag instance as unhealthy with optional terminate
# Args: $1 = instance OCID, $2 = display name, $3 = terminate (true/false)
#--------------------------------------------------------------------------------
tag_instance_unhealthy() {
    local instance_ocid="$1"
    local display_name="$2"
    local do_terminate="${3:-false}"
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    # Oracle defined tag namespace and key for host actions
    local tag_namespace="ComputeInstanceHostActions"
    local tag_key="CustomerReportedHostStatus"
    local tag_value="unhealthy"
    
    echo ""
    if [[ "$do_terminate" == "true" ]]; then
        echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║              ⚠️  TAG UNHEALTHY + TERMINATE INSTANCE  ⚠️                         ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    else
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║                         TAG INSTANCE AS UNHEALTHY                              ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    fi
    echo ""
    echo -e "${WHITE}Instance:${NC}  ${GREEN}$display_name${NC}"
    echo -e "${WHITE}OCID:${NC}      ${YELLOW}$instance_ocid${NC}"
    echo ""
    echo -e "${WHITE}Defined tag to apply:${NC}"
    echo -e "  ${CYAN}Namespace:${NC} ${MAGENTA}$tag_namespace${NC}"
    echo -e "  ${CYAN}Key:${NC}       ${MAGENTA}$tag_key${NC}"
    echo -e "  ${CYAN}Value:${NC}     ${MAGENTA}$tag_value${NC}"
    echo ""
    
    if [[ "$do_terminate" == "true" ]]; then
        echo -e "${RED}⚠️  This will TAG the instance as unhealthy AND TERMINATE it!${NC}"
        echo ""
        echo -n -e "${RED}Type 'yes' to confirm TAG + TERMINATE: ${NC}"
    else
        echo -e "${YELLOW}This will TAG the instance as unhealthy (instance will continue running).${NC}"
        echo ""
        echo -n -e "${CYAN}Confirm tag? (yes/no): ${NC}"
    fi
    
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}Operation cancelled${NC}"
        echo ""
        echo -n -e "${CYAN}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    # Get current defined tags
    echo ""
    echo -e "${YELLOW}Fetching current instance tags...${NC}"
    
    local instance_json
    instance_json=$(oci compute instance get \
        --instance-id "$instance_ocid" \
        --region "$region" \
        --output json 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to fetch instance details:${NC}"
        echo "$instance_json"
        echo ""
        echo -n -e "${CYAN}Press Enter to continue...${NC}"
        read -r
        return 1
    fi
    
    # Extract current defined-tags
    local current_defined_tags
    current_defined_tags=$(echo "$instance_json" | jq -r '.data["defined-tags"] // {}')
    
    # Show current tags
    echo ""
    echo -e "${WHITE}Current defined tags:${NC}"
    if [[ -n "$current_defined_tags" && "$current_defined_tags" != "{}" ]]; then
        echo "$current_defined_tags" | jq -r 'to_entries[] | .key as $ns | .value | to_entries[] | "  \($ns).\(.key) = \(.value)"' 2>/dev/null
    else
        echo -e "  ${GRAY}(none)${NC}"
    fi
    echo ""
    
    # Merge in our new tag (preserving all existing tags)
    local updated_defined_tags
    updated_defined_tags=$(echo "$current_defined_tags" | jq --arg ns "$tag_namespace" --arg key "$tag_key" --arg val "$tag_value" '
        .[$ns] = ((.[$ns] // {}) + {($key): $val})
    ')
    
    # Format the JSON for display (compact for command, pretty for log)
    local updated_tags_compact
    updated_tags_compact=$(echo "$updated_defined_tags" | jq -c '.')
    
    # Build the update command for display
    local update_cmd="oci compute instance update --instance-id \"$instance_ocid\" --region \"$region\" --defined-tags '${updated_tags_compact}' --force"
    
    echo -e "${WHITE}Command to execute:${NC}"
    echo -e "${GRAY}oci compute instance update \\${NC}"
    echo -e "${GRAY}  --instance-id \"$instance_ocid\" \\${NC}"
    echo -e "${GRAY}  --region \"$region\" \\${NC}"
    echo -e "${GRAY}  --defined-tags '${NC}"
    echo "$updated_defined_tags" | jq '.' | while IFS= read -r line; do
        echo -e "${GRAY}$line${NC}"
    done
    echo -e "${GRAY}' --force${NC}"
    echo ""
    
    # Log the action
    log_action "TAG_UNHEALTHY" "$update_cmd"
    
    # Apply the tag
    echo -e "${YELLOW}Applying defined tag...${NC}"
    
    local tag_result
    tag_result=$(oci compute instance update \
        --instance-id "$instance_ocid" \
        --region "$region" \
        --defined-tags "$updated_defined_tags" \
        --force \
        --output json 2>&1)
    
    local tag_exit_code=$?
    
    if [[ $tag_exit_code -eq 0 ]]; then
        echo -e "${GREEN}✓ Instance tagged as unhealthy successfully${NC}"
        log_action_result "SUCCESS" "Instance $display_name tagged with $tag_namespace.$tag_key=$tag_value"
        
        # Verify the tag was applied
        local applied_tag
        applied_tag=$(echo "$tag_result" | jq -r --arg ns "$tag_namespace" --arg key "$tag_key" '.data["defined-tags"][$ns][$key] // "NOT_SET"')
        echo -e "  ${CYAN}Verified:${NC} ${MAGENTA}$tag_namespace.$tag_key${NC} = ${GREEN}$applied_tag${NC}"
        
        # If terminate requested, show instance details with the tag first
        if [[ "$do_terminate" == "true" ]]; then
            echo ""
            echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}                           INSTANCE DETAILS WITH APPLIED TAG                                                    ${NC}"
            echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
            echo ""
            
            # Re-fetch instance to show updated tags
            local updated_instance_json
            updated_instance_json=$(oci compute instance get \
                --instance-id "$instance_ocid" \
                --region "$region" \
                --output json 2>/dev/null)
            
            if [[ -n "$updated_instance_json" ]]; then
                # Display key instance info
                local inst_state inst_shape inst_ad inst_created
                inst_state=$(echo "$updated_instance_json" | jq -r '.data["lifecycle-state"] // "N/A"')
                inst_shape=$(echo "$updated_instance_json" | jq -r '.data.shape // "N/A"')
                inst_ad=$(echo "$updated_instance_json" | jq -r '.data["availability-domain"] // "N/A"')
                inst_created=$(echo "$updated_instance_json" | jq -r '.data["time-created"] // "N/A"')
                
                echo -e "${WHITE}Instance:${NC}       ${GREEN}$display_name${NC}"
                echo -e "${WHITE}OCID:${NC}           ${YELLOW}$instance_ocid${NC}"
                echo -e "${WHITE}State:${NC}          ${CYAN}$inst_state${NC}"
                echo -e "${WHITE}Shape:${NC}          ${CYAN}$inst_shape${NC}"
                echo -e "${WHITE}AD:${NC}             ${CYAN}${inst_ad##*:}${NC}"
                echo -e "${WHITE}Created:${NC}        ${GRAY}${inst_created:0:19}${NC}"
                echo ""
                
                # Display defined tags (highlighting the unhealthy tag)
                echo -e "${WHITE}─── Defined Tags ───${NC}"
                local defined_tags
                defined_tags=$(echo "$updated_instance_json" | jq -r '.data["defined-tags"] // {}')
                
                if [[ -n "$defined_tags" && "$defined_tags" != "{}" ]]; then
                    echo "$defined_tags" | jq -r 'to_entries[] | .key as $ns | .value | to_entries[] | "\($ns).\(.key)=\(.value)"' 2>/dev/null | while read -r tag_line; do
                        if [[ "$tag_line" == *"$tag_namespace.$tag_key"* ]]; then
                            # Highlight the unhealthy tag
                            echo -e "  ${RED}★ $tag_line${NC}  ${RED}← UNHEALTHY TAG APPLIED${NC}"
                        else
                            echo -e "  ${GRAY}$tag_line${NC}"
                        fi
                    done
                else
                    echo -e "  ${GRAY}(none)${NC}"
                fi
                
                # Display freeform tags if any
                local freeform_tags
                freeform_tags=$(echo "$updated_instance_json" | jq -r '.data["freeform-tags"] // {}')
                if [[ -n "$freeform_tags" && "$freeform_tags" != "{}" ]]; then
                    echo ""
                    echo -e "${WHITE}─── Freeform Tags ───${NC}"
                    echo "$freeform_tags" | jq -r 'to_entries[] | "  \(.key)=\(.value)"' 2>/dev/null
                fi
            fi
            
            echo ""
            echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        fi
    else
        echo -e "${RED}✗ Failed to tag instance:${NC}"
        echo "$tag_result"
        log_action_result "FAILED" "Failed to tag instance $display_name"
        
        # Check if it's a tag namespace issue
        if echo "$tag_result" | grep -qi "TagDefinition\|TagNamespace\|does not exist"; then
            echo ""
            echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
            echo -e "${YELLOW}NOTE: The tag namespace '$tag_namespace' or key '$tag_key' may not exist in your tenancy.${NC}"
            echo -e "${YELLOW}You may need to create it first or use a different tag.${NC}"
            echo ""
            echo -e "${WHITE}To create the tag namespace and key, use:${NC}"
            echo -e "${GRAY}  oci iam tag-namespace create --compartment-id <root-compartment> --name \"$tag_namespace\" --description \"Host action tags\"${NC}"
            echo -e "${GRAY}  oci iam tag create --tag-namespace-id <namespace-ocid> --name \"$tag_key\" --description \"Customer reported host status\"${NC}"
            echo -e "${YELLOW}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        fi
        
        echo ""
        echo -n -e "${CYAN}Press Enter to continue...${NC}"
        read -r
        return 1
    fi
    
    # If terminate requested, do it now
    if [[ "$do_terminate" == "true" ]]; then
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                    ⚠️  FINAL CONFIRMATION TO TERMINATE  ⚠️                       ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${WHITE}Instance ${GREEN}$display_name${NC}${WHITE} has been tagged as unhealthy.${NC}"
        echo -e "${RED}Are you sure you want to TERMINATE this instance?${NC}"
        echo ""
        echo -n -e "${RED}Type 'TERMINATE' to proceed (or anything else to cancel): ${NC}"
        
        local final_confirm
        read -r final_confirm
        
        if [[ "$final_confirm" != "TERMINATE" ]]; then
            echo -e "${YELLOW}Termination cancelled. Instance remains tagged as unhealthy.${NC}"
            echo ""
            echo -n -e "${CYAN}Press Enter to continue...${NC}"
            read -r
            return 0
        fi
        
        echo ""
        echo -e "${RED}Proceeding with instance termination...${NC}"
        
        local terminate_cmd="oci compute instance terminate --instance-id \"$instance_ocid\" --region \"$region\" --preserve-boot-volume false --force"
        
        echo ""
        echo -e "${WHITE}Command to execute:${NC}"
        echo -e "${GRAY}$terminate_cmd${NC}"
        echo ""
        
        log_action "TERMINATE" "$terminate_cmd"
        
        local terminate_result
        terminate_result=$(oci compute instance terminate \
            --instance-id "$instance_ocid" \
            --region "$region" \
            --preserve-boot-volume false \
            --force 2>&1)
        
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✓ Instance termination initiated${NC}"
            log_action_result "SUCCESS" "Instance $display_name termination initiated"
        else
            echo -e "${RED}✗ Failed to terminate instance:${NC}"
            echo "$terminate_result"
            log_action_result "FAILED" "Failed to terminate instance $display_name"
        fi
    fi
    
    echo ""
    echo -n -e "${CYAN}Press Enter to continue...${NC}"
    read -r
}

#--------------------------------------------------------------------------------
# Remove unhealthy tag from instance
# Args: $1 = instance OCID, $2 = display name
#--------------------------------------------------------------------------------
remove_instance_unhealthy_tag() {
    local instance_ocid="$1"
    local display_name="$2"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    # Oracle defined tag namespace and key for host actions
    local tag_namespace="ComputeInstanceHostActions"
    local tag_key="CustomerReportedHostStatus"
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                       REMOVE UNHEALTHY TAG FROM INSTANCE                       ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}Instance:${NC}  ${GREEN}$display_name${NC}"
    echo -e "${WHITE}OCID:${NC}      ${YELLOW}$instance_ocid${NC}"
    echo ""
    
    # Get current defined tags
    echo -e "${YELLOW}Fetching current instance tags...${NC}"
    
    local instance_json
    instance_json=$(oci compute instance get \
        --instance-id "$instance_ocid" \
        --region "$region" \
        --output json 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to fetch instance details:${NC}"
        echo "$instance_json"
        echo ""
        echo -n -e "${CYAN}Press Enter to continue...${NC}"
        read -r
        return 1
    fi
    
    # Extract current defined-tags
    local current_defined_tags
    current_defined_tags=$(echo "$instance_json" | jq -r '.data["defined-tags"] // {}')
    
    # Check if the tag exists
    local current_tag_value
    current_tag_value=$(echo "$current_defined_tags" | jq -r --arg ns "$tag_namespace" --arg key "$tag_key" '.[$ns][$key] // empty')
    
    if [[ -z "$current_tag_value" ]]; then
        echo ""
        echo -e "${YELLOW}The unhealthy tag is not set on this instance.${NC}"
        echo -e "  ${CYAN}$tag_namespace.$tag_key${NC} = ${GRAY}(not set)${NC}"
        echo ""
        echo -n -e "${CYAN}Press Enter to continue...${NC}"
        read -r
        return 0
    fi
    
    echo ""
    echo -e "${WHITE}Current tag to remove:${NC}"
    echo -e "  ${CYAN}Namespace:${NC} ${MAGENTA}$tag_namespace${NC}"
    echo -e "  ${CYAN}Key:${NC}       ${MAGENTA}$tag_key${NC}"
    echo -e "  ${CYAN}Value:${NC}     ${RED}$current_tag_value${NC}"
    echo ""
    
    # Show all current tags
    echo -e "${WHITE}All current defined tags:${NC}"
    if [[ -n "$current_defined_tags" && "$current_defined_tags" != "{}" ]]; then
        echo "$current_defined_tags" | jq -r 'to_entries[] | .key as $ns | .value | to_entries[] | "\($ns).\(.key) = \(.value)"' 2>/dev/null | while read -r tag_line; do
            if [[ "$tag_line" == *"$tag_namespace.$tag_key"* ]]; then
                echo -e "  ${RED}★ $tag_line${NC}  ${RED}← TO BE REMOVED${NC}"
            else
                echo -e "  ${GRAY}$tag_line${NC}"
            fi
        done
    fi
    echo ""
    
    echo -e "${GREEN}This will REMOVE the unhealthy tag from the instance.${NC}"
    echo ""
    echo -n -e "${CYAN}Confirm removal? (yes/no): ${NC}"
    
    local confirm
    read -r confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo -e "${YELLOW}Operation cancelled${NC}"
        echo ""
        echo -n -e "${CYAN}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    # Remove the tag by deleting the key from the namespace
    local updated_defined_tags
    updated_defined_tags=$(echo "$current_defined_tags" | jq --arg ns "$tag_namespace" --arg key "$tag_key" '
        if .[$ns] then
            .[$ns] |= del(.[$key]) |
            if .[$ns] == {} then del(.[$ns]) else . end
        else
            .
        end
    ')
    
    # Format the JSON for display
    local updated_tags_compact
    updated_tags_compact=$(echo "$updated_defined_tags" | jq -c '.')
    
    # Build the update command for display
    local update_cmd="oci compute instance update --instance-id \"$instance_ocid\" --region \"$region\" --defined-tags '${updated_tags_compact}' --force"
    
    echo ""
    echo -e "${WHITE}Command to execute:${NC}"
    echo -e "${GRAY}oci compute instance update \\${NC}"
    echo -e "${GRAY}  --instance-id \"$instance_ocid\" \\${NC}"
    echo -e "${GRAY}  --region \"$region\" \\${NC}"
    echo -e "${GRAY}  --defined-tags '${NC}"
    echo "$updated_defined_tags" | jq '.' | while IFS= read -r line; do
        echo -e "${GRAY}$line${NC}"
    done
    echo -e "${GRAY}' --force${NC}"
    echo ""
    
    # Log the action
    log_action "REMOVE_UNHEALTHY_TAG" "$update_cmd"
    
    # Apply the update
    echo -e "${YELLOW}Removing unhealthy tag...${NC}"
    
    local tag_result
    tag_result=$(oci compute instance update \
        --instance-id "$instance_ocid" \
        --region "$region" \
        --defined-tags "$updated_defined_tags" \
        --force \
        --output json 2>&1)
    
    local tag_exit_code=$?
    
    if [[ $tag_exit_code -eq 0 ]]; then
        echo -e "${GREEN}✓ Unhealthy tag removed successfully${NC}"
        log_action_result "SUCCESS" "Instance $display_name - removed $tag_namespace.$tag_key tag"
        
        # Verify the tag was removed
        local verified_tag
        verified_tag=$(echo "$tag_result" | jq -r --arg ns "$tag_namespace" --arg key "$tag_key" '.data["defined-tags"][$ns][$key] // "REMOVED"')
        if [[ "$verified_tag" == "REMOVED" || -z "$verified_tag" ]]; then
            echo -e "  ${CYAN}Verified:${NC} ${MAGENTA}$tag_namespace.$tag_key${NC} = ${GREEN}(removed)${NC}"
        else
            echo -e "  ${YELLOW}Warning:${NC} Tag may still exist: ${MAGENTA}$tag_namespace.$tag_key${NC} = ${RED}$verified_tag${NC}"
        fi
        
        # Show updated tags
        echo ""
        echo -e "${WHITE}─── Updated Defined Tags ───${NC}"
        local final_tags
        final_tags=$(echo "$tag_result" | jq -r '.data["defined-tags"] // {}')
        if [[ -n "$final_tags" && "$final_tags" != "{}" ]]; then
            echo "$final_tags" | jq -r 'to_entries[] | .key as $ns | .value | to_entries[] | "  \($ns).\(.key) = \(.value)"' 2>/dev/null
        else
            echo -e "  ${GRAY}(no defined tags)${NC}"
        fi
    else
        echo -e "${RED}✗ Failed to remove tag:${NC}"
        echo "$tag_result"
        log_action_result "FAILED" "Failed to remove unhealthy tag from instance $display_name"
    fi
    
    echo ""
    echo -n -e "${CYAN}Press Enter to continue...${NC}"
    read -r
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
    temp_output=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    temp_error=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    
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
    tmp1=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    tmp2=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    
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
    tmp_instance=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    tmp_ic=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    
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
    tmp1=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    tmp2=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    
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
                rm -f "$FABRIC_CACHE" "$CLUSTER_CACHE" "$INSTANCE_CLUSTER_MAP_CACHE" "$INSTANCE_CONFIG_CACHE" "$COMPUTE_CLUSTER_CACHE"
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
    rm -f "$FABRIC_CACHE" "$CLUSTER_CACHE" "$INSTANCE_CLUSTER_MAP_CACHE" "$INSTANCE_CONFIG_CACHE" "$COMPUTE_CLUSTER_CACHE"
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
    fabric_output_temp=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    
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
    cc_output_temp=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    
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
    ic_output_temp=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    
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
        
        # Invalidate cluster, fabric, and instance-cluster map caches
        rm -f "$CLUSTER_CACHE" "$FABRIC_CACHE" "$INSTANCE_CLUSTER_MAP_CACHE"
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
    rm -f "$FABRIC_CACHE" "$CLUSTER_CACHE" "$INSTANCE_CLUSTER_MAP_CACHE" "$INSTANCE_CONFIG_CACHE" "$COMPUTE_CLUSTER_CACHE"
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
    cluster_lines_temp=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
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
            ic_output_temp=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
            
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
            ic_output_temp=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
            
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
        
        # Invalidate cluster, fabric, and instance-cluster map caches
        rm -f "$CLUSTER_CACHE" "$FABRIC_CACHE" "$INSTANCE_CLUSTER_MAP_CACHE"
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
    rm -f "$FABRIC_CACHE" "$CLUSTER_CACHE" "$INSTANCE_CLUSTER_MAP_CACHE" "$INSTANCE_CONFIG_CACHE" "$COMPUTE_CLUSTER_CACHE"
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
    ic_output_temp=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    
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
    rm -f "$CLUSTER_CACHE" "$FABRIC_CACHE" "$INSTANCE_CLUSTER_MAP_CACHE"
    
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

#================================================================================
# RESOURCE MANAGER STACKS MANAGEMENT
#================================================================================

#--------------------------------------------------------------------------------
# Manage Resource Manager Stacks - Main menu
#--------------------------------------------------------------------------------
manage_resource_manager_stacks() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    
    # Show stacks with jobs - this function handles all interactions
    # When user presses 'b', it returns and we go back to main menu
    rm_list_stacks_with_jobs "$compartment_id"
}

#--------------------------------------------------------------------------------
# List All Resource Manager Stacks with their Jobs - Interactive
#--------------------------------------------------------------------------------
rm_list_stacks_with_jobs() {
    local compartment_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${WHITE}                                  ALL STACKS WITH JOB HISTORY                                                    ${NC}"
    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local list_cmd="oci resource-manager stack list --compartment-id \"$compartment_id\" --all --output json"
    echo -e "${GRAY}$list_cmd${NC}"
    echo ""
    
    local stacks_json
    stacks_json=$(oci resource-manager stack list \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$stacks_json" || "$stacks_json" == "null" ]]; then
        echo -e "${YELLOW}No stacks found or unable to list stacks${NC}"
        return 1
    fi
    
    local stack_count
    stack_count=$(echo "$stacks_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$stack_count" -eq 0 ]]; then
        echo -e "${YELLOW}No stacks found in this compartment${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Found $stack_count stack(s)${NC}"
    echo ""
    
    # Clear and populate global maps
    declare -gA RM_STACK_MAP
    declare -gA RM_STACK_NAMES
    declare -gA RM_JOB_MAP  # Maps "stack_idx.job_idx" to job_id
    RM_STACK_MAP=()
    RM_STACK_NAMES=()
    RM_JOB_MAP=()
    
    local stack_idx=0
    
    # Process each stack
    while IFS='|' read -r stack_name state tf_version stack_id time_created; do
        [[ -z "$stack_name" ]] && continue
        ((stack_idx++))
        
        RM_STACK_MAP[$stack_idx]="$stack_id"
        RM_STACK_NAMES[$stack_idx]="$stack_name"
        
        # Color based on state
        local state_color="$GREEN"
        case "$state" in
            ACTIVE) state_color="$GREEN" ;;
            CREATING|UPDATING) state_color="$YELLOW" ;;
            DELETING|DELETED|FAILED) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        
        echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "${BOLD}${CYAN}│ [s${stack_idx}] Stack: ${WHITE}${stack_name}${NC}"
        echo -e "${BOLD}${CYAN}├──────────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "│ ${CYAN}State:${NC}      ${state_color}${state}${NC}"
        echo -e "│ ${CYAN}TF Version:${NC} ${WHITE}${tf_version:-N/A}${NC}"
        echo -e "│ ${CYAN}Created:${NC}    ${WHITE}${time_created:0:19}${NC}"
        echo -e "│ ${CYAN}Stack OCID:${NC} ${YELLOW}${stack_id}${NC}"
        echo -e "${BOLD}${CYAN}│${NC}"
        
        # Fetch jobs for this stack
        local jobs_json
        jobs_json=$(oci resource-manager job list \
            --stack-id "$stack_id" \
            --all \
            --output json 2>/dev/null)
        
        local job_count=0
        if [[ -n "$jobs_json" && "$jobs_json" != "null" ]]; then
            job_count=$(echo "$jobs_json" | jq '.data | length' 2>/dev/null) || job_count=0
        fi
        
        if [[ "$job_count" -eq 0 ]]; then
            echo -e "│ ${GRAY}No jobs found for this stack${NC}"
        else
            echo -e "│ ${BOLD}${WHITE}Jobs (${job_count}):${NC}"
            echo -e "│"
            printf "│   ${BOLD}%-8s %-12s %-12s %-20s %-20s %s${NC}\n" "ID" "Operation" "State" "Created" "Finished" "Job OCID"
            echo -e "│   ────────────────────────────────────────────────────────────────────────────────────────────────────────"
            
            local job_idx=0
            while IFS='|' read -r operation job_state time_created time_finished job_id; do
                [[ -z "$operation" ]] && continue
                ((job_idx++))
                
                # Store job mapping
                RM_JOB_MAP["${stack_idx}.${job_idx}"]="$job_id"
                
                # Color based on state
                local job_state_color="$GREEN"
                case "$job_state" in
                    SUCCEEDED) job_state_color="$GREEN" ;;
                    IN_PROGRESS|ACCEPTED) job_state_color="$YELLOW" ;;
                    FAILED|CANCELED) job_state_color="$RED" ;;
                    *) job_state_color="$GRAY" ;;
                esac
                
                # Operation color
                local op_color="$WHITE"
                case "$operation" in
                    APPLY) op_color="$GREEN" ;;
                    PLAN) op_color="$CYAN" ;;
                    DESTROY) op_color="$RED" ;;
                    IMPORT_TF_STATE) op_color="$YELLOW" ;;
                esac
                
                # Format times
                local time_created_short="${time_created:0:19}"
                local time_finished_short="${time_finished:0:19}"
                [[ "$time_finished_short" == "null" || -z "$time_finished_short" ]] && time_finished_short="-"
                
                printf "│   ${YELLOW}[j%-5s]${NC} ${op_color}%-12s${NC} ${job_state_color}%-12s${NC} %-20s %-20s ${GRAY}%s${NC}\n" \
                    "${stack_idx}.${job_idx}" "$operation" "$job_state" "$time_created_short" "$time_finished_short" "$job_id"
                    
            done < <(echo "$jobs_json" | jq -r '.data | sort_by(.["time-created"]) | reverse | .[] | "\(.operation)|\(.["lifecycle-state"])|\(.["time-created"])|\(.["time-finished"] // "null")|\(.id)"' 2>/dev/null)
        fi
        
        echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
        
    done < <(echo "$stacks_json" | jq -r '.data | sort_by(.["display-name"]) | .[] | "\(.["display-name"])|\(.["lifecycle-state"])|\(.["terraform-version"] // "N/A")|\(.id)|\(.["time-created"])"' 2>/dev/null)
    
    RM_STACK_COUNT=$stack_idx
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Summary ═══${NC}"
    echo -e "  Total Stacks: ${GREEN}$stack_count${NC}"
    echo ""
    
    # Interactive selection loop
    while true; do
        echo -e "${BOLD}${WHITE}─── Selection Options ───${NC}"
        echo -e "  ${YELLOW}s#${NC}       - View stack details (e.g., ${YELLOW}s1${NC})"
        echo -e "  ${YELLOW}s#o${NC}      - View stack outputs (e.g., ${YELLOW}s1o${NC})"
        echo -e "  ${YELLOW}s#r${NC}      - View stack resources (e.g., ${YELLOW}s1r${NC})"
        echo -e "  ${YELLOW}s#t${NC}      - View stack state file (e.g., ${YELLOW}s1t${NC})"
        echo -e "  ${YELLOW}j#.#${NC}     - View job details (e.g., ${YELLOW}j1.2${NC})"
        echo -e "  ${YELLOW}j#.#l${NC}    - View job logs (e.g., ${YELLOW}j1.2l${NC})"
        echo -e "  ${YELLOW}refresh${NC}  - Reload stacks and jobs"
        echo -e "  ${YELLOW}b${NC}        - Back to Resource Manager menu"
        echo ""
        echo -n -e "${CYAN}Selection: ${NC}"
        read -r selection
        
        [[ -z "$selection" || "$selection" == "b" || "$selection" == "B" ]] && return 0
        
        # Refresh
        if [[ "$selection" == "refresh" ]]; then
            rm_list_stacks_with_jobs "$compartment_id"
            return $?
        fi
        
        # Stack details: s#
        if [[ "$selection" =~ ^s([0-9]+)$ ]]; then
            local sel_stack="${BASH_REMATCH[1]}"
            if [[ -n "${RM_STACK_MAP[$sel_stack]}" ]]; then
                rm_show_stack_detail "${RM_STACK_MAP[$sel_stack]}"
            else
                echo -e "${RED}Invalid stack number: s${sel_stack}${NC}"
            fi
            continue
        fi
        
        # Stack outputs: s#o
        if [[ "$selection" =~ ^s([0-9]+)o$ ]]; then
            local sel_stack="${BASH_REMATCH[1]}"
            if [[ -n "${RM_STACK_MAP[$sel_stack]}" ]]; then
                rm_show_stack_outputs_direct "${RM_STACK_MAP[$sel_stack]}" "${RM_STACK_NAMES[$sel_stack]}"
            else
                echo -e "${RED}Invalid stack number: s${sel_stack}${NC}"
            fi
            continue
        fi
        
        # Stack resources: s#r
        if [[ "$selection" =~ ^s([0-9]+)r$ ]]; then
            local sel_stack="${BASH_REMATCH[1]}"
            if [[ -n "${RM_STACK_MAP[$sel_stack]}" ]]; then
                rm_show_stack_resources_direct "${RM_STACK_MAP[$sel_stack]}" "${RM_STACK_NAMES[$sel_stack]}"
            else
                echo -e "${RED}Invalid stack number: s${sel_stack}${NC}"
            fi
            continue
        fi
        
        # Stack state: s#t
        if [[ "$selection" =~ ^s([0-9]+)t$ ]]; then
            local sel_stack="${BASH_REMATCH[1]}"
            if [[ -n "${RM_STACK_MAP[$sel_stack]}" ]]; then
                rm_show_stack_state_direct "${RM_STACK_MAP[$sel_stack]}" "${RM_STACK_NAMES[$sel_stack]}"
            else
                echo -e "${RED}Invalid stack number: s${sel_stack}${NC}"
            fi
            continue
        fi
        
        # Job details: j#.#
        if [[ "$selection" =~ ^j([0-9]+)\.([0-9]+)$ ]]; then
            local sel_key="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
            if [[ -n "${RM_JOB_MAP[$sel_key]}" ]]; then
                rm_show_job_detail_direct "${RM_JOB_MAP[$sel_key]}"
            else
                echo -e "${RED}Invalid job reference: j${sel_key}${NC}"
            fi
            continue
        fi
        
        # Job logs: j#.#l
        if [[ "$selection" =~ ^j([0-9]+)\.([0-9]+)l$ ]]; then
            local sel_key="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
            if [[ -n "${RM_JOB_MAP[$sel_key]}" ]]; then
                rm_show_job_logs_direct "${RM_JOB_MAP[$sel_key]}"
            else
                echo -e "${RED}Invalid job reference: j${sel_key}${NC}"
            fi
            continue
        fi
        
        echo -e "${RED}Invalid selection. Use s# for stacks, j#.# for jobs${NC}"
    done
    
    return 0
}

#--------------------------------------------------------------------------------
# Show stack outputs directly by stack ID
#--------------------------------------------------------------------------------
rm_show_stack_outputs_direct() {
    local stack_id="$1"
    local stack_name="$2"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Stack Outputs: ${CYAN}${stack_name}${NC} ${BOLD}${WHITE}═══${NC}"
    echo ""
    
    local get_cmd="oci resource-manager stack get --stack-id \"$stack_id\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local stack_json
    stack_json=$(oci resource-manager stack get --stack-id "$stack_id" --output json 2>/dev/null)
    
    if [[ -z "$stack_json" || "$stack_json" == "null" ]]; then
        echo -e "${RED}Failed to get stack details${NC}"
        return
    fi
    
    # Check for outputs in stack
    local outputs
    outputs=$(echo "$stack_json" | jq '.data.outputs // {}' 2>/dev/null)
    
    if [[ "$outputs" == "{}" || "$outputs" == "null" || -z "$outputs" ]]; then
        echo -e "${YELLOW}No outputs found for this stack${NC}"
        echo -e "${GRAY}Note: Outputs are populated after a successful apply job${NC}"
    else
        echo -e "${GREEN}Stack Outputs:${NC}"
        echo ""
        echo "$outputs" | jq -r 'to_entries[] | "  \(.key): \(.value)"' 2>/dev/null
    fi
    
    echo ""
}

#--------------------------------------------------------------------------------
# Show stack resources directly by stack ID
#--------------------------------------------------------------------------------
rm_show_stack_resources_direct() {
    local stack_id="$1"
    local stack_name="$2"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Stack Resources: ${CYAN}${stack_name}${NC} ${BOLD}${WHITE}═══${NC}"
    echo ""
    
    local list_cmd="oci resource-manager stack list-terraform-resources --stack-id \"$stack_id\" --output json"
    echo -e "${GRAY}$list_cmd${NC}"
    echo ""
    
    local resources_json
    resources_json=$(oci resource-manager stack list-terraform-resources \
        --stack-id "$stack_id" \
        --output json 2>/dev/null)
    
    if [[ -z "$resources_json" || "$resources_json" == "null" ]]; then
        echo -e "${YELLOW}No resources found or unable to list resources${NC}"
        return
    fi
    
    local resource_count
    resource_count=$(echo "$resources_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$resource_count" -eq 0 ]]; then
        echo -e "${YELLOW}No resources found for this stack${NC}"
        return
    fi
    
    echo -e "${GREEN}Found $resource_count resource(s)${NC}"
    echo ""
    
    # Print header
    printf "${BOLD}%-50s %-40s %s${NC}\n" "Resource Type" "Resource Name" "Resource OCID"
    print_separator 160
    
    echo "$resources_json" | jq -r '.data[] | "\(.["resource-type"] // "N/A")|\(.["resource-name"] // "N/A")|\(.["resource-id"] // "N/A")"' 2>/dev/null | while IFS='|' read -r res_type res_name res_id; do
        printf "%-50s %-40s ${GRAY}%s${NC}\n" "${res_type:0:48}" "${res_name:0:38}" "$res_id"
    done
    
    echo ""
}

#--------------------------------------------------------------------------------
# Show stack state directly by stack ID
#--------------------------------------------------------------------------------
rm_show_stack_state_direct() {
    local stack_id="$1"
    local stack_name="$2"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Stack State: ${CYAN}${stack_name}${NC} ${BOLD}${WHITE}═══${NC}"
    echo ""
    
    local get_cmd="oci resource-manager stack get-stack-tf-state --stack-id \"$stack_id\" --file -"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local state_content
    state_content=$(oci resource-manager stack get-stack-tf-state \
        --stack-id "$stack_id" \
        --file - 2>/dev/null)
    
    if [[ -z "$state_content" ]]; then
        echo -e "${YELLOW}No state found or unable to get state${NC}"
        return
    fi
    
    # Parse and display state summary
    echo -e "${GREEN}Terraform State Summary:${NC}"
    echo ""
    
    local version serial
    version=$(echo "$state_content" | jq -r '.version // "N/A"' 2>/dev/null)
    serial=$(echo "$state_content" | jq -r '.serial // "N/A"' 2>/dev/null)
    
    echo -e "  ${CYAN}Version:${NC} $version"
    echo -e "  ${CYAN}Serial:${NC}  $serial"
    echo ""
    
    # Count resources
    local res_count
    res_count=$(echo "$state_content" | jq '.resources | length' 2>/dev/null) || res_count=0
    echo -e "  ${CYAN}Resources in state:${NC} $res_count"
    echo ""
    
    if [[ "$res_count" -gt 0 ]]; then
        echo -e "${WHITE}Resources:${NC}"
        echo ""
        printf "  ${BOLD}%-40s %-50s %s${NC}\n" "Type" "Name" "Provider"
        echo "  ────────────────────────────────────────────────────────────────────────────────────────────────────────"
        
        echo "$state_content" | jq -r '.resources[] | "\(.type // "N/A")|\(.name // "N/A")|\(.provider // "N/A")"' 2>/dev/null | while IFS='|' read -r res_type res_name res_provider; do
            printf "  %-40s %-50s ${GRAY}%s${NC}\n" "${res_type:0:38}" "${res_name:0:48}" "$res_provider"
        done
    fi
    
    echo ""
}

#--------------------------------------------------------------------------------
# Show job details directly by job ID
#--------------------------------------------------------------------------------
rm_show_job_detail_direct() {
    local job_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Job Details ═══${NC}"
    echo ""
    
    local get_cmd="oci resource-manager job get --job-id \"$job_id\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local job_json
    job_json=$(oci resource-manager job get --job-id "$job_id" --output json 2>/dev/null)
    
    if [[ -z "$job_json" || "$job_json" == "null" ]]; then
        echo -e "${RED}Failed to get job details${NC}"
        return
    fi
    
    # Extract fields
    local operation state stack_id time_created time_finished
    local resolved_plan_id apply_tf_state failure_details
    operation=$(echo "$job_json" | jq -r '.data.operation // "N/A"')
    state=$(echo "$job_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    stack_id=$(echo "$job_json" | jq -r '.data["stack-id"] // "N/A"')
    time_created=$(echo "$job_json" | jq -r '.data["time-created"] // "N/A"')
    time_finished=$(echo "$job_json" | jq -r '.data["time-finished"] // "N/A"')
    resolved_plan_id=$(echo "$job_json" | jq -r '.data["resolved-plan-job-id"] // "N/A"')
    
    # State color
    local state_color="$GREEN"
    case "$state" in
        SUCCEEDED) state_color="$GREEN" ;;
        IN_PROGRESS|ACCEPTED) state_color="$YELLOW" ;;
        FAILED|CANCELED) state_color="$RED" ;;
    esac
    
    # Operation color
    local op_color="$WHITE"
    case "$operation" in
        APPLY) op_color="$GREEN" ;;
        PLAN) op_color="$CYAN" ;;
        DESTROY) op_color="$RED" ;;
        IMPORT_TF_STATE) op_color="$YELLOW" ;;
    esac
    
    echo -e "  ${CYAN}Operation:${NC}    ${op_color}$operation${NC}"
    echo -e "  ${CYAN}State:${NC}        ${state_color}$state${NC}"
    echo -e "  ${CYAN}Created:${NC}      ${WHITE}$time_created${NC}"
    echo -e "  ${CYAN}Finished:${NC}     ${WHITE}$time_finished${NC}"
    echo -e "  ${CYAN}Stack OCID:${NC}   ${YELLOW}$stack_id${NC}"
    echo -e "  ${CYAN}Job OCID:${NC}     ${YELLOW}$job_id${NC}"
    
    if [[ "$resolved_plan_id" != "N/A" && "$resolved_plan_id" != "null" && -n "$resolved_plan_id" ]]; then
        echo -e "  ${CYAN}Plan Job:${NC}     ${YELLOW}$resolved_plan_id${NC}"
    fi
    
    # Check for failure details
    if [[ "$state" == "FAILED" ]]; then
        failure_details=$(echo "$job_json" | jq -r '.data["failure-details"] // "N/A"' 2>/dev/null)
        if [[ "$failure_details" != "N/A" && "$failure_details" != "null" && -n "$failure_details" ]]; then
            echo ""
            echo -e "  ${RED}Failure Details:${NC}"
            echo "$failure_details" | fold -s -w 100 | while IFS= read -r line; do
                echo -e "    ${RED}$line${NC}"
            done
        fi
    fi
    
    echo ""
}

#--------------------------------------------------------------------------------
# Show job logs directly by job ID
#--------------------------------------------------------------------------------
rm_show_job_logs_direct() {
    local job_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Job Logs ═══${NC}"
    echo ""
    
    local logs_cmd="oci resource-manager job get-job-logs --job-id \"$job_id\" --all --output json"
    echo -e "${GRAY}$logs_cmd${NC}"
    echo ""
    
    local logs_json
    logs_json=$(oci resource-manager job get-job-logs \
        --job-id "$job_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$logs_json" || "$logs_json" == "null" ]]; then
        echo -e "${YELLOW}No logs found or unable to get logs${NC}"
        return
    fi
    
    local log_count
    log_count=$(echo "$logs_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$log_count" -eq 0 ]]; then
        echo -e "${YELLOW}No log entries found${NC}"
        return
    fi
    
    echo -e "${GREEN}Found $log_count log entries${NC}"
    echo ""
    
    # Display logs
    echo "$logs_json" | jq -r '.data[] | "\(.timestamp // "N/A") [\(.level // "INFO")] \(.message // "")"' 2>/dev/null | while IFS= read -r log_line; do
        # Color based on log level
        if echo "$log_line" | grep -qE '\[ERROR\]|\[FATAL\]'; then
            echo -e "${RED}$log_line${NC}"
        elif echo "$log_line" | grep -qE '\[WARN\]|\[WARNING\]'; then
            echo -e "${YELLOW}$log_line${NC}"
        elif echo "$log_line" | grep -qE 'Apply complete|Creation complete|Destruction complete'; then
            echo -e "${GREEN}$log_line${NC}"
        else
            echo "$log_line"
        fi
    done
    
    echo ""
    echo -e "${GRAY}Press Enter to continue${NC}"
    read -r
}

#--------------------------------------------------------------------------------
# List Resource Manager Stacks
#--------------------------------------------------------------------------------
rm_list_stacks() {
    local compartment_id="$1"
    local interactive="${2:-true}"  # Whether to prompt for selection
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Resource Manager Stacks ═══${NC}"
    echo ""
    
    local list_cmd="oci resource-manager stack list --compartment-id \"$compartment_id\" --all --output json"
    echo -e "${GRAY}$list_cmd${NC}"
    echo ""
    
    local stacks_json
    stacks_json=$(oci resource-manager stack list \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$stacks_json" || "$stacks_json" == "null" ]]; then
        echo -e "${YELLOW}No stacks found or unable to list stacks${NC}"
        return 1
    fi
    
    local stack_count
    stack_count=$(echo "$stacks_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$stack_count" -eq 0 ]]; then
        echo -e "${YELLOW}No stacks found in this compartment${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Found $stack_count stack(s)${NC}"
    echo ""
    
    # Print header
    printf "${BOLD}%-3s %-35s %-10s %-8s %s${NC}\n" "#" "Stack Name" "State" "TF Ver" "Stack OCID"
    print_separator 160
    
    local idx=0
    # Clear and populate global stack map
    declare -gA RM_STACK_MAP
    declare -gA RM_STACK_NAMES
    RM_STACK_MAP=()
    RM_STACK_NAMES=()
    
    while IFS='|' read -r stack_name state tf_version stack_id time_created; do
        [[ -z "$stack_name" ]] && continue
        ((idx++))
        
        RM_STACK_MAP[$idx]="$stack_id"
        RM_STACK_NAMES[$idx]="$stack_name"
        
        # Color based on state
        local state_color="$GREEN"
        case "$state" in
            ACTIVE) state_color="$GREEN" ;;
            CREATING|UPDATING) state_color="$YELLOW" ;;
            DELETING|DELETED|FAILED) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        
        # Truncate name if too long
        local name_trunc="${stack_name:0:33}"
        [[ ${#stack_name} -gt 33 ]] && name_trunc="${name_trunc}.."
        
        printf "${YELLOW}%-3s${NC} %-35s ${state_color}%-10s${NC} %-8s ${GRAY}%s${NC}\n" \
            "$idx" "$name_trunc" "$state" "${tf_version:-N/A}" "$stack_id"
            
    done < <(echo "$stacks_json" | jq -r '.data[] | "\(.["display-name"])|\(.["lifecycle-state"])|\(.["terraform-version"] // "N/A")|\(.id)|\(.["time-created"])"' 2>/dev/null | sort)
    
    echo ""
    
    # Store count for other functions
    RM_STACK_COUNT=$idx
    
    if [[ "$interactive" == "true" ]]; then
        echo -e "${GRAY}Enter stack # to view details, or press Enter to continue${NC}"
        echo -n -e "${CYAN}Selection: ${NC}"
        read -r stack_selection
        
        if [[ -n "$stack_selection" && -n "${RM_STACK_MAP[$stack_selection]}" ]]; then
            rm_show_stack_detail "${RM_STACK_MAP[$stack_selection]}"
        fi
    fi
    
    return 0
}

#--------------------------------------------------------------------------------
# Show detailed stack information
#--------------------------------------------------------------------------------
rm_show_stack_detail() {
    local stack_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Stack Details ═══${NC}"
    echo ""
    
    local get_cmd="oci resource-manager stack get --stack-id \"$stack_id\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local stack_json
    stack_json=$(oci resource-manager stack get \
        --stack-id "$stack_id" \
        --output json 2>/dev/null)
    
    if [[ -z "$stack_json" || "$stack_json" == "null" ]]; then
        echo -e "${RED}Failed to get stack details${NC}"
        return
    fi
    
    # Extract fields
    local name state tf_version description time_created source_type working_dir
    name=$(echo "$stack_json" | jq -r '.data["display-name"] // "N/A"')
    state=$(echo "$stack_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    tf_version=$(echo "$stack_json" | jq -r '.data["terraform-version"] // "N/A"')
    description=$(echo "$stack_json" | jq -r '.data.description // "N/A"')
    time_created=$(echo "$stack_json" | jq -r '.data["time-created"] // "N/A"')
    source_type=$(echo "$stack_json" | jq -r '.data["config-source"].["config-source-type"] // "N/A"')
    working_dir=$(echo "$stack_json" | jq -r '.data["config-source"]["working-directory"] // "N/A"')
    
    # State color
    local state_color="$GREEN"
    case "$state" in
        ACTIVE) state_color="$GREEN" ;;
        CREATING|UPDATING) state_color="$YELLOW" ;;
        DELETING|DELETED|FAILED) state_color="$RED" ;;
    esac
    
    echo -e "  ${CYAN}Name:${NC}              ${WHITE}$name${NC}"
    echo -e "  ${CYAN}State:${NC}             ${state_color}$state${NC}"
    echo -e "  ${CYAN}Terraform Version:${NC} ${WHITE}$tf_version${NC}"
    echo -e "  ${CYAN}Description:${NC}       ${WHITE}$description${NC}"
    echo -e "  ${CYAN}Created:${NC}           ${WHITE}$time_created${NC}"
    echo -e "  ${CYAN}Source Type:${NC}       ${WHITE}$source_type${NC}"
    echo -e "  ${CYAN}Working Directory:${NC} ${WHITE}$working_dir${NC}"
    echo -e "  ${CYAN}Stack OCID:${NC}        ${YELLOW}$stack_id${NC}"
    echo ""
    
    # Show variables if any
    local variables
    variables=$(echo "$stack_json" | jq -r '.data.variables // {}')
    if [[ "$variables" != "{}" && "$variables" != "null" ]]; then
        echo -e "${BOLD}${WHITE}Variables:${NC}"
        echo "$variables" | jq -r 'to_entries[] | "  \(.key) = \(.value)"' 2>/dev/null | head -20
        local var_count
        var_count=$(echo "$variables" | jq 'keys | length' 2>/dev/null)
        [[ "$var_count" -gt 20 ]] && echo -e "  ${GRAY}... and $((var_count - 20)) more${NC}"
        echo ""
    fi
    
    # Show freeform tags
    local freeform_tags
    freeform_tags=$(echo "$stack_json" | jq -r '.data["freeform-tags"] // {}')
    if [[ "$freeform_tags" != "{}" && "$freeform_tags" != "null" ]]; then
        echo -e "${BOLD}${WHITE}Freeform Tags:${NC}"
        echo "$freeform_tags" | jq -r 'to_entries[] | "  \(.key) = \(.value)"' 2>/dev/null
        echo ""
    fi
    
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# View Stack Details (with selection from list)
#--------------------------------------------------------------------------------
rm_view_stack_details() {
    local compartment_id="$1"
    
    # List stacks without interactive prompt
    rm_list_stacks "$compartment_id" "false"
    
    if [[ ${RM_STACK_COUNT:-0} -eq 0 ]]; then
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Enter stack # to view details (or Enter to cancel): ${NC}"
    read -r stack_selection
    
    if [[ -n "$stack_selection" && -n "${RM_STACK_MAP[$stack_selection]}" ]]; then
        rm_show_stack_detail "${RM_STACK_MAP[$stack_selection]}"
    elif [[ -n "$stack_selection" ]]; then
        echo -e "${RED}Invalid selection${NC}"
    fi
}

#--------------------------------------------------------------------------------
# List Jobs for a Stack
#--------------------------------------------------------------------------------
rm_list_jobs() {
    local compartment_id="$1"
    
    # List stacks without interactive prompt
    rm_list_stacks "$compartment_id" "false"
    
    if [[ ${RM_STACK_COUNT:-0} -eq 0 ]]; then
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Enter stack # to view jobs (or Enter to cancel): ${NC}"
    read -r stack_selection
    
    if [[ -z "$stack_selection" ]]; then
        return
    fi
    
    if [[ -z "${RM_STACK_MAP[$stack_selection]}" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return
    fi
    
    local stack_id="${RM_STACK_MAP[$stack_selection]}"
    local stack_name="${RM_STACK_NAMES[$stack_selection]}"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Jobs for Stack: ${CYAN}${stack_name}${NC} ${BOLD}${WHITE}═══${NC}"
    echo ""
    
    local list_cmd="oci resource-manager job list --stack-id \"$stack_id\" --all --output json"
    echo -e "${GRAY}$list_cmd${NC}"
    echo ""
    
    local jobs_json
    jobs_json=$(oci resource-manager job list \
        --stack-id "$stack_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$jobs_json" || "$jobs_json" == "null" ]]; then
        echo -e "${YELLOW}No jobs found or unable to list jobs${NC}"
        return
    fi
    
    local job_count
    job_count=$(echo "$jobs_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$job_count" -eq 0 ]]; then
        echo -e "${YELLOW}No jobs found for this stack${NC}"
        return
    fi
    
    echo -e "${GREEN}Found $job_count job(s)${NC}"
    echo ""
    
    # Print header
    printf "${BOLD}%-3s %-12s %-12s %-20s %s${NC}\n" "#" "Operation" "State" "Time Created" "Job OCID"
    print_separator 160
    
    local idx=0
    declare -gA RM_JOB_MAP
    RM_JOB_MAP=()
    
    while IFS='|' read -r operation state time_created job_id; do
        [[ -z "$operation" ]] && continue
        ((idx++))
        
        RM_JOB_MAP[$idx]="$job_id"
        
        # Color based on state
        local state_color="$GREEN"
        case "$state" in
            SUCCEEDED) state_color="$GREEN" ;;
            IN_PROGRESS|ACCEPTED) state_color="$YELLOW" ;;
            FAILED|CANCELED) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        
        # Operation color
        local op_color="$WHITE"
        case "$operation" in
            APPLY) op_color="$GREEN" ;;
            PLAN) op_color="$CYAN" ;;
            DESTROY) op_color="$RED" ;;
            IMPORT_TF_STATE) op_color="$YELLOW" ;;
        esac
        
        # Format time
        local time_short="${time_created:0:19}"
        
        printf "${YELLOW}%-3s${NC} ${op_color}%-12s${NC} ${state_color}%-12s${NC} %-20s ${GRAY}%s${NC}\n" \
            "$idx" "$operation" "$state" "$time_short" "$job_id"
            
    done < <(echo "$jobs_json" | jq -r '.data | sort_by(.["time-created"]) | reverse | .[] | "\(.operation)|\(.["lifecycle-state"])|\(.["time-created"])|\(.id)"' 2>/dev/null)
    
    # Store count
    RM_JOB_COUNT=$idx
    
    echo ""
    echo -e "${GRAY}Enter job # to view details, or press Enter to continue${NC}"
    echo -n -e "${CYAN}Selection: ${NC}"
    read -r job_selection
    
    if [[ -n "$job_selection" && -n "${RM_JOB_MAP[$job_selection]}" ]]; then
        rm_show_job_detail "${RM_JOB_MAP[$job_selection]}"
    fi
}

#--------------------------------------------------------------------------------
# Show Job Details
#--------------------------------------------------------------------------------
rm_show_job_detail() {
    local job_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Job Details ═══${NC}"
    echo ""
    
    local get_cmd="oci resource-manager job get --job-id \"$job_id\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local job_json
    job_json=$(oci resource-manager job get \
        --job-id "$job_id" \
        --output json 2>/dev/null)
    
    if [[ -z "$job_json" || "$job_json" == "null" ]]; then
        echo -e "${RED}Failed to get job details${NC}"
        return
    fi
    
    # Extract fields
    local operation state time_created time_finished stack_id
    local apply_job_plan_resolution failure_details
    operation=$(echo "$job_json" | jq -r '.data.operation // "N/A"')
    state=$(echo "$job_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    time_created=$(echo "$job_json" | jq -r '.data["time-created"] // "N/A"')
    time_finished=$(echo "$job_json" | jq -r '.data["time-finished"] // "N/A"')
    stack_id=$(echo "$job_json" | jq -r '.data["stack-id"] // "N/A"')
    apply_job_plan_resolution=$(echo "$job_json" | jq -r '.data["apply-job-plan-resolution"] // "N/A"')
    failure_details=$(echo "$job_json" | jq -r '.data["failure-details"] // empty')
    
    # State color
    local state_color="$GREEN"
    case "$state" in
        SUCCEEDED) state_color="$GREEN" ;;
        IN_PROGRESS|ACCEPTED) state_color="$YELLOW" ;;
        FAILED|CANCELED) state_color="$RED" ;;
    esac
    
    # Operation color
    local op_color="$WHITE"
    case "$operation" in
        APPLY) op_color="$GREEN" ;;
        PLAN) op_color="$CYAN" ;;
        DESTROY) op_color="$RED" ;;
    esac
    
    echo -e "  ${CYAN}Operation:${NC}         ${op_color}$operation${NC}"
    echo -e "  ${CYAN}State:${NC}             ${state_color}$state${NC}"
    echo -e "  ${CYAN}Created:${NC}           ${WHITE}$time_created${NC}"
    echo -e "  ${CYAN}Finished:${NC}          ${WHITE}$time_finished${NC}"
    echo -e "  ${CYAN}Plan Resolution:${NC}   ${WHITE}$apply_job_plan_resolution${NC}"
    echo -e "  ${CYAN}Stack OCID:${NC}        ${YELLOW}$stack_id${NC}"
    echo -e "  ${CYAN}Job OCID:${NC}          ${YELLOW}$job_id${NC}"
    
    # Show failure details if present
    if [[ -n "$failure_details" && "$failure_details" != "null" ]]; then
        echo ""
        echo -e "${RED}Failure Details:${NC}"
        echo "$failure_details" | jq '.' 2>/dev/null || echo "$failure_details"
    fi
    
    echo ""
    echo -e "${GRAY}Options: ${WHITE}logs${NC} = view logs, ${WHITE}Enter${NC} = continue${NC}"
    echo -n -e "${CYAN}Selection: ${NC}"
    read -r action
    
    if [[ "$action" == "logs" ]]; then
        rm_show_job_logs "$job_id"
    fi
}

#--------------------------------------------------------------------------------
# View Job Details (with selection from list)
#--------------------------------------------------------------------------------
rm_view_job_details() {
    local compartment_id="$1"
    
    # First select a stack
    rm_list_stacks "$compartment_id" "false"
    
    if [[ ${RM_STACK_COUNT:-0} -eq 0 ]]; then
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Enter stack # to view its jobs (or Enter to cancel): ${NC}"
    read -r stack_selection
    
    if [[ -z "$stack_selection" ]]; then
        return
    fi
    
    if [[ -z "${RM_STACK_MAP[$stack_selection]}" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return
    fi
    
    local stack_id="${RM_STACK_MAP[$stack_selection]}"
    local stack_name="${RM_STACK_NAMES[$stack_selection]}"
    
    # Now list jobs for that stack
    echo ""
    echo -e "${BOLD}${WHITE}═══ Jobs for Stack: ${CYAN}${stack_name}${NC} ${BOLD}${WHITE}═══${NC}"
    echo ""
    
    local jobs_json
    jobs_json=$(oci resource-manager job list \
        --stack-id "$stack_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$jobs_json" || "$jobs_json" == "null" ]]; then
        echo -e "${YELLOW}No jobs found${NC}"
        return
    fi
    
    local job_count
    job_count=$(echo "$jobs_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$job_count" -eq 0 ]]; then
        echo -e "${YELLOW}No jobs found for this stack${NC}"
        return
    fi
    
    echo -e "${GREEN}Found $job_count job(s)${NC}"
    echo ""
    
    printf "${BOLD}%-3s %-12s %-12s %-20s %s${NC}\n" "#" "Operation" "State" "Time Created" "Job OCID"
    print_separator 160
    
    local idx=0
    declare -gA RM_JOB_MAP
    RM_JOB_MAP=()
    
    while IFS='|' read -r operation state time_created job_id; do
        [[ -z "$operation" ]] && continue
        ((idx++))
        
        RM_JOB_MAP[$idx]="$job_id"
        
        local state_color="$GREEN"
        case "$state" in
            SUCCEEDED) state_color="$GREEN" ;;
            IN_PROGRESS|ACCEPTED) state_color="$YELLOW" ;;
            FAILED|CANCELED) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        
        local op_color="$WHITE"
        case "$operation" in
            APPLY) op_color="$GREEN" ;;
            PLAN) op_color="$CYAN" ;;
            DESTROY) op_color="$RED" ;;
            IMPORT_TF_STATE) op_color="$YELLOW" ;;
        esac
        
        local time_short="${time_created:0:19}"
        
        printf "${YELLOW}%-3s${NC} ${op_color}%-12s${NC} ${state_color}%-12s${NC} %-20s ${GRAY}%s${NC}\n" \
            "$idx" "$operation" "$state" "$time_short" "$job_id"
            
    done < <(echo "$jobs_json" | jq -r '.data | sort_by(.["time-created"]) | reverse | .[] | "\(.operation)|\(.["lifecycle-state"])|\(.["time-created"])|\(.id)"' 2>/dev/null)
    
    echo ""
    echo -n -e "${CYAN}Enter job # to view details (or Enter to cancel): ${NC}"
    read -r job_selection
    
    if [[ -n "$job_selection" && -n "${RM_JOB_MAP[$job_selection]}" ]]; then
        rm_show_job_detail "${RM_JOB_MAP[$job_selection]}"
    elif [[ -n "$job_selection" ]]; then
        echo -e "${RED}Invalid selection${NC}"
    fi
}

#--------------------------------------------------------------------------------
# View Job Logs (with selection)
#--------------------------------------------------------------------------------
rm_view_job_logs() {
    local compartment_id="$1"
    
    # First select a stack
    rm_list_stacks "$compartment_id" "false"
    
    if [[ ${RM_STACK_COUNT:-0} -eq 0 ]]; then
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Enter stack # to view its jobs (or Enter to cancel): ${NC}"
    read -r stack_selection
    
    if [[ -z "$stack_selection" ]]; then
        return
    fi
    
    if [[ -z "${RM_STACK_MAP[$stack_selection]}" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return
    fi
    
    local stack_id="${RM_STACK_MAP[$stack_selection]}"
    local stack_name="${RM_STACK_NAMES[$stack_selection]}"
    
    # List jobs
    echo ""
    echo -e "${BOLD}${WHITE}═══ Jobs for Stack: ${CYAN}${stack_name}${NC} ${BOLD}${WHITE}═══${NC}"
    echo ""
    
    local jobs_json
    jobs_json=$(oci resource-manager job list \
        --stack-id "$stack_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$jobs_json" || "$jobs_json" == "null" ]]; then
        echo -e "${YELLOW}No jobs found${NC}"
        return
    fi
    
    local job_count
    job_count=$(echo "$jobs_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$job_count" -eq 0 ]]; then
        echo -e "${YELLOW}No jobs found for this stack${NC}"
        return
    fi
    
    echo -e "${GREEN}Found $job_count job(s)${NC}"
    echo ""
    
    printf "${BOLD}%-3s %-12s %-12s %-20s %s${NC}\n" "#" "Operation" "State" "Time Created" "Job OCID"
    print_separator 160
    
    local idx=0
    declare -gA RM_JOB_MAP
    RM_JOB_MAP=()
    
    while IFS='|' read -r operation state time_created job_id; do
        [[ -z "$operation" ]] && continue
        ((idx++))
        
        RM_JOB_MAP[$idx]="$job_id"
        
        local state_color="$GREEN"
        case "$state" in
            SUCCEEDED) state_color="$GREEN" ;;
            IN_PROGRESS|ACCEPTED) state_color="$YELLOW" ;;
            FAILED|CANCELED) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        
        local op_color="$WHITE"
        case "$operation" in
            APPLY) op_color="$GREEN" ;;
            PLAN) op_color="$CYAN" ;;
            DESTROY) op_color="$RED" ;;
            IMPORT_TF_STATE) op_color="$YELLOW" ;;
        esac
        
        local time_short="${time_created:0:19}"
        
        printf "${YELLOW}%-3s${NC} ${op_color}%-12s${NC} ${state_color}%-12s${NC} %-20s ${GRAY}%s${NC}\n" \
            "$idx" "$operation" "$state" "$time_short" "$job_id"
            
    done < <(echo "$jobs_json" | jq -r '.data | sort_by(.["time-created"]) | reverse | .[] | "\(.operation)|\(.["lifecycle-state"])|\(.["time-created"])|\(.id)"' 2>/dev/null)
    
    echo ""
    echo -n -e "${CYAN}Enter job # to view logs (or Enter to cancel): ${NC}"
    read -r job_selection
    
    if [[ -n "$job_selection" && -n "${RM_JOB_MAP[$job_selection]}" ]]; then
        rm_show_job_logs "${RM_JOB_MAP[$job_selection]}"
    elif [[ -n "$job_selection" ]]; then
        echo -e "${RED}Invalid selection${NC}"
    fi
}

rm_show_job_logs() {
    local job_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Job Logs ═══${NC}"
    echo ""
    
    local logs_cmd="oci resource-manager job get-job-logs --job-id \"$job_id\" --all"
    echo -e "${GRAY}$logs_cmd${NC}"
    echo ""
    
    # Get logs
    local logs_json
    logs_json=$(oci resource-manager job get-job-logs \
        --job-id "$job_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$logs_json" || "$logs_json" == "null" ]]; then
        echo -e "${YELLOW}No logs found or unable to retrieve logs${NC}"
        return
    fi
    
    local log_count
    log_count=$(echo "$logs_json" | jq '.data | length' 2>/dev/null)
    
    echo -e "${GREEN}Retrieved $log_count log entries${NC}"
    echo ""
    
    # Display logs with timestamp and level
    echo "$logs_json" | jq -r '.data[] | "\(.timestamp) [\(.level)] \(.message)"' 2>/dev/null | while read -r line; do
        # Color based on level in the line
        if [[ "$line" == *"[ERROR]"* ]]; then
            echo -e "${RED}$line${NC}"
        elif [[ "$line" == *"[WARN]"* ]]; then
            echo -e "${YELLOW}$line${NC}"
        elif [[ "$line" == *"[INFO]"* ]]; then
            echo -e "${WHITE}$line${NC}"
        else
            echo "$line"
        fi
    done | less -R
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# View Stack Outputs
#--------------------------------------------------------------------------------
rm_view_stack_outputs() {
    local compartment_id="$1"
    
    # List stacks first
    rm_list_stacks "$compartment_id" "false"
    
    if [[ ${RM_STACK_COUNT:-0} -eq 0 ]]; then
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Enter stack # to view outputs (or Enter to cancel): ${NC}"
    read -r stack_selection
    
    if [[ -z "$stack_selection" ]]; then
        return
    fi
    
    if [[ -z "${RM_STACK_MAP[$stack_selection]}" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return
    fi
    
    local stack_id="${RM_STACK_MAP[$stack_selection]}"
    local stack_name="${RM_STACK_NAMES[$stack_selection]}"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Stack Outputs: ${CYAN}${stack_name}${NC} ${BOLD}${WHITE}═══${NC}"
    echo ""
    
    local outputs_cmd="oci resource-manager stack list-terraform-outputs --stack-id \"$stack_id\" --all --output json"
    echo -e "${GRAY}$outputs_cmd${NC}"
    echo ""
    
    # Try the outputs endpoint
    local tf_outputs
    tf_outputs=$(oci resource-manager stack list-terraform-outputs \
        --stack-id "$stack_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -n "$tf_outputs" && "$tf_outputs" != "null" ]]; then
        local output_count
        output_count=$(echo "$tf_outputs" | jq '.data | length' 2>/dev/null)
        
        if [[ "$output_count" -gt 0 ]]; then
            echo -e "${GREEN}Found $output_count output(s)${NC}"
            echo ""
            
            printf "${BOLD}%-40s %-12s %s${NC}\n" "Output Name" "Sensitive" "Value"
            print_separator 100
            
            echo "$tf_outputs" | jq -r '.data[] | "\(.["output-name"])|\(.["is-sensitive"])|\(.["output-value"])"' 2>/dev/null | while IFS='|' read -r name sensitive value; do
                local name_trunc="${name:0:38}"
                local sens_color="$WHITE"
                local value_display
                if [[ "$sensitive" == "true" ]]; then
                    sens_color="$RED"
                    value_display="${RED}[SENSITIVE - hidden]${NC}"
                else
                    value_display="${value:0:80}"
                    [[ ${#value} -gt 80 ]] && value_display="${value_display}..."
                fi
                printf "%-40s ${sens_color}%-12s${NC} %s\n" "$name_trunc" "$sensitive" "$value_display"
            done
        else
            echo -e "${YELLOW}No outputs defined for this stack${NC}"
        fi
    else
        echo -e "${YELLOW}Unable to retrieve outputs. The stack may not have been applied yet.${NC}"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# View Stack State
#--------------------------------------------------------------------------------
rm_view_stack_state() {
    local compartment_id="$1"
    
    # List stacks first
    rm_list_stacks "$compartment_id" "false"
    
    if [[ ${RM_STACK_COUNT:-0} -eq 0 ]]; then
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Enter stack # to view state (or Enter to cancel): ${NC}"
    read -r stack_selection
    
    if [[ -z "$stack_selection" ]]; then
        return
    fi
    
    if [[ -z "${RM_STACK_MAP[$stack_selection]}" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return
    fi
    
    local stack_id="${RM_STACK_MAP[$stack_selection]}"
    local stack_name="${RM_STACK_NAMES[$stack_selection]}"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Terraform State: ${CYAN}${stack_name}${NC} ${BOLD}${WHITE}═══${NC}"
    echo ""
    
    local state_cmd="oci resource-manager stack get-stack-tf-state --stack-id \"$stack_id\" --file -"
    echo -e "${GRAY}$state_cmd${NC}"
    echo ""
    
    echo -e "${YELLOW}Note: This retrieves the Terraform state file. It may contain sensitive information.${NC}"
    echo -n -e "${CYAN}Continue? (y/N): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        return
    fi
    
    echo ""
    
    # Get state and pipe through jq for pretty printing, then to less
    oci resource-manager stack get-stack-tf-state \
        --stack-id "$stack_id" \
        --file - 2>/dev/null | jq '.' 2>/dev/null | less -R
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# List Stack Resources
#--------------------------------------------------------------------------------
rm_list_stack_resources() {
    local compartment_id="$1"
    
    # List stacks first
    rm_list_stacks "$compartment_id" "false"
    
    if [[ ${RM_STACK_COUNT:-0} -eq 0 ]]; then
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Enter stack # to list resources (or Enter to cancel): ${NC}"
    read -r stack_selection
    
    if [[ -z "$stack_selection" ]]; then
        return
    fi
    
    if [[ -z "${RM_STACK_MAP[$stack_selection]}" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return
    fi
    
    local stack_id="${RM_STACK_MAP[$stack_selection]}"
    local stack_name="${RM_STACK_NAMES[$stack_selection]}"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Resources Managed by: ${CYAN}${stack_name}${NC} ${BOLD}${WHITE}═══${NC}"
    echo ""
    
    local resources_cmd="oci resource-manager associated-resource-summary list-stack-associated-resources --stack-id \"$stack_id\" --all --output json"
    echo -e "${GRAY}$resources_cmd${NC}"
    echo ""
    
    local resources_json
    resources_json=$(oci resource-manager associated-resource-summary list-stack-associated-resources \
        --stack-id "$stack_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$resources_json" || "$resources_json" == "null" ]]; then
        echo -e "${YELLOW}No resources found or unable to list resources${NC}"
        echo -e "${GRAY}Note: Resources are only tracked after a successful apply.${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    local resource_count
    resource_count=$(echo "$resources_json" | jq '.data.items | length' 2>/dev/null)
    
    if [[ "$resource_count" -eq 0 || -z "$resource_count" ]]; then
        echo -e "${YELLOW}No resources found for this stack${NC}"
        echo -e "${GRAY}Note: Resources are only tracked after a successful apply.${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    echo -e "${GREEN}Found $resource_count resource(s)${NC}"
    echo ""
    
    # Print header
    printf "${BOLD}%-3s %-30s %-40s %s${NC}\n" "#" "Resource Type" "Resource Name" "Resource OCID"
    print_separator 180
    
    local idx=0
    echo "$resources_json" | jq -r '.data.items[] | "\(.["resource-type"])|\(.["resource-name"] // "N/A")|\(.["resource-id"])"' 2>/dev/null | while IFS='|' read -r res_type res_name res_id; do
        ((idx++))
        
        # Truncate for display
        local type_trunc="${res_type:0:28}"
        local name_trunc="${res_name:0:38}"
        [[ ${#res_name} -gt 38 ]] && name_trunc="${name_trunc}.."
        
        printf "${YELLOW}%-3s${NC} %-30s %-40s ${GRAY}%s${NC}\n" "$idx" "$type_trunc" "$name_trunc" "$res_id"
    done
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#================================================================================
# WORK REQUESTS MANAGEMENT
#================================================================================

#--------------------------------------------------------------------------------
# Manage Work Requests - Main menu
#--------------------------------------------------------------------------------
manage_work_requests() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    
    # Show work requests with interactive selection - this handles all interactions
    wr_list_work_requests_interactive "$compartment_id"
}

#--------------------------------------------------------------------------------
# List Work Requests with Interactive Selection
#--------------------------------------------------------------------------------
wr_list_work_requests_interactive() {
    local compartment_id="$1"
    local status_filter="${2:-}"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${WHITE}                                          WORK REQUESTS                                                          ${NC}"
    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    local list_cmd="oci work-requests work-request list --compartment-id \"$compartment_id\" --all --output json"
    local query_filter=""
    if [[ -n "$status_filter" ]]; then
        query_filter="--query \"data[?status=='${status_filter}']\""
        list_cmd="oci work-requests work-request list --compartment-id \"$compartment_id\" --all $query_filter --output json"
    fi
    echo -e "${GRAY}$list_cmd${NC}"
    echo ""
    
    local wr_json
    if [[ -n "$status_filter" ]]; then
        wr_json=$(oci work-requests work-request list \
            --compartment-id "$compartment_id" \
            --all \
            --query "data[?status=='${status_filter}']" \
            --output json 2>/dev/null)
    else
        wr_json=$(oci work-requests work-request list \
            --compartment-id "$compartment_id" \
            --all \
            --output json 2>/dev/null)
    fi
    
    if [[ -z "$wr_json" || "$wr_json" == "null" ]]; then
        echo -e "${YELLOW}No work requests found or unable to list work requests${NC}"
        echo ""
        echo -e "${GRAY}Press Enter to go back...${NC}"
        read -r
        return 1
    fi
    
    local wr_count
    # Handle both formats - with and without .data wrapper
    if echo "$wr_json" | jq -e '.data' &>/dev/null; then
        wr_count=$(echo "$wr_json" | jq '.data | length' 2>/dev/null)
    else
        wr_count=$(echo "$wr_json" | jq 'length' 2>/dev/null)
    fi
    
    if [[ "$wr_count" -eq 0 || -z "$wr_count" ]]; then
        echo -e "${YELLOW}No work requests found${NC}"
        [[ -n "$status_filter" ]] && echo -e "${CYAN}Filter: ${WHITE}$status_filter${NC}"
        echo ""
        echo -e "${GRAY}Press Enter to go back...${NC}"
        read -r
        return 1
    fi
    
    echo -e "${GREEN}Found $wr_count work request(s)${NC}"
    [[ -n "$status_filter" ]] && echo -e "${CYAN}Filtered by status: ${WHITE}$status_filter${NC}"
    echo ""
    
    # Print header
    printf "${BOLD}%-6s %-40s %-15s %-6s %-20s %s${NC}\n" "ID" "Operation Type" "Status" "%" "Time Started" "Work Request OCID"
    print_separator 180
    
    local idx=0
    # Clear and populate global work request map
    declare -gA WR_MAP
    WR_MAP=()
    
    # Handle both formats - with and without .data wrapper
    local jq_path=".data"
    if ! echo "$wr_json" | jq -e '.data' &>/dev/null; then
        jq_path="."
    fi
    
    while IFS='|' read -r operation_type status percent_complete time_started wr_id; do
        [[ -z "$operation_type" ]] && continue
        ((idx++))
        
        WR_MAP[$idx]="$wr_id"
        
        # Color based on status
        local status_color="$GREEN"
        case "$status" in
            SUCCEEDED|COMPLETED) status_color="$GREEN" ;;
            IN_PROGRESS|ACCEPTED) status_color="$YELLOW" ;;
            FAILED|CANCELED|CANCELING) status_color="$RED" ;;
            *) status_color="$GRAY" ;;
        esac
        
        # Truncate operation type if needed
        local op_trunc="${operation_type:0:38}"
        [[ ${#operation_type} -gt 38 ]] && op_trunc="${op_trunc}.."
        
        # Format time
        local time_short="${time_started:0:19}"
        
        # Format percentage
        local pct_display="${percent_complete:-0}"
        
        printf "${YELLOW}[w%-3s]${NC} %-40s ${status_color}%-15s${NC} %-6s %-20s ${GRAY}%s${NC}\n" \
            "$idx" "$op_trunc" "$status" "${pct_display}%" "$time_short" "$wr_id"
            
    done < <(echo "$wr_json" | jq -r "${jq_path} | sort_by(.[\"time-started\"]) | reverse | .[] | \"\(.[\"operation-type\"])|\(.status)|\(.[\"percent-complete\"])|\(.[\"time-started\"])|\(.id)\"" 2>/dev/null)
    
    echo ""
    
    # Store count
    WR_COUNT=$idx
    
    # Interactive selection loop
    while true; do
        echo -e "${BOLD}${WHITE}─── Selection Options ───${NC}"
        echo -e "  ${YELLOW}w#${NC}        - View work request details (e.g., ${YELLOW}w1${NC})"
        echo -e "  ${YELLOW}w#e${NC}       - View work request errors (e.g., ${YELLOW}w1e${NC})"
        echo -e "  ${YELLOW}w#l${NC}       - View work request logs (e.g., ${YELLOW}w1l${NC})"
        echo -e "  ${YELLOW}w#r${NC}       - View affected resources (e.g., ${YELLOW}w1r${NC})"
        echo -e "  ${YELLOW}failed${NC}    - Filter by FAILED status"
        echo -e "  ${YELLOW}progress${NC}  - Filter by IN_PROGRESS status"
        echo -e "  ${YELLOW}succeeded${NC} - Filter by SUCCEEDED status"
        echo -e "  ${YELLOW}all${NC}       - Show all work requests (clear filter)"
        echo -e "  ${YELLOW}refresh${NC}   - Reload work requests"
        echo -e "  ${YELLOW}b${NC}         - Back to main menu"
        echo ""
        echo -n -e "${CYAN}Selection: ${NC}"
        read -r selection
        
        [[ -z "$selection" || "$selection" == "b" || "$selection" == "B" ]] && return 0
        
        # Refresh
        if [[ "$selection" == "refresh" ]]; then
            wr_list_work_requests_interactive "$compartment_id" "$status_filter"
            return $?
        fi
        
        # Filter commands
        if [[ "$selection" == "failed" ]]; then
            wr_list_work_requests_interactive "$compartment_id" "FAILED"
            return $?
        fi
        if [[ "$selection" == "progress" ]]; then
            wr_list_work_requests_interactive "$compartment_id" "IN_PROGRESS"
            return $?
        fi
        if [[ "$selection" == "succeeded" ]]; then
            wr_list_work_requests_interactive "$compartment_id" "SUCCEEDED"
            return $?
        fi
        if [[ "$selection" == "all" ]]; then
            wr_list_work_requests_interactive "$compartment_id" ""
            return $?
        fi
        
        # Work request details: w#
        if [[ "$selection" =~ ^w([0-9]+)$ ]]; then
            local sel_wr="${BASH_REMATCH[1]}"
            if [[ -n "${WR_MAP[$sel_wr]}" ]]; then
                wr_show_work_request_detail "${WR_MAP[$sel_wr]}"
            else
                echo -e "${RED}Invalid work request number: w${sel_wr}${NC}"
            fi
            continue
        fi
        
        # Work request errors: w#e
        if [[ "$selection" =~ ^w([0-9]+)e$ ]]; then
            local sel_wr="${BASH_REMATCH[1]}"
            if [[ -n "${WR_MAP[$sel_wr]}" ]]; then
                wr_show_work_request_errors "${WR_MAP[$sel_wr]}"
            else
                echo -e "${RED}Invalid work request number: w${sel_wr}${NC}"
            fi
            continue
        fi
        
        # Work request logs: w#l
        if [[ "$selection" =~ ^w([0-9]+)l$ ]]; then
            local sel_wr="${BASH_REMATCH[1]}"
            if [[ -n "${WR_MAP[$sel_wr]}" ]]; then
                wr_show_work_request_logs "${WR_MAP[$sel_wr]}"
            else
                echo -e "${RED}Invalid work request number: w${sel_wr}${NC}"
            fi
            continue
        fi
        
        # Work request resources: w#r
        if [[ "$selection" =~ ^w([0-9]+)r$ ]]; then
            local sel_wr="${BASH_REMATCH[1]}"
            if [[ -n "${WR_MAP[$sel_wr]}" ]]; then
                wr_show_work_request_resources "${WR_MAP[$sel_wr]}"
            else
                echo -e "${RED}Invalid work request number: w${sel_wr}${NC}"
            fi
            continue
        fi
        
        echo -e "${RED}Invalid selection. Use w# for work requests${NC}"
    done
    
    return 0
}

#--------------------------------------------------------------------------------
# Show Work Request Resources
#--------------------------------------------------------------------------------
wr_show_work_request_resources() {
    local wr_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Work Request Affected Resources ═══${NC}"
    echo ""
    
    local get_cmd="oci work-requests work-request get --work-request-id \"$wr_id\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local wr_json
    wr_json=$(oci work-requests work-request get --work-request-id "$wr_id" --output json 2>/dev/null)
    
    if [[ -z "$wr_json" || "$wr_json" == "null" ]]; then
        echo -e "${RED}Failed to get work request details${NC}"
        return
    fi
    
    # Get resources
    local resources
    resources=$(echo "$wr_json" | jq -r '.data.resources // []' 2>/dev/null)
    
    local res_count
    res_count=$(echo "$resources" | jq 'length' 2>/dev/null) || res_count=0
    
    if [[ "$res_count" -eq 0 ]]; then
        echo -e "${YELLOW}No affected resources found${NC}"
        return
    fi
    
    echo -e "${GREEN}Found $res_count affected resource(s)${NC}"
    echo ""
    
    printf "${BOLD}%-20s %-20s %s${NC}\n" "Action Type" "Entity Type" "Resource OCID"
    print_separator 140
    
    echo "$resources" | jq -r '.[] | "\(.["action-type"] // "N/A")|\(.["entity-type"] // "N/A")|\(.identifier // "N/A")"' 2>/dev/null | while IFS='|' read -r action_type entity_type identifier; do
        # Color based on action type
        local action_color="$WHITE"
        case "$action_type" in
            CREATED) action_color="$GREEN" ;;
            UPDATED) action_color="$YELLOW" ;;
            DELETED) action_color="$RED" ;;
            IN_PROGRESS) action_color="$CYAN" ;;
        esac
        
        printf "${action_color}%-20s${NC} %-20s ${GRAY}%s${NC}\n" "$action_type" "$entity_type" "$identifier"
    done
    
    echo ""
}

#--------------------------------------------------------------------------------
# List Work Requests
#--------------------------------------------------------------------------------
wr_list_work_requests() {
    local compartment_id="$1"
    local status_filter="${2:-}"
    local action_on_select="${3:-none}"  # none, details, errors, logs
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Work Requests ═══${NC}"
    echo ""
    
    local list_cmd="oci work-requests work-request list --compartment-id \"$compartment_id\" --all --output json"
    [[ -n "$status_filter" ]] && list_cmd="oci work-requests work-request list --compartment-id \"$compartment_id\" --status \"$status_filter\" --all --output json"
    echo -e "${GRAY}$list_cmd${NC}"
    echo ""
    
    local wr_json
    if [[ -n "$status_filter" ]]; then
        wr_json=$(oci work-requests work-request list \
            --compartment-id "$compartment_id" \
            --status "$status_filter" \
            --all \
            --output json 2>/dev/null)
    else
        wr_json=$(oci work-requests work-request list \
            --compartment-id "$compartment_id" \
            --all \
            --output json 2>/dev/null)
    fi
    
    if [[ -z "$wr_json" || "$wr_json" == "null" ]]; then
        echo -e "${YELLOW}No work requests found or unable to list work requests${NC}"
        return 1
    fi
    
    local wr_count
    wr_count=$(echo "$wr_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$wr_count" -eq 0 ]]; then
        echo -e "${YELLOW}No work requests found${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Found $wr_count work request(s)${NC}"
    [[ -n "$status_filter" ]] && echo -e "${CYAN}Filtered by status: ${WHITE}$status_filter${NC}"
    echo ""
    
    # Print header
    printf "${BOLD}%-3s %-40s %-15s %-6s %-20s %s${NC}\n" "#" "Operation Type" "Status" "%" "Time Started" "Work Request OCID"
    print_separator 180
    
    local idx=0
    # Clear and populate global work request map
    declare -gA WR_MAP
    WR_MAP=()
    
    while IFS='|' read -r operation_type status percent_complete time_started wr_id; do
        [[ -z "$operation_type" ]] && continue
        ((idx++))
        
        WR_MAP[$idx]="$wr_id"
        
        # Color based on status
        local status_color="$GREEN"
        case "$status" in
            SUCCEEDED|COMPLETED) status_color="$GREEN" ;;
            IN_PROGRESS|ACCEPTED) status_color="$YELLOW" ;;
            FAILED|CANCELED|CANCELING) status_color="$RED" ;;
            *) status_color="$GRAY" ;;
        esac
        
        # Truncate operation type if needed
        local op_trunc="${operation_type:0:38}"
        [[ ${#operation_type} -gt 38 ]] && op_trunc="${op_trunc}.."
        
        # Format time
        local time_short="${time_started:0:19}"
        
        # Format percentage
        local pct_display="${percent_complete:-0}"
        
        printf "${YELLOW}%-3s${NC} %-40s ${status_color}%-15s${NC} %-6s %-20s ${GRAY}%s${NC}\n" \
            "$idx" "$op_trunc" "$status" "${pct_display}%" "$time_short" "$wr_id"
            
    done < <(echo "$wr_json" | jq -r '.data | sort_by(.["time-started"]) | reverse | .[] | "\(.["operation-type"])|\(.status)|\(.["percent-complete"])|\(.["time-started"])|\(.id)"' 2>/dev/null)
    
    echo ""
    
    # Store count
    WR_COUNT=$idx
    
    # Handle selection based on action type
    case "$action_on_select" in
        none)
            echo -e "Press Enter to continue..."
            read -r
            ;;
        details)
            echo -n -e "${CYAN}Enter work request # to view details (or Enter to cancel): ${NC}"
            read -r wr_selection
            if [[ -n "$wr_selection" && -n "${WR_MAP[$wr_selection]}" ]]; then
                wr_show_work_request_detail "${WR_MAP[$wr_selection]}"
            elif [[ -n "$wr_selection" ]]; then
                echo -e "${RED}Invalid selection${NC}"
            fi
            ;;
        errors)
            echo -n -e "${CYAN}Enter work request # to view errors (or Enter to cancel): ${NC}"
            read -r wr_selection
            if [[ -n "$wr_selection" && -n "${WR_MAP[$wr_selection]}" ]]; then
                wr_show_work_request_errors "${WR_MAP[$wr_selection]}"
            elif [[ -n "$wr_selection" ]]; then
                echo -e "${RED}Invalid selection${NC}"
            fi
            ;;
        logs)
            echo -n -e "${CYAN}Enter work request # to view logs (or Enter to cancel): ${NC}"
            read -r wr_selection
            if [[ -n "$wr_selection" && -n "${WR_MAP[$wr_selection]}" ]]; then
                wr_show_work_request_logs "${WR_MAP[$wr_selection]}"
            elif [[ -n "$wr_selection" ]]; then
                echo -e "${RED}Invalid selection${NC}"
            fi
            ;;
    esac
    
    return 0
}

#--------------------------------------------------------------------------------
# Show Work Request Details
#--------------------------------------------------------------------------------
wr_show_work_request_detail() {
    local wr_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Work Request Details ═══${NC}"
    echo ""
    
    local get_cmd="oci work-requests work-request get --work-request-id \"$wr_id\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local wr_json
    wr_json=$(oci work-requests work-request get \
        --work-request-id "$wr_id" \
        --output json 2>/dev/null)
    
    if [[ -z "$wr_json" || "$wr_json" == "null" ]]; then
        echo -e "${RED}Failed to get work request details${NC}"
        return
    fi
    
    # Extract fields
    local operation_type status percent_complete time_accepted time_started time_finished
    operation_type=$(echo "$wr_json" | jq -r '.data["operation-type"] // "N/A"')
    status=$(echo "$wr_json" | jq -r '.data.status // "N/A"')
    percent_complete=$(echo "$wr_json" | jq -r '.data["percent-complete"] // "0"')
    time_accepted=$(echo "$wr_json" | jq -r '.data["time-accepted"] // "N/A"')
    time_started=$(echo "$wr_json" | jq -r '.data["time-started"] // "N/A"')
    time_finished=$(echo "$wr_json" | jq -r '.data["time-finished"] // "N/A"')
    
    # Status color
    local status_color="$GREEN"
    case "$status" in
        SUCCEEDED|COMPLETED) status_color="$GREEN" ;;
        IN_PROGRESS|ACCEPTED) status_color="$YELLOW" ;;
        FAILED|CANCELED|CANCELING) status_color="$RED" ;;
    esac
    
    echo -e "  ${CYAN}Operation Type:${NC}    ${WHITE}$operation_type${NC}"
    echo -e "  ${CYAN}Status:${NC}            ${status_color}$status${NC}"
    echo -e "  ${CYAN}Progress:${NC}          ${WHITE}${percent_complete}%${NC}"
    echo -e "  ${CYAN}Time Accepted:${NC}     ${WHITE}$time_accepted${NC}"
    echo -e "  ${CYAN}Time Started:${NC}      ${WHITE}$time_started${NC}"
    echo -e "  ${CYAN}Time Finished:${NC}     ${WHITE}$time_finished${NC}"
    echo -e "  ${CYAN}Work Request OCID:${NC} ${YELLOW}$wr_id${NC}"
    echo ""
    
    # Show resources affected
    local resources
    resources=$(echo "$wr_json" | jq -r '.data.resources // []')
    if [[ "$resources" != "[]" && "$resources" != "null" ]]; then
        echo -e "${BOLD}${WHITE}Resources Affected:${NC}"
        echo ""
        printf "  ${BOLD}%-20s %-15s %s${NC}\n" "Entity Type" "Action" "Resource OCID"
        print_separator 140
        echo "$wr_json" | jq -r '.data.resources[] | "\(.["entity-type"])|\(.["action-type"])|\(.identifier)"' 2>/dev/null | while IFS='|' read -r entity_type action_type identifier; do
            local action_color="$WHITE"
            case "$action_type" in
                CREATED) action_color="$GREEN" ;;
                UPDATED|IN_PROGRESS) action_color="$YELLOW" ;;
                DELETED) action_color="$RED" ;;
            esac
            printf "  %-20s ${action_color}%-15s${NC} ${GRAY}%s${NC}\n" "$entity_type" "$action_type" "$identifier"
        done
        echo ""
    fi
    
    echo -e "${GRAY}Options: ${WHITE}errors${NC} = view errors, ${WHITE}logs${NC} = view logs, ${WHITE}Enter${NC} = continue${NC}"
    echo -n -e "${CYAN}Selection: ${NC}"
    read -r action
    
    case "$action" in
        errors|ERRORS|e|E)
            wr_show_work_request_errors "$wr_id"
            ;;
        logs|LOGS|l|L)
            wr_show_work_request_logs "$wr_id"
            ;;
    esac
}

#--------------------------------------------------------------------------------
# View Work Request Errors (called directly from show_detail)
#--------------------------------------------------------------------------------

wr_show_work_request_errors() {
    local wr_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Work Request Errors ═══${NC}"
    echo ""
    
    local errors_cmd="oci work-requests work-request-error list --work-request-id \"$wr_id\" --all --output json"
    echo -e "${GRAY}$errors_cmd${NC}"
    echo ""
    
    local errors_json
    errors_json=$(oci work-requests work-request-error list \
        --work-request-id "$wr_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$errors_json" || "$errors_json" == "null" ]]; then
        echo -e "${YELLOW}No errors found or unable to retrieve errors${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    local error_count
    error_count=$(echo "$errors_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$error_count" -eq 0 ]]; then
        echo -e "${GREEN}No errors found for this work request${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    echo -e "${RED}Found $error_count error(s)${NC}"
    echo ""
    
    # Display errors
    echo "$errors_json" | jq -r '.data[] | "\(.timestamp) [\(.code)] \(.message)"' 2>/dev/null | while read -r line; do
        echo -e "${RED}$line${NC}"
    done
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Show Work Request Logs (called directly from show_detail or menu)
#--------------------------------------------------------------------------------
wr_show_work_request_logs() {
    local wr_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Work Request Logs ═══${NC}"
    echo ""
    
    local logs_cmd="oci work-requests work-request-log-entry list --work-request-id \"$wr_id\" --all --output json"
    echo -e "${GRAY}$logs_cmd${NC}"
    echo ""
    
    local logs_json
    logs_json=$(oci work-requests work-request-log-entry list \
        --work-request-id "$wr_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$logs_json" || "$logs_json" == "null" ]]; then
        echo -e "${YELLOW}No logs found or unable to retrieve logs${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    local log_count
    log_count=$(echo "$logs_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$log_count" -eq 0 ]]; then
        echo -e "${YELLOW}No log entries found for this work request${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    echo -e "${GREEN}Found $log_count log entries${NC}"
    echo ""
    
    # Display logs with timestamp
    echo "$logs_json" | jq -r '.data | sort_by(.timestamp) | .[] | "\(.timestamp) | \(.message)"' 2>/dev/null | while read -r line; do
        # Color based on content
        if [[ "$line" == *"error"* || "$line" == *"Error"* || "$line" == *"ERROR"* || "$line" == *"failed"* || "$line" == *"Failed"* ]]; then
            echo -e "${RED}$line${NC}"
        elif [[ "$line" == *"warn"* || "$line" == *"Warn"* || "$line" == *"WARN"* ]]; then
            echo -e "${YELLOW}$line${NC}"
        elif [[ "$line" == *"success"* || "$line" == *"Success"* || "$line" == *"completed"* || "$line" == *"Completed"* ]]; then
            echo -e "${GREEN}$line${NC}"
        else
            echo "$line"
        fi
    done | less -R
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Filter Work Requests by Status
#--------------------------------------------------------------------------------
wr_filter_by_status() {
    local compartment_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Filter Work Requests by Status ═══${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) ${WHITE}ACCEPTED${NC}      - Work request accepted but not started"
    echo -e "  ${GREEN}2${NC}) ${WHITE}IN_PROGRESS${NC}   - Work request currently running"
    echo -e "  ${GREEN}3${NC}) ${WHITE}SUCCEEDED${NC}     - Work request completed successfully"
    echo -e "  ${GREEN}4${NC}) ${WHITE}FAILED${NC}        - Work request failed"
    echo -e "  ${GREEN}5${NC}) ${WHITE}CANCELING${NC}     - Work request being canceled"
    echo -e "  ${GREEN}6${NC}) ${WHITE}CANCELED${NC}      - Work request was canceled"
    echo ""
    echo -n -e "${CYAN}Enter status # (or Enter to cancel): ${NC}"
    read -r status_selection
    
    local status_filter=""
    case "$status_selection" in
        1) status_filter="ACCEPTED" ;;
        2) status_filter="IN_PROGRESS" ;;
        3) status_filter="SUCCEEDED" ;;
        4) status_filter="FAILED" ;;
        5) status_filter="CANCELING" ;;
        6) status_filter="CANCELED" ;;
        "") return ;;
        *)
            echo -e "${RED}Invalid selection${NC}"
            return
            ;;
    esac
    
    wr_list_work_requests "$compartment_id" "$status_filter" "details"
}

#--------------------------------------------------------------------------------
# Search Work Requests by Resource OCID
#--------------------------------------------------------------------------------
wr_search_by_resource() {
    local compartment_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Search Work Requests by Resource OCID ═══${NC}"
    echo ""
    echo -n -e "${CYAN}Enter Resource OCID to search: ${NC}"
    read -r resource_ocid
    
    if [[ -z "$resource_ocid" ]]; then
        echo -e "${YELLOW}No resource OCID provided${NC}"
        return
    fi
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Work Requests for Resource ═══${NC}"
    echo ""
    
    local search_cmd="oci work-requests work-request list --compartment-id \"$compartment_id\" --resource-id \"$resource_ocid\" --all --output json"
    echo -e "${GRAY}$search_cmd${NC}"
    echo ""
    
    local wr_json
    wr_json=$(oci work-requests work-request list \
        --compartment-id "$compartment_id" \
        --resource-id "$resource_ocid" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$wr_json" || "$wr_json" == "null" ]]; then
        echo -e "${YELLOW}No work requests found for this resource${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    local wr_count
    wr_count=$(echo "$wr_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$wr_count" -eq 0 ]]; then
        echo -e "${YELLOW}No work requests found for this resource${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    echo -e "${GREEN}Found $wr_count work request(s) for resource${NC}"
    echo ""
    
    # Print header
    printf "${BOLD}%-3s %-40s %-15s %-6s %-20s %s${NC}\n" "#" "Operation Type" "Status" "%" "Time Started" "Work Request OCID"
    print_separator 180
    
    local idx=0
    declare -gA WR_MAP
    WR_MAP=()
    
    while IFS='|' read -r operation_type status percent_complete time_started wr_id; do
        [[ -z "$operation_type" ]] && continue
        ((idx++))
        
        WR_MAP[$idx]="$wr_id"
        
        local status_color="$GREEN"
        case "$status" in
            SUCCEEDED|COMPLETED) status_color="$GREEN" ;;
            IN_PROGRESS|ACCEPTED) status_color="$YELLOW" ;;
            FAILED|CANCELED|CANCELING) status_color="$RED" ;;
            *) status_color="$GRAY" ;;
        esac
        
        local op_trunc="${operation_type:0:38}"
        [[ ${#operation_type} -gt 38 ]] && op_trunc="${op_trunc}.."
        
        local time_short="${time_started:0:19}"
        local pct_display="${percent_complete:-0}"
        
        printf "${YELLOW}%-3s${NC} %-40s ${status_color}%-15s${NC} %-6s %-20s ${GRAY}%s${NC}\n" \
            "$idx" "$op_trunc" "$status" "${pct_display}%" "$time_short" "$wr_id"
            
    done < <(echo "$wr_json" | jq -r '.data | sort_by(.["time-started"]) | reverse | .[] | "\(.["operation-type"])|\(.status)|\(.["percent-complete"])|\(.["time-started"])|\(.id)"' 2>/dev/null)
    
    WR_COUNT=$idx
    
    echo ""
    echo -e "${GRAY}Enter work request # to view details, or press Enter to continue${NC}"
    echo -n -e "${CYAN}Selection: ${NC}"
    read -r wr_selection
    
    if [[ -n "$wr_selection" && -n "${WR_MAP[$wr_selection]}" ]]; then
        wr_show_work_request_detail "${WR_MAP[$wr_selection]}"
    fi
}

#================================================================================
# FILE STORAGE SERVICE (FSS) MANAGEMENT
#================================================================================

#--------------------------------------------------------------------------------
# Get availability domains for compartment
#--------------------------------------------------------------------------------
fss_get_availability_domains() {
    local compartment_id="$1"
    
    local ad_json
    ad_json=$(oci iam availability-domain list --compartment-id "$compartment_id" --output json 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Error getting availability domains: $ad_json${NC}" >&2
        return 1
    fi
    
    echo "$ad_json" | jq -r '.data[].name' 2>/dev/null
}

#--------------------------------------------------------------------------------
# Manage File Storage - Main menu
#--------------------------------------------------------------------------------
manage_file_storage() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local ad="${AVAILABILITY_DOMAIN:-}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    # Show FSS overview on entry
    fss_show_overview "$compartment_id"
    
    while true; do
        echo ""
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${MAGENTA}                                      FILE STORAGE SERVICE (FSS)                                                 ${NC}"
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}Environment:${NC}"
        echo -e "  ${CYAN}Region:${NC}      ${WHITE}${region}${NC}"
        echo -e "  ${CYAN}Compartment:${NC} ${YELLOW}${compartment_id}${NC}"
        [[ -n "$ad" ]] && echo -e "  ${CYAN}AD:${NC}          ${WHITE}${ad}${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}─── Selection Options ───${NC}"
        echo -e "  ${YELLOW}f#${NC}        - View file system details (e.g., ${YELLOW}f1${NC})"
        echo -e "  ${YELLOW}m#${NC}        - View mount target details (e.g., ${YELLOW}m1${NC})"
        echo -e "  ${YELLOW}e#${NC}        - View export details (e.g., ${YELLOW}e1${NC})"
        echo ""
        echo -e "  ${YELLOW}cf${NC}        - Create file system"
        echo -e "  ${YELLOW}cm${NC}        - Create mount target"
        echo -e "  ${YELLOW}ce${NC}        - Create export"
        echo -e "  ${YELLOW}cs${NC}        - Create snapshot"
        echo ""
        echo -e "  ${YELLOW}df#${NC}       - Delete file system (e.g., ${YELLOW}df1${NC})"
        echo -e "  ${YELLOW}dm#${NC}       - Delete mount target (e.g., ${YELLOW}dm1${NC})"
        echo -e "  ${YELLOW}de#${NC}       - Delete export (e.g., ${YELLOW}de1${NC})"
        echo ""
        echo -e "  ${YELLOW}refresh${NC}   - Reload FSS data"
        echo -e "  ${YELLOW}b${NC}         - Back to main menu"
        echo ""
        echo -n -e "${CYAN}Selection: ${NC}"
        read -r selection
        
        [[ -z "$selection" || "$selection" == "b" || "$selection" == "B" ]] && return 0
        
        # Refresh
        if [[ "$selection" == "refresh" ]]; then
            fss_show_overview "$compartment_id"
            continue
        fi
        
        # Create commands
        if [[ "$selection" == "cf" ]]; then
            fss_create_file_system "$compartment_id" "$ad"
            fss_show_overview "$compartment_id"
            continue
        fi
        if [[ "$selection" == "cm" ]]; then
            fss_create_mount_target "$compartment_id" "$ad"
            fss_show_overview "$compartment_id"
            continue
        fi
        if [[ "$selection" == "ce" ]]; then
            fss_create_export "$compartment_id" "$ad"
            fss_show_overview "$compartment_id"
            continue
        fi
        if [[ "$selection" == "cs" ]]; then
            fss_create_snapshot "$compartment_id" "$ad"
            fss_show_overview "$compartment_id"
            continue
        fi
        
        # View file system: f#
        if [[ "$selection" =~ ^f([0-9]+)$ ]]; then
            local sel_idx="${BASH_REMATCH[1]}"
            if [[ -n "${FSS_FS_MAP[$sel_idx]}" ]]; then
                fss_show_file_system_detail "${FSS_FS_MAP[$sel_idx]}"
            else
                echo -e "${RED}Invalid file system number: f${sel_idx}${NC}"
            fi
            continue
        fi
        
        # View mount target: m#
        if [[ "$selection" =~ ^m([0-9]+)$ ]]; then
            local sel_idx="${BASH_REMATCH[1]}"
            if [[ -n "${FSS_MT_MAP[$sel_idx]}" ]]; then
                fss_show_mount_target_detail "${FSS_MT_MAP[$sel_idx]}"
            else
                echo -e "${RED}Invalid mount target number: m${sel_idx}${NC}"
            fi
            continue
        fi
        
        # View export: e#
        if [[ "$selection" =~ ^e([0-9]+)$ ]]; then
            local sel_idx="${BASH_REMATCH[1]}"
            if [[ -n "${FSS_EXPORT_MAP[$sel_idx]}" ]]; then
                fss_show_export_detail "${FSS_EXPORT_MAP[$sel_idx]}"
            else
                echo -e "${RED}Invalid export number: e${sel_idx}${NC}"
            fi
            continue
        fi
        
        # Delete file system: df#
        if [[ "$selection" =~ ^df([0-9]+)$ ]]; then
            local sel_idx="${BASH_REMATCH[1]}"
            if [[ -n "${FSS_FS_MAP[$sel_idx]}" ]]; then
                FSS_SELECTED_FS="${FSS_FS_MAP[$sel_idx]}"
                fss_delete_file_system_direct "$compartment_id"
                fss_show_overview "$compartment_id"
            else
                echo -e "${RED}Invalid file system number: df${sel_idx}${NC}"
            fi
            continue
        fi
        
        # Delete mount target: dm#
        if [[ "$selection" =~ ^dm([0-9]+)$ ]]; then
            local sel_idx="${BASH_REMATCH[1]}"
            if [[ -n "${FSS_MT_MAP[$sel_idx]}" ]]; then
                FSS_SELECTED_MT="${FSS_MT_MAP[$sel_idx]}"
                fss_delete_mount_target_direct "$compartment_id"
                fss_show_overview "$compartment_id"
            else
                echo -e "${RED}Invalid mount target number: dm${sel_idx}${NC}"
            fi
            continue
        fi
        
        # Delete export: de#
        if [[ "$selection" =~ ^de([0-9]+)$ ]]; then
            local sel_idx="${BASH_REMATCH[1]}"
            if [[ -n "${FSS_EXPORT_MAP[$sel_idx]}" ]]; then
                FSS_SELECTED_EXPORT="${FSS_EXPORT_MAP[$sel_idx]}"
                fss_delete_export_direct "$compartment_id"
                fss_show_overview "$compartment_id"
            else
                echo -e "${RED}Invalid export number: de${sel_idx}${NC}"
            fi
            continue
        fi
        
        echo -e "${RED}Invalid selection${NC}"
    done
}


#--------------------------------------------------------------------------------
# FSS - Show Overview (Hierarchical: Mount Targets → Exports → File Systems)
#--------------------------------------------------------------------------------
fss_show_overview() {
    local compartment_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${WHITE}                                      FILE STORAGE SERVICE (FSS)                                                 ${NC}"
    echo -e "${BOLD}${WHITE}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Get availability domains
    echo -e "${CYAN}Getting availability domains...${NC}"
    local ads
    ads=$(fss_get_availability_domains "$compartment_id")
    
    if [[ -z "$ads" ]]; then
        echo -e "${RED}Unable to get availability domains${NC}"
        return 1
    fi
    
    # Clear global maps
    declare -gA FSS_FS_MAP
    declare -gA FSS_MT_MAP
    declare -gA FSS_EXPORT_MAP
    declare -gA FSS_FS_NAMES
    FSS_FS_MAP=()
    FSS_MT_MAP=()
    FSS_EXPORT_MAP=()
    FSS_FS_NAMES=()
    
    local fs_idx=0
    local mt_idx=0
    local export_idx=0
    
    #---------------------------------------------------------------------------
    # Gather all data first
    #---------------------------------------------------------------------------
    echo -e "${CYAN}Fetching file systems...${NC}"
    local all_fs_json="[]"
    while IFS= read -r ad; do
        [[ -z "$ad" ]] && continue
        local fs_json
        fs_json=$(oci fs file-system list \
            --compartment-id "$compartment_id" \
            --availability-domain "$ad" \
            --all \
            --output json 2>&1)
        if [[ $? -eq 0 ]]; then
            local fs_data
            fs_data=$(echo "$fs_json" | jq '.data // []' 2>/dev/null)
            all_fs_json=$(echo "$all_fs_json" "$fs_data" | jq -s 'add' 2>/dev/null)
        fi
    done <<< "$ads"
    
    echo -e "${CYAN}Fetching mount targets...${NC}"
    local all_mt_json="[]"
    while IFS= read -r ad; do
        [[ -z "$ad" ]] && continue
        local mt_json
        mt_json=$(oci fs mount-target list \
            --compartment-id "$compartment_id" \
            --availability-domain "$ad" \
            --all \
            --output json 2>&1)
        if [[ $? -eq 0 ]]; then
            local mt_data
            mt_data=$(echo "$mt_json" | jq '.data // []' 2>/dev/null)
            all_mt_json=$(echo "$all_mt_json" "$mt_data" | jq -s 'add' 2>/dev/null)
        fi
    done <<< "$ads"
    
    echo -e "${CYAN}Fetching exports...${NC}"
    local all_export_json
    all_export_json=$(oci fs export list \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>&1)
    if [[ $? -ne 0 ]]; then
        all_export_json='{"data":[]}'
    fi
    
    # Get private IPs for mount targets
    echo -e "${CYAN}Resolving private IPs...${NC}"
    declare -A MT_IPS
    while IFS='|' read -r mt_id ip_ids; do
        [[ -z "$mt_id" ]] && continue
        local first_ip_id
        first_ip_id=$(echo "$ip_ids" | jq -r '.[0] // empty' 2>/dev/null)
        if [[ -n "$first_ip_id" ]]; then
            local ip_addr
            ip_addr=$(oci network private-ip get --private-ip-id "$first_ip_id" --query 'data."ip-address"' --raw-output 2>/dev/null)
            MT_IPS[$mt_id]="$ip_addr"
        fi
    done < <(echo "$all_mt_json" | jq -r '.[] | "\(.id)|\(.["private-ip-ids"])"' 2>/dev/null)
    
    echo ""
    
    # Build file system lookup
    declare -A FS_INFO  # fs_id -> "name|state|metered_bytes|ad"
    while IFS='|' read -r fs_id fs_name fs_state fs_bytes fs_ad; do
        [[ -z "$fs_id" ]] && continue
        FS_INFO[$fs_id]="$fs_name|$fs_state|$fs_bytes|$fs_ad"
    done < <(echo "$all_fs_json" | jq -r '.[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["metered-bytes"])|\(.["availability-domain"])"' 2>/dev/null)
    
    # Build export lookup by export-set-id
    declare -A EXPORTS_BY_SET  # export_set_id -> "export_id|path|fs_id;export_id|path|fs_id;..."
    while IFS='|' read -r export_id export_path export_set_id fs_id export_state; do
        [[ -z "$export_id" ]] && continue
        if [[ -n "${EXPORTS_BY_SET[$export_set_id]}" ]]; then
            EXPORTS_BY_SET[$export_set_id]="${EXPORTS_BY_SET[$export_set_id]};$export_id|$export_path|$fs_id|$export_state"
        else
            EXPORTS_BY_SET[$export_set_id]="$export_id|$export_path|$fs_id|$export_state"
        fi
    done < <(echo "$all_export_json" | jq -r '.data[] | "\(.id)|\(.path)|\(.["export-set-id"])|\(.["file-system-id"])|\(.["lifecycle-state"])"' 2>/dev/null)
    
    # Track which file systems have exports
    declare -A FS_HAS_EXPORT
    
    #---------------------------------------------------------------------------
    # Display Mount Targets with Exports and File Systems
    #---------------------------------------------------------------------------
    local mt_count
    mt_count=$(echo "$all_mt_json" | jq 'length' 2>/dev/null) || mt_count=0
    
    if [[ "$mt_count" -gt 0 ]]; then
        echo -e "${BOLD}${WHITE}MOUNT TARGETS WITH EXPORTS${NC}"
        echo ""
        
        while IFS='|' read -r mt_id mt_name mt_state mt_ad export_set_id; do
            [[ -z "$mt_id" ]] && continue
            ((mt_idx++))
            
            FSS_MT_MAP[$mt_idx]="$mt_id"
            
            local mt_state_color="$GREEN"
            case "$mt_state" in
                ACTIVE) mt_state_color="$GREEN" ;;
                CREATING|UPDATING) mt_state_color="$YELLOW" ;;
                DELETING|DELETED|FAILED) mt_state_color="$RED" ;;
                *) mt_state_color="$GRAY" ;;
            esac
            
            local ad_short="${mt_ad##*:}"
            local mt_ip="${MT_IPS[$mt_id]:-N/A}"
            
            echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
            echo -e "${BOLD}${CYAN}│${NC} ${YELLOW}[m${mt_idx}]${NC} ${BOLD}${WHITE}${mt_name}${NC}  ${mt_state_color}${mt_state}${NC}"
            echo -e "${BOLD}${CYAN}│${NC}     ${CYAN}IP:${NC} ${WHITE}${mt_ip}${NC}  ${CYAN}AD:${NC} ${WHITE}${ad_short}${NC}"
            echo -e "${BOLD}${CYAN}│${NC}     ${GRAY}${mt_id}${NC}"
            
            # Get exports for this mount target
            local exports="${EXPORTS_BY_SET[$export_set_id]}"
            
            if [[ -n "$exports" ]]; then
                echo -e "${BOLD}${CYAN}│${NC}"
                echo -e "${BOLD}${CYAN}│${NC}     ${BOLD}${WHITE}Exports:${NC}"
                
                # Parse exports (semicolon separated)
                IFS=';' read -ra EXPORT_ARRAY <<< "$exports"
                local exp_count=${#EXPORT_ARRAY[@]}
                local exp_i=0
                
                for export_entry in "${EXPORT_ARRAY[@]}"; do
                    ((exp_i++))
                    ((export_idx++))
                    
                    IFS='|' read -r exp_id exp_path exp_fs_id exp_state <<< "$export_entry"
                    FSS_EXPORT_MAP[$export_idx]="$exp_id"
                    
                    # Mark file system as having export
                    FS_HAS_EXPORT[$exp_fs_id]=1
                    
                    # Get file system info
                    local fs_info="${FS_INFO[$exp_fs_id]}"
                    local fs_name fs_state fs_bytes fs_ad
                    IFS='|' read -r fs_name fs_state fs_bytes fs_ad <<< "$fs_info"
                    
                    # Find fs_idx for this file system
                    local this_fs_idx=""
                    for i in "${!FSS_FS_MAP[@]}"; do
                        if [[ "${FSS_FS_MAP[$i]}" == "$exp_fs_id" ]]; then
                            this_fs_idx=$i
                            break
                        fi
                    done
                    if [[ -z "$this_fs_idx" ]]; then
                        ((fs_idx++))
                        FSS_FS_MAP[$fs_idx]="$exp_fs_id"
                        FSS_FS_NAMES[$fs_idx]="$fs_name"
                        this_fs_idx=$fs_idx
                    fi
                    
                    local exp_state_color="$GREEN"
                    case "$exp_state" in
                        ACTIVE) exp_state_color="$GREEN" ;;
                        CREATING|UPDATING) exp_state_color="$YELLOW" ;;
                        DELETING|DELETED|FAILED) exp_state_color="$RED" ;;
                        *) exp_state_color="$GRAY" ;;
                    esac
                    
                    local fs_state_color="$GREEN"
                    case "$fs_state" in
                        ACTIVE) fs_state_color="$GREEN" ;;
                        CREATING|UPDATING) fs_state_color="$YELLOW" ;;
                        DELETING|DELETED|FAILED) fs_state_color="$RED" ;;
                        *) fs_state_color="$GRAY" ;;
                    esac
                    
                    # Convert bytes to human readable
                    local fs_size="0 B"
                    if [[ -n "$fs_bytes" && "$fs_bytes" != "null" && "$fs_bytes" -gt 0 ]] 2>/dev/null; then
                        if [[ "$fs_bytes" -ge 1073741824 ]]; then
                            fs_size="$(echo "scale=1; $fs_bytes / 1073741824" | bc) GB"
                        elif [[ "$fs_bytes" -ge 1048576 ]]; then
                            fs_size="$(echo "scale=1; $fs_bytes / 1048576" | bc) MB"
                        elif [[ "$fs_bytes" -ge 1024 ]]; then
                            fs_size="$(echo "scale=1; $fs_bytes / 1000" | bc) KB"
                        else
                            fs_size="${fs_bytes} B"
                        fi
                    fi
                    
                    # Tree characters
                    local tree_char="├──"
                    local tree_cont="│  "
                    if [[ $exp_i -eq $exp_count ]]; then
                        tree_char="└──"
                        tree_cont="   "
                    fi
                    
                    echo -e "${BOLD}${CYAN}│${NC}     ${tree_char} ${YELLOW}[e${export_idx}]${NC} ${WHITE}${exp_path}${NC}  ${exp_state_color}${exp_state}${NC}"
                    echo -e "${BOLD}${CYAN}│${NC}     ${tree_cont}    └── ${YELLOW}[f${this_fs_idx}]${NC} ${WHITE}${fs_name:-N/A}${NC}  ${fs_state_color}${fs_state:-N/A}${NC}  ${CYAN}Size:${NC} ${WHITE}${fs_size}${NC}"
                    
                done
            else
                echo -e "${BOLD}${CYAN}│${NC}     ${GRAY}(No exports configured)${NC}"
            fi
            
            echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
            echo ""
            
        done < <(echo "$all_mt_json" | jq -r '.[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["availability-domain"])|\(.["export-set-id"])"' 2>/dev/null)
    fi
    
    #---------------------------------------------------------------------------
    # Display Standalone File Systems (no exports)
    #---------------------------------------------------------------------------
    local standalone_fs=""
    while IFS='|' read -r fs_id fs_name fs_state fs_bytes fs_ad; do
        [[ -z "$fs_id" ]] && continue
        if [[ -z "${FS_HAS_EXPORT[$fs_id]}" ]]; then
            standalone_fs="${standalone_fs}${fs_id}|${fs_name}|${fs_state}|${fs_bytes}|${fs_ad}\n"
        fi
    done < <(echo "$all_fs_json" | jq -r '.[] | "\(.id)|\(.["display-name"])|\(.["lifecycle-state"])|\(.["metered-bytes"])|\(.["availability-domain"])"' 2>/dev/null)
    
    if [[ -n "$standalone_fs" ]]; then
        echo -e "${BOLD}${WHITE}STANDALONE FILE SYSTEMS ${GRAY}(no exports)${NC}"
        echo ""
        
        echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        
        while IFS='|' read -r fs_id fs_name fs_state fs_bytes fs_ad; do
            [[ -z "$fs_id" ]] && continue
            ((fs_idx++))
            
            FSS_FS_MAP[$fs_idx]="$fs_id"
            FSS_FS_NAMES[$fs_idx]="$fs_name"
            
            local fs_state_color="$GREEN"
            case "$fs_state" in
                ACTIVE) fs_state_color="$GREEN" ;;
                CREATING|UPDATING) fs_state_color="$YELLOW" ;;
                DELETING|DELETED|FAILED) fs_state_color="$RED" ;;
                *) fs_state_color="$GRAY" ;;
            esac
            
            local ad_short="${fs_ad##*:}"
            
            # Convert bytes to human readable
            local fs_size="0 B"
            if [[ -n "$fs_bytes" && "$fs_bytes" != "null" && "$fs_bytes" -gt 0 ]] 2>/dev/null; then
                if [[ "$fs_bytes" -ge 1073741824 ]]; then
                    fs_size="$(echo "scale=1; $fs_bytes / 1073741824" | bc) GB"
                elif [[ "$fs_bytes" -ge 1048576 ]]; then
                    fs_size="$(echo "scale=1; $fs_bytes / 1048576" | bc) MB"
                elif [[ "$fs_bytes" -ge 1024 ]]; then
                    fs_size="$(echo "scale=1; $fs_bytes / 1000" | bc) KB"
                else
                    fs_size="${fs_bytes} B"
                fi
            fi
            
            echo -e "${BOLD}${CYAN}│${NC} ${YELLOW}[f${fs_idx}]${NC} ${WHITE}${fs_name}${NC}  ${fs_state_color}${fs_state}${NC}  ${CYAN}Size:${NC} ${WHITE}${fs_size}${NC}  ${CYAN}AD:${NC} ${WHITE}${ad_short}${NC}"
            echo -e "${BOLD}${CYAN}│${NC}      ${GRAY}${fs_id}${NC}"
            
        done < <(echo -e "$standalone_fs")
        
        echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        echo ""
    fi
    
    # Store counts
    FSS_FS_COUNT=$fs_idx
    FSS_MT_COUNT=$mt_idx
    FSS_EXPORT_COUNT=$export_idx
    
    #---------------------------------------------------------------------------
    # Summary
    #---------------------------------------------------------------------------
    echo -e "${BOLD}${WHITE}═══ Summary ═══${NC}"
    echo -e "  Mount Targets: ${GREEN}$mt_idx${NC}"
    echo -e "  Exports:       ${GREEN}$export_idx${NC}"
    echo -e "  File Systems:  ${GREEN}$fs_idx${NC}"
    echo ""
    
    # NFS mount example
    if [[ $mt_idx -gt 0 && $export_idx -gt 0 ]]; then
        local sample_ip="${MT_IPS[${FSS_MT_MAP[1]}]:-<mount-target-ip>}"
        echo -e "${BOLD}${WHITE}═══ NFS Mount Example ═══${NC}"
        echo -e "  ${GRAY}sudo mount -t nfs -o nfsvers=3 ${sample_ip}:/<export-path> /mnt/fss${NC}"
        echo ""
    fi
}

#--------------------------------------------------------------------------------
# FSS - Show File System Detail
#--------------------------------------------------------------------------------
fss_show_file_system_detail() {
    local fs_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ File System Details ═══${NC}"
    echo ""
    
    local get_cmd="oci fs file-system get --file-system-id \"$fs_id\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local fs_json
    fs_json=$(oci fs file-system get --file-system-id "$fs_id" --output json 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Error getting file system: ${NC}"
        echo "$fs_json"
        return
    fi
    
    local name state ad metered_bytes time_created
    name=$(echo "$fs_json" | jq -r '.data["display-name"] // "N/A"')
    state=$(echo "$fs_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    ad=$(echo "$fs_json" | jq -r '.data["availability-domain"] // "N/A"')
    metered_bytes=$(echo "$fs_json" | jq -r '.data["metered-bytes"] // 0')
    time_created=$(echo "$fs_json" | jq -r '.data["time-created"] // "N/A"')
    
    local metered_gb="0"
    [[ -n "$metered_bytes" && "$metered_bytes" != "null" ]] && metered_gb=$(echo "scale=2; $metered_bytes / 1073741824" | bc 2>/dev/null || echo "0")
    
    echo -e "  ${CYAN}Name:${NC}              ${WHITE}$name${NC}"
    echo -e "  ${CYAN}State:${NC}             ${WHITE}$state${NC}"
    echo -e "  ${CYAN}Availability Domain:${NC} ${WHITE}$ad${NC}"
    echo -e "  ${CYAN}Metered Size:${NC}      ${WHITE}${metered_gb} GB${NC}"
    echo -e "  ${CYAN}Created:${NC}           ${WHITE}$time_created${NC}"
    echo -e "  ${CYAN}OCID:${NC}              ${YELLOW}$fs_id${NC}"
    echo ""
}

#--------------------------------------------------------------------------------
# FSS - Show Mount Target Detail
#--------------------------------------------------------------------------------
fss_show_mount_target_detail() {
    local mt_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Mount Target Details ═══${NC}"
    echo ""
    
    local get_cmd="oci fs mount-target get --mount-target-id \"$mt_id\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local mt_json
    mt_json=$(oci fs mount-target get --mount-target-id "$mt_id" --output json 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Error getting mount target: ${NC}"
        echo "$mt_json"
        return
    fi
    
    local name state ad subnet_id export_set_id time_created
    name=$(echo "$mt_json" | jq -r '.data["display-name"] // "N/A"')
    state=$(echo "$mt_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    ad=$(echo "$mt_json" | jq -r '.data["availability-domain"] // "N/A"')
    subnet_id=$(echo "$mt_json" | jq -r '.data["subnet-id"] // "N/A"')
    export_set_id=$(echo "$mt_json" | jq -r '.data["export-set-id"] // "N/A"')
    time_created=$(echo "$mt_json" | jq -r '.data["time-created"] // "N/A"')
    
    # Get private IP
    local private_ip="N/A"
    local private_ip_ids
    private_ip_ids=$(echo "$mt_json" | jq -r '.data["private-ip-ids"][]' 2>/dev/null)
    if [[ -n "$private_ip_ids" ]]; then
        local first_ip_id
        first_ip_id=$(echo "$private_ip_ids" | head -1)
        private_ip=$(oci network private-ip get --private-ip-id "$first_ip_id" --query 'data."ip-address"' --raw-output 2>/dev/null) || private_ip="N/A"
    fi
    
    echo -e "  ${CYAN}Name:${NC}              ${WHITE}$name${NC}"
    echo -e "  ${CYAN}State:${NC}             ${WHITE}$state${NC}"
    echo -e "  ${CYAN}Availability Domain:${NC} ${WHITE}$ad${NC}"
    echo -e "  ${CYAN}Private IP:${NC}        ${WHITE}$private_ip${NC}"
    echo -e "  ${CYAN}Subnet OCID:${NC}       ${YELLOW}$subnet_id${NC}"
    echo -e "  ${CYAN}Export Set OCID:${NC}   ${YELLOW}$export_set_id${NC}"
    echo -e "  ${CYAN}Created:${NC}           ${WHITE}$time_created${NC}"
    echo -e "  ${CYAN}OCID:${NC}              ${YELLOW}$mt_id${NC}"
    echo ""
    
    # Show mount command
    if [[ "$private_ip" != "N/A" ]]; then
        echo -e "${BOLD}${WHITE}═══ Mount Command ═══${NC}"
        echo -e "  ${GREEN}sudo mount -t nfs -o nfsvers=3 ${private_ip}:/<export_path> /mnt/<mount_point>${NC}"
        echo ""
    fi
}

#--------------------------------------------------------------------------------
# FSS - Show Export Detail
#--------------------------------------------------------------------------------
fss_show_export_detail() {
    local export_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Export Details ═══${NC}"
    echo ""
    
    local get_cmd="oci fs export get --export-id \"$export_id\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local export_json
    export_json=$(oci fs export get --export-id "$export_id" --output json 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Error getting export: ${NC}"
        echo "$export_json"
        return
    fi
    
    local path state fs_id export_set_id time_created
    path=$(echo "$export_json" | jq -r '.data.path // "N/A"')
    state=$(echo "$export_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    fs_id=$(echo "$export_json" | jq -r '.data["file-system-id"] // "N/A"')
    export_set_id=$(echo "$export_json" | jq -r '.data["export-set-id"] // "N/A"')
    time_created=$(echo "$export_json" | jq -r '.data["time-created"] // "N/A"')
    
    echo -e "  ${CYAN}Path:${NC}              ${WHITE}$path${NC}"
    echo -e "  ${CYAN}State:${NC}             ${WHITE}$state${NC}"
    echo -e "  ${CYAN}File System OCID:${NC}  ${YELLOW}$fs_id${NC}"
    echo -e "  ${CYAN}Export Set OCID:${NC}   ${YELLOW}$export_set_id${NC}"
    echo -e "  ${CYAN}Created:${NC}           ${WHITE}$time_created${NC}"
    echo -e "  ${CYAN}OCID:${NC}              ${YELLOW}$export_id${NC}"
    echo ""
    
    # Show export options
    echo -e "${BOLD}${WHITE}═══ Export Options ═══${NC}"
    echo "$export_json" | jq -r '.data["export-options"][]? | "  Source: \(.source // "N/A"), Access: \(.access // "N/A"), Identity: \(.["identity-squash"] // "N/A")"' 2>/dev/null
    echo ""
}

#--------------------------------------------------------------------------------
# FSS - Delete File System Direct (with confirmation)
#--------------------------------------------------------------------------------
fss_delete_file_system_direct() {
    local compartment_id="$1"
    local log_file="${MAINTENANCE_LOG_FILE:-./logs/k8s_maintenance_$(date +%Y%m%d).log}"
    
    echo ""
    echo -e "${BOLD}${RED}═══ Delete File System ═══${NC}"
    echo ""
    
    local delete_cmd="oci fs file-system delete --file-system-id \"$FSS_SELECTED_FS\" --force"
    echo -e "${RED}Command: $delete_cmd${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm deletion: ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Deletion cancelled${NC}"
        return
    fi
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] EXECUTING: $delete_cmd" >> "$log_file"
    echo -e "${GRAY}$delete_cmd${NC}"
    
    local result
    result=$(oci fs file-system delete --file-system-id "$FSS_SELECTED_FS" --force 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}File system deletion initiated${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Deleted $FSS_SELECTED_FS" >> "$log_file"
    else
        echo -e "${RED}Failed to delete file system: $result${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: Delete $FSS_SELECTED_FS - $result" >> "$log_file"
    fi
}

#--------------------------------------------------------------------------------
# FSS - Delete Mount Target Direct (with confirmation)
#--------------------------------------------------------------------------------
fss_delete_mount_target_direct() {
    local compartment_id="$1"
    local log_file="${MAINTENANCE_LOG_FILE:-./logs/k8s_maintenance_$(date +%Y%m%d).log}"
    
    echo ""
    echo -e "${BOLD}${RED}═══ Delete Mount Target ═══${NC}"
    echo ""
    
    local delete_cmd="oci fs mount-target delete --mount-target-id \"$FSS_SELECTED_MT\" --force"
    echo -e "${RED}Command: $delete_cmd${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm deletion: ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Deletion cancelled${NC}"
        return
    fi
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] EXECUTING: $delete_cmd" >> "$log_file"
    echo -e "${GRAY}$delete_cmd${NC}"
    
    local result
    result=$(oci fs mount-target delete --mount-target-id "$FSS_SELECTED_MT" --force 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Mount target deletion initiated${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Deleted $FSS_SELECTED_MT" >> "$log_file"
    else
        echo -e "${RED}Failed to delete mount target: $result${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: Delete $FSS_SELECTED_MT - $result" >> "$log_file"
    fi
}

#--------------------------------------------------------------------------------
# FSS - Delete Export Direct (with confirmation)
#--------------------------------------------------------------------------------
fss_delete_export_direct() {
    local compartment_id="$1"
    local log_file="${MAINTENANCE_LOG_FILE:-./logs/k8s_maintenance_$(date +%Y%m%d).log}"
    
    echo ""
    echo -e "${BOLD}${RED}═══ Delete Export ═══${NC}"
    echo ""
    
    local delete_cmd="oci fs export delete --export-id \"$FSS_SELECTED_EXPORT\" --force"
    echo -e "${RED}Command: $delete_cmd${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm deletion: ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Deletion cancelled${NC}"
        return
    fi
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] EXECUTING: $delete_cmd" >> "$log_file"
    echo -e "${GRAY}$delete_cmd${NC}"
    
    local result
    result=$(oci fs export delete --export-id "$FSS_SELECTED_EXPORT" --force 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Export deletion initiated${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Deleted $FSS_SELECTED_EXPORT" >> "$log_file"
    else
        echo -e "${RED}Failed to delete export: $result${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: Delete $FSS_SELECTED_EXPORT - $result" >> "$log_file"
    fi
}

#--------------------------------------------------------------------------------
# FSS - List File Systems
#--------------------------------------------------------------------------------
fss_list_file_systems() {
    local compartment_id="$1"
    local ad="$2"
    local action="${3:-none}"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ File Systems ═══${NC}"
    echo ""
    
    local fs_json
    local all_fs_json="[]"
    
    if [[ -n "$ad" ]]; then
        # Single AD specified
        local list_cmd="oci fs file-system list --compartment-id \"$compartment_id\" --availability-domain \"$ad\" --all --output json"
        echo -e "${GRAY}$list_cmd${NC}"
        echo ""
        
        fs_json=$(oci fs file-system list \
            --compartment-id "$compartment_id" \
            --availability-domain "$ad" \
            --all \
            --output json 2>&1)
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}Error listing file systems:${NC}"
            echo "$fs_json" | while IFS= read -r line; do echo -e "${RED}  $line${NC}"; done
            return 1
        fi
        
        all_fs_json=$(echo "$fs_json" | jq '.data // []' 2>/dev/null)
    else
        # No AD specified - iterate through all ADs
        echo -e "${CYAN}Getting availability domains...${NC}"
        local ads
        ads=$(fss_get_availability_domains "$compartment_id")
        
        if [[ -z "$ads" ]]; then
            echo -e "${RED}Unable to get availability domains${NC}"
            return 1
        fi
        
        while IFS= read -r ad_name; do
            [[ -z "$ad_name" ]] && continue
            
            local list_cmd="oci fs file-system list --compartment-id \"$compartment_id\" --availability-domain \"$ad_name\" --all --output json"
            echo -e "${GRAY}$list_cmd${NC}"
            
            fs_json=$(oci fs file-system list \
                --compartment-id "$compartment_id" \
                --availability-domain "$ad_name" \
                --all \
                --output json 2>&1)
            
            if [[ $? -ne 0 ]]; then
                echo -e "${RED}Error listing file systems in $ad_name:${NC}"
                echo "$fs_json" | head -3 | while IFS= read -r line; do echo -e "${RED}  $line${NC}"; done
                continue
            fi
            
            local fs_data
            fs_data=$(echo "$fs_json" | jq '.data // []' 2>/dev/null)
            all_fs_json=$(echo "$all_fs_json" "$fs_data" | jq -s 'add' 2>/dev/null)
            
        done <<< "$ads"
        echo ""
    fi
    
    local fs_count
    fs_count=$(echo "$all_fs_json" | jq 'length' 2>/dev/null) || fs_count=0
    
    if [[ "$fs_count" -eq 0 ]]; then
        echo -e "${YELLOW}No file systems found${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Found $fs_count file system(s)${NC}"
    echo ""
    
    printf "${BOLD}%-3s %-35s %-12s %-15s %-20s %s${NC}\n" "#" "Display Name" "State" "Metered (GB)" "Availability Domain" "File System OCID"
    print_separator 180
    
    local idx=0
    declare -gA FSS_FS_MAP
    FSS_FS_MAP=()
    
    while IFS='|' read -r display_name state metered_bytes ad_name fs_id; do
        [[ -z "$display_name" ]] && continue
        ((idx++))
        
        FSS_FS_MAP[$idx]="$fs_id"
        
        local state_color="$GREEN"
        case "$state" in
            ACTIVE) state_color="$GREEN" ;;
            CREATING|UPDATING) state_color="$YELLOW" ;;
            DELETING|DELETED|FAILED) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        
        local name_trunc="${display_name:0:33}"
        [[ ${#display_name} -gt 33 ]] && name_trunc="${name_trunc}.."
        
        # Convert bytes to GB
        local metered_gb="0"
        [[ -n "$metered_bytes" && "$metered_bytes" != "null" ]] && metered_gb=$(echo "scale=2; $metered_bytes / 1073741824" | bc 2>/dev/null || echo "0")
        
        # Extract AD name (last part)
        local ad_short="${ad_name##*:}"
        
        printf "${YELLOW}%-3s${NC} %-35s ${state_color}%-12s${NC} %-15s %-20s ${GRAY}%s${NC}\n" \
            "$idx" "$name_trunc" "$state" "${metered_gb}" "$ad_short" "$fs_id"
            
    done < <(echo "$all_fs_json" | jq -r '.[] | "\(.["display-name"])|\(.["lifecycle-state"])|\(.["metered-bytes"])|\(.["availability-domain"])|\(.id)"' 2>/dev/null)
    
    FSS_FS_COUNT=$idx
    echo ""
    
    case "$action" in
        none)
            echo -e "Press Enter to continue..."
            read -r
            ;;
        select)
            echo -n -e "${CYAN}Enter file system # (or Enter to cancel): ${NC}"
            read -r fs_selection
            if [[ -n "$fs_selection" && -n "${FSS_FS_MAP[$fs_selection]}" ]]; then
                FSS_SELECTED_FS="${FSS_FS_MAP[$fs_selection]}"
            fi
            ;;
    esac
    
    return 0
}

#--------------------------------------------------------------------------------
# FSS - View File System Details
#--------------------------------------------------------------------------------
fss_view_file_system_details() {
    local compartment_id="$1"
    local ad="$2"
    
    FSS_SELECTED_FS=""
    fss_list_file_systems "$compartment_id" "$ad" "select"
    
    [[ -z "$FSS_SELECTED_FS" ]] && return
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ File System Details ═══${NC}"
    echo ""
    
    local get_cmd="oci fs file-system get --file-system-id \"$FSS_SELECTED_FS\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local fs_json
    fs_json=$(oci fs file-system get --file-system-id "$FSS_SELECTED_FS" --output json 2>/dev/null)
    
    if [[ -z "$fs_json" || "$fs_json" == "null" ]]; then
        echo -e "${RED}Failed to get file system details${NC}"
        return
    fi
    
    local display_name state metered_bytes ad_name time_created fs_id
    display_name=$(echo "$fs_json" | jq -r '.data["display-name"] // "N/A"')
    state=$(echo "$fs_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    metered_bytes=$(echo "$fs_json" | jq -r '.data["metered-bytes"] // "0"')
    ad_name=$(echo "$fs_json" | jq -r '.data["availability-domain"] // "N/A"')
    time_created=$(echo "$fs_json" | jq -r '.data["time-created"] // "N/A"')
    fs_id=$(echo "$fs_json" | jq -r '.data.id // "N/A"')
    
    local metered_gb
    metered_gb=$(echo "scale=2; $metered_bytes / 1073741824" | bc 2>/dev/null || echo "0")
    
    local state_color="$GREEN"
    case "$state" in
        ACTIVE) state_color="$GREEN" ;;
        CREATING|UPDATING) state_color="$YELLOW" ;;
        *) state_color="$RED" ;;
    esac
    
    echo -e "  ${CYAN}Display Name:${NC}        ${WHITE}$display_name${NC}"
    echo -e "  ${CYAN}State:${NC}               ${state_color}$state${NC}"
    echo -e "  ${CYAN}Metered Size:${NC}        ${WHITE}${metered_gb} GB${NC}"
    echo -e "  ${CYAN}Availability Domain:${NC} ${WHITE}$ad_name${NC}"
    echo -e "  ${CYAN}Time Created:${NC}        ${WHITE}$time_created${NC}"
    echo -e "  ${CYAN}File System OCID:${NC}    ${YELLOW}$fs_id${NC}"
    echo ""
    
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# FSS - Create File System
#--------------------------------------------------------------------------------
fss_create_file_system() {
    local compartment_id="$1"
    local ad="$2"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Create File System ═══${NC}"
    echo ""
    
    # Get AD if not set
    if [[ -z "$ad" ]]; then
        echo -e "${CYAN}Available Availability Domains:${NC}"
        local ads_json
        ads_json=$(oci iam availability-domain list --compartment-id "$compartment_id" --output json 2>/dev/null)
        
        local idx=0
        declare -A AD_MAP
        while read -r ad_name; do
            [[ -z "$ad_name" ]] && continue
            ((idx++))
            AD_MAP[$idx]="$ad_name"
            echo -e "  ${YELLOW}$idx${NC}) $ad_name"
        done < <(echo "$ads_json" | jq -r '.data[].name' 2>/dev/null)
        
        echo ""
        echo -n -e "${CYAN}Select AD #: ${NC}"
        read -r ad_selection
        ad="${AD_MAP[$ad_selection]}"
        
        if [[ -z "$ad" ]]; then
            echo -e "${RED}Invalid selection${NC}"
            return
        fi
    fi
    
    echo -n -e "${CYAN}Enter display name for file system: ${NC}"
    read -r fs_name
    
    if [[ -z "$fs_name" ]]; then
        echo -e "${RED}Display name is required${NC}"
        return
    fi
    
    echo ""
    local create_cmd="oci fs file-system create --compartment-id \"$compartment_id\" --availability-domain \"$ad\" --display-name \"$fs_name\""
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$create_cmd${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Proceed with creation? (y/N): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    # Log the action
    local log_file="${LOG_DIR:-/tmp}/fss_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CREATE FILE SYSTEM: $create_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Creating file system...${NC}"
    
    local result
    result=$(oci fs file-system create \
        --compartment-id "$compartment_id" \
        --availability-domain "$ad" \
        --display-name "$fs_name" \
        --output json 2>&1)
    
    if echo "$result" | jq -e '.data.id' > /dev/null 2>&1; then
        local new_fs_id
        new_fs_id=$(echo "$result" | jq -r '.data.id')
        echo -e "${GREEN}✓ File system created successfully${NC}"
        echo -e "  ${CYAN}OCID:${NC} ${YELLOW}$new_fs_id${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Created $new_fs_id" >> "$log_file"
    else
        echo -e "${RED}Failed to create file system${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# FSS - Update File System
#--------------------------------------------------------------------------------
fss_update_file_system() {
    local compartment_id="$1"
    local ad="$2"
    
    FSS_SELECTED_FS=""
    fss_list_file_systems "$compartment_id" "$ad" "select"
    
    [[ -z "$FSS_SELECTED_FS" ]] && return
    
    echo ""
    echo -n -e "${CYAN}Enter new display name: ${NC}"
    read -r new_name
    
    if [[ -z "$new_name" ]]; then
        echo -e "${RED}Display name is required${NC}"
        return
    fi
    
    echo ""
    local update_cmd="oci fs file-system update --file-system-id \"$FSS_SELECTED_FS\" --display-name \"$new_name\""
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$update_cmd${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Proceed with update? (y/N): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/fss_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] UPDATE FILE SYSTEM: $update_cmd" >> "$log_file"
    
    local result
    result=$(oci fs file-system update \
        --file-system-id "$FSS_SELECTED_FS" \
        --display-name "$new_name" \
        --output json 2>&1)
    
    if echo "$result" | jq -e '.data.id' > /dev/null 2>&1; then
        echo -e "${GREEN}✓ File system updated successfully${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Updated $FSS_SELECTED_FS" >> "$log_file"
    else
        echo -e "${RED}Failed to update file system${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# FSS - Delete File System
#--------------------------------------------------------------------------------
fss_delete_file_system() {
    local compartment_id="$1"
    local ad="$2"
    
    FSS_SELECTED_FS=""
    fss_list_file_systems "$compartment_id" "$ad" "select"
    
    [[ -z "$FSS_SELECTED_FS" ]] && return
    
    echo ""
    echo -e "${RED}WARNING: This will permanently delete the file system and all its data!${NC}"
    echo ""
    local delete_cmd="oci fs file-system delete --file-system-id \"$FSS_SELECTED_FS\" --force"
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$delete_cmd${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm: ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/fss_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DELETE FILE SYSTEM: $delete_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Deleting file system...${NC}"
    
    local result
    result=$(oci fs file-system delete \
        --file-system-id "$FSS_SELECTED_FS" \
        --force 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ File system deletion initiated${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Deleted $FSS_SELECTED_FS" >> "$log_file"
    else
        echo -e "${RED}Failed to delete file system${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# FSS - List Mount Targets
#--------------------------------------------------------------------------------
fss_list_mount_targets() {
    local compartment_id="$1"
    local ad="$2"
    local action="${3:-none}"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Mount Targets ═══${NC}"
    echo ""
    
    local mt_json
    local all_mt_json="[]"
    
    if [[ -n "$ad" ]]; then
        # Single AD specified
        local list_cmd="oci fs mount-target list --compartment-id \"$compartment_id\" --availability-domain \"$ad\" --all --output json"
        echo -e "${GRAY}$list_cmd${NC}"
        echo ""
        
        mt_json=$(oci fs mount-target list \
            --compartment-id "$compartment_id" \
            --availability-domain "$ad" \
            --all \
            --output json 2>&1)
        
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}Error listing mount targets:${NC}"
            echo "$mt_json" | while IFS= read -r line; do echo -e "${RED}  $line${NC}"; done
            return 1
        fi
        
        all_mt_json=$(echo "$mt_json" | jq '.data // []' 2>/dev/null)
    else
        # No AD specified - iterate through all ADs
        echo -e "${CYAN}Getting availability domains...${NC}"
        local ads
        ads=$(fss_get_availability_domains "$compartment_id")
        
        if [[ -z "$ads" ]]; then
            echo -e "${RED}Unable to get availability domains${NC}"
            return 1
        fi
        
        while IFS= read -r ad_name; do
            [[ -z "$ad_name" ]] && continue
            
            local list_cmd="oci fs mount-target list --compartment-id \"$compartment_id\" --availability-domain \"$ad_name\" --all --output json"
            echo -e "${GRAY}$list_cmd${NC}"
            
            mt_json=$(oci fs mount-target list \
                --compartment-id "$compartment_id" \
                --availability-domain "$ad_name" \
                --all \
                --output json 2>&1)
            
            if [[ $? -ne 0 ]]; then
                echo -e "${RED}Error listing mount targets in $ad_name:${NC}"
                echo "$mt_json" | head -3 | while IFS= read -r line; do echo -e "${RED}  $line${NC}"; done
                continue
            fi
            
            local mt_data
            mt_data=$(echo "$mt_json" | jq '.data // []' 2>/dev/null)
            all_mt_json=$(echo "$all_mt_json" "$mt_data" | jq -s 'add' 2>/dev/null)
            
        done <<< "$ads"
        echo ""
    fi
    
    local mt_count
    mt_count=$(echo "$all_mt_json" | jq 'length' 2>/dev/null) || mt_count=0
    
    if [[ "$mt_count" -eq 0 ]]; then
        echo -e "${YELLOW}No mount targets found${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Found $mt_count mount target(s)${NC}"
    echo ""
    
    printf "${BOLD}%-3s %-30s %-12s %-20s %-18s %s${NC}\n" "#" "Display Name" "State" "Availability Domain" "Private IP" "Mount Target OCID"
    print_separator 180
    
    local idx=0
    declare -gA FSS_MT_MAP
    FSS_MT_MAP=()
    
    while IFS='|' read -r display_name state ad_name private_ips mt_id; do
        [[ -z "$display_name" ]] && continue
        ((idx++))
        
        FSS_MT_MAP[$idx]="$mt_id"
        
        local state_color="$GREEN"
        case "$state" in
            ACTIVE) state_color="$GREEN" ;;
            CREATING|UPDATING) state_color="$YELLOW" ;;
            DELETING|DELETED|FAILED) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        
        local name_trunc="${display_name:0:28}"
        [[ ${#display_name} -gt 28 ]] && name_trunc="${name_trunc}.."
        
        local ad_short="${ad_name##*:}"
        
        # Extract first private IP
        local first_ip
        first_ip=$(echo "$private_ips" | jq -r '.[0] // "N/A"' 2>/dev/null)
        
        printf "${YELLOW}%-3s${NC} %-30s ${state_color}%-12s${NC} %-20s %-18s ${GRAY}%s${NC}\n" \
            "$idx" "$name_trunc" "$state" "$ad_short" "$first_ip" "$mt_id"
            
    done < <(echo "$all_mt_json" | jq -r '.[] | "\(.["display-name"])|\(.["lifecycle-state"])|\(.["availability-domain"])|\(.["private-ip-ids"])|\(.id)"' 2>/dev/null)
    
    FSS_MT_COUNT=$idx
    echo ""
    
    case "$action" in
        none)
            echo -e "Press Enter to continue..."
            read -r
            ;;
        select)
            echo -n -e "${CYAN}Enter mount target # (or Enter to cancel): ${NC}"
            read -r mt_selection
            if [[ -n "$mt_selection" && -n "${FSS_MT_MAP[$mt_selection]}" ]]; then
                FSS_SELECTED_MT="${FSS_MT_MAP[$mt_selection]}"
            fi
            ;;
    esac
    
    return 0
}

#--------------------------------------------------------------------------------
# FSS - View Mount Target Details (with mount commands)
#--------------------------------------------------------------------------------
fss_view_mount_target_details() {
    local compartment_id="$1"
    local ad="$2"
    
    FSS_SELECTED_MT=""
    fss_list_mount_targets "$compartment_id" "$ad" "select"
    
    [[ -z "$FSS_SELECTED_MT" ]] && return
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Mount Target Details ═══${NC}"
    echo ""
    
    local get_cmd="oci fs mount-target get --mount-target-id \"$FSS_SELECTED_MT\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local mt_json
    mt_json=$(oci fs mount-target get --mount-target-id "$FSS_SELECTED_MT" --output json 2>/dev/null)
    
    if [[ -z "$mt_json" || "$mt_json" == "null" ]]; then
        echo -e "${RED}Failed to get mount target details${NC}"
        return
    fi
    
    local display_name state ad_name subnet_id export_set_id time_created mt_id
    display_name=$(echo "$mt_json" | jq -r '.data["display-name"] // "N/A"')
    state=$(echo "$mt_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    ad_name=$(echo "$mt_json" | jq -r '.data["availability-domain"] // "N/A"')
    subnet_id=$(echo "$mt_json" | jq -r '.data["subnet-id"] // "N/A"')
    export_set_id=$(echo "$mt_json" | jq -r '.data["export-set-id"] // "N/A"')
    time_created=$(echo "$mt_json" | jq -r '.data["time-created"] // "N/A"')
    mt_id=$(echo "$mt_json" | jq -r '.data.id // "N/A"')
    
    # Get private IPs
    local private_ip_ids
    private_ip_ids=$(echo "$mt_json" | jq -r '.data["private-ip-ids"][]' 2>/dev/null)
    
    local state_color="$GREEN"
    case "$state" in
        ACTIVE) state_color="$GREEN" ;;
        CREATING|UPDATING) state_color="$YELLOW" ;;
        *) state_color="$RED" ;;
    esac
    
    echo -e "  ${CYAN}Display Name:${NC}        ${WHITE}$display_name${NC}"
    echo -e "  ${CYAN}State:${NC}               ${state_color}$state${NC}"
    echo -e "  ${CYAN}Availability Domain:${NC} ${WHITE}$ad_name${NC}"
    echo -e "  ${CYAN}Subnet OCID:${NC}         ${GRAY}$subnet_id${NC}"
    echo -e "  ${CYAN}Export Set OCID:${NC}     ${GRAY}$export_set_id${NC}"
    echo -e "  ${CYAN}Time Created:${NC}        ${WHITE}$time_created${NC}"
    echo -e "  ${CYAN}Mount Target OCID:${NC}   ${YELLOW}$mt_id${NC}"
    echo ""
    
    # Resolve private IPs to actual addresses
    if [[ -n "$private_ip_ids" ]]; then
        echo -e "${BOLD}${WHITE}Private IP Addresses:${NC}"
        for pip_id in $private_ip_ids; do
            local pip_json
            pip_json=$(oci network private-ip get --private-ip-id "$pip_id" --output json 2>/dev/null)
            local ip_addr
            ip_addr=$(echo "$pip_json" | jq -r '.data["ip-address"] // "N/A"')
            local hostname
            hostname=$(echo "$pip_json" | jq -r '.data["hostname-label"] // ""')
            echo -e "  ${CYAN}IP:${NC} ${WHITE}$ip_addr${NC}  ${GRAY}$hostname${NC}"
            
            # Show mount command example
            echo ""
            echo -e "${BOLD}${WHITE}Mount Command Examples:${NC}"
            echo -e "  ${GRAY}# Mount file system (replace <export-path> with actual export path)${NC}"
            echo -e "  ${WHITE}sudo mount -t nfs -o nfsvers=3 ${ip_addr}:/<export-path> /mnt/fss${NC}"
            echo ""
            echo -e "  ${GRAY}# For NFSv4:${NC}"
            echo -e "  ${WHITE}sudo mount -t nfs -o nfsvers=4 ${ip_addr}:/<export-path> /mnt/fss${NC}"
        done
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# FSS - Create Mount Target
#--------------------------------------------------------------------------------
fss_create_mount_target() {
    local compartment_id="$1"
    local ad="$2"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Create Mount Target ═══${NC}"
    echo ""
    
    # Get AD if not set
    if [[ -z "$ad" ]]; then
        echo -e "${CYAN}Available Availability Domains:${NC}"
        local ads_json
        ads_json=$(oci iam availability-domain list --compartment-id "$compartment_id" --output json 2>/dev/null)
        
        local idx=0
        declare -A AD_MAP
        while read -r ad_name; do
            [[ -z "$ad_name" ]] && continue
            ((idx++))
            AD_MAP[$idx]="$ad_name"
            echo -e "  ${YELLOW}$idx${NC}) $ad_name"
        done < <(echo "$ads_json" | jq -r '.data[].name' 2>/dev/null)
        
        echo ""
        echo -n -e "${CYAN}Select AD #: ${NC}"
        read -r ad_selection
        ad="${AD_MAP[$ad_selection]}"
        
        if [[ -z "$ad" ]]; then
            echo -e "${RED}Invalid selection${NC}"
            return
        fi
    fi
    
    # List subnets
    echo ""
    echo -e "${CYAN}Available Subnets:${NC}"
    local subnets_json
    subnets_json=$(oci network subnet list --compartment-id "$compartment_id" --all --output json 2>/dev/null)
    
    local idx=0
    declare -A SUBNET_MAP
    while IFS='|' read -r subnet_name subnet_id cidr; do
        [[ -z "$subnet_name" ]] && continue
        ((idx++))
        SUBNET_MAP[$idx]="$subnet_id"
        echo -e "  ${YELLOW}$idx${NC}) $subnet_name (${cidr})"
    done < <(echo "$subnets_json" | jq -r '.data[] | "\(.["display-name"])|\(.id)|\(.["cidr-block"])"' 2>/dev/null)
    
    echo ""
    echo -n -e "${CYAN}Select subnet #: ${NC}"
    read -r subnet_selection
    local subnet_id="${SUBNET_MAP[$subnet_selection]}"
    
    if [[ -z "$subnet_id" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return
    fi
    
    echo -n -e "${CYAN}Enter display name for mount target: ${NC}"
    read -r mt_name
    
    if [[ -z "$mt_name" ]]; then
        echo -e "${RED}Display name is required${NC}"
        return
    fi
    
    echo ""
    local create_cmd="oci fs mount-target create --compartment-id \"$compartment_id\" --availability-domain \"$ad\" --subnet-id \"$subnet_id\" --display-name \"$mt_name\""
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$create_cmd${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Proceed with creation? (y/N): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/fss_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CREATE MOUNT TARGET: $create_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Creating mount target...${NC}"
    
    local result
    result=$(oci fs mount-target create \
        --compartment-id "$compartment_id" \
        --availability-domain "$ad" \
        --subnet-id "$subnet_id" \
        --display-name "$mt_name" \
        --output json 2>&1)
    
    if echo "$result" | jq -e '.data.id' > /dev/null 2>&1; then
        local new_mt_id
        new_mt_id=$(echo "$result" | jq -r '.data.id')
        echo -e "${GREEN}✓ Mount target created successfully${NC}"
        echo -e "  ${CYAN}OCID:${NC} ${YELLOW}$new_mt_id${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Created $new_mt_id" >> "$log_file"
    else
        echo -e "${RED}Failed to create mount target${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# FSS - Delete Mount Target
#--------------------------------------------------------------------------------
fss_delete_mount_target() {
    local compartment_id="$1"
    local ad="$2"
    
    FSS_SELECTED_MT=""
    fss_list_mount_targets "$compartment_id" "$ad" "select"
    
    [[ -z "$FSS_SELECTED_MT" ]] && return
    
    echo ""
    echo -e "${RED}WARNING: This will delete the mount target!${NC}"
    echo ""
    local delete_cmd="oci fs mount-target delete --mount-target-id \"$FSS_SELECTED_MT\" --force"
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$delete_cmd${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm: ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/fss_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DELETE MOUNT TARGET: $delete_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Deleting mount target...${NC}"
    
    local result
    result=$(oci fs mount-target delete \
        --mount-target-id "$FSS_SELECTED_MT" \
        --force 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Mount target deletion initiated${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Deleted $FSS_SELECTED_MT" >> "$log_file"
    else
        echo -e "${RED}Failed to delete mount target${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# FSS - List Exports
#--------------------------------------------------------------------------------
fss_list_exports() {
    local compartment_id="$1"
    local action="${2:-none}"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Exports ═══${NC}"
    echo ""
    
    local list_cmd="oci fs export list --compartment-id \"$compartment_id\" --all --output json"
    echo -e "${GRAY}$list_cmd${NC}"
    echo ""
    
    local export_json
    export_json=$(oci fs export list \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$export_json" || "$export_json" == "null" ]]; then
        echo -e "${YELLOW}No exports found or unable to list${NC}"
        return 1
    fi
    
    local export_count
    export_count=$(echo "$export_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$export_count" -eq 0 ]]; then
        echo -e "${YELLOW}No exports found${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Found $export_count export(s)${NC}"
    echo ""
    
    printf "${BOLD}%-3s %-30s %-12s %-50s %s${NC}\n" "#" "Path" "State" "File System OCID" "Export OCID"
    print_separator 180
    
    local idx=0
    declare -gA FSS_EXPORT_MAP
    FSS_EXPORT_MAP=()
    
    while IFS='|' read -r path state fs_id export_id; do
        [[ -z "$path" ]] && continue
        ((idx++))
        
        FSS_EXPORT_MAP[$idx]="$export_id"
        
        local state_color="$GREEN"
        case "$state" in
            ACTIVE) state_color="$GREEN" ;;
            CREATING|UPDATING) state_color="$YELLOW" ;;
            DELETING|DELETED|FAILED) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        
        local path_trunc="${path:0:28}"
        [[ ${#path} -gt 28 ]] && path_trunc="${path_trunc}.."
        
        local fs_short="${fs_id:0:48}..."
        
        printf "${YELLOW}%-3s${NC} %-30s ${state_color}%-12s${NC} ${GRAY}%-50s %s${NC}\n" \
            "$idx" "$path_trunc" "$state" "$fs_short" "$export_id"
            
    done < <(echo "$export_json" | jq -r '.data[] | "\(.path)|\(.["lifecycle-state"])|\(.["file-system-id"])|\(.id)"' 2>/dev/null)
    
    FSS_EXPORT_COUNT=$idx
    echo ""
    
    case "$action" in
        none)
            echo -e "Press Enter to continue..."
            read -r
            ;;
        select)
            echo -n -e "${CYAN}Enter export # (or Enter to cancel): ${NC}"
            read -r export_selection
            if [[ -n "$export_selection" && -n "${FSS_EXPORT_MAP[$export_selection]}" ]]; then
                FSS_SELECTED_EXPORT="${FSS_EXPORT_MAP[$export_selection]}"
            fi
            ;;
    esac
    
    return 0
}

#--------------------------------------------------------------------------------
# FSS - Create Export
#--------------------------------------------------------------------------------
fss_create_export() {
    local compartment_id="$1"
    local ad="$2"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Create Export ═══${NC}"
    echo ""
    
    # Select file system
    echo -e "${CYAN}Select a file system to export:${NC}"
    FSS_SELECTED_FS=""
    fss_list_file_systems "$compartment_id" "$ad" "select"
    
    if [[ -z "$FSS_SELECTED_FS" ]]; then
        echo -e "${RED}No file system selected${NC}"
        return
    fi
    
    # Select mount target (to get export set)
    echo ""
    echo -e "${CYAN}Select a mount target:${NC}"
    FSS_SELECTED_MT=""
    fss_list_mount_targets "$compartment_id" "$ad" "select"
    
    if [[ -z "$FSS_SELECTED_MT" ]]; then
        echo -e "${RED}No mount target selected${NC}"
        return
    fi
    
    # Get export set ID from mount target
    local mt_json
    mt_json=$(oci fs mount-target get --mount-target-id "$FSS_SELECTED_MT" --output json 2>/dev/null)
    local export_set_id
    export_set_id=$(echo "$mt_json" | jq -r '.data["export-set-id"]')
    
    if [[ -z "$export_set_id" || "$export_set_id" == "null" ]]; then
        echo -e "${RED}Could not get export set from mount target${NC}"
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Enter export path (e.g., /myfs): ${NC}"
    read -r export_path
    
    if [[ -z "$export_path" ]]; then
        export_path="/${RANDOM}"
        echo -e "${YELLOW}Using default path: $export_path${NC}"
    fi
    
    echo ""
    local create_cmd="oci fs export create --file-system-id \"$FSS_SELECTED_FS\" --export-set-id \"$export_set_id\" --path \"$export_path\""
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$create_cmd${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Proceed with creation? (y/N): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/fss_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CREATE EXPORT: $create_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Creating export...${NC}"
    
    local result
    result=$(oci fs export create \
        --file-system-id "$FSS_SELECTED_FS" \
        --export-set-id "$export_set_id" \
        --path "$export_path" \
        --output json 2>&1)
    
    if echo "$result" | jq -e '.data.id' > /dev/null 2>&1; then
        local new_export_id
        new_export_id=$(echo "$result" | jq -r '.data.id')
        echo -e "${GREEN}✓ Export created successfully${NC}"
        echo -e "  ${CYAN}OCID:${NC} ${YELLOW}$new_export_id${NC}"
        echo -e "  ${CYAN}Path:${NC} ${WHITE}$export_path${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Created $new_export_id" >> "$log_file"
    else
        echo -e "${RED}Failed to create export${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# FSS - Delete Export
#--------------------------------------------------------------------------------
fss_delete_export() {
    local compartment_id="$1"
    
    FSS_SELECTED_EXPORT=""
    fss_list_exports "$compartment_id" "select"
    
    [[ -z "$FSS_SELECTED_EXPORT" ]] && return
    
    echo ""
    echo -e "${RED}WARNING: This will delete the export!${NC}"
    echo ""
    local delete_cmd="oci fs export delete --export-id \"$FSS_SELECTED_EXPORT\" --force"
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$delete_cmd${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm: ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/fss_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DELETE EXPORT: $delete_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Deleting export...${NC}"
    
    local result
    result=$(oci fs export delete \
        --export-id "$FSS_SELECTED_EXPORT" \
        --force 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Export deletion initiated${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Deleted $FSS_SELECTED_EXPORT" >> "$log_file"
    else
        echo -e "${RED}Failed to delete export${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# FSS - List Snapshots
#--------------------------------------------------------------------------------
fss_list_snapshots() {
    local compartment_id="$1"
    local ad="$2"
    local action="${3:-none}"
    
    # First select a file system
    echo -e "${CYAN}Select a file system to view snapshots:${NC}"
    FSS_SELECTED_FS=""
    fss_list_file_systems "$compartment_id" "$ad" "select"
    
    if [[ -z "$FSS_SELECTED_FS" ]]; then
        return
    fi
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Snapshots ═══${NC}"
    echo ""
    
    local list_cmd="oci fs snapshot list --file-system-id \"$FSS_SELECTED_FS\" --all --output json"
    echo -e "${GRAY}$list_cmd${NC}"
    echo ""
    
    local snap_json
    snap_json=$(oci fs snapshot list \
        --file-system-id "$FSS_SELECTED_FS" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$snap_json" || "$snap_json" == "null" ]]; then
        echo -e "${YELLOW}No snapshots found or unable to list${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return 1
    fi
    
    local snap_count
    snap_count=$(echo "$snap_json" | jq '.data | length' 2>/dev/null)
    
    if [[ "$snap_count" -eq 0 ]]; then
        echo -e "${YELLOW}No snapshots found${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return 1
    fi
    
    echo -e "${GREEN}Found $snap_count snapshot(s)${NC}"
    echo ""
    
    printf "${BOLD}%-3s %-40s %-12s %-25s %s${NC}\n" "#" "Name" "State" "Time Created" "Snapshot OCID"
    print_separator 160
    
    local idx=0
    declare -gA FSS_SNAP_MAP
    FSS_SNAP_MAP=()
    
    while IFS='|' read -r name state time_created snap_id; do
        [[ -z "$name" ]] && continue
        ((idx++))
        
        FSS_SNAP_MAP[$idx]="$snap_id"
        
        local state_color="$GREEN"
        case "$state" in
            ACTIVE) state_color="$GREEN" ;;
            CREATING|UPDATING) state_color="$YELLOW" ;;
            DELETING|DELETED|FAILED) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        
        local name_trunc="${name:0:38}"
        [[ ${#name} -gt 38 ]] && name_trunc="${name_trunc}.."
        
        local time_short="${time_created:0:23}"
        
        printf "${YELLOW}%-3s${NC} %-40s ${state_color}%-12s${NC} %-25s ${GRAY}%s${NC}\n" \
            "$idx" "$name_trunc" "$state" "$time_short" "$snap_id"
            
    done < <(echo "$snap_json" | jq -r '.data[] | "\(.name)|\(.["lifecycle-state"])|\(.["time-created"])|\(.id)"' 2>/dev/null)
    
    FSS_SNAP_COUNT=$idx
    echo ""
    
    case "$action" in
        none)
            echo -e "Press Enter to continue..."
            read -r
            ;;
        select)
            echo -n -e "${CYAN}Enter snapshot # (or Enter to cancel): ${NC}"
            read -r snap_selection
            if [[ -n "$snap_selection" && -n "${FSS_SNAP_MAP[$snap_selection]}" ]]; then
                FSS_SELECTED_SNAP="${FSS_SNAP_MAP[$snap_selection]}"
            fi
            ;;
    esac
    
    return 0
}

#--------------------------------------------------------------------------------
# FSS - Create Snapshot
#--------------------------------------------------------------------------------
fss_create_snapshot() {
    local compartment_id="$1"
    local ad="$2"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Create Snapshot ═══${NC}"
    echo ""
    
    # Select file system
    echo -e "${CYAN}Select a file system:${NC}"
    FSS_SELECTED_FS=""
    fss_list_file_systems "$compartment_id" "$ad" "select"
    
    if [[ -z "$FSS_SELECTED_FS" ]]; then
        echo -e "${RED}No file system selected${NC}"
        return
    fi
    
    echo ""
    echo -n -e "${CYAN}Enter snapshot name: ${NC}"
    read -r snap_name
    
    if [[ -z "$snap_name" ]]; then
        snap_name="snapshot-$(date +%Y%m%d-%H%M%S)"
        echo -e "${YELLOW}Using default name: $snap_name${NC}"
    fi
    
    echo ""
    local create_cmd="oci fs snapshot create --file-system-id \"$FSS_SELECTED_FS\" --name \"$snap_name\""
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$create_cmd${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Proceed with creation? (y/N): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/fss_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CREATE SNAPSHOT: $create_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Creating snapshot...${NC}"
    
    local result
    result=$(oci fs snapshot create \
        --file-system-id "$FSS_SELECTED_FS" \
        --name "$snap_name" \
        --output json 2>&1)
    
    if echo "$result" | jq -e '.data.id' > /dev/null 2>&1; then
        local new_snap_id
        new_snap_id=$(echo "$result" | jq -r '.data.id')
        echo -e "${GREEN}✓ Snapshot created successfully${NC}"
        echo -e "  ${CYAN}OCID:${NC} ${YELLOW}$new_snap_id${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Created $new_snap_id" >> "$log_file"
    else
        echo -e "${RED}Failed to create snapshot${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# FSS - Delete Snapshot
#--------------------------------------------------------------------------------
fss_delete_snapshot() {
    local compartment_id="$1"
    local ad="$2"
    
    FSS_SELECTED_SNAP=""
    fss_list_snapshots "$compartment_id" "$ad" "select"
    
    [[ -z "$FSS_SELECTED_SNAP" ]] && return
    
    echo ""
    echo -e "${RED}WARNING: This will delete the snapshot!${NC}"
    echo ""
    local delete_cmd="oci fs snapshot delete --snapshot-id \"$FSS_SELECTED_SNAP\" --force"
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$delete_cmd${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm: ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/fss_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DELETE SNAPSHOT: $delete_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Deleting snapshot...${NC}"
    
    local result
    result=$(oci fs snapshot delete \
        --snapshot-id "$FSS_SELECTED_SNAP" \
        --force 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Snapshot deletion initiated${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Deleted $FSS_SELECTED_SNAP" >> "$log_file"
    else
        echo -e "${RED}Failed to delete snapshot${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#================================================================================
# LUSTRE FILE SYSTEM MANAGEMENT
#================================================================================

#--------------------------------------------------------------------------------
# Manage Lustre File Systems - Main menu
#--------------------------------------------------------------------------------
manage_lustre_file_systems() {
    local compartment_id="${EFFECTIVE_COMPARTMENT_ID:-$COMPARTMENT_ID}"
    local region="${EFFECTIVE_REGION:-$REGION}"
    
    while true; do
        echo ""
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${MAGENTA}                                        LUSTRE FILE SYSTEMS                                                      ${NC}"
        echo -e "${BOLD}${MAGENTA}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        echo -e "${BOLD}${WHITE}Environment:${NC}"
        echo -e "  ${CYAN}Region:${NC}      ${WHITE}${region}${NC}"
        echo -e "  ${CYAN}Compartment:${NC} ${YELLOW}${compartment_id}${NC}"
        echo ""
        
        # Fetch all Lustre file systems across all ADs
        echo -e "${GRAY}Fetching Lustre file systems...${NC}"
        local lfs_json
        lfs_json=$(oci lfs lustre-file-system-collection list-lustre-file-systems \
            --compartment-id "$compartment_id" \
            --all \
            --output json 2>/dev/null)
        
        local lfs_count=0
        if [[ -n "$lfs_json" && "$lfs_json" != "null" ]]; then
            lfs_count=$(echo "$lfs_json" | jq '.data.items | length' 2>/dev/null || echo "0")
        fi
        
        # Display summary table
        echo -e "${BOLD}${WHITE}═══ Lustre File Systems Summary (${lfs_count} found) ═══${NC}"
        echo ""
        
        if [[ "$lfs_count" -gt 0 ]]; then
            # Group by AD
            local ads_list
            ads_list=$(echo "$lfs_json" | jq -r '.data.items[]["availability-domain"]' 2>/dev/null | sort -u)
            
            declare -gA LFS_MAP
            LFS_MAP=()
            local idx=0
            
            for ad in $ads_list; do
                local ad_short="${ad##*:}"
                echo -e "${BOLD}${CYAN}─── $ad_short ───${NC}"
                echo ""
                
                printf "  ${BOLD}%-3s %-28s %-10s %-8s %-12s %-10s %-8s %-20s${NC}\n" \
                    "#" "Display Name" "State" "Capacity" "Perf Tier" "Version" "OS Link" "MGS Address"
                print_separator 120
                
                # Get file systems for this AD
                while IFS='|' read -r display_name state capacity_gb perf_tier version mgs_address fs_name lfs_id; do
                    [[ -z "$display_name" ]] && continue
                    ((idx++))
                    
                    LFS_MAP[$idx]="$lfs_id"
                    
                    local state_color="$GREEN"
                    case "$state" in
                        ACTIVE) state_color="$GREEN" ;;
                        CREATING|UPDATING) state_color="$YELLOW" ;;
                        DELETING|DELETED|FAILED) state_color="$RED" ;;
                        *) state_color="$GRAY" ;;
                    esac
                    
                    local name_trunc="${display_name:0:26}"
                    [[ ${#display_name} -gt 26 ]] && name_trunc="${name_trunc}.."
                    
                    # Convert capacity to TB
                    local capacity_display="N/A"
                    if [[ "$capacity_gb" =~ ^[0-9]+$ ]] && [[ "$capacity_gb" -gt 0 ]]; then
                        capacity_display=$(echo "scale=1; $capacity_gb / 1000" | bc)
                        capacity_display="${capacity_display}TB"
                    fi
                    
                    # Shorten performance tier
                    local perf_short="N/A"
                    case "$perf_tier" in
                        MBPS_PER_TB_125) perf_short="125/TB" ;;
                        MBPS_PER_TB_250) perf_short="250/TB" ;;
                        MBPS_PER_TB_500) perf_short="500/TB" ;;
                        MBPS_PER_TB_1000) perf_short="1000/TB" ;;
                        *) perf_short="${perf_tier:0:10}" ;;
                    esac
                    
                    # Check for object storage links
                    local os_link_status="${GRAY}None${NC}"
                    local os_links_json
                    os_links_json=$(oci lfs data-repository-association-collection list-data-repository-associations \
                        --lustre-file-system-id "$lfs_id" \
                        --output json 2>/dev/null)
                    
                    if [[ -n "$os_links_json" ]]; then
                        local link_count
                        link_count=$(echo "$os_links_json" | jq '.data.items | length' 2>/dev/null || echo "0")
                        if [[ "$link_count" -gt 0 ]]; then
                            local link_state
                            link_state=$(echo "$os_links_json" | jq -r '.data.items[0]["lifecycle-state"] // "N/A"' 2>/dev/null)
                            case "$link_state" in
                                ACTIVE) os_link_status="${GREEN}Active${NC}" ;;
                                CREATING) os_link_status="${YELLOW}Creating${NC}" ;;
                                *) os_link_status="${YELLOW}${link_state:0:8}${NC}" ;;
                            esac
                            [[ "$link_count" -gt 1 ]] && os_link_status="${os_link_status} (${link_count})"
                        fi
                    fi
                    
                    # Version display
                    local version_display="${version:0:8}"
                    [[ "$version" == "null" || -z "$version" ]] && version_display="N/A"
                    
                    # MGS address display
                    local mgs_display="${mgs_address:0:18}"
                    [[ "$mgs_address" == "null" || -z "$mgs_address" ]] && mgs_display="N/A"
                    
                    printf "  ${YELLOW}%-3s${NC} %-28s ${state_color}%-10s${NC} %-8s %-12s %-10s %-8b %-20s\n" \
                        "$idx" "$name_trunc" "$state" "$capacity_display" "$perf_short" "$version_display" "$os_link_status" "$mgs_display"
                    
                    # Show mount command if MGS address and file system name are available
                    if [[ "$mgs_address" != "null" && -n "$mgs_address" && "$fs_name" != "null" && -n "$fs_name" ]]; then
                        printf "      ${GRAY}Mount: sudo mount -t lustre %s:/%s /mnt/lustre${NC}\n" "$mgs_address" "$fs_name"
                    fi
                    
                done < <(echo "$lfs_json" | jq -r --arg ad "$ad" '
                    .data.items[] | 
                    select(.["availability-domain"] == $ad) | 
                    "\(.["display-name"])|\(.["lifecycle-state"])|\(.["capacity-in-gbs"] // 0)|\(.["performance-tier"] // "N/A")|\(.["lustre-version"] // .["major-version"] // "N/A")|\(.["mgs-address"] // "N/A")|\(.["file-system-name"] // "N/A")|\(.id)"
                ' 2>/dev/null)
                
                echo ""
            done
            
            LFS_COUNT=$idx
        else
            echo -e "  ${YELLOW}No Lustre file systems found in this compartment${NC}"
            echo ""
        fi
        
        echo -e "${BOLD}${WHITE}═══ Actions ═══${NC}"
        echo -e "  ${YELLOW}#${NC}   ${WHITE}View details${NC}               - Enter number to view file system details"
        echo ""
        echo -e "${BOLD}${WHITE}─── File System Operations ───${NC}"
        echo -e "  ${GREEN}c${NC})  ${WHITE}Create Lustre File System${NC}  - Create a new Lustre file system"
        echo -e "  ${GREEN}u${NC})  ${WHITE}Update Lustre File System${NC}  - Update name or capacity"
        echo -e "  ${RED}d${NC})  ${WHITE}Delete Lustre File System${NC}  - Delete a Lustre file system"
        echo ""
        echo -e "${BOLD}${WHITE}─── Object Storage Links ───${NC}"
        echo -e "  ${GREEN}ol${NC}) ${WHITE}List Object Storage Links${NC}  - List all HSM links"
        echo -e "  ${GREEN}oc${NC}) ${WHITE}Create Object Storage Link${NC} - Link Lustre to Object Storage"
        echo -e "  ${GREEN}oi${NC}) ${WHITE}Start Import from Object${NC}   - Import data from Object Storage"
        echo -e "  ${GREEN}oe${NC}) ${WHITE}Start Export to Object${NC}     - Export data to Object Storage"
        echo -e "  ${RED}od${NC}) ${WHITE}Delete Object Storage Link${NC} - Remove an Object Storage link"
        echo ""
        echo -e "${BOLD}${WHITE}─── Monitoring ───${NC}"
        echo -e "  ${GREEN}w${NC})  ${WHITE}Work Requests${NC}              - View Lustre work requests (async operations)"
        echo ""
        echo -e "  ${WHITE}r${NC})  Refresh"
        echo -e "  ${WHITE}b${NC})  Back to main menu"
        echo ""
        echo -n -e "${BOLD}${CYAN}Enter selection: ${NC}"
        read -r selection
        
        case "$selection" in
            [0-9]|[0-9][0-9])
                if [[ -n "${LFS_MAP[$selection]}" ]]; then
                    LFS_SELECTED="${LFS_MAP[$selection]}"
                    lfs_view_selected_details "$compartment_id"
                else
                    echo -e "${RED}Invalid selection${NC}"
                fi
                ;;
            c|C) lfs_create_file_system "$compartment_id" ;;
            u|U) lfs_update_file_system "$compartment_id" ;;
            d|D) lfs_delete_file_system "$compartment_id" ;;
            ol|OL) lfs_list_object_storage_links "$compartment_id" ;;
            oc|OC) lfs_create_object_storage_link "$compartment_id" ;;
            oi|OI) lfs_start_import_from_object "$compartment_id" ;;
            oe|OE) lfs_start_export_to_object "$compartment_id" ;;
            od|OD) lfs_delete_object_storage_link "$compartment_id" ;;
            w|W) lfs_list_work_requests "$compartment_id" ;;
            r|R) continue ;;
            b|B|back|BACK|"") return ;;
            *) echo -e "${RED}Invalid selection${NC}" ;;
        esac
    done
}

# View details of already selected LFS
lfs_view_selected_details() {
    local compartment_id="$1"
    
    [[ -z "$LFS_SELECTED" ]] && return
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Lustre File System Details ═══${NC}"
    echo ""
    
    local lfs_json
    lfs_json=$(oci lfs lustre-file-system get --lustre-file-system-id "$LFS_SELECTED" --output json 2>/dev/null)
    
    if [[ -z "$lfs_json" || "$lfs_json" == "null" ]]; then
        echo -e "${RED}Failed to get Lustre file system details${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    # Call the existing details display logic
    _display_lfs_details "$lfs_json"
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

# Internal function to display LFS details (reusable)
_display_lfs_details() {
    local lfs_json="$1"
    
    # Basic fields
    local display_name state capacity_tb ad_name subnet_id time_created lfs_id
    local file_system_name mgs_address
    
    display_name=$(echo "$lfs_json" | jq -r '.data["display-name"] // "N/A"')
    state=$(echo "$lfs_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    local capacity_gb
    capacity_gb=$(echo "$lfs_json" | jq -r '.data["capacity-in-gbs"] // 0')
    capacity_tb=$(echo "scale=1; $capacity_gb / 1000" | bc)
    ad_name=$(echo "$lfs_json" | jq -r '.data["availability-domain"] // "N/A"')
    subnet_id=$(echo "$lfs_json" | jq -r '.data["subnet-id"] // "N/A"')
    time_created=$(echo "$lfs_json" | jq -r '.data["time-created"] // "N/A"')
    lfs_id=$(echo "$lfs_json" | jq -r '.data.id // "N/A"')
    
    # Lustre-specific fields
    file_system_name=$(echo "$lfs_json" | jq -r '.data["file-system-name"] // "N/A"')
    mgs_address=$(echo "$lfs_json" | jq -r '.data["mgs-address"] // "N/A"')
    
    # Performance tier
    local performance_tier
    performance_tier=$(echo "$lfs_json" | jq -r '.data["performance-tier"] // "N/A"')
    local throughput_display="N/A"
    if [[ "$performance_tier" != "N/A" && "$capacity_gb" -gt 0 ]]; then
        local tier_value
        case "$performance_tier" in
            MBPS_PER_TB_125) tier_value=125 ;;
            MBPS_PER_TB_250) tier_value=250 ;;
            MBPS_PER_TB_500) tier_value=500 ;;
            MBPS_PER_TB_1000) tier_value=1000 ;;
            *) tier_value=0 ;;
        esac
        if [[ "$tier_value" -gt 0 ]]; then
            local expected_throughput
            expected_throughput=$(echo "$capacity_tb * $tier_value" | bc | cut -d'.' -f1)
            throughput_display="${expected_throughput} MB/s (${tier_value} MB/s per TB)"
        fi
    fi
    
    # Lustre version
    local lustre_version
    lustre_version=$(echo "$lfs_json" | jq -r '.data["lustre-version"] // .data["major-version"] // "N/A"')
    
    # Root squash configuration
    local root_squash
    root_squash=$(echo "$lfs_json" | jq -r '.data["root-squash-configuration"]["root-squash"] // .data["root-squash"] // "N/A"')
    
    # Network Security Groups
    local nsg_ids
    nsg_ids=$(echo "$lfs_json" | jq -r '.data["nsg-ids"] // []')
    
    # Encryption / KMS
    local kms_key_id
    kms_key_id=$(echo "$lfs_json" | jq -r '.data["kms-key-id"] // "N/A"')
    local encryption_type="Oracle-managed"
    if [[ "$kms_key_id" != "N/A" && "$kms_key_id" != "null" && -n "$kms_key_id" ]]; then
        encryption_type="Customer-managed (KMS)"
    fi
    
    local state_color="$GREEN"
    case "$state" in
        ACTIVE) state_color="$GREEN" ;;
        CREATING|UPDATING) state_color="$YELLOW" ;;
        *) state_color="$RED" ;;
    esac
    
    # Display basic info section
    echo -e "${BOLD}${CYAN}─── Basic Information ───${NC}"
    echo -e "  ${CYAN}Display Name:${NC}        ${WHITE}$display_name${NC}"
    echo -e "  ${CYAN}File System Name:${NC}    ${WHITE}$file_system_name${NC}"
    echo -e "  ${CYAN}Lustre Version:${NC}      ${WHITE}$lustre_version${NC}"
    echo -e "  ${CYAN}State:${NC}               ${state_color}$state${NC}"
    echo -e "  ${CYAN}Lustre FS OCID:${NC}      ${YELLOW}$lfs_id${NC}"
    echo -e "  ${CYAN}Time Created:${NC}        ${WHITE}$time_created${NC}"
    echo ""
    
    # Display capacity and performance section
    echo -e "${BOLD}${CYAN}─── Capacity & Performance ───${NC}"
    echo -e "  ${CYAN}Capacity:${NC}            ${WHITE}${capacity_tb} TB (${capacity_gb} GB)${NC}"
    echo -e "  ${CYAN}Performance Tier:${NC}    ${WHITE}$performance_tier${NC}"
    echo -e "  ${CYAN}Expected Throughput:${NC} ${WHITE}$throughput_display${NC}"
    echo ""
    
    # Display network section
    echo -e "${BOLD}${CYAN}─── Network Configuration ───${NC}"
    echo -e "  ${CYAN}MGS Address:${NC}         ${WHITE}$mgs_address${NC}"
    echo -e "  ${CYAN}Availability Domain:${NC} ${WHITE}$ad_name${NC}"
    echo -e "  ${CYAN}Subnet OCID:${NC}         ${YELLOW}$subnet_id${NC}"
    local nsg_display
    nsg_display=$(echo "$nsg_ids" | jq -r 'if length > 0 then .[] else empty end' 2>/dev/null)
    if [[ -n "$nsg_display" ]]; then
        echo -e "  ${CYAN}Network Security Groups:${NC}"
        echo "$nsg_ids" | jq -r '.[]?' 2>/dev/null | while read -r nsg; do
            [[ -n "$nsg" ]] && echo -e "    ${YELLOW}$nsg${NC}"
        done
    else
        echo -e "  ${CYAN}Network Security Groups:${NC} ${GRAY}None${NC}"
    fi
    echo ""
    
    # Display security section
    echo -e "${BOLD}${CYAN}─── Security Configuration ───${NC}"
    echo -e "  ${CYAN}Root Squash:${NC}         ${WHITE}$root_squash${NC}"
    echo -e "  ${CYAN}Encryption:${NC}          ${WHITE}$encryption_type${NC}"
    if [[ "$kms_key_id" != "N/A" && "$kms_key_id" != "null" && -n "$kms_key_id" ]]; then
        echo -e "  ${CYAN}KMS Key OCID:${NC}        ${YELLOW}$kms_key_id${NC}"
    fi
    echo ""
    
    # Fetch and display Object Storage Links
    echo -e "${BOLD}${CYAN}─── Object Storage Links ───${NC}"
    local os_links_json
    os_links_json=$(oci lfs data-repository-association-collection list-data-repository-associations \
        --lustre-file-system-id "$lfs_id" \
        --output json 2>/dev/null)
    
    local link_count=0
    if [[ -n "$os_links_json" ]]; then
        link_count=$(echo "$os_links_json" | jq '.data.items | length' 2>/dev/null || echo "0")
    fi
    
    if [[ "$link_count" -gt 0 ]]; then
        local link_idx=0
        while IFS='|' read -r assoc_id assoc_state fs_path bucket prefix import_policy export_policy; do
            ((link_idx++))
            
            local link_state_color="$GREEN"
            case "$assoc_state" in
                ACTIVE) link_state_color="$GREEN" ;;
                CREATING|UPDATING) link_state_color="$YELLOW" ;;
                *) link_state_color="$RED" ;;
            esac
            
            echo -e "  ${CYAN}Link #${link_idx}:${NC}"
            echo -e "    ${CYAN}State:${NC}              ${link_state_color}${assoc_state}${NC}"
            echo -e "    ${CYAN}File System Path:${NC}   ${WHITE}$fs_path${NC}"
            echo -e "    ${CYAN}Bucket:${NC}             ${WHITE}$bucket${NC}"
            echo -e "    ${CYAN}Prefix:${NC}             ${WHITE}${prefix:-none}${NC}"
            echo -e "    ${CYAN}Import Policy:${NC}      ${WHITE}$import_policy${NC}"
            echo -e "    ${CYAN}Export Policy:${NC}      ${WHITE}$export_policy${NC}"
            echo -e "    ${CYAN}Association OCID:${NC}   ${YELLOW}$assoc_id${NC}"
            echo ""
        done < <(echo "$os_links_json" | jq -r '
            .data.items[] |
            "\(.id)|\(.["lifecycle-state"])|\(.["file-system-path"] // "N/A")|\(.bucket // "N/A")|\(.prefix // "")|\(.["data-repository-import-policy"]["import-policy-type"] // "N/A")|\(.["data-repository-export-policy"]["export-policy-type"] // "N/A")"
        ' 2>/dev/null)
    else
        echo -e "  ${GRAY}No Object Storage links configured${NC}"
        echo ""
    fi
    
    # Mount commands
    if [[ "$mgs_address" != "N/A" && "$mgs_address" != "null" && -n "$file_system_name" ]]; then
        echo -e "${BOLD}${CYAN}─── Mount Commands ───${NC}"
        echo ""
        echo -e "  ${GRAY}# Install Lustre client (Oracle Linux / RHEL):${NC}"
        echo -e "  ${WHITE}sudo yum install -y lustre-client${NC}"
        echo ""
        echo -e "  ${GRAY}# Create mount point and mount:${NC}"
        echo -e "  ${WHITE}sudo mkdir -p /mnt/lustre${NC}"
        echo -e "  ${WHITE}sudo mount -t lustre ${mgs_address}:/${file_system_name} /mnt/lustre${NC}"
        echo ""
        echo -e "  ${GRAY}# Add to /etc/fstab for persistent mount:${NC}"
        echo -e "  ${WHITE}${mgs_address}:/${file_system_name} /mnt/lustre lustre defaults,_netdev 0 0${NC}"
    fi
}

#--------------------------------------------------------------------------------
# Lustre - List File Systems
#--------------------------------------------------------------------------------
lfs_list_file_systems() {
    local compartment_id="$1"
    local action="${2:-none}"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Lustre File Systems ═══${NC}"
    echo ""
    
    local list_cmd="oci lfs lustre-file-system-collection list-lustre-file-systems --compartment-id \"$compartment_id\" --all --output json"
    echo -e "${GRAY}$list_cmd${NC}"
    echo ""
    
    local lfs_json
    lfs_json=$(oci lfs lustre-file-system-collection list-lustre-file-systems \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$lfs_json" || "$lfs_json" == "null" ]]; then
        echo -e "${YELLOW}No Lustre file systems found or unable to list${NC}"
        return 1
    fi
    
    local lfs_count
    lfs_count=$(echo "$lfs_json" | jq '.data.items | length' 2>/dev/null)
    
    if [[ "$lfs_count" -eq 0 || -z "$lfs_count" ]]; then
        echo -e "${YELLOW}No Lustre file systems found${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Found $lfs_count Lustre file system(s)${NC}"
    echo ""
    
    printf "${BOLD}%-3s %-30s %-12s %-10s %-20s %s${NC}\n" "#" "Display Name" "State" "Capacity" "Availability Domain" "Lustre FS OCID"
    print_separator 180
    
    local idx=0
    declare -gA LFS_MAP
    LFS_MAP=()
    
    while IFS='|' read -r display_name state capacity_gb ad_name lfs_id; do
        [[ -z "$display_name" ]] && continue
        ((idx++))
        
        LFS_MAP[$idx]="$lfs_id"
        
        local state_color="$GREEN"
        case "$state" in
            ACTIVE) state_color="$GREEN" ;;
            CREATING|UPDATING) state_color="$YELLOW" ;;
            DELETING|DELETED|FAILED) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        
        local name_trunc="${display_name:0:28}"
        [[ ${#display_name} -gt 28 ]] && name_trunc="${name_trunc}.."
        
        local ad_short="${ad_name##*:}"
        
        # Display capacity - API may return in GB, convert to TB for display
        local capacity_display
        if [[ "$capacity_gb" =~ ^[0-9]+$ ]] && [[ "$capacity_gb" -gt 500 ]]; then
            # Likely in GB, convert to TB
            capacity_display=$(echo "scale=1; $capacity_gb / 1000" | bc)
            capacity_display="${capacity_display}TB"
        else
            capacity_display="${capacity_gb}TB"
        fi
        
        printf "${YELLOW}%-3s${NC} %-30s ${state_color}%-12s${NC} %-10s %-20s ${GRAY}%s${NC}\n" \
            "$idx" "$name_trunc" "$state" "$capacity_display" "$ad_short" "$lfs_id"
            
    done < <(echo "$lfs_json" | jq -r '.data.items[] | "\(.["display-name"])|\(.["lifecycle-state"])|\(.["capacity-in-gbs"] // .["capacity-in-tbs"] // "N/A")|\(.["availability-domain"])|\(.id)"' 2>/dev/null)
    
    LFS_COUNT=$idx
    echo ""
    
    case "$action" in
        none)
            echo -e "Press Enter to continue..."
            read -r
            ;;
        select)
            echo -n -e "${CYAN}Enter Lustre file system # (or Enter to cancel): ${NC}"
            read -r lfs_selection
            if [[ -n "$lfs_selection" && -n "${LFS_MAP[$lfs_selection]}" ]]; then
                LFS_SELECTED="${LFS_MAP[$lfs_selection]}"
            fi
            ;;
    esac
    
    return 0
}

#--------------------------------------------------------------------------------
# Lustre - View File System Details (with mount commands)
#--------------------------------------------------------------------------------
lfs_view_file_system_details() {
    local compartment_id="$1"
    
    LFS_SELECTED=""
    lfs_list_file_systems "$compartment_id" "select"
    
    [[ -z "$LFS_SELECTED" ]] && return
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Lustre File System Details ═══${NC}"
    echo ""
    
    local get_cmd="oci lfs lustre-file-system get --lustre-file-system-id \"$LFS_SELECTED\" --output json"
    echo -e "${GRAY}$get_cmd${NC}"
    echo ""
    
    local lfs_json
    lfs_json=$(oci lfs lustre-file-system get --lustre-file-system-id "$LFS_SELECTED" --output json 2>/dev/null)
    
    if [[ -z "$lfs_json" || "$lfs_json" == "null" ]]; then
        echo -e "${RED}Failed to get Lustre file system details${NC}"
        return
    fi
    
    # Basic fields
    local display_name state capacity_tb ad_name subnet_id time_created lfs_id
    local file_system_name mgs_address
    
    display_name=$(echo "$lfs_json" | jq -r '.data["display-name"] // "N/A"')
    state=$(echo "$lfs_json" | jq -r '.data["lifecycle-state"] // "N/A"')
    capacity_tb=$(echo "$lfs_json" | jq -r '.data["capacity-in-gbs"] // .data["capacity-in-tbs"] // "N/A"')
    # Convert to TB if in GB
    if [[ "$capacity_tb" =~ ^[0-9]+$ ]] && [[ "$capacity_tb" -gt 500 ]]; then
        capacity_tb=$(echo "scale=1; $capacity_tb / 1000" | bc)
    fi
    ad_name=$(echo "$lfs_json" | jq -r '.data["availability-domain"] // "N/A"')
    subnet_id=$(echo "$lfs_json" | jq -r '.data["subnet-id"] // "N/A"')
    time_created=$(echo "$lfs_json" | jq -r '.data["time-created"] // "N/A"')
    lfs_id=$(echo "$lfs_json" | jq -r '.data.id // "N/A"')
    
    # Lustre-specific fields
    file_system_name=$(echo "$lfs_json" | jq -r '.data["file-system-name"] // "N/A"')
    mgs_address=$(echo "$lfs_json" | jq -r '.data["mgs-address"] // "N/A"')
    
    # Performance tier
    local performance_tier
    performance_tier=$(echo "$lfs_json" | jq -r '.data["performance-tier"] // "N/A"')
    local throughput_display="N/A"
    if [[ "$performance_tier" != "N/A" && "$capacity_tb" != "N/A" ]]; then
        local tier_value
        case "$performance_tier" in
            MBPS_PER_TB_125) tier_value=125 ;;
            MBPS_PER_TB_250) tier_value=250 ;;
            MBPS_PER_TB_500) tier_value=500 ;;
            MBPS_PER_TB_1000) tier_value=1000 ;;
            *) tier_value=0 ;;
        esac
        if [[ "$tier_value" -gt 0 ]]; then
            local expected_throughput
            expected_throughput=$(echo "$capacity_tb * $tier_value" | bc | cut -d'.' -f1)
            throughput_display="${expected_throughput} MB/s (${tier_value} MB/s per TB)"
        fi
    fi
    
    # Lustre version
    local lustre_version
    lustre_version=$(echo "$lfs_json" | jq -r '.data["lustre-version"] // .data["major-version"] // "N/A"')
    
    # Root squash configuration
    local root_squash
    root_squash=$(echo "$lfs_json" | jq -r '.data["root-squash-configuration"]["root-squash"] // .data["root-squash"] // "N/A"')
    
    # Network Security Groups
    local nsg_ids nsg_display
    nsg_ids=$(echo "$lfs_json" | jq -r '.data["nsg-ids"] // []')
    if [[ "$nsg_ids" == "[]" || "$nsg_ids" == "null" || -z "$nsg_ids" ]]; then
        nsg_display="None"
    else
        nsg_display=$(echo "$nsg_ids" | jq -r 'if length > 0 then .[] else "None" end' 2>/dev/null)
    fi
    
    # Encryption / KMS
    local kms_key_id
    kms_key_id=$(echo "$lfs_json" | jq -r '.data["kms-key-id"] // "N/A"')
    local encryption_type="Oracle-managed"
    if [[ "$kms_key_id" != "N/A" && "$kms_key_id" != "null" && -n "$kms_key_id" ]]; then
        encryption_type="Customer-managed (KMS)"
    fi
    
    # Cluster placement and replication
    local cluster_placement_group_id replication_target_id
    cluster_placement_group_id=$(echo "$lfs_json" | jq -r '.data["cluster-placement-group-id"] // "N/A"')
    replication_target_id=$(echo "$lfs_json" | jq -r '.data["replication-target-id"] // "N/A"')
    
    # Object Storage Links (data repository associations)
    local data_repository_associations
    data_repository_associations=$(echo "$lfs_json" | jq -r '.data["data-repository-associations"] // []')
    
    # Lifecycle details and freeform tags
    local lifecycle_details freeform_tags defined_tags
    lifecycle_details=$(echo "$lfs_json" | jq -r '.data["lifecycle-details"] // "N/A"')
    freeform_tags=$(echo "$lfs_json" | jq -r '.data["freeform-tags"] // {}')
    defined_tags=$(echo "$lfs_json" | jq -r '.data["defined-tags"] // {}')
    
    local state_color="$GREEN"
    case "$state" in
        ACTIVE) state_color="$GREEN" ;;
        CREATING|UPDATING) state_color="$YELLOW" ;;
        *) state_color="$RED" ;;
    esac
    
    # Display basic info section
    echo -e "${BOLD}${CYAN}─── Basic Information ───${NC}"
    echo -e "  ${CYAN}Display Name:${NC}        ${WHITE}$display_name${NC}"
    echo -e "  ${CYAN}File System Name:${NC}    ${WHITE}$file_system_name${NC}"
    echo -e "  ${CYAN}Lustre Version:${NC}      ${WHITE}$lustre_version${NC}"
    echo -e "  ${CYAN}State:${NC}               ${state_color}$state${NC}"
    [[ "$lifecycle_details" != "N/A" && -n "$lifecycle_details" ]] && \
        echo -e "  ${CYAN}Lifecycle Details:${NC}   ${WHITE}$lifecycle_details${NC}"
    echo -e "  ${CYAN}Lustre FS OCID:${NC}      ${YELLOW}$lfs_id${NC}"
    echo -e "  ${CYAN}Time Created:${NC}        ${WHITE}$time_created${NC}"
    echo ""
    
    # Display capacity and performance section
    echo -e "${BOLD}${CYAN}─── Capacity & Performance ───${NC}"
    echo -e "  ${CYAN}Capacity:${NC}            ${WHITE}${capacity_tb} TB${NC}"
    echo -e "  ${CYAN}Performance Tier:${NC}    ${WHITE}$performance_tier${NC}"
    echo -e "  ${CYAN}Expected Throughput:${NC} ${WHITE}$throughput_display${NC}"
    echo ""
    
    # Display network section
    echo -e "${BOLD}${CYAN}─── Network Configuration ───${NC}"
    echo -e "  ${CYAN}MGS Address:${NC}         ${WHITE}$mgs_address${NC}"
    echo -e "  ${CYAN}Availability Domain:${NC} ${WHITE}$ad_name${NC}"
    echo -e "  ${CYAN}Subnet OCID:${NC}         ${YELLOW}$subnet_id${NC}"
    echo -e "  ${CYAN}Network Security Groups:${NC}"
    if [[ "$nsg_display" == "None" ]]; then
        echo -e "    ${GRAY}None${NC}"
    else
        echo "$nsg_ids" | jq -r '.[]?' 2>/dev/null | while read -r nsg; do
            [[ -n "$nsg" ]] && echo -e "    ${YELLOW}$nsg${NC}"
        done
    fi
    echo ""
    
    # Display security section
    echo -e "${BOLD}${CYAN}─── Security Configuration ───${NC}"
    echo -e "  ${CYAN}Root Squash:${NC}         ${WHITE}$root_squash${NC}"
    echo -e "  ${CYAN}Encryption:${NC}          ${WHITE}$encryption_type${NC}"
    if [[ "$kms_key_id" != "N/A" && "$kms_key_id" != "null" && -n "$kms_key_id" ]]; then
        echo -e "  ${CYAN}KMS Key OCID:${NC}        ${YELLOW}$kms_key_id${NC}"
    fi
    echo ""
    
    # Display Object Storage Links section (if configured)
    local has_data_repos
    has_data_repos=$(echo "$data_repository_associations" | jq 'if type == "array" then length > 0 else false end' 2>/dev/null)
    if [[ "$has_data_repos" == "true" ]]; then
        echo -e "${BOLD}${CYAN}─── Object Storage Links ───${NC}"
        local assoc_count
        assoc_count=$(echo "$data_repository_associations" | jq 'length' 2>/dev/null)
        local i
        for ((i=0; i<assoc_count; i++)); do
            local assoc_id assoc_state fs_path bucket prefix import_policy export_policy
            assoc_id=$(echo "$data_repository_associations" | jq -r ".[$i].id // \"N/A\"")
            assoc_state=$(echo "$data_repository_associations" | jq -r ".[$i][\"lifecycle-state\"] // \"N/A\"")
            fs_path=$(echo "$data_repository_associations" | jq -r ".[$i][\"file-system-path\"] // \"N/A\"")
            bucket=$(echo "$data_repository_associations" | jq -r ".[$i].bucket // \"N/A\"")
            prefix=$(echo "$data_repository_associations" | jq -r ".[$i].prefix // \"none\"")
            import_policy=$(echo "$data_repository_associations" | jq -r ".[$i][\"data-repository-import-policy\"][\"import-policy-type\"] // \"N/A\"" 2>/dev/null)
            export_policy=$(echo "$data_repository_associations" | jq -r ".[$i][\"data-repository-export-policy\"][\"export-policy-type\"] // \"N/A\"" 2>/dev/null)
            
            local assoc_state_color="$GREEN"
            case "$assoc_state" in
                ACTIVE) assoc_state_color="$GREEN" ;;
                CREATING|UPDATING) assoc_state_color="$YELLOW" ;;
                *) assoc_state_color="$RED" ;;
            esac
            
            echo -e "  ${CYAN}Association ID:${NC}      ${YELLOW}$assoc_id${NC}"
            echo -e "    ${CYAN}State:${NC}              ${assoc_state_color}${assoc_state}${NC}"
            echo -e "    ${CYAN}File System Path:${NC}   ${WHITE}$fs_path${NC}"
            echo -e "    ${CYAN}Bucket:${NC}             ${WHITE}$bucket${NC}"
            echo -e "    ${CYAN}Prefix:${NC}             ${WHITE}$prefix${NC}"
            echo -e "    ${CYAN}Import Policy:${NC}      ${WHITE}$import_policy${NC}"
            echo -e "    ${CYAN}Export Policy:${NC}      ${WHITE}$export_policy${NC}"
            echo ""
        done
    fi
    
    # Display placement section (if applicable)
    if [[ "$cluster_placement_group_id" != "N/A" && "$cluster_placement_group_id" != "null" && -n "$cluster_placement_group_id" ]]; then
        echo -e "${BOLD}${CYAN}─── Placement ───${NC}"
        echo -e "  ${CYAN}Cluster Placement Group:${NC} ${YELLOW}$cluster_placement_group_id${NC}"
        echo ""
    fi
    
    # Display replication section (if applicable)
    if [[ "$replication_target_id" != "N/A" && "$replication_target_id" != "null" && -n "$replication_target_id" ]]; then
        echo -e "${BOLD}${CYAN}─── Replication ───${NC}"
        echo -e "  ${CYAN}Replication Target:${NC} ${YELLOW}$replication_target_id${NC}"
        echo ""
    fi
    
    # Display tags section
    local has_freeform_tags has_defined_tags
    has_freeform_tags=$(echo "$freeform_tags" | jq 'length > 0' 2>/dev/null)
    has_defined_tags=$(echo "$defined_tags" | jq 'to_entries | length > 0' 2>/dev/null)
    
    if [[ "$has_freeform_tags" == "true" || "$has_defined_tags" == "true" ]]; then
        echo -e "${BOLD}${CYAN}─── Tags ───${NC}"
        if [[ "$has_freeform_tags" == "true" ]]; then
            echo -e "  ${CYAN}Freeform Tags:${NC}"
            echo "$freeform_tags" | jq -r 'to_entries[] | "    \(.key): \(.value)"' 2>/dev/null | while read -r line; do
                echo -e "  ${WHITE}$line${NC}"
            done
        fi
        if [[ "$has_defined_tags" == "true" ]]; then
            echo -e "  ${CYAN}Defined Tags:${NC}"
            echo "$defined_tags" | jq -r 'to_entries[] | .key as $ns | .value | to_entries[] | "    \($ns).\(.key): \(.value)"' 2>/dev/null | while read -r line; do
                echo -e "  ${WHITE}$line${NC}"
            done
        fi
        echo ""
    fi
    
    # Mount commands
    if [[ "$mgs_address" != "N/A" && -n "$file_system_name" ]]; then
        echo -e "${BOLD}${CYAN}─── Mount Commands ───${NC}"
        echo ""
        echo -e "  ${GRAY}# Install Lustre client (Oracle Linux / RHEL):${NC}"
        echo -e "  ${WHITE}sudo yum install -y lustre-client${NC}"
        echo ""
        echo -e "  ${GRAY}# Create mount point and mount:${NC}"
        echo -e "  ${WHITE}sudo mkdir -p /mnt/lustre${NC}"
        echo -e "  ${WHITE}sudo mount -t lustre ${mgs_address}:/${file_system_name} /mnt/lustre${NC}"
        echo ""
        echo -e "  ${GRAY}# Add to /etc/fstab for persistent mount:${NC}"
        echo -e "  ${WHITE}${mgs_address}:/${file_system_name} /mnt/lustre lustre defaults,_netdev 0 0${NC}"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Lustre - Create File System
#--------------------------------------------------------------------------------
lfs_create_file_system() {
    local compartment_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Create Lustre File System ═══${NC}"
    echo ""
    
    # Get AD
    echo -e "${CYAN}Available Availability Domains:${NC}"
    local ads_json
    ads_json=$(oci iam availability-domain list --compartment-id "$compartment_id" --output json 2>/dev/null)
    
    local idx=0
    declare -A AD_MAP
    while read -r ad_name; do
        [[ -z "$ad_name" ]] && continue
        ((idx++))
        AD_MAP[$idx]="$ad_name"
        echo -e "  ${YELLOW}$idx${NC}) $ad_name"
    done < <(echo "$ads_json" | jq -r '.data[].name' 2>/dev/null)
    
    echo ""
    echo -n -e "${CYAN}Select AD #: ${NC}"
    read -r ad_selection
    local ad="${AD_MAP[$ad_selection]}"
    
    if [[ -z "$ad" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return
    fi
    
    # List subnets
    echo ""
    echo -e "${CYAN}Available Subnets:${NC}"
    local subnets_json
    subnets_json=$(oci network subnet list --compartment-id "$compartment_id" --all --output json 2>/dev/null)
    
    idx=0
    declare -A SUBNET_MAP
    while IFS='|' read -r subnet_name subnet_id cidr; do
        [[ -z "$subnet_name" ]] && continue
        ((idx++))
        SUBNET_MAP[$idx]="$subnet_id"
        echo -e "  ${YELLOW}$idx${NC}) $subnet_name (${cidr})"
    done < <(echo "$subnets_json" | jq -r '.data[] | "\(.["display-name"])|\(.id)|\(.["cidr-block"])"' 2>/dev/null)
    
    echo ""
    echo -n -e "${CYAN}Select subnet #: ${NC}"
    read -r subnet_selection
    local subnet_id="${SUBNET_MAP[$subnet_selection]}"
    
    if [[ -z "$subnet_id" ]]; then
        echo -e "${RED}Invalid selection${NC}"
        return
    fi
    
    # List NSGs (optional)
    echo ""
    echo -e "${CYAN}Available Network Security Groups (optional):${NC}"
    local nsgs_json
    nsgs_json=$(oci network nsg list --compartment-id "$compartment_id" --all --output json 2>/dev/null)
    
    idx=0
    declare -A NSG_MAP
    echo -e "  ${YELLOW}0${NC}) None (skip NSG)"
    while IFS='|' read -r nsg_name nsg_id; do
        [[ -z "$nsg_name" ]] && continue
        ((idx++))
        NSG_MAP[$idx]="$nsg_id"
        echo -e "  ${YELLOW}$idx${NC}) $nsg_name"
    done < <(echo "$nsgs_json" | jq -r '.data[] | "\(.["display-name"])|\(.id)"' 2>/dev/null)
    
    echo ""
    echo -n -e "${CYAN}Select NSG # (0 for none): ${NC}"
    read -r nsg_selection
    local nsg_id=""
    if [[ "$nsg_selection" != "0" && -n "${NSG_MAP[$nsg_selection]}" ]]; then
        nsg_id="${NSG_MAP[$nsg_selection]}"
    fi
    
    echo ""
    echo -n -e "${CYAN}Enter display name: ${NC}"
    read -r lfs_name
    
    if [[ -z "$lfs_name" ]]; then
        echo -e "${RED}Display name is required${NC}"
        return
    fi
    
    echo ""
    echo -e "${GRAY}File system name rules: 1-8 characters, letters (a-z, A-Z), numbers, and underscore only${NC}"
    echo -n -e "${CYAN}Enter file system name (e.g., lfs1, myfs_01): ${NC}"
    read -r fs_name
    
    if [[ -z "$fs_name" ]]; then
        # Generate default: lfs + random 4 digits
        fs_name="lfs$(shuf -i 1000-9999 -n 1)"
        echo -e "${YELLOW}Using default: $fs_name${NC}"
    fi
    
    # Validate file system name: 1-8 characters, alphanumeric and underscore only
    while true; do
        if [[ ${#fs_name} -lt 1 || ${#fs_name} -gt 8 ]]; then
            echo -e "${RED}File system name must be 1-8 characters. You entered: ${#fs_name} characters${NC}"
        elif [[ ! "$fs_name" =~ ^[a-zA-Z0-9_]+$ ]]; then
            echo -e "${RED}File system name can only contain letters (a-z, A-Z), numbers, and underscore${NC}"
        else
            break
        fi
        echo -n -e "${CYAN}Enter valid name: ${NC}"
        read -r fs_name
        if [[ -z "$fs_name" ]]; then
            echo -e "${RED}Name required. Aborting.${NC}"
            return
        fi
    done
    
    # Capacity selection with proper Lustre sizing rules
    echo ""
    echo -e "${CYAN}Select capacity:${NC}"
    echo -e "${GRAY}  Rules: Min 31,200 GB (31.2 TB), must be multiple of 10,400 GB (10.4 TB)${NC}"
    echo -e "  ${YELLOW}1${NC})  31.2 TB  (31,200 GB - minimum)"
    echo -e "  ${YELLOW}2${NC})  41.6 TB  (41,600 GB)"
    echo -e "  ${YELLOW}3${NC})  52.0 TB  (52,000 GB)"
    echo -e "  ${YELLOW}4${NC})  62.4 TB  (62,400 GB)"
    echo -e "  ${YELLOW}5${NC})  72.8 TB  (72,800 GB)"
    echo -e "  ${YELLOW}6${NC})  83.2 TB  (83,200 GB)"
    echo -e "  ${YELLOW}7${NC})  93.6 TB  (93,600 GB)"
    echo -e "  ${YELLOW}8${NC}) 104.0 TB (104,000 GB)"
    echo -e "  ${YELLOW}9${NC}) 114.4 TB (114,400 GB)"
    echo -e "  ${YELLOW}10${NC}) 124.8 TB (124,800 GB)"
    echo -e "  ${YELLOW}11${NC}) 166.4 TB (166,400 GB)"
    echo -e "  ${YELLOW}12${NC}) 208.0 TB (208,000 GB)"
    echo -e "  ${YELLOW}c${NC})  Custom"
    echo -n -e "${CYAN}Select #: ${NC}"
    read -r cap_selection
    
    local capacity_tb
    case "$cap_selection" in
        1) capacity_tb="31.2" ;;
        2) capacity_tb="41.6" ;;
        3) capacity_tb="52.0" ;;
        4) capacity_tb="62.4" ;;
        5) capacity_tb="72.8" ;;
        6) capacity_tb="83.2" ;;
        7) capacity_tb="93.6" ;;
        8) capacity_tb="104.0" ;;
        9) capacity_tb="114.4" ;;
        10) capacity_tb="124.8" ;;
        11) capacity_tb="166.4" ;;
        12) capacity_tb="208.0" ;;
        c|C|13)
            echo ""
            echo -e "${GRAY}Capacity must be a multiple of 10.4 TB (10,400 GB), minimum 31.2 TB${NC}"
            echo -e "${GRAY}Examples: 31.2, 41.6, 52.0, 62.4, 72.8, 83.2, 93.6, 104.0, 114.4, 124.8, 135.2, ...${NC}"
            echo -n -e "${CYAN}Enter capacity in TB: ${NC}"
            read -r capacity_tb
            # Validate the capacity
            if ! lfs_validate_capacity "$capacity_tb"; then
                local entered_gb
                entered_gb=$(echo "scale=0; $capacity_tb * 1000 / 1" | bc 2>/dev/null)
                echo -e "${RED}Invalid capacity. ${entered_gb} GB is not a multiple of 10,400 GB.${NC}"
                echo -e "${GRAY}Nearest valid values: $(( (entered_gb / 10400) * 10400 )) GB or $(( ((entered_gb / 10400) + 1) * 10400 )) GB${NC}"
                return
            fi
            ;;
        *) capacity_tb="31.2" ;;
    esac
    
    # Performance tier selection
    echo ""
    echo -e "${CYAN}Select performance tier (MB/s per TB):${NC}"
    echo -e "  ${YELLOW}1${NC}) MBPS_PER_TB_125   (125 MB/s per TB)"
    echo -e "  ${YELLOW}2${NC}) MBPS_PER_TB_250   (250 MB/s per TB)"
    echo -e "  ${YELLOW}3${NC}) MBPS_PER_TB_500   (500 MB/s per TB)"
    echo -e "  ${YELLOW}4${NC}) MBPS_PER_TB_1000  (1000 MB/s per TB)"
    echo -n -e "${CYAN}Select #: ${NC}"
    read -r perf_selection
    
    local performance_tier
    case "$perf_selection" in
        1) performance_tier="MBPS_PER_TB_125" ;;
        2) performance_tier="MBPS_PER_TB_250" ;;
        3) performance_tier="MBPS_PER_TB_500" ;;
        4) performance_tier="MBPS_PER_TB_1000" ;;
        *) performance_tier="MBPS_PER_TB_125" ;;
    esac
    
    # Calculate expected throughput
    local expected_throughput
    case "$performance_tier" in
        MBPS_PER_TB_125) expected_throughput=$(echo "$capacity_tb * 125" | bc) ;;
        MBPS_PER_TB_250) expected_throughput=$(echo "$capacity_tb * 250" | bc) ;;
        MBPS_PER_TB_500) expected_throughput=$(echo "$capacity_tb * 500" | bc) ;;
        MBPS_PER_TB_1000) expected_throughput=$(echo "$capacity_tb * 1000" | bc) ;;
    esac
    echo -e "${GRAY}  Expected throughput: ~${expected_throughput} MB/s${NC}"
    
    # Root squash selection
    echo ""
    echo -e "${CYAN}Select root squash mode:${NC}"
    echo -e "  ${YELLOW}1${NC}) NONE  (no root squashing - root has full access)"
    echo -e "  ${YELLOW}2${NC}) ROOT  (root is squashed to anonymous user)"
    echo -n -e "${CYAN}Select #: ${NC}"
    read -r squash_selection
    
    local root_squash
    case "$squash_selection" in
        1) root_squash="NONE" ;;
        2) root_squash="ROOT" ;;
        *) root_squash="NONE" ;;
    esac
    
    # Encryption selection
    echo ""
    echo -e "${CYAN}Select encryption:${NC}"
    echo -e "  ${YELLOW}1${NC}) Oracle-managed keys (default)"
    echo -e "  ${YELLOW}2${NC}) Customer-managed keys (KMS)"
    echo -n -e "${CYAN}Select #: ${NC}"
    read -r enc_selection
    
    local kms_key_id=""
    if [[ "$enc_selection" == "2" ]]; then
        echo ""
        echo -e "${CYAN}Available KMS Keys:${NC}"
        local vaults_json keys_found=0
        
        # List vaults first
        vaults_json=$(oci kms management vault list --compartment-id "$compartment_id" --all --output json 2>/dev/null)
        
        idx=0
        declare -A KMS_KEY_MAP
        
        while IFS='|' read -r vault_name vault_id mgmt_endpoint; do
            [[ -z "$vault_id" ]] && continue
            [[ "$vault_name" == "null" ]] && continue
            
            # List keys in this vault
            local keys_json
            keys_json=$(oci kms management key list --compartment-id "$compartment_id" --endpoint "$mgmt_endpoint" --all --output json 2>/dev/null)
            
            while IFS='|' read -r key_name key_id key_state; do
                [[ -z "$key_id" ]] && continue
                [[ "$key_state" != "ENABLED" ]] && continue
                ((idx++))
                ((keys_found++))
                KMS_KEY_MAP[$idx]="$key_id"
                echo -e "  ${YELLOW}$idx${NC}) $key_name (Vault: $vault_name)"
            done < <(echo "$keys_json" | jq -r '.data[] | "\(.["display-name"])|\(.id)|\(.["lifecycle-state"])"' 2>/dev/null)
            
        done < <(echo "$vaults_json" | jq -r '.data[] | select(.["lifecycle-state"]=="ACTIVE") | "\(.["display-name"])|\(.id)|\(.["management-endpoint"])"' 2>/dev/null)
        
        if [[ $keys_found -eq 0 ]]; then
            echo -e "${YELLOW}No KMS keys found. Using Oracle-managed keys.${NC}"
        else
            echo ""
            echo -n -e "${CYAN}Select KMS key #: ${NC}"
            read -r kms_selection
            kms_key_id="${KMS_KEY_MAP[$kms_selection]}"
            
            if [[ -z "$kms_key_id" ]]; then
                echo -e "${YELLOW}Invalid selection. Using Oracle-managed keys.${NC}"
                kms_key_id=""
            fi
        fi
    fi
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Configuration Summary ═══${NC}"
    echo -e "  ${CYAN}Display Name:${NC}      $lfs_name"
    echo -e "  ${CYAN}File System Name:${NC}  $fs_name"
    echo -e "  ${CYAN}Availability Domain:${NC} $ad"
    echo -e "  ${CYAN}Subnet:${NC}            ${subnet_id:0:50}..."
    [[ -n "$nsg_id" ]] && echo -e "  ${CYAN}NSG:${NC}               ${nsg_id:0:50}..."
    echo -e "  ${CYAN}Capacity:${NC}          ${capacity_tb} TB"
    echo -e "  ${CYAN}Performance Tier:${NC}  $performance_tier (~${expected_throughput} MB/s)"
    echo -e "  ${CYAN}Root Squash:${NC}       $root_squash"
    if [[ -n "$kms_key_id" ]]; then
        echo -e "  ${CYAN}Encryption:${NC}        Customer-managed (KMS)"
        echo -e "  ${CYAN}KMS Key:${NC}           ${kms_key_id:0:50}..."
    else
        echo -e "  ${CYAN}Encryption:${NC}        Oracle-managed"
    fi
    echo ""
    
    # Convert TB to GB for API (API uses --capacity-in-gbs)
    # API requires multiples of 10400 GB
    # Preset values: 31.2 TB = 31200 GB, 41.6 TB = 41600 GB, etc.
    local capacity_gb
    capacity_gb=$(echo "scale=0; $capacity_tb * 1000 / 1" | bc)
    
    # Build root-squash-configuration JSON
    local root_squash_config="{\"rootSquash\": \"$root_squash\"}"
    
    # Build the create command (display shows TB, API uses GB)
    local create_cmd="oci lfs lustre-file-system create"
    create_cmd+=" --compartment-id \"$compartment_id\""
    create_cmd+=" --availability-domain \"$ad\""
    create_cmd+=" --subnet-id \"$subnet_id\""
    create_cmd+=" --display-name \"$lfs_name\""
    create_cmd+=" --file-system-name \"$fs_name\""
    create_cmd+=" --capacity-in-gbs $capacity_gb"
    create_cmd+=" --performance-tier $performance_tier"
    create_cmd+=" --root-squash-configuration '$root_squash_config'"
    [[ -n "$nsg_id" ]] && create_cmd+=" --nsg-ids '[\"$nsg_id\"]'"
    [[ -n "$kms_key_id" ]] && create_cmd+=" --kms-key-id \"$kms_key_id\""
    
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$create_cmd${NC}"
    echo -e "${GRAY}(${capacity_tb} TB = ${capacity_gb} GB)${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Proceed with creation? (y/N): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-./logs}/lustre_actions_$(date +%Y%m%d).log"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CREATE LUSTRE: $create_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Creating Lustre file system (this may take several minutes)...${NC}"
    
    # Build the actual command with optional parameters
    local result
    if [[ -n "$kms_key_id" && -n "$nsg_id" ]]; then
        result=$(oci lfs lustre-file-system create \
            --compartment-id "$compartment_id" \
            --availability-domain "$ad" \
            --subnet-id "$subnet_id" \
            --display-name "$lfs_name" \
            --file-system-name "$fs_name" \
            --capacity-in-gbs "$capacity_gb" \
            --performance-tier "$performance_tier" \
            --root-squash-configuration "$root_squash_config" \
            --nsg-ids "[\"$nsg_id\"]" \
            --kms-key-id "$kms_key_id" \
            --output json 2>&1)
    elif [[ -n "$kms_key_id" ]]; then
        result=$(oci lfs lustre-file-system create \
            --compartment-id "$compartment_id" \
            --availability-domain "$ad" \
            --subnet-id "$subnet_id" \
            --display-name "$lfs_name" \
            --file-system-name "$fs_name" \
            --capacity-in-gbs "$capacity_gb" \
            --performance-tier "$performance_tier" \
            --root-squash-configuration "$root_squash_config" \
            --kms-key-id "$kms_key_id" \
            --output json 2>&1)
    elif [[ -n "$nsg_id" ]]; then
        result=$(oci lfs lustre-file-system create \
            --compartment-id "$compartment_id" \
            --availability-domain "$ad" \
            --subnet-id "$subnet_id" \
            --display-name "$lfs_name" \
            --file-system-name "$fs_name" \
            --capacity-in-gbs "$capacity_gb" \
            --performance-tier "$performance_tier" \
            --root-squash-configuration "$root_squash_config" \
            --nsg-ids "[\"$nsg_id\"]" \
            --output json 2>&1)
    else
        result=$(oci lfs lustre-file-system create \
            --compartment-id "$compartment_id" \
            --availability-domain "$ad" \
            --subnet-id "$subnet_id" \
            --display-name "$lfs_name" \
            --file-system-name "$fs_name" \
            --capacity-in-gbs "$capacity_gb" \
            --performance-tier "$performance_tier" \
            --root-squash-configuration "$root_squash_config" \
            --output json 2>&1)
    fi
    
    if echo "$result" | jq -e '.data.id' > /dev/null 2>&1; then
        local new_lfs_id
        new_lfs_id=$(echo "$result" | jq -r '.data.id')
        echo -e "${GREEN}✓ Lustre file system creation initiated${NC}"
        echo -e "  ${CYAN}OCID:${NC} ${YELLOW}$new_lfs_id${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Created $new_lfs_id" >> "$log_file"
    else
        echo -e "${RED}Failed to create Lustre file system${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Lustre - Validate capacity follows sizing rules
# Min 31.2 TB, increment 10.4 TB (≤124.8 TB), increment 41.6 TB (>124.8 TB)
#--------------------------------------------------------------------------------
lfs_validate_capacity() {
    local capacity="$1"
    
    # Check if it's a valid number
    if ! [[ "$capacity" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        return 1
    fi
    
    # Convert to GB and check if it's a multiple of 10400
    local capacity_gb
    capacity_gb=$(echo "scale=0; $capacity * 1000 / 1" | bc)
    
    # Minimum is 31200 GB (3 * 10400)
    if [[ "$capacity_gb" -lt 31200 ]]; then
        return 1
    fi
    
    # Must be multiple of 10400
    local remainder=$((capacity_gb % 10400))
    if [[ "$remainder" -ne 0 ]]; then
        return 1
    fi
    
    return 0
}

# Convert TB to valid GB (multiple of 10400)
lfs_tb_to_gb() {
    local tb="$1"
    echo "scale=0; $tb * 1000 / 1" | bc
}

#--------------------------------------------------------------------------------
# Lustre - Update File System
#--------------------------------------------------------------------------------
lfs_update_file_system() {
    local compartment_id="$1"
    
    LFS_SELECTED=""
    lfs_list_file_systems "$compartment_id" "select"
    
    [[ -z "$LFS_SELECTED" ]] && return
    
    # Get current file system details
    local lfs_json
    lfs_json=$(oci lfs lustre-file-system get --lustre-file-system-id "$LFS_SELECTED" --output json 2>/dev/null)
    
    # Get capacity in GB (API returns GB)
    local current_capacity_gb
    current_capacity_gb=$(echo "$lfs_json" | jq -r '.data["capacity-in-gbs"] // "0"')
    
    # Convert GB to TB for display (1000 GB = 1 TB for Lustre)
    local current_capacity_tb
    current_capacity_tb=$(echo "scale=1; $current_capacity_gb / 1000" | bc)
    
    local current_name
    current_name=$(echo "$lfs_json" | jq -r '.data["display-name"] // "N/A"')
    
    # Get NSG IDs if configured
    local nsg_ids_json
    nsg_ids_json=$(echo "$lfs_json" | jq -c '.data["nsg-ids"] // []')
    local has_nsg="false"
    if [[ "$nsg_ids_json" != "[]" && "$nsg_ids_json" != "null" && -n "$nsg_ids_json" ]]; then
        local nsg_count
        nsg_count=$(echo "$nsg_ids_json" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$nsg_count" -gt 0 ]]; then
            has_nsg="true"
        fi
    fi
    
    echo ""
    echo -e "${WHITE}Current file system:${NC} $current_name"
    echo -e "${WHITE}Current capacity:${NC}    ${current_capacity_tb} TB (${current_capacity_gb} GB)"
    if [[ "$has_nsg" == "true" ]]; then
        echo -e "${WHITE}NSG configured:${NC}      ${GREEN}Yes${NC} (will be preserved)"
    fi
    echo ""
    
    echo -e "${CYAN}What would you like to update?${NC}"
    echo -e "  ${YELLOW}1${NC}) Display name"
    echo -e "  ${YELLOW}2${NC}) Capacity (increase only)"
    echo -n -e "${CYAN}Select #: ${NC}"
    read -r update_type
    
    local update_cmd=""
    local new_name=""
    local new_capacity_gb=""
    local new_capacity_tb=""
    local nsg_param=""
    
    # Build NSG parameter if NSGs are configured
    if [[ "$has_nsg" == "true" ]]; then
        nsg_param="--nsg-ids '$nsg_ids_json'"
    fi
    
    case "$update_type" in
        1)
            echo -n -e "${CYAN}Enter new display name: ${NC}"
            read -r new_name
            [[ -z "$new_name" ]] && { echo -e "${RED}Name required${NC}"; return; }
            update_cmd="oci lfs lustre-file-system update --lustre-file-system-id \"$LFS_SELECTED\" --display-name \"$new_name\""
            [[ -n "$nsg_param" ]] && update_cmd="$update_cmd $nsg_param --force"
            ;;
        2)
            echo ""
            echo -e "${GRAY}Lustre capacity sizing rules:${NC}"
            echo -e "${GRAY}  - Capacity can only be INCREASED (not decreased)${NC}"
            echo -e "${GRAY}  - Minimum: 31200 GB (31.2 TB)${NC}"
            echo -e "${GRAY}  - Increment: 10400 GB (10.4 TB) when capacity ≤ 124800 GB${NC}"
            echo -e "${GRAY}  - Increment: 41600 GB (41.6 TB) when capacity > 124800 GB${NC}"
            echo -e "${GRAY}  - All values must be multiples of 10400 GB${NC}"
            echo ""
            
            # Calculate next valid capacities in GB (must be multiples of 10400)
            echo -e "${CYAN}Suggested next capacities:${NC}"
            local next_caps_gb=()
            local next_caps_tb=()
            
            # Find next valid capacity (round up to next multiple of 10400)
            local next_gb=$((current_capacity_gb + 10400))
            # Round to nearest multiple of 10400
            next_gb=$(( ((next_gb + 10399) / 10400) * 10400 ))
            
            if [[ "$next_gb" -le 124800 ]]; then
                # Show next few 10400 GB increments
                for i in 1 2 3 4 5; do
                    if [[ "$next_gb" -le 124800 ]]; then
                        next_caps_gb+=("$next_gb")
                        local tb_val=$(echo "scale=1; $next_gb / 1000" | bc)
                        next_caps_tb+=("$tb_val")
                        next_gb=$((next_gb + 10400))
                    else
                        break
                    fi
                done
                # Add first 41600 increment option (166400 GB = 166.4 TB)
                if [[ ${#next_caps_gb[@]} -lt 6 ]]; then
                    next_caps_gb+=("166400")
                    next_caps_tb+=("166.4")
                fi
            else
                # Already above 124800, show 41600 increments
                # Round up to next multiple of 41600 above 124800
                next_gb=$(( ((current_capacity_gb - 124800 + 41600) / 41600) * 41600 + 124800 ))
                if [[ "$next_gb" -le "$current_capacity_gb" ]]; then
                    next_gb=$((next_gb + 41600))
                fi
                for i in 1 2 3 4 5; do
                    next_caps_gb+=("$next_gb")
                    local tb_val=$(echo "scale=1; $next_gb / 1000" | bc)
                    next_caps_tb+=("$tb_val")
                    next_gb=$((next_gb + 41600))
                done
            fi
            
            local idx=0
            for i in "${!next_caps_gb[@]}"; do
                ((idx++))
                echo -e "  ${YELLOW}$idx${NC}) ${next_caps_tb[$i]} TB (${next_caps_gb[$i]} GB)"
            done
            echo -e "  ${YELLOW}c${NC}) Custom capacity (in GB)"
            echo ""
            echo -n -e "${CYAN}Select #: ${NC}"
            read -r cap_selection
            
            if [[ "$cap_selection" == "c" || "$cap_selection" == "C" ]]; then
                echo ""
                echo -e "${GRAY}Enter capacity in GB (must be multiple of 10400, e.g., 41600, 52000, 62400)${NC}"
                echo -n -e "${CYAN}Enter new capacity in GB: ${NC}"
                read -r new_capacity_gb
                
                # Validate it's a number
                if ! [[ "$new_capacity_gb" =~ ^[0-9]+$ ]]; then
                    echo -e "${RED}Invalid number${NC}"
                    return
                fi
                
                # Validate it's a multiple of 10400
                if [[ $((new_capacity_gb % 10400)) -ne 0 ]]; then
                    echo -e "${RED}Capacity must be a multiple of 10400 GB${NC}"
                    local suggested=$(( ((new_capacity_gb + 10399) / 10400) * 10400 ))
                    echo -e "${YELLOW}Suggested: ${suggested} GB${NC}"
                    return
                fi
                
                # Validate minimum
                if [[ "$new_capacity_gb" -lt 31200 ]]; then
                    echo -e "${RED}Minimum capacity is 31200 GB${NC}"
                    return
                fi
                
                # Check that it's an increase
                if [[ "$new_capacity_gb" -le "$current_capacity_gb" ]]; then
                    echo -e "${RED}New capacity must be greater than current capacity (${current_capacity_gb} GB)${NC}"
                    return
                fi
                
                new_capacity_tb=$(echo "scale=1; $new_capacity_gb / 1000" | bc)
            elif [[ "$cap_selection" =~ ^[0-9]+$ ]] && [[ "$cap_selection" -ge 1 ]] && [[ "$cap_selection" -le ${#next_caps_gb[@]} ]]; then
                new_capacity_gb="${next_caps_gb[$((cap_selection-1))]}"
                new_capacity_tb="${next_caps_tb[$((cap_selection-1))]}"
            else
                echo -e "${RED}Invalid selection${NC}"
                return
            fi
            
            update_cmd="oci lfs lustre-file-system update --lustre-file-system-id \"$LFS_SELECTED\" --capacity-in-gbs $new_capacity_gb"
            [[ -n "$nsg_param" ]] && update_cmd="$update_cmd $nsg_param --force"
            ;;
        *)
            echo -e "${RED}Invalid selection${NC}"
            return
            ;;
    esac
    
    echo ""
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$update_cmd${NC}"
    if [[ "$update_type" == "2" ]]; then
        echo -e "${GRAY}(${new_capacity_tb} TB = ${new_capacity_gb} GB)${NC}"
    fi
    echo ""
    
    echo -n -e "${YELLOW}Proceed with update? (y/N): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-./logs}/lustre_actions_$(date +%Y%m%d).log"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] UPDATE LUSTRE: $update_cmd" >> "$log_file"
    
    local result
    if [[ "$update_type" == "1" ]]; then
        if [[ "$has_nsg" == "true" ]]; then
            result=$(oci lfs lustre-file-system update \
                --lustre-file-system-id "$LFS_SELECTED" \
                --display-name "$new_name" \
                --nsg-ids "$nsg_ids_json" \
                --force \
                --output json 2>&1)
        else
            result=$(oci lfs lustre-file-system update \
                --lustre-file-system-id "$LFS_SELECTED" \
                --display-name "$new_name" \
                --output json 2>&1)
        fi
    else
        if [[ "$has_nsg" == "true" ]]; then
            result=$(oci lfs lustre-file-system update \
                --lustre-file-system-id "$LFS_SELECTED" \
                --capacity-in-gbs "$new_capacity_gb" \
                --nsg-ids "$nsg_ids_json" \
                --force \
                --output json 2>&1)
        else
            result=$(oci lfs lustre-file-system update \
                --lustre-file-system-id "$LFS_SELECTED" \
                --capacity-in-gbs "$new_capacity_gb" \
                --output json 2>&1)
        fi
    fi
    
    # Check for success - either direct response with data.id OR async work request
    local work_request_id
    work_request_id=$(echo "$result" | jq -r '.["opc-work-request-id"] // empty' 2>/dev/null)
    
    if echo "$result" | jq -e '.data.id' > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Lustre file system updated${NC}"
        if [[ "$update_type" == "2" ]]; then
            echo -e "  ${CYAN}New capacity:${NC} ${new_capacity_tb} TB / ${new_capacity_gb} GB (was ${current_capacity_tb} TB / ${current_capacity_gb} GB)"
        fi
        [[ "$has_nsg" == "true" ]] && echo -e "  ${CYAN}NSG:${NC} Preserved"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Updated $LFS_SELECTED" >> "$log_file"
    elif [[ -n "$work_request_id" ]]; then
        echo -e "${GREEN}✓ Lustre file system update initiated${NC}"
        if [[ "$update_type" == "2" ]]; then
            echo -e "  ${CYAN}New capacity:${NC} ${new_capacity_tb} TB / ${new_capacity_gb} GB (was ${current_capacity_tb} TB / ${current_capacity_gb} GB)"
        fi
        [[ "$has_nsg" == "true" ]] && echo -e "  ${CYAN}NSG:${NC} Preserved"
        echo -e "  ${CYAN}Work Request:${NC} ${YELLOW}$work_request_id${NC}"
        echo -e "  ${GRAY}File system will show UPDATING state until complete${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Update initiated, work-request: $work_request_id" >> "$log_file"
    else
        echo -e "${RED}Failed to update Lustre file system${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Lustre - List Work Requests
#--------------------------------------------------------------------------------
lfs_list_work_requests() {
    local compartment_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Lustre Work Requests ═══${NC}"
    echo ""
    
    local list_cmd="oci lfs work-request list --compartment-id \"$compartment_id\" --all --output json"
    echo -e "${GRAY}$list_cmd${NC}"
    echo ""
    
    local wr_json
    wr_json=$(oci lfs work-request list --compartment-id "$compartment_id" --all --output json 2>/dev/null)
    
    if [[ -z "$wr_json" || "$wr_json" == "null" ]]; then
        echo -e "${YELLOW}No work requests found or unable to list${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    # Handle both .data.items and .data structures
    local wr_count
    wr_count=$(echo "$wr_json" | jq '.data.items | length // 0' 2>/dev/null)
    [[ -z "$wr_count" || "$wr_count" == "null" ]] && wr_count=0
    
    if [[ "$wr_count" -eq 0 ]]; then
        echo -e "${YELLOW}No work requests found${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    echo -e "${GREEN}Found $wr_count work request(s)${NC}"
    echo ""
    
    # Header
    printf "${BOLD}%-3s %-22s %-12s %-6s %-20s %-20s %s${NC}\n" \
        "#" "Operation Type" "Status" "%" "Time Started" "Time Finished" "Work Request ID"
    print_separator 160
    
    local idx=0
    declare -A WR_MAP
    WR_MAP=()
    
    while IFS='|' read -r op_type status percent_complete time_started time_finished wr_id; do
        [[ -z "$op_type" ]] && continue
        ((idx++))
        
        WR_MAP[$idx]="$wr_id"
        
        local status_color="$GREEN"
        case "$status" in
            SUCCEEDED|COMPLETED) status_color="$GREEN" ;;
            IN_PROGRESS|ACCEPTED) status_color="$YELLOW" ;;
            FAILED|CANCELED|CANCELING) status_color="$RED" ;;
            *) status_color="$GRAY" ;;
        esac
        
        # Format times - extract just date and time
        local start_display="${time_started:0:19}"
        [[ "$time_started" == "null" || -z "$time_started" ]] && start_display="N/A"
        start_display="${start_display/T/ }"
        
        local finish_display="${time_finished:0:19}"
        [[ "$time_finished" == "null" || -z "$time_finished" ]] && finish_display="--"
        finish_display="${finish_display/T/ }"
        
        # Shorten operation type for display
        local op_short="$op_type"
        case "$op_type" in
            CREATE_LUSTRE_FILE_SYSTEM) op_short="CREATE_LFS" ;;
            UPDATE_LUSTRE_FILE_SYSTEM) op_short="UPDATE_LFS" ;;
            DELETE_LUSTRE_FILE_SYSTEM) op_short="DELETE_LFS" ;;
            *) op_short="${op_type:0:20}" ;;
        esac
        
        # Format percent
        local pct_display
        if [[ "$percent_complete" == "null" || -z "$percent_complete" ]]; then
            pct_display="--"
        else
            pct_display=$(printf "%.0f%%" "$percent_complete")
        fi
        
        printf "${YELLOW}%-3s${NC} %-22s ${status_color}%-12s${NC} %-6s %-20s %-20s ${GRAY}%s${NC}\n" \
            "$idx" "$op_short" "$status" "$pct_display" "$start_display" "$finish_display" "$wr_id"
            
    done < <(echo "$wr_json" | jq -r '.data.items[] | "\(.["operation-type"])|\(.status)|\(.["percent-complete"])|\(.["time-started"])|\(.["time-finished"])|\(.id)"' 2>/dev/null)
    
    echo ""
    echo -e "${CYAN}Options:${NC}"
    echo -e "  ${YELLOW}#${NC}  View work request details"
    echo -e "  ${WHITE}Enter${NC} to go back"
    echo ""
    echo -n -e "${CYAN}Select #: ${NC}"
    read -r wr_selection
    
    if [[ -n "$wr_selection" && -n "${WR_MAP[$wr_selection]}" ]]; then
        lfs_view_work_request_details "${WR_MAP[$wr_selection]}"
    fi
}

#--------------------------------------------------------------------------------
# Lustre - View Work Request Details
#--------------------------------------------------------------------------------
lfs_view_work_request_details() {
    local wr_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Work Request Details ═══${NC}"
    echo ""
    
    local wr_json
    wr_json=$(oci lfs work-request get --work-request-id "$wr_id" --output json 2>/dev/null)
    
    if [[ -z "$wr_json" || "$wr_json" == "null" ]]; then
        echo -e "${RED}Failed to get work request details${NC}"
        echo ""
        echo -e "Press Enter to continue..."
        read -r
        return
    fi
    
    # Extract fields
    local op_type status percent_complete time_accepted time_started time_finished
    op_type=$(echo "$wr_json" | jq -r '.data["operation-type"] // "N/A"')
    status=$(echo "$wr_json" | jq -r '.data.status // "N/A"')
    percent_complete=$(echo "$wr_json" | jq -r '.data["percent-complete"] // "N/A"')
    time_accepted=$(echo "$wr_json" | jq -r '.data["time-accepted"] // "N/A"')
    time_started=$(echo "$wr_json" | jq -r '.data["time-started"] // "N/A"')
    time_finished=$(echo "$wr_json" | jq -r '.data["time-finished"] // "N/A"')
    
    local status_color="$GREEN"
    case "$status" in
        SUCCEEDED|COMPLETED) status_color="$GREEN" ;;
        IN_PROGRESS|ACCEPTED) status_color="$YELLOW" ;;
        FAILED|CANCELED|CANCELING) status_color="$RED" ;;
        *) status_color="$GRAY" ;;
    esac
    
    echo -e "${BOLD}${CYAN}─── Basic Information ───${NC}"
    echo -e "  ${CYAN}Operation Type:${NC}   ${WHITE}$op_type${NC}"
    echo -e "  ${CYAN}Status:${NC}           ${status_color}$status${NC}"
    echo -e "  ${CYAN}Progress:${NC}         ${WHITE}${percent_complete}%${NC}"
    echo -e "  ${CYAN}Work Request ID:${NC}  ${YELLOW}$wr_id${NC}"
    echo ""
    
    echo -e "${BOLD}${CYAN}─── Timing ───${NC}"
    echo -e "  ${CYAN}Time Accepted:${NC}    ${WHITE}${time_accepted/T/ }${NC}"
    echo -e "  ${CYAN}Time Started:${NC}     ${WHITE}${time_started/T/ }${NC}"
    echo -e "  ${CYAN}Time Finished:${NC}    ${WHITE}${time_finished/T/ }${NC}"
    
    # Calculate duration if both start and finish are available
    if [[ "$time_started" != "N/A" && "$time_started" != "null" && "$time_finished" != "N/A" && "$time_finished" != "null" ]]; then
        local start_epoch finish_epoch duration_sec
        start_epoch=$(date -d "${time_started}" +%s 2>/dev/null || echo "0")
        finish_epoch=$(date -d "${time_finished}" +%s 2>/dev/null || echo "0")
        if [[ "$start_epoch" -gt 0 && "$finish_epoch" -gt 0 ]]; then
            duration_sec=$((finish_epoch - start_epoch))
            local duration_min=$((duration_sec / 60))
            local duration_sec_rem=$((duration_sec % 60))
            echo -e "  ${CYAN}Duration:${NC}         ${WHITE}${duration_min}m ${duration_sec_rem}s${NC}"
        fi
    fi
    echo ""
    
    # Resources affected
    local resources
    resources=$(echo "$wr_json" | jq -r '.data.resources // []')
    local resource_count
    resource_count=$(echo "$resources" | jq 'length' 2>/dev/null || echo "0")
    
    if [[ "$resource_count" -gt 0 ]]; then
        echo -e "${BOLD}${CYAN}─── Resources Affected ───${NC}"
        while IFS='|' read -r entity_type entity_uri action_type; do
            [[ -z "$entity_type" ]] && continue
            echo -e "  ${CYAN}Type:${NC}   ${WHITE}$entity_type${NC}"
            echo -e "  ${CYAN}Action:${NC} ${WHITE}$action_type${NC}"
            echo -e "  ${CYAN}URI:${NC}    ${YELLOW}$entity_uri${NC}"
            echo ""
        done < <(echo "$resources" | jq -r '.[] | "\(.["entity-type"])|\(.["entity-uri"])|\(.["action-type"])"' 2>/dev/null)
    fi
    
    # Fetch errors from separate API (errors are not in the main work-request get response)
    echo -e "${BOLD}${RED}─── Errors ───${NC}"
    local errors_json
    errors_json=$(oci lfs work-request-error list --work-request-id "$wr_id" --all --output json 2>/dev/null)
    
    local error_count=0
    if [[ -n "$errors_json" && "$errors_json" != "null" ]]; then
        error_count=$(echo "$errors_json" | jq '.data.items | length // 0' 2>/dev/null || echo "0")
    fi
    
    if [[ "$error_count" -gt 0 ]]; then
        while IFS='|' read -r code message timestamp; do
            [[ -z "$code" ]] && continue
            local ts_display="${timestamp/T/ }"
            ts_display="${ts_display:0:19}"
            echo -e "  ${RED}Code:${NC}      ${WHITE}$code${NC}"
            echo -e "  ${RED}Message:${NC}   ${WHITE}$message${NC}"
            echo -e "  ${RED}Timestamp:${NC} ${GRAY}$ts_display${NC}"
            echo ""
        done < <(echo "$errors_json" | jq -r '.data.items[] | "\(.code)|\(.message)|\(.timestamp)"' 2>/dev/null)
    else
        echo -e "  ${GREEN}No errors${NC}"
    fi
    echo ""
    
    # Logs
    echo -e "${BOLD}${CYAN}─── Work Request Logs ───${NC}"
    local logs_json
    logs_json=$(oci lfs work-request-log list --work-request-id "$wr_id" --all --output json 2>/dev/null)
    
    local log_count=0
    if [[ -n "$logs_json" && "$logs_json" != "null" ]]; then
        log_count=$(echo "$logs_json" | jq '.data.items | length // 0' 2>/dev/null || echo "0")
    fi
    
    if [[ "$log_count" -gt 0 ]]; then
        echo ""
        while IFS='|' read -r timestamp message; do
            [[ -z "$timestamp" ]] && continue
            local ts_display="${timestamp/T/ }"
            ts_display="${ts_display:0:19}"
            echo -e "  ${GRAY}[$ts_display]${NC} ${WHITE}$message${NC}"
        done < <(echo "$logs_json" | jq -r '.data.items[] | "\(.timestamp)|\(.message)"' 2>/dev/null)
    else
        echo -e "  ${GRAY}No logs available${NC}"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Lustre - Delete File System
#--------------------------------------------------------------------------------
lfs_delete_file_system() {
    local compartment_id="$1"
    
    LFS_SELECTED=""
    lfs_list_file_systems "$compartment_id" "select"
    
    [[ -z "$LFS_SELECTED" ]] && return
    
    echo ""
    echo -e "${RED}WARNING: This will permanently delete the Lustre file system and ALL data!${NC}"
    echo ""
    local delete_cmd="oci lfs lustre-file-system delete --lustre-file-system-id \"$LFS_SELECTED\" --force"
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$delete_cmd${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm: ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/lustre_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DELETE LUSTRE: $delete_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Deleting Lustre file system...${NC}"
    
    local result
    result=$(oci lfs lustre-file-system delete \
        --lustre-file-system-id "$LFS_SELECTED" \
        --force 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Lustre file system deletion initiated${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Deleted $LFS_SELECTED" >> "$log_file"
    else
        echo -e "${RED}Failed to delete Lustre file system${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Lustre - List Object Storage Links
#--------------------------------------------------------------------------------
lfs_list_object_storage_links() {
    local compartment_id="$1"
    local action="${2:-none}"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Object Storage Links ═══${NC}"
    echo ""
    
    local list_cmd="oci lfs object-storage-link-collection list-object-storage-links --compartment-id \"$compartment_id\" --all --output json"
    echo -e "${GRAY}$list_cmd${NC}"
    echo ""
    
    local links_json
    links_json=$(oci lfs object-storage-link-collection list-object-storage-links \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>/dev/null)
    
    if [[ -z "$links_json" || "$links_json" == "null" ]]; then
        echo -e "${YELLOW}No Object Storage links found or unable to list${NC}"
        return 1
    fi
    
    local link_count
    link_count=$(echo "$links_json" | jq '.data.items | length' 2>/dev/null)
    
    if [[ "$link_count" -eq 0 || -z "$link_count" ]]; then
        echo -e "${YELLOW}No Object Storage links found${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Found $link_count Object Storage link(s)${NC}"
    echo ""
    
    printf "${BOLD}%-3s %-25s %-12s %-30s %s${NC}\n" "#" "Display Name" "State" "Bucket" "Link OCID"
    print_separator 160
    
    local idx=0
    declare -gA LFS_LINK_MAP
    LFS_LINK_MAP=()
    
    while IFS='|' read -r display_name state bucket_name link_id; do
        [[ -z "$display_name" ]] && continue
        ((idx++))
        
        LFS_LINK_MAP[$idx]="$link_id"
        
        local state_color="$GREEN"
        case "$state" in
            ACTIVE) state_color="$GREEN" ;;
            CREATING|UPDATING) state_color="$YELLOW" ;;
            DELETING|DELETED|FAILED) state_color="$RED" ;;
            *) state_color="$GRAY" ;;
        esac
        
        local name_trunc="${display_name:0:23}"
        [[ ${#display_name} -gt 23 ]] && name_trunc="${name_trunc}.."
        
        local bucket_trunc="${bucket_name:0:28}"
        [[ ${#bucket_name} -gt 28 ]] && bucket_trunc="${bucket_trunc}.."
        
        printf "${YELLOW}%-3s${NC} %-25s ${state_color}%-12s${NC} %-30s ${GRAY}%s${NC}\n" \
            "$idx" "$name_trunc" "$state" "$bucket_trunc" "$link_id"
            
    done < <(echo "$links_json" | jq -r '.data.items[] | "\(.["display-name"])|\(.["lifecycle-state"])|\(.["bucket-name"] // "N/A")|\(.id)"' 2>/dev/null)
    
    LFS_LINK_COUNT=$idx
    echo ""
    
    case "$action" in
        none)
            echo -e "Press Enter to continue..."
            read -r
            ;;
        select)
            echo -n -e "${CYAN}Enter link # (or Enter to cancel): ${NC}"
            read -r link_selection
            if [[ -n "$link_selection" && -n "${LFS_LINK_MAP[$link_selection]}" ]]; then
                LFS_SELECTED_LINK="${LFS_LINK_MAP[$link_selection]}"
            fi
            ;;
    esac
    
    return 0
}

#--------------------------------------------------------------------------------
# Lustre - Create Object Storage Link
#--------------------------------------------------------------------------------
lfs_create_object_storage_link() {
    local compartment_id="$1"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Create Object Storage Link ═══${NC}"
    echo ""
    
    # Select Lustre file system
    echo -e "${CYAN}Select a Lustre file system:${NC}"
    LFS_SELECTED=""
    lfs_list_file_systems "$compartment_id" "select"
    
    if [[ -z "$LFS_SELECTED" ]]; then
        echo -e "${RED}No Lustre file system selected${NC}"
        return
    fi
    
    echo -n -e "${CYAN}Enter Object Storage namespace: ${NC}"
    read -r os_namespace
    
    echo -n -e "${CYAN}Enter bucket name: ${NC}"
    read -r bucket_name
    
    echo -n -e "${CYAN}Enter link display name: ${NC}"
    read -r link_name
    
    if [[ -z "$os_namespace" || -z "$bucket_name" ]]; then
        echo -e "${RED}Namespace and bucket name are required${NC}"
        return
    fi
    
    [[ -z "$link_name" ]] && link_name="link-$bucket_name"
    
    echo ""
    local create_cmd="oci lfs object-storage-link create --lustre-file-system-id \"$LFS_SELECTED\" --bucket-name \"$bucket_name\" --namespace \"$os_namespace\" --display-name \"$link_name\""
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$create_cmd${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Proceed with creation? (y/N): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/lustre_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] CREATE OS LINK: $create_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Creating Object Storage link...${NC}"
    
    local result
    result=$(oci lfs object-storage-link create \
        --lustre-file-system-id "$LFS_SELECTED" \
        --bucket-name "$bucket_name" \
        --namespace "$os_namespace" \
        --display-name "$link_name" \
        --output json 2>&1)
    
    if echo "$result" | jq -e '.data.id' > /dev/null 2>&1; then
        local new_link_id
        new_link_id=$(echo "$result" | jq -r '.data.id')
        echo -e "${GREEN}✓ Object Storage link created${NC}"
        echo -e "  ${CYAN}OCID:${NC} ${YELLOW}$new_link_id${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Created $new_link_id" >> "$log_file"
    else
        echo -e "${RED}Failed to create Object Storage link${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Lustre - Start Import from Object Storage
#--------------------------------------------------------------------------------
lfs_start_import_from_object() {
    local compartment_id="$1"
    
    LFS_SELECTED_LINK=""
    lfs_list_object_storage_links "$compartment_id" "select"
    
    [[ -z "$LFS_SELECTED_LINK" ]] && return
    
    echo ""
    local import_cmd="oci lfs object-storage-link start-import-from-object --object-storage-link-id \"$LFS_SELECTED_LINK\""
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$import_cmd${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Start import from Object Storage? (y/N): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/lustre_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] START IMPORT: $import_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Starting import...${NC}"
    
    local result
    result=$(oci lfs object-storage-link start-import-from-object \
        --object-storage-link-id "$LFS_SELECTED_LINK" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Import started${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Import started for $LFS_SELECTED_LINK" >> "$log_file"
    else
        echo -e "${RED}Failed to start import${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Lustre - Start Export to Object Storage
#--------------------------------------------------------------------------------
lfs_start_export_to_object() {
    local compartment_id="$1"
    
    LFS_SELECTED_LINK=""
    lfs_list_object_storage_links "$compartment_id" "select"
    
    [[ -z "$LFS_SELECTED_LINK" ]] && return
    
    echo ""
    local export_cmd="oci lfs object-storage-link start-export-to-object --object-storage-link-id \"$LFS_SELECTED_LINK\""
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$export_cmd${NC}"
    echo ""
    
    echo -n -e "${YELLOW}Start export to Object Storage? (y/N): ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/lustre_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] START EXPORT: $export_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Starting export...${NC}"
    
    local result
    result=$(oci lfs object-storage-link start-export-to-object \
        --object-storage-link-id "$LFS_SELECTED_LINK" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Export started${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Export started for $LFS_SELECTED_LINK" >> "$log_file"
    else
        echo -e "${RED}Failed to start export${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Lustre - Delete Object Storage Link
#--------------------------------------------------------------------------------
lfs_delete_object_storage_link() {
    local compartment_id="$1"
    
    LFS_SELECTED_LINK=""
    lfs_list_object_storage_links "$compartment_id" "select"
    
    [[ -z "$LFS_SELECTED_LINK" ]] && return
    
    echo ""
    echo -e "${RED}WARNING: This will delete the Object Storage link!${NC}"
    echo ""
    local delete_cmd="oci lfs object-storage-link delete --object-storage-link-id \"$LFS_SELECTED_LINK\" --force"
    echo -e "${GRAY}Command to execute:${NC}"
    echo -e "${WHITE}$delete_cmd${NC}"
    echo ""
    
    echo -n -e "${RED}Type 'DELETE' to confirm: ${NC}"
    read -r confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
        echo -e "${YELLOW}Cancelled${NC}"
        return
    fi
    
    local log_file="${LOG_DIR:-/tmp}/lustre_actions_$(date +%Y%m%d).log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DELETE OS LINK: $delete_cmd" >> "$log_file"
    
    echo ""
    echo -e "${CYAN}Deleting Object Storage link...${NC}"
    
    local result
    result=$(oci lfs object-storage-link delete \
        --object-storage-link-id "$LFS_SELECTED_LINK" \
        --force 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Object Storage link deleted${NC}"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: Deleted $LFS_SELECTED_LINK" >> "$log_file"
    else
        echo -e "${RED}Failed to delete Object Storage link${NC}"
        echo "$result"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $result" >> "$log_file"
    fi
    
    echo ""
    echo -e "Press Enter to continue..."
    read -r
}

#--------------------------------------------------------------------------------
# Manage Capacity Topology - View host lifecycle states summary
#--------------------------------------------------------------------------------
manage_capacity_topology() {
    local tenancy_id="${TENANCY_ID:-}"
    
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}${CYAN}                                      CAPACITY TOPOLOGY                                                         ${NC}"
        echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        if [[ -z "$tenancy_id" ]]; then
            echo -e "${RED}TENANCY_ID not set. Cannot query capacity topology.${NC}"
            echo ""
            echo -n -e "${CYAN}Press Enter to return...${NC}"
            read -r
            return
        fi
        
        # Refresh capacity topology cache
        echo -e "${CYAN}Fetching capacity topology data...${NC}"
        fetch_capacity_topology
        
        if [[ ! -f "$CAPACITY_TOPOLOGY_CACHE" ]]; then
            echo -e "${RED}Failed to fetch capacity topology data${NC}"
            echo ""
            echo -n -e "${CYAN}Press Enter to return...${NC}"
            read -r
            return
        fi
        
        # Count total hosts (excluding comment lines)
        local total_hosts
        total_hosts=$(grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | wc -l)
        
        if [[ "$total_hosts" -eq 0 ]]; then
            echo -e "${YELLOW}No capacity topology hosts found${NC}"
            echo ""
            echo -n -e "${CYAN}Press Enter to return...${NC}"
            read -r
            return
        fi
        
        echo ""
        echo -e "${BOLD}${WHITE}═══ Summary ═══════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${WHITE}Total Hosts:${NC} ${GREEN}$total_hosts${NC}"
        echo ""
        
        #-----------------------------------------------------------------------
        # Lifecycle State Summary
        #-----------------------------------------------------------------------
        echo -e "${BOLD}${WHITE}─── Lifecycle State Summary ───────────────────────────────────────────────────────────────────────────────────${NC}"
        printf "  ${BOLD}%-25s %8s %8s${NC}\n" "STATE" "COUNT" "PERCENT"
        echo -e "  ─────────────────────────────────────────────"
        
        # Get unique lifecycle states and counts
        grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | cut -d'|' -f2 | sort | uniq -c | sort -rn | while read -r count state; do
            local pct
            pct=$(echo "scale=1; $count * 100 / $total_hosts" | bc)
            
            local state_color="$WHITE"
            case "$state" in
                ACTIVE|HEALTHY) state_color="$GREEN" ;;
                DEGRADED|IMPAIRED) state_color="$YELLOW" ;;
                INACTIVE|FAILED|UNAVAILABLE) state_color="$RED" ;;
                *) state_color="$GRAY" ;;
            esac
            
            printf "  ${state_color}%-25s${NC} %8s %7s%%\n" "$state" "$count" "$pct"
        done
        
        echo ""
        
        #-----------------------------------------------------------------------
        # Lifecycle Details Summary
        #-----------------------------------------------------------------------
        echo -e "${BOLD}${WHITE}─── Lifecycle Details Summary ─────────────────────────────────────────────────────────────────────────────────${NC}"
        printf "  ${BOLD}%-40s %8s %8s${NC}\n" "DETAILS" "COUNT" "PERCENT"
        echo -e "  ─────────────────────────────────────────────────────────────"
        
        # Get unique lifecycle details and counts
        grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | cut -d'|' -f3 | sort | uniq -c | sort -rn | while read -r count details; do
            local pct
            pct=$(echo "scale=1; $count * 100 / $total_hosts" | bc)
            
            local details_color="$WHITE"
            local details_display="${details:0:38}"
            [[ ${#details} -gt 38 ]] && details_display="${details_display}.."
            
            case "$details" in
                N/A|"") 
                    details_color="$GRAY"
                    details_display="(none)"
                    ;;
                *HEALTHY*|*ACTIVE*) details_color="$GREEN" ;;
                *DEGRADED*|*WARNING*|*IMPAIRED*) details_color="$YELLOW" ;;
                *FAILED*|*ERROR*|*UNAVAILABLE*) details_color="$RED" ;;
                *) details_color="$WHITE" ;;
            esac
            
            printf "  ${details_color}%-40s${NC} %8s %7s%%\n" "$details_display" "$count" "$pct"
        done
        
        echo ""
        
        #-----------------------------------------------------------------------
        # Topology Summary (by Topology OCID)
        #-----------------------------------------------------------------------
        echo -e "${BOLD}${WHITE}─── Topology Summary ──────────────────────────────────────────────────────────────────────────────────────────${NC}"
        printf "  ${BOLD}%-50s %8s${NC}\n" "TOPOLOGY OCID" "HOSTS"
        echo -e "  ─────────────────────────────────────────────────────────────"
        
        grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | cut -d'|' -f4 | sort | uniq -c | sort -rn | while read -r count topo_id; do
            local topo_short="${topo_id:0:48}"
            [[ ${#topo_id} -gt 48 ]] && topo_short="${topo_short}.."
            printf "  ${YELLOW}%-50s${NC} %8s\n" "$topo_short" "$count"
        done
        
        echo ""
        
        #-----------------------------------------------------------------------
        # Actions Menu
        #-----------------------------------------------------------------------
        echo -e "${BOLD}${WHITE}─── Actions ───────────────────────────────────────────────────────────────────────────────────────────────────${NC}"
        echo -e "  ${GREEN}1${NC}) View hosts by lifecycle state"
        echo -e "  ${GREEN}2${NC}) View hosts by lifecycle details"
        echo -e "  ${GREEN}3${NC}) View all hosts (detailed)"
        echo -e "  ${GREEN}r${NC}) Refresh data"
        echo -e "  ${WHITE}Enter${NC}) Return to menu"
        echo ""
        echo -n -e "${CYAN}Select [1-3/r/Enter]: ${NC}"
        
        local choice
        read -r choice
        
        case "$choice" in
            1)
                capacity_topology_view_by_state
                ;;
            2)
                capacity_topology_view_by_details
                ;;
            3)
                capacity_topology_view_all_hosts
                ;;
            r|R)
                # Force refresh by removing cache
                rm -f "$CAPACITY_TOPOLOGY_CACHE"
                echo -e "${YELLOW}Cache cleared, refreshing...${NC}"
                sleep 1
                ;;
            *)
                return
                ;;
        esac
    done
}

#--------------------------------------------------------------------------------
# Capacity Topology - View hosts filtered by lifecycle state
#--------------------------------------------------------------------------------
capacity_topology_view_by_state() {
    echo ""
    echo -e "${CYAN}Select lifecycle state to filter:${NC}"
    
    # Get unique states
    local states
    states=$(grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | cut -d'|' -f2 | sort -u)
    
    local idx=0
    declare -A state_map
    while IFS= read -r state; do
        [[ -z "$state" ]] && continue
        ((idx++))
        state_map[$idx]="$state"
        local count
        count=$(grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | cut -d'|' -f2 | grep -c "^${state}$")
        echo -e "  ${GREEN}$idx${NC}) $state ($count hosts)"
    done <<< "$states"
    
    echo ""
    echo -n -e "${CYAN}Select #: ${NC}"
    read -r sel
    
    local selected_state="${state_map[$sel]}"
    [[ -z "$selected_state" ]] && return
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Hosts with Lifecycle State: ${CYAN}$selected_state${NC} ${BOLD}${WHITE}═══${NC}"
    echo ""
    printf "${BOLD}%-50s %-15s %-30s${NC}\n" "INSTANCE OCID" "STATE" "DETAILS"
    echo "─────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | grep "|${selected_state}|" | while IFS='|' read -r inst_id state details topo_id; do
        local inst_short="${inst_id:0:48}"
        [[ ${#inst_id} -gt 48 ]] && inst_short="${inst_short}.."
        
        local state_color="$GREEN"
        case "$state" in
            ACTIVE|HEALTHY) state_color="$GREEN" ;;
            DEGRADED|IMPAIRED) state_color="$YELLOW" ;;
            INACTIVE|FAILED|UNAVAILABLE) state_color="$RED" ;;
        esac
        
        local details_display="${details:0:28}"
        [[ ${#details} -gt 28 ]] && details_display="${details_display}.."
        [[ "$details" == "N/A" ]] && details_display="-"
        
        printf "${YELLOW}%-50s${NC} ${state_color}%-15s${NC} %-30s\n" "$inst_short" "$state" "$details_display"
    done
    
    echo ""
    echo -n -e "${CYAN}Press Enter to continue...${NC}"
    read -r
}

#--------------------------------------------------------------------------------
# Capacity Topology - View hosts filtered by lifecycle details
#--------------------------------------------------------------------------------
capacity_topology_view_by_details() {
    echo ""
    echo -e "${CYAN}Select lifecycle details to filter:${NC}"
    
    # Get unique details
    local details_list
    details_list=$(grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | cut -d'|' -f3 | sort -u)
    
    local idx=0
    declare -A details_map
    while IFS= read -r details; do
        [[ -z "$details" ]] && continue
        ((idx++))
        details_map[$idx]="$details"
        local count
        count=$(grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | awk -F'|' -v d="$details" '$3 == d' | wc -l)
        local display="${details:0:50}"
        [[ "$details" == "N/A" ]] && display="(none)"
        echo -e "  ${GREEN}$idx${NC}) $display ($count hosts)"
    done <<< "$details_list"
    
    echo ""
    echo -n -e "${CYAN}Select #: ${NC}"
    read -r sel
    
    local selected_details="${details_map[$sel]}"
    [[ -z "$selected_details" ]] && return
    
    local display_title="$selected_details"
    [[ "$selected_details" == "N/A" ]] && display_title="(none)"
    
    echo ""
    echo -e "${BOLD}${WHITE}═══ Hosts with Lifecycle Details: ${CYAN}$display_title${NC} ${BOLD}${WHITE}═══${NC}"
    echo ""
    printf "${BOLD}%-50s %-15s %-30s${NC}\n" "INSTANCE OCID" "STATE" "DETAILS"
    echo "─────────────────────────────────────────────────────────────────────────────────────────────────────"
    
    grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | awk -F'|' -v d="$selected_details" '$3 == d' | while IFS='|' read -r inst_id state details topo_id; do
        local inst_short="${inst_id:0:48}"
        [[ ${#inst_id} -gt 48 ]] && inst_short="${inst_short}.."
        
        local state_color="$GREEN"
        case "$state" in
            ACTIVE|HEALTHY) state_color="$GREEN" ;;
            DEGRADED|IMPAIRED) state_color="$YELLOW" ;;
            INACTIVE|FAILED|UNAVAILABLE) state_color="$RED" ;;
        esac
        
        local details_display="${details:0:28}"
        [[ ${#details} -gt 28 ]] && details_display="${details_display}.."
        [[ "$details" == "N/A" ]] && details_display="-"
        
        printf "${YELLOW}%-50s${NC} ${state_color}%-15s${NC} %-30s\n" "$inst_short" "$state" "$details_display"
    done
    
    echo ""
    echo -n -e "${CYAN}Press Enter to continue...${NC}"
    read -r
}

#--------------------------------------------------------------------------------
# Capacity Topology - View all hosts detailed
#--------------------------------------------------------------------------------
capacity_topology_view_all_hosts() {
    echo ""
    echo -e "${BOLD}${WHITE}═══ All Capacity Topology Hosts ═══${NC}"
    echo ""
    printf "${BOLD}%-55s %-12s %-25s %-30s${NC}\n" "INSTANCE OCID" "STATE" "DETAILS" "TOPOLOGY"
    echo "═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════"
    
    grep -v "^#" "$CAPACITY_TOPOLOGY_CACHE" | sort -t'|' -k2,2 -k3,3 | while IFS='|' read -r inst_id state details topo_id; do
        local inst_short="${inst_id:0:53}"
        [[ ${#inst_id} -gt 53 ]] && inst_short="${inst_short}.."
        
        local state_color="$GREEN"
        case "$state" in
            ACTIVE|HEALTHY) state_color="$GREEN" ;;
            DEGRADED|IMPAIRED) state_color="$YELLOW" ;;
            INACTIVE|FAILED|UNAVAILABLE) state_color="$RED" ;;
        esac
        
        local details_display="${details:0:23}"
        [[ ${#details} -gt 23 ]] && details_display="${details_display}.."
        [[ "$details" == "N/A" ]] && details_display="-"
        
        local topo_short="${topo_id:0:28}"
        [[ ${#topo_id} -gt 28 ]] && topo_short="${topo_short}.."
        
        printf "${YELLOW}%-55s${NC} ${state_color}%-12s${NC} %-25s ${GRAY}%-30s${NC}\n" "$inst_short" "$state" "$details_display" "$topo_short"
    done | less -R
    
    echo ""
    echo -n -e "${CYAN}Press Enter to continue...${NC}"
    read -r
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
# Manage NVIDIA GPU Stack Health - Check GPU Operator & DRA per node
#--------------------------------------------------------------------------------
manage_nvidia_gpu_stack_health() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}                                                    NVIDIA GPU STACK HEALTH CHECK                                                                      ${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Check if kubectl is available
    if ! command -v kubectl &>/dev/null; then
        echo -e "${RED}kubectl not available - cannot check GPU stack health${NC}"
        echo ""
        echo -e "Press Enter to return..."
        read -r
        return 1
    fi
    
    # Test cluster connectivity
    if ! kubectl cluster-info &>/dev/null; then
        echo -e "${RED}Cannot connect to Kubernetes cluster${NC}"
        echo ""
        echo -e "Press Enter to return..."
        read -r
        return 1
    fi
    
    echo -e "${GRAY}Fetching node and pod information...${NC}"
    echo ""
    
    # Show validation commands used
    echo -e "${BOLD}${WHITE}═══ Validation Commands ═══${NC}"
    echo ""
    echo -e "${GRAY}Node & GPU info:${NC}"
    echo -e "  ${CYAN}kubectl get nodes -o json | jq '.items[] | {name, gpu: .status.capacity[\"nvidia.com/gpu\"], taints: .spec.taints}'${NC}"
    echo ""
    echo -e "${GRAY}GPU Operator pods per node:${NC}"
    echo -e "  ${CYAN}kubectl get pods -n gpu-operator -o json | jq '.items[] | {node: .spec.nodeName, name: .metadata.name, phase: .status.phase}'${NC}"
    echo ""
    echo -e "${GRAY}DRA Driver pods per node:${NC}"
    echo -e "  ${CYAN}kubectl get pods -n nvidia-dra-driver-gpu -o json | jq '.items[] | {node: .spec.nodeName, name: .metadata.name, phase: .status.phase}'${NC}"
    echo ""
    echo -e "${GRAY}DRA Controller (deployment - runs on any node):${NC}"
    echo -e "  ${CYAN}kubectl get pods -n nvidia-dra-driver-gpu -l app=nvidia-dra-controller -o wide${NC}"
    echo ""
    
    # Get all nodes with GPU info including taints
    local nodes_json
    nodes_json=$(kubectl get nodes -o json 2>/dev/null)
    
    if [[ -z "$nodes_json" ]]; then
        echo -e "${RED}Failed to get nodes${NC}"
        echo ""
        echo -e "Press Enter to return..."
        read -r
        return 1
    fi
    
    # Build node list with GPU detection and taints
    local node_data
    node_data=$(echo "$nodes_json" | jq -r '
        .items[] | 
        {
            name: .metadata.name,
            gpu_count: (.status.capacity["nvidia.com/gpu"] // "0"),
            gpu_product: (.metadata.labels["nvidia.com/gpu.product"] // "-"),
            ready: (.status.conditions[] | select(.type=="Ready") | .status),
            unschedulable: (.spec.unschedulable // false),
            taints: ((.spec.taints // []) | map(.key + "=" + (.value // "") + ":" + .effect) | join(","))
        } | "\(.name)|\(.gpu_count)|\(.gpu_product)|\(.ready)|\(.unschedulable)|\(.taints)"
    ' 2>/dev/null)
    
    # Get all pods from gpu-operator namespace with ready status
    # Format: nodeName|podName|phase|readyContainers/totalContainers
    local gpu_op_pods
    gpu_op_pods=$(kubectl get pods -n gpu-operator -o json 2>/dev/null | jq -r '
        .items[] | 
        ((.status.containerStatuses // []) | map(select(.ready == true)) | length) as $ready |
        ((.status.containerStatuses // []) | length) as $total |
        "\(.spec.nodeName // "N/A")|\(.metadata.name)|\(.status.phase)|\($ready)/\($total)"
    ' 2>/dev/null)
    
    # Get all pods from nvidia-dra-driver-gpu namespace with ready status
    # Format: nodeName|podName|phase|readyContainers/totalContainers
    local dra_pods
    dra_pods=$(kubectl get pods -n nvidia-dra-driver-gpu -o json 2>/dev/null | jq -r '
        .items[] | 
        ((.status.containerStatuses // []) | map(select(.ready == true)) | length) as $ready |
        ((.status.containerStatuses // []) | length) as $total |
        "\(.spec.nodeName // "N/A")|\(.metadata.name)|\(.status.phase)|\($ready)/\($total)"
    ' 2>/dev/null)
    
    # Check if namespaces exist
    local gpu_op_ns_exists=false
    local dra_ns_exists=false
    kubectl get ns gpu-operator &>/dev/null && gpu_op_ns_exists=true
    kubectl get ns nvidia-dra-driver-gpu &>/dev/null && dra_ns_exists=true
    
    # Check DRA kubelet plugin status globally
    # Pattern matches: nvidia-dra-driver-gpu-kubelet-plugin-* or *-k8s-dra-driver-kubelet-plugin-*
    local dra_kubelet_plugin_count=0
    local dra_kubelet_plugin_ready=0
    local dra_kubelet_plugin_status="${GRAY}-"
    if [[ "$dra_ns_exists" == "true" ]]; then
        # Count kubelet-plugin pods and their ready status (flexible pattern)
        while IFS='|' read -r node_name pod_name phase ready_status; do
            if [[ "$pod_name" == *"kubelet-plugin"* ]]; then
                ((dra_kubelet_plugin_count++))
                if [[ "$phase" == "Running" ]]; then
                    # Check if all containers are ready (e.g., "2/2" means ready)
                    local ready_num total_num
                    ready_num=$(echo "$ready_status" | cut -d'/' -f1)
                    total_num=$(echo "$ready_status" | cut -d'/' -f2)
                    if [[ "$ready_num" == "$total_num" && "$total_num" != "0" ]]; then
                        ((dra_kubelet_plugin_ready++))
                    fi
                fi
            fi
        done <<< "$dra_pods"
        
        if [[ $dra_kubelet_plugin_count -gt 0 ]]; then
            if [[ $dra_kubelet_plugin_ready -eq $dra_kubelet_plugin_count ]]; then
                dra_kubelet_plugin_status="${GREEN}✓ ${dra_kubelet_plugin_ready}/${dra_kubelet_plugin_count} Ready"
            else
                dra_kubelet_plugin_status="${YELLOW}◐ ${dra_kubelet_plugin_ready}/${dra_kubelet_plugin_count} Ready"
            fi
        else
            dra_kubelet_plugin_status="${RED}✗ No kubelet-plugin pods found"
        fi
    fi
    
    # Summary section
    echo -e "${BOLD}${WHITE}═══ Namespace Status ═══${NC}"
    echo ""
    if [[ "$gpu_op_ns_exists" == "true" ]]; then
        local gpu_op_pod_count
        gpu_op_pod_count=$(kubectl get pods -n gpu-operator --no-headers 2>/dev/null | wc -l | tr -d ' ')
        echo -e "  ${CYAN}gpu-operator:${NC}          ${GREEN}EXISTS${NC} (${gpu_op_pod_count} pods)"
        
        # Check if using host drivers (no nvidia-driver pods)
        local driver_pod_count
        driver_pod_count=$(kubectl get pods -n gpu-operator --no-headers 2>/dev/null | grep -c "nvidia-driver" 2>/dev/null || true)
        driver_pod_count=${driver_pod_count:-0}
        driver_pod_count=$(echo "$driver_pod_count" | tr -d '[:space:]')
        if [[ -z "$driver_pod_count" || "$driver_pod_count" == "0" ]]; then
            echo -e "  ${CYAN}Driver Mode:${NC}           ${GRAY}HOST${NC} (driver.enabled: false - using pre-installed drivers)"
        else
            echo -e "  ${CYAN}Driver Mode:${NC}           ${GREEN}OPERATOR${NC} (${driver_pod_count} nvidia-driver pods)"
        fi
    else
        echo -e "  ${CYAN}gpu-operator:${NC}          ${RED}NOT FOUND${NC}"
    fi
    
    if [[ "$dra_ns_exists" == "true" ]]; then
        local dra_pod_count
        dra_pod_count=$(kubectl get pods -n nvidia-dra-driver-gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')
        echo -e "  ${CYAN}nvidia-dra-driver-gpu:${NC} ${GREEN}EXISTS${NC} (${dra_pod_count} pods)"
        echo -e "  ${CYAN}DRA Kubelet Plugin:${NC}    ${dra_kubelet_plugin_status}${NC}"
    else
        echo -e "  ${CYAN}nvidia-dra-driver-gpu:${NC} ${RED}NOT FOUND${NC}"
    fi
    echo ""
    
    # Build header for component matrix
    echo -e "${BOLD}${WHITE}═══ Per-Node Component Status (GPU Nodes Only) ═══${NC}"
    echo ""
    echo -e "${GRAY}Components: driver=NVIDIA Driver (or 'host' if using pre-installed drivers) | toolkit=Container Toolkit | plugin=Device Plugin${NC}"
    echo -e "${GRAY}            gfd=GPU Feature Discovery | dcgm=DCGM Exporter | validator=Operator Validator | mig-mgr=MIG Manager${NC}"
    echo -e "${GRAY}            dra-drv=DRA Kubelet Plugin (*kubelet-plugin* pods in nvidia-dra-driver-gpu namespace)${NC}"
    echo ""
    
    # Print header
    printf "${BOLD}%-3s %-28s %-5s %-6s %-20s %-7s %-7s %-7s %-5s %-5s %-9s %-8s %-8s %-80s${NC}\n" \
        "#" "Node Name" "GPUs" "Ready" "GPU Product" "driver" "toolkit" "plugin" "gfd" "dcgm" "validator" "mig-mgr" "dra-drv" "Taints"
    print_separator 245
    
    # Process each node - only GPU nodes
    local node_idx=0
    declare -A NODE_INDEX_MAP
    local total_nodes=0
    local gpu_nodes=0
    local healthy_nodes=0
    
    while IFS='|' read -r node_name gpu_count gpu_product ready unschedulable taints; do
        [[ -z "$node_name" ]] && continue
        ((total_nodes++))
        
        # Skip non-GPU nodes
        [[ "$gpu_count" == "0" || -z "$gpu_count" ]] && continue
        
        ((gpu_nodes++))
        ((node_idx++))
        NODE_INDEX_MAP[$node_idx]="$node_name"
        
        # Truncate fields
        local node_trunc="${node_name:0:28}"
        local product_trunc="${gpu_product:0:20}"
        
        # Process taints for display
        local taints_display="-"
        local taints_color="$GRAY"
        if [[ -n "$taints" && "$taints" != "null" ]]; then
            # Shorten common taint patterns
            taints_display=$(echo "$taints" | sed 's/nvidia.com\/gpu=:NoSchedule/gpu:NoSched/g' \
                | sed 's/node.kubernetes.io\/unschedulable:NoSchedule/unschedulable/g' \
                | sed 's/oci.oraclecloud.com\/oke-new-node:NoSchedule/newNode/g' \
                | sed 's/:NoSchedule/:NoSch/g' \
                | sed 's/:NoExecute/:NoEx/g' \
                | sed 's/:PreferNoSchedule/:PrefNo/g')
            taints_display="${taints_display:0:80}"
            taints_color="$YELLOW"
        fi
        
        # Ready status color
        local ready_color="$GREEN"
        [[ "$ready" != "True" ]] && ready_color="$RED"
        
        # GPU count color
        local gpu_color="$CYAN"
        
        # Helper function to get component status from pod list
        # Returns: "color|value" (e.g., "GREEN|1/1" or "RED|-")
        _get_pod_status() {
            local pods="$1"
            local node="$2"
            local pattern="$3"
            local optional="$4"  # "optional" if component is optional
            
            local pod_line
            pod_line=$(echo "$pods" | grep "^${node}|.*${pattern}" | head -1)
            
            if [[ -n "$pod_line" ]]; then
                local phase ready_status ready_num total_num
                phase=$(echo "$pod_line" | cut -d'|' -f3)
                ready_status=$(echo "$pod_line" | cut -d'|' -f4)
                ready_num=$(echo "$ready_status" | cut -d'/' -f1)
                total_num=$(echo "$ready_status" | cut -d'/' -f2)
                
                if [[ "$phase" == "Running" && "$ready_num" == "$total_num" && "$total_num" != "0" ]]; then
                    echo "GREEN|${ready_status}"
                elif [[ "$phase" == "Running" ]]; then
                    echo "YELLOW|${ready_status}"
                elif [[ "$phase" == "Succeeded" ]]; then
                    echo "GREEN|done"
                else
                    echo "YELLOW|${phase:0:4}"
                fi
            else
                if [[ "$optional" == "optional" ]]; then
                    echo "GRAY|-"
                else
                    echo "RED|-"
                fi
            fi
        }
        
        # Check each GPU Operator component - store color and value separately
        local driver_color="GRAY" driver_val="-"
        local toolkit_color="GRAY" toolkit_val="-"
        local plugin_color="GRAY" plugin_val="-"
        local gfd_color="GRAY" gfd_val="-"
        local dcgm_color="GRAY" dcgm_val="-"
        local validator_color="GRAY" validator_val="-"
        local mig_color="GRAY" mig_val="-"
        
        if [[ "$gpu_op_ns_exists" == "true" ]]; then
            # Check driver - handle host driver mode
            local driver_pod
            driver_pod=$(echo "$gpu_op_pods" | grep "^${node_name}|.*nvidia-driver" | head -1)
            if [[ -n "$driver_pod" ]]; then
                local d_phase d_ready d_rnum d_tnum
                d_phase=$(echo "$driver_pod" | cut -d'|' -f3)
                d_ready=$(echo "$driver_pod" | cut -d'|' -f4)
                d_rnum=$(echo "$d_ready" | cut -d'/' -f1)
                d_tnum=$(echo "$d_ready" | cut -d'/' -f2)
                if [[ "$d_phase" == "Running" && "$d_rnum" == "$d_tnum" && "$d_tnum" != "0" ]]; then
                    driver_color="GREEN"; driver_val="$d_ready"
                elif [[ "$d_phase" == "Running" ]]; then
                    driver_color="YELLOW"; driver_val="$d_ready"
                else
                    driver_color="YELLOW"; driver_val="${d_phase:0:4}"
                fi
            else
                # Check if any driver pods exist cluster-wide
                if echo "$gpu_op_pods" | grep -q "nvidia-driver"; then
                    driver_color="RED"; driver_val="-"
                else
                    driver_color="GRAY"; driver_val="host"
                fi
            fi
            
            # Check other components using helper
            local result
            result=$(_get_pod_status "$gpu_op_pods" "$node_name" "container-toolkit")
            toolkit_color="${result%%|*}"; toolkit_val="${result#*|}"
            
            result=$(_get_pod_status "$gpu_op_pods" "$node_name" "device-plugin")
            plugin_color="${result%%|*}"; plugin_val="${result#*|}"
            
            result=$(_get_pod_status "$gpu_op_pods" "$node_name" "feature-discovery")
            gfd_color="${result%%|*}"; gfd_val="${result#*|}"
            
            result=$(_get_pod_status "$gpu_op_pods" "$node_name" "dcgm")
            dcgm_color="${result%%|*}"; dcgm_val="${result#*|}"
            
            result=$(_get_pod_status "$gpu_op_pods" "$node_name" "validator")
            validator_color="${result%%|*}"; validator_val="${result#*|}"
            
            result=$(_get_pod_status "$gpu_op_pods" "$node_name" "mig-manager" "optional")
            mig_color="${result%%|*}"; mig_val="${result#*|}"
        fi
        
        # Check DRA kubelet-plugin (per-node daemonset)
        local dra_color="GRAY" dra_val="-"
        
        if [[ "$dra_ns_exists" == "true" ]]; then
            local node_dra_pod
            node_dra_pod=$(echo "$dra_pods" | grep "^${node_name}|.*kubelet-plugin" | head -1)
            
            if [[ -n "$node_dra_pod" ]]; then
                local dra_phase dra_ready_status dra_ready_num dra_total_num
                dra_phase=$(echo "$node_dra_pod" | cut -d'|' -f3)
                dra_ready_status=$(echo "$node_dra_pod" | cut -d'|' -f4)
                dra_ready_num=$(echo "$dra_ready_status" | cut -d'/' -f1)
                dra_total_num=$(echo "$dra_ready_status" | cut -d'/' -f2)
                
                if [[ "$dra_phase" == "Running" && "$dra_ready_num" == "$dra_total_num" && "$dra_total_num" != "0" ]]; then
                    dra_color="GREEN"; dra_val="$dra_ready_status"
                elif [[ "$dra_phase" == "Running" ]]; then
                    dra_color="YELLOW"; dra_val="$dra_ready_status"
                else
                    dra_color="YELLOW"; dra_val="${dra_phase:0:4}"
                fi
            else
                dra_color="RED"; dra_val="-"
            fi
        fi
        
        # Check if node is healthy (all required components running for GPU node)
        local node_healthy=true
        if [[ "$gpu_op_ns_exists" == "true" ]]; then
            # Driver: either has green status or using host drivers is acceptable
            [[ "$driver_color" != "GREEN" && "$driver_val" != "host" ]] && node_healthy=false
            [[ "$toolkit_color" != "GREEN" ]] && node_healthy=false
            [[ "$plugin_color" != "GREEN" ]] && node_healthy=false
        fi
        [[ "$node_healthy" == "true" ]] && ((healthy_nodes++))
        
        # Convert color names to actual codes
        local dc tc pc gc dcc vc mc drac
        case "$driver_color" in GREEN) dc="$GREEN";; YELLOW) dc="$YELLOW";; RED) dc="$RED";; *) dc="$GRAY";; esac
        case "$toolkit_color" in GREEN) tc="$GREEN";; YELLOW) tc="$YELLOW";; RED) tc="$RED";; *) tc="$GRAY";; esac
        case "$plugin_color" in GREEN) pc="$GREEN";; YELLOW) pc="$YELLOW";; RED) pc="$RED";; *) pc="$GRAY";; esac
        case "$gfd_color" in GREEN) gc="$GREEN";; YELLOW) gc="$YELLOW";; RED) gc="$RED";; *) gc="$GRAY";; esac
        case "$dcgm_color" in GREEN) dcc="$GREEN";; YELLOW) dcc="$YELLOW";; RED) dcc="$RED";; *) dcc="$GRAY";; esac
        case "$validator_color" in GREEN) vc="$GREEN";; YELLOW) vc="$YELLOW";; RED) vc="$RED";; *) vc="$GRAY";; esac
        case "$mig_color" in GREEN) mc="$GREEN";; YELLOW) mc="$YELLOW";; RED) mc="$RED";; *) mc="$GRAY";; esac
        case "$dra_color" in GREEN) drac="$GREEN";; YELLOW) drac="$YELLOW";; RED) drac="$RED";; *) drac="$GRAY";; esac
        
        # Print row with proper alignment
        printf "${YELLOW}%-3s${NC} %-28s ${gpu_color}%-5s${NC} ${ready_color}%-6s${NC} %-20s ${dc}%-7s${NC} ${tc}%-7s${NC} ${pc}%-7s${NC} ${gc}%-5s${NC} ${dcc}%-5s${NC} ${vc}%-9s${NC} ${mc}%-8s${NC} ${drac}%-8s${NC} ${taints_color}%-80s${NC}\n" \
            "$node_idx" "$node_trunc" "$gpu_count" "$ready" "$product_trunc" "$driver_val" "$toolkit_val" "$plugin_val" "$gfd_val" "$dcgm_val" "$validator_val" "$mig_val" "$dra_val" "$taints_display"
            
    done <<< "$node_data"
    
    if [[ $gpu_nodes -eq 0 ]]; then
        echo -e "  ${YELLOW}No GPU nodes found in the cluster${NC}"
    fi
    
    echo ""
    print_separator 245
    
    # Summary
    echo ""
    echo -e "${BOLD}${WHITE}═══ Summary ═══${NC}"
    echo ""
    echo -e "  ${WHITE}Total Nodes:${NC}   $total_nodes"
    echo -e "  ${WHITE}GPU Nodes:${NC}     $gpu_nodes"
    if [[ $gpu_nodes -gt 0 ]]; then
        if [[ $healthy_nodes -eq $gpu_nodes ]]; then
            echo -e "  ${WHITE}Healthy:${NC}       ${GREEN}$healthy_nodes / $gpu_nodes${NC} ${GREEN}✓ All GPU nodes healthy${NC}"
        else
            echo -e "  ${WHITE}Healthy:${NC}       ${YELLOW}$healthy_nodes / $gpu_nodes${NC} ${RED}⚠ Some nodes have issues${NC}"
        fi
    fi
    echo ""
    
    # Legend
    echo -e "${BOLD}${WHITE}Legend:${NC}"
    echo -e "  ${GREEN}1/1${NC}, ${GREEN}2/2${NC} = All containers Ready    ${YELLOW}0/1${NC}, ${YELLOW}1/2${NC} = Not all containers Ready    ${RED}-${NC} = Missing    ${GRAY}-${NC} = N/A or Optional"
    echo ""
    echo -e "${BOLD}${WHITE}Status Values:${NC}"
    echo -e "  ${GREEN}N/N${NC}  = Pod Running with all containers Ready (e.g., 1/1, 2/2)"
    echo -e "  ${YELLOW}N/N${NC}  = Pod Running but not all containers Ready (e.g., 0/1, 1/2)"
    echo -e "  ${YELLOW}Pend${NC} = Pod in Pending state"
    echo -e "  ${GREEN}done${NC} = Pod Succeeded (completed successfully, e.g., validator)"
    echo -e "  ${GRAY}host${NC} = Using pre-installed host drivers (driver.enabled: false)"
    echo -e "  ${RED}-${NC}    = Required component missing"
    echo -e "  ${GRAY}-${NC}    = Optional component not deployed (e.g., mig-mgr)"
    echo ""
    echo -e "${BOLD}${WHITE}Common Taints:${NC}"
    echo -e "  ${YELLOW}newNode${NC} = oci.oraclecloud.com/oke-new-node:NoSchedule (node initializing)"
    echo -e "  ${YELLOW}gpu:NoSch${NC} = nvidia.com/gpu:NoSchedule (GPU dedicated)"
    echo -e "  ${YELLOW}unschedulable${NC} = node.kubernetes.io/unschedulable:NoSchedule (cordoned)"
    echo ""
    
    # Interactive menu
    while true; do
        echo -e "${BOLD}${WHITE}─── Actions ───${NC}"
        echo -e "  Enter ${YELLOW}#${NC} (e.g., 1) to view detailed pod status for a node"
        echo -e "  Enter ${YELLOW}pods${NC} to list all GPU-related pods"
        echo -e "  Enter ${YELLOW}dra${NC} to list DRA kubelet-plugin pods with READY status"
        echo -e "  Enter ${YELLOW}events${NC} to show recent events from GPU namespaces"
        echo -e "  Enter ${YELLOW}refresh${NC} to refresh the status"
        echo -e "  Enter ${YELLOW}b${NC} to go back"
        echo ""
        echo -n -e "${CYAN}Selection: ${NC}"
        read -r selection
        
        case "$selection" in
            [0-9]*)
                local selected_node="${NODE_INDEX_MAP[$selection]:-}"
                if [[ -z "$selected_node" ]]; then
                    echo -e "${RED}Invalid node number: $selection${NC}"
                    continue
                fi
                
                echo ""
                echo -e "${BOLD}${CYAN}═══ Pod Details for Node: ${WHITE}${selected_node}${NC} ${BOLD}${CYAN}═══${NC}"
                echo ""
                
                # Show node taints
                echo -e "${BOLD}${WHITE}Node Taints:${NC}"
                kubectl get node "$selected_node" -o json 2>/dev/null | jq -r '
                    .spec.taints // [] | if length == 0 then "  (none)" else .[] | "  \(.key)=\(.value // ""):\(.effect)" end
                ' 2>/dev/null || echo -e "${GRAY}  Unable to fetch taints${NC}"
                echo ""
                
                echo -e "${BOLD}${WHITE}GPU Operator Pods (gpu-operator namespace):${NC}"
                kubectl get pods -n gpu-operator -o wide --field-selector spec.nodeName="$selected_node" 2>/dev/null || echo -e "${GRAY}  No pods found${NC}"
                echo ""
                
                echo -e "${BOLD}${WHITE}DRA Pods (nvidia-dra-driver-gpu namespace):${NC}"
                kubectl get pods -n nvidia-dra-driver-gpu -o wide --field-selector spec.nodeName="$selected_node" 2>/dev/null || echo -e "${GRAY}  No pods found${NC}"
                echo ""
                
                # Show node labels related to NVIDIA
                echo -e "${BOLD}${WHITE}NVIDIA Node Labels:${NC}"
                kubectl get node "$selected_node" -o json 2>/dev/null | jq -r '
                    .metadata.labels | to_entries[] | 
                    select(.key | startswith("nvidia.com") or startswith("feature.node.kubernetes.io/pci-10de")) |
                    "  \(.key) = \(.value)"
                ' 2>/dev/null || echo -e "${GRAY}  No NVIDIA labels found${NC}"
                echo ""
                ;;
            pods|PODS)
                echo ""
                echo -e "${BOLD}${WHITE}═══ All GPU Operator Pods ═══${NC}"
                kubectl get pods -n gpu-operator -o wide 2>/dev/null || echo -e "${GRAY}Namespace not found${NC}"
                echo ""
                echo -e "${BOLD}${WHITE}═══ All DRA Pods ═══${NC}"
                kubectl get pods -n nvidia-dra-driver-gpu -o wide 2>/dev/null || echo -e "${GRAY}Namespace not found${NC}"
                echo ""
                ;;
            dra|DRA)
                echo ""
                echo -e "${BOLD}${WHITE}═══ DRA Kubelet Plugin Pods (*kubelet-plugin*) ═══${NC}"
                echo ""
                # Show kubelet-plugin pods with their ready status
                kubectl get pods -n nvidia-dra-driver-gpu -o wide 2>/dev/null | grep -E "NAME|kubelet-plugin" || echo -e "${GRAY}No kubelet-plugin pods found${NC}"
                echo ""
                # Also show summary
                local total_plugin_pods ready_plugin_pods
                total_plugin_pods=$(kubectl get pods -n nvidia-dra-driver-gpu --no-headers 2>/dev/null | grep -c "kubelet-plugin" 2>/dev/null || true)
                total_plugin_pods=${total_plugin_pods:-0}
                total_plugin_pods=$(echo "$total_plugin_pods" | tr -d '[:space:]')
                [[ -z "$total_plugin_pods" ]] && total_plugin_pods=0
                ready_plugin_pods=$(kubectl get pods -n nvidia-dra-driver-gpu --no-headers 2>/dev/null | grep "kubelet-plugin" | awk '$2 ~ /^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if(a[1]==a[2] && $3=="Running") count++} END {print count+0}')
                echo -e "${WHITE}Summary: ${CYAN}${ready_plugin_pods}${NC}/${CYAN}${total_plugin_pods}${NC} kubelet-plugin pods fully ready${NC}"
                echo ""
                ;;
            events|EVENTS)
                echo ""
                echo -e "${BOLD}${WHITE}═══ Recent Events (gpu-operator) ═══${NC}"
                kubectl get events -n gpu-operator --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || echo -e "${GRAY}No events${NC}"
                echo ""
                echo -e "${BOLD}${WHITE}═══ Recent Events (nvidia-dra-driver-gpu) ═══${NC}"
                kubectl get events -n nvidia-dra-driver-gpu --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || echo -e "${GRAY}No events${NC}"
                echo ""
                ;;
            refresh|REFRESH)
                manage_nvidia_gpu_stack_health
                return
                ;;
            b|B|back|BACK|"")
                return
                ;;
            *)
                echo -e "${RED}Unknown command${NC}"
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
        
        # Use 'oci iam tag get' to get full tag details including validator
        local tag_get_cmd="oci iam tag get --tag-namespace-id \"$namespace_ocid\" --tag-name \"${GPU_TAG_NAME}\" --output json"
        echo -e "${GRAY}$tag_get_cmd${NC}"
        echo ""
        
        local tag_info
        tag_info=$(oci iam tag get \
            --tag-namespace-id "$namespace_ocid" \
            --tag-name "${GPU_TAG_NAME}" \
            --output json 2>/dev/null)
        
        # Extract from .data since tag get wraps in data
        local tag_data
        tag_data=$(echo "$tag_info" | jq '.data' 2>/dev/null)
        
        if [[ -z "$tag_data" || "$tag_data" == "null" ]]; then
            echo -e "${RED}✗ Tag '${GPU_TAG_NAME}' does NOT exist in namespace${NC}"
            all_valid=false
        else
            local tag_ocid tag_state tag_description validator_type
            tag_ocid=$(echo "$tag_data" | jq -r '.id // empty')
            tag_state=$(echo "$tag_data" | jq -r '.["lifecycle-state"] // "UNKNOWN"')
            tag_description=$(echo "$tag_data" | jq -r '.description // "N/A"')
            validator_type=$(echo "$tag_data" | jq -r '.validator["validator-type"] // "NONE"')
            
            # Get validator values as array
            local validator_values_array
            validator_values_array=$(echo "$tag_data" | jq -r '.validator.values // []')
            local validator_values_display
            validator_values_display=$(echo "$tag_data" | jq -r '.validator.values // [] | join(", ")')
            
            echo -e "${GREEN}✓ Tag '${GPU_TAG_NAME}' exists${NC}"
            echo -e "  ${CYAN}OCID:${NC}        ${YELLOW}${tag_ocid}${NC}"
            echo -e "  ${CYAN}State:${NC}       ${WHITE}${tag_state}${NC}"
            echo -e "  ${CYAN}Description:${NC} ${WHITE}${tag_description}${NC}"
            echo -e "  ${CYAN}Validator:${NC}   ${WHITE}${validator_type}${NC}"
            if [[ -n "$validator_values_display" ]]; then
                echo -e "  ${CYAN}Values:${NC}      ${WHITE}${validator_values_display}${NC}"
            fi
            
            if [[ "$tag_state" != "ACTIVE" ]]; then
                echo -e "${RED}  ⚠ Tag is not ACTIVE (state: ${tag_state})${NC}"
                all_valid=false
            fi
            
            # Step 3: Validate that expected values exist in validator.values array
            echo ""
            echo -e "${YELLOW}Step 3: Checking validator values for required entries...${NC}"
            echo ""
            
            # Check if validator type is ENUM (required for value checking)
            if [[ "$validator_type" != "ENUM" ]]; then
                echo -e "${RED}  ✗ Validator type is '${validator_type}', expected 'ENUM'${NC}"
                all_valid=false
            else
                echo -e "${GREEN}  ✓ Validator type is 'ENUM'${NC}"
            fi
            
            # Check each expected value exists in the validator.values array
            local expected_values
            IFS=',' read -ra expected_values <<< "${GPU_TAG_VALUES}"
            for val in "${expected_values[@]}"; do
                # Trim whitespace
                val=$(echo "$val" | xargs)
                
                # Check if value exists in JSON array using jq
                local value_exists
                value_exists=$(echo "$tag_data" | jq -r --arg v "$val" '.validator.values // [] | map(select(. == $v)) | length')
                
                if [[ "$value_exists" -gt 0 ]]; then
                    echo -e "${GREEN}  ✓ Required value '${val}' found in validator.values${NC}"
                else
                    echo -e "${RED}  ✗ Required value '${val}' NOT found in validator.values${NC}"
                    echo -e "${GRAY}    Current values: [${validator_values_display}]${NC}"
                    all_valid=false
                fi
            done
            
            # Show raw JSON for debugging
            echo ""
            echo -e "${GRAY}Raw validator JSON:${NC}"
            echo "$tag_data" | jq '.validator' 2>/dev/null | sed 's/^/  /'
        fi
        
        echo ""
        
        # List all tags in namespace (using tag list for overview)
        echo -e "${YELLOW}All tags in namespace:${NC}"
        echo ""
        
        local existing_tags
        existing_tags=$(oci iam tag list \
            --tag-namespace-id "$namespace_ocid" \
            --all \
            --output json 2>/dev/null)
        
        printf "  ${GRAY}%-30s %-12s %s${NC}\n" "Name" "State" "OCID"
        echo "$existing_tags" | jq -r '.data[] | "\(.name)|\(.["lifecycle-state"])|\(.id)"' 2>/dev/null | \
        while IFS='|' read -r t_name t_state t_ocid; do
            local state_color="$GREEN"
            [[ "$t_state" != "ACTIVE" ]] && state_color="$YELLOW"
            printf "  ${WHITE}%-30s${NC} ${state_color}%-12s${NC} ${YELLOW}%s${NC}\n" "$t_name" "$t_state" "$t_ocid"
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
    ic_output_temp=$(mktemp "${TEMP_DIR}/tmp.XXXXXXXXXX")
    
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
    echo "If no instance-ocid is provided, lists all instances in the compartment with fabric details"
    echo "(Use INSTANCE_FILTER in variables.sh to filter: all, gpu, or non-gpu)"
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
    echo "  --get-user-data    Extract and display the decoded cloud-init user-data from the instance"
    echo "                     Useful for reviewing or backing up cloud-init configurations"
    echo ""
    echo -e "${BOLD}Clique Analysis:${NC}"
    echo "  --list-cliques      List all unique cliques with nodes grouped by GPU memory cluster and fabric"
    echo "                      Also shows fabrics without active clusters and instances not in K8s"
    echo "  --cliques-summary   Show summary table of all cliques with fabric info"
    echo "                      Also shows fabrics without active clusters and instances not in K8s"
    echo ""
    echo -e "${BOLD}GPU Cluster Search:${NC}"
    echo "  <gpu-cluster-id> --list-cluster"
    echo "    List all instances in a specific GPU memory cluster with fabric details"
    echo ""
    echo -e "${BOLD}Instance Configuration:${NC}"
    echo "  <instance-config-ocid> --get-user-data-config"
    echo "    Extract and display the decoded cloud-init user-data from an instance configuration"
    echo "    Useful for reviewing instance configuration cloud-init templates"
    echo ""
    echo -e "${BOLD}Instance Termination:${NC}"
    echo "  <instance-ocid> --terminate"
    echo "    Interactively terminate an instance with full details and confirmation"
    echo "    Shows: instance details, K8s node status, running pods, termination command"
    echo "    Logs all actions to ./logs/k8s_maintenance_YYYYMMDD.log"
    echo ""
    echo -e "${BOLD}Resource Management:${NC}"
    echo "  --manage            Interactive resource management mode"
    echo "                      - OKE Cluster environment view"
    echo "                      - Network resources (subnets, NSGs)"
    echo "                      - GPU Memory Fabrics & Clusters (create, update, view)"
    echo "                      - Compute Instances (view details, IPs, volumes)"
    echo "                      - Instance Configurations (create, view, compare, delete)"
    echo "                      - Compute Clusters (create, view, delete)"
    echo "                      - GPU Instance Tagging (namespace and tags)"
    echo "                      - NVIDIA GPU Stack Health (GPU Operator & DRA per node)"
    echo "                      - Resource Manager Stacks (view stacks, jobs, logs, state)"
    echo "                      - Work Requests (view status, errors, logs)"
    echo "                      - File Storage (FSS) - file systems, mount targets, exports"
    echo "                      - Lustre File Systems - create, mount, Object Storage links"
    echo ""
    echo -e "${BOLD}Setup & Maintenance:${NC}"
    echo "  --setup             Run initial setup to create/update variables.sh"
    echo "                      Auto-detects environment from IMDS and allows resource selection"
    echo "  --refresh           Clear all cached data to force fresh fetch from OCI"
    echo "                      Useful after infrastructure changes or stale data"
    echo "  --maintenance       Show instances requiring maintenance attention"
    echo "                      Lists instances with DEGRADED capacity topology or active announcements"
    echo "  --announcements     Show all announcements with affected resource details"
    echo "                      Validates if affected instances still exist in OCI"
    echo ""
    echo -e "${BOLD}Interactive Features:${NC}"
    echo "  When listing GPU instances, if instances not in kubernetes (running in OCI but not in K8s)"
    echo "  are found, you will be prompted to select one to view its console history."
    echo "  This helps diagnose why an instance failed to join the Kubernetes cluster."
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                                                    # List all instances with fabric info"
    echo "  $0 --refresh                                          # Clear cache and force fresh data"
    echo "  $0 --maintenance                                      # Show instances needing maintenance"
    echo "  $0 --announcements                                    # Show all announcements with resources"
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
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --get-user-data    # Extract cloud-init from instance"
    echo "  $0 ocid1.computegpumemorycluster.xxx --list-cluster    # List cluster instances + fabric"
    echo "  $0 ocid1.instanceconfig.xxx --get-user-data-config    # Extract cloud-init from instance config"
    echo "  $0 ocid1.instance.xxx --terminate                     # Interactively terminate instance with details"
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
INSTANCE_FILTER="all"
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
    
    # Create cache and temp directories
    mkdir -p "$CACHE_DIR"
    mkdir -p "$TEMP_DIR"
    
    # Cleanup temp files on exit
    trap 'rm -rf "${TEMP_DIR:?}"/* 2>/dev/null' EXIT
    
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
        --manage)
            interactive_management_main_menu
            ;;
        --maintenance)
            list_maintenance_instances "$EFFECTIVE_COMPARTMENT_ID" "$EFFECTIVE_REGION"
            ;;
        --announcements)
            list_all_announcements "$EFFECTIVE_COMPARTMENT_ID" "$EFFECTIVE_REGION"
            ;;
        --refresh)
            refresh_all_caches
            ;;
        --help|-h)
            show_help
            ;;
        *)
            # Assume it's an instance OCID or instance config OCID or GPU cluster OCID
            local instance_id="$1"
            local show_labels="false"
            local show_clique="false"
            local count_clique="false"
            local show_console_history="false"
            local show_instance_details="false"
            local show_user_data="false"
            local show_config_user_data="false"
            local show_list_cluster="false"
            local do_terminate="false"
            
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
                    --get-user-data)
                        show_user_data="true"
                        shift
                        ;;
                    --get-user-data-config)
                        show_config_user_data="true"
                        shift
                        ;;
                    --list-cluster)
                        show_list_cluster="true"
                        shift
                        ;;
                    --terminate)
                        do_terminate="true"
                        shift
                        ;;
                    *)
                        log_error "Unknown option: $1"
                        exit 1
                        ;;
                esac
            done
            
            if [[ "$do_terminate" == "true" ]]; then
                terminate_instance_interactive "$instance_id"
            elif [[ "$show_list_cluster" == "true" ]]; then
                list_instances_by_gpu_cluster "$instance_id" "$EFFECTIVE_COMPARTMENT_ID" "$EFFECTIVE_REGION"
            elif [[ "$show_config_user_data" == "true" ]]; then
                get_instance_config_user_data "$instance_id"
            elif [[ "$show_user_data" == "true" ]]; then
                get_instance_user_data "$instance_id"
            elif [[ "$show_console_history" == "true" ]]; then
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