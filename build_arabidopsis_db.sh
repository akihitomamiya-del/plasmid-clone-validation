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
#   -h|--help          show this header
#
# Requires: curl or wget (unless --source); diamond. If diamond is not on PATH the
# script will use `apptainer exec "$PLAN_SIF" diamond` when $PLAN_SIF (or a plannotate
# SIF under $NXF_SINGULARITY_CACHEDIR / /opt/sif-cache) is available -- this also
# version-matches the SIF's diamond (2.1.x). Install diamond via:  conda install -c
# bioconda diamond   (or download the static binary from the diamond GitHub release).

set -euo pipefail
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

OUT="./arabidopsis_db"; REL=63; SOURCE=""; KEEP_ISO=0
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --release) REL="$2"; shift 2;;
    --source) SOURCE="$2"; shift 2;;
    --keep-isoforms) KEEP_ISO=1; shift;;
    -*) echo "unknown option: $1" >&2; exit 2;;
    *) args+=("$1"); shift;;
  esac
done
[[ ${#args[@]} -ge 1 ]] && OUT="${args[0]}"

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
echo "== build_arabidopsis_db =="
echo "out=$OUT  release=$REL  keep_isoforms=$KEEP_ISO  source=${SOURCE:-<download>}"

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

# --- 2) normalise deflines + (default) collapse to one longest protein/gene ----
# Emit a FASTA whose first token is the AGI locus, and the details CSV
# (sseqid=AGI, Feature=symbol, Description=function). Pure stdlib python3.
NORM_FAA="$OUT/arabidopsis_proteins.faa"
CSV="$OUT/arabidopsis.csv"
python3 - "$RAW_FAA" "$NORM_FAA" "$CSV" "$KEEP_ISO" <<'PY'
import sys, re, gzip, csv, io

src, faa_out, csv_out, keep_iso = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"

def opener(p):
    return io.TextIOWrapper(gzip.open(p, "rb")) if p.endswith(".gz") else open(p)

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
with open(faa_out, "w") as fa, open(csv_out, "w", newline="") as cf:
    w = csv.writer(cf)
    w.writerow(["sseqid", "Feature", "Description"])
    for sid, agi, sym, desc, s in out:
        if not s:
            continue
        if sid in nseen:        # guarantee unique ids
            continue
        nseen.add(sid)
        fa.write(f">{sid} {sym} {desc}\n")
        for k in range(0, len(s), 60):
            fa.write(s[k:k+60] + "\n")
        w.writerow([sid, sym, desc])

sys.stderr.write(f"normalised {len(out)} proteins ({len(nseen)} unique ids written)\n")
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
