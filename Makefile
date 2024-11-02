SHELL := /bin/bash
KIND_VERSION := 0.20.0
KUBECTL_VERSION := $(shell curl -L -s https://dl.k8s.io/release/stable.txt)
KUBE_PROMETHEUS_VERSION := release-0.13

.PHONY: all
all: prerequisites cluster setup-nvidia-runtime install-operators setup-monitoring port-forward

.PHONY: reinstall-all
reinstall-all: clean cluster setup-nvidia-runtime install-operators setup-monitoring port-forward

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
	$(MAKE) setup-nvidia-runtime
	$(MAKE) install-operators
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

.PHONY: setup-nvidia-runtime
setup-nvidia-runtime: verify-nvidia-library
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
	# Wait for containerd to be ready
	sleep 20
	# Now verify the setup
	$(MAKE) verify-setup
	$(MAKE) debug-all

.PHONY: verify-nvidia-setup
verify-nvidia-setup:
	@echo "=== Verifying NVIDIA Setup ==="
	@docker exec kind-control-plane bash -c '\
		echo "1. Library files:" && \
			ls -la /usr/lib/x86_64-linux-gnu/libnvidia-ml* && \
		echo "\n2. Library load test:" && \
			ldd /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.535.183.01 && \
		echo "\n3. NVIDIA SMI test:" && \
			nvidia-smi && \
		echo "\n4. Container CLI test:" && \
			nvidia-container-cli info'

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

.PHONY: verify-nvidia-library
verify-nvidia-library:
	@echo "=== Verifying Host Library ==="
	@if [ ! -f "/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.535.183.01" ]; then \
		echo "ERROR: Source library not found!"; \
		exit 1; \
	fi
	@ls -la /usr/lib/x86_64-linux-gnu/libnvidia-ml*

.PHONY: debug-logs
debug-logs:
	@echo "Debugging GPU operator..."
	./debug-gpu-operator.sh > gpu-operator-debug.log 2>&1

# Debug and Verification Targets
.PHONY: debug-all
debug-all: debug-libraries debug-runtime debug-containerd debug-operator debug-operator-init debug-containerd-config

.PHONY: debug-libraries
debug-libraries:
	@echo "=== Debugging NVIDIA Libraries ==="
	@docker exec kind-control-plane bash -c '\
		echo "1. Library files and symlinks:" && \
		ls -la /usr/lib/x86_64-linux-gnu/libnvidia* /usr/lib/x86_64-linux-gnu/libcuda* && \
		echo "\n2. Library dependencies:" && \
		for lib in libnvidia-ml.so.1 libcuda.so.1; do \
			echo "\nChecking $$lib:" && \
			ldd /usr/lib/x86_64-linux-gnu/$$lib; \
		done && \
		echo "\n3. ldconfig cache:" && \
		ldconfig -v | grep -E "nvidia|cuda"'

.PHONY: debug-runtime
debug-runtime:
	@echo "=== Debugging NVIDIA Runtime ==="
	@docker exec kind-control-plane bash -c '\
		echo "1. Runtime binaries:" && \
		ls -la /usr/bin/nvidia-* && \
		echo "\n2. Runtime config:" && \
		cat /etc/nvidia-container-runtime/config.toml && \
		echo "\n3. Runtime test:" && \
		nvidia-container-cli info && \
		echo "\n4. Runtime version:" && \
		nvidia-container-runtime --version && \
		echo "\n5. SMI test:" && \
		nvidia-smi'

.PHONY: debug-containerd
debug-containerd:
	@echo "=== Debugging Containerd Setup ==="
	@docker exec kind-control-plane bash -c '\
		echo "1. Containerd config:" && \
		cat /etc/containerd/config.toml | grep -A 10 nvidia && \
		echo "\n2. Containerd status:" && \
		systemctl status containerd && \
		echo "\n3. Runtime paths:" && \
		ls -la /usr/local/nvidia/toolkit/nvidia-container-runtime && \
		echo "\n4. Socket:" && \
		ls -la /run/containerd/containerd.sock'

.PHONY: debug-operator
debug-operator:
	@echo "=== Debugging GPU Operator ==="
	@echo "1. Pod status:"
	@kubectl get pods -n gpu-operator
	@echo "\n2. Device plugin logs:"
	@kubectl logs -l app=nvidia-device-plugin-daemonset -n gpu-operator --tail=50
	@echo "\n3. Container toolkit logs:"
	@kubectl logs -l app=nvidia-container-toolkit-daemonset -n gpu-operator --tail=50
	@echo "\n4. Operator logs:"
	@kubectl logs -l app=gpu-operator -n gpu-operator --tail=50

.PHONY: verify-setup
verify-setup:
	@echo "=== Verifying Complete Setup ==="
	@echo "1. Checking libraries..."
	@$(MAKE) -s verify-nvidia-library
	@echo "\n2. Checking runtime..."
	@$(MAKE) -s validate-runtime-setup

.PHONY: collect-logs
collect-logs:
	@echo "=== Collecting All Logs ==="
	@mkdir -p logs
	@echo "1. Collecting containerd logs..."
	@docker exec kind-control-plane journalctl -u containerd > logs/containerd.log
	@echo "2. Collecting NVIDIA runtime logs..."
	@docker exec kind-control-plane bash -c 'cat /var/log/nvidia-container-runtime-debug.log' > logs/nvidia-runtime.log 2>/dev/null || true
	@echo "3. Collecting GPU operator logs..."
	@kubectl logs -l app=gpu-operator -n gpu-operator > logs/gpu-operator.log 2>/dev/null || true
	@echo "4. Collecting device plugin logs..."
	@kubectl logs -l app=nvidia-device-plugin-daemonset -n gpu-operator > logs/device-plugin.log 2>/dev/null || true
	@echo "Logs collected in ./logs directory"

.PHONY: test-gpu
test-gpu:
	@echo "=== Testing GPU Access ==="
	@kubectl run nvidia-smi --rm -it --restart=Never \
		--image=nvidia/cuda:12.2.0-base-ubuntu20.04 \
		--command -- nvidia-smi || \
		(echo "GPU test failed. Running diagnostics..." && $(MAKE) debug-all)

.PHONY: debug-operator-init
debug-operator-init:
	@echo "=== Debugging GPU Operator Init Containers ==="
	@echo "1. Checking toolkit init container:"
	@kubectl logs -n gpu-operator -l app=nvidia-container-toolkit-daemonset -c toolkit-validation || true
	
	@echo "\n2. Checking device plugin init container:"
	@kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset -c toolkit-validation || true
	
	@echo "\n3. Checking DCGM init container:"
	@kubectl logs -n gpu-operator -l app=nvidia-dcgm-exporter -c toolkit-validation || true
	
	@echo "\n4. Checking validator init containers:"
	@kubectl logs -n gpu-operator -l app=nvidia-operator-validator -c driver-validation || true
	@kubectl logs -n gpu-operator -l app=nvidia-operator-validator -c toolkit-validation || true
	
	@echo "\n5. Checking pod descriptions:"
	@echo "\nToolkit pod:"
	@kubectl describe pod -n gpu-operator -l app=nvidia-container-toolkit-daemonset
	@echo "\nDevice plugin pod:"
	@kubectl describe pod -n gpu-operator -l app=nvidia-device-plugin-daemonset
	@echo "\nDCGM pod:"
	@kubectl describe pod -n gpu-operator -l app=nvidia-dcgm-exporter
	@echo "\nValidator pod:"
	@kubectl describe pod -n gpu-operator -l app=nvidia-operator-validator

.PHONY: debug-containerd-config
debug-containerd-config:
	@echo "=== Debugging Containerd Configuration ==="
	@docker exec kind-control-plane bash -c '\
		echo "1. Current containerd config:" && \
		cat /etc/containerd/config.toml && \
		echo "\n2. Runtime handler status:" && \
		ctr runtime list && \
		echo "\n3. Checking NVIDIA runtime:" && \
		ls -l /usr/local/nvidia/toolkit/nvidia-container-runtime && \
		echo "\n4. Runtime socket:" && \
		ls -l /run/containerd/containerd.sock && \
		echo "\n5. Containerd service status:" && \
		systemctl status containerd'

.PHONY: fix-operator-init
fix-operator-init:
	@echo "=== Fixing GPU Operator Init Issues ==="
	@echo "1. Verifying NVIDIA runtime setup..."
	@docker exec kind-control-plane nvidia-container-cli info || \
		(echo "NVIDIA runtime not working, attempting fix..." && \
		docker exec kind-control-plane bash -c '\
			chmod 755 /usr/local/nvidia/toolkit/nvidia-container-runtime && \
			systemctl restart containerd && \
			sleep 5')
	
	@echo "\n2. Restarting stuck pods..."
	@kubectl delete pod -n gpu-operator -l app=nvidia-container-toolkit-daemonset
	@kubectl delete pod -n gpu-operator -l app=nvidia-device-plugin-daemonset
	@kubectl delete pod -n gpu-operator -l app=nvidia-dcgm-exporter
	@kubectl delete pod -n gpu-operator -l app=nvidia-operator-validator
	
	@echo "\n3. Waiting for pods to restart..."
	@sleep 30
	
	@echo "\n4. New pod status:"
	@kubectl get pods -n gpu-operator

.PHONY: fix-nvidia-stack
fix-nvidia-stack:
	@echo "=== Fixing NVIDIA Container Stack ==="
	@echo "1. Copying runtime configurations..."
	@docker cp nvidia-container-runtime.toml kind-control-plane:/etc/nvidia-container-runtime/config.toml
	@docker cp containerd-config.toml kind-control-plane:/etc/containerd/config.toml

	@echo "2. Verifying NVIDIA runtime setup..."
	@docker exec kind-control-plane bash -c 'chmod 755 /usr/local/nvidia/toolkit/nvidia-container-runtime && \
		ls -la /usr/local/nvidia/toolkit/nvidia-container-runtime && \
		nvidia-container-cli info'

	@echo "3. Restarting containerd..."
	@docker exec kind-control-plane systemctl restart containerd
	@sleep 10

	@echo "4. Restarting GPU operator pods..."
	-kubectl delete pod -n gpu-operator --all
	@sleep 30

	@echo "5. Checking new pod status..."
	@kubectl get pods -n gpu-operator

.PHONY: verify-nvidia-stack
verify-nvidia-stack:
	@echo "=== Verifying NVIDIA Stack ==="
	@echo "1. Checking runtime binary..."
	@docker exec kind-control-plane ls -la /usr/local/nvidia/toolkit/nvidia-container-runtime
	
	@echo "\n2. Checking runtime config..."
	@docker exec kind-control-plane cat /etc/nvidia-container-runtime/config.toml
	
	@echo "\n3. Checking containerd config..."
	@docker exec kind-control-plane cat /etc/containerd/config.toml
	
	@echo "\n4. Testing NVIDIA runtime..."
	@docker exec kind-control-plane nvidia-container-cli info
	
	@echo "\n5. Checking GPU operator pods..."
	@kubectl get pods -n gpu-operator

.PHONY: debug-toolkit-validation
debug-toolkit-validation:
	@echo "=== Debugging Toolkit Validation ==="
	@echo "1. Checking toolkit pod logs..."
	@kubectl logs -n gpu-operator -l app=nvidia-container-toolkit-daemonset --all-containers --prefix || true
	
	@echo "\n2. Checking toolkit pod events..."
	@kubectl describe pod -n gpu-operator -l app=nvidia-container-toolkit-daemonset | grep -A 20 Events:
	
	@echo "\n3. Checking runtime on node..."
	@docker exec kind-control-plane bash -c '\
		nvidia-container-cli info && \
		nvidia-container-runtime --version'
