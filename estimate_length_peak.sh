#!/usr/bin/env bash
#
# estimate_length_peak.sh
# -----------------------
# Data-driven read-length peak finder + length-window filter for Oxford Nanopore
# plasmid reads. For a Rapid Barcoding (RBK) plasmid library the full-length
# linearised construct shows up as a sharp read-length mode (~ the plasmid size);
# this script locates that mode and derives a length window around it WITHOUT a
# hand-picked threshold, then writes the in-window reads for assembly.
#
# Why it is robust (the raw signal is bimodal: short adapter/fragment junk near 0
# bp PLUS the full-length peak):
#   * YIELD weighting (default) — each read contributes its LENGTH to its bin, so
#     the full-length molecule (which dominates sequenced bases) wins even when
#     short fragments dominate read COUNT. Rare long concatemers carry few reads,
#     so they don't move the mode either.
#   * a min-length floor ignores the adapter/fragment pile when locating the peak.
#   * histogram smoothing removes single-bin noise before argmax.
#
# Usage:
#   ./estimate_length_peak.sh <reads.fastq[.gz]> [options]
#
# Options:
#   --bin BP        histogram bin width                       (default 50)
#   --smooth N      smoothing half-window, in bins            (default 5)
#   --floor BP      ignore reads < BP when locating the peak  (default 1000)
#   --weight W      histogram weighting: yield | count        (default yield)
#   --width METHOD  window rule around the peak:
#                     pct:P   peak +/- P percent              (default pct:15)
#                     fwhm    full width at half maximum (data-driven width)
#                     valley  out to the density minima either side (clamped)
#   --min-qual Q    also require mean read Q >= Q in the output (default 0 = off)
#   -o FILE         filtered-reads output  (default <input>.peak<lo>-<hi>.fastq.gz)
#   --report-only   print the peak/window report; do NOT write filtered reads
#   -j N            seqkit threads                            (default 8)
#   -h|--help       show this header
#
# Output: a human report (peak, window, read/yield counts, coverage estimate, an
# ASCII histogram with the peak '^' and window '|' marked) on stderr, and the
# filtered FASTQ (unless --report-only). The last stdout line is machine-readable:
#   PEAK_WINDOW <peak_bp> <lo_bp> <hi_bp>
# so it can drive the rest of the repo, e.g.:
#   read _ PEAK LO HI < <(./estimate_length_peak.sh reads.fastq.gz --report-only | tail -1)
#   EXTRA_NF_ARGS="--assembly_tool canu" ./clone_validate.sh in out "$PEAK" "$LO" 15 "$HI"
#
# seqkit is used for length/quality so --min-qual matches wf-clone-validation's own
# error-probability mean-Q (the same metric filter_nanopore_reads.sh uses).

set -euo pipefail

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; }

# ---- defaults ----
BIN=50; SMOOTH=5; FLOOR=1000; WEIGHT=yield; WIDTH="pct:15"; MINQ=0
OUT=""; REPORT_ONLY=0; J=8

[[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
IN="$1"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin)        BIN="$2"; shift 2;;
    --smooth)     SMOOTH="$2"; shift 2;;
    --floor)      FLOOR="$2"; shift 2;;
    --weight)     WEIGHT="$2"; shift 2;;
    --width)      WIDTH="$2"; shift 2;;
    --min-qual)   MINQ="$2"; shift 2;;
    -o)           OUT="$2"; shift 2;;
    --report-only) REPORT_ONLY=1; shift;;
    -j)           J="$2"; shift 2;;
    -h|--help)    usage; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

command -v seqkit >/dev/null 2>&1 || { echo "ERROR: seqkit not found on PATH" >&2; exit 1; }
[[ -f "$IN" ]] || { echo "ERROR: input not found: $IN" >&2; exit 1; }
case "$WEIGHT" in yield|count) ;; *) echo "ERROR: --weight must be yield|count" >&2; exit 2;; esac
METHOD="${WIDTH%%:*}"; PCT="${WIDTH#*:}"; [[ "$METHOD" == "pct" ]] || PCT=10
case "$METHOD" in pct|fwhm|valley) ;; *) echo "ERROR: --width must be pct:P|fwhm|valley" >&2; exit 2;; esac

# ---- read lengths (seqkit handles .gz natively) ----
# fx2tab -nli -> "id\tlength"; take the length column.
mapfile_tmp="$(mktemp)"; trap 'rm -f "$mapfile_tmp"' EXIT
seqkit fx2tab -j "$J" -nli "$IN" 2>/dev/null | cut -f2 > "$mapfile_tmp"
[[ -s "$mapfile_tmp" ]] || { echo "ERROR: no reads parsed from $IN" >&2; exit 1; }

# ---- peak + window via awk (report -> stderr, machine line -> stdout) ----
read -r PEAK LO HI TOTAL WIN < <(
  awk -v B="$BIN" -v S="$SMOOTH" -v FLOOR="$FLOOR" -v WEIGHT="$WEIGHT" \
      -v METHOD="$METHOD" -v P="$PCT" '
  { L=$1+0; if(L<=0) next; total++; totyield+=L; b=int(L/B);
    cnt[b]++; yld[b]+=L; if(b>maxbin) maxbin=b }
  END{
    for(b=0;b<=maxbin;b++){ w[b]=(WEIGHT=="yield")?(yld[b]+0):(cnt[b]+0) }
    # boxcar smoothing
    for(b=0;b<=maxbin;b++){ s=0; for(j=b-S;j<=b+S;j++) if(j>=0&&j<=maxbin) s+=w[j]; sm[b]=s }
    fb=int(FLOOR/B); pk=-1; pkv=-1
    for(b=fb;b<=maxbin;b++) if(sm[b]>pkv){ pkv=sm[b]; pk=b }
    if(pk<0){ print "ERR" > "/dev/stderr"; exit 2 }
    # refine peak center: density-weighted centroid over the half-max plateau
    half=pkv*0.5
    lr=pk; while(lr>fb && sm[lr-1]>=half) lr--
    hr=pk; while(hr<maxbin && sm[hr+1]>=half) hr++
    num=0; den=0; for(b=lr;b<=hr;b++){ c=(b+0.5)*B; num+=c*sm[b]; den+=sm[b] }
    peak=(den>0)?num/den:(pk+0.5)*B
    if(METHOD=="pct"){ lo=peak*(1-P/100.0); hi=peak*(1+P/100.0) }
    else if(METHOD=="fwhm"){ lo=lr*B; hi=(hr+1)*B }
    else { # valley: descend to a local min OR below 5% of peak, each side; clamp left at FLOOR
      tau=pkv*0.05
      lb=pk; while(lb>fb && sm[lb-1]<=sm[lb] && sm[lb-1]>tau) lb--
      rb=pk; while(rb<maxbin && sm[rb+1]<=sm[rb] && sm[rb+1]>tau) rb++
      lo=lb*B; hi=(rb+1)*B; if(lo<FLOOR) lo=FLOOR
    }
    win=0; for(b=0;b<=maxbin;b++){ c=(b+0.5)*B; if(c>=lo&&c<=hi) win+=cnt[b] }
    printf "%.0f %.0f %.0f %d %d\n", peak, lo, hi, total, win

    # ---- ASCII histogram to stderr (count-based bars; ^=peak, |=window edges) ----
    # collapse fine bins into ~24 display rows spanning floor-ish..just past peak
    printf "  read-length distribution (count; bin=%dbp, weight=%s)\n", B, WEIGHT > "/dev/stderr"
    dispmax=int((hi*1.6)/B); if(dispmax>maxbin) dispmax=maxbin
    cmax=0; for(b=0;b<=dispmax;b++) if(cnt[b]>cmax) cmax=cnt[b]
    step=int((dispmax+1)/40); if(step<1) step=1
    for(b=0;b<=dispmax;b+=step){
      cc=0; lab=b*B
      for(j=b;j<b+step&&j<=dispmax;j++) cc+=cnt[j]
      bar=""; k=(cmax>0)?int(50*cc/cmax):0; for(i=0;i<k;i++) bar=bar"#"
      mark=" "; if(lab<=peak && peak<lab+step*B) mark="^"
      edge=""; if(lo>=lab&&lo<lab+step*B) edge=edge" <lo"; if(hi>=lab&&hi<lab+step*B) edge=edge" <hi"
      printf "  %6d %s %-50s %d%s\n", lab, mark, bar, cc, edge > "/dev/stderr"
    }
  }' "$mapfile_tmp"
)

[[ -n "${PEAK:-}" ]] || { echo "ERROR: peak estimation failed" >&2; exit 1; }
LO=${LO%.*}; HI=${HI%.*}; PEAK=${PEAK%.*}

# ---- report ----
{
  echo
  echo "  estimated full-length peak : ${PEAK} bp"
  echo "  derived length window      : ${LO} - ${HI} bp   (rule: ${WIDTH})"
  echo "  reads total / in-window    : ${TOTAL} / ${WIN}   ($(awk -v a="$WIN" -v b="$TOTAL" 'BEGIN{printf "%.1f%%", (b>0)?100*a/b:0}'))"
  [[ "$MINQ" != "0" ]] && echo "  output also requires        : mean Q >= ${MINQ}"
} >&2

if [[ "$REPORT_ONLY" == "1" ]]; then
  echo "PEAK_WINDOW ${PEAK} ${LO} ${HI}"
  exit 0
fi

# ---- filter ----
if [[ -z "$OUT" ]]; then
  base="$(basename "$IN")"; base="${base%.fastq.gz}"; base="${base%.fq.gz}"; base="${base%.fastq}"; base="${base%.fq}"
  OUT="$(dirname "$IN")/${base}.peak${LO}-${HI}.fastq.gz"
fi
sk=(seqkit seq --min-len "$LO" --max-len "$HI" -j "$J")
[[ "$MINQ" != "0" ]] && sk+=(--min-qual "$MINQ")
"${sk[@]}" "$IN" -o "$OUT" 2>/dev/null
kept="$(seqkit stats -T "$OUT" 2>/dev/null | awk 'NR==2{print $4}')"
echo "  wrote ${kept:-0} reads -> ${OUT}" >&2
echo "PEAK_WINDOW ${PEAK} ${LO} ${HI}"
