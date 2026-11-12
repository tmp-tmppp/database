{{/* Name of the server's objects: the StatefulSet, the client Service and the NetworkPolicy (the schema pins "postgres"). */}}
{{- define "database.name" -}}
{{- .Values.serviceName -}}
{{- end -}}

{{/* The image, always by digest. */}}
{{- define "database.image" -}}
{{- printf "%s:%s@%s" .Values.image.repository .Values.image.tag .Values.image.digest -}}
{{- end -}}

{{/* Labels on every object and Pod of this chart. app.kubernetes.io/name is "postgres" because the egress rules of
markets, trading and market-data select the database Pods by app.kubernetes.io/name: postgres. */}}
{{- define "database.labels" -}}
app.kubernetes.io/name: {{ include "database.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: chance
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Labels that select the server Pod (never the setup Job or the test Pod). */}}
{{- define "database.serverSelectorLabels" -}}
app.kubernetes.io/name: {{ include "database.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: server
{{- end -}}

{{/* Security settings of every Pod: the alpine image's postgres user (uid and gid 70), no service account token, no
Service environment variables (a Service called postgres would otherwise put POSTGRES_PORT and friends into the
environment of the image's entrypoint). */}}
{{- define "database.podSecurity" -}}
automountServiceAccountToken: false
enableServiceLinks: false
securityContext:
  runAsNonRoot: true
  runAsUser: 70
  runAsGroup: 70
  fsGroup: 70
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{- define "database.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
{{- end -}}

{{/* The list of roles the Job creates and the test checks, one per line: kind database role password_key limit.
Fails the render on a repeated database, role or key, on a role named like the superuser, and when the connection
limits do not fit into max_connections (5 left for the superuser and maintenance). */}}
{{- define "database.rolesConf" -}}
{{- $dbs := dict -}}
{{- $roles := dict -}}
{{- $keys := dict $.Values.superuser.passwordKey "superuser" -}}
{{- $total := 0 -}}
{{- $lines := list "# kind database role password_key connection_limit" -}}
{{- range $.Values.databases -}}
{{- if hasKey $dbs .name -}}{{- fail (printf "databases: the database %s is listed twice" .name) -}}{{- end -}}
{{- $_ := set $dbs .name true -}}
{{- $db := .name -}}
{{- $all := prepend .extraRoles (dict "name" .role "passwordKey" .passwordKey "connectionLimit" .connectionLimit "kind" "owner") -}}
{{- range $all -}}
{{- if or (hasKey $roles .name) (eq .name $.Values.superuser.name) -}}{{- fail (printf "databases: the role %s is used twice (or is the superuser)" .name) -}}{{- end -}}
{{- if hasKey $keys .passwordKey -}}{{- fail (printf "databases: the Secret key %s is used twice" .passwordKey) -}}{{- end -}}
{{- $_ := set $roles .name true -}}
{{- $_ := set $keys .passwordKey true -}}
{{- $total = add $total .connectionLimit -}}
{{- $lines = append $lines (printf "%s %s %s %s %d" (.kind | default "extra") $db .name .passwordKey (int .connectionLimit)) -}}
{{- end -}}
{{- end -}}
{{- if gt (add $total 5) (atoi (index $.Values.config "max_connections")) -}}
{{- fail (printf "databases: the connection limits add up to %d; with 5 kept for the superuser that exceeds config.max_connections (%s)" $total (index $.Values.config "max_connections")) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}
