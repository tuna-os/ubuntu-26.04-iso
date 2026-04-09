#!/usr/bin/bash
# Live-environment setup for the Ubuntu 26.04 ISO installer image.
#
# Runs inside the final Ubuntu container stage with:
#   --cap-add sys_admin --security-opt label=disable
#
# At this point the dmsquash-live initramfs has already been built (in the
# Containerfile RUN step before this script).  This script handles the runtime
# live environment: liveuser, GDM3 autologin, dconf, tmpfs, VFS storage config,
# and skopeo/podman wrappers for offline bootc install support.

set -exo pipefail

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

# ── Polkit: allow liveuser to run pkexec without password ─────────────────────
# Lets liveuser run `sudo bootc install to-disk` without a password prompt.
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/99-live-installer.rules << 'EOF'
polkit.addRule(function(action, subject) {
    if (action.id === "org.freedesktop.policykit.exec" &&
            subject.user === "liveuser" && subject.local) {
        return polkit.Result.YES;
    }
});
EOF

# ── Install instructions on the desktop ───────────────────────────────────────
# Drop a README on liveuser's desktop so it's immediately visible
mkdir -p /home/liveuser/Desktop
cat > /home/liveuser/Desktop/INSTALL.txt << 'READMEEOF'
Ubuntu 26.04 Live (Resolute Raccoon)
=====================================

To install to disk, open a terminal and run:

  sudo bootc install to-disk --source-imgref ghcr.io/hanthor/ubuntu-26.04-desktop-bootc:latest /dev/sda

Replace /dev/sda with your target drive. Requires internet access.

WARNING: This will erase the target drive completely.
READMEEOF
chown -R liveuser:liveuser /home/liveuser/Desktop

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
