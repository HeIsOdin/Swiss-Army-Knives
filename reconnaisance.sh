#!/usr/bin/env bash
set -u
set -o pipefail

REMOTE_URL="https://github.com/K3rn4lp4n1c/eCitadel-2026-WWW.git"
BASE="$HOME/ecitadel_www_repo"
HOST="$(hostname -s 2>/dev/null || echo unknown-host)"
TS="$(date +%F_%H%M%S)"
SNAP_REL="snapshots/${HOST}_${TS}"
SNAP="$BASE/$SNAP_REL"
REPORT="$SNAP/recon_report.txt"
BACKUP="$BASE/local_only/${HOST}_${TS}.tar"

log(){ echo "[*] $1"; }

init_repo() {
  mkdir -p "$SNAP" "$BASE/local_only"

  if [ ! -d "$BASE/.git" ]; then
    git init "$BASE"
    cd "$BASE" || exit 1
    git branch -M main
    git remote add origin "$REMOTE_URL" 2>/dev/null || true
  else
    cd "$BASE" || exit 1
    git remote get-url origin >/dev/null 2>&1 || git remote add origin "$REMOTE_URL"
  fi

  # Avoid commit failures in fresh competition images.
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
  [ -e "$1" ] || return 0
  mkdir -p "$(dirname "$2")"
  cp -a "$1" "$2" 2>/dev/null || true
}

copy_tree() {
  [ -d "$1" ] || return 0

  local src="$1"
  local dest="$2"

  mkdir -p "$dest"

  tar -C "$src" \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='vendor' \
    --exclude='__pycache__' \
    --exclude='*.log' \
    --exclude='*.sql' \
    --exclude='*.sqlite' \
    --exclude='*.db' \
    --exclude='*.tar' \
    --exclude='*.tar.gz' \
    --exclude='*.tgz' \
    --exclude='*.zip' \
    -cf - . 2>/dev/null \
    | tar -C "$dest" -xf - 2>/dev/null || true
}

make_tar_backup() {
  log "Creating local tar backup"

  # local_only is not added to git by this script.
  tar --xattrs --acls --selinux -cpf "$BACKUP" \
    /etc/nginx \
    /etc/apache2 \
    /etc/httpd \
    /etc/php \
    /etc/php-fpm.d \
    /etc/ssh/sshd_config \
    /etc/systemd/system \
    /var/www \
    /srv \
    /opt \
    /usr/local/bin \
    /usr/local/sbin \
    2>/dev/null || true
}

copy_snapshot_files() {
  log "Copying web/server config and source candidates"

  copy_if_exists /etc/ssh/sshd_config "$SNAP/etc/ssh/sshd_config"

  copy_tree /etc/nginx "$SNAP/etc/nginx"
  copy_tree /etc/apache2 "$SNAP/etc/apache2"
  copy_tree /etc/httpd "$SNAP/etc/httpd"
  copy_tree /etc/php "$SNAP/etc/php"
  copy_tree /etc/php-fpm.d "$SNAP/etc/php-fpm.d"
  copy_tree /etc/systemd/system "$SNAP/etc/systemd/system"

  copy_tree /var/www "$SNAP/var/www"
  copy_tree /srv "$SNAP/srv"
  copy_tree /opt "$SNAP/opt"
  copy_tree /usr/local/bin "$SNAP/usr/local/bin"
  copy_tree /usr/local/sbin "$SNAP/usr/local/sbin"
}

commit_snapshot() {
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

  echo
  echo "Snapshot:"
  echo "  $SNAP"
  echo
  echo "Single report file:"
  echo "  $REPORT"
  echo
  echo "Local tar backup:"
  echo "  $BACKUP"
  echo
  echo "Push manually when ready:"
  echo "  cd $BASE && git push -u origin main"
}

main() {
  [ "$EUID" -eq 0 ] || echo "[!] Run with sudo for best results."

  init_repo

  {
    echo "eCitadel Web Server Recon Report"
    echo "host=$HOST"
    echo "timestamp=$TS"
    echo "repo=$REMOTE_URL"
    echo "snapshot=$SNAP"
  } > "$REPORT"

  section "00_environment" '
echo "[Identity]"
hostname -f
cat /etc/os-release 2>/dev/null || true
uname -a
uptime
echo

echo "[WSL check]"
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "WSL detected. Some systemd/service results may be limited."
else
  echo "Not WSL, or WSL signature not detected."
fi
echo

echo "[Logged-in/recent sessions]"
who || true
last -a | head -40 || true
'

  section "01_network_and_ports" '
echo "[Addresses]"
ip -br addr || true
echo

echo "[Routes]"
ip route || true
echo

echo "[Listening sockets]"
ss -tulpn || true
echo

echo "[Established/recent TCP sockets]"
ss -tanp 2>/dev/null | head -100 || true
echo

echo "[DNS]"
cat /etc/resolv.conf 2>/dev/null || true
'

  section "02_services_and_processes" '
echo "[Systemd]"
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

echo "[Process list: web/security relevant]"
ps auxww \
  | egrep -i "apache|nginx|httpd|php|php-fpm|node|npm|pm2|gunicorn|uwsgi|tomcat|flask|django|python|perl|ruby|java|bash|sh|nc |ncat|socat|curl|wget|ssh|cron" \
  | grep -v egrep || true
echo

echo "[Top processes]"
ps -eo user,pid,ppid,stat,%cpu,%mem,etime,cmd --sort=-%cpu | head -80 || true
'

  section "03_users_ssh_privilege" '
echo "[Users with login shells]"
awk -F: "$7 ~ /(bash|sh|zsh|ksh)$/ {print}" /etc/passwd 2>/dev/null || true
echo

echo "[UID 0 accounts]"
awk -F: "$3 == 0 {print}" /etc/passwd 2>/dev/null || true
echo

echo "[sudo/wheel/admin groups]"
getent group sudo 2>/dev/null || true
getent group wheel 2>/dev/null || true
getent group admin 2>/dev/null || true
echo

echo "[sudoers files]"
ls -la /etc/sudoers /etc/sudoers.d 2>/dev/null || true
echo

echo "[Effective SSH config]"
sshd -T 2>/dev/null \
  | egrep "port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|allowusers|allowgroups|maxauthtries|x11forwarding|authorizedkeysfile|usepam" || true
echo

echo "[authorized_keys files]"
find /root /home -maxdepth 3 -name authorized_keys -type f -ls 2>/dev/null || true
'

  section "04_domain_context" '
echo "[realm]"
realm list 2>/dev/null || echo "realm unavailable/no realm info"
echo

echo "[SSSD/Winbind/Kerberos files]"
ls -la /etc/sssd /etc/krb5.conf /etc/samba/smb.conf /etc/nsswitch.conf 2>/dev/null || true
echo

echo "[Domain-related processes]"
ps auxww | egrep -i "sssd|winbind|realmd|krb5|samba|smbd|nmbd" | grep -v egrep || true
'

  section "05_persistence" '
echo "[Cron files]"
ls -la /etc/crontab /etc/cron* /var/spool/cron /var/spool/cron/crontabs 2>/dev/null || true
echo

echo "[Current user/root crontab]"
crontab -l 2>/dev/null || true
echo

echo "[Systemd timers/services modified recently]"
if [ -d /run/systemd/system ]; then
  systemctl list-timers --all --no-pager || true
else
  echo "systemd unavailable."
fi
echo

find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system -type f -mtime -30 -ls 2>/dev/null || true
echo

echo "[Suspicious persistence strings]"
grep -RInE "nc |ncat|socat|bash -i|/dev/tcp|curl .*sh|wget .*sh|base64|python.*socket|perl.*socket|php .* -r|chmod \+s|chattr \+i" \
  /etc/systemd /etc/cron* /var/spool/cron* 2>/dev/null || true
'

  section "06_malicious_binary_detection" '
echo "[SUID files]"
find / -xdev -perm -4000 -type f -ls 2>/dev/null || true
echo

echo "[SGID files]"
find / -xdev -perm -2000 -type f -ls 2>/dev/null || true
echo

echo "[Executable files in risky writable locations]"
find /tmp /var/tmp /dev/shm /var/www /srv /opt \
  \( -path "/tmp/VSLiveshareLogs/*" -o -path "/tmp/python-languageserver-cancellation/*" -o -path "/tmp/pyright-*/*" \) -prune -o \
  -type f -perm /111 -ls 2>/dev/null | head -300 || true
echo

echo "[ELF/scripts in risky writable or web/app locations]"
find /tmp /var/tmp /dev/shm /var/www /srv /opt \
  \( -path "/tmp/VSLiveshareLogs/*" -o -path "/tmp/python-languageserver-cancellation/*" -o -path "/tmp/pyright-*/*" \) -prune -o \
  -type f -exec file {} \; 2>/dev/null \
  | egrep "ELF|executable|script|shared object" | head -300 || true
echo

echo "[Recently modified files in high-value writable/app locations]"
find /usr/local/bin /usr/local/sbin /var/www /srv /opt /tmp /var/tmp /dev/shm \
  \( -path "/tmp/VSLiveshareLogs/*" -o -path "/tmp/python-languageserver-cancellation/*" -o -path "/tmp/pyright-*/*" \) -prune -o \
  -type f -mtime -7 -ls 2>/dev/null | head -300 || true
'

  section "07_package_integrity" '
echo "[Debian/Ubuntu: dpkg -V]"
if command -v dpkg >/dev/null 2>&1; then
  dpkg -V 2>/dev/null || true
else
  echo "dpkg not installed."
fi
echo

echo "[Debian/Ubuntu: debsums -C]"
if command -v debsums >/dev/null 2>&1; then
  debsums -C 2>/dev/null || true
else
  echo "debsums not installed."
fi
echo

echo "[Fedora/RHEL: rpm -Va]"
if command -v rpm >/dev/null 2>&1; then
  rpm -Va 2>/dev/null || true
else
  echo "rpm not installed."
fi
'

  section "08_firewall_security_controls" '
echo "[ufw]"
command -v ufw >/dev/null 2>&1 && ufw status verbose || echo "ufw unavailable"
echo

echo "[firewalld]"
command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --list-all || echo "firewalld unavailable"
echo

echo "[nftables]"
command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | head -300 || echo "nft unavailable/no rules"
echo

echo "[iptables]"
command -v iptables >/dev/null 2>&1 && iptables -S 2>/dev/null || echo "iptables unavailable"
echo

echo "[AppArmor/SELinux]"
command -v aa-status >/dev/null 2>&1 && aa-status 2>/dev/null || true
command -v getenforce >/dev/null 2>&1 && getenforce 2>/dev/null || true
'

  section "09_web_stack" '
echo "[Web-related processes]"
ps auxww | egrep -i "apache|nginx|httpd|php|php-fpm|node|npm|pm2|gunicorn|uwsgi|tomcat|flask|django|rails|puma" | grep -v egrep || true
echo

echo "[Web ports]"
ss -tulpn | egrep ":22|:80|:443|:8080|:8000|:3000|:5000|:8443" || true
echo

echo "[Web service status]"
if [ -d /run/systemd/system ]; then
  systemctl status nginx apache2 httpd php-fpm php*-fpm tomcat gunicorn uwsgi --no-pager 2>/dev/null || true
else
  echo "systemd unavailable."
fi
echo

echo "[Likely web/app roots]"
ls -la /var/www /srv /opt 2>/dev/null || true
echo

find /var/www /srv /opt -maxdepth 5 -type f \( \
  -name "index.*" -o \
  -name "package.json" -o \
  -name "app.py" -o \
  -name "wsgi.py" -o \
  -name "manage.py" -o \
  -name "requirements.txt" -o \
  -name "composer.json" -o \
  -name "wp-config.php" -o \
  -name "settings.py" -o \
  -name "*.service" \
\) 2>/dev/null || true
'

  section "10_web_suspicious_content" '
echo "[Dangerous code patterns]"
grep -RInE "system\(|shell_exec|passthru|proc_open|popen|base64_decode|eval\(|assert\(|cmd=|/bin/bash|/dev/tcp|nc |ncat|socat|subprocess|pickle.loads|Runtime.getRuntime|ProcessBuilder" \
  /var/www /srv /opt 2>/dev/null | head -500 || true
echo

echo "[World-writable web/app files]"
find /var/www /srv /opt -type f -perm -0002 -ls 2>/dev/null | head -300 || true
echo

echo "[World-writable web/app directories]"
find /var/www /srv /opt -type d -perm -0002 -ls 2>/dev/null | head -300 || true
echo

echo "[Recently modified web/app files]"
find /var/www /srv /opt -type f -mtime -7 -ls 2>/dev/null | head -500 || true
'

  section "11_web_logs_routes" '
echo "[Suspicious web log entries]"
grep -RInaE " 40[0-9] | 50[0-9] |\.env|\.git|/etc/passwd|union select|select.+from|base64|cmd=|\.php\?|\.cgi|\.jsp|\.asp|%2e%2e|\.\./|curl|wget|xmlrpc|wp-admin|PROPFIND" \
  /var/log/nginx /var/log/apache2 /var/log/httpd 2>/dev/null | tail -500 || true
echo

echo "[Top requested paths]"
awk "{print \$7}" /var/log/nginx/access.log /var/log/nginx/access.log.* /var/log/apache2/access.log /var/log/apache2/access.log.* /var/log/httpd/access_log /var/log/httpd/access_log.* 2>/dev/null \
  | sort | uniq -c | sort -nr | head -50 || true
echo

echo "[Top client IPs]"
awk "{print \$1}" /var/log/nginx/access.log /var/log/nginx/access.log.* /var/log/apache2/access.log /var/log/apache2/access.log.* /var/log/httpd/access_log /var/log/httpd/access_log.* 2>/dev/null \
  | sort | uniq -c | sort -nr | head -30 || true
'

  section "12_web_validation" '
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

  section "13_snapshot_inventory" "
echo '[Copied snapshot directories/files]'
find '$SNAP' -maxdepth 4 -print 2>/dev/null | sed 's#^$SNAP#.#' | sort | head -500
echo
echo '[Local tar backup path]'
echo '$BACKUP'
"

  commit_snapshot

  log "Done: $SNAP"
}

main
