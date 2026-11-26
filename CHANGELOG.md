# Changelog

This file lists the releases of `agent-shared`, newest first.
Versions follow semantic versioning, and each release is tagged `v<version>`.

## [Unreleased]

- A rule with frontmatter that scopes it (`paths:`, `globs:`, `applyTo:`, `alwaysApply:`, or `description:`) goes into Codex's and GitHub Copilot CLI's block without its frontmatter, under one quoted line that says where it applies; Claude Code gets a copy rewritten to `paths:` for a rule scoped with `globs:` or `applyTo:`, and a copy that starts with that line for a rule scoped only by `description:`. A rule whose frontmatter is not closed is refused (#43)
- A run that deploys `~/.shared` installs each plugin that `~/.codex/config.toml` enables with `enabled = true` and Codex does not have, since Codex does not install them on its own. It writes no trust for the hooks of those plugins, and names a plugin whose marketplace Codex has not registered with the commands to run (#45)

## [0.3.0] - 2026-11-25

- `~/.shared/plugins.json` names the Codex plugins whose hooks you trust, with the git URL of each marketplace. Each deploy registers a marketplace Codex does not have, installs a named plugin Codex does not have, and writes Codex's trust for every hook of each named plugin for its current command, so a hook an update changed is trusted again without opening `/hooks` (#37)
- Only `~/.shared/plugins.json` is read; a `plugins.json` in another source folder or a repository's `.shared` is named in a warning, and `agent-shared check` refuses a `plugins.json` of the wrong shape (#37)
- A repository's hooks run from any folder of the repository: the hook command names its script from the repository's git root, for Claude Code, Codex, and GitHub Copilot CLI (#35)
- The READMEs say that `agent-shared remove` also drops the removed source's entries from `off.json` (#33)

## [0.2.4] - 2026-11-24

- Two proposals to Agent Plugins, in `docs/proposals/`: rules as a portable plugin component, and the hook events each client version supports with a report of every hook a client does not run, posted as Discussions agentplugins/agent-plugins-spec#100 and #101
- The definition's relation section names the portable hooks of Agent Plugins v1.1 and the two proposals
- `remove --source ~/.shared` keeps the folders right under the home folder, such as `~/.claude` and `~/.codex`, when they are left empty, as the definition says; before, it took `~/.shared` for a repository's `.shared` and removed them
- The READMEs say that skills and Claude Code's rules are links an edit reaches at once, and that Codex and GitHub Copilot CLI see a rule edit on the next deploy

## [0.2.3] - 2026-11-23

- `deploy` reads each agent's version with the `checked` command of its row: an agent older than `from` gets nothing written and keeps what was placed before, and an agent newer than `to` or whose version cannot be read is written as before; the run names each of them
- The definition says the same rule; before, it said an agent outside the range on either side gets nothing written

## [0.2.2] - 2026-11-23

- When `deploy` or `remove` takes a file or a link out, the folders it leaves empty go too, up to an agent's folder right under the home folder, such as `~/.copilot`, and the repository root, which stay

## [0.2.1] - 2026-11-23

- The GitHub Copilot CLI row waits for the `copilot` command on `PATH` (`needs_command`) instead of the folder `~/.copilot`, which a Copilot IDE plugin also makes, so a computer without Copilot CLI gets nothing
- A row that is skipped loses the run's marked rules block and hooks in its home files, and a rules or hook file left holding nothing is removed

## [0.2.0] - 2026-11-23

- The default agent table gives GitHub Copilot CLI the rules in one block of `~/.copilot/copilot-instructions.md` and the hooks in `~/.copilot/hooks/agent-shared.json`, only when `~/.copilot` exists
- A row of the agent table can leave out `skills`, wait for a folder with `needs`, and put a `version` on top of its hook file
- The definition `spec/agent-shared.md` (Japanese translation `spec/agent-shared.ja.md`), version `2026-11-23`, says how a source folder is placed into every agent, with the agent table `src/agent_shared/agents.json` published for every tool
- Every row of the agent table lists the hook events the agent reads and the versions it was checked against; a hook whose event an agent does not read is left out of that agent and named
- `agent-shared approve --source <folder>` approves the hooks of a source once; until then `deploy` places none of its hooks. `~/.shared` and sources placed before count as approved
- `agent-shared remove --source <folder>` takes out everything one source placed, also after its folder is deleted
- `agent-shared check --source <folder>` checks a source folder against the definition, with `examples/basic` as an example that passes
- A repository's `.shared` also places its rules in a block of the repository's `AGENTS.md` and its hooks in each agent's repository settings
- The `Repository` URL in `pyproject.toml` names this repository

## [0.1.0] - 2026-11-23

- `agent-shared deploy`, which links the skills and rules in `~/.shared` into Claude Code and the agents that read `~/.agents/skills`, writes the rules into `~/.codex/AGENTS.md` and the hooks into both agents' settings with Codex's trust, links a repository's `.shared` skills into its own folders, and removes only what it placed
- `agent-shared hooks --agent <name>`, which prints the hook groups `deploy` adds to one agent's hook file and writes nothing, for a guard to compare with
- `agent-shared placed --source <folder>`, which prints, as JSON, the skills, rules, and hooks one source folder placed in each agent and that are still there, and writes nothing, for an app to list what it deployed
- `agent-shared off` and `agent-shared on`, which leave one rule or hook of a source out of one agent on every later deploy, and put it back, keeping the choice in `off.json` beside the record
- The command moved here from `agent-shuriken`, with the commits that made it
