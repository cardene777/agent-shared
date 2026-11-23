# repository-pages

| 条件 | 確かめ方 | 出元 |
|---|---|---|
| `assets/icon.svg` is a square SVG on the dark rounded square of agent-shuriken's icon, holding an agent's face and a folder | `bash tests/test-agent-shared.sh` check `"the icon is a square SVG in assets"` passes | #5 |
| `README.md` and `README.ja.md` show `assets/icon.svg` before their first section | `bash tests/test-agent-shared.sh` check `"both READMEs show the icon at the top"` passes | #5 |
| `tests/test-agent-shared.sh` refuses README pages that name a sign-in or a private repository | `bash tests/test-agent-shared.sh` check `"the READMEs name no sign-in or private repository"` passes | #5 |
| Both README pages install the command with `uv tool install "git+https://github.com/cardene777/agent-shared"` | `bash tests/test-agent-shared.sh` check `"the READMEs install from this repository"` passes | #5 |
| The command still installs with `uv tool install` and its help and README describe `off.json` | `bash tests/test-agent-shared.sh` checks `"uv tool install puts agent-shared on PATH without any plugin"` and `"the README and the help describe off.json"` pass | #5 |
