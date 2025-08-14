
## v1.0.0
## Script used to simplify determining limits for GPU deployments
## modify ad, gpu and provide the tenancy ocid
## run in the oci shell of the tenancy.  Please sure to run it in the region you plan to validate service limits for.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m' # No Color (reset)

region="$OCI_CLI_PROFILE"
ad="0"
selectad=""
GPU=gpu-a100-v2-count
comp_id=`oci iam compartment list --all  --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --raw-output --query "data[?contains(\"id\",'tenancy')].id | [0]"`

get_limit_availability() {
        local command="$1"
        local service="$2"
       json_output=$(eval "$command")

        # Simple while loop through items
        i=0
        total=$(echo "$json_output" | jq 'length')

        while [[ $i -lt $total ]]; do
        # Extract the required fields
        availability_domain=$(echo "$json_output" | jq -r ".[$i].\"availability-domain\"")
        limit_name=$(echo "$json_output" | jq -r ".[$i].name")
        
        echo -e "${BLUE}Info: Processing item $((i+1))/$total: ${WHITE}$limit_name${NC} ${BLUE}in${NC} ${WHITE}$availability_domain${NC}${NC}"

        if [[ "$availability_domain" == "null" || -z "$availability_domain" ]]; then
                oci limits resource-availability get \
                --service-name $service \
                --compartment-id "$OCI_TENANCY" \
                --limit-name $limit_name \
                --region $region \
                --output table
        else
                oci limits resource-availability get \
                        --service-name $service \
                        --compartment-id $OCI_TENANCY \
                        --limit-name $limit_name \
                        --availability-domain "$availability_domain" \
                        --region $region \
                        --output table
        fi

        ((i++))
        done
}

#AD1=$(oci iam availability-domain list --query 'data[*].name | [0]' --profile $region --raw-output)
#AD2=$(oci iam availability-domain list --query 'data[*].name | [1]' --profile $region)
#AD3=$(oci iam availability-domain list --query 'data[*].name | [2]' --profile $region)
#AD1=${AD1#\"}
#AD1=${AD1%\"}
#echo $AD1


echo -e  "${CYAN}Your Region to evaluate limits for is: $region${NC}"
echo -e "${CYAN}Enter new region (or press Enter to keep current): ${NC}"
read new_region

# Use new region if provided, otherwise keep current
region="${new_region:-$region}"

echo -e "${GREEN}Using region: $region${NC}"

echo -e "${CYAN}Your Availability Zone is $ad${NC}"
echo -n -e "${CYAN}Do you want to specify a specific AD? (0 for all (Default) or 1,2,3) : ${NC}"
read selected
ad="${selected:-$ad}"

echo -e "${GREEN}Using Availability Zone $ad${NC}"
selectad=$[selected - 1]

while [ -v $comp_id ] ; do
        read -p "What is the tenancy OCID? " comp_id
done

if [ "$ad" -eq 0 ]; then
                
                echo -e "${YELLOW}GPUs${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query 'sort_by(data[?contains(name,\`gpu\`) && !contains(name,\`reserv\`) && value > \`0\`],&\"availability-domain\")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query '\''sort_by(data[?contains(name,`gpu`) && !contains(name,`reserv`) && value > `0`],&"availability-domain")'\'' --region $region --all --output json'
                get_limit_availability "$oci_command" compute

                echo -e "${YELLOW}E5 Cores${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query 'sort_by(data[?contains(name,`e5-core`) && !contains(name,`reserv`)],&"name")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query '\''sort_by(data[?contains(name,`e5-core`) && !contains(name,`reserv`) && value > `0`],&"name")'\'' --region $region --all --output json'
                get_limit_availability "$oci_command" compute
                
                echo -e "${YELLOW}E5 Memory${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query 'sort_by(data[?contains(name,`e5-memory`) && !contains(name,`reserv`)],&"name")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query '\''sort_by(data[?contains(name,`e5-memory`) && !contains(name,`reserv`) && value > `0`],&"name")'\'' --region $region --all --output json'
                get_limit_availability "$oci_command" compute
                
                echo -e "${YELLOW}Block Storage${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name block-storage --query 'sort_by(data[?contains(name,`total-storage-gb`) || contains(name,`volume-count`) && !contains(name,`reserv`)],&"name")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name block-storage --query '\''sort_by(data[?contains(name,`total-storage-gb`) || contains(name,`volume-count`) && !contains(name,`reserv`) && value > `0`],&"name")'\'' --region $region --all --output json'
                get_limit_availability "$oci_command" block-storage

                echo -e "${YELLOW}File Storage Service${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name filesystem --query 'sort_by(data[?contains(name,`file-system-count`) || contains(name,`mount-target`) && !contains(name,`reserv`)],&"name")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name filesystem --query '\''sort_by(data[?contains(name,`file-system-count`) || contains(name,`mount-target`) && !contains(name,`reserv`) && value > `0`],&"name")'\'' --region $region --all --output json'
                get_limit_availability "$oci_command" filesystem

                echo -e "${YELLOW}Cluster Network${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name compute-management --query 'sort_by(data[?contains(name,`cluster-network`) && !contains(name,`reserv`)],&"name")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name compute-management --query '\''sort_by(data[?contains(name,`cluster-network`) && !contains(name,`reserv`)],&"name")'\'' --region $region --all --output json'
                get_limit_availability "$oci_command" compute-management


        else
                
                ad=$(oci iam availability-domain list --query "data[$selectad].name" --region $region --raw-output)
        
                echo -e "${YELLOW}GPUs${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query 'sort_by(data[?contains(name,\`gpu\`) && !contains(name,\`reserv\`) && value > \`0\`],&\"availability-domain\")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query '\''sort_by(data[?contains(name,`gpu`) && !contains(name,`reserv`) && value > `0`],&"availability-domain")'\'' --availability-domain $ad --region $region --all --output json'
                get_limit_availability "$oci_command" compute

                echo -e "${YELLOW}E5 Cores${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query 'sort_by(data[?contains(name,`e5-core`) && !contains(name,`reserv`)],&"name")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query '\''sort_by(data[?contains(name,`e5-core`) && !contains(name,`reserv`) && value > `0`],&"name")'\'' --availability-domain $ad --region $region --all --output json'
                get_limit_availability "$oci_command" compute
                
                echo -e "${YELLOW}E5 Memory${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query 'sort_by(data[?contains(name,`e5-memory`) && !contains(name,`reserv`)],&"name")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name compute --query '\''sort_by(data[?contains(name,`e5-memory`) && !contains(name,`reserv`) && value > `0`],&"name")'\'' --availability-domain $ad --region $region --all --output json'
                get_limit_availability "$oci_command" compute
                
                echo -e "${YELLOW}Block Storage${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name block-storage --query 'sort_by(data[?contains(name,`total-storage-gb`) || contains(name,`volume-count`) && !contains(name,`reserv`)],&"name")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name block-storage --query '\''sort_by(data[?contains(name,`total-storage-gb`) || contains(name,`volume-count`) && !contains(name,`reserv`) && value > `0`],&"name")'\'' --availability-domain $ad --region $region --all --output json'
                get_limit_availability "$oci_command" block-storage

                echo -e "${YELLOW}File Storage Service${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name filesystem --query 'sort_by(data[?contains(name,`file-system-count`) || contains(name,`mount-target`) && !contains(name,`reserv`)],&"name")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name filesystem --query '\''sort_by(data[?contains(name,`file-system-count`) || contains(name,`mount-target`) && !contains(name,`reserv`) && value > `0`],&"name")'\'' --availability-domain $ad --region $region --all --output json'
                get_limit_availability "$oci_command" filesystem

                echo -e "${YELLOW}Cluster Network${NC}"
                ##oci limits value list --compartment-id $OCI_TENANCY --service-name compute-management --query 'sort_by(data[?contains(name,`cluster-network`) && !contains(name,`reserv`)],&"name")' --all --output table
                oci_command='oci limits value list --compartment-id $OCI_TENANCY --service-name compute-management --query '\''sort_by(data[?contains(name,`cluster-network`) && !contains(name,`reserv`)],&"name")'\'' --region $region --all --output json'
                get_limit_availability "$oci_command" compute-management

fi