#!/bin/bash
# nic_map.sh — Map Mellanox PCI devices to net/RDMA/link info
# v1.8.0 | 2026-04-23
#
#./nic_map.sh
#PCI_BDF            TYPE   NET_IF   RDMA_DEV STATE  SPEED   NUMA FIRMWARE               IP_ADDR
#-------------------------------------------------------------------------------------------------------------------
#0006:09:00.0       CX7    eth0     mlx5_4   up     200G    0    28.44.1022 (ORC0000000014) 10.241.0.2
#0016:0b:00.0       CX7    eth1     mlx5_9   up     200G    1    28.44.1022 (ORC0000000014) none
#0000:03:00.0       CX8    rdma0    mlx5_0   up     400G    0    40.46.4050 (ORC0000000015) gdcd:2:a75a:f00a:92e3:17ff:fec4:8aac
#0000:03:00.1       CX8    rdma1    mlx5_1   up     400G    0    40.46.4050 (ORC0000000015) gdcd:2:a75a:f00b:92e3:17ff:fec4:8aad
#0002:03:00.0       CX8    rdma2    mlx5_2   up     400G    0    40.46.4050 (ORC0000000015) gdcd:2:a25a:f00a:92e3:17ff:fec4:8aac
#0002:03:00.1       CX8    rdma3    mlx5_3   up     400G    0    40.46.4050 (ORC0000000015) gdcd:2:a25a:f00b:92e3:17ff:fec4:8aad
#0010:03:00.0       CX8    rdma4    mlx5_5   up     400G    1    40.46.4050 (ORC0000000015) gdcd:2:a35a:f00a:ea9e:49ff:fe59:7bbe
#0010:03:00.1       CX8    rdma5    mlx5_6   up     400G    1    40.46.4050 (ORC0000000015) gdcd:2:a35a:f00b:ea9e:49ff:fe59:7bbf
#0012:03:00.0       CX8    rdma6    mlx5_7   up     400G    1    40.46.4050 (ORC0000000015) gdcd:2:a45a:f00a:ea9e:49ff:fe59:7bbe
#0012:03:00.1       CX8    rdma7    mlx5_8   up     400G    1    40.46.4050 (ORC0000000015) gdcd:2:a45a:f00b:ea9e:49ff:fe59:7bbf
#
#

SHAPE=$(curl -sL -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/ 2>/dev/null | jq -r '.shape // empty')
printf "GPU Model: %s\n\n" "${SHAPE:-unknown}"

printf "%-18s %-6s %-8s %-8s %-6s %-7s %-4s %-13s %-13s %-16s %s\n" \
  "PCI_BDF" "TYPE" "NET_IF" "RDMA_DEV" "STATE" "SPEED" "NUMA" "FW_RUN" "FW_FLASH" "PSID" "IP_ADDR"
printf '%0.s-' {1..140}; echo

ETH_ROWS=()
RDMA_ROWS=()
while read -r line; do
  BDF=$(echo "$line" | awk '{print $1}')
  case "$line" in
    *ConnectX-8*) TYPE="CX8" ;;
    *ConnectX-7*) TYPE="CX7" ;;
    *ConnectX-6*) TYPE="CX6" ;;
    *ConnectX-5*) TYPE="CX5" ;;
    *ConnectX-4*) TYPE="CX4" ;;
    *ConnectX-3*) TYPE="CX3" ;;
    *)            TYPE="N/A" ;;
  esac

  NET_IF=$(ls /sys/bus/pci/devices/${BDF}/net/ 2>/dev/null | head -1)
  RDMA_DEV=$(ls /sys/bus/pci/devices/${BDF}/infiniband/ 2>/dev/null | head -1)
  NUMA=$(cat /sys/bus/pci/devices/${BDF}/numa_node 2>/dev/null)

  if [[ -n "$NET_IF" ]]; then
    STATE=$(cat /sys/class/net/${NET_IF}/operstate 2>/dev/null)
    SPEED_MBPS=$(cat /sys/class/net/${NET_IF}/speed 2>/dev/null)
    if [[ "$SPEED_MBPS" =~ ^[0-9]+$ ]]; then
      SPEED="$((SPEED_MBPS / 1000))G"
    else
      SPEED="N/A"
    fi
    IP=$(ip -4 addr show dev ${NET_IF} 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    if [[ -z "$IP" ]]; then
      IP=$(ip -6 addr show dev ${NET_IF} scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | head -1)
    fi
  else
    STATE="N/A"; SPEED="N/A"; IP=""
  fi

  MST_OUT=$(sudo mstflint -d "$BDF" query 2>/dev/null)
  FW_FLASH=$(echo "$MST_OUT" | awk -F': *' '/^FW Version:/{print $2; exit}' | awk '{print $1}')
  FW_RUN=$(echo "$MST_OUT"  | awk -F': *' '/^FW Version\(Running\):/{print $2; exit}' | awk '{print $1}')
  PSID=$(echo "$MST_OUT"    | awk -F': *' '/^PSID:/{print $2; exit}' | awk '{print $1}')
  [[ -z "$FW_RUN" ]] && FW_RUN="$FW_FLASH"
  if [[ -z "$FW_FLASH" && -n "$NET_IF" ]]; then
    FW_RUN=$(ethtool -i ${NET_IF} 2>/dev/null | awk -F': ' '/firmware-version/{print $2}' | awk '{print $1}')
    FW_FLASH="$FW_RUN"
  fi

  ROW=$(printf "%-18s %-6s %-8s %-8s %-6s %-7s %-4s %-13s %-13s %-16s %s" \
    "$BDF" "$TYPE" "${NET_IF:-none}" "${RDMA_DEV:-none}" \
    "${STATE:-N/A}" "$SPEED" "${NUMA:-N/A}" \
    "${FW_RUN:-N/A}" "${FW_FLASH:-N/A}" "${PSID:-N/A}" "${IP:-none}")

  if [[ "$NET_IF" == eth* ]]; then
    ETH_ROWS+=("$ROW")
  elif [[ "$NET_IF" == rdma* ]]; then
    RDMA_ROWS+=("$ROW")
  fi
done < <(lspci -Dmm | grep -i mellanox | grep -i "ethernet controller")

for row in "${ETH_ROWS[@]}"; do echo "$row"; done | sort -t' ' -k3,3V
for row in "${RDMA_ROWS[@]}"; do echo "$row"; done | sort -t' ' -k3,3V
