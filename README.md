# Wi-Fi Triage Toolkit

A Bash script that collects Wi-Fi, network and latency data on macOS or Linux and writes a single self contained HTML report with findings and remediation tips, so a first line engineer can attach one file to a ticket instead of a dozen command outputs.

It runs as a normal user, changes no settings and needs nothing beyond what ships with the OS (plus `curl` for the HTTP timing).

## Usage

```bash
./wifi_triage.sh                      # writes wifi_report_<date>.html
./wifi_triage.sh --redact             # same, with identifiers replaced, safe to share
./wifi_triage.sh --out report.html    # choose the file name
./wifi_triage.sh --skip-network-tests # no ping and no request to example.com
```

The script prints `Wrote <file> (<n> sections)` when it finishes. A full run takes about 25 seconds, most of it the three 5 packet pings.

Sample reports, both made with `--redact`:

- [examples/sample_report_macos_redacted.html](examples/sample_report_macos_redacted.html), macOS 27.2 on Wi-Fi
- [examples/sample_report_linux_no_wifi_redacted.html](examples/sample_report_linux_no_wifi_redacted.html), Alpine Linux 3.20 in a container with no Wi-Fi hardware

## What it collects

| Section | macOS | Linux |
|---------|-------|-------|
| System | `sw_vers`, model lines from `system_profiler SPHardwareDataType` | `/etc/os-release` |
| Current Wi-Fi | `system_profiler SPAirPortDataType -json`: PHY mode, channel and width, signal and noise, SNR, transmit rate, MCS index, security, country code | `iw dev <if> link` and `iw dev <if> info`, or `iwconfig` |
| Nearby networks | the last system scan from the same `system_profiler` data | `nmcli device wifi list`, or `iw dev <if> scan` when run as root |
| Network snapshot | `networksetup -listallhardwareports`, `networksetup -getinfo Wi-Fi`, `route -n get default`, `ipconfig getsummary <if>` (without the raw DHCP packet), `scutil --nwi`, `scutil --dns` | `ip address`, `ip route`, `/etc/resolv.conf`, `nmcli device status` |
| Latency | `ping` to the default gateway, the first IPv4 DNS server and 1.1.1.1 | same |
| HTTP timing | `curl` timing for DNS lookup, connect, TLS, time to first byte and total against https://example.com | same |
| Channel crowding | nearby networks counted per channel | same, from the `nmcli` CHAN column |

The report opens with a findings list worked out from those numbers: signal strength against the -60 and -67 dBm marks, SNR against 25 dB, packet loss and average latency per ping target, and how many nearby networks share the current channel.

The Wi-Fi interface is found with `networksetup` on macOS. On Linux the script tries `iw dev`, then `nmcli`, then `/sys/class/net/*/wireless`, then `iwconfig`. When there is no Wi-Fi interface the report says so and still covers wired networking, latency and HTTP timing.

## macOS notes

- Apple removed the `airport` command in macOS 14.4. The script reads the same link details from `system_profiler SPAirPortDataType -json` and pulls values out with `plutil`, so it does not need `jq` or Python.
- macOS hides the SSID and BSSID from programs that do not have Location Services permission, and `system_profiler` and `ipconfig` then print `<redacted>`. The report says this when it happens. Granting Location Services to the terminal app shows them.
- `wdutil info` gives roaming, beacon and fault details but needs root. The script runs it only when started with `sudo` and otherwise notes the command in the report.
- macOS `ping` is IPv4 only, so the DNS ping uses the first IPv4 resolver.

## Redaction

`--redact` replaces MAC addresses, IPv4 and IPv6 addresses and UUIDs by pattern, and replaces host names, the computer name, the user name, DNS search domains and every SSID the script saw by exact match. SSIDs that macOS already hid stay as `<redacted>`. A version string with five or more dotted numbers is left alone, but a four part version number looks exactly like an IPv4 address and gets replaced too.

## Requirements

- Bash 3.2 or later (the macOS default works)
- macOS: nothing extra
- Linux: `ip` or `ifconfig`, `ping`, and `iw`, `nmcli` or `iwconfig` for the Wi-Fi details
- `curl` for the HTTP timing. Without it the report says curl is missing.

## Tested

- macOS 27.2 on an Apple silicon Mac connected over Wi-Fi, with and without `--redact` and with `--skip-network-tests`
- Alpine Linux 3.20 in Docker with `bash` added, where `iw`, `nmcli`, `iwconfig` and `curl` are absent and there is no Wi-Fi hardware, once with networking and once with `--network none`

## Related captures

Association and EAPOL (802.1X key exchange) frames are useful alongside the report. Management frames are only visible when the interface is in monitor mode.

```bash
# macOS, monitor mode with -I
sudo tcpdump -I -i en0 'ether proto 0x888e or (type mgt and subtype assoc-req)'

# Linux, on an interface that is already in monitor mode
sudo tcpdump -i wlan0 -vvv 'wlan type mgt or ether proto 0x888e'
```

Wireshark display filter for EAPOL, association and reassociation frames, DHCP and DNS:

```text
eapol || (wlan.fc.type_subtype in {0x00,0x01,0x02,0x03}) || (dhcp || dns)
```
