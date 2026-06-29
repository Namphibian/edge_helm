{{- define "app.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "app.labels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}


{{- /*
kebabCase: convert CamelCase or camelCase to kebab-case and lowercase
Usage: {{ include "app.kebab" "dataVolume" }}
*/ -}}
{{- define "app.kebab" -}}
{{ $s := . }}
{{- /* Insert dash before each capital letter */ -}}
{{ $withDashes := regexReplaceAll "([A-Z])" $s "-${1}" }}
{{- /* Remove any leading or trailing dashes */ -}}
{{ $trimmed := regexReplaceAll "^[-]+" $withDashes "" }}
{{ $trimmed = regexReplaceAll "[-]+$" $trimmed "" }}
{{ lower $trimmed }}
{{- end -}}

{{- /*
fileResourceName: build a unique resource/volume name for app.files entries.
Usage: {{ include "app.fileResourceName" (list $root $file $index) }}
*/ -}}
{{- define "app.fileResourceName" -}}
{{- $root := index . 0 -}}
{{- $file := index . 1 -}}
{{- $index := index . 2 -}}
{{- $type := lower (default "configmap" $file.type) -}}
{{- printf "%s-%s-%s-%d" (trim (include "app.fullname" $root)) (trim (include "app.kebab" $file.name)) $type $index | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- /*
helpers: app.assembleUrl
Parameters: a map with keys: scheme (optional, default "http"), host, port (optional), path (optional)
Returns: assembled URL string e.g. "https://172.16.125.46:8185/buyboost"
*/ -}}
{{- define "app.assembleUrl" -}}
  {{- $v := . -}}
  {{- $scheme := "http" -}}{{- if hasKey $v "scheme" -}}{{- $scheme = index $v "scheme" -}}{{- end -}}
  {{- $host := index $v "host" -}}
  {{- $path := "" -}}{{- if hasKey $v "path" -}}{{- $path = index $v "path" -}}{{- end -}}
  {{- if hasKey $v "port" -}}
    {{- printf "%s://%s:%v%s" $scheme $host (index $v "port") $path -}}
  {{- else -}}
    {{- printf "%s://%s%s" $scheme $host $path -}}
  {{- end -}}
{{- end -}}

{{- /*
helpers: app.configValue
Parameters: list containing [ $cfg, $configData, $contextName ]
  - $cfg: the value to resolve (either a literal value or a map with configDataKey)
  - $configData: $.Values.app.configData
  - $contextName: string used in error messages
Returns: the resolved value from configData, or the literal value as-is.

configDataKey supports dot-notation to access sub-fields of a type:url entry:
  configDataKey: buyboostOpenapiHost        → assembled URL string
  configDataKey: buyboostOpenapiHost.host   → "172.16.125.46"
  configDataKey: buyboostOpenapiHost.port   → 8185
  configDataKey: buyboostOpenapiHost.scheme → "https"
  configDataKey: buyboostOpenapiHost.path   → "/buyboost"
*/ -}}
{{- define "app.configValue" -}}
  {{- $cfg := index . 0 -}}
  {{- $configData := index . 1 -}}
  {{- $contextName := index . 2 -}}
  {{- if kindIs "map" $cfg -}}
    {{- if hasKey $cfg "configDataKey" -}}
      {{- $rawKey := index $cfg "configDataKey" -}}
      {{- $parts := splitList "." $rawKey -}}
      {{- $cfgKey := first $parts -}}
      {{- $subField := "" -}}
      {{- if gt (len $parts) 1 -}}{{- $subField = join "." (rest $parts) -}}{{- end -}}
      {{- if not (hasKey $configData $cfgKey) -}}
        {{- fail (printf "%s: configDataKey %q not found in .Values.app.configData" $contextName $cfgKey) -}}
      {{- end -}}
      {{- $entry := index $configData $cfgKey -}}
      {{- if not (hasKey $entry "value") -}}
        {{- fail (printf "%s: configData entry %q has no 'value' field" $contextName $cfgKey) -}}
      {{- end -}}
      {{- $entryValue := index $entry "value" -}}
      {{- $entryType := "" -}}{{- if hasKey $entry "type" -}}{{- $entryType = index $entry "type" -}}{{- end -}}
      {{- if $subField -}}
        {{- if not (kindIs "map" $entryValue) -}}
          {{- fail (printf "%s: configDataKey %q value is not a map; cannot access sub-field %q" $contextName $cfgKey $subField) -}}
        {{- end -}}
        {{- if not (hasKey $entryValue $subField) -}}
          {{- fail (printf "%s: configData entry %q has no sub-field %q" $contextName $cfgKey $subField) -}}
        {{- end -}}
        {{- index $entryValue $subField -}}
      {{- else if eq $entryType "url" -}}
        {{- include "app.assembleUrl" $entryValue -}}
      {{- else -}}
        {{- $entryValue -}}
      {{- end -}}
    {{- else -}}
      {{- $cfg -}}
    {{- end -}}
  {{- else -}}
    {{- $cfg -}}
  {{- end -}}
{{- end -}}

{{- /*
helpers: app.configValueStr
Same as app.configValue but always returns a string representation.
For lists, returns JSON. For maps, returns JSON. For scalars, returns printf %v.
*/ -}}
{{- define "app.configValueStr" -}}
  {{- $raw := include "app.configValue" . -}}
  {{- $raw -}}
{{- end -}}

{{- /*
helpers: app.resolvePort
Parameters: list containing [ $portCfg, $configData, $contextName ]
  - $portCfg: the value of ports.<name>.port (either a number/string or a map with configDataKey)
  - $configData: $.Values.app.configData
  - $contextName: string used in error messages (e.g., "service api source")
Returns: numeric port value (rendered as text) or fails with a clear message.
*/ -}}
{{- /*
helpers: app.annotations
Parameters: list containing [ $annotationNames, $root ]
  - $annotationNames: list of annotation set names (from annotationSets)
  - $root: the root context ($)
Renders the merged annotations block (without the "annotations:" key).
*/ -}}
{{- define "app.annotations" -}}
{{- $annotationNames := index . 0 -}}
{{- $root := index . 1 -}}
{{- range $asetName := $annotationNames -}}
{{- $aset := index $root.Values.app.annotationSets $asetName -}}
{{- range $ak, $av := $aset }}
{{ $ak }}: {{ include "app.configValue" (list $av $root.Values.app.configData (printf "annotation %s.%s" $asetName $ak)) | quote }}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
helpers: app.envValue
Parameters: list containing [ $cfg, $configData, $contextName ]
Resolves a value for use as a container env var string:
  - configDataKey reference → looks up configData entry value
  - type:url entry          → assembled URL string (or sub-field via dot-notation)
  - list of scalars         → comma-joined string  (e.g. storageForbiddenFileTypes)
  - list of maps            → JSON string           (e.g. openapiUsers)
  - plain map (no key)      → JSON string
  - scalar                  → plain string
*/ -}}
{{- define "app.envValue" -}}
  {{- $cfg := index . 0 -}}
  {{- $configData := index . 1 -}}
  {{- $contextName := index . 2 -}}
  {{- if kindIs "map" $cfg -}}
    {{- if hasKey $cfg "configDataKey" -}}
      {{- $rawKey := index $cfg "configDataKey" -}}
      {{- $parts := splitList "." $rawKey -}}
      {{- $cfgKey := first $parts -}}
      {{- $subField := "" -}}
      {{- if gt (len $parts) 1 -}}{{- $subField = join "." (rest $parts) -}}{{- end -}}
      {{- if not (hasKey $configData $cfgKey) -}}
        {{- fail (printf "%s: configDataKey %q not found in .Values.app.configData" $contextName $cfgKey) -}}
      {{- end -}}
      {{- $entry := index $configData $cfgKey -}}
      {{- if not (hasKey $entry "value") -}}
        {{- fail (printf "%s: configData entry %q has no 'value' field" $contextName $cfgKey) -}}
      {{- end -}}
      {{- $v := index $entry "value" -}}
      {{- $joinChar := "," -}}
      {{- if hasKey $entry "joinChar" -}}
        {{- $joinChar = index $entry "joinChar" -}}
      {{- end -}}
      {{- $entryType := "" -}}{{- if hasKey $entry "type" -}}{{- $entryType = index $entry "type" -}}{{- end -}}
      {{- if $subField -}}
        {{- if not (kindIs "map" $v) -}}
          {{- fail (printf "%s: configDataKey %q value is not a map; cannot access sub-field %q" $contextName $cfgKey $subField) -}}
        {{- end -}}
        {{- if not (hasKey $v $subField) -}}
          {{- fail (printf "%s: configData entry %q has no sub-field %q" $contextName $cfgKey $subField) -}}
        {{- end -}}
        {{- index $v $subField -}}
      {{- else if eq $entryType "url" -}}
        {{- include "app.assembleUrl" $v -}}
      {{- else if kindIs "slice" $v -}}
        {{- if and (gt (len $v) 0) (kindIs "map" (index $v 0)) -}}
          {{- toJson $v -}}
        {{- else -}}
          {{- join $joinChar $v -}}
        {{- end -}}
      {{- else -}}
        {{- $v -}}
      {{- end -}}
    {{- else -}}
      {{- toJson $cfg -}}
    {{- end -}}
  {{- else if kindIs "slice" $cfg -}}
    {{- if and (gt (len $cfg) 0) (kindIs "map" (index $cfg 0)) -}}
      {{- toJson $cfg -}}
    {{- else -}}
      {{- join "," $cfg -}}
    {{- end -}}
  {{- else -}}
    {{- $cfg -}}
  {{- end -}}
{{- end -}}

{{- define "app.resolvePort" -}}
  {{- $portCfg := index . 0 -}}
  {{- $configData := index . 1 -}}
  {{- $contextName := index . 2 -}}
  {{- if kindIs "map" $portCfg -}}
    {{- $cfgKey := index $portCfg "configDataKey" -}}
    {{- if not (hasKey $configData $cfgKey) -}}
      {{- fail (printf "%s: configDataKey %q not found in .Values.app.configData" $contextName $cfgKey) -}}
    {{- end -}}
    {{- $entry := index $configData $cfgKey -}}
    {{- if or (not (hasKey $entry "value")) (empty (index $entry "value")) -}}
      {{- fail (printf "%s: configData entry %q has no 'value' field or it is empty" $contextName $cfgKey) -}}
    {{- end -}}
    {{- /* Ensure numeric output */ -}}
    {{- printf "%d" (int (index $entry "value")) -}}
  {{- else -}}
    {{- /* literal port value */ -}}
    {{- printf "%v" $portCfg -}}
  {{- end -}}
{{- end -}}
