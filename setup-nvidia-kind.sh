#!/bin/bash

echo "Copying NVIDIA utilities and libraries to Kind container..."

# Install required packages
docker exec kind-control-plane apt-get update
docker exec kind-control-plane apt-get install -y libc-bin

# Create ldconfig.real symlink
docker exec kind-control-plane ln -sf /sbin/ldconfig /sbin/ldconfig.real

# Copy NVIDIA binaries
docker exec kind-control-plane mkdir -p /usr/local/nvidia/bin
for binary in nvidia-smi nvidia-debugdump nvidia-persistenced nvidia-cuda-mps-control nvidia-cuda-mps-server nvidia-container-runtime nvidia-container-runtime-hook nvidia-container-cli; do
    if [ -f "/usr/bin/$binary" ]; then
        docker cp "/usr/bin/$binary" kind-control-plane:/usr/bin/
    fi
done

# Copy NVIDIA libraries
docker exec kind-control-plane mkdir -p /usr/local/nvidia/lib64
for lib in $(find /usr/lib/x86_64-linux-gnu -name "libnvidia-*.so*" -o -name "libcuda*.so*"); do
    docker cp "$lib" kind-control-plane:/usr/lib/x86_64-linux-gnu/
done

# Copy additional required files
if [ -d "/usr/share/nvidia" ]; then
    docker exec kind-control-plane mkdir -p /usr/share/nvidia
    docker cp /usr/share/nvidia kind-control-plane:/usr/share/
fi

# Configure nvidia-container-runtime
docker exec kind-control-plane mkdir -p /etc/nvidia-container-runtime
docker exec kind-control-plane bash -c 'cat > /etc/nvidia-container-runtime/config.toml << EOF
disable-require = false
debug = "/var/log/nvidia-container-runtime-debug.log"
ldconfig = "@/sbin/ldconfig.real"

[nvidia-container-cli]
debug = "/var/log/nvidia-container-cli-debug.log"
EOF'

# Set up environment
docker exec kind-control-plane bash -c 'echo "export PATH=\$PATH:/usr/local/nvidia/bin" >> /etc/profile.d/nvidia.sh'
docker exec kind-control-plane bash -c 'echo "/usr/local/nvidia/lib64" >> /etc/ld.so.conf.d/nvidia.conf'
docker exec kind-control-plane ldconfig

echo "NVIDIA setup complete" 