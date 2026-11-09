*! webapi v0.1.3  2026-11-09
*! v0.1.3: reads the reply as UTF-8 (encoding("utf-8")), so accented text no
*!   longer arrives garbled; every user string (URL, params, headers, tokens,
*!   body, records, tsv path) is passed with macval(), so a "$" typed as \$
*!   (Socrata's \$limit) reaches the API unchanged instead of being expanded
*!   as a global inside webapi (the help now documents \$, because Stata
*!   expands `=char(36)' in the caller); HTTP error text with quotes, braces,
*!   backticks or "$" prints intact; the helper keeps a literal
*!   "a.b" key and a nested a{b} as two columns (with a warning) and turns a
*!   CRLF inside a value into a single line break.
*! v0.1.2: bindquote(strict), so a value that contains line breaks stays one
*!   row (it used to split into extra rows); a "~" in tsv() is expanded here,
*!   because the Python helper does not expand it.
*! v0.1.1 2026-08-16: no-output hint reports the actual interpreter (python
*!   on Windows).  Helper already UTF-8-safe and dependency-free (stdlib urllib).
*! Fetch an authenticated JSON web API into Stata as a dataset.
*!
*! A small, dependency-free generalisation of the pattern documented in
*! Booth (2026, googlesheets/googlechart): a request to a URL, an
*! authentication step, and a JSON reply parsed back into variables and
*! observations.  webapi handles the HTTP + auth + JSON-to-table steps with
*! the Python standard library, so no pip packages or virtualenv are needed.
*!
*!   webapi get  using "<URL>" [, options]
*!   webapi post using "<URL>" , body("<json>") [, options]
*!
*! Options:
*!   records(path)      dot-path to the JSON array of records (default: the
*!                      whole reply).  e.g. records("data") or records("results.items")
*!   params(k=v|k=v)    pipe-delimited query-string parameters
*!   headers(H:V|H:V)   pipe-delimited request headers
*!   bearer(token)      send Authorization: Bearer <token>
*!   basicauth(user:pw) send HTTP basic authentication
*!   apikeyheader(H:V)  send an API key as a header
*!   apikeyparam(k=v)   send an API key as a query parameter
*!   body(text)         request body (POST); JSON content-type assumed
*!   timeout(#)         seconds before giving up (default 30)
*!   tsv(path)          keep the intermediate TSV at this path
*!   stringall          import every column as a string
*!   clear              replace data in memory (like import delimited)
*!   verbose            echo the underlying python invocation

program define webapi, rclass
    version 16.0

    gettoken sub 0 : 0
    local sub = lower(strtrim("`sub'"))
    if "`sub'" == "help" {
        help webapi
        exit 0
    }
    if !inlist("`sub'", "get", "post") {
        display as error "webapi: first word must be {bf:get}, {bf:post}, or {bf:help}"
        display as error `"  Syntax: {bf:webapi get using "URL", records(...) [options]}"'
        exit 198
    }

    syntax using/, [ HEADers(string) PARAms(string)                        ///
        BEARER(string) BASICauth(string)                                   ///
        APIKEYHeader(string) APIKEYParam(string)                           ///
        RECords(string) BODY(string) TIMEout(integer 30)                   ///
        EVERY(real 0) TIMES(integer 0)                                     ///
        TSV(string) STRINGall CLEAR Verbose ]

    local url `"`macval(using)'"'
    local method = upper("`sub'")

    * --- discover the helper -------------------------------------------
    capture findfile webapi_helper.py
    if _rc {
        display as error "webapi: webapi_helper.py not on the adopath. Reinstall the package."
        exit 601
    }
    local helper "`r(fn)'"

    * --- output paths --------------------------------------------------
    if `"`tsv'"' == "" {
        tempfile datatsv
        local outdata `"`datatsv'"'
    }
    else {
        * Expand a leading "~" here: Stata and the Python helper must use the
        * same full path, and Python does not expand "~".
        _wa_expandtilde, local(outdata) path(`"`macval(tsv)'"')
    }
    tempfile status argjson

    * --- assemble the request as a tab-separated key/value file --------
    * A flat key<TAB>value file (rather than JSON built in Stata) means URLs,
    * tokens, and parameter values need no escaping on the Stata side.
    * macval() keeps a "$" or a backtick in a user string literal: without it
    * Stata would expand "$limit" again here as a (usually empty) global.
    * The writes sit in { } blocks on purpose: a one-line "if cond command"
    * expands the command a second time, which would undo macval().
    tempname h
    quietly file open `h' using `"`argjson'"', write text replace
    file write `h' "method"  _tab "`method'"    _n
    file write `h' "url"     _tab `"`macval(url)'"'      _n
    file write `h' "records" _tab `"`macval(records)'"'  _n
    file write `h' "timeout" _tab "`timeout'"    _n
    if `"`macval(headers)'"' != "" {
        file write `h' "headers_raw" _tab `"`macval(headers)'"' _n
    }
    if `"`macval(params)'"' != "" {
        file write `h' "params_raw" _tab `"`macval(params)'"' _n
    }
    if `"`macval(bearer)'"' != "" {
        file write `h' "bearer" _tab `"`macval(bearer)'"' _n
    }
    if `"`macval(basicauth)'"' != "" {
        file write `h' "basic" _tab `"`macval(basicauth)'"' _n
    }
    if `"`macval(apikeyheader)'"' != "" {
        file write `h' "apikey_header" _tab `"`macval(apikeyheader)'"' _n
    }
    if `"`macval(apikeyparam)'"' != "" {
        file write `h' "apikey_param" _tab `"`macval(apikeyparam)'"' _n
    }
    if `"`macval(body)'"' != "" {
        file write `h' "body" _tab `"`macval(body)'"' _n
    }
    file write `h' "out_tsv" _tab `"`macval(outdata)'"'  _n
    file close `h'

    * --- python + polling settings -------------------------------------
    if lower("`c(os)'") == "windows" local PY "python"
    else                             local PY "python3"
    if "`verbose'" != "" {
        display as text `"[webapi] `PY' "`helper'" "`argjson'" "`status'""'
    }
    if `every' < 0 local every 0
    * every() without times() polls a bounded number of times, so a call
    * always returns; times() alone (no wait) just repeats back-to-back.
    if `every' > 0 & `times' <= 0 local times 12
    if `times' <= 0 local times 1
    local polling = (`times' > 1)
    if "`stringall'" != "" local scols "stringcols(_all)"

    tempfile master

    forvalues _p = 1/`times' {
        quietly shell `PY' "`helper'" "`argjson'" "`status'"

        capture confirm file `"`status'"'
        if _rc {
            display as error `"webapi: the helper produced no output.  Is `PY' on your PATH?"'
            exit 198
        }

        * read the key=value status
        local st ""
        local err ""
        local msg ""
        local nrows 0
        local ncols 0
        local http ""
        local warn ""
        tempname sh
        file open `sh' using `"`status'"', read text
        file read `sh' line
        while r(eof) == 0 {
            * Split key=value in Mata: a message (an API's error body) can hold
            * quotes, backticks or "$", which Stata expressions would mangle.
            mata: st_local("eq", strofreal(strpos(st_local("line"), "=")))
            if `eq' > 0 {
                mata: st_local("k", substr(st_local("line"), 1, `eq' - 1))
                mata: st_local("v", substr(st_local("line"), `eq' + 1, .))
                local tgt ""
                if "`k'" == "status"           local tgt st
                else if "`k'" == "error"       local tgt err
                else if "`k'" == "message"     local tgt msg
                else if "`k'" == "warning"     local tgt warn
                else if "`k'" == "nrows"       local tgt nrows
                else if "`k'" == "ncols"       local tgt ncols
                else if "`k'" == "http_status" local tgt http
                if "`tgt'" != "" mata: st_local("`tgt'", st_local("v"))
            }
            file read `sh' line
        }
        file close `sh'

        if `"`macval(st)'"' != "ok" {
            * Print the message from Mata with SMCL braces escaped, so quotes,
            * braces, backticks and "$" in an error body show as sent.
            mata: st_local("msg", _wa_smclsafe(st_local("msg")))
            mata: st_local("err", _wa_smclsafe(st_local("err")))
            mata: printf("{err}webapi %s: %s -- %s\n", st_local("sub"), st_local("err"), st_local("msg"))
            exit 198
        }
        mata: st_local("haswarn", strofreal(st_local("warn") != ""))
        if `haswarn' & `_p' == 1 {
            mata: printf("{txt}webapi note: %s\n", _wa_smclsafe(st_local("warn")))
        }

        if `polling' {
            * accumulate one snapshot per poll, stamped with the poll index
            * and the wall-clock time, so a stream of pulls stacks into a panel.
            import delimited using `"`macval(outdata)'"', delimiters(tab) bindquote(strict) varnames(1) encoding("utf-8") clear `scols'
            quietly gen long _poll = `_p'
            quietly gen str12 _polltime = "`c(current_time)'"
            if `_p' > 1 quietly append using `"`master'"'
            quietly save `"`master'"', replace
            display as text "  poll `_p'/`times' at `c(current_time)': `nrows' rows (HTTP `http')"
            if `_p' < `times' & `every' > 0 sleep `=int(`every'*1000)'
        }
        else {
            import delimited using `"`macval(outdata)'"', delimiters(tab) bindquote(strict) varnames(1) encoding("utf-8") `clear' `scols'
        }
    }

    if `polling' {
        quietly use `"`master'"', clear
        sort _poll
        display as result _n "[webapi `sub']  `times' polls, `=_N' total rows accumulated"
        return scalar polls = `times'
        return scalar nrows = _N
    }
    else {
        display as result _n "[webapi `sub']  `nrows' rows, `ncols' columns  (HTTP `http')"
        return scalar nrows = `nrows'
        return scalar ncols = `ncols'
    }
    return local http `"`http'"'
    return local url  `"`macval(url)'"'
end


* Expand a leading "~" (bare "~", "~/" or "~\") to the home directory, without
* relying on the operating system, Stata, or Python to do it.  Result goes to
* the caller's local.
program define _wa_expandtilde
    version 16.0
    syntax , LOCAL(name) [ PATH(string) ]
    local p `"`macval(path)'"'
    if `"`macval(p)'"' == "~" | strpos(`"`macval(p)'"', "~/") == 1 | strpos(`"`macval(p)'"', "~\") == 1 {
        if lower("`c(os)'") == "windows" local order "USERPROFILE HOMEDRIVEPATH HOME"
        else                              local order "HOME USERPROFILE HOMEDRIVEPATH"
        local home ""
        foreach src of local order {
            if `"`home'"' != "" continue
            if "`src'" == "HOMEDRIVEPATH" {
                local drive : env HOMEDRIVE
                local hpath : env HOMEPATH
                if `"`drive'`hpath'"' != "" local home `"`drive'`hpath'"'
            }
            else local home : env `src'
        }
        if `"`home'"' != "" {
            mata: st_local("rest", substr(st_local("p"), 2, .))
            if `"`rest'"' != "" {
                local cl = substr(`"`home'"', -1, 1)
                if `"`cl'"' == "/" | `"`cl'"' == "\" {
                    if length(`"`home'"') > 1 local home = substr(`"`home'"', 1, length(`"`home'"') - 1)
                    else local rest = substr(`"`rest'"', 2, .)
                }
            }
            local p `"`home'`macval(rest)'"'
        }
    }
    c_local `local' `"`macval(p)'"'
end


* Escape SMCL braces so Mata's printf() shows text exactly as received.
mata:
string scalar _wa_smclsafe(string scalar s)
{
    s = subinstr(s, "{", char(1))
    s = subinstr(s, "}", "{c )-}")
    return(subinstr(s, char(1), "{c -(}"))
}
end
