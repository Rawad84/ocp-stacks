#!/usr/bin/env bash
# Validation for sandbox deployment (Clair disabled, HPA disabled, reduced replicas).
# Calls validate.sh with --sandbox flag — no need to pass flags manually.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/validate-full.sh" --sandbox "$@"
