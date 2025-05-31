#!/bin/bash

# 设置终端环境变量
export TERM=xterm  

VER='1.0.0'

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

# 配置文件路径
config_file="/opt/AirTools/Stream/client.json"

# 检查配置文件是否存在，如果不存在则创建一个默认文件
if [[ ! -f "$config_file" ]]; then
  echo "提示：配置文件不存在，正在创建一个默认配置文件。"
  mkdir -p "$(dirname "$config_file")"
  echo '{"proxy_soft": []}' > "$config_file"
fi

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
  # 直接设置 proxy_soft 为已选择的值
  proxy_soft=("${selected[@]}")
  # 保存选择的软件到文件
  jq -n --argjson soft "$(jq -n -c '[$ARGS.positional[]]' --args "${selected[@]}")" '{"proxy_soft": $soft}' > "$config_file"
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
MEDIA_CONTENT=$(bash <(curl -L -s check.unlock.media) -M 4 -R 66 | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g')

# 解析流媒体状态
declare -A media_status
while IFS= read -r line; do
  if [[ $line =~ ^(.+):[[:space:]]*(Yes|No|Failed|Originals).* ]]; then
    platform=$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    status="${BASH_REMATCH[2]}"
    media_status["$platform"]="$status"
  fi
done <<< "$MEDIA_CONTENT"
