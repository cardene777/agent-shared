# Proposal: rules as a portable plugin component

This is the text of a GitHub Discussion proposed to the Agent Plugins specification (agentplugins/agent-plugins-spec).
A companion proposal covers the hook events each client version supports: [agent-plugins-hook-events.md](agent-plugins-hook-events.md).

## Summary

Many plugins need always-on instructions next to their skills: coding conventions, safety rules, or the steps a team follows.
The specification leaves rules outside the format "until their formats converge".
This proposal suggests that the content has already converged on plain Markdown, and that only the place each client loads it from differs.
It proposes a small `rules/` component and two client requirements, and offers one placement pattern that was run on three clients.

## Problem

A plugin that ships skills and MCP servers portably still has no portable way to ship the instructions that go with them.
Each client reads always-on instructions from its own place:

| Client | Where user-level instructions are read |
|---|---|
| Claude Code | `~/.claude/CLAUDE.md`, and every Markdown file in `~/.claude/rules/` |
| Codex | `~/.codex/AGENTS.md` |
| GitHub Copilot CLI | `~/.copilot/copilot-instructions.md` |
| Repositories | `AGENTS.md` at the repository root, read by Codex and others, and by Claude Code through `@AGENTS.md` in `CLAUDE.md` |

So a plugin author either keeps one copy per client or asks users to paste the text by hand.
Pasted text cannot be told apart from the user's own lines, so disabling or uninstalling the plugin leaves its rules behind, still loaded.

## Who hits it

- Plugin authors who ship team conventions or safety rules together with skills and hooks.
- Users who run more than one client and want the same rules in each.
- Organizations that distribute rules to many developers and need to update or withdraw them.

## Why it belongs in the portable specification

The content is the same in every client: Markdown read as instructions for the whole session.
What a client cannot decide alone is where a plugin keeps its rules and what enabling and removing them guarantees, since a plugin is written once for every client.
Placement inside each client can stay client policy.

### Proposed shape

- A plugin MAY have a `rules/` directory at the plugin root holding `*.md` files, one rule per file, the file name being the rule name.
- A client that supports rules MUST load every rule file of an enabled plugin as always-on instructions.
- When the plugin is disabled or uninstalled, the client MUST stop loading its rules and MUST NOT change instructions the user wrote.

### A placement pattern for clients that read one instructions file

A client that reads instructions from one file can still meet the removal requirement exactly:

```markdown
<!-- agent-plugin begin plugin=<plugin id> -->
## <rule name>
<rule text>
<!-- agent-plugin end plugin=<plugin id> -->
```

- One fenced block per plugin, placed after the user's own lines.
- Updating rewrites only the lines between the fences, and removing deletes the fences and the lines between them.
- Lines outside every block keep their bytes, and a line inside a rule that starts like a fence is refused before writing.

A client that reads a folder of rule files, like Claude Code's `~/.claude/rules/`, can place one link per rule and remove the links it recorded.

## Evidence

agent-shared ([definition](https://github.com/cardene777/agent-shared/blob/main/spec/agent-shared.md)) places one folder of skills, rules, and hooks into several clients and takes them out again.
Its rules placement is the pattern above, run on these clients and versions:

| Client | Versions checked | Placement |
|---|---|---|
| Claude Code | 2.1.330 | one link per rule in `~/.claude/rules/` |
| Codex | 0.124.0 to 0.171.0 | one fenced block per source in `~/.codex/AGENTS.md` |
| GitHub Copilot CLI | 1.0.62 to 1.0.114 | one fenced block per source in `~/.copilot/copilot-instructions.md` |
| Repositories | - | one fenced block per source in `AGENTS.md` |

Its tests check that the lines outside a block keep their bytes, that removing a source takes out only its block, also after the source folder is deleted, and that a file left holding nothing is removed.

## Who would adopt it

- agent-shared implements the placement above for Claude Code, Codex, and GitHub Copilot CLI today, and would read a plugin's `rules/` directory as a source.
- Clients that already load `AGENTS.md`-style files could load an enabled plugin's `rules/*.md` with a small change; we cannot speak for client vendors and would like to hear from them.

## Open questions

- Precedence when a plugin rule and a user instruction disagree.
- Rules scoped to paths, such as Copilot's `applyTo` or Cursor's glob rules, which this proposal leaves out of a first version.
- Size limits, since every rule is loaded into every session.
