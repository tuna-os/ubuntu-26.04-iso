#!/usr/bin/bash
# Live-environment setup for the Ubuntu 26.04 ISO installer image.
#
# Runs inside the final Ubuntu container stage with:
#   --cap-add sys_admin --security-opt label=disable
#
# Handles: liveuser, GDM3 autologin, dconf, AppArmor masking, tmpfs,
# tuna-installer autostart + polkit, VFS storage config, skopeo wrapper.

set -exo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Live user ─────────────────────────────────────────────────────────────────
useradd --create-home --uid 1000 --user-group \
    --comment "Live User" liveuser || true
passwd --delete liveuser

# Debug builds: set password and enable SSH for testing
if [[ "${DEBUG:-0}" == "1" ]]; then
    echo "liveuser:live" | chpasswd
    passwd --unlock root
    echo "root:root" | chpasswd

    echo "liveuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/liveuser-debug
    chmod 440 /etc/sudoers.d/liveuser-debug

    mkdir -p /etc/systemd/system-preset
    echo "enable ssh.service" > /etc/systemd/system-preset/90-live-debug.preset
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /lib/systemd/system/ssh.service \
        /etc/systemd/system/multi-user.target.wants/ssh.service

    cat >> /etc/ssh/sshd_config << 'SSHEOF'
PermitEmptyPasswords no
PasswordAuthentication yes
PermitRootLogin yes
SSHEOF

    # Ubuntu uses ufw (not firewalld) — open SSH so port 22 is reachable from host
    ufw allow ssh 2>/dev/null || true

    cat > /usr/lib/systemd/system/debug-ssh-banner.service << 'BANNEREOF'
[Unit]
Description=Print SSH connection info to serial console
After=ssh.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
  IP=$(hostname -I | awk "{print \$1}"); \
  echo ""; \
  echo "========================================"; \
  echo " DEBUG SSH READY"; \
  echo " ssh liveuser@${IP:-<no-ip>}  (password: live)"; \
  echo " ssh root@${IP:-<no-ip>}      (password: root)"; \
  echo "========================================"; \
  echo ""'
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
BANNEREOF
    systemctl enable debug-ssh-banner.service
fi

# Passwordless sudo for liveuser
echo 'liveuser ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/liveuser
chmod 0440 /etc/sudoers.d/liveuser

# Skip gnome-initial-setup in the live session
mkdir -p /home/liveuser/.config
touch /home/liveuser/.config/gnome-initial-setup-done
chown -R liveuser:liveuser /home/liveuser/.config

# ── GDM3 autologin ────────────────────────────────────────────────────────────
# Ubuntu uses /etc/gdm3/custom.conf and the service is named gdm3
mkdir -p /etc/gdm3
cat > /etc/gdm3/custom.conf << 'GDMEOF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=liveuser
GDMEOF

# ── dconf: screensaver, sleep, and power policy ───────────────────────────────
# Ubuntu's default dconf profile references system-db:local.
# Ensure the profile exists and references our local db.
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d /etc/dconf/db/local.d/locks

cat > /etc/dconf/profile/user << 'PROFILEEOF'
user-db:user
system-db:local
PROFILEEOF

cat > /etc/dconf/db/local.d/50-live-iso << 'DCONFEOF'
[org/gnome/shell]
welcome-dialog-last-shown-version='999'
favorite-apps=['ubuntu-installer.desktop', 'org.mozilla.firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Console.desktop']

[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0
power-button-action='nothing'
DCONFEOF

cat > /etc/dconf/db/local.d/locks/50-live-iso << 'LOCKSEOF'
/org/gnome/shell/favorite-apps
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/idle-activation-enabled
/org/gnome/desktop/session/idle-delay
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-timeout
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-timeout
LOCKSEOF

dconf update

# ── Mask sleep/suspend targets and AppArmor ──────────────────────────────────
# AppArmor profiles restrict user namespace creation and mount operations that
# podman/skopeo/bootc need during install.  The kernel cmdline already includes
# apparmor=0; mask the service here as belt-and-suspenders.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target \
    apparmor.service

# ── /var/tmp tmpfs ────────────────────────────────────────────────────────────
# The live overlayfs puts /var on a small RAM overlay.  bootc and skopeo need
# substantial space in /var/tmp when staging an install; mount a dedicated tmpfs.
cat > /usr/lib/systemd/system/var-tmp.mount << 'UNITEOF'
[Unit]
Description=Large tmpfs for /var/tmp in the live environment

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=8G,nr_inodes=1m

[Install]
WantedBy=local-fs.target
UNITEOF
systemctl enable var-tmp.mount

mkdir -p /var/fisherman-tmp

# ── Live hostname ─────────────────────────────────────────────────────────────
mkdir -p /usr/lib/tmpfiles.d
echo 'f /etc/hostname 0644 - - - ubuntu-live' > /usr/lib/tmpfiles.d/live-hostname.conf

# ── tuna-installer desktop entry override ────────────────────────────────────
INSTALLER_APP_ID="org.bootcinstaller.Installer"
[[ "${INSTALLER_CHANNEL:-stable}" == "dev" ]] && INSTALLER_APP_ID="org.bootcinstaller.Installer.Devel"

mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/${INSTALLER_APP_ID}.desktop << DESKTOPEOF
[Desktop Entry]
Name=Ubuntu Installer
Exec=/usr/bin/flatpak run --env=VANILLA_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json ${INSTALLER_APP_ID}
Icon=distributor-logo-ubuntu
Terminal=false
Type=Application
Categories=GTK;System;Settings;
StartupNotify=true
X-Flatpak=${INSTALLER_APP_ID}
DESKTOPEOF

mkdir -p /usr/share/applications
cat > /usr/share/applications/ubuntu-installer.desktop << DTEOF
[Desktop Entry]
Name=Ubuntu Installer
Comment=Install Ubuntu 26.04 to your computer
Exec=flatpak run --env=VANILLA_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json ${INSTALLER_APP_ID}
Icon=distributor-logo-ubuntu
Type=Application
Categories=System;
NoDisplay=false
DTEOF

# ── Installer configuration ───────────────────────────────────────────────────
mkdir -p /etc/bootc-installer
cp "$SCRIPT_DIR/etc/bootc-installer/images.json" /etc/bootc-installer/images.json
cp "$SCRIPT_DIR/etc/bootc-installer/recipe.json" /etc/bootc-installer/recipe.json
touch /etc/bootc-installer/live-iso-mode

# ── Installer autostart ───────────────────────────────────────────────────────
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/tuna-installer.desktop << DTEOF
[Desktop Entry]
Name=Ubuntu Installer
Exec=flatpak run --env=VANILLA_CUSTOM_RECIPE=/run/host/etc/bootc-installer/recipe.json ${INSTALLER_APP_ID}
Icon=distributor-logo-ubuntu
Type=Application
X-GNOME-Autostart-enabled=true
DTEOF

# ── Polkit rules for live installer ──────────────────────────────────────────
INSTALLER_APP_DIR=$(find /var/lib/flatpak/app/${INSTALLER_APP_ID} -name fisherman -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
if [ -n "$INSTALLER_APP_DIR" ]; then
    mkdir -p /usr/local/bin
    ln -sf "${INSTALLER_APP_DIR}/fisherman" /usr/local/bin/fisherman
fi

mkdir -p /usr/share/polkit-1/actions
cat > /usr/share/polkit-1/actions/org.bootcinstaller.Installer.policy << 'POLICYEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
  "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
  "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="org.tunaos.Installer.install">
    <description>Install an operating system to disk</description>
    <message>Authentication is required to install an operating system</message>
    <icon_name>drive-harddisk</icon_name>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/bin/fisherman</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
POLICYEOF

mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/99-live-installer.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id === "org.freedesktop.policykit.exec" ||
         action.id === "org.tunaos.Installer.install") &&
            subject.user === "liveuser" && subject.local) {
        return polkit.Result.YES;
    }
});
EOF

# ── ZFS install helper ────────────────────────────────────────────────────────
# Drop the ZFS root installer script into the live image so users and tuna-installer
# can invoke it for ZFS-root installs.  Also create a desktop entry for quick access.
install -m 755 "$SCRIPT_DIR/zfs-install.sh" /usr/local/bin/zfs-install

mkdir -p /usr/share/applications
cat > /usr/share/applications/zfs-install.desktop << 'ZFSEOF'
[Desktop Entry]
Name=Install to ZFS
Comment=Install Ubuntu 26.04 with ZFS root filesystem
Exec=bash -c 'zenity --info --text="Run: sudo zfs-install /dev/sdX" --title="ZFS Install" || xterm -e "sudo zfs-install --help; bash"'
Icon=drive-harddisk
Terminal=false
Type=Application
Categories=System;
NoDisplay=true
ZFSEOF

# ── Live-ready marker service ─────────────────────────────────────────────────
# Prints a unique token to the serial console after the display manager starts.
# CI greps for this token to confirm the live session reached the desktop.
cat > /usr/lib/systemd/system/live-ready.service << 'UNITEOF'
[Unit]
Description=Live environment ready marker
After=display-manager.service
Requires=display-manager.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo "UBUNTU26_LIVE_READY"'
StandardOutput=journal+console

[Install]
WantedBy=graphical.target
UNITEOF
systemctl enable live-ready.service

echo "configure-live.sh: done"
