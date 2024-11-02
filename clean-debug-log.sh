#!/bin/bash

# Check if input file is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <input-log-file>"
    exit 1
fi

INPUT_FILE="$1"
TEMP_FILE=$(mktemp)

{
    echo "=== CLEANED DEBUG LOG ==="
    echo

    # Extract and deduplicate pod status
    echo "=== Pod Status ==="
    grep -A 10 "^NAME.*READY.*STATUS" "$INPUT_FILE" | head -n 11
    echo

    # Extract unique error messages
    echo "=== Unique Error Messages ==="
    grep -i "error\|failed\|warning" "$INPUT_FILE" | sort -u
    echo

    # Extract NVIDIA library information
    echo "=== NVIDIA Libraries ==="
    grep -A 5 "libnvidia-ml.so" "$INPUT_FILE" | sort -u
    echo

    # Extract containerd configuration
    echo "=== Containerd Config Highlights ==="
    grep -A 10 "\[plugins.*containerd.*nvidia\]" "$INPUT_FILE" | head -n 11
    echo

    # Extract runtime logs
    echo "=== Runtime Logs Highlights ==="
    grep -A 5 "Runtime Debug Log" "$INPUT_FILE" | grep -v "^--$"
    echo

    # Extract nvidia-smi output
    echo "=== nvidia-smi Output ==="
    grep -A 5 "^=== nvidia-smi ===$" "$INPUT_FILE" | grep -v "^--$"
    echo

} > "$TEMP_FILE"

# Replace original file with cleaned version
mv "$TEMP_FILE" "${INPUT_FILE}.clean"
echo "Cleaned log saved to ${INPUT_FILE}.clean" 