---
name: setup-scripts
description: >-
  Guide for editing setup-automation scripts (setup-vscode.sh,
  setup-containerlab.sh, setup-control.sh) and the workshop content
  structure. Use when modifying setup scripts, debugging VM boot
  issues, changing exercise files, or working with the network-workshop
  directory.
---

# Setup Scripts & Workshop Content Guide

## VM Environment Constraints

### rhel-9.6 (vscode VM)

This is a **bare base image**. It has almost nothing pre-installed:

- **No git** — download repo via GitHub tarball:
  `curl -sL https://github.com/.../archive/refs/heads/main.tar.gz | tar xz -C /tmp`
- **No podman** — requires RHSM registration first, then `dnf install`
- **No dnf repos** — must register with `subscription-manager` using
  `REG_USER`/`REG_PASS` env vars before any `dnf install`
- **No pip** — install via `curl -sL https://bootstrap.pypa.io/get-pip.py | python3`
- **No ansible-navigator** — install via pip as the rhel user with `--user` flag

### ansiblebu-containerlab-v2 (containerlab VM)

- Has containerlab, podman pre-installed
- Has stale `/etc/hosts` entries from image build — always delete and
  rewrite rtr1-4 entries, never trust a grep guard
- **No deployer-managed SSH keys** (all VMs are `isolated`) — must
  generate keys and push via `sshpass`

### aap-2.6-2-ceh (control VM)

- Has AAP, podman pre-installed
- Needs registry login for `registry.redhat.io` EE images
- Waits for SSH key from containerlab before running lab-automation

## Script Execution Order Matters

### setup-vscode.sh

```
1. code-server install + config
2. sudoers + loginctl enable-linger
3. RHSM register → dnf install git, podman, sshpass
4. Download repo tarball
5. Install bundled RPMs (fallback/extras)
6. Copy exercise files to ~rhel/network-workshop
7. Install pip → ansible-navigator
8. PATH setup (~/.local/bin)
9. Pre-pull network EE
10. Router SSH access wrappers
11. chown fix on ~/.config and ~/.local
```

Key ordering rules:
- RHSM + dnf **before** anything that needs podman/git/sshpass
- Bundled RPMs **after** tarball download (they're in the repo)
- `chown -R rhel:rhel ~/.config ~/.local` **at the end** (script runs
  as root and creates dirs that rhel user needs to own)
- `loginctl enable-linger` **before** any podman usage (prevents
  cgroupv2 systemd warnings)

### setup-containerlab.sh

```
1. Clone repo
2. Install bundled RPMs (must be before push_ssh_key — needs sshpass)
3. Generate SSH key + push to control (via sshpass, not sudo -u ssh)
4. Router access (/etc/hosts, SSH config, wrappers, profile.d)
```

Key ordering rules:
- `install_rpms` **before** `push_ssh_key_to_control` (sshpass needed)
- `/etc/hosts` entries: always `sed -i '/rtr[1-4]/d'` then append
  (never use grep guard — stale image entries fool it)
- SSH config needs `Hostname` directives per router (not just `User`)

## Credentials & Environment Variables

| Variable | Used By | Purpose |
|----------|---------|---------|
| `REG_USER` | control (registry), vscode (RHSM) | Red Hat account username |
| `REG_PASS` | control (registry), vscode (RHSM) | Red Hat account password |
| `CONTROLLER_PASSWORD` | control | AAP admin password |
| `GATEWAY_HOSTNAME` | control | AAP gateway URL |
| `GUID` | control, ui-config | Unique lab instance ID |
| `DOMAIN` | control, ui-config | Base domain for routes |

## Workshop Content Structure

### What goes on the vscode server (`~/network-workshop/`)

```
network-workshop/
├── .ansible-navigator.yml    ← navigator config (inventory, EE image)
├── playbook.yml              ← provided for exercise 2 (SNMP config)
├── lab_inventory/hosts       ← inventory with rtr1-4 via containerlab ports
├── 1-explore/                ← exercise READMEs + images
├── 2-first-playbook/         ← exercise READMEs only
├── 3-facts/                  ← READMEs + facts.yml (answer key)
└── 4-resource-module/        ← READMEs + resource/gathered/multivendor.yml
```

Rules:
- Only `playbook.yml` at top level — it's the "provided" playbook for
  exercise 2
- Answer key playbooks stay **inside** their exercise folders only
- `.ansible-navigator.yml` must NOT have `/etc/ansible/` volume mount
  (doesn't exist on rhel-9.6)

### AAP job templates (bootstrapped by lab-automation)

- `Network-Restore` is created **dynamically** by the backup job, NOT
  pre-provisioned. The bootstrap deletes both `"Network-Restore"` and
  `"Network Automation - Restore"` to prevent duplicates.

## Testing Setup Scripts on a Live VM

Run the latest script without redeploying:

```bash
curl -sL https://github.com/rhpds/zt-network-automation-workshop/archive/refs/heads/main.tar.gz | tar xz -C /tmp
sudo bash /tmp/zt-network-automation-workshop-main/setup-automation/setup-vscode.sh
cat /tmp/progress.log
```

The script is idempotent — RPMs skip if installed, pip skips satisfied
deps, code-server detects existing install.

## Debugging Boot Failures

1. Check `/tmp/progress.log` on the failing VM
2. Common failure points:
   - "No private key found" → SSH key gen/push failed (check sshpass)
   - "Could not resolve hostname rtrX" → `/etc/hosts` not written
   - "container engine could not be found: podman" → RHSM not registered
   - "Permission denied: ~/.local" → missing `chown` after root operations
   - "Port and url not defined" → `type:` vs `url:` mistake in ui-config
