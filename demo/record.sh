#!/usr/bin/env bash
# Records demo/demo.cast by driving nvim inside tmux, logging each key and step to
# demo/events.txt, then renders assets/demo.gif, assets/demo-dark.gif and their MP4s with demo/render.py.
# Needs tmux, asciinema, python3 with pillow and pyte, and ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."
cols=90 rows=22
rm -f demo/demo.cast demo/events.txt
tmux kill-session -t quill-demo 2>/dev/null || true
t0=$(date +%s.%N)
tmux new-session -d -s quill-demo -x $cols -y $rows \
  "asciinema rec -q --overwrite -f asciicast-v2 --window-size ${cols}x${rows} -c 'nvim -u demo/init.lua -i NONE demo/sample.lua' demo/demo.cast"
now() { python3 -c "import time; print(round(time.time() - $t0, 3))"; }
log() { echo "$1 $(now) $2" >> demo/events.txt; }
step() { log step "$1"; }
k() { log key "$*"; tmux send-keys -t quill-demo "$@"; }
type_text() {
  log key "\"$1\""
  for ((i = 0; i < ${#1}; i++)); do tmux send-keys -t quill-demo -l "${1:i:1}"; sleep 0.055; done
}

sleep 2.0
step "Select and describe"
k 3G; sleep 0.5; k V; sleep 0.4; k 8G; sleep 0.9
k Space k; sleep 0.9
type_text "add error handling"; sleep 0.5
step "Streams in as a preview"
k Enter; sleep 3.4
step "Follow up to refine"
k f; sleep 0.9
type_text "add type annotations"; sleep 0.5
k Enter; sleep 3.6
step "Accept or reject each hunk"
k ]h; sleep 1.1
k a; sleep 1.1
k r; sleep 1.1
k a; sleep 0.3
step "Lands as one change"; sleep 1.5
step "One u undoes it all"
k u; sleep 2.2
step end
tmux send-keys -t quill-demo : q a ! Enter; sleep 1
tmux kill-session -t quill-demo 2>/dev/null || true
[ -n "${NO_RENDER:-}" ] || python3 demo/render.py
