#!/usr/bin/env bash
# The values keys of the 1.0 contract (ADR-0058): lists every key a values file can set, as a path read from
# values.schema.json (a map entry is <name>, a list item []), and compares the list with the committed one.
# A key that is gone fails: a removed or renamed key is a major change. A key that is not listed fails too, until the
# list that holds it is committed with the change that adds it.
# Usage: contract-keys.sh <chart-dir> [<keys-file>]   compare (default keys file: <chart-dir>/tests/contract/keys.txt)
#        contract-keys.sh --list <chart-dir>         print the list (to regenerate the keys file after adding a key)
# Needs jq.
set -euo pipefail

usage="usage: contract-keys.sh <chart-dir> [<keys-file>] | contract-keys.sh --list <chart-dir>"
list_only=false
if [ "${1:-}" = --list ]; then
  list_only=true
  shift
fi
chart_dir="${1:?$usage}"
keys_file="${2:-$chart_dir/tests/contract/keys.txt}"
schema="$chart_dir/values.schema.json"
[ -f "$schema" ] || { echo "contract-keys: $schema not found" >&2; exit 2; }

# Walks the schema from its root: properties, items and additionalProperties name the keys; $ref (to a definition),
# allOf, anyOf, oneOf, then and else add the keys of the same node (if and not only constrain them). A definition
# already on the path is not entered again. jq's unique sorts by code point, so the order does not depend on the locale.
# tr: a native jq.exe on Windows writes CRLF.
list_keys() {
  jq -r '
    .definitions as $defs
    | def keys_of($node; $prefix; $seen):
        if ($node | type) != "object" then empty
        else
          ( if ($node["$ref"] | type) == "string" then
              ($node["$ref"] | ltrimstr("#/definitions/")) as $d
              | if ($seen | any(. == $d)) then empty else keys_of($defs[$d]; $prefix; $seen + [$d]) end
            else empty end ),
          ( ($node.properties // {}) | to_entries[] | ($prefix + [.key]) as $p | $p, keys_of(.value; $p; $seen) ),
          ( if ($node.items | type) == "object" then keys_of($node.items; $prefix + ["[]"]; $seen) else empty end ),
          ( if ($node.additionalProperties | type) == "object"
            then keys_of($node.additionalProperties; $prefix + ["<name>"]; $seen) else empty end ),
          ( (($node.allOf // []), ($node.anyOf // []), ($node.oneOf // [])) | .[] | keys_of(.; $prefix; $seen) ),
          ( ($node.then, $node.else) | select(. != null) | keys_of(.; $prefix; $seen) )
        end;
      [keys_of(.; []; []) | map(if . == "[]" then . else "." + . end) | join("") | ltrimstr(".")] | unique | .[]
  ' "$schema" | tr -d '\r'
}

if $list_only; then
  list_keys
  exit 0
fi

[ -f "$keys_file" ] || {
  echo "contract-keys: $keys_file not found: write it with .github/scripts/contract-keys.sh --list <chart-dir> > $keys_file" >&2
  exit 2
}

current="$(list_keys)"
committed="$(tr -d '\r' < "$keys_file")"
removed="$(LC_ALL=C comm -13 <(printf '%s\n' "$current" | LC_ALL=C sort) <(printf '%s\n' "$committed" | LC_ALL=C sort))"
added="$(LC_ALL=C comm -23 <(printf '%s\n' "$current" | LC_ALL=C sort) <(printf '%s\n' "$committed" | LC_ALL=C sort))"

status=0
if [ -n "$removed" ]; then
  echo "contract-keys: these keys of $keys_file are gone from values.schema.json:"
  printf '%s\n' "$removed" | while IFS= read -r key; do echo "  - $key"; done
  echo "A removed or renamed key is a major change (ADR-0058): restore the key."
  status=1
fi
if [ -n "$added" ]; then
  echo "contract-keys: these keys of values.schema.json are not in $keys_file:"
  printf '%s\n' "$added" | while IFS= read -r key; do echo "  + $key"; done
  echo "A new key joins the contract: commit it with the change that adds it" \
    "(.github/scripts/contract-keys.sh --list . > tests/contract/keys.txt)."
  status=1
fi
if [ "$status" -eq 0 ]; then
  echo "contract-keys: the $(printf '%s\n' "$current" | wc -l | tr -d ' ') keys of values.schema.json match $keys_file"
fi
exit "$status"
