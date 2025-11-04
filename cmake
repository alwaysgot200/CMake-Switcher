#!/usr/bin/env bash

export CMAKE_WRAPPER_VERBOSE="${CMAKE_WRAPPER_VERBOSE:-1}"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
VERBOSE="${CMAKE_WRAPPER_VERBOSE:-}"

# Send logs to stderr so command substitutions only capture function outputs
log() { [[ -n "$VERBOSE" ]] && echo "[cmake-wrapper] $*" >&2; }
first_existing() { for p in "$@"; do [[ -n "$p" && -f "$p" ]] && { echo "$p"; return 0; }; done; return 1; }

stage() { log "\n==== 阶段: $1 ===="; }

#---------------------------------------------------------------
# OS / Arch detection
#---------------------------------------------------------------
detect_os() {
  local u
  u="$(uname -s 2>/dev/null || echo unknown)"
  case "$u" in
    Linux) echo linux;;
    Darwin) echo macos;;
    MINGW*|MSYS*|CYGWIN*) echo windows;;
    *) echo linux;;
  esac
}

detect_arch() {
  local m
  m="$(uname -m 2>/dev/null || echo x86_64)"
  case "$m" in
    x86_64|amd64) echo x86_64;;
    aarch64|arm64) echo arm64;;
    *) echo x86_64;;
  esac
}

OS="$(detect_os)"; ARCH="$(detect_arch)"

#---------------------------------------------------------------
# Configurable naming & base URL
#   You can override via env:
#   - CMAKE_DOWNLOAD_BASE (default: https://cmake.org/files)
#   - CMAKE_DIR_PREFIX    (default: cmake)
#---------------------------------------------------------------
DOWNLOAD_BASE="${CMAKE_DOWNLOAD_BASE:-https://cmake.org/files}"
DIR_PREFIX="${CMAKE_DIR_PREFIX:-cmake}"

#---------------------------------------------------------------
# URL mapping
#   Supported versions: 3.5.2, 3.31.2, 4.1.2
#---------------------------------------------------------------
platform_suffix_and_ext() {
  local ver os arch major minor
  ver="$1"; os="$2"; arch="$3"
  major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"

  if [[ "$major.$minor" == "3.5" ]]; then
    case "$os" in
      macos) echo "Darwin-x86_64 tar.gz";;
      linux) echo "Linux-x86_64 tar.gz";;
      windows) echo "win32-x86 zip";;
    esac
  else
    case "$os" in
      macos) echo "macos-universal tar.gz";;
      linux)
        if [[ "$arch" == "arm64" ]]; then echo "linux-aarch64 tar.gz"; else echo "linux-x86_64 tar.gz"; fi;;
      windows)
        # Prefer x86_64; can extend to arm64 later
        echo "windows-x86_64 zip";;
    esac
  fi
}

build_url() {
  local ver os arch suf ext major minor dir
  ver="$1"; os="$2"; arch="$3"
  read -r suf ext <<<"$(platform_suffix_and_ext "$ver" "$os" "$arch")"
  major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"
  dir="v${major}.${minor}"
  echo "${DOWNLOAD_BASE}/${dir}/${DIR_PREFIX}-$ver-${suf}.${ext}"
}

# Local archive filename (to store under SCRIPT_DIR)
archive_filename() {
  local ver os arch suf ext
  ver="$1"; os="$2"; arch="$3"
  read -r suf ext <<<"$(platform_suffix_and_ext "$ver" "$os" "$arch")"
  echo "${DIR_PREFIX}-$ver-${suf}.${ext}"
}

#---------------------------------------------------------------
# Download & Extract
#   Extract to ${SCRIPT_DIR}/cmake-<version>
#---------------------------------------------------------------
ensure_tools() {
  command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
  command -v tar >/dev/null || { echo "tar is required" >&2; exit 1; }
  command -v unzip >/dev/null || true
}

extract_archive() {
  local archive dest_root ext
  archive="$1"; dest_root="$2"; ext="$3"
  rm -rf "$dest_root.tmp"
  mkdir -p "$dest_root.tmp"
  if [[ "$ext" == "tar.gz" ]]; then
    tar -xzf "$archive" -C "$dest_root.tmp"
  elif [[ "$ext" == "zip" ]]; then
    if command -v unzip >/dev/null; then unzip -q "$archive" -d "$dest_root.tmp"; else
      echo "unzip not available" >&2; exit 1; fi
  else
    echo "Unknown archive type: $ext" >&2; exit 1
  fi

  # Move extracted folder into dest_root, preserving official folder name
  local extracted base final
  extracted="$(find "$dest_root.tmp" -maxdepth 1 -mindepth 1 -type d | head -n1 || true)"
  if [[ -z "$extracted" ]]; then echo "Extraction failed" >&2; rm -rf "$dest_root.tmp"; exit 1; fi
  base="$(basename "$extracted")"
  final="$dest_root/$base"
  rm -rf "$final"
  mv "$extracted" "$final"
  rm -rf "$dest_root.tmp"
  echo "$final"
}

# Normalize pre-existing extracted folder names to cmake-<version>
normalize_existing_layout() {
  # Intentionally no-op to preserve official extracted directory names
  return 0
}

# Locate official extracted directory for a specific version without renaming
locate_version_root() {
  local ver root cand
  ver="$1"; root=""
  # Sidecar pointer file
  local pointer="$SCRIPT_DIR/${DIR_PREFIX}-$ver.path"
  if [[ -f "$pointer" ]]; then
    root="$(cat "$pointer" 2>/dev/null || true)"
    if [[ -n "$root" && -d "$root" ]]; then echo "$root"; return 0; fi
  fi
  # Search for official folders matching pattern
  cand="$(find "$SCRIPT_DIR" -maxdepth 1 -type d -name "${DIR_PREFIX}-${ver}*" | head -n1 || true)"
  if [[ -n "$cand" ]]; then echo "$cand"; return 0; fi
  return 1
}

# Locate cmake binary inside extracted official package without altering layout
locate_binary() {
  local dest os
  dest="$1"; os="${2:-$OS}"
  # Candidate paths across platforms
  local candidates=(
    "$dest/bin/cmake"
    "$dest/CMake.app/Contents/bin/cmake"
    "$dest/bin/cmake.exe"
    "$dest/cmake.exe"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then echo "$c"; return 0; fi
  done
  return 1
}

# Ensure version exists locally; if not, download and normalize
ensure_version_ready() {
  local ver root url suf ext archive bin
  ver="$1"
  # Try to locate pre-existing official directory
  root="$(locate_version_root "$ver" || true)"
  if [[ -n "$root" ]]; then
    bin="$(locate_binary "$root" "$OS" || true)"
    if [[ -n "$bin" ]]; then
      log "版本 $ver 已存在: $bin"
      echo "$bin"
      return 0
    fi
  fi
  if [[ -n "$bin" ]]; then
    log "版本 $ver 已存在: $bin"
    echo "$bin"
    return 0
  fi

  ensure_tools
  read -r suf ext <<<"$(platform_suffix_and_ext "$ver" "$OS" "$ARCH")"
  url="$(build_url "$ver" "$OS" "$ARCH")"
  archive="$SCRIPT_DIR/$(archive_filename "$ver" "$OS" "$ARCH")"
  stage "下载 ($ver)"
  log "URL: $url"
  if ! curl -fL --retry 3 --retry-delay 1 -o "$archive" "$url"; then
    echo "Download failed: $url" >&2; rm -f "$archive"; exit 1
  fi
  stage "解压 ($ver)"
  log "归档: $archive -> 目录: $SCRIPT_DIR"
  root="$(extract_archive "$archive" "$SCRIPT_DIR" "$ext" || true)"
  # Record pointer file for later fast lookup
  if [[ -n "$root" ]]; then echo "$root" > "$SCRIPT_DIR/${DIR_PREFIX}-$ver.path"; fi
  bin="$(locate_binary "$root" "$OS" || true)"
  if [[ -n "$bin" ]]; then echo "$bin"; return 0; fi
  echo "CMake binary not found in $dest" >&2; exit 1
}

# Check if version exists without triggering download
version_binary_if_exists() {
  local ver root bin
  ver="$1"
  local legacy1="$SCRIPT_DIR/$ver"; local legacy2="$SCRIPT_DIR/$ver/bin/cmake"
  if [[ -d "$legacy1" && -f "$legacy2" ]]; then echo "$legacy2"; return 0; fi
  root="$(locate_version_root "$ver" || true)"
  bin="$(locate_binary "$root" "$OS" || true)"
  if [[ -n "$bin" ]]; then echo "$bin"; return 0; fi
  return 1
}

# If none of the three versions exist locally, pre-download all
prefetch_all_if_none() {
  local ver found=false
  for ver in $CMAKE_VERSIONS; do
    if version_binary_if_exists "$ver" >/dev/null 2>&1; then found=true; break; fi
  done
  if ! $found; then
    stage "检测完整性"
    log "本地未发现任何版本，开始预取: $CMAKE_VERSIONS"
    for ver in $CMAKE_VERSIONS; do
      ensure_version_ready "$ver" >/dev/null || true
    done
  fi
}

# If any of the three versions is missing, fetch the missing ones
prefetch_missing_versions() {
  stage "检测完整性"
  local ver
  for ver in $CMAKE_VERSIONS; do
    if ! version_binary_if_exists "$ver" >/dev/null 2>&1; then
      log "版本 $ver 缺失，开始获取..."
      ensure_version_ready "$ver" >/dev/null || true
      log "版本 $ver 已就绪"
    else
      log "版本 $ver 已存在"
    fi
  done
}

#---------------------------------------------------------------
# Resolve versions / selection
#---------------------------------------------------------------
VERSION_3_5="3.5.2"; VERSION_3_31="3.31.2"; VERSION_4_1="4.1.2"
 
# Space-separated版本列表；可通过环境变量覆盖
# 示例： export CMAKE_VERSIONS="3.5.2 3.31.2 4.1.2"
CMAKE_VERSIONS="${CMAKE_VERSIONS:-$VERSION_3_5 $VERSION_3_31 $VERSION_4_1}"

# Allow overrides via env
CMAKE_3_5="${CMAKE3_5_PATH:-}"
CMAKE_3_31="${CMAKE3_31_PATH:-}"
CMAKE_4_1="${CMAKE4_1_PATH:-}"

# Special modes: -E/-P/--help/--version use latest immediately
for a in "$@"; do
  case "$a" in -E|-P|--help|-help|--version|-version)
    prefetch_missing_versions
    if [[ -z "$CMAKE_4_1" ]]; then CMAKE_4_1="$(ensure_version_ready "$VERSION_4_1")"; fi
    exec "$CMAKE_4_1" "$@";;
  esac
done

# No args -> use latest
if [[ $# -eq 0 ]]; then
  stage "选择并运行"
  log "无参数，使用最新版本 -> $VERSION_4_1"
  prefetch_missing_versions
  if [[ -z "$CMAKE_4_1" ]]; then CMAKE_4_1="$(ensure_version_ready "$VERSION_4_1")"; fi
  exec "$CMAKE_4_1" "$@"
fi

# Source dir detection
SRC_DIR=""
args=( "$@" )
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "-S" && $((i+1)) -lt ${#args[@]} ]]; then SRC_DIR="${args[$((i+1))]}"; break; fi
done
if [[ -z "$SRC_DIR" ]]; then
  for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "-H" && $((i+1)) -lt ${#args[@]} ]]; then SRC_DIR="${args[$((i+1))]}"; break; fi
  done
fi
if [[ -z "$SRC_DIR" ]]; then
  for a in "${args[@]}"; do
    if [[ -n "$a" && "${a:0:1}" != "-" && -d "$a" && -f "$a/CMakeLists.txt" ]]; then SRC_DIR="$a"; break; fi
  done
fi
[[ -z "$SRC_DIR" && -f "./CMakeLists.txt" ]] && SRC_DIR="."

CHOSEN=""
if [[ -n "$SRC_DIR" && -f "$SRC_DIR/CMakeLists.txt" ]]; then
  prefetch_missing_versions
  MIN="$(grep -ioE 'cmake_minimum_required[[:space:]]*\([[:space:]]*VERSION[[:space:]]+[0-9]+(\.[0-9]+)?' "$SRC_DIR/CMakeLists.txt" \
          | sed -E 's/.*VERSION[[:space:]]*//' | head -n1 || true)"
  if [[ -z "$MIN" ]]; then
    MIN="$(grep -ioE 'cmake_policy[[:space:]]*\([[:space:]]*VERSION[[:space:]]+[0-9]+(\.[0-9]+)?' "$SRC_DIR/CMakeLists.txt" \
            | sed -E 's/.*VERSION[[:space:]]*//' | head -n1 || true)"
  fi
  if [[ -n "$MIN" ]]; then
    stage "选择并运行"
    MAJOR="${MIN%%.*}"; REST="${MIN#*.}"; [[ "$REST" == "$MIN" ]] && MINOR=0 || MINOR="${REST%%.*}"
    if (( MAJOR < 3 || (MAJOR == 3 && MINOR < 5) )); then
      [[ -z "$CMAKE_3_5" ]] && CMAKE_3_5="$(ensure_version_ready "$VERSION_3_5")"
      CHOSEN="$CMAKE_3_5"; log "检测到最低版本 ${MAJOR}.${MINOR} (<3.5) -> 选择 $VERSION_3_5"
    elif (( MAJOR < 4 )); then
      [[ -z "$CMAKE_3_31" ]] && CMAKE_3_31="$(ensure_version_ready "$VERSION_3_31")"
      CHOSEN="$CMAKE_3_31"; log "检测到最低版本 ${MAJOR}.${MINOR} (>=3.5 且 <4.0) -> 选择 $VERSION_3_31"
    else
      [[ -z "$CMAKE_4_1" ]] && CMAKE_4_1="$(ensure_version_ready "$VERSION_4_1")"
      CHOSEN="$CMAKE_4_1"; log "检测到最低版本 ${MAJOR}.${MINOR} (>=4.0) -> 选择 $VERSION_4_1"
    fi
  else
    stage "选择并运行"
    [[ -z "$CMAKE_4_1" ]] && CMAKE_4_1="$(ensure_version_ready "$VERSION_4_1")"
    CHOSEN="$CMAKE_4_1"; log "未找到最低版本要求，使用默认 -> $VERSION_4_1"
  fi
else
  stage "选择并运行"
  [[ -z "$CMAKE_4_1" ]] && CMAKE_4_1="$(ensure_version_ready "$VERSION_4_1")"
  CHOSEN="$CMAKE_4_1"; log "未找到源目录，使用默认 -> $VERSION_4_1"
fi

if [[ -z "$CHOSEN" || ! -f "$CHOSEN" ]]; then
  echo "Selected CMake not found: $CHOSEN" >&2
  echo "If auto-download failed, set CMAKE3_5_PATH / CMAKE3_31_PATH / CMAKE4_1_PATH or place cmake-<ver> under $SCRIPT_DIR." >&2
  exit 1
fi

exec "$CHOSEN" "$@"