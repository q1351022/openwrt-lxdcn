#!/bin/bash

set -e

# 设置默认参数
ENABLE_WIFI_SWITCH=true
ENABLE_IPV6=true
MODE="主路由"
USE_LATEST_IMAGE=false
CUSTOM_GATEWAY=""
CONTAINER_IP=""

# 获取默认网卡名（上网出口）
DEFAULT_IFACE=$(ip route get 1.1.1.1 | awk '{ for(i=1;i<=NF;i++) if ($i == "dev") print $(i+1) }')

# 打印主菜单函数
function main_menu() {
    clear
    echo "=============================="
    echo " OpenWrt LXD 自动部署脚本"
    echo "=============================="
    echo "1. 使用默认镜像部署"
    echo "2. 使用最新镜像部署"
    echo "3. 切换为旁路由模式"
    echo "4. 切换为主路由模式"
    echo "5. 启用或禁用 Wi-Fi 热点：当前 ${ENABLE_WIFI_SWITCH}"
    echo "6. 启用或禁用 IPv6 支持：当前 ${ENABLE_IPV6}"
    echo "7. 设置旁路由参数（网关+容器IP）"
    echo "0. 开始部署"
    echo "=============================="
    echo -n "请输入选项："
    read opt
    case $opt in
        1) USE_LATEST_IMAGE=false;;
        2) USE_LATEST_IMAGE=true;;
        3) 
            MODE="旁路由"
            read -p "请输入主路由网关IP (如 192.168.1.1): " CUSTOM_GATEWAY
            CONTAINER_IP="${CUSTOM_GATEWAY%.*}.2"  # 自动生成容器IP
            echo "容器IP自动设置为: ${CONTAINER_IP}"
            sleep 2
            ;;
        4) MODE="主路由";;
        5) ENABLE_WIFI_SWITCH=$( [[ $ENABLE_WIFI_SWITCH == true ]] && echo false || echo true );;
        6) ENABLE_IPV6=$( [[ $ENABLE_IPV6 == true ]] && echo false || echo true );;
        7)
            read -p "请输入主路由网关IP (如 192.168.1.1): " CUSTOM_GATEWAY
            read -p "请输入容器静态IP (如 ${CUSTOM_GATEWAY%.*}.2): " CONTAINER_IP
            ;;
        0) deploy_openwrt; return;;
        *) echo "无效输入，按回车返回..."; read;;
    esac
    main_menu
}

# 下载 OpenWrt 镜像
function fetch_openwrt_image() {
    if $USE_LATEST_IMAGE; then
        echo "正在获取 OpenWrt 最新镜像..."
        URL=$(curl -s https://api.github.com/repos/sbwml/openwrt-x86_64/releases/latest | grep browser_download_url | grep rootfs.tar.gz | cut -d '"' -f 4)
    else
        echo "使用默认镜像..."
        URL="https://github.com/sbwml/openwrt-x86_64/releases/download/2024.03.01/openwrt-x86-64-generic-rootfs.tar.gz"
    fi
    wget -O rootfs.tar.gz "$URL"
}

# 创建并配置 LXD 容器
function deploy_openwrt() {
    echo "创建 OpenWrt 容器..."

    # 安装 lxd
    if ! command -v lxc >/dev/null; then
        echo "安装 lxd..."
        sudo apt update && sudo apt install -y lxd
        sudo newgrp lxd
    fi

    # 初始化 LXD（如果尚未初始化）
    if ! lxc storage list | grep -q default; then
        echo "初始化 LXD..."
        lxd init --auto
    fi

    # 下载镜像
    fetch_openwrt_image

    # 导入镜像
    echo "导入 OpenWrt 镜像..."
    lxc image import rootfs.tar.gz --alias openwrt

    # 删除已存在容器
    lxc delete openwrt --force 2>/dev/null || true

    # 创建容器
    if [[ $MODE == "旁路由" ]]; then
        # 创建桥接网络配置
        if ! lxc network show lxdbr-phy &>/dev/null; then
            lxc network create lxdbr-phy --type=bridge parent=${DEFAULT_IFACE} ipv4.address=none ipv6.address=none
        fi
        lxc init openwrt openwrt -n lxdbr-phy
        lxc config device set openwrt eth0 ipv4.address "${CONTAINER_IP}/24"
    else
        lxc init openwrt openwrt
        lxc network attach lxdbr0 openwrt eth0 eth0
        lxc config device set openwrt eth0 ipv4.address 192.168.123.2
    fi

    # 启动容器
    lxc start openwrt
    sleep 5  # 等待容器启动

    # 基础配置
    echo "配置基础设置..."
    lxc exec openwrt -- /bin/sh -c "uci set dropbear.@dropbear[0].enable=1; uci commit dropbear; /etc/init.d/dropbear restart"

    # Wi-Fi 热点配置
    if $ENABLE_WIFI_SWITCH; then
        echo "启用主机 Wi-Fi 热点..."
        if ! nmcli device wifi hotspot ifname $DEFAULT_IFACE ssid OpenWrtHotspot password 12345678; then
            echo "警告：Wi-Fi 热点配置失败，请检查网卡是否支持AP模式"
        fi
    fi

    # IPv6 配置
    if $ENABLE_IPV6; then
        lxc exec openwrt -- uci set network.lan.ipv6='auto'
        lxc exec openwrt -- uci commit network
    fi

    # 旁路由模式配置
    if [[ $MODE == "旁路由" ]]; then
        echo "配置为旁路由模式..."
        GATEWAY_IP=${CUSTOM_GATEWAY:-192.168.1.1}
        lxc exec openwrt -- uci set network.lan.gateway=$GATEWAY_IP
        lxc exec openwrt -- uci set network.lan.dns=$GATEWAY_IP
        lxc exec openwrt -- uci delete dhcp.lan.dhcp_option || true
        lxc exec openwrt -- uci set dhcp.lan.ignore=1
        lxc exec openwrt -- uci commit network
        lxc exec openwrt -- uci commit dhcp
        lxc exec openwrt -- /etc/init.d/dnsmasq stop || true
        lxc exec openwrt -- /etc/init.d/firewall stop || true
    fi

    # 重启网络服务
    lxc exec openwrt -- /etc/init.d/network restart

    echo "=============================="
    echo "部署完成！"
    [[ $MODE == "旁路由" ]] && echo "旁路由IP: ${CONTAINER_IP}" || echo "主路由IP: 192.168.123.2"
    echo "SSH访问: ssh root@${CONTAINER_IP:-192.168.123.2}"
    echo "=============================="
}

# 启动菜单
main_menu
