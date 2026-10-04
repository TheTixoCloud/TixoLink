#!/usr/bin/env bash
# TixoLink NEXUS - UI framework (colors, headers, prompts, tables)
#
# All terminal rendering goes through this file. No other file should emit
# raw ANSI escape sequences.

if [[ -n "${TIXOLINK_UI_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_UI_SH_LOADED=1

# --- Color / capability detection -------------------------------------------
ui::_colors_enabled() {
    [[ -n "${NO_COLOR:-}" ]] && return 1
    [[ -t 1 ]] || return 1
    [[ "${TERM:-dumb}" == "dumb" ]] && return 1
    return 0
}

if ui::_colors_enabled; then
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_RED=$'\033[31m'
    UI_GREEN=$'\033[32m'
    UI_YELLOW=$'\033[33m'
    UI_CYAN=$'\033[36m'
    UI_DIM=$'\033[2m'
else
    UI_RESET=""
    UI_BOLD=""
    UI_RED=""
    UI_GREEN=""
    UI_YELLOW=""
    UI_CYAN=""
    UI_DIM=""
fi
readonly UI_RESET UI_BOLD UI_RED UI_GREEN UI_YELLOW UI_CYAN UI_DIM

ui::_is_interactive() {
    [[ -t 0 && -t 1 ]]
}

# --- Banner / headers --------------------------------------------------------
ui::header() {
    printf '%s%s== TixoLink NEXUS ==%s %sTheTixoCloud%s\n' \
        "$UI_BOLD" "$UI_CYAN" "$UI_RESET" "$UI_DIM" "$UI_RESET"
}

# ui::section <title>
ui::section() {
    printf '\n%s%s%s\n' "$UI_BOLD" "$1" "$UI_RESET"
}

# ui::success <message>
ui::success() {
    printf '%s[OK]%s %s\n' "$UI_GREEN" "$UI_RESET" "$1"
}

# ui::error <message>
ui::error() {
    printf '%s[ERROR]%s %s\n' "$UI_RED" "$UI_RESET" "$1" >&2
}

# ui::warning <message>
ui::warning() {
    printf '%s[WARN]%s %s\n' "$UI_YELLOW" "$UI_RESET" "$1"
}

# ui::info <message>
ui::info() {
    printf '%s[INFO]%s %s\n' "$UI_CYAN" "$UI_RESET" "$1"
}

# --- Prompts ------------------------------------------------------------------
# ui::confirm <prompt> [default: y|n]
# Returns 0 for yes, 1 for no. Non-interactive sessions fail closed (return 1)
# unless a default is supplied.
ui::confirm() {
    local prompt="$1" default="${2:-}"
    local suffix="[y/n]"
    [[ "$default" == "y" ]] && suffix="[Y/n]"
    [[ "$default" == "n" ]] && suffix="[y/N]"

    if ! ui::_is_interactive; then
        [[ "$default" == "y" ]] && return 0
        return 1
    fi

    local reply
    while true; do
        read -r -p "$prompt $suffix " reply
        reply="$(common::lower "${reply:-$default}")"
        case "$reply" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) printf 'Please answer y or n.\n' ;;
        esac
    done
}

# ui::input <prompt> [default-value]
# Prints the entered value (or default) to stdout.
ui::input() {
    local prompt="$1" default="${2:-}"
    local reply
    if ! ui::_is_interactive; then
        printf '%s' "$default"
        return 0
    fi
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " reply
    else
        read -r -p "$prompt: " reply
    fi
    printf '%s' "${reply:-$default}"
}

# ui::select <title> <option1> <option2> ...
# Prints the 1-based index of the chosen option to stdout. Returns 1 if
# selection is impossible (non-interactive, no options).
ui::select() {
    local title="$1"
    shift
    local -a options=("$@")
    [[ ${#options[@]} -eq 0 ]] && return 1

    printf '%s\n' "$title"
    local i
    for i in "${!options[@]}"; do
        printf ' [%d] %s\n' "$((i+1))" "${options[$i]}"
    done

    if ! ui::_is_interactive; then
        return 1
    fi

    local choice
    while true; do
        read -r -p "Select: " choice
        if common::is_integer "$choice" && (( choice >= 1 && choice <= ${#options[@]} )); then
            printf '%s' "$choice"
            return 0
        fi
        printf 'Invalid selection.\n'
    done
}

# --- Tables -------------------------------------------------------------------
# ui::table <header1|header2|...> <row1col1|row1col2|...> ...
# Each argument is a '|'-delimited row; the first argument is the header row.
# Column widths are computed from the widest cell per column.
ui::table() {
    local header="$1"
    shift
    local -a rows=("$@")

    local -a headers
    IFS='|' read -r -a headers <<<"$header"
    local ncols=${#headers[@]}

    local -a widths=()
    local c
    for (( c=0; c<ncols; c++ )); do
        widths[c]=${#headers[c]}
    done

    local row
    local -a cells
    for row in "${rows[@]}"; do
        IFS='|' read -r -a cells <<<"$row"
        for (( c=0; c<ncols; c++ )); do
            local cell="${cells[c]:-}"
            local len=${#cell}
            (( len > widths[c] )) && widths[c]=$len
        done
    done

    ui::_table_row headers widths "$ncols" "$UI_BOLD"
    for row in "${rows[@]}"; do
        IFS='|' read -r -a cells <<<"$row"
        ui::_table_row cells widths "$ncols" ""
    done
}

ui::_table_row() {
    local -n _cells_ref="$1"
    local -n _widths_ref="$2"
    local ncols="$3" style="$4"
    local c line=""
    for (( c=0; c<ncols; c++ )); do
        local cell="${_cells_ref[$c]:-}"
        local width="${_widths_ref[$c]:-0}"
        line+="$(printf '%s%-*s%s  ' "$style" "$width" "$cell" "$UI_RESET")"
    done
    printf '%s\n' "$line"
}
