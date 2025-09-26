#!/bin/sh

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

echo -e "
  ${green}soga 后端管理脚本，${plain}${red}仅适用于ALPINE${plain}
  
  ${green}0.${plain} 修改配置
————————————————
  ${green}1.${plain} 安装 soga
  ${green}2.${plain} 卸载 soga
————————————————
  ${green}3.${plain} 启动 soga
  ${green}4.${plain} 停止 soga
  ${green}5.${plain} 重启 soga
  ${green}6.${plain} 查看 soga 状态
  ${green}7.${plain} 查看 soga 日志
————————————————
  ${green}8.${plain} 设置 soga 开机自启
  ${green}9.${plain} 取消 soga 开机自启
————————————————
  ${green}10.${plain} 开启 soga 报错自启
  ${green}11.${plain} 取消 soga 报错自启
 "

# 检查是否安装soga
if [ -f "/etc/soga/soga" ]; then
    soga_service_status=$(rc-service soga status 2>&1)
    
    if echo "$soga_service_status" | grep -q "started"; then
        soga_status="${green}已运行${plain}"
    elif echo "$soga_service_status" | grep -q "stopped"; then
        soga_status="${red}未运行${plain}"
    elif echo "$soga_service_status" | grep -q "crashed"; then
        soga_status="${yellow}已崩溃${plain}"
    else
        soga_status="$soga_service_status"
    fi

    if rc-update show default | grep -q "soga | default" ; then
        auto_start="${green}是${plain}"
    else
        auto_start="${red}否${plain}"
    fi
else
    soga_status="${red}未安装${plain}"
    auto_start=""
fi

echo -e "soga状态: $soga_status"
if [ -n "$auto_start" ]; then
    echo -e "是否开机自启: ${auto_start}"
fi

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
    echo ""
    echo -e "${red}错误:${plain} 必须使用root用户运行此脚本！\n"
    exit 1
fi

# 定义安装soga的函数
install_soga() {
    
    if [ ! -f "/usr/share/zoneinfo/Asia/Shanghai" ]; then
        echo -e "${yellow}时区 Asia/Shanghai 不存在，正在修复${plain}"
        
        # 安装 tzdata 包
        if ! apk info | grep -q tzdata; then
            # echo -e "${yellow}正在安装 tzdata 包${plain}"
            apk add tzdata
        fi
        
        # 设置正确的时区
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
        
        echo -e "${green}时区已成功修复为 Asia/Shanghai${plain}"
    fi
    
    read -p "输入指定版本 例 2.10.2 (回车默认最新版): " version_input

    if [ -z "$version_input" ]; then
        last_version=$(curl -Ls "https://api.github.com/repos/vaxilu/soga/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    else
        last_version="$version_input"
    fi

    if [ -z "$last_version" ]; then
        echo -e "${red}检测 soga 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 soga 版本安装${plain}"
        exit 1
    fi

    echo -e "${yellow}开始安装${plain}"
    
    arch=$(arch)

    if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
        arch="amd64"
    elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
        arch="arm64"
    else
        arch="amd64"
        echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
    fi

    echo "架构: ${arch}"
    
    if ! command -v sudo >/dev/null 2>&1; then
        apk add sudo
    fi
    if ! command -v wget >/dev/null 2>&1; then
        apk add wget
    fi
    if ! command -v curl >/dev/null 2>&1; then
        apk add curl
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        apk add unzip
    fi

    if [ -f "/etc/soga/soga" ]; then
        echo -e "${red}soga已安装，请不要重复安装${plain}"
        exit 1
    fi

    if ! grep -qi "Alpine" /etc/os-release; then
        echo "${red}该脚本仅支持Alpine系统${plain}"
        exit 1
    fi

    cd /usr/local/
    if [[ -e /usr/local/soga/ ]]; then
        rm /usr/local/soga/ -rf
    fi
    
    wget -N --no-check-certificate -O /usr/local/soga.tar.gz "https://github.com/vaxilu/soga/releases/download/${last_version}/soga-linux-${arch}.tar.gz"
    tar zxvf soga.tar.gz
    rm soga.tar.gz -f
    cd soga
    chmod +x soga

    mkdir /etc/soga/ -p
    
    echo "正在写入rc-service……"
    cd /etc/init.d
    rc-service soga stop
    rc-update del soga default
    rm soga
    
    wget https://raw.githubusercontent.com/HuTuTuOnO/AirPro-SH/main/SoGa/AlPine/soga
    chmod 777 soga
    rc-update add soga default

    cd /usr/local/soga/

    if [[ ! -f /etc/soga/soga.conf ]]; then
        cp soga.conf /etc/soga/
    fi
    if [[ ! -f /etc/soga/blockList ]]; then
        cp blockList /etc/soga/
    fi
    if [[ ! -f /etc/soga/whiteList ]]; then
        cp whiteList /etc/soga/
    fi
    if [[ ! -f /etc/soga/dns.yml ]]; then
        cp dns.yml /etc/soga/
    fi
    if [[ ! -f /etc/soga/routes.toml ]]; then
        cp routes.toml /etc/soga/
    fi

    if [ $? -eq 0 ]; then
        echo -e "${green}soga已安装完成，请先配置好配置文件后再启动${plain}"
    else
        echo -e "${red}soga安装失败${plain}"
    fi

    exit 0
}

# 根据用户选择执行相应操作
echo
read -p "请输入选择 [0-11]: " option

case "$option" in
    "0")
        if [ ! -f "/etc/soga/soga" ]; then
            echo -e "${red}请先安装soga${plain}"
            exit 1
        fi
        echo
        echo -e "请选择编辑器:"
        echo -e "${green}1.${plain} vi"
        echo -e "${green}2.${plain} nano"
        read -p "请输入选择 [1-2]: " choice

        if [ "$choice" = "1" ]; then
            vi /etc/soga/soga.conf
        elif [ "$choice" = "2" ]; then
            if ! command -v nano >/dev/null 2>&1; then
                apk add nano
            fi
            nano /etc/soga/soga.conf
        else
            echo -e "${red}请输入正确的数字 [1-2]${plain}"
        fi
        ;;
    "1")
        install_soga
        ;;
    "2")
        if [ ! -f "/etc/soga/soga" ]; then
            echo -e "${red}请先安装soga${plain}"
            exit 1
        fi

        read -p "确定要卸载 soga 吗?[y/n]: " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            cd /etc/init.d
            rc-service soga stop
            rc-update del soga default
            rm soga
            rm -rf /etc/soga

            echo -e "卸载成功，如果你想删除此脚本，则退出脚本后运行 ${green}rm /usr/bin/soga${plain} 进行删除"
        else
            echo "取消卸载"
        fi
        exit 0
        ;;
    "3")
        if [ ! -f "/etc/soga/soga" ]; then
            echo -e "${red}请先安装soga${plain}"
            exit 1
        fi

        if rc-service soga status | grep -q "* status: started"; then
            echo -e "${green}soga已运行，无需再次启动${plain}"
        else
            rc-service soga start
            if [ $? -eq 0 ]; then
                echo -e "${green}soga启动成功${plain}"
            else
                echo -e "${red}soga启动失败${plain}"
            fi
        fi
        ;;
    "4")
        if [ ! -f "/etc/soga/soga" ]; then
            echo -e "${red}请先安装soga${plain}"
            exit 1
        fi
        rc-service soga stop
        if [ $? -eq 0 ]; then
            echo -e "${green}soga停止成功${plain}"
        else
            echo -e "${red}soga停止失败${plain}"
        fi
        ;;
    "5")
        if [ ! -f "/etc/soga/soga" ]; then
            echo -e "${red}请先安装soga${plain}"
            exit 1
        fi
        rc-service soga restart
        if [ $? -eq 0 ]; then
            echo -e "${green}soga重启成功${plain}"
        else
            echo -e "${red}soga重启失败${plain}"
        fi
        ;;
    "6")
        if [ ! -f "/etc/soga/soga" ]; then
            echo -e "${red}请先安装soga${plain}"
            exit 1
        fi

        rc-service soga status
        ;;
    "7")
        if [ ! -f "/etc/soga/soga" ]; then
            echo -e "${red}请先安装soga${plain}"
            exit 1
        fi
        tail -f /var/log/soga.log
        ;;
    "8")
        if [ ! -f "/etc/soga/soga" ]; then
            echo -e "${red}请先安装soga${plain}"
            exit 1
        fi

        rc-update add soga default
        if [ $? -eq 0 ]; then
            echo -e "${green}soga 已设置为开机自启${plain}"
        else
            echo -e "${red}soga 设置开机自启失败${plain}"
        fi
        ;;
    "9")
        if [ ! -f "/etc/soga/soga" ]; then
            echo -e "${red}请先安装soga${plain}"
            exit 1
        fi
        rc-update del soga default
        if [ $? -eq 0 ]; then
            echo -e "${green}soga 已取消开机自启${plain}"
        else
            echo -e "${red}soga 取消开机自启失败${plain}"
        fi
        ;;
    "10")
        if crontab -l | grep -q 'rc-service soga restart'; then
            echo -e "${yellow}soga 报错自动重启任务已存在${plain}"
        else
            (crontab -l; echo "* * * * * /bin/sh -c 'if rc-service soga status 2>&1 | grep -qE \"crashed|stopped\"; then rc-service soga restart; fi'") | crontab -
            if [ $? -eq 0 ]; then
                echo -e "${green}已开启 soga 报错自动重启${plain}"
            else
                echo -e "${red}soga 报错自动重启开启失败${plain}"
            fi
        fi
        ;;
    
    "11")
        crontab -l | grep -v 'rc-service soga restart' | crontab -
        if [ $? -eq 0 ]; then
            echo -e "${green}已取消 soga 报错自动重启${plain}"
        else
            echo -e "${red}soga 报错自动重启取消失败${plain}"
        fi
        ;;
    *)
        echo -e "${red}请输入正确的数字 [0-11]${plain}"
        ;;
esac
