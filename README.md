# stockbot-long-backend-k8s-manifests

App 的 K8s 部署設定。ArgoCD 監聽這個 repo，每一筆 commit = 一次部署變更。

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

---

## 目錄結構

```
stockbot-long-backend-k8s-manifests/
└── base/
    ├── kustomization.yaml
    ├── namespace.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── servicemonitor.yaml
    └── hpa.yaml

# ⚠️ 沒有 secret.yaml
# DB 密碼不放在 Git 裡
# Secret 由 infra repo 的 install-all.sh 用指令建在 K8s 裡
```

---

## 各檔案說明

### base/namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: myapp
```

### base/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: myapp
spec:
  replicas: 1

  selector:
    matchLabels:
      app: myapp

  template:
    metadata:
      labels:
        app: myapp
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"

    spec:
      containers:
        - name: myapp
          image: ghcr.io/yourorg/stockbot-long-backend:latest

          ports:
            - name: http
              containerPort: 8080

          env:
            - name: DB_DSN
              valueFrom:
                secretKeyRef:
                  name: myapp-db    # Secret 由 infra repo 的 install-all.sh 建立
                  key: dsn

          livenessProbe:            # 失敗 → 重啟 Pod
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10

          readinessProbe:           # 失敗 → 移出流量名單
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10

          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 250m
              memory: 128Mi
```

### base/service.yaml

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
    app: myapp
  ports:
    - name: http
      port: 80
      targetPort: 8080
```

### base/ingress.yaml

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  namespace: myapp
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
spec:
  ingressClassName: nginx
  rules:
    - host: myapp.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  number: 80
```

### base/servicemonitor.yaml

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

### base/hpa.yaml

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
