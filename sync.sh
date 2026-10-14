#!/bin/bash
# ══════════════════════════════════════════════════════════════
# Universal IMAP Email Migration Tool  v2.0.0
# Supports: Gmail, Zimbra, Zextras Carbonio, Outlook/Office 365, Yahoo, any IMAP
# ══════════════════════════════════════════════════════════════

VERSION="2.0.0"

# ─── Bash version guard (requires 4+ for associative arrays) ──
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "ERROR: Bash 4.0+ required (current: ${BASH_VERSION:-unknown})"
    exit 1
fi

# ─── Strip Windows carriage returns if present ────────────────
if grep -qP '\r$' "$0" 2>/dev/null; then
    tmp_self="$(mktemp)"
    sed 's/\r$//' "$0" > "$tmp_self"
    chmod +x "$tmp_self"
    exec bash "$tmp_self" "$@"
fi

set -o pipefail

# ============================================
# COLOR CODES
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}${WHITE}  $1${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
}
print_subheader() { echo -e "${MAGENTA}─── $1 ───${NC}"; }
print_error()     { echo -e "${RED}[ERROR]${NC} $1"; }
print_success()   { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_info()      { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warning()   { echo -e "${YELLOW}[WARNING]${NC} $1"; }

get_timestamp()   { date +%Y%m%d_%H%M%S; }
generate_logname() {
    local safe_name
    safe_name=$(echo "$1" | tr '@' '_' | tr '.' '_')
    echo "$LOG_DIR/$(date +%Y_%m_%d_%H_%M_%S)_${safe_name}.log"
}
pause() { read -r -p "Press Enter to continue..." _; }

# ============================================
# PROGRESS BAR
# ============================================
show_progress() {
    local current=$1 total=$2 start_time=$3
    local percent=$((current * 100 / total))
    local elapsed=$(( $(date +%s) - start_time ))
    local eta_str=""

    if [ "$current" -gt 0 ] && [ "$elapsed" -gt 0 ]; then
        local secs_per_item=$((elapsed / current))
        local remaining=$((total - current))
        local eta_secs=$((remaining * secs_per_item))
        eta_str="ETA: $(printf '%02d:%02d:%02d' $((eta_secs/3600)) $(((eta_secs%3600)/60)) $((eta_secs%60)))"
    fi

    local bar_width=30
    local filled=$((percent * bar_width / 100))
    local empty=$((bar_width - filled))
    local bar=""
    local j
    for ((j=0; j<filled; j++)); do bar+="█"; done
    for ((j=0; j<empty; j++)); do bar+="░"; done

    local elapsed_st
    elapsed_str=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $(((elapsed%3600)/60)) $((elapsed%60)))

    printf "\r  ${CYAN}[%s]${NC} %3d%% (%d/%d) Elapsed: %s %s " \
        "$bar" "$percent" "$current" "$total" "$elapsed_str" "$eta_str"
}

# ============================================
# PROVIDER HELPERS
# ============================================
provider_name() {
    case "$1" in
        1) echo "Gmail / Google Workspace" ;;
        2) echo "Zimbra / Zextras Carbonio" ;;
        3) echo "Outlook / Office 365 / Exchange" ;;
        4) echo "Yahoo Mail" ;;
        *) echo "Other IMAP Server" ;;
    esac
}

provider_auth_notice() {
    case "$1" in
        1) print_warning "Gmail/Google Workspace requires an App Password if 2FA is enabled." ;;
        3) print_warning "Office 365/Exchange often requires OAuth or an App Password." ;;
        4) print_warning "Yahoo Mail requires an App Password if 2-step verification is enabled." ;;
    esac
}

validate_mapping_line() {
    local line="$1" src dest
    [[ "$line" != *:* ]] && return 1
    src="${line%%:*}"
    dest="${line#*:}"
    validate_email "$src" && validate_email "$dest"
}

# ============================================
# PRE-FLIGHT
# ============================================
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root."
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    command -v imapsync >/dev/null 2>&1 || missing+=("imapsync")
    command -v bc >/dev/null 2>&1 || missing+=("bc")
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing: ${missing[*]}"
        exit 1
    fi
    IMAPSYNC_BIN="$(command -v imapsync)"
}

# ============================================
# VALIDATION HELPERS
# ============================================
validate_email() {
    [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}
validate_host() { [[ -n "$1" ]]; }
is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

prompt_required() {
    local prompt="$1" varname="$2" validator="$3" value
    while true; do
        read -r -p "$prompt: " value
        if [ -z "$value" ]; then
            print_error "This field is required."
            continue
        fi
        if [ -n "$validator" ] && ! "$validator" "$value"; then
            print_error "Invalid value."
            continue
        fi
        printf -v "$varname" '%s' "$value"
        break
    done
}

prompt_optional() {
    local prompt="$1" varname="$2" default="$3" value
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
    printf -v "$varname" '%s' "$value"
}

prompt_password() {
    local prompt="$1" varname="$2" value
    while true; do
        read -r -s -p "$prompt: " value
        echo ""  # Newline after silent read
        if [ -z "$value" ]; then
            print_error "Password cannot be empty."
            continue
        fi
        printf -v "$varname" '%s' "$value"
        break
    done
}

# ============================================
# PROFILE MANAGEMENT
# ============================================
WORK_ROOT_DEFAULT="$HOME/migration_tool"

select_or_create_profile() {
    print_header "MIGRATION PROFILE SETUP"
    echo ""
    prompt_optional "Base working directory" WORK_ROOT "$WORK_ROOT_DEFAULT"

    BASE_DIR="$WORK_ROOT"
    CONFIG_DIR="$BASE_DIR/profiles"
    LOG_DIR="$BASE_DIR/LOGS"
    REPORT_DIR="$BASE_DIR/reports"
    USER_LISTS_DIR="$BASE_DIR/user_lists"
    SECRETS_DIR="$BASE_DIR/.secrets"
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$REPORT_DIR" "$USER_LISTS_DIR" "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"

    local profiles=()
    while IFS= read -r -d '' f; do
        profiles+=("$(basename "$f" .conf)")
    done < <(find "$CONFIG_DIR" -maxdepth 1 -name "*.conf" -print0 2>/dev/null)

    if [ ${#profiles[@]} -gt 0 ]; then
        echo ""
        echo "Existing profiles:"
        local i=1
        for p in "${profiles[@]}"; do
            echo "  $i) $p"
            ((i++)) || true
        done
        echo "  n) Create new"
        echo ""
        read -r -p "Select profile or 'n': " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#profiles[@]} ]; then
            PROFILE_NAME="${profiles[$((choice-1))]}"
            load_profile "$PROFILE_NAME"
            return
        fi
    fi
    create_profile
}

configure_provider() {
    local direction="$1"  # "source" or "dest"
    local prefix label ssl_flag options_va

    if [ "$direction" = "source" ]; then
        prefix="SOURCE"
        label="source"
        ssl_flag="--ssl1"
        options_var="SOURCE_OPTIONS"
    else
        prefix="DEST"
        label="destination"
        ssl_flag="--ssl2"
        options_var="DEST_OPTIONS"
    fi

    echo ""
    print_info "Select $label provider:"
    echo "  1) Gmail / Google Workspace"
    echo "  2) Zimbra / Zextras Carbonio"
    echo "  3) Outlook / Office 365 / Exchange"
    echo "  4) Yahoo Mail"
    echo "  5) Other IMAP Server"
    local provider_choice
    read -r -p "Select (1-5): " provider_choice
    provider_auth_notice "$provider_choice"

    local host port ssl options=""
    case $provider_choice in
        1)
            host="imap.gmail.com"
            port="993"
            ssl="$ssl_flag"
            if [ "$direction" = "source" ]; then
                options="--gmail1"
            else
                options="--gmail2"
            fi
            ;;
        2)
            prompt_required "${label^} host" host validate_host
            port="993"
            ssl="$ssl_flag"
            ;;
        3)
            host="outlook.office365.com"
            port="993"
            ssl="$ssl_flag"
            ;;
        4)
            host="imap.mail.yahoo.com"
            port="993"
            ssl="$ssl_flag"
            ;;
        *)
            prompt_required "${label^} host" host validate_host
            prompt_optional "${label^} port" port "993"
            local use_ssl
            read -r -p "Use SSL? (y/n): " use_ssl
            if [[ "$use_ssl" =~ ^[Yy]$ ]]; then
                ssl="$ssl_flag"
            else
                ssl=""
            fi
            ;;
    esac

    printf -v "${prefix}_PROVIDER" '%s' "$provider_choice"
    printf -v "${prefix}_HOST" '%s' "$host"
    printf -v "${prefix}_PORT" '%s' "$port"
    printf -v "${prefix}_SSL" '%s' "$ssl"
    printf -v "${prefix}_OPTIONS" '%s' "$options"
}

create_profile() {
    echo ""
    print_subheader "New Profile"
    prompt_required "Profile name" PROFILE_NAME
    PROFILE_NAME="${PROFILE_NAME// /_}"

    configure_provider "source"
    prompt_required "Source auth user" SOURCE_AUTHUSER validate_email

    configure_provider "dest"
    prompt_required "Destination auth user" DEST_AUTHUSER validate_email

    echo ""
    print_info "Password options:"
    echo "  1) Store in chmod 600 secrets file (recommended)"
    echo "  2) Prompt me each time"
    read -r -p "Select (1-2): " pw_mode

    if [ "$pw_mode" = "1" ]; then
        PASS_MODE="file"
        prompt_password "Source password" SOURCE_PASS
        prompt_password "Destination password" DEST_PASS
        SOURCE_PASS_FILE="$SECRETS_DIR/${PROFILE_NAME}_source.pass"
        DEST_PASS_FILE="$SECRETS_DIR/${PROFILE_NAME}_destination.pass"
        printf '%s' "$SOURCE_PASS" > "$SOURCE_PASS_FILE"
        printf '%s' "$DEST_PASS" > "$DEST_PASS_FILE"
        chmod 600 "$SOURCE_PASS_FILE" "$DEST_PASS_FILE"
        unset SOURCE_PASS DEST_PASS
    else
        PASS_MODE="prompt"
        SOURCE_PASS_FILE=""
        DEST_PASS_FILE=""
    fi

    save_profile
    print_success "Profile saved"
    pause
}

save_profile() {
    cat > "$CONFIG_DIR/${PROFILE_NAME}.conf" <<EOF
SOURCE_PROVIDER="$SOURCE_PROVIDER"
SOURCE_HOST="$SOURCE_HOST"
SOURCE_PORT="$SOURCE_PORT"
SOURCE_SSL="$SOURCE_SSL"
SOURCE_AUTHUSER="$SOURCE_AUTHUSER"
SOURCE_OPTIONS="$SOURCE_OPTIONS"
DEST_PROVIDER="$DEST_PROVIDER"
DEST_HOST="$DEST_HOST"
DEST_PORT="$DEST_PORT"
DEST_SSL="$DEST_SSL"
DEST_AUTHUSER="$DEST_AUTHUSER"
DEST_OPTIONS="$DEST_OPTIONS"
PASS_MODE="$PASS_MODE"
SOURCE_PASS_FILE="$SOURCE_PASS_FILE"
DEST_PASS_FILE="$DEST_PASS_FILE"
EOF
    chmod 600 "$CONFIG_DIR/${PROFILE_NAME}.conf"
}

load_profile() {
    local name="$1"
    local conf="$CONFIG_DIR/${name}.conf"
    if [ ! -f "$conf" ]; then
        print_error "Profile not found"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$conf"
    PROFILE_NAME="$name"

    if [ "$PASS_MODE" = "prompt" ]; then
        echo ""
        print_info "Profile '$PROFILE_NAME' prompts for passwords."
        prompt_password "Source password" SOURCE_PASS
        prompt_password "Destination password" DEST_PASS
        SESSION_SOURCE_PASS_FILE="$(mktemp)"
        SESSION_DEST_PASS_FILE="$(mktemp)"
        printf '%s' "$SOURCE_PASS" > "$SESSION_SOURCE_PASS_FILE"
        printf '%s' "$DEST_PASS" > "$SESSION_DEST_PASS_FILE"
        chmod 600 "$SESSION_SOURCE_PASS_FILE" "$SESSION_DEST_PASS_FILE"
        unset SOURCE_PASS DEST_PASS
        SOURCE_PASS_FILE="$SESSION_SOURCE_PASS_FILE"
        DEST_PASS_FILE="$SESSION_DEST_PASS_FILE"
        USING_TEMP_PASS_FILES=1
    else
        if [ ! -f "$SOURCE_PASS_FILE" ] || [ ! -f "$DEST_PASS_FILE" ]; then
            print_error "Secrets file missing"
            exit 1
        fi
        USING_TEMP_PASS_FILES=0
    fi
}

edit_profile() {
    clea
    print_header "EDIT PROFILE — $PROFILE_NAME"
    echo ""
    echo "Current settings:"
    echo "  1) Source provider:  $(provider_name "$SOURCE_PROVIDER") ($SOURCE_HOST:$SOURCE_PORT)"
    echo "  2) Source auth user: $SOURCE_AUTHUSER"
    echo "  3) Dest provider:   $(provider_name "$DEST_PROVIDER") ($DEST_HOST:$DEST_PORT)"
    echo "  4) Dest auth user:  $DEST_AUTHUSER"
    echo "  5) Password mode:   $PASS_MODE"
    echo "  6) Update passwords"
    echo "  0) Cancel"
    echo ""
    read -r -p "Edit field (0-6): " edit_choice

    case "$edit_choice" in
        1)
            configure_provider "source"
            save_profile
            print_success "Source provider updated"
            ;;
        2)
            prompt_required "New source auth user" SOURCE_AUTHUSER validate_email
            save_profile
            print_success "Source auth user updated"
            ;;
        3)
            configure_provider "dest"
            save_profile
            print_success "Destination provider updated"
            ;;
        4)
            prompt_required "New destination auth user" DEST_AUTHUSER validate_email
            save_profile
            print_success "Destination auth user updated"
            ;;
        5)
            echo "  1) Store in secrets file"
            echo "  2) Prompt each time"
            read -r -p "Select: " new_mode
            if [ "$new_mode" = "1" ]; then
                PASS_MODE="file"
                prompt_password "Source password" SOURCE_PASS
                prompt_password "Destination password" DEST_PASS
                SOURCE_PASS_FILE="$SECRETS_DIR/${PROFILE_NAME}_source.pass"
                DEST_PASS_FILE="$SECRETS_DIR/${PROFILE_NAME}_destination.pass"
                printf '%s' "$SOURCE_PASS" > "$SOURCE_PASS_FILE"
                printf '%s' "$DEST_PASS" > "$DEST_PASS_FILE"
                chmod 600 "$SOURCE_PASS_FILE" "$DEST_PASS_FILE"
                unset SOURCE_PASS DEST_PASS
            else
                PASS_MODE="prompt"
                rm -f "$SECRETS_DIR/${PROFILE_NAME}_source.pass" "$SECRETS_DIR/${PROFILE_NAME}_destination.pass"
                SOURCE_PASS_FILE=""
                DEST_PASS_FILE=""
            fi
            save_profile
            print_success "Password mode updated"
            ;;
        6)
            if [ "$PASS_MODE" = "file" ]; then
                prompt_password "New source password" SOURCE_PASS
                prompt_password "New destination password" DEST_PASS
                printf '%s' "$SOURCE_PASS" > "$SOURCE_PASS_FILE"
                printf '%s' "$DEST_PASS" > "$DEST_PASS_FILE"
                unset SOURCE_PASS DEST_PASS
                print_success "Passwords updated"
            else
                print_warning "Password mode is 'prompt' — passwords are entered at load time."
            fi
            ;;
        0|*) print_info "Cancelled" ;;
    esac
    pause
}

delete_profile() {
    clea
    print_header "DELETE PROFILE"
    echo ""

    local profiles=()
    while IFS= read -r -d '' f; do
        profiles+=("$(basename "$f" .conf)")
    done < <(find "$CONFIG_DIR" -maxdepth 1 -name "*.conf" -print0 2>/dev/null)

    if [ ${#profiles[@]} -eq 0 ]; then
        print_warning "No profiles found"
        pause
        return
    fi

    echo "Profiles:"
    local i=1
    for p in "${profiles[@]}"; do
        local marker=""
        [ "$p" = "$PROFILE_NAME" ] && marker=" ${YELLOW}(active)${NC}"
        echo -e "  $i) $p$marker"
        ((i++)) || true
    done
    echo "  0) Cancel"
    echo ""
    read -r -p "Select profile to delete: " del_choice

    if ! is_number "$del_choice" || [ "$del_choice" -eq 0 ] || [ "$del_choice" -gt ${#profiles[@]} ]; then
        print_info "Cancelled"
        pause
        return
    fi

    local target="${profiles[$((del_choice-1))]}"
    if [ "$target" = "$PROFILE_NAME" ]; then
        print_error "Cannot delete the active profile. Switch to another profile first."
        pause
        return
    fi

    read -r -p "Confirm delete profile '$target'? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -f "$CONFIG_DIR/${target}.conf"
        rm -f "$SECRETS_DIR/${target}_source.pass" "$SECRETS_DIR/${target}_destination.pass"
        print_success "Profile '$target' deleted"
    else
        print_info "Cancelled"
    fi
    pause
}

export_profile() {
    clea
    print_header "EXPORT PROFILE — $PROFILE_NAME"
    echo ""
    local export_file
    prompt_optional "Export file path" export_file "$BASE_DIR/${PROFILE_NAME}_export.conf"

    {
        echo "# Migration Profile Export: $PROFILE_NAME"
        echo "# Exported: $(date)"
        echo "# Tool Version: $VERSION"
        echo ""
        cat "$CONFIG_DIR/${PROFILE_NAME}.conf"
    } > "$export_file"

    echo ""
    read -r -p "Include passwords in export? (y/n): " inc_pass
    if [[ "$inc_pass" =~ ^[Yy]$ ]] && [ "$PASS_MODE" = "file" ]; then
        {
            echo ""
            echo "# --- Encoded Passwords ---"
            echo "SOURCE_PASS_B64=\"$(base64 < "$SOURCE_PASS_FILE" | tr -d '\n')\""
            echo "DEST_PASS_B64=\"$(base64 < "$DEST_PASS_FILE" | tr -d '\n')\""
        } >> "$export_file"
        chmod 600 "$export_file"
        print_warning "Passwords included — keep this file secure!"
    fi

    print_success "Exported to: $export_file"
    pause
}

import_profile() {
    clea
    print_header "IMPORT PROFILE"
    echo ""
    local import_file
    read -r -p "Import file path: " import_file

    if [ ! -f "$import_file" ]; then
        print_error "File not found"
        pause
        return
    fi

    local new_name
    prompt_required "Profile name for import" new_name
    new_name="${new_name// /_}"

    if [ -f "$CONFIG_DIR/${new_name}.conf" ]; then
        read -r -p "Profile '$new_name' exists. Overwrite? (y/n): " ow
        [[ "$ow" =~ ^[Yy]$ ]] || { print_info "Cancelled"; pause; return; }
    fi

    # Extract only config lines (skip comments and encoded passwords)
    grep -v '^#' "$import_file" | grep -v '^$' | grep -v '_B64=' > "$CONFIG_DIR/${new_name}.conf"
    chmod 600 "$CONFIG_DIR/${new_name}.conf"

    # Handle encoded passwords if present
    local src_b64 dst_b64
    src_b64=$(grep 'SOURCE_PASS_B64=' "$import_file" | cut -d'"' -f2)
    dst_b64=$(grep 'DEST_PASS_B64=' "$import_file" | cut -d'"' -f2)

    if [ -n "$src_b64" ] && [ -n "$dst_b64" ]; then
        echo "$src_b64" | base64 -d > "$SECRETS_DIR/${new_name}_source.pass"
        echo "$dst_b64" | base64 -d > "$SECRETS_DIR/${new_name}_destination.pass"
        chmod 600 "$SECRETS_DIR/${new_name}_source.pass" "$SECRETS_DIR/${new_name}_destination.pass"

        # Update password file paths in the imported config
        sed -i "s|SOURCE_PASS_FILE=.*|SOURCE_PASS_FILE=\"$SECRETS_DIR/${new_name}_source.pass\"|" "$CONFIG_DIR/${new_name}.conf"
        sed -i "s|DEST_PASS_FILE=.*|DEST_PASS_FILE=\"$SECRETS_DIR/${new_name}_destination.pass\"|" "$CONFIG_DIR/${new_name}.conf"
        print_success "Imported with passwords"
    else
        print_success "Imported (no passwords — will prompt)"
    fi
    pause
}

manage_profiles() {
    clea
    print_header "PROFILE MANAGEMENT"
    echo ""
    echo "  Active: ${BOLD}$PROFILE_NAME${NC}"
    echo ""
    echo "  1) Switch profile"
    echo "  2) Create new profile"
    echo "  3) Edit current profile"
    echo "  4) Delete a profile"
    echo "  5) Export current profile"
    echo "  6) Import profile"
    echo "  0) Back"
    echo ""
    read -r -p "Select (0-6): " pm_choice

    case "$pm_choice" in
        1) cleanup_session_secrets; select_or_create_profile ;;
        2) create_profile ;;
        3) edit_profile ;;
        4) delete_profile ;;
        5) export_profile ;;
        6) import_profile ;;
        0) return ;;
        *) print_error "Invalid"; sleep 1 ;;
    esac
}

# ============================================
# CLEANUP
# ============================================
cleanup_session_secrets() {
    if [ "${USING_TEMP_PASS_FILES:-0}" = "1" ]; then
        shred -u "$SESSION_SOURCE_PASS_FILE" "$SESSION_DEST_PASS_FILE" 2>/dev/null \
            || rm -f "$SESSION_SOURCE_PASS_FILE" "$SESSION_DEST_PASS_FILE"
    fi
}
trap cleanup_session_secrets EXIT

# ============================================
# MIGRATION OPTIONS (folder filters, throttle)
# ============================================
prompt_migration_options() {
    FOLDER_INCLUDES=()
    FOLDER_EXCLUDES=()
    THROTTLE_BPS="0"

    echo ""
    print_subheader "Migration Options"
    read -r -p "Configure folder filters? (y/n) [n]: " do_filters
    if [[ "$do_filters" =~ ^[Yy]$ ]]; then
        echo ""
        print_info "Enter folder INCLUDE patterns (regex, blank to finish):"
        print_info "  Example: ^INBOX$ or ^Sent"
        while true; do
            read -r -p "  include> " pat
            [ -z "$pat" ] && break
            FOLDER_INCLUDES+=("$pat")
        done

        echo ""
        print_info "Enter folder EXCLUDE patterns (regex, blank to finish):"
        print_info "  Example: ^Trash$ or ^Spam or ^\\[Gmail\\]/All Mail"
        while true; do
            read -r -p "  exclude> " pat
            [ -z "$pat" ] && break
            FOLDER_EXCLUDES+=("$pat")
        done

        [ ${#FOLDER_INCLUDES[@]} -gt 0 ] && print_info "Includes: ${FOLDER_INCLUDES[*]}"
        [ ${#FOLDER_EXCLUDES[@]} -gt 0 ] && print_info "Excludes: ${FOLDER_EXCLUDES[*]}"
    fi

    read -r -p "Set bandwidth throttle? (y/n) [n]: " do_throttle
    if [[ "$do_throttle" =~ ^[Yy]$ ]]; then
        prompt_optional "Max bytes per second (0=unlimited)" THROTTLE_BPS "0"
    fi
}

build_extra_args() {
    local -n _args=$1
    local pat

    for pat in "${FOLDER_INCLUDES[@]}"; do
        _args+=("--include" "$pat")
    done
    for pat in "${FOLDER_EXCLUDES[@]}"; do
        _args+=("--exclude" "$pat")
    done
    if [ "$THROTTLE_BPS" != "0" ] && is_number "$THROTTLE_BPS"; then
        _args+=("--maxbytespersecond" "$THROTTLE_BPS")
    fi
}

# ============================================
# IMAPSYNC WRAPPER
# ============================================
run_imapsync() {
    local user1="$1" user2="$2" log_file="$3" quiet="${4:-0}"; shift 3
    [ "$1" = "--quiet" ] && { quiet=1; shift; }

    local timeout_secs="0"
    local extra_args=()

    while [ $# -gt 0 ]; do
        if [ "$1" = "--timeout" ]; then
            timeout_secs="$2"
            shift 2
        else
            extra_args+=("$1")
            shift
        fi
    done

    local cmd=()
    [ "$timeout_secs" != "0" ] && is_number "$timeout_secs" && cmd+=("timeout" "$timeout_secs")
    cmd+=("$IMAPSYNC_BIN")

    [ -n "$SOURCE_SSL" ] && cmd+=("$SOURCE_SSL")
    cmd+=("--host1" "$SOURCE_HOST")
    [ -n "$SOURCE_PORT" ] && cmd+=("--port1" "$SOURCE_PORT")
    cmd+=("--user1" "$user1")
    cmd+=("--authuser1" "$SOURCE_AUTHUSER")
    cmd+=("--passfile1" "$SOURCE_PASS_FILE")
    [ -n "$SOURCE_OPTIONS" ] && cmd+=("$SOURCE_OPTIONS")

    [ -n "$DEST_SSL" ] && cmd+=("$DEST_SSL")
    cmd+=("--host2" "$DEST_HOST")
    [ -n "$DEST_PORT" ] && cmd+=("--port2" "$DEST_PORT")
    cmd+=("--user2" "$user2")
    cmd+=("--authuser2" "$DEST_AUTHUSER")
    cmd+=("--passfile2" "$DEST_PASS_FILE")
    [ -n "$DEST_OPTIONS" ] && cmd+=("$DEST_OPTIONS")

    cmd+=("--nosyncacls" "--subscribe" "--syncinternaldates")
    cmd+=("${extra_args[@]}")

    if [ "$quiet" = "1" ]; then
        "${cmd[@]}" > "$log_file" 2>&1
    else
        "${cmd[@]}" 2>&1 | tee "$log_file"
    fi
    return "${PIPESTATUS[0]}"
}

# ============================================
# ZIMBRA / Zextras Carbonio HELPERS (Optional)
# ============================================
have_zmprov() { command -v zmprov >/dev/null 2>&1; }

check_user_exists() {
    have_zmprov && zmprov -l ga "$1" &>/dev/null
}

get_mailbox_size() {
    have_zmprov || { echo 0; return; }
    zmprov -l ga "$1" 2>/dev/null | grep "zimbraMailTotalSize:" | cut -d' ' -f2
}

human_readable_size() {
    local bytes="${1:-0}"
    if [ "$bytes" -gt 1073741824 ] 2>/dev/null; then
        echo "$(echo "scale=2; $bytes/1073741824" | bc) GB"
    elif [ "$bytes" -gt 1048576 ] 2>/dev/null; then
        echo "$(echo "scale=2; $bytes/1048576" | bc) MB"
    elif [ "$bytes" -gt 1024 ] 2>/dev/null; then
        echo "$(echo "scale=2; $bytes/1024" | bc) KB"
    else
        echo "${bytes:-0} bytes"
    fi
}

# ============================================
# 1. SINGLE USER MIGRATION
# ============================================
migrate_single_user() {
    clea
    print_header "SINGLE USER MIGRATION — $PROFILE_NAME"
    echo ""
    print_info "Source: $(provider_name "$SOURCE_PROVIDER") ($SOURCE_HOST)"
    print_info "Destination: $(provider_name "$DEST_PROVIDER") ($DEST_HOST)"
    echo ""

    prompt_required "Source email (FROM)" SOURCE_EMAIL validate_email
    prompt_required "Destination email (TO)" DEST_EMAIL validate_email

    prompt_migration_options

    echo ""
    print_info "Migrating: $SOURCE_EMAIL -> $DEST_EMAIL"
    read -r -p "Continue? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { print_info "Cancelled"; pause; return; }

    local timeout_secs
    while true; do
        prompt_optional "Timeout seconds (0=no timeout)" timeout_secs "0"
        if [ "$timeout_secs" -ge 0 ] 2>/dev/null; then
            break
        else
            print_error "Timeout must be >= 0"
        fi
    done

    LOG_FILE=$(generate_logname "single_${SOURCE_EMAIL}_to_${DEST_EMAIL}")
    echo ""
    print_info "Running imapsync..."
    echo ""

    local migration_extra=()
    build_extra_args migration_extra

    run_imapsync "$SOURCE_EMAIL" "$DEST_EMAIL" "$LOG_FILE" \
        --timeout "$timeout_secs" "${migration_extra[@]}"
    EXIT_CODE=$?

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$EXIT_CODE" -eq 0 ]; then
        print_success "Migration completed!"
        echo "Log: $LOG_FILE"
        echo ""
        print_subheader "Summary"
        grep -E "Messages transferred|Messages skipped|Total bytes transferred" "$LOG_FILE" | tail -3
    else
        print_error "Migration failed (Exit: $EXIT_CODE)"
        echo "Log: $LOG_FILE"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    pause
}

# ============================================
# 2. BATCH MIGRATION
# ============================================
batch_migrate() {
    clea
    print_header "BATCH MIGRATION — $PROFILE_NAME"
    echo ""
    echo "Available user list files:"
    echo "─────────────────────────"
    while IFS= read -r -d '' file; do
        local count
        count=$(grep -vc '^#\|^$' "$file" 2>/dev/null || echo 0)
        echo "  $(basename "$file") - $count users"
    done < <(find "$USER_LISTS_DIR" -maxdepth 1 -name "*.txt" -type f -print0 2>/dev/null)
    echo ""
    echo "Options:"
    echo "  1) Use existing source email list"
    echo "  2) Create new source email list"
    echo "  3) Use mapping file (source:dest pairs)"
    echo "  0) Cancel"
    read -r -p "Select (0-3): " BATCH_OPTION

    local USER_FILE="" MAPPING_FILE=""
    case $BATCH_OPTION in
        0) print_info "Cancelled"; pause; return ;;
        1)
            read -r -p "Enter filename: " uf
            USER_FILE="$USER_LISTS_DIR/$uf"
            [ -f "$USER_FILE" ] || { print_error "File not found"; pause; return; }
            ;;
        2)
            read -r -p "Enter new filename: " nf
            USER_FILE="$USER_LISTS_DIR/${nf}.txt"
            echo "Enter emails (blank line to finish):"
            : > "$USER_FILE"
            while true; do
                read -r -p "> " line
                [ -z "$line" ] && break
                validate_email "$line" && echo "$line" >> "$USER_FILE" || print_warning "Skipped invalid: $line"
            done
            [ -s "$USER_FILE" ] || { print_error "No valid users"; rm -f "$USER_FILE"; pause; return; }
            print_success "Created: $USER_FILE"
            ;;
        3)
            read -r -p "Enter mapping file path: " MAPPING_FILE
            [ -f "$MAPPING_FILE" ] || { print_error "File not found"; pause; return; }
            ;;
        *) print_error "Invalid"; pause; return ;;
    esac

    local LIST_FILE
    LIST_FILE="$(mktemp)"
    local SKIPPED=0

    if [ -n "$MAPPING_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            if validate_mapping_line "$line"; then
                echo "$line" >> "$LIST_FILE"
            else
                print_warning "Skipped invalid: $line"
                SKIPPED=$((SKIPPED + 1))
            fi
        done < "$MAPPING_FILE"
    else
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            if validate_email "$line"; then
                echo "$line:$line" >> "$LIST_FILE"
            else
                print_warning "Skipped invalid: $line"
                SKIPPED=$((SKIPPED + 1))
            fi
        done < "$USER_FILE"
    fi

    TOTAL_USERS=$(wc -l < "$LIST_FILE")
    if [ "$TOTAL_USERS" -eq 0 ]; then
        print_error "No valid entries ($SKIPPED skipped)"
        rm -f "$LIST_FILE"
        pause
        return
    fi
    [ "$SKIPPED" -gt 0 ] && print_warning "$SKIPPED invalid entries skipped"
    print_info "Found $TOTAL_USERS valid migrations"

    prompt_migration_options

    read -r -p "Continue? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { print_info "Cancelled"; rm -f "$LIST_FILE"; pause; return; }

    local timeout_secs
    while true; do
        prompt_optional "Per-user timeout seconds" timeout_secs "0"
        [ "$timeout_secs" -ge 0 ] 2>/dev/null && break
        print_error "Timeout must be >= 0"
    done

    # Retry options
    local max_retries retry_delay
    prompt_optional "Max retries per user on failure (0=no retry)" max_retries "0"
    if [ "$max_retries" -gt 0 ] 2>/dev/null; then
        prompt_optional "Initial retry delay seconds" retry_delay "5"
    else
        max_retries=0
        retry_delay=0
    fi

    # Parallel migration option
    local max_parallel
    prompt_optional "Parallel jobs (1=sequential)" max_parallel "1"
    is_number "$max_parallel" || max_parallel=1
    [ "$max_parallel" -lt 1 ] && max_parallel=1
    [ "$max_parallel" -gt 20 ] && { print_warning "Capping at 20 parallel jobs"; max_parallel=20; }

    local migration_extra=()
    build_extra_args migration_extra

    REPORT_FILE="$REPORT_DIR/batch_report_$(get_timestamp).txt"
    local SUCCESS_COUNT=0 FAIL_COUNT=0
    local -a FAILED_USERS=()

    {
        echo "Batch Report - $(date)"
        echo "Profile: $PROFILE_NAME"
        echo "Started: $(date)"
        echo "Parallel: $max_parallel  Retries: $max_retries"
        echo ""
        echo "RESULTS:"
        echo "────────"
    } > "$REPORT_FILE"

    # Trap SIGINT during batch to write partial report
    local batch_interrupted=0
    batch_cleanup() {
        batch_interrupted=1
        echo ""
        print_warning "Interrupted! Writing partial report..."
        {
            echo ""
            echo "INTERRUPTED AT: $(date)"
            echo "Completed: $((SUCCESS_COUNT + FAIL_COUNT))/$TOTAL_USERS"
            echo "Success: $SUCCESS_COUNT"
            echo "Failed: $FAIL_COUNT"
        } >> "$REPORT_FILE"
        rm -f "$LIST_FILE"
    }
    trap batch_cleanup INT

    echo ""
    print_info "Starting batch migration..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local batch_start_time
    batch_start_time=$(date +%s)

    if [ "$max_parallel" -gt 1 ]; then
        # ── Parallel migration ──
        local results_file
        results_file=$(mktemp)
        local sem_fifo
        sem_fifo=$(mktemp -u)
        mkfifo "$sem_fifo"
        exec 3<>"$sem_fifo"
        rm -f "$sem_fifo"

        # Seed semaphore with tokens
        local t
        for ((t=0; t<max_parallel; t++)); do
            printf '\n' >&3
        done

        local -a pids=()
        local job_count=0

        while IFS=: read -r src dst || [ -n "$src" ]; do
            [ -z "$src" ] && continue
            dst="${dst:-$src}"

            read -u 3  # Acquire semaphore (blocks if full)

            (
                local log attempt=0 success=false delay=$retry_delay
                log=$(generate_logname "batch_${src}_to_${dst}")

                while [ "$attempt" -le "$max_retries" ]; do
                    if [ "$attempt" -gt 0 ]; then
                        sleep "$delay"
                        delay=$((delay * 2))
                    fi

                    run_imapsync "$src" "$dst" "$log" --quiet \
                        --timeout "$timeout_secs" "${migration_extra[@]}"
                    if [ $? -eq 0 ]; then
                        success=true
                        break
                    fi
                    attempt=$((attempt + 1))
                done

                if $success; then
                    echo "SUCCESS:$src:$dst" >> "$results_file"
                else
                    echo "FAILED:$src:$dst" >> "$results_file"
                fi

                printf '\n' >&3  # Release semaphore
            ) &
            pids+=($!)
            job_count=$((job_count + 1))

            echo -ne "\r  Launched: $job_count/$TOTAL_USERS jobs (max parallel: $max_parallel) "
        done < "$LIST_FILE"

        echo ""
        print_info "All jobs launched. Waiting for completion..."

        # Wait for all background jobs
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null
        done
        exec 3>&-  # Close semaphore FD

        # Process results
        while IFS=: read -r status src dst; do
            if [ "$status" = "SUCCESS" ]; then
                print_success "✓ $src -> $dst"
                echo "SUCCESS: $src -> $dst" >> "$REPORT_FILE"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                print_error "✗ $src -> $dst"
                echo "FAILED: $src -> $dst" >> "$REPORT_FILE"
                FAILED_USERS+=("$src:$dst")
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        done < "$results_file"
        rm -f "$results_file"

    else
        # ── Sequential migration ──
        while IFS=: read -r SOURCE_EMAIL DEST_EMAIL || [ -n "$SOURCE_EMAIL" ]; do
            [ -z "$SOURCE_EMAIL" ] && continue
            [ "$batch_interrupted" = "1" ] && break
            DEST_EMAIL="${DEST_EMAIL:-$SOURCE_EMAIL}"

            echo ""
            print_info "Migrating: $SOURCE_EMAIL -> $DEST_EMAIL"
            LOG_FILE=$(generate_logname "batch_${SOURCE_EMAIL}_to_${DEST_EMAIL}")

            local attempt=0 success=false delay=$retry_delay

            while [ "$attempt" -le "$max_retries" ]; do
                if [ "$attempt" -gt 0 ]; then
                    print_warning "Retry $attempt/$max_retries (waiting ${delay}s)..."
                    sleep "$delay"
                    delay=$((delay * 2))
                fi

                run_imapsync "$SOURCE_EMAIL" "$DEST_EMAIL" "$LOG_FILE" \
                    --timeout "$timeout_secs" "${migration_extra[@]}"
                EXIT_CODE=$?

                if [ "$EXIT_CODE" -eq 0 ]; then
                    success=true
                    break
                fi
                attempt=$((attempt + 1))
            done

            if $success; then
                print_success "✓ $SOURCE_EMAIL -> $DEST_EMAIL"
                echo "SUCCESS: $SOURCE_EMAIL -> $DEST_EMAIL" >> "$REPORT_FILE"
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                print_error "✗ $SOURCE_EMAIL -> $DEST_EMAIL (Exit: $EXIT_CODE)"
                echo "FAILED: $SOURCE_EMAIL -> $DEST_EMAIL (Exit: $EXIT_CODE)" >> "$REPORT_FILE"
                FAILED_USERS+=("$SOURCE_EMAIL:$DEST_EMAIL")
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi

            show_progress "$((SUCCESS_COUNT + FAIL_COUNT))" "$TOTAL_USERS" "$batch_start_time"
            echo ""
        done < "$LIST_FILE"
    fi

    # Restore default trap
    trap cleanup_session_secrets EXIT
    trap - INT

    {
        echo ""
        echo "SUMMARY:"
        echo "────────────────"
        echo "Total: $TOTAL_USERS"
        echo "Success: $SUCCESS_COUNT"
        echo "Failed: $FAIL_COUNT"
        echo "Completed: $(date)"
        local batch_elapsed=$(( $(date +%s) - batch_start_time ))
        echo "Duration: $(printf '%02d:%02d:%02d' $((batch_elapsed/3600)) $(((batch_elapsed%3600)/60)) $((batch_elapsed%60)))"
    } >> "$REPORT_FILE"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_subheader "Batch Complete"
    print_success "Successful: $SUCCESS_COUNT"
    [ "$FAIL_COUNT" -gt 0 ] && print_error "Failed: $FAIL_COUNT" || print_info "Failed: 0"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo ""
        print_warning "Failed migrations:"
        printf '  %s\n' "${FAILED_USERS[@]}"
        echo ""
        print_info "Use option 5 to resume failed"
    fi
    print_info "Report: $REPORT_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    rm -f "$LIST_FILE"
    pause
}

# ============================================
# 3. CHECK STATUS
# ============================================
check_status() {
    clea
    print_header "MIGRATION STATUS CHECK — $PROFILE_NAME"

    if [ "$DEST_PROVIDER" != "2" ]; then
        print_warning "Status check works best for Zimbra destinations"
        print_info "Current destination: $(provider_name "$DEST_PROVIDER")"
        print_info "Please check your destination mailbox directly."
        echo ""
    fi

    prompt_required "Destination email to check" USER_EMAIL validate_email
    echo ""
    print_subheader "Checking: $USER_EMAIL"
    echo ""

    if have_zmprov; then
        if check_user_exists "$USER_EMAIL"; then
            print_success "✓ User exists on Zimbra"
            echo ""
            print_subheader "User Details"
            SIZE=$(get_mailbox_size "$USER_EMAIL")
            echo "Mailbox Size: $(human_readable_size "$SIZE")"
            LAST_LOGIN=$(zmprov -l ga "$USER_EMAIL" 2>/dev/null | grep "zimbraLastLogonTimestamp:" | cut -d' ' -f2)
            echo "Last Login: ${LAST_LOGIN:-Never}"
            STATUS=$(zmprov -l ga "$USER_EMAIL" 2>/dev/null | grep "zimbraAccountStatus:" | cut -d' ' -f2)
            echo "Account Status: ${STATUS:-unknown}"
            QUOTA=$(zmprov -l ga "$USER_EMAIL" 2>/dev/null | grep "zimbraMailQuota:" | cut -d' ' -f2)
            echo "Mail Quota: $([ -n "$QUOTA" ] && human_readable_size "$QUOTA" || echo Unlimited)"
        else
            print_error "✗ User NOT found"
        fi
    else
        print_warning "zmprov not found — skipping Zimbra check"
    fi

    echo ""
    print_subheader "Migration Logs"
    local safe_email
    safe_email=$(echo "$USER_EMAIL" | sed 's/[.@]/[.@]/g')
    LOG_FILES=$(find "$LOG_DIR" -name "*${USER_EMAIL}*.log" -type f 2>/dev/null | sort -r)
    if [ -n "$LOG_FILES" ]; then
        echo "Found logs:"
        echo ""
        echo "$LOG_FILES" | head -5 | while read -r file; do
            local status
            status=$(grep "return value" "$file" 2>/dev/null | head -1)
            echo "  📁 $(basename "$file")"
            echo "     Status: ${status:-No result}"
        done
        echo ""
        read -r -p "View latest log? (y/n): " VIEW_LOG
        if [[ "$VIEW_LOG" =~ ^[Yy]$ ]]; then
            LATEST_LOG=$(echo "$LOG_FILES" | head -1)
            echo ""
            print_subheader "Latest Log"
            echo "─────────────────────────────────────────────────"
            tail -30 "$LATEST_LOG"
        fi
    else
        print_warning "No logs found for this user"
    fi
    pause
}

# ============================================
# 4. VERIFY SYNC
# ============================================
verify_sync() {
    clea
    print_header "VERIFY SYNC — $PROFILE_NAME"
    echo ""
    prompt_required "Source email" SOURCE_EMAIL validate_email
    prompt_required "Destination email" DEST_EMAIL validate_email

    prompt_migration_options

    print_info "Verifying: $SOURCE_EMAIL -> $DEST_EMAIL"
    echo ""
    echo "Running dry run..."
    echo ""
    VERIFY_LOG=$(generate_logname "verify_${SOURCE_EMAIL}_to_${DEST_EMAIL}")

    local verify_extra=()
    build_extra_args verify_extra

    run_imapsync "$SOURCE_EMAIL" "$DEST_EMAIL" "$VERIFY_LOG" --dry "${verify_extra[@]}"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_subheader "Verification Results"
    echo ""
    grep -E "Nb messages|Total size|Biggest message|Messages transferred" "$VERIFY_LOG" | head -20
    echo ""
    echo "Log: $VERIFY_LOG"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    pause
}

# ============================================
# 5. RESUME FAILED
# ============================================
resume_failed() {
    clea
    print_header "RESUME FAILED — $PROFILE_NAME"
    echo ""
    REPORTS=$(find "$REPORT_DIR" -name "batch_report_*.txt" -type f 2>/dev/null | sort -r)
    if [ -z "$REPORTS" ]; then
        print_error "No reports found"
        pause
        return
    fi

    echo "Available reports:"
    echo "──────────────────"
    local i=1
    declare -A REPORT_MAP
    while IFS= read -r report; do
        local total failed
        total=$(grep -c "^SUCCESS:" "$report" 2>/dev/null || echo 0)
        failed=$(grep -c "^FAILED:" "$report" 2>/dev/null || echo 0)
        echo "  $i) $(basename "$report") (Success: $total, Failed: $failed)"
        REPORT_MAP[$i]="$report"
        i=$((i + 1))
    done <<< "$REPORTS"

    echo ""
    read -r -p "Select report (1-$((i-1))): " SELECTION
    if [ -z "${REPORT_MAP[$SELECTION]:-}" ]; then
        print_error "Invalid selection"
        pause
        return
    fi
    REPORT_FILE="${REPORT_MAP[$SELECTION]}"
    print_info "Using: $(basename "$REPORT_FILE")"

    # Robust parsing: extract source and dest from "FAILED: src -> dst (Exit: N)"
    mapfile -t FAILED_MIGRATIONS < <(
        grep "^FAILED:" "$REPORT_FILE" | awk '{
            # Remove "FAILED: " prefix, extract "src -> dst"
            sub(/^FAILED:[[:space:]]*/, "")
            # Split on " -> " and take first two fields
            split($0, parts, / -> /)
            src = parts[1]
            # Remove trailing " (Exit: ...)" from dst
            dst = parts[2]
            sub(/ \(Exit:.*$/, "", dst)
            print src ":" dst
        }'
    )

    if [ ${#FAILED_MIGRATIONS[@]} -eq 0 ]; then
        print_success "No failed migrations"
        pause
        return
    fi

    echo ""
    print_warning "Found ${#FAILED_MIGRATIONS[@]} failed migrations"
    local display_count=${#FAILED_MIGRATIONS[@]}
    [ "$display_count" -gt 20 ] && display_count=20
    printf '  %s\n' "${FAILED_MIGRATIONS[@]:0:$display_count}"
    [ ${#FAILED_MIGRATIONS[@]} -gt 20 ] && echo "... and $((${#FAILED_MIGRATIONS[@]} - 20)) more"
    echo ""

    read -r -p "Resume? (y/n): " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { print_info "Cancelled"; pause; return; }

    # Retry options for resume
    local max_retries retry_delay
    prompt_optional "Max retries per user (0=no retry)" max_retries "0"
    is_number "$max_retries" || max_retries=0
    if [ "$max_retries" -gt 0 ]; then
        prompt_optional "Initial retry delay seconds" retry_delay "5"
    else
        retry_delay=0
    fi

    RESUME_REPORT="$REPORT_DIR/resume_report_$(get_timestamp).txt"
    local SUCCESS_COUNT=0 FAIL_COUNT=0
    {
        echo "Resume Report - $(date)"
        echo "Profile: $PROFILE_NAME"
        echo "Original: $(basename "$REPORT_FILE")"
        echo ""
    } > "$RESUME_REPORT"

    echo ""
    print_info "Resuming..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local resume_start_time
    resume_start_time=$(date +%s)

    for MIGRATION in "${FAILED_MIGRATIONS[@]}"; do
        local src_email dst_email
        src_email="${MIGRATION%%:*}"
        dst_email="${MIGRATION#*:}"

        [ -z "$src_email" ] && continue

        echo ""
        print_info "Retrying: $src_email -> $dst_email"
        LOG_FILE=$(generate_logname "resume_${src_email}_to_${dst_email}")

        local attempt=0 success=false delay=$retry_delay

        while [ "$attempt" -le "$max_retries" ]; do
            if [ "$attempt" -gt 0 ]; then
                print_warning "Retry $attempt/$max_retries (waiting ${delay}s)..."
                sleep "$delay"
                delay=$((delay * 2))
            fi

            run_imapsync "$src_email" "$dst_email" "$LOG_FILE"
            if [ $? -eq 0 ]; then
                success=true
                break
            fi
            attempt=$((attempt + 1))
        done

        if $success; then
            print_success "✓ $src_email -> $dst_email"
            echo "SUCCESS: $src_email -> $dst_email" >> "$RESUME_REPORT"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            print_error "✗ $src_email -> $dst_email - FAILED AGAIN"
            echo "FAILED: $src_email -> $dst_email" >> "$RESUME_REPORT"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi

        show_progress "$((SUCCESS_COUNT + FAIL_COUNT))" "${#FAILED_MIGRATIONS[@]}" "$resume_start_time"
        echo ""
    done

    {
        echo ""
        echo "SUMMARY:"
        echo "────────────────"
        echo "Total: ${#FAILED_MIGRATIONS[@]}"
        echo "Success: $SUCCESS_COUNT"
        echo "Failed: $FAIL_COUNT"
        echo "Completed: $(date)"
    } >> "$RESUME_REPORT"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_subheader "Resume Complete"
    print_success "Success: $SUCCESS_COUNT"
    [ "$FAIL_COUNT" -gt 0 ] && print_error "Failed: $FAIL_COUNT" || print_info "Failed: 0"
    print_info "Report: $RESUME_REPORT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    pause
}

# ============================================
# 6. MANAGE USER LISTS
# ============================================
manage_user_lists() {
    clea
    print_header "USER LIST MANAGEMENT — $PROFILE_NAME"
    echo ""
    echo "Current lists:"
    echo "───────────────────"
    if [ -n "$(ls -A "$USER_LISTS_DIR" 2>/dev/null)" ]; then
        while IFS= read -r -d '' file; do
            local count
            count=$(grep -vc '^#\|^$' "$file" 2>/dev/null || echo 0)
            echo "  📄 $(basename "$file") - $count entries"
        done < <(find "$USER_LISTS_DIR" -maxdepth 1 -name "*.txt" -type f -print0 2>/dev/null)
    else
        echo "  No lists found"
    fi
    echo ""
    echo "Options:"
    echo "  1) Create source email list"
    echo "  2) Create mapping file (source:dest)"
    echo "  3) View file contents"
    echo "  4) Delete file"
    echo "  5) Import from file path"
    echo "  0) Back"
    read -r -p "Select (0-5): " LIST_OPTION

    case $LIST_OPTION in
        0) return ;;
        1)
            read -r -p "Filename: " nl
            local USER_FILE="$USER_LISTS_DIR/${nl}.txt"
            echo "Enter emails (blank line to finish):"
            : > "$USER_FILE"
            while true; do
                read -r -p "> " line
                [ -z "$line" ] && break
                validate_email "$line" && echo "$line" >> "$USER_FILE" || print_warning "Skipped invalid: $line"
            done
            [ -s "$USER_FILE" ] && print_success "Created $(wc -l < "$USER_FILE") entries" || { print_error "No entries"; rm -f "$USER_FILE"; }
            ;;
        2)
            read -r -p "Filename: " nl
            local MAP_FILE="$USER_LISTS_DIR/${nl}.txt"
            echo "Enter source:dest pairs (blank line to finish):"
            : > "$MAP_FILE"
            while true; do
                read -r -p "> " line
                [ -z "$line" ] && break
                if validate_mapping_line "$line"; then
                    echo "$line" >> "$MAP_FILE"
                else
                    print_warning "Skipped invalid: $line (format: email:email)"
                fi
            done
            [ -s "$MAP_FILE" ] && print_success "Created $(wc -l < "$MAP_FILE") mappings" || { print_error "No mappings"; rm -f "$MAP_FILE"; }
            ;;
        3)
            read -r -p "Filename: " vf
            local VIEW_FILE="$USER_LISTS_DIR/$vf"
            if [ -f "$VIEW_FILE" ]; then
                echo ""
                cat -n "$VIEW_FILE"
                echo ""
                print_info "Total: $(grep -vc '^#\|^$' "$VIEW_FILE" 2>/dev/null || echo 0)"
            else
                print_error "Not found"
            fi
            ;;
        4)
            read -r -p "Filename: " df
            local DEL_FILE="$USER_LISTS_DIR/$df"
            if [ -f "$DEL_FILE" ]; then
                read -r -p "Confirm delete? (y/n): " CONFIRM
                [[ "$CONFIRM" =~ ^[Yy]$ ]] && rm -f "$DEL_FILE" && print_success "Deleted" || print_info "Cancelled"
            else
                print_error "Not found"
            fi
            ;;
        5)
            read -r -p "Source file path: " IMPORT_FILE
            if [ ! -f "$IMPORT_FILE" ]; then
                print_error "Not found"
            else
                read -r -p "Target filename: " tn
                cp "$IMPORT_FILE" "$USER_LISTS_DIR/${tn}.txt"
                print_success "Imported $(grep -vc '^#\|^$' "$USER_LISTS_DIR/${tn}.txt" 2>/dev/null || echo 0) entries"
            fi
            ;;
        *) print_error "Invalid" ;;
    esac
    pause
}

# ============================================
# 7. VIEW REPORTS
# ============================================
view_reports() {
    clea
    print_header "VIEW REPORTS — $PROFILE_NAME"
    echo ""
    REPORTS=$(find "$REPORT_DIR" -name "*.txt" -type f 2>/dev/null | sort -r)
    if [ -z "$REPORTS" ]; then
        echo "  No reports found"
        pause
        return
    fi

    echo "Available reports:"
    echo "──────────────────"
    local i=1
    declare -A REPORT_MAP
    while IFS= read -r report; do
        echo "  $i) $(basename "$report") ($(wc -l < "$report") lines)"
        REPORT_MAP[$i]="$report"
        i=$((i + 1))
    done <<< "$REPORTS"

    echo ""
    read -r -p "Select (0 to cancel): " SEL
    [[ "$SEL" =~ ^[0-9]+$ ]] || { print_error "Invalid"; pause; return; }
    [ "$SEL" -eq 0 ] && return
    if [ -z "${REPORT_MAP[$SEL]:-}" ]; then
        print_error "Invalid selection"
        pause
        return
    fi
    REPORT_FILE="${REPORT_MAP[$SEL]}"
    echo ""
    echo "─────────────────────────────────────────────────"
    echo "File: $(basename "$REPORT_FILE")"
    echo "─────────────────────────────────────────────────"
    cat "$REPORT_FILE"
    echo "─────────────────────────────────────────────────"
    pause
}

# ============================================
# 8. LOG CLEANUP
# ============================================
log_cleanup() {
    clea
    print_header "LOG CLEANUP — $PROFILE_NAME"
    echo ""

    # Count and show disk usage
    local log_count log_size
    log_count=$(find "$LOG_DIR" -name "*.log" -type f 2>/dev/null | wc -l)
    log_size=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)

    print_info "Log directory: $LOG_DIR"
    print_info "Total logs: $log_count"
    print_info "Disk usage: ${log_size:-0}"
    echo ""

    if [ "$log_count" -eq 0 ]; then
        print_info "No logs to clean up."
        pause
        return
    fi

    echo "Options:"
    echo "  1) Delete logs older than N days"
    echo "  2) Delete all logs"
    echo "  3) Delete logs for specific user"
    echo "  4) Show largest log files"
    echo "  0) Cancel"
    read -r -p "Select (0-4): " cleanup_choice

    case "$cleanup_choice" in
        1)
            local days
            prompt_required "Delete logs older than (days)" days is_numbe
            local old_count
            old_count=$(find "$LOG_DIR" -name "*.log" -type f -mtime +"$days" 2>/dev/null | wc -l)
            if [ "$old_count" -eq 0 ]; then
                print_info "No logs older than $days days."
            else
                print_warning "Found $old_count logs older than $days days"
                read -r -p "Delete them? (y/n): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    find "$LOG_DIR" -name "*.log" -type f -mtime +"$days" -delete
                    print_success "Deleted $old_count logs"
                else
                    print_info "Cancelled"
                fi
            fi
            ;;
        2)
            read -r -p "Delete ALL $log_count logs? (y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                find "$LOG_DIR" -name "*.log" -type f -delete
                print_success "All logs deleted"
            else
                print_info "Cancelled"
            fi
            ;;
        3)
            local email
            prompt_required "Email address" email validate_email
            local user_logs
            user_logs=$(find "$LOG_DIR" -name "*${email}*.log" -type f 2>/dev/null | wc -l)
            if [ "$user_logs" -eq 0 ]; then
                print_info "No logs found for $email"
            else
                print_warning "Found $user_logs logs for $email"
                read -r -p "Delete them? (y/n): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    find "$LOG_DIR" -name "*${email}*.log" -type f -delete
                    print_success "Deleted $user_logs logs"
                else
                    print_info "Cancelled"
                fi
            fi
            ;;
        4)
            echo ""
            print_subheader "Top 10 Largest Logs"
            find "$LOG_DIR" -name "*.log" -type f -printf '%s %p\n' 2>/dev/null \
                | sort -rn | head -10 | while read -r size file; do
                    echo "  $(human_readable_size "$size")  $(basename "$file")"
                done
            ;;
        0) return ;;
        *) print_error "Invalid" ;;
    esac
    pause
}

# ============================================
# CLI HELP & VERSION
# ============================================
show_help() {
    cat <<'HELPTEXT'
Universal IMAP Email Migration Tool

Usage:
  sync.sh [OPTIONS]

Options:
  --help, -h        Show this help message
  --version, -v     Show version information
  --profile NAME    Load a specific profile and skip the profile selection menu

Description:
  Interactive tool for migrating email via IMAP using imapsync.
  Supports Gmail, Zimbra, Zextras Carbonio, Outlook/Office 365, Yahoo, and any IMAP server.

Features:
  • Single-user and batch migration
  • Migration verification (dry run)
  • Resume failed migrations with retry + backoff
  • Parallel batch migration
  • Folder include/exclude filters
  • Bandwidth throttling
  • Profile management (create, edit, delete, export, import)
  • Log rotation and cleanup
  • Progress tracking with ETA

Requirements:
  • Bash 4.0+
  • imapsync
  • bc
  • Root privileges

Examples:
  sudo ./sync.sh                       # Interactive mode
  sudo ./sync.sh --profile myprofile   # Load specific profile
  sudo ./sync.sh --help                # Show help
HELPTEXT
}

# ============================================
# MAIN MENU
# ============================================
show_menu() {
    clea
    print_header "UNIVERSAL EMAIL MIGRATION TOOL  v$VERSION"
    echo ""
    echo -e "  ┌─────────────────────────────────────────────────────────┐"
    echo -e "  │  ${BOLD}1.${NC}  Migrate Single User                               │"
    echo -e "  │  ${BOLD}2.${NC}  Batch Migration                                   │"
    echo -e "  │  ${BOLD}3.${NC}  Check Migration Status                            │"
    echo -e "  │  ${BOLD}4.${NC}  Verify Sync (Dry Run)                             │"
    echo -e "  │  ${BOLD}5.${NC}  Resume Failed Migrations                          │"
    echo -e "  │  ${BOLD}6.${NC}  Manage User Lists                                 │"
    echo -e "  │  ${BOLD}7.${NC}  View Reports                                      │"
    echo -e "  │  ${BOLD}8.${NC}  Manage Profiles                                   │"
    echo -e "  │  ${BOLD}9.${NC}  Log Cleanup                                       │"
    echo -e "  │  ${BOLD}0.${NC}  Exit                                              │"
    echo -e "  └─────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "📊 ${DIM}Status:${NC}"
    echo -e "  ${DIM}•${NC} Profile: ${BOLD}$PROFILE_NAME${NC}"
    echo -e "  ${DIM}•${NC} Source: ${SOURCE_AUTHUSER%%@*}@$SOURCE_HOST ($(provider_name "$SOURCE_PROVIDER"))"
    echo -e "  ${DIM}•${NC} Destination: ${DEST_AUTHUSER%%@*}@$DEST_HOST ($(provider_name "$DEST_PROVIDER"))"
    echo -e "  ${DIM}•${NC} Base: $BASE_DIR"
    echo ""
    read -r -p "Select (0-9): " MENU_OPTION

    case $MENU_OPTION in
        1) migrate_single_user ;;
        2) batch_migrate ;;
        3) check_status ;;
        4) verify_sync ;;
        5) resume_failed ;;
        6) manage_user_lists ;;
        7) view_reports ;;
        8) manage_profiles ;;
        9) log_cleanup ;;
        0) echo ""; print_info "Exiting..."; cleanup_session_secrets; exit 0 ;;
        *) print_error "Invalid"; sleep 1 ;;
    esac
}

# ============================================
# MAIN
# ============================================

# Parse CLI flags before root/dependency checks
case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --version|-v)
        echo "Universal IMAP Email Migration Tool v$VERSION"
        exit 0
        ;;
esac

check_root
check_dependencies

if [ "$1" = "--profile" ] && [ -n "${2:-}" ]; then
    WORK_ROOT="${WORK_ROOT:-$WORK_ROOT_DEFAULT}"
    BASE_DIR="$WORK_ROOT"
    CONFIG_DIR="$BASE_DIR/profiles"
    LOG_DIR="$BASE_DIR/LOGS"
    REPORT_DIR="$BASE_DIR/reports"
    USER_LISTS_DIR="$BASE_DIR/user_lists"
    SECRETS_DIR="$BASE_DIR/.secrets"
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$REPORT_DIR" "$USER_LISTS_DIR" "$SECRETS_DIR"
    load_profile "$2"
else
    select_or_create_profile
fi

while true; do
    show_menu
done