{{/*
Extra objects (the values key extraObjects): the accessor and the table of the kinds an extra object cannot be. Internal,
not a public API.
*/}}

{{/*
chart-base.extraObjects: fills the dict `out` with the extra objects, keyed by the object's key: the non-null entries of
extraObjects (nil counts as empty), each without its null fields at any depth through maps. It is chart-base.pruneNulls
on a deep copy: a null entry and a null field are absent, a list is kept as written (a null item too), a map emptied by
the pruning stays {}, and false, 0 and "" are values. The one reader of extraObjects: templates/extraobjects.yaml
renders what it returns and templates/validate.yaml checks it; never read .Values.extraObjects elsewhere.
Usage: {{- $objects := dict }}{{- include "chart-base.extraObjects" (dict "ctx" $ "out" $objects) }}, then range over
$objects (in key order).
*/}}
{{- define "chart-base.extraObjects" -}}
{{- $all := deepCopy (.ctx.Values.extraObjects | default dict) -}}
{{- include "chart-base.pruneNulls" $all -}}
{{- range $key, $entry := $all }}{{ $_ := set $.out $key $entry }}{{ end -}}
{{- end -}}

{{/*
chart-base.rejectedKinds: the built-in kinds an extra object cannot be, as YAML: <group>/<Kind> (a core kind without a
group and a slash) to the reason that templates/validate.yaml's message gives, compared lowercase with the extra
object's API group (the part of apiVersion before the /) and kind, any version:
- workload: the built-in workloads (one workload per alias);
- service: a Service (one Service per alias, and no alias-safe name: <fullname>.<key> is no DNS-1035 label);
- endpoints: Endpoints and EndpointSlice (a Service's backends wired by hand);
- secret: a Secret (its data would sit in the values, ADR-0004);
- cluster: every type marked +genclient:nonNamespaced in k8s.io/api v0.35.3 and v0.37.0, plus CustomResourceDefinition
  and APIService: an extra object is installed in the release namespace.
The cluster rows are regenerated at each bump of the Kubernetes floor (docs/guides/development.md); each row is pinned
by a test of tests/extraobjects_guards_test.yaml.
Usage: include "chart-base.rejectedKinds" . | fromYaml
*/}}
{{- define "chart-base.rejectedKinds" -}}
Pod: workload
ReplicationController: workload
apps/Deployment: workload
apps/ReplicaSet: workload
apps/StatefulSet: workload
apps/DaemonSet: workload
batch/Job: workload
batch/CronJob: workload
Service: service
Endpoints: endpoints
discovery.k8s.io/EndpointSlice: endpoints
Secret: secret
ComponentStatus: cluster
Namespace: cluster
Node: cluster
PersistentVolume: cluster
admissionregistration.k8s.io/MutatingAdmissionPolicy: cluster
admissionregistration.k8s.io/MutatingAdmissionPolicyBinding: cluster
admissionregistration.k8s.io/MutatingWebhookConfiguration: cluster
admissionregistration.k8s.io/ValidatingAdmissionPolicy: cluster
admissionregistration.k8s.io/ValidatingAdmissionPolicyBinding: cluster
admissionregistration.k8s.io/ValidatingWebhookConfiguration: cluster
apiextensions.k8s.io/CustomResourceDefinition: cluster
apiregistration.k8s.io/APIService: cluster
authentication.k8s.io/SelfSubjectReview: cluster
authentication.k8s.io/TokenReview: cluster
authorization.k8s.io/SelfSubjectAccessReview: cluster
authorization.k8s.io/SelfSubjectRulesReview: cluster
authorization.k8s.io/SubjectAccessReview: cluster
certificates.k8s.io/CertificateSigningRequest: cluster
certificates.k8s.io/ClusterTrustBundle: cluster
flowcontrol.apiserver.k8s.io/FlowSchema: cluster
flowcontrol.apiserver.k8s.io/PriorityLevelConfiguration: cluster
imagepolicy.k8s.io/ImageReview: cluster
internal.apiserver.k8s.io/StorageVersion: cluster
networking.k8s.io/IPAddress: cluster
networking.k8s.io/IngressClass: cluster
networking.k8s.io/ServiceCIDR: cluster
node.k8s.io/RuntimeClass: cluster
rbac.authorization.k8s.io/ClusterRole: cluster
rbac.authorization.k8s.io/ClusterRoleBinding: cluster
resource.k8s.io/DeviceClass: cluster
resource.k8s.io/DeviceTaintRule: cluster
resource.k8s.io/ResourcePoolStatusRequest: cluster
resource.k8s.io/ResourceSlice: cluster
scheduling.k8s.io/PriorityClass: cluster
storage.k8s.io/CSIDriver: cluster
storage.k8s.io/CSINode: cluster
storage.k8s.io/StorageClass: cluster
storage.k8s.io/VolumeAttachment: cluster
storage.k8s.io/VolumeAttributesClass: cluster
storagemigration.k8s.io/StorageVersionMigration: cluster
{{- end -}}
