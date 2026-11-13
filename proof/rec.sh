#!/usr/bin/env bash
# rec.sh NAME WORKTREE BRANCH DRIVE [cols rows]: records /tmp/proof/NAME.gif from a tmux-driven nvim.
set -euo pipefail
name=$1 wt=$2 branch=$3 drive=$4 cols=${5:-104} rows=${6:-27}
cd /tmp/proof
export QUILL_FAKE_LOG=/tmp/proof/$name.fake.log QUILL_ROOT=$wt PROOF_BRANCH=$branch PROOF_PORT=${PROOF_PORT:-18799}
export PROOF_LOG=/tmp/proof/$name.server.log PROOF_EMPTY_HOME=$(mktemp -d -p /var/tmp) PROOF_COPILOT_DIR=/tmp/proof/copilot-config
: > "$PROOF_LOG"
mkdir -p "$PROOF_COPILOT_DIR"
echo '{"github.com:Iv1.b507a08c87ecfe98":{"user":"juswag","oauth_token":"gho_demo","githubAppId":"Iv1.b507a08c87ecfe98"}}' > "$PROOF_COPILOT_DIR/apps.json"
python3 "$wt/tests/sse_server.py" "$PROOF_PORT" "$PROOF_LOG" & srv=$!
trap "kill $srv 2>/dev/null" EXIT
sleep 0.5
tmux kill-session -t proof 2>/dev/null || true
tmux new-session -d -s proof -x "$cols" -y "$rows" \
  "asciinema rec -q --overwrite -f asciicast-v2 --window-size ${cols}x${rows} -c 'nvim -u /tmp/proof/init.lua -i NONE sample.lua' $name.cast"
k() { tmux send-keys -t proof "$@"; }
cmd() { local s=$1; k Escape; k -l ":"; for ((i = 0; i < ${#s}; i++)); do k -l "${s:i:1}"; sleep 0.02; done; sleep 0.3; k Enter; }
type_slow() { local s=$1; for ((i = 0; i < ${#s}; i++)); do k -l "${s:i:1}"; sleep 0.04; done; }
edit() { k gg; sleep 0.3; k V j; sleep 0.4; k Space k; sleep 0.8; type_slow "$1"; sleep 0.4; k Enter; }
sleep 1.5
source "$drive"
k Escape; cmd "qa!"; sleep 1
tmux kill-session -t proof 2>/dev/null || true
theme=1a1b26,c0caf5,15161e,f7768e,9ece6a,e0af68,7aa2f7,bb9af7,7dcfff,a9b1d6,414868,f7768e,9ece6a,e0af68,7aa2f7,bb9af7,7dcfff,c0caf5
agg --font-family "JetBrains Mono,DejaVu Sans Mono,DejaVu Sans" --font-size 18 --line-height 1.4 --theme "$theme" \
  --idle-time-limit 2.5 --fps-cap 15 "$name.cast" "$name.raw.gif" 2>/dev/null
d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$name.raw.gif")
ffmpeg -loglevel error -y -t "$(python3 -c "print($d-1.2)")" -i "$name.raw.gif" \
  -vf "fps=10,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" "$name.gif"
ls -la "$name.gif"
