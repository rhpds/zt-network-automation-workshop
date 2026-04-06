#!/bin/bash
# Runs when showroom targets the containerlab VM (bastion / lab node).
# Extend this if you need provisioning steps specific to containerlab.
set -e
echo "Setup containerlab" >> /tmp/progress.log
chmod 666 /tmp/progress.log 2>/dev/null || true
