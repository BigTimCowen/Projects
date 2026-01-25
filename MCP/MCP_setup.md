# OCI MCP Server - Operator Node Installation

Run the MCP server directly on your operator node for local kubectl/oci/helm access.

## Architecture

```
┌─────────────────────────────────┐
│         Operator Node           │
│  ┌─────────────────────────┐    │
│  │     MCP Server          │    │
│  │  (local execution)      │    │
│  └──────────┬──────────────┘    │
│             │                   │
│    ┌────────┴────────┐          │
│    ▼        ▼        ▼          │
│ kubectl    oci     helm         │
└─────────────────────────────────┘
```

## Quick Install

```bash
# Copy install script to operator node
scp install.sh opc@operator:/tmp/

# SSH to operator and run
ssh opc@operator
chmod +x /tmp/install.sh
/tmp/install.sh

# Test
/opt/oci-mcp-server/test.sh
```

## What Gets Installed

```
/opt/oci-mcp-server/
├── server.py           # MCP server
├── run.sh              # Wrapper script
├── test.sh             # Test script
├── venv/               # Python virtual environment
├── config/
│   └── config.json     # Allowlists and settings
├── logs/
│   └── audit.log       # All command executions
└── scripts/            # Your custom scripts
```

## Connecting from Claude Desktop

### Direct SSH (no bastion)

Add to `~/.config/claude/claude_desktop_config.json` (Linux) or equivalent:

```json
{
  "mcpServers": {
    "oci-infrastructure": {
      "command": "ssh",
      "args": [
        "-i", "~/.ssh/your_key",
        "opc@operator-ip",
        "/opt/oci-mcp-server/run.sh"
      ]
    }
  }
}
```

### Via Bastion (ProxyJump)

```json
{
  "mcpServers": {
    "oci-infrastructure": {
      "command": "ssh",
      "args": [
        "-i", "~/.ssh/your_key",
        "-J", "opc@bastion-ip",
        "opc@operator-internal-ip",
        "/opt/oci-mcp-server/run.sh"
      ]
    }
  }
}
```

### Via SSH Config

If you have `~/.ssh/config` set up:

```
Host operator
    HostName 10.0.1.100
    User opc
    ProxyJump bastion
    IdentityFile ~/.ssh/operator_key
```

Then Claude Desktop config is simply:

```json
{
  "mcpServers": {
    "oci-infrastructure": {
      "command": "ssh",
      "args": ["operator", "/opt/oci-mcp-server/run.sh"]
    }
  }
}
```

## Adding Custom Scripts

1. Place script on operator node:
   ```bash
   cp my_script.sh /opt/oci-mcp-server/scripts/
   chmod +x /opt/oci-mcp-server/scripts/my_script.sh
   ```

2. Add to config:
   ```json
   {
     "allowed_scripts": {
       "my_script": "/opt/oci-mcp-server/scripts/my_script.sh",
       "k8s_nodes_details": "/home/opc/scripts/k8s_get_nodes_details.sh"
     }
   }
   ```

3. Use via Claude:
   ```
   run_script: my_script
   run_script: k8s_nodes_details --verbose
   ```

## Customizing Allowlists

Edit `/opt/oci-mcp-server/config/config.json`:

```json
{
  "allowlist": {
    "kubectl": [
      "^kubectl get .*",
      "^kubectl describe .*",
      "^kubectl scale deployment .* --replicas=\\d+$"
    ],
    "oci": [
      "^oci compute instance list .*",
      "^oci ce cluster get .*"
    ]
  }
}
```

**Pattern tips:**
- `^` anchors to start (prevents injection)
- `.*` matches anything
- `\\d+` matches numbers
- `$` anchors to end (for exact matches)

## Viewing Audit Logs

```bash
# Recent activity
tail -f /opt/oci-mcp-server/logs/audit.log

# Parse with jq
cat /opt/oci-mcp-server/logs/audit.log | jq -r 'select(.tool=="kubectl") | .params.command'
```

## Troubleshooting

### SSH connection fails

```bash
# Test SSH from your workstation
ssh -v opc@operator /opt/oci-mcp-server/run.sh
```

### kubectl not found

The server looks for kubectl in standard paths. Check:
```bash
which kubectl
echo $PATH
```

### OCI CLI auth issues

If using instance principal:
```bash
export OCI_CLI_AUTH=instance_principal
oci iam region list
```

### Permission denied on logs

```bash
sudo chown -R opc:opc /opt/oci-mcp-server/logs
```

## Uninstall

```bash
sudo rm -rf /opt/oci-mcp-server
```