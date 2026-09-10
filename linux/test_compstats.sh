#!/usr/bin/env bash
# Self-contained test suite for compstats.sh - no external framework (bats,
# etc.), consistent with the script's own zero-dependency goal. Mocks every
# external command it touches, same spirit as the Windows (Pester) and
# macOS (unittest) suites.
#
# Run with: bash test_compstats.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./compstats.sh

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" desc="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        echo "  [+] $desc"
    else
        echo "  [-] $desc"
        echo "      expected: [$expected]"
        echo "      actual:   [$actual]"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  [+] $desc"
    else
        echo "  [-] $desc (expected to contain: $needle)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  [+] $desc"
    else
        echo "  [-] $desc (expected NOT to contain: $needle)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# --------------------------------------------------------------------------
echo "=== smart_numeric_value (ATA attribute table: value is the LAST"
echo "    number, not the ID) ==="

ata_lines=$'ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE\n  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0\n  9 Power_On_Hours          0x0032   100   100   000    Old_age   Always       -       12345\n194 Temperature_Celsius     0x0022   062   038   000    Old_age   Always       -       30 (Min/Max 20/45)\n177 Wear_Leveling_Count     0x0013   094   094   000    Pre-fail  Always       -       35'

r=$(printf '%s' "$ata_lines" | smart_numeric_value 1 "Reallocated_Sector_Ct")
assert_eq "0" "$r" "reallocated sectors RAW_VALUE, not attribute ID 5"

r=$(printf '%s' "$ata_lines" | smart_numeric_value 1 "Power_On_Hours")
assert_eq "12345" "$r" "power-on hours RAW_VALUE, not attribute ID 9"

r=$(printf '%s' "$ata_lines" | smart_numeric_value 1 "Temperature_Celsius")
assert_eq "30" "$r" "temperature ignores the (Min/Max ...) suffix"

r=$(printf '%s' "$ata_lines" | smart_numeric_value 1 "Wear_Leveling_Count")
assert_eq "35" "$r" "wear-leveling RAW_VALUE, not attribute ID 177"

echo ""
echo "=== smart_numeric_value (NVMe log fields) ==="

nvme_lines=$'Temperature:                       35 Celsius\nPercentage Used:                   1%\nPower On Hours:                    1,234\nMedia and Data Integrity Errors:   0'

r=$(printf '%s' "$nvme_lines" | smart_numeric_value 0 "Temperature:")
assert_eq "35" "$r" "NVMe temperature"

r=$(printf '%s' "$nvme_lines" | smart_numeric_value 0 "^Power On Hours:")
assert_eq "1234" "$r" "NVMe power-on hours strips thousands separator"

r=$(printf '%s' "$nvme_lines" | smart_numeric_value 0 "Percentage Used")
assert_eq "1" "$r" "NVMe wear percentage"

r=$(printf '%s' "$nvme_lines" | smart_numeric_value 0 "Media and Data Integrity Errors:")
assert_eq "0" "$r" "NVMe integrity errors on the LAST line (no trailing newline) is not skipped"

echo ""
echo "=== disk_health_status ==="

r=$(disk_health_status "3" "" "50" "")
assert_contains "$r" "KO|" "KO when reallocated sectors present"

r=$(disk_health_status "0" "62" "50" "")
assert_contains "$r" "Attention|" "Attention (not KO) for a hot but error-free disk"

r=$(disk_health_status "0" "55" "60" "")
assert_contains "$r" "OK|" "respects a custom (higher) temperature threshold"

r=$(disk_health_status "0" "N/A" "50" "FAILING")
assert_contains "$r" "Attention|FAILING|" "falls back to the raw SMART status string"

r=$(disk_health_status "0" "35" "50" "PASSED")
assert_contains "$r" "OK|OK|health-good|" "OK when nominal"

echo ""
echo "=== global_assessment ==="

r=$(global_assessment "OK OK" "1" "95")
assert_contains "$r" "100|Bon etat|" "perfectly healthy machine scores 100"

r=$(global_assessment "KO KO KO" "1" "10")
assert_contains "$r" "0|Critique|" "score never goes below 0"

r=$(global_assessment "OK" "0" "0")
assert_contains "$r" "100|" "battery ignored when there is none (desktop)"

r=$(global_assessment "" "1" "70" "80" "60" "75")
assert_contains "$r" "65|" "custom battery-critical threshold (70% health, critical=75 -> below it)"

echo ""
echo "=== html_escape / json_str ==="

r=$(html_escape '<script>a&b</script>')
assert_eq '&lt;script&gt;a&amp;b&lt;/script&gt;' "$r" "escapes angle brackets and ampersand"

r=$(json_str 'a "quoted" \ value')
assert_eq '"a \"quoted\" \\ value"' "$r" "json_str escapes quotes and backslashes"

r=$(json_str "")
assert_eq "null" "$r" "json_str: empty value becomes null"

echo ""
echo "=== get_cpu_info (mocked /proc/cpuinfo) ==="

grep() {
    if [[ "$*" == *"model name"*"cpuinfo"* ]]; then
        echo "model name	: Intel(R) Core(TM) i7-11850H CPU @ 2.50GHz"
    elif [[ "$*" == *"vendor_id"*"cpuinfo"* ]]; then
        echo "vendor_id	: GenuineIntel"
    else
        command grep "$@"
    fi
}
r=$(get_cpu_info)
assert_eq "Intel|Intel(R) Core(TM) i7-11850H CPU @ 2.50GHz" "$r" "parses brand and model, GenuineIntel -> Intel"
unset -f grep

echo ""
echo "=== dmidecode -t memory block parsing (occupied + empty slot) ==="

dmidecode() {
    cat <<'EOF'
Memory Device
	Size: 8192 MB
	Locator: ChannelA-DIMM0
	Bank Locator: BANK 0
	Manufacturer: Samsung
Memory Device
	Size: No Module Installed
	Locator: ChannelB-DIMM0
	Bank Locator: BANK 1
EOF
}
grep() {
    if [[ "$*" == *"MemTotal"* ]]; then echo "MemTotal:       16777216 kB"; else command grep "$@"; fi
}
has_command() { [[ "$1" == "dmidecode" ]] && return 0 || return 1; }
get_ram_info
assert_eq "0" "$RAM_INTEGRATED" "RAM_INTEGRATED is 0 when dmidecode succeeds"
assert_eq "2" "${#RAM_SLOT[@]}" "two memory slots parsed"
assert_eq "Occupe" "${RAM_STATUS[0]}" "first slot occupied"
assert_eq "Samsung" "${RAM_MANUFACTURER[0]}" "first slot manufacturer"
assert_eq "Vide" "${RAM_STATUS[1]}" "second slot empty"
unset -f dmidecode grep has_command

echo ""
echo "=== get_disk_list (mocked lsblk -P, filters out partitions) ==="

lsblk() {
    cat <<'EOF'
NAME="sda" TYPE="disk" SIZE="500G" MODEL="Samsung SSD 970" SERIAL="S123ABC" TRAN="sata" ROTA="0"
NAME="sda1" TYPE="part" SIZE="500M" MODEL="" SERIAL="" TRAN="" ROTA="0"
NAME="nvme0n1" TYPE="disk" SIZE="1T" MODEL="WD Black SN750" SERIAL="WD123" TRAN="nvme" ROTA="0"
EOF
}
has_command() { [[ "$1" == "lsblk" ]] && return 0 || return 1; }
get_disk_list
assert_eq "2" "${#DISK_NAME[@]}" "only whole disks kept, partition sda1 excluded"
assert_eq "sda" "${DISK_NAME[0]}" "first disk name"
assert_eq "SSD" "${DISK_TYPE[0]}" "ROTA=0 maps to SSD"
assert_eq "WD Black SN750" "${DISK_MODEL[1]}" "model with spaces parsed correctly"
unset -f lsblk has_command

echo ""
echo "=== get_smart_data (NVMe and ATA) ==="

smartctl() {
    cat <<'EOF'
Model Number:                      WD Black SN750
Serial Number:                     WD123456
Firmware Version:                  1B2QGXA7
Temperature:                       42 Celsius
Percentage Used:                   3%
Power On Hours:                    2,345
Media and Data Integrity Errors:   0
EOF
}
has_command() { [[ "$1" == "smartctl" ]] && return 0 || return 1; }
get_smart_data "nvme0n1" "nvme"
assert_eq "1" "$SMART_RESULT_AVAILABLE" "NVMe SMART data recognized as available"
assert_eq "0" "$SMART_RESULT_ERRORS" "NVMe errors from Media and Data Integrity Errors (last line)"
assert_eq "2345" "$SMART_RESULT_HOURS" "NVMe hours strips thousands separator"
assert_eq "42" "$SMART_RESULT_TEMP" "NVMe temperature"
assert_eq "3% use" "$SMART_RESULT_WEAR" "NVMe wear from Percentage Used"

smartctl() {
    cat <<'EOF'
Device Model:     Samsung SSD 970 EVO
Serial Number:    S123ABC
Firmware Version: 2B2QEXM7
ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  5 Reallocated_Sector_Ct   0x0033   100   100   010    Pre-fail  Always       -       0
  9 Power_On_Hours          0x0032   100   100   000    Old_age   Always       -       9999
194 Temperature_Celsius     0x0022   062   038   000    Old_age   Always       -       33 (Min/Max 20/45)
177 Wear_Leveling_Count     0x0013   094   094   000    Pre-fail  Always       -       12
EOF
}
get_smart_data "sda" "sata"
assert_eq "0" "$SMART_RESULT_ERRORS" "ATA reallocated sectors, not attribute ID"
assert_eq "9999" "$SMART_RESULT_HOURS" "ATA hours, not attribute ID"
assert_eq "33" "$SMART_RESULT_TEMP" "ATA temperature, ignoring (Min/Max) suffix"
assert_eq "12% restant" "$SMART_RESULT_WEAR" "ATA wear leveling, not attribute ID"
assert_eq "Samsung SSD 970 EVO" "$SMART_RESULT_MODEL" "ATA model string"
unset -f smartctl has_command

echo ""
echo "=== get_network_info (mocked ip -o link show) ==="

ip() {
    cat <<'EOF'
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP mode DEFAULT group default qlen 1000    link/ether aa:bb:cc:dd:ee:ff brd ff:ff:ff:ff:ff:ff
EOF
}
has_command() { [[ "$1" == "ip" ]] && return 0 || return 1; }
get_network_info
assert_eq "1" "${#NET_NAME[@]}" "loopback excluded, one real interface kept"
assert_eq "eth0" "${NET_NAME[0]}" "interface name"
assert_eq "aa:bb:cc:dd:ee:ff" "${NET_MAC[0]}" "MAC address"
unset -f ip has_command

echo ""
echo "=== get_encryption_info (mocked lsblk, crypto_LUKS detection) ==="

lsblk() {
    cat <<'EOF'
NAME="sda" FSTYPE=""
NAME="sda1" FSTYPE="vfat"
NAME="sda2" FSTYPE="crypto_LUKS"
EOF
}
has_command() { [[ "$1" == "lsblk" ]] && return 0 || return 1; }
get_encryption_info
assert_eq "OK" "$ENCRYPTION_STATUS" "status OK when lsblk is available"
assert_eq "1" "${#LUKS_NAME[@]}" "one LUKS volume detected"
assert_eq "sda2" "${LUKS_NAME[0]}" "LUKS volume name"
unset -f lsblk

has_command() { return 1; }
get_encryption_info
assert_eq "Unavailable" "$ENCRYPTION_STATUS" "status Unavailable when lsblk is missing"
unset -f has_command

echo ""
echo "=== get_battery_info (fake sysfs directory) ==="

tmp_bat=$(mktemp -d)
mkdir -p "$tmp_bat/BAT0"
printf 'SDI' > "$tmp_bat/BAT0/manufacturer"
printf 'DELL ABC123' > "$tmp_bat/BAT0/model_name"
printf '9988' > "$tmp_bat/BAT0/serial_number"
printf '245' > "$tmp_bat/BAT0/cycle_count"
printf '45000000' > "$tmp_bat/BAT0/energy_full"
printf '51600000' > "$tmp_bat/BAT0/energy_full_design"

r=$(get_battery_info 80 60 40 "$tmp_bat")
assert_contains "$r" "1|9988|SDI|DELL ABC123|245|87.2" "battery fields parsed (has_battery, serial, manufacturer, model, cycles, ~87% health)"
assert_contains "$r" "|Excellent" "87% health classified as Excellent (>= 80 threshold)"
rm -rf "$tmp_bat"

tmp_nobat=$(mktemp -d)
r=$(get_battery_info 80 60 40 "$tmp_nobat")
assert_eq "0||||||" "$r" "no BAT* directory -> has_battery=0 (desktop)"
rm -rf "$tmp_nobat"

echo ""
echo "=== remove_old_reports ==="

tmp_reports=$(mktemp -d)
touch "$tmp_reports/old.html" "$tmp_reports/old.json" "$tmp_reports/recent.html" "$tmp_reports/resume.csv"
touch -d "100 days ago" "$tmp_reports/old.html" "$tmp_reports/old.json" "$tmp_reports/resume.csv" 2>/dev/null
touch -d "1 day ago" "$tmp_reports/recent.html" 2>/dev/null
out=$(remove_old_reports "$tmp_reports" 30)
assert_contains "$out" "old.html" "old.html reported as removed"
[[ -f "$tmp_reports/old.html" ]] && assert_eq "missing" "present" "old.html actually deleted" || assert_eq "1" "1" "old.html actually deleted"
[[ -f "$tmp_reports/recent.html" ]] && assert_eq "1" "1" "recent.html untouched" || assert_eq "present" "missing" "recent.html untouched"
[[ -f "$tmp_reports/resume.csv" ]] && assert_eq "1" "1" "resume.csv never deleted" || assert_eq "present" "missing" "resume.csv never deleted"
rm -rf "$tmp_reports"

tmp_disabled=$(mktemp -d)
touch "$tmp_disabled/ancient.html"
touch -d "1000 days ago" "$tmp_disabled/ancient.html" 2>/dev/null
remove_old_reports "$tmp_disabled" 0 >/dev/null
[[ -f "$tmp_disabled/ancient.html" ]] && assert_eq "1" "1" "MaxAgeDays=0 disables purge entirely" || assert_eq "present" "missing" "MaxAgeDays=0 disables purge entirely"
rm -rf "$tmp_disabled"

echo ""
echo "=== update_report_index ==="

tmp_idx=$(mktemp -d)
cat > "$tmp_idx/report1.json" <<'EOF'
{
  "GeneratedAt": "2026-09-10 10:00:00",
  "AssetTag": "REF-42",
  "System": {"Brand": "Dell Inc.", "Model": "Precision 7760", "SerialNumber": "GZM66M3"},
  "CPU": {"Brand": "Intel", "Model": "i7-11850H"},
  "GlobalAssessment": {"Score": 80, "Label": "Bon etat", "Recommendation": "Reemploi possible", "BadgeClass": "status-ok"}
}
EOF
echo "<html></html>" > "$tmp_idx/report1.html"
result=$(update_report_index "$tmp_idx")
assert_eq "$tmp_idx/index.html" "$result" "index path returned"
content=$(cat "$result")
assert_contains "$content" "Precision 7760" "System.Model extracted (not CPU.Model, despite both named 'Model')"
assert_contains "$content" "REF-42" "asset tag in index"
assert_contains "$content" "80/100" "score in index"

tmp_orphan=$(mktemp -d)
cat > "$tmp_orphan/orphan.json" <<'EOF'
{"System": {}, "GlobalAssessment": {}}
EOF
result=$(update_report_index "$tmp_orphan")
assert_eq "" "$result" "JSON without a matching HTML file is skipped, index not written"
rm -rf "$tmp_idx" "$tmp_orphan"

echo ""
echo "=== update_report_index HTML-escapes injected data ==="
tmp_xss=$(mktemp -d)
cat > "$tmp_xss/r.json" <<'EOF'
{
  "GeneratedAt": "x",
  "AssetTag": "<script>alert(1)</script>",
  "System": {"Brand": "A & B", "Model": "X", "SerialNumber": "1"},
  "GlobalAssessment": {"Score": 1, "Label": "", "Recommendation": "", "BadgeClass": ""}
}
EOF
echo "<html></html>" > "$tmp_xss/r.html"
result=$(update_report_index "$tmp_xss")
content=$(cat "$result")
assert_not_contains "$content" "<script>" "raw <script> tag not present in the index page"
assert_contains "$content" "&amp; B" "ampersand escaped"
rm -rf "$tmp_xss"

echo ""
echo "======================================"
echo "Tests: $TESTS_RUN   Failed: $TESTS_FAILED"
echo "======================================"
[[ "$TESTS_FAILED" -eq 0 ]]
