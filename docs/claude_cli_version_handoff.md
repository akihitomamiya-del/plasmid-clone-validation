# Handoff: keep the Claude CLI fresh in the claude-code sandbox (scoped-sudo, no rebuild)

**Audience:** a Claude Code (or human) on a **networked host** with **Docker + `/dev/fuse`**, where the
devcontainer images can be **built and validated**. This can't be done inside the firewalled sandbox
(egress is GitHub/npm/Anthropic only; `CLAUDE.md` forbids validating `.devcontainer/claude-code/` changes
there). Investigated + designed in-sandbox 2026-06-25.

**Status — reviewed, hardened, and host-validated 2026-06-25; pending commit + republish.** Implemented as
Option A on branch `feat/claude-cli-version-refresh`. Three hardening deviations from the snippets below were
made during review and are reflected here: (1) the npm install also pins the `@anthropic-ai`-scoped registry
(`--registry` alone does not constrain a scoped package); (2) the `claudeRefresh` postCreate is
`[ -x ]`-guarded so a pulled image predating the script skips cleanly instead of failing create; (3) an
offline-retry observation in §8. Remaining: **merge `security/firewall-hardening-rootful` first (§9), then
build+push `:claude-code` (§8, manual — CI never builds it).** Files:

- `+ .devcontainer/claude-code/install-claude.sh` — new root-run, registry-pinned refresh script
- `~ .devcontainer/claude-code/Dockerfile` — COPY it + add a **third scoped** sudo grant (keeps the baked
  Claude as an offline fallback)
- `~ .devcontainer/claude-code/devcontainer.json` — postCreate `claudeRefresh`
- `~ .devcontainer/claude-code-image/devcontainer.json` — postCreate `claudeRefresh`

---

## 1. The goal

The Claude CLI in the sandbox **feels pinned** — rebuilds don't pick up new releases. Make it track
`@latest` **without an image rebuild** and **without weakening containment**: keep **scoped sudo** (the
agent must never get arbitrary root or be able to flush the egress firewall) and keep Claude **root-owned**
(the agent must not be able to replace its own CLI).

Symptom, measured in-sandbox 2026-06-25:
```
claude --version                           -> 2.1.187
npm view @anthropic-ai/claude-code version -> 2.1.191   # behind, despite "@latest"
```

## 2. Why it's stale (it is NOT actually pinned)

`@latest` resolves at **image-build time**, then freezes:
1. **Build cache** — `RUN npm install -g …@latest` is cached by its literal text, so a *warm* rebuild
   reuses the old install. (The `CLAUDE.md` note "Claude updates by rebuilding this layer" is misleading —
   a warm rebuild won't.)
2. **Prebuilt pull image** — `claude-code-image/` pulls `:claude-code`, which **bakes** Claude; re-pulling
   gives the same version.
3. **CI gap** — `.github/workflows/docker-publish.yml` builds only the runtime, never `:claude-code`, so
   that tag is refreshed by hand.

## 3. The base/runtime split is already correct (don't restructure it)

The runtime base ships **no Claude** — `build/Dockerfile` (`FROM mcr…/base:ubuntu-22.04`) says so itself:
*"NOT here (added by .devcontainer/claude-code on top — the L3R-seq pattern): Claude Code CLI, node, …"*.
Claude lives only in the thin `claude-code` layer. So this is purely about **how that layer (and the pull
image) get a fresh Claude** — not a base rebuild.

## 4. Security rationale — scoped vs. blanket sudo (vs. Anthropic's reference)

This is *why* the fix is shaped the way it is. In the yolo model the agent runs
`--dangerously-skip-permissions`, and the **egress firewall is the guardrail**. The container is launched
`--cap-add=NET_ADMIN` so the firewall can be built; `NET_ADMIN` is wielded by **root**. The agent runs
**non-root**, so **`sudo` is its only bridge to root → `NET_ADMIN` → `iptables -F`.** Therefore *the sudo
scope is the containment boundary:*

| | agent user | sudo the agent gets | can it flush its own firewall? |
|---|---|---|---|
| **Anthropic reference** (`anthropics/claude-code`) | `node` (`FROM node:20`) | **scoped** — only `init-firewall.sh` | **No** |
| **this repo** | `vscode` | **scoped** — firewall + `/opt` helper (blanket `rm`'d, `Dockerfile:55`) | **No** |
| **L3R-seq** | `vscode` | **blanket** `NOPASSWD:ALL` (inherited from the base, never removed) | **Yes** |

- **Blanket** sudo ⇒ the agent runs `sudo iptables -F` (or `sudo bash`) and the firewall is gone — the
  guardrail is voluntary. **Do not go here.**
- **Scoped** sudo ⇒ the agent can run *only* the allowlisted scripts as root; it can't flush the firewall.
  This repo matches Anthropic's reference, and `security/firewall-hardening-rootful` goes a notch further
  (fail-closed `trap … DROP`, resolver-pinned DNS, no blanket SSH).

**The fix adds Claude-refresh as a THIRD scoped grant — never blanket sudo — so containment is preserved.**

*Honest caveat:* even scoped, this is **egress-contained, not airtight** — the workspace is bind-mounted
read-write (agent can edit host files / `.git/hooks` / the firewall source / write the token to disk) and
the allowlist includes GitHub (a porous exfil surface). Pair it with a Claude-Code command policy. This is
exactly the "safe" → "egress-contained" reframing the security branch makes.

## 5. The fix (Option A) — what's staged

Keep the baked Claude as an **offline fallback**; add a **best-effort root refresh** that runs at
container-create (pre-firewall window) and on demand. Because `registry.npmjs.org` is in the firewall
allowlist (`init-firewall.sh:74`), the on-demand path also works once the firewall is up.

**5.1 `.devcontainer/claude-code/install-claude.sh`** (new; root-owned in the image; pins **both** the
default and the `@anthropic-ai`-scoped registry; runs from a root-owned cwd so a planted `./.npmrc` can't
redirect it; `sudo`'s `env_reset` strips the caller's `NPM_CONFIG_*`):

```bash
#!/bin/bash
set -uo pipefail
cd /usr/local/lib 2>/dev/null || cd /          # root-owned cwd: ignore any agent-writable ./.npmrc
NPM="$(command -v npm || echo /usr/bin/npm)"
CLAUDE="$(command -v claude || echo /usr/bin/claude)"
# Pin BOTH the default and the @anthropic-ai-scoped registry: --registry alone does NOT constrain a
# scoped package, so a planted "@anthropic-ai:registry=" could otherwise redirect this scoped install.
if "$NPM" install -g --registry=https://registry.npmjs.org/ \
        --@anthropic-ai:registry=https://registry.npmjs.org/ @anthropic-ai/claude-code@latest; then
    if v="$("$CLAUDE" --version 2>/dev/null)"; then echo "install-claude: refreshed to $v"
    else echo "install-claude: npm install succeeded but 'claude --version' failed" >&2; fi
else
    echo "install-claude: refresh failed (offline?); keeping the baked $("$CLAUDE" --version 2>/dev/null || echo '?')" >&2
fi
exit 0                                          # never fail container creation
```

**5.2 `.devcontainer/claude-code/Dockerfile`** — keep the baked `npm i -g …@latest` (fallback); add, just
after it, a COPY + the third **scoped** grant (do **not** touch the `rm -f /etc/sudoers.d/vscode` lockdown):

```dockerfile
COPY .devcontainer/claude-code/install-claude.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/install-claude.sh \
    && echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/install-claude.sh" > /etc/sudoers.d/vscode-claude-refresh \
    && chmod 0440 /etc/sudoers.d/vscode-claude-refresh
```

**5.3 both `devcontainer.json`** (`claude-code/` and `claude-code-image/`) — add the parallel postCreate
entry (the prebuilt pull image self-refreshes at create too). The `[ -x ]` guard makes a pulled image that
predates this script skip cleanly instead of failing create:

```jsonc
"postCreateCommand": {
  "livePreview":   "bash /usr/local/bin/install-live-preview.sh",
  "claudeRefresh": "if [ -x /usr/local/bin/install-claude.sh ]; then sudo /usr/local/bin/install-claude.sh; fi"
}
```

**Updating Claude after this lands:** recreate the container (**automatic**), or run
`sudo /usr/local/bin/install-claude.sh` in a running one (**on demand**). No image rebuild either way.

## 6. Alternatives (rejected for this goal)

- **B — match L3R-seq (vscode-writable npm prefix).** Simplest live-update, but it makes Claude
  agent-writable *and*, taken literally, restores L3R-seq's **blanket sudo** — a double step down from this
  repo's posture and out of line with Anthropic's reference. Rejected.
- **C — keep baked + cache-bust ARG.** Most conservative (no runtime root-npm trigger at all), but every
  update needs a `--no-cache` rebuild — gives up the no-rebuild convenience. Keep as the stricter fallback
  if you decide the agent must not be able to *trigger* even an official, registry-pinned root install.
  ```dockerfile
  ARG CLAUDE_CODE_VERSION=latest
  ARG CLAUDE_REFRESH=0    # docker build --build-arg CLAUDE_REFRESH=$(date +%s) … / VS Code "Rebuild Without Cache"
  RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}
  ```

## 7. Security invariants — must NOT regress

- Keep `remoteUser` non-root; keep blanket sudo removed (`rm -f /etc/sudoers.d/vscode`); add **only** the
  scoped `install-claude.sh` grant.
- Don't give `vscode` a writable npm prefix; don't grant the agent `NET_ADMIN`; don't bind `docker.sock`.
- Keep the firewall fail-closed trap + `claude-guarded.sh` launch gate from the security branch.
- `install-claude.sh` must stay root-owned (agent can't edit it), registry-pinned, and run from a
  root-owned cwd.

## 8. Host validation checklist

Build context = repo root (`"context": "../.."`). **Validated 2026-06-25 on the host (Docker 29.6.0, warm
cache) via `docker run` probes against a freshly built `:claude-code`; results inline. The in-devcontainer
firewall + `claude -p` pass is still pending a host token.**
- [x] `claude --version` == `npm view @anthropic-ai/claude-code version` — both `2.1.191`.
- [x] **No-rebuild refresh:** `sudo /usr/local/bin/install-claude.sh` (or a container recreate) advances the
      version with no image rebuild — a `2.1.187`-pinned image refreshed to **`2.1.191` in ~1s**.
- [x] Immutability: as `vscode`, `npm i -g cowsay` **fails** (EACCES) — global prefix is root-owned.
- [x] Scoped sudo only: `sudo -l` lists **install-claude, firewall, fix-opt** — **no** `(root) NOPASSWD: ALL`
      (`/etc/sudoers.d/vscode` absent); `sudo iptables -F` **denied**; all three drop-ins pass `visudo -cf`.
- [x] Registry can't be redirected: a planted `~/.npmrc` **and** cwd `.npmrc` setting bogus `registry=` **and**
      `@anthropic-ai:registry=` did **not** redirect `sudo install-claude.sh` (defended by the CLI `--registry`
      **and** `--@anthropic-ai:registry` pins, the root-owned cwd, and `env_reset` → `HOME=/root`).
- [x] Firewall intact: `/tmp/firewall-status` == `ok`; `example.com` blocked; `api.github.com` **and**
      `registry.npmjs.org` reachable (so the on-demand refresh works post-firewall).
- [x] Offline safety: `--network none` create still succeeds (script exits `0`, Claude present). NOTE: with no
      registry npm retries ~4 min before cache-fallback/graceful-fail — bound with `--fetch-retries=1` if that
      create delay matters (it doesn't on a networked host: postCreate runs pre-firewall).
- [ ] `claude -p "say pong"` works with the host token — **not run** (no `CLAUDE_CODE_OAUTH_TOKEN`/
      `ANTHROPIC_API_KEY` in the host env); run inside the real sandbox with a long-lived `setup-token`.
- [ ] **Pull config (manual republish):** `docker build … :claude-code && docker push`, then **re-pull** and
      confirm the `claude-code-image` config's `claudeRefresh` **runs** (not the `[ -x ]` skip). CI never
      builds `:claude-code`.

## 9. Coordinate with the security branch

`security/firewall-hardening-rootful` edits the same Dockerfile region (adds a `claude-guarded.sh` COPY +
a `~/.bashrc` `claude` alias). **Merge it first**, then this layers cleanly — the new COPY + sudoers sit
just after the baked Claude install, away from the branch's insertions. `install-claude.sh` calls `npm`
and the real `claude` binary, so the branch's `claude` → `claude-guarded.sh` alias doesn't affect it
(shell aliases don't apply in non-interactive scripts).
