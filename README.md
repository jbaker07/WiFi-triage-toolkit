# Wi‑Fi Triage Toolkit (MVP)

Cross‑platform Wi‑Fi diagnostics that produces a clean HTML report with:
- Current Wi‑Fi state (RSSI/SNR, channel/band/PHY) and nearby APs (macOS airport; Linux nmcli/iw)
- Network snapshot (routes, DNS), ping latency to 1.1.1.1/8.8.8.8/example.com
- Basic HTTP timing (DNS/connect/TLS/TTFB/total) via curl
- Channel crowding histogram and remediation tips

## Quick start
chmod +x wifi_triage.sh
./wifi_triage.sh
# Open the generated wifi_report_*.html

## Optional extras
- Capture association/EAPOL with Wireshark or tcpdump:
- macOS: `sudo tcpdump -I -i en0 ether proto 0x888e or (type mgt and subtype assoc-req)`
- Linux: `sudo tcpdump -i wlan0 -vvv wlan type mgt or ether proto 0x888e`
- Useful Wireshark display filters:
- `eapol || (wlan.fc.type_subtype in {0x00,0x01,0x02,0x03}) || (dhcp || dns)`

## Resume bullet (suggested)
Built a cross‑platform Wi‑Fi diagnostic (RSSI/SNR, channel/band, PHY rate, DNS latency, packet loss) with an HTML report and remediation tips; standardized first‑touch Wi‑Fi triage for mock users.