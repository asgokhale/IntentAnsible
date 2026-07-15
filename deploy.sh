#!/usr/bin/env bash
# Convenience: generate the runner, then run it -- as two real invocations
# (required; see deploy.yml). Pass the same -e/-i args you'd pass ansible.
# Usage: ./deploy.sh -i inventory_test -e @mydeployments/ch-819381.yml \
#                    -e active_pipeline=provision_only
set -euo pipefail
echo "[deploy] generating runner..."
ansible-playbook "$@" generate_runner.yml
echo "[deploy] running generated pipeline..."
ansible-playbook "$@" run_deployment.yml
