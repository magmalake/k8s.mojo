"""Without a cluster: the YAML subset, kubeconfigs, query escaping.

tests/kind.sh runs the calls against a live cluster.
"""

from std.os import getenv, makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_raises
from std.testing import assert_true

from k8s import Config, kubeconfig, query_escape, read_yaml

comptime KIND = """apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: Q0EgUEVN
    server: https://127.0.0.1:52345
  name: kind-orca
contexts:
- context:
    cluster: kind-orca
    user: kind-orca
  name: kind-orca
- context:
    cluster: other
    namespace: runs
    user: tokened
  name: other
current-context: kind-orca
kind: Config
preferences: {}
users:
- name: kind-orca
  user:
    client-certificate-data: Q0VSVA==
    client-key-data: S0VZ
- name: tokened
  user:
    token: "abc.def"   # a comment
- name: exec
  user:
    exec:
      command: aws
      args:
        - eks
        - get-token
"""


def test_yaml_kubectl_style() raises:
    var y = read_yaml(KIND)
    assert_equal(y.get("current-context"), "kind-orca")
    assert_equal(y.count("clusters"), 1)
    assert_equal(y.get("clusters/0/name"), "kind-orca")
    assert_equal(y.get("clusters/0/cluster/server"), "https://127.0.0.1:52345")
    assert_equal(y.count("contexts"), 2)
    assert_equal(y.get("contexts/1/context/namespace"), "runs")
    assert_equal(y.get("users/1/user/token"), "abc.def")
    assert_equal(y.get("preferences"), "")
    assert_equal(y.count("users/2/user/exec/args"), 2)
    assert_equal(y.get("users/2/user/exec/args/1"), "get-token")
    assert_true(y.has("users/2/user/exec"))
    assert_false(y.has("users/0/user/exec"))


def test_yaml_scalars() raises:
    var y = read_yaml(
        """# leading comment
---
a: 'it''s'
b: "line\\nnext \\"q\\""
c: plain value with: colon
d: ~
e:
f: x#not a comment
"g h": 1
list:
  - one
  - 'two: quoted'
  -
    k: v
"""
    )
    assert_equal(y.get("a"), "it's")
    assert_equal(y.get("b"), 'line\nnext "q"')
    assert_equal(y.get("c"), "plain value with: colon")
    assert_equal(y.get("d"), "")
    assert_equal(y.get("e"), "")
    assert_true(y.has("e"))
    assert_equal(y.get("f"), "x#not a comment")
    assert_equal(y.get("g h"), "1")
    assert_equal(y.count("list"), 3)
    assert_equal(y.get("list/1"), "two: quoted")
    assert_equal(y.get("list/2/k"), "v")


def test_yaml_refuses() raises:
    for doc in [
        String("a: |\n  block\n"),
        String("a: {b: 1}\n"),
        String("a: [1, 2]\n"),
        String("a: &x 1\n"),
        String("a:\n  b: 1\n   c: 2\n"),
        String("- x\n"),
        String("a:\n- x\nb: 1\n  c: 2\n"),
        String("a: 'open\n"),
        String("just text\n"),
    ]:
        with assert_raises():
            _ = read_yaml(doc)


def test_kubeconfig_client_certs() raises:
    var c = kubeconfig(read_yaml(KIND))
    assert_equal(c.server, "https://127.0.0.1:52345")
    assert_equal(c.namespace, "default")
    assert_equal(c.token, "")
    for pair in [
        (c.ca_file, "CA PEM"),
        (c.cert_file, "CERT"),
        (c.key_file, "KEY"),
    ]:
        with open(pair[0], "r") as f:
            assert_equal(f.read(), pair[1])
    # In one fresh directory of its own.
    var dir = String(c.key_file[byte = : c.key_file.rfind("/")])
    assert_true("k8s-mojo-" in dir)
    assert_equal(dir, String(c.ca_file[byte = : c.ca_file.rfind("/")]))


def test_kubeconfig_contexts() raises:
    var y = read_yaml(KIND)
    with assert_raises(contains="no clusters entry other"):
        _ = kubeconfig(y, "other")
    var fixed = String(KIND).replace(
        "contexts:",
        (
            "- cluster:\n    server: http://127.0.0.1:8001\n  name:"
            " other\ncontexts:"
        ),
    )
    var c = kubeconfig(read_yaml(fixed), "other")
    assert_equal(c.server, "http://127.0.0.1:8001")
    assert_equal(c.namespace, "runs")
    assert_equal(c.token, "abc.def")
    assert_equal(c.bearer(), "abc.def")
    with assert_raises(contains="no contexts entry"):
        _ = kubeconfig(y, "missing")
    var execd = fixed.replace("user: tokened", "user: exec")
    with assert_raises(contains="exec"):
        _ = kubeconfig(read_yaml(execd), "other")
    var insecure = String(KIND).replace(
        "    server: https",
        "    insecure-skip-tls-verify: true\n    server: https",
    )
    with assert_raises(contains="skips TLS verification"):
        _ = kubeconfig(read_yaml(insecure))


def test_kubeconfig_files() raises:
    var dir = String(
        getenv("TMPDIR", "/tmp").rstrip("/"), "/k8s-mojo-test-files"
    )
    makedirs(dir, exist_ok=True)
    with open(String(dir, "/token"), "w") as f:
        f.write("from-file\n")
    var doc = String(
        "clusters:\n- cluster:\n    certificate-authority: ca.pem\n",
        "    server: https://h:1\n  name: c\ncontexts:\n- context:\n",
        "    cluster: c\n    user: u\n  name: x\ncurrent-context: x\n",
        "users:\n- name: u\n  user:\n    tokenFile: token\n",
        "    client-certificate: /abs/cert.pem\n",
    )
    var path = String(dir, "/config")
    with open(path, "w") as f:
        f.write(doc)
    var c = Config.from_kubeconfig(path)
    assert_equal(c.ca_file, String(dir, "/ca.pem"))
    assert_equal(c.cert_file, "/abs/cert.pem")
    assert_equal(c.bearer(), "from-file")


def test_in_cluster_needs_a_pod() raises:
    if getenv("KUBERNETES_SERVICE_HOST"):
        return
    with assert_raises(contains="not in a pod"):
        _ = Config.in_cluster()


def test_query_escape() raises:
    assert_equal(
        query_escape("app=x,orca.run in (1,2)"),
        "app%3Dx%2Corca.run%20in%20%281%2C2%29",
    )
    assert_equal(query_escape("a-b_c.d~"), "a-b_c.d~")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
