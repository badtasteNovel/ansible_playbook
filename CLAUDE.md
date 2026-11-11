# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This repository hosts Ansible automation to provision a Debian 13 (trixie) VM on an ESXi host (not local containers/WSL — local host memory is insufficient for that) via a fully unattended (preseed) install, and configure it, including generating and distributing an SSH key. Networking is DHCP. First target VM: `debian-vm`, sudo user `charlie`, no password on that account at all (locked, SSH-key-only, passwordless sudo) — there's no console/rescue path by design, since SSH access exists from first boot.

The `community.vmware` module parameter names and return-field shapes used in `build_vm/debian.yml` (especially `vmware_guest_boot_manager`, `vsphere_copy`'s datastore path format, and `vmware_guest_info`'s IP field) were written from general knowledge, not verified against a live collection or ESXi host — there's neither `ansible-playbook` nor ESXi access in the dev sandbox. Run `ansible-doc community.vmware.<module>` against the installed collection version before trusting this end-to-end, and expect to need adjustments. The ISO-remastering `sed` patterns in `custom/scripts/remaster-iso/debian.sh` are similarly unverified against a real netinst ISO.

## Directory layout: official Ansible skeleton vs. `custom/`

Ansible's own documented project layout (inventory, `group_vars/`, `host_vars/`, `roles/`, top-level playbooks) only covers things Ansible itself understands — it says nothing about where project-specific tooling belongs, since that's out of Ansible's scope by design. This repo keeps that distinction explicit:

- **Repo root** — the official skeleton, plus files tools require to live at root: `inventory/`, `group_vars/`, `host_vars/` (currently empty, held by `.gitkeep`), `roles/`, `build_vm/` (top-level playbooks, one file per OS/distro — currently just `build_vm/debian.yml`; the sample-setup doc doesn't dictate playbook names any more than it dictates this grouping, so this is our own convention sitting alongside the official pieces, not inside `custom/`), `Taskfile.yaml` (by the user's preference, not an Ansible convention), `.gitignore` and `CLAUDE.md` (must stay at root for git/Claude Code to find them), and `requirements.yml` (not from Ansible's sample-setup doc specifically, but a near-universal `ansible-galaxy` convention — kept at root; revisit if that's wrong).
- **`custom/`** — everything else: ISO handling (`custom/iso/`), build output (`custom/generated/`), the generated SSH keypair (`custom/keys/`), helper scripts (`custom/scripts/`), and the `.env`/`.env.example` pair. None of this is Ansible-recognized; it's purely this project's own convention.

## Commands

- `task --list` — list available tasks
- `task install` — install local tooling; runs `install:default` from the included `install` namespace, which calls `install:ansible` (ansible-core + collections from `requirements.yml`) and `install:iso-tools` (`xorriso`)
- `task select-iso` — interactively pick an ISO registered in `custom/iso/manifest.json` (via `gum choose`), prints the resolved path; fails if the file isn't actually present under `custom/iso/`
- `task build-debian-vm` — sources `custom/.env`, runs `select-iso`, then runs `ansible-playbook build_vm/debian.yml` with the chosen ISO

## Architecture

- `Taskfile.yaml` — root task definitions; includes namespaced task files from `custom/scripts/tasks/` (e.g. `custom/scripts/tasks/install.yaml` as the `install` namespace). Add new task groups the same way rather than growing the root file.
- `custom/iso/` — holds *source* ISO files used to provision VMs. Has its own scoped `.gitignore` (ignore everything except `manifest.json` and itself) rather than relying on the root `.gitignore`. Only `manifest.json` (a simple `{"<name>": "<filename>"}` map) is tracked; place the actual ISO files here manually before running tasks that need them.
- `custom/iso/debian/` — the actual Debian ISO lives here (gitignored), alongside `signature/`:
  - `signature/fingerprint/` — the Debian CD signing keys (`*.asc`, tracked in git — they're public keys, not secrets) plus `fingerprints.txt`, a pinned list of their expected fingerprints. `verify-iso/debian.sh` treats this list as the actual trust anchor: it recomputes each imported key's fingerprint and refuses to use a key whose fingerprint isn't in this file, rather than blindly trusting whatever `*.asc` files happen to be present.
  - `signature/checksum/` — `SHA512SUMS` and `SHA512SUMS.sign`, downloaded from the same official mirror directory as the ISO itself (tracked in git — small text files, useful as an audit trail of what was verified).
- `custom/scripts/verify-iso/debian.sh` — verifies a Debian ISO is an unmodified official release: checks each key in `signature/fingerprint/*.asc` against the pinned `fingerprints.txt`, uses only the ones that pass to `gpgv`-verify `signature/checksum/SHA512SUMS.sign` against `SHA512SUMS`, then `sha512sum -c`s the ISO itself against the matching line. Usage: `debian.sh <path/to/iso>`. Verified end-to-end against the real Debian 13.7.0 netinst ISO and its real official `SHA512SUMS`/`SHA512SUMS.sign` — this one isn't a "hasn't been tested yet" caveat like some of the other scripts in this repo.
- `custom/generated/` — build output (rendered `preseed.cfg`, the preseed-injected ISO) produced by the playbook at runtime. Kept separate from `custom/iso/` (source material) on purpose, and gitignored from the root `.gitignore`.
- `build_vm/debian.yml` — the main entry point, at repo root alongside `roles/`/`inventory/`. Runs entirely against `localhost` (it shells out and calls the ESXi API; it doesn't SSH anywhere until the very last step). Flow: generate an SSH keypair under `custom/keys/` (gitignored) → render `roles/debian_preseed_iso/templates/preseed.cfg.j2` into `custom/generated/` → remaster the selected ISO via `custom/scripts/remaster-iso/debian.sh` into `custom/generated/` → upload it to the ESXi datastore (`community.vmware.vsphere_copy`) → create the VM (`community.vmware.vmware_guest`, `state: present`) → set CD-first boot order (`vmware_guest_boot_manager`) → power on → poll `vmware_guest_info` until an IP shows up → wait for port 22.
- `custom/scripts/remaster-iso/` — per-OS ISO remastering scripts, one file per distro/installer family (currently just `debian.sh`, for the classic Debian Installer/isolinux-grub layout). `debian.sh` extracts a Debian netinst ISO, drops in `preseed.cfg`, patches the isolinux (BIOS) and grub (UEFI) boot configs to auto-start the unattended install, repacks with `xorriso`. Needs `sudo mount`.
- VM provisioning target: a standalone ESXi host (no vCenter) — `community.vmware` modules are called with `datacenter: ha-datacenter`, the implicit pseudo-datacenter name for a bare ESXi host.
- Secrets (ESXi hostname/credentials/datastore/network) live in `custom/.env`, gitignored; `custom/.env.example` documents the required keys and is the tracked template. The playbook reads these via `lookup('env', ...)`, so anything invoking `ansible-playbook` must source `custom/.env` first (the `build-debian-vm` task does this).
- SSH key handling: the keypair is generated locally by the playbook (`community.crypto.openssh_keypair`, under `custom/keys/`); only the public key is baked into the preseed `late_command` and ends up on the VM. The private key never leaves the control node and is never committed.

_This section will be expanded as the project's actual purpose and structure are defined._
