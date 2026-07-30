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
# Optionally sets up Duo Security two-factor authentication in front of the
# machine's logins, which covers local and domain accounts with one
# configuration. See the Duo section further down for why it edits per-service
# PAM files rather than common-auth or system-auth.
#
# License: MIT
#

set -uo pipefail

readonly PROGRAM_NAME="domain-join-setup"
readonly SCRIPT_VERSION="1.2.0"

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
MENU_FORCED=-1    # -1 = decide from the flags, 0 = never, 1 = always
CLI_DIRECTED=0    # set once a flag has said what to do, which skips the menu

# Duo Security two-factor authentication. The secret key is also picked up from
# the DUO_SKEY environment variable so it need not sit in the process list.
OPT_DUO=-1              # -1 = ask, 0 = no, 1 = yes
OPT_DUO_IKEY=""
OPT_DUO_SKEY="${DUO_SKEY:-}"
OPT_DUO_SKEY_FILE=""
OPT_DUO_HOST=""
OPT_DUO_PROTECT=""      # comma separated: login,sshd,sudo,none (empty = ask)
OPT_DUO_FAILMODE=""     # safe | secure (empty = safe)
OPT_DUO_AUTOPUSH=""     # yes | no (empty = derive from the chosen targets)
OPT_DUO_EXEMPT_GROUP="" # break-glass group whose members skip Duo
DUO_ADD_REPO=-1         # -1 = ask before adding Duo's own package repository
DUO_BUILD_SOURCE=-1     # -1 = ask before building Duo Unix from source

# What to install. Filled in by the choice builders, or by the matching flags.
BACKEND=""
GUI_CHOICES=""
EXTRA_CHOICES=""

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

# fetch_url <url> <destination> - HTTPS only, so a downloaded signing key or
# source archive cannot be swapped out in transit by a plaintext redirect.
#
# Deliberately not routed through run(): under --dry-run that would print the
# command, return success and leave the caller reading a file that was never
# written. Callers check DRY_RUN themselves before they get here.
fetch_url() {
    local url="$1" dest="$2" rc=0
    log_to_file "FETCH $url"
    if have curl; then
        curl -fsSL --proto '=https' --tlsv1.2 -o "$dest" "$url" || rc=$?
    elif have wget; then
        wget -q --https-only -O "$dest" "$url" || rc=$?
    else
        warn "Neither curl nor wget is installed; cannot download $url"
        return 1
    fi
    (( rc == 0 )) || warn "Download failed ($url)"
    return $rc
}

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

# ask_secret <outvar> <prompt> - like ask_value with the echo turned off, for
# the Duo secret key. There is deliberately no default: a secret that can be
# accepted by pressing Enter is a secret nobody chose.
ask_secret() {
    local outvar="$1" prompt="$2" reply
    if [[ $ASSUME_YES -eq 1 ]]; then
        printf -v "$outvar" '%s' ""
        return 0
    fi
    printf '%s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET"
    read -rs reply </dev/tty || reply=""
    printf '\n'
    printf -v "$outvar" '%s' "$reply"
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
DISTRO_ID=""; DISTRO_NAME=""; DISTRO_VERSION=""; PKG_FAMILY=""; PKG_MGR=""
# Release codename and Ubuntu lineage, both needed to name the right suite on
# third-party apt repositories. UBUNTU_CODENAME wins over VERSION_CODENAME
# because a derivative such as Linux Mint names its own releases in the latter.
DISTRO_CODENAME=""; DISTRO_UBUNTU_BASED=0

detect_distro() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found; cannot identify this system."

    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
    DISTRO_VERSION="${VERSION_ID:-}"
    DISTRO_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "${UBUNTU_CODENAME:-}" ]] && DISTRO_UBUNTU_BASED=1
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

        # --- Duo Security two-factor authentication ---------------------------
        # Candidates, not a guarantee: Duo Unix is packaged under different names
        # and, worse, some builds omit pam_duo.so entirely (Fedora's duo_unix
        # ships login_duo only). configure_duo() therefore checks for the module
        # itself rather than trusting that the package delivered it.
        debian:extra_duo) echo "duo-unix libpam-duo" ;;
        rhel:extra_duo)   echo "duo_unix" ;;
        suse:extra_duo)   echo "duo_unix" ;;
        arch:extra_duo)   echo "duo_unix" ;;

        # Build dependencies for Duo's source release, used where no package
        # carrying pam_duo.so exists.
        debian:duo_build_deps) echo "build-essential libssl-dev libpam0g-dev zlib1g-dev ca-certificates" ;;
        rhel:duo_build_deps)   echo "gcc make openssl-devel pam-devel zlib-devel ca-certificates" ;;
        suse:duo_build_deps)   echo "gcc make libopenssl-devel pam-devel zlib-devel ca-certificates" ;;
        arch:duo_build_deps)   echo "gcc make openssl pam zlib ca-certificates" ;;

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

# ini_set <file> <section> <key> <value>
#
# Sets key=value inside [section] of a plain INI file, creating the file or the
# section when either is missing and replacing an existing value in place. Like
# sssd_set_option() the contents are copied back rather than moved, so the
# original mode and ownership survive.
ini_set() {
    local f="$1" section="$2" key="$3" val="$4"

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s set %s=%s under [%s] in %s\n' \
            "$C_CYAN" "$C_RESET" "$key" "$val" "$section" "$f"
        return 0
    fi

    mkdir -p "$(dirname "$f")" || return 1

    if [[ ! -f "$f" ]]; then
        printf '[%s]\n%s=%s\n' "$section" "$key" "$val" >"$f"
        return 0
    fi

    # Blank lines inside the target section are buffered rather than printed,
    # so an inserted key attaches to the last setting instead of drifting below
    # the blank line that separates one section from the next.
    local tmp
    tmp="$(mktemp)" || return 1
    awk -v section="$section" -v key="$key" -v val="$val" '
        function flush(  i) { for (i = 1; i <= npend; i++) print pend[i]; npend = 0 }
        /^[[:space:]]*\[/ {
            # Leaving the target section without having written the key.
            if (in_section && !done) { print key "=" val; done = 1 }
            flush()
            in_section = ($0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$")
            if (in_section) seen = 1
            print; next
        }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            flush()
            if (!done) { print key "=" val; done = 1 }
            next
        }
        in_section && /^[[:space:]]*$/ { pend[++npend] = $0; next }
        { flush(); print }
        END {
            if (!done) {
                if (!seen) print "[" section "]"
                print key "=" val
            }
            flush()
        }
    ' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }

    cat "$tmp" >"$f"
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# PAM stack editing
# ---------------------------------------------------------------------------
# Everything here works on the PAM file of one *service* - /etc/pam.d/sddm,
# /etc/pam.d/sshd - and never on common-auth, system-auth or the other shared
# stacks. Two reasons. Those shared files are generated: authselect and
# pam-auth-update rewrite them and would drop a hand-added line at the next run.
# And they are included by every service on the machine, so a second factor
# there lands on sudo, su, cron and polkit as well as the login screen.
#
# A rule appended to a service's auth stack is only reached if nothing before it
# can return success for the whole stack. Two constructs can:
#
#   sufficient    succeeds -> PAM returns from the stack immediately
#   include       splices another file in, so a 'sufficient' inside it counts
#
# 'substack' does not: a sufficient inside a substack ends only the substack, so
# the parent stack carries on. That distinction decides where the Duo rule goes,
# which is why it is measured rather than assumed.

# Lines that participate in the auth stack: real auth rules, the optional-module
# "-auth" form, and Debian's @include, which splices every type at once.
PAM_AUTH_ANCHOR_RE='^[[:space:]]*(-?auth[[:space:]]|@include[[:space:]])'

# pam_auth_can_short_circuit <file> [depth] - true when the stack can return
# success before the end, so anything appended would be skipped.
pam_auth_can_short_circuit() {
    local f="$1" depth="${2:-0}" line rest target
    (( depth > 4 )) && return 1            # malformed include loop; assume the worst
    [[ -f "$f" ]] || return 1

    # PAM resolves a bare include name against the directory holding the file
    # that names it, so the recursion follows suit instead of assuming /etc/pam.d.
    local dir
    dir="$(dirname "$f")"

    while IFS= read -r line; do
        # A jump rule that ends the stack on success, e.g. [success=done ...].
        [[ "$line" == *success=done* ]] && return 0

        rest="${line#@include}"
        if [[ "$rest" != "$line" ]]; then
            target="${rest//[[:space:]]/}"
            [[ -n "$target" ]] || continue
            [[ "$target" == /* ]] || target="$dir/$target"
            pam_auth_can_short_circuit "$target" $(( depth + 1 )) && return 0
            continue
        fi

        rest="${line#-}"; rest="${rest#auth}"
        rest="${rest#"${rest%%[![:space:]]*}"}"     # drop the leading whitespace
        case "$rest" in
            sufficient*) return 0 ;;
            include*)
                target="${rest#include}"
                target="${target//[[:space:]]/}"
                [[ -n "$target" ]] || continue
                [[ "$target" == /* ]] || target="$dir/$target"
                pam_auth_can_short_circuit "$target" $(( depth + 1 )) && return 0
                ;;
        esac
    done < <(grep -E "$PAM_AUTH_ANCHOR_RE" "$f" 2>/dev/null | sed 's/^[[:space:]]*//')

    return 1
}

# pam_auth_anchor <file> - line number of the last rule in the auth stack, or
# nothing when the file has none.
pam_auth_anchor() {
    grep -nE "$PAM_AUTH_ANCHOR_RE" "$1" 2>/dev/null | tail -1 | cut -d: -f1
}

# pam_auth_first <file> - line number of the first rule in the auth stack.
pam_auth_first() {
    grep -nE "$PAM_AUTH_ANCHOR_RE" "$1" 2>/dev/null | head -1 | cut -d: -f1
}

# pam_add_auth <file> <rule> <token>
#
# Inserts <rule> into the auth stack of <file> and reports where it went:
#   0  after the existing rules - the second factor follows the password
#   3  before them, because the stack short-circuits and anything after the
#      password check would never run; the Duo prompt then comes first
#   1  nothing was changed
#
# <token> is what identifies the rule as already present, so a second run is a
# no-op rather than a second copy.
pam_add_auth() {
    local f="$1" rule="$2" token="$3"
    local anchor position="after"

    [[ -f "$f" ]] || { warn "$f does not exist; skipping it."; return 1; }

    if grep -q "$token" "$f"; then
        ok "$f already carries $token"
        return 0
    fi

    if pam_auth_can_short_circuit "$f"; then
        position="before"
        anchor="$(pam_auth_first "$f")"
    else
        anchor="$(pam_auth_anchor "$f")"
    fi

    if [[ -z "$anchor" ]]; then
        warn "$f has no auth rules to attach to; skipping it."
        return 1
    fi

    backup_file "$f"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s %s: insert %s the auth stack -> %s\n' \
            "$C_CYAN" "$C_RESET" "$f" "$position" "$rule"
        [[ "$position" == "before" ]] && return 3
        return 0
    fi

    local tmp
    tmp="$(mktemp)" || return 1
    if [[ "$position" == "before" ]]; then
        awk -v n="$anchor" -v rule="$rule" 'NR == n { print rule } { print }' "$f" >"$tmp" \
            || { rm -f "$tmp"; return 1; }
    else
        awk -v n="$anchor" -v rule="$rule" '{ print } NR == n { print rule }' "$f" >"$tmp" \
            || { rm -f "$tmp"; return 1; }
    fi

    # Copied back rather than moved, so the file keeps its mode and ownership.
    cat "$tmp" >"$f"
    rm -f "$tmp"

    ok "$f: added the rule $position the existing auth stack"
    [[ "$position" == "before" ]] && return 3
    return 0
}

# pam_remove_auth <file> <token> - takes the rule out again.
pam_remove_auth() {
    local f="$1" token="$2"
    [[ -f "$f" ]] || return 0
    grep -q "$token" "$f" || return 0
    backup_file "$f"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s remove every %s rule from %s\n' "$C_CYAN" "$C_RESET" "$token" "$f"
        return 0
    fi
    local tmp
    tmp="$(mktemp)" || return 1
    # grep exits 1 when it selects nothing, which for an inverted match means the
    # file was nothing but the rule being removed. Judge by the output, not the
    # exit status, so a PAM file is never truncated on a technicality.
    grep -v "$token" "$f" >"$tmp"
    if [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        warn "Refusing to empty $f; remove the $token rule by hand."
        return 1
    fi
    cat "$tmp" >"$f"
    rm -f "$tmp"
    ok "$f: $token removed"
}

# ---------------------------------------------------------------------------
# SDDM login screen
# ---------------------------------------------------------------------------
# The three probes below are read-only, so they run under --dry-run too and
# keep the preview honest.

# active_display_manager - the unit behind display-manager.service ("sddm",
# "gdm3", "lightdm", ...), or nothing when it cannot be determined.
active_display_manager() {
    local target
    target="$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null)" || return 0
    [[ -n "$target" ]] || return 0
    target="${target##*/}"
    printf '%s' "${target%.service}"
}

# sddm_current_theme - the theme SDDM will actually load. Later files win,
# matching SDDM's own read order.
sddm_current_theme() {
    local theme="" f val
    for f in /usr/lib/sddm/sddm.conf.d/*.conf /etc/sddm.conf /etc/sddm.conf.d/*.conf; do
        [[ -f "$f" ]] || continue
        val="$(awk -F= '/^[[:space:]]*Current[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2 }' "$f" | tail -1)"
        [[ -n "$val" ]] && theme="$val"
    done
    printf '%s' "${theme:-breeze}"
}

# version_has_last_user_model <version> - true when a version string is at
# least 0.20, where needsFullUserModel arrived. Split out from the probe below
# so the comparison can be tested without SDDM installed.
version_has_last_user_model() {
    local ver="$1" major minor
    ver="$(printf '%s' "$ver" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    [[ -n "$ver" ]] || return 1
    major="${ver%%.*}"; minor="${ver##*.}"
    (( 10#$major > 0 )) && return 0
    (( 10#$minor >= 20 ))
}

# sddm_has_last_user_model - true when the installed SDDM understands
# needsFullUserModel. Older builds can only show an enumerated user list.
sddm_has_last_user_model() {
    have sddm || return 1
    version_has_last_user_model "$(sddm --version 2>/dev/null)"
}

# configure_sddm_greeter - put the domain user back on the login screen.
#
# SDDM builds its user list with getpwent(), which SSSD deliberately answers
# with local accounts only, and then filters it by UID range. A domain user
# therefore fails twice over and the greeter offers nothing but "Other". Rather
# than enumerate the directory, this switches the theme to SDDM's last-user
# model: one getpwnam() against the name in /var/lib/sddm/state.conf, which
# SSSD resolves happily. The result is the Windows behaviour - the machine's
# owner sees their own tile and types only a password.
#
# The menu can reach this twice in one run - directly, and again through
# post_join_tuning after a join - so the second call is a no-op.
SDDM_GREETER_DONE=0
configure_sddm_greeter() {
    (( SDDM_GREETER_DONE )) && return 0
    SDDM_GREETER_DONE=1

    [[ "$(active_display_manager)" == "sddm" ]] || return 0

    printf '\n'
    note "SDDM lists local accounts only, so a domain user has to click 'Other' every time."
    if ! confirm "Show the last domain user on the SDDM login screen instead?" "y"; then
        note "Login screen left unchanged."
        return 0
    fi

    # AD accounts get algorithmic UIDs far above the greeter's 60000 default,
    # so lift the ceiling to the top of SSSD's ID mapping range.
    local uid_max
    uid_max="$(awk -F= '/^[[:space:]]*ldap_idmap_range_max[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); print $2 }' \
        /etc/sssd/sssd.conf 2>/dev/null | tail -1)"
    [[ "$uid_max" =~ ^[0-9]+$ ]] || uid_max=2000200000

    local dropin="/etc/sddm.conf.d/10-domain-users.conf"
    backup_file "$dropin"
    ini_set "$dropin" Users MinimumUid 1000       || { warn "Could not write $dropin."; return 0; }
    ini_set "$dropin" Users MaximumUid "$uid_max" || { warn "Could not write $dropin."; return 0; }
    ini_set "$dropin" Users RememberLastUser true || { warn "Could not write $dropin."; return 0; }
    [[ $DRY_RUN -eq 0 ]] && ok "$dropin: UID ceiling raised to $uid_max"

    if ! sddm_has_last_user_model; then
        warn "This SDDM predates needsFullUserModel (0.20); the greeter will keep listing local users only."
        note "Either upgrade SDDM, or set 'enumerate = true' in sssd.conf together with an"
        note "ldap_user_search_base scoped to one OU, so the whole directory is not pulled."
        return 0
    fi

    local theme theme_dir
    theme="$(sddm_current_theme)"
    for theme_dir in "/usr/share/sddm/themes/$theme" "/usr/local/share/sddm/themes/$theme"; do
        [[ -d "$theme_dir" ]] && break
        theme_dir=""
    done
    if [[ -z "$theme_dir" ]]; then
        warn "SDDM theme '$theme' was not found; skipping the theme override."
        return 0
    fi

    # theme.conf.user is SDDM's own override file, so the packaged theme.conf
    # stays untouched and the change survives a Plasma upgrade.
    local override="$theme_dir/theme.conf.user"
    backup_file "$override"
    if ! ini_set "$override" General needsFullUserModel false; then
        warn "Could not write $override."
        return 0
    fi
    [[ $DRY_RUN -eq 0 ]] && ok "$override: greeter shows the last logged-in user"

    note "Applies at the next login screen -- do not restart sddm from inside a session."
    note "The first domain login still goes through 'Other'; the account is remembered after that."
}

# ---------------------------------------------------------------------------
# Duo Security two-factor authentication
# ---------------------------------------------------------------------------
# Duo Unix adds a second factor on top of whichever first factor is already in
# place, which is what makes it work for local accounts and Active Directory
# accounts at the same time: pam_duo.so runs after the password module, and it
# neither knows nor cares whether pam_unix, pam_sss or pam_winbind validated
# that password. The username it sends to Duo is simply the PAM username, so
# short domain names line up with a Duo directory by themselves once
# post_join_tuning has set use_fully_qualified_names = False.
#
# What Duo Unix cannot do is draw a dialog. It talks over the PAM conversation
# in text, so a graphical greeter shows its prompts as a plain line of text at
# best. The practical configuration for a desktop is therefore autopush, which
# sends a push notification and needs no typing at all.

# Not readonly: the test suite redirects it at a temporary file so the handling
# of a file that holds a shared secret is covered without needing root.
DUO_CONF="/etc/duo/pam_duo.conf"
readonly DUO_GPG_KEY_URL="https://duo.com/DUO-GPG-PUBLIC-KEY.asc"
readonly DUO_KEYRING="/usr/share/keyrings/duo-archive-keyring.gpg"
readonly DUO_SOURCE_URL="https://dl.duosecurity.com/duo_unix-latest.tar.gz"
readonly DUO_DEFAULT_EXEMPT_GROUP="duo-exempt"

DUO_CONFIGURED=0        # set once the module, credentials and PAM are all in place
DUO_PAM_FILES=""        # the service files that were edited, for the summary

# --- Locating the module ---------------------------------------------------
# The directories a PAM module could plausibly be in. Debian and Ubuntu use a
# multiarch path, the RPM distributions use /lib64/security, and a source build
# can land under /usr/local.
DUO_PAM_SEARCH_DIRS=(
    /lib/security /lib64/security
    /usr/lib/security /usr/lib64/security /usr/lib/*/security
    /usr/local/lib/security /usr/local/lib64/security
)

# pam_module_dir - where this system actually keeps its PAM modules, found by
# looking for one that is certainly present. libpam's module directory is
# compiled in and cannot be queried, so the location of pam_unix.so stands in
# for it: whatever directory that is in is the directory PAM searches.
pam_module_dir() {
    local d
    for d in "${DUO_PAM_SEARCH_DIRS[@]}"; do
        [[ -f "$d/pam_unix.so" ]] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

# duo_pam_module - absolute path of pam_duo.so, or nothing when it is absent.
duo_pam_module() {
    local d
    for d in "${DUO_PAM_SEARCH_DIRS[@]}"; do
        [[ -f "$d/pam_duo.so" ]] && { printf '%s' "$d/pam_duo.so"; return 0; }
    done
    return 1
}

# duo_pam_module_arg - how the module should be named in a PAM file. A module in
# the directory PAM searches goes in by name; one anywhere else - a source build
# that guessed the directory wrong - needs its absolute path, or PAM will report
# the module as missing and, depending on the control flag, let logins straight
# through.
duo_pam_module_arg() {
    local path dir moddir
    path="$(duo_pam_module)" || return 1
    dir="$(dirname "$path")"
    moddir="$(pam_module_dir)" || moddir=""
    if [[ -n "$moddir" && "$dir" -ef "$moddir" ]]; then
        printf 'pam_duo.so'
    else
        printf '%s' "$path"
    fi
}

# --- Credential validation -------------------------------------------------
# Duo's own formats. Checked because the failure they prevent is silent: a
# mistyped key produces a working-looking PAM stack that denies every login the
# first time somebody tries to use it.
valid_duo_ikey() { [[ "$1" =~ ^[A-Z0-9]{20}$ ]]; }
valid_duo_skey() { [[ "$1" =~ ^[A-Za-z0-9]{40}$ ]]; }
valid_duo_host() { [[ "$1" =~ ^api-[A-Za-z0-9]+\.duo(security|federal)\.com$ ]]; }

# duo_conf_get <key> [file] - one value out of the Duo config file.
duo_conf_get() {
    local key="$1" f="${2:-$DUO_CONF}"
    awk -F= -v key="$key" \
        '$0 ~ "^[[:space:]]*" key "[[:space:]]*=" { gsub(/[[:space:]]/, "", $2); print $2 }' \
        "$f" 2>/dev/null | tail -1
}

# duo_conf_is_configured [file] - true when the config already holds all three
# values in a plausible shape, so a re-run does not have to ask again.
duo_conf_is_configured() {
    local f="${1:-$DUO_CONF}"
    [[ -r "$f" ]] || return 1
    valid_duo_ikey "$(duo_conf_get ikey "$f")" \
        && valid_duo_skey "$(duo_conf_get skey "$f")" \
        && valid_duo_host "$(duo_conf_get host "$f")"
}

# duo_conf_host [file] - the API host recorded in the config file.
duo_conf_host() {
    duo_conf_get host "${1:-$DUO_CONF}"
}

# duo_ask_until_valid <outvar> <prompt> <validator> <hint> [secret]
#
# Keeps asking until the value passes, or the operator insists on the value they
# typed, or three attempts are up. A wrong value can still be forced through -
# Duo may introduce a format this script has not heard of - but never silently.
duo_ask_until_valid() {
    local outvar="$1" prompt="$2" validator="$3" hint="$4" secret="${5:-0}"
    local value="${!outvar}" attempts=0 shown

    while true; do
        if [[ -n "$value" ]] && "$validator" "$value"; then
            printf -v "$outvar" '%s' "$value"
            return 0
        fi
        if [[ -n "$value" ]]; then
            warn "$hint"
            shown="$value"
            (( secret )) && shown="(the value you typed)"
            if confirm "Use $shown anyway?" "n"; then
                printf -v "$outvar" '%s' "$value"
                return 0
            fi
        fi
        if (( ASSUME_YES )); then
            err "No valid value for '$prompt' was supplied, and -y cannot ask for one."
            return 1
        fi
        if (( attempts >= 3 )); then
            err "Giving up on '$prompt' after three attempts."
            return 1
        fi
        attempts=$(( attempts + 1 ))
        if (( secret )); then
            ask_secret value "$prompt"
        else
            ask_value value "$prompt" ""
        fi
    done
}

# --- Getting hold of pam_duo.so -------------------------------------------
# duo_repo_kind - which official Duo repository fits this system.
#   apt  Debian and Ubuntu, addressed by release codename
#   yum  RHEL and its rebuilds, addressed by major version
#   ""   Fedora, openSUSE and Arch, for which Duo publishes nothing; those go
#        through the source build instead
duo_repo_kind() {
    case "$PKG_FAMILY" in
        debian)
            [[ -n "$DISTRO_CODENAME" ]] && printf 'apt'
            ;;
        rhel)
            # Duo's RedHat tree is indexed by RHEL major version, so Fedora's
            # releasever (44, 45...) has nowhere to point.
            case "$DISTRO_ID" in
                fedora|nobara|bazzite) ;;
                *) [[ -n "$DISTRO_VERSION" ]] && printf 'yum' ;;
            esac
            ;;
    esac
}

# duo_apt_suite - the directory Duo publishes this lineage under.
duo_apt_suite() {
    (( DISTRO_UBUNTU_BASED )) && printf 'Ubuntu' || printf 'Debian'
}

# duo_gate <gate_var> <prompt> - a three-state gate: the flag said yes, the flag
# said no, or nobody has said anything yet and the operator is asked.
duo_gate() {
    local gate="$1" prompt="$2"
    case "${!gate}" in
        1) return 0 ;;
        0) return 1 ;;
        *) confirm "$prompt" "n" ;;
    esac
}

duo_add_apt_repo() {
    local list="/etc/apt/sources.list.d/duosecurity.list" suite
    suite="$(duo_apt_suite)"

    if [[ -z "$DISTRO_CODENAME" ]]; then
        warn "Cannot determine this release's codename, so the Duo suite is unknown."
        return 1
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s import %s into %s\n' "$C_CYAN" "$C_RESET" "$DUO_GPG_KEY_URL" "$DUO_KEYRING"
        printf '%s  [dry-run]%s write %s -> pkg.duosecurity.com/%s %s main\n' \
            "$C_CYAN" "$C_RESET" "$list" "$suite" "$DISTRO_CODENAME"
        return 0
    fi

    have gpg || { warn "gnupg is not installed, so the Duo signing key cannot be imported."; return 1; }

    local tmp
    tmp="$(mktemp)" || return 1
    fetch_url "$DUO_GPG_KEY_URL" "$tmp" || { rm -f "$tmp"; return 1; }

    printf '\n'
    info "Signing key offered by duo.com:"
    gpg --show-keys --with-fingerprint "$tmp" 2>/dev/null | sed 's/^/    /'
    note "Check that fingerprint against Duo's published one before accepting it."
    if ! confirm "Trust this key to sign packages for this machine?" "n"; then
        rm -f "$tmp"
        note "Key rejected; the Duo repository was not added."
        return 1
    fi

    mkdir -p "$(dirname "$DUO_KEYRING")"
    if ! gpg --batch --yes --dearmor --output "$DUO_KEYRING" "$tmp"; then
        rm -f "$tmp"
        warn "Could not convert the Duo signing key into a keyring."
        return 1
    fi
    rm -f "$tmp"
    chmod 0644 "$DUO_KEYRING"

    backup_file "$list"
    printf '# Added by %s\ndeb [signed-by=%s] https://pkg.duosecurity.com/%s %s main\n' \
        "$PROGRAM_NAME" "$DUO_KEYRING" "$suite" "$DISTRO_CODENAME" >"$list"
    chmod 0644 "$list"
    ok "$list written (signed-by $DUO_KEYRING)"

    REPO_REFRESHED=0
    refresh_repos
}

duo_add_yum_repo() {
    local repo="/etc/yum.repos.d/duosecurity.repo"

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s write %s -> pkg.duosecurity.com/RedHat/$releasever/$basearch\n' \
            "$C_CYAN" "$C_RESET" "$repo"
        return 0
    fi

    backup_file "$repo"
    cat >"$repo" <<EOF
# Added by $PROGRAM_NAME
[duosecurity]
name=Duo Security Repository
baseurl=https://pkg.duosecurity.com/RedHat/\$releasever/\$basearch
enabled=1
gpgcheck=1
gpgkey=$DUO_GPG_KEY_URL
EOF
    chmod 0644 "$repo"
    ok "$repo written"
    note "The first install from it will ask you to accept Duo's signing key."

    REPO_REFRESHED=0
    refresh_repos
}

# add_duo_repo - offer Duo's own package repository, which is a third-party
# source and so is never added without being asked for.
add_duo_repo() {
    local kind
    kind="$(duo_repo_kind)"
    [[ -n "$kind" ]] || return 1

    printf '\n'
    note "Duo publishes signed packages of its own at pkg.duosecurity.com."
    note "Adding it means this machine trusts Duo to ship it software."
    duo_gate DUO_ADD_REPO "Add the official Duo package repository?" || {
        note "Duo repository not added."
        return 1
    }

    case "$kind" in
        apt) duo_add_apt_repo ;;
        yum) duo_add_yum_repo ;;
    esac
}

# duo_verify_tarball - check the source archive against Duo's signing key, and
# fall back to showing the checksum when no detached signature is published.
duo_verify_tarball() {
    local tarball="$1" work="$2"
    local sig="$work/duo_unix.tar.gz.asc" key="$work/duo-key.asc"
    local gnupghome="$work/gnupg"

    if have gpg \
       && fetch_url "${DUO_SOURCE_URL}.asc" "$sig" 2>/dev/null \
       && fetch_url "$DUO_GPG_KEY_URL" "$key" 2>/dev/null; then
        mkdir -p "$gnupghome" && chmod 0700 "$gnupghome"
        if GNUPGHOME="$gnupghome" gpg --batch --quiet --import "$key" 2>/dev/null \
           && GNUPGHOME="$gnupghome" gpg --batch --verify "$sig" "$tarball" 2>&1 \
              | grep -q 'Good signature'; then
            ok "Source archive carries a good signature from Duo's key."
            return 0
        fi
        err "The source archive did not verify against Duo's signing key."
        return 1
    fi

    warn "No detached signature was available for the source archive."
    have sha256sum && note "SHA256: $(sha256sum "$tarball" | awk '{print $1}')"
    note "Compare it with the checksum Duo publishes at https://duo.com/docs/duounix"
    confirm "Build from this unverified archive anyway?" "n"
}

# duo_build_from_source - the fallback for the distributions Duo does not
# package. Installs under /usr/local so nothing collides with the package
# manager, and reads /etc/duo like a packaged build would.
duo_build_from_source() {
    # Duo's own configure defaults sysconfdir to /etc/duo, but only while it is
    # untouched - passing --sysconfdir explicitly would silently point pam_duo at
    # a different file from the one this script writes, and a pam_duo that finds
    # no keys fails every authentication. So the default is left alone.
    local pamdir
    pamdir="$(pam_module_dir)" || pamdir=""

    printf '\n'
    note "No package on this system carries pam_duo.so, so it has to be compiled"
    note "from Duo's source release. login_duo and the libraries go under"
    note "/usr/local; pam_duo.so goes to ${pamdir:-the PAM module directory},"
    note "where PAM looks for it, and the configuration stays in /etc/duo."
    note "'sudo make uninstall' in the build tree reverses all of it."
    duo_gate DUO_BUILD_SOURCE "Build Duo Unix from source now?" || {
        note "Duo Unix not built."
        return 1
    }

    local -a deps=()
    read -r -a deps <<<"$(pkgs_for duo_build_deps)"
    if [[ ${#deps[@]} -gt 0 ]]; then
        refresh_repos
        filter_available "${deps[@]}"
        if [[ ${#AVAILABLE_PACKAGES[@]} -gt 0 ]]; then
            install_packages "${AVAILABLE_PACKAGES[@]}" \
                || { err "The build dependencies would not install."; return 1; }
        fi
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s download %s, then ./configure --with-pam%s --prefix=/usr/local, make, make install\n' \
            "$C_CYAN" "$C_RESET" "$DUO_SOURCE_URL" "${pamdir:+=$pamdir}"
        return 0
    fi

    local work
    work="$(mktemp -d)" || return 1
    local tarball="$work/duo_unix.tar.gz"

    info "Downloading Duo Unix"
    fetch_url "$DUO_SOURCE_URL" "$tarball" || { rm -rf "$work"; return 1; }
    duo_verify_tarball "$tarball" "$work" || { rm -rf "$work"; return 1; }

    if ! tar -xzf "$tarball" -C "$work"; then
        rm -rf "$work"
        err "The source archive would not unpack."
        return 1
    fi

    local src
    src="$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'duo_unix-*' | head -1)"
    if [[ -z "$src" ]]; then
        rm -rf "$work"
        err "Unexpected layout inside the source archive."
        return 1
    fi

    # --with-pam=DIR overrides where the module is installed. Without a DIR the
    # build hard-codes /lib64/security on x86_64, which is right on the RPM
    # distributions and wrong on Debian's multiarch layout - so the directory the
    # system's own PAM modules live in is passed in explicitly.
    info "Building Duo Unix (this takes a minute)"
    log_to_file "BUILD $src"
    if ! (
        cd "$src" || exit 1
        ./configure "--with-pam${pamdir:+=$pamdir}" --prefix=/usr/local >"$work/build.log" 2>&1 \
            && make >>"$work/build.log" 2>&1 \
            && make install >>"$work/build.log" 2>&1
    ); then
        err "The build failed. Its log is at $work/build.log, which is left in place."
        tail -20 "$work/build.log" 2>/dev/null | sed 's/^/    /' >&2
        return 1
    fi

    have ldconfig && ldconfig 2>/dev/null
    ok "Duo Unix built and installed under /usr/local"
    note "Build tree kept at $src -- 'sudo make uninstall' there removes it again."
    return 0
}

# duo_install - get pam_duo.so onto the machine, trying the cheapest source
# first: the distribution repositories, then Duo's own, then a source build.
duo_install() {
    local -a cands=()
    local installed_something=0
    read -r -a cands <<<"$(pkgs_for extra_duo)"

    if [[ ${#cands[@]} -gt 0 ]]; then
        refresh_repos
        filter_available "${cands[@]}"
        if [[ ${#AVAILABLE_PACKAGES[@]} -gt 0 ]]; then
            info "Installing Duo Unix from the distribution repositories"
            if install_packages "${AVAILABLE_PACKAGES[@]}"; then
                installed_something=1
            else
                warn "The distribution's Duo package would not install."
            fi
        else
            note "No Duo package in this system's repositories."
        fi
    fi
    duo_pam_module >/dev/null && { ok "pam_duo.so came from the distribution package."; return 0; }

    # A package that installed but brought no module is the common case, not an
    # error: Fedora's duo_unix deliberately ships login_duo only.
    if (( installed_something )) && [[ $DRY_RUN -eq 0 ]]; then
        warn "The installed Duo package does not include pam_duo.so."
        note "Some distributions build Duo Unix without PAM support."
    fi

    if [[ -n "$(duo_repo_kind)" ]] && add_duo_repo; then
        filter_available "${cands[@]}"
        if [[ ${#AVAILABLE_PACKAGES[@]} -gt 0 ]]; then
            install_packages "${AVAILABLE_PACKAGES[@]}" \
                || warn "The Duo package would not install from Duo's repository."
        fi
        duo_pam_module >/dev/null && { ok "pam_duo.so came from Duo's repository."; return 0; }
    fi

    duo_build_from_source && return 0
    return 1
}

# --- Configuration ---------------------------------------------------------
# duo_conf_set <key> <value> [secret] - ini_set against the Duo config, with the
# secret key kept out of the dry-run transcript and the log.
duo_conf_set() {
    local key="$1" value="$2" secret="${3:-0}" shown="$2"
    (( secret )) && shown="<hidden>"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s set %s=%s under [duo] in %s\n' \
            "$C_CYAN" "$C_RESET" "$key" "$shown" "$DUO_CONF"
        return 0
    fi
    ini_set "$DUO_CONF" duo "$key" "$value"
}

# duo_write_conf <failmode> <autopush> <exempt_group>
#
# Collects the credentials and writes /etc/duo/pam_duo.conf at 0600. pam_duo
# reads the secret key out of this file on every authentication, so its mode is
# established before anything is written into it, never afterwards.
duo_write_conf() {
    local failmode="$1" autopush="$2" exempt="$3"
    local d_ikey="$OPT_DUO_IKEY" d_skey="" d_host="$OPT_DUO_HOST"

    if [[ -n "$OPT_DUO_SKEY_FILE" ]]; then
        if [[ -r "$OPT_DUO_SKEY_FILE" ]]; then
            d_skey="$(head -1 "$OPT_DUO_SKEY_FILE" | tr -d '[:space:]')"
        else
            warn "Cannot read the secret key file $OPT_DUO_SKEY_FILE."
        fi
    fi
    [[ -z "$d_skey" ]] && d_skey="$OPT_DUO_SKEY"

    if [[ -z "$d_ikey$d_skey$d_host" ]] && duo_conf_is_configured; then
        ok "$DUO_CONF already holds an integration key, secret key and API host."
        if ! confirm "Replace those credentials?" "n"; then
            note "Existing Duo credentials kept."
            duo_conf_set failmode "$failmode"
            duo_conf_set autopush "$autopush"
            [[ -n "$exempt" ]] && duo_conf_set groups "*,!$exempt"
            return 0
        fi
    fi

    printf '\n'
    note "These three values come from the Duo Admin Panel: Applications > add a"
    note "'Unix Application', which yields an integration key, a secret key and"
    note "an API hostname. The secret key is not echoed as you type it."
    printf '\n'

    duo_ask_until_valid d_ikey "Duo integration key (ikey)" valid_duo_ikey \
        "An integration key is 20 characters of upper case letters and digits, starting DI." || return 1
    duo_ask_until_valid d_skey "Duo secret key (skey)" valid_duo_skey \
        "A secret key is 40 alphanumeric characters." 1 || return 1
    duo_ask_until_valid d_host "Duo API hostname (host)" valid_duo_host \
        "An API hostname looks like api-1234abcd.duosecurity.com." || return 1

    if [[ $DRY_RUN -eq 0 ]]; then
        mkdir -p "$(dirname "$DUO_CONF")" || { err "Cannot create $(dirname "$DUO_CONF")."; return 1; }
        chmod 0755 "$(dirname "$DUO_CONF")"
        backup_file "$DUO_CONF"
        if [[ ! -f "$DUO_CONF" ]]; then
            : >"$DUO_CONF" || { err "Cannot create $DUO_CONF."; return 1; }
        fi
        chown root:root "$DUO_CONF" 2>/dev/null
        chmod 0600 "$DUO_CONF"
    fi

    duo_conf_set ikey "$d_ikey"      || { err "Could not write to $DUO_CONF."; return 1; }
    duo_conf_set skey "$d_skey" 1    || { err "Could not write to $DUO_CONF."; return 1; }
    duo_conf_set host "$d_host"      || { err "Could not write to $DUO_CONF."; return 1; }
    duo_conf_set failmode "$failmode"
    duo_conf_set pushinfo yes
    duo_conf_set autopush "$autopush"
    # prompts is the number of attempts pam_duo allows before denying, default 3.
    # One is right for a greeter, which has no good way to show a second prompt:
    # a rejected or timed-out push fails the login rather than hanging on a
    # question nobody can read.
    duo_conf_set prompts 1
    [[ -n "$exempt" ]] && duo_conf_set groups "*,!$exempt"

    [[ $DRY_RUN -eq 0 ]] && ok "$DUO_CONF written, root-owned and mode 0600"
    return 0
}

# duo_check_api <host> - unauthenticated reachability probe. /auth/v2/ping needs
# no signature, so it tells "cannot reach Duo" apart from "wrong keys".
duo_check_api() {
    local host="$1"
    [[ -n "$host" ]] || return 0
    if [[ $DRY_RUN -eq 1 ]]; then
        note "Would check that https://$host/auth/v2/ping answers."
        return 0
    fi
    have curl || { note "curl is not installed; skipping the Duo reachability check."; return 0; }
    if curl -fsS --max-time 10 "https://$host/auth/v2/ping" 2>/dev/null | grep -q '"stat"'; then
        ok "Duo's API at $host answers"
    else
        warn "https://$host/auth/v2/ping did not answer."
        note "Check the API hostname, DNS, and outbound 443 through any proxy."
        note "pam_duo also honours http_proxy in $DUO_CONF if one is required."
    fi
}

# --- Which services get the second factor ----------------------------------
# duo_login_pam_files - the display manager's own PAM service file plus the
# console login. Both are per-service files that no generator rewrites.
duo_login_pam_files() {
    local -a candidates=() out=()
    local dm f
    dm="$(active_display_manager)"

    case "$dm" in
        sddm)                             candidates+=(/etc/pam.d/sddm) ;;
        plasmalogin|plasma-login-manager) candidates+=(/etc/pam.d/kde /etc/pam.d/plasmalogin) ;;
        gdm|gdm3)                         candidates+=(/etc/pam.d/gdm-password) ;;
        lightdm)                          candidates+=(/etc/pam.d/lightdm) ;;
        lxdm)                             candidates+=(/etc/pam.d/lxdm) ;;
        greetd)                           candidates+=(/etc/pam.d/greetd) ;;
        ly)                               candidates+=(/etc/pam.d/ly) ;;
    esac

    # A text console login bypasses the greeter entirely, so it is covered too.
    candidates+=(/etc/pam.d/login)

    for f in "${candidates[@]}"; do
        [[ -f "$f" ]] && out+=("$f")
    done
    printf '%s\n' ${out[@]+"${out[@]}"}
}

duo_sshd_pam_files() {
    [[ -f /etc/pam.d/sshd ]] && printf '%s\n' /etc/pam.d/sshd
    return 0
}

duo_sudo_pam_files() {
    local f
    for f in /etc/pam.d/sudo /etc/pam.d/sudo-i; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
    return 0
}

# duo_target_files <target> - the PAM files behind one menu choice.
duo_target_files() {
    case "$1" in
        login) duo_login_pam_files ;;
        sshd)  duo_sshd_pam_files ;;
        sudo)  duo_sudo_pam_files ;;
    esac
}

duo_choose_targets() {
    local outvar="$1"
    local -a entries=()
    local login_files
    login_files="$(duo_login_pam_files | tr '\n' ' ')"
    login_files="${login_files% }"

    entries+=("login|Desktop and console logins  ${C_GREEN}(recommended)${C_RESET}|Adds the second factor to ${login_files:-the display manager and console PAM files}. This is the one that protects the machine itself, and it covers local accounts and domain accounts together because both arrive through the same service file.")
    entries+=("sshd|Remote SSH logins|Adds it to /etc/pam.d/sshd. sshd must also have 'UsePAM yes' and 'KbdInteractiveAuthentication yes' for the Duo conversation to reach the client; both are checked afterwards.")
    entries+=("sudo|sudo|Asks for a second factor on every privilege escalation as well. Thorough, but each sudo then waits on a phone, and Plasma's graphical polkit prompt cannot show Duo's text conversation at all - so this is off by default.")

    menu_multi "$outvar" "Which logins should require a Duo second factor?" "login" "${entries[@]}"
}

# duo_setup_exempt_group - a local group whose members skip Duo entirely.
#
# This is the break-glass path, and it is the difference between a second factor
# and a locked door. If Duo is unreachable and failmode is secure, or an
# enrolment goes wrong, or a phone is lost, the account in this group is how the
# machine gets fixed. Duo's 'groups' directive is evaluated by pam_duo itself, so
# the exemption holds even when the Duo service cannot be reached at all.
duo_setup_exempt_group() {
    local outvar="$1" group="$OPT_DUO_EXEMPT_GROUP" member=""

    if [[ -n "$group" ]]; then
        printf -v "$outvar" '%s' "$group"
    else
        printf '\n'
        note "A break-glass group is strongly advised: its members skip Duo, so one"
        note "local account can still get in if Duo is unreachable or a phone is lost."
        if ! confirm "Create a group whose members bypass Duo?" "y"; then
            warn "No bypass group. If Duo becomes unreachable, every login here depends"
            warn "on failmode alone."
            printf -v "$outvar" '%s' ""
            return 0
        fi
        ask_value group "Name for the bypass group" "$DUO_DEFAULT_EXEMPT_GROUP"
        [[ -z "$group" ]] && group="$DUO_DEFAULT_EXEMPT_GROUP"
        printf -v "$outvar" '%s' "$group"
    fi

    if have getent && getent group "$group" >/dev/null 2>&1; then
        ok "Group '$group' already exists"
    elif have groupadd; then
        run_quiet groupadd -f "$group" && ok "Group '$group' created" \
            || warn "Could not create the group '$group'."
    else
        warn "groupadd is not available; create the group '$group' by hand."
    fi

    # The account that invoked sudo is the obvious candidate, since it is the one
    # already known to have administrative access to this machine.
    member="${SUDO_USER:-}"
    if [[ -n "$member" ]] && have usermod; then
        if id -nG "$member" 2>/dev/null | tr ' ' '\n' | grep -qx "$group"; then
            ok "$member is already in '$group'"
        elif confirm "Add '$member' to '$group' as the break-glass account?" "y"; then
            run_quiet usermod -aG "$group" "$member" \
                && ok "$member added to '$group'" \
                || warn "Could not add $member to $group."
            note "Group membership applies at $member's next login, not this session."
        fi
    else
        note "Add your break-glass account with: sudo usermod -aG $group <user>"
    fi
    return 0
}

# duo_check_sshd_config - pam_duo can only talk to an SSH client through
# keyboard-interactive authentication, so report on it rather than leaving a
# stack that silently never prompts.
duo_check_sshd_config() {
    local cfg="/etc/ssh/sshd_config"
    [[ -f "$cfg" ]] || { note "No $cfg found; check the SSH server's PAM settings by hand."; return 0; }

    # sshd_config is normally mode 0600, so an unprivileged preview cannot read
    # it. Say that, rather than draw conclusions from greps that all failed.
    if [[ ! -r "$cfg" ]]; then
        note "$cfg is not readable by this user, so its settings were not checked."
        note "Duo needs 'UsePAM yes' and 'KbdInteractiveAuthentication yes' there."
        return 0
    fi

    local effective="" needed=()
    if have sshd; then
        effective="$(sshd -T 2>/dev/null)"
    fi

    if [[ -n "$effective" ]]; then
        grep -qi '^usepam yes' <<<"$effective" || needed+=("UsePAM yes")
        grep -qiE '^(kbdinteractiveauthentication|challengeresponseauthentication) yes' <<<"$effective" \
            || needed+=("KbdInteractiveAuthentication yes")
    else
        grep -qiE '^[[:space:]]*UsePAM[[:space:]]+yes' "$cfg" || needed+=("UsePAM yes")
        grep -qiE '^[[:space:]]*(KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]+yes' "$cfg" \
            || needed+=("KbdInteractiveAuthentication yes")
    fi

    if [[ ${#needed[@]} -eq 0 ]]; then
        ok "sshd is already set up to run the PAM conversation"
        return 0
    fi

    warn "sshd needs these before Duo can prompt an SSH client:"
    local line
    for line in "${needed[@]}"; do note "  $line"; done

    local dropin="/etc/ssh/sshd_config.d/99-duo.conf"
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' "$cfg"; then
        note "This sshd_config has no Include for sshd_config.d, so add the lines above to $cfg yourself."
        return 0
    fi
    if ! confirm "Write them to $dropin?" "y"; then
        note "sshd left as it is; Duo will not prompt SSH clients until those are set."
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s write %s\n' "$C_CYAN" "$C_RESET" "$dropin"
        return 0
    fi

    mkdir -p "$(dirname "$dropin")"
    backup_file "$dropin"
    { printf '# Added by %s so pam_duo can run its conversation.\n' "$PROGRAM_NAME"
      for line in "${needed[@]}"; do printf '%s\n' "$line"; done
    } >"$dropin"
    chmod 0644 "$dropin"
    ok "$dropin written"

    if have sshd && ! sshd -t 2>/dev/null; then
        rm -f "$dropin"
        err "sshd rejected the resulting configuration, so $dropin was removed again."
        return 1
    fi
    note "Run 'sudo systemctl reload sshd' when you are ready for it to take effect."
    return 0
}

# duo_wire_pam <module_arg> <targets> <already_requested>
#
# The one step that can lock somebody out, so it states what it is about to do,
# to which files, and how to undo it, before it does anything.
#
# <already_requested> is 1 when the services came from --duo-protect. That is an
# instruction, so it is carried out rather than asked about again - the same way
# --join and --open-firewall skip their prompts. Without it the prompt defaults
# to no, and an unattended run would report success having changed nothing.
duo_wire_pam() {
    local module_arg="$1" targets="$2" already_requested="${3:-0}"
    local -a files=() reordered=()
    local target f rc

    for target in $targets; do
        [[ "$target" == "none" ]] && continue
        while IFS= read -r f; do
            [[ -n "$f" ]] && files+=("$f")
        done < <(duo_target_files "$target")
    done

    if [[ ${#files[@]} -eq 0 ]]; then
        warn "None of the chosen services have a PAM file on this system."
        note "Nothing was wired up; $DUO_CONF is written and ready if you add one."
        return 1
    fi

    local rule="auth       required     $module_arg"

    printf '\n'
    info "About to add this rule to the auth stack of ${#files[@]} service file(s):"
    note "  $rule"
    for f in "${files[@]}"; do note "  -> $f"; done

    printf '\n'
    warn "Read this before answering:"
    note "  - Keep a root shell open on a text console (Ctrl+Alt+F3) while you test."
    note "  - Test in a second session. Do not log out of this one first."
    note "  - Every file is backed up as <file>.$PROGRAM_NAME.<timestamp>.bak."
    note "  - This script can undo it: run the Duo entry again and choose to remove."

    if (( already_requested )); then
        printf '\n'
        note "Proceeding: --duo-protect already named these services."
    elif ! confirm "Add the Duo rule to those files?" "n"; then
        note "PAM left unchanged. $DUO_CONF is still in place for later."
        return 1
    fi

    DUO_PAM_FILES=""
    local wired=0
    for f in "${files[@]}"; do
        rc=0
        pam_add_auth "$f" "$rule" "pam_duo.so" || rc=$?
        case $rc in
            0) wired=$(( wired + 1 )); DUO_PAM_FILES+="${DUO_PAM_FILES:+ }$f" ;;
            3) wired=$(( wired + 1 )); DUO_PAM_FILES+="${DUO_PAM_FILES:+ }$f"
               reordered+=("$f") ;;
            *) warn "Left $f alone." ;;
        esac
    done

    if (( wired == 0 )); then
        err "No PAM file was changed."
        return 1
    fi

    if [[ ${#reordered[@]} -gt 0 ]]; then
        printf '\n'
        warn "In these files the Duo rule had to go before the password check:"
        for f in "${reordered[@]}"; do note "  $f"; done
        note "Their auth stack returns as soon as the password module succeeds, so a"
        note "rule after it would never run - the second factor would look configured"
        note "and do nothing. Duo therefore asks first and the password second."
    fi

    return 0
}

# duo_remove - take Duo back out of every service file that carries it.
duo_remove() {
    local -a files=()
    local f

    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done < <(grep -rl 'pam_duo.so' /etc/pam.d/ 2>/dev/null | sort)

    if [[ ${#files[@]} -eq 0 ]]; then
        note "No file under /etc/pam.d/ references pam_duo.so; nothing to remove."
        return 0
    fi

    printf '\n'
    info "pam_duo.so is referenced by:"
    for f in "${files[@]}"; do note "  $f"; done
    if ! confirm "Remove the Duo rule from all of them?" "y"; then
        note "PAM left unchanged."
        return 0
    fi

    for f in "${files[@]}"; do
        pam_remove_auth "$f" "pam_duo.so"
    done
    printf '\n'
    ok "Duo is no longer in the authentication stack."
    note "$DUO_CONF and the installed packages were left alone, so re-enabling it"
    note "later needs nothing more than this menu entry again."
    return 0
}

duo_explain() {
    note "Duo Unix puts a second factor in front of this machine's logins. It sits"
    note "after the password module, so it protects local accounts and Active"
    note "Directory accounts alike - pam_duo does not care which module checked"
    note "the password, only that one did."
    printf '\n'
    note "It has no graphical interface. Duo talks over the PAM conversation in"
    note "plain text, which a greeter can show only as a line of text, if at all."
    note "The workable desktop configuration is autopush: the greeter accepts the"
    note "password, Duo sends a push to the enrolled phone, and the login finishes"
    note "when it is approved. No typing, no dialog needed."
}

# duo_print_summary - what was changed, and how to reverse it.
duo_print_summary() {
    printf '\n'
    ok "Duo two-factor authentication is configured."
    printf '\n'
    printf '  Enrol every account that logs in here in the Duo Admin Panel, under the\n'
    printf '  username PAM sends -- which is the plain login name, so jdoe rather than\n'
    printf '  jdoe@%s once short names are enabled.\n' "${OPT_DOMAIN:-your.domain}"
    printf '\n'
    printf '  Test it without logging out of this session -- and test what was\n'
    printf '  actually changed, which here is:\n'
    if [[ " $DUO_PAM_FILES " == *" /etc/pam.d/sshd "* ]]; then
        printf '    %sssh %s@localhost%s\n' "$C_CYAN" "${SUDO_USER:-$USER}" "$C_RESET"
    fi
    if [[ "$DUO_PAM_FILES" == *"/etc/pam.d/sudo"* ]]; then
        printf '    %ssudo -k && sudo true%s in another terminal\n' "$C_CYAN" "$C_RESET"
    fi
    if [[ "$DUO_PAM_FILES" == *"/etc/pam.d/login"* || "$DUO_PAM_FILES" == *"pam.d/sddm"* \
       || "$DUO_PAM_FILES" == *"pam.d/kde"* || "$DUO_PAM_FILES" == *"pam.d/gdm-password"* \
       || "$DUO_PAM_FILES" == *"pam.d/lightdm"* ]]; then
        printf '    a login on a text console (%sCtrl+Alt+F3%s)\n' "$C_CYAN" "$C_RESET"
    fi
    printf '\n'
    printf '  To undo it, run this script and pick "Duo two-factor authentication",\n'
    printf '  then choose to remove -- or by hand:\n'
    printf "    %ssudo sed -i '/pam_duo.so/d' %s%s\n" \
        "$C_CYAN" "${DUO_PAM_FILES:-/etc/pam.d/*}" "$C_RESET"
}

# configure_duo - the whole feature, in the order the pieces depend on each
# other: the module, then credentials, then reachability, then PAM last.
#
# Guarded like configure_sddm_greeter, because the guided setup and the menu can
# both arrive here in one run.
DUO_DONE=0
configure_duo() {
    (( DUO_DONE )) && return 0
    DUO_DONE=1

    heading "Duo Security two-factor authentication"
    duo_explain

    local module_arg=""
    if ! module_arg="$(duo_pam_module_arg 2>/dev/null)"; then
        printf '\n'
        duo_install || {
            printf '\n'
            err "pam_duo.so is not on this system, so nothing was wired into PAM."
            note "Duo Unix, with PAM support, is available as:"
            note "  Debian/Ubuntu  the duo-unix package from pkg.duosecurity.com"
            note "  RHEL rebuilds  the duo_unix package from pkg.duosecurity.com"
            note "  everything else  a source build from https://dl.duosecurity.com"
            return 1
        }
        module_arg="$(duo_pam_module_arg 2>/dev/null)" || module_arg=""
    fi

    if [[ -z "$module_arg" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            module_arg="pam_duo.so"
            note "pam_duo.so is not installed here; the preview continues as if it were."
        else
            err "pam_duo.so still cannot be found; PAM was left untouched."
            return 1
        fi
    else
        ok "PAM module: $(duo_pam_module)"
    fi

    # An existing installation gets the chance to be removed rather than
    # reconfigured - which is what somebody who has just been locked out wants.
    if grep -rq 'pam_duo.so' /etc/pam.d/ 2>/dev/null; then
        printf '\n'
        # --duo-protect names services to wire, so with it the sensible default is
        # to go and wire them; pam_add_auth is idempotent, so re-running is safe.
        local what already="keep"
        [[ -n "$OPT_DUO_PROTECT" ]] && already="add"
        menu_single what "Duo is already in the PAM stack on this machine." "$already" \
            "keep|Leave the PAM stack alone|Only revisits $DUO_CONF: the credentials, failmode and autopush. Nothing is added to or removed from any service file." \
            "add|Add it to more services|Keeps what is already wired and offers the service list again, so SSH or sudo can be brought in alongside the login screen." \
            "remove|Remove Duo from every service|Strips the pam_duo rule out of every file under /etc/pam.d/ that carries it, restoring single-factor logins. The package and $DUO_CONF stay, so it can be switched back on later."
        case "$what" in
            remove) duo_remove; return $? ;;
            keep)
                local failmode_keep="${OPT_DUO_FAILMODE:-safe}"
                duo_write_conf "$failmode_keep" "${OPT_DUO_AUTOPUSH:-yes}" "$OPT_DUO_EXEMPT_GROUP" || return 1
                duo_check_api "$(duo_conf_host)"
                DUO_CONFIGURED=1
                return 0
                ;;
        esac
    fi

    # Which services, decided before the config file is written because autopush
    # is only the right default when a graphical greeter is involved.
    local targets="$OPT_DUO_PROTECT" targets_from_flag=0
    if [[ -n "$targets" ]]; then
        targets="${targets//,/ }"
        targets_from_flag=1
    else
        duo_choose_targets targets
    fi
    if [[ -z "${targets// /}" || "${targets// /}" == "none" ]]; then
        note "No services selected, so nothing will be wired into PAM."
        note "Configuring $DUO_CONF anyway, so it is ready when you choose some."
    fi

    local failmode="$OPT_DUO_FAILMODE"
    if [[ -z "$failmode" ]]; then
        menu_single failmode "What should happen if Duo cannot be reached?" "safe" \
            "safe|Allow the login (fail open)|If Duo's service is unreachable - an outage, a DNS problem, a laptop off the network at the wrong moment - the password alone is accepted and the event is logged. The machine stays usable; the second factor is only as available as Duo is." \
            "secure|Deny the login (fail closed)|No Duo, no login, for everybody at once. This is the stronger stance and the one that locks a workstation out of its own front door during an outage. Only pick it with the bypass group below actually populated."
    fi

    local autopush="$OPT_DUO_AUTOPUSH"
    if [[ -z "$autopush" ]]; then
        autopush="no"
        [[ " $targets " == *" login "* ]] && autopush="yes"
    fi
    if [[ "$autopush" == "yes" ]]; then
        note "autopush is on: Duo pushes to the enrolled device instead of asking for"
        note "a passcode, which is the only thing a graphical greeter can carry."
    fi

    local exempt=""
    duo_setup_exempt_group exempt

    duo_write_conf "$failmode" "$autopush" "$exempt" || return 1
    duo_check_api "$(duo_conf_host)"

    if [[ -z "${targets// /}" || "${targets// /}" == "none" ]]; then
        DUO_CONFIGURED=1
        return 0
    fi

    duo_wire_pam "$module_arg" "$targets" "$targets_from_flag" || return 1
    [[ " $targets " == *" sshd "* ]] && duo_check_sshd_config

    DUO_CONFIGURED=1
    duo_print_summary
    return 0
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

# Guarded like configure_sddm_greeter: a join runs this itself, so ticking both
# "Join a domain" and "Post-join login settings" asks the questions once.
POST_JOIN_TUNING_DONE=0
post_join_tuning() {
    (( POST_JOIN_TUNING_DONE )) && return 0
    POST_JOIN_TUNING_DONE=1

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

    configure_sddm_greeter

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
    entries+=("duo|Duo Security two-factor authentication|Adds a second factor in front of this machine's logins, for local and domain accounts alike. Needs an integration key, secret key and API hostname from the Duo Admin Panel, and asks separately which services to protect. Duo Unix is text-only, so a graphical greeter gets a push notification rather than a prompt.")

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

    if (( DUO_CONFIGURED )) || [[ -f "$DUO_CONF" ]]; then
        printf '\n  %sDuo%s - every account that logs in here must be enrolled in the Duo\n' \
            "$C_BOLD" "$C_RESET"
        printf '  Admin Panel under the username PAM sees. Check what is wired up with:\n'
        printf '    %sgrep -rl pam_duo.so /etc/pam.d/%s\n' "$C_CYAN" "$C_RESET"
    fi

    if [[ "$DE_ID" == "kde" ]]; then
        printf '\n  %sKDE Plasma note:%s System Settings has no Active Directory module.\n' \
            "$C_YELLOW$C_BOLD" "$C_RESET"
        printf '  Domain logins still work normally through SDDM once the machine is\n'
        printf '  joined -- pick "Other" and type the domain username. With the login\n'
        printf '  screen tweak applied, that account is shown by name from then on, the\n'
        printf '  way Windows remembers the last user. Use Cockpit or the realm command\n'
        printf '  for join and membership management.\n'
    fi

    printf '\n  Full log: %s\n' "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
# One function per thing the script can do. The menu runs whichever ones were
# ticked and the command line runs the guided one, so each action asks for
# whatever it needs rather than relying on an earlier step having run.

print_system_header() {
    heading "$PROGRAM_NAME $SCRIPT_VERSION"
    printf '  Distribution : %s%s%s\n' "$C_BOLD" "$DISTRO_NAME" "$C_RESET"
    printf '  Family       : %s (%s)\n' "$PKG_FAMILY" "$PKG_MGR"
    printf '  Desktop      : %s%s%s\n' "$C_BOLD" "$DE_NAME" "$C_RESET"
    printf '  Kernel       : %s\n' "$(uname -r)"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '  Mode         : %sDRY RUN - nothing will be changed%s\n' "$C_CYAN$C_BOLD" "$C_RESET"
    fi
    return 0
}

# 'none' is a selection, not a package group: drop it wherever it appears.
gui_drop_none() {
    local -a kept=() item
    for item in ${GUI_CHOICES:-}; do
        [[ "$item" == "none" ]] && continue
        kept+=("$item")
    done
    GUI_CHOICES="${kept[*]-}"
}

# resolve_choices - take BACKEND, GUI_CHOICES and EXTRA_CHOICES from the flags
# where they were given and ask for the rest.
resolve_choices() {
    if [[ -n "$OPT_BACKEND" ]]; then BACKEND="$OPT_BACKEND"; else choose_backend; fi
    if [[ -n "$OPT_GUI" ]]; then GUI_CHOICES="${OPT_GUI//,/ }"; else choose_gui; fi
    if [[ -n "$OPT_EXTRAS" ]]; then EXTRA_CHOICES="${OPT_EXTRAS//,/ }"; else choose_extras; fi
    gui_drop_none
}

# build_package_list - expand the current choices into WANTED_PACKAGES, and
# note the two extras that are configuration rather than packages.
declare -a WANTED_PACKAGES=()
WANT_MKHOMEDIR=0
WANT_TIMESYNC=0
WANT_DUO=0

build_package_list() {
    local -a wanted=() add=()
    local choice group_pkgs

    WANTED_PACKAGES=()
    WANT_MKHOMEDIR=0
    WANT_TIMESYNC=0
    WANT_DUO=0

    case "$BACKEND" in
        sssd)    read -r -a wanted <<<"$(pkgs_for core_sssd)" ;;
        winbind) read -r -a wanted <<<"$(pkgs_for core_winbind)" ;;
        both)    read -r -a wanted <<<"$(pkgs_for core_sssd) $(pkgs_for core_winbind)" ;;
    esac

    for choice in ${GUI_CHOICES:-}; do
        group_pkgs="$(pkgs_for "gui_${choice}")"
        [[ -n "$group_pkgs" ]] && read -r -a add <<<"$group_pkgs" && wanted+=("${add[@]}")
    done

    for choice in ${EXTRA_CHOICES:-}; do
        case "$choice" in
            mkhomedir)   WANT_MKHOMEDIR=1 ;;
            timesync)    WANT_TIMESYNC=1
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
            sudo)         group_pkgs="$(pkgs_for extra_sudo)"
                          [[ -n "$group_pkgs" ]] && { read -r -a add <<<"$group_pkgs"; wanted+=("${add[@]}"); } ;;
            # Duo is left out of the package preview on purpose: which package
            # carries pam_duo.so, and whether a repository has to be added or the
            # module built, is not knowable until configure_duo has looked.
            duo)          WANT_DUO=1 ;;
        esac
    done

    # Deduplicate while preserving order.
    local p u seen
    for p in ${wanted[@]+"${wanted[@]}"}; do
        seen=0
        for u in ${WANTED_PACKAGES[@]+"${WANTED_PACKAGES[@]}"}; do [[ "$u" == "$p" ]] && { seen=1; break; }; done
        (( seen )) || WANTED_PACKAGES+=("$p")
    done
}

# preview_packages - resolve WANTED_PACKAGES against the repositories and show
# what will happen. Non-zero when nothing installable came back.
preview_packages() {
    heading "Packages"
    refresh_repos
    filter_available ${WANTED_PACKAGES[@]+"${WANTED_PACKAGES[@]}"}

    if [[ ${#AVAILABLE_PACKAGES[@]} -eq 0 ]]; then
        err "No installable packages resolved. Are the distribution repositories enabled?"
        return 1
    fi

    local p
    printf '  The following will be installed or confirmed present:\n\n'
    for p in "${AVAILABLE_PACKAGES[@]}"; do
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
}

# Set when the user says no at the install prompt. Declining is not a failure,
# but it does mean the caller has to stop.
INSTALL_DECLINED=0

# install_previewed_packages - confirm and install what preview_packages found.
install_previewed_packages() {
    INSTALL_DECLINED=0
    if ! confirm "Proceed with the installation?" "y"; then
        INSTALL_DECLINED=1
        info "Aborted at the user's request. Nothing was changed."
        return 0
    fi

    heading "Installation"
    if ! install_packages "${AVAILABLE_PACKAGES[@]}"; then
        err "Package installation failed. See the output above and $LOG_FILE."
        return 1
    fi
    ok "Packages installed"
}

# enable_gui_services - start whichever GUI front ends were installed.
enable_gui_services() {
    local choice
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
}

# --- The actions themselves ------------------------------------------------

# Install and configure everything, then optionally join. This is what the
# command line runs when it is not handed a menu.
action_guided_setup() {
    resolve_choices
    build_package_list
    preview_packages || return 1
    (( LIST_ONLY )) && return 0
    install_previewed_packages || return 1
    (( INSTALL_DECLINED )) && return 0

    heading "Configuration"
    (( WANT_TIMESYNC ))  && configure_timesync
    (( WANT_MKHOMEDIR )) && configure_mkhomedir

    case "$BACKEND" in
        sssd|both)
            # sssd has no valid configuration until the join creates one, so it
            # is enabled but deliberately not started here.
            enable_service sssd.service later
            ;;
    esac
    enable_gui_services

    preflight_checks

    local join_now=$DO_JOIN
    if (( join_now == -1 )); then
        printf '\n'
        if confirm "Join an Active Directory domain now?" "n"; then join_now=1; else join_now=0; fi
    fi
    (( join_now == 1 )) && perform_join

    # Duo goes last, deliberately. It is the only step that can leave the machine
    # unable to authenticate, so everything else is already done and verifiable
    # before the authentication stack is touched.
    local duo_now=$WANT_DUO
    (( OPT_DUO == 1 )) && duo_now=1
    (( OPT_DUO == 0 )) && duo_now=0
    (( duo_now == 1 )) && configure_duo

    print_next_steps
    return 0
}

action_install_packages() {
    resolve_choices
    build_package_list
    preview_packages || return 1
    install_previewed_packages || return 1
    (( INSTALL_DECLINED )) && return 0
    printf '\n'
    note "Packages only: no services were enabled and no files were edited."
    note "The configuration items in the menu apply those separately."
    return 0
}

action_gui_tools() {
    # Only the GUI groups are wanted here, so the other two inputs to
    # build_package_list are deliberately cleared.
    BACKEND=""
    EXTRA_CHOICES=""
    if [[ -n "$OPT_GUI" ]]; then GUI_CHOICES="${OPT_GUI//,/ }"; else choose_gui; fi
    gui_drop_none

    if [[ -z "${GUI_CHOICES// /}" ]]; then
        note "No graphical tools selected; nothing to do."
        return 0
    fi

    build_package_list
    preview_packages || return 1
    install_previewed_packages || return 1
    (( INSTALL_DECLINED )) && return 0

    heading "Configuration"
    enable_gui_services
    return 0
}

action_join() {
    perform_join
}

action_post_join() {
    if [[ ! -f /etc/sssd/sssd.conf ]]; then
        warn "/etc/sssd/sssd.conf does not exist, so there is nothing to tune yet."
        note "'realm join' writes that file; join the domain first."
        return 1
    fi
    post_join_tuning
}

action_mkhomedir() {
    configure_mkhomedir
}

action_timesync() {
    configure_timesync
}

action_duo() {
    configure_duo
}

action_sddm_greeter() {
    local dm
    dm="$(active_display_manager)"
    if [[ "$dm" != "sddm" ]]; then
        warn "SDDM is not this machine's display manager${dm:+ (it is $dm)}; nothing to change."
        note "The tweak only applies to the SDDM greeter used by KDE Plasma."
        return 0
    fi
    configure_sddm_greeter
}

# Read-only: what the machine looks like and whether a join would work.
action_status() {
    preflight_checks

    heading "Domain status"
    if have realm; then
        local realms
        realms="$(realm list 2>/dev/null)"
        if [[ -n "$realms" ]]; then
            ok "This machine is joined."
            printf '%s\n' "$realms"
        else
            note "Not joined to any domain."
        fi
    else
        note "'realm' is not installed, so membership cannot be queried."
    fi

    local unit
    for unit in sssd.service winbind.service cockpit.socket adsys.service; do
        unit_exists "$unit" || continue
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            ok "$unit is running"
        else
            note "$unit is installed but not running"
        fi
    done

    heading "Two-factor authentication"
    local module duo_files
    if module="$(duo_pam_module)"; then
        ok "pam_duo.so present at $module"
    else
        note "pam_duo.so is not installed."
    fi
    if duo_conf_is_configured; then
        ok "$DUO_CONF holds a complete set of Duo credentials"
    elif [[ -f "$DUO_CONF" ]]; then
        warn "$DUO_CONF exists but is missing a valid ikey, skey or host."
    else
        note "$DUO_CONF does not exist."
    fi
    duo_files="$(grep -rl 'pam_duo.so' /etc/pam.d/ 2>/dev/null | sort | tr '\n' ' ')"
    if [[ -n "${duo_files// /}" ]]; then
        ok "Duo is in the auth stack of: ${duo_files% }"
    else
        note "No service under /etc/pam.d/ requires Duo."
    fi

    print_next_steps
    return 0
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
# A two-column checkbox menu: the arrow keys move, SPACE ticks an entry, ENTER
# runs everything ticked. The layout is recomputed on every draw, so a narrow
# or short terminal loses detail - hints, then the banner box, then the spacer
# rows - rather than having lines spill off the edge.

M_CSI=$'\x1b['
M_BOLD="${M_CSI}1m"
M_DIM="${M_CSI}2m"
M_RESET="${M_CSI}0m"
M_GREEN="${M_CSI}32m"
M_YELLOW="${M_CSI}33m"
M_BLUE="${M_CSI}34m"
M_CYAN="${M_CSI}36m"

if [[ -n "${NO_COLOR:-}" ]]; then
    M_BOLD=""; M_DIM=""; M_RESET=""; M_GREEN=""; M_YELLOW=""; M_BLUE=""; M_CYAN=""
fi

MENU_TITLE="Active Directory Domain Join - Setup and Configuration"

# Left column is indices 0-3, right column 4-8, and index 9 is a full-width
# row centred underneath both. The columns need not be the same length.
MENU_NAMES=(
    "Guided setup"
    "Install packages only"
    "Graphical management tools"
    "Join an Active Directory domain"
    "Home directories on first login"
    "Network time synchronisation"
    "SDDM login screen"
    "Post-join login settings"
    "Duo two-factor authentication"
    "Preflight checks and domain status"
)
# One line of explanation per entry, shown for whichever entry the cursor is
# on. They are far too long to sit beside the names in two columns, and the
# names alone do not say what a run actually changes.
MENU_HINTS=(
    "Install, configure, then offer to join - the whole setup in one pass"
    "Install the packages only: no files edited, no services enabled"
    "Cockpit, GNOME Enterprise Login, YaST or Ubuntu ADSys, where they apply"
    "Discover the domain, join it, then settle the login settings"
    "Create a home directory the first time a domain user logs in"
    "Keep the clock in step - Kerberos rejects a skew over five minutes"
    "Show the last domain user on the SDDM greeter instead of only 'Other'"
    "Short usernames, who is allowed to log in, sudo for a domain group"
    "Second factor for local and domain logins via Duo Unix, or remove it"
    "Read-only: hostname, clock, DNS, membership and service state"
)

MENU_LEFT_COUNT=4
MENU_RIGHT_COUNT=5
MENU_TOTAL=10
MENU_CURSOR=0
MENU_SELECTED=(0 0 0 0 0 0 0 0 0 0)

# The order selections run in: install first, then configure, then join, then
# the settings that only make sense once the machine is a domain member - and
# Duo last of all, since it is the only entry that can stop a login working.
MENU_RUN_ORDER=(0 1 2 4 5 9 3 7 6 8)

MCOL=0
MROW=0

# Last key read by menu_read_key. A global rather than stdout because the read
# must not happen in a subshell - see menu_read_key.
MENU_KEY=""

# Raised by the SIGWINCH trap and polled by menu_read_key.
MENU_RESIZED=0

# How long menu_read_key waits before letting a pending SIGWINCH trap run, and
# so the worst-case delay between resizing the window and seeing the reflow.
MENU_READ_TIMEOUT=0.2

# Blank columns between the two menu columns.
MENU_COL_GAP=4

# Layout state, recomputed from the terminal size on every draw. None of it is
# a fixed dimension.
ML_TERM_W=80        # terminal width in columns
ML_TERM_H=24        # terminal height in rows
ML_CONTENT_W=76     # width of the drawn block
ML_COL_W=38         # left column width, two-column mode only
ML_TWO_COL=1        # 1 = two columns, 0 = single stacked column
ML_HINTS=1          # 1 = show the hint line for the highlighted entry
ML_BANNER=1         # 1 = boxed banner, 0 = plain one-line title
ML_LEGEND=1         # 1 = show the key legend
ML_BLANKS=2         # 2 = all spacer rows, 1 = inner only, 0 = none
ML_TOO_SMALL=0      # 1 = the terminal cannot fit even the minimal layout
ML_MIN_W=0          # minimum usable width, reported when ML_TOO_SMALL=1
ML_MIN_H=0          # minimum usable height, reported when ML_TOO_SMALL=1
ML_INFO_LABELS=()   # header info labels, rebuilt by menu_build_info
ML_INFO_VALUES=()   # header info values, matching ML_INFO_LABELS
ML_INFO_STYLES=()   # colour for each value, matching ML_INFO_LABELS

# Detected once on entry: querying realm on every draw would be wasteful.
MENU_DOMAIN=""

MTRUNC=""

# Truncate an escape-free string to at most $2 columns, marking the cut with an
# ellipsis. The result goes to $MTRUNC rather than stdout so the draw loop does
# not fork a subshell per item. Bash counts characters, which matches display
# width for every glyph this menu uses.
menu_truncate() {
    local s="$1" max="$2"
    if (( max <= 0 )); then
        MTRUNC=""
    elif (( ${#s} <= max )); then
        MTRUNC="$s"
    elif (( max == 1 )); then
        MTRUNC="…"
    else
        MTRUNC="${s:0:max-1}…"
    fi
}

menu_hide_cursor() { printf '%s?25l' "$M_CSI"; }
menu_show_cursor() { printf '%s?25h' "$M_CSI"; }

# With autowrap off the terminal clips a line that overruns the right edge
# instead of spilling it onto column 0 of the next row, where the in-place
# redraw would never overwrite it.
menu_disable_wrap() { printf '%s?7l' "$M_CSI"; }
menu_enable_wrap()  { printf '%s?7h' "$M_CSI"; }

# Ask the kernel for the window size; stty is available wherever this script
# runs, which tput is not.
menu_term_size() {
    local size
    if size="$(stty size 2>/dev/null)" && [[ "$size" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
        ML_TERM_H="${BASH_REMATCH[1]}"
        ML_TERM_W="${BASH_REMATCH[2]}"
    else
        ML_TERM_H="${LINES:-24}"
        ML_TERM_W="${COLUMNS:-80}"
    fi
    (( ML_TERM_W < 1 )) && ML_TERM_W=80
    (( ML_TERM_H < 1 )) && ML_TERM_H=24
    return 0
}

# One realm query on entry, so the header can say whether this machine is
# already a member without slowing every redraw down.
menu_gather_info() {
    MENU_DOMAIN=""
    have realm || return 0
    MENU_DOMAIN="$(realm list --name-only 2>/dev/null | head -1)"
    return 0
}

# The header block. Rebuilt on each draw because the dry-run line changes
# underneath it while the menu is open.
menu_build_info() {
    ML_INFO_LABELS=(
        "Distribution    :"
        "Package manager :"
        "Desktop         :"
        "Domain          :"
        "Mode            :"
    )
    ML_INFO_VALUES=(
        "$DISTRO_NAME"
        "$PKG_MGR ($PKG_FAMILY family)"
        "$DE_NAME"
        "${MENU_DOMAIN:-not joined}"
        "$( (( DRY_RUN )) && printf 'DRY RUN - nothing will be changed' || printf 'changes will be applied' )"
    )
    ML_INFO_STYLES=(
        "$M_YELLOW"
        "$M_YELLOW"
        "$M_YELLOW"
        "$( [[ -n "$MENU_DOMAIN" ]] && printf '%s' "$M_GREEN" || printf '%s' "$M_YELLOW" )"
        "$( (( DRY_RUN )) && printf '%s' "${M_BOLD}${M_CYAN}" || printf '%s' "$M_GREEN" )"
    )
    return 0
}

menu_compute_layout() {
    menu_term_size
    menu_build_info

    # Natural width of an item: "> " (2) + "[ ]" (3) + " " (1) + name.
    local i w
    local left_w=0 right_w=0 center_w=0
    for ((i=0; i<MENU_TOTAL; i++)); do
        w=$(( 6 + ${#MENU_NAMES[i]} ))
        if (( i < MENU_LEFT_COUNT )); then
            (( w > left_w )) && left_w=$w
        elif (( i < MENU_LEFT_COUNT + MENU_RIGHT_COUNT )); then
            (( w > right_w )) && right_w=$w
        else
            (( w > center_w )) && center_w=$w
        fi
    done
    local single_w=$left_w
    (( right_w > single_w ))  && single_w=$right_w
    (( center_w > single_w )) && single_w=$center_w

    # Keep a column of breathing room on each side where there is room to spare.
    local avail=$(( ML_TERM_W - 2 ))
    (( avail < 20 )) && avail=$ML_TERM_W

    # Width ladder: two columns while they fit, otherwise one stacked column.
    # The stacked form is four rows taller, so it is the second choice - on a
    # default 80x24 terminal height is the scarcer resource.
    local body_w
    if (( left_w + MENU_COL_GAP + right_w <= avail )); then
        ML_TWO_COL=1
        ML_COL_W=$(( left_w + MENU_COL_GAP ))
        body_w=$(( left_w + MENU_COL_GAP + right_w ))
        (( center_w > body_w )) && body_w=$center_w
    else
        ML_TWO_COL=0
        ML_COL_W=$single_w
        body_w=$single_w
    fi

    local info_w=0
    for ((i=0; i<${#ML_INFO_LABELS[@]}; i++)); do
        w=$(( ${#ML_INFO_LABELS[i]} + 1 + ${#ML_INFO_VALUES[i]} ))
        (( w > info_w )) && info_w=$w
    done

    ML_CONTENT_W=$body_w
    (( info_w > ML_CONTENT_W )) && ML_CONTENT_W=$info_w
    (( ML_CONTENT_W > avail )) && ML_CONTENT_W=$avail
    # Widen to fit the title box where there is spare room, so the title is not
    # clipped merely because the item rows happen to be narrow.
    local title_w=$(( ${#MENU_TITLE} + 2 ))
    (( title_w > ML_CONTENT_W && title_w <= avail )) && ML_CONTENT_W=$title_w
    (( ML_CONTENT_W < 1 )) && ML_CONTENT_W=1

    # Height ladder: shed decoration in the order of how little it costs to
    # lose. Row budget = top blank + banner(3) + blank + info + blank + rule +
    # blank + items + hint + rule + blank + selected + blank + legend(2).
    local center_count=$(( MENU_TOTAL - MENU_LEFT_COUNT - MENU_RIGHT_COUNT ))
    local col_rows=$MENU_LEFT_COUNT
    (( MENU_RIGHT_COUNT > col_rows )) && col_rows=$MENU_RIGHT_COUNT
    local item_rows=$(( col_rows + center_count ))
    (( ML_TWO_COL == 0 )) && item_rows=$MENU_TOTAL

    local info_rows=${#ML_INFO_LABELS[@]}
    local fixed=$(( info_rows + 2 + item_rows + 1 + 1 ))  # info, 2 rules, items, count, cursor row
    local base=$(( fixed + 3 + 2 + 1 ))                   # + banner box + legend + hint, no blanks
    ML_BLANKS=2; ML_BANNER=1; ML_LEGEND=1; ML_HINTS=1
    local needed=$(( base + 7 ))                          # all seven spacer rows
    if (( needed > ML_TERM_H )); then
        # Give up the outermost spacers first - the ones between sections do
        # more for legibility than the ones at the very top and bottom.
        ML_BLANKS=1
        needed=$(( base + 5 ))
    fi
    if (( needed > ML_TERM_H )); then
        ML_BLANKS=0
        needed=$base
    fi
    if (( needed > ML_TERM_H )); then
        ML_BANNER=0
        needed=$(( needed - 2 ))                          # the box becomes one plain line
    fi
    if (( needed > ML_TERM_H )); then
        ML_HINTS=0
        needed=$(( needed - 1 ))
    fi
    if (( needed > ML_TERM_H )); then
        ML_LEGEND=0
        needed=$(( needed - 2 ))
    fi

    # Nothing left to shed. Report the floor instead of drawing a broken screen.
    ML_MIN_W=$(( single_w + 2 ))
    ML_MIN_H=$(( fixed + 1 ))
    ML_TOO_SMALL=0
    if (( needed > ML_TERM_H || ML_TERM_W < single_w )); then
        ML_TOO_SMALL=1
    fi
    return 0
}

# Render one item into $MITEM, with its visible width in $MITEM_W so the caller
# can pad the column.
MITEM=""
MITEM_W=0
menu_render_item() {
    local idx="$1" max_w="$2"
    local name="${MENU_NAMES[$idx]}"

    # "> " (2) + "[ ]" (3) + " " (1) leaves max_w - 6 for the name.
    local avail=$(( max_w - 6 ))
    if (( ${#name} > avail )); then
        menu_truncate "$name" "$avail"
        name="$MTRUNC"
    fi

    local prefix="  "
    (( idx == MENU_CURSOR )) && prefix="${M_BOLD}${M_BLUE}▸ ${M_RESET}"

    local checkbox="[ ]"
    (( MENU_SELECTED[idx] == 1 )) && checkbox="${M_GREEN}[✓]${M_RESET}"

    if (( idx == MENU_CURSOR )); then
        MITEM="${prefix}${checkbox} ${M_BOLD}${name}${M_RESET}"
    else
        MITEM="${prefix}${checkbox} ${name}"
    fi

    MITEM_W=$(( 6 + ${#name} ))
    return 0
}

draw_menu() {
    menu_compute_layout

    local eol=$'\033[K'
    local _buf=$'\033[H'    # home the cursor and overwrite in place, no flicker

    if (( ML_TOO_SMALL )); then
        # Kept short and clipped: a wrapped "too small" notice would be its own
        # instance of the problem it is reporting.
        menu_truncate "Terminal too small" "$ML_TERM_W"
        _buf+="${M_BOLD}${M_YELLOW}${MTRUNC}${M_RESET}${eol}"$'\n'
        menu_truncate "Need ${ML_MIN_W}x${ML_MIN_H}, have ${ML_TERM_W}x${ML_TERM_H}" "$ML_TERM_W"
        _buf+="${MTRUNC}${eol}"$'\n'
        _buf+=$'\033[J'
        printf '%s' "$_buf"
        return 0
    fi

    local content_width=$ML_CONTENT_W
    local margin=0
    (( ML_TERM_W > content_width )) && margin=$(( (ML_TERM_W - content_width) / 2 ))
    local pad=""
    (( margin > 0 )) && printf -v pad '%*s' "$margin" ''

    # blank_hi are the outermost spacers, dropped one tier before the rest.
    local blank="" blank_hi=""
    (( ML_BLANKS >= 1 )) && blank="${pad}${eol}"$'\n'
    (( ML_BLANKS >= 2 )) && blank_hi="$blank"

    # --- Banner -----------------------------------------------------------
    if (( ML_BANNER )); then
        local inner_width=$(( content_width - 2 ))
        local border_fill
        printf -v border_fill '%*s' "$inner_width" ''
        border_fill="${border_fill// /═}"

        menu_truncate "$MENU_TITLE" "$inner_width"
        local btext="$MTRUNC"
        local blpad=$(( (inner_width - ${#btext}) / 2 ))
        local brpad=$(( inner_width - ${#btext} - blpad ))
        local blspaces="" brspaces=""
        (( blpad > 0 )) && printf -v blspaces '%*s' "$blpad" ''
        (( brpad > 0 )) && printf -v brspaces '%*s' "$brpad" ''

        _buf+="$blank_hi"
        _buf+="${pad}${M_BOLD}${M_CYAN}╔${border_fill}╗${M_RESET}${eol}"$'\n'
        _buf+="${pad}${M_BOLD}${M_CYAN}║${blspaces}${btext}${brspaces}║${M_RESET}${eol}"$'\n'
        _buf+="${pad}${M_BOLD}${M_CYAN}╚${border_fill}╝${M_RESET}${eol}"$'\n'
    else
        menu_truncate "$MENU_TITLE" "$content_width"
        local btext="$MTRUNC"
        local blpad=$(( (content_width - ${#btext}) / 2 ))
        local blspaces=""
        (( blpad > 0 )) && printf -v blspaces '%*s' "$blpad" ''
        _buf+="${pad}${blspaces}${M_BOLD}${M_CYAN}${btext}${M_RESET}${eol}"$'\n'
    fi
    _buf+="$blank"

    # --- Detected system (centred as a block) ------------------------------
    local il info_max_len=0 full_len
    for ((il=0; il<${#ML_INFO_LABELS[@]}; il++)); do
        full_len=$(( ${#ML_INFO_LABELS[il]} + 1 + ${#ML_INFO_VALUES[il]} ))
        (( full_len > info_max_len )) && info_max_len=$full_len
    done
    local info_lpad=$(( (content_width - info_max_len) / 2 ))
    # The block is wider than the panel on a narrow terminal; centring it then
    # would push the values off the right edge instead of clipping them.
    (( info_lpad < 0 )) && info_lpad=0
    local info_pad=""
    (( info_lpad > 0 )) && printf -v info_pad '%*s' "$info_lpad" ''

    for ((il=0; il<${#ML_INFO_LABELS[@]}; il++)); do
        local label="${ML_INFO_LABELS[il]}"
        # Clip the value to whatever is left of the terminal on this line.
        local value_room=$(( ML_TERM_W - margin - info_lpad - ${#label} - 1 ))
        menu_truncate "${ML_INFO_VALUES[il]}" "$value_room"
        _buf+="${pad}${info_pad}${M_BOLD}${label}${M_RESET} ${ML_INFO_STYLES[il]}${MTRUNC}${M_RESET}${eol}"$'\n'
    done
    _buf+="$blank"

    # --- Items -------------------------------------------------------------
    local sep_fill
    printf -v sep_fill '%*s' "$content_width" ''
    sep_fill="${sep_fill// /─}"
    _buf+="${pad}${M_DIM}${sep_fill}${M_RESET}${eol}"$'\n'
    _buf+="$blank"

    local idx
    if (( ML_TWO_COL )); then
        # The two columns are independent lengths, so the grid is as deep as the
        # longer of them and a row may hold only one entry.
        local row right_w=$(( content_width - ML_COL_W ))
        local grid_rows=$MENU_LEFT_COUNT
        (( MENU_RIGHT_COUNT > grid_rows )) && grid_rows=$MENU_RIGHT_COUNT

        for ((row=0; row<grid_rows; row++)); do
            local line=""
            if (( row < MENU_LEFT_COUNT )); then
                menu_render_item "$row" "$ML_COL_W"
                local padding=$(( ML_COL_W - MITEM_W ))
                (( padding < 1 )) && padding=1
                local gap_str
                printf -v gap_str '%*s' "$padding" ''
                line="${MITEM}${gap_str}"
            else
                # No left entry on this row; hold the right column in place.
                printf -v line '%*s' "$ML_COL_W" ''
            fi
            if (( row < MENU_RIGHT_COUNT )); then
                idx=$(( MENU_LEFT_COUNT + row ))
                menu_render_item "$idx" "$right_w"
                line="${line}${MITEM}"
            fi
            _buf+="${pad}${line}${eol}"$'\n'
        done

        local center_start=$(( MENU_LEFT_COUNT + MENU_RIGHT_COUNT ))
        for ((idx=center_start; idx<MENU_TOTAL; idx++)); do
            menu_render_item "$idx" "$content_width"
            local clpad=$(( (content_width - MITEM_W) / 2 ))
            local cpad=""
            (( clpad > 0 )) && printf -v cpad '%*s' "$clpad" ''
            _buf+="${pad}${cpad}${MITEM}${eol}"$'\n'
        done
    else
        # Single stacked column, left aligned: centring each row on its own
        # width reads as ragged once the rows differ in length.
        for ((idx=0; idx<MENU_TOTAL; idx++)); do
            menu_render_item "$idx" "$content_width"
            _buf+="${pad}${MITEM}${eol}"$'\n'
        done
    fi

    _buf+="$blank"

    # What the highlighted entry does. Centred on the block, and always the
    # same single row, so moving the cursor does not reflow the screen.
    if (( ML_HINTS )); then
        menu_truncate "${MENU_HINTS[$MENU_CURSOR]}" "$content_width"
        local hlpad=$(( (content_width - ${#MTRUNC}) / 2 ))
        local hpad=""
        (( hlpad > 0 )) && printf -v hpad '%*s' "$hlpad" ''
        _buf+="${pad}${hpad}${M_DIM}${MTRUNC}${M_RESET}${eol}"$'\n'
    fi

    _buf+="${pad}${M_DIM}${sep_fill}${M_RESET}${eol}"$'\n'
    _buf+="$blank"

    # --- Footer -------------------------------------------------------------
    local sel_count=0 i
    for ((i=0; i<MENU_TOTAL; i++)); do
        (( MENU_SELECTED[i] == 1 )) && sel_count=$(( sel_count + 1 ))
    done
    _buf+="${pad}${M_CYAN}Selected: ${M_GREEN}${sel_count}${M_RESET}${eol}"$'\n'

    if (( ML_LEGEND )); then
        _buf+="$blank_hi"
        local keys="↑↓←→ Navigate   SPACE Select/Deselect   ENTER Confirm   D Dry-run   Q Quit"
        (( ML_TWO_COL == 0 )) && keys="↑↓ Move  SPACE Select  ENTER Go  D Dry-run  Q Quit"
        menu_truncate "$keys" "$content_width"
        _buf+="${pad}${M_YELLOW}${MTRUNC}${M_RESET}${eol}"$'\n'
        if (( content_width >= 38 )); then
            _buf+="${pad}${M_DIM}Legend: ${M_GREEN}[✓]${M_RESET}${M_DIM} selected  [ ] not selected${M_RESET}${eol}"$'\n'
        else
            _buf+="${pad}${eol}"$'\n'
        fi
    fi

    # Drop the final newline: emitting one on the bottom row scrolls the
    # screen, which would push the top of the menu out of view whenever the
    # layout happens to fill the terminal exactly. \033[J still clears below.
    _buf="${_buf%$'\n'}"
    _buf+=$'\033[J'
    printf '%s' "$_buf"
    return 0
}

# Read one keypress into MENU_KEY.
#
# This sets a global instead of echoing, because the caller must not run it in
# a command substitution: bash resets caught traps in a subshell and SIGWINCH
# defaults to "ignore", so a resize would be swallowed entirely. Even called
# directly, bash restarts the read across a trapped signal and defers the
# handler until the read returns, so a blocking read would sit on a stale
# screen until the next keypress. The short timeout bounds that - the read
# gives up, the pending WINCH trap runs, and the loop sees MENU_RESIZED.
menu_read_key() {
    local key rc
    MENU_KEY=""

    while true; do
        rc=0
        IFS= read -rsn1 -t "$MENU_READ_TIMEOUT" key 2>/dev/null || rc=$?
        (( rc == 0 )) && break

        if (( MENU_RESIZED )); then
            MENU_RESIZED=0
            MENU_KEY="REDRAW"
            return 0
        fi

        # rc > 128 is the timeout; anything else is EOF, which ends the menu
        # the same way Enter does.
        if (( rc <= 128 )); then
            MENU_KEY="ENTER"
            return 0
        fi
    done

    if [[ "$key" == $'\x1b' ]]; then
        local seq code
        IFS= read -rsn1 -t 0.5 seq 2>/dev/null || true
        if [[ "$seq" == "[" || "$seq" == "O" ]]; then
            IFS= read -rsn1 -t 0.5 code 2>/dev/null || true
            case "$code" in
                A) MENU_KEY="UP";    return 0 ;;
                B) MENU_KEY="DOWN";  return 0 ;;
                C) MENU_KEY="RIGHT"; return 0 ;;
                D) MENU_KEY="LEFT";  return 0 ;;
            esac
            # Some other control sequence - Home, Page Up, a mouse report.
            # Ignore it rather than read it as the bare Escape that quits.
            MENU_KEY="OTHER"
            return 0
        fi
        [[ -z "$seq" ]] && { MENU_KEY="ESCAPE"; return 0; }
        MENU_KEY="OTHER"
        return 0
    fi

    case "$key" in
        ' ')  MENU_KEY="SPACE" ;;
        '')   MENU_KEY="ENTER" ;;
        q|Q)  MENU_KEY="QUIT" ;;
        d|D)  MENU_KEY="DRYRUN" ;;
        *)    MENU_KEY="OTHER" ;;
    esac
    return 0
}

# Column (0 = left, 1 = right, 2 = centred) and row for a cursor index.
menu_get_pos() {
    local idx="$1"
    if (( idx < MENU_LEFT_COUNT )); then
        MCOL=0; MROW=$idx
    elif (( idx < MENU_LEFT_COUNT + MENU_RIGHT_COUNT )); then
        MCOL=1; MROW=$(( idx - MENU_LEFT_COUNT ))
    else
        MCOL=2; MROW=$(( idx - MENU_LEFT_COUNT - MENU_RIGHT_COUNT ))
    fi
    return 0
}

# The inverse: place the cursor from a column and row.
menu_set_cursor() {
    local col="$1" row="$2" target
    if (( col == 0 )); then
        target=$row
    elif (( col == 1 )); then
        target=$(( MENU_LEFT_COUNT + row ))
    else
        target=$(( MENU_LEFT_COUNT + MENU_RIGHT_COUNT + row ))
    fi
    (( target < MENU_TOTAL )) && MENU_CURSOR=$target
    return 0
}

menu_cleanup() {
    menu_show_cursor
    menu_enable_wrap
    if [[ -n "${MENU_SAVED_STTY:-}" ]]; then
        stty "$MENU_SAVED_STTY" 2>/dev/null
    else
        stty echo 2>/dev/null
    fi
    return 0
}

# Draw the menu and collect the selections. Returns 1 when the user quit.
run_menu() {
    MENU_CURSOR=0
    MENU_SELECTED=(0 0 0 0 0 0 0 0 0 0)
    menu_gather_info

    MENU_SAVED_STTY="$(stty -g 2>/dev/null)" || MENU_SAVED_STTY=""
    menu_hide_cursor
    menu_disable_wrap
    stty -echo 2>/dev/null

    trap menu_cleanup EXIT
    # Only raise a flag here: drawing from inside the handler could interleave
    # with a draw already in progress. menu_read_key turns this into a REDRAW.
    trap 'MENU_RESIZED=1' WINCH

    printf '\033[2J\033[H'
    draw_menu

    local quit=0 col_size target_row
    while true; do
        # A direct call, not $(...) - see menu_read_key for why the subshell
        # would break live resize handling.
        menu_read_key

        case "$MENU_KEY" in
            UP)
                # The stacked layout has no grid to navigate: walk the list.
                if (( ML_TWO_COL == 0 )); then
                    if (( MENU_CURSOR == 0 )); then
                        MENU_CURSOR=$(( MENU_TOTAL - 1 ))
                    else
                        MENU_CURSOR=$(( MENU_CURSOR - 1 ))
                    fi
                    draw_menu
                    continue
                fi
                menu_get_pos "$MENU_CURSOR"
                if (( MCOL == 2 )); then
                    # From the centred row, up into the foot of the left column.
                    menu_set_cursor 0 $(( MENU_LEFT_COUNT - 1 ))
                elif (( MROW == 0 )); then
                    # From the top of a column, wrap round to the centred row.
                    menu_set_cursor 2 0
                else
                    menu_set_cursor "$MCOL" $(( MROW - 1 ))
                fi
                ;;
            DOWN)
                if (( ML_TWO_COL == 0 )); then
                    MENU_CURSOR=$(( (MENU_CURSOR + 1) % MENU_TOTAL ))
                    draw_menu
                    continue
                fi
                menu_get_pos "$MENU_CURSOR"
                if (( MCOL == 2 )); then
                    menu_set_cursor 0 0
                else
                    col_size=$MENU_LEFT_COUNT
                    (( MCOL == 1 )) && col_size=$MENU_RIGHT_COUNT
                    if (( MROW >= col_size - 1 )); then
                        menu_set_cursor 2 0
                    else
                        menu_set_cursor "$MCOL" $(( MROW + 1 ))
                    fi
                fi
                ;;
            LEFT)
                (( ML_TWO_COL == 0 )) && continue
                menu_get_pos "$MENU_CURSOR"
                if (( MCOL == 1 )); then
                    target_row=$MROW
                    (( target_row >= MENU_LEFT_COUNT )) && target_row=$(( MENU_LEFT_COUNT - 1 ))
                    menu_set_cursor 0 "$target_row"
                fi
                ;;
            RIGHT)
                (( ML_TWO_COL == 0 )) && continue
                menu_get_pos "$MENU_CURSOR"
                if (( MCOL == 0 )); then
                    target_row=$MROW
                    (( target_row >= MENU_RIGHT_COUNT )) && target_row=$(( MENU_RIGHT_COUNT - 1 ))
                    menu_set_cursor 1 "$target_row"
                fi
                ;;
            SPACE)
                if (( MENU_SELECTED[MENU_CURSOR] == 1 )); then
                    MENU_SELECTED[MENU_CURSOR]=0
                else
                    MENU_SELECTED[MENU_CURSOR]=1
                fi
                ;;
            DRYRUN)
                if (( DRY_RUN )); then DRY_RUN=0; else DRY_RUN=1; fi
                ;;
            ENTER)
                break
                ;;
            QUIT|ESCAPE)
                quit=1
                break
                ;;
            REDRAW|OTHER)
                # The draw at the foot of the loop recomputes the layout, so a
                # resize needs nothing else done here.
                ;;
        esac

        draw_menu
    done

    menu_cleanup
    trap - EXIT
    trap - WINCH
    printf '\033[2J\033[H'

    (( quit )) && return 1
    return 0
}

menu_run_action() {
    case "$1" in
        0) action_guided_setup ;;
        1) action_install_packages ;;
        2) action_gui_tools ;;
        3) action_join ;;
        4) action_mkhomedir ;;
        5) action_timesync ;;
        6) action_sddm_greeter ;;
        7) action_post_join ;;
        8) action_duo ;;
        9) action_status ;;
        *) return 1 ;;
    esac
}

# Run everything that was ticked, in MENU_RUN_ORDER.
process_menu_selections() {
    local -a queue=()
    local idx

    for idx in "${MENU_RUN_ORDER[@]}"; do
        (( MENU_SELECTED[idx] == 1 )) && queue+=("$idx")
    done

    if [[ ${#queue[@]} -eq 0 ]]; then
        info "Nothing was selected."
        return 0
    fi

    print_system_header

    local pos=0 rc failed=0
    for idx in "${queue[@]}"; do
        pos=$(( pos + 1 ))
        heading "[$pos/${#queue[@]}] ${MENU_NAMES[$idx]}"
        rc=0
        menu_run_action "$idx" || rc=$?
        if (( rc != 0 )); then
            failed=$(( failed + 1 ))
            err "${MENU_NAMES[$idx]} did not complete."
            if (( pos < ${#queue[@]} )); then
                if ! confirm "Carry on with the remaining selections?" "n"; then
                    warn "Stopped with $(( ${#queue[@]} - pos )) selection(s) not run."
                    return 1
                fi
            fi
        fi
    done

    printf '\n'
    if (( failed )); then
        warn "Finished with $failed of ${#queue[@]} selection(s) incomplete."
        return 1
    fi
    ok "Done."
    return 0
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

Run with no options to get the interactive menu: arrow keys move, SPACE ticks
an entry, ENTER runs everything ticked. Any option that says what to do skips
the menu and runs the guided setup directly.

${C_BOLD}OPTIONS${C_RESET}
      --menu              Force the interactive menu.
      --no-menu           Skip the menu and run the guided setup.
  -d, --domain DOMAIN     Active Directory domain (e.g. corp.example.com).
  -u, --user USER         Domain account used to perform the join.
  -b, --backend NAME      sssd | winbind | both
  -g, --gui LIST          Comma separated: cockpit,gnome,yast,adsys,none
  -e, --extras LIST       Comma separated: mkhomedir,timesync,troubleshoot,shares,sudo,duo
      --join              Join the domain after installing.
      --no-join           Install only; never attempt a join.
      --open-firewall     Allow Cockpit (9090/tcp) through the firewall.
      --no-open-firewall  Leave the firewall alone.
  -y, --yes               Non-interactive; accept every recommended default.
  -n, --dry-run           Print what would happen without changing anything.
  -l, --list              Show the packages for this system and exit.
  -h, --help              This help.
      --version           Print the version.

${C_BOLD}DUO TWO-FACTOR AUTHENTICATION${C_RESET}
      --duo               Set up Duo Security 2FA (same as -e duo).
      --no-duo            Never set up Duo, whatever the extras say.
      --duo-ikey KEY      Duo integration key.
      --duo-skey KEY      Duo secret key. Visible in 'ps'; prefer the two below.
      --duo-skey-file F   Read the secret key from the first line of F.
      --duo-host HOST     Duo API hostname, e.g. api-1234abcd.duosecurity.com.
      --duo-protect LIST  Comma separated: login,sshd,sudo,none
      --duo-failmode MODE safe (allow logins if Duo is unreachable) or secure.
      --duo-autopush Y/N  yes = push to the enrolled device instead of prompting.
      --duo-exempt GROUP  Break-glass group whose members skip Duo.
      --duo-repo          Allow adding Duo's own package repository.
      --duo-build         Allow building Duo Unix from source where unpackaged.

The secret key is also read from the DUO_SKEY environment variable, which keeps
it out of the process list and the shell history.

${C_BOLD}EXAMPLES${C_RESET}
  # Interactive menu of everything the script can do
  sudo ./domain-join-setup.sh

  # Preview the actions for a KDE workstation without touching anything
  sudo ./domain-join-setup.sh --dry-run

  # Unattended install plus join
  sudo ./domain-join-setup.sh -y -b sssd -g cockpit \\
       -e mkhomedir,timesync,shares -d corp.example.com -u svc-join --join

  # The same, with Duo protecting the login screen
  DUO_SKEY=... sudo -E ./domain-join-setup.sh -y -b sssd -g cockpit \\
       -d corp.example.com -u svc-join --join \\
       --duo --duo-repo --duo-ikey DIXXXXXXXXXXXXXXXXXX \\
       --duo-host api-1234abcd.duosecurity.com \\
       --duo-protect login --duo-exempt duo-exempt
EOF
}

# Options that say what to do set CLI_DIRECTED, which suppresses the menu.
# --dry-run and --detected-de only modify how it is done, so they leave the
# menu in place.
parse_args() {
    local skey_on_cmdline=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain)   OPT_DOMAIN="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
            -u|--user)     OPT_JOIN_USER="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
            -b|--backend)  OPT_BACKEND="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
            -g|--gui)      OPT_GUI="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
            -e|--extras)   OPT_EXTRAS="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
            --join)        DO_JOIN=1; CLI_DIRECTED=1; shift ;;
            --no-join)     DO_JOIN=0; CLI_DIRECTED=1; shift ;;
            --open-firewall)    OPEN_FIREWALL=1; CLI_DIRECTED=1; shift ;;
            --no-open-firewall) OPEN_FIREWALL=0; CLI_DIRECTED=1; shift ;;
            --duo)           OPT_DUO=1; CLI_DIRECTED=1; shift ;;
            --no-duo)        OPT_DUO=0; CLI_DIRECTED=1; shift ;;
            --duo-ikey)      OPT_DUO_IKEY="${2:-}"; OPT_DUO=1; CLI_DIRECTED=1; shift 2 ;;
            --duo-skey)      OPT_DUO_SKEY="${2:-}"; OPT_DUO=1; CLI_DIRECTED=1; skey_on_cmdline=1; shift 2 ;;
            --duo-skey-file) OPT_DUO_SKEY_FILE="${2:-}"; OPT_DUO=1; CLI_DIRECTED=1; shift 2 ;;
            --duo-host)      OPT_DUO_HOST="${2:-}"; OPT_DUO=1; CLI_DIRECTED=1; shift 2 ;;
            --duo-protect)   OPT_DUO_PROTECT="${2:-}"; OPT_DUO=1; CLI_DIRECTED=1; shift 2 ;;
            --duo-failmode)  OPT_DUO_FAILMODE="${2:-}"; OPT_DUO=1; CLI_DIRECTED=1; shift 2 ;;
            --duo-autopush)  OPT_DUO_AUTOPUSH="${2:-}"; OPT_DUO=1; CLI_DIRECTED=1; shift 2 ;;
            --duo-exempt)    OPT_DUO_EXEMPT_GROUP="${2:-}"; OPT_DUO=1; CLI_DIRECTED=1; shift 2 ;;
            --duo-repo)      DUO_ADD_REPO=1; shift ;;
            --no-duo-repo)   DUO_ADD_REPO=0; shift ;;
            --duo-build)     DUO_BUILD_SOURCE=1; shift ;;
            --no-duo-build)  DUO_BUILD_SOURCE=0; shift ;;
            --detected-de) DJ_DE="${2:-}"; shift 2 ;;   # internal: set by the sudo re-exec
            --menu)        MENU_FORCED=1; shift ;;
            --no-menu)     MENU_FORCED=0; shift ;;
            -y|--yes)      ASSUME_YES=1; CLI_DIRECTED=1; shift ;;
            -n|--dry-run)  DRY_RUN=1; shift ;;
            -l|--list)     LIST_ONLY=1; CLI_DIRECTED=1; shift ;;
            -h|--help)     usage; exit 0 ;;
            --version)     printf '%s %s\n' "$PROGRAM_NAME" "$SCRIPT_VERSION"; exit 0 ;;
            *)             err "Unknown option: $1"; printf '\n'; usage; exit 2 ;;
        esac
    done

    if [[ -n "$OPT_BACKEND" && ! "$OPT_BACKEND" =~ ^(sssd|winbind|both)$ ]]; then
        die "Invalid --backend '$OPT_BACKEND' (expected sssd, winbind or both)."
    fi

    if [[ -n "$OPT_DUO_FAILMODE" && ! "$OPT_DUO_FAILMODE" =~ ^(safe|secure)$ ]]; then
        die "Invalid --duo-failmode '$OPT_DUO_FAILMODE' (expected safe or secure)."
    fi

    if [[ -n "$OPT_DUO_AUTOPUSH" ]]; then
        OPT_DUO_AUTOPUSH="${OPT_DUO_AUTOPUSH,,}"
        case "$OPT_DUO_AUTOPUSH" in
            y|yes|true|1)  OPT_DUO_AUTOPUSH="yes" ;;
            n|no|false|0)  OPT_DUO_AUTOPUSH="no" ;;
            *) die "Invalid --duo-autopush '$OPT_DUO_AUTOPUSH' (expected yes or no)." ;;
        esac
    fi

    if [[ -n "$OPT_DUO_PROTECT" ]]; then
        local target
        for target in ${OPT_DUO_PROTECT//,/ }; do
            [[ "$target" =~ ^(login|sshd|sudo|none)$ ]] \
                || die "Invalid --duo-protect target '$target' (expected login, sshd, sudo or none)."
        done
    fi

    # A secret key on the command line is readable by every user on the machine
    # for as long as the script runs. Say so rather than let it pass unremarked.
    if (( skey_on_cmdline )) && [[ -n "$OPT_DUO_SKEY" ]]; then
        warn "A --duo-skey on the command line is visible in 'ps' to every local user."
        note "--duo-skey-file, or the DUO_SKEY environment variable, avoids that."
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
# menu_wanted - the menu is the default, but only when nothing on the command
# line has already said what to do and there is a terminal to draw on.
menu_wanted() {
    (( MENU_FORCED == 0 )) && return 1

    if [[ ! -t 0 || ! -t 1 ]]; then
        (( MENU_FORCED == 1 )) && die "The interactive menu needs a terminal."
        return 1
    fi

    (( MENU_FORCED == 1 )) && return 0
    (( CLI_DIRECTED )) && return 1
    return 0
}

main() {
    parse_args "$@"

    detect_distro
    detect_de          # before the sudo re-exec, while the session vars exist
    require_root "$@"

    if menu_wanted; then
        while true; do
            if ! run_menu; then
                info "Cancelled. Nothing was changed."
                break
            fi
            process_menu_selections
            printf '\n'
            confirm "Return to the menu?" "n" || break
        done
        return 0
    fi

    print_system_header
    action_guided_setup || exit 1
    (( LIST_ONLY )) && exit 0
    (( INSTALL_DECLINED )) && exit 0
    printf '\n'
    ok "Done."
}

# Executing the file runs the installer; sourcing it exposes the functions
# without side effects, which is how tests/run-tests.sh drives the per-distro
# logic on a machine that only runs one distro.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
