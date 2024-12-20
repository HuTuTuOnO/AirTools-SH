#!/bin/bash

# 设置终端环境变量
export TERM=xterm  

VER='1.0.9'

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
  echo "错误：必须使用 root 用户运行此脚本！"
  exit 1
fi

required_packages=(jq bc curl)
for package in "${required_packages[@]}"; do
  if ! command -v "$package" &> /dev/null; then
    echo "提示：$package 未安装，正在尝试安装..."
    install_cmd=""
    if which apt &> /dev/null; then
      install_cmd="apt-get update -y > /dev/null && apt-get install -y $package > /dev/null"
    elif which yum &> /dev/null; then
      install_cmd="yum install -y $package > /dev/null"
    elif which pacman &> /dev/null; then
      install_cmd="pacman -Sy --noconfirm $package > /dev/null"
    else
      echo "错误：不支持的包管理器，请手动安装 $package。"
      exit 1
    fi
    eval "$install_cmd" || { echo "错误：安装 $package 失败。"; exit 1; }
  fi
done

# 配置文件
config_file="/opt/AirTools/Stream/client.json"
# 读取代理软件配置
proxy_soft=($(jq -r '.proxy_soft[]' < "$config_file" 2>/dev/null))
# 选择代理软件（如果未配置）
if [[ ${#proxy_soft[@]} -eq 0 ]]; then
  proxy_soft_options=("soga" "xrayr" "soga-docker")
  selected=()
  PS3="请选择要使用的代理软件: "
  while true; do
    select choice in "${proxy_soft_options[@]}" "完成" "退出"; do
      case $choice in
        "完成")
          break 2 # 退出内层和外层循环
          ;;
        "退出")
          exit 0
          ;;
        "")
          echo "无效选择."
          ;;
        *)
          selected+=("$choice")
          echo "已选择: ${selected[@]}"
          ;;
      esac
    done
  done
  proxy_soft_json=$(jq -n -c '[$ARGS.positional[]]' --args "${selected[@]}")
  # 保存选择的软件到文件
  mkdir -p "$(dirname "$config_file")"
  jq -n --argjson soft "$proxy_soft_json" '{"proxy_soft": $soft}' > "$config_file"
fi


# 解析传入参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --API) API="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# 检查 API 地址
if [[ -z "$API" ]]; then
  echo "错误：没有传入 API 地址，请使用 --API 传入有效的 API 地址。"
  exit 1
fi

# 获取 API 数据
API_RES=$(curl -s "$API")
if [[ $(echo "$API_RES" | jq -r '.code') -ne 200 ]]; then
  echo "错误：无法获取流媒体解锁状态，原因: $(echo "$API_RES" | jq -r '.msg')"
  exit 1
fi

# 解析 API 数据
if ! NODES_JSON=$(echo "$API_RES" | jq -r '.data.node // {}'); then
  echo "错误：无法解析节点数据。"
  exit 1
fi

if ! PLATFORMS_JSON=$(echo "$API_RES" | jq -r '.data.platform // {}'); then
  echo "错误：无法解析平台数据。"
  exit 1
fi

# 获取流媒体解锁状态
MEDIA_CONTENT=$(bash <(curl -L -s https://raw.githubusercontent.com/HuTuTuOnO/AirPro-SH/main/Stream/check.sh) -M 4 -R 66 | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g')

# 解析流媒体状态
declare -A media_status
while IFS= read -r line; do
  if [[ $line =~ ^(.+):[[:space:]]*(Yes|No|Failed|Originals).* ]]; then
    platform=$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    status="${BASH_REMATCH[2]}"
    media_status["$platform"]="$status"
  fi
done <<< "$MEDIA_CONTENT"

# 记录已添加的出口节点和规则
declare -A routes

# 循环对比判断是否解锁
for platform in "${!media_status[@]}"; do
  if [[ "${media_status[$platform]}" != "Yes" ]]; then
    # 检查是否存在别名和规则，并避免 null 值导致错误
    alias_list=$(echo "$PLATFORMS_JSON" | jq -r --arg platform "$platform" '.[$platform].alias // empty | select(. != null)[]')
    rules_list=$(echo "$PLATFORMS_JSON" | jq -r --arg platform "$platform" '.[$platform].rules // empty | select(. != null)[]')
    
    # 如果别名和规则为空，跳过该平台
    if [[ -z "$alias_list" || -z "$rules_list" ]]; then
      echo "警告：平台 $platform 没有找到别名或规则，跳过。"
      continue
    fi

    # 对别名进行 Ping 测试，找出最优的 alias
    best_ping=999999
    best_alias=""

    for alias in $alias_list; do
      # 获取当前节点域名
      node_domain=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].domain // empty')
      if [[ -z "$node_domain" ]]; then
        echo "警告：平台 $platform 节点 $alias 的域名为空，跳过。"
        continue
      fi

      # 进行 Ping 测试，添加重试机制
      ping_time=""
      for attempt in {1..3}; do
        ping_time=$(ping -c 1 "$node_domain" | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}')
        if [[ -n "$ping_time" ]]; then
          break
        fi
      done
      
      if [[ -z "$ping_time" ]]; then
        echo "警告：平台 $platform Ping 节点 $alias 失败，已跳过。"
        continue
      fi
      
      # 更新最优 alias
      if (( $(echo "$ping_time < $best_ping" | bc -l) )); then
        best_ping="$ping_time"
        best_alias="$alias"
      fi
    done

    # 增加容错判断是否存在 best_alias
    if [[ -z "$best_alias" ]]; then
      echo "警告：无法为平台 $platform 找到最优节点，跳过。"
      continue
    fi

    # 提示相关解锁信息
    echo "提示：平台 $platform 最优节点 $best_alias，延时 $best_ping MS"

    # 将 platform 存入 routes 生成配置文件时读取
    if [[ -z "${routes[$best_alias]}" ]]; then
      routes[$best_alias]="# $platform"
    else
      routes[$best_alias]+="^# $platform"
    fi

    # 将 rules_list 存入 routes 生成配置文件时读取
    for rule in $rules_list; do
      routes[$best_alias]+="^\"$rule\","
    done
  fi
done

# 生成 SOGA 配置文件
generate_soga_config(){
  local routes_file="$1"
   : > "$routes_file" # 清空文件
   echo "enable=true" > "$routes_file"

   for alias in $(echo "$NODES_JSON" | jq -r 'keys[]'); do
    if [[ -z "${routes[$alias]}" ]]; then
      echo "警告：节点 $alias 没有任何规则，跳过。"
      continue
    fi
  
    # 写入路由规则
    echo -e "\n# 路由 $alias\n[[routes]]\nrules=[" >> "$routes_file"
    
    IFS='^'
    for rule in ${routes[$alias]}; do
      echo "$rule" >> "$routes_file"
    done
    unset IFS
  
    echo ']' >> "$routes_file"
  
    # 获取节点信息
    node_type=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].type // empty')
    node_domain=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].domain // empty')
    node_port=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].port // empty')
    node_cipher=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].cipher // empty')
    node_password=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].uuid // empty')
  
    # 写入出口节点
    echo -e "\n# 出口 $alias\n[[routes.Outs]]\ntype=\"$node_type\"\nserver=\"$node_domain\"\nport=$node_port\npassword=\"$node_password\"\ncipher=\"$node_cipher\"" >> "$routes_file"
  done
  
  # 添加全局路由规则
  echo -e "\n# 路由 ALL\n[[routes]]\nrules=[\"*\"]\n\n# 出口 ALL\n[[routes.Outs]]\ntype=\"direct\"" >> "$routes_file"
}

# 生成 XrayR 配置文件
generate_xrayr_config() {
  local routes_file="$1"
}

# 配置文件路径
declare -A routes_files=(
  ["soga"]="/etc/soga/routes.toml"
  ["soga-docker"]="/etc/soga/routes.toml"
  ["xrayr"]="/etc/xrayr/config.json"
)

# 循环处理代理软件
for software in "${proxy_soft[@]}"; do
  routes_file="${routes_files[$software]}"
  if [[ -z "$routes_file" ]]; then
    echo "错误：未找到 $software 的路由文件配置。"
    continue
  fi
    case "$software" in
    "soga" | "soga-docker") 
      generate_soga_config "$routes_file"
      ;;
    "xrayr") 
      generate_xrayr_config "$routes_file" 
      ;;
    *) 
      echo "警告：不支持的代理软件：$software"
      ;;
  esac
  
done

