# Choose an LLM endpoint and model for Hermes Agent

[← Repository overview](../README.md) · [Set up OpenShell on Kubernetes](openshell-on-kubernetes.md)

Configure a sandbox to call an OpenAI-compatible endpoint, then tell Hermes Agent which model to request. **Hermes Agent** is the harness in the sandbox. **Hermes 3** is one model it can call through a serving endpoint. This example uses `NousResearch/Hermes-3-Llama-3.1-8B`. Substitute the exact model ID or alias served by your endpoint. [Hermes Agent provider configuration](https://hermes-agent.nousresearch.com/docs/integrations/providers#custom--self-hosted-llm-providers) · [Hermes 3 model card](https://huggingface.co/NousResearch/Hermes-3-Llama-3.1-8B)

| Set this in | What it controls |
| --- | --- |
| OpenShell provider profile and sandbox attachment | Which endpoint the sandbox can reach, which executable may call it, and which credential it can use. |
| Hermes Agent `config.yaml` | The API base URL, request format, and model ID the harness sends. |
| The inference server | Which models or aliases are actually served and whether they support tool calling. |

> [!NOTE]
> OpenShell 0.1.9 uses per-sandbox provider attachments and native provider URLs. The older `openshell inference set` command and `inference.local` endpoint were removed in the 0.1.0 transition. [OpenShell inference](https://docs.nvidia.com/openshell/v0.1.9/how-it-works/inference) · [Migration notes](https://docs.nvidia.com/openshell/v0.1.9/upgrade/0-1-0)

**Already have the image and provider?** From the repository root, [launch a sandbox with Hermes configured](#3-launch-with-the-default-model).

## 1. Build the Hermes sandbox image

Complete the [Kubernetes lab through CLI connection](openshell-on-kubernetes.md#3-connect-over-loopback) and leave the port-forward running. Have an OpenAI-compatible Chat Completions server reachable from the Kubernetes deployment, with a bearer token and a model ID. The example uses `https://llm.example.com/v1`. Replace that URL and the corresponding profile host, port, and path with your actual endpoint. For a server on Kubernetes, use a Service DNS name reachable from the sandbox supervisor. The gateway's local port-forward is for CLI access.

Run these commands from the host terminal where you connected the OpenShell CLI. The pinned NVIDIA Hermes base image seeds `/sandbox` with files owned by NemoClaw's sandbox user. OpenShell's default Kubernetes workspace initializer runs as UID/GID `10001`, so build a small derivative that makes those files readable and writable by that user. [NVIDIA Hermes image source](https://github.com/NVIDIA/NemoClaw/blob/main/agents/hermes/Dockerfile)

```bash
docker build --tag hermes-openshell-lab:0.1 - <<'DOCKERFILE'
FROM ghcr.io/nvidia/nemoclaw/hermes-sandbox-base@sha256:4574777698fa65e270f53ee4c6fca90640cc89867e7dcc726c2ca03429d4ed8b
USER 0
RUN chown -R 10001:10001 /sandbox && chmod -R u+rwX /sandbox
USER 10001:10001
DOCKERFILE

k3d image import hermes-openshell-lab:0.1 -c openshell-guide
```

The import command targets the disposable cluster from the Kubernetes guide. On another cluster, publish the image to a registry your nodes can pull from and set `HERMES_SANDBOX_IMAGE` to its tag or digest before running the launcher. The [filesystem policy](hermes/workload-policy.yaml) keeps the default paths and adds read-only access to `/opt/hermes` for the Python environment. [OpenShell sandbox policies](https://docs.nvidia.com/openshell/v0.1.9/how-it-works/policies)

## 2. Register the endpoint and credential

Save the following as `hermes-llm.yaml` on the host. Replace the example host, port, and path as needed. The path rule covers Chat Completions and model discovery under `/v1/`. The Python path comes from the pinned image. For a different image, use the resolved interpreter path that actually makes the requests. [OpenShell provider profiles](https://docs.nvidia.com/openshell/v0.1.9/how-it-works/providers/profiles)

```yaml
id: hermes-llm
display_name: Hermes LLM endpoint
category: inference
inference_capable: true
credentials:
  - name: api_key
    env_vars: [HERMES_LAB_LLM_API_KEY]
    required: true
    auth_style: bearer
    header_name: authorization
endpoints:
  - host: llm.example.com
    port: 443
    path: /v1/**
    protocol: rest
    access: read-write
    enforcement: enforce
binaries:
  - /usr/bin/python3.13
```

```bash
export OPENSHELL_GATEWAY="${OPENSHELL_LAB_GATEWAY:-k8s-lab}"
export OPENSHELL_WORKSPACE=default
openshell profile lint -f hermes-llm.yaml
openshell profile import -f hermes-llm.yaml

(
  set -e
  read -rsp 'LLM endpoint API key: ' HERMES_LAB_LLM_API_KEY
  printf '\n'
  export HERMES_LAB_LLM_API_KEY
  openshell provider create --name hermes-llm --type hermes-llm \
    --credential HERMES_LAB_LLM_API_KEY
)
```

Reuse this provider for each sandbox that needs the endpoint. With the provider attached, a new sandbox process receives an opaque placeholder in `HERMES_LAB_LLM_API_KEY`. The OpenShell proxy substitutes the real bearer token on a matching request. [OpenShell inference and credential binding](https://docs.nvidia.com/openshell/v0.1.9/how-it-works/inference)

## 3. Launch with the default model

From the repository root, run the [launcher](hermes/launch.sh) with a new sandbox name and your endpoint's API base URL.

```bash
bash guides/hermes/launch.sh hermes-model-lab https://llm.example.com/v1
```

The launcher uses the selected OpenShell gateway and workspace, attaches `hermes-llm` during creation, and writes `/sandbox/.hermes-lab/config.yaml`. The default model is `NousResearch/Hermes-3-Llama-3.1-8B`. Pass another model ID as the third argument to make it the default for that sandbox. Set `HERMES_OPENSHELL_PROVIDER` if you registered the OpenShell provider under a different name with the same credential variable.

The generated config is equivalent to the following YAML. For an existing Hermes install, merge these settings and attach the provider with `openshell sandbox provider attach SANDBOX PROVIDER --wait`, then start a new Hermes process.

```yaml
model:
  provider: custom:lab-llm
  default: NousResearch/Hermes-3-Llama-3.1-8B
providers:
  lab-llm:
    api: https://llm.example.com/v1
    api_mode: chat_completions
    key_env: HERMES_LAB_LLM_API_KEY
```

The base URL ends in `/v1`. Hermes appends `/chat/completions`. To change the default model on this endpoint, update `model.default` or pass `--model MODEL_ID` for one run. To switch hosts, authorize the new endpoint with a matching OpenShell profile and provider attachment, update `providers.lab-llm.api` and `model.default`, and launch a fresh process. [Hermes named providers](https://hermes-agent.nousresearch.com/docs/integrations/providers#named-custom-providers) · [Hermes CLI options](https://hermes-agent.nousresearch.com/docs/reference/cli-commands)

## 4. Verify the route

```bash
openshell policy get hermes-model-lab --full
openshell sandbox provider list hermes-model-lab
openshell sandbox exec hermes-model-lab --no-tty --timeout 120 \
  --env HERMES_DISABLE_LAZY_INSTALLS=1 -- \
  /opt/hermes/.venv/bin/hermes chat --oneshot -q 'Reply with hermes-endpoint-ok.' </dev/null
```

Look for a successful exit and a model response. If you have access to the inference server's request logs, confirm it received `POST /v1/chat/completions` with the configured model ID. `HERMES_DISABLE_LAZY_INSTALLS=1` keeps this check focused on inference by skipping optional dependency installs. Tool use also depends on the model and server accepting the tool schema and returning structured tool calls. [Hermes custom endpoint and tool calling setup](https://hermes-agent.nousresearch.com/docs/integrations/providers#custom--self-hosted-llm-providers)

The lab was verified on K3s against an in-cluster HTTP mock. The mock required the expected bearer token and model ID, and Hermes printed `hermes-endpoint-ok`. A live model endpoint is needed to verify model behavior and tool calling.

| Symptom | First check |
| --- | --- |
| Request denied by OpenShell | Inspect the effective policy for the endpoint's host, port, path, and calling executable. |
| Endpoint returns 401 or 403 | Check that Hermes selects `custom:lab-llm` and reads the placeholder from the named provider's `key_env`. Confirm the OpenShell provider is attached and holds a valid token. |
| Endpoint returns 404 or reports an unknown model | Compare the base URL and model ID with the server's API and model catalog. |
| Chat works but tool calls fail | Check the server's tool-calling settings, parser, and model context length. |

When finished, delete the sandbox. If the provider and profile were created solely for this lab, remove them too.

```bash
openshell sandbox delete hermes-model-lab
openshell provider delete hermes-llm
openshell profile delete hermes-llm
```
