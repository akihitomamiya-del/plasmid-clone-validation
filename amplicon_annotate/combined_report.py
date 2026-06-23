#!/usr/bin/env python
"""Amplicon annotation report: pLannotate (linear) feature map + feature table.

Runs inside the wf-clone-validation SIF (ezcharts 0.12.0 + bokeh + plannotate),
with PYTHONPATH pointing at that workflow's `bin/` so `workflow_glue.bokeh_plot`
is importable. Consumes the `plannotate_report.json` produced by our patched
`run_plannotate.py --linear` (Stage 3) and writes a single HTML report.

Per sample the JSON holds (see run_plannotate.py):
  { "<sample>": { "sample_name": str,
                  "plot":        <RAW annotation df as DataFrame.to_json()>,
                  "annotations": <CLEANED display df as DataFrame.to_json()>,
                  "seq_len":     int }, ... }
`plot` feeds get_bokeh() (raw columns qstart/qend/qlen/pi_permatch/db/...);
`annotations` is the human-facing table. The two keys are counter-intuitively
named because of an unpack in run_plannotate.py -- do not swap them.
"""
import argparse
import json

import pandas as pd
from dominate.tags import p
from dominate.util import raw
from ezcharts.components.ezchart import EZChart
from ezcharts.components.reports import labs
from ezcharts.layout.snippets import Tabs
from ezcharts.layout.snippets.table import DataTable
from ezcharts.plots import BokehPlot

# get_bokeh: plannotate's renderer, ported to bokeh 3 in the wf-clone-validation
# glue. linear=True annotates a linearised construct (origin tick, no doubling).
from workflow_glue.bokeh_plot import get_bokeh


def _read_df(json_str):
    """Decode a pandas DataFrame.to_json() payload; tolerate empty/missing."""
    if not json_str:
        return pd.DataFrame()
    try:
        return pd.read_json(json_str)
    except ValueError:
        return pd.DataFrame()


def _clean_table(annotations):
    """Drop the bookkeeping column and prettify the strand for display."""
    df = annotations.copy()
    if "Plasmid length" in df.columns:
        df = df.drop("Plasmid length", axis="columns")
    if "Strand" in df.columns:
        df.loc[df["Strand"] == -1, "Strand"] = "-"
        df.loc[df["Strand"] == 1, "Strand"] = "+"
    return df


def summary_section(report, plannotate):
    """At-a-glance table: per sample consensus length + features found."""
    rows = []
    for sample, item in plannotate.items():
        ann = _read_df(item.get("annotations"))
        rows.append({
            "Sample": item.get("sample_name", sample),
            "Consensus length (bp)": item.get("seq_len", ""),
            "Features found": 0 if ann.empty else len(ann),
        })
    with report.add_section("At a glance", "Summary"):
        p("BLAST-based annotation (pLannotate, linear mode) of each amplicon "
          "consensus. Known elements are detected against the bundled SnapGene, "
          "Swiss-Prot, fpbase and Rfam databases -- no internet access required.")
        DataTable.from_pandas(pd.DataFrame(rows), use_index=False)


def plannotate_section(report, plannotate):
    """Per-sample dropdown: linear feature map + annotation table."""
    with report.add_section("Annotated features", "Plannotate"):
        raw(
            "The annotation plot and feature table are produced using "
            '<a href="http://plannotate.barricklab.org/">pLannotate</a> in '
            "linear mode (for PCR amplicons / linear constructs). Unfilled "
            "features are incomplete -- the match covers &lt;95% of the "
            "database feature. Hover a feature for its identity and "
            "description; use the wheel to zoom.")
        tabs = Tabs()
        with tabs.add_dropdown_menu():
            for sample, item in plannotate.items():
                table = _clean_table(_read_df(item.get("annotations")))
                raw_df = _read_df(item.get("plot"))
                with tabs.add_dropdown_tab(str(sample)):
                    if not raw_df.empty:
                        bk = BokehPlot()
                        bk._fig = get_bokeh(raw_df, linear=True)
                        bk._fig.xgrid.grid_line_color = None
                        bk._fig.ygrid.grid_line_color = None
                        EZChart(bk, "epi2melabs", width="100%", height="100%")
                    else:
                        p("No known elements were annotated for this "
                          "consensus.")
                    if not table.empty:
                        DataTable.from_pandas(table, use_index=False)


def main():
    """Entry point."""
    parser = argparse.ArgumentParser(
        description="Build the amplicon annotation HTML report.")
    parser.add_argument(
        "--plannotate_json", required=True,
        help="plannotate_report.json from run_plannotate.py --linear.")
    parser.add_argument(
        "--params", required=True, help="workflow params JSON (for the header).")
    parser.add_argument(
        "--versions", required=True, help="tool versions file (for the header).")
    parser.add_argument(
        "--wf_version", default="amplicon-annotate", help="version string.")
    parser.add_argument(
        "--output", required=True, help="output HTML path.")
    args = parser.parse_args()

    with open(args.plannotate_json) as fh:
        plannotate = json.load(fh)

    report = labs.LabsReport(
        "Amplicon annotation report", "wf-amplicon-annotate",
        args.params, args.versions, args.wf_version)
    summary_section(report, plannotate)
    plannotate_section(report, plannotate)
    report.write(args.output)


if __name__ == "__main__":
    main()
