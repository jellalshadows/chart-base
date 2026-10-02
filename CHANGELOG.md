# Changelog

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
