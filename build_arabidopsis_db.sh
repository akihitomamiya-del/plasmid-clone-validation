#!/usr/bin/env bash
#
# build_arabidopsis_db.sh
# -----------------------
# Build the custom *Arabidopsis thaliana* protein database that the amplicon
# annotation pipeline uses to add the **AGI locus code + gene symbol + functional
# description** to each consensus. Produces two small artifacts:
#
#   <out_dir>/arabidopsis.dmnd   diamond protein DB (defline first token = AGI locus)
#   <out_dir>/arabidopsis.csv    details table, header  sseqid,Feature,Description
#                                  = AGI locus, gene symbol, function
#
# >>> RUN THIS OUTSIDE the firewalled devcontainer. <<<
# The Arabidopsis proteome is downloaded from Ensembl Plants, which is NOT reachable
# from inside the sandbox (only GitHub/npm/Anthropic egress -- verified: every TAIR /
# Ensembl / UniProt / NCBI host returns "No route to host"). Run this on any networked
# host, then copy <out_dir> to the machine that runs the pipeline and point ARAB_DB at
# it:  ARAB_DB=/path/to/arabidopsis_db ./amplicon_validate.sh <raw> <out>
# See docs/arabidopsis_annotation_plan.md for the full runbook.
#
# Data source (primary): Ensembl Plants `Arabidopsis_thaliana.TAIR10.pep.all.fa.gz`
# -- the one file carrying AGI (gene:), symbol (gene_symbol:) and function
# (description:) in each defline. Genes with no curated symbol fall back to the AGI.
#
# Usage:
#   ./build_arabidopsis_db.sh [out_dir] [options]
#
# Options:
#   out_dir            output directory (default ./arabidopsis_db)
#   --release N        Ensembl Plants release (default 63; archive 58 also works)
#   --source FILE      use a local proteome .fa/.fa.gz instead of downloading
#                      (lets you build fully offline once you have the FASTA)
#   --keep-isoforms    keep every splice isoform (default: one longest protein per
#                      gene, so the AGI is the bare locus AT#G##### with no .N suffix)
#   --aliases-source S where extra gene names come from: 'biomart' (default; Ensembl
#                      Plants BioMart external_gene_name+external_synonym, no login)
#                      or 'none' (symbol-or-AGI only, the pre-alias behaviour)
#   --aliases FILE     use a local TAIR/Araport-style alias tsv instead of BioMart
#                      (columns: AGI <tab> symbol[/name] ...; multiple rows per AGI;
#                      builds fully offline). Overrides --aliases-source.
#   -h|--help          show this header
#
# Gene names: by default the build JOINS a gene-alias table to broaden the displayed
# name -- it fills a real symbol for loci Ensembl leaves un-named *when the alias table
# offers a genuine one*, and folds extra synonyms into the Description as
# "synonyms: ANAC001, ... - <function>". Obsolete BAC/clone ids (e.g. F10N7.90) are kept
# ONLY as synonyms, never promoted to the label -- a clean AGI reads better than a clone
# id (the AGI is in the Accession column either way). So the Feature column is always a
# real symbol or the bare AGI, never a clone id; the GenBank /label is unchanged
# ("PGR3 (AT4G31850)"). NB BioMart mostly carries clone-id synonyms, so this typically
# adds ~1k real symbols + synonyms on ~20k loci (lab names like NUWA/LPE1 are TAIR/
# Araport-curated and are NOT in BioMart -- supply them via --aliases for those). Alias
# fetch is best-effort: if it fails the build produces the symbol-or-AGI table as before.
#
# Requires: curl or wget (unless --source); diamond. If diamond is not on PATH the
# script will use `apptainer exec "$PLAN_SIF" diamond` when $PLAN_SIF (or a plannotate
# SIF under $NXF_SINGULARITY_CACHEDIR / /opt/sif-cache) is available -- this also
# version-matches the SIF's diamond (2.1.x). Install diamond via:  conda install -c
# bioconda diamond   (or download the static binary from the diamond GitHub release).

set -euo pipefail
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

OUT="./arabidopsis_db"; REL=63; SOURCE=""; KEEP_ISO=0
ALIASES_FILE=""; ALIASES_SOURCE="biomart"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --release) REL="$2"; shift 2;;
    --source) SOURCE="$2"; shift 2;;
    --keep-isoforms) KEEP_ISO=1; shift;;
    --aliases) ALIASES_FILE="$2"; shift 2;;
    --aliases-source) ALIASES_SOURCE="$2"; shift 2;;
    -*) echo "unknown option: $1" >&2; exit 2;;
    *) args+=("$1"); shift;;
  esac
done
[[ ${#args[@]} -ge 1 ]] && OUT="${args[0]}"

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
echo "== build_arabidopsis_db =="
echo "out=$OUT  release=$REL  keep_isoforms=$KEEP_ISO  source=${SOURCE:-<download>}"
echo "aliases=${ALIASES_FILE:-<$ALIASES_SOURCE>}"

# --- 1) obtain the proteome FASTA ---------------------------------------------
RAW_FAA="$OUT/_ensembl_pep.fa.gz"
if [[ -n "$SOURCE" ]]; then
    [[ -f "$SOURCE" ]] || { echo "ERROR: --source not found: $SOURCE" >&2; exit 1; }
    RAW_FAA="$SOURCE"
    echo "Using local proteome: $RAW_FAA"
else
    BASE="Arabidopsis_thaliana.TAIR10.pep.all.fa.gz"
    URLS=(
      "https://ftp.ensemblgenomes.org/pub/plants/release-${REL}/fasta/arabidopsis_thaliana/pep/${BASE}"
      "https://ftp.ebi.ac.uk/pub/ensemblgenomes/plants/release-${REL}/fasta/arabidopsis_thaliana/pep/${BASE}"
    )
    ok=0
    for u in "${URLS[@]}"; do
        echo "Downloading: $u"
        if command -v curl >/dev/null 2>&1; then
            curl -fSL --retry 3 -o "$RAW_FAA" "$u" && { ok=1; break; }
        elif command -v wget >/dev/null 2>&1; then
            wget -O "$RAW_FAA" "$u" && { ok=1; break; }
        else
            echo "ERROR: need curl or wget to download (or pass --source FILE)." >&2; exit 1
        fi
        echo "  (failed; trying next mirror)" >&2
    done
    (( ok == 1 )) || { echo "ERROR: could not download the proteome from any mirror." >&2; exit 1; }
fi

# --- 1b) obtain the gene-alias table (extra symbols + synonyms) ----------------
# Broadens the displayed gene name: fills a real symbol for the many loci Ensembl
# leaves un-named, and lists extra synonyms (e.g. PGR3 -> NUWA, LPE1) in the
# Description. Source: Ensembl Plants BioMart (external_gene_name + external_synonym,
# no login) or a local TAIR/Araport-style tsv via --aliases. Best-effort: if the
# table is unavailable the build proceeds with symbol-or-AGI exactly as before.
ALIASES_TSV=""
if [[ -n "$ALIASES_FILE" ]]; then
    [[ -f "$ALIASES_FILE" ]] || { echo "ERROR: --aliases not found: $ALIASES_FILE" >&2; exit 1; }
    ALIASES_TSV="$ALIASES_FILE"
    echo "Using local alias table: $ALIASES_TSV"
elif [[ "$ALIASES_SOURCE" == "none" ]]; then
    echo "Aliases disabled (--aliases-source none)."
elif [[ "$ALIASES_SOURCE" == "biomart" ]]; then
    ALIASES_TSV="$OUT/_gene_aliases.tsv"
    # AGI <tab> external_gene_name <tab> external_synonym (one row per synonym).
    BIOMART_QUERY='<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE Query><Query virtualSchemaName="plants_mart" formatter="TSV" header="0" uniqueRows="1" count="" datasetConfigVersion="0.6"><Dataset name="athaliana_eg_gene" interface="default"><Attribute name="ensembl_gene_id"/><Attribute name="external_gene_name"/><Attribute name="external_synonym"/></Dataset></Query>'
    echo "Downloading gene aliases from Ensembl Plants BioMart ..."
    ok=0
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 -G "https://plants.ensembl.org/biomart/martservice" \
            --data-urlencode "query=$BIOMART_QUERY" -o "$ALIASES_TSV" && ok=1
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$ALIASES_TSV" --post-data="query=$BIOMART_QUERY" \
            "https://plants.ensembl.org/biomart/martservice" && ok=1
    else
        echo "ERROR: need curl or wget for BioMart (or pass --aliases FILE)." >&2; exit 1
    fi
    if (( ok == 1 )) && [[ -s "$ALIASES_TSV" ]] && ! grep -qi 'Query ERROR' "$ALIASES_TSV"; then
        echo "  aliases: $(wc -l < "$ALIASES_TSV") rows"
    else
        echo "  WARNING: BioMart alias download failed/empty -- proceeding with symbol-or-AGI only." >&2
        ALIASES_TSV=""
    fi
else
    echo "ERROR: unknown --aliases-source: '$ALIASES_SOURCE' (use 'biomart' or 'none', or --aliases FILE)." >&2
    exit 2
fi

# --- 2) normalise deflines + (default) collapse to one longest protein/gene ----
# Emit a FASTA whose first token is the AGI locus, and the details CSV
# (sseqid=AGI, Feature=symbol, Description=function). Pure stdlib python3.
# When an alias table is present, Feature gains a real symbol for un-named loci that have
# one (clone ids stay as synonyms, never the label) and Description is prefixed
# "synonyms: <a, b, ...> - " (see --aliases / BioMart above).
NORM_FAA="$OUT/arabidopsis_proteins.faa"
CSV="$OUT/arabidopsis.csv"
python3 - "$RAW_FAA" "$NORM_FAA" "$CSV" "$KEEP_ISO" "${ALIASES_TSV:-}" <<'PY'
import sys, re, gzip, csv, io

src, faa_out, csv_out, keep_iso = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
aliases_path = sys.argv[5] if len(sys.argv) > 5 else ""

def opener(p):
    return io.TextIOWrapper(gzip.open(p, "rb")) if p.endswith(".gz") else open(p)

# --- alias table: AGI(upper) -> ordered, unique, symbol-like names --------------
AGI_RE = re.compile(r"^AT[1-5CM]G\d{5}$", re.I)
SYM_RE = re.compile(r"^[A-Za-z0-9][\w.+/-]{0,19}$")  # short, space-free gene token

def is_symbol(tok, agi):
    tok = tok.strip()
    if not tok or " " in tok or tok.upper() == agi.upper():
        return False
    return bool(SYM_RE.match(tok))

aliases = {}
if aliases_path:
    with opener(aliases_path) as fh:
        for ln in fh:
            parts = ln.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            agi = parts[0].strip().upper()
            if not AGI_RE.match(agi):     # skips header rows / stray lines
                continue
            bucket = aliases.setdefault(agi, [])
            for tok in parts[1:]:
                if is_symbol(tok, agi) and \
                        tok.strip().upper() not in {b.upper() for b in bucket}:
                    bucket.append(tok.strip())

MAXSYN = 8

def is_clone_name(tok):
    # BAC/clone-derived gene-model name (e.g. F10N7.90, T21H19_100). Real Arabidopsis
    # gene symbols never contain '.' or '_', so such tokens are kept as synonyms but
    # NEVER promoted to the displayed primary -- a clean AGI is more useful to a reader
    # than an obsolete clone id (the AGI is preserved in the Accession column regardless).
    return ("." in tok) or ("_" in tok)

def enrich(agi, sym, desc):
    """Pick the primary symbol; fold any remaining synonyms into the description."""
    agi_u = agi.upper()
    al = aliases.get(agi_u, [])
    ens = None if sym.upper() == agi_u else sym       # Ensembl symbol, if any
    # primary: Ensembl symbol > first real (non-clone) alias > the clean AGI.
    primary = ens or next((a for a in al if not is_clone_name(a)), None) or agi
    seen = {primary.upper()}
    syn = []
    for s in (([ens] if ens else []) + al):
        if s.upper() not in seen:
            seen.add(s.upper())
            syn.append(s)
    if syn:
        more = "" if len(syn) <= MAXSYN else ", ..."
        desc = "synonyms: " + ", ".join(syn[:MAXSYN]) + more + " - " + desc
    return primary, desc

def parse_header(h):
    sid = h.split()[0]
    m = re.search(r"gene:(\S+)", h)
    agi = m.group(1) if m else sid.split(".")[0]
    agi = agi.upper()
    m = re.search(r"gene_symbol:(\S+)", h)
    sym = m.group(1) if m else agi
    if "description:" in h:
        d = h.split("description:", 1)[1]
        d = re.sub(r"\s*\[Source:[^\]]*\]\s*$", "", d).strip()
    else:
        d = "uncharacterized protein"
    return sid, agi, sym, (d or "uncharacterized protein")

# read records
recs = []  # (sid, agi, sym, desc, seq)
sid = agi = sym = desc = None
seq = []
with opener(src) as fh:
    for ln in fh:
        if ln.startswith(">"):
            if sid is not None:
                recs.append((sid, agi, sym, desc, "".join(seq)))
            sid, agi, sym, desc = parse_header(ln[1:].rstrip("\n"))
            seq = []
        else:
            seq.append(ln.strip())
    if sid is not None:
        recs.append((sid, agi, sym, desc, "".join(seq)))

if not keep_iso:
    # one longest protein per AGI locus -> the displayed id is the bare locus
    best = {}
    for sid, agi, sym, desc, s in recs:
        cur = best.get(agi)
        if cur is None or len(s) > len(cur[4]):
            best[agi] = (agi, agi, sym, desc, s)   # set seqid = bare AGI
    out = list(best.values())
else:
    out = recs  # keep isoform id (AT#G#####.N) as the seqid

# write FASTA (first token = seqid = AGI [or AGI.N]) and the details CSV
nseen = set()
n_named = n_syn = 0
with open(faa_out, "w") as fa, open(csv_out, "w", newline="") as cf:
    w = csv.writer(cf)
    w.writerow(["sseqid", "Feature", "Description"])
    for sid, agi, sym, desc, s in out:
        if not s:
            continue
        if sid in nseen:        # guarantee unique ids
            continue
        nseen.add(sid)
        feat, desc2 = enrich(agi, sym, desc)
        if feat.upper() != agi.upper() and sym.upper() == agi.upper():
            n_named += 1        # alias supplied a symbol Ensembl lacked
        if desc2 != desc:
            n_syn += 1          # synonyms folded into the description
        fa.write(f">{sid} {feat} {desc2}\n")
        for k in range(0, len(s), 60):
            fa.write(s[k:k+60] + "\n")
        w.writerow([sid, feat, desc2])

sys.stderr.write(
    f"normalised {len(out)} proteins ({len(nseen)} unique ids written); "
    f"aliases: named {n_named} previously un-named loci, "
    f"added synonyms to {n_syn}\n")
PY

NPROT=$(grep -c '^>' "$NORM_FAA" || true)
NCSV=$(( $(wc -l < "$CSV") - 1 ))
echo "Proteins: $NPROT  (CSV rows: $NCSV)"
(( NPROT > 0 )) || { echo "ERROR: normalisation produced no proteins -- check the source FASTA defline format." >&2; exit 1; }

# --- 3) locate diamond (host -> plannotate SIF -> auto-fetched static binary) ---
# DIAMOND_VERSION matches the plannotate SIF's diamond so the baked .dmnd is
# readable by it (the SIF ships 2.1.15; a version-skewed DB fails to open there).
DIAMOND_VERSION="${DIAMOND_VERSION:-2.1.15}"
DIAMOND=()
if command -v diamond >/dev/null 2>&1; then
    DIAMOND=(diamond)
else
    SIF="${PLAN_SIF:-}"
    [[ -z "$SIF" ]] && SIF="$(ls "${NXF_SINGULARITY_CACHEDIR:-/opt/sif-cache}"/ontresearch-plannotate-*.img 2>/dev/null | head -1 || true)"
    if [[ -n "$SIF" && -f "$SIF" ]] && command -v apptainer >/dev/null 2>&1; then
        DIAMOND=(apptainer exec --bind "$OUT" "$SIF" diamond)
        echo "Using diamond from SIF: $(basename "$SIF")"
    else
        # Neither host diamond nor a SIF: auto-fetch a version-matched static
        # binary so the builder works on a bare networked host (x86_64 only).
        BIN="$OUT/.diamond-${DIAMOND_VERSION}"
        if [[ ! -x "$BIN" ]]; then
            echo "diamond not found; fetching static v${DIAMOND_VERSION} ..."
            URL="https://github.com/bbuchfink/diamond/releases/download/v${DIAMOND_VERSION}/diamond-linux64.tar.gz"
            TGZ="$OUT/.diamond.tar.gz"
            if command -v curl >/dev/null 2>&1; then curl -fSL --retry 3 -o "$TGZ" "$URL" || true
            elif command -v wget >/dev/null 2>&1; then wget -O "$TGZ" "$URL" || true
            else echo "ERROR: need curl or wget to auto-fetch diamond." >&2; exit 1; fi
            if [[ -s "$TGZ" ]] && tar xzf "$TGZ" -C "$OUT" diamond 2>/dev/null; then
                mv -f "$OUT/diamond" "$BIN"; chmod +x "$BIN"
            fi
            rm -f "$TGZ"
        fi
        if [[ -x "$BIN" ]]; then
            DIAMOND=("$BIN"); echo "Using auto-fetched diamond: $BIN"
        else
            echo "ERROR: 'diamond' not found, no plannotate SIF, and auto-fetch failed." >&2
            echo "       Install it (conda install -c bioconda diamond), set PLAN_SIF=/path/to/plannotate.img," >&2
            echo "       or put a 'diamond' binary on PATH (https://github.com/bbuchfink/diamond/releases)." >&2
            exit 1
        fi
    fi
fi

# --- 4) build the diamond DB ---------------------------------------------------
# DB basename MUST be 'arabidopsis' (the pipeline's YAML key -> file stem).
# Absolute -d/--in so it is cwd-independent (host diamond or SIF apptainer alike).
echo "Building diamond DB -> $OUT/arabidopsis.dmnd"
"${DIAMOND[@]}" makedb --in "$NORM_FAA" -d "$OUT/arabidopsis" 2>&1 | tail -3

# --- 5) self-checks ------------------------------------------------------------
echo "== self-check =="
"${DIAMOND[@]}" dbinfo -d "$OUT/arabidopsis" 2>/dev/null | grep -iE 'sequences|letters' || true
echo "CSV head:"; head -3 "$CSV"
[[ -f "$OUT/arabidopsis.dmnd" && -f "$OUT/arabidopsis.csv" ]] || { echo "ERROR: expected artifacts missing." >&2; exit 1; }

cat <<EOF

== DONE ==
  $OUT/arabidopsis.dmnd
  $OUT/arabidopsis.csv

Use it (on the pipeline host, fully offline):
  ARAB_DB="$OUT" ./amplicon_validate.sh <raw_dir> <out_dir>
  # or directly:
  ARAB_DB="$OUT" ./amplicon_annotate/annotate.sh <consensus.fasta> <out_dir>

The annotation will gain an 'Accession' (AGI locus) column + 'arabidopsis' features
carrying the gene symbol (Feature) and function (Description). See
docs/arabidopsis_annotation_plan.md.
EOF
