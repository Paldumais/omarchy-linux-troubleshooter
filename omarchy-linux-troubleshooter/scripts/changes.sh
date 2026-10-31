#!/usr/bin/env bash
# Backups + persistent change log, so rollback survives long chats and context compaction.
#   changes.sh backup FILE...      copy FILE(s) (full path preserved) into a timestamped set; log it
#   changes.sh log "message"       append one line (what / why / verified?) to the change log
#   changes.sh list                last 20 log lines + backup sets
#   changes.sh restore TS FILE     show diff, then restore FILE from backup set TS  (this IS a change: needs approval)
#   changes.sh doctor [--fix]      check this tool's prerequisites; --fix only creates the state dir (LOW risk)
# Root-owned files: run with sudo (state dir stays under the invoking user's home). Nothing here edits the files itself.
set -u
usage(){ sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
user="${SUDO_USER:-$(id -un)}"
home=$(getent passwd "$user" | cut -d: -f6); home="${home:-$HOME}"
state="${CHANGES_DIR:-$home/.local/state/omarchy-troubleshooter}"
if [ "${1:-}" = doctor ]; then
  fix=0; bad=0; [ "${2:-}" = "--fix" ] && fix=1
  for t in realpath cp diff getent date mktemp tr; do
    command -v "$t" >/dev/null 2>&1 || { echo "FAIL    core tool missing: $t (coreutils/diffutils): base system problem, stop and report"; bad=$((bad+1)); }
  done
  d=$(mktemp -d 2>/dev/null) || d=""
  if [ -n "$d" ] && mkdir -p "$d/s/x" "$d/o" && : >"$d/s/x/f" && cp -a --parents -- "$d/s/x/f" "$d/o/" 2>/dev/null && [ -e "$d/o$d/s/x/f" ]
  then echo "OK      cp --parents works"; else echo "FAIL    cp --parents unsupported or temp dir unusable (GNU coreutils needed)"; bad=$((bad+1)); fi
  [ -n "$d" ] && rm -rf "$d"
  sd=$(cd "$(dirname "$0")" && pwd)
  for f in "$sd"/*.sh; do
    [ -e "$f" ] || continue
    if grep -q $'\r' "$f"; then
      if [ $fix = 1 ] && [ "$f" != "$(realpath "$0")" ] && sed -i.bak 's/\r$//' "$f"; then echo "FIXED   CRLF removed from $f (backup: $f.bak)"
      else echo "FAIL    CRLF line endings in $f -> sed -i.bak 's/\\r\$//' '$f'   [LOW]"; bad=$((bad+1)); fi
    fi
    if [ ! -x "$f" ]; then
      if [ $fix = 1 ] && chmod +x "$f" 2>/dev/null; then echo "FIXED   chmod +x $f"
      else echo "WARN    not executable: $f -> chmod +x '$f'   [LOW]  (or run: bash '$f')"; fi
    fi
  done
  if [ -d "$state" ]; then
    if [ -w "$state" ] && touch "$state/.wtest.$$" 2>/dev/null; then rm -f "$state/.wtest.$$"; echo "OK      state dir writable: $state"
    else echo "FAIL    state dir not writable (created by a sudo run?) -> sudo chown -R \"$user\": '$state'   [MEDIUM, sudo]"; bad=$((bad+1)); fi
  elif [ $fix = 1 ] && mkdir -p "$state/backups" 2>/dev/null; then echo "FIXED   created $state"
  else echo "WARN    state dir missing -> mkdir -p '$state/backups'   [LOW]  (or: $0 doctor --fix)"; fi
  [ -n "${SUDO_USER:-}" ] && echo "INFO    running via sudo: the state dir is resolved for user '$SUDO_USER'"
  echo "== changes.sh doctor: $bad FAIL =="; [ $bad -eq 0 ]; exit $?
fi
mkdir -p "$state/backups" || { echo "[error] cannot create $state" >&2; exit 1; }
logf="$state/changes.log"
fixown(){ [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER": "$state" 2>/dev/null; return 0; }
logline(){ printf '%s | %s\n' "$(date -Is)" "$(printf '%s' "$*" | tr '\n' ' ')" >>"$logf"; }

case "${1:-}" in
  backup)
    shift; [ $# -gt 0 ] || usage
    ts=$(date +%Y%m%d-%H%M%S); n=0
    mkdir -p "$state/backups/$ts" || { echo "[error] cannot create backup set" >&2; exit 1; }
    for f in "$@"; do
      f=$(realpath -m -- "$f")
      if   [ ! -e "$f" ]; then echo "[skip] not found: $f" >&2; continue
      elif [ ! -r "$f" ]; then echo "[fail] unreadable, retry with sudo: $f" >&2; continue; fi
      if cp -a --parents -- "$f" "$state/backups/$ts/"; then
        n=$((n+1)); logline "backup | $f | set=$ts"; echo "backed up: $f"
      else echo "[fail] copy failed: $f" >&2; fi
    done
    [ $n -gt 0 ] || { echo "[error] nothing backed up; do NOT edit these files yet" >&2; exit 1; }
    fixown; echo "restore with: $0 restore $ts <file>" ;;
  log)
    shift; [ $# -gt 0 ] || usage
    logline "$*"; fixown; echo "logged" ;;
  list)
    echo "--- last log lines ($logf)"; tail -n 20 "$logf" 2>/dev/null || echo "(empty)"
    echo "--- backup sets"; ls -1 "$state/backups" 2>/dev/null | tail -n 20 ;;
  restore)
    ts="${2:-}"; f="${3:-}"; [ -n "$ts" ] && [ -n "$f" ] || usage
    [[ $ts =~ ^[0-9]{8}-[0-9]{6}$ ]] || { echo "[error] bad set id (expected YYYYMMDD-HHMMSS)" >&2; exit 2; }
    f=$(realpath -m -- "$f"); src="$state/backups/$ts$f"
    [ -e "$src" ] || { echo "[error] no such backup: $src" >&2; exit 1; }
    echo "--- diff (current vs backup)"; diff -ru -- "$f" "$src" | head -80; echo "---"
    if cp -a -- "$src" "$f"; then
      logline "restore | $f | from set=$ts"; fixown
      echo "restored $f. Reload/restart what uses it, then re-verify."
    else echo "[error] restore failed (permissions? retry with sudo)" >&2; exit 1; fi ;;
  *) usage ;;
esac
