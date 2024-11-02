SHELL := /bin/bash
KIND_VERSION := 0.20.0
KUBECTL_VERSION := $(shell curl -L -s https://dl.k8s.io/release/stable.txt)

.PHONY: all
all: prerequisites cluster setup-nvidia install-gpu-operator test-gpu

.PHONY: reinstall-all
reinstall-all: clean cluster setup-nvidia install-gpu-operator setup-monitoring port-forward


.PHONY: reinstall-nvidia-runtime
reinstall-nvidia-runtime:
	@echo "Reinstalling NVIDIA runtime..."
	-helm uninstall -n gpu-operator gpu-operator
	-kubectl delete namespace gpu-operator
	@echo "Waiting for namespace deletion..."
	-kubectl wait --for=delete namespace/gpu-operator --timeout=60s
	@echo "Recreating cluster and setting up NVIDIA runtime..."
	$(MAKE) clean
	$(MAKE) cluster
	$(MAKE) setup-nvidia
	$(MAKE) install-gpu-operator
	@echo "NVIDIA runtime reinstallation complete"

.PHONY: prerequisites
prerequisites:
	@echo "Installing prerequisites..."
	# Install Go
	sudo apt-get update && sudo apt-get install -y golang-go
	# Install kubectl
	curl -LO "https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/linux/amd64/kubectl"
	chmod +x kubectl
	sudo mv kubectl /usr/local/bin/
	# Install Kind
	curl -Lo ./kind https://kind.sigs.k8s.io/dl/v$(KIND_VERSION)/kind-linux-amd64
	chmod +x ./kind
	sudo mv ./kind /usr/local/bin/kind
	# Install Helm
	curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

.PHONY: cluster
cluster:
	@echo "Creating Kind cluster with GPU support..."
	kind create cluster --config kind-config.yaml
	kubectl cluster-info

.PHONY: setup-nvidia
setup-nvidia:
	@echo "Setting up NVIDIA support..."
	chmod +x setup-nvidia-kind.sh
	./setup-nvidia-kind.sh

.PHONY: install-gpu-operator
install-gpu-operator:
	@echo "Installing GPU Operator..."
	helm repo add nvidia https://helm.ngc.nvidia.com/nvidia || true
	helm repo update
	helm install gpu-operator nvidia/gpu-operator \
		--namespace gpu-operator --create-namespace \
		--set driver.enabled=false \
		--set toolkit.enabled=true \
		--set devicePlugin.enabled=true \
		--set migManager.enabled=false \
		--set driver.useHostMounts=true \
		--set toolkit.version=v1.15.0-ubuntu20.04 \
		--set devicePlugin.version=v0.14.3-ubuntu20.04

.PHONY: test-gpu
test-gpu:
	@echo "=== Testing GPU Access ==="
	-kubectl delete pod nvidia-smi --ignore-not-found
	kubectl run nvidia-smi --restart=Never \
		--image=nvidia/cuda:12.3.1-base-ubuntu22.04 \
		--command -- nvidia-smi
	sleep 5
	kubectl logs nvidia-smi

.PHONY: setup-monitoring
setup-monitoring:
	@echo "Setting up monitoring..."
	# Install kube-prometheus-stack
	git clone --depth 1 -b $(KUBE_PROMETHEUS_VERSION) https://github.com/prometheus-operator/kube-prometheus.git
	kubectl create -f kube-prometheus/manifests/setup
	kubectl wait --for condition=Established --all CustomResourceDefinition --namespace=monitoring
	kubectl create -f kube-prometheus/manifests/
	# Setup DCGM monitoring
	kubectl apply -f prometheus-dcgm.yaml
	kubectl apply -f dcgm-servicemonitor.yaml

.PHONY: port-forward
port-forward:
	@echo "Setting up port forwards for monitoring services..."
	# Wait for pods to be ready
	kubectl wait --namespace monitoring --for=condition=Ready pods -l app.kubernetes.io/name=grafana --timeout=300s
	kubectl wait --namespace monitoring --for=condition=Ready pods -l app.kubernetes.io/name=prometheus --timeout=300s
	kubectl wait --namespace monitoring --for=condition=Ready pods -l app.kubernetes.io/name=alertmanager --timeout=300s
	
	# Start port forwarding
	kubectl --namespace monitoring port-forward svc/prometheus-k8s 9090:9090 --address 0.0.0.0 &
	kubectl --namespace monitoring port-forward svc/grafana 3000:3000 --address 0.0.0.0 &
	kubectl --namespace monitoring port-forward svc/alertmanager-main 9093:9093 --address 0.0.0.0 &
	
	# Verify port forwards are running
	@echo "Verifying port forwards..."
	@sleep 5
	@netstat -tlpn | grep 9090 || (echo "Prometheus port forward failed" && exit 1)
	@netstat -tlpn | grep 3000 || (echo "Grafana port forward failed" && exit 1)
	@netstat -tlpn | grep 9093 || (echo "Alertmanager port forward failed" && exit 1)
	@echo "Port forwards successfully established"

.PHONY: clean
clean:
	@echo "Cleaning up..."
	kind delete cluster || true

.PHONY: debug
debug:
	@echo "=== Debug Information ==="
	kubectl get pods -n gpu-operator
	kubectl describe pods -n gpu-operator
	kubectl logs -n gpu-operator -l app=gpu-operator
	docker exec kind-control-plane nvidia-container-cli info

.PHONY: debug-logs
debug-logs:
	@echo "Debugging GPU operator..."
	./debug-gpu-operator.sh > gpu-operator-debug.log 2>&1
	
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  all                - Complete setup"
	@echo "  prerequisites      - Install required tools"
	@echo "  cluster           - Create Kind cluster"
	@echo "  setup-nvidia      - Setup NVIDIA support"
	@echo "  install-gpu-operator - Install GPU operator"
	@echo "  test-gpu          - Test GPU access"
	@echo "  clean             - Delete cluster"
	@echo "  debug             - Show debug information"
