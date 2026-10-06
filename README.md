# json2dir-awk

json2dir in GNU awk (launcher approach): `json2dir.awk` (plain gawk, no `system()`, no pipes, no extensions) validates the JSON document and emits a shell script, and the POSIX sh launcher `json2dir` runs that script.

    JSON2DIR_GAWK=/path/to/gawk ./json2dir < tree.json
