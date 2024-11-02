#!/bin/bash

# Create a temporary file for raw logs
RAW_LOG=$(mktemp)
CLEAN_LOG="${RAW_LOG}.clean"

collect_logs() {
    echo "Collecting logs..."
    {
        echo "=== GPU Operator Pod Status ==="
        kubectl get pods -n gpu-operator -o wide

        echo -e "\n=== Node Status ==="
        kubectl get nodes -o wide

        echo -e "\n=== Node GPU Labels ==="
        kubectl get nodes --show-labels | grep nvidia

        echo -e "\n=== Validator Pod Logs ==="
        kubectl logs -n gpu-operator $(kubectl get pods -n gpu-operator -l app=nvidia-operator-validator -o name) --all-containers --prefix || true

        echo -e "\n=== GPU Feature Discovery Logs ==="
        kubectl logs -n gpu-operator $(kubectl get pods -n gpu-operator -l app=gpu-feature-discovery -o name) --all-containers --prefix || true

        echo -e "\n=== Device Plugin Logs ==="
        kubectl logs -n gpu-operator $(kubectl get pods -n gpu-operator -l app=nvidia-device-plugin-daemonset -o name) --all-containers --prefix || true

        echo -e "\n=== Container Toolkit Logs ==="
        kubectl logs -n gpu-operator $(kubectl get pods -n gpu-operator -l app=nvidia-container-toolkit-daemonset -o name) --all-containers --prefix || true

        echo -e "\n=== DCGM Exporter Logs ==="
        kubectl logs -n gpu-operator $(kubectl get pods -n gpu-operator -l app=nvidia-dcgm-exporter -o name) --all-containers --prefix || true

        echo -e "\n=== Kind Container GPU Setup ==="
        docker exec kind-control-plane bash -c '
            echo "=== nvidia-smi ==="
            nvidia-smi
            echo -e "\n=== NVIDIA Libraries ==="
            ls -l /usr/lib/x86_64-linux-gnu/libnvidia*
            echo -e "\n=== ldconfig Cache ==="
            ldconfig -p | grep nvidia
            echo -e "\n=== Container Runtime Config ==="
            cat /etc/nvidia-container-runtime/config.toml
            echo -e "\n=== Containerd Config ==="
            cat /etc/containerd/config.toml
        '

        echo -e "\n=== Containerd Status ==="
        docker exec kind-control-plane systemctl status containerd

        echo -e "\n=== Runtime Debug Logs ==="
        docker exec kind-control-plane bash -c '
            echo "=== Runtime Debug Log ==="
            cat /var/log/nvidia-container-runtime-debug.log || true
            echo -e "\n=== CLI Debug Log ==="
            cat /var/log/nvidia-container-cli-debug.log || true
            echo -e "\n=== Runtime Log ==="
            cat /var/log/nvidia-container-runtime.log || true
        '
    } > "$RAW_LOG"
}

clean_logs() {
    echo "Cleaning logs..."
    {
        echo "=== CLEANED DEBUG LOG ==="
        echo

        # Extract and deduplicate pod status
        echo "=== Pod Status ==="
        grep -A 10 "^NAME.*READY.*STATUS" "$RAW_LOG" | head -n 11
        echo

        # Extract unique error messages
        echo "=== Unique Error Messages ==="
        grep -i "error\|failed\|warning" "$RAW_LOG" | sort -u
        echo

        # Extract NVIDIA library information
        echo "=== NVIDIA Libraries ==="
        grep -A 5 "libnvidia-ml.so" "$RAW_LOG" | sort -u
        echo "--"
        grep -A 5 "^-.*libnvidia" "$RAW_LOG" | sort -u
        echo

        # Extract containerd configuration
        echo "=== Containerd Config Highlights ==="
        grep -A 10 "\[plugins.*containerd.*nvidia\]" "$RAW_LOG" | head -n 11
        echo

        # Extract runtime logs
        echo "=== Runtime Logs Highlights ==="
        grep -A 5 "Runtime Debug Log" "$RAW_LOG" | grep -v "^--$"
        echo

        # Extract nvidia-smi output
        echo "=== nvidia-smi Output ==="
        grep -A 5 "^=== nvidia-smi ===$" "$RAW_LOG" | grep -v "^--$"
        echo
    } > "$CLEAN_LOG"
}

main() {
    collect_logs
    clean_logs

    echo "Raw logs saved to: $RAW_LOG"
    echo "Cleaned logs saved to: $CLEAN_LOG"
    
    # Display cleaned logs
    echo -e "\nCleaned Logs Content:"
    echo "===================="
    cat "$CLEAN_LOG"
}

main