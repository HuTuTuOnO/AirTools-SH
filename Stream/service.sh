#!/bin/bash

VER='1.0.0'

# 检查是否为root用户
[[ $EUID -ne 0 ]] && echo -e "错误：必须使用root用户运行此脚本！\n" && exit 1

# 检查并安装 JQ 
if ! command -v jq &> /dev/null ; then
  echo "提示：JQ 或 BC 未安装，正在安装..."
  if [[ -f /etc/debian_version ]]; then
    apt-get update
    apt-get install -y jq
  else
    echo "错误：不支持的操作系统，请手动安装 JQ"
    exit 1
  fi
fi

# 定义 JSON 文件路径
CONFIG_FILE="/opt/AirPro/Stream.json"

# 检查 JQ 是否存在
if ! command -v jq &> /dev/null; then
  echo "jq 命令未安装。请安装 JQ 后再运行脚本。"
  exit 1
fi

# 检查配置文件是否存在，如果不存在则提示用户输入并保存
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "配置文件不存在，请输入以下信息："
  read -p "请输入 API 地址: " API
  read -p "请输入 ID: " ID

  # 保存到 JSON 文件中
  mkdir -p "$(dirname "$CONFIG_FILE")"  # 确保目录存在
  echo "{\"api\": \"$API\", \"id\": \"$ID\"}" > "$CONFIG_FILE"
  echo "配置已保存到 $CONFIG_FILE"
else
  # 从 JSON 文件中读取 API 和 ID
  API=$(jq -r '.api' "$CONFIG_FILE")
  ID=$(jq -r '.id' "$CONFIG_FILE")
fi

# 获取流媒体解锁状态
MEDIA_CONTENT=$(bash <(curl -L -s https://down.vmssr.net/Stream/check.sh) -M 4 -R 66 2>&1 | sed 's/\x1B\[[0-9;]*[a-zA-Z]//g')

# 读取流媒体状态
declare -A media_status
declare -a unlocked_platforms

while IFS= read -r line; do
  if [[ $line =~ ^(.+):[[:space:]]*(Yes|No|Failed|Originals).* ]]; then
    platform=$(echo "${BASH_REMATCH[1]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    status="${BASH_REMATCH[2]}"
    media_status["$platform"]="$status"
    
    # 如果状态为 Yes，则将平台添加到解锁平台数组中
    if [[ "$status" == "Yes" ]]; then
      unlocked_platforms+=("$platform")
    fi
  fi
done <<< "$MEDIA_CONTENT"

# 提交到AirPro平台
response=$(curl -X POST -H "Content-Type: application/json" -d "$(jq -n --arg id "$ID" --argjson platforms "$(printf '%s\n' "${unlocked_platforms[@]}" | jq -R . | jq -s .)" '{id: $id, platform: $platforms}')" "$API")

echo "POST 请求结果：$response"
