#!/bin/bash

VER='1.0.9'

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
  echo "错误：必须使用 root 用户运行此脚本！"
  exit 1
fi

# 检查并安装 JQ 和 BC
if ! command -v jq &> /dev/null; then
  echo "提示：JQ 未安装，正在安装..."
  if [[ -f /etc/debian_version ]]; then
    apt-get update && apt-get install -y jq
  else
    echo "错误：不支持的操作系统，请手动安装 JQ。"
    exit 1
  fi
fi

if ! command -v bc &> /dev/null; then
  echo "提示：BC 未安装，正在安装..."
  if [[ -f /etc/debian_version ]]; then
    apt-get update && apt-get install -y bc
  else
    echo "错误：不支持的操作系统，请手动安装 BC。"
    exit 1
  fi
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

# 配置文件路径
routes_file="/etc/soga/routes.toml"
if [[ ! -f "$routes_file" ]]; then
  echo "错误：配置文件路径不存在，请检查路径！"
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

# 清空并初始化配置文件
: > "$routes_file"
echo "enable=true" > "$routes_file"

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

echo "配置文件生成完成：$routes_file"

# 重启 SOGA 服务
if soga restart 2>&1; then
  echo "提示：SOGA 服务重启成功。"
else
  echo "错误：SOGA 服务重启失败。"
fi
