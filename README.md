# webapi — fetch an authenticated JSON web API into Stata

**Turn any JSON web API into a Stata dataset in one command, with no external dependencies.**

```stata
webapi get using "https://data.cdc.gov/resource/bi63-dtpu.json", ///
    params("year=2017|cause_name=All causes") clear
```

`webapi` performs one HTTP request, authenticates it, and reads the JSON reply back into Stata as variables and observations. It is a small, dependency-free generalisation of the pattern behind [`googlesheets`](https://github.com/ericabooth/googlesheets-stata-public) and [`googlechart`](https://github.com/ericabooth/googlechart-stata-public): a request to a URL, an authentication step, and a JSON reply parsed into memory.

The network and JSON work is done by a companion Python helper that uses only the Python **standard library** — no `pip` packages, no virtualenv. The only requirement is Stata 16 or later and a working `python3` on the PATH (`python` on Windows). Stata does not ship this interpreter; install Python 3 from python.org or your system's package manager.

## Install

```stata
net install webapi, from("https://raw.githubusercontent.com/ericabooth/webapi-stata-public/main/") replace force
help webapi
```

## What it does

| | |
|---|---|
| **Request** | `get` or `post`, with query `params()`, request `headers()`, and a `body()` for POST |
| **Auth** | `bearer()`, `apikeyheader()`, `apikeyparam()`, or `basicauth()` — pick what the API wants |
| **Shape** | `records()` names the JSON array to turn into rows; nested object fields flatten automatically to columns; `stringall` imports every column as a string |
| **Poll** | `every(seconds)` `times(n)` re-fetches a live endpoint on an interval and stacks the snapshots into a panel; `times()` defaults to 12 when `every()` is set |
| **Control** | `timeout(seconds)` (default 30), `tsv(path)` keeps the intermediate TSV, `verbose` echoes the Python call |
| **Return** | the table in memory, plus `r(nrows)`, `r(http)` and `r(url)`; `r(ncols)` on a single request, `r(polls)` on a polling call |

## Examples

**A public array of records** (nested fields flatten to columns like `addresscity`, `companyname`):

```stata
webapi get using "https://jsonplaceholder.typicode.com/users", clear
```

**A real health API** — CDC's NCHS leading-causes-of-death dataset on Socrata, filtered and with a header:

```stata
webapi get using "https://data.cdc.gov/resource/bi63-dtpu.json", ///
    params("year=2017|cause_name=All causes") headers("Accept:application/json") clear
```

**An authenticated API**, keeping the token out of the script:

```stata
* set $API_TOKEN once in profile.do, never in the do-file
webapi get using "https://api.example.org/v1/series", ///
    bearer("$API_TOKEN") params("since=2026-01-01") records("data") clear
```

**Create a resource with POST**; the reply is the created object:

```stata
webapi post using "https://api.example.org/v1/items", ///
    body(`"{"name":"Texas","value":18.8}"') bearer("$API_TOKEN") records("") clear
```

**Poll a live endpoint** every 30 seconds, 20 times; the snapshots stack into a panel keyed by `_poll` and `_polltime`:

```stata
webapi get using "https://api.example.org/v1/status", ///
    records("data") every(30) times(20) clear
```

## Notes

- **`records()`** is a dot path to the array of records. Omit it (or use `records("")`) when the reply is itself the array; use `records("data")` or `records("results.items")` when it is nested.
- **`params()` and `headers()`** are pipe-delimited so values may contain spaces: `params("q=heart disease|limit=50")`.
- **The dollar sign.** Some APIs (Socrata's `$limit`, `$select`, `$where`) use parameters beginning with `$`, which Stata reads as a global macro. Type it as `\$`, for example `params("\$limit=5")`; `webapi` then sends the `$` unchanged. The same works in the URL, `headers()`, `body()` and the auth options. Do not use `` `=char(36)' ``: Stata expands the `$limit` it produces as a global before `webapi` runs, and the parameter name is lost.
- **Numbers sent as strings.** By default each column gets the type `import delimited` picks, so a column of numeric-looking strings (Socrata sends every number as a string) arrives as numbers. Codes with leading zeros (ZIP, FIPS, `"001"`) lose the zeros; add `stringall` to keep every column exactly as sent.
- **Column names.** Nested fields flatten to dotted names (`geo.lat` becomes `geolat`, with the full name in the variable label). If a record has both a literal `"a.b"` key and a nested `a{b}`, the second becomes `a.b_2` and `webapi` prints a note.
- **Text.** The reply is read as UTF-8, so non-ASCII text arrives intact, and a line break inside a value (LF, CRLF or CR) stays in the value as one line break.
- **Secrets.** Store tokens in a global set in `profile.do`; never commit a token to a public repo, and prefer headers over query strings for keys.

## Relationship to other tools

`webapi` focuses on the *authenticated request-and-shape* workflow, not on JSON parsing as such. For JSON parsing in other contexts see [`jsonio`](https://github.com/wbuchanan/StataJSON) (Buchanan) and `insheetjson` / `libjson` (Lindsley). Where those read JSON you already have, `webapi` fetches it — with authentication, query parameters, and record-flattening — in one line.

## Author and license

Eric A. Booth, Sr Researcher, Texas 2036 (eric.a.booth@gmail.com), 2026. MIT-licensed. A companion to `googlesheets` and `googlechart`.
