#!/bin/bash
# down.vps.mom/scripts/install-dstatus-agent.sh
# 作用：安装/更新 DStatus 探针（统一为 dstatus-agent），并兼容旧版 neko-status
# 原因：与外部脚本及面板一致化命名，减少服务名/路径不一致导致的安装失败
# 相关：down.vps.mom/scripts/README.md, static/sh/install-agent.sh, static/sh/remove-agent.sh, static/js/admin/autodiscovery-manager.js

# 错误处理
set -e
# 只记操作名；自动发现命令的第一个参数是注册密钥，不能在出错提示里原样打印
case "${1:-}" in
    install|uninstall|reinstall-config|repair-openrc) REQUESTED_OPERATION="$1" ;;
    *) REQUESTED_OPERATION="" ;;
esac
# --- 名称定义 ---
NEW_AGENT_BINARY_NAME="dstatus-agent"
# 统一使用 dstatus-agent 作为服务名
NEW_SERVICE_NAME="dstatus-agent"
NEW_CONFIG_DIR="/etc/dstatus-agent"
NEW_CONFIG_FILE="${NEW_CONFIG_DIR}/config.yaml"
NEW_BINARY_PATH="/usr/bin/${NEW_AGENT_BINARY_NAME}"

OLD_AGENT_BINARY_NAME="neko-status"
OLD_SERVICE_NAME="nekonekostatus"
OLD_CONFIG_DIR="/etc/neko-status"
OLD_CONFIG_FILE="${OLD_CONFIG_DIR}/config.yaml"
OLD_BINARY_PATH="/usr/bin/${OLD_AGENT_BINARY_NAME}"

# 特殊网络安装（TASK-1032）：本机不能上外网、只能经内网反代访问面板时，命令带 DSTATUS_DOWNLOAD_VIA_PANEL=1，
# Agent 经命令里的面板地址下载（面板开了「经面板下载 Agent」才提供），不查外部 IP，配置写 download_via_panel 与 public_ip_lookup。
DOWNLOAD_VIA_PANEL=false
case "$(printf '%s' "${DSTATUS_DOWNLOAD_VIA_PANEL:-}" | tr 'A-Z' 'a-z')" in 1|true|yes|on) DOWNLOAD_VIA_PANEL=true ;; esac
PANEL_DOWNLOAD_ROOT=""   # <面板地址>/api/agent/download/；只有这个前缀下的下载带凭证
PANEL_ENROLL_TOKEN=""    # 新装：安装授权
PANEL_AGENT_KEY=""       # 重装：节点通讯密钥与节点 ID
PANEL_AGENT_SID=""

# --- 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_info() { echo -e "${BLUE}[信息]${NC} $1"; }
print_success() { echo -e "${GREEN}[成功]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }
die() { print_error "$1"; exit "${2:-1}"; }

# 安装事务只操作本次记录的文件；备份与目标同文件系统，恢复使用 rename。
INSTALL_WORK_DIR=""
INSTALL_SWITCH_STARTED=false
INSTALL_FILES_CHANGED=false
INSTALL_COMMITTED=false
INSTALL_ENABLE_ATTEMPTED=false
INSTALL_LOCK_HELD=false
INSTALL_PATHS=()
INSTALL_BACKUP_DIRS=()
INSTALL_RUNNING_SERVICES=()

select_service_file() {
    if [[ "$OS_FAMILY" == "alpine" ]] && has_command rc-service; then
        INSTALL_INIT=openrc
        INSTALL_SERVICE_FILE="/etc/init.d/${NEW_SERVICE_NAME}"
    elif [[ "$OS_FAMILY" == "openwrt" || "$OS_FAMILY" == "immortalwrt" ]] && [ -f /etc/rc.common ]; then
        INSTALL_INIT=procd
        INSTALL_SERVICE_FILE="/etc/init.d/${NEW_SERVICE_NAME}"
    elif has_command systemctl; then
        INSTALL_INIT=systemd
        INSTALL_SERVICE_FILE="/etc/systemd/system/${NEW_SERVICE_NAME}.service"
    elif [ -d /etc/init.d ]; then
        INSTALL_INIT=sysv
        INSTALL_SERVICE_FILE="/etc/init.d/${NEW_SERVICE_NAME}"
    else
        die "无法检测到可验证的服务管理器。"
    fi
}

begin_install_transaction() {
    select_service_file
    for tool in sha256sum timeout od readlink; do has_command "$tool" || die "缺少校验工具: $tool"; done
    mkdir /run/dstatus-agent-install.lock 2>/dev/null || die "已有安装事务或未恢复的事务，请先检查 /run/dstatus-agent-install.lock。"
    INSTALL_LOCK_HELD=true
    INSTALL_WORK_DIR=$(mktemp -d "$(dirname "$NEW_BINARY_PATH")/.dstatus-agent-install.XXXXXX") || return 1
    printf '%s\n' "$INSTALL_WORK_DIR" > /run/dstatus-agent-install.lock/workdir || return 1
    INSTALL_CONFIG_DIR_EXISTED=false
    [ ! -d "$NEW_CONFIG_DIR" ] || INSTALL_CONFIG_DIR_EXISTED=true
}

snapshot_install_file() {
    local target="$1" backup_dir
    # 拒绝目录，允许普通文件/软链；不跟随软链覆盖其指向的文件。
    [ ! -d "$target" ] || { print_error "目标是目录，拒绝替换: $target"; return 1; }
    backup_dir=$(mktemp -d "$(dirname "$target")/.dstatus-agent-backup.XXXXXX") || return 1
    INSTALL_PATHS+=("$target")
    INSTALL_BACKUP_DIRS+=("$backup_dir")
    printf '%s\t%s\n' "$target" "$backup_dir" >> "$INSTALL_WORK_DIR/backups" || return 1
    if [ -e "$target" ] || [ -L "$target" ]; then
        cp -a "$target" "$backup_dir/original" || return 1
    fi
}

managed_service_running() {
    local service="$1"
    case "$INSTALL_INIT" in
        systemd) systemctl is-active --quiet "$service" ;;
        openrc) rc-service "$service" status >/dev/null 2>&1 ;;
        procd) [ -f "/etc/init.d/$service" ] && "/etc/init.d/$service" running >/dev/null 2>&1 ;;
        sysv)
            local binary="$NEW_BINARY_PATH" config="$NEW_CONFIG_FILE"
            [ "$service" != "$OLD_SERVICE_NAME" ] || { binary="$OLD_BINARY_PATH"; config="$OLD_CONFIG_FILE"; }
            agent_process_id "$binary" "$config" >/dev/null ;;
    esac
}

manage_install_service() {
    local action="$1" service="$2"
    case "$INSTALL_INIT" in
        systemd) systemctl "$action" "$service" ;;
        openrc) rc-service "$service" "$action" ;;
        procd|sysv) "/etc/init.d/$service" "$action" ;;
    esac
}

# >>> agent-process.sh：源为 static/sh/agent-process.sh，运行 node scripts/sync-agent-installer.js 同步
# shellcheck shell=bash
# 探针进程归属：Linux 按 /proc 中的可执行文件和可选配置路径匹配，避免依赖 procps 或误杀同名程序。
# 公网脚本内嵌此文件；主控安装/卸载由 modules/servers/func.js 拼接。维护口径见 docs/开发/客户安装脚本开发维护.md。

agent_process_pids() {
    local binary="$1" config="${2:-}" resolved proc executable arg previous matched pid
    resolved=$(readlink -f "$binary") || { [ ! -e "$binary" ] && return 0; return 1; }
    for proc in /proc/[0-9]*/exe; do
        executable=$(readlink "$proc" 2>/dev/null) || continue
        [ "${executable% (deleted)}" = "$resolved" ] || continue
        matched=false
        if [ -z "$config" ]; then
            matched=true
        else
            previous=""
            # 进程可能在扫描时退出；消失的 cmdline 不是安装失败。
            while IFS= read -r -d '' arg; do
                if [ "$previous" = -c ] && [ "$arg" = "$config" ]; then matched=true; break; fi
                previous="$arg"
            done 2>/dev/null < "${proc%/exe}/cmdline" || true
        fi
        if [ "$matched" = true ]; then
            pid=${proc%/exe}
            printf '%s\n' "${pid##*/}"
        fi
    done
    return 0
}

agent_process_id() {
    local pids
    pids=$(agent_process_pids "$@") || return 1
    [ -n "$pids" ] || return 1
    printf '%s\n' "${pids%%$'\n'*}"
}

# 先停止所属服务，再调用此函数清理尚未退出的本探针。每次发信号前重新核对归属。
agent_stop_processes() {
    local binary="$1" config="${2:-}" pids pid attempt
    pids=$(agent_process_pids "$binary" "$config") || return 1
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
    for attempt in 1 2 3 4 5; do
        pids=$(agent_process_pids "$binary" "$config") || return 1
        [ -n "$pids" ] || return 0
        sleep 1
    done
    pids=$(agent_process_pids "$binary" "$config") || return 1
    for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
    sleep 1
    pids=$(agent_process_pids "$binary" "$config") || return 1
    [ -z "$pids" ] || { printf 'Agent 进程未能停止：%s\n' "$binary" >&2; return 1; }
}
# <<< agent-process.sh

verify_running_agent() {
    local service="$1" binary="$2" config="$3" verify_http="${4:-false}" pid previous_pid="" stable=0 attempt port
    port=$(sed -n 's/^port:[[:space:]]*//p' "$config" | tr -d '"\047\r')
    # 连续存活十秒（超过 RestartSec），拒绝自动重启循环和空壳 supervisor。
    for attempt in {1..30}; do
        if managed_service_running "$service" && pid=$(agent_process_id "$binary" "$config"); then
            if [ "$pid" = "$previous_pid" ]; then stable=$((stable + 1)); else stable=0; fi
            previous_pid="$pid"
            if [ "$stable" -ge 10 ]; then
                if [ "$verify_http" != true ] || grep -Eq '^report_enabled:[[:space:]]*true' "$config"; then return 0; fi
                if has_command curl; then
                    curl --noproxy '*' -fsS --max-time 2 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && return 0
                else
                    wget -q -T 2 -O /dev/null "http://127.0.0.1:$port/healthz" && return 0
                fi
            fi
        else
            stable=0
            previous_pid=""
        fi
        sleep 1
    done
    return 1
}

installation_boot_links() {
    local link target
    for link in /etc/systemd/system/*.service /etc/systemd/system/*.wants/* /etc/systemd/system/*.requires/* \
        /run/systemd/system/*.service /run/systemd/system/*.wants/* /run/systemd/system/*.requires/* \
        /etc/runlevels/*/* /etc/rc*.d/* /etc/rc.d/*; do
        [ -L "$link" ] || continue
        target=$(readlink "$link") || return 1
        case "$target" in
            */"$NEW_SERVICE_NAME"|*/"$OLD_SERVICE_NAME"|*/"$NEW_SERVICE_NAME.service"|*/"$OLD_SERVICE_NAME.service") printf '%s\n' "$link" ;;
        esac
    done
}

switch_installation() {
    local service link i
    mkdir -p "$NEW_CONFIG_DIR" || return 1
    snapshot_install_file "$NEW_BINARY_PATH" || return 1
    snapshot_install_file "$NEW_CONFIG_FILE" || return 1
    snapshot_install_file "$INSTALL_SERVICE_FILE" || return 1
    while IFS= read -r link; do
        [ "$link" != "$INSTALL_SERVICE_FILE" ] || continue
        snapshot_install_file "$link" || return 1
    done < <(installation_boot_links)
    for service in "$OLD_SERVICE_NAME" "$NEW_SERVICE_NAME"; do
        if managed_service_running "$service"; then INSTALL_RUNNING_SERVICES+=("$service"); fi
    done
    INSTALL_SWITCH_STARTED=true
    for service in "${INSTALL_RUNNING_SERVICES[@]}"; do
        manage_install_service stop "$service" || return 1
    done
    # stop 失败或未纳管的进程仍在运行时拒绝覆盖。
    if agent_process_id "$NEW_BINARY_PATH" >/dev/null || agent_process_id "$OLD_BINARY_PATH" >/dev/null; then
        print_error "原 Agent 进程未停止，拒绝切换。"
        return 1
    fi
    # Agent 运行期间可能保存配置；停止后刷新备份，避免回滚到过早的快照。
    for i in 0 1 2; do
        if [ -e "${INSTALL_PATHS[i]}" ] || [ -L "${INSTALL_PATHS[i]}" ]; then
            cp -a "${INSTALL_PATHS[i]}" "${INSTALL_BACKUP_DIRS[i]}/latest" || return 1
            mv -f "${INSTALL_BACKUP_DIRS[i]}/latest" "${INSTALL_BACKUP_DIRS[i]}/original" || return 1
        fi
    done
    INSTALL_FILES_CHANGED=true
    mv -f "$INSTALL_WORK_DIR/binary" "$NEW_BINARY_PATH" || return 1
    # 配置/服务的最终临时文件也放在目标目录内，避免跨文件系统覆盖。
    cp "$INSTALL_WORK_DIR/config" "${INSTALL_BACKUP_DIRS[1]}/new" || return 1
    chmod 600 "${INSTALL_BACKUP_DIRS[1]}/new" || return 1
    mv -f "${INSTALL_BACKUP_DIRS[1]}/new" "$NEW_CONFIG_FILE" || return 1
    cp "$INSTALL_WORK_DIR/service" "${INSTALL_BACKUP_DIRS[2]}/new" || return 1
    chmod 755 "${INSTALL_BACKUP_DIRS[2]}/new" || return 1
    mv -f "${INSTALL_BACKUP_DIRS[2]}/new" "$INSTALL_SERVICE_FILE" || return 1
    [ "$INSTALL_INIT" != systemd ] || systemctl daemon-reload || return 1
}

enable_installed_service() {
    case "$INSTALL_INIT" in
        systemd) systemctl enable "$NEW_SERVICE_NAME" ;;
        openrc) rc-update add "$NEW_SERVICE_NAME" default ;;
        procd) "/etc/init.d/$NEW_SERVICE_NAME" enable ;;
        sysv) update-rc.d "$NEW_SERVICE_NAME" defaults || chkconfig "$NEW_SERVICE_NAME" on ;;
    esac
}

rollback_installation() {
    local failed=0 i service binary config link
    print_warning "安装未完成，正在恢复原 Agent..."
    if [ "$INSTALL_FILES_CHANGED" = true ]; then
        manage_install_service stop "$NEW_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    if [ "$INSTALL_ENABLE_ATTEMPTED" = true ]; then
        # enable/disable 可改多个别名和 runlevel 链接；恢复原链接，不推测 enabled 状态。
        while IFS= read -r link; do rm -f "$link" || failed=1; done < <(installation_boot_links)
    fi
    if [ "$INSTALL_FILES_CHANGED" = true ]; then
        for ((i=${#INSTALL_PATHS[@]}-1; i>=0; i--)); do
            if [ -e "${INSTALL_BACKUP_DIRS[i]}/original" ] || [ -L "${INSTALL_BACKUP_DIRS[i]}/original" ]; then
                mv -f "${INSTALL_BACKUP_DIRS[i]}/original" "${INSTALL_PATHS[i]}" || failed=1
            else
                rm -f "${INSTALL_PATHS[i]}" || failed=1
            fi
        done
    fi
    if [ "$INSTALL_INIT" = systemd ]; then
        systemctl daemon-reload || failed=1
        systemctl reset-failed "$NEW_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    for service in "${INSTALL_RUNNING_SERVICES[@]}"; do
        binary="$NEW_BINARY_PATH"; config="$NEW_CONFIG_FILE"
        [ "$service" != "$OLD_SERVICE_NAME" ] || { binary="$OLD_BINARY_PATH"; config="$OLD_CONFIG_FILE"; }
        manage_install_service start "$service" && verify_running_agent "$service" "$binary" "$config" || failed=1
    done
    if [ "$failed" -ne 0 ]; then
        print_error "自动恢复未完成；备份保留在 ${INSTALL_WORK_DIR}（backups 记录恢复路径），请人工恢复后再重试。"
        return 1
    fi
    print_warning "已恢复安装前的文件和服务运行状态。"
}

cleanup_install_transaction() {
    local backup_dir
    for backup_dir in "${INSTALL_BACKUP_DIRS[@]}"; do rm -rf "$backup_dir" || return 1; done
    [ -z "$INSTALL_WORK_DIR" ] || rm -rf "$INSTALL_WORK_DIR" || return 1
    if [ "${INSTALL_CONFIG_DIR_EXISTED:-true}" = false ] && [ "$INSTALL_COMMITTED" = false ]; then
        rmdir "$NEW_CONFIG_DIR" 2>/dev/null || true
    fi
    if [ "$INSTALL_LOCK_HELD" = true ]; then
        rm -f /run/dstatus-agent-install.lock/workdir || return 1
        rmdir /run/dstatus-agent-install.lock || return 1
    fi
}

commit_installation() {
    INSTALL_ENABLE_ATTEMPTED=true
    enable_installed_service || return 1
    case "$INSTALL_INIT" in
        systemd)
            if [ -e "/etc/systemd/system/$OLD_SERVICE_NAME.service" ] || [ -e "/lib/systemd/system/$OLD_SERVICE_NAME.service" ]; then
                systemctl disable "$OLD_SERVICE_NAME" || return 1
            fi ;;
        openrc)
            if [ -e "/etc/runlevels/default/$OLD_SERVICE_NAME" ]; then rc-update del "$OLD_SERVICE_NAME" default || return 1; fi ;;
        procd) if [ -f "/etc/init.d/$OLD_SERVICE_NAME" ]; then "/etc/init.d/$OLD_SERVICE_NAME" disable || return 1; fi ;;
        sysv) if [ -f "/etc/init.d/$OLD_SERVICE_NAME" ]; then update-rc.d -f "$OLD_SERVICE_NAME" remove || chkconfig "$OLD_SERVICE_NAME" off || return 1; fi ;;
    esac
    INSTALL_COMMITTED=true
    # 兼容别名与旧版本清理只在新服务稳定运行后处理。
    ln -sf "$NEW_BINARY_PATH" /usr/bin/neko-status 2>/dev/null || true
    remove_dstatus_aliases
    register_dsa_command
}

# 旧版本建过 /usr/bin/dstatus 与 dstatus 服务别名，和面板（Docker 安装的服务也叫 dstatus）、npm 包 dstatus 撞名（TASK-1027）。
# 不再新建；已有的只在确实指向本 Agent 时删除，面板自己的服务文件不碰。
alias_points_to_agent() {
    local link="$1" target
    [ -L "$link" ] || return 1
    target=$(readlink "$link" 2>/dev/null || true)
    case "$target" in
        "$NEW_BINARY_PATH"|*/dstatus-agent|*/neko-status|neko-status|dstatus-agent) return 0 ;;
        "/etc/systemd/system/${NEW_SERVICE_NAME}.service"|"${NEW_SERVICE_NAME}.service") return 0 ;;
        "/etc/init.d/${NEW_SERVICE_NAME}"|"${NEW_SERVICE_NAME}") return 0 ;;
    esac
    return 1
}

remove_dstatus_aliases() {
    local link removed_unit=false
    for link in /usr/bin/dstatus /etc/init.d/dstatus; do
        if alias_points_to_agent "$link"; then rm -f "$link" && print_info "已删除与面板同名的旧别名 $link"; fi
    done
    if alias_points_to_agent /etc/systemd/system/dstatus.service; then
        rm -f /etc/systemd/system/dstatus.service && removed_unit=true
        print_info "已删除与面板同名的旧服务别名 /etc/systemd/system/dstatus.service"
    fi
    # 旧版面板安装脚本对别名执行过 systemctl enable dstatus：只删指向本 Agent 或已失效别名的启用链接。
    link=/etc/systemd/system/multi-user.target.wants/dstatus.service
    if [ -L "$link" ]; then
        case "$(readlink "$link" 2>/dev/null || true)" in
            "/etc/systemd/system/${NEW_SERVICE_NAME}.service"|/etc/systemd/system/dstatus.service)
                if [ ! -e /etc/systemd/system/dstatus.service ]; then rm -f "$link" && removed_unit=true; fi ;;
        esac
    fi
    if [ "$removed_unit" = true ] && has_command systemctl; then systemctl daemon-reload 2>/dev/null || true; fi
    return 0
}

# 本机管理命令 dsa（DStatus Agent）。只在 /usr/bin/dsa 不存在或本来就指向本 Agent 时建立，不覆盖别人的 dsa。
# 装上的被控程序有没有 dsa 和「允许面板运行脚本」开关：agent-v2.3.5 及更早没有，随下一版被控发布。
# 面板可能先于被控发版（TASK-1036）：旧程序不登记 dsa（它不认 dsa 这个名字，会照常启动被控服务），也不提示 dsa 用法。
# 只跑 -v（打印版本就退出，所有版本都有）；没有正式版本号的自建或测试构建按支持处理（它们来自带 dsa 的主线）。
agent_supports_dsa() {
    local ver major minor patch
    ver=$("$NEW_BINARY_PATH" -v 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    [ -n "$ver" ] || return 0
    major=${ver%%.*}; minor=${ver#*.}; minor=${minor%%.*}; patch=${ver##*.}
    [ "$major" -ne 2 ] && { [ "$major" -gt 2 ]; return; }
    [ "$minor" -ne 3 ] && { [ "$minor" -gt 3 ]; return; }
    [ "$patch" -gt 5 ]
}

register_dsa_command() {
    agent_supports_dsa || return 0
    if [ -e /usr/bin/dsa ] || [ -L /usr/bin/dsa ]; then
        if ! alias_points_to_agent /usr/bin/dsa; then
            print_warning "/usr/bin/dsa 已被其他程序占用，未注册管理命令；可直接用 ${NEW_BINARY_PATH} 的软链自行建立。"
            return 0
        fi
    fi
    ln -sfn "$NEW_BINARY_PATH" /usr/bin/dsa 2>/dev/null || print_warning "注册管理命令 /usr/bin/dsa 失败。"
    return 0
}

# 本机键：允许面板运行脚本（allow_remote_exec）、远程关令牌、自动升级的本机设置。重装原样保留；
# 新装默认不允许；DSTATUS_ALLOW_EXEC=1 允许、=0 不允许（明确给了就以它为准）。旧键 remote_shell_enabled 转成新键。
read_config_scalar() {
    [ -n "$1" ] && [ -f "$1" ] || return 0
    sed -n "s/^$2:[[:space:]]*//p" "$1" 2>/dev/null | head -n 1 | sed "s/[[:space:]]*#.*\$//; s/^[\"']//; s/[\"']\$//"
}

normalize_allow_exec_env() {
    case "$(printf '%s' "${DSTATUS_ALLOW_EXEC:-}" | tr 'A-Z' 'a-z')" in
        '') echo "" ;;
        1|true|yes|on) echo "true" ;;
        0|false|no|off) echo "false" ;;
        *) return 1 ;;
    esac
}

agent_local_config_lines() {
    local source_config="$1" allow legacy token auto_local ip_lookup via_panel explicit
    explicit=$(normalize_allow_exec_env) || { print_error "DSTATUS_ALLOW_EXEC 只能是 1 或 0。" >&2; return 1; }
    allow=$(read_config_scalar "$source_config" allow_remote_exec | tr 'A-Z' 'a-z')
    legacy=$(read_config_scalar "$source_config" remote_shell_enabled | tr 'A-Z' 'a-z')
    token=$(read_config_scalar "$source_config" remote_exec_off_token)
    auto_local=$(read_config_scalar "$source_config" auto_upgrade_local | tr 'A-Z' 'a-z')
    ip_lookup=$(read_config_scalar "$source_config" public_ip_lookup | tr 'A-Z' 'a-z')
    via_panel=$(read_config_scalar "$source_config" download_via_panel | tr 'A-Z' 'a-z')
    # 特殊网络安装：不查公网 IP（外部查不到，只会一直报错），升级先经面板下载
    if [ "$DOWNLOAD_VIA_PANEL" = true ]; then ip_lookup=false; via_panel=true; fi
    case "$allow" in true|false) ;; *) allow="" ;; esac
    case "$legacy" in true|false) ;; *) legacy="" ;; esac
    if [ -n "$explicit" ]; then
        allow="$explicit"
    elif [ -z "$allow" ] && [ -n "$legacy" ]; then
        allow="$legacy"
    elif [ -z "$allow" ] && [ -z "$source_config" ]; then
        # 新装：默认不允许面板在本机运行脚本（用户 2026-11-08 决定）。已有配置却没写的是升级前装的节点，保持没写（按允许）。
        allow=false
    fi
    [ -z "$allow" ] || printf 'allow_remote_exec: %s\n' "$allow"
    if [[ "$token" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then printf 'remote_exec_off_token: "%s"\n' "$token"; fi
    case "$auto_local" in true|false) printf 'auto_upgrade_local: %s\n' "$auto_local" ;; esac
    # 本机关掉的「查询公网 IP」重装后保持关；没写或写 true 都是默认打开，不写。
    [ "$ip_lookup" != "false" ] || printf 'public_ip_lookup: false\n'
    [ "$via_panel" != "true" ] || printf 'download_via_panel: true\n'
    return 0
}

print_agent_management_summary() {
    local allow
    allow=$(read_config_scalar "$NEW_CONFIG_FILE" allow_remote_exec | tr 'A-Z' 'a-z')
    if ! agent_supports_dsa; then
        case "$allow" in
            false) print_info "${BLUE}运行脚本:${NC} 这版被控还没有本机开关，面板照旧可以运行脚本；被控升级到新版后默认不允许，需要时执行 ${GREEN}sudo dsa exec on${NC}" ;;
            *) print_info "${BLUE}运行脚本:${NC} 这版被控还没有本机开关，面板照旧可以运行脚本；被控升级到新版后可用 ${GREEN}sudo dsa${NC} 管理" ;;
        esac
        return 0
    fi
    print_info "${BLUE}本机管理:${NC} 运行 ${GREEN}sudo dsa${NC} 打开菜单；脚本与 AI 用 ${GREEN}dsa status --json${NC}、${GREEN}sudo dsa restart${NC}、${GREEN}sudo dsa logs${NC} 等，${GREEN}dsa help${NC} 查看全部"
    case "$allow" in
        false) print_info "${BLUE}运行脚本:${NC} 面板不能在这台机器上运行脚本；需要时执行 ${GREEN}sudo dsa exec on${NC}" ;;
        true) print_info "${BLUE}运行脚本:${NC} 已允许面板在这台机器上运行脚本；关闭执行 ${GREEN}sudo dsa exec off${NC}" ;;
        *) print_info "${BLUE}运行脚本:${NC} 保持原样（允许）；不需要面板运行脚本时执行 ${GREEN}sudo dsa exec off${NC}" ;;
    esac
}

installer_exit() {
    local status=$? recovered=true
    trap - EXIT
    trap '' HUP INT TERM
    set +e
    if [ "$INSTALL_SWITCH_STARTED" = true ] && [ "$INSTALL_COMMITTED" = false ]; then
        [ "$status" -ne 0 ] || status=1
        rollback_installation || recovered=false
    fi
    if [ "$recovered" = true ]; then
        cleanup_install_transaction || print_warning "临时文件清理未完成，请检查 ${INSTALL_WORK_DIR}。"
    fi
    if [ "$status" -ne 0 ]; then print_error "${REQUESTED_OPERATION:-安装}未完成。"; fi
    exit "$status"
}
trap installer_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

normalize_single_line_text() {
    printf '%s' "${1:-}" | tr '\r\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

normalize_download_base() {
    local url="${1:-}"
    url="${url%/}"
    case "$url" in
        */dstatus-agent|*/neko-status)
            url="${url%/*}"
            ;;
    esac
    printf '%s' "$url"
}

has_command() {
    command -v "$1" >/dev/null 2>&1
}

ensure_download_tool_available() {
    if has_command curl; then
        print_info "检测到可用下载工具: curl"
        return 0
    fi

    if has_command wget; then
        print_info "检测到可用下载工具: wget"
        return 0
    fi

    die "未检测到可用下载工具，请先手工安装 curl 或 wget 后重试。"
}

is_panel_download_url() {
    [ -n "$PANEL_DOWNLOAD_ROOT" ] && [ "${1#"$PANEL_DOWNLOAD_ROOT"}" != "$1" ]
}

# 经面板下载要凭证（新装带安装授权，已有身份的重装再带节点密钥，面板认其中一个即可）；只发给面板地址，不发给 GitHub 与加速站。
panel_download_headers() {
    PANEL_HEADER_LINES=()
    is_panel_download_url "$1" || return 0
    [ -z "$PANEL_ENROLL_TOKEN" ] || PANEL_HEADER_LINES+=("X-DStatus-Enroll: ${PANEL_ENROLL_TOKEN}")
    if [ -n "$PANEL_AGENT_KEY" ] && [ -n "$PANEL_AGENT_SID" ]; then
        PANEL_HEADER_LINES+=("key: ${PANEL_AGENT_KEY}" "X-DStatus-Sid: ${PANEL_AGENT_SID}")
    fi
}

# 下载顺序（TASK-792）：面板 /api/client/download-prefix 按这台机器所在地区排好（downloadPlan），脚本只按顺序逐个试，
# 不测速竞速。每个来源只试一次、不回头：后面还有来源时，低于 50KB/s 持续 15 秒就换下一个；最后一个来源不因慢放弃，
# 只按 30 秒没进度放弃（用户 2026-11-15「不要引发循环」「不要有问题需要花很长时间才能反应过来换源」）。
DSTATUS_GITHUB_RELEASE_PREFIX="https://github.com/fev125/dstatus/releases/download/"
# 老面板不给下载顺序时用的内置国内入口，与面板 modules/agent-download/sources.js 的内置清单一致
DSTATUS_BUILTIN_MIRROR_PREFIX="https://dsdl.2byy.cn/"
SLOW_SPEED_LIMIT=51200
SLOW_SPEED_TIME=15
PLAN_BASES=()
PANEL_RELEASE_BASE=""
PANEL_CHECKSUMS=false
LAST_DOWNLOAD_HTTP_CODE=""
LAST_DOWNLOAD_CURL_EXIT=""

download_tag_from_base() {
    local base
    base="$(normalize_download_base "${1:-}")"
    base="${base##*/}"
    if [[ "$base" =~ ^agent-(latest|v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?)$ ]]; then printf '%s' "$base"; fi
}

# <前缀>https://github.com/fev125/dstatus/releases/download/<标签> → GitHub 发布目录；认不出返回空
download_github_base_of() {
    local base
    base="$(normalize_download_base "${1:-}")"
    case "$base" in
        https://github.com/fev125/dstatus/releases/download/*) printf '%s' "$base"; return 0 ;;
    esac
    printf '%s' "$base" | sed -n 's|^https://[^/]*/\(https://github\.com/fev125/dstatus/releases/download/[^/]*\)$|\1|p' | head -n1
}

download_label_for_base() {
    local base="${1:-}" host
    if is_panel_download_url "$base"; then echo "面板"; return; fi
    case "$base" in
        https://github.com/*) echo "GitHub" ;;
        https://dsdl.2byy.cn/*) echo "国内加速（EdgeOne）" ;;
        https://gh-proxy.com/*) echo "第三方加速 gh-proxy" ;;
        https://ghfast.top/*) echo "第三方加速 ghfast" ;;
        *) host="${base#*://}"; echo "${host%%/*}" ;;
    esac
}

download_failure_reason() {
    # 服务器回了错误状态时按状态码说（不同版本的 curl 对 HTTP 错误报 22 或 56）
    case "${LAST_DOWNLOAD_HTTP_CODE:-}" in 4??|5??) LAST_DOWNLOAD_CURL_EXIT=22 ;; esac
    case "${LAST_DOWNLOAD_CURL_EXIT:-}" in
        28) echo "太慢或超时" ;;
        22)
            case "${LAST_DOWNLOAD_HTTP_CODE:-}" in
                404) echo "没有这个文件" ;;
                401|403) echo "被拒绝（HTTP ${LAST_DOWNLOAD_HTTP_CODE}）" ;;
                503) echo "面板正在准备文件或忙" ;;
                *) echo "返回 HTTP ${LAST_DOWNLOAD_HTTP_CODE:-错误}" ;;
            esac ;;
        6) echo "域名解析失败" ;;
        7) echo "连不上" ;;
        35|51|58|60) echo "加密连接或证书出错" ;;
        "") echo "下载失败" ;;
        *) echo "下载失败（curl ${LAST_DOWNLOAD_CURL_EXIT}）" ;;
    esac
}

download_with_curl() {
    local source_url="$1"
    local target_file="$2"
    local connect_timeout="${3:-15}"
    local retry_count="${4:-0}"
    local speed_limit="${5:-1}"
    local speed_time="${6:-30}"
    local -a header_args=()
    local line code rc=0
    panel_download_headers "$source_url"
    for line in "${PANEL_HEADER_LINES[@]}"; do header_args+=(-H "$line"); done
    # 带凭证时不跟随跳转：curl 会把 -H 的请求头原样带给跳转后的网站（面板自己不跳转，跳转只可能来自反代配置）
    [ "${#header_args[@]}" -eq 0 ] || header_args+=(--max-redirs 0)
    code=$(curl -fsSL "${header_args[@]}" --connect-timeout "$connect_timeout" --retry "$retry_count" --retry-max-time 240 \
        --speed-limit "$speed_limit" --speed-time "$speed_time" -w '%{http_code}' "$source_url" -o "$target_file") || rc=$?
    LAST_DOWNLOAD_HTTP_CODE="$code"
    return "$rc"
}

download_with_wget() {
    local source_url="$1"
    local target_file="$2"
    local connect_timeout="${3:-30}"
    local -a header_args=()
    local line
    panel_download_headers "$source_url"
    for line in "${PANEL_HEADER_LINES[@]}"; do header_args+=("--header=$line"); done
    [ "${#header_args[@]}" -eq 0 ] || header_args+=(--max-redirect=0)
    wget -q --tries=1 "${header_args[@]}" -T "$connect_timeout" -O "$target_file" "$source_url"
}

# 下一个来源还在后面（is_last=false）：慢了就换、面板忙不等；最后一个来源：慢也下完，面板忙按 Retry-After 等（最多约 4 分钟）
download_with_available_tools() {
    local source_url="$1"
    local target_file="$2"
    local source_base="${3:-}"
    local is_last="${4:-true}"
    local connect_timeout=15 retry_count=0 speed_limit=1 speed_time=30
    if [ "$is_last" != true ]; then
        connect_timeout=10
        speed_limit="$SLOW_SPEED_LIMIT"
        speed_time="$SLOW_SPEED_TIME"
    elif is_panel_download_url "$source_base"; then
        retry_count=8
    fi

    LAST_DOWNLOAD_CURL_EXIT=""
    LAST_DOWNLOAD_HTTP_CODE=""
    if has_command curl; then
        if download_with_curl "$source_url" "$target_file" "$connect_timeout" "$retry_count" "$speed_limit" "$speed_time"; then
            return 0
        else
            LAST_DOWNLOAD_CURL_EXIT=$?
        fi
        # 有 curl 就不再用 wget 重下：wget 没有低速中断，会破坏「每个来源只试一次、慢了就换」
        rm -f "$target_file"
        return 1
    fi

    if has_command wget && download_with_wget "$source_url" "$target_file" "$connect_timeout"; then
        return 0
    fi

    rm -f "$target_file"
    return 1
}

# 下载顺序里的一项：只收 https 地址；http 只收本面板的地址（内网反代）
plan_add_base() {
    local candidate existing
    candidate="$(normalize_download_base "${1:-}")"
    [ -n "$candidate" ] || return 0
    case "$candidate" in
        *[[:space:]\"\'\`\$\\]*) return 0 ;;
        https://*) ;;
        http://*) is_panel_download_url "$candidate" || return 0 ;;
        *) return 0 ;;
    esac
    for existing in "${PLAN_BASES[@]:-}"; do
        [ "$existing" = "$candidate" ] && return 0
    done
    PLAN_BASES+=("$candidate")
}

# 排出 PLAN_BASES：面板 SSH 代装给的 DSTATUS_DOWNLOAD_BASES > 面板答复的 downloadPlan > 老面板的兜底顺序
build_download_plan() {
    local response="${1:-}" prefix_url="${2:-}" tag="${3:-agent-latest}" panel_offered="${4:-false}"
    local item plan_items github
    PLAN_BASES=()
    if [ -n "${DSTATUS_DOWNLOAD_BASES:-}" ]; then
        for item in $DSTATUS_DOWNLOAD_BASES; do plan_add_base "$item"; done
        [ "${#PLAN_BASES[@]}" -eq 0 ] || return 0
    fi
    # 命令里明确指定了下载前缀：它排第一
    [ -z "${DSTATUS_DOWNLOAD_PREFIX:-}" ] || plan_add_base "$DSTATUS_DOWNLOAD_PREFIX"
    plan_items="$(printf '%s' "$response" | tr -d '\r\n' | sed -n 's/.*"downloadPlan"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p')"
    if [ -n "$plan_items" ]; then
        while IFS= read -r item; do
            [ "$item" = panel ] && item="$PANEL_RELEASE_BASE"
            plan_add_base "$item"
        done <<< "$plan_items"
        return 0
    fi
    # 老面板（没有 downloadPlan）：设置里选的加速前缀 → GitHub → 内置国内入口 → 两个第三方加速站（老面板照旧可用）→ 面板
    github="$(download_github_base_of "$prefix_url")"
    [ -n "$github" ] || github="${DSTATUS_GITHUB_RELEASE_PREFIX}${tag}"
    plan_add_base "$prefix_url"
    plan_add_base "$github"
    plan_add_base "${DSTATUS_BUILTIN_MIRROR_PREFIX}${github}"
    plan_add_base "https://gh-proxy.com/${github}"
    plan_add_base "https://ghfast.top/${github}"
    [ "$panel_offered" != true ] || plan_add_base "$PANEL_RELEASE_BASE"
}

# 问面板要下载顺序；带上安装授权或节点密钥，面板据此判断这台机器在不在中国大陆
fetch_download_prefix() {
    local server_url="${1%/}" line
    local -a header_args=()
    [ -z "$PANEL_ENROLL_TOKEN" ] || header_args+=(-H "X-DStatus-Enroll: ${PANEL_ENROLL_TOKEN}")
    if [ -n "$PANEL_AGENT_KEY" ] && [ -n "$PANEL_AGENT_SID" ]; then
        header_args+=(-H "key: ${PANEL_AGENT_KEY}" -H "X-DStatus-Sid: ${PANEL_AGENT_SID}")
    fi
    curl -s -m 10 --max-redirs 0 "${header_args[@]}" "${server_url}/api/client/download-prefix" 2>/dev/null || true
}

extract_json_string_field() {
    local json_payload="${1:-}"
    local field_name="${2:-}"

    if [ -z "$field_name" ]; then
        return 0
    fi

    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json_payload" | jq -r --arg field "$field_name" '.[$field] // .data[$field] // empty' 2>/dev/null
        return 0
    fi

    printf '%s' "$json_payload" | sed -n "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
}

extract_json_bool_field() {
    local json_payload="${1:-}"
    local field_name="${2:-}"
    local field_value=""

    if [ -z "$field_name" ]; then
        echo "false"
        return 0
    fi

    if command -v jq >/dev/null 2>&1; then
        field_value=$(printf '%s' "$json_payload" | jq -r --arg field "$field_name" 'if (.[$field] == true or .[$field] == false) then (.[$field] | tostring) elif (.data[$field] == true or .data[$field] == false) then (.data[$field] | tostring) else "false" end' 2>/dev/null)
    else
        field_value=$(printf '%s' "$json_payload" | sed -n "s/.*\"${field_name}\"[[:space:]]*:[[:space:]]*\\(true\\|false\\).*/\\1/p" | head -n1)
    fi

    if [ "$field_value" = "true" ]; then
        echo "true"
    else
        echo "false"
    fi
}

describe_register_curl_failure() {
    local curl_exit_code="${1:-0}"
    case "$curl_exit_code" in
        6) echo "DNS 解析失败，请检查 VPS 的域名解析配置" ;;
        7) echo "无法连接到服务器，请检查地址、端口和防火墙" ;;
        28) echo "连接或响应超时，请检查网络连通性和服务器负载" ;;
        35) echo "TLS 握手失败或协议不兼容，请检查 VPS 本机 TLS 能力与面板反代支持的 TLS 版本" ;;
        51|60) echo "TLS 证书校验失败，请检查证书链、域名和自签证书配置" ;;
        *) echo "网络请求失败 (curl exit code: ${curl_exit_code})" ;;
    esac
}

run_register_request() {
    local server_url="$1"
    local payload="$2"
    local body_file="$3"
    local stderr_file="$4"
    local force_tls12="${5:-false}"
    local -a curl_cmd

    curl_cmd=(
        curl
        -sS
        --connect-timeout 10
        --max-time 20
        -o "$body_file"
        -w "%{http_code}"
        -X POST
        "${server_url%/}/autodiscovery/register"
        -H "Content-Type: application/json"
        -d "$payload"
    )

    if [ "$force_tls12" = "true" ]; then
        curl_cmd+=(--tlsv1.2)
    fi

    set +e
    REGISTER_REQUEST_HTTP_CODE="$("${curl_cmd[@]}" 2>"$stderr_file")"
    REGISTER_REQUEST_EXIT_CODE=$?
    set -e
}

delegate_to_macos_script() {
    local macos_script_url="https://down.vps.mom/scripts/install-dstatus-agent-macos.sh"
    local temp_script=""
    local delegate_exit_code=0
    # 特殊网络安装第一期只有 Linux（TASK-1032）：macOS 安装脚本不会经面板下载，直接说明，不走到一半再报怪错
    if [ "$DOWNLOAD_VIA_PANEL" = true ]; then
        die "特殊网络安装暂不支持 macOS，只支持 Linux。"
    fi
    print_info "检测到 macOS，切换到专用安装脚本..."

    temp_script="$(mktemp "/tmp/dstatus-agent-macos.XXXXXX.sh")" || die "创建 macOS 安装脚本临时文件失败"
    if ! curl -fsSL "$macos_script_url" -o "$temp_script"; then
        rm -f "$temp_script"
        die "拉取 macOS 安装脚本失败: ${macos_script_url}"
    fi

    set +e
    bash "$temp_script" "$@"
    delegate_exit_code=$?
    set -e
    rm -f "$temp_script"

    if [ "$delegate_exit_code" -eq 0 ]; then
        exit 0
    fi
    exit "$delegate_exit_code"
}

# --- 辅助函数 ---
check_root() {
    if [ "$(id -u)" != "0" ]; then 
        die "此脚本需要root权限运行。请使用 sudo 或切换到 root 用户后执行。"
    fi
}

get_system_info() {
    if [ -f /etc.defaults/VERSION ] && [ -x /usr/syno/bin/synosystemctl ]; then OS_FAMILY="synology";
    elif [ -f /etc/alpine-release ]; then OS_FAMILY="alpine";
    elif [ -f /etc/os-release ]; then . /etc/os-release; OS_FAMILY=$ID;
    else die "无法确定操作系统类型"; fi

    HOSTNAME_VAL=$(hostname)
    if [ "$DOWNLOAD_VIA_PANEL" = true ]; then
        # 特殊网络：外部查 IP 的网站连不上，不去试（每个要等 5 秒）；装好后可在面板节点设置里填公网地址
        IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    else
        IP_ADDR=$(curl -s -m 5 https://api.ipify.org || curl -s -m 5 https://ipinfo.io/ip || hostname -I 2>/dev/null | awk '{print $1}' || ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -n1)
    fi
    if [ -z "$IP_ADDR" ]; then IP_ADDR="127.0.0.1"; print_warning "无法获取外部IP，使用本地IP: $IP_ADDR"; fi

    SYSTEM_INFO_OS_NAME=$(uname -s)
    SYSTEM_INFO_OS_VERSION=$(uname -r)

    if command -v ip &> /dev/null; then DEFAULT_NETWORK_DEVICE=$(ip route | grep default | head -n1 | awk '{print $5}');
    elif command -v route &> /dev/null; then DEFAULT_NETWORK_DEVICE=$(route -n | grep 'UG[ \t]' | awk '{print $8}' | head -n1); fi
    if [ -z "$DEFAULT_NETWORK_DEVICE" ]; then print_warning "无法确定默认网卡，将交由主控自动选择"; fi
}

detect_architecture() {
    DOWNLOAD_OS_TYPE_RAW=$(uname -s)
    DOWNLOAD_OS_TYPE=$(printf '%s' "$DOWNLOAD_OS_TYPE_RAW" | tr 'A-Z' 'a-z')
    case "$DOWNLOAD_OS_TYPE" in
        linux*) DOWNLOAD_OS_TYPE="linux" ;;
        darwin*) DOWNLOAD_OS_TYPE="darwin" ;;
    esac
    DOWNLOAD_ARCH_RAW=$(uname -m)
    DOWNLOAD_ARCH="$DOWNLOAD_ARCH_RAW"
    case "$DOWNLOAD_ARCH" in
        x86_64|amd64) DOWNLOAD_ARCH="amd64" ;; i386|i686) DOWNLOAD_ARCH="386" ;;
        aarch64|arm64|armv8*|armv8l) DOWNLOAD_ARCH="arm64" ;; armv7*|armhf) DOWNLOAD_ARCH="arm7" ;;
        arm*) if grep -q "v7" /proc/cpuinfo 2>/dev/null; then DOWNLOAD_ARCH="arm7";
              elif grep -q "v6" /proc/cpuinfo 2>/dev/null; then DOWNLOAD_ARCH="arm6";
              else DOWNLOAD_ARCH="arm7"; fi ;;
        mips64el|mips64le) DOWNLOAD_ARCH="mips64le" ;;
        mips64) DOWNLOAD_ARCH="mips64" ;;
        mipsel|mipsle) DOWNLOAD_ARCH="mipsle" ;;
        mips) DOWNLOAD_ARCH="mips" ;;
        *) print_warning "未知架构: ${DOWNLOAD_ARCH}，将优先尝试通用二进制回退" ;;
    esac
    if [ "$DOWNLOAD_OS_TYPE" = "darwin" ]; then
        if [ "$DOWNLOAD_ARCH" != "amd64" ] && [ "$DOWNLOAD_ARCH" != "arm64" ]; then DOWNLOAD_ARCH="amd64"; fi
    fi
}

system_ca_bundle_present() {
    local bundle
    for bundle in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
        [ -s "$bundle" ] && return 0
    done
    return 1
}

# 需要的东西都在就不碰包管理器：刷新软件源的输出是静默的，源慢或连不上时会无提示地停很久，
# 客户看到的就是「安装卡住」（工单 31）。Alpine 另需 OpenRC 与 pgrep，缺了仍走安装。
install_dependencies_already_met() {
    has_command curl || has_command wget || return 1
    system_ca_bundle_present || return 1
    case "$OS_FAMILY" in
        alpine) has_command rc-service && has_command pgrep ;;
        ubuntu|debian|centos|rhel|fedora|arch|manjaro|openwrt|immortalwrt) return 0 ;;
        *) return 1 ;;
    esac
}

install_dependencies() {
    # DSM 没有通用发行版包管理器，不为安装探针引入 Entware。
    if [ "$OS_FAMILY" = synology ]; then
        ensure_download_tool_available
        return
    fi
    if install_dependencies_already_met; then
        print_info "下载工具和证书已具备，跳过系统依赖安装。"
        return
    fi
    print_info "安装依赖: curl, wget...（软件源较慢时这一步可能要等几分钟）"
    if [[ "$OS_FAMILY" == "alpine" ]]; then
        apk update >/dev/null && apk add --no-cache curl wget procps openrc
    elif [[ "$OS_FAMILY" == "openwrt" || "$OS_FAMILY" == "immortalwrt" ]]; then
        opkg update >/dev/null 2>&1 || true
        opkg install curl wget ca-bundle ca-certificates >/dev/null 2>&1 || \
        opkg install curl wget ca-bundle >/dev/null 2>&1 || \
        print_warning "OpenWrt/ImmortalWrt 依赖安装失败，请确认 opkg 源可用并手工安装 curl/wget/ca 证书"
    elif [[ "$OS_FAMILY" == "ubuntu" || "$OS_FAMILY" == "debian" ]]; then
        # 非交互：Ubuntu 的 needrestart 在终端里装包会弹「要重启哪些服务」对话框（TASK-792 AC#8）
        export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
        apt-get update -qq >/dev/null || { sed -i -E '/^[[:space:]]*deb .*bullseye-backports/s/^/# /' /etc/apt/sources.list 2>/dev/null || true; [ -d /etc/apt/sources.list.d ] && sed -i -E '/^[[:space:]]*deb .*bullseye-backports/s/^/# /' /etc/apt/sources.list.d/*.list 2>/dev/null || true; sed -i 's|bullseye/updates|bullseye-security|g' /etc/apt/sources.list 2>/dev/null || true; [ -d /etc/apt/sources.list.d ] && sed -i 's|bullseye/updates|bullseye-security|g' /etc/apt/sources.list.d/*.list 2>/dev/null || true; apt-get -o Acquire::AllowReleaseInfoChange=true update -qq >/dev/null; }; apt-get install -y -qq curl wget ca-certificates
    elif [[ "$OS_FAMILY" == "centos" || "$OS_FAMILY" == "rhel" || "$OS_FAMILY" == "fedora" ]]; then
        yum install -y -q curl wget
    elif [[ "$OS_FAMILY" == "arch" || "$OS_FAMILY" == "manjaro" ]]; then
        pacman -S --noconfirm curl wget >/dev/null
    else
        print_warning "未知操作系统 ($OS_FAMILY)，请确保已安装: curl wget"
    fi
}

cleanup_old_version_files() {
    local cleaned=false
    if [ -f "$OLD_BINARY_PATH" ] && [ ! -L "$OLD_BINARY_PATH" ]; then
        rm -f "$OLD_BINARY_PATH" && cleaned=true
    fi
    if [ -d "$OLD_CONFIG_DIR" ]; then
        rm -rf "$OLD_CONFIG_DIR" && cleaned=true
    fi
    if [ -f "/etc/systemd/system/$OLD_SERVICE_NAME.service" ]; then
        rm -f "/etc/systemd/system/$OLD_SERVICE_NAME.service" && cleaned=true
        systemctl daemon-reload 2>/dev/null || true
    fi
    # 清理过渡期别名服务文件（已废弃，保留现用 dstatus-agent 服务文件）
    if [ -f "/etc/init.d/$OLD_SERVICE_NAME" ]; then
        rm -f "/etc/init.d/$OLD_SERVICE_NAME" && cleaned=true
    fi
    # 不再删除 /etc/init.d/dstatus-agent（当前主服务名）
    # 清理static/sh脚本可能创建的文件
    if rm -f "/var/run/nekonekostatus.pid" "/var/log/nekonekostatus.log" "/usr/local/bin/nekonekostatus-start" "/usr/local/bin/nekonekostatus-stop" 2>/dev/null; then
        cleaned=true
    fi
    if [ "$cleaned" = true ]; then print_info "已清理历史版本残留文件。"; fi
}

# 经面板下载（TASK-1032）：依次试给出的文件名；成功时 try_url 留下成功地址（调用方的变量），SHA256SUMS 校验用同一来源。
# 在一个来源里取程序文件：标准文件名没有（404）再试通用与旧名。成功时 DOWNLOADED_URL 是实际下载的地址
download_from_base() {
    local base="$1" target_file="$2" is_last="$3" name
    shift 3
    for name in "$@"; do
        DOWNLOADED_URL="${base}/${name}"
        if download_with_available_tools "$DOWNLOADED_URL" "$target_file" "$base" "$is_last"; then
            return 0
        fi
        # 只有「没有这个文件」才在同一来源换文件名；连不上、太慢、被拒绝直接换下一个来源
        [ "${LAST_DOWNLOAD_HTTP_CODE:-}" = 404 ] || return 1
    done
    return 1
}

download_agent_binary() {
    local server_url_for_download="$1"
    local temp_file_downloaded="${INSTALL_WORK_DIR}/binary"
    local server_prefix_response download_prefix_url tag region panel_offered=false
    local primary_filename_to_download fallback_filename_to_download universal_filename_to_download legacy_universal_filename_to_download
    local index total base label is_last reason
    local -a source_results=()

    # 本机下载不了时，用户可先把探针文件放到本机，用 DSTATUS_AGENT_FILE 指定路径，跳过下载。
    if [ -n "${DSTATUS_AGENT_FILE:-}" ]; then
        use_local_agent_binary "$DSTATUS_AGENT_FILE"
        return
    fi

    print_info "获取 ${NEW_AGENT_BINARY_NAME} 下载信息..."
    PANEL_DOWNLOAD_ROOT="${server_url_for_download%/}/api/agent/download/"
    server_prefix_response="$(fetch_download_prefix "$server_url_for_download")"
    download_prefix_url=$(extract_json_string_field "$server_prefix_response" "url")
    if [ -n "${DSTATUS_DOWNLOAD_PREFIX:-}" ]; then download_prefix_url="$DSTATUS_DOWNLOAD_PREFIX"; fi
    [ -n "$download_prefix_url" ] || download_prefix_url="${DSTATUS_GITHUB_RELEASE_PREFIX}agent-latest"
    tag=$(extract_json_string_field "$server_prefix_response" "tag")
    [ -n "$(download_tag_from_base "/$tag")" ] || tag="$(download_tag_from_base "$download_prefix_url")"
    [ -n "$tag" ] || tag="agent-latest"
    region=$(extract_json_string_field "$server_prefix_response" "region")
    [ "$(extract_json_bool_field "$server_prefix_response" "panelDownload")" = true ] && panel_offered=true
    PANEL_CHECKSUMS="$(extract_json_bool_field "$server_prefix_response" "panelChecksums")"
    PANEL_RELEASE_BASE="${PANEL_DOWNLOAD_ROOT}release/${tag}"

    primary_filename_to_download="${NEW_AGENT_BINARY_NAME}_${DOWNLOAD_OS_TYPE}_${DOWNLOAD_ARCH}"
    fallback_filename_to_download="${OLD_AGENT_BINARY_NAME}_${DOWNLOAD_OS_TYPE}_${DOWNLOAD_ARCH}"
    universal_filename_to_download="${NEW_AGENT_BINARY_NAME}_${DOWNLOAD_OS_TYPE}_universal"
    legacy_universal_filename_to_download="${OLD_AGENT_BINARY_NAME}_${DOWNLOAD_OS_TYPE}_universal"

    # 特殊网络安装：本机上不了外网，只经面板下载；失败就停下说明原因，不再去试 GitHub（只会逐个等超时）
    if [ "$DOWNLOAD_VIA_PANEL" = true ]; then
        PLAN_BASES=("$PANEL_RELEASE_BASE")
        print_info "特殊网络安装：经面板下载 ${NEW_AGENT_BINARY_NAME}（${PANEL_RELEASE_BASE}）"
    else
        build_download_plan "$server_prefix_response" "$download_prefix_url" "$tag" "$panel_offered"
    fi
    total="${#PLAN_BASES[@]}"
    print_info "下载目标: ${primary_filename_to_download}（版本 ${tag}）"
    case "$region" in
        cn) print_info "面板判断本机在中国大陆，按以下顺序下载：" ;;
        other) print_info "面板判断本机不在中国大陆，按以下顺序下载：" ;;
        *) print_info "按以下顺序下载：" ;;
    esac
    index=0
    for base in "${PLAN_BASES[@]}"; do
        index=$((index + 1))
        echo "  ${index}. $(download_label_for_base "$base")"
    done

    # 面板回「正在准备」（503）且后面还有来源时先跳过、记下，后面的来源试完再回头等它一次（只回头这一次）：
    # 面板在后台继续准备，这样慢的 GitHub 不会因为排在最后而被一直等下去。
    local deferred_panel="" attempts_left
    index=0
    attempts_left=("${PLAN_BASES[@]}")
    while [ "${#attempts_left[@]}" -gt 0 ]; do
        base="${attempts_left[0]}"
        attempts_left=("${attempts_left[@]:1}")
        index=$((index + 1))
        is_last=false
        if [ "${#attempts_left[@]}" -eq 0 ] && [ -z "$deferred_panel" ]; then is_last=true; fi
        label="$(download_label_for_base "$base")"
        print_info "从 ${label} 下载（${index}/${total}）..."
        if ! download_from_base "$base" "$temp_file_downloaded" "$is_last" \
            "$primary_filename_to_download" "$universal_filename_to_download" \
            "$fallback_filename_to_download" "$legacy_universal_filename_to_download"; then
            if [ "$is_last" != true ] && [ "${LAST_DOWNLOAD_HTTP_CODE:-}" = 503 ] && is_panel_download_url "$base" && [ -z "$deferred_panel" ]; then
                deferred_panel="$base"
                print_info "面板正在准备这个文件，先试后面的来源，稍后回来等它。"
            else
                reason="$(download_failure_reason)"
                source_results+=("${label}：${reason}")
                [ "$is_last" = true ] || print_warning "${label} ${reason}，换下一个来源。"
            fi
        elif ! [ -s "$temp_file_downloaded" ]; then
            source_results+=("${label}：下载到的文件是空的")
            rm -f "$temp_file_downloaded"
        elif validate_agent_binary "$temp_file_downloaded" "$DOWNLOADED_URL"; then
            print_success "已从 ${label} 下载。"
            return 0
        else
            source_results+=("${label}：文件没通过校验")
            rm -f "$temp_file_downloaded"
            [ "$is_last" = true ] || print_warning "${label} 的文件没通过校验，换下一个来源。"
        fi
        if [ "${#attempts_left[@]}" -eq 0 ] && [ -n "$deferred_panel" ]; then
            attempts_left=("$deferred_panel")
            deferred_panel=""
            total=$((total + 1))
            print_info "回到面板，等它准备好文件。"
        fi
    done

    print_error "下载失败: ${NEW_AGENT_BINARY_NAME}。各来源结果："
    for reason in "${source_results[@]}"; do echo "  - ${reason}"; done
    if [ "$DOWNLOAD_VIA_PANEL" = true ]; then
        print_error "请确认：面板「Agent 安装源」不是「只用 GitHub」；命令里的地址在本机能访问；安装授权未过期。"
    fi
    print_local_file_install_hint "${DSTATUS_GITHUB_RELEASE_PREFIX}${tag}" "$primary_filename_to_download"
    rm -f "$temp_file_downloaded"
    return 1
}

# 核对校验和（TASK-792 / TASK-1034）：https 面板提供已验过发版签名的 SHA256SUMS 时一律从面板取，程序可以来自任何来源——
# 下载来源被冒充或下载源清单出错，也装不上别的程序。面板不提供（老面板）、取不到或面板是 http 时，退回下载来源自带的校验和并提示。
validate_agent_binary() {
    local temp_file_downloaded="$1" try_url="$2"
    local checksum_file="$INSTALL_WORK_DIR/SHA256SUMS" expected actual file_base="${try_url%/*}" from="" file_tag sums_base
    rm -f "$checksum_file"
    # 校验和与程序必须是同一个版本：按实际下载地址里的标签去面板取
    file_tag="$(download_tag_from_base "$file_base")"
    sums_base="${PANEL_DOWNLOAD_ROOT}release/${file_tag:-agent-latest}"
    if [ "$PANEL_CHECKSUMS" = true ] && [ "${sums_base#https://}" != "$sums_base" ]; then
        if download_with_available_tools "${sums_base}/SHA256SUMS" "$checksum_file" "$sums_base" false; then
            from="面板（已验发版签名）"
        elif [ "${LAST_DOWNLOAD_HTTP_CODE:-}" = 502 ]; then
            # 面板连得上、但它确认不了这个版本的官方签名：不退回下载来源自带的校验和（防被冒充的下载来源）
            print_error "面板确认不了这个版本的官方签名，不信任这个来源的文件。"
            return 1
        else
            print_warning "没能从面板取到已验签名的校验和，改用下载来源自带的校验和（防不住被冒充的下载来源）。"
        fi
    elif [ "$PANEL_CHECKSUMS" = true ]; then
        print_warning "面板地址是 http，校验和可能在传输中被改，只核对下载来源自带的校验和。"
    fi
    if [ -z "$from" ]; then
        download_with_available_tools "${file_base}/SHA256SUMS" "$checksum_file" "$file_base" false || { print_error "无法获取 SHA256SUMS。"; return 1; }
        from="下载来源"
    fi
    expected=$(awk -v name="${try_url##*/}" '$2 == name || $2 == "*" name {print $1}' "$checksum_file")
    [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || { print_error "校验和里没有 ${try_url##*/}。"; return 1; }
    actual=$(sha256sum "$temp_file_downloaded") || return 1
    [ "${actual%% *}" = "$expected" ] || { print_error "SHA256 与${from}的校验和不一致，文件可能损坏或被改过。"; return 1; }
    check_agent_binary_runs "$temp_file_downloaded" || return 1
    print_success "Agent 已通过 SHA256（校验和来自${from}）、文件格式和执行检查。"
    return 0
}

check_agent_binary_runs() {
    local binary_file="$1" magic
    magic=$(od -An -tx1 -N4 "$binary_file" | tr -d ' \n')
    [ "$magic" = 7f454c46 ] || { print_error "Agent 文件不是 Linux ELF 二进制。"; return 1; }
    chmod 755 "$binary_file" || return 1
    timeout -k 2 10 "$binary_file" -v >/dev/null 2>&1 || { print_error "下载的 Agent 无法执行版本检查（请确认文件与本机架构 ${DOWNLOAD_ARCH:-unknown} 一致）。"; return 1; }
}

use_local_agent_binary() {
    local source_file="$1" target_file="${INSTALL_WORK_DIR}/binary" sums_file actual
    [ -f "$source_file" ] && [ -s "$source_file" ] || { print_error "找不到本地 Agent 文件或文件为空: ${source_file}"; return 1; }
    print_info "使用本地 Agent 文件，跳过下载: ${source_file}"
    cp -f "$source_file" "$target_file" || { print_error "复制本地 Agent 文件失败。"; return 1; }
    actual=$(sha256sum "$target_file") || return 1
    actual="${actual%% *}"
    # 同目录有官方 SHA256SUMS 时按内容校验（不要求保留原文件名）；没有则提示后继续。
    sums_file="$(dirname "$source_file")/SHA256SUMS"
    if [ -f "$sums_file" ]; then
        awk -v h="$actual" 'tolower($1) == tolower(h) { found = 1 } END { exit !found }' "$sums_file" \
            || { print_error "本地 Agent 文件与同目录 SHA256SUMS 不匹配，文件可能损坏或不是官方版本。"; return 1; }
        print_success "本地 Agent 文件已通过 SHA256 校验。"
    else
        print_warning "同目录没有 SHA256SUMS，跳过校验。文件 SHA256: ${actual}"
    fi
    check_agent_binary_runs "$target_file" || return 1
    print_success "本地 Agent 文件已通过文件格式和执行检查。"
}

print_local_file_install_hint() {
    local download_base="$1" file_name="$2"
    echo ""
    print_info "本机连不上 GitHub 或速度太慢时，可以手动放一份 Agent 文件再安装："
    echo "  1. 在能打开 GitHub 的电脑下载: ${download_base}/${file_name}"
    echo "     （可选）同时下载 ${download_base}/SHA256SUMS，放在同一目录可自动校验"
    echo "  2. 上传到本机，例如 /root/${file_name}"
    echo "  3. 执行: export DSTATUS_AGENT_FILE=/root/${file_name}"
    echo "  4. 再执行一次原来的安装命令（用 sudo 时写成: ... | sudo DSTATUS_AGENT_FILE=/root/${file_name} bash -s ...）"
}

register_with_server() {
    local reg_key_for_server="$1"
    local server_url_for_reg="$2"
    local enable_active_report="${3:-false}"
    local agent_port="${4:-9999}"
    local register_response=""
    local register_message=""
    local register_http_code=""
    local register_stderr=""
    local is_existing="false"
    local is_approved="true"
    local register_succeeded="false"
    local used_tls12_retry="false"
    local response_preview=""
    local stderr_preview=""
    local body_file=""
    local stderr_file=""
    local installation_id=""

    if [ -r /proc/sys/kernel/random/uuid ]; then
        installation_id="$(cat /proc/sys/kernel/random/uuid)"
    elif command -v uuidgen >/dev/null 2>&1; then
        installation_id="$(uuidgen)"
    else
        installation_id="$(date +%s)-$$"
    fi

    print_info "向服务器注册 (注册密钥: ${reg_key_for_server:0:8}...) 于: $server_url_for_reg"
    API_KEY_FROM_SERVER="" # 全局
    SID_FROM_SERVER=""   # 全局

    local register_payload
    register_payload=$(cat <<EOF
{
    "hostname": "$HOSTNAME_VAL",
    "ip": "$IP_ADDR",
    "system": "$SYSTEM_INFO_OS_NAME",
    "version": "$SYSTEM_INFO_OS_VERSION",
    "device": "$DEFAULT_NETWORK_DEVICE",
    "port": $agent_port,
    "registrationKey": "$reg_key_for_server",
    "installationId": "$installation_id",
    "enableActiveReport": $enable_active_report
}
EOF
)
    body_file="$(mktemp)"
    stderr_file="$(mktemp)"

    run_register_request "$server_url_for_reg" "$register_payload" "$body_file" "$stderr_file" "false"
    if [ "$REGISTER_REQUEST_EXIT_CODE" -eq 35 ] && [[ "$server_url_for_reg" =~ ^https:// ]]; then
        used_tls12_retry="true"
        print_warning "首次 TLS 握手失败，尝试使用 TLS 1.2 重新注册..."
        run_register_request "$server_url_for_reg" "$register_payload" "$body_file" "$stderr_file" "true"
    fi

    register_response=$(cat "$body_file" 2>/dev/null || true)
    register_stderr=$(cat "$stderr_file" 2>/dev/null || true)
    rm -f "$body_file" "$stderr_file"

    if [ "$REGISTER_REQUEST_EXIT_CODE" -ne 0 ]; then
        stderr_preview=$(normalize_single_line_text "$register_stderr")
        print_error "注册失败: $(describe_register_curl_failure "$REGISTER_REQUEST_EXIT_CODE")"
        if [ -n "$stderr_preview" ]; then
            print_error "curl 输出: $stderr_preview"
        fi
        return 1
    fi

    register_http_code="${REGISTER_REQUEST_HTTP_CODE:-000}"
    if [[ ! "$register_http_code" =~ ^2[0-9][0-9]$ ]]; then
        register_message=$(extract_json_string_field "$register_response" "message")
        response_preview=$(normalize_single_line_text "$register_response")
        if [ -n "$register_message" ]; then
            print_error "注册失败: HTTP ${register_http_code}，${register_message}"
        elif [ -n "$response_preview" ]; then
            print_error "注册失败: HTTP ${register_http_code}，响应: ${response_preview}"
        else
            print_error "注册失败: HTTP ${register_http_code}"
        fi
        return 1
    fi

    register_succeeded=$(extract_json_bool_field "$register_response" "success")
    if [ "$register_succeeded" != "true" ]; then
        register_message=$(extract_json_string_field "$register_response" "message")
        response_preview=$(normalize_single_line_text "$register_response")
        if [ -n "$register_message" ]; then
            print_error "注册失败: ${register_message}"
        elif [ -n "$response_preview" ]; then
            print_error "注册失败: ${response_preview}"
        else
            print_error "注册失败: 服务器返回了无法识别的响应"
        fi
        return 1
    fi

    API_KEY_FROM_SERVER=$(extract_json_string_field "$register_response" "apiKey")
    SID_FROM_SERVER=$(extract_json_string_field "$register_response" "sid")
    MODE_FROM_SERVER=$(extract_json_string_field "$register_response" "communicationMode")
    PORT_FROM_SERVER=$(printf '%s' "$register_response" | sed -n 's/.*"agentPort"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
    if [ -n "$MODE_FROM_SERVER" ] || [ -n "$PORT_FROM_SERVER" ]; then
        case "$MODE_FROM_SERVER" in active|passive) ;; *) print_error "注册返回的模式无效"; return 1 ;; esac
        [[ "$PORT_FROM_SERVER" =~ ^[0-9]+$ ]] && [ "$PORT_FROM_SERVER" -ge 1 ] && [ "$PORT_FROM_SERVER" -le 65535 ] || { print_error "注册返回的端口无效"; return 1; }
    fi
    is_existing=$(extract_json_bool_field "$register_response" "existing")
    is_approved=$(extract_json_bool_field "$register_response" "approved")
    register_message=$(extract_json_string_field "$register_response" "message")

    if [ -z "$API_KEY_FROM_SERVER" ]; then
        response_preview=$(normalize_single_line_text "$register_response")
        print_error "注册失败: 未能从服务器响应中获取 API 密钥"
        if [ -n "$response_preview" ]; then
            print_error "服务器响应: $response_preview"
        fi
        return 1
    fi

    if [ "$used_tls12_retry" = "true" ]; then
        print_warning "当前环境默认 TLS 协商失败，已回退到 TLS 1.2 完成注册"
    fi

    if [ "$is_existing" = "true" ]; then
        print_warning "${register_message:-该 IP 已在面板中注册，将复用已有节点配置}"
    elif [ "$is_approved" = "false" ]; then
        print_warning "${register_message:-注册成功，节点已提交，等待面板审核}"
    else
        print_success "${register_message:-注册成功，节点已自动添加}"
    fi

    print_success "API密钥: ${API_KEY_FROM_SERVER:0:8}..., Server ID: ${SID_FROM_SERVER:-未提供}"
    return 0
}

create_service_files() {
    local service_output="${INSTALL_WORK_DIR:+$INSTALL_WORK_DIR/service}"
    print_info "创建/更新服务 ${NEW_SERVICE_NAME}..."
    if [[ "$OS_FAMILY" == "alpine" ]] && command -v rc-service &> /dev/null; then
        cat > "${service_output:-/etc/init.d/${NEW_SERVICE_NAME}}" <<EOF || return 1
#!/sbin/openrc-run
name="DStatus Agent"
description="DStatus Agent Service"
command="${NEW_BINARY_PATH}"
command_args="-c ${NEW_CONFIG_FILE}"
supervisor=supervise-daemon
respawn_delay=5
respawn_max=0
output_log="/var/log/${NEW_SERVICE_NAME}.log"
error_log="/var/log/${NEW_SERVICE_NAME}.log"
depend() { need net; after firewall; }
start_pre() { checkpath --directory --owner root:root --mode 0755 "${NEW_CONFIG_DIR}"; }
EOF
        chmod +x "${service_output:-/etc/init.d/${NEW_SERVICE_NAME}}"
        [ -z "$service_output" ] || return 0
    elif [[ "$OS_FAMILY" == "openwrt" || "$OS_FAMILY" == "immortalwrt" ]] && [ -f /etc/rc.common ]; then
        cat > "${service_output:-/etc/init.d/${NEW_SERVICE_NAME}}" <<EOF || return 1
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command "${NEW_BINARY_PATH}" -c "${NEW_CONFIG_FILE}"
    procd_set_param file "${NEW_CONFIG_FILE}"
    procd_set_param respawn 5 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
        chmod +x "${service_output:-/etc/init.d/${NEW_SERVICE_NAME}}"
        [ -z "$service_output" ] || return 0
    elif command -v systemctl &> /dev/null; then
        cat > "${service_output:-/etc/systemd/system/${NEW_SERVICE_NAME}.service}" <<EOF || return 1
[Unit]
Description=DStatus Agent Service
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=${NEW_BINARY_PATH} -c ${NEW_CONFIG_FILE}
[Install]
WantedBy=multi-user.target
EOF
        [ -z "$service_output" ] || return 0
        systemctl daemon-reload
    elif [ -d /etc/init.d ]; then
        cat > "${service_output:-/etc/init.d/${NEW_SERVICE_NAME}}" <<EOF || return 1
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ${NEW_SERVICE_NAME}
# Required-Start:    \$network \$remote_fs \$syslog
# Required-Stop:     \$network \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: DStatus Agent Service
### END INIT INFO
DAEMON="${NEW_BINARY_PATH}"
DAEMON_ARGS="-c ${NEW_CONFIG_FILE}"
PIDFILE="/var/run/${NEW_SERVICE_NAME}.pid"

CHILD_PID=""
stop_child() {
    if [ -n "\${CHILD_PID:-}" ]; then
        kill "\$CHILD_PID" 2>/dev/null || true
        wait "\$CHILD_PID" 2>/dev/null || true
        CHILD_PID=""
    fi
}
supervise() {
    trap 'stop_child; exit 0' TERM INT
    while :; do
        "\$DAEMON" \$DAEMON_ARGS >>"/var/log/${NEW_SERVICE_NAME}.log" 2>&1 &
        CHILD_PID=\$!
        wait "\$CHILD_PID" 2>/dev/null || true
        CHILD_PID=""
        sleep 5 &
        CHILD_PID=\$!
        wait "\$CHILD_PID" 2>/dev/null || true
        CHILD_PID=""
    done
}
start() { echo "启动DStatus Agent..."; start-stop-daemon --start --quiet --background --make-pidfile --pidfile "\$PIDFILE" --startas "\$0" -- supervise || return 2; }
stop() { echo "停止DStatus Agent..."; start-stop-daemon --stop --quiet --retry TERM/10/KILL/5 --pidfile "\$PIDFILE" || true; start-stop-daemon --stop --quiet --retry TERM/5/KILL/5 --exec "\$DAEMON" >/dev/null 2>&1 || true; rm -f "\$PIDFILE"; }
restart() { stop; sleep 1; start; }
case "\$1" in start) start;; stop) stop;; restart) restart;; supervise) supervise;; *) echo "用法: \$0 {start|stop|restart}"; exit 1;; esac
exit 0
EOF
        chmod +x "${service_output:-/etc/init.d/${NEW_SERVICE_NAME}}"
        [ -z "$service_output" ] || return 0
        update-rc.d "${NEW_SERVICE_NAME}" defaults >/dev/null 2>&1 || chkconfig "${NEW_SERVICE_NAME}" on >/dev/null 2>&1
    else
        print_warning "无法检测到标准init系统。服务 ${NEW_SERVICE_NAME} 可能需要手动配置启动。"
    fi
}

# >>> agent-firewall.sh：与 static/sh/agent-firewall.sh 逐字一致，改那份后运行 node scripts/sync-agent-installer.js（tests/agent-installer/agent-firewall-shell.test.js 核对）
# shellcheck shell=bash
# 区域名、端口列表按空白拆成多个参数是有意的
# shellcheck disable=SC2046,SC2086
# static/sh/agent-firewall.sh
# 作用：探针端口的防火墙放行与收回。被动模式在 ufw、firewalld 开着、端口还没有规则时放行（IPv4、IPv6 一起）；主动模式、换端口、卸载时只收回本脚本加过的；其他情况不改防火墙，只打印放行办法
# 原因：权限给到最小、用完能收回、不碰用户自己的规则（TASK-978.06）；命令安装、面板 SSH 安装和两种卸载共用这一份
# 相关：down.vps.mom/scripts/install-dstatus-agent.sh（内嵌同一份，tests/agent-installer/agent-firewall-shell.test.js 核对一致）、static/sh/install-agent.sh、static/sh/remove-agent.sh、modules/servers/func.js（面板 SSH 执行前拼在脚本前面）
#
# 只定义函数，不执行。调用方开着 set -e、set -Eeuo pipefail 加 ERR 陷阱或 set -u 都能直接调用：每条可能失败的命令都有兜底，入口总是返回 0。
# 怎么认出本脚本加的：ufw 规则带注释 dstatus-agent；firewalld 端口没有注释，加过的记在探针配置目录的 firewall-rules（每行「firewalld 区域 端口」）。
# 手写 iptables/nftables 不自动改：规则顺序和持久化方式各家不同，追加的规则可能不生效或重启就丢，改为打印命令（用户 2026-11-03 同意）。

AGENT_FW_MARK=dstatus-agent
AGENT_FW_MANAGED=false

agent_fw_say() { printf '[防火墙] %s\n' "$*"; }

agent_fw_say_lines() {
    local line
    while IFS= read -r line; do
        if [ -n "$line" ]; then agent_fw_say "  $line"; fi
    done <<<"$1"
    return 0
}

# $1 是否等于后面某个参数
agent_fw_in_list() {
    local item="$1"
    shift
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "$item" ]; then return 0; fi
        shift
    done
    return 1
}

# 多行文本 $1 里有没有整行等于 $2
agent_fw_has_line() {
    local line
    while IFS= read -r line; do
        if [ "$line" = "$2" ]; then return 0; fi
    done <<<"$1"
    return 1
}

# 端口 $1 是否落在 $2 里：$2 是单个端口或范围（ufw 写 9000:10000，firewalld 写 9000-10000）
agent_fw_port_in() {
    local low high
    case "$2" in
        *[-:]*) low=${2%%[-:]*}; high=${2#*[-:]} ;;
        *) low=$2; high=$2 ;;
    esac
    case "$low" in ''|*[!0-9]*) return 1 ;; esac
    case "$high" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$1" -ge "$((10#$low))" ] && [ "$1" -le "$((10#$high))" ]; then return 0; fi
    return 1
}

# 端口 $1 是否落在逗号分隔的端口与范围列表 $2 里（如 22,9000:10000）
agent_fw_list_covers() {
    local rest="$2," item
    while [ -n "$rest" ]; do
        item=${rest%%,*}
        rest=${rest#*,}
        if agent_fw_port_in "$1" "$item"; then return 0; fi
    done
    return 1
}

# 配置文件里的探针端口（1–65535），读不到时不输出
agent_fw_config_port() {
    local value=""
    if [ -f "${1:-}" ]; then
        value=$(sed -n 's/^port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null) || value=""
        value=${value%%$'\n'*}
    fi
    case "$value" in ''|*[!0-9]*) return 0 ;; esac
    value=$((10#$value))
    if [ "$value" -ge 1 ] && [ "$value" -le 65535 ]; then printf '%s\n' "$value"; fi
    return 0
}

# ---- ufw ----

# 用户规则：`ufw show added` 里以 ufw 开头的行；读不到时返回 1
agent_fw_ufw_rules() {
    local out
    out=$(LC_ALL=C ufw show added 2>/dev/null) || return 1
    printf '%s\n' "$out" | sed -n '/^ufw /p'
    return 0
}

agent_fw_ufw_active() {
    local out
    out=$(LC_ALL=C ufw status 2>/dev/null) || return 1
    case "$out" in "Status: active"*) return 0 ;; esac
    return 1
}

# 本脚本加过放行的端口
agent_fw_ufw_own_ports() {
    printf '%s\n' "$1" | sed -n "s/^ufw allow \([0-9][0-9]*\)\/tcp comment '${AGENT_FW_MARK}'\$/\1/p"
    return 0
}

# 规则行 $1 里有没有覆盖端口 $2 的端口写法：单个、逗号列表或范围都算；不区分来源端口与目的端口，宁可多提示一条
agent_fw_ufw_line_covers() {
    local -a tokens=()
    local token
    read -r -a tokens <<<"$1" || true
    for token in ${tokens[@]+"${tokens[@]}"}; do
        token=${token%/tcp}
        case "$token" in ''|*[!0-9:,]*) continue ;; esac
        if agent_fw_list_covers "$2" "$token"; then return 0; fi
    done
    return 1
}

# 覆盖端口 $2 的入站 TCP 规则（含限定来源、拒绝、端口范围），不含本脚本那条；只管 UDP、出站、转发的不算
agent_fw_ufw_port_rules() {
    local line
    while IFS= read -r line; do
        case "$line" in
            ''|"ufw allow $2/tcp comment '${AGENT_FW_MARK}'"|"ufw route "*|*" out "*|*/udp|*"/udp "*|*"proto udp"*) continue ;;
        esac
        if agent_fw_ufw_line_covers "$line" "$2"; then printf '%s\n' "$line"; fi
    done <<<"$1"
    return 0
}

agent_fw_ufw_sync() {
    local port="$1" rules lines p families
    shift
    command -v ufw >/dev/null 2>&1 || return 0
    if ! rules=$(agent_fw_ufw_rules); then
        agent_fw_say "读不到 ufw 规则，未改动 ufw"
        return 0
    fi
    for p in $(agent_fw_ufw_own_ports "$rules"); do
        if [ "$p" = "$port" ]; then continue; fi
        if LC_ALL=C ufw --force delete allow "$p/tcp" >/dev/null 2>&1; then
            agent_fw_say "已收回本脚本在 ufw 加的放行：TCP $p"
        else
            agent_fw_say "收回 ufw 放行 TCP $p 失败，请手动执行：ufw delete allow $p/tcp"
        fi
    done
    if [ -n "$port" ] && agent_fw_ufw_active; then
        AGENT_FW_MANAGED=true
        families="IPv4、IPv6"
        if grep -qs '^IPV6=["]*no' /etc/default/ufw; then
            families="IPv4"
            agent_fw_say "ufw 没有接管 IPv6（/etc/default/ufw 里 IPV6=no），IPv6 入站由系统其他设置决定"
        fi
        lines=$(agent_fw_ufw_port_rules "$rules" "$port")
        if agent_fw_in_list "$port" $(agent_fw_ufw_own_ports "$rules"); then
            agent_fw_say "ufw 已放行 TCP ${port}（本脚本此前加的）"
        elif [ -n "$lines" ]; then
            agent_fw_say "ufw 里已有涉及 TCP $port 的规则，本次不改动；请确认它们放行了面板的 $families 访问："
            agent_fw_say_lines "$lines"
        elif LC_ALL=C ufw allow "$port/tcp" comment "$AGENT_FW_MARK" >/dev/null 2>&1; then
            agent_fw_say "已在 ufw 放行 TCP ${port}（${families}，注释 ${AGENT_FW_MARK}；卸载或改主动模式时收回）"
        else
            agent_fw_say "ufw 放行 TCP $port 失败，请手动执行：ufw allow $port/tcp"
        fi
    fi
    for p in "$@"; do
        if [ "$p" = "$port" ]; then continue; fi
        lines=$(agent_fw_ufw_port_rules "$rules" "$p")
        if [ -n "$lines" ]; then
            agent_fw_say "ufw 里还有涉及 TCP $p 的规则，不是本脚本加的（可能是旧版安装脚本或你自己加的），未改动；不再需要时手动删除："
            agent_fw_say_lines "$(printf '%s\n' "$lines" | sed 's/^ufw /ufw delete /')"
        fi
    done
    return 0
}

# ---- firewalld ----

agent_fw_firewalld_running() {
    local state
    command -v firewall-cmd >/dev/null 2>&1 || return 1
    state=$(LC_ALL=C firewall-cmd --state 2>/dev/null) || return 1
    if [ "$state" = running ]; then return 0; fi
    return 1
}

# 出网网卡：IPv4、IPv6 默认路由所在的网卡
agent_fw_default_route_devs() {
    if command -v ip >/dev/null 2>&1; then
        { ip -4 route show default 2>/dev/null || true; ip -6 route show default 2>/dev/null || true; } | sed -n 's/.* dev \([^ ]*\).*/\1/p'
    fi
    return 0
}

# 面板连进来会落到的区域：出网网卡绑定的区域；网卡没绑区域或判不出时用默认区域
agent_fw_firewalld_zones() {
    local default="$1" dev zone zones=""
    for dev in $(agent_fw_default_route_devs); do
        zone=$(LC_ALL=C firewall-cmd --get-zone-of-interface="$dev" 2>/dev/null) || zone=""
        if [ -z "$zone" ]; then zone="$default"; fi
        if [ -n "$zone" ] && ! agent_fw_in_list "$zone" $zones; then zones="$zones $zone"; fi
    done
    if [ -z "$zones" ]; then zones="$default"; fi
    printf '%s\n' $zones
    return 0
}

# 区域 $1 当前或永久配置里覆盖 TCP $2 的端口放行（单个或范围），每行一条原样写法，如 9999/tcp、9000-10000/tcp
agent_fw_firewalld_port_specs() {
    local out spec
    out=$({ LC_ALL=C firewall-cmd --zone="$1" --list-ports 2>/dev/null || true; LC_ALL=C firewall-cmd --permanent --zone="$1" --list-ports 2>/dev/null || true; } | tr ' ' '\n' | sort -u) || out=""
    while IFS= read -r spec; do
        case "$spec" in
            */tcp) if agent_fw_port_in "$2" "${spec%/tcp}"; then printf '%s\n' "$spec"; fi ;;
        esac
    done <<<"$out"
    return 0
}

# 富规则 $1 里有没有覆盖端口 $2 的 port="…"（含 to-port，单个或范围）
agent_fw_rich_rule_covers() {
    local rest="$1" pattern='port="([0-9]+([-:][0-9]+)?)"'
    while [[ $rest =~ $pattern ]]; do
        if agent_fw_port_in "$2" "${BASH_REMATCH[1]}"; then return 0; fi
        rest=${rest#*"${BASH_REMATCH[0]}"}
    done
    return 1
}

# 区域 $1 里覆盖端口 $2 的富规则（当前与永久配置）
agent_fw_firewalld_rich_rules() {
    local out rule
    out=$({ LC_ALL=C firewall-cmd --zone="$1" --list-rich-rules 2>/dev/null || true; LC_ALL=C firewall-cmd --permanent --zone="$1" --list-rich-rules 2>/dev/null || true; } | sort -u) || out=""
    while IFS= read -r rule; do
        if [ -n "$rule" ] && agent_fw_rich_rule_covers "$rule" "$2"; then printf '%s\n' "$rule"; fi
    done <<<"$out"
    return 0
}

# 当前与永久配置缺哪个补哪个；不整体重载，免得丢掉用户临时加的规则
agent_fw_firewalld_ensure() {
    if ! LC_ALL=C firewall-cmd --zone="$1" --query-port="$2/tcp" >/dev/null 2>&1; then
        LC_ALL=C firewall-cmd --zone="$1" --add-port="$2/tcp" >/dev/null 2>&1 || return 1
    fi
    if ! LC_ALL=C firewall-cmd --permanent --zone="$1" --query-port="$2/tcp" >/dev/null 2>&1; then
        LC_ALL=C firewall-cmd --permanent --zone="$1" --add-port="$2/tcp" >/dev/null 2>&1 || return 1
    fi
    return 0
}

agent_fw_firewalld_remove() {
    local failed=0
    if LC_ALL=C firewall-cmd --zone="$1" --query-port="$2/tcp" >/dev/null 2>&1; then
        LC_ALL=C firewall-cmd --zone="$1" --remove-port="$2/tcp" >/dev/null 2>&1 || failed=1
    fi
    if LC_ALL=C firewall-cmd --permanent --zone="$1" --query-port="$2/tcp" >/dev/null 2>&1; then
        LC_ALL=C firewall-cmd --permanent --zone="$1" --remove-port="$2/tcp" >/dev/null 2>&1 || failed=1
    fi
    return "$failed"
}

agent_fw_firewalld_has_source_zones() {
    local out
    out=$(LC_ALL=C firewall-cmd --get-active-zones 2>/dev/null) || return 1
    case "$out" in *"sources:"*) return 0 ;; esac
    return 1
}

# 记录文件写成「firewalld 区域 端口」行；没有记录就删掉文件
agent_fw_state_write() {
    local file="$1" content="$2"
    if [ -z "$file" ]; then return 0; fi
    if [ -z "$content" ]; then
        rm -f "$file" 2>/dev/null || true
        return 0
    fi
    if mkdir -p "$(dirname "$file")" 2>/dev/null && printf '%s' "$content" >"$file.tmp" 2>/dev/null && mv -f "$file.tmp" "$file" 2>/dev/null; then
        return 0
    fi
    rm -f "$file.tmp" 2>/dev/null || true
    agent_fw_say "没能记下本脚本加的 firewalld 放行（${file}），以后需要手动收回"
    return 0
}

agent_fw_firewalld_sync() {
    local port="$1" state_file="$2" running=false default="" zones="" kept="" kind zone p rest lines spec
    shift 2
    command -v firewall-cmd >/dev/null 2>&1 || return 0
    if agent_fw_firewalld_running; then
        running=true
        default=$(LC_ALL=C firewall-cmd --get-default-zone 2>/dev/null) || default=""
        zones=$(agent_fw_firewalld_zones "$default")
    fi
    if [ -n "$state_file" ] && [ -r "$state_file" ]; then
        while read -r kind zone p rest; do
            if [ "$kind" != firewalld ] || [ -z "$zone" ] || [ -z "$p" ]; then continue; fi
            if [ -n "$port" ] && [ "$p" = "$port" ] && { [ "$running" != true ] || agent_fw_in_list "$zone" $zones; }; then
                kept="${kept}firewalld $zone $p"$'\n'
            elif [ "$running" = true ] && agent_fw_firewalld_remove "$zone" "$p"; then
                agent_fw_say "已收回本脚本在 firewalld 区域 $zone 加的放行：TCP $p"
            else
                kept="${kept}firewalld $zone $p"$'\n'
                agent_fw_say "没能收回本脚本在 firewalld 区域 $zone 加的 TCP $p 放行（firewalld 没在运行或命令失败），请手动执行：firewall-cmd --zone=$zone --remove-port=$p/tcp; firewall-cmd --permanent --zone=$zone --remove-port=$p/tcp"
            fi
        done <"$state_file"
    fi
    if [ -n "$port" ] && [ "$running" = true ]; then
        AGENT_FW_MANAGED=true
        for zone in $zones; do
            if agent_fw_has_line "$kept" "firewalld $zone $port"; then
                if agent_fw_firewalld_ensure "$zone" "$port"; then
                    agent_fw_say "firewalld 区域 $zone 已放行 TCP ${port}（本脚本此前加的）"
                else
                    agent_fw_say "补回 firewalld 区域 $zone 的 TCP $port 放行失败，请手动执行：firewall-cmd --zone=$zone --add-port=$port/tcp; firewall-cmd --permanent --zone=$zone --add-port=$port/tcp"
                fi
            elif lines=$(agent_fw_firewalld_port_specs "$zone" "$port") && [ -n "$lines" ]; then
                agent_fw_say "firewalld 区域 $zone 里已有覆盖 TCP $port 的放行（不是本脚本加的），本次不改动：${lines//$'\n'/ }"
            else
                lines=$(agent_fw_firewalld_rich_rules "$zone" "$port")
                if [ -n "$lines" ]; then
                    agent_fw_say "firewalld 区域 $zone 里有涉及 TCP $port 的富规则，本次不改动；请确认它们放行了面板的 IPv4、IPv6 访问："
                    agent_fw_say_lines "$lines"
                elif agent_fw_firewalld_ensure "$zone" "$port"; then
                    kept="${kept}firewalld $zone $port"$'\n'
                    agent_fw_say "已在 firewalld 区域 $zone 放行 TCP ${port}（IPv4、IPv6，立即生效并写入永久配置；卸载或改主动模式时收回）"
                else
                    agent_fw_firewalld_remove "$zone" "$port" || true
                    agent_fw_say "firewalld 区域 $zone 放行 TCP $port 失败，请手动执行：firewall-cmd --zone=$zone --add-port=$port/tcp; firewall-cmd --permanent --zone=$zone --add-port=$port/tcp"
                fi
            fi
        done
        if agent_fw_firewalld_has_source_zones; then
            agent_fw_say "另有按来源地址绑定的 firewalld 区域，本脚本没有改动；面板地址落在这类区域时，请在那里放行 TCP $port"
        fi
    fi
    agent_fw_state_write "$state_file" "$kept"
    if [ "$running" = true ]; then
        if [ -n "$default" ] && ! agent_fw_in_list "$default" $zones; then zones="$zones $default"; fi
        for p in "$@"; do
            if [ "$p" = "$port" ]; then continue; fi
            for zone in $zones; do
                for spec in $(agent_fw_firewalld_port_specs "$zone" "$p"); do
                    if [ "$spec" = "$p/tcp" ] && agent_fw_has_line "$kept" "firewalld $zone $p"; then continue; fi
                    agent_fw_say "firewalld 区域 $zone 里还放行着 ${spec}，覆盖 TCP ${p}，不是本脚本加的（可能是旧版安装脚本或你自己加的），未改动；不再需要时手动删除：firewall-cmd --zone=$zone --remove-port=$spec; firewall-cmd --permanent --zone=$zone --remove-port=$spec"
                done
                lines=$(agent_fw_firewalld_rich_rules "$zone" "$p")
                if [ -n "$lines" ]; then
                    agent_fw_say "firewalld 区域 $zone 里还有涉及 TCP $p 的富规则，未改动；不再需要时用 firewall-cmd --zone=$zone --remove-rich-rule='<规则>' 删除（加 --permanent 删永久配置）："
                    agent_fw_say_lines "$lines"
                fi
            done
        done
    fi
    return 0
}

# ---- 旧版留下的手写 iptables 放行：只列出，不删（分不清是不是用户自己加的） ----

agent_fw_iptables_leftovers() {
    local port="$1" p cmd found=false
    shift
    for p in "$@"; do
        if [ "$p" = "$port" ]; then continue; fi
        for cmd in iptables ip6tables; do
            if command -v "$cmd" >/dev/null 2>&1 && "$cmd" -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1; then
                found=true
                agent_fw_say "$cmd 里还有放行 TCP $p 的规则，不是本脚本加的（可能是旧版安装脚本或你自己加的），未改动；不再需要时手动删除：$cmd -D INPUT -p tcp --dport $p -j ACCEPT"
            fi
        done
    done
    if [ "$found" = true ] && [ -f /etc/local.d/iptables.start ]; then
        agent_fw_say "这台机器开机时会从 /etc/iptables/rules.v4 恢复 iptables 规则，删完请重新保存：iptables-save > /etc/iptables/rules.v4"
    fi
    return 0
}

agent_fw_hint() {
    local port="$1"
    if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
        agent_fw_say "被动模式：面板要连本机 TCP ${port}；开着 macOS 防火墙时，在「系统设置 → 网络 → 防火墙 → 选项」里允许 dstatus-agent 接收传入连接"
    elif [ "$(id -u 2>/dev/null || echo 1)" != 0 ]; then
        agent_fw_say "被动模式：面板要连本机 TCP ${port}；当前不是 root，未改动防火墙，请让管理员放行（IPv4、IPv6）"
    elif [ "$AGENT_FW_MANAGED" != true ]; then
        agent_fw_say "被动模式：面板要连本机 TCP ${port}；本机没有在用的 ufw 或 firewalld，未改动防火墙。另用 iptables、nftables 拦入站的话，请自行放行："
        agent_fw_say "  iptables -I INPUT -p tcp --dport $port -j ACCEPT"
        agent_fw_say "  ip6tables -I INPUT -p tcp --dport $port -j ACCEPT"
    fi
    agent_fw_say "云服务器还要在控制台安全组放行 TCP ${port}（IPv6 规则一般要单独加）"
    return 0
}

# agent_firewall_sync <端口> <记录文件> [以前用过的端口...]
#   端口非空：被动模式，放行这个端口，收回本脚本在其他端口加过的
#   端口为空：主动模式或卸载，收回本脚本加过的全部
#   以前用过的端口：收回之后那里还有别的放行（旧版安装脚本或用户自己加的）就列出来，请用户核对
# 只有 root 会改防火墙；其他情况只打印提示。安装提交成功之后再调用：失败回滚时旧端口照旧能连。
agent_firewall_sync() {
    local port="${1:-}" state_file="${2:-}"
    if [ "$#" -ge 2 ]; then shift 2; else set --; fi
    AGENT_FW_MANAGED=false
    if [ "$(id -u 2>/dev/null || echo 1)" = 0 ]; then
        agent_fw_ufw_sync "$port" "$@"
        agent_fw_firewalld_sync "$port" "$state_file" "$@"
        agent_fw_iptables_leftovers "$port" "$@"
    fi
    if [ -n "$port" ]; then agent_fw_hint "$port"; fi
    return 0
}
# <<< agent-firewall.sh

# 防火墙在安装提交成功之后才放行或收回：失败回滚时旧端口照旧能连；这一步出错只给提示，不让安装失败
sync_agent_firewall() {
    local active="$1" port="$2" previous_port="${3:-}"
    [ "$active" != "true" ] || port=""
    agent_firewall_sync "$port" "${NEW_CONFIG_DIR}/firewall-rules" $previous_port || true
}

# 安装前配置里的端口：换端口或改主动模式后，据此核对旧端口上还剩的放行
installed_agent_port() {
    local port
    port="$(agent_fw_config_port "$NEW_CONFIG_FILE")"
    [ -n "$port" ] || port="$(agent_fw_config_port "$OLD_CONFIG_FILE")"
    printf "%s" "$port"
}

service_started_successfully() {
    if command -v systemctl &> /dev/null; then
        systemctl is-active --quiet "${NEW_SERVICE_NAME}"
        return $?
    fi
    if [[ "$OS_FAMILY" == "openwrt" || "$OS_FAMILY" == "immortalwrt" ]] && [ -f "/etc/init.d/${NEW_SERVICE_NAME}" ]; then
        /etc/init.d/"${NEW_SERVICE_NAME}" running >/dev/null 2>&1 || \
        pgrep -f "${NEW_AGENT_BINARY_NAME} -c ${NEW_CONFIG_FILE}" >/dev/null || \
        pgrep -f "dstatus -c ${NEW_CONFIG_FILE}" >/dev/null || \
        pgrep -f "${OLD_AGENT_BINARY_NAME} -c ${NEW_CONFIG_FILE}" >/dev/null
        return $?
    fi
    if [[ "$OS_FAMILY" == "alpine" ]] && command -v rc-service &> /dev/null; then
        rc-service "${NEW_SERVICE_NAME}" status >/dev/null 2>&1
        return $?
    fi
    if [ -f "/etc/init.d/${NEW_SERVICE_NAME}" ]; then
        pgrep -f "(dstatus-agent|dstatus|neko-status) -c ${NEW_CONFIG_FILE}" > /dev/null
        return $?
    fi
    return 1
}

start_new_service() {
    if [ "$INSTALL_SWITCH_STARTED" = true ]; then
        manage_install_service start "$NEW_SERVICE_NAME" || return 1
        verify_running_agent "$NEW_SERVICE_NAME" "$NEW_BINARY_PATH" "$NEW_CONFIG_FILE" true || { print_error "Agent 未能持续运行。"; return 1; }
        print_success "Agent 已持续运行，等待面板回连核验。"
        return 0
    fi
    print_info "启动服务 ${NEW_SERVICE_NAME}..."
    if [[ "$OS_FAMILY" == "alpine" ]] && command -v rc-service &> /dev/null; then
        rc-service "${NEW_SERVICE_NAME}" start && rc-update add "${NEW_SERVICE_NAME}" default >/dev/null 2>&1
    elif [[ "$OS_FAMILY" == "openwrt" || "$OS_FAMILY" == "immortalwrt" ]] && [ -f "/etc/init.d/${NEW_SERVICE_NAME}" ]; then
        /etc/init.d/"${NEW_SERVICE_NAME}" enable >/dev/null 2>&1 || true
        /etc/init.d/"${NEW_SERVICE_NAME}" start || true
    elif command -v systemctl &> /dev/null; then
        systemctl enable "${NEW_SERVICE_NAME}" >/dev/null 2>&1 || true
        systemctl start "${NEW_SERVICE_NAME}" || true
    elif [ -f "/etc/init.d/${NEW_SERVICE_NAME}" ]; then
        "/etc/init.d/${NEW_SERVICE_NAME}" start
    fi

    sleep 2
    if service_started_successfully; then
        print_success "服务 ${NEW_SERVICE_NAME} 已启动，等待节点回连。"
    else
        print_error "服务 ${NEW_SERVICE_NAME} 启动失败。"
        if command -v systemctl &> /dev/null; then print_error "  查看日志: sudo journalctl -u ${NEW_SERVICE_NAME} -f -n 50";
        elif [[ "$OS_FAMILY" == "alpine" ]]; then print_error "  查看日志: sudo tail -n 50 /var/log/messages (或相关日志)"; fi
        return 1
    fi
}

apply_openrc_service_repair() {
    local binary_sha_before="$1"
    local config_sha_before="$2"
    local binary_sha_after
    local config_sha_after
    local attempt

    rc-service "${NEW_SERVICE_NAME}" stop || true
    if agent_process_id "$NEW_BINARY_PATH" >/dev/null; then
        print_error "原 Agent 没有停止，拒绝覆盖服务文件。"
        return 1
    fi

    rc-service "${NEW_SERVICE_NAME}" zap >/dev/null 2>&1 || true
    create_service_files || return 1
    grep -Fxq "supervisor=supervise-daemon" "/etc/init.d/${NEW_SERVICE_NAME}" || return 1
    grep -Fxq "respawn_delay=5" "/etc/init.d/${NEW_SERVICE_NAME}" || return 1
    grep -Fxq "respawn_max=0" "/etc/init.d/${NEW_SERVICE_NAME}" || return 1
    rc-update add "${NEW_SERVICE_NAME}" default >/dev/null 2>&1 || return 1
    rc-service "${NEW_SERVICE_NAME}" start || return 1

    for attempt in {1..10}; do
        if rc-service "${NEW_SERVICE_NAME}" status >/dev/null 2>&1; then break; fi
        sleep 1
    done
    rc-service "${NEW_SERVICE_NAME}" status >/dev/null 2>&1 || return 1
    binary_sha_after="$(sha256sum "$NEW_BINARY_PATH")" || return 1
    config_sha_after="$(sha256sum "$NEW_CONFIG_FILE")" || return 1
    [ "$binary_sha_before" = "${binary_sha_after%% *}" ] || return 1
    [ "$config_sha_before" = "${config_sha_after%% *}" ] || return 1
}

rollback_openrc_service_repair() {
    local backup_file="$1"
    local service_file="/etc/init.d/${NEW_SERVICE_NAME}"

    rc-service "${NEW_SERVICE_NAME}" stop >/dev/null 2>&1 || true
    if ! cp -p "$backup_file" "$service_file"; then
        print_error "恢复旧服务文件失败，请立即人工检查 ${service_file}。"
        return 1
    fi
    chmod +x "$service_file" || return 1
    rc-service "${NEW_SERVICE_NAME}" zap >/dev/null 2>&1 || true
    if ! rc-service "${NEW_SERVICE_NAME}" start; then
        print_error "旧服务文件已恢复，但 Agent 重新启动失败。"
        return 1
    fi
    print_warning "修复失败，已恢复旧服务文件并重新启动 Agent。"
}

process_openrc_repair() {
    local service_file="/etc/init.d/${NEW_SERVICE_NAME}"
    local backup_file
    local binary_sha_before
    local config_sha_before
    local repair_status=0

    check_root
    get_system_info
    [ "$OS_FAMILY" = "alpine" ] || die "repair-openrc 仅支持 Alpine/OpenRC。"
    command -v rc-service >/dev/null 2>&1 || die "未检测到 rc-service。"
    command -v supervise-daemon >/dev/null 2>&1 || die "当前 OpenRC 缺少 supervise-daemon。"
    command -v sha256sum >/dev/null 2>&1 || die "未检测到 sha256sum。"
    [ -x "$NEW_BINARY_PATH" ] || die "未找到现有 Agent: ${NEW_BINARY_PATH}"
    [ -f "$NEW_CONFIG_FILE" ] || die "未找到现有配置: ${NEW_CONFIG_FILE}"
    [ -f "$service_file" ] || die "未找到现有 OpenRC 服务: ${service_file}"

    backup_file="$(mktemp "/tmp/${NEW_SERVICE_NAME}-openrc.XXXXXX")" || die "创建服务备份失败。"
    if ! cp -p "$service_file" "$backup_file"; then
        rm "$backup_file"
        die "备份现有服务文件失败。"
    fi
    binary_sha_before="$(sha256sum "$NEW_BINARY_PATH")" || {
        rm "$backup_file"
        die "读取 Agent 哈希失败。"
    }
    binary_sha_before="${binary_sha_before%% *}"
    config_sha_before="$(sha256sum "$NEW_CONFIG_FILE")" || {
        rm "$backup_file"
        die "读取配置哈希失败。"
    }
    config_sha_before="${config_sha_before%% *}"

    print_info "只修复 OpenRC 服务守护；不会修改 Agent 二进制、配置或节点注册。"
    apply_openrc_service_repair "$binary_sha_before" "$config_sha_before" || repair_status=$?
    if [ "$repair_status" -ne 0 ]; then
        rollback_openrc_service_repair "$backup_file" || true
        rm "$backup_file"
        return "$repair_status"
    fi

    rm "$backup_file"
    print_success "OpenRC 服务守护修复完成，Agent 已重新启动。"
}

# --- 检查是否需要注册 ---
# 命令里的面板地址与本机配置不同时，用本机身份问命令里的面板认不认（握手接口只核对、不写数据）。
# 输出 recognized / unknown / key_mismatch / undetermined；老面板没有该接口（接口不存在）、网络不通都算 undetermined。
probe_identity_on_panel() {
    local panel_url="${1%/}" sid="$2" key="$3" body_file="" code=""
    command -v curl >/dev/null 2>&1 || { echo undetermined; return 0; }
    [[ "$sid" =~ ^[A-Za-z0-9._-]+$ ]] || { echo undetermined; return 0; }
    body_file="$(mktemp)" || { echo undetermined; return 0; }
    code="$(curl -s -m 10 -L --post301 --post302 --post303 -o "$body_file" -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' -H "key: ${key}" \
        --data "{\"sid\":\"${sid}\"}" "${panel_url}/api/agent/control/handshake" 2>/dev/null)" || code=""
    case "$code" in
        200) grep -q '"success"[[:space:]]*:[[:space:]]*true' "$body_file" && echo recognized || echo undetermined ;;
        401) grep -q 'E_UNAUTHORIZED' "$body_file" && echo key_mismatch || echo undetermined ;;
        404) grep -q 'E_NOT_FOUND' "$body_file" && grep -q '未知服务器' "$body_file" && echo unknown || echo undetermined ;;
        *) echo undetermined ;;
    esac
    rm -f "$body_file"
}

determine_registration_needed() {
    local final_api_key=""
    local final_server_id=""
    local config_source=""
    local selected_config=""
    local config_server_url=""
    local new_server_url="$1"

    print_info "--- 检查现有配置 ---"

    # 优先检查新版配置
    if [ -f "$NEW_CONFIG_FILE" ]; then
        final_api_key=$(grep "^key:" "$NEW_CONFIG_FILE" | cut -d' ' -f2 | tr -d '"' | tr -d "'")
        final_server_id=$(grep "^server_id:" "$NEW_CONFIG_FILE" | cut -d' ' -f2 | tr -d '"' | tr -d "'")
        config_server_url=$(grep "^report_server:" "$NEW_CONFIG_FILE" | cut -d' ' -f2 | tr -d '"' | tr -d "'")
        if [ -n "$final_api_key" ] || [ -n "$final_server_id" ]; then
            config_source="当前 ${NEW_AGENT_BINARY_NAME} 配置"
            selected_config="$NEW_CONFIG_FILE"
        fi
    fi

    # 如果新版没有，检查旧版配置（迁移）
    if [ -z "$final_api_key" ] && [ -z "$final_server_id" ] && [ -f "$OLD_CONFIG_FILE" ]; then
        final_api_key=$(grep "^key:" "$OLD_CONFIG_FILE" | cut -d' ' -f2 | tr -d '"' | tr -d "'")
        final_server_id=$(grep "^server_id:" "$OLD_CONFIG_FILE" | cut -d' ' -f2 | tr -d '"' | tr -d "'")
        config_server_url=$(grep "^report_server:" "$OLD_CONFIG_FILE" | cut -d' ' -f2 | tr -d '"' | tr -d "'")
        if [ -n "$final_api_key" ]; then
            config_source="旧版 ${OLD_AGENT_BINARY_NAME} 迁移"
            selected_config="$OLD_CONFIG_FILE"
        fi
    fi

    # 智能判断是否需要重新注册
    if [ -n "$final_api_key" ] && [ -n "$final_server_id" ]; then
        # 标准化URL对比（移除尾部斜杠）
        config_server_url=${config_server_url%/}
        new_server_url=${new_server_url%/}

        # 换了面板地址：命令里的面板不认识本机节点时改为注册新节点，否则节点会一直连旧面板、新面板看不到
        if [[ "$config_server_url" =~ ^https?://[^/[:space:]]+ ]] && [[ "$new_server_url" =~ ^https?://[^/[:space:]]+ ]] \
            && [ "$config_server_url" != "$new_server_url" ]; then
            case "$(probe_identity_on_panel "$new_server_url" "$final_server_id" "$final_api_key")" in
                recognized)
                    print_info "命令中的面板认得本机节点，保留节点身份。"
                    ;;
                unknown)
                    local identity_backup
                    identity_backup="$(dirname "$NEW_CONFIG_FILE")/config.yaml.backup-$(date +%Y%m%d-%H%M%S)"
                    mkdir -p "$(dirname "$NEW_CONFIG_FILE")" && cp -p "$selected_config" "$identity_backup" \
                        || die "备份原配置失败，安装中止，未做任何改动。"
                    print_warning "本机节点（原面板 ${config_server_url}）在命令中的面板里不存在，将作为新节点注册。"
                    print_info "原配置已备份到: ${identity_backup}"
                    FINAL_API_KEY=""
                    FINAL_SERVER_ID=""
                    NEED_REGISTER=true
                    return 0
                    ;;
                key_mismatch)
                    die "本机节点在命令中的面板里存在，但通讯密钥不一致。请在面板该节点页复制「重装命令」执行；本次未做任何改动。"
                    ;;
                *)
                    print_warning "无法确认命令中的面板是否认得本机节点，保留原节点身份和上报地址 ${config_server_url}。"
                    ;;
            esac
        fi

        # 保留现有配置
        print_info "检测到有效配置 (${config_source}), API密钥: ${final_api_key:0:8}..."
        print_info "保持现有配置，跳过注册流程"
        if [[ ! "$config_server_url" =~ ^https?://[^/[:space:]]+ ]]; then
            [[ "$new_server_url" =~ ^https?://[^/[:space:]]+ ]] || die "现有面板地址无效，命令中的上报地址也无效，请从面板重新复制安装/更新脚本。"
            config_server_url="$new_server_url"
            print_info "现有上报地址无效，已采用命令中的上报地址"
        fi
        FINAL_REPORT_SERVER="$config_server_url"
        FINAL_API_KEY="$final_api_key"
        FINAL_SERVER_ID="$final_server_id"
        local existing_config="$selected_config"
        EXISTING_REPORT_ENABLED=$(sed -n 's/^report_enabled:[[:space:]]*//p' "$existing_config" | tr -d '\"\047\r')
        EXISTING_AGENT_PORT=$(sed -n 's/^port:[[:space:]]*//p' "$existing_config" | tr -d '\"\047\r')
        case "$EXISTING_REPORT_ENABLED" in true|false) ;; *) die "现有配置的模式不明确，请使用面板节点重装命令恢复。" ;; esac
        [[ "$EXISTING_AGENT_PORT" =~ ^[0-9]+$ ]] && [ "$EXISTING_AGENT_PORT" -ge 1 ] && [ "$EXISTING_AGENT_PORT" -le 65535 ] || die "现有配置端口无效，请使用面板节点重装命令恢复。"
        NEED_REGISTER=false
    elif [ -n "$final_api_key" ] || [ -n "$final_server_id" ]; then
        die "现有节点身份不完整，请使用面板中该节点的重装命令恢复；不会自动创建重复节点。"
    else
        print_info "未检测到有效配置，将进行注册获取新密钥"
        FINAL_API_KEY=""
        FINAL_SERVER_ID=""
        NEED_REGISTER=true
    fi
}

# --- 智能配置文件创建 ---
create_optimized_config() {
    local api_key="$1"
    local server_url="$2" 
    local server_id="$3"
    local enable_active_report="${4:-false}"
    local agent_port="${5:-9999}"
    local explicit_report_interval="${6:-}"
    local explicit_task_poll_enabled="${7:-}"
    local explicit_task_poll_interval="${8:-}"
    local explicit_task_poll_max_batch="${9:-}"
    local explicit_auto_upgrade_enabled="${10:-}"

    normalize_bool_value() {
        local raw="$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')"
        case "$raw" in
            1|true|yes|on) echo "true" ;;
            0|false|no|off) echo "false" ;;
            *) echo "false" ;;
        esac
    }

    normalize_int_value() {
        local raw="${1:-}"
        local fallback="${2:-0}"
        local min="${3:-0}"
        if [[ "$raw" =~ ^[0-9]+$ ]]; then
            if [ "$raw" -lt "$min" ]; then
                echo "$fallback"
            else
                echo "$raw"
            fi
        else
            echo "$fallback"
        fi
    }
    
    # 读取现有配置的其他参数（如果存在）
    local existing_port="$agent_port"
    local existing_debug="false"
    local existing_report_enabled="$enable_active_report"
    local existing_report_interval="$(normalize_int_value "$explicit_report_interval" "2" "1")"
    local existing_task_poll_enabled="true"
    local existing_task_poll_interval="$(normalize_int_value "$explicit_task_poll_interval" "10" "1")"
    local existing_task_poll_max_batch="$(normalize_int_value "$explicit_task_poll_max_batch" "5" "1")"
    local existing_auto_upgrade_enabled="$(normalize_bool_value "$explicit_auto_upgrade_enabled")"
    
    # 如果启用主动上报，设置相应配置
    if [ "$enable_active_report" = "true" ]; then
        print_info "配置Agent主动上报: 每${existing_report_interval}秒上报一次（主动模式）"
        existing_report_enabled="true"
        existing_task_poll_enabled="$(normalize_bool_value "${explicit_task_poll_enabled:-true}")"
    elif [ "$agent_port" != "9999" ]; then
        print_info "配置Agent监听端口: $agent_port"
    fi
    
    # 尝试从现有配置读取设置（但端口使用用户指定的）
    if [ -f "$NEW_CONFIG_FILE" ]; then
        # 端口使用用户指定的，不从现有配置读取
        existing_debug=$(grep "^debug:" "$NEW_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr -d '"' | tr -d "'" || echo "false")
        if [ -z "$explicit_report_interval" ]; then
            existing_report_interval=$(grep "^report_interval:" "$NEW_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr -d '"' | tr -d "'" || echo "2")
        fi
        if [ -z "$explicit_task_poll_enabled" ]; then
            existing_task_poll_enabled=$(grep "^task_poll_enabled:" "$NEW_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr 'A-Z' 'a-z' | tr -d '"' | tr -d "'" || echo "$existing_task_poll_enabled")
        fi
        if [ -z "$explicit_task_poll_interval" ]; then
            existing_task_poll_interval=$(grep "^task_poll_interval:" "$NEW_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr -d '"' | tr -d "'" || echo "$existing_task_poll_interval")
        fi
        if [ -z "$explicit_task_poll_max_batch" ]; then
            existing_task_poll_max_batch=$(grep "^task_poll_max_batch:" "$NEW_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr -d '"' | tr -d "'" || echo "$existing_task_poll_max_batch")
        fi
        if [ -z "$explicit_auto_upgrade_enabled" ]; then
            existing_auto_upgrade_enabled=$(grep "^auto_upgrade_enabled:" "$NEW_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr 'A-Z' 'a-z' | tr -d '"' | tr -d "'" || echo "$existing_auto_upgrade_enabled")
        fi
    elif [ -f "$OLD_CONFIG_FILE" ]; then
        # 端口使用用户指定的，不从现有配置读取
        existing_debug=$(grep "^debug:" "$OLD_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr -d '"' | tr -d "'" || echo "false")
        if [ -z "$explicit_report_interval" ]; then
            existing_report_interval=$(grep "^report_interval:" "$OLD_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr -d '"' | tr -d "'" || echo "2")
        fi
        if [ -z "$explicit_task_poll_enabled" ]; then
            existing_task_poll_enabled=$(grep "^task_poll_enabled:" "$OLD_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr 'A-Z' 'a-z' | tr -d '"' | tr -d "'" || echo "$existing_task_poll_enabled")
        fi
        if [ -z "$explicit_task_poll_interval" ]; then
            existing_task_poll_interval=$(grep "^task_poll_interval:" "$OLD_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr -d '"' | tr -d "'" || echo "$existing_task_poll_interval")
        fi
        if [ -z "$explicit_task_poll_max_batch" ]; then
            existing_task_poll_max_batch=$(grep "^task_poll_max_batch:" "$OLD_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr -d '"' | tr -d "'" || echo "$existing_task_poll_max_batch")
        fi
        if [ -z "$explicit_auto_upgrade_enabled" ]; then
            existing_auto_upgrade_enabled=$(grep "^auto_upgrade_enabled:" "$OLD_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2 | tr 'A-Z' 'a-z' | tr -d '"' | tr -d "'" || echo "$existing_auto_upgrade_enabled")
        fi
    fi

    existing_report_enabled="$(normalize_bool_value "$existing_report_enabled")"
    # 配置同步在主动和被动模式均需要；重装不能继承旧版关闭的控制通道。
    existing_task_poll_enabled="true"
    existing_task_poll_interval="$(normalize_int_value "$existing_task_poll_interval" "10" "1")"
    existing_task_poll_max_batch="$(normalize_int_value "$existing_task_poll_max_batch" "5" "1")"
    existing_auto_upgrade_enabled="$(normalize_bool_value "$existing_auto_upgrade_enabled")"

    local local_source_config="" local_lines
    if [ -f "$NEW_CONFIG_FILE" ]; then local_source_config="$NEW_CONFIG_FILE"; elif [ -f "$OLD_CONFIG_FILE" ]; then local_source_config="$OLD_CONFIG_FILE"; fi
    local_lines=$(agent_local_config_lines "$local_source_config") || return 1

    local config_output="${INSTALL_WORK_DIR:+$INSTALL_WORK_DIR/config}"
    config_output="${config_output:-$NEW_CONFIG_FILE}"
    mkdir -p "$(dirname "$config_output")"
    print_info "准备配置文件..."
    local config_tmp
    config_tmp=$(mktemp "${config_output}.XXXXXX")
    chmod 600 "$config_tmp"
    cat > "$config_tmp" <<EOF || return 1
# DStatus Agent Configuration  
key: "${api_key}"
port: ${existing_port}
debug: ${existing_debug}

# 主动上报配置（智能补全）
report_enabled: ${existing_report_enabled}
report_server: "${server_url}"
report_interval: ${existing_report_interval}
report_server_key: "${api_key}"
server_id: "${server_id}"
# 任务轮询配置（主动模式必须）
task_poll_enabled: ${existing_task_poll_enabled}
task_poll_interval: ${existing_task_poll_interval}
task_poll_max_batch: ${existing_task_poll_max_batch}
task_poll_mock: false
auto_upgrade_enabled: ${existing_auto_upgrade_enabled}
EOF
    if [ -n "$local_lines" ]; then
        printf '# 本机设置：只能在这台机器上改（sudo dsa），面板只能远程关闭「允许面板运行脚本」\n%s\n' "$local_lines" >> "$config_tmp" || return 1
    fi
    mv "$config_tmp" "$config_output"
}

process_reinstall_from_env() {
    local api_key="${DSTATUS_API_KEY:-}"
    local server_id="${DSTATUS_SERVER_ID:-}"
    local report_server="${DSTATUS_REPORT_SERVER:-}"
    local agent_mode="$(printf '%s' "${DSTATUS_AGENT_MODE:-}" | tr 'A-Z' 'a-z')"
    local report_enabled="${DSTATUS_REPORT_ENABLED:-}"
    local report_interval="${DSTATUS_REPORT_INTERVAL:-}"
    local task_poll_enabled="${DSTATUS_TASK_POLL_ENABLED:-}"
    local task_poll_interval="${DSTATUS_TASK_POLL_INTERVAL:-}"
    local task_poll_max_batch="${DSTATUS_TASK_POLL_MAX_BATCH:-}"
    local auto_upgrade_enabled="${DSTATUS_AUTO_UPGRADE_ENABLED:-}"
    local agent_port="${DSTATUS_AGENT_PORT:-9999}"

    report_server=${report_server%/}

    check_root
    get_system_info
    detect_architecture
    ensure_download_tool_available

    if [ -z "$api_key" ]; then die "缺少 DSTATUS_API_KEY。"; fi
    if [ -z "$server_id" ]; then die "缺少 DSTATUS_SERVER_ID。"; fi
    if [ -z "$report_server" ]; then die "缺少 DSTATUS_REPORT_SERVER。"; fi
    if [[ ! "$report_server" =~ ^https?:// ]]; then die "DSTATUS_REPORT_SERVER 格式无效 (应以 http(s):// 开头)。"; fi

    if [ "$agent_mode" = "active" ] || [ "$agent_mode" = "active-report" ]; then
        report_enabled="true"
        if [ -z "$task_poll_enabled" ]; then
            task_poll_enabled="true"
        fi
        print_info "使用当前节点主动模式配置执行重装"
    else
        report_enabled="${report_enabled:-false}"
        if [ -z "$task_poll_enabled" ]; then
            task_poll_enabled="true"
        fi
        print_info "使用当前节点被动模式配置执行重装"
    fi

    local previous_port
    previous_port="$(installed_agent_port)"
    begin_install_transaction

    PANEL_AGENT_KEY="$api_key"
    PANEL_AGENT_SID="$server_id"
    if ! download_agent_binary "$report_server"; then
        die "${NEW_AGENT_BINARY_NAME} 下载失败。"
    fi

    FINAL_API_KEY="$api_key"
    FINAL_SERVER_ID="$server_id"

    create_optimized_config \
        "$FINAL_API_KEY" \
        "$report_server" \
        "$FINAL_SERVER_ID" \
        "$report_enabled" \
        "$agent_port" \
        "$report_interval" \
        "$task_poll_enabled" \
        "$task_poll_interval" \
        "$task_poll_max_batch" \
        "$auto_upgrade_enabled"

    create_service_files
    switch_installation
    start_new_service
    commit_installation
    sync_agent_firewall "$report_enabled" "$agent_port" "$previous_port"
    print_success "基于当前节点配置的重装完成。"
    print_agent_management_summary
}

# --- 主安装/更新流程（优化版）---
process_installation() {
    local user_input_reg_key="$1"
    local user_input_server_url="$2"
    local enable_active_report="${3:-false}"
    local agent_port="${4:-9999}"
    user_input_server_url=${user_input_server_url%/}
    PANEL_ENROLL_TOKEN="$user_input_reg_key"

    check_root
    get_system_info
    detect_architecture
    # 特殊网络装不了系统依赖（软件源也在外网）；命令本身就是用 curl 取的脚本，只核对下载工具在不在
    if [ "$DOWNLOAD_VIA_PANEL" = true ] || [ -e "$NEW_BINARY_PATH" ] || [ -e "$OLD_BINARY_PATH" ] || [ -f "$NEW_CONFIG_FILE" ] || [ -f "$OLD_CONFIG_FILE" ]; then
        ensure_download_tool_available
    else
        install_dependencies
    fi

    # 简化的配置检查（移除复杂交互逻辑）
    determine_registration_needed "$user_input_server_url"
    if [ "$NEED_REGISTER" = false ]; then
        user_input_server_url="$FINAL_REPORT_SERVER"
        # 已有身份的重装：授权可能已过期，经面板下载时同时带节点密钥
        PANEL_AGENT_KEY="$FINAL_API_KEY"
        PANEL_AGENT_SID="$FINAL_SERVER_ID"
    fi

    local previous_port
    previous_port="$(installed_agent_port)"
    begin_install_transaction

    if ! download_agent_binary "$user_input_server_url"; then
        die "${NEW_AGENT_BINARY_NAME} 下载失败。"
    fi

    # 条件注册（仅在需要时）
    if [ "$NEED_REGISTER" = true ]; then
        if ! register_with_server "$user_input_reg_key" "$user_input_server_url" "$enable_active_report" "$agent_port"; then
            die "注册失败。"
        fi
        FINAL_API_KEY="$API_KEY_FROM_SERVER"
        FINAL_SERVER_ID="$SID_FROM_SERVER"
        if [ -n "$MODE_FROM_SERVER" ]; then
            enable_active_report=false
            [ "$MODE_FROM_SERVER" != "active" ] || enable_active_report=true
            agent_port="$PORT_FROM_SERVER"
        fi
        print_info "注册成功，获得新的API密钥和Server ID"
    else
        print_info "跳过注册，使用现有配置: API密钥 ${FINAL_API_KEY:0:8}..., Server ID: ${FINAL_SERVER_ID:-未设置}"
        enable_active_report="$EXISTING_REPORT_ENABLED"
        agent_port="$EXISTING_AGENT_PORT"
    fi

    if [ -z "$FINAL_API_KEY" ]; then die "最终API密钥为空，无法继续。"; fi

    # 使用优化的配置创建函数
    create_optimized_config "$FINAL_API_KEY" "$user_input_server_url" "$FINAL_SERVER_ID" "$enable_active_report" "$agent_port"
    create_service_files
    switch_installation
    start_new_service
    commit_installation
    cleanup_old_version_files
    sync_agent_firewall "$enable_active_report" "$agent_port" "$previous_port"

    print_success "--------------------------------------------------"
    print_success "本机安装完成，服务已启动；节点接入和配置生效请在面板核验。"
    print_success "--------------------------------------------------"
    print_agent_management_summary
    print_info "${BLUE}配置文件:${NC} ${NEW_CONFIG_FILE}"
    print_success "--------------------------------------------------"
    print_warning "${YELLOW}卸载说明:${NC}"
    print_info "  ${BLUE}提示:${NC} 重新安装时会保留现有配置（API密钥和Server ID不变）。"
    print_info "  如需全新安装（获取新的API密钥），请先执行卸载命令，再重新安装。"
    print_warning "  要卸载 ${NEW_AGENT_BINARY_NAME} 及所有历史版本，运行 sudo dsa uninstall --yes，或："
    echo -e "    ${GREEN}curl -fsSL https://down.vps.mom/scripts/install-dstatus-agent.sh | sudo bash -s -- uninstall${NC}"
    print_success "--------------------------------------------------"

}

# --- 卸载函数（兼容所有历史版本）---
process_uninstallation() {
    check_root

    print_warning "开始卸载 DStatus Agent（包括所有历史版本）..."
    local summary_success=0
    local summary_skip=0
    local summary_fail=0
    local detected_ports=()

    mark_success() {
        summary_success=$((summary_success + 1))
        print_success "$1"
    }

    mark_skip() {
        summary_skip=$((summary_skip + 1))
        print_info "$1"
    }

    mark_fail() {
        summary_fail=$((summary_fail + 1))
        print_warning "$1"
    }

    add_port_if_valid() {
        local raw_port="$1"
        case "$raw_port" in
            ''|*[!0-9]*) return 0 ;;
        esac
        if [ "$raw_port" -lt 1 ] || [ "$raw_port" -gt 65535 ]; then
            return 0
        fi
        for existing_port in "${detected_ports[@]}"; do
            [ "$existing_port" = "$raw_port" ] && return 0
        done
        detected_ports+=("$raw_port")
    }

    collect_port_from_config() {
        local config_path="$1"
        [ -f "$config_path" ] || return 0
        local extracted
        extracted=$(grep -E '^port:[[:space:]]*[0-9]+' "$config_path" 2>/dev/null | head -n1 | sed -E 's/^port:[[:space:]]*([0-9]+).*$/\1/' || true)
        add_port_if_valid "$extracted"
    }

    remove_file_if_exists() {
        local target_path="$1"
        local description="$2"
        if [ -e "$target_path" ] || [ -L "$target_path" ]; then
            if rm -f "$target_path" 2>/dev/null; then
                mark_success "已删除 ${description}: ${target_path}"
            else
                mark_fail "删除失败 ${description}: ${target_path}"
            fi
        else
            mark_skip "未找到 ${description}: ${target_path}"
        fi
    }

    remove_dir_if_exists() {
        local target_path="$1"
        local description="$2"
        if [ -d "$target_path" ]; then
            if rm -rf "$target_path" 2>/dev/null; then
                mark_success "已删除 ${description}: ${target_path}"
            else
                mark_fail "删除失败 ${description}: ${target_path}"
            fi
        else
            mark_skip "未找到 ${description}: ${target_path}"
        fi
    }

    collect_port_from_config "$NEW_CONFIG_FILE"
    collect_port_from_config "$OLD_CONFIG_FILE"
    if [ "${#detected_ports[@]}" -gt 0 ]; then
        print_info "检测到 Agent 端口: ${detected_ports[*]}"
    else
        print_info "未从配置中识别到 Agent 端口"
    fi

    # 1. 停止并禁用探针服务（不处理 dstatus，避免误操作面板）
    local agent_service_names=("dstatus-agent" "nekonekostatus")
    for service in "${agent_service_names[@]}"; do
        print_info "停止服务: $service"
        systemctl stop "$service" 2>/dev/null || true
        systemctl disable "$service" 2>/dev/null || true
        /etc/init.d/"$service" stop 2>/dev/null || true
        /etc/init.d/"$service" disable 2>/dev/null || true
        rc-service "$service" stop 2>/dev/null || true
        rc-update delete "$service" default 2>/dev/null || true
        update-rc.d -f "$service" remove 2>/dev/null || true
        chkconfig "$service" off 2>/dev/null || true
    done

    # 2. 清理探针进程（精确匹配）
    print_info "清理 Agent 进程..."
    agent_stop_processes "$NEW_BINARY_PATH" || return 1
    agent_stop_processes "$OLD_BINARY_PATH" || return 1
    sleep 1

    # 3. 删除探针二进制
    print_info "删除 Agent 二进制..."
    remove_file_if_exists "/usr/bin/dstatus-agent" "Agent 二进制"
    if alias_points_to_agent /usr/bin/dsa; then
        remove_file_if_exists "/usr/bin/dsa" "管理命令 dsa"
    elif [ -e /usr/bin/dsa ] || [ -L /usr/bin/dsa ]; then
        mark_skip "跳过 /usr/bin/dsa（不是本 Agent 的管理命令）"
    fi
    remove_file_if_exists "/usr/bin/neko-status" "旧版 Agent 二进制"
    if [ -L /usr/bin/dstatus ]; then
        local dstatus_link_target
        dstatus_link_target="$(readlink /usr/bin/dstatus 2>/dev/null || true)"
        case "$dstatus_link_target" in
            */dstatus-agent|/usr/bin/dstatus-agent|*/neko-status|/usr/bin/neko-status)
                remove_file_if_exists "/usr/bin/dstatus" "Agent 兼容软链"
                ;;
            *)
                mark_skip "跳过 /usr/bin/dstatus（非 Agent 软链）"
                ;;
        esac
    else
        mark_skip "未找到 Agent 兼容软链 /usr/bin/dstatus"
    fi

    # 4. 删除探针服务文件（不无条件删除 dstatus.service）
    print_info "删除 Agent 服务文件..."
    remove_file_if_exists "/etc/systemd/system/dstatus-agent.service" "systemd Agent 服务文件"
    remove_file_if_exists "/etc/systemd/system/nekonekostatus.service" "systemd 历史服务文件"
    remove_file_if_exists "/etc/init.d/dstatus-agent" "init.d Agent 服务文件"
    remove_file_if_exists "/etc/init.d/nekonekostatus" "init.d 历史服务文件"

    if [ -L /etc/systemd/system/dstatus.service ] && [ "$(readlink /etc/systemd/system/dstatus.service)" = "/etc/systemd/system/dstatus-agent.service" ]; then
        remove_file_if_exists "/etc/systemd/system/dstatus.service" "systemd Agent 别名服务"
    else
        mark_skip "跳过 /etc/systemd/system/dstatus.service（非 Agent 别名）"
    fi
    if [ -L /etc/init.d/dstatus ] && [ "$(readlink /etc/init.d/dstatus)" = "/etc/init.d/dstatus-agent" ]; then
        remove_file_if_exists "/etc/init.d/dstatus" "init.d Agent 别名服务"
    else
        mark_skip "跳过 /etc/init.d/dstatus（非 Agent 别名）"
    fi

    if command -v systemctl &> /dev/null; then
        systemctl daemon-reload 2>/dev/null || true
        print_info "systemd 已重载"
    fi

    # 5. 防火墙：只收回本脚本加过的放行，其余列出来请用户核对；记录在配置目录里，要先于删除配置目录
    print_info "收回防火墙放行..."
    agent_firewall_sync "" "${NEW_CONFIG_DIR}/firewall-rules" "${detected_ports[@]}" || true

    # 6. 删除配置目录
    print_info "删除配置目录..."
    remove_dir_if_exists "/etc/dstatus-agent" "Agent 配置目录"
    remove_dir_if_exists "/etc/neko-status" "旧版 Agent 配置目录"

    # 7. 清理遗留文件
    print_info "清理遗留文件..."
    local leftover_files=(
        "/var/run/dstatus-agent.pid"
        "/var/run/dstatus.pid"
        "/var/run/nekonekostatus.pid"
        "/var/log/dstatus-agent.log"
        "/var/log/dstatus.log"
        "/var/log/nekonekostatus.log"
        "/usr/local/bin/dstatus-agent-start"
        "/usr/local/bin/dstatus-agent-stop"
        "/usr/local/bin/dstatus-start"
        "/usr/local/bin/dstatus-stop"
        "/usr/local/bin/nekonekostatus-start"
        "/usr/local/bin/nekonekostatus-stop"
    )
    for leftover in "${leftover_files[@]}"; do
        remove_file_if_exists "$leftover" "遗留文件"
    done

    print_success "--------------------------------------------------"
    [ "$summary_fail" -eq 0 ] || { print_error "卸载未完成：有 ${summary_fail} 项清理失败。"; return 1; }
    print_success "卸载完成！"
    print_success "清理摘要：成功 ${summary_success} 项，跳过 ${summary_skip} 项，失败 ${summary_fail} 项"
    print_success "--------------------------------------------------"
}

# --- 主函数入口 ---
main() {
    if [ "${1:-}" == "repair-openrc" ]; then
        [ "$#" -eq 1 ] || die "repair-openrc 不接受其他参数。"
        process_openrc_repair
        exit 0
    fi

    # 优先检查卸载操作
    if [ "$1" == "uninstall" ]; then
        if [ "$(uname -s)" = "Darwin" ]; then
            delegate_to_macos_script "$@"
        fi
        process_uninstallation
        exit 0
    fi

    local operation=""
    local key_param=""
    local url_param=""
    local report_mode=""
    local custom_port=""
    normalize_allow_exec_env >/dev/null || die "DSTATUS_ALLOW_EXEC 只能是 1 或 0。" 2

    if [ "$1" == "reinstall-config" ] && [ "$#" -eq 1 ]; then
        operation="reinstall-config"
    elif [ "$1" == "install" ] && [ "$#" -eq 5 ]; then
        operation="install"; key_param="$2"; url_param="$3"; report_mode="$4"; custom_port="$5";
    elif [ "$1" == "install" ] && [ "$#" -eq 4 ]; then
        operation="install"; key_param="$2"; url_param="$3"; report_mode="$4";
    elif [ "$1" == "install" ] && [ "$#" -eq 3 ]; then
        operation="install"; key_param="$2"; url_param="$3";
    elif [ "$#" -eq 4 ]; then
        operation="install"; key_param="$1"; url_param="$2"; report_mode="$3"; custom_port="$4";
    elif [ "$#" -eq 3 ]; then
        operation="install"; key_param="$1"; url_param="$2"; report_mode="$3";
    elif [ "$#" -eq 2 ]; then
        operation="install"; key_param="$1"; url_param="$2";
    else
        print_error "参数格式不正确。"
        echo "支持的格式:"
        echo "  0. curl ... | bash -s -- repair-openrc  # root Alpine 存量服务守护修复"
        echo "  1. curl ... | sudo bash -s -- uninstall  # 卸载当前版本和历史残留"
        echo "  2. curl ... | bash -s -- <注册密钥> <服务器URL>"
        echo "  3. curl ... | bash -s -- <注册密钥> <服务器URL> active-report"
        echo "  4. curl ... | bash -s -- <注册密钥> <服务器URL> passive <端口>"
        echo "  5. curl ... | sudo bash -s install <注册密钥> <服务器URL>"
        echo "  6. curl ... | sudo bash -s install <注册密钥> <服务器URL> active-report"
        echo "  7. curl ... | sudo bash -s install <注册密钥> <服务器URL> passive <端口>"
        echo "  8. env DSTATUS_API_KEY=... DSTATUS_SERVER_ID=... DSTATUS_REPORT_SERVER=... bash -c 'curl ... | bash -s -- reinstall-config'"
        echo "  安装和重装都可先 export DSTATUS_AGENT_FILE=<本机 Agent 文件路径>，跳过下载"
        echo "  安装时带 DSTATUS_ALLOW_EXEC=1 允许面板在这台机器上运行脚本（默认不允许；装好后也可 sudo dsa exec on）"
        echo ""
        echo "示例："
        echo "  OpenRC 修复: curl -fsSL https://down.vps.mom/scripts/install-dstatus-agent.sh | bash -s -- repair-openrc"
        echo "  卸载: curl -fsSL https://down.vps.mom/scripts/install-dstatus-agent.sh | sudo bash -s -- uninstall"
        echo "  安装: curl -fsSL https://down.vps.mom/scripts/install-dstatus-agent.sh | bash -s -- \"YOUR_KEY\" \"https://your-server.com\""
        echo "  主动模式: curl -fsSL https://down.vps.mom/scripts/install-dstatus-agent.sh | bash -s -- \"YOUR_KEY\" \"https://your-server.com\" active-report"
        echo "  自定义端口: curl -fsSL https://down.vps.mom/scripts/install-dstatus-agent.sh | bash -s -- \"YOUR_KEY\" \"https://your-server.com\" passive 9998"
        echo "  重装: env DSTATUS_API_KEY=... DSTATUS_SERVER_ID=... DSTATUS_REPORT_SERVER=... bash -c 'curl -fsSL https://down.vps.mom/scripts/install-dstatus-agent.sh | bash -s -- reinstall-config'"
        exit 1
    fi

    if [ "$(uname -s)" = "Darwin" ]; then
        delegate_to_macos_script "$@"
    fi

    if [ "$operation" == "reinstall-config" ]; then
        process_reinstall_from_env
        return
    fi

    # 验证上报模式参数
    local enable_active_report="false"
    local agent_port="9999"
    
    if [ "$report_mode" = "active-report" ] || [ "$report_mode" = "active" ]; then
        enable_active_report="true"
        [ -n "$custom_port" ] && agent_port="$custom_port"
        print_info "启用Agent主动上报模式"
    elif [ "$report_mode" = "passive" ] && [ -n "$custom_port" ]; then
        agent_port="$custom_port"
        print_info "使用被动模式，Agent端口: $agent_port"
    fi

    if [ -z "$key_param" ]; then die "注册密钥不能为空。"; fi
    if [ -z "$url_param" ]; then die "服务器URL不能为空。"; fi
    if [[ ! "$url_param" =~ ^https?:// ]]; then die "服务器URL格式无效 (应以 http(s):// 开头)。"; fi

    if [ "$operation" == "install" ]; then
        process_installation "$key_param" "$url_param" "$enable_active_report" "$agent_port"
    else
        print_error "未知的操作模式。"
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
