#!/usr/bin/env bash
set -u
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0

REPO="${BN_REPO:-$HOME/botlatro-sim-main}"
END_AT="$(date -d "${BN_END:-08:00}" +%s)"
[ "$END_AT" -le "$(date +%s)" ] && END_AT=$(( END_AT + 86400 ))
CEILING="${BN_CEILING:-}"
GUARD_EVERY="${BN_GUARD_EVERY:-240}"
MARGIN="${BN_MARGIN:-1200}"
QUICK_WAIT="${BN_QUICK_WAIT:-300}"
SESSION_HOURS="${BN_SESSION_HOURS:-4}"
MODEL="${BN_MODEL:-opus}"
CLAUDE="${BN_CLAUDE:-claude}"
HZ="${BN_HZ:-python3 tools/botsim/cloud/hz.py}"
AP="${BN_AP:-python3 tools/botsim/autopilot/autopilot.py}"
DAY="$(date +%Y-%m-%d)"
STATE="${BN_STATE:-$HOME/.local/state/botlatro-night}"
LOGS="${BN_LOGS:-$STATE/$(date +%m%d_%H%M)}"
REPORT="tools/botsim/night/REPORT-$DAY.md"
GIT=(git -c user.name="Gabriel Quart" -c user.email="gabriel.quart.15@gmail.com")
TOOLS=(Read Edit Write Glob Grep
    "Bash(python3:*)" "Bash(git:*)" "Bash(gh:*)" "Bash(date:*)" "Bash(ls:*)" "Bash(cat:*)" "Bash(head:*)"
    "Bash(tail:*)" "Bash(grep:*)" "Bash(wc:*)" "Bash(find:*)" "Bash(mkdir:*)" "Bash(cp:*)" "Bash(mv:*)" "Bash(rm:*)"
    "Bash(sed:*)" "Bash(sort:*)" "Bash(diff:*)" "Bash(cut:*)" "Bash(cd:*)" "Bash(chmod:*)" "Bash(ps:*)" "Bash(until:*)")
KEEP=(tools/botsim/cloud/spend.json tools/botsim/cloud/SPEND.md)

[ "${1:-}" = "ceiling" ] || mkdir -p "$LOGS"
cd "$REPO" || exit 1
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOGS/night.log"; }
now() { date +%s; }

ledger() {
    $HZ spend --json 2>/dev/null | python3 -c 'import json,sys
for l in reversed(sys.stdin.read().splitlines()):
    try:
        print(json.loads(l)["spent_eur"]); break
    except Exception: pass'
}

ceiling() {
    local c
    c="$(cat "$LOGS/ceiling" 2>/dev/null)"
    echo "${c:-$CEILING}"
}

over() {
    local s="$1" c
    c="$(ceiling)"
    [ -n "$c" ] && [ -n "$s" ] && python3 -c "import sys; sys.exit(0 if float('$s') >= float('$c') else 1)"
}

money_stop() {
    say "MONEY: ledger $1 EUR reached the ceiling $(ceiling), deleting every box and stopping the autopilot"
    touch "$LOGS/NO_PAID"
    $AP stop "night ceiling $(ceiling) EUR reached (ledger $1)" >>"$LOGS/night.log" 2>&1
    for i in 1 2 3; do
        $HZ down >>"$LOGS/night.log" 2>&1
        $HZ list 2>/dev/null | grep -q "no botsim servers" && break
        sleep 20
    done
}

guard() {
    while [ "$(now)" -lt $(( END_AT + 3600 )) ]; do
        local s
        s="$(ledger)"
        if [ -z "$s" ]; then
            say "guard: cannot read the ledger"
        elif over "$s"; then
            if [ ! -f "$LOGS/NO_PAID" ]; then
                money_stop "$s"
            elif ! $HZ list 2>/dev/null | grep -q "no botsim servers"; then
                say "MONEY: boxes listed after the ceiling, deleting them"
                $HZ down >>"$LOGS/night.log" 2>&1
            fi
        fi
        sleep "$GUARD_EVERY"
    done
}

tidy() {
    local dirty
    if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
        say "session left branch $(git rev-parse --abbrev-ref HEAD), back to main"
        git switch -q --merge main >>"$LOGS/night.log" 2>&1 || { git checkout -q -- . && git switch -q main; say "could not carry the changes to main, dropped them"; }
    fi
    dirty="$(git status --porcelain --untracked-files=no | awk '{print $2}' | grep -vxF -f <(printf '%s\n' "${KEEP[@]}"))"
    if [ -n "$dirty" ]; then
        echo "$dirty" | xargs git add -- && "${GIT[@]}" commit -qm "Night: leftovers of session $1" && say "committed leftovers of session $1"
    fi
    git push -q origin main >>"$LOGS/night.log" 2>&1 || say "push of main failed (kept local)"
}

session() {
    local n="$1" secs prompt paid="yes" c s left="unknown"
    secs=$(( END_AT - $(now) ))
    [ "$secs" -gt $(( SESSION_HOURS * 3600 )) ] && secs=$(( SESSION_HOURS * 3600 ))
    c="$(ceiling)"
    s="$(ledger)"
    [ -n "$c" ] && [ -n "$s" ] && left="$(python3 -c "print('%.2f' % max(0.0, float('$c') - float('$s')))")"
    [ -f "$LOGS/NO_PAID" ] && paid="no, the money ceiling was reached: free CI work only"
    prompt="$(sed -e "s#{END}#$(date -d "@$END_AT" +%H:%M)#g" -e "s#{STOP}#$(date -d "@$(( $(now) + secs - 900 ))" +%H:%M)#g" \
        -e "s#{CEILING}#${c:-none}#g" -e "s#{LEDGER}#${s:-unknown}#g" -e "s#{LEFT}#$left#g" \
        -e "s#{DONE}#$LOGS/DONE#g" -e "s#{PAID}#$paid#g" -e "s#{REPORT}#$REPORT#g" -e "s#{N}#$n#g" tools/botsim/night/prompt.md)"
    say "session $n starts, up to $(( secs / 60 )) min, ceiling ${c:-none} EUR, ledger ${s:-unknown} EUR"
    timeout "$secs" "$CLAUDE" -p "$prompt" --model "$MODEL" --permission-mode acceptEdits --allowedTools "${TOOLS[@]}" \
        --output-format text >"$LOGS/session-$n.log" 2>&1
    say "session $n ended (exit $?), log $LOGS/session-$n.log"
}

run() {
    [ -n "$CEILING" ] && echo "$CEILING" >"$LOGS/ceiling"
    ln -sfn "$LOGS" "$STATE/current"
    say "night starts, ends $(date -d "@$END_AT" '+%a %H:%M'), ceiling ${CEILING:-none} EUR, logs $LOGS"
    [ -n "$CEILING" ] || say "WARNING: no BN_CEILING set"
    guard &
    local guard_pid=$! n=0 t0 quick=0
    while [ $(( END_AT - $(now) )) -gt "$MARGIN" ]; do
        n=$(( n + 1 ))
        git switch -q main 2>/dev/null
        git pull -q --rebase --autostash origin main >>"$LOGS/night.log" 2>&1 || { git rebase --abort 2>/dev/null; say "pull of main failed"; }
        t0=$(now)
        session "$n"
        tidy "$n"
        if [ -f "$LOGS/DONE" ]; then
            say "session $n marked the work done, stopping"
            break
        fi
        if [ $(( $(now) - t0 )) -lt 180 ]; then
            quick=$(( quick + 1 ))
            say "session $n was short ($quick in a row), waiting $(( quick * QUICK_WAIT )) s"
            sleep $(( quick * QUICK_WAIT > 1800 ? 1800 : quick * QUICK_WAIT ))
        else
            quick=0
        fi
    done
    kill "$guard_pid" 2>/dev/null
    local s
    s="$(ledger)"
    over "$s" && [ ! -f "$LOGS/NO_PAID" ] && money_stop "$s"
    {
        echo
        echo "## Runner summary"
        echo "- Sessions: $n. Ledger at the end: ${s:-unknown} EUR (ceiling $(ceiling))."
        echo "- Boxes: $($HZ list 2>/dev/null | head -1)"
        echo "- Logs: $LOGS"
    } >>"$REPORT"
    git add "$REPORT" && "${GIT[@]}" commit -qm "Night report $DAY" && git push -q origin main >>"$LOGS/night.log" 2>&1
    say "night finished, main at $(git rev-parse --short HEAD)"
}

set_ceiling() {
    local cur="$STATE/current" old
    [ -n "${1:-}" ] && python3 -c "float('$1')" 2>/dev/null || { echo "usage: night.sh ceiling EUR"; return 1; }
    [ -d "$cur" ] || { echo "no night run found at $cur"; return 1; }
    old="$(cat "$cur/ceiling" 2>/dev/null)"
    echo "$1" >"$cur/ceiling"
    echo "[$(date +%H:%M:%S)] ceiling changed from ${old:-none} to $1 EUR (guard and next session prompts)" | tee -a "$cur/night.log"
}

{
    if [ "${1:-}" = "ceiling" ]; then
        set_ceiling "${2:-}"
        exit $?
    fi
    if [ "${BN_GUARD_ONLY:-}" = "1" ]; then
        [ -n "$CEILING" ] && echo "$CEILING" >"$LOGS/ceiling"
        say "guard only, ceiling $CEILING EUR, until $(date -d "@$(( END_AT + 3600 ))" +%H:%M)"
        guard
        exit 0
    fi
    if [ "${BN_INHIBITED:-}" != "1" ] && command -v systemd-inhibit >/dev/null; then
        [ -n "${BN_DIM:-}" ] && brightnessctl set 0 >/dev/null 2>&1
        BN_LOGS="$LOGS" BN_INHIBITED=1 exec systemd-inhibit --what=sleep:idle:handle-lid-switch --who="Bot-latro night" --why="Bot-latro night run" bash "$0" "$@"
    fi
    run
    exit 0
}
