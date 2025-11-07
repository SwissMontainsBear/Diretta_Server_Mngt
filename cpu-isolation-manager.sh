#!/bin/bash

# realtime-audio-tuner.sh
# Automates the advanced low-latency CPU and system tuning strategy for an audio workload.
# This script implements the multi-step plan involving GRUB, systemd slices, IRQ affinity,
# and CPU governor settings.

set -euo pipefail

# --- Configuration (Customize these values) ---
# CPU Layout from your strategy
HOUSEKEEPING_CPUS="0,8"
DIRETTA_CPUS="1-2,9-10"
HQPLAYER_CPUS="3-7,11-15"
ALL_ISOLATED_CPUS_LIST="1-7,9-15"
ALL_ISOLATED_CPUS_ARRAY=(1 2 3 4 5 6 7 9 10 11 12 13 14 15)

# Service names
DIRETTA_SERVICE="diretta_sync_host.service"
HQPLAYER_SERVICE="hqplayerd.service"

# Paths
GRUB_CONFIG_FILE="/etc/default/grub"
SYSTEMD_DIR="/etc/systemd/system"
LOCAL_BIN_DIR="/usr/local/bin"

# --- Functions ---

usage() {
    cat <<EOF
Usage: sudo $0 <command>

Commands:
  apply     Applies the full low-latency system tuning configuration.
  revert    Removes the configuration and reverts to system defaults.
  status    Checks the status of the created configuration files and services.

This script must be run as root.
It will create backups of any modified files.
EOF
    exit 1
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "ERROR: This script must be run as root." >&2
        exit 1
    fi
}

# --- APPLY Functions ---

apply_grub_config() {
    echo "INFO: Configuring GRUB..."
    local grub_cmdline_var="GRUB_CMDLINE_LINUX"
    
    # Kernel parameters from your strategy
    # Note: Removed "(isolcpus=io_queue,...)" as it's not standard syntax. Assuming you meant to combine them.
    local rt_params="isolcpus=${ALL_ISOLATED_CPUS_LIST} nohz=on nohz_full=${ALL_ISOLATED_CPUS_LIST} rcu_nocbs=${ALL_ISOLATED_CPUS_LIST} irqaffinity=${HOUSEKEEPING_CPUS}"
    local other_params="rhgb quiet zswap.enabled=0 amd_pstate=enable audit=0 ibt=off nosoftlockup skew_tick=1 default_hugepagesz=1G"
    local new_cmdline="${other_params} ${rt_params}"

    # Backup original
    [[ -f "${GRUB_CONFIG_FILE}.bak_rt_tuner" ]] || cp "$GRUB_CONFIG_FILE" "${GRUB_CONFIG_FILE}.bak_rt_tuner"
    echo "INFO: Backed up original to ${GRUB_CONFIG_FILE}.bak_rt_tuner"
    
    # Clean previous params and add new ones
    sed -i -E "s/ isolcpus=[^ \"]+//g; s/ nohz=[^ \"]+//g; s/ nohz_full=[^ \"]+//g; s/ rcu_nocbs=[^ \"]+//g; s/ irqaffinity=[^ \"]+//g" "$GRUB_CONFIG_FILE"
    sed -i "s#^${grub_cmdline_var}=\"\(.*\)\"#${grub_cmdline_var}=\"\1 ${rt_params}\"#" "$GRUB_CONFIG_FILE"
    # Clean up potential double spaces
    sed -i "s/  */ /g" "$GRUB_CONFIG_FILE"

    echo "INFO: GRUB CMDLINE set. Running grub update..."
    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v grub2-mkconfig &>/dev/null; then
        # Detect common paths for grub.cfg
        if [ -f /boot/grub2/grub.cfg ]; then
            grub2-mkconfig -o /boot/grub2/grub.cfg
        elif [ -f /boot/grub/grub.cfg ]; then
            grub2-mkconfig -o /boot/grub/grub.cfg
        else
            echo "ERROR: Could not find grub.cfg location for grub2-mkconfig." >&2
            return 1
        fi
    else
        echo "ERROR: Could not find 'update-grub' or 'grub2-mkconfig'." >&2
        return 1
    fi
    echo "SUCCESS: GRUB configured."
}

apply_systemd_slices() {
    echo "INFO: Creating systemd slice definitions..."
    # Restrict system/user tasks
    mkdir -p "${SYSTEMD_DIR}/init.scope.d"
    mkdir -p "${SYSTEMD_DIR}/system.slice.d"
    mkdir -p "${SYSTEMD_DIR}/user.slice.d"

    cat << EOF > "${SYSTEMD_DIR}/init.scope.d/50-cpu-isolation.conf"
[Scope]
AllowedCPUs=${HOUSEKEEPING_CPUS}
EOF
    cat << EOF > "${SYSTEMD_DIR}/system.slice.d/50-cpu-isolation.conf"
[Slice]
AllowedCPUs=${HOUSEKEEPING_CPUS}
EOF
    cat << EOF > "${SYSTEMD_DIR}/user.slice.d/50-cpu-isolation.conf"
[Slice]
AllowedCPUs=${HOUSEKEEPING_CPUS}
EOF

    # Create custom workload slices
    cat << EOF > "${SYSTEMD_DIR}/diretta.slice"
[Slice]
AllowedCPUs=${DIRETTA_CPUS}
EOF
    cat << EOF > "${SYSTEMD_DIR}/hqplayer.slice"
[Slice]
AllowedCPUs=${HQPLAYER_CPUS}
CPUQuota=100%
EOF
    echo "SUCCESS: Systemd slices created."
}

apply_workload_config() {
    echo "INFO: Configuring workload services to use slices..."
    
    # Use safer drop-in files instead of modifying originals
    mkdir -p "${SYSTEMD_DIR}/${DIRETTA_SERVICE}.d"
    cat << EOF > "${SYSTEMD_DIR}/${DIRETTA_SERVICE}.d/10-isolation.conf"
[Service]
Slice=diretta.slice
EOF

    mkdir -p "${SYSTEMD_DIR}/${HQPLAYER_SERVICE}.d"
    cat << EOF > "${SYSTEMD_DIR}/${HQPLAYER_SERVICE}.d/10-isolation.conf"
[Service]
Slice=hqplayer.slice
IOSchedulingClass=realtime
LimitMEMLOCK=4G
LimitNICE=-10
LimitRTPRIO=98
CPUSchedulingPolicy=rr
CPUSchedulingPriority=99
Nice=-20
EOF
    echo "SUCCESS: Workload slices applied via systemd drop-ins."
}

apply_irq_service() {
    echo "INFO: Creating IRQ affinity service..."
    local script_path="${LOCAL_BIN_DIR}/set-irq-affinity.sh"
    local service_path="${SYSTEMD_DIR}/set-irq-affinity.service"

    cat << EOF > "$script_path"
#!/bin/bash
# Set IRQ affinities to housekeeping cores for isolation
LOG_FILE="/var/log/irq-affinity.log"
echo "\$(date): Setting all IRQs to cores ${HOUSEKEEPING_CPUS}" > "\$LOG_FILE"
find /proc/irq/ -name "smp_affinity_list" -exec sh -c "echo ${HOUSEKEEPING_CPUS} > {}" \; 2>>"\$LOG_FILE"
EOF
    chmod +x "$script_path"

    cat << EOF > "$service_path"
[Unit]
Description=Set IRQ affinity for audio isolation
After=network.target

[Service]
Type=oneshot
ExecStart=$script_path
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    echo "SUCCESS: IRQ affinity service created."
}

apply_cpu_governor_service() {
    echo "INFO: Creating CPU performance governor service..."
    local service_path="${SYSTEMD_DIR}/cpu-performance.service"
    
    local exec_cmd="for i in ${ALL_ISOLATED_CPUS_ARRAY[@]}; do echo performance > /sys/devices/system/cpu/cpu\$i/cpufreq/scaling_governor; done"

    cat << EOF > "$service_path"
[Unit]
Description=Set CPU governor to performance for audio cores
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '$exec_cmd'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    echo "SUCCESS: CPU governor service created."
}

# --- REVERT Functions ---

revert_grub_config() {
    echo "INFO: Reverting GRUB changes..."
    local backup_file="${GRUB_CONFIG_FILE}.bak_rt_tuner"
    if [[ -f "$backup_file" ]]; then
        mv "$backup_file" "$GRUB_CONFIG_FILE"
        echo "SUCCESS: GRUB config restored from backup."
        # Update GRUB again after restoring
        if command -v update-grub &>/dev/null; then update-grub; fi
        if command -v grub2-mkconfig &>/dev/null; then
            if [ -f /boot/grub2/grub.cfg ]; then grub2-mkconfig -o /boot/grub2/grub.cfg; fi
            if [ -f /boot/grub/grub.cfg ]; then grub2-mkconfig -o /boot/grub/grub.cfg; fi
        fi
    else
        echo "WARNING: GRUB backup not found. Manual check required."
    fi
}

revert_systemd_files() {
    echo "INFO: Removing all created systemd units and slice definitions..."
    rm -f "${SYSTEMD_DIR}/init.scope.d/50-cpu-isolation.conf"
    rm -f "${SYSTEMD_DIR}/system.slice.d/50-cpu-isolation.conf"
    rm -f "${SYSTEMD_DIR}/user.slice.d/50-cpu-isolation.conf"
    rm -f "${SYSTEMD_DIR}/diretta.slice"
    rm -f "${SYSTEMD_DIR}/hqplayer.slice"
    rm -rf "${SYSTEMD_DIR}/${DIRETTA_SERVICE}.d"
    rm -rf "${SYSTEMD_DIR}/${HQPLAYER_SERVICE}.d"
    rm -f "${SYSTEMD_DIR}/set-irq-affinity.service"
    rm -f "${SYSTEMD_DIR}/cpu-performance.service"
    echo "SUCCESS: Systemd files removed."
}

revert_scripts() {
    echo "INFO: Removing helper scripts..."
    rm -f "${LOCAL_BIN_DIR}/set-irq-affinity.sh"
    echo "SUCCESS: Helper scripts removed."
}

# --- Main Logic ---

main() {
    check_root
    
    if [[ $# -eq 0 ]]; then
        usage
    fi

    local cmd=$1
    case "$cmd" in
        apply)
            echo "--- APPLYING LOW-LATENCY CONFIGURATION ---"
            read -p "This will modify system files. Continue? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi

            apply_grub_config
            apply_systemd_slices
            apply_workload_config
            apply_irq_service
            apply_cpu_governor_service
            
            echo "INFO: Reloading systemd and enabling new services..."
            systemctl daemon-reload
            systemctl enable set-irq-affinity.service cpu-performance.service
            
            echo
            echo "--- CONFIGURATION APPLIED SUCCESSFULLY ---"
            echo "A reboot is REQUIRED for all changes to take effect."
            ;;
            
        revert)
            echo "--- REVERTING LOW-LATENCY CONFIGURATION ---"
            read -p "This will remove all created files and restore backups. Continue? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then exit 1; fi
            
            echo "INFO: Disabling services..."
            systemctl disable --now set-irq-affinity.service cpu-performance.service 2>/dev/null || true
            
            revert_grub_config
            revert_systemd_files
            revert_scripts
            
            echo "INFO: Reloading systemd..."
            systemctl daemon-reload
            
            echo
            echo "--- CONFIGURATION REVERTED ---"
            echo "A reboot is REQUIRED to return to the previous state."

            ;;
        
        status)
            echo "--- CHECKING LOW-LATENCY CONFIGURATION STATUS ---"
            ls -l \
                "${GRUB_CONFIG_FILE}.bak_rt_tuner" \
                "${SYSTEMD_DIR}/init.scope.d/50-cpu-isolation.conf" \
                "${SYSTEMD_DIR}/system.slice.d/50-cpu-isolation.conf" \
                "${SYSTEMD_DIR}/user.slice.d/50-cpu-isolation.conf" \
                "${SYSTEMD_DIR}/diretta.slice" \
                "${SYSTEMD_DIR}/hqplayer.slice" \
                "${SYSTEMD_DIR}/${DIRETTA_SERVICE}.d/10-isolation.conf" \
                "${SYSTEMD_DIR}/${HQPLAYER_SERVICE}.d/10-isolation.conf" \
                "${SYSTEMD_DIR}/set-irq-affinity.service" \
                "${SYSTEMD_DIR}/cpu-performance.service" \
                "${LOCAL_BIN_DIR}/set-irq-affinity.sh" \
                2>/dev/null || echo "No configuration files found."
            echo
            echo "--- Service Status ---"
            systemctl is-enabled set-irq-affinity.service cpu-performance.service 2>/dev/null || true
            ;;
            
        *)
            echo "ERROR: Unknown command '$cmd'" >&2
            usage
            ;;
    esac
}

main "$@"
