SHELL := /bin/bash
KIND_VERSION := 0.20.0
KUBECTL_VERSION := $(shell curl -L -s https://dl.k8s.io/release/stable.txt)
KUBE_PROMETHEUS_VERSION := release-0.13

.PHONY: all
all: prerequisites cluster setup-nvidia-runtime install-operators setup-monitoring port-forward

.PHONY: reinstall
reinstall: clean cluster setup-nvidia-runtime install-operators setup-monitoring port-forward

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

.PHONY: setup-nvidia-runtime
setup-nvidia-runtime:
	@echo "Setting up NVIDIA runtime in Kind node..."
	docker exec kind-control-plane apt-get update
	# Add NVIDIA repository and its GPG key
	docker exec kind-control-plane apt-get install -y curl gnupg
	docker exec kind-control-plane curl -s -L https://nvidia.github.io/nvidia-container-runtime/gpgkey | docker exec -i kind-control-plane apt-key add -
	docker exec kind-control-plane curl -s -L https://nvidia.github.io/nvidia-container-runtime/ubuntu20.04/nvidia-container-runtime.list | docker exec -i kind-control-plane tee /etc/apt/sources.list.d/nvidia-container-runtime.list
	docker exec kind-control-plane apt-get update
	# Install NVIDIA container runtime
	docker exec kind-control-plane apt-get install -y nvidia-container-runtime
	# Copy NVIDIA utilities and libraries
	chmod +x setup-nvidia-kind.sh
	./setup-nvidia-kind.sh
	# Configure containerd
	docker cp containerd-config.toml kind-control-plane:/etc/containerd/config.toml
	docker exec kind-control-plane systemctl restart containerd
	# Verify runtime setup
	docker exec kind-control-plane nvidia-container-cli info
	# Wait for containerd to be ready
	sleep 20

.PHONY: validate-nvidia-setup
validate-nvidia-setup:
	@echo "Validating NVIDIA setup in Kind container..."
	@echo "\nChecking NVIDIA devices:"
	@docker exec kind-control-plane ls -l /dev/nvidia*
	@echo "\nChecking NVIDIA driver utilities:"
	@docker exec kind-control-plane which nvidia-smi
	@docker exec kind-control-plane nvidia-smi
	@echo "\nChecking NVIDIA libraries:"
	@docker exec kind-control-plane ls -l /usr/lib/x86_64-linux-gnu/libnvidia*
	@echo "\nChecking container runtime:"
	@docker exec kind-control-plane nvidia-container-cli info

.PHONY: install-operators
install-operators:
	@echo "Installing GPU Operator..."
	helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
	helm repo update
	DRIVER_VERSION=$(shell nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
	helm install gpu-operator \
		nvidia/gpu-operator \
		--set driver.enabled=false \
		--set driver.version=$(DRIVER_VERSION) \
		--set toolkit.enabled=true \
		--set devicePlugin.enabled=true \
		--set migManager.enabled=false \
		--set operator.defaultRuntime=containerd \
		--set driver.rdma.enabled=false \
		--set mig.strategy=mixed \
		--set driver.useHostMounts=true \
		--set toolkit.version=v1.13.5 \
		--set containerRuntime.version=v1.13.5 \
		--set toolkit.repository=nvcr.io/nvidia/k8s \
		--set toolkit.name=container-toolkit \
		--set toolkit.tag=v1.13.5-ubuntu20.04 \
		--set toolkit.env[0].name=CONTAINERD_CONFIG \
		--set toolkit.env[0].value=/etc/containerd/config.toml \
		--set toolkit.env[1].name=CONTAINERD_SOCKET \
		--set toolkit.env[1].value=/run/containerd/containerd.sock \
		--set toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS \
		--set toolkit.env[2].value=nvidia \
		--set operator.validator.image.repository=nvcr.io/nvidia/cloud-native/gpu-operator-validator \
		--set operator.validator.image.tag=v24.9.0 \
		--namespace gpu-operator \
		--create-namespace

.PHONY: validate-gpu-operator
validate-gpu-operator:
	@echo "Waiting for GPU operator pods to be ready..."
	kubectl wait --for=condition=ready pods -l app=nvidia-device-plugin-daemonset -n gpu-operator --timeout=300s
	kubectl wait --for=condition=ready pods -l app=nvidia-container-toolkit-daemonset -n gpu-operator --timeout=300s
	kubectl wait --for=condition=ready pods -l app=nvidia-dcgm-exporter -n gpu-operator --timeout=300s
	@echo "Checking GPU operator logs..."
	kubectl logs -l app=gpu-operator -n gpu-operator

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
	rm -rf kube-prometheus/

.PHONY: verify
verify:
	@echo "Verifying installation..."
	kubectl get nodes
	kubectl get pods -n gpu-operator
	kubectl get pods -n monitoring
	@echo "Testing GPU availability..."
	kubectl run nvidia-smi --rm -it --restart=Never \
		--image=nvidia/cuda:12.2.0-base-ubuntu20.04 \
		--command -- nvidia-smi

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  all               - Complete setup (prerequisites, cluster, GPU operator, monitoring)"
	@echo "  prerequisites     - Install required tools (kubectl, kind, helm)"
	@echo "  cluster          - Create Kind cluster with GPU support"
	@echo "  setup-nvidia-runtime - Setup NVIDIA runtime in Kind node"
	@echo "  install-operators - Install GPU operator"
	@echo "  setup-monitoring - Setup Prometheus and DCGM monitoring"
	@echo "  port-forward     - Setup port forwarding for monitoring services"
	@echo "  clean            - Delete cluster and clean up"
	@echo "  verify           - Verify installation"
	@echo "  help             - Show this help message"

.PHONY: validate-toolkit
validate-toolkit:
	@echo "Validating NVIDIA Container Toolkit..."
	@docker exec kind-control-plane nvidia-container-cli info
	@docker exec kind-control-plane nvidia-container-runtime --version
	@echo "\nChecking toolkit pod status..."
	@kubectl get pods -n gpu-operator -l app=nvidia-container-toolkit-daemonset
	@kubectl describe pods -n gpu-operator -l app=nvidia-container-toolkit-daemonset

.PHONY: validate-runtime-setup
validate-runtime-setup:
	@echo "Validating runtime setup..."
	@docker exec kind-control-plane ls -l /usr/bin/nvidia-container-runtime
	@docker exec kind-control-plane ls -l /run/containerd/containerd.sock
	@docker exec kind-control-plane systemctl status containerd
	@docker exec kind-control-plane nvidia-container-cli info
