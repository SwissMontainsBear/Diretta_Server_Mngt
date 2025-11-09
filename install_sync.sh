#!/bin/sh
#	Installs and compiles Diretta Alsa drivers
#	GPL 3.0
#	Mis à disposition sans garantie
#	bear at forum-hifi.fr

# Input validation
if [ -z "$1" ]; then
    echo "Error: Release version required"
    echo "Usage: $0 <release_version>"
    echo "Example: $0 1.2.3"
    exit 1
fi

RELEASE_VER=$1
SOFTWARE_NAME="DirettaAlsaHost"
FILENAME="${SOFTWARE_NAME}_${RELEASE_VER}.tar.xz"

# Verify the file exists
if [ ! -f "${FILENAME}" ]; then
    echo "Error: ${FILENAME} not found!"
    exit 1
fi

RELEASE=$(uname -r)
echo "Current kernel release is: ${RELEASE}"
USER=$(whoami)
echo "Current user is: ${USER}"

# Function to stop a service with forced kill if needed
stop_service_with_kill() {
    local SERVICE_NAME=$1
    local PROCESS_NAME=$2
    local MAX_WAIT=10  # Maximum seconds to wait for graceful shutdown
    
    echo "Stopping ${SERVICE_NAME}..."
    
    # Try graceful stop first
    sudo systemctl stop "${SERVICE_NAME}"
    
    # Wait and check if service stopped
    local COUNT=0
    while systemctl is-active --quiet "${SERVICE_NAME}" && [ ${COUNT} -lt ${MAX_WAIT} ]; do
        echo "  Waiting for ${SERVICE_NAME} to stop... (${COUNT}/${MAX_WAIT})"
        sleep 1
        COUNT=$((COUNT + 1))
    done
    
    # Check if service is still running
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo "  ✗ ${SERVICE_NAME} did not stop gracefully"
        echo "  Searching for ${PROCESS_NAME} process..."
        
        # Find the process
        PIDS=$(ps -A | grep "${PROCESS_NAME}" | grep -v grep | awk '{print $1}')
        
        if [ -n "${PIDS}" ]; then
            echo "  Found process(es): ${PIDS}"
            for PID in ${PIDS}; do
                echo "  Killing process ${PID}..."
                sudo kill -9 "${PID}"
            done
            
            # Verify process is killed
            sleep 1
            REMAINING=$(ps -A | grep "${PROCESS_NAME}" | grep -v grep)
            if [ -z "${REMAINING}" ]; then
                echo "  ✓ ${PROCESS_NAME} process(es) killed successfully"
            else
                echo "  ✗ Warning: Some ${PROCESS_NAME} processes may still be running"
            fi
        else
            echo "  ℹ No ${PROCESS_NAME} process found, but service still active"
            echo "  Forcing service stop..."
            sudo systemctl kill "${SERVICE_NAME}"
            sleep 1
        fi
    else
        echo "  ✓ ${SERVICE_NAME} stopped successfully"
    fi
    
    # Final verification
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        echo "  ✗ ERROR: ${SERVICE_NAME} is still running!"
        return 1
    else
        echo "  ✓ ${SERVICE_NAME} is stopped"
        return 0
    fi
}

echo ""
echo "=== Stopping services ==="

# Stop services in dependency order: hqplayerd → diretta_sync_host → diretta_bridge_driver
stop_service_with_kill "hqplayerd.service" "hqplayerd" || {
    echo "Failed to stop hqplayerd.service"
    echo "Please manually kill the process and try again"
    exit 1
}

stop_service_with_kill "diretta_sync_host.service" "syncAlsa" || {
    echo "Warning: diretta_sync_host.service may not have stopped cleanly"
}

# Stop diretta_bridge_driver (simple systemctl stop, no process to kill)
echo "Stopping diretta_bridge_driver.service..."
sudo systemctl stop diretta_bridge_driver.service

# Verify it stopped
if systemctl is-active --quiet diretta_bridge_driver.service; then
    echo "  ✗ Warning: diretta_bridge_driver.service still active"
else
    echo "  ✓ diretta_bridge_driver.service stopped"
fi

# Unload alsa_bridge module (now safe since diretta_sync_host is stopped)
echo ""
echo "Unloading alsa_bridge module..."
if lsmod | grep -q alsa_bridge; then
    sudo rmmod alsa_bridge && echo "  ✓ alsa_bridge module unloaded" || {
        echo "  ✗ Failed to unload alsa_bridge module"
        echo "  Module may be in use. Checking dependencies..."
        lsmod | grep alsa_bridge
        exit 1
    }
else
    echo "  ℹ alsa_bridge module not loaded"
fi

echo ""
echo "=== All services stopped and modules unloaded ==="

sudo dnf update --refresh --exclude='kernel-core'

echo ""
echo "Uncompressing kernel image"
/bin/bash /home/${USER}/extract-vmlinux.sh /boot/vmlinuz-${RELEASE} > vmlinux || { echo "Failed to extract vmlinux"; exit 1; }
sudo cp vmlinux /usr/src/kernels/${RELEASE}/. || { echo "Failed to copy vmlinux"; exit 1; }

echo "Uncompressing new drivers tar"
cp DirettaAlsaHost/syncalsa_setting.inf . || { echo "Failed to backup settings"; exit 1; }
tar -xvf "${FILENAME}" || { echo "Failed to extract ${FILENAME}"; exit 1; }
cp syncalsa_setting.inf DirettaAlsaHost/. || { echo "Failed to restore settings"; exit 1; }

echo "=== Detecting CPU Architecture ==="

CPU_VENDOR=$(lscpu | grep "Vendor ID" | awk '{print $3}')
CPU_MODEL=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
CPU_FAMILY=$(lscpu | grep "CPU family" | awk '{print $3}')
CPU_MODEL_NUM=$(lscpu | grep -w "Model:" | awk '{print $2}')

echo "CPU Vendor: ${CPU_VENDOR}"
echo "CPU Model: ${CPU_MODEL}"
echo "CPU Family: ${CPU_FAMILY}"
echo "CPU Model Number: ${CPU_MODEL_NUM}"

# Detect Zen4 (Family 25, Model >= 96)
# Zen4: Ryzen 7000 series, EPYC 9004 series
IS_ZEN4=false

if [ "${CPU_VENDOR}" = "AuthenticAMD" ]; then
    if [ "${CPU_FAMILY}" = "25" ] && [ "${CPU_MODEL_NUM}" -ge 96 ]; then
        IS_ZEN4=true
    elif echo "${CPU_MODEL}" | grep -Eq "Ryzen.*(7[0-9]{3}|9[0-9]{3})"; then
        IS_ZEN4=true
    elif echo "${CPU_MODEL}" | grep -Eq "EPYC.*9[0-9]{3}"; then
        IS_ZEN4=true
    fi
fi

if [ "${IS_ZEN4}" = true ]; then
    echo ""
    echo "✓ Zen4 architecture detected!"
    echo "  Enabling optimizations: -march=x86-64-v4 -mtune=znver4 -O3"
    KCFLAGS="-march=x86-64-v4 -mtune=znver4 -O3"
else
    echo ""
    echo "→ Non-Zen4 CPU detected"
    echo "  Using standard compilation flags"
    KCFLAGS=""
fi

KERNELDIR="/usr/src/kernels/${RELEASE}"

# Enter directory and prepare for compilation
cd DirettaAlsaHost || { echo "Failed to enter DirettaAlsaHost directory"; exit 1; }

if [ "${IS_ZEN4}" = true ]; then
	chmod +x syncAlsa_gcc15_x64_zen4
else
	chmod +x syncAlsa_gcc15_x64_v2
fi	

rm -f alsa_bridge.ko alsa_bridge.mod alsa_bridge.mod.o alsa_bridge.o modules.order Module.symvers

echo "Building with $([ "${IS_ZEN4}" = true ] && echo 'Zen4 optimizations' || echo 'standard flags')..."

sudo make KCFLAGS="${KCFLAGS}" KERNELDIR="${KERNELDIR}" || { echo "Build failed"; exit 1; }
sudo cp alsa_bridge.ko "/lib/modules/${RELEASE}/." || { echo "Copy failed"; exit 1; }
sudo depmod || { echo "depmod failed"; exit 1; }
sudo modprobe alsa_bridge || { echo "modprobe failed"; exit 1; }

echo ""
echo "=== Verification ==="
lsmod | grep alsa && echo "✓ alsa_bridge module loaded successfully" || echo "✗ Warning: alsa_bridge not in lsmod"

# Return to home directory
cd "${HOME}" || { echo "Failed to return to home directory"; exit 1; }

echo ""
echo "=== Verifying Service Configuration ==="

USER_HOME="/home/${USER}"
EXPECTED_BINARY=$([ "${IS_ZEN4}" = true ] && echo "syncAlsa_gcc15_x64_zen4" || echo "syncAlsa_gcc15_x64_v2")

# ===== Configure diretta_bridge_driver.service =====
BRIDGE_SERVICE_FILE="/etc/systemd/system/diretta_bridge_driver.service"

echo "Checking diretta_bridge_driver.service configuration..."

if [ ! -f "${BRIDGE_SERVICE_FILE}" ]; then
    echo "  Creating ${BRIDGE_SERVICE_FILE}..."
    
    sudo tee "${BRIDGE_SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description = Diretta Alsa Bridge Driver
After=local-fs.target
ConditionPathExists=${USER_HOME}/DirettaAlsaHost

[Service]
ExecStartPre=modprobe snd_pcm
ExecStart=modprobe alsa_bridge
ExecStop=rmmod alsa_bridge
Restart=no
Type=simple

[Install]
WantedBy=multi-user.target
EOF
    
    echo "  ✓ diretta_bridge_driver.service created"
else
    # Check if ExecStop is configured
    if ! grep -q "^ExecStop=" "${BRIDGE_SERVICE_FILE}"; then
        echo "  Updating ${BRIDGE_SERVICE_FILE} (adding ExecStop)..."
        
        sudo tee "${BRIDGE_SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description = Diretta Alsa Bridge Driver
After=local-fs.target
ConditionPathExists=${USER_HOME}/DirettaAlsaHost

[Service]
ExecStartPre=modprobe snd_pcm
ExecStart=modprobe alsa_bridge
ExecStop=rmmod alsa_bridge
Restart=no
Type=simple

[Install]
WantedBy=multi-user.target
EOF
        
        echo "  ✓ diretta_bridge_driver.service updated"
    else
        echo "  ✓ diretta_bridge_driver.service already correctly configured"
    fi
fi

# Enable the bridge driver service
if ! systemctl is-enabled diretta_bridge_driver.service >/dev/null 2>&1; then
    echo "  Enabling diretta_bridge_driver.service..."
    sudo systemctl enable diretta_bridge_driver.service
    echo "  ✓ Service enabled"
else
    echo "  ✓ Service already enabled"
fi

# ===== Configure diretta_sync_host.service =====
SYNC_SERVICE_FILE="/etc/systemd/system/diretta_sync_host.service"

echo ""
echo "Checking diretta_sync_host.service configuration..."

if [ ! -f "${SYNC_SERVICE_FILE}" ]; then
    echo "  Creating ${SYNC_SERVICE_FILE}..."
    
    sudo tee "${SYNC_SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description = Diretta Synchro Alsa Host
After=network-online.target diretta_bridge_driver.service
Requires=diretta_bridge_driver.service
ConditionPathExists=${USER_HOME}/DirettaAlsaHost

[Service]
Slice=diretta.slice
ExecStart=${USER_HOME}/DirettaAlsaHost/${EXPECTED_BINARY} ${USER_HOME}/DirettaAlsaHost/syncalsa_setting.inf
ExecStop=${USER_HOME}/DirettaAlsaHost/${EXPECTED_BINARY} kill
Restart=always
Type=simple

[Install]
WantedBy=multi-user.target
EOF
    
    echo "  ✓ diretta_sync_host.service created"
else
    # Verify the correct binary is referenced
    CURRENT_BINARY=$(grep "^ExecStart=" "${SYNC_SERVICE_FILE}" | grep -o "syncAlsa_gcc15_x64[^ ]*" | head -1)
    
    if [ "${CURRENT_BINARY}" != "${EXPECTED_BINARY}" ]; then
        echo "  ✗ Service file uses '${CURRENT_BINARY}' but should use '${EXPECTED_BINARY}'"
        echo "  Updating service file..."
        
        sudo tee "${SYNC_SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description = Diretta Synchro Alsa Host
After=network-online.target diretta_bridge_driver.service
Requires=diretta_bridge_driver.service
ConditionPathExists=${USER_HOME}/DirettaAlsaHost

[Service]
Slice=diretta.slice
ExecStart=${USER_HOME}/DirettaAlsaHost/${EXPECTED_BINARY} ${USER_HOME}/DirettaAlsaHost/syncalsa_setting.inf
ExecStop=${USER_HOME}/DirettaAlsaHost/${EXPECTED_BINARY} kill
Restart=always
Type=simple

[Install]
WantedBy=multi-user.target
EOF
        
        echo "  ✓ Service file updated for ${EXPECTED_BINARY}"
    else
        echo "  ✓ Service file correctly configured for ${EXPECTED_BINARY}"
    fi
fi

# Verify the binary file exists and is executable
BINARY_PATH="${USER_HOME}/DirettaAlsaHost/${EXPECTED_BINARY}"
if [ ! -f "${BINARY_PATH}" ]; then
    echo "  ✗ Error: Binary ${EXPECTED_BINARY} not found at ${BINARY_PATH}"
    exit 1
elif [ ! -x "${BINARY_PATH}" ]; then
    echo "  ✗ Error: Binary ${EXPECTED_BINARY} is not executable"
    exit 1
else
    echo "  ✓ Binary ${EXPECTED_BINARY} found and executable"
fi

# Verify settings file exists
SETTINGS_FILE="${USER_HOME}/DirettaAlsaHost/syncalsa_setting.inf"
if [ ! -f "${SETTINGS_FILE}" ]; then
    echo "  ✗ Error: Settings file not found at ${SETTINGS_FILE}"
    exit 1
else
    echo "  ✓ Settings file found"
fi

# Enable the sync host service
if ! systemctl is-enabled diretta_sync_host.service >/dev/null 2>&1; then
    echo "  Enabling diretta_sync_host.service..."
    sudo systemctl enable diretta_sync_host.service
    echo "  ✓ Service enabled"
else
    echo "  ✓ Service already enabled"
fi

# Reload systemd daemon to pick up changes
sudo systemctl daemon-reload

echo ""
echo "=== Starting services ==="

# Start services in dependency order
sudo systemctl start diretta_bridge_driver.service
sleep 1
sudo systemctl start diretta_sync_host.service
sleep 1
sudo systemctl restart hqplayerd.service

# Verify services are running
echo ""
echo "=== Service Status ==="
sleep 2  # Give services time to start

if systemctl is-active --quiet diretta_bridge_driver.service; then
    echo "✓ diretta_bridge_driver.service is running"
    lsmod | grep -q alsa_bridge && echo "  ✓ alsa_bridge module loaded" || echo "  ✗ alsa_bridge module not loaded!"
else
    echo "✗ diretta_bridge_driver.service failed to start"
    sudo systemctl status diretta_bridge_driver.service --no-pager
fi

if systemctl is-active --quiet diretta_sync_host.service; then
    echo "✓ diretta_sync_host.service is running"
else
    echo "✗ diretta_sync_host.service failed to start"
    sudo systemctl status diretta_sync_host.service --no-pager
fi

if systemctl is-active --quiet hqplayerd.service; then
    echo "✓ hqplayerd.service is running"
else
    echo "✗ hqplayerd.service failed to start"
    sudo systemctl status hqplayerd.service --no-pager
fi

echo ""
echo "✓ Installation complete!"
