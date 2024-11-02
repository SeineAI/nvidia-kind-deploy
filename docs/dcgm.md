# DCGM Monitoring Setup Guide

## Overview
This guide explains the setup of NVIDIA DCGM (Data Center GPU Manager) monitoring in Kubernetes using Prometheus.

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
- Can be visualized using Grafana dashboards
- Custom dashboards can be created for specific monitoring needs
