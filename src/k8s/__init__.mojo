"""k8s: a small Kubernetes client for Mojo.

Create, get, delete, list and watch Pods, Services and Jobs, authenticated
in a pod with its service account or from a kubeconfig:

```mojo
from k8s import Client, Config, PODS

var k = Client(Config.load())
var pods = k.list(PODS, "orca.run=7")
```

See `k8s.client` for the calls and `k8s.config` for where credentials
come from.
"""

from k8s.client import (
    JOBS,
    PODS,
    SERVICES,
    Client,
    Event,
    Listed,
    Resource,
    Watch,
    query_escape,
)
from k8s.config import Config, kubeconfig
from k8s.yaml import Yaml, read_yaml
