#!/usr/bin/env bash
#wifi_triage.sh
#Collects Wi-Fi, network and latency data on macOS or Linux and writes one
#self contained HTML report that can be attached to a ticket.
#Runs as a normal user. Nothing here changes network settings.
#Usage: ./wifi_triage.sh [--redact] [--out FILE] [--skip-network-tests]

USAGE_TEXT="Usage: $0 [--redact] [--out FILE] [--skip-network-tests]
  --redact              replace SSIDs, BSSIDs, MAC and IP addresses, host names and
                        search domains with placeholders so the report can be shared
  --out FILE            where to write the report (default: wifi_report_<date>.html)
  --skip-network-tests  do not ping or fetch https://example.com"

REDACT_REPORT=0
RUN_NETWORK_TESTS=1
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --redact) REDACT_REPORT=1 ;;
        --skip-network-tests) RUN_NETWORK_TESTS=0 ;;
        --out)
            if [ $# -lt 2 ]; then
                echo "$USAGE_TEXT"
                exit 1
            fi
            OUT="$2"
            shift
            ;;
        -h|--help)
            echo "$USAGE_TEXT"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "$USAGE_TEXT"
            exit 1
            ;;
    esac
    shift
done

#DTS stamps the report name and title. TMP_DIR holds every command output
#until the report is rendered, and is removed on exit.
DTS=$(date +%Y%m%d-%H%M%S)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/wifi_triage.XXXXXX") || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
if [ -z "$OUT" ]; then
    OUT="wifi_report_$DTS.html"
fi

#Words that --redact replaces wherever they appear (host names, SSIDs and so on).
REDACT_WORDS_FILE="$TMP_DIR/redact_words.txt"
: >"$REDACT_WORDS_FILE"
WIFI_INTERFACE=""
DEFAULT_GATEWAY=""
DNS_SERVER=""

has(){ command -v "$1" >/dev/null 2>&1; }

os(){
case "$(uname -s)" in
    Darwin) echo "darwin" ;;
    Linux) echo "linux" ;;
    *) uname -s | tr '[:upper:]' '[:lower:]' ;;
esac
}

#Remember a value that --redact must hide. Empty values and the redaction
#markers macOS already uses are ignored.
add_redact_word(){
if [ -n "$1" ] && [ "$1" != "<redacted>" ] && [ ${#1} -ge 4 ]; then
    echo "$1" >>"$REDACT_WORDS_FILE"
fi
}

sys_info(){
{
echo "Report time: $(date)"
echo "Host name: $(hostname 2>/dev/null)"
echo "Kernel: $(uname -srm)"
if [ "$(os)" = "darwin" ]; then
    sw_vers 2>/dev/null
    #Only the model lines, the full hardware report includes the serial number.
    system_profiler SPHardwareDataType 2>/dev/null | grep -E "Model Name|Model Identifier|Chip|Memory:"
elif [ -r /etc/os-release ]; then
    grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
fi
echo "Running as uid $(id -u)"
} >"$TMP_DIR/system.txt" 2>&1
add_redact_word "$(hostname 2>/dev/null)"
add_redact_word "$(hostname -s 2>/dev/null)"
add_redact_word "${USER:-}"
if [ "$(os)" = "darwin" ]; then
    add_redact_word "$(scutil --get ComputerName 2>/dev/null)"
    add_redact_word "$(scutil --get LocalHostName 2>/dev/null)"
fi
}

#Find the Wi-Fi interface name, or leave WIFI_INTERFACE empty if there is none.
find_wifi_interface(){
if [ "$(os)" = "darwin" ]; then
    #networksetup names the port "Wi-Fi" on current macOS and "AirPort" on old releases.
    WIFI_INTERFACE=$(networksetup -listallhardwareports 2>/dev/null | awk '/^Hardware Port: (Wi-Fi|AirPort)/{getline; print $2; exit}')
    return
fi
if has iw; then
    WIFI_INTERFACE=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')
fi
if [ -z "$WIFI_INTERFACE" ] && has nmcli; then
    WIFI_INTERFACE=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')
fi
if [ -z "$WIFI_INTERFACE" ]; then
    #The kernel creates a wireless directory for every Wi-Fi interface.
    for WIRELESS_DIR in /sys/class/net/*/wireless; do
        if [ -d "$WIRELESS_DIR" ]; then
            WIFI_INTERFACE=$(basename "$(dirname "$WIRELESS_DIR")")
            break
        fi
    done
fi
if [ -z "$WIFI_INTERFACE" ] && has iwconfig; then
    WIFI_INTERFACE=$(iwconfig 2>/dev/null | awk '/IEEE 802.11/{print $1; exit}')
fi
}

net_snap(){
{
if [ "$(os)" = "darwin" ]; then
    echo "== Hardware ports (networksetup -listallhardwareports)"
    networksetup -listallhardwareports 2>&1
    echo
    echo "== Default route (route -n get default)"
    route -n get default 2>&1
    DEFAULT_GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
    if [ -n "$WIFI_INTERFACE" ]; then
        echo
        echo "== Wi-Fi service settings (networksetup -getinfo Wi-Fi)"
        networksetup -getinfo Wi-Fi 2>&1
        echo
        echo "== Interface summary (ipconfig getsummary $WIFI_INTERFACE)"
        #The raw DHCP packet in the summary is long and carries vendor options,
        #so skip it. It ends at the next "Key : value" line.
        ipconfig getsummary "$WIFI_INTERFACE" 2>&1 | awk '/Packet :/{skip=1; next} skip && / : /{skip=0} !skip{print}'
    fi
    echo
    echo "== Network state (scutil --nwi)"
    scutil --nwi 2>&1
    echo
    echo "== DNS resolvers (scutil --dns)"
    scutil --dns 2>&1 | grep -E "^resolver|nameserver|search domain|domain *:|if_index|reach" | head -40
    #macOS ping only does IPv4, so use the first IPv4 resolver for the DNS ping.
    DNS_SERVER=$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/ && $3 ~ /\./ {print $3; exit}')
    for SEARCH_DOMAIN in $(scutil --dns 2>/dev/null | awk '/search domain/{print $NF}' | sort -u); do
        add_redact_word "$SEARCH_DOMAIN"
    done
else
    echo "== Addresses (ip address)"
    if has ip; then
        #BusyBox ip has no -brief, so fall back to the long form.
        ip -brief address 2>/dev/null || ip address 2>&1
        echo
        echo "== Routes (ip route)"
        ip route 2>&1
        DEFAULT_GATEWAY=$(ip route 2>/dev/null | awk '$1=="default"{print $3; exit}')
    elif has ifconfig; then
        ifconfig -a 2>&1
        DEFAULT_GATEWAY=$(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $2; exit}')
    else
        echo "Neither ip nor ifconfig is installed."
    fi
    echo
    echo "== DNS (/etc/resolv.conf)"
    grep -vE '^#|^$' /etc/resolv.conf 2>&1
    DNS_SERVER=$(awk '$1=="nameserver" && $2 ~ /\./ {print $2; exit}' /etc/resolv.conf 2>/dev/null)
    for SEARCH_DOMAIN in $(awk '$1=="search" || $1=="domain"{for(i=2;i<=NF;i++) print $i}' /etc/resolv.conf 2>/dev/null); do
        add_redact_word "$SEARCH_DOMAIN"
    done
    if has nmcli; then
        echo
        echo "== NetworkManager devices (nmcli device status)"
        nmcli device status 2>&1
    fi
fi
} >"$TMP_DIR/network.txt" 2>&1
}

#Read one value from the system_profiler JSON with plutil, which ships with
#macOS, so the script does not depend on jq or python.
sp_value(){
plutil -extract "$1" raw -o - "$TMP_DIR/sp_airport.json" 2>/dev/null
}

wifi_info_macos(){
if [ -z "$WIFI_INTERFACE" ]; then
    echo "No Wi-Fi interface found. networksetup lists no Wi-Fi or AirPort hardware port." >"$TMP_DIR/wifi_none.txt"
    return
fi
#The old airport command was removed in macOS 14.4. system_profiler reports
#the same link details, as JSON since macOS 10.15.
if ! system_profiler SPAirPortDataType -json >"$TMP_DIR/sp_airport.json" 2>/dev/null || ! sp_value SPAirPortDataType.0 >/dev/null; then
    system_profiler SPAirPortDataType >"$TMP_DIR/wifi_current.txt" 2>&1
    echo "system_profiler -json was not available, so this is the text output." >>"$TMP_DIR/wifi_current.txt"
    return
fi

#Find the entry for our interface in spairport_airport_interfaces.
INTERFACE_COUNT=$(sp_value SPAirPortDataType.0.spairport_airport_interfaces)
INTERFACE_INDEX=0
SP_BASE=""
while [ "$INTERFACE_INDEX" -lt "${INTERFACE_COUNT:-0}" ]; do
    if [ "$(sp_value SPAirPortDataType.0.spairport_airport_interfaces.$INTERFACE_INDEX._name)" = "$WIFI_INTERFACE" ]; then
        SP_BASE="SPAirPortDataType.0.spairport_airport_interfaces.$INTERFACE_INDEX"
        break
    fi
    INTERFACE_INDEX=$((INTERFACE_INDEX + 1))
done
if [ -z "$SP_BASE" ]; then
    echo "system_profiler has no entry for $WIFI_INTERFACE." >"$TMP_DIR/wifi_none.txt"
    return
fi

CURRENT="$SP_BASE.spairport_current_network_information"
CURRENT_SSID=$(sp_value "$CURRENT._name")
add_redact_word "$CURRENT_SSID"
SIGNAL_NOISE=$(sp_value "$CURRENT.spairport_signal_noise")
#"-60 dBm / -93 dBm" is RSSI then noise floor. SNR is the gap between them.
RSSI_DBM=$(echo "$SIGNAL_NOISE" | awk '{print $1}')
NOISE_DBM=$(echo "$SIGNAL_NOISE" | awk '{print $4}')
{
echo "Interface: $WIFI_INTERFACE"
echo "Status: $(sp_value "$SP_BASE.spairport_status_information" | sed 's/spairport_status_//')"
echo "SSID: ${CURRENT_SSID:-not connected}"
echo "PHY mode: $(sp_value "$CURRENT.spairport_network_phymode")"
echo "Channel: $(sp_value "$CURRENT.spairport_network_channel")"
echo "Signal / noise: ${SIGNAL_NOISE:-unknown}"
if [ -n "$RSSI_DBM" ] && [ -n "$NOISE_DBM" ]; then
    echo "SNR: $((RSSI_DBM - NOISE_DBM)) dB"
fi
echo "Transmit rate: $(sp_value "$CURRENT.spairport_network_rate") Mbps"
echo "MCS index: $(sp_value "$CURRENT.spairport_network_mcs")"
echo "Security: $(sp_value "$CURRENT.spairport_security_mode" | sed -E 's/^s?pairport_security_mode_//')"
echo "Country code: $(sp_value "$CURRENT.spairport_network_country_code")"
echo "Card: $(sp_value "$SP_BASE.spairport_wireless_card_type" | sed 's/spairport_wireless_card_type_//')"
echo "Firmware: $(sp_value "$SP_BASE.spairport_wireless_firmware_version")"
if [ "$CURRENT_SSID" = "<redacted>" ]; then
    echo
    echo "macOS hides the SSID and BSSID from programs that do not have Location Services"
    echo "permission. Grant it to the terminal app to see them, or use sudo wdutil info."
fi
} >"$TMP_DIR/wifi_current.txt"
echo "$RSSI_DBM" >"$TMP_DIR/rssi.txt"
echo "$NOISE_DBM" >"$TMP_DIR/noise.txt"
sp_value "$CURRENT.spairport_network_channel" | awk '{print $1}' >"$TMP_DIR/current_channel.txt"

#Nearby networks from the last scan the system made.
NEARBY="$SP_BASE.spairport_airport_other_local_wireless_networks"
NEARBY_COUNT=$(sp_value "$NEARBY")
NEARBY_INDEX=0
{
printf "%-32s %-22s %-14s %s\n" "NETWORK" "CHANNEL" "PHY" "SECURITY"
while [ "$NEARBY_INDEX" -lt "${NEARBY_COUNT:-0}" ]; do
    NEARBY_SSID=$(sp_value "$NEARBY.$NEARBY_INDEX._name")
    add_redact_word "$NEARBY_SSID"
    printf "%-32s %-22s %-14s %s\n" "${NEARBY_SSID:-hidden}" \
        "$(sp_value "$NEARBY.$NEARBY_INDEX.spairport_network_channel")" \
        "$(sp_value "$NEARBY.$NEARBY_INDEX.spairport_network_phymode")" \
        "$(sp_value "$NEARBY.$NEARBY_INDEX.spairport_security_mode" | sed -E 's/^s?pairport_security_mode_//')"
    NEARBY_INDEX=$((NEARBY_INDEX + 1))
done
} >"$TMP_DIR/wifi_scan.txt"
echo "$NEARBY_COUNT nearby networks" >>"$TMP_DIR/wifi_scan.txt"

#wdutil gives roaming, beacon and fault details, but only to root.
if [ "$(id -u)" -eq 0 ] && has wdutil; then
    wdutil info >"$TMP_DIR/wdutil.txt" 2>&1
else
    echo "wdutil info needs sudo. Run: sudo wdutil info" >"$TMP_DIR/wdutil_note.txt"
fi
}

wifi_info_linux(){
if [ -z "$WIFI_INTERFACE" ]; then
    echo "No Wi-Fi interface found. Checked iw dev, nmcli, /sys/class/net/*/wireless and iwconfig." >"$TMP_DIR/wifi_none.txt"
    return
fi
{
echo "Interface: $WIFI_INTERFACE"
if has iw; then
    echo
    echo "== iw dev $WIFI_INTERFACE link"
    iw dev "$WIFI_INTERFACE" link 2>&1
    echo
    echo "== iw dev $WIFI_INTERFACE info"
    iw dev "$WIFI_INTERFACE" info 2>&1
elif has iwconfig; then
    echo
    echo "== iwconfig $WIFI_INTERFACE"
    iwconfig "$WIFI_INTERFACE" 2>&1
else
    echo "Neither iw nor iwconfig is installed, so link details are missing."
fi
} >"$TMP_DIR/wifi_current.txt"

if has iw; then
    iw dev "$WIFI_INTERFACE" link 2>/dev/null | awk '/signal:/{print $2; exit}' >"$TMP_DIR/rssi.txt"
    LINK_SSID=$(iw dev "$WIFI_INTERFACE" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p')
    add_redact_word "$LINK_SSID"
    #"freq: 5180" is in MHz. Channels 1 to 13 are 2412 to 2472, 5 GHz is (freq - 5000) / 5.
    iw dev "$WIFI_INTERFACE" link 2>/dev/null | awk '/freq:/{f=int($2); if (f<3000) print (f-2407)/5; else if (f<5950) print (f-5000)/5; else print (f-5950)/5; exit}' >"$TMP_DIR/current_channel.txt"
elif has iwconfig; then
    iwconfig "$WIFI_INTERFACE" 2>/dev/null | sed -n 's/.*Signal level=\(-[0-9]*\).*/\1/p' | head -1 >"$TMP_DIR/rssi.txt"
fi

#nmcli shows the scan any user can read. iw scan needs root.
if has nmcli; then
    nmcli -f SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY device wifi list ifname "$WIFI_INTERFACE" >"$TMP_DIR/wifi_scan.txt" 2>&1
    for NEARBY_SSID in $(nmcli -t -f SSID device wifi list ifname "$WIFI_INTERFACE" 2>/dev/null); do
        add_redact_word "$NEARBY_SSID"
    done
elif [ "$(id -u)" -eq 0 ] && has iw; then
    iw dev "$WIFI_INTERFACE" scan 2>&1 | awk '/^BSS /{print ""; print $2} /SSID:|freq:|signal:|DS Parameter set/{print}' >"$TMP_DIR/wifi_scan.txt"
else
    echo "No scan: nmcli is not installed and iw scan needs root." >"$TMP_DIR/wifi_scan.txt"
fi
}

#Ping one target and save the output as ping_<label>.txt.
ping_target(){
PING_LABEL="$1"
PING_HOST="$2"
if [ -z "$PING_HOST" ]; then
    return
fi
{
echo "Target: $PING_LABEL ($PING_HOST)"
if [ "$(os)" = "darwin" ]; then
    #-t is an overall time limit in seconds on macOS.
    ping -c 5 -t 10 "$PING_HOST" 2>&1
else
    #-w is the overall deadline on Linux and in busybox.
    ping -c 5 -w 10 "$PING_HOST" 2>&1
fi
} >"$TMP_DIR/ping_$PING_LABEL.txt"
}

latency_tests(){
if [ "$RUN_NETWORK_TESTS" -eq 0 ]; then
    return
fi
if ! has ping; then
    echo "ping is not installed." >"$TMP_DIR/ping_missing.txt"
    return
fi
#Gateway latency is the Wi-Fi hop itself. DNS and 1.1.1.1 show whether the
#problem is local or further out.
ping_target "gateway" "$DEFAULT_GATEWAY"
if [ "$DNS_SERVER" != "$DEFAULT_GATEWAY" ]; then
    ping_target "dns" "$DNS_SERVER"
fi
ping_target "internet" "1.1.1.1"
}

throughput_hint(){
if [ "$RUN_NETWORK_TESTS" -eq 0 ]; then
    return
fi
if has curl; then
curl -w '\nlookup:%{time_namelookup} connect:%{time_connect} tls:%{time_appconnect} ttfb:%{time_starttransfer} total:%{time_total}\n' -o /dev/null -s --max-time 15 https://example.com >"$TMP_DIR/curl_timing.txt" || echo "curl could not reach https://example.com (exit $?)" >>"$TMP_DIR/curl_timing.txt"
else
echo "curl is not installed, so there is no HTTP timing." >"$TMP_DIR/curl_timing.txt"
fi
}

channel_rec(){
#Count nearby networks per channel. macOS writes "149 (5GHz, 80MHz)" in the
#CHANNEL column, nmcli writes the bare number in CHAN.
if [ ! -s "$TMP_DIR/wifi_scan.txt" ]; then
    return
fi
if [ "$(os)" = "darwin" ]; then
    awk 'NR>1 && $0 !~ /nearby networks$/ {for(i=1;i<=NF;i++) if ($(i+1) ~ /^\([0-9]GHz,$/) {print $i; break}}' "$TMP_DIR/wifi_scan.txt" | sort | uniq -c | sort -nr >"$TMP_DIR/channel_hist.txt"
elif head -1 "$TMP_DIR/wifi_scan.txt" | grep -q CHAN; then
    awk 'NR==1{for(i=1;i<=NF;i++) if ($i=="CHAN") col=i; next} col{print $(col)}' "$TMP_DIR/wifi_scan.txt" | sort | uniq -c | sort -nr >"$TMP_DIR/channel_hist.txt"
fi
if [ ! -s "$TMP_DIR/channel_hist.txt" ]; then
    rm -f "$TMP_DIR/channel_hist.txt"
fi
}

#Short findings for the top of the report, from the numbers collected above.
findings(){
{
RSSI_VALUE=$(cat "$TMP_DIR/rssi.txt" 2>/dev/null)
NOISE_VALUE=$(cat "$TMP_DIR/noise.txt" 2>/dev/null)
if [ -f "$TMP_DIR/wifi_none.txt" ]; then
    echo "No Wi-Fi interface on this machine, so the report covers wired networking only."
elif [ -n "$RSSI_VALUE" ]; then
    if [ "$RSSI_VALUE" -ge -60 ]; then
        echo "Signal $RSSI_VALUE dBm is strong."
    elif [ "$RSSI_VALUE" -ge -67 ]; then
        echo "Signal $RSSI_VALUE dBm is usable for most work but weak for calls."
    else
        echo "Signal $RSSI_VALUE dBm is weak. Move closer to the access point or remove obstacles."
    fi
    if [ -n "$NOISE_VALUE" ]; then
        SNR_VALUE=$((RSSI_VALUE - NOISE_VALUE))
        if [ "$SNR_VALUE" -lt 25 ]; then
            echo "SNR is $SNR_VALUE dB, under 25 dB. Expect retries and lower rates."
        else
            echo "SNR is $SNR_VALUE dB, which is healthy."
        fi
    fi
else
    echo "Wi-Fi interface $WIFI_INTERFACE found but no signal reading was available."
fi
for PING_FILE in "$TMP_DIR"/ping_*.txt; do
    [ -f "$PING_FILE" ] || continue
    PING_LABEL=$(basename "$PING_FILE" .txt | sed 's/^ping_//')
    if [ "$PING_LABEL" = "missing" ]; then
        continue
    fi
    LOSS_TEXT=$(grep -Eo '[0-9.]+% packet loss' "$PING_FILE" | head -1)
    #The summary line is min/avg/max then an equals sign. The second number is the average.
    AVERAGE_MS=$(awk -F'=' '/min\/avg\/max/{split($2, parts, "/"); gsub(/ /, "", parts[2]); print parts[2]; exit}' "$PING_FILE")
    if [ -z "$LOSS_TEXT" ]; then
        echo "Ping to $PING_LABEL failed. See the ping section."
    else
        echo "Ping to $PING_LABEL: $LOSS_TEXT${AVERAGE_MS:+, average $AVERAGE_MS ms}."
    fi
done
if [ -f "$TMP_DIR/channel_hist.txt" ] && [ -s "$TMP_DIR/current_channel.txt" ]; then
    CURRENT_CHANNEL=$(cat "$TMP_DIR/current_channel.txt")
    SAME_CHANNEL_COUNT=$(awk -v c="$CURRENT_CHANNEL" '$2==c{print $1}' "$TMP_DIR/channel_hist.txt")
    echo "Networks in the nearby list on the current channel ($CURRENT_CHANNEL): ${SAME_CHANNEL_COUNT:-0}."
fi
} >"$TMP_DIR/findings.txt"
}

#Replace addresses, names and SSIDs in every collected file.
redact_all(){
for REDACT_FILE in "$TMP_DIR"/*.txt; do
    case "$REDACT_FILE" in
        "$REDACT_WORDS_FILE") continue ;;
    esac
    #Literal words first, longest first, so a host name inside a domain is caught too.
    awk 'NR==FNR { if (length($0) > 0) words[++n] = $0; next }
         {
           line = $0
           for (i = 1; i <= n; i++) {
             out = ""
             while ((p = index(line, words[i])) > 0) {
               out = out substr(line, 1, p - 1) "<redacted-name>"
               line = substr(line, p + length(words[i]))
             }
             line = out line
           }
           print line
         }' <(awk '{print length($0) "\t" $0}' "$REDACT_WORDS_FILE" | sort -rn | cut -f2-) "$REDACT_FILE" >"$REDACT_FILE.tmp"
    #Then patterns: MAC addresses, UUIDs, IPv6 (three or more colons, or ::), IPv4.
    #The IPv4 pattern needs a non digit, non dot character on each side so
    #version strings like 23.10.1.2.242 are left alone. It runs twice because
    #two addresses can share one separator character.
    sed -E \
        -e 's/([0-9A-Fa-f]{1,2}[:-]){5}[0-9A-Fa-f]{1,2}/<mac>/g' \
        -e 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<uuid>/g' \
        -e 's/[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{1,4})*::([0-9A-Fa-f]{1,4}:)*[0-9A-Fa-f]{0,4}/<ipv6>/g' \
        -e 's/([0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}/<ipv6>/g' \
        -e 's/(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)/\1<ipv4>\3/g' \
        -e 's/(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)/\1<ipv4>\3/g' \
        "$REDACT_FILE.tmp" >"$REDACT_FILE"
    rm -f "$REDACT_FILE.tmp"
done
}

#HTML report
html_escape(){ sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

#Print one report section if its file exists.
section(){
if [ -f "$TMP_DIR/$2" ]; then
echo "<h2>$1</h2><pre>"; html_escape <"$TMP_DIR/$2"; echo "</pre>"
fi
}

render_html(){
{
echo "<!doctype html><meta charset=\"utf-8\"><title>Wi-Fi Report $DTS</title><style>body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;max-width:920px;margin:40px auto;padding:0 16px;line-height:1.4}pre{background:#111;color:#eee;padding:12px;border-radius:10px;overflow:auto}h2{margin-top:28px}ul.findings li{margin:4px 0}</style>"
echo "<h1>Wi-Fi Report $DTS</h1>"
echo "<p>This report summarizes current Wi-Fi state, nearby networks, latency, DNS, and basic HTTP timing.</p>"
if [ "$REDACT_REPORT" -eq 1 ]; then
echo "<p><b>Redacted:</b> SSIDs, BSSIDs, MAC and IP addresses, host names and search domains are replaced with placeholders.</p>"
fi

echo "<h2>Findings</h2><ul class=\"findings\">"
while IFS= read -r FINDING_LINE; do
echo "<li>$(echo "$FINDING_LINE" | html_escape)</li>"
done <"$TMP_DIR/findings.txt"
echo "</ul>"

section "System" "system.txt"
section "Wi-Fi" "wifi_none.txt"
if [ "$(os)" = "darwin" ]; then
section "Current Wi-Fi (system_profiler SPAirPortDataType)" "wifi_current.txt"
section "Nearby networks (system_profiler, last system scan)" "wifi_scan.txt"
section "wdutil" "wdutil.txt"
section "wdutil" "wdutil_note.txt"
else
section "Current Wi-Fi (iw or iwconfig)" "wifi_current.txt"
section "Nearby networks (nmcli or iw scan)" "wifi_scan.txt"
fi
section "Network snapshot" "network.txt"

for f in "$TMP_DIR"/ping_*.txt; do
[[ -f "$f" ]] || continue
base=$(basename "$f" .txt | sed 's/^ping_//')
echo "<h2>Ping $base</h2><pre>"; html_escape <"$f"; echo "</pre>"
done

section "HTTP timing (curl to https://example.com, seconds)" "curl_timing.txt"

if [[ -f "$TMP_DIR/channel_hist.txt" ]]; then
echo "<h2>Channel crowding (networks per channel)</h2><pre>"; html_escape <"$TMP_DIR/channel_hist.txt"; echo "</pre>"
if [[ -s "$TMP_DIR/current_channel.txt" ]]; then
cur=$(cat "$TMP_DIR/current_channel.txt")
echo "<p><b>Current channel:</b> $cur. If it is crowded above, move the access point to a quieter channel. On 2.4 GHz use 1, 6 or 11, which do not overlap. On 5 GHz any channel with few neighbors works.</p>"
fi
fi

echo "<h2>Remediation tips</h2><ul>"
echo "<li>RSSI worse than -65 dBm or SNR below 25 dB: move closer to the access point, reduce interference, prefer 5 GHz.</li>"
echo "<li>High packet loss or latency to the gateway: the problem is the Wi-Fi hop. Check channel congestion, try the other band, look for interference.</li>"
echo "<li>Clean gateway but loss or latency to DNS or the internet: the problem is past the access point. Check the uplink and any captive portal.</li>"
echo "<li>Slow DNS or TLS in the HTTP timing usually points at the network path or MTU. Compare wired against Wi-Fi.</li>"
echo "</ul>"
} >"$OUT"
echo "Wrote $OUT ($(grep -c '<h2>' "$OUT") sections)"
}

#Main
sys_info
find_wifi_interface
net_snap
if [[ $(os) == "darwin" ]]; then wifi_info_macos; else wifi_info_linux; fi
latency_tests
throughput_hint
channel_rec
findings
if [ "$REDACT_REPORT" -eq 1 ]; then redact_all; fi
render_html
