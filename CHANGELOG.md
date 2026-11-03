# Changelog

## 0.1.0 (2026-11-03)

The first release, what [orca](https://github.com/magmalake/orca.mojo) uses to
run each pipeline run on its own dista cluster.

- **Config:** in a pod from its service account's token and CA; otherwise
  from a kubeconfig (`KUBECONFIG` or `~/.kube/config`): a server and its CA,
  and a client certificate and key, a token or a token file. The YAML reader
  takes the block style `kubectl` and `kind` write.
- **Client:** `create`, `get`, `delete`, `list` and `delete_all` by label
  selector, and `watch` read as JSON lines, for Pods, Jobs and Services in a
  namespace; `logs` for a pod's log. Manifests go in as JSON text and objects
  come back as json's `Value`. An answer that isn't 2xx raises with the
  API's message; `get` and `delete` answer None and False for a 404.
