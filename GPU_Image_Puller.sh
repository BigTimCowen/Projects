#!/bin/bash
## v1.0.0
## This script is used to verify, upload and/or delete HPC Images from object storage buckets for specific months.  This has to be modified manually when new images are released.  You can also view all compartments in a tenancy.
## Run in the oci shell of the tenancy as an admin that can import images or delete images.
## This will default upload to the POC Compartment or it'll spit out a list of compartments with their ocid to select to upload images to.

COMP_OCID=
OS="Canonical Ubuntu"
image_type=1
image_name=""
os_ver=1
driver_ver=0
IMAGES=""
month_selected=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m' # No Color (reset)

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

what_image() {
                while true; do
                read -p "What Images do you need, Nvidia(1) or AMD(2)? [1]: " image_type
                image_type=${image_type:-1}  # Default to 1
                
                if [[ "$image_type" =~ ^[12]$ ]]; then
                        break
                else
                        echo "Please enter 1 or 2"
                fi
                done

                if [ "$image_type" -eq 1 ]; then
                echo -e "${GREEN}NVIDIA image selected${NC}"
                else
                echo -e "${GREEN}AMD image selected${NC}"
                fi

}

what_os () {
                while true; do
                read -p "What OS do you need, Ubuntu 22.04 (1) or 24.04 (2)? [1]: " os_ver
                os_ver=${os_ver:-1}  # Default to 1
                
                if [[ "$image_type" =~ ^[12]$ ]]; then
                        break
                else
                        echo "Please enter 1 or 2"
                fi
                done

                if [ "$image_type" -eq 1 ]; then
                echo -e "${GREEN}22.04 image selected${NC}"
                else
                echo -e "${GREEN}24.04 image selected${NC}"
                fi

}

what_driver () {

                if [ "$image_type" -eq 1 ]; then 
                        read -p "What driver do you need, Nvidia 550 (1), 560 (2), 570 (3), 575 (4) or All (0)? [0]: " driver_ver
                        case "$driver_ver" in
                                "1")
                                        driver_ver=550
                                        ;;
                                "2")
                                        driver_ver=560
                                        ;;
                                "3")
                                        driver_ver=570
                                        ;;
                                "4")
                                        driver_ver=575
                                        ;;
                        esac

                elif [ "$image_type" -eq 2 ]; then
                        read -p "What driver do you need, AMD ROCEM 632 (1) or All (0)? [Default: 0]: " driver_ver

                        case "driver_ver" in 
                                "1")
                                        driver_ver=632
                                        ;;
                        esac
                fi
                                
                if [ "$image_type" -eq 1 ]; then
                        case "$driver_ver" in
                                "0")
                                        echo -e "${GREEN}All drivers selected${NC}"
                                        ;;
                                "550")
                                        echo -e "${GREEN}Driver 550 selected${NC}"
                                        ;;
                                "560")
                                        echo -e "${GREEN}Driver 560 selected${NC}"
                                        ;;
                                "570")
                                        echo -e "${GREEN}Driver 570 selected${NC}"
                                        ;;
                                "575")
                                        echo -e "${GREEN}Driver 575 selected${NC}"
                                        ;;
                                *)
                                        echo -e "${CYAN}No specific driver selected${NC}"
                                        ;;
                        esac
                        
                elif [ "$image_type" -eq 2 ]; then
                        
                        case "$driver_ver" in
                                "0")
                                        echo -e "${GREEN}All drivers selected${NC}"
                                        ;;
                                "632")
                                        echo -e "${GREEN}Driver 632 selected${NC}"
                                        ;;
                                *)
                                        echo -e "${CYAN}No specific driver selected${NC}"
                                        ;;
                        esac
                        
                fi

}


get_image_name () {
        local image_name=$(echo "$1" | awk -F'/' '{print $11}')
        echo "$image_name"
        return 0
}

does_image_exist() {
        local compartment_id="$1"
        local image_name="$2"
        local uri="$3"
        local os="$4"

        local result=$(oci compute image list --compartment-id "$compartment_id" --query "data[?\"display-name\" == '$image_name']" --all --output json)
        ##echo "Compartment id " $compartment_id
        ##echo "Image Name " $image_name
        ##echo "URI " $uri
        ##echo "OS " $os
        ##echo "Results " $result
        if [ -n $image_name ]; then
                if [ "$result" = "[]" ] || [ -z "$result" ]; then
                        echo -e "${GREEN}✅ Image NOT found${NC} in compartment, importing $image_name"
                        oci compute image import from-object-uri --uri $uri --compartment-id $compartment_id --operating-system "$os" --display-name $image_name
                else 
                        echo -e "${RED}❌ Image FOUND${NC} in compartment already, $image_name, skipping to import."
                fi 
        fi
}

import_images() {

                        for images in "${IMAGES[@]}"; do
                                local temp_image_name=$(get_image_name "$images")
                                does_image_exist $COMP_OCID $temp_image_name "$images" $OS
                        done

}

get_compartments() {
        # Get all compartments including root
        local import_poc="y"
        read -p "Do you want to import to the POC compartment? (default: y): " import_poc
        import_poc=${import_poc:-y}

        if [ "$import_poc" == "y" ]; then
                COMP_OCID=$(oci iam compartment list --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --lifecycle-state ACTIVE --query "data[?contains(name,'POC')].id | [0]" --raw-output)
        else
                oci iam compartment list --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --lifecycle-state ACTIVE --query 'data[*].{Name:name, OCID:id, State:"lifecycle-state", Description:description}' --output table
        
        while [ -z $COMP_OCID ]; do
                read -p "Please select Compartment OCID to import images to: " COMP_OCID
        done

        fi

        print_status "Compartment $COMP_OCID selected"

}

month_import() {
        month_selected="$1"
        get_compartments

        what_image

        what_os

        what_driver

        #March 2025
        if (( $month_selected == 1 )); then

                if (( $image_type == 1 )); then
                ## NVIDIA Images
                ## March 2025 Ubuntu 22.04
                        if (($os_ver == 1 )); then
                                case "$driver_ver" in
                                        "550")
                                                IMAGES=(
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-GPU-550-CUDA-12.4-2025.03.26-0"
                                                        )
                                                ;;
                                        "560")
                                                IMAGES=(
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-GPU-560-CUDA-12.6-2025.03.26-0"
                                                        )
                                                ;;      
                                        "570")
                                                IMAGES=(
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-GPU-570-CUDA-12.8-2025.03.26-0"
                                                        )
                                                ;;
                                        "575")
                                                IMAGES=()
                                                ;;
                                        *)
                                                IMAGES=(
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-GPU-550-CUDA-12.4-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-GPU-560-CUDA-12.6-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-GPU-570-CUDA-12.8-2025.03.26-0"
                                                        )
                                        ;;
                                esac
                        elif (( $os_ver == 2 )); then
                        ## NVIDIA Images
                        ## March 2025 Ubuntu 24.04
                                case "$driver_ver" in
                                        "560")
                                                IMAGES=(
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2024.10.09-0-OCA-DOCA-OFED-2.10.0-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2024.10.09-0-OCA-DOCA-OFED-2.10.0-GPU-560-CUDA-12.6-2025.03.27-0"
                                                        )
                                                ;;      
                                        "570")
                                                IMAGES=(
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2024.10.09-0-OCA-DOCA-OFED-2.10.0-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2024.10.09-0-OCA-DOCA-OFED-2.10.0-GPU-570-CUDA-12.8-2025.03.27-0"
                                                        )
                                                ;;
                                        *)
                                                IMAGES=(
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2024.10.09-0-OCA-DOCA-OFED-2.10.0-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2024.10.09-0-OCA-DOCA-OFED-2.10.0-GPU-560-CUDA-12.6-2025.03.27-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2024.10.09-0-OCA-DOCA-OFED-2.10.0-GPU-570-CUDA-12.8-2025.03.27-0"
                                                        )
                                        ;;
                                esac
                        fi

                elif (( $image_type == 2 )); then
                        ## AMD Images
                        ## March 2025 Ubuntu 22.04
                        if (($os_ver == 1 )); then
                                case "$driver_ver" in
                                        "632")
                                                IMAGES=(
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-AMD-ROCM-632-2025.03.26-0"
                                                )
                                                ;;
                                        *)
                                                IMAGES=(
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2024.10.04-0-OCA-OFED-24.10-1.1.4.0-AMD-ROCM-632-2025.03.26-0"
                                                        )
                                        ;;
                                esac
                        elif (( $os_ver == 2 )); then
                        ## AMD Images
                        ## March 2025 Ubuntu 24.04
                                case "$driver_ver" in
                                        "632")
                                                IMAGES=(
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2024.10.09-0-OCA-DOCA-OFED-2.10.0-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2024.10.09-0-OCA-DOCA-OFED-2.10.0-AMD-ROCM-632-2025.03.26-0"
                                                )
                                                ;;
                                        *)
                                                IMAGES=(
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2024.10.09-0-OCA-DOCA-OFED-2.10.0-2025.03.26-0"
                                                        "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2024.10.09-0-OCA-DOCA-OFED-2.10.0-AMD-ROCM-632-2025.03.26-0"
                                                )
                                        ;;
                                esac
                        fi       
                else
                        echo "No images of $image_type and $os_ver selected"
                fi

        #June 2025
        elif (( $month_selected == 2 )); then
                if (( $image_type == 1 )); then
                        ## NVIDIA Images
                        ## June 2025 Ubuntu 22.04
                                if (($os_ver == 1 )); then
                                        case "$driver_ver" in
                                                "550")
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-2025.06.07-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-GPU-550-CUDA-12.4-2025.06.07-0"
                                                                )
                                                        ;;
                                                "560")
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-2025.06.07-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-GPU-560-CUDA-12.6-2025.06.07-0"
                                                                )
                                                        ;;      
                                                "570")
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-2025.06.07-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-GPU-570-OPEN-CUDA-12.8-2025.06.07-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-aarch64-2025.05.20-0-OFED-24.10-1.1.4.0-GPU-570-OPEN-CUDA-12.8-2025.07.02-0"
                                                                )
                                                        ;;
                                                "575")
                                                        IMAGES=()
                                                        ;;
                                                *)
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-GPU-570-OPEN-CUDA-12.8-2025.06.07-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-GPU-560-CUDA-12.6-2025.06.07-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-GPU-550-CUDA-12.4-2025.06.07-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-2025.06.07-0"
                                                                )
                                                ;;
                                        esac
                                elif (( $os_ver == 2 )); then
                                ## NVidia Images
                                ## 24.04 -- No images available to use
                                        case "$driver_ver" in
                                                "560")
                                                        IMAGES=(
                                                                )
                                                        ;;      
                                                "570")
                                                        IMAGES=(
                                                        
                                                                )
                                                        ;;
                                                *)
                                                        IMAGES=(
                                                                )
                                                ;;
                                        esac
                                fi
                elif (( $image_type == 2 )); then
                                ## AMD Images
                                ## June 2025 Ubuntu 22.04, No images available to use
                                if (($os_ver == 1 )); then
                                        case "$driver_ver" in
                                                "632")
                                                        IMAGES=(
                                                                )
                                                        ;;
                                                *)
                                                        IMAGES=(
                                                                )
                                                ;;
                                        esac
                                elif (( $os_ver == 2 )); then
                                ## AMD Images
                                ## June 2025 Ubuntu 22.04, No images available to use
                                                        case "$driver_ver" in
                                                "632")
                                                        IMAGES=(
                                                        )
                                                        ;;
                                                *)
                                                        IMAGES=(
                                                        )
                                                ;;
                                        esac
                                fi  
                        else
                                echo "No images of $image_type and $os_ver selected"
                        fi
        elif (( $month_selected == 3 )); then
                if (( $image_type == 1 )); then
                                ## NVIDIA Images
                                ## July 2025 Ubuntu 22.04
                                if (($os_ver == 1 )); then
                                        case "$driver_ver" in
                                                "550")
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-2025.07.22-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-GPU-550-CUDA-12.4-2025.07.22-0"
                                                                )
                                                        ;;
                                                "560")
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-2025.07.22-0"

                                                                )
                                                        ;;      
                                                "570")
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-2025.07.22-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-GPU-570-OPEN-CUDA-12.8-2025.07.22-0"
                                                                )
                                                        ;;
                                                "575")
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-2025.07.22-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-DOCA-OFED-3.1.0-GPU-575-OPEN-CUDA-12.9-2025.07.22-0"
                                                                )
                                                        ;;
                                                *)
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-2025.07.22-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-GPU-550-CUDA-12.4-2025.07.22-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-GPU-570-OPEN-CUDA-12.8-2025.07.22-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-DOCA-OFED-3.1.0-GPU-575-OPEN-CUDA-12.9-2025.07.22-0"
                                                                )
                                                ;;
                                        esac
                                elif (( $os_ver == 2 )); then
                                ## NVIDIA Images
                                ## July 2025 Ubuntu 24.04
                                        case "$driver_ver" in
                                                "560")
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2025.05.20-0-DOCA-OFED-3.0.0-2025.07.22-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2025.05.20-0-DOCA-OFED-3.0.0-GPU-560-CUDA-12.6-2025.07.22-0"
                                                                )
                                                        ;;      
                                                "570")
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2025.05.20-0-DOCA-OFED-3.0.0-2025.07.22-0"
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-24.04-2025.05.20-0-DOCA-OFED-3.0.0-GPU-570-OPEN-CUDA-12.8-2025.07.22-0"
                                                                )
                                                        ;;
                                                *)
                                                        IMAGES=(
                                                                )
                                                ;;
                                        esac
                                fi
                elif (( $image_type == 2 )); then
                                ## AMD Images
                                ## July 2025 Ubuntu 22.04
                                if (($os_ver == 1 )); then
                                        case "$driver_ver" in
                                                "632")
                                                        IMAGES=(
                                                                )
                                                        ;;
                                                *)
                                                        IMAGES=(
                                                                "https://objectstorage.ca-montreal-1.oraclecloud.com/p/ts6fjAuj7hY4io5x_jfX3fyC70HRCG8-9gOFqAjuF0KE0s-6tgDZkbRRZIbMZmoN/n/hpc_limited_availability/b/images/o/Canonical-Ubuntu-22.04-2025.05.20-0-OFED-24.10-1.1.4.0-AMD-ROCM-632-2025.07.23-0"
                                                                
                                                                                                                )
                                                ;;
                                        esac
                                elif (( $os_ver == 2 )); then
                                ## AMD Images
                                ## July 2025 Ubuntu 24.04
                                                        case "$driver_ver" in
                                                "632")
                                                        IMAGES=(
                                                        )
                                                        ;;
                                                *)
                                                        IMAGES=(
                                                        )
                                                ;;
                                        esac
                                fi    
                        else
                                echo "No images of $image_type and $os_ver selected"
                        fi
                
        fi

                import_images $IMAGES

                echo -e "${GREEN}All images have been processed to be imported.${NC}"
}

delete_images() {

                COMPARTMENT_ID=
                SEARCH_TERM="OFED"
                DRY_RUN=false


                # Get all compartments including root
                oci iam compartment list --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --lifecycle-state ACTIVE --query 'data[*].{Name:name, OCID:id, State:"lifecycle-state", Description:description}' --output table

                while [ -z $COMPARTMENT_ID ]; do
                        read -p "What is the Compartment OCID? " COMPARTMENT_ID
                done


                # Parse arguments
                while [[ $# -gt 0 ]]; do
                case $1 in
                        --dry-run)
                        DRY_RUN=true
                        shift
                        ;;
                        --search-term)
                        SEARCH_TERM="$2"
                        shift 2
                        ;;
                        *)
                        shift
                        ;;
                esac
                done

                echo "Simple OCI Image Script"
                echo "================================"
                echo "Compartment: $COMPARTMENT_ID"
                echo "Search term: $SEARCH_TERM"
                echo "Mode: $([ "$DRY_RUN" == true ] && echo "DRY RUN" || echo "DELETE")"
                echo ""

                # Step 1: Get all images (avoiding JMESPath filtering)
                echo "Getting all images in compartment..."
                ALL_IMAGES=$(oci compute image list --all --compartment-id "$COMPARTMENT_ID" 2>/dev/null)

                if [[ $? -ne 0 ]]; then
                echo "Error: Failed to get images"
                exit 1
                fi

                # Step 2: Filter using jq instead of JMESPath
                echo "Filtering images containing '$SEARCH_TERM'..."
                FILTERED_IMAGES=$(echo "$ALL_IMAGES" | jq -r ".data[] | select(.\"display-name\" | contains(\"$SEARCH_TERM\")) | select(.publisher != \"Oracle\" and .publisher != \"Canonical\") | .id + \"|\" + .\"display-name\" + \"|\" + .\"lifecycle-state\"")

                if [[ -z "$FILTERED_IMAGES" ]]; then
                echo "No custom images found containing '$SEARCH_TERM'"
                exit 0
                fi

                # Step 3: Display found images
                echo ""
                echo "Found custom images containing '$SEARCH_TERM':"
                echo "=============================================="
                printf "%-50s %-15s %s\n" "DISPLAY NAME" "STATE" "OCID"
                echo "$(printf '%*s' 100 | tr ' ' '-')"

                echo "$FILTERED_IMAGES" | while IFS='|' read -r ocid name state; do
                printf "%-50s %-15s %s\n" "$name" "$state" "$ocid"
                done

                # Count images
                IMAGE_COUNT=$(echo "$FILTERED_IMAGES" | wc -l)
                echo ""
                echo "Total images: $IMAGE_COUNT"
                

                # Step 4: Confirm deletion
                if [[ "$DRY_RUN" == false ]]; then
                echo ""
                echo "WARNING: This will permanently delete $IMAGE_COUNT image(s)!"
                read -p "Type 'yes' to confirm deletion: " confirm
                
                if [[ "$confirm" != "yes" ]]; then
                        echo "Deletion cancelled"
                        exit 0
                fi
                
                # Step 5: Delete images
                echo ""
                echo "Deleting images..."
                echo "$FILTERED_IMAGES" | while IFS='|' read -r ocid name state; do
                        echo "Deleting: $name ($ocid)"
                        oci compute image delete --image-id "$ocid" --force
                        if [[ $? -eq 0 ]]; then
                        echo "  ✓ Deletion initiated successfully"
                        else
                        echo "  ✗ Deletion failed"
                        fi
                        echo ""
                done
                else
                echo ""
                if [[ "$DRY_RUN" ]]; then
                        echo "This is a dry run and if actually ran would delete $IMAGE_COUNT images"
                fi
                fi

}

#!/bin/bash

check_images() {
    SEARCH_TERM="OFED"
    REQUIRED_SHAPES=()
    CHECK_ALL_SHAPES=false
    VERBOSE=false
    NO_ALTERNATIVE_CHECK=false
    
    # Default GPU shapes from official OCI documentation
    DEFAULT_SHAPES=(
        # Bare Metal GPU Shapes
        "BM.GPU2.2"           # 2x P100 16GB
        "BM.GPU3.8"           # 8x V100 16GB
        "BM.GPU4.8"           # 8x A100 40GB
        "BM.GPU.A10.4"        # 4x A10 24GB
        "BM.GPU.A100-v2.8"    # 8x A100 80GB
        "BM.GPU.MI300X.8"     # 8x MI300X 192GB (AMD)
        "BM.GPU.L40S.4"       # 4x L40S 48GB
        "BM.GPU.H100.8"       # 8x H100 80GB
        "BM.GPU.H200.8"       # 8x H200 141GB
        "BM.GPU.B200.8"       # 8x B200 180GB
        "BM.GPU.GB200.4"      # 4x B200 192GB (Grace Blackwell)
        # Virtual Machine GPU Shapes
        "VM.GPU2.1"           # 1x P100 16GB
        "VM.GPU3.1"           # 1x V100 16GB
        "VM.GPU3.2"           # 2x V100 16GB
        "VM.GPU3.4"           # 4x V100 16GB
        "VM.GPU.A10.1"        # 1x A10 24GB
        "VM.GPU.A10.2"        # 2x A10 24GB
    )


    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --search-term)
                SEARCH_TERM="$2"
                shift 2
                ;;
            --shapes)
                # Parse comma-separated shapes
                IFS=',' read -ra REQUIRED_SHAPES <<< "$2"
                shift 2
                ;;
            --check-all-shapes)
                CHECK_ALL_SHAPES=true
                shift
                ;;
            --debug)
                set -x
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --search-term TERM       Search for images containing TERM (default: OFED)"
                echo "  --shapes SHAPE1,SHAPE2   Comma-separated list of shapes to check"
                echo "  --check-all-shapes       Show all compatible shapes instead of checking specific ones"
                echo "  --debug                  Enable debug mode"
                echo "  --verbose                Enable verbose output"
                echo "  --help                   Show this help"
                echo ""
                echo "Examples:"
                echo "  $0 --shapes 'BM.GPU4.8,VM.GPU.A10.1'"
                echo "  $0 --check-all-shapes"
                echo "  $0 --search-term CUDA --shapes 'BM.GPU4.8'"
                exit 0
                ;;
            --no-alternative-check)
                NO_ALTERNATIVE_CHECK=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Use default shapes if none provided
    if [[ ${#REQUIRED_SHAPES[@]} -eq 0 ]]; then
        REQUIRED_SHAPES=("${DEFAULT_SHAPES[@]}")
    fi

    echo "OCI OFED Image Shape Compatibility Checker"
    echo "=========================================="
    echo "Compartment: $COMPARTMENT_ID"
    echo "Search term: $SEARCH_TERM"
    if [[ "$CHECK_ALL_SHAPES" == true ]]; then
        echo "Mode: Check all compatible shapes"
    else
        echo "Required shapes: ${REQUIRED_SHAPES[*]}"
    fi
    echo ""

    # Step 1: Get all images
    echo "Getting all images in compartment..."
    ALL_IMAGES=$(oci compute image list --all --compartment-id "$COMP_OCID" 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to get images"
        exit 1
    fi

    # Step 2: Filter using jq
    echo "Filtering custom images containing '$SEARCH_TERM'..."
    FILTERED_IMAGES=$(echo "$ALL_IMAGES" | jq -r ".data[] | select(.\"display-name\" | contains(\"$SEARCH_TERM\")) | select(.publisher != \"Oracle\" and .publisher != \"Canonical\") | .id + \"|\" + .\"display-name\" + \"|\" + .\"lifecycle-state\"")

    if [[ -z "$FILTERED_IMAGES" ]]; then
        echo "No custom images found containing '$SEARCH_TERM'"
        exit 0
    fi

    # Count images
    IMAGE_COUNT=$(echo "$FILTERED_IMAGES" | wc -l)
    echo "Found $IMAGE_COUNT custom image(s) containing '$SEARCH_TERM'"
    echo ""

    # Function to check image metadata (alternative method)
    check_image_metadata() {
        local image_id="$1"
        local image_name="$2"
        
        echo "   🔍 Checking image metadata for clues about compatibility..."
        
        # Get detailed image information
        IMAGE_DETAILS=$(oci compute image get --image-id "$image_id" 2>/dev/null)
        
        if [[ $? -eq 0 ]]; then
            # Extract relevant metadata
            OS=$(echo "$IMAGE_DETAILS" | jq -r '.data."operating-system" // "Unknown"')
            OS_VERSION=$(echo "$IMAGE_DETAILS" | jq -r '.data."operating-system-version" // "Unknown"')
            SIZE_GB=$(echo "$IMAGE_DETAILS" | jq -r '.data."size-in-mbs" // 0 | tonumber / 1024')
            
            echo "   📋 Image metadata:"
            echo "      OS: $OS $OS_VERSION"
            echo "      Size: ${SIZE_GB} GB"
            
            # Make educated guesses based on image name and metadata
            if echo "$image_name" | grep -iq "gpu\|cuda\|rocm"; then
                echo "   🎯 Image appears to be GPU-optimized (contains GPU/CUDA/ROCM)"
                echo "   💡 Likely compatible with GPU shapes like:"
                for shape in "${REQUIRED_SHAPES[@]}"; do
                    if echo "$shape" | grep -iq "gpu"; then
                        echo "      • $shape (GPU shape - likely compatible)"
                    fi
                done
            fi
            
            if echo "$image_name" | grep -iq "ofed\|infiniband"; then
                echo "   🌐 Image appears to have InfiniBand/OFED support"
                echo "   💡 Likely compatible with high-performance compute shapes"
            fi
            
            echo "   ⚠️  Note: This is an educated guess based on naming. Use OCI Console to configure actual shape compatibility."
            echo "   🔧 To configure shape compatibility manually:"
            for shape in "${REQUIRED_SHAPES[@]}"; do
                echo "      oci compute image-shape-compatibility-entry create --image-id $image_id --shape-name $shape"
            done
        else
            echo "   ❌ Could not retrieve image metadata"
        fi
    }

    # Step 3: Check shape compatibility for each image
    echo "Checking shape compatibility..."
    echo "============================================================="

    COMPATIBLE_IMAGES=0
    INCOMPATIBLE_IMAGES=0
    IMAGES_TO_SHOW=()

    # First pass: collect images that need attention
    while IFS='|' read -r ocid name state; do
        if [[ "$state" != "AVAILABLE" ]]; then
            continue  # Skip unavailable images
        fi
        
        # Try the shape compatibility API first
        SHAPES_DATA=$(oci compute image-shape-compatibility-entry list --image-id "$ocid" 2>&1)
        SHAPES_EXIT_CODE=$?
        
        if [[ $SHAPES_EXIT_CODE -ne 0 ]]; then
            # API failed - this image needs attention
            IMAGES_TO_SHOW+=("$ocid|$name|$state|API_ERROR")
            continue
        fi
        
        COMPATIBLE_SHAPES=$(echo "$SHAPES_DATA" | jq -r '.data[].shape' 2>/dev/null | sort)
        
        if [[ -z "$COMPATIBLE_SHAPES" ]]; then
            # No shapes configured - this image needs attention
            IMAGES_TO_SHOW+=("$ocid|$name|$state|NO_SHAPES")
            continue
        fi
        
        if [[ "$CHECK_ALL_SHAPES" == true ]]; then
            # For --check-all-shapes, always show (user wants to see what's configured)
            IMAGES_TO_SHOW+=("$ocid|$name|$state|HAS_SHAPES")
        else
            # Check if any required shapes are missing
            MISSING_SHAPES=()
            
            for required_shape in "${REQUIRED_SHAPES[@]}"; do
                if ! echo "$COMPATIBLE_SHAPES" | grep -q "^$required_shape$"; then
                    MISSING_SHAPES+=("$required_shape")
                fi
            done
            
            if [[ ${#MISSING_SHAPES[@]} -gt 0 ]]; then
                # Has missing shapes - this image needs attention
                IMAGES_TO_SHOW+=("$ocid|$name|$state|MISSING_SHAPES")
            else
                # All shapes are configured - skip this image
                ((COMPATIBLE_IMAGES++))
            fi
        fi
    done <<< "$FILTERED_IMAGES"

    # Show results
    if [[ ${#IMAGES_TO_SHOW[@]} -eq 0 ]]; then
        echo ""
        if [[ "$CHECK_ALL_SHAPES" == true ]]; then
            echo "✅ No images found with shape compatibility configured."
        else
            echo "✅ All images already have the required shapes configured!"
            echo ""
            echo "📊 Summary:"
            echo "   Total images: $IMAGE_COUNT"
            echo "   Images with all required shapes: $COMPATIBLE_IMAGES"
            echo "   Required shapes: ${REQUIRED_SHAPES[*]}"
        fi
        echo ""
        echo "💡 No action needed - all images are properly configured."
        exit 0
    fi

    # Display only images that need attention
    for image_info in "${IMAGES_TO_SHOW[@]}"; do
        IFS='|' read -r ocid name state status <<< "$image_info"
        
        echo ""
        echo "🖼️  Image: $name"
        echo "   OCID: ${ocid}"
        echo "   State: $state"
        
        # Re-fetch shape data for display
        SHAPES_DATA=$(oci compute image-shape-compatibility-entry list --image-id "$ocid" 2>&1)
        SHAPES_EXIT_CODE=$?
        
        if [[ $SHAPES_EXIT_CODE -ne 0 ]]; then
            # Handle API errors
            if echo "$SHAPES_DATA" | grep -iq "notauthorizedornotfound\|not found\|404"; then
                echo "   ⚠️  Image shape compatibility not configured or not accessible"
            elif echo "$SHAPES_DATA" | grep -iq "serviceerror\|500\|503"; then
                echo "   ⚠️  Service error accessing shape compatibility API"
            elif echo "$SHAPES_DATA" | grep -iq "invalidparameter\|400"; then
                echo "   ⚠️  Invalid parameter - image may not support shape compatibility API"
            else
                echo "   ❌ Error: Failed to retrieve shape compatibility"
                if [[ $VERBOSE == true ]]; then
                    echo "   📝 Error details: $SHAPES_DATA"
                fi
            fi
            
            if [[ $NO_ALTERNATIVE_CHECK != true ]]; then
                echo "   💡 Trying alternative method: image metadata check..."
                check_image_metadata "$ocid" "$name"
            fi
            ((INCOMPATIBLE_IMAGES++))
            continue
        fi
        
        COMPATIBLE_SHAPES=$(echo "$SHAPES_DATA" | jq -r '.data[].shape' 2>/dev/null | sort)
        
        if [[ -z "$COMPATIBLE_SHAPES" ]]; then
            echo "   ❌ No shape compatibility configured"
            echo "   💡 Configure shapes using: oci compute image-shape-compatibility-entry create --image-id $ocid --shape-name <SHAPE_NAME>"
            ((INCOMPATIBLE_IMAGES++))
            continue
        fi
        
        if [[ "$CHECK_ALL_SHAPES" == true ]]; then
            # Show all compatible shapes
            echo "   ✅ Shape compatibility configured"
            SHAPE_COUNT=$(echo "$COMPATIBLE_SHAPES" | wc -l)
            echo "   📊 Compatible shapes ($SHAPE_COUNT):"
            echo "$COMPATIBLE_SHAPES" | while read -r shape; do
                echo "      ✓ $shape"
            done
            ((COMPATIBLE_IMAGES++))
        else
            # Check specific required shapes and show missing ones
            MISSING_SHAPES=()
            FOUND_SHAPES=()
            
            for required_shape in "${REQUIRED_SHAPES[@]}"; do
                if echo "$COMPATIBLE_SHAPES" | grep -q "^$required_shape$"; then
                    FOUND_SHAPES+=("$required_shape")
                else
                    MISSING_SHAPES+=("$required_shape")
                fi
            done
            
            echo "   ⚠️  Missing required shapes!"
            
            if [[ ${#FOUND_SHAPES[@]} -gt 0 ]]; then
                echo "   ✅ Already configured:"
                for shape in "${FOUND_SHAPES[@]}"; do
                    echo "      ✓ $shape"
                done
            fi
            
            echo "   ❌ Missing shapes:"
            for shape in "${MISSING_SHAPES[@]}"; do
                echo "      ✗ $shape"
                echo "         Add with: oci compute image-shape-compatibility-entry create --image-id $ocid --shape-name $shape"
            done
            ((INCOMPATIBLE_IMAGES++))
        fi
        
        echo "   ─────────────────────────────────────────────────────────"
    done

    # Final summary
    echo ""
    echo "Summary"
    echo "======="
    
    if [[ ${#IMAGES_TO_SHOW[@]} -eq 0 ]]; then
        echo "✅ All images are properly configured!"
    else
        echo "Images needing attention: ${#IMAGES_TO_SHOW[@]}"
        echo "Images already configured: $COMPATIBLE_IMAGES"
        echo "Total images found: $IMAGE_COUNT"
        
        if [[ "$CHECK_ALL_SHAPES" != true ]]; then
            echo ""
            echo "Required shapes: ${REQUIRED_SHAPES[*]}"
        fi
        
        echo ""
        echo "💡 Use the commands above to configure missing shapes"
    fi
}

main () {

        echo -e  "${CYAN}What would you like to do?${NC}
                ${YELLOW}(1) Verify Images
                (2) Delete All Uploaded Images
                (3) Upload March Images
                (4) Upload June Images
                (5) Upload July Images 
                (6) Listing all compartments${NC}       
                "
        read action

                if [ "$action" -eq 1 ]; then
                        delete_images --dry-run
                elif [ $action -eq 2 ]; then
                        delete_images
                elif [ $action -eq 3 ]; then
                        #March Images
                        month_import 1
                        check_images "$@"
                elif [ $action -eq 4 ]; then
                        #June Images
                        month_import 2
                        check_images "$@"
                elif [ $action -eq 5 ]; then
                        #July Images
                        month_import 3
                        check_images"$@"
                elif [ $action -eq 6 ]; then
                        compartment_lister "$OCI_TENANCY"
                else
                        echo "No action selected."
                fi


                

}

main "$@"