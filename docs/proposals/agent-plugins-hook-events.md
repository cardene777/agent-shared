# Proposal: the hook events each client version supports, and reporting a hook a client does not run

This is the text of a GitHub Discussion posted to the Agent Plugins specification as agentplugins/agent-plugins-spec#101.
A companion proposal covers rules as a plugin component: [agent-plugins-portable-rules.md](agent-plugins-portable-rules.md).

Discussion-first proposal per CONTRIBUTING.md. Related threads: agentplugins/agent-plugins-spec#54 proposed the portable hooks component, and agentplugins/agent-plugins-spec#89 brought portable lifecycle hooks into v1.1; this proposal adds what happens to a handler a client does not run.

## Summary

Portable lifecycle hooks in v1.1 define five events.
Clients reach those events, and the fields around them, at different versions, and will add more events at different times.
This proposal asks that a client report every handler of an enabled plugin it does not run, and that the project keep a table of the events each client version supports.

## Problem

A plugin that declares a hook cannot tell whether the installed client will run it.
When a client skips a handler without a word, a guard hook that was meant to stop a dangerous command gives a false sense of safety.
Client support moves with versions, for example:

- GitHub Copilot CLI accepted the nested hook file shape and capitalized event names from 1.0.6, and passed Claude Code's tool names to hook scripts from 1.0.62.
- Codex reads 14 hook events and Claude Code reads 33, while each reads a different set beyond the five of v1.1.

The incubation pull request for portable hooks asked how a host that cannot run a hook should report it, and the question has no answer in the specification yet.

## Who hits it

- Authors of guard hooks, whose value is that they always run.
- Users on an older client version, who get a plugin whose hooks silently do nothing.
- Organizations that require a policy hook and need to know where it is not running.

## Why it belongs in the portable specification

Whether a skipped hook is reported is a portability guarantee: a plugin author can rely on it only if every client gives it.
A message in one client's own words does not let a plugin, a registry, or an installer check support before enabling a plugin.

### Proposed shape

- When a client does not run a handler of an enabled plugin, because it does not support the event, a field, or a value, it MUST report the plugin, the event, and the reason when the plugin is enabled, and MUST NOT skip it silently.
- The project keeps a table of the events, and the fields that change behavior, each client supports from which version, maintained by the implementers, like a compatibility matrix.
- This fits the configurable blocking of hook failures being discussed for v1.1: a handler marked to block could also make a client that does not support it refuse to enable the plugin.

## Evidence

agent-shared ([definition](https://github.com/cardene777/agent-shared/blob/main/spec/agent-shared.md)) keeps such a table for the clients it places hooks into, as `events` and `checked` on each row of its agent table:

| Client | Versions checked | Events read |
|---|---|---|
| Claude Code | 2.1.330 | 33, including all five of v1.1 |
| Codex | 0.124.0 to 0.171.0 | 14, including all five of v1.1 |
| GitHub Copilot CLI | 1.0.62 to 1.0.114 | 11, including all five of v1.1 |

When a hook's event is not in a client's row, the hook is left out of that client and the run names it, for example `left the ConfigChange hook ... out of Codex: it reads no ConfigChange event`.
When the installed client is older than the lowest version checked, nothing is written for that client and the run says so; a newer version is written and named, since clients release often.

## Who would adopt it

- agent-shared reports skipped hooks this way today for Claude Code, Codex, and GitHub Copilot CLI, and keeps its table up to date with each client release.
- Every client implementing v1.1 portable hooks already has to decide what to do with a handler it does not support; the requirement asks only that the decision is visible.

## Open questions

- Where the table lives: in the specification, in its conformance materials, or in a separate document the implementers update.
- Whether a plugin can declare the events it needs, so a client refuses before installing rather than after.

This proposal was prepared with an AI coding agent and reviewed by me.
