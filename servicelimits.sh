#!/bin/bash
## Author: Tim Cowen (tim.cowen@oracle)
## v1.0.0
## Script used to simplify determining limits for GPU deployments
## modify ad, gpu and provide the tenancy ocid
## run in the oci shell of the tenancy.  Please sure to run it in the region you plan to validate service limits for.

region=""
ad=""
selectad=""
GPU=gpu-a100-v2-count
comp_id=`oci iam compartment list --all  --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --raw-output --query "data[?contains(\"id\",'tenancy')].id | [0]"`

#AD1=$(oci iam availability-domain list --query 'data[*].name | [0]' --profile $region --raw-output)
#AD2=$(oci iam availability-domain list --query 'data[*].name | [1]' --profile $region)
#AD3=$(oci iam availability-domain list --query 'data[*].name | [2]' --profile $region)
#AD1=${AD1#\"}
#AD1=${AD1%\"}
#echo $AD1


if [ -z $region ] ; then
        read -p "What region? (ex. us-phoenix-1, us-ashburn-1..) : " region
fi


if [ -z $ad ]; then
        read -p "What AD? (1,2,3) : " selectad
        selectad=$[selectad - 1]
        #ad=${ad#\"}
        #ad=${ad%\"}
fi


while [ -v $comp_id ] ; do
        read -p "What is the tenancy OCID? " comp_id
done

if [ -z "$ad" ]; then


        echo "GPUs"
        oci limits value list --compartment-id ${comp_id} --service-name compute --name ${GPU} --output table

        echo "E5 Cores"
        oci limits value list --compartment-id ${comp_id} --service-name compute --name standard-e5-core-count --output table

        echo "E5 Memory"
        oci limits value list --compartment-id ${comp_id} --service-name compute --name standard-e5-memory-count --output table

        echo "Block Storage"
        oci limits value list --compartment-id ${comp_id} --service-name block-storage --output table

        echo "File Storage Service"
        oci limits value list --compartment-id ${comp_id} --service-name filesystem --output table

else

        ad=$(oci iam availability-domain list --query 'data[*].name | ['$selectad']' --profile $region --raw-output)
        #ad=${ad#\"}
        #ad=${ad%\"}

        #oci limits value list --compartment-id ${comp_id} --service-name compute --name ${GPU} --availability-domain $ad --profile $region | grep value | xargs -I {} echo "$GPU {}"

        oci limits value list --compartment-id ${comp_id} --service-name compute --name ${GPU} --availability-domain $ad --profile $region --output table
        oci limits value list --compartment-id ${comp_id} --service-name compute --name standard-e5-core-count --availability-domain $ad --profile $region  --output table
        oci limits value list --compartment-id ${comp_id} --service-name compute --name standard-e5-memory-count --availability-domain $ad --profile $region  --output table
        oci limits value list --compartment-id ${comp_id} --service-name block-storage --availability-domain $ad --profile $region --output table
        oci limits value list --compartment-id ${comp_id} --service-name filesystem --availability-domain $ad --profile $region --output table

fi