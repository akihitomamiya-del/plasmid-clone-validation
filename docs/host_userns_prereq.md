# Host prerequisite: enable rootless Apptainer (load one AppArmor profile — no global change)

**Audience:** whoever has `sudo`/admin on this workstation (hostname `validation-host`).
**Time:** ~1 minute, no reboot. **Reversible:** instantly. **Host-wide security posture:** unchanged.

The `plasmid-clone-validation` firewalled devcontainer runs Claude Code as a **non-root** user and
runs the EPI2ME `wf-clone-validation` workflow via **rootless Apptainer**. To set up a container,
rootless Apptainer must create an **unprivileged user namespace** *and* perform **mounts**. On this
host (Ubuntu, kernel 6.17) two things stand in the way — and the fix is a single **opt-in AppArmor
profile**, *not* a host-wide setting change.

---

## TL;DR — the command to run

```bash
# From a clone of this repo, as a sudoer, once:
sudo bash .devcontainer/setup-host-apparmor.sh
```

That installs the `pcv-apptainer` AppArmor profile into `/etc/apparmor.d/` (auto-loaded on every
boot) and loads it now. The devcontainer already opts into it via
`--security-opt apparmor=pcv-apptainer`. **The global
`kernel.apparmor_restrict_unprivileged_userns` sysctl is left at `1` (hardened).**

Verify:
```bash
sudo aa-status | grep pcv-apptainer                  # -> pcv-apptainer   (loaded, enforce)
sysctl kernel.apparmor_restrict_unprivileged_userns  # -> still = 1 (unchanged)
```

Revert:
```bash
sudo apparmor_parser -R /etc/apparmor.d/pcv-apptainer && sudo rm -f /etc/apparmor.d/pcv-apptainer
```

---

## What actually blocks it (two gates)

Measured on this host (sysctl `= 1`), running rootless `apptainer exec` of a workflow SIF as the
non-root `vscode` user, offline:

| Container AppArmor | userns creation | mount | Result |
|---|---|---|---|
| `docker-default` (stock) | ✅ allowed (confined + userns) | ❌ **denied** | fails: *"Failed to set mount propagation: Permission denied"* |
| `unconfined` (incl. `--privileged`) | ❌ **denied** at sysctl=1 | ✅ allowed | fails: *"Could not write info to setgroups: Permission denied"* |
| **`pcv-apptainer` (this profile)** | ✅ allowed | ✅ allowed | ✅ **works** |

There are **two** gates, guarded by different mechanisms:

1. **The userns gate** — `apparmor_restrict_unprivileged_userns=1` blocks unprivileged user-namespace
   creation for **unconfined** processes, but **allows** it for a process confined by a *named*
   AppArmor profile carrying the `userns,` permission.
2. **The mount gate** — Docker's stock `docker-default` profile **denies the `mount`** Apptainer
   needs (pivot_root + bind mounts + the squashfuse mount of the SIF).

You cannot open both with the coarse settings: `docker-default` shuts gate 2; `unconfined` (or
`--privileged`) shuts gate 1. The `pcv-apptainer` profile is the one config that opens **both** — it
stays *confined* (gate 1 ✅) **and** permits `mount` (gate 2 ✅).

> This **corrects an earlier diagnosis** ("the workflow can't run until you set the userns sysctl to
> 0"). The sysctl is only one of two gates, and with this profile you don't touch it at all. The old
> `apparmor=unconfined` + `sysctl=0` recipe does work — but only while the sysctl is 0, which reverts
> on reboot and which the no-sudo user (`user`) cannot set.

---

## Why the AppArmor profile is the right lever (vs. the global sysctl)

| | **AppArmor profile** (recommended) | **Global `sysctl=0`** (alternative, below) |
|---|---|---|
| Scope | **opt-in per container** (`--security-opt apparmor=pcv-apptainer`) | **host-wide**, every user & process |
| Host-wide userns hardening | **stays ON** | **turned OFF** for everyone (incl. the sequencing user) |
| Persists across reboot | ✅ auto-loaded from `/etc/apparmor.d/` | only if you add a sysctl drop-in |
| Usable by no-sudo `user` | ✅ after the one-time admin load | needs the global change |
| Revert | unload + delete one file | remove drop-in + reset sysctl |

The profile is **strictly less invasive**: it grants the userns+mount permission **only** to
containers that explicitly request it, leaving the kernel's userns restriction in force for
everything else on this shared box.

**On the profile's breadth.** `pcv-apptainer` is intentionally broad on *AppArmor* mediation (it
permits `mount`, `capability`, `network`, `file`, …). That is acceptable because the real controls on
this container are elsewhere: the **egress firewall** (the workflow shares the container netns, so the
`OUTPUT` allowlist governs it), Docker's **default capability drop** (no `CAP_SYS_ADMIN`; no
`--privileged`), the **non-root** user, and **userns** isolation. AppArmor's role here is narrowly to
satisfy the userns gate without blocking Apptainer's mounts. Tightening toward a
`docker-default`-plus-`userns`/`mount` profile is possible future hardening (noted in
`.devcontainer/pcv-apptainer.aaprofile`).

---

## Validation

On `validation-host` (Docker 29.6, kernel 6.17.0-35, `apparmor_restrict_unprivileged_userns=1`),
with the profile loaded, the **full offline canu pipeline** runs as non-root `vscode` and reproduces
the reference exactly — **1 contig, 5,652 bp, "Completed successfully"** — and the sysctl never left
`1`. The same `apptainer` calls fail with `docker-default` (mount gate) and with
`unconfined`/`--privileged` (userns gate), per the table above.

Note: besides this host profile, the devcontainer also passes `--security-opt systempaths=unconfined`
so the workflow's *nested* Apptainer can mount `/proc` — a container runArg, not a host change
(see `archive/setup_and_plan.md` §5).

---

## Alternative (not recommended on a shared box): relax the global sysctl

If you would rather not load a profile, the historical approach works but **weakens userns hardening
host-wide**:

```bash
sudo tee /etc/sysctl.d/99-apptainer-userns.conf >/dev/null <<'EOF'
kernel.apparmor_restrict_unprivileged_userns = 0
EOF
sudo sysctl --system
```
Then set the devcontainer runArg back to `--security-opt apparmor=unconfined`. Revert with
`sudo rm /etc/sysctl.d/99-apptainer-userns.conf && sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=1`.

**Trade-off:** `0` is the historical Linux default (still default on Debian/Fedora/RHEL/Arch), but it
removes one local-privilege-escalation defense for **all** users on this machine — including the
sequencing user. It opens no network/remote exposure. On a shared lab box, prefer the scoped profile.

---

## If you'd rather not change the host at all

Run the firewalled devcontainer purely as the Claude sandbox and run the assembly on the host's
existing Docker (`PROFILE=standard ./clone_validate.sh …`, see `docs/archive/setup_and_plan.md` Appendix A),
or run Apptainer directly on the host. Both avoid the nested rootless-Apptainer requirement entirely.
