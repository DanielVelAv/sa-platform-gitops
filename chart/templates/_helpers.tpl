{{/*
=======================================================================
_helpers.tpl — plantillas nombradas compartidas.

En Helm el espacio de nombres de las plantillas es GLOBAL: lo que se
define aqui, en el chart padre, queda disponible para todos los
subcharts. Por eso los subcharts no repiten estos bloques.

Demuestra el uso real del motor de plantillas exigido por el enunciado:
range, if/else, required, default y quote.
=======================================================================
*/}}


{{/*
-----------------------------------------------------------------------
1. Nombre completo de un componente.
   Uso: {{ include "sa-platform.nombreCompleto" (dict "raiz" . "componente" "ms-auth") }}
   Kubernetes limita los nombres a 63 caracteres, de ahi el trunc.
-----------------------------------------------------------------------
*/}}
{{- define "sa-platform.nombreCompleto" -}}
{{- $componente := required "sa-platform.nombreCompleto necesita 'componente'" .componente -}}
{{- printf "%s-%s" .raiz.Release.Name $componente | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{/*
-----------------------------------------------------------------------
2. Etiquetas comunes a todo objeto del chart.
   Uso: {{- include "sa-platform.etiquetas" (dict "raiz" . "componente" "ms-auth") | nindent 4 }}
-----------------------------------------------------------------------
*/}}
{{- define "sa-platform.etiquetas" -}}
{{- $raiz := .raiz -}}
helm.sh/chart: {{ printf "%s-%s" $raiz.Chart.Name $raiz.Chart.Version | replace "+" "_" | quote }}
app.kubernetes.io/managed-by: {{ $raiz.Release.Service | quote }}
app.kubernetes.io/version: {{ $raiz.Chart.AppVersion | default "sin-version" | quote }}
app.kubernetes.io/part-of: "sa-platform"
{{ include "sa-platform.etiquetasSelector" . }}
{{- end -}}


{{/*
-----------------------------------------------------------------------
3. Etiquetas de seleccion. Son un subconjunto INMUTABLE de las
   anteriores: el selector de un Deployment no se puede cambiar despues
   de creado, por eso no incluye version ni chart.
-----------------------------------------------------------------------
*/}}
{{- define "sa-platform.etiquetasSelector" -}}
app.kubernetes.io/name: {{ .componente | quote }}
app.kubernetes.io/instance: {{ .raiz.Release.Name | quote }}
{{- end -}}


{{/*
-----------------------------------------------------------------------
4. Referencia completa de la imagen.
   `required` hace que la instalacion falle de inmediato si falta el
   repositorio, en vez de desplegar un pod que quedaria en ErrImagePull.
   Uso: {{ include "sa-platform.imagen" . }}   (desde un subchart)
-----------------------------------------------------------------------
*/}}
{{- define "sa-platform.imagen" -}}
{{- $repo := required "Debe definir image.repository para este componente" .Values.image.repository -}}
{{- $tag := .Values.image.tag | default .Values.global.imageTag | default "latest" -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}


{{/*
-----------------------------------------------------------------------
5. Contexto de seguridad del contenedor (requisito G).
   Usa `range` para recorrer la lista de capacidades que se eliminan.
-----------------------------------------------------------------------
*/}}
{{- define "sa-platform.contextoSeguridad" -}}
{{- $sc := .Values.global.securityContext -}}
runAsNonRoot: {{ $sc.runAsNonRoot | default true }}
runAsUser: {{ $sc.runAsUser | default 1000 }}
runAsGroup: {{ $sc.runAsGroup | default 1000 }}
readOnlyRootFilesystem: {{ $sc.readOnlyRootFilesystem | default true }}
allowPrivilegeEscalation: {{ $sc.allowPrivilegeEscalation | default false }}
capabilities:
  drop:
  {{- range $sc.capabilitiesDrop }}
    - {{ . | quote }}
  {{- end }}
{{- end -}}


{{/*
-----------------------------------------------------------------------
6. Las tres probes (requisito F).
   Cada una responde una pregunta distinta:
     startup   -> ¿ya termino de arrancar? Protege arranques lentos.
     readiness -> ¿puede atender trafico AHORA? Lo saca del balanceo.
     liveness  -> ¿quedo colgado? Reinicia el contenedor.
   El if/else permite omitir una probe si el componente no la define.
-----------------------------------------------------------------------
*/}}
{{- define "sa-platform.probes" -}}
{{- $p := .Values.probes | default dict -}}
{{- $puerto := .Values.puerto -}}
{{- if $p.startup }}
startupProbe:
  httpGet:
    path: {{ $p.startup.path | default "/health" | quote }}
    port: {{ $puerto }}
  periodSeconds: {{ $p.startup.periodSeconds | default 5 }}
  failureThreshold: {{ $p.startup.failureThreshold | default 12 }}
{{- end }}
{{- if $p.readiness }}
readinessProbe:
  httpGet:
    path: {{ $p.readiness.path | default "/health" | quote }}
    port: {{ $puerto }}
  periodSeconds: {{ $p.readiness.periodSeconds | default 10 }}
  failureThreshold: {{ $p.readiness.failureThreshold | default 3 }}
{{- else }}
{{- fail (printf "El componente %s debe definir al menos la probe de readiness" .Values.nombre) }}
{{- end }}
{{- if $p.liveness }}
livenessProbe:
  httpGet:
    path: {{ $p.liveness.path | default "/health" | quote }}
    port: {{ $puerto }}
  periodSeconds: {{ $p.liveness.periodSeconds | default 20 }}
  failureThreshold: {{ $p.liveness.failureThreshold | default 3 }}
{{- end }}
{{- end -}}


{{/*
-----------------------------------------------------------------------
7. Variables de entorno comunes.
   Lo NO sensible viene del ConfigMap y lo sensible del Secret, ambos
   generados por el chart padre (requisito B). Ningun valor va quemado
   en la plantilla.
-----------------------------------------------------------------------
*/}}
{{- define "sa-platform.envFromComun" -}}
- configMapRef:
    name: {{ .Values.global.configMapName | quote }}
{{- end -}}


{{/*
-----------------------------------------------------------------------
7b. Variables sensibles, referenciadas UNA POR UNA desde el Secret.

   No se usa `secretRef` en envFrom a proposito: el Secret contiene
   claves con guiones (database-url-ms-auth) que no son identificadores
   validos de variable de entorno, y Kubernetes las descartaria en
   silencio. Referenciando cada clave se controla ademas que cada
   servicio reciba solo los secretos que necesita.
-----------------------------------------------------------------------
*/}}
{{- define "sa-platform.envSecretos" -}}
- name: PORT
  value: {{ .Values.puerto | quote }}
{{- if .Values.usaBaseDatos }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.secretName | quote }}
      key: {{ printf "database-url-%s" .Values.nombre | quote }}
{{- end }}
{{- if .Values.usaBroker }}
- name: RABBITMQ_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.secretName | quote }}
      key: "RABBITMQ_URL"
{{- end }}
{{- range .Values.secretosExtra }}
- name: {{ . | quote }}
  valueFrom:
    secretKeyRef:
      name: {{ $.Values.global.secretName | quote }}
      key: {{ . | quote }}
{{- end }}
{{- end -}}


{{/*
-----------------------------------------------------------------------
8. Volumenes de escritura temporal.
   Con readOnlyRootFilesystem: true el contenedor no puede escribir en
   su propio sistema de archivos. Node y Python necesitan /tmp, asi que
   se monta un emptyDir efimero.
-----------------------------------------------------------------------
*/}}
{{- define "sa-platform.volumenesTemporales" -}}
- name: tmp
  emptyDir: {}
{{- end -}}

{{- define "sa-platform.montajesTemporales" -}}
- name: tmp
  mountPath: /tmp
{{- end -}}
