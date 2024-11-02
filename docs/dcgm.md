# DCGM Monitoring Setup Guide

## Overview
This guide explains the setup of NVIDIA DCGM (Data Center GPU Manager) monitoring in Kubernetes using Prometheus and visualization using Grafana.

## DCGM ServiceMonitor Configuration

### ServiceMonitor Specification
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dcgm-exporter
  namespace: monitoring
```
Creates a ServiceMonitor in the monitoring namespace.

### Endpoint Configuration
```yaml
endpoints:
  - port: gpu-metrics
    path: /metrics
```
- Specifies the metrics endpoint
- Uses the standard `/metrics` path
- Targets the `gpu-metrics` port

### Namespace Selection
```yaml
namespaceSelector:
  matchNames:
    - gpu-operator
```
Monitors services in the `gpu-operator` namespace.

### Service Selection
```yaml
selector:
  matchLabels:
    app: nvidia-dcgm-exporter
```
Selects services labeled with `app: nvidia-dcgm-exporter`.

## Prometheus RBAC Configuration

### Role Definition
```yaml
kind: Role
metadata:
  name: prometheus-dcgm
  namespace: gpu-operator
```
Creates a role in the `gpu-operator` namespace.

### Permissions
The role grants the following permissions:

1. **Core Resources**
   ```yaml
   - apiGroups: [""]
     resources: ["services", "endpoints", "pods"]
     verbs: ["get", "list", "watch"]
   ```
   Allows discovery of monitoring targets.

2. **ConfigMap Access**
   ```yaml
   - apiGroups: [""]
     resources: ["configmaps"]
     verbs: ["get"]
   ```
   Enables configuration access.

3. **ServiceMonitor Access**
   ```yaml
   - apiGroups: ["monitoring.coreos.com"]
     resources: ["servicemonitors"]
     verbs: ["get", "list", "watch"]
   ```
   Permits ServiceMonitor management.

### Role Binding
```yaml
subjects:
- kind: ServiceAccount
  name: prometheus-k8s
  namespace: monitoring
```
Binds the role to Prometheus service account.

## Metrics Collection Flow

1. **DCGM Exporter**
   - Collects GPU metrics
   - Exposes metrics on specified port
   - Labels metrics with GPU information

2. **ServiceMonitor**
   - Discovers DCGM exporter service
   - Configures scrape settings
   - Manages metric collection interval

3. **Prometheus**
   - Uses RBAC permissions to access metrics
   - Scrapes metrics from DCGM exporter
   - Stores metrics in time-series database

## NVIDIA DCGM Dashboard Setup

### Importing Dashboard
1. Access Grafana UI (default: http://localhost:3000)
2. Log in with your credentials (default: admin/admin)
3. Click on the "+" icon in the left sidebar
4. Select "Import"
5. Upload the dashboard JSON file from `./dashboards/12239_rev2.json`
   - Or copy and paste the JSON content
6. Select the Prometheus data source
7. Click "Import"

### Available Metrics and Panels
The DCGM dashboard provides visualizations for:
- GPU Temperature
  - Real-time temperature graphs
  - Average temperature gauge
- Power Usage
  - Per-GPU power consumption
  - Total power consumption gauge
- GPU Performance
  - SM Clock frequencies
  - GPU Utilization
  - Tensor Core Utilization
- Memory Usage
  - Framebuffer memory usage

### Dashboard Features
- Auto-refresh options (5s to 1d intervals)
- GPU instance selection
- Time range selection
- Dark theme optimized
- Professional gauge visualizations
- Detailed tooltips

## Available Metrics
DCGM exporter provides metrics including:
- GPU utilization
- Memory usage
- Power consumption
- Temperature
- Error counts
- Process statistics

## Integration with Grafana
- Metrics are available in Prometheus
- Pre-configured dashboard available
- Custom dashboards can be created for specific monitoring needs
- Supports alerting based on GPU metrics
