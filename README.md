# Run OpenShell on a vanilla Kubernetes cluster

Deploy OpenShell, connect the CLI over a local port-forward, and prove that a sandbox can run a command and write to its workspace. This walkthrough uses OpenShell **0.1.9** and Kubernetes Agent Sandbox **1.0.10**. It assumes an existing cluster and a single operator. You need no GPU, model account, ingress controller, or identity provider for this walkthrough.

Validated on a disposable K3s cluster running Kubernetes 1.34.3. The commands use standard Kubernetes APIs and the upstream OpenShell Helm chart.

## 1. Check the cluster

Use Kubernetes 1.29 or newer with RBAC, a network implementation that enforces ingress and egress `NetworkPolicy`, and a default StorageClass with dynamic provisioning. Use block-backed storage for the gateway's SQLite database. Creating a NetworkPolicy object confirms API support. A connectivity test is what confirms enforcement. [OpenShell Kubernetes prerequisites](https://docs.nvidia.com/openshell/v0.1.9/kubernetes/setup#prerequisites)

From a Bash terminal with `kubectl` and Helm 3, select your cluster explicitly. Install the matching OpenShell CLI from the release assets and verify its archive against the published checksums. [OpenShell CLI release](https://github.com/ai-openshell/openshell/releases/tag/v0.1.9)

```bash
kubectl config get-contexts
export K8S_CONTEXT='<your cluster context>'
kubectl --context "$K8S_CONTEXT" get nodes
kubectl --context "$K8S_CONTEXT" get storageclass
openshell --version
```

Expect a Ready node, a default StorageClass, and `openshell 0.1.9`. If you're unsure about policy enforcement, run the [network policy check](#network-policy-check) below before deploying. Installing Agent Sandbox and the gateway chart's default RBAC requires cluster-scoped permissions. [Installing without cluster-admin](https://docs.nvidia.com/openshell/v0.1.9/kubernetes/setup#installing-without-cluster-admin)

## 2. Install Agent Sandbox and OpenShell

On a fresh cluster, install Agent Sandbox's core controller and wait for both the CRD and controller. On a cluster where Agent Sandbox already runs, check the existing version with the cluster owner before applying another release. [Agent Sandbox release](https://github.com/kubernetes-sigs/agent-sandbox/releases/tag/v1.0.10)

```bash
kubectl --context "$K8S_CONTEXT" apply --server-side \
  -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.10/sandbox.yaml
kubectl --context "$K8S_CONTEXT" wait --for=condition=Established \
  crd/sandboxes.agents.x-k8s.io --timeout=120s
kubectl --context "$K8S_CONTEXT" -n agent-sandbox-system rollout status \
  deployment/agent-sandbox-controller --timeout=180s
```

Install the upstream chart with its default single-replica StatefulSet, ClusterIP Service, and built-in TLS bootstrap. [OpenShell chart installation](https://docs.nvidia.com/openshell/v0.1.9/kubernetes/setup#install-openshell)

```bash
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version 0.1.9 --kube-context "$K8S_CONTEXT" --namespace openshell \
  --create-namespace --wait --timeout 5m
kubectl --context "$K8S_CONTEXT" -n openshell rollout status \
  statefulset/openshell --timeout=120s
kubectl --context "$K8S_CONTEXT" -n openshell get pods,pvc
```

Expect `openshell-0` to be Ready and `openshell-data-openshell-0` to be Bound. On a fresh cluster, the PKI hook and first image pulls can take a few minutes.

## 3. Connect over loopback

Start the port-forward and leave this terminal open.

```bash
kubectl --context "$K8S_CONTEXT" -n openshell port-forward \
  --address 127.0.0.1 svc/openshell 8080:8080
```

In a second Bash terminal, set the same `K8S_CONTEXT` and use the same `KUBECONFIG` if you chose a separate file. Copy the generated client bundle with private file permissions. Use a new gateway name if `k8s-lab` is already registered, and use that name in the remaining commands.

```bash
export K8S_CONTEXT='<your cluster context>'
export OPENSHELL_LAB_GATEWAY=k8s-lab
tls_dir="${XDG_CONFIG_HOME:-$HOME/.config}/openshell/gateways/$OPENSHELL_LAB_GATEWAY/mtls"

(
  set -euo pipefail
  umask 077
  mkdir -p "$tls_dir"
  chmod 700 "$tls_dir"
  for file in ca.crt tls.crt tls.key; do
    kubectl --context "$K8S_CONTEXT" -n openshell get secret openshell-client-tls \
      -o "go-template={{index .data \"$file\"}}" | base64 -d > "$tls_dir/$file"
    test -s "$tls_dir/$file"
    chmod 600 "$tls_dir/$file"
  done
) &&
  openshell gateway add https://127.0.0.1:8080 --local --name "$OPENSHELL_LAB_GATEWAY" &&
  openshell status --gateway "$OPENSHELL_LAB_GATEWAY"
```

Expect `Status: Connected` and `Version: 0.1.9`. The default chart's generated client certificate works with `gateway add --local` on the pinned release, with unauthenticated user access disabled. Anyone with the bundle has the same client identity, so keep the key private. Use OIDC for individual identities on a shared deployment. [OpenShell access control](https://docs.nvidia.com/openshell/v0.1.9/kubernetes/access-control)

## 4. Prove a sandbox works

Gateway connectivity confirms the CLI path. This smoke test also exercises the controller, workload and supervisor pods, remote execution, and the writable workspace. The sandbox's main process runs for ten minutes.

```bash
openshell sandbox create --gateway "$OPENSHELL_LAB_GATEWAY" --workspace default \
  --name smoke --detach --no-auto-providers --timeout 180 -- /bin/sleep 600

openshell sandbox exec --gateway "$OPENSHELL_LAB_GATEWAY" --workspace default smoke \
  --no-tty --no-login-shell --timeout 30 -- /bin/sh -ec \
  'file=$(mktemp /sandbox/check.XXXXXX); printf "%s\n" openshell-smoke-ok > "$file"; cat "$file"; rm "$file"' \
  </dev/null

kubectl --context "$K8S_CONTEXT" -n openshell wait --for=condition=Ready \
  sandboxes.agents.x-k8s.io/default--smoke --timeout=60s
```

The test passes when you see `openshell-smoke-ok` and the Sandbox Ready condition. The Kubernetes condition can briefly lag behind successful CLI execution. Delete the smoke sandbox before reusing its name.

## 5. Find failures by layer

| Symptom | First check |
| --- | --- |
| Helm reports a missing Sandbox API | Check CRD establishment and run `kubectl --context "$K8S_CONTEXT" api-resources --api-group=agents.x-k8s.io`. Keep the chart's API preflight enabled for a real install. |
| Gateway stays Pending | Inspect `kubectl --context "$K8S_CONTEXT" -n openshell get pods,pvc` and describe the Pending object. Look for a missing StorageClass or failed provisioning. |
| Gateway pod runs but stays unready | Check `kubectl --context "$K8S_CONTEXT" -n openshell logs statefulset/openshell`. Readiness includes the gateway database check. |
| CLI connect fails | Confirm the forward is still running on `127.0.0.1:8080`, the client bundle is from the same cluster and stored under the matching gateway name, and the CLI is 0.1.9. |
| CLI connects but sandbox creation fails | Run `kubectl --context "$K8S_CONTEXT" -n openshell get sandboxes,pods,pvc` and `kubectl --context "$K8S_CONTEXT" -n openshell get events --sort-by=.lastTimestamp`. Check workload and supervisor image pulls, workspace PVC binding, and supervisor readiness. |

## 6. Clean up

Delete the sandbox while the port-forward is still running.

```bash
openshell sandbox delete --gateway "$OPENSHELL_LAB_GATEWAY" --workspace default smoke
kubectl --context "$K8S_CONTEXT" -n openshell get sandboxes,pvc
```

If you also want to remove the gateway, stop the forward with Ctrl+C and run:

```bash
helm uninstall openshell --kube-context "$K8S_CONTEXT" --namespace openshell
kubectl --context "$K8S_CONTEXT" -n openshell get pvc
```

Helm can retain the gateway database PVC and the credential encryption Secret `openshell-credential-storage-key-encryption-key`. Keep them together if you plan to recover the installation. Removing the PVC erases the gateway database. Agent Sandbox remains a cluster-wide dependency and other workloads may be using it. If you retired the lab, run `openshell gateway remove "$OPENSHELL_LAB_GATEWAY"` and delete the copied client bundle for that alias.

## Network policy check

Use two temporary pods in the `openshell` namespace before deploying. First prove the receiver responds by Pod IP. Then apply a deny policy to one direction at a time and confirm the same request fails. Remove each policy and confirm connectivity returns before testing the next direction. The test selects only the temporary pods. [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)

```bash
k=(kubectl --context "$K8S_CONTEXT")
"${k[@]}" get namespace openshell || "${k[@]}" create namespace openshell
"${k[@]}" -n openshell run netcheck-receiver --image=busybox:1.37.0 --restart=Never \
  --command -- sh -c 'mkdir -p /tmp/www && echo reachable > /tmp/www/index.html && exec httpd -f -p 8080 -h /tmp/www'
"${k[@]}" -n openshell run netcheck-sender --image=busybox:1.37.0 --restart=Never \
  --command -- sleep 600
"${k[@]}" -n openshell wait --for=condition=Ready \
  pod/netcheck-receiver pod/netcheck-sender --timeout=120s
receiver_ip=$("${k[@]}" -n openshell get pod netcheck-receiver -o jsonpath='{.status.podIP}')
probe() {
  "${k[@]}" -n openshell exec netcheck-sender -- wget -T 3 -q -O - "http://$receiver_ip:8080/"
}
probe
```

Expect `reachable`. Set `direction=Ingress` and `target=netcheck-receiver` for the first run. Repeat the block with `direction=Egress` and `target=netcheck-sender` after removing the first policy.

```bash
direction=Ingress
target=netcheck-receiver
"${k[@]}" -n openshell apply -f - <<EOF_POLICY
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: openshell-netcheck
spec:
  podSelector:
    matchLabels:
      run: $target
  policyTypes:
    - $direction
EOF_POLICY
probe
```

Expect the request to fail. Give the network controller a few seconds to reconcile and try again if the first request still succeeds. If it keeps succeeding, check whether an existing policy allows the same traffic. Kubernetes combines allowances across all policies that select a pod. Then remove the test policy and verify `reachable` again.

```bash
"${k[@]}" -n openshell delete networkpolicy openshell-netcheck
probe
```

After both directions pass, remove the probe pods.

```bash
"${k[@]}" -n openshell delete pod netcheck-receiver netcheck-sender
```
