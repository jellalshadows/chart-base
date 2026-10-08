# Changelog

## [0.7.0](https://github.com/jellalshadows/chart-base/compare/v0.6.0...v0.7.0) (2026-10-08)


### ⚠ BREAKING CHANGES

* A map-form file of configFiles.files now drops every key whose value is null or empty (key:), at any depth of nested maps (a list, and everything inside it, is rendered as written), from every values layer; 0.6.0 rendered key: null, so such a ConfigMap changes once with no render error (a Deployment rolls; CronJob and Job pods read the new file at their next run): write key: {} for a section that keeps its defaults, key: "" for an empty value, or the string form of the file for a literal null. A null entry of resources.limits, or of resources.requests other than the required cpu and memory, now renders no such limit or request (0.6.0 rendered the null, which the API server stores as zero: a zero limit, or an install rejected with limit of 0 when a request for the same resource is set), and resources.limits: null, a schema error in 0.6.0, now renders no limits. configFiles.mountPath is rendered as written: a path with trailing whitespace or a # comment was cut by 0.6.0 and now names another directory; remove them. These values now fail the render: a configFiles.mountPath that normalizes to /tmp or / (for example //tmp or /tmp/.), or to /var/run/secrets/kubernetes.io/serviceaccount while serviceAccount.automountToken is true (choose another directory, or for the token directory set serviceAccount.automountToken: false); externalSecret.enabled: true with externalSecret.data null, empty or absent (list a key in externalSecret.data, or set externalSecret.enabled: false); a null for cronjob.schedule on a cronjob, or for externalSecret.secretStoreRef.kind or .name, httpRoute.parentRefs or ingress.hosts while their block is enabled (write the value; for secretStoreRef.kind, ClusterSecretStore or SecretStore); a main-container probe whose httpGet.port or tcpSocket.port is a name that no ports entry declares, or whose httpGet or tcpSocket is not a map (use the port number, declare the name in ports, or remove the probe; a liveness probe fixed this way runs for the first time); an unknown or misspelt key, or a null value, in an entry of httpRoute.parentRefs or httpRoute.matches, at any level (fix the spelling or remove the null: the entries take exactly the fields of the Gateway API v1.6.2 Standard CRD, and the error names the path). See docs/upgrading.md.

### Features

* extra volumes ([#20](https://github.com/jellalshadows/chart-base/issues/20)) ([94bbc7a](https://github.com/jellalshadows/chart-base/commit/94bbc7a53a3c79acfa7e1d7b0d51412b3c68f727))


### Bug Fixes

* map-form config files drop null and empty (key:) keys; values that render broken objects now fail ([#18](https://github.com/jellalshadows/chart-base/issues/18)) ([333e4a2](https://github.com/jellalshadows/chart-base/commit/333e4a278e0a0157df32671b5c748d22765ca5a6))

## [0.6.0](https://github.com/jellalshadows/chart-base/compare/v0.5.0...v0.6.0) (2026-10-06)


### ⚠ BREAKING CHANGES

* serviceAccount.annotations together with serviceAccount.create: false now fail the render (0.5.0 ignored them silently: with create: false the chart creates no ServiceAccount to carry them, and the pods run as the namespace's default ServiceAccount). Remove them from that component's values; an override file clears inherited annotations with serviceAccount.annotations: null (an empty map {} is merged and still fails). The same values then render what 0.5.0 rendered; if the pods need the annotations (a cloud identity), set serviceAccount.create: true instead, so that the chart creates the component's own ServiceAccount with them (the pods roll once). See docs/upgrading.md.

### Features

* existing ServiceAccount and namespaced RBAC ([#16](https://github.com/jellalshadows/chart-base/issues/16)) ([bbf2517](https://github.com/jellalshadows/chart-base/commit/bbf2517ad1ade7c3de753e0b8b0e23b573892cd0))

## [0.5.0](https://github.com/jellalshadows/chart-base/compare/v0.4.1...v0.5.0) (2026-10-02)


### Features

* opt-in NetworkPolicy with sibling-component references ([#14](https://github.com/jellalshadows/chart-base/issues/14)) ([cdf97e1](https://github.com/jellalshadows/chart-base/commit/cdf97e188cd15b9fd85e8b0da97f91bf2681d240))

## [0.4.1](https://github.com/jellalshadows/chart-base/compare/v0.4.0...v0.4.1) (2026-10-01)


### Bug Fixes

* quote strings rendered from values ([#12](https://github.com/jellalshadows/chart-base/issues/12)) ([28ac2ff](https://github.com/jellalshadows/chart-base/commit/28ac2fff47f671a4d46b2291b0e95a64f2265870))

## [0.4.0](https://github.com/jellalshadows/chart-base/compare/v0.3.0...v0.4.0) (2026-09-30)


### Features

* Prometheus monitoring (ServiceMonitor, PodMonitor, PrometheusRule) ([#10](https://github.com/jellalshadows/chart-base/issues/10)) ([72ddbc9](https://github.com/jellalshadows/chart-base/commit/72ddbc90929dd56da32ac4d72351467e09083422))

## [0.3.0](https://github.com/jellalshadows/chart-base/compare/v0.2.0...v0.3.0) (2026-09-30)


### ⚠ BREAKING CHANGES

* enableServiceLinks now defaults to false (Deployments roll once on upgrade; CronJob and Job pods pick it up at their next run); set enableServiceLinks: true to restore Kubernetes' default. cronjob.suspend is now always rendered (false): a CronJob suspended by hand is resumed by the upgrade (or, with Helm 4 server-side apply, the upgrade can fail with a field-manager conflict) unless <alias>.cronjob.suspend: true is set first. See docs/upgrading.md.

### Features

* rollout and pod runtime knobs ([#8](https://github.com/jellalshadows/chart-base/issues/8)) ([0cb0da7](https://github.com/jellalshadows/chart-base/commit/0cb0da75f15ba2613f260fd8e4f293d8b84c19cb))

## [0.2.0](https://github.com/jellalshadows/chart-base/compare/v0.1.0...v0.2.0) (2026-09-29)


### ⚠ BREAKING CHANGES

* externalSecret.reloadOnChange moved to the component-level reloadOnChange; see docs/upgrading.md.

### Features

* env references, envFrom and component-level reloadOnChange ([#4](https://github.com/jellalshadows/chart-base/issues/4)) ([894a64e](https://github.com/jellalshadows/chart-base/commit/894a64e7f1848c03bdb425c6f52a16792203a698))

## 0.1.0 (2026-09-28)


### Features

* add chart-base generic workload chart ([#1](https://github.com/jellalshadows/chart-base/issues/1)) ([fa5fc1e](https://github.com/jellalshadows/chart-base/commit/fa5fc1e9810c629bd0d78bc2edd3afe47a2cd65a))
