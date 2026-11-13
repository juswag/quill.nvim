wait_gone() { sleep 2; for _ in $(seq 120); do pgrep -f "$1" >/dev/null || break; sleep 0.5; done; sleep 5; }
cmd "Proof codex-real"; sleep 1
cmd "ProofMonitor"; sleep 1
edit "bump x to 2"; wait_gone "codex exec"
k Enter; sleep 1
cmd "Proof claude-real"; sleep 1
edit "bump x to 2"; wait_gone "claude -p"
k Enter; sleep 1.5
