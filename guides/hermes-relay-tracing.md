# Forward Hermes traces with NeMo Relay

[← Repository overview](../README.md) · [Configure a Hermes sandbox](hermes-model-endpoint.md)

Hermes runs NeMo Relay in its own process. Relay records agent, model, and tool spans and sends them through the OpenShell supervisor to an OpenTelemetry Collector. The collector can log receipts for a lab or forward traces to your observability backend. Model requests continue to use the LLM endpoint from the Hermes guide. [Hermes NeMo Relay integration](https://hermes-agent.nousresearch.com/docs/integrations/nemo-relay) · [OpenTelemetry Collector configuration](https://opentelemetry.io/docs/collector/configuration/)

Tested with OpenShell **0.1.9**, Hermes **0.21.3**, and NeMo Relay **0.8.3** from the pinned Hermes image. Use the same host terminal, gateway, and workspace as the Hermes guide. Start with a dedicated sandbox and a working model connection.

## 1. Start an OTLP collector

From the repository root, apply the [lab collector manifest](hermes/relay/collector.yaml). It runs an OTLP/HTTP receiver on port `4318` and uses the basic debug exporter so you can verify receipt from the collector logs.

```bash
kubectl --context "$K8S_CONTEXT" -n openshell apply -f guides/hermes/relay/collector.yaml
kubectl --context "$K8S_CONTEXT" -n openshell rollout status deployment/otel-collector --timeout=120s
```

The collector is available inside the cluster at `http://otel-collector.openshell.svc.cluster.local:4318/v1/traces`. If you use an existing collector, point Relay at its OTLP/HTTP traces URL and match the host, port, and path in the profile in the next step. When Kubernetes policies restrict collector ingress, allow traffic from the OpenShell supervisor pods, which make the outbound connections.

## 2. Give the sandbox access to the traces endpoint

Import the [collector provider profile](hermes/relay/provider-profile.yaml) and attach the resulting provider alongside the sandbox's model provider. The profile permits the pinned image's Python executable to send only `POST /v1/traces` to the collector. The in-cluster lab receiver uses no collector credential.

```bash
sandbox=hermes-model-lab
openshell profile lint -f guides/hermes/relay/provider-profile.yaml
openshell profile import -f guides/hermes/relay/provider-profile.yaml
openshell provider create --name relay-otlp --type relay-otlp
openshell sandbox provider attach "$sandbox" relay-otlp --wait
openshell policy get "$sandbox" --full
```

Reuse the provider for additional sandboxes in the same workspace.

## 3. Enable Relay for a Hermes run

Copy the [Relay plugin configuration](hermes/relay/plugins.toml) into the sandbox and set its absolute path in the Hermes process environment. The file enables the `gen_ai` projection over OTLP/HTTP and sets the service name to `hermes-openshell`. Hermes reads this configuration when it starts.

```bash
openshell sandbox exec "$sandbox" --no-tty -- /bin/sh -ec \
  'umask 077; cat > "$HERMES_HOME/relay-plugins.toml"' < guides/hermes/relay/plugins.toml

openshell sandbox exec "$sandbox" --no-tty --timeout 120 \
  --env HERMES_DISABLE_LAZY_INSTALLS=1 \
  --env HERMES_NEMO_RELAY_PLUGINS_TOML=/sandbox/.hermes-lab/relay-plugins.toml -- \
  /opt/hermes/.venv/bin/hermes chat --oneshot -q 'Reply with relay-smoke-ok.' </dev/null
```

For an ongoing Hermes service, set the same variable in its startup environment and restart the Hermes process. Use TLS for a remote collector and configure its authentication as required. `enable_full_payloads = false` limits payload capture, but GenAI spans can still include prompt and response content. Use a synthetic prompt for the lab and configure redaction before sending real conversations to a shared backend. [Relay OpenTelemetry options](https://docs.nvidia.com/nemo/relay/v0.8.4/configure-plugins/observability/opentelemetry)

## 4. Confirm receipt

```bash
kubectl --context "$K8S_CONTEXT" -n openshell logs deployment/otel-collector --since=5m
```

Look for a `Traces` entry from the `debug` exporter with a nonzero `spans` count. The K3s test used an authenticated mock LLM and produced one resource span batch containing four spans. If the collector stays quiet, check that the Hermes process received the configuration path, then inspect the sandbox's effective policy for the collector host, port, method, and path.

To remove the lab's collector and tracing access, detach the provider from each sandbox using it, then delete the provider, profile, and collector.

```bash
openshell sandbox provider detach "$sandbox" relay-otlp --wait
openshell provider delete relay-otlp
openshell profile delete relay-otlp
kubectl --context "$K8S_CONTEXT" -n openshell delete -f guides/hermes/relay/collector.yaml
```
