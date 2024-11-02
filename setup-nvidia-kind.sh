#!/bin/bash

echo "Copying NVIDIA utilities and libraries to Kind container..."

# Install required packages
docker exec kind-control-plane apt-get update
docker exec kind-control-plane apt-get install -y libc-bin pciutils

# Create ldconfig.real symlink
docker exec kind-control-plane ln -sf /sbin/ldconfig /sbin/ldconfig.real

# Copy NVIDIA binaries
docker exec kind-control-plane mkdir -p /usr/local/nvidia/bin
for binary in nvidia-smi nvidia-debugdump nvidia-persistenced nvidia-cuda-mps-control nvidia-cuda-mps-server nvidia-container-runtime nvidia-container-runtime-hook nvidia-container-cli; do
    if [ -f "/usr/bin/$binary" ]; then
        docker cp "/usr/bin/$binary" kind-control-plane:/usr/bin/
        docker exec kind-control-plane chmod +x "/usr/bin/$binary"
    fi
done

# Create necessary directories
docker exec kind-control-plane mkdir -p /usr/local/nvidia/lib64
docker exec kind-control-plane mkdir -p /usr/lib/x86_64-linux-gnu
docker exec kind-control-plane mkdir -p /usr/lib/nvidia

# Copy and link NVIDIA libraries
for lib in $(find /usr/lib/x86_64-linux-gnu -name "libnvidia-*.so*" -o -name "libcuda*.so*"); do
    basename=$(basename "$lib")
    docker cp "$lib" kind-control-plane:/usr/lib/x86_64-linux-gnu/
    # Create symlinks if needed
    if [[ $basename == *.so.* ]]; then
        base=$(echo "$basename" | cut -d. -f1).so
        docker exec kind-control-plane bash -c "cd /usr/lib/x86_64-linux-gnu && ln -sf $basename $base"
    fi
done

# Specifically handle libnvidia-ml.so
if [ -f "/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1" ]; then
    docker cp "/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1" kind-control-plane:/usr/lib/x86_64-linux-gnu/
    docker exec kind-control-plane bash -c "cd /usr/lib/x86_64-linux-gnu && ln -sf libnvidia-ml.so.1 libnvidia-ml.so"
fi

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
debug-file = "/var/log/nvidia-container-runtime-debug.log"
verbosity = "debug"
ldconfig = "@/sbin/ldconfig.real"

[nvidia-container-cli]
debug = "/var/log/nvidia-container-cli-debug.log"
debug-file = "/var/log/nvidia-container-cli-debug.log"
verbosity = "debug"

[nvidia-container-runtime]
debug = "/var/log/nvidia-container-runtime.log"
debug-file = "/var/log/nvidia-container-runtime.log"
verbosity = "debug"
EOF'

# Set up environment
docker exec kind-control-plane bash -c 'echo "export PATH=\$PATH:/usr/local/nvidia/bin" >> /etc/profile.d/nvidia.sh'
docker exec kind-control-plane bash -c 'echo "/usr/local/nvidia/lib64" >> /etc/ld.so.conf.d/nvidia.conf'
docker exec kind-control-plane bash -c 'echo "/usr/lib/x86_64-linux-gnu" >> /etc/ld.so.conf.d/nvidia.conf'
docker exec kind-control-plane ldconfig

# Create log directory with proper permissions
docker exec kind-control-plane mkdir -p /var/log
docker exec kind-control-plane chmod 777 /var/log

# Verify NVIDIA setup
echo "Verifying NVIDIA setup..."
docker exec kind-control-plane bash -c 'ls -l /usr/lib/x86_64-linux-gnu/libnvidia-ml.so*'
docker exec kind-control-plane bash -c 'ldconfig -p | grep nvidia'
docker exec kind-control-plane nvidia-smi

echo "NVIDIA setup complete"