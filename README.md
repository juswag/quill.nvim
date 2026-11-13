# pr-assets

Recordings and test logs that PR descriptions link to. This branch is not part of the plugin.

`proof/` holds the harness that made them. `proof/rec.sh NAME WORKTREE BRANCH DRIVE` starts
`tests/sse_server.py` from WORKTREE and records nvim in tmux with asciinema. agg renders
NAME.gif. `proof/init.lua` defines `:Proof <scene>`, which switches provider setups on
camera, and `:ProofMonitor`, a bottom pane that lists CLI processes and mock-server requests.
