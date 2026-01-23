#!/bin/bash
#
# instance_ops.sh - Query and manage GPU instances
#
# Description:
#   Query and manage GPU instances by display name, instance OCID, or GPU memory cluster OCID.
#   Supports cordon, drain, reboot, terminate, and rename operations.
#
# Dependencies:
#   - oci CLI (configured)
#   - kubectl (configured with cluster access)
#   - jq (JSON processor)
#
# Usage:
#   ./instance_ops.sh [OPTIONS]
#   Run with --help for full usage information.
#

set -e
set -o pipefail

# Source variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/variables.sh" ]]; then
    source "${SCRIPT_DIR}/variables.sh"
else
    echo "Error: variables.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

# Color codes (readonly)
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Script options
MODE=""
SEARCH_VALUE=""
ACTION=""
NEW_NAME_PREFIX=""
START_NODE_NUMBER=""
AUTO_NUMBER=false
DRY_RUN=false
DRAIN_TIMEOUT=300
FORCE_DRAIN=false
SKIP_POD_CHECK=false

# Setup logging
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/gpu_instances_$(date +%Y%m%d_%H%M%S).log"

#===============================================================================
# LOGGING FUNCTIONS
#===============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

log_info() {
    log "INFO" "$@"
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    log "SUCCESS" "$@"
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warning() {
    log "WARNING" "$@"
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    log "ERROR" "$@"
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_command() {
    log "COMMAND" "$@"
    echo -e "${CYAN}[COMMAND]${NC} $*" >&2
}

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

# Check if required commands are available
check_dependencies() {
    local missing=()
    
    command -v oci &>/dev/null || missing+=("oci")
    command -v kubectl &>/dev/null || missing+=("kubectl")
    command -v jq &>/dev/null || missing+=("jq")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_error "Please install the missing dependencies and try again."
        exit 1
    fi
}

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Query and manage GPU instances by display name, instance OCID, or GPU memory cluster OCID

Options:
  --display-name <name>          Search by instance display name
  --instance-id <ocid>           Search by instance OCID
  --gpu-cluster <ocid>           Search by GPU memory cluster OCID
  --list-all                     List all GPU instances in the compartment
  --reboot                       Reboot the instance (with --instance-id or --display-name)
  --terminate                    Terminate the instance (with --instance-id, --display-name, or --gpu-cluster)
  --cordon                       Cordon the node(s) in Kubernetes
  --drain                        Drain the node(s) in Kubernetes (cordons first if needed)
  --cordon-drain                 Cordon and drain the node(s) in Kubernetes
  --uncordon                     Uncordon the node(s) in Kubernetes
  --rename <prefix>              Rename instance(s) with prefix + last 5 chars of GPU cluster OCID + node number
  --node-number <num>            Starting node number for rename (auto-detects if not specified)
  --drain-timeout <seconds>      Timeout for drain operation (default: 300)
  --force-drain                  Force drain even if PodDisruptionBudgets are violated
  --skip-pod-check               Skip pod validation before reboot/terminate
  --dry-run                      Print commands without executing them
  --compartment-id <ocid>        Override compartment OCID from variables.sh
  --region <region>              Override region from variables.sh
  --help                         Show this help message

Variables from variables.sh:
  COMPARTMENT_ID: ${COMPARTMENT_ID:-not set}
  REGION: ${REGION:-not set}

Logs are saved to: ${LOG_DIR}/

Examples:
  # List all GPU instances
  $0 --list-all

  # Query by display name
  $0 --display-name instance20260116091436

  # Cordon a single node
  $0 --instance-id ocid1.instance.oc1.us-dallas-1.xxx --cordon

  # Drain a single node (will cordon first if not already cordoned)
  $0 --instance-id ocid1.instance.oc1.us-dallas-1.xxx --drain --drain-timeout 600

  # Cordon and drain a single node
  $0 --display-name inst-gb200-3asoa-node01 --cordon-drain

  # Cordon and drain all nodes in a GPU cluster
  $0 --gpu-cluster ocid1.computegpumemorycluster.oc1.us-dallas-1.xxx --cordon-drain

  # Uncordon a node
  $0 --instance-id ocid1.instance.oc1.us-dallas-1.xxx --uncordon

  # Reboot an instance (automatically checks for running pods)
  $0 --instance-id ocid1.instance.oc1.us-dallas-1.xxx --reboot

  # Terminate with pod check
  $0 --instance-id ocid1.instance.oc1.us-dallas-1.xxx --terminate

  # Terminate all instances in GPU cluster (with pod validation)
  $0 --gpu-cluster ocid1.computegpumemorycluster.oc1.us-dallas-1.xxx --terminate

  # Rename with auto-numbering
  $0 --gpu-cluster ocid1.computegpumemorycluster.oc1.us-dallas-1.xxx --rename inst-gb200
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --display-name)
            MODE="display-name"
            SEARCH_VALUE="$2"
            shift 2
            ;;
        --instance-id)
            MODE="instance-id"
            SEARCH_VALUE="$2"
            shift 2
            ;;
        --gpu-cluster)
            MODE="gpu-cluster"
            SEARCH_VALUE="$2"
            shift 2
            ;;
        --list-all)
            MODE="list-all"
            shift
            ;;
        --reboot)
            ACTION="reboot"
            shift
            ;;
        --terminate)
            ACTION="terminate"
            shift
            ;;
        --cordon)
            ACTION="cordon"
            shift
            ;;
        --drain)
            ACTION="drain"
            shift
            ;;
        --cordon-drain)
            ACTION="cordon-drain"
            shift
            ;;
        --uncordon)
            ACTION="uncordon"
            shift
            ;;
        --rename)
            ACTION="rename"
            NEW_NAME_PREFIX="$2"
            shift 2
            ;;
        --node-number)
            START_NODE_NUMBER="$2"
            shift 2
            ;;
        --drain-timeout)
            DRAIN_TIMEOUT="$2"
            shift 2
            ;;
        --force-drain)
            FORCE_DRAIN=true
            shift
            ;;
        --skip-pod-check)
            SKIP_POD_CHECK=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --compartment-id)
            COMPARTMENT_ID="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Check dependencies
check_dependencies

# Log script start
log_info "Script started"
log_info "Mode: ${MODE:-none}, Search Value: ${SEARCH_VALUE:-none}, Action: ${ACTION:-none}"
if [[ "$DRY_RUN" == true ]]; then
    log_warning "DRY RUN MODE - Commands will be printed but not executed"
fi
if [[ "$ACTION" == "rename" ]]; then
    log_info "New name prefix: ${NEW_NAME_PREFIX}, Starting node number: ${START_NODE_NUMBER:-auto}"
fi
log_info "Log file: $LOG_FILE"

# Validate inputs
if [[ -z "$COMPARTMENT_ID" ]]; then
    log_error "COMPARTMENT_ID is not set in variables.sh or via --compartment-id"
    exit 1
fi

if [[ -z "$REGION" ]]; then
    REGION="us-dallas-1"
    log_warning "REGION not set, using default: ${REGION}"
fi

if [[ -z "$MODE" ]]; then
    log_error "Must specify --display-name, --instance-id, --gpu-cluster, or --list-all"
    usage
fi

# Validate action only works with appropriate modes
if [[ "$ACTION" == "reboot" ]] && [[ "$MODE" == "gpu-cluster" || "$MODE" == "list-all" ]]; then
    log_error "--reboot can only be used with --instance-id or --display-name"
    exit 1
fi

if [[ "$ACTION" == "rename" ]] && [[ -z "$NEW_NAME_PREFIX" ]]; then
    log_error "--rename requires a prefix value"
    exit 1
fi

# Validate node number is a positive integer if provided
if [[ -n "$START_NODE_NUMBER" ]]; then
    if [[ ! "$START_NODE_NUMBER" =~ ^[0-9]+$ ]] || [[ "$START_NODE_NUMBER" -lt 1 ]]; then
        log_error "Node number must be a positive integer"
        exit 1
    fi
    AUTO_NUMBER=false
else
    AUTO_NUMBER=true
fi

log_info "Using Compartment: $COMPARTMENT_ID"
log_info "Using Region: $REGION"

#===============================================================================
# COMMAND EXECUTION FUNCTIONS
#===============================================================================

# Function to execute OCI command with logging and confirmation
execute_oci_command() {
    local cmd="$*"
    local skip_confirm="${OCI_SKIP_CONFIRM:-false}"
    
    log_command "$cmd"
    echo ""
    echo -e "${CYAN}Command to execute:${NC}"
    echo "  $cmd"
    echo ""
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY RUN] Command not executed${NC}"
        return 0
    fi
    
    # Skip confirmation if already confirmed at a higher level (e.g., batch operations)
    if [[ "$skip_confirm" != "true" ]]; then
        read -p "Execute this command? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Command skipped${NC}"
            log_info "Command skipped by user: $cmd"
            return 2  # Return 2 to indicate skipped (not failed)
        fi
    fi
    
    echo -e "${BLUE}Executing...${NC}"
    eval "$cmd"
    return $?
}

# Function to execute kubectl command with logging
execute_kubectl_command() {
    local cmd="$*"
    
    log_command "$cmd"
    echo ""
    echo -e "${CYAN}Executing:${NC}"
    echo "  $cmd"
    echo ""
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY RUN] Command not executed${NC}"
        return 0
    fi
    
    eval "$cmd"
    return $?
}

#===============================================================================
# NODE LOOKUP FUNCTIONS
#===============================================================================

# Function to get node name from instance display name
get_node_name_from_display_name() {
    local display_name="$1"
    
    # Try exact match first using provider ID lookup through OCI
    local instance_id
    instance_id=$(oci compute instance list \
        --compartment-id "$COMPARTMENT_ID" \
        --region "$REGION" \
        --display-name "$display_name" \
        --query 'data[0].id' \
        --raw-output 2>/dev/null)
    
    if [[ -n "$instance_id" && "$instance_id" != "null" ]]; then
        get_node_name_from_instance_id "$instance_id"
        return $?
    fi
    
    # Fallback: Try display-name label
    local node_name
    node_name=$(kubectl get nodes -l "oci.oraclecloud.com/display-name=${display_name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -z "$node_name" ]]; then
        log_warning "Could not find Kubernetes node for instance: $display_name"
        return 1
    fi
    
    echo "$node_name"
    return 0
}

# Function to get node name from instance OCID
get_node_name_from_instance_id() {
    local instance_id="$1"
    
    local node_name
    node_name=$(kubectl get nodes -o jsonpath="{.items[?(@.spec.providerID=='${instance_id}')].metadata.name}" 2>/dev/null)
    
    if [[ -z "$node_name" ]]; then
        log_warning "Could not find Kubernetes node for instance OCID: $instance_id"
        return 1
    fi
    
    echo "$node_name"
    return 0
}

#===============================================================================
# NODE STATE CHECK FUNCTIONS
#===============================================================================

# Function to check if node is cordoned
is_node_cordoned() {
    local node_name="$1"
    
    local is_cordoned
    is_cordoned=$(kubectl get node "$node_name" -o jsonpath='{.spec.unschedulable}' 2>/dev/null)
    
    [[ "$is_cordoned" == "true" ]]
}

# Function to check if node has running pods (excluding DaemonSets and system pods)
check_node_pods() {
    local node_name="$1"
    
    log_info "Checking for running pods on node: $node_name"
    
    # Get non-system pods that are running
    local pod_count
    pod_count=$(kubectl get pods --all-namespaces --field-selector "spec.nodeName=${node_name}" \
        -o json 2>/dev/null | jq '[.items[] | 
        select(.status.phase != "Succeeded" and .status.phase != "Failed") |
        select(.metadata.ownerReferences == null or 
               (.metadata.ownerReferences | map(.kind) | contains(["DaemonSet"]) | not))
        ] | length')
    
    if [[ "$pod_count" -gt 0 ]]; then
        log_warning "Node $node_name has $pod_count running pod(s) (excluding DaemonSets)"
        echo ""
        echo -e "${YELLOW}Running pods on node $node_name (excluding DaemonSets):${NC}"
        kubectl get pods --all-namespaces --field-selector "spec.nodeName=${node_name}" \
            -o wide 2>/dev/null | grep -v "^kube-system" || true
        echo ""
        return 1
    else
        log_success "Node $node_name has no running pods (excluding DaemonSets)"
        return 0
    fi
}

#===============================================================================
# KUBERNETES NODE OPERATIONS
#===============================================================================

# Function to cordon a node
cordon_node() {
    local node_name="$1"
    
    log_info "Cordoning node: $node_name"
    
    # Check if already cordoned
    if is_node_cordoned "$node_name"; then
        echo -e "${YELLOW}Node $node_name is already cordoned${NC}"
        log_info "Node $node_name is already cordoned"
        return 0
    fi
    
    local cmd="kubectl cordon \"$node_name\""
    
    if execute_kubectl_command "$cmd"; then
        echo -e "${GREEN}✓ Successfully cordoned node: $node_name${NC}"
        log_success "Successfully cordoned node: $node_name"
        return 0
    else
        echo -e "${RED}✗ Failed to cordon node: $node_name${NC}"
        log_error "Failed to cordon node: $node_name"
        return 1
    fi
}

# Function to uncordon a node
uncordon_node() {
    local node_name="$1"
    
    log_info "Uncordoning node: $node_name"
    
    # Check if already uncordoned
    if ! is_node_cordoned "$node_name"; then
        echo -e "${YELLOW}Node $node_name is not cordoned${NC}"
        log_info "Node $node_name is not cordoned"
        return 0
    fi
    
    local cmd="kubectl uncordon \"$node_name\""
    
    if execute_kubectl_command "$cmd"; then
        echo -e "${GREEN}✓ Successfully uncordoned node: $node_name${NC}"
        log_success "Successfully uncordoned node: $node_name"
        return 0
    else
        echo -e "${RED}✗ Failed to uncordon node: $node_name${NC}"
        log_error "Failed to uncordon node: $node_name"
        return 1
    fi
}

# Function to drain a node (cordons first if not already cordoned)
drain_node() {
    local node_name="$1"
    
    log_info "Draining node: $node_name (timeout: ${DRAIN_TIMEOUT}s, force: $FORCE_DRAIN)"
    
    # First ensure the node is cordoned
    if ! is_node_cordoned "$node_name"; then
        log_info "Node $node_name is not cordoned, cordoning first..."
        if ! cordon_node "$node_name"; then
            log_error "Failed to cordon node before drain"
            return 1
        fi
    else
        log_info "Node $node_name is already cordoned"
    fi
    
    # Build drain options
    local drain_opts="--ignore-daemonsets --delete-emptydir-data --timeout=${DRAIN_TIMEOUT}s"
    
    if [[ "$FORCE_DRAIN" == true ]]; then
        drain_opts="$drain_opts --disable-eviction --force"
    fi
    
    local cmd="kubectl drain \"$node_name\" $drain_opts"
    
    if execute_kubectl_command "$cmd"; then
        echo -e "${GREEN}✓ Successfully drained node: $node_name${NC}"
        log_success "Successfully drained node: $node_name"
        return 0
    else
        echo -e "${RED}✗ Failed to drain node: $node_name${NC}"
        log_error "Failed to drain node: $node_name"
        return 1
    fi
}

# Function to cordon and drain a node
# Note: This is essentially the same as drain since drain cordons first,
# but we keep it for explicit user intent
cordon_and_drain_node() {
    local node_name="$1"
    
    echo -e "${BLUE}Cordoning and draining node: $node_name${NC}"
    
    # drain_node already handles cordoning if needed
    drain_node "$node_name"
    return $?
}

#===============================================================================
# RENAME HELPER FUNCTIONS
#===============================================================================

# Function to extract last 5 characters from GPU cluster OCID
extract_cluster_suffix() {
    local cluster_ocid="$1"
    echo "${cluster_ocid: -5}" | tr '[:upper:]' '[:lower:]'
}

# Function to find next available node number
find_next_node_number() {
    local gpu_cluster="$1"
    local name_prefix="$2"
    local cluster_suffix
    cluster_suffix=$(extract_cluster_suffix "$gpu_cluster")
    
    # Get all existing instances with this naming pattern
    local cmd="oci compute instance list --compartment-id \"$COMPARTMENT_ID\" --region \"$REGION\" --all --query \"data[?\\\"freeform-tags\\\".\\\"oci:compute:gpumemorycluster\\\"=='${gpu_cluster}'].\\\"display-name\\\"\" --raw-output"
    log_command "$cmd"
    
    local existing_instances
    existing_instances=$(eval "$cmd" 2>/dev/null)
    
    if [[ -z "$existing_instances" ]]; then
        echo "1"
        return
    fi
    
    # Extract node numbers from existing instances
    local node_numbers=()
    while IFS= read -r name; do
        if [[ "$name" =~ ${name_prefix}-${cluster_suffix}-node([0-9]+) ]]; then
            node_numbers+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$existing_instances"
    
    if [[ ${#node_numbers[@]} -eq 0 ]]; then
        echo "1"
        return
    fi
    
    # Sort node numbers
    IFS=$'\n' sorted_numbers=($(sort -n <<<"${node_numbers[*]}"))
    unset IFS
    
    # Find first gap
    local expected=1
    for num in "${sorted_numbers[@]}"; do
        num=$((10#$num))  # Convert to base 10 to handle leading zeros
        if [[ $num -gt $expected ]]; then
            echo "$expected"
            log_info "Found gap in numbering, using node number: $expected"
            return
        fi
        expected=$((num + 1))
    done
    
    # No gaps found, use next number after highest
    echo "$expected"
    log_info "No gaps found, using next sequential number: $expected"
}

# Function to get smart node numbers for multiple instances
get_smart_node_numbers() {
    local gpu_cluster="$1"
    local name_prefix="$2"
    local count="$3"
    local cluster_suffix
    cluster_suffix=$(extract_cluster_suffix "$gpu_cluster")
    
    # Get all existing instances with this naming pattern
    local cmd="oci compute instance list --compartment-id \"$COMPARTMENT_ID\" --region \"$REGION\" --all --query \"data[?\\\"freeform-tags\\\".\\\"oci:compute:gpumemorycluster\\\"=='${gpu_cluster}'].\\\"display-name\\\"\" --raw-output"
    log_command "$cmd"
    
    local existing_instances
    existing_instances=$(eval "$cmd" 2>/dev/null)
    
    # Extract existing node numbers
    local existing_numbers=()
    while IFS= read -r name; do
        if [[ "$name" =~ ${name_prefix}-${cluster_suffix}-node([0-9]+) ]]; then
            existing_numbers+=("$((10#${BASH_REMATCH[1]}))")
        fi
    done <<< "$existing_instances"
    
    # Generate list of available numbers
    local available_numbers=()
    local max_needed=$((count + ${#existing_numbers[@]}))
    
    for ((i=1; i<=max_needed; i++)); do
        local found=false
        for existing in "${existing_numbers[@]}"; do
            if [[ $i -eq $existing ]]; then
                found=true
                break
            fi
        done
        
        if [[ "$found" == false ]]; then
            available_numbers+=("$i")
            if [[ ${#available_numbers[@]} -eq $count ]]; then
                break
            fi
        fi
    done
    
    # Return as space-separated list
    echo "${available_numbers[@]}"
    log_info "Smart numbering allocated: ${available_numbers[*]}"
}

#===============================================================================
# INSTANCE OPERATIONS
#===============================================================================

# Function to rename instance
rename_instance() {
    local instance_id="$1"
    local instance_name="$2"
    local gpu_cluster="$3"
    local name_prefix="$4"
    local node_number="${5:-}"
    
    if [[ -z "$gpu_cluster" ]] || [[ "$gpu_cluster" == "null" ]]; then
        log_error "Cannot rename instance $instance_name: No GPU cluster OCID found"
        echo -e "${RED}Error: Instance $instance_name has no GPU cluster OCID tag${NC}"
        return 1
    fi
    
    local cluster_suffix
    cluster_suffix=$(extract_cluster_suffix "$gpu_cluster")
    
    # Auto-detect node number if not provided
    if [[ -z "$node_number" ]]; then
        node_number=$(find_next_node_number "$gpu_cluster" "$name_prefix")
    fi
    
    local new_name="${name_prefix}-${cluster_suffix}-node$(printf '%02d' "$node_number")"
    
    log_info "Attempting to rename instance $instance_name ($instance_id) to $new_name"
    
    echo -n "Renaming $instance_name to $new_name... "
    
    local cmd="oci compute instance update --instance-id \"$instance_id\" --display-name \"$new_name\" --force --region \"$REGION\""
    
    if execute_oci_command "$cmd" >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}✓ Success${NC}"
        log_success "Successfully renamed instance $instance_name to $new_name ($instance_id)"
        return 0
    else
        echo -e "${RED}✗ Failed${NC}"
        log_error "Failed to rename instance $instance_name to $new_name ($instance_id)"
        return 1
    fi
}

# Function to rename instances in GPU cluster
rename_gpu_cluster_instances() {
    local gpu_cluster="$1"
    local name_prefix="$2"
    local start_number="${3:-}"
    
    log_info "Rename requested for all instances in GPU cluster: $gpu_cluster"
    log_info "Name prefix: $name_prefix, Starting node number: ${start_number:-auto}"
    
    # Get all instances in the cluster
    local cmd="oci compute instance list --compartment-id \"$COMPARTMENT_ID\" --region \"$REGION\" --all --query \"data[?\\\"freeform-tags\\\".\\\"oci:compute:gpumemorycluster\\\"=='${gpu_cluster}'].{InstanceID:id,DisplayName:\\\"display-name\\\",State:\\\"lifecycle-state\\\",GPUCluster:\\\"freeform-tags\\\".\\\"oci:compute:gpumemorycluster\\\"}\" --output json"
    log_command "$cmd"
    
    local INSTANCES
    INSTANCES=$(eval "$cmd" 2>/dev/null)
    
    local COUNT
    COUNT=$(echo "$INSTANCES" | jq '. | length')
    
    if [[ "$COUNT" -eq 0 ]]; then
        log_warning "No instances found in GPU memory cluster: $gpu_cluster"
        echo -e "${YELLOW}No instances found in GPU memory cluster${NC}"
        return 0
    fi
    
    log_info "Found $COUNT instances in GPU cluster: $gpu_cluster"
    
    local cluster_suffix
    cluster_suffix=$(extract_cluster_suffix "$gpu_cluster")
    
    # Determine node numbers to use
    local node_numbers=()
    if [[ -n "$start_number" ]]; then
        # User specified starting number - only allocate what we need
        for ((i=0; i<COUNT; i++)); do
            node_numbers+=($((start_number + i)))
        done
        log_info "Using user-specified numbering starting from: $start_number"
    else
        # Sequential numbering from 1 to COUNT
        for ((i=1; i<=COUNT; i++)); do
            node_numbers+=($i)
        done
        log_info "Using sequential numbering: 1 to $COUNT"
    fi
    
    echo ""
    echo -e "${YELLOW}Instances will be renamed with pattern: ${name_prefix}-${cluster_suffix}-nodeXX${NC}"
    echo "GPU Memory Cluster: $gpu_cluster"
    echo "Total instances to rename: $COUNT"
    if [[ -n "$start_number" ]]; then
        echo "Starting node number: $start_number (user specified)"
    else
        echo "Node numbering: Sequential (1-$COUNT)"
    fi
    echo ""
    
    # Store instance data in arrays to avoid subshell issues
    local instance_names=()
    local instance_states=()
    local instance_ids=()
    local instance_clusters=()
    
    # Read all instance data into arrays
    while IFS='|' read -r name state id cluster; do
        [[ -z "$name" ]] && continue
        instance_names+=("$name")
        instance_states+=("$state")
        instance_ids+=("$id")
        instance_clusters+=("$cluster")
    done < <(echo "$INSTANCES" | jq -r '.[] | [.DisplayName, .State, .InstanceID, .GPUCluster] | join("|")')
    
    # Display current names and new names
    printf "%-40s %-10s %-40s %s\n" "CURRENT_NAME" "STATE" "NEW_NAME" "INSTANCE_ID"
    printf "%-40s %-10s %-40s %s\n" "------------" "-----" "--------" "-----------"
    
    for ((idx=0; idx<${#instance_names[@]}; idx++)); do
        local new_name="${name_prefix}-${cluster_suffix}-node$(printf '%02d' "${node_numbers[$idx]}")"
        printf "%-40s %-10s %-40s %s\n" "${instance_names[$idx]}" "${instance_states[$idx]}" "$new_name" "${instance_ids[$idx]}"
    done
    
    echo ""
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY RUN] The following commands would be executed:${NC}"
        echo ""
        
        for ((idx=0; idx<${#instance_names[@]}; idx++)); do
            local node_num=${node_numbers[$idx]}
            local new_name="${name_prefix}-${cluster_suffix}-node$(printf '%02d' "$node_num")"
            local cmd="oci compute instance update --instance-id \"${instance_ids[$idx]}\" --display-name \"$new_name\" --force --region \"$REGION\""
            echo -e "${CYAN}[$((idx+1))/${COUNT}]${NC} $cmd"
        done
        
        echo ""
        return 0
    fi
    
    read -p "Type 'RENAME' to confirm renaming all $COUNT instances: " CONFIRM
    
    if [[ "$CONFIRM" != "RENAME" ]]; then
        log_warning "Cluster rename cancelled by user"
        echo "Rename cancelled."
        return 0
    fi
    
    log_info "User confirmed rename of all instances in GPU cluster: $gpu_cluster"
    
    echo ""
    echo -e "${GREEN}Renaming all instances in GPU memory cluster...${NC}"
    echo ""
    
    local RENAMED_COUNT=0
    local FAILED_COUNT=0
    
    # Rename each instance
    for idx in "${!instance_names[@]}"; do
        local node_num=${node_numbers[$idx]}
        local new_name="${name_prefix}-${cluster_suffix}-node$(printf '%02d' "$node_num")"
        local instance_id="${instance_ids[$idx]}"
        local instance_name="${instance_names[$idx]}"
        
        echo -n "Renaming ${instance_name} to $new_name... "
        log_info "Attempting to rename: ${instance_name} (${instance_id}) to $new_name"
        
        # Log the command
        log_command "oci compute instance update --instance-id \"${instance_id}\" --display-name \"$new_name\" --force --region \"$REGION\""
        
        # Execute the rename
        if oci compute instance update \
            --instance-id "${instance_id}" \
            --display-name "$new_name" \
            --force \
            --region "$REGION" >> "$LOG_FILE" 2>&1; then
            echo -e "${GREEN}✓ Success${NC}"
            log_success "Successfully renamed: ${instance_name} to $new_name (${instance_id})"
            ((RENAMED_COUNT++))
        else
            echo -e "${RED}✗ Failed${NC}"
            log_error "Failed to rename: ${instance_name} to $new_name (${instance_id})"
            ((FAILED_COUNT++))
        fi
    done
    
    echo ""
    echo -e "${GREEN}Rename complete!${NC}"
    echo "Successfully renamed: $RENAMED_COUNT"
    echo "Failed: $FAILED_COUNT"
    
    log_info "Cluster rename summary - Success: $RENAMED_COUNT, Failed: $FAILED_COUNT"
    log_success "Cluster rename process completed"
}

# Function to reboot instance
reboot_instance() {
    local instance_id="$1"
    local instance_name="$2"
    
    log_info "Reboot requested for instance: $instance_name ($instance_id)"
    
    # Check for running pods unless skip flag is set
    if [[ "$SKIP_POD_CHECK" == false ]]; then
        local node_name
        if node_name=$(get_node_name_from_instance_id "$instance_id"); then
            if ! check_node_pods "$node_name"; then
                echo ""
                echo -e "${RED}ERROR: Node has running pods. Please drain the node first or use --skip-pod-check${NC}"
                echo ""
                echo "To drain the node, run:"
                echo "  $0 --instance-id $instance_id --drain"
                echo ""
                log_error "Reboot blocked: Node $node_name has running pods"
                return 1
            fi
        fi
    else
        log_warning "Skipping pod check as requested"
    fi
    
    echo ""
    echo -e "${YELLOW}Instance to reboot:${NC}"
    echo "  Name: $instance_name"
    echo "  OCID: $instance_id"
    echo ""
    
    local cmd="oci compute instance action --instance-id \"$instance_id\" --action SOFTRESET --region \"$REGION\""
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY RUN] The following command would be executed:${NC}"
        log_command "$cmd"
        return 0
    fi
    
    read -p "Type 'REBOOT' to confirm: " CONFIRM
    
    if [[ "$CONFIRM" != "REBOOT" ]]; then
        log_warning "Reboot cancelled by user"
        echo "Reboot cancelled."
        return 0
    fi
    
    log_info "User confirmed reboot for instance: $instance_name ($instance_id)"
    
    echo ""
    echo -e "${GREEN}Rebooting instance...${NC}"
    
    # Skip confirmation in execute_oci_command since we already confirmed
    if OCI_SKIP_CONFIRM=true execute_oci_command "$cmd" >> "$LOG_FILE" 2>&1; then
        log_success "Reboot initiated successfully for instance: $instance_name ($instance_id)"
        echo -e "${GREEN}Reboot initiated successfully${NC}"
    else
        log_error "Failed to reboot instance: $instance_name ($instance_id)"
        echo -e "${RED}Failed to reboot instance${NC}"
        return 1
    fi
}

# Function to terminate instance
terminate_instance() {
    local instance_id="$1"
    local instance_name="$2"
    
    log_info "Termination requested for instance: $instance_name ($instance_id)"
    
    # Check for running pods unless skip flag is set
    if [[ "$SKIP_POD_CHECK" == false ]]; then
        local node_name
        if node_name=$(get_node_name_from_instance_id "$instance_id"); then
            if ! check_node_pods "$node_name"; then
                echo ""
                echo -e "${RED}ERROR: Node has running pods. Please drain the node first or use --skip-pod-check${NC}"
                echo ""
                echo "To drain the node, run:"
                echo "  $0 --instance-id $instance_id --drain"
                echo ""
                log_error "Termination blocked: Node $node_name has running pods"
                return 1
            fi
        fi
    else
        log_warning "Skipping pod check as requested"
    fi
    
    echo ""
    echo -e "${RED}WARNING: This will TERMINATE the instance!${NC}"
    echo "  Name: $instance_name"
    echo "  OCID: $instance_id"
    echo ""
    
    local cmd="oci compute instance terminate --instance-id \"$instance_id\" --force --region \"$REGION\""
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY RUN] The following command would be executed:${NC}"
        log_command "$cmd"
        return 0
    fi
    
    read -p "Type 'TERMINATE' to confirm: " CONFIRM
    
    if [[ "$CONFIRM" != "TERMINATE" ]]; then
        log_warning "Termination cancelled by user"
        echo "Termination cancelled."
        return 0
    fi
    
    log_info "User confirmed termination for instance: $instance_name ($instance_id)"
    
    echo ""
    echo -e "${RED}Terminating instance...${NC}"
    
    # Skip confirmation in execute_oci_command since we already confirmed
    if OCI_SKIP_CONFIRM=true execute_oci_command "$cmd" >> "$LOG_FILE" 2>&1; then
        log_success "Termination initiated successfully for instance: $instance_name ($instance_id)"
        echo -e "${GREEN}Termination initiated successfully${NC}"
    else
        log_error "Failed to terminate instance: $instance_name ($instance_id)"
        echo -e "${RED}Failed to terminate instance${NC}"
        return 1
    fi
}

#===============================================================================
# GPU CLUSTER OPERATIONS
#===============================================================================

# Function to cordon/drain/uncordon instances in GPU cluster
cordon_drain_gpu_cluster() {
    local gpu_cluster="$1"
    local operation="$2"  # "cordon", "drain", "cordon-drain", or "uncordon"
    
    log_info "$operation requested for all instances in GPU cluster: $gpu_cluster"
    
    # Get all instances in the cluster
    local cmd="oci compute instance list --compartment-id \"$COMPARTMENT_ID\" --region \"$REGION\" --all --query \"data[?\\\"freeform-tags\\\".\\\"oci:compute:gpumemorycluster\\\"=='${gpu_cluster}'].{InstanceID:id,DisplayName:\\\"display-name\\\",State:\\\"lifecycle-state\\\"}\" --output json"
    log_command "$cmd"
    
    local INSTANCES
    INSTANCES=$(eval "$cmd" 2>/dev/null)
    
    local COUNT
    COUNT=$(echo "$INSTANCES" | jq '. | length')
    
    if [[ "$COUNT" -eq 0 ]]; then
        log_warning "No instances found in GPU memory cluster: $gpu_cluster"
        echo -e "${YELLOW}No instances found in GPU memory cluster${NC}"
        return 0
    fi
    
    log_info "Found $COUNT instances in GPU cluster: $gpu_cluster"
    
    echo ""
    echo -e "${YELLOW}Will $operation all nodes in GPU memory cluster${NC}"
    echo "GPU Memory Cluster: $gpu_cluster"
    echo "Total instances: $COUNT"
    echo ""
    
    # Store instance data in arrays
    local instance_names=()
    local instance_ids=()
    
    while IFS='|' read -r name id; do
        [[ -z "$name" ]] && continue
        instance_names+=("$name")
        instance_ids+=("$id")
    done < <(echo "$INSTANCES" | jq -r '.[] | [.DisplayName, .InstanceID] | join("|")')
    
    # Display instances
    printf "%-40s %s\n" "DISPLAY_NAME" "INSTANCE_ID"
    printf "%-40s %s\n" "------------" "-----------"
    
    for ((idx=0; idx<${#instance_names[@]}; idx++)); do
        printf "%-40s %s\n" "${instance_names[$idx]}" "${instance_ids[$idx]}"
    done
    
    echo ""
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY RUN] Would attempt to $operation nodes${NC}"
        return 0
    fi
    
    local SUCCESS_COUNT=0
    local FAILED_COUNT=0
    local SKIPPED_COUNT=0
    
    # Process each instance
    for ((idx=0; idx<${#instance_names[@]}; idx++)); do
        local node_name
        if ! node_name=$(get_node_name_from_instance_id "${instance_ids[$idx]}"); then
            echo -e "${YELLOW}⚠ Skipping ${instance_names[$idx]}: Not found in Kubernetes${NC}"
            ((SKIPPED_COUNT++))
            continue
        fi
        
        echo ""
        echo -e "${BLUE}Processing node: $node_name (${instance_names[$idx]})${NC}"
        
        case $operation in
            cordon)
                if cordon_node "$node_name"; then
                    ((SUCCESS_COUNT++))
                else
                    ((FAILED_COUNT++))
                fi
                ;;
            drain|cordon-drain)
                # Both drain and cordon-drain do the same thing now
                # since drain_node handles cordoning
                if drain_node "$node_name"; then
                    ((SUCCESS_COUNT++))
                else
                    ((FAILED_COUNT++))
                fi
                ;;
            uncordon)
                if uncordon_node "$node_name"; then
                    ((SUCCESS_COUNT++))
                else
                    ((FAILED_COUNT++))
                fi
                ;;
        esac
    done
    
    echo ""
    echo -e "${GREEN}Operation complete!${NC}"
    echo "Successfully processed: $SUCCESS_COUNT"
    echo "Failed: $FAILED_COUNT"
    echo "Skipped (not in K8s): $SKIPPED_COUNT"
    
    log_info "Cluster $operation summary - Success: $SUCCESS_COUNT, Failed: $FAILED_COUNT, Skipped: $SKIPPED_COUNT"
}

# Function to terminate all instances in GPU cluster
terminate_gpu_cluster_instances() {
    local gpu_cluster="$1"
    
    log_info "Termination requested for all instances in GPU cluster: $gpu_cluster"
    
    # Get all instances in the cluster
    local cmd="oci compute instance list --compartment-id \"$COMPARTMENT_ID\" --region \"$REGION\" --all --query \"data[?\\\"freeform-tags\\\".\\\"oci:compute:gpumemorycluster\\\"=='${gpu_cluster}'].{InstanceID:id,DisplayName:\\\"display-name\\\",State:\\\"lifecycle-state\\\"}\" --output json"
    log_command "$cmd"
    
    local INSTANCES
    INSTANCES=$(eval "$cmd" 2>/dev/null)
    
    local COUNT
    COUNT=$(echo "$INSTANCES" | jq '. | length')
    
    if [[ "$COUNT" -eq 0 ]]; then
        log_warning "No instances found in GPU memory cluster: $gpu_cluster"
        echo -e "${YELLOW}No instances found in GPU memory cluster${NC}"
        return 0
    fi
    
    log_info "Found $COUNT instances in GPU cluster: $gpu_cluster"
    
    # Store instance data in arrays
    local instance_names=()
    local instance_states=()
    local instance_ids=()
    
    while IFS='|' read -r name state id; do
        [[ -z "$name" ]] && continue
        instance_names+=("$name")
        instance_states+=("$state")
        instance_ids+=("$id")
    done < <(echo "$INSTANCES" | jq -r '.[] | [.DisplayName, .State, .InstanceID] | join("|")')
    
    echo -e "${RED}WARNING: This will TERMINATE ALL instances in the GPU memory cluster!${NC}"
    echo "GPU Memory Cluster: $gpu_cluster"
    echo "Total instances to terminate: $COUNT"
    echo ""
    
    # Display instances that will be terminated
    printf "%-40s %-10s %s\n" "DISPLAY_NAME" "STATE" "INSTANCE_ID"
    printf "%-40s %-10s %s\n" "------------" "-----" "-----------"
    
    for ((idx=0; idx<${#instance_names[@]}; idx++)); do
        printf "%-40s %-10s %s\n" "${instance_names[$idx]}" "${instance_states[$idx]}" "${instance_ids[$idx]}"
        log_info "Instance to terminate: ${instance_names[$idx]} (${instance_ids[$idx]}) - State: ${instance_states[$idx]}"
    done
    
    echo ""
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY RUN] The following command would be executed:${NC}"
        echo ""
        local cmd="oci compute compute-gpu-memory-cluster delete --compute-gpu-memory-cluster-id $gpu_cluster --force"
        echo -e "${CYAN}${NC} $cmd"
        echo ""
        return 0
    fi
    
    read -p "Type 'TERMINATE ALL' to confirm deletion of all $COUNT instances: " CONFIRM
    
    if [[ "$CONFIRM" != "TERMINATE ALL" ]]; then
        log_warning "Cluster termination cancelled by user"
        echo "Termination cancelled."
        return 0
    fi
    
    log_info "User confirmed termination of all instances in GPU cluster: $gpu_cluster"
    
    echo ""
    echo -e "${RED}Terminating GPU memory cluster...${NC}"
    echo ""
    
    echo -n "Terminating $gpu_cluster..."
    log_info "Attempting to terminate GPU cluster: $gpu_cluster"
    
    local cmd="oci compute compute-gpu-memory-cluster delete --compute-gpu-memory-cluster-id $gpu_cluster --force"
    
    # Skip confirmation in execute_oci_command since we already confirmed
    if OCI_SKIP_CONFIRM=true execute_oci_command "$cmd" >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}✓ Success${NC}"
        log_success "Successfully initiated termination of GPU cluster: $gpu_cluster"
    else
        echo -e "${RED}✗ Failed${NC}"
        log_error "Failed to terminate GPU cluster: $gpu_cluster"
        return 1
    fi
    
    echo ""
    echo -e "${GREEN}Termination initiated!${NC}"
    
    log_success "Cluster termination process completed"
}

#===============================================================================
# QUERY FUNCTIONS
#===============================================================================

# Function to list all GPU instances
list_all_instances() {
    log_info "Listing all GPU instances in compartment"
    
    echo -e "${GREEN}Listing all GPU instances in compartment${NC}"
    echo "Compartment: $COMPARTMENT_ID"
    echo "Region: $REGION"
    echo ""
    
    local cmd="oci compute instance list --compartment-id \"$COMPARTMENT_ID\" --region \"$REGION\" --all --query 'data[?contains(shape, \`GPU\`) || contains(shape, \`GB\`)].{InstanceID:id,DisplayName:\"display-name\",State:\"lifecycle-state\",Shape:shape,AD:\"availability-domain\",GPUCluster:\"freeform-tags\".\"oci:compute:gpumemorycluster\",Created:\"time-created\"}' --output json"
    log_command "$cmd"
    
    local RESULT
    RESULT=$(eval "$cmd" 2>/dev/null)
    
    local COUNT
    COUNT=$(echo "$RESULT" | jq '. | length')
    
    if [[ "$COUNT" -eq 0 ]]; then
        log_warning "No GPU instances found"
        echo -e "${YELLOW}No GPU instances found in compartment${NC}"
        return 0
    fi
    
    log_info "Found $COUNT GPU instance(s)"
    
    echo -e "${GREEN}Found $COUNT GPU instance(s):${NC}"
    echo ""
    
    # Display as table
    echo "$RESULT" | jq -r '
        ["DISPLAY_NAME", "SHAPE", "STATE", "GPU_CLUSTER", "INSTANCE_ID"],
        ["------------", "-----", "-----", "-----------", "-----------"],
        (.[] | [
            .DisplayName,
            .Shape,
            .State,
            (.GPUCluster // "N/A" | if length > 20 then .[-20:] else . end),
            .InstanceID
        ]) | @tsv
    ' | column -t -s $'\t'
    
    echo ""
    echo -e "${BLUE}Summary by Shape:${NC}"
    echo "$RESULT" | jq -r 'group_by(.Shape) | .[] | "\(.[0].Shape): \(length) instances"'
    
    echo ""
    echo -e "${BLUE}Summary by State:${NC}"
    echo "$RESULT" | jq -r 'group_by(.State) | .[] | "\(.[0].State): \(length) instances"'
    
    echo ""
    echo -e "${BLUE}Summary by GPU Cluster:${NC}"
    echo "$RESULT" | jq -r '
        group_by(.GPUCluster // "No Cluster") | 
        .[] | 
        "\(.[0].GPUCluster // "No Cluster"): \(length) instances"
    '
}

# Function to query by display name
query_by_display_name() {
    local display_name="$1"
    
    log_info "Querying by display name: $display_name"
    
    echo -e "${GREEN}Searching for instance: ${display_name}${NC}"
    echo "Compartment: $COMPARTMENT_ID"
    echo "Region: $REGION"
    echo ""
    
    local cmd="oci compute instance list --compartment-id \"$COMPARTMENT_ID\" --region \"$REGION\" --all --query \"data[?\\\"display-name\\\"=='${display_name}'].{InstanceID:id,DisplayName:\\\"display-name\\\",State:\\\"lifecycle-state\\\",Shape:shape,GPUCluster:\\\"freeform-tags\\\".\\\"oci:compute:gpumemorycluster\\\"}\" --output json"
    log_command "$cmd"
    
    local RESULT
    RESULT=$(eval "$cmd" 2>/dev/null)
    
    local COUNT
    COUNT=$(echo "$RESULT" | jq '. | length')
    
    if [[ "$COUNT" -eq 0 ]]; then
        log_warning "No instances found with display name: ${display_name}"
        echo -e "${YELLOW}No instances found with display name: ${display_name}${NC}"
        return 0
    fi
    
    log_info "Found $COUNT instance(s) with display name: ${display_name}"
    
    echo -e "${GREEN}Found $COUNT instance(s):${NC}"
    echo ""
    
    # Display as table
    echo "$RESULT" | jq -r '
        ["DISPLAY_NAME", "SHAPE", "STATE", "INSTANCE_ID", "GPU_MEMORY_CLUSTER"],
        ["------------", "-----", "-----", "-----------", "-------------------"],
        (.[] | [
            .DisplayName,
            .Shape,
            .State,
            .InstanceID,
            .GPUCluster // "N/A"
        ]) | @tsv
    ' | column -t -s $'\t'
    
    echo ""
    echo -e "${GREEN}Instance OCID:${NC}"
    local INSTANCE_ID
    INSTANCE_ID=$(echo "$RESULT" | jq -r '.[].InstanceID')
    echo "$INSTANCE_ID"
    
    log_info "Instance OCID: $INSTANCE_ID"
    
    echo ""
    local GPU_CLUSTER
    GPU_CLUSTER=$(echo "$RESULT" | jq -r '.[0].GPUCluster // empty')
    if [[ -n "$GPU_CLUSTER" ]]; then
        echo -e "${GREEN}GPU Memory Cluster OCID:${NC}"
        echo "$GPU_CLUSTER"
        log_info "GPU Memory Cluster OCID: $GPU_CLUSTER"
    fi
    
    # Perform action if specified
    if [[ -n "$ACTION" ]]; then
        echo ""
        
        # Get Kubernetes node name for cordon/drain actions
        local node_name
        
        case $ACTION in
            cordon|drain|cordon-drain|uncordon)
                if node_name=$(get_node_name_from_display_name "$display_name"); then
                    case $ACTION in
                        cordon)       cordon_node "$node_name" ;;
                        drain)        drain_node "$node_name" ;;
                        cordon-drain) cordon_and_drain_node "$node_name" ;;
                        uncordon)     uncordon_node "$node_name" ;;
                    esac
                else
                    log_error "Cannot perform $ACTION: Node not found in Kubernetes"
                fi
                ;;
            reboot)
                reboot_instance "$INSTANCE_ID" "$display_name"
                ;;
            terminate)
                terminate_instance "$INSTANCE_ID" "$display_name"
                ;;
            rename)
                if rename_instance "$INSTANCE_ID" "$display_name" "$GPU_CLUSTER" "$NEW_NAME_PREFIX" "$START_NODE_NUMBER"; then
                    log_success "Instance renamed successfully"
                fi
                ;;
        esac
    fi
}

# Function to query by instance ID
query_by_instance_id() {
    local instance_id="$1"
    
    log_info "Querying by instance ID: $instance_id"
    
    echo -e "${GREEN}Searching for instance: ${instance_id}${NC}"
    echo "Region: $REGION"
    echo ""
    
    local cmd="oci compute instance get --instance-id \"$instance_id\" --region \"$REGION\" --query 'data.{InstanceID:id,DisplayName:\"display-name\",State:\"lifecycle-state\",Shape:shape,AD:\"availability-domain\",FaultDomain:\"fault-domain\",GPUCluster:\"freeform-tags\".\"oci:compute:gpumemorycluster\",Created:\"time-created\"}' --output json"
    log_command "$cmd"
    
    local RESULT
    RESULT=$(eval "$cmd" 2>/dev/null)
    
    if [[ -z "$RESULT" ]]; then
        log_error "Instance not found or unable to retrieve instance details: $instance_id"
        echo -e "${RED}Error: Instance not found or unable to retrieve instance details${NC}"
        return 1
    fi
    
    log_success "Successfully retrieved instance details for: $instance_id"
    
    echo -e "${GREEN}Instance Details:${NC}"
    echo ""
    
    # Display as key-value pairs
    echo "$RESULT" | jq -r '
        [
            ["Display Name:", .DisplayName],
            ["Shape:", .Shape],
            ["State:", .State],
            ["Availability Domain:", .AD],
            ["Fault Domain:", .FaultDomain],
            ["GPU Memory Cluster:", (.GPUCluster // "N/A")],
            ["Created:", .Created],
            ["Instance OCID:", .InstanceID]
        ] | .[] | @tsv
    ' | column -t -s $'\t'
    
    local INSTANCE_NAME
    INSTANCE_NAME=$(echo "$RESULT" | jq -r '.DisplayName')
    local GPU_CLUSTER
    GPU_CLUSTER=$(echo "$RESULT" | jq -r '.GPUCluster // empty')
    
    log_info "Instance Name: $INSTANCE_NAME, State: $(echo "$RESULT" | jq -r '.State')"
    
    # Perform action if specified
    if [[ -n "$ACTION" ]]; then
        echo ""
        
        # Get Kubernetes node name for cordon/drain actions
        local node_name
        
        case $ACTION in
            cordon|drain|cordon-drain|uncordon)
                if node_name=$(get_node_name_from_instance_id "$instance_id"); then
                    case $ACTION in
                        cordon)       cordon_node "$node_name" ;;
                        drain)        drain_node "$node_name" ;;
                        cordon-drain) cordon_and_drain_node "$node_name" ;;
                        uncordon)     uncordon_node "$node_name" ;;
                    esac
                else
                    log_error "Cannot perform $ACTION: Node not found in Kubernetes"
                fi
                ;;
            reboot)
                reboot_instance "$instance_id" "$INSTANCE_NAME"
                ;;
            terminate)
                terminate_instance "$instance_id" "$INSTANCE_NAME"
                ;;
            rename)
                if rename_instance "$instance_id" "$INSTANCE_NAME" "$GPU_CLUSTER" "$NEW_NAME_PREFIX" "$START_NODE_NUMBER"; then
                    log_success "Instance renamed successfully"
                fi
                ;;
        esac
    fi
}

# Function to query by GPU cluster
query_by_gpu_cluster() {
    local gpu_cluster="$1"
    
    log_info "Querying by GPU cluster: $gpu_cluster"
    
    echo -e "${GREEN}Searching for instances in GPU Memory Cluster:${NC}"
    echo "$gpu_cluster"
    echo "Compartment: $COMPARTMENT_ID"
    echo "Region: $REGION"
    echo ""
    
    local cmd="oci compute instance list --compartment-id \"$COMPARTMENT_ID\" --region \"$REGION\" --all --query \"data[?\\\"freeform-tags\\\".\\\"oci:compute:gpumemorycluster\\\"=='${gpu_cluster}'].{InstanceID:id,DisplayName:\\\"display-name\\\",State:\\\"lifecycle-state\\\",Shape:shape,AD:\\\"availability-domain\\\",FaultDomain:\\\"fault-domain\\\"}\" --output json"
    log_command "$cmd"
    
    local RESULT
    RESULT=$(eval "$cmd" 2>/dev/null)
    
    local COUNT
    COUNT=$(echo "$RESULT" | jq '. | length')
    
    if [[ "$COUNT" -eq 0 ]]; then
        log_warning "No instances found in GPU memory cluster: $gpu_cluster"
        echo -e "${YELLOW}No instances found in GPU memory cluster${NC}"
        return 0
    fi
    
    log_info "Found $COUNT instance(s) in GPU cluster: $gpu_cluster"
    
    echo -e "${GREEN}Found $COUNT instance(s):${NC}"
    echo ""
    
    # Display as table
    echo "$RESULT" | jq -r '
        ["DISPLAY_NAME", "STATE", "SHAPE", "FAULT_DOMAIN", "INSTANCE_ID"],
        ["------------", "-----", "-----", "------------", "-----------"],
        (.[] | [
            .DisplayName,
            .State,
            .Shape,
            .FaultDomain,
            .InstanceID
        ]) | @tsv
    ' | column -t -s $'\t'
    
    # Perform action if specified
    if [[ -n "$ACTION" ]]; then
        echo ""
        
        case $ACTION in
            terminate)
                terminate_gpu_cluster_instances "$gpu_cluster"
                ;;
            rename)
                rename_gpu_cluster_instances "$gpu_cluster" "$NEW_NAME_PREFIX" "$START_NODE_NUMBER"
                ;;
            cordon|drain|cordon-drain|uncordon)
                cordon_drain_gpu_cluster "$gpu_cluster" "$ACTION"
                ;;
        esac
    fi
}

#===============================================================================
# MAIN EXECUTION
#===============================================================================

# Execute based on mode
case $MODE in
    display-name)
        query_by_display_name "$SEARCH_VALUE"
        ;;
    instance-id)
        query_by_instance_id "$SEARCH_VALUE"
        ;;
    gpu-cluster)
        query_by_gpu_cluster "$SEARCH_VALUE"
        ;;
    list-all)
        list_all_instances
        ;;
esac

log_success "Script completed successfully"
echo ""
echo -e "${BLUE}Log file: $LOG_FILE${NC}"