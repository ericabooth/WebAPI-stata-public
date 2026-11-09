*! test_webapi.do  v0.1.3  (adds the \$limit case)
*! Smoke test for webapi against two public JSON APIs (no credentials needed).
version 16.0
clear all
set more off

capture which webapi
if _rc {
    display as error "webapi is not on the adopath. Install it first (see README.md)."
    exit 199
}

*-----------------------------------------------------------------------------
* (1) A plain public JSON array of objects.  Nested fields (address, company)
*     flatten automatically to dotted -> underscored column names.
*-----------------------------------------------------------------------------
webapi get using "https://jsonplaceholder.typicode.com/users", clear
describe, short
assert _N == 10
list id name addresscity in 1/3, noobs

*-----------------------------------------------------------------------------
* (2) A real health API: CDC's NCHS leading-causes-of-death dataset on the
*     Socrata platform.  Simple field filters (year, cause_name) are passed as
*     query parameters; a request header is attached.  records("") means the
*     reply is itself the array of records.
*     NOTE: Socrata's $limit / $select parameters begin with "$", which Stata
*     would read as a global macro.  Type the "$" as \$ (see case 2b);
*     `=char(36)' does not work, because Stata expands the result again.
*-----------------------------------------------------------------------------
webapi get using "https://data.cdc.gov/resource/bi63-dtpu.json",            ///
    params("year=2017|cause_name=All causes")                              ///
    headers("Accept:application/json") clear
local got = r(nrows)
local code = r(http)
destring deaths aadr, replace force
keep state deaths aadr
gsort -deaths
list in 1/6, noobs
display as result "webapi returned `got' rows over HTTP `code'"

*-----------------------------------------------------------------------------
* (2b) A SoQL clause that begins with "$", typed as \$.  A global named
*      $limit must not leak into the request (webapi v0.1.3 and later).
*-----------------------------------------------------------------------------
global limit "NOT_SENT"
webapi get using "https://data.cdc.gov/resource/bi63-dtpu.json",            ///
    params("\$limit=3|year=2017") clear
assert _N == 3
macro drop limit

*-----------------------------------------------------------------------------
* (3) POST -- create a resource; the reply is the single created object.
*-----------------------------------------------------------------------------
webapi post using "https://jsonplaceholder.typicode.com/posts",             ///
    body(`"{"title":"CHR uninsured note","userId":7}"') records("") clear
assert _N == 1
list, noobs

*-----------------------------------------------------------------------------
* (4) EVERY -- poll a live endpoint on an interval.  Each snapshot stacks
*     into a panel with a _poll index and a _polltime wall-clock stamp, so a
*     live feed becomes a small time series without an external scheduler.
*-----------------------------------------------------------------------------
webapi get using                                                            ///
    "https://timeapi.io/api/Time/current/zone?timeZone=America/Chicago",     ///
    records("") every(1) times(3) clear
assert _N == 3
list _poll seconds, noobs

display as result _n "TEST_WEBAPI_DONE"
