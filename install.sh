#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
plain='\033[0m'

cur_dir=$(pwd)
github_repo="jameqq/XrayRP"
github_url="https://github.com/${github_repo}"
script_repo="jameqq/XrayR-release1"
raw_base="https://raw.githubusercontent.com/${script_repo}/master"

[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif grep -Eqi "debian" /etc/issue /proc/version 2>/dev/null; then
    release="debian"
elif grep -Eqi "ubuntu" /etc/issue /proc/version 2>/dev/null; then
    release="ubuntu"
elif grep -Eqi "centos|red hat|redhat" /etc/issue /proc/version 2>/dev/null; then
    release="centos"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n"
    exit 1
fi

arch=$(arch)
if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    echo -e "${red}不支持的架构：${arch}${plain}"
    exit 1
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ]; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)"
    exit 2
fi

install_base() {
    if [[ $release == "centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar crontabs socat -y
    else
        apt update -y
        apt install wget curl unzip tar cron socat -y
    fi
}

check_status() {
    systemctl is-active --quiet XrayR
}

download() {
    curl --fail --location --show-error --silent --retry 3 --connect-timeout 10 -o "$1" "$2"
}

install_XrayR() {
    if [[ -e /usr/local/XrayR/ ]]; then
        rm -rf /usr/local/XrayR/
    fi

    mkdir -p /usr/local/XrayR/
    cd /usr/local/XrayR/ || exit 1

    if [[ $# == 0 || -z ${1:-} ]]; then
        last_version=$(curl --fail --location --show-error --silent --retry 3 \
            "https://api.github.com/repos/${github_repo}/releases/latest" |
            sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
        if [[ -z $last_version ]]; then
            echo -e "${red}检测 XrayR 版本失败，可能是 GitHub API 限流或网络异常${plain}"
            exit 1
        fi
    else
        if [[ $1 == v* || $1 == V* ]]; then
            last_version=$1
        else
            last_version="v$1"
        fi
    fi

    echo -e "检测到 XrayR 版本：${last_version}，开始安装"
    download XrayR-linux.zip \
        "${github_url}/releases/download/${last_version}/XrayR-linux-${arch}.zip" || {
        echo -e "${red}下载 XrayR ${last_version} 失败${plain}"
        exit 1
    }

    unzip -o XrayR-linux.zip || {
        echo -e "${red}解压 XrayR-linux.zip 失败${plain}"
        exit 1
    }
    rm -f XrayR-linux.zip

    # Release 中若不是标准文件名 XrayR，则自动把唯一的 XrayR-* 二进制改名。
    if [[ ! -f XrayR ]]; then
        xrayr_binary=$(find . -maxdepth 1 -type f -name 'XrayR-*' -print -quit)
        if [[ -z $xrayr_binary ]]; then
            echo -e "${red}解压后未找到 XrayR 或 XrayR-* 二进制文件${plain}"
            exit 1
        fi
        mv -f -- "$xrayr_binary" XrayR
        echo "已将 ${xrayr_binary#./} 重命名为 XrayR"
    fi

    if [[ ! -s XrayR ]]; then
        echo -e "${red}XrayR 二进制文件不存在或为空${plain}"
        exit 1
    fi
    chmod +x XrayR

    mkdir -p /etc/XrayR/
    fresh_install=0
    [[ ! -f /etc/XrayR/config.yml ]] && fresh_install=1
    for config_file in geoip.dat geosite.dat config.yml dns.json route.json custom_outbound.json custom_inbound.json rulelist; do
        if [[ ! -f /etc/XrayR/$config_file ]]; then
            download "/etc/XrayR/$config_file" "${raw_base}/config/${config_file}" || {
                echo -e "${red}下载配置文件 ${config_file} 失败${plain}"
                exit 1
            }
        fi
    done

    rm -f /etc/systemd/system/XrayR.service
    download /etc/systemd/system/XrayR.service "${raw_base}/XrayR.service" || {
        echo -e "${red}下载 XrayR.service 失败${plain}"
        exit 1
    }
    systemctl daemon-reload
    systemctl enable XrayR || {
        echo -e "${red}设置 XrayR 开机自启失败${plain}"
        exit 1
    }

    download /usr/bin/XrayR.tmp "${raw_base}/XrayR.sh" || {
        echo -e "${red}下载 XrayR 管理脚本失败${plain}"
        exit 1
    }
    bash -n /usr/bin/XrayR.tmp || {
        echo -e "${red}XrayR 管理脚本语法检查失败${plain}"
        rm -f /usr/bin/XrayR.tmp
        exit 1
    }
    mv -f /usr/bin/XrayR.tmp /usr/bin/XrayR
    chmod +x /usr/bin/XrayR
    ln -sfn /usr/bin/XrayR /usr/bin/xrayr

    if [[ $fresh_install == 1 ]]; then
        echo -e "${green}XrayR ${last_version}${plain} 安装完成，已设置开机自启"
        echo "全新安装，请先编辑 /etc/XrayR/config.yml，配置完成后执行：XrayR start"
    else
        systemctl restart XrayR
        sleep 2
        if check_status; then
            echo -e "${green}XrayR ${last_version} 安装并启动成功${plain}"
        else
            echo -e "${red}XrayR 启动失败，请执行：journalctl -u XrayR -n 100 --no-pager${plain}"
            exit 1
        fi
    fi

    cd "$cur_dir" || exit 1
    echo "XrayR 管理脚本已安装，可执行：XrayR"
}

echo -e "${green}开始安装${plain}"
install_base
install_XrayR "${1:-}"
