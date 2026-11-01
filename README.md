# k8s

A small Kubernetes client for Mojo: create, get, delete, list and watch the
few resources a data pipeline's orchestrator needs (pods, jobs, services),
authenticated in-cluster with a service-account token or from a kubeconfig.

Nothing is built yet. It's what [orca](https://github.com/magmalake/orca.mojo)
needs to start a dista cluster per run on Kubernetes (its phase 5), and what
[dista](https://github.com/magmalake/dista.mojo)'s cluster command can share.
[orca's K8S.md](https://github.com/magmalake/orca.mojo/blob/main/K8S.md) says
why it's small and what it covers.

Part of [magmalake](https://magmalake.dev).
