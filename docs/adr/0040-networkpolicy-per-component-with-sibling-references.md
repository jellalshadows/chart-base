# ADR-0040: One opt-in NetworkPolicy per component, with sibling components referenced by alias

- **Status:** Accepted
- **Date:** 2026-10-02
- **Since:** 0.5.0
- **Related:** [ADR-0001](0001-application-chart-consumed-through-aliases.md), [ADR-0011](0011-strict-draft-07-schema.md), [ADR-0027](0027-required-keys-in-the-schema.md), [ADR-0036](0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md), [ADR-0038](0038-one-metrics-endpoint-servicemonitor-or-podmonitor.md), [ADR-0041](0041-job-component-networkpolicy-is-a-hook.md)

## Context

A domain umbrella deploys every component of a domain into one namespace, each as an alias of chart-base
([ADR-0001](0001-application-chart-consumed-through-aliases.md)). Without a NetworkPolicy every pod accepts
connections from every pod of the cluster and may open any connection. The facts that shape a chart's policy
(Kubernetes documentation, *Network Policies*, and `staging/src/k8s.io/api/networking/v1/types.go` at v1.37.0):

- **Enforcement is the CNI's.** "Creating a NetworkPolicy resource without a controller that implements it
  will have no effect." Nothing in the API says whether a policy is enforced, or when: "there is no way to tell
  from the Kubernetes API when exactly that happens". On EKS, the Amazon VPC CNI enforces policies only after its
  network policy parameter is enabled (EKS user guide, *Restrict Pod network traffic with Kubernetes network
  policies*, step 2).
- **Isolation is per direction, and policies only add.** A pod is isolated for ingress (or egress) when some
  policy that selects it lists `Ingress` (or `Egress`) in `policyTypes`; it then accepts only "those from the
  pod's node and those allowed by the `ingress` list of some NetworkPolicy", the union of every policy. A
  connection needs both the source's egress and the destination's ingress to allow it. Without `policyTypes`,
  `Ingress` is always set and `Egress` only when there are egress rules.
- **An empty list means everything.** An empty or missing `ports` list "matches all ports", an empty or missing
  `from` (or `to`) list "matches all sources" (destinations). A template that renders `ports: []` for a component
  without ports opens every port instead of none.
- **Peers.** A `podSelector` alone selects pods of the policy's namespace; a `podSelector` and a
  `namespaceSelector` in one peer select those pods in those namespaces; an `ipBlock` cannot be combined with a
  selector, and a peer needs at least one of them (`ValidateNetworkPolicyPeer`, v1.33.12). A namespace is selected
  by name through the label `kubernetes.io/metadata.name`, which the control plane sets on every namespace and
  which cannot be changed.
- **`ipBlock` is for addresses outside the cluster.** The documentation says CIDRs "should be cluster-external
  IPs", and whether NAT happens before or after policy evaluation depends on the implementation. On GKE Dataplane V2
  "Pod traffic is never covered by an `ipBlock` rule"; kindnet, the CNI of the e2e, does match pod IPs with
  `ipBlock` (kube-network-policies `f67f0fb35e2b`, `pkg/networkpolicy/networkpolicy.go`).
- **Named ports resolve on the target pod**: on the selected pod for ingress, on each destination pod for egress.
  chart-base already names every container port and renders each Service `targetPort` by that name.
- **A component cannot read its siblings' values**: a subchart sees only its own values and `global` (Helm
  documentation, *Subcharts and Global Values*), and chart-base ignores `global`. Its own `ports` are known; a
  sibling's are not. What it does know about a sibling is its selector labels: `app.kubernetes.io/name` is the
  alias and `app.kubernetes.io/instance` the release.
- **Traffic sources of a component.** Its siblings; the Gateway's proxy pods or the ingress controller's pods,
  whose namespace depends on the installation (in its default mode, Envoy Gateway creates the proxies "in the
  namespace where Envoy Gateway is running", not in the Gateway's: Envoy Gateway documentation, *Deployment Modes*);
  Prometheus, which scrapes the pod IP and container port directly, from a namespace
  that kube-prometheus-stack does not fix (OpenShift uses `openshift-monitoring`); the kubelet, from the node. The
  traffic of a `hostNetwork` controller is, in the most common implementations, treated as node traffic (the
  documentation allows a plugin to apply selectors to it or not), and Cilium's Ingress and Gateway API send traffic
  from a per-node Envoy with the identity `reserved:ingress`, which Cilium's own policies select (Cilium
  documentation, *Ingress and Network Policy*; a Cilium maintainer in cilium/cilium#36509, 2024-12-11, Cilium 1.16:
  a CiliumNetworkPolicy is required; current releases unverified). A standard NetworkPolicy cannot select that
  identity, so `extra` cannot allow it either: a namespace selector cannot be relied on for either source, and the
  Cilium traffic is allowed in a CiliumNetworkPolicy, outside this chart.
- **Destinations of a component.** The cluster DNS: pods labelled `k8s-app: kube-dns` in `kube-system` on kubeadm
  (kind), EKS, GKE with kube-dns, AKS and k3s, listening on port 53 on kubeadm and k3s (their manifests); on OpenShift, pods
  labelled `dns.operator.openshift.io/daemonset-dns: default` in `openshift-dns`, listening on port 5353
  (cluster-dns-operator manifests).
  NodeLocal DNSCache runs on the host network and listens on a link-local address (usually `169.254.20.10`), so a
  pod selector usually does not match it. The `ipBlock` is the address the pods actually query: `169.254.20.10/32`
  when the kubelet's `clusterDNS` points at the NodeLocal address (kube-proxy IPVS mode), the kube-dns Service
  ClusterIP `/32` in kube-proxy iptables mode, where NodeLocal DNSCache also listens on that IP and the traffic is
  not DNAT-ed (GKE's guide uses the ClusterIP for GKE without Dataplane V2); on GKE Dataplane V2 nothing is needed,
  and a Service IP may not be used in an `ipBlock`.
  The API server is not a pod (a host-network static pod on kubeadm and kind, a managed endpoint on EKS, GKE and
  AKS): in a standard NetworkPolicy, an `ipBlock` with its endpoint addresses is the portable way to allow it.
- **Helm merges a map from values into the default map.** A map set under an alias is coalesced with the
  subchart's default map key by key, so a default `podSelector: {k8s-app: kube-dns}` overridden with OpenShift's
  label would render both labels (an AND that matches no DNS pod). Deleting the default key with a `null` behaves
  differently by Helm version in an umbrella's own `values.yaml` (measured with `helm template`: Helm 3.22.0 deletes
  it, Helm 4.3.0 keeps it; a `null` in a `-f` file or in `--set` deletes it on both).
- **kubeconform checks structure, not the API rules.** With the schemas the `lint` job pins, a NetworkPolicy with
  `policyTypes: [Inbound]`, `protocol: ICMP` or an `endPort` on a named port is valid for kubeconform, while the
  API server rejects all three (`ValidateNetworkPolicySpec`, `ValidateNetworkPolicyPort`): such a mistake would
  surface only when Helm applies the release ([ADR-0036](0036-rollout-and-runtime-knobs-are-validated-pass-throughs.md)
  has the same problem and the same answer).
- Sibling charts: bjw-s app-template and stakater application pass rules through without validation; bitnami nginx
  enables its policy by default, allows any source on its ports and any egress unless told otherwise. None of them
  can reference a sibling component of an umbrella.

## Decision

- **A `networkPolicy` block, off by default, and it stays off.** On, it renders one
  `networking.k8s.io/v1` NetworkPolicy named `<fullname>` (`templates/networkpolicy.yaml`) on every workload type,
  with the chart's labels, whose `podSelector` is the chart's selector labels. On a `job` component it is a hook
  ([ADR-0041](0041-job-component-networkpolicy-is-a-hook.md)).
- **Ingress is isolated, egress only on request.** `policyTypes` is always rendered: `[Ingress]`, or
  `[Ingress, Egress]` with `networkPolicy.egress.enabled: true`. While `egress.enabled` is `false`, the egress
  destination lists must stay empty (a guard, below); the DNS settings are then ignored.
- **Ingress sources, one rule each, in this order:**
  - `ingress.fromComponents`: aliases of sibling components; one peer per alias, `podSelector.matchLabels`
    `{app.kubernetes.io/name: <alias>, app.kubernetes.io/instance: <release>}` (`chart-base.componentPeer`,
    `templates/_networkpolicy.tpl`), to every entry of `ports` **by name**, protocol TCP;
  - `ingress.fromNamespaces`: namespace names; one peer `namespaceSelector.matchExpressions`
    `kubernetes.io/metadata.name In [...]` (`chart-base.namespacePeer`), to every entry of `ports` by name;
  - `ingress.metricsFromNamespaces`: Prometheus' namespaces, the same peer, to `metrics.port` only;
  - `ingress.extra`: NetworkPolicyIngressRules, appended verbatim.
  Without a source there is no rule: the pods accept connections only from their node.
- **Egress, with `egress.enabled`, one rule each, in this order:**
  - DNS (`egress.dns`, on by default): one peer that combines the namespace (`kube-system`) and the pod labels
    (`dns.podSelector`, `null` by default, which renders `k8s-app: kube-dns`; a map set there replaces it, it is not
    merged with it), one `ipBlock` peer per entry of `dns.cidrs`, on `dns.ports` (53 UDP and TCP; every entry
    carries its protocol, required by the schema, because TCP is the API's default and would silently block UDP
    DNS). OpenShift sets the namespace (`openshift-dns`), the labels and
    `ports: [{port: 5353, protocol: UDP}, {port: 5353, protocol: TCP}]`; NodeLocal DNSCache adds the address the pods
    query to `dns.cidrs` (above); a resolver that a namespace and labels cannot select takes `dns.enabled: false`
    and an `egress.extra` rule;
  - `egress.toComponents`: aliases of sibling components, to any port of their pods (the sibling's own policy
    restricts its ports, and the chart cannot read them);
  - `egress.toCIDRs`: one rule per entry, `ipBlock` with `except`, ports by number with an optional `endPort` and
    TCP by default, every port without `ports`;
  - `egress.extra`: NetworkPolicyEgressRules, appended verbatim.
- **No empty list is ever rendered.** A rule is rendered only when its input is not empty, and the sibling and
  namespace rules only when `ports` is not empty. `dns.ports` and `dns.podSelector` must not be empty, and in the
  pass-through rules and in `toCIDRs` a `from`, `to`, `ports`, `except`, `matchLabels` or `matchExpressions` that is
  present must not be empty: an omitted list means "all", and `{}` is how a selector says every pod or namespace.
- **Every string from values and every peer is quoted** (aliases, the release name, namespace names, port names,
  CIDRs), so that an alias or a namespace named `on` stays a string; the policy's own `spec.podSelector` uses the
  shared `chart-base.selectorLabels`.
- **A strict schema** (`additionalProperties: false`): aliases with the chart's alias rule and at most 63
  characters, namespace names as DNS-1123 labels, CIDRs by shape (IPv4 and IPv6), ports as a number from 1 to
  65535 or a port name (numbers only in `toCIDRs` and `dns.ports`) and always present (a port entry without a
  `port` would open every port of its protocol: a whole protocol is `port: 1` with `endPort: 65535`), `endPort`
  only with a number, protocols
  `TCP`, `UDP` or `SCTP`, peers with at least one field and an `ipBlock` alone, label selector operators `In`,
  `NotIn` (with values), `Exists` and `DoesNotExist` (without). `networkPolicy`, its `enabled`, `ingress` and
  `egress`, `egress.enabled`, and `enabled`, `namespace` and `ports` of `egress.dns` are `required`
  ([ADR-0027](0027-required-keys-in-the-schema.md)); `dns.podSelector` is `null` or a non-empty map.
- **Guards** in `templates/validate.yaml`, while `networkPolicy.enabled`:
  - `metrics.enabled` without `metricsFromNamespaces` fails (the policy would block the scrapes). It accepts no
    `extra` alternative: a scraper that is not a pod in a namespace (an agent on the host network, a Prometheus
    outside the cluster) still needs a namespace listed, and its addresses allowed with an `ipBlock` in `extra`;
  - `metricsFromNamespaces` without `metrics.enabled` fails, also on a CronJob or a Job, where metrics cannot be
    enabled: the list would open nothing;
  - `httpRoute.enabled` or `ingress.enabled` without `fromNamespaces`, without `ingress.extra` and without
    `ingress.routeTrafficAllowedElsewhere: true` fails: the route would reach a component that refuses its traffic.
    The key (a boolean, `false` by default, the owner's decision of 2026-10-03) is the third remedy, for traffic that
    a policy this chart cannot express allows (Cilium's Ingress or Gateway, a `hostNetwork` controller): it opens
    nothing, and it fails without a route, because it would have no effect;
  - `fromComponents` or `fromNamespaces` with `ports: []` fails: there is no port to open by name;
  - `egress.toComponents`, `egress.toCIDRs`, `egress.extra` or `egress.dns.cidrs` set while `egress.enabled` is
    `false` fails: a destination list that looks like a restriction would restrict nothing. Changed DNS scalars
    (namespace, selector, ports) cannot be told from the defaults and are ignored. The guard does not run while
    `networkPolicy.enabled` is `false`, the switch that overlays flip;
  - an `endPort` lower than its `port` fails (in `ingress.extra`, and with `egress.enabled` in `egress.toCIDRs` and
    `egress.extra`), as the API server would.
- **Not validated** (documented in the values, the README and the consuming guide): whether the CNI enforces
  NetworkPolicy; whether a referenced sibling or namespace exists; label keys and values beyond their type; that an
  `except` is inside its `cidr`; whether the route's traffic really is allowed where `routeTrafficAllowedElsewhere`
  says it is (Cilium Ingress or Gateway, `hostNetwork`); the DNS of a distribution that differs from the defaults; the API server for components with
  `serviceAccount.automountToken: true` once egress is isolated (its endpoint IPs belong in `toCIDRs`).

## Consequences

- An umbrella can say, per component and by alias, which siblings, namespaces and Prometheus may reach it and,
  with egress isolated, what it may reach. Most values that the API server would reject, or that would open nothing
  or everything, fail at render time with the component's name (see "Not validated": an `except` outside its `cidr`
  is not checked, and `extra: [{}]` deliberately allows everything). A route that Cilium's Ingress or Gateway serves
  needs a CiliumNetworkPolicy outside the chart and `routeTrafficAllowedElsewhere: true`: the chart cannot check
  either.
- With egress off, enabling the policy never breaks an outgoing connection. With egress on, every destination must
  be listed: databases outside the cluster, the API server, a NodeLocal DNSCache. An overlay that turns
  `egress.enabled` off must also clear the destination lists (`[]`).
- Trade-off: on a CNI that does not enforce NetworkPolicy the object is created and nothing changes, and no test of
  the chart can tell. A typo in an alias that is still a valid alias selects no pod, silently.
- Trade-off: `fromNamespaces` opens every declared port to every pod of those namespaces, and `toComponents` every
  port of the sibling's pods. Narrower rules go in `extra`.
- Trade-off: a namespace default-deny, which isolates every pod of the namespace, is the platform's, not the
  chart's. Under an egress default-deny, a component with `egress.enabled: false` has no egress at all: its
  ingress-only policy allows nothing outward.
- kubeconform validates the rendered object's structure in the `lint` job. The e2e proves that the API server
  accepts the `full` scenario's policy and, on kind, under a namespace default-deny: that NetworkPolicy is enforced
  (a deny check first: kindnet fails open), that the chart's rules allow a sibling, a monitoring namespace and DNS by
  Service name, and that they open nothing more on the probed paths; then, with the default-deny deleted, that an ingress-only policy
  leaves a pod's egress open and that the chart's own policy isolates a pod's ingress and egress
  ([testing guide](../guides/testing.md#end-to-end-on-kind)).

## Alternatives considered

### Egress isolated by default

The strongest posture, and bitnami's with `allowExternalEgress: false`. But every destination would have to be
listed before the first deploy, and some (the API server, a CIDR outside the cluster) differ per cluster: enabling
an opt-in feature would break outgoing traffic. Isolating egress whenever an egress key is set was rejected too:
listing DNS alone would silently deny everything else.

### A default monitoring namespace

`monitoring` with `app.kubernetes.io/name: prometheus` would be convenient, but kube-prometheus-stack has no fixed
namespace and OpenShift uses `openshift-monitoring`: a wrong default silently stops the scrapes. Listing Prometheus'
namespace in `fromNamespaces` instead would open every port to it, not only the metrics port.

### Ports per source, or per destination sibling

`fromComponents: [{name: web, ports: [http]}]` is more precise but heavier for the common case; the component's
own `ports` are the ports it serves. For `toComponents`, the sibling's ports are in the sibling's values, which a
subchart cannot read, so they would be repeated and drift. Both precise cases fit in `extra`.

### A default DNS selector map

A default `podSelector: {k8s-app: kube-dns}` in `values.yaml` cannot be replaced from an umbrella: Helm merges the map
set there into it, so OpenShift's label would be ANDed with `k8s-app: kube-dns`, and deleting the default key with a
`null` works on Helm 3.22 but not on Helm 4.3 in an umbrella's own values. A `null` default that the template fills
in is replaced by any map, on both.

### Ignoring the egress lists while egress is off

The chart's precedent for a disabled block, and it would let an overlay keep its lists. But a list of destinations
that restricts nothing is a fail-open on a security control: a user who forgot the switch believes egress is
restricted. The guard fails instead; it costs an overlay a `[]` per list.

### DNS to port 53 on any destination

What bitnami does. It needs no configuration for NodeLocal DNSCache or a cloud resolver, but it lets the pod talk
DNS to any resolver (an exfiltration path), and it still misses OpenShift's port 5353.

### Several NetworkPolicies per component

A policy per concern (`-dns`, `-metrics`) reads better in `kubectl get`, but policies only add up, so one object
holds the same rules with one name per component, like every other object of the chart.

### Rules passed through without a schema

What bjw-s app-template and stakater application do. Every field is available, but a typo or a rule the API
rejects fails only at install, an empty list silently opens everything, and siblings cannot be referenced by alias.
The validated `extra` keeps the full expressiveness.

### On by default

It would make every exposure path (Gateway, ingress controller, Prometheus) mandatory configuration, a breaking
release, and on a CNI that does not enforce NetworkPolicy it would add objects that change nothing.

## References

- [Kubernetes: Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
  (Prerequisites, The two sorts of pod isolation, Behavior of `to` and `from` selectors, Targeting a Namespace by
  its name, Pod lifecycle)
- Kubernetes v1.37.0, [`staging/src/k8s.io/api/networking/v1/types.go`](https://github.com/kubernetes/kubernetes/blob/v1.37.0/staging/src/k8s.io/api/networking/v1/types.go);
  v1.33.12, [`pkg/apis/networking/validation/validation.go`](https://github.com/kubernetes/kubernetes/blob/v1.33.12/pkg/apis/networking/validation/validation.go)
  and [`staging/src/k8s.io/apimachinery/pkg/apis/meta/v1/validation/validation.go`](https://github.com/kubernetes/kubernetes/blob/v1.33.12/staging/src/k8s.io/apimachinery/pkg/apis/meta/v1/validation/validation.go)
  (label selectors)
- [Helm: Subcharts and Global Values](https://helm.sh/docs/chart_template_guide/subcharts_and_globals/)
- [GKE: network policy, limitations](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/network-policy);
  [GKE: NodeLocal DNSCache, network policy](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/nodelocal-dns-cache);
  [Kubernetes: NodeLocal DNSCache](https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/)
- [Amazon EKS: Restrict Pod network traffic with Kubernetes network policies](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html)
- [Envoy Gateway: Deployment Modes](https://gateway.envoyproxy.io/docs/tasks/operations/deployment-mode/) (where the
  proxies run)
- [Cilium: Ingress and Network Policy](https://docs.cilium.io/en/stable/network/servicemesh/ingress-and-network-policy/),
  [cilium/cilium#36509](https://github.com/cilium/cilium/issues/36509)
- openshift/cluster-dns-operator, `pkg/manifests/assets/dns/daemonset.yaml` and `service.yaml` (the DNS pods' label
  and port 5353)
- [kube-network-policies `f67f0fb35e2b`](https://github.com/kubernetes-sigs/kube-network-policies/tree/f67f0fb35e2b),
  the policy engine of kindnet in kind v0.32.0 and v0.33.0
- `values.yaml` (`networkPolicy`), `values.schema.json` (`networkPolicy` and its definitions),
  `templates/networkpolicy.yaml`, `templates/_networkpolicy.tpl`, `templates/validate.yaml`,
  `tests/networkpolicy_test.yaml`, `ci/full-values.yaml`, `.github/scripts/e2e.sh`, `.github/scripts/alias-contract.sh`
