# The agent-shared definition

Definition version `2026-11-23`.

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
| `command` | The shell command the agent runs. `${CLAUDE_PLUGIN_ROOT}` is replaced by the source folder's path, or by `.shared` in a repository |
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

## Placing into a repository

A repository's `.shared` is placed into the repository itself, so every clone gets the same items.

| Item | Where |
|---|---|
| Skills | a relative link per skill in each row's `repo_skills` |
| Rules | one block of each row's `repo_rules`, `AGENTS.md` in the published table |
| Hooks | each row's `repo_hooks`, with `${CLAUDE_PLUGIN_ROOT}` replaced by `.shared` |

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
| This definition | a date, `2026-11-23` | the top of this text |
| The mark | an integer, `1` | `# agent-shared 1 source=<id>` |
| The agent table | an integer, `1` | `version` of `agents.json` |
| An agent | the agent's own version | `checked` of its row |

When the installed version of an agent is outside its row's `checked` range, a tool writes nothing for that agent and says so, until the row is checked again.

## Relation to existing specs

| Spec or tool | What it covers | How this definition sits on it |
|---|---|---|
| Agent Skills | `SKILL.md` and the skill folders agents read | Skills are placed as Agent Skills defines them, unchanged |
| `AGENTS.md` | One rules file at a repository root | A repository's rules go into a fenced block of it |
| Claude Code hooks | The hook shape and its events | The hook declaration is this shape |
| GitHub Copilot CLI and Codex hooks | Hook files that read Claude Code's nested shape | Hooks are written as declared, with the version and trust each needs |
| Agent Plugins 1.0.0 | Portable plugins with skills and MCP; hooks and rules are left out as not portable | This definition is offered as the portable form of hooks and rules |
| rulesync, APM, AgentsMesh | Tools that change their own hook format into each agent's | This definition gives them one public shape and one mark instead of a private format each |
