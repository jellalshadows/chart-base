# ADR-0028: `podLabels` cannot override the selector labels

- **Status:** Accepted
- **Date:** 2026-09-28
- **Since:** 0.1.0

## Context

A Deployment's `spec.selector` is immutable once the object exists, and chart-base builds it from
`chart-base.selectorLabels` (`templates/_labels.tpl`): `app.kubernetes.io/name` and
`app.kubernetes.io/instance`. Those same two labels sit in every pod's own labels too, through
`chart-base.podLabels`, which layers `.Values.podLabels` on top of the chart's own base labels
(`templates/_labels.tpl`). `values.yaml` exposes `podLabels` precisely so a consumer can attach arbitrary
extra labels to pods — for a service mesh, a cost-allocation tag, whatever their own tooling needs — without
touching chart-base's templates at all.

Nothing in Kubernetes stops a consumer from writing `podLabels: {"app.kubernetes.io/name": "something-else"}`.
A Deployment's pod template labels must be a superset of its own `spec.selector.matchLabels` for the API
server to accept the object; if a consumer's `podLabels` collided with `app.kubernetes.io/name` or
`app.kubernetes.io/instance` and diverged from what the selector actually asks for, the Deployment would be
rejected at apply time — or, worse, only start failing on a later `helm upgrade` once the labels have
actually diverged, rather than on the first install. The branch's final review before 0.1.0 caught this and
pushed the check earlier, into the schema itself (Spec §14.1, A14).

## Decision

- `values.schema.json`'s `podLabels` property declares `"propertyNames": {"not": {"enum":
  ["app.kubernetes.io/name", "app.kubernetes.io/instance"]}}` — any key with either of those two exact names
  inside `podLabels` fails schema validation, with the schema naming the offending property (e.g. `invalid
  propertyName 'app.kubernetes.io/name'`).
- This rejects only the two label keys chart-base itself reserves to build the Deployment's selector
  (`chart-base.selectorLabels`); every other key in `podLabels` remains free for consumer use.
- The check runs at `helm lint --strict`/`helm template` time — and therefore in CI's `lint` job — well
  before anything reaches the Kubernetes API server.

## Consequences

- A consumer who tries to override either selector-identity label through `podLabels` gets an immediate,
  specific schema error instead of a Deployment rejected by the API server, or — worse — one that installs
  cleanly on the first pass and only breaks on a later `helm upgrade` once the two label sets have diverged.
- Trade-off: this closes only the two label keys chart-base itself owns. It does nothing to prevent a
  consumer from choosing a different `podLabels` key that collides with some *other* tool's own selector
  expectations (a service mesh's, for instance) — the schema protects chart-base's own selector contract,
  not every possible label collision a cluster might care about.

## Alternatives considered

### Letting the install fail at the API server

The error would surface late — at `helm upgrade`/`kubectl apply`, or, worse, only on a subsequent upgrade
once the pod template's labels and the selector have already diverged — and would report the API server's
own generic rejection instead of the actual `podLabels` key that caused it.

### Silently dropping the keys

A consumer who set `podLabels["app.kubernetes.io/name"]` expecting it to take effect would see no error and
no effect at all — a worse outcome than failing loudly, because nothing signals that anything went wrong.

## References

- `values.schema.json` (`podLabels.propertyNames`)
- `templates/_labels.tpl` (`chart-base.selectorLabels`, `chart-base.podLabels`)
- `templates/deployment.yaml` (`spec.selector.matchLabels`)
- Design spec §14.1 (A14)
