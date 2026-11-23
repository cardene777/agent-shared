#!/usr/bin/env bash
# Stops a shell command that force-pushes. The agent passes the tool call as JSON on stdin, with the
# command in tool_input.command; exit status 2 stops the call and shows the message to the agent.
input="$(cat)"
command="$(printf '%s' "$input" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))')"
case "$command" in
  *"push --force"* | *"push -f"*)
    echo "A force push rewrites history others may have pulled. Push without --force." >&2
    exit 2
    ;;
esac
exit 0
