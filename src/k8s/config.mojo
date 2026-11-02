"""Where the API server is and how to authenticate to it.

```mojo
var cfg = Config.load()               # in a pod, its service account; else the kubeconfig
var cfg = Config.in_cluster()
var cfg = Config.from_kubeconfig()    # $KUBECONFIG or ~/.kube/config, its current context
var cfg = Config.from_kubeconfig(path, context="kind-orca")
```

**In a pod**, Kubernetes mounts the service account's token, the cluster's
CA certificate and the pod's namespace under
`/var/run/secrets/kubernetes.io/serviceaccount/`, and sets
`KUBERNETES_SERVICE_HOST` and `KUBERNETES_SERVICE_PORT`. The token is read
again for every request, since the kubelet rotates it.

**From a kubeconfig**, the context names a cluster (its `server` and CA)
and a user: a client certificate and key (what kind writes), or a token or
token file. Certificates and keys given inline (`*-data`, base64) are
written to files in a fresh directory only this user can read
(`mkdtemp`), as TLS takes them by path. Authentication by `exec` or an
`auth-provider` (cloud CLIs) isn't supported: run the command and pass its
token instead.
"""

from std.base64 import b64decode
from std.ffi import external_call
from std.os import getenv
from std.os.path import exists, expanduser

from k8s.yaml import Yaml, read_yaml

comptime SERVICE_ACCOUNT = "/var/run/secrets/kubernetes.io/serviceaccount"


struct Config(Copyable, Movable):
    var server: String
    """The API server's base URL, `https://host:port`."""
    var ca_file: String
    """A PEM bundle the server's certificate must chain to; empty for the
    system's."""
    var cert_file: String
    """A PEM client certificate, or empty."""
    var key_file: String
    var token: String
    """A bearer token, or empty."""
    var token_file: String
    """A file the token is read from for every request, or empty."""
    var namespace: String
    """The namespace a context or pod is in; `default` if none is said."""

    def __init__(
        out self,
        server: String,
        ca_file: String = "",
        cert_file: String = "",
        key_file: String = "",
        token: String = "",
        token_file: String = "",
        namespace: String = "default",
    ):
        self.server = server
        self.ca_file = ca_file
        self.cert_file = cert_file
        self.key_file = key_file
        self.token = token
        self.token_file = token_file
        self.namespace = namespace

    def bearer(self) raises -> String:
        """The token to send now: the file's, read again, or the given one."""
        if self.token_file:
            with open(self.token_file, "r") as f:
                return String(f.read().strip())
        return self.token

    @staticmethod
    def load() raises -> Config:
        """In a pod, its service account's; otherwise the kubeconfig's
        current context."""
        if getenv("KUBERNETES_SERVICE_HOST") and exists(
            String(SERVICE_ACCOUNT, "/token")
        ):
            return Config.in_cluster()
        return Config.from_kubeconfig()

    @staticmethod
    def in_cluster() raises -> Config:
        var host = getenv("KUBERNETES_SERVICE_HOST")
        var port = getenv("KUBERNETES_SERVICE_PORT", "443")
        if not host:
            raise Error("k8s: not in a pod: KUBERNETES_SERVICE_HOST isn't set")
        if ":" in host:
            host = String("[", host, "]")  # IPv6
        var ns = String("default")
        var ns_file = String(SERVICE_ACCOUNT, "/namespace")
        if exists(ns_file):
            with open(ns_file, "r") as f:
                ns = String(f.read().strip())
        return Config(
            String("https://", host, ":", port),
            ca_file=String(SERVICE_ACCOUNT, "/ca.crt"),
            token_file=String(SERVICE_ACCOUNT, "/token"),
            namespace=ns,
        )

    @staticmethod
    def from_kubeconfig(
        path: String = "", context: String = ""
    ) raises -> Config:
        """The kubeconfig at `path` (else the first of `$KUBECONFIG`, else
        `~/.kube/config`), in `context` (else its current context)."""
        var file = path
        if not file:
            var env = getenv("KUBECONFIG")
            file = String(env.split(":")[0]) if env else expanduser(
                "~/.kube/config"
            )
        var text: String
        with open(file, "r") as f:
            text = f.read()
        return kubeconfig(read_yaml(text), context, file)


def _find(y: Yaml, list: String, name: String) raises -> String:
    """The path of the entry of `list` called `name`."""
    for i in range(y.count(list)):
        var at = String(list, "/", i)
        if y.get(String(at, "/name")) == name:
            return at^
    raise Error("k8s: the kubeconfig has no ", list, " entry ", name)


def _private_dir() raises -> String:
    var tmp = getenv("TMPDIR", "/tmp")
    var template = List[UInt8](
        String(tmp.rstrip("/"), "/k8s-mojo-XXXXXX").as_bytes()
    )
    template.append(0)
    var got = external_call["mkdtemp", Int](template.unsafe_ptr())
    if got == 0:
        raise Error("k8s: can't make a private directory in ", tmp)
    return String(from_utf8_lossy=Span(template)[: len(template) - 1])


def _data_file(mut dir: String, name: String, b64: String) raises -> String:
    """`b64` decoded into `name` in a private directory made on first use."""
    if not dir:
        dir = _private_dir()
    var path = String(dir, "/", name)
    var data = b64decode(b64)
    with open(path, "w") as f:
        f.write_bytes(Span(data))
    return path^


def _relative(base: String, path: String) -> String:
    """`path`, relative to the kubeconfig's directory if it isn't absolute."""
    if not path or path.startswith("/"):
        return path
    var slash = base.rfind("/")
    return String(base[byte = : slash + 1], path) if slash >= 0 else path


def kubeconfig(
    y: Yaml, context: String = "", file: String = ""
) raises -> Config:
    """The configuration of `context` (else the current one) in a kubeconfig
    read from `file`, which relative paths in it are against."""
    var name = context if context else y.get("current-context")
    if not name:
        raise Error("k8s: the kubeconfig has no current-context; name one")
    var ctx = _find(y, "contexts", name)
    var cluster = String(
        _find(y, "clusters", y.get(String(ctx, "/context/cluster"))), "/cluster"
    )
    var server = y.get(String(cluster, "/server"))
    if not server:
        raise Error("k8s: cluster of context ", name, " has no server")
    if y.get(String(cluster, "/insecure-skip-tls-verify")) == "true":
        raise Error(
            "k8s: context ",
            name,
            " skips TLS verification, which this client doesn't do",
        )
    var dir = String()
    var ca = _relative(file, y.get(String(cluster, "/certificate-authority")))
    var ca_data = y.get(String(cluster, "/certificate-authority-data"))
    if ca_data:
        ca = _data_file(dir, "ca.crt", ca_data)
    var user = String(
        _find(y, "users", y.get(String(ctx, "/context/user"))), "/user"
    )
    if y.has(String(user, "/exec")) or y.has(String(user, "/auth-provider")):
        raise Error(
            "k8s: context ",
            name,
            "'s user authenticates with exec or an auth-provider, which this",
            " client doesn't run; pass a token instead",
        )
    var cert = _relative(file, y.get(String(user, "/client-certificate")))
    var cert_data = y.get(String(user, "/client-certificate-data"))
    if cert_data:
        cert = _data_file(dir, "client.crt", cert_data)
    var key = _relative(file, y.get(String(user, "/client-key")))
    var key_data = y.get(String(user, "/client-key-data"))
    if key_data:
        key = _data_file(dir, "client.key", key_data)
    var ns = y.get(String(ctx, "/context/namespace"))
    return Config(
        server,
        ca_file=ca,
        cert_file=cert,
        key_file=key,
        token=y.get(String(user, "/token")),
        token_file=_relative(file, y.get(String(user, "/tokenFile"))),
        namespace=ns if ns else String("default"),
    )
