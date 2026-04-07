#!/bin/bash
USER=rhel

echo "Adding wheel" > /root/post-run.log
usermod -aG wheel rhel

echo "Setup vm control" > /tmp/progress.log

chmod 666 /tmp/progress.log 

#dnf install -y nc

# Optional: run lab-automation playbooks (containerlab deploy + Controller SCM project) when this
# workshop repo is synced onto the control node and ansible-playbook is available.
# Set CONTROLLER_PASSWORD for Controller API (admin); omit to skip AAP bootstrap tasks only.
run_lab_automation() {
  local la_dir=""
  for d in "/home/rhel/zt-network-automation-workshop" "/home/rhel/workshop" "${WORKSHOP_REPO_ROOT:-}"; do
    [[ -z "$d" ]] && continue
    if [[ -f "$d/lab-automation/playbooks/site.yml" ]]; then
      la_dir="$d/lab-automation"
      break
    fi
  done
  [[ -z "$la_dir" ]] && return 0
  if ! sudo -u rhel -H bash -c "command -v ansible-playbook" >/dev/null 2>&1; then
    echo "ansible-playbook not found for rhel; skipping lab-automation" >> /tmp/progress.log
    return 0
  fi
  echo "Running lab-automation from $la_dir" >> /tmp/progress.log
  sudo -u rhel -H env \
    CONTROLLER_PASSWORD="${CONTROLLER_PASSWORD:-}" \
    GATEWAY_HOSTNAME="${GATEWAY_HOSTNAME:-}" \
    GATEWAY_USERNAME="${GATEWAY_USERNAME:-}" \
    GATEWAY_PASSWORD="${GATEWAY_PASSWORD:-}" \
    bash -c "
    cd \"$la_dir\" || exit 1
    ansible-galaxy collection install -r requirements.yml -p \"\$HOME/.ansible/collections\" >> /tmp/lab-automation-collections.log 2>&1 || true
    ansible-playbook -i inventory/lab.yml playbooks/site.yml >> /tmp/lab-automation-site.log 2>&1
  " || echo "lab-automation failed; see /tmp/lab-automation-site.log" >> /tmp/progress.log
}

run_lab_automation || true

