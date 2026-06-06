#!/usr/bin/env bash
# eCitadel web backup tool
#
# Commands:
#   backup   - create local_only/TIMESTAMP/rootfs.tar
#   compare  - compare latest/rootfs.tar, or a supplied tarball, against the live server
#   restore  - restore selected paths; if no --path is given, restore the whole tarball
#   list     - list tarball contents
#   latest   - print the latest backup directory
#
# Plain tar only. Web server only.

set -euo pipefail

if [[ -n "${ECITADEL_REPO:-}" ]]; then
  BASE="$ECITADEL_REPO"
elif [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  SUDO_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
  BASE="${SUDO_HOME:-$HOME}/ecitadel_www_repo"
else
  BASE="$HOME/ecitadel_www_repo"
fi

COMMAND="${1:-}"
shift || true

TAR_PATH=""
OUT_DIR=""
EXTRA_INCLUDE=()
RESTORE_PATHS=()

log(){ echo "[*] $*"; }
die(){ echo "[!] $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./salvation.sh backup [--base DIR] [--include /extra/path]
  sudo ./salvation.sh compare [--base DIR] [--tar /path/to/rootfs.tar] [--out DIR]
  sudo ./salvation.sh restore [--base DIR] [--tar /path/to/rootfs.tar] [--path etc/nginx/nginx.conf] [--path var/www/html/index.html]
       ./salvation.sh list [--base DIR] [--tar /path/to/rootfs.tar]
       ./salvation.sh latest [--base DIR]

Defaults:
  --tar defaults to <base>/local_only/latest/rootfs.tar for compare, restore, and list.
  restore with no --path restores the whole tarball.

Options:
  --base DIR       Base directory. Default: $ECITADEL_REPO or ~/ecitadel_www_repo
  --include PATH   Extra absolute path to include during backup. Can be repeated.
  --tar PATH       Backup tarball path.
  --out DIR        Compare output directory.
  --path RELPATH   Restore path inside tarball, relative to /. Can be repeated.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) BASE="${2:-}"; shift 2 ;;
      --include) EXTRA_INCLUDE+=("${2:-}"); shift 2 ;;
      --tar) TAR_PATH="${2:-}"; shift 2 ;;
      --out) OUT_DIR="${2:-}"; shift 2 ;;
      --path) RESTORE_PATHS+=("${2:-}"); shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

need_root() {
  [[ "$EUID" -eq 0 ]] || die "Run this command with sudo/root."
}

default_tar_path() {
  echo "$BASE/local_only/latest/rootfs.tar"
}

resolve_tar_path() {
  if [[ -z "$TAR_PATH" ]]; then
    TAR_PATH="$(default_tar_path)"
  fi
  [[ -f "$TAR_PATH" ]] || die "Tarball not found: $TAR_PATH"
}

relpath() {
  local p="$1"
  p="${p#./}"
  p="${p#/}"
  echo "$p"
}

safe_restore_path() {
  local p="$1"
  [[ -n "$p" ]] || die "Empty restore path."
  [[ "$p" != /* ]] || die "Restore path must be relative to /: $p"
  [[ "$p" != *".."* ]] || die "Restore path cannot contain '..': $p"
  [[ "$p" != *"*"* && "$p" != *"?"* && "$p" != *"["* ]] || die "Restore path cannot contain wildcards: $p"
}

tar_list() {
  tar -tf "$1" | sed 's#^\./##; s#^/##'
}

tar_member_exists() {
  local tarball="$1"
  local member="$2"
  tar_list "$tarball" | grep -Fxq "$member"
}

add_if_exists() {
  local p
  p="$(relpath "$1")"
  [[ -e "/$p" ]] && echo "$p"
}

make_include_list() {
  {
    add_if_exists /etc/nginx
    add_if_exists /etc/apache2
    add_if_exists /etc/httpd
    add_if_exists /etc/caddy
    add_if_exists /etc/php
    add_if_exists /etc/php-fpm.d
    add_if_exists /etc/ssh
    add_if_exists /etc/systemd/system
    add_if_exists /etc/sssd
    add_if_exists /etc/krb5.conf
    add_if_exists /etc/samba/smb.conf
    add_if_exists /etc/ufw
    add_if_exists /etc/iptables
    add_if_exists /etc/firewalld
    add_if_exists /etc/nftables.conf
    add_if_exists /var/www
    add_if_exists /srv
    add_if_exists /opt
    add_if_exists /usr/local/bin
    add_if_exists /usr/local/sbin
    add_if_exists /root/.ssh

    if [[ -d /home ]]; then
      find /home -mindepth 2 -maxdepth 2 -type d -name .ssh 2>/dev/null | sed 's#^/##' || true
    fi

    for p in "${EXTRA_INCLUDE[@]}"; do
      add_if_exists "$p"
    done
  } | sort -u
}

backup_cmd() {
  need_root

  local ts dir include tarball
  ts="$(date +%F_%H%M%S)"
  dir="$BASE/local_only/$ts"
  include="$dir/include_paths.txt"
  tarball="$dir/rootfs.tar"

  mkdir -p "$dir"
  make_include_list > "$include"
  [[ -s "$include" ]] || die "No paths found to back up."

  log "Creating backup: $tarball"

  tar --xattrs --acls --selinux --numeric-owner -C / -cpf "$tarball" \
    --exclude='*/ecitadel_www_repo/*' \
    --exclude='*/local_only/*' \
    --exclude='*/.git/*' \
    --exclude='*/node_modules/*' \
    --exclude='*/vendor/*' \
    --exclude='*/__pycache__/*' \
    --exclude='*.pyc' \
    --exclude='*.log' \
    --exclude='*.sql' \
    --exclude='*.sqlite' \
    --exclude='*.sqlite3' \
    --exclude='*.db' \
    --exclude='*.tar' \
    --exclude='*.tgz' \
    --exclude='*.zip' \
    --exclude='VBoxGuestAdditions-*' \
    --files-from "$include"

  tar -tf "$tarball" > "$dir/tar_list.txt"

  {
    echo "time=$(date -Is)"
    echo "host=$(hostname -f 2>/dev/null || hostname)"
    echo "tarball=$tarball"
    echo "base=$BASE"
    echo
    echo "included_paths:"
    sed 's/^/  /' "$include"
  } > "$dir/backup_notes.txt"

  ln -sfn "$ts" "$BASE/local_only/latest"

  log "Backup complete."
  echo "Backup directory: $dir"
  echo "Tarball: $tarball"
}

is_text_candidate() {
  local p="$1"
  [[ "$p" =~ \.(conf|cnf|ini|env|service|timer|socket|target|php|py|js|json|yml|yaml|xml|html|css|sh|txt|sql|rb|pl|cgi|java|properties)$ ]] && return 0
  [[ "$p" == etc/* || "$p" == var/www/* || "$p" == srv/* ]] && return 0
  return 1
}

safe_name() {
  echo "$1" | sed 's#/#_#g; s#[^A-Za-z0-9._-]#_#g'
}

compare_cmd() {
  need_root
  resolve_tar_path

  local ts out backup_files live_files
  ts="$(date +%F_%H%M%S)"

  if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$(dirname "$TAR_PATH")/compare_$ts"
  fi

  out="$OUT_DIR"
  mkdir -p "$out/text_diffs"

  log "Comparing backup to live filesystem"
  log "Tarball: $TAR_PATH"
  log "Output: $out"

  tar -C / -df "$TAR_PATH" > "$out/tar_compare_raw.txt" 2>&1 || true

  backup_files="$out/backup_files.txt"
  live_files="$out/live_files.txt"

  tar_list "$TAR_PATH" | grep -Ev '/$' | sort -u > "$backup_files"

  {
    for d in /etc /var/www /srv /opt /usr/local/bin /usr/local/sbin /root/.ssh /home; do
      [[ -e "$d" ]] || continue
      find "$d" \
        \( -path "*/ecitadel_www_repo/*" \
           -o -path "*/local_only/*" \
           -o -path "/opt/VBoxGuestAdditions-*" \
           -o -path "/srv/www/biafra/*" \) -prune -o \
        -type f -print 2>/dev/null
    done
  } | sed 's#^/##' | sort -u > "$live_files"

  comm -23 "$backup_files" "$live_files" > "$out/missing_files.txt" || true
  comm -13 "$backup_files" "$live_files" > "$out/new_live_files.txt" || true

  grep -Ei '(\.php|\.phtml|\.jsp|\.war|\.py|\.sh|\.pl|\.cgi|\.so|\.service|\.timer|authorized_keys|\.env|\.bak|\.old|\.save|\.sql|\.db|\.sqlite|\.sqlite3)$' \
    "$out/new_live_files.txt" > "$out/suspicious_new_files.txt" || true

  : > "$out/changed_files.txt"
  : > "$out/changed_text_files.txt"
  : > "$out/binary_or_unreadable_changed_files.txt"

  while IFS= read -r p; do
    [[ -f "/$p" ]] || continue

    if ! cmp -s <(tar -xOf "$TAR_PATH" "$p" 2>/dev/null) "/$p"; then
      echo "$p" >> "$out/changed_files.txt"

      if is_text_candidate "$p" && file -b --mime-type "/$p" 2>/dev/null | grep -Eq 'text|json|xml|x-shellscript|javascript|x-php|x-python'; then
        echo "$p" >> "$out/changed_text_files.txt"
        diff -u <(tar -xOf "$TAR_PATH" "$p" 2>/dev/null) "/$p" \
          > "$out/text_diffs/$(safe_name "$p").diff" || true
      else
        echo "$p" >> "$out/binary_or_unreadable_changed_files.txt"
      fi
    fi
  done < "$backup_files"

  {
    echo "Backup compare summary"
    echo "time=$(date -Is)"
    echo "tarball=$TAR_PATH"
    echo
    echo "changed_files=$(wc -l < "$out/changed_files.txt")"
    echo "changed_text_files=$(wc -l < "$out/changed_text_files.txt")"
    echo "missing_files=$(wc -l < "$out/missing_files.txt")"
    echo "new_live_files=$(wc -l < "$out/new_live_files.txt")"
    echo "suspicious_new_files=$(wc -l < "$out/suspicious_new_files.txt")"
    echo
    echo "review_order:"
    echo "  1. $out/suspicious_new_files.txt"
    echo "  2. $out/changed_text_files.txt"
    echo "  3. $out/text_diffs/"
    echo "  4. $out/missing_files.txt"
    echo "  5. $out/tar_compare_raw.txt"
  } > "$out/summary.txt"

  cat "$out/summary.txt"
}

make_pre_restore_backup() {
  local safety_tar="$BASE/local_only/pre_restore_$(date +%F_%H%M%S).tar"
  local tmp_list
  tmp_list="$(mktemp)"

  if [[ "${#RESTORE_PATHS[@]}" -eq 0 ]]; then
    tar_list "$TAR_PATH" | grep -Ev '/$' | while read -r p; do
      [[ -e "/$p" ]] && echo "$p"
    done > "$tmp_list"
  else
    for p in "${RESTORE_PATHS[@]}"; do
      [[ -e "/$p" ]] && echo "$p"
    done > "$tmp_list"
  fi

  if [[ -s "$tmp_list" ]]; then
    log "Creating pre-restore backup of current live files: $safety_tar"
    tar --xattrs --acls --selinux --numeric-owner -C / -cpf "$safety_tar" --files-from "$tmp_list" 2>/dev/null || true
  fi

  rm -f "$tmp_list"
}

restore_cmd() {
  need_root
  resolve_tar_path

  local normalized=()
  local p

  for p in "${RESTORE_PATHS[@]}"; do
    p="$(relpath "$p")"
    safe_restore_path "$p"
    tar_member_exists "$TAR_PATH" "$p" || die "Not found in tarball: $p"
    normalized+=("$p")
  done
  RESTORE_PATHS=("${normalized[@]}")

  echo "Restore plan"
  echo "tarball=$TAR_PATH"

  if [[ "${#RESTORE_PATHS[@]}" -eq 0 ]]; then
    echo "scope=whole tarball"
  else
    echo "scope=selected paths"
    printf '  %s\n' "${RESTORE_PATHS[@]}"
  fi

  make_pre_restore_backup

  log "Restoring. Backup tarball will not be deleted."

  if [[ "${#RESTORE_PATHS[@]}" -eq 0 ]]; then
    tar --xattrs --acls --selinux --numeric-owner -C / -xpf "$TAR_PATH"
  else
    tar --xattrs --acls --selinux --numeric-owner -C / -xpf "$TAR_PATH" "${RESTORE_PATHS[@]}"
  fi

  log "Restore complete."
}

latest_cmd() {
  local latest="$BASE/local_only/latest"
  [[ -e "$latest" ]] || die "No latest backup found at $latest"
  readlink -f "$latest"
}

list_cmd() {
  resolve_tar_path
  tar -tf "$TAR_PATH"
}

main() {
  [[ -n "$COMMAND" ]] || { usage; exit 1; }
  parse_args "$@"

  case "$COMMAND" in
    backup) backup_cmd ;;
    compare) compare_cmd ;;
    restore) restore_cmd ;;
    list) list_cmd ;;
    latest) latest_cmd ;;
    help|-h|--help) usage ;;
    *) die "Unknown command: $COMMAND" ;;
  esac
}

main "$@"
