#!/bin/bash

echo "=== GPU Operator Pod Status ==="
kubectl get pods -n gpu-operator -o wide

echo -e "\n=== Node Status ==="
kubectl get nodes -o wide

echo -e "\n=== Node GPU Labels ==="
kubectl get nodes --show-labels | grep nvidia

echo -e "\n=== Validator Pod Logs ==="
kubectl logs -n gpu-operator $(kubectl get pods -n gpu-operator -l app=nvidia-operator-validator -o name) --all-containers --prefix || true

echo -e "\n=== GPU Feature Discovery Logs ==="
kubectl logs -n gpu-operator $(kubectl get pods -n gpu-operator -l app=gpu-feature-discovery -o name) --all-containers --prefix || true

echo -e "\n=== Device Plugin Logs ==="
kubectl logs -n gpu-operator $(kubectl get pods -n gpu-operator -l app=nvidia-device-plugin-daemonset -o name) --all-containers --prefix || true

echo -e "\n=== Container Toolkit Logs ==="
kubectl logs -n gpu-operator $(kubectl get pods -n gpu-operator -l app=nvidia-container-toolkit-daemonset -o name) --all-containers --prefix || true

echo -e "\n=== DCGM Exporter Logs ==="
kubectl logs -n gpu-operator $(kubectl get pods -n gpu-operator -l app=nvidia-dcgm-exporter -o name) --all-containers --prefix || true

echo -e "\n=== Kind Container GPU Setup ==="
docker exec kind-control-plane bash -c '
echo "=== nvidia-smi ==="
nvidia-smi
echo -e "\n=== NVIDIA Libraries ==="
ls -l /usr/lib/x86_64-linux-gnu/libnvidia*
echo -e "\n=== ldconfig Cache ==="
ldconfig -p | grep nvidia
echo -e "\n=== Container Runtime Config ==="
cat /etc/nvidia-container-runtime/config.toml
echo -e "\n=== Containerd Config ==="
cat /etc/containerd/config.toml
'

echo -e "\n=== Containerd Status ==="
docker exec kind-control-plane systemctl status containerd

echo -e "\n=== Runtime Debug Logs ==="
docker exec kind-control-plane bash -c '
echo "=== Runtime Debug Log ==="
cat /var/log/nvidia-container-runtime-debug.log || true
echo -e "\n=== CLI Debug Log ==="
cat /var/log/nvidia-container-cli-debug.log || true
echo -e "\n=== Runtime Log ==="
cat /var/log/nvidia-container-runtime.log || true
' 