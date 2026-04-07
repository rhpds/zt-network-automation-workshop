#!/bin/bash
# Runs when showroom targets the containerlab VM (bastion / lab node).
set -e
echo "Setup containerlab" >> /tmp/progress.log
chmod 666 /tmp/progress.log 2>/dev/null || true

# ---------------------------------------------------------------------------
# Push SSH key + config to 'control' so control can SSH back to containerlab.
# The lab image pre-loads a keypair under ~rhel/.ssh/ on containerlab;
# control's rhel user has no private key or ssh config by default.
# ---------------------------------------------------------------------------
push_ssh_key_to_control() {
  local key_user="rhel"
  local key_home="/home/${key_user}"
  local ssh_dir="${key_home}/.ssh"

  # Find the private key (name varies per lab build).
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

  echo "Pushing SSH key (${privkey}) to control:~${key_user}/.ssh/" >> /tmp/progress.log

  # Use the existing key (containerlab → control already works) to copy files.
  sudo -u "${key_user}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 control \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh" || { echo "SSH to control failed; skipping key push" >> /tmp/progress.log; return 0; }

  sudo -u "${key_user}" scp -o StrictHostKeyChecking=no \
    "${privkey}" "control:${ssh_dir}/$(basename "${privkey}")"
  [[ -n "$pubkey" ]] && sudo -u "${key_user}" scp -o StrictHostKeyChecking=no \
    "${pubkey}" "control:${ssh_dir}/$(basename "${pubkey}")"

  # Write an SSH config on control so `ssh containerlab` works out of the box.
  sudo -u "${key_user}" ssh -o StrictHostKeyChecking=no control bash -s <<REMOTE
    set -e
    chmod 600 ~/.ssh/$(basename "${privkey}")
    cat > ~/.ssh/config <<'EOF'
Host *
  IdentityFile ~/.ssh/$(basename "${privkey}")
  StrictHostKeyChecking no
  ConnectTimeout 60
  ConnectionAttempts 10
EOF
    chmod 600 ~/.ssh/config
REMOTE

  echo "SSH key + config pushed to control successfully" >> /tmp/progress.log
}

push_ssh_key_to_control || echo "push_ssh_key_to_control failed; see above" >> /tmp/progress.log
