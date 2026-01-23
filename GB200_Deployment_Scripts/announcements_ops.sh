#!/bin/bash

# Script to list and manage GPU-related announcements
# Author: Tim's GPU Infrastructure Tools
# Date: $(date +%Y-%m-%d)

set -euo pipefail

# Trap to show where script exits on error
trap 'echo "[TRAP] Script exited at line $LINENO with exit code $?" >&2' ERR

# Parse command line arguments
DEBUG=false
SHOW_HELP=false

for arg in "$@"; do
    case $arg in
        --debug)
            DEBUG=true
            ;;
        --help|-h)
            SHOW_HELP=true
            ;;
        *)
            ;;
    esac
done

# Show help if requested
if [[ "$SHOW_HELP" == "true" ]]; then
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  --debug         Enable debug output
  --help, -h      Show this help message

Description:
  Lists GPU-related announcements from OCI and allows interactive acknowledgment.

Commands (interactive mode):
  [number]        View announcement details
  ack [nums]      Acknowledge announcement(s) (e.g., ack 5, ack 1-10, ack 1,3,5-7)
  q               Quit

EOF
    exit 0
fi

# Debug output function
debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

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
ANNOUNCEMENTS_LIST="cache/announcements_list.json"
ANNOUNCEMENTS_DETAILS_DIR="cache"
ANNOUNCEMENTS_SUMMARY="announcements_summary.txt"
ACKNOWLEDGED_FILE="acknowledged_announcements.txt"
ACK_STATUS_CACHE="cache/ack_status_cache.json"
CACHE_MAX_AGE=14400  # 4 hours in seconds

# Function to check if cache is valid (not expired)
is_cache_valid() {
    if [[ ! -f "$ACK_STATUS_CACHE" ]]; then
        return 1  # Cache doesn't exist
    fi

    local cache_age=$(( $(date +%s) - $(stat -c %Y "$ACK_STATUS_CACHE" 2>/dev/null || echo 0) ))
    if [[ $cache_age -gt $CACHE_MAX_AGE ]]; then
        debug "Cache expired (age: ${cache_age}s, max: ${CACHE_MAX_AGE}s)"
        return 1  # Cache is too old
    fi

    debug "Cache is valid (age: ${cache_age}s)"
    return 0  # Cache is valid
}

# Function to get cached ack status
get_cached_ack_status() {
    local announcement_id="$1"

    # Check if cache is valid first
    if ! is_cache_valid; then
        debug "Cache invalid or expired, will query OCI"
        echo "UNCACHED"
        return
    fi

    if [[ -f "$ACK_STATUS_CACHE" ]]; then
        jq -r --arg id "$announcement_id" '.[$id] // "UNCACHED"' "$ACK_STATUS_CACHE" 2>/dev/null || echo "UNCACHED"
    else
        echo "UNCACHED"
    fi
}

# Function to cache ack status
cache_ack_status() {
    local announcement_id="$1"
    local ack_date="$2"

    # Create cache file if it doesn't exist
    if [[ ! -f "$ACK_STATUS_CACHE" ]]; then
        echo "{}" > "$ACK_STATUS_CACHE"
    fi

    # Update cache with new status
    local temp_file=$(mktemp)
    jq --arg id "$announcement_id" --arg date "$ack_date" '.[$id] = $date' "$ACK_STATUS_CACHE" > "$temp_file" 2>/dev/null
    mv "$temp_file" "$ACK_STATUS_CACHE"
}

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

# Function to check if announcement is acknowledged
is_acknowledged() {
    local announcement_id="$1"
    if [[ -f "$ACKNOWLEDGED_FILE" ]]; then
        grep -Fxq "$announcement_id" "$ACKNOWLEDGED_FILE"
        return $?
    fi
    return 1
}

# Function to expand number ranges and lists
# Examples: "1-5" -> "1 2 3 4 5", "1,3,5-7" -> "1 3 5 6 7"
expand_numbers() {
    local input="$1"
    local numbers=()

    # Split by comma
    IFS=',' read -ra parts <<< "$input"

    for part in "${parts[@]}"; do
        # Trim whitespace
        part=$(echo "$part" | xargs)

        # Check if it's a range (contains -)
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"

            # Swap if reversed
            if [[ $start -gt $end ]]; then
                temp=$start
                start=$end
                end=$temp
            fi

            # Generate range
            for ((i=start; i<=end; i++)); do
                numbers+=("$i")
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            # Single number
            numbers+=("$part")
        else
            print_error "Invalid number or range: $part"
            return 1
        fi
    done

    # Output unique sorted numbers
    printf '%s\n' "${numbers[@]}" | sort -n | uniq
}

# Function to mark announcement as acknowledged
mark_acknowledged() {
    local announcement_id="$1"
    if ! is_acknowledged "$announcement_id"; then
        echo "$announcement_id" >> "$ACKNOWLEDGED_FILE"
        debug "Marked announcement as acknowledged: $announcement_id"
    else
        debug "Announcement already acknowledged: $announcement_id"
    fi
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
if [[ "$DEBUG" == "true" ]]; then
    print_header "Fetching Announcement Details (Parallel)"
fi

fetch_announcement_detail() {
    local announcement_id="$1"
    local output_file="$ANNOUNCEMENTS_DETAILS_DIR/${announcement_id##*.}.json"

    # Skip if file already exists and is not empty
    if [[ -f "$output_file" && -s "$output_file" ]]; then
        if [[ "$DEBUG" == "true" ]]; then
            echo "⊙ $announcement_id (cached)"
        fi
        return 0
    fi

    if oci announce announcements get \
        --announcement-id "$announcement_id" > "$output_file" 2>/dev/null; then
        if [[ "$DEBUG" == "true" ]]; then
            echo "✓ $announcement_id"
        fi
    else
        if [[ "$DEBUG" == "true" ]]; then
            echo "✗ $announcement_id" >&2
        fi
        return 1
    fi
}

export -f fetch_announcement_detail
export ANNOUNCEMENTS_DETAILS_DIR
export DEBUG

# Use GNU parallel if available, otherwise use xargs
# IMPORTANT: Redirect stdin from /dev/null to prevent consuming stdin needed for interactive prompt
if command -v parallel &> /dev/null; then
    if [[ "$DEBUG" == "true" ]]; then
        print_status "Using GNU parallel for faster processing..."
        printf "%s\n" "${ANNOUNCEMENT_IDS_ARRAY[@]}" | \
            parallel -j 10 --progress fetch_announcement_detail < /dev/null
    else
        printf "%s\n" "${ANNOUNCEMENT_IDS_ARRAY[@]}" | \
            parallel -j 10 fetch_announcement_detail < /dev/null 2>&1
    fi
else
    if [[ "$DEBUG" == "true" ]]; then
        print_status "Using xargs for parallel processing..."
        printf "%s\n" "${ANNOUNCEMENT_IDS_ARRAY[@]}" | \
            xargs -P 10 -I {} bash -c 'fetch_announcement_detail "$@"' _ {} < /dev/null
    else
        printf "%s\n" "${ANNOUNCEMENT_IDS_ARRAY[@]}" | \
            xargs -P 10 -I {} bash -c 'fetch_announcement_detail "$@"' _ {} < /dev/null 2>&1
    fi
fi

if [[ "$DEBUG" == "true" ]]; then
    print_status "Details fetched and stored in $ANNOUNCEMENTS_DETAILS_DIR/"
fi

# Step 3: Generate summary table
print_header "GPU-Related Announcements Summary"

# Print column headers
printf "${WHITE}%-4s%-19s%-7s%-15s%-15s%-92s%-25s%-15s%-65s${NC}\n" \
    "No." "Type" "State" "Ref Ticket" "Created" "Resource ID" "Resource Name" "Ack" "Description"
echo -e "${CYAN}$(printf '%.0s─' {1..268})${NC}"

# Process and display announcements
declare -a DISPLAY_ANNOUNCEMENTS
index=1

for detail_file in "$ANNOUNCEMENTS_DETAILS_DIR"/*.json; do
    if [[ ! -f "$detail_file" ]]; then
        continue
    fi

    # Skip the announcements list file
    if [[ "$detail_file" == *"/announcements_list.json" ]]; then
        continue
    fi

    # Skip the ack status cache file
    if [[ "$detail_file" == *"/ack_status_cache.json" ]]; then
        continue
    fi

    # Validate this is an announcement detail file (must have .data.id)
    if ! jq -e '.data.id' "$detail_file" > /dev/null 2>&1; then
        debug "Skipping invalid announcement file: $detail_file"
        continue
    fi

    # Extract fields with fallbacks
    announcement_type=$(jq -r '.data."announcement-type" // "N/A"' "$detail_file")
    announcement_id=$(jq -r '.data.id // "N/A"' "$detail_file")
    lifecycle_state=$(jq -r '.data."lifecycle-state" // "N/A"' "$detail_file")
    affected_regions=$(jq -r '.data."affected-regions" // [] | join(", ")' "$detail_file")
    description=$(jq -r '.data.description // .data.summary // "N/A"' "$detail_file")
    reference_ticket=$(jq -r '.data."reference-ticket-number" // "N/A"' "$detail_file")
    time_created=$(jq -r '.data."time-created" // "N/A"' "$detail_file")

    # Convert time-created to MM/DD/YY HH:MM format
    if [[ "$time_created" != "N/A" ]]; then
        created_date=$(date -d "$time_created" +"%m/%d/%y %H:%M" 2>/dev/null || echo "N/A")
    else
        created_date="N/A"
    fi

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

    # Check acknowledgment status with caching
    ack_status="-"
    cached_status=$(get_cached_ack_status "$announcement_id")

    if [[ "$cached_status" == "UNCACHED" ]]; then
        # Not in cache, query OCI
        if [[ "$DEBUG" == "true" ]]; then
            debug "Checking OCI acknowledgment status for: $announcement_id"
        fi

        # Use subshell to prevent pipefail from killing the script if oci command fails
        time_acknowledged=$(
            oci announce user-status get \
                --announcement-id "$announcement_id" 2>/dev/null \
            | jq -r '.data."time-acknowledged" // "null"' 2>/dev/null
        ) || time_acknowledged="null"

        if [[ "$time_acknowledged" != "null" && -n "$time_acknowledged" ]]; then
            # Convert to MM/DD/YY HH:MM format
            ack_status=$(date -d "$time_acknowledged" +"%m/%d/%y %H:%M" 2>/dev/null || echo "Yes")
            if [[ "$DEBUG" == "true" ]]; then
                debug "  Acknowledged at: $time_acknowledged -> $ack_status"
            fi
        else
            ack_status="-"
        fi

        # Cache the result
        cache_ack_status "$announcement_id" "$ack_status"
        debug "Cached ack status for $announcement_id: $ack_status"
    else
        # Use cached value
        ack_status="$cached_status"
        if [[ "$DEBUG" == "true" ]]; then
            debug "Using cached ack status for $announcement_id: $ack_status"
        fi
    fi

    # Truncate for display
    short_reference_ticket="${reference_ticket:0:15}"
    full_resource_id="${resource_id}"
    short_resource_name="${resource_name:0:25}"
    short_description="${description:0:65}"

    # Determine colors based on lifecycle state
    case "$lifecycle_state" in
        ACTIVE)
            lifecycle_color=$RED
            ;;
        INACTIVE)
            lifecycle_color=$GREEN
            ;;
        *)
            lifecycle_color=$YELLOW
            ;;
    esac

    # Store for selection
    DISPLAY_ANNOUNCEMENTS[$index]="$detail_file"

    # Format index - just plain number with padding
    formatted_index=$(printf "%-4s" "$index")

    # Format lifecycle with color and padding
    lifecycle_padded=$(printf "%-7s" "$short_lifecycle")
    formatted_lifecycle="${lifecycle_color}${lifecycle_padded}${NC}"

    # Build the entire line
    line=$(printf "%-4s%-19s%-7s%-15s%-15s%-92s%-25s%-15s%-65s" \
        "PLACEHOLDER_IDX" \
        "$announcement_type" \
        "PLACEHOLDER_LCS" \
        "$short_reference_ticket" \
        "$created_date" \
        "$full_resource_id" \
        "$short_resource_name" \
        "$ack_status" \
        "$short_description")

    # Replace placeholders and echo with color interpretation
    line="${line/PLACEHOLDER_IDX/$formatted_index}"
    line="${line/PLACEHOLDER_LCS/$formatted_lifecycle}"
    echo -e "$line"

    index=$((index + 1))
done

echo ""
print_status "Total GPU-related announcements displayed: $((index - 1))"

# Extract USER_ID for acknowledgments from the announcements list
USER_ID=$(jq -r '.data."user-statuses"[0]."user-id" // empty' "$ANNOUNCEMENTS_LIST" 2>/dev/null) || USER_ID=""

# Step 4: Interactive selection
echo ""
print_header "Announcement Details"
echo -e "${CYAN}Commands:${NC}"
echo -e "  ${WHITE}[number]${NC}       - View announcement details"
echo -e "  ${WHITE}ack [nums]${NC}     - Mark announcement(s) as acknowledged"
echo -e "                   Examples: ack 5, ack 1-10, ack 1,3,5-7"
echo -e "  ${WHITE}q${NC}              - Quit"
echo ""

# Read from /dev/tty to ensure we get terminal input even if stdin was consumed
if ! read -rp $'\e[0;36mEnter command:\e[0m ' selection < /dev/tty 2>/dev/null; then
    # Fallback to regular stdin if /dev/tty fails
    if ! read -rp $'\e[0;36mEnter command:\e[0m ' selection; then
        print_error "No input received (stdin may have been consumed)"
        exit 1
    fi
fi

debug "Read selection: '$selection'"
debug "Length: ${#selection}"

if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
    print_status "Exiting..."
    exit 0
fi

debug "Checking if matches ack pattern..."

# Check for ack command with range support
if [[ "$selection" =~ ^ack[[:space:]]+(.+)$ ]]; then
    debug "Matched ack pattern!"
    ack_input="${BASH_REMATCH[1]}"
    debug "ack_input = '$ack_input'"

    # Create temporary file for batch processing
    temp_ack_file="cache/pending_acks_$$.txt"
    debug "temp_ack_file = '$temp_ack_file'"

    # Expand numbers into an array
    debug "Calling expand_numbers..."
    mapfile -t ack_nums_array < <(expand_numbers "$ack_input")
    debug "expand_numbers returned, array size = ${#ack_nums_array[@]}"
    debug "array contents = ${ack_nums_array[*]}"

    if [[ ${#ack_nums_array[@]} -eq 0 ]]; then
        print_error "Invalid number format: $ack_input"
        exit 1
    fi

    debug "Building batch file..."

    # Ensure cache directory exists
    mkdir -p cache

    # Build the batch file with announcement IDs
    ack_count=0
    debug "Starting for loop over array..."
    for ack_num in "${ack_nums_array[@]}"; do
        debug "Processing ack_num = '$ack_num'"
        [[ -z "$ack_num" ]] && continue

        debug "Validating selection (index=$index)..."
        # Validate selection
        if [[ $ack_num -lt 1 ]] || [[ $ack_num -ge $index ]]; then
            print_error "Invalid selection: $ack_num (valid range: 1-$((index-1)))"
            continue
        fi

        debug "Getting file from DISPLAY_ANNOUNCEMENTS[$ack_num]..."
        # Get the announcement ID from the detail file
        selected_file="${DISPLAY_ANNOUNCEMENTS[$ack_num]}"
        debug "selected_file = '$selected_file'"

        if [[ ! -f "$selected_file" ]]; then
            print_error "Announcement file not found for #$ack_num"
            continue
        fi

        debug "Extracting announcement ID from file..."
        ack_announcement_id=$(jq -r '.data.id' "$selected_file")
        debug "ack_announcement_id = '$ack_announcement_id'"

        debug "Writing to temp file..."
        echo "$ack_announcement_id" >> "$temp_ack_file"
        debug "Incrementing counter..."
        ack_count=$((ack_count + 1))
        debug "ack_count is now $ack_count"
        debug "Finished processing ack_num $ack_num"
    done

    debug "For loop complete, ack_count = $ack_count"

    debug "Checking if ack_count is 0..."

    if [[ $ack_count -eq 0 ]]; then
        print_error "No valid announcements to acknowledge"
        rm -f "$temp_ack_file"
        exit 1
    fi

    debug "Created batch file with $ack_count announcement(s) to acknowledge: $temp_ack_file"

    # Debug: Show what's in the batch file
    if [[ "$DEBUG" == "true" ]]; then
        echo ""
        print_status "Batch file contents:"
        cat "$temp_ack_file"
        echo ""
    fi

    # Process the batch file - acknowledge via OCI API
    print_header "Processing Acknowledgments"

    if [[ -z "$USER_ID" ]]; then
        print_error "Could not determine USER_ID from announcements. Cannot acknowledge via OCI API."
        print_status "Marking announcements as acknowledged locally only..."

        while IFS= read -r announcement_id; do
            [[ -z "$announcement_id" ]] && continue
            mark_acknowledged "$announcement_id"
        done < "$temp_ack_file"

        rm -f "$temp_ack_file"
        exit 1
    fi

    print_status "Acknowledging $ack_count announcement(s) via OCI API..."
    print_status "Using USER_ID: $USER_ID"

    if [[ "$DEBUG" == "false" ]]; then
        echo -n "Progress: "
    else
        echo ""
    fi

    success_count=0
    failed_count=0
    skipped_count=0
    processed=0
    while IFS= read -r announcement_id; do
        [[ -z "$announcement_id" ]] && continue

        processed=$((processed + 1))

        # Check if already acknowledged
        if is_acknowledged "$announcement_id"; then
            if [[ "$DEBUG" == "true" ]]; then
                print_status "Skipping (already acknowledged): $announcement_id"
            fi
            skipped_count=$((skipped_count + 1))
            if [[ "$DEBUG" == "false" ]]; then
                echo -n "○"
            fi
            continue
        fi

        if [[ "$DEBUG" == "true" ]]; then
            print_status "Acknowledging: $announcement_id"
        fi

        # Get current timestamp in ISO 8601 format
        timestamp=$(date +"%Y-%m-%dT%H:%M:%S%:z")

        # Show the command being executed (debug only)
        if [[ "$DEBUG" == "true" ]]; then
            echo "  Command: oci announce user-status update \\"
            echo "             --announcement-id $announcement_id \\"
            echo "             --user-status-announcement-id $announcement_id \\"
            echo "             --user-id $USER_ID \\"
            echo "             --time-acknowledged $timestamp"
        fi

        # Make OCI API call to acknowledge the announcement
        oci_output=$(oci announce user-status update \
            --announcement-id "$announcement_id" \
            --user-status-announcement-id "$announcement_id" \
            --user-id "$USER_ID" \
            --time-acknowledged "$timestamp" \
            2>&1)
        oci_exit_code=$?

        if [[ $oci_exit_code -eq 0 ]]; then
            # Convert timestamp to MM/DD/YY HH:MM for cache
            ack_date=$(date -d "$timestamp" +"%m/%d/%y %H:%M" 2>/dev/null || date +"%m/%d/%y %H:%M")

            mark_acknowledged "$announcement_id"
            cache_ack_status "$announcement_id" "$ack_date"

            success_count=$((success_count + 1))
            if [[ "$DEBUG" == "true" ]]; then
                echo "  ✓ Success"
                debug "Updated cache with ack date: $ack_date"
                echo ""
            else
                echo -n "✓"
            fi
        else
            if [[ "$DEBUG" == "true" ]]; then
                print_error "  ✗ Failed (exit code: $oci_exit_code)"
                echo "  Error output:"
                echo "$oci_output" | sed 's/^/    /' >&2
                echo ""
            else
                echo -n "✗"
            fi
            failed_count=$((failed_count + 1))
        fi
    done < "$temp_ack_file"

    # Add newline after progress bar in normal mode
    if [[ "$DEBUG" == "false" ]]; then
        echo ""
    fi

    # Clean up the batch file
    rm -f "$temp_ack_file"
    debug "Cleaned up batch file"

    echo ""
    if [[ $skipped_count -gt 0 ]]; then
        print_status "Acknowledgment complete: $success_count succeeded, $failed_count failed, $skipped_count skipped (already acknowledged)"
    else
        print_status "Acknowledgment complete: $success_count succeeded, $failed_count failed"
    fi
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

# Check acknowledgment status
ack_status="Not Acknowledged"
ack_color=$YELLOW
if is_acknowledged "$announcement_id"; then
    ack_status="✓ Acknowledged"
    ack_color=$GREEN
fi

# Print formatted details
echo ""
printf "${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Announcement Type:" "$announcement_type"
printf "${CYAN}%-20s${NC} ${WHITE}%s${NC}\n" "Announcement ID:" "$announcement_id"
printf "${CYAN}%-20s${NC} ${ack_color}%s${NC}\n" "Status:" "$ack_status"

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
