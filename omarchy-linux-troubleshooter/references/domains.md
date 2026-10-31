# Domain checklists (load only the section that matches the symptom)

Contents: power · gpu · display · wifi-bt · asus · suspend · storage · security

## power
CPU/amd-pstate-epp. Check: driver and mode (`/sys/devices/system/cpu/amd_pstate/status`), EPP vs active profile, `platform_profile`, exactly one power manager active, AC vs battery behavior. Measure real draw (battery `power_now` or current x voltage, `turbostat` PkgWatt if installed) at idle with a fixed workload, before and after. Goals: battery efficiency, balanced, max on AC. Reject savings that cost responsiveness or stability.

## gpu
Radeon 880M / amdgpu. Check: firmware loaded (no `Direct firmware load ... failed`), `journalctl -k` for ring timeouts, `[drm] *ERROR*`, display-engine/DCN faults, PSR/PSR-SU messages; RADV/Vulkan works; VA-API decode works; VRAM vs GTT sizes. PSR/DC/panel-replay kernel parameters are targeted workarounds: only with matching log symptoms, with purpose and revert path stated (MEDIUM risk).

## display
Samsung OLED, native 2880x1800 @120 Hz. Targets: 120 Hz on AC, 60 Hz on battery, scale ~1.6-2.0, accurate P3 without oversaturation, HDR only if the whole stack works, VRR only if verified.
- Inspect actual state: `hyprctl monitors all` (mode, format, bit depth, color-management preset, VRR), `hyprctl configerrors`, EDID in `/sys/class/drm/*/edid` (`edid-decode` if installed). Validate every monitor/cm key against the installed Hyprland version.
- A loaded ICC profile is not proof it is applied: compare output with/without it using a test pattern or reference image.
- 10-bit (`XRGB2101010`) only if no regression (screen sharing, apps, flicker); 8-bit SDR is a fine default.
- Test HDR/VRR with a real capable client; watch for OLED VRR flicker and brightness shifts. Never enable HDR just because the panel advertises it.
- Check docks/DisplayLink only if one is connected.
- AC/battery refresh switching: least invasive native mechanism (udev/ACPI event + `hyprctl keyword`, or an Omarchy-supported hook). No polling daemon.

## wifi-bt
MT7922, `mt7921e`. Check: driver bound, firmware version in log, regdomain (`iw reg get`), band/width in use (`iw dev <if> link`), NM power-save setting, ASPM link state (`lspci -vv`, needs sudo), Bluetooth coexistence symptoms (audio stutter, 2.4 GHz). Do not disable power save or ASPM without a matching symptom; if you do, measure throughput/latency/loss and battery before and after (`iperf3`, `ping -c 100`).

## asus
Check: `asus_wmi`/`asus_nb_wmi` loaded, `platform_profile` and its choices, battery `charge_control_end_threshold` (read before write; setting it is LOW-MEDIUM risk via sysfs/udev/systemd), keyboard backlight, hotkeys (`journalctl`, `wev`). Never write EC registers or force unsupported fan modes. If `asusctl`/`asusd` is proposed, justify it against native sysfs and check conflicts with power-profiles-daemon.

## suspend
Check: `/sys/power/mem_sleep` (report what is there; make no assumption), journal around the suspend/resume (`journalctl -b -1` if needed), wake sources (`/proc/acpi/wakeup`), post-resume errors from amdgpu, mt7921e, NVMe, USB/USB4. Compare with the previous kernel. Intermittent: require repeated cycles before concluding.

## storage
NVMe SMART (`critical_warning`, `percentage_used`, `media_errors`, temperature; sudo), PCIe link speed, AER/timeouts in logs, OOM events, swap/zram state, filesystem errors in logs. No repair on mounted filesystems; no destructive tests.

## security
Report, do not harden unless asked: Secure Boot state, TPM presence, `pacman -Qkk` anomalies (read-only), foreign/AUR packages (`pacman -Qm`), listening sockets (`ss -tulpn`), failed units, firewall state, SSH exposure.
