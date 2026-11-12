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
GROUPS = ("correctness", "performance", "composability", "readability")
# (file or generated table, section id) in page order
ORDER = [("principles.md", "principles"), ("footguns", "footguns"), ("pipeline.md", "pipeline"), ("families", "families"),
         ("rules", "rules"), ("findings.md", "findings"), ("types.md", "types"), ("effects.md", "effects"),
         ("architecture.md", "architecture"), ("plan.md", "plan"), ("glossary.md", "glossary")]


def load(name: str, table: str) -> list[dict]:
    return tomllib.loads((DESIGN / name).read_text())[table]


footguns, rules, families = load("footguns.toml", "footgun"), load("rules.toml", "rule"), load("families.toml", "family")
by_id = {footgun["id"]: footgun for footgun in footguns}
assert len(by_id) == len(footguns), "footgun IDs must be unique"
owner = Counter(ident for rule in rules for ident in rule["footguns"])
assert set(owner) == set(by_id) and all(count == 1 for count in owner.values()), "each footgun belongs to exactly one rule"
for rule in rules:
    assert len({by_id[ident]["group"] for ident in rule["footguns"]}) == 1, f"{rule['name']}: one group per rule"
assert {footgun["family"] for footgun in footguns} <= {family["letter"] for family in families}, "unknown family letter"
for rule in rules:
    letters = {by_id[ident]["family"] for ident in rule["footguns"]}
    assert len(letters) == 1 or not letters & {"A", "B"}, f"{rule['name']}: syntax family mixed with later family"


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
    rows = [(f["group"], [f"F{f['id']}", f["area"], code(f["text"]), code(f.get("example", "")), chip(f["group"]), f["family"], code(f.get("note", ""))])
            for f in footguns]
    return ("<h2>Footguns</h2><p>Source of truth for rewrite. Each line names one problem Corset prevents. Data: <code>footguns.toml</code>.</p>"
            + filter_bar("Filter footguns by group") + table(["ID", "Area", "Footgun", "Example", "Group", "Family", "Note"], rows, True))


def families_section() -> str:
    cards = []
    for family in families:
        chips = "".join(f'<span class="chip g-{f["group"]}" title="{html.escape(f["text"].replace("`", ""))}">F{f["id"]}</span>'
                        for f in footguns if f["family"] == family["letter"])
        cards.append(f'<div class="family"><h3><span>{family["letter"]}</span>{family["title"]}</h3><p>{code(family["text"])}</p><div class="rules">{chips}</div></div>')
    return ("<h2>Analysis families</h2><p>Each family is one analysis. Rules inside family share its code and output. Chips are footgun IDs; hover for text. Data: <code>families.toml</code>.</p>"
            f'<div class="families">{"".join(cards)}</div>')


def rules_section() -> str:
    rows = []
    for rule in rules:
        group = by_id[rule["footguns"][0]]["group"]
        letters = " ".join(sorted({by_id[ident]["family"] for ident in rule["footguns"]}))
        listed = "<br>".join(f"F{ident} {code(by_id[ident]['text'])}" for ident in rule["footguns"])
        rows.append((group, [f"<code>{rule['name']}</code>", chip(group), letters, listed, code(rule.get("note", ""))]))
    return ("<h2>Rules</h2><p>Rule is unit of config, opt-out and group. It covers one footgun, or several with same group and same analysis. Data: <code>rules.toml</code>.</p>"
            + filter_bar("Filter rules by group") + table(["Rule", "Group", "Family", "Footguns", "Note"], rows, True))


def phase_count(spec: str) -> int:
    """Count footguns a plan row covers: listed families, or deferred ones for 'later'."""
    if spec == "later":
        return sum(deferred(f) for f in footguns)
    return sum(f["family"] in spec.split() and not deferred(f) for f in footguns)


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


GENERATED = {"footguns": footguns_section, "families": families_section, "rules": rules_section}
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
  <div class="meta"><span><b>{len(footguns)}</b> footguns</span><span><b>{len(rules)}</b> rules</span><span><b>{len(families)}</b> analysis families</span></div>
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
print(f"{len(footguns)} footguns, {len(rules)} rules, {len(families)} families")
