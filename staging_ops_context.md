# Devix Platform — Staging-Ops Context Document

Use this document as context when setting up the `staging-ops` repository for Kubernetes + ArgoCD deployment.

---

## 1. Architecture Overview

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  React Native   │────▶│  devix-backend   │────▶│   PostgreSQL    │
│  Expo Router    │     │  (Go / Gin)      │     │   (Primary DB)  │
│  Mobile App     │◀────│  Port: 8080      │     └─────────────────┘
└─────────────────┘     │                  │     ┌─────────────────┐
                        │  WebSocket: /ws  │────▶│     Redis       │
                        │                  │     │  (Cache + PubSub│
                        └──────────────────┘     │   + Rate Limit) │
                                │                └─────────────────┘
                                │                ┌─────────────────┐
                                └───────────────▶│  Elasticsearch  │
                                                 │  (Full-text     │
                                                 │   Search)       │
                                                 └─────────────────┘
                                │                ┌─────────────────┐
                                └───────────────▶│  Cloudflare R2  │
                                                 │  (Media/CDN)    │
                                                 └─────────────────┘
```

---

## 2. Services Required in Kubernetes

### 2.1. devix-backend (Deployment)
- **Image**: Built from `devix-backend` repo (needs Dockerfile)
- **Port**: `8080`
- **Protocol**: HTTP + WebSocket (`/ws`)
- **Replicas**: 2+ (stateless, horizontally scalable)
- **Health Check**: `GET /health` → `{"status": "ok"}`
- **Readiness**: Same endpoint
- **Resource Requests**: CPU: 100m, Memory: 128Mi
- **Resource Limits**: CPU: 500m, Memory: 512Mi

### 2.2. PostgreSQL (StatefulSet)
- **Image**: `postgres:16-alpine`
- **Port**: `5432`
- **Storage**: PersistentVolumeClaim (10Gi minimum)
- **Databases**: `devix_dev`, `devix_staging`, `devix_prod`

### 2.3. Redis (Deployment or StatefulSet)
- **Image**: `redis:7-alpine`
- **Port**: `6379`
- **Storage**: Optional PVC for persistence
- **Used for**: Caching, WebSocket Pub/Sub, Rate Limiting, Abuse Detection, Background Jobs

### 2.4. Elasticsearch (StatefulSet)
- **Image**: `docker.elastic.co/elasticsearch/elasticsearch:8.11.1`
- **Port**: `9200`
- **Storage**: PersistentVolumeClaim (10Gi minimum)
- **Env**: `discovery.type=single-node`, `xpack.security.enabled=false` (for staging)
- **Used for**: Full-text post search with fuzzy matching

---

## 3. Environment Variables

The backend reads all config from environment variables. Here is the complete list:

```yaml
# Server
SERVER_PORT: "8080"
SERVER_ENV: "staging"  # development | staging | production

# Database (REQUIRED)
DATABASE_URL: "postgres://user:pass@postgres:5432/devix_staging?sslmode=disable"

# Redis (OPTIONAL — falls back gracefully)
REDIS_URL: "redis://redis:6379"
REDIS_PASSWORD: ""
REDIS_DB: "0"

# Elasticsearch (OPTIONAL — falls back to DB search)
ELASTICSEARCH_URL: "http://elasticsearch:9200"

# JWT (REQUIRED — minimum 32 characters)
JWT_ACCESS_SECRET: "<random-32-char-string>"
JWT_REFRESH_SECRET: "<different-random-32-char-string>"
JWT_ACCESS_EXPIRY: "15m"
JWT_REFRESH_EXPIRY: "168h"

# Media Storage
STORAGE_TYPE: "r2"  # "local" or "r2"
UPLOAD_DIR: "./uploads"

# Cloudflare R2 (Required if STORAGE_TYPE=r2)
R2_ACCOUNT_ID: ""
R2_ACCESS_KEY: ""
R2_SECRET_KEY: ""
R2_BUCKET_NAME: ""
R2_PUBLIC_URL: ""
R2_CDN_URL: ""        # Optional: custom domain for CDN delivery
R2_ENDPOINT: ""

# CORS
CORS_ORIGINS: "http://localhost:3000,https://devix.app"

# Rate Limiting
RATE_LIMIT_REQUESTS: "100"
RATE_LIMIT_WINDOW: "1m"
AUTH_RATE_LIMIT_REQUESTS: "5"
AUTH_RATE_LIMIT_WINDOW: "1m"
```

---

## 4. Dockerfile (Multi-Stage Build)

Place this in the root of `devix-backend`:

```dockerfile
# Stage 1: Build
FROM golang:1.22-alpine AS builder
RUN apk add --no-cache git
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /devix-backend ./cmd/server

# Stage 2: Production
FROM alpine:3.19
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=builder /devix-backend .
EXPOSE 8080
CMD ["./devix-backend"]
```

---

## 5. Kubernetes Manifests Structure

Recommended layout for `staging-ops` repo:

```
staging-ops/
├── base/
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── devix-backend/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   ├── hpa.yaml
│   │   └── ingress.yaml
│   ├── postgres/
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   ├── pvc.yaml
│   │   └── configmap.yaml
│   ├── redis/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   └── elasticsearch/
│       ├── statefulset.yaml
│       ├── service.yaml
│       └── pvc.yaml
├── overlays/
│   ├── staging/
│   │   ├── kustomization.yaml
│   │   ├── secrets.yaml          # Sealed/SOPS encrypted
│   │   └── patches/
│   │       └── replicas.yaml
│   └── production/
│       ├── kustomization.yaml
│       ├── secrets.yaml
│       └── patches/
│           ├── replicas.yaml
│           └── resources.yaml
├── argocd/
│   ├── application-staging.yaml
│   └── application-production.yaml
└── README.md
```

---

## 6. ArgoCD Application Manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: devix-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<your-username>/staging-ops.git
    targetRevision: main
    path: overlays/staging
  destination:
    server: https://kubernetes.default.svc
    namespace: devix-staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

## 7. CI/CD Pipeline (GitHub Actions)

In the `devix-backend` repo, create `.github/workflows/deploy.yml`:

```yaml
name: Build & Push
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Login to GHCR
        run: echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin
      - name: Build & Push
        run: |
          docker build -t ghcr.io/${{ github.repository }}:${{ github.sha }} .
          docker build -t ghcr.io/${{ github.repository }}:latest .
          docker push ghcr.io/${{ github.repository }}:${{ github.sha }}
          docker push ghcr.io/${{ github.repository }}:latest
      - name: Update staging-ops
        run: |
          # Use kustomize edit or sed to update image tag in staging-ops repo
          # ArgoCD will auto-sync from there
```

---

## 8. API Endpoints Summary

### Auth
- `POST /api/v1/auth/signup` — Register
- `POST /api/v1/auth/login` — Login
- `POST /api/v1/auth/refresh` — Refresh tokens
- `POST /api/v1/auth/logout` — Logout

### Users
- `GET /api/v1/users/:username` — Public profile
- `GET /api/v1/users/me` — Current user (auth)
- `PUT /api/v1/users/me` — Update profile (auth)
- `PUT /api/v1/users/me/avatar` — Upload avatar (auth)
- `PUT /api/v1/users/me/settings` — Update settings (auth)

### Posts
- `GET /api/v1/posts` — List posts
- `GET /api/v1/posts/:id` — Get post by slug
- `POST /api/v1/posts` — Create post (auth)
- `PUT /api/v1/posts/:id` — Update post (auth)
- `DELETE /api/v1/posts/:id` — Delete post (auth)
- `POST /api/v1/posts/:id/media` — Upload media (auth)

### Feed
- `GET /api/v1/feed` — Main feed (optional auth for personalization)
- `GET /api/v1/feed/following` — Following feed (auth)
- `GET /api/v1/feed/explore` — Explore/discover feed (optional auth)

### Comments
- `GET /api/v1/posts/:id/comments` — Get comments
- `POST /api/v1/posts/:id/comments` — Create comment (auth)
- `PUT /api/v1/comments/:id` — Edit comment (auth)
- `DELETE /api/v1/comments/:id` — Delete comment (auth)

### Tags
- `GET /api/v1/tags` — All tags
- `GET /api/v1/tags/trending` — Trending tags

### Votes
- `POST /api/v1/posts/:id/vote` — Vote on post (auth)
- `POST /api/v1/comments/:id/vote` — Vote on comment (auth)

### Bookmarks
- `GET /api/v1/bookmarks` — List bookmarks (auth)
- `POST /api/v1/posts/:id/bookmark` — Toggle bookmark (auth)

### Follow
- `POST /api/v1/users/:id/follow` — Follow user (auth)
- `DELETE /api/v1/users/:id/follow` — Unfollow user (auth)
- `GET /api/v1/users/:id/followers` — Get followers
- `GET /api/v1/users/:id/following` — Get following

### Notifications
- `GET /api/v1/notifications` — List notifications (auth)
- `PUT /api/v1/notifications/:id/read` — Mark as read (auth)
- `PUT /api/v1/notifications/read-all` — Mark all as read (auth)

### WebSocket
- `GET /ws` — WebSocket connection (auth via JWT)
  - Client sends: `join_room`, `leave_room`, `typing`
  - Server pushes: `new_notification`, `new_comment`, `typing`

### Health
- `GET /health` — Health check

---

## 9. Key Technical Details

- **Language**: Go 1.22+
- **Framework**: Gin (HTTP) + Gorilla (WebSocket)
- **ORM**: GORM v2
- **Auth**: JWT (Access + Refresh tokens)
- **Search**: Elasticsearch 8.x with fuzzy matching
- **Cache**: Redis with cache-aside pattern (15-30 min TTLs)
- **Real-time**: WebSocket Hub with Redis Pub/Sub for multi-instance sync
- **Background Jobs**: In-process worker queue (3 workers)
- **Media**: Cloudflare R2 (S3-compatible) with optional CDN
- **Rate Limiting**: Redis sliding window counters
- **Security**: CSP headers, HSTS, abuse detection, login lockout
