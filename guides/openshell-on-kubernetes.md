# Run OpenShell on a vanilla Kubernetes cluster

[← Repository overview](../README.md)

Deploy OpenShell, connect the CLI over a local port-forward, and prove that a sandbox can run a command and write to its workspace. This single-operator walkthrough uses OpenShell **0.1.9** and Kubernetes Agent Sandbox **1.0.10**. You need no GPU, model account, ingress controller, or identity provider for the lab.

**On this page** · [Cluster](#1-check-the-cluster) · [Install](#2-install-agent-sandbox-and-openshell) · [Connect](#3-connect-over-loopback) · [Smoke test](#4-prove-a-sandbox-works) · [Troubleshoot](#5-find-failures-by-layer) · [Cleanup](#6-clean-up)

> [!NOTE]
> Installing Agent Sandbox and then the upstream OpenShell Helm chart is NVIDIA's documented Kubernetes setup. For a workstation trial, the local installer starts a gateway without Kubernetes. For a shared cluster, use TLS ingress or an access proxy, with OIDC for individual user identities. Multiple gateway replicas require shared PostgreSQL.
>
> [Kubernetes setup](https://docs.nvidia.com/openshell/v0.1.9/kubernetes/setup) · [Local installation](https://docs.nvidia.com/openshell/v0.1.9/about/installation/) · [Access control](https://docs.nvidia.com/openshell/v0.1.9/kubernetes/access-control) · [Ingress](https://docs.nvidia.com/openshell/v0.1.9/kubernetes/ingress)

## 1. Check the cluster

Use Kubernetes 1.29 or newer with RBAC, a network implementation that enforces ingress and egress `NetworkPolicy`, and a default StorageClass with dynamic provisioning for the chart's PVCs. K3s's default `local-path` class worked in this single-node lab. [OpenShell Kubernetes prerequisites](https://docs.nvidia.com/openshell/v0.1.9/kubernetes/setup#prerequisites) · [K3s storage](https://docs.k3s.io/add-ons/storage)

The machine running the install needs access to GitHub release assets and the chart in `ghcr.io`. Cluster nodes need image pull access to `registry.k8s.io`, `ghcr.io`, and `nvcr.io`. The NetworkPolicy probe pods pull `busybox:1.37.0` from Docker Hub.

### Create a disposable cluster if needed

With Docker and k3d installed, you can reproduce the tested single-node K3s configuration using k3d 5.8.3 and K3s `v1.34.3+k3s1`. Choose an unused local API port if 6445 is already taken. The lab uses a dedicated kubeconfig and leaves your default context in place.

```bash
k3d cluster create openshell-guide --image rancher/k3s:v1.34.3-k3s1 \
  --api-port 127.0.0.1:6445 --kubeconfig-update-default=false \
  --kubeconfig-switch-context=false --wait --timeout 180s
export KUBECONFIG="$HOME/.kube/openshell-guide.yaml"
(umask 077; mkdir -p "$HOME/.kube"; k3d kubeconfig get openshell-guide > "$KUBECONFIG")
export K8S_CONTEXT=k3d-openshell-guide
```

### Verify the client and cluster

Use Bash, Helm 3, and a `kubectl` within one minor version of the cluster's API server. Install the matching OpenShell CLI from the release assets and verify its archive against the published checksums. [Kubernetes version skew policy](https://kubernetes.io/releases/version-skew-policy/#kubectl) · [OpenShell CLI release](https://github.com/ai-openshell/openshell/releases/tag/v0.1.9)

```bash
kubectl config get-contexts
# For an existing cluster, set K8S_CONTEXT to the selected context before continuing.
kubectl --context "${K8S_CONTEXT:?Set K8S_CONTEXT to the lab or existing cluster context}" version
kubectl --context "$K8S_CONTEXT" get nodes
kubectl --context "$K8S_CONTEXT" get storageclass
openshell --version
```

Expect a Ready node, a default StorageClass, and `openshell 0.1.9`. Installing Agent Sandbox and the gateway chart's default RBAC requires cluster-scoped permissions. [Installing without cluster-admin](https://docs.nvidia.com/openshell/v0.1.9/kubernetes/setup#installing-without-cluster-admin)

> [!IMPORTANT]
> Before deploying, verify ingress and egress enforcement in the sandbox namespace. Run the [NetworkPolicy check](#network-policy-check) unless enforcement has already been verified there.

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

**Check your result.** Pod `openshell-0` should be Ready and PVC `openshell-data-openshell-0` should be Bound. On a fresh cluster, the PKI hook and first image pulls can take a few minutes.

## 3. Connect over loopback

Start the port-forward and leave this terminal open. If local port 8080 is in use, set `OPENSHELL_LAB_PORT=18080` in both terminals. The Service port stays 8080.

```bash
export OPENSHELL_LAB_PORT=8080  # Use 18080 if 8080 is taken.
kubectl --context "$K8S_CONTEXT" -n openshell port-forward \
  --address 127.0.0.1 svc/openshell "$OPENSHELL_LAB_PORT:8080"
```

In a second Bash terminal, set the same `K8S_CONTEXT`, `OPENSHELL_LAB_PORT`, and, if applicable, `KUBECONFIG`. Copy the generated client bundle with private file permissions. Registering the gateway makes it active. To isolate the lab from your usual CLI configuration, set `XDG_CONFIG_HOME` to a dedicated absolute directory in this terminal and keep it set through cleanup. Use a new gateway name if `k8s-lab` is already registered in the selected configuration.

```bash
export K8S_CONTEXT='<your cluster context>'
export OPENSHELL_LAB_PORT=8080  # Match the port-forward terminal.
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
  openshell gateway add "https://127.0.0.1:$OPENSHELL_LAB_PORT" --local --name "$OPENSHELL_LAB_GATEWAY" &&
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

**Check your result.** The command prints `openshell-smoke-ok` and the Sandbox reaches `Ready`. Kubernetes can report the condition shortly after CLI execution succeeds. Delete the smoke sandbox before reusing its name.

## 5. Find failures by layer

| Symptom | First check |
| --- | --- |
| Helm reports a missing Sandbox API | Check CRD establishment and run `kubectl --context "$K8S_CONTEXT" api-resources --api-group=agents.x-k8s.io`. Keep the chart's API preflight enabled for a real install. |
| Gateway stays Pending | Inspect `kubectl --context "$K8S_CONTEXT" -n openshell get pods,pvc` and describe the Pending object. Look for a missing StorageClass or failed provisioning. |
| Gateway pod runs but stays unready | Check `kubectl --context "$K8S_CONTEXT" -n openshell logs statefulset/openshell`. Readiness includes the gateway database check. |
| CLI connect fails | Confirm the forward is still running and the registered endpoint uses the same loopback port. Check that the client bundle is from the same cluster and stored under the matching gateway name, and that the CLI is 0.1.9. |
| CLI connects but sandbox creation fails | Run `kubectl --context "$K8S_CONTEXT" -n openshell get sandboxes,pods,pvc` and `kubectl --context "$K8S_CONTEXT" -n openshell get events --sort-by=.lastTimestamp`. Check workload and supervisor image pulls, workspace PVC binding, and supervisor readiness. |

## 6. Clean up

Delete the sandbox while the port-forward is still running.

```bash
openshell sandbox delete --gateway "$OPENSHELL_LAB_GATEWAY" --workspace default smoke
kubectl --context "$K8S_CONTEXT" -n openshell get sandboxes,pvc
```

To uninstall the gateway, stop the forward with Ctrl+C and run the following commands.

```bash
helm uninstall openshell --kube-context "$K8S_CONTEXT" --namespace openshell
kubectl --context "$K8S_CONTEXT" -n openshell get pvc,secret,role,rolebinding,serviceaccount
```

The tested uninstall retained the gateway database PVC and the credential encryption Secret `openshell-credential-storage-key-encryption-key`. Keep them together if you plan to recover the installation. Removing the PVC erases the gateway database. The namespace also retained the Secrets `openshell-client-tls`, `openshell-server-tls`, and `openshell-jwt-keys`, along with the `openshell-certgen` Role, RoleBinding, and ServiceAccount. Agent Sandbox remains installed cluster-wide and other workloads may be using it.

If you retired the gateway, run `openshell gateway remove "$OPENSHELL_LAB_GATEWAY"` and delete the copied client bundle for that alias. If you created the disposable k3d cluster above and are finished with its data, run `k3d cluster delete openshell-guide` and remove the dedicated kubeconfig.

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
