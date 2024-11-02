# Configuration Guide: Kind and NVIDIA Setup

## Kind Configuration (kind-config.yaml)

### Overview
The Kind configuration file defines the cluster setup with specific focus on NVIDIA GPU support.

### Key Components

#### Node Configuration
```yaml
nodes:
- role: control-plane
```
Defines a single-node cluster with control-plane role.

#### GPU Device Mounts
The following device mounts are essential for GPU support:
- `/dev/nvidia0`, `/dev/nvidia1`: Individual GPU devices
- `/dev/nvidia-uvm`, `/dev/nvidia-uvm-tools`: GPU driver user-mode components
- `/dev/nvidiactl`: GPU control device
- `/dev/nvidia-modeset`: Display driver component
- `/dev/nvidia-caps`: GPU capabilities

#### NVIDIA Binary Mounts
Critical NVIDIA binaries mounted from host:
- `nvidia-smi`: GPU monitoring and management
- `nvidia-debugdump`: Debugging tool
- `nvidia-persistenced`: Persistence daemon

#### Library Mounts
Essential NVIDIA libraries mounted from host:
- `libnvidia-ml.so`: NVIDIA Management Library
- `libcuda.so`: CUDA Runtime
- `libnvidia-ptxjitcompiler.so`: PTX JIT Compiler
- `libnvidia-fatbinaryloader.so`: Fat Binary Loader

#### Port Mappings
Configures port forwarding for services:
- 30000-30002: Reserved for custom services

#### Kubelet Configuration
```yaml
nodeRegistration:
  kubeletExtraArgs:
    node-labels: "nvidia.com/gpu=true"
```
Labels the node for GPU support.

## NVIDIA Setup Script (setup-nvidia-kind.sh)

### Overview
This script configures NVIDIA container support within the Kind cluster.

### Setup Process

1. **Package Installation**
   ```bash
   apt-get install curl gnupg libc-bin pciutils psmisc apt-utils
   ```
   Installs required system packages.

2. **NVIDIA Container Toolkit**
   - Adds NVIDIA repository
   - Installs nvidia-container-toolkit
   - Sets up GPG keys for secure package installation

3. **Directory Structure**
   Creates required directories:
   - `/usr/lib64`
   - `/usr/local/nvidia/lib64`
   - `/usr/local/nvidia/bin`
   - `/usr/lib/nvidia`
   - `/usr/local/nvidia/toolkit`

4. **Library Configuration**
   - Creates symbolic links for NVIDIA libraries
   - Updates library cache with `ldconfig`
   - Configures library search paths

5. **Container Runtime Configuration**
   - Updates containerd configuration
   - Sets environment variables
   - Configures systemd service

6. **Verification**
   Runs verification tests:
   - Tests `nvidia-smi`
   - Verifies library configuration
   - Tests `nvidia-container-cli`

### Security Considerations
- Uses GPG key verification for package installation
- Sets appropriate permissions for directories
- Configures secure library paths

### Dependencies
- Requires host NVIDIA drivers
- Needs root access within Kind container
- Requires specific NVIDIA library versions (535.183.01)
