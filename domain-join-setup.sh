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
readonly SCRIPT_VERSION="1.4.0"

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
OPT_SUDO_USER=""  # comma separated accounts to grant sudo (empty = ask)
OPT_SUDO_GROUP="" # comma separated groups to grant sudo (empty = ask)
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

# WinApps - Windows applications launched from the Linux desktop over RDP.
#
# The multi-user problem this solves: 'winapps' hard-codes its configuration
# path to ${HOME}/.config/winapps/winapps.conf and has no system-wide fallback,
# so a --system install puts the launchers in /usr/share/applications for
# everyone while every one of those launchers still dies on a missing per-user
# config. On a domain-joined machine the set of users is not known in advance,
# so the config cannot be written per user ahead of time. It is generated at
# login instead, from one root-owned template, with the account's own name
# substituted in - which is also what makes the RDP session land in the right
# Windows profile.
OPT_WINAPPS=-1           # -1 = ask, 0 = no, 1 = yes
OPT_WINAPPS_BACKEND=""   # libvirt | docker | podman | manual (empty = ask)
OPT_WINAPPS_HOST=""      # RDP_IP: the Windows host, for the 'manual' backend
OPT_WINAPPS_PORT=""      # RDP_PORT (empty = 3389)
OPT_WINAPPS_VM=""        # VM_NAME, libvirt only (empty = RDPWindows)
OPT_WINAPPS_DOMAIN=""    # RDP_DOMAIN (empty = derive from the joined realm)
OPT_WINAPPS_CREDS=""     # askpass | kerberos | shared (empty = ask)
OPT_WINAPPS_RDP_USER=""  # shared-credential mode only: the service account
OPT_WINAPPS_RDP_PASS="${WINAPPS_RDP_PASS:-}"  # shared-credential mode only
WINAPPS_REMOVE=0         # --winapps-remove: take the multi-user wiring back out

# Building the Windows guest. libvirt backend only: the script can stand up a
# WinApps-ready Windows 11 Pro VM (unattended install, virtio drivers, RDP and
# RemoteApp enabled). It does nothing domain-related - joining the guest to AD,
# and anything else inside Windows, is left to the operator.
OPT_WINAPPS_DEPLOY=-1    # -1 = ask, 0 = no, 1 = yes  (libvirt backend only)
OPT_WINAPPS_ISO=""       # path to a Windows 10/11 ISO; empty = fetch with Mido
OPT_WINAPPS_VM_RAM=""    # guest RAM in MiB   (empty = 4096)
OPT_WINAPPS_VM_CPUS=""   # guest vCPUs        (empty = 4)
OPT_WINAPPS_VM_DISK=""   # guest disk in GiB  (empty = 64)
OPT_WINAPPS_VM_PASS="${WINAPPS_VM_PASS:-}"  # local admin password for the built VM
WINAPPS_VM_REMOVE=0      # --winapps-vm-remove: also undefine the libvirt guest

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

        # --- WinApps ----------------------------------------------------------
        # The client side: FreeRDP plus what setup.sh shells out to. Names come
        # from the per-distribution dependency lists in the WinApps README.
        # freerdp3-x11 is Debian's v3 package; the others ship v3 as 'freerdp'.
        debian:extra_winapps) echo "curl dialog freerdp3-x11 git iproute2 libnotify-bin netcat-openbsd" ;;
        rhel:extra_winapps)   echo "curl dialog freerdp git iproute libnotify nmap-ncat" ;;
        suse:extra_winapps)   echo "curl dialog freerdp git iproute2 libnotify-tools netcat-openbsd" ;;
        arch:extra_winapps)   echo "curl dialog freerdp git iproute2 libnotify openbsd-netcat" ;;

        # Backend that hosts the Windows guest. Only the chosen one is
        # installed, and 'manual' (an existing RDP host on the network) needs
        # none of it.
        debian:winapps_libvirt) echo "qemu-kvm libvirt-daemon-system libvirt-clients virt-manager virtiofsd libvirt-daemon-config-network" ;;
        rhel:winapps_libvirt)   echo "qemu-kvm libvirt virt-manager virt-install virtiofsd libvirt-daemon-config-network" ;;
        suse:winapps_libvirt)   echo "qemu-kvm libvirt virt-manager virt-install" ;;
        arch:winapps_libvirt)   echo "qemu-full libvirt virt-manager dnsmasq iptables-nft" ;;

        # Extra tooling for '--winapps-deploy': UEFI firmware and an emulated TPM
        # (Windows 11 needs both), an ISO authoring tool for the unattended
        # answer disk, and virt-viewer to watch the install.
        debian:winapps_deploy) echo "ovmf swtpm swtpm-tools xorriso virt-viewer qemu-utils" ;;
        rhel:winapps_deploy)   echo "edk2-ovmf swtpm swtpm-tools xorriso virt-viewer qemu-img" ;;
        suse:winapps_deploy)   echo "qemu-ovmf-x86_64 swtpm swtpm-tools xorriso virt-viewer qemu-tools" ;;
        arch:winapps_deploy)   echo "edk2-ovmf swtpm libisoburn virt-viewer" ;;

        debian:winapps_docker) echo "docker.io docker-compose-v2" ;;
        rhel:winapps_docker)   echo "docker docker-compose" ;;
        suse:winapps_docker)   echo "docker docker-compose" ;;
        arch:winapps_docker)   echo "docker docker-compose" ;;

        debian:winapps_podman) echo "podman podman-compose" ;;
        rhel:winapps_podman)   echo "podman podman-compose" ;;
        suse:winapps_podman)   echo "podman podman-compose" ;;
        arch:winapps_podman)   echo "podman podman-compose" ;;

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

# Where backups go when they must not sit beside the original. See
# OUT_OF_TREE_BACKUP_DIR usage in configure_sddm_greeter: SDDM parses every file
# in /etc/sddm.conf.d/ regardless of name, so a .bak left there becomes live
# configuration.
readonly OUT_OF_TREE_BACKUP_DIR="/var/backups/${PROGRAM_NAME}"

# backup_file <file> [dest_dir]
#
# Without dest_dir the copy lands beside the original, which is what almost
# every caller wants. Pass dest_dir for files inside a directory that some
# daemon reads wholesale.
backup_file() {
    local f="$1" destdir="${2:-}"
    [[ -f "$f" ]] || return 0
    [[ $DRY_RUN -eq 1 ]] && { printf '%s  [dry-run]%s back up %s\n' "$C_CYAN" "$C_RESET" "$f"; return 0; }
    local bak
    if [[ -n "$destdir" ]]; then
        mkdir -p "$destdir" || { warn "Could not create $destdir; $f not backed up."; return 1; }
        bak="$destdir/${f##*/}.$(date +%Y%m%d%H%M%S).bak"
    else
        bak="${f}.${PROGRAM_NAME}.$(date +%Y%m%d%H%M%S).bak"
    fi
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
# least 0.19. "Don't fill UserModel if theme does not require it" - the commit
# that added needsFullUserModel - shipped in 0.19.0 (2020-11-02), not 0.20, and
# 0.19 is what Ubuntu 22.04 LTS carries. Split out from the probe below so the
# comparison can be tested without SDDM installed.
version_has_last_user_model() {
    local ver="$1" major minor
    ver="$(printf '%s' "$ver" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    [[ -n "$ver" ]] || return 1
    major="${ver%%.*}"; minor="${ver##*.}"
    (( 10#$major > 0 )) && return 0
    (( 10#$minor >= 19 ))
}

# sddm_package_version - the installed SDDM version according to the package
# database.
#
# Deliberately NOT `sddm --version`. On at least some builds - Kubuntu's among
# them - the daemon does not recognise the flag and simply *starts*: it grabs a
# VT, brings up a display server and throws a greeter over whatever session was
# in front of you. Nothing is lost, the old session keeps running on its own VT,
# but it is indistinguishable from being locked out of your own machine. A probe
# has no business being able to do that, so nothing here executes sddm.
sddm_package_version() {
    local v=""
    if have dpkg-query; then
        v="$(dpkg-query -W -f='${Version}' sddm 2>/dev/null)"
    fi
    if [[ -z "$v" ]] && have rpm; then
        v="$(rpm -q --qf '%{VERSION}' sddm 2>/dev/null)"
    fi
    if [[ -z "$v" ]] && have pacman; then
        v="$(pacman -Q sddm 2>/dev/null | awk '{print $2}')"
    fi
    printf '%s' "$v"
}

# sddm_binary_knows_last_user_model - look for the option name inside the
# greeter binary. The greeter reads it through ThemeConfig, so the literal
# string is linked in, which makes this a direct capability check rather than a
# version comparison. Used when no package database can answer.
sddm_binary_knows_last_user_model() {
    local b
    for b in /usr/bin/sddm-greeter-qt6 /usr/bin/sddm-greeter \
             /usr/libexec/sddm-greeter /usr/lib/sddm/sddm-greeter \
             /usr/lib/*/libexec/sddm-greeter /usr/bin/sddm; do
        [[ -f "$b" ]] || continue
        grep -qa 'needsFullUserModel' "$b" 2>/dev/null && return 0
    done
    return 1
}

# sddm_has_last_user_model - true when the installed SDDM understands
# needsFullUserModel. Older builds can only show an enumerated user list.
sddm_has_last_user_model() {
    have sddm || return 1

    local v
    v="$(sddm_package_version)"
    if [[ -n "$v" ]]; then
        version_has_last_user_model "$v"
        return $?
    fi

    sddm_binary_knows_last_user_model
}

# sddm_local_user_count [passwd_file] - how many accounts the greeter would list
# from files(5). Only local accounts are counted, because SSSD does not answer
# getpwent() and so contributes nothing to the enumeration. The UID window is
# the greeter's own default: 1000 to 60000, which is what keeps 'nobody' (65534)
# off the login screen.
sddm_local_user_count() {
    awk -F: '$3 >= 1000 && $3 <= 60000' "${1:-/etc/passwd}" 2>/dev/null | wc -l
}

# sddm_avatar_threshold <local_user_count> - the DisableAvatarsThreshold that
# makes SDDM look the last user up by name, or nothing when it cannot work.
#
# This is the whole trick, and it is not obvious from the option name. In
# UserModel.cpp the getpwnam() fallback for the last user is not a separate
# code path - it lives *inside* the early-exit branch of the getpwent() loop:
#
#     if (!needAllUsers && d->users.count() > Theme.DisableAvatarsThreshold) {
#         if (!lastUserFound && (lastUserData = getpwnam(lastUser())))
#             d->users << ...
#         break;
#     }
#
# So needsFullUserModel=false only disarms the `needAllUsers` half of that
# condition. The count still has to exceed the threshold for the branch to run
# at all, and the default threshold is 7 - more than the number of accounts on
# any normal workstation. The loop therefore never breaks, the fallback never
# fires, and the domain user never appears. That is why setting
# needsFullUserModel on its own changes nothing.
#
# Setting the threshold to one below the local user count makes the branch fire
# on the last local account: every local user is already in the model, the
# domain user is appended by name, and nothing is lost.
sddm_avatar_threshold() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n >= 1 )) || return 1
    printf '%s' "$(( n - 1 ))"
}

# --- The forked theme ------------------------------------------------------
#
# Arming the getpwnam() fallback puts the domain user in the model but does not
# put them on screen, because Breeze refuses to draw a user list at all once the
# model is incomplete. Main.qml:
#
#     showUserList: {
#         ...
#         if (userListModel.hasOwnProperty("containsAllUsers")
#             && !userListModel.containsAllUsers) {
#             return false                                     // (1)
#         }
#         return userListModel.count <= userListModel.disableAvatarsThreshold  // (2)
#     }
#
# Both bails fire. (1) because UserModel sets containsAllUsers = false in the
# very branch that appends the domain user - on every released SDDM the only
# code path that adds the account is the one that marks the model partial. (2)
# because the threshold has to sit *below* the user count for that branch to run
# at all, which is the exact opposite of what this test wants. The greeter falls
# back to a username field with the remembered name typed in, which is not a
# user list.
#
# Neither is reachable from configuration, so the theme is forked and those two
# lines are patched. Everything except Main.qml is symlinked at the packaged
# theme, so a Plasma upgrade keeps the fork's assets and sub-components current
# and only the one patched file can go stale; the fork is rebuilt from source on
# every run, so that staleness is corrected the next time this is used.
#
# SDDM's develop branch has already hoisted the fallback out of the loop, so
# containsAllUsers stays true and stock Breeze needs no patch. That is
# unreleased - v0.21.0 is still the newest tag - and nothing here tries to
# detect it, because a branch for a version that does not exist yet cannot be
# tested against one. When 0.22 ships, the fork can be dropped and the drop-in
# reduced to RememberLastUser on its own.
# Not readonly: the test suite redirects it at a temporary tree so a fork can be
# built and inspected end to end without writing under /usr or needing root.
SDDM_THEME_ROOT="${SDDM_THEME_ROOT:-/usr/share/sddm/themes}"
readonly SDDM_FORK_SUFFIX="-domain"
readonly SDDM_FORK_STAMP=".domain-join-setup.source"

# sddm_theme_dir <name> [root] - where a theme actually lives, or nothing. The
# optional root is what the test suite points at a temporary tree, so the
# lookup can be exercised without writing under /usr.
sddm_theme_dir() {
    local d
    if [[ -n "${2:-}" ]]; then
        [[ -d "$2/$1" ]] && { printf '%s' "$2/$1"; return 0; }
        return 1
    fi
    for d in "$SDDM_THEME_ROOT/$1" "/usr/local/share/sddm/themes/$1"; do
        [[ -d "$d" ]] && { printf '%s' "$d"; return 0; }
    done
    return 1
}

# sddm_fork_source <theme> [root] - the theme a fork should be derived from. A
# fork records its origin, so a second run refreshes from the real Breeze
# instead of forking the fork and patching an already-patched file.
sddm_fork_source() {
    local theme="$1" dir src
    dir="$(sddm_theme_dir "$theme" "${2:-}")" || { printf '%s' "$theme"; return 0; }
    if [[ -f "$dir/$SDDM_FORK_STAMP" ]]; then
        src="$(awk -F= '/^source=/ { print $2 }' "$dir/$SDDM_FORK_STAMP" | tail -1)"
        [[ -n "$src" ]] && { printf '%s' "$src"; return 0; }
    fi
    printf '%s' "$theme"
}

# sddm_patch_main_qml <file> - neutralise the two bails. Both anchors appear
# exactly once in Breeze, and a mismatch is reported rather than ignored: a
# silently unpatched copy would look like a working theme and behave like the
# broken one.
sddm_patch_main_qml() {
    local f="$1"
    sed -i \
        -e 's|&& !userListModel\.containsAllUsers|\&\& false /* domain-join-setup: the partial model is deliberate */|' \
        -e 's|return userListModel\.count <= userListModel\.disableAvatarsThreshold|return userListModel.count > 0 /* domain-join-setup: the threshold is tuned for the getpwnam fallback, not for hiding the list */|' \
        "$f" || return 1
    grep -q '&& !userListModel\.containsAllUsers' "$f" && return 1
    grep -q 'return userListModel\.count <= userListModel\.disableAvatarsThreshold' "$f" && return 1
    grep -q 'domain-join-setup' "$f" || return 1
    return 0
}

# sddm_build_forked_theme <source_theme> - build <source>-domain, print its name.
#
# Built in a staging directory and swapped in only once the patch has verified,
# because the live theme is what the login screen loads: a half-built one is a
# machine nobody can log into.
sddm_build_forked_theme() {
    local src="$1" srcdir forkname forkdir staging entry base
    srcdir="$(sddm_theme_dir "$src")" || { warn "SDDM theme '$src' was not found."; return 1; }
    forkname="${src}${SDDM_FORK_SUFFIX}"
    forkdir="$SDDM_THEME_ROOT/$forkname"
    staging="${forkdir}.new"

    if [[ ! -f "$srcdir/Main.qml" ]]; then
        warn "$srcdir has no Main.qml, so there is nothing to fork."
        return 1
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s fork %s -> %s (Main.qml patched, everything else symlinked)\n' \
            "$C_CYAN" "$C_RESET" "$srcdir" "$forkdir"
        printf '%s' "$forkname"
        return 0
    fi

    # Only ever replace a directory this script built. Anything else under that
    # name is somebody's own theme and is left strictly alone.
    if [[ -e "$forkdir" && ! -f "$forkdir/$SDDM_FORK_STAMP" ]]; then
        warn "$forkdir exists but was not created by this installer; leaving it alone."
        return 1
    fi

    rm -rf -- "$staging" || return 1
    mkdir -p "$staging" || return 1

    for entry in "$srcdir"/*; do
        [[ -e "$entry" ]] || continue
        base="${entry##*/}"
        [[ "$base" == "Main.qml" || "$base" == "metadata.desktop" ]] && continue
        ln -sfn "$entry" "$staging/$base" || { rm -rf -- "$staging"; return 1; }
    done

    cp -a "$srcdir/Main.qml" "$staging/Main.qml" || { rm -rf -- "$staging"; return 1; }
    if ! sddm_patch_main_qml "$staging/Main.qml"; then
        warn "Breeze's showUserList no longer matches what this patch expects."
        note "Plasma has rewritten Main.qml, so the fork would be built and do nothing."
        note "The login screen is left exactly as it is rather than changed into a lie."
        rm -rf -- "$staging"
        return 1
    fi

    # Its own copy, so the fork is distinguishable in Plasma's Login Screen module
    # instead of showing up as a second entry with the same name as the original.
    if [[ -f "$srcdir/metadata.desktop" ]]; then
        cp -a "$srcdir/metadata.desktop" "$staging/metadata.desktop" \
            && sed -i "s|^Name=.*|Name=${src} (domain users)|" "$staging/metadata.desktop"
    fi

    # needsFullUserModel lives in the fork, so the packaged theme is never
    # touched at all - theme.conf above is a symlink to the distribution's own.
    ini_set "$staging/theme.conf.user" General needsFullUserModel false \
        || { rm -rf -- "$staging"; return 1; }

    {
        printf 'source=%s\n' "$src"
        printf 'source_dir=%s\n' "$srcdir"
        printf 'source_main_qml_sha256=%s\n' "$(sha256sum "$srcdir/Main.qml" | awk '{print $1}')"
        printf 'built=%s\n' "$(date -Is)"
        printf 'by=%s\n' "$PROGRAM_NAME"
    } > "$staging/$SDDM_FORK_STAMP" || { rm -rf -- "$staging"; return 1; }

    rm -rf -- "$forkdir" || { rm -rf -- "$staging"; return 1; }
    mv -T "$staging" "$forkdir" || return 1

    printf '%s' "$forkname"
}

# configure_sddm_greeter - put the domain user back on the login screen.
#
# SDDM builds its user list with getpwent(), which SSSD deliberately answers
# with local accounts only. A domain user is therefore absent and the greeter
# offers nothing but "Other". Rather than enumerate the directory, this switches
# the theme to SDDM's last-user model: one getpwnam() against the name in
# /var/lib/sddm/state.conf, which SSSD resolves happily. The result is the
# Windows behaviour - the machine's owner sees their own tile and types only a
# password.
#
# Two settings are needed, not one. needsFullUserModel=false on the theme, and a
# DisableAvatarsThreshold low enough for the lookup to actually run - see
# sddm_avatar_threshold for why the second one is what makes the difference.
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

    if ! sddm_has_last_user_model; then
        warn "This SDDM predates needsFullUserModel (0.19); the greeter will keep listing local users only."
        note "Either upgrade SDDM, or set 'enumerate = true' in sssd.conf together with an"
        note "ldap_user_search_base scoped to one OU, so the whole directory is not pulled."
        return 0
    fi

    # The greeter resolves the remembered account with getpwnam(), which ignores
    # MinimumUid/MaximumUid - those are only applied while walking getpwent().
    # So the AD UID, high as it is, needs no window widening here, and leaving
    # the 60000 default in place is what keeps 'nobody' off the login screen.
    local users threshold
    users="$(sddm_local_user_count)"
    if ! threshold="$(sddm_avatar_threshold "$users")"; then
        warn "No local account in the 1000-60000 range, so the greeter has nothing to enumerate."
        note "SDDM only looks the remembered user up while walking the local accounts, so it"
        note "needs at least one. Create a local account, or enumerate the directory instead."
        return 0
    fi

    # Sorts after 20-kubuntu.conf, kde_settings.conf and anything else a distro
    # or the Plasma "Login Screen" module drops in here. Drop-ins are read in
    # alphabetical order and the last value wins, so a 10- prefix loses to all
    # of them.
    local dropin="/etc/sddm.conf.d/zz-domain-users.conf"
    local legacy="/etc/sddm.conf.d/10-domain-users.conf"
    if [[ -f "$legacy" ]]; then
        backup_file "$legacy" "$OUT_OF_TREE_BACKUP_DIR"
        run rm -f "$legacy" && note "Removed $legacy (it sorted before the distro's own drop-ins)."
    fi

    # ConfigBase::load() walks this directory with
    # entryInfoList(QDir::Files | QDir::NoDotAndDotDot) - no name filter at all.
    # So a .bak sitting here is not an inert backup, it is live configuration,
    # and because "<name>.conf.<stamp>.bak" sorts after "<name>.conf" it wins
    # over the very file it was copied from. Earlier runs of this script left
    # exactly that behind. Clear them out and keep backups elsewhere from now on.
    [[ $DRY_RUN -eq 1 ]] || mkdir -p "$OUT_OF_TREE_BACKUP_DIR" 2>/dev/null || true
    local stray moved=0
    for stray in /etc/sddm.conf.d/*.bak /etc/sddm.conf.d/*~ /etc/sddm.conf.d/*.orig; do
        [[ -f "$stray" ]] || continue
        # Moved, never deleted -- it is still the user's backup, it just cannot
        # live in a directory that gets parsed.
        if run mv -f "$stray" "$OUT_OF_TREE_BACKUP_DIR/"; then
            moved=1
        else
            warn "Could not move $stray out of /etc/sddm.conf.d/; SDDM will keep reading it."
        fi
    done
    if (( moved )); then
        note "Stale backups moved to $OUT_OF_TREE_BACKUP_DIR -- SDDM was parsing them as config."
    fi

    # /etc/sddm.conf is appended *after* the drop-in directory, so it overrides
    # every drop-in. Worth saying out loud rather than silently losing to it.
    # Current belongs in this list above all: it is the key that selects the
    # forked theme, so a Current= in /etc/sddm.conf does not merely weaken the
    # result, it discards the whole thing while every other setting still looks
    # correctly applied.
    if [[ -f /etc/sddm.conf ]] \
       && grep -qE '^[[:space:]]*(Current|MaximumUid|MinimumUid|DisableAvatarsThreshold|EnableAvatars|RememberLastUser)[[:space:]]*=' \
            /etc/sddm.conf 2>/dev/null; then
        warn "/etc/sddm.conf sets one of these keys itself, and it is read after the drop-ins."
        grep -nE '^[[:space:]]*(Current|MaximumUid|MinimumUid|DisableAvatarsThreshold|EnableAvatars|RememberLastUser)[[:space:]]*=' \
            /etc/sddm.conf 2>/dev/null | while read -r line; do note "  /etc/sddm.conf:$line"; done
        note "Remove the conflicting line from /etc/sddm.conf or this drop-in will not win."
    fi

    backup_file "$dropin" "$OUT_OF_TREE_BACKUP_DIR"
    ini_set "$dropin" Users MinimumUid 1000                       || { warn "Could not write $dropin."; return 0; }
    ini_set "$dropin" Users RememberLastUser true                 || { warn "Could not write $dropin."; return 0; }
    ini_set "$dropin" Theme DisableAvatarsThreshold "$threshold"  || { warn "Could not write $dropin."; return 0; }
    # Explicit, because the model disables avatars by itself once the count is
    # over the threshold - but only while the setting is still at its default.
    ini_set "$dropin" Theme EnableAvatars true                    || { warn "Could not write $dropin."; return 0; }
    [[ $DRY_RUN -eq 0 ]] && ok "$dropin: last-user lookup armed ($users local accounts, threshold $threshold)"

    local theme source forkname
    theme="$(sddm_current_theme)"
    source="$(sddm_fork_source "$theme")"
    if ! sddm_theme_dir "$source" >/dev/null; then
        warn "SDDM theme '$source' was not found; leaving the login screen alone."
        return 0
    fi

    if ! forkname="$(sddm_build_forked_theme "$source")"; then
        note "The drop-in above still stands, so the remembered user is offered as a"
        note "pre-filled username. That is SDDM's own behaviour without the patched theme."
        return 0
    fi

    if ! ini_set "$dropin" Theme Current "$forkname"; then
        warn "Could not point SDDM at $forkname; the packaged theme stays selected."
        return 0
    fi
    [[ $DRY_RUN -eq 0 ]] && ok "$dropin: theme set to $forkname (local users and the last domain user as tiles)"

    note "Applies at the next login screen. Log out normally when you are ready."
    warn "Do not 'systemctl restart sddm' from inside a session: that starts a fresh greeter"
    note "on a new VT and looks exactly like being locked out, while the old session keeps"
    note "running behind it. Logging back in shows the session still there."
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

# invoking_user_is_domain_user - true when the account that started this script
# is served by the directory rather than by /etc/passwd. Checking files(5)
# first and only then the full NSS stack keeps a local account whose name also
# exists in AD on the local side of the answer.
invoking_user_is_domain_user() {
    local u=""
    # pkexec hands over a UID rather than a name; logname reads the owner of the
    # controlling terminal. Either way what is wanted is the pre-sudo account.
    if [[ -n "${PKEXEC_UID:-}" ]]; then
        u="$(getent passwd "$PKEXEC_UID" 2>/dev/null | cut -d: -f1)"
    elif [[ -n "${SUDO_USER:-}" ]]; then
        u="$SUDO_USER"
    else
        u="$(logname 2>/dev/null)" || u=""
    fi

    [[ -n "$u" && "$u" != "root" ]] || return 1
    cut -d: -f1 /etc/passwd 2>/dev/null | grep -qxF "$u" && return 1
    getent passwd "$u" >/dev/null 2>&1
}

# restart_sssd [flush] - make sssd.conf changes take effect.
#
# "flush" also drops the on-disk cache, which is required whenever the name
# format changed. Every record in cache_<domain>.ldb was written under the old
# form, and a lookup for the new one misses until the cache is rebuilt, so
# 'jdoe' keeps failing while sssd.conf plainly says use_fully_qualified_names =
# False. The setting is right; the daemon is just still answering from stale
# records. This is the single most common reason the short-name option looks
# like it did nothing.
restart_sssd() {
    local flush="${1:-}"

    # Restarting SSSD underneath a live graphical session owned by a domain user
    # pulls NSS and PAM out from under it. The screen locker engages, a greeter
    # comes back, and the session keeps running behind it -- indistinguishable
    # from being thrown out, even though nothing was lost. Not worth doing to
    # someone mid-session when the next boot picks it up for free.
    if invoking_user_is_domain_user; then
        printf '\n'
        warn "This session belongs to a domain user, so SSSD is being left running."
        note "Restarting it here would lock the session and drop you at the login screen,"
        note "with the session still alive behind it. Reboot, or run this from a local"
        note "account, and the changes apply on the way back up:"
        if [[ "$flush" == "flush" ]]; then
            printf '    %ssudo systemctl stop sssd && sudo rm -f /var/lib/sss/db/*.ldb && sudo systemctl start sssd%s\n' \
                "$C_CYAN" "$C_RESET"
        else
            printf '    %ssudo systemctl restart sssd%s\n' "$C_CYAN" "$C_RESET"
        fi
        return 0
    fi

    if [[ "$flush" == "flush" ]]; then
        info "Clearing the SSSD cache so the new name format is picked up"
        run_quiet systemctl stop sssd
        # Cached credentials go with the cache, so the first login after this
        # has to reach a domain controller. Everything else is refetched on
        # demand. sss_cache -E only marks records stale, which is not enough
        # when the keys themselves are in the old format.
        if run_quiet sh -c 'rm -f /var/lib/sss/db/*.ldb'; then
            ok "SSSD cache cleared (the next domain login must be online)"
        else
            warn "Could not clear /var/lib/sss/db; short names may not resolve until it is."
        fi
    fi

    info "Restarting SSSD to apply the changes"
    run_quiet systemctl restart sssd && ok "sssd restarted" || warn "Could not restart sssd."
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

    # Tracked because turning this on is what makes the cache wipe necessary
    # below: the cached records are keyed by the old, qualified name.
    local names_changed=0
    if confirm "Allow short usernames (jdoe) instead of requiring jdoe@${OPT_DOMAIN}?" "y"; then
        backup_file /etc/sssd/sssd.conf
        names_changed=1
        if [[ $DRY_RUN -eq 0 ]]; then
            sssd_set_option "use_fully_qualified_names" "False"
            sssd_set_option "fallback_homedir" "/home/%u"
            ok "sssd.conf: short names enabled, home directories under /home/<user>"
            note "jdoe@${OPT_DOMAIN} keeps working too -- the short form is what gets displayed."
            if (( ! WANT_MKHOMEDIR )) && ! grep -rq 'pam_mkhomedir\|pam_oddjob_mkhomedir' /etc/pam.d/ 2>/dev/null; then
                warn "Home directories move to /home/<user>, but nothing on this machine creates them."
                note "Without pam_mkhomedir a domain login lands in a missing \$HOME and the desktop"
                note "session dies on the spot, straight back to the greeter. Run this script's"
                note "'Create home directories on first login' step, or enable it by hand."
            fi
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

    if (( names_changed )); then
        restart_sssd flush
    else
        restart_sssd
    fi

    # After the restart, not before: configure_sudo_access checks each name
    # through getent, and a daemon still holding the pre-change configuration
    # (or a stale cache) would answer for the wrong form of the name.
    configure_sudo_access
}

# ---------------------------------------------------------------------------
# sudo rights for an account or a group
#
# Every grant is its own drop-in under /etc/sudoers.d, never a line appended to
# /etc/sudoers: a drop-in is undone by deleting one file, and a botched edit to
# the main file takes every sudo on the machine with it.
#
# A domain principal is not a well behaved filename. 'Linux Admins@corp.example.com'
# carries a space and two dots, and sudo skips any file in sudoers.d whose name
# contains a dot or ends in '~' - so the name is slugified for the filename and
# only the rule inside the file spells it out verbatim.
# ---------------------------------------------------------------------------
# Not readonly: the test suite points it at a temporary directory so the real
# write path is what gets exercised.
SUDOERS_DIR="/etc/sudoers.d"

# Fold a principal into something sudo will actually read as a filename.
sudoers_slug() {
    local s="${1,,}"
    s="${s//[^a-z0-9]/-}"
    while [[ "$s" == *--* ]]; do s="${s//--/-}"; done
    s="${s#-}"; s="${s%-}"
    s="${s:0:56}"
    s="${s%-}"
    printf '%s' "$s"
}

# sudoers reads ',', '=', ':', '(', ')', '!' and '#' as syntax, and a backslash
# as the escape this script adds itself. A name holding any of them cannot be
# written as a plain rule, so it is rejected here rather than turned into a file
# that visudo refuses - or, worse, one it accepts as something other than the
# name that was typed. A space is legal, and common in AD group names.
valid_sudo_principal() {
    # 'ALL' is the sudoers wildcard, not a name: as a typo it reads as a valid
    # rule handing every account on the machine full root.
    [[ "$1" == "ALL" ]] && return 1
    # Single quoted so the '$-' inside the bracket expression is not expanded as
    # the shell's own option-flags parameter before the match runs.
    local re='^[A-Za-z0-9._@$-]+( +[A-Za-z0-9._@$-]+)*$'
    [[ "$1" =~ $re ]]
}

# The realm this machine belongs to, for the qualified retry below. OPT_DOMAIN
# is whatever a join in this run used; realm knows it for an existing member.
sudo_domain_suffix() {
    local d="${OPT_DOMAIN:-}"
    if [[ -z "$d" ]] && have realm; then
        d="$(realm list --name-only 2>/dev/null | head -1)"
    fi
    printf '%s' "${d,,}"
}

# NSS lookup, retried with the domain appended. With use_fully_qualified_names
# left at its default a joined machine answers only to 'name@domain' - which is
# the form that then has to go into the rule, since sudo resolves the name the
# same way. Sets SUDO_RESOLVED to the form that answered. Returns 2, not 1, when
# there is no getent to ask: unknown is not the same as absent.
SUDO_RESOLVED=""
sudo_resolve_principal() {
    local kind="$1" name="$2" db="passwd" domain
    [[ "$kind" == "group" ]] && db="group"
    SUDO_RESOLVED=""

    have getent || return 2

    if getent "$db" "$name" >/dev/null 2>&1; then
        SUDO_RESOLVED="$name"
        return 0
    fi

    domain="$(sudo_domain_suffix)"
    if [[ -n "$domain" && "$name" != *@* ]] \
        && getent "$db" "${name}@${domain}" >/dev/null 2>&1; then
        SUDO_RESOLVED="${name}@${domain}"
        return 0
    fi
    return 1
}

# The member list is the quickest confirmation that the group found is the group
# meant - a local group of the same name resolves just as happily as the AD one.
sudo_show_group_members() {
    local members
    have getent || return 0
    members="$(getent group "$1" 2>/dev/null | awk -F: '{print $4}')"
    if [[ -n "$members" ]]; then
        note "Members: ${members//,/, }"
    else
        note "getent lists no members for '$1'. Accounts holding it as their"
        note "primary group are not listed there, so this alone is not a fault."
    fi
    return 0
}

# sudoers_write_rule <user|group> <name>
sudoers_write_rule() {
    local kind="$1" name="$2"
    local slug file rule tmp

    slug="$(sudoers_slug "$name")"
    if [[ -z "$slug" ]]; then
        err "'$name' has nothing in it that can be used as a filename."
        return 1
    fi
    file="$SUDOERS_DIR/domain-join-${kind}-${slug}"

    # A space is the one character common in AD names that sudoers reads as a
    # separator, so it is escaped in the rule itself.
    if [[ "$kind" == "group" ]]; then
        rule="%${name// /\\ } ALL=(ALL:ALL) ALL"
    else
        rule="${name// /\\ } ALL=(ALL:ALL) ALL"
    fi

    # A second run over the same name is a no-op rather than another identical
    # file and another backup of it.
    if [[ -f "$file" && "$(grep -v '^#' "$file" 2>/dev/null)" == "$rule" ]]; then
        ok "$file already grants this"
        note "  $rule"
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s write %s containing:\n' "$C_CYAN" "$C_RESET" "$file"
        printf '%s  [dry-run]%s   %s\n' "$C_CYAN" "$C_RESET" "$rule"
        return 0
    fi

    if [[ ! -d "$SUDOERS_DIR" ]]; then
        mkdir -p "$SUDOERS_DIR" || { err "Could not create $SUDOERS_DIR."; return 1; }
        chmod 0750 "$SUDOERS_DIR"
    fi

    # Checked before it is installed, never after. A syntax error anywhere in
    # /etc/sudoers.d makes sudo refuse to run at all, so a file that fails the
    # check must never have existed at that path, not even for a moment.
    tmp="$(mktemp "${TMPDIR:-/tmp}/${PROGRAM_NAME}.sudoers.XXXXXX")" || {
        err "Could not create a temporary file to validate the rule."
        return 1
    }
    printf '# Written by %s on %s\n%s\n' \
        "$PROGRAM_NAME" "$(date '+%Y-%m-%d %H:%M:%S')" "$rule" >"$tmp"
    chmod 0440 "$tmp"

    if have visudo; then
        if ! visudo -cf "$tmp" >/dev/null 2>&1; then
            rm -f "$tmp"
            err "The rule generated for '$name' is not valid sudoers syntax; nothing was written."
            return 1
        fi
    else
        warn "visudo is not installed, so the rule could not be syntax checked."
    fi

    [[ -f "$file" ]] && backup_file "$file" "$OUT_OF_TREE_BACKUP_DIR"

    # sudo ignores any file in sudoers.d that is not owned by root or is group
    # writable, so the ownership is stated rather than inherited. Skipped when
    # not root, which is only ever the test suite: install would just fail.
    local -a inst=(install -m 0440)
    (( EUID == 0 )) && inst+=(-o root -g root)

    if "${inst[@]}" "$tmp" "$file"; then
        rm -f "$tmp"
        ok "$file"
        note "  $rule"
        log_to_file "SUDO  $kind '$name' -> $file"
        return 0
    fi

    rm -f "$tmp"
    err "Could not install $file."
    return 1
}

# Why a name was rejected. Split out of sudo_grant_one so the interactive
# prompt can say the same thing before it asks again.
sudo_principal_syntax_error() {
    err "'$1' holds a character that sudoers cannot carry in a name."
    note "Letters, digits, spaces and . _ - @ \$ only: ',', '=', ':', '!' and '#'"
    note "are sudoers syntax, so a name containing them cannot be written as a rule."
}

# sudo_grant_one <user|group> <name> [forced]
#
# forced=1 means the name came from a flag rather than a prompt, so an
# unresolvable name is reported and written anyway instead of asking.
sudo_grant_one() {
    local kind="$1" name="$2" forced="${3:-0}" rc=0

    if ! valid_sudo_principal "$name"; then
        sudo_principal_syntax_error "$name"
        return 1
    fi

    sudo_resolve_principal "$kind" "$name" || rc=$?
    case $rc in
        0)
            if [[ "$SUDO_RESOLVED" != "$name" ]]; then
                note "'$name' only resolves as '$SUDO_RESOLVED'; using the qualified form."
                name="$SUDO_RESOLVED"
            fi
            ok "The $kind '$name' resolves on this machine"
            [[ "$kind" == "group" ]] && sudo_show_group_members "$name"
            ;;
        2)
            warn "getent is not available, so '$name' could not be checked."
            ;;
        *)
            warn "Nothing on this machine resolves the $kind '$name'."
            local db="passwd"
            [[ "$kind" == "group" ]] && db="group"
            note "Check it with: getent $db '$name'"
            local suffix
            suffix="$(sudo_domain_suffix)"
            if [[ -n "$suffix" && "$name" != *@* ]]; then
                note "A joined machine often answers only to '${name}@${suffix}'."
            elif [[ "$kind" == "group" ]]; then
                note "Directory groups only answer once SSSD is running and the machine"
                note "has joined, so this is expected before the join."
            fi
            note "A rule naming something that does not exist grants nothing, and stays"
            note "wrong quietly until somebody reads the file."
            if (( forced )); then
                warn "Writing it anyway, since it was named on the command line."
            elif ! confirm "Write the rule anyway?" "n"; then
                note "Left '$name' alone."
                return 0
            fi
            ;;
    esac

    sudoers_write_rule "$kind" "$name" || return 1

    if [[ "$kind" == "group" ]]; then
        note "Group membership is read at login, so a member already signed in has to"
        note "log out and back in before sudo will see it."
    fi
    return 0
}

# Ask for one name and grant it. A name sudoers cannot spell is a typo, not a
# decision, so it is asked again rather than abandoning the grant - the reason
# the name was refused is on screen and the answer is one correction away.
# Enter on an empty line is the way out.
sudo_grant_interactive() {
    local kind="$1" name prompt domain
    domain="$(sudo_domain_suffix)"
    domain="${domain:-corp.example.com}"

    if [[ "$kind" == "group" ]]; then
        prompt="Group to grant sudo (e.g. 'Linux Admins' or 'Linux Admins@${domain}')"
    else
        prompt="Account to grant sudo (e.g. jdoe or jdoe@${domain})"
    fi

    while true; do
        printf '\n'
        ask_value name "$prompt" ""
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"

        if [[ -z "$name" ]]; then
            note "No $kind given; nothing granted."
            return 0
        fi

        if valid_sudo_principal "$name"; then
            break
        fi

        sudo_principal_syntax_error "$name"
        note "Type it again, or press Enter on an empty line to grant nothing."
        # ASSUME_YES makes ask_value return the (empty) default without reading,
        # so looping here would spin forever on a bad --sudo-user default.
        (( ASSUME_YES )) && return 1
    done

    sudo_grant_one "$kind" "$name"
}

# --sudo-user / --sudo-group, comma separated. Only the comma splits: a name may
# legitimately contain spaces.
sudo_grant_list() {
    local kind="$1" list="$2" rc=0 name
    local -a names=()
    [[ -z "$list" ]] && return 0

    IFS=',' read -r -a names <<<"$list"
    for name in "${names[@]}"; do
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"
        [[ -z "$name" ]] && continue
        sudo_grant_one "$kind" "$name" 1 || rc=1
    done
    return $rc
}

# Reachable twice in one run - straight from the menu, and again through
# post_join_tuning after a join - so the second call is a no-op, the same way
# configure_sddm_greeter is guarded.
SUDO_ACCESS_DONE=0
configure_sudo_access() {
    (( SUDO_ACCESS_DONE )) && return 0
    SUDO_ACCESS_DONE=1

    heading "sudo rights"

    # Flags win outright and skip the prompts: -y with neither of them set is a
    # deliberate "leave sudo alone", not an invitation to guess.
    if [[ -n "$OPT_SUDO_USER" || -n "$OPT_SUDO_GROUP" ]]; then
        local frc=0
        sudo_grant_list user  "$OPT_SUDO_USER"  || frc=1
        sudo_grant_list group "$OPT_SUDO_GROUP" || frc=1
        return $frc
    fi

    note "Each grant becomes its own file in $SUDOERS_DIR, so it can be taken back"
    note "by deleting that one file. Local and domain accounts both work here."

    # A group is the usual answer and so the one Enter accepts - but under -y
    # the default is what runs unasked, and granting root to a guessed name is
    # not something a non-interactive run should do on its own.
    local choice rc=0 default_choice="group"
    (( ASSUME_YES )) && default_choice="skip"

    menu_single choice "Who should be allowed to use sudo on this machine?" "$default_choice" \
        "user|An account|Grants sudo to one account, local or domain. Use this for a named administrator rather than for everybody who happens to be in a directory group." \
        "group|A group|Grants sudo to every member of one group, which is how an AD 'Linux Admins' group is normally put to work: membership is then managed in the directory instead of on this machine." \
        "both|An account and a group|Asks for one of each, writing a separate file for each so either can be revoked on its own." \
        "skip|Neither|Leaves sudo exactly as it is. Nothing under $SUDOERS_DIR is written or removed."

    case "$choice" in
        user)
            sudo_grant_interactive user || rc=1
            ;;
        group)
            sudo_grant_interactive group || rc=1
            ;;
        both)
            sudo_grant_interactive user  || rc=1
            sudo_grant_interactive group || rc=1
            ;;
        skip)
            note "sudo left unchanged."
            ;;
    esac
    return $rc
}

# ---------------------------------------------------------------------------
# WinApps - Windows applications as Linux desktop launchers
# ---------------------------------------------------------------------------
# WinApps runs a Windows instance (a local VM, a container, or an existing RDP
# host) and launches individual Windows programs through FreeRDP so they appear
# as ordinary entries in the Linux application menu.
#
# Upstream installs one of two ways:
#
#   setup.sh --user    launchers in ~/.local/share/applications, binary in
#                      ~/.local/bin - visible to exactly one account
#   setup.sh --system  launchers in /usr/share/applications, binary in
#                      /usr/local/bin - visible to every account
#
# '--system' is therefore already the multi-user answer for the launchers, and
# the advice you will find in older write-ups - run setup.sh per user, or copy
# .desktop files into /usr/share/applications by hand - is obsolete.
#
# What '--system' does *not* solve is the configuration. bin/winapps opens
#
#   readonly CONFIG_PATH="${HOME}/.config/winapps/winapps.conf"
#
# and exits if it is missing. There is no /etc/winapps fallback, so every one of
# those shared launchers still needs a file in the home directory of whoever
# clicks it. That is the gap this section fills, and on a domain-joined machine
# it cannot be filled by writing the files in advance: the accounts arrive from
# the directory, and the first time you learn a user exists is when they log in.
#
# So the config is generated at login from a single root-owned template, with
# the account's own short name substituted into RDP_USER. That is what makes the
# session land in *that* user's Windows profile with *that* user's mapped
# drives, instead of everyone sharing one.
WINAPPS_ETC_DIR="/etc/winapps"
WINAPPS_TEMPLATE="$WINAPPS_ETC_DIR/winapps.conf.template"
WINAPPS_SEEDER="/usr/local/bin/winapps-user-config"
WINAPPS_ASKPASS="/usr/local/bin/winapps-askpass"
WINAPPS_PROFILE_D="/etc/profile.d/winapps-user-config.sh"
WINAPPS_AUTOSTART="/etc/xdg/autostart/winapps-user-config.desktop"
WINAPPS_SKEL_DIR="/etc/skel/.config/winapps"
WINAPPS_UPSTREAM_URL="https://raw.githubusercontent.com/winapps-org/winapps/main/setup.sh"
WINAPPS_CONFIGURED=0

# --winapps-deploy: building the Windows guest.
WINAPPS_VM_DEPLOYER="/usr/local/bin/winapps-vm-deploy"
WINAPPS_ISO_CACHE="/var/lib/winapps/iso"
WINAPPS_VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
WINAPPS_MIDO_URL="https://raw.githubusercontent.com/ElliotKillick/Mido/main/Mido.sh"
WINAPPS_RDPAPPS_URL="https://raw.githubusercontent.com/winapps-org/winapps/main/install/RDPApps.reg"
WINAPPS_VM_DEPLOYED=0

# winapps_install_file <dest> <mode> - content arrives on stdin.
#
# Written through a temporary file in the destination directory and moved into
# place, so a launcher or a login hook is never observed half-written. stdin is
# drained under --dry-run as well, or the caller's heredoc would back up.
winapps_install_file() {
    local dest="$1" mode="$2" tmp dir
    dir="$(dirname "$dest")"

    if [[ $DRY_RUN -eq 1 ]]; then
        cat >/dev/null
        printf '%s  [dry-run]%s write %s (mode %s)\n' "$C_CYAN" "$C_RESET" "$dest" "$mode"
        return 0
    fi

    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || { err "Could not create $dir."; return 1; }
    fi

    tmp="$(mktemp "${dir}/.${PROGRAM_NAME}.XXXXXX")" || {
        err "Could not create a temporary file in $dir."
        return 1
    }
    cat >"$tmp" || { rm -f "$tmp"; err "Could not write $dest."; return 1; }
    chmod "$mode" "$tmp" || { rm -f "$tmp"; err "Could not set mode on $dest."; return 1; }
    (( EUID == 0 )) && chown root:root "$tmp" 2>/dev/null

    [[ -f "$dest" ]] && backup_file "$dest" "$OUT_OF_TREE_BACKUP_DIR"

    if mv -f "$tmp" "$dest"; then
        ok "$dest"
        log_to_file "WINAPPS wrote $dest"
        return 0
    fi
    rm -f "$tmp"
    err "Could not install $dest."
    return 1
}

# The realm this machine is joined to, upper-cased, as RDP_DOMAIN wants it.
# Falls back to whatever -d/--domain said so a pre-join run still produces a
# usable template.
winapps_default_domain() {
    local d=""
    if have realm; then
        d="$(realm list --name-only 2>/dev/null | head -n1)"
    fi
    [[ -z "$d" ]] && d="$OPT_DOMAIN"
    [[ -z "$d" ]] && d="$(hostname -d 2>/dev/null)"
    printf '%s' "${d^^}"
}

# Which FreeRDP is actually installed. WinApps auto-detects this itself, so an
# empty result is a warning rather than a failure - but if it is empty *after*
# the packages went in, the launchers will not work and it is worth saying so
# now rather than at first click.
winapps_freerdp_cmd() {
    local c
    for c in xfreerdp3 xfreerdp sdl-freerdp3 sdl3-freerdp sdl-freerdp; do
        have "$c" && { printf '%s' "$c"; return 0; }
    done
    if have flatpak && flatpak list --columns=application 2>/dev/null | grep -q '^com.freerdp.FreeRDP$'; then
        printf 'flatpak run --command=xfreerdp com.freerdp.FreeRDP'
        return 0
    fi
    return 1
}

winapps_choose_backend() {
    local -a entries=()
    entries+=("libvirt|Local Windows VM via libvirt/KVM  ${C_GREEN}(recommended here)${C_RESET}|Runs Windows as a full virtual machine on this PC. The VM is joined to the domain in its own right, so a user's Windows profile, group policy and mapped drives all come from Active Directory exactly as they would on a physical Windows box. Best for a workstation that is used by one person at a time.")
    entries+=("manual|An existing Windows host on the network|No VM is run here at all: the launchers point at a Windows machine you already have, typically a Remote Desktop Session Host joined to the same domain. Much lighter on the client, and the only sensible option if you are rolling this out to more than a handful of PCs. You will be asked for its address.")
    entries+=("docker|Windows in a Docker container|Uses the dockur/windows image to run Windows under Docker. Quicker to stand up than libvirt and easy to reset, but it is still a full Windows install underneath and joining it to the domain is on you.")
    entries+=("podman|Windows in a Podman container|As above but rootless-capable under Podman. Note that FreeRDP has to be invoked through 'podman unshare' for rootless networking, which WinApps handles for you.")

    menu_single OPT_WINAPPS_BACKEND "Where should the Windows side run?" "libvirt" "${entries[@]}"
}

winapps_choose_creds() {
    local -a entries=()
    entries+=("askpass|Ask each user for their own AD password  ${C_GREEN}(recommended)${C_RESET}|Nothing secret is stored on disk. The first time a user opens a Windows app they are prompted for their Active Directory password, which is handed to FreeRDP through its askpass interface and never appears on a command line or in a log. It is cached in the kernel session keyring where available, so they are asked once per login rather than once per app.")
    entries+=("kerberos|Single sign-on with the user's Kerberos ticket|No password prompt at all: FreeRDP reuses the ticket SSSD obtained when the user logged into Linux. The cleanest experience by far, but it needs the Windows host domain-joined with a correct SPN and a ticket cache FreeRDP can read, so treat it as the thing to aim for rather than the thing to switch on blind. Falls back to a prompt if the ticket is refused.")
    entries+=("shared|One shared service account for everybody|Every user connects as the same Windows account, with its password stored in the root-owned template. Simple, and appropriate for a kiosk or a single shared appliance - but it defeats the point of the domain join, because all users land in one Windows profile and the directory cannot tell them apart. Not recommended on a multi-user machine.")

    menu_single OPT_WINAPPS_CREDS "How should users authenticate to Windows?" "askpass" "${entries[@]}"
}

# ---------------------------------------------------------------------------
# The generated pieces
# ---------------------------------------------------------------------------
# The askpass helper. FreeRDP runs whatever FREERDP_ASKPASS names and reads the
# password from its stdout, which keeps it out of both the process list and the
# WinApps debug log - unlike RDP_PASS, which becomes a '/p:' argument.
winapps_write_askpass() {
    info "Installing the password helper"
    winapps_install_file "$WINAPPS_ASKPASS" 0755 <<'WINAPPS_ASKPASS_EOF'
#!/bin/sh
#
# Written by domain-join-setup. Prints an Active Directory password on stdout
# for FreeRDP, which invokes this via FREERDP_ASKPASS.
#
# The password is cached in the *session* keyring, not a file: it dies with the
# login session, is unreadable by other users, and never touches disk.
set -u

KEY_DESC="winapps:rdp"
KEY_TIMEOUT=36000   # seconds; re-prompt roughly every ten hours

prompt_text="Active Directory password for ${USER:-$(id -un 2>/dev/null)}"
prompt_title="Windows application sign-in"

# --- Cached? -----------------------------------------------------------------
if command -v keyctl >/dev/null 2>&1; then
    key_id=$(keyctl request user "$KEY_DESC" 2>/dev/null)
    if [ -n "${key_id:-}" ]; then
        if keyctl pipe "$key_id" 2>/dev/null; then
            exit 0
        fi
    fi
fi

# --- Ask ---------------------------------------------------------------------
# A graphical prompt is required: this is invoked from a desktop launcher, so
# there is usually no terminal attached to read from.
pass=""
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v kdialog >/dev/null 2>&1; then
    pass=$(kdialog --title "$prompt_title" --password "$prompt_text" 2>/dev/null)
elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1; then
    pass=$(zenity --password --title "$prompt_title" 2>/dev/null)
elif command -v systemd-ask-password >/dev/null 2>&1; then
    pass=$(systemd-ask-password --no-tty "$prompt_text:" 2>/dev/null)
elif [ -t 0 ]; then
    stty -echo 2>/dev/null
    printf '%s: ' "$prompt_text" >&2
    IFS= read -r pass
    stty echo 2>/dev/null
    printf '\n' >&2
fi

[ -n "$pass" ] || exit 1

# --- Cache and emit ----------------------------------------------------------
if command -v keyctl >/dev/null 2>&1; then
    key_id=$(printf '%s' "$pass" | keyctl padd user "$KEY_DESC" @s 2>/dev/null)
    [ -n "${key_id:-}" ] && keyctl timeout "$key_id" "$KEY_TIMEOUT" >/dev/null 2>&1
fi

printf '%s' "$pass"
WINAPPS_ASKPASS_EOF
}

# The template every user's config is generated from. Root-owned and the single
# place any of this is edited: change it here and every user picks the change up
# at their next login.
winapps_write_template() {
    local domain="$1" backend="$2" creds="$3" host="$4" port="$5" vm="$6"
    local rdp_user_line rdp_pass_line askpass_line ip_line flags

    # '@WINAPPS_USER@' is the substitution the seeder makes per user. In shared
    # mode there is nothing to substitute - everyone is the same account.
    if [[ "$creds" == "shared" ]]; then
        rdp_user_line="RDP_USER=\"${OPT_WINAPPS_RDP_USER}\""
        rdp_pass_line="RDP_PASS=\"${OPT_WINAPPS_RDP_PASS}\""
        askpass_line='RDP_ASKPASS=""'
    else
        rdp_user_line='RDP_USER="@WINAPPS_USER@"'
        rdp_pass_line='RDP_PASS=""'
        askpass_line="RDP_ASKPASS=\"$WINAPPS_ASKPASS\""
    fi

    # Kerberos SSO: no password at all, and NLA told to use the ticket cache
    # SSSD populated at login.
    flags='/cert:tofu /sound /microphone +home-drive'
    if [[ "$creds" == "kerberos" ]]; then
        askpass_line="RDP_ASKPASS=\"$WINAPPS_ASKPASS\"   # fallback if the ticket is refused"
        flags="$flags /sec:nla"
    fi

    ip_line="RDP_IP=\"${host:-127.0.0.1}\""
    # libvirt discovers the guest address from the VM itself, and hard-coding
    # one here would override that with something that goes stale on reboot.
    [[ "$backend" == "libvirt" ]] && ip_line='#RDP_IP=""   # libvirt: discovered from VM_NAME at runtime'

    info "Writing the configuration template"
    winapps_install_file "$WINAPPS_TEMPLATE" 0644 <<WINAPPS_TEMPLATE_EOF
##############################################################################
# WinApps configuration template
#
# Written by $PROGRAM_NAME on $(date '+%Y-%m-%d %H:%M:%S').
#
# THIS FILE IS THE MASTER COPY. Do not edit the per-user copies under
# ~/.config/winapps/winapps.conf - they are regenerated from this file at
# login whenever this one changes, and your edits there would be overwritten.
#
# '@WINAPPS_USER@' is replaced with the login name of whoever is logging in,
# with any 'DOMAIN\\' prefix or '@realm' suffix stripped, so that each user
# reaches their own Windows profile.
#
# After editing, users pick the change up at their next login. To push it out
# to everyone who is already logged in:
#     sudo $WINAPPS_SEEDER --all
##############################################################################

# [WINDOWS USERNAME]
$rdp_user_line

# [WINDOWS PASSWORD]
# Left empty deliberately. RDP_ASKPASS names a helper whose stdout is used as
# the password, so nothing secret is stored on disk and nothing appears in the
# process list or the WinApps log.
$rdp_pass_line
$askpass_line

# [WINDOWS DOMAIN]
RDP_DOMAIN="$domain"

# [WINDOWS IPV4 ADDRESS]
$ip_line

# [RDP PORT]
RDP_PORT="${port:-3389}"

# [VM NAME] - libvirt only; must match the domain name shown by 'virsh list'.
VM_NAME="${vm:-RDPWindows}"

# [WINAPPS BACKEND]
WAFLAVOR="$backend"

# [DISPLAY SCALING] - 100, 140 or 180.
RDP_SCALE="100"

# [ADDITIONAL FREERDP FLAGS]
# '+home-drive' maps the user's Linux home into the Windows session, which is
# what lets a Windows program open and save files that live on this machine.
RDP_FLAGS="$flags"

# [DEBUG LOGGING] - writes ~/.local/share/winapps/winapps.log on each launch.
DEBUG="false"
WINAPPS_TEMPLATE_EOF
}

# The seeder. Runs as the logging-in user, generates their config from the
# template, and is deliberately incapable of failing loudly: anything that goes
# wrong here must not be allowed to block a login.
winapps_write_seeder() {
    info "Installing the per-user configuration generator"
    winapps_install_file "$WINAPPS_SEEDER" 0755 <<WINAPPS_SEEDER_EOF
#!/bin/sh
#
# Written by $PROGRAM_NAME.
#
# Generates ~/.config/winapps/winapps.conf from $WINAPPS_TEMPLATE for the
# user running it, substituting their own account name into RDP_USER.
#
# Runs at every login (from $WINAPPS_PROFILE_D for shell and SSH
# sessions, and from $WINAPPS_AUTOSTART for graphical ones -
# display managers do not reliably source /etc/profile.d, so both are wired
# up and the second one to run is a no-op).
#
# With --all, walks every home directory instead and seeds each one. That is
# for pushing a template change out to users who are already logged in; the
# per-user path needs no arguments and no privileges.
#
# Exits 0 on every path it can. A login must not fail because a Windows
# application launcher could not be configured.
set -u

TEMPLATE="$WINAPPS_TEMPLATE"
MARKER="# Generated by $PROGRAM_NAME from \$TEMPLATE"

[ -r "\$TEMPLATE" ] || exit 0

# seed_for <login-name> <home-directory>
seed_for() {
    _login="\$1"
    _home="\$2"
    [ -n "\$_login" ] && [ -n "\$_home" ] && [ -d "\$_home" ] || return 0

    # Strip 'DOMAIN\\' (Winbind) and '@realm' (SSSD fully-qualified names) so
    # what reaches RDP_USER is the bare sAMAccountName that Windows expects.
    _short="\${_login##*\\\\}"
    _short="\${_short%%@*}"
    [ -n "\$_short" ] || return 0

    _dir="\$_home/.config/winapps"
    _conf="\$_dir/winapps.conf"
    _stamp="\$MARKER (\$(cksum <"\$TEMPLATE" 2>/dev/null))"

    # Leave a hand-edited file alone. A user who wants to keep their own copy
    # deletes the marker line and this never touches it again.
    if [ -f "\$_conf" ]; then
        grep -qF "\$MARKER" "\$_conf" 2>/dev/null || return 0
        grep -qF "\$_stamp" "\$_conf" 2>/dev/null && return 0
    fi

    mkdir -p "\$_dir" 2>/dev/null || return 0

    _tmp="\$_conf.\$\$.tmp"
    {
        printf '%s\\n' "\$_stamp"
        printf '%s\\n' "# Edits here are overwritten at the next login. Change \$TEMPLATE instead,"
        printf '%s\\n' "# or delete the line above to keep this copy and stop it being regenerated."
        printf '%s\\n' ""
        sed "s/@WINAPPS_USER@/\$_short/g" "\$TEMPLATE"
    } >"\$_tmp" 2>/dev/null || { rm -f "\$_tmp" 2>/dev/null; return 0; }

    chmod 600 "\$_tmp" 2>/dev/null
    mv -f "\$_tmp" "\$_conf" 2>/dev/null || { rm -f "\$_tmp" 2>/dev/null; return 0; }

    # Only meaningful under --all, where this runs as root.
    if [ "\$(id -u)" = "0" ]; then
        chown -R "\$_login" "\$_dir" 2>/dev/null
    fi
    return 0
}

if [ "\${1:-}" = "--all" ]; then
    [ "\$(id -u)" = "0" ] || { echo "--all must be run as root." >&2; exit 1; }
    # getent covers domain accounts from SSSD/Winbind as well as local ones.
    getent passwd 2>/dev/null | while IFS=: read -r _n _x _u _g _c _h _s; do
        [ "\$_u" -ge 1000 ] 2>/dev/null || continue
        case "\$_s" in */nologin|*/false) continue ;; esac
        seed_for "\$_n" "\$_h"
    done
    exit 0
fi

# Per-user path: skip root and the system accounts entirely.
_uid="\$(id -u 2>/dev/null)" || exit 0
[ "\$_uid" -ge 1000 ] 2>/dev/null || exit 0
seed_for "\$(id -un 2>/dev/null)" "\${HOME:-}"
exit 0
WINAPPS_SEEDER_EOF
}

# Both login hooks call the same seeder. Display managers are inconsistent about
# sourcing /etc/profile.d for a graphical session - SDDM and GDM each do it only
# under some configurations - so the XDG autostart entry is what actually
# guarantees a desktop user gets seeded, and profile.d covers SSH and consoles.
winapps_wire_login_hooks() {
    info "Wiring the generator into login"

    winapps_install_file "$WINAPPS_PROFILE_D" 0644 <<WINAPPS_PROFILE_EOF
# Written by $PROGRAM_NAME.
#
# Generates this user's WinApps configuration from $WINAPPS_TEMPLATE.
# Backgrounded and silenced: a login must not wait on it or fail with it.
if [ -x "$WINAPPS_SEEDER" ]; then
    "$WINAPPS_SEEDER" >/dev/null 2>&1 || true
fi
WINAPPS_PROFILE_EOF

    winapps_install_file "$WINAPPS_AUTOSTART" 0644 <<WINAPPS_AUTOSTART_EOF
[Desktop Entry]
Type=Application
Name=WinApps user configuration
Comment=Generates this user's WinApps configuration from the system template
Exec=$WINAPPS_SEEDER
Terminal=false
NoDisplay=true
X-GNOME-Autostart-Phase=Initialization
OnlyShowIn=GNOME;KDE;XFCE;MATE;LXQt;Cinnamon;Budgie;COSMIC;Unity;
WINAPPS_AUTOSTART_EOF

    # /etc/skel is copied by pam_mkhomedir when a domain user's home is created,
    # which covers the very first login - before either hook above has had a
    # chance to run in a session that already has a desktop starting up.
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s seed %s from the template\n' "$C_CYAN" "$C_RESET" "$WINAPPS_SKEL_DIR"
    elif mkdir -p "$WINAPPS_SKEL_DIR" 2>/dev/null; then
        # Copied with the @WINAPPS_USER@ token still in it. The seeder replaces
        # the token on the user's first login; until then the file is inert
        # rather than wrong, which is the safer of the two failure modes.
        if cp -f "$WINAPPS_TEMPLATE" "$WINAPPS_SKEL_DIR/winapps.conf" 2>/dev/null; then
            chmod 600 "$WINAPPS_SKEL_DIR/winapps.conf"
            ok "$WINAPPS_SKEL_DIR/winapps.conf"
        fi
    fi
    return 0
}

# Seed every existing account now, so a machine that already has users logged
# in does not have to wait for the next login to pick the template up.
winapps_seed_all() {
    info "Generating the configuration for existing accounts"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s %s --all\n' "$C_CYAN" "$C_RESET" "$WINAPPS_SEEDER"
        return 0
    fi
    if "$WINAPPS_SEEDER" --all; then
        ok "Existing home directories seeded"
    else
        warn "Could not seed every home directory; they will be done at next login."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# --winapps-deploy - build the Windows guest (libvirt backend only)
# ---------------------------------------------------------------------------
# This is the one part of the WinApps step that touches Windows itself. It
# stands up an *unattended* Windows 11 Pro install with the virtio drivers,
# Remote Desktop and RemoteApp already switched on, so 'winapps' has something
# to connect to. It does nothing with Active Directory: joining the guest to
# the domain, and anything else inside Windows, is the operator's job.
#
# The work is done by a standalone script installed at $WINAPPS_VM_DEPLOYER so
# the VM can be rebuilt later without re-running this installer.
winapps_write_vm_deployer() {
    info "Installing the Windows VM builder ($WINAPPS_VM_DEPLOYER)"
    winapps_install_file "$WINAPPS_VM_DEPLOYER" 0755 <<'WINAPPS_VMDEPLOY_EOF'
#!/bin/bash
#
# winapps-vm-deploy - build a WinApps-ready Windows 11 Pro VM under libvirt/KVM.
#
# Written by domain-join-setup. Runs an unattended Windows install with the
# virtio drivers, Remote Desktop and RemoteApp enabled. It does NOTHING
# domain-related - join the guest to Active Directory yourself if you want it.
#
# Re-runnable: refuses when the guest already exists unless --force is given,
# which destroys the existing guest and its disk first.
#
#   Environment (all optional):
#     WA_VM_NAME   libvirt domain name           (default RDPWindows)
#     WA_VM_ADMIN  local administrator account   (default Docker)
#     WA_VM_PASS   local administrator password  (default: random, printed once)
#     WA_VM_RAM    guest RAM in MiB              (default 4096)
#     WA_VM_CPUS   guest vCPUs                   (default 4)
#     WA_VM_DISK   guest disk in GiB            (default 64)
#     WA_ISO       full path to a Windows 10/11 .iso file, filename included,
#                  not just its directory  (default: fetch with Mido)
#
set -u

VM_NAME="${WA_VM_NAME:-RDPWindows}"
VM_ADMIN="${WA_VM_ADMIN:-Docker}"
VM_PASS="${WA_VM_PASS:-}"
VM_RAM="${WA_VM_RAM:-4096}"
VM_CPUS="${WA_VM_CPUS:-4}"
VM_DISK="${WA_VM_DISK:-64}"
WIN_ISO="${WA_ISO:-}"
FORCE=0

CACHE="/var/lib/winapps/iso"
VIRTIO_ISO="$CACHE/virtio-win.iso"
STAGED_WIN_ISO=""      # the pool copy of the Windows ISO, re-mastered to boot without the CD prompt
SRC_WIN_ISO=""         # the operator's / cached / Mido-fetched source ISO before preparation
UNATTEND_ISO=""        # set once the answer disk is built
VIRTIO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
MIDO_URL="https://raw.githubusercontent.com/ElliotKillick/Mido/main/Mido.sh"
RDPAPPS_URL="https://raw.githubusercontent.com/winapps-org/winapps/main/oem/RDPApps.reg"
LIBVIRT_URI="qemu:///system"
POOL_DIR="/var/lib/libvirt/images"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

fetch() {   # <url> <dest>
    if command -v curl >/dev/null 2>&1; then
        curl -fL --proto '=https' --tlsv1.2 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --https-only -O "$2" "$1"
    else
        return 1
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force)   FORCE=1; shift ;;
        --iso)     WIN_ISO="${2:-}"; shift 2 ;;
        --name)    VM_NAME="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *)         die "unknown argument: $1" ;;
    esac
done

[ "$(id -u)" = "0" ] || die "must run as root."

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK" 2>/dev/null; }
trap cleanup EXIT INT TERM

# --- preflight --------------------------------------------------------------
for c in virt-install virsh qemu-img xorriso; do
    command -v "$c" >/dev/null 2>&1 || die "$c is not installed."
done
[ -e /dev/kvm ] || die "/dev/kvm is missing - enable VT-x/AMD-V in the firmware."
{ [ -r /dev/kvm ] && [ -w /dev/kvm ]; } || \
    warn "no read/write access to /dev/kvm - the guest may fail to start."
virsh -c "$LIBVIRT_URI" version >/dev/null 2>&1 || \
    die "cannot reach libvirt at $LIBVIRT_URI - is libvirtd running?"

_ovmf=""
for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
         /usr/share/qemu/ovmf-x86_64-code.bin; do
    [ -f "$f" ] && { _ovmf="$f"; break; }
done
[ -n "$_ovmf" ] || warn "no OVMF firmware found - 'virt-install --boot uefi' may fail. Install the OVMF/edk2 package."

if virsh -c "$LIBVIRT_URI" dominfo "$VM_NAME" >/dev/null 2>&1; then
    if [ "$FORCE" = "1" ]; then
        log "Removing the existing '$VM_NAME' guest (--force)."
        virsh -c "$LIBVIRT_URI" destroy "$VM_NAME" >/dev/null 2>&1 || true
        # Not --remove-all-storage: that would also delete a Windows ISO passed
        # by path. The system disk and the VM-named staged ISOs are removed by
        # name below instead.
        virsh -c "$LIBVIRT_URI" undefine --nvram "$VM_NAME" >/dev/null 2>&1 || true
        # The prepared '-install.iso' (+ its '.src' marker) is kept: it is a
        # re-mastered copy of the source ISO and the marker check below rebuilds
        # it when the source ISO changes.
        rm -f "$POOL_DIR/${VM_NAME}.qcow2" \
              "$POOL_DIR/${VM_NAME}-unattend.iso" 2>/dev/null || true
    else
        die "a libvirt guest named '$VM_NAME' already exists - re-run with --force to rebuild it."
    fi
fi

# Checked here, before the multi-GB ISO work, so a leftover disk fails fast.
# (A guest is not always defined when a disk is left behind - e.g. an earlier
# run that died between qemu-img and virt-install.)
if [ "$FORCE" != "1" ] && [ -f "$POOL_DIR/${VM_NAME}.qcow2" ]; then
    die "$POOL_DIR/${VM_NAME}.qcow2 already exists - re-run with --force to rebuild it."
fi

if virsh -c "$LIBVIRT_URI" net-info default >/dev/null 2>&1; then
    virsh -c "$LIBVIRT_URI" net-info default 2>/dev/null | grep -qi 'Active:.*yes' || {
        virsh -c "$LIBVIRT_URI" net-start default >/dev/null 2>&1 || true
    }
    virsh -c "$LIBVIRT_URI" net-autostart default >/dev/null 2>&1 || true
else
    warn "the libvirt 'default' network is not defined - the guest will have no network."
fi

mkdir -p "$CACHE" "$POOL_DIR"
# The QEMU process drops to an unprivileged user and cannot traverse a 0700
# home directory or read a root-only file, so everything it opens has to live
# somewhere world-traversable. /var/lib/winapps must therefore be 0755, not
# whatever root's umask produced.
chmod 0755 /var/lib/winapps "$CACHE" 2>/dev/null || true

# Which user QEMU runs as - 'qemu' on Fedora/RHEL, 'libvirt-qemu' on Debian/
# Ubuntu, or whatever qemu.conf overrides it to. Used to test whether a file is
# actually reachable before handing its path to libvirt.
QEMU_USER="$(sed -n 's/^[[:space:]]*user[[:space:]]*=[[:space:]]*"\?\([^"]*\)"\?.*/\1/p' \
             /etc/libvirt/qemu.conf 2>/dev/null | tail -1)"
[ -n "$QEMU_USER" ] || for u in qemu libvirt-qemu; do
    id "$u" >/dev/null 2>&1 && { QEMU_USER="$u"; break; }
done

# hyp_can_read <path> - true if the QEMU user can open this file for reading,
# path traversal included. Assumes yes if the user could not be determined.
hyp_can_read() {
    [ -n "$QEMU_USER" ] || return 0
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$QEMU_USER" -- test -r "$1" 2>/dev/null
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n -u "$QEMU_USER" test -r "$1" 2>/dev/null
    else
        return 0
    fi
}

# iso_efi_noprompt SRC DST
# Copy SRC to DST, then patch DST so the guest boots without the Windows
# install media's "Press any key to boot from CD or DVD..." prompt. That
# prompt hangs an unattended build: nothing is watching the console, so OVMF
# drops the CD after a few seconds and Setup never starts. ('virsh send-key'
# is not a reliable cure - the guest keyboard is not up that early.)
#
# Microsoft ships a prompt-free 'efisys_noprompt.bin' right next to the
# prompting 'efisys.bin', identical in size, and the El Torito UEFI entry
# points at that file's sectors. So we overwrite those sectors in place with
# the no-prompt image - no re-mastering, which keeps the UDF structure and
# any >4 GiB install.wim byte-for-byte intact. Returns non-zero on any
# problem; the caller then falls back to a plain copy.
iso_efi_noprompt() {
    local src="$1" dst="$2" d g nppath ppath np_sz p_sz start
    command -v xorriso >/dev/null 2>&1 || return 1
    command -v dd >/dev/null 2>&1 || return 1
    d="$(mktemp -d "$WORK/noprompt.XXXXXX")" || return 1

    # Locate both boot images by name, whatever case/tree xorriso reads them
    # from. report_lba prints "... , '<iso-path>'" as the last field.
    nppath=""; ppath=""
    for g in 'efisys_noprompt.bin' 'EFISYS_NOPROMPT.BIN' \
             'efisys_noprompt*' 'EFISYS_NOPROMPT*'; do
        nppath="$(xorriso -indev "$src" -find / -name "$g" -exec report_lba -- \
                    2>/dev/null | awk -F\' '/lba:/ {print $2; exit}')"
        [ -n "$nppath" ] && break
    done
    for g in 'efisys.bin' 'EFISYS.BIN'; do
        ppath="$(xorriso -indev "$src" -find / -name "$g" -exec report_lba -- \
                   2>/dev/null | awk -F\' '/lba:/ {print $2; exit}')"
        [ -n "$ppath" ] && break
    done
    { [ -n "$nppath" ] && [ -n "$ppath" ]; } || { rm -rf "$d"; return 1; }

    xorriso -osirrox on -indev "$src" -extract "$nppath" "$d/np.bin" >/dev/null 2>&1
    xorriso -osirrox on -indev "$src" -extract "$ppath"  "$d/p.bin"  >/dev/null 2>&1
    { [ -s "$d/np.bin" ] && [ -s "$d/p.bin" ]; } || { rm -rf "$d"; return 1; }

    np_sz=$(stat -c %s "$d/np.bin" 2>/dev/null || echo 0)
    p_sz=$(stat -c %s "$d/p.bin" 2>/dev/null || echo 0)
    # Same size means the sectors line up and 'dd' overwrites the extent exactly.
    [ "$np_sz" -gt 0 ] && [ "$np_sz" = "$p_sz" ] || { rm -rf "$d"; return 1; }

    # 2048-byte sector where efisys.bin starts in the image. On Microsoft media
    # the El Torito UEFI entry points at exactly this file's extent, so writing
    # the no-prompt image here is what OVMF ends up loading from the CD.
    #   report_lba: "File data lba:  <idx> , <start> , <blocks> , '<path>'"
    start=$(xorriso -indev "$src" -find "$ppath" -exec report_lba -- 2>/dev/null \
              | awk -F, '/data lba:/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
    case "$start" in ''|*[!0-9]*|0) rm -rf "$d"; return 1;; esac

    rm -f "$dst"
    cp --reflink=auto -f "$src" "$dst" 2>/dev/null || cp -f "$src" "$dst" \
        || { rm -rf "$d"; return 1; }

    dd if="$d/np.bin" of="$dst" bs=2048 seek="$start" conv=notrunc status=none 2>/dev/null \
        || { rm -rf "$d"; rm -f "$dst"; return 1; }

    # Verify the write landed on efisys.bin and nothing else: read that file
    # back out of the patched image and check it now equals the no-prompt one.
    # If it does not, the LBA was wrong and we may have corrupted the ISO -
    # throw the copy away so the caller falls back to a plain copy.
    xorriso -osirrox on -indev "$dst" -extract "$ppath" "$d/check.bin" >/dev/null 2>&1
    if cmp -s "$d/np.bin" "$d/check.bin"; then
        rm -rf "$d"; return 0
    fi
    rm -rf "$d"; rm -f "$dst"; return 1
}

# --- Windows ISO -----------------------------------------------------------
SRC_WIN_ISO=""
if [ -n "$WIN_ISO" ]; then
    [ -d "$WIN_ISO" ] && die "the ISO path is a directory ($WIN_ISO) - give the full path to the .iso file, filename included."
    [ -f "$WIN_ISO" ] || die "Windows ISO not found: $WIN_ISO (pass the full path including the .iso filename)"
    SRC_WIN_ISO="$WIN_ISO"
    log "Using Windows ISO: $WIN_ISO"
elif [ -f "$POOL_DIR/${VM_NAME}-install.iso" ]; then
    # A previous run left its ISO here. Reuse it rather than falling back to a
    # fresh (and often broken) Mido download. The prepare step below is skipped
    # ('.src' marker present) or re-runs against this copy as its own source.
    if [ -f "$POOL_DIR/${VM_NAME}-install.iso.src" ]; then
        WIN_ISO="$POOL_DIR/${VM_NAME}-install.iso"
        log "Reusing the prepared Windows ISO: $WIN_ISO"
    else
        _stale="$POOL_DIR/${VM_NAME}-install.stale.iso"
        mv -f "$POOL_DIR/${VM_NAME}-install.iso" "$_stale" \
            && SRC_WIN_ISO="$_stale" \
            || die "could not move the stale staged ISO aside."
        log "Re-preparing the previously staged Windows ISO."
    fi
else
    SRC_WIN_ISO="$CACHE/windows.iso"
    if [ -f "$SRC_WIN_ISO" ]; then
        log "Using cached Windows ISO: $SRC_WIN_ISO"
    else
        log "No ISO given - fetching Windows 11 with Mido (from Microsoft's own servers)."
        warn "Mido drives Microsoft's download API and can break without notice."
        warn "If it fails, fetch a Windows 10/11 ISO yourself and re-run with --iso PATH."
        _mido="$CACHE/Mido.sh"
        fetch "$MIDO_URL" "$_mido" || die "could not download Mido."
        chmod +x "$_mido"
        ( cd "$CACHE" && "$_mido" win11x64 ) || die "Mido could not fetch the Windows ISO."
        if [ -f "$CACHE/win11x64.iso" ]; then
            mv -f "$CACHE/win11x64.iso" "$SRC_WIN_ISO"
        else
            _got=$(ls -1t "$CACHE"/*.iso 2>/dev/null | grep -v virtio | head -1)
            [ -n "$_got" ] && mv -f "$_got" "$SRC_WIN_ISO" || die "Mido finished but produced no ISO."
        fi
    fi
fi

# --- virtio-win ISO ------------------------------------------------------
if [ -f "$VIRTIO_ISO" ]; then
    log "Using cached virtio-win ISO."
else
    log "Downloading the virtio-win driver ISO."
    fetch "$VIRTIO_URL" "$VIRTIO_ISO" || die "could not download virtio-win.iso."
fi

# --- build the unattended answer disk ----------------------------------
WORK="$(mktemp -d /var/tmp/winapps-deploy.XXXXXX)" || die "could not create a work directory."
ISO_ROOT="$WORK/iso"
DRV="$ISO_ROOT/\$WinPEDriver\$"
mkdir -p "$DRV" "$ISO_ROOT/oem"

# --- prepare the Windows ISO (strip the "press any key" CD boot prompt) ---
# Always work on a copy in the pool: the operator's original ISO is never
# touched and the QEMU user can always read what is under $POOL_DIR.
# NOPROMPT_OK=1 once the staged ISO is known to boot without the CD prompt.
NOPROMPT_OK=0
if [ -n "$SRC_WIN_ISO" ]; then
    [ -f "$SRC_WIN_ISO" ] || die "Windows ISO vanished: $SRC_WIN_ISO"
    STAGED_WIN_ISO="$POOL_DIR/${VM_NAME}-install.iso"
    _mk="$STAGED_WIN_ISO.src"
    _src_sz=$(stat -c %s "$SRC_WIN_ISO" 2>/dev/null || echo 0)
    [ "$SRC_WIN_ISO" = "$STAGED_WIN_ISO" ] && die "internal: source and staged ISO path collide."
    if [ "$_src_sz" -gt 0 ] && [ -f "$STAGED_WIN_ISO" ] && \
       [ "$(cut -d' ' -f1 "$_mk" 2>/dev/null)" = "$_src_sz" ]; then
        log "Reusing the prepared Windows ISO at $STAGED_WIN_ISO"
        [ "$(cut -d' ' -f2 "$_mk" 2>/dev/null)" = "noprompt" ] && NOPROMPT_OK=1
    else
        rm -f "$STAGED_WIN_ISO" "$_mk"
        log "Preparing the Windows ISO for an unattended boot."
        log "(makes a copy in $POOL_DIR without the 'press any key' CD prompt - a"
        log " few minutes, once per source ISO)"
        _mode=plain
        if iso_efi_noprompt "$SRC_WIN_ISO" "$STAGED_WIN_ISO"; then
            NOPROMPT_OK=1; _mode=noprompt
        else
            warn "could not remove the CD boot prompt from this ISO - using a plain copy."
            warn "Watch the first boot in virt-viewer and press a key at the"
            warn "'Press any key to boot from CD or DVD...' prompt if it appears."
            cp --reflink=auto -f "$SRC_WIN_ISO" "$STAGED_WIN_ISO" 2>/dev/null \
                || cp -f "$SRC_WIN_ISO" "$STAGED_WIN_ISO" \
                || die "could not stage the Windows ISO into $POOL_DIR."
        fi
        chmod 0644 "$STAGED_WIN_ISO"
        printf '%s %s\n' "$_src_sz" "$_mode" > "$_mk"
        [ -n "${_stale:-}" ] && rm -f "$_stale"
    fi
    WIN_ISO="$STAGED_WIN_ISO"
fi
[ -f "$WIN_ISO" ] || die "no Windows ISO to install from."
hyp_can_read "$WIN_ISO" || warn "the prepared ISO ($WIN_ISO) may not be readable by the '$QEMU_USER' user."

# Stage the boot-critical virtio drivers where Windows Setup auto-loads them
# (a folder named $WinPEDriver$ at the root of the attached media). Pulled
# straight out of the virtio ISO with xorriso, so no loop mount is needed.
#
# Keep this list MINIMAL. Windows 11 24H2/25H2 Setup aborts early with
# "0xD000A000 - 0x40031" (or "0x80070103 - 0x40031") when a $WinPEDriver$
# INF matches a driver WinPE already has loaded - the extra QEMU/virtio
# INFs (Balloon, vioserial, qemufwcfg, qemupciserial, pvpanic, smbus,
# vioscsi when there is no SCSI controller) each trip that. Only what is
# needed to see the virtio-blk system disk (viostor) and the NIC during
# OOBE (NetKVM) goes in here; virtio-win-guest-tools.exe installs the full
# set on first boot (see setup.ps1).
_staged=0
for d in viostor NetKVM; do
    for a in w11 w10; do
        if xorriso -osirrox on -indev "$VIRTIO_ISO" \
             -extract "/$d/$a/amd64" "$DRV/$d" >/dev/null 2>&1; then
            if [ -n "$(ls -A "$DRV/$d" 2>/dev/null)" ]; then _staged=$((_staged+1)); break; fi
        fi
        rm -rf "$DRV/$d" 2>/dev/null
    done
done
[ "$_staged" -gt 0 ] || warn "no virtio drivers were staged - if Setup shows no disks, click 'Load driver' and point it at the virtio CD."

fetch "$RDPAPPS_URL" "$ISO_ROOT/oem/RDPApps.reg" || \
    warn "could not download RDPApps.reg - RemoteApp will need enabling inside Windows by hand."

if [ -z "$VM_PASS" ]; then
    VM_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18)Aa1!"
    PASS_GENERATED=1
else
    PASS_GENERATED=0
fi

xesc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
X_ADMIN="$(xesc "$VM_ADMIN")"
X_PASS="$(xesc "$VM_PASS")"

cat > "$ISO_ROOT/Autounattend.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
            <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
            <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows 11 Pro</Value></MetaData>
          </InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData>
        <ProductKey><Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key><WillShowUI>OnError</WillShowUI></ProductKey>
        <AcceptEula>true</AcceptEula>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" language="neutral" versionScope="nonSxS">
      <ComputerName>*</ComputerName>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" language="neutral" versionScope="nonSxS">
      <InputLocale>0409:00000409</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$X_ADMIN</Name>
            <Group>Administrators</Group>
            <DisplayName>$X_ADMIN</DisplayName>
            <Password><Value>$X_PASS</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Username>$X_ADMIN</Username>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Password><Value>$X_PASS</Value><PlainText>true</PlainText></Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd /c "for %i in (D E F G H I J K) do @if exist %i:\oem\setup.cmd call %i:\oem\setup.cmd %i:"</CommandLine>
          <Description>WinApps first-boot setup</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
XML

cat > "$ISO_ROOT/oem/setup.cmd" <<'CMD'
@echo off
set "SRC=%~1"
if "%SRC%"=="" set "SRC=%~d0"
if exist "%SRC%\oem\RDPApps.reg" reg import "%SRC%\oem\RDPApps.reg"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC%\oem\setup.ps1" > "%SystemDrive%\winapps-deploy.log" 2>&1
exit /b 0
CMD

cat > "$ISO_ROOT/oem/setup.ps1" <<'PS1'
$ErrorActionPreference = 'Continue'

# Remote Desktop on, firewall group opened.
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
try { Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' } catch {}

# A suspended guest cannot answer RDP - disable every idle timeout.
powercfg /setactive SCHEME_MIN 2>$null
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0
powercfg /hibernate off 2>$null

# Treat the LAN as private so sharing and discovery work.
try { Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private } catch {}

# RemoteApp: allow any program to be launched (WinApps needs this).
$rail = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList'
New-Item -Path $rail -Force | Out-Null
Set-ItemProperty -Path $rail -Name fDisabledAllowList -Value 1

# virtio guest tools + QEMU guest agent, from whichever CD carries them.
$vt = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' |
      Where-Object { Test-Path (Join-Path $_.DeviceID 'virtio-win-guest-tools.exe') } |
      Select-Object -First 1
if ($vt) {
    Start-Process (Join-Path $vt.DeviceID 'virtio-win-guest-tools.exe') `
        -ArgumentList '/quiet','/norestart' -Wait
}

shutdown /r /t 5 /c "WinApps deploy: first-boot configuration complete"
PS1

# Written into the libvirt pool, not the 0700 work directory: the QEMU user
# has to be able to read it once it is attached as a CD.
UNATTEND_ISO="$POOL_DIR/${VM_NAME}-unattend.iso"
xorriso -as mkisofs -quiet -J -r -V WAUNATTEND \
    -o "$UNATTEND_ISO" "$ISO_ROOT" || die "could not build the unattend ISO."
chmod 0644 "$UNATTEND_ISO"

# --- create the guest ------------------------------------------------------
DISK_PATH="$POOL_DIR/${VM_NAME}.qcow2"
if [ -f "$DISK_PATH" ]; then
    [ "$FORCE" = "1" ] && rm -f "$DISK_PATH" || die "$DISK_PATH already exists - use --force."
fi
qemu-img create -f qcow2 "$DISK_PATH" "${VM_DISK}G" >/dev/null || die "could not create the system disk."

log "Defining and starting '$VM_NAME' (${VM_RAM} MiB RAM, ${VM_CPUS} vCPU, ${VM_DISK} GiB disk)."
virt-install \
    --connect "$LIBVIRT_URI" \
    --name "$VM_NAME" \
    --os-variant win11 \
    --memory "$VM_RAM" \
    --vcpus "$VM_CPUS" \
    --cpu host-passthrough \
    --machine q35 \
    --boot uefi \
    --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
    --disk "path=$DISK_PATH,bus=virtio,format=qcow2,boot.order=1" \
    --disk "path=$WIN_ISO,device=cdrom,boot.order=2" \
    --disk "path=$VIRTIO_ISO,device=cdrom" \
    --disk "path=$UNATTEND_ISO,device=cdrom" \
    --network network=default,model=virtio \
    --graphics spice \
    --video qxl \
    --sound default \
    --noautoconsole \
    --wait 0 \
    || {
        # virt-install may have defined the domain before the start failed.
        # Tear the half-built guest down so a plain re-run works without --force.
        virsh -c "$LIBVIRT_URI" destroy "$VM_NAME" >/dev/null 2>&1 || true
        virsh -c "$LIBVIRT_URI" undefine --nvram "$VM_NAME" >/dev/null 2>&1 || true
        rm -f "$DISK_PATH"
        die "virt-install failed."
    }

virsh -c "$LIBVIRT_URI" autostart "$VM_NAME" >/dev/null 2>&1 || true

# Belt and braces for the CD boot prompt. The install ISO is patched to boot
# straight through (see iso_efi_noprompt), but in case that did not take on
# this media, also tap a key every couple of seconds for the first few
# minutes: on the first boot the empty system disk (boot.order=1) fails and
# OVMF falls through to the CD, which otherwise stops at "Press any key to
# boot from CD or DVD...". 'send-key' is unreliable that early in firmware,
# hence the ISO patch is the real fix - but the extra keystrokes are free
# insurance and harmless once Setup (driven by Autounattend.xml) is running.
# After install the disk boots directly and none of this fires again.
(
    sleep 5
    for _ in $(seq 1 150); do
        virsh -c "$LIBVIRT_URI" send-key "$VM_NAME" KEY_ENTER >/dev/null 2>&1
        sleep 2
    done
) >/dev/null 2>&1 &

echo ""
echo "  ---------------------------------------------------------------------------"
echo "  The Windows guest '$VM_NAME' is installing."
echo ""
echo "    Watch it:   virt-viewer --connect $LIBVIRT_URI $VM_NAME"
echo ""
if [ "${NOPROMPT_OK:-0}" != "1" ]; then
echo "  NOTE: the CD boot prompt could not be removed from this ISO. If the"
echo "  first boot stops at 'Press any key to boot from CD or DVD...', open"
echo "  the viewer above and press a key. (A key is also sent automatically,"
echo "  but that can miss the ~5-second window.)"
echo ""
fi
echo "  The install is unattended and reboots itself a few times. Give it"
echo "  20-45 minutes to settle on the desktop."
echo ""
echo "    Local administrator : $VM_ADMIN"
if [ "$PASS_GENERATED" = "1" ]; then
echo "    Password (generated): $VM_PASS"
echo "                          ^ shown once - write it down now."
else
echo "    Password             : (the one you supplied)"
fi
echo ""
echo "  When Windows is up and reachable over RDP, scan it for installed"
echo "  programs and create the launchers:"
echo ""
echo "    sudo /etc/winapps/setup.sh --system"
echo ""
echo "  Re-run that same command any time you install or remove a program in"
echo "  Windows, to refresh the launchers."
echo ""
echo "  This guest is NOT domain-joined - do that from inside Windows if you"
echo "  want AD logins and network shares."
echo "  ---------------------------------------------------------------------------"
echo ""
WINAPPS_VMDEPLOY_EOF
}

# Collect the guest parameters and run the deployer. libvirt backend only.
winapps_deploy_vm() {
    local ram="${OPT_WINAPPS_VM_RAM:-4096}" cpus="${OPT_WINAPPS_VM_CPUS:-4}"
    local disk="${OPT_WINAPPS_VM_DISK:-64}" iso="$OPT_WINAPPS_ISO"
    local vm="${OPT_WINAPPS_VM:-RDPWindows}"

    if [[ -z "$iso" && $ASSUME_YES -ne 1 ]]; then
        printf '\n'
        note "A Windows 10/11 ISO is needed. Give the full path *including the"
        note ".iso filename*, e.g. /srv/iso/Win11_24H2_English_x64.iso - not just"
        note "the directory. Leave it blank to let Mido fetch Windows 11 from"
        note "Microsoft (a local ISO is more reliable)."
        while : ; do
            ask_value iso "Path to the Windows ISO file" ""
            [[ -z "$iso" ]] && break                       # blank = use Mido
            if [[ -d "$iso" ]]; then
                err "That is a directory. Add the .iso filename to the path."
                iso=""; continue
            fi
            [[ -f "$iso" ]] && break
            err "No such file: $iso"
            iso=""
        done
    fi
    # Non-interactive, or a path supplied on the command line: no re-prompt.
    if [[ -n "$iso" ]]; then
        if [[ -d "$iso" ]]; then
            err "--winapps-iso is a directory: $iso"
            note "Point it at the .iso file itself, filename included."
            return 1
        fi
        if [[ ! -f "$iso" ]]; then
            err "No such file: $iso"
            return 1
        fi
    fi
    if [[ $ASSUME_YES -ne 1 ]]; then
        ask_value ram  "Guest RAM (MiB)"  "$ram"
        ask_value cpus "Guest vCPUs"      "$cpus"
        ask_value disk "Guest disk (GiB)" "$disk"
    fi

    info "Deploying the Windows guest '$vm'"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s %s %s\n' "$C_CYAN" "$C_RESET" "$WINAPPS_VM_DEPLOYER" \
            "${iso:+--iso $iso}"
        return 0
    fi

    WA_VM_NAME="$vm" WA_VM_RAM="$ram" WA_VM_CPUS="$cpus" WA_VM_DISK="$disk" \
    WA_VM_PASS="$OPT_WINAPPS_VM_PASS" WA_ISO="$iso" \
        "$WINAPPS_VM_DEPLOYER" || {
        err "The Windows guest could not be deployed."
        note "Fix the problem above, then re-run (--force clears the half-built guest):"
        printf '    %ssudo %s --force --name %s%s%s\n' "$C_CYAN" "$WINAPPS_VM_DEPLOYER" \
            "$vm" "${iso:+ --iso $iso}" "$C_RESET"
        return 1
    }
    WINAPPS_VM_DEPLOYED=1
    return 0
}

# Run the upstream installer with --system, which is what puts the launchers in
# /usr/share/applications for every account.
#
# It cannot be run blind: the installer connects to Windows and enumerates the
# installed programs, so Windows has to be up, reachable over RDP and - for this
# to be worth anything - already joined to the domain. When it is not, the
# groundwork is left in place and the command is printed for later.
winapps_install_upstream() {
    local installer="$WINAPPS_ETC_DIR/setup.sh" rc=0

    if ! confirm "Is the Windows side already installed, domain-joined and reachable over RDP?" "n"; then
        printf '\n'
        note "Leaving the WinApps launchers for later - Windows has to be up first."
        note "Once it is, run:"
        printf '    %ssudo %s --system%s\n' "$C_CYAN" "$installer" "$C_RESET"
        return 0
    fi

    info "Fetching the WinApps installer"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s  [dry-run]%s download %s to %s\n' \
            "$C_CYAN" "$C_RESET" "$WINAPPS_UPSTREAM_URL" "$installer"
        printf '%s  [dry-run]%s %s --system\n' "$C_CYAN" "$C_RESET" "$installer"
        return 0
    fi

    mkdir -p "$WINAPPS_ETC_DIR" || { err "Could not create $WINAPPS_ETC_DIR."; return 1; }
    if ! fetch_url "$WINAPPS_UPSTREAM_URL" "$installer"; then
        err "Could not download the WinApps installer."
        note "The rest of the configuration is in place; re-run this step when the"
        note "network allows, or install WinApps by hand with --system."
        return 1
    fi
    chmod 0755 "$installer"

    # The installer reads its config from $HOME, and $HOME here is root's. Seed
    # root from the same template so the app scan has something to connect with.
    if [[ -n "${HOME:-}" && -r "$WINAPPS_TEMPLATE" ]]; then
        "$WINAPPS_SEEDER" >/dev/null 2>&1 || true
        if [[ ! -f "$HOME/.config/winapps/winapps.conf" ]]; then
            mkdir -p "$HOME/.config/winapps"
            sed "s/@WINAPPS_USER@/${OPT_WINAPPS_RDP_USER:-Administrator}/g" \
                "$WINAPPS_TEMPLATE" >"$HOME/.config/winapps/winapps.conf"
            chmod 600 "$HOME/.config/winapps/winapps.conf"
        fi
    fi

    info "Running the WinApps installer (system-wide)"
    run "$installer" --system || rc=$?
    if (( rc != 0 )); then
        warn "The WinApps installer exited non-zero; the launchers may be incomplete."
        note "Re-run it once Windows is reachable:  sudo $installer --system"
        return 1
    fi
    ok "WinApps launchers installed in /usr/share/applications"
    return 0
}

# Take the multi-user wiring back out. Deliberately leaves the per-user configs
# and the launchers alone - those belong to the upstream installer's --uninstall
# and to the users themselves.
winapps_remove() {
    heading "Remove the WinApps multi-user configuration"

    local f
    for f in "$WINAPPS_PROFILE_D" "$WINAPPS_AUTOSTART" "$WINAPPS_SEEDER" \
             "$WINAPPS_ASKPASS" "$WINAPPS_TEMPLATE" "$WINAPPS_VM_DEPLOYER" \
             "$WINAPPS_SKEL_DIR/winapps.conf"; do
        if [[ -e "$f" ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                printf '%s  [dry-run]%s remove %s\n' "$C_CYAN" "$C_RESET" "$f"
            else
                backup_file "$f" "$OUT_OF_TREE_BACKUP_DIR"
                rm -f "$f" && ok "Removed $f"
            fi
        fi
    done

    # The Windows guest is only torn down when explicitly asked - its disk holds
    # a full Windows install and whatever was saved inside it.
    local vm="${OPT_WINAPPS_VM:-RDPWindows}"
    if have virsh && virsh -c qemu:///system dominfo "$vm" >/dev/null 2>&1; then
        printf '\n'
        if (( WINAPPS_VM_REMOVE )) || { [[ $DRY_RUN -ne 1 ]] && \
             confirm "Also destroy the libvirt guest '$vm' and its disk? This cannot be undone." "n"; }; then
            if [[ $DRY_RUN -eq 1 ]]; then
                printf '%s  [dry-run]%s virsh undefine --nvram --remove-all-storage %s\n' \
                    "$C_CYAN" "$C_RESET" "$vm"
            else
                virsh -c qemu:///system destroy "$vm" >/dev/null 2>&1 || true
                if virsh -c qemu:///system undefine --nvram --remove-all-storage "$vm" >/dev/null 2>&1 \
                   || virsh -c qemu:///system undefine --nvram "$vm" >/dev/null 2>&1; then
                    ok "Removed the libvirt guest '$vm'"
                else
                    warn "Could not remove the guest '$vm'; do it by hand with virsh."
                fi
            fi
        else
            note "Left the libvirt guest '$vm' in place."
        fi
    fi

    printf '\n'
    note "Left in place on purpose:"
    note "  - each user's ~/.config/winapps/winapps.conf"
    note "  - the launchers in /usr/share/applications"
    note "  - the cached ISOs in $WINAPPS_ISO_CACHE"
    note "To remove those too:  sudo $WINAPPS_ETC_DIR/setup.sh --uninstall"
    return 0
}

winapps_print_summary() {
    local freerdp
    freerdp="$(winapps_freerdp_cmd)" || freerdp=""

    heading "WinApps summary"
    printf '  Backend        : %s%s%s\n' "$C_BOLD" "$OPT_WINAPPS_BACKEND" "$C_RESET"
    printf '  Credentials    : %s%s%s\n' "$C_BOLD" "$OPT_WINAPPS_CREDS" "$C_RESET"
    printf '  RDP domain     : %s\n' "${OPT_WINAPPS_DOMAIN:-<none>}"
    case "$OPT_WINAPPS_BACKEND" in
        manual) printf '  Windows host   : %s:%s\n' "${OPT_WINAPPS_HOST:-?}" "${OPT_WINAPPS_PORT:-3389}" ;;
        libvirt) printf '  libvirt VM     : %s%s\n' "${OPT_WINAPPS_VM:-RDPWindows}" \
                     "$( (( WINAPPS_VM_DEPLOYED )) && printf ' (installing now)' )" ;;
    esac
    if [[ -n "$freerdp" ]]; then
        printf '  FreeRDP        : %s\n' "$freerdp"
    else
        printf '  FreeRDP        : %snot found%s\n' "$C_YELLOW" "$C_RESET"
    fi
    printf '  Template       : %s\n' "$WINAPPS_TEMPLATE"

    printf '\n'
    printf '  %sHow this works for a domain user:%s\n' "$C_BOLD" "$C_RESET"
    printf '  They log in, the generator writes their own ~/.config/winapps/winapps.conf\n'
    printf '  with their account name in RDP_USER, and the Windows launchers in the\n'
    printf '  application menu open under their own Windows profile.\n'

    printf '\n'
    printf '  %sTo change the settings for everyone:%s\n' "$C_BOLD" "$C_RESET"
    printf '    %ssudo nano %s%s\n' "$C_CYAN" "$WINAPPS_TEMPLATE" "$C_RESET"
    printf '    %ssudo %s --all%s\n' "$C_CYAN" "$WINAPPS_SEEDER" "$C_RESET"
    printf '\n'
    printf '  %sTo scan (or re-scan) Windows for programs and refresh the launchers:%s\n' "$C_BOLD" "$C_RESET"
    printf '    %ssudo %s/setup.sh --system%s\n' "$C_CYAN" "$WINAPPS_ETC_DIR" "$C_RESET"
    printf '    Run it after the first install, and again whenever a program is\n'
    printf '    added to or removed from Windows.\n'

    if [[ "$OPT_WINAPPS_BACKEND" == "libvirt" && -x "$WINAPPS_VM_DEPLOYER" ]]; then
        printf '\n'
        printf '  %sTo build or rebuild the Windows VM:%s\n' "$C_BOLD" "$C_RESET"
        printf '    %ssudo %s%s            %s(--force to replace an existing one)%s\n' \
            "$C_CYAN" "$WINAPPS_VM_DEPLOYER" "$C_RESET" "$C_DIM" "$C_RESET"
    fi
    return 0
}

# The whole WinApps step.
configure_winapps() {
    heading "WinApps - Windows applications for every domain user"

    (( WINAPPS_REMOVE )) && { winapps_remove; return $?; }

    wrap_text "  " "WinApps makes individual Windows programs appear as ordinary entries in this machine's application menu, launched over RDP. Installed system-wide the launchers are shared by every account, and this step adds what upstream leaves out: a per-user configuration generated at login, so each domain user reaches Windows as themselves."
    printf '\n'

    # --- Choices ------------------------------------------------------------
    [[ -z "$OPT_WINAPPS_BACKEND" ]] && winapps_choose_backend
    if [[ ! "$OPT_WINAPPS_BACKEND" =~ ^(libvirt|docker|podman|manual)$ ]]; then
        err "Invalid WinApps backend '$OPT_WINAPPS_BACKEND'."
        return 1
    fi

    [[ -z "$OPT_WINAPPS_CREDS" ]] && winapps_choose_creds
    if [[ ! "$OPT_WINAPPS_CREDS" =~ ^(askpass|kerberos|shared)$ ]]; then
        err "Invalid WinApps credential mode '$OPT_WINAPPS_CREDS'."
        return 1
    fi

    if [[ -z "$OPT_WINAPPS_DOMAIN" ]]; then
        OPT_WINAPPS_DOMAIN="$(winapps_default_domain)"
        if [[ -z "$OPT_WINAPPS_DOMAIN" ]]; then
            warn "This machine does not look domain-joined yet."
            note "RDP_DOMAIN is being left blank; set it in the template once joined."
        else
            ask_value OPT_WINAPPS_DOMAIN "Active Directory domain for the RDP session" "$OPT_WINAPPS_DOMAIN"
        fi
    fi

    if [[ "$OPT_WINAPPS_BACKEND" == "manual" && -z "$OPT_WINAPPS_HOST" ]]; then
        ask_value OPT_WINAPPS_HOST "Address of the Windows host (hostname or IP)" ""
        if [[ -z "$OPT_WINAPPS_HOST" ]]; then
            err "The 'manual' backend needs an address to connect to."
            return 1
        fi
    fi
    [[ "$OPT_WINAPPS_BACKEND" == "libvirt" && -z "$OPT_WINAPPS_VM" ]] && \
        ask_value OPT_WINAPPS_VM "libvirt VM name" "RDPWindows"

    if [[ "$OPT_WINAPPS_CREDS" == "shared" ]]; then
        warn "Every user will connect to Windows as the same account."
        note "Their AD identity will not reach Windows, so profiles and mapped"
        note "drives will be shared rather than per-user."
        [[ -z "$OPT_WINAPPS_RDP_USER" ]] && \
            ask_value OPT_WINAPPS_RDP_USER "Windows service account" ""
        [[ -z "$OPT_WINAPPS_RDP_PASS" ]] && \
            ask_secret OPT_WINAPPS_RDP_PASS "Password for $OPT_WINAPPS_RDP_USER"
        if [[ -z "$OPT_WINAPPS_RDP_USER" || -z "$OPT_WINAPPS_RDP_PASS" ]]; then
            err "Shared-credential mode needs both an account and a password."
            return 1
        fi
    fi

    # --- Packages -----------------------------------------------------------
    local -a pkgs=() add=()
    read -r -a pkgs <<<"$(pkgs_for extra_winapps)"
    if [[ "$OPT_WINAPPS_BACKEND" != "manual" ]]; then
        local group_pkgs
        group_pkgs="$(pkgs_for "winapps_${OPT_WINAPPS_BACKEND}")"
        [[ -n "$group_pkgs" ]] && { read -r -a add <<<"$group_pkgs"; pkgs+=("${add[@]}"); }
    fi

    refresh_repos
    filter_available "${pkgs[@]}"
    if [[ ${#SKIPPED_PACKAGES[@]} -gt 0 ]]; then
        warn "Not available on this system: ${SKIPPED_PACKAGES[*]}"
        note "Docker in particular is often only in the vendor's own repository."
    fi
    if [[ ${#AVAILABLE_PACKAGES[@]} -gt 0 ]]; then
        printf '\n'
        info "Packages: ${AVAILABLE_PACKAGES[*]}"
        if confirm "Install these?" "y"; then
            install_packages "${AVAILABLE_PACKAGES[@]}" || {
                err "Package installation failed; stopping before anything is written."
                return 1
            }
        else
            note "Skipping the package install; the configuration is still written."
        fi
    fi

    # --- The configuration --------------------------------------------------
    printf '\n'
    winapps_write_askpass || return 1
    winapps_write_template "$OPT_WINAPPS_DOMAIN" "$OPT_WINAPPS_BACKEND" \
        "$OPT_WINAPPS_CREDS" "$OPT_WINAPPS_HOST" "$OPT_WINAPPS_PORT" \
        "$OPT_WINAPPS_VM" || return 1
    winapps_write_seeder || return 1
    winapps_wire_login_hooks || return 1
    winapps_seed_all

    # --- Backend services ---------------------------------------------------
    case "$OPT_WINAPPS_BACKEND" in
        libvirt) enable_service libvirtd.service ;;
        docker)  enable_service docker.service ;;
        podman)  enable_service podman.socket ;;
    esac

    # --- Build the Windows guest (libvirt backend only) --------------------
    if [[ "$OPT_WINAPPS_BACKEND" == "libvirt" ]]; then
        local do_deploy=0
        case "$OPT_WINAPPS_DEPLOY" in
            1) do_deploy=1 ;;
            0) do_deploy=0 ;;
            *) [[ $ASSUME_YES -ne 1 ]] \
                 && confirm "Build the Windows 11 VM now with virt-install (unattended, ~20-45 min)?" "n" \
                 && do_deploy=1 ;;
        esac

        if (( do_deploy )); then
            printf '\n'
            local -a dep_pkgs=()
            read -r -a dep_pkgs <<<"$(pkgs_for winapps_deploy)"
            if [[ ${#dep_pkgs[@]} -gt 0 ]]; then
                filter_available "${dep_pkgs[@]}"
                if [[ ${#AVAILABLE_PACKAGES[@]} -gt 0 ]]; then
                    info "Deploy dependencies: ${AVAILABLE_PACKAGES[*]}"
                    install_packages "${AVAILABLE_PACKAGES[@]}" \
                        || warn "Some deploy dependencies did not install; virt-install may fail."
                fi
                [[ ${#SKIPPED_PACKAGES[@]} -gt 0 ]] && \
                    warn "Not available here: ${SKIPPED_PACKAGES[*]}"
            fi
            winapps_write_vm_deployer || return 1
            winapps_deploy_vm || true
        else
            winapps_write_vm_deployer || true
            note "Skipping the VM build. When you want it:  sudo $WINAPPS_VM_DEPLOYER"
        fi
    fi

    if ! winapps_freerdp_cmd >/dev/null; then
        printf '\n'
        warn "No FreeRDP command was found on this system."
        note "WinApps launchers cannot connect without it. Install FreeRDP 3 and"
        note "re-run this step, or set FREERDP_COMMAND in $WINAPPS_TEMPLATE."
    fi

    # --- Launchers ----------------------------------------------------------
    printf '\n'
    winapps_install_upstream || true

    WINAPPS_CONFIGURED=1
    printf '\n'
    winapps_print_summary
    return 0
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
    entries+=("winapps|Windows applications for every domain user|Installs WinApps so Windows programs appear in the Linux application menu and open over RDP. The launchers are installed system-wide and each domain user's configuration is generated at login with their own account name, so everyone reaches their own Windows profile. Needs a Windows VM on this machine or a Remote Desktop host on the network.")

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
WANT_WINAPPS=0

build_package_list() {
    local -a wanted=() add=()
    local choice group_pkgs

    WANTED_PACKAGES=()
    WANT_MKHOMEDIR=0
    WANT_TIMESYNC=0
    WANT_DUO=0
    WANT_WINAPPS=0

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
            # Same reasoning as Duo: which backend packages are needed depends
            # on answers configure_winapps has not asked for yet, so it does its
            # own install rather than joining this preview.
            winapps)      WANT_WINAPPS=1 ;;
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

    # Named on the command line rather than reached through the join, so it has
    # to run whether or not this pass joined anything. A join already ran it,
    # and the guard inside makes this second call a no-op.
    if [[ -n "$OPT_SUDO_USER" || -n "$OPT_SUDO_GROUP" ]]; then
        configure_sudo_access
    fi

    # WinApps reads the joined realm for RDP_DOMAIN, so it runs after the join
    # but before Duo - it is ordinary desktop plumbing and cannot lock anyone out.
    local winapps_now=$WANT_WINAPPS
    (( OPT_WINAPPS == 1 )) && winapps_now=1
    (( OPT_WINAPPS == 0 )) && winapps_now=0
    (( winapps_now == 1 )) && configure_winapps

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

action_sudo_access() {
    configure_sudo_access
}

action_duo() {
    configure_duo
}

action_winapps() {
    configure_winapps
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

# The entries fill a two-column grid, left column first. An even number of
# entries splits evenly (here 6 and 6); an odd number leaves one over, drawn as
# a full-width row centred underneath both columns. MENU_LEFT_COUNT and
# MENU_RIGHT_COUNT below say where the split falls - keep their sum equal to the
# entry count for an even list, or one short of it for an odd list.
MENU_NAMES=(
    "Guided setup"
    "Install packages only"
    "Graphical management tools"
    "Join an Active Directory domain"
    "Home directories on first login"
    "Network time synchronisation"
    "SDDM login screen"
    "Post-join login settings"
    "Grant sudo to a user or group"
    "Duo two-factor authentication"
    "Windows apps for every user"
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
    "Short usernames, who is allowed to log in, and then the sudo rights"
    "Give an account or a group sudo through its own /etc/sudoers.d file"
    "Second factor for local and domain logins via Duo Unix, or remove it"
    "Windows programs in the app menu, configured per domain user via WinApps"
    "Read-only: hostname, clock, DNS, membership and service state"
)

MENU_LEFT_COUNT=6
MENU_RIGHT_COUNT=6
MENU_TOTAL=12
MENU_CURSOR=0
MENU_SELECTED=(0 0 0 0 0 0 0 0 0 0 0 0)

# The order selections run in: install first, then configure, then join, then
# the settings that only make sense once the machine is a domain member - and
# Duo last of all, since it is the only entry that can stop a login working.
#
# WinApps sits after the join (index 10, run late) because it reads the joined
# realm to fill in RDP_DOMAIN, but still ahead of Duo.
MENU_RUN_ORDER=(0 1 2 4 5 11 3 7 6 8 10 9)

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

# Blank columns between the two menu columns, and blank columns held clear on
# the right of the grid so the longest right-column entry does not run into the
# banner border.
MENU_COL_GAP=3
MENU_GRID_RMARGIN=3
ML_GRID_RMARGIN_EFF=3   # RMARGIN after the fit-to-width shrink in menu_compute_layout

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
    # The stacked form is several rows taller, so it is the second choice - on a
    # default 80x24 terminal height is the scarcer resource. Before giving up the
    # second column, shrink the cosmetic spacing: first the right margin, then
    # the inter-column gap down to a single space.
    local body_w gap=$MENU_COL_GAP rmargin=$MENU_GRID_RMARGIN
    while (( left_w + gap + right_w + rmargin > avail && rmargin > 0 )); do
        (( rmargin-- ))
    done
    while (( left_w + gap + right_w > avail && gap > 1 )); do
        (( gap-- ))
    done
    if (( left_w + gap + right_w <= avail )); then
        ML_TWO_COL=1
        ML_COL_W=$(( left_w + gap ))
        ML_GRID_RMARGIN_EFF=$rmargin
        body_w=$(( left_w + gap + right_w + rmargin ))
        (( center_w > body_w )) && body_w=$center_w
    else
        ML_TWO_COL=0
        ML_COL_W=$single_w
        ML_GRID_RMARGIN_EFF=0
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
        # longer of them and a row may hold only one entry. Hold MENU_GRID_RMARGIN
        # columns clear on the right, unless the terminal is too tight to afford
        # it and the space is needed for the text itself.
        local row right_w=$(( content_width - ML_COL_W - ML_GRID_RMARGIN_EFF ))
        (( right_w < 16 )) && right_w=$(( content_width - ML_COL_W ))
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
    MENU_SELECTED=(); local _s
    for ((_s=0; _s<MENU_TOTAL; _s++)); do MENU_SELECTED[_s]=0; done
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
                    if (( MENU_TOTAL > MENU_LEFT_COUNT + MENU_RIGHT_COUNT )); then
                        # An odd list has a centred row - wrap to it.
                        menu_set_cursor 2 0
                    else
                        # Even list, no centred row - wrap to this column's foot.
                        col_size=$MENU_LEFT_COUNT
                        (( MCOL == 1 )) && col_size=$MENU_RIGHT_COUNT
                        menu_set_cursor "$MCOL" $(( col_size - 1 ))
                    fi
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
                        if (( MENU_TOTAL > MENU_LEFT_COUNT + MENU_RIGHT_COUNT )); then
                            menu_set_cursor 2 0
                        else
                            menu_set_cursor "$MCOL" 0
                        fi
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
        8) action_sudo_access ;;
        9) action_duo ;;
        10) action_winapps ;;
        11) action_status ;;
        *) return 1 ;;
    esac
}

# The once-per-run guards on the steps that are reachable from more than one
# place - configure_sudo_access from both the menu and post_join_tuning, and so
# on. They exist to stop one batch prompting twice for the same thing, so they
# are scoped to a batch: the menu loops back for another ENTER, and without
# this reset a step already run would return success without a word, leaving
# "Done." printed over a selection that did nothing.
reset_step_guards() {
    SDDM_GREETER_DONE=0
    DUO_DONE=0
    POST_JOIN_TUNING_DONE=0
    SUDO_ACCESS_DONE=0
}

# Run everything that was ticked, in MENU_RUN_ORDER.
process_menu_selections() {
    local -a queue=()
    local idx

    reset_step_guards

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
# Staying current
# ---------------------------------------------------------------------------
# There is no packaging here and no version handshake: whatever file is sitting
# on the machine is what runs. A checkout three commits behind looks exactly
# like a current one, produces log lines that look exactly like a current one's,
# and only diverges at the point where it does the wrong thing - by which time
# the obvious conclusion is that the new code does not work, rather than that it
# was never running. So the launch checks, says what is missing, and offers to
# fix it before anything else happens.
UPDATE_CHECK=1          # --no-update-check turns the launch check off
UPDATE_ONLY=0           # --update checks, updates, and exits
declare -a ORIGINAL_ARGV=()

# script_path - the running file, absolute.
script_path() {
    local p="${BASH_SOURCE[0]}"
    [[ "$p" == /* ]] || p="$PWD/$p"
    printf '%s' "$p"
}

# script_repo - the git checkout the running script lives in, or nothing. The
# .git directory is tested directly rather than asking git, so a script sitting
# outside a checkout costs nothing and prints nothing.
script_repo() {
    local dir
    have git || return 1
    dir="$(cd -- "$(dirname -- "$(script_path)")" 2>/dev/null && pwd)" || return 1
    [[ -d "$dir/.git" ]] || return 1
    printf '%s' "$dir"
}

# git_in_repo <dir> <args...> - git against the checkout, as its owner.
#
# This script is normally run under sudo while the checkout belongs to whoever
# cloned it. Running git as root there trips the dubious-ownership refusal, and
# when it does not, it leaves root-owned objects behind that break the owner's
# next pull. Dropping back to the owner avoids both. Every call is bounded, so
# an unreachable remote delays the launch rather than hanging it.
git_in_repo() {
    local dir="$1"; shift
    local owner
    owner="$(stat -c '%U' "$dir" 2>/dev/null)" || return 1
    if [[ $EUID -eq 0 && "$owner" != "root" ]] && have sudo; then
        timeout 20 sudo -n -u "$owner" git -C "$dir" "$@"
    else
        timeout 20 git -C "$dir" -c "safe.directory=$dir" "$@"
    fi
}

# update_status <dir> - "current", "behind" or "unknown". Anything the check
# cannot establish is "unknown", never "current": a failed fetch must not be
# reported as being up to date.
update_status() {
    local dir="$1" branch upstream local_rev remote_rev
    branch="$(git_in_repo "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [[ -n "$branch" && "$branch" != "HEAD" ]] || { printf 'unknown'; return 0; }
    git_in_repo "$dir" fetch --quiet 2>/dev/null || { printf 'unknown'; return 0; }
    upstream="$(git_in_repo "$dir" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"
    [[ -n "$upstream" ]] || { printf 'unknown'; return 0; }
    local_rev="$(git_in_repo "$dir" rev-parse HEAD 2>/dev/null)"
    remote_rev="$(git_in_repo "$dir" rev-parse "$upstream" 2>/dev/null)"
    [[ -n "$local_rev" && -n "$remote_rev" ]] || { printf 'unknown'; return 0; }
    [[ "$local_rev" == "$remote_rev" ]] && { printf 'current'; return 0; }
    if [[ -n "$(git_in_repo "$dir" rev-list "${local_rev}..${remote_rev}" 2>/dev/null)" ]]; then
        printf 'behind'
    else
        printf 'current'      # ahead, or diverged locally - not this check's business
    fi
}

# check_for_update - run before anything else touches the system.
check_for_update() {
    (( UPDATE_CHECK )) || return 0

    local dir status upstream
    if ! dir="$(script_repo)"; then
        if (( UPDATE_ONLY )); then
            warn "$(script_path) is not inside a git checkout, so there is nothing to update from."
            note "Copy the file over by hand, or clone the repository and run it from there."
            exit 1
        fi
        return 0
    fi

    status="$(update_status "$dir")"
    case "$status" in
        current)
            if (( UPDATE_ONLY )); then
                ok "Already up to date ($(git_in_repo "$dir" rev-parse --short HEAD 2>/dev/null))."
                exit 0
            fi
            return 0
            ;;
        unknown)
            if (( UPDATE_ONLY )); then
                warn "Could not work out whether this checkout is current; it is left alone."
                exit 1
            fi
            # Silent on a normal launch: an offline machine is a supported way to
            # run this, and a warning on every start would train people to ignore
            # the one that matters.
            return 0
            ;;
    esac

    upstream="$(git_in_repo "$dir" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"
    printf '\n'
    warn "This checkout is behind ${upstream:-its remote}. The following commits are missing:"
    git_in_repo "$dir" log --oneline "HEAD..@{upstream}" 2>/dev/null \
        | while read -r line; do note "  $line"; done
    note "Running now runs the old code. It will look and log exactly like the new code."

    if (( DRY_RUN )); then
        note "--dry-run changes nothing, so the checkout is left as it is."
        return 0
    fi

    if ! confirm "Update and restart the script?" "y"; then
        (( UPDATE_ONLY )) && exit 0
        warn "Continuing on the old code."
        return 0
    fi

    if ! git_in_repo "$dir" pull --ff-only --quiet; then
        warn "Update failed: the checkout has local changes, or it has diverged from the remote."
        note "Sort it out with git, or use --no-update-check to run the old code deliberately."
        exit 1
    fi
    ok "Updated to $(git_in_repo "$dir" rev-parse --short HEAD 2>/dev/null)."
    (( UPDATE_ONLY )) && exit 0

    # Re-exec so the rest of this run is the code that was just pulled, rather
    # than the half of it bash has already parsed.
    note "Restarting with the new code."
    exec "$(script_path)" ${ORIGINAL_ARGV[@]+"${ORIGINAL_ARGV[@]}"}
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
  -e, --extras LIST       Comma separated: mkhomedir,timesync,troubleshoot,shares,
                          sudo,duo,winapps
      --sudo-user LIST    Grant sudo to these accounts, comma separated. Local
                          or domain; a name may contain spaces.
      --sudo-group LIST   Grant sudo to these groups, comma separated. Each one
                          gets its own file under /etc/sudoers.d.
      --join              Join the domain after installing.
      --no-join           Install only; never attempt a join.
      --open-firewall     Allow Cockpit (9090/tcp) through the firewall.
      --no-open-firewall  Leave the firewall alone.
  -y, --yes               Non-interactive; accept every recommended default.
  -n, --dry-run           Print what would happen without changing anything.
  -l, --list              Show the packages for this system and exit.
      --update            Update this checkout from its remote and exit.
      --no-update-check   Do not check for a newer version at startup.
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

${C_BOLD}WINDOWS APPLICATIONS (WINAPPS)${C_RESET}
      --winapps           Set up WinApps for all users (same as -e winapps).
      --no-winapps        Never set up WinApps, whatever the extras say.
      --winapps-backend B libvirt (local VM), manual (existing RDP host on the
                          network), docker or podman.
      --winapps-host ADDR Windows hostname or IP. Required for 'manual'.
      --winapps-port PORT RDP port (default 3389).
      --winapps-vm NAME   libvirt VM name (default RDPWindows).
      --winapps-domain D  RDP_DOMAIN (default: the realm this machine joined).
      --winapps-creds M   askpass  - prompt each user for their own AD password
                          kerberos - single sign-on from the user's ticket
                          shared   - one service account for everyone
      --winapps-user USER Windows service account, 'shared' mode only.
      --winapps-remove    Remove the multi-user wiring (template, generator,
                          login hooks). Leaves per-user configs and launchers.
      --winapps-vm-remove With --winapps-remove, also 'virsh undefine' the guest
                          and delete its disk.

Building the Windows guest (libvirt backend only):
      --winapps-deploy    Build a WinApps-ready Windows 11 Pro VM: unattended
                          install, virtio drivers, RDP and RemoteApp on. Nothing
                          domain-related - join it to AD yourself.
      --no-winapps-deploy Never build the VM; just install the builder script.
      --winapps-iso FILE  Full path to a Windows 10/11 .iso file - the filename
                          must be part of the path, not just its directory.
                          Without it, Mido fetches Windows 11 from Microsoft
                          (less reliable).
      --winapps-vm-ram N   Guest RAM in MiB   (default 4096).
      --winapps-vm-cpus N  Guest vCPUs        (default 4).
      --winapps-vm-disk N  Guest disk in GiB  (default 64).

The shared-mode password is read from the WINAPPS_RDP_PASS environment variable
so it stays out of the process list. Note that 'shared' puts every user into the
same Windows profile, which defeats the point of the domain join.

The built VM's local administrator password is read from WINAPPS_VM_PASS; if
unset, a random one is generated and printed once. The builder is also installed
as 'winapps-vm-deploy' so the VM can be rebuilt later without re-running this.

${C_BOLD}EXAMPLES${C_RESET}
  # Interactive menu of everything the script can do
  sudo ./domain-join-setup.sh

  # Preview the actions for a KDE workstation without touching anything
  sudo ./domain-join-setup.sh --dry-run

  # Unattended install plus join
  sudo ./domain-join-setup.sh -y -b sssd -g cockpit \\
       -e mkhomedir,timesync,shares -d corp.example.com -u svc-join --join

  # Grant sudo to a domain group and one account, no prompts
  sudo ./domain-join-setup.sh -y --sudo-group 'Linux Admins@corp.example.com' \\
       --sudo-user jdoe

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
    # Kept verbatim so check_for_update can re-exec the run exactly as asked.
    ORIGINAL_ARGV=("$@")
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--domain)   OPT_DOMAIN="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
            -u|--user)     OPT_JOIN_USER="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
            -b|--backend)  OPT_BACKEND="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
            -g|--gui)      OPT_GUI="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
            -e|--extras)   OPT_EXTRAS="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
            --sudo-user)   OPT_SUDO_USER="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
            --sudo-group)  OPT_SUDO_GROUP="${2:-}"; CLI_DIRECTED=1; shift 2 ;;
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
            --winapps)          OPT_WINAPPS=1; CLI_DIRECTED=1; shift ;;
            --no-winapps)       OPT_WINAPPS=0; CLI_DIRECTED=1; shift ;;
            --winapps-backend)  OPT_WINAPPS_BACKEND="${2:-}"; OPT_WINAPPS=1; CLI_DIRECTED=1; shift 2 ;;
            --winapps-host)     OPT_WINAPPS_HOST="${2:-}"; OPT_WINAPPS=1; CLI_DIRECTED=1; shift 2 ;;
            --winapps-port)     OPT_WINAPPS_PORT="${2:-}"; OPT_WINAPPS=1; CLI_DIRECTED=1; shift 2 ;;
            --winapps-vm)       OPT_WINAPPS_VM="${2:-}"; OPT_WINAPPS=1; CLI_DIRECTED=1; shift 2 ;;
            --winapps-domain)   OPT_WINAPPS_DOMAIN="${2:-}"; OPT_WINAPPS=1; CLI_DIRECTED=1; shift 2 ;;
            --winapps-creds)    OPT_WINAPPS_CREDS="${2:-}"; OPT_WINAPPS=1; CLI_DIRECTED=1; shift 2 ;;
            --winapps-user)     OPT_WINAPPS_RDP_USER="${2:-}"; OPT_WINAPPS=1; CLI_DIRECTED=1; shift 2 ;;
            --winapps-remove)   WINAPPS_REMOVE=1; OPT_WINAPPS=1; CLI_DIRECTED=1; shift ;;
            --winapps-vm-remove) WINAPPS_VM_REMOVE=1; WINAPPS_REMOVE=1; OPT_WINAPPS=1; CLI_DIRECTED=1; shift ;;
            --winapps-deploy)    OPT_WINAPPS_DEPLOY=1; OPT_WINAPPS=1; CLI_DIRECTED=1; shift ;;
            --no-winapps-deploy) OPT_WINAPPS_DEPLOY=0; CLI_DIRECTED=1; shift ;;
            --winapps-iso)       OPT_WINAPPS_ISO="${2:-}"; OPT_WINAPPS_DEPLOY=1; OPT_WINAPPS=1; CLI_DIRECTED=1; shift 2 ;;
            --winapps-vm-ram)    OPT_WINAPPS_VM_RAM="${2:-}"; OPT_WINAPPS=1; CLI_DIRECTED=1; shift 2 ;;
            --winapps-vm-cpus)   OPT_WINAPPS_VM_CPUS="${2:-}"; OPT_WINAPPS=1; CLI_DIRECTED=1; shift 2 ;;
            --winapps-vm-disk)   OPT_WINAPPS_VM_DISK="${2:-}"; OPT_WINAPPS=1; CLI_DIRECTED=1; shift 2 ;;
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
            --update)          UPDATE_ONLY=1; CLI_DIRECTED=1; shift ;;
            --no-update-check) UPDATE_CHECK=0; shift ;;
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

    if [[ -n "$OPT_WINAPPS_BACKEND" && ! "$OPT_WINAPPS_BACKEND" =~ ^(libvirt|docker|podman|manual)$ ]]; then
        die "Invalid --winapps-backend '$OPT_WINAPPS_BACKEND' (expected libvirt, docker, podman or manual)."
    fi

    if [[ -n "$OPT_WINAPPS_CREDS" && ! "$OPT_WINAPPS_CREDS" =~ ^(askpass|kerberos|shared)$ ]]; then
        die "Invalid --winapps-creds '$OPT_WINAPPS_CREDS' (expected askpass, kerberos or shared)."
    fi

    if [[ "$OPT_WINAPPS_BACKEND" == "manual" && -n "$OPT_WINAPPS_HOST" ]]; then
        :
    elif [[ "$OPT_WINAPPS_BACKEND" == "manual" && $ASSUME_YES -eq 1 ]]; then
        die "--winapps-backend manual needs --winapps-host to say where Windows is."
    fi

    if [[ "$OPT_WINAPPS_CREDS" == "shared" && $ASSUME_YES -eq 1 && -z "$OPT_WINAPPS_RDP_USER" ]]; then
        die "--winapps-creds shared needs --winapps-user (and WINAPPS_RDP_PASS in the environment)."
    fi

    if [[ "$OPT_WINAPPS_DEPLOY" == "1" && -n "$OPT_WINAPPS_BACKEND" && "$OPT_WINAPPS_BACKEND" != "libvirt" ]]; then
        die "--winapps-deploy only applies to the libvirt backend (got '$OPT_WINAPPS_BACKEND')."
    fi
    if [[ -n "$OPT_WINAPPS_ISO" ]]; then
        if [[ -d "$OPT_WINAPPS_ISO" ]]; then
            die "--winapps-iso is a directory ('$OPT_WINAPPS_ISO'). Give the full path to the .iso file, filename included."
        elif [[ ! -f "$OPT_WINAPPS_ISO" ]]; then
            die "--winapps-iso: no such file '$OPT_WINAPPS_ISO'."
        fi
    fi
    for _p in "ram:$OPT_WINAPPS_VM_RAM" "cpus:$OPT_WINAPPS_VM_CPUS" "disk:$OPT_WINAPPS_VM_DISK"; do
        [[ -z "${_p#*:}" ]] && continue
        [[ "${_p#*:}" =~ ^[1-9][0-9]*$ ]] || die "--winapps-vm-${_p%%:*} must be a positive integer (got '${_p#*:}')."
    done
    unset _p

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
    check_for_update    # before anything reads the system or edits a file

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
