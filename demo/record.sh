#!/usr/bin/env bash
# Records demo/demo.cast by driving nvim inside tmux, then renders assets/demo.gif (README)
# and demo/demo.mp4 (1280x800, git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d demo/.deps/tokyonight.nvim ] || git clone -q --depth 1 https://github.com/folke/tokyonight.nvim demo/.deps/tokyonight.nvim
cast=demo/demo.cast
rm -f "$cast"
tmux kill-session -t quill-demo 2>/dev/null || true
tmux new-session -d -s quill-demo -x 104 -y 27 \
  "asciinema rec -q --overwrite -f asciicast-v2 --window-size 104x27 -c 'nvim -u demo/init.lua -i NONE demo/sample.lua' $cast"
k() { tmux send-keys -t quill-demo "$@"; }
type_slow() { local s=$1; for ((i = 0; i < ${#s}; i++)); do k -l "${s:i:1}"; sleep 0.05; done; }
source demo/drive.sh
k : q a ! Enter; sleep 1
tmux kill-session -t quill-demo 2>/dev/null || true

# Theme only affects padding and default colors; nvim paints its own truecolor background.
theme=1a1b26,c0caf5,15161e,f7768e,9ece6a,e0af68,7aa2f7,bb9af7,7dcfff,a9b1d6,414868,f7768e,9ece6a,e0af68,7aa2f7,bb9af7,7dcfff,c0caf5
agg --font-family "JetBrains Mono,DejaVu Sans Mono,DejaVu Sans" --font-size 20 --line-height 1.45 --theme "$theme" \
  --idle-time-limit 3 --fps-cap 30 "$cast" demo/raw.gif
fit="scale=1280:800:force_original_aspect_ratio=decrease:flags=lanczos,pad=1280:800:(ow-iw)/2:(oh-ih)/2:color=0x1a1b26"
ffmpeg -loglevel error -y -i demo/raw.gif -vf "$fit" -movflags +faststart -pix_fmt yuv420p -c:v libx264 -crf 18 demo/demo.mp4
ffmpeg -loglevel error -y -i demo/demo.mp4 \
  -vf "fps=12,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  assets/demo.gif
rm -f demo/raw.gif
