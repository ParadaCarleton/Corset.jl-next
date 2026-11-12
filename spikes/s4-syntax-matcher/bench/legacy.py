"""Time legacy Corset `check` per corpus package: wall seconds and peak child RSS.

Usage: python3 -I bench/legacy.py <corset-checkout> <runs> <check-flags|-> <package-dir>...
Each run is fresh process; first run after precompile counts as cold.
"""
import resource
import subprocess
import sys
import time


def measure(corset: str, flags: list[str], package: str) -> tuple[float, int, int]:
    """Run one check; return wall seconds, exit code, peak RSS of process tree in MB."""
    command = ["julia", "--startup-file=no", f"--project={corset}", "-e", "using Corset; exit(Corset.main(ARGS))", "--", "check", *flags, package]
    start = time.monotonic()
    result = subprocess.run(command, capture_output=True, text=True)
    wall = time.monotonic() - start
    peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // 1024
    sys.stderr.write(result.stdout[-1500:] + result.stderr[-1500:])
    return wall, result.returncode, peak


def main(corset: str, runs: int, flags: list[str], packages: list[str]) -> None:
    for package in packages:
        for i in range(runs):
            wall, code, peak = measure(corset, flags, package)
            print(f"{package.rsplit('/', 1)[-1]} run={i} wall={wall:.1f}s exit={code} peak_child_rss_max_so_far={peak}MB", flush=True)


main(sys.argv[1], int(sys.argv[2]), [] if sys.argv[3] == '-' else sys.argv[3].split(','), sys.argv[4:])
