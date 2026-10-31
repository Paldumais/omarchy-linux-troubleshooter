# Self-repair catalog (tooling errors)

Scope: repairs the **skill's own tooling and its prerequisites**, never the system being diagnosed (that follows the normal fix workflow).

Contents: protocol · catalog · diagnostics to request

## Protocol
1. Run `bash <dir>/scripts/audit.sh --doctor` (or `changes.sh doctor` if audit.sh itself cannot start). It changes nothing and prints each repair with its risk class.
2. Match the exact error text below. Quote the error; do not paraphrase it.
3. Apply **one** repair at a time. LOW: apply when the user says go (`--doctor --fix` applies only LOW ones). MEDIUM and above: show the command, wait for explicit approval. Never use `sudo` from an agent shell: ask the user to run it and paste the result.
4. Verify by re-running the exact command that failed. Then `changes.sh log "tooling repair | <what> | verified yes/no"`.
5. Two failed repairs for the same error: stop (circuit breaker), report the evidence, ask the user.
6. If the script itself looks buggy (`unbound variable`, wrong output), capture `bash -x <script> <slice> 2>&1 | tail -30` and propose a minimal patch as a diff. Do not rewrite the script, and do not patch it without approval.

## Catalog
| Symptom (exact text) | Cause | Repair [class] | Verify |
|---|---|---|---|
| `Permission denied` when running `./audit.sh` | exec bit lost (browser upload, zip) | `chmod +x <dir>/scripts/*.sh` [LOW], or just run `bash <dir>/scripts/audit.sh` | script starts |
| `set: -\r: invalid option`, `$'\r': command not found`, `syntax error near unexpected token $'do\r'`, `bad interpreter` | CRLF line endings (Windows editor, git autocrlf, web upload) | `sed -i.bak 's/\r$//' <dir>/scripts/*.sh` [LOW]; prevent with `printf '*.sh text eol=lf\n' > .gitattributes` at the repo root | `grep -c $'\r' <file>` prints 0 |
| `No such file or directory` for a script path | path not relative to the skill dir, or folder incomplete | `find ~ /usr/share -name audit.sh -path '*omarchy-linux-troubleshooter*' 2>/dev/null`; reinstall the whole folder [LOW] | `--doctor` finds changes.sh and references |
| `[missing tool] X` | package not installed | `--doctor` prints one consolidated `sudo pacman -S --needed ...` [MEDIUM, sudo, approval] | `command -v X` |
| `error: target not found: <pkg>` | package DB not synced or wrong name | Never `pacman -Sy <pkg>` (partial upgrade). Full `sudo pacman -Syu` first [MEDIUM], or `sudo pacman -Fy; pacman -F <tool>` to find the owning package [LOW] | `pacman -Qi <pkg>` |
| `unable to lock database` | another pacman running or stale lock | `pgrep -a pacman` [READ-ONLY]; wait. Remove `/var/lib/pacman/db.lck` only if no pacman process exists [MEDIUM, approval] | next pacman call works |
| `Hint: You are currently not seeing messages from other users and the system`, `No journal files were found` | user not in a journal-reading group | `sudo usermod -aG systemd-journal "$USER"` then log out/in [MEDIUM, sudo]; or user runs `sudo journalctl ...` and pastes | `journalctl -b -n1` prints a line |
| `Specifying boot ID or boot offset has no effect, no persistent journal was found` | volatile journal: no previous-boot logs | `sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald` [MEDIUM, optional]; effective from next boot | `ls /var/log/journal` |
| `[no running Hyprland instance found ...]`, `HYPRLAND_INSTANCE_SIGNATURE not set`, `Couldn't connect to socket` | shell outside the session (TTY/ssh/su) or stale instance | audit.sh auto-detects the newest instance; manual: `export XDG_RUNTIME_DIR=/run/user/$(id -u); export HYPRLAND_INSTANCE_SIGNATURE=$(basename "$(ls -td "$XDG_RUNTIME_DIR"/hypr/*/ \| head -1)")` [READ-ONLY]; otherwise ask the user to run the display slice inside Hyprland | `hyprctl version` |
| `Failed to connect to bus`, `XDG_RUNTIME_DIR` not set | shell not in a user session | `export XDG_RUNTIME_DIR=/run/user/$(id -u)` [READ-ONLY, this shell only] | `systemctl --user --failed` works |
| `sudo: a terminal is required`, command hangs | agent shell has no TTY | user runs the command in a terminal and pastes the output | pasted output |
| `[timeout after 20s]` | slow or hung tool (vulkaninfo, bluetoothctl, nmcli) | run that command alone with a longer limit: `timeout 60 <cmd>` [READ-ONLY]; check its service with `systemctl status <svc>`; restarting a service is [MEDIUM] | command returns |
| `[error] report is empty`, `[warn] requested path not writable` | disk full or unwritable path | `df -h ~`; use `AUDIT_OUT=/tmp/audit.txt` [LOW] | report file written |
| `[fail] unreadable, retry with sudo` (changes.sh) | root-owned file | user runs `sudo bash <dir>/scripts/changes.sh backup <file>` [MEDIUM] | backup path listed by `changes.sh list` |
| `cannot create .../omarchy-troubleshooter`, `state dir not writable` | state dir root-owned after a sudo run | `sudo chown -R "$USER": ~/.local/state/omarchy-troubleshooter` [MEDIUM, sudo] or `changes.sh doctor --fix` if just missing [LOW] | `changes.sh doctor` OK |
| Output cut off by the agent tool | tool output limit | re-run one slice, or narrow with `grep`/`tail`/`AUDIT_SINCE` [READ-ONLY]; never conclude from partial data | complete section visible |
| `unbound variable`, `line N: ... command not found` (and no CR present) | script bug or missing dependency | follow Protocol step 6 | patched script passes the failing case |

## Diagnostics to request when the error is not in the catalog
Ask for only these, in this order: the exact error text; `bash <dir>/scripts/audit.sh --doctor`; `bash -x <script> <slice> 2>&1 | tail -30`; `bash --version | head -1; uname -r`. Then add the new error to this table after it is solved.
