# ADR-0069: A GRPCRoute, extra HTTPRoute rules and `appProtocol`

- **Status:** Accepted
- **Date:** 2026-11-18
- **Since:** 1.4.0
- **Related:** [ADR-0016](0016-httproute-first-ingress-optional.md) (amended), [ADR-0040](0040-networkpolicy-per-component-with-sibling-references.md) (amended), [ADR-0048](0048-httproute-parentrefs-and-matches-are-closed.md) (amended), [ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md), [ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md) (amended)

## Context

The 0.11.0 that was cut on 2026-11-02 planned four things:
- a GRPCRoute;
- HTTPRoute rules that replaced `httpRoute.matches`;
- `ports[].appProtocol`;
- stricter checks of the existing `httpRoute` fields.

Its design files were lost. The only record of its shape is the roadmap row from before the cut. Since 1.0.0,
`httpRoute.matches` is a frozen key ([ADR-0058](0058-the-1-0-contract-and-how-it-stays-frozen.md)), and a check that
rejects values that render is a major. So two parts of that plan cannot ship in a minor: replacing `matches` and the
stricter checks.

A component's HTTPRoute has one rule, which sends `httpRoute.matches` to the first `ports` entry. A component that
serves gRPC next to HTTP, or a path on another port, needs a second route in `extraObjects`. A cleartext gRPC backend
has one more need: its Service port must declare the protocol (`appProtocol: kubernetes.io/h2c`), or most Gateways
will not speak HTTP/2 to it.

## Decision

- **`ports[].appProtocol`** (optional) is written on the Service port only. A container port has no such field. The
  schema takes a non-empty string or `null`, and the API server checks the value.
- **`httpRoute.rules`** (default `[]`) adds rules, in order, after the one that `httpRoute.matches` makes. Each rule
  takes:
  - `matches`: `httpRouteMatch` entries, closed as in [ADR-0048](0048-httproute-parentrefs-and-matches-are-closed.md);
  - `port`: the name of the `ports` entry the rule sends to (absent or `null`: the first entry).

  The backend stays this component's Service. Values without `rules` render the same HTTPRoute as 1.3.
- **`grpcRoute`** (`enabled: false`) renders a GRPCRoute (`gateway.networking.k8s.io/v1`). It is in the Standard
  channel of Gateway API v1.6.2, which CI applies. It takes:
  - `parentRefs`, with the fields of `httpRoute.parentRefs`;
  - `hostnames`;
  - `matches`: closed `GRPCRouteMatch` entries, `method` and `headers`; empty means every request;
  - `port`: a `ports` entry by name; `null` means the first entry.

  It can be enabled with or without `httpRoute`. Both routes send to the same Service.
- **Guards, not schema conditionals.** The render fails on:
  - a rule without matches (it would take every request, as the first rule does);
  - a `port` that names no `ports` entry;
  - a GRPCRoute without `parentRefs`;
  - a GRPCRoute without `service.enabled`.

  The schema rejects a GRPCRoute on a CronJob or a Job, as it rejects an HTTPRoute there. A schema `if` on
  `grpcRoute.enabled` would not work: a `--reuse-values` upgrade from 1.3 has no `grpcRoute` at all, so the `if` would
  hold vacuously and the `then` would apply to every worker.
- **NetworkPolicy:** a GRPCRoute is a route for the guards of
  [ADR-0040](0040-networkpolicy-per-component-with-sibling-references.md). With `networkPolicy` on, it needs a source
  (`fromNamespaces`, `extra` or `routeTrafficAllowedElsewhere`), and with it `routeTrafficAllowedElsewhere` has an
  effect.
- **Required fields of an entry the consumer writes.** The new entries reuse the closed definitions, required fields
  included: a header match's `name` and `value`, a parent's `name`.
  - [ADR-0064](0064-from-1-0-0-a-new-key-is-optional.md)'s "never in `required`, at any level" is about the keys a
    `--reuse-values` upgrade can lack.
  - A field of an entry exists only because the consumer wrote that entry, so no upgrade can make it disappear.

## Consequences

- An HTTPRoute can send paths to different ports of the component, and a gRPC service gets its own route, without
  `extraObjects`.
- The first HTTPRoute rule keeps its frozen shape: `matches` to the first port.
- Several things are left out, and each can be added later without breaking anything:
  - filters;
  - timeouts;
  - several backends in one rule;
  - GRPCRoute rules beyond the first.
- The stricter checks of the existing `httpRoute` fields wait for a major.
- `ci/full-values.yaml` renders all three features. kubeconform checks them against the pinned CRD schemas, and the
  e2e's API server stores them.

## Alternatives considered

### `httpRoute.rules` replacing `matches` (the 0.11.0 plan)

It removes a frozen key, so it is a major.

### A schema `if`/`then` for the GRPCRoute's when-enabled keys, as for `httpRoute`

When a `--reuse-values` upgrade leaves `grpcRoute` absent, the `if` holds vacuously, and the `then` would require
`service.enabled` of every component.

### A backend per rule (any Service, any port number)

The chart routes to its own component. A route to another backend belongs to another component, or to
`extraObjects`.
