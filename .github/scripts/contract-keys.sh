#!/usr/bin/env bash
# The values keys of the 1.0 contract (ADR-0058): lists every key a values file can set, as a path read from
# values.schema.json (a map entry is <name>, a list item []), and compares the list with the committed one.
# A key that is gone fails: a removed or renamed key is a major change. A key that is not listed fails too, until the
# list that holds it is committed with the change that adds it.
# Usage: contract-keys.sh <chart-dir> [<keys-file>]   compare (default keys file: <chart-dir>/tests/contract/keys.txt)
#        contract-keys.sh --add <chart-dir> [<keys-file>]
#            write the union of the keys file and the schema's keys into the keys file, after adding a key: it never
#            drops a line, so a removed key stays listed (and compare keeps failing) until its line is deleted by hand
#        contract-keys.sh --list <chart-dir>         print the schema's keys
#        contract-keys.sh --base <commit> <chart-dir> [<pr-title>]
#            fail when <chart-dir>/tests/contract/keys.txt lost a line against the same file at <commit> (the pull
#            request's base), unless <pr-title> marks a breaking change ("type!: ..." or "type(scope)!: ..."); a base
#            without the file passes. The commit must be fetched (CI: actions/checkout with fetch-depth: 0).
# Needs jq; --base needs git.
set -euo pipefail

usage="usage: contract-keys.sh <chart-dir> [<keys-file>] | --add <chart-dir> [<keys-file>] | --list <chart-dir> | --base <commit> <chart-dir> [<pr-title>]"
mode=compare
case "${1:-}" in
  --add | --list) mode="${1#--}"; shift ;;
  --base) mode=base; base="${2:?$usage}"; shift 2 ;;
esac
chart_dir="${1:?$usage}"
schema="$chart_dir/values.schema.json"
[ -f "$schema" ] || { echo "contract-keys: $schema not found" >&2; exit 2; }

# --base: the committed list of the base against the list of this change, line by line (the compare mode checks that
# this change's list is the schema's). The title is never printed: it is the pull request author's text.
if [ "$mode" = base ]; then
  title="${2:-}"
  list=tests/contract/keys.txt
  git -C "$chart_dir" cat-file -e "$base^{commit}" 2> /dev/null || {
    echo "contract-keys: the base commit $base is not in the clone: fetch it (actions/checkout with fetch-depth: 0)" >&2
    exit 2
  }
  if ! before="$(git -C "$chart_dir" show "$base:./$list" 2> /dev/null)"; then
    echo "contract-keys: $base has no $list: nothing to compare (the list starts with this change)"
    exit 0
  fi
  [ -f "$chart_dir/$list" ] || { echo "contract-keys: $chart_dir/$list not found" >&2; exit 2; }
  lost="$(LC_ALL=C comm -23 <(printf '%s\n' "$before" | tr -d '\r' | LC_ALL=C sort -u) \
    <(tr -d '\r' < "$chart_dir/$list" | LC_ALL=C sort -u))"
  if [ -z "$lost" ]; then
    echo "contract-keys: no line of $list at $base is gone ($(printf '%s\n' "$before" | wc -l | tr -d ' ') there, $(wc -l < "$chart_dir/$list" | tr -d ' ') now)"
    exit 0
  fi
  echo "contract-keys: these lines of $list at $base are gone from it:"
  printf '%s\n' "$lost" | while IFS= read -r key; do echo "  - $key"; done
  if [[ "$title" =~ ^[a-z]+(\([^()]+\))?!:\  ]]; then
    echo "contract-keys: the pull request title marks a breaking change (type!:), so the removal is accepted (ADR-0058)."
    exit 0
  fi
  echo "A removed or renamed key is a major change (ADR-0058): restore the line, or mark the pull request breaking" \
    "(a title \"type!: ...\" or \"type(scope)!: ...\")."
  exit 1
fi
keys_file="${2:-$chart_dir/tests/contract/keys.txt}"

# Walks the schema from its root: properties, items, additionalProperties and patternProperties name the keys (a map
# entry is <name> under either of the last two; a false schema under properties is a rejected key, ADR-0068); $ref (to a definition),
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
          ( ($node.properties // {}) | to_entries[] | select(.value != false) | ($prefix + [.key]) as $p | $p, keys_of(.value; $p; $seen) ),
          ( if ($node.items | type) == "object" then keys_of($node.items; $prefix + ["[]"]; $seen) else empty end ),
          ( if ($node.additionalProperties | type) == "object"
            then keys_of($node.additionalProperties; $prefix + ["<name>"]; $seen) else empty end ),
          ( ($node.patternProperties // {}) | to_entries[] | select((.value | type) == "object")
            | keys_of(.value; $prefix + ["<name>"]; $seen) ),
          ( (($node.allOf // []), ($node.anyOf // []), ($node.oneOf // [])) | .[] | keys_of(.; $prefix; $seen) ),
          ( ($node.then, $node.else) | select(. != null) | keys_of(.; $prefix; $seen) )
        end;
      [keys_of(.; []; []) | map(if . == "[]" then . else "." + . end) | join("") | ltrimstr(".")] | unique | .[]
  ' "$schema" | tr -d '\r'
}

if [ "$mode" = list ]; then
  list_keys
  exit 0
fi

# --add: the union, sorted by byte (the code point order of jq's unique: the keys are ASCII), so that regenerating the
# list can only add lines; a removal is a line deleted by hand, which a reviewer sees and --base checks.
if [ "$mode" = add ]; then
  union="$( { list_keys; [ ! -f "$keys_file" ] || tr -d '\r' < "$keys_file"; } | LC_ALL=C sort -u)"
  before=0
  [ ! -f "$keys_file" ] || before="$(tr -d '\r' < "$keys_file" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  printf '%s\n' "$union" > "$keys_file"
  echo "contract-keys: $keys_file lists $(printf '%s\n' "$union" | wc -l | tr -d ' ') keys ($before before); no line was removed"
  exit 0
fi

[ -f "$keys_file" ] || {
  echo "contract-keys: $keys_file not found: write it with .github/scripts/contract-keys.sh --add <chart-dir>" >&2
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
  echo "A removed or renamed key is a major change (ADR-0058): restore the key, or, for a major, delete its line by" \
    "hand (CI then requires a breaking pull request title, contract-keys.sh --base)."
  status=1
fi
if [ -n "$added" ]; then
  echo "contract-keys: these keys of values.schema.json are not in $keys_file:"
  printf '%s\n' "$added" | while IFS= read -r key; do echo "  + $key"; done
  echo "A new key joins the contract: commit it with the change that adds it" \
    "(.github/scripts/contract-keys.sh --add . adds it to the list and never removes a line)."
  status=1
fi
if [ "$status" -eq 0 ]; then
  echo "contract-keys: the $(printf '%s\n' "$current" | wc -l | tr -d ' ') keys of values.schema.json match $keys_file"
fi
exit "$status"
