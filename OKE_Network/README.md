# OKE VCN Network Stack

Oracle Cloud Infrastructure (OCI) Terraform configuration for creating a complete Virtual Cloud Network (VCN) optimized for Oracle Kubernetes Engine (OKE) clusters with GPU workloads.

## Overview

This Terraform stack creates a production-ready VCN with:
- **Comprehensive subnet architecture** for OKE components
- **Network Security Groups (NSGs)** with granular security rules
- **Gateway configuration** (Internet, NAT, Service, optional DRG)
- **Flexible subnet options** for various use cases
- **Resource Manager integration** with user-friendly UI

## Architecture

### Network Components

```
VCN (10.140.0.0/16)
├── Control Plane Subnet (/29)     - Kubernetes API Server (PUBLIC by default)
├── Workers Subnet (/20)            - Kubernetes worker nodes (PRIVATE)
├── Pods Subnet (/18)               - VCN-native pod networking (PRIVATE)
├── Internal LB Subnet (/21)        - Private load balancers (PRIVATE)
├── Public LB Subnet (/21)          - Internet-facing load balancers (PUBLIC, optional)
├── Bastion Subnet (/29)            - SSH jump host (PUBLIC, optional)
├── Operator Subnet (/29)           - Admin/CI-CD access (PRIVATE, optional)
├── FSS Subnet (/21)                - File Storage Service (PRIVATE, optional)
└── Lustre Subnet (/23)             - Lustre filesystem (PRIVATE, optional)
```

### Gateways

- **Internet Gateway**: Public subnet internet access (configurable)
- **NAT Gateway**: Private subnet outbound internet access (always created)
- **Service Gateway**: Private access to OCI services (always created)
- **Dynamic Routing Gateway (DRG)**: Hybrid cloud connectivity via VPN/FastConnect (optional)

### Network Security Groups

Each subnet has an associated NSG with specific security rules:
- **Control Plane NSG**: API server access (port 6443)
- **Workers NSG**: Kubelet, NodePort services, inter-node communication
- **Pods NSG**: Pod-to-pod and pod-to-service networking
- **Load Balancer NSGs**: Health checks and backend traffic
- **FSS NSG**: NFS traffic for shared storage

## File Structure

```
.
├── main.tf              - VCN, DRG, and random generators
├── variables.tf         - Input variable definitions
├── provider.tf          - OCI provider configuration
├── subnets.tf          - All subnet resources
├── nsgs.tf             - Network Security Group definitions
├── nsg_rules.tf        - NSG security rules (ingress/egress)
├── security_lists.tf   - Security list configurations
├── outputs.tf          - Output values and NSG summary
├── policies.tf         - IAM policies for OKE nodes
├── schema.yaml         - Resource Manager UI schema
└── README.md           - This file
```

## Prerequisites

- OCI account with appropriate permissions
- Compartment for network resources
- Understanding of OKE networking requirements

## Quick Start

### Using OCI Resource Manager

1. **Create Stack**:
   - Navigate to Resource Manager > Stacks
   - Click "Create Stack"
   - Upload this folder as a .zip file

2. **Configure Variables**:
   - **VCN Name**: Custom name for your VCN
   - **VCN CIDR**: Default is 10.140.0.0/16
   - **Compartment**: Select target compartment
   - **Gateways**: Enable/disable Internet Gateway, DRG
   - **Subnets**: Choose which optional subnets to create

3. **Deploy**:
   - Review plan
   - Apply configuration
   - View NSG summary in Application Information

### Using Terraform CLI

```bash
# Initialize Terraform
terraform init

# Review the plan
terraform plan

# Apply the configuration
terraform apply

# View outputs
terraform output nsg_configuration_summary
```

## Configuration Options

### Core VCN Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `vcn_display_name` | `oke-gpu-quickstart` | VCN display name |
| `vcn_cidrs` | `10.140.0.0/16` | VCN CIDR blocks |
| `create_vcn` | `true` | Whether to create VCN |

### Gateway Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `create_public_subnets` | `true` | Create public subnets |
| `create_internet_gateway` | `true` | Create Internet Gateway |
| `create_drg` | `false` | Create Dynamic Routing Gateway |

### Subnet Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `create_bastion_subnet` | `true` | Create bastion subnet (independent) |
| `create_operator_subnet` | `true` | Create operator subnet (independent) |
| `create_fss_subnet` | `true` | Create FSS subnet |
| `create_lustre_subnet` | `false` | Create Lustre subnet |

**Note**: Bastion and Operator subnets are now **independent** of the `create_public_subnets` flag. They will automatically ensure an Internet Gateway is created when enabled.

### Display Name Customization

Each subnet supports custom display names:

| Variable | Default | Example Custom Value |
|----------|---------|---------------------|
| `bastion_subnet_name` | `bastion-{state_id}` | `prod-bastion` |
| `operator_subnet_name` | `operator-{state_id}` | `prod-operator` |
| `cp_subnet_name` | `cp-{state_id}` | `prod-k8s-control` |
| `workers_subnet_name` | `workers-{state_id}` | `prod-k8s-workers` |
| `pods_subnet_name` | `pods-{state_id}` | `prod-k8s-pods` |
| `int_lb_subnet_name` | `int_lb-{state_id}` | `prod-internal-lb` |
| `pub_lb_subnet_name` | `pub_lb-{state_id}` | `prod-public-lb` |
| `fss_subnet_name` | `fss-{state_id}` | `prod-file-storage` |
| `lustre_subnet_name` | `lustre-{state_id}` | `prod-lustre` |

### Advanced Settings

- **Custom CIDR Blocks**: Override auto-calculated subnet CIDRs
- **DNS Labels**: Enable/disable DNS labels for VCN and subnets
- **Security Lists**: Lock down default security list
- **Custom Route Rules**: Add custom routes for gateways
- **Reserved NAT IP**: Use reserved public IP for NAT gateway

## Custom Subnet CIDRs

Each subnet can use either auto-calculated or custom CIDR blocks:

### Auto-Calculated (Default)

When no custom CIDR is specified, subnets are automatically sized from the VCN CIDR:

```
VCN: 10.140.0.0/16
├── Control Plane:  10.140.0.0/29    (8 IPs)
├── Bastion:        10.140.0.8/29    (8 IPs)
├── Operator:       10.140.0.16/29   (8 IPs)
├── Int LB:         10.140.32.0/21   (2,048 IPs)
├── Pub LB:         10.140.40.0/21   (2,048 IPs)
├── FSS:            10.140.48.0/21   (2,048 IPs)
├── Workers:        10.144.0.0/20    (4,096 IPs)
├── Pods:           10.160.0.0/18    (16,384 IPs)
└── Lustre:         10.140.128.0/23  (512 IPs)
```

### Custom CIDRs

Enable "Subnets advanced settings" in Resource Manager to specify custom CIDRs:

**Via Resource Manager UI:**
1. Check "Subnets advanced settings"
2. Specify custom CIDRs for any subnet (leave blank to auto-calculate)

**Via Terraform CLI:**
```hcl
# terraform.tfvars
subnets_advanced_settings = true
bastion_subnet_cidr       = "10.140.1.0/28"
operator_subnet_cidr      = "10.140.1.16/28"
cp_subnet_cidr            = "10.140.2.0/29"
workers_subnet_cidr       = "10.140.8.0/22"
pods_subnet_cidr          = "10.142.0.0/17"
int_lb_subnet_cidr        = "10.140.4.0/24"
pub_lb_subnet_cidr        = "10.140.5.0/24"
fss_subnet_cidr           = "10.140.6.0/24"
lustre_subnet_cidr        = "10.140.7.0/24"
```

**CIDR Rules:**
- Must be valid RFC 1918 private IP ranges
- Must not overlap with other subnets in the VCN
- Must be within the VCN CIDR range
- Netmask must be /16 to /30

**Benefits:**
- Align with existing IP addressing schemes
- Reserve specific IP ranges for future use
- Optimize for specific workload requirements
- Match corporate network standards

## Network Security

### Security Model

This stack uses **Network Security Groups (NSGs)** instead of Security Lists for:
- Stateful firewall rules (return traffic automatically allowed)
- Resource-level security (attach NSGs to specific resources)
- Easier management and troubleshooting

### Key Traffic Flows

#### Control Plane Communication
- Workers → Control Plane: TCP 6443 (kubectl, API)
- Pods → Control Plane: TCP 6443 (in-cluster API)
- Control Plane → Workers: TCP 10250 (kubelet)

#### Worker Node Communication
- Worker ↔ Worker: All protocols (pod networking)
- Workers: NodePort range 30000-32767
- ICMP Type 3 Code 4 (path MTU discovery)

#### Load Balancer Traffic
- Load Balancers → Workers: Health checks + backend
- Workers → Load Balancers: Return traffic

#### Storage Access
- Workers/Pods → FSS: NFS (ports 111, 2048-2050)
- Workers/Pods → Lustre: Lustre protocol

## Outputs

### Standard Outputs

The stack provides OCIDs and CIDRs for all created resources:

**Network Resources:**
- VCN and gateway IDs
- Route table IDs
- DRG ID and attachment ID (if created)

**Subnet Information:**
- Subnet IDs for each subnet
- **Subnet CIDR blocks for each subnet** (NEW)
  - `bastion_subnet_cidr`
  - `operator_subnet_cidr`
  - `cp_subnet_cidr`
  - `workers_subnet_cidr`
  - `pods_subnet_cidr`
  - `int_lb_subnet_cidr`
  - `pub_lb_subnet_cidr`
  - `fss_subnet_cidr`
  - `lustre_subnet_cidr`

**Security Resources:**
- NSG IDs for each security group
- IAM policy IDs (if created)

### NSG Configuration Summary

A formatted summary showing:
- VCN name and CIDR
- Each NSG with its associated subnet name and CIDR
- Public/Private designation for each subnet

View in Resource Manager "Application Information" page after deployment.

## Best Practices

### CIDR Planning

- **Default VCN CIDR**: 10.140.0.0/16 provides 65,536 IPs
- **Pods Subnet**: Large /18 (16,384 IPs) for high pod density
- **Workers Subnet**: /20 (4,096 IPs) for worker node scaling
- **Load Balancer Subnets**: /21 (2,048 IPs) each for LB scaling

### Security Considerations

1. **Control plane is public by default** for easier access - set `control_plane_is_public = false` for production
2. **Use bastion for SSH access** to private resources
3. **Operator subnet is private** - uses NAT gateway for outbound access
4. **Minimize public subnets** - only LB if needed
5. **Review NSG rules** before production deployment
6. **Enable DRG** only if hybrid connectivity required

### OKE Integration

This VCN is designed to work with OKE clusters using:
- **VCN-native pod networking** (pods subnet)
- **Public control plane by default** for easier initial setup
- **Private worker nodes** for security
- **Network policies** via NSGs
- **Load balancers** for service exposure

**Production Tip**: Set `control_plane_is_public = false` for enhanced security in production environments.

## Troubleshooting

### Common Issues

**Issue**: Terraform errors about missing subnets
- **Solution**: Check subnet creation flags in variables

**Issue**: NSG rules not appearing
- **Solution**: Verify NSGs were created (check optional subnet flags)

**Issue**: Can't access control plane
- **Solution**: Check if control plane is public, verify NSG rules

**Issue**: Pods can't reach internet
- **Solution**: Verify NAT gateway is created and route table is correct

### Validation

```bash
# Check VCN resources
oci network vcn list --compartment-id <compartment_ocid>

# List subnets
oci network subnet list --compartment-id <compartment_ocid> --vcn-id <vcn_ocid>

# View NSG rules
oci network nsg rules list --nsg-id <nsg_ocid>

# Test connectivity (from bastion)
ping <worker_node_private_ip>
curl -k https://<control_plane_endpoint>:6443
```

## Customization

### Custom Display Names for Subnets

You can customize the display names of any subnet to match your naming conventions:

**Via Terraform Variables:**
```hcl
# terraform.tfvars
cp_subnet_name      = "prod-k8s-control-plane"
workers_subnet_name = "prod-k8s-worker-nodes"
pods_subnet_name    = "prod-k8s-pod-network"
bastion_subnet_name = "prod-bastion-jump"
```

**Via Environment Variables:**
```bash
export TF_VAR_workers_subnet_name="prod-k8s-workers"
export TF_VAR_pods_subnet_name="prod-k8s-pods"
```

**Benefits:**
- Align with corporate naming standards
- Improve clarity in multi-environment deployments
- Easier identification in OCI console
- Better integration with monitoring tools

### Modifying Subnet CIDRs

The easiest way to customize subnet CIDRs is through the Resource Manager UI:

**Method 1: Resource Manager UI (Recommended)**
1. When creating/editing the stack, check **"Subnets advanced settings"**
2. Enter custom CIDRs in the text fields that appear
3. Leave any field blank to use auto-calculated CIDR for that subnet
4. Apply the stack

**Method 2: Terraform Variables**
Create or edit `terraform.tfvars`:
```hcl
# Enable advanced subnet settings
subnets_advanced_settings = true

# Specify only the subnets you want to customize
# Omit variables to use auto-calculated CIDRs
workers_subnet_cidr = "10.140.10.0/22"   # Larger worker subnet
pods_subnet_cidr    = "10.142.0.0/17"    # Larger pod subnet
cp_subnet_cidr      = "10.140.2.0/29"    # Control plane
```

**Method 3: Environment Variables**
```bash
export TF_VAR_workers_subnet_cidr="10.140.10.0/22"
export TF_VAR_pods_subnet_cidr="10.142.0.0/17"
terraform apply
```

### Adding Custom NSG Rules

Edit `nsg_rules.tf` to add additional security rules:

```hcl
resource "oci_core_network_security_group_security_rule" "custom_rule" {
  network_security_group_id = local.workers_nsg_id
  direction                 = "INGRESS"
  protocol                  = "6"  # TCP
  source                    = "10.0.0.0/24"
  source_type               = "CIDR_BLOCK"
  description               = "Allow custom application traffic"
  
  tcp_options {
    destination_port_range {
      min = 8080
      max = 8080
    }
  }
}
```

## Support and Contributing

### Getting Help

- **OCI Documentation**: https://docs.oracle.com/en-us/iaas/Content/ContEng/home.htm
- **Terraform OCI Provider**: https://registry.terraform.io/providers/oracle/oci/latest/docs

### Version Information

- **Terraform**: >= 1.0
- **OCI Provider**: ~> 5.0
- **VCN Module**: 3.6.0

## License

Copyright (c) 2025 Oracle Corporation and/or its affiliates.
Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl

## Changelog

### v20250204 - Enhanced Flexibility Update
- **CHANGED**: Control plane subnet is now PUBLIC by default (can be set to private)
- **CHANGED**: Operator subnet is now PRIVATE (uses NAT gateway)
- **NEW**: Bastion and Operator subnets are now independent of public subnet flag
- **NEW**: Custom display names for all subnets
- **NEW**: CIDR block outputs for all subnets
- **NEW**: Prepopulated display names and CIDRs in UI
- **NEW**: Grouped subnet configurations (name + CIDR together)
- Fixed vcn_display_name variable handling
- Added Internet Gateway configuration checkbox
- Added Dynamic Routing Gateway (DRG) support
- Added subnet creation checkboxes (bastion, operator, FSS, Lustre)
- Added comprehensive NSG configuration summary output
- Changed operator and FSS subnet defaults to true
- Added comprehensive inline documentation and comments
- Created README and CIDR reference documentation

---

**Note**: This stack creates a complete network infrastructure for OKE. Review and adjust security rules, CIDR blocks, and optional components based on your specific requirements before deploying to production.
