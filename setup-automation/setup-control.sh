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
# 2. Clone the workshop repo (it is not copied to the VM automatically).
# ---------------------------------------------------------------------------
REPO_URL="https://github.com/rhpds/zt-network-automation-workshop.git"
REPO_DIR="/home/rhel/zt-network-automation-workshop"
RHEL_SSH="/home/rhel/.ssh"

# ---------------------------------------------------------------------------
# Wait for SSH key to appear (setup-containerlab.sh pushes it here).
# The platform puts the private key only on containerlab; that VM's setup
# script SCPs it to control. We just wait for it to show up.
# ---------------------------------------------------------------------------
wait_for_ssh_key() {
  if [[ -f "${RHEL_SSH}/config" ]] && ls "${RHEL_SSH}"/*.pem &>/dev/null 2>&1; then
    echo "SSH key + config already present on control" >> /tmp/progress.log
    return 0
  fi

  local max_attempts=60
  local delay=10
  echo "Waiting for SSH key from containerlab (pushed by setup-containerlab.sh)..." >> /tmp/progress.log
  for (( i=1; i<=max_attempts; i++ )); do
    if ls "${RHEL_SSH}"/*.pem &>/dev/null 2>&1; then
      echo "SSH key appeared on control after ${i} checks" >> /tmp/progress.log
      return 0
    fi
    sleep "${delay}"
  done

  echo "WARNING: SSH key never arrived after ${max_attempts} checks (~10 min). Containerlab playbooks will fail." >> /tmp/progress.log
  return 1
}

clone_repo() {
  if [[ -f "${REPO_DIR}/lab-automation/playbooks/site.yml" ]]; then
    echo "Workshop repo already present at ${REPO_DIR}" >> /tmp/progress.log
    return 0
  fi

  echo "Cloning ${REPO_URL} to ${REPO_DIR}..." >> /tmp/progress.log
  sudo -u rhel -H git clone "${REPO_URL}" "${REPO_DIR}" >> /tmp/progress.log 2>&1
  if [[ $? -eq 0 ]]; then
    echo "Repo cloned successfully" >> /tmp/progress.log
    return 0
  else
    echo "ERROR: git clone failed" >> /tmp/progress.log
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 3. Run lab-automation playbooks inside the EE via podman.
# ---------------------------------------------------------------------------
run_lab_automation() {
  local la_dir="${REPO_DIR}/lab-automation"
  if [[ ! -f "${la_dir}/playbooks/site.yml" ]]; then
    echo "lab-automation/playbooks/site.yml not found at ${la_dir}; skipping" >> /tmp/progress.log
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
    -e GUID="${GUID:-}" \
    -e DOMAIN="${DOMAIN:-}" \
    "${EE_IMAGE}" \
    ansible-playbook \
      -i /runner/project/inventory/lab.yml \
      /runner/project/playbooks/site.yml \
    >> /tmp/lab-automation-site.log 2>&1 \
  || echo "lab-automation failed; see /tmp/lab-automation-site.log" >> /tmp/progress.log
}

registry_login || true
pull_ee || true
wait_for_ssh_key || true
clone_repo || true
run_lab_automation || true
