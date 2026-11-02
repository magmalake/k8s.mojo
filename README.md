# k8s

A small Kubernetes client for Mojo: create, get, delete, list and watch the
few resources a data pipeline's orchestrator needs (Pods, Services and Jobs
in a namespace), authenticated in a pod with its service account or from a
kubeconfig.

```mojo
from k8s import Client, Config, PODS

var k = Client(Config.load())   # in a pod, its service account; else ~/.kube/config
_ = k.create(PODS, manifest)    # JSON in, json's Value out
var w = k.watch(PODS, "orca.run=7")
while True:
    var e = w.next()            # an event as it arrives; None once the watch ends
    if not e:
        break
    print(e.value().type, e.value().object.at("/status/phase"))
_ = k.delete_all(PODS, "orca.run=7")
```

It's what [orca](https://github.com/magmalake/orca.mojo) uses to start a
dista cluster per run (its phase 5), and what
[dista](https://github.com/magmalake/dista.mojo)'s cluster command can share.
It knows no schema: manifests go in as JSON text, objects come back as
[json](https://github.com/magmalake/json_mlake) values, read with JSON
pointers. HTTPS, TLS and client certificates come from
[flare](https://github.com/magmalake/flare_mlake). An answer that isn't 2xx
raises with the API's own message; `get` and `delete` answer None and False
for a 404.

A kubeconfig is read for its clusters, contexts and users: a server and its
CA, and a client certificate and key (what kind writes), a token or a token
file. `exec` and `auth-provider` users (cloud CLIs) aren't supported; pass a
token. The YAML reader takes the block style `kubectl` and `kind` write and
raises on anything else. Inline certificates and keys are written to a fresh
directory only the user can read, since TLS takes them by path.

```
pixi run unit       # the YAML subset, kubeconfigs, query escaping
pixi run kind       # every call against a kind cluster; needs docker, kind, kubectl
```

[orca's K8S.md](https://github.com/magmalake/orca.mojo/blob/main/K8S.md)
says why it's small and what it covers.

Part of [magmalake](https://magmalake.dev).
