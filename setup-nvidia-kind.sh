#!/bin/bash

echo "Copying NVIDIA utilities and libraries to Kind container..."

# Install required packages
docker exec kind-control-plane apt-get update
docker exec kind-control-plane apt-get install -y libc-bin pciutils psmisc

# Create ldconfig.real symlink
docker exec kind-control-plane ln -sf /sbin/ldconfig /sbin/ldconfig.real

# Before copying files, stop any NVIDIA processes and unmount
docker exec kind-control-plane bash -c '
    systemctl stop nvidia-persistenced || true
    killall -9 nvidia-smi || true
    # Unmount any busy devices
    for f in /usr/bin/nvidia-* /usr/lib/x86_64-linux-gnu/libnvidia-* /usr/lib/x86_64-linux-gnu/libcuda*; do
        umount "$f" 2>/dev/null || true
    done
    sleep 2
'

# Copy NVIDIA binaries
docker exec kind-control-plane mkdir -p /usr/local/nvidia/bin
for binary in nvidia-smi nvidia-debugdump nvidia-persistenced nvidia-cuda-mps-control nvidia-cuda-mps-server nvidia-container-runtime nvidia-container-runtime-hook nvidia-container-cli; do
    if [ -f "/usr/bin/$binary" ]; then
        docker cp --follow-link "/usr/bin/$binary" kind-control-plane:/usr/bin/
        docker exec kind-control-plane chmod +x "/usr/bin/$binary"
    fi
done

# Create necessary directories
docker exec kind-control-plane mkdir -p /usr/local/nvidia/lib64
docker exec kind-control-plane mkdir -p /usr/lib/x86_64-linux-gnu
docker exec kind-control-plane mkdir -p /usr/lib/nvidia
docker exec kind-control-plane bash -c 'mkdir -p /usr/local/nvidia/toolkit'

# Copy and link NVIDIA libraries
for lib in $(find /usr/lib/x86_64-linux-gnu -name "libnvidia-*.so*" -o -name "libcuda*.so*"); do
    basename=$(basename "$lib")
    docker cp "$lib" kind-control-plane:/usr/lib/x86_64-linux-gnu/
    docker exec kind-control-plane chmod 755 "/usr/lib/x86_64-linux-gnu/$basename"
    
    # Create version-independent symlinks
    if [[ $basename =~ (.+)\.so\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        base="${BASH_REMATCH[1]}"
        version=$(echo "$basename" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+$')
        docker exec kind-control-plane bash -c "cd /usr/lib/x86_64-linux-gnu && \
            ln -sf $basename $base.so.${version%%.*} && \
            ln -sf $base.so.${version%%.*} $base.so && \
            cd /usr/lib/nvidia && \
            ln -sf ../x86_64-linux-gnu/$base.so $base.so"
    fi
done

# Define all required NVIDIA libraries
NVIDIA_LIBS=(
    "libnvidia-ml.so.535.183.01"
    "libcuda.so.535.183.01"
    "libnvidia-ptxjitcompiler.so.535.183.01"
    "libnvidia-fatbinaryloader.so.535.183.01"
)

echo "=== Copying NVIDIA Libraries ==="
for lib in "${NVIDIA_LIBS[@]}"; do
    base_lib="/usr/lib/x86_64-linux-gnu/$lib"
    if [ ! -f "$base_lib" ]; then
        echo "WARNING: Cannot find $base_lib"
        continue
    fi
    
    echo "Copying $lib..."
    docker exec kind-control-plane rm -f "/usr/lib/x86_64-linux-gnu/$lib"
    docker cp "$base_lib" "kind-control-plane:/usr/lib/x86_64-linux-gnu/"
    
    # Create version symlinks
    version=$(echo "$lib" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")
    major_version=${version%%.*}
    base_name=$(echo "$lib" | sed "s/\.${version}//")
    
    docker exec kind-control-plane bash -c "
        cd /usr/lib/x86_64-linux-gnu && \
        ln -sf $lib ${base_name}.${major_version} && \
        ln -sf ${base_name}.${major_version} ${base_name}.1 && \
        ln -sf ${base_name}.1 ${base_name}
    "
done

# Verify all libraries
echo "=== Verifying Libraries ==="
docker exec kind-control-plane bash -c '
    echo "1. Checking library files:"
    ls -la /usr/lib/x86_64-linux-gnu/libnvidia* /usr/lib/x86_64-linux-gnu/libcuda*
    
    echo "\n2. Checking library dependencies:"
    for lib in libnvidia-ml.so.1 libcuda.so.1; do
        echo "\nChecking $lib:"
        ldd /usr/lib/x86_64-linux-gnu/$lib
    done
    
    echo "\n3. Updating ldconfig cache:"
    ldconfig
    
    echo "\n4. Checking ldconfig cache:"
    ldconfig -p | grep -E "nvidia|cuda"
'

# Copy NVIDIA container runtime to toolkit directory
if [ -f "/usr/bin/nvidia-container-runtime" ]; then
    docker cp "/usr/bin/nvidia-container-runtime" kind-control-plane:/usr/local/nvidia/toolkit/
    docker exec kind-control-plane chmod 755 "/usr/local/nvidia/toolkit/nvidia-container-runtime"
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
root = "/usr/lib/x86_64-linux-gnu"
path = [
    "/usr/lib/x86_64-linux-gnu",
    "/usr/local/nvidia/lib64",
    "/usr/bin",
    "/usr/lib/nvidia"
]
environment = []
library-root = "/usr/lib/x86_64-linux-gnu"
library-path = [
    "/usr/lib/x86_64-linux-gnu",
    "/usr/lib/nvidia"
]

[nvidia-container-runtime]
debug = "/var/log/nvidia-container-runtime.log"
debug-file = "/var/log/nvidia-container-runtime.log"
verbosity = "debug"
EOF'

# Validate the config
docker exec kind-control-plane bash -c '
    echo "Validating NVIDIA container runtime config..."
    if command -v tomlv &> /dev/null; then
        tomlv /etc/nvidia-container-runtime/config.toml
    else
        echo "Installing toml validator..."
        apt-get update && apt-get install -y go-toml
        tomlv /etc/nvidia-container-runtime/config.toml
    fi
    
    echo "Testing NVIDIA container runtime..."
    nvidia-container-cli info
'

# Restart containerd after config changes
docker exec kind-control-plane systemctl restart containerd
sleep 5

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
docker exec kind-control-plane nvidia-smi

# Add this before "NVIDIA setup complete"
echo "=== Debugging NVIDIA Setup ==="
docker exec kind-control-plane bash -c '
    echo "\n3. Library dependencies:"
    ldd /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.$NVIDIA_ML_VERSION || true
    echo "\n4. Library in ldconfig:"
    ldconfig -v | grep nvidia-ml
    echo "\n5. Testing library load:"
    LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:/usr/lib/nvidia nvidia-smi
'

echo "=== Verifying Containerd Configuration ==="
docker exec kind-control-plane bash -c '
    echo "1. Checking containerd config:"
    cat /etc/containerd/config.toml | grep nvidia
    echo "\n2. Checking containerd status:"
    systemctl status containerd
    echo "\n3. Checking runtime executable:"
    ls -la /usr/local/nvidia/toolkit/nvidia-container-runtime
'

echo "=== Verifying Containerd Runtime ==="
docker exec kind-control-plane bash -c '
    echo "1. Checking runtime configuration:"
    containerd config dump | grep -A 10 nvidia
    echo "\n2. Checking runtime binary:"
    ls -la /usr/local/nvidia/toolkit/nvidia-container-runtime
    echo "\n3. Verifying runtime permissions:"
    namei -l /usr/local/nvidia/toolkit/nvidia-container-runtime
'

echo "NVIDIA setup complete"