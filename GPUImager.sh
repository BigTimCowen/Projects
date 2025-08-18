#!/bin/bash
## v1.0.0
## This script is used to verify, upload and/or delete HPC Images from object storage buckets for specific months.  This has to be modified manually when new images are released.  You can also view all compartments in a tenancy.
## run in the oci shell of the tenancy as an admin that can import images or delete images.

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
                        #oci compute image import from-object-uri --uri $uri --compartment-id $compartment_id --operating-system "$os" --display-name $image_name
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
        oci iam compartment list --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --lifecycle-state ACTIVE --query 'data[*].{Name:name, OCID:id, State:"lifecycle-state", Description:description}' --output table

        while [ -z $COMP_OCID ]; do
                read -p "What is the Compartment OCID? " COMP_OCID
        done

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
                printf "%-50s %-15s %s\n" "$name" "$state" "${ocid:0:40}..."
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

compartment_lister() {
        # Simple OCI Compartment Lister
        # Usage: ./simple_list_compartments.sh [tenancy-ocid]

        # Check if tenancy OCID is provided as argument
        if [ $# -eq 1 ]; then
        TENANCY_ID="$1"
        else
        # Try to get tenancy OCID from config
        echo "No tenancy OCID provided. Trying to get from OCI config..."
        TENANCY_ID=$(oci iam tenancy get --query "data.id" --raw-output 2>/dev/null)

        if [ $? -ne 0 ] || [ -z "$TENANCY_ID" ]; then
                echo "Error: Could not get tenancy OCID from config."
                echo "Usage: $0 <tenancy-ocid>"
                echo "Example: $0 ocid1.tenancy.oc1..aaaaaaaa..."
                echo ""
                echo "Or configure OCI CLI first:"
                echo "oci setup config"
                exit 1
        fi
        fi

        echo "Using tenancy: $TENANCY_ID"
        echo ""

        # List compartments
        echo "Compartment Name | Compartment OCID"
        echo "----------------------------------------"

        oci iam compartment list \
        --compartment-id "$TENANCY_ID" \
        --all \
        --query "data[?\"lifecycle-state\"=='ACTIVE'].{name:name,ocid:id}" \
        --output table

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
                elif [ $action -eq 4 ]; then
                        #June Images
                        month_import 2
                elif [ $action -eq 5 ]; then
                        #July Images
                        month_import 3
                elif [ $action -eq 6 ]; then
                        compartment_lister "$OCI_TENANCY"
                else
                        echo "No action selected."
                fi


                

}

main "$@"