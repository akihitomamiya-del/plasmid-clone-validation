#!/usr/bin/env python
"""Amplicon annotation report: linear feature map + pLannotate map + feature table.

Runs inside the wf-clone-validation SIF (ezcharts 0.12.0 + bokeh + plannotate),
with PYTHONPATH pointing at that workflow's `bin/` so `workflow_glue.bokeh_plot`
is importable. Consumes the `plannotate_report.json` produced by our patched
`run_plannotate.py --linear` (Stage 3) and writes a single HTML report.

Per sample the JSON holds (see run_plannotate.py):
  { "<sample>": { "sample_name": str,
                  "plot":        <RAW annotation df as DataFrame.to_json()>,
                  "annotations": <CLEANED display df as DataFrame.to_json()>,
                  "seq_len":     int }, ... }
`plot` feeds pLannotate's get_bokeh() (raw qstart/qend/qlen/...); `annotations`
is the human-facing table AND the source for our linear track. The two keys are
counter-intuitively named (an unpack in run_plannotate.py) -- do not swap them.
"""
import argparse
import json

import pandas as pd
from dominate.tags import h4, p
from dominate.util import raw
from ezcharts.components.ezchart import EZChart
from ezcharts.components.reports import labs
from ezcharts.layout.snippets import Tabs
from ezcharts.layout.snippets.table import DataTable
from ezcharts.plots import BokehPlot

# pLannotate's renderer, ported to bokeh 3 in the wf-clone-validation glue.
from workflow_glue.bokeh_plot import get_bokeh

# Fill colour per annotation database (linear track).
_DB_COLOURS = {
    "snapgene": "#4e79a7", "swissprot": "#59a14f", "fpbase": "#e15759",
    "infernal": "#b07aa1", "rfam": "#b07aa1",
}


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


def linear_feature_map(table, seq_len):
    """A left-to-right feature track for a LINEAR amplicon.

    Forward (+) features sit above the backbone, reverse (-) below; overlapping
    features are packed into lanes. `table` is the cleaned annotations df
    (Strand already mapped to '+'/'-'). Returns a bokeh figure.
    """
    from bokeh.models import ColumnDataSource, HoverTool, LabelSet, Range1d
    from bokeh.plotting import figure

    rows = []
    for _, r in table.iterrows():
        try:
            s, e = int(r["Start Location"]), int(r["End Location"])
        except (KeyError, ValueError, TypeError):
            continue
        lo, hi = (s, e) if s <= e else (e, s)
        sgn = -1 if str(r.get("Strand", "+")).strip() in ("-", "-1") else 1
        rows.append({
            "lo": lo, "hi": hi, "mid": (lo + hi) / 2.0, "sgn": sgn,
            "feature": str(r.get("Feature", "")),
            "db": str(r.get("Database", "")),
            "identity": str(r.get("Identity", "")),
            "strand": "+" if sgn > 0 else "-",
            "desc": str(r.get("Description", ""))[:140],
            "color": _DB_COLOURS.get(str(r.get("Database", "")).lower(), "#9c755f"),
        })

    def pack(items):
        """Greedy interval packing -> a lane index per feature."""
        lane_end = []
        for it in sorted(items, key=lambda x: x["lo"]):
            for li, end in enumerate(lane_end):
                if it["lo"] > end:
                    lane_end[li] = it["hi"]
                    it["lane"] = li
                    break
            else:
                lane_end.append(it["hi"])
                it["lane"] = len(lane_end) - 1
        return max(len(lane_end), 1)

    fwd = [r for r in rows if r["sgn"] > 0]
    rev = [r for r in rows if r["sgn"] < 0]
    n_fwd, n_rev = pack(fwd), pack(rev)
    for r in fwd:
        r["y"] = (r["lane"] + 1.0)
    for r in rev:
        r["y"] = -(r["lane"] + 1.0)
    for r in rows:
        r["top"], r["bottom"] = r["y"] + 0.36, r["y"] - 0.36
        r["label_y"] = r["y"] + (0.5 if r["sgn"] > 0 else -0.5)

    src = ColumnDataSource({k: [r[k] for r in rows] for k in (
        "lo", "hi", "mid", "top", "bottom", "label_y", "feature", "db",
        "identity", "strand", "desc", "color")})

    p_fig = figure(
        height=max(220, int((n_fwd + n_rev + 2) * 40)),
        sizing_mode="stretch_width",
        x_range=Range1d(0, max(int(seq_len) or 1, 1)),
        y_range=Range1d(-(n_rev + 1.2), n_fwd + 1.2),
        tools="xpan,xwheel_zoom,reset,save", toolbar_location="above",
        x_axis_label="position (bp)", title="Linear feature map")
    p_fig.yaxis.visible = False
    p_fig.ygrid.visible = False
    p_fig.line([0, seq_len], [0, 0], line_width=3, line_color="#555555")
    glyph = p_fig.quad(
        left="lo", right="hi", top="top", bottom="bottom", source=src,
        fill_color="color", line_color="#333333", fill_alpha=0.85)
    p_fig.add_layout(LabelSet(
        x="mid", y="label_y", text="feature", source=src,
        text_font_size="9pt", text_align="center", text_baseline="middle"))
    p_fig.add_tools(HoverTool(renderers=[glyph], tooltips=[
        ("feature", "@feature"), ("database", "@db"), ("identity", "@identity"),
        ("strand", "@strand"), ("span", "@lo–@hi bp"), ("description", "@desc")]))
    return p_fig


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
    """Per-sample dropdown: linear track + pLannotate map + annotation table."""
    with report.add_section("Annotated features", "Plannotate"):
        raw(
            "Known elements are detected with "
            '<a href="http://plannotate.barricklab.org/">pLannotate</a> in '
            "linear mode (for PCR amplicons). The <b>linear feature map</b> "
            "lays features along the amplicon (forward above the backbone, "
            "reverse below); the <b>pLannotate map</b> is the tool's native "
            "view. Unfilled features in the pLannotate map are incomplete "
            "(match covers &lt;95% of the database feature).")
        if not plannotate:
            p("No consensus sequences were annotated -- none had recognizable "
              "elements (or no consensus was produced).")
            return
        tabs = Tabs()
        with tabs.add_dropdown_menu():
            for sample, item in plannotate.items():
                table = _clean_table(_read_df(item.get("annotations")))
                raw_df = _read_df(item.get("plot"))
                seq_len = item.get("seq_len", 0)
                with tabs.add_dropdown_tab(str(sample)):
                    if table.empty:
                        p("No known elements were annotated for this "
                          "consensus.")
                        continue
                    # 1) linear track (fail-safe: never break the report on it)
                    try:
                        lin = BokehPlot()
                        lin._fig = linear_feature_map(table, seq_len)
                        EZChart(lin, "epi2melabs", width="100%")
                    except Exception as exc:  # noqa: BLE001
                        p(f"(linear feature map unavailable: {exc})")
                    # 2) pLannotate's native map
                    if not raw_df.empty:
                        h4("pLannotate map")
                        bk = BokehPlot()
                        bk._fig = get_bokeh(raw_df, linear=True)
                        bk._fig.xgrid.grid_line_color = None
                        bk._fig.ygrid.grid_line_color = None
                        EZChart(bk, "epi2melabs", width="100%", height="100%")
                    # 3) annotation table
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
