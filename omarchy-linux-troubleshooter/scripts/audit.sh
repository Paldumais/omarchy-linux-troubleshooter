#!/usr/bin/env bash
# READ-ONLY audit. Writes ONE redacted report file; changes nothing else. No sudo needed.
# Usage:  audit.sh [slice ...]    slices: system cpu power gpu display net storage logs security
#                                 (default: all; a PREFLIGHT block is always printed first)
#         audit.sh --doctor       check this tooling and print exact repair commands (changes nothing)
#         audit.sh --doctor --fix apply ONLY the LOW-risk repairs (exec bit, CRLF, state dir); never installs or uses sudo
# Env:    AUDIT_OUT=/path/file    report path (default ~/audit-YYYY-MM-DD-HHMM.txt, falls back to /tmp)
#         AUDIT_SINCE="2026-10-31 14:00"   limit the logs slice to entries since that time
set -u
export LC_ALL=C
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SDIR="$(dirname "$SELF")"

hn=$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9.-'); [ ${#hn} -lt 4 ] && hn='__nohost__'  # short names would mangle other text

sec(){ printf '\n===== %s =====\n' "$1"; }
# run "<cmd>": skip if first word is not installed; print the real exit code; 20 s timeout.
run(){ local bin=${1%% *} rc
  if command -v "$bin" >/dev/null 2>&1; then
    printf '$ %s\n' "$1"; timeout 20 bash -c "$1" 2>&1; rc=$?
    if [ $rc -eq 124 ]; then echo "[timeout after 20s]"; else printf '[exit %s]\n' "$rc"; fi
  else printf '[missing tool] %s\n' "$bin"; fi; }
# rd <files...>: print readable files as "path: content"; unmatched globs are skipped.
rd(){ local f; for f in "$@"; do [ -r "$f" ] && printf '%s: %s\n' "$f" "$(tr '\n' ' ' <"$f")"; done; return 0; }

# Locate the running Hyprland instance when launched from a shell that lacks the env (agent shells, ssh).
hypr_env(){
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    local d; d=$(ls -td "$XDG_RUNTIME_DIR"/hypr/*/ 2>/dev/null | head -1)
    [ -n "$d" ] && export HYPRLAND_INSTANCE_SIGNATURE="$(basename "$d")"
  fi
}

s_preflight(){ sec PREFLIGHT
  # shellcheck disable=SC1091
  ( . /etc/os-release 2>/dev/null; echo "distro=${ID:-?} like=${ID_LIKE:-} variant=${VARIANT_ID:-}" )
  echo "kernel=$(uname -r) arch=$(uname -m) session=${XDG_SESSION_TYPE:-?} desktop=${XDG_CURRENT_DESKTOP:-?}"
  echo "pkg_manager=$(for p in pacman dnf apt; do command -v "$p" >/dev/null 2>&1 && { echo "$p"; break; }; done)"
  echo "hypr_instance=${HYPRLAND_INSTANCE_SIGNATURE:-none-found}"
  echo "journal_readable=$(journalctl -b -n1 --no-pager >/dev/null 2>&1 && echo yes || echo no)"
  echo "omarchy_dir=$(ls -d "$HOME/.local/share/omarchy" /usr/share/omarchy 2>/dev/null | head -1)"
  echo "audit_user=$(id -un) uid=$(id -u) groups=$(id -Gn | tr ' ' ',')"; }

s_system(){ sec SYSTEM; run "uname -a"; run "hostnamectl"; rd /etc/os-release /proc/cmdline
  rd /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name /sys/class/dmi/id/bios_version /sys/class/dmi/id/bios_date
  run "bootctl status"
  if command -v pacman >/dev/null 2>&1; then
    run "pacman -Q | grep -E '^(linux|linux-firmware[a-z-]*|mesa|vulkan-radeon|hyprland|pipewire|wireplumber|networkmanager|systemd|power-profiles-daemon) '"
    run "pacman -Qm"
  elif command -v rpm >/dev/null 2>&1; then
    run "rpm -qa | grep -E '^(kernel-core|linux-firmware|mesa-dri-drivers|hyprland|pipewire|wireplumber|NetworkManager|systemd|power-profiles-daemon)-[0-9]'"
  else echo "[unsupported package manager: package inventory skipped]"; fi; }
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
s_display(){ sec DISPLAY; hypr_env
  if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then run "hyprctl version"; run "hyprctl monitors all"; run "hyprctl configerrors"
  else echo "[no running Hyprland instance found: hyprctl skipped; run from inside the session or check XDG_RUNTIME_DIR]"; fi
  run "ls /sys/class/drm"; }
s_net(){ sec NET; run "iw reg get"; run "iw dev"; run "rfkill list"; run "nmcli radio"; run "bluetoothctl show"
  run "lsmod | grep -E 'mt79|mt76|btusb|btmtk'"; run "lspci -nnk | grep -A4 -i network"; }
s_storage(){ sec STORAGE; run "lsblk -f"; run "findmnt -D"; run "swapon --show"; run "free -h"; run "lsmod | grep -E 'asus|wmi'"; }
s_logs(){ sec LOGS; echo "(window: $jarg; system logs need membership in systemd-journal/adm/wheel)"
  run "systemctl --failed --no-pager"; run "systemctl --user --failed --no-pager"
  run "journalctl $jarg -p err..alert --no-pager | tail -n 150"; run "journalctl -k $jarg -p warning --no-pager | tail -n 200"
  [ -z "$since" ] && run "journalctl -b -1 -p err..alert --no-pager | tail -n 80"; }
s_security(){ sec SECURITY; run "bootctl status | grep -i 'secure boot'"; run "systemctl is-active ufw nftables firewalld sshd"; run "ss -tulpn"; }

# Best-effort redaction. Loopback (127.x.x.x) and 0.0.0.0 are kept: they matter for listening-socket analysis.
redact(){ sed -E \
  -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/XX:XX:XX:XX:XX:XX/g' \
  -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/UUID-REDACTED/g' \
  -e 's/\b127\.([0-9]{1,3}\.){2}[0-9]{1,3}\b/@@LOOP@@/g' -e 's/\b0\.0\.0\.0\b/@@ANY@@/g' \
  -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/IPV4-REDACTED/g' \
  -e 's/@@LOOP@@/127.x.x.x/g' -e 's/@@ANY@@/0.0.0.0/g' \
  -e 's/(iSerial +[0-9]+ +)[^ ]+/\1REDACTED/g' \
  -e 's/((Hardware )?Serial( Number)?|Machine ID|Boot ID)([ =:]+)[^ ,]+/\1\4REDACTED/Ig' \
  -e 's/(ssid )[^ ].*/\1REDACTED/I' \
  -e "s|/home/${USER:-user}|/home/USER|g" \
  -e "s/\\b${hn}\\b/HOSTNAME/g"; }

# ---------------------------------------------------------------- doctor: diagnose and repair THIS tooling only
# Never touches the system under diagnosis. --fix applies LOW-risk repairs only; installs/sudo are printed, never run.
doctor(){
  local fix=0 bad=0 warn=0 f t od state avail p
  local -a missing=() pk=()
  [ "${1:-}" = "--fix" ] && fix=1
  ok(){ printf 'OK      %s\n' "$*"; }
  wr(){ printf 'WARN    %s\n' "$*"; warn=$((warn+1)); }
  fl(){ printf 'FAIL    %s\n' "$*"; bad=$((bad+1)); }
  fx(){ printf 'FIXED   %s\n' "$*"; }
  echo "== audit doctor ($([ $fix = 1 ] && echo 'fixing LOW-risk issues' || echo 'report only')) =="

  if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then ok "bash ${BASH_VERSION%%(*}"
  else fl "bash >= 4 required (found $BASH_VERSION)"; return 1; fi
  for t in timeout sed tr getent realpath cp diff date id mktemp df cut grep; do
    command -v "$t" >/dev/null 2>&1 || fl "core tool missing: $t (coreutils/sed/grep/diffutils): base system problem, stop and report [MEDIUM, sudo]"
  done

  for f in "$SDIR"/*.sh; do
    [ -e "$f" ] || continue
    if grep -q $'\r' "$f"; then
      if [ $fix = 1 ] && [ "$f" != "$SELF" ] && sed -i.bak 's/\r$//' "$f"; then fx "CRLF removed from $f (backup: $f.bak)"
      else fl "CRLF line endings in $f -> sed -i.bak 's/\\r\$//' '$f'   [LOW]  (prevent: printf '*.sh text eol=lf\\n' > .gitattributes)"; fi
    fi
    if [ ! -x "$f" ]; then
      if [ $fix = 1 ] && chmod +x "$f" 2>/dev/null; then fx "chmod +x $f"
      else wr "not executable: $f -> chmod +x '$f'  [LOW]  (or run it as: bash '$f')"; fi
    fi
  done
  [ -f "$SDIR/changes.sh" ] || wr "scripts/changes.sh not found next to audit.sh: reinstall the skill folder (all files)"
  [ -f "$SDIR/../references/domains.md" ] || wr "references/domains.md not found: reinstall the skill folder (all files)"

  declare -A PKG=( [lspci]=pciutils [lsusb]=usbutils [sensors]=lm_sensors [iw]=iw [rfkill]=util-linux [nmcli]=networkmanager
    [bluetoothctl]=bluez-utils [vulkaninfo]=vulkan-tools [glxinfo]=mesa-utils [vainfo]=libva-utils [powerprofilesctl]=power-profiles-daemon
    [hyprctl]=hyprland [nvme]=nvme-cli [edid-decode]=edid-decode [ss]=iproute2 [bootctl]=systemd [journalctl]=systemd [systemctl]=systemd
    [hostnamectl]=systemd [lsblk]=util-linux [findmnt]=util-linux [swapon]=util-linux [free]=procps-ng [lsmod]=kmod [lscpu]=util-linux )
  for t in $(printf '%s\n' "${!PKG[@]}" | sort); do
    command -v "$t" >/dev/null 2>&1 || { missing+=("$t"); pk+=("${PKG[$t]}"); }
  done
  if [ ${#missing[@]} -eq 0 ]; then ok "all diagnostic tools present"
  else
    wr "missing tools: ${missing[*]}"
    if command -v pacman >/dev/null 2>&1; then
      echo "        install [MEDIUM, sudo, needs approval]: sudo pacman -S --needed $(printf '%s\n' "${pk[@]}" | sort -u | tr '\n' ' ')"
      echo "        'target not found'? never run 'pacman -Sy <pkg>' (partial upgrade). Do a full 'sudo pacman -Syu' first, or look up the owner: sudo pacman -Fy; pacman -F <tool>"
    else echo "        non-Arch system: install the packages that provide those commands with your package manager"; fi
  fi

  if command -v journalctl >/dev/null 2>&1; then
    if journalctl -b -n1 --no-pager >/dev/null 2>&1; then ok "system journal readable"
    else wr "journal not readable -> sudo usermod -aG systemd-journal \"\$USER\"  [MEDIUM, sudo; log out/in]  or ask the user to run journalctl with sudo and paste"; fi
    if [ -d /var/log/journal ]; then ok "persistent journal on (previous-boot logs available)"
    else wr "no persistent journal ('journalctl -b -1' will be empty) -> sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald  [MEDIUM, optional]"; fi
  fi

  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if [ -d "$XDG_RUNTIME_DIR" ]; then ok "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
  else wr "XDG_RUNTIME_DIR missing ($XDG_RUNTIME_DIR): not in a user session (ssh/sudo/su?). Use: export XDG_RUNTIME_DIR=/run/user/\$(id -u)  [READ-ONLY, this shell only]"; fi
  hypr_env
  if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    if command -v hyprctl >/dev/null 2>&1 && timeout 5 hyprctl version >/dev/null 2>&1; then ok "Hyprland reachable (instance $HYPRLAND_INSTANCE_SIGNATURE)"
    else wr "Hyprland instance found but hyprctl cannot reach it (stale instance or hyprctl missing): run display checks inside the session"; fi
  else wr "no Hyprland instance: display checks must run inside the session (not TTY/ssh/su)"; fi

  od=$(dirname "${AUDIT_OUT:-$HOME/x}")
  if touch "$od/.audit-wtest.$$" 2>/dev/null; then rm -f "$od/.audit-wtest.$$"; ok "report dir writable: $od"
  else wr "report dir not writable: $od -> use AUDIT_OUT=/tmp/audit.txt (audit.sh falls back to /tmp by itself)"; fi
  state="${CHANGES_DIR:-$HOME/.local/state/omarchy-troubleshooter}"
  if [ -d "$state" ]; then
    if [ -w "$state" ]; then ok "state dir writable: $state"
    else wr "state dir not writable (created by a sudo run?) -> sudo chown -R \"\$USER\": '$state'  [MEDIUM, sudo]"; fi
  elif [ $fix = 1 ] && mkdir -p "$state" 2>/dev/null; then fx "created $state"
  else wr "state dir missing (created automatically on first backup; or: mkdir -p '$state' [LOW])"; fi
  avail=$(df -Pk "$HOME" 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f4)
  if [ "${avail:-0}" -lt 102400 ] 2>/dev/null; then wr "low disk space on \$HOME (${avail:-?} KB free): reports and backups may fail"; else ok "disk space on \$HOME"; fi

  p=$([ $fix = 1 ] && echo "Re-run without --fix to confirm.")
  echo "== doctor summary: $bad FAIL, $warn WARN. Each repair shows its risk class; MEDIUM and above need explicit user approval. $p =="
  [ $bad -eq 0 ]
}

case "${1:-}" in
  --doctor) shift; doctor "$@"; exit $? ;;
  -h|--help) sed -n '2,10p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# ---------------------------------------------------------------- audit run
out="${AUDIT_OUT:-$HOME/audit-$(date +%F-%H%M).txt}"
if ! { mkdir -p "$(dirname "$out")" && : >"$out"; } 2>/dev/null; then
  out="/tmp/audit-$(id -u)-$(date +%F-%H%M).txt"; echo "[warn] requested path not writable, using $out" >&2
fi
slices=("$@"); [ ${#slices[@]} -eq 0 ] && slices=(system cpu power gpu display net storage logs security)

since="${AUDIT_SINCE:-}"; jarg="-b"
if [ -n "$since" ]; then
  if [[ $since =~ ^[0-9A-Za-z:\ .-]+$ ]]; then jarg="--since \"$since\""
  else echo "[warn] AUDIT_SINCE has unsupported characters; ignored" >&2; fi
fi

{ s_preflight
  for s in "${slices[@]}"; do
    if declare -F "s_$s" >/dev/null && [ "$s" != preflight ]; then "s_$s"; else printf '[unknown slice] %s\n' "$s"; fi
  done; } 2>&1 | redact >"$out"

if [ -s "$out" ]; then
  chmod 600 "$out"
  echo "Report: $out ($(wc -l <"$out") lines). Redaction is best-effort (IPv6 and some names are not covered): skim before sharing."
  miss=$(grep -c '^\[missing tool\]' "$out"); tmo=$(grep -c '^\[timeout' "$out")
  perm=$(grep -ciE 'permission denied|operation not permitted|not authorized|access denied|not seeing messages' "$out")
  nohy=$(grep -c '^\[no running Hyprland' "$out"); unk=$(grep -c '^\[unknown slice\]' "$out")
  if [ $((miss+tmo+perm+nohy+unk)) -gt 0 ]; then
    echo "[hint] $miss missing tool(s), $tmo timeout(s), $perm permission message(s), $nohy no-Hyprland, $unk unknown slice(s). Diagnose and get repair commands: bash '$SELF' --doctor"
  fi
else echo "[error] report is empty; check disk space and permissions on $(dirname "$out"), then: bash '$SELF' --doctor" >&2; exit 1; fi
