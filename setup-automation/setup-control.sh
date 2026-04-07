#!/bin/bash
USER=rhel
EE_IMAGE="registry.redhat.io/ansible-automation-platform-26/ee-supported-rhel9:latest"

echo "Adding wheel" > /root/post-run.log
usermod -aG wheel rhel

echo "Setup vm control" > /tmp/progress.log
chmod 666 /tmp/progress.log

# ---------------------------------------------------------------------------
# 1. Pull the EE image if not already present.
# ---------------------------------------------------------------------------
pull_ee() {
  if podman images --format '{{.Repository}}:{{.Tag}}' | grep -q "${EE_IMAGE}"; then
    echo "EE image ${EE_IMAGE} already present" >> /tmp/progress.log
    return 0
  fi
  echo "Pulling EE image ${EE_IMAGE}..." >> /tmp/progress.log
  podman pull "${EE_IMAGE}" >> /tmp/progress.log 2>&1
}

# ---------------------------------------------------------------------------
# 2. Run lab-automation playbooks inside the EE via podman (no pip/dnf needed).
#    The EE has ansible-playbook + awx.awx + ansible.platform + network collections.
# ---------------------------------------------------------------------------
run_lab_automation() {
  local la_dir=""
  for d in "/home/rhel/zt-network-automation-workshop" "/home/rhel/workshop" "${WORKSHOP_REPO_ROOT:-}"; do
    [[ -z "$d" ]] && continue
    if [[ -f "$d/lab-automation/playbooks/site.yml" ]]; then
      la_dir="$d/lab-automation"
      break
    fi
  done
  if [[ -z "$la_dir" ]]; then
    echo "lab-automation/playbooks/site.yml not found; skipping" >> /tmp/progress.log
    return 0
  fi
  if ! command -v podman &>/dev/null; then
    echo "podman not available; skipping lab-automation" >> /tmp/progress.log
    return 0
  fi

  local rhel_home="/home/rhel"
  echo "Running lab-automation from $la_dir via EE (podman)" >> /tmp/progress.log

  sudo -u rhel -H podman run --rm \
    --network host \
    -v "${la_dir}:/runner/project:Z" \
    -v "${rhel_home}/.ssh:/home/runner/.ssh:Z" \
    -e CONTROLLER_PASSWORD="${CONTROLLER_PASSWORD:-}" \
    -e GATEWAY_HOSTNAME="${GATEWAY_HOSTNAME:-}" \
    -e GATEWAY_USERNAME="${GATEWAY_USERNAME:-}" \
    -e GATEWAY_PASSWORD="${GATEWAY_PASSWORD:-}" \
    "${EE_IMAGE}" \
    ansible-playbook \
      -i /runner/project/inventory/lab.yml \
      /runner/project/playbooks/site.yml \
    >> /tmp/lab-automation-site.log 2>&1 \
  || echo "lab-automation failed; see /tmp/lab-automation-site.log" >> /tmp/progress.log
}

pull_ee || true
run_lab_automation || true

