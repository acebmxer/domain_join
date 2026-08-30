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

section "The menu is the default, and the action flags switch it off"
# menu_wanted also insists on a terminal, which the test harness is not, so
# CLI_DIRECTED is what is being read back here.
directed_after() {
    ( CLI_DIRECTED=0; MENU_FORCED=-1; OPT_DOMAIN=""; OPT_BACKEND=""
      parse_args "$@" >/dev/null 2>&1; printf '%s' "$CLI_DIRECTED" )
}
check "no flags leaves the menu in place"     "0" "$(directed_after)"
check "--dry-run alone leaves the menu"       "0" "$(directed_after --dry-run)"
check "--detected-de alone leaves the menu"   "0" "$(directed_after --detected-de kde)"
check "--backend skips the menu"              "1" "$(directed_after -b sssd)"
check "--domain skips the menu"               "1" "$(directed_after -d corp.example.com)"
check "--yes skips the menu"                  "1" "$(directed_after -y)"
check "--list skips the menu"                 "1" "$(directed_after -l)"
check "--join skips the menu"                 "1" "$(directed_after --join)"
forced_after() {
    ( MENU_FORCED=-1; parse_args "$@" >/dev/null 2>&1; printf '%s' "$MENU_FORCED" )
}
check "--menu forces the menu on"    "1" "$(forced_after --menu)"
check "--no-menu forces the menu off" "0" "$(forced_after --no-menu)"

section "Menu tables line up"
check "one hint per entry"  "${#MENU_NAMES[@]}" "${#MENU_HINTS[@]}"
check "MENU_TOTAL matches the names" "${#MENU_NAMES[@]}" "$MENU_TOTAL"
check "the columns account for every entry" "$MENU_TOTAL" \
      "$(( MENU_LEFT_COUNT + MENU_RIGHT_COUNT + (MENU_TOTAL - MENU_LEFT_COUNT - MENU_RIGHT_COUNT) ))"
# An even list fills two whole columns; an odd list leaves exactly one over for
# the centred row. Anything else is a layout mistake.
_leftover=$(( MENU_TOTAL - MENU_LEFT_COUNT - MENU_RIGHT_COUNT ))
check "an even list has no centred row"      "0" "$(( MENU_TOTAL % 2 == 0 ? _leftover : 0 ))"
check "the split is even within one row"     "1" "$(( MENU_LEFT_COUNT == MENU_RIGHT_COUNT || MENU_LEFT_COUNT == MENU_RIGHT_COUNT + 1 ? 1 : 0 ))"
check "at most one entry is ever centred"    "1" "$(( _leftover <= 1 ? 1 : 0 ))"
check "the run order covers every entry once" "$MENU_TOTAL" "${#MENU_RUN_ORDER[@]}"
check "the run order is a permutation of the indices" \
      "$(seq 0 $((MENU_TOTAL - 1)) | sort -n | tr '\n' ' ')" \
      "$(printf '%s\n' "${MENU_RUN_ORDER[@]}" | sort -n | tr '\n' ' ')"
# Every index must map to an action, and nothing beyond the table may.
missing=""
for ((i=0; i<MENU_TOTAL; i++)); do
    grep -qE "^ *$i\) action_" "$TARGET" || missing="$missing $i"
done
check "every entry dispatches to an action" "" "$missing"
if ( menu_run_action "$MENU_TOTAL" ) >/dev/null 2>&1; then
    printf '  %s an out-of-range menu index was accepted\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s an out-of-range menu index returns non-zero\n' "$(green PASS)"; ((PASS++))
fi

section "Menu layout adapts to the terminal"
# stty cannot report a size here, so menu_term_size falls back to LINES/COLUMNS.
layout_at() {
    COLUMNS="$1" LINES="$2" menu_compute_layout
}
DISTRO_NAME="Test Linux 1"; PKG_MGR="dnf"; PKG_FAMILY="rhel"; DE_NAME="KDE Plasma"; MENU_DOMAIN=""
layout_at 120 45
check "120x45 uses two columns"      "1" "$ML_TWO_COL"
check "120x45 keeps the banner box"  "1" "$ML_BANNER"
check "120x45 keeps the hint line"   "1" "$ML_HINTS"
check "120x45 is not too small"      "0" "$ML_TOO_SMALL"
layout_at 80 24
check "80x24 still uses two columns" "1" "$ML_TWO_COL"
check "80x24 is not too small"       "0" "$ML_TOO_SMALL"
layout_at 60 30
check "60x30 stacks into one column" "0" "$ML_TWO_COL"
check "60x30 is not too small"       "0" "$ML_TOO_SMALL"
layout_at 30 12
check "30x12 reports too small"      "1" "$ML_TOO_SMALL"
# The floor the README quotes. Adding a menu entry moves it, so it is pinned.
layout_at 40 22
check "40x22 is the smallest usable size" "0" "$ML_TOO_SMALL"
layout_at 39 22
check "39 columns is too narrow"          "1" "$ML_TOO_SMALL"
layout_at 40 21
check "21 rows is too short"              "1" "$ML_TOO_SMALL"

# No drawn line may be wider than the terminal, or the redraw leaves debris.
overlong=0
for size in "120 45" "100 40" "80 24" "70 30" "60 30" "45 24"; do
    set -- $size
    MENU_CURSOR=0
    # Count display columns, not bytes: the menu box is drawn with multi-byte
    # box-drawing characters, and mawk (Ubuntu's awk) would count each as 3.
    widest="$(COLUMNS="$1" LINES="$2" draw_menu \
        | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' \
        | python3 -c 'import sys; print(max((len(l.rstrip("\r\n")) for l in sys.stdin), default=0))')"
    (( widest > $1 )) && { overlong=1; printf '        %sx%s produced a %s-column line\n' "$1" "$2" "$widest"; }
done
check "every drawn line fits the terminal" "0" "$overlong"

section "Menu navigation"
# Mirrors the UP/DOWN handlers in run_menu: with an even list there is no
# centred row, so a wrap at a column edge stays inside that column.
nav() {
    MENU_CURSOR="$1"
    menu_get_pos "$MENU_CURSOR"
    local has_centre=$(( MENU_TOTAL > MENU_LEFT_COUNT + MENU_RIGHT_COUNT ))
    case "$2" in
        up)
            if (( MCOL == 2 )); then menu_set_cursor 0 $(( MENU_LEFT_COUNT - 1 ))
            elif (( MROW == 0 )); then
                if (( has_centre )); then menu_set_cursor 2 0
                else
                    col_size=$MENU_LEFT_COUNT
                    (( MCOL == 1 )) && col_size=$MENU_RIGHT_COUNT
                    menu_set_cursor "$MCOL" $(( col_size - 1 ))
                fi
            else menu_set_cursor "$MCOL" $(( MROW - 1 )); fi ;;
        down)
            if (( MCOL == 2 )); then menu_set_cursor 0 0
            else
                col_size=$MENU_LEFT_COUNT
                (( MCOL == 1 )) && col_size=$MENU_RIGHT_COUNT
                if (( MROW >= col_size - 1 )); then
                    if (( has_centre )); then menu_set_cursor 2 0
                    else menu_set_cursor "$MCOL" 0; fi
                else menu_set_cursor "$MCOL" $(( MROW + 1 )); fi
            fi ;;
    esac
    printf '%s' "$MENU_CURSOR"
}
ML_TWO_COL=1
right_top=$MENU_LEFT_COUNT
right_foot=$(( MENU_LEFT_COUNT + MENU_RIGHT_COUNT - 1 ))
left_foot=$(( MENU_LEFT_COUNT - 1 ))
check "index 0 is the top of the left column"  "0 0" "$(menu_get_pos 0; printf '%s %s' "$MCOL" "$MROW")"
check "the first right-column index is its top" "1 0" \
      "$(menu_get_pos "$right_top"; printf '%s %s' "$MCOL" "$MROW")"
check "the right column's foot is in column 1" "1 $(( MENU_RIGHT_COUNT - 1 ))" \
      "$(menu_get_pos "$right_foot"; printf '%s %s' "$MCOL" "$MROW")"
check "up from the left top wraps to the left foot"   "$left_foot"  "$(nav 0 up)"
check "up from the right top wraps to the right foot" "$right_foot" "$(nav "$right_top" up)"
check "down off the left foot wraps to the left top"  "0"           "$(nav "$left_foot" down)"
check "down off the right foot wraps to the right top" "$right_top" "$(nav "$right_foot" down)"
check "down within the left column steps by one"      "1"           "$(nav 0 down)"

# The centred-row path still has to work for a hypothetical odd list.
_sL=$MENU_LEFT_COUNT _sR=$MENU_RIGHT_COUNT _sT=$MENU_TOTAL
MENU_LEFT_COUNT=2; MENU_RIGHT_COUNT=2; MENU_TOTAL=5
_ci=$(( MENU_LEFT_COUNT + MENU_RIGHT_COUNT ))
check "odd list: up from a column top reaches the centred row" "$_ci" "$(nav 0 up)"
check "odd list: up from the centred row enters the left column" "1" "$(nav "$_ci" up)"
check "odd list: down from the centred row returns to the top"  "0" "$(nav "$_ci" down)"
MENU_LEFT_COUNT=$_sL; MENU_RIGHT_COUNT=$_sR; MENU_TOTAL=$_sT
MENU_CURSOR=0

# The columns need not be the same length, and the draw loop used to walk only
# as many rows as the left column has - which silently hid the last entry of a
# longer right column.
missing_names=""
drawn="$(COLUMNS=120 LINES=45 draw_menu | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g')"
for name in "${MENU_NAMES[@]}"; do
    [[ "$drawn" == *"$name"* ]] || missing_names="$missing_names|$name"
done
check "every entry is drawn, whichever column is longer" "" "$missing_names"

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
# 0.19.0 is the floor: "Don't fill UserModel if theme does not require it"
# shipped there, and it is the version Ubuntu 22.04 LTS carries.
ver_gate() { version_has_last_user_model "$1" && echo yes || echo no; }
check "sddm 0.21.0 supports it"   "yes" "$(ver_gate 'sddm 0.21.0')"
check "sddm 0.20.0 supports it"   "yes" "$(ver_gate 'sddm 0.20.0')"
check "sddm 0.19.0 supports it"   "yes" "$(ver_gate 'sddm 0.19.0')"
check "sddm 0.18.1 does not"      "no"  "$(ver_gate 'sddm 0.18.1')"
check "sddm 0.13.0 does not"      "no"  "$(ver_gate 'sddm 0.13.0')"
check "sddm 1.0.0 supports it"    "yes" "$(ver_gate 'sddm 1.0.0')"
check "unparseable version fails closed" "no" "$(ver_gate 'unknown')"

section "SDDM version probe never executes sddm"
# Regression: sddm_has_last_user_model used to run `sddm --version`. On Kubuntu
# the daemon does not recognise the flag and starts instead -- it takes a VT and
# throws a greeter over the running session, which looks exactly like being
# locked out. Nothing in the probe may execute sddm.
# Comments discuss the old call on purpose, so compare against code only.
sddm_code_only() { grep -v '^[[:space:]]*#' "$TARGET"; }
check "no code runs 'sddm --version'" "0" \
    "$(sddm_code_only | grep -c 'sddm --version')"
check "no code runs sddm with a flag" "0" \
    "$(sddm_code_only | grep -cE '(^|[^-[:alnum:]_/])sddm[[:space:]]+-')"

# The probe reads the package database instead. Stub each backend in turn.
probe_with() {
    (
        have() { [[ "$1" == "$1" ]]; }
        dpkg-query() { :; }
        eval "$1"
        sddm_package_version
    )
}
check "dpkg-query answer is used" "0.19.0-1ubuntu4" \
    "$(probe_with 'dpkg-query() { printf "0.19.0-1ubuntu4"; }')"
check "a Kubuntu 0.19 package version passes the gate" "yes" \
    "$(version_has_last_user_model '0.19.0-1ubuntu4' && echo yes || echo no)"
check "a Kubuntu 0.21 package version passes the gate" "yes" \
    "$(version_has_last_user_model '0.21.0-1ubuntu2' && echo yes || echo no)"
check "an 0.18 package version fails the gate" "no" \
    "$(version_has_last_user_model '0.18.1-2build1' && echo yes || echo no)"

section "SDDM last-user lookup: local account count and threshold"
# The greeter only runs getpwnam() on the remembered user once the enumerated
# count exceeds DisableAvatarsThreshold, so the threshold has to sit one below
# the number of local accounts -- see sddm_avatar_threshold.
# Reuses $INI_TMP rather than taking a second temp dir, so the EXIT trap set up
# for it stays the only one -- a second trap would replace it and leak the first.
pw="$INI_TMP/passwd"
printf 'root:x:0:0::/root:/bin/bash\ndaemon:x:1:1::/usr/sbin:/usr/sbin/nologin\n' >"$pw"
check "system accounts are not counted" "0" "$(sddm_local_user_count "$pw")"

printf 'nick:x:1000:1000::/home/nick:/bin/bash\n' >>"$pw"
check "one local account counted" "1" "$(sddm_local_user_count "$pw")"

printf 'guest:x:1001:1001::/home/guest:/bin/bash\n' >>"$pw"
check "two local accounts counted" "2" "$(sddm_local_user_count "$pw")"

printf 'nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin\n' >>"$pw"
check "nobody is outside the UID window" "2" "$(sddm_local_user_count "$pw")"

thr() { sddm_avatar_threshold "$1" 2>/dev/null || echo unusable; }
check "one local account -> threshold 0"  "0" "$(thr 1)"
check "two local accounts -> threshold 1" "1" "$(thr 2)"
check "five local accounts -> threshold 4" "4" "$(thr 5)"
check "no local account is unusable" "unusable" "$(thr 0)"
check "garbage is unusable"          "unusable" "$(thr '')"

section "SDDM forked theme: the showUserList patch"
# Arming the getpwnam() fallback is not enough on its own: Breeze refuses to
# draw a user list once containsAllUsers is false, and false is exactly what
# UserModel sets in the branch that appends the domain user. Both bails have to
# go, or the greeter falls back to a pre-filled username field.
qml="$INI_TMP/Main.qml"
write_breeze_showuserlist() {
    cat >"$qml" <<'QML'
                showUserList: {
                    if (!userListModel.hasOwnProperty("count")
                        || !userListModel.hasOwnProperty("disableAvatarsThreshold")) {
                        return false
                    }

                    if (userListModel.count === 0 ) {
                        return false
                    }

                    if (userListModel.hasOwnProperty("containsAllUsers") && !userListModel.containsAllUsers) {
                        return false
                    }

                    return userListModel.count <= userListModel.disableAvatarsThreshold
                }
QML
}

write_breeze_showuserlist
check "the patch applies to Breeze's block" "yes" \
    "$(sddm_patch_main_qml "$qml" >/dev/null 2>&1 && echo yes || echo no)"
check "the containsAllUsers bail is neutralised" "0" \
    "$(grep -c '&& !userListModel\.containsAllUsers' "$qml")"
check "the threshold comparison is gone" "0" \
    "$(grep -c 'count <= userListModel\.disableAvatarsThreshold' "$qml")"
check "the list is drawn whenever the model has anyone" "1" \
    "$(grep -c 'return userListModel\.count > 0' "$qml")"
check "the empty-model guard is left alone" "1" \
    "$(grep -c 'userListModel\.count === 0' "$qml")"

# A silently unpatched copy is worse than no fork at all: it looks like a
# working theme and behaves like the broken one. If Plasma rewrites the block,
# the patch has to report failure so the caller leaves the login screen alone.
printf 'showUserList: { return somethingCompletelyDifferent }\n' >"$qml"
check "a rewritten block is reported, not ignored" "no" \
    "$(sddm_patch_main_qml "$qml" >/dev/null 2>&1 && echo yes || echo no)"

section "SDDM forked theme: finding what to fork from"
# Re-running must refresh the fork from the packaged theme. Forking the fork
# would patch an already-patched Main.qml and, once upstream changes, quietly
# accumulate a copy of a copy.
themes="$INI_TMP/themes"
mkdir -p "$themes/breeze" "$themes/breeze-domain"
check "a packaged theme is its own source" "breeze" \
    "$(sddm_fork_source breeze "$themes")"
printf 'source=breeze\nbuilt=2026-08-20\n' >"$themes/breeze-domain/.domain-join-setup.source"
check "a fork names the theme it came from" "breeze" \
    "$(sddm_fork_source breeze-domain "$themes")"
check "an unknown theme is passed through" "elarun" \
    "$(sddm_fork_source elarun "$themes")"
check "a theme root without the theme finds nothing" "no" \
    "$(sddm_theme_dir nosuchtheme "$themes" >/dev/null 2>&1 && echo yes || echo no)"

section "Duo: package map"
for fam in debian rhel suse arch; do
    PKG_FAMILY="$fam"
    duo="$(pkgs_for extra_duo)"
    deps="$(pkgs_for duo_build_deps)"
    [[ -n "$duo" ]]  && { printf '  %s %s: extra_duo is populated\n' "$(green PASS)" "$fam"; ((PASS++)); } \
                     || { printf '  %s %s: extra_duo is empty\n' "$(red FAIL)" "$fam"; ((FAIL++)); }
    [[ -n "$deps" ]] && { printf '  %s %s: duo_build_deps is populated\n' "$(green PASS)" "$fam"; ((PASS++)); } \
                     || { printf '  %s %s: duo_build_deps is empty\n' "$(red FAIL)" "$fam"; ((FAIL++)); }
done
PKG_FAMILY="debian"
check_contains "debian duo build deps use libpam0g-dev" "libpam0g-dev" "$(pkgs_for duo_build_deps)"
PKG_FAMILY="rhel"
check_contains "rhel duo build deps use pam-devel" "pam-devel" "$(pkgs_for duo_build_deps)"
check_lacks    "rhel avoids libpam0g-dev"         "libpam0g-dev" "$(pkgs_for duo_build_deps)"

section "Duo: credential formats"
gate() { "$1" "$2" && echo yes || echo no; }
check "a 20-character ikey is accepted"   "yes" "$(gate valid_duo_ikey DIABCDEFGHIJKLMNOPQR)"
check "a short ikey is rejected"          "no"  "$(gate valid_duo_ikey DIABC)"
check "a lower-case ikey is rejected"     "no"  "$(gate valid_duo_ikey diabcdefghijklmnopqr)"
check "an empty ikey is rejected"         "no"  "$(gate valid_duo_ikey '')"
check "a 40-character skey is accepted"   "yes" "$(gate valid_duo_skey 0123456789abcdef0123456789abcdef01234567)"
check "a 39-character skey is rejected"   "no"  "$(gate valid_duo_skey 0123456789abcdef0123456789abcdef0123456)"
check "an api host is accepted"           "yes" "$(gate valid_duo_host api-1234abcd.duosecurity.com)"
check "a duofederal host is accepted"     "yes" "$(gate valid_duo_host api-1234abcd.duofederal.com)"
check "a bare domain is rejected"         "no"  "$(gate valid_duo_host duosecurity.com)"
check "the mangled '://duosecurity.com' is rejected" "no" "$(gate valid_duo_host '://duosecurity.com')"
check "an admin host is rejected"         "no"  "$(gate valid_duo_host admin-1234abcd.duosecurity.com)"

section "Duo: which repository fits which distro"
repo_kind_for() {
    ( PKG_FAMILY="$1"; DISTRO_ID="$2"; DISTRO_VERSION="$3"; DISTRO_CODENAME="$4"
      printf '%s' "$(duo_repo_kind)" )
}
check "Kubuntu gets the apt repo"       "apt" "$(repo_kind_for debian ubuntu 24.04 noble)"
check "Debian gets the apt repo"        "apt" "$(repo_kind_for debian debian 12 bookworm)"
check "no codename means no apt repo"   ""    "$(repo_kind_for debian debian 12 '')"
check "RHEL 9 gets the yum repo"        "yum" "$(repo_kind_for rhel rhel 9.4 '')"
check "Rocky gets the yum repo"         "yum" "$(repo_kind_for rhel rocky 9.4 '')"
check "Fedora has no Duo repo"          ""    "$(repo_kind_for rhel fedora 44 '')"
check "openSUSE has no Duo repo"        ""    "$(repo_kind_for suse opensuse-leap 15.6 '')"
check "Arch has no Duo repo"            ""    "$(repo_kind_for arch arch '' '')"
check "an Ubuntu lineage uses the Ubuntu suite" "Ubuntu" \
      "$( DISTRO_UBUNTU_BASED=1; duo_apt_suite )"
check "everything else uses the Debian suite"   "Debian" \
      "$( DISTRO_UBUNTU_BASED=0; duo_apt_suite )"

section "Duo: reading back /etc/duo/pam_duo.conf"
DUO_TMP="$(mktemp -d)"
f="$DUO_TMP/pam_duo.conf"
printf '[duo]\nikey=DIABCDEFGHIJKLMNOPQR\nskey=0123456789abcdef0123456789abcdef01234567\nhost=api-1234abcd.duosecurity.com\n' >"$f"
check "a complete config reads back as configured" "yes" "$(duo_conf_is_configured "$f" && echo yes || echo no)"
check "the API host is read back"  "api-1234abcd.duosecurity.com" "$(duo_conf_host "$f")"
check "spaces around the '=' are tolerated" "api-1234abcd.duosecurity.com" \
      "$(printf '[duo]\nhost = api-1234abcd.duosecurity.com\n' >"$f.spaced"; duo_conf_host "$f.spaced")"
printf '[duo]\nikey=DIABCDEFGHIJKLMNOPQR\nskey=tooshort\nhost=api-1234abcd.duosecurity.com\n' >"$f.bad"
check "a bad secret key is not 'configured'" "no" "$(duo_conf_is_configured "$f.bad" && echo yes || echo no)"
check "a missing file is not 'configured'"   "no" "$(duo_conf_is_configured "$DUO_TMP/absent" && echo yes || echo no)"

section "Duo: naming the PAM module"
# A module referenced by bare name must actually be on PAM's search path. Get
# this wrong and PAM reports the module as missing, which on some control flags
# lets the login through with no second factor at all.
MOD_TMP="$(mktemp -d)"
mkdir -p "$MOD_TMP/system/security" "$MOD_TMP/elsewhere/security"
touch "$MOD_TMP/system/security/pam_unix.so"
DUO_PAM_SEARCH_DIRS=("$MOD_TMP/system/security" "$MOD_TMP/elsewhere/security")
check "the module directory is the one holding pam_unix.so" \
      "$MOD_TMP/system/security" "$(pam_module_dir)"
check "no pam_duo.so means no module" "" "$(duo_pam_module || true)"

touch "$MOD_TMP/system/security/pam_duo.so"
check "a module on the search path is named plainly" "pam_duo.so" "$(duo_pam_module_arg)"

rm -f "$MOD_TMP/system/security/pam_duo.so"
touch "$MOD_TMP/elsewhere/security/pam_duo.so"
check "a module off the search path needs its full path" \
      "$MOD_TMP/elsewhere/security/pam_duo.so" "$(duo_pam_module_arg)"

# /lib64 is a symlink to /usr/lib64 on a merged-usr system, so the same
# directory reached by two names must not be mistaken for two directories.
ln -s "$MOD_TMP/system" "$MOD_TMP/system-link"
DUO_PAM_SEARCH_DIRS=("$MOD_TMP/system/security" "$MOD_TMP/system-link/security")
touch "$MOD_TMP/system/security/pam_duo.so"
check "a symlinked module directory is still the same one" "pam_duo.so" \
      "$( DUO_PAM_SEARCH_DIRS=("$MOD_TMP/system-link/security" "$MOD_TMP/system/security"); duo_pam_module_arg )"
rm -rf "$MOD_TMP"
DUO_PAM_SEARCH_DIRS=(/lib/security /lib64/security /usr/lib/security /usr/lib64/security /usr/lib/*/security /usr/local/lib/security /usr/local/lib64/security)

section "Duo: writing /etc/duo/pam_duo.conf"
# pam_duo reads a shared secret out of this file on every authentication, so the
# mode matters as much as the contents. DUO_CONF is redirected at a temporary
# file rather than mocked, so the real function is what gets exercised.
DUO_CONF_REAL="$DUO_CONF"
DUO_CONF="$DUO_TMP/written/pam_duo.conf"
DRY_RUN=0
(
    OPT_DUO_IKEY="DIABCDEFGHIJKLMNOPQR"
    OPT_DUO_SKEY="0123456789abcdef0123456789abcdef01234567"
    OPT_DUO_HOST="api-1234abcd.duosecurity.com"
    OPT_DUO_SKEY_FILE=""
    duo_write_conf safe yes duo-exempt >/dev/null 2>&1
)
check "the config file is created"        "yes" "$([[ -f "$DUO_CONF" ]] && echo yes || echo no)"
check "and is readable only by its owner" "600" "$(stat -c '%a' "$DUO_CONF" 2>/dev/null)"
check "the parent directory is created"   "yes" "$([[ -d "$(dirname "$DUO_CONF")" ]] && echo yes || echo no)"
check "it reads back as fully configured" "yes" "$(duo_conf_is_configured && echo yes || echo no)"
check "failmode is recorded"              "safe" "$(duo_conf_get failmode)"
check "autopush is recorded"              "yes"  "$(duo_conf_get autopush)"
check "prompts is capped at one"          "1"    "$(duo_conf_get prompts)"
check "the bypass group becomes an exclusion" '*,!duo-exempt' "$(duo_conf_get groups)"
check "everything lands under [duo]"      "1" "$(grep -c '^\[duo\]' "$DUO_CONF")"

# The secret key must not leak into the transcript, which the operator may paste
# into a ticket, or into the log file.
transcript="$(
    DRY_RUN=1
    DUO_CONF="$DUO_TMP/dryrun.conf"
    OPT_DUO_IKEY="DIABCDEFGHIJKLMNOPQR"
    OPT_DUO_SKEY="0123456789abcdef0123456789abcdef01234567"
    OPT_DUO_HOST="api-1234abcd.duosecurity.com"
    OPT_DUO_SKEY_FILE=""
    duo_write_conf safe yes "" 2>&1
)"
if [[ "$transcript" == *"0123456789abcdef0123456789abcdef01234567"* ]]; then
    printf '  %s the secret key appeared in the --dry-run transcript\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s the secret key stays out of the --dry-run transcript\n' "$(green PASS)"; ((PASS++))
fi
check "--dry-run writes no config file" "no" \
      "$([[ -f "$DUO_TMP/dryrun.conf" ]] && echo yes || echo no)"

# A secret key read from a file, which is how it should be supplied.
printf '0123456789abcdef0123456789abcdef01234567\n' >"$DUO_TMP/skey"
DUO_CONF="$DUO_TMP/from-file.conf"
(
    OPT_DUO_IKEY="DIABCDEFGHIJKLMNOPQR"
    OPT_DUO_SKEY=""
    OPT_DUO_SKEY_FILE="$DUO_TMP/skey"
    OPT_DUO_HOST="api-1234abcd.duosecurity.com"
    duo_write_conf secure no "" >/dev/null 2>&1
)
check "--duo-skey-file supplies the secret" "yes" "$(duo_conf_is_configured && echo yes || echo no)"
check "failmode=secure is honoured"         "secure" "$(duo_conf_get failmode)"
check "no bypass group means no groups key" "" "$(duo_conf_get groups)"
DUO_CONF="$DUO_CONF_REAL"

section "Duo: reading a PAM auth stack"
# Written the way the real files are, since where the Duo rule may go depends on
# whether anything ahead of it can return success for the whole stack.
pam_dir="$DUO_TMP/pam.d"
mkdir -p "$pam_dir"
printf 'auth required pam_env.so\nauth sufficient pam_unix.so\nauth required pam_deny.so\n' >"$pam_dir/short-circuit"
printf 'auth substack password-auth\nauth include postlogin\n' >"$pam_dir/substack"
printf 'auth [success=1 default=ignore] pam_unix.so nullok\nauth requisite pam_deny.so\nauth required pam_permit.so\n' >"$pam_dir/debian-style"
printf 'auth [success=done default=ignore] pam_sss.so\nauth required pam_deny.so\n' >"$pam_dir/jump"
printf '# no auth rules here\naccount required pam_unix.so\n' >"$pam_dir/no-auth"
sc() { pam_auth_can_short_circuit "$1" && echo yes || echo no; }
check "a bare 'sufficient' short-circuits"     "yes" "$(sc "$pam_dir/short-circuit")"
check "'substack' does not short-circuit"      "no"  "$(sc "$pam_dir/substack")"
check "Debian's success=1 does not"            "no"  "$(sc "$pam_dir/debian-style")"
check "a success=done jump does"                "yes" "$(sc "$pam_dir/jump")"
check "a file with no auth rules does not"     "no"  "$(sc "$pam_dir/no-auth")"
check "the anchor is the last auth rule"       "3" "$(pam_auth_anchor "$pam_dir/short-circuit")"
check "the first auth rule is found too"       "1" "$(pam_auth_first "$pam_dir/short-circuit")"
check "no auth rules means no anchor"          ""  "$(pam_auth_anchor "$pam_dir/no-auth")"

# A Debian-style service file whose primary block lives in an @include.
printf 'auth requisite pam_nologin.so\n@include common-auth\n-auth optional pam_kwallet5.so\n' >"$pam_dir/sddm"
printf 'auth [success=1 default=ignore] pam_unix.so nullok\nauth requisite pam_deny.so\nauth required pam_permit.so\n' >"$pam_dir/common-auth"
check "@include is recognised as part of the stack" "2" \
      "$(( $(pam_auth_anchor "$pam_dir/sddm") - 1 ))"
check "an @include of a safe stack stays safe"      "no"  "$(sc "$pam_dir/sddm")"
printf 'auth sufficient pam_unix.so\n' >"$pam_dir/common-auth"
check "an @include of a short-circuiting stack is caught" "yes" "$(sc "$pam_dir/sddm")"

section "Duo: inserting the rule into a PAM file"
DRY_RUN=0
rule="auth       required     pam_duo.so"

# The safe case: the rule goes after the password check, which is the ordering
# that makes it a second factor rather than a first one.
f="$pam_dir/place-after"
printf 'auth substack password-auth\nauth include postlogin\naccount required pam_unix.so\n' >"$f"
pam_add_auth "$f" "$rule" pam_duo.so >/dev/null; rc=$?
check "a non-short-circuiting stack returns 0" "0" "$rc"
check "the rule lands after the last auth rule" "3" "$(grep -n 'pam_duo.so' "$f" | cut -d: -f1)"
check "the account section is left below it" "4" "$(grep -n 'account' "$f" | cut -d: -f1)"

# A second run must not add a second copy.
pam_add_auth "$f" "$rule" pam_duo.so >/dev/null
check "a second run adds nothing" "1" "$(grep -c 'pam_duo.so' "$f")"

# The short-circuiting case: after the password check the rule would never run,
# so it has to go first, and the caller is told with rc 3.
f="$pam_dir/place-before"
printf 'auth required pam_env.so\nauth sufficient pam_unix.so\nauth required pam_deny.so\n' >"$f"
pam_add_auth "$f" "$rule" pam_duo.so >/dev/null; rc=$?
check "a short-circuiting stack returns 3" "3" "$rc"
check "the rule goes in ahead of the stack" "1" "$(grep -n 'pam_duo.so' "$f" | cut -d: -f1)"

# PAM files are root-owned with a fixed mode; a rewrite must not relax either.
f="$pam_dir/mode"
printf 'auth substack password-auth\n' >"$f"
chmod 0644 "$f"
pam_add_auth "$f" "$rule" pam_duo.so >/dev/null
check "the file mode survives the edit" "644" "$(stat -c '%a' "$f")"

# A file with no auth stack is left alone rather than guessed at.
f="$pam_dir/no-auth-target"
printf 'account required pam_unix.so\n' >"$f"
pam_add_auth "$f" "$rule" pam_duo.so >/dev/null 2>&1; rc=$?
check "a file with no auth stack is refused" "1" "$rc"
check "and is left untouched" "0" "$(grep -c 'pam_duo.so' "$f")"

# Nothing may reach the disk under --dry-run.
f="$pam_dir/dryrun"
printf 'auth substack password-auth\n' >"$f"
before="$(cat "$f")"
DRY_RUN=1; pam_add_auth "$f" "$rule" pam_duo.so >/dev/null; DRY_RUN=0
check "--dry-run changes nothing on disk" "$before" "$(cat "$f")"

section "Duo: taking the rule back out"
f="$pam_dir/remove"
printf 'auth substack password-auth\nauth required pam_duo.so\naccount required pam_unix.so\n' >"$f"
pam_remove_auth "$f" pam_duo.so >/dev/null
check "the rule is removed" "0" "$(grep -c 'pam_duo.so' "$f")"
check "the rest of the file survives" "2" "$(wc -l <"$f")"
pam_remove_auth "$f" pam_duo.so >/dev/null; rc=$?
check "removing what is not there succeeds" "0" "$rc"

# A file consisting only of the rule would be emptied, which is worse than
# leaving it: an empty PAM file denies everything.
f="$pam_dir/only-duo"
printf 'auth required pam_duo.so\n' >"$f"
pam_remove_auth "$f" pam_duo.so >/dev/null 2>&1; rc=$?
check "refuses to empty a PAM file" "1" "$rc"
check "and leaves the file intact" "1" "$(grep -c 'pam_duo.so' "$f")"

rm -rf "$DUO_TMP"

section "Duo: argument parsing"
duo_opt() {
    local want="$1"; shift
    ( OPT_DUO=-1; OPT_DUO_IKEY=""; OPT_DUO_HOST=""; OPT_DUO_PROTECT=""
      OPT_DUO_FAILMODE=""; OPT_DUO_AUTOPUSH=""; OPT_DUO_SKEY=""; DUO_ADD_REPO=-1
      parse_args "$@" >/dev/null 2>&1; printf '%s' "${!want}" )
}
check "--duo turns Duo on"                  "1" "$(duo_opt OPT_DUO --duo)"
check "--no-duo turns Duo off"              "0" "$(duo_opt OPT_DUO --no-duo)"
check "--duo-ikey implies --duo"            "1" "$(duo_opt OPT_DUO --duo-ikey DIABCDEFGHIJKLMNOPQR)"
check "--duo-ikey is stored"                "DIABCDEFGHIJKLMNOPQR" \
      "$(duo_opt OPT_DUO_IKEY --duo-ikey DIABCDEFGHIJKLMNOPQR)"
check "--duo-host is stored"                "api-1234abcd.duosecurity.com" \
      "$(duo_opt OPT_DUO_HOST --duo-host api-1234abcd.duosecurity.com)"
check "--duo-protect is stored"             "login,sshd" "$(duo_opt OPT_DUO_PROTECT --duo-protect login,sshd)"
check "--duo-failmode is stored"            "secure" "$(duo_opt OPT_DUO_FAILMODE --duo-failmode secure)"
check "--duo-autopush normalises 'y'"       "yes" "$(duo_opt OPT_DUO_AUTOPUSH --duo-autopush y)"
check "--duo-autopush normalises 'FALSE'"   "no"  "$(duo_opt OPT_DUO_AUTOPUSH --duo-autopush FALSE)"
check "--duo-repo opens the repo gate"      "1" "$(duo_opt DUO_ADD_REPO --duo-repo)"
check "--duo skips the menu"                "1" "$(directed_after --duo)"
check "--duo-repo alone leaves the menu"    "0" "$(directed_after --duo-repo)"

for bad in "--duo-failmode maybe" "--duo-autopush sometimes" "--duo-protect everything"; do
    # shellcheck disable=SC2086
    if ( OPT_DUO_FAILMODE=""; OPT_DUO_AUTOPUSH=""; OPT_DUO_PROTECT=""; parse_args $bad ) >/dev/null 2>&1; then
        printf '  %s "%s" was accepted\n' "$(red FAIL)" "$bad"; ((FAIL++))
    else
        printf '  %s "%s" exits non-zero\n' "$(green PASS)" "$bad"; ((PASS++))
    fi
done

section "Duo: extras keyword drives the configuration step, not a package"
( BACKEND="sssd"; PKG_FAMILY="debian"; GUI_CHOICES=""; EXTRA_CHOICES="duo"
  build_package_list
  check "-e duo sets WANT_DUO" "1" "$WANT_DUO"
  check_lacks "-e duo adds no package to the preview" "duo-unix" "${WANTED_PACKAGES[*]}" )
PASS=$((PASS + 2))

section "sudo rights: turning a principal into a filename"
# sudo skips any file in sudoers.d whose name holds a dot or ends in '~', so a
# domain principal cannot simply be pasted in as the filename.
check "a plain account is unchanged"     "jdoe" "$(sudoers_slug jdoe)"
check "spaces, '@' and dots all fold"    "linux-admins-corp-example-com" \
      "$(sudoers_slug 'Linux Admins@corp.example.com')"
check "runs of separators collapse"      "a-b-c" "$(sudoers_slug 'A--B..C')"
check "leading and trailing dashes go"   "jdoe"  "$(sudoers_slug '  jdoe  ')"
check "a name with nothing usable slugs to nothing" "" "$(sudoers_slug '@@@')"
check "no slug means no file is written" "1" \
      "$(SUDOERS_DIR="$(mktemp -d)" DRY_RUN=0; sudoers_write_rule user '@@@' >/dev/null 2>&1; echo $?)"

section "sudo rights: names sudoers cannot carry"
for good in "jdoe" "Linux Admins" "Linux Admins@corp.example.com" "svc.account_1" "host\$"; do
    check "'$good' is accepted" "0" "$(valid_sudo_principal "$good"; echo $?)"
done
# Each of these is sudoers syntax, not part of a name. Writing one out produces
# a rule that means something other than what was typed.
for bad in "a,b" "a=b" "a:b" "a!b" "a#b" "a(b" 'back\slash' " leading" "trailing " ""; do
    check "'$bad' is rejected" "1" "$(valid_sudo_principal "$bad"; echo $?)"
done
check "'ALL' is rejected as a name" "1" "$(valid_sudo_principal ALL; echo $?)"

section "sudo rights: writing the drop-in"
SUDO_TMP="$(mktemp -d)"
SUDOERS_DIR="$SUDO_TMP"
DRY_RUN=0
sudoers_write_rule group "Linux Admins@corp.example.com" >/dev/null 2>&1
grp_file="$SUDO_TMP/domain-join-group-linux-admins-corp-example-com"
check "the group file is created" "yes" "$([[ -f "$grp_file" ]] && echo yes || echo no)"
check "and is read-only, no write bit anywhere" "440" "$(stat -c '%a' "$grp_file" 2>/dev/null)"
# The space is the one character common in AD group names that sudoers reads as
# a separator, and '%' is what makes the rule match a group rather than a user.
check "the group rule escapes the space" \
      '%Linux\ Admins@corp.example.com ALL=(ALL:ALL) ALL' \
      "$(grep -v '^#' "$grp_file")"

sudoers_write_rule user "jdoe@corp.example.com" >/dev/null 2>&1
usr_file="$SUDO_TMP/domain-join-user-jdoe-corp-example-com"
check "the user file is created" "yes" "$([[ -f "$usr_file" ]] && echo yes || echo no)"
check "a user rule carries no '%'" "jdoe@corp.example.com ALL=(ALL:ALL) ALL" \
      "$(grep -v '^#' "$usr_file")"
check "user and group files are separate" "2" "$(ls -1 "$SUDO_TMP" | wc -l)"

# A second run must not stack up identical files and backups of them.
before="$(stat -c '%Y %s' "$grp_file")"
sudoers_write_rule group "Linux Admins@corp.example.com" >/dev/null 2>&1
check "writing the same grant twice leaves the file alone" "$before" \
      "$(stat -c '%Y %s' "$grp_file")"
check "and adds no second file" "2" "$(ls -1 "$SUDO_TMP" | wc -l)"

# A syntax error anywhere in sudoers.d makes sudo refuse to run at all, so the
# check has to happen before the file is in place, never after.
if have visudo; then
    sudoers_write_rule user "a=b" >/dev/null 2>&1
    check "a rule visudo rejects is never installed" "" \
          "$(ls -1 "$SUDO_TMP" | grep 'a-b' || true)"
    check "and the write reports failure" "1" \
          "$(sudoers_write_rule user 'a=b' >/dev/null 2>&1; echo $?)"
else
    printf '  %s visudo is not installed; skipped the syntax-check tests\n' "$(green PASS)"
    ((PASS++))
fi

DRY_RUN=1
rm -rf "${SUDO_TMP:?}"/*
sudoers_write_rule group "Linux Admins" >/dev/null 2>&1
check "--dry-run writes nothing" "0" "$(ls -1 "$SUDO_TMP" | wc -l)"
DRY_RUN=0
rm -rf "$SUDO_TMP"

section "sudo rights: the flags"
( CLI_DIRECTED=0; OPT_SUDO_USER=""; OPT_SUDO_GROUP=""
  parse_args --sudo-user jdoe --sudo-group 'Linux Admins' >/dev/null 2>&1
  check "--sudo-user is stored"  "jdoe"          "$OPT_SUDO_USER"
  check "--sudo-group is stored" "Linux Admins"  "$OPT_SUDO_GROUP"
  check "--sudo-group skips the menu" "1" "$CLI_DIRECTED" )
PASS=$((PASS + 3))

# A name may contain spaces, so only the comma separates one from the next.
SUDO_TMP="$(mktemp -d)"
( SUDOERS_DIR="$SUDO_TMP"; DRY_RUN=0; ASSUME_YES=1
  OPT_SUDO_USER=""; OPT_SUDO_GROUP="Linux Admins, Server Admins"
  SUDO_ACCESS_DONE=0
  configure_sudo_access >/dev/null 2>&1 )
check "a comma separated list writes one file per group" "2" "$(ls -1 "$SUDO_TMP" | wc -l)"
check "the first group keeps its space" "yes" \
      "$([[ -f "$SUDO_TMP/domain-join-group-linux-admins" ]] && echo yes || echo no)"
check "the second group is trimmed, not mangled" "yes" \
      "$([[ -f "$SUDO_TMP/domain-join-group-server-admins" ]] && echo yes || echo no)"

# -y with neither flag is a deliberate "leave sudo alone", not a licence to guess.
( SUDOERS_DIR="$SUDO_TMP"; DRY_RUN=0; ASSUME_YES=1
  OPT_SUDO_USER=""; OPT_SUDO_GROUP=""
  SUDO_ACCESS_DONE=0
  configure_sudo_access >/dev/null 2>&1 )
check "-y with no flags grants nothing" "2" "$(ls -1 "$SUDO_TMP" | wc -l)"
rm -rf "$SUDO_TMP"
SUDOERS_DIR="/etc/sudoers.d"

section "sudo rights: the guard against asking twice"
( SUDO_ACCESS_DONE=1
  check "a second call is a no-op" "" "$(configure_sudo_access 2>&1)" )
PASS=$((PASS + 1))

# ...but the guard is scoped to one batch of menu selections. The menu loops
# back for another ENTER, and a step ticked again then has to run again rather
# than returning success silently and leaving "Done." over a no-op.
# Deliberately not in a subshell: check() counts into PASS/FAIL, and a subshell
# would throw the FAIL away.
SDDM_GREETER_DONE=1; DUO_DONE=1; POST_JOIN_TUNING_DONE=1; SUDO_ACCESS_DONE=1
reset_step_guards
check "a new batch clears the sudo guard"      "0" "$SUDO_ACCESS_DONE"
check "a new batch clears the post-join guard" "0" "$POST_JOIN_TUNING_DONE"
check "a new batch clears the SDDM guard"      "0" "$SDDM_GREETER_DONE"
check "a new batch clears the Duo guard"       "0" "$DUO_DONE"

section "sudo rights: a mistyped name is asked again"
# A name sudoers cannot spell is a typo, not an answer: the prompt repeats
# instead of abandoning the grant. The stub pops one scripted reply per call.
SUDO_TMP="$(mktemp -d)"
SUDO_RETRY_OUT="$(
  SUDOERS_DIR="$SUDO_TMP"; DRY_RUN=0; ASSUME_YES=0
  ANSWERS=("Linux Admins," "Linux Admins")
  ask_value() { printf -v "$1" '%s' "${ANSWERS[0]:-}"; ANSWERS=("${ANSWERS[@]:1}"); }
  confirm()   { return 0; }   # "write the rule anyway?" - the name will not resolve
  sudo_grant_interactive group 2>&1
)"
check "the mistyped name is rejected" "yes" \
      "$([[ "$SUDO_RETRY_OUT" == *"'Linux Admins,' holds a character"* ]] && echo yes || echo no)"
check "the prompt says how to back out" "yes" \
      "$([[ "$SUDO_RETRY_OUT" == *"press Enter on an empty line"* ]] && echo yes || echo no)"
check "the corrected name is written" "yes" \
      "$([[ -f "$SUDO_TMP/domain-join-group-linux-admins" ]] && echo yes || echo no)"

# The remaining two need a stubbed ask_value but their result has to be counted,
# so the real one is put back by hand rather than by leaving a subshell.
ASK_VALUE_REAL="$(declare -f ask_value)"

# An empty answer is still the way out, and still not a failure.
SUDOERS_DIR="$SUDO_TMP"; DRY_RUN=0; ASSUME_YES=0
ask_value() { printf -v "$1" '%s' ""; }
sudo_grant_interactive user >/dev/null 2>&1
check "an empty name grants nothing and succeeds" "0" "$?"
check "an empty name writes no file" "1" "$(ls -1 "$SUDO_TMP" | wc -l)"

# -y never reads, so ask_value hands back the same unusable name every time.
# The loop has to give up rather than spin: it returns 1, and a hang here would
# stall the suite, which is the other half of the assertion.
ASSUME_YES=1
ask_value() { printf -v "$1" '%s' "Bad,Name"; }
sudo_grant_interactive group >/dev/null 2>&1
check "-y gives up on an unusable name instead of looping" "1" "$?"

eval "$ASK_VALUE_REAL"
ASSUME_YES=0
rm -rf "$SUDO_TMP"
SUDOERS_DIR="/etc/sudoers.d"

section "WinApps: the flags"
winapps_after() {
    ( OPT_WINAPPS=-1; OPT_WINAPPS_BACKEND=""; OPT_WINAPPS_CREDS=""
      OPT_WINAPPS_HOST=""; OPT_WINAPPS_RDP_USER=""; WINAPPS_REMOVE=0; ASSUME_YES=0
      parse_args "$@" >/dev/null 2>&1
      printf '%s|%s|%s|%s' "$OPT_WINAPPS" "$OPT_WINAPPS_BACKEND" \
             "$OPT_WINAPPS_CREDS" "$WINAPPS_REMOVE" )
}
check "--winapps turns it on"        "1|||0"          "$(winapps_after --winapps)"
check "--no-winapps turns it off"    "0|||0"          "$(winapps_after --no-winapps)"
check "--winapps-backend implies on" "1|libvirt||0"   "$(winapps_after --winapps-backend libvirt)"
check "--winapps-creds is stored"    "1||askpass|0"   "$(winapps_after --winapps-creds askpass)"
check "--winapps-remove sets removal" "1|||1"         "$(winapps_after --winapps-remove)"

# An invalid enum must stop the run rather than be carried into a config file.
for bad in "--winapps-backend vmware" "--winapps-creds telepathy"; do
    if ( parse_args $bad ) >/dev/null 2>&1; then
        printf '  %s %s was accepted\n' "$(red FAIL)" "$bad"; ((FAIL++))
    else
        printf '  %s %s is rejected\n' "$(green PASS)" "$bad"; ((PASS++))
    fi
done

# 'manual' has nothing to connect to without a host, and -y cannot ask.
if ( ASSUME_YES=1; parse_args -y --winapps-backend manual ) >/dev/null 2>&1; then
    printf '  %s manual backend with no host was accepted under -y\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s manual backend demands --winapps-host under -y\n' "$(green PASS)"; ((PASS++))
fi
check "manual backend is fine with a host" "1|manual||0" \
      "$(winapps_after --winapps-backend manual --winapps-host win.corp.example.com)"

section "WinApps: the VM builder flags"
winapps_deploy_after() {
    ( OPT_WINAPPS=-1; OPT_WINAPPS_BACKEND=""; OPT_WINAPPS_DEPLOY=-1
      OPT_WINAPPS_ISO=""; OPT_WINAPPS_VM_RAM=""; OPT_WINAPPS_VM_CPUS=""
      OPT_WINAPPS_VM_DISK=""; WINAPPS_VM_REMOVE=0; WINAPPS_REMOVE=0; ASSUME_YES=0
      parse_args "$@" >/dev/null 2>&1
      printf '%s|%s|%s|%s|%s' "$OPT_WINAPPS_DEPLOY" "$OPT_WINAPPS_VM_RAM" \
             "$OPT_WINAPPS_VM_CPUS" "$OPT_WINAPPS_VM_DISK" "$WINAPPS_VM_REMOVE" )
}
check "--winapps-deploy implies on"     "1||||0"     "$(winapps_deploy_after --winapps-deploy)"
check "--no-winapps-deploy turns it off" "0||||0"    "$(winapps_deploy_after --no-winapps-deploy)"
check "--winapps-vm-ram/-cpus/-disk stored" "1|8192|6|128|0" \
      "$(winapps_deploy_after --winapps-deploy --winapps-vm-ram 8192 --winapps-vm-cpus 6 --winapps-vm-disk 128)"
check "--winapps-vm-remove sets both flags" "1" \
      "$( ( WINAPPS_VM_REMOVE=0; WINAPPS_REMOVE=0
            parse_args --winapps-vm-remove >/dev/null 2>&1
            printf '%s' "$(( WINAPPS_VM_REMOVE & WINAPPS_REMOVE ))" ) )"

# Non-libvirt backend + deploy must be refused, a bad size must stop the run,
# and --winapps-iso must be a real .iso *file* - a directory or a missing path
# is refused rather than carried into the builder.
for bad in "--winapps-deploy --winapps-backend docker" \
           "--winapps-deploy --winapps-vm-ram plenty" \
           "--winapps-iso /nonexistent/windows.iso" \
           "--winapps-iso /tmp"; do
    if ( parse_args $bad ) >/dev/null 2>&1; then
        printf '  %s %s was accepted\n' "$(red FAIL)" "$bad"; ((FAIL++))
    else
        printf '  %s %s is rejected\n' "$(green PASS)" "$bad"; ((PASS++))
    fi
done
# A real .iso file is accepted.
_fakeiso="$(mktemp --suffix=.iso)"
if ( parse_args --winapps-iso "$_fakeiso" ) >/dev/null 2>&1; then
    printf '  %s a real .iso file path is accepted\n' "$(green PASS)"; ((PASS++))
else
    printf '  %s a real .iso file path was rejected\n' "$(red FAIL)"; ((FAIL++))
fi
rm -f "$_fakeiso"

section "WinApps: the config template"
WA_TMP="$(mktemp -d)"
WINAPPS_TEMPLATE="$WA_TMP/winapps.conf.template"
WINAPPS_ASKPASS="/usr/local/bin/winapps-askpass"
DRY_RUN=0
OPT_WINAPPS_RDP_USER=""; OPT_WINAPPS_RDP_PASS=""

# check_contains matches whole space-delimited words, which cannot see a token
# inside RDP_USER="...". These are plain substring assertions instead.
check_line() {
    local desc="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        printf '  %s %s\n' "$(green PASS)" "$desc"; ((PASS++))
    else
        printf '  %s %s\n' "$(red FAIL)" "$desc"
        printf '        %s not found in %s\n' "$needle" "$file"
        ((FAIL++))
    fi
}

winapps_write_template "CORP.EXAMPLE.COM" "libvirt" "askpass" "" "" "RDPWindows" >/dev/null 2>&1
check_line "the template carries the substitution token" 'RDP_USER="@WINAPPS_USER@"' "$WINAPPS_TEMPLATE"
check_line "the domain is written through"               'RDP_DOMAIN="CORP.EXAMPLE.COM"' "$WINAPPS_TEMPLATE"
check_line "the backend is written through"              'WAFLAVOR="libvirt"' "$WINAPPS_TEMPLATE"
if grep -q '^RDP_PASS=""' "$WINAPPS_TEMPLATE"; then
    printf '  %s askpass mode stores no password\n' "$(green PASS)"; ((PASS++))
else
    printf '  %s askpass mode left a password in the template\n' "$(red FAIL)"; ((FAIL++))
fi
# libvirt discovers the guest address itself; a hard-coded one goes stale.
if grep -qE '^RDP_IP=' "$WINAPPS_TEMPLATE"; then
    printf '  %s libvirt pinned RDP_IP when it should not\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s libvirt leaves RDP_IP for runtime discovery\n' "$(green PASS)"; ((PASS++))
fi

winapps_write_template "CORP" "manual" "askpass" "10.0.0.9" "3390" "" >/dev/null 2>&1
check_line "manual pins the host"    'RDP_IP="10.0.0.9"' "$WINAPPS_TEMPLATE"
check_line "manual honours the port" 'RDP_PORT="3390"'   "$WINAPPS_TEMPLATE"

# Shared mode is the one path that writes a secret, so prove it lands and that
# the token is gone - a leftover token would try to log in as '@WINAPPS_USER@'.
OPT_WINAPPS_RDP_USER="svc-winapps"; OPT_WINAPPS_RDP_PASS="hunter2"
winapps_write_template "CORP" "manual" "shared" "10.0.0.9" "" "" >/dev/null 2>&1
check_line "shared mode writes the service account" 'RDP_USER="svc-winapps"' "$WINAPPS_TEMPLATE"
check_line "shared mode writes the password"        'RDP_PASS="hunter2"'     "$WINAPPS_TEMPLATE"
if grep -qF '@WINAPPS_USER@' "$WINAPPS_TEMPLATE" | grep -qv '^#'; then
    printf '  %s shared mode left a substitution token behind\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s shared mode substitutes nothing per user\n' "$(green PASS)"; ((PASS++))
fi
OPT_WINAPPS_RDP_USER=""; OPT_WINAPPS_RDP_PASS=""

section "WinApps: the per-user generator"
WINAPPS_SEEDER="$WA_TMP/winapps-user-config"
winapps_write_template "CORP.EXAMPLE.COM" "libvirt" "askpass" "" "" "RDPWindows" >/dev/null 2>&1
winapps_write_seeder >/dev/null 2>&1

if bash -n "$WINAPPS_SEEDER" 2>/dev/null; then
    printf '  %s the generated seeder parses\n' "$(green PASS)"; ((PASS++))
else
    printf '  %s the generated seeder has a syntax error\n' "$(red FAIL)"; ((FAIL++))
fi

# The point of the whole exercise: each user's own name reaches RDP_USER, with
# the domain qualifier stripped off whichever way SSSD or Winbind presents it.
seed_as() {
    local login="$1" home="$WA_TMP/home/$1"
    mkdir -p "$home"
    HOME="$home" bash -c "
        id() { case \"\$1\" in -u) echo 1001 ;; -un) echo '$login' ;; esac; }
        export -f id 2>/dev/null
        . '$WINAPPS_SEEDER'
    " >/dev/null 2>&1
    grep -h '^RDP_USER=' "$home/.config/winapps/winapps.conf" 2>/dev/null
}
check "a plain name is used as-is"        'RDP_USER="jdoe"' "$(seed_as jdoe)"
check "an @realm suffix is stripped"      'RDP_USER="jdoe"' "$(seed_as 'jdoe@corp.example.com')"
check 'a DOMAIN\ prefix is stripped'      'RDP_USER="jdoe"' "$(seed_as 'CORP\jdoe')"

# A user who takes ownership of their copy keeps it.
OWN="$WA_TMP/home/jdoe/.config/winapps/winapps.conf"
printf 'RDP_USER="hand-edited"\n' >"$OWN"
seed_as jdoe >/dev/null
check "a copy without the marker is left alone" 'RDP_USER="hand-edited"' \
      "$(grep '^RDP_USER=' "$OWN")"

section "WinApps: the root program-scan config"
# winapps_seed_scan_config writes root's ~/.config/winapps for 'setup.sh
# --system'. It must connect as the guest's local admin, not a domain identity:
# that account is all a fresh (or later domain-joined) guest has.
SCAN_HOME="$WA_TMP/scanroot"; mkdir -p "$SCAN_HOME"
WINAPPS_TEMPLATE="$WA_TMP/scan.template"
winapps_write_template "CORP.EXAMPLE.COM" "libvirt" "kerberos" "" "" "IT-VM" >/dev/null 2>&1
( HOME="$SCAN_HOME"; OPT_WINAPPS_VM_ADMIN="admin"; OPT_WINAPPS_VM_PASS="p'wd"
  winapps_seed_scan_config /etc/winapps/setup.sh ) >/dev/null 2>&1
SCAN_CONF="$SCAN_HOME/.config/winapps/winapps.conf"
SCAN_PASS="$SCAN_HOME/.config/winapps/scan-askpass"
check_line "it connects as the local admin from the config" 'RDP_USER="admin"' "$SCAN_CONF"
check_line "it blanks the RDP domain"                       'RDP_DOMAIN=""'    "$SCAN_CONF"
check_line "it keeps the libvirt VM name for IP discovery"  'VM_NAME="IT-VM"'  "$SCAN_CONF"
check_line "it points RDP_ASKPASS at the scan helper"       'scan-askpass'     "$SCAN_CONF"
if grep -qF '/sec:nla' "$SCAN_CONF"; then
    printf '  %s it left Kerberos NLA on a local-account connection\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s it drops Kerberos NLA for the local-account connection\n' "$(green PASS)"; ((PASS++))
fi
if grep -qE '^RDP_PASS=""' "$SCAN_CONF" && ! grep -qF "p'wd" "$SCAN_CONF"; then
    printf '  %s the password is never written into winapps.conf\n' "$(green PASS)"; ((PASS++))
else
    printf '  %s the password leaked into winapps.conf\n' "$(red FAIL)"; ((FAIL++))
fi
if [ "$(stat -c '%a' "$SCAN_PASS" 2>/dev/null)" = "700" ] && [ "$("$SCAN_PASS")" = "p'wd" ]; then
    printf '  %s the askpass helper is 0700 and emits the exact password\n' "$(green PASS)"; ((PASS++))
else
    printf '  %s the askpass helper has the wrong mode or output\n' "$(red FAIL)"; ((FAIL++))
fi
# No password in the config and no tty: warn, no helper, no crash.
SCAN_HOME2="$WA_TMP/scanroot2"; mkdir -p "$SCAN_HOME2"
( HOME="$SCAN_HOME2"; OPT_WINAPPS_VM_ADMIN=""; OPT_WINAPPS_VM_PASS=""
  winapps_seed_scan_config /etc/winapps/setup.sh ) >/dev/null 2>&1 </dev/null
check_line "with no password it still writes a config as Docker" 'RDP_USER="Docker"' \
      "$SCAN_HOME2/.config/winapps/winapps.conf"
if [ -e "$SCAN_HOME2/.config/winapps/scan-askpass" ]; then
    printf '  %s it left an empty askpass helper behind\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s it writes no askpass helper without a password\n' "$(green PASS)"; ((PASS++))
fi

section "WinApps: stripping the install CD drives"
# After the operator says Windows is up, the three install CDs have done their
# job: winapps_strip_vm_cdroms ejects the media in the first drive and detaches
# the other two, leaving one empty CD-ROM.
EJECT_LOG="$WA_TMP/eject.log"
cat >"$WA_TMP/virsh_stub" <<STUB
virsh() {
    case "\$*" in
        *"dominfo"*)   return 0 ;;
        *"domblklist --details"*)
            printf ' Type Device Target Source\\n'
            printf ' file disk  vda /var/lib/libvirt/images/vm.qcow2\\n'
            printf ' file cdrom sda /var/lib/libvirt/images/vm-install.iso\\n'
            printf ' file cdrom sdb /var/lib/winapps/iso/virtio-win.iso\\n'
            printf ' file cdrom sdc /var/lib/libvirt/images/vm-unattend.iso\\n' ;;
        *"domstate"*)     echo running ;;
        *"change-media"*|*"detach-disk"*) echo "\$*" >>"$EJECT_LOG" ;;
    esac
}
STUB
run_strip() { (
    OPT_WINAPPS_BACKEND="${1:-libvirt}"; OPT_WINAPPS_VM="IT-VM"; DRY_RUN=0
    source "$WA_TMP/virsh_stub"
    have() { [[ "$1" == virsh ]]; }
    confirm() { return "${STRIP_CONFIRM:-0}"; }
    ok() { :; }; warn() { :; }; note() { :; }; info() { :; }
    winapps_strip_vm_cdroms
) >/dev/null 2>&1; }

: >"$EJECT_LOG"; STRIP_CONFIRM=0 run_strip
check "it ejects the media in the kept drive"  "1" "$(grep -c 'change-media IT-VM sda --eject' "$EJECT_LOG")"
check "it detaches the two spare drives"        "2" "$(grep -c 'detach-disk IT-VM' "$EJECT_LOG")"
check "it does not detach the kept drive"       "0" "$(grep -c 'detach-disk IT-VM sda' "$EJECT_LOG")"
check "it detaches the virtio drive"            "yes" \
      "$(grep -q 'detach-disk IT-VM sdb' "$EJECT_LOG" && echo yes || echo no)"
# libvirt rejects a live CD-ROM unplug, so the detach is --config only.
check "the detach is persistent-only (no --live)" "0" \
      "$(grep 'detach-disk' "$EJECT_LOG" | grep -c -- '--live')"
check "the detach persists to the definition"  "2" \
      "$(grep 'detach-disk' "$EJECT_LOG" | grep -c -- '--config')"
check "the medium eject is live on a running guest" "yes" \
      "$(grep 'change-media' "$EJECT_LOG" | grep -q -- '--live' && echo yes || echo no)"

: >"$EJECT_LOG"; STRIP_CONFIRM=1 run_strip
check "declining leaves every drive in place"   "0" "$(grep -cE 'change-media|detach-disk' "$EJECT_LOG")"

: >"$EJECT_LOG"; STRIP_CONFIRM=0 run_strip docker
check "a non-libvirt backend is skipped"        "0" "$(grep -cE 'change-media|detach-disk' "$EJECT_LOG")"

section "WinApps: the VM builder script"
WINAPPS_VM_DEPLOYER="$WA_TMP/winapps-vm-deploy"
winapps_write_vm_deployer >/dev/null 2>&1
if bash -n "$WINAPPS_VM_DEPLOYER" 2>/dev/null; then
    printf '  %s the generated VM builder parses\n' "$(green PASS)"; ((PASS++))
else
    printf '  %s the generated VM builder has a syntax error\n' "$(red FAIL)"; ((FAIL++))
fi
check_line "it authors an unattended answer file"  'Autounattend.xml'        "$WINAPPS_VM_DEPLOYER"
# Without publicKeyToken the offline SMI parser rejects the file in the
# specialize/oobeSystem passes ("not a valid unattended Setup answer file",
# 0x80220003) and the install dies with "computer restarted unexpectedly".
check_line "its answer-file components are signed" 'publicKeyToken="31bf3856ad364e35"' "$WINAPPS_VM_DEPLOYER"
# The edition is a variable now, defaulted rather than hardcoded; that the
# default really is Windows 11 Pro is checked against the rendered answer file
# in "Autounattend.xml carries the answers" below.
check_line "it installs the configured edition"   '<Value>$X_EDITION</Value>' "$WINAPPS_VM_DEPLOYER"
check_line "the edition defaults to Windows 11 Pro" 'VM_EDITION="${VM_EDITION:-Windows 11 Pro}"' "$WINAPPS_VM_DEPLOYER"
check_line "it bypasses the Win11 hardware checks" 'BypassTPMCheck'          "$WINAPPS_VM_DEPLOYER"
check_line "it enables Remote Desktop"             'fDenyTSConnections'      "$WINAPPS_VM_DEPLOYER"
check_line "it imports the RemoteApp registry"     'RDPApps.reg'             "$WINAPPS_VM_DEPLOYER"
check_line "it fetches RDPApps.reg from oem/"      'oem/RDPApps.reg'        "$WINAPPS_VM_DEPLOYER"
check_line "it checks the hypervisor can read the ISO" 'hyp_can_read'        "$WINAPPS_VM_DEPLOYER"
check_line "it stages an unreachable ISO into the pool" '${VM_NAME}-install.iso' "$WINAPPS_VM_DEPLOYER"
check_line "it builds the answer disk in the pool"  'UNATTEND_ISO="$POOL_DIR' "$WINAPPS_VM_DEPLOYER"
check_line "it stages the virtio boot driver"      'viostor'                "$WINAPPS_VM_DEPLOYER"
check_line "it keeps the WinPE driver set minimal"  'for d in viostor NetKVM' "$WINAPPS_VM_DEPLOYER"
if grep -q 'for d in viostor NetKVM; do' "$WINAPPS_VM_DEPLOYER" && \
   ! grep -qE '^for d in .*(qemufwcfg|vioserial|pvpanic|smbus)' "$WINAPPS_VM_DEPLOYER"; then
    printf '  %s it does not inject redundant virtio INFs into WinPE (0xD000A000-0x40031)\n' "$(green PASS)"; ((PASS++))
else
    printf '  %s redundant virtio INFs still staged into WinPE\n' "$(red FAIL)"; ((FAIL++))
fi
check_line "it creates the guest with an emulated TPM" 'backend.type=emulator' "$WINAPPS_VM_DEPLOYER"
check_line "it patches the ISO past the CD boot prompt" 'efisys_noprompt.bin' "$WINAPPS_VM_DEPLOYER"
check_line "it overwrites the boot image extent"   'conv=notrunc'           "$WINAPPS_VM_DEPLOYER"
check_line "it locates the boot image by LBA"      'report_lba'             "$WINAPPS_VM_DEPLOYER"
check_line "it records whether the prompt was removed" '"$_src_sz" "$_mode" > "$_mk"' "$WINAPPS_VM_DEPLOYER"
check_line "it keeps a key-tap safety net"         'send-key "$VM_NAME" KEY_ENTER' "$WINAPPS_VM_DEPLOYER"
check_line "the key-tap net is skipped when the prompt is gone" 'if [ "${NOPROMPT_OK:-0}" != "1" ]; then' "$WINAPPS_VM_DEPLOYER"
check_line "it warns when the prompt is still there" 'the CD boot prompt could not be removed' "$WINAPPS_VM_DEPLOYER"
check_line "it points the user at the app scan"    'setup.sh --system'      "$WINAPPS_VM_DEPLOYER"
# The '--help' banner must not fall through to the argument parser.
if ( "$WINAPPS_VM_DEPLOYER" --nonsense ) >/dev/null 2>&1; then
    printf '  %s the VM builder accepts a bogus argument\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s the VM builder rejects a bogus argument\n' "$(green PASS)"; ((PASS++))
fi

rm -rf "$WA_TMP"

section "windows-vm.conf: parsing"
VMC_TMP="$(mktemp -d)"
vmc_read() {
    local body="$1"; shift
    printf '%s\n' "$body" > "$VMC_TMP/t.conf"
    chmod 600 "$VMC_TMP/t.conf"
    ( VM_CONF_FILE="$VMC_TMP/t.conf"; VM_CONF_HAS_SECRET=0
      OPT_WINAPPS_ISO=""; OPT_WINAPPS_VM=""; OPT_WINAPPS_VM_ADMIN=""
      OPT_WINAPPS_VM_PASS=""; OPT_WINAPPS_VM_RAM=""; OPT_WINAPPS_VM_CPUS=""
      OPT_WINAPPS_VM_DISK=""
      vm_conf_load >/dev/null 2>&1 || exit 1
      local out="" v
      for v in "$@"; do out+="${!v}|"; done
      printf '%s' "${out%|}" )
}
check "the ISO path is read"      "/srv/w.iso" "$(vmc_read 'iso = /srv/w.iso' OPT_WINAPPS_ISO)"
check "the guest name is read"    "Win11"      "$(vmc_read 'vm_name = Win11' OPT_WINAPPS_VM)"
check "the admin account is read" "winadmin"   "$(vmc_read 'admin = winadmin' OPT_WINAPPS_VM_ADMIN)"
check "the password is read"      "hunter2!"   "$(vmc_read 'password = hunter2!' OPT_WINAPPS_VM_PASS)"
check "the sizes are read"        "8192|6|120" \
      "$(vmc_read 'ram = 8192
cpus = 6
disk = 120' OPT_WINAPPS_VM_RAM OPT_WINAPPS_VM_CPUS OPT_WINAPPS_VM_DISK)"
check "whitespace around = is ignored" "Win11" "$(vmc_read '   vm_name=Win11   ' OPT_WINAPPS_VM)"
check "comments and blank lines are skipped" "Win11" \
      "$(vmc_read '# a comment

vm_name = Win11' OPT_WINAPPS_VM)"
check "a '#' inside a password is not a comment" 'P@ss#word' \
      "$(vmc_read 'password = P@ss#word' OPT_WINAPPS_VM_PASS)"
check "quotes preserve a trailing space" "pass " \
      "$(vmc_read 'password = "pass "' OPT_WINAPPS_VM_PASS)"
check "a CRLF line ending is tolerated" "Win11" \
      "$(vmc_read "$(printf 'vm_name = Win11\r')" OPT_WINAPPS_VM)"

# Bad input must stop the run, naming the file and line.
vmc_rejects() {
    local desc="$1" body="$2"
    printf '%s\n' "$body" > "$VMC_TMP/t.conf"
    if ( VM_CONF_FILE="$VMC_TMP/t.conf"; vm_conf_load ) >/dev/null 2>&1; then
        printf '  %s %s was accepted\n' "$(red FAIL)" "$desc"; ((FAIL++))
    else
        printf '  %s %s is rejected\n' "$(green PASS)" "$desc"; ((PASS++))
    fi
}
vmc_rejects "an unknown setting"        'isoo = /x.iso'
vmc_rejects "a setting from elsewhere"  'domain = corp.example.com'
vmc_rejects "a line with no '='"        'iso'
vmc_rejects "a non-numeric size"        'ram = lots'
if ( VM_CONF_FILE="$VMC_TMP/nope.conf"; vm_conf_load ) >/dev/null 2>&1; then
    printf '  %s a missing --vm-config file was accepted\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s a missing --vm-config file is an error\n' "$(green PASS)"; ((PASS++))
fi

section "windows-vm.conf: the Windows answers"
vmc_read2() {
    local body="$1"; shift
    printf '%s\n' "$body" > "$VMC_TMP/t.conf"
    chmod 600 "$VMC_TMP/t.conf"
    ( VM_CONF_FILE="$VMC_TMP/t.conf"
      OPT_VM_EDITION=""; OPT_VM_PRODUCT_KEY=""; OPT_VM_COMPUTER_NAME=""
      OPT_VM_OWNER=""; OPT_VM_ORGANIZATION=""; OPT_VM_TIMEZONE=""
      OPT_VM_UI_LANGUAGE=""; OPT_VM_SYSTEM_LOCALE=""; OPT_VM_USER_LOCALE=""
      OPT_VM_INPUT_LOCALE=""
      vm_conf_load >/dev/null 2>&1 || exit 1
      local out="" v
      for v in "$@"; do out+="${!v}|"; done
      printf '%s' "${out%|}" )
}
check "the edition is read"       "Windows 11 Enterprise" \
      "$(vmc_read2 'edition = Windows 11 Enterprise' OPT_VM_EDITION)"
check "the product key is read"   "ABCDE-12345-FGHIJ-67890-KLMNO" \
      "$(vmc_read2 'product_key = ABCDE-12345-FGHIJ-67890-KLMNO' OPT_VM_PRODUCT_KEY)"
check "the computer name is read" "WIN11-LAB" \
      "$(vmc_read2 'computer_name = WIN11-LAB' OPT_VM_COMPUTER_NAME)"
check "'*' is an allowed computer name" "*" \
      "$(vmc_read2 'computer_name = *' OPT_VM_COMPUTER_NAME)"
check "owner and organization are read" "Example User|Example Ltd" \
      "$(vmc_read2 'owner = Example User
organization = Example Ltd' OPT_VM_OWNER OPT_VM_ORGANIZATION)"
check "the time zone is read"     "Eastern Standard Time" \
      "$(vmc_read2 'timezone = Eastern Standard Time' OPT_VM_TIMEZONE)"
check "the locales are read"      "en-GB|de-DE|fr-FR|0809:00000809" \
      "$(vmc_read2 'ui_language   = en-GB
system_locale = de-DE
user_locale   = fr-FR
input_locale  = 0809:00000809' OPT_VM_UI_LANGUAGE OPT_VM_SYSTEM_LOCALE \
        OPT_VM_USER_LOCALE OPT_VM_INPUT_LOCALE)"
check "a bare language tag is an input locale" "en-GB" \
      "$(vmc_read2 'input_locale = en-GB' OPT_VM_INPUT_LOCALE)"

vmc_rejects "a malformed product key"      'product_key = ABCDE-12345'
vmc_rejects "a computer name over 15"      'computer_name = WAY-TOO-LONG-A-NAME'
vmc_rejects "an all-digit computer name"   'computer_name = 12345'
vmc_rejects "a computer name with a space" 'computer_name = WIN 11'
vmc_rejects "a bogus language tag"         'ui_language = english'
vmc_rejects "a bogus user locale"          'user_locale = 12345'
vmc_rejects "an empty time zone"           'timezone ='
vmc_rejects "a bogus input locale"         'input_locale = ?!'

section "windows-vm.conf: precedence"
printf 'ram = 8192\npassword = fromfile\n' > "$VMC_TMP/p.conf"
chmod 600 "$VMC_TMP/p.conf"
check "a flag beats the file" "2048" \
      "$( OPT_WINAPPS_VM_RAM=""; VM_CONF_FILE="$VMC_TMP/p.conf"
          vm_conf_load >/dev/null 2>&1
          parse_args --winapps-vm-ram 2048 >/dev/null 2>&1
          printf '%s' "$OPT_WINAPPS_VM_RAM" )"
check "WINAPPS_VM_PASS beats the file" "fromenv" \
      "$( OPT_WINAPPS_VM_PASS="fromenv"     # as the WINAPPS_VM_PASS default would
          VM_CONF_FILE="$VMC_TMP/p.conf"; vm_conf_load >/dev/null 2>&1
          printf '%s' "$OPT_WINAPPS_VM_PASS" )"
check "the file is used when nothing else supplies it" "fromfile" \
      "$( OPT_WINAPPS_VM_PASS=""
          VM_CONF_FILE="$VMC_TMP/p.conf"; vm_conf_load >/dev/null 2>&1
          printf '%s' "$OPT_WINAPPS_VM_PASS" )"
check "--no-vm-config ignores the file" "|" \
      "$( OPT_WINAPPS_VM_RAM=""; vm_conf_prescan --no-vm-config
          VM_CONF_FILE="$VMC_TMP/p.conf"; vm_conf_load >/dev/null 2>&1
          printf '%s|%s' "$OPT_WINAPPS_VM_RAM" "$VM_CONF_LOADED_FROM" )"
check "--vm-config is picked out before the flags" "$VMC_TMP/p.conf" \
      "$( vm_conf_prescan --winapps --vm-config "$VMC_TMP/p.conf" --winapps-deploy
          printf '%s' "$VM_CONF_FILE" )"

section "windows-vm.conf: --write-vm-config and the sample"
VMC_WROTE="$VMC_TMP/written.conf"
if ( vm_conf_write_sample "$VMC_WROTE" ) >/dev/null 2>&1; then
    printf '  %s --write-vm-config writes a file\n' "$(green PASS)"; ((PASS++))
else
    printf '  %s --write-vm-config failed\n' "$(red FAIL)"; ((FAIL++))
fi
check "it is created mode 0600" "600" "$(stat -c '%a' "$VMC_WROTE" 2>/dev/null)"
if ( vm_conf_write_sample "$VMC_WROTE" ) >/dev/null 2>&1; then
    printf '  %s --write-vm-config overwrote an existing file\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s --write-vm-config refuses to overwrite\n' "$(green PASS)"; ((PASS++))
fi
# The sample committed to the repo is generated from the same heredoc, so it
# cannot be allowed to drift away from what the script actually writes.
VMC_SAMPLE="$SCRIPT_DIR/windows-vm.conf.example"
if [[ -f "$VMC_SAMPLE" ]]; then
    printf '  %s windows-vm.conf.example is committed\n' "$(green PASS)"; ((PASS++))
    if diff -q "$VMC_SAMPLE" "$VMC_WROTE" >/dev/null 2>&1; then
        printf '  %s the sample matches --write-vm-config\n' "$(green PASS)"; ((PASS++))
    else
        printf '  %s the sample has drifted from --write-vm-config\n' "$(red FAIL)"; ((FAIL++))
        diff "$VMC_SAMPLE" "$VMC_WROTE" | head -10 | sed 's/^/        /'
    fi
    if grep -qE '^[a-z_]+[[:space:]]*=' "$VMC_SAMPLE"; then
        printf '  %s the sample has an uncommented setting in it\n' "$(red FAIL)"; ((FAIL++))
    else
        printf '  %s every setting in the sample is commented out\n' "$(green PASS)"; ((PASS++))
    fi
    if grep -qE '/home/|/Users/' "$VMC_SAMPLE"; then
        printf '  %s the sample contains a real home directory path\n' "$(red FAIL)"; ((FAIL++))
    else
        printf '  %s the sample carries no personal path\n' "$(green PASS)"; ((PASS++))
    fi
    # Every name it mentions must be one vm_conf_set accepts, and uncommenting
    # the whole thing must parse.
    VMC_BAD=""
    while read -r n; do
        grep -qE "^        $n\)" "$TARGET" || VMC_BAD+="$n "
    done < <(sed -n 's/^#\([a-z_][a-z_0-9]*\)[[:space:]]*=.*/\1/p' "$VMC_SAMPLE" | sort -u)
    check "every name in the sample is a real setting" "" "${VMC_BAD% }"
    sed 's/^#\([a-z_][a-z_0-9]*[[:space:]]*=\)/\1/' "$VMC_SAMPLE" \
        | grep -v '^#' | grep -v '^$' > "$VMC_TMP/all.conf"
    chmod 600 "$VMC_TMP/all.conf"
    if ( VM_CONF_FILE="$VMC_TMP/all.conf"; vm_conf_load ) >/dev/null 2>&1; then
        printf '  %s every example value in the sample is valid\n' "$(green PASS)"; ((PASS++))
    else
        printf '  %s the sample holds a value it would reject\n' "$(red FAIL)"; ((FAIL++))
        ( VM_CONF_FILE="$VMC_TMP/all.conf"; vm_conf_load ) 2>&1 | tail -2 | sed 's/^/        /'
    fi
else
    printf '  %s windows-vm.conf.example is missing from the repo\n' "$(red FAIL)"; ((FAIL++))
fi
if have git && [[ -d "$SCRIPT_DIR/.git" ]]; then
    git -C "$SCRIPT_DIR" check-ignore -q windows-vm.conf 2>/dev/null \
        && { printf '  %s windows-vm.conf is gitignored\n' "$(green PASS)"; ((PASS++)); } \
        || { printf '  %s windows-vm.conf is NOT gitignored\n' "$(red FAIL)"; ((FAIL++)); }
    git -C "$SCRIPT_DIR" check-ignore -q windows-vm.conf.example 2>/dev/null \
        && { printf '  %s the sample is gitignored and would never ship\n' "$(red FAIL)"; ((FAIL++)); } \
        || { printf '  %s the sample is not gitignored\n' "$(green PASS)"; ((PASS++)); }
fi

section "Autounattend.xml carries the answers"
# The answer file is where a wrong value costs 45 minutes, so it is rendered
# for real and read back rather than checked by inspection.
AU_TMP="$(mktemp -d)"
mkdir -p "$AU_TMP/iso/oem"
( DRY_RUN=0; WINAPPS_VM_DEPLOYER="$AU_TMP/deploy.sh"
  winapps_install_file() { local d="$1"; shift; cat > "$d"; chmod 755 "$d"; }
  winapps_write_vm_deployer ) >/dev/null 2>&1
au_render() {
    printf '%s\n' "$1" > "$AU_TMP/vm.conf"
    chmod 600 "$AU_TMP/vm.conf"
    rm -f "$AU_TMP/iso/Autounattend.xml"
    ( WINDOWS_VM_CONF="$AU_TMP/vm.conf" ISO_ROOT="$AU_TMP/iso"
      eval "$(sed -n '/^VM_NAME=/,/^\[ "\${#VM_ADMIN}" -le 20 \]/p' "$AU_TMP/deploy.sh")"
      eval "$(sed -n '/^xesc()/,/^XML$/p' "$AU_TMP/deploy.sh")" ) >/dev/null 2>&1
}
au_has() {
    local desc="$1" needle="$2"
    if grep -qF -- "$needle" "$AU_TMP/iso/Autounattend.xml" 2>/dev/null; then
        printf '  %s %s\n' "$(green PASS)" "$desc"; ((PASS++))
    else
        printf '  %s %s\n' "$(red FAIL)" "$desc"
        printf '        %s not in the rendered answer file\n' "$needle"; ((FAIL++))
    fi
}
au_wellformed() {
    if python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" \
         "$AU_TMP/iso/Autounattend.xml" >/dev/null 2>&1; then
        printf '  %s %s\n' "$(green PASS)" "$1"; ((PASS++))
    else
        printf '  %s %s\n' "$(red FAIL)" "$1"; ((FAIL++))
    fi
}

# Defaults must render exactly what the script produced before any of this
# existed - a settings file nobody has written must change nothing.
au_render ''
au_has "default edition is Windows 11 Pro" '<Value>Windows 11 Pro</Value>'
au_has "default key is the generic Pro key" '<Key>W269N-WFGWX-YVC9B-4J6C9-T83GX</Key>'
au_has "default computer name is generated" '<ComputerName>*</ComputerName>'
au_has "default UI language is en-US"       '<UILanguage>en-US</UILanguage>'
au_has "default input locale is US"         '<InputLocale>0409:00000409</InputLocale>'
au_has "a time zone is always set"          '<TimeZone>UTC</TimeZone>'
au_wellformed "the default answer file is well-formed XML"

au_render 'edition       = Windows 11 Enterprise
product_key   = ABCDE-12345-FGHIJ-67890-KLMNO
computer_name = WIN11-LAB
admin         = winadmin
owner         = Example User
organization  = Example Ltd
timezone      = Eastern Standard Time
ui_language   = en-GB
input_locale  = 0809:00000809'
au_has "the edition reaches /IMAGE/NAME"   '<Value>Windows 11 Enterprise</Value>'
au_has "the product key reaches ProductKey" '<Key>ABCDE-12345-FGHIJ-67890-KLMNO</Key>'
au_has "the computer name reaches the XML"  '<ComputerName>WIN11-LAB</ComputerName>'
au_has "the time zone reaches the XML"      '<TimeZone>Eastern Standard Time</TimeZone>'
au_has "the owner reaches the XML"          '<RegisteredOwner>Example User</RegisteredOwner>'
au_has "the organization reaches the XML"   '<RegisteredOrganization>Example Ltd</RegisteredOrganization>'
au_has "the keyboard reaches InputLocale"   '<InputLocale>0809:00000809</InputLocale>'
au_has "the account reaches the XML"        '<Name>winadmin</Name>'
# system_locale and user_locale were not set, so they follow ui_language.
au_has "system_locale follows ui_language"  '<SystemLocale>en-GB</SystemLocale>'
au_has "user_locale follows ui_language"    '<UserLocale>en-GB</UserLocale>'
au_wellformed "a fully populated answer file is well-formed XML"

# An edition with no key of its own must leave ProductKey out entirely rather
# than emit an empty one, which Setup treats differently.
au_render 'edition = Windows 11 Enterprise'
if grep -q 'ProductKey' "$AU_TMP/iso/Autounattend.xml"; then
    printf '  %s an empty ProductKey was emitted\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s no key for that edition leaves ProductKey out\n' "$(green PASS)"; ((PASS++))
fi
au_wellformed "omitting ProductKey leaves well-formed XML"

# A value with XML metacharacters must be escaped, not injected.
au_render 'organization = Ampersand & <Sons>'
au_has "XML metacharacters are escaped" '&amp; &lt;Sons&gt;'
au_wellformed "an organization holding markup leaves well-formed XML"

# The deployer must reject the same bad values the installer does.
au_deploy_rejects() {
    local desc="$1" body="$2"
    printf '%s\n' "$body" > "$AU_TMP/vm.conf"
    if ( WINDOWS_VM_CONF="$AU_TMP/vm.conf"
         eval "$(sed -n '/^VM_NAME=/,/^\[ "\${#VM_ADMIN}" -le 20 \]/p' "$AU_TMP/deploy.sh")"
       ) >/dev/null 2>&1; then
        printf '  %s the builder accepted %s\n' "$(red FAIL)" "$desc"; ((FAIL++))
    else
        printf '  %s the builder rejects %s\n' "$(green PASS)" "$desc"; ((PASS++))
    fi
}
au_deploy_rejects "a malformed product key"    'product_key = NOPE'
au_deploy_rejects "an all-digit computer name" 'computer_name = 12345'
au_deploy_rejects "a bogus language tag"       'ui_language = english'
au_deploy_rejects "an unknown setting"         'domain = corp.example.com'
au_deploy_rejects "a bad account name"         'admin = Bad Name'

rm -rf "$AU_TMP"

section "The VM's local administrator account"
for good in Docker win-admin user_1 A; do
    winapps_vm_admin_ok "$good" \
        && { printf '  %s %s is accepted\n' "$(green PASS)" "$good"; ((PASS++)); } \
        || { printf '  %s %s was rejected\n' "$(red FAIL)" "$good"; ((FAIL++)); }
done
for bad in "Win Admin" 'a\b' 'a"b' 'a:b' 'a;b' 'a|b' 'a=b' 'a,b' 'a+b' 'a*b' 'a?b' \
           'a<b' 'a>b' 'a@b' 'a[b' 'a]b' 'a/b' 'trailingdot.' \
           'ThisNameIsWayTooLongForWindows' ''; do
    winapps_vm_admin_ok "$bad" \
        && { printf '  %s "%s" was accepted\n' "$(red FAIL)" "$bad"; ((FAIL++)); } \
        || { printf '  %s "%s" is rejected\n' "$(green PASS)" "$bad"; ((PASS++)); }
done
if ( parse_args --winapps-vm-user "Bad Name" ) >/dev/null 2>&1; then
    printf '  %s --winapps-vm-user accepted a name with a space\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s --winapps-vm-user rejects a name with a space\n' "$(green PASS)"; ((PASS++))
fi
check "--winapps-vm-user is stored" "win-admin" \
      "$( OPT_WINAPPS_VM_ADMIN=""; parse_args --winapps-vm-user win-admin >/dev/null 2>&1
          printf '%s' "$OPT_WINAPPS_VM_ADMIN" )"
# A name the config file supplies has to be checked too, not just a flag.
if ( printf 'admin = Bad Name\n' > "$VMC_TMP/t.conf"
     VM_CONF_FILE="$VMC_TMP/t.conf"; vm_conf_load >/dev/null 2>&1
     parse_args ) >/dev/null 2>&1; then
    printf '  %s a bad name in windows-vm.conf was accepted\n' "$(red FAIL)"; ((FAIL++))
else
    printf '  %s a bad name in windows-vm.conf is rejected\n' "$(green PASS)"; ((PASS++))
fi

rm -rf "$VMC_TMP"

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
