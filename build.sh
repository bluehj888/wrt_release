#!/usr/bin/env bash

set -e

source /etc/profile
BASE_PATH=$(cd $(dirname $0) && pwd)

# 默认使用 IPK (opkg) 包管理
USE_APK=false

# ==== 新增-APK参数 ====
show_help() {
    echo "Usage: $0 [device_model] [options]"
    echo "Options:"
    echo "  -apk    使用 APK 包管理系统 (默认: IPK)"
    echo "  -h, --help 显示帮助信息"
    echo "环境变量:"
    echo "  USE_APK=true 启用 APK (云编译使用)"
    exit 0
}

# 检查帮助参数
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

# 解析命令行参数
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -apk)
            USE_APK=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# 恢复位置参数
set -- "${POSITIONAL_ARGS[@]}"

# 检查必需参数
if [ $# -lt 1 ]; then
    echo "错误：缺少设备型号参数"
    show_help
    exit 1
fi

# 环境变量覆盖（云编译使用）
if [ "$USE_APK" = "false" ]; then
    if [ -n "${USE_APK}" ]; then
        USE_APK=${USE_APK}
    fi
fi

# ==== 新增部分结束 ====
Dev=$1
Build_Mod=$2

CONFIG_FILE="$BASE_PATH/deconfig/$Dev.config"
INI_FILE="$BASE_PATH/compilecfg/$Dev.ini"

if [[ ! -f $CONFIG_FILE ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

if [[ ! -f $INI_FILE ]]; then
    echo "INI file not found: $INI_FILE"
    exit 1
fi

# ==== 包管理配置注入 ====
# 检查配置是否已存在
if ! grep -q "CONFIG_USE_APK" "$CONFIG_FILE"; then
    # 只有文件中没有配置时才添加
    if [ "$USE_APK" = "true" ]; then
        echo "CONFIG_USE_APK=y" >> "$CONFIG_FILE"
        echo "CONFIG_PACKAGE_luci-app-package-manager=y" >> "$CONFIG_FILE"
        echo "CONFIG_PACKAGE_luci-lib-ipkg=n" >> "$CONFIG_FILE"
        echo "使用 APK 包管理系统"
    else
        echo "CONFIG_USE_APK=n" >> "$CONFIG_FILE"
        echo "CONFIG_PACKAGE_luci-lib-ipkg=y" >> "$CONFIG_FILE"
        echo "使用 IPK (opkg) 包管理系统"
    fi
    
    # 显示应用的配置
    echo "应用的包管理配置:"
    grep -E "CONFIG_USE_APK|CONFIG_PACKAGE_luci-lib-ipkg" "$CONFIG_FILE"
else
    # 显示已有配置
    echo "包管理配置已存在:"
    grep -E "CONFIG_USE_APK|CONFIG_PACKAGE_luci-lib-ipkg" "$CONFIG_FILE"
fi
# ==== 包管理配置注入结束 ====

read_ini_by_key() {
    local key=$1
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$INI_FILE"
}

REPO_URL=$(read_ini_by_key "REPO_URL")
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
BUILD_DIR=$(read_ini_by_key "BUILD_DIR")
COMMIT_HASH=$(read_ini_by_key "COMMIT_HASH")
COMMIT_HASH=${COMMIT_HASH:-none}

if [[ -d $BASE_PATH/action_build ]]; then
    BUILD_DIR="action_build"
fi

# 在调用 update.sh 前设置环境变量
export USE_APK=$USE_APK
$BASE_PATH/update.sh "$REPO_URL" "$REPO_BRANCH" "$BASE_PATH/$BUILD_DIR" "$COMMIT_HASH"

\cp -f "$CONFIG_FILE" "$BASE_PATH/$BUILD_DIR/.config"

cd "$BASE_PATH/$BUILD_DIR"
make defconfig

if grep -qE "^CONFIG_TARGET_x86_64=y" "$CONFIG_FILE"; then
    DISTFEEDS_PATH="$BASE_PATH/$BUILD_DIR/package/emortal/default-settings/files/99-distfeeds.conf"
    if [ -d "${DISTFEEDS_PATH%/*}" ] && [ -f "$DISTFEEDS_PATH" ]; then
        sed -i 's/aarch64_cortex-a53/x86_64/g' "$DISTFEEDS_PATH"
    fi
fi

if [[ $Build_Mod == "debug" ]]; then
    exit 0
fi

TARGET_DIR="$BASE_PATH/$BUILD_DIR/bin/targets"
if [[ -d $TARGET_DIR ]]; then
    find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec rm -f {} +
fi

make download -j$(($(nproc) * 2))
make -j$(($(nproc) + 1)) || make -j1 V=s

FIRMWARE_DIR="$BASE_PATH/firmware"
\rm -rf "$FIRMWARE_DIR"
mkdir -p "$FIRMWARE_DIR"
find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
\rm -f "$BASE_PATH/firmware/Packages.manifest" 2>/dev/null

# 在 build.sh 中的重命名代码前添加调试信息

echo "=== 调试信息 ==="
echo "USE_APK 变量值: '$USE_APK'"
echo "USE_APK 类型: $(type -t USE_APK 2>/dev/null || echo '未定义')"
echo "环境变量 USE_APK: '${USE_APK:-未设置}'"
echo "================="

# 重命名固件文件
if [ "$USE_APK" = "true" ]; then
    pkg_suffix="apk"
    echo "条件判断: USE_APK=true, 使用 apk 后缀"
else
    pkg_suffix="ipk"
    echo "条件判断: USE_APK≠true, 使用 ipk 后缀"
fi

echo "最终选择的后缀: $pkg_suffix"

cd "$FIRMWARE_DIR" || exit 1
for file in *squashfs*; do
    if [ -f "$file" ]; then
        new_name="$(echo "$file" | sed "s/squashfs/${pkg_suffix}-squashfs/")"
        echo "重命名: $file -> $new_name"
        mv "$file" "$new_name"
    fi
done
cd - >/dev/null

echo "固件已添加 $pkg_suffix 标识"

if [[ -d $BASE_PATH/action_build ]]; then
    make clean
fi
