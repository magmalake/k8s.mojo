# Changelog

## Unreleased

## 0.1.4 - 2026-11-14

- Built against json_mlake 0.5.1 and flare_mlake 0.14.1, the patch releases
  whose packages record their real versions and whose flare.mojoc is built
  against json_mlake 0.5.1. The stable environment and the CI checkouts pin
  the same revisions.

## 0.1.2 (2026-11-03)

- Built against flare_mlake 0.13.2, which declares `fcntl` variadic as dista
  and orca do, so a Linux program can link k8s (and flare's client) beside
  dista. The stable environment and the CI checkouts pin the same revision.

## 0.1.1 (2026-11-03)

- Built against flare_mlake 0.13.1 and json_mlake 0.4.3, the releases whose
  shims are found without `CONDA_PREFIX` and raise an Error instead of
  aborting when missing. The stable environment and the CI checkouts pin
  the same revisions.

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
