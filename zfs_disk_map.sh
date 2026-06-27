#!/usr/bin/env bash
# =============================================================================
# zfs_disk_map.sh  v3.3.0
# =============================================================================
# Maps all active ZFS pool member disks to their physical identifiers and
# pool topology. Outputs a terminal reference table and/or P-Touch Editor
# .lbx label files for drive tray labeling.
#
# Fields collected per disk:
#   - Block device name (sda, sdb, etc.)
#   - Partition device (sda2, etc.)
#   - Physical serial number (4-method fallback: lsblk, smartctl, hdparm, sysfs)
#   - Drive model
#   - Drive size
#   - ZFS pool name
#   - vdev role (raidz1-0:pos-2, mirror-0:pos-1, spare, cache, etc.)
#   - Partition UUID (PARTUUID or filesystem UUID fallback)
#   - ZFS vdev GUID
#   - vdev STATE from zpool status (ONLINE, DEGRADED, FAULTED, etc.)
#   - Exact path string shown in `zpool status` output
#
# Usage:
#   sudo ./zfs_disk_map.sh                  # Reference table only (default)
#   sudo ./zfs_disk_map.sh --labels         # Table + .txt tray label files
#   sudo ./zfs_disk_map.sh --lbx-12         # Table + 12mm TZe tape .lbx files
#   sudo ./zfs_disk_map.sh --lbx-18         # Table + 18mm TZe tape .lbx files (2.5" max width)
#   sudo ./zfs_disk_map.sh --lbx-24         # Table + 24mm / 1" TZe tape .lbx files
#   sudo ./zfs_disk_map.sh --lbx-all        # Table + all three LBX formats
#   sudo ./zfs_disk_map.sh --all            # Table + .txt + all three LBX formats
#   sudo ./zfs_disk_map.sh --brief          # Brief 4-column status view (DISK, STATE, SERIAL, POOL)
#   sudo ./zfs_disk_map.sh --help           # Show usage
#
# Output directories (all created under ./zfs_labels/):
#   txt/      One .txt file per drive — full field dump, printer-friendly
#   lbx-12/   12mm tape — serial (large, left) | divider | part/role/model (right, all-caps)
#   lbx-18/   18mm tape — serial (large, left) | divider | 4-line right col, 2.5" fixed width
#   lbx-24/   24mm / 1" tape — 5-line full-detail label with border frame
#
# LBX label notes:
#   - One .lbx file per physical drive, named by serial number
#   - Compatible with Brother P-Touch Editor 5.4+ (Windows/macOS)
#   - Tested on Brother PT-2430PC; printerID/format can be adjusted in script
#   - Files overwrite on re-run — back up if you have manual edits
#
# Requirements: bash 4+, lsblk, blkid, zpool, zdb
# Optional:     smartctl (smartmontools), hdparm  -- improve serial detection
# LBX output:   7z (p7zip) -- /usr/bin/7z on TrueNAS
#
# Notes:
#   - Run as root for full output (zdb GUIDs, blkid PARTUUIDs)
#   - Safe to run during resilver; vdev map captures output before parsing
#   - If script exits silently on first run, retry -- zpool status can return
#     incomplete data mid-resilver
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SCRIPT_VERSION="3.3.0"
BASE_LABEL_DIR="$(pwd)/zfs_labels"

DO_LABELS=false
DO_LBX24=false
DO_LBX12=false
DO_LBX18=false
DO_BRIEF=false

if [[ -t 1 ]]; then
    C_BOLD="\033[1m"; C_CYAN="\033[1;36m"; C_YELLOW="\033[1;33m"
    C_GREEN="\033[1;32m"; C_RED="\033[1;31m"; C_RESET="\033[0m"
else
    C_BOLD="" C_CYAN="" C_YELLOW="" C_GREEN="" C_RED="" C_RESET=""
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --labels)   DO_LABELS=true ;;
        --lbx-24)   DO_LBX24=true ;;
        --lbx-12)   DO_LBX12=true ;;
        --lbx-18)   DO_LBX18=true ;;
        --lbx-all)  DO_LBX24=true; DO_LBX12=true; DO_LBX18=true ;;
        --all)      DO_LABELS=true; DO_LBX24=true; DO_LBX12=true; DO_LBX18=true ;;
        --brief)    DO_BRIEF=true ;;
        --help|-h)
            sed -n '/^# Usage:/,/^# Output/p' "$0" | sed 's/^# \?//'
            echo ""
            sed -n '/^# Output/,/^# Requirements/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "Unknown argument: $arg  (use --help)" >&2; exit 1 ;;
    esac
done

NEEDS_7Z=false
[[ "$DO_LBX24" == true || "$DO_LBX12" == true || "$DO_LBX18" == true ]] && NEEDS_7Z=true || true

# ---------------------------------------------------------------------------
# Tool checks
# ---------------------------------------------------------------------------
MISSING_OPTIONAL=()

check_root() {
    [[ $EUID -ne 0 ]] && echo -e "${C_YELLOW}[WARN]${C_RESET} Not running as root -- serial/GUID fields may be incomplete." >&2 || true
}

check_tools() {
    local missing_req=()
    for t in lsblk blkid zpool zdb; do
        command -v "$t" &>/dev/null || missing_req+=("$t")
    done
    [[ ${#missing_req[@]} -gt 0 ]] && { echo -e "${C_RED}[ERROR]${C_RESET} Missing required tools: ${missing_req[*]}" >&2; exit 1; }

    for t in smartctl hdparm; do
        command -v "$t" &>/dev/null || MISSING_OPTIONAL+=("$t")
    done

    if [[ "$NEEDS_7Z" == true ]] && ! command -v 7z &>/dev/null; then
        echo -e "${C_RED}[ERROR]${C_RESET} LBX output requires '7z' (p7zip). Not found in PATH." >&2; exit 1
    fi

    if [[ ${#MISSING_OPTIONAL[@]} -gt 0 ]]; then
        echo -e "${C_YELLOW}[WARN]${C_RESET} Optional tools missing: ${MISSING_OPTIONAL[*]} -- serial detection may be limited." >&2
    fi
}

# ---------------------------------------------------------------------------
# Device metadata helpers
# ---------------------------------------------------------------------------
get_serial() {
    local dev="$1" s=""
    s=$(lsblk -dn -o SERIAL "$dev" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$s" ]] && echo "$s" && return || true
    if command -v smartctl &>/dev/null; then
        s=$(smartctl -i "$dev" 2>/dev/null | awk -F': +' '/Serial [Nn]umber/{gsub(/[[:space:]]/,"",$2);print $2}')
        [[ -n "$s" ]] && echo "$s" && return || true
    fi
    if command -v hdparm &>/dev/null; then
        s=$(hdparm -I "$dev" 2>/dev/null | awk -F': +' '/Serial Number/{gsub(/[[:space:]]/,"",$2);print $2}')
        [[ -n "$s" ]] && echo "$s" && return || true
    fi
    local sn; sn=$(basename "$dev")
    [[ -r "/sys/block/${sn}/device/serial" ]] && tr -d '[:space:]' < "/sys/block/${sn}/device/serial" && return || true
    echo "N/A"
}

get_model() {
    local dev="$1" m=""
    m=$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]*$//')
    [[ -n "$m" ]] && echo "$m" && return || true
    if command -v smartctl &>/dev/null; then
        m=$(smartctl -i "$dev" 2>/dev/null | awk -F': +' '/Device Model|Product/{print $2;exit}' | sed 's/[[:space:]]*$//')
        [[ -n "$m" ]] && echo "$m" && return || true
    fi
    local sn; sn=$(basename "$dev")
    [[ -r "/sys/block/${sn}/device/model" ]] && \
        tr -s '[:space:]' ' ' < "/sys/block/${sn}/device/model" | sed 's/ *$//' && return
    echo "N/A"
}

get_size()     { lsblk -dn -o SIZE "$1" 2>/dev/null | tr -d '[:space:]' || echo "N/A"; }
get_partuuid() {
    local part="$1" u=""
    u=$(blkid -s PARTUUID -o value "$part" 2>/dev/null)
    [[ -n "$u" ]] && echo "$u" && return || true
    u=$(blkid -s UUID -o value "$part" 2>/dev/null)
    [[ -n "$u" ]] && echo "(fs)$u" && return || true
    echo "N/A"
}

resolve_dev() {
    local p="$1"
    [[ "$p" =~ ^/dev/(sd|nvme|vd|hd|xvd|mmcblk)[a-z0-9] ]] && echo "$p" && return || true
    local r; r=$(readlink -f "$p" 2>/dev/null)
    [[ -b "$r" ]] && echo "$r" && return || true
    echo "$p"
}

parent_disk_of() {
    local dev="$1" base; base=$(basename "$dev")
    [[ "$base" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]] && echo "/dev/${BASH_REMATCH[1]}" && return || true
    [[ "$base" =~ ^(mmcblk[0-9]+)p[0-9]+$ ]]      && echo "/dev/${BASH_REMATCH[1]}" && return || true
    local p; p=$(echo "$base" | sed 's/[0-9]*$//')
    [[ "$p" != "$base" && -b "/dev/$p" ]] && echo "/dev/$p" && return || true
    echo "$dev"
}

# ---------------------------------------------------------------------------
# VDEV map
# ---------------------------------------------------------------------------
declare -A VDEV_MAP

build_vdev_map() {
    local current_pool="" current_vdev_type="" vdev_position=0 in_config=false
    local zpool_out; zpool_out=$(zpool status -P 2>/dev/null)

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*pool:[[:space:]]+(.+)$ ]]; then
            current_pool="${BASH_REMATCH[1]}"; current_vdev_type=""; vdev_position=0; in_config=false; continue
        fi
        [[ "$line" =~ ^[[:space:]]*config:[[:space:]]*$ ]] && in_config=true && continue || true
        [[ "$in_config" == true ]] && [[ "$line" =~ ^[[:space:]]*errors:[[:space:]] ]] && in_config=false && continue || true
        [[ "$in_config" == true ]] || continue
        [[ "$line" =~ NAME[[:space:]]+STATE ]] && continue || true
        [[ -n "$current_pool" && "$line" =~ ^[[:space:]]{0,8}${current_pool}[[:space:]] ]] && continue || true

        if [[ "$line" =~ ^[[:space:]]+(mirror|raidz[123]?|draid[23]?|spare|cache|log|special|dedup|replacing)(-[0-9]+)?[[:space:]] ]]; then
            current_vdev_type="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; vdev_position=0; continue
        fi

        if [[ "$line" =~ ^[[:space:]]+(/dev/[^[:space:]]+) ]]; then
            local raw_dev="${BASH_REMATCH[1]}"
            local full_dev; full_dev=$(resolve_dev "$raw_dev")
            local base_disk; base_disk=$(parent_disk_of "$full_dev")
            local role; [[ -n "$current_vdev_type" ]] && role="${current_vdev_type}:pos-${vdev_position}" || role="stripe:pos-${vdev_position}"

            local guid="N/A"
            command -v zdb &>/dev/null && [[ $EUID -eq 0 ]] && \
                guid=$(timeout 5 zdb -l "$full_dev" 2>/dev/null | awk '/^[[:space:]]*guid:/{print $2;exit}')
            [[ -z "$guid" ]] && guid="N/A" || true

            local state="UNKNOWN"
            [[ "$line" =~ [[:space:]]([A-Z]+)[[:space:]]+[0-9] ]] && state="${BASH_REMATCH[1]}" || true
            # Fallback: grab second whitespace-delimited token (NAME STATE ...)
            if [[ "$state" == "UNKNOWN" ]]; then
                state=$(echo "$line" | awk '{print $2}')
                [[ "$state" =~ ^(ONLINE|DEGRADED|FAULTED|REMOVED|UNAVAIL|OFFLINE)$ ]] || state="UNKNOWN"
            fi

            local entry="${current_pool}|${role}|${guid}|${raw_dev}|${state}"
            VDEV_MAP["$full_dev"]="$entry"
            [[ "$base_disk" != "$full_dev" ]] && VDEV_MAP["$base_disk"]="$entry" || true
            (( vdev_position++ )) || true
        fi
    done <<< "$zpool_out"
}

declare -A POOL_GUID_MAP
build_pool_guid_map() {
    [[ $EUID -ne 0 ]] && return || true
    local current_pool=""
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z0-9_:.-]+): ]] && current_pool="${BASH_REMATCH[1]}" || true
        [[ "$line" =~ pool_guid:[[:space:]]+([0-9]+) && -n "$current_pool" ]] && POOL_GUID_MAP["$current_pool"]="${BASH_REMATCH[1]}" || true
    done < <(zdb -C 2>/dev/null)
}

get_zfs_disks() {
    local seen=()
    for dev in "${!VDEV_MAP[@]}"; do
        local base; base=$(parent_disk_of "$dev")
        local already=false
        for s in "${seen[@]+"${seen[@]}"}"; do [[ "$s" == "$base" ]] && already=true && break; done || true
        if ! $already; then seen+=("$base"); echo "$base"; fi
    done | sort -u
}

# ---------------------------------------------------------------------------
# Records: DISK|PART|STATE|SERIAL|MODEL|SIZE|POOL|ROLE|PARTUUID|GUID|ZPOOL_DISPLAY
# ---------------------------------------------------------------------------
declare -a RECORDS

collect_records() {
    local base_disk
    while IFS= read -r base_disk; do
        [[ -b "$base_disk" ]] || continue
        local serial model size
        serial=$(get_serial "$base_disk")
        model=$(get_model  "$base_disk")
        size=$(get_size    "$base_disk")
        local handled=false

        while IFS= read -r part; do
            [[ -b "$part" ]] || continue
            local entry="${VDEV_MAP[$part]:-}"; [[ -z "$entry" ]] && continue || true
            local pool role guid zpool_display state
            IFS='|' read -r pool role guid zpool_display state <<< "$entry"
            local partuuid; partuuid=$(get_partuuid "$part")
            RECORDS+=("$(basename "$base_disk")|$(basename "$part")|${state}|${serial}|${model}|${size}|${pool}|${role}|${partuuid}|${guid}|${zpool_display}")
            handled=true
        done < <(lsblk -ln -o NAME "$base_disk" 2>/dev/null | tail -n +2 | sed "s|^|/dev/|")

        if [[ "$handled" != true ]]; then
            local entry="${VDEV_MAP[$base_disk]:-}"
            if [[ -n "$entry" ]]; then
                local pool role guid zpool_display state
                IFS='|' read -r pool role guid zpool_display state <<< "$entry"
                local partuuid; partuuid=$(get_partuuid "$base_disk")
                RECORDS+=("$(basename "$base_disk")|$(basename "$base_disk")|${state}|${serial}|${model}|${size}|${pool}|${role}|${partuuid}|${guid}|${zpool_display}")
            fi
        fi
    done < <(get_zfs_disks)
}

# ---------------------------------------------------------------------------
# Table output (always shown)
# ---------------------------------------------------------------------------
print_table() {
    local sep; sep=$(printf '%0.s-' {1..195})
    echo ""
    echo -e "${C_BOLD}${C_CYAN}ZFS Disk Map -- $(hostname) -- $(date '+%Y-%m-%d %H:%M:%S')${C_RESET}"
    echo "$sep"
    printf "${C_BOLD}%-6s  %-10s  %-9s  %-22s  %-26s  %-6s  %-14s  %-22s  %-36s  %-18s  %s${C_RESET}\n" \
        "DISK" "PART" "STATE" "SERIAL" "MODEL" "SIZE" "POOL" "VDEV ROLE" "PART UUID" "ZFS GUID" "ZPOOL STATUS PATH"
    echo "$sep"
    if [[ ${#RECORDS[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}  No ZFS vdev devices found. Is a pool imported? Root may be required.${C_RESET}"
    else
        for rec in "${RECORDS[@]}"; do
            IFS='|' read -r disk part state serial model size pool role partuuid guid zpool_display <<< "$rec"
            local state_color="$C_RESET"
            [[ "$state" == "ONLINE"   ]] && state_color="$C_GREEN"  || true
            [[ "$state" == "DEGRADED" ]] && state_color="$C_YELLOW" || true
            [[ "$state" =~ ^(FAULTED|REMOVED|UNAVAIL|OFFLINE)$ ]] && state_color="$C_RED" || true
            printf "%-6s  %-10s  ${state_color}%-9s${C_RESET}  %-22s  %-26s  %-6s  %-14s  %-22s  %-36s  %-18s  %s\n" \
                "$disk" "$part" "$state" "$serial" "$model" "$size" "$pool" "$role" "$partuuid" "$guid" "$zpool_display"
        done
    fi
    echo "$sep"
    echo -e "  ${C_GREEN}${#RECORDS[@]} vdev member(s) -- $(zpool list -H -o name 2>/dev/null | wc -l | tr -d ' ') pool(s)${C_RESET}"
    echo "$sep"
    echo ""
}

# ---------------------------------------------------------------------------
# Brief view  (--brief)
# ---------------------------------------------------------------------------
print_brief() {
    local sep; sep=$(printf '%0.s-' {1..70})
    echo ""
    echo -e "${C_BOLD}${C_CYAN}ZFS Disk Map (brief) -- $(hostname) -- $(date '+%Y-%m-%d %H:%M:%S')${C_RESET}"
    echo "$sep"
    printf "${C_BOLD}%-6s  %-9s  %-22s  %s${C_RESET}\n" "DISK" "STATE" "SERIAL" "POOL"
    echo "$sep"
    if [[ ${#RECORDS[@]} -eq 0 ]]; then
        echo -e "${C_YELLOW}  No ZFS vdev devices found. Is a pool imported? Root may be required.${C_RESET}"
    else
        for rec in "${RECORDS[@]}"; do
            IFS='|' read -r disk part state serial model size pool role partuuid guid zpool_display <<< "$rec"
            local state_color="$C_RESET"
            [[ "$state" == "ONLINE"   ]] && state_color="$C_GREEN"  || true
            [[ "$state" == "DEGRADED" ]] && state_color="$C_YELLOW" || true
            [[ "$state" =~ ^(FAULTED|REMOVED|UNAVAIL|OFFLINE)$ ]] && state_color="$C_RED" || true
            printf "%-6s  ${state_color}%-9s${C_RESET}  %-22s  %s\n" \
                "$disk" "$state" "$serial" "$pool"
        done
    fi
    echo "$sep"
    echo -e "  ${C_GREEN}${#RECORDS[@]} vdev member(s) -- $(zpool list -H -o name 2>/dev/null | wc -l | tr -d ' ') pool(s)${C_RESET}"
    echo "$sep"
    echo ""
}

# ---------------------------------------------------------------------------
# .txt tray labels  (--labels)
# ---------------------------------------------------------------------------
save_labels() {
    local dir="${BASE_LABEL_DIR}/txt"
    mkdir -p "$dir"
    local sep; sep=$(printf '%0.s-' {1..60})
    local count=0

    for rec in "${RECORDS[@]}"; do
        IFS='|' read -r disk part state serial model size pool role partuuid guid zpool_display <<< "$rec"
        local safe_serial; safe_serial=$(echo "$serial" | tr -cd '[:alnum:]_-')
        [[ -z "$safe_serial" ]] && safe_serial="unknown_${disk}" || true

        cat > "${dir}/${safe_serial}.txt" << TXTEOF
${sep}
 DISK TRAY LABEL
${sep}
 Slot/Device    : ${disk}
 Partition      : ${part}
 State          : ${state}
 Serial         : ${serial}
 Model          : ${model}
 Size           : ${size}
 Pool           : ${pool}
 vdev Role      : ${role}
 Part UUID      : ${partuuid}
 ZFS GUID       : ${guid}
 zpool status   : ${zpool_display}
 Generated      : $(date '+%Y-%m-%d %H:%M:%S')
${sep}
TXTEOF
        (( count++ )) || true
    done

    echo -e "  ${C_GREEN}[txt]${C_RESET} ${count} file(s) -> ${dir}/"
}

# ---------------------------------------------------------------------------
# LBX shared helpers
# ---------------------------------------------------------------------------
xml_esc() { echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'; }

make_string_items() {
    local text="$1" size="$2" orgsize="$3" weight="${4:-400}" font="${5:-Arial Narrow}"
    local out="" tok
    # Group into whitespace-separated tokens (matches P-Touch Editor behaviour)
    while IFS= read -r -d '' tok; do
        [[ -z "$tok" ]] && continue || true
        out+="<text:stringItem charLen=\"${#tok}\"><text:ptFontInfo>"
        out+="<text:logFont name=\"${font}\" width=\"0\" italic=\"false\" weight=\"${weight}\" charSet=\"0\" pitchAndFamily=\"34\"/>"
        out+="<text:fontExt effect=\"NOEFFECT\" underline=\"0\" strikeout=\"0\" size=\"${size}\" orgSize=\"${orgsize}\" textColor=\"#000000\" textPrintColorNumber=\"1\"/>"
        out+="</text:ptFontInfo></text:stringItem>"
    done < <(echo -n "$text" | grep -oP '\S+|\s+' | tr '\n' '\0')
    echo "$out"
}

write_lbx() {
    local tmpdir="$1" outfile="$2"
    ( cd "$tmpdir" && 7z a -tzip -mx=5 "$outfile" label.xml prop.xml > /dev/null )
    rm -rf "$tmpdir"
}

write_prop() {
    local tmpdir="$1" gen_date="$2"
    cat > "${tmpdir}/prop.xml" << PROPEOF
<?xml version="1.0" encoding="UTF-8"?><meta:properties xmlns:meta="http://schemas.brother.info/ptouch/2007/lbx/meta" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/"><meta:appName>P-touch Editor</meta:appName><dc:title></dc:title><dc:subject></dc:subject><dc:creator>root</dc:creator><meta:keyword></meta:keyword><dc:description></dc:description><meta:template></meta:template><dcterms:created>${gen_date}</dcterms:created><dcterms:modified>${gen_date}</dcterms:modified><meta:lastPrinted></meta:lastPrinted><meta:modifiedBy>root</meta:modifiedBy><meta:revision>1</meta:revision><meta:editTime>0</meta:editTime><meta:numPages>1</meta:numPages><meta:numWords>0</meta:numWords><meta:numChars>0</meta:numChars><meta:security>0</meta:security></meta:properties>
PROPEOF
}

LBX_HEADER='<?xml version="1.0" encoding="UTF-8"?><pt:document xmlns:pt="http://schemas.brother.info/ptouch/2007/lbx/main" xmlns:style="http://schemas.brother.info/ptouch/2007/lbx/style" xmlns:text="http://schemas.brother.info/ptouch/2007/lbx/text" xmlns:draw="http://schemas.brother.info/ptouch/2007/lbx/draw" xmlns:image="http://schemas.brother.info/ptouch/2007/lbx/image" xmlns:barcode="http://schemas.brother.info/ptouch/2007/lbx/barcode" xmlns:database="http://schemas.brother.info/ptouch/2007/lbx/database" xmlns:table="http://schemas.brother.info/ptouch/2007/lbx/table" xmlns:cable="http://schemas.brother.info/ptouch/2007/lbx/cable" version="1.7" generator="P-touch Editor 5.4.016 Windows">'

lbx_textobj() {
    # args: name id x y w h size orgsize weight data [font]
    local name="$1" id="$2" x="$3" y="$4" w="$5" h="$6"
    local size="$7" orgsize="$8" weight="$9" data="${10}" font="${11:-Arial Narrow}"
    local si; si=$(make_string_items "$data" "$size" "$orgsize" "$weight" "$font")
    echo -n "<text:text><pt:objectStyle x=\"${x}\" y=\"${y}\" width=\"${w}\" height=\"${h}\" backColor=\"#FFFFFF\" backPrintColorNumber=\"0\" ropMode=\"COPYPEN\" angle=\"0\" anchor=\"TOPLEFT\" flip=\"NONE\"><pt:pen style=\"NULL\" widthX=\"0.5pt\" widthY=\"0.5pt\" color=\"#000000\" printColorNumber=\"1\"/><pt:brush style=\"NULL\" color=\"#000000\" printColorNumber=\"1\" id=\"0\"/><pt:expanded objectName=\"${name}\" ID=\"${id}\" lock=\"0\" templateMergeTarget=\"LABELLIST\" templateMergeType=\"NONE\" templateMergeID=\"0\" linkStatus=\"NONE\" linkID=\"0\"/></pt:objectStyle><text:ptFontInfo><text:logFont name=\"${font}\" width=\"0\" italic=\"false\" weight=\"${weight}\" charSet=\"0\" pitchAndFamily=\"34\"/><text:fontExt effect=\"NOEFFECT\" underline=\"0\" strikeout=\"0\" size=\"${size}\" orgSize=\"${orgsize}\" textColor=\"#000000\" textPrintColorNumber=\"1\"/></text:ptFontInfo><text:textControl control=\"LONGTEXTFIXED\" clipFrame=\"false\" aspectNormal=\"true\" shrink=\"true\" autoLF=\"false\" avoidImage=\"false\"/><text:textAlign horizontalAlignment=\"LEFT\" verticalAlignment=\"CENTER\" inLineAlignment=\"BASELINE\"/><text:textStyle vertical=\"false\" nullBlock=\"false\" charSpace=\"0\" lineSpace=\"0\" orgPoint=\"${size}\" combinedChars=\"false\"/><pt:data>${data}</pt:data>${si}</text:text>"
}

lbx_divider() {
    # args: x y height
    echo -n "<draw:line><pt:objectStyle x=\"${1}\" y=\"${2}\" width=\"0.5pt\" height=\"${3}\" backColor=\"#000000\" backPrintColorNumber=\"1\" ropMode=\"COPYPEN\" angle=\"0\" anchor=\"TOPLEFT\" flip=\"NONE\"><pt:pen style=\"SOLID\" widthX=\"0.5pt\" widthY=\"0.5pt\" color=\"#000000\" printColorNumber=\"1\"/><pt:brush style=\"SOLID\" color=\"#000000\" printColorNumber=\"1\" id=\"0\"/><pt:expanded objectName=\"Divider\" ID=\"9\" lock=\"2\" templateMergeTarget=\"LABELLIST\" templateMergeType=\"NONE\" templateMergeID=\"0\" linkStatus=\"NONE\" linkID=\"0\"/></pt:objectStyle><draw:lineStyle/></draw:line>"
}

lbx_textobj_r() {
    # Right-aligned variant of lbx_textobj
    local name="$1" id="$2" x="$3" y="$4" w="$5" h="$6"
    local size="$7" orgsize="$8" weight="$9" data="${10}" font="${11:-Arial Narrow}"
    local si; si=$(make_string_items "$data" "$size" "$orgsize" "$weight" "$font")
    echo -n "<text:text><pt:objectStyle x=\"${x}\" y=\"${y}\" width=\"${w}\" height=\"${h}\" backColor=\"#FFFFFF\" backPrintColorNumber=\"0\" ropMode=\"COPYPEN\" angle=\"0\" anchor=\"TOPLEFT\" flip=\"NONE\"><pt:pen style=\"NULL\" widthX=\"0.5pt\" widthY=\"0.5pt\" color=\"#000000\" printColorNumber=\"1\"/><pt:brush style=\"NULL\" color=\"#000000\" printColorNumber=\"1\" id=\"0\"/><pt:expanded objectName=\"${name}\" ID=\"${id}\" lock=\"0\" templateMergeTarget=\"LABELLIST\" templateMergeType=\"NONE\" templateMergeID=\"0\" linkStatus=\"NONE\" linkID=\"0\"/></pt:objectStyle><text:ptFontInfo><text:logFont name=\"${font}\" width=\"0\" italic=\"false\" weight=\"${weight}\" charSet=\"0\" pitchAndFamily=\"34\"/><text:fontExt effect=\"NOEFFECT\" underline=\"0\" strikeout=\"0\" size=\"${size}\" orgSize=\"${orgsize}\" textColor=\"#000000\" textPrintColorNumber=\"1\"/></text:ptFontInfo><text:textControl control=\"LONGTEXTFIXED\" clipFrame=\"false\" aspectNormal=\"true\" shrink=\"true\" autoLF=\"false\" avoidImage=\"false\"/><text:textAlign horizontalAlignment=\"RIGHT\" verticalAlignment=\"CENTER\" inLineAlignment=\"BASELINE\"/><text:textStyle vertical=\"false\" nullBlock=\"false\" charSpace=\"0\" lineSpace=\"0\" orgPoint=\"${size}\" combinedChars=\"false\"/><pt:data>${data}</pt:data>${si}</text:text>"
}

# ---------------------------------------------------------------------------
# 24mm LBX  (--lbx-24)
# Layout: 5 full-width lines, framed, verified against PT-2430PC output
# ---------------------------------------------------------------------------
save_lbx_24() {
    local dir="${BASE_LABEL_DIR}/lbx-24"
    mkdir -p "$dir"
    local count=0

    for rec in "${RECORDS[@]}"; do
        IFS='|' read -r disk part state serial model size pool role partuuid guid zpool_display <<< "$rec"
        local safe_serial; safe_serial=$(echo "$serial" | tr -cd '[:alnum:]_-')
        [[ -z "$safe_serial" ]] && safe_serial="unknown_${disk}" || true
        local gen_date; gen_date=$(date '+%Y-%m-%dT%H:%M:%SZ')
        local gen_disp; gen_disp=$(date '+%Y-%m-%d %H:%M:%S')

        local x_model x_serial x_disk x_part x_size x_pool x_role x_partuuid x_guid x_zpool x_date
        x_model=$(xml_esc "$model");   x_serial=$(xml_esc "$serial")
        x_disk=$(xml_esc "$disk");     x_part=$(xml_esc "$part")
        x_size=$(xml_esc "$size");     x_pool=$(xml_esc "$pool")
        x_role=$(xml_esc "$role");     x_partuuid=$(xml_esc "$partuuid")
        x_guid=$(xml_esc "$guid");     x_zpool=$(xml_esc "$zpool_display")
        x_date=$(xml_esc "$gen_disp")

        local line1="${x_model}  - SN: ${x_serial}"
        local line2="DISK: ${x_disk}   PART: ${x_part}   SIZE: ${x_size}"
        local line3="POOL: ${x_pool}   ROLE: ${x_role}"
        local line4="PARTUUID: ${x_partuuid}   GUID: ${x_guid}"
        local line5="zpool: ${x_zpool}   [${x_date}]"

        local tmpdir; tmpdir=$(mktemp -d)

        {
            echo -n "${LBX_HEADER}"
            echo -n '<pt:body currentSheet="Sheet 1" direction="LTR"><style:sheet name="Sheet 1">'
            echo -n '<style:paper media="0" width="68pt" height="2834.4pt" marginLeft="8.4pt" marginTop="5.7pt" marginRight="8.4pt" marginBottom="5.7pt" orientation="landscape" autoLength="true" monochromeDisplay="true" printColorDisplay="false" printColorsID="0" paperColor="#FFFFFF" paperInk="#000000" split="1" format="261" backgroundTheme="0" printerID="23088" printerName="Brother PT-2430PC"/>'
            echo -n '<style:cutLine regularCut="0pt" freeCut=""/>'
            echo -n '<style:backGround x="5.6pt" y="8.4pt" width="390.2pt" height="51.2pt" brushStyle="NULL" brushId="0" userPattern="NONE" userPatternId="0" color="#000000" printColorNumber="1" backColor="#FFFFFF" backPrintColorNumber="0"/>'
            echo -n '<pt:objects>'
            echo -n '<draw:frame><pt:objectStyle x="5.7pt" y="8.4pt" width="390pt" height="51.2pt" backColor="#FFFFFF" backPrintColorNumber="0" ropMode="COPYPEN" angle="0" anchor="TOPLEFT" flip="NONE"><pt:pen style="INSIDEFRAME" widthX="0.5pt" widthY="0.5pt" color="#000000" printColorNumber="1"/><pt:brush style="NULL" color="#000000" printColorNumber="1" id="0"/><pt:expanded objectName="Frame6" ID="0" lock="2" templateMergeTarget="LABELLIST" templateMergeType="NONE" templateMergeID="0" linkStatus="NONE" linkID="0"/></pt:objectStyle><draw:frameStyle category="SIMPLE" style="5" stretchCenter="true"/></draw:frame>'
            lbx_textobj "Line1" 1 "10.3pt" "9.8pt"  "380.8pt" "15.8pt" "14pt"  "14pt"  "700" "$line1"
            lbx_textobj "Line2" 2 "10.3pt" "23.9pt" "380.8pt" "9.6pt"  "8.5pt" "8.5pt" "400" "$line2"
            lbx_textobj "Line3" 3 "10.3pt" "30.9pt" "380.8pt" "9.6pt"  "7.5pt" "8.5pt" "400" "$line3"
            lbx_textobj "Line4" 4 "10.3pt" "39.6pt" "380.8pt" "7.9pt"  "6pt"   "7pt"   "400" "$line4"
            lbx_textobj "Line5" 5 "10.3pt" "48.4pt" "380.8pt" "7pt"    "5pt"   "6pt"   "400" "$line5"
            echo -n '</pt:objects></style:sheet></pt:body></pt:document>'
        } > "${tmpdir}/label.xml"

        write_prop "$tmpdir" "$gen_date"
        write_lbx  "$tmpdir" "${dir}/${safe_serial}.lbx"
        (( count++ )) || true
    done

    echo -e "  ${C_GREEN}[lbx-24]${C_RESET} ${count} file(s) -> ${dir}/"
}

# ---------------------------------------------------------------------------
# 12mm LBX  (--lbx-12)
# Layout: serial large+bold left | divider | part/role/model stacked right
# Verified against user's PT-2430PC template
# ---------------------------------------------------------------------------
save_lbx_12() {
    local dir="${BASE_LABEL_DIR}/lbx-12"
    mkdir -p "$dir"
    local count=0

    for rec in "${RECORDS[@]}"; do
        IFS='|' read -r disk part state serial model size pool role partuuid guid zpool_display <<< "$rec"
        local safe_serial; safe_serial=$(echo "$serial" | tr -cd '[:alnum:]_-')
        [[ -z "$safe_serial" ]] && safe_serial="unknown_${disk}" || true
        local gen_date; gen_date=$(date '+%Y-%m-%dT%H:%M:%SZ')

        local x_serial x_part x_pool x_role x_model
        x_serial=$(xml_esc "$serial")
        x_part=$(xml_esc "$part");   x_pool=$(xml_esc "$pool")
        x_role=$(xml_esc "$role");   x_model=$(xml_esc "$model")

        # All-caps right column
        local r_part; r_part=$(echo "${x_part}  |  ${x_pool}" | tr '[:lower:]' '[:upper:]')
        local r_role; r_role=$(echo "$x_role"  | tr '[:lower:]' '[:upper:]')
        local r_model; r_model=$(echo "$x_model" | tr '[:lower:]' '[:upper:]')

        local tmpdir; tmpdir=$(mktemp -d)

        {
            echo -n "${LBX_HEADER}"
            echo -n '<pt:body currentSheet="Sheet 1" direction="LTR"><style:sheet name="Sheet 1">'
            echo -n '<style:paper media="0" width="33.6pt" height="2834.4pt" marginLeft="2.8pt" marginTop="5.7pt" marginRight="2.8pt" marginBottom="5.7pt" orientation="landscape" autoLength="true" monochromeDisplay="true" printColorDisplay="false" printColorsID="0" paperColor="#FFFFFF" paperInk="#000000" split="1" format="259" backgroundTheme="0" printerID="23088" printerName="Brother PT-2430PC"/>'
            echo -n '<style:cutLine regularCut="0pt" freeCut=""/>'
            echo -n '<style:backGround x="5.6pt" y="2.8pt" width="270pt" height="28pt" brushStyle="NULL" brushId="0" userPattern="NONE" userPatternId="0" color="#000000" printColorNumber="1" backColor="#FFFFFF" backPrintColorNumber="0"/>'
            echo -n '<pt:objects>'
            lbx_textobj "Serial" 1 "7.7pt"  "4.8pt"  "170pt"   "22.6pt" "18pt"  "16pt"  "700" "$x_serial"
            lbx_divider "179pt" "4.8pt" "22.6pt"
            lbx_textobj "Part"   2 "181pt"   "5.5pt"  "85pt"   "7pt"    "6.5pt" "6.5pt" "700" "$r_part"
            lbx_textobj "Role"   3 "181pt"   "13.0pt" "85pt"   "7pt"    "6.5pt" "6.5pt" "700" "$r_role"
            lbx_textobj "Model"  4 "181pt"   "20.5pt" "85pt"   "7pt"    "6.5pt" "6.5pt" "700" "$r_model"
            echo -n '</pt:objects></style:sheet></pt:body></pt:document>'
        } > "${tmpdir}/label.xml"

        write_prop "$tmpdir" "$gen_date"
        write_lbx  "$tmpdir" "${dir}/${safe_serial}.lbx"
        (( count++ )) || true
    done

    echo -e "  ${C_GREEN}[lbx-12]${C_RESET} ${count} file(s) -> ${dir}/"
}

# ---------------------------------------------------------------------------
# 18mm LBX  (--lbx-18)
# Layout: serial 14pt non-bold left | divider | 4 stacked right-justified (part/role/mfr/mdl)
# Fixed width 2.5" (180pt), 18mm tape — right col overlaps serial box (intentional)
# ---------------------------------------------------------------------------
save_lbx_18() {
    local dir="${BASE_LABEL_DIR}/lbx-18"
    mkdir -p "$dir"
    local count=0

    for rec in "${RECORDS[@]}"; do
        IFS='|' read -r disk part state serial model size pool role partuuid guid zpool_display <<< "$rec"
        local safe_serial; safe_serial=$(echo "$serial" | tr -cd '[:alnum:]_-')
        [[ -z "$safe_serial" ]] && safe_serial="unknown_${disk}" || true
        local gen_date; gen_date=$(date '+%Y-%m-%dT%H:%M:%SZ')

        local x_serial x_part x_pool x_role x_model
        x_serial=$(xml_esc "$serial")
        x_part=$(xml_esc "$part")
        x_pool=$(xml_esc "$pool")
        x_role=$(xml_esc "$role")
        x_model=$(xml_esc "$model")

        # Right col — all caps
        local r_part; r_part=$(echo "${x_part}  |  ${x_pool}" | tr '[:lower:]' '[:upper:]')
        local r_role; r_role=$(echo "$x_role" | tr '[:lower:]' '[:upper:]')
        local r_mfr r_mdl
        if [[ "$x_model" == *" "* ]]; then
            r_mfr=$(echo "${x_model%% *}" | tr '[:lower:]' '[:upper:]')
            r_mdl=$(echo "${x_model#* }"  | tr '[:lower:]' '[:upper:]')
        else
            r_mfr=""
            r_mdl=$(echo "$x_model" | tr '[:lower:]' '[:upper:]')
        fi

        local tmpdir; tmpdir=$(mktemp -d)

        {
            echo -n "${LBX_HEADER}"
            echo -n '<pt:body currentSheet="Sheet 1" direction="LTR"><style:sheet name="Sheet 1">'
            echo -n '<style:paper media="0" width="51.02pt" height="180pt" marginLeft="2.8pt" marginTop="5.7pt" marginRight="2.8pt" marginBottom="5.7pt" orientation="landscape" autoLength="false" monochromeDisplay="true" printColorDisplay="false" printColorsID="0" paperColor="#FFFFFF" paperInk="#000000" split="1" format="260" backgroundTheme="0" printerID="23088" printerName="Brother PT-2430PC"/>'
            echo -n '<style:cutLine regularCut="0pt" freeCut=""/>'
            echo -n '<style:backGround x="2.8pt" y="5.7pt" width="174.4pt" height="39.6pt" brushStyle="NULL" brushId="0" userPattern="NONE" userPatternId="0" color="#000000" printColorNumber="1" backColor="#FFFFFF" backPrintColorNumber="0"/>'
            echo -n '<pt:objects>'
            lbx_textobj   "Serial" 1 "5pt"  "5.7pt"  "123pt" "39.6pt" "14pt" "14pt" "400" "$x_serial"
            lbx_divider "131pt" "5.7pt" "39.6pt"
            lbx_textobj_r "Part" 2 "90pt" "5.7pt"  "80pt" "7pt" "6pt" "6pt" "700" "$r_part"
            lbx_textobj_r "Role" 3 "90pt" "16.3pt" "80pt" "7pt" "6pt" "6pt" "700" "$r_role"
            lbx_textobj_r "Mfr"  4 "90pt" "27.5pt" "80pt" "6pt" "6pt" "6pt" "700" "$r_mfr"
            lbx_textobj_r "Mdl"  5 "90pt" "33.5pt" "80pt" "6pt" "6pt" "6pt" "700" "$r_mdl"
            echo -n '</pt:objects></style:sheet></pt:body></pt:document>'
        } > "${tmpdir}/label.xml"

        write_prop "$tmpdir" "$gen_date"
        write_lbx  "$tmpdir" "${dir}/${safe_serial}.lbx"
        (( count++ )) || true
    done

    echo -e "  ${C_GREEN}[lbx-18]${C_RESET} ${count} file(s) -> ${dir}/"
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${C_BOLD}zfs_disk_map.sh v${SCRIPT_VERSION}${C_RESET}"
    echo ""
    check_root
    check_tools

    echo -e "${C_CYAN}[1/4]${C_RESET} Building ZFS vdev map..."
    build_vdev_map

    echo -e "${C_CYAN}[2/4]${C_RESET} Building pool GUID index..."
    build_pool_guid_map

    echo -e "${C_CYAN}[3/4]${C_RESET} Collecting per-disk metadata..."
    collect_records

    echo -e "${C_CYAN}[4/4]${C_RESET} Formatting output..."
    echo ""

    if [[ "$DO_BRIEF" == true ]]; then
        print_brief
    else
        print_table
    fi

    if [[ "$DO_LABELS" == true || "$DO_LBX24" == true || "$DO_LBX12" == true || "$DO_LBX18" == true ]]; then
        echo -e "${C_BOLD}Output files:${C_RESET}"
        [[ "$DO_LABELS" == true ]] && save_labels || true
        [[ "$DO_LBX24" == true ]]  && save_lbx_24 || true
        [[ "$DO_LBX12" == true ]]  && save_lbx_12 || true
        [[ "$DO_LBX18" == true ]]  && save_lbx_18 || true
        echo ""
    fi
}

main "$@"
