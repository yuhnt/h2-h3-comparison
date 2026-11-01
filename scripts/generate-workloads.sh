#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SINGLE_DIR="$PROJECT_ROOT/web/resources/single"
MULTI_DIR="$PROJECT_ROOT/web/resources/multi"

echo "=== Generating Benchmark Workload Files ==="

# Create directories
mkdir -p "$SINGLE_DIR"
mkdir -p "$MULTI_DIR"

# --- Demo 1: Single-Stream Workloads ---
echo "Generating Demo 1 (Single-Stream) files..."

# Small Files
touch "$SINGLE_DIR/0kb.bin"
head -c 10K /dev/urandom > "$SINGLE_DIR/10kb.bin" 2>/dev/null || dd if=/dev/urandom of="$SINGLE_DIR/10kb.bin" bs=10K count=1 2>/dev/null
head -c 100K /dev/urandom > "$SINGLE_DIR/100kb.bin" 2>/dev/null || dd if=/dev/urandom of="$SINGLE_DIR/100kb.bin" bs=100K count=1 2>/dev/null

# Medium Files
head -c 500K /dev/urandom > "$SINGLE_DIR/500kb.bin" 2>/dev/null || dd if=/dev/urandom of="$SINGLE_DIR/500kb.bin" bs=500K count=1 2>/dev/null
head -c 1M /dev/urandom > "$SINGLE_DIR/1mb.bin" 2>/dev/null || dd if=/dev/urandom of="$SINGLE_DIR/1mb.bin" bs=1M count=1 2>/dev/null
head -c 5M /dev/urandom > "$SINGLE_DIR/5mb.bin" 2>/dev/null || dd if=/dev/urandom of="$SINGLE_DIR/5mb.bin" bs=5M count=1 2>/dev/null

# Large Files
head -c 10M /dev/urandom > "$SINGLE_DIR/10mb.bin" 2>/dev/null || dd if=/dev/urandom of="$SINGLE_DIR/10mb.bin" bs=10M count=1 2>/dev/null

echo "✓ Demo 1 files generated in $SINGLE_DIR:"
ls -lh "$SINGLE_DIR"

# --- Demo 2: Multi-Stream Workloads (20 x 1MB) ---
echo
echo "Generating Demo 2 (Multi-Stream: 20 x 1MB) files..."
for i in $(seq 1 20); do
    head -c 1M /dev/urandom > "$MULTI_DIR/file-${i}.bin" 2>/dev/null || dd if=/dev/urandom of="$MULTI_DIR/file-${i}.bin" bs=1M count=1 2>/dev/null
done

echo "✓ Demo 2 files generated in $MULTI_DIR (20 files x 1MB)"
echo "=== Workload Generation Complete ==="
