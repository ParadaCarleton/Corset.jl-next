"""Cross-tabulate julia-anal mutation.jl kinds against spike verdicts. Usage: python3 join.py <anal_out> <spike_results> <tag>"""

import collections
import csv
import sys

anal_dir, spike_dir, tag = sys.argv[1:4]


def is_bang(name: str) -> bool:
    return name.endswith("!") and name != "!"


for pkg in ["Distances", "DataStructures", "JSON"]:
    anal = collections.defaultdict(list)
    with open(f"{anal_dir}/{pkg}-anal.tsv") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            anal[(row["name"], row["location"])].append((row["head"], row["names"]))
    flags = collections.defaultdict(list)
    with open(f"{spike_dir}/{pkg}-{tag}-flags.tsv") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            flags[(row["name"], row["location"])].append(row["flag"])
    head_tab, names_tab = collections.Counter(), collections.Counter()
    examples = collections.defaultdict(list)
    ambiguous = generated = 0
    for (name, loc), kinds in anal.items():
        if name.startswith("#"):
            generated += len(kinds)
            continue
        fl = flags.get((name, loc), [])
        if len(kinds) > 1 and (len(set(kinds)) > 1 or fl):
            ambiguous += len(kinds)
            continue
        if is_bang(name):
            ours = "NONE" if "SPURIOUS!" in fl else "POSSIBLE" if "bang-possible" in fl else "DEFINITE"
        else:
            ours = "DEFINITE" if "MISSING!" in fl else "POSSIBLE" if "missing?" in fl else "NONE"
        for h, n in kinds:
            head_tab[(ours, h)] += 1
            names_tab[(ours, n)] += 1
            examples[(ours, h, n)].append(f"{name} {loc.rsplit('/', 1)[-1]}")
    total = sum(head_tab.values())
    print(f"== {pkg}: {total} named methods compared; {generated} generated and {ambiguous} ambiguous left out")
    for label, tab, cols in (("head", head_tab, ["clean", "writes_arg", "writes_global", "unknown", "error"]),
                             ("names", names_tab, ["clean", "writes_arg", "writes_global", "error"])):
        print(f"  julia-anal {label}: " + "  ".join(f"{c}={sum(v for (o, k), v in tab.items() if k == c)}" for c in cols))
        for ours in ["DEFINITE", "POSSIBLE", "NONE"]:
            print(f"    spike {ours:8} " + "  ".join(f"{c}={tab[(ours, c)]}" for c in cols))
    for key in [("DEFINITE", "clean", "clean"), ("DEFINITE", "unknown", "clean"), ("NONE", "writes_arg", "writes_arg"), ("POSSIBLE", "clean", "clean")]:
        if examples[key]:
            print(f"  ours={key[0]} head={key[1]} names={key[2]}: {len(examples[key])} e.g. {examples[key][:6]}")
