#!/bin/bash

# 脚本版本
VER='1.0.9'

# 颜色变量
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 打印彩色消息
print_message() {
  echo -e "$1$2$NC"
}

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
  print_message "$RED" "错误：此脚本必须以 root 用户身份运行！\n"
  exit 1
fi

# 安装必要的软件包
required_packages=(jq bc curl)
for package in "${required_packages[@]}"; do
  if ! command -v "$package" &> /dev/null; then
    print_message "$YELLOW" "提示：$package 未安装，正在尝试安装...\n"
    install_cmd=""
    if which apt &> /dev/null; then
      install_cmd="apt-get update -y > /dev/null && apt-get install -y $package > /dev/null"
    elif which yum &> /dev/null; then
      install_cmd="yum install -y $package > /dev/null"
    elif which pacman &> /dev/null; then
      install_cmd="pacman -Sy --noconfirm $package > /dev/null"
    else
      print_message "$RED" "错误：不支持的包管理器，请手动安装 $package。\n"
      exit 1
    fi
    eval "$install_cmd" || { print_message "$RED" "错误：安装 $package 失败。\n"; exit 1; }
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
  PS3="请选择要使用的代理软件 (多选，用空格分隔序号, 回车确认): "
  select choices in "${proxy_soft_options[@]}" "退出"; do
    case $choices in
      "退出")
        exit 0
        ;;
      *)
        selected+=("$choices")
        ;;
    esac
  done < <(
    for i in "${!proxy_soft_options[@]}"; do
      printf "%s) %s\n" "$((i+1))" "${proxy_soft_options[i]}"
    done
    echo "q) 退出"
  )

  proxy_soft_json=$(jq -n -c '[$ARGS.positional[]]' --args "${selected[@]}")

  # 保存选择的软件到文件
  mkdir -p "$(dirname "$config_file")"
  jq -n --argjson soft "$proxy_soft_json" '{"proxy_soft": $soft}' > "$config_file"
fi


# 解析 API URL
while [[ $# -gt 0 ]]; do
  case "$1" in
    --API) API="$2"; shift 2 ;;
    *) print_message "$RED" "错误：未知参数: $1\n"; exit 1 ;;
  esac
done

# 检查 API 地址
if [[ -z "$API" ]]; then
  print_message "$RED" "错误：未提供 API 地址，请使用 --API <URL>。\n"
  exit 1
fi

# 获取并解析 API 数据
get_api_data() {
  API_RES=$(curl -s "$API")
  if [[ $(echo "$API_RES" | jq -r '.code') -ne 200 ]]; then
    print_message "$RED" "错误：API 请求失败: $(echo "$API_RES" | jq -r '.msg')\n"
    return 1
  fi
  NODES_JSON=$(echo "$API_RES" | jq -r '.data.node // {}')
  PLATFORMS_JSON=$(echo "$API_RES" | jq -r '.data.platform // {}')
  [[ -n "$NODES_JSON" && -n "$PLATFORMS_JSON" ]] # 检查是否成功解析
}

if ! get_api_data; then
  exit 1
fi


# 获取流媒体解锁状态 (可以考虑将 check.sh 集成到此脚本中)
media_content=$(bash <(curl -L -s https://raw.githubusercontent.com/HuTuTuOnO/AirPro-SH/main/Stream/check.sh) -M 4 -R 66 | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g')

# 解析流媒体状态
declare -A media_status
while IFS= read -r line; do
  if [[ $line =~ ^(.+):[[:space:]]*(Yes|No|Failed|Originals).* ]]; then
    platform="${BASH_REMATCH[1]## }" # 更简洁的空格去除方式
    status="${BASH_REMATCH[2]}"
    media_status["$platform"]="$status"
  fi
done <<< "$media_content"


# 记录路由规则
declare -A routes

# 循环处理平台和节点
for platform in "${!media_status[@]}"; do
  if [[ "${media_status[$platform]}" != "Yes" ]]; then
    alias_list=$(echo "$PLATFORMS_JSON" | jq -r --arg platform "$platform" '.[$platform].alias // [] | select(. != null)[]') # 处理空数组
    rules_list=$(echo "$PLATFORMS_JSON" | jq -r --arg platform "$platform" '.[$platform].rules // [] | select(. != null)[]') # 处理空数组

    # 跳过没有别名或规则的平台
    if [[ -z "$alias_list" || -z "$rules_list" ]]; then
      print_message "$YELLOW" "警告：平台 $platform 没有找到别名或规则，跳过。\n"
      continue
    fi


    # 查找最优节点 (Ping 测试)
    best_ping=999999
    best_alias=""
    for alias in $alias_list; do
      node_domain=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].domain // empty')
      if [[ -z "$node_domain" ]]; then
        print_message "$YELLOW" "警告：平台 $platform 节点 $alias 的域名为空，跳过。\n"
        continue
      fi

      # Ping 测试 with retry
      ping_time=""
      for attempt in {1..3}; do
        ping_time=$(ping -c 1 -W 1 "$node_domain" 2>&1 | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}') # 添加超时控制
        if [[ -n "$ping_time" ]]; then
          break
        fi
      done

      if [[ -z "$ping_time" ]]; then
        print_message "$YELLOW" "警告：平台 $platform Ping 节点 $alias 失败，已跳过。\n"
        continue
      fi

      if (( $(echo "$ping_time < $best_ping" | bc -l) )); then
        best_ping="$ping_time"
        best_alias="$alias"
      fi
    done

    # 如果没有找到最优节点，则跳过
    if [[ -z "$best_alias" ]]; then
      print_message "$YELLOW" "警告：无法为平台 $platform 找到最优节点，跳过。\n"
      continue
    fi

    print_message "$GREEN" "提示：平台 $platform 最优节点 $best_alias，延时 $best_ping ms\n"


    # 构建路由规则字符串
    routes[$best_alias]+="# $platform\n"
    for rule in $rules_list; do
      routes[$best_alias]+="\"$rule\",\n" # 注意逗号和换行
    done

  fi
done



# 配置文件路径
declare -A routes_files=(
  ["soga"]="/etc/soga/routes.conf"
  ["soga-docker"]="/etc/soga/routes.conf"
  ["xrayr"]="/etc/xrayr/config.json"
)

# 生成 SOGA 配置文件
generate_soga_config() {
  local routes_file="$1"
  : > "$routes_file" # 清空文件
  echo "enable=true" > "$routes_file"

  for alias in $(echo "$NODES_JSON" | jq -r 'keys[]'); do
    if [[ -n "${routes[$alias]}" ]]; then  # 检查是否存在路由规则
      echo -e "\n# 路由 $alias\n[[routes]]\nrules=[${routes[$alias]%*,}\n]" >> "$routes_file" # 使用参数扩展去除最后一个逗号

      # 获取节点信息 (可以使用jq一次性获取所有信息)
      node_info=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias] | "\(.type // empty)\n\(.domain // empty)\n\(.port // empty)\n\(.uuid // empty)\n\(.cipher // empty)"')
      read -r node_type node_domain node_port node_uuid node_cipher <<< "$node_info"

      echo -e "\n# 出口 $alias\n[[routes.Outs]]\ntype=\"$node_type\"\nserver=\"$node_domain\"\nport=$node_port\npassword=\"$node_uuid\"\ncipher=\"$node_cipher\"" >> "$routes_file"
    fi
  done

  echo -e "\n# 路由 ALL\n[[routes]]\nrules=[\"*\"]\n\n# 出口 ALL\n[[routes.Outs]]\ntype=\"direct\"" >> "$routes_file"
}


# 生成 XrayR 配置文件
generate_xrayr_config() {
  local routes_file="$1"

  # 构建 routing rules (更简洁的 jq 用法)
  routing_rules=$(jq -n \
    --argjson routes "$routes" \
    --argjson nodes "$NODES_JSON" \
    '{
      "domainStrategy": "AsIs",
      "rules": [
        {
          "type": "field",
          "outboundTag": "direct",
          "domain": ["geosite:private", "geosite:cn"]
        },
        ($routes | to_entries[] | select(.value != null) | {
          "type": "field",
          "outboundTag": .key,
          "domain": (.value | split("\n") | map(select(startswith("\"") and endswith("\""))) | unique)
        })
      ]
    }')


  # 获取默认 UUID 和 domain (错误处理)
  default_uuid=$(echo "$NODES_JSON" | jq -r 'keys[] | first | . as $key | .[$key].uuid // empty')
  default_domain=$(echo "$NODES_JSON" | jq -r 'keys[] | first | . as $key | .[$key].domain // empty')
  if [[ -z "$default_uuid" || -z "$default_domain" ]]; then
    print_message "$RED" "错误：无法获取默认 UUID 或 Domain。\n"
    return 1
  fi

  # 构建完整的 XrayR 配置 (更简洁的 jq 用法)
  xrayr_config=$(jq -n \
    --arg routing_rules "$routing_rules" \
    --arg uuid "$default_uuid" \
    --arg domain "$default_domain" \
    --argjson nodes "$NODES_JSON" \
    '{
      "log": {"loglevel": "warning"},
      "inbounds": [
        {"port": 443, "protocol": "vless", "settings": {"clients": [{"id": $uuid}]}, "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": $domain}}}
      ],
      "outbounds": [
        {"protocol": "freedom", "settings": {}},
        {"protocol": "blackhole", "settings": {}, "tag": "block"},
        ($nodes | to_entries[] | {
          "tag": .key,
          "protocol": "vless",
          "settings": {
            "vnext": [
              {
                "address": .value.domain,
                "port": .value.port|tonumber,
                "users": [{"id": .value.uuid, "encryption": "none", "level": 0}]
              }
            ]
          },
          "streamSettings": {"network": "tcp", "security": "tls", "tlsSettings": {"serverName": .value.domain}}
        })
      ],
      "routing": $routing_rules|fromjson
    }')

  echo "$xrayr_config" > "$routes_file"
}


# 循环处理代理软件
for software in "${proxy_soft[@]}"; do
  routes_file="${routes_files[$software]}"
  if [[ -z "$routes_file" ]]; then
    print_message "$RED" "错误：未找到 $software 的路由文件配置。\n"
    continue
  fi

  case "$software" in
    "soga" | "soga-docker") generate_soga_config "$routes_file" ;;
    "xrayr") generate_xrayr_config "$routes_file" ;;
    *) print_message "$YELLOW" "警告：不支持的代理软件：$software\n" ;;
  esac

  if [[ -f "$routes_file" ]]; then
    print_message "$GREEN" "配置文件 $software 生成完成：$routes_file\n"
  else
    print_message "$RED" "错误：$software 配置文件生成失败。\n"
  fi
done

# 循环处理代理软件
for software in "${proxy_soft[@]}"; do
  # ... (之前的循环内代码不变)

  # 重启服务
  case "$software" in
    "soga")
      if systemctl is-active --quiet soga; then
        systemctl restart soga
        restart_result=$?
      elif which soga &> /dev/null; then # 检查 soga 命令是否存在
        soga restart # 如果 soga 不是 systemd 服务，尝试直接使用命令重启
        restart_result=$?
      else
        print_message "$YELLOW" "警告：找不到 soga 服务或命令，无法重启。\n"
        restart_result=1
      fi
      ;;
    "soga-docker")
      container_name=$(docker ps -a -f "ancestor=vaxilu/soga" -q)
      if [[ -n "$container_name" ]]; then
        docker restart "$container_name"
        restart_result=$?
      else
        print_message "$RED" "错误：找不到 vaxilu/soga 镜像的容器。\n"
        restart_result=1
      fi
      ;;
    "xrayr")
      if systemctl is-active --quiet xrayr; then
        systemctl restart xrayr
        restart_result=$?
      elif which xrayr &> /dev/null; then
        xrayr restart
        restart_result=$?
      else
        print_message "$YELLOW" "警告：找不到 xrayr 服务或命令，无法重启。\n"
        restart_result=1
      fi
      ;;
  esac

  if [[ $restart_result -eq 0 ]]; then
    print_message "$GREEN" "$software 重启成功。\n"
  else
    print_message "$RED" "错误：$software 重启失败。\n"
  fi
done
