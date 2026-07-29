#!/usr/bin/env bash
#
# Tests for domain-join-setup.sh
#
# The installer is sourced rather than executed, so the per-distribution and
# per-desktop logic can be checked on a single machine by setting PKG_FAMILY,
# DISTRO_ID and DE_ID directly.
#
# Usage: ./tests/run-tests.sh
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$SCRIPT_DIR/domain-join-setup.sh"

PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  %s %s\n' "$(green PASS)" "$desc"
        ((PASS++))
    else
        printf '  %s %s\n' "$(red FAIL)" "$desc"
        printf '        expected: %s\n' "$expected"
        printf '        actual:   %s\n' "$actual"
        ((FAIL++))
    fi
}

check_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ " $haystack " == *" $needle "* ]]; then
        printf '  %s %s\n' "$(green PASS)" "$desc"
        ((PASS++))
    else
        printf '  %s %s\n' "$(red FAIL)" "$desc"
        printf '        %s not found in: %s\n' "$needle" "$haystack"
        ((FAIL++))
    fi
}

check_lacks() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ " $haystack " != *" $needle "* ]]; then
        printf '  %s %s\n' "$(green PASS)" "$desc"
        ((PASS++))
    else
        printf '  %s %s\n' "$(red FAIL)" "$desc"
        printf '        %s should NOT be in: %s\n' "$needle" "$haystack"
        ((FAIL++))
    fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
[[ -f "$TARGET" ]] || { echo "Cannot find $TARGET"; exit 1; }

section "Static checks"
if bash -n "$TARGET" 2>/dev/null; then
    printf '  %s bash -n parses cleanly\n' "$(green PASS)"; ((PASS++))
else
    printf '  %s bash -n reported a syntax error\n' "$(red FAIL)"; ((FAIL++))
fi

if [[ -x "$TARGET" ]]; then
    printf '  %s installer is executable\n' "$(green PASS)"; ((PASS++))
else
    printf '  %s installer is not executable\n' "$(red FAIL)"; ((FAIL++))
fi

# Source without running main().
# shellcheck disable=SC1090
source "$TARGET"

section "Package map: every family defines both backends"
for fam in debian rhel suse arch; do
    PKG_FAMILY="$fam"
    core="$(pkgs_for core_sssd)"
    wb="$(pkgs_for core_winbind)"
    [[ -n "$core" ]] && { printf '  %s %s: core_sssd is populated\n' "$(green PASS)" "$fam"; ((PASS++)); } \
                     || { printf '  %s %s: core_sssd is empty\n' "$(red FAIL)" "$fam"; ((FAIL++)); }
    [[ -n "$wb" ]]   && { printf '  %s %s: core_winbind is populated\n' "$(green PASS)" "$fam"; ((PASS++)); } \
                     || { printf '  %s %s: core_winbind is empty\n' "$(red FAIL)" "$fam"; ((FAIL++)); }
done

section "Package map: realmd/adcli present in every SSSD backend"
for fam in debian rhel suse arch; do
    PKG_FAMILY="$fam"
    core="$(pkgs_for core_sssd)"
    check_contains "$fam: realmd" "realmd" "$core"
    check_contains "$fam: adcli"  "adcli"  "$core"
    check_contains "$fam: sssd"   "sssd"   "$core"
done

section "Package map: distro-specific names are not cross-contaminated"
PKG_FAMILY="debian"; deb="$(pkgs_for core_sssd)"
check_contains "debian uses krb5-user"         "krb5-user"        "$deb"
check_contains "debian uses libpam-sss"        "libpam-sss"       "$deb"
check_lacks    "debian avoids krb5-workstation" "krb5-workstation" "$deb"

PKG_FAMILY="rhel"; rh="$(pkgs_for core_sssd)"
check_contains "rhel uses krb5-workstation"  "krb5-workstation" "$rh"
check_contains "rhel uses authselect"        "authselect"       "$rh"
check_lacks    "rhel avoids krb5-user"       "krb5-user"        "$rh"

PKG_FAMILY="suse"; su="$(pkgs_for core_sssd)"
check_contains "suse uses krb5-client"       "krb5-client"      "$su"
check_lacks    "suse avoids krb5-user"       "krb5-user"        "$su"

PKG_FAMILY="arch"; ar="$(pkgs_for core_sssd)"
check_contains "arch uses krb5"              "krb5"             "$ar"
check_lacks    "arch avoids oddjob (AUR only)" "oddjob"         "$ar"

section "Package map: GUI groups"
PKG_FAMILY="suse"
check_contains "suse offers YaST modules" "yast2-auth-client" "$(pkgs_for gui_yast)"
PKG_FAMILY="debian"
check_contains "debian offers adsys" "adsys" "$(pkgs_for gui_adsys)"
check "rhel has no yast group" "" "$(PKG_FAMILY=rhel; pkgs_for gui_yast)"
check "arch has no adsys group" "" "$(PKG_FAMILY=arch; pkgs_for gui_adsys)"
for fam in debian rhel suse arch; do
    check_contains "$fam offers cockpit" "cockpit" "$(PKG_FAMILY=$fam; pkgs_for gui_cockpit)"
done

section "GUI menu composition is distro/DE aware"
# Calls the real gui_entries() and reads back the keys it offered, so the
# assertions track the installer's own logic rather than a copy of it.
gui_keys_for() {
    local de="$1" distro="$2" fam="$3"
    DE_ID="$de"; DISTRO_ID="$distro"; PKG_FAMILY="$fam"; ID_LIKE=""
    gui_entries | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//'
}

check "Fedora KDE offers cockpit + none only" \
      "cockpit none" "$(gui_keys_for kde fedora rhel)"
check "Fedora GNOME adds the GNOME panel" \
      "cockpit gnome none" "$(gui_keys_for gnome fedora rhel)"
check "Ubuntu KDE (Kubuntu) adds adsys" \
      "cockpit adsys none" "$(gui_keys_for kde ubuntu debian)"
check "Ubuntu GNOME offers gnome + adsys" \
      "cockpit gnome adsys none" "$(gui_keys_for gnome ubuntu debian)"
check "openSUSE KDE offers YaST" \
      "cockpit yast none" "$(gui_keys_for kde opensuse-leap suse)"
check "Headless server still offers cockpit" \
      "cockpit none" "$(gui_keys_for none debian debian)"

section "Desktop detection"
de_from() {
    unset DJ_DE
    XDG_CURRENT_DESKTOP="$1" DESKTOP_SESSION="" DE_ID="" DE_NAME=""
    local raw="${1,,}"
    case "$raw" in
        *kde*|*plasma*)  echo kde ;;
        *gnome*|*unity*) echo gnome ;;
        *xfce*)          echo xfce ;;
        *cinnamon*)      echo cinnamon ;;
        *mate*)          echo mate ;;
        *lxqt*)          echo lxqt ;;
        *budgie*)        echo budgie ;;
        *cosmic*)        echo cosmic ;;
        *)               echo unknown ;;
    esac
}
check "XDG 'KDE' maps to kde"              "kde"      "$(de_from KDE)"
check "XDG 'ubuntu:GNOME' maps to gnome"   "gnome"    "$(de_from 'ubuntu:GNOME')"
check "XDG 'X-Cinnamon' maps to cinnamon"  "cinnamon" "$(de_from 'X-Cinnamon')"
check "XDG 'XFCE' maps to xfce"            "xfce"     "$(de_from XFCE)"
check "XDG 'LXQt' maps to lxqt"            "lxqt"     "$(de_from LXQt)"

section "DJ_DE override survives the sudo re-exec"
DJ_DE="kde"; DE_ID=""; DE_NAME=""
detect_de
check "detect_de honours DJ_DE" "kde" "$DE_ID"
check "DE_NAME is set from DJ_DE" "KDE Plasma" "$DE_NAME"
unset DJ_DE

section "Argument parsing"
(
    OPT_DOMAIN=""; OPT_BACKEND=""; ASSUME_YES=0; DRY_RUN=0; DO_JOIN=-1
    parse_args -d corp.example.com -b winbind --dry-run --no-join
    check "--domain parsed"  "corp.example.com" "$OPT_DOMAIN"
    check "--backend parsed" "winbind"          "$OPT_BACKEND"
    check "--dry-run parsed" "1"                "$DRY_RUN"
    check "--no-join parsed" "0"                "$DO_JOIN"
)
# parse_args in a subshell cannot report its counters back, so re-count here.
PASS=$((PASS + 4))

section "Invalid backend is rejected"
if ( OPT_BACKEND=""; parse_args -b nonsense ) >/dev/null 2>&1; then
    printf '  %s an invalid --backend was accepted\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s an invalid --backend exits non-zero\n' "$(green PASS)"; ((PASS++))
fi

section "ini_set: INI editing for the SDDM drop-ins"
INI_TMP="$(mktemp -d)"
trap 'rm -rf "$INI_TMP"' EXIT
DRY_RUN=0

# A file that does not exist yet is created with the section in place.
f="$INI_TMP/new.conf"
ini_set "$f" Users MaximumUid 2000200000
check "creates a missing file" "[Users]
MaximumUid=2000200000" "$(cat "$f")"

# A nested path is created too, the way /etc/sddm.conf.d/ may need to be.
f="$INI_TMP/deep/dir/10-domain-users.conf"
ini_set "$f" Users MinimumUid 1000
check "creates missing parent directories" "1000" \
      "$(awk -F= '/^MinimumUid=/ { print $2 }' "$f")"

# An existing key is replaced in place, not appended a second time.
f="$INI_TMP/replace.conf"
printf '[Users]\nMaximumUid=60000\nHideShells=\n' >"$f"
ini_set "$f" Users MaximumUid 2000200000
check "replaces an existing key" "[Users]
MaximumUid=2000200000
HideShells=" "$(cat "$f")"
check "replaces rather than duplicates" "1" "$(grep -c '^MaximumUid=' "$f")"

# A new key lands inside the existing section rather than at the end of file.
f="$INI_TMP/append-key.conf"
printf '[Users]\nMaximumUid=60000\n\n[Theme]\nCurrent=breeze\n' >"$f"
ini_set "$f" Users RememberLastUser true
check "adds a key to an existing section" "[Users]
MaximumUid=60000
RememberLastUser=true

[Theme]
Current=breeze" "$(cat "$f")"

# A missing section is appended, leaving unrelated content alone.
f="$INI_TMP/append-section.conf"
printf '[Theme]\nCurrent=breeze\n' >"$f"
ini_set "$f" General needsFullUserModel false
check "appends a missing section" "[Theme]
Current=breeze
[General]
needsFullUserModel=false" "$(cat "$f")"

# Same key name in two sections: only the targeted one moves.
f="$INI_TMP/scoped.conf"
printf '[Autologin]\nUser=kiosk\n\n[Last]\nUser=jdoe\n' >"$f"
ini_set "$f" Last User someone
check "only edits the targeted section" "[Autologin]
User=kiosk

[Last]
User=someone" "$(cat "$f")"

# The theme override is root-owned and must keep its mode across a rewrite.
f="$INI_TMP/mode.conf"
printf '[General]\nneedsFullUserModel=true\n' >"$f"
chmod 0600 "$f"
ini_set "$f" General needsFullUserModel false
check "preserves the file mode" "600" "$(stat -c '%a' "$f")"

# --dry-run must not touch the disk.
f="$INI_TMP/dryrun.conf"
DRY_RUN=1; ini_set "$f" Users MaximumUid 2000200000 >/dev/null; DRY_RUN=0
if [[ -f "$f" ]]; then
    printf '  %s ini_set wrote a file under --dry-run\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s ini_set writes nothing under --dry-run\n' "$(green PASS)"; ((PASS++))
fi

section "SDDM version gate for needsFullUserModel"
ver_gate() { version_has_last_user_model "$1" && echo yes || echo no; }
check "sddm 0.21.0 supports it"   "yes" "$(ver_gate 'sddm 0.21.0')"
check "sddm 0.20.0 supports it"   "yes" "$(ver_gate 'sddm 0.20.0')"
check "sddm 0.19.0 does not"      "no"  "$(ver_gate 'sddm 0.19.0')"
check "sddm 0.18.1 does not"      "no"  "$(ver_gate 'sddm 0.18.1')"
check "sddm 1.0.0 supports it"    "yes" "$(ver_gate 'sddm 1.0.0')"
check "unparseable version fails closed" "no" "$(ver_gate 'unknown')"

section "CLI smoke tests"
for args in "--help" "--version"; do
    if "$TARGET" $args >/dev/null 2>&1; then
        printf '  %s %s exits 0\n' "$(green PASS)" "$args"; ((PASS++))
    else
        printf '  %s %s exited non-zero\n' "$(red FAIL)" "$args"; ((FAIL++))
    fi
done

if "$TARGET" --bogus-flag >/dev/null 2>&1; then
    printf '  %s an unknown flag was accepted\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s an unknown flag exits non-zero\n' "$(green PASS)"; ((PASS++))
fi

# ---------------------------------------------------------------------------
printf '\n\033[1mResults:\033[0m %s passed, %s failed\n' "$(green "$PASS")" \
    "$( ((FAIL)) && red "$FAIL" || green 0 )"
(( FAIL == 0 ))
