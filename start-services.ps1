

Write-Host "Checking Kubernetes connection..."
kubectl cluster-info
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "Applying ArgoCD Master Application..."
kubectl apply -f argocd-master-staging.yml

Write-Host "Applying Staging Applications..."
kubectl apply -f staging/apps.yml

Write-Host "Waiting for pods to start (this may take a minute)..."
# Wait for some key deployments to be available
kubectl wait --for=condition=available deployment/grafana --timeout=60s
kubectl wait --for=condition=available deployment/uptime-kuma --timeout=60s

Write-Host "Setting up local access (Port-Forwarding)..."

# Stop any existing port-forwards
Get-Process | Where-Object { $_.ProcessName -eq "kubectl" } | Stop-Process -Force -ErrorAction SilentlyContinue

# Start new port-forwards in background
Start-Process kubectl -ArgumentList "port-forward svc/argocd-server -n argocd 8080:443" -WindowStyle Hidden
Start-Process kubectl -ArgumentList "port-forward svc/grafana 3005:3005" -WindowStyle Hidden
Start-Sleep -Seconds 2
Start-Process kubectl -ArgumentList "port-forward svc/uptime-kuma 3001:3001" -WindowStyle Hidden
Start-Process kubectl -ArgumentList "port-forward svc/prometheus 9091:9090" -WindowStyle Hidden

Write-Host "--------------------------------------------------"
Write-Host "SERVICES ARE NOW ACCESSIBLE LOCALLY:"
Write-Host "ArgoCD:      https://localhost:8080"
Write-Host "Grafana:     http://localhost:3005"
Write-Host "Uptime Kuma: http://localhost:3001"
Write-Host "Prometheus:  http://localhost:9091"

Write-Host "`nGetting ArgoCD admin password..."
$password = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}"
$decoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($password))
Write-Host "ArgoCD Password: $decoded"
Write-Host "--------------------------------------------------"
Write-Host "Note: Keep this terminal open or remember that port-forwards are running in the background."
