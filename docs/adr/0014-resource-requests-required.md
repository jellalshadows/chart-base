# ADR-0014: `resources.requests` are required

- **Status:** Accepted
- **Date:** 2026-09-27
- **Since:** 0.1.0
- **Related:** [ADR-0015](0015-pdb-and-topology-spread-by-default.md)

## Context

`resources` is one of the values `helm create`'s starter chart leaves empty (`{}`) by default, and it
is entirely legal Kubernetes for a pod to have no `resources` at all — it just means the container has
no request and no limit, and the scheduler and the Kubernetes autoscaling machinery treat it
accordingly: with nothing requested, the scheduler has no basis to reason about how much of a node the
pod needs, and any feature that scales based on utilization has nothing to compute a percentage of.

Two features chart-base ships as defaults depend directly on `requests` being set to mean anything:
the HorizontalPodAutoscaler (`autoscaling/v2`, `templates/hpa.yaml`) computes utilization as a
percentage of the container's requested CPU/memory — `targetCPUUtilizationPercentage` and
`targetMemoryUtilizationPercentage` are both percentages of `resources.requests`, not of a limit or of
node capacity — and the Kubernetes scheduler places every pod by comparing its requests against a
node's allocatable capacity. A component with no requests either cannot autoscale meaningfully (there
is no percentage to compute) or gets scheduled with no guarantee of the resources it actually needs,
which is a worse failure mode precisely because it is invisible until the node is under pressure.

Leaving `resources` optional in the schema does not remove this dependency — it only removes the one
place that could catch a component shipped without it before it ever runs.

## Decision

- `values.schema.json`'s `resources` object requires the `requests` key
  (`"required": ["requests"]`), and `requests` itself requires `cpu` and `memory`
  (`"required": ["cpu", "memory"]`, each typed `string` or `number`). Every component must set
  `resources.requests.cpu` and `resources.requests.memory`; there is no default value for either
  because there is no safe generic default across every workload chart-base might run.
- `resources.limits` stays entirely optional: the schema declares it as a plain, unconstrained object
  with no `required` entries, so a component may set some limits, all limits, or none.
- `resources` (verbatim, whatever the consumer set under `requests`/`limits`) is rendered onto the
  container as-is (`templates/_pod.tpl`); chart-base does not compute, cap, or default any resource
  value beyond requiring `requests.cpu`/`requests.memory` to exist.

## Consequences

- Every component chart-base renders has a well-defined resource footprint the scheduler can act on,
  and `autoscaling.enabled: true` always has a percentage it can compute against.
- Trade-off: a consumer who genuinely has no idea what to request (a new component, first deploy) is
  forced to guess something rather than skip the question — chart-base offers no low-effort escape
  hatch, and a bad guess (e.g. requesting far more than the workload needs) is not caught by the
  schema, which only checks that the keys exist, not that their values are reasonable.
- Requiring `requests` but not `limits` means a component with no limits can burst unbounded on a node
  that has capacity to spare, which is a deliberate trade favoring scheduling correctness over strict
  containment; a consumer that wants containment sets `limits` itself.

## Alternatives considered

### Optional `requests`

Lets a component ship with no resource footprint at all. The scheduler then has nothing to reason
about, and `autoscaling.enabled` has no requests to compute a percentage against — the HPA either
cannot be enabled meaningfully or silently computes utilization against zero, neither of which is
better than asking for the value up front.

### Resource presets (e.g. `size: small|medium|large` mapped to fixed requests/limits)

Rejected in the roadmap: a small fixed set of presets cannot fit every workload chart-base is generic
enough to run, and a preset that is wrong for a given component hides the actual numbers a consumer
would otherwise have to look at and justify — it trades an explicit, if inconvenient, requirement for a
convenient default that is silently wrong for some fraction of components.

## References

- `values.schema.json` (`resources`)
- `templates/_pod.tpl`
- `templates/hpa.yaml`
- [Kubernetes: Managing Resources for Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- [Kubernetes: Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
