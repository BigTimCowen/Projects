LOGFILE="create_gb200_oci_output.log"
exec > >(tee -a  $LOGFILE) 2>&1

echo "Listing GPU Memory Fabrics at $(date)"
echo "Sourcing Variables from variables.sh"

source ./variables.sh
oci compute compute-gpu-memory-fabric list --compartment-id $TENANCY_ID
echo "Completed listing GPU Memory Fabrics at $(date)"