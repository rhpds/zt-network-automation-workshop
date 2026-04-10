#!/bin/bash
USER=rhel
EE_IMAGE="registry.redhat.io/ansible-automation-platform-26/ee-supported-rhel9:latest"
NETWORK_EE_IMAGE="quay.io/acme_corp/network-ee"
REPO_URL="https://github.com/rhpds/zt-network-automation-workshop.git"
REPO_DIR="/home/rhel/zt-network-automation-workshop"
RHEL_SSH="/home/rhel/.ssh"

echo "Adding wheel" > /root/post-run.log
usermod -aG wheel rhel

echo "Setup vm control" > /tmp/progress.log
chmod 666 /tmp/progress.log

# ---------------------------------------------------------------------------
# Functions (all defined up front, called at the bottom).
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

clone_repo() {
  if [[ -f "${REPO_DIR}/lab-automation/playbooks/site.yml" ]]; then
    echo "Workshop repo already present at ${REPO_DIR}" >> /tmp/progress.log
    return 0
  fi
  echo "Cloning ${REPO_URL} to ${REPO_DIR}..." >> /tmp/progress.log
  sudo -u rhel -H git clone "${REPO_URL}" "${REPO_DIR}" >> /tmp/progress.log 2>&1
  if [[ $? -eq 0 ]]; then
    echo "Repo cloned successfully" >> /tmp/progress.log
  else
    echo "ERROR: git clone failed" >> /tmp/progress.log
    return 1
  fi
}

install_rpms() {
  local rpm_dir="${REPO_DIR}/rpms"
  if [[ -d "${rpm_dir}" ]]; then
    echo "Installing bundled RPMs from ${rpm_dir}..." >> /tmp/progress.log
    rpm -ivh "${rpm_dir}"/*.rpm >> /tmp/progress.log 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# Heavy lifting — runs in the background so the platform doesn't timeout.
# Everything below here logs to /tmp/progress.log for monitoring.
# ---------------------------------------------------------------------------
background_setup() {
  echo "=== Background setup started ===" >> /tmp/progress.log

  # Pull EE images.
  echo "Pulling EE image ${EE_IMAGE}..." >> /tmp/progress.log
  sudo -u rhel -H podman pull "${EE_IMAGE}" >> /tmp/progress.log 2>&1 \
    && echo "EE image pulled" >> /tmp/progress.log \
    || echo "WARNING: EE pull failed" >> /tmp/progress.log

  echo "Pulling Network EE image ${NETWORK_EE_IMAGE}..." >> /tmp/progress.log
  sudo -u rhel -H podman pull "${NETWORK_EE_IMAGE}" >> /tmp/progress.log 2>&1 \
    && echo "Network EE pulled" >> /tmp/progress.log \
    || echo "WARNING: Network EE pull failed" >> /tmp/progress.log

  # Wait for SSH key from containerlab (pushed by setup-containerlab.sh).
  if [[ -f "${RHEL_SSH}/config" ]] && ls "${RHEL_SSH}"/*.pem &>/dev/null 2>&1; then
    echo "SSH key already present" >> /tmp/progress.log
  else
    echo "Waiting for SSH key from containerlab..." >> /tmp/progress.log
    for (( i=1; i<=60; i++ )); do
      if ls "${RHEL_SSH}"/*.pem &>/dev/null 2>&1; then
        echo "SSH key arrived after ${i} checks" >> /tmp/progress.log
        break
      fi
      sleep 10
    done
  fi

  # Run lab-automation playbooks (AAP bootstrap + topology).
  local la_dir="${REPO_DIR}/lab-automation"
  if [[ -f "${la_dir}/playbooks/site.yml" ]] && command -v podman &>/dev/null; then
    echo "Running lab-automation via EE..." >> /tmp/progress.log
    sudo -u rhel -H podman run --rm \
      --network host \
      -v "${la_dir}:/runner/project:Z" \
      -v "/home/rhel/.ssh:/home/runner/.ssh:Z" \
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
  else
    echo "Skipping lab-automation (site.yml not found or podman unavailable)" >> /tmp/progress.log
  fi

  echo "=== Background setup complete ===" >> /tmp/progress.log
}

# ---------------------------------------------------------------------------
# Execution: fast stuff synchronously, slow stuff in background.
# ---------------------------------------------------------------------------
registry_login || true
clone_repo || true
install_rpms

# Background the slow work (image pulls, SSH key wait, lab-automation).
# Export env vars so the background function inherits them.
export REG_USER REG_PASS CONTROLLER_PASSWORD GATEWAY_HOSTNAME
export GATEWAY_USERNAME GATEWAY_PASSWORD GUID DOMAIN
nohup bash -c "$(declare -f background_setup); \
  EE_IMAGE='${EE_IMAGE}' NETWORK_EE_IMAGE='${NETWORK_EE_IMAGE}' \
  REPO_DIR='${REPO_DIR}' RHEL_SSH='${RHEL_SSH}' \
  CONTROLLER_PASSWORD='${CONTROLLER_PASSWORD:-}' \
  GATEWAY_HOSTNAME='${GATEWAY_HOSTNAME:-}' \
  GATEWAY_USERNAME='${GATEWAY_USERNAME:-}' \
  GATEWAY_PASSWORD='${GATEWAY_PASSWORD:-}' \
  GUID='${GUID:-}' DOMAIN='${DOMAIN:-}' \
  background_setup" >> /tmp/progress.log 2>&1 &

echo "Fast setup done; background tasks running (PID $!). Monitor: tail -f /tmp/progress.log" >> /tmp/progress.log
