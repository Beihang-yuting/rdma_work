#!/usr/bin/env bash
# 目录：工具层 tools/rxe/rxe_tap_setup.sh。
# 层：验证工具（需 sudo）。
# 职责：建立/拆除仿真与 Soft-RoCE 互打用的 TAP 链路：持久 TAP 网卡（属主为当前用户，仿真进程无需
#   root 即可打开），配置 rxe 侧 IPv4、关闭 IPv6（减少无关报文），为仿真侧 IP 加静态邻居（仿真不应答
#   ARP），并在其上绑定 rxe 设备。rxe 在根命名空间（5.15 内核的 rxe 不支持 netns）。
# 用法：rxe_tap_setup.sh up|down [tap] [rxe_ip] [sim_ip] [sim_mac]
set -euo pipefail

action=${1:?usage: rxe_tap_setup.sh up|down [tap] [rxe_ip] [sim_ip] [sim_mac]}
tap=${2:-rtap0}
rxe_ip=${3:-10.79.0.2}
sim_ip=${4:-10.79.0.1}
sim_mac=${5:-02:00:00:00:79:01}
dev=rxe_${tap}

down() {
  sudo -n rdma link delete "$dev" 2>/dev/null || true
  sudo -n ip tuntap del dev "$tap" mode tap 2>/dev/null || true
}

if [[ "$action" == down ]]; then
  down
  exit 0
fi

down
sudo -n modprobe rdma_rxe
sudo -n ip tuntap add dev "$tap" mode tap user "$(id -u)"
sudo -n sysctl -q -w "net.ipv6.conf.$tap.disable_ipv6=1"
sudo -n ip addr add "$rxe_ip/24" dev "$tap"
sudo -n ip link set "$tap" mtu 1500 up
sudo -n ip neigh replace "$sim_ip" lladdr "$sim_mac" dev "$tap" nud permanent
sudo -n rdma link add "$dev" type rxe netdev "$tap"
sleep 1
hex=$(printf '%02x%02x:%02x%02x' ${rxe_ip//./ })
gid=$(ibv_devinfo -v -d "$dev" |
  awk -v h="ffff:$hex" '/GID\[/ && index($0, h) {match($0, /\[ *[0-9]+\]/);
       s = substr($0, RSTART + 1, RLENGTH - 2); gsub(/ /, "", s); print s; exit}')
echo "tap=$tap dev=$dev gid_index=$gid rxe_ip=$rxe_ip rxe_mac=$(cat /sys/class/net/$tap/address)" \
     "sim_ip=$sim_ip sim_mac=$sim_mac"
