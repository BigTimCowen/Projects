#!/bin/bash
# Script to get Kubernetes node details, GPU clique information, and OCI instance tags
# This makes it easy to get information related to kubernetes nodes clique ids and associate them to the gpu memory clusters defined in OCI tags

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
    echo -e "${YELLOW}Warning: variables.sh not found. Please ensure COMPARTMENT_ID and REGION are set.${NC}"
fi

# Function to list all unique cliques
list_all_cliques() {
    echo -e "${BOLD}${MAGENTA}=== All GPU Cliques in Kubernetes Cluster ===${NC}"
    echo ""
    
    # Get all unique cliques
    local cliques=$(kubectl get nodes -o json | jq -r '.items[].metadata.labels["nvidia.com/gpu.clique"]' | grep -v null | sort -u)
    
    if [[ -z "$cliques" ]]; then
        echo -e "${YELLOW}No GPU cliques found in the cluster${NC}"
        return 0
    fi
    
    local total_cliques=$(echo "$cliques" | wc -l)
    echo -e "${BOLD}${CYAN}Total Cliques Found:${NC} $total_cliques"
    echo ""
    
    # Iterate through each clique
    while read -r clique_id; do
        [[ -z "$clique_id" ]] && continue
        
        echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}${YELLOW}Clique ID:${NC} $clique_id"
        
        # Get all nodes in this clique
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
            # Query OCI for gpu-memory-cluster tag
            local gpu_mem_cluster=$(oci compute instance get --instance-id "$ocid" --query 'data."freeform-tags"."oci:compute:gpumemorycluster"' --raw-output 2>/dev/null)
            gpu_mem_cluster=${gpu_mem_cluster:-N/A}
            
            # Append to the cluster group
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
    
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Function to get summary of all cliques
list_cliques_summary() {
    echo -e "${BOLD}${MAGENTA}=== GPU Cliques Summary ===${NC}"
    echo ""
    
    # Get all unique cliques
    local cliques=$(kubectl get nodes -o json | jq -r '.items[].metadata.labels["nvidia.com/gpu.clique"]' | grep -v null | sort -u)
    
    if [[ -z "$cliques" ]]; then
        echo -e "${YELLOW}No GPU cliques found in the cluster${NC}"
        return 0
    fi
    
    printf "${BOLD}%-40s %-15s %-20s${NC}\n" "Clique ID" "Total Nodes" "Memory Clusters"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    while read -r clique_id; do
        [[ -z "$clique_id" ]] && continue
        
        # Get all nodes in this clique
        local node_count=$(kubectl get nodes -o json | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
        
        # Get unique GPU memory clusters for this clique
        local clique_data=$(kubectl get nodes -o json | jq -r --arg clique "$clique_id" '
            .items[] | 
            select(.metadata.labels["nvidia.com/gpu.clique"]==$clique) | 
            .spec.providerID
        ')
        
        declare -A mem_clusters
        while read -r ocid; do
            [[ -z "$ocid" ]] && continue
            local gpu_mem_cluster=$(oci compute instance get --instance-id "$ocid" --query 'data."freeform-tags"."oci:compute:gpumemorycluster"' --raw-output 2>/dev/null)
            gpu_mem_cluster=${gpu_mem_cluster:-N/A}
            mem_clusters[$gpu_mem_cluster]=1
        done <<< "$clique_data"
        
        local cluster_list=$(echo "${!mem_clusters[@]}" | tr ' ' ',' | tr '\n' ',' | sed 's/,$//')
        
        printf "${CYAN}%-40s${NC} ${GREEN}%-15s${NC} ${YELLOW}%-20s${NC}\n" "$clique_id" "$node_count" "$cluster_list"
        
        unset mem_clusters
    done <<< "$cliques"
}

# Function to get node name from instance OCID
get_node_info() {
    local instance_id="$1"
    local show_labels="$2"
    local show_clique="$3"
    local count_clique="$4"
    
    local provider_id="${instance_id}"
    local node_name=$(kubectl get nodes -o jsonpath="{.items[?(@.spec.providerID=='${provider_id}')].metadata.name}" 2>/dev/null)
    
    if [[ -z "$node_name" ]]; then
        echo -e "${RED}Could not find Kubernetes node for instance OCID: $instance_id${NC}"
        return 1
    fi
    
    echo -e "${BOLD}${CYAN}Node Name:${NC} $node_name"
    echo -e "${BOLD}${CYAN}Instance OCID:${NC} $instance_id"
    
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
        local clique_size=$(kubectl get nodes -o json | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
        
        echo ""
        echo -e "${BOLD}${GREEN}=== GPU Clique Information ===${NC}"
        echo -e "${CYAN}GPU Clique ID:${NC} ${clique_id:-N/A}"
        echo -e "${CYAN}GPU Clique Size:${NC} ${clique_size:-N/A}"
        
        # Get OCI gpu-memory-cluster tag
        echo ""
        echo -e "${BOLD}${GREEN}=== OCI Instance Tags ===${NC}"
        local gpu_memory_cluster=$(oci compute instance get --instance-id "$instance_id" --query 'data."freeform-tags"."oci:compute:gpumemorycluster"' --raw-output 2>/dev/null)
        echo -e "${CYAN}GPU Memory Cluster (OCI Tag):${NC} ${gpu_memory_cluster:-N/A}"
    fi
    
    # Count nodes with same clique ID if requested
    if [[ "$count_clique" == "true" ]]; then
        local clique_id=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.clique}' 2>/dev/null)
        
        if [[ -n "$clique_id" && "$clique_id" != "null" ]]; then
            echo ""
            echo -e "${BOLD}${YELLOW}=== Nodes in Same Clique ($clique_id) ===${NC}"
            
            # Get all nodes in clique with their GPU memory cluster
            local clique_data=$(kubectl get nodes -o json | jq -r --arg clique "$clique_id" '
                .items[] | 
                select(.metadata.labels["nvidia.com/gpu.clique"]==$clique) | 
                "\(.metadata.name)|\(.spec.providerID)"
            ')
            
            local node_count=$(kubectl get nodes -o json | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
            
            echo -e "${CYAN}Total nodes in clique:${NC} $node_count"
            echo ""
            
            # Collect nodes by GPU memory cluster
            declare -A cluster_nodes
            
            while IFS='|' read -r node ocid; do
                # Query OCI for gpu-memory-cluster tag
                local gpu_mem_cluster=$(oci compute instance get --instance-id "$ocid" --query 'data."freeform-tags"."oci:compute:gpumemorycluster"' --raw-output 2>/dev/null)
                gpu_mem_cluster=${gpu_mem_cluster:-N/A}
                
                # Append to the cluster group
                if [[ -z "${cluster_nodes[$gpu_mem_cluster]}" ]]; then
                    cluster_nodes[$gpu_mem_cluster]="$node|$ocid"
                else
                    cluster_nodes[$gpu_mem_cluster]="${cluster_nodes[$gpu_mem_cluster]}"$'\n'"$node|$ocid"
                fi
            done <<< "$clique_data"
            
            # Display grouped by GPU memory cluster
            for mem_cluster in $(echo "${!cluster_nodes[@]}" | tr ' ' '\n' | sort); do
                echo -e "${BOLD}${BLUE}GPU Mem Cluster: $mem_cluster${NC}"
                
                while IFS='|' read -r node ocid; do
                    echo -e "  ${GREEN}$node${NC} - ${YELLOW}$ocid${NC}"
                done <<< "${cluster_nodes[$mem_cluster]}"
                echo ""
            done
        else
            echo ""
            echo -e "${YELLOW}No GPU clique ID found for this node${NC}"
        fi
    fi
    
    return 0
}

# Function to list all instances in compartment with GPU info
list_all_instances() {
    local compartment_id="$1"
    local region="$2"
    
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
    
    # Get all GPU nodes from Kubernetes
    local gpu_nodes=$(kubectl get nodes -o json | jq -r '.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]) | .spec.providerID' | sort -u)
    
    if [[ -z "$gpu_nodes" ]]; then
        echo -e "${YELLOW}No GPU nodes found in Kubernetes cluster${NC}"
        return 0
    fi
    
    # Print header
    echo -e "${BOLD}$(printf '%-30s %-12s %-50s %-10s %-40s %-12s' 'Display Name' 'State' 'K8s Node' 'GPU Mem' 'Clique ID' 'Clique Size')${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Process each GPU node instance
    while read -r instance_id; do
        [[ -z "$instance_id" ]] && continue
        
        # Get instance details from OCI
        local instance_details=$(oci compute instance get --instance-id "$instance_id" --query 'data.{"DisplayName":"display-name","State":"lifecycle-state"}' --output json 2>/dev/null)
        
        if [[ -z "$instance_details" ]]; then
            continue
        fi
        
        local display_name=$(echo "$instance_details" | jq -r '.DisplayName')
        local state=$(echo "$instance_details" | jq -r '.State')
        
        # Get GPU memory cluster tag
        local gpu_mem_cluster=$(oci compute instance get --instance-id "$instance_id" --query 'data."freeform-tags"."oci:compute:gpumemorycluster"' --raw-output 2>/dev/null)
        gpu_mem_cluster=${gpu_mem_cluster:-N/A}
        
        # Get K8s node name
        local node_name=$(kubectl get nodes -o jsonpath="{.items[?(@.spec.providerID=='${instance_id}')].metadata.name}" 2>/dev/null)
        node_name=${node_name:-N/A}
        
        # Get clique info
        local clique_id="N/A"
        local clique_size="N/A"
        if [[ "$node_name" != "N/A" ]]; then
            clique_id=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.clique}' 2>/dev/null)
            clique_id=${clique_id:-N/A}
            if [[ "$clique_id" != "N/A" && "$clique_id" != "null" ]]; then
                clique_size=$(kubectl get nodes -o json | jq --arg clique "$clique_id" '[.items[] | select(.metadata.labels["nvidia.com/gpu.clique"]==$clique)] | length')
            fi
        fi
        
        # Truncate long names
        local short_name="${display_name:0:28}"
        local short_node="${node_name:0:48}"
        local short_clique="${clique_id:0:38}"
        
        # Format output with colors
        if [[ "$state" == "RUNNING" ]]; then
            state_display="${GREEN}${state}${NC}"
        else
            state_display="${YELLOW}${state}${NC}"
        fi
        
        if [[ "$node_name" == "N/A" ]]; then
            node_display="${RED}${short_node}${NC}"
        else
            node_display="${GREEN}${short_node}${NC}"
        fi
        
        # Use echo -e for proper color rendering
        echo -e "$(printf '%-30s' "$short_name") ${state_display}$(printf '%*s' $((12 - ${#state})) '') ${node_display}$(printf '%*s' $((50 - ${#short_node})) '') ${CYAN}$(printf '%-10s' "$gpu_mem_cluster")${NC} ${YELLOW}$(printf '%-40s' "$short_clique")${NC} ${MAGENTA}$(printf '%-12s' "$clique_size")${NC}"
        
    done <<< "$gpu_nodes"
}

# Function to list all instances in a GPU memory cluster
list_instances_by_gpu_cluster() {
    local gpu_cluster="$1"
    local compartment_id="$2"
    local region="$3"
    
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
    
    local cmd="oci compute instance list --compartment-id \"$compartment_id\" --region \"$region\" --all --query \"data[?\\\"freeform-tags\\\".\\\"oci:compute:gpumemorycluster\\\"=='${gpu_cluster}'].{InstanceID:id,DisplayName:\\\"display-name\\\",State:\\\"lifecycle-state\\\"}\" --output json"
    
    eval "$cmd" | jq -r '.[] | "\(.InstanceID)|\(.DisplayName)|\(.State)"' | while IFS='|' read -r instance_id display_name state; do
        echo -e "${BOLD}${CYAN}Display Name:${NC} $display_name"
        
        # Color code the state
        if [[ "$state" == "RUNNING" ]]; then
            echo -e "${BOLD}${CYAN}State:${NC} ${GREEN}$state${NC}"
        else
            echo -e "${BOLD}${CYAN}State:${NC} ${YELLOW}$state${NC}"
        fi
        
        # Try to find corresponding K8s node
        local node_name=$(kubectl get nodes -o jsonpath="{.items[?(@.spec.providerID=='${instance_id}')].metadata.name}" 2>/dev/null)
        if [[ -n "$node_name" ]]; then
            echo -e "  ${GREEN}$node_name${NC} - ${YELLOW}$instance_id${NC}"
            local clique_id=$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.clique}' 2>/dev/null)
            if [[ -n "$clique_id" && "$clique_id" != "null" ]]; then
                echo -e "${BOLD}${CYAN}GPU Clique ID:${NC} $clique_id"
            fi
        else
            echo -e "  ${YELLOW}$instance_id${NC} - ${RED}No K8s node found${NC}"
        fi
        echo ""
    done
}

# Main script
if [ -z "$1" ]; then
    # No arguments - list all GPU instances in compartment
    list_all_instances "$COMPARTMENT_ID" "$REGION"
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
    list_instances_by_gpu_cluster "$gpu_cluster" "$COMPARTMENT_ID" "$REGION"
    exit $?
fi

# Check if showing help
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo -e "${BOLD}Usage:${NC} $0 [instance-ocid] [OPTIONS]"
    echo ""
    echo "If no instance-ocid is provided, lists all GPU instances in the compartment"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --labels         Show all labels for the node"
    echo "  --clique         Show GPU clique information and OCI tags"
    echo "  --count-clique   Count and list all nodes in the same clique with OCI tags"
    echo "  --all            Show everything (labels + clique + count + OCI tags)"
    echo ""
    echo -e "${BOLD}Clique Analysis:${NC}"
    echo "  --list-cliques   List all unique cliques with nodes grouped by GPU memory cluster"
    echo "  --cliques-summary   Show summary table of all cliques"
    echo ""
    echo -e "${BOLD}GPU Cluster Search:${NC}"
    echo "  --list-cluster <gpu-cluster-id>"
    echo "    List all instances in a specific GPU memory cluster"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                                                    # List all GPU instances"
    echo "  $0 --list-cliques                                     # List all cliques with details"
    echo "  $0 --cliques-summary                                  # Summary table of cliques"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx                 # Basic node info"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --labels        # Show labels"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --clique        # Show clique info"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --count-clique  # Show clique members"
    echo "  $0 ocid1.instance.oc1.us-dallas-1.xxx --all           # Show everything"
    echo "  $0 --list-cluster 0                                   # List cluster 0 instances"
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