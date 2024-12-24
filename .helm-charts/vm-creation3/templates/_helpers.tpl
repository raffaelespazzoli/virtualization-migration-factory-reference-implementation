{{/*
Helper to select the correct template based on the OS variable
*/}}
{{- define "vm-template.selector" -}}
{{- if eq .Values.os "rhel8" -}}
{{- include "vm-creation3/templates/rhel8-template.yaml" . -}}
{{- else if eq .Values.os "rhel9" -}}
{{- include "vm-creation3/templates/rhel9-template.yaml" . -}}
{{- else -}}
{{- fail "Unsupported OS specified in values.yaml" -}}
{{- end -}}
{{- end -}}
