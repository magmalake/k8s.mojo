"""Against a live cluster, in the namespace `K8S_TEST_NAMESPACE`, with the
kubeconfig's credentials; tests/kind.sh sets it up.

- a pod is created, watched to `Succeeded`, listed by its label, and its
  log read;
- a Service and a Job are created and got, and the Job watched to done;
- `delete_all` deletes everything with the label, and gets answer None;
- the API's refusals raise with its message: a spec it finds invalid (422),
  a name already taken (409), and, with `K8S_TEST_TOKEN` (a service account
  with no role), a create RBAC forbids (403).
"""

from std.ffi import external_call
from std.os import getenv
from std.time import sleep

from json import Value

from k8s import JOBS, PODS, SERVICES, Client, Config


def _check(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: ", what)


def _pod(name: String, label: String) -> String:
    return String(
        '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "',
        name,
        '", "labels": {"app": "k8s-mojo-test", "test": "',
        label,
        '"}}, "spec": {"restartPolicy": "Never", "containers": [{"name":',
        ' "main", "image": "busybox:1.36", "command": ["sh", "-c",',
        ' "echo hello"]}]}}',
    )


def _phase(v: Value) raises -> String:
    var p = v.try_at("/status/phase")
    return p.value().string_value() if p else String()


def _wait_gone(k: Client, name: String) raises:
    """Until the pod's gone: deleting one is graceful."""
    for _ in range(120):
        if not k.get(PODS, name):
            return
        sleep(0.5)
    raise Error("FAIL: pod ", name, " is still there a minute after delete")


def main() raises:
    var ns = getenv("K8S_TEST_NAMESPACE", "k8s-mojo-test")
    var cfg = Config.from_kubeconfig()
    cfg.namespace = ns
    var k = Client(cfg.copy())
    var label = String("t", external_call["getpid", Int32]())
    var sel = String("app=k8s-mojo-test,test=", label)

    # A pod, watched from the (empty) list's version to Succeeded.
    var before = k.list(PODS, sel)
    _check(len(before.items) == 0, "pods with a new label already exist")
    var made = k.create(PODS, _pod("smoke", label))
    _check(made.at("/metadata/name").string_value() == "smoke", "create")
    var w = k.watch(PODS, sel, before.resource_version, timeout_seconds=180)
    var seen = List[String]()
    var phase = String()
    while phase != "Succeeded":
        var e = w.next()
        if not e:
            raise Error("FAIL: the watch ended before the pod succeeded")
        seen.append(e.value().type)
        phase = _phase(e.value().object)
        _check(phase != "Failed", "the pod failed")
    w.close()
    _check(seen[0] == "ADDED", String("the first event is ", seen[0]))
    _check(len(seen) >= 2, "no MODIFIED events")
    print("ok   pod watched to Succeeded through", len(seen), "events")
    var listed = k.list(PODS, sel)
    _check(len(listed.items) == 1, "list by label")
    _check(
        listed.items[0].at("/metadata/name").string_value() == "smoke",
        "the listed pod",
    )
    _check(_phase(k.get(PODS, "smoke").value()) == "Succeeded", "get")
    _check(not k.get(PODS, "no-such-pod"), "get of no pod")
    _check(
        k.logs("smoke") == "hello\n",
        String("the pod's log: '", k.logs("smoke"), "'"),
    )
    _check(k.logs("no-such-pod") == "", "the log of no pod")

    # A Service and a Job.
    _ = k.create(
        SERVICES,
        String(
            '{"apiVersion": "v1", "kind": "Service", "metadata": {"name":',
            ' "smoke", "labels": {"app": "k8s-mojo-test", "test": "',
            label,
            '"}}, "spec": {"selector": {"test": "',
            label,
            '"}, "ports": [{"port": 6390}]}}',
        ),
    )
    _check(
        k.get(SERVICES, "smoke").value().at("/spec/ports/0/port").int_value()
        == 6390,
        "the service",
    )
    var job = String(
        '{"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name":',
        ' "smoke", "labels": {"app": "k8s-mojo-test", "test": "',
        label,
        '"}}, "spec": {"backoffLimit": 0, "template": {"metadata":',
        ' {"labels": {"app": "k8s-mojo-test", "test": "',
        label,
        '"}}, "spec": {"restartPolicy": "Never", "containers": [{"name":',
        ' "main", "image": "busybox:1.36", "command": ["true"]}]}}}}',
    )
    _ = k.create(JOBS, job)
    var jw = k.watch(JOBS, sel, timeout_seconds=180)
    while True:
        var e = jw.next()
        if not e:
            raise Error("FAIL: the watch ended before the job finished")
        var done = e.value().object.try_at("/status/succeeded")
        if done and done.value().int_value() == 1:
            break
    jw.close()
    print("ok   service and job")

    # Refusals, with the API's own messages.
    var invalid = String(
        '{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "bad"},',
        ' "spec": {"containers": []}}',
    )
    try:
        _ = k.create(PODS, invalid)
        raise Error("FAIL: an invalid pod was created")
    except e:
        var msg = String(e)
        _check("422" in msg and "Invalid" in msg, String("422: ", msg))
    try:
        _ = k.create(
            SERVICES,
            (
                '{"apiVersion": "v1", "kind": "Service", "metadata": {"name":'
                ' "smoke"}, "spec": {"ports": [{"port": 1}]}}'
            ),
        )
        raise Error("FAIL: a second service named smoke was created")
    except e:
        _check("409" in String(e) and "AlreadyExists" in String(e), String(e))
    var token = getenv("K8S_TEST_TOKEN")
    if token:
        var nobody = Config(
            cfg.server, ca_file=cfg.ca_file, token=token, namespace=ns
        )
        try:
            _ = Client(nobody^).create(PODS, _pod("forbidden", label))
            raise Error("FAIL: a service account with no role created a pod")
        except e:
            _check("403" in String(e) and "forbidden" in String(e), String(e))
    print(
        "ok   refusals: 422, 409, 403" if token else "ok   refusals: 422, 409"
    )

    # Everything with the label, gone.
    _check(k.delete_all(JOBS, sel) == 1, "delete_all jobs")
    _check(k.delete_all(SERVICES, sel) == 1, "delete_all services")
    _check(k.delete_all(PODS, sel) >= 1, "delete_all pods")
    _wait_gone(k, "smoke")
    _check(not k.get(SERVICES, "smoke"), "the service after delete")
    _check(not k.get(JOBS, "smoke"), "the job after delete")
    for _ in range(120):
        if len(k.list(PODS, sel).items) == 0:
            break
        sleep(0.5)
    _check(len(k.list(PODS, sel).items) == 0, "the job's pod after delete")
    _check(not k.delete(PODS, "smoke"), "delete of no pod")
    with_bad_selector(k)
    print("ok   deleted by label")


def with_bad_selector(k: Client) raises:
    try:
        _ = k.delete_all(PODS, " ")
        raise Error("FAIL: delete_all ran with no selector")
    except e:
        _check("needs a label selector" in String(e), String(e))
