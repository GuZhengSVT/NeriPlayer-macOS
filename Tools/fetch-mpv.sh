#!/usr/bin/env bash
# fetch-mpv.sh —— Vendor 化 libmpv（移植规划 M1-T1）。
#
# 用途：把 libmpv 的头文件与动态库从 Homebrew 布置到 Vendor/mpv/，供后续
#       MPVController 桥接层与命令行验证使用。
#
# 产物布局（简化布局 + pkg-config，产物不入库，见 .gitignore 的 /Vendor/mpv/）：
#   Vendor/mpv/include/mpv/*.h           # libmpv 公共头文件（client.h / render.h / ...）
#   Vendor/mpv/lib/libmpv*.dylib         # 动态库（含版本化软链）
#   Vendor/mpv/lib/pkgconfig/mpv.pc      # pkg-config 描述文件（含 rpath）
#   Vendor/mpv/VENDORED.txt              # 来源与已知限制记录
#
# 行为：
#   - 已存在可用产物时直接跳过（幂等）；--force 强制重新布置。
#   - 未安装 Homebrew / brew 安装失败时打印明确错误与手动步骤，退出码非 0。
#   - 会把 libmpv 的 install_name 改写为 @rpath/libmpv.<N>.dylib 并做 ad-hoc 重签名，
#     使 -L Vendor/mpv/lib -lmpv 真正链接到 Vendor 内的副本（而非 Homebrew 原件）。
#
# 已知限制：libmpv 的间接依赖（ffmpeg/libass/libplacebo 等）仍指向 Homebrew 绝对路径，
#           即本脚本只做到「libmpv 本体 vendor 化」。完整依赖闭包 vendor 化留待后续任务。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/Vendor/mpv"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# {0,1}//'
      exit 0
      ;;
    *)
      printf '未知参数：%s（可用：--force）\n' "$arg" >&2
      exit 2
      ;;
  esac
done

log() { printf '[fetch-mpv] %s\n' "$*"; }
err() { printf '[fetch-mpv] 错误：%s\n' "$*" >&2; }

manual_steps() {
  cat >&2 <<'MANUAL'
[fetch-mpv] 手动步骤（Homebrew 不可用时）：
  1) 安装 Homebrew：https://brew.sh
  2) brew install mpv
  3) 记下 keg 路径：P="$(brew --prefix mpv)"
  4) 手动布置：
       mkdir -p Vendor/mpv/include Vendor/mpv/lib
       cp -R "$P/include/mpv" Vendor/mpv/include/
       cp -R "$P/lib/"libmpv*.dylib Vendor/mpv/lib/
  5) 重新执行本脚本：Tools/fetch-mpv.sh
  备选（自行编译 libmpv）：
       git clone https://github.com/mpv-player/mpv
       cd mpv && meson setup build -Dlibmpv=true -Dbuildtype=release && meson compile -C build
       之后把 build/include/mpv 与 build/libmpv*.dylib 按上面的布局放入 Vendor/mpv/
MANUAL
}

# ---------- 1. 幂等检测 ----------
existing_dylib="$VENDOR_DIR/lib/libmpv.dylib"
existing_id="$(otool -D "$existing_dylib" 2>/dev/null | tail -n 1 || true)"
if [[ "$FORCE" -eq 0 && -f "$existing_dylib" && -f "$VENDOR_DIR/include/mpv/client.h"
      && "$existing_id" == @rpath/libmpv*.dylib ]] && codesign --verify "$existing_dylib" 2>/dev/null; then
  log "检测到已有产物，跳过（--force 可强制刷新）："
  log "  dylib : $existing_dylib"
  log "  header: $VENDOR_DIR/include/mpv/client.h"
  exit 0
fi

# ---------- 2. 定位 Homebrew mpv ----------
if ! command -v brew >/dev/null 2>&1; then
  err "未找到 Homebrew（brew 不在 PATH 中）。"
  manual_steps
  exit 1
fi

mpv_prefix="$(brew --prefix mpv 2>/dev/null || true)"
if [[ -z "$mpv_prefix" || ! -d "$mpv_prefix" ]]; then
  log "Homebrew 中未安装 mpv，执行 brew install mpv ..."
  if ! brew install mpv; then
    err "brew install mpv 失败。"
    manual_steps
    exit 1
  fi
  mpv_prefix="$(brew --prefix mpv 2>/dev/null || true)"
fi

if [[ -z "$mpv_prefix" || ! -d "$mpv_prefix" ]]; then
  err "无法确定 mpv 的 Homebrew keg 路径。"
  manual_steps
  exit 1
fi

src_include="$mpv_prefix/include/mpv"
src_libdir="$mpv_prefix/lib"

if [[ ! -f "$src_include/client.h" ]]; then
  err "未在 $src_include 找到 client.h；当前 mpv 安装可能未带 libmpv 头文件。"
  manual_steps
  exit 1
fi

# 取最小的 libmpv 动态库（跳过 dev 软链 libmpv.dylib 之外的目录项）
shopt -s nullglob
src_dylibs=("$src_libdir"/libmpv*.dylib)
shopt -u nullglob
if [[ "${#src_dylibs[@]}" -eq 0 ]]; then
  err "未在 $src_libdir 找到 libmpv*.dylib。"
  manual_steps
  exit 1
fi

mpv_version="$(brew list --versions mpv 2>/dev/null | awk '{print $2}' | head -n 1)"
mpv_version="${mpv_version:-未知}"

log "来源 keg : $mpv_prefix"
log "brew 版本: mpv $mpv_version"
log "架构     : $(uname -m)"

# ---------- 3. 布置产物 ----------
# Reject redirected trees before replacing any artifacts.
for target in "$ROOT_DIR/Vendor" "$VENDOR_DIR" "$VENDOR_DIR/include" "$VENDOR_DIR/lib"; do
  if [[ -L "$target" ]]; then err "拒绝修改符号链接目录：$target"; exit 1; fi
done
mkdir -p "$VENDOR_DIR/include" "$VENDOR_DIR/lib"
resolved_vendor="$(cd "$VENDOR_DIR" && pwd -P)"
expected_vendor="$(cd "$ROOT_DIR" && pwd -P)/Vendor/mpv"
[[ "$resolved_vendor" == "$expected_vendor" ]] || { err "Vendor 路径不在项目内"; exit 1; }

rm -rf "$VENDOR_DIR/include/mpv"
cp -R "$src_include" "$VENDOR_DIR/include/"
log "已布置头文件 -> Vendor/mpv/include/mpv（$(ls "$VENDOR_DIR/include/mpv" | wc -l | tr -d ' ') 个文件）"

rm -f "$VENDOR_DIR/lib/libmpv"*.dylib
cp -R "${src_dylibs[@]}" "$VENDOR_DIR/lib/"

# Fail closed: copied but unrelocated/unsigned libraries are not usable artifacts.
dylib_id=""
for f in "$VENDOR_DIR"/lib/libmpv*.dylib; do
  [[ -L "$f" ]] && continue
  [[ -f "$f" ]] || continue
  base="$(basename "$f")"
  install_name_tool -id "@rpath/$base" "$f"
  codesign --force --sign - "$f"
  codesign --verify "$f"
done
if [[ ! -f "$VENDOR_DIR/lib/libmpv.dylib" ]]; then
  err "缺少 libmpv.dylib 链接入口"; exit 1
fi
dylib_id="$(otool -D "$VENDOR_DIR/lib/libmpv.dylib" | tail -n 1)"
[[ "$dylib_id" == @rpath/libmpv*.dylib ]] || { err "install_name 校验失败"; exit 1; }

log "已布置动态库 -> Vendor/mpv/lib（$(ls "$VENDOR_DIR"/lib/libmpv*.dylib | wc -l | tr -d ' ') 个条目）"

# ---------- 4. pkg-config ----------
# Version 取 libmpv 客户端 API 版本（keg 自带 mpv.pc 的 Version），取不到则退回 brew 包版本。
api_version="$(awk -F': *' '/^Version:/{print $2; exit}' "$src_libdir/pkgconfig/mpv.pc" 2>/dev/null || true)"
api_version="${api_version:-$mpv_version}"

mkdir -p "$VENDOR_DIR/lib/pkgconfig"
{
  printf 'prefix=%s\n' "$VENDOR_DIR"
  cat <<'PC'
exec_prefix=${prefix}
libdir=${prefix}/lib
includedir=${prefix}/include

Name: mpv
Description: mpv media player client library (vendored by Tools/fetch-mpv.sh)
PC
  printf 'Version: %s\n' "$api_version"
  cat <<'PC'
Libs: -L${libdir} -lmpv -Wl,-rpath,${libdir}
Cflags: -I${includedir}
PC
} > "$VENDOR_DIR/lib/pkgconfig/mpv.pc"
log "已生成 pkg-config -> Vendor/mpv/lib/pkgconfig/mpv.pc（API 版本 ${api_version}）"

# ---------- 5. 来源记录 ----------
{
  printf 'libmpv vendored by Tools/fetch-mpv.sh\n'
  printf 'generated_at : %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'host_arch    : %s\n' "$(uname -m)"
  printf 'brew_keg     : %s\n' "$mpv_prefix"
  printf 'brew_version : mpv %s\n' "$mpv_version"
  printf 'api_version  : %s\n' "$api_version"
  printf 'dylib_id     : %s\n' "${dylib_id:-未改写}"
  printf '\n'
  printf 'lib/\n'
  ls -l "$VENDOR_DIR/lib" | sed 's/^/  /'
  printf '\n已知限制：libmpv 的间接依赖（ffmpeg/libass/libplacebo 等）仍指向 Homebrew\n'
  printf '绝对路径，故本机需保留 brew 安装的 mpv 依赖。完整依赖闭包 vendor 化未做。\n'
} > "$VENDOR_DIR/VENDORED.txt"
log "已写入来源记录 -> Vendor/mpv/VENDORED.txt"

log "完成。用法示例："
log "  clang -I Vendor/mpv/include -L Vendor/mpv/lib -lmpv -Wl,-rpath,Vendor/mpv/lib demo.c -o demo"
log "  或 export PKG_CONFIG_PATH=$PWD/Vendor/mpv/lib/pkgconfig && pkg-config --cflags --libs mpv"
