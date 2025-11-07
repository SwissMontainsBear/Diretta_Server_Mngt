#!/bin/sh
#	Install_HQPe
#	GPL 3.0
#	Mis à disposition sans garantie
#	bear at forum-hifi.fr
#

RELEASE=$(uname -r)
echo "Current kernel release is: $RELEASE"
USER=$(whoami)
echo "Current user is: $USER"
sudo dnf update
echo ""

echo "You will be offered the opportunity to achieve certain tasks:"
echo "Please choose among the following"
echo ""
echo "Install/Optimize: finishes install and removes certain unnecessary/polluting services (firewall, aso...)"
echo "Diretta: 	install and compile the Diretta ALSA drivers"
echo "NAA:		install HQPlayers's Network Audio Adapter"
echo "HQPe:		install HQPlayer Embedded for Fedora"
echo "Network:	change parameters of Diretta network interface"
echo "Status:		check installed components"
echo "reboot"
echo "exit"
echo ""

echo "Which task would you like to achieve?"
select option in "Optimize" "DirettaAlsa" "MemoryPlay" "MemoryPlayCtrl" "Install_HQPe" "Install_NAA" "Remove_Diretta" "Remove_HQPe" "Remove_NAA" "Network_Bridge" "Status" "reboot" "exit" ; do
    case $option in

		Optimize )
			echo "Starting system optimization..."
			sudo dnf install -y kernel-devel make dwarves tar zstd rsync curl || { echo "Failed to install packages"; break; }
			sudo systemctl disable auditd || true
			sudo systemctl stop firewalld || true
			sudo dnf remove -y firewalld || true
			sudo dnf remove -y selinux-policy || true
			sudo systemctl disable systemd-journald || true
			sudo systemctl stop systemd-journald || true
			sudo systemctl disable systemd-oomd || true
			sudo systemctl stop systemd-oomd || true
			sudo systemctl disable systemd-homed || true
			sudo systemctl stop systemd-homed || true
			sudo systemctl stop polkitd || true
			sudo dnf remove -y polkit || true

			sudo dnf install -y dropbear || { echo "Failed to install dropbear"; break; }
			sudo systemctl enable dropbear || { echo "Failed to enable dropbear"; break; }
			sudo systemctl start dropbear || { echo "Failed to start dropbear"; break; }

			sudo systemctl disable sshd || true
			sudo systemctl stop sshd || true
			sudo dnf install -y htop || { echo "Failed to install htop"; break; }

			sudo dnf copr enable -y bieszczaders/kernel-cachyos || { echo "Failed to enable COPR"; break; }
			sudo dnf install -y kernel-cachyos-rt kernel-cachyos-rt-devel-matched || { echo "Failed to install kernel"; break; }
			sudo grubby --update-kernel=ALL --args="audit=0 zswap.enabled=0 skew_tick=1 nosoftlockup default_hugepagesz=1G intel_pstate=enable" || { echo "Failed to update GRUB"; break; }
			echo "Optimization complete. System will reboot."
			sudo reboot
			;;

		# Compilation and installation of Diretta's drivers
    DirettaAlsa )
			echo "Starting Diretta ALSA driver installation..."
			SAVED_DIR=$(pwd)
			cd /home/"$USER" || { echo "Failed to change directory"; SAVED_DIR=""; break; }
			
			# backup existing settings
			if [ -f "DirettaAlsaHost/setting.inf" ]; then
				cp DirettaAlsaHost/setting.inf . || { echo "Failed to backup settings"; cd "$SAVED_DIR" 2>/dev/null; break; }
			fi
			
    		# checking for kernel's extraction script
			SCRIPT="/home/$USER/extract-vmlinux.sh"
			if [ ! -f "$SCRIPT" ]; then
				echo "extract-vmlinux.sh is not present in the expected directory"
				echo "Diretta drivers' compilation and installation are cancelled"
				echo ""
				cd "$SAVED_DIR" 2>/dev/null
				break
			fi

			# extracting the kernel from /boot/vmlinuz image
			/bin/bash /home/"$USER"/extract-vmlinux.sh /boot/vmlinuz-"$RELEASE" > vmlinux || { echo "Failed to extract vmlinux"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sudo cp vmlinux /usr/src/kernels/"$RELEASE"/. || { echo "Failed to copy vmlinux"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sudo install -D resolve_btfids /usr/src/kernels/"$RELEASE"/tools/bpf/resolve_btfids/resolve_btfids
#			sudo cp resolve_btfids /usr/src/kernels/"$RELEASE"/tools/bpf/resolve_btfids/. || { echo "Failed to copy resolve_btfids"; cd "$SAVED_DIR" 2>/dev/null; break; }

			# uncompressing Diretta drivers' directory
			tar --use-compress-program=unzstd -xvf DirettaAlsaHost_0_xxx_x.tar.zst || { echo "Failed to extract Diretta drivers"; cd "$SAVED_DIR" 2>/dev/null; break; }
			
			# drivers' compilation
			cd DirettaAlsaHost || { echo "Failed to enter DirettaAlsaHost directory"; cd "$SAVED_DIR" 2>/dev/null; break; }
			rm -f alsa_bridge.ko  alsa_bridge.mod  alsa_bridge.mod.c  alsa_bridge.mod.o  alsa_bridge.o modules.order  Module.symvers
			sudo make KCFLAGS="-march=x86-64-v4 -mtune=znver4 -O3" KERNELDIR=/usr/src/kernels/"$RELEASE"/ || { echo "Failed to compile drivers"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sudo cp alsa_bridge.ko /lib/modules/"$RELEASE"/. || { echo "Failed to copy driver"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sudo depmod || { echo "Failed to run depmod"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sudo modprobe alsa_bridge || { echo "Failed to load module"; cd "$SAVED_DIR" 2>/dev/null; break; }
			lsmod | grep alsa

			# choose your version of system and gcc compiler
			# utiliser 'uname -m' pour l'architecture de la machine
			# utiliser 'gcc -dumpversion' pour la version du compilateur
			cp syncAlsa_gcc15_x64_zen4 syncAlsa

			# driver's installation
			cd /home/"$USER" || { echo "Failed to return to home"; cd "$SAVED_DIR" 2>/dev/null; break; }
			a0="ConditionPathExists=\/home\/user\/master\/diretta\/sync\/salsa"
			b0="ConditionPathExists=\/home\/$USER\/DirettaAlsaHost"
			a1="ExecStart=\/home\/user\/master\/diretta\/sync\/salsa\/syncAlsa"
			b1="ExecStart=\/home\/$USER\/DirettaAlsaHost\/syncAlsa\ \/home\/user\/DirettaAlsaHost\/setting.inf"
			a2="ExecStop=\/home\/user\/master\/diretta\/sync\/salsa\/syncAlsa\ \kill"
			b2="ExecStop=\/home\/$USER\/DirettaAlsaHost\/syncAlsa\ \kill"
			a3="After=audirvanaStudio.service"
			b3="After=hqplayerd.service"
			a4="ExecStart=insmod\ \/home\/user\/master\/diretta\/sync\/salsa\/alsa_bridge.ko"
			b4='ExecStart=modprobe\ \alsa_bridge'

			# changing directory inside lauching scripts (using | as delimiter for clarity)
			sed -i "s|$a0|$b0|g" /home/"$USER"/DirettaAlsaHost/diretta_bridge_driver.service || { echo "Failed sed operation 1"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sed -i "s|$a4|$b4|g" /home/"$USER"/DirettaAlsaHost/diretta_bridge_driver.service || { echo "Failed sed operation 2"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sed -i "s|$a0|$b0|g" /home/"$USER"/DirettaAlsaHost/diretta_sync_host.service || { echo "Failed sed operation 3"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sed -i "s|$a1|$b1|g" /home/"$USER"/DirettaAlsaHost/diretta_sync_host.service || { echo "Failed sed operation 4"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sed -i "s|$a2|$b2|g" /home/"$USER"/DirettaAlsaHost/diretta_sync_host.service || { echo "Failed sed operation 5"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sed -i "s|$a3|$b3|g" /home/"$USER"/DirettaAlsaHost/diretta_sync_host.service || { echo "Failed sed operation 6"; cd "$SAVED_DIR" 2>/dev/null; break; }

			# copy launching scripts in appropriate system's directory
			sudo cp /home/"$USER"/DirettaAlsaHost/diretta_bridge_driver.service /etc/systemd/system/. || { echo "Failed to copy service file"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sudo cp /home/"$USER"/DirettaAlsaHost/diretta_sync_host.service /etc/systemd/system/. || { echo "Failed to copy service file"; cd "$SAVED_DIR" 2>/dev/null; break; }

			# allowing lauching scripts
			sudo systemctl enable diretta_bridge_driver || { echo "Failed to enable service"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sudo systemctl enable diretta_sync_host || { echo "Failed to enable service"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sudo grubby --update-kernel=ALL --args="audit=0" || { echo "Failed to update GRUB"; cd "$SAVED_DIR" 2>/dev/null; break; }

			# restoring settings' file
			PARAM="/home/$USER/DirettaAlsaHost/setting.inf"
			PARAMBAK="/home/$USER/setting.inf"
			if [ -f "$PARAMBAK" ]; then
				cp "$PARAMBAK" "$PARAM" || { echo "Failed to restore settings"; cd "$SAVED_DIR" 2>/dev/null; break; }
			fi

			echo "Diretta ALSA drivers installed successfully"
			cd "$SAVED_DIR" 2>/dev/null
   	;;

		# Installation of Diretta's MemoryPlay
    MemoryPlay )
			echo "Starting MemoryPlay installation..."
			SAVED_DIR=$(pwd)
			cd /home/"$USER" || { echo "Failed to change directory"; SAVED_DIR=""; break; }

			# uncompressing Diretta MemoryPlay directory
			if [ -f "MemoryPlay/memoryplayhost_setting.inf" ]; then
				cp MemoryPlay/memoryplayhost_setting.inf . || { echo "Failed to backup settings"; cd "$SAVED_DIR" 2>/dev/null; break; }
			fi
			
			# curl -OL https://www.diretta.link/preview/MemoryPlayHostLinux.tar.zst
			tar --use-compress-program=unzstd -xvf MemoryPlayHostLinux_0_144_3.tar.zst || { echo "Failed to extract MemoryPlay"; cd "$SAVED_DIR" 2>/dev/null; break; }
			cp memoryplayhost_setting.inf MemoryPlay/. || { echo "Failed to copy settings"; cd "$SAVED_DIR" 2>/dev/null; break; }

			# choose your version of system and gcc compiler
			# utiliser 'uname -m' pour l'architecture de la machine
			# utiliser 'gcc -dumpversion' pour la version du compilateur
			cd MemoryPlay || { echo "Failed to enter MemoryPlay directory"; cd "$SAVED_DIR" 2>/dev/null; break; }
			cp MemoryPlayHost_gcc15_x64_zen4 MemoryPlayHost || { echo "Failed to copy binary"; cd "$SAVED_DIR" 2>/dev/null; break; }
			chmod -x diretta_memoryplay_host.service

			# driver's installation
			cd /home/"$USER" || { echo "Failed to return to home"; cd "$SAVED_DIR" 2>/dev/null; break; }
			a0='ConditionPathExists=\/home\/user\/MemoryPlayHostLinux'
			b0="ConditionPathExists=\/home\/$USER\/MemoryPlay"
			a1="ExecStart=/home/user/MemoryPlayHostLinux/MemoryPlayHostLinux"
			b1="ExecStart=/home/$USER/MemoryPlay/MemoryPlayHost\ \/home\/$USER\/MemoryPlay\/memoryplayhost_setting.inf"

			# changing directory inside lauching scripts
			sed -i "s|$a0|$b0|g" /home/"$USER"/MemoryPlay/diretta_memoryplay_host.service || { echo "Failed sed operation"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sed -i "s|$a1|$b1|g" /home/"$USER"/MemoryPlay/diretta_memoryplay_host.service || { echo "Failed sed operation"; cd "$SAVED_DIR" 2>/dev/null; break; }

			# copy launching scripts in appropriate system's directory
			sudo cp /home/"$USER"/MemoryPlay/diretta_memoryplay_host.service /etc/systemd/system/. || { echo "Failed to copy service file"; cd "$SAVED_DIR" 2>/dev/null; break; }

			# allowing lauching scripts
			sudo systemctl enable diretta_memoryplay_host || { echo "Failed to enable service"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sudo grubby --update-kernel=ALL --args="audit=0" || { echo "Failed to update GRUB"; cd "$SAVED_DIR" 2>/dev/null; break; }

			echo "MemoryPlay installed successfully"
			cd "$SAVED_DIR" 2>/dev/null

  	;;

		# Installation of Diretta's MemoryPlayController
    MemoryPlayCtrl )
			echo "Starting MemoryPlayController installation..."
			SAVED_DIR=$(pwd)
			cd /home/"$USER" || { echo "Failed to change directory"; SAVED_DIR=""; break; }
			
			tar --use-compress-program=unzstd -xvf MemoryPlayControllerSDK_0_144_1.tar.zst || { echo "Failed to extract SDK"; cd "$SAVED_DIR" 2>/dev/null; break; }
#			curl --silent https://github.com/xiph/flac/releases/tag/1.4.3
			tar xvf flac-1.4.3.tar.xz || { echo "Failed to extract FLAC"; cd "$SAVED_DIR" 2>/dev/null; break; }
			mv flac-1.4.3/* MemoryPlayControllerSDK/flac/. || { echo "Failed to move FLAC"; cd "$SAVED_DIR" 2>/dev/null; break; }
			cd MemoryPlayControllerSDK/flac || { echo "Failed to enter FLAC directory"; cd "$SAVED_DIR" 2>/dev/null; break; }
			sh ./configure --disable-ogg --enable-static || { echo "Failed to configure FLAC"; cd "$SAVED_DIR" 2>/dev/null; break; }
			make KCFLAGS="-march=x86-64-v4 -mtune=znver4 -O3" -j6 || { echo "Failed to make FLAC"; cd "$SAVED_DIR" 2>/dev/null; break; }
			cd .. || { echo "Failed to return"; cd "$SAVED_DIR" 2>/dev/null; break; }
			
			# Fixed: Remove leading space from variable a
			a='LDFLAGS=\ \$(CCL_FLTO)\ -lm\ -pthread\ -lstdc++\ \$(LDFLAGS_APP)\ -static\ -O2'
			b='LDFLAGS=\ \$(CCL_FLTO)\ -lm\ -pthread\ -lstdc++\ \$(LDFLAGS_APP)\ -O2'
			sed -i "s|$a|$b|g" /home/"$USER"/MemoryPlayControllerSDK/Makefile || { echo "Failed sed operation"; cd "$SAVED_DIR" 2>/dev/null; break; }
			# make ARCH_NAME=x86_64-linux 
			make KCFLAGS="-march=x86-64-v4 -mtune=znver4 -O3" || { echo "Failed to make SDK"; cd "$SAVED_DIR" 2>/dev/null; break; }
			
			echo "MemoryPlayController compiled successfully"
			cd "$SAVED_DIR" 2>/dev/null
	  ;;

		Install_HQPe )
			echo "Starting HQPlayer Embedded installation..."
			
			# Version configuration
			LIBGMPRIS_VERSION="2.2.1-9"
			LIBGMPRIS_RPM="libgmpris-${LIBGMPRIS_VERSION}.fc42.x86_64.rpm"
			LIBGMPRIS_URL="https://www.sonarnerd.net/src/fc42/${LIBGMPRIS_RPM}"
			
			HQPLAYER_VERSION="5.15.2-43"
			HQPLAYER_RPM="hqplayerd-${HQPLAYER_VERSION}.fc42.x86_64.rpm"
			HQPLAYER_URL="https://www.signalyst.eu/bins/hqplayerd/fc42/${HQPLAYER_RPM}"
			
			# installing utility and HQPlayers Embedded
			# saving parameters file from previous version
			FILE="/etc/hqplayer/hqplayerd.xml"
			FILEBAK="/etc/hqplayer/hqplayerd_bak.xml"
			FILENEW="/etc/hqplayer/hqplayerd_new.xml"
			if [ -f "$FILE" ] ; then
				sudo cp "$FILE" "$FILEBAK" || { echo "Failed to backup config"; break; }
			fi

			# installing new version
			sudo dnf install "$LIBGMPRIS_URL" || { echo "Failed to install libgmpris"; break; }
			sudo dnf install "$HQPLAYER_URL" || { echo "Failed to install hqplayerd"; break; }

			# restoring old parameters file
			if [ -f "$FILEBAK" ] ; then
				# saving the new parameter file in case there is something to restore from it
				sudo cp "$FILE" "$FILENEW" || { echo "Failed to save new config"; break; }
				# restoring the previous parameter file
				sudo cp "$FILEBAK" "$FILE" || { echo "Failed to restore config"; break; }
			fi			

			# enabling HQPlayer
			sudo systemctl enable hqplayerd || { echo "Failed to enable service"; break; }
			sudo systemctl start hqplayerd || { echo "Failed to start service"; break; }

			# offering to change userid and password for HQPe
			echo ""
			echo "Would you like to change userid and password for HQPlayer?"
			select yn in "Yes" "No" ; do
				case $yn in 
					Yes )
						echo "The username will be: $USER"
						read -rp "Please enter the password for HQPlayer's web interface: " USER_PWD
						echo ""
						echo "Is this configuration correct?"
						echo "  Username: $USER"
						echo "  Password: (hidden)"
						select yn2 in "Yes" "No" ; do
							case $yn2 in 
								Yes )
									# Fixed: Use echo piping instead of here-doc for better portability
									echo "$USER_PWD" | sudo hqplayerd -s "$USER" || { echo "Failed to set credentials"; break 2; }
									sudo systemctl restart hqplayerd || { echo "Failed to restart service"; break 2; }
									echo "Credentials updated successfully"
									break 2 ;;
								No )
									break ;;
						    esac
						done					
						break ;;
					No )
						echo "Using default HQPlayer credentials"
						break ;;
			    esac
			done

			echo "HQPlayer Embedded installed successfully"
			;;

      Install_NAA )
			echo "Starting Network Audio Adapter installation..."
			
			# Version configuration
			LIBGMPRIS_VERSION="2.2.1-9"
			LIBGMPRIS_RPM="libgmpris-${LIBGMPRIS_VERSION}.fc42.x86_64.rpm"
			LIBGMPRIS_URL="https://www.sonarnerd.net/src/fc42/${LIBGMPRIS_RPM}"
			
			NAA_VERSION="5.1.5-24"
			NAA_RPM="networkaudiod-${NAA_VERSION}.fc42.x86_64.rpm"
			NAA_URL="https://www.signalyst.eu/bins/naa/linux/fc42/${NAA_RPM}"
			
			# installing utility and HQPlayers' Network Audio Adapter
			sudo dnf install "$LIBGMPRIS_URL" || { echo "Failed to install libgmpris"; break; }
			sudo dnf install "$NAA_URL" || { echo "Failed to install networkaudiod"; break; }
			sudo systemctl enable networkaudiod || { echo "Failed to enable service"; break; }
			sudo systemctl start networkaudiod || { echo "Failed to start service"; break; }
			
			echo "Network Audio Adapter installed successfully"
			;;

      Remove_Diretta )
			echo "Removing Diretta components..."
			sudo systemctl disable diretta_bridge_driver || true
			sudo systemctl stop diretta_bridge_driver || true
			sudo systemctl stop diretta_sync_host || true
			sudo systemctl disable diretta_sync_host || true
			sudo systemctl disable diretta_memoryplay_host 2>/dev/null || true
			sudo systemctl stop diretta_memoryplay_host 2>/dev/null || true
			sudo rmmod alsa_bridge 2>/dev/null || true
			sudo rm -f /etc/systemd/system/diretta_*.service || true
			sudo systemctl daemon-reload || true
			
			echo "Diretta components removed successfully"
			;;

		  Remove_HQPe )
			echo "Removing HQPlayer Embedded..."
			sudo systemctl stop hqplayerd || true
			sudo systemctl disable hqplayerd || true
			
			echo "HQPlayer Embedded removed successfully"
			;;

      Remove_NAA )
			echo "Removing Network Audio Adapter..."
			sudo systemctl stop networkaudiod || true
			sudo systemctl disable networkaudiod || true
			
			echo "Network Audio Adapter removed successfully"
			;;

		  Network_Bridge )
			echo ""
			echo "Configuring network bridge for Diretta interface..."
			echo ""
			
			# Display current network status
			nmcli -f DEVICE,TYPE,IP4-CONNECTIVITY,CONNECTION device

			read -rp "Please enter the first interface name: " ifname1
			read -rp "Please enter the second interface name: " ifname2
			
			# Input validation
			if [ -z "$ifname1" ] || [ -z "$ifname2" ]; then
				echo "Error: Interface names cannot be empty"
				break
			fi
			
			echo ""
			echo "The interface names you entered are: $ifname1 and $ifname2"
			echo "Is this correct ?"
			select yn in "Yes" "No" ; do
				case $yn in 
					Yes )
						# disabling ipv4, enabling ipv6 link-local setting route metric
						sudo nmcli con add ifname br0 type bridge con-name br0 || { echo "Failed to create bridge"; break 2; }
						sudo nmcli con add type bridge-slave ifname "$ifname1" master br0 || { echo "Failed to add $ifname1"; break 2; }
						sudo nmcli con add type bridge-slave ifname "$ifname2" master br0 || { echo "Failed to add $ifname2"; break 2; }
						sudo nmcli con mod br0 ipv4.method static ipv4.address 192.168.1.24/24 ipv4.gateway 192.168.1.1 ipv4.dns 8.8.8.8,8.8.4.4 || { echo "Failed to configure br0"; break 2; }
						sudo nmcli con mod br0 ipv6.method link-local ipv6.route-metric 100 connection.autoconnect yes || { echo "Failed to configure IPv6"; break 2; }
						sudo nmcli con down "$ifname1" 2>/dev/null || true
						sudo nmcli con down "$ifname2" 2>/dev/null || true
						sudo nmcli con up br0 || { echo "Failed to activate bridge"; break 2; }
						
						echo "Bridge configured successfully"
						break 2 ;;
					No )
						break ;;
			    esac
			done
			;;

		Status )
			echo ""
			echo "=== System Component Status ==="
			echo ""
			
			echo "HQPlayer Embedded:"
			sudo systemctl is-enabled hqplayerd >/dev/null 2>&1 && echo "  ✓ Enabled" || echo "  ✗ Not enabled"
			sudo systemctl is-active hqplayerd >/dev/null 2>&1 && echo "  ✓ Running" || echo "  ✗ Not running"
			echo ""
			
			echo "Network Audio Adapter:"
			sudo systemctl is-enabled networkaudiod >/dev/null 2>&1 && echo "  ✓ Enabled" || echo "  ✗ Not enabled"
			sudo systemctl is-active networkaudiod >/dev/null 2>&1 && echo "  ✓ Running" || echo "  ✗ Not running"
			echo ""
			
			echo "Diretta Bridge Driver:"
			sudo systemctl is-enabled diretta_bridge_driver >/dev/null 2>&1 && echo "  ✓ Enabled" || echo "  ✗ Not enabled"
			sudo systemctl is-active diretta_bridge_driver >/dev/null 2>&1 && echo "  ✓ Running" || echo "  ✗ Not running"
			echo ""
			
			echo "Diretta Sync Host:"
			sudo systemctl is-enabled diretta_sync_host >/dev/null 2>&1 && echo "  ✓ Enabled" || echo "  ✗ Not enabled"
			sudo systemctl is-active diretta_sync_host >/dev/null 2>&1 && echo "  ✓ Running" || echo "  ✗ Not running"
			echo ""
			
			echo "Diretta MemoryPlay:"
			sudo systemctl is-enabled diretta_memoryplay_host >/dev/null 2>&1 && echo "  ✓ Enabled" || echo "  ✗ Not enabled"
			sudo systemctl is-active diretta_memoryplay_host >/dev/null 2>&1 && echo "  ✓ Running" || echo "  ✗ Not running"
			echo ""
			
			echo "ALSA Bridge Module:"
			lsmod | grep -q alsa_bridge && echo "  ✓ Loaded" || echo "  ✗ Not loaded"
			echo ""
			;;

		reboot )
			echo "System will reboot now..."
			sudo reboot
    ;;

		exit )
			echo "Exiting..."
			exit 0
		;;
    esac
done
