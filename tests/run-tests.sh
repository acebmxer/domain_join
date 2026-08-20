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
layout_at 40 21
check "40x21 is the smallest usable size" "0" "$ML_TOO_SMALL"
layout_at 39 21
check "39 columns is too narrow"          "1" "$ML_TOO_SMALL"
layout_at 40 20
check "20 rows is too short"              "1" "$ML_TOO_SMALL"

# No drawn line may be wider than the terminal, or the redraw leaves debris.
overlong=0
for size in "120 45" "100 40" "80 24" "70 30" "60 30" "45 24"; do
    set -- $size
    MENU_CURSOR=0
    widest="$(COLUMNS="$1" LINES="$2" draw_menu \
        | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' \
        | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
    (( widest > $1 )) && { overlong=1; printf '        %sx%s produced a %s-column line\n' "$1" "$2" "$widest"; }
done
check "every drawn line fits the terminal" "0" "$overlong"

section "Menu navigation"
nav() {
    # Places the cursor, applies a key, and reports where it landed.
    MENU_CURSOR="$1"
    menu_get_pos "$MENU_CURSOR"
    case "$2" in
        up)    if (( MCOL == 2 )); then menu_set_cursor 0 $(( MENU_LEFT_COUNT - 1 ))
               elif (( MROW == 0 )); then menu_set_cursor 2 0
               else menu_set_cursor "$MCOL" $(( MROW - 1 )); fi ;;
        down)  if (( MCOL == 2 )); then menu_set_cursor 0 0
               else
                   col_size=$MENU_LEFT_COUNT
                   (( MCOL == 1 )) && col_size=$MENU_RIGHT_COUNT
                   if (( MROW >= col_size - 1 )); then menu_set_cursor 2 0
                   else menu_set_cursor "$MCOL" $(( MROW + 1 )); fi
               fi ;;
    esac
    printf '%s' "$MENU_CURSOR"
}
ML_TWO_COL=1
centre_idx=$(( MENU_LEFT_COUNT + MENU_RIGHT_COUNT ))
right_foot=$(( MENU_LEFT_COUNT + MENU_RIGHT_COUNT - 1 ))
left_foot=$(( MENU_LEFT_COUNT - 1 ))
check "index 0 is the top of the left column"  "0 0" "$(menu_get_pos 0; printf '%s %s' "$MCOL" "$MROW")"
check "the first right-column index is its top" "1 0" \
      "$(menu_get_pos "$MENU_LEFT_COUNT"; printf '%s %s' "$MCOL" "$MROW")"
check "the last index is the centred row"      "2 0" \
      "$(menu_get_pos "$centre_idx"; printf '%s %s' "$MCOL" "$MROW")"
check "the right column's foot is in column 1" "1 $(( MENU_RIGHT_COUNT - 1 ))" \
      "$(menu_get_pos "$right_foot"; printf '%s %s' "$MCOL" "$MROW")"
check "up from the top wraps to the centre"    "$centre_idx" "$(nav 0 up)"
check "down off the left column reaches it too" "$centre_idx" "$(nav "$left_foot" down)"
check "down off the right column reaches it too" "$centre_idx" "$(nav "$right_foot" down)"
check "down from the centre returns to the top" "0" "$(nav "$centre_idx" down)"
check "up from the centre enters the left column" "$left_foot" "$(nav "$centre_idx" up)"
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
