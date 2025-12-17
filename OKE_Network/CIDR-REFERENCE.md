# Subnet CIDR Reference Guide

## Quick Reference: Default Subnet Allocations

When using the default VCN CIDR `10.140.0.0/16`, subnets are automatically allocated as follows:

| Subnet | CIDR | IPs Available | Size | Purpose |
|--------|------|---------------|------|---------|
| Control Plane | `10.140.0.0/29` | 8 | Smallest | Kubernetes API server |
| Bastion | `10.140.0.8/29` | 8 | Smallest | SSH jump host |
| Operator | `10.140.0.16/29` | 8 | Smallest | Admin/CI-CD access |
| Internal LB | `10.140.32.0/21` | 2,048 | Large | Private load balancers |
| Public LB | `10.140.40.0/21` | 2,048 | Large | Internet-facing LBs |
| FSS | `10.140.48.0/21` | 2,048 | Large | File Storage Service |
| Lustre | `10.140.128.0/23` | 512 | Medium | Lustre filesystem |
| Workers | `10.144.0.0/20` | 4,096 | Very Large | Kubernetes nodes |
| Pods | `10.160.0.0/18` | 16,384 | Huge | Pod IP addresses |

## CIDR Calculation Formula

Subnets are calculated using Terraform's `cidrsubnet()` function:
```
cidrsubnet(base_cidr, newbits, netnum)
```

Where:
- `base_cidr` = VCN CIDR (e.g., 10.140.0.0/16)
- `newbits` = How many bits to add to the netmask
- `netnum` = Network number (offset)

### Examples from Default Configuration

```hcl
# Control Plane: 10.140.0.0/29
cidrsubnet("10.140.0.0/16", 13, 0)  # /16 + 13 = /29, offset 0

# Bastion: 10.140.0.8/29  
cidrsubnet("10.140.0.0/16", 13, 1)  # /16 + 13 = /29, offset 1

# Workers: 10.144.0.0/20
cidrsubnet("10.140.0.0/16", 4, 2)   # /16 + 4 = /20, offset 2

# Pods: 10.160.0.0/18
cidrsubnet("10.140.0.0/16", 2, 2)   # /16 + 2 = /18, offset 2
```

## Subnet Sizing Guide

Choose subnet sizes based on expected resource counts:

### Netmask to IP Count

| CIDR | Netmask | Total IPs | Usable IPs* | Best For |
|------|---------|-----------|-------------|----------|
| /29 | 255.255.255.248 | 8 | 5 | Control plane, bastion |
| /28 | 255.255.255.240 | 16 | 13 | Small admin subnets |
| /27 | 255.255.255.224 | 32 | 29 | Small subnets |
| /24 | 255.255.255.0 | 256 | 251 | Standard subnet |
| /23 | 255.255.254.0 | 512 | 507 | Medium subnet |
| /22 | 255.255.252.0 | 1,024 | 1,019 | Large subnet |
| /21 | 255.255.248.0 | 2,048 | 2,043 | Load balancers |
| /20 | 255.255.240.0 | 4,096 | 4,091 | Worker nodes |
| /19 | 255.255.224.0 | 8,192 | 8,187 | Very large |
| /18 | 255.255.192.0 | 16,384 | 16,379 | Pods |
| /17 | 255.255.128.0 | 32,768 | 32,763 | Extra large pods |

\* Usable IPs = Total IPs - 5 (OCI reserves first 3 and last 2 IPs per subnet)

## Common Customization Scenarios

### Scenario 1: Larger Worker Node Pool

**Need**: 100+ worker nodes with room for growth

**Default**: 10.144.0.0/20 (4,096 IPs)  
**Custom**: 10.144.0.0/19 (8,192 IPs)

```hcl
workers_subnet_cidr = "10.144.0.0/19"
```

### Scenario 2: High Pod Density for AI/ML

**Need**: 50,000+ concurrent pods for large-scale GPU training

**Default**: 10.160.0.0/18 (16,384 IPs)  
**Custom**: 10.160.0.0/17 (32,768 IPs)

```hcl
pods_subnet_cidr = "10.160.0.0/17"
```

### Scenario 3: Multiple Load Balancers

**Need**: Many public-facing services with dedicated LBs

**Default**: 10.140.40.0/21 (2,048 IPs)  
**Custom**: 10.140.40.0/20 (4,096 IPs)

```hcl
pub_lb_subnet_cidr = "10.140.40.0/20"
```

### Scenario 4: Compact Deployment

**Need**: Minimal subnet sizes to conserve VCN IP space

```hcl
bastion_subnet_cidr  = "10.140.0.0/28"    # 16 IPs instead of 8
operator_subnet_cidr = "10.140.0.16/28"   # 16 IPs instead of 8
int_lb_subnet_cidr   = "10.140.1.0/24"    # 256 IPs instead of 2,048
pub_lb_subnet_cidr   = "10.140.2.0/24"    # 256 IPs instead of 2,048
fss_subnet_cidr      = "10.140.3.0/24"    # 256 IPs instead of 2,048
workers_subnet_cidr  = "10.140.16.0/22"   # 1,024 IPs instead of 4,096
pods_subnet_cidr     = "10.140.32.0/19"   # 8,192 IPs instead of 16,384
```

## Best Practices

### 1. Plan for Growth
Always provision 2-3x more IPs than your current need:
- **Workers**: Plan for cluster scaling events
- **Pods**: Consider max pods per node × max nodes
- **Load Balancers**: Account for blue-green deployments

### 2. Avoid Overlaps
Use a CIDR calculator to verify no subnet overlaps:
```bash
# Example using ipcalc
ipcalc 10.140.0.0/29    # Control plane
ipcalc 10.140.0.8/29    # Bastion (no overlap)
```

### 3. Reserve Space
Leave gaps in your addressing for future subnets:
```
10.140.0.0/24   - Reserved for small admin subnets
10.140.1.0/24   - Reserved for future use
10.140.8.0/21   - Reserved for future services
```

### 4. Document Your Scheme
Keep a record of your CIDR allocations:
```
# cidr-allocation.txt
VCN:          10.140.0.0/16
Control:      10.140.0.0/29
Bastion:      10.140.0.8/29
Workers:      10.144.0.0/20
Pods:         10.160.0.0/18
Reserved:     10.140.1.0-10.140.7.255
```

## Validation Commands

### Verify Subnet Creation
```bash
# List all subnets in VCN
oci network subnet list \
  --compartment-id <compartment_ocid> \
  --vcn-id <vcn_ocid> \
  --query 'data[*].{Name:"display-name",CIDR:"cidr-block"}' \
  --output table
```

### Check for CIDR Conflicts
```bash
# Get all subnet CIDRs
oci network subnet list \
  --compartment-id <compartment_ocid> \
  --vcn-id <vcn_ocid> \
  --query 'data[*]."cidr-block"' \
  --output json
```

### Calculate Available IPs
```bash
# For a given CIDR, calculate usable IPs
# Example: /20 = 2^(32-20) - 5 = 4091 usable IPs
```

## Troubleshooting

### Error: CIDR Block Overlaps
**Problem**: Subnets cannot have overlapping CIDR ranges

**Solution**: 
1. Review all custom CIDRs for overlaps
2. Use online CIDR calculator
3. Adjust conflicting subnet ranges

### Error: CIDR Outside VCN Range
**Problem**: Subnet CIDR must be within VCN CIDR

**Solution**:
```hcl
# If VCN is 10.140.0.0/16, subnet must be 10.140.x.x
# Bad:  10.141.0.0/24  (outside VCN range)
# Good: 10.140.100.0/24 (inside VCN range)
```

### Error: Invalid CIDR Format
**Problem**: CIDR must be in format x.x.x.x/y where y is 16-30

**Solution**:
```hcl
# Bad:  "10.140.0.0"      (missing netmask)
# Bad:  "10.140.0.0/8"    (netmask too small)
# Good: "10.140.0.0/24"   (valid format)
```

## Tools and Resources

### Online CIDR Calculators
- https://www.ipaddressguide.com/cidr
- https://cidr.xyz/
- https://www.subnet-calculator.com/

### Terraform Functions
```hcl
# Calculate subnet CIDR
cidrsubnet(vpc_cidr, newbits, netnum)

# Calculate host address
cidrhost(subnet_cidr, hostnum)

# Get network address  
cidrnetmask(cidr)
```

### OCI CLI Commands
```bash
# List VCN details
oci network vcn get --vcn-id <vcn_ocid>

# Create subnet with custom CIDR
oci network subnet create \
  --cidr-block "10.140.50.0/24" \
  --compartment-id <compartment_ocid> \
  --vcn-id <vcn_ocid> \
  --display-name "custom-subnet"
```

## Quick Tips

💡 **Tip 1**: Start with defaults, customize later if needed  
💡 **Tip 2**: Pods subnet should be 4x larger than workers subnet  
💡 **Tip 3**: Keep control plane and admin subnets small (/29 or /28)  
💡 **Tip 4**: Load balancer subnets should match expected service count  
💡 **Tip 5**: Always document your CIDR allocation scheme  

---

**Need Help?**
- Review the main [README.md](./README.md) for configuration examples
- Check OCI documentation: https://docs.oracle.com/iaas/Content/Network/Tasks/managingVCNs.htm
- Use `terraform plan` to preview subnet allocations before applying
