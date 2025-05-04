#!/bin/bash set -e

================= 全局配置 =================

WORKDIR="$HOME/openwrt-lxd" IMAGE_ALIAS="openwrt" CONTAINER_NAME="openwrt" SHORTCUT="/usr/local/bin/op" BRIDGE_NAME="br0" CONFIG_FILE="$HOME/.openwrt-lxd.conf"

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'

================= 高级功能开关 =================

ENABLE_IPV6=false ENABLE_WIFI_SWITCH=false

load_config() { if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE" fi }

save_config() { cat > "$CONFIG_FILE" <<EOF ENABLE_IPV6=$ENABLE_IPV6 ENABLE_WIFI_SWITCH=$ENABLE_WIFI_SWITCH EOF }

================= 多架构支持 =================

detect_architecture() { case $(uname -m) in x86_64) echo "x86/64" ;; aarch64) echo "armvirt/64" ;; armv7l) echo "armvirt/32" ;; *) echo "unknown" ;; esac }

TARGET_PATH=$(detect_architecture) [ "$TARGET_PATH" = "unknown" ] && { echo -e "${RED}不支持的架构: $(uname -m)${NC}"; exit 1; }

choose_version() { echo -e "${GREEN}[✓] 可选择 OpenWrt 版本${NC}" echo "1) 使用默认版本 23.05.3" echo "2) 自动检测最新版本" read -p "请选择: " version_choice case $version_choice in 2) latest_ver=$(wget -qO- https://downloads.openwrt.org/releases/ | grep -oE '2[0-9]+.[0-9]+.[0-9]+' | sort -Vr | head -1) VERSION="$latest_ver" ;; *) VERSION="23.05.3" ;; esac }

choose_version IMAGE_FILENAME="openwrt-${VERSION}-${TARGET_PATH////-}-rootfs.tar.gz" IMAGE_URL="https://downloads.openwrt.org/releases/${VERSION}/targets/${TARGET_PATH}/${IMAGE_FILENAME}"

================= 子网推测 =================

detect_subnet() { local gw=$(ip route | awk '/default/ {print $3}' | head -1) if [[ $gw =~ ^([0-9]+.[0-9]+).([0-9]+).[0-9]+$ ]]; then local base="${BASH_REMATCH[1]}" local third="${BASH_REMATCH[2]}" if (( third < 253 )); then echo "$base.$((third + 1))" return fi fi echo "192.168.2" } DEFAULT_SUBNET=$(detect_subnet)

================= 核心功能 =================

check_dependencies() { local missing=() local required=("wget" "tar" "lxd")

if ! systemctl is-active --quiet lxd; then echo -e "${YELLOW}[!] 启动LXD服务...${NC}" sudo systemctl start lxd || { echo -e "${RED}[!] 需要先初始化LXD，请运行: sudo lxd init${NC}" exit 1 } fi

for cmd in "${required[@]}"; do if ! command -v "$cmd" &>/dev/null; then missing+=("$cmd") fi done

if [ ${#missing[@]} -gt 0 ]; then echo -e "${YELLOW}[!] 缺少依赖: ${missing[*]}${NC}" read -p "自动安装？[Y/n] " confirm [[ ! "$confirm" =~ [nN] ]] && sudo apt update && sudo apt install -y "${missing[@]}" fi }

init_bridge() { if ip link show "$BRIDGE_NAME" &>/dev/null; then echo -e "${GREEN}[✓] 已存在桥接接口 ${BRIDGE_NAME}${NC}" return fi

default_iface=$(ip route show default 0.0.0.0/0 | awk '{print $5}' | head -1) [ -z "$default_iface" ] && default_iface=$(ls /sys/class/net | grep -vE '^(lo|br0)$' | head -1)

echo -e "${YELLOW}[] 等待网络初始化...${NC}" sleep 5 }

setup_container() { mkdir -p "$WORKDIR" cd "$WORKDIR"

if [ ! -f "rootfs.tar.gz" ]; then echo -e "${YELLOW}[~] 下载OpenWrt镜像...${NC}" wget -q --show-progress -O rootfs.tar.gz "$IMAGE_URL" fi

if ! lxc image list | grep -q "$IMAGE_ALIAS"; then echo -e "${YELLOW}[~] 导入容器镜像...${NC}" cat > metadata.yaml <<EOF architecture: "$(uname -m)" creation_date: $(date +%s) properties: description: "OpenWrt $VERSION" os: "OpenWrt" release: "$VERSION" EOF tar -czf openwrt-lxd.tar.gz metadata.yaml rootfs.tar.gz lxc image import openwrt-lxd.tar.gz --alias "$IMAGE_ALIAS" fi

if ! lxc list | grep -q "$CONTAINER_NAME"; then echo -e "${YELLOW}[~] 初始化容器...${NC}" lxc launch "$IMAGE_ALIAS" "$CONTAINER_NAME" sleep 5

for i in {1..10}; do if lxc exec "$CONTAINER_NAME" -- ip a | grep -q "inet "; then break; fi sleep 1 done lxc config device add "$CONTAINER_NAME" eth0 nic nictype=bridged parent="$BRIDGE_NAME" lxc config set "$CONTAINER_NAME" boot.autostart true lxc config set "$CONTAINER_NAME" security.privileged true 

fi }

select_mode() { echo -e "\n${GREEN}==== 模式选择 ====${NC}" echo "1) 主路由模式" echo "2) 旁路由模式" read -p "请选择: " mode

case $mode in 1) configure_main_router ;; 2) configure_passive_router ;; *) echo -e "${RED}无效选项，默认使用主路由模式${NC}"; configure_main_router ;; esac }

configure_main_router() { local lan_ip="${DEFAULT_SUBNET}.1" echo -e "${YELLOW}[~] 配置主路由 (IP: $lan_ip)...${NC}" lxc exec "$CONTAINER_NAME" -- sh <<EOF uci batch <<EOL set network.lan.proto='static' set network.lan.ipaddr='$lan_ip' set network.lan.netmask='255.255.255.0' set dhcp.lan.start='100' set dhcp.lan.limit='150' set dhcp.lan.leasetime='12h' set firewall.@zone[0].masq='1' commit EOL /etc/init.d/network restart /etc/init.d/dnsmasq restart EOF echo -e "${GREEN}[✓] 主路由配置完成，访问地址: http://$lan_ip${NC}" }

validate_ip() { [[ $1 =~ ^[0-9]+.[0-9]+.[0-9]+.[0-9]+$ ]] }

configure_passive_router() { while :; do read -p "请输入主路由IP: " main_ip validate_ip "$main_ip" && break echo -e "${RED}无效IP格式，例如: 192.168.1.1${NC}" done

local passive_ip="${main_ip%.*}.2"

echo -e "${YELLOW}[~] 配置旁路由 (IP: $passive_ip)...${NC}" lxc exec "$CONTAINER_NAME" -- sh <<EOF uci batch <<EOL set network.lan.proto='static' set network.lan.ipaddr='$passive_ip' set network.lan.netmask='255.255.255.0' set network.lan.gateway='$main_ip' set network.lan.dns='$main_ip' delete dhcp.lan commit EOL /etc/init.d/network restart EOF echo -e "${GREEN}[✓] 旁路由配置完成，访问地址: http://$passive_ip${NC}" }

create_shortcut() { if [ ! -f "$SHORTCUT" ]; then sudo bash -c "echo -e '#!/bin/bash\n"$(realpath "$0")" "$@"' > "$SHORTCUT"" sudo chmod +x "$SHORTCUT" echo -e "${GREEN}[✓] 已创建快捷方式: ${SHORTCUT}${NC}" fi }

safe_cleanup() { echo -e "${RED}!!! 警告：将永久删除所有数据 !!!${NC}" read -p "确认清理？(输入 YES 确认): " confirm if [ "$confirm" = "YES" ]; then read -p "是否保留快捷方式？[Y/n] " keep [[ "$keep" =~ [nN] ]] && sudo rm -f "$SHORTCUT" && echo -e "${GREEN}[✓] 已删除快捷方式${NC}" lxc stop "$CONTAINER_NAME" --force || true lxc delete "$CONTAINER_NAME" || true lxc image delete "$IMAGE_ALIAS" || true sudo rm -f /etc/netplan/99-openwrt-bridge.yaml && sudo netplan apply rm -rf "$WORKDIR" rm -f "$CONFIG_FILE" echo -e "${GREEN}[✓] 清理完成${NC}" else echo -e "${YELLOW}已取消${NC}" fi }

================= 容器命令代理 =================

if [[ "$(basename "$0")" = "op" && $# -gt 0 ]]; then lxc exec "$CONTAINER_NAME" -- "$@" exit $? fi

================= 主菜单 =================

load_config

while true; do echo -e "\n${GREEN}==== OpenWrt 管理 =====" echo "1) 一键部署（首次使用）" echo "2) 切换主路由模式" echo "3) 切换旁路由模式" echo "4) 进入容器控制台" echo "5) 清理环境" echo "6) 切换 IPv6 支持（当前：$([ "$ENABLE_IPV6" = true ] && echo 开启 || echo 关闭)）" echo "7) 切换 Wi-Fi 热点自动切换（当前：$([ "$ENABLE_WIFI_SWITCH" = true ] && echo 开启 || echo 关闭)）" echo "0) 退出" echo -e "=======================${NC}"

read -p "请选择: " choice case $choice in 1) check_dependencies; init_bridge; setup_container; create_shortcut; select_mode ;; 2) configure_main_router ;; 3) configure_passive_router ;; 4) lxc exec "$CONTAINER_NAME" -- su - ;; 5) safe_cleanup ;; 6) ENABLE_IPV6=$([ "$ENABLE_IPV6" = true ] && echo false || echo true); save_config ;; 7) ENABLE_WIFI_SWITCH=$([ "$ENABLE_WIFI_SWITCH" = true ] && echo false || echo true); save_config ;; 0) exit 0 ;; *) echo -e "${RED}无效选项！${NC}" ;; esac

done
