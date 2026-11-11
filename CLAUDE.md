# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

This repository hosts Ansible automation to provision a Debian 12 (bookworm) VM on an ESXi host (not local containers/WSL — local host memory is insufficient for that) via a fully unattended (preseed) install, and configure it, including generating and distributing an SSH key. Networking is DHCP. First target VM: `debian-vm`, sudo user `charlie`, no password on that account at all (locked, SSH-key-only, passwordless sudo) — there's no console/rescue path by design, since SSH access exists from first boot.

The `community.vmware` module parameter names and return-field shapes used in `playbooks/build-debian-vm.yml` (especially `vmware_guest_boot_manager`, `vsphere_copy`'s datastore path format, and `vmware_guest_info`'s IP field) were written from general knowledge, not verified against a live collection or ESXi host — there's neither `ansible-playbook` nor ESXi access in the dev sandbox. Run `ansible-doc community.vmware.<module>` against the installed collection version before trusting this end-to-end, and expect to need adjustments. The ISO-remastering `sed` patterns in `scripts/remaster-iso.sh` are similarly unverified against a real netinst ISO.

## Commands

- `task --list` — list available tasks
- `task install` — install local tooling; runs `install:default` from the included `install` namespace, which calls `install:ansible` (ansible-core + collections from `requirements.yml`) and `install:iso-tools` (`xorriso`)
- `task select-iso` — interactively pick an ISO registered in `iso/manifest.json` (via `gum choose`), prints the resolved path; fails if the file isn't actually present under `iso/`
- `task build-debian-vm` — sources `.env`, runs `select-iso`, then runs `ansible-playbook playbooks/build-debian-vm.yml` with the chosen ISO

## Architecture

- `Taskfile.yaml` — root task definitions; includes namespaced task files from `scripts/tasks/` (e.g. `scripts/tasks/install.yaml` as the `install` namespace). Add new task groups the same way rather than growing the root file.
- `iso/` — holds ISO files used to provision VMs. The ISOs themselves are gitignored (too large, and change independently of the repo); only `iso/manifest.json` (a simple `{"<name>": "<filename>"}` map) is tracked. Place the actual ISO files here manually before running tasks that need them. `iso/_generated/` holds the preseed-injected ISO built at playbook runtime — also gitignored.
- `playbooks/build-debian-vm.yml` — the main entry point. Runs entirely against `localhost` (it shells out and calls the ESXi API; it doesn't SSH anywhere until the very last step). Flow: generate an SSH keypair under `keys/` (gitignored) → render `roles/debian_preseed_iso/templates/preseed.cfg.j2` → remaster the selected ISO via `scripts/remaster-iso.sh` → upload it to the ESXi datastore (`community.vmware.vsphere_copy`) → create the VM (`community.vmware.vmware_guest`, `state: present`) → set CD-first boot order (`vmware_guest_boot_manager`) → power on → poll `vmware_guest_info` until an IP shows up → wait for port 22.
- `scripts/remaster-iso.sh` — extracts a Debian netinst ISO, drops in `preseed.cfg`, patches the isolinux (BIOS) and grub (UEFI) boot configs to auto-start the unattended install, repacks with `xorriso`. Needs `sudo mount`.
- VM provisioning target: a standalone ESXi host (no vCenter) — `community.vmware` modules are called with `datacenter: ha-datacenter`, the implicit pseudo-datacenter name for a bare ESXi host.
- Secrets (ESXi hostname/credentials/datastore/network) live in a local `.env` file, gitignored; `.env.example` documents the required keys and is the tracked template. The playbook reads these via `lookup('env', ...)`, so anything invoking `ansible-playbook` must source `.env` first (the `build-debian-vm` task does this).
- SSH key handling: the keypair is generated locally by the playbook (`community.crypto.openssh_keypair`, under `keys/`); only the public key is baked into the preseed `late_command` and ends up on the VM. The private key never leaves the control node and is never committed.

_This section will be expanded as the project's actual purpose and structure are defined._
