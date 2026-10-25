#!/usr/bin/env bash
# Scenario tests for claude-switch. Everything runs against a temp dir: no real settings,
# no real key, no network. A fake `claude` binary stands in for `claude auth status`.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CS="$HERE/../bin/claude-switch"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

export CLAUDE_SWITCH_HOME="$T/home"
export CLAUDE_SWITCH_SETTINGS="$T/settings.json"
export CLAUDE_SWITCH_BACKUP_DIR="$T/backups"
export CLAUDE_SWITCH_CLAUDE_BIN="$T/fake-claude"
cat > "$T/fake-claude" <<'EOF'
#!/usr/bin/env bash
# reports api_key_helper when the test settings file carries an apiKeyHelper, else claude.ai
if grep -q apiKeyHelper "$CLAUDE_SWITCH_SETTINGS"; then m=api_key_helper; else m=claude.ai; fi
echo "{\"loggedIn\": true, \"authMethod\": \"$m\"}"
EOF
chmod +x "$T/fake-claude"
echo '{"$schema":"x","model":"fable","env":{"A":"1"}}' > "$T/settings.json"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { # check <desc> <cmd...>  -> passes if command exits 0
  if "${@:2}" >/dev/null 2>&1; then ok "$1"; else fail "$1"; fi
}
has_helper()  { python3 -c 'import json,sys; sys.exit(0 if "apiKeyHelper" in json.load(open(sys.argv[1])) else 1)' "$CLAUDE_SWITCH_SETTINGS"; }
no_helper()   { ! has_helper; }
effective()   { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["effective"])' "$CLAUDE_SWITCH_HOME/state.json"; }
field()       { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$CLAUDE_SWITCH_HOME/state.json" "$1"; }
sl() { # sl <five_hour_pct|-> <resets_at> <session> <cost>  -> feed a statusline JSON
  python3 - "$@" <<'PY' | "$CS" statusline
import json, sys
pct, resets, sid, cost = sys.argv[1:5]
d = {"session_id": sid, "cost": {"total_cost_usd": float(cost)}, "model": {"id": "m"}}
if pct != "-":
    d["rate_limits"] = {"five_hour": {"used_percentage": int(pct), "resets_at": int(resets)}}
print(json.dumps(d))
PY
}
sf() { printf '{"hook_event_name":"StopFailure","error":"%s","last_assistant_message":"API Error: x"}' "$1" | "$CS" on-stop-failure; }
export CS; export -f has_helper no_helper effective field   # used inside `bash -c` checks

T0=1800000000            # fixed "now"
export CLAUDE_SWITCH_NOW=$T0

echo "# install"
"$CS" install >/dev/null
check "settings keeps unrelated keys"      python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["model"]=="fable" and d["env"]=={"A":"1"}' "$CLAUDE_SWITCH_SETTINGS"
check "statusLine + hooks registered"      python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "statusline" in d["statusLine"]["command"]; assert d["hooks"]["StopFailure"] and d["hooks"]["Stop"]' "$CLAUDE_SWITCH_SETTINGS"
check "no apiKeyHelper after install"      no_helper
check "backup written"                      bash -c 'ls "$CLAUDE_SWITCH_BACKUP_DIR"/settings-*.json'
check "api-key refuses in max mode"         bash -c '! "$CS" api-key'
printf 'sk-ant-api03-TESTKEY' | "$CS" set-key >/dev/null
check "key file is 0600"                    bash -c '[ "$(stat -c %a "$CLAUDE_SWITCH_HOME/api_key")" = 600 ]'

echo "# scenario 1: plenty of quota -> stays on Max"
out=$(sl 4 $((T0+3600)) s1 0.01)
check "effective max"                       bash -c '[ "$(effective)" = max ]'
check "statusline shows MAX and 4%"         bash -c 'echo "$1" | grep -q MAX && echo "$1" | grep -q "5h 4%"' _ "$out"
check "no API spend recorded on Max"        bash -c '[ "$(field api_spend)" = "{}" ]'

echo "# scenario 2: quota exhausted (96%) -> switch to API"
out=$(sl 96 $((T0+3600)) s1 0.02)
check "effective api"                       bash -c '[ "$(effective)" = api ]'
check "apiKeyHelper present"                has_helper
check "helper outputs key"                  bash -c '[ "$("$CS" api-key)" = sk-ant-api03-TESTKEY ]'
check "recover time = resets_at"            bash -c '[ "$(field max_recover_at)" = '"$((T0+3600))"' ]'
check "statusline shows API"                bash -c 'echo "$1" | grep -q API' _ "$out"
check "switch logged"                       bash -c '"$CS" log | grep -q "SWITCH max -> api"'

echo "# scenario 3: API-mode cost accounting (no rate_limits in JSON)"
export CLAUDE_SWITCH_NOW=$((T0+60))
sl - 0 s1 0.52 >/dev/null     # +0.50 since last seen 0.02
sl - 0 s2 0.25 >/dev/null     # new session, +0.25
check "daily spend = 0.75"                  bash -c 'python3 -c "import json,sys; v=list(json.load(open(sys.argv[1]))[\"api_spend\"].values())[0]; assert abs(v-0.75)<1e-6" "$CLAUDE_SWITCH_HOME/state.json"'
check "cost log has 2 lines"                bash -c '[ "$(wc -l < "$CLAUDE_SWITCH_HOME/log/api-cost.jsonl")" = 2 ]'
check "usage not cleared by API-mode data"  bash -c '[ "$(field usage)" != "{}" ]'

echo "# scenario 4: before reset -> stays API; after reset -> back to Max"
export CLAUDE_SWITCH_NOW=$((T0+3599))
"$CS" check >/dev/null
check "still api 1s before reset"           bash -c '[ "$(effective)" = api ]'
export CLAUDE_SWITCH_NOW=$((T0+3601))
check "check reports switched"              bash -c '[ "$("$CS" check)" = switched ]'
check "effective max after reset"           bash -c '[ "$(effective)" = max ]'
check "apiKeyHelper removed"                no_helper
check "fresh-process auth verified"         bash -c 'sleep 1; "$CS" log | grep -q "VERIFY auth status = claude.ai OK"'

echo "# scenario 5: still exhausted after reset (weekly) -> back to API, reset far in future"
export CLAUDE_SWITCH_NOW=$((T0+3700))
python3 - <<PY | "$CS" statusline >/dev/null
import json
print(json.dumps({"session_id":"s3","cost":{"total_cost_usd":0},
  "rate_limits":{"five_hour":{"used_percentage":10,"resets_at":$((T0+3700+18000))},
                 "seven_day":{"used_percentage":100,"resets_at":$((T0+3700+86400))}}}))
PY
check "weekly exhaustion switches to api"   bash -c '[ "$(effective)" = api ]'
check "recover at weekly reset"             bash -c '[ "$(field max_recover_at)" = '"$((T0+3700+86400))"' ]'

echo "# scenario 6: daily soft limit -> back to Max and API blocked"
export CLAUDE_SWITCH_NOW=$((T0+3800))
sl - 0 s3 4.50 >/dev/null   # +4.50 -> 5.25 today >= 5.0
check "effective max"                       bash -c '[ "$(effective)" = max ]'
check "api blocked"                         bash -c '[ "$(field api_blocked)" = True ]'
sl 100 $((T0+9000)) s3 4.50 >/dev/null
check "exhaustion ignored while blocked"    bash -c '[ "$(effective)" = max ]'
"$CS" set-mode auto >/dev/null
check "set-mode auto clears block"          bash -c '[ "$(field api_blocked)" = False ]'
check "...and re-enters API (quota still 100%)" bash -c '[ "$(effective)" = api ]'

echo "# scenario 7: API auth failure -> immediate stop, back to Max"
export CLAUDE_SWITCH_NOW=$((T0+90000))   # next day: spend counter fresh, recovery time passed
"$CS" check >/dev/null
check "recovered to max overnight"          bash -c '[ "$(effective)" = max ]'
sl 100 $((T0+90000+3600)) s4 0 >/dev/null
check "in api"                              bash -c '[ "$(effective)" = api ]'
sf authentication_failed
check "back to max"                         bash -c '[ "$(effective)" = max ]'
check "blocked with reason"                 bash -c '"$CS" status | grep -q "API BLOCKED:.*authentication_failed"'
"$CS" set-mode auto >/dev/null

echo "# scenario 8: StopFailure rate_limit guard"
export CLAUDE_SWITCH_NOW=$((T0+100000))
"$CS" check >/dev/null                             # recovery time passed -> max
sl 20 $((T0+100000+3600)) s5 0 >/dev/null          # fresh usage 20%
sf rate_limit
check "rate_limit at 20% ignored"           bash -c '[ "$(effective)" = max ]'
sl 85 $((T0+100000+3600)) s5 0 >/dev/null          # 85% >= guard 80
sf rate_limit
check "rate_limit at 85% switches"          bash -c '[ "$(effective)" = api ]'
check "recover from known resets_at"        bash -c '[ "$(field max_recover_at)" = '"$((T0+100000+3600))"' ]'
"$CS" set-mode max >/dev/null
export CLAUDE_SWITCH_NOW=$((T0+100000+5000))       # usage now stale (>900s)
"$CS" set-mode auto >/dev/null
sf rate_limit
check "rate_limit with stale usage switches" bash -c '[ "$(effective)" = api ]'

echo "# scenario 9: forced modes"
"$CS" set-mode max >/dev/null
check "force max removes helper"            no_helper
sl 100 $((T0+200000)) s6 0 >/dev/null
check "force max ignores exhaustion"        no_helper
"$CS" set-mode api >/dev/null
check "force api adds helper"               has_helper
"$CS" set-mode auto >/dev/null

echo "# scenario 9b: leaving forced api with quota available -> back to max; key removed in api -> back to max"
export CLAUDE_SWITCH_NOW=$((T0+250000))
"$CS" set-mode auto >/dev/null; "$CS" check >/dev/null
sl 10 $((T0+250000+3600)) s6b 0 >/dev/null
"$CS" set-mode api >/dev/null
"$CS" set-mode auto >/dev/null
check "auto after forced api returns to max" bash -c '[ "$(effective)" = max ] && no_helper'
"$CS" set-mode api >/dev/null
mv "$CLAUDE_SWITCH_HOME/api_key" "$CLAUDE_SWITCH_HOME/api_key.bak"
"$CS" set-mode auto >/dev/null
check "missing key in api -> max"           bash -c '[ "$(effective)" = max ] && no_helper'
mv "$CLAUDE_SWITCH_HOME/api_key.bak" "$CLAUDE_SWITCH_HOME/api_key"

echo "# scenario 9c: forced api + API auth error -> still falls back to max and blocks"
"$CS" set-mode api >/dev/null
sf authentication_failed
check "forced api overridden by auth error" bash -c '[ "$(effective)" = max ] && no_helper && [ "$(field api_blocked)" = True ]'
"$CS" set-mode auto >/dev/null

echo "# scenario 10: server errors never switch"
"$CS" set-mode auto >/dev/null; export CLAUDE_SWITCH_NOW=$((T0+300000))
sl 30 $((T0+300000+3600)) s7 0 >/dev/null
for e in overloaded server_error unknown invalid_request; do sf $e; done
check "overloaded/server_error/unknown ignored" bash -c '[ "$(effective)" = max ]'

echo "# scenario 11: missing key file -> refuses to enter API mode"
mv "$CLAUDE_SWITCH_HOME/api_key" "$CLAUDE_SWITCH_HOME/api_key.bak"
sl 100 $((T0+300000+3600)) s7 0 >/dev/null
check "stays max without key"               bash -c '[ "$(effective)" = max ] && no_helper'
check "refusal logged"                      bash -c '"$CS" log | grep -q "REFUSED switch to api"'
mv "$CLAUDE_SWITCH_HOME/api_key.bak" "$CLAUDE_SWITCH_HOME/api_key"

echo "# uninstall"
"$CS" set-mode api >/dev/null
"$CS" uninstall >/dev/null
check "settings restored to unrelated keys only" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert set(d)=={"$schema","model","env"}, d' "$CLAUDE_SWITCH_SETTINGS"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
