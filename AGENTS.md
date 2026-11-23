# AGENTS.md

Guidance for people and coding agents working in this repository.
Claude Code reads it through `CLAUDE.md`; Codex and other agents read it directly.

## What this repository is

The `agent-shared` command, which places the skills, rules, and hooks a person keeps in `~/.shared` into every coding agent.
It is a Python package that uses only the standard library of Python 3.11 or later, installed with `uv tool install`, and [README.md](README.md) describes everything it reads and writes.

```
pyproject.toml                  The package and its version
src/agent_shared/               The command and its default agent table, agents.json
tests/test-agent-shared.sh      Tests with a throwaway HOME, run before every pull request
README.md, README.ja.md         The guide, in English and in Japanese
assets/icon.svg                 The icon, on the dark rounded square of agent-shuriken's icon
CHANGELOG.md                    The releases
.ikkan/specs/                   Acceptance criteria kept by the ikkan workflow
```

Run tests against a throwaway `HOME`, never against a real agent folder.
`README.ja.md` is the Japanese counterpart of `README.md`; change both together.

## Commits and pull requests

- Write the subject as `<emoji> <type>(<scope>): <summary>` in English, for example `✨ feat(deploy): give rules to Gemini CLI`. The scope is the part of the command, or `repo` for repository-wide changes.

  | Emoji | Type |
  |---|---|
  | ✨ | `feat` |
  | 🐛 | `fix` |
  | 🔧 | `refactor` |
  | 📝 | `docs` |
  | ✅ | `test` |
  | 🎨 | `chore` |
  | ⚡ | `perf` |
  | 🔐 | `security` |
  | 🔥 | `removal` |
  | 🚚 | `migration` |
  | ⏪ | `revert` |

- Title an issue in English like a commit subject, in the same form. The pull request takes the issue's title, and the squashed commit takes the pull request's.
- One topic per pull request. The description has a summary of what changed and why, and a testing section listing the commands you ran and their results.
- A release raises the version in `pyproject.toml`, adds its entry to `CHANGELOG.md`, and is tagged `v<version>`.
- Do not include personal data in files, commits, or pull requests: local paths such as `/Users/<name>`, email addresses, account names, or real service lists.
- Do not add CI workflows.
