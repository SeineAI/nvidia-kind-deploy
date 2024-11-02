#!/bin/bash
set -e

echo "Setting up NVIDIA Container Support in Kind..."

# Install required packages
docker exec kind-control-plane apt-get update
docker exec kind-control-plane apt-get install -y curl gnupg libc-bin pciutils psmisc apt-utils

# Add NVIDIA repository and install container toolkit FIRST
docker exec kind-control-plane bash -c '
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
'

# Setup library paths and symlinks AFTER toolkit installation
docker exec kind-control-plane bash -c '
    mkdir -p /usr/lib64 /usr/local/nvidia/lib64
    mkdir -p /usr/local/nvidia/bin
    mkdir -p /usr/lib/nvidia
    mkdir -p /usr/local/nvidia/toolkit
    
    # Create symlinks for NVIDIA libraries
    cd /usr/lib/x86_64-linux-gnu
    ln -sf libnvidia-ml.so.535.183.01 libnvidia-ml.so.1
    ln -sf libnvidia-ml.so.1 libnvidia-ml.so
    ln -sf libcuda.so.535.183.01 libcuda.so.1
    ln -sf libcuda.so.1 libcuda.so
    ln -sf libnvidia-ptxjitcompiler.so.535.183.01 libnvidia-ptxjitcompiler.so.1
    ln -sf libnvidia-fatbinaryloader.so.535.183.01 libnvidia-fatbinaryloader.so.1
    
    # Make binaries executable
    chmod +x /usr/bin/nvidia-*
    
    # Update library paths
    echo "/usr/lib/x86_64-linux-gnu" > /etc/ld.so.conf.d/nvidia.conf
    echo "/usr/lib64" >> /etc/ld.so.conf.d/nvidia.conf
    echo "/usr/local/nvidia/lib64" >> /etc/ld.so.conf.d/nvidia.conf
    ldconfig
'

# Copy configuration files
docker cp config/containerd-config.toml kind-control-plane:/etc/containerd/config.toml

# Set up environment
docker exec kind-control-plane bash -c 'echo "export PATH=\$PATH:/usr/local/nvidia/bin" >> /etc/profile.d/nvidia.sh'
docker exec kind-control-plane bash -c 'echo "/usr/local/nvidia/lib64" >> /etc/ld.so.conf.d/nvidia.conf'
docker exec kind-control-plane ldconfig

# Create log directory with proper permissions
docker exec kind-control-plane mkdir -p /var/log
docker exec kind-control-plane chmod 777 /var/log

# Update container runtime environment
docker exec kind-control-plane mkdir -p /etc/systemd/system/containerd.service.d
docker exec kind-control-plane bash -c 'cat > /etc/systemd/system/containerd.service.d/env.conf << EOF
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/nvidia/bin"
Environment="LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/local/nvidia/lib64"
EOF'

# Restart containerd
docker exec kind-control-plane systemctl daemon-reload
docker exec kind-control-plane systemctl restart containerd
sleep 5

# Verify setup
docker exec kind-control-plane bash -c '
    echo "=== Testing nvidia-smi ==="
    nvidia-smi
    echo "=== Checking NVIDIA libraries ==="
    ldconfig -p | grep -E "nvidia|cuda"
    echo "=== Testing nvidia-container-cli ==="
    nvidia-container-cli info
'

echo "NVIDIA setup complete"