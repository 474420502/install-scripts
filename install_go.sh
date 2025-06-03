#!/bin/bash

# 严格模式
set -euo pipefail

# --- 配置参数 ---
DEFAULT_GO_VERSION="1.24.3" # Let's use a more recent typical Go version
INSTALL_BASE_DIR="/usr/local/share"
MIRRORS=(
    "https://golang.google.cn/dl/"
    "https://dl.google.com/go/"
    "https://mirrors.aliyun.com/golang/"
    "https://mirrors.tuna.tsinghua.edu.cn/golang/"
    "https://mirrors.sjtug.sjtu.edu.cn/golang/"
    "https://mirrors.hust.edu.cn/golang/"
)
GOROOT_DIR="${INSTALL_BASE_DIR}/go"
GOPATH_DIR="${INSTALL_BASE_DIR}/gopath" # Changed from /usr/local/gopath for consistency
PROFILE_FILE="/etc/profile"

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 帮助函数 ---
function info() { echo -e "${BLUE}[INFO]${NC} $1"; }
function success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
function warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
function error_exit() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

function confirm_action() {
    local message="$1"; local default_response="${2:-y}"; local prompt_suffix=" (Y/n)"
    if [[ "${default_response,,}" == "n" ]]; then prompt_suffix=" (y/N)"; fi
    local response
    while true; do
        read -r -p "$message${prompt_suffix}? " response; response="${response:-${default_response}}"
        case "${response,,}" in y|yes) return 0 ;; n|no) return 1 ;; *) warning "请输入 y 或 n." ;; esac
    done
}

function check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then error_exit "此脚本需要以 root 权限运行。请尝试使用 'sudo $0' 来执行。"; fi
    info "以 root 权限运行。"
}

function detect_arch() {
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;; aarch64) echo "arm64" ;; armv6l|armv7l) echo "armv6l" ;;
        *) warning "未知的系统架构: $arch. 将尝试使用 amd64。"; echo "amd64" ;;
    esac
}

# --- 主逻辑 ---
function main() {
    check_root
    local target_version; read -r -p "请输入要安装的 Go 版本 (默认为 ${DEFAULT_GO_VERSION}): " target_version
    target_version="${target_version:-${DEFAULT_GO_VERSION}}"
    info "将要安装/升级的 Go 版本: ${target_version}"
    if ! confirm_action "确认版本 ${target_version} 是否正确"; then info "操作已取消。"; exit 0; fi

    local go_arch; go_arch=$(detect_arch); info "检测到系统架构: ${go_arch}"
    local go_tar="go${target_version}.linux-${go_arch}.tar.gz"

    if [[ -x "${GOROOT_DIR}/bin/go" ]]; then
        current_version=$("${GOROOT_DIR}/bin/go" version | awk '{print $3}' | sed 's/go//')
        warning "检测到已安装 Go 版本: ${current_version} 在 ${GOROOT_DIR}"
        if ! confirm_action "确定要替换为 ${target_version} 吗"; then info "操作已取消。"; exit 0; fi
    elif [[ -d "${GOROOT_DIR}" ]]; then
        warning "检测到目录 ${GOROOT_DIR} 已存在，但可能不是有效的 Go 安装。"
        if ! confirm_action "是否继续并覆盖此目录 (旧内容将备份)"; then info "操作已取消。"; exit 0; fi
    fi

    local download_url; info "请选择下载镜像源 (用于 ${go_tar})："
    for i in "${!MIRRORS[@]}"; do echo "$((i+1)). ${MIRRORS[$i]}"; done
    local choice
    while true; do
        read -r -p "请输入选择 (1-${#MIRRORS[@]}, 默认1): " choice; choice=${choice:-1}
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MIRRORS[@]}" ]; then
            download_url="${MIRRORS[$((choice-1))]}${go_tar}"; info "已选择镜像源: ${download_url}"; break
        else warning "无效选择。"; fi
    done

    local temp_tarball="/tmp/${go_tar}"; info "正在从 ${download_url} 下载 Go ${target_version}..."
    local wget_opts=(-q --show-progress --tries=3 --timeout=60 --no-check-certificate)
    if ! wget "${wget_opts[@]}" "${download_url}" -O "${temp_tarball}"; then
        warning "从 ${download_url} 下载失败。尝试其他镜像源..."
        local found_mirror=false
        for mirror_base in "${MIRRORS[@]}"; do
            if [[ "${mirror_base}${go_tar}" == "${download_url}" ]]; then continue; fi
            local current_try_url="${mirror_base}${go_tar}"; info "尝试从 ${current_try_url} 下载..."
            if wget "${wget_opts[@]}" "${current_try_url}" -O "${temp_tarball}"; then
                success "从 ${current_try_url} 下载成功"; found_mirror=true; download_url="$current_try_url"; break
            fi
        done
        if ! ${found_mirror}; then rm -f "${temp_tarball}"; error_exit "所有镜像源下载均失败。"; fi
    else success "从 ${download_url} 下载成功。"; fi

    local goroot_backup_dir=""
    if [[ -d "${GOROOT_DIR}" ]]; then
        goroot_backup_dir="${GOROOT_DIR}-backup-$(date +%Y%m%d%H%M%S)"
        info "备份旧版本 ${GOROOT_DIR} 到 ${goroot_backup_dir}"
        if ! mv "${GOROOT_DIR}" "${goroot_backup_dir}"; then error_exit "备份旧版本失败。"; fi
        success "旧版本已备份到 ${goroot_backup_dir}"
    fi

    info "正在安装 Go ${target_version} 到 ${GOROOT_DIR}..."; mkdir -p "${INSTALL_BASE_DIR}"
    if ! tar -C "${INSTALL_BASE_DIR}" -xzf "${temp_tarball}"; then
        if [[ -d "${GOROOT_DIR}" ]]; then rm -rf "${GOROOT_DIR}"; fi
        if [[ -n "${goroot_backup_dir}" && -d "${goroot_backup_dir}" ]]; then
            warning "Go 解压安装失败，正在尝试恢复备份..."
            if mv "${goroot_backup_dir}" "${GOROOT_DIR}"; then
                warning "备份已恢复到 ${GOROOT_DIR}"
            else
                warning "恢复备份失败。旧的 Go 可能在 ${goroot_backup_dir}。"
            fi
        fi
        rm -f "${temp_tarball}"; error_exit "Go 解压安装失败。"
    fi
    success "Go 解压安装成功。"
    rm -f "${temp_tarball}"; info "临时下载文件 ${temp_tarball} 已删除。"

    if [[ ! -d "${GOPATH_DIR}" ]]; then
        info "创建 GOPATH 目录: ${GOPATH_DIR}"; mkdir -p "${GOPATH_DIR}"
    else info "GOPATH 目录 ${GOPATH_DIR} 已存在。"; fi
    success "GOPATH 目录已设置为: ${GOPATH_DIR}"

    info "--- 检查并配置环境变量 (${PROFILE_FILE}) ---"
    local goroot_to_set="${GOROOT_DIR}"; local gopath_to_set="${GOPATH_DIR}"
    local goroot_bin_abs="${GOROOT_DIR}/bin"; local gopath_bin_abs="${GOPATH_DIR}/bin"
    local goroot_bin_var="\$GOROOT/bin"; local gopath_bin_var="\$GOPATH/bin"

    local profile_backup="${PROFILE_FILE}.bak_$(date +%Y%m%d%H%M%S)_go_install"
    info "正在备份 ${PROFILE_FILE} 到 ${profile_backup}..."; cp "${PROFILE_FILE}" "${profile_backup}"
    success "${PROFILE_FILE} 已备份到 ${profile_backup}"

    local temp_profile_file_for_processing="${PROFILE_FILE}.tmp_process_$$"
    cp "${PROFILE_FILE}" "${temp_profile_file_for_processing}"

    local new_profile_lines_stage1=()
    local goroot_export_found=false; local gopath_export_found=false
    local path_export_found=false; local line_modified_in_loop=false

    mapfile -t current_profile_lines < "$temp_profile_file_for_processing"

    for (( i=0; i<${#current_profile_lines[@]}; i++ )); do
        local line="${current_profile_lines[$i]}"; local original_line="$line"

        if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+GOROOT= ]]; then
            goroot_export_found=true
            if [[ "$line" != "export GOROOT=${goroot_to_set}" ]]; then
                info "更新 GOROOT: 旧 '${line}' -> 新 'export GOROOT=${goroot_to_set}'"
                line="export GOROOT=${goroot_to_set}"
            fi
        fi
        if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+GOPATH= ]]; then
            gopath_export_found=true
            if [[ "$line" != "export GOPATH=${gopath_to_set}" ]]; then
                info "更新 GOPATH: 旧 '${line}' -> 新 'export GOPATH=${gopath_to_set}'"
                line="export GOPATH=${gopath_to_set}"
            fi
        fi
        
        if [[ "$line" =~ ^([[:space:]]*export[[:space:]]+PATH=)(.*) ]]; then
            path_export_found=true
            local path_prefix="${BASH_REMATCH[1]}"
            local path_value_str="${BASH_REMATCH[2]}"
            
            local path_has_goroot_bin=false; local path_has_gopath_bin=false

            if [[ "$path_value_str" == *"$goroot_bin_abs"* || "$path_value_str" == *'$GOROOT/bin'* || "$path_value_str" == *'${GOROOT}/bin'* ]]; then
                path_has_goroot_bin=true
            fi
            if [[ "$path_value_str" == *"$gopath_bin_abs"* || "$path_value_str" == *'$GOPATH/bin'* || "$path_value_str" == *'${GOPATH}/bin'* ]]; then
                path_has_gopath_bin=true
            fi
            
            local append_to_this_path_value=""
            if ! $path_has_goroot_bin; then append_to_this_path_value+=":${goroot_bin_var}"; fi
            if ! $path_has_gopath_bin; then append_to_this_path_value+=":${gopath_bin_var}"; fi

            if [[ -n "$append_to_this_path_value" ]]; then
                local modified_path_value_str="$path_value_str"
                if [[ "$modified_path_value_str" =~ ^(\".*)\"$ ]]; then
                    modified_path_value_str="${BASH_REMATCH[1]}${append_to_this_path_value}\""
                elif [[ "$modified_path_value_str" =~ ^(\'.*)\'$ ]]; then
                    modified_path_value_str="${BASH_REMATCH[1]}${append_to_this_path_value}\'"
                elif [[ -z "$modified_path_value_str" ]] && [[ "${append_to_this_path_value:0:1}" == ":" ]]; then
                    modified_path_value_str="${append_to_this_path_value:1}"
                else
                    modified_path_value_str+="$append_to_this_path_value"
                fi
                line="${path_prefix}${modified_path_value_str}"
            fi
        fi
        
        if [[ "$line" != "$original_line" ]]; then line_modified_in_loop=true; fi
        new_profile_lines_stage1+=("$line")
    done
    rm -f "$temp_profile_file_for_processing"

    local final_new_profile_lines=()
    local new_goroot_line_to_add=""
    local new_gopath_line_to_add=""
    local new_path_line_to_add=""

    if ! $goroot_export_found; then new_goroot_line_to_add="export GOROOT=${goroot_to_set}"; fi
    if ! $gopath_export_found; then new_gopath_line_to_add="export GOPATH=${gopath_to_set}"; fi
    if ! $path_export_found; then new_path_line_to_add="export PATH=\$PATH:${goroot_bin_var}:${gopath_bin_var}"; fi

    if $path_export_found && ([[ -n "$new_goroot_line_to_add" ]] || [[ -n "$new_gopath_line_to_add" ]]); then
        local path_line_encountered_for_insertion=false
        for existing_line in "${new_profile_lines_stage1[@]}"; do
            if [[ "$existing_line" =~ ^[[:space:]]*export[[:space:]]+PATH= ]] && ! $path_line_encountered_for_insertion; then
                path_line_encountered_for_insertion=true
                if [[ -n "$new_goroot_line_to_add" ]]; then
                    info "Inserting new GOROOT export before existing PATH line."
                    final_new_profile_lines+=("$new_goroot_line_to_add")
                    new_goroot_line_to_add=""
                fi
                if [[ -n "$new_gopath_line_to_add" ]]; then
                    info "Inserting new GOPATH export before existing PATH line."
                    final_new_profile_lines+=("$new_gopath_line_to_add")
                    new_gopath_line_to_add=""
                fi
            fi
            final_new_profile_lines+=("$existing_line")
        done
    else
        final_new_profile_lines=("${new_profile_lines_stage1[@]}")
    fi

    if [[ -n "$new_goroot_line_to_add" ]]; then final_new_profile_lines+=("$new_goroot_line_to_add"); fi
    if [[ -n "$new_gopath_line_to_add" ]]; then final_new_profile_lines+=("$new_gopath_line_to_add"); fi
    if [[ -n "$new_path_line_to_add" ]];   then final_new_profile_lines+=("$new_path_line_to_add"); fi

    local temp_profile_file_for_diff="${PROFILE_FILE}.tmp_diff_$$"
    printf "%s\n" "${final_new_profile_lines[@]}" > "$temp_profile_file_for_diff"

    if ! diff -q "${profile_backup}" "${temp_profile_file_for_diff}" >/dev/null; then
        info "检测到需要对 ${PROFILE_FILE} 进行以下更改:"
        echo "-------------------------- DIFF START --------------------------"
        diff -u "${profile_backup}" "${temp_profile_file_for_diff}" || true
        echo "--------------------------- DIFF END ---------------------------"
        
        if confirm_action "确认将以上更改写入 ${PROFILE_FILE} 吗"; then
            cat "${temp_profile_file_for_diff}" > "${PROFILE_FILE}"; success "${PROFILE_FILE} 已更新。"
            echo "更改概要:"
            if ! $goroot_export_found && grep -q -E "^[[:space:]]*export[[:space:]]+GOROOT=${goroot_to_set}" "${temp_profile_file_for_diff}"; then
                echo "  - 新增: export GOROOT=${goroot_to_set}"
            elif $goroot_export_found && ! grep -q -E "^[[:space:]]*export[[:space:]]+GOROOT=${goroot_to_set}" "${profile_backup}" && grep -q -E "^[[:space:]]*export[[:space:]]+GOROOT=${goroot_to_set}" "${temp_profile_file_for_diff}"; then
                 echo "  - 更新: GOROOT 设置为 ${goroot_to_set}"
            fi

            if ! $gopath_export_found && grep -q -E "^[[:space:]]*export[[:space:]]+GOPATH=${gopath_to_set}" "${temp_profile_file_for_diff}"; then
                echo "  - 新增: export GOPATH=${gopath_to_set}"
            elif $gopath_export_found && ! grep -q -E "^[[:space:]]*export[[:space:]]+GOPATH=${gopath_to_set}" "${profile_backup}" && grep -q -E "^[[:space:]]*export[[:space:]]+GOPATH=${gopath_to_set}" "${temp_profile_file_for_diff}"; then
                 echo "  - 更新: GOPATH 设置为 ${gopath_to_set}"
            fi
            
            local path_line_in_backup; path_line_in_backup=$(grep -E "^[[:space:]]*export[[:space:]]+PATH=" "${profile_backup}" || true)
            local path_line_in_temp; path_line_in_temp=$(grep -E "^[[:space:]]*export[[:space:]]+PATH=" "${temp_profile_file_for_diff}" || true)

            if ! $path_export_found && [[ -n "$path_line_in_temp" ]]; then
                 echo "  - 新增: export PATH 行 (包含 ${goroot_bin_var} 和 ${gopath_bin_var})"
            elif $path_export_found && [[ "$path_line_in_backup" != "$path_line_in_temp" ]] ; then
                 if ( [[ "$path_line_in_temp" == *"$goroot_bin_var"* ]] && ! [[ "$path_line_in_backup" == *"$goroot_bin_var"* ]] ) || \
                    ( [[ "$path_line_in_temp" == *"$gopath_bin_var"* ]] && ! [[ "$path_line_in_backup" == *"$gopath_bin_var"* ]] ); then
                    echo "  - 修改: export PATH 行以确保包含 ${goroot_bin_var} 和 ${gopath_bin_var}。"
                 elif [[ -n "$path_line_in_temp" ]]; then
                    echo "  - 修改: export PATH 行或其周围环境配置。"
                 fi
            fi

        else warning "${PROFILE_FILE} 未被修改。备份文件保留在 ${profile_backup}"; fi
    else success "${PROFILE_FILE} 中的 Go 环境变量已是最新，无需修改。"; rm "${profile_backup}"; fi
    
    rm -f "${temp_profile_file_for_diff}"

    # 新增：询问是否删除备份文件
    local backup_files_to_remove=()
    if [[ -f "${profile_backup}" ]]; then backup_files_to_remove+=("${profile_backup}"); fi
    if [[ -n "${goroot_backup_dir}" && -d "${goroot_backup_dir}" ]]; then backup_files_to_remove+=("${goroot_backup_dir}"); fi

    if [[ ${#backup_files_to_remove[@]} -gt 0 ]]; then
        info "以下备份文件可以被删除:"
        for backup_file in "${backup_files_to_remove[@]}"; do
            echo "  - ${backup_file}"
        done
        
        if confirm_action "是否删除以上列出的所有备份文件 (默认为 n)" "n"; then
            for backup_file in "${backup_files_to_remove[@]}"; do
                if [[ -f "${backup_file}" ]]; then
                    rm -f "${backup_file}" && info "已删除文件: ${backup_file}"
                elif [[ -d "${backup_file}" ]]; then
                    rm -rf "${backup_file}" && info "已删除目录: ${backup_file}"
                fi
            done
            success "所有备份文件已删除"
        else
            info "保留备份文件"
        fi
    fi

    success "\nGo ${target_version} 已成功安装到 ${GOROOT_DIR}"
    info "GOROOT: ${GOROOT_DIR}"; info "GOPATH: ${GOPATH_DIR}"
    if ! diff -q "${profile_backup}" "${PROFILE_FILE}" 2>/dev/null && [[ -f "${profile_backup}" ]]; then
         warning "请执行 'source ${PROFILE_FILE}' 或重新登录使环境变量更改生效。"
    fi
    info "您可以通过运行 '${GOROOT_DIR}/bin/go version' 来验证安装。"
}
main "$@"