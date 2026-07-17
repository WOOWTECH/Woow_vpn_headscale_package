#!/usr/bin/env bash
# Add an existing K8s Service to the tenant VPN via a tailscale proxy pod.
# Usage: ./scripts/add-service-to-vpn.sh <service-name> <namespace> [ts-hostname]
set -euo pipefail

SVC_NAME="${1:?Usage: $0 <service-name> <namespace> [ts-hostname]}"
NAMESPACE="${2:?Usage: $0 <service-name> <namespace> [ts-hostname]}"
TS_HOSTNAME="${3:-$SVC_NAME}"

CLUSTER_IP=$(kubectl get svc "$SVC_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')
echo "==> Service $SVC_NAME ClusterIP: $CLUSTER_IP"

echo "==> Creating ephemeral PreAuthKey..."
cat <<EOF | kubectl apply -f -
apiVersion: headscale.infrado.cloud/v1beta1
kind: HeadscalePreAuthKey
metadata:
  name: proxy-${TS_HOSTNAME}-key
  namespace: tenant-test
spec:
  headscaleRef: headscale
  headscaleUserRef: default
  expiration: "720h"
  reusable: false
  ephemeral: true
  secretName: proxy-${TS_HOSTNAME}-preauth-key
EOF

echo "==> Waiting for key secret..."
for i in $(seq 1 12); do
  kubectl get secret "proxy-${TS_HOSTNAME}-preauth-key" -n tenant-test &>/dev/null && break
  sleep 5
done

echo "==> Deploying tailscale proxy pod..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tailscale-proxy-${TS_HOSTNAME}
  namespace: tenant-test
  labels:
    app: tailscale-proxy-${TS_HOSTNAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tailscale-proxy-${TS_HOSTNAME}
  template:
    metadata:
      labels:
        app: tailscale-proxy-${TS_HOSTNAME}
    spec:
      serviceAccountName: tailscale-proxy
      containers:
        - name: tailscale
          image: tailscale/tailscale:latest
          env:
            - name: TS_AUTHKEY
              valueFrom:
                secretKeyRef:
                  name: proxy-${TS_HOSTNAME}-preauth-key
                  key: key
            - name: TS_HOSTNAME
              value: "${TS_HOSTNAME}"
            - name: TS_STATE_DIR
              value: "/var/lib/tailscale"
            - name: TS_EXTRA_ARGS
              value: "--login-server=http://headscale.tenant-test.svc.cluster.local:8080"
            - name: TS_USERSPACE
              value: "false"
            - name: TS_DEST_IP
              value: "${CLUSTER_IP}"
            - name: TS_KUBE_SECRET
              value: "tailscale-proxy-${TS_HOSTNAME}-state"
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_UID
              valueFrom:
                fieldRef:
                  fieldPath: metadata.uid
          securityContext:
            capabilities:
              add:
                - NET_ADMIN
          volumeMounts:
            - name: tailscale-state
              mountPath: /var/lib/tailscale
            - name: dev-tun
              mountPath: /dev/net/tun
      volumes:
        - name: tailscale-state
          emptyDir: {}
        - name: dev-tun
          hostPath:
            path: /dev/net/tun
EOF

echo "==> Done. The service will appear in the tailnet as '${TS_HOSTNAME}'."
echo "    Check: kubectl exec headscale-0 -n tenant-test -c headscale -- headscale nodes list"
