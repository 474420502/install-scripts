#!/bin/bash

set -euo pipefail

DEFAULT_NVM_VERSION="v0.40.4"
DEFAULT_PROFILE_MODE="auto"
DEFAULT_NODE_VERSION="skip"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

function info() { echo -e "${BLUE}[INFO]${NC} $1"; }
function success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
function warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
function error_exit() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

function print_help() {
    cat <<'EOF'
用法:
  ./install_nvm.sh [选项]

说明:
  按 nvm 官方当前推荐方式安装或升级 nvm 本体，并可选安装 Node 版本。
  默认按用户安装，不建议使用 sudo。

选项:
  --nvm-version <latest|v0.40.4|0.40.4>
      指定要安装/升级的 nvm 版本，默认 latest。

  --node-version <skip|lts/*|node|22.12.0>
      安装完 nvm 后可选顺带安装一个 Node 版本，默认 skip。

  --profile <auto|none|PATH>
      指定让 nvm installer 写入哪个 shell 配置文件。
      auto: 自动检测。
      none: 等同 PROFILE=/dev/null，不修改配置文件。

  --nvm-dir <PATH>
      指定 nvm 安装目录。默认遵循官方规则：
      ~/.nvm 或 $XDG_CONFIG_HOME/nvm

  --yes
      跳过交互确认，直接按参数执行。

  --help, -h
      显示帮助。

示例:
  ./install_nvm.sh
  ./install_nvm.sh --nvm-version latest --node-version 'lts/*'
  ./install_nvm.sh --nvm-version v0.40.4 --node-version 22.12.0 --profile ~/.bashrc --yes
  ./install_nvm.sh --profile none --yes
EOF
}

function confirm_action() {
    local message="$1"
    local default_response="${2:-y}"
    local prompt_suffix=" (Y/n)"

    if [[ "${ASSUME_YES}" == "true" ]]; then
        info "已启用 --yes: ${message}"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        if [[ "${default_response,,}" == "y" ]]; then
            return 0
        fi
        return 1
    fi

    if [[ "${default_response,,}" == "n" ]]; then
        prompt_suffix=" (y/N)"
    fi

    local response
    while true; do
        read -r -p "$message${prompt_suffix}? " response
        response="${response:-${default_response}}"
        case "${response,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) warning "请输入 y 或 n." ;;
        esac
    done
}

function check_runtime() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        error_exit "检测到通过 sudo 运行。nvm 官方建议按用户安装，请切回目标用户后直接执行脚本。"
    fi

    if [[ "$(id -u)" -eq 0 ]]; then
        warning "当前以 root 用户运行，nvm 将安装到 ${HOME}，这通常不是推荐方式。"
        if ! confirm_action "确认仍然继续" "n"; then
            info "操作已取消。"
            exit 0
        fi
    fi

    if ! command -v bash >/dev/null 2>&1; then
        error_exit "未检测到 bash，无法继续。"
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        error_exit "需要 curl 或 wget 之一来下载 nvm 官方 install.sh。"
    fi
}

function normalize_nvm_version() {
    local version="$1"
    if [[ -z "$version" || "$version" == "latest" ]]; then
        echo "latest"
    elif [[ "$version" =~ ^v[0-9] ]]; then
        echo "$version"
    else
        echo "v${version}"
    fi
}

function default_nvm_dir() {
    if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
        printf '%s/nvm' "${XDG_CONFIG_HOME}"
    else
        printf '%s/.nvm' "${HOME}"
    fi
}

function download_text() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 30 "$url"
    else
        wget -q --timeout=30 -O - "$url"
    fi
}

function download_file() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$output"
    else
        wget -q --timeout=60 -O "$output" "$url"
    fi
}

function fetch_latest_nvm_version() {
    local latest_version=""

    latest_version="$(download_text "https://api.github.com/repos/nvm-sh/nvm/releases/latest" 2>/dev/null | grep -o '"tag_name": "[^"]*"' | head -1 | sed 's/"tag_name": "//; s/"$//')"
    if [[ -n "$latest_version" ]]; then
        echo "$latest_version"
        return 0
    fi

    if command -v git >/dev/null 2>&1; then
        latest_version="$(git ls-remote --tags --refs https://github.com/nvm-sh/nvm.git 'v[0-9]*' 2>/dev/null | awk -F/ '{print $3}' | sort -V | tail -1)"
        if [[ -n "$latest_version" ]]; then
            echo "$latest_version"
            return 0
        fi
    fi

    return 1
}

function detect_profile_file() {
    local shell_name
    shell_name="$(basename "${SHELL:-bash}")"

    local -a candidates=()
    case "$shell_name" in
        zsh) candidates+=("${HOME}/.zshrc" "${HOME}/.zprofile") ;;
        bash) candidates+=("${HOME}/.bashrc" "${HOME}/.bash_profile") ;;
        *) candidates+=("${HOME}/.profile") ;;
    esac
    candidates+=("${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.zshrc" "${HOME}/.profile")

    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf '%s\n' "${candidates[0]}"
}

function ensure_profile_file() {
    local profile_file="$1"
    if [[ "$profile_file" == "/dev/null" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$profile_file")"
    if [[ ! -f "$profile_file" ]]; then
        touch "$profile_file"
        info "已创建 shell 配置文件: ${profile_file}"
    fi
}

function source_nvm() {
    local nvm_dir="$1"
    if [[ ! -s "${nvm_dir}/nvm.sh" ]]; then
        return 1
    fi

    local had_errexit=0
    local had_nounset=0
    local had_pipefail=0

    [[ $- == *e* ]] && had_errexit=1
    [[ $- == *u* ]] && had_nounset=1
    if set -o | grep -q '^pipefail[[:space:]]\+on$'; then
        had_pipefail=1
    fi

    set +e
    set +u
    set +o pipefail

    export NVM_DIR="$nvm_dir"
    # shellcheck source=/dev/null
    . "${nvm_dir}/nvm.sh" --no-use >/dev/null 2>&1
    local rc=$?

    if (( had_errexit )); then set -e; fi
    if (( had_nounset )); then set -u; fi
    if (( had_pipefail )); then
        set -o pipefail
    else
        set +o pipefail
    fi

    return "$rc"
}

function installed_nvm_version() {
    local nvm_dir="$1"
    if source_nvm "$nvm_dir" && command -v nvm >/dev/null 2>&1; then
        nvm --version 2>/dev/null || true
    fi
}

function install_or_update_nvm() {
    local target_version="$1"
    local nvm_dir="$2"
    local profile_file="$3"
    local install_url="https://raw.githubusercontent.com/nvm-sh/nvm/${target_version}/install.sh"
    local temp_script
    temp_script="$(mktemp)"

    info "正在下载 nvm 官方 install.sh: ${install_url}"
    if ! download_file "$install_url" "$temp_script"; then
        rm -f "$temp_script"
        error_exit "下载 ${install_url} 失败，请检查版本号或网络连接。"
    fi

    info "正在执行 nvm 官方安装/升级脚本..."
    if ! env NVM_DIR="$nvm_dir" PROFILE="$profile_file" bash "$temp_script"; then
        rm -f "$temp_script"
        error_exit "nvm 官方 install.sh 执行失败。"
    fi

    rm -f "$temp_script"
}

function maybe_install_node() {
    local node_version="$1"

    if [[ -z "$node_version" || "$node_version" == "skip" ]]; then
        info "跳过 Node 安装。"
        return 0
    fi

    info "开始安装 Node 版本: ${node_version}"
    nvm install "$node_version"
    nvm alias default "$node_version" >/dev/null
    nvm use default >/dev/null

    local current_node_version=""
    current_node_version="$(node -v 2>/dev/null || true)"
    if [[ -n "$current_node_version" ]]; then
        success "Node 已安装并设为默认版本: ${current_node_version}"
    else
        success "Node 版本 ${node_version} 已安装并设为默认版本。"
    fi
}

function main() {
    ASSUME_YES="false"
    local requested_nvm_version="latest"
    local requested_node_version="$DEFAULT_NODE_VERSION"
    local profile_mode="$DEFAULT_PROFILE_MODE"
    local custom_nvm_dir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nvm-version)
                [[ $# -ge 2 ]] || error_exit "--nvm-version 需要一个参数。"
                requested_nvm_version="$2"
                shift 2
                ;;
            --node-version)
                [[ $# -ge 2 ]] || error_exit "--node-version 需要一个参数。"
                requested_node_version="$2"
                shift 2
                ;;
            --profile)
                [[ $# -ge 2 ]] || error_exit "--profile 需要一个参数。"
                profile_mode="$2"
                shift 2
                ;;
            --nvm-dir)
                [[ $# -ge 2 ]] || error_exit "--nvm-dir 需要一个参数。"
                custom_nvm_dir="$2"
                shift 2
                ;;
            --yes)
                ASSUME_YES="true"
                shift
                ;;
            --help|-h)
                print_help
                exit 0
                ;;
            *)
                error_exit "未知参数: $1。可使用 --help 查看说明。"
                ;;
        esac
    done

    check_runtime

    local online_nvm_version=""
    local resolved_latest_version="$DEFAULT_NVM_VERSION"
    online_nvm_version="$(fetch_latest_nvm_version || true)"
    if [[ -n "$online_nvm_version" ]]; then
        resolved_latest_version="$online_nvm_version"
        info "检测到最新 nvm 版本: ${online_nvm_version}"
    else
        warning "无法在线获取最新 nvm 版本，回退到预设版本: ${DEFAULT_NVM_VERSION}"
    fi

    if [[ -t 0 && "$ASSUME_YES" != "true" && "$requested_nvm_version" == "latest" ]]; then
        local nvm_input=""
        read -r -p "请输入要安装/升级的 nvm 版本 (默认为 ${resolved_latest_version}; 输入 latest 也可): " nvm_input
        requested_nvm_version="${nvm_input:-${resolved_latest_version}}"
    fi

    local target_nvm_version
    target_nvm_version="$(normalize_nvm_version "$requested_nvm_version")"
    if [[ "$target_nvm_version" == "latest" ]]; then
        target_nvm_version="$resolved_latest_version"
    fi

    if [[ -t 0 && "$ASSUME_YES" != "true" && "$requested_node_version" == "$DEFAULT_NODE_VERSION" ]]; then
        local node_input=""
        read -r -p "如需顺带安装 Node，请输入 node / lts/* / 具体版本；直接回车跳过: " node_input
        requested_node_version="${node_input:-skip}"
    fi

    local profile_file=""
    case "$profile_mode" in
        auto) profile_file="$(detect_profile_file)" ;;
        none) profile_file="/dev/null" ;;
        *) profile_file="$profile_mode" ;;
    esac
    ensure_profile_file "$profile_file"

    local nvm_dir=""
    if [[ -n "$custom_nvm_dir" ]]; then
        nvm_dir="$custom_nvm_dir"
    else
        nvm_dir="$(default_nvm_dir)"
    fi

    local current_nvm_version=""
    current_nvm_version="$(installed_nvm_version "$nvm_dir")"
    if [[ -n "$current_nvm_version" ]]; then
        info "检测到当前已安装 nvm 版本: ${current_nvm_version}"
    fi

    info "目标 nvm 版本: ${target_nvm_version}"
    info "nvm 安装目录: ${nvm_dir}"
    if [[ "$profile_file" == "/dev/null" ]]; then
        info "shell 配置文件: 不自动写入"
    else
        info "shell 配置文件: ${profile_file}"
    fi
    if [[ "$requested_node_version" == "skip" ]]; then
        info "Node 安装: 跳过"
    else
        info "Node 安装: ${requested_node_version}"
    fi

    local should_run_installer="true"
    if [[ -n "$current_nvm_version" && "$current_nvm_version" == "${target_nvm_version#v}" ]]; then
        warning "当前 nvm 已是目标版本 ${target_nvm_version}。"
        if ! confirm_action "是否仍重新执行官方 installer，以确认或修复 shell 配置" "y"; then
            should_run_installer="false"
        fi
    else
        if ! confirm_action "确认继续安装/升级 nvm 到 ${target_nvm_version}"; then
            info "操作已取消。"
            exit 0
        fi
    fi

    if [[ "$should_run_installer" == "true" ]]; then
        install_or_update_nvm "$target_nvm_version" "$nvm_dir" "$profile_file"
    fi

    if ! source_nvm "$nvm_dir" || ! command -v nvm >/dev/null 2>&1; then
        error_exit "nvm 安装后无法在当前 shell 中加载，请检查 ${nvm_dir}/nvm.sh。"
    fi

    local final_nvm_version=""
    final_nvm_version="$(nvm --version 2>/dev/null || true)"
    if [[ -z "$final_nvm_version" ]]; then
        error_exit "无法验证 nvm 安装结果。"
    fi

    maybe_install_node "$requested_node_version"

    success "nvm 安装/升级完成，当前版本: ${final_nvm_version}"
    info "验证命令: command -v nvm"
    if [[ "$profile_file" == "/dev/null" ]]; then
        warning "你选择了不自动写入 shell 配置。请手动加入以下内容:"
        echo "export NVM_DIR=\"${nvm_dir}\""
        echo "[ -s \"\$NVM_DIR/nvm.sh\" ] && \\. \"\$NVM_DIR/nvm.sh\""
        echo "[ -s \"\$NVM_DIR/bash_completion\" ] && \\. \"\$NVM_DIR/bash_completion\""
    else
        warning "请执行 'source ${profile_file}' 或重新打开终端，使 nvm 命令在新 shell 中生效。"
    fi
}

main "$@"