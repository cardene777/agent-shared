# The agent-shared definition

Definition version `2026-11-26`.

agent-shared places the skills, rules, and hooks kept in one source folder into every coding agent a person uses, in the place and shape each agent reads.
A hook is declared once, in Claude Code's hook shape, and an agent table says where each agent keeps its files and which events it reads.
Every placed hook and rules block carries a mark that names its source folder, so a tool takes out only what it placed and never an entry the person wrote by hand.
This English text is the normative definition; [agent-shared.ja.md](agent-shared.ja.md) is its Japanese translation, and [GLOSSARY.md](../GLOSSARY.md) defines its terms.

## Overview

| File | Written by | Holds |
|---|---|---|
| `skills/<name>/SKILL.md` | The person | A skill as Agent Skills defines it |
| `rules/<name>.md` | The person | One rule file in Markdown |
| `hooks.json` | The person | The hook declaration |
| `agents.json` | The person, optionally | Rows that add an agent or replace a row of the agent table |
| The agent table | This definition | Where each agent keeps its files, which events it reads, and the versions checked |

```text
~/.shared/                     the person's own source folder
├── skills/plain-words/SKILL.md
├── rules/commit-messages.md
├── hooks.json                 the hook declaration
├── hooks/no-force-push.sh     a script a hook runs
└── agents.json                optional rows of the agent table
```

[examples/basic](../examples/basic) is a source folder that passes `agent-shared check`.

## Source folder

A source folder holds any of `skills/`, `rules/`, and `hooks.json`.

| Source folder | Where | Approval |
|---|---|---|
| The person's own | `~/.shared` | Counts as approved |
| Another source | Any folder, named with `--source` | Approved once by the person |
| A repository's | `.shared` at the repository root | Approved once by the person |

A skill folder's name equals the `name` in its `SKILL.md`, as Agent Skills requires.
A rule is a `.md` file directly under `rules/`, and its file name is its name.
Two source folders in one run that hold a skill or a rule of the same name are refused before anything is written.

## Hook declaration

`hooks.json` holds the `hooks` object of Claude Code's settings: events, each with a list of groups, each group with an optional `matcher` and a list of hooks.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/no-force-push.sh", "timeout": 5}
        ]
      }
    ]
  }
}
```

| Field | Meaning |
|---|---|
| `command` | The shell command the agent runs. `${CLAUDE_PLUGIN_ROOT}` is replaced by the source folder's path, or in a repository by `"$(git rev-parse --show-toplevel 2>/dev/null \|\| pwd)"/.shared`, so the hook finds `.shared` from any folder of the repository |
| `timeout` | Seconds, as Claude Code reads it |
| `tools` | An optional list of agent names; the hook goes only to those agents, and the field is not written |

A tool writes each hook into every agent of the agent table in that agent's shape.

- An agent whose row lists the hook's event gets the hook as declared, with the mark added to its command.
- An agent whose row does not list the event does not get the hook, and the run names the hook and the agent.
- A row with a hook file `version` gets that number as the file's top-level `version`.
- A tool does not place a hook whose command a hand-written hook in the same file already runs for the same event; it refuses and names it.

### Each agent's shape

| Agent | Rules | Hooks | Shape |
|---|---|---|---|
| Claude Code | a link per rule in `~/.claude/rules` | `~/.claude/settings.json` | as declared |
| Codex | one block in `~/.codex/AGENTS.md` | `~/.codex/hooks.json` | as declared, with Codex's trust written for each placed hook |
| GitHub Copilot CLI | one block in `~/.copilot/copilot-instructions.md` | `~/.copilot/hooks/agent-shared.json` | as declared, with `"version": 1` on top; written only when the `copilot` command is on `PATH` (`needs_command`) |

Skills go into `~/.claude/skills` for Claude Code and into `~/.agents/skills` for the agents that read it, Codex and GitHub Copilot CLI among them.

### Rules with a scope

A rule may start with frontmatter between two `---` lines that limits where it applies.

| Field | Written by | Meaning |
|---|---|---|
| `paths` | Claude Code | The files the rule applies to, as glob patterns |
| `globs` | Cursor | The same, as a list or one string of patterns separated by commas |
| `applyTo` | GitHub Copilot | The same, as one string of patterns separated by commas |
| `alwaysApply` | Cursor | `true` makes the rule apply everywhere, whatever the patterns say |
| `description` | Cursor | When to apply a rule that has no patterns |

A rules file holds every rule for every task, so a tool writes a rule with frontmatter into a block without its frontmatter, under one quoted line that states its scope.
The agent reads the rule always and follows the scope the line names, which keeps a rule in force rather than dropping it.

```text
<!-- agent-shared rule typescript.md -->
> Applies when working on files that match `src/**/*.ts`, `test/**/*.ts`.
# TypeScript
...
```

| Scope | The line |
|---|---|
| Patterns in `paths`, `globs`, or `applyTo` | `> Applies when working on files that match <each pattern in backticks>.` |
| `description` without patterns | `> Apply this rule when the task fits: <description>` |
| `alwaysApply: true`, or no scope field | no line |

A folder of rule links gets a rewritten copy in place of a link when the agent would not read the scope: Claude Code reads only `paths:`.
A rule scoped with `globs` or `applyTo` gets a copy with its patterns under `paths:`, and a rule scoped only by `description` gets a copy that starts with the line above instead of its frontmatter.
A rule without frontmatter, or scoped with `paths` only, stays a link.
A rule whose first line is `---` and that has no closing `---` line is refused before anything is written.

## Agent table

The agent table is published as [`src/agent_shared/agents.json`](../src/agent_shared/agents.json), and every tool reads that one table instead of keeping its own.
A row of `~/.shared/agents.json` with a new name adds an agent, and a row with the name of a published row replaces that row.

| Field | Meaning |
|---|---|
| `name` | The agent's name, also used by `tools` |
| `skills` | The folder that gets a link per skill; a row without it places no skills |
| `repo_skills` | The folder in a repository that gets a link per repository skill |
| `rules` | `place` and `form`: `link` puts a link per rule in the folder `place`, `block` writes the rules in one block of the file `place` |
| `repo_rules` | The same as `rules`, with `place` relative to the repository root |
| `hooks` | `file` gets the hooks; `version` is written on top of a file that holds hooks; `trust: codex-app-server` also writes Codex's trust |
| `repo_hooks` | The same as `hooks`, with `file` relative to the repository root |
| `events` | The hook events the agent reads; a row without it reads every event |
| `checked` | `command` prints the installed version, and `from` and `to` are the lowest and highest versions the row was checked against |
| `needs` | A path that must exist for the row to be written |
| `needs_command` | A command that must be on `PATH` for the row to be written; a row that is skipped loses the run's marked items in its files, and a file left holding nothing is removed |
| `plugins` | `claude` or `codex`: a skill that a plugin installed in that agent already has is not placed for it |

```json
{"version": 1, "agents": [{"name": "My agent", "skills": "~/.my-agent/skills", "events": ["PreToolUse", "Stop"]}]}
```

## Marks and records

A placed hook carries the mark as the last line of its command, a shell comment that the agent ignores.

```json
{"type": "command", "command": "bash /home/me/.shared/hooks/no-force-push.sh\n# agent-shared 1 source=3f9c2a71b0de", "timeout": 5}
```

Placed rules sit between two fence lines in the agent's rules file.

```text
<!-- agent-shared begin source=3f9c2a71b0de -->
<!-- agent-shared rule commit-messages.md -->
# Commit messages
...
<!-- agent-shared end source=3f9c2a71b0de -->
```

| Item | How it is told apart |
|---|---|
| Hook | The mark `# agent-shared 1 source=<id>` on the last line of its command |
| Rules in one file | The begin and end fence lines with the same `<id>` |
| Skill or rule link | The tool's own record of the links it placed, since a link cannot carry a mark |
| Rewritten copy of a rule | The same record, which names the copy with the SHA-256 of its text; a copy changed by hand is neither replaced nor taken out |

`<id>` is the first 12 hexadecimal digits of the SHA-256 of the source folder's real path.
A tool takes out or rewrites only entries that carry the mark of a source folder it deploys, and leaves every other entry as it is.
When taking an item out leaves its folder empty, the tool removes that folder and each folder above it left empty, and stops at a folder right under the home folder (an agent's own folder such as `~/.copilot`) and at the repository root, which stay even when empty.
The record of links and the list of items switched off for one agent are each tool's own and are not part of this definition; agent-shared keeps them in `placed.json` and `off.json`.

## Approving sources

A hook runs a command, so a tool places the hooks of a source folder only after the person approved that source folder once.

- `~/.shared` counts as approved.
- Another source folder shows the person every hook command the first time, and is approved when the person answers yes; `agent-shared approve --source <folder>` does this.
- A source folder that is not approved still gets its skills and rules placed, gets none of its hooks placed, and the run names the command that approves it.
- An agent's own trust, such as Codex's, is written only for hooks that were placed.
- A source folder that a tool's record held before the tool supported approval counts as approved.

## Codex plugins

`~/.shared/plugins.json` names the Codex plugins whose hooks the person trusts.

| Field | Meaning |
|---|---|
| `codex.marketplaces` | Each marketplace's name mapped to the git URL Codex fetches it from |
| `codex.plugins` | The plugins, each written as `<plugin>@<marketplace>` with a marketplace of `codex.marketplaces` |

- A tool reads only `~/.shared/plugins.json`, the person's own source, because trusting a hook lets it run any command. A `plugins.json` in another source folder or in a repository's `.shared` is not read, and the run names it.
- Each run registers a marketplace Codex does not have, installs a named plugin Codex does not have, and writes Codex's trust for every hook of each named plugin for its current command, so a hook an update changed is trusted again.
- A run without `--source` first refreshes, with `codex plugin marketplace upgrade <marketplace>`, the snapshot Codex keeps of each named plugin's marketplace that Codex's settings register as a Git marketplace. After installing, it reads with `codex plugin list --json -m <marketplace>` the version Codex has of each named plugin and the snapshot folder, and when `.codex-plugin/plugin.json` there names a higher version, written as dotted numbers, it runs `codex plugin add <plugin>@<marketplace>`, which replaces the installed version; the trust it then writes covers the hooks of the new version. A version that is lower, equal, or not dotted numbers is left as it is, and so are the plugins the list does not name. A failed refresh is named with the marketplace and `codex plugin marketplace upgrade <marketplace>`, a failed install with the plugin, both versions, and `codex plugin add <plugin>@<marketplace>`, and the run goes on. A run with `--source` neither refreshes nor upgrades, so a tool that puts hooks back with `--source` does not reach the network for plugins.
- A plugin taken off the list stays installed and keeps its trust; `codex plugin remove <plugin>@<marketplace>` removes it.
- Codex does not install a plugin that `~/.codex/config.toml` enables, so a run that deploys `~/.shared` also installs each plugin whose `[plugins."<plugin>@<marketplace>"]` table says `enabled = true` and that Codex does not have, with or without a `plugins.json`. It writes no trust for the hooks of those plugins. A plugin whose marketplace Codex has not registered, and that `plugins.json` gives no git URL for, is named with the commands to run, and the others are still installed.
- Claude Code does not install an enabled plugin of a marketplace it has already registered, so a run that deploys `~/.shared` also runs `claude plugin install <plugin>@<marketplace> --scope user` for each plugin that `enabledPlugins` in `~/.claude/settings.json` sets to `true`, whose marketplace `~/.claude/plugins/known_marketplaces.json` holds, and that `~/.claude/plugins/installed_plugins.json` has no user-scope record of. A plugin of a marketplace Claude Code has not registered is left to Claude Code, which fetches it when it clones the marketplace. Without the `claude` command, the run names the plugins it left uninstalled.
- `agent-shared check` refuses a `plugins.json` whose top level is not an object, a plugin not written as `<plugin>@<marketplace>`, a plugin whose marketplace is not listed, and a marketplace without a git URL.

## Placing into a repository

A repository's `.shared` is placed into the repository itself, so every clone gets the same items.

| Item | Where |
|---|---|
| Skills | a relative link per skill in each row's `repo_skills` |
| Rules | one block of each row's `repo_rules`, `AGENTS.md` in the published table |
| Hooks | each row's `repo_hooks`, with `${CLAUDE_PLUGIN_ROOT}` replaced by `"$(git rev-parse --show-toplevel 2>/dev/null \|\| pwd)"/.shared` |

Codex runs a repository's hooks only after the person trusts them in Codex, so the run says to open `/hooks` in Codex.

## Taking everything out

A tool can take out everything one source folder placed, from every agent: the links in its record, the rules blocks and hooks carrying the source folder's `<id>`, and an agent's trust for those hooks.
It relies only on the marks and the record, so it works after the source folder is deleted.
For a repository's `.shared`, the repository's own files are cleaned too.
`agent-shared remove --source <folder>` does this.

## Checking a source folder

`agent-shared check --source <folder>` prints each problem as `<file>: <entry>: <problem>` and exits 1 when there is one.

| Problem | Entry named |
|---|---|
| An event no agent in the table reads | `hooks.<event>` |
| A hook without a command | `hooks.<event>[<group>].hooks[<hook>]` |
| A row of the source's agent table without a name | `agents[<row>]` |
| A skill whose name differs from its folder | `name` |

## Versions

| Version | Form | Where |
|---|---|---|
| This definition | a date, `2026-11-26` | the top of this text |
| The mark | an integer, `1` | `# agent-shared 1 source=<id>` |
| The agent table | an integer, `1` | `version` of `agents.json` |
| An agent | the agent's own version | `checked` of its row |

When the installed version of an agent is older than `from` of its row's `checked`, a tool writes nothing for that agent, leaves what it placed before as it is, and says so.
When the version is newer than `to`, or cannot be read, the tool writes as before and says so, since agents release often and a newer version mostly keeps the shapes the row was checked against.

## Relation to existing specs

| Spec or tool | What it covers | How this definition sits on it |
|---|---|---|
| Agent Skills | `SKILL.md` and the skill folders agents read | Skills are placed as Agent Skills defines them, unchanged |
| `AGENTS.md` | One rules file at a repository root | A repository's rules go into a fenced block of it |
| Claude Code hooks | The hook shape and its events | The hook declaration is this shape |
| GitHub Copilot CLI and Codex hooks | Hook files that read Claude Code's nested shape | Hooks are written as declared, with the version and trust each needs |
| Agent Plugins 1.0.0 | Portable plugins with skills and MCP; hooks and rules are left out as not portable | Rules are proposed as a portable component in `docs/proposals/agent-plugins-portable-rules.md`, posted as agentplugins/agent-plugins-spec#100 |
| Agent Plugins v1.1 | Portable lifecycle hooks in `hooks.json` at the plugin root, a `command` with `args`, for five events | agent-shared is to read this form as a source too once v1.1 is released (#25), and keeps the Claude Code shape for the events v1.1 lacks; the events each client version supports are proposed in `docs/proposals/agent-plugins-hook-events.md`, posted as agentplugins/agent-plugins-spec#101 |
| rulesync, APM, AgentsMesh | Tools that change their own hook format into each agent's | This definition gives them one public shape and one mark instead of a private format each |
