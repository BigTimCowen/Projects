#!/usr/bin/env bash
#
# OCI Policy Audit Script
# Recursively searches all compartments and lists policies
#
# Version: 2.3.0 (2026-01-25) - Search keyword highlighting in results
#

# Don't use set -e as we want to continue even if some compartments fail
DEBUG="${DEBUG:-false}"

# Source variables.sh if it exists in current directory or script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_LOADED=""
if [[ -f "./variables.sh" ]]; then
    source "./variables.sh"
    VARS_LOADED="./variables.sh"
elif [[ -f "$SCRIPT_DIR/variables.sh" ]]; then
    source "$SCRIPT_DIR/variables.sh"
    VARS_LOADED="$SCRIPT_DIR/variables.sh"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Default values (can be overridden by variables.sh or command line)
TENANCY_OCID="${TENANCY_OCID:-}"
FILTER="${FILTER:-}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-pretty}"
SHOW_COMPARTMENT_TREE="${SHOW_COMPARTMENT_TREE:-false}"
CONFIG_FILE="${CONFIG_FILE:-}"
MAX_PARALLEL="${MAX_PARALLEL:-${PARALLEL:-15}}"
EXPAND_ALL="${EXPAND_ALL:-true}"
REFRESH_CACHE="${REFRESH_CACHE:-false}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/oci-policy-audit}"
CACHE_TTL="${CACHE_TTL:-3600}"  # Default 1 hour in seconds

usage() {
    echo ""
    echo -e "${BOLD}OCI Policy Audit Script${NC}"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -t, --tenancy OCID     Tenancy OCID (default: from OCI config)"
    echo "  -C, --config FILE      OCI config file path (default: ~/.oci/config)"
    echo "  -v, --vars FILE        Variables file to source (default: ./variables.sh)"
    echo "  -f, --filter [TYPE]    Filter by resource type. If TYPE omitted, shows interactive menu"
    echo "  -k, --keyword KEYWORD  Filter by keyword (searches full statement text)"
    echo "  -o, --output FORMAT    Output format: pretty, json, csv (default: pretty)"
    echo "  -c, --compartments     Also show compartment tree"
    echo "  -p, --parallel N       Max parallel requests (default: 15)"
    echo "  -s, --short            Truncate long statements (default: show full)"
    echo "  -r, --refresh          Force refresh cache (bypass cached data)"
    echo "  --cache-dir DIR        Cache directory (default: ~/.cache/oci-policy-audit)"
    echo "  --cache-ttl SECS       Cache TTL in seconds (default: 3600 = 1 hour)"
    echo "  --no-cache             Disable caching entirely"
    echo "  --cache-info           Show cache status and exit"
    echo "  --clear-cache          Clear cache for this tenancy and exit"
    echo "  -h, --help             Show this help"
    echo ""
    echo "Cache:"
    echo "  Policies are cached locally to speed up subsequent runs."
    echo "  Cache location: \$HOME/.cache/oci-policy-audit/<tenancy-hash>/"
    echo "  Use -r/--refresh to force a fresh fetch from OCI API."
    echo ""
    echo "Variables file (variables.sh) can set:"
    echo "  TENANCY_OCID           Tenancy OCID"
    echo "  FILTER                 Default filter keyword"
    echo "  OUTPUT_FORMAT          pretty, json, or csv"
    echo "  MAX_PARALLEL           Max parallel requests"
    echo "  EXPAND_ALL             true or false"
    echo "  CONFIG_FILE            OCI config file path"
    echo "  CACHE_DIR              Cache directory"
    echo "  CACHE_TTL              Cache TTL in seconds"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Use cache if valid"
    echo "  $0 -r                                 # Force refresh from OCI"
    echo "  $0 --cache-ttl 7200                   # 2 hour cache TTL"
    echo "  $0 --no-cache                         # Skip cache entirely"
    echo "  $0 --cache-info                       # Show cache status"
    echo "  $0 -f                                 # Interactive filter menu"
    echo "  $0 -f cluster-family                  # Filter by resource type"
    echo "  $0 -f compute                         # Find compute resource policies"
    echo "  $0 -k dynamic-group                   # Keyword search in statements"
    echo "  $0 -o json > policies.json            # Export to JSON"
    echo ""
    echo "Filter types (interactive -f menu):"
    echo "  1) OCI Service   - Searches resource type after manage/use/read/inspect"
    echo "  2) Compartment   - Shows policies in matching compartment"
    echo "  3) Policy Name   - Matches policy name"
    echo "  4) Custom Keyword - Searches full statement text"
    echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--tenancy)
            TENANCY_OCID="$2"
            shift 2
            ;;
        -C|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -v|--vars)
            if [[ -f "$2" ]]; then
                source "$2"
                VARS_LOADED="$2"
            else
                echo "Warning: Variables file not found: $2" >&2
            fi
            shift 2
            ;;
        -f|--filter)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                # Direct filter argument - use resource-type (service) filter
                FILTER="__SERVICE__:$2"
                shift 2
            else
                # Interactive mode - will be handled after fetching policies
                FILTER="__INTERACTIVE__"
                shift
            fi
            ;;
        -k|--keyword)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                # Keyword filter - searches full statement text
                FILTER="$2"
                shift 2
            else
                echo "Error: -k/--keyword requires an argument" >&2
                exit 1
            fi
            ;;
        -o|--output)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -c|--compartments)
            SHOW_COMPARTMENT_TREE=true
            shift
            ;;
        -p|--parallel)
            MAX_PARALLEL="$2"
            shift 2
            ;;
        -s|--short)
            EXPAND_ALL=false
            shift
            ;;
        -r|--refresh)
            REFRESH_CACHE=true
            shift
            ;;
        --cache-dir)
            CACHE_DIR="$2"
            shift 2
            ;;
        --cache-ttl)
            CACHE_TTL="$2"
            shift 2
            ;;
        --no-cache)
            CACHE_TTL=0
            shift
            ;;
        --cache-info)
            SHOW_CACHE_INFO=true
            shift
            ;;
        --clear-cache)
            CLEAR_CACHE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Get tenancy OCID from config if not provided
if [[ -z "$TENANCY_OCID" ]]; then
    # Check if using instance principal
    if [[ "$OCI_CLI_AUTH" == "instance_principal" ]]; then
        echo -e "${DIM}Detected instance principal auth${NC}" >&2
        # Get tenancy from instance metadata
        TENANCY_OCID=$(curl -s -H "Authorization: Bearer Oracle" \
            http://169.254.169.254/opc/v2/instance/ 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('compartmentId',''))" 2>/dev/null)
        
        # If compartment is not tenancy, try to get tenancy from it
        if [[ "$TENANCY_OCID" == ocid1.compartment.* ]]; then
            echo -e "${DIM}Instance is in a compartment, fetching tenancy...${NC}" >&2
            TENANCY_OCID=$(oci iam compartment get --compartment-id "$TENANCY_OCID" \
                --query "data.\"compartment-id\"" --raw-output 2>/dev/null)
            # Keep going up until we hit tenancy
            while [[ "$TENANCY_OCID" == ocid1.compartment.* ]]; do
                TENANCY_OCID=$(oci iam compartment get --compartment-id "$TENANCY_OCID" \
                    --query "data.\"compartment-id\"" --raw-output 2>/dev/null)
            done
        fi
    else
        # Check if config file was specified
        if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
            OCI_CONFIG="$CONFIG_FILE"
        else
            # Check multiple possible config locations
            OCI_CONFIG=""
            for config_path in \
                "$OCI_CLI_CONFIG_FILE" \
                "$HOME/.oci/config" \
                "/etc/oci/config" \
                "$HOME/.config/oci/config" \
                "/home/$(whoami)/.oci/config" \
                "/root/.oci/config"; do
                if [[ -f "$config_path" ]]; then
                    OCI_CONFIG="$config_path"
                    break
                fi
            done
        fi
        
        if [[ -n "$OCI_CONFIG" ]]; then
            TENANCY_OCID=$(grep "^tenancy" "$OCI_CONFIG" | head -1 | cut -d= -f2 | tr -d ' ')
            echo -e "${DIM}Using config: $OCI_CONFIG${NC}" >&2
        fi
    fi
fi

if [[ -z "$TENANCY_OCID" ]]; then
    echo -e "${RED}Error: Could not determine tenancy OCID${NC}"
    echo "Provide with -t option or ensure ~/.oci/config is configured"
    exit 1
fi

# Verify OCI CLI works
if ! command -v oci &>/dev/null; then
    echo -e "${RED}Error: OCI CLI not installed${NC}"
    exit 1
fi

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}" >&2
echo -e "${CYAN}${BOLD}              OCI Policy Audit Report${NC}" >&2
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}" >&2
echo "" >&2

# Get tenancy name
echo -e "${DIM}Fetching tenancy info...${NC}" >&2
TENANCY_NAME=$(oci iam tenancy get --tenancy-id "$TENANCY_OCID" --query "data.name" --raw-output 2>/dev/null || echo "Unknown")
echo -e "Tenancy: ${GREEN}$TENANCY_NAME${NC}" >&2
echo -e "OCID: ${DIM}${TENANCY_OCID:0:50}...${NC}" >&2
if [[ "$FILTER" == "__INTERACTIVE__" ]]; then
    echo -e "Filter: ${CYAN}(interactive selection after scan)${NC}" >&2
elif [[ -n "$FILTER" ]]; then
    if [[ "$FILTER" == __SERVICE__:* ]]; then
        echo -e "Filter: resource-type contains '${YELLOW}${FILTER#__SERVICE__:}${NC}'" >&2
    elif [[ "$FILTER" == __COMPARTMENT__:* ]]; then
        echo -e "Filter: compartment '${YELLOW}${FILTER#__COMPARTMENT__:}${NC}'" >&2
    elif [[ "$FILTER" == __POLICY__:* ]]; then
        echo -e "Filter: policy name '${YELLOW}${FILTER#__POLICY__:}${NC}'" >&2
    else
        echo -e "Filter: keyword '${YELLOW}$FILTER${NC}'" >&2
    fi
fi
[[ -n "$VARS_LOADED" ]] && echo -e "Variables: ${DIM}$VARS_LOADED${NC}" >&2
echo "" >&2

# Show compartment tree if requested
if [[ "$SHOW_COMPARTMENT_TREE" == true ]]; then
    echo -e "${BOLD}Compartment Hierarchy:${NC}" >&2
    echo -e "${DIM}Fetching compartments...${NC}" >&2
    
    oci iam compartment list \
        --compartment-id "$TENANCY_OCID" \
        --compartment-id-in-subtree true \
        --all \
        --output json 2>/dev/null | python3 -c "
import sys, json

raw = json.load(sys.stdin)
data = [c for c in raw.get('data', []) if c.get('lifecycle-state') == 'ACTIVE']
compartments = {c['id']: c for c in data}

# Add root
root_id = '$TENANCY_OCID'

def get_depth(comp_id, depth=0):
    if comp_id == root_id or comp_id not in compartments:
        return depth
    parent = compartments[comp_id].get('compartment-id', root_id)
    return get_depth(parent, depth + 1)

# Sort by depth then name
sorted_comps = sorted(data, key=lambda c: (get_depth(c['id']), c.get('name', '')))

print(f'  (root) $TENANCY_NAME')
for c in sorted_comps:
    depth = get_depth(c['id'])
    indent = '  ' * (depth + 1)
    name = c.get('name', 'Unknown')
    print(f'{indent}├── {name}')
" >&2
    echo "" >&2
fi

# ============================================================================
# CACHING LOGIC
# ============================================================================

# Create cache directory
TENANCY_HASH=$(echo "$TENANCY_OCID" | md5sum | cut -c1-12)
TENANCY_CACHE_DIR="$CACHE_DIR/$TENANCY_HASH"
CACHE_POLICIES_FILE="$TENANCY_CACHE_DIR/policies.json"
CACHE_COMPARTMENTS_FILE="$TENANCY_CACHE_DIR/compartments.json"
CACHE_META_FILE="$TENANCY_CACHE_DIR/metadata.json"

# Function to check if cache is valid
cache_is_valid() {
    # If cache TTL is 0, caching is disabled
    [[ "$CACHE_TTL" -eq 0 ]] && return 1
    
    # If refresh requested, cache is invalid
    [[ "$REFRESH_CACHE" == "true" ]] && return 1
    
    # Check if cache files exist
    [[ ! -f "$CACHE_POLICIES_FILE" ]] && return 1
    [[ ! -f "$CACHE_COMPARTMENTS_FILE" ]] && return 1
    [[ ! -f "$CACHE_META_FILE" ]] && return 1
    
    # Check cache age
    local cache_time
    cache_time=$(python3 -c "
import json
try:
    with open('$CACHE_META_FILE') as f:
        meta = json.load(f)
    print(meta.get('timestamp', 0))
except:
    print(0)
" 2>/dev/null)
    
    local current_time
    current_time=$(date +%s)
    local cache_age=$((current_time - cache_time))
    
    [[ $cache_age -lt $CACHE_TTL ]] && return 0
    return 1
}

# Function to get cache info
get_cache_info() {
    if [[ ! -f "$CACHE_META_FILE" ]]; then
        echo "No cache found for this tenancy"
        return 1
    fi
    
    python3 -c "
import json
from datetime import datetime

try:
    with open('$CACHE_META_FILE') as f:
        meta = json.load(f)
    
    ts = meta.get('timestamp', 0)
    cache_time = datetime.fromtimestamp(ts)
    age_secs = int($(date +%s)) - ts
    
    if age_secs < 60:
        age_str = f'{age_secs} seconds'
    elif age_secs < 3600:
        age_str = f'{age_secs // 60} minutes'
    elif age_secs < 86400:
        age_str = f'{age_secs // 3600} hours, {(age_secs % 3600) // 60} minutes'
    else:
        age_str = f'{age_secs // 86400} days, {(age_secs % 86400) // 3600} hours'
    
    print(f\"Cache Directory: $TENANCY_CACHE_DIR\")
    print(f\"Tenancy: {meta.get('tenancy_name', 'Unknown')}\")
    print(f\"OCID: {meta.get('tenancy_ocid', 'Unknown')[:50]}...\")
    print(f\"Cached at: {cache_time.strftime('%Y-%m-%d %H:%M:%S')}\")
    print(f\"Cache age: {age_str}\")
    print(f\"TTL: $CACHE_TTL seconds\")
    
    ttl_remaining = $CACHE_TTL - age_secs
    if ttl_remaining > 0:
        print(f\"Status: \033[0;32mVALID\033[0m (expires in {ttl_remaining // 60} minutes)\")
    else:
        print(f\"Status: \033[0;33mEXPIRED\033[0m ({abs(ttl_remaining) // 60} minutes ago)\")
    
    print(f\"Policies: {meta.get('policy_count', 'Unknown')}\")
    print(f\"Compartments: {meta.get('compartment_count', 'Unknown')}\")
except Exception as e:
    print(f'Error reading cache: {e}')
" 2>/dev/null
}

# Function to save to cache
save_to_cache() {
    local policies_json="$1"
    local compartments_json="$2"
    local policy_count="$3"
    local comp_count="$4"
    
    mkdir -p "$TENANCY_CACHE_DIR"
    
    echo "$policies_json" > "$CACHE_POLICIES_FILE"
    echo "$compartments_json" > "$CACHE_COMPARTMENTS_FILE"
    
    python3 -c "
import json
meta = {
    'timestamp': $(date +%s),
    'tenancy_ocid': '$TENANCY_OCID',
    'tenancy_name': '$TENANCY_NAME',
    'policy_count': $policy_count,
    'compartment_count': $comp_count,
    'cache_ttl': $CACHE_TTL
}
with open('$CACHE_META_FILE', 'w') as f:
    json.dump(meta, f, indent=2)
" 2>/dev/null
    
    echo -e "${DIM}Cache saved to: $TENANCY_CACHE_DIR${NC}" >&2
}

# Handle --cache-info flag
if [[ "${SHOW_CACHE_INFO:-false}" == "true" ]]; then
    echo -e "${BOLD}Cache Information${NC}"
    echo "─────────────────────────────────────────"
    get_cache_info
    echo ""
    echo -e "${DIM}Cache files:${NC}"
    if [[ -d "$TENANCY_CACHE_DIR" ]]; then
        ls -lh "$TENANCY_CACHE_DIR" 2>/dev/null | tail -n +2
    else
        echo "  (no cache directory)"
    fi
    exit 0
fi

# Handle --clear-cache flag
if [[ "${CLEAR_CACHE:-false}" == "true" ]]; then
    if [[ -d "$TENANCY_CACHE_DIR" ]]; then
        echo -e "Clearing cache for tenancy: ${YELLOW}$TENANCY_OCID${NC}"
        rm -rf "$TENANCY_CACHE_DIR"
        echo -e "${GREEN}✓${NC} Cache cleared"
    else
        echo -e "${DIM}No cache found for this tenancy${NC}"
    fi
    exit 0
fi

# Check cache status and decide whether to fetch or load from cache
USE_CACHE=false
if cache_is_valid; then
    USE_CACHE=true
    echo -e "${GREEN}✓${NC} Using cached data (age: $(python3 -c "
import json
with open('$CACHE_META_FILE') as f:
    meta = json.load(f)
age = $(date +%s) - meta.get('timestamp', 0)
if age < 60:
    print(f'{age}s')
elif age < 3600:
    print(f'{age // 60}m')
else:
    print(f'{age // 3600}h {(age % 3600) // 60}m')
" 2>/dev/null))" >&2
    echo -e "${DIM}Use -r/--refresh to force refresh${NC}" >&2
else
    if [[ "$REFRESH_CACHE" == "true" ]]; then
        echo -e "${YELLOW}↻${NC} Refreshing cache..." >&2
    elif [[ "$CACHE_TTL" -eq 0 ]]; then
        echo -e "${DIM}Caching disabled${NC}" >&2
    else
        echo -e "${DIM}Cache miss or expired, fetching fresh data...${NC}" >&2
    fi
fi
echo "" >&2

if [[ "$USE_CACHE" == "true" ]]; then
    # Load from cache
    COMPARTMENTS_JSON=$(cat "$CACHE_COMPARTMENTS_FILE")
    ALL_POLICIES=$(cat "$CACHE_POLICIES_FILE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(json.dumps(data.get('data', data)))
" 2>/dev/null)
    POLICIES_JSON="{\"data\": $ALL_POLICIES}"
else
    # Fetch fresh data from OCI
    # Fetch all policies by iterating through compartments
    echo -e "${DIM}Fetching policies from all compartments...${NC}" >&2

    # First get compartment list (filter in Python to avoid JMESPath issues)
    COMPARTMENTS_JSON=$(oci iam compartment list \
        --compartment-id "$TENANCY_OCID" \
        --compartment-id-in-subtree true \
        --all \
        --output json 2>/dev/null)

    # Check if we got compartments
    if [[ -z "$COMPARTMENTS_JSON" ]]; then
        echo -e "${RED}Error: Failed to fetch compartments${NC}" >&2
        exit 1
    fi

    # Build list of compartment IDs (including root/tenancy)
    COMP_IDS=$(echo "$COMPARTMENTS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Include tenancy as root compartment
print('$TENANCY_OCID')
for c in data.get('data', []):
    if c.get('lifecycle-state') == 'ACTIVE':
        print(c.get('id', ''))
" 2>/dev/null)

    # Check if we got any compartments
    if [[ -z "$COMP_IDS" ]]; then
        echo -e "${RED}Error: No compartments found${NC}" >&2
        exit 1
    fi

    TOTAL_COMPS=$(echo "$COMP_IDS" | wc -l)

    # Use temp directory for parallel fetching
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    echo -e "${DIM}Scanning $TOTAL_COMPS compartments (up to ${MAX_PARALLEL} parallel)...${NC}" >&2

    # Fetch policies in parallel using background jobs
    COMP_NUM=0
    RUNNING=0

    for comp_id in $COMP_IDS; do
        COMP_NUM=$((COMP_NUM + 1))
        
        # Start background job
        (oci iam policy list --compartment-id "$comp_id" --all --output json 2>/dev/null > "$TEMP_DIR/pol_${COMP_NUM}.json") &
        RUNNING=$((RUNNING + 1))
        
        # Limit parallel jobs
        if [[ $RUNNING -ge $MAX_PARALLEL ]]; then
            wait -n 2>/dev/null || wait
            RUNNING=$((RUNNING - 1))
        fi
        
        # Progress update every 10 compartments
        if [[ $((COMP_NUM % 10)) -eq 0 ]]; then
            DONE=$(ls -1 "$TEMP_DIR"/pol_*.json 2>/dev/null | wc -l)
            printf "\r${DIM}Scanning: %d/%d compartments...${NC}   " "$DONE" "$TOTAL_COMPS" >&2
        fi
    done

    # Wait for remaining jobs
    wait
    echo "" >&2

    # Merge all policy files
    echo -e "${DIM}Merging results...${NC}" >&2
    ALL_POLICIES=$(python3 -c "
import json
import os

all_policies = []
temp_dir = '$TEMP_DIR'
for fname in os.listdir(temp_dir):
    if fname.startswith('pol_') and fname.endswith('.json'):
        try:
            with open(os.path.join(temp_dir, fname)) as f:
                data = json.load(f)
                all_policies.extend(data.get('data', []))
        except:
            pass

print(json.dumps(all_policies))
" 2>/dev/null)

    # Check if we got any policies
    if [[ -z "$ALL_POLICIES" ]] || [[ "$ALL_POLICIES" == "[]" ]]; then
        echo -e "${YELLOW}Warning: No policies found in any compartment${NC}" >&2
    fi

    POLICIES_JSON="{\"data\": $ALL_POLICIES}"
    
    # Save to cache if caching is enabled
    if [[ "$CACHE_TTL" -gt 0 ]]; then
        POLICY_COUNT=$(echo "$ALL_POLICIES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
        COMP_COUNT=$(echo "$COMPARTMENTS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo 0)
        save_to_cache "$POLICIES_JSON" "$COMPARTMENTS_JSON" "$POLICY_COUNT" "$COMP_COUNT"
    fi
fi

# Handle interactive filter selection
INTERACTIVE_MODE=false
if [[ "$FILTER" == "__INTERACTIVE__" ]]; then
    INTERACTIVE_MODE=true
fi

while true; do
    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        echo "" >&2
        echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}" >&2
        echo -e "${BOLD}                    Filter Selection${NC}" >&2
        echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}" >&2
        echo "" >&2
        echo -e "${BOLD}Filter by:${NC}" >&2
        echo -e "  ${CYAN}1)${NC} OCI Service (resource type)" >&2
        echo -e "  ${CYAN}2)${NC} Compartment" >&2
        echo -e "  ${CYAN}3)${NC} Policy Name" >&2
        echo -e "  ${CYAN}4)${NC} Custom Keyword" >&2
        echo -e "  ${CYAN}0)${NC} Show All (no filter)" >&2
        echo -e "  ${CYAN}q)${NC} Quit" >&2
        echo "" >&2
        read -p "Select filter type (0-4, q to quit): " FILTER_TYPE
        
        # Quit on q/Q
        if [[ "${FILTER_TYPE,,}" == "q" ]]; then
            echo -e "${DIM}Exiting...${NC}" >&2
            exit 0
        fi
        
        case "$FILTER_TYPE" in
            1)
                # Filter by OCI Service - comprehensive list from OCI CLI
                echo "" >&2
                echo -e "${BOLD}OCI Services (from oci cli):${NC}" >&2
                echo "" >&2
                echo -e "${YELLOW}Analytics & AI${NC}" >&2
                echo -e "  ai                  ai-document           ai-vision             analytics" >&2
                echo -e "  bds                 data-catalog          data-flow             data-integration" >&2
                echo -e "  data-labeling       data-science          generative-ai         generative-ai-inference" >&2
                echo -e "  generative-ai-agent oda                   speech                streaming" >&2
                echo "" >&2
                echo -e "${YELLOW}Billing & Cost Management${NC}" >&2
                echo -e "  budgets             onesubscription       usage                 usage-api" >&2
                echo "" >&2
                echo -e "${YELLOW}Compute${NC}" >&2
                echo -e "  autoscaling         compute               compute-management    instance-family" >&2
                echo "" >&2
                echo -e "${YELLOW}Databases${NC}" >&2
                echo -e "  database-management db                    mysql                 nosql" >&2
                echo -e "  autonomous-database data-safe             goldengate            psql" >&2
                echo "" >&2
                echo -e "${YELLOW}Developer Services${NC}" >&2
                echo -e "  adm                 api-gateway           artifacts             blockchain" >&2
                echo -e "  ce                  dbtools               devops                email" >&2
                echo -e "  fn                  oce                   resource-manager      visual-builder" >&2
                echo "" >&2
                echo -e "${YELLOW}Governance & Administration${NC}" >&2
                echo -e "  announce            capacity-management   limits                organizations" >&2
                echo -e "  support             work-requests" >&2
                echo "" >&2
                echo -e "${YELLOW}Identity & Security${NC}" >&2
                echo -e "  audit               bastion               certificates          cloud-guard" >&2
                echo -e "  iam                 identity-domains      vault                 kms" >&2
                echo -e "  waf                 zpr                   security-attribute    threat-intelligence" >&2
                echo "" >&2
                echo -e "${YELLOW}Networking${NC}" >&2
                echo -e "  dns                 lb                    network               network-firewall" >&2
                echo -e "  nlb                 virtual-network       vcn                   drg" >&2
                echo "" >&2
                echo -e "${YELLOW}Observability & Management${NC}" >&2
                echo -e "  apm-config          apm-control-plane     apm-synthetics        apm-traces" >&2
                echo -e "  events              health-checks         kms                   log-analytics" >&2
                echo -e "  logging             monitoring            ons                   sch" >&2
                echo -e "  stack-monitoring" >&2
                echo "" >&2
                echo -e "${YELLOW}Storage${NC}" >&2
                echo -e "  bv                  fs                    lfs                   os" >&2
                echo -e "  object-family       volume-family         file-family" >&2
                echo "" >&2
                echo -e "${YELLOW}Others${NC}" >&2
                echo -e "  container-instances disaster-recovery     fleet-apps-management integration" >&2
                echo -e "  marketplace         media-services        opensearch            queue" >&2
                echo -e "  redis               secrets" >&2
                echo "" >&2
                echo -e "${YELLOW}Resource Families (for policies)${NC}" >&2
                echo -e "  all-resources              cluster-family            database-family" >&2
                echo -e "  instance-family            object-family             virtual-network-family" >&2
                echo -e "  generative-ai-family       functions-family          vault-family" >&2
                echo "" >&2
                read -p "Type service/resource name (or Enter to go back): " SVC_INPUT
                if [[ -z "$SVC_INPUT" ]]; then
                    continue  # Go back to main menu
                fi
                FILTER="__SERVICE__:$SVC_INPUT"
                echo -e "Filtering by resource type: ${YELLOW}$SVC_INPUT${NC}" >&2
                ;;
        
        2)
            # Filter by Compartment
            echo "" >&2
            echo -e "${BOLD}Compartments with policies:${NC}" >&2
            echo "" >&2
            
            COMP_LIST=$(echo "$POLICIES_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
comps_raw = '''$COMPARTMENTS_JSON'''
import json as j
comps = j.loads(comps_raw)

# Build comp name and parent lookup
comp_names = {'$TENANCY_OCID': '(root)'}
comp_parents = {'$TENANCY_OCID': None}
for c in comps.get('data', comps) if isinstance(comps, dict) else comps:
    cid = c.get('id', '')
    comp_names[cid] = c.get('name', 'Unknown')
    comp_parents[cid] = c.get('compartment-id', '$TENANCY_OCID')

# Build compartment path
def get_comp_path(cid, max_depth=4):
    path = []
    current = cid
    while current and len(path) < max_depth:
        name = comp_names.get(current, '')
        if name:
            path.insert(0, name)
        current = comp_parents.get(current)
    if len(path) > 3:
        return path[0] + '/.../' + '/'.join(path[-2:])
    return '/'.join(path)

# Count policies per compartment (using path for display, name for filter)
comp_counts = {}
comp_paths = {}
for p in data.get('data', []):
    cid = p.get('compartment-id', '')
    cname = comp_names.get(cid, cid[:30])
    cpath = get_comp_path(cid)
    if cname not in comp_counts:
        comp_counts[cname] = 0
        comp_paths[cname] = cpath
    comp_counts[cname] += 1

# Print sorted by path
items = [(name, count, comp_paths.get(name, name)) for name, count in comp_counts.items()]
items.sort(key=lambda x: x[2])
for i, (name, count, path) in enumerate(items, 1):
    print(f'{i}|{name}|{count}|{path}')
" 2>/dev/null)
            
            echo "$COMP_LIST" | while IFS='|' read -r num name count path; do
                printf "  ${GREEN}%3d)${NC} %-40s ${DIM}[%d policies]${NC}\n" "$num" "$path" "$count" >&2
            done
            
            echo "" >&2
            read -p "Select number or type name (or Enter to go back): " COMP_SELECT
            
            if [[ -z "$COMP_SELECT" ]]; then
                continue  # Go back to main menu
            elif [[ "$COMP_SELECT" =~ ^[0-9]+$ ]]; then
                SELECTED_COMP=$(echo "$COMP_LIST" | sed -n "${COMP_SELECT}p" | cut -d'|' -f2)
                if [[ -n "$SELECTED_COMP" ]]; then
                    FILTER="__COMPARTMENT__:$SELECTED_COMP"
                    echo -e "Filtering by compartment: ${YELLOW}$SELECTED_COMP${NC}" >&2
                fi
            else
                # Allow typing a compartment name directly
                FILTER="__COMPARTMENT__:$COMP_SELECT"
                echo -e "Filtering by compartment: ${YELLOW}$COMP_SELECT${NC}" >&2
            fi
            ;;
        
        3)
            # Filter by Policy Name
            echo "" >&2
            echo -e "${BOLD}Policies:${NC}" >&2
            
            POLICY_LIST=$(echo "$POLICIES_JSON" | python3 -c "
import sys, json

data = json.load(sys.stdin)
comps_raw = '''$COMPARTMENTS_JSON'''
import json as j
comps = j.loads(comps_raw)

# Build compartment lookup
comp_names = {'$TENANCY_OCID': '(root)'}
comp_parents = {'$TENANCY_OCID': None}
for c in comps.get('data', comps) if isinstance(comps, dict) else comps:
    cid = c.get('id', '')
    comp_names[cid] = c.get('name', 'Unknown')
    comp_parents[cid] = c.get('compartment-id', '$TENANCY_OCID')

# Build compartment path
def get_comp_path(cid, max_depth=4):
    path = []
    current = cid
    while current and len(path) < max_depth:
        name = comp_names.get(current, '')
        if name:
            path.insert(0, name)
        current = comp_parents.get(current)
    if len(path) > 3:
        return path[0] + '/.../' + '/'.join(path[-2:])
    return '/'.join(path)

policies = data.get('data', [])
seen = {}
for p in policies:
    name = p.get('name', 'Unknown')
    cid = p.get('compartment-id', '$TENANCY_OCID')
    comp_path = get_comp_path(cid)
    stmt_count = len(p.get('statements', []))
    if name not in seen:
        seen[name] = (stmt_count, comp_path)

for i, (name, (count, path)) in enumerate(sorted(seen.items()), 1):
    print(f'{i}|{name}|{count}|{path}')
" 2>/dev/null)
            
            echo "$POLICY_LIST" | while IFS='|' read -r num name count path; do
                printf "  ${GREEN}%3d)${NC} %-35s ${DIM}[%d stmts]${NC} ${BLUE}%s${NC}\n" "$num" "$name" "$count" "$path" >&2
            done
            
            echo "" >&2
            read -p "Select number or type name (or Enter to go back): " POL_SELECT
            
            if [[ -z "$POL_SELECT" ]]; then
                continue  # Go back to main menu
            elif [[ "$POL_SELECT" =~ ^[0-9]+$ ]]; then
                SELECTED_POL=$(echo "$POLICY_LIST" | sed -n "${POL_SELECT}p" | cut -d'|' -f2)
                if [[ -n "$SELECTED_POL" ]]; then
                    FILTER="__POLICY__:$SELECTED_POL"
                    echo -e "Filtering by policy: ${YELLOW}$SELECTED_POL${NC}" >&2
                fi
            else
                # Allow typing a policy name directly
                FILTER="__POLICY__:$POL_SELECT"
                echo -e "Filtering by policy: ${YELLOW}$POL_SELECT${NC}" >&2
            fi
            ;;
        
        4)
            # Custom keyword
            echo "" >&2
            read -p "Enter keyword to filter (or Enter to go back): " CUSTOM_KW
            if [[ -z "$CUSTOM_KW" ]]; then
                continue  # Go back to main menu
            fi
            FILTER="$CUSTOM_KW"
            echo -e "Filtering by keyword: ${YELLOW}$FILTER${NC}" >&2
            ;;
        
        0)
            FILTER=""
            echo -e "${DIM}Showing all policies${NC}" >&2
            ;;
        
        *)
            # Invalid or empty - go back to menu
            continue
            ;;
    esac
    echo "" >&2
    fi  # end of INTERACTIVE_MODE check

# Process and display
case $OUTPUT_FORMAT in
    json)
        if [[ -n "$FILTER" ]]; then
            echo "$POLICIES_JSON" | python3 -c "
import sys, json, re

filter_raw = '${FILTER}'
filter_type = 'keyword'
filter_value = filter_raw.lower()

if filter_raw.startswith('__COMPARTMENT__:'):
    filter_type = 'compartment'
    filter_value = filter_raw[16:].lower()
elif filter_raw.startswith('__POLICY__:'):
    filter_type = 'policy'
    filter_value = filter_raw[11:].lower()
elif filter_raw.startswith('__SERVICE__:'):
    filter_type = 'service'
    filter_value = filter_raw[12:].lower()

# Handle regex patterns
filter_patterns = []
if '\\\\|' in filter_value or '|' in filter_value:
    filter_patterns = [p.strip() for p in filter_value.replace('\\\\|', '|').split('|')]
else:
    filter_patterns = [filter_value] if filter_value else []

def matches(text, patterns):
    text_lower = text.lower()
    return any(p in text_lower for p in patterns) if patterns else True

def extract_resource_type(statement):
    pattern = r'\b(?:manage|use|read|inspect)\s+([a-zA-Z][a-zA-Z0-9_-]*(?:-[a-zA-Z0-9_]+)*)'
    match = re.search(pattern, statement, re.IGNORECASE)
    return match.group(1).lower() if match else ''

def matches_service(statement, patterns):
    if not patterns:
        return True
    resource_type = extract_resource_type(statement)
    return any(p in resource_type for p in patterns) if resource_type else False

data = json.load(sys.stdin)
filtered = []
for p in data.get('data', []):
    if filter_type == 'policy':
        if not matches(p.get('name', ''), filter_patterns):
            continue
        filtered.append(p)
    elif filter_type == 'compartment':
        # Note: compartment filtering requires compartment names lookup
        # For JSON output, we'll include policies that match the compartment-id prefix
        filtered.append(p)
    elif filter_type == 'service':
        matching = [s for s in p.get('statements', []) if matches_service(s, filter_patterns)]
        if matching:
            p['statements'] = matching
            filtered.append(p)
    else:
        matching = [s for s in p.get('statements', []) if matches(s, filter_patterns)]
        if matching:
            p['statements'] = matching
            filtered.append(p)
print(json.dumps(filtered, indent=2))
"
        else
            echo "$POLICIES_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(json.dumps(data.get('data', []), indent=2))
"
        fi
        ;;
    
    csv)
        echo "policy_name,compartment_id,statement"
        echo "$POLICIES_JSON" | python3 -c "
import sys, json, csv, re

filter_raw = '${FILTER}'
filter_type = 'keyword'
filter_value = filter_raw.lower() if filter_raw else ''

if filter_raw.startswith('__COMPARTMENT__:'):
    filter_type = 'compartment'
    filter_value = filter_raw[16:].lower()
elif filter_raw.startswith('__POLICY__:'):
    filter_type = 'policy'
    filter_value = filter_raw[11:].lower()
elif filter_raw.startswith('__SERVICE__:'):
    filter_type = 'service'
    filter_value = filter_raw[12:].lower()

def extract_resource_type(statement):
    pattern = r'\b(?:manage|use|read|inspect)\s+([a-zA-Z][a-zA-Z0-9_-]*(?:-[a-zA-Z0-9_]+)*)'
    match = re.search(pattern, statement, re.IGNORECASE)
    return match.group(1).lower() if match else ''

data = json.load(sys.stdin)
writer = csv.writer(sys.stdout)

for p in data.get('data', []):
    name = p.get('name', '')
    comp = p.get('compartment-id', '')
    for s in p.get('statements', []):
        include = False
        if not filter_value:
            include = True
        elif filter_type == 'policy':
            include = filter_value in name.lower()
        elif filter_type == 'service':
            resource = extract_resource_type(s)
            include = filter_value in resource if resource else False
        else:
            include = filter_value in s.lower()
        if include:
            writer.writerow([name, comp, s])
"
        ;;
    
    pretty|*)
        # Write JSON to temp files to avoid heredoc escaping issues
        TEMP_POL=$(mktemp)
        TEMP_CMP=$(mktemp)
        echo "$POLICIES_JSON" > "$TEMP_POL"
        echo "$COMPARTMENTS_JSON" > "$TEMP_CMP"
        
        python3 - "$TEMP_POL" "$TEMP_CMP" "$TENANCY_OCID" "$FILTER" "$TENANCY_NAME" "$EXPAND_ALL" << 'PYEOF'
import json
import sys
import re
from collections import defaultdict

pol_file = sys.argv[1]
cmp_file = sys.argv[2]
tenancy_ocid = sys.argv[3]
filter_raw = sys.argv[4] if len(sys.argv) > 4 else ''
tenancy_name = sys.argv[5] if len(sys.argv) > 5 else 'Root'
expand_all = sys.argv[6].lower() == 'true' if len(sys.argv) > 6 else True

# Parse filter type
filter_type = 'keyword'  # default: search in statements
filter_value = filter_raw.lower() if filter_raw else ''

if filter_raw.startswith('__COMPARTMENT__:'):
    filter_type = 'compartment'
    filter_value = filter_raw[16:].lower()  # Remove prefix
elif filter_raw.startswith('__POLICY__:'):
    filter_type = 'policy'
    filter_value = filter_raw[11:].lower()  # Remove prefix
elif filter_raw.startswith('__SERVICE__:'):
    filter_type = 'service'
    filter_value = filter_raw[12:].lower()  # Remove prefix

# Handle regex patterns (from service filter with \|)
filter_patterns = []
if '\\|' in filter_value:
    filter_patterns = [p.strip() for p in filter_value.replace('\\|', '|').split('|')]
else:
    filter_patterns = [filter_value] if filter_value else []

def matches_filter(text, patterns):
    """Check if text matches any of the filter patterns"""
    if not patterns:
        return True
    text_lower = text.lower()
    return any(p in text_lower for p in patterns)

def extract_resource_type(statement):
    """Extract the resource type from a policy statement.
    Policy format: Allow <subject> to <verb> <resource-type> in <location>
    Returns the resource-type portion."""
    import re
    # Pattern to match: verb followed by resource type
    # Verbs: manage, use, read, inspect
    pattern = r'\b(?:manage|use|read|inspect)\s+([a-zA-Z][a-zA-Z0-9_-]*(?:-[a-zA-Z0-9_]+)*)'
    match = re.search(pattern, statement, re.IGNORECASE)
    if match:
        return match.group(1).lower()
    return ''

def matches_service_filter(statement, patterns):
    """Check if statement's resource type contains any of the filter patterns.
    Simple substring matching on the resource-type field.
    
    Examples:
      -f compute     -> matches compute-management-family, compute-capacity-reservations
      -f cluster     -> matches cluster-family, cluster-node-pools
      -f instance-family -> matches instance-family
    """
    if not patterns:
        return True
    resource_type = extract_resource_type(statement)
    if not resource_type:
        return False
    
    # Simple substring matching on resource-type
    return any(p in resource_type for p in patterns)

with open(pol_file) as f:
    policies = json.load(f)
with open(cmp_file) as f:
    compartments_raw = json.load(f)

# ANSI colors
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
CYAN = '\033[0;36m'
MAGENTA = '\033[0;35m'
BOLD = '\033[1m'
DIM = '\033[2m'
NC = '\033[0m'
RED = '\033[0;31m'
BLUE = '\033[0;34m'

# Build compartment data structures
comp_list = compartments_raw.get('data', compartments_raw) if isinstance(compartments_raw, dict) else compartments_raw

# Map: id -> compartment info
compartments = {tenancy_ocid: {'name': tenancy_name, 'id': tenancy_ocid, 'parent': None}}
for c in comp_list:
    cid = c.get('id', '')
    compartments[cid] = {
        'name': c.get('name', 'Unknown'),
        'id': cid,
        'parent': c.get('compartment-id', tenancy_ocid)
    }

# Build children map
children = defaultdict(list)
for cid, comp in compartments.items():
    parent = comp.get('parent')
    if parent and parent != cid:
        children[parent].append(cid)

# Sort children alphabetically
for parent_id in children:
    children[parent_id].sort(key=lambda x: compartments.get(x, {}).get('name', '').lower())

# Count descendants for each compartment
def count_descendants(comp_id):
    """Count all descendant compartments recursively"""
    count = len(children.get(comp_id, []))
    for child_id in children.get(comp_id, []):
        count += count_descendants(child_id)
    return count

descendant_counts = {cid: count_descendants(cid) for cid in compartments}

# Group policies by compartment
policies_by_comp = defaultdict(list)
for p in policies.get('data', []):
    comp_id = p.get('compartment-id', tenancy_ocid)
    policies_by_comp[comp_id].append(p)

# Count total policies in branch (compartment + all descendants)
def count_branch_policies(comp_id):
    """Count policies in this compartment and all descendants"""
    count = len(policies_by_comp.get(comp_id, []))
    for child_id in children.get(comp_id, []):
        count += count_branch_policies(child_id)
    return count

branch_policy_counts = {cid: count_branch_policies(cid) for cid in compartments}

# Stats
total_policies = 0
total_statements = 0
matching_policies = 0
matching_statements = 0

# Build list of compartment names for highlighting
comp_names_list = [c.get('name', '') for c in compartments.values() if c.get('name')]

def format_statement(s, prefix_len=0, highlight_keyword=None):
    """Highlight keywords in statement and handle wrapping"""
    import re
    display = s
    
    # Colors
    ORANGE = '\033[38;5;208m'  # True orange (256-color)
    BOLD_BLUE = '\033[1;34m'
    BG_YELLOW = '\033[43;30m'  # Yellow background, black text for search highlight
    
    # 1. Highlight "Deny" keyword in RED (rare but critical)
    display = re.sub(r'\b(Deny)\b', f'{RED}\\1{NC}', display, flags=re.IGNORECASE)
    
    # 2. Highlight "Allow" keyword in GREEN
    display = re.sub(r'\b(Allow)\b', f'{GREEN}\\1{NC}', display, flags=re.IGNORECASE)
    
    # 3. Highlight "Allow service <service_name>" - service name in RED
    # Pattern: "service <name>" where name can contain dots, underscores, hyphens
    service_pattern = r'\b(service\s+)([a-zA-Z][a-zA-Z0-9._-]*)\b'
    def service_replacer(m):
        prefix = m.group(1)
        svc_name = m.group(2)
        return f'{prefix}{RED}{svc_name}{NC}'
    display = re.sub(service_pattern, service_replacer, display, flags=re.IGNORECASE)
    
    # 4. Highlight any-user in ORANGE (security risk - broad access)
    display = re.sub(r'\bany-user\b', f'{ORANGE}any-user{NC}', display, flags=re.IGNORECASE)
    
    # 5. Highlight verbs in YELLOW
    for kw in ['manage', 'use', 'read', 'inspect']:
        pattern = rf'\b{kw}\b'
        if re.search(pattern, display, re.IGNORECASE):
            display = re.sub(pattern, f'{YELLOW}{kw}{NC}', display, flags=re.IGNORECASE)
    
    # 6. Highlight OCI resource types in CYAN
    # Comprehensive list from OCI documentation
    oci_services = [
        # Resource families (most common in policies)
        'all-resources',
        'cluster-family', 'instance-family', 'volume-family', 'object-family',
        'virtual-network-family', 'database-family', 'file-family', 'dns-family',
        'load-balancers', 'network-load-balancers',
        
        # AI & Analytics
        'generative-ai-family', 'generative-ai-inference-family', 'generative-ai-agent-family',
        'generative-ai', 'ai-service-family', 'data-science-family',
        'ai-language-family', 'ai-vision-family', 'ai-document-family', 'ai-speech-family',
        'analytics-family', 'big-data-service-family', 'data-catalog-family',
        'data-flow-family', 'data-integration-family', 'streaming-family',
        
        # Compute
        'compute-management-family', 'auto-scaling-configurations',
        'instance-configurations', 'instance-pools', 'instance-images',
        'dedicated-vm-hosts', 'compute-capacity-reservations',
        
        # Containers & Kubernetes  
        'cluster-node-pools', 'cluster-workload-mappings',
        'container-instances', 'container-repos',
        
        # Database
        'autonomous-database-family', 'db-systems', 'db-nodes', 'db-homes',
        'databases', 'backups', 'mysql-family', 'nosql-family', 'psql-family',
        'data-safe-family', 'goldengate-family',
        
        # Developer
        'devops-family', 'repos', 'build-pipelines', 'deploy-pipelines',
        'api-gateway-family', 'functions-family', 'fn-function', 'fn-app',
        'artifacts', 'container-images', 'generic-artifacts',
        'resource-manager-family', 'stacks', 'jobs',
        
        # Identity & Security
        'authentication-policies', 'credentials', 'compartments',
        'dynamic-groups', 'groups', 'identity-providers', 'policies',
        'tag-namespaces', 'tag-defaults', 'users', 'network-sources',
        'vault-family', 'vaults', 'keys', 'secrets', 'key-family', 'secret-family',
        'cloud-guard-family', 'bastion-family', 'bastions', 'sessions',
        'waf-family', 'web-app-firewalls', 'waf-policies',
        'security-zone-family', 'security-zones', 'security-recipes',
        
        # Networking
        'vcns', 'subnets', 'route-tables', 'security-lists', 'network-security-groups',
        'internet-gateways', 'nat-gateways', 'service-gateways', 'local-peering-gateways',
        'drgs', 'drg-attachments', 'cpes', 'ipsec-connections',
        'cross-connects', 'virtual-circuits', 'vlans', 'vnic-attachments',
        'private-ips', 'public-ips', 'byoip-ranges',
        'dns-zones', 'dns-records', 'dns-steering-policies',
        'load-balancer-family', 'network-load-balancer-family',
        'network-firewall-family', 'network-firewalls', 'network-firewall-policies',
        
        # Storage
        'buckets', 'objects', 'objectstorage-namespaces', 'preauthenticated-requests',
        'volumes', 'volume-attachments', 'volume-backups', 'boot-volumes',
        'boot-volume-backups', 'volume-groups', 'volume-group-backups',
        'file-systems', 'mount-targets', 'export-sets',
        'lustre-file-systems',
        
        # Observability & Management
        'logging-family', 'log-groups', 'logs', 'log-content',
        'metrics', 'alarms', 'monitoring-family',
        'events-family', 'rules',
        'ons-family', 'ons-topics', 'ons-subscriptions',
        'apm-domains', 'apm-config-family',
        'log-analytics-family', 'log-analytics-entities',
        'management-agents', 'management-agent-install-keys',
        'stack-monitoring-family',
        'connector-hub-family', 'service-connectors',
        
        # Other services
        'oke', 'kubernetes', 'email-family', 'approved-senders', 'suppressions',
        'marketplace-listings', 'announcements', 'limits', 'usage-reports',
        'audit-events', 'work-requests', 'tenancies',
    ]
    
    # Sort by length descending to match longer patterns first 
    # (e.g., 'generative-ai-family' before 'generative-ai')
    oci_services_sorted = sorted(oci_services, key=len, reverse=True)
    
    for svc in oci_services_sorted:
        # Use negative lookbehind/lookahead for hyphens to avoid matching
        # partial words like 'oke' in 'oke-gpu-yyazlk'
        pattern = rf'(?<!-)\b{re.escape(svc)}\b(?!-)'
        if re.search(pattern, display, re.IGNORECASE):
            display = re.sub(pattern, f'{CYAN}{svc}{NC}', display, flags=re.IGNORECASE)
    
    # 7. Catch-all: Color any resource name after verbs that wasn't already colored
    # Pattern: after "manage|use|read|inspect " followed by word with hyphens (resource names)
    # Only if not already colored (check for \033 escape sequence)
    # Need to escape ANSI codes since they contain regex special chars like [
    yellow_esc = re.escape(YELLOW)
    nc_esc = re.escape(NC)
    verb_resource_pattern = rf'({yellow_esc}(?:manage|use|read|inspect){nc_esc}\s+)([a-zA-Z][a-zA-Z0-9-]*(?:-[a-zA-Z0-9]+)*)'
    def verb_resource_replacer(m):
        verb_part = m.group(1)
        resource = m.group(2)
        # Don't re-color if already has escape codes
        if '\033[' in resource:
            return m.group(0)
        return f'{verb_part}{CYAN}{resource}{NC}'
    display = re.sub(verb_resource_pattern, verb_resource_replacer, display)
    
    # 8. Highlight dynamic-group keyword in MAGENTA
    display = re.sub(r'\b(dynamic-group)\b', f'{MAGENTA}\\1{NC}', display, flags=re.IGNORECASE)
    
    # 9. Highlight standalone "group" keyword (not part of "dynamic-group" or "any-group")
    # Use negative lookbehind to avoid matching the "group" in "dynamic-group" or "any-group"
    display = re.sub(r'(?<!dynamic-)(?<!any-)(\bgroup\b)', f'{MAGENTA}\\1{NC}', display, flags=re.IGNORECASE)
    
    # 10. Highlight any-group in ORANGE (security risk - broad access)
    # Done after group coloring to ensure it stays orange, not magenta
    display = re.sub(r'\bany-group\b', f'{ORANGE}any-group{NC}', display, flags=re.IGNORECASE)
    
    # 11. Highlight compartment references in BOLD BLUE
    
    # Match compartment OCID pattern (anywhere in statement)
    ocid_pattern = r'(ocid1\.compartment\.[a-zA-Z0-9._-]+)'
    display = re.sub(ocid_pattern, rf'{BOLD_BLUE}\1{NC}', display)
    
    # Match "in compartment <name>" - handles various formats:
    # - in compartment MyComp
    # - in compartment 'My Comp'
    # - in compartment Parent:Child
    # - in compartment Parent:Child:GrandChild
    comp_name_pattern = r'(in\s+compartment\s+)(?!id\b)([\'"]?)([a-zA-Z0-9_:/-]+)([\'"]?)'
    def comp_replacer(m):
        prefix = m.group(1)
        quote1 = m.group(2)
        name = m.group(3)
        quote2 = m.group(4)
        return f'{prefix}{quote1}{BOLD_BLUE}{name}{NC}{quote2}'
    display = re.sub(comp_name_pattern, comp_replacer, display, flags=re.IGNORECASE)
    
    # Also highlight "in tenancy" 
    display = re.sub(r'\b(in\s+)(tenancy)\b', rf'\1{BOLD_BLUE}\2{NC}', display, flags=re.IGNORECASE)
    
    # 12. Highlight "where" keyword in CYAN (conditions are important)
    display = re.sub(r'\b(where)\b', f'{CYAN}\\1{NC}', display, flags=re.IGNORECASE)
    
    # 13. Dim structural keyword "to" (reduce noise, let important parts stand out)
    # Match " to " with spaces to avoid matching "to" inside other words
    display = re.sub(r'(\s)(to)(\s)', rf'\1{DIM}\2{NC}\3', display, flags=re.IGNORECASE)
    
    # 14. Highlight the search keyword if provided (do this last to make it stand out)
    if highlight_keyword:
        # Case-insensitive highlight with background color
        pattern = re.compile(re.escape(highlight_keyword), re.IGNORECASE)
        display = pattern.sub(f'{BG_YELLOW}\\g<0>{NC}', display)
    
    return display

def print_compartment(comp_id, prefix="", is_last=True, depth=0):
    """Recursively print compartment tree with policies"""
    global total_policies, total_statements, matching_policies, matching_statements
    
    comp = compartments.get(comp_id, {})
    comp_name = comp.get('name', 'Unknown')
    
    # Tree branch characters
    branch = "└── " if is_last else "├── "
    child_prefix = prefix + ("    " if is_last else "│   ")
    
    # Check if this compartment matches the filter (for compartment filter type)
    comp_matches_filter = True
    if filter_type == 'compartment' and filter_patterns:
        comp_matches_filter = matches_filter(comp_name, filter_patterns)
        
        # If this compartment doesn't match, check if any descendant matches
        if not comp_matches_filter:
            def has_matching_descendant(cid):
                c = compartments.get(cid, {})
                if matches_filter(c.get('name', ''), filter_patterns):
                    return True
                for child in children.get(cid, []):
                    if has_matching_descendant(child):
                        return True
                return False
            if not has_matching_descendant(comp_id):
                return  # No matching descendants, skip entirely
    
    # Get policies for this compartment
    comp_policies = policies_by_comp.get(comp_id, [])
    
    # Filter policies based on filter type
    filtered_policies = []
    
    # For compartment filter, only show policies if THIS compartment matches
    if filter_type == 'compartment' and filter_patterns and not comp_matches_filter:
        # Don't show policies from non-matching compartments
        pass
    else:
        for p in comp_policies:
            total_policies += 1
            policy_name = p.get('name', 'Unknown')
            
            # Check policy name filter
            if filter_type == 'policy' and filter_patterns:
                if not matches_filter(policy_name, filter_patterns):
                    continue
            
            policy_stmts = []
            for s in p.get('statements', []):
                total_statements += 1
                
                # Check statement filter based on filter type
                if filter_type == 'keyword' and filter_patterns:
                    if matches_filter(s, filter_patterns):
                        matching_statements += 1
                        policy_stmts.append(s)
                elif filter_type == 'service' and filter_patterns:
                    if matches_service_filter(s, filter_patterns):
                        matching_statements += 1
                        policy_stmts.append(s)
                else:
                    # For compartment/policy filters, include all statements
                    matching_statements += 1
                    policy_stmts.append(s)
            
            if policy_stmts or (filter_type not in ['keyword', 'service'] and not filter_patterns):
                if policy_stmts:
                    matching_policies += 1
                filtered_policies.append((policy_name, policy_stmts, p.get('statements', [])))
    
    # Get children
    child_comps = children.get(comp_id, [])
    
    # Skip if no policies and no children with policies (when filtering)
    has_content = bool(filtered_policies) or any(
        policies_by_comp.get(c) or children.get(c) for c in child_comps
    )
    
    if filter_patterns and not has_content and depth > 0:
        # Check recursively if any descendant has matching content
        def has_descendant_match(cid):
            # Check compartment name match
            if filter_type == 'compartment':
                c = compartments.get(cid, {})
                if matches_filter(c.get('name', ''), filter_patterns):
                    return True
            
            # Check policies
            for p in policies_by_comp.get(cid, []):
                if filter_type == 'policy':
                    if matches_filter(p.get('name', ''), filter_patterns):
                        return True
                elif filter_type == 'keyword':
                    for s in p.get('statements', []):
                        if matches_filter(s, filter_patterns):
                            return True
                elif filter_type == 'service':
                    for s in p.get('statements', []):
                        if matches_service_filter(s, filter_patterns):
                            return True
            
            # Check children
            for child in children.get(cid, []):
                if has_descendant_match(child):
                    return True
            return False
        
        if not has_descendant_match(comp_id):
            return
    
    # Print compartment header
    if depth == 0:
        # Root compartment
        policy_count = len(filtered_policies)
        child_count = len(children.get(comp_id, []))
        desc_count = descendant_counts.get(comp_id, 0)
        branch_policies = branch_policy_counts.get(comp_id, 0)
        
        print(f"\n{BOLD}{BLUE}🏢 {comp_name}{NC} (root tenancy)")
        info_parts = []
        if policy_count > 0:
            if branch_policies > policy_count:
                info_parts.append(f"{policy_count} policies here, {branch_policies} total in tree")
            else:
                info_parts.append(f"{policy_count} policies")
        elif branch_policies > 0:
            info_parts.append(f"{branch_policies} policies in tree")
        if child_count > 0:
            if desc_count > child_count:
                info_parts.append(f"{child_count} direct sub-compartments ({desc_count} total nested)")
            else:
                info_parts.append(f"{child_count} sub-compartments")
        if info_parts:
            print(f"{DIM}   {', '.join(info_parts)}{NC}")
    else:
        policy_count = len(filtered_policies)
        child_count = len(children.get(comp_id, []))
        desc_count = descendant_counts.get(comp_id, 0)
        branch_policies = branch_policy_counts.get(comp_id, 0)
        
        # Build info string
        info_parts = []
        if policy_count > 0:
            if branch_policies > policy_count:
                info_parts.append(f"{policy_count} policies, {branch_policies} in branch")
            else:
                info_parts.append(f"{policy_count} policies")
        elif branch_policies > 0:
            info_parts.append(f"{branch_policies} in branch")
        if child_count > 0:
            if desc_count > child_count:
                info_parts.append(f"{child_count} sub ({desc_count} nested)")
            else:
                info_parts.append(f"{child_count} sub")
        
        info_str = f" {DIM}({', '.join(info_parts)}){NC}" if info_parts else ""
        print(f"{prefix}{branch}{BLUE}📁 {comp_name}{NC}{info_str}")
    
    # Print policies for this compartment
    policy_prefix = child_prefix if depth > 0 else "   "
    for i, (pol_name, matched_stmts, all_stmts) in enumerate(filtered_policies):
        is_last_policy = (i == len(filtered_policies) - 1) and not child_comps
        pol_branch = "└── " if is_last_policy else "├── "
        stmt_prefix = policy_prefix + ("    " if is_last_policy else "│   ")
        
        stmt_count = len(all_stmts)
        match_info = ""
        if filter_type in ['keyword', 'service'] and filter_patterns and matched_stmts:
            match_info = f" {GREEN}({len(matched_stmts)} match){NC}"
        
        print(f"{policy_prefix}{pol_branch}{GREEN}📜 {pol_name}{NC} {DIM}[{stmt_count} statements]{NC}{match_info}")
        
        # Print statements
        # For keyword and service filters, show only matched statements
        if filter_type in ['keyword', 'service'] and filter_patterns:
            stmts_to_show = matched_stmts
        else:
            stmts_to_show = all_stmts
        
        # Determine what keyword to highlight
        highlight = filter_value if filter_type in ['keyword', 'service'] and filter_patterns else None
        
        for j, stmt in enumerate(stmts_to_show):
            is_last_stmt = (j == len(stmts_to_show) - 1)
            stmt_branch = "└─ " if is_last_stmt else "├─ "
            
            # Format statement (truncate only if not expanding)
            if not expand_all and len(stmt) > 100:
                formatted = format_statement(stmt[:97] + "...", highlight_keyword=highlight)
            else:
                formatted = format_statement(stmt, highlight_keyword=highlight)
            
            print(f"{stmt_prefix}{stmt_branch}{formatted}")
    
    # Print child compartments
    for i, child_id in enumerate(child_comps):
        is_last_child = (i == len(child_comps) - 1)
        print_compartment(child_id, child_prefix if depth > 0 else "   ", is_last_child, depth + 1)

# Print the tree starting from root
print(f"\n{BOLD}{'═' * 70}{NC}")
print(f"{BOLD}  Compartment & Policy Hierarchy{NC}")
print(f"{BOLD}{'═' * 70}{NC}")

print_compartment(tenancy_ocid, depth=0)

# Summary
print(f"\n{BOLD}{'─' * 70}{NC}")
print(f"{BOLD}Summary{NC}")
print(f"{'─' * 70}")

if filter_patterns:
    filter_display = filter_value
    if filter_type == 'compartment':
        filter_display = f"compartment: {filter_value}"
    elif filter_type == 'policy':
        filter_display = f"policy: {filter_value}"
    elif filter_type == 'service':
        filter_display = f"resource-type contains: {filter_value}"
    elif filter_type == 'keyword':
        filter_display = f"keyword: {filter_value}"
    print(f"  Filter: '{YELLOW}{filter_display}{NC}'")
    print(f"  Matching: {GREEN}{matching_policies}{NC} policies, {GREEN}{matching_statements}{NC} statements")
    print(f"  Total scanned: {total_policies} policies, {total_statements} statements")
else:
    print(f"  Total: {GREEN}{total_policies}{NC} policies with {GREEN}{total_statements}{NC} statements")

# Analysis - only show when no filter is applied
if not filter_patterns:
    print(f"\n{BOLD}Policy Analysis{NC}")
    print(f"{'─' * 70}")
    
    # Admin policies
    admin_statements = []
    for p in policies.get('data', []):
        for s in p.get('statements', []):
            if 'manage all-resources' in s.lower():
                admin_statements.append((p.get('name'), s))
    
    if admin_statements:
        print(f"  {YELLOW}⚠{NC}  {len(admin_statements)} statements grant '{YELLOW}manage all-resources{NC}' (full admin)")
        for pol_name, stmt in admin_statements[:5]:
            print(f"      {DIM}└─ {pol_name}{NC}")
        if len(admin_statements) > 5:
            print(f"      {DIM}   ... and {len(admin_statements) - 5} more{NC}")
    
    # Dynamic group policies
    dg_statements = []
    for p in policies.get('data', []):
        for s in p.get('statements', []):
            if 'dynamic-group' in s.lower():
                dg_statements.append((p.get('name'), s))
    
    if dg_statements:
        print(f"  {GREEN}✓{NC}  {len(dg_statements)} statements use {MAGENTA}dynamic groups{NC}")
    
    # Compartment stats
    comps_with_policies = len([c for c in policies_by_comp if policies_by_comp[c]])
    comps_with_children = len([c for c in children if children[c]])
    max_depth = 0
    
    def get_depth(comp_id, current_depth=0):
        global max_depth
        max_depth = max(max_depth, current_depth)
        for child in children.get(comp_id, []):
            get_depth(child, current_depth + 1)
    
    get_depth(tenancy_ocid)
    
    print(f"\n  📊 Compartment Statistics:")
    print(f"      Total compartments: {len(compartments)}")
    print(f"      With policies: {comps_with_policies}")
    print(f"      With sub-compartments: {comps_with_children}")
    print(f"      Max nesting depth: {max_depth}")
    
    # Top compartments by policy count
    if policies_by_comp:
        print(f"\n  📋 Top Compartments by Policy Count:")
        sorted_comps = sorted(
            [(cid, len(pols)) for cid, pols in policies_by_comp.items() if pols],
            key=lambda x: -x[1]
        )[:5]
        for cid, count in sorted_comps:
            name = compartments.get(cid, {}).get('name', 'Unknown')
            print(f"      {count:3d} policies: {name}")

PYEOF
        rm -f "$TEMP_POL" "$TEMP_CMP"
        ;;
esac

echo "" >&2
echo -e "${DIM}Audit complete.${NC}" >&2

# If not in interactive mode, exit the loop
if [[ "$INTERACTIVE_MODE" != "true" ]]; then
    break
fi

# Prompt to continue or quit
echo "" >&2
read -p "Press Enter for new search, or 'q' to quit: " CONTINUE_CHOICE
if [[ "${CONTINUE_CHOICE,,}" == "q" ]]; then
    echo -e "${DIM}Exiting...${NC}" >&2
    break
fi

done  # end of while true loop