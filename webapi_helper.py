#!/usr/bin/env python3
"""webapi_helper.py -- the network + JSON-to-table worker behind `webapi'.

v0.1.4 (2026-11-09): the request file may start with "argsformat<TAB>2"; its
values are then escaped (backslash, line break, carriage return and tab are
written as two-character backslash codes) and are decoded here, so a body()
that spans several lines is sent whole instead of only its first line.

v0.1.3 (2026-11-09): a literal "a.b" key and a nested a{b} no longer
collapse into one column (the later one is renamed with a _2 suffix and a
warning is reported); a CRLF or lone CR inside a string value becomes a
single LF, so the line break survives the import into Stata; nested arrays
kept as JSON text now keep non-ASCII characters as UTF-8 rather than as escape codes.

Portability (2026-08-16): explicit encoding="utf-8" on the TSV and status
files so non-ASCII values round-trip on Windows (cp1252 default) as on POSIX.

Usage (called by webapi.ado, not by hand):
    python3 webapi_helper.py <args.json> <out.json>

Reads a request spec from <args.json>, performs one authenticated HTTP
request with the Python standard library only (no pip, no virtualenv),
parses the JSON reply, selects the array of records named by records(),
flattens each record's nested scalars into dotted column names, and writes
the result as a TSV that Stata materialises with `import delimited'.  A tiny
key=value status file is written to <out.json> for the ado to read.

Standard library only, so the package has no external dependencies: a working
python3 on the PATH is all it needs.  Stata does not ship one; install Python 3
separately (python.org, Homebrew, or a system package).
"""
import sys, json, csv, ssl, base64
import urllib.request, urllib.parse, urllib.error


def _kv(raw, sep):
    """Parse a pipe-delimited 'key<sep>value|key<sep>value' string into a dict."""
    out = {}
    if not raw:
        return out
    for part in str(raw).split("|"):
        part = part.strip()
        if not part or sep not in part:
            continue
        k, v = part.split(sep, 1)
        out[k.strip()] = v.strip()
    return out


def _get_path(obj, path):
    """Navigate a dot path (e.g. 'data.items') to the array/object of records.
    An empty path returns the whole payload."""
    if not path:
        return obj
    cur = obj
    for part in path.split("."):
        if isinstance(cur, dict):
            cur = cur.get(part)
        elif isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return None
        else:
            return None
    return cur


def _scalar(v):
    """Prepare one scalar for the TSV.  A CRLF or a lone CR inside a string
    becomes LF: Stata's import keeps an LF inside a quoted field as a line
    break but drops a CR, which would join the two lines."""
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, str) and "\r" in v:
        return v.replace("\r\n", "\n").replace("\r", "\n")
    return v


def _flatten(d, path=()):
    """Flatten a record's nested scalar fields into a dict keyed by the tuple
    of keys that leads to each value.  Keeping the path as a tuple (rather than
    a joined "a.b" string) keeps a literal key "a.b" apart from a nested a{b};
    _column_names() then gives each path a unique column name.
    Nested arrays are kept as compact JSON strings so no data is silently lost."""
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            key = path + (str(k),)
            if isinstance(v, dict):
                out.update(_flatten(v, key))
            elif isinstance(v, list):
                out[key] = json.dumps(v, separators=(",", ":"), ensure_ascii=False)
            else:
                out[key] = _scalar(v)
    else:
        out[path or ("value",)] = _scalar(d)
    return out


def _column_names(paths):
    """Map each key path to a dotted column name, unique across all records.
    When two different paths join to the same name (a literal "a.b" key and a
    nested a{b}), the later one gets a _2, _3, ... suffix.  Returns the mapping
    and a list of the renames for the warning line."""
    names, used, renames = {}, set(), []
    for p in paths:
        base = ".".join(p)
        name, i = base, 1
        while name in used:
            i += 1
            name = f"{base}_{i}"
        if name != base:
            renames.append(f"{base} -> {name}")
        used.add(name)
        names[p] = name
    return names, renames


_ESC = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\"}


def _unescape(v):
    """Undo the escaping webapi.ado applies (argsformat 2): backslash-n,
    backslash-r, backslash-t and a doubled backslash.  Any other backslash
    pair is kept as it is."""
    out, i = [], 0
    while i < len(v):
        c = v[i]
        if c == "\\" and i + 1 < len(v):
            nxt = v[i + 1]
            out.append(_ESC.get(nxt, c + nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _read_args(path):
    """Read the tab-separated key<TAB>value request spec written by webapi.ado.
    Using a flat key/value file (rather than JSON from the ado) means URLs,
    tokens, and parameter values need no JSON escaping on the Stata side.
    With argsformat 2 (webapi 0.1.4 and later) each value is escaped so it
    fits on one line; older files hold raw values."""
    args = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n").rstrip("\r")
            if "\t" in line:
                k, v = line.split("\t", 1)
                args[k] = v
    if args.get("argsformat") == "2":
        args = {k: _unescape(v) for k, v in args.items()}
    return args


def run(args):
    url = args["url"]

    params = _kv(args.get("params_raw"), "=")
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)

    headers = _kv(args.get("headers_raw"), ":")
    if args.get("bearer"):
        headers["Authorization"] = "Bearer " + args["bearer"]
    if args.get("basic"):
        u, _, p = str(args["basic"]).partition(":")
        headers["Authorization"] = "Basic " + base64.b64encode(f"{u}:{p}".encode()).decode()
    akh = _kv(args.get("apikey_header"), ":")
    for k, v in akh.items():
        headers[k] = v
    akp = _kv(args.get("apikey_param"), "=")
    if akp:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(akp)

    data = None
    method = (args.get("method") or "GET").upper()
    body = args.get("body")
    if body is not None and body != "":
        data = str(body).encode("utf-8")
        headers.setdefault("Content-Type", "application/json")

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=int(args.get("timeout", 30)), context=ctx) as resp:
        raw = resp.read().decode("utf-8", "replace")
        http_status = resp.getcode()

    payload = json.loads(raw)
    recs = _get_path(payload, args.get("records", ""))
    if isinstance(recs, dict):
        recs = [recs]
    if not isinstance(recs, list):
        got = type(recs).__name__
        raise ValueError(
            f"records('{args.get('records','')}') did not resolve to a JSON array "
            f"(got {got}); check the path against the API's reply"
        )

    rows = [_flatten(r) if isinstance(r, dict) else {("value",): _scalar(r)}
            for r in recs]
    paths = []
    seen = set()
    for r in rows:
        for k in r.keys():
            if k not in seen:
                seen.add(k)
                paths.append(k)
    names, renames = _column_names(paths)

    with open(args["out_tsv"], "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, delimiter="\t", lineterminator="\n")
        w.writerow([names[p] for p in paths])
        for r in rows:
            w.writerow(["" if r.get(p) is None else r.get(p) for p in paths])

    result = {"status": "ok", "nrows": len(rows), "ncols": len(paths),
              "http_status": http_status}
    if renames:
        result["warning"] = ("two JSON fields flatten to the same column name; "
                             "renamed " + "; ".join(renames))
    return result


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: webapi_helper.py <args.json> <out.json>\n")
        sys.exit(2)
    args_path, out_path = sys.argv[1], sys.argv[2]
    try:
        args = _read_args(args_path)
        result = run(args)
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = " -- " + e.read().decode("utf-8", "replace")[:300]
        except Exception:
            pass
        result = {"status": "error", "error": "HTTPError",
                  "message": f"{e.code} {e.reason}{detail}"}
    except urllib.error.URLError as e:
        result = {"status": "error", "error": "URLError", "message": str(e.reason)}
    except Exception as e:
        result = {"status": "error", "error": type(e).__name__, "message": str(e)}

    with open(out_path, "w", encoding="utf-8") as f:
        for k, v in result.items():
            f.write(f"{k}={str(v).replace(chr(10), ' ').replace(chr(13), ' ')}\n")
    sys.exit(0 if result.get("status") == "ok" else 1)


if __name__ == "__main__":
    main()
