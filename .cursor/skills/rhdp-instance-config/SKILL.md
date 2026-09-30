---
name: rhdp-instance-config
description: >-
  Guard rails for editing config/instances.yaml and related RHDP/agnosticD lab
  VM definitions. Use when modifying instances.yaml, userdata blocks, AnsibleGroup
  tags, ui-config.yml tabs, or setup-automation scripts. Prevents known boot-hang
  and deployment pitfalls.
---

# RHDP Instance Configuration Guide

This lab runs on the Red Hat Demo Platform (RHDP) via the agnosticD deployer.
The deployer reads `config/instances.yaml` to provision VMs and applies
automation based on each VM's `AnsibleGroup` tag. Several non-obvious
interactions between these settings have caused multi-hour debugging sessions.

## Critical Rules

### 1. AnsibleGroup Must Be "isolated" for All VMs

```yaml
tags:
  - key: AnsibleGroup
    value: isolated    # CORRECT — agnosticD leaves this VM alone
```

**Never use `bastions`** unless the VM genuinely needs agnosticD-managed SSH
key distribution and password setup. When a VM is tagged `bastions`:

- The deployer SSHs into it during provisioning to push keys and reset passwords.
- If credentials don't match what the deployer expects, it hangs/retries for
  minutes, causing massive boot delays (~20 min+).
- The deployer only supports **one** bastion host. Tagging multiple VMs as
  `bastions` will cause failures.

Our lab handles its own SSH and password setup via cloud-init `userdata`, so
every VM should be `isolated`.

### 2. Userdata Scalar Must Be `|-` (Literal Block), Never `>-` (Folded)

```yaml
# CORRECT — preserves newlines, cloud-init can parse each directive
userdata: |-
  #cloud-config
  user: rhel
  password: ansible123!
  chpasswd: { expire: False }
  runcmd:
    - echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/50-cloud-init.conf
    - systemctl reload sshd
```

```yaml
# WRONG — folds all lines into one, cloud-init receives garbage
userdata: >-
  #cloud-config
  user: rhel
  ...
```

In YAML:
- `|-` = literal block scalar, preserves newlines (what cloud-init needs)
- `>-` = folding scalar, joins lines with spaces (breaks cloud-init entirely)

When `>-` is used, passwords never get set, SSH password auth is never enabled,
and any automation that tries to SSH with a password will fail silently.

### 3. Every VM Needs Its Own Userdata Block

Don't assume the deployer handles password/SSH setup — it won't for `isolated`
nodes. Each VM definition in `instances.yaml` must include the full `userdata`
block with cloud-config for user, password, chpasswd, and the sshd runcmd.

### 4. UI Config Terminal Routing

In `ui-config.yml`, terminal tabs use two different keys:

- `type:` accepts only predefined values like `terminal` (chart default route)
- `url:` accepts explicit paths like `/wetty_control`

**Never put a path in `type:`** — it causes "Port and url not defined" errors.

```yaml
# CORRECT — explicit WeTTY path goes in url:
- name: AAP terminal
  url: /wetty_control

# WRONG — type: only accepts predefined values, not paths
- name: AAP terminal
  type: /wetty_control

# RISKY — "terminal" resolves to whatever the chart default is (often containerlab)
- name: AAP terminal
  type: terminal
```

Use explicit `url: /wetty_<vmname>` for every terminal tab. Only use
`type: terminal` if you're certain the chart default route points where you want.

### 5. VSCode Service Naming

The vscode VM service and route names must be consistent simple names (not
suffixed with port numbers):

```yaml
services:
  - name: vscode          # not "vscode-8080"
routes:
  - name: vscode          # must match the service name
    service: vscode
```

## Checklist When Editing instances.yaml

- [ ] All VMs have `value: isolated` (not `bastions`)
- [ ] All `userdata:` fields use `|-` scalar (not `>-`)
- [ ] Every VM has a complete `userdata` cloud-config block
- [ ] Service names and route names are consistent
- [ ] `networks:` block is present on each VM that needs network access
- [ ] VSCode image is `rhel-9.6` (not `devtools-ansible` — code-server is
      installed by `setup-vscode.sh` at runtime)

## Architecture Quick Reference

| VM | Purpose | Image | AnsibleGroup |
|----|---------|-------|--------------|
| containerlab | Network topology (clab + routers) | ansiblebu-containerlab-v2 | isolated |
| control | AAP controller + lab automation | aap-2.6-2-ceh-* | isolated |
| vscode | Browser IDE (code-server) | rhel-9.6 | isolated |

Setup scripts in `setup-automation/` run as cloud-init runcmd or are triggered
by the deployer for the respective VM. They handle everything (package install,
code-server setup, EE pulls, repo cloning) because all VMs are `isolated`.
