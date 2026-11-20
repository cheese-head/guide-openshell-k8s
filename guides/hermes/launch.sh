#!/usr/bin/env bash
set -euo pipefail

if [[ ${1-} == --help || ${1-} == -h || $# -lt 2 || $# -gt 3 ]]; then
  printf 'Usage: bash %s SANDBOX API_BASE_URL [MODEL_ID]\n' "$0"
  printf 'Uses the active OpenShell gateway and workspace.\n'
  printf 'Optional overrides: HERMES_SANDBOX_IMAGE, HERMES_OPENSHELL_PROVIDER.\n'
  [[ ${1-} == --help || ${1-} == -h ]] && exit 0
  exit 2
fi

sandbox=$1
base_url=${2%/}
model=${3:-NousResearch/Hermes-3-Llama-3.1-8B}
image=${HERMES_SANDBOX_IMAGE:-docker.io/library/hermes-openshell-lab:0.1}
provider=${HERMES_OPENSHELL_PROVIDER:-hermes-llm}
guide_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ ! $base_url =~ ^https?://[^/@[:space:][:cntrl:]?#]+(/[^[:space:][:cntrl:]?#]*)?$ ]]; then
  printf 'Provide an HTTP(S) API base URL without embedded credentials, a query, or a fragment.\n' >&2
  exit 2
fi

openshell sandbox create --name "$sandbox" --from "$image" \
  --policy "$guide_dir/workload-policy.yaml" --provider "$provider" \
  --detach --no-auto-providers --timeout 300 \
  --env HERMES_HOME=/sandbox/.hermes-lab -- /bin/sleep 3600

if ! openshell sandbox exec "$sandbox" --no-tty --no-login-shell --timeout 30 -- \
  /opt/hermes/.venv/bin/python - "$base_url" "$model" <<'PYTHON'
import json
import os
import sys
from pathlib import Path

base_url, model = sys.argv[1:]
os.umask(0o077)
home = Path(os.environ["HERMES_HOME"])
home.mkdir(parents=True, exist_ok=True)
config = {
    "model": {"provider": "custom:lab-llm", "default": model},
    "providers": {
        "lab-llm": {
            "api": base_url,
            "api_mode": "chat_completions",
            "key_env": "HERMES_LAB_LLM_API_KEY",
        }
    },
}
with (home / "config.yaml").open("x") as config_file:
    json.dump(config, config_file, indent=2)
    config_file.write("\n")
PYTHON
then
  printf 'Sandbox %s was created, but Hermes setup failed. Inspect or delete it before retrying.\n' "$sandbox" >&2
  exit 1
fi

printf 'Sandbox %s is ready with Hermes model %s.\n' "$sandbox" "$model"
