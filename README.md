# stockbot-long-backend-k8s-manifests

App 的 K8s 部署設定。ArgoCD 監聽這個 repo，每一筆 commit = 一次部署變更。

> **這是一個教學 repo**，每個 YAML 檔案都有詳細的中文註解，
> 適合想學習 Kubernetes 部署實戰的人閱讀。

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
│  存放：Deployment、Service、Ingress、HPA 等 YAML                     │
│  誰改：CI 自動改 image tag / DevOps 手動調設定                        │
│  觸發：ArgoCD 監聯這個 repo → 自動 sync 到 K8s                       │
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
| **權限控制** | 可以對不同 repo 設不同的 GitHub 權限（誰能改部署設定）|
| **GitOps 最佳實踐** | ArgoCD 建議把 manifest 跟 app 原始碼分開（Single Source of Truth）|

---

## CI/CD 流程中的位置

```
GitHub Actions（在 app repo）build image 後
    │
    ▼
GitHub Actions 去改本 repo 的 image tag（base/kustomization.yaml）
    │
    ▼
ArgoCD 偵測到本 repo 有變 → 自動 sync 部署到 K8s
    │
    ▼
Pod 跑起來
```

### 流程詳細說明

1. **開發者 push 程式碼到 app repo 的 main branch**
2. **GitHub Actions 啟動 CI pipeline**：跑測試 → build Docker image → push 到 GHCR（GitHub Container Registry）
3. **GitHub Actions 用 `kustomize edit set image` 修改本 repo 的 `kustomization.yaml`**：把 image tag 從舊的 SHA 換成新的 SHA
4. **ArgoCD 每 3 分鐘（預設）輪詢本 repo**：偵測到 kustomization.yaml 有變更
5. **ArgoCD 自動 sync**：用 `kustomize build` 產生最終 YAML，`kubectl apply` 到 K8s cluster
6. **K8s 執行 Rolling Update**：建立新 Pod → 等新 Pod ready → 刪除舊 Pod → 零停機完成部署

---

## 目錄結構

```
stockbot-long-backend-k8s-manifests/
└── base/                           ← Kustomize 的 base 層（基礎設定）
    ├── kustomization.yaml          ← Kustomize 總管清單（列出所有要部署的 YAML）
    ├── namespace.yaml              ← Namespace：K8s 的邏輯隔離空間
    ├── deployment.yaml             ← Deployment：管理 Pod 的部署控制器
    ├── service.yaml                ← Service：Pod 的穩定入口 + 負載均衡
    ├── ingress.yaml                ← Ingress：外部 HTTP 流量的路由規則
    ├── servicemonitor.yaml         ← ServiceMonitor：讓 Prometheus 自動監控
    └── hpa.yaml                    ← HPA：根據 CPU 使用率自動擴縮 Pod

# ⚠️ 沒有 secret.yaml
# DB 密碼不放在 Git 裡
# Secret 由 infra repo 的 install-all.sh 用指令建在 K8s 裡
```

---

## K8s 基礎觀念速查

> 如果你對 Kubernetes 還不太熟悉，這一段幫你快速建立核心概念。

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
| **Kustomize** | K8s 原生的設定管理工具 | 多環境設定檔合併器 |

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
```

---

## 各檔案說明

### base/namespace.yaml

> 建立一個專屬的 Namespace，讓所有資源住在同一個空間裡。

```yaml
apiVersion: v1          # Namespace 是 K8s 核心 API
kind: Namespace
metadata:
  name: myapp           # 之後所有資源的 namespace 欄位都填這個
```

**教學重點**：
- Namespace 是 K8s 的邏輯隔離單位，不同 Namespace 的資源互不干擾
- 刪除 Namespace 會**連裡面所有資源一起刪掉**（包括 Pod、Service、Secret…）
- K8s 預設有 `default`、`kube-system`、`kube-public` 等 Namespace

---

### base/deployment.yaml

> 定義 app 要怎麼跑：用什麼 image、開什麼 port、怎麼健康檢查、給多少資源。

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: myapp
spec:
  replicas: 1                     # Pod 副本數（HPA 啟用後會自動覆蓋）

  selector:
    matchLabels:
      app: myapp                  # ⚠️ 必須跟 template.metadata.labels 一致

  template:
    metadata:
      labels:
        app: myapp                # Pod 的標籤（Service 靠這個找到 Pod）
      annotations:
        prometheus.io/scrape: "true"    # 告訴 Prometheus 要抓這個 Pod
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"

    spec:
      containers:
        - name: myapp
          image: ghcr.io/yourorg/stockbot-long-backend:latest

          ports:
            - name: http
              containerPort: 8080       # Go app 監聽的 port

          env:
            - name: DB_DSN
              valueFrom:
                secretKeyRef:
                  name: myapp-db        # Secret 由 infra repo 建立（不在 Git 裡）
                  key: dsn

          livenessProbe:                # 失敗 → K8s 重啟容器
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10

          readinessProbe:               # 失敗 → 從 Service 流量中移除
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10

          resources:
            requests:                   # 保證的最低資源（影響排程）
              cpu: 50m
              memory: 32Mi
            limits:                     # 資源上限（超過 memory → OOMKill）
              cpu: 250m
              memory: 128Mi
```

**教學重點**：

| 欄位 | 說明 |
|------|------|
| `selector.matchLabels` | 必須跟 `template.metadata.labels` 一致，否則建不起來 |
| `livenessProbe` | 偵測容器是否「活著」，失敗 → 重啟。用途：偵測 deadlock |
| `readinessProbe` | 偵測容器是否「準備好」，失敗 → 不接收流量。用途：啟動中連 DB |
| `resources.requests` | K8s 排程保證的最低資源，HPA 的 CPU% 也是依據這個計算 |
| `resources.limits` | 容器能用的資源上限。CPU 超限 → 被限速；Memory 超限 → OOMKill |
| `secretKeyRef` | 從 K8s Secret 讀取敏感資料，不寫死在 YAML 裡 |

**CPU 單位**：`1000m = 1 核心`，所以 `50m = 0.05 核心`
**Memory 單位**：`Mi = MiB`（1 MiB = 1024 KiB）

---

### base/service.yaml

> 提供穩定的 DNS 名稱和 ClusterIP，把流量負載均衡到背後的 Pod。

```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
  namespace: myapp
  labels:
    app: myapp
spec:
  selector:
    app: myapp          # 流量導到所有 label 含 app=myapp 的 Pod
  ports:
    - name: http
      port: 80          # Service 對外的 port（Ingress 連這個）
      targetPort: 8080  # 轉發到 Pod 的 port（Go app 監聽的）
```

**教學重點**：

- **為什麼需要 Service？** Pod IP 每次重建都會變，Service 提供穩定的 DNS 名稱
- **DNS 名稱**：`myapp.myapp.svc.cluster.local`（服務名.命名空間.svc.cluster.local）
- **port vs targetPort**：
  ```
  Ingress → Service:80 (port) → Pod:8080 (targetPort)
  ```
- **Service 類型**：沒指定 `type` 就是 `ClusterIP`（只在 cluster 內部可見）
  - `ClusterIP`：內部用（本檔案）
  - `NodePort`：每個 Node 開一個 port
  - `LoadBalancer`：雲端自動建外部 LB

---

### base/ingress.yaml

> 定義外部 HTTP 請求怎麼路由到內部 Service。

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"  # 允許最大 10MB body
spec:
  ingressClassName: nginx     # 指定用哪個 Ingress Controller
  rules:
    - host: myapp.local       # Host header 必須是 myapp.local 才匹配
      http:
        paths:
          - path: /
            pathType: Prefix  # 前綴匹配（/ 匹配所有路徑）
            backend:
              service:
                name: myapp   # 轉發到 Service "myapp"
                port:
                  number: 80  # Service 的 port（不是 Pod 的 8080）
```

**教學重點**：

- **Ingress vs Ingress Controller**：Ingress 只是規則（像 nginx.conf），Ingress Controller 是實際跑著的 nginx
- **host 欄位**：開發環境需要在 `/etc/hosts` 加上 `<Node IP> myapp.local`
- **pathType**：
  - `Prefix`：`/` 匹配所有路徑（`/api`、`/health` 都匹配）
  - `Exact`：`/api` 只匹配 `/api`，不匹配 `/api/v1`

---

### base/servicemonitor.yaml

> 告訴 Prometheus 去監控哪些 Service 的指標端點。

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: myapp
  namespace: myapp
  labels:
    release: monitoring    # ⚡ 必須跟 Helm release name 一致，否則 Prometheus 抓不到
spec:
  selector:
    matchLabels:
      app: myapp
  endpoints:
    - port: http
      path: /metrics
      interval: 15s
```

**教學重點**：

- **ServiceMonitor 不是 K8s 內建的**，需要先安裝 Prometheus Operator（CRD）
- **`release: monitoring` 是最常見的踩坑點**：Prometheus Operator 用 `serviceMonitorSelector` 篩選 ServiceMonitor，label 不對就抓不到
- **除錯順序**：
  1. ServiceMonitor 的 `release` label 對不對？
  2. ServiceMonitor 的 selector 能不能找到 Service？
  3. Service 的 selector 能不能找到 Pod？
  4. Pod 的 `/metrics` 端點有沒有回應？
  5. 到 Prometheus UI → Status → Targets 確認

---

### base/hpa.yaml

> 根據 CPU 使用率自動擴縮 Pod 數量。

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: myapp
  namespace: myapp
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: myapp
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

**教學重點**：

- **計算公式**：`期望副本數 = ceil(目前副本數 × 目前CPU% / 目標CPU%)`
  - 範例：2 個 Pod，平均 90% → `ceil(2 × 90/70)` = 3 個 Pod
- **averageUtilization 70% 的基準是 `requests.cpu`，不是 `limits.cpu`**
  - `requests.cpu = 50m`，70% = `35m`，超過就會擴容
- **HPA 會覆蓋 Deployment 的 replicas**，最終 Pod 數量由 HPA 控制
- **需要 Metrics Server**（infra repo 安裝），否則 HPA 無法取得指標
- **冷卻時間**：擴容幾乎立即，縮容預設等 5 分鐘（避免抖動）

---

### Secret 說明（不在本 repo 中）

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
> 密碼從 `.env` 讀取，只存在 K8s cluster 裡。ArgoCD 不管理這個 Secret（不在 kustomization.yaml 裡），不會覆蓋或刪掉它。

---

## 常見操作指令速查

### 查看資源狀態

```bash
kubectl get all -n myapp                          # 列出 myapp Namespace 所有資源
kubectl get pods -n myapp -o wide                 # 列出 Pod（含 Node 和 IP）
kubectl describe pod <pod-name> -n myapp          # 查看 Pod 詳細狀態
kubectl logs <pod-name> -n myapp                  # 查看 Pod 日誌
kubectl logs <pod-name> -n myapp -f               # 即時追蹤日誌（tail -f）
kubectl logs <pod-name> -n myapp --previous       # 查看上一個容器的日誌（crash 後用）
```

### 部署相關

```bash
kubectl rollout status deploy/myapp -n myapp      # 查看部署進度
kubectl rollout history deploy/myapp -n myapp     # 查看部署歷史
kubectl rollout undo deploy/myapp -n myapp        # 回滾到上一版
kubectl rollout restart deploy/myapp -n myapp     # 重啟所有 Pod（不改 image）
```

### 擴縮與 HPA

```bash
kubectl get hpa -n myapp                          # 查看 HPA 狀態（含 CPU% 和副本數）
kubectl top pods -n myapp                         # 查看 Pod 實際資源用量
kubectl scale deploy myapp --replicas=3 -n myapp  # 手動擴縮（HPA 會覆蓋回來）
```

### 除錯

```bash
kubectl exec -it <pod-name> -n myapp -- sh        # 進入 Pod 的 shell
kubectl port-forward svc/myapp 8080:80 -n myapp   # 把 Service 映射到本機 localhost:8080
kubectl get events -n myapp --sort-by=.metadata.creationTimestamp  # 查看事件（排程失敗、OOMKill 等）
```

### Kustomize

```bash
kustomize build base/                             # 預覽最終 YAML（不實際部署）
kubectl apply -k base/                            # 用 Kustomize 部署
kubectl diff -k base/                             # 比較 cluster 現況與本地 YAML 的差異
```

---

## 常見問題與除錯

### Pod 一直 CrashLoopBackOff

1. `kubectl logs <pod> -n myapp --previous` 看上一次 crash 的日誌
2. 通常原因：DB 連不上（Secret 沒建 / DSN 錯誤）、port 衝突、程式 panic

### HPA 顯示 `<unknown>/70%`

1. 確認 Metrics Server 有安裝且正常運作
2. `kubectl top pods -n myapp` 如果報錯，代表 Metrics Server 有問題
3. 確認 Deployment 有設定 `resources.requests.cpu`（HPA 需要這個來算百分比）

### Prometheus 抓不到指標

1. 檢查 ServiceMonitor 的 `release` label 是否跟 Prometheus Operator 的 Helm release name 一致
2. Prometheus UI → Status → Targets 確認 target 是否出現
3. `kubectl port-forward <pod> 8080:8080 -n myapp` 然後 `curl localhost:8080/metrics` 確認指標端點正常

### Ingress 不通

1. `kubectl get ingress -n myapp` 確認 ADDRESS 欄位有值
2. 確認 Ingress Controller 有安裝（`kubectl get pods -n ingress-nginx`）
3. 確認 DNS / `/etc/hosts` 設定正確
4. `kubectl describe ingress myapp -n myapp` 看有沒有錯誤事件
