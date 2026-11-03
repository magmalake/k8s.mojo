"""The calls: create, get, delete, list and watch, for Pods, Services and
Jobs in a namespace, and a pod's log.

```mojo
var k = Client(Config.load())
_ = k.create(PODS, '{"apiVersion": "v1", "kind": "Pod", ...}')
var pod = k.get(PODS, "smoke")                  # None if there's none
var w = k.watch(PODS, "app=smoke")
while True:
    var e = w.next()                            # None once the watch ends
    if not e or e.value().object.at("/status/phase").string_value() == "Succeeded":
        break
_ = k.delete_all(PODS, "app=smoke")
```

Objects go in as JSON text and come back as json's `Value`, so a caller
writes the manifests it needs and reads the fields it needs (`at` takes a
JSON pointer), and this tin knows no schema. An answer that isn't 2xx
raises `Error("k8s: <METHOD> <path>: <code> <reason>: <message>")` with the
API's own `Status` message, except a 404 from `get` and `delete`, which
answer None and False.

A watch is one long response of JSON lines, one event each (`ADDED`,
`MODIFIED`, `DELETED`, `ERROR`), which `Watch.next` reads as they arrive.
The server ends it after `timeout_seconds`; to see every change, list
first and watch from the list's `resource_version`, and on a watch that
ended, watch again from the last event's. A 410 (the version is too old)
raises; list again.
"""

from flare.http import HttpClient, Request, Response
from flare.http._client.stream_response import HttpStreamResponse
from flare.tls import TlsConfig
from json import Value, loads

from k8s.config import Config


@fieldwise_init
struct Resource(Copyable, ImplicitlyCopyable, Movable):
    """A kind of namespaced object, by where the API serves it."""

    var prefix: StaticString
    """`/api/v1` for the core group, `/apis/<group>/<version>` otherwise."""
    var plural: StaticString


comptime PODS = Resource("/api/v1", "pods")
comptime SERVICES = Resource("/api/v1", "services")
comptime JOBS = Resource("/apis/batch/v1", "jobs")


@fieldwise_init
struct Listed(Movable):
    var items: List[Value]
    var resource_version: String
    """The list's, to watch from."""


@fieldwise_init
struct Event(Copyable, Movable):
    var type: String
    """`ADDED`, `MODIFIED`, `DELETED` or `ERROR`."""
    var object: Value
    """The object as it is after the change, or for `ERROR` a `Status`."""


def query_escape(s: String) -> String:
    """`s` with everything but unreserved characters percent-encoded."""
    comptime hex = "0123456789ABCDEF"
    var out = String()
    for b in s.as_bytes():
        if (
            (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
            or (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
            or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
            or b == UInt8(ord("-"))
            or b == UInt8(ord("_"))
            or b == UInt8(ord("."))
            or b == UInt8(ord("~"))
        ):
            out.write(chr(Int(b)))
        else:
            out.write("%", hex[byte=Int(b >> 4)], hex[byte=Int(b & 15)])
    return out^


def _failure(method: String, path: String, status: Int, body: String) -> Error:
    """The API's `Status` message, or the body, as an error."""
    var why = String(body.strip())
    try:
        var s = loads(body)
        var msg = s.try_at("/message")
        var reason = s.try_at("/reason")
        if msg:
            why = String(
                reason.value().string_value() if reason else String(),
                ": " if reason else "",
                msg.value().string_value(),
            )
    except:
        pass
    return Error("k8s: ", method, " ", path, ": ", status, " ", why)


struct Watch(Movable):
    """The events of one watch request, as they arrive."""

    var _stream: HttpStreamResponse
    var _buf: List[UInt8]
    var _path: String
    var resource_version: String
    """The last event's, to watch again from."""

    def __init__(
        out self, var stream: HttpStreamResponse, path: String, since: String
    ):
        self._stream = stream^
        self._buf = List[UInt8]()
        self._path = path
        self.resource_version = since

    def next(mut self) raises -> Optional[Event]:
        """The next event, waiting for it; None once the server has ended
        the watch. An `ERROR` event raises."""
        while True:
            var nl = -1
            for i in range(len(self._buf)):
                if self._buf[i] == UInt8(ord("\n")):
                    nl = i
                    break
            if nl < 0:
                if self._stream.done():
                    return None
                var chunk = self._stream.read_chunk(65536)
                if len(chunk) == 0 and self._stream.done():
                    return None
                self._buf.extend(Span(chunk))
                continue
            var line = String(from_utf8_lossy=Span(self._buf)[:nl])
            self._buf = List[UInt8](Span(self._buf)[nl + 1 :])
            if not line.strip():
                continue
            var e = loads(line)
            var type = e["type"].string_value()
            var obj = e["object"].copy()
            if type == "ERROR":
                var code = obj.try_at("/code")
                raise _failure(
                    "GET",
                    self._path,
                    Int(code.value().int_value()) if code else 0,
                    obj.raw_json(),
                )
            var rv = obj.try_at("/metadata/resourceVersion")
            if rv:
                self.resource_version = rv.value().string_value()
            return Event(type^, obj^)

    def close(mut self):
        self._stream.close()


struct Client(Movable):
    """Calls to the API server `config` names, as its user."""

    var config: Config

    def __init__(out self, var config: Config):
        self.config = config^

    def _http(self, read_timeout_ms: Int) raises -> HttpClient:
        var c: HttpClient
        if self.config.server.startswith("https://"):
            c = HttpClient(
                TlsConfig(
                    ca_bundle=self.config.ca_file,
                    cert_file=self.config.cert_file,
                    key_file=self.config.key_file,
                ),
                timeout_ms=10_000,
            )
        else:
            c = HttpClient(timeout_ms=10_000)
        return c^.with_read_timeout(read_timeout_ms)

    def _request(
        self, method: String, path: String, body: String = ""
    ) raises -> Request:
        var req = Request(
            method=method,
            url=String(self.config.server.rstrip("/"), path),
            body=List[UInt8](body.as_bytes()),
        )
        req.headers.set("Accept", "application/json")
        if body:
            req.headers.set("Content-Type", "application/json")
        var token = self.config.bearer()
        if token:
            req.headers.set("Authorization", String("Bearer ", token))
        return req^

    def _send(
        self, method: String, path: String, body: String = ""
    ) raises -> Response:
        return self._http(30_000).send(self._request(method, path, body))

    def _path(
        self, r: Resource, namespace: String, name: String = ""
    ) -> String:
        var out = String(
            r.prefix,
            "/namespaces/",
            query_escape(namespace if namespace else self.config.namespace),
            "/",
            r.plural,
        )
        if name:
            out.write("/", query_escape(name))
        return out^

    def create(
        self, r: Resource, manifest: String, namespace: String = ""
    ) raises -> Value:
        """Creates the object `manifest` describes, and returns it as the
        server made it."""
        var path = self._path(r, namespace)
        var resp = self._send("POST", path, manifest)
        if resp.status < 200 or resp.status >= 300:
            raise _failure("POST", path, resp.status, resp.text())
        return loads(resp.text())

    def get(
        self, r: Resource, name: String, namespace: String = ""
    ) raises -> Optional[Value]:
        var path = self._path(r, namespace, name)
        var resp = self._send("GET", path)
        if resp.status == 404:
            return None
        if resp.status != 200:
            raise _failure("GET", path, resp.status, resp.text())
        return loads(resp.text())

    def logs(
        self, pod: String, container: String = "", namespace: String = ""
    ) raises -> String:
        """A pod's log, of its only container or of `container`; empty for
        a pod that's gone."""
        var path = String(self._path(PODS, namespace, pod), "/log")
        if container:
            path.write("?container=", query_escape(container))
        var resp = self._send("GET", path)
        if resp.status == 404:
            return ""
        if resp.status != 200:
            raise _failure("GET", path, resp.status, resp.text())
        return resp.text()

    def delete(
        self,
        r: Resource,
        name: String,
        namespace: String = "",
        propagation: String = "Background",
    ) raises -> Bool:
        """Deletes the object, and what it owns by `propagation`
        (`Background`, `Foreground` or `Orphan`); False if there was none."""
        var path = String(
            self._path(r, namespace, name),
            "?propagationPolicy=",
            query_escape(propagation),
        )
        var resp = self._send("DELETE", path)
        if resp.status == 404:
            return False
        if resp.status < 200 or resp.status >= 300:
            raise _failure("DELETE", path, resp.status, resp.text())
        return True

    def list(
        self, r: Resource, selector: String = "", namespace: String = ""
    ) raises -> Listed:
        """The objects whose labels match `selector` (`app=x,run=7`), or
        all of them."""
        var path = self._path(r, namespace)
        if selector:
            path.write("?labelSelector=", query_escape(selector))
        var resp = self._send("GET", path)
        if resp.status != 200:
            raise _failure("GET", path, resp.status, resp.text())
        var l = loads(resp.text())
        var items = List[Value]()
        var got = l.try_at("/items")
        if got and got.value().is_array():
            items = got.value().array_items()
        var rv = l.try_at("/metadata/resourceVersion")
        return Listed(items^, rv.value().string_value() if rv else String())

    def delete_all(
        self, r: Resource, selector: String, namespace: String = ""
    ) raises -> Int:
        """Deletes every object matching `selector`, which mustn't be empty,
        and returns how many there were."""
        if not selector.strip():
            raise Error("k8s: delete_all needs a label selector")
        var n = 0
        for o in self.list(r, selector, namespace).items:
            if self.delete(r, o.at("/metadata/name").string_value(), namespace):
                n += 1
        return n

    def watch(
        self,
        r: Resource,
        selector: String = "",
        resource_version: String = "",
        timeout_seconds: Int = 300,
        namespace: String = "",
    ) raises -> Watch:
        """A watch of the objects matching `selector`, from
        `resource_version` (else from now, with an `ADDED` event for each
        that exists), until the server ends it after `timeout_seconds`."""
        var path = String(
            self._path(r, namespace),
            "?watch=1&timeoutSeconds=",
            timeout_seconds,
        )
        if selector:
            path.write("&labelSelector=", query_escape(selector))
        if resource_version:
            path.write("&resourceVersion=", query_escape(resource_version))
        var http = self._http((timeout_seconds + 30) * 1000)
        var stream = http.send_streaming(self._request("GET", path))
        if stream.status != 200:
            var body = String(from_utf8_lossy=Span(stream.read_all()))
            raise _failure("GET", path, stream.status, body)
        return Watch(stream^, path, resource_version)
