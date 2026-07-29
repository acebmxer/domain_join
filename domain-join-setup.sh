#!/usr/bin/env bash
#
# domain-join-setup.sh
#
# Installs and configures everything a Linux workstation needs in order to join
# and live on an Active Directory domain, across multiple distributions and any
# desktop environment.
#
# The script detects the distro and the desktop environment, then offers the
# choices that actually apply to that combination (with a short description of
# each) instead of assuming one backend or one desktop.
#
# Supported package families:
#   debian  - Debian, Ubuntu, Kubuntu, Linux Mint, Pop!_OS, Zorin, elementary
#   rhel    - Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux, Oracle Linux
#   suse    - openSUSE Leap/Tumbleweed, SLED/SLES
#   arch    - Arch, Manjaro, EndeavourOS, Garuda
#
# License: MIT
#

set -uo pipefail

readonly PROGRAM_NAME="domain-join-setup"
readonly SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Runtime options (overridable by flags)
# ---------------------------------------------------------------------------
ASSUME_YES=0
DRY_RUN=0
LIST_ONLY=0
OPT_BACKEND=""
OPT_GUI=""
OPT_EXTRAS=""
OPT_DOMAIN=""
OPT_JOIN_USER=""
DO_JOIN=-1        # -1 = ask, 0 = no, 1 = yes
OPEN_FIREWALL=-1  # -1 = ask, 0 = no, 1 = yes

LOG_FILE="/var/log/${PROGRAM_NAME}.log"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

log_to_file() {
    [[ $DRY_RUN -eq 1 ]] && return 0
    [[ -w "$(dirname "$LOG_FILE")" ]] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null
}

info()  { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*"; log_to_file "INFO  $*"; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log_to_file "OK    $*"; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; log_to_file "WARN  $*"; }
err()   { printf '%s err%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; log_to_file "ERROR $*"; }
note()  { printf '%s     %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()   { err "$*"; exit 1; }

hr() {
    local width="${COLUMNS:-72}"
    (( width > 78 )) && width=78
    printf '%s%s%s\n' "$C_DIM" "$(printf '%*s' "$width" '' | tr ' ' '-')" "$C_RESET"
}

heading() {
    printf '\n'
    hr
    printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"
    hr
}

# Wrap a description to the terminal width with a hanging indent.
wrap_text() {
    local indent="$1" text="$2"
    local width="${COLUMNS:-76}"
    (( width > 76 )) && width=76
    local avail=$(( width - ${#indent} ))
    (( avail < 30 )) && avail=30
    local line="" word
    for word in $text; do
        if (( ${#line} + ${#word} + 1 > avail )) && [[ -n "$line" ]]; then
            printf '%s%s%s%s\n' "$C_DIM" "$indent" "$line" "$C_RESET"
            line="$word"
        else
            line="${line:+$line }$word"
        fi
    done
    [[ -n "$line" ]] && printf '%s%s%s%s\n' "$C_DIM" "$indent" "$line" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------
# run <command...> - honours --dry-run, logs everything.
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s %s\n' "$C_CYAN" "$C_RESET" "$*"
        return 0
    fi
    log_to_file "RUN   $*"
    "$@"
}

# run_quiet - like run() but swallows stdout unless it fails.
run_quiet() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s %s\n' "$C_CYAN" "$C_RESET" "$*"
        return 0
    fi
    local output rc
    log_to_file "RUN   $*"
    output=$("$@" 2>&1); rc=$?
    if (( rc != 0 )); then
        printf '%s\n' "$output" >&2
    fi
    log_to_file "RC    $rc"
    return $rc
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Interactive prompts
# ---------------------------------------------------------------------------
confirm() {
    local prompt="$1" default="${2:-y}" reply
    if [[ $ASSUME_YES -eq 1 ]]; then
        [[ "$default" == "y" ]] && return 0 || return 1
    fi
    local hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"
    while true; do
        printf '%s%s%s %s ' "$C_BOLD" "$prompt" "$C_RESET" "$hint"
        read -r reply </dev/tty || reply=""
        reply="${reply,,}"
        [[ -z "$reply" ]] && reply="$default"
        case "$reply" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     warn "Please answer y or n." ;;
        esac
    done
}

# menu_single <outvar> <title> <default_key> <"key|Label|Description">...
#
# Prints a numbered menu with a description under each entry and stores the
# chosen key in the named variable.
menu_single() {
    local outvar="$1" title="$2" default_key="$3"; shift 3
    local entries=("$@")
    local -a keys=() labels=() descs=()
    local default_index=1 i=1 entry

    for entry in "${entries[@]}"; do
        keys+=("${entry%%|*}")
        local rest="${entry#*|}"
        labels+=("${rest%%|*}")
        descs+=("${rest#*|}")
        [[ "${entry%%|*}" == "$default_key" ]] && default_index=$i
        ((i++))
    done

    if [[ ${#keys[@]} -eq 1 ]]; then
        printf -v "$outvar" '%s' "${keys[0]}"
        return 0
    fi

    if [[ $ASSUME_YES -eq 1 ]]; then
        printf -v "$outvar" '%s' "${keys[$((default_index - 1))]}"
        return 0
    fi

    printf '\n%s%s%s\n\n' "$C_BOLD" "$title" "$C_RESET"
    for i in "${!keys[@]}"; do
        local marker="  "
        (( i + 1 == default_index )) && marker="${C_GREEN}*${C_RESET} "
        printf '%s%s%2d)%s %s\n' "$marker" "$C_BOLD" "$((i + 1))" "$C_RESET" "${labels[$i]}"
        wrap_text "      " "${descs[$i]}"
        printf '\n'
    done
    note "* = recommended default (press Enter to accept)"

    local reply
    while true; do
        printf '%sChoice [1-%d]:%s ' "$C_BOLD" "${#keys[@]}" "$C_RESET"
        read -r reply </dev/tty || reply=""
        [[ -z "$reply" ]] && reply="$default_index"
        if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#keys[@]} )); then
            printf -v "$outvar" '%s' "${keys[$((reply - 1))]}"
            return 0
        fi
        warn "Enter a number between 1 and ${#keys[@]}."
    done
}

# menu_multi <outvar> <title> <default_keys_csv> <"key|Label|Description">...
#
# Multi-select menu. Stores a space separated list of chosen keys.
menu_multi() {
    local outvar="$1" title="$2" default_csv="$3"; shift 3
    local entries=("$@")
    local -a keys=() labels=() descs=()
    local entry i

    for entry in "${entries[@]}"; do
        keys+=("${entry%%|*}")
        local rest="${entry#*|}"
        labels+=("${rest%%|*}")
        descs+=("${rest#*|}")
    done

    local -a defaults=()
    IFS=',' read -r -a defaults <<<"$default_csv"

    is_default() {
        local k="$1" d
        for d in ${defaults[@]+"${defaults[@]}"}; do
            [[ "$d" == "$k" ]] && return 0
        done
        return 1
    }

    if [[ $ASSUME_YES -eq 1 ]]; then
        printf -v "$outvar" '%s' "${default_csv//,/ }"
        return 0
    fi

    printf '\n%s%s%s\n\n' "$C_BOLD" "$title" "$C_RESET"
    for i in "${!keys[@]}"; do
        local box="[ ]"
        is_default "${keys[$i]}" && box="${C_GREEN}[x]${C_RESET}"
        printf '  %s%2d)%s %s %s\n' "$C_BOLD" "$((i + 1))" "$C_RESET" "$box" "${labels[$i]}"
        wrap_text "      " "${descs[$i]}"
        printf '\n'
    done
    note "Enter numbers separated by spaces (e.g. \"1 3\"), 'all', 'none',"
    note "or press Enter to keep the [x] selections."

    local reply
    while true; do
        printf '%sSelection:%s ' "$C_BOLD" "$C_RESET"
        read -r reply </dev/tty || reply=""
        reply="${reply,,}"

        if [[ -z "$reply" ]]; then
            printf -v "$outvar" '%s' "${default_csv//,/ }"
            return 0
        fi
        if [[ "$reply" == "none" ]]; then
            printf -v "$outvar" '%s' ""
            return 0
        fi
        if [[ "$reply" == "all" ]]; then
            printf -v "$outvar" '%s' "${keys[*]}"
            return 0
        fi

        local -a chosen=() valid=1 token
        for token in $reply; do
            if [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= ${#keys[@]} )); then
                chosen+=("${keys[$((token - 1))]}")
            else
                warn "'$token' is not a valid choice."
                valid=0
                break
            fi
        done
        if (( valid )); then
            printf -v "$outvar" '%s' "${chosen[*]-}"
            return 0
        fi
    done
}

ask_value() {
    local outvar="$1" prompt="$2" default="${3:-}" reply
    if [[ $ASSUME_YES -eq 1 ]]; then
        printf -v "$outvar" '%s' "$default"
        return 0
    fi
    if [[ -n "$default" ]]; then
        printf '%s%s%s [%s]: ' "$C_BOLD" "$prompt" "$C_RESET" "$default"
    else
        printf '%s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET"
    fi
    read -r reply </dev/tty || reply=""
    [[ -z "$reply" ]] && reply="$default"
    printf -v "$outvar" '%s' "$reply"
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
DISTRO_ID=""; DISTRO_NAME=""; DISTRO_VERSION=""; PKG_FAMILY=""; PKG_MGR=""

detect_distro() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found; cannot identify this system."

    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
    DISTRO_VERSION="${VERSION_ID:-}"
    local id_like="${ID_LIKE:-}"

    case "$DISTRO_ID" in
        debian|ubuntu|linuxmint|pop|zorin|elementary|neon|raspbian|kali|devuan)
            PKG_FAMILY="debian" ;;
        fedora|rhel|centos|rocky|almalinux|ol|oracle|scientific|nobara|bazzite)
            PKG_FAMILY="rhel" ;;
        opensuse*|sles|sled|sle*|suse)
            PKG_FAMILY="suse" ;;
        arch|manjaro|endeavouros|garuda|arcolinux|cachyos)
            PKG_FAMILY="arch" ;;
        *)
            # Fall back to ID_LIKE for derivatives we do not know by name.
            case " $id_like " in
                *" debian "*|*" ubuntu "*) PKG_FAMILY="debian" ;;
                *" fedora "*|*" rhel "*|*" centos "*) PKG_FAMILY="rhel" ;;
                *" suse "*|*" opensuse "*) PKG_FAMILY="suse" ;;
                *" arch "*) PKG_FAMILY="arch" ;;
            esac ;;
    esac

    # Last resort: identify by which package manager is present.
    if [[ -z "$PKG_FAMILY" ]]; then
        if   have apt-get; then PKG_FAMILY="debian"
        elif have dnf || have yum; then PKG_FAMILY="rhel"
        elif have zypper; then PKG_FAMILY="suse"
        elif have pacman; then PKG_FAMILY="arch"
        fi
    fi

    [[ -n "$PKG_FAMILY" ]] || die "Unsupported distribution: $DISTRO_NAME (no known package manager)."

    case "$PKG_FAMILY" in
        debian) PKG_MGR="apt-get" ;;
        rhel)   PKG_MGR=$(have dnf5 && echo dnf5 || { have dnf && echo dnf || echo yum; }) ;;
        suse)   PKG_MGR="zypper" ;;
        arch)   PKG_MGR="pacman" ;;
    esac

    have "$PKG_MGR" || die "Package manager '$PKG_MGR' not found on this system."
}

DE_ID=""; DE_NAME=""

detect_de() {
    # Honour a value passed through the sudo re-exec, since sudo drops the
    # desktop session variables.
    if [[ -n "${DJ_DE:-}" ]]; then
        DE_ID="$DJ_DE"
    else
        local raw="${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:+:$DESKTOP_SESSION}"
        raw="${raw,,}"
        case "$raw" in
            *kde*|*plasma*)  DE_ID="kde" ;;
            *gnome*|*unity*) DE_ID="gnome" ;;
            *xfce*)          DE_ID="xfce" ;;
            *cinnamon*)      DE_ID="cinnamon" ;;
            *mate*)          DE_ID="mate" ;;
            *lxqt*)          DE_ID="lxqt" ;;
            *budgie*)        DE_ID="budgie" ;;
            *cosmic*)        DE_ID="cosmic" ;;
            *sway*|*hyprland*|*wlroots*) DE_ID="wlroots" ;;
        esac
    fi

    # No session variables (ssh, sudo, tty): look for a running session, then
    # fall back to what is merely installed.
    if [[ -z "$DE_ID" ]]; then
        if   pgrep -x plasmashell    >/dev/null 2>&1; then DE_ID="kde"
        elif pgrep -x gnome-shell    >/dev/null 2>&1; then DE_ID="gnome"
        elif pgrep -x xfce4-session  >/dev/null 2>&1; then DE_ID="xfce"
        elif pgrep -x cinnamon       >/dev/null 2>&1; then DE_ID="cinnamon"
        elif pgrep -x mate-session   >/dev/null 2>&1; then DE_ID="mate"
        elif pgrep -x lxqt-session   >/dev/null 2>&1; then DE_ID="lxqt"
        elif have plasmashell;          then DE_ID="kde"
        elif have gnome-shell;          then DE_ID="gnome"
        elif have xfce4-session;        then DE_ID="xfce"
        else DE_ID="none"
        fi
    fi

    case "$DE_ID" in
        kde)      DE_NAME="KDE Plasma" ;;
        gnome)    DE_NAME="GNOME" ;;
        xfce)     DE_NAME="Xfce" ;;
        cinnamon) DE_NAME="Cinnamon" ;;
        mate)     DE_NAME="MATE" ;;
        lxqt)     DE_NAME="LXQt" ;;
        budgie)   DE_NAME="Budgie" ;;
        cosmic)   DE_NAME="COSMIC" ;;
        wlroots)  DE_NAME="Sway/Hyprland" ;;
        none)     DE_NAME="No desktop detected (server/headless)" ;;
        *)        DE_NAME="$DE_ID" ;;
    esac
}

# ---------------------------------------------------------------------------
# Package name mapping
# ---------------------------------------------------------------------------
# pkgs_for <group> - echoes the package names for the current family.
# Names that do not exist in the configured repos are filtered out later, so a
# generous list here is safe.
pkgs_for() {
    local group="$1"
    case "$PKG_FAMILY:$group" in
        # --- SSSD / realmd backend -----------------------------------------
        debian:core_sssd)
            echo "realmd sssd sssd-tools sssd-ad sssd-krb5 libnss-sss libpam-sss adcli samba-common-bin krb5-user packagekit oddjob oddjob-mkhomedir" ;;
        rhel:core_sssd)
            echo "realmd sssd sssd-tools sssd-ad sssd-krb5 adcli samba-common-tools krb5-workstation authselect oddjob oddjob-mkhomedir PackageKit" ;;
        suse:core_sssd)
            echo "realmd sssd sssd-tools sssd-ad sssd-krb5 sssd-ldap adcli samba-client krb5-client PackageKit" ;;
        arch:core_sssd)
            echo "realmd sssd adcli krb5 samba packagekit" ;;

        # --- Samba Winbind backend -----------------------------------------
        debian:core_winbind)
            echo "winbind libnss-winbind libpam-winbind samba-common-bin smbclient krb5-user" ;;
        rhel:core_winbind)
            echo "samba-winbind samba-winbind-clients samba-common-tools authselect krb5-workstation" ;;
        suse:core_winbind)
            echo "samba-winbind samba-client krb5-client" ;;
        arch:core_winbind)
            echo "samba krb5" ;;

        # --- GUI: Cockpit ----------------------------------------------------
        debian:gui_cockpit) echo "cockpit cockpit-system" ;;
        rhel:gui_cockpit)   echo "cockpit cockpit-system" ;;
        suse:gui_cockpit)   echo "cockpit cockpit-system" ;;
        arch:gui_cockpit)   echo "cockpit" ;;

        # --- GUI: GNOME Settings enterprise login ----------------------------
        debian:gui_gnome) echo "gnome-control-center gnome-online-accounts" ;;
        rhel:gui_gnome)   echo "gnome-control-center gnome-online-accounts" ;;
        suse:gui_gnome)   echo "gnome-control-center gnome-online-accounts" ;;
        arch:gui_gnome)   echo "gnome-control-center gnome-online-accounts" ;;

        # --- GUI: YaST (openSUSE only) ---------------------------------------
        suse:gui_yast) echo "yast2-auth-client yast2-samba-client yast2-users" ;;

        # --- GUI: Ubuntu ADSys (Group Policy client) -------------------------
        debian:gui_adsys) echo "adsys" ;;

        # --- Optional extras ---------------------------------------------------
        debian:extra_troubleshoot) echo "dnsutils ldap-utils krb5-user" ;;
        rhel:extra_troubleshoot)   echo "bind-utils openldap-clients krb5-workstation" ;;
        suse:extra_troubleshoot)   echo "bind-utils openldap2-client krb5-client" ;;
        arch:extra_troubleshoot)   echo "bind openldap krb5" ;;

        debian:extra_shares) echo "cifs-utils smbclient" ;;
        rhel:extra_shares)   echo "cifs-utils samba-client" ;;
        suse:extra_shares)   echo "cifs-utils samba-client" ;;
        arch:extra_shares)   echo "cifs-utils smbclient" ;;

        debian:extra_sudo) echo "libsss-sudo" ;;
        rhel:extra_sudo)   echo "" ;;   # provided by sssd-common
        suse:extra_sudo)   echo "" ;;
        arch:extra_sudo)   echo "" ;;

        debian:extra_chrony) echo "chrony" ;;
        rhel:extra_chrony)   echo "chrony" ;;
        suse:extra_chrony)   echo "chrony" ;;
        arch:extra_chrony)   echo "chrony" ;;

        *) echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# Package manager operations
# ---------------------------------------------------------------------------
REPO_REFRESHED=0

refresh_repos() {
    (( REPO_REFRESHED )) && return 0
    REPO_REFRESHED=1
    if [[ $EUID -ne 0 ]]; then
        note "Not root; using cached package metadata."
        return 0
    fi
    info "Refreshing package metadata"
    case "$PKG_FAMILY" in
        debian) run_quiet apt-get update ;;
        rhel)   run_quiet "$PKG_MGR" -q makecache ;;
        suse)   run_quiet zypper --non-interactive refresh ;;
        arch)
            # Deliberately no 'pacman -Sy' here. Refreshing the database and
            # then installing without a full upgrade is a partial upgrade,
            # which is unsupported on Arch and can break a running system.
            note "Using the existing pacman database."
            note "Run 'sudo pacman -Syu' first if it has not been synced recently."
            ;;
    esac || warn "Metadata refresh reported an error; continuing with cached data."
}

pkg_is_installed() {
    case "$PKG_FAMILY" in
        debian) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "ok installed" ;;
        rhel)   rpm -q "$1" >/dev/null 2>&1 ;;
        suse)   rpm -q "$1" >/dev/null 2>&1 ;;
        arch)   pacman -Qi "$1" >/dev/null 2>&1 ;;
    esac
}

pkg_is_available() {
    case "$PKG_FAMILY" in
        debian) apt-cache show "$1" 2>/dev/null | grep -q '^Package:' ;;
        rhel)   "$PKG_MGR" -q repoquery --qf '%{name}' "$1" 2>/dev/null | grep -q . ;;
        suse)   zypper --non-interactive --quiet search --match-exact --type package "$1" >/dev/null 2>&1 ;;
        arch)   pacman -Si "$1" >/dev/null 2>&1 ;;
    esac
}

# filter_available <pkg...> - split the candidates into what the repos actually
# carry and what they do not. Results land in globals rather than on stdout so
# that both lists survive (a subshell would discard the skipped list).
declare -a AVAILABLE_PACKAGES=()
declare -a SKIPPED_PACKAGES=()

filter_available() {
    AVAILABLE_PACKAGES=()
    SKIPPED_PACKAGES=()
    local pkg
    for pkg in "$@"; do
        [[ -z "$pkg" ]] && continue
        if pkg_is_installed "$pkg" || pkg_is_available "$pkg"; then
            AVAILABLE_PACKAGES+=("$pkg")
        else
            SKIPPED_PACKAGES+=("$pkg")
        fi
    done
}

install_packages() {
    local -a pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && { warn "Nothing to install."; return 0; }

    info "Installing ${#pkgs[@]} package(s)"
    case "$PKG_FAMILY" in
        debian)
            # krb5-user asks for a default realm via debconf; preseed it when we
            # know the domain and keep the frontend non-interactive regardless.
            if [[ -n "$OPT_DOMAIN" ]] && have debconf-set-selections && [[ $DRY_RUN -eq 0 ]]; then
                printf 'krb5-config krb5-config/default_realm string %s\n' "${OPT_DOMAIN^^}" \
                    | debconf-set-selections 2>/dev/null || true
            fi
            DEBIAN_FRONTEND=noninteractive run apt-get install -y "${pkgs[@]}"
            ;;
        rhel)
            run "$PKG_MGR" install -y "${pkgs[@]}"
            ;;
        suse)
            run zypper --non-interactive install --auto-agree-with-licenses "${pkgs[@]}"
            ;;
        arch)
            run pacman -S --needed --noconfirm "${pkgs[@]}"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Service helpers
# ---------------------------------------------------------------------------
# Read-only, so it runs even under --dry-run to keep the preview accurate.
unit_exists() {
    have systemctl || return 1
    systemctl list-unit-files "$1" 2>/dev/null | grep -q "^$1"
}

enable_service() {
    local unit="$1" start="${2:-now}"
    have systemctl || { warn "systemd not present; enable '$unit' manually."; return 0; }
    if ! unit_exists "$unit"; then
        warn "Service '$unit' is not present; skipping."
        return 0
    fi
    if [[ "$start" == "now" ]]; then
        run_quiet systemctl enable --now "$unit" && ok "Enabled and started $unit" \
            || warn "Could not enable/start $unit (see log)."
    else
        run_quiet systemctl enable "$unit" && ok "Enabled $unit (starts after the domain join)" \
            || warn "Could not enable $unit (see log)."
    fi
}

# ---------------------------------------------------------------------------
# Post-install configuration
# ---------------------------------------------------------------------------
configure_mkhomedir() {
    info "Enabling automatic home directory creation on first login"
    case "$PKG_FAMILY" in
        rhel)
            if have authselect; then
                enable_service oddjobd.service now
                if run_quiet authselect select sssd with-mkhomedir --force; then
                    ok "authselect profile: sssd with-mkhomedir"
                else
                    warn "authselect failed; check 'authselect current'."
                fi
            else
                warn "authselect not available; configure pam_mkhomedir manually."
            fi
            ;;
        debian)
            enable_service oddjobd.service now
            if have pam-auth-update; then
                if DEBIAN_FRONTEND=noninteractive run_quiet pam-auth-update --enable mkhomedir; then
                    ok "pam-auth-update: mkhomedir enabled"
                else
                    warn "pam-auth-update failed; run 'sudo pam-auth-update' and tick 'Create home directory on login'."
                fi
            else
                warn "pam-auth-update not found; configure pam_mkhomedir manually."
            fi
            ;;
        suse)
            if have pam-config; then
                if run_quiet pam-config --add --mkhomedir; then
                    ok "pam-config: mkhomedir enabled"
                else
                    warn "pam-config failed; configure pam_mkhomedir manually."
                fi
            else
                warn "pam-config not found; configure pam_mkhomedir manually."
            fi
            ;;
        arch)
            local pam_file="/etc/pam.d/system-login"
            local pam_line="session   optional   pam_mkhomedir.so skel=/etc/skel umask=0077"
            if [[ ! -f "$pam_file" ]]; then
                warn "$pam_file not found; configure pam_mkhomedir manually."
            elif grep -q "pam_mkhomedir.so" "$pam_file"; then
                ok "pam_mkhomedir already present in $pam_file"
            else
                backup_file "$pam_file"
                if [[ $DRY_RUN -eq 1 ]]; then
                    printf '%s  [dry-run]%s append pam_mkhomedir to %s\n' "$C_CYAN" "$C_RESET" "$pam_file"
                else
                    printf '%s\n' "$pam_line" >>"$pam_file" && ok "Added pam_mkhomedir to $pam_file"
                fi
            fi
            ;;
    esac
}

configure_timesync() {
    info "Ensuring the clock is synchronised (Kerberos rejects >5 min skew)"
    if unit_exists chronyd.service; then
        enable_service chronyd.service now
    elif unit_exists chrony.service; then
        enable_service chrony.service now
    elif unit_exists systemd-timesyncd.service; then
        enable_service systemd-timesyncd.service now
    else
        warn "No time sync service found; install chrony or systemd-timesyncd."
        return 0
    fi
    [[ $DRY_RUN -eq 1 ]] && return 0
    have timedatectl && run_quiet timedatectl set-ntp true
}

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    [[ $DRY_RUN -eq 1 ]] && { printf '%s  [dry-run]%s back up %s\n' "$C_CYAN" "$C_RESET" "$f"; return 0; }
    local bak="${f}.${PROGRAM_NAME}.$(date +%Y%m%d%H%M%S).bak"
    cp -a "$f" "$bak" && note "Backed up $f -> $bak"
}

open_firewall_for_cockpit() {
    local answer=$OPEN_FIREWALL
    if (( answer == -1 )); then
        if confirm "Open TCP port 9090 in the firewall so Cockpit is reachable from other machines?" "n"; then
            answer=1
        else
            answer=0
        fi
    fi
    if (( answer == 0 )); then
        note "Firewall untouched. Cockpit is still usable locally at https://localhost:9090"
        return 0
    fi

    if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
        run_quiet firewall-cmd --permanent --add-service=cockpit && \
        run_quiet firewall-cmd --reload && ok "firewalld: cockpit service allowed"
    elif have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        run_quiet ufw allow 9090/tcp && ok "ufw: 9090/tcp allowed"
    else
        note "No active firewalld/ufw detected; no firewall change needed."
    fi
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    heading "Preflight checks"

    # Hostname
    local host_fqdn
    host_fqdn="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo unknown)"
    if [[ "$host_fqdn" == *.* ]]; then
        ok "Hostname: $host_fqdn"
    else
        warn "Hostname '$host_fqdn' is not fully qualified."
        note "AD prefers an FQDN. Set one with:"
        note "  sudo hostnamectl set-hostname ${host_fqdn}.your.domain"
    fi

    # Clock
    if have timedatectl; then
        local synced
        synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
        if [[ "$synced" == "yes" ]]; then
            ok "Clock is NTP synchronised"
        else
            warn "Clock is not NTP synchronised (Kerberos allows ~5 minutes of skew)."
        fi
    fi

    # DNS to the domain, if we know it
    if [[ -n "$OPT_DOMAIN" ]]; then
        if have dig; then
            if dig +short -t SRV "_ldap._tcp.dc._msdcs.${OPT_DOMAIN}" 2>/dev/null | grep -q .; then
                ok "DNS resolves domain controllers for $OPT_DOMAIN"
            else
                warn "No _ldap._tcp.dc._msdcs.${OPT_DOMAIN} SRV records returned."
                note "The machine must use the AD DNS servers, not a public resolver."
            fi
        else
            note "Install bind-utils/dnsutils to verify the domain's SRV records."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Domain join
# ---------------------------------------------------------------------------
sssd_set_option() {
    local key="$1" val="$2" f="/etc/sssd/sssd.conf"
    [[ -f "$f" ]] || return 1

    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$f"; then
        sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$f"
        return 0
    fi

    if ! grep -qE '^\[domain/' "$f"; then
        warn "No [domain/...] section in $f; not setting '$key'."
        return 1
    fi

    local tmp
    tmp="$(mktemp)" || return 1
    awk -v line="${key} = ${val}" '
        /^\[domain\// && !inserted { print; print line; inserted = 1; next }
        { print }
    ' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }

    # Copy the contents back rather than mv, so sssd.conf keeps its 0600 mode
    # and ownership -- SSSD refuses to start if they are relaxed.
    cat "$tmp" >"$f"
    rm -f "$tmp"
}

perform_join() {
    heading "Join the Active Directory domain"

    if ! have realm; then
        err "'realm' is not available, so the automated join cannot run."
        note "Winbind-only setups join with: sudo net ads join -U Administrator"
        return 1
    fi

    [[ -z "$OPT_DOMAIN" ]] && ask_value OPT_DOMAIN "Active Directory domain (e.g. corp.example.com)" ""
    if [[ -z "$OPT_DOMAIN" ]]; then
        warn "No domain given; skipping the join."
        return 1
    fi

    info "Discovering $OPT_DOMAIN"
    if ! run realm discover "$OPT_DOMAIN"; then
        err "Could not discover $OPT_DOMAIN."
        note "Check that DNS points at the domain controllers and the domain name is right."
        return 1
    fi

    [[ -z "$OPT_JOIN_USER" ]] && ask_value OPT_JOIN_USER "Domain account allowed to join computers" "Administrator"

    info "Joining $OPT_DOMAIN as $OPT_JOIN_USER (you will be prompted for the password)"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s realm join -U %s %s\n' "$C_CYAN" "$C_RESET" "$OPT_JOIN_USER" "$OPT_DOMAIN"
        return 0
    fi

    if realm join -U "$OPT_JOIN_USER" "$OPT_DOMAIN"; then
        ok "Joined $OPT_DOMAIN"
        log_to_file "JOIN  success $OPT_DOMAIN"
    else
        err "The join failed. 'sudo realm join -v -U $OPT_JOIN_USER $OPT_DOMAIN' shows the details."
        return 1
    fi

    post_join_tuning
}

post_join_tuning() {
    [[ -f /etc/sssd/sssd.conf ]] || return 0

    heading "Post-join login settings"

    if confirm "Allow short usernames (jdoe) instead of requiring jdoe@${OPT_DOMAIN}?" "y"; then
        backup_file /etc/sssd/sssd.conf
        if [[ $DRY_RUN -eq 0 ]]; then
            sssd_set_option "use_fully_qualified_names" "False"
            sssd_set_option "fallback_homedir" "/home/%u"
            ok "sssd.conf: short names enabled, home directories under /home/<user>"
        fi
    fi

    local access_choice
    menu_single access_choice "Who may log in to this machine?" "group" \
        "group|A specific AD group only|Restricts interactive logins to the members of one Active Directory group. This is the safer default: a fresh domain join otherwise exposes the workstation to every account in the directory." \
        "all|Every domain user|Any account in the domain can log in. Convenient for shared lab or kiosk machines, but it means the whole directory has shell access to this host." \
        "skip|Decide later|Leaves the access rules untouched. Nothing changes until you run 'realm permit' yourself; on most builds this means logins stay denied."

    case "$access_choice" in
        all)
            run realm permit --all && ok "All domain users may log in."
            ;;
        group)
            local grp
            ask_value grp "AD group permitted to log in (e.g. 'Linux Admins')" ""
            if [[ -n "$grp" ]]; then
                if run realm permit -g "$grp"; then
                    ok "Members of '$grp' may log in."
                else
                    warn "Could not permit '$grp'. Verify the group name with 'realm list'."
                fi
            else
                note "No group given; access rules left unchanged."
            fi
            ;;
        skip)
            note "Access rules unchanged. Use 'realm permit -g \"Some Group\"' when ready."
            ;;
    esac

    if confirm "Grant a domain group passwordless-prompt sudo rights on this machine?" "n"; then
        local sudo_grp
        ask_value sudo_grp "AD group to grant sudo (e.g. 'Linux Admins')" ""
        if [[ -n "$sudo_grp" ]]; then
            local sudoers_file="/etc/sudoers.d/domain-admins"
            if [[ $DRY_RUN -eq 1 ]]; then
                printf '%s  [dry-run]%s write %s for group %s\n' "$C_CYAN" "$C_RESET" "$sudoers_file" "$sudo_grp"
            else
                printf '%%%s ALL=(ALL) ALL\n' "${sudo_grp// /\\ }" >"$sudoers_file"
                chmod 0440 "$sudoers_file"
                if visudo -cf "$sudoers_file" >/dev/null 2>&1; then
                    ok "sudo granted to '$sudo_grp' via $sudoers_file"
                else
                    rm -f "$sudoers_file"
                    err "Generated sudoers entry was invalid and has been removed."
                fi
            fi
        fi
    fi

    info "Restarting SSSD to apply the changes"
    run_quiet systemctl restart sssd && ok "sssd restarted" || warn "Could not restart sssd."
}

# ---------------------------------------------------------------------------
# Choice builders - only offer what makes sense here
# ---------------------------------------------------------------------------
choose_backend() {
    local -a entries=()
    entries+=("sssd|SSSD + realmd + adcli  ${C_GREEN}(recommended)${C_RESET}|The modern standard used by Fedora, RHEL and Ubuntu. Kerberos single sign-on, cached credentials for offline logins, AD group to POSIX ID mapping, and one-command joins via 'realm join'. Choose this unless you have a specific reason not to.")
    entries+=("winbind|Samba Winbind|Samba's own AD client. Pick this if the machine is also a Samba file server, if you must match Windows RID-based UID/GID mapping exactly, or if you are attaching to an old NT4-style domain. Joins are done with 'net ads join'.")
    entries+=("both|Install both|SSSD handles logins while the Winbind tooling stays available for Samba shares and 'net ads' troubleshooting. Uses more disk and adds a second daemon, but nothing conflicts as long as only SSSD is wired into PAM/NSS.")

    menu_single BACKEND "Which Active Directory backend should handle authentication?" "sssd" "${entries[@]}"
}

# gui_entries - the GUI menu rows that apply to the detected distro and
# desktop, one "key|Label|Description" per line. Split out from choose_gui so
# the test suite can assert on the real composition rather than a copy of it.
gui_entries() {
    local -a entries=()

    # Cockpit is the only join GUI that works on every desktop, so it leads on
    # anything that is not GNOME.
    entries+=("cockpit|Cockpit web console (works on any desktop)|A browser-based admin console at https://localhost:9090 whose Overview page has a 'Join domain' dialog driven by realmd. This is the practical graphical option on KDE Plasma, Xfce, LXQt, Cinnamon and headless servers, none of which ship a native domain-join panel.")

    if [[ "$DE_ID" == "gnome" ]] || [[ "$DE_ID" == "cinnamon" ]] || [[ "$DE_ID" == "budgie" ]]; then
        entries+=("gnome|GNOME Settings - Enterprise Login|GNOME's Users panel gains an 'Enterprise Login' option that joins the domain and adds AD accounts from Settings. Already present on a standard GNOME install; selecting this just makes sure the packages are there.")
    fi

    if [[ "$PKG_FAMILY" == "suse" ]]; then
        entries+=("yast|YaST - User Logon Management / Domain Membership|openSUSE's own graphical admin tool. The 'User Logon Management' module drives SSSD and the 'Windows Domain Membership' module drives Winbind, both with a full GUI and a matching ncurses mode over SSH.")
    fi

    if [[ "$DISTRO_ID" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *ubuntu* ]]; then
        entries+=("adsys|Ubuntu ADSys - Group Policy client|Applies Active Directory Group Policy Objects to the Ubuntu desktop: dconf settings, privilege assignment, scripts and network shares. Complements SSSD rather than replacing it. Full GPO support needs an Ubuntu Pro subscription; the package installs and runs without one.")
    fi

    entries+=("none|No GUI - command line only|Installs nothing extra. You join and manage the domain with 'realm', 'adcli' and 'net ads'. Sensible for servers, minimal images, or configuration-managed fleets.")

    printf '%s\n' "${entries[@]}"
}

# gui_default - which GUI row starts ticked for this desktop.
gui_default() {
    case "$DE_ID" in
        gnome|cinnamon|budgie) echo "gnome" ;;
        *)                     echo "cockpit" ;;
    esac
}

choose_gui() {
    local -a entries=()
    mapfile -t entries < <(gui_entries)
    menu_multi GUI_CHOICES "Which graphical domain management tools should be installed?" \
        "$(gui_default)" "${entries[@]}"
}

choose_extras() {
    local -a entries=()
    entries+=("mkhomedir|Create home directories on first login|Without this a domain user logs in with no home directory and most desktop sessions fail to start. Configured through authselect, pam-auth-update, pam-config or pam_mkhomedir depending on the distro.")
    entries+=("timesync|Enforce network time synchronisation|Kerberos rejects tickets when the clock differs from the domain controller by more than about five minutes, which is the single most common cause of a failed join. Enables chrony or systemd-timesyncd.")
    entries+=("troubleshoot|Diagnostic tools (dig, ldapsearch, kinit)|DNS, LDAP and Kerberos clients for checking SRV records, querying the directory and testing ticket acquisition. Small download, and the first thing you will want when a join misbehaves.")
    entries+=("shares|Access to Windows file shares|cifs-utils and smbclient so the workstation can browse and mount SMB shares, including mounting with your Kerberos ticket instead of a stored password.")
    entries+=("sudo|SSSD sudo rules from the directory|Lets sudo read sudoers rules published in Active Directory, so admin rights are managed centrally rather than in /etc/sudoers on every machine.")

    menu_multi EXTRA_CHOICES "Which supporting components should be included?" "mkhomedir,timesync,troubleshoot" "${entries[@]}"
}

# ---------------------------------------------------------------------------
# Summary and next steps
# ---------------------------------------------------------------------------
print_next_steps() {
    heading "Next steps"

    local joined=0
    if have realm && [[ $DRY_RUN -eq 0 ]]; then
        realm list 2>/dev/null | grep -q "domain-name" && joined=1
    fi

    if (( joined )); then
        ok "This machine is joined to a domain."
        printf '\n'
        printf '  Verify a domain account resolves:\n'
        printf '    %sid someuser@%s%s\n' "$C_CYAN" "${OPT_DOMAIN:-your.domain}" "$C_RESET"
        printf '  Test a Kerberos ticket:\n'
        printf '    %skinit someuser@%s && klist%s\n' "$C_CYAN" "${OPT_DOMAIN^^}" "$C_RESET"
        printf '  Review who is permitted to log in:\n'
        printf '    %srealm list%s\n' "$C_CYAN" "$C_RESET"
    else
        printf '  Join the domain from the command line:\n'
        printf '    %ssudo realm discover %s%s\n' "$C_CYAN" "${OPT_DOMAIN:-corp.example.com}" "$C_RESET"
        printf '    %ssudo realm join -U Administrator %s%s\n' "$C_CYAN" "${OPT_DOMAIN:-corp.example.com}" "$C_RESET"
    fi

    local g
    for g in ${GUI_CHOICES:-}; do
        case "$g" in
            cockpit)
                printf '\n  %sCockpit%s - open %shttps://localhost:9090%s and sign in with a local\n' \
                    "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
                printf '  administrator account. The Overview page has a "Join domain" button.\n'
                ;;
            gnome)
                printf '\n  %sGNOME%s - Settings > System > Users > Add User > Enterprise Login.\n' \
                    "$C_BOLD" "$C_RESET"
                ;;
            yast)
                printf '\n  %sYaST%s - run %ssudo yast2 auth-client%s (SSSD) or\n' \
                    "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
                printf '  %ssudo yast2 samba-client%s (Winbind).\n' "$C_CYAN" "$C_RESET"
                ;;
            adsys)
                printf '\n  %sADSys%s - check Group Policy application with %sadsysctl policy applied%s.\n' \
                    "$C_BOLD" "$C_RESET" "$C_CYAN" "$C_RESET"
                ;;
        esac
    done

    if [[ "$DE_ID" == "kde" ]]; then
        printf '\n  %sKDE Plasma note:%s System Settings has no Active Directory module.\n' \
            "$C_YELLOW$C_BOLD" "$C_RESET"
        printf '  Domain logins still work normally through SDDM once the machine is\n'
        printf '  joined -- type the domain username at the login screen. Use Cockpit or\n'
        printf '  the realm command for join and membership management.\n'
    fi

    printf '\n  Full log: %s\n' "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${C_BOLD}$PROGRAM_NAME $SCRIPT_VERSION${C_RESET}
Install and configure Active Directory domain join support on any supported
Linux distribution and desktop environment.

${C_BOLD}USAGE${C_RESET}
  sudo ./domain-join-setup.sh [options]

${C_BOLD}OPTIONS${C_RESET}
  -d, --domain DOMAIN     Active Directory domain (e.g. corp.example.com).
  -u, --user USER         Domain account used to perform the join.
  -b, --backend NAME      sssd | winbind | both
  -g, --gui LIST          Comma separated: cockpit,gnome,yast,adsys,none
  -e, --extras LIST       Comma separated: mkhomedir,timesync,troubleshoot,shares,sudo
      --join              Join the domain after installing.
      --no-join           Install only; never attempt a join.
      --open-firewall     Allow Cockpit (9090/tcp) through the firewall.
      --no-open-firewall  Leave the firewall alone.
  -y, --yes               Non-interactive; accept every recommended default.
  -n, --dry-run           Print what would happen without changing anything.
  -l, --list              Show the packages for this system and exit.
  -h, --help              This help.
      --version           Print the version.

${C_BOLD}EXAMPLES${C_RESET}
  # Interactive: detect the system, ask what to install
  sudo ./domain-join-setup.sh

  # Preview the actions for a KDE workstation without touching anything
  sudo ./domain-join-setup.sh --dry-run

  # Unattended install plus join
  sudo ./domain-join-setup.sh -y -b sssd -g cockpit \\
       -e mkhomedir,timesync,shares -d corp.example.com -u svc-join --join
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain)   OPT_DOMAIN="${2:-}"; shift 2 ;;
            -u|--user)     OPT_JOIN_USER="${2:-}"; shift 2 ;;
            -b|--backend)  OPT_BACKEND="${2:-}"; shift 2 ;;
            -g|--gui)      OPT_GUI="${2:-}"; shift 2 ;;
            -e|--extras)   OPT_EXTRAS="${2:-}"; shift 2 ;;
            --join)        DO_JOIN=1; shift ;;
            --no-join)     DO_JOIN=0; shift ;;
            --open-firewall)    OPEN_FIREWALL=1; shift ;;
            --no-open-firewall) OPEN_FIREWALL=0; shift ;;
            --detected-de) DJ_DE="${2:-}"; shift 2 ;;   # internal: set by the sudo re-exec
            -y|--yes)      ASSUME_YES=1; shift ;;
            -n|--dry-run)  DRY_RUN=1; shift ;;
            -l|--list)     LIST_ONLY=1; shift ;;
            -h|--help)     usage; exit 0 ;;
            --version)     printf '%s %s\n' "$PROGRAM_NAME" "$SCRIPT_VERSION"; exit 0 ;;
            *)             err "Unknown option: $1"; printf '\n'; usage; exit 2 ;;
        esac
    done

    if [[ -n "$OPT_BACKEND" && ! "$OPT_BACKEND" =~ ^(sssd|winbind|both)$ ]]; then
        die "Invalid --backend '$OPT_BACKEND' (expected sssd, winbind or both)."
    fi
}

require_root() {
    [[ $EUID -eq 0 ]] && return 0
    [[ $LIST_ONLY -eq 1 || $DRY_RUN -eq 1 ]] && { warn "Not running as root; showing a preview only."; return 0; }

    if have sudo; then
        info "Root privileges are required; re-running under sudo."
        # The detected desktop is passed as an argument, not an environment
        # variable: sudoers defaults to !setenv, which would reject `sudo VAR=x`.
        exec sudo "$0" --detected-de "$DE_ID" "$@"
    fi
    die "Run this script as root (sudo $0)."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    detect_distro
    detect_de          # before the sudo re-exec, while the session vars exist
    require_root "$@"

    heading "$PROGRAM_NAME $SCRIPT_VERSION"
    printf '  Distribution : %s%s%s\n' "$C_BOLD" "$DISTRO_NAME" "$C_RESET"
    printf '  Family       : %s (%s)\n' "$PKG_FAMILY" "$PKG_MGR"
    printf '  Desktop      : %s%s%s\n' "$C_BOLD" "$DE_NAME" "$C_RESET"
    printf '  Kernel       : %s\n' "$(uname -r)"
    [[ $DRY_RUN -eq 1 ]] && printf '  Mode         : %sDRY RUN - nothing will be changed%s\n' "$C_CYAN$C_BOLD" "$C_RESET"

    # --- Choices ---------------------------------------------------------
    if [[ -n "$OPT_BACKEND" ]]; then
        BACKEND="$OPT_BACKEND"
    else
        choose_backend
    fi

    if [[ -n "$OPT_GUI" ]]; then
        GUI_CHOICES="${OPT_GUI//,/ }"
    else
        choose_gui
    fi

    if [[ -n "$OPT_EXTRAS" ]]; then
        EXTRA_CHOICES="${OPT_EXTRAS//,/ }"
    else
        choose_extras
    fi

    # 'none' is a selection, not a package group: drop it wherever it appears.
    local -a gui_kept=() gui_item
    for gui_item in ${GUI_CHOICES:-}; do
        [[ "$gui_item" == "none" ]] && continue
        gui_kept+=("$gui_item")
    done
    GUI_CHOICES="${gui_kept[*]-}"

    # --- Build the package list ------------------------------------------
    local -a wanted=()
    case "$BACKEND" in
        sssd)    read -r -a wanted <<<"$(pkgs_for core_sssd)" ;;
        winbind) read -r -a wanted <<<"$(pkgs_for core_winbind)" ;;
        both)    read -r -a wanted <<<"$(pkgs_for core_sssd) $(pkgs_for core_winbind)" ;;
    esac

    local choice
    for choice in ${GUI_CHOICES:-}; do
        local group_pkgs
        group_pkgs="$(pkgs_for "gui_${choice}")"
        [[ -n "$group_pkgs" ]] && read -r -a add <<<"$group_pkgs" && wanted+=("${add[@]}")
    done

    local want_mkhomedir=0 want_timesync=0
    for choice in ${EXTRA_CHOICES:-}; do
        case "$choice" in
            mkhomedir)   want_mkhomedir=1 ;;
            timesync)    want_timesync=1
                         # Only pull in chrony when the system has no time
                         # daemon at all; installing it alongside an active
                         # chronyd or systemd-timesyncd just creates a conflict.
                         if ! unit_exists chronyd.service \
                            && ! unit_exists chrony.service \
                            && ! unit_exists systemd-timesyncd.service; then
                             read -r -a add <<<"$(pkgs_for extra_chrony)"; wanted+=("${add[@]}")
                         fi ;;
            troubleshoot) read -r -a add <<<"$(pkgs_for extra_troubleshoot)"; wanted+=("${add[@]}") ;;
            shares)       read -r -a add <<<"$(pkgs_for extra_shares)"; wanted+=("${add[@]}") ;;
            sudo)         local sp; sp="$(pkgs_for extra_sudo)"
                          [[ -n "$sp" ]] && { read -r -a add <<<"$sp"; wanted+=("${add[@]}"); } ;;
        esac
    done

    # Deduplicate while preserving order.
    local -a unique=()
    local p seen
    for p in ${wanted[@]+"${wanted[@]}"}; do
        seen=0
        local u
        for u in ${unique[@]+"${unique[@]}"}; do [[ "$u" == "$p" ]] && { seen=1; break; }; done
        (( seen )) || unique+=("$p")
    done

    # --- Resolve against the repos ---------------------------------------
    heading "Packages"
    refresh_repos
    filter_available ${unique[@]+"${unique[@]}"}
    local -a final=("${AVAILABLE_PACKAGES[@]-}")

    if [[ ${#final[@]} -eq 0 || -z "${final[0]}" ]]; then
        die "No installable packages resolved. Are the distribution repositories enabled?"
    fi

    printf '  The following will be installed or confirmed present:\n\n'
    for p in "${final[@]}"; do
        if pkg_is_installed "$p"; then
            printf '    %s%s%s %s (already installed)\n' "$C_GREEN" "+" "$C_RESET" "$p"
        else
            printf '    %s+%s %s\n' "$C_BOLD" "$C_RESET" "$p"
        fi
    done

    if [[ ${#SKIPPED_PACKAGES[@]} -gt 0 ]]; then
        printf '\n'
        warn "Not available in this system's repositories (skipped):"
        for p in "${SKIPPED_PACKAGES[@]}"; do note "  - $p"; done
    fi
    printf '\n'

    if [[ $LIST_ONLY -eq 1 ]]; then
        exit 0
    fi

    if ! confirm "Proceed with the installation?" "y"; then
        info "Aborted at the user's request. Nothing was changed."
        exit 0
    fi

    # --- Install ----------------------------------------------------------
    heading "Installation"
    if ! install_packages "${final[@]}"; then
        die "Package installation failed. See the output above and $LOG_FILE."
    fi
    ok "Packages installed"

    # --- Configure --------------------------------------------------------
    heading "Configuration"
    (( want_timesync ))  && configure_timesync
    (( want_mkhomedir )) && configure_mkhomedir

    case "$BACKEND" in
        sssd|both)
            # sssd has no valid configuration until the join creates one, so it
            # is enabled but deliberately not started here.
            enable_service sssd.service later
            ;;
    esac

    for choice in ${GUI_CHOICES:-}; do
        case "$choice" in
            cockpit)
                enable_service cockpit.socket now
                open_firewall_for_cockpit
                ;;
            adsys)
                enable_service adsys.service now
                ;;
        esac
    done

    preflight_checks

    # --- Optional join ----------------------------------------------------
    local join_now=$DO_JOIN
    if (( join_now == -1 )); then
        printf '\n'
        if confirm "Join an Active Directory domain now?" "n"; then join_now=1; else join_now=0; fi
    fi
    (( join_now == 1 )) && perform_join

    print_next_steps
    printf '\n'
    ok "Done."
}

# Executing the file runs the installer; sourcing it exposes the functions
# without side effects, which is how tests/run-tests.sh drives the per-distro
# logic on a machine that only runs one distro.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
