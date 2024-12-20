#!/bin/bash

# 设置终端环境变量
export TERM=xterm

VER='1.0.9'

# 定义颜色变量 (可选)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 函数：打印彩色消息
print_message() {
  local color="$1"
  local message="$2"
  echo -e "${color}${message}${NC}"
}

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
  print_message "$RED" "错误：必须使用 root 用户运行此脚本！"
  exit 1
fi

# 检查并安装 JQ 和 BC (使用更通用的方法)
required_packages=(jq bc)
for package in "${required_packages[@]}"; do
  if ! command -v "$package" &> /dev/null; then
    print_message "$YELLOW" "提示：$package 未安装，正在尝试安装..."
    if which apt &> /dev/null; then
      apt-get update -y && apt-get install -y "$package"
    elif which yum &> /dev/null; then
      yum install -y "$package"
    else
      print_message "$RED" "错误：不支持的包管理器，请手动安装 $package。"
      exit 1
    fi
  fi
done

# 获取代理软件
config_file="/opt/AirTools/Stream/client.json"

# 检查配置文件是否存在并读取
if [[ -f "$config_file" ]]; then
  proxy_soft=($(jq -r '.proxy_soft[]' < "$config_file"))  # 正确读取数组
fi

# 如果没有配置文件，则进行选择
if [[ ${#proxy_soft[@]} -eq 0 ]]; then
  proxy_soft_options=("soga" "xrayr" "soga-docker")
  while true; do
    echo "请选择要使用的代理软件 (多选，用空格分隔，例如：1 2 3):"
    for i in "${!proxy_soft_options[@]}"; do
      echo "$((i+1)). ${proxy_soft_options[$i]}"
    done
    read -r choices

    proxy_soft=()
    for choice in $choices; do
      if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#proxy_soft_options[@]}" ]]; then
        index=$((choice - 1))
        proxy_soft+=("${proxy_soft_options[$index]}")
      else
        echo "无效的选择: $choice"
      fi
    done

    if [[ ${#proxy_soft[@]} -gt 0 ]]; then
      # 保存选择的软件到文件
      mkdir -p "$(dirname "$config_file")"  # 使用 $config_file
      # 使用 printf 和 jq 构建 JSON 数组 (与之前版本相同)
      printf '{"proxy_soft": ['
      for i in "${!proxy_soft[@]}"; do
        printf '"%s"' "${proxy_soft[$i]}"
        if [[ $i -lt $(( ${#proxy_soft[@]} - 1 )) ]]; then
          printf ','
        fi
      done
      printf ']}\n' | jq . > "$config_file" # 使用 $config_file
      break
    else
      echo "请至少选择一个代理软件。"
    fi
  done
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
media_content=$(bash <(curl -L -s https://raw.githubusercontent.com/HuTuTuOnO/AirPro-SH/main/Stream/check.sh) -M 4 -R 66 | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g')

# 解析流媒体状态
declare -A media_status
while IFS= read -r line; do
  if [[ $line =~ ^(.+):[[:space:]]*(Yes|No|Failed|Originals).* ]]; then
    platform=$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    status="${BASH_REMATCH[2]}"
    media_status["$platform"]="$status"
  fi
done <<< "$media_content"

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

# 生成配置文件
declare -A routes_files=(
  ["soga"]="/etc/soga/routes.conf"
  ["soga-docker"]="/etc/soga/routes.conf"
  ["xrayr"]="/etc/xrayr/config.json"
)

for software in "${proxy_soft[@]}"; do
  routes_file="${routes_files[$software]}"

  if [[ -z "$routes_file" ]]; then
    print_message "$RED" "错误：未找到 $software 的路由文件配置。"
    continue
  fi

  # 创建配置文件的备份 (可选)
  if [[ -f "$routes_file" ]]; then
    cp "$routes_file" "$routes_file.bak"
  fi

  case "$software" in
    "soga" | "soga-docker")
      # ... (SOGA 配置文件生成逻辑)
      
      # 清空并初始化配置文件
      : > "$routes_file"
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
      ;;
    "xrayr")
      # ... (XrayR 配置文件生成逻辑，使用 $routes_file)
        # 构建 XrayR 的 routing rules
        routing_rules='{"domainStrategy": "AsIs","rules": ['
        for alias in "${!routes[@]}"; do
            # 获取节点信息
            node_domain=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].domain // empty')
            if [[ -n "$node_domain" ]]; then # 确保域名不为空
                routing_rules+="{\"type\": \"field\",\"outboundTag\": \"$alias\",\"domain\": [$(echo "${routes[$alias]}" | sed 's/\^//g' | sed 's/,$//g')]},"
            fi
        done
        routing_rules+="{\"type\": \"field\",\"outboundTag\": \"direct\",\"domain\": [\"geosite:private\",\"geosite:cn\"]}]}"
      
      
        # 构建完整的 XrayR 配置
        xrayr_config=$(jq -n \
            --arg routing_rules "$routing_rules" \
            '{
              "log": {"loglevel": "warning"},
              "inbounds": [
                {"port": 443, "protocol": "vless", "settings": {"clients": [{"id": "YOUR_UUID"}]}, "streamSettings": {"network": "tcp","security": "tls","tlsSettings": {"serverName": "YOUR_DOMAIN"}}}
              ],
              "outbounds": [
                {"protocol": "freedom", "settings": {}}, # 默认直连出口
                {"protocol": "blackhole", "settings": {}, "tag": "block"}
              ],
              "routing": $routing_rules
            }'
        )
      
      
      
        # 添加每个 alias 对应的 outbound 配置
        for alias in "${!routes[@]}"; do
          node_type=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].type // empty')
          node_domain=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].domain // empty')
          node_port=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].port // empty')
          node_cipher=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].cipher // empty')  # 注意：这里使用 cipher
          node_uuid=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias].uuid // empty') # 使用 uuid
      
      
          xrayr_config=$(echo "$xrayr_config" | jq --arg alias "$alias" \
              --arg node_type "$node_type" \
              --arg node_domain "$node_domain" \
              --arg node_port "$node_port" \
              --arg node_uuid "$node_uuid" \
              '.outbounds += [{
                "tag": $alias,
                "protocol": "vless",
                "settings": {
                  "vnext": [
                    {
                      "address": $node_domain,
                      "port": $node_port|tonumber,
                      "users": [
                        {"id": $node_uuid, "encryption": "none", "level": 0}
                      ]
                    }
                  ]
                },
                "streamSettings": {
                  "network": "tcp",
                  "security": "tls",
                  "tlsSettings": {"serverName": $node_domain}
                }
              }]')
        done
      
        echo "$xrayr_config" > "$routes_file"
      ;;
    *)
      print_message "$YELLOW" "警告：不支持的代理软件：$software"
      ;;
  esac

  if [[ -f "$routes_file" ]]; then
    print_message "$GREEN" "配置文件 $software 生成完成：$routes_file"
  else
    print_message "$RED" "错误：$software 配置文件生成失败。"
    #  如果生成失败，尝试恢复备份 (可选)
    if [[ -f "$routes_file.bak" ]]; then
      mv "$routes_file.bak" "$routes_file"
    fi
  fi
done
