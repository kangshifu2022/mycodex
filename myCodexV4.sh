#!/bin/bash

# myCodex.sh - Codex 供应商配置管理工具
# 用法: bash myCodex.sh [配置目录]

target_home() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        getent passwd "$SUDO_USER" | cut -d: -f6
        return
    fi

    printf '%s\n' "$HOME"
}

TARGET_HOME="$(target_home)"
CONFIG_DIR="${1:-$TARGET_HOME/.codex}"
BASE_DIR="$(dirname "$CONFIG_DIR")"
DEFAULT_STORE_DIR="$BASE_DIR/.myCodex"
LEGACY_STORE_DIR="$BASE_DIR/myCodex"
STORE_DIR="${MYCODEX_STORE_DIR:-$DEFAULT_STORE_DIR}"
PROVIDERS_DIR="$STORE_DIR/providers"
BACKUP_DIR="$STORE_DIR/backups"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

declare -a PROVIDERS=()
CHOSEN_PROVIDER=""
CODEX_INSTALLED_BY_SCRIPT=0

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return
    fi

    if command_exists sudo; then
        sudo "$@"
        return
    fi

    echo -e "${RED}错误: 需要 root 权限或 sudo 才能安装依赖${RESET}"
    return 1
}

owner_of_path() {
    stat -c '%U:%G' "$1" 2>/dev/null || printf '%s' "未知"
}

print_permission_fix_hint() {
    local path="$1"
    local parent

    parent="$(dirname "$path")"

    echo -e "${YELLOW}权限诊断:${RESET}"
    if [ -e "$parent" ]; then
        echo "  $parent 属主: $(owner_of_path "$parent") 权限: $(stat -c '%A' "$parent" 2>/dev/null || printf '%s' '未知')"
    fi
    if [ -e "$path" ]; then
        echo "  $path 属主: $(owner_of_path "$path") 权限: $(stat -c '%A' "$path" 2>/dev/null || printf '%s' '未知')"
    fi

    if [ "$(id -u)" -ne 0 ]; then
        echo ""
        echo "可以先运行这条命令修复当前用户 home 下的 Codex 目录权限:"
        echo -e "${CYAN}sudo chown -R \"$(id -un):$(id -gn)\" \"$TARGET_HOME/.codex\" \"$TARGET_HOME/.myCodex\" 2>/dev/null || true${RESET}"
        echo "如果仍然失败，再检查 home 目录本身:"
        echo -e "${CYAN}ls -ld \"$TARGET_HOME\" \"$TARGET_HOME/.codex\" \"$TARGET_HOME/.myCodex\"${RESET}"
    fi
}

node_major_version() {
    node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || printf '%s' "0"
}

install_base_dependencies() {
    if ! command_exists apt-get; then
        echo -e "${RED}错误: 当前系统缺少 apt-get，暂时只支持 Debian/Ubuntu 自动安装${RESET}"
        return 1
    fi

    echo -e "${CYAN}正在安装基础依赖...${RESET}"
    run_privileged apt-get update && \
        run_privileged apt-get install -y ca-certificates curl gnupg python3
}

install_nodejs_for_codex() {
    local major

    if command_exists node && command_exists npm; then
        major="$(node_major_version)"
        if [ "${major:-0}" -ge 22 ]; then
            return 0
        fi

        echo -e "${YELLOW}检测到 Node.js $major，Codex 安装将升级到 Node.js 22${RESET}"
    fi

    if ! install_base_dependencies; then
        return 1
    fi

    echo -e "${CYAN}正在安装 Node.js 22...${RESET}"
    if ! curl -fsSL https://deb.nodesource.com/setup_22.x | run_privileged bash -; then
        return 1
    fi

    run_privileged apt-get install -y nodejs
}

install_codex_cli() {
    if ! install_nodejs_for_codex; then
        return 1
    fi

    echo -e "${CYAN}正在安装 Codex CLI...${RESET}"
    if ! run_privileged npm install -g @openai/codex; then
        return 1
    fi

    hash -r 2>/dev/null
    command_exists codex
}

ensure_codex_installed() {
    if ! command_exists python3; then
        if ! install_base_dependencies; then
            return 1
        fi
    fi

    if command_exists codex; then
        return 0
    fi

    echo -e "${YELLOW}未检测到 Codex CLI，开始自动安装...${RESET}"
    if ! install_codex_cli; then
        echo -e "${RED}错误: Codex CLI 自动安装失败${RESET}"
        return 1
    fi

    CODEX_INSTALLED_BY_SCRIPT=1
    echo -e "${GREEN}Codex CLI 已安装完成${RESET}"
}

ensure_config_dir_exists() {
    if [ -d "$CONFIG_DIR" ] && [ -w "$CONFIG_DIR" ]; then
        return 0
    fi

    if mkdir -p "$CONFIG_DIR"; then
        chmod 700 "$CONFIG_DIR" 2>/dev/null
        return 0
    fi

    echo -e "${RED}错误: 无法创建配置目录: $CONFIG_DIR${RESET}"
    print_permission_fix_hint "$CONFIG_DIR"
    echo "用法: bash myCodex.sh [配置目录]"
    return 1
}

if ! ensure_codex_installed; then
    exit 1
fi

# 检查配置目录
if ! ensure_config_dir_exists; then
    exit 1
fi

cleanup() {
    tput cnorm 2>/dev/null
    stty echo 2>/dev/null
}

clear_screen() {
    printf '\033[H\033[2J'
}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

provider_dir() {
    printf '%s' "$PROVIDERS_DIR/$1"
}

provider_auth_file() {
    printf '%s' "$PROVIDERS_DIR/$1/auth.json"
}

provider_config_file() {
    printf '%s' "$PROVIDERS_DIR/$1/config.toml"
}

migrate_store_dir_if_needed() {
    if [ -n "${MYCODEX_STORE_DIR:-}" ]; then
        return 0
    fi

    if [ "$STORE_DIR" != "$DEFAULT_STORE_DIR" ]; then
        return 0
    fi

    if [ -d "$STORE_DIR" ] || [ ! -d "$LEGACY_STORE_DIR" ]; then
        return 0
    fi

    if mv "$LEGACY_STORE_DIR" "$STORE_DIR"; then
        chmod 700 "$STORE_DIR" "$STORE_DIR/providers" "$STORE_DIR/backups" 2>/dev/null
        return 0
    fi

    echo -e "${RED}错误: 无法迁移旧目录: $LEGACY_STORE_DIR -> $STORE_DIR${RESET}"
    return 1
}

ensure_storage_dirs() {
    if mkdir -p "$PROVIDERS_DIR" "$BACKUP_DIR"; then
        chmod 700 "$STORE_DIR" "$PROVIDERS_DIR" "$BACKUP_DIR" 2>/dev/null
        return 0
    fi

    echo -e "${RED}错误: 无法创建目录: $STORE_DIR${RESET}"
    print_permission_fix_hint "$STORE_DIR"
    return 1
}

copy_provider_files_to_store() {
    local provider_name="$1"
    local auth_source="$2"
    local config_source="$3"
    local target_dir auth_target config_target

    target_dir="$(provider_dir "$provider_name")"
    auth_target="$(provider_auth_file "$provider_name")"
    config_target="$(provider_config_file "$provider_name")"

    if ! mkdir -p "$target_dir"; then
        return 1
    fi

    if ! cp "$auth_source" "$auth_target"; then
        return 1
    fi

    if ! cp "$config_source" "$config_target"; then
        return 1
    fi

    chmod 600 "$auth_target" "$config_target" 2>/dev/null
    chmod 700 "$target_dir" 2>/dev/null
    return 0
}

move_backup_file() {
    local source_file="$1"
    local target_file="$2"

    if [ ! -f "$source_file" ]; then
        return 0
    fi

    if cp "$source_file" "$target_file"; then
        chmod 600 "$target_file" 2>/dev/null
        rm -f "$source_file"
        return 0
    fi

    return 1
}

migrate_legacy_providers() {
    local legacy_auth suffix legacy_config
    local target_name target_auth target_config

    while IFS= read -r legacy_auth; do
        suffix="${legacy_auth##*.}"
        legacy_config="$CONFIG_DIR/config.toml.$suffix"

        [ "$suffix" = "bak" ] && continue
        [ -f "$legacy_config" ] || continue

        target_name="$suffix"
        target_auth="$(provider_auth_file "$target_name")"
        target_config="$(provider_config_file "$target_name")"

        if [ -f "$target_auth" ] || [ -f "$target_config" ]; then
            if cmp -s "$legacy_auth" "$target_auth" 2>/dev/null && \
               cmp -s "$legacy_config" "$target_config" 2>/dev/null; then
                rm -f "$legacy_auth" "$legacy_config"
                continue
            fi

            target_name="$(ensure_unique_provider_name "$target_name")"
        fi

        if ! copy_provider_files_to_store "$target_name" "$legacy_auth" "$legacy_config"; then
            echo -e "${RED}错误: 迁移旧厂商配置失败: $suffix${RESET}"
            return 1
        fi

        rm -f "$legacy_auth" "$legacy_config"
    done < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name "auth.json.*" | sort)

    return 0
}

initialize_storage() {
    if ! migrate_store_dir_if_needed; then
        return 1
    fi

    if ! ensure_storage_dirs; then
        return 1
    fi

    if ! move_backup_file "$CONFIG_DIR/auth.json.bak" "$BACKUP_DIR/auth.json.bak"; then
        echo -e "${RED}错误: 迁移 auth.json.bak 失败${RESET}"
        return 1
    fi

    if ! move_backup_file "$CONFIG_DIR/config.toml.bak" "$BACKUP_DIR/config.toml.bak"; then
        echo -e "${RED}错误: 迁移 config.toml.bak 失败${RESET}"
        return 1
    fi

    migrate_legacy_providers
}

scan_providers() {
    local path suffix

    PROVIDERS=()

    while IFS= read -r path; do
        suffix="${path##*/}"
        if [ -f "$path/auth.json" ] && [ -f "$path/config.toml" ]; then
            PROVIDERS+=("$suffix")
        fi
    done < <(find "$PROVIDERS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
}

get_current_provider() {
    local current=""
    local suffix

    if [ -f "$CONFIG_DIR/auth.json" ] && [ -f "$CONFIG_DIR/config.toml" ]; then
        for suffix in "${PROVIDERS[@]}"; do
            if cmp -s "$CONFIG_DIR/auth.json" "$(provider_auth_file "$suffix")" 2>/dev/null && \
               cmp -s "$CONFIG_DIR/config.toml" "$(provider_config_file "$suffix")" 2>/dev/null; then
                current="$suffix"
                break
            fi
        done
    fi

    printf '%s' "$current"
}

read_menu_key() {
    local key key2 key3

    IFS= read -rsn1 key

    if [[ "$key" == $'\x1b' ]]; then
        IFS= read -rsn1 -t 0.1 key2
        if [[ "$key2" == '[' ]]; then
            IFS= read -rsn1 -t 0.1 key3
            case "$key3" in
                A) printf '%s' "up" ;;
                B) printf '%s' "down" ;;
            esac
        fi
        return
    fi

    case "$key" in
        '') printf '%s' "enter" ;;
        q|Q) printf '%s' "quit" ;;
        k|K) printf '%s' "up" ;;
        j|J) printf '%s' "down" ;;
    esac
}

normalize_base_url() {
    local url

    url="$(trim "$1")"
    if [ -z "$url" ]; then
        printf '%s' ""
        return
    fi

    if [[ ! "$url" =~ ^https?:// ]]; then
        url="https://$url"
    fi

    while [[ "$url" == */ ]]; do
        url="${url%/}"
    done

    printf '%s' "$url"
}

sanitize_provider_name() {
    local name

    name="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    name="$(trim "$name")"
    name="$(printf '%s' "$name" | sed 's#[/\\]#_#g; s/[[:cntrl:]]/_/g; s/[[:space:]][[:space:]]*/_/g; s/^[_[:space:].-]*//; s/[_[:space:].-]*$//')"

    if [ -z "$name" ] || [ "$name" = "." ] || [ "$name" = ".." ]; then
        name="provider"
    fi

    printf '%s' "$name"
}

derive_provider_name_from_url() {
    local url host candidate

    url="$(normalize_base_url "$1")"
    host="${url#*://}"
    host="${host#*@}"
    host="${host%%/*}"
    host="${host%%:*}"
    host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
    host="${host#www.}"
    host="${host#api.}"

    candidate="${host%%.*}"
    if [ -z "$candidate" ]; then
        candidate="$host"
    fi

    sanitize_provider_name "$candidate"
}

ensure_unique_provider_name() {
    local base_name candidate index

    base_name="$(sanitize_provider_name "$1")"
    candidate="$base_name"
    index=2

    while [ -d "$(provider_dir "$candidate")" ]; do
        candidate="${base_name}_$index"
        index=$((index + 1))
    done

    printf '%s' "$candidate"
}

get_template_config() {
    local first_match

    if [ -f "$CONFIG_DIR/config.toml" ]; then
        printf '%s' "$CONFIG_DIR/config.toml"
        return
    fi

    first_match="$(find "$PROVIDERS_DIR" -mindepth 2 -maxdepth 2 -type f -name "config.toml" | sort | head -n 1)"
    printf '%s' "$first_match"
}

write_auth_file() {
    local output_file="$1"
    local api_key="$2"

    python3 - "$output_file" "$api_key" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
api_key = sys.argv[2]

output_path.write_text(
    json.dumps({"OPENAI_API_KEY": api_key}, ensure_ascii=True, indent=2) + "\n"
)
PY
}

write_config_file() {
    local output_file="$1"
    local provider_name="$2"
    local base_url="$3"
    local template_file

    template_file="$(get_template_config)"

    python3 - "$template_file" "$output_file" "$provider_name" "$base_url" <<'PY'
import json
import re
import sys
from pathlib import Path

template_file, output_file, provider_name, base_url = sys.argv[1:5]
provider_name_toml = json.dumps(provider_name, ensure_ascii=False)
base_url_toml = json.dumps(base_url, ensure_ascii=False)

text = ""
if template_file and Path(template_file).exists():
    text = Path(template_file).read_text()

if not text.strip():
    text = (
        f'model_provider = {provider_name_toml}\n'
        'model = "gpt-5.4"\n'
        'model_reasoning_effort = "high"\n'
        'disable_response_storage = true\n'
        'sandbox_mode = "workspace-write"\n'
        '\n'
        '[sandbox_workspace_write]\n'
        'network_access = true\n'
    )

model_provider_line = f'model_provider = {provider_name_toml}'
if re.search(r'(?m)^model_provider\s*=\s*".*?"\s*$', text):
    text = re.sub(
        r'(?m)^model_provider\s*=\s*".*?"\s*$',
        model_provider_line,
        text,
        count=1,
    )
else:
    text = model_provider_line + "\n" + text

section_pattern = re.compile(
    rf'(?ms)^\[model_providers\.{re.escape(provider_name_toml)}\]\n.*?(?=^\[|\Z)'
)
text = section_pattern.sub("", text).rstrip()

provider_block = (
    f'[model_providers.{provider_name_toml}]\n'
    f'name = {provider_name_toml}\n'
    f'base_url = {base_url_toml}\n'
    'wire_api = "responses"\n'
    'requires_openai_auth = true\n'
)

if text:
    text += "\n\n"
text += provider_block

Path(output_file).write_text(text.rstrip() + "\n")
PY
}

rename_provider_config_file() {
    local config_file="$1"
    local old_name="$2"
    local new_name="$3"

    python3 - "$config_file" "$old_name" "$new_name" <<'PY'
import json
import re
import sys
from pathlib import Path

config_file, old_name, new_name = sys.argv[1:4]
path = Path(config_file)
text = path.read_text()

old_name_toml = json.dumps(old_name, ensure_ascii=False)
new_name_toml = json.dumps(new_name, ensure_ascii=False)


def provider_ref_pattern(name: str) -> str:
    variants = [json.dumps(name, ensure_ascii=False)]
    if re.fullmatch(r"[A-Za-z0-9_-]+", name):
        variants.append(name)
    return "(?:" + "|".join(re.escape(item) for item in dict.fromkeys(variants)) + ")"


def strip_provider_section(source: str, name: str) -> str:
    pattern = re.compile(
        rf'(?ms)^\[model_providers\.{provider_ref_pattern(name)}\]\n.*?(?=^\[|\Z)'
    )
    return pattern.sub("", source).rstrip()


section_pattern = re.compile(
    rf'(?ms)^\[model_providers\.{provider_ref_pattern(old_name)}\]\n(.*?)(?=^\[|\Z)'
)
match = section_pattern.search(text)

if match:
    body = match.group(1).rstrip()
else:
    body = 'wire_api = "responses"\nrequires_openai_auth = true'

name_line = f'name = {new_name_toml}'
if re.search(r'(?m)^name\s*=.*$', body):
    body = re.sub(r'(?m)^name\s*=.*$', name_line, body, count=1)
else:
    body = name_line + "\n" + body

body = body.strip()
provider_block = f'[model_providers.{new_name_toml}]\n{body}\n'

text = strip_provider_section(text, old_name)
if old_name != new_name:
    text = strip_provider_section(text, new_name)

model_provider_line = f'model_provider = {new_name_toml}'
if re.search(r'(?m)^model_provider\s*=.*$', text):
    text = re.sub(
        r'(?m)^model_provider\s*=.*$',
        model_provider_line,
        text,
        count=1,
    )
else:
    text = model_provider_line + "\n" + text

text = text.rstrip()
if text:
    text += "\n\n"
text += provider_block

path.write_text(text.rstrip() + "\n")
PY
}

rename_provider_directory() {
    local old_name="$1"
    local new_name="$2"
    local old_path new_path config_file

    old_path="$(provider_dir "$old_name")"
    new_path="$(provider_dir "$new_name")"
    config_file="$new_path/config.toml"

    if [ "$old_name" = "$new_name" ]; then
        return 0
    fi

    if ! mv "$old_path" "$new_path"; then
        return 1
    fi

    if ! rename_provider_config_file "$config_file" "$old_name" "$new_name"; then
        mv "$new_path" "$old_path" 2>/dev/null
        return 1
    fi

    chmod 700 "$new_path" 2>/dev/null
    chmod 600 "$new_path/auth.json" "$new_path/config.toml" 2>/dev/null
    return 0
}

pause_return() {
    echo ""
    read -r -p "按 Enter 返回..." _
}

apply_config() {
    local suffix="$1"
    local auth_source config_source

    auth_source="$(provider_auth_file "$suffix")"
    config_source="$(provider_config_file "$suffix")"

    if [ -f "$CONFIG_DIR/auth.json" ]; then
        cp "$CONFIG_DIR/auth.json" "$BACKUP_DIR/auth.json.bak" 2>/dev/null
        chmod 600 "$BACKUP_DIR/auth.json.bak" 2>/dev/null
    fi
    if [ -f "$CONFIG_DIR/config.toml" ]; then
        cp "$CONFIG_DIR/config.toml" "$BACKUP_DIR/config.toml.bak" 2>/dev/null
        chmod 600 "$BACKUP_DIR/config.toml.bak" 2>/dev/null
    fi

    if cp "$auth_source" "$CONFIG_DIR/auth.json" && \
       cp "$config_source" "$CONFIG_DIR/config.toml"; then
        chmod 600 "$CONFIG_DIR/auth.json" "$CONFIG_DIR/config.toml" 2>/dev/null
        echo -e "${GREEN}已切换到供应商: ${BOLD}$suffix${RESET}"
        echo -e "${DIM}auth.json   <- $auth_source${RESET}"
        echo -e "${DIM}config.toml <- $config_source${RESET}"
        return 0
    fi

    echo -e "${RED}切换失败，请检查文件权限${RESET}"
    return 1
}

render_main_menu() {
    local selected="$1"
    local current_provider="$2"
    local items=("添加新厂商" "切换厂商" "重命名厂商" "删除厂商")
    local i

    tput civis 2>/dev/null
    clear_screen

    echo -e "${BOLD}${CYAN}Codex 供应商管理${RESET}"
    if [ -n "$current_provider" ]; then
        echo -e "${DIM}当前供应商: $current_provider${RESET}"
    else
        echo -e "${DIM}当前供应商: 未识别${RESET}"
    fi
    echo -e "${DIM}↑↓ 选择  Enter 确认  q 退出${RESET}"
    echo ""

    for i in "${!items[@]}"; do
        if [ "$i" -eq "$selected" ]; then
            echo -e "${GREEN}${BOLD}▶ ${items[$i]}${RESET}"
        else
            echo "  ${items[$i]}"
        fi
    done
}

render_provider_menu() {
    local title="$1"
    local selected="$2"
    local current_provider="$3"
    local i provider

    tput civis 2>/dev/null
    clear_screen

    echo -e "${BOLD}${CYAN}$title${RESET}"
    echo -e "${DIM}↑↓ 选择  Enter 确认  q 返回${RESET}"
    echo ""

    for i in "${!PROVIDERS[@]}"; do
        provider="${PROVIDERS[$i]}"
        if [ "$i" -eq "$selected" ]; then
            if [ "$provider" = "$current_provider" ]; then
                echo -e "${GREEN}${BOLD}▶ $provider${RESET} ${DIM}(当前)${RESET}"
            else
                echo -e "${GREEN}${BOLD}▶ $provider${RESET}"
            fi
        else
            if [ "$provider" = "$current_provider" ]; then
                echo -e "  ${DIM}$provider (当前)${RESET}"
            else
                echo "  $provider"
            fi
        fi
    done
}

choose_provider() {
    local title="$1"
    local current_provider="$2"
    local selected=0
    local count key i

    CHOSEN_PROVIDER=""

    if [ "${#PROVIDERS[@]}" -eq 0 ]; then
        return 1
    fi

    count="${#PROVIDERS[@]}"

    for i in "${!PROVIDERS[@]}"; do
        if [ "${PROVIDERS[$i]}" = "$current_provider" ]; then
            selected="$i"
            break
        fi
    done

    while true; do
        render_provider_menu "$title" "$selected" "$current_provider"
        key="$(read_menu_key)"

        case "$key" in
            up)
                selected=$(( (selected - 1 + count) % count ))
                ;;
            down)
                selected=$(( (selected + 1) % count ))
                ;;
            enter)
                CHOSEN_PROVIDER="${PROVIDERS[$selected]}"
                return 0
                ;;
            quit)
                return 1
                ;;
        esac
    done
}

add_provider_flow() {
    local base_url api_key default_name provider_name final_name
    local provider_path auth_file config_file

    tput cnorm 2>/dev/null
    clear_screen

    echo -e "${BOLD}${CYAN}添加新厂商${RESET}"
    echo -e "${DIM}Base URL 留空则取消${RESET}"
    echo ""

    read -r -p "Base URL: " base_url
    base_url="$(normalize_base_url "$base_url")"
    if [ -z "$base_url" ]; then
        echo -e "\n${DIM}已取消${RESET}"
        pause_return
        return 1
    fi

    echo ""
    read -r -p "API KEY: " api_key
    echo ""
    api_key="$(trim "$api_key")"
    if [ -z "$api_key" ]; then
        echo -e "\n${DIM}已取消${RESET}"
        pause_return
        return 1
    fi

    default_name="$(derive_provider_name_from_url "$base_url")"
    default_name="$(ensure_unique_provider_name "$default_name")"

    echo ""
    read -r -p "厂商名 [$default_name]: " provider_name
    provider_name="$(trim "$provider_name")"
    if [ -z "$provider_name" ]; then
        provider_name="$default_name"
    fi

    provider_name="$(sanitize_provider_name "$provider_name")"
    final_name="$(ensure_unique_provider_name "$provider_name")"

    provider_path="$(provider_dir "$final_name")"
    auth_file="$provider_path/auth.json"
    config_file="$provider_path/config.toml"

    if ! mkdir -p "$provider_path"; then
        echo -e "\n${RED}创建厂商目录失败: $provider_path${RESET}"
        pause_return
        return 1
    fi

    chmod 700 "$provider_path" 2>/dev/null

    if ! write_auth_file "$auth_file" "$api_key"; then
        echo -e "\n${RED}写入 $auth_file 失败${RESET}"
        pause_return
        return 1
    fi

    if ! write_config_file "$config_file" "$final_name" "$base_url"; then
        rm -f "$auth_file"
        rmdir "$provider_path" 2>/dev/null
        echo -e "\n${RED}写入 $config_file 失败${RESET}"
        pause_return
        return 1
    fi

    chmod 600 "$auth_file" "$config_file" 2>/dev/null

    scan_providers

    clear_screen
    echo -e "${GREEN}新厂商已添加${RESET}"
    echo -e "${DIM}名称: $final_name${RESET}"
    echo -e "${DIM}Base URL: $base_url${RESET}"
    echo -e "${DIM}存放目录: $provider_path${RESET}"
    if [ "$final_name" != "$provider_name" ]; then
        echo -e "${YELLOW}名称已自动调整为: $final_name${RESET}"
    fi

    pause_return
    return 0
}

switch_provider_flow() {
    local current_provider

    scan_providers
    current_provider="$(get_current_provider)"

    if [ "${#PROVIDERS[@]}" -eq 0 ]; then
        tput cnorm 2>/dev/null
        clear_screen
        echo -e "${YELLOW}当前还没有可切换的厂商配置${RESET}"
        echo -e "${DIM}先用“添加新厂商”创建一个供应商${RESET}"
        pause_return
        return 1
    fi

    if ! choose_provider "切换厂商" "$current_provider"; then
        return 1
    fi

    tput cnorm 2>/dev/null
    clear_screen
    if apply_config "$CHOSEN_PROVIDER"; then
        echo ""
        return 0
    fi

    pause_return
    return 1
}

rename_provider_flow() {
    local current_provider old_name requested_name new_name final_name

    scan_providers
    current_provider="$(get_current_provider)"

    if [ "${#PROVIDERS[@]}" -eq 0 ]; then
        tput cnorm 2>/dev/null
        clear_screen
        echo -e "${YELLOW}当前还没有可重命名的厂商配置${RESET}"
        echo -e "${DIM}先用“添加新厂商”创建一个供应商${RESET}"
        pause_return
        return 1
    fi

    if ! choose_provider "选择要重命名的厂商" "$current_provider"; then
        return 1
    fi

    old_name="$CHOSEN_PROVIDER"

    tput cnorm 2>/dev/null
    clear_screen
    echo -e "${BOLD}${CYAN}重命名厂商${RESET}"
    echo -e "${DIM}当前名称: $old_name${RESET}"
    echo ""

    read -r -p "新厂商名 [$old_name]: " requested_name
    requested_name="$(trim "$requested_name")"
    if [ -z "$requested_name" ]; then
        requested_name="$old_name"
    fi

    new_name="$(sanitize_provider_name "$requested_name")"
    if [ "$new_name" = "$old_name" ]; then
        clear_screen
        echo -e "${DIM}名称未变更${RESET}"
        pause_return
        return 1
    fi

    final_name="$(ensure_unique_provider_name "$new_name")"

    if ! rename_provider_directory "$old_name" "$final_name"; then
        echo -e "\n${RED}重命名失败，请检查文件权限${RESET}"
        pause_return
        return 1
    fi

    scan_providers

    clear_screen
    echo -e "${GREEN}厂商已重命名${RESET}"
    echo -e "${DIM}原名称: $old_name${RESET}"
    echo -e "${DIM}新名称: $final_name${RESET}"
    echo -e "${DIM}存放目录: $(provider_dir "$final_name")${RESET}"
    if [ "$final_name" != "$new_name" ]; then
        echo -e "${YELLOW}名称已自动调整为: $final_name${RESET}"
    fi

    if [ "$old_name" = "$current_provider" ]; then
        echo ""
        if ! apply_config "$final_name"; then
            echo -e "${YELLOW}当前生效配置同步失败，请手动切换到 $final_name${RESET}"
            pause_return
            return 1
        fi
    fi

    pause_return
    return 0
}

delete_provider_flow() {
    local current_provider target_name target_path confirm

    scan_providers
    current_provider="$(get_current_provider)"

    if [ "${#PROVIDERS[@]}" -eq 0 ]; then
        tput cnorm 2>/dev/null
        clear_screen
        echo -e "${YELLOW}当前还没有可删除的厂商配置${RESET}"
        echo -e "${DIM}先用“添加新厂商”创建一个供应商${RESET}"
        pause_return
        return 1
    fi

    if ! choose_provider "选择要删除的厂商" "$current_provider"; then
        return 1
    fi

    target_name="$CHOSEN_PROVIDER"
    target_path="$(provider_dir "$target_name")"

    tput cnorm 2>/dev/null
    clear_screen
    echo -e "${BOLD}${CYAN}删除厂商${RESET}"
    echo -e "${DIM}名称: $target_name${RESET}"
    echo -e "${DIM}目录: $target_path${RESET}"
    if [ "$target_name" = "$current_provider" ]; then
        echo -e "${YELLOW}该厂商当前正在生效，删除后会同时移除当前 auth.json 和 config.toml${RESET}"
    fi
    echo ""
    read -r -p "确认删除？输入 y 继续: " confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo -e "\n${DIM}已取消${RESET}"
        pause_return
        return 1
    fi

    if [ ! -d "$target_path" ]; then
        echo -e "\n${RED}删除失败，厂商目录不存在: $target_path${RESET}"
        pause_return
        return 1
    fi

    if ! rm -rf "$target_path"; then
        echo -e "\n${RED}删除失败，请检查文件权限${RESET}"
        pause_return
        return 1
    fi

    if [ "$target_name" = "$current_provider" ]; then
        rm -f "$CONFIG_DIR/auth.json" "$CONFIG_DIR/config.toml"
    fi

    scan_providers

    clear_screen
    echo -e "${GREEN}厂商已删除${RESET}"
    echo -e "${DIM}名称: $target_name${RESET}"
    if [ "$target_name" = "$current_provider" ]; then
        echo -e "${DIM}当前生效配置已清空，请重新切换或添加厂商${RESET}"
    fi

    pause_return
    return 0
}

main() {
    local selected=0
    local current_provider key
    local menu_count=4

    trap cleanup EXIT INT TERM

    if ! initialize_storage; then
        exit 1
    fi

    while true; do
        scan_providers
        current_provider="$(get_current_provider)"
        render_main_menu "$selected" "$current_provider"
        key="$(read_menu_key)"

        case "$key" in
            up)
                selected=$(( (selected - 1 + menu_count) % menu_count ))
                ;;
            down)
                selected=$(( (selected + 1) % menu_count ))
                ;;
            enter)
                case "$selected" in
                    0)
                        add_provider_flow
                        ;;
                    1)
                        if switch_provider_flow; then
                            break
                        fi
                        ;;
                    2)
                        rename_provider_flow
                        ;;
                    3)
                        delete_provider_flow
                        ;;
                esac
                ;;
            quit)
                clear_screen
                echo -e "${DIM}已取消${RESET}"
                break
                ;;
        esac
    done
}

main
