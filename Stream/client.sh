#!/bin/bash

VER='1.0.0'

# 检查是否为root用户
[[ $EUID -ne 0 ]] && echo -e "错误：必须使用root用户运行此脚本！\n" && exit 1

# 检查并安装 JQ 和 BC
if ! command -v jq &> /dev/null || ! command -v bc &> /dev/null; then
  echo "提示：JQ 或 BC 未安装，正在安装..."
  if [[ -f /etc/debian_version ]]; then
    apt-get update
    apt-get install -y jq bc
  else
    echo "错误：不支持的操作系统，请手动安装 JQ 和 BC。"
    exit 1
  fi
fi

# 解析传入的参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --API)
      API="$2"
      shift 2
      ;;
    *)
      echo "未知参数: $1"
      exit 1
      ;;
  esac
done

# 检查是否传入了API地址
if [[ -z "$API" ]]; then
  echo "错误：没有传入API地址，请使用 --API 传入有效的API地址。"
  exit 1
fi

# 获取流媒体解锁状态
API_RESPONSE=$(curl -s "$API")
CODE=$(echo "$API_RESPONSE" | jq -r '.code')
MSG=$(echo "$API_RESPONSE" | jq -r '.msg')

if [[ "$CODE" -ne 200 ]]; then
  echo "错误：无法获取流媒体解锁状态，原因: $MSG"
  exit 1
fi

# 读取解锁节点和平台信息
NODES_JSON=$(echo "$API_RESPONSE" | jq -r '.data.node // {}')
PLATFORMS_JSON=$(echo "$API_RESPONSE" | jq -r '.data.platform // {}')

# 初始化配置文件路径
routes_file="/etc/soga/routes.toml"

# 检查文件是否存在
if [[ ! -f "$routes_file" ]]; then
  echo "错误：配置文件路径不存在，请检查路径！"
  exit 1
fi

# 清空文件内容
: > "$routes_file"

# 添加头部内容
echo -e "enable=true" > "$routes_file"

# 记录已添加的出口节点和规则
declare -A routes
declare -A nodes_info

# 处理解锁平台信息
for platform in $(echo "$PLATFORMS_JSON" | jq -r 'keys[]'); do
  alias_list=$(echo "$PLATFORMS_JSON" | jq -r --arg platform "$platform" '.[$platform].alias | join(" ")')
  rules_list=$(echo "$PLATFORMS_JSON" | jq -r --arg platform "$platform" '.[$platform].rules | join(" ")')

  for alias in $alias_list; do
    node_info=$(echo "$NODES_JSON" | jq -r --arg alias "$alias" '.[$alias]')

    # 检查是否获取到有效的节点信息
    if [[ -z "$node_info" ]]; then
      echo "警告：无法找到别名 $alias 对应的节点信息，跳过该节点。"
      continue
    fi

    node_key=$(echo "$node_info" | jq -r '.domain')
    node_type=$(echo "$node_info" | jq -r '.type')
    node_port=$(echo "$node_info" | jq -r '.port')
    node_password=$(echo "$node_info" | jq -r '.uuid')
    node_cipher=$(echo "$node_info" | jq -r '.cipher')

    # 初始化节点路由信息
    if [[ -z "${routes[$node_key]}" ]]; then
      routes[$node_key]=""
      nodes_info[$node_key]="listen=\"\"\ntype=\"$node_type\"\nserver=\"$node_key\"\nport=$node_port\npassword=\"$node_password\"\ncipher=\"$node_cipher\""
    fi

    # 添加流媒体平台的域名规则
    rules_str=$(echo "$rules_list" | sed 's/ /",\n    "domain:/g')
    rules_str="\"domain:$rules_str\""

    # 按照你提供的格式添加节点和规则
    routes[$node_key]+="#$platform\n[[routes]]\nrules=[\n    \"#$platform\",\n    $rules_str,\n    \"#$platform--->\"\n]\n\n[[routes.Outs]] #路由 $alias 出口\n${nodes_info[$node_key]}"
  done
done

# 写入配置文件
for node_key in "${!routes[@]}"; do
  echo -e "${routes[$node_key]}" >> "$routes_file"
done

# 添加尾部内容
echo -e "\n[[routes]]\nrules=[\"*\"]\n\n[[routes.Outs]]\ntype=\"direct\"" >> "$routes_file"

echo "提示：配置文件已生成。"

echo "提示：正在重启SOGA服务。"

SOGA_RESTART=$(soga restart 2>&1)

# 检查命令是否成功
if [[ $? -eq 0 ]]; then
  echo "提示：SOGA服务重启成功。"
else
  echo "错误：SOGA服务重启失败。"
fi
