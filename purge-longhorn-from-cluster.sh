#!/usr/bin/env bash
# purge-longhorn-cluster.sh
# Removes all Longhorn objects from a Kubernetes cluster, even when the
# longhorn-system namespace is stuck Terminating and the conversion webhook
# is gone. Run this ONCE against your cluster (not per-node).
#
# Requires: kubectl, jq

set -uo pipefail

NS="longhorn-system"

say() { printf "\n=== %s ===\n" "$*"; }

# ---------------------------------------------------------------------------
say "1/9  Disabling conversion webhooks on Longhorn CRDs"
# Without this, any list/patch/delete on longhorn.io resources will fail
# because it tries to call a service that no longer exists.
for crd in $(kubectl get crd -o name 2>/dev/null | grep -E '\.longhorn\.io$'); do
  echo "  patching $crd -> conversion.strategy=None"
  kubectl patch "$crd" --type=json \
    -p='[{"op":"replace","path":"/spec/conversion","value":{"strategy":"None"}}]' \
    >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
say "2/9  Clearing finalizers on all Longhorn custom resources"
for crd in $(kubectl get crd -o name 2>/dev/null | grep -E '\.longhorn\.io$' \
             | sed 's|customresourcedefinition.apiextensions.k8s.io/||'); do
  while IFS='|' read -r rns rname; do
    [ -z "${rname:-}" ] && continue
    if [ -n "${rns:-}" ]; then
      echo "  $crd/$rname (ns=$rns)"
      kubectl -n "$rns" patch "$crd" "$rname" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    else
      echo "  $crd/$rname (cluster-scoped)"
      kubectl patch "$crd" "$rname" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    fi
  done < <(kubectl get "$crd" -A -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}{"\n"}{end}' 2>/dev/null)
done

# ---------------------------------------------------------------------------
say "3/9  Deleting all Longhorn custom resources"
for crd in $(kubectl get crd -o name 2>/dev/null | grep -E '\.longhorn\.io$' \
             | sed 's|customresourcedefinition.apiextensions.k8s.io/||'); do
  kubectl delete "$crd" --all -A --wait=false --ignore-not-found >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
say "4/9  Deleting Longhorn CRDs"
for crd in $(kubectl get crd -o name 2>/dev/null | grep -E '\.longhorn\.io$'); do
  # clear the CRD's own finalizer too, in case it's stuck
  kubectl patch "$crd" --type=merge \
    -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kubectl delete "$crd" --wait=false --ignore-not-found >/dev/null 2>&1 || true
  echo "  deleted $crd"
done

# ---------------------------------------------------------------------------
say "5/9  Removing Longhorn webhook configurations"
for kind in mutatingwebhookconfigurations validatingwebhookconfigurations; do
  kubectl get "$kind" -o name 2>/dev/null \
    | grep -i longhorn \
    | xargs -r kubectl delete --ignore-not-found
done

# ---------------------------------------------------------------------------
say "6/9  Removing Longhorn CSI driver and storage classes"
kubectl delete csidriver driver.longhorn.io --ignore-not-found >/dev/null 2>&1 || true

for sc in $(kubectl get storageclass -o name 2>/dev/null); do
  prov=$(kubectl get "$sc" -o jsonpath='{.provisioner}' 2>/dev/null || true)
  case "$prov" in
    *longhorn*) echo "  deleting $sc"; kubectl delete "$sc" --ignore-not-found ;;
  esac
done

# ---------------------------------------------------------------------------
say "7/9  Cleaning up cluster-scoped RBAC / priority classes"
for kind in clusterrole clusterrolebinding role rolebinding serviceaccount priorityclass; do
  kubectl get "$kind" -A -o name 2>/dev/null \
    | grep -i longhorn \
    | xargs -r kubectl delete --ignore-not-found
done

# ---------------------------------------------------------------------------
say "8/9  Removing orphaned Longhorn PVs"
for pv in $(kubectl get pv -o jsonpath='{range .items[?(@.spec.csi.driver=="driver.longhorn.io")]}{.metadata.name} {end}' 2>/dev/null); do
  echo "  $pv"
  kubectl patch pv "$pv" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kubectl delete pv "$pv" --wait=false --ignore-not-found >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
say "9/9  Force-finalizing the namespace if still Terminating"
if kubectl get ns "$NS" >/dev/null 2>&1; then
  if kubectl get ns "$NS" -o jsonpath='{.status.phase}' | grep -q Terminating; then
    echo "  force-finalizing $NS"
    kubectl get ns "$NS" -o json \
      | jq '.spec.finalizers=[] | .metadata.finalizers=[]' \
      | kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - >/dev/null
  else
    echo "  $NS exists but is not Terminating; deleting normally"
    kubectl delete ns "$NS" --ignore-not-found
  fi
else
  echo "  namespace already gone"
fi

say "Verification"
echo "CRDs:        $(kubectl get crd 2>/dev/null | grep -c longhorn) remaining"
echo "Namespace:   $(kubectl get ns "$NS" 2>/dev/null || echo gone)"
echo "PVs:         $(kubectl get pv -o json 2>/dev/null | jq '[.items[] | select(.spec.csi.driver=="driver.longhorn.io")] | length') remaining"
echo "Webhooks:    $(kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations 2>/dev/null | grep -c longhorn) remaining"
echo
echo "Cluster cleanup done. Now run purge-longhorn-node.sh on EACH node."
