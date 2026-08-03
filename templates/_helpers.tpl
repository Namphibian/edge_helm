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
app.kebab — convert CamelCase or camelCase to kebab-case and lowercase.
Usage: {{ include "app.kebab" "dataVolume" }}
*/ -}}
{{- define "app.kebab" -}}
{{ $s := . }}
{{- $withDashes := regexReplaceAll "([A-Z])" $s "-${1}" }}
{{- $trimmed := regexReplaceAll "^[-]+" $withDashes "" }}
{{ $trimmed = regexReplaceAll "[-]+$" $trimmed "" }}
{{ lower $trimmed }}
{{- end -}}

{{- /*
app.fileResourceName — build a deterministic resource/volume name for a configFiles entry.

Parameters (list): [ $root, $file ]
  - $root : the Helm root context ($)
  - $file : a single app.configFiles entry (must have .name and .type)

Returns: "<fullname>-<kebab(file.name)>-<type>" truncated to 63 characters.

Usage: {{ include "app.fileResourceName" (list $ $file) }}
*/ -}}
{{- define "app.fileResourceName" -}}
{{- $root := index . 0 -}}
{{- $file := index . 1 -}}
{{- $type := lower (default "configmap" $file.type) -}}
{{- printf "%s-%s-%s" (trim (include "app.fullname" $root)) (trim (include "app.kebab" $file.name)) $type | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- /*
app.resolveConfigDataEntry — shared configDataKey lookup used by app.configValue and app.envValue.

Centralises all parsing, validation, and entry extraction so neither consumer
duplicates the logic.  Returns a JSON-encoded envelope consumed via fromJson:

  {
    "cfgKey"   : string   — the base configData key (before any dot)
    "subField" : string   — single sub-field name, or "" if none
    "value"    : any      — raw value from the configData entry
    "type"     : string   — "int" | "string" | "list" | "url" | ""
    "joinChar" : string   — list join delimiter (default ",")
  }

Parameters (list): [ $rawKey, $configData, $contextName ]
  - $rawKey      : the raw configDataKey string.
                   Supports exactly one level of dot-notation sub-field access:
                     "buyboostOpenapiHost.host"  → cfgKey=buyboostOpenapiHost, subField=host
                   Deeper paths (e.g. "a.b.c") are not supported and will fail.
  - $configData  : $.Values.configData
  - $contextName : caller label used in fail() messages

Fails with a descriptive message if:
  - $rawKey contains more than one dot (nested path not supported)
  - the base key is not found in configData
  - the matching entry has no "value" field
*/ -}}
{{- define "app.resolveConfigDataEntry" -}}
  {{- $rawKey      := index . 0 -}}
  {{- $configData  := index . 1 -}}
  {{- $contextName := index . 2 -}}
  {{- $parts := splitList "." $rawKey -}}
  {{- if gt (len $parts) 2 -}}
    {{- fail (printf "%s: configDataKey %q contains more than one dot; only a single sub-field level is supported (e.g. \"buyboostOpenapiHost.host\")" $contextName $rawKey) -}}
  {{- end -}}
  {{- $cfgKey   := first $parts -}}
  {{- $subField := "" -}}
  {{- if eq (len $parts) 2 -}}{{- $subField = last $parts -}}{{- end -}}
  {{- if not (hasKey $configData $cfgKey) -}}
    {{- fail (printf "%s: configDataKey %q not found in .Values.configData" $contextName $cfgKey) -}}
  {{- end -}}
  {{- $entry := index $configData $cfgKey -}}
  {{- if not (hasKey $entry "value") -}}
    {{- fail (printf "%s: configData entry %q has no 'value' field" $contextName $cfgKey) -}}
  {{- end -}}
  {{- $entryType := "" -}}
  {{- if hasKey $entry "type" -}}{{- $entryType = lower (printf "%v" (index $entry "type")) -}}{{- end -}}
  {{- $joinChar := "," -}}
  {{- if hasKey $entry "joinChar" -}}{{- $joinChar = index $entry "joinChar" -}}{{- end -}}
  {{- dict
      "cfgKey"   $cfgKey
      "subField" $subField
      "value"    (index $entry "value")
      "type"     $entryType
      "joinChar" $joinChar
    | toJson -}}
{{- end -}}

{{- /*
app.assembleUrl — assemble a URL string from a structured url-type value map.

Parameters: a map with keys:
  scheme (optional, default "http"), host (required), port (optional), path (optional)

Returns: assembled URL string, e.g. "https://172.16.125.46:8185/buyboost"

Usage: {{ include "app.assembleUrl" $urlValueMap }}
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
app.configValue — resolve a value that is either a literal or a configDataKey reference.

Parameters (list): [ $cfg, $configData, $contextName ]
  - $cfg          : the value to resolve — a literal (string/int/bool/…) or a
                    map containing a "configDataKey" key
  - $configData   : $.Values.configData
  - $contextName  : caller label used in fail() messages

Returns the resolved value as-is (callers are responsible for further formatting):
  - configDataKey with a single dot sub-field  → the specific sub-field value
  - configDataKey pointing to a type:url entry → assembled URL string
  - configDataKey pointing to any other entry  → raw entry value
  - literal value                              → passed through unchanged

Sub-field dot-notation supports exactly ONE level (e.g. "key.subField").
Paths with more than one dot (e.g. "a.b.c") will fail at render time.

Examples:
  configDataKey: buyboostOpenapiHost          → "http://172.16.125.46:8185/buyboost"
  configDataKey: buyboostOpenapiHost.host     → "172.16.125.46"
  configDataKey: buyboostOpenapiHost.port     → 8185
  configDataKey: buyboostOpenapiHost.scheme   → "http"
  configDataKey: buyboostOpenapiHost.path     → "/buyboost"
*/ -}}
{{- define "app.configValue" -}}
  {{- $cfg         := index . 0 -}}
  {{- $configData  := index . 1 -}}
  {{- $contextName := index . 2 -}}
  {{- if kindIs "map" $cfg -}}
    {{- if hasKey $cfg "configDataKey" -}}
      {{- $r := include "app.resolveConfigDataEntry" (list (index $cfg "configDataKey") $configData $contextName) | fromJson -}}
      {{- if $r.subField -}}
        {{- if not (kindIs "map" $r.value) -}}
          {{- fail (printf "%s: configDataKey %q value is not a map; cannot access sub-field %q" $contextName $r.cfgKey $r.subField) -}}
        {{- end -}}
        {{- if not (hasKey $r.value $r.subField) -}}
          {{- fail (printf "%s: configData entry %q has no sub-field %q" $contextName $r.cfgKey $r.subField) -}}
        {{- end -}}
        {{- index $r.value $r.subField -}}
      {{- else if eq $r.type "url" -}}
        {{- include "app.assembleUrl" $r.value -}}
      {{- else -}}
        {{- $r.value -}}
      {{- end -}}
    {{- else -}}
      {{- $cfg -}}
    {{- end -}}
  {{- else -}}
    {{- $cfg -}}
  {{- end -}}
{{- end -}}

{{- /*
app.configValueStr — identical to app.configValue; always returns a string.
Kept as a named alias for call-sites that explicitly want a string context.
*/ -}}
{{- define "app.configValueStr" -}}
  {{- include "app.configValue" . -}}
{{- end -}}

{{- /*
app.annotations — render a merged annotations block from named annotation sets.

Parameters (list): [ $annotationNames, $root, $annotationSets? ]
  - $annotationNames : list of annotation-set names defined in app.annotationSets
  - $root            : the Helm root context ($)
  - $annotationSets  : optional app-specific annotationSets map

Outputs key: "value" lines (without the parent "annotations:" key).
Annotation values support the configDataKey pattern.
*/ -}}
{{- define "app.annotations" -}}
{{- $annotationNames := index . 0 -}}
{{- $root := index . 1 -}}
{{- $annotationSets := dict -}}
{{- if ge (len .) 3 -}}
  {{- $annotationSets = (index . 2 | default dict) -}}
{{- else -}}
  {{- if and (kindIs "map" $root.Values.app) (gt (len $root.Values.app) 0) -}}
    {{- $firstAppName := first (keys $root.Values.app | sortAlpha) -}}
    {{- $firstApp := index $root.Values.app $firstAppName -}}
    {{- if and (kindIs "map" $firstApp) (hasKey $firstApp "annotationSets") -}}
      {{- $annotationSets = index $firstApp "annotationSets" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- range $asetName := $annotationNames -}}
{{- if not (hasKey $annotationSets $asetName) -}}
  {{- fail (printf "annotation set %q not found" $asetName) -}}
{{- end -}}
{{- $aset := index $annotationSets $asetName -}}
{{- range $ak := (keys $aset | sortAlpha) }}
{{- $av := index $aset $ak }}
{{ $ak }}: {{ include "app.configValue" (list $av $root.Values.configData (printf "annotation %s.%s" $asetName $ak)) | quote }}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /*
app.envValue — resolve a value for use as a container env-var string.

Parameters (list): [ $cfg, $configData, $contextName ]
  - $cfg          : the value to resolve — a literal or a configDataKey map
  - $configData   : $.Values.configData
  - $contextName  : caller label used in fail() messages

Resolution rules (applied in order):
  1. configDataKey with dot-notation sub-field  → raw sub-field value as string
  2. configDataKey pointing to a type:url entry → assembled URL string
  3. configDataKey pointing to a list-of-maps   → JSON string
  4. configDataKey pointing to a list-of-scalars→ joinChar-delimited string
  5. configDataKey pointing to a scalar         → plain string
  6. plain map (no configDataKey)               → JSON string
  7. literal slice                              → JSON (if list-of-maps) or
                                                  comma-joined (if list-of-scalars)
  8. literal scalar                             → plain string
*/ -}}
{{- define "app.envValue" -}}
  {{- $cfg         := index . 0 -}}
  {{- $configData  := index . 1 -}}
  {{- $contextName := index . 2 -}}
  {{- if kindIs "map" $cfg -}}
    {{- if hasKey $cfg "configDataKey" -}}
      {{- $r := include "app.resolveConfigDataEntry" (list (index $cfg "configDataKey") $configData $contextName) | fromJson -}}
      {{- if $r.subField -}}
        {{- if not (kindIs "map" $r.value) -}}
          {{- fail (printf "%s: configDataKey %q value is not a map; cannot access sub-field %q" $contextName $r.cfgKey $r.subField) -}}
        {{- end -}}
        {{- if not (hasKey $r.value $r.subField) -}}
          {{- fail (printf "%s: configData entry %q has no sub-field %q" $contextName $r.cfgKey $r.subField) -}}
        {{- end -}}
        {{- index $r.value $r.subField -}}
      {{- else if eq $r.type "url" -}}
        {{- include "app.assembleUrl" $r.value -}}
      {{- else if kindIs "slice" $r.value -}}
        {{- if and (gt (len $r.value) 0) (kindIs "map" (index $r.value 0)) -}}
          {{- toJson $r.value -}}
        {{- else -}}
          {{- join $r.joinChar (toStrings $r.value) -}}
        {{- end -}}
      {{- else -}}
        {{- $r.value -}}
      {{- end -}}
    {{- else -}}
      {{- toJson $cfg -}}
    {{- end -}}
  {{- else if kindIs "slice" $cfg -}}
    {{- if and (gt (len $cfg) 0) (kindIs "map" (index $cfg 0)) -}}
      {{- toJson $cfg -}}
    {{- else -}}
      {{- join "," (toStrings $cfg) -}}
    {{- end -}}
  {{- else -}}
    {{- $cfg -}}
  {{- end -}}
{{- end -}}

{{- /*
app.transformContent — render a transform map as KEY=VALUE lines for use in
                       configFiles entries (e.g. .properties / env-file format).

Parameters (list): [ $transform, $configData, $contextName ]
  - $transform    : map of "some.key": (literal | configDataKey reference)
  - $configData   : $.Values.configData
  - $contextName  : caller label used in fail() messages

Each value is resolved using app.envValue, so lists, maps and URL types are
serialised with the same rules as container env vars.

Example output:
  server.port=8080
  server.servlet.context-path=/evs
  storage.forbidden.file.types=.exe,.com,.dll,...
  openapi.users=[{"ak":"test1","orgs":["**"],"sk":"000000"}]
*/ -}}
{{- define "app.transformContent" -}}
  {{- $transform   := index . 0 -}}
  {{- $configData  := index . 1 -}}
  {{- $contextName := index . 2 -}}
  {{- $lines := list -}}
  {{- range $k := (keys $transform | sortAlpha) -}}
    {{- $v := index $transform $k -}}
    {{- $resolved := include "app.envValue" (list $v $configData (printf "%s.%s" $contextName $k)) -}}
    {{- $lines = append $lines (printf "%s=%s" $k $resolved) -}}
  {{- end -}}
  {{- join "\n" $lines -}}
{{- end -}}

{{- /*
app.resolvePort — resolve a port value and guarantee numeric string output.

Parameters (list): [ $portCfg, $configData, $contextName, $strictConfigRefOnly? ]
  - $portCfg      : the port value — either a literal number/string or a map
                    containing "configDataKey" (preferred) or
                    "portDefinitionKey" (legacy alias) pointing to a port value
  - $configData   : $.Values.configData
  - $contextName  : caller label used in fail() messages
  - $strictConfigRefOnly (optional): when true, map refs must use configDataKey
                                     and portDefinitionKey is rejected

Returns: the port as a numeric string (e.g. "8080").

Both the configDataKey/portDefinitionKey and literal branches are stringified to $raw via
printf "%v", then validated with regex "^[1-9][0-9]*$" before int()
conversion. This prevents silent coercion of non-numeric values to 0 and
rejects strings that look non-numeric (e.g. "http-tomcat", "0", "8.0").
*/ -}}
{{- define "app.resolvePort" -}}
  {{- $portCfg     := index . 0 -}}
  {{- $configData  := index . 1 -}}
  {{- $contextName := index . 2 -}}
  {{- $strictConfigRefOnly := false -}}
  {{- if ge (len .) 4 -}}
    {{- $strictConfigRefOnly = index . 3 -}}
  {{- end -}}
  {{- $raw := "" -}}
  {{- if kindIs "map" $portCfg -}}
    {{- $hasCfgRef := hasKey $portCfg "configDataKey" -}}
    {{- $hasPortDefRef := hasKey $portCfg "portDefinitionKey" -}}
    {{- if and $strictConfigRefOnly $hasPortDefRef -}}
      {{- fail (printf "%s: portDefinitionKey is not allowed in this context; use configDataKey or a literal numeric value" $contextName) -}}
    {{- end -}}
    {{- if and $hasCfgRef $hasPortDefRef -}}
      {{- fail (printf "%s: port map cannot contain both configDataKey and portDefinitionKey" $contextName) -}}
    {{- end -}}
    {{- if not (or $hasCfgRef $hasPortDefRef) -}}
      {{- fail (printf "%s: port map must contain configDataKey (preferred) or portDefinitionKey" $contextName) -}}
    {{- end -}}
    {{- $ref := "" -}}
    {{- if $hasCfgRef -}}
      {{- $ref = index $portCfg "configDataKey" -}}
    {{- else -}}
      {{- $ref = index $portCfg "portDefinitionKey" -}}
    {{- end -}}
    {{- $r := include "app.resolveConfigDataEntry" (list $ref $configData $contextName) | fromJson -}}
    {{- if $r.subField -}}
      {{- if not (kindIs "map" $r.value) -}}
        {{- fail (printf "%s: portDefinitionKey %q value is not a map; cannot access sub-field %q" $contextName $r.cfgKey $r.subField) -}}
      {{- end -}}
      {{- if not (hasKey $r.value $r.subField) -}}
        {{- fail (printf "%s: configData entry %q has no sub-field %q" $contextName $r.cfgKey $r.subField) -}}
      {{- end -}}
      {{- $raw = printf "%v" (index $r.value $r.subField) -}}
    {{- else -}}
      {{- $raw = printf "%v" $r.value -}}
    {{- end -}}
  {{- else -}}
    {{- $raw = printf "%v" $portCfg -}}
  {{- end -}}
  {{- if not (regexMatch "^[1-9][0-9]*$" $raw) -}}
    {{- fail (printf "%s: port value %q is not a valid positive integer (must match ^[1-9][0-9]*$)" $contextName $raw) -}}
  {{- end -}}
  {{- printf "%d" (int $raw) -}}
{{- end -}}
