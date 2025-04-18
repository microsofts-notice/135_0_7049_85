#!/bin/bash

# 遇到错误时立即退出
set -e
# 如果管道中的任何命令失败，则退出
set -o pipefail

# --- 配置 ---
# V8 源码和构建的目标目录 (可以根据需要修改)
V8_BUILD_DIR="$HOME/v8_build_sandbox" # 建议为启用沙箱的构建使用不同的目录
# depot_tools 的安装目录
DEPOT_TOOLS_DIR="$V8_BUILD_DIR/depot_tools"
# 构建类型: "Release" 或 "Debug"
BUILD_TYPE="Release"
# 目标 CPU 架构: "x64" (适用于大多数桌面 Ubuntu), "arm64" (适用于 ARM 架构的 Ubuntu)
TARGET_CPU="x64"
# 使用的核心数进行编译 (默认使用所有核心)
BUILD_JOBS=$(nproc)

# --- 脚本开始 ---

echo "### V8 d8 自动编译脚本 (启用 Sandbox) ###"
echo "目标目录: $V8_BUILD_DIR"
echo "构建类型: $BUILD_TYPE"
echo "目标架构: $TARGET_CPU"
echo "编译核心数: $BUILD_JOBS"
echo "启用 Sandbox: Yes"
echo "启用 Sandbox Testing: Yes"
echo "---------------------------------"

# 1. 检查/安装系统依赖 (提示用户)
echo ">>> 步骤 1: 检查系统依赖..."
echo "    请确保已安装 Git, Python3, Clang, 和 C++ 编译工具链。"
echo "    在 Ubuntu/Debian 上，如果缺少，可以尝试运行:"
echo "    sudo apt update && sudo apt install git python3 python3-pip build-essential clang"
# 这里不直接执行 sudo，让用户确认并手动执行
read -p "    按 Enter 继续，或按 Ctrl+C 退出并安装依赖..."

# 2. 创建目标目录
echo ">>> 步骤 2: 创建目标目录 $V8_BUILD_DIR..."
mkdir -p "$V8_BUILD_DIR"
# 使用 pushd/popd 管理目录切换更安全
pushd "$V8_BUILD_DIR" > /dev/null

# 3. 获取/更新 depot_tools
echo ">>> 步骤 3: 获取/更新 depot_tools..."
if [ ! -d "$DEPOT_TOOLS_DIR" ]; then
  echo "    正在克隆 depot_tools 到 $DEPOT_TOOLS_DIR..."
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
else
  echo "    depot_tools 已存在，尝试更新..."
  # 使用 -C 指定目录，避免不必要的 cd
  git -C "$DEPOT_TOOLS_DIR" pull origin main
fi

# 将 depot_tools 添加到当前 Shell 的 PATH (更稳健的方式)
export PATH="$DEPOT_TOOLS_DIR:$PATH"
echo "    depot_tools 已添加到 PATH (仅限本次执行)"

# 验证 depot_tools 是否可用 (例如检查 gclient 是否存在)
if ! command -v gclient &> /dev/null; then
    echo "错误：无法找到 depot_tools 中的 gclient 命令。" >&2
    echo "请检查 depot_tools 是否正确安装在 '$DEPOT_TOOLS_DIR' 并且已添加到 PATH。" >&2
    popd > /dev/null # 退出 V8_BUILD_DIR
    exit 1
fi

# 4. 获取 V8 源码
echo ">>> 步骤 4: 获取 V8 源码..."
V8_SRC_DIR="$V8_BUILD_DIR/v8" # 定义 V8 源码路径变量
if [ ! -d "$V8_SRC_DIR" ]; then
  echo "    使用 'fetch v8' 下载 V8 源码及其依赖 (这可能需要很长时间)..."
  fetch v8
  # fetch v8 之后，当前目录应该就是 v8
  if [ ! -d "$V8_SRC_DIR" ]; then # Double check fetch created the directory as expected
      echo "错误：'fetch v8' 命令后未找到 v8 目录 '$V8_SRC_DIR'" >&2
      popd > /dev/null # 退出 V8_BUILD_DIR
      exit 1
  fi
  pushd "$V8_SRC_DIR" > /dev/null # 进入 v8 目录
  echo "    运行 'gclient sync' 确保所有依赖都已同步..."
  gclient sync
else
  echo "    V8 目录已存在，进入目录并尝试更新..."
  pushd "$V8_SRC_DIR" > /dev/null # 进入 v8 目录
  echo "    运行 'git pull origin main' 更新 V8 主分支..."
  # 检查是否有本地修改，避免 pull 失败
  if git status --porcelain | grep .; then
      echo "警告：V8 目录中有未提交的更改，跳过 git pull。请手动处理。" >&2
  else
      # 尝试更新，如果失败则提示
      if ! git pull origin main; then
          echo "警告: 'git pull origin main' 失败。可能是本地分支冲突或网络问题。" >&2
          echo "      将继续尝试 gclient sync，但源码可能不是最新的。" >&2
      fi
  fi
  echo "    运行 'gclient sync' 更新依赖..."
  gclient sync
fi
# 确保当前目录是 v8 (pushd 成功时会自动进入)

# --- 添加的步骤：安装 sysroot ---
# 4.5. 安装构建所需的 sysroot (V8/Chromium build requirement on Linux)
echo ">>> 步骤 4.5: 安装/更新构建所需的 sysroot..."
# Map TARGET_CPU to sysroot architecture name used by the script
SYSROOT_ARCH=""
if [ "$TARGET_CPU" == "x64" ]; then
    SYSROOT_ARCH="amd64"
elif [ "$TARGET_CPU" == "arm64" ]; then
    SYSROOT_ARCH="arm64"
# Add other architectures if needed (e.g., arm)
# elif [ "$TARGET_CPU" == "arm" ]; then
#     SYSROOT_ARCH="arm"
else
    echo "错误：未知的 TARGET_CPU '$TARGET_CPU'，无法确定 sysroot 架构。" >&2
    # popd back out before exiting
    popd > /dev/null # Exit v8 dir
    popd > /dev/null # Exit V8_BUILD_DIR
    exit 1
fi

echo "    正在为架构 $SYSROOT_ARCH 安装/更新 sysroot (如果需要，会自动下载)..."
# Run the sysroot installation script from within the v8 directory
# Using python3 explicitly is safer
python3 build/linux/sysroot_scripts/install-sysroot.py --arch="$SYSROOT_ARCH"
# --- sysroot 安装结束 ---


# 5. 配置构建 (使用 GN)
echo ">>> 步骤 5: 配置构建 (使用 GN)..."
# 根据构建类型设置 is_debug 和 symbol_level
# 推荐使用 Clang
GN_ARGS="is_clang=true"

if [ "$BUILD_TYPE" == "Debug" ]; then
  GN_ARGS="$GN_ARGS is_debug=true symbol_level=2" # 调试构建，启用调试符号
  BUILD_OUTPUT_DIR="out.gn/$TARGET_CPU.debug.sandbox" # 目录名更清晰
else
  GN_ARGS="$GN_ARGS is_debug=false symbol_level=0" # 发布构建，移除符号以减小体积
  BUILD_OUTPUT_DIR="out.gn/$TARGET_CPU.release.sandbox" # 目录名更清晰
fi

# 添加其他常用参数
# is_component_build=false: 构建静态库，生成单个 d8 可执行文件
# target_cpu: 指定目标 CPU 架构
GN_ARGS="$GN_ARGS is_component_build=false target_cpu=\"$TARGET_CPU\""

# *** 添加 Sandbox 相关参数 ***
GN_ARGS="$GN_ARGS v8_enable_sandbox=true v8_enable_sandbox_testing=true"

echo "    构建输出目录: $BUILD_OUTPUT_DIR"
echo "    GN 参数: $GN_ARGS"
# 运行 gn gen
gn gen "$BUILD_OUTPUT_DIR" --args="$GN_ARGS"

# 6. 执行编译 (使用 Ninja)
echo ">>> 步骤 6: 执行编译 (使用 Ninja)..."
echo "    正在编译目标 'd8' (使用 $BUILD_JOBS 个核心)..."
ninja -C "$BUILD_OUTPUT_DIR" d8 -j"$BUILD_JOBS"

# 7. 完成
echo "---------------------------------"
echo ">>> 编译完成！"
# V8_SRC_DIR 变量已在步骤 4 定义
D8_PATH="$V8_SRC_DIR/$BUILD_OUTPUT_DIR/d8"
echo "    d8 可执行文件位于: $D8_PATH"
echo ""
echo "    你可以通过以下命令运行 d8:"
echo "    cd $V8_SRC_DIR"
echo "    ./$BUILD_OUTPUT_DIR/d8"
echo ""
echo "    例如，执行一个简单的 JS 文件:"
echo "    echo 'print(\"Hello from sandboxed d8!\");' > hello.js"
echo "    ./$BUILD_OUTPUT_DIR/d8 hello.js"
echo "---------------------------------"

# 返回到初始目录
popd > /dev/null # 退出 v8 目录
popd > /dev/null # 退出 V8_BUILD_DIR

exit 0
