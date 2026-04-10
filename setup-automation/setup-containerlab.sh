#!/bin/bash
# Runs when showroom targets the containerlab VM (bastion / lab node).
# NOTE: Do NOT use set -e — each section must run independently.
echo "Setup containerlab" >> /tmp/progress.log
chmod 666 /tmp/progress.log 2>/dev/null || true

REPO_URL="https://github.com/rhpds/zt-network-automation-workshop.git"
REPO_DIR="/home/rhel/zt-network-automation-workshop"

# ---------------------------------------------------------------------------
# Clone the workshop repo so we have access to bundled RPMs etc.
# ---------------------------------------------------------------------------
clone_repo() {
  if [[ -d "${REPO_DIR}/.git" ]]; then
    echo "Workshop repo already present on containerlab" >> /tmp/progress.log
    return 0
  fi

  echo "Cloning ${REPO_URL} to ${REPO_DIR} on containerlab..." >> /tmp/progress.log
  sudo -u rhel -H git clone "${REPO_URL}" "${REPO_DIR}" >> /tmp/progress.log 2>&1
  if [[ $? -eq 0 ]]; then
    echo "Repo cloned on containerlab" >> /tmp/progress.log
  else
    echo "WARNING: git clone failed on containerlab" >> /tmp/progress.log
  fi
}

# ---------------------------------------------------------------------------
# Push SSH key + config to 'control' so control can SSH back to containerlab.
# ---------------------------------------------------------------------------
push_ssh_key_to_control() {
  local key_user="rhel"
  local key_home="/home/${key_user}"
  local ssh_dir="${key_home}/.ssh"

  local privkey=""
  for f in "${ssh_dir}"/*.pem "${ssh_dir}/id_rsa" "${ssh_dir}/id_ed25519"; do
    if [[ -f "$f" ]]; then
      privkey="$f"
      break
    fi
  done
  if [[ -z "$privkey" ]]; then
    echo "No private key found under ${ssh_dir}; skipping key push to control" >> /tmp/progress.log
    return 0
  fi

  local pubkey=""
  if [[ -f "${privkey%.pem}.pub" ]]; then
    pubkey="${privkey%.pem}.pub"
  elif [[ -f "${privkey}.pub" ]]; then
    pubkey="${privkey}.pub"
  fi

  local keybase
  keybase="$(basename "${privkey}")"
  echo "Pushing SSH key (${privkey}) to control:~${key_user}/.ssh/" >> /tmp/progress.log

  sudo -u "${key_user}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 control \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>>/tmp/progress.log
  if [[ $? -ne 0 ]]; then
    echo "SSH to control failed; skipping key push" >> /tmp/progress.log
    return 0
  fi

  sudo -u "${key_user}" scp -o StrictHostKeyChecking=no \
    "${privkey}" "control:${ssh_dir}/${keybase}" 2>>/tmp/progress.log || true
  if [[ -n "$pubkey" ]]; then
    sudo -u "${key_user}" scp -o StrictHostKeyChecking=no \
      "${pubkey}" "control:${ssh_dir}/$(basename "${pubkey}")" 2>>/tmp/progress.log || true
  fi

  sudo -u "${key_user}" ssh -o StrictHostKeyChecking=no control bash -s -- "${keybase}" <<'REMOTE'
    chmod 600 ~/.ssh/"$1" 2>/dev/null
    cat > ~/.ssh/config <<EOF
Host *
  IdentityFile ~/.ssh/$1
  StrictHostKeyChecking no
  ConnectTimeout 60
  ConnectionAttempts 10
EOF
    chmod 600 ~/.ssh/config
REMOTE

  echo "SSH key + config pushed to control successfully" >> /tmp/progress.log
}

# ---------------------------------------------------------------------------
# Set up /etc/hosts, SSH config, sshpass, and wrapper scripts so students
# can connect to routers with just `ssh rtr1` or `rtr1`.
# ---------------------------------------------------------------------------
setup_router_access() {
  echo "Setting up router name resolution and SSH config..." >> /tmp/progress.log

  # /etc/hosts — system-wide, works for all users.
  if ! grep -q "rtr1" /etc/hosts 2>/dev/null; then
    cat >> /etc/hosts <<'HOSTS'
172.20.20.10 rtr1
172.20.20.20 rtr2
172.20.20.30 rtr3
172.20.20.40 rtr4
HOSTS
    echo "Added rtr1-4 to /etc/hosts" >> /tmp/progress.log
  fi

  # SSH config for both rhel and lab-user.
  for u in rhel lab-user; do
    local uhome="/home/${u}"
    local ussh="${uhome}/.ssh"
    if id "${u}" &>/dev/null; then
      mkdir -p "${ussh}"
      cat > "${ussh}/config.d-routers" <<'SSHCFG'
Host rtr1 rtr2 rtr3 rtr4
  User admin
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
SSHCFG
      # Append Include if main config exists, otherwise create config directly.
      if [[ -f "${ussh}/config" ]]; then
        grep -q "config.d-routers" "${ussh}/config" 2>/dev/null || \
          sed -i '1i Include ~/.ssh/config.d-routers' "${ussh}/config"
      else
        cat > "${ussh}/config" <<'MAINCFG'
Include ~/.ssh/config.d-routers
MAINCFG
      fi
      chmod 600 "${ussh}/config" "${ussh}/config.d-routers" 2>/dev/null
      chown -R "${u}:${u}" "${ussh}" 2>/dev/null || chown -R "${u}:users" "${ussh}" 2>/dev/null
      echo "SSH router config written for ${u}" >> /tmp/progress.log
    fi
  done

  # Install sshpass from bundled RPM.
  if ! command -v sshpass &>/dev/null; then
    local rpm_path="${REPO_DIR}/rpms/sshpass-1.09-4.el9.x86_64.rpm"
    if [[ -f "${rpm_path}" ]]; then
      rpm -ivh "${rpm_path}" >> /tmp/progress.log 2>&1 || true
      echo "sshpass installed from bundled RPM" >> /tmp/progress.log
    else
      echo "WARNING: sshpass RPM not found at ${rpm_path}" >> /tmp/progress.log
    fi
  else
    echo "sshpass already installed" >> /tmp/progress.log
  fi

  # Wrapper scripts: just type `rtr1` to connect passwordlessly.
  for rtr in rtr1 rtr2 rtr3 rtr4; do
    cat > "/usr/local/bin/${rtr}" <<WRAPPER
#!/bin/bash
exec sshpass -p 'admin@123' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@${rtr} "\$@"
WRAPPER
    chmod 755 "/usr/local/bin/${rtr}"
  done

  # Shell function so `ssh rtr1` also works passwordlessly (all users).
  cat > /etc/profile.d/router-ssh.sh <<'PROFILE'
ssh() {
  case "$1" in
    rtr[1-4])
      sshpass -p 'admin@123' /usr/bin/ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "admin@$1" "${@:2}"
      ;;
    *)
      /usr/bin/ssh "$@"
      ;;
  esac
}
PROFILE
  chmod 644 /etc/profile.d/router-ssh.sh

  echo "Router access configured — rtr1/rtr2/rtr3/rtr4 (passwordless)" >> /tmp/progress.log
}

# ---------------------------------------------------------------------------
# Install any other bundled RPMs (grubby etc.).
# ---------------------------------------------------------------------------
install_rpms() {
  local rpm_dir="${REPO_DIR}/rpms"
  if [[ -d "${rpm_dir}" ]]; then
    echo "Installing bundled RPMs on containerlab..." >> /tmp/progress.log
    rpm -ivh "${rpm_dir}"/*.rpm >> /tmp/progress.log 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# Run each step independently — failures in one must not block the rest.
# ---------------------------------------------------------------------------
clone_repo
push_ssh_key_to_control || echo "push_ssh_key_to_control failed" >> /tmp/progress.log
install_rpms
setup_router_access || echo "setup_router_access failed" >> /tmp/progress.log
echo "setup-containerlab.sh complete" >> /tmp/progress.log
