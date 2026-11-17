#!/usr/bin/env bash
# Renders every YAML block under the README's "## Recipes" through a throwaway umbrella and validates the manifests
# with kubeconform on the CI edges, Kubernetes 1.33.12 and 1.37.0, with the schema locations of validate-manifests.sh.
# Usage: readme-recipes.sh <chart-dir> [<out-dir>]     Requires: helm, kubeconform, yq (mikefarah v4)
#   <out-dir>, empty or new: keep the work there instead of a temporary directory removed on exit: <NN>/ the
#   umbrella of values block NN (its values.yaml, an override file next to it, charts/ filled: installable with
#   `helm install vending <out-dir>/<NN> --namespace vending [-f <out-dir>/<NN>/values-<name>.yaml]`),
#   <NN>-manifest.yaml for a manifest block, blocks/ every block as extracted and every render.
#
# Extraction (deterministic; docs/guides/testing.md, "README recipes"): README.md (the generated file, where the
# template escapes are resolved), from the line "## Recipes" to the next "## " heading. A line that is exactly ```yaml
# opens a block and the next line that is exactly ``` closes it; any other fence is skipped whole. Blocks are numbered
# in document order and reported by their first line and their "### " heading. Each block is one of:
#   - a manifest: a top-level apiVersion and kind; validated with kubeconform as written;
#   - an override file: its first line is "# values-<name>.yaml"; rendered with -f over the values block before it;
#   - umbrella values (every other block): each top-level key is an alias of chart-base, except global and keys that
#     start with "x-" (an umbrella key that only holds YAML anchors); rendered as the release "vending" in the
#     namespace "vending".
set -euo pipefail

chart_src="${1:?usage: readme-recipes.sh <chart-dir> [<out-dir>]}"
readme="$chart_src/README.md"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kube_versions=(1.33.12 1.37.0) # the edges of the kubeconform steps of ci.yaml (ADR-0018)

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$readme" ] || fail "no README.md in $chart_src"

if [ -n "${2:-}" ]; then
  work="$2"
  mkdir -p "$work"
  shopt -s nullglob dotglob
  existing=("$work"/*)
  shopt -u nullglob dotglob
  [ "${#existing[@]}" -eq 0 ] || fail "$work is not empty: the umbrellas go in an empty or new directory"
else
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
fi

# One pinned source for the schemas: the values validate-manifests.sh assigns.
assigned() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in "$1=\""*'"') line="${line#"$1=\""}"; printf '%s\n' "${line%\"}"; return 0 ;; esac
  done < "$script_dir/validate-manifests.sh"
  fail "no $1=\"...\" line in $script_dir/validate-manifests.sh: the kubeconform schema locations moved"
}
k8s_schemas="$(assigned k8s_schemas)"
crd_schemas="$(assigned crd_schemas)"

# The chart next to the umbrellas, referenced with a relative file:// path (alias-contract.sh says why).
mkdir -p "$work/chart-base" "$work/blocks" "$work/kubeconform-cache"
cp -r "$chart_src"/Chart.yaml "$chart_src"/values.yaml "$chart_src"/values.schema.json "$chart_src"/templates "$work/chart-base/"

# Extraction.
n=0 lineno=0 heading="" in_recipes=false in_yaml=false in_other=false
declare -a block_file block_line block_heading
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line="${line%$'\r'}"
  if $in_yaml; then
    if [ "$line" = '```' ]; then in_yaml=false; else printf '%s\n' "$line" >> "${block_file[n]}"; fi
    continue
  fi
  if $in_other; then
    case "$line" in '```'*) in_other=false ;; esac
    continue
  fi
  case "$line" in
    '## Recipes') in_recipes=true; continue ;;
    '## '*) if $in_recipes; then break; fi; continue ;;
  esac
  $in_recipes || continue
  case "$line" in
    '### '*) heading="${line#'### '}" ;;
    '```yaml')
      n=$((n + 1))
      block_file[n]="$work/blocks/$(printf '%02d' "$n").yaml"
      block_line[n]=$((lineno + 1))
      block_heading[n]="$heading"
      : > "${block_file[n]}"
      in_yaml=true
      ;;
    '```'*) in_other=true ;;
  esac
done < "$readme"
$in_yaml && fail "README.md:${block_line[n]}: the yaml block is not closed"
[ "$n" -gt 0 ] || fail "README.md: no yaml block under '## Recipes' (nothing to check: was the section renamed?)"

failures=0 values=0 overrides=0 manifests=0 last_values=0
declare -a block_dir block_aliases
report() { # <block> <what failed> <output>
  echo "FAIL: README.md:${block_line[$1]} (recipe \"${block_heading[$1]}\"): $2" >&2
  printf '%s\n' "$3" | while IFS= read -r l; do printf '    %s\n' "$l" >&2; done
  failures=$((failures + 1))
}
validate() { # <block> <rendered file> <kubernetes version> <what was rendered>: kubeconform, strict, the CI schemas
  local out
  if ! out="$(kubeconform -strict -summary -cache "$work/kubeconform-cache" -kubernetes-version "$3" \
    -schema-location "$k8s_schemas" -schema-location "$crd_schemas" "$2" 2>&1)"; then
    report "$1" "kubeconform rejects $4 on Kubernetes $3" "$out"
    return 1
  fi
}
render() { # <block> [helm args...]: helm template of the block's umbrella, then kubeconform, on every version
  local b="$1" v out rendered ok=true
  shift
  for v in "${kube_versions[@]}"; do
    if ! out="$(helm template vending "${block_dir[b]}" --namespace vending --kube-version "$v" "$@" 2>&1)"; then
      report "$b" "helm template on Kubernetes $v fails (aliases: ${block_aliases[b]})" "$out"
      ok=false
      continue
    fi
    rendered="$work/blocks/$(printf '%02d' "$b").rendered-$v.yaml"
    printf '%s\n' "$out" > "$rendered"
    validate "$b" "$rendered" "$v" "the render (aliases: ${block_aliases[b]})" || ok=false
  done
  $ok
}

for b in $(seq 1 "$n"); do
  f="${block_file[b]}"
  first=""
  IFS= read -r first < "$f" || true
  slug="$(printf '%02d' "$b")"
  if [[ "$first" =~ ^#\ (values-[A-Za-z0-9._-]+\.yaml)$ ]]; then
    overrides=$((overrides + 1))
    base="$last_values"
    [ -n "${block_dir[base]:-}" ] || { report "$b" "an override file with no umbrella before it" "$first"; continue; }
    cp "$f" "${block_dir[base]}/${BASH_REMATCH[1]}"
    block_dir[b]="${block_dir[base]}" block_aliases[b]="${block_aliases[base]}"
    render "$b" -f "${block_dir[b]}/${BASH_REMATCH[1]}" \
      && echo "ok - README.md:${block_line[b]} ${BASH_REMATCH[1]} over README.md:${block_line[base]} (${block_heading[b]})"
    continue
  fi
  if ! kind="$(yq 'has("apiVersion") and has("kind")' "$f" 2>&1)"; then
    report "$b" "the block is not YAML" "$kind"
    continue
  fi
  if [ "${kind%$'\r'}" = true ]; then
    manifests=$((manifests + 1))
    cp "$f" "$work/$slug-manifest.yaml"
    for v in "${kube_versions[@]}"; do validate "$b" "$f" "$v" "the manifest" || true; done
    echo "ok - README.md:${block_line[b]} a manifest (${block_heading[b]})"
    continue
  fi
  values=$((values + 1))
  last_values="$b"
  aliases=()
  while IFS= read -r key; do
    key="${key%$'\r'}"
    case "$key" in global | x-*) ;; *) aliases+=("$key") ;; esac
  done < <(yq 'keys | .[]' "$f")
  [ "${#aliases[@]}" -gt 0 ] || { report "$b" "umbrella values without an alias" "$(< "$f")"; continue; }
  block_dir[b]="$work/$slug"
  block_aliases[b]="${aliases[*]}"
  mkdir -p "${block_dir[b]}/templates"
  {
    echo "apiVersion: v2"
    echo "name: vending"
    echo "version: 0.1.0"
    echo "dependencies:"
    for alias in "${aliases[@]}"; do
      echo "  - name: chart-base"
      echo "    version: \">=0.0.0-0\""
      echo "    repository: \"file://../chart-base\""
      echo "    alias: ${alias}"
      echo "    condition: ${alias}.enabled"
    done
  } > "${block_dir[b]}/Chart.yaml"
  echo "README recipe umbrella" > "${block_dir[b]}/templates/NOTES.txt"
  cp "$f" "${block_dir[b]}/values.yaml"
  if ! out="$(helm dependency update "${block_dir[b]}" 2>&1)"; then
    report "$b" "helm dependency update fails" "$out"
    continue
  fi
  render "$b" && echo "ok - README.md:${block_line[b]} ${block_aliases[b]} (${block_heading[b]})"
done

summary="$n yaml blocks under '## Recipes' (umbrella values: $values, override files: $overrides, manifests: $manifests), Kubernetes ${kube_versions[*]}"
[ "$failures" -eq 0 ] || fail "readme recipes: $failures failed checks in $summary"
echo "readme recipes: every block renders and validates: $summary"
