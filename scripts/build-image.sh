#!/usr/bin/env bash
set -euo pipefail

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.0}"
AMLOGIC_KERNEL="${AMLOGIC_KERNEL:-6.1.60}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-1024}"
DAEDE_RELEASE_TAG="${DAEDE_RELEASE_TAG:-latest}"
OUT_DIR="${OUT_DIR:-$PWD/out}"

# ====== 🛠️ 已切换为适合你的 armsr/armv8 通用 ARM64 架构 ======
TARGET="armsr/armv8"
PROFILE="default"
DAEDE_ARCH="aarch64_cortex-a53"
DAEDE_REPO="kenzok8/openwrt-daede"

# ====== 🛠️ 自动拼接官方 armsr/armv8 的 ImageBuilder 下载路径 ======
if [[ "$OPENWRT_VERSION" == *"SNAPSHOT"* ]]; then
  IMAGEBUILDER_URL="https://downloads.immortalwrt.org/snapshots/targets/armsr/armv8/immortalwrt-imagebuilder-armsr-armv8.Linux-x86_64.tar.zst"
else
  IMAGEBUILDER_URL="https://downloads.immortalwrt.org/releases/${OPENWRT_VERSION}/targets/armsr/armv8/immortalwrt-imagebuilder-${OPENWRT_VERSION}-armsr-armv8.Linux-x86_64.tar.zst"
fi

# 预装包（已剔除 25.12.0 APK 软件源中不存在的过时组件）
EXTRA_PACKAGES="luci luci-i18n-base-zh-cn luci-app-daede luci-app-amlogic kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag curl nano"

WORK_DIR="${WORK_DIR:-$PWD/work}"
IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

mkdir -p "$WORK_DIR" "$OUT_DIR"

resolve_daede_apk_url() {
  local release_api
  if [ "$DAEDE_RELEASE_TAG" = "latest" ]; then
    release_api="https://api.github.com/repos/$DAEDE_REPO/releases/latest"
  else
    release_api="https://api.github.com/repos/$DAEDE_REPO/releases/tags/$DAEDE_RELEASE_TAG"
  fi

  python3 - "$release_api" "$DAEDE_ARCH" <<'PY'
import json, os, sys, urllib.request
release_api, arch = sys.argv[1:3]
request = urllib.request.Request(release_api, headers={"Accept": "application/vnd.github+json", "User-Agent": "kenzok8-imagebuilder"})
token = os.environ.get("GITHUB_TOKEN")
if token: request.add_header("Authorization", f"Bearer {token}")
with urllib.request.urlopen(request, timeout=30) as response: release = json.load(response)

suffix = f"-{arch}.apk"
matches = [asset.get("browser_download_url") or asset.get("url") for asset in release.get("assets", []) if asset.get("name", "").startswith("luci-app-daede-") and asset.get("name", "").endswith(suffix)]
if not matches: raise SystemExit(f"luci-app-daede APK for {arch} not found")
print(matches[0])
PY
}

install_daede_apk() {
  local packages_dir="$WORK_DIR/imagebuilder/packages"
  local daede_url
  daede_url="$(resolve_daede_apk_url)"
  mkdir -p "$packages_dir"

  local fname="${daede_url##*/}"
  fname="${fname%-${DAEDE_ARCH}.apk}.apk"

  echo ">>>> 正在下载适合盒子的 daede 插件: $daede_url"
  curl -L --retry 8 --retry-delay 5 --connect-timeout 30 -o "$packages_dir/$fname" "$daede_url"
}

echo ">>>> 正在获取 ImageBuilder: $IMAGEBUILDER_URL"
if [ ! -s "$IB_ARCHIVE" ]; then
  curl -L -f --retry 8 --retry-delay 5 --connect-timeout 30 -o "$IB_ARCHIVE" "$IMAGEBUILDER_URL" || {
    echo "❌ 错误：下载失败，请确认该版本 ImageBuilder 存在！"
    exit 1
  }
fi

rm -rf "$WORK_DIR/imagebuilder"
mkdir -p "$WORK_DIR/imagebuilder"
tar --use-compress-program=unzstd -xf "$IB_ARCHIVE" -C "$WORK_DIR/imagebuilder" --strip-components=1

install_daede_apk

cd "$WORK_DIR/imagebuilder"

# 新版大雕环境鲁棒性改动
sed -i -e 's/# CONFIG_TARGET_ROOTFS_TARGZ is not set/CONFIG_TARGET_ROOTFS_TARGZ=y/' .config 2>/dev/null || true
echo "CONFIG_TARGET_ROOTFS_TARGZ=y" >> .config

echo ">>>> 开始编译基础 Rootfs 系统结构..."
if ! make image PROFILE="$PROFILE" PACKAGES="$EXTRA_PACKAGES" FILES=files BIN_DIR="$OUT_DIR" ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"; then
  echo "ImageBuilder 编译失败，请核对版本号。"; exit 1
fi

echo ">>>> 开始为 Tanix TX8 Max (S912) 进行专属固件封装..."
ROOTFS_FILE=$(find "$OUT_DIR" -name "*rootfs.tar.gz" | head -n 1)

AMLOGIC_DIR="$WORK_DIR/amlogic-s9xxx"
rm -rf "$AMLOGIC_DIR"
git clone --depth 1 https://github.com/ophub/amlogic-s9xxx-openwrt.git "$AMLOGIC_DIR"

mkdir -p "$AMLOGIC_DIR/openwrt"
# 完美对齐大雕工具箱默认接受的 generic 文件名命名规范
cp "$ROOTFS_FILE" "$AMLOGIC_DIR/openwrt/openwrt-armsr-armv8-generic-rootfs.tar.gz"

cd "$AMLOGIC_DIR"
# 执行针对你电视盒子的打包封装
sudo ./make -b "Tanix-TX8-MAX" -k "$AMLOGIC_KERNEL"

mkdir -p "$OUT_DIR"
cp -r output/* "$OUT_DIR/"

cd "$OUT_DIR"
find . -maxdepth 1 -type f ! -name "*.img" ! -name "*.img.gz" ! -name "*rootfs.tar.gz" -exec rm -f {} \;

for f in *.img *.img.gz *.tar.gz; do
  [ -f "$f" ] && sha256sum "$f"
done > sha256sums

BUILD_DATE="$(TZ='Asia/Shanghai' date '+%F %H:%M CST')"
cat > BUILD-MANIFEST.txt <<BODYEOF
## Tanix TX8 Max (S912) 专属定制固件

### 💾 下载说明
- **\`.img / .img.gz\`**：请直接使用 Rufus / BalenaEtcher 烧录进 U 盘引导。

### ⚙️ 编译信息
- **系统版本**：ImmortalWrt \`${OPENWRT_VERSION}\`
- **晶晨核心内核**：晶晨 \`${AMLOGIC_KERNEL}\` (完全整合 eBPF 支持)
- **设备专属 DTB**：\`meson-gxm-tx8-max.dtb\`
- **构建日期**：${BUILD_DATE}

### 📦 固件内置应用
\`${EXTRA_PACKAGES}\`
BODYEOF

ls -la "$OUT_DIR"