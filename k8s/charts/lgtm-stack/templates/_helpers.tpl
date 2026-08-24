{{/*
Labels applied to every object in the chart.

app.kubernetes.io/name is the COMPONENT (loki, tempo, ...), not the chart. A Service
selects pods by label, so a shared name would make one Service match every pod.
*/}}
{{- define "lgtm.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: lgtm-stack
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Selector labels for one component. Call: (include "lgtm.selectorLabels" (dict "ctx" $ "component" "loki"))

These must NEVER change for a running release. A StatefulSet's selector is immutable, so
an edit here makes `helm upgrade` fail with a field-is-immutable error and the only fix is
a delete and reinstall.
*/}}
{{- define "lgtm.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- end -}}

{{/*
Render a backend config file, with an optional deep-merged override.

Call: (include "lgtm.renderConfig" (dict "ctx" $ "file" "files/mimir-config.yaml" "override" .Values.mimir.configOverride))

TWO PATHS, AND THE DIFFERENCE IS DELIBERATE.

  no override -> the file is emitted BYTE FOR BYTE, comments included. Nothing can be lost
                 in translation, because nothing is translated.
  an override -> the file is parsed to a map, the override is deep-merged over it, and the
                 result is re-emitted. THE COMMENTS ARE LOST IN THE CONFIGMAP. They are not
                 lost in config/, which stays the source of truth.

The parse path also normalises YAML. That is safe for the files here, and it is NOT safe in
general: an unquoted date such as `from: 2024-01-01` in config/loki-config.yaml would be
re-emitted as a full timestamp and Loki would reject it. That single hazard is why Loki has
no override and takes the verbatim path.
*/}}
{{- define "lgtm.renderConfig" -}}
{{- $raw := .ctx.Files.Get .file -}}
{{- if not $raw -}}
{{- fail (printf "config file %s is missing from the chart. Run `make -C k8s sync-config`." .file) -}}
{{- end -}}
{{- if .override -}}
{{ mergeOverwrite ($raw | fromYaml) (deepCopy .override) | toYaml }}
{{- else -}}
{{ $raw }}
{{- end -}}
{{- end -}}

{{/*
The ServiceAccount every pod in the chart runs as.
*/}}
{{- define "lgtm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- printf "%s-lgtm" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
default
{{- end -}}
{{- end -}}

{{/*
The volume that carries Grafana's credentials as FILES.

ONE MOUNT PATH, TWO SOURCES. Locally the files come from a Kubernetes Secret. On EKS they
come from the Secrets Store CSI driver, which reads AWS Secrets Manager using the pod's own
AWS identity and creates no Kubernetes Secret at all - so nothing reaches etcd and
`kubectl get secret` returns nothing to steal.

BECAUSE THE PATH IS THE SAME IN BOTH, the container configuration is identical and the local
cluster exercises the real mechanism. A local stand-in that used a plain environment
variable would leave the file path untested until the first EKS install.
*/}}
{{- define "lgtm.credentialsVolume" -}}
- name: credentials
{{- if .Values.secretsStore.enabled }}
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: grafana-credentials
{{- else }}
  secret:
    secretName: {{ .Values.grafana.credentialsSecret }}
{{- end }}
{{- end -}}

{{/*
The environment that gives Tempo and Mimir their S3 identity.

Empty on EKS: the IRSA web-identity token is projected into the pod by the ServiceAccount,
and the same credential chain finds it there instead.
*/}}
{{- define "lgtm.s3Env" -}}
{{- if .Values.s3Credentials.enabled }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ .Values.s3Credentials.secretName }}
      key: accessKeyId
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.s3Credentials.secretName }}
      key: secretAccessKey
{{- end }}
{{- end -}}
