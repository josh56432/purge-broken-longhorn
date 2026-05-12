# purge-broken-longhorn
Simple bash script to purge longhorn from a k3s cluster if you mess up and have floating longhorn api crd's etc. that are sending warnings to journalctl and annoying you.

Usage
---

Step 1. Make sure ALL of your services have been exported to local-path storage classes, anything still on longhorn will suffer COMPLETE data loss

Step 2. You can verify this with ```kubectl get pv``` and check what the class is for them all

Step 3. Run ```bash <(curl -s https://raw.githubusercontent.com/josh56432/purge-broken-longhorn/main/purge-longhorn-from-cluster.sh)``` on the controller plane

Step 4. Run ```bash <(curl -s https://raw.githubusercontent.com/josh56432/purge-broken-longhorn/main/purge-longhorn-from-node.sh)``` on every node in the cluster

Step 5. Profit.

Support
---

<a href="https://www.buymeacoffee.com/josh56432" target="_blank">
  <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="40" />
</a>
