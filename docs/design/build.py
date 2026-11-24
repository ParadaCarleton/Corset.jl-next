# /// script
# requires-python = ">=3.12"
# dependencies = ["markdown-it-py>=3"]
# ///
"""Render design parts (*.md, *.toml in this directory) into rules-rewrite.html.

Run: uv run docs/design/build.py
"""
import html
import re
import tomllib
from collections import Counter
from pathlib import Path

from markdown_it import MarkdownIt

DESIGN = Path(__file__).resolve().parent
GROUPS = ("correctness", "safety", "performance", "composability", "readability", "restriction")
# (file or generated table, section id) in page order
ORDER = [("principles.md", "principles"), ("footguns", "footguns"), ("pipeline.md", "pipeline"), ("stages", "stages"),
         ("rules", "rules"), ("findings.md", "findings"), ("types.md", "types"), ("effects.md", "effects"), ("lifecycle.md", "lifecycle"),
         ("architecture.md", "architecture"), ("plan.md", "plan"), ("phase5.md", "phase5"), ("glossary.md", "glossary")]


def load(name: str, table: str) -> list[dict]:
    return tomllib.loads((DESIGN / name).read_text())[table]


footguns, rules, stages = load("footguns.toml", "footgun"), load("rules.toml", "rule"), load("stages.toml", "stage")
by_id = {footgun["id"]: footgun for footgun in footguns}
assert len(by_id) == len(footguns), "footgun IDs must be unique"
owner = Counter(ident for rule in rules for ident in rule["footguns"])
assert set(owner) == set(by_id) and all(count == 1 for count in owner.values()), "each footgun belongs to exactly one rule"
for rule in rules:
    assert len({by_id[ident]["group"] for ident in rule["footguns"]}) == 1, f"{rule['name']}: one group per rule"
assert {footgun["stage"] for footgun in footguns} <= {stage["name"] for stage in stages}, "unknown stage"
for rule in rules:
    names = {by_id[ident]["stage"] for ident in rule["footguns"]}
    assert len(names) == 1 or "syntax" not in names, f"{rule['name']}: syntax stage mixed with later stage"


def code(text: str) -> str:
    """Escape text and turn `spans` into <code>."""
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(text, quote=False))


def chip(group: str) -> str:
    return f'<span class="chip g-{group}">{group}</span>'


def filter_bar(label: str) -> str:
    buttons = "".join(f'<button type="button" data-filter="{name}" aria-pressed="{str(name == "all").lower()}">{name}</button>'
                      for name in ("all", *GROUPS))
    return f'<div class="filter" role="group" aria-label="{label}">{buttons}</div>'


def table(head: list[str], rows: list[tuple[str, list[str]]], filterable: bool) -> str:
    head_html = "".join(f"<th>{cell}</th>" for cell in head)
    body = "\n".join(f'<tr data-group="{group}">' + "".join(f"<td>{cell}</td>" for cell in cells) + "</tr>" for group, cells in rows)
    data = " data-table" if filterable else ""
    return f'<div class="scroll"><table{data}><thead><tr>{head_html}</tr></thead><tbody>\n{body}\n</tbody></table></div>'


def deferred(footgun: dict) -> bool:
    return "Later" in footgun.get("note", "")


def footguns_section() -> str:
    rows = [(f["group"], [f"F{f['id']}", f["area"], code(f["text"]), code(f.get("example", "")), chip(f["group"]), f["stage"], code(f.get("note", ""))])
            for f in footguns]
    return ("<h2>Footguns</h2><p>Source of truth for rewrite. Each line names one problem Corset prevents. Data: <code>footguns.toml</code>.</p>"
            + filter_bar("Filter footguns by group") + table(["ID", "Area", "Footgun", "Example", "Group", "Stage", "Note"], rows, True))


def stages_section() -> str:
    cards = []
    for stage in stages:
        chips = "".join(f'<span class="chip g-{f["group"]}" title="{html.escape(f["text"].replace("`", ""))}">F{f["id"]}</span>'
                        for f in footguns if f["stage"] == stage["name"])
        cards.append(f'<div class="stage"><h3><span>{stage["name"]}</span>{stage["title"]}</h3><p>{code(stage["text"])}</p><div class="rules">{chips}</div></div>')
    return ("<h2>Analysis stages</h2><p>Each stage computes facts once per run, in pipeline order. Rule belongs to last stage it reads. Chips are footgun IDs; hover for text. Data: <code>stages.toml</code>.</p>"
            f'<div class="stages">{"".join(cards)}</div>')


def rules_section() -> str:
    rows = []
    for rule in rules:
        group = by_id[rule["footguns"][0]]["group"]
        names = " ".join(sorted({by_id[ident]["stage"] for ident in rule["footguns"]}))
        listed = "<br>".join(f"F{ident} {code(by_id[ident]['text'])}" for ident in rule["footguns"])
        rows.append((group, [f"<code>{rule['name']}</code>", chip(group), names, listed, code(rule.get("note", ""))]))
    return ("<h2>Rules</h2><p>Rule is unit of config, opt-out and group. It covers one footgun, or several with same group and same analysis. Data: <code>rules.toml</code>.</p>"
            + filter_bar("Filter rules by group") + table(["Rule", "Group", "Stage", "Footguns", "Note"], rows, True))


def phase_count(spec: str) -> int:
    """Count footguns a plan row covers: listed stages, or deferred ones for 'later'."""
    if spec == "later":
        return sum(deferred(f) for f in footguns)
    return sum(f["stage"] in spec.split() and not deferred(f) for f in footguns)


markdown = MarkdownIt("commonmark", {"html": True}).enable("table")


def cards(rendered: str) -> str:
    """Wrap each h3 block in a card; h2 also ends a card."""
    parts = re.split(r"(?=<h[23][ >])", rendered)
    return "".join(f'<div class="decision">{part}</div>' if part.startswith("<h3") else part for part in parts)


def markdown_section(name: str) -> str:
    text = re.sub(r"\{\{count:([^}]+)\}\}", lambda match: str(phase_count(match.group(1))), (DESIGN / name).read_text())
    rendered = markdown.render(text)
    rendered = re.sub(r"<h1>(.*?)</h1>", r"<h2>\1</h2>", rendered, count=1)
    rendered = re.sub(r"<table>", '<div class="scroll"><table>', rendered).replace("</table>", "</table></div>")
    return cards(rendered)


GENERATED = {"footguns": footguns_section, "stages": stages_section, "rules": rules_section}
sections = "\n\n".join(f'<section id="{ident}">\n{GENERATED[part]() if part in GENERATED else markdown_section(part)}\n</section>' for part, ident in ORDER)
nav = " · ".join(f'<a href="#{ident}">{ident}</a>' for _, ident in ORDER)
page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Corset Rewrite Plan</title>
<style>
{(DESIGN / "page.css").read_text()}</style>
</head>
<body>
<main>
<header>
  <div class="eyebrow">Corset.jl · design · generated from docs/design parts</div>
  <h1>Corset Rewrite Plan</h1>
  <p class="lede">Footguns, rules, shared analyses and decisions for rewrite of Corset. Source files: <code>docs/design/README.md</code> lists them. Legacy rule names live in <code>rules-rewrite-history.md</code>.</p>
  <div class="meta"><span><b>{len(footguns)}</b> footguns</span><span><b>{len(rules)}</b> rules</span><span><b>{len(stages)}</b> analysis stages</span></div>
  <nav class="note">{nav}</nav>
</header>

{sections}

<footer><p>Generated by <code>uv run docs/design/build.py</code>. Edit parts, never this file.</p></footer>
</main>
<script>
for (const group of document.querySelectorAll('.filter')) {{
  const table = group.parentElement.querySelector('table[data-table]');
  group.addEventListener('click', (event) => {{
    const button = event.target.closest('button[data-filter]');
    if (!button) return;
    for (const other of group.querySelectorAll('button')) other.setAttribute('aria-pressed', String(other === button));
    const filter = button.dataset.filter;
    for (const row of table.tBodies[0].rows) row.hidden = filter !== 'all' && !row.dataset.group.split(' ').includes(filter);
  }});
}}
</script>
</body>
</html>
"""
(DESIGN / "rules-rewrite.html").write_text(page)
print(f"{len(footguns)} footguns, {len(rules)} rules, {len(stages)} stages")
