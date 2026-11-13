# Stands in for `codex` and `claude`: logs argv and stdin, then replays a recorded
# JSONL stream chosen by a marker in the prompt (SLOW, UNAUTHORIZED, CRASH, HANG).
import json, os, sys, time

name = os.path.basename(sys.argv[1])
prompt = sys.stdin.read()
with open(os.environ["QUILL_FAKE_LOG"], "a") as f:
    f.write(json.dumps({"cli": name, "argv": sys.argv[2:], "stdin": prompt, "cwd": os.getcwd()}) + "\n")

fixtures = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures")
def replay(fixture, delay=0.005):
    for line in open(os.path.join(fixtures, fixture)):
        # Split each line in two writes to exercise partial-line buffering.
        for part in (line[:9], line[9:]):
            sys.stdout.write(part)
            sys.stdout.flush()
            time.sleep(delay)

if "HANG" in prompt:
    time.sleep(60)
elif "CRASH" in prompt:
    sys.stderr.write("panic: something broke\n")
    sys.exit(3)
elif "UNAUTHORIZED" in prompt:
    replay(name + "_unauthorized.jsonl")
    sys.exit(1)
elif "SLOW" in prompt:
    for _ in range(200):
        replay(name + "_ok.jsonl", 0.05)
else:
    replay(name + "_ok.jsonl")
