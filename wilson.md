# Infrastructure brief: zt-network-automation-workshop (nested KVM / vEOS failure)

Audience: platform, virtualization, or image owners (e.g. “Wilson”) who need to understand **what this lab runs on** and **why Arista vEOS sometimes dies with MSR / QEMU errors** under nested KVM.

## Captured logs (2026-05-14 incident)

These files are **verbatim** (or full-line reconstruction of the repeating monitor retries) from one failing lab so you can search or attach without re-scrolling chat:

* link:wilson/docker-logs-clab-routers-rtr2.txt[`wilson/docker-logs-clab-routers-rtr2.txt`] — full `docker logs clab-routers-rtr2` including **`qemu cmd:`**, **MSR / kvm_buf_set_msrs** STDERR, all **60** monitor retry lines, and **`QemuBroken`** traceback.
* link:wilson/containerlab-inspect.txt[`wilson/containerlab-inspect.txt`] — `sudo containerlab inspect` after failure (**Arista `exited`**, Cisco/Juniper still **running**).
* link:wilson/host-kvm-sanity.txt[`wilson/host-kvm-sanity.txt`] — `uname -r` and `ls -la /dev/kvm` on the containerlab VM.

---

## 1. What stack this workshop runs on

This repository defines **workshop content**, **Ansible lab-automation**, and **first-boot setup scripts**. The **runtime environment** is provisioned by **Red Hat Demo Platform (RHDP)** (or a compatible deployer) using **KubeVirt-style virtual machines** on **OpenShift** (or equivalent Kubernetes + VM operator). Exact cluster branding may vary; the layering below is what matters for KVM.

From `config/instances.yaml` in this repo, a typical deployment includes **three isolated VMs**:

| VM | Image (example from repo) | Role |
|----|---------------------------|------|
| **containerlab** | `ansiblebu-containerlab-v2` | Docker (or Podman) + **Containerlab**; hosts the multi-vendor router topology (Cisco C8000v, Arista vEOS, Juniper vSRX) as **containers** whose internals run **QEMU/KVM** again (vrnetlab pattern). |
| **control** | `aap-2.6-2-ceh-*` | **Ansible Automation Platform** (controller + embedded automation); job templates SSH to routers via published ports or routed paths. |
| **vscode** | `rhel-9.6` | **code-server**; students use `ansible-navigator` and SSH helpers to hit routers through the **containerlab** VM’s **LoadBalancer** ports (e.g. 2222–2226). |

The **containerlab** VM also exposes a **LoadBalancer** service (`containerlab-fip`) mapping **external TCP ports** (2222, 2223, …) to the same ports on the VM, where Containerlab publishes **per-router SSH** (see topology `routers.clab.yml` on the lab image under e.g. `/home/lab-user/1_multi_vendor_router`).

**First-boot automation:** `setup-automation/main.yml` copies per-VM shell scripts (`setup-containerlab.sh`, `setup-control.sh`, `setup-vscode.sh`) from the deployer’s checkout onto each VM and runs them as root. The containerlab script installs the **`containerlab-resume`** systemd unit so after **pause/resume or reboot**, the last topology directory is **destroyed then redeployed** (see `setup-automation/setup-containerlab.sh`).

---

## 2. Nested virtualization: the layer cake

For a single **Arista vEOS** node (`clab-routers-rtr2`), the execution stack is approximately:

```text
[L0] Physical host CPU + hypervisor (e.g. Linux KVM on bare metal, or hypervisor under OpenShift)
       │
[L1] KubeVirt VirtualMachine (the “containerlab” RHEL guest) — guest sees vCPUs, /dev/kvm
       │     kernel: e.g. 5.14.x el9 (RHEL 9)
       │
[L2] Docker (or Podman) on L1 — runs the vrnetlab “router” container
       │
[L3] qemu-system-x86_64 inside the container — emulates vEOS with -enable-kvm
```

So **nested KVM** means: **QEMU in the container (L3)** uses **KVM acceleration** by talking to **`/dev/kvm` on L1**. That device is backed by the **L1 hypervisor’s** support for **nested** virtualization: the L1 guest is itself a VM, so its KVM is “nested.”

**Cisco C8000v and Juniper vSRX** in the same topology use **different QEMU command lines** (CPU model, features) than **Arista vEOS**. That is why you can see **rtr1 / rtr3 running** while **rtr2 / rtr4 exit** when only the vEOS path hits the bug.

---

## 3. What is actually failing (observed behavior)

### Symptoms

- `ssh` / `nc` to Arista management **connection refused** (no listener — VM never came up).
- `docker logs clab-routers-rtr2` (and rtr4) shows **QEMU STDERR** then a long loop of **“Unable to connect to qemu monitor (port 4000)”** and finally **`vrnetlab.QemuBroken`**.
- `containerlab inspect`: **Arista** nodes **`exited`**, **N/A** IPv4; Cisco/Juniper may still show **running** (possibly **unhealthy** until boot completes).

### Root cause (technical)

The **vEOS vrnetlab** image (`registry.gitlab.com/redhatautomation/veos-ee:4.32.0F` in current topologies) launches QEMU roughly like:

```text
qemu-system-x86_64 -enable-kvm ... -cpu host,level=9 -smp 2,sockets=1,cores=1 ...
```

**`-cpu host`** tells QEMU to expose **the host’s CPU model and feature bits** to the inner guest (the vEOS VM). **`-cpu host,level=9`** further tunes **x86 feature level** for the guest ABI.

When this runs **inside L1** (the containerlab VM), **KVM in the inner QEMU** must program **Model-Specific Registers (MSRs)** through the **nested** path: inner KVM → L1 kernel → L0 (or L1 hypervisor). If **L0 does not expose or correctly virtualize** a particular MSR for nested guests, **KVM ioctl fails** and QEMU aborts **before** the monitor socket is usable.

**Concrete error from logs:**

```text
qemu-system-x86_64: error: failed to set MSR 0x345 to 0x2000
qemu-system-x86_64: ... kvm_buf_set_msrs: Assertion `ret == cpu->kvm_msr_buf->nmsrs' failed.
```

So: **not** a Containerlab wiring bug, **not** “wrong SSH password,” **not** fixed by `containerlab destroy` + `deploy` if the **same** QEMU line and **same** nested host remain.

The flood of **“Unable to connect to qemu monitor”** is **downstream**: vrnetlab polls the QEMU monitor on **tcp/4000**, but **QEMU already exited**, so the monitor never comes up.

### Evidence that L1 “has KVM”

On the containerlab VM, **`/dev/kvm`** exists and is typically mode `666` — so **L1 believes KVM is available**. That is **necessary** but **not sufficient** for every **L3** `-cpu host` MSR to succeed under nesting.

---

## 4. What fixes it (ownership)

| Owner | Action |
|-------|--------|
| **Image / vrnetlab maintainers** (Arista `veos-ee` container) | Ship a QEMU CPU model **safe for nested KVM** (avoid `-cpu host,level=9` on nested clusters), or document a **supported env var** to select CPU model when `KVM_NESTED` or similar is detected. |
| **Platform / OpenShift Virtualization** | Adjust **VM CPU mode** (e.g. reduce passthrough aggressiveness), enable/fix **nested virt** for the worker pool, or **pin** this workload to nodes where nested MSR behavior is known-good. |
| **Workshop / lab automation** | Cannot patch QEMU inside the published **veos-ee** image from this repo alone; can only **escalate** with logs and **inspect** output. |

---

## 5. Escalation packet (attach to ticket)

1. Full **`docker logs clab-routers-rtr2`** from the **start** (include **`qemu cmd:`** and **MSR** lines, not only monitor retries) — see link:wilson/docker-logs-clab-routers-rtr2.txt[`wilson/docker-logs-clab-routers-rtr2.txt`].
2. **`sudo containerlab inspect`** from topology dir (shows **exited** for both Arista nodes) — link:wilson/containerlab-inspect.txt[`wilson/containerlab-inspect.txt`].
3. **`uname -r`** and **`ls -la /dev/kvm`** from the **containerlab** VM — link:wilson/host-kvm-sanity.txt[`wilson/host-kvm-sanity.txt`].
4. One-line summary: **Nested KVM: vEOS QEMU uses `-cpu host,level=9` + KVM; MSR 0x345 set fails; QEMU exits; need image CPU model or hypervisor nested-virt fix.**

---

## 6. Related files in this repository

- `config/instances.yaml` — VM definitions, LB ports, disk/memory hints.
- `setup-automation/setup-containerlab.sh` — `containerlab-resume` (**destroy** then **deploy --reconfigure** on boot).
- `lab-automation/playbooks/1_multi_vendor_router_up.yml` / `1_multi_vendor_router_down.yml` — topology deploy/destroy from Ansible.
- `README-containerlab.md` — operator-facing notes including a **QEMU / MSR** troubleshooting subsection.
- `wilson/` — captured **log attachments** linked from `wilson.md` (same incident).

This file (`wilson.md`) is narrative documentation only; it is not executed by any automation.
