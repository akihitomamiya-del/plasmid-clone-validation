#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""variant_parser.py -- does my clone match the intended construct?

Compare a pipeline consensus FASTA against a USER-SUPPLIED reference (.gbk or
.fasta) and flag every discrepancy. Given a SAM of the consensus aligned to the
reference (produced by validate_against_reference.sh, which runs minimap2 in the
wf-amplicon SIF), this walks each primary alignment and emits:

  * substitution      a single-base mismatch        (ref base -> consensus base)
  * insertion         extra base(s) in the consensus (absent from the reference)
  * deletion          reference base(s) the consensus is missing
  * truncation_5p     consensus 5' bases that do not align to the reference
  * truncation_3p     consensus 3' bases that do not align to the reference

Each variant is then tagged with the reference feature it lands in (interval
overlap against the GenBank FEATURES table), so the PI can tell "a 1 bp deletion
inside the CDS" from "a substitution out in the backbone".

Design constraints (see CLAUDE.md):
  * STDLIB ONLY. The SAM is parsed as plain text (no pysam) and the GenBank with
    a small purpose-built parser (no BioPython). That is why --selftest runs on a
    bare host with nothing but python3 -- which is handy, because the heavy
    aligner half runs inside an Apptainer SIF where this file is merely
    `python`-executed, and the parser must not assume any non-stdlib import.
  * NEVER touches the network. Inclusive (1-based) reference coordinates, matching
    GenBank / the rest of the repo.

CLI:
  variant_parser.py --reference <ref.gbk|fasta> --sam <aln.sam> --out <dir>
  variant_parser.py --gbk2fasta <ref.gbk>          # ORIGIN sequence -> FASTA (stdout)
  variant_parser.py --selftest                     # self-check, no apptainer/pysam
"""

import argparse
import csv
import os
import re
import sys
import tempfile


# ===========================================================================
# Reference parsing (GenBank / FASTA)
# ===========================================================================

# A FEATURES-table location: we only need the outermost numeric span + strand.
# Handles `123..456`, `complement(123..456)`, `join(1..9,20..30)` (-> span 1..30),
# fuzzy `<123..>456`, and a bare single base `123`.
_NUM_RE = re.compile(r"\d+")


def _parse_location(loc):
    """Return (start, end, strand) 1-based inclusive; strand in {+1,-1}.

    Falls back to the min/max coordinate for join()/order() so a feature always
    has a single covering interval (internal structure is not needed for overlap).
    """
    strand = -1 if "complement" in loc else 1
    nums = [int(n) for n in _NUM_RE.findall(loc)]
    if not nums:
        return None, None, strand
    return min(nums), max(nums), strand


def _parse_qualifier(text):
    """Parse a single `/key=value` (or bare `/flag`) line.

    Returns (key_lower, value, still_open) where still_open is True when a quoted
    value opened but did not close on this line (it continues on following lines).
    """
    body = text[1:]  # drop the leading '/'
    if "=" in body:
        key, val = body.split("=", 1)
    else:
        key, val = body, ""
    key = key.strip().lower()
    val = val.strip()
    still_open = False
    if val.startswith('"'):
        if val.endswith('"') and len(val) >= 2:
            val = val[1:-1]
        else:
            val = val[1:]          # opening quote only -> value spans more lines
            still_open = True
    return key, val, still_open


def _feature_label(quals, ftype):
    """Best human label for a feature: /label, else gene/product/note, else type."""
    for key in ("label", "gene", "product", "note"):
        if quals.get(key):
            return quals[key]
    return ftype


def _parse_genbank(path):
    """Parse a GenBank file -> (sequence_upper, [feature dicts]).

    Each feature dict: {type, start, end, strand, label}, 1-based inclusive.
    Only the FEATURES table and the ORIGIN sequence are read; everything else in
    the header is ignored. Multi-line locations and quoted qualifier values are
    supported; the common single-line case (pLannotate/SnapGene exports) is the
    fast path.
    """
    locus = "reference"
    seq_parts = []
    feats = []
    cur = None            # the feature currently being assembled
    section = None        # None | "features" | "origin"

    def finish(feat):
        if feat is None:
            return
        start, end, strand = _parse_location(feat["loc"])
        if start is None:
            return
        feats.append({
            "type": feat["type"],
            "start": start,
            "end": end,
            "strand": strand,
            "label": _feature_label(feat["quals"], feat["type"]),
        })

    with open(path) as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if line.startswith("LOCUS"):
                parts = line.split()
                if len(parts) >= 2:
                    locus = parts[1]
                section = None
                continue
            if line.startswith("FEATURES"):
                section = "features"
                continue
            if line.startswith("ORIGIN"):
                finish(cur)
                cur = None
                section = "origin"
                continue
            if line.startswith("//"):
                finish(cur)
                cur = None
                section = None
                continue
            if section == "origin":
                # e.g. "        1 agacacgggc cagagctgca ..." -> keep only letters
                seq_parts.append(re.sub(r"[^A-Za-z]", "", line))
                continue
            if section == "features":
                stripped = line.strip()
                if not stripped:
                    continue
                lead = len(line) - len(line.lstrip(" "))
                # GenBank puts feature keys at column 6 (indent 5) and qualifiers at
                # column 22 (indent 21); a small indent that is not a '/qualifier'
                # marks a new feature key line.
                is_key = (0 < lead < 16) and not stripped.startswith("/")
                if is_key:
                    finish(cur)
                    m = re.match(r"\s+(\S+)\s+(.*\S)\s*$", line)
                    if m:
                        cur = {"type": m.group(1), "loc": m.group(2),
                               "quals": {}, "seen_qual": False, "open_q": None}
                    else:
                        cur = {"type": stripped, "loc": "", "quals": {},
                               "seen_qual": False, "open_q": None}
                elif cur is not None:
                    if stripped.startswith("/"):
                        cur["seen_qual"] = True
                        key, val, still_open = _parse_qualifier(stripped)
                        if key not in cur["quals"]:
                            cur["quals"][key] = val
                        cur["open_q"] = key if still_open else None
                    elif cur["open_q"] is not None:
                        # continuation of a quoted qualifier value
                        closed = stripped.endswith('"')
                        cur["quals"][cur["open_q"]] += stripped.strip('"')
                        if closed:
                            cur["open_q"] = None
                    elif not cur["seen_qual"]:
                        # continuation of a wrapped location (join/order)
                        cur["loc"] += stripped
    finish(cur)  # defensive: file truncated before ORIGIN/'//'
    return "".join(seq_parts).upper(), feats


def _read_fasta_first(path):
    """Return the first FASTA record's sequence (uppercased)."""
    chunks = []
    started = False
    with open(path) as fh:
        for line in fh:
            if line.startswith(">"):
                if started:
                    break
                started = True
                continue
            if started:
                chunks.append(line.strip())
    return "".join(chunks).upper()


def _is_genbank_path(path):
    ext = os.path.splitext(path)[1].lower()
    if ext in (".gb", ".gbk", ".genbank"):
        return True
    if ext in (".fa", ".fasta", ".fna", ".fas", ".ffn", ".faa", ".seq"):
        return False
    # Unknown extension: sniff the first meaningful line.
    with open(path) as fh:
        for line in fh:
            s = line.strip()
            if not s:
                continue
            if s.startswith("LOCUS"):
                return True
            return False
    return False


def parse_reference(path):
    """Parse a reference into (sequence, features).

    GenBank -> (ORIGIN sequence, feature list). FASTA -> (sequence, []) because a
    bare FASTA carries no annotation to overlap against.
    """
    if _is_genbank_path(path):
        return _parse_genbank(path)
    return _read_fasta_first(path), []


def reference_sequences(path):
    """Map record id -> sequence for the reference (all FASTA records, or the one
    GenBank LOCUS). Used only to recover ref bases in the rare CIGAR-only path."""
    if _is_genbank_path(path):
        seq, _ = _parse_genbank(path)
        return {locus_name(path): seq}
    out = {}
    cur = None
    chunks = []
    with open(path) as fh:
        for line in fh:
            if line.startswith(">"):
                if cur is not None:
                    out[cur] = "".join(chunks).upper()
                cur = line[1:].split()[0] if len(line) > 1 else "ref"
                chunks = []
            else:
                chunks.append(line.strip())
    if cur is not None:
        out[cur] = "".join(chunks).upper()
    return out


def locus_name(path):
    """LOCUS name of a GenBank file, else the file basename."""
    try:
        with open(path) as fh:
            for line in fh:
                if line.startswith("LOCUS"):
                    parts = line.split()
                    return parts[1] if len(parts) >= 2 else "reference"
    except OSError:
        pass
    return os.path.splitext(os.path.basename(path))[0]


def format_fasta(name, seq, width=70):
    """Render a single sequence as wrapped FASTA text."""
    lines = [">" + name]
    for i in range(0, len(seq), width):
        lines.append(seq[i:i + width])
    return "\n".join(lines) + "\n"


# ===========================================================================
# SAM / alignment walking
# ===========================================================================

# minimap2 `cs` operators (short form `--cs`, and the `=` of long form `--cs=long`):
#   :<n>      <n> identical bases        (consume ref n, query n)
#   =<seq>    identical bases (long cs)  (consume ref len, query len)
#   *<r><q>   substitution r->q          (consume ref 1, query 1)
#   +<seq>    insertion, query-only      (consume ref 0, query len)
#   -<seq>    deletion, ref-only         (consume ref len, query 0)
#   ~ab<n>cd  intron/splice (skipped for genomic asm; ref advances by <n>)
_CS_TOKEN_RE = re.compile(
    r"(:\d+|=[A-Za-z]+|\*[A-Za-z][A-Za-z]|\+[A-Za-z]+|-[A-Za-z]+"
    r"|~[A-Za-z]{2}\d+[A-Za-z]{2})")

_CIGAR_RE = re.compile(r"(\d+)([MIDNSHP=X])")


def _new_stats():
    return {"matches": 0, "subs": 0, "ins": 0, "ins_bp": 0,
            "dels": 0, "del_bp": 0, "trunc_5p": 0, "trunc_3p": 0,
            "aligned": False, "unmapped": False}


def _mk(qname, ref_pos, vtype, ref, alt, length):
    """Build a variant record with empty annotation fields (filled later)."""
    return {"consensus_id": qname, "ref_pos": int(ref_pos), "type": vtype,
            "ref": ref, "alt": alt, "length": int(length),
            "In_Feature": "no", "Feature": "", "Feature_Type": ""}


def _clip_preview(bases, cap=30):
    """Short, CSV-safe preview of a (possibly long) clipped end."""
    if not bases:
        return ""
    return bases if len(bases) <= cap else bases[:cap] + "..."


def _parse_cigar(cigar):
    if cigar == "*" or not cigar:
        return []
    return [(int(n), op) for n, op in _CIGAR_RE.findall(cigar)]


def _parse_sam_record(cols):
    rec = {
        "qname": cols[0],
        "flag": int(cols[1]),
        "rname": cols[2],
        "pos": int(cols[3]),       # 1-based reference start
        "cigar": cols[5],
        "seq": cols[9],
        "tags": {},
    }
    for col in cols[11:]:
        # tag is KEY:TYPE:VALUE -- split only twice so the cs/MD value (which itself
        # contains ':') survives intact.
        parts = col.split(":", 2)
        if len(parts) == 3:
            rec["tags"][parts[0]] = parts[2]
    return rec


def _add_trunc(stats, vtype, n):
    if vtype == "truncation_5p":
        stats["trunc_5p"] += n
    else:
        stats["trunc_3p"] += n


def _emit_clips(rec, cigar_ops, reverse, variants, stats):
    """Leading/trailing soft (S) or hard (H) clips -> 5'/3' truncations.

    A clipped end is consensus sequence that did not align to the reference. On a
    forward alignment the CIGAR's leading clip is the consensus 5' end and the
    trailing clip the 3' end; on a reverse alignment (SAM stores the query
    reverse-complemented) those swap, so we flip the labels by strand.
    """
    if not cigar_ops:
        return
    qname, pos, seq = rec["qname"], rec["pos"], rec["seq"]
    ref_consumed = sum(n for n, op in cigar_ops if op in "MDN=X")
    ref_end = pos + ref_consumed - 1

    head_n, head_op = cigar_ops[0]
    tail_n, tail_op = cigar_ops[-1]

    if head_op in "SH" and head_n > 0:
        bases = seq[:head_n] if (head_op == "S" and seq != "*") else ""
        vtype = "truncation_3p" if reverse else "truncation_5p"
        variants.append(_mk(qname, pos, vtype, "", _clip_preview(bases), head_n))
        _add_trunc(stats, vtype, head_n)
    if tail_op in "SH" and tail_n > 0:
        bases = seq[-tail_n:] if (tail_op == "S" and seq != "*") else ""
        vtype = "truncation_5p" if reverse else "truncation_3p"
        variants.append(_mk(qname, ref_end, vtype, "", _clip_preview(bases), tail_n))
        _add_trunc(stats, vtype, tail_n)


def _walk_cs(qname, pos, cs, variants, stats):
    """Emit substitutions/insertions/deletions from a minimap2 `cs` string.

    The cs tag is unambiguous (it carries both ref and query bases), so this is the
    preferred path. Reference coordinate is tracked across every operator.
    """
    ref = pos  # next reference position to consume (1-based)
    for tok in _CS_TOKEN_RE.findall(cs):
        op = tok[0]
        if op == ":":
            n = int(tok[1:])
            stats["matches"] += n
            ref += n
        elif op == "=":
            n = len(tok) - 1
            stats["matches"] += n
            ref += n
        elif op == "*":
            variants.append(_mk(qname, ref, "substitution",
                                tok[1].upper(), tok[2].upper(), 1))
            stats["subs"] += 1
            ref += 1
        elif op == "+":
            ins = tok[1:].upper()
            # anchor the insertion at the preceding reference base; ref is unchanged
            variants.append(_mk(qname, ref - 1, "insertion", "", ins, len(ins)))
            stats["ins"] += 1
            stats["ins_bp"] += len(ins)
        elif op == "-":
            dele = tok[1:].upper()
            variants.append(_mk(qname, ref, "deletion", dele, "", len(dele)))
            stats["dels"] += 1
            stats["del_bp"] += len(dele)
            ref += len(dele)
        elif op == "~":
            m = re.match(r"~[A-Za-z]{2}(\d+)[A-Za-z]{2}", tok)
            if m:
                ref += int(m.group(1))


def _md_tokens(md):
    """Yield ("match", n) | ("sub", ref_base) | ("del", ref_bases) from an MD tag."""
    i, n = 0, len(md)
    while i < n:
        c = md[i]
        if c.isdigit():
            j = i
            while j < n and md[j].isdigit():
                j += 1
            yield ("match", int(md[i:j]))
            i = j
        elif c == "^":
            j = i + 1
            while j < n and md[j].isalpha():
                j += 1
            yield ("del", md[i + 1:j])
            i = j
        elif c.isalpha():
            yield ("sub", c)
            i += 1
        else:
            i += 1


def _walk_cigar_md(qname, pos, cigar_ops, md, seq, variants, stats):
    """Fallback: reconstruct variants from CIGAR + MD when there is no `cs` tag.

    The MD tag ignores insertions, so a single MD match run can straddle a CIGAR
    insertion; we consume MD lazily, pushing back the unused tail of a partially
    consumed match run.
    """
    gen = _md_tokens(md)
    pending = []  # LIFO push-back for a partially consumed match run

    def next_tok():
        if pending:
            return pending.pop()
        return next(gen, None)

    ref = pos
    q = 0
    have_seq = seq and seq != "*"
    for length, op in cigar_ops:
        if op in "M=X":
            remaining = length
            while remaining > 0:
                tok = next_tok()
                if tok is None:                      # MD exhausted -> assume matches
                    stats["matches"] += remaining
                    ref += remaining
                    q += remaining
                    remaining = 0
                    break
                kind = tok[0]
                if kind == "match":
                    take = min(tok[1], remaining)
                    stats["matches"] += take
                    ref += take
                    q += take
                    remaining -= take
                    if tok[1] > take:
                        pending.append(("match", tok[1] - take))
                elif kind == "sub":
                    alt = seq[q].upper() if have_seq and q < len(seq) else ""
                    variants.append(_mk(qname, ref, "substitution",
                                        tok[1].upper(), alt, 1))
                    stats["subs"] += 1
                    ref += 1
                    q += 1
                    remaining -= 1
                else:                                # a 'del' has no place inside M
                    pending.append(tok)
                    break
        elif op == "I":
            ins = seq[q:q + length].upper() if have_seq else ""
            variants.append(_mk(qname, ref - 1, "insertion", "", ins, length))
            stats["ins"] += 1
            stats["ins_bp"] += length
            q += length
        elif op == "D":
            tok = next_tok()
            if tok and tok[0] == "del":
                dele = tok[1].upper()
            else:
                dele = ""
                if tok is not None:
                    pending.append(tok)
            variants.append(_mk(qname, ref, "deletion", dele, "", length))
            stats["dels"] += 1
            stats["del_bp"] += length
            ref += length
        elif op == "N":
            ref += length
        elif op == "S":
            q += length
        # H, P consume neither ref nor (recorded) query


def _walk_cigar_only(qname, pos, cigar_ops, rec, ref_seqs, variants, stats):
    """Last resort: CIGAR alone. Plain `M` cannot reveal mismatches (counted as
    matches); only extended `=`/`X` CIGARs expose substitutions."""
    seq = rec["seq"]
    have_seq = seq and seq != "*"
    rseq = (ref_seqs or {}).get(rec["rname"])
    ref = pos
    q = 0
    for length, op in cigar_ops:
        if op in "M=":
            stats["matches"] += length
            ref += length
            q += length
        elif op == "X":
            for k in range(length):
                rb = rseq[ref - 1 + k].upper() if rseq and ref - 1 + k < len(rseq) else ""
                ab = seq[q + k].upper() if have_seq and q + k < len(seq) else ""
                variants.append(_mk(qname, ref + k, "substitution", rb, ab, 1))
                stats["subs"] += 1
            ref += length
            q += length
        elif op == "I":
            ins = seq[q:q + length].upper() if have_seq else ""
            variants.append(_mk(qname, ref - 1, "insertion", "", ins, length))
            stats["ins"] += 1
            stats["ins_bp"] += length
            q += length
        elif op == "D":
            dele = rseq[ref - 1:ref - 1 + length].upper() if rseq else ""
            variants.append(_mk(qname, ref, "deletion", dele, "", length))
            stats["dels"] += 1
            stats["del_bp"] += length
            ref += length
        elif op == "N":
            ref += length
        elif op == "S":
            q += length


def _variants_one_alignment(rec, ref_seqs, variants, stats):
    qname = rec["qname"]
    st = stats.setdefault(qname, _new_stats())
    st["aligned"] = True
    cigar_ops = _parse_cigar(rec["cigar"])
    reverse = bool(rec["flag"] & 0x10)
    _emit_clips(rec, cigar_ops, reverse, variants, st)

    cs = rec["tags"].get("cs")
    md = rec["tags"].get("MD")
    if cs:
        _walk_cs(qname, rec["pos"], cs, variants, st)
    elif md:
        _walk_cigar_md(qname, rec["pos"], cigar_ops, md, rec["seq"], variants, st)
    else:
        _walk_cigar_only(qname, rec["pos"], cigar_ops, rec, ref_seqs, variants, st)


def variants_from_sam(sam_path, ref_seqs=None):
    """Walk a SAM file -> (variants, stats).

    Only primary, mapped alignments are processed (secondary 0x100 / supplementary
    0x800 are skipped; unmapped 0x4 are recorded as a whole-consensus miss). The
    optional ref_seqs (id -> sequence) only helps the CIGAR-only `X` fallback fill
    in reference bases; the cs/MD paths do not need it.
    """
    variants = []
    stats = {}
    with open(sam_path) as fh:
        for line in fh:
            if not line or line[0] == "@":
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 11:
                continue
            rec = _parse_sam_record(cols)
            flag = rec["flag"]
            if flag & 0x4:                       # unmapped consensus
                st = stats.setdefault(rec["qname"], _new_stats())
                st["unmapped"] = True
                length = len(rec["seq"]) if rec["seq"] != "*" else 0
                variants.append(_mk(rec["qname"], 0, "unmapped", "", "", length))
                continue
            if flag & 0x100 or flag & 0x800:     # secondary / supplementary
                continue
            _variants_one_alignment(rec, ref_seqs, variants, stats)
    return variants, stats


# ===========================================================================
# Feature overlap + outputs
# ===========================================================================

def _variant_span(v):
    """1-based inclusive reference span a variant occupies (for feature overlap)."""
    pos = v["ref_pos"]
    if v["type"] == "deletion":
        return pos, pos + max(v["length"], 1) - 1
    # substitutions, insertions (anchor base) and truncation boundaries are a point
    return pos, pos


def annotate_overlap(variants, features):
    """Tag each variant with the reference feature(s) it overlaps.

    Sets In_Feature ('yes'/'no'), Feature (';'-joined labels) and Feature_Type
    (';'-joined types). The whole-molecule 'source' feature is ignored so it does
    not mask the specific feature a variant actually sits in.
    """
    feats = [f for f in features if str(f.get("type", "")).lower() != "source"]
    for v in variants:
        if v["type"] == "unmapped":
            continue
        start, end = _variant_span(v)
        hits = [f for f in feats if not (end < f["start"] or start > f["end"])]
        if hits:
            v["In_Feature"] = "yes"
            v["Feature"] = ";".join(str(f["label"]) for f in hits)
            v["Feature_Type"] = ";".join(str(f["type"]) for f in hits)
        else:
            v["In_Feature"] = "no"
            v["Feature"] = ""
            v["Feature_Type"] = ""
    return variants


def _identity_pct(st):
    """BLAST-style identity: matches / (matches + subs + inserted_bp + deleted_bp)."""
    denom = st["matches"] + st["subs"] + st["ins_bp"] + st["del_bp"]
    return 100.0 * st["matches"] / denom if denom else 0.0


def _verdict(st):
    if st.get("unmapped") or not st.get("aligned"):
        return "UNMAPPED"
    disc = (st["subs"] or st["ins"] or st["dels"]
            or st["trunc_5p"] or st["trunc_3p"])
    return "DISCREPANT" if disc else "MATCH"


CSV_COLUMNS = ["Consensus_ID", "Ref_Pos", "Type", "Ref", "Alt", "Length",
               "In_Feature", "Feature", "Feature_Type"]


def write_outputs(variants, stats, out_dir):
    """Write variants_vs_reference.csv + variant_summary.txt into out_dir."""
    os.makedirs(out_dir, exist_ok=True)
    csv_path = os.path.join(out_dir, "variants_vs_reference.csv")
    sum_path = os.path.join(out_dir, "variant_summary.txt")

    ordered = sorted(variants, key=lambda v: (v["consensus_id"], v["ref_pos"],
                                              v["type"]))
    with open(csv_path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(CSV_COLUMNS)
        for v in ordered:
            w.writerow([v["consensus_id"], v["ref_pos"], v["type"], v["ref"],
                        v["alt"], v["length"], v["In_Feature"], v["Feature"],
                        v["Feature_Type"]])

    with open(sum_path, "w") as fh:
        fh.write("# variant_summary.txt -- consensus vs reference\n")
        fh.write("# identity% = matches / (matches + substitutions + inserted_bp "
                 "+ deleted_bp) * 100\n")
        fh.write("\t".join(["Consensus_ID", "n_subs", "n_ins", "n_del",
                            "trunc_5p_bp", "trunc_3p_bp", "identity%",
                            "verdict"]) + "\n")
        for cid in sorted(stats):
            st = stats[cid]
            fh.write("\t".join([
                cid, str(st["subs"]), str(st["ins"]), str(st["dels"]),
                str(st["trunc_5p"]), str(st["trunc_3p"]),
                "%.2f" % _identity_pct(st), _verdict(st)]) + "\n")
    return csv_path, sum_path


def _print_run_summary(stats):
    """Compact, human-readable headline for the console (full-run mode only)."""
    n_var = sum(st["subs"] + st["ins"] + st["dels"]
                + (1 if st["trunc_5p"] else 0) + (1 if st["trunc_3p"] else 0)
                for st in stats.values())
    print("[variant_parser] %d consensus(es), %d discrepancy event(s)"
          % (len(stats), n_var))
    for cid in sorted(stats):
        st = stats[cid]
        bits = []
        if st["subs"]:
            bits.append("%d sub" % st["subs"])
        if st["ins"]:
            bits.append("%d ins(%dbp)" % (st["ins"], st["ins_bp"]))
        if st["dels"]:
            bits.append("%d del(%dbp)" % (st["dels"], st["del_bp"]))
        if st["trunc_5p"]:
            bits.append("5' trunc %dbp" % st["trunc_5p"])
        if st["trunc_3p"]:
            bits.append("3' trunc %dbp" % st["trunc_3p"])
        detail = ", ".join(bits) if bits else "no differences"
        print("  %s: %s -> %.2f%% identity [%s]"
              % (cid, detail, _identity_pct(st), _verdict(st)))


# ===========================================================================
# Self-test (no apptainer, no pysam, no network)
# ===========================================================================

def selftest():
    """Build a tiny reference + a hand-written SAM and assert each variant class
    is detected. Exercises BOTH the `cs` path and the CIGAR+MD fallback."""
    # 40 bp reference; position 11 is the substituted base, 31..33 the deleted run.
    ref_seq = ("ACGTACGTAC" "A" "CGTACGTAC" "GTACGTACGT" "CCC" "TACGTAC")
    assert len(ref_seq) == 40, len(ref_seq)
    features = [{"type": "CDS", "start": 5, "end": 25, "strand": 1,
                 "label": "testCDS"}]

    # Consensus aligned at ref pos 1:
    #   10 match, 1 sub (A->G), 9 match, 2 bp insertion (TT), 10 match,
    #   3 bp deletion (CCC), 7 match, then a 5 bp 3' soft-clip (GGGGG).
    seq = ("ACGTACGTAC" "G" "CGTACGTAC" "TT" "GTACGTACGT" "TACGTAC" "GGGGG")
    assert len(seq) == 44, len(seq)
    cigar = "20M2I10M3D7M5S"
    cs = ":10*ag:9+tt:10-ccc:7"
    md = "10A19^CCC7"
    header = "@HD\tVN:1.6\tSO:unsorted\n@SQ\tSN:ref\tLN:40\n"
    common = ["sample01", "0", "ref", "1", "60", cigar, "*", "0", "0", seq, "*"]
    sams = {
        "cs": "\t".join(common + ["NM:i:6", "cs:Z:" + cs]),
        "MD": "\t".join(common + ["NM:i:6", "MD:Z:" + md]),
    }

    for label, body in sams.items():
        tf = tempfile.NamedTemporaryFile("w", suffix=".sam", delete=False)
        try:
            tf.write(header + body + "\n")
            tf.close()
            variants, stats = variants_from_sam(tf.name)
        finally:
            os.unlink(tf.name)
        annotate_overlap(variants, features)

        subs = [v for v in variants if v["type"] == "substitution"]
        ins = [v for v in variants if v["type"] == "insertion"]
        dels = [v for v in variants if v["type"] == "deletion"]
        t3 = [v for v in variants if v["type"] == "truncation_3p"]
        t5 = [v for v in variants if v["type"] == "truncation_5p"]

        assert len(subs) == 1, "[%s] expected 1 substitution, got %d" % (label, len(subs))
        assert subs[0]["ref_pos"] == 11, "[%s] sub at %d" % (label, subs[0]["ref_pos"])
        assert subs[0]["ref"] == "A" and subs[0]["alt"] == "G", \
            "[%s] sub bases %s>%s" % (label, subs[0]["ref"], subs[0]["alt"])
        assert len(ins) == 1 and ins[0]["length"] == 2, \
            "[%s] expected one 2bp insertion, got %s" % (label, ins)
        assert len(dels) == 1 and dels[0]["length"] == 3, \
            "[%s] expected one 3bp deletion, got %s" % (label, dels)
        assert dels[0]["ref_pos"] == 31, "[%s] del at %d" % (label, dels[0]["ref_pos"])
        assert len(t3) == 1 and t3[0]["length"] == 5, \
            "[%s] expected a 5bp 3' truncation, got %s" % (label, t3)
        assert not t5, "[%s] unexpected 5' truncation %s" % (label, t5)
        # the substitution at ref 11 lands inside the CDS feature (5..25)
        assert subs[0]["In_Feature"] == "yes" and "testCDS" in subs[0]["Feature"], \
            "[%s] substitution not annotated in-feature: %s" % (label, subs[0])
        # identity = 36 / (36 + 1 + 2 + 3) = 85.71%
        ident = _identity_pct(stats["sample01"])
        assert 85.0 < ident < 86.5, "[%s] identity %.2f out of range" % (label, ident)
        print("  [%s] OK: sub A>G@11 (in %s), ins 2bp, del 3bp@31, 3' trunc 5bp, "
              "identity %.2f%%" % (label, subs[0]["Feature"], ident))

    print("SELFTEST PASS")


# ===========================================================================
# CLI
# ===========================================================================

def _build_parser():
    p = argparse.ArgumentParser(
        description="Flag consensus-vs-reference discrepancies and their "
                    "overlapping reference features (stdlib only).")
    p.add_argument("--reference", help="reference .gbk/.gb or .fasta/.fa/.fna")
    p.add_argument("--sam", help="SAM of the consensus aligned to the reference "
                                 "(minimap2 -a --cs)")
    p.add_argument("--out", help="output directory for the CSV + summary")
    p.add_argument("--gbk2fasta", metavar="REF",
                   help="print the reference ORIGIN as FASTA to stdout and exit "
                        "(used by validate_against_reference.sh to feed minimap2)")
    p.add_argument("--selftest", action="store_true",
                   help="run the built-in self-check (no apptainer/pysam) and exit")
    return p


def main(argv=None):
    args = _build_parser().parse_args(argv)

    if args.selftest:
        selftest()
        return 0

    if args.gbk2fasta:
        seq, _ = parse_reference(args.gbk2fasta)
        if not seq:
            sys.stderr.write("ERROR: no sequence found in %s\n" % args.gbk2fasta)
            return 1
        sys.stdout.write(format_fasta(locus_name(args.gbk2fasta), seq))
        return 0

    if not (args.reference and args.sam and args.out):
        sys.stderr.write("ERROR: --reference, --sam and --out are all required "
                         "(or use --selftest / --gbk2fasta).\n")
        return 2

    _, features = parse_reference(args.reference)
    ref_seqs = reference_sequences(args.reference)
    variants, stats = variants_from_sam(args.sam, ref_seqs=ref_seqs)
    annotate_overlap(variants, features)
    csv_path, sum_path = write_outputs(variants, stats, args.out)
    _print_run_summary(stats)
    print("[variant_parser] wrote %s" % csv_path)
    print("[variant_parser] wrote %s" % sum_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
