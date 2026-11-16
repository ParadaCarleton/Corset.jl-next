"""Print `possible` share per corpus package. Usage: python3 score.py results repair2"""

import re
import sys

for pkg in ["Distances", "DataStructures", "JSON"]:
    text = open(f"{sys.argv[1]}/{pkg}-{sys.argv[2]}.txt").read()
    tally = {(kind, cert): int(n) for kind, cert, n in re.findall(r"^(plain|bang|generated) (DEFINITE|POSSIBLE|NONE) (\d+)", text, re.M)}
    total = sum(tally.values())
    if total == 0:
        sys.exit(f"{pkg}: no verdicts")
    possible = sum(n for (_, cert), n in tally.items() if cert == "POSSIBLE")
    definite = sum(n for (_, cert), n in tally.items() if cert == "DEFINITE")
    summary_s = re.search(r"summary_s=([\d.]+)", text).group(1)
    warm_s = re.search(r"warm_s=([\d.]+)", text).group(1)
    print(f"{pkg:15} total {total} possible {possible} {100 * possible / total:.1f}% definite {definite} summary_s {summary_s} warm_s {warm_s}")
