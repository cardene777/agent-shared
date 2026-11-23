# Glossary

The terms of the agent-shared definition. [GLOSSARY.ja.md](GLOSSARY.ja.md) is its Japanese translation.

| Term | Meaning |
|---|---|
| source folder | A folder holding `skills/`, `rules/`, and `hooks.json`, whose items a tool places into every agent. `~/.shared` is the user's own, and a repository keeps one in `.shared` |
| hook declaration | The hooks of a source folder, written once in Claude Code's hook shape in `hooks.json` |
| agent table | The JSON table of where each agent keeps its skills, rules, and hooks, which hook shape it reads, how event names and fields map, and the agent versions it was checked against |
| mark | The last line of a placed hook command, `# agent-shared 1 source=<id>`, naming the source folder that placed it. The integer is the version of the mark's form |
| rules block | The lines between `<!-- agent-shared begin source=<id> -->` and `<!-- agent-shared end source=<id> -->` in an agent's rules file, holding the rules one source folder placed |
| approved source | A source folder whose hooks the person approved once. `~/.shared` counts as approved, and a tool writes no hook of a source that is not approved |
| record | A tool's own file of the links it placed, since a link cannot carry a mark. agent-shared keeps `placed.json` |
| switch list | A tool's own file of the items one source leaves out of one agent. agent-shared keeps `off.json` |
