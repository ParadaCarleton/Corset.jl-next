"""Wall seconds and peak RSS of one command. Usage: python3 -I bench/wall.py <command>..."""
import resource
import subprocess
import sys
import time

start = time.monotonic()
code = subprocess.run(sys.argv[1:], stdout=subprocess.DEVNULL).returncode
print(f"wall={time.monotonic() - start:.2f}s exit={code} peak_rss={resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss // 1024}MB")
