#!/usr/bin/env bash

export CMAKE_WRAPPER_VERBOSE="${CMAKE_WRAPPER_VERBOSE:-1}"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
VERBOSE="${CMAKE_WRAPPER_VERBOSE:-}"

log() { [[ -n "$VERBOSE" ]] && echo "[cmake-wrapper] $*"; }
first_existing() { for p in "$@"; do [[ -n "$p" && -f "$p" ]] && { echo "$p"; return 0; }; done; return 1; }

# 三个版本的默认位置
CMAKE_3_5="${CMAKE3_5_PATH:-}"
if [[ -z "$CMAKE_3_5" ]]; then
  CMAKE_3_5="$(first_existing \
    "$SCRIPT_DIR/cmake-3.5.2/bin/cmake.exe" \
    "$SCRIPT_DIR/cmake-3.5.2.exe" \
  )" || true
fi

CMAKE_3_31="${CMAKE3_31_PATH:-}"
if [[ -z "$CMAKE_3_31" ]]; then
  CMAKE_3_31="$(first_existing \
    "$SCRIPT_DIR/cmake-3.31.8/bin/cmake.exe" \
    "$SCRIPT_DIR/cmake3.exe" \
    "$SCRIPT_DIR/cmake.exe" \
  )" || true
fi

CMAKE_4_1="${CMAKE4_1_PATH:-}"
if [[ -z "$CMAKE_4_1" ]]; then
  CMAKE_4_1="$(first_existing \
    "$SCRIPT_DIR/cmake-4.1.1/bin/cmake.exe" \
    "$(command -v cmake || true)" \
  )" || true
fi

# 特殊模式：直接用最新版
for a in "$@"; do
  case "$a" in -E|-P|--help|-help|--version|-version) exec "$CMAKE_4_1" "$@";; esac
done

# 无参数时，直接使用 4.1.1
if [[ $# -eq 0 ]]; then
  log "No relevant args -> cmake-4.1.1"
  exec "$CMAKE_4_1" "$@"
fi

# 源码目录解析
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

# 默认使用最新版本
CHOSEN="$CMAKE_4_1"
if [[ -n "$SRC_DIR" && -f "$SRC_DIR/CMakeLists.txt" ]]; then
  MIN="$(grep -ioE 'cmake_minimum_required[[:space:]]*\([[:space:]]*VERSION[[:space:]]+[0-9]+(\.[0-9]+)?' "$SRC_DIR/CMakeLists.txt" \
          | sed -E 's/.*VERSION[[:space:]]*//' | head -n1 || true)"
  if [[ -z "$MIN" ]]; then
    MIN="$(grep -ioE 'cmake_policy[[:space:]]*\([[:space:]]*VERSION[[:space:]]+[0-9]+(\.[0-9]+)?' "$SRC_DIR/CMakeLists.txt" \
            | sed -E 's/.*VERSION[[:space:]]*//' | head -n1 || true)"
  fi
  if [[ -n "$MIN" ]]; then
    MAJOR="${MIN%%.*}"; REST="${MIN#*.}"; [[ "$REST" == "$MIN" ]] && MINOR=0 || MINOR="${REST%%.*}"
    
    # 版本选择逻辑
    if (( MAJOR < 3 || (MAJOR == 3 && MINOR < 5) )); then
      CHOSEN="$CMAKE_3_5"
      log "Detected minimum ${MAJOR}.${MINOR} (<3.5) -> cmake-3.5.2"
    elif (( MAJOR < 4 )); then
      CHOSEN="$CMAKE_3_31"
      log "Detected minimum ${MAJOR}.${MINOR} (>=3.5 and <4.0) -> cmake-3.31.8"
    else
      CHOSEN="$CMAKE_4_1"
      log "Detected minimum ${MAJOR}.${MINOR} (>=4.0) -> cmake-4.1.1"
    fi
  else
    log "No minimum found -> cmake-4.1.1 (default)"
  fi
else
  log "No source dir -> cmake-4.1.1 (default)"
fi

if [[ -z "$CHOSEN" || ! -f "$CHOSEN" ]]; then
  echo "Selected CMake not found: $CHOSEN" >&2
  echo "Place cmake-3.5.2, cmake-3.31.8 or cmake-4.1.1 under $SCRIPT_DIR, or set CMAKE3_5_PATH / CMAKE3_31_PATH / CMAKE4_1_PATH." >&2
  exit 1
fi

exec "$CHOSEN" "$@"