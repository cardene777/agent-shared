# copilot-cli

| Criterion | How to check | Origin |
|---|---|---|
| The default table has a GitHub Copilot CLI row, and `agent-shared deploy` writes the shared rules in one fenced block of `~/.copilot/copilot-instructions.md`, leaving the lines outside the block unchanged | `bash tests/test-agent-shared.sh` check `"deploy writes rules in one block of Copilot CLI's instructions"` passes | #4 |
| `agent-shared deploy` writes the declared hooks into `~/.copilot/hooks/agent-shared.json` with `"version": 1`, in Claude Code's nested shape with PascalCase event names, each command carrying the agent-shared mark | `bash tests/test-agent-shared.sh` check `"deploy writes marked hooks for Copilot CLI in a file of version 1"` passes | #4 |
| A rule or hook taken out of the source is taken out of Copilot CLI's block and hook file on the next run, and the hooks without the mark stay | `bash tests/test-agent-shared.sh` check `"a removed rule or hook is taken out of Copilot CLI on the next run"` passes | #4 |
| `agent-shared placed` lists the rules and hooks placed for GitHub Copilot CLI | `bash tests/test-agent-shared.sh` check `"placed lists the rules and hooks placed for Copilot CLI"` passes | #4 |
| On a computer without `~/.copilot`, `agent-shared deploy` creates nothing under `~/.copilot` and still writes Claude Code's and Codex's rules and hooks | `bash tests/test-agent-shared.sh` check `"deploy writes nothing for Copilot CLI without ~/.copilot"` passes | #4 |
| `agent-shared deploy` leaves the other files in `~/.copilot/hooks/` unchanged | `bash tests/test-agent-shared.sh` check `"deploy leaves the other Copilot CLI hook files unchanged"` passes | #4 |
| A skill an installed Codex plugin already has is still not placed in `~/.agents/skills`, which Copilot CLI also reads | `bash tests/test-agent-shared.sh` check `"a skill an installed plugin already has is not placed for that agent"` passes | #4 |
| The rules and hooks of Claude Code and Codex are written as before | `bash tests/test-agent-shared.sh` checks `"deploy writes rules as links for Claude Code and one block for Codex"`, `"deploy adds marked hooks and keeps the other settings"`, and `"deploy writes Codex trust for the hooks it placed"` pass | #4 |
| `README.md` and `README.ja.md` say that GitHub Copilot CLI takes the rules and hooks, and where they are written | `bash tests/test-agent-shared.sh` check `"the READMEs name where Copilot CLI's rules and hooks go"` passes | #4 |
