# Changelog

This file lists the releases of `agent-shared`, newest first.
Versions follow semantic versioning, and each release is tagged `v<version>`.

## Unreleased

- The default agent table gives GitHub Copilot CLI the rules in one block of `~/.copilot/copilot-instructions.md` and the hooks in `~/.copilot/hooks/agent-shared.json`, only when `~/.copilot` exists
- A row of the agent table can leave out `skills`, wait for a folder with `needs`, and put a `version` on top of its hook file

## [0.1.0] - 2026-11-23

- `agent-shared deploy`, which links the skills and rules in `~/.shared` into Claude Code and the agents that read `~/.agents/skills`, writes the rules into `~/.codex/AGENTS.md` and the hooks into both agents' settings with Codex's trust, links a repository's `.shared` skills into its own folders, and removes only what it placed
- `agent-shared hooks --agent <name>`, which prints the hook groups `deploy` adds to one agent's hook file and writes nothing, for a guard to compare with
- `agent-shared placed --source <folder>`, which prints, as JSON, the skills, rules, and hooks one source folder placed in each agent and that are still there, and writes nothing, for an app to list what it deployed
- `agent-shared off` and `agent-shared on`, which leave one rule or hook of a source out of one agent on every later deploy, and put it back, keeping the choice in `off.json` beside the record
- The command moved here from `agent-shuriken`, with the commits that made it
