oci compute image list   --compartment-id ocid1.compartment.oc1..aaaaaaaaycgwyl3ud3iqn5tpz2txhtfc5i5jikurgicfyo6vgx34x3kijlva   --all --query "data[?contains(\"display-name\",'OFED')].{Compartment_ocid: \"compartment-id\", operating_system: \"operating-system\", os_ver: \"operating-system-version\", display_name: \"display-name\"}"   --output table

oci compute image list   --compartment-id ocid1.compartment.oc1..aaaaaaaaycgwyl3ud3iqn5tpz2txhtfc5i5jikurgicfyo6vgx34x3kijlva   --all --query "data[?contains(\"display-name\",'OFED')].{Compartment_ocid: \"compartment-id\", operating_system: \"operating-system\", os_ver: \"operating-system-version\", display_name: \"display-name\"}"   --output table

oci compute image list   --compartment-id ocid1.compartment.oc1..aaaaaaaaycgwyl3ud3iqn5tpz2txhtfc5i5jikurgicfyo6vgx34x3kijlva   --all --query "data[?contains(\"display-name\",'GPU')].{Compartment_ocid: \"compartment-id\", operating_system: \"operating-system\", os_ver: \"operating-system-version\", display_name: \"display-name\", image_id: \"id\"}"   --output table

#Set OCI_TENANCY
OCI_TENANCY=`curl -sH "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/ | jq -r .tenantId`

#List OCI Regions
oci iam region list --query "data[?contains(name,'jeddah')]" --output table

#list GPU and Linux images in the tenancy to find image id easily.
oci compute image list   --compartment-id $OCI_TENANCY   --all --query "data[?contains(\"display-name\",'GPU') && contains(\"display-name\",'Linux')].{Compartment_ocid: \"compartment-id\", operating_system: \"operating-system\", os_ver: \"operating-system-version\", display_name: \"display-name\", image_id: \"id\"}"  --region me-jeddah-1 --output table

#list specific image with certain shape values
oci compute image-shape-compatibility-entry list --image-id <image_id> --query "data[?contains(shape,'MI300X')]"
oci compute image-shape-compatibility-entry list --image-id ocid1.image.oc1.phx.aaaaaaaalebw6ni657v57gtjnxkztzvvomwckzqrvkodxh22czeiscgdqkhq --query "data[?contains(shape,'MI300X')]"

oci compute image list   --compartment-id ocid1.compartment.oc1..aaaaaaaaycgwyl3ud3iqn5tpz2txhtfc5i5jikurgicfyo6vgx34x3kijlva   --all --query "data[?\"compartment-id\" != null].{Compartment_ocid: \"compartment-id\", operating_system: \"operating-system\", os_ver: \"operating-system-version\", display_name: \"display-name\"}"   --output table

COMPARTMENT_NAME="TimCowen"
NODE_POOL_NAME="gpu"
COMP_ID=ocid1.compartment.oc1..aaaaaaaaycgwyl3ud3iqn5tpz2txhtfc5i5jikurgicfyo6vgx34x3kijlva
CLUSTER_ID=ocid1.cluster.oc1.iad.aaaaaaaap7ooarfltqxqo33gubggh7vv6lk23sjf7vj6g6xcjcgi5a467ugq
NODE_POOL_ID=ocid1.nodepool.oc1.iad.aaaaaaaapippgjosblzpc6mojlkb5jmxcv7wyci3yvtj46zl4ne32voun4qa
INSTANCE_ID=ocid1.instance.oc1.iad.anuwcljtemfnr4qc4ktb6zkj2hgmlmsjg6vaducqvkl5cvblcfj7xdcs425q

# Search for specific compartment name for ocid
oci iam compartment list --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --lifecycle-state ACTIVE --query "data[?contains(name,'$COMPARTMENT_NAME')].{name: name, description: description, Compartment_ocid: \"compartment-id\"}" --output table

#query to find the oke clusters in compartment with the ocids, replace compartment-id with yours
oci ce cluster list --compartment-id $COMP_ID  --query "data[*].{name:name, id:id, "lifecycle_state": \"lifecycle-state\", "kubernetes_ver": \"kubernetes-version\"}" --output table

#query to find the nodepool for the cluster in compartment, replace gpu with nodepool name
oci ce node-pool list --cluster-id $CLUSTER_IP --compartment-id $COMP_ID --query "data[?contains(name, '$NODE_POOL_NAME')].{name:name, kube_ver: \"kubernetes-version\", availability_domain:\"node-config-details\".\"placement-configs\"[0].\"availability-domain\", cluster_autoscaler:\"freeform-tags\".cluster_autoscaler, nodepool_ocid:id, node_image:\"node-image-name\", node_shape:\"node-shape\", node_shape_config:\"node-shape-config\", cni_type:\"node-config-details\".\"node-pool-pod-network-option-details\".\"cni-type\"}" --output table

oci ce node-pool list --cluster-id ocid1.cluster.oc1.iad.aaaaaaaaanc7lzbjfilmozzxdgl6tblbqttoxuejlzessizvlct4yaqt562q --compartment-id ocid1.compartment.oc1..aaaaaaaa2h666ekv6ifhdewgxs2m36xkb6lwceyuudhf6r3mbpskfzzgtpzq --query "data[?contains(name, 'gpu-cluster')].{name:name, kube_ver: \"kubernetes-version\", availability_domain:\"node-config-details\".\"placement-configs\"[0].\"availability-domain\", cluster_autoscaler:\"freeform-tags\".cluster_autoscaler, nodepool_ocid:id, node_image:\"node-image-name\", node_shape:\"node-shape\", node_shape_config:\"node-shape-config\", cni_type:\"node-config-details\".\"node-pool-pod-network-option-details\".\"cni-type\"}" --output table

oci ce node-pool get --node-pool-id $NODE_POOL_ID --query "data.nodes[?contains(id, '$INSTANCE_ID')]"


 name, node-config-details  pool, role, cluster_autoscaler, id, node-shape, node-source

ocid1.nodepool.oc1.iad.aaaaaaaapippgjosblzpc6mojlkb5jmxcv7wyci3yvtj46zl4ne32voun4qa

#query cluster for work-requests
oci ce work-request list --compartment-id $COMP_ID --query "data[?contains(\"operation-type\", '')].{id:id,status:status,time_started:\"time-started\",resources:resources}" --output table

#query cluster for addons and version
oci ce cluster-addon list --cluster-id $COMP_ID

oci ce addon-option list --kubernetes-version v1.32.1 --query "data[?contains(name, 'NvidiaGpuPlugin')].{name: name, ver_num: versions[0].\"version-number\", lifecycle_state: \"lifecycle-state\", status: versions[0].status}" --output table


#query for work requests on cluster
oci work-requests work-request list --compartment-id ocid1.compartment.oc1..aaaaaaaaycgwyl3ud3iqn5tpz2txhtfc5i5jikurgicfyo6vgx34x3kijlva --resource-id ocid1.cluster.oc1.iad.aaaaaaaap7ooarfltqxqo33gubggh7vv6lk23sjf7vj6g6xcjcgi5a467ugq --query "data[*].{id:id,operation:\"operation-type\",status:status,\"time-started\":\"time-started\"}" --output table


kubectl get 

kubectl get nodes -o json | jq '[.items[] | [.metadata.labels.hostname, .metadata.labels["node.info/compartment.id"], .spec.providerID, .spec.taints] | contains ("present")]'

kubectl get nodes -o json | jq '.items[] | select(.metadata.labels.hostname == "oke-cgi5a467ugq-nn26zyatswq-shdrsyygoua-0") | {name: .metadata.name, hostname: .metadata.labels.hostname, compartment: .metadata.labels["node.info/compartment.id"]}'

oci ce node-pool-options get --node-pool-option-id all |   jq '.. | objects | select(has("source-name")) | select(."source-name" | contains("1.34"))'

oci compute instance get --instance-id $INSTANCE_ID

oci --region us-phoenix-1 compute capacity-topology bare-metal-host list --capacity-topology-id <...> --query "data[?contains(lifecycle-state, 'Available']"

oci --region us-phoenix-1 compute capacity-topology bare-metal-host list --capacity-topology-id <...> --query "data[?contains(compute-network-block-id, '']"

oci compute instance list --compartment-id ocid1.compartment.oc1..aaaaaaaaq6c6fs2yk7z7gb4gxousnsf5dmuwjl2rzpwenjucnfunqtp6wufa  --auth instance_principal --output table --query "data[].{shape: shape, lifecycle: \"lifecycle-state\", display: \"display-name\"}"
oci compute-management cluster-network list --compartment-id ocid1.compartment.oc1..aaaaaaaaq6c6fs2yk7z7gb4gxousnsf5dmuwjl2rzpwenjucnfunqtp6wufa --auth instance_principal --output table --query "data[].{display:\"display-name\",instancepool:\"instance-pools\",lifecycle:\"lifecycle-state\"}"

oci ce cluster disable-addon --cluster-id <cluster-id> --addon-name NvidiaGpuPlugin

#to get capacity vs allocatable on a node
k get node 10.240.32.198 -o=yaml | grep -A 6 -B7 capacity

 k get pods --show-labels -o wide

k get pods -A --field-selector spec.nodeName=

 k logs -l apps.kubernetes.io/pod-index=0

 k exec odyssey-lr-1e4-0 - bash

#Pull Console history for a running instance
REGION=sa-saopaulo-1
INSTANCE_OCID=ocid1.instance.oc1.sa-saopaulo-1.antxeljr2bemolacy3wgcy4pj6yqrjzxlnnqavrluq2uwaxq5k2quq3cynta
CONSOLE_HISTORY_ID=$(oci --region $REGION compute console-history capture --instance-id $INSTANCE_OCID | jq -r '.data.id')
oci compute console-history get-content --instance-console-history-id $CONSOLE_HISTORY_ID --length 10000000 --file -
