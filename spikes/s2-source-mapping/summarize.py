"""Summarize `out/*.tsv` from `measure.jl`. Run: `uv run --with polars summarize.py <file|codetracking>`."""

import sys
from pathlib import Path

import polars as pl

OUT = Path(__file__).parent / "out" / sys.argv[1]
CORPUS = ["Distances", "DataStructures", "JSON"]
# Statements a finding can point at: calls, allocations, assignments of calls.
FINDABLE = ["call", "new", "broadcast", "kwcall"]

pl.Config.set_tbl_rows(60)
pl.Config.set_tbl_cols(12)
pl.Config.set_tbl_width_chars(160)

statements = pl.read_csv(OUT / "statements.tsv", separator="\t", infer_schema_length=0, quote_char=None).filter(pl.col("package").is_in(CORPUS))
methods = pl.read_csv(OUT / "methods.tsv", separator="\t", quote_char=None).filter(pl.col("package").is_in(CORPUS))


def shares(frame: pl.DataFrame, by: list[str]) -> pl.DataFrame:
    """Return statement count and share per mapping class for each group."""
    return (
        frame.group_by(by)
        .agg(
            pl.len().alias("n"),
            *[(pl.col("mapping") == cls).mean().round(3).alias(cls) for cls in ["exact", "ambiguous", "line_only", "foreign_line", "missing"]],
        )
        .sort("n", descending=True)
    )


print("== methods by status\n", methods.group_by("status").len().sort("len", descending=True))
print("== methods by category and status\n", methods.group_by("category", "status").len().sort("len", descending=True))
print("== all statements\n", shares(statements, ["package"]))
print("== all statements, total\n", shares(statements.with_columns(pl.lit("all").alias("scope")), ["scope"]))
findable = statements.filter(pl.col("kind").is_in(FINDABLE))
print("== findable statements, total\n", shares(findable.with_columns(pl.lit("findable").alias("scope")), ["scope"]))
print("== findable statements by package\n", shares(findable, ["package"]))
print("== findable statements by method category\n", shares(findable, ["category"]))
print("== findable statements by kind\n", shares(findable, ["kind"]))
print("== findable statements by enclosing macro\n", shares(findable.filter(pl.col("macro") != ""), ["macro"]).head(20))
print("== callee check on exact call spans\n", statements.filter(pl.col("callee_check") != "na").group_by("callee_check").len())
print(
    "== time per method (s)\n",
    methods.select(
        pl.len().alias("methods"),
        pl.col("infer_seconds").sum().round(2).alias("infer_total"),
        pl.col("map_seconds").sum().round(2).alias("map_total"),
        pl.col("map_seconds").median().alias("map_median"),
        pl.col("map_seconds").max().round(3).alias("map_max"),
    ),
)
