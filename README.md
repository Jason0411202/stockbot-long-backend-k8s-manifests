# stockbot-long-backend-k8s-manifests

App 的 K8s 部署設定（Helm Chart）。ArgoCD 監聽這個 repo，每一筆 commit = 一次部署變更。

> **這是一個教學 repo**，每個模板檔案都有詳細的中文註解，
> 適合想學習 Kubernetes + Helm 部署實戰的人閱讀。

---

## 在三個 Repo 中的角色

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  repo 1: stockbot-long-backend（Go app 原始碼）                     │
│  存放：Go 程式碼、Dockerfile、GitHub Actions CI/CD                   │
│  觸發：push to main → CI 跑測試 → build image → 通知 manifest repo  │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  repo 2: stockbot-long-backend-k8s-manifests（本 repo）             │
│  存放：Helm Chart（templates/ + values.yaml）                        │
│  誰改：CI 自動改 image tag / DevOps 手動調設定                        │
│  觸發：ArgoCD 監聽這個 repo → 自動 sync 到 K8s                       │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  repo 3: stockbot-long-backend-k8s-infra（基礎設施）                │
│  存放：MariaDB、ES、Kibana、Fluent Bit、Prometheus、Grafana、         │
│        Ingress Controller、ArgoCD、cert-manager 的設定               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 為什麼要分三個 Repo？

| 考量 | 說明 |
|------|------|
| **職責分離** | App 開發者只碰 app repo，不需要懂 K8s；K8s 設定獨立管理 |
| **部署解耦** | 改 K8s 設定不需要重新 build image，改 app 不需要動 manifest |
| **權限控制** | 可以對不同 repo 設不同的 GitHub 權限 |
| **GitOps 最佳實踐** | ArgoCD 建議把 manifest 跟 app 原始碼分開 |

---

## CI/CD 流程

```
GitHub Actions（在 app repo）build image 後
    │
    ▼
GitHub Actions 去改本 repo 的 values.yaml（更新 image.tag）
    │
    ▼
ArgoCD 偵測到本 repo 有變 → 用 Helm 渲染 → 自動 sync 到 K8s
    │
    ▼
K8s 執行 Rolling Update → Pod 跑起來
```

### CI/CD 更新 image tag 的方式

以前用 Kustomize 時是 `kustomize edit set image`，現在改用 Helm 後有兩種方式：

```bash
# 方式一：直接用 yq 改 values.yaml（推薦，簡單直接）
yq -i '.image.tag = "abc1234"' values.yaml

# 方式二：用 sed（不需要額外安裝工具）
sed -i 's/tag: .*/tag: abc1234/' values.yaml
```

---

## 目錄結構

```
stockbot-long-backend-k8s-manifests/
├── Chart.yaml              ← Helm Chart 的身分證（名稱、版本）
├── values.yaml             ← ⭐ 所有超參數集中在這裡（換專案只改這個檔案）
├── templates/              ← Helm 模板目錄
│   ├── _helpers.tpl        ← 共用模板片段（labels、selector 定義一次）
│   ├── namespace.yaml      ← Namespace：K8s 的邏輯隔離空間
│   ├── deployment.yaml     ← Deployment：管理 Pod 的部署控制器
│   ├── service.yaml        ← Service：Pod 的穩定入口 + 負載均衡
│   ├── ingress.yaml        ← Ingress：外部 HTTP 流量的路由規則
│   ├── servicemonitor.yaml ← ServiceMonitor：讓 Prometheus 自動監控
│   └── hpa.yaml            ← HPA：根據 CPU 使用率自動擴縮 Pod
└── README.md

# ⚠️ 沒有 secret.yaml
# DB 密碼不放在 Git 裡
# Secret 由 infra repo 的 install-all.sh 用指令建在 K8s 裡
```

---

## 為什麼從 Kustomize 改成 Helm？

| 問題 | Kustomize | Helm |
|------|-----------|------|
| 換專案要改的地方 | 散佈在 7 個 YAML 裡，逐一搜尋替換 | **集中在 `values.yaml` 一個檔案** |
| 可讀性 | 要看每個 YAML 才知道有哪些參數 | **看 `values.yaml` 就是完整清單** |
| 條件渲染 | 不支援（例如：有沒有裝 Prometheus） | **`{{- if .Values.serviceMonitor.enabled }}`** |
| ArgoCD 支援 | 原生支援 | 原生支援 |

---

## values.yaml 超參數總覽

> 換專案時，只需要修改 `values.yaml`，不用動 templates/ 裡的任何檔案。

| 參數 | 預設值 | 說明 | 對齊 infra repo |
|------|--------|------|-----------------|
| `appName` | `myapp` | 應用名稱（用在所有資源的 name 和 labels） | |
| `namespace` | `myapp` | K8s Namespace | install-all.sh 建立的 namespace |
| `image.repository` | `ghcr.io/yourorg/stockbot-long-backend` | Container image 路徑 | |
| `image.tag` | `latest` | Image tag（CI/CD 自動更新） | |
| `containerPort` | `8080` | Go app 監聽的 port | |
| `ingress.host` | `myapp.local` | 域名 | install-all.sh 輸出的 URL |
| `ingress.className` | `nginx` | Ingress Controller 類型 | ingress-nginx controller |
| `ingress.maxBodySize` | `10m` | 允許的最大 request body | |
| `secret.name` | `myapp-db` | DB Secret 名稱 | install-all.sh 建立的 Secret |
| `secret.key` | `dsn` | Secret 中的 key | install-all.sh 建立的 key |
| `envName` | `DB_DSN` | 環境變數名稱 | Go app 的 os.Getenv() |
| `serviceMonitor.enabled` | `true` | 是否建立 ServiceMonitor | |
| `serviceMonitor.releaseLabel` | `monitoring` | Prometheus 的 Helm release name | `helm upgrade --install monitoring ...` |
| `serviceMonitor.interval` | `15s` | 指標抓取間隔 | |
| `resources.requests.cpu` | `50m` | CPU 最低保證 | |
| `resources.requests.memory` | `32Mi` | 記憶體最低保證 | |
| `resources.limits.cpu` | `250m` | CPU 上限 | |
| `resources.limits.memory` | `128Mi` | 記憶體上限 | |
| `hpa.minReplicas` | `2` | 最少副本數 | |
| `hpa.maxReplicas` | `5` | 最多副本數 | |
| `hpa.targetCPU` | `70` | 目標 CPU 使用率 % | |

---

## K8s 基礎觀念速查

### 資源之間的關係圖

```
                        ┌──────────────────────────┐
                        │       使用者瀏覽器         │
                        └────────────┬─────────────┘
                                     │ HTTP 請求
                                     ▼
                        ┌──────────────────────────┐
                        │    Ingress Controller     │ ← 實際的 nginx 反向代理
                        │    (nginx, 裝在 infra)    │    （讀取 Ingress 規則來路由）
                        └────────────┬─────────────┘
                                     │ 根據 Ingress 規則路由
                                     ▼
              ┌──────────────────────────────────────────────┐
              │              Ingress (ingress.yaml)          │
              │   規則：host=myapp.local, path=/ → myapp:80  │
              └────────────────────┬─────────────────────────┘
                                   │
                                   ▼
              ┌──────────────────────────────────────────────┐
              │            Service (service.yaml)            │
              │      穩定 DNS: myapp.myapp.svc.cluster.local │
              │      port:80 → targetPort:8080               │
              └───────┬────────────────────┬─────────────────┘
                      │ 負載均衡            │
                      ▼                    ▼
              ┌──────────────┐    ┌──────────────┐
              │   Pod (副本1) │    │   Pod (副本2) │  ← Deployment 管理
              │   :8080      │    │   :8080      │  ← HPA 控制數量
              └──────────────┘    └──────────────┘
                      │                    │
                      ▼                    ▼
              ┌──────────────────────────────────────────────┐
              │         Prometheus (ServiceMonitor)          │
              │     每 15 秒抓取 /metrics 端點的指標          │
              └──────────────────────────────────────────────┘
```

### 核心觀念對照表

| K8s 概念 | 白話解釋 | 類比 |
|---------|---------|------|
| **Namespace** | 資源的邏輯隔離空間 | 資料夾 |
| **Pod** | 最小部署單位，跑一個或多個容器 | 一台虛擬機 |
| **Deployment** | 管理 Pod 的控制器，確保指定數量的 Pod 在跑 | 自動化管理員 |
| **Service** | Pod 的穩定入口，提供 DNS 和負載均衡 | 總機 / 電話分機 |
| **Ingress** | 外部 HTTP 流量的路由規則 | 門牌 + 路標 |
| **HPA** | 自動根據負載擴縮 Pod 數量 | 自動增減櫃台人員 |
| **ServiceMonitor** | 告訴 Prometheus 要監控哪些 Service | 監視器安裝清單 |
| **Secret** | 存放敏感資料（密碼、token） | 保險箱 |
| **Helm Chart** | K8s 的包管理工具，一個 chart = 一組可參數化的 YAML | npm package |

### Label 與 Selector 的串接邏輯

```
Deployment.spec.selector.matchLabels: app=myapp
        │ 必須一致
        ▼
Pod.metadata.labels: app=myapp
        │ Service 靠這個找到 Pod
        ▼
Service.spec.selector: app=myapp
        │ ServiceMonitor 靠這個找到 Service
        ▼
ServiceMonitor.spec.selector.matchLabels: app=myapp

⚠️ 如果任何一層的 label 對不上，流量就斷了！
   用 Helm 的好處：這些 label 都在 _helpers.tpl 定義一次，不會對不上。
```

---

## Helm 模板語法速查

> 給第一次看 Helm 模板的人。

| 語法 | 說明 | 範例 |
|------|------|------|
| `{{ .Values.xxx }}` | 讀取 values.yaml 的值 | `{{ .Values.appName }}` → `myapp` |
| `{{ include "xxx" . }}` | 引用 _helpers.tpl 的模板 | `{{ include "app.name" . }}` → `myapp` |
| `{{ .Values.xxx \| quote }}` | 加上引號 | `{{ .Values.ingress.host \| quote }}` → `"myapp.local"` |
| `{{- xxx }}` / `{{ xxx -}}` | 去掉前/後的空白行 | 避免渲染出多餘的空行 |
| `nindent N` | 插入並縮排 N 格 | `{{ include "app.labels" . \| nindent 4 }}` |
| `toYaml` | 把 values 的 YAML 結構原封不動輸出 | `{{ toYaml .Values.resources \| nindent 12 }}` |
| `{{- if .Values.xxx }}` | 條件渲染 | ServiceMonitor 的 enabled 開關 |

### 預覽渲染結果

```bash
# 在本機預覽 Helm 渲染後的完整 YAML（不實際部署）
helm template myapp .

# 只看某個模板的結果
helm template myapp . -s templates/deployment.yaml

# 用自訂值覆蓋 values.yaml
helm template myapp . --set image.tag=abc1234
```

---

## 各檔案說明

### Chart.yaml

> Helm Chart 的身分證。ArgoCD 看到這個檔案就知道要用 Helm 渲染。

### values.yaml

> 所有超參數集中在這裡。換專案只改這個檔案。

### templates/_helpers.tpl

> 共用模板片段。labels 和 selector 定義一次，所有模板共用，避免對不上。

### templates/namespace.yaml

> 建立專屬 Namespace。

### templates/deployment.yaml

> Pod 的模板：image、port、環境變數、健康檢查、資源限制。

### templates/service.yaml

> 提供穩定 DNS 和負載均衡，把外部的 port 80 轉發到 Pod 的 8080。

### templates/ingress.yaml

> 定義外部 HTTP 路由規則（host + path → Service）。

### templates/servicemonitor.yaml

> 告訴 Prometheus 監控這個 app 的 /metrics（可透過 enabled 開關關閉）。

### templates/hpa.yaml

> 根據 CPU 使用率自動擴縮 Pod 數量。

---

## Secret 說明（不在本 repo 中）

> ⚠️ **Secret 不放在本 repo 的 Git 裡。**
>
> DB 連線字串含明文密碼，即使 repo 是 private，放在 Git 歷史裡也永遠刪不掉。
>
> Secret 由 `stockbot-long-backend-k8s-infra` repo 的 `install-all.sh` 用指令建立：
> ```bash
> kubectl -n myapp create secret generic myapp-db \
>   --from-literal=dsn="myapp:${MARIADB_PASSWORD}@tcp(mariadb.myapp.svc.cluster.local:3306)/myapp?parseTime=true" \
>   --dry-run=client -o yaml | kubectl apply -f -
> ```
> 密碼從 `.env` 讀取，只存在 K8s cluster 裡。ArgoCD 不管理這個 Secret（不在 Helm Chart 裡），不會覆蓋或刪掉它。

---

## 跟 infra repo 的對齊關係

```
本 repo (values.yaml)                      infra repo
─────────────────────                      ──────────
secret.name: myapp-db          ←──對齊──→  install-all.sh: kubectl create secret generic myapp-db
secret.key: dsn                ←──對齊──→  install-all.sh: --from-literal=dsn="..."
serviceMonitor.releaseLabel:   ←──對齊──→  install-all.sh: helm upgrade --install monitoring ...
  monitoring
ingress.className: nginx       ←──對齊──→  install-all.sh: helm upgrade --install ingress-nginx ...
namespace: myapp               ←──對齊──→  install-all.sh: kubectl create namespace myapp
ingress.host: myapp.local      ←──對齊──→  install-all.sh 最後印出的 URL
```

---

## 常見操作指令速查

### Helm 操作

```bash
helm template myapp .                             # 預覽渲染結果（不部署）
helm template myapp . -s templates/deployment.yaml # 只看某個模板
helm install myapp . -n myapp                      # 手動安裝（通常交給 ArgoCD）
helm upgrade myapp . -n myapp                      # 手動升級
helm uninstall myapp -n myapp                      # 移除所有資源
```

### 查看資源狀態

```bash
kubectl get all -n myapp                          # 列出所有資源
kubectl get pods -n myapp -o wide                 # 列出 Pod（含 Node 和 IP）
kubectl describe pod <pod-name> -n myapp          # 查看 Pod 詳細狀態
kubectl logs <pod-name> -n myapp                  # 查看日誌
kubectl logs <pod-name> -n myapp -f               # 即時追蹤日誌
kubectl logs <pod-name> -n myapp --previous       # 查看上一個容器的日誌（crash 後用）
```

### 部署相關

```bash
kubectl rollout status deploy/myapp -n myapp      # 查看部署進度
kubectl rollout history deploy/myapp -n myapp     # 查看部署歷史
kubectl rollout undo deploy/myapp -n myapp        # 回滾到上一版
kubectl rollout restart deploy/myapp -n myapp     # 重啟所有 Pod
```

### 擴縮與 HPA

```bash
kubectl get hpa -n myapp                          # 查看 HPA 狀態
kubectl top pods -n myapp                         # 查看 Pod 實際資源用量
```

### 除錯

```bash
kubectl exec -it <pod-name> -n myapp -- sh        # 進入 Pod shell
kubectl port-forward svc/myapp 8080:80 -n myapp   # 映射到本機 localhost:8080
kubectl get events -n myapp --sort-by=.metadata.creationTimestamp  # 查看事件
```

---

## 常見問題與除錯

### Pod 一直 CrashLoopBackOff

1. `kubectl logs <pod> -n myapp --previous` 看上一次 crash 的日誌
2. 通常原因：DB 連不上（Secret 沒建 / DSN 錯誤）、port 衝突、程式 panic

### HPA 顯示 `<unknown>/70%`

1. 確認 Metrics Server 有安裝
2. `kubectl top pods -n myapp` 如果報錯，代表 Metrics Server 有問題
3. 確認 Deployment 有設定 `resources.requests.cpu`

### Prometheus 抓不到指標

1. 檢查 `values.yaml` 的 `serviceMonitor.releaseLabel` 是否跟 infra 的 Prometheus Helm release name 一致
2. Prometheus UI → Status → Targets 確認
3. `kubectl port-forward <pod> 8080:8080 -n myapp` → `curl localhost:8080/metrics`

### Ingress 不通

1. `kubectl get ingress -n myapp` 確認 ADDRESS 有值
2. 確認 Ingress Controller 有安裝（`kubectl get pods -n ingress-nginx`）
3. 確認 `/etc/hosts` 設定正確

### ArgoCD 顯示 OutOfSync

1. 確認 ArgoCD Application 的 `path` 已從 `base` 改為 `.`（根目錄）
2. ArgoCD 偵測到 `Chart.yaml` 會自動用 Helm 渲染
3. 到 ArgoCD UI 查看 diff，確認差異是否預期
