# ADR-0008: Names are `<release>-<alias>` and never truncated

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0

## Context

Every component under an alias needs a resource name that is unique within the umbrella's release,
predictable, and stable enough that renaming an alias is a deliberate, visible action rather than an
accident. `helm create`'s scaffolded `fullname` helper truncates the computed name to 63 characters
(the Kubernetes object name limit) with `trunc 63 | trimSuffix "-"`, and takes a shortcut when the
release name already contains the chart name: it uses the release name alone. Under an alias, that
shortcut is actively dangerous — a release named `wholesales` with an alias `sales` would collide
with the shortcut's `contains` check and its output would just be `wholesales`, silently dropping the
alias from the name and colliding with any other alias whose name also happens to be contained in
the release name.

chart-base's own name helper, `chart-base.fullname` (`templates/_names.tpl`), does neither: it always
prints `<release>-<component>`, where `component` is `.Chart.Name` — which Helm replaces with the
declared alias for an aliased subchart (`chart-base.component`). There is no shortcut and no
truncation anywhere in the helper.

Kubernetes' own object name limit (63 characters, a DNS label / RFC 1123 subdomain segment
constraint) is not the only one that matters here: a `CronJob`'s controller creates each run's `Job`
by appending an 11-character timestamp suffix to the `CronJob`'s name, so a `CronJob` name longer
than 52 characters produces `Job` names over 63 characters that the API server rejects outright —
the `CronJob` is created successfully but can never run anything (documented on the Kubernetes
`CronJob` page). `templates/validate.yaml` enforces exactly this pair of limits with a `fail` guard:
63 characters for every other workload type, 52 for `cronjob`, computed from the same `fullname` the
templates use, with no truncation as an escape hatch — an over-limit name fails the render with a
message naming the resource and both the actual and the maximum length.

Because `helm lint`'s template rendering always substitutes a fixed placeholder release name,
`test-release` (`pkg/chart/v2/lint/rules/template.go` in Helm's own source, `ReleaseOptions{Name:
"test-release", ...}`), a name-length guard tied to a real, longer release name would never trigger
under `helm lint` alone — CI additionally renders with `helm template` against the real scenario
values (`ci/*-values.yaml`), which use realistic release/alias combinations, to actually exercise the
length guard.

## Decision

- `chart-base.fullname` (`templates/_names.tpl`) always renders `<.Release.Name>-<component>`, where
  `component` is `chart-base.component` (`.Chart.Name`, the alias under an aliased dependency). No
  `contains` shortcut, no truncation.
- `templates/validate.yaml` computes the maximum allowed length as `63` for every `workload.type`
  except `cronjob`, which gets `52` (`ternary 52 63 (eq .Values.workload.type "cronjob")`), and fails
  the render with `chart-base.fail` when `fullname` exceeds it, naming the resource, its actual
  length and the limit.
- `templates/validate.yaml` also requires both the alias (`component`) and the full resource name
  (`fullname`) to match the DNS-1035 pattern `^[a-z]([-a-z0-9]*[a-z0-9])?$` (lowercase, kebab-case,
  starting with a letter), failing otherwise.
- Renaming an alias changes `fullname` for every one of its resources: Kubernetes treats it as
  deleting the old objects and creating new ones, there is no rename-in-place.
- `helm lint`'s own template rendering always uses release name `test-release`, so length guards are
  additionally exercised in CI with `helm template <umbrella>` against the `ci/*-values.yaml`
  scenarios, using realistic release names, not `helm lint` alone.

## Consequences

- Two components can never silently collide on the same name; a name collision either cannot happen
  (different aliases always produce different names) or is caught immediately by the DNS-1035 guard.
- A too-long combination of release name and alias is a hard failure with a clear message, not a
  silently truncated name that might collide with another component — the trade-off is that an
  umbrella author must pick a shorter alias or a shorter release name themselves; chart-base offers no
  automatic fix.
- Renaming an alias is a disruptive operation (delete and recreate every one of its objects,
  including its Secret and PersistentVolumeClaims if any existed), which is deliberate but must be
  understood by whoever renames one.

## Alternatives considered

### The `helm create` scaffolded `fullname` helper

Its `contains` shortcut (using the release name alone when it already contains the chart name) and
its truncation to 63 characters can make two differently-named components collide on the same
rendered name with no warning — exactly the failure mode chart-base's own helper and guard are built
to prevent.

## References

- `templates/_names.tpl`
- `templates/validate.yaml`
- `ci/full-values.yaml` (and the other `ci/*-values.yaml` scenarios)
- [Kubernetes: CronJob](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)
- [helm/helm `pkg/chart/v2/lint/rules/template.go`](https://github.com/helm/helm/blob/main/pkg/chart/v2/lint/rules/template.go)
