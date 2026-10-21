#!/usr/bin/env bash
set -euo pipefail

# Shared chooser (plan D02). Contract: Documents/runtime-managed-configuration.md section 4.
#
#   menu_choose.sh --prompt TEXT [--confirm] < RECORDS
#
# RECORDS are newline-separated "ID<TAB>LABEL" lines. The chooser shows the labels through
# the selected launcher's native dmenu mode (via menu_exec.sh --dmenu, so the launcher, its
# Wayland backend and its log stay identical to the legacy route) and prints the ID of the
# selected record. Exit status: 0 selected, 3 cancelled, 1 launcher failure, 2 invalid request.
# --confirm ignores stdin and offers "No" first and "Yes" second; only "Yes" returns 0.
#
# Labels are display text only: control characters, bidirectional overrides and invalid
# UTF-8 are removed, markup and image escapes are disabled where the launcher supports them,
# and duplicate labels receive collision-free suffixes. A returned line that is not exactly
# one offered label (or one offered index) is a failure, never a fuzzy match. Nothing is
# logged about the labels or the selection.

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export HSS_SCRIPTS_DIR=$script_dir
# shellcheck source=dotfiles/.config/hypr/scripts/lib/hss_runtime.sh
source "$script_dir/lib/hss_runtime.sh"

readonly EXIT_SELECTED=0 EXIT_FAILED=1 EXIT_USAGE=2 EXIT_CANCELLED=3

usage() {
    printf 'Usage: menu_choose.sh --prompt TEXT [--confirm] < RECORDS\n' >&2
    printf 'RECORDS: newline-separated ID<TAB>LABEL lines; IDs match [A-Za-z0-9._:-]+ and are unique.\n' >&2
}

invalid() {
    printf 'menu_choose.sh: %s\n' "$1" >&2
    exit "$EXIT_USAGE"
}

failed() {
    printf 'menu_choose.sh: %s\n' "$1" >&2
    exit "$EXIT_FAILED"
}

# Display text without control characters, bidirectional overrides or isolates, trimmed.
# Sets REPLY (no subshell, so long record lists stay fast).
clean_text() {
    local text=$1 mark
    text=${text//$'\t'/ }
    text=${text//$'\r'/ }
    text=${text//[[:cntrl:]]/}
    for mark in $'\xe2\x80\x8e' $'\xe2\x80\x8f' $'\xe2\x80\xaa' $'\xe2\x80\xab' $'\xe2\x80\xac' \
        $'\xe2\x80\xad' $'\xe2\x80\xae' $'\xe2\x81\xa6' $'\xe2\x81\xa7' $'\xe2\x81\xa8' $'\xe2\x81\xa9' \
        $'\xc2\x85'; do
        text=${text//"$mark"/}
    done
    text="${text#"${text%%[![:space:]]*}"}"
    REPLY="${text%"${text##*[![:space:]]}"}"
}

prompt=""
have_prompt=false
confirm=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt)
            [[ $# -ge 2 ]] || { usage; exit "$EXIT_USAGE"; }
            prompt=$2
            have_prompt=true
            shift 2
            ;;
        --prompt=*) prompt=${1#--prompt=}; have_prompt=true; shift ;;
        --confirm) confirm=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit "$EXIT_USAGE" ;;
    esac
done
$have_prompt || { usage; exit "$EXIT_USAGE"; }
clean_text "$prompt"
prompt=$REPLY
[[ -n $prompt ]] || invalid "the prompt is empty"

ids=()
labels=()
if $confirm; then
    ids=(no yes)
    labels=(No Yes)
else
    declare -A seen_ids=()
    line_number=0
    while IFS= read -r line || [[ -n $line ]]; do
        line_number=$((line_number + 1))
        [[ $line == *$'\t'* ]] || invalid "record $line_number has no TAB separator"
        id=${line%%$'\t'*}
        label=${line#*$'\t'}
        [[ $id =~ ^[A-Za-z0-9._:-]+$ ]] || invalid "record $line_number has an invalid ID"
        [[ -z ${seen_ids[$id]+x} ]] || invalid "record $line_number repeats an ID"
        seen_ids[$id]=1
        clean_text "$label"
        label=$REPLY
        [[ -n $label ]] || invalid "record $line_number has an empty label"
        ids+=("$id")
        labels+=("$label")
    done
    ((${#ids[@]} > 0)) || invalid "no records were given"
    # Drop invalid UTF-8 bytes in one pass; the line count is unchanged because labels
    # contain no newlines.
    if hss_have iconv; then
        mapfile -t converted < <(printf '%s\n' "${labels[@]}" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null || true)
        if ((${#converted[@]} == ${#labels[@]})); then
            for index in "${!converted[@]}"; do
                [[ -n ${converted[$index]} ]] || invalid "record $((index + 1)) has an empty label"
                labels[index]=${converted[$index]}
            done
        fi
    fi
fi

# Collision-free display labels: a repeated label gets " (N)" with the smallest N that
# collides neither with an already shown label nor with any label that is still to come.
declare -A original=() shown=() label_index=()
for label in "${labels[@]}"; do
    original[$label]=1
done
display=()
for index in "${!labels[@]}"; do
    label=${labels[$index]}
    candidate=$label
    if [[ -n ${shown[$candidate]+x} ]]; then
        n=2
        candidate="$label ($n)"
        while [[ -n ${shown[$candidate]+x} || -n ${original[$candidate]+x} ]]; do
            n=$((n + 1))
            candidate="$label ($n)"
        done
    fi
    shown[$candidate]=1
    label_index[$candidate]=$index
    display+=("$candidate")
done

roles_file=$(hss_roles_file)
[[ -r $roles_file ]] || failed "role data is missing: $roles_file"
package=$(jq -r '.roles.launcher.package // ""' "$roles_file" 2>/dev/null) || package=""
dmenu_executable=$(jq -r '.roles.launcher.dmenu_executable // ""' "$roles_file" 2>/dev/null) || dmenu_executable=""
[[ -n $package && -n $dmenu_executable ]] || failed "no launcher is selected in $roles_file"
hss_have "$dmenu_executable" || failed "the selected launcher $dmenu_executable is not installed"

# Native dmenu options per launcher (verified evidence: capabilities.d/d02-launchers.json).
#   output: "index" (0-based index, custom entries refused natively) or "text" (exact label).
#   cancel: the launcher's documented/observed exit status for Escape.
extra=()
output=text
cancel_status=1
case "$package" in
    wofi)
        # The shipped config enables markup and image escapes; force both off for untrusted labels
        # and keep the selection out of wofi's dmenu cache.
        extra=("--prompt=$prompt" --cache-file=/dev/null
            --define=allow_markup=false --define=allow_images=false --define=dmenu-parse_action=false)
        ;;
    rofi)
        extra=(-p "$prompt" -format i -no-custom -no-markup-rows)
        output=index
        ;;
    fuzzel)
        extra=("--prompt=$prompt: " --index --only-match --cache=/dev/null)
        output=index
        cancel_status=2
        ;;
    bemenu)
        extra=(-p "$prompt" -l 15)
        ;;
    tofi)
        extra=("--prompt-text=$prompt: " --require-match=true)
        ;;
    *) failed "launcher $package has no chooser adapter" ;;
esac

set +e
selection=$(printf '%s\n' "${display[@]}" | "$script_dir/menu_exec.sh" --dmenu "${extra[@]}")
status=$?
set -e

if ((status != 0)); then
    if ((status == cancel_status)); then
        exit "$EXIT_CANCELLED"
    fi
    case "$status" in
        126|127) failed "the selected launcher could not be started (status $status)" ;;
        *) failed "the launcher failed with status $status" ;;
    esac
fi

# Command substitution removed the trailing newlines; anything left must be one line.
[[ -n $selection ]] || exit "$EXIT_CANCELLED"
[[ $selection != *$'\n'* ]] || failed "the launcher returned more than one line"

if [[ $output == index ]]; then
    [[ $selection =~ ^[0-9]{1,9}$ ]] || failed "the launcher returned an invalid index"
    ((10#$selection < ${#display[@]})) || failed "the launcher returned an index outside the offered records"
    chosen=$((10#$selection))
else
    [[ -n ${label_index[$selection]+x} ]] || failed "the launcher returned text that is not an offered label"
    chosen=${label_index[$selection]}
fi

if $confirm; then
    [[ ${ids[$chosen]} == yes ]] || exit "$EXIT_CANCELLED"
fi
printf '%s\n' "${ids[$chosen]}"
exit "$EXIT_SELECTED"
