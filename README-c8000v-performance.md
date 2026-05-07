# Cisco C8000v Boot Performance Issue

## Problem

The Cisco C8000v (IOS-XE 17.13.01a) virtual router takes **25-30 minutes** to fully boot in the containerlab topology, compared to **2-3 minutes** for Arista vEOS and Juniper vSRX on the same host. During boot, the router's SSH port is open but rejects all authentication, causing Ansible playbooks and manual SSH attempts to fail with:

```
ssh connection failed: Failed to authenticate public key: Access denied for 'publickey'.
Authentication that can continue: publickey,keyboard-interactive,password
```

This affects both AAP job templates and student CLI exercises from the VS Code terminal.

## Root Cause

The vrnetlab container image launches QEMU with **`-smp 1`** (single vCPU). The C8000v boot process is extremely CPU-intensive — it generates crypto keys, starts NETCONF/RESTCONF/IOX services, and applies the startup config via serial console. Each operation queues behind the others on a single core.

## Evidence (collected 2026-05-07)

**Host specs:** 12 vCPUs, AMD EPYC 7642 48-Core, 32 GB RAM

**Container resource usage during boot:**

| Container | CPU % | Memory |
|-----------|-------|--------|
| clab-routers-rtr1 (C8000v) | **101.75%** | 4.0 GiB |
| clab-routers-rtr3 (vSRX) | 110.09% | 4.0 GiB |
| clab-routers-rtr2 (vEOS) | 14.33% | 2.0 GiB |
| clab-routers-rtr4 (vEOS) | 15.53% | 2.0 GiB |

**IOS-XE internal load reports** (from `docker logs clab-routers-rtr1`):

```
%PLATFORM-4-ELEMENT_WARNING: RP/0: 5-Minute Load Average value 8.52 exceeds warning level 8.00
%PLATFORM-3-ELEMENT_CRITICAL: RP/0: 5-Minute Load Average value 12.04 exceeds critical level 12.00
```

A load average of 12 on a 1-vCPU VM means 12 processes are waiting for CPU at any given time.

**Config application timing via vrnetlab serial console:**

Individual IOS CLI commands that normally complete in under 1 second were taking **5+ minutes** each:

```
14:04:50 → ip ssh server algorithm mac hmac-sha2-512
14:09:16 → response received                          (4 min 26 sec)

14:09:16 → ip ssh maxstartups 128
14:14:23 → response received                          (5 min 7 sec)
```

The full startup config application took over 20 minutes.

**Host load during this time was only 2.90** — the 12 host CPUs are not saturated. The bottleneck is entirely the single QEMU vCPU.

## Recommendation

**Rebuild the C8000v vrnetlab image with `-smp 2` (or `-smp 4`).** The host has 12 cores with plenty of headroom. Giving the C8000v 2 vCPUs should roughly halve boot time; 4 vCPUs would bring it closer to the 5-8 minute range.

The change is in the vrnetlab `launch.py` (or equivalent QEMU launch script) inside the container image `registry.gitlab.com/redhatautomation/cat8:17.13.01a`. Look for the `-smp 1` flag in the QEMU command line:

```
qemu-system-x86_64 -enable-kvm ... -smp 1 -m 4096 ...
```

Change to:

```
qemu-system-x86_64 -enable-kvm ... -smp 2 -m 4096 ...
```

### Alternative / complementary mitigations

1. **Increase the topology deploy wait time.** The `1_multi_vendor_router_up.yml` playbook waits 120 seconds after `containerlab deploy`. With the current single-vCPU image, this should be **600 seconds** (10 minutes) minimum. This doesn't fix the root cause but prevents students from hitting half-booted routers.

2. **Simplify the startup config.** The C8000v config enables IOX, RESTCONF, NETCONF, crypto key generation, BGP, OSPF, and GRE tunnels. Each service adds boot time. If RESTCONF and IOX aren't needed for the workshop exercises, removing them from the startup config would reduce boot time.

3. **Pre-boot the topology before students access the lab.** Deploy the containerlab topology as part of the provisioning pipeline (e.g., in `setup-containerlab.sh`) rather than as a separate AAP job, and add a health-check gate that waits for all nodes to reach `(healthy)` before marking the lab as ready.

## How to Verify the Fix

After rebuilding the image, deploy the topology and time the boot:

```bash
cd /home/lab-user/1_multi_vendor_router
sudo containerlab deploy --reconfigure

# Poll until healthy (should be under 10 min with -smp 2)
while true; do
  status=$(sudo containerlab inspect 2>/dev/null | grep rtr1 | grep -o '(healthy)')
  if [[ -n "$status" ]]; then
    echo "rtr1 is healthy"
    break
  fi
  echo "Waiting for rtr1..."
  sleep 30
done

# Verify SSH works
sshpass -p 'admin@123' ssh -o StrictHostKeyChecking=no admin@172.20.20.10 "show version"
```
