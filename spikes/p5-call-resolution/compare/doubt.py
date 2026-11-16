"""Split `possible` verdicts by doubt test (CLAUDE.md). Usage: python3 doubt.py <results_dir> <tag>"""

import collections
import re
import sys

# Corset limit; compiler could settle: blind spot, coverage line only
BLIND = {"alias", "candidate_nosummary"}
# dispatch open in code; Corset did not examine every candidate
OPEN = {"too_many_candidates", "apply_unresolved"}
# doubt in code: candidates disagree, callee unknown until run time, unknown C call
DOUBT = {"join", "typecall", "callee_unknown", "callback", "foreign"}
BARS = {"Distances": 38.7, "DataStructures": 28.6, "JSON": 30.4}

results, tag = sys.argv[1:3]
print(f"{'package':15} {'total':>5} {'possible':>8} {'blind':>5} {'open':>4} {'doubt':>5}  {'all %':>6} {'no blind %':>10} {'bar %':>5}")
for pkg, bar in BARS.items():
    text = open(f"{results}/{pkg}-{tag}.txt").read()
    tally = {(k, c): int(n) for k, c, n in re.findall(r"^(plain|bang|generated) (DEFINITE|POSSIBLE|NONE) (\d+)", text, re.M)}
    total = sum(tally.values())
    leaves = collections.Counter(line.split("\t")[1].split()[0] for line in open(f"{results}/{pkg}-{tag}-blame.tsv"))
    unknown = set(leaves) - BLIND - OPEN - DOUBT
    if unknown:
        sys.exit(f"unclassified leaf kinds: {unknown}")
    possible = sum(n for (_, c), n in tally.items() if c == "POSSIBLE")
    if possible != sum(leaves.values()):
        sys.exit(f"{pkg}: {possible} possible verdicts but {sum(leaves.values())} blame rows")
    blind, opened, doubt = (sum(leaves[k] for k in s) for s in (BLIND, OPEN, DOUBT))
    print(f"{pkg:15} {total:5} {possible:8} {blind:5} {opened:4} {doubt:5}  {100 * possible / total:6.1f} {100 * (possible - blind) / total:10.1f} {bar:5.1f}")
