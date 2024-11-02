#!/bin/bash

# Define NVIDIA version and paths at the top
NVIDIA_VERSION="535.183.01"
NVIDIA_MAJOR_VERSION="${NVIDIA_VERSION%%.*}"
NVIDIA_LIB_DIR="/usr/lib/x86_64-linux-gnu"

# Define all required NVIDIA libraries
NVIDIA_LIBS=(
    "libnvidia-ml.so.${NVIDIA_VERSION}"
    "libcuda.so.${NVIDIA_VERSION}"
    "libnvidia-ptxjitcompiler.so.${NVIDIA_VERSION}"
    "libnvidia-fatbinaryloader.so.${NVIDIA_VERSION}"
)

echo "Setting up NVIDIA version ${NVIDIA_VERSION}..."

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
docker exec kind-control-plane mkdir -p /usr/local/nvidia/toolkit

# Define required NVIDIA libraries and create a function to handle library copying
copy_nvidia_library() {
    local lib="$1"
    local basename=$(basename "$lib")
    echo "Processing $basename..."
    
    # Resolve symlinks to get the actual file
    local real_lib=$(readlink -f "$lib")
    echo "Real library path: $real_lib"
    
    # Force unmount and remove existing files
    docker exec kind-control-plane bash -c "
        # Force unmount if mounted
        umount '${NVIDIA_LIB_DIR}/$basename' 2>/dev/null || true
        # Remove existing file and symlinks
        rm -f '${NVIDIA_LIB_DIR}/$basename'*
        # Ensure directory exists
        mkdir -p '${NVIDIA_LIB_DIR}'
    "
    
    # Copy the actual file, not the symlink
    echo "Copying real library file..."
    if ! docker cp "$real_lib" "kind-control-plane:${NVIDIA_LIB_DIR}/$basename"; then
        echo "ERROR: Failed to copy $basename"
        return 1
    fi
    
    # Verify file size matches
    local src_size=$(stat -c%s "$real_lib")
    local dst_size=$(docker exec kind-control-plane stat -c%s "${NVIDIA_LIB_DIR}/$basename")
    
    if [ "$src_size" != "$dst_size" ]; then
        echo "ERROR: File size mismatch for $basename"
        echo "Source size: $src_size"
        echo "Destination size: $dst_size"
        return 1
    fi
    
    # Set permissions
    docker exec kind-control-plane chmod 755 "${NVIDIA_LIB_DIR}/$basename"
    
    # Create symlinks if it's a versioned library
    if [[ $basename =~ (.+)\.so\.([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        local base="${BASH_REMATCH[1]}"
        local version="${BASH_REMATCH[2]}"
        local major_version="${version%%.*}"
        
        docker exec kind-control-plane bash -c "
            cd ${NVIDIA_LIB_DIR} && \
            ln -sf $basename $base.so.$major_version && \
            ln -sf $base.so.$major_version $base.so.1 && \
            ln -sf $base.so.1 $base.so && \
            cd /usr/lib/nvidia && \
            ln -sf ../x86_64-linux-gnu/$base.so $base.so
        "
    fi
    
    # Verify the copy and print details
    docker exec kind-control-plane bash -c "
        echo 'Verifying $basename:'
        ls -la ${NVIDIA_LIB_DIR}/$basename
        file ${NVIDIA_LIB_DIR}/$basename
        echo 'File size: '
        stat -c%s ${NVIDIA_LIB_DIR}/$basename
    "
    
    return 0
}

echo "=== Copying NVIDIA Libraries ==="

# First, copy the essential libraries we know we need
for lib in "${NVIDIA_LIBS[@]}"; do
    source_lib="${NVIDIA_LIB_DIR}/$lib"
    if [ ! -f "$source_lib" ]; then
        echo "WARNING: Essential library $lib not found!"
        continue
    fi
    copy_nvidia_library "$source_lib"
done

# Then, find and copy any additional NVIDIA libraries
echo "Copying additional NVIDIA libraries..."
for lib in $(find ${NVIDIA_LIB_DIR} -name "libnvidia-*.so*" -o -name "libcuda*.so*" -type f); do
    # Skip if we already copied this library
    basename=$(basename "$lib")
    if [[ " ${NVIDIA_LIBS[@]} " =~ " ${basename} " ]]; then
        continue
    fi
    copy_nvidia_library "$lib"
done

# Verify all libraries
echo "=== Verifying Libraries ==="
docker exec kind-control-plane bash -c "
    echo '1. Checking library files:'
    ls -la ${NVIDIA_LIB_DIR}/libnvidia* /usr/lib/x86_64-linux-gnu/libcuda*
    
    echo '\n2. Checking library dependencies:'
    for lib in libnvidia-ml.so.1 libcuda.so.1; do
        echo '\nChecking $lib:'
        ldd ${NVIDIA_LIB_DIR}/$lib
    done
    
    echo '\n3. Updating ldconfig cache:'
    ldconfig
    
    echo '\n4. Checking ldconfig cache:'
    ldconfig -p | grep -E 'nvidia|cuda'
"

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
path = ["/usr/lib/x86_64-linux-gnu", "/usr/local/nvidia/lib64", "/usr/bin", "/usr/lib/nvidia"]
environment = []
library-root = "/usr/lib/x86_64-linux-gnu"
library-path = ["/usr/lib/x86_64-linux-gnu", "/usr/lib/nvidia"]

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
docker exec kind-control-plane nvidia-smi

# Add this before "NVIDIA setup complete"
echo "=== Debugging NVIDIA Setup ==="
docker exec kind-control-plane bash -c "
    echo '1. Library files:'
    ls -la ${NVIDIA_LIB_DIR}/libnvidia-ml*
    echo '\n2. Library load test:'
    ldd ${NVIDIA_LIB_DIR}/libnvidia-ml.so.${NVIDIA_VERSION}
    echo '\n3. NVIDIA SMI test:'
    LD_LIBRARY_PATH=${NVIDIA_LIB_DIR}:/usr/lib/nvidia nvidia-smi
"

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