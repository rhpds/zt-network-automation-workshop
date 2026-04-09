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

# ---------------------------------------------------------------------------
# Set up /etc/hosts and SSH config so students can just `ssh rtr1` etc.
# IPs are static from the containerlab topology (172.20.20.0/24 Docker bridge).
# ---------------------------------------------------------------------------
setup_router_access() {
  echo "Setting up router name resolution and SSH config..." >> /tmp/progress.log

  grep -q "rtr1" /etc/hosts 2>/dev/null || cat >> /etc/hosts <<'HOSTS'
172.20.20.10 rtr1
172.20.20.20 rtr2
172.20.20.30 rtr3
172.20.20.40 rtr4
HOSTS

  local lab_ssh="/home/lab-user/.ssh"
  mkdir -p "${lab_ssh}"

  cat > "${lab_ssh}/config" <<'SSHCFG'
Host rtr1 rtr2 rtr3 rtr4
  User admin
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
SSHCFG
  chmod 600 "${lab_ssh}/config"
  chown -R lab-user:lab-user "${lab_ssh}"

  # Python-based sshpass alternative (no EPEL needed).
  cat > /usr/local/bin/sshpass-py <<'PYEOF'
#!/usr/bin/env python3
import sys, os, pty, select, time
password = sys.argv[1]
cmd = sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
buf = b""
sent = False
while True:
    r, _, _ = select.select([fd], [], [], 1)
    if r:
        try:
            data = os.read(fd, 1024)
        except OSError:
            break
        if not data:
            break
        buf += data
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        if not sent and b"assword:" in buf:
            time.sleep(0.1)
            os.write(fd, (password + "\n").encode())
            sent = True
            buf = b""
    elif sent:
        continue
_, status = os.waitpid(pid, 0)
sys.exit(os.WEXITSTATUS(status))
PYEOF
  chmod 755 /usr/local/bin/sshpass-py

  # Wrapper scripts: just type `rtr1` to connect passwordlessly.
  for rtr in rtr1 rtr2 rtr3 rtr4; do
    cat > "/usr/local/bin/${rtr}" <<WRAPPER
#!/bin/bash
exec /usr/local/bin/sshpass-py 'admin@123' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@${rtr} "\$@"
WRAPPER
    chmod 755 "/usr/local/bin/${rtr}"
  done

  echo "Router access configured — rtr1/rtr2/rtr3/rtr4 (passwordless)" >> /tmp/progress.log
}

setup_router_access || echo "setup_router_access failed" >> /tmp/progress.log
