#!/bin/bash
set -e

CONTAINER_NAME="openwrt"
DOWNLOAD_DIR=~/openwrt-lxd
OPENWRT_VERSION="23.05.3"
ROOTFS_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/x86/64/openwrt-$OPENWRT_VERSION-x86-64-rootfs.tar.gz"

function menu() {
  clear
  echo "========================="
  echo " OpenWrt LXD 中文管理工具"
  echo "========================="
  echo ""
  echo "1) 安装 OpenWrt 容器"
  echo "2) 创建并桥接 br0 网桥（Wi-Fi 热点）"
  echo "3) 启动 OpenWrt 容器"
  echo "4) 停止 OpenWrt 容器"
  echo "5) 删除 OpenWrt 容器与镜像"
  echo "6) 查看容器状态"
  echo "7) 修改容器网络配置（设为192.168.100.1）"
  echo "0) 退出"
  echo ""
  read -p "请输入编号：" choice
  case "$choice" in
    1) install_openwrt ;;
    2) setup_bridge ;;
    3) lxc start $CONTAINER_NAME; echo "已启动容器 $CONTAINER_NAME" ;;
    4) lxc stop $CONTAINER_NAME; echo "已停止容器 $CONTAINER_NAME" ;;
    5) clean_all ;;
    6) lxc list ;;
    7) config_network ;;
    0) exit 0 ;;
    *) echo "无效选项，请重新输入。" ;;
  esac
  echo ""
  read -p "按回车键返回菜单..." dummy
  menu
}

function install_openwrt() {
  echo "[1/6] 准备下载 OpenWrt 镜像"
  mkdir -p $DOWNLOAD_DIR
  cd $DOWNLOAD_DIR
  wget "$ROOTFS_URL" -O rootfs.tar.gz

  echo "[2/6] 导入 LXD 镜像"
  cat <<EOF > metadata.yaml
architecture: "amd64"
creation_date: $(date +%s)
properties:
  description: "OpenWrt $OPENWRT_VERSION x86_64"
  os: "openwrt"
  release: "$OPENWRT_VERSION"
  type: "container"
EOF

  tar -czf openwrt-image.tar.gz metadata.yaml rootfs.tar.gz
  lxc image import openwrt-image.tar.gz --alias $CONTAINER_NAME
  rm -f metadata.yaml openwrt-image.tar.gz

  echo "[3/6] 创建容器并连接到 lxdbr0"
  lxc init $CONTAINER_NAME $CONTAINER_NAME
  lxc network attach lxdbr0 $CONTAINER_NAME eth0
  lxc config device set $CONTAINER_NAME eth0 name eth0
  lxc config set $CONTAINER_NAME boot.autostart true

  echo "[4/6] 启动容器"
  lxc start $CONTAINER_NAME
  sleep 5

  echo "[5/6] 配置初始网络（192.168.100.1 静态）"
  config_network

  echo "[6/6] 完成。容器已运行，访问：http://192.168.100.1"
}

function config_network() {
  lxc exec $CONTAINER_NAME -- /bin/sh -c "
uci set network.lan=interface
uci set network.lan.device='eth0'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.100.1'
uci set network.lan.netmask='255.255.255.0'
uci commit network

uci set dhcp.lan=dhcp
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'
uci commit dhcp

uci set firewall.@zone[0].network='lan'
uci commit firewall

/etc/init.d/network restart
/etc/init.d/dnsmasq restart
/etc/init.d/uhttpd start
"
}

function setup_bridge() {
  wifi_dev=$(iw dev | awk '$1=="Interface"{print $2}' | head -n1)
  echo "检测到无线设备：$wifi_dev"

  echo "[1/3] 创建网桥 br0"
  nmcli connection add type bridge ifname br0 con-name br0
  nmcli connection modify br0 ipv4.method manual ipv4.addresses 192.168.100.2/24 ipv4.gateway 192.168.100.1 ipv4.dns 192.168.100.1
  nmcli connection up br0

  echo "[2/3] 创建 Wi-Fi 热点并桥接到 br0"
  nmcli connection add type wifi ifname $wifi_dev con-name br0-hotspot autoconnect yes ssid OpenWrt-Hotspot
  nmcli connection modify br0-hotspot 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared
  nmcli connection modify br0-hotspot wifi-sec.key-mgmt wpa-psk wifi-sec.psk "12345678"
  nmcli connection modify br0-hotspot master br0
  nmcli connection up br0-hotspot

  echo "[完成] 热点 OpenWrt-Hotspot 已创建，密码为 12345678"
}

function clean_all() {
  echo "[!] 正在清理容器与镜像"
  lxc stop $CONTAINER_NAME || true
  lxc delete $CONTAINER_NAME || true
  lxc image delete $CONTAINER_NAME || true
  rm -rf $DOWNLOAD_DIR
  echo "已完成清理。"
}

menu
