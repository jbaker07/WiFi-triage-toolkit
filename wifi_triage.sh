#!/usr/bin/env bash
throughput_hint(){
if has curl; then
curl -w '\nlookup:%{time_namelookup} connect:%{time_connect} tls:%{time_appconnect} ttfb:%{time_starttransfer} total:%{time_total}\n' -o /dev/null -s https://example.com >"$TMP_DIR/curl_timing.txt" || true
fi
}

channel_rec(){
# Parse current channel and nearby networks to suggest a cleaner channel (macOS only best-effort)
local APT="/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"
if [[ $(os) == "darwin" && -x "$APT" ]]; then
local curchan; curchan=$(awk '/ channel: /{print $2}' "$TMP_DIR/airport_current.txt" | head -1)
awk 'NR>1{print $2}' "$TMP_DIR/airport_scan.txt" | sort | uniq -c | sort -nr >"$TMP_DIR/channel_hist.txt" || true
echo "$curchan" >"$TMP_DIR/current_channel.txt" 2>/dev/null || true
fi
}

# ---- HTML report ----
html_escape(){ sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

render_html(){
{
echo "<!doctype html><meta charset=\"utf-8\"><title>Wi‑Fi Report $DTS</title><style>body{font-family:system-ui,Segoe UI,Roboto,Helvetica,Arial,sans-serif;max-width:920px;margin:40px auto;line-height:1.4}pre{background:#111;color:#eee;padding:12px;border-radius:10px;overflow:auto}h2{margin-top:28px}code{background:#f3f3f3;padding:2px 4px;border-radius:6px}</style>"
echo "<h1>Wi‑Fi Report — $DTS</h1>"
echo "<p>This report summarizes current Wi‑Fi state, nearby networks, latency, DNS, and basic HTTP timing.</p>"

echo "<h2>System</h2><pre>"; cat "$TMP_DIR/system.txt" | html_escape; echo "</pre>"
if [[ -f "$TMP_DIR/airport_current.txt" ]]; then
echo "<h2>Current Wi‑Fi (macOS airport -I)</h2><pre>"; cat "$TMP_DIR/airport_current.txt" | html_escape; echo "</pre>"
fi
if [[ -f "$TMP_DIR/airport_scan.txt" ]]; then
echo "<h2>Nearby Networks (airport -s)</h2><pre>"; cat "$TMP_DIR/airport_scan.txt" | html_escape; echo "</pre>"
fi
if [[ -f "$TMP_DIR/nmcli_wifi.txt" ]]; then
echo "<h2>Wi‑Fi (Linux nmcli)</h2><pre>"; cat "$TMP_DIR/nmcli_wifi.txt" | html_escape; echo "</pre>"
fi
if [[ -f "$TMP_DIR/iw_dev.txt" ]]; then
echo "<h2>iw dev</h2><pre>"; cat "$TMP_DIR/iw_dev.txt" | html_escape; echo "</pre>"
fi

echo "<h2>Network snapshot</h2><pre>"; cat "$TMP_DIR/network.txt" | html_escape; echo "</pre>"

for f in "$TMP_DIR"/ping_*.txt; do
[[ -f "$f" ]] || continue
base=$(basename "$f")
echo "<h2>Ping $base</h2><pre>"; cat "$f" | html_escape; echo "</pre>"
done

if [[ -f "$TMP_DIR/curl_timing.txt" ]]; then
echo "<h2>HTTP timing (curl → example.com)</h2><pre>"; cat "$TMP_DIR/curl_timing.txt" | html_escape; echo "</pre>"
fi

if [[ -f "$TMP_DIR/channel_hist.txt" ]]; then
echo "<h2>Channel crowding (count → channel)</h2><pre>"; cat "$TMP_DIR/channel_hist.txt" | html_escape; echo "</pre>"
if [[ -f "$TMP_DIR/current_channel.txt" ]]; then
cur=$(cat "$TMP_DIR/current_channel.txt")
echo "<p><b>Current channel:</b> $cur. If heavily crowded above, consider moving AP to a cleaner non-overlapping channel (1/6/11 for 2.4GHz; any DFS-clean channel for 5GHz).</p>"
fi
fi

echo "<h2>Remediation tips</h2><ul>"
echo "<li>RSSI worse than −65 dBm or SNR below 25 dB → move closer to AP, reduce interference, prefer 5GHz.</li>"
echo "<li>High packet loss/latency to DNS → check channel congestion, retry on different band, verify no captive portal.</li>"
echo "<li>HTTP timing: slow DNS or TLS usually indicates network path or MTU issues; compare wired vs Wi‑Fi.</li>"
echo "</ul>"
} >"$OUT"
echo "Wrote $OUT"
}

# ---- Main ----
sys_info
net_snap
if [[ $(os) == "darwin" ]]; then wifi_info_macos; else wifi_info_linux; fi
latency_tests
throughput_hint
channel_rec
render_html