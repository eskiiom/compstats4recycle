#!/usr/bin/env bash
#
# CompStats for Recycle - Linux
#
# Generates an HTML/JSON/CSV report with system, CPU, GPU, RAM, disk (with
# SMART/lsblk health), battery, network and LUKS encryption info, for
# assessing a Linux machine before recycling/reuse. Companion to
# windows/CompStats.ps1 and macos/compstats.py - same idea, each using its
# OS's own native tools rather than a shared abstraction layer.
#
# Deliberately dependency-free beyond what a normal Linux install already
# has (coreutils, lsblk/dmidecode/ip from util-linux/iproute2, which ship on
# essentially every distro) - no jq, no bc, no third-party packages.
#
# Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org)
# Project homepage: https://github.com/eskiiom/compstats4recycle

# Deliberately NOT using `set -u` (nounset): a bare `local var` declaration
# (no assignment) leaves it genuinely unbound in bash, and this script
# declares plenty of those to fill in incrementally. Under nounset, any code
# path that reaches such a variable before it's assigned (easy to hit with
# real-world command output that doesn't match every case tested against)
# crashes the whole run - directly against this script's "missing data is
# N/A, never a crash" design, matching the Windows/macOS scripts' try/catch
# approach. `pipefail` alone is kept for legitimate pipeline-failure checks.
set -o pipefail

SCRIPT_VERSION="0.1"
SCRIPT_DATE="2026-09-10"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

has_command() { command -v "$1" >/dev/null 2>&1; }

# Run a command, echo its stdout, or nothing on failure - callers treat an
# empty result as "field not available" rather than crashing, mirroring the
# Windows/macOS scripts' try/catch-everywhere approach.
run_cmd() {
    "$@" 2>/dev/null
    return 0
}

html_escape() {
    # In bash, an unescaped & in the REPLACEMENT side of ${var//pattern/repl}
    # means "the matched text" (like sed's &), not a literal ampersand - so
    # &lt;/&gt;/&quot; must be written as \&lt; etc., or they come out as
    # "<lt;"/">gt;"/etc. instead. The &/&amp; substitution below "works" only
    # by coincidence (the matched text IS "&", so inserting it is correct
    # either way) - escaped for clarity regardless.
    local s="${1-}"
    s="${s//&/\&amp;}"
    s="${s//</\&lt;}"
    s="${s//>/\&gt;}"
    s="${s//\"/\&quot;}"
    printf '%s' "$s"
}

json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

json_str() {
    # json_str <value> -> "escaped value", or null if empty
    local v="${1-}"
    if [[ -z "$v" ]]; then printf 'null'; else printf '"%s"' "$(json_escape "$v")"; fi
}

json_num_or_null() {
    local v="${1-}"
    if [[ -z "$v" || ! "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf 'null'; else printf '%s' "$v"; fi
}

trim() {
    local s="${1-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Extract a numeric value from smartctl output. ATA attribute-table rows put
# the value we want (RAW_VALUE) at the END of the line - the first number is
# the attribute ID (e.g. 5 for Reallocated_Sector_Ct), so -trailing must be
# used for those. NVMe log fields ("Power On Hours:    1,234") are simple
# "label: value" lines where the first number after the colon IS the value.
# Args: <trailing: 0|1> <pattern...> ; smartctl output lines on stdin.
smart_numeric_value() {
    local trailing="$1"; shift
    local line pattern stripped
    # `|| [[ -n "$line" ]]` matters: read fails (without an error) on a final
    # line that lacks a trailing newline - very possible here since these
    # loops often consume output already captured via $(...), which always
    # strips trailing newlines. Without this, the last line is silently
    # skipped whenever the field being searched for happens to be on it.
    while IFS= read -r line || [[ -n "$line" ]]; do
        for pattern in "$@"; do
            if [[ "$line" =~ $pattern ]]; then
                if [[ "$trailing" == "1" ]]; then
                    stripped=$(printf '%s' "$line" | sed -E 's/[[:space:]]*\([^)]*\)[[:space:]]*$//')
                    if [[ "$stripped" =~ ([0-9][0-9,]*)[[:space:]]*$ ]]; then
                        printf '%s' "${BASH_REMATCH[1]//,/}"
                        return 0
                    fi
                else
                    if [[ "$line" =~ :[[:space:]]*([0-9][0-9,]*) ]]; then
                        printf '%s' "${BASH_REMATCH[1]//,/}"
                        return 0
                    fi
                fi
            fi
        done
    done
    return 1
}

# --------------------------------------------------------------------------
# Disk health classification (same logic used for the summary badge and the
# detailed disk card, so the two can't disagree)
# Args: errors temp temp_threshold smart_status
# Echoes: status|label|css_class|alert_message
# --------------------------------------------------------------------------

disk_health_status() {
    local errors="${1-}" temp="${2-}" temp_threshold="${3:-50}" smart_status="${4-}"

    if [[ -n "$errors" && "$errors" != "N/A" && "$errors" =~ ^[0-9]+$ && "$errors" -gt 0 ]]; then
        printf 'KO|Probleme detecte|health-bad|Secteurs realloues detectes'
        return
    fi
    if [[ -n "$temp" && "$temp" != "N/A" && "$temp" =~ ^[0-9]+$ && "$temp" -gt "$temp_threshold" ]]; then
        printf 'Attention|Temperature elevee|health-warning|Temperature > %sC' "$temp_threshold"
        return
    fi
    if [[ -n "$smart_status" && "$smart_status" != "N/A" && "$smart_status" != "PASSED" && "$smart_status" != "OK" ]]; then
        printf 'Attention|%s|health-warning|' "$smart_status"
        return
    fi
    printf 'OK|OK|health-good|'
}

# --------------------------------------------------------------------------
# Global assessment (same scoring as the Windows/macOS scripts). Battery
# health is truncated to an integer - bash arithmetic has no native floats
# and this avoids depending on bc for a simple threshold comparison.
# Echoes: score|label|recommendation|badge_class
# --------------------------------------------------------------------------

global_assessment() {
    local disk_statuses="${1-}" has_battery="${2:-0}" battery_health="${3:-100}"
    local battery_good="${4:-80}" battery_warning="${5:-60}" battery_critical="${6:-40}"
    local score_good="${7:-80}" score_warning="${8:-50}"
    local score=100 status

    for status in $disk_statuses; do
        case "$status" in
            KO) (( score -= 35 )) ;;
            Attention) (( score -= 12 )) ;;
        esac
    done

    if [[ "$has_battery" == "1" ]]; then
        local bh="${battery_health%.*}"
        [[ -z "$bh" ]] && bh=100
        if (( bh < battery_critical )); then (( score -= 35 ))
        elif (( bh < battery_warning )); then (( score -= 20 ))
        elif (( bh < battery_good )); then (( score -= 8 ))
        fi
    fi

    (( score < 0 )) && score=0
    (( score > 100 )) && score=100

    local label recommendation badge_class
    if (( score >= score_good )); then
        label="Bon etat"; recommendation="Reemploi possible"; badge_class="status-ok"
    elif (( score >= score_warning )); then
        label="Attention"; recommendation="Verifier avant reemploi"; badge_class="status-warning"
    else
        label="Critique"; recommendation="Recyclage recommande"; badge_class="status-bad"
    fi

    printf '%s|%s|%s|%s' "$score" "$label" "$recommendation" "$badge_class"
}

# --------------------------------------------------------------------------
# System / CPU / GPU / RAM
# --------------------------------------------------------------------------

# Echoes: brand|model|serial|bios_date
get_system_info() {
    local brand model serial bios_date
    brand=$(trim "$(run_cmd cat /sys/class/dmi/id/sys_vendor)")
    model=$(trim "$(run_cmd cat /sys/class/dmi/id/product_name)")
    # product_serial commonly requires root; falls back to N/A otherwise,
    # same "can't verify without elevated rights" situation as Windows' TPM
    serial=$(trim "$(run_cmd cat /sys/class/dmi/id/product_serial)")
    bios_date=$(trim "$(run_cmd cat /sys/class/dmi/id/bios_date)")
    printf '%s|%s|%s|%s' "${brand:-N/A}" "${model:-N/A}" "${serial:-N/A}" "${bios_date:-N/A}"
}

# Echoes: brand|model
get_cpu_info() {
    local brand model
    model=$(trim "$(run_cmd grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2-)")
    brand=$(trim "$(run_cmd grep -m1 '^vendor_id' /proc/cpuinfo | cut -d: -f2-)")
    if [[ "$brand" == "GenuineIntel" ]]; then brand="Intel"
    elif [[ "$brand" == "AuthenticAMD" ]]; then brand="AMD"; fi
    printf '%s|%s' "${brand:-N/A}" "${model:-N/A}"
}

# Populates the GPU_NAME array (one entry per detected controller)
declare -a GPU_NAME
get_gpu_info() {
    GPU_NAME=()
    has_command lspci || return 0
    local line
    # `|| [[ -n "$line" ]]` matters: read fails (without an error) on a final
    # line that lacks a trailing newline - very possible here since these
    # loops often consume output already captured via $(...), which always
    # strips trailing newlines. Without this, the last line is silently
    # skipped whenever the field being searched for happens to be on it.
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] && GPU_NAME+=("$(trim "${line#*: }")")
    done < <(run_cmd lspci | grep -Ei 'VGA compatible controller|3D controller|Display controller')
}

# Sets RAM_TOTAL, RAM_INTEGRATED (1 if no per-slot data at all), and the
# RAM_SLOT/RAM_MANUFACTURER/RAM_CAPACITY/RAM_STATUS arrays (one entry per
# physical slot) via dmidecode - which needs root on most distros. Without
# it, RAM_INTEGRATED is set but this means "couldn't verify", not
# necessarily "genuinely soldered" - the report wording reflects that.
RAM_TOTAL="N/A"
RAM_INTEGRATED="0"
declare -a RAM_SLOT RAM_MANUFACTURER RAM_CAPACITY RAM_STATUS

get_ram_info() {
    RAM_SLOT=(); RAM_MANUFACTURER=(); RAM_CAPACITY=(); RAM_STATUS=()
    RAM_INTEGRATED="0"

    local total_kb
    total_kb=$(run_cmd grep -m1 MemTotal /proc/meminfo | grep -oE '[0-9]+' | head -1)
    if [[ -n "$total_kb" ]]; then
        RAM_TOTAL="$(awk -v kb="$total_kb" 'BEGIN { printf "%.2f GB", kb/1024/1024 }')"
    fi

    if ! has_command dmidecode; then
        RAM_INTEGRATED="1"
        return 0
    fi

    local dmi_out
    dmi_out=$(run_cmd dmidecode -t memory)
    if [[ -z "$dmi_out" ]]; then
        RAM_INTEGRATED="1"
        return 0
    fi

    local locator manufacturer size
    while IFS='|' read -r locator manufacturer size; do
        [[ -z "$locator" && -z "$size" ]] && continue
        RAM_SLOT+=("${locator:-N/A}")
        if [[ -z "$size" || "$size" == "No Module Installed" ]]; then
            RAM_STATUS+=("Vide")
            RAM_MANUFACTURER+=("")
            RAM_CAPACITY+=("")
        else
            RAM_STATUS+=("Occupe")
            RAM_MANUFACTURER+=("${manufacturer:-N/A}")
            RAM_CAPACITY+=("$size")
        fi
    done < <(printf '%s\n' "$dmi_out" | awk '
        /^Memory Device$/ {
            if (started) print locator "|" manufacturer "|" size
            locator=""; manufacturer=""; size=""; started=1
        }
        /^[[:space:]]*Size: / { sub(/^[[:space:]]*Size: /, ""); size=$0 }
        /^[[:space:]]*Locator: / && $0 !~ /Bank Locator/ { sub(/^[[:space:]]*Locator: /, ""); locator=$0 }
        /^[[:space:]]*Manufacturer: / { sub(/^[[:space:]]*Manufacturer: /, ""); manufacturer=$0 }
        END { if (started) print locator "|" manufacturer "|" size }
    ')

    if [[ ${#RAM_SLOT[@]} -eq 0 ]]; then
        RAM_INTEGRATED="1"
    fi
}

# --------------------------------------------------------------------------
# Disks + SMART
# --------------------------------------------------------------------------

# Parses `lsblk -P` output ("KEY=\"value\" KEY2=\"value2\" ...") for one
# line into the LSBLK_FIELDS associative array.
declare -A LSBLK_FIELDS
parse_kv_line() {
    LSBLK_FIELDS=()
    local rest="$1" key value
    while [[ "$rest" =~ ^([A-Za-z:_]+)=\"([^\"]*)\"[[:space:]]*(.*)$ ]]; do
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        rest="${BASH_REMATCH[3]}"
        LSBLK_FIELDS["$key"]="$value"
    done
}

declare -a DISK_NAME DISK_TYPE DISK_SIZE DISK_MODEL DISK_SERIAL DISK_TRAN
# Populated per-disk by main() right after get_disk_list, via get_smart_data
# and disk_health_status (kept as parallel arrays, indexed like DISK_NAME)
declare -a DISK_SMART_AVAILABLE DISK_SMART_ERRORS DISK_SMART_HOURS DISK_SMART_TEMP DISK_SMART_WEAR
declare -a DISK_SMART_MODEL DISK_SMART_SERIAL DISK_SMART_FIRMWARE
declare -a DISK_HEALTH  # each entry: "status|label|css_class|alert_message"

get_disk_list() {
    DISK_NAME=(); DISK_TYPE=(); DISK_SIZE=(); DISK_MODEL=(); DISK_SERIAL=(); DISK_TRAN=()
    has_command lsblk || return 0
    local line
    # `|| [[ -n "$line" ]]` matters: read fails (without an error) on a final
    # line that lacks a trailing newline - very possible here since these
    # loops often consume output already captured via $(...), which always
    # strips trailing newlines. Without this, the last line is silently
    # skipped whenever the field being searched for happens to be on it.
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        parse_kv_line "$line"
        [[ "${LSBLK_FIELDS[TYPE]:-}" == "disk" ]] || continue
        DISK_NAME+=("${LSBLK_FIELDS[NAME]:-}")
        if [[ "${LSBLK_FIELDS[ROTA]:-0}" == "1" ]]; then DISK_TYPE+=("HDD"); else DISK_TYPE+=("SSD"); fi
        DISK_SIZE+=("${LSBLK_FIELDS[SIZE]:-N/A}")
        DISK_MODEL+=("${LSBLK_FIELDS[MODEL]:-N/A}")
        DISK_SERIAL+=("${LSBLK_FIELDS[SERIAL]:-N/A}")
        DISK_TRAN+=("${LSBLK_FIELDS[TRAN]:-N/A}")
    done < <(run_cmd lsblk -P -o NAME,TYPE,SIZE,MODEL,SERIAL,TRAN,ROTA)
}

# Queries smartctl for one disk (falling back to "no SMART data" if smartctl
# is missing/fails/needs root). Sets the SMART_RESULT_* globals; the caller
# copies them into per-disk arrays right after calling this.
SMART_RESULT_AVAILABLE="0"
SMART_RESULT_ERRORS="N/A"; SMART_RESULT_HOURS="N/A"; SMART_RESULT_TEMP="N/A"; SMART_RESULT_WEAR="N/A"
SMART_RESULT_MODEL=""; SMART_RESULT_SERIAL=""; SMART_RESULT_FIRMWARE=""

get_smart_data() {
    local disk_name="$1" tran="${2:-}"
    SMART_RESULT_AVAILABLE="0"
    SMART_RESULT_ERRORS="N/A"; SMART_RESULT_HOURS="N/A"; SMART_RESULT_TEMP="N/A"; SMART_RESULT_WEAR="N/A"
    SMART_RESULT_MODEL=""; SMART_RESULT_SERIAL=""; SMART_RESULT_FIRMWARE=""

    has_command smartctl || return 1

    local device="/dev/$disk_name"
    local dev_types
    if [[ "$tran" == "nvme" ]]; then dev_types=(nvme ata sat scsi); else dev_types=(sat ata nvme scsi); fi

    local dtype output
    for dtype in "${dev_types[@]}"; do
        output=$(run_cmd sudo -n smartctl -d "$dtype" -a "$device")
        [[ -z "$output" ]] && output=$(run_cmd smartctl -d "$dtype" -a "$device")
        [[ -z "$output" ]] && continue
        printf '%s' "$output" | grep -qE 'Reallocated_Sector_Ct|Power_On_Hours|Power-On_Hours|Data Units Written|Percentage Used' || continue

        local errors hours temp wear
        errors=$(printf '%s' "$output" | smart_numeric_value 1 "Reallocated_Sector_Ct")
        [[ -z "$errors" ]] && errors=$(printf '%s' "$output" | smart_numeric_value 0 "Media and Data Integrity Errors:")

        hours=$(printf '%s' "$output" | smart_numeric_value 1 "Power_On_Hours" "Power-On_Hours")
        [[ -z "$hours" ]] && hours=$(printf '%s' "$output" | smart_numeric_value 0 "^Power On Hours:")

        temp=$(printf '%s' "$output" | smart_numeric_value 0 "Temperature:")
        [[ -z "$temp" ]] && temp=$(printf '%s' "$output" | smart_numeric_value 1 "Temperature_Celsius")
        if [[ -n "$temp" ]] && ! ( [[ "$temp" -gt 0 && "$temp" -lt 100 ]] ); then temp=""; fi

        wear=$(printf '%s' "$output" | smart_numeric_value 1 "Percent_Lifetime_Remain" "Wear_Leveling_Count")
        if [[ -n "$wear" ]]; then
            SMART_RESULT_WEAR="${wear}% restant"
        else
            wear=$(printf '%s' "$output" | smart_numeric_value 0 "Percentage Used")
            [[ -n "$wear" ]] && SMART_RESULT_WEAR="${wear}% use"
        fi

        SMART_RESULT_AVAILABLE="1"
        SMART_RESULT_ERRORS="${errors:-N/A}"
        SMART_RESULT_HOURS="${hours:-N/A}"
        SMART_RESULT_TEMP="${temp:-N/A}"
        SMART_RESULT_MODEL=$(printf '%s' "$output" | grep -m1 -E 'Device Model:|Model Number:' | sed -E 's/.*(Device Model|Model Number):[[:space:]]*//')
        SMART_RESULT_SERIAL=$(printf '%s' "$output" | grep -m1 'Serial Number:' | sed -E 's/.*Serial Number:[[:space:]]*//')
        SMART_RESULT_FIRMWARE=$(printf '%s' "$output" | grep -m1 'Firmware Version:' | sed -E 's/.*Firmware Version:[[:space:]]*//')
        return 0
    done
    return 1
}

# --------------------------------------------------------------------------
# Battery (via /sys/class/power_supply - a stable kernel sysfs ABI, more
# reliable across distros than any single userspace tool's text output)
# --------------------------------------------------------------------------

# Echoes: has_battery(0|1)|serial|manufacturer|model|cycles|health_pct|health_status
get_battery_info() {
    local good="${1:-80}" warning="${2:-60}" critical="${3:-40}" base_dir="${4:-/sys/class/power_supply}"
    local bat_dir="" d
    for d in "$base_dir"/BAT*; do
        [[ -d "$d" ]] && bat_dir="$d" && break
    done
    if [[ -z "$bat_dir" ]]; then
        printf '0||||||'
        return
    fi

    local manufacturer model serial cycles energy_full energy_full_design
    manufacturer=$(trim "$(run_cmd cat "$bat_dir/manufacturer")")
    model=$(trim "$(run_cmd cat "$bat_dir/model_name")")
    serial=$(trim "$(run_cmd cat "$bat_dir/serial_number")")
    cycles=$(trim "$(run_cmd cat "$bat_dir/cycle_count")")

    # Some kernels/drivers expose energy_* (uWh), others charge_* (uAh) -
    # use whichever pair is actually present
    energy_full=$(trim "$(run_cmd cat "$bat_dir/energy_full")")
    energy_full_design=$(trim "$(run_cmd cat "$bat_dir/energy_full_design")")
    if [[ -z "$energy_full" || -z "$energy_full_design" ]]; then
        energy_full=$(trim "$(run_cmd cat "$bat_dir/charge_full")")
        energy_full_design=$(trim "$(run_cmd cat "$bat_dir/charge_full_design")")
    fi

    local health_pct=""
    if [[ -n "$energy_full" && -n "$energy_full_design" && "$energy_full_design" -gt 0 ]]; then
        health_pct=$(awk -v f="$energy_full" -v d="$energy_full_design" 'BEGIN { printf "%.2f", (f/d)*100 }')
    fi

    local health_status="Inconnu"
    if [[ -n "$health_pct" ]]; then
        local hp_int="${health_pct%.*}"
        if (( hp_int >= good )); then health_status="Excellent"
        elif (( hp_int >= warning )); then health_status="Bon"
        elif (( hp_int >= critical )); then health_status="Attention"
        else health_status="Critique"
        fi
    fi

    printf '1|%s|%s|%s|%s|%s|%s' "${serial:-N/A}" "${manufacturer:-N/A}" "${model:-N/A}" "${cycles:-N/A}" "${health_pct:-N/A}" "$health_status"
}

# --------------------------------------------------------------------------
# Network / LUKS encryption / OS info
# --------------------------------------------------------------------------

declare -a NET_NAME NET_MAC
get_network_info() {
    NET_NAME=(); NET_MAC=()
    has_command ip || return 0
    local line name mac
    # `|| [[ -n "$line" ]]` matters: read fails (without an error) on a final
    # line that lacks a trailing newline - very possible here since these
    # loops often consume output already captured via $(...), which always
    # strips trailing newlines. Without this, the last line is silently
    # skipped whenever the field being searched for happens to be on it.
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[0-9]+:[[:space:]]+([^:@[:space:]]+)(@[^:]+)?:.*link/ether[[:space:]]+([0-9a-fA-F:]+) ]]; then
            name="${BASH_REMATCH[1]}"
            mac="${BASH_REMATCH[3]}"
            [[ "$name" == "lo" ]] && continue
            [[ "$mac" == "00:00:00:00:00:00" ]] && continue
            NET_NAME+=("$name")
            NET_MAC+=("$mac")
        fi
    done < <(run_cmd ip -o link show)
}

ENCRYPTION_STATUS="Unavailable"
declare -a LUKS_NAME
get_encryption_info() {
    LUKS_NAME=()
    ENCRYPTION_STATUS="Unavailable"
    has_command lsblk || return 0
    ENCRYPTION_STATUS="OK"
    local line
    # `|| [[ -n "$line" ]]` matters: read fails (without an error) on a final
    # line that lacks a trailing newline - very possible here since these
    # loops often consume output already captured via $(...), which always
    # strips trailing newlines. Without this, the last line is silently
    # skipped whenever the field being searched for happens to be on it.
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        parse_kv_line "$line"
        if [[ "${LSBLK_FIELDS[FSTYPE]:-}" == "crypto_LUKS" ]]; then
            LUKS_NAME+=("${LSBLK_FIELDS[NAME]:-}")
        fi
    done < <(run_cmd lsblk -P -o NAME,FSTYPE)
}

get_os_info() {
    local name=""
    if [[ -r /etc/os-release ]]; then
        # os-release is documented (systemd spec) to be safe to source: a
        # plain shell-compatible KEY=VALUE file, not arbitrary/untrusted input
        name=$(run_cmd bash -c 'source /etc/os-release 2>/dev/null && printf "%s" "$PRETTY_NAME"')
    fi
    printf '%s' "${name:-N/A}"
}

# --------------------------------------------------------------------------
# Reports folder maintenance
# --------------------------------------------------------------------------

remove_old_reports() {
    local reports_dir="$1" max_age_days="$2"
    [[ "$max_age_days" -gt 0 ]] || return 0
    [[ -d "$reports_dir" ]] || return 0
    local f
    while IFS= read -r -d '' f || [[ -n "$f" ]]; do
        rm -f -- "$f"
        echo "Rapport ancien supprime (${max_age_days}+ jours): $(basename -- "$f")"
    done < <(find "$reports_dir" -maxdepth 1 -type f \( -name '*.html' -o -name '*.json' \) -mtime "+${max_age_days}" -print0 2>/dev/null)
}

# Ad-hoc extractors for OUR OWN generated JSON, not a general parser - fine
# since this script both writes and reads that exact format. Relies on
# "System" being the first section written (see build_json_report) so the
# first "Model"/"Brand"/"SerialNumber" match is the system's, not the CPU's
# or a disk's (which use some of the same key names).
json_get() {
    local file="$1" key="$2"
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | head -1 | sed -E "s/.*: *\"([^\"]*)\"/\1/"
}
json_get_num() {
    local file="$1" key="$2"
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9.]*" "$file" 2>/dev/null | head -1 | sed -E 's/.*: *//'
}

update_report_index() {
    local reports_dir="$1"
    local rows="" count=0
    local jf html_file generated_at asset_tag brand model serial score label recommendation badge_class

    while IFS= read -r jf; do
        html_file="${jf%.json}.html"
        [[ -f "$html_file" ]] || continue

        generated_at=$(json_get "$jf" "GeneratedAt")
        asset_tag=$(json_get "$jf" "AssetTag")
        brand=$(json_get "$jf" "Brand")
        model=$(json_get "$jf" "Model")
        serial=$(json_get "$jf" "SerialNumber")
        score=$(json_get_num "$jf" "Score")
        label=$(json_get "$jf" "Label")
        recommendation=$(json_get "$jf" "Recommendation")
        badge_class=$(json_get "$jf" "BadgeClass")

        rows+="<tr><td>$(html_escape "$generated_at")</td><td>$(html_escape "$asset_tag")</td>"
        rows+="<td>$(html_escape "$brand") $(html_escape "$model")</td><td>$(html_escape "$serial")</td>"
        rows+="<td><span class='status-badge ${badge_class}'>${score:-?}/100 - $(html_escape "$label")</span></td>"
        rows+="<td>$(html_escape "$recommendation")</td>"
        rows+="<td><a href='$(html_escape "$(basename -- "$html_file")")'>Ouvrir</a></td></tr>"
        (( count++ ))
    done < <(find "$reports_dir" -maxdepth 1 -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)

    [[ "$count" -eq 0 ]] && return 1

    cat > "$reports_dir/index.html" <<EOF
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>Index des rapports - CompStats for Recycle</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Verdana, sans-serif; margin: 20px; background-color: #f4f4f4; color: #333; }
        .container { max-width: 1400px; margin: auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }
        h1 { text-align: center; color: #2c3e50; }
        table { border-collapse: collapse; width: 100%; margin-top: 10px; }
        th, td { border: 1px solid #ddd; padding: 10px; text-align: left; }
        th { background-color: #f8f9fa; font-weight: bold; }
        tr:nth-child(even) { background-color: #f8f9fa; }
        .status-badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-weight: bold; font-size: 0.9em; }
        .status-ok { background: #27ae60; color: white; }
        .status-warning { background: #f39c12; color: white; }
        .status-bad { background: #e74c3c; color: white; }
        a { color: #3498db; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Index des rapports ($count)</h1>
        <table>
            <tr><th>Date</th><th>Reference</th><th>Modele</th><th>Numero de serie</th><th>Etat</th><th>Recommandation</th><th></th></tr>
            $rows
        </table>
    </div>
</body>
</html>
EOF
    printf '%s/index.html' "$reports_dir"
}

# --------------------------------------------------------------------------
# JSON export
#
# Built from the globals main() populates after calling the collection
# functions above (SYS_*, CPU_*, BATTERY_*, OS_NAME, GA_*, ASSET_TAG) plus
# the DISK_*/GPU_NAME/NET_NAME+NET_MAC/RAM_* arrays. "System" is written
# FIRST deliberately - see update_report_index's ad-hoc extractor, which
# relies on that ordering to find System.Model before CPU.Model.
# --------------------------------------------------------------------------

build_json_report() {
    local json="{"
    json+="\"GeneratedAt\":$(json_str "$(date '+%Y-%m-%d %H:%M:%S')"),"
    json+="\"ScriptVersion\":$(json_str "$SCRIPT_VERSION"),"
    json+="\"AssetTag\":$(json_str "$ASSET_TAG"),"
    json+="\"System\":{\"Brand\":$(json_str "$SYS_BRAND"),\"Model\":$(json_str "$SYS_MODEL"),\"SerialNumber\":$(json_str "$SYS_SERIAL"),\"BiosDate\":$(json_str "$SYS_BIOS_DATE")},"
    json+="\"CPU\":{\"Brand\":$(json_str "$CPU_BRAND"),\"Model\":$(json_str "$CPU_MODEL")},"
    json+="\"OS\":{\"Name\":$(json_str "$OS_NAME")},"

    json+="\"GPU\":["
    local i first=1
    for i in "${!GPU_NAME[@]}"; do
        [[ $first -eq 1 ]] && first=0 || json+=","
        json+="{\"Name\":$(json_str "${GPU_NAME[$i]}")}"
    done
    json+="],"

    json+="\"Network\":["
    first=1
    for i in "${!NET_NAME[@]}"; do
        [[ $first -eq 1 ]] && first=0 || json+=","
        json+="{\"Name\":$(json_str "${NET_NAME[$i]}"),\"MACAddress\":$(json_str "${NET_MAC[$i]}")}"
    done
    json+="],"

    json+="\"RAM\":{\"Total\":$(json_str "$RAM_TOTAL"),\"Integrated\":$([[ "$RAM_INTEGRATED" == "1" ]] && echo true || echo false),\"Modules\":["
    first=1
    for i in "${!RAM_SLOT[@]}"; do
        [[ $first -eq 1 ]] && first=0 || json+=","
        json+="{\"Slot\":$(json_str "${RAM_SLOT[$i]}"),\"Status\":$(json_str "${RAM_STATUS[$i]}"),\"Manufacturer\":$(json_str "${RAM_MANUFACTURER[$i]}"),\"Capacity\":$(json_str "${RAM_CAPACITY[$i]}")}"
    done
    json+="]},"

    json+="\"Disks\":["
    first=1
    for i in "${!DISK_NAME[@]}"; do
        [[ $first -eq 1 ]] && first=0 || json+=","
        json+="{\"DeviceID\":$(json_str "${DISK_NAME[$i]}"),\"Type\":$(json_str "${DISK_TYPE[$i]}"),"
        json+="\"Size\":$(json_str "${DISK_SIZE[$i]}"),\"BusProtocol\":$(json_str "${DISK_TRAN[$i]}"),"
        json+="\"MediaName\":$(json_str "${DISK_MODEL[$i]}"),"
        if [[ "${DISK_SMART_AVAILABLE[$i]}" == "1" ]]; then
            json+="\"SMART\":{\"Errors\":$(json_str "${DISK_SMART_ERRORS[$i]}"),\"Hours\":$(json_str "${DISK_SMART_HOURS[$i]}"),"
            json+="\"Temp\":$(json_str "${DISK_SMART_TEMP[$i]}"),\"WearLevel\":$(json_str "${DISK_SMART_WEAR[$i]}"),"
            json+="\"Model\":$(json_str "${DISK_SMART_MODEL[$i]}"),\"Serial\":$(json_str "${DISK_SMART_SERIAL[$i]}"),"
            json+="\"Firmware\":$(json_str "${DISK_SMART_FIRMWARE[$i]}"),\"Source\":\"smartctl\"}"
        else
            json+="\"SMART\":null"
        fi
        json+="}"
    done
    json+="],"

    json+="\"Encryption\":{\"Status\":$(json_str "$ENCRYPTION_STATUS"),\"Volumes\":["
    first=1
    for i in "${!LUKS_NAME[@]}"; do
        [[ $first -eq 1 ]] && first=0 || json+=","
        json+="{\"MountPoint\":$(json_str "${LUKS_NAME[$i]}"),\"ProtectionStatus\":\"Chiffre\",\"EncryptionMethod\":\"LUKS\"}"
    done
    json+="]},"

    if [[ "$BATTERY_HAS" == "1" ]]; then
        json+="\"Battery\":{\"SerialNumber\":$(json_str "$BATTERY_SERIAL"),\"Manufacturer\":$(json_str "$BATTERY_MANUFACTURER"),"
        json+="\"Age\":$(json_str "${BATTERY_CYCLES} cycles"),\"Health\":$(json_str "${BATTERY_HEALTH_PCT}%"),"
        json+="\"HealthValue\":$(json_num_or_null "$BATTERY_HEALTH_PCT"),\"HealthStatus\":$(json_str "$BATTERY_HEALTH_STATUS")},"
    else
        json+="\"Battery\":null,"
    fi

    json+="\"GlobalAssessment\":{\"Score\":$(json_num_or_null "$GA_SCORE"),\"Label\":$(json_str "$GA_LABEL"),\"Recommendation\":$(json_str "$GA_RECOMMENDATION"),\"BadgeClass\":$(json_str "$GA_BADGE_CLASS")}"
    json+="}"
    printf '%s' "$json"
}

# --------------------------------------------------------------------------
# HTML report
# --------------------------------------------------------------------------

REPORT_CSS='
body { font-family: "Segoe UI", Tahoma, Verdana, sans-serif; margin: 20px; background-color: #f4f4f4; color: #333; }
.container { max-width: 1200px; margin: auto; background: white; padding: 20px; border-radius: 8px; box-shadow: 0 0 10px rgba(0,0,0,0.1); }
h1 { text-align: center; color: #2c3e50; }
.section { margin-bottom: 30px; }
h2 { border-bottom: 2px solid #3498db; padding-bottom: 5px; color: #2c3e50; }
table { border-collapse: collapse; width: 100%; margin-top: 10px; }
th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
th { background-color: #f8f9fa; font-weight: bold; }
tr:nth-child(even) { background-color: #f8f9fa; }
.health-good { color: green; }
.health-warning { color: orange; }
.health-bad { color: red; }
.summary-card { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 10px; margin-bottom: 30px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
.summary-card h2 { border: none; color: white; margin-top: 0; font-size: 1.2em; }
.summary-grid { display: flex; flex-wrap: wrap; gap: 15px; margin-top: 15px; }
.summary-item { background: rgba(255,255,255,0.2); padding: 10px 15px; border-radius: 5px; flex: 1; min-width: 150px; }
.summary-label { font-weight: bold; font-size: 0.9em; opacity: 0.9; }
.summary-value { font-size: 1.1em; margin-top: 5px; }
.status-badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-weight: bold; font-size: 0.9em; }
.status-ok { background: #27ae60; color: white; }
.status-warning { background: #f39c12; color: white; }
.status-bad { background: #e74c3c; color: white; }
.disk-card { margin-bottom: 20px; border: 1px solid #ddd; padding: 10px; border-radius: 5px; }
@media print {
    body { background: white; }
    .container { box-shadow: none; max-width: 100%; }
    .summary-card { background: white; color: #333; border: 2px solid #667eea; box-shadow: none; }
    .summary-card h2, .summary-label { color: #333; }
    .summary-item { background: #f4f4f4; }
    .status-ok, .status-warning, .status-bad { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    .section, .disk-card { page-break-inside: avoid; }
}
'

build_html_report() {
    local summary_disks_html="$1" summary_disks_battery_html="$2"

    local ram_html
    if [[ "$RAM_INTEGRATED" == "1" ]]; then
        ram_html="<p><em>D&eacute;tail par module non disponible (n&eacute;cessite dmidecode, souvent avec les droits root).</em></p>"
    else
        ram_html="<table><tr><th>Slot</th><th>Statut</th><th>Marque</th><th>Capacit&eacute;</th></tr>"
        local i
        for i in "${!RAM_SLOT[@]}"; do
            ram_html+="<tr><td>$(html_escape "${RAM_SLOT[$i]}")</td><td>$(html_escape "${RAM_STATUS[$i]}")</td><td>$(html_escape "${RAM_MANUFACTURER[$i]}")</td><td>$(html_escape "${RAM_CAPACITY[$i]}")</td></tr>"
        done
        ram_html+="</table>"
    fi

    local gpu_html="" i
    for i in "${!GPU_NAME[@]}"; do
        gpu_html+="<table style='margin-bottom: 10px;'><tr><th>Mod&egrave;le</th><td>$(html_escape "${GPU_NAME[$i]}")</td></tr></table>"
    done
    [[ -z "$gpu_html" ]] && gpu_html="<p>Non d&eacute;tect&eacute;e</p>"

    local network_html="<table><tr><th>Interface</th><th>Adresse MAC</th></tr>"
    for i in "${!NET_NAME[@]}"; do
        network_html+="<tr><td>$(html_escape "${NET_NAME[$i]}")</td><td>$(html_escape "${NET_MAC[$i]}")</td></tr>"
    done
    network_html+="</table>"

    local disks_html="" health status label css_class alert
    for i in "${!DISK_NAME[@]}"; do
        IFS='|' read -r status label css_class alert <<< "${DISK_HEALTH[$i]}"
        disks_html+="<div class='disk-card'><table>"
        disks_html+="<tr><th>Type</th><td>$(html_escape "${DISK_TYPE[$i]}")</td></tr>"
        disks_html+="<tr><th>Taille</th><td>$(html_escape "${DISK_SIZE[$i]}")</td></tr>"
        disks_html+="<tr><th>Mod&egrave;le</th><td>$(html_escape "${DISK_MODEL[$i]}")</td></tr>"
        disks_html+="<tr><th>Bus</th><td>$(html_escape "${DISK_TRAN[$i]}")</td></tr>"
        if [[ "${DISK_SMART_AVAILABLE[$i]}" == "1" ]]; then
            [[ -n "${DISK_SMART_MODEL[$i]}" ]] && disks_html+="<tr><th>Mod&egrave;le (SMART)</th><td>$(html_escape "${DISK_SMART_MODEL[$i]}")</td></tr>"
            [[ -n "${DISK_SMART_SERIAL[$i]}" ]] && disks_html+="<tr><th>Num&eacute;ro de s&eacute;rie</th><td>$(html_escape "${DISK_SMART_SERIAL[$i]}")</td></tr>"
            [[ -n "${DISK_SMART_FIRMWARE[$i]}" ]] && disks_html+="<tr><th>Firmware</th><td>$(html_escape "${DISK_SMART_FIRMWARE[$i]}")</td></tr>"
            disks_html+="<tr><th>Secteurs r&eacute;allou&eacute;s</th><td class='${css_class}'>$(html_escape "${DISK_SMART_ERRORS[$i]}")</td></tr>"
            disks_html+="<tr><th>Heures utilisation</th><td>$(html_escape "${DISK_SMART_HOURS[$i]}")</td></tr>"
            disks_html+="<tr><th>Temp&eacute;rature</th><td class='${css_class}'>$(html_escape "${DISK_SMART_TEMP[$i]}")</td></tr>"
            disks_html+="<tr><th>Niveau d'usure</th><td>$(html_escape "${DISK_SMART_WEAR[$i]}")</td></tr>"
        else
            disks_html+="<tr><th>SMART</th><td>Non disponible (smartctl absent ou droits insuffisants)</td></tr>"
        fi
        disks_html+="<tr><th>Etat de sant&eacute;</th><td class='${css_class}'><strong>$(html_escape "$label")</strong></td></tr>"
        [[ -n "$alert" ]] && disks_html+="<tr><th>Alerte</th><td class='health-bad'>$(html_escape "$alert")</td></tr>"
        disks_html+="</table></div>"
    done
    [[ -z "$disks_html" ]] && disks_html="<p>Aucun disque d&eacute;tect&eacute;</p>"

    local battery_html
    if [[ "$BATTERY_HAS" == "1" ]]; then
        local bh_class="health-warning"
        local bh_int="${BATTERY_HEALTH_PCT%.*}"
        if [[ -n "$bh_int" ]] && (( bh_int >= 80 )); then bh_class="health-good"
        elif [[ -n "$bh_int" ]] && (( bh_int < 60 )); then bh_class="health-bad"; fi
        battery_html="<table>"
        battery_html+="<tr><th>Fabricant</th><td>$(html_escape "$BATTERY_MANUFACTURER")</td></tr>"
        battery_html+="<tr><th>Num&eacute;ro de s&eacute;rie</th><td>$(html_escape "$BATTERY_SERIAL")</td></tr>"
        battery_html+="<tr><th>Age approximatif</th><td>$(html_escape "${BATTERY_CYCLES} cycles")</td></tr>"
        battery_html+="<tr><th>Etat de sant&eacute;</th><td class='${bh_class}'>${BATTERY_HEALTH_PCT}% (${BATTERY_HEALTH_STATUS})</td></tr>"
        battery_html+="</table>"
    else
        battery_html="<p>Aucune batterie d&eacute;tect&eacute;e</p>"
    fi

    local encryption_html
    if [[ "$ENCRYPTION_STATUS" == "OK" ]]; then
        encryption_html="<table><tr><th>Volume</th><th>Statut</th></tr>"
        for i in "${!LUKS_NAME[@]}"; do
            encryption_html+="<tr><td>$(html_escape "${LUKS_NAME[$i]}")</td><td class='health-warning'>Chiffre (LUKS)</td></tr>"
        done
        [[ ${#LUKS_NAME[@]} -eq 0 ]] && encryption_html+="<tr><td colspan='2'>Aucun volume chiffre detecte</td></tr>"
        encryption_html+="</table>"
    else
        encryption_html="<p><em>Statut de chiffrement non v&eacute;rifi&eacute; (lsblk indisponible).</em></p>"
    fi

    local generated_at
    generated_at=$(date '+%Y-%m-%d %H:%M:%S')

    cat <<HTMLEOF
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <title>CompStats for Recycle</title>
    <style>${REPORT_CSS}</style>
</head>
<body>
    <div class="container">
        <h1>Statistiques Ordinateur pour Recyclage</h1>
        <p><strong>Date de generation:</strong> ${generated_at}</p>

        <div class="summary-card">
            <h2>Resume de Sante</h2>
            <div class="summary-grid">
                <div class="summary-item">
                    <div class="summary-label">Etat global</div>
                    <div class="summary-value"><span class='status-badge ${GA_BADGE_CLASS}'>${GA_SCORE}/100 - $(html_escape "$GA_LABEL")</span></div>
                </div>
                <div class="summary-item">
                    <div class="summary-label">Modele</div>
                    <div class="summary-value">$(html_escape "$SYS_MODEL") ($(html_escape "$SYS_SERIAL"))</div>
                </div>
                <div class="summary-item">
                    <div class="summary-label">Disques</div>
                    <div class="summary-value">${summary_disks_html}</div>
                </div>
                <div class="summary-item">
                    <div class="summary-label">Batterie</div>
                    <div class="summary-value">${summary_disks_battery_html}</div>
                </div>
            </div>
            <p style="margin-top: 15px; margin-bottom: 0;"><strong>Recommandation :</strong> $(html_escape "$GA_RECOMMENDATION")</p>
        </div>

        <div class="section">
            <h2>Systeme</h2>
            <table>
                <tr><th>Marque</th><td>$(html_escape "$SYS_BRAND")</td></tr>
                <tr><th>Modele</th><td>$(html_escape "$SYS_MODEL")</td></tr>
                <tr><th>Numero de serie</th><td>$(html_escape "$SYS_SERIAL")</td></tr>
                <tr><th>Date BIOS</th><td>$(html_escape "$SYS_BIOS_DATE")</td></tr>
                <tr><th>Distribution</th><td>$(html_escape "$OS_NAME")</td></tr>
            </table>
        </div>

        <div class="section">
            <h2>CPU</h2>
            <table>
                <tr><th>Marque</th><td>$(html_escape "$CPU_BRAND")</td></tr>
                <tr><th>Modele</th><td>$(html_escape "$CPU_MODEL")</td></tr>
            </table>
        </div>

        <div class="section">
            <h2>Carte graphique</h2>
            ${gpu_html}
        </div>

        <div class="section">
            <h2>Reseau</h2>
            ${network_html}
        </div>

        <div class="section">
            <h2>RAM</h2>
            <p><strong>Total:</strong> $(html_escape "$RAM_TOTAL")</p>
            ${ram_html}
        </div>

        <div class="section">
            <h2>Disques</h2>
            ${disks_html}
        </div>

        <div class="section">
            <h2>Chiffrement (LUKS)</h2>
            ${encryption_html}
        </div>

        <div class="section">
            <h2>Batterie</h2>
            ${battery_html}
        </div>
    </div>
    <footer style="text-align: center; margin-top: 30px; padding: 15px; background: #f8f9fa; border-radius: 5px; font-size: 0.9em; color: #666;">
        <p><strong>CompStats for Recycle v${SCRIPT_VERSION} (Linux)</strong> - Copyright (c) 2026 Guillaume COQUEBLIN (esquimo.org)</p>
        <p><a href="https://github.com/eskiiom/compstats4recycle" target="_blank">https://github.com/eskiiom/compstats4recycle</a></p>
    </footer>
</body>
</html>
HTMLEOF
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

safe_filename_part() {
    printf '%s' "$1" | sed -E 's/[\\/:*?"<>|]/_/g'
}

print_usage() {
    cat <<EOF
Usage: $(basename -- "$0") [options]

  --no-json                        Ne pas ecrire l'export JSON
  --no-csv-log                     Ne pas ajouter de ligne au CSV consolide
  --no-index                       Ne pas regenerer Rapports/index.html
  --asset-tag REF                  Reference d'inventaire interne optionnelle
  --battery-good-threshold N       Defaut 80
  --battery-warning-threshold N    Defaut 60
  --battery-critical-threshold N   Defaut 40
  --disk-temp-warning-threshold N  Defaut 50
  --score-good-threshold N         Defaut 80
  --score-warning-threshold N      Defaut 50
  --purge-reports-older-than-days N  Defaut 0 (desactive)
  -h, --help                       Affiche cette aide
EOF
}

main() {
    if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
        echo "Attention : ce script est concu pour Linux (uname -s != Linux)." >&2
    fi

    local no_json=0 no_csv_log=0 no_index=0
    ASSET_TAG=""
    local battery_good=80 battery_warning=60 battery_critical=40
    local disk_temp_threshold=50 score_good=80 score_warning=50
    local purge_days=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-json) no_json=1; shift ;;
            --no-csv-log) no_csv_log=1; shift ;;
            --no-index) no_index=1; shift ;;
            --asset-tag) ASSET_TAG="${2:-}"; shift 2 ;;
            --battery-good-threshold) battery_good="${2:-80}"; shift 2 ;;
            --battery-warning-threshold) battery_warning="${2:-60}"; shift 2 ;;
            --battery-critical-threshold) battery_critical="${2:-40}"; shift 2 ;;
            --disk-temp-warning-threshold) disk_temp_threshold="${2:-50}"; shift 2 ;;
            --score-good-threshold) score_good="${2:-80}"; shift 2 ;;
            --score-warning-threshold) score_warning="${2:-50}"; shift 2 ;;
            --purge-reports-older-than-days) purge_days="${2:-0}"; shift 2 ;;
            -h|--help) print_usage; return 0 ;;
            *) echo "Option inconnue: $1" >&2; print_usage; return 1 ;;
        esac
    done

    echo "======================================"
    echo "CompStats for Recycle v${SCRIPT_VERSION} Linux (${SCRIPT_DATE})"
    echo "Copyright (c) 2026 Guillaume COQUEBLIN"
    echo "https://github.com/eskiiom/compstats4recycle"
    echo "======================================"
    echo ""

    IFS='|' read -r SYS_BRAND SYS_MODEL SYS_SERIAL SYS_BIOS_DATE <<< "$(get_system_info)"
    IFS='|' read -r CPU_BRAND CPU_MODEL <<< "$(get_cpu_info)"
    OS_NAME=$(get_os_info)
    get_gpu_info
    get_network_info
    get_ram_info
    get_disk_list
    get_encryption_info

    IFS='|' read -r BATTERY_HAS BATTERY_SERIAL BATTERY_MANUFACTURER BATTERY_MODEL BATTERY_CYCLES BATTERY_HEALTH_PCT BATTERY_HEALTH_STATUS \
        <<< "$(get_battery_info "$battery_good" "$battery_warning" "$battery_critical")"

    local i status label css_class alert disk_statuses=""
    local summary_disks_html="" summary_disks_plain=""
    for i in "${!DISK_NAME[@]}"; do
        if get_smart_data "${DISK_NAME[$i]}" "${DISK_TRAN[$i]}"; then
            DISK_SMART_AVAILABLE+=("1")
        else
            DISK_SMART_AVAILABLE+=("0")
        fi
        DISK_SMART_ERRORS+=("$SMART_RESULT_ERRORS")
        DISK_SMART_HOURS+=("$SMART_RESULT_HOURS")
        DISK_SMART_TEMP+=("$SMART_RESULT_TEMP")
        DISK_SMART_WEAR+=("$SMART_RESULT_WEAR")
        DISK_SMART_MODEL+=("$SMART_RESULT_MODEL")
        DISK_SMART_SERIAL+=("$SMART_RESULT_SERIAL")
        DISK_SMART_FIRMWARE+=("$SMART_RESULT_FIRMWARE")

        DISK_HEALTH+=("$(disk_health_status "$SMART_RESULT_ERRORS" "$SMART_RESULT_TEMP" "$disk_temp_threshold" "")")
        IFS='|' read -r status label css_class alert <<< "${DISK_HEALTH[$i]}"
        disk_statuses+=" $status"

        local badge="status-ok"
        [[ "$status" == "Attention" ]] && badge="status-warning"
        [[ "$status" == "KO" ]] && badge="status-bad"
        local size_no_gb="${DISK_SIZE[$i]}"
        [[ $i -gt 0 ]] && { summary_disks_html+=" | "; summary_disks_plain+=" | "; }
        summary_disks_html+="Disque $((i+1)) ${size_no_gb} : <span class='status-badge ${badge}'>${status}</span>"
        summary_disks_plain+="Disque $((i+1)) ${size_no_gb} : ${status}"
    done
    [[ -z "$summary_disks_plain" ]] && { summary_disks_html="Aucun disque"; summary_disks_plain="Aucun disque"; }

    local summary_battery_html
    if [[ "$BATTERY_HAS" == "1" ]]; then
        local bh_int="${BATTERY_HEALTH_PCT%.*}"
        local badge="status-ok"
        [[ -n "$bh_int" ]] && (( bh_int < battery_warning )) && badge="status-bad"
        [[ -n "$bh_int" ]] && (( bh_int >= battery_warning && bh_int < battery_good )) && badge="status-warning"
        summary_battery_html="<span class='status-badge ${badge}'>${BATTERY_HEALTH_PCT}%</span>"
    else
        summary_battery_html="N/A"
    fi

    IFS='|' read -r GA_SCORE GA_LABEL GA_RECOMMENDATION GA_BADGE_CLASS <<< \
        "$(global_assessment "$disk_statuses" "$BATTERY_HAS" "${BATTERY_HEALTH_PCT:-100}" \
            "$battery_good" "$battery_warning" "$battery_critical" "$score_good" "$score_warning")"

    local reports_dir="${SCRIPT_DIR}/Rapports"
    mkdir -p "$reports_dir"

    if [[ "$purge_days" -gt 0 ]]; then
        remove_old_reports "$reports_dir" "$purge_days"
    fi

    local date_str asset_prefix filename_base
    date_str=$(date '+%Y-%m-%d_%H-%M-%S')
    asset_prefix=""
    [[ -n "$ASSET_TAG" ]] && asset_prefix="$(safe_filename_part "$ASSET_TAG")_"
    filename_base="${asset_prefix}$(safe_filename_part "$SYS_BRAND")_$(safe_filename_part "$SYS_MODEL")_$(safe_filename_part "$SYS_SERIAL")_${date_str}_CS4Rv${SCRIPT_VERSION}"

    local html_path="${reports_dir}/${filename_base}.html"
    build_html_report "$summary_disks_html" "$summary_battery_html" > "$html_path"
    echo "Rapport genere a $html_path"

    if [[ "$no_json" -eq 0 ]]; then
        local json_path="${reports_dir}/${filename_base}.json"
        build_json_report > "$json_path"
        echo "Export JSON genere a $json_path"
    fi

    if [[ "$no_csv_log" -eq 0 ]]; then
        local csv_path="${reports_dir}/resume.csv"
        if [[ ! -f "$csv_path" ]]; then
            printf 'DateHeure,ReferenceInventaire,Marque,Modele,NumeroSerie,CPU,RAM,Disques,BatterieSante,ScoreGlobal,Recommandation\n' > "$csv_path"
        fi
        local batt_csv="N/A"
        [[ "$BATTERY_HAS" == "1" ]] && batt_csv="${BATTERY_HEALTH_PCT}%"
        printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$ASSET_TAG" "$SYS_BRAND" "$SYS_MODEL" "$SYS_SERIAL" \
            "$CPU_MODEL" "$RAM_TOTAL" "$summary_disks_plain" "$batt_csv" "$GA_SCORE" "$GA_RECOMMENDATION" >> "$csv_path"
        echo "Ligne ajoutee au resume: $csv_path"
    fi

    if [[ "$no_index" -eq 0 && "$no_json" -eq 0 ]]; then
        local index_path
        index_path=$(update_report_index "$reports_dir")
        [[ -n "$index_path" ]] && echo "Index des rapports mis a jour: $index_path"
    fi

    echo ""
    echo "======================================"
    echo "Resume"
    echo "======================================"
    echo "Score global    : ${GA_SCORE}/100 - ${GA_LABEL}"
    echo "Recommandation  : ${GA_RECOMMENDATION}"
    echo "Disques         : ${summary_disks_plain}"
    if [[ "$BATTERY_HAS" == "1" ]]; then
        echo "Batterie        : ${BATTERY_HEALTH_PCT}% (${BATTERY_HEALTH_STATUS})"
    else
        echo "Batterie        : N/A"
    fi
    [[ "$ENCRYPTION_STATUS" != "OK" ]] && echo "Chiffrement     : non verifie"
}

# Only auto-run when executed directly, not when sourced (e.g. by the test
# suite) - mirrors the dot-source guard in windows/CompStats.ps1.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
