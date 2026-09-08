#!/usr/bin/env bash
# =============================================================================
# deploy.sh -- generate the pipeline runner, then run it (two real invocations;
# see deploy.yml for why they can't be one).
#
# TWO WAYS TO PASS YOUR DEPLOYMENT DATA:
#
# 1. --deployment <dir>   (convenient)
#      Loads, in this DEFINED ORDER, everything under the deployment directory:
#         <dir>/spec.yml
#         <dir>/pipeline.yml
#         <dir>/vars/*.yml   (alphabetical)
#      Later files override earlier ones (standard Ansible -e precedence), so
#      vars/ can override pipeline/spec if needed.
#      Example:
#        ./deploy.sh --deployment mydeployments/foo -i local.ini \
#            -e active_pipeline=full
#
# 2. explicit -e @... flags   (full control; power users)
#        ./deploy.sh -i local.ini \
#            -e @mydeployments/foo/spec.yml \
#            -e @mydeployments/foo/pipeline.yml \
#            -e @mydeployments/foo/vars/control.yml \
#            -e active_pipeline=full
#
# Anything you pass besides --deployment is forwarded to ansible-playbook as-is,
# so you can mix: use --deployment and still add extra -e overrides.
# =============================================================================
set -euo pipefail

# Use the framework's own ansible.cfg, bypassing the user's ~/.ansible.cfg
# entirely (self-contained: not sabotaged by stale personal SSH/ansible config).
# ANSIBLE_CONFIG wins over ./ansible.cfg, ~/.ansible.cfg, and /etc/ansible.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG_OVERRIDE:-$SCRIPT_DIR/ansible.cfg}"
echo "[deploy] using ANSIBLE_CONFIG=$ANSIBLE_CONFIG"

DEPLOY_DIR=""
PASSTHRU=()

# Separate --deployment from the args forwarded to ansible-playbook.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deployment)
      DEPLOY_DIR="${2:-}"
      if [[ -z "$DEPLOY_DIR" ]]; then
        echo "[deploy] ERROR: --deployment needs a directory path" >&2
        exit 2
      fi
      shift 2
      ;;
    --deployment=*)
      DEPLOY_DIR="${1#*=}"
      shift
      ;;
    *)
      PASSTHRU+=("$1")
      shift
      ;;
  esac
done

# Build the -e flags from a deployment directory, in a DEFINED order.
DEPLOY_ARGS=()
if [[ -n "$DEPLOY_DIR" ]]; then
  DEPLOY_DIR="${DEPLOY_DIR%/}"   # strip trailing slash
  if [[ ! -d "$DEPLOY_DIR" ]]; then
    echo "[deploy] ERROR: deployment directory not found: $DEPLOY_DIR" >&2
    exit 2
  fi
  # spec.yml (required)
  if [[ -f "$DEPLOY_DIR/spec.yml" ]]; then
    DEPLOY_ARGS+=(-e "@$DEPLOY_DIR/spec.yml")
  else
    echo "[deploy] ERROR: missing required $DEPLOY_DIR/spec.yml" >&2
    echo "         (copy specs/examples/sample-deployment/spec.yml and edit it)" >&2
    exit 2
  fi
  # pipeline.yml (required)
  if [[ -f "$DEPLOY_DIR/pipeline.yml" ]]; then
    DEPLOY_ARGS+=(-e "@$DEPLOY_DIR/pipeline.yml")
  else
    echo "[deploy] ERROR: missing required $DEPLOY_DIR/pipeline.yml" >&2
    echo "         (copy specs/examples/sample-deployment/pipeline.yml and edit it)" >&2
    exit 2
  fi
  # vars/*.yml (optional, alphabetical)
  if [[ -d "$DEPLOY_DIR/vars" ]]; then
    shopt -s nullglob
    for vf in "$DEPLOY_DIR"/vars/*.yml; do
      DEPLOY_ARGS+=(-e "@$vf")
    done
    shopt -u nullglob
  fi
  echo "[deploy] deployment '$DEPLOY_DIR' -> loading:"
  for ((i=0; i<${#DEPLOY_ARGS[@]}; i+=2)); do echo "           ${DEPLOY_ARGS[i+1]#@}"; done
fi

ALL_ARGS=("${DEPLOY_ARGS[@]}" "${PASSTHRU[@]}")

echo "[deploy] generating runner..."
ansible-playbook "${ALL_ARGS[@]}" generate_runner.yml
echo "[deploy] running generated pipeline..."
ansible-playbook "${ALL_ARGS[@]}" run_deployment.yml
