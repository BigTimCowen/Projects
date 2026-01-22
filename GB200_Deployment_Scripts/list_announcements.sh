#!/bin/bash

# Script to list and manage GPU-related announcements
# Author: Tim's GPU Infrastructure Tools
# Date: $(date +%Y-%m-%d)

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Output files
ANNOUNCEMENTS_LIST="announcements_list.json"
ANNOUNCEMENTS_DETAILS_DIR="cache"
ANNOUNCEMENTS_SUMMARY="announcements_summary.txt"

# Function to print colored header
print_header() {
    echo -e "${CYAN}========================================${NC}"
    echo -e "${WHITE}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

# Function to print status
print_status() {
    echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"
}

# Function to print error
print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to print warning
print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Initialize
echo -e "${BLUE}Listing Announcements at $(date)${NC}"
echo -e "${BLUE}Sourcing Variables from variables.sh${NC}"

if [[ ! -f "./variables.sh" ]]; then
    print_error "variables.sh not found in current directory"
    exit 1
fi

source ./variables.sh

if [[ -z "${COMPARTMENT_ID:-}" ]]; then
    print_error "COMPARTMENT_ID not set in variables.sh"
    exit 1
fi

# Create details directory
mkdir -p "$ANNOUNCEMENTS_DETAILS_DIR"

# Step 1: Fetch announcements list
print_header "Fetching Announcements List"
print_status "Querying OCI for announcements in compartment: $COMPARTMENT_ID"

if ! oci announce announcements list \
    --compartment-id "$COMPARTMENT_ID" \
    --all > "$ANNOUNCEMENTS_LIST" 2>/dev/null; then
    print_error "Failed to fetch announcements list"
    exit 1
fi

# Count announcements
TOTAL_ANNOUNCEMENTS=$(jq '.data.items | length' "$ANNOUNCEMENTS_LIST")
print_status "Found $TOTAL_ANNOUNCEMENTS total announcements"

# Filter GPU-related announcements
print_status "Filtering GPU-related announcements..."
GPU_ANNOUNCEMENT_IDS=$(jq -r '.data.items[] | 
    select(
        (."announcement-type" // "" | test("GPU|gpu|compute|instance|bare.*metal"; "i")) or
        (."resource-type" // "" | test("GPU|gpu|compute|instance"; "i")) or
        (.summary // "" | test("GPU|gpu|H100|A100|BM\\.GPU|Bare.*Metal"; "i")) or
        (.description // "" | test("GPU|gpu|H100|A100|BM\\.GPU"; "i")) or
        (."affected-regions" // [] | tostring | test("GPU|gpu|H100|A100"; "i")) or
        (.services // [] | tostring | test("Compute"; "i"))
    ) | .id' "$ANNOUNCEMENTS_LIST" 2>&1)

if [[ -z "$GPU_ANNOUNCEMENT_IDS" ]]; then
    print_warning "No GPU-related announcements found"
    
    # Debug: show available fields
    if [[ "${DEBUG:-0}" == "1" ]]; then
        print_status "Available announcement fields:"
        jq -r '.data.items[0] | keys[]' "$ANNOUNCEMENTS_LIST" 2>/dev/null | head -10
    fi
    
    echo -e "\n${YELLOW}Showing all announcements instead...${NC}\n"
    GPU_ANNOUNCEMENT_IDS=$(jq -r '.data.items[].id' "$ANNOUNCEMENTS_LIST")
fi

# Convert to array
mapfile -t ANNOUNCEMENT_IDS_ARRAY <<< "$GPU_ANNOUNCEMENT_IDS"
GPU_COUNT=${#ANNOUNCEMENT_IDS_ARRAY[@]}

print_status "Found $GPU_COUNT GPU-related announcements"

# Step 2: Fetch details in parallel
print_header "Fetching Announcement Details (Parallel)"

fetch_announcement_detail() {
    local announcement_id="$1"
    local output_file="$ANNOUNCEMENTS_DETAILS_DIR/${announcement_id##*.}.json"
    
    # Skip if file already exists and is not empty
    if [[ -f "$output_file" && -s "$output_file" ]]; then
        echo "⊙ $announcement_id (cached)"
        return 0
    fi
    
    if oci announce announcements get \
        --announcement-id "$announcement_id" > "$output_file" 2>/dev/null; then
        echo "✓ $announcement_id"
    else
        echo "✗ $announcement_id" >&2
        return 1
    fi
}

export -f fetch_announcement_detail
export ANNOUNCEMENTS_DETAILS_DIR

# Use GNU parallel if available, otherwise use xargs
if command -v parallel &> /dev/null; then
    print_status "Using GNU parallel for faster processing..."
    printf "%s\n" "${ANNOUNCEMENT_IDS_ARRAY[@]}" | \
        parallel -j 10 --progress fetch_announcement_detail
else
    print_status "Using xargs for parallel processing..."
    printf "%s\n" "${ANNOUNCEMENT_IDS_ARRAY[@]}" | \
        xargs -P 10 -I {} bash -c 'fetch_announcement_detail "$@"' _ {}
fi

print_status "Details fetched and stored in $ANNOUNCEMENTS_DETAILS_DIR/"

# Step 3: Generate summary table
print_header "GPU-Related Announcements Summary"

# Print column headers
printf "${WHITE}%-4s  %-20s  %-6s  %-95s  %-30s  %-100s${NC}\n" \
    "No." "Type" "State" "Resource ID" "Resource Name" "Description"
echo -e "${CYAN}$(printf '%.0s─' {1..265})${NC}"

# Process and display announcements
declare -a DISPLAY_ANNOUNCEMENTS
index=1

for detail_file in "$ANNOUNCEMENTS_DETAILS_DIR"/*.json; do
    if [[ ! -f "$detail_file" ]]; then
        continue
    fi
    
    # Extract fields with fallbacks
    announcement_type=$(jq -r '.data."announcement-type" // "N/A"' "$detail_file")
    announcement_id=$(jq -r '.data.id // "N/A"' "$detail_file")
    lifecycle_state=$(jq -r '.data."lifecycle-state" // "N/A"' "$detail_file")
    affected_regions=$(jq -r '.data."affected-regions" // [] | join(", ")' "$detail_file")
    description=$(jq -r '.data.description // .data.summary // "N/A"' "$detail_file")
    
    # Get first affected resource if available - try multiple methods
    # Method 1: Look for instance-id in affected-resources
    resource_id=$(jq -r '
        .data."affected-resources"[0]? // empty |
        if type == "object" then
            (.properties[]? | select(.name == "resourceId" or .name == "instanceId") | .value) // 
            (."resource-id"? // ."instance-id"? // "N/A")
        else
            "N/A"
        end
    ' "$detail_file" 2>/dev/null)
    
    # If still N/A, try to get from root level
    if [[ "$resource_id" == "N/A" || -z "$resource_id" ]]; then
        resource_id=$(jq -r '.data."resource-id" // .data."affected-resources"[0]."resource-id" // "N/A"' "$detail_file" 2>/dev/null)
    fi
    
    # Method 2: Look for resource name
    resource_name=$(jq -r '
        .data."affected-resources"[0]? // empty |
        if type == "object" then
            (.properties[]? | select(.name == "resourceName" or .name == "displayName") | .value) //
            (."resource-name"? // ."display-name"? // "N/A")
        else
            "N/A"
        end
    ' "$detail_file" 2>/dev/null)
    
    # If still N/A, try to get from root level
    if [[ "$resource_name" == "N/A" || -z "$resource_name" ]]; then
        resource_name=$(jq -r '.data."resource-name" // .data."affected-resources"[0]."resource-name" // "N/A"' "$detail_file" 2>/dev/null)
    fi
    
    # Truncate lifecycle state to 6 characters (ACTIVE becomes ACTIVE, INACTIVE becomes INACTV)
    short_lifecycle="${lifecycle_state:0:6}"
    
    # Truncate for display
    full_resource_id="${resource_id}"
    short_resource_name="${resource_name:0:30}"
    short_description="${description:0:100}"
    
    # Determine colors based on lifecycle state
    case "$lifecycle_state" in
        ACTIVE)
            color=$RED
            ;;
        INACTIVE)
            color=$GREEN
            ;;
        *)
            color=$YELLOW
            ;;
    esac
    
    # Store for selection
    DISPLAY_ANNOUNCEMENTS[$index]="$detail_file"
    
    # Print row with proper alignment - lifecycle is 6 chars with 2 spaces after
    printf "${color}%-4s${NC}  %-20s  ${color}%-6s${NC}  %-95s  %-30s  %-100s\n" \
        "$index" \
        "$announcement_type" \
        "$short_lifecycle" \
        "$full_resource_id" \
        "$short_resource_name" \
        "$short_description"
    
    ((index++))
done

echo ""
print_status "Total GPU-related announcements displayed: $((index - 1))"

# Step 4: Interactive selection
echo ""
print_header "Announcement Details"
echo -e "${CYAN}Enter announcement number for details (or 'q' to quit):${NC} "
read -r selection

if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
    print_status "Exiting..."
    exit 0
fi

# Validate selection
if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -ge $index ]]; then
    print_error "Invalid selection: $selection"
    exit 1
fi

# Get selected announcement file
selected_file="${DISPLAY_ANNOUNCEMENTS[$selection]}"

if [[ ! -f "$selected_file" ]]; then
    print_error "Announcement file not found: $selected_file"
    exit 1
fi

# Display detailed information
print_header "Detailed Information for Announcement #$selection"

announcement_type=$(jq -r '.data."announcement-type" // "N/A"' "$selected_file")
announcement_id=$(jq -r '.data.id // "N/A"' "$selected_file")
lifecycle_state=$(jq -r '.data."lifecycle-state" // "N/A"' "$selected_file")
summary=$(jq -r '.data.summary // "N/A"' "$selected_file")
description=$(jq -r '.data.description // "N/A"' "$selected_file")
time_one_value=$(jq -r '.data."time-one-value" // "N/A"' "$selected_file")
time_created=$(jq -r '.data."time-created" // "N/A"' "$selected_file")
time_updated=$(jq -r '.data."time-updated" // "N/A"' "$selected_file")
affected_regions=$(jq -r '.data."affected-regions" // [] | join(", ")' "$selected_file")

# Print formatted details
echo ""
printf "${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Announcement Type:" "$announcement_type"
printf "${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Announcement ID:" "$announcement_id"

case "$lifecycle_state" in
    ACTIVE)
        printf "${CYAN}%-20s${NC} ${RED}%s${NC}\n" "Lifecycle State:" "$lifecycle_state"
        ;;
    INACTIVE)
        printf "${CYAN}%-20s${NC} ${GREEN}%s${NC}\n" "Lifecycle State:" "$lifecycle_state"
        ;;
    *)
        printf "${CYAN}%-20s${NC} ${YELLOW}%s${NC}\n" "Lifecycle State:" "$lifecycle_state"
        ;;
esac

printf "${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Time One Value:" "$time_one_value"
printf "${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Time Created:" "$time_created"
printf "${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Time Updated:" "$time_updated"
printf "${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Affected Regions:" "$affected_regions"

echo ""
printf "${CYAN}%-20s${NC}\n" "Summary:"
echo -e "${WHITE}$summary${NC}"

echo ""
printf "${CYAN}%-20s${NC}\n" "Description:"
echo -e "${WHITE}$description${NC}"

# Display affected resources
echo ""
printf "${CYAN}%-20s${NC}\n" "Affected Resources:"
echo -e "${CYAN}$(printf '%.0s─' {1..100})${NC}"

resource_count=$(jq '.data."affected-resources" | length' "$selected_file")

if [[ $resource_count -gt 0 ]]; then
    for i in $(seq 0 $((resource_count - 1))); do
        echo -e "${YELLOW}Resource #$((i + 1)):${NC}"
        
        # Check if properties exist and are not null
        has_properties=$(jq -r ".data.\"affected-resources\"[$i].properties // null | type" "$selected_file")
        
        if [[ "$has_properties" == "array" ]]; then
            # Extract resource properties without color codes in jq
            jq -r ".data.\"affected-resources\"[$i].properties[] | 
                \"\\(.name): \\(.value)\"" "$selected_file" | while read -r line; do
                # Split on first colon
                prop_name="${line%%:*}"
                prop_value="${line#*: }"
                printf "  ${CYAN}%s:${NC} %s\n" "$prop_name" "$prop_value"
            done
        else
            # Try alternative structure - direct key-value pairs
            echo -e "  ${CYAN}Resource Type:${NC} $(jq -r ".data.\"affected-resources\"[$i].\"resource-type\" // \"N/A\"" "$selected_file")"
            echo -e "  ${CYAN}Resource ID:${NC} $(jq -r ".data.\"affected-resources\"[$i].\"resource-id\" // \"N/A\"" "$selected_file")"
            echo -e "  ${CYAN}Resource Name:${NC} $(jq -r ".data.\"affected-resources\"[$i].\"resource-name\" // \"N/A\"" "$selected_file")"
            
            # Show all available fields
            jq -r ".data.\"affected-resources\"[$i] | to_entries[] | 
                \"\\(.key): \\(.value)\"" "$selected_file" | while read -r line; do
                # Skip already displayed fields
                if [[ "$line" =~ ^(resource-type|resource-id|resource-name): ]]; then
                    continue
                fi
                prop_name="${line%%:*}"
                prop_value="${line#*: }"
                printf "  ${CYAN}%s:${NC} %s\n" "$prop_name" "$prop_value"
            done
        fi
        
        echo ""
    done
else
    echo -e "${YELLOW}No affected resources listed${NC}"
fi

echo ""
print_status "End of detailed information"