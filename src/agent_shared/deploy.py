"""Plans and writes what agent-shared places in each agent, and reads back what a source placed.

A source is a folder with the `.shared` layout: `skills/<name>/SKILL.md`, `rules/*.md`, and
`hooks.json` (the `hooks` object of Claude Code's settings). The agent table says where each agent
keeps skills, rules, and hooks. Every run first plans the whole change and checks it; when anything
must be refused, nothing is written.

What agent-shared placed is told apart from what the user wrote by hand in three ways:

  skill and rule links  the record (`placed.json`) names each link and the target it was given
  the rules block       `<!-- agent-shared begin source=<id> -->` ... `<!-- agent-shared end source=<id> -->`
  hooks                 the command's last line is `# agent-shared 1 source=<id>`, a shell comment

`<id>` is the first 12 hex digits of the SHA-256 of the source folder's real path, so each source
removes only what it placed itself.

The switch list (`off.json`, beside the record) names the items that are not placed in one agent: a
source folder, an agent, and an item of that source. The item is a rule file (`rules/<name>.md`), a file
that hook commands run (`hooks/...`), or a whole hook command that runs no file. Every command, every
run, reads it, so an item stays out of that agent whichever tool deploys.
"""

import hashlib
import json
import os
import queue
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import tomllib
from importlib import resources

MARK = "# agent-shared 1 source="
BEGIN = "<!-- agent-shared begin source={} -->"
END = "<!-- agent-shared end source={} -->"
RULE = "<!-- agent-shared rule {} -->"
MARK_LINE_START = "<!-- agent-shared "
TABLE_VERSION = 1
RECORD_VERSION = 1
OFF_VERSION = 1
ROOT_PLACEHOLDER = "${CLAUDE_PLUGIN_ROOT}"
# What a repository's hooks name in place of ROOT_PLACEHOLDER. The agents run a hook in the folder they were
# started in, which may be below the repository root, so the command finds .shared from the git root, and from
# the working folder outside a git work tree.
REPO_HOOK_ROOT = '"$(git rev-parse --show-toplevel 2>/dev/null || pwd)"/.shared'
# What may come right before or after a file's path inside a command, so `hooks/a.sh` is not found in
# `hooks/a.sh.orig` or in `other/hooks/a.sh`.
PATH_CHARACTER = r"[\w./-]"
CODEX_TIMEOUT = 30
# Registering a marketplace clones it, so a codex plugin command gets longer than one app-server answer.
PLUGIN_COMMAND_TIMEOUT = 600
RULE_FORMS = ("link", "block")
TRUST_KINDS = ("codex-app-server",)
PLUGIN_KINDS = ("claude", "codex")


class Refused(Exception):
    """The run must not write anything. `lines` names each reason."""

    def __init__(self, lines):
        super().__init__("\n".join(lines))
        self.lines = lines


class Usage(Exception):
    """The command line, a source folder, the agent table, or the record cannot be used."""


class TrustFailed(Exception):
    """Codex could not be asked to trust the hooks. The text is the reason."""


def home():
    return os.path.expanduser("~")


def expand(path):
    return os.path.abspath(os.path.expanduser(path))


def shown(path):
    """The path as printed: the home folder is written as `~`."""
    top = home()
    if path == top:
        return "~"
    if path.startswith(top + os.sep):
        return "~" + path[len(top):]
    return path


def source_id(path):
    return hashlib.sha256(os.path.realpath(path).encode("utf-8")).hexdigest()[:12]


def read_json(path, what):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, UnicodeError, ValueError) as error:
        raise Usage("{} {} cannot be read as JSON ({})".format(what, shown(path), error))


def skill_names(folder):
    """The names of the folders under `folder` that hold a SKILL.md, in name order."""
    if not os.path.isdir(folder):
        return []
    return [name for name in sorted(os.listdir(folder))
            if not name.startswith(".") and os.path.isfile(os.path.join(folder, name, "SKILL.md"))]


class Source:
    """A folder with the `.shared` layout."""

    def __init__(self, path):
        self.path = os.path.abspath(path)
        self.id = source_id(self.path)

    def skills(self):
        base = os.path.join(self.path, "skills")
        return {name: os.path.join(base, name) for name in skill_names(base)}

    def rules(self):
        base = os.path.join(self.path, "rules")
        if not os.path.isdir(base):
            return {}
        return {name: os.path.join(base, name) for name in sorted(os.listdir(base))
                if name.endswith(".md") and not name.startswith(".") and os.path.isfile(os.path.join(base, name))}

    def hooks(self, agent_names, root=None):
        """The declared hooks as (event, group without hooks, hook, tools) with the source folder filled in,
        or `root` in its place (a repository's hooks name `.shared` from the repository's git root).
        `tools` is the set of agent names the hook goes to, or None for every agent."""
        path = os.path.join(self.path, "hooks.json")
        if not os.path.exists(path):
            return []
        data = read_json(path, "the hook declaration")
        events = data.get("hooks") if isinstance(data, dict) else None
        if not isinstance(events, dict):
            raise Usage("{} has no `hooks` object that maps events to lists of groups".format(shown(path)))
        declared = []
        for event, groups in events.items():
            if not isinstance(groups, list) or not all(isinstance(group, dict) for group in groups):
                raise Usage("`hooks.{}` in {} is not a list of groups".format(event, shown(path)))
            for group in groups:
                hooks = group.get("hooks")
                if not isinstance(hooks, list) or not hooks:
                    raise Usage("a group of `hooks.{}` in {} has no list of hooks".format(event, shown(path)))
                bare = {key: value for key, value in group.items() if key != "hooks"}
                for hook in hooks:
                    if not isinstance(hook, dict) or not isinstance(hook.get("command"), str):
                        raise Usage("a hook of `hooks.{}` in {} has no command string".format(event, shown(path)))
                    hook = dict(hook, command=hook["command"].replace(ROOT_PLACEHOLDER, root or self.path))
                    tools = hook.pop("tools", None)
                    if tools is not None:
                        if not isinstance(tools, list) or not tools or not all(isinstance(t, str) for t in tools):
                            raise Usage("the `tools` of a hook of `hooks.{}` in {} is not a list of agent names"
                                        .format(event, shown(path)))
                        unknown = sorted(set(tools) - set(agent_names))
                        if unknown:
                            raise Usage("a hook of `hooks.{}` in {} names agents that are not in the table: {}"
                                        .format(event, shown(path), ", ".join(unknown)))
                        tools = frozenset(tools)
                    declared.append((event, bare, hook, tools))
        return declared


def load_table(user_table):
    """The agent table: the default rows, with the rows of the user's table replacing or adding rows by name."""
    default = json.loads(resources.files("agent_shared").joinpath("agents.json").read_text(encoding="utf-8"))
    rows = checked_rows(default, "the default agent table")
    if user_table and os.path.exists(user_table):
        for row in checked_rows(read_json(user_table, "the agent table"), shown(user_table)):
            names = [existing["name"] for existing in rows]
            if row["name"] in names:
                rows[names.index(row["name"])] = row
            else:
                rows.append(row)
    return rows


def rules_problem(value):
    return not (isinstance(value, dict) and isinstance(value.get("place"), str) and value.get("form") in RULE_FORMS)


def hooks_problem(value):
    return not (isinstance(value, dict) and isinstance(value.get("file"), str)
                and value.get("trust", TRUST_KINDS[0]) in TRUST_KINDS
                and ("version" not in value or type(value["version"]) is int))


def row_problem(row):
    """What is wrong with one row of an agent table, or None."""
    if not isinstance(row, dict) or not isinstance(row.get("name"), str) or not row["name"]:
        return "the row has no name"
    name = row["name"]
    for key in ("skills", "needs", "repo_skills"):
        if key in row and not isinstance(row[key], str):
            return "the {} of {} is not a path".format(key, name)
    if "needs_command" in row and not (isinstance(row["needs_command"], str) and row["needs_command"]):
        return "the needs_command of {} is not a command name".format(name)
    for key in ("rules", "repo_rules"):
        if key in row and rules_problem(row[key]):
            return "the {} of {} need a place and a form ({})".format(key, name, " or ".join(RULE_FORMS))
    for key in ("hooks", "repo_hooks"):
        if key in row and hooks_problem(row[key]):
            return "the {} of {} need a file, and a version that is a whole number".format(key, name)
    if "events" in row and not (isinstance(row["events"], list) and row["events"]
                                and all(isinstance(event, str) and event for event in row["events"])):
        return "the events of {} are not a list of event names".format(name)
    if "checked" in row and not (isinstance(row["checked"], dict)
                                 and all(isinstance(row["checked"].get(key), str) for key in ("from", "to"))):
        return "the checked versions of {} need from and to".format(name)
    if "plugins" in row and row["plugins"] not in PLUGIN_KINDS:
        return "the plugins of {} is not one of {}".format(name, ", ".join(PLUGIN_KINDS))
    return None


def table_problem(table):
    if not isinstance(table, dict) or table.get("version") != TABLE_VERSION or not isinstance(table.get("agents"), list):
        return "it is not an agent table of version {} with an `agents` list".format(TABLE_VERSION)
    return None


def checked_rows(table, where):
    problem = table_problem(table)
    if problem:
        raise Usage("{}: {}".format(where, problem))
    for row in table["agents"]:
        problem = row_problem(row)
        if problem:
            raise Usage("{}: {}".format(where, problem))
    return list(table["agents"])


def claude_plugin_skills(warnings):
    """{skill name: plugin} for the plugins installed in Claude Code and not turned off."""
    base = os.path.join(home(), ".claude")
    installed = os.path.join(base, "plugins", "installed_plugins.json")
    if not os.path.exists(installed):
        return {}
    try:
        data = read_json(installed, "Claude Code's plugin list")
        settings = os.path.join(base, "settings.json")
        enabled = (read_json(settings, "Claude Code's settings") if os.path.exists(settings) else {}).get("enabledPlugins") or {}
    except Usage as error:
        warnings.append("{}; skills were placed for Claude Code without checking its plugins".format(error))
        return {}
    found = {}
    for key, entries in (data.get("plugins") or {}).items():
        if enabled.get(key) is False or not isinstance(entries, list):
            continue
        for entry in entries:
            install = entry.get("installPath") if isinstance(entry, dict) else None
            if isinstance(install, str):
                for name in skill_names(os.path.join(install, "skills")):
                    found.setdefault(name, key)
    return found


def codex_plugin_skills(warnings):
    """{skill name: plugin} for the plugins turned on in Codex's config.toml."""
    config = os.path.join(home(), ".codex", "config.toml")
    if not os.path.exists(config):
        return {}
    try:
        with open(config, "rb") as handle:
            data = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        warnings.append("{} cannot be read ({}); skills were placed for Codex without checking its plugins"
                        .format(shown(config), error))
        return {}
    cache = os.path.join(home(), ".codex", "plugins", "cache")
    found = {}
    for key, table in (data.get("plugins") or {}).items():
        if not isinstance(table, dict) or table.get("enabled") is not True:
            continue
        name, _, market = key.partition("@")
        base = os.path.join(cache, market, name)
        for version in sorted(os.listdir(base)) if os.path.isdir(base) else []:
            for skill in skill_names(os.path.join(base, version, "skills")):
                found.setdefault(skill, key)
    return found


PLUGIN_LIST = "plugins.json"


def plugin_list(path):
    """Reads the plugin list `plugins.json` at `path`: the Codex plugins whose hooks the person trusts, and the git
    URL of each of their marketplaces. Returns ({"marketplaces": {name: url}, "plugins": [id]}, problems), with
    each problem written as `<entry>: <problem>` and the list None when there is a problem."""
    try:
        data = read_json(path, "the plugin list")
    except Usage as error:
        return None, ["{}".format(error)]
    if not isinstance(data, dict):
        return None, ["plugins: the file holds no JSON object"]
    codex = data.get("codex", {})
    if not isinstance(codex, dict):
        return None, ["codex: holds no object of `marketplaces` and `plugins`"]
    markets = codex.get("marketplaces", {})
    plugins = codex.get("plugins", [])
    problems = []
    if not isinstance(markets, dict):
        problems.append("codex.marketplaces: holds no object that maps a marketplace to its git URL")
        markets = {}
    for name, url in markets.items():
        if not isinstance(url, str) or not url.strip():
            problems.append("codex.marketplaces.{}: the marketplace {} has no git URL".format(name, name))
    if not isinstance(plugins, list):
        problems.append("codex.plugins: holds no list of plugins")
        plugins = []
    for index, plugin in enumerate(plugins):
        name, at, market = plugin.partition("@") if isinstance(plugin, str) else ("", "", "")
        if not (name and at and market) or "@" in market:
            problems.append("codex.plugins[{}]: {} is not written as <plugin>@<marketplace>".format(index, plugin))
        elif market not in markets:
            problems.append("codex.plugins[{}]: the marketplace {} of {} is not in codex.marketplaces"
                            .format(index, market, plugin))
    if problems:
        return None, problems
    return {"marketplaces": dict(markets), "plugins": list(dict.fromkeys(plugins))}, []


def state_folder():
    """The folder of the record and the switch list: `AGENT_SHARED_STATE`, or ~/.local/share/agent-shared."""
    folder = os.environ.get("AGENT_SHARED_STATE") or os.path.join(home(), ".local", "share", "agent-shared")
    return os.path.abspath(os.path.expanduser(folder))


def write_private(folder, path, data, prefix):
    """Replaces the JSON file in one step, readable only by the user, in a folder only the user can open."""
    os.makedirs(folder, exist_ok=True)
    os.chmod(folder, 0o700)
    text = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    handle, temporary = tempfile.mkstemp(dir=folder, prefix=prefix)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(text)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def runs_file(command, source, item):
    """Whether the hook command, with the source folder filled in, runs the file `item` of the source."""
    place = re.escape(os.path.join(source.path, item))
    return re.search("(?<!{0}){1}(?!{0})".format(PATH_CHARACTER, place), command) is not None


def is_command(command, source, item):
    """Whether `item` is the whole hook command, as declared with `${CLAUDE_PLUGIN_ROOT}` or filled in."""
    return item.replace(ROOT_PLACEHOLDER, source.path) == command


class OffList:
    """The switch list: the items one agent does not get from a source, kept in `off.json`."""

    def __init__(self):
        self.folder = state_folder()
        self.path = os.path.join(self.folder, "off.json")
        self.entries = []
        if os.path.exists(self.path):
            data = read_json(self.path, "the switch list")
            entries = data.get("off") if isinstance(data, dict) and data.get("version") == OFF_VERSION else None
            if not isinstance(entries, list) or not all(
                    isinstance(entry, dict) and all(isinstance(entry.get(key), str) for key in ("source", "agent", "item"))
                    for entry in entries):
                raise Usage("the switch list {} is not of version {} with an `off` list of source, agent, and item; "
                            "fix it or move it away".format(shown(self.path), OFF_VERSION))
            self.entries = entries
        self.ids = [source_id(entry["source"]) for entry in self.entries]

    def items(self, source, agent_name):
        """The items of the source switched off for the agent, in name order."""
        return sorted({entry["item"] for entry, sid in zip(self.entries, self.ids)
                       if sid == source.id and entry["agent"] == agent_name})

    def rule_off(self, source, agent_name, name):
        return "rules/" + name in self.items(source, agent_name)

    def hook_off(self, source, agent_name, command):
        return any(is_command(command, source, item) or runs_file(command, source, item)
                   for item in self.items(source, agent_name))

    def forget(self, ids):
        """Takes out every entry of the sources `ids`, for a source taken out of every agent."""
        kept = [(entry, sid) for entry, sid in zip(self.entries, self.ids) if sid not in ids]
        if len(kept) == len(self.entries):
            return
        self.entries, self.ids = [pair[0] for pair in kept], [pair[1] for pair in kept]
        write_private(self.folder, self.path, {"version": OFF_VERSION, "off": self.entries}, ".off-")

    def switch(self, source, agent_name, item, on):
        """Takes the item out of the list (on) or adds it once (off). Returns whether the list changed."""
        here = [i for i, (entry, sid) in enumerate(zip(self.entries, self.ids))
                if sid == source.id and entry["agent"] == agent_name and entry["item"] == item]
        if on and here:
            self.entries = [entry for i, entry in enumerate(self.entries) if i not in here]
        elif not on and not here:
            self.entries.append({"source": source.path, "agent": agent_name, "item": item})
        else:
            return False
        write_private(self.folder, self.path, {"version": OFF_VERSION, "off": self.entries}, ".off-")
        return True


class Record:
    """What agent-shared placed, per source: each link and the target it was given."""

    def __init__(self):
        self.folder = state_folder()
        self.path = os.path.join(self.folder, "placed.json")
        self.sources = {}
        if os.path.exists(self.path):
            data = read_json(self.path, "the record")
            if not isinstance(data, dict) or data.get("version") != RECORD_VERSION or not isinstance(data.get("sources"), dict):
                raise Usage("the record {} is not of version {}; move it away to start a new record"
                            .format(shown(self.path), RECORD_VERSION))
            self.sources = data["sources"]

    def links(self, ids):
        return {place: target for sid in ids for place, target in (self.sources.get(sid) or {}).get("links", {}).items()}

    def owner(self, place):
        for sid, entry in self.sources.items():
            if place in entry.get("links", {}):
                return sid, entry
        return None, None

    def approved(self, source):
        """Whether the person approved the source's hooks. ~/.shared is the person's own, and a source the record
        held before approvals existed carries no `approved` field and was placed by the person before."""
        if source.path == os.path.join(home(), ".shared"):
            return True
        entry = self.sources.get(source.id)
        return entry is not None and entry.get("approved", True) is True

    def save(self, sources, links_by_source):
        for source in sources:
            links = links_by_source.get(source.id, {})
            approved = self.approved(source)
            if links or approved:
                self.sources[source.id] = {"path": source.path, "links": dict(sorted(links.items())), "approved": approved}
            else:
                self.sources.pop(source.id, None)
        self.write()

    def approve(self, source):
        entry = self.sources.setdefault(source.id, {"path": source.path, "links": {}})
        entry["approved"] = True
        self.write()

    def forget(self, ids):
        for sid in ids:
            self.sources.pop(sid, None)
        self.write()

    def write(self):
        write_private(self.folder, self.path, {"version": RECORD_VERSION, "sources": self.sources}, ".placed-")


def find_repo(argument):
    """The repository whose `.shared` is deployed: the named one, or the one that holds the current folder."""
    if argument:
        root = expand(argument)
        if not os.path.isdir(os.path.join(root, ".shared")):
            raise Usage("{} has no .shared folder".format(shown(root)))
        return root
    here, top = os.getcwd(), home()
    while True:
        if os.path.exists(os.path.join(here, ".git")):
            return here if here != top and os.path.isdir(os.path.join(here, ".shared")) else None
        parent = os.path.dirname(here)
        if parent == here:
            return None
        here = parent


def still_placed(place, target):
    """Whether `place` is still the link agent-shared placed there, pointing at the target it was given."""
    return os.path.islink(place) and os.readlink(place) == target


def is_marked(hook, ids=None):
    """Whether agent-shared placed the hook, from any source or from one of `ids`."""
    command = hook.get("command") if isinstance(hook, dict) else None
    if not isinstance(command, str) or "\n" not in command:
        return False
    last = command.rsplit("\n", 1)[1]
    return last.startswith(MARK) and (ids is None or last[len(MARK):] in ids)


def read_agent_json(path, refusals):
    """An agent's JSON settings, {} when the file does not exist, or None after adding a refusal."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, UnicodeError, ValueError) as error:
        refusals.append("{} cannot be read as JSON ({})".format(shown(path), error))
        return None
    hooks = data.get("hooks", {}) if isinstance(data, dict) else None
    if not isinstance(hooks, dict) or not all(isinstance(groups, list) for groups in hooks.values()):
        refusals.append("{} has a `hooks` value that is not a map of events to lists".format(shown(path)))
        return None
    return data


def with_hooks(data, ids, groups_by_event):
    """The settings with the hooks of the sources `ids` taken out and the declared groups added at the end."""
    data = json.loads(json.dumps(data))
    events = data.get("hooks")
    if events is None:
        if not groups_by_event:
            return data
        events = data["hooks"] = {}
    emptied = False
    for event in list(events):
        kept_groups = []
        for group in events[event]:
            inner = group.get("hooks", []) if isinstance(group, dict) else []
            kept = [hook for hook in inner if not is_marked(hook, ids)]
            if isinstance(group, dict) and len(kept) != len(inner):
                if not kept:
                    continue
                group = dict(group, hooks=kept)
            kept_groups.append(group)
        if kept_groups or not events[event]:
            events[event] = kept_groups
        else:
            del events[event]
            emptied = True
    for event, groups in groups_by_event.items():
        events.setdefault(event, []).extend(groups)
    if not events and emptied:
        del data["hooks"]
    return data


def block_lines(lines, sid, where, refusals):
    """The (begin, end) line numbers of the source's block in a rules file, None when it has none."""
    begins = [i for i, line in enumerate(lines) if line.rstrip("\n") == BEGIN.format(sid)]
    ends = [i for i, line in enumerate(lines) if line.rstrip("\n") == END.format(sid)]
    if not begins and not ends:
        return None
    if len(begins) != 1 or len(ends) != 1 or ends[0] < begins[0]:
        refusals.append("the agent-shared block of {} is broken; remove its marker lines by hand".format(shown(where)))
        return None
    return begins[0], ends[0]


def rules_block(sid, rules):
    out = [BEGIN.format(sid) + "\n"]
    for name, path in rules:
        with open(path, encoding="utf-8") as handle:
            body = handle.read()
        out.append(RULE.format(name) + "\n")
        out.append(body if body.endswith("\n") else body + "\n")
    out.append(END.format(sid) + "\n")
    return "".join(out)


def write_text(path, text):
    """Replaces the file's text in one step and keeps its mode."""
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=folder, prefix=".agent-shared-")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(text)
        if os.path.exists(path):
            shutil.copymode(path, temporary)
        else:
            os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


class CodexServer:
    """Talks to `codex app-server` with one JSON message per line, reading the settings in `codex_home`."""

    def __init__(self, command, codex_home):
        env = dict(os.environ, CODEX_HOME=codex_home)
        try:
            self.proc = subprocess.Popen([command, "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, text=True, env=env, cwd=codex_home)
        except OSError as error:
            raise TrustFailed("Codex could not be started ({})".format(error.strerror or error))
        self.lines = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def send(self, message):
        try:
            self.proc.stdin.write(json.dumps(message) + "\n")
            self.proc.stdin.flush()
        except OSError:
            raise TrustFailed("Codex stopped before {}".format(message.get("method")))

    def call(self, method, params):
        self.next_id += 1
        request_id = self.next_id
        self.send({"id": request_id, "method": method, "params": params})
        while True:
            try:
                line = self.lines.get(timeout=CODEX_TIMEOUT)
            except queue.Empty:
                raise TrustFailed("{} got no answer in {} seconds".format(method, CODEX_TIMEOUT))
            if line is None:
                raise TrustFailed("Codex stopped before answering {}".format(method))
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if message.get("id") != request_id:
                continue
            if "error" in message:
                error = message["error"]
                raise TrustFailed("{} returned an error ({})".format(
                    method, error.get("message") if isinstance(error, dict) else error))
            return message.get("result") or {}

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except (OSError, subprocess.SubprocessError):
            self.proc.kill()


def codex_command():
    """The codex command to run, or None when it is not on PATH."""
    name = os.environ.get("AGENT_SHARED_CODEX_BIN", "codex")
    return shutil.which(name) if name else None


def with_trusted(state, trusted):
    """A copy of Codex's trust state with `trusted` ({key: hash}) written as the trusted hash of each key."""
    wanted = {key: dict(entry) if isinstance(entry, dict) else entry for key, entry in state.items()}
    for key, digest in trusted.items():
        entry = wanted.get(key)
        wanted[key] = dict(entry if isinstance(entry, dict) else {}, trusted_hash=digest)
    return wanted


def codex_trust(codex_home, choose):
    """Asks `codex app-server` with the settings in `codex_home` for its hooks and its trust state, lets
    `choose(hooks, state)` return the wanted state, and writes it the way Codex's /hooks screen does when it differs.
    Returns the number of keys changed, or None when there is no codex command."""
    command = codex_command()
    if command is None:
        return None
    server = CodexServer(command, codex_home)
    try:
        server.call("initialize", {"clientInfo": {"name": "agent-shared", "version": "1"}})
        server.send({"method": "initialized"})
        hooks = [hook for group in server.call("hooks/list", {}).get("data") or [] for hook in group.get("hooks") or []]
        layers = server.call("config/read", {"includeLayers": True}).get("layers") or []
        user = next((layer for layer in layers if (layer.get("name") or {}).get("type") == "user"), {})
        state = ((user.get("config") or {}).get("hooks") or {}).get("state") or {}
        if not isinstance(state, dict):
            raise TrustFailed("Codex's hooks.state is not a map of keys")
        wanted = choose(hooks, state)
        if wanted == state:
            return 0
        params = {"edits": [{"keyPath": "hooks.state", "value": wanted, "mergeStrategy": "replace"}]}
        if user.get("version"):
            params["expectedVersion"] = user["version"]
        result = server.call("config/batchWrite", params)
        if result.get("status") != "ok":
            raise TrustFailed("config/batchWrite answered {}".format(result.get("status")))
        return sum(1 for key in set(wanted) | set(state) if wanted.get(key) != state.get(key))
    finally:
        server.close()


def trust_codex_hooks(place):
    """Asks Codex to trust the hooks agent-shared placed in `place` and to forget the trust of hooks no longer there.
    Returns the number of keys changed, or None when there is no codex command."""
    real = os.path.realpath(place)

    def choose(hooks, state):
        listed, marked = set(), {}
        for hook in hooks:
            if hook.get("source") != "user" or hook.get("pluginId") or not hook.get("key"):
                continue
            if os.path.realpath(hook.get("sourcePath") or "") != real:
                continue
            listed.add(hook["key"])
            if is_marked({"command": hook.get("command")}) and hook.get("currentHash"):
                marked[hook["key"]] = hook["currentHash"]
        wanted = with_trusted(state, marked)
        for key in list(wanted):
            if os.path.realpath(key.rsplit(":", 3)[0]) == real and key not in listed:
                del wanted[key]
        return wanted

    return codex_trust(os.path.dirname(place), choose)


def trust_codex_plugin_hooks(plugin_ids):
    """Asks Codex to trust every hook of the installed plugins in `plugin_ids` for its current command. The trust of
    every other hook stays as it is. Returns the number of keys changed, or None when there is no codex command."""
    def choose(hooks, state):
        current = {hook["key"]: hook["currentHash"] for hook in hooks
                   if hook.get("pluginId") in plugin_ids and hook.get("key") and hook.get("currentHash")}
        return with_trusted(state, current)

    return codex_trust(os.path.join(home(), ".codex"), choose)


def run_codex(command, args):
    """Runs `codex <args>` with the settings in ~/.codex. Returns None when it worked, or the reason it did not."""
    env = dict(os.environ, CODEX_HOME=os.path.join(home(), ".codex"))
    try:
        done = subprocess.run([command] + args, stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env,
                              timeout=PLUGIN_COMMAND_TIMEOUT)
    except subprocess.TimeoutExpired:
        return "it did not end in {} seconds".format(PLUGIN_COMMAND_TIMEOUT)
    except OSError as error:
        return "{}".format(error.strerror or error)
    if done.returncode == 0:
        return None
    said = (done.stderr or done.stdout or "").strip().splitlines()
    return "it exited {}{}".format(done.returncode, ": " + said[0] if said else "")


def ensure_codex_plugins(listing, notes, warnings):
    """Registers the missing marketplaces of the plugin list in Codex, installs its plugins Codex does not have, and
    trusts every hook of its plugins for the current command. A plugin already installed is left as it is."""
    plugins = listing["plugins"]
    if not plugins:
        return
    named = ", ".join(plugins)
    command = codex_command()
    if command is None:
        warnings.append("Codex was not found, so the plugins {} are not installed or trusted yet. Install each with "
                        "`codex plugin add <plugin>@<marketplace>`, then open /hooks in Codex and trust their hooks."
                        .format(named))
        return
    codex_home = os.path.join(home(), ".codex")
    config = os.path.join(codex_home, "config.toml")
    try:
        with open(config, "rb") as handle:
            registered = set((tomllib.load(handle).get("marketplaces") or {}))
    except FileNotFoundError:
        registered = set()
    except (OSError, tomllib.TOMLDecodeError) as error:
        warnings.append("{} cannot be read ({}), so the plugins {} were not installed or trusted"
                        .format(shown(config), error, named))
        return
    failed = set()
    for market in sorted({plugin.partition("@")[2] for plugin in plugins} - registered):
        url = listing["marketplaces"][market]
        reason = run_codex(command, ["plugin", "marketplace", "add", url])
        if reason:
            failed.add(market)
            warnings.append("the Codex marketplace {} could not be registered from {} ({}); run "
                            "`codex plugin marketplace add {}`".format(market, url, reason, url))
        else:
            notes.append("registered the Codex marketplace {} from {}".format(market, url))
    for plugin in plugins:
        name, _, market = plugin.partition("@")
        if market in failed or os.path.isdir(os.path.join(codex_home, "plugins", "cache", market, name)):
            continue
        reason = run_codex(command, ["plugin", "add", plugin])
        if reason:
            warnings.append("the Codex plugin {} could not be installed ({}); run `codex plugin add {}`"
                            .format(plugin, reason, plugin))
        else:
            notes.append("installed the Codex plugin {}".format(plugin))
    try:
        changed = trust_codex_plugin_hooks(set(plugins))
    except TrustFailed as error:
        warnings.append("Codex's trust for the hooks of the plugins {} was not written ({}). Open /hooks in Codex "
                        "and trust their hooks.".format(named, error))
        return
    if changed:
        notes.append("wrote Codex's trust for the hooks of the plugins {}".format(named))


def existing_source(path):
    """The source folder named on the command line, which must exist."""
    path = expand(path)
    if not os.path.isdir(path):
        raise Usage("the source folder {} does not exist".format(shown(path)))
    return Source(path)


def user_sources(extra_sources):
    """~/.shared when it exists, then every --source folder once, in the order given."""
    main_path = os.path.join(home(), ".shared")
    sources = [Source(main_path)] if os.path.isdir(main_path) else []
    for path in extra_sources:
        source = existing_source(path)
        if source.id not in {known.id for known in sources}:
            sources.append(source)
    return sources


def agent_table():
    main_path = os.path.join(home(), ".shared")
    return load_table(os.path.join(main_path, "agents.json") if os.path.isdir(main_path) else None)


def row_present(row):
    """Whether the agent of a row is on this computer. An agent many people do not use waits for its own command on
    PATH (`needs_command`) or for a path (`needs`), so its files appear only where it is installed; a folder another
    product also makes, such as `~/.copilot` of a Copilot IDE plugin, does not tell."""
    if "needs_command" in row and shutil.which(row["needs_command"]) is None:
        return False
    return "needs" not in row or os.path.exists(expand(row["needs"]))


def version_key(text):
    return tuple(int(part) for part in text.split("."))


def agent_version(row):
    """The version the `checked` command of a row prints, as text, or None when the command is missing, fails, or
    prints no version."""
    try:
        done = subprocess.run(shlex.split(row["checked"]["command"]), capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=10)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    found = re.search(r"\d+(?:\.\d+)+", done.stdout) if done.returncode == 0 else None
    return found.group(0) if found else None


def version_check(row):
    """Compares the installed version of a row's agent with its `checked` range. Returns (hold, line): hold is True
    for a version older than `from`, which gets nothing written; line is the line the run prints, or None for a
    version inside the range and for a row without `checked`."""
    checked = row.get("checked")
    if not checked:
        return False, None
    version = agent_version(row)
    if version is None:
        return False, "could not read the version of {} from `{}`; wrote it as before".format(
            row["name"], checked["command"])
    width = max(len(version_key(text)) for text in (version, checked["from"], checked["to"]))
    key, low, high = (version_key(text) + (0,) * (width - len(version_key(text)))
                      for text in (version, checked["from"], checked["to"]))
    if key < low:
        return True, ("wrote nothing for {}: its version {} is older than {}, the lowest version agent-shared "
                      "checked; update {} and deploy again".format(row["name"], version, checked["from"], row["name"]))
    if key > high:
        return False, "{} {} is newer than {}, the highest version agent-shared checked; wrote it as before".format(
            row["name"], version, checked["to"])
    return False, None


def agent_places(row):
    """Where one agent of the table keeps what agent-shared places in the home folder: the skills folder
    (None for an agent that reads another row's folder), the rules place and form (None without rules),
    and the hook file (None without hooks)."""
    rules = row.get("rules")
    return (expand(row["skills"]) if "skills" in row else None,
            (expand(rules["place"]), rules["form"]) if rules else None,
            expand(row["hooks"]["file"]) if "hooks" in row else None)


def agent_hook_groups(declared, row, off):
    """The groups deploy adds to one agent's hook file, by event, the (event, command) pairs they carry, and
    the (event, command) pairs left out because the agent reads no such event.
    Each declared hook goes in its own copy of its group, with the source's mark on a last line of its command.
    A hook the switch list turns off for the agent is left out, and so is a hook whose event the row's
    `events` do not list; a row without `events` reads every event."""
    agent_name, events = row["name"], row.get("events")
    groups, commands, missing = {}, set(), []
    for source, event, bare, hook, tools in declared:
        if tools is not None and agent_name not in tools:
            continue
        if off.hook_off(source, agent_name, hook["command"]):
            continue
        if events is not None and event not in events:
            missing.append((event, hook["command"]))
            continue
        commands.add((event, hook["command"]))
        marked = dict(hook, command=hook["command"] + "\n" + MARK + source.id)
        groups.setdefault(event, []).append(dict(bare, hooks=[marked]))
    return groups, commands, missing


def hooks(agent_name, extra_sources):
    """Prints, as JSON, the hook groups deploy would add to the agent's hook file. Writes nothing. Returns 0."""
    sources = user_sources(extra_sources)
    if not sources:
        raise Usage("there are no hooks to print: create ~/.shared, or pass --source")
    table = agent_table()
    agent_names = [row["name"] for row in table]
    if agent_name not in agent_names:
        raise Usage("the agent {} is not in the agent table (agents: {})".format(agent_name, ", ".join(agent_names)))
    off = OffList()
    record = Record()
    row = next(row for row in table if row["name"] == agent_name)
    groups = {}
    if "hooks" in row:
        declared = [(source,) + hook for source in sources if record.approved(source) for hook in source.hooks(agent_names)]
        groups = agent_hook_groups(declared, row, off)[0]
    print(json.dumps({"hooks": groups}, ensure_ascii=False, indent=2))
    return 0


def linked_names(links, folder):
    """The names of the links in `folder` that a source placed and that still point at their target."""
    return sorted(os.path.basename(place) for place, target in links.items()
                  if os.path.dirname(place) == folder and still_placed(place, target))


def block_rule_names(path, sid, refusals):
    """The names of the rules in the source's block of a rules file, [] when the file or the block is missing."""
    if not os.path.exists(path):
        return []
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines(keepends=True)
    except (OSError, UnicodeError) as error:
        refusals.append("{} cannot be read ({})".format(shown(path), error))
        return []
    found = block_lines(lines, sid, path, refusals)
    if not found:
        return []
    head, tail = RULE.split("{}")
    names = [line.rstrip("\n") for line in lines[found[0] + 1:found[1]]]
    return sorted(line[len(head):len(line) - len(tail)] for line in names if line.startswith(head) and line.endswith(tail))


def marked_hooks(path, sid, refusals):
    """The hooks the source placed in an agent's hook file, in file order, each as its event, the group's
    matcher when it has one, and the command without the mark."""
    data = read_agent_json(path, refusals)
    if data is None:
        return []
    found = []
    for event, groups in data.get("hooks", {}).items():
        for group in groups:
            if not isinstance(group, dict):
                continue
            for hook in group.get("hooks", []):
                if is_marked(hook, {sid}):
                    entry = {"event": event}
                    if "matcher" in group:
                        entry["matcher"] = group["matcher"]
                    entry["command"] = hook["command"].rsplit("\n", 1)[0]
                    found.append(entry)
    return found


def placed(source_path):
    """Prints, as JSON, the skills, rules, and hooks one source placed in each agent of the table that are
    still there. Writes nothing. Returns 0."""
    source = existing_source(source_path)
    table = agent_table()
    links = Record().links({source.id})
    off = OffList()
    refusals, agents = [], {}
    for row in table:
        skills_dir, rules_at, hook_file = agent_places(row)
        rules = []
        if rules_at:
            place, form = rules_at
            rules = linked_names(links, place) if form == "link" else block_rule_names(place, source.id, refusals)
        agents[row["name"]] = {"skills": linked_names(links, skills_dir) if skills_dir else [], "rules": rules,
                               "hooks": marked_hooks(hook_file, source.id, refusals) if hook_file else []}
        # Only an agent the list names items for gets the key, so the shape stays as before without a list.
        left_out = off.items(source, row["name"])
        if left_out:
            agents[row["name"]]["left_out"] = left_out
    if refusals:
        raise Usage("; ".join(dict.fromkeys(refusals)))
    print(json.dumps({"source": source.path, "agents": agents}, ensure_ascii=False, indent=2))
    return 0


def switch(source_path, agent_name, item, on):
    """Turns one item of a source off or on for one agent in the switch list. Places nothing; the next
    deploy honors the list. Returns 0."""
    off = OffList()
    if on:
        source = Source(expand(source_path))
        changed = off.switch(source, agent_name, item, on=True)
        print("switched on {} for {} from {}{}".format(item, agent_name, shown(source.path),
                                                     "" if changed else " (it was not switched off)"))
        return 0
    source = existing_source(source_path)
    agent_names = [row["name"] for row in agent_table()]
    if agent_name not in agent_names:
        raise Usage("the agent {} is not in the agent table (agents: {})".format(agent_name, ", ".join(agent_names)))
    parts = item.split("/")
    inside = not os.path.isabs(item) and ".." not in parts
    commands = [hook["command"] for _event, _bare, hook, _tools in source.hooks(agent_names)]
    if not inside and not any(is_command(command, source, item) for command in commands):
        raise Usage("{} names a place outside the source folder {}".format(item, shown(source.path)))
    known = (
        (len(parts) == 2 and parts[0] == "rules" and parts[1] in source.rules())
        or (inside and os.path.isfile(os.path.join(source.path, item))
            and any(runs_file(command, source, item) for command in commands))
        or any(is_command(command, source, item) for command in commands))
    if not known:
        raise Usage("the source {} has no rule, hook file, or hook command {}".format(shown(source.path), item))
    changed = off.switch(source, agent_name, item, on=False)
    print("switched off {} for {} from {}{}; the next deploy leaves it out".format(
        item, agent_name, shown(source.path), "" if changed else " (it was already off)"))
    return 0


def deploy(extra_sources, repo_argument):
    """Plans the deployment, refuses before writing when anything is in the way, then writes it. Returns 0."""
    sources = user_sources(extra_sources)
    repo_root = find_repo(repo_argument)
    repo = Source(os.path.join(repo_root, ".shared")) if repo_root else None
    if not sources and repo is None:
        raise Usage("there is nothing to deploy: create ~/.shared, or pass --source or --repo")

    table = agent_table()
    agent_names = [row["name"] for row in table]
    record = Record()
    off = OffList()
    run = sources + ([repo] if repo else [])
    run_ids = {source.id for source in run}
    refusals, warnings, notes = [], [], []

    # Trusting a hook lets it run any command on the machine, so only the person's own source names the Codex
    # plugins to install and trust, and a plugin list in another source is not read (#37).
    main_path = os.path.realpath(os.path.join(home(), ".shared"))
    listing = None
    for source in run:
        list_path = os.path.join(source.path, PLUGIN_LIST)
        if not os.path.isfile(list_path):
            continue
        if os.path.realpath(source.path) != main_path:
            warnings.append("{} was not read: only ~/.shared/plugins.json names the Codex plugins to install and trust"
                            .format(shown(list_path)))
            continue
        listing, problems = plugin_list(list_path)
        refusals += ["{}: {}".format(shown(list_path), problem) for problem in problems]

    skills, rules, declared = {}, {}, []
    for source in sources:
        for kind, found, items in (("skill", skills, source.skills()), ("rule", rules, source.rules())):
            for name, path in items.items():
                if name in found:
                    refusals.append("the {} {} is in two sources: {} and {}".format(
                        kind, name, shown(found[name][1].path), shown(source.path)))
                else:
                    found[name] = (path, source)
        source_hooks = source.hooks(agent_names)
        if record.approved(source):
            declared += [(source,) + hook for hook in source_hooks]
        elif source_hooks:
            notes.append("the hooks of {} were not placed: approve them with `agent-shared approve --source {}`"
                         .format(source.path, source.path))
    # A repository's hooks go only into the repository's own settings, naming `.shared` from its git root.
    repo_declared = []
    if repo:
        repo_hooks = repo.hooks(agent_names, root=REPO_HOOK_ROOT)
        if record.approved(repo):
            repo_declared = [(repo,) + hook for hook in repo_hooks]
        elif repo_hooks:
            notes.append("the hooks of {} were not placed: approve them with `agent-shared approve --source {}`"
                         .format(repo.path, repo.path))

    # links: place -> (target text, source)
    wanted = {}
    blocks = {}
    hook_files = {}
    plugin_cache = {}
    written_agents = []
    trust_by_hand = set()
    skipped = []
    # Folders whose links belong to an agent older than its checked versions: the run writes nothing for that agent,
    # so its links stay where they are and stay in the record.
    held_folders = set()
    for row in table:
        if not row_present(row):
            skipped.append(row)
            continue
        hold, line = version_check(row)
        if line:
            (warnings if hold else notes).append(line)
        if hold:
            skills_dir, rules_at, _hook_file = agent_places(row)
            held_folders |= {skills_dir} if skills_dir else set()
            held_folders |= {rules_at[0]} if rules_at and rules_at[1] == "link" else set()
            if repo and isinstance(row.get("repo_skills"), str):
                held_folders.add(os.path.join(repo_root, row["repo_skills"]))
            if repo and (row.get("repo_rules") or {}).get("form") == "link":
                held_folders.add(os.path.join(repo_root, row["repo_rules"]["place"]))
            continue
        written_agents.append(row["name"])
        kind = row.get("plugins")
        if kind and kind not in plugin_cache:
            plugin_cache[kind] = (claude_plugin_skills if kind == "claude" else codex_plugin_skills)(warnings)
        plugins = plugin_cache.get(kind, {})
        skills_dir, rules_at, hook_file = agent_places(row)
        if skills_dir is not None:
            for name, (path, source) in skills.items():
                if name in plugins:
                    notes.append("skipped the skill {} for {}: the plugin {} already has it".format(name, row["name"], plugins[name]))
                else:
                    wanted[os.path.join(skills_dir, name)] = (path, source)
        if rules_at:
            place, form = rules_at
            kept = {name: (path, source) for name, (path, source) in rules.items()
                    if not off.rule_off(source, row["name"], name)}
            if form == "link":
                for name, (path, source) in kept.items():
                    wanted[os.path.join(place, name)] = (path, source)
            else:
                blocks[place] = {source.id: sorted((name, path) for name, (path, owner) in kept.items() if owner is source)
                                 for source in sources}
        hook_places = [(hook_file, row.get("hooks"), declared)] if hook_file else []
        if repo and "repo_hooks" in row:
            hook_places.append((os.path.join(repo_root, row["repo_hooks"]["file"]), row["repo_hooks"], repo_declared))
            if (row.get("hooks") or {}).get("trust") and repo_declared:
                trust_by_hand.add(os.path.join(repo_root, row["repo_hooks"]["file"]))
        for place, spec, place_declared in hook_places:
            entry = hook_files.setdefault(place, {"trust": spec.get("trust") if place == hook_file else None,
                                                  "version": spec.get("version"), "groups": {}, "commands": set()})
            groups, commands, missing = agent_hook_groups(place_declared, row, off)
            for event, command in missing:
                notes.append("left the {} hook `{}` out of {}: it reads no {} event".format(event, command, row["name"], event))
            entry["commands"] |= commands
            for event, added in groups.items():
                entry["groups"].setdefault(event, []).extend(added)
        if repo and isinstance(row.get("repo_skills"), str):
            base = os.path.join(repo_root, row["repo_skills"])
            for name, path in repo.skills().items():
                wanted[os.path.join(base, name)] = (os.path.relpath(path, base), repo)
        if repo and "repo_rules" in row:
            place = os.path.join(repo_root, row["repo_rules"]["place"])
            kept = {name: path for name, path in repo.rules().items() if not off.rule_off(repo, row["name"], name)}
            if row["repo_rules"]["form"] == "link":
                for name, path in kept.items():
                    wanted[os.path.join(place, name)] = (os.path.relpath(path, place), repo)
            else:
                blocks[place] = {repo.id: sorted(kept.items())}

    # A row skipped now keeps none of the run's marked items in its home files, so items written before, when the
    # agent was there or a path only looked like it, are taken out. A repository's files are shared with the
    # people who have the agent, so they are left as they are.
    for row in skipped:
        _skills_dir, rules_at, hook_file = agent_places(row)
        if rules_at and rules_at[1] == "block":
            blocks.setdefault(rules_at[0], {source.id: [] for source in sources})
        if hook_file:
            hook_files.setdefault(hook_file, {"trust": None, "version": None, "groups": {}, "commands": set()})

    # The links in the way: something agent-shared did not place, or a link placed from another source.
    for place, (target, source) in sorted(wanted.items()):
        owner, entry = record.owner(place)
        if owner is not None and owner not in run_ids:
            refusals.append("{} was placed from another source, {}; deploy both sources in one run"
                            .format(shown(place), shown(entry.get("path", "?"))))
        elif os.path.lexists(place) and not (owner is not None and still_placed(place, record.sources[owner]["links"][place])):
            refusals.append("{} is in the way: agent-shared did not place it".format(shown(place)))

    blocks_text = {}
    for place, by_source in blocks.items():
        text = ""
        if os.path.exists(place):
            with open(place, encoding="utf-8") as handle:
                text = handle.read()
        lines = text.splitlines(keepends=True)
        for sid, items in by_source.items():
            for name, path in items:
                with open(path, encoding="utf-8") as handle:
                    if any(line.startswith(MARK_LINE_START) for line in handle):
                        refusals.append("the rule {} has a line that starts like an agent-shared marker".format(shown(path)))
            found = block_lines(lines, sid, place, refusals)
            new = rules_block(sid, items).splitlines(keepends=True) if items else []
            if found:
                lines[found[0]:found[1] + 1] = new
            elif new:
                if lines and not lines[-1].endswith("\n"):
                    lines[-1] += "\n"
                lines += new
        new_text = "".join(lines)
        if new_text != text:
            blocks_text[place] = new_text

    hooks_text = {}
    for place, entry in hook_files.items():
        data = read_agent_json(place, refusals)
        if data is None:
            continue
        hand = {(event, hook["command"]) for event, groups in data.get("hooks", {}).items()
                for group in groups if isinstance(group, dict) for hook in group.get("hooks", [])
                if isinstance(hook, dict) and isinstance(hook.get("command"), str) and not is_marked(hook)}
        for event, command in sorted(entry["commands"] & hand):
            refusals.append("{} has a hook that agent-shared did not place with the same command: {} {}"
                            .format(shown(place), event, command))
        new = with_hooks(data, run_ids, entry["groups"])
        # A file the agent reads only with a top-level version gets it first, as the agent's docs show it.
        if entry["version"] is not None and new.get("hooks") and "version" not in new:
            new = dict({"version": entry["version"]}, **new)
        if new != data:
            hooks_text[place] = json.dumps(new, ensure_ascii=False, indent=2) + "\n"

    if refusals:
        raise Refused(refusals)

    # Write: take out links this run no longer places, then place the rest.
    placed_links = {source.id: {} for source in run}
    for place, target in sorted(record.links(run_ids).items()):
        if place in wanted and wanted[place][0] == target:
            continue
        if place not in wanted and os.path.dirname(place) in held_folders:
            placed_links[record.owner(place)[0]][place] = target
            continue
        if still_placed(place, target):
            os.unlink(place)
            notes.append("removed {}".format(shown(place)))
            clear_emptied(place, notes, repo_root)
    for place, (target, source) in sorted(wanted.items()):
        placed_links[source.id][place] = target
        if still_placed(place, target):
            continue
        os.makedirs(os.path.dirname(place), exist_ok=True)
        os.symlink(target, place)
        notes.append("placed {}".format(shown(place)))
    for place, text in sorted(blocks_text.items()):
        put_text(place, text, "wrote the rules block in {}", notes, repo_root)
    for place, text in sorted(hooks_text.items()):
        put_text(place, text, "wrote the hooks in {}", notes, repo_root)
    record.save(run, placed_links)

    for place, entry in sorted(hook_files.items()):
        if entry["trust"] != "codex-app-server" or not os.path.exists(place):
            continue
        with open(place, encoding="utf-8") as handle:
            if place not in hooks_text and MARK not in handle.read():
                continue
        write_codex_trust(place, notes, warnings)
    for place in sorted(trust_by_hand & set(hooks_text)):
        warnings.append("Codex runs a repository's hooks only after you trust them: open /hooks in Codex once "
                        "and trust the hooks in {}.".format(shown(place)))
    if listing and any(row.get("plugins") == "codex" and row["name"] in written_agents for row in table):
        ensure_codex_plugins(listing, notes, warnings)

    for line in notes:
        print(line)
    for line in warnings:
        print("warning: " + line)
    print("deployed {} skills and {} rules from {} source{} to {}".format(
        len(skills) + (len(repo.skills()) if repo else 0), len(rules), len(run), "" if len(run) == 1 else "s",
        ", ".join(written_agents)))
    return 0


def holds_nothing(text):
    """Whether a rules or hook file holds nothing once agent-shared's entries are out: no text, or JSON with no
    key but `version`."""
    if not text.strip():
        return True
    try:
        data = json.loads(text)
    except ValueError:
        return False
    return isinstance(data, dict) and set(data) <= {"version"}


def put_text(place, text, done, notes, repo_root=None):
    """Writes a rules or hook file, or removes it when it would hold nothing, so no empty file is left behind."""
    if holds_nothing(text):
        if os.path.exists(place):
            os.unlink(place)
            notes.append("removed {}, which held nothing else".format(shown(place)))
            clear_emptied(place, notes, repo_root)
        return
    write_text(place, text)
    notes.append(done.format(shown(place)))


def clear_emptied(place, notes, repo_root=None):
    """Removes, upward, the folders that taking `place` out left empty. It stops at a folder right under the home
    folder, which is an agent's own folder such as `~/.copilot`, and at the repository root; both stay even when
    empty. A folder outside the home folder and the repository is never removed."""
    top = home()
    folder = os.path.dirname(place)
    while True:
        parent = os.path.dirname(folder)
        in_repo = repo_root is not None and folder.startswith(repo_root + os.sep)
        in_home = folder.startswith(top + os.sep) and parent != top
        if folder == repo_root or not (in_repo or in_home):
            return
        try:
            os.rmdir(folder)
        except OSError:
            return
        notes.append("removed {}, which was left empty".format(shown(folder)))
        folder = parent


def write_codex_trust(place, notes, warnings):
    """Asks Codex to trust the marked hooks in its hook file and to forget the trust of hooks no longer there."""
    how = "Open /hooks in Codex once and trust the hooks in {}.".format(shown(place))
    try:
        changed = trust_codex_hooks(place)
    except TrustFailed as error:
        warnings.append("Codex's hook trust was not written ({}). {}".format(error, how))
        return
    if changed is None:
        warnings.append("Codex was not found, so it does not trust the hooks yet. {}".format(how))
    elif changed:
        notes.append("wrote Codex's trust for the hooks in {}".format(shown(place)))


def approve(source_path):
    """Prints the hook commands of one source and records the person's approval when they answer yes, so
    deploy places the source's hooks from then on. Returns 0 when approved, 1 when not."""
    source = existing_source(source_path)
    agent_names = [row["name"] for row in agent_table()]
    declared = source.hooks(agent_names)
    record = Record()
    print("The hooks of {} run these commands:".format(source.path))
    for event, bare, hook, _tools in declared:
        matcher = " {}".format(bare["matcher"]) if "matcher" in bare else ""
        print("  {}{}: {}".format(event, matcher, hook["command"]))
    if not declared:
        print("  (no hooks)")
    if record.approved(source):
        print("{} is already approved".format(source.path))
        return 0
    sys.stdout.write("Approve them, so deploy places this source's hooks in every agent? [y/N] ")
    sys.stdout.flush()
    answer = sys.stdin.readline().strip().lower()
    if answer not in ("y", "yes"):
        print("\nnot approved; nothing was written")
        return 1
    record.approve(source)
    print("approved {}".format(source.path))
    return 0


def remove(source_path):
    """Takes out every link, rules block, and marked hook one source placed from every agent, and the source's
    entries in the record and the switch list, relying only on the marks and the record, so it also works
    after the source folder is gone. A repository's `.shared` is also taken out of the repository. Returns 0."""
    path = expand(source_path)
    record = Record()
    off = OffList()
    ids = {source_id(path)} | {sid for sid, entry in record.sources.items() if entry.get("path") == path}
    table = agent_table()
    # ~/.shared is the person's own source, not a repository's: as in find_repo(), the home folder is never a
    # repository, so the folders right under it stay when they are left empty (#29).
    parent = os.path.dirname(path)
    repo_root = parent if os.path.basename(path) == ".shared" and parent != home() else None
    rule_files, hook_files = set(), {}
    for row in table:
        _skills_dir, rules_at, hook_file = agent_places(row)
        if rules_at and rules_at[1] == "block":
            rule_files.add(rules_at[0])
        if hook_file:
            hook_files[hook_file] = (row.get("hooks") or {}).get("trust")
        if repo_root and "repo_rules" in row and row["repo_rules"]["form"] == "block":
            rule_files.add(os.path.join(repo_root, row["repo_rules"]["place"]))
        if repo_root and "repo_hooks" in row:
            hook_files.setdefault(os.path.join(repo_root, row["repo_hooks"]["file"]), None)

    refusals, notes, warnings = [], [], []
    links = [place for place, target in sorted(record.links(ids).items()) if still_placed(place, target)]
    blocks_text = {}
    for place in sorted(rule_files):
        if not os.path.exists(place):
            continue
        with open(place, encoding="utf-8") as handle:
            text = handle.read()
        lines = text.splitlines(keepends=True)
        for sid in sorted(ids):
            found = block_lines(lines, sid, place, refusals)
            if found:
                del lines[found[0]:found[1] + 1]
        if "".join(lines) != text:
            blocks_text[place] = "".join(lines)
    hooks_text = {}
    for place in sorted(hook_files):
        if not os.path.exists(place):
            continue
        data = read_agent_json(place, refusals)
        if data is None:
            continue
        new = with_hooks(data, ids, {})
        if new != data:
            hooks_text[place] = json.dumps(new, ensure_ascii=False, indent=2) + "\n"
    if refusals:
        raise Refused(refusals)

    for place in links:
        os.unlink(place)
        notes.append("removed {}".format(shown(place)))
        clear_emptied(place, notes, repo_root)
    for place, text in sorted(blocks_text.items()):
        put_text(place, text, "took the rules block out of {}", notes, repo_root)
    for place, text in sorted(hooks_text.items()):
        put_text(place, text, "took the hooks out of {}", notes, repo_root)
    found = bool(links or blocks_text or hooks_text) or any(sid in record.sources for sid in ids)
    record.forget(ids)
    off.forget(ids)
    for place, trust in sorted(hook_files.items()):
        if trust == "codex-app-server" and place in hooks_text:
            write_codex_trust(place, notes, warnings)
    for line in notes:
        print(line)
    for line in warnings:
        print("warning: " + line)
    print("removed everything {} placed".format(path) if found else "nothing was placed from {}".format(path))
    return 0


def check(source_path):
    """Checks one source folder against the definition and prints each problem as `<file>: <entry>: <problem>`.
    Writes nothing. Returns 0 when there is none, 1 otherwise."""
    source = existing_source(source_path)
    problems = []
    table_path = os.path.join(source.path, "agents.json")
    own_rows = []
    if os.path.exists(table_path):
        try:
            table = read_json(table_path, "the agent table")
        except Usage as error:
            problems.append("{}: {}".format(table_path, error))
            table = None
        if table is not None and table_problem(table):
            problems.append("{}: agents: {}".format(table_path, table_problem(table)))
        elif table is not None:
            for index, row in enumerate(table["agents"]):
                problem = row_problem(row)
                if problem:
                    problems.append("{}: agents[{}]: {}".format(table_path, index, problem))
                else:
                    own_rows.append(row)
    rows = agent_table()
    for row in own_rows:
        rows = [known for known in rows if known["name"] != row["name"]] + [row]
    agent_names = {row["name"] for row in rows}
    every_event = any("events" not in row for row in rows)
    known_events = {event for row in rows for event in row.get("events", [])}

    hooks_path = os.path.join(source.path, "hooks.json")
    if os.path.exists(hooks_path):
        try:
            data = read_json(hooks_path, "the hook declaration")
        except Usage as error:
            problems.append("{}: {}".format(hooks_path, error))
            data = {}
        events = data.get("hooks") if isinstance(data, dict) else None
        if not isinstance(events, dict):
            problems.append("{}: hooks: there is no `hooks` object that maps events to lists of groups".format(hooks_path))
            events = {}
        for event, groups in events.items():
            if not every_event and event not in known_events:
                problems.append("{}: hooks.{}: no agent in the table reads the event {}".format(hooks_path, event, event))
            if not isinstance(groups, list):
                problems.append("{}: hooks.{}: the event holds no list of groups".format(hooks_path, event))
                continue
            for gi, group in enumerate(groups):
                inner = group.get("hooks") if isinstance(group, dict) else None
                if not isinstance(inner, list) or not inner:
                    problems.append("{}: hooks.{}[{}]: the group has no list of hooks".format(hooks_path, event, gi))
                    continue
                for hi, hook in enumerate(inner):
                    entry = "hooks.{}[{}].hooks[{}]".format(event, gi, hi)
                    if not isinstance(hook, dict) or not isinstance(hook.get("command"), str) or not hook["command"]:
                        problems.append("{}: {}: the hook has no command".format(hooks_path, entry))
                        continue
                    unknown = sorted(set(hook.get("tools") or []) - agent_names) if isinstance(hook.get("tools"), list) else []
                    if unknown:
                        problems.append("{}: {}: tools names agents not in the table: {}".format(hooks_path, entry, ", ".join(unknown)))

    list_path = os.path.join(source.path, PLUGIN_LIST)
    if os.path.isfile(list_path):
        problems += ["{}: {}".format(list_path, problem) for problem in plugin_list(list_path)[1]]

    for name, folder in source.skills().items():
        skill_file = os.path.join(folder, "SKILL.md")
        with open(skill_file, encoding="utf-8") as handle:
            head = handle.read().split("\n---", 1)[0]
        declared = re.search(r"^name:\s*(\S+)\s*$", head, re.M)
        if not declared or declared.group(1).strip("'\"") != name:
            problems.append("{}: name: the skill's name must equal its folder {}".format(skill_file, name))

    for line in problems:
        print(line)
    if problems:
        print("{} problem{} in {}".format(len(problems), "" if len(problems) == 1 else "s", source.path))
        return 1
    print("ok: {}".format(source.path))
    return 0
