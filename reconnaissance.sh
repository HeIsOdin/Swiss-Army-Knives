#!/usr/bin/env bash
set -u
set -o pipefail

REMOTE_URL="https://github.com/K3rn4lp4n1c/eCitadel-2026-WWW.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"

# When run with sudo, keep writing to the invoking user's repo instead of /root.
if [[ -n "${ECITADEL_REPO:-}" ]]; then
  BASE="$ECITADEL_REPO"
elif [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  SUDO_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  BASE="${SUDO_HOME:-$HOME}/ecitadel_www_repo"
else
  BASE="$HOME/ecitadel_www_repo"
fi

HOST="$(hostname -s 2>/dev/null || echo unknown-host)"
TS="$(date +%F_%H%M%S)"
SNAP_REL="snapshots/${HOST}_${TS}"
SNAP="$BASE/$SNAP_REL"
REPORT="$SNAP/recon_report.txt"
BACKUP="$BASE/local_only/${HOST}_${TS}.tar"
IS_ROOT="no"
[[ "$EUID" -eq 0 ]] && IS_ROOT="yes"
GIT_AVAILABLE="yes"
command -v git >/dev/null 2>&1 || GIT_AVAILABLE="no"

# Optional allow-list for competition authorized users. One username per line.
AUTHORIZED_USERS_FILE="${AUTHORIZED_USERS_FILE:-}"
if [[ -z "$AUTHORIZED_USERS_FILE" ]]; then
  if [[ -f "$SCRIPT_DIR/authorized_users.txt" ]]; then
    AUTHORIZED_USERS_FILE="$SCRIPT_DIR/authorized_users.txt"
  elif [[ -f "$BASE/authorized_users.txt" ]]; then
    AUTHORIZED_USERS_FILE="$BASE/authorized_users.txt"
  fi
fi

log(){ echo "[*] $1"; }
warn(){ echo "[!] $1"; }

init_workspace() {
  mkdir -p "$SNAP" "$BASE/local_only"

  if [[ "$GIT_AVAILABLE" != "yes" ]]; then
    warn "git is not installed; snapshot will be written locally but not committed."
    return 0
  fi

  if [[ ! -d "$BASE/.git" ]]; then
    git init "$BASE" >/dev/null 2>&1 || true
    cd "$BASE" || exit 1
    git branch -M main 2>/dev/null || true
    git remote add origin "$REMOTE_URL" 2>/dev/null || true
  else
    cd "$BASE" || exit 1
    git remote get-url origin >/dev/null 2>&1 || git remote add origin "$REMOTE_URL" 2>/dev/null || true
  fi

  git config user.name >/dev/null 2>&1 || git config user.name "eCitadel Defender"
  git config user.email >/dev/null 2>&1 || git config user.email "defender@localhost"
}

section() {
  local title="$1"
  local cmd="$2"

  log "$title"
  {
    echo
    echo "================================================================"
    echo "SECTION: $title"
    echo "TIME: $(date)"
    echo "================================================================"
    echo
    bash -lc "$cmd" 2>&1
  } >> "$REPORT"
}

copy_if_exists() {
  [[ -e "$1" ]] || return 0
  mkdir -p "$(dirname "$2")"
  cp -a "$1" "$2" 2>/dev/null || true
}

copy_tree() {
  [[ -d "$1" ]] || return 0
  local src="$1"
  local dest="$2"

  mkdir -p "$dest"

  tar -C "$src" \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='vendor' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='*.log' \
    --exclude='*.sql' \
    --exclude='*.sqlite' \
    --exclude='*.sqlite3' \
    --exclude='*.db' \
    --exclude='*.tar' \
    --exclude='*.tar.gz' \
    --exclude='*.tgz' \
    --exclude='*.zip' \
    --exclude='VBoxGuestAdditions-*' \
    --exclude='biafra' \
    --exclude='ssh_host_*_key' \
    --exclude='id_rsa' \
    --exclude='id_dsa' \
    --exclude='id_ecdsa' \
    --exclude='id_ed25519' \
    --exclude='*.pem' \
    --exclude='*.key' \
    -cf - . 2>/dev/null \
    | tar -C "$dest" -xf - 2>/dev/null || true
}

make_tar_backup() {
  log "Creating local tar backup"

  # local_only is intentionally not added to git by this script.
  # This local tar may contain sensitive files and is for rollback only.
  tar --xattrs --acls --selinux -cpf "$BACKUP" \
    /etc/nginx \
    /etc/apache2 \
    /etc/httpd \
    /etc/php \
    /etc/php-fpm.d \
    /etc/ssh \
    /etc/systemd/system \
    /etc/sssd \
    /etc/krb5.conf \
    /etc/samba/smb.conf \
    /etc/ufw \
    /etc/iptables \
    /etc/firewalld \
    /etc/nftables.conf \
    /var/www \
    /srv \
    /opt \
    /usr/local/bin \
    /usr/local/sbin \
    2>/dev/null || true
}

copy_snapshot_files() {
  log "Copying config and source candidates"

  copy_if_exists /etc/passwd "$SNAP/etc/passwd"
  copy_if_exists /etc/group "$SNAP/etc/group"
  copy_if_exists /etc/hosts "$SNAP/etc/hosts"
  copy_if_exists /etc/resolv.conf "$SNAP/etc/resolv.conf"
  copy_if_exists /etc/nsswitch.conf "$SNAP/etc/nsswitch.conf"
  copy_if_exists /etc/krb5.conf "$SNAP/etc/krb5.conf"
  copy_if_exists /etc/samba/smb.conf "$SNAP/etc/samba/smb.conf"
  copy_if_exists /etc/nftables.conf "$SNAP/etc/nftables.conf"

  copy_tree /etc/ssh "$SNAP/etc/ssh"
  copy_tree /etc/nginx "$SNAP/etc/nginx"
  copy_tree /etc/apache2 "$SNAP/etc/apache2"
  copy_tree /etc/httpd "$SNAP/etc/httpd"
  copy_tree /etc/php "$SNAP/etc/php"
  copy_tree /etc/php-fpm.d "$SNAP/etc/php-fpm.d"
  copy_tree /etc/systemd/system "$SNAP/etc/systemd/system"
  copy_tree /etc/sssd "$SNAP/etc/sssd"
  copy_tree /etc/ufw "$SNAP/etc/ufw"
  copy_tree /etc/iptables "$SNAP/etc/iptables"
  copy_tree /etc/firewalld "$SNAP/etc/firewalld"

  copy_tree /var/www "$SNAP/var/www"
  copy_tree /srv "$SNAP/srv"
  copy_tree /opt "$SNAP/opt"
  copy_tree /usr/local/bin "$SNAP/usr/local/bin"
  copy_tree /usr/local/sbin "$SNAP/usr/local/sbin"
}

remove_push_unsafe_files() {
  log "Removing files that should not be pushed"

  # Keep private material only in local_only tar backups, never in committed snapshots.
  find "$SNAP" -type f \( \
    -name "ssh_host_*_key" -o \
    -name "id_rsa" -o \
    -name "id_dsa" -o \
    -name "id_ecdsa" -o \
    -name "id_ed25519" -o \
    -name "*.pem" -o \
    -name "*.key" \
  \) ! -name "*.pub" -delete 2>/dev/null || true

  # Avoid creating privileged executable copies inside the Git snapshot.
  find "$SNAP" -type f \( -perm -4000 -o -perm -2000 \) -exec chmod ug-s {} \; 2>/dev/null || true
}

commit_snapshot() {
  if [[ "$GIT_AVAILABLE" != "yes" ]]; then
    return 0
  fi

  cd "$BASE" || exit 1
  git add "$SNAP_REL"

  if git diff --cached --quiet; then
    echo "[*] No snapshot changes to commit."
  else
    git commit -m "Add web snapshot for $HOST at $TS" || {
      echo "[!] Git commit failed. Check git status/config."
      return 0
    }
  fi
}

fix_ownership() {
  if [[ "$EUID" -eq 0 && -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" && -d "$BASE" ]]; then
    chown -R "$SUDO_UID:$SUDO_GID" "$BASE" 2>/dev/null || true
  fi
}

main() {
  if [[ "$IS_ROOT" != "yes" ]]; then
    warn "Not running as root. Report will be marked incomplete. Run with sudo for full results."
  fi

  init_workspace

  {
    echo "eCitadel Web Server Recon Report"
    echo "host=$HOST"
    echo "timestamp=$TS"
    echo "repo=$REMOTE_URL"
    echo "snapshot=$SNAP"
    echo "ran_as_root=$IS_ROOT"
    if [[ -n "$AUTHORIZED_USERS_FILE" ]]; then
      echo "authorized_users_file=$AUTHORIZED_USERS_FILE"
    else
      echo "authorized_users_file=not_provided"
    fi
    if [[ "$IS_ROOT" != "yes" ]]; then
      echo "report_status=INCOMPLETE_NON_ROOT"
      echo "note=Some firewall, process-owner, package-integrity, auth-log, and protected-file checks may be missing or incomplete."
    else
      echo "report_status=FULL_ROOT_ATTEMPT"
    fi
  } > "$REPORT"

  section "00_quick_triage_summary" '
echo "[Open scored-looking ports]"
ss -tulpn | egrep ":22|:80|:443|:8080|:8000|:3000|:5000|:8443|:3306|:5432" || true
echo

echo "[Likely web stack]"
ps auxww | egrep -i "nginx|apache|httpd|caddy|php-fpm|node|pm2|gunicorn|uwsgi|tomcat|flask|django|rails|puma" | grep -v egrep || true
echo

echo "[Likely web/app roots]"
find /var/www /srv /opt -maxdepth 4 \
  \( -path "/opt/VBoxGuestAdditions-*" -o -path "/srv/www/biafra" -o -path "/srv/www/biafra/*" -o -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -type f \( -name "index.*" -o -name "app.py" -o -name "wsgi.py" -o -name "manage.py" -o -name "package.json" -o -name "composer.json" -o -name "wp-config.php" -o -name "settings.py" \) -print 2>/dev/null | head -120 || true
echo

echo "[Immediate sensitive-file red flags under app roots]"
find /var/www /srv /opt -maxdepth 6 \
  \( -path "/opt/VBoxGuestAdditions-*" -o -path "/srv/www/biafra" -o -path "/srv/www/biafra/*" -o -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -type f \( -name ".env" -o -name ".env.*" -o -name "*.sqlite" -o -name "*.sqlite3" -o -name "*.db" -o -name "*.jsonl" -o -name "*.bak" -o -name "*.old" -o -name "*.save" \) -ls 2>/dev/null | head -120 || true
'

  section "01_environment" '
echo "[Identity]"
hostname -f 2>/dev/null || hostname
cat /etc/os-release 2>/dev/null || true
uname -a
uptime
echo

echo "[Privilege status]"
id
echo "EUID=$EUID"
if [ "$EUID" -ne 0 ]; then
  echo "INCOMPLETE: not running as root"
else
  echo "Running as root"
fi
echo

echo "[Virtualization / container hints]"
systemd-detect-virt 2>/dev/null || true
grep -qi microsoft /proc/version 2>/dev/null && echo "WSL detected" || echo "WSL signature not detected"
echo

echo "[Logged-in/recent sessions]"
who || true
last -a | head -40 || true
'

  section "02_network_and_ports" '
echo "[Addresses]"
ip -br addr || true
echo

echo "[Routes]"
ip route || true
echo

echo "[Listening sockets with processes]"
ss -tulpn || true
echo

echo "[Established/recent TCP sockets]"
ss -tanp 2>/dev/null | head -150 || true
echo

echo "[DNS]"
cat /etc/resolv.conf 2>/dev/null || true
command -v resolvectl >/dev/null 2>&1 && resolvectl status 2>/dev/null | head -120 || true
'

  section "03_services_processes_packages" '
echo "[Systemd failed/running/enabled]"
if [ -d /run/systemd/system ]; then
  systemctl --failed --no-pager || true
  echo
  systemctl list-units --type=service --state=running --no-pager || true
  echo
  systemctl list-unit-files --state=enabled --no-pager || true
else
  echo "systemd is not active or not available."
fi
echo

echo "[Web/security relevant process list]"
ps auxww | egrep -i "apache|nginx|httpd|caddy|php|php-fpm|node|npm|pm2|gunicorn|uwsgi|tomcat|flask|django|python|perl|ruby|java|bash|sh|nc |ncat|socat|curl|wget|ssh|cron" | grep -v egrep || true
echo

echo "[Top processes]"
ps -eo user,pid,ppid,stat,%cpu,%mem,etime,cmd --sort=-%cpu | head -80 || true
echo

echo "[Relevant installed packages]"
if command -v dpkg-query >/dev/null 2>&1; then
  dpkg-query -W 2>/dev/null | egrep -i "nginx|apache|httpd|openssh|php|python3-flask|gunicorn|uwsgi|nodejs|npm|mysql|mariadb|postgres|redis|tomcat|sssd|realmd|samba|krb5|ufw|iptables|nftables|firewalld" || true
elif command -v rpm >/dev/null 2>&1; then
  rpm -qa | egrep -i "nginx|apache|httpd|openssh|php|python3-flask|gunicorn|uwsgi|nodejs|npm|mysql|mariadb|postgres|redis|tomcat|sssd|realmd|samba|krb5|ufw|iptables|nftables|firewalld" || true
fi
'

  section "04_users_ssh_privilege" "
echo '[Users with login shells - local /etc/passwd]'
awk -F: '\''\\$7 ~ /(bash|sh|zsh|ksh)$/ {print \\$1 ":" \\$7}'\'' /etc/passwd 2>/dev/null || true
echo

echo '[Users with login shells - NSS/domain aware]'
getent passwd 2>/dev/null | awk -F: '\''\\$7 ~ /(bash|sh|zsh|ksh)$/ {print \\$1 ":" \\$7}'\'' | head -300 || true
echo

echo '[UID 0 accounts]'
getent passwd 2>/dev/null | awk -F: '\''\\$3 == 0 {print}'\'' || true
echo

echo '[sudo/wheel/admin groups]'
getent group sudo 2>/dev/null || true
getent group wheel 2>/dev/null || true
getent group admin 2>/dev/null || true
echo

echo '[authorized user comparison]'
if [ -n '$AUTHORIZED_USERS_FILE' ] && [ -f '$AUTHORIZED_USERS_FILE' ]; then
  tmp_current=\\$(mktemp)
  tmp_auth=\\$(mktemp)
  getent passwd 2>/dev/null | awk -F: '\''\\$7 ~ /(bash|sh|zsh|ksh)$/ {print \\$1}'\'' | sort -u > "\\$tmp_current"
  grep -Ev '^\s*(#|$)' '$AUTHORIZED_USERS_FILE' | sort -u > "\\$tmp_auth"
  echo 'Users with shell not in authorized list:'
  comm -23 "\\$tmp_current" "\\$tmp_auth" || true
  echo
  echo 'Authorized users not currently found with shell:'
  comm -13 "\\$tmp_current" "\\$tmp_auth" || true
  rm -f "\\$tmp_current" "\\$tmp_auth"
else
  echo 'No authorized_users.txt provided; skipping whitelist comparison.'
fi
echo

echo '[sudoers files]'
ls -la /etc/sudoers /etc/sudoers.d 2>/dev/null || true
echo

echo '[SSH listening check]'
ss -tulpn | egrep ':22|sshd|ssh' || echo 'No obvious SSH listener found.'
echo

if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ] || [ -f /etc/ssh/sshd_config ]; then
  SSHD_BIN=\\$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
  echo '[sshd syntax test]'
  "\\$SSHD_BIN" -t 2>&1 || true
  echo
  echo '[Effective SSH config]'
  "\\$SSHD_BIN" -T 2>&1 | egrep 'port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|permitemptypasswords|allowusers|allowgroups|maxauthtries|maxsessions|x11forwarding|allowtcpforwarding|gatewayports|authorizedkeysfile|usepam|subsystem' || true
else
  echo 'OpenSSH server config not detected; skipping sshd -t/sshd -T.'
fi
echo

echo '[sshd_config.d contents]'
ls -la /etc/ssh/sshd_config.d 2>/dev/null || true
for f in /etc/ssh/sshd_config.d/*.conf; do
  [ -f "\\$f" ] && echo "--- \\$f ---" && sed -n '1,180p' "\\$f"
done
echo

echo '[authorized_keys files]'
find /root /home -maxdepth 3 -name authorized_keys -type f -ls 2>/dev/null || true
"

  section "05_domain_context" '
echo "[realm]"
realm list 2>/dev/null || echo "realm unavailable/no realm info"
echo

echo "[SSSD/Winbind/Kerberos files]"
ls -la /etc/sssd /etc/krb5.conf /etc/samba/smb.conf /etc/nsswitch.conf 2>/dev/null || true
echo

echo "[Domain-related processes]"
ps auxww | egrep -i "sssd|winbind|realmd|krb5|samba|smbd|nmbd" | grep -v egrep || true
echo

echo "[Name service switch]"
sed -n "1,220p" /etc/nsswitch.conf 2>/dev/null || true
echo

echo "[Domain-related sudo/SSH references]"
grep -RInE "sudo|wheel|admin|domain|sss|ldap|krb5|AllowUsers|AllowGroups" /etc/sudoers /etc/sudoers.d /etc/sssd /etc/ssh 2>/dev/null | head -300 || true
'

  section "06_persistence" '
echo "[Cron files]"
ls -la /etc/crontab /etc/cron* /var/spool/cron /var/spool/cron/crontabs 2>/dev/null || true
echo

echo "[Root/current crontab]"
crontab -l 2>/dev/null || true
echo

echo "[All readable user crontabs]"
for u in $(cut -d: -f1 /etc/passwd 2>/dev/null); do
  out=$(crontab -l -u "$u" 2>/dev/null || true)
  if [ -n "$out" ]; then
    echo "--- crontab for $u ---"
    echo "$out"
  fi
done
echo

echo "[Systemd timers/services modified recently]"
if [ -d /run/systemd/system ]; then
  systemctl list-timers --all --no-pager || true
else
  echo "systemd unavailable."
fi
echo
find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system -type f -mtime -30 -ls 2>/dev/null | head -300 || true
echo

echo "[Suspicious persistence strings]"
grep -RInE "nc |ncat|socat|bash -i|/dev/tcp|curl .*sh|wget .*sh|base64|python.*socket|perl.*socket|php .* -r|chmod \+s|chattr \+i" /etc/systemd /etc/cron* /var/spool/cron* 2>/dev/null | head -300 || true
'

  section "07_binary_and_permission_risks" '
echo "[SUID files]"
find / -xdev \
  \( -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -perm -4000 -type f -ls 2>/dev/null | head -300 || true
echo

echo "[SGID files]"
find / -xdev \
  \( -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -perm -2000 -type f -ls 2>/dev/null | head -300 || true
echo

echo "[Linux file capabilities]"
command -v getcap >/dev/null 2>&1 && getcap -r / 2>/dev/null | egrep -v "/ecitadel_www_repo/" | head -300 || echo "getcap unavailable"
echo

echo "[Executable files in risky writable/app locations]"
find /tmp /var/tmp /dev/shm /var/www /srv /opt \
  \( -path "/opt/VBoxGuestAdditions-*" -o -path "/srv/www/biafra" -o -path "/srv/www/biafra/*" -o -path "/tmp/VSLiveshareLogs/*" -o -path "/tmp/python-languageserver-cancellation/*" -o -path "/tmp/pyright-*/*" -o -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -type f -perm /111 -ls 2>/dev/null | head -300 || true
echo

echo "[ELF/scripts in risky writable or app locations]"
find /tmp /var/tmp /dev/shm /var/www /srv /opt \
  \( -path "/opt/VBoxGuestAdditions-*" -o -path "/srv/www/biafra" -o -path "/srv/www/biafra/*" -o -path "/tmp/VSLiveshareLogs/*" -o -path "/tmp/python-languageserver-cancellation/*" -o -path "/tmp/pyright-*/*" -o -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -type f -exec file {} \; 2>/dev/null | egrep "ELF|executable|script|shared object" | head -300 || true
echo

echo "[Recently modified files in high-value locations]"
find /usr/local/bin /usr/local/sbin /var/www /srv /opt /tmp /var/tmp /dev/shm \
  \( -path "/opt/VBoxGuestAdditions-*" -o -path "/srv/www/biafra" -o -path "/srv/www/biafra/*" -o -path "/tmp/VSLiveshareLogs/*" -o -path "/tmp/python-languageserver-cancellation/*" -o -path "/tmp/pyright-*/*" -o -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -type f -mtime -7 -ls 2>/dev/null | head -300 || true
'

  section "08_package_integrity" '
echo "[Debian/Ubuntu: dpkg -V, filtered]"
if command -v dpkg >/dev/null 2>&1; then
  dpkg -V 2>/dev/null | egrep -v "Permission denied|/boot/System.map|/boot/vmlinuz" | head -300 || true
else
  echo "dpkg not installed."
fi
echo

echo "[Debian/Ubuntu: debsums -C]"
if command -v debsums >/dev/null 2>&1; then
  debsums -C 2>/dev/null | head -300 || true
else
  echo "debsums not installed."
fi
echo

echo "[Fedora/RHEL: rpm -Va]"
if command -v rpm >/dev/null 2>&1; then
  rpm -Va 2>/dev/null | head -300 || true
else
  echo "rpm not installed."
fi
'

  section "09_firewall_security_controls" '
echo "[ufw status]"
if command -v ufw >/dev/null 2>&1; then
  ufw status numbered verbose 2>&1 || true
  echo
  echo "[ufw raw]"
  ufw show raw 2>&1 || true
else
  echo "ufw unavailable"
fi

echo
echo "[iptables active rules]"
if command -v iptables >/dev/null 2>&1; then
  iptables -S 2>/dev/null || true
  echo
  echo "[iptables-save]"
  iptables-save -c 2>/dev/null || true
else
  echo "iptables unavailable"
fi

echo
echo "[ip6tables active rules]"
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -S 2>/dev/null || true
  echo
  echo "[ip6tables-save]"
  ip6tables-save -c 2>/dev/null || true
else
  echo "ip6tables unavailable"
fi

echo
echo "[nftables]"
if command -v nft >/dev/null 2>&1; then
  nft -a list ruleset 2>/dev/null || true
else
  echo "nft unavailable"
fi

echo
echo "[firewalld]"
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --state 2>&1 || true
  firewall-cmd --list-all-zones 2>&1 || true
  firewall-cmd --permanent --list-all-zones 2>&1 || true
  firewall-cmd --direct --get-all-rules 2>&1 || true
else
  echo "firewalld unavailable"
fi

echo
echo "[AppArmor summary]"
if command -v aa-status >/dev/null 2>&1; then
  aa-status 2>/dev/null | egrep "profiles are loaded|profiles are in enforce|profiles are in complain|processes are" || true
  echo
  echo "[Web/SSH relevant AppArmor lines]"
  aa-status 2>/dev/null | egrep -i "nginx|apache|httpd|php|ssh|sshd|mysql|mariadb|postgres|redis" || true
else
  echo "aa-status unavailable"
fi

echo
echo "[SELinux]"
command -v getenforce >/dev/null 2>&1 && getenforce 2>/dev/null || echo "getenforce unavailable"
'

  section "10_web_stack" '
echo "[Web-related processes]"
ps auxww | egrep -i "apache|nginx|httpd|caddy|php|php-fpm|node|npm|pm2|gunicorn|uwsgi|tomcat|flask|django|rails|puma" | grep -v egrep || true
echo

echo "[Web ports]"
ss -tulpn | egrep ":22|:80|:443|:8080|:8000|:3000|:5000|:8443" || true
echo

echo "[Web service status]"
if [ -d /run/systemd/system ]; then
  systemctl status nginx apache2 httpd caddy php-fpm 'php*-fpm' tomcat gunicorn uwsgi --no-pager 2>/dev/null || true
else
  echo "systemd unavailable."
fi
echo

echo "[Likely web/app roots]"
ls -la /var/www /srv /opt 2>/dev/null || true
echo
find /var/www /srv /opt -maxdepth 5 \
  \( -path "/opt/VBoxGuestAdditions-*" -o -path "/srv/www/biafra" -o -path "/srv/www/biafra/*" -o -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -type f \( -name "index.*" -o -name "package.json" -o -name "app.py" -o -name "wsgi.py" -o -name "manage.py" -o -name "requirements.txt" -o -name "composer.json" -o -name "wp-config.php" -o -name "settings.py" -o -name "*.service" \) -print 2>/dev/null | head -300 || true
'

  section "11_webserver_effective_config" '
echo "[Detected web server candidates]"
ps auxww | egrep -i "nginx|apache|httpd|caddy|node|pm2|gunicorn|uwsgi|tomcat|flask|django|rails|puma" | grep -v egrep || true
echo

if command -v nginx >/dev/null 2>&1 || ps auxww | grep -E "nginx: master|nginx: worker" | grep -vq grep || [ -d /etc/nginx ]; then
  echo "[nginx detected: nginx -t]"
  nginx -t 2>&1 || true
  echo
  echo "[nginx detected: important directives from nginx -T]"
  nginx -T 2>&1 | egrep -n "server_name|listen|root |alias |index |try_files|proxy_pass|fastcgi_pass|uwsgi_pass|location |auth_basic|allow |deny |autoindex|client_max_body_size|access_log|error_log|include " | head -500 || true
else
  echo "nginx not detected as installed/configured/running; skipping nginx -t/nginx -T."
fi

echo
if command -v apache2ctl >/dev/null 2>&1 || command -v apachectl >/dev/null 2>&1 || ps auxww | egrep -q "apache2|httpd" || [ -d /etc/apache2 ] || [ -d /etc/httpd ]; then
  echo "[Apache/httpd detected: config test]"
  command -v apache2ctl >/dev/null 2>&1 && apache2ctl configtest 2>&1 || true
  command -v apachectl >/dev/null 2>&1 && apachectl configtest 2>&1 || true
  echo
  echo "[Apache/httpd detected: enabled sites/modules summary]"
  ls -la /etc/apache2/sites-enabled /etc/apache2/mods-enabled /etc/httpd/conf.d 2>/dev/null || true
else
  echo "Apache/httpd not detected; skipping Apache config test."
fi

echo
if command -v caddy >/dev/null 2>&1 || ps auxww | egrep -q "caddy" || [ -d /etc/caddy ]; then
  echo "[Caddy detected]"
  caddy validate --config /etc/caddy/Caddyfile 2>&1 || true
  sed -n "1,220p" /etc/caddy/Caddyfile 2>/dev/null || true
else
  echo "Caddy not detected; skipping Caddy validation."
fi
'

  section "12_web_app_content_review" '
echo "[Dangerous code patterns, pruned]"
grep -RInE "system\(|shell_exec|passthru|proc_open|popen|base64_decode|eval\(|assert\(|cmd=|/bin/bash|/dev/tcp|nc |ncat|socat|subprocess|pickle.loads|Runtime.getRuntime|ProcessBuilder" /var/www /srv /opt 2>/dev/null \
  | egrep -v "/opt/VBoxGuestAdditions-|/srv/www/biafra|/ecitadel_www_repo/" \
  | head -500 || true
echo

echo "[Sensitive files under likely web roots]"
find /var/www /srv /opt -maxdepth 8 \
  \( -path "/opt/VBoxGuestAdditions-*" -o -path "/srv/www/biafra" -o -path "/srv/www/biafra/*" -o -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -type f \( -name "*.jsonl" -o -name "*.log" -o -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" -o -name ".env" -o -name ".env.*" -o -name "*config*.php" -o -name "settings.py" -o -name "wp-config.php" -o -name "*.bak" -o -name "*.old" -o -name "*.save" \) -ls 2>/dev/null | head -300 || true
echo

echo "[World-writable web/app files]"
find /var/www /srv /opt \
  \( -path "/opt/VBoxGuestAdditions-*" -o -path "/srv/www/biafra" -o -path "/srv/www/biafra/*" -o -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -type f -perm -0002 -ls 2>/dev/null | head -300 || true
echo

echo "[World-writable web/app directories]"
find /var/www /srv /opt \
  \( -path "/opt/VBoxGuestAdditions-*" -o -path "/srv/www/biafra" -o -path "/srv/www/biafra/*" -o -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -type d -perm -0002 -ls 2>/dev/null | head -300 || true
echo

echo "[Recently modified web/app files]"
find /var/www /srv /opt \
  \( -path "/opt/VBoxGuestAdditions-*" -o -path "/srv/www/biafra" -o -path "/srv/www/biafra/*" -o -path "/root/ecitadel_www_repo" -o -path "/root/ecitadel_www_repo/*" -o -path "/home/*/ecitadel_www_repo" -o -path "/home/*/ecitadel_www_repo/*" \) -prune -o \
  -type f -mtime -7 -ls 2>/dev/null | head -500 || true
'

  section "13_web_logs_routes" '
echo "[Suspicious web log entries]"
grep -RInaE " 40[0-9] | 50[0-9] |\.env|\.git|/etc/passwd|union select|select.+from|base64|cmd=|\.php\?|\.cgi|\.jsp|\.asp|%2e%2e|\.\./|curl|wget|xmlrpc|wp-admin|PROPFIND" /var/log/nginx /var/log/apache2 /var/log/httpd 2>/dev/null | tail -500 || true
echo

echo "[Top requested paths]"
awk "{print \$7}" /var/log/nginx/access.log /var/log/nginx/access.log.* /var/log/apache2/access.log /var/log/apache2/access.log.* /var/log/httpd/access_log /var/log/httpd/access_log.* 2>/dev/null | sort | uniq -c | sort -nr | head -50 || true
echo

echo "[Top client IPs]"
awk "{print \$1}" /var/log/nginx/access.log /var/log/nginx/access.log.* /var/log/apache2/access.log /var/log/apache2/access.log.* /var/log/httpd/access_log /var/log/httpd/access_log.* 2>/dev/null | sort | uniq -c | sort -nr | head -30 || true
echo

echo "[Status code summary]"
awk "{print \$9}" /var/log/nginx/access.log /var/log/nginx/access.log.* /var/log/apache2/access.log /var/log/apache2/access.log.* /var/log/httpd/access_log /var/log/httpd/access_log.* 2>/dev/null | egrep "^[0-9]{3}$" | sort | uniq -c | sort -nr || true
'

  section "14_auth_logs" '
echo "[SSH service journal last 24h]"
if [ -d /run/systemd/system ]; then
  journalctl -u ssh -u sshd --since "24 hours ago" --no-pager 2>/dev/null | tail -300 || true
else
  echo "systemd unavailable."
fi
echo

echo "[Auth log high-signal lines]"
grep -RInaE "Failed password|Accepted password|Accepted publickey|Invalid user|authentication failure|sudo:|session opened|session closed" /var/log/auth.log /var/log/secure 2>/dev/null | tail -300 || true
echo

echo "[lastb if available]"
lastb -a 2>/dev/null | head -50 || true
'

  section "15_web_validation" '
check_url() {
  local url="$1"
  echo "---- $url ----"
  curl -k -I --max-time 5 "$url" 2>&1 || echo "No response from $url"
  echo
}
check_url http://127.0.0.1
check_url http://localhost
check_url https://127.0.0.1
check_url https://localhost
'

  make_tar_backup
  copy_snapshot_files
  remove_push_unsafe_files

  section "16_snapshot_inventory" "
echo '[Copied snapshot summary]'
find '$SNAP' -maxdepth 3 -print 2>/dev/null | sed 's#^$SNAP#.#' | sort | head -350
echo
echo '[Local tar backup path]'
echo '$BACKUP'
echo
echo '[Push-unsafe file check]'
find '$SNAP' -type f \\( -name 'ssh_host_*_key' -o -name 'id_rsa' -o -name 'id_dsa' -o -name 'id_ecdsa' -o -name 'id_ed25519' -o -name '*.pem' -o -name '*.key' \\) ! -name '*.pub' -print 2>/dev/null || true
echo
echo '[SUID/SGID files inside committed snapshot should be empty]'
find '$SNAP' -type f \\( -perm -4000 -o -perm -2000 \\) -ls 2>/dev/null || true
"

  commit_snapshot
  fix_ownership

  echo
  echo "Snapshot: $SNAP"
  echo "Report:   $REPORT"
  echo "Backup:   $BACKUP"
  echo
  echo "Push manually when ready:"
  echo "  cd $BASE && git push -u origin main"
  echo
  log "Done."
}

main
