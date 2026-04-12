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
# Install git (not present on rhel-9.6 base image).
# ---------------------------------------------------------------------------
if ! command -v git &>/dev/null; then
  echo "Installing git..." >> /tmp/progress.log
  dnf install -y git-core >> /tmp/progress.log 2>&1 || true
fi

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
  for rpm_file in "${REPO_DIR}"/rpms/*.rpm; do
    rpm -Uvh "${rpm_file}" >> /tmp/progress.log 2>&1 || true
  done
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

# ---------------------------------------------------------------------------
# Router SSH access — wrapper scripts so students can type `ssh rtr1` or `rtr1`
# from the VS Code terminal. Routers are reachable via containerlab port forwarding.
# ---------------------------------------------------------------------------
setup_router_access() {
  echo "Setting up router SSH access on vscode VM..." >> /tmp/progress.log

  if ! command -v sshpass &>/dev/null; then
    echo "WARNING: sshpass not available; router SSH wrappers will not work" >> /tmp/progress.log
    return 0
  fi

  for rtr_entry in "rtr1 2222" "rtr2 2223" "rtr3 2225" "rtr4 2226"; do
    local rtr_name="${rtr_entry% *}"
    local rtr_port="${rtr_entry#* }"
    cat > "/usr/local/bin/${rtr_name}" <<WRAPPER
#!/bin/bash
exec sshpass -p 'admin@123' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${rtr_port} admin@containerlab "\$@"
WRAPPER
    chmod 755 "/usr/local/bin/${rtr_name}"
  done

  cat > /etc/profile.d/router-ssh.sh <<'PROFILE'
ssh() {
  case "$1" in
    rtr[1-4])
      local port
      case "$1" in
        rtr1) port=2222 ;; rtr2) port=2223 ;; rtr3) port=2225 ;; rtr4) port=2226 ;;
      esac
      sshpass -p 'admin@123' /usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$port" "admin@containerlab" "${@:2}"
      ;;
    *)
      /usr/bin/ssh "$@"
      ;;
  esac
}
PROFILE
  chmod 644 /etc/profile.d/router-ssh.sh

  echo "Router access configured on vscode — rtr1/rtr2/rtr3/rtr4 via containerlab ports" >> /tmp/progress.log
}
setup_router_access

echo "setup-vscode.sh complete" >> /tmp/progress.log
