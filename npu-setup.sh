#!/bin/bash
set -e

# NPU Development Environment Setup with Auto-Recovery
# Creates isolated container with NPU access and automatic recovery from hangs

WORKSPACE_DIR="$HOME/npu-projects"
CONTAINER_NAME="claude-npu-dev"
WATCHDOG_CHECK_INTERVAL=30  # seconds
WATCHDOG_HANG_TIMEOUT=15    # seconds

echo "=== NPU Development Environment Setup ==="
echo ""

# Create workspace directory
echo "[1/6] Creating workspace directory..."
mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"

# Setup passwordless sudo for NPU recovery
echo "[2/6] Setting up passwordless sudo for NPU recovery..."
sudo tee /etc/sudoers.d/npu-recovery > /dev/null << EOF
$USER ALL=(ALL) NOPASSWD: /sbin/rmmod amdxdna
$USER ALL=(ALL) NOPASSWD: /sbin/modprobe amdxdna
$USER ALL=(ALL) NOPASSWD: /usr/bin/tee /sys/bus/pci/drivers/amdxdna/unbind
$USER ALL=(ALL) NOPASSWD: /usr/bin/tee /sys/bus/pci/drivers/amdxdna/bind
EOF
sudo chmod 440 /etc/sudoers.d/npu-recovery
echo "   ✓ Passwordless sudo configured"

# Create watchdog script
echo "[3/6] Creating NPU watchdog script..."
cat > "$WORKSPACE_DIR/watchdog.sh" << 'WATCHDOG_EOF'
#!/bin/bash

CONTAINER="claude-npu-dev"
CHECK_INTERVAL=30  # seconds
HANG_TIMEOUT=15    # seconds
LOG_FILE="$HOME/npu-projects/watchdog.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

reset_npu() {
    log "NPU appears hung, resetting..."
    
    # Try graceful container restart first
    podman restart "$CONTAINER" 2>/dev/null
    sleep 2
    
    # If that doesn't work, reload kernel module
    if ! timeout 5s podman exec "$CONTAINER" xrt-smi examine &>/dev/null 2>&1; then
        log "Container restart insufficient, reloading kernel module..."
        sudo rmmod amdxdna 2>/dev/null || true
        sleep 1
        sudo modprobe amdxdna
        sleep 2
        podman restart "$CONTAINER"
    fi
    
    log "NPU reset complete"
}

log "NPU watchdog started (PID: $$)"

while true; do
    # Check if container exists
    if ! podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        log "Container does not exist, watchdog exiting..."
        exit 0
    fi
    
    # Check if container is running
    if ! podman ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        log "Container stopped, restarting..."
        podman start "$CONTAINER"
        sleep 5
        continue
    fi
    
    # Check if NPU is responsive
    if podman exec "$CONTAINER" timeout "$HANG_TIMEOUT" xrt-smi examine &>/dev/null 2>&1; then
        # NPU is healthy
        sleep "$CHECK_INTERVAL"
    else
        # NPU hung
        reset_npu
        sleep 5
    fi
done
WATCHDOG_EOF

chmod +x "$WORKSPACE_DIR/watchdog.sh"
echo "   ✓ Watchdog script created"

# Stop existing container if running
echo "[4/6] Cleaning up any existing container..."
if podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "   Stopping and removing existing container..."
    podman stop "$CONTAINER_NAME" 2>/dev/null || true
    podman rm "$CONTAINER_NAME" 2>/dev/null || true
fi

# Stop existing watchdog if running
if [ -f "$WORKSPACE_DIR/watchdog.pid" ]; then
    OLD_PID=$(cat "$WORKSPACE_DIR/watchdog.pid")
    if ps -p "$OLD_PID" > /dev/null 2>&1; then
        echo "   Stopping existing watchdog (PID: $OLD_PID)..."
        kill "$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$WORKSPACE_DIR/watchdog.pid"
fi

# Check if NPU device exists
echo "[5/6] Checking for NPU device..."
if [ ! -e /dev/accel/accel0 ]; then
    echo "   ⚠ WARNING: /dev/accel/accel0 not found"
    echo "   NPU may not be available or driver not loaded"
    echo "   Continuing anyway..."
else
    echo "   ✓ NPU device found"
fi

# Check if XRT exists
if [ ! -d /opt/xilinx/xrt ]; then
    echo "   ⚠ WARNING: /opt/xilinx/xrt not found"
    echo "   You may need to install XRT first"
    echo "   Continuing anyway..."
else
    echo "   ✓ XRT found"
fi

# Create container
echo "[6/6] Creating container with NPU access..."
podman run -d --name "$CONTAINER_NAME" \
  --device /dev/accel/accel0 \
  --device /dev/dri \
  -v "$WORKSPACE_DIR:/workspace" \
  -v /opt/xilinx/xrt:/opt/xilinx/xrt:ro \
  --read-only \
  --tmpfs /tmp \
  --tmpfs /var/tmp \
  -e LD_LIBRARY_PATH=/opt/xilinx/xrt/lib \
  -e PATH=/opt/xilinx/xrt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --security-opt label=disable \
  --security-opt no-new-privileges \
  -w /workspace \
  ubuntu:24.04 \
  sleep infinity

sleep 2
echo "   ✓ Container created"

# Install basic tools in container
echo ""
echo "Installing development tools in container..."
podman exec "$CONTAINER_NAME" bash -c 'apt update -qq && apt install -y -qq \
  build-essential cmake ninja-build \
  python3-venv python3-pip git wget curl \
  clang-14 lld-14 gcc-13 g++-13 \
  vim nano htop > /dev/null 2>&1'
echo "   ✓ Development tools installed"

# Create Python venv
echo "Setting up Python environment..."
podman exec "$CONTAINER_NAME" bash -c 'python3 -m venv /workspace/ironenv'
echo "   ✓ Python venv created"

# Start watchdog
echo ""
echo "Starting NPU watchdog..."
nohup "$WORKSPACE_DIR/watchdog.sh" > /dev/null 2>&1 &
WATCHDOG_PID=$!
echo $WATCHDOG_PID > "$WORKSPACE_DIR/watchdog.pid"
echo "   ✓ Watchdog started (PID: $WATCHDOG_PID)"

# Create stop script
cat > "$WORKSPACE_DIR/stop-all.sh" << 'STOP_EOF'
#!/bin/bash
echo "Stopping NPU development environment..."

# Stop watchdog
if [ -f "$HOME/npu-projects/watchdog.pid" ]; then
    WATCHDOG_PID=$(cat "$HOME/npu-projects/watchdog.pid")
    if ps -p "$WATCHDOG_PID" > /dev/null 2>&1; then
        echo "  Stopping watchdog (PID: $WATCHDOG_PID)..."
        kill "$WATCHDOG_PID" 2>/dev/null
    fi
    rm -f "$HOME/npu-projects/watchdog.pid"
fi

# Stop container
echo "  Stopping container..."
podman stop claude-npu-dev 2>/dev/null || true

echo "✓ Stopped"
STOP_EOF
chmod +x "$WORKSPACE_DIR/stop-all.sh"

# Create restart script
cat > "$WORKSPACE_DIR/restart-all.sh" << 'RESTART_EOF'
#!/bin/bash
echo "Restarting NPU development environment..."

# Stop everything
"$HOME/npu-projects/stop-all.sh"
sleep 2

# Start container
echo "Starting container..."
podman start claude-npu-dev

# Start watchdog
echo "Starting watchdog..."
nohup "$HOME/npu-projects/watchdog.sh" > /dev/null 2>&1 &
echo $! > "$HOME/npu-projects/watchdog.pid"

echo "✓ Restarted"
RESTART_EOF
chmod +x "$WORKSPACE_DIR/restart-all.sh"

# Create status script
cat > "$WORKSPACE_DIR/status.sh" << 'STATUS_EOF'
#!/bin/bash
echo "=== NPU Development Environment Status ==="
echo ""

# Container status
echo "Container:"
if podman ps --format '{{.Names}}' | grep -q "^claude-npu-dev$"; then
    echo "  ✓ Running"
else
    echo "  ✗ Not running"
fi

# Watchdog status
echo ""
echo "Watchdog:"
if [ -f "$HOME/npu-projects/watchdog.pid" ]; then
    WATCHDOG_PID=$(cat "$HOME/npu-projects/watchdog.pid")
    if ps -p "$WATCHDOG_PID" > /dev/null 2>&1; then
        echo "  ✓ Running (PID: $WATCHDOG_PID)"
    else
        echo "  ✗ Not running (stale PID file)"
    fi
else
    echo "  ✗ Not running"
fi

# NPU status
echo ""
echo "NPU:"
if podman exec claude-npu-dev timeout 5s xrt-smi examine &>/dev/null 2>&1; then
    echo "  ✓ Responsive"
else
    echo "  ✗ Not responsive or not accessible"
fi

# Recent watchdog events
echo ""
echo "Recent watchdog events:"
if [ -f "$HOME/npu-projects/watchdog.log" ]; then
    tail -5 "$HOME/npu-projects/watchdog.log"
else
    echo "  No log file yet"
fi
STATUS_EOF
chmod +x "$WORKSPACE_DIR/status.sh"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Workspace:  $WORKSPACE_DIR"
echo "Container:  $CONTAINER_NAME"
echo "Watchdog:   Running (PID: $WATCHDOG_PID)"
echo ""
echo "Useful commands:"
echo "  Status:   $WORKSPACE_DIR/status.sh"
echo "  Stop:     $WORKSPACE_DIR/stop-all.sh"
echo "  Restart:  $WORKSPACE_DIR/restart-all.sh"
echo "  Logs:     tail -f $WORKSPACE_DIR/watchdog.log"
echo ""
echo "Container shell: podman exec -it $CONTAINER_NAME bash"
echo ""
echo "✓ Ready for NPU development!"
