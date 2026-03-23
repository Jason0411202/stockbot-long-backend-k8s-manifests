{{/*
============================================================
_helpers.tpl — 可重複使用的模板片段（Helm 的「函式庫」）
============================================================

【什麼是 _helpers.tpl？】
  底線開頭的檔案不會被 Helm 渲染成 K8s 資源，
  而是作為「工具函式」給其他模板 {{ include "xxx" . }} 引用。

【define / include 怎麼用？】
  定義：{{- define "app.labels" -}} ... {{- end }}
  引用：{{ include "app.labels" . }}
  引用（帶縮排）：{{ include "app.labels" . | nindent 4 }}

【為什麼要抽出來？】
  labels 和 selector 在 6 個 YAML 裡重複出現，
  集中定義一次，避免改一處忘了改其他地方。
*/}}


{{/*
app.name — 應用程式名稱
用途：metadata.name、container name 等
*/}}
{{- define "app.name" -}}
{{ .Values.appName }}
{{- end }}


{{/*
app.labels — 通用 labels（貼在所有資源的 metadata.labels）
用途：kubectl get xxx -l app=myapp 時可以篩選
*/}}
{{- define "app.labels" -}}
app: {{ .Values.appName }}
{{- end }}


{{/*
app.selectorLabels — 選擇器用的 labels
用途：Deployment selector、Service selector、ServiceMonitor selector
⚠️ selector labels 一旦設定就不能改（K8s 不允許更新 selector）
所以跟 app.labels 分開定義，避免未來加了新 label 導致 selector 跟著變
*/}}
{{- define "app.selectorLabels" -}}
app: {{ .Values.appName }}
{{- end }}
