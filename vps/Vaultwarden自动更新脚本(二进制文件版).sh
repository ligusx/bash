#!/bin/bash
# ================= 配置区（请按实际情况修改） =================
# 你当前 Vaultwarden 的运行目录（二进制和 web-vault 所在位置）
VW_RUN_DIR="/opt/1panel/apps/openresty/openresty/www/sites/passwd.ligus.cc/index"

# 你的数据目录（通常包含 db.sqlite3，脚本不会动这里，仅用于确认）
VW_DATA_DIR="/opt/1panel/apps/openresty/openresty/www/sites/passwd.ligus.cc/index/data"

# Supervisor 进程名（用 supervisorctl status 查到的 名称:名称_00 格式）
VW_SUPERVISOR_NAME="vaultwarden:vaultwarden_00"

# Supervisor 的 supervisorctl 路径（一般无需修改）
SUPERVISORCTL="/usr/bin/supervisorctl"

# 临时提取目录
TMP_DIR="/tmp/vw-extract"
# ============================================================

# 修复宝塔计划任务环境变量问题
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export SHELL=/bin/bash

set -e

echo "[0/7] 检测版本更新..."
LOCAL_VERSION=$("$VW_RUN_DIR/vaultwarden" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
GITHUB_VERSION=$(curl -s "https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest" | grep -oP '"tag_name": "\K[^"]+' | head -1)

if [ -n "$LOCAL_VERSION" ] && [ -n "$GITHUB_VERSION" ]; then
    echo "  当前版本: $LOCAL_VERSION | 最新版本: $GITHUB_VERSION"
    if [ "$LOCAL_VERSION" = "$GITHUB_VERSION" ]; then
        echo "  版本一致，无需更新。自动退出。"
        exit 0
    fi
    echo "  发现新版本，开始执行更新..."
else
    echo "  无法获取版本信息（本地或网络原因），将默认执行更新..."
fi

echo "[1/7] 准备临时目录..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

echo "[2/7] 从 Docker Hub 下载并解包最新镜像 (无需 Docker)..."

# ================= 内置解包逻辑开始 =================
PLATFORM="linux/amd64"
OUT_DIR="$TMP_DIR"
image_spec="vaultwarden/server:latest-alpine"
image="${image_spec%%:*}"
ref="${image_spec#*:}"
if [ "${ref}" = "${image_spec}" ]; then ref=latest; fi

OLD_IFS="${IFS}"; IFS=/ read -r OS ARCH VARIANT <<< "${PLATFORM}"; IFS="${OLD_IFS}"

extract() {
    local key="$1"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]\+\"" | sed -e 's/"$//' -e 's/.*"//'
}

fetch() {
    if command -v curl >/dev/null; then
        if [ $# -eq 2 ]; then set -- -H "$2" "$1"; elif [ $# -eq 3 ]; then set -- -H "$2" -H "$3" "$1"; fi
        curl -sSL "$@"
    else
        if [ $# -eq 2 ]; then set -- --header "$2" "$1"; elif [ $# -eq 3 ]; then set -- --header "$2" --header "$3" "$1"; fi
        wget -qO- "$@"
    fi
}

manifest_list_url="https://hub.docker.com/v2/repositories/${image}/tags/${ref}"
NL='
'
digest=$(fetch "${manifest_list_url}" | sed -e 's/\([][{}]\)/\'"${NL}"'\1\'"${NL}"'/g' | sed -n '/"images":/,/]/ p' | grep architecture | while read -r img; do
    arch="$(echo ${img} | extract 'architecture')"
    if [ "${arch}" != "${ARCH}" ]; then continue; fi
    os="$(echo ${img} | extract 'os')"
    if [ "${os}" != "${OS}" ]; then continue; fi
    variant="$(echo ${img} | extract 'variant')"
    if [ "${variant}" = "${VARIANT}" ]; then echo ${img} | extract 'digest'; break; fi
done)

if [ -z "${digest}" ]; then echo "No image digest found."; exit 1; fi

api_token_url="https://auth.docker.io/token?service=registry.docker.io&scope=repository:$image:pull"
manifest_url="https://registry-1.docker.io/v2/${image}/manifests/${digest}"
blobs_base_url="https://registry-1.docker.io/v2/${image}/blobs"

token=$(fetch "${api_token_url}" | extract 'token')
auth_header="Authorization: Bearer $token"
docker_manifest_v2="application/vnd.docker.distribution.manifest.v2+json"
oci_manifest_v1="application/vnd.oci.image.manifest.v1+json"
accept_header="Accept: ${docker_manifest_v2},${oci_manifest_v1}"

layers=$(fetch "${manifest_url}" "${auth_header}" "${accept_header}" | sed -n '/"layers":/,$ p' | extract 'digest')
if [ -z "${layers}" ]; then echo "No layers returned."; exit 1; fi

mkdir -p "${OUT_DIR}"
for layer in $layers; do
    hash="${layer#sha256:}"
    echo "  Fetching layer ${hash:0:8}..."
    fetch "${blobs_base_url}/${layer}" "${auth_header}" | gzip -d | tar -C "${OUT_DIR}" -xpf -
    OLD_IFS="${IFS}"
    find "${OUT_DIR}" -name '.wh.*' | while IFS= read -r f; do
        dir="${f%/*}"; wh_file="${f##*/}"; file="${wh_file#.wh.}"
        rm -rf "${dir}/${wh_file}" "${dir}/${file}"
    done
    IFS="${OLD_IFS}"
done

# ================= 内置解包逻辑结束 =================

echo "[3/7] 检查提取的文件..."
if [ ! -f "$TMP_DIR/vaultwarden" ]; then
    echo "错误：未提取到 vaultwarden 二进制文件！"
    exit 1
fi

echo "[4/7] 备份并替换现有文件..."
if [ ! -d "$VW_RUN_DIR" ]; then
    echo "错误：运行目录 $VW_RUN_DIR 不存在，请检查脚本配置。"
    exit 1
fi

# 先清理上一次的旧备份
rm -f "$VW_RUN_DIR"/vaultwarden.bak.*
rm -rf "$VW_RUN_DIR"/web-vault.bak.*

# 备份当前版本
if [ -f "$VW_RUN_DIR/vaultwarden" ]; then
    mv "$VW_RUN_DIR/vaultwarden" "$VW_RUN_DIR/vaultwarden.bak"
    echo "  已备份旧二进制 -> vaultwarden.bak"
fi
if [ -d "$VW_RUN_DIR/web-vault" ]; then
    mv "$VW_RUN_DIR/web-vault" "$VW_RUN_DIR/web-vault.bak"
    echo "  已备份旧 web-vault -> web-vault.bak"
fi

# 替换新文件
mv "$TMP_DIR/vaultwarden" "$VW_RUN_DIR/vaultwarden"
mv "$TMP_DIR/web-vault" "$VW_RUN_DIR/web-vault"
chmod +x "$VW_RUN_DIR/vaultwarden"

chown -R www:www "$VW_RUN_DIR/vaultwarden" "$VW_RUN_DIR/web-vault" 2>/dev/null || true

echo "[5/7] 重启 Supervisor 服务..."
if [ -x "$SUPERVISORCTL" ]; then
    "$SUPERVISORCTL" restart "$VW_SUPERVISOR_NAME"
    echo "  已执行重启：$VW_SUPERVISOR_NAME"
else
    echo "  警告：未找到 supervisorctl ($SUPERVISORCTL)，请手动重启 Vaultwarden。"
    exit 1
fi

echo "[6/7] 清理临时目录..."
# 因为不用 Docker 了，所以没镜像需要 prune，直接删临时目录即可
rm -rf "$TMP_DIR"

echo "[7/7] 完成！Vaultwarden 已通过无 Docker 模式更新并重启。"