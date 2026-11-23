# 0001 The mark lives inside the hook command

Date: 2026-11-23

## Decision

A tool that places a hook writes its mark as the last line of the hook's command, `# agent-shared 1 source=<id>`, and fences the rules it places with `<!-- agent-shared begin source=<id> -->` and `<!-- agent-shared end source=<id> -->`.
Only links, which cannot carry a mark, go in the tool's own record.
A tool takes out an entry only when it carries the mark of a source the tool deploys, so a hand-written entry is never taken out.

## Options not taken

| Option | Why not |
|---|---|
| A field on the hook entry, such as `"source"` | Claude Code refuses unknown fields in its settings, so the field cannot be written there |
| A record file of placed entries and their hashes only, as APM's `apm.lock.yaml` with `.claude/apm-hooks.json` | A hand edit of the settings makes the record and the settings drift, and the tool can no longer tell which entries are its own |
| Whole files of the tool's own only, as rulesync writes `.kiro/hooks/rulesync.json` | Claude Code and Codex read hooks from one settings file, so the hooks have to be merged into a file the user also writes |

## Grounds

- `MARK`, `BEGIN`, and `END` in `src/agent_shared/deploy.py`, and `is_marked` and `with_hooks`, which take out only marked hooks
- The check `entries without the mark are left unchanged` in `tests/test-agent-shared.sh`
- The decisions of cardene777/agent-shared#9, step 2, "Ownership marks"
