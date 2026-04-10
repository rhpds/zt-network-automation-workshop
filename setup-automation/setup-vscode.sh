#!/bin/bash
USER=rhel
REPO_URL="https://github.com/rhpds/zt-network-automation-workshop.git"
REPO_DIR="/tmp/zt-network-automation-workshop"

echo "Setup vscode" > /tmp/progress.log
chmod 666 /tmp/progress.log

# ---------------------------------------------------------------------------
# Install code-server (curl pattern from zt-quarkus-intro).
# ---------------------------------------------------------------------------
mkdir -p /home/$USER/.local/share/code-server/User/
mkdir -p /home/$USER/.config/code-server/

cat > /home/$USER/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:8080
auth: none
cert: false
disable-update-check: true
EOF

cat > /home/$USER/.local/share/code-server/User/settings.json <<EOL
{
  "git.ignoreLegacyWarning": true,
  "window.menuBarVisibility": "visible",
  "git.enableSmartCommit": true,
  "workbench.tips.enabled": false,
  "workbench.startupEditor": "readme",
  "telemetry.enableTelemetry": false,
  "search.smartCase": true,
  "git.confirmSync": false,
  "workbench.colorTheme": "Visual Studio Dark",
  "update.showReleaseNotes": false,
  "update.mode": "none",
  "files.exclude": {
    "**/.*": true
  },
  "security.workspace.trust.enabled": false,
  "redhat.telemetry.enabled": false
}
EOL

chown $USER.$USER /home/$USER/.config/code-server/config.yaml /home/$USER/.local/share/code-server/User/settings.json

echo "Installing code-server..." >> /tmp/progress.log
curl -fsSL https://code-server.dev/install.sh | sh >> /tmp/progress.log 2>&1
systemctl enable --now code-server@$USER
echo "code-server installed and started on port 8080" >> /tmp/progress.log

# ---------------------------------------------------------------------------
# Sudoers for rhel user.
# ---------------------------------------------------------------------------
echo "%rhel ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/rhel_sudoers
chmod 440 /etc/sudoers.d/rhel_sudoers

# ---------------------------------------------------------------------------
# Clone workshop repo and copy exercise files to ~rhel/network-workshop.
# ---------------------------------------------------------------------------
echo "Cloning workshop repo for exercise files..." >> /tmp/progress.log
timeout 120 git clone "${REPO_URL}" "${REPO_DIR}" >> /tmp/progress.log 2>&1 || true

if [[ -d "${REPO_DIR}/network-workshop" ]]; then
  cp -r "${REPO_DIR}/network-workshop" /home/$USER/network-workshop
  cp "${REPO_DIR}/network-workshop/.ansible-navigator.yml" /home/$USER/.ansible-navigator.yml
  chown -R $USER:$USER /home/$USER/network-workshop /home/$USER/.ansible-navigator.yml
  echo "Exercise files copied to /home/$USER/network-workshop" >> /tmp/progress.log
else
  echo "WARNING: network-workshop directory not found in repo" >> /tmp/progress.log
fi

# ---------------------------------------------------------------------------
# Install bundled RPMs (podman, sshpass, etc.).
# ---------------------------------------------------------------------------
if [[ -d "${REPO_DIR}/rpms" ]]; then
  echo "Installing bundled RPMs on vscode VM..." >> /tmp/progress.log
  rpm -ivh "${REPO_DIR}"/rpms/*.rpm >> /tmp/progress.log 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Pre-pull network EE (best effort, 3 min timeout).
# ---------------------------------------------------------------------------
if command -v podman &>/dev/null; then
  echo "Pulling network EE image..." >> /tmp/progress.log
  timeout 180 sudo -u $USER -H podman pull quay.io/acme_corp/network-ee:latest >> /tmp/progress.log 2>&1 \
    && echo "Network EE pulled" >> /tmp/progress.log \
    || echo "WARNING: Could not pull network EE" >> /tmp/progress.log
fi

echo "setup-vscode.sh complete" >> /tmp/progress.log
