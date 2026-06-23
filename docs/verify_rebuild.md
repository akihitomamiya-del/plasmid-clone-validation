# Self-check after a devcontainer rebuild — point your in-container Claude Code here

**How to use:** after "Dev Containers: Reopen in Container" (the **`claude-code`** config), open Claude
Code inside the container and say: **"Follow `docs/verify_rebuild.md` and report."**

**Your task (you are the contained yolo agent):** verify the rebuild is correct, the sandbox is
enforcing, and the pipeline reproduces the reference. **Run every command and paste its real output —
never summarize, and never claim PASS without showing the output.** End with a PASS/FAIL table + an
overall verdict.

---

## A. Standard checks
Run the **`claude-code`** subset of [`verify_devcontainer.md`](verify_devcontainer.md) and paste each
command's output. At minimum:

```bash
cat /tmp/firewall-status                                    # expect: ok
curl -sS --max-time 6 https://example.com    >/dev/null 2>&1 && echo "example.com REACHABLE (FAIL)"  || echo "example.com blocked (PASS)"
curl -sS --max-time 6 https://api.github.com >/dev/null 2>&1 && echo "api.github.com reachable (PASS)" || echo "api.github.com BLOCKED (FAIL)"
cat /proc/self/attr/current                                 # expect: pcv-apptainer (enforce)
id                                                          # non-root vscode
nextflow -version 2>&1 | grep -iom1 'version [0-9.]*'       # expect: version 24.10.9  (no manual chown needed = uid fix worked)
stat -c '%U %a' /opt/nextflow/framework/*/nextflow-*-one.jar   # expect owner: vscode
stat -c '%U:%G %a' /opt/sif-cache/*.img | sort -u          # expect: root:root 755   (5 SIFs, world-readable, not chowned)
apptainer exec /opt/sif-cache/ontresearch-wf-common-*.img echo "rootless apptainer OK"
```

## B. Containment — prove it on YOURSELF (you are the agent being contained)
All five must be **PASS** — the firewall + your immutable, root-owned tooling are what make yolo mode safe.

```bash
sudo -n -l 2>/dev/null | grep -q 'NOPASSWD: ALL' && echo "blanket sudo PRESENT (FAIL)" || echo "no blanket sudo (PASS)"
sudo -n iptables -L OUTPUT >/dev/null 2>&1 && echo "can touch firewall (FAIL)" || echo "iptables denied (PASS)"
( echo x > "$(npm root -g)/_probe" )                  2>/dev/null && echo "wrote global node_modules (FAIL)" || echo "global npm immutable (PASS)"
( echo x >> "$(readlink -f "$(command -v claude)")" ) 2>/dev/null && echo "modified own claude (FAIL)"        || echo "claude immutable (PASS)"
( npm install -g cowsay --silent ) >/dev/null 2>&1                && echo "npm i -g succeeded (FAIL)"          || echo "npm i -g denied (PASS)"
```

## C. End-to-end: the offline assembly reproduces the reference (~3 min — the real test)
Matched-params run — this reproduces the reference **byte-for-byte**:

```bash
EXTRA_NF_ARGS="--assembly_tool canu --assm_coverage 60" PROFILE=singularity \
  ./clone_validate.sh example_rawdata runs/cv 5000 5000 20 6000
find runs/cv -name sample_status.txt -exec cat {} +        # expect: barcode69,Completed successfully,5652
FA=$(find runs/cv -name '*.final.fasta' | head -1)
md5sum <(grep -v '^>' "$FA" | tr -d '\n' | tr a-z A-Z) \
       <(grep -v '^>' reference_run_canu/output/barcode69.final.fasta | tr -d '\n' | tr a-z A-Z)
# PASS = both md5 == 2b78d8db3aacbc918d3e031d8ee7538c   (byte-identical to the reference)
```

> Note: `./clone_validate.sh example_rawdata runs/cv auto` (the recommended default) also assembles
> `5652 bp` / `Completed successfully`, but its **md5 differs** — AUTO picks data-driven params
> (`approx_size≈5623`, default coverage), a different-but-valid consensus. Use the **matched-params**
> command above for the byte-identical check.

---

## Report
Emit a table — **check · expected · actual · PASS/FAIL** — then an **overall verdict**: *sandbox
enforcing + pipeline reproduces the reference?* For any FAIL, paste the failing command's output and
give your best guess at the cause. Do not declare an overall PASS unless every command's real output
is shown.

---

## Extended verification — the other code paths (run 2026-06-21, all PASS)

Sections A–C prove the *happy path* (matched-params canu run + containment). These extra checks cover
the paths A–C skip: **AUTO sizing**, the **pre-filter** itself, the **guardrails** (which must *refuse*,
not just succeed), **firewall depth** (IP-layer, not just one domain), and the **flye failure path** that
makes canu the load-bearing default. All run on `example_rawdata/barcode69` (765 raw reads).

### Functional code-path coverage
| # | Check | Command | Expected | Actual | Result |
|---|---|---|---|---|---|
| 1 | **AUTO mode** end-to-end (the recommended default) | `./clone_validate.sh example_rawdata runs/cv_auto auto` | `Completed successfully` / 5652 bp; alias `sample69`; per-sample `approx_size` from peak; **md5 differs** from reference (data-driven) | `sample69,Completed successfully,5652`; sheet `barcode69,sample69,5623`; md5 `3c8f198f…` ≠ ref `2b78d8db…` | **PASS** |
| 2 | **Pre-filter** read count (our contribution, in isolation) | `./filter_nanopore_reads.sh example_rawdata /tmp/filt_check 5000 20 6000` → `seqkit stats` | 128 reads kept, 5–6 kb, Q≥20 | `765 → 128 kept (16.7%)`, 5293–5808 bp, minQ 20.02 | **PASS** |
| 3 | **Peak estimator** (AUTO's sizing brain), standalone | `./estimate_length_peak.sh example_rawdata/barcode69/*.fastq.gz --report-only` | prints `PEAK_WINDOW peak lo hi` | `PEAK_WINDOW 5623 5061 6185` (peak 5623, in-window 274/765) | **PASS** |

### Negative tests — the guardrails must fire
| # | Check | Command | Expected | Actual | Result |
|---|---|---|---|---|---|
| 4 | **`approx_size` envelope guard** refuses a re-clipping size | `./clone_validate.sh example_rawdata /tmp/guard_test 3000 5000 20 6000` | warns + `Refusing to continue`; **exit ≠ 0** (range for window [5000,6000] is [5000,10000]) | warning printed; `Refusing to continue; re-run with FORCE=1`; **exit 1** | **PASS** |
| 5 | **flye fails on these reads** (why canu is the default) | `EXTRA_NF_ARGS="--assembly_tool flye" ./clone_validate.sh example_rawdata /tmp/cv_flye 5000 5000 20 6000` | assembly fails; status ≠ "Completed"; no `.final.fasta`; SIGFPE from min-overlap > read len | `barcode69,Failed to assemble using Flye,N/A`; 0 assemblies; log: N50 5634, "Minimum overlap set to 6000", `died with <Signals.SIGFPE: 8>` | **PASS** |

> #5 reproduces `docs/assembly_findings_2026-06-21.md` verbatim: flye auto-picks min-overlap **6000 bp**
> (> the ~5.6 kb reads) → zero overlaps → divide-by-zero **SIGFPE**, on all 4 retries. The workflow then
> reports the sample as failed and still emits a report — it does not crash the run.

### Firewall depth & statics
| # | Check | Command | Expected | Actual | Result |
|---|---|---|---|---|---|
| 6a | egress blocked at the **IP layer**, not just by domain | `curl --max-time 6 https://1.1.1.1` | blocked (a DNS-only block would be a hole) | `direct-IP egress blocked` | **PASS** |
| 6b | npm registry reachable (allowlisted) | `curl --max-time 6 https://registry.npmjs.org` | reachable | `npm registry reachable` | **PASS** |
| 7 | script **syntax** (CLAUDE.md's own verify step) | `bash -n clone_validate.sh filter_nanopore_reads.sh estimate_length_peak.sh` | clean | `syntax OK` | **PASS** |

*(api.anthropic.com reachability needs no test — the contained Claude agent talks to it to run these checks.)*

### Does the pipeline emit the EPI2ME-GUI HTML report? — **YES, identical**
Every run (matched, AUTO) writes `<out>/cloneval/wf-clone-validation-report.html` (~2.4 MB) — the **same
report the EPI2ME desktop GUI shows**, because the GUI is just a launcher around this same `wf-clone-validation`
Nextflow workflow; the `pipeline:report` process generates the HTML on both paths.

| Check | Ours (`runs/cv_auto/cloneval/`) | EPI2ME reference (`reference_run_canu/output/`) |
|---|---|---|
| `wf-clone-validation-report.html` | 2.4 MB, `<title>Clone validation report</title>`, EPI2ME/ezcharts | 2.5 MB, same title + generator |
| `execution/report.html` (Nextflow resources) | 2.9 MB | 2.9 MB |
| `execution/timeline.html` | 254 KB | 254 KB |

Same sections as the GUI: *Sample status, Read/assembly QC, Inserts, Annotation (plannotate)*. Open it in any
browser — no GUI install needed. Sidecar outputs also match: `*.final.fasta`, `*.annotations.gbk/.bed`,
`plannotate.json`, `*.assembly_stats.tsv`, `feature_table.txt`, `sample_status.txt`.
