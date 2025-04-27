# Setting up Kind Cluster with NVIDIA GPU Support: Makefile Guide

## Overview
This guide explains how to use the Makefile to set up a Kind (Kubernetes in Docker) cluster with NVIDIA GPU support, including monitoring capabilities.

For detailed configuration information, please refer to:
- [NVIDIA and Kind Configuration Guide](docs/nvidia-kind.md)
- [DCGM Monitoring Setup Guide](docs/dcgm.md)

## Prerequisites
The Makefile automatically installs the following requirements:
- Go
- kubectl (latest stable version)
- Kind (v0.20.0)
- Helm

## Main Targets

### Complete Setup
```bash
make all
```
This runs the complete setup process in the following order:
1. Installs prerequisites
2. Creates Kind cluster
3. Sets up NVIDIA support
4. Installs GPU operator
5. Tests GPU access
6. Sets up monitoring
7. Configures port forwarding

### Individual Steps

#### 1. Install Prerequisites
```bash
make prerequisites
```
Installs all required tools and dependencies.

#### 2. Create Cluster
```bash
make cluster
```
Creates a Kind cluster using the configuration from `kind-config.yaml`. For detailed configuration information, see the [NVIDIA and Kind Configuration Guide](docs/nvidia-kind.md).

You can use different kind configuration files by setting the `KIND_CONFIG` environment variable:
```bash
# Use default config (kind-config.yaml)
make cluster

# Use 8 GPU configuration
KIND_CONFIG=kind-config-8GPU.yaml make cluster

# Use mount configuration
KIND_CONFIG=kind-config-mnt.yaml make cluster
```

Available configuration files:
- `kind-config.yaml`: Default configuration with basic GPU support
- `kind-config-8GPU.yaml`: Configuration for systems with 8 GPUs
- `kind-config-mnt.yaml`: Configuration with additional mount points for models, data, templates, and requests

#### 3. Setup NVIDIA Support
```bash
make setup-nvidia
```
Runs the `setup-nvidia-kind.sh` script to configure NVIDIA container support. See the [NVIDIA and Kind Configuration Guide](docs/nvidia-kind.md) for detailed explanation of the setup process.

#### 4. Install GPU Operator
```bash
make install-gpu-operator
```
Installs the NVIDIA GPU operator with the following configurations:
- Driver disabled (uses host driver)
- Toolkit enabled
- Device plugin enabled
- MIG manager disabled
- Host mounts enabled
- Specific toolkit and device plugin versions

#### 5. Test GPU Access
```bash
make test-gpu
```
Runs a test pod with `nvidia-smi` to verify GPU access.

#### 6. Setup Monitoring
```bash
make setup-monitoring
```
Sets up monitoring stack:
- Installs kube-prometheus-stack
- Configures DCGM monitoring
- Sets up custom service monitors

For detailed information about DCGM monitoring setup, refer to the [DCGM Monitoring Setup Guide](docs/dcgm.md).

#### 7. Port Forwarding
```bash
make port-forward
```
Sets up port forwarding for monitoring services:
- Prometheus: `9090`
- Grafana: `3000`
- Alertmanager: `9093`

### Maintenance Commands

#### Clean Up
```bash
make clean
```
Deletes the Kind cluster.

#### Debug
```bash
make debug
```
Shows debug information including:
- Pod status in gpu-operator namespace
- Pod descriptions
- GPU operator logs
- NVIDIA container information

#### Reinstall NVIDIA Runtime
```bash
make reinstall-nvidia-runtime
```
Completely reinstalls the NVIDIA runtime:
1. Uninstalls GPU operator
2. Deletes gpu-operator namespace
3. Recreates cluster
4. Reinstalls NVIDIA support
5. Reinstalls GPU operator

## Common Issues and Troubleshooting

1. If port forwarding fails:
   - Check if ports are already in use
   - Verify the services are running in the monitoring namespace

2. If GPU operator installation fails:
   - Use `make debug` to check the operator logs
   - Verify NVIDIA driver compatibility
   - Check if all required mounts are properly configured
   - See [NVIDIA and Kind Configuration Guide](docs/nvidia-kind.md) for proper setup requirements

3. If monitoring setup fails:
   - Ensure CustomResourceDefinitions are properly established
   - Check if the prometheus-operator is running
   - Verify RBAC permissions are correctly configured
   - Refer to [DCGM Monitoring Setup Guide](docs/dcgm.md) for detailed monitoring configuration
