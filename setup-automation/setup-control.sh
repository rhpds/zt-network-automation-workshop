#!/bin/bash
USER=rhel
EE_IMAGE="registry.redhat.io/ansible-automation-platform-26/ee-supported-rhel9:latest"

echo "Adding wheel" > /root/post-run.log
usermod -aG wheel rhel

echo "Setup vm control" > /tmp/progress.log
chmod 666 /tmp/progress.log

# ---------------------------------------------------------------------------
# 1. Log in to registry.redhat.io and pull the EE image.
# ---------------------------------------------------------------------------
registry_login() {
  if [[ -n "${REG_USER:-}" && -n "${REG_PASS:-}" ]]; then
    echo "Logging in to registry.redhat.io as ${REG_USER} (root + rhel)..." >> /tmp/progress.log
    podman login registry.redhat.io -u "$REG_USER" -p "$REG_PASS" >> /tmp/progress.log 2>&1 || true
    sudo -u rhel -H podman login registry.redhat.io -u "$REG_USER" -p "$REG_PASS" >> /tmp/progress.log 2>&1
    if [[ $? -eq 0 ]]; then
      echo "Registry login successful" >> /tmp/progress.log
      return 0
    else
      echo "Registry login failed" >> /tmp/progress.log
      return 1
    fi
  else
    echo "REG_USER/REG_PASS not set; skipping registry login" >> /tmp/progress.log
    return 0
  fi
}

pull_ee() {
  if podman images --format '{{.Repository}}:{{.Tag}}' | grep -q "${EE_IMAGE}"; then
    echo "EE image ${EE_IMAGE} already present" >> /tmp/progress.log
    return 0
  fi

  echo "Pulling EE image ${EE_IMAGE}..." >> /tmp/progress.log
  if podman pull "${EE_IMAGE}" >> /tmp/progress.log 2>&1; then
    echo "EE image pulled successfully" >> /tmp/progress.log
    return 0
  fi

  echo "ERROR: Could not pull EE image" >> /tmp/progress.log
  return 1
}

# ---------------------------------------------------------------------------
# 2. Wait for the workshop repo to appear (showroom clones it asynchronously).
# ---------------------------------------------------------------------------
find_lab_automation() {
  local max_attempts=30
  local delay=10
  for (( i=1; i<=max_attempts; i++ )); do
    for d in "/opt/workshop" "/home/rhel/zt-network-automation-workshop" "/home/rhel/workshop" "${WORKSHOP_REPO_ROOT:-}"; do
      [[ -z "$d" ]] && continue
      if [[ -f "$d/lab-automation/playbooks/site.yml" ]]; then
        echo "$d/lab-automation"
        return 0
      fi
    done
    echo "Waiting for workshop repo (attempt ${i}/${max_attempts})..." >> /tmp/progress.log
    sleep "${delay}"
  done
  return 1
}

# ---------------------------------------------------------------------------
# 3. Run lab-automation playbooks inside the EE via podman.
# ---------------------------------------------------------------------------
run_lab_automation() {
  local la_dir
  la_dir=$(find_lab_automation)
  if [[ -z "$la_dir" ]]; then
    echo "lab-automation/playbooks/site.yml not found after waiting; skipping" >> /tmp/progress.log
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

registry_login || true
pull_ee || true
run_lab_automation || true
