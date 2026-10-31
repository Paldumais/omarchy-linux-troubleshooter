#!/usr/bin/env bash
# READ-ONLY audit. Writes ONE redacted report file; modifies nothing else. No sudo.
# Usage: audit.sh [slice ...]   slices: system cpu power gpu display net storage logs security
# Default: all slices. Output: $AUDIT_OUT or ~/audit-YYYY-MM-DD-HHMM.txt
set -u
out="${AUDIT_OUT:-$HOME/audit-$(date +%F-%H%M).txt}"
slices=("$@"); [ ${#slices[@]} -eq 0 ] && slices=(system cpu power gpu display net storage logs security)

hn=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-'); [ ${#hn} -lt 4 ] && hn='__nohost__'   # short names would mangle other text
sec(){ printf '\n===== %s =====\n' "$1"; }
# run "<cmd>": skips if the first word is not installed; prints the real exit code; 20 s timeout.
run(){ local bin=${1%% *}
  if command -v "$bin" >/dev/null 2>&1; then
    printf '$ %s\n' "$1"; timeout 20 bash -c "$1" 2>&1; printf '[exit %s]\n' "$?"
  else printf '[missing tool] %s\n' "$bin"; fi; }
# rd <files...>: print readable files as "path: content"; unmatched globs are skipped.
rd(){ local f; for f in "$@"; do [ -r "$f" ] && printf '%s: %s\n' "$f" "$(tr '\n' ' ' <"$f")"; done; return 0; }

s_system(){ sec SYSTEM; run "uname -a"; run "hostnamectl"; rd /etc/os-release /proc/cmdline
  rd /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/bios_version /sys/class/dmi/id/bios_date
  run "bootctl status"
  run "pacman -Q | grep -E '^(linux|linux-firmware[a-z-]*|mesa|vulkan-radeon|hyprland|pipewire|wireplumber|networkmanager|systemd|power-profiles-daemon) '"
  run "pacman -Qm"; }
s_cpu(){ sec CPU; run "lscpu"
  rd /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor \
     /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference /sys/devices/system/cpu/amd_pstate/status; }
s_power(){ sec POWER; run "powerprofilesctl list"; run "systemctl is-active power-profiles-daemon tlp tuned auto-cpufreq"
  rd /sys/firmware/acpi/platform_profile /sys/firmware/acpi/platform_profile_choices /sys/power/mem_sleep /sys/power/state
  rd /sys/class/power_supply/BAT*/status /sys/class/power_supply/BAT*/capacity /sys/class/power_supply/BAT*/cycle_count \
     /sys/class/power_supply/BAT*/charge_control_end_threshold /sys/class/power_supply/BAT*/power_now /sys/class/power_supply/AC*/online
  run "sensors"; }
s_gpu(){ sec GPU; run "lspci -nnk | grep -A4 -E 'VGA|Display|3D'"; run "vulkaninfo --summary"; run "glxinfo -B"; run "vainfo"
  rd /sys/class/drm/card*/device/mem_info_vram_total /sys/class/drm/card*/device/mem_info_gtt_total /sys/class/drm/card*/device/power_dpm_force_performance_level; }
s_display(){ sec DISPLAY; run "hyprctl version"; run "hyprctl monitors all"; run "hyprctl configerrors"
  run "ls /sys/class/drm"; echo "(needs a running Hyprland session; empty hyprctl output = run from inside it, not a TTY/ssh)"; }
s_net(){ sec NET; run "iw reg get"; run "iw dev"; run "rfkill list"; run "nmcli radio"; run "bluetoothctl show"
  run "lsmod | grep -E 'mt79|mt76|btusb|btmtk'"; run "lspci -nnk | grep -A4 -i network"; }
s_storage(){ sec STORAGE; run "lsblk -f"; run "findmnt -D"; run "swapon --show"; run "free -h"; run "lsmod | grep -E 'asus|wmi'"; }
s_logs(){ sec LOGS; echo "(needs membership in systemd-journal/adm/wheel to see system logs)"
  run "systemctl --failed --no-pager"; run "systemctl --user --failed --no-pager"
  run "journalctl -b -p err..alert --no-pager | tail -n 150"; run "journalctl -k -b -p warning --no-pager | tail -n 200"
  run "journalctl -b -1 -p err..alert --no-pager | tail -n 80"; }
s_security(){ sec SECURITY; run "bootctl status | grep -i 'secure boot'"; run "systemctl is-active ufw nftables firewalld sshd"; run "ss -tulpn"; }

{ for s in "${slices[@]}"; do
    if declare -F "s_$s" >/dev/null; then "s_$s"; else printf '[unknown slice] %s\n' "$s"; fi
  done; } 2>&1 | sed -E \
  -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/XX:XX:XX:XX:XX:XX/g' \
  -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/UUID-REDACTED/g' \
  -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/IPV4-REDACTED/g' \
  -e 's/(Machine ID|Boot ID|Hardware Serial|Serial Number|serial)[^,]*/\1: REDACTED/Ig' \
  -e 's/(ssid )[^ ].*/\1REDACTED/I' \
  -e "s|/home/${USER:-user}|/home/USER|g" \
  -e "s/\\b${hn}\\b/HOSTNAME/g" > "$out"
chmod 600 "$out"
echo "Report: $out ($(wc -l <"$out") lines). Skim it before sharing publicly; redaction is best-effort."
