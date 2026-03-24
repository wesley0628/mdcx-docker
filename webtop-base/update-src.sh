#!/bin/bash

# 脚本说明: 当使用源码部署时，使用该脚本自动完成更新源码的处理。

# DEV:
# - gui-base/update-src.sh
# - webtop-base/update-src.sh
# - webtop-base/rootfs-src/app-assets/scripts/update-src.sh
# 除了.env提示不同外，其余部分基本相同。
# webtop-base/rootfs-src/app-assets/scripts/update-src.sh 中 appPath=/app; 没有restart容器处理。

if [ ! -f ".env" ]; then
  echo "⚠️ 当前目录缺少文件 .env。示例文件：https://github.com/northsea4/mdcx-docker/blob/main/webtop-base/.env.sample"
  # exit 1
else
  . .env
fi

# 检查是否有jq命令
if ! command -v jq &> /dev/null
then
  echo "❌ 请先安装jq命令！参考：https://command-not-found.com/jq"
  exit 1
fi


FILE_INITIALIZED=".mdcx_initialized"

# 应用版本
appVersion=0

# 源码存放目录
appPath="./app"

# release tag
tagName="latest"

# 更新源码后，是否重启容器
restart=false

while [[ $# -gt 0 ]]
do
  key="$1"
  case $key in
    -p|--path|--src)
      appPath="$2"
      shift 2
      shift
      ;;
    -t|--tag)
      tagName="$2"
      shift 2
      ;;
    --restart)
      restart="$2"
      shift
      shift
      ;;
    --dry)
      dry=1
      shift
      ;;
    --verbose)
      verbose=1
      shift
      ;;
    -h|--help)
      help=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done


if [ -n "$help" ]; then
  echo "脚本功能：更新自部署的应用源码"
  echo ""
  echo "示例-检查并更新:    $0"
  echo ""
  echo "参数说明："
  echo "--src, --path, -p         指定源码存放目录，默认 ./app"
  echo "--tag                     指定要更新的版本标签，默认latest"
  echo "--restart                 更新后重启容器，默认false。可选参数值: 1, 0; true, false"
  echo "--dry                     只检查，不更新"
  echo "-h, --help                显示帮助信息"
  exit 0
fi

generate_app_version() {
  local published_at="$1"

  # 去除非数字字符
  published_at=$(echo "$published_at" | tr -dc '0-9')

  # 取前8位数字作为年月日，前缀为d
  echo "d${published_at:0:8}"
}

find_release_by_tag_name() {
  local repo=$1
  local target_tag_name=$2
  
  local url="https://api.github.com/repos/${repo}/releases"

  local target_release=""

  local found=false
  local page=1
  while true; do
    local response=$(curl -s "${url}?per_page=100&page=${page}")
    if [[ -z "$response" ]]; then
      break
    fi

    local array_size=$(printf '%s' "$response" | jq 'length')
    if [[ "$array_size" == "0" ]]; then
      break
    fi

    local temp_file=$(mktemp)
    printf '%s' "$response" > "$temp_file"

    local matched_release=$(cat "$temp_file" | jq -c --arg tag "$target_tag_name" '.[] | select(.tag_name == $tag)')
    rm -f "$temp_file"

    if [[ -n "$matched_release" ]]; then
      printf '%s' "$matched_release"
      found=true
      break
    fi

    page=$((page + 1))
  done

  if [[ "$found" == "false" ]]; then
    return 1
  fi
}

fetch_release_info() {
  local repo="$1"
  local tag_name="$2"

  local temp_file=$(mktemp)

  local url="https://api.github.com/repos/${repo}/releases/tags/${tag_name}"

  if [[ "$tag_name" == "latest" ]]; then
    url="https://api.github.com/repos/${repo}/releases/latest"
  fi

  curl -s "${url}" > "$temp_file"
  if [[ ! -s "$temp_file" ]]; then
    rm -f "$temp_file"
    echo "❌ 无法获取release信息！"
    return 1
  fi

  local message=$(cat "$temp_file" | jq -r '.message // empty' 2>/dev/null)
  if [[ -n "$message" ]]; then
    rm -f "$temp_file"
    echo "❌ API错误：$message"
    return 1
  fi

  cat "$temp_file" | jq -c '.'
  rm -f "$temp_file"
  return 0
}

# 获取指定仓库和tag_name的release，并解析得到release信息
get_release_info() {
  local repo="$1"
  local tag_name="$2"

  local release=""

  release=$(fetch_release_info "$repo" "$tag_name")
  if [[ $? -ne 0 || -z "$release" ]]; then
    release=$(find_release_by_tag_name "$repo" "$tag_name")
  fi

  if [[ -z "$release" ]]; then
    echo "❌ 找不到 tag_name=${tag_name} 的release！"
    return 1
  fi

  local tag_name_from_json=$(printf '%s' "$release" | jq -r '.tag_name')
  if [[ -z "$tag_name_from_json" || "$tag_name_from_json" == "null" ]]; then
    echo "❌ 找不到 tag_name！"
    return 1
  fi

  published_at=$(printf '%s' "$release" | jq -r '.published_at')
  if [[ -z "$published_at" || "$published_at" == "null" ]]; then
    echo "❌ 找不到 published_at！"
    return 1
  fi

  release_version=$(generate_app_version "$published_at")

  tar_url=$(printf '%s' "$release" | jq -r '.tarball_url')
  if [[ -z "$tar_url" || "$tar_url" == "null" ]]; then
    echo "❌ 从请求结果获取源码压缩包文件下载链接失败！"
    return 1
  fi

  zip_url=$(printf '%s' "$release" | jq -r '.zipball_url')
  if [[ -z "$zip_url" || "$zip_url" == "null" ]]; then
    echo "❌ 从请求结果获取源码压缩包文件下载链接失败！"
    return 1
  fi

  local data="{
    \"tag_name\": \"${tag_name_from_json}\",
    \"published_at\": \"${published_at}\",
    \"release_version\": \"${release_version}\",
    \"tar_url\": \"${tar_url}\",
    \"zip_url\": \"${zip_url}\"
  }"
  echo $data
  return 0
}

appPath=$(echo "$appPath" | sed 's:/*$::')

if [[ -n "${appPath}" ]]; then
  if [[ ! -d "${appPath}" ]]; then
    echo "⚠️ $appPath 不存在，现在创建"
    mkdir -p $appPath
  else
    echo "✅ $appPath 已经存在"
  fi
else
  echo "❌ 应用源码目录参数不能为空！"
  exit 1
fi

REPO="Hazard804/mdcx"
TAG_NAME="${tagName}"

info=$(get_release_info "$REPO" "$TAG_NAME")
if [[ $? -ne 0 ]]; then
  echo "❌ 获取仓库 ${REPO} 中 tag_name=${TAG_NAME} 的release信息失败！"
  exit 1
else
  echo "✅ 获取仓库 ${REPO} 中 tag_name=${TAG_NAME} 的release信息成功！"
fi
echo $info | jq
# exit 0

# 发布时间
published_at=$(printf '%s' $info | jq -r ".published_at")
echo "📅 发布时间: $published_at"

# 版本号
release_version=$(printf '%s' $info | jq -r ".release_version")
echo "🔢 版本号: $release_version"

# 源码链接
file_url=$(printf '%s' $info | jq -r ".tar_url")
echo "🔗 下载链接: $file_url"


if [[ -z "$file_url" ]]; then
  echo "❌ 从请求结果获取下载链接失败！"
  exit 1
fi

if [[ -n "$dry" ]]; then
  exit 0
fi

file_path="$release_version.tar.gz"

if [[ -n "$verbose" ]]; then
  curl -o $file_path $file_url -L
else
  curl -so $file_path $file_url -L
fi

if [[ $? -ne 0 ]]; then
  echo "❌ 下载源码压缩包失败！"
  exit 1
fi

echo "✅ 下载成功"
echo "⏳ 开始解压..."

# 解压新的源码到app目录
tar -zxvf $file_path -C $appPath --strip-components 1
# 删除压缩包
rm -f $file_path
echo "✅ 源码已覆盖到 $appPath"

if [ -f ".env.versions" ]; then
  echo "✅ 更新 .env.versions MDCX_APP_VERSION=$release_version"
  sed -i -e "s/MDCX_APP_VERSION=[0-9.]\+/MDCX_APP_VERSION=$release_version/" .env.versions
fi

if [ -f ".env" ]; then
  echo "✅ 更新 .env APP_VERSION=$release_version"
  sed -i -e "s/APP_VERSION=[0-9.]\+/APP_VERSION=$release_version/" .env
fi

echo "ℹ️ 删除标记文件 $appPath/$FILE_INITIALIZED"
rm -f "$appPath/$FILE_INITIALIZED"

if [[ -n "MDCX_SRC_CONTAINER_NAME" ]]; then
  if [[ "$restart" == "1" || "$restart" == "true" ]]; then
    echo "⏳ 重启容器..."
    docker restart $MDCX_SRC_CONTAINER_NAME
  else
    echo "ℹ️ 如果已经部署过容器，执行以下命令重启容器"
    echo "docker restart $MDCX_SRC_CONTAINER_NAME"
  fi
fi

echo "🎉 Enjoy~"