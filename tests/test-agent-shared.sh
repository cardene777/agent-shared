#!/usr/bin/env bash
# Tests for agent-shared with a throwaway HOME for every scenario.
# A stand-in for `codex app-server` answers the trust calls and logs them, so no real agent settings
# are read or written. Only the uv check builds the package, into a throwaway tool folder.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
ROOT="$PKG"
REAL_HOME="$HOME"
PASS=0
FAIL=0
T="$(mktemp -d)"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
# PATH without any folder that holds a real `copilot` command, so only copilot_installed puts one there.
BASE_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r dir; do [ -x "$dir/copilot" ] || printf '%s:' "$dir"; done)"
BASE_PATH="${BASE_PATH%:}"

ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
ng() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [ -n "$why" ] && printf '      %s\n' "$why"; }
check() { why=""; if "$2"; then ok "$1"; else ng "$1"; fi; }

# The stand-in for `codex app-server`: lists the hooks in $CODEX_HOME/hooks.json and the hooks of the
# plugins installed under $CODEX_HOME/plugins/cache with a hash of each command, reports an empty trust
# state (or the one kept in $STUB_STATE), accepts every write, and logs each message to $STUB_LOG.
# `codex plugin marketplace add <folder>` and `codex plugin add <plugin>@<marketplace>` work on a
# throwaway marketplace folder (see plugin_market) and log their arguments to $STUB_LOG.
mkdir -p "$T/bin"
cat > "$T/bin/codex" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
import shutil
import sys
import tomllib

home = os.environ["CODEX_HOME"]
log = os.environ.get("STUB_LOG")
state_file = os.environ.get("STUB_STATE")
config = os.path.join(home, "config.toml")


def append_config(text):
    with open(config, "a") as handle:
        handle.write(text)


if sys.argv[1:2] == ["plugin"]:
    if log:
        with open(log, "a") as handle:
            handle.write(json.dumps({"argv": sys.argv[1:]}) + "\n")
    args = sys.argv[2:]
    if args[:2] == ["marketplace", "add"] and len(args) == 3:
        name = open(os.path.join(args[2], "name")).read().strip()
        append_config('\n[marketplaces.%s]\nsource_type = "local"\nsource = "%s"\n' % (name, args[2]))
        sys.exit(0)
    if args[:1] == ["add"] and len(args) == 2 and "@" in args[1]:
        plugin, market = args[1].split("@", 1)
        data = tomllib.load(open(config, "rb")) if os.path.exists(config) else {}
        source = ((data.get("marketplaces") or {}).get(market) or {}).get("source")
        if not source:
            print("marketplace %s is not configured" % market, file=sys.stderr)
            sys.exit(1)
        shutil.copytree(os.path.join(source, "plugins", plugin),
                        os.path.join(home, "plugins", "cache", market, plugin, "1.0.0"))
        append_config('\n[plugins."%s"]\nenabled = true\n' % args[1])
        sys.exit(0)
    sys.exit(2)
if sys.argv[1:] != ["app-server"]:
    sys.exit(2)


def reply(request_id, result):
    sys.stdout.write(json.dumps({"id": request_id, "result": result}) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    message = json.loads(line)
    if log:
        with open(log, "a") as handle:
            handle.write(json.dumps(message) + "\n")
    method, request_id = message.get("method"), message.get("id")
    if request_id is None:
        continue
    if method == "hooks/list":
        place = os.path.join(home, "hooks.json")
        data = json.load(open(place)) if os.path.exists(place) else {}
        hooks = []
        for event, groups in (data.get("hooks") or {}).items():
            for group_index, group in enumerate(groups):
                for hook_index, hook in enumerate(group.get("hooks") or []):
                    command = hook.get("command", "")
                    hooks.append({
                        "source": "user", "sourcePath": place, "command": command,
                        "key": "%s:%s:%d:%d" % (place, event, group_index, hook_index),
                        "currentHash": "sha256:" + hashlib.sha256(command.encode()).hexdigest(),
                    })
        cache = os.path.join(home, "plugins", "cache")
        for market in sorted(os.listdir(cache)) if os.path.isdir(cache) else []:
            for plugin in sorted(os.listdir(os.path.join(cache, market))):
                for version in sorted(os.listdir(os.path.join(cache, market, plugin))):
                    place = os.path.join(cache, market, plugin, version, "hooks", "hooks.json")
                    if not os.path.exists(place):
                        continue
                    plugin_id = "%s@%s" % (plugin, market)
                    for event, groups in (json.load(open(place)).get("hooks") or {}).items():
                        for group_index, group in enumerate(groups):
                            for hook_index, hook in enumerate(group.get("hooks") or []):
                                command = hook.get("command", "")
                                hooks.append({
                                    "source": "plugin", "pluginId": plugin_id, "sourcePath": place, "command": command,
                                    "key": "%s:hooks/hooks.json:%s:%d:%d" % (plugin_id, event, group_index, hook_index),
                                    "currentHash": "sha256:" + hashlib.sha256(command.encode()).hexdigest(),
                                })
        reply(request_id, {"data": [{"hooks": hooks}]})
    elif method == "config/read":
        state = json.load(open(state_file)) if state_file and os.path.exists(state_file) else {}
        reply(request_id, {"layers": [{"name": {"type": "user"}, "config": {"hooks": {"state": state}}, "version": "v1"}]})
    elif method == "config/batchWrite":
        if state_file:
            json.dump(message["params"]["edits"][0]["value"], open(state_file, "w"))
        reply(request_id, {"status": "ok"})
    else:
        reply(request_id, {})
PY
chmod +x "$T/bin/codex"

# A new throwaway HOME with two skills, two rules, and two hooks in ~/.shared, and settings that already
# hold the user's own entries.
fresh() {
  export PATH="$BASE_PATH"
  rm -rf "$T/version-bin"
  export HOME="$T/home-$1"
  export AGENT_SHARED_CODEX_BIN="$T/bin/codex"
  export STUB_LOG="$HOME/codex-calls.jsonl"
  unset AGENT_SHARED_STATE STUB_STATE MARKET
  RUN_DIR="$HOME"
  mkdir -p "$HOME/.shared/skills/alpha" "$HOME/.shared/skills/beta" "$HOME/.shared/rules" "$HOME/.claude" "$HOME/.codex"
  printf -- '---\nname: alpha\ndescription: Alpha.\n---\nAlpha.\n' > "$HOME/.shared/skills/alpha/SKILL.md"
  printf -- '---\nname: beta\ndescription: Beta.\n---\nBeta.\n' > "$HOME/.shared/skills/beta/SKILL.md"
  printf '# One\nRule one.\n' > "$HOME/.shared/rules/one.md"
  printf '# Two\nRule two.\n' > "$HOME/.shared/rules/two.md"
  cat > "$HOME/.shared/hooks.json" <<'JSON'
{"hooks": {
  "PreToolUse": [
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"}]},
    {"matcher": "Edit", "hooks": [{"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"}]}
  ],
  "Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}]
}}
JSON
  cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "permissions": {"allow": ["Bash(ls)"]},
  "hooks": {"PreToolUse": [{"matcher": "Read", "hooks": [{"type": "command", "command": "echo mine"}]}]}
}
JSON
  printf '# My notes\n\nKeep this line.\n' > "$HOME/.codex/AGENTS.md"
  cat > "$HOME/.codex/hooks.json" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo my-codex-hook"}]}]}}
JSON
}

# Puts a stand-in `copilot` command on PATH, so the Copilot CLI row is written. fresh takes it off again.
copilot_installed() {
  mkdir -p "$T/copilot-bin"
  printf '#!/bin/sh\nexit 0\n' > "$T/copilot-bin/copilot"
  chmod +x "$T/copilot-bin/copilot"
  export PATH="$T/copilot-bin:$BASE_PATH"
}

# Puts a stand-in for the agent command $1 first on PATH, printing $2 when asked for its version, or nothing when
# $2 is empty. fresh takes it off again.
agent_version() {
  mkdir -p "$T/version-bin"
  if [ -n "$2" ]; then
    printf '#!/bin/sh\necho "%s"\n' "$2" > "$T/version-bin/$1"
  else
    printf '#!/bin/sh\nexit 0\n' > "$T/version-bin/$1"
  fi
  chmod +x "$T/version-bin/$1"
  case ":$PATH:" in *":$T/version-bin:"*) ;; *) export PATH="$T/version-bin:$PATH" ;; esac
}

# Runs agent-shared from the package source in $RUN_DIR. Output goes to $T/out, the exit code to $rc.
run() {
  (cd "$RUN_DIR" && PYTHONPATH="$PKG/src" python3 -m agent_shared "$@") > "$T/out" 2>&1
  rc=$?
}

# True when $1 is a link that resolves to the folder or file $2.
real() { python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
links_to() { [ -L "$1" ] && [ -e "$1" ] && [ "$(real "$1")" = "$(real "$2")" ]; }
deployed() { run deploy; [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }; }
mode() { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$1"; }

uv_installs() {
  command -v uv > /dev/null || { why="uv is not installed"; return 1; }
  HOME="$REAL_HOME" UV_TOOL_DIR="$T/uv/tools" UV_TOOL_BIN_DIR="$T/uv/bin" uv tool install --quiet "$PKG" > "$T/uv.out" 2>&1 \
    || { why="uv tool install failed: $(tail -1 "$T/uv.out")"; return 1; }
  [ -x "$T/uv/bin/agent-shared" ] || { why="no agent-shared command in the tool bin folder"; return 1; }
  [ -z "$(find "$T/uv/tools" -name SKILL.md -print -quit)" ] || { why="a SKILL.md was installed with the command"; return 1; }
  HOME="$REAL_HOME" "$T/uv/bin/agent-shared" --help > /dev/null 2>&1 || { why="agent-shared --help failed"; return 1; }
}

links_skills() {
  fresh links
  deployed || return 1
  local skill place
  for skill in alpha beta; do
    for place in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
      links_to "$place/$skill" "$HOME/.shared/skills/$skill" || { why="$place/$skill is not a link to the shared copy"; return 1; }
    done
  done
}

no_codex_skills() {
  fresh codexskills
  deployed || return 1
  [ -L "$HOME/.agents/skills/alpha" ] || { why="the shared agent folder got no skill"; return 1; }
  [ ! -e "$HOME/.codex/skills" ] || { why="something was placed in ~/.codex/skills"; return 1; }
}

writes_rules() {
  fresh rules
  local before="$T/agents-before.md"
  cp "$HOME/.codex/AGENTS.md" "$before"
  deployed || return 1
  links_to "$HOME/.claude/rules/one.md" "$HOME/.shared/rules/one.md" || { why="~/.claude/rules/one.md is not a link to the rule"; return 1; }
  links_to "$HOME/.claude/rules/two.md" "$HOME/.shared/rules/two.md" || { why="~/.claude/rules/two.md is not a link to the rule"; return 1; }
  python3 - "$before" "$HOME/.codex/AGENTS.md" <<'PY' || { why="$(cat "$before.why" 2>/dev/null)"; return 1; }
import sys
before = open(sys.argv[1]).read()
after = open(sys.argv[2]).read()
lines = after.splitlines(keepends=True)
begins = [i for i, line in enumerate(lines) if line.startswith("<!-- agent-shared begin")]
ends = [i for i, line in enumerate(lines) if line.startswith("<!-- agent-shared end")]
problem = None
if len(begins) != 1 or len(ends) != 1 or begins[0] > ends[0]:
    problem = "AGENTS.md does not have exactly one block"
elif "".join(lines[:begins[0]]) + "".join(lines[ends[0] + 1:]) != before:
    problem = "the lines outside the block changed"
elif "Rule one." not in after or "Rule two." not in after:
    problem = "the block does not hold both rules"
if problem:
    open(sys.argv[1] + ".why", "w").write(problem)
    sys.exit(1)
PY
}

adds_hooks() {
  fresh hooks
  deployed || return 1
  python3 - "$HOME" <<'PY' || { why="$(cat "$T/hooks.why" 2>/dev/null)"; return 1; }
import json, os, sys
home = sys.argv[1]
def commands(path, event):
    data = json.load(open(path))
    return [hook["command"] for group in data.get("hooks", {}).get(event, []) for hook in group.get("hooks", [])]
def marked(command):
    return "\n" in command and command.rsplit("\n", 1)[1].startswith("# agent-shared")
problem = None
settings = json.load(open(os.path.join(home, ".claude/settings.json")))
guard = "bash %s/.shared/hooks/guard.sh" % home
for path in (os.path.join(home, ".claude/settings.json"), os.path.join(home, ".codex/hooks.json")):
    pre = commands(path, "PreToolUse")
    stop = commands(path, "Stop")
    if sum(1 for c in pre if marked(c) and c.startswith(guard)) != 2:
        problem = "%s does not have the guard hook once for each of its two matchers, with the source folder filled in" % path
    elif not any(marked(c) and c.startswith("echo stop") for c in stop):
        problem = "%s has no marked stop hook" % path
if problem is None and (settings.get("model") != "opus" or settings.get("permissions") != {"allow": ["Bash(ls)"]}):
    problem = "settings outside hooks changed"
if problem is None and "echo mine" not in commands(os.path.join(home, ".claude/settings.json"), "PreToolUse"):
    problem = "the hand-written hook is gone"
if problem:
    open(os.environ["T"] + "/hooks.why", "w").write(problem)
    sys.exit(1)
PY
}

trusts_codex_hooks() {
  fresh trust
  deployed || return 1
  python3 - "$HOME" <<'PY' || { why="$(cat "$T/trust.why" 2>/dev/null)"; return 1; }
import json, os, sys
home = sys.argv[1]
problem = None
log = os.path.join(home, "codex-calls.jsonl")
writes = [json.loads(l) for l in open(log)] if os.path.exists(log) else []
writes = [m for m in writes if m.get("method") == "config/batchWrite"]
if not writes:
    problem = "agent-shared never asked Codex to write the trust state"
else:
    value = writes[-1]["params"]["edits"][0]["value"]
    data = json.load(open(os.path.join(home, ".codex/hooks.json")))
    place = os.path.join(home, ".codex/hooks.json")
    marked, hand = set(), set()
    for event, groups in data["hooks"].items():
        for gi, group in enumerate(groups):
            for hi, hook in enumerate(group["hooks"]):
                key = "%s:%s:%d:%d" % (place, event, gi, hi)
                c = hook["command"]
                (marked if "\n" in c and c.rsplit("\n", 1)[1].startswith("# agent-shared") else hand).add(key)
    trusted = {k for k, v in value.items() if isinstance(v, dict) and v.get("trusted_hash")}
    if trusted != marked:
        problem = "trusted keys %s, placed hooks %s" % (sorted(trusted), sorted(marked))
if problem:
    open(os.path.join(os.environ["T"], "trust.why"), "w").write(problem)
    sys.exit(1)
PY
}

without_codex() {
  fresh nocodex
  export AGENT_SHARED_CODEX_BIN="$T/bin/no-such-codex"
  deployed || return 1
  grep -q '/hooks' "$T/out" || { why="the run did not say how to trust the hooks in Codex"; return 1; }
  [ -L "$HOME/.claude/skills/alpha" ] || { why="the other agents were not deployed"; return 1; }
}

# A throwaway marketplace named `market` for the stand-in codex, with the plugins guard-one (two hooks)
# and other (one hook). The stand-in keeps Codex's trust state in $STUB_STATE.
plugin_market() {
  MARKET="$T/market-$1"
  mkdir -p "$MARKET/plugins/guard-one/hooks" "$MARKET/plugins/other/hooks"
  printf 'market\n' > "$MARKET/name"
  cat > "$MARKET/plugins/guard-one/hooks/hooks.json" <<'JSON'
{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash guard-a.sh"}, {"type": "command", "command": "bash guard-b.sh"}]}]}}
JSON
  cat > "$MARKET/plugins/other/hooks/hooks.json" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "bash other.sh"}]}]}}
JSON
  export STUB_STATE="$HOME/codex-state.json"
}

# Writes plugins.json into the folder $1, naming the plugins after it from the marketplace above.
plugins_json() {
  local folder="$1"
  shift
  python3 - "$folder/plugins.json" "$MARKET" "$@" <<'PY'
import json, sys
path, market, plugins = sys.argv[1], sys.argv[2], sys.argv[3:]
json.dump({"codex": {"marketplaces": {"market": market}, "plugins": plugins}}, open(path, "w"))
PY
}

# Registers the marketplace in the throwaway Codex, as `codex plugin marketplace add` does.
market_registered() {
  printf '\n[marketplaces.market]\nsource_type = "local"\nsource = "%s"\n' "$MARKET" >> "$HOME/.codex/config.toml"
}

# Installs the plugin $1 of the marketplace in the throwaway Codex without agent-shared.
plugin_installed() {
  mkdir -p "$HOME/.codex/plugins/cache/market/$1"
  cp -R "$MARKET/plugins/$1" "$HOME/.codex/plugins/cache/market/$1/1.0.0"
  printf '\n[plugins."%s@market"]\nenabled = true\n' "$1" >> "$HOME/.codex/config.toml"
}

# The trusted hashes the stand-in keeps for the hooks of the plugin $1, as sorted "key hash" lines.
trusted_of() {
  python3 - "${STUB_STATE:-}" "$1@market" <<'PY' | LC_ALL=C sort
import json, os, sys
path, plugin = sys.argv[1:]
state = json.load(open(path)) if path and os.path.exists(path) else {}
for key, entry in state.items():
    if key.startswith(plugin + ":") and isinstance(entry, dict) and entry.get("trusted_hash"):
        print(key, entry["trusted_hash"])
PY
}

# The current hashes of the hooks of the installed plugin $1, as sorted "key hash" lines.
current_of() {
  python3 - "$HOME/.codex/plugins/cache/market/$1/1.0.0/hooks/hooks.json" "$1@market" <<'PY' | LC_ALL=C sort
import hashlib, json, sys
path, plugin = sys.argv[1:]
for event, groups in json.load(open(path))["hooks"].items():
    for gi, group in enumerate(groups):
        for hi, hook in enumerate(group["hooks"]):
            print("%s:hooks/hooks.json:%s:%d:%d sha256:%s" % (plugin, event, gi, hi, hashlib.sha256(hook["command"].encode()).hexdigest()))
PY
}

# True when the stand-in codex was run with exactly the arguments given.
codex_ran() {
  python3 - "$STUB_LOG" "$@" <<'PY'
import json, os, sys
log, wanted = sys.argv[1], sys.argv[2:]
lines = [json.loads(l) for l in open(log)] if os.path.exists(log) else []
sys.exit(0 if any(m.get("argv") == wanted for m in lines) else 1)
PY
}

installs_named_plugins() {
  fresh plugin-install
  plugin_market install
  market_registered
  plugins_json "$HOME/.shared" guard-one@market
  deployed || return 1
  codex_ran plugin add guard-one@market || { why="deploy did not run codex plugin add guard-one@market"; return 1; }
  [ -d "$HOME/.codex/plugins/cache/market/guard-one" ] || { why="guard-one is not installed in Codex"; return 1; }
  [ ! -e "$HOME/.codex/plugins/cache/market/other" ] || { why="other was installed although plugins.json does not name it"; return 1; }
}

registers_missing_market() {
  fresh plugin-market
  plugin_market register
  plugins_json "$HOME/.shared" guard-one@market
  deployed || return 1
  codex_ran plugin marketplace add "$MARKET" || { why="deploy did not register the marketplace from plugins.json"; return 1; }
  python3 - "$STUB_LOG" <<'PY' || { why="the plugin was installed before its marketplace was registered"; return 1; }
import json, sys
argvs = [json.loads(l).get("argv") for l in open(sys.argv[1])]
argvs = [a for a in argvs if a]
first_market = next(i for i, a in enumerate(argvs) if a[:3] == ["plugin", "marketplace", "add"])
first_add = next(i for i, a in enumerate(argvs) if a[:2] == ["plugin", "add"])
sys.exit(0 if first_market < first_add else 1)
PY
  [ -d "$HOME/.codex/plugins/cache/market/guard-one" ] || { why="guard-one is not installed in Codex"; return 1; }
}

trusts_named_plugin_hooks() {
  fresh plugin-trust
  plugin_market trust
  market_registered
  plugin_installed guard-one
  plugins_json "$HOME/.shared" guard-one@market
  deployed || return 1
  local trusted current
  trusted="$(trusted_of guard-one)"
  current="$(current_of guard-one)"
  [ -n "$trusted" ] && [ "$trusted" = "$current" ] || { why="trusted [$trusted], current [$current]"; return 1; }
}

retrusts_changed_hook() {
  fresh plugin-retrust
  plugin_market retrust
  market_registered
  plugin_installed guard-one
  plugins_json "$HOME/.shared" guard-one@market
  deployed || return 1
  local cached="$HOME/.codex/plugins/cache/market/guard-one/1.0.0/hooks/hooks.json"
  python3 - "$cached" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["hooks"]["PreToolUse"][0]["hooks"][0]["command"] = "bash guard-a-updated.sh"
json.dump(data, open(path, "w"))
PY
  deployed || return 1
  local trusted current
  trusted="$(trusted_of guard-one)"
  current="$(current_of guard-one)"
  [ -n "$trusted" ] && [ "$trusted" = "$current" ] || { why="after the update, trusted [$trusted], current [$current]"; return 1; }
}

keeps_taken_off() {
  fresh plugin-off
  plugin_market off
  market_registered
  plugins_json "$HOME/.shared" guard-one@market
  deployed || return 1
  local before
  before="$(trusted_of guard-one)"
  [ -n "$before" ] || { why="the first deploy trusted no hook of guard-one"; return 1; }
  plugins_json "$HOME/.shared"
  deployed || return 1
  [ -d "$HOME/.codex/plugins/cache/market/guard-one" ] || { why="guard-one was removed from Codex"; return 1; }
  [ "$(trusted_of guard-one)" = "$before" ] || { why="the trust of guard-one changed after it left the list"; return 1; }
  ! grep -qF '"remove"' "$STUB_LOG" || { why="deploy ran codex plugin remove"; return 1; }
}

# A plugins.json in a repository's .shared and in a --source folder is not read, and each is named.
outside_plugins_not_read() {
  fresh plugin-outside
  plugin_market outside
  market_registered
  local repo="$T/repo-plugins" extra="$T/extra-plugins"
  mkdir -p "$repo/.shared/skills/delta" "$extra/skills/epsilon"
  git -C "$repo" init -q
  printf -- '---\nname: delta\ndescription: Delta.\n---\nDelta.\n' > "$repo/.shared/skills/delta/SKILL.md"
  printf -- '---\nname: epsilon\ndescription: Epsilon.\n---\nEpsilon.\n' > "$extra/skills/epsilon/SKILL.md"
  plugins_json "$repo/.shared" guard-one@market
  plugins_json "$extra" guard-one@market
  RUN_DIR="$repo"
  deployed || return 1
  grep -qF "$repo/.shared/plugins.json" "$T/out" || { why="the run did not name the repository's plugins.json"; return 1; }
  RUN_DIR="$HOME"
  run deploy --source "$extra"
  [ "$rc" = 0 ] || { why="deploy --source exited $rc: $(tail -1 "$T/out")"; return 1; }
  grep -qF "$extra/plugins.json" "$T/out" || { why="the run did not name the --source folder's plugins.json"; return 1; }
  [ ! -e "$HOME/.codex/plugins/cache/market/guard-one" ] || { why="guard-one was installed from a plugins.json outside ~/.shared"; return 1; }
  [ -z "$(trusted_of guard-one)" ] || { why="guard-one's hooks were trusted from a plugins.json outside ~/.shared"; return 1; }
}

without_codex_names_plugins() {
  fresh plugin-nocodex
  plugin_market nocodex
  plugins_json "$HOME/.shared" guard-one@market
  export AGENT_SHARED_CODEX_BIN="$T/bin/no-such-codex"
  deployed || return 1
  grep -F 'guard-one@market' "$T/out" | grep -qF '/hooks' || { why="the run did not name guard-one@market with how to trust it"; return 1; }
  [ -L "$HOME/.claude/skills/alpha" ] || { why="the other agents were not deployed"; return 1; }
}

# Each wrong plugins.json sits in a source of its own, so each refusal is seen.
check_refuses_plugins() {
  fresh check-plugins
  local bad="$T/bad-plugins"
  mkdir -p "$bad/list" "$bad/at" "$bad/url"
  printf '[]\n' > "$bad/list/plugins.json"
  printf '{"codex": {"marketplaces": {"market": "%s"}, "plugins": ["guard-one"]}}\n' "$T/market" > "$bad/at/plugins.json"
  printf '{"codex": {"marketplaces": {"market": ""}, "plugins": ["guard-one@market"]}}\n' > "$bad/url/plugins.json"
  check_run --source "$bad/list"
  [ "$rc" = 1 ] && grep -qF 'plugins.json' "$T/check.out" \
    || { why="a list that is not an object: check exited $rc: $(tail -1 "$T/check.out")"; return 1; }
  check_run --source "$bad/at"
  [ "$rc" = 1 ] && grep 'plugins.json' "$T/check.out" | grep -qF 'guard-one' \
    || { why="a plugin without @: check exited $rc: $(tail -1 "$T/check.out")"; return 1; }
  check_run --source "$bad/url"
  [ "$rc" = 1 ] && grep 'plugins.json' "$T/check.out" | grep -qF 'market' \
    || { why="a marketplace without a git URL: check exited $rc: $(tail -1 "$T/check.out")"; return 1; }
}

# The trust a deploy finds for a plugin plugins.json does not name stays as it was.
leaves_unnamed_plugins() {
  fresh plugin-unnamed
  plugin_market unnamed
  market_registered
  plugin_installed other
  printf '{"other@market:hooks/hooks.json:Stop:0:0": {"trusted_hash": "sha256:seeded"}}\n' > "$STUB_STATE"
  plugins_json "$HOME/.shared" guard-one@market
  deployed || return 1
  [ "$(trusted_of other)" = "other@market:hooks/hooks.json:Stop:0:0 sha256:seeded" ] \
    || { why="the trust of other changed: [$(trusted_of other)]"; return 1; }
}

definition_plugins_json() {
  local f
  for f in README.md README.ja.md spec/agent-shared.md spec/agent-shared.ja.md; do
    grep -qF '~/.shared/plugins.json' "$ROOT/$f" || { why="$f does not name ~/.shared/plugins.json"; return 1; }
    grep -qF 'codex plugin remove' "$ROOT/$f" || { why="$f does not say how a plugin taken off the list is removed"; return 1; }
  done
}

repo_skills() {
  fresh repo
  local repo="$T/repo"
  mkdir -p "$repo/.shared/skills/gamma"
  git -C "$repo" init -q
  printf -- '---\nname: gamma\ndescription: Gamma.\n---\nGamma.\n' > "$repo/.shared/skills/gamma/SKILL.md"
  RUN_DIR="$repo"
  deployed || return 1
  links_to "$repo/.claude/skills/gamma" "$repo/.shared/skills/gamma" || { why="the repository's .claude/skills/gamma is not a link to its skill"; return 1; }
  links_to "$repo/.agents/skills/gamma" "$repo/.shared/skills/gamma" || { why="the repository's .agents/skills/gamma is not a link to its skill"; return 1; }
}

removes_taken_out() {
  fresh remove
  deployed || return 1
  rm -rf "$HOME/.shared/skills/beta" "$HOME/.shared/rules/two.md"
  cat > "$HOME/.shared/hooks.json" <<'JSON'
{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"}]}]}}
JSON
  deployed || return 1
  [ ! -e "$HOME/.claude/skills/beta" ] && [ ! -L "$HOME/.claude/skills/beta" ] || { why="beta is still in ~/.claude/skills"; return 1; }
  [ ! -L "$HOME/.agents/skills/beta" ] || { why="beta is still in ~/.agents/skills"; return 1; }
  [ ! -L "$HOME/.claude/rules/two.md" ] || { why="rule two is still in ~/.claude/rules"; return 1; }
  ! grep -q 'Rule two.' "$HOME/.codex/AGENTS.md" || { why="rule two is still in AGENTS.md"; return 1; }
  ! grep -q 'echo stop' "$HOME/.claude/settings.json" || { why="the stop hook is still in settings.json"; return 1; }
  [ -L "$HOME/.claude/skills/alpha" ] && [ -L "$HOME/.claude/rules/one.md" ] && grep -q 'guard.sh' "$HOME/.claude/settings.json" \
    || { why="an item that stayed in the source was removed"; return 1; }
}

leaves_unmarked() {
  fresh unmarked
  mkdir -p "$HOME/.claude/skills/mine"
  printf 'my own skill\n' > "$HOME/.claude/skills/mine/SKILL.md"
  cp "$HOME/.claude/skills/mine/SKILL.md" "$T/mine-before"
  cp "$HOME/.codex/AGENTS.md" "$T/agents-unmarked-before"
  deployed || return 1
  [ -L "$HOME/.claude/skills/alpha" ] || { why="the run placed nothing"; return 1; }
  cmp -s "$HOME/.claude/skills/mine/SKILL.md" "$T/mine-before" || { why="the hand-made skill changed"; return 1; }
  head -c "$(wc -c < "$T/agents-unmarked-before")" "$HOME/.codex/AGENTS.md" | cmp -s - "$T/agents-unmarked-before" \
    || { why="the lines of AGENTS.md before the block changed"; return 1; }
  python3 - "$HOME" <<'PY' || { why="a hand-written hook changed or moved"; return 1; }
import json, os, sys
home = sys.argv[1]
s = json.load(open(os.path.join(home, ".claude/settings.json")))
c = json.load(open(os.path.join(home, ".codex/hooks.json")))
mine = [g for g in s["hooks"]["PreToolUse"] if g.get("matcher") == "Read"]
codex = [h for g in c["hooks"]["Stop"] for h in g["hooks"] if h["command"] == "echo my-codex-hook"]
sys.exit(0 if mine == [{"matcher": "Read", "hooks": [{"type": "command", "command": "echo mine"}]}] and len(codex) == 1 else 1)
PY
}

skips_plugin_skills() {
  fresh plugin
  local cache="$HOME/.claude/plugins/cache/market/kit/1.0.0"
  mkdir -p "$cache/skills/alpha"
  printf -- '---\nname: alpha\ndescription: Alpha from a plugin.\n---\n' > "$cache/skills/alpha/SKILL.md"
  printf '{"version": 2, "plugins": {"kit@market": [{"scope": "user", "installPath": "%s", "version": "1.0.0"}]}}\n' "$cache" \
    > "$HOME/.claude/plugins/installed_plugins.json"
  # A Codex plugin has beta. Copilot CLI reads ~/.agents/skills too, so its folder is there to show that
  # its row does not bring beta back into that folder.
  mkdir -p "$HOME/.codex/plugins/cache/market/tool/1.0.0/skills/beta" "$HOME/.copilot"
  copilot_installed
  printf -- '---\nname: beta\ndescription: Beta from a Codex plugin.\n---\n' > "$HOME/.codex/plugins/cache/market/tool/1.0.0/skills/beta/SKILL.md"
  printf '[plugins."tool@market"]\nenabled = true\n' > "$HOME/.codex/config.toml"
  deployed || return 1
  [ ! -e "$HOME/.claude/skills/alpha" ] && [ ! -L "$HOME/.claude/skills/alpha" ] || { why="alpha was placed for Claude Code although the plugin has it"; return 1; }
  [ -L "$HOME/.claude/skills/beta" ] || { why="beta was not placed for Claude Code"; return 1; }
  [ -L "$HOME/.agents/skills/alpha" ] || { why="alpha was not placed for the agents without the plugin"; return 1; }
  grep 'alpha' "$T/out" | grep -q 'kit@market' || { why="the run did not name the skill and the plugin"; return 1; }
  [ ! -e "$HOME/.agents/skills/beta" ] && [ ! -L "$HOME/.agents/skills/beta" ] || { why="beta was placed in ~/.agents/skills although the Codex plugin has it"; return 1; }
}

refuses_same_name() {
  fresh twosources
  mkdir -p "$T/extra/skills/alpha"
  printf -- '---\nname: alpha\ndescription: Another alpha.\n---\n' > "$T/extra/skills/alpha/SKILL.md"
  run deploy --source "$T/extra"
  [ "$rc" = 1 ] || { why="deploy exited $rc"; return 1; }
  grep -q "$T/extra" "$T/out" && grep -qE '~/\.shared|'"$HOME"'/\.shared' "$T/out" || { why="the run did not name both sources"; return 1; }
  [ ! -L "$HOME/.claude/skills/alpha" ] && [ ! -L "$HOME/.claude/skills/beta" ] && [ ! -L "$HOME/.agents/skills/beta" ] \
    || { why="the run placed skills although it refused"; return 1; }
}

refuses_hand_hook() {
  fresh handhook
  python3 - "$HOME/.claude/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["hooks"]["Stop"] = [{"hooks": [{"type": "command", "command": "echo stop"}]}]
open(path, "w").write(json.dumps(data, indent=2) + "\n")
PY
  cp "$HOME/.claude/settings.json" "$T/settings-before"
  run deploy
  [ "$rc" = 1 ] || { why="deploy exited $rc"; return 1; }
  cmp -s "$HOME/.claude/settings.json" "$T/settings-before" || { why="settings.json changed"; return 1; }
  grep -q 'echo stop' "$T/out" || { why="the run did not name the hook"; return 1; }
}

user_row() {
  fresh row
  printf '{"version": 1, "agents": [{"name": "tester", "skills": "~/.tester/skills"}]}\n' > "$HOME/.shared/agents.json"
  deployed || return 1
  links_to "$HOME/.tester/skills/alpha" "$HOME/.shared/skills/alpha" || { why="the added agent got no skill"; return 1; }
  [ -L "$HOME/.claude/skills/alpha" ] || { why="the default agents lost their skills"; return 1; }
}

private_record() {
  fresh record
  deployed || return 1
  local dir="$HOME/.local/share/agent-shared" file
  [ -d "$dir" ] || { why="no record folder at ~/.local/share/agent-shared"; return 1; }
  [ "$(mode "$dir")" = 0o700 ] || { why="the record folder has mode $(mode "$dir")"; return 1; }
  file="$(find "$dir" -type f -print -quit)"
  [ -n "$file" ] && [ "$(mode "$file")" = 0o600 ] || { why="no record file readable only by the user"; return 1; }
  fresh record-moved
  export AGENT_SHARED_STATE="$T/state"
  deployed || return 1
  [ -n "$(find "$T/state" -type f -print -quit 2>/dev/null)" ] || { why="AGENT_SHARED_STATE did not move the record"; return 1; }
}

export T
# Runs `agent-shared hooks` with stdout and stderr kept apart in $T/hooks.out and $T/hooks.err.
hooks_run() {
  (cd "$RUN_DIR" && PYTHONPATH="$PKG/src" python3 -m agent_shared hooks "$@") > "$T/hooks.out" 2> "$T/hooks.err"
  rc=$?
}

# Prints every path under $1 with its kind, link target, and content hash, to compare before and after.
snapshot() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
for here, dirs, files in os.walk(sys.argv[1]):
    dirs.sort()
    for name in sorted(dirs + files):
        path = os.path.join(here, name)
        if os.path.islink(path):
            print("link", path, os.readlink(path))
        elif os.path.isdir(path):
            print("dir", path)
        else:
            print("file", path, hashlib.sha256(open(path, "rb").read()).hexdigest())
PY
}

hooks_match_deploy() {
  fresh hooks-match
  hooks_run --agent "Claude Code"
  [ "$rc" = 0 ] || { why="hooks exited $rc: $(tail -1 "$T/hooks.err")"; return 1; }
  cp "$T/hooks.out" "$T/hooks-claude.json"
  deployed || return 1
  python3 - "$T/hooks-claude.json" "$HOME/.claude/settings.json" <<'PY' > "$T/compare.out" 2>&1 || { why="$(tail -1 "$T/compare.out")"; return 1; }
import json, sys
printed = json.load(open(sys.argv[1]))
settings = json.load(open(sys.argv[2]))
mark = "# agent-shared 1 source="
placed = {}
for event, groups in settings["hooks"].items():
    kept = [g for g in groups if all(h["command"].rsplit("\n", 1)[-1].startswith(mark) for h in g["hooks"])]
    if kept:
        placed[event] = kept
if not placed:
    sys.exit("deploy placed no marked hooks to compare with")
if printed.get("hooks") != placed:
    sys.exit("the printed hooks differ from the marked hooks deploy added")
PY
}

hooks_by_tools() {
  fresh hooks-tools
  cat > "$HOME/.shared/hooks.json" <<'JSON'
{"hooks": {
  "Stop": [
    {"hooks": [{"type": "command", "command": "echo stop"}]},
    {"hooks": [{"type": "command", "command": "echo claude-only", "tools": ["Claude Code"]}]}
  ]
}}
JSON
  hooks_run --agent Codex
  [ "$rc" = 0 ] || { why="hooks --agent Codex exited $rc: $(tail -1 "$T/hooks.err")"; return 1; }
  grep -q 'echo stop' "$T/hooks.out" || { why="the hook for every agent is missing for Codex"; return 1; }
  ! grep -q 'claude-only' "$T/hooks.out" || { why="a hook for Claude Code only was printed for Codex"; return 1; }
  hooks_run --agent "Claude Code"
  grep -q 'claude-only' "$T/hooks.out" || { why="the hook for Claude Code only is missing for Claude Code"; return 1; }
}

hooks_every_source() {
  fresh hooks-sources
  mkdir -p "$T/extra-source"
  printf '%s\n' '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo extra"}]}]}}' > "$T/extra-source/hooks.json"
  approve_source "$T/extra-source"
  hooks_run --agent "Claude Code" --source "$T/extra-source"
  [ "$rc" = 0 ] || { why="hooks exited $rc: $(tail -1 "$T/hooks.err")"; return 1; }
  grep -q 'echo extra' "$T/hooks.out" || { why="the hook of the --source folder was not printed"; return 1; }
  grep -q 'echo stop' "$T/hooks.out" || { why="the hook of ~/.shared was not printed"; return 1; }
}

hooks_write_nothing() {
  fresh hooks-quiet
  deployed || return 1
  snapshot "$HOME" > "$T/before.txt"
  hooks_run --agent "Claude Code"
  [ "$rc" = 0 ] || { why="hooks exited $rc: $(tail -1 "$T/hooks.err")"; return 1; }
  snapshot "$HOME" > "$T/after.txt"
  cmp -s "$T/before.txt" "$T/after.txt" || { why="hooks changed $(diff "$T/before.txt" "$T/after.txt" | sed -n 2p)"; return 1; }
}

hooks_unknown_agent() {
  fresh hooks-unknown
  hooks_run --agent Nobody
  [ "$rc" = 2 ] || { why="hooks --agent Nobody exited $rc"; return 1; }
  [ ! -s "$T/hooks.out" ] || { why="hooks printed something for an unknown agent"; return 1; }
  grep -q 'Nobody' "$T/hooks.err" || { why="the refusal does not name the agent: $(tail -1 "$T/hooks.err")"; return 1; }
}

hooks_need_agent() {
  fresh hooks-no-agent
  hooks_run
  [ "$rc" = 2 ] || { why="hooks without --agent exited $rc"; return 1; }
  grep -q -- '--agent' "$T/hooks.err" || { why="the refusal does not name --agent: $(tail -1 "$T/hooks.err")"; return 1; }
}

# Runs `agent-shared placed` with stdout and stderr kept apart in $T/placed.out and $T/placed.err.
placed_run() {
  (cd "$RUN_DIR" && PYTHONPATH="$PKG/src" python3 -m agent_shared placed "$@") > "$T/placed.out" 2> "$T/placed.err"
  rc=$?
}
placed_ok() {
  placed_run "$@"
  [ "$rc" = 0 ] || { why="placed exited $rc: $(tail -1 "$T/placed.err")"; return 1; }
}

# A second source in $T/source-$1, deployed with ~/.shared: two skills, one rule, the same hook command
# under two matchers with ${CLAUDE_PLUGIN_ROOT}, a Stop hook without a matcher, and a hook for Claude
# Code only. $SRC names the folder.
full_source() {
  SRC="$T/source-$1"
  mkdir -p "$SRC/skills/delta" "$SRC/skills/epsilon" "$SRC/rules"
  printf -- '---\nname: delta\ndescription: Delta.\n---\nDelta.\n' > "$SRC/skills/delta/SKILL.md"
  printf -- '---\nname: epsilon\ndescription: Epsilon.\n---\nEpsilon.\n' > "$SRC/skills/epsilon/SKILL.md"
  printf '# Three\nRule three.\n' > "$SRC/rules/three.md"
  cat > "$SRC/hooks.json" <<'JSON'
{"hooks": {
  "PreToolUse": [
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/check.sh"}]},
    {"matcher": "Edit", "hooks": [{"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/check.sh", "timeout": 5}]}
  ],
  "Stop": [
    {"hooks": [{"type": "command", "command": "echo source-stop"}]},
    {"hooks": [{"type": "command", "command": "echo claude-only", "tools": ["Claude Code"]}]}
  ]
}}
JSON
  # A source other than ~/.shared gets its hooks placed only once the person approves it.
  [ -n "${NO_APPROVE:-}" ] || approve_source "$SRC"
}

# Approves the source folder $1, answering yes. Output goes to $T/approve.out, the exit code to $rc.
approve_source() {
  printf 'y\n' | (cd "$RUN_DIR" && PYTHONPATH="$PKG/src" python3 -m agent_shared approve --source "$1") > "$T/approve.out" 2>&1
  rc=$?
}

# Reads $T/placed.out and runs the Python check on stdin with `out` (the JSON, keys in order), `src`,
# and `home` defined. The check calls fail(<reason>) when it does not hold.
placed_holds() {
  python3 - "$T/placed.out" "${SRC:-}" "$HOME" "$T/placed.why" 3<&0 <<'PY' || { why="$(cat "$T/placed.why" 2>/dev/null)"; return 1; }
import json, os, sys
path, src, home, why = sys.argv[1:]
def fail(reason):
    open(why, "w").write(reason)
    sys.exit(1)
try:
    out = json.load(open(path), object_pairs_hook=lambda pairs: dict(pairs))
except ValueError as error:
    fail("placed did not print JSON (%s)" % error)
exec(os.fdopen(3).read())
PY
}

placed_lists() {
  fresh placed-lists
  full_source lists
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  placed_ok --source "$SRC" || return 1
  placed_holds <<'PY'
if out.get("source") != src:
    fail("source is %r, not the folder passed" % out.get("source"))
agents = out.get("agents") or {}
for name, hooks in (("Claude Code", 4), ("Codex", 3)):
    agent = agents.get(name)
    if not isinstance(agent, dict):
        fail("%s is missing from agents" % name)
    if agent.get("skills") != ["delta", "epsilon"]:
        fail("%s skills are %r" % (name, agent.get("skills")))
    if agent.get("rules") != ["three.md"]:
        fail("%s rules are %r" % (name, agent.get("rules")))
    if len(agent.get("hooks") or []) != hooks:
        fail("%s has %d hooks, not the %d the source declared for it" % (name, len(agent.get("hooks") or []), hooks))
PY
}

placed_hook_shape() {
  fresh placed-hooks
  full_source hooks
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  placed_ok --source "$SRC" || return 1
  placed_holds <<'PY'
check = "bash %s/hooks/check.sh" % src
want = {
    "Claude Code": [
        {"event": "PreToolUse", "matcher": "Bash", "command": check},
        {"event": "PreToolUse", "matcher": "Edit", "command": check},
        {"event": "Stop", "command": "echo source-stop"},
        {"event": "Stop", "command": "echo claude-only"},
    ],
    "Codex": [
        {"event": "PreToolUse", "matcher": "Bash", "command": check},
        {"event": "PreToolUse", "matcher": "Edit", "command": check},
        {"event": "Stop", "command": "echo source-stop"},
    ],
}
key = lambda hook: json.dumps(hook, sort_keys=True)
for name, hooks in want.items():
    got = (out.get("agents") or {}).get(name, {}).get("hooks")
    if not isinstance(got, list) or sorted(got, key=key) != sorted(hooks, key=key):
        fail("%s hooks are %r" % (name, got))
PY
}

placed_other_source() {
  fresh placed-other
  # The shape of an app's own folder: skills only, an empty rules folder, and no hooks.
  SRC="$T/source-other"
  mkdir -p "$SRC/skills/gamma" "$SRC/rules"
  printf -- '---\nname: gamma\ndescription: Gamma.\n---\nGamma.\n' > "$SRC/skills/gamma/SKILL.md"
  printf '{"hooks": {}}\n' > "$SRC/hooks.json"
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  [ -L "$HOME/.claude/skills/alpha" ] || { why="deploy did not place ~/.shared's skills to leave out"; return 1; }
  placed_ok --source "$SRC" || return 1
  placed_holds <<'PY'
for name in ("Claude Code", "Codex"):
    agent = (out.get("agents") or {}).get(name)
    if agent != {"skills": ["gamma"], "rules": [], "hooks": []}:
        fail("%s is %r, with something ~/.shared placed or without gamma" % (name, agent))
PY
}

placed_plugin_skill() {
  fresh placed-plugin
  full_source plugin
  local cache="$HOME/.claude/plugins/cache/market/kit/1.0.0"
  mkdir -p "$cache/skills/delta"
  printf -- '---\nname: delta\ndescription: Delta from a plugin.\n---\n' > "$cache/skills/delta/SKILL.md"
  printf '{"version": 2, "plugins": {"kit@market": [{"scope": "user", "installPath": "%s", "version": "1.0.0"}]}}\n' "$cache" \
    > "$HOME/.claude/plugins/installed_plugins.json"
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  placed_ok --source "$SRC" || return 1
  placed_holds <<'PY'
agents = out.get("agents") or {}
if (agents.get("Claude Code") or {}).get("skills") != ["epsilon"]:
    fail("Claude Code skills are %r, though its plugin has delta" % (agents.get("Claude Code") or {}).get("skills"))
if (agents.get("Codex") or {}).get("skills") != ["delta", "epsilon"]:
    fail("Codex skills are %r, though delta was placed for it" % (agents.get("Codex") or {}).get("skills"))
PY
}

placed_marked_only() {
  fresh placed-marked
  full_source marked
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  # The user removes one link, points another somewhere else, and adds a skill and a hook by hand.
  rm "$HOME/.claude/skills/delta"
  rm "$HOME/.agents/skills/epsilon"
  ln -s "$T" "$HOME/.agents/skills/epsilon"
  mkdir -p "$HOME/.claude/skills/mine"
  printf 'my own skill\n' > "$HOME/.claude/skills/mine/SKILL.md"
  python3 - "$HOME/.codex/hooks.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["hooks"]["Stop"].append({"hooks": [{"type": "command", "command": "echo source-stop-by-hand"}]})
open(path, "w").write(json.dumps(data, indent=2) + "\n")
PY
  placed_ok --source "$SRC" || return 1
  placed_holds <<'PY'
agents = out.get("agents") or {}
if (agents.get("Claude Code") or {}).get("skills") != ["epsilon"]:
    fail("Claude Code skills are %r, with the removed link or the hand-made skill" % (agents.get("Claude Code") or {}).get("skills"))
if (agents.get("Codex") or {}).get("skills") != ["delta"]:
    fail("Codex skills are %r, with the link that now points elsewhere" % (agents.get("Codex") or {}).get("skills"))
commands = [h.get("command") for a in agents.values() for h in a.get("hooks") or []]
for mine in ("echo mine", "echo my-codex-hook", "echo source-stop-by-hand"):
    if mine in commands:
        fail("the hook %r without the mark was listed" % mine)
PY
}

placed_write_nothing() {
  fresh placed-quiet
  full_source quiet
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  { snapshot "$HOME"; snapshot "$SRC"; } > "$T/before.txt"
  placed_ok --source "$SRC" || return 1
  { snapshot "$HOME"; snapshot "$SRC"; } > "$T/after.txt"
  cmp -s "$T/before.txt" "$T/after.txt" || { why="placed changed $(diff "$T/before.txt" "$T/after.txt" | sed -n 2p)"; return 1; }
}

placed_never_deployed() {
  fresh placed-never
  SRC="$T/source-never"
  mkdir -p "$SRC/skills/zeta"
  printf -- '---\nname: zeta\ndescription: Zeta.\n---\nZeta.\n' > "$SRC/skills/zeta/SKILL.md"
  # Before any deploy there is no record, and after deploying only ~/.shared the record names another source.
  placed_ok --source "$SRC" || return 1
  placed_holds <<'PY' || return 1
empty = {"skills": [], "rules": [], "hooks": []}
default = ["Claude Code", "Codex", "GitHub Copilot CLI"]
if out != {"source": src, "agents": {name: empty for name in default}} or list(out["agents"]) != default:
    fail("before any deploy placed printed %r" % out)
PY
  printf '{"version": 1, "agents": [{"name": "tester", "skills": "~/.tester/skills"}]}\n' > "$HOME/.shared/agents.json"
  deployed || return 1
  placed_ok --source "$SRC" || return 1
  placed_holds <<'PY'
agents = out.get("agents") or {}
if list(agents) != ["Claude Code", "Codex", "GitHub Copilot CLI", "tester"]:
    fail("the agents are %r, not every agent of the table in its order" % list(agents))
for name, agent in agents.items():
    if agent != {"skills": [], "rules": [], "hooks": []}:
        fail("%s is %r for a source never deployed" % (name, agent))
PY
}

placed_bad_hook_file() {
  fresh placed-badhooks
  full_source badhooks
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  printf '{"hooks": \n' > "$HOME/.codex/hooks.json"
  placed_run --source "$SRC"
  [ "$rc" = 2 ] || { why="placed exited $rc with a hook file that is not JSON"; return 1; }
  [ ! -s "$T/placed.out" ] || { why="placed printed something though it could not read a hook file"; return 1; }
  grep -q 'codex/hooks.json' "$T/placed.err" || { why="the refusal does not name the file: $(tail -1 "$T/placed.err")"; return 1; }
}

placed_broken_block() {
  fresh placed-block
  full_source block
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  grep '^<!-- agent-shared begin' "$HOME/.codex/AGENTS.md" | tail -1 >> "$HOME/.codex/AGENTS.md"
  placed_run --source "$SRC"
  [ "$rc" = 2 ] || { why="placed exited $rc with a broken rules block"; return 1; }
  [ ! -s "$T/placed.out" ] || { why="placed printed something though the rules block is broken"; return 1; }
  grep -q 'AGENTS.md' "$T/placed.err" || { why="the refusal does not name the file: $(tail -1 "$T/placed.err")"; return 1; }
}

placed_needs_source() {
  fresh placed-nosource
  placed_run
  [ "$rc" = 2 ] || { why="placed without --source exited $rc"; return 1; }
  [ ! -s "$T/placed.out" ] || { why="placed without --source printed something"; return 1; }
  grep -q -- '--source' "$T/placed.err" || { why="the refusal does not name --source: $(tail -1 "$T/placed.err")"; return 1; }
  placed_run --source "$T/no-such-source"
  [ "$rc" = 2 ] || { why="placed with a missing folder exited $rc"; return 1; }
  [ ! -s "$T/placed.out" ] || { why="placed with a missing folder printed something"; return 1; }
  grep -q "$T/no-such-source" "$T/placed.err" || { why="the refusal does not name the folder: $(tail -1 "$T/placed.err")"; return 1; }
}

# The fixture's hook file, so the list can name a file the source holds, and a command that runs the
# same file through a wrapper, beside a command whose file only starts with the same path.
hook_files() {
  mkdir -p "$HOME/.shared/hooks/lib"
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.shared/hooks/guard.sh"
  printf '#!/bin/sh\nexit 0\n' > "$HOME/.shared/hooks/guard.sh.orig"
  printf '#!/bin/sh\nexec "$@"\n' > "$HOME/.shared/hooks/lib/wrap.sh"
  cat > "$HOME/.shared/hooks.json" <<'JSON'
{"hooks": {
  "PreToolUse": [
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"}]},
    {"matcher": "Edit", "hooks": [{"type": "command", "command": "/bin/sh ${CLAUDE_PLUGIN_ROOT}/hooks/lib/wrap.sh bash ${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"}]},
    {"matcher": "Read", "hooks": [{"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh.orig"}]}
  ],
  "Stop": [{"hooks": [{"type": "command", "command": "echo stop"}]}]
}}
JSON
}

# The marked commands of one event in an agent's hook file, one per line, without the mark.
marked_commands() {
  python3 - "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for group in data.get("hooks", {}).get(sys.argv[2], []):
    for hook in group.get("hooks", []):
        command = hook.get("command", "")
        if "\n" in command and command.rsplit("\n", 1)[1].startswith("# agent-shared"):
            print(command.rsplit("\n", 1)[0])
PY
}

off_list() { printf '%s\n' "$HOME/.local/share/agent-shared/off.json"; }

off_on_write() {
  fresh off-write
  hook_files
  run off --source "$HOME/.shared" --agent Codex rules/one.md
  [ "$rc" = 0 ] || { why="off exited $rc: $(tail -1 "$T/out")"; return 1; }
  run off --source "$HOME/.shared" --agent "Claude Code" hooks/guard.sh
  [ "$rc" = 0 ] || { why="the second off exited $rc: $(tail -1 "$T/out")"; return 1; }
  python3 - "$(off_list)" "$HOME" <<'PY' || { why="$(cat "$T/off.why" 2>/dev/null)"; return 1; }
import json, os, sys
path, home = sys.argv[1:]
def fail(reason):
    open(os.environ["T"] + "/off.why", "w").write(reason)
    sys.exit(1)
if not os.path.exists(path):
    fail("off wrote no off.json beside the record")
data = json.load(open(path))
items = sorted((entry.get("agent"), entry.get("item")) for entry in data.get("off", []))
if items != [("Claude Code", "hooks/guard.sh"), ("Codex", "rules/one.md")]:
    fail("off.json holds %r" % items)
if any(os.path.realpath(entry.get("source", "")) != os.path.realpath(os.path.join(home, ".shared")) for entry in data["off"]):
    fail("an entry of off.json does not name the source folder")
PY
  run on --source "$HOME/.shared" --agent Codex rules/one.md
  [ "$rc" = 0 ] || { why="on exited $rc: $(tail -1 "$T/out")"; return 1; }
  python3 - "$(off_list)" <<'PY' || { why="on did not take out exactly its one entry"; return 1; }
import json, sys
data = json.load(open(sys.argv[1]))
sys.exit(0 if [(e["agent"], e["item"]) for e in data["off"]] == [("Claude Code", "hooks/guard.sh")] else 1)
PY
}

private_off_list() {
  fresh off-private
  run off --source "$HOME/.shared" --agent Codex rules/one.md
  [ "$rc" = 0 ] || { why="off exited $rc: $(tail -1 "$T/out")"; return 1; }
  [ "$(mode "$HOME/.local/share/agent-shared")" = 0o700 ] || { why="the record folder has mode $(mode "$HOME/.local/share/agent-shared")"; return 1; }
  [ "$(mode "$(off_list)")" = 0o600 ] || { why="off.json has mode $(mode "$(off_list)")"; return 1; }
  fresh off-private-moved
  export AGENT_SHARED_STATE="$T/off-state"
  run off --source "$HOME/.shared" --agent Codex rules/one.md
  [ -f "$T/off-state/off.json" ] || { why="AGENT_SHARED_STATE did not move off.json"; return 1; }
}

off_refuses_unknown() {
  fresh off-unknown
  hook_files
  local args
  for args in "--agent Codex rules/none.md" "--agent Codex hooks/none.sh" "--agent Codex ../outside.md" "--agent Nobody rules/one.md"; do
    # shellcheck disable=SC2086
    run off --source "$HOME/.shared" $args
    [ "$rc" = 2 ] || { why="off $args exited $rc"; return 1; }
    [ ! -e "$(off_list)" ] || { why="off $args wrote off.json though it refused"; return 1; }
  done
  run off --source "$HOME/.shared" --agent Nobody rules/one.md
  grep -q 'Nobody' "$T/out" || { why="the refusal does not name the agent: $(tail -1 "$T/out")"; return 1; }
  run off --source "$HOME/.shared" --agent Codex rules/none.md
  grep -q 'rules/none.md' "$T/out" || { why="the refusal does not name the item: $(tail -1 "$T/out")"; return 1; }
}

off_rule_one_agent() {
  fresh off-rule
  run off --source "$HOME/.shared" --agent Codex rules/one.md
  deployed || return 1
  ! grep -q 'Rule one.' "$HOME/.codex/AGENTS.md" || { why="rule one is in Codex's AGENTS.md though it is off for Codex"; return 1; }
  grep -q 'Rule two.' "$HOME/.codex/AGENTS.md" || { why="rule two left Codex's AGENTS.md"; return 1; }
  links_to "$HOME/.claude/rules/one.md" "$HOME/.shared/rules/one.md" || { why="rule one left Claude Code"; return 1; }
  fresh off-rule-claude
  run off --source "$HOME/.shared" --agent "Claude Code" rules/one.md
  deployed || return 1
  [ ! -L "$HOME/.claude/rules/one.md" ] || { why="rule one is linked into Claude Code though it is off for Claude Code"; return 1; }
  grep -q 'Rule one.' "$HOME/.codex/AGENTS.md" || { why="rule one left Codex"; return 1; }
}

off_hook_file() {
  fresh off-hook
  hook_files
  run off --source "$HOME/.shared" --agent Codex hooks/guard.sh
  deployed || return 1
  local codex claude
  codex="$(marked_commands "$HOME/.codex/hooks.json" PreToolUse)"
  claude="$(marked_commands "$HOME/.claude/settings.json" PreToolUse)"
  ! printf '%s\n' "$codex" | grep -q 'hooks/guard.sh$' || { why="Codex still runs guard.sh: $codex"; return 1; }
  printf '%s\n' "$codex" | grep -q 'hooks/guard.sh.orig$' || { why="Codex lost guard.sh.orig, which only starts like the path"; return 1; }
  [ "$(printf '%s\n' "$claude" | grep -c 'hooks/guard.sh$')" = 2 ] || { why="Claude Code does not keep both commands that run guard.sh: $claude"; return 1; }
}

off_command() {
  fresh off-command
  run off --source "$HOME/.shared" --agent Codex "echo stop"
  [ "$rc" = 0 ] || { why="off with a command exited $rc: $(tail -1 "$T/out")"; return 1; }
  deployed || return 1
  [ -z "$(marked_commands "$HOME/.codex/hooks.json" Stop)" ] || { why="Codex still has the stop hook"; return 1; }
  marked_commands "$HOME/.claude/settings.json" Stop | grep -q '^echo stop$' || { why="Claude Code lost the stop hook"; return 1; }
}

off_named_source_only() {
  fresh off-source
  hook_files
  SRC="$T/source-same-path"
  mkdir -p "$SRC/hooks"
  printf '#!/bin/sh\nexit 0\n' > "$SRC/hooks/guard.sh"
  printf '%s\n' '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"}]}]}}' > "$SRC/hooks.json"
  run off --source "$HOME/.shared" --agent Codex hooks/guard.sh
  approve_source "$SRC"
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  marked_commands "$HOME/.codex/hooks.json" Stop | grep -q "^bash $SRC/hooks/guard.sh$" \
    || { why="the other source's guard.sh left Codex"; return 1; }
  ! marked_commands "$HOME/.codex/hooks.json" PreToolUse | grep -q "/.shared/hooks/guard.sh$" \
    || { why="~/.shared's guard.sh is still in Codex"; return 1; }
}

off_then_on() {
  fresh off-then-on
  hook_files
  deployed || return 1
  run off --source "$HOME/.shared" --agent "Claude Code" rules/two.md
  run off --source "$HOME/.shared" --agent "Claude Code" hooks/guard.sh
  deployed || return 1
  [ ! -L "$HOME/.claude/rules/two.md" ] || { why="the next deploy left rule two in Claude Code"; return 1; }
  ! marked_commands "$HOME/.claude/settings.json" PreToolUse | grep -q 'hooks/guard.sh$' || { why="the next deploy left guard.sh in Claude Code"; return 1; }
  run on --source "$HOME/.shared" --agent "Claude Code" rules/two.md
  run on --source "$HOME/.shared" --agent "Claude Code" hooks/guard.sh
  deployed || return 1
  links_to "$HOME/.claude/rules/two.md" "$HOME/.shared/rules/two.md" || { why="rule two did not come back after on"; return 1; }
  [ "$(marked_commands "$HOME/.claude/settings.json" PreToolUse | grep -c 'hooks/guard.sh$')" = 2 ] || { why="guard.sh did not come back after on"; return 1; }
}

hooks_off() {
  fresh hooks-off
  hook_files
  run off --source "$HOME/.shared" --agent Codex hooks/guard.sh
  hooks_run --agent Codex
  [ "$rc" = 0 ] || { why="hooks exited $rc: $(tail -1 "$T/hooks.err")"; return 1; }
  ! grep -q 'hooks/guard.sh\\n' "$T/hooks.out" && ! grep -q 'hooks/guard.sh"' "$T/hooks.out" || { why="hooks printed guard.sh for Codex"; return 1; }
  grep -q 'guard.sh.orig' "$T/hooks.out" || { why="hooks left out guard.sh.orig"; return 1; }
  deployed || return 1
  hooks_run --agent Codex
  cp "$T/hooks.out" "$T/hooks-codex.json"
  python3 - "$T/hooks-codex.json" "$HOME/.codex/hooks.json" <<'PY' || { why="the printed hooks differ from what deploy placed in Codex"; return 1; }
import json, sys
printed = json.load(open(sys.argv[1]))["hooks"]
data = json.load(open(sys.argv[2]))["hooks"]
mark = "# agent-shared 1 source="
placed = {}
for event, groups in data.items():
    kept = [g for g in groups if all(h["command"].rsplit("\n", 1)[-1].startswith(mark) for h in g["hooks"])]
    if kept:
        placed[event] = kept
sys.exit(0 if printed == placed else 1)
PY
}

placed_left_out() {
  fresh placed-off
  hook_files
  run off --source "$HOME/.shared" --agent Codex rules/one.md
  run off --source "$HOME/.shared" --agent Codex hooks/guard.sh
  deployed || return 1
  SRC="$HOME/.shared"
  placed_ok --source "$HOME/.shared" || return 1
  placed_holds <<'PY'
agents = out.get("agents") or {}
codex = agents.get("Codex") or {}
claude = agents.get("Claude Code") or {}
if sorted(codex.get("left_out") or []) != ["hooks/guard.sh", "rules/one.md"]:
    fail("Codex's left_out is %r" % codex.get("left_out"))
if claude.get("left_out"):
    fail("Claude Code names %r as left out, though nothing is off for it" % claude.get("left_out"))
if "one.md" in (codex.get("rules") or []):
    fail("Codex lists rule one as placed")
PY
}

off_unreadable() {
  fresh off-broken
  deployed || return 1
  mkdir -p "$HOME/.local/share/agent-shared"
  printf '{"off": [\n' > "$(off_list)"
  snapshot "$HOME" > "$T/before.txt"
  run deploy
  [ "$rc" = 2 ] || { why="deploy exited $rc with an unreadable off.json"; return 1; }
  grep -q 'off.json' "$T/out" || { why="deploy did not name off.json: $(tail -1 "$T/out")"; return 1; }
  snapshot "$HOME" > "$T/after.txt"
  cmp -s "$T/before.txt" "$T/after.txt" || { why="deploy wrote $(diff "$T/before.txt" "$T/after.txt" | sed -n 2p)"; return 1; }
  hooks_run --agent Codex
  [ "$rc" = 2 ] && grep -q 'off.json' "$T/hooks.err" || { why="hooks exited $rc: $(tail -1 "$T/hooks.err")"; return 1; }
  placed_run --source "$HOME/.shared"
  [ "$rc" = 2 ] && grep -q 'off.json' "$T/placed.err" || { why="placed exited $rc: $(tail -1 "$T/placed.err")"; return 1; }
}

off_documented() {
  local f
  for f in README.md README.ja.md; do
    grep -qF 'off.json' "$ROOT/$f" && grep -qF 'agent-shared off' "$ROOT/$f" && grep -qF 'agent-shared on' "$ROOT/$f" \
      || { why="$f does not describe off.json with agent-shared off and on"; return 1; }
  done
  (cd "$T" && PYTHONPATH="$PKG/src" python3 -m agent_shared --help) > "$T/help.out" 2>&1
  grep -qF 'off.json' "$T/help.out" || { why="--help does not name off.json"; return 1; }
  (cd "$T" && PYTHONPATH="$PKG/src" python3 -m agent_shared off --help) > "$T/help.out" 2>&1
  grep -q 'exit status' "$T/help.out" && grep -qF 'off.json' "$T/help.out" || { why="off --help does not describe off.json and its exits"; return 1; }
}

# GitHub Copilot CLI reads rules from ~/.copilot/copilot-instructions.md in every session and hooks from
# ~/.copilot/hooks/*.json, which take Claude Code's nested shape with PascalCase events and a top-level
# "version": 1. Copilot CLI is not run here; the files written are checked against that shape.
COPILOT_RULES=".copilot/copilot-instructions.md"
COPILOT_HOOKS=".copilot/hooks/agent-shared.json"

# Checks a Copilot CLI hook file at $1 with the Python on stdin, which has `data`, `home`, and
# marked(command), and calls fail(<reason>) when it does not hold.
copilot_holds() {
  python3 - "$1" "$HOME" "$T/copilot.why" 3<&0 <<'PY' || { why="$(cat "$T/copilot.why" 2>/dev/null)"; return 1; }
import json, os, sys
path, home, why = sys.argv[1:]
def fail(reason):
    open(why, "w").write(reason)
    sys.exit(1)
def marked(command):
    return "\n" in command and command.rsplit("\n", 1)[1].startswith("# agent-shared")
if not os.path.exists(path):
    fail("%s was not written" % path)
data = json.load(open(path))
exec(os.fdopen(3).read())
PY
}

copilot_rules() {
  fresh copilot-rules
  mkdir -p "$HOME/.copilot"
  copilot_installed
  printf '# My Copilot notes\n\nKeep this line.\n' > "$HOME/$COPILOT_RULES"
  cp "$HOME/$COPILOT_RULES" "$T/copilot-before.md"
  deployed || return 1
  python3 - "$T/copilot-before.md" "$HOME/$COPILOT_RULES" <<'PY' || { why="$(cat "$T/copilot-rules.why" 2>/dev/null)"; return 1; }
import os, sys
before = open(sys.argv[1]).read()
after = open(sys.argv[2]).read()
lines = after.splitlines(keepends=True)
begins = [i for i, line in enumerate(lines) if line.startswith("<!-- agent-shared begin")]
ends = [i for i, line in enumerate(lines) if line.startswith("<!-- agent-shared end")]
problem = None
if len(begins) != 1 or len(ends) != 1 or begins[0] > ends[0]:
    problem = "copilot-instructions.md does not have exactly one block"
elif "".join(lines[:begins[0]]) + "".join(lines[ends[0] + 1:]) != before:
    problem = "the lines outside the block changed"
elif "Rule one." not in after or "Rule two." not in after:
    problem = "the block does not hold both rules"
if problem:
    open(os.environ["T"] + "/copilot-rules.why", "w").write(problem)
    sys.exit(1)
PY
}

copilot_hooks() {
  fresh copilot-hooks
  mkdir -p "$HOME/.copilot"
  copilot_installed
  deployed || return 1
  copilot_holds "$HOME/$COPILOT_HOOKS" <<'PY'
if data.get("version") != 1:
    fail("the hook file has version %r, not 1" % data.get("version"))
events = data.get("hooks")
if not isinstance(events, dict) or sorted(events) != ["PreToolUse", "Stop"]:
    fail("the events are %r, not PreToolUse and Stop" % (sorted(events) if isinstance(events, dict) else events))
guard = "bash %s/.shared/hooks/guard.sh" % home
matchers = []
for group in events["PreToolUse"]:
    inner = group.get("hooks")
    if not isinstance(inner, list) or not all(isinstance(h, dict) and h.get("type") == "command" for h in inner):
        fail("a PreToolUse group has no nested list of command hooks: %r" % group)
    matchers += [group.get("matcher") for h in inner if marked(h["command"]) and h["command"].startswith(guard)]
if sorted(matchers) != ["Bash", "Edit"]:
    fail("the marked guard hook is under the matchers %r, not Bash and Edit once each" % matchers)
if not any(marked(h["command"]) and h["command"].startswith("echo stop") for g in events["Stop"] for h in g.get("hooks", [])):
    fail("the hook file has no marked stop hook")
PY
}

copilot_removes() {
  fresh copilot-remove
  mkdir -p "$HOME/.copilot"
  copilot_installed
  deployed || return 1
  grep -q 'Rule two.' "$HOME/$COPILOT_RULES" 2>/dev/null && grep -q 'echo stop' "$HOME/$COPILOT_HOOKS" 2>/dev/null \
    || { why="the first run placed no rule two or stop hook for Copilot CLI"; return 1; }
  python3 - "$HOME/$COPILOT_HOOKS" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["hooks"].setdefault("Stop", []).append({"hooks": [{"type": "command", "command": "echo my-copilot-hook"}]})
json.dump(data, open(sys.argv[1], "w"), indent=2)
PY
  rm -f "$HOME/.shared/rules/two.md"
  cat > "$HOME/.shared/hooks.json" <<'JSON'
{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/guard.sh"}]}]}}
JSON
  deployed || return 1
  ! grep -q 'Rule two.' "$HOME/$COPILOT_RULES" || { why="rule two is still in copilot-instructions.md"; return 1; }
  grep -q 'Rule one.' "$HOME/$COPILOT_RULES" || { why="rule one, still in the source, was taken out"; return 1; }
  copilot_holds "$HOME/$COPILOT_HOOKS" <<'PY'
commands = [h["command"] for groups in data.get("hooks", {}).values() for g in groups for h in g.get("hooks", [])]
if any(marked(c) and c.startswith("echo stop") for c in commands):
    fail("the stop hook taken out of the source is still in the hook file")
if not any(marked(c) and "guard.sh" in c for c in commands):
    fail("the guard hook, still in the source, was taken out")
if "echo my-copilot-hook" not in commands:
    fail("the hook without the mark is gone")
PY
}

copilot_placed() {
  fresh copilot-placed
  mkdir -p "$HOME/.copilot"
  copilot_installed
  full_source copilot
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  placed_ok --source "$SRC" || return 1
  placed_holds <<'PY'
agent = (out.get("agents") or {}).get("GitHub Copilot CLI")
if not isinstance(agent, dict):
    fail("GitHub Copilot CLI is missing from agents")
if agent.get("rules") != ["three.md"]:
    fail("GitHub Copilot CLI rules are %r" % agent.get("rules"))
if len(agent.get("hooks") or []) != 3:
    fail("GitHub Copilot CLI has %d hooks, not the 3 the source declared for it" % len(agent.get("hooks") or []))
PY
}

copilot_absent() {
  fresh copilot-absent
  hooks_run --agent "GitHub Copilot CLI"
  [ "$rc" = 0 ] || { why="the default table has no GitHub Copilot CLI row: $(tail -1 "$T/hooks.err")"; return 1; }
  deployed || return 1
  [ ! -e "$HOME/.copilot" ] || { why="deploy created ~/.copilot: $(find "$HOME/.copilot" | head -3 | tr '\n' ' ')"; return 1; }
  links_to "$HOME/.claude/rules/one.md" "$HOME/.shared/rules/one.md" || { why="the rules were not written for Claude Code"; return 1; }
  grep -q 'Rule one.' "$HOME/.codex/AGENTS.md" || { why="the rules were not written for Codex"; return 1; }
  grep -q 'guard.sh' "$HOME/.claude/settings.json" && grep -q 'guard.sh' "$HOME/.codex/hooks.json" \
    || { why="the hooks were not written for Claude Code and Codex"; return 1; }
}

copilot_other_hook_files() {
  fresh copilot-others
  mkdir -p "$HOME/.copilot/hooks"
  copilot_installed
  printf '{"version": 1, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}]}}\n' > "$HOME/.copilot/hooks/mine.json"
  cp "$HOME/.copilot/hooks/mine.json" "$T/copilot-mine-before.json"
  deployed || return 1
  cmp -s "$HOME/.copilot/hooks/mine.json" "$T/copilot-mine-before.json" || { why="~/.copilot/hooks/mine.json changed"; return 1; }
}

# A Copilot IDE plugin makes ~/.copilot/ide, while the copilot command is not installed.
copilot_ide_only() {
  fresh copilot-ide
  mkdir -p "$HOME/.copilot/ide"
  deployed || return 1
  local found
  found="$(cd "$HOME/.copilot" && find . -mindepth 1 -not -path './ide' -not -path './ide/*' | head -3 | tr '\n' ' ')"
  [ -z "$found" ] || { why="deploy wrote into ~/.copilot without the copilot command: $found"; return 1; }
}

# Placed while the command was there, then the command is gone: the run's items leave, the person's stay.
copilot_skipped_cleanup() {
  fresh copilot-skipped
  mkdir -p "$HOME/.copilot/hooks"
  printf '# My notes\n\nKeep this line.\n' > "$HOME/$COPILOT_RULES"
  printf '{"version": 1, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo my-copilot-hook"}]}]}}\n' > "$HOME/$COPILOT_HOOKS"
  printf '{"version": 1, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}]}}\n' > "$HOME/.copilot/hooks/mine.json"
  copilot_installed
  deployed || return 1
  grep -q 'Rule one.' "$HOME/$COPILOT_RULES" && grep -q 'guard.sh' "$HOME/$COPILOT_HOOKS" \
    || { why="the first run, with the copilot command, did not place the rules and hooks"; return 1; }
  export PATH="$BASE_PATH"
  run deploy
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  ! grep -q 'agent-shared' "$HOME/$COPILOT_RULES" || { why="the rules block is still in copilot-instructions.md"; return 1; }
  grep -q 'Keep this line.' "$HOME/$COPILOT_RULES" || { why="the person's own line is gone"; return 1; }
  ! grep -q 'guard.sh' "$HOME/$COPILOT_HOOKS" && grep -q 'echo my-copilot-hook' "$HOME/$COPILOT_HOOKS" \
    || { why="the marked hooks stayed or the hand-written hook is gone"; return 1; }
  grep -q 'echo mine' "$HOME/.copilot/hooks/mine.json" || { why="the person's other hook file changed"; return 1; }
  # A file the run alone wrote holds nothing once its items are out, so it is removed.
  fresh copilot-skipped-empty
  mkdir -p "$HOME/.copilot"
  copilot_installed
  deployed || return 1
  export PATH="$BASE_PATH"
  run deploy
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  [ ! -e "$HOME/$COPILOT_RULES" ] && [ ! -e "$HOME/$COPILOT_HOOKS" ] \
    || { why="a file left holding nothing was not removed: $(ls "$HOME/.copilot" "$HOME/.copilot/hooks" 2>/dev/null | tr '\n' ' ')"; return 1; }
}

definition_names_needs_command() {
  local f
  python3 - "$PKG/src/agent_shared/agents.json" <<'PY' || { why="the Copilot CLI row does not wait for the copilot command"; return 1; }
import json, sys
row = next(r for r in json.load(open(sys.argv[1]))["agents"] if r["name"] == "GitHub Copilot CLI")
sys.exit(0 if row.get("needs_command") == "copilot" and "needs" not in row else 1)
PY
  for f in spec/agent-shared.md spec/agent-shared.ja.md README.md README.ja.md; do
    grep -qF 'needs_command' "$ROOT/$f" && grep -qF '`copilot`' "$ROOT/$f" \
      || { why="$f does not name needs_command and the copilot command"; return 1; }
  done
}

# Placed while the command was there, then the command is gone: the hook file goes, and so does the folder it
# leaves empty, while the agent's folder right under the home folder stays even when empty.
emptied_hooks_folder() {
  fresh emptied-hooks
  mkdir -p "$HOME/.copilot"
  copilot_installed
  deployed || return 1
  [ -f "$HOME/$COPILOT_HOOKS" ] || { why="the first run, with the copilot command, did not write the hook file"; return 1; }
  export PATH="$BASE_PATH"
  deployed || return 1
  [ ! -e "$HOME/$COPILOT_HOOKS" ] || { why="the hook file was not removed"; return 1; }
  [ ! -e "$HOME/.copilot/hooks" ] || { why="the emptied ~/.copilot/hooks stayed"; return 1; }
  [ -d "$HOME/.copilot" ] || { why="~/.copilot, the agent's folder, was removed"; return 1; }
}

# The source drops its skills: the links go, and so do the skill folders they leave empty, while the agents'
# folders right under the home folder stay.
emptied_skill_folder() {
  fresh emptied-skills
  deployed || return 1
  links_to "$HOME/.agents/skills/alpha" "$HOME/.shared/skills/alpha" || { why="the first run did not link the skills"; return 1; }
  rm -rf "$HOME/.shared/skills"
  deployed || return 1
  local folder
  for folder in .claude/skills .agents/skills; do
    [ ! -e "$HOME/$folder" ] || { why="the emptied ~/$folder stayed: $(ls -A "$HOME/$folder" | tr '\n' ' ')"; return 1; }
  done
  [ -d "$HOME/.claude" ] && [ -d "$HOME/.agents" ] || { why="an agent's folder right under the home folder was removed"; return 1; }
}

# A repository's .shared placed skills, rules, and hooks into the repository, then is removed: no folder it left
# empty stays, and the repository root does.
remove_repo_folders() {
  fresh remove-repo
  mkdir -p "$HOME/.copilot"
  copilot_installed
  repo_with_shared remove
  mkdir -p "$REPO/.shared/skills/gamma"
  printf -- '---\nname: gamma\ndescription: Gamma.\n---\nGamma.\n' > "$REPO/.shared/skills/gamma/SKILL.md"
  approve_source "$REPO/.shared"
  run deploy --repo "$REPO"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  [ -f "$REPO/.github/hooks/agent-shared.json" ] && [ -L "$REPO/.claude/skills/gamma" ] \
    || { why="the repository's hooks and skills were not placed before removing them"; return 1; }
  run remove --source "$REPO/.shared"
  [ "$rc" = 0 ] || { why="remove exited $rc: $(tail -1 "$T/out")"; return 1; }
  [ -d "$REPO/.git" ] && [ -d "$REPO/.shared" ] || { why="the repository root lost .git or .shared"; return 1; }
  local empty
  empty="$(cd "$REPO" && find . -mindepth 1 -type d -empty -not -path './.git' -not -path './.git/*' -not -path './.shared' -not -path './.shared/*' | sort | tr '\n' ' ')"
  [ -z "$empty" ] || { why="remove left empty folders in the repository: $empty"; return 1; }
}

# Removing ~/.shared keeps the folders right under the home folder even when they are left empty,
# while the emptied folders inside them still go (#29). The home folder is no repository.
remove_home_source() {
  fresh remove-home
  find "$HOME/.claude" "$HOME/.codex" -mindepth 1 -delete
  mkdir -p "$HOME/.copilot"
  copilot_installed
  run deploy
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  [ -L "$HOME/.claude/skills/alpha" ] && [ -L "$HOME/.agents/skills/alpha" ] || { why="~/.shared was not placed before removing it"; return 1; }
  run remove --source "$HOME/.shared"
  [ "$rc" = 0 ] || { why="remove exited $rc: $(tail -1 "$T/out")"; return 1; }
  local folder
  for folder in .claude .codex .copilot .agents; do
    [ -d "$HOME/$folder" ] || { why="remove took out ~/$folder, a folder right under the home folder"; return 1; }
  done
  [ ! -e "$HOME/.claude/skills" ] && [ ! -e "$HOME/.agents/skills" ] || { why="remove left the emptied skills folders"; return 1; }
  [ -d "$HOME/.shared/skills/alpha" ] || { why="remove touched the source folder"; return 1; }
}

# The READMEs say which agents see an edit at once (links) and which see it on the next deploy (copies) (#29).
readmes_edit_reach() {
  grep -qF 'an edit to a rule reaches them on the next `agent-shared deploy`' "$ROOT/README.md" \
    && ! grep -qF 'an edit reaches every agent at once' "$ROOT/README.md" \
    || { why="README.md does not say that Codex and Copilot CLI see a rule edit on the next deploy"; return 1; }
  grep -qF 'ルールの直しは次の`agent-shared deploy`で届きます' "$ROOT/README.ja.md" \
    && ! grep -qF '全てのエージェントに一度に届きます' "$ROOT/README.ja.md" \
    || { why="README.ja.md does not say that Codex and Copilot CLI see a rule edit on the next deploy"; return 1; }
}

# The READMEs name every command that writes off.json, remove included (#33).
readmes_off_writers() {
  grep -qF '`agent-shared remove` drops the removed source'"'"'s entries from' "$ROOT/README.md" \
    || { why="README.md does not say that remove drops entries from off.json"; return 1; }
  grep -qF '`agent-shared remove`は外した配る元の項目をそこから消す' "$ROOT/README.ja.md" \
    || { why="README.ja.md does not say that remove drops entries from off.json"; return 1; }
}

# A folder that still holds the person's file stays when agent-shared takes its own file out of it.
person_file_folder() {
  fresh person-folder
  mkdir -p "$HOME/.copilot/hooks"
  printf '{"version": 1, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "echo mine"}]}]}}\n' > "$HOME/.copilot/hooks/mine.json"
  copilot_installed
  deployed || return 1
  export PATH="$BASE_PATH"
  deployed || return 1
  [ ! -e "$HOME/$COPILOT_HOOKS" ] || { why="the hook file was not removed"; return 1; }
  [ -f "$HOME/.copilot/hooks/mine.json" ] || { why="~/.copilot/hooks/mine.json, the person's file, is gone"; return 1; }
}

definition_emptied_folders() {
  local f word
  for f in spec/agent-shared.md README.md spec/agent-shared.ja.md README.ja.md; do
    case "$f" in *.ja.md) word='空になったフォルダー' ;; *) word='left empty' ;; esac
    grep -qF "$word" "$ROOT/$f" || { why="$f does not say a folder left empty is removed ($word)"; return 1; }
  done
}

# Codex placed at a checked version, then found older than `from`: nothing of Codex changes, Claude Code is still
# written, and once Codex is back inside the range the next deploy writes it again.
version_older() {
  fresh version-older
  agent_version codex 'codex-cli 0.171.0'
  deployed || return 1
  cp "$HOME/.codex/hooks.json" "$T/version-older-hooks.json"
  cp "$HOME/.codex/AGENTS.md" "$T/version-older-agents.md"
  printf '# Three\nRule three.\n' > "$HOME/.shared/rules/three.md"
  mkdir -p "$HOME/.shared/skills/gamma"
  printf -- '---\nname: gamma\ndescription: Gamma.\n---\nGamma.\n' > "$HOME/.shared/skills/gamma/SKILL.md"
  agent_version codex 'codex-cli 0.100.0'
  deployed || return 1
  cmp -s "$HOME/.codex/hooks.json" "$T/version-older-hooks.json" && cmp -s "$HOME/.codex/AGENTS.md" "$T/version-older-agents.md" \
    || { why="Codex's hooks.json or AGENTS.md changed while Codex was older than from"; return 1; }
  [ ! -e "$HOME/.agents/skills/gamma" ] || { why="the new skill was placed for Codex while it was older than from"; return 1; }
  links_to "$HOME/.agents/skills/alpha" "$HOME/.shared/skills/alpha" || { why="Codex's skill link placed before is gone"; return 1; }
  links_to "$HOME/.claude/skills/gamma" "$HOME/.shared/skills/gamma" && links_to "$HOME/.claude/rules/three.md" "$HOME/.shared/rules/three.md" \
    || { why="Claude Code was not written in the same run"; return 1; }
  grep -qF '0.100.0' "$T/out" && grep -qF '0.124.0' "$T/out" || { why="the run did not name Codex's version and from: $(cat "$T/out" | tr '\n' ' ')"; return 1; }
  agent_version codex 'codex-cli 0.171.0'
  deployed || return 1
  links_to "$HOME/.agents/skills/gamma" "$HOME/.shared/skills/gamma" && grep -q 'Rule three.' "$HOME/.codex/AGENTS.md" \
    || { why="back inside the range, the next deploy did not write Codex"; return 1; }
}

version_newer() {
  fresh version-newer
  agent_version claude '2.1.999 (Claude Code)'
  deployed || return 1
  links_to "$HOME/.claude/skills/alpha" "$HOME/.shared/skills/alpha" && grep -q 'guard.sh' "$HOME/.claude/settings.json" \
    || { why="Claude Code was not written"; return 1; }
  grep -qF '2.1.999' "$T/out" && grep -qF '2.1.330' "$T/out" || { why="the run did not name Claude Code's version and to: $(cat "$T/out" | tr '\n' ' ')"; return 1; }
}

version_unreadable() {
  fresh version-unreadable
  agent_version claude ''
  deployed || return 1
  links_to "$HOME/.claude/skills/alpha" "$HOME/.shared/skills/alpha" || { why="Claude Code was not written when its version printed nothing"; return 1; }
  grep -i 'could not read' "$T/out" | grep -q 'Claude Code' || { why="the run did not say Claude Code's version could not be read: $(cat "$T/out" | tr '\n' ' ')"; return 1; }
  # Without the command on PATH at all.
  fresh version-missing
  export PATH="$(printf '%s' "$BASE_PATH" | tr ':' '\n' | while IFS= read -r dir; do [ -x "$dir/claude" ] || printf '%s:' "$dir"; done)"
  export PATH="${PATH%:}"
  deployed || return 1
  links_to "$HOME/.claude/skills/alpha" "$HOME/.shared/skills/alpha" || { why="Claude Code was not written without its command"; return 1; }
  grep -i 'could not read' "$T/out" | grep -q 'Claude Code' || { why="the run did not say Claude Code's version could not be read without its command"; return 1; }
}

version_inside() {
  fresh version-inside
  agent_version claude '2.1.330 (Claude Code)'
  agent_version codex 'codex-cli 0.171.0'
  deployed || return 1
  links_to "$HOME/.claude/skills/alpha" "$HOME/.shared/skills/alpha" && links_to "$HOME/.agents/skills/alpha" "$HOME/.shared/skills/alpha" \
    || { why="Claude Code or Codex was not written"; return 1; }
  ! grep -i -E 'version|2\.1\.330|0\.171\.0' "$T/out" > /dev/null || { why="the run printed a version line: $(grep -i -E 'version|2\.1\.330|0\.171\.0' "$T/out" | head -2 | tr '\n' ' ')"; return 1; }
}

definition_versions() {
  local f older newer
  for f in spec/agent-shared.md README.md spec/agent-shared.ja.md README.ja.md; do
    case "$f" in
      *.ja.md) older='`from`より古い'; newer='`to`より新しい' ;;
      *) older='older than `from`'; newer='newer than `to`' ;;
    esac
    grep -qF "$older" "$ROOT/$f" && grep -qF "$newer" "$ROOT/$f" \
      || { why="$f does not say which versions stop the writes ($older, $newer)"; return 1; }
  done
}

# The two proposals to Agent Plugins, in English, with the parts its contributing guide asks a Discussion to cover.
PROPOSALS="docs/proposals/agent-plugins-portable-rules.md docs/proposals/agent-plugins-hook-events.md"
proposals_parts() {
  local f heading
  for f in $PROPOSALS; do
    [ -f "$ROOT/$f" ] || { why="$f is missing"; return 1; }
    for heading in '## Problem' '## Who hits it' '## Why it belongs in the portable specification' '## Who would adopt it'; do
      grep -qxF "$heading" "$ROOT/$f" || { why="$f has no heading: $heading"; return 1; }
    done
    ! python3 -c 'import re,sys; sys.exit(0 if re.search(r"[぀-ヿ一-鿿]", open(sys.argv[1], encoding="utf-8").read()) else 1)' "$ROOT/$f" \
      || { why="$f is not all English"; return 1; }
  done
}

proposals_evidence() {
  local f
  for f in $PROPOSALS; do
    [ -f "$ROOT/$f" ] || { why="$f is missing"; return 1; }
    python3 - "$PKG/src/agent_shared/agents.json" "$ROOT/$f" <<'PY' || { why="$(cat "$T/proposal.why")"; return 1; }
import json, os, sys
rows = json.load(open(sys.argv[1]))["agents"]
text = open(sys.argv[2], encoding="utf-8").read()
missing = [r["name"] + " " + r["checked"]["to"] for r in rows if r["name"] not in text or r["checked"]["to"] not in text]
if "https://github.com/cardene777/agent-shared/blob/main/spec/agent-shared.md" not in text:
    missing.append("a link to the definition")
if missing:
    open(os.environ["T"] + "/proposal.why", "w").write("%s does not name %s" % (sys.argv[2], ", ".join(missing)))
    sys.exit(1)
PY
  done
}

# Each proposal names the Discussion it was posted as, its related threads, and that an AI tool was used,
# and the two name different Discussions (#27).
proposals_posted() {
  local f number numbers=""
  for f in $PROPOSALS; do
    [ -f "$ROOT/$f" ] || { why="$f is missing"; return 1; }
    number="$(sed -n 's/^This is the text of a GitHub Discussion posted to the Agent Plugins specification as agentplugins\/agent-plugins-spec#\([0-9][0-9]*\)\.$/\1/p' "$ROOT/$f")"
    [ -n "$number" ] || { why="$f does not name the Discussion it was posted as"; return 1; }
    grep -q '^Discussion-first proposal per CONTRIBUTING.md. Related threads: ' "$ROOT/$f" || { why="$f names no related threads"; return 1; }
    grep -qxF 'This proposal was prepared with an AI coding agent and reviewed by me.' "$ROOT/$f" \
      || { why="$f does not say an AI tool was used"; return 1; }
    case " $numbers " in *" $number "*) why="two proposals name the same Discussion #$number"; return 1 ;; esac
    numbers="$numbers $number"
  done
}

definition_v11() {
  local f
  for f in spec/agent-shared.md spec/agent-shared.ja.md; do
    grep -qF 'Agent Plugins v1.1' "$ROOT/$f" && grep -qF 'docs/proposals/agent-plugins-portable-rules.md' "$ROOT/$f" \
      && grep -qF 'docs/proposals/agent-plugins-hook-events.md' "$ROOT/$f" \
      || { why="$f does not relate itself to Agent Plugins v1.1 and name the two proposals"; return 1; }
  done
}

readmes_name_copilot() {
  local f
  for f in README.md README.ja.md; do
    grep -qF '~/.copilot/copilot-instructions.md' "$ROOT/$f" && grep -qF '~/.copilot/hooks/agent-shared.json' "$ROOT/$f" \
      || { why="$f does not name where Copilot CLI's rules and hooks go"; return 1; }
  done
}

# The definition: spec/agent-shared.md is normative and spec/agent-shared.ja.md is its translation, so the
# two keep the same headings, table rows, and code blocks.
definition_pair() {
  [ -f "$ROOT/spec/agent-shared.md" ] && [ -f "$ROOT/spec/agent-shared.ja.md" ] \
    || { why="spec/agent-shared.md or spec/agent-shared.ja.md is missing"; return 1; }
  python3 - "$ROOT/spec/agent-shared.md" "$ROOT/spec/agent-shared.ja.md" <<'PY' || { why="$(cat "$T/pair.why")"; return 1; }
import os, re, sys
def shape(path):
    text = open(path, encoding="utf-8").read()
    blocks = re.findall(r"^```[^\n]*\n(.*?)^```", text, re.M | re.S)
    body = re.sub(r"^```.*?^```", "", text, flags=re.M | re.S).splitlines()
    levels = [len(re.match(r"#+", line).group()) for line in body if re.match(r"#{1,6} ", line)]
    rows = [line for line in body if line.startswith("|") and not re.fullmatch(r"\|[-| :]+\|", line)]
    return levels, len(rows), blocks
en, ja = shape(sys.argv[1]), shape(sys.argv[2])
problem = None
if en[0] != ja[0]:
    problem = "the headings differ: levels %r and %r" % (en[0], ja[0])
elif en[1] != ja[1]:
    problem = "the table rows differ: %d and %d" % (en[1], ja[1])
elif en[2] != ja[2]:
    problem = "the code blocks differ"
if problem:
    open(os.environ["T"] + "/pair.why", "w").write(problem)
    sys.exit(1)
PY
}

definition_sections() {
  local spec="$ROOT/spec/agent-shared.md" name
  [ -f "$spec" ] || { why="spec/agent-shared.md is missing"; return 1; }
  for name in "Source folder" "Hook declaration" "Agent table" "Marks and records" "Approving sources" \
      "Placing into a repository" "Taking everything out" "Versions" "Relation to existing specs"; do
    grep -q -i -E "^#{2,3} $name\$" "$spec" || { why="spec/agent-shared.md has no section $name"; return 1; }
  done
  grep -q -E '^Definition version `[0-9]{4}-[0-9]{2}-[0-9]{2}`' "$spec" || { why="spec/agent-shared.md has no dated definition version"; return 1; }
}

table_rows() {
  grep -qF 'src/agent_shared/agents.json' "$ROOT/spec/agent-shared.md" 2>/dev/null \
    || { why="the definition does not name src/agent_shared/agents.json as the agent table"; return 1; }
  python3 - "$PKG/src/agent_shared/agents.json" <<'PY' || { why="$(cat "$T/table.why")"; return 1; }
import json, os, sys
problem = None
for row in json.load(open(sys.argv[1]))["agents"]:
    events, checked = row.get("events"), row.get("checked")
    if not isinstance(events, list) or not events or not all(isinstance(e, str) and e for e in events):
        problem = "the row %s lists no events" % row.get("name")
    elif not isinstance(checked, dict) or not all(isinstance(checked.get(k), str) and checked[k] for k in ("from", "to")):
        problem = "the row %s has no checked versions from and to" % row.get("name")
    if problem:
        break
if problem:
    open(os.environ["T"] + "/table.why", "w").write(problem)
    sys.exit(1)
PY
}

check_run() {
  (cd "$RUN_DIR" && PYTHONPATH="$PKG/src" python3 -m agent_shared check "$@") > "$T/check.out" 2>&1
  rc=$?
}

check_example() {
  fresh check-example
  check_run --source "$ROOT/examples/basic"
  [ "$rc" = 0 ] || { why="check exited $rc: $(tail -1 "$T/check.out")"; return 1; }
}

# Each wrong declaration sits in a source of its own, so each refusal is seen.
check_refuses() {
  fresh check-refuses
  local bad="$T/bad-source"
  mkdir -p "$bad/event" "$bad/command" "$bad/row"
  printf '{"hooks": {"NoSuchEvent": [{"hooks": [{"type": "command", "command": "echo x"}]}]}}\n' > "$bad/event/hooks.json"
  printf '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command"}]}]}}\n' > "$bad/command/hooks.json"
  printf '{"version": 1, "agents": [{"skills": "~/.nameless/skills"}]}\n' > "$bad/row/agents.json"
  check_run --source "$bad/event"
  [ "$rc" = 1 ] && grep 'hooks.json' "$T/check.out" | grep -q 'NoSuchEvent' \
    || { why="an unknown event: check exited $rc: $(tail -1 "$T/check.out")"; return 1; }
  check_run --source "$bad/command"
  [ "$rc" = 1 ] && grep 'hooks.json' "$T/check.out" | grep -qF 'hooks.PreToolUse[0].hooks[0]' \
    || { why="a hook without a command: check exited $rc: $(tail -1 "$T/check.out")"; return 1; }
  check_run --source "$bad/row"
  [ "$rc" = 1 ] && grep 'agents.json' "$T/check.out" | grep -qF 'agents[0]' \
    || { why="a row without a name: check exited $rc: $(tail -1 "$T/check.out")"; return 1; }
}

# The definition's table of places, read for every skill, rule, and hook of the example.
example_deploy() {
  fresh example
  rm -rf "$HOME/.shared"
  mkdir -p "$HOME/.copilot"
  copilot_installed
  local ex="$ROOT/examples/basic"
  [ -d "$ex/skills" ] && [ -d "$ex/rules" ] && [ -f "$ex/hooks.json" ] || { why="examples/basic lacks skills, rules, or hooks.json"; return 1; }
  approve_source "$ex"
  run deploy --source "$ex"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  python3 - "$HOME" "$ex" <<'PY' || { why="$(cat "$T/example.why")"; return 1; }
import json, os, sys
home, ex = sys.argv[1:]
real = os.path.realpath
def fail(reason):
    open(os.environ["T"] + "/example.why", "w").write(reason)
    sys.exit(1)
def marked(command):
    return "\n" in command and command.rsplit("\n", 1)[1].startswith("# agent-shared")
skills = sorted(n for n in os.listdir(os.path.join(ex, "skills")) if os.path.isfile(os.path.join(ex, "skills", n, "SKILL.md")))
rules = sorted(n for n in os.listdir(os.path.join(ex, "rules")) if n.endswith(".md"))
if not skills or not rules:
    fail("the example has no skill or no rule")
for name in skills:
    for folder in (".claude/skills", ".agents/skills"):
        place = os.path.join(home, folder, name)
        if not os.path.islink(place) or real(place) != real(os.path.join(ex, "skills", name)):
            fail("%s is not a link to the skill" % place)
for name in rules:
    place = os.path.join(home, ".claude/rules", name)
    if not os.path.islink(place) or real(place) != real(os.path.join(ex, "rules", name)):
        fail("%s is not a link to the rule" % place)
    body = open(os.path.join(ex, "rules", name)).read().strip()
    for path in (".codex/AGENTS.md", ".copilot/copilot-instructions.md"):
        if body not in open(os.path.join(home, path)).read():
            fail("the rule %s is not in the block of %s" % (name, path))
declared = json.load(open(os.path.join(ex, "hooks.json")))["hooks"]
for path in (".claude/settings.json", ".codex/hooks.json", ".copilot/hooks/agent-shared.json"):
    events = json.load(open(os.path.join(home, path))).get("hooks", {})
    for event, groups in declared.items():
        for group in groups:
            for hook in group["hooks"]:
                want = hook["command"].replace("${CLAUDE_PLUGIN_ROOT}", ex)
                got = [h["command"] for g in events.get(event, []) for h in g.get("hooks", [])]
                if not any(marked(c) and c.startswith(want) for c in got):
                    fail("%s has no marked %s hook %s" % (path, event, want))
PY
}

# A row of the user's table that reads only PreToolUse, so the Stop hook of ~/.shared has no place in it.
missing_event() {
  fresh missing-event
  printf '{"version": 1, "agents": [{"name": "Narrow", "skills": "~/.narrow/skills", "hooks": {"file": "~/.narrow/hooks.json"}, "events": ["PreToolUse"]}]}\n' \
    > "$HOME/.shared/agents.json"
  deployed || return 1
  grep -q 'guard.sh' "$HOME/.narrow/hooks.json" 2>/dev/null || { why="the PreToolUse hook was not written for Narrow"; return 1; }
  ! grep -q 'echo stop' "$HOME/.narrow/hooks.json" || { why="the Stop hook was written for an agent that lacks Stop"; return 1; }
  grep -q 'echo stop' "$HOME/.claude/settings.json" || { why="the Stop hook is gone from Claude Code"; return 1; }
  grep 'Narrow' "$T/out" | grep -q 'Stop' || { why="the run did not name the Stop hook and Narrow"; return 1; }
}

unapproved_source() {
  fresh unapproved
  NO_APPROVE=1 full_source unapproved
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  links_to "$HOME/.claude/skills/delta" "$SRC/skills/delta" || { why="the skill of the source was not placed"; return 1; }
  links_to "$HOME/.claude/rules/three.md" "$SRC/rules/three.md" || { why="the rule of the source was not placed"; return 1; }
  ! grep -qF "$SRC" "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" || { why="a hook of the source not approved was written"; return 1; }
  grep -q 'guard.sh' "$HOME/.claude/settings.json" || { why="the hooks of ~/.shared are gone"; return 1; }
  grep -F 'agent-shared approve --source' "$T/out" | grep -qF "$SRC" || { why="the run did not name the command that approves the source"; return 1; }
  python3 - "$HOME" <<'PY' || { why="Codex was asked to trust a hook of the source not approved"; return 1; }
import json, os, sys
home = sys.argv[1]
log = os.path.join(home, "codex-calls.jsonl")
writes = [json.loads(l) for l in open(log)] if os.path.exists(log) else []
writes = [m for m in writes if m.get("method") == "config/batchWrite"]
data = json.load(open(os.path.join(home, ".codex/hooks.json")))
place = os.path.join(home, ".codex/hooks.json")
marked = {"%s:%s:%d:%d" % (place, e, gi, hi) for e, groups in data["hooks"].items() for gi, g in enumerate(groups)
          for hi, h in enumerate(g["hooks"]) if "\n" in h["command"] and h["command"].rsplit("\n", 1)[1].startswith("# agent-shared")}
for message in writes:
    value = message["params"]["edits"][0]["value"]
    if any(isinstance(v, dict) and v.get("trusted_hash") for k, v in value.items() if k not in marked):
        sys.exit(1)
PY
}

approve_then_deploy() {
  fresh approve
  NO_APPROVE=1 full_source approve
  approve_source "$SRC"
  [ "$rc" = 0 ] || { why="approve exited $rc: $(tail -1 "$T/approve.out")"; return 1; }
  grep -qF "$SRC/hooks/check.sh" "$T/approve.out" && grep -q 'echo source-stop' "$T/approve.out" \
    || { why="approve did not print the source's hook commands"; return 1; }
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  grep -qF "$SRC/hooks/check.sh" "$HOME/.claude/settings.json" || { why="the approved source's hook was not written"; return 1; }
}

# A record written before approving existed holds the source without an approval field.
approved_before() {
  fresh approved-before
  NO_APPROVE=1 full_source before
  local sid
  sid="$(PYTHONPATH="$PKG/src" python3 -c 'import sys; from agent_shared.deploy import source_id; print(source_id(sys.argv[1]))' "$SRC")"
  mkdir -p "$HOME/.local/share/agent-shared"
  printf '{"version": 1, "sources": {"%s": {"path": "%s", "links": {}}}}\n' "$sid" "$SRC" > "$HOME/.local/share/agent-shared/placed.json"
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  grep -qF "$SRC/hooks/check.sh" "$HOME/.claude/settings.json" || { why="the hooks of a source placed before were not written"; return 1; }
  grep -q 'guard.sh' "$HOME/.claude/settings.json" || { why="the hooks of ~/.shared were not written"; return 1; }
}

# A repository with .shared, the way find_repo looks for one.
repo_with_shared() {
  REPO="$T/repo-$1"
  mkdir -p "$REPO/.git" "$REPO/.shared/rules" "$REPO/.shared/hooks"
  printf '# Repo rule\nRepository rule.\n' > "$REPO/.shared/rules/repo.md"
  printf '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/check.sh"}]}]}}\n' \
    > "$REPO/.shared/hooks.json"
}

repo_rules() {
  fresh repo-rules
  repo_with_shared rules
  printf '# The repository\n\nKeep this line.\n' > "$REPO/AGENTS.md"
  cp "$REPO/AGENTS.md" "$T/repo-agents-before.md"
  run deploy --repo "$REPO"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  python3 - "$T/repo-agents-before.md" "$REPO/AGENTS.md" <<'PY' || { why="$(cat "$T/repo-rules.why")"; return 1; }
import os, sys
before, after = open(sys.argv[1]).read(), open(sys.argv[2]).read()
lines = after.splitlines(keepends=True)
begins = [i for i, line in enumerate(lines) if line.startswith("<!-- agent-shared begin")]
ends = [i for i, line in enumerate(lines) if line.startswith("<!-- agent-shared end")]
problem = None
if len(begins) != 1 or len(ends) != 1 or begins[0] > ends[0]:
    problem = "the repository's AGENTS.md does not have exactly one block"
elif "".join(lines[:begins[0]]) + "".join(lines[ends[0] + 1:]) != before:
    problem = "the lines outside the block changed"
elif "Repository rule." not in after:
    problem = "the block does not hold the repository's rule"
if problem:
    open(os.environ["T"] + "/repo-rules.why", "w").write(problem)
    sys.exit(1)
PY
}

repo_hooks() {
  fresh repo-hooks
  mkdir -p "$HOME/.copilot"
  copilot_installed
  repo_with_shared hooks
  approve_source "$REPO/.shared"
  run deploy --repo "$REPO"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  python3 - "$REPO" <<'PY' || { why="$(cat "$T/repo-hooks.why")"; return 1; }
import json, os, sys
repo = sys.argv[1]
def fail(reason):
    open(os.environ["T"] + "/repo-hooks.why", "w").write(reason)
    sys.exit(1)
for path in (".claude/settings.json", ".codex/hooks.json", ".github/hooks/agent-shared.json"):
    full = os.path.join(repo, path)
    if not os.path.exists(full):
        fail("%s was not written" % path)
    data = json.load(open(full))
    commands = [h["command"] for g in data.get("hooks", {}).get("PreToolUse", []) for h in g.get("hooks", [])]
    if not any(c.startswith("bash ") and ".shared/hooks/check.sh\n# agent-shared" in c for c in commands):
        fail("%s has no marked hook running .shared/hooks/check.sh: %r" % (path, commands))
    if path.startswith(".github") and data.get("version") != 1:
        fail("%s has no version 1" % path)
PY
}

# The three agents' repository hook files, relative to the repository.
REPO_HOOK_FILES=".claude/settings.json .codex/hooks.json .github/hooks/agent-shared.json"

# A repository with .shared in a real git work tree, a src/ subfolder, and a hook script that exits 2, deployed
# for the three agents.
deployed_git_repo() {
  fresh "repo-git-$1"
  mkdir -p "$HOME/.copilot"
  copilot_installed
  repo_with_shared "git-$1"
  rm -rf "$REPO/.git"
  git init -q "$REPO" || { why="git init failed"; return 1; }
  mkdir -p "$REPO/src"
  printf '#!/bin/sh\nexit 2\n' > "$REPO/.shared/hooks/check.sh"
  approve_source "$REPO/.shared"
  run deploy --repo "$REPO"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
}

repo_hooks_git_root() {
  deployed_git_repo root || return 1
  want='bash "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"/.shared/hooks/check.sh'
  for path in $REPO_HOOK_FILES; do
    [ -f "$REPO/$path" ] || { why="$path was not written"; return 1; }
    got="$(marked_commands "$REPO/$path" PreToolUse)"
    [ "$got" = "$want" ] || { why="$path names the script as: $got"; return 1; }
  done
}

repo_hooks_subfolder() {
  deployed_git_repo sub || return 1
  for path in $REPO_HOOK_FILES; do
    # The whole placed command, its mark line included, as the agent runs it.
    command="$(python3 - "$REPO/$path" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
found = [hook["command"] for group in data.get("hooks", {}).get("PreToolUse", []) for hook in group.get("hooks", [])
         if hook.get("command", "").rsplit("\n", 1)[-1].startswith("# agent-shared")]
print(found[0] if found else "")
PY
)"
    [ -n "$command" ] || { why="$path has no marked hook"; return 1; }
    for dir in "$REPO" "$REPO/src"; do
      (cd "$dir" && sh -c "$command") > /dev/null 2>&1
      code=$?
      [ "$code" = 2 ] || { why="the hook of $path exited $code in ${dir#"$T/"}, not the script's 2"; return 1; }
    done
  done
}

remove_all() {
  fresh remove-all
  mkdir -p "$HOME/.copilot"
  copilot_installed
  full_source removed
  run deploy --source "$SRC"
  [ "$rc" = 0 ] || { why="deploy exited $rc: $(tail -1 "$T/out")"; return 1; }
  links_to "$HOME/.claude/skills/delta" "$SRC/skills/delta" && grep -qF "$SRC/hooks/check.sh" "$HOME/.claude/settings.json" \
    || { why="the source was not placed before removing it"; return 1; }
  rm -rf "$SRC"
  run remove --source "$SRC"
  [ "$rc" = 0 ] || { why="remove exited $rc: $(tail -1 "$T/out")"; return 1; }
  python3 - "$HOME" "$SRC" <<'PY' || { why="$(cat "$T/remove.why")"; return 1; }
import json, os, sys
home, src = sys.argv[1:]
def fail(reason):
    open(os.environ["T"] + "/remove.why", "w").write(reason)
    sys.exit(1)
for folder in (".claude/skills", ".agents/skills", ".claude/rules"):
    for name in os.listdir(os.path.join(home, folder)):
        place = os.path.join(home, folder, name)
        if os.path.islink(place) and os.readlink(place).startswith(src):
            fail("%s still links into the removed source" % place)
for path in (".codex/AGENTS.md", ".copilot/copilot-instructions.md"):
    if "Rule three." in open(os.path.join(home, path)).read():
        fail("the rule of the removed source is still in %s" % path)
    if "Rule one." not in open(os.path.join(home, path)).read():
        fail("the rule of ~/.shared is gone from %s" % path)
for path in (".claude/settings.json", ".codex/hooks.json", ".copilot/hooks/agent-shared.json"):
    text = open(os.path.join(home, path)).read()
    if "check.sh" in text or "source-stop" in text:
        fail("a hook of the removed source is still in %s" % path)
    if "guard.sh" not in text:
        fail("the hooks of ~/.shared are gone from %s" % path)
if "echo mine" not in open(os.path.join(home, ".claude/settings.json")).read():
    fail("the hand-written hook is gone")
if not os.path.islink(os.path.join(home, ".claude/skills/alpha")):
    fail("the skill of ~/.shared is gone")
place = os.path.join(home, ".codex/hooks.json")
data = json.load(open(place))
marked = {"%s:%s:%d:%d" % (place, e, gi, hi) for e, groups in data["hooks"].items() for gi, g in enumerate(groups)
          for hi, h in enumerate(g["hooks"]) if "\n" in h["command"] and h["command"].rsplit("\n", 1)[1].startswith("# agent-shared")}
log = os.path.join(home, "codex-calls.jsonl")
writes = [json.loads(l) for l in open(log) if '"config/batchWrite"' in l]
trusted = {k for k, v in writes[-1]["params"]["edits"][0]["value"].items() if isinstance(v, dict) and v.get("trusted_hash")}
if trusted != marked:
    fail("Codex trusts %s after remove, while the hooks left are %s" % (sorted(trusted), sorted(marked)))
PY
}

readmes_definition() {
  local f word
  for f in README.md README.ja.md; do
    grep -qF '](spec/agent-shared' "$ROOT/$f" || { why="$f does not link the definition"; return 1; }
    for word in 'agent-shared check' 'agent-shared approve' 'agent-shared remove'; do
      grep -qF "$word" "$ROOT/$f" || { why="$f does not describe $word"; return 1; }
    done
  done
}

pyproject_url() {
  grep -qF 'Repository = "https://github.com/cardene777/agent-shared"' "$PKG/pyproject.toml" \
    || { why="pyproject.toml names another repository: $(grep -F 'Repository' "$PKG/pyproject.toml")"; return 1; }
}

# The icon keeps the dark rounded square of agent-shuriken's icon, so the two read as one family.
icon_present() {
  local icon="$ROOT/assets/icon.svg"
  [ -f "$icon" ] || { why="assets/icon.svg is missing"; return 1; }
  grep -qF 'viewBox="0 0 256 256"' "$icon" || { why="assets/icon.svg is not a 256 by 256 square"; return 1; }
  grep -qF 'rx="56" fill="#151a22"' "$icon" || { why="assets/icon.svg lacks the dark rounded square"; return 1; }
}

readmes_show_icon() {
  local f
  for f in README.md README.ja.md; do
    sed -n '/^## /q;p' "$ROOT/$f" | grep -qF 'src="assets/icon.svg"' \
      || { why="$f does not show assets/icon.svg before its first section"; return 1; }
  done
}

# The repository is public, so installing it needs no sign-in.
readmes_name_no_sign_in() {
  ! grep -n -i -E 'private|sign-in|sign in' "$ROOT/README.md" > "$T/words" || { why="README.md:$(head -1 "$T/words")"; return 1; }
  ! grep -n -E '非公開|ログイン' "$ROOT/README.ja.md" > "$T/words" || { why="README.ja.md:$(head -1 "$T/words")"; return 1; }
}

readmes_install_here() {
  local f
  for f in README.md README.ja.md; do
    grep -qF 'uv tool install "git+https://github.com/cardene777/agent-shared"' "$ROOT/$f" \
      || { why="$f does not install from cardene777/agent-shared"; return 1; }
  done
}

check "uv tool install puts agent-shared on PATH without any plugin" uv_installs
check "deploy links every skill into the Claude Code and shared agent folders" links_skills
check "deploy places nothing in the deprecated Codex skills folder" no_codex_skills
check "deploy writes rules as links for Claude Code and one block for Codex" writes_rules
check "deploy adds marked hooks and keeps the other settings" adds_hooks
check "deploy writes Codex trust for the hooks it placed" trusts_codex_hooks
check "without codex the run prints how to trust hooks in Codex" without_codex
check "deploy installs the Codex plugins plugins.json names" installs_named_plugins
check "deploy registers a missing marketplace from plugins.json" registers_missing_market
check "deploy trusts every hook of the named Codex plugins" trusts_named_plugin_hooks
check "deploy trusts a named plugin's changed hook again" retrusts_changed_hook
check "a plugin taken off plugins.json keeps its install and trust" keeps_taken_off
check "a plugins.json outside ~/.shared is not read and is named in a warning" outside_plugins_not_read
check "without codex the run names the plugins left untrusted" without_codex_names_plugins
check "check refuses a plugins.json of the wrong shape" check_refuses_plugins
check "deploy leaves the hooks of unnamed plugins untrusted" leaves_unnamed_plugins
check "the definition and the READMEs describe plugins.json" definition_plugins_json
check "deploy in a repository links its skills into its own folders" repo_skills
check "a removed skill, rule, or hook is taken out on the next run" removes_taken_out
check "entries without the mark are left unchanged" leaves_unmarked
check "a skill an installed plugin already has is not placed for that agent" skips_plugin_skills
check "two sources with the same skill name are refused" refuses_same_name
check "a hand-written hook with a declared command is refused" refuses_hand_hook
check "a row in the user's table adds an agent" user_row
check "the record of placed items is kept readable only by the user" private_record
check "hooks prints the groups deploy adds for an agent" hooks_match_deploy
check "hooks leaves out a hook whose tools name another agent" hooks_by_tools
check "hooks includes the hooks of every source" hooks_every_source
check "hooks writes nothing" hooks_write_nothing
check "hooks refuses an agent the table does not have" hooks_unknown_agent
check "hooks refuses a call without --agent" hooks_need_agent
check "placed lists what a source placed for each agent" placed_lists
check "placed prints each hook without the mark" placed_hook_shape
check "placed leaves out what another source placed" placed_other_source
check "placed leaves out a skill a plugin already has" placed_plugin_skill
check "placed counts only what still carries the mark" placed_marked_only
check "placed writes nothing" placed_write_nothing
check "placed prints empty lists for a source never deployed" placed_never_deployed
check "placed refuses a hook file it cannot read" placed_bad_hook_file
check "placed refuses a broken rules block" placed_broken_block
check "placed refuses a call without an existing source" placed_needs_source
check "off and on write one entry of off.json beside the record" off_on_write
check "off.json is kept readable only by the user" private_off_list
check "off refuses a path the source lacks and an agent the table lacks" off_refuses_unknown
check "deploy leaves a switched-off rule out of one agent and keeps it in the other" off_rule_one_agent
check "deploy leaves every command that runs a switched-off hook file out of one agent" off_hook_file
check "deploy leaves a switched-off command that runs no file out of one agent" off_command
check "the list leaves out only the named source's item" off_named_source_only
check "a switched-off item placed before is taken out and comes back after on" off_then_on
check "hooks leaves out what the list switched off" hooks_off
check "placed names what the list left out for each agent" placed_left_out
check "an unreadable off.json refuses deploy, hooks, and placed" off_unreadable
check "the README and the help describe off.json" off_documented
check "the icon is a square SVG in assets" icon_present
check "both READMEs show the icon at the top" readmes_show_icon
check "the READMEs name no sign-in or private repository" readmes_name_no_sign_in
check "the READMEs install from this repository" readmes_install_here
check "deploy writes rules in one block of Copilot CLI's instructions" copilot_rules
check "deploy writes marked hooks for Copilot CLI in a file of version 1" copilot_hooks
check "a removed rule or hook is taken out of Copilot CLI on the next run" copilot_removes
check "placed lists the rules and hooks placed for Copilot CLI" copilot_placed
check "deploy writes nothing for Copilot CLI without ~/.copilot" copilot_absent
check "deploy leaves the other Copilot CLI hook files unchanged" copilot_other_hook_files
check "the READMEs name where Copilot CLI's rules and hooks go" readmes_name_copilot
check "the definition pair has the same headings, tables, and examples" definition_pair
check "the definition has every section and a dated version" definition_sections
check "every row of the agent table lists its events and checked versions" table_rows
check "check passes the example source folder" check_example
check "check refuses wrong declarations naming the file and the entry" check_refuses
check "deploy places the example where the definition says" example_deploy
check "a hook with an event an agent lacks is left out of that agent and named" missing_event
check "a source not approved gets no hooks and is named" unapproved_source
check "approve prints the commands and lets the next deploy write them" approve_then_deploy
check "a source placed before and ~/.shared keep their hooks without approval" approved_before
check "deploy writes a repository's rules in one block of its AGENTS.md" repo_rules
check "deploy writes a repository's hooks into each agent's repository settings" repo_hooks
check "a repository's hook commands name .shared from the git root for every agent" repo_hooks_git_root
check "a repository's hook run from a subfolder exits with its script's own code" repo_hooks_subfolder
check "remove takes out everything one source placed, also after its folder is gone" remove_all
check "the READMEs link the definition and describe check, approve, and remove" readmes_definition
check "pyproject names this repository" pyproject_url
check "deploy writes nothing for Copilot CLI with only an IDE plugin's folder" copilot_ide_only
check "a skipped Copilot CLI row loses what was placed and keeps the person's own" copilot_skipped_cleanup
check "the definition and the READMEs name needs_command for Copilot CLI" definition_names_needs_command
check "a removed hook file takes its emptied folder with it" emptied_hooks_folder
check "taking out the last skill link removes its emptied folder" emptied_skill_folder
check "remove leaves no empty folder in the repository" remove_repo_folders
check "removing ~/.shared keeps the folders right under the home folder" remove_home_source
check "the READMEs say which agents see an edit at once and which on the next deploy" readmes_edit_reach
check "the READMEs name every command that writes off.json" readmes_off_writers
check "a folder holding the person's file stays" person_file_folder
check "the definition and the READMEs say emptied folders are removed" definition_emptied_folders
check "deploy writes nothing for an agent older than its checked versions" version_older
check "deploy writes an agent newer than its checked versions and names it" version_newer
check "deploy writes an agent whose version cannot be read and says so" version_unreadable
check "deploy writes an agent inside its checked versions without a version line" version_inside
check "the definition and the READMEs say which versions stop the writes" definition_versions
check "the two Agent Plugins proposals have the parts the contributing guide asks for" proposals_parts
check "each proposal names the clients it ran on and links the definition" proposals_evidence
check "each proposal names the Discussion it was posted as, its related threads, and the AI line" proposals_posted
check "the definition relates itself to Agent Plugins v1.1" definition_v11

printf '%d passed, %d failed (%d ran)\n' "$PASS" "$FAIL" "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
