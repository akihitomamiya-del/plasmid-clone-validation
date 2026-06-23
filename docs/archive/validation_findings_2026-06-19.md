# Devcontainer validation findings — 2026-06-19

In-container validation of the `plasmid-clone-validation` sandboxed devcontainer: confirm the build
is firewalled/rootless and reproduces the `reference_run_canu` correctness target. Run by Claude Code
inside the running container.

- **Host:** kernel 6.17.0-35-generic, 32 cores, 123 GiB RAM, 1.3 TiB free. Runtime user `vscode` =
  **uid 1001 / gid 1001**. Git user `user`.
- **Verdict:** ✅ **Pipeline reproduces the reference exactly** (byte-identical consensus). The sandbox
  (AppArmor + egress firewall + rootless Apptainer + offline SIF cache) is **working as designed**.
  ⚠️ **But the container does not start the pipeline as-shipped on this host** — a uid-portability bug
  required a one-line `sudo chown` workaround (details + fix below). Plus one **security** item worth
  acting on: `vscode`'s blanket sudo can disable the egress firewall.

---

## 1. Result — reference reproduction is exact

Command (offline, as non-root `vscode`, from `docs/verify_devcontainer.md` §4):
```bash
EXTRA_NF_ARGS="--assembly_tool canu --assm_coverage 60" PROFILE=singularity \
  ./clone_validate.sh example_rawdata runs/cv_canu 5000 5000 20 6000
```

| Check | Reference (`reference_run_canu/`) | This run (`runs/cv_canu/cloneval/`) | Match |
|---|---|---|---|
| Status | `barcode69,Completed successfully,5652` | `barcode69,Completed successfully,5652` | ✅ identical |
| Contig length | 5,652 bp | 5,652 bp | ✅ |
| **Consensus seq md5** | `2b78d8db3aacbc918d3e031d8ee7538c` | `2b78d8db3aacbc918d3e031d8ee7538c` | ✅ **byte-identical** |
| Annotations (8) | AmpR, attL1, attL2, ori, PGR3, RNAI, rrnB T1, rrnB T2 | same 8 | ✅ |
| Medaka mean-Q | 56.23 | 56.23 | ✅ |

- **Wall-clock ≈ 3 min** (16:45:24Z → 16:48:17Z). `assembleCore` (canu) 28.8 s, `medakaPolishAssembly` 11 s.
- **All 27 Nextflow processes `COMPLETED`, 0 failed.** Fully offline from `/opt/sif-cache` (no egress).
- The polished consensus matches to the byte — not merely "right length," the identical sequence.

---

## 2. Container validation — all green

| Area | Check | Result |
|---|---|---|
| Firewall | `/tmp/firewall-status` | `ok` |
| Firewall | `example.com`, `pypi.org` (off-allowlist) | blocked ✅ |
| Firewall | `api.github.com` (on-allowlist) | reachable ✅ |
| AppArmor | `/proc/self/attr/current` | `pcv-apptainer (enforce)` ✅ |
| AppArmor | `/proc/kallsyms` read | denied (hardened) ✅ |
| Rootless Apptainer | `apptainer exec …wf-common….img echo …` | `rootless apptainer OK` ✅ |
| Rootless Apptainer | real workflow containers (canu/medaka/plannotate) | all executed nested ✅ |
| Offline cache | 5 `.img` filenames vs `docs/sif_cache.md` manifest | exact match ✅ |
| Offline cache | volume shadowing `/opt/sif-cache` or `/opt/nextflow`? | none (baked into image) ✅ |
| Read filter | `example_rawdata` → 5–6 kb, Q≥20 | 128 reads (5293–5808 bp, minQ 20.02), 765→128 ✅ |
| Runtimes | apptainer / nextflow / seqkit / java / claude | 1.3.6 / 24.10.9 / 2.9.0 / 17.0.19 / 2.1.183 ✅ |
| Claude yolo | `~/.claude` ownership + writability | `vscode`-owned, writable ✅ |

---

## 3. Findings

### 3.1 🔴 BLOCKER (worked around) — the devcontainer is not uid-portable

**Symptom.** Out of the box, `nextflow -version` fails:
`Error: Unable to access jarfile /opt/nextflow/framework/24.10.9/nextflow-24.10.9-one.jar`.
The pipeline cannot start.

**Root cause.** `devcontainer.json` sets `updateRemoteUserUID: true`. The Dockerfile bakes
`/opt/nextflow` + `/opt/sif-cache` into the image and runs `chown -R vscode:vscode /opt/...`
(`.devcontainer/Dockerfile:86`) — but at **build** time `vscode` = uid **1000** (the
`mcr.microsoft.com/devcontainers/base` default). At **runtime**, `updateRemoteUserUID` remaps `vscode`
to match the **host** dev-user uid, which on this host is **1001**. The baked `/opt/*` therefore stays
owned by orphan uid **1000** (there is no uid-1000 user in the container):

```
/opt/nextflow                                          uid=1000 gid=1000 mode=755
/opt/sif-cache                                         uid=1000 gid=1000 mode=755
/opt/nextflow/framework/24.10.9/nextflow-…-one.jar     uid=1000 gid=1000 mode=600   <-- unreadable by 1001
```

The SIF `.img` files happen to survive (mode 755 = world-readable), but the nextflow jar is mode **600**,
so `vscode` (1001) cannot read it → launcher dies. `NXF_HOME` (`/opt/nextflow`) is also unwritable by 1001.

**Why the docs say "validated end-to-end."** That validation (`docs/decision_log.md`,
`docs/host_userns_prereq.md`) ran on a host whose dev-user uid **was 1000** (`validation-host`),
so the build-time chown coincidentally lined up. The bug only appears when **host dev-uid ≠ 1000** — i.e.
on this host, and likely on most other people's machines.

**`/opt/nextflow` must be writable at runtime (not just readable).** Evidence from this run: the
pipeline created `/opt/nextflow/secrets/` and wrote `__pycache__/*.pyc` under
`/opt/nextflow/assets/epi2me-labs/wf-clone-validation/bin/…` during execution. So a fix that only makes
the jar *readable* is insufficient — the runtime uid needs **write** access to `/opt/nextflow`.
(Confirmed harmless: the `plugins/` dir stayed untouched and `nextflow.config` declares no `plugins{}`,
so no plugin download is needed offline; `.nextflow` history/cache + `work/` correctly land in the
writable workspace CWD.)

**Workaround applied this session (so the run could proceed):**
```bash
sudo chown -R vscode:vscode /opt/nextflow /opt/sif-cache
```
This is a *runtime* state change to the running container only — it resets on rebuild and touches no
repo files. It depends on `vscode` having sudo (see 3.2).

**Proper fix (pick one; do at build/config time so no interactive root is needed at runtime):**

- **Recommended — re-align ownership at container start.** Add a tiny root-owned helper
  (`fix-opt-ownership.sh`) that runs `chown -R "$(id -u):$(id -g)" /opt/nextflow /opt/sif-cache`, invoke
  it from `postStartCommand` (next to the firewall), and grant it via a **scoped** sudoers entry. This
  works for *any* host uid and composes with the sudo-hardening in 3.2. `updateRemoteUserUID` runs before
  `postStart`, so the helper sees the final uid. This is the standard devcontainer pattern for
  "baked content owned by build-uid vs. remapped runtime-uid."
- **Alternative — make `/opt` uid-agnostic at build time.** `chmod -R a+rwX /opt/nextflow` (and `a+rX`
  on `/opt/sif-cache`) and drop the build-time `chown`. Avoids all runtime root, but world-writable
  `NXF_HOME` is less tidy; **verify on a host build** that no other NXF_HOME subpath needs writing offline.
- **Do NOT use `updateRemoteUserUID: false`.** It would keep `vscode`=1000 at runtime, which then can't
  write the **bind-mounted workspace** (owned by the host uid 1001) — breaking `runs/` output and git.
  The remap is load-bearing for the workspace; the real bug is only that `/opt` is outside `$HOME` and so
  isn't covered by the remap's home-dir chown.

### 3.2 🟠 SECURITY — `vscode`'s blanket sudo can disable the egress firewall

**Issue.** Inside the container `vscode` has full `(root) NOPASSWD: ALL` (from the base image's
`/etc/sudoers.d/vscode`). The egress firewall is the *only* guardrail that makes
`--dangerously-skip-permissions` safe — but the agent runs as `vscode`, so it can simply:
```bash
sudo iptables -F OUTPUT && sudo iptables -P OUTPUT ACCEPT   # firewall gone; egress wide open
```
and the `firewall-warning.sh` banner won't fire (it only re-checks `/tmp/firewall-status` at shell
start, which still says `ok`). **A containment boundary the contained agent can remove isn't a boundary.**

**Why it's there.** It's the devcontainer base-image default — fine for ordinary dev (the human is
trusted), a liability only because here the "user" is an autonomous agent we're trying to contain. Note
the Dockerfile **already adds the correct least-privilege grant** (`.devcontainer/Dockerfile:62`):
NOPASSWD for **only** `init-firewall.sh` + `start-firewall.sh`. The blanket base grant just makes it moot
(`sudo -l` shows both; `ALL` wins).

**Fix.** Drop the blanket grant, keep the scoped one:
```dockerfile
RUN rm -f /etc/sudoers.d/vscode      # remove base-image NOPASSWD: ALL
```
After this: firewall still self-configures at `postStart` ✅, Apptainer/Nextflow still run rootless ✅
(no sudo needed — the whole AppArmor design), but the agent can't flush its own firewall ✅. Re-running
`sudo start-firewall.sh` only *re-applies* rules (idempotent), so even the scoped power can't tear them
down. If you adopt the 3.1 "recommended" fix, add `fix-opt-ownership.sh` to the same scoped sudoers list.

**Honest caveats (don't oversell):**
1. **Defense-in-depth, not airtight.** Rootless Apptainer deliberately opens
   `userns + mount + seccomp=unconfined + /dev/fuse` — a wider kernel surface than a locked-down
   container. Removing sudo closes the trivial, scriptable escape, not a kernel-level exploit.
2. **Keep the firewall/helper scripts root-owned and non-injectable.** `sudo`-running a *script* is only
   safe because `vscode` can't edit it and it takes no untrusted args. Preserve that invariant.
3. **It removes the in-container escape hatch.** I used that very sudo to fix 3.1. So this only works if
   packaging bugs (esp. 3.1) are fixed at **build** time. Do 3.1 and 3.2 **together**.
4. Optional: gate blanket sudo behind a build `ARG` so a "dev" variant keeps it while the unattended/yolo
   variant ships locked down.

### 3.3 🟡 Minor observations
- **Claude auth token is absent from the container env** (`CLAUDE_CODE_OAUTH_TOKEN` and
  `ANTHROPIC_API_KEY` both unset). Auth currently works off a **credential persisted in the `~/.claude`
  named volume**, not the documented "inject token via host env" path (`CLAUDE.md`, README "Before you
  build"). Two implications: (a) the documented env-injection path was *not* exercised this session;
  (b) if that persisted credential is a normal login **access token** (not a long-lived
  `claude setup-token`), it will expire in hours and can't refresh (firewall blocks claude.ai) — exactly
  the `CLAUDE.md` gotcha. Worth confirming which kind it is.
- **`/opt/custflow/epi2meuser/conda/bin/java` in `ps`** is not a host path — it's a *containerized*
  medaka/canu process visible in the host process list because Apptainer shares the PID namespace.
  Benign; noted so it isn't mistaken for a stray install.
- **`docs/setup_and_plan.md` §9 open item #4** (full end-to-end offline `nextflow run` under the profile)
  can now be marked **resolved** — this run is that confirmation (modulo the 3.1 ownership fix).

---

## 4. Recommendations (prioritized)

| # | Change | Where | Priority |
|---|---|---|---|
| 1 | Fix uid portability — chown `/opt/{nextflow,sif-cache}` to the runtime uid at start via a scoped root-owned helper from `postStartCommand` (or make `/opt` uid-agnostic at build) | `Dockerfile`, `devcontainer.json` | **High** (blocks the run on any host where dev-uid ≠ 1000) |
| 2 | Remove `vscode`'s blanket sudo (`rm -f /etc/sudoers.d/vscode`); keep only the scoped firewall (+ ownership-helper) grant | `.devcontainer/Dockerfile` (after line 62) | **High** (closes firewall-bypass) |
| 3 | Confirm the persisted Claude credential is a long-lived `setup-token`, not an access token; document the env-injection path actually used | README / `CLAUDE.md` | Medium |
| 4 | Mark `setup_and_plan.md` §9 item #4 resolved; note the uid caveat so the next host build expects it | `docs/setup_and_plan.md` | Low |

> ⚠️ **All `Dockerfile`/`devcontainer.json` changes must be built on a networked host** (per `CLAUDE.md`:
> the devcontainer can't be rebuilt inside the firewalled container). Treat recommendations 1–2 as a
> draft change to validate on a host build; the session's runtime `chown` keeps *this* container working
> in the meantime.

---

## 5. How to reproduce these findings

```bash
# environment / sandbox
id; cat /tmp/firewall-status; cat /proc/self/attr/current
curl -sS --max-time 8 https://example.com   >/dev/null && echo BAD || echo blocked
curl -sS --max-time 8 https://api.github.com >/dev/null && echo reachable || echo BLOCKED

# the uid bug (before the workaround)
stat -c '%n uid=%u mode=%a' /opt/nextflow/framework/24.10.9/nextflow-24.10.9-one.jar
nextflow -version            # -> Unable to access jarfile  (as uid 1001)

# blanket sudo
sudo -l | grep -i 'NOPASSWD: ALL'

# workaround + run
sudo chown -R vscode:vscode /opt/nextflow /opt/sif-cache
EXTRA_NF_ARGS="--assembly_tool canu --assm_coverage 60" PROFILE=singularity \
  ./clone_validate.sh example_rawdata runs/cv_canu 5000 5000 20 6000

# compare to reference
diff reference_run_canu/output/sample_status.txt runs/cv_canu/cloneval/sample_status.txt
md5sum <(grep -v '^>' reference_run_canu/output/barcode69.final.fasta      | tr -d '\n' | tr a-z A-Z) \
       <(grep -v '^>' runs/cv_canu/cloneval/barcode69.final.fasta          | tr -d '\n' | tr a-z A-Z)
```

## 6. Appendix — raw evidence

```
# runtime user vs baked ownership
uid=1001(vscode) gid=1001(vscode)
getent passwd 1000  -> (none: orphaned ownership)

# sudo -l (vscode)
(root) NOPASSWD: ALL
(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/start-firewall.sh

# SIF cache (filenames match docs/sif_cache.md exactly)
ontresearch-wf-clone-validation-sha0ebc91d22c0ea5183272af8bf2b96ca51e88ad5d.img   1280364544
ontresearch-canu-sha50e56c57b7dfcc28ea176895c6ad98b43c607df2.img                  1170878464
ontresearch-medaka-shacf8338462607b17b1d68dbce212cb93daea50bad.img                 826220544
ontresearch-plannotate-shae4901fb4353581a26049f564d279edd81fe38805.img             846299136
ontresearch-wf-common-shafdd79f8e4a6faad77513c36f623693977b92b08e.img              784433152

# nextflow trace: 27/27 COMPLETED, 0 FAILED; assembleCore 28.8s, medakaPolishAssembly 11s
```

---

## 7. Applying & validating the fix (host rebuild)

> Implements recommendations 1 + 2. **Untested in-container** (per `CLAUDE.md` the devcontainer can't
> be rebuilt inside the firewall) — validate on a host rebuild. The *current* running container is
> unaffected; the session `chown` workaround (§3.1) keeps it working until you rebuild.

### What changed (working tree, uncommitted)
- **`.devcontainer/fix-opt-ownership.sh`** (new) — root helper: `chown -R vscode:vscode /opt/{nextflow,sif-cache}`. Non-injectable (no args, fixed paths), root-owned.
- **`.devcontainer/Dockerfile`** — new block *after* the SIF/npm layers (keeps the ~4.8 GB cache warm):
  `COPY fix-opt-ownership.sh`, `rm -f /etc/sudoers.d/vscode` (drop blanket sudo), add scoped
  `vscode-fixopt` NOPASSWD grant. The scoped `vscode-firewall` grant (Dockerfile:62) is untouched.
- **`.devcontainer/devcontainer.json`** — `postStartCommand` now runs `fixOwnership` + `firewall`
  (both scoped sudo, parallel); comment on why `updateRemoteUserUID:true` stays.

### Rebuild on the host (NOT inside this container)
Use the Dev Containers flow — plain `docker run` won't exercise the bug (it starts as the image's
uid 1000, skipping the `updateRemoteUserUID` remap *and* the `postStart` hooks):
```bash
# VS Code: Command Palette -> "Dev Containers: Rebuild Container"
# or, CLI from the repo root on the host:
devcontainer up --build --workspace-folder .
```
Host prereq unchanged: the `pcv-apptainer` AppArmor profile must be loaded
(`sudo bash .devcontainer/setup-host-apparmor.sh`) — already loaded on this host.

### Pass/fail checklist (run inside the freshly rebuilt container)
| # | Check | Command | Expected (fix working) |
|---|---|---|---|
| 1 | uid fix — runs with **no** manual chown | `nextflow -version` | prints `24.10.9` |
| 2 | jar readable as runtime uid | `stat -c '%U %a' /opt/nextflow/framework/*/nextflow-*.jar` | owner `vscode` |
| 3 | sudo is scoped only | `sudo -l` | only `vscode-firewall` + `vscode-fixopt`; **no** `NOPASSWD: ALL` |
| 4 | firewall still self-configured | `cat /tmp/firewall-status` | `ok` |
| 5 | agent can't touch the firewall | `sudo -n iptables -L OUTPUT` *(read-only; safe)* | `sudo: a password is required` (denied) |
| 6 | reproduction intact | the §1 canu run | status `5652`, consensus md5 `2b78d8db…7538c` |

All six green ⇒ both fixes validated and the container is correct out-of-the-box on any host uid.
If something legitimately needs root at runtime, extend the **scoped** sudoers list — do *not* re-add
the blanket grant.

### Rollback
Revert the changed files (`git checkout -- .devcontainer/`) and rebuild; or, on a still-running
container, the §3.1 one-liner (`sudo chown -R vscode:vscode /opt/nextflow /opt/sif-cache`) restores
the pre-fix workaround.

---

## 8. Host-rebuild validation RESULTS — 2026-06-20 ✅

> Executes the §7 plan. Run **on the host** `validation-host` as **user (uid 1001)** with
> Docker 29.6 — i.e. exactly the `dev-uid ≠ 1000` condition that triggers §3.1. (This host has **two**
> dev users: `user`=uid 1000 — the original validator, so the bug stayed hidden — and
> `user`=uid 1001. That two-user split is the real explanation of the §3.1 "uid 1000" note.)
> The §1 reference container (`hardcore_stonebraker`) was left running and untouched; all testing used
> throwaway images/containers + an isolated temp workspace.

### 8.1 Build — the modified Dockerfile builds, cache stays warm ✅
`docker build` of the modified Dockerfile succeeded (exit 0). Every expensive layer was **`CACHED`**
(`#14` apptainer/SIF-pull, `#15` `nextflow pull`, `#16` firewall COPY, `#17` .claude chown); only the
new tail layers re-ran (`#18` `COPY fix-opt-ownership.sh`, `#19` sudoers lockdown, `#20` bashrc). **§7's
"keeps the ~4.8 GB cache warm" claim is confirmed** — no SIF re-pull. Fresh image verified: `/etc/sudoers.d/vscode`
**gone**; only `vscode-firewall` + `vscode-fixopt` remain (both `0440`); `fix-opt-ownership.sh` `root:root 0755`;
`/opt` owned by build-uid **1000**, jar `0600` (the orphaned precondition).

### 8.2 Method — faithful runtime reproduction
Derived a uid-remapped image replicating VS Code's `updateRemoteUserUID` exactly (rewrite `vscode`→`1001`
in passwd/group + `chown -R 1001 $HOME` only; `/opt` left at 1000 — confirmed from the live `-uid` image's
build history). Ran with the **production `runArgs`** (`--cap-add NET_ADMIN/NET_RAW`, `seccomp=unconfined`,
`apparmor=pcv-apptainer`, `systempaths=unconfined`, `/dev/fuse`); container reported `pcv-apptainer (enforce)`.
**Bug reproduced pre-fix:** `nextflow -version` → `Unable to access jarfile …` (jar `0600` owned by orphan 1000).

### 8.3 §7 checklist — all six PASS (+ added egress test)
| # | Check | Result |
|---|---|---|
| 1 | `nextflow -version`, no manual chown | `version 24.10.9 build 5943` ✅ |
| 2 | jar + /opt owner after `fixOwnership` | `vscode` ✅ (re-chowned to runtime uid 1001) |
| 3 | `sudo -l` scoped only | only `vscode-firewall` + `vscode-fixopt`; **no `NOPASSWD: ALL`** ✅ |
| 4 | `/tmp/firewall-status` | `ok` ✅ |
| **4b** | **egress functional** (added per review) | `example.com` **blocked**, `api.github.com` reachable ✅ |
| 5 | `sudo -n iptables -L/-F OUTPUT` | **denied** ("password required") — firewall-flush attack closed ✅ |
| 6 | canu reproduction | status `…,Completed successfully,5652`; consensus md5 **`2b78d8db…7538c`** byte-identical ✅ |

**Both §7 fixes are validated end-to-end on a uid-1001 host.** Ship after a host rebuild (the §1
container needs none — it already carries the manual workaround).

### 8.4 🟠 NEW SECURITY FINDING (now fixed) — silent firewall fail-open via `/tmp/firewall-status` pre-plant
Found during the security review; **confirmed reproducible**. `/tmp` is world-writable+sticky and the host
sets `fs.protected_regular = 2`. A contained agent can pre-plant a **vscode-owned** `/tmp/firewall-status="ok"`.
On the *next container start* (a **restart** preserves `/tmp`; a rebuild does not), `start-firewall.sh`'s
`echo "failed" > "$STATUS_FILE"` then fails with **EACCES even as root** (protected_regular blocks writing a
foreign-owned file in a sticky dir) → `set -e` **aborts the script before `init-firewall.sh` ever runs** →
**iptables stays `OUTPUT ACCEPT` (egress wide open)** while the stale `"ok"` keeps `firewall-warning.sh` **silent**.
Proven: root write → `Permission denied`; `start-firewall rc=1`; `iptables -S OUTPUT` → `-P OUTPUT ACCEPT`;
`curl example.com` → **REACHABLE**. This is *pre-existing* (not introduced by §7), but §7 removed the easier
`sudo iptables -F` lever, making this the new weakest link — so it's worth closing now.

- **Severity:** Medium — needs a restart (not a fresh rebuild) **and** a prior pre-plant by the agent.
- **Fix applied** (`.devcontainer/start-firewall.sh`): `rm -f "$STATUS_FILE"` **before** writing it. root can
  unlink it (CAP_FOWNER in a sticky dir); recreating it makes the file **root-owned**, after which the agent
  can neither overwrite (DAC `0644`) nor delete (sticky bit) it.
- **Proven fixed:** with the pre-plant in place + patched script → `Firewall active`, `rc=0`, status file
  `root:root 0644 = ok`, `iptables -P OUTPUT DROP`, `example.com` **blocked**, `api.github.com` reachable;
  and vscode re-tamper attempts → overwrite `Permission denied`, delete `Operation not permitted`. ✅
- **Caveat:** `start-firewall.sh` is `COPY`d *before* the SIF-pull layer (Dockerfile:60), so editing it
  **does bust the SIF cache on rebuild** (one ~4.8 GB re-pull). Acceptable on a host rebuild; optionally move
  the firewall-scripts `COPY` after the SIF layers (as the §7 block was) to keep edits cache-cheap.

### 8.5 Follow-ups
- **MUST before commit:** `git add .devcontainer/fix-opt-ownership.sh` — it is **untracked**, yet the Dockerfile
  `COPY fix-opt-ownership.sh` depends on it. The build only succeeded here because the file is on disk; a fresh
  clone would fail to build. (`docs/validation_findings_2026-06-19.md` is also untracked — add if you want it in history.)
- **Checklist:** keep the new **4b egress test**; consider a fail-open regression check (pre-plant `ok`, run
  start-firewall, assert `example.com` blocked).
- **Inherent / out-of-scope (acknowledged, no action required):** brief startup egress window before postStart
  applies iptables; wider kernel surface from rootless Apptainer's `userns + seccomp=unconfined + systempaths=unconfined`
  (AppArmor `deny` rules for sensitive `/proc`,`/sys` confirmed enforcing); firewall scripts are mode `0775`
  (group=root, not vscode — not exploitable; `0755` is tidier).
- **Verdict:** §7's uid-portability + sudo-lockdown fixes are **correct and complete**; the firewall guardrail
  still enforces egress; the one real residual (8.4) is now closed and tested.
