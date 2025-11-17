#How to generate an ssh key from the command line
ssh-keygen -t rsa -N "" -b 2048 -C "tc-keys" -f "C:\Users\Tim Cowen\OneDrive - Oracle Corporation\FY26-TCOWEN-Z1126313H\ssh-keys\tcowen_key"

#Check Instance details
curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance

#Check instance metadata
curl -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/metadata/

#Check the host of the instance
curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/host

#Check if oci cli is working
oci os ns get --auth instance_principal

#Get compartment id of instance
curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/ | jq -r .compartmentId

#Get the instance name of the gpu node
gpunode=gpu-87
j=`cat /etc/hosts | grep -i $gpunode | grep .local.vcn | awk '{print $4}'`
echo $j

#Get compartmentid
comp_id=`curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/ | jq -r .compartmentId`

#Get ocid of instance running
oci compute instance list --compartment-id ${comp_id} --display-name ${j} --auth instance_principal | jq -r .data[0].id

#Get the serial number of the GPU
sudo dmidecode -s system-serial-number ; nvidia-smi -L ; lspci | grep "rev ff"

#Create a cluster
#create_cluster.sh <# of GPUs to Add> <GPU name in the queues.conf> <HPC-Default under instance_types in queues.conf> <partition> <enable debug logging> <-DEBUG -- turned on to keep the GPUs, if this and the enable debugging logging isnt passed, GPUS will be recycled on failure.>
/opt/oci-hpc/bin/create_cluster.sh 2 a100-aphx02-01 hpc-default compute 0 -DEBUG

#Check the prior runs on the slurm queue
sacct -a --format=JobID,JobName,User,Partition,State,ExitCode,AllocCPUS,Elapsed,MaxRSS,Start,End

#Investigate details of a job run
scontrol show job <id>

#investigate details of a node
scontrol show node <node>

#Investigate details of a job run
sacct -j <jobid> --format=JobID,JobName,AllocCPUs,AllocTRES,Elapsed,State,Exitcode

#Investigate details of a job run
sacct -j 29 --long

#Add a node to the slurm cluster
nohup /opt/oci-hpc/bin/resize.sh add 3 --cluster_name h100-ord01-03 > ~/tc/add.log 2>&1 &
 tail -n 250 /opt/oci-hpc/logs/resize*.log

#Drain a slurm node
sudo scontrol update nodename=h100-ord01-03-636 state=drain
sudo scontrol update nodename=<name> state=drain reason="TC TEST "

#Slurm States
    State 
        Idle - nodes are ready to receive a job
        Alloc -- allocated for job to run
        Mix - multiple jobs are running on it
        Drain -- taken out of rotation, you have to change the state by resuming


#Use to understand the reason for draining
sinfo -R

#To update node state
sudo scontrol update nodename=<name> state=resume
    H100-ord01-03-[629,222,1,22]
Where [629,222,1,22] can be multiple at the same time

#grab all the nodes in the cluster
sinfo -Neh -p compute | awk '{print $1}'| sort -t- -k 4 -n > ~/tc/gf_inventory

#tag a node unhealth - 
python ~/oracle_health_checks/tag-unhealthy.py --instance-id

#Remove a node from the slurm cluster
nohup /opt/oci-hpc/bin/resize.sh remove_unreachable --nodes inst-09bgn-h100-ord01-03 --cluster_name h100-ord01-03 --quiet > ~/tc/terminate.log 2>&1 &
nohup /opt/oci-hpc/bin/resize.sh remove_unreachable --nodes inst-xa9gz-h100-ord01-03 --cluster_name h100-ord01-03 --quiet > ~/tp/terminate.log 2>&1 &
tail -n 250 /opt/oci-hpc/logs/resize*.log

nvidia-smi topo -m
ubuntu@GPU-87:~$ nvidia-smi topo -m
        GPU0    GPU1    GPU2    GPU3    GPU4    GPU5    GPU6    GPU7    NIC0    NIC1    NIC2    NIC3    NIC4    NIC5    NIC6    NIC7    NIC8    NIC9    NIC10   NIC11   NIC12   NIC13   NIC14   NIC15   NIC16   NIC17   CPU Affinity    NUMA Affinity   GPU NUMA ID
GPU0     X      NV12    NV12    NV12    NV12    NV12    NV12    NV12    SYS     SYS     SYS     SYS     SYS     PXB     PXB     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     48-63   3               N/A
GPU1    NV12     X      NV12    NV12    NV12    NV12    NV12    NV12    SYS     SYS     SYS     SYS     SYS     PXB     PXB     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     48-63   3               N/A
GPU2    NV12    NV12     X      NV12    NV12    NV12    NV12    NV12    SYS     PXB     PXB     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     16-31   1               N/A
GPU3    NV12    NV12    NV12     X      NV12    NV12    NV12    NV12    SYS     PXB     PXB     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     16-31   1               N/A
GPU4    NV12    NV12    NV12    NV12     X      NV12    NV12    NV12    SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB     PXB     PXB     112-127 7               N/A
GPU5    NV12    NV12    NV12    NV12    NV12     X      NV12    NV12    SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB     PXB     PXB     112-127 7               N/A
GPU6    NV12    NV12    NV12    NV12    NV12    NV12     X      NV12    SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB     PXB     PXB     SYS     SYS     SYS     SYS     SYS     80-95   5               N/A
GPU7    NV12    NV12    NV12    NV12    NV12    NV12    NV12     X      SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB     PXB     PXB     SYS     SYS     SYS     SYS     SYS     80-95   5               N/A
NIC0    SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS      X      SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS
NIC1    SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS      X      PIX     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS
NIC2    SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS     PIX      X      PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS
NIC3    SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS     PXB     PXB      X      PIX     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS
NIC4    SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS     PXB     PXB     PIX      X      SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS
NIC5    PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS      X      PIX     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS
NIC6    PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PIX      X      PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS
NIC7    PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB      X      PIX     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS
NIC8    PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB     PIX      X      SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS
NIC9    SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS      X      PIX     PXB     PXB     SYS     SYS     SYS     SYS     SYS
NIC10   SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PIX      X      PXB     PXB     SYS     SYS     SYS     SYS     SYS
NIC11   SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB      X      PIX     SYS     SYS     SYS     SYS     SYS
NIC12   SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB     PIX      X      SYS     SYS     SYS     SYS     SYS
NIC13   SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS      X      SYS     SYS     SYS     SYS
NIC14   SYS     SYS     SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS      X      PIX     PXB     PXB
NIC15   SYS     SYS     SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PIX      X      PXB     PXB
NIC16   SYS     SYS     SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB      X      PIX
NIC17   SYS     SYS     SYS     SYS     PXB     PXB     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     SYS     PXB     PXB     PIX      X

Legend:

  X    = Self
  SYS  = Connection traversing PCIe as well as the SMP interconnect between NUMA nodes (e.g., QPI/UPI)
  NODE = Connection traversing PCIe as well as the interconnect between PCIe Host Bridges within a NUMA node
  PHB  = Connection traversing PCIe as well as a PCIe Host Bridge (typically the CPU)
  PXB  = Connection traversing multiple PCIe bridges (without traversing the PCIe Host Bridge)
  PIX  = Connection traversing at most a single PCIe bridge
  NV#  = Connection traversing a bonded set of # NVLinks

NIC Legend:

  NIC0: mlx5_0
  NIC1: mlx5_1
  NIC2: mlx5_2
  NIC3: mlx5_3
  NIC4: mlx5_4
  NIC5: mlx5_5
  NIC6: mlx5_6
  NIC7: mlx5_7
  NIC8: mlx5_8
  NIC9: mlx5_9
  NIC10: mlx5_10
  NIC11: mlx5_11
  NIC12: mlx5_12
  NIC13: mlx5_13
  NIC14: mlx5_14
  NIC15: mlx5_15
  NIC16: mlx5_16
  NIC17: mlx5_17
