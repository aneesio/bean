#!/usr/bin/env bash
# Content-free CPU/RSS samples for one explicitly supplied Bean process.
# This does not inspect windows, fields, writing, clipboard, or provider keys.
set -euo pipefail
[[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || { echo 'Usage: profile_bean_runtime.sh PID [seconds, 1-60]' >&2; exit 2; }
python3 - "$1" "${2:-15}" <<'PY'
import json, math, subprocess, sys, time
pid = int(sys.argv[1])
duration = float(sys.argv[2])
if not math.isfinite(duration) or not 1 <= duration <= 60:
    raise SystemExit('Duration must be 1-60 seconds.')
command = subprocess.check_output(['ps','-p',str(pid),'-o','comm='],text=True).strip()
if not command.endswith('/Bean.app/Contents/MacOS/Bean'):
    raise SystemExit('PID is not a Bean application executable.')
samples = []
deadline = time.monotonic() + duration
while time.monotonic() < deadline:
    output = subprocess.check_output(['ps','-p',str(pid),'-o','%cpu=','-o','rss='],text=True).split()
    if len(output) != 2:
        raise SystemExit('Bean exited during sampling.')
    samples.append((float(output[0]),int(output[1])))
    time.sleep(.25)
cpu = sorted(sample[0] for sample in samples)
print(json.dumps({'samples':len(samples),'seconds':duration,
  'cpu_percent_mean':round(sum(cpu)/len(cpu),2),
  'cpu_percent_p95':cpu[max(0,math.ceil(.95*len(cpu))-1)],
  'rss_mib_max':round(max(sample[1] for sample in samples)/1024,2),
  'measurement':'process-wide ps CPU/RSS samples; activity must be recorded separately; no writing collected'},indent=2))
PY
