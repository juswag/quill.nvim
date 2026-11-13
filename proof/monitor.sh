#!/usr/bin/env bash
# Bottom pane: live fake/real CLI processes and the requests the local mock server received.
log=$1
while true; do
  out=$(
    printf '\033[1mprocesses\033[0m (pgrep -af "fake_cli.py|codex exec|claude -p"):\n'
    pgrep -af 'fake_cli.py|codex exec|claude -p' | grep -v pgrep | cut -c1-100 | sed 's/^/  /' || true
    [ -z "$(pgrep -f 'fake_cli.py|codex exec|claude -p')" ] && echo "  (none)"
    if [ -n "$log" ] && [ -s "$log" ]; then
      printf '\033[1mmock server requests\033[0m (%s):\n' "$log"
      tail -n 3 "$log" | jq -r '"  \(if .body then "POST" else "GET " end) \(.path)  Authorization: \(.headers.Authorization // "-")"' | cut -c1-100
    fi
  )
  printf '\033[H\033[2J%s\n' "$out"
  sleep 0.3
done
