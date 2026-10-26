#!/usr/bin/env python3
"""Runs `aiken check` and prints one line per test: status, memory and CPU units.

Usage: scripts/test-report.py [extra aiken check arguments], e.g. `-m campaign_escrow`.
Exits non-zero when a test fails or the project does not type-check.
Budget per transaction (mainnet, protocol 11): 16 500 000 memory units, 10 000 000 000 CPU steps.
"""
import json
import subprocess
import sys

MAX_MEM = 16_500_000
MAX_CPU = 10_000_000_000

proc = subprocess.run(
    ["aiken", "check", *sys.argv[1:]], capture_output=True, text=True
)
start = proc.stdout.find("{")
if start < 0:
    sys.stdout.write(proc.stdout + proc.stderr)
    sys.exit(proc.returncode or 1)
report = json.loads(proc.stdout[start:])
failed = 0
for module in report.get("modules", []):
    for test in module.get("tests", []):
        status = test.get("status")
        units = test.get("execution_units") or {}
        mem, cpu = units.get("mem"), units.get("cpu")
        share = (
            f"{100 * mem / MAX_MEM:5.1f}% mem {100 * cpu / MAX_CPU:5.1f}% cpu"
            if mem is not None
            else f"{test.get('iterations', '?')} runs"
        )
        mark = "ok  " if status == "pass" else "FAIL"
        if status != "pass":
            failed += 1
        print(f"{mark} {module['name']}.{test['title']:<70} {share}")
        if status != "pass":
            for key in ("traces", "counterexample", "assertion"):
                if test.get(key):
                    print(f"     {key}: {test[key]}")
summary = report.get("summary", {})
print(f"\n{summary}")
sys.stderr.write(proc.stderr[-4000:] if proc.returncode and failed == 0 else "")
sys.exit(1 if failed or proc.returncode else 0)
