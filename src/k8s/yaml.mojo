"""Just enough YAML to read a kubeconfig: block mappings and sequences of
scalars, read into a flat map from paths to strings.

```mojo
var y = read_yaml(text)
y.get("current-context")                  # "kind-orca"
y.get("clusters/0/cluster/server")        # "https://127.0.0.1:6443"
y.count("users")                          # 1
```

A path is the keys and sequence indices from the top, joined by `/`. A
scalar may be plain, single-quoted or double-quoted; `~`, `null` and an
empty value are the empty string, as are the empty flow collections `{}`
and `[]`. That covers what `kubectl` and `kind` write. Anything else,
such as a block scalar (`|`), a flow collection with something in it, an
anchor or a tab used to indent, raises rather than being read wrong.
"""


@fieldwise_init
struct Yaml(Movable):
    var values: Dict[String, String]
    """Each scalar, by its path."""
    var counts: Dict[String, Int]
    """Each sequence's length, by its path."""
    var maps: Dict[String, Bool]
    """The path of each mapping below the top."""

    def get(self, path: String, default: String = "") -> String:
        return self.values.get(path, default)

    def has(self, path: String) -> Bool:
        return path in self.values or path in self.counts or path in self.maps

    def count(self, path: String) -> Int:
        """The length of the sequence at `path`, or 0."""
        return self.counts.get(path, 0)


@fieldwise_init
struct _Frame(Copyable, Movable):
    var indent: Int
    """The column its entries start at."""
    var path: String
    var seq: Bool


def _join(path: String, key: String) -> String:
    return String(path, "/", key) if path else key


def _bad(line: Int, why: String) -> Error:
    return Error("k8s: YAML line ", line, ": ", why)


def _comment_at(t: String) -> Int:
    """Where a comment starts in `t`, outside quotes, or -1."""
    var b = t.as_bytes()
    var quote = UInt8(0)
    for i in range(len(b)):
        var c = b[i]
        if quote:
            if c == quote:
                quote = 0
            elif c == UInt8(ord("\\")) and quote == UInt8(ord('"')):
                pass
        elif c == UInt8(ord("'")) or c == UInt8(ord('"')):
            quote = c
        elif c == UInt8(ord("#")) and (i == 0 or b[i - 1] == UInt8(ord(" "))):
            return i
    return -1


def _scalar(raw: String, line: Int) raises -> String:
    var s = String(raw.strip())
    if s == "" or s == "~" or s == "null" or s == "{}" or s == "[]":
        return ""
    var b = s.as_bytes()
    var first = b[0]
    if first == UInt8(ord("'")):
        if len(b) < 2 or b[len(b) - 1] != first:
            raise _bad(line, "an unterminated quoted string")
        return String(s[byte = 1 : len(b) - 1]).replace("''", "'")
    if first == UInt8(ord('"')):
        if len(b) < 2 or b[len(b) - 1] != first:
            raise _bad(line, "an unterminated quoted string")
        var out = String()
        var i = 1
        while i < len(b) - 1:
            var c = b[i]
            if c == UInt8(ord("\\")) and i + 1 < len(b) - 1:
                var e = b[i + 1]
                if e == UInt8(ord("n")):
                    out.write("\n")
                elif e == UInt8(ord("t")):
                    out.write("\t")
                elif e == UInt8(ord('"')) or e == UInt8(ord("\\")):
                    out.write(String(s[byte = i + 1 : i + 2]))
                else:
                    raise _bad(line, "an escape it doesn't read")
                i += 2
                continue
            out.write(String(s[byte = i : i + 1]))
            i += 1
        return out^
    if (
        first == UInt8(ord("|"))
        or first == UInt8(ord(">"))
        or first == UInt8(ord("{"))
        or first == UInt8(ord("["))
        or first == UInt8(ord("&"))
        or first == UInt8(ord("*"))
        or first == UInt8(ord("!"))
    ):
        raise _bad(line, String("YAML it doesn't read: ", s))
    return s^


def _key_value(t: String, line: Int) raises -> Tuple[String, String, Bool]:
    """A `key: value` line's key and value, and whether it has a value."""
    var colon = -1
    var b = t.as_bytes()
    var quote = UInt8(0)
    for i in range(len(b)):
        var c = b[i]
        if quote:
            if c == quote:
                quote = 0
        elif c == UInt8(ord("'")) or c == UInt8(ord('"')):
            quote = c
        elif c == UInt8(ord(":")) and (
            i + 1 == len(b) or b[i + 1] == UInt8(ord(" "))
        ):
            colon = i
            break
    if colon <= 0:
        raise _bad(line, String("not a key: ", t))
    var key = _scalar(String(t[byte=:colon]), line)
    var rest = String(t[byte = colon + 1 :].strip())
    return (key^, rest^, rest.byte_length() > 0)


def read_yaml(text: String) raises -> Yaml:
    var y = Yaml(
        Dict[String, String](), Dict[String, Int](), Dict[String, Bool]()
    )
    var frames: List[_Frame] = [_Frame(0, "", False)]
    # A key with nothing after its colon: what follows says what it holds.
    var pending = String()
    var pending_indent = -1
    var have_pending = False
    var n = 0
    for raw in text.splitlines():
        n += 1
        var line = String(raw)
        if "\t" in line and String(line.strip(" ")).startswith("\t"):
            raise _bad(n, "a tab used to indent")
        var c = _comment_at(line)
        if c >= 0:
            var cut = String(line[byte=:c])
            line = cut^
        var t = String(line.rstrip())
        var stripped = String(t.lstrip(" "))
        if not stripped or stripped == "---":
            continue
        var indent = t.byte_length() - stripped.byte_length()
        var dash = stripped == "-" or stripped.startswith("- ")
        if have_pending:
            have_pending = False
            if dash and indent >= pending_indent:
                frames.append(_Frame(indent, pending, True))
                y.counts[pending] = 0
            elif indent > pending_indent:
                frames.append(_Frame(indent, pending, False))
                y.maps[pending] = True
            else:
                y.values[pending] = ""
        while len(frames) > 1 and frames[len(frames) - 1].indent > indent:
            _ = frames.pop()
        # A sequence at its key's column ends at the next key there.
        while (
            len(frames) > 1
            and frames[len(frames) - 1].seq
            and frames[len(frames) - 1].indent == indent
            and not dash
        ):
            _ = frames.pop()
        var top = frames[len(frames) - 1].copy()
        if top.indent != indent:
            raise _bad(n, "indented where nothing is open")
        if dash:
            if not top.seq:
                raise _bad(n, "a sequence item where a key belongs")
            var item = _join(top.path, String(y.counts[top.path]))
            y.counts[top.path] += 1
            var rest = String(stripped[byte=1:].strip())
            if not rest:
                pending = item
                pending_indent = indent
                have_pending = True
                continue
            var quoted = rest.startswith("'") or rest.startswith('"')
            if not quoted and (": " in rest or rest.endswith(":")):
                # `- key: value`: a mapping whose keys line up with `key`.
                var at = indent + (stripped.byte_length() - rest.byte_length())
                frames.append(_Frame(at, item, False))
                y.maps[item] = True
                var kv = _key_value(rest, n)
                if kv[2]:
                    y.values[_join(item, kv[0])] = _scalar(kv[1], n)
                else:
                    pending = _join(item, kv[0])
                    pending_indent = at
                    have_pending = True
                continue
            y.values[item] = _scalar(rest, n)
            continue
        if top.seq:
            raise _bad(n, "a key where a sequence item belongs")
        var kv = _key_value(stripped, n)
        var path = _join(top.path, kv[0])
        if kv[2]:
            y.values[path] = _scalar(kv[1], n)
        else:
            pending = path
            pending_indent = indent
            have_pending = True
    if have_pending:
        y.values[pending] = ""
    return y^
