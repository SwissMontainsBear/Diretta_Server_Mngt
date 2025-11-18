#!/bin/sh
#	Install_MemoryPlay
#	GPL 3.0
#	Mis à disposition sans garantie
#	bear at forum-hifi.fr

# Input validation
if [ -z "$1" ]; then
    echo "Error: Version number required"
    echo "Usage: $0 <version>"
    echo "Example: $0 0_147_02"
    exit 1
fi

VERSION=$1
SOFTWARE_NAME="MemoryPlayHostLinux"
FILENAME="${SOFTWARE_NAME}_${VERSION}.tar.zst"

# Verify the file exists
if [ ! -f "${FILENAME}" ]; then
    echo "Error: ${FILENAME} not found in current directory!"
    exit 1
fi

USER=$(whoami)
USER_HOME="/home/${USER}"

echo "=== MemoryPlay Installation ==="
echo "Version: ${VERSION}"
echo "User: ${USER}"
echo "Home: ${USER_HOME}"

# Detect CPU Architecture
echo ""
echo "=== Detecting CPU Architecture ==="

CPU_VENDOR=$(lscpu | grep "Vendor ID" | awk '{print $3}')
CPU_MODEL=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
CPU_FAMILY=$(lscpu | grep "CPU family" | awk '{print $3}')
CPU_MODEL_NUM=$(lscpu | grep -w "Model:" | awk '{print $2}')

echo "CPU Vendor: ${CPU_VENDOR}"
echo "CPU Model: ${CPU_MODEL}"
echo "CPU Family: ${CPU_FAMILY}"
echo "CPU Model Number: ${CPU_MODEL_NUM}"

# Detect Zen4
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
    echo "✓ Zen4 architecture detected!"
    BINARY_SOURCE="MemoryPlayHost_gcc15_x64_zen4"
else
    echo "→ Non-Zen4 CPU detected"
    BINARY_SOURCE="MemoryPlayHost_gcc15_x64_v2"
fi

# Stop service if running
echo ""
echo "=== Stopping MemoryPlay service ==="
if systemctl is-active --quiet diretta_memoryplay_host.service; then
    sudo systemctl stop diretta_memoryplay_host.service
    echo "✓ Service stopped"
else
    echo "ℹ Service not running"
fi

# Change to home directory
cd "${USER_HOME}" || { echo "Failed to change to home directory"; exit 1; }

# Backup existing settings
echo ""
echo "=== Backing up settings ==="
if [ -f "MemoryPlay/memoryplayhost_setting.inf" ]; then
    cp MemoryPlay/memoryplayhost_setting.inf . || { echo "Failed to backup settings"; exit 1; }
    echo "✓ Settings backed up"
else
    echo "ℹ No existing settings file found"
fi

# Extract archive
echo ""
echo "=== Extracting ${FILENAME} ==="
tar --use-compress-program=unzstd -xvf "${FILENAME}" || { echo "Failed to extract MemoryPlay"; exit 1; }
echo "✓ Archive extracted"

# Restore settings if they existed
if [ -f "memoryplayhost_setting.inf" ]; then
    cp memoryplayhost_setting.inf MemoryPlay/. || { echo "Failed to restore settings"; exit 1; }
    echo "✓ Settings restored"
fi

# Enter MemoryPlay directory
cd MemoryPlay || { echo "Failed to enter MemoryPlay directory"; exit 1; }

# Copy appropriate binary
echo ""
echo "=== Configuring binary ==="
echo "Using: ${BINARY_SOURCE}"

if [ ! -f "${BINARY_SOURCE}" ]; then
    echo "✗ Error: ${BINARY_SOURCE} not found!"
    exit 1
fi

cp "${BINARY_SOURCE}" MemoryPlayHost || { echo "Failed to copy binary"; exit 1; }
chmod +x MemoryPlayHost || { echo "Failed to make binary executable"; exit 1; }
echo "✓ Binary configured and executable"

# Return to home directory
cd "${USER_HOME}" || { echo "Failed to return to home directory"; exit 1; }

# Create/update service file
echo ""
echo "=== Configuring systemd service ==="

SERVICE_FILE="/etc/systemd/system/diretta_memoryplay_host.service"

sudo tee "${SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description = Diretta Memory Play Host
After=network-online.target
ConditionPathExists=${USER_HOME}/MemoryPlay

[Service]
Slice=memory.slice
ExecStart=${USER_HOME}/MemoryPlay/MemoryPlayHost ${USER_HOME}/MemoryPlay/memoryplayhost_setting.inf
Restart=always
Type=simple

[Install]
WantedBy=multi-user.target
EOF

echo "✓ Service file created/updated"

# Verify binary and settings exist
BINARY_PATH="${USER_HOME}/MemoryPlay/MemoryPlayHost"
SETTINGS_PATH="${USER_HOME}/MemoryPlay/memoryplayhost_setting.inf"

if [ ! -f "${BINARY_PATH}" ]; then
    echo "✗ Error: Binary not found at ${BINARY_PATH}"
    exit 1
elif [ ! -x "${BINARY_PATH}" ]; then
    echo "✗ Error: Binary is not executable"
    exit 1
else
    echo "✓ Binary verified: ${BINARY_PATH}"
fi

if [ ! -f "${SETTINGS_PATH}" ]; then
    echo "✗ Warning: Settings file not found at ${SETTINGS_PATH}"
    echo "  Service may fail to start without settings file"
else
    echo "✓ Settings file verified: ${SETTINGS_PATH}"
fi

# Reload systemd and enable service
sudo systemctl daemon-reload

if ! systemctl is-enabled diretta_memoryplay_host.service >/dev/null 2>&1; then
    echo "Enabling diretta_memoryplay_host.service..."
    sudo systemctl enable diretta_memoryplay_host.service
    echo "✓ Service enabled"
else
    echo "✓ Service already enabled"
fi

# Start service
echo ""
echo "=== Starting MemoryPlay service ==="
sudo systemctl start diretta_memoryplay_host.service

# Verify service status
sleep 2
if systemctl is-active --quiet diretta_memoryplay_host.service; then
    echo "✓ diretta_memoryplay_host.service is running"
else
    echo "✗ diretta_memoryplay_host.service failed to start"
    echo ""
    echo "Service status:"
    sudo systemctl status diretta_memoryplay_host.service --no-pager
    exit 1
fi

echo ""
echo "✓ MemoryPlay installation complete!"
echo ""
echo "Service status:"
sudo systemctl status diretta_memoryplay_host.service --no-pager -l
