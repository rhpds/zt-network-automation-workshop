#!/bin/bash
# Runs on the vscode VM (devtools-ansible image — code-server is pre-installed).
echo "Setup vscode" >> /tmp/progress.log
chmod 666 /tmp/progress.log 2>/dev/null || true

REPO_URL="https://github.com/rhpds/zt-network-automation-workshop.git"
REPO_DIR="/tmp/zt-network-automation-workshop"

# ---------------------------------------------------------------------------
# Configure and start code-server (already baked into devtools-ansible image).
# ---------------------------------------------------------------------------
systemctl stop code-server 2>/dev/null || true

mkdir -p /home/rhel/.config/code-server
cat > /home/rhel/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:8080
auth: none
cert: false
EOF
chown -R rhel:rhel /home/rhel/.config/code-server

systemctl start code-server
echo "code-server configured and started on port 8080" >> /tmp/progress.log

# ---------------------------------------------------------------------------
# Clone the workshop repo and copy exercise files to ~rhel/network-workshop.
# ---------------------------------------------------------------------------
echo "Cloning workshop repo for exercise files..." >> /tmp/progress.log
git clone "${REPO_URL}" "${REPO_DIR}" >> /tmp/progress.log 2>&1 || true

if [[ -d "${REPO_DIR}/network-workshop" ]]; then
  cp -r "${REPO_DIR}/network-workshop" /home/rhel/network-workshop
  cp "${REPO_DIR}/network-workshop/.ansible-navigator.yml" /home/rhel/.ansible-navigator.yml
  chown -R rhel:rhel /home/rhel/network-workshop /home/rhel/.ansible-navigator.yml
  echo "Exercise files copied to /home/rhel/network-workshop" >> /tmp/progress.log
else
  echo "WARNING: network-workshop directory not found in repo" >> /tmp/progress.log
fi

# ---------------------------------------------------------------------------
# Install bundled RPMs (podman, sshpass, etc.) from the cloned repo.
# The devtools-ansible image may not have podman; Leo's lab installs it
# via dnf after Satellite registration, but we don't have Satellite.
# ---------------------------------------------------------------------------
if [[ -d "${REPO_DIR}/rpms" ]]; then
  echo "Installing bundled RPMs on vscode VM..." >> /tmp/progress.log
  rpm -ivh "${REPO_DIR}"/rpms/*.rpm >> /tmp/progress.log 2>&1 || true
fi

# Install ansible-navigator if not already present.
if ! command -v ansible-navigator &>/dev/null; then
  echo "Installing ansible-navigator via pip..." >> /tmp/progress.log
  sudo -u rhel pip3 install ansible-navigator >> /tmp/progress.log 2>&1 \
    || pip3 install ansible-navigator >> /tmp/progress.log 2>&1 \
    || echo "WARNING: ansible-navigator installation failed" >> /tmp/progress.log
fi

# Sudoers for rhel user (needed for become operations).
echo "%rhel ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/rhel_sudoers
chmod 440 /etc/sudoers.d/rhel_sudoers

# ---------------------------------------------------------------------------
# Pre-pull the network EE so ansible-navigator doesn't wait on first run.
# ---------------------------------------------------------------------------
if command -v podman &>/dev/null; then
  echo "Pulling network EE image for ansible-navigator..." >> /tmp/progress.log
  sudo -u rhel -H podman pull quay.io/acme_corp/network-ee:latest >> /tmp/progress.log 2>&1 \
    && echo "Network EE pulled successfully" >> /tmp/progress.log \
    || echo "WARNING: Could not pull network EE (ansible-navigator will try at runtime)" >> /tmp/progress.log
else
  echo "WARNING: podman not available — cannot pre-pull network EE" >> /tmp/progress.log
fi

echo "setup-vscode.sh complete" >> /tmp/progress.log
