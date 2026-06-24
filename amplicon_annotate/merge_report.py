#!/usr/bin/env python3
"""Merge the pLannotate annotation section into the wf-amplicon LabsReport.

Produces ONE self-contained HTML = the usual `wf-amplicon-report.html` with the
annotation report's **"Annotated features"** section (linear feature map +
pLannotate map + feature table) spliced in as an extra section, plus a matching
nav entry. This is the "annotation added to the usual amplicon-wf report" view.

Why a post-hoc HTML splice (and why it is safe here):
  Both reports are EPI2ME `LabsReport`s built by the *same* ezcharts version
  (the wf-amplicon SIF and the wf-clone-validation SIF ship the same one), so
  they embed BYTE-IDENTICAL bokeh / echarts / datatables / bootstrap bundles.
  The base report therefore already provides every JS runtime the annotation
  content needs -- we reuse it and carry over only the annotation's *dynamic*
  pieces (the section markup, whose DataTable init is inline, and the external
  Bokeh embed script). All element ids are UUIDs, so nothing collides.

Pure stdlib; runs on host/runtime python3 -- no Apptainer/SIF needed.

Usage:
  merge_report.py --base wf-amplicon-report.html \
                  --annotation amplicon-annotation-report.html \
                  --output amplicon-report-with-annotation.html \
                  [--heading "Annotated features"] [--nav-label Annotation]
"""
import argparse
import re
import sys


def script_spans(html):
    """Yield (start, end, body) for every <script>...</script> (end past tag)."""
    for m in re.finditer(r"<script\b[^>]*>", html):
        close = html.find("</script>", m.end())
        if close == -1:
            continue
        yield m.start(), close + len("</script>"), html[m.end():close]


def extract_section(html, heading):
    """Return the <section>...</section> whose first heading text == `heading`.

    Matches balanced <section> tags so nested sections (if any) don't truncate.
    """
    m = re.search(r">\s*" + re.escape(heading) + r"\s*<", html)
    if not m:
        raise ValueError(f"annotation section heading {heading!r} not found")
    start = html.rfind("<section", 0, m.start())
    if start == -1:
        raise ValueError(f"no <section> enclosing heading {heading!r}")
    depth, k = 0, start
    while True:
        nxt_open = html.find("<section", k + 1)
        nxt_close = html.find("</section>", k + 1)
        if nxt_close == -1:
            raise ValueError("unbalanced <section> while extracting")
        if nxt_open != -1 and nxt_open < nxt_close:
            depth += 1
            k = nxt_open
        else:
            if depth == 0:
                return html[start:nxt_close + len("</section>")]
            depth -= 1
            k = nxt_close


def find_bokeh_embed(html, section_html):
    """The standalone Bokeh embed <script> (the one that renders the plots).

    It lives OUTSIDE the section markup (near the libs), unlike the DataTable
    init which is inline in the section. Returns '' if the section has no plots.
    """
    if "data-root-id" not in section_html and 'class="bk-root"' not in section_html:
        return ""  # no bokeh plots in the carried section -> nothing to carry
    for start, end, body in script_spans(html):
        if "Bokeh.safely" in body:
            return html[start:end]
    raise ValueError("section has bokeh plot divs but no Bokeh embed script found")


def ensure_runtime(base, ann, signature, label):
    """If `base` lacks a shared lib `signature`, return ann's <script> for it.

    The wf-amplicon report normally already has bokeh+datatables (it has plots
    and tables), so this is a belt-and-braces fallback, not the usual path.
    """
    if signature in base:
        return ""
    for start, end, body in script_spans(ann):
        if signature in body:
            print(f"note: base lacks {label}; carrying it from the annotation report",
                  file=sys.stderr)
            return ann[start:end]
    raise ValueError(f"base lacks {label} and it is not in the annotation report either")


def splice_section(base, section_html):
    """Insert `section_html` as the last child of <section id="main-content">."""
    meta = base.find('<section id="meta-content"')
    if meta == -1:
        raise ValueError("base report has no meta-content anchor")
    mc_close = base.rfind("</section>", 0, meta)  # closes main-content
    if mc_close == -1:
        raise ValueError("could not locate main-content closing tag")
    return base[:mc_close] + "\n" + section_html + "\n" + base[mc_close:]


def add_nav_entry(base, sec_id, label):
    """Add a dropdown nav link to the new section, next to the existing links."""
    if not sec_id:
        return base
    link = f'<a class="dropdown-item" href="#{sec_id}">{label}</a>'
    divider = base.find('class="dropdown-divider"')
    if 0 <= divider < base.find('id="main-content"'):
        # insert at the end of the content-link group (the </div> before the divider)
        grp_close = base.rfind("</div>", 0, divider)
        if grp_close != -1:
            return base[:grp_close] + link + base[grp_close:]
    # fallback: place it just before the Versions link
    ver = base.find('<a class="dropdown-item" href="#versions"')
    if ver != -1:
        return base[:ver] + link + base[ver:]
    print("note: could not find the nav to add an Annotation link (cosmetic only)",
          file=sys.stderr)
    return base


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", required=True, help="wf-amplicon-report.html")
    ap.add_argument("--annotation", required=True, help="amplicon-annotation-report.html")
    ap.add_argument("--output", required=True, help="merged HTML output path")
    ap.add_argument("--heading", default="Annotated features",
                    help="annotation section heading to splice (default: %(default)s)")
    ap.add_argument("--nav-label", default="Annotation",
                    help="nav label for the spliced section (default: %(default)s)")
    args = ap.parse_args()

    with open(args.base, encoding="utf-8", errors="replace") as fh:
        base = fh.read()
    with open(args.annotation, encoding="utf-8", errors="replace") as fh:
        ann = fh.read()

    for marker, what in [("</body>", "base"), ('id="main-content"', "base")]:
        if marker not in base:
            sys.exit(f"ERROR: {what} report is not a LabsReport (missing {marker!r})")

    section_html = extract_section(ann, args.heading)
    sec_id_m = re.search(r'id="(Section_\w+)"', section_html)
    sec_id = sec_id_m.group(1) if sec_id_m else ""

    embed = find_bokeh_embed(ann, section_html)
    # Carry shared runtimes only if the base is somehow missing them (rare).
    carried_libs = "".join(
        ensure_runtime(base, ann, sig, label)
        for sig, label in [("BEGIN bokeh.min.js", "bokeh runtime"),
                           ("simpleDatatables", "datatables runtime")]
    )

    merged = splice_section(base, section_html)
    merged = add_nav_entry(merged, sec_id, args.nav_label)
    tail = carried_libs + embed
    if tail:
        body = merged.rfind("</body>")
        merged = merged[:body] + tail + "\n" + merged[body:]

    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(merged)
    print(f"merged report -> {args.output}  "
          f"({len(merged):,} bytes; section={sec_id or 'n/a'}; "
          f"bokeh_embed={'yes' if embed else 'none'})")


if __name__ == "__main__":
    main()
