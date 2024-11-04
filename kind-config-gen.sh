#!/bin/bash

set -euo pipefail

# Parse command line arguments
DRY_RUN=false
CLUSTER_NAME="kind-gpu"
OUTPUT_FILE=""

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -n, --name NAME       Set cluster name (default: kind-gpu)"
    echo "  -d, --dry-run        Only generate the configuration file without creating cluster"
    echo "  -o, --output FILE    Specify output file for configuration (default: kind-config.yaml)"
    echo "  -h, --help          Print this help message"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required commands
for cmd in nvidia-smi find; do
    if ! command_exists "$cmd"; then
        echo "Error: Required command '$cmd' not found"
        exit 1
    fi
done

# Only check for 'kind' command if not in dry-run mode
if ! $DRY_RUN; then
    if ! command_exists "kind"; then
        echo "Error: Required command 'kind' not found"
        exit 1
    fi
fi

# Get CUDA version and libraries path
CUDA_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
if [ -z "$CUDA_VERSION" ]; then
    echo "Error: Could not detect CUDA version"
    exit 1
fi

echo "Detected CUDA version: $CUDA_VERSION"

# Count available GPUs
GPU_COUNT=$(nvidia-smi --query-gpu=gpu_name --format=csv,noheader | wc -l)
echo "Detected $GPU_COUNT GPU(s)"

# Set up configuration file path
if [ -z "$OUTPUT_FILE" ]; then
    if $DRY_RUN; then
        OUTPUT_FILE="kind-config.yaml"
    else
        TMP_DIR=$(mktemp -d)
        OUTPUT_FILE="$TMP_DIR/kind-config.yaml"
    fi
fi

# Function to find NVIDIA libraries
find_nvidia_lib() {
    local lib_name=$1
    local lib_dirs=(
        "/usr/lib/x86_64-linux-gnu"  # Debian/Ubuntu
        "/usr/lib64"                 # RHEL/CentOS/Fedora
        "/usr/lib"                   # General
        "/usr/local/nvidia/lib64"    # Container environments
        "/usr/local/nvidia/lib"      # Container environments
        "$(dirname $(command -v nvidia-smi))/../lib64"  # Relative to nvidia-smi
        "$(dirname $(command -v nvidia-smi))/../lib"    # Relative to nvidia-smi
    )
    
    # First try exact version match
    for dir in "${lib_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local exact_match=$(find "$dir" -name "${lib_name}.so.*${CUDA_VERSION}" 2>/dev/null | head -n1)
            if [ -n "$exact_match" ]; then
                echo "$exact_match"
                return 0
            fi
        fi
    done
    
    # If exact match fails, try finding any version
    for dir in "${lib_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local any_version=$(find "$dir" -name "${lib_name}.so.*" 2>/dev/null | head -n1)
            if [ -n "$any_version" ]; then
                echo "$any_version"
                return 0
            fi
        fi
    done
    
    return 1
}

# Start generating KIND config
cat > "$OUTPUT_FILE" << EOL
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
EOL

# Add GPU device mounts
for i in $(seq 0 $((GPU_COUNT-1))); do
    cat >> "$OUTPUT_FILE" << EOL
  - hostPath: /dev/nvidia${i}
    containerPath: /dev/nvidia${i}
EOL
done

# Add common NVIDIA device mounts
for device in nvidia-uvm nvidia-uvm-tools nvidiactl nvidia-modeset nvidia-caps; do
    if [ -e "/dev/${device}" ]; then
        cat >> "$OUTPUT_FILE" << EOL
  - hostPath: /dev/${device}
    containerPath: /dev/${device}
EOL
    fi
done

# Find NVIDIA binaries
NVIDIA_BINS=(
    "nvidia-smi"
    "nvidia-debugdump"
    "nvidia-persistenced"
)

# Search for NVIDIA binaries in multiple locations
BINARY_PATHS=(
    "/usr/bin"
    "/usr/local/bin"
    "/usr/local/nvidia/bin"
    "$(dirname $(command -v nvidia-smi))"
)

for binary in "${NVIDIA_BINS[@]}"; do
    for path in "${BINARY_PATHS[@]}"; do
        if [ -f "${path}/${binary}" ]; then
            cat >> "$OUTPUT_FILE" << EOL
  - hostPath: ${path}/${binary}
    containerPath: /usr/bin/${binary}
EOL
            break
        fi
    done
done

# Find and add required NVIDIA libraries
NVIDIA_LIBS=(
    "libnvidia-ml"
    "libcuda"
    "libnvidia-ptxjitcompiler"
    "libnvidia-fatbinaryloader"
)

for lib in "${NVIDIA_LIBS[@]}"; do
    LIB_PATH=$(find_nvidia_lib "$lib")
    if [ -n "$LIB_PATH" ]; then
        echo "Found $lib at: $LIB_PATH"
        cat >> "$OUTPUT_FILE" << EOL
  - hostPath: ${LIB_PATH}
    containerPath: ${LIB_PATH}
EOL
    else
        echo "Warning: Could not find $lib"
    fi
done

# Add port mappings
cat >> "$OUTPUT_FILE" << EOL
  extraPortMappings:
  - containerPort: 30000
    hostPort: 30000
    protocol: TCP
  - containerPort: 30001
    hostPort: 30001
    protocol: TCP
  - containerPort: 30002
    hostPort: 30002
    protocol: TCP
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "nvidia.com/gpu=true"
EOL

echo "Generated KIND configuration at: $OUTPUT_FILE"

# If not in dry-run mode, proceed with cluster creation
if ! $DRY_RUN; then
    # Function to delete existing cluster if it exists
    delete_existing_cluster() {
        local cluster_name=$1
        if kind get clusters 2>/dev/null | grep -q "^${cluster_name}$"; then
            echo "Deleting existing cluster: ${cluster_name}"
            kind delete cluster --name "${cluster_name}"
        fi
    }

    # Create the cluster
    echo "Creating KIND cluster with GPU support..."
    delete_existing_cluster "$CLUSTER_NAME"
    kind create cluster --config "$OUTPUT_FILE" --name "$CLUSTER_NAME"

    echo "Cluster creation complete. Testing GPU access..."
    kubectl wait --for=condition=ready node --all --timeout=120s

    # Create a test pod to verify GPU access
    cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-smi-test
spec:
  containers:
  - name: nvidia-smi
    image: nvidia/cuda:11.0.3-base-ubuntu20.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
  restartPolicy: Never
EOF

    echo "Waiting for test pod to complete..."
    kubectl wait --for=condition=completed pod/nvidia-smi-test --timeout=60s
    echo "GPU test pod logs:"
    kubectl logs nvidia-smi-test

    # Clean up test pod
    kubectl delete pod nvidia-smi-test

    # Clean up temporary directory if it was created
    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi

    echo "Setup complete! Your KIND cluster with GPU support is ready."
else
    echo "Dry run complete. Configuration file generated at: $OUTPUT_FILE"
    echo "To create a cluster using this configuration, run:"
    echo "kind create cluster --config $OUTPUT_FILE --name $CLUSTER_NAME"
fi
