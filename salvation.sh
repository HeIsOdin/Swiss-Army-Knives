#!/usr/bin/env bash
# eCitadel web backup/compare/restore helper ("salvation")
#
# Commands:
#   backup   - create local_only/TIMESTAMP/rootfs.tar and local_only/TIMESTAMP/salvation_report.txt
#   compare  - compare latest/rootfs.tar, or a supplied tarball, against the live server
#   restore  - restore selected paths; if no --path is given, restore the whole tarball
#   list     - list tarball contents
#   latest   - print the latest backup directory
#
# Design:
#   - Plain tar only.
#   - Web server only for now.
#   - If --tar is not passed, compare/restore/list use local_only/latest/rootfs.tar.
#   - Restore never deletes the backup tarball.
#   - Restore creates a pre-restore tarball of current live files before overwriting them.
#   - Each backup directory keeps one main text file: salvation_report.txt.
#   - Compare prints changed files to stdout and also appends them to salvation_report.txt.

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
OUT_REPORT=""
EXTRA_INCLUDE=()
RESTORE_PATHS=()

log(){ echo "[*] $*"; }
die(){ echo "[!] $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./salvation.sh backup [--base DIR] [--include /extra/path]

  sudo ./salvation.sh compare [--base DIR] [--tar /path/to/rootfs.tar] [--report /path/to/report.txt]

  sudo ./salvation.sh restore [--base DIR] [--tar /path/to/rootfs.tar] [--path etc/nginx/nginx.conf] [--path var/www/html/index.html]
      If no --path is given, restore extracts the whole tarball.

       ./salvation.sh list [--base DIR] [--tar /path/to/rootfs.tar]
       ./salvation.sh latest [--base DIR]

Defaults:
  --tar defaults to <base>/local_only/latest/rootfs.tar for compare, restore, and list.
  --report defaults to salvation_report.txt beside the selected tarball.

Options:
  --base DIR       Base directory. Default: $ECITADEL_REPO or ~/ecitadel_www_repo
  --include PATH   Extra absolute path to include during backup. Can be repeated.
  --tar PATH       Backup tarball path.
  --report PATH    Text report path for compare/restore. Default: dirname(rootfs.tar)/salvation_report.txt
  --path RELPATH   Restore path inside tarball, relative to /. Can be repeated.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base) BASE="${2:-}"; shift 2 ;;
      --include) EXTRA_INCLUDE+=("${2:-}"); shift 2 ;;
      --tar) TAR_PATH="${2:-}"; shift 2 ;;
      --report) OUT_REPORT="${2:-}"; shift 2 ;;
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

report_path_for_tar() {
  if [[ -n "$OUT_REPORT" ]]; then
    echo "$OUT_REPORT"
  else
    echo "$(dirname "$TAR_PATH")/salvation_report.txt"
  fi
}

append_section() {
  local report="$1"
  local title="$2"
  mkdir -p "$(dirname "$report")"
  {
    echo
    echo "================================================================"
    echo "SECTION: $title"
    echo "TIME: $(date -Is)"
    echo "================================================================"
    echo
  } >> "$report"
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
  tar --quoting-style=literal -tf "$1" | sed 's#^\./##; s#^/##'
}

tar_regular_files() {
  tar --quoting-style=literal -tvf "$1" 2>/dev/null \
    | awk '$1 ~ /^-/ {for (i=6; i<=NF; i++) printf "%s%s", $i, (i==NF ? ORS : OFS)}' \
    | sed 's#^\./##; s#^/##'
}

tar_member_exists() {
  local tarball="$1"
  local member="$2"
  tar_list "$tarball" | grep -Fxq "$member"
}

add_if_exists() {
  local p
  p="$(relpath "$1")"

  if [[ -e "/$p" ]]; then
    echo "$p"
  fi

  return 0
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

  local ts dir include tarball report
  ts="$(date +%F_%H%M%S)"
  dir="$BASE/local_only/$ts"
  include="$(mktemp)"
  tarball="$dir/rootfs.tar"
  report="$dir/salvation_report.txt"

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

  {
    echo "eCitadel Salvation Report"
    echo "host=$(hostname -f 2>/dev/null || hostname)"
    echo "created=$(date -Is)"
    echo "base=$BASE"
    echo "backup_dir=$dir"
    echo "tarball=$tarball"
  } > "$report"

  append_section "$report" "BACKUP_SUMMARY"
  {
    echo "tarball=$tarball"
    echo "tarball_size_bytes=$(stat -c %s "$tarball" 2>/dev/null || echo unknown)"
    echo "latest_symlink=$BASE/local_only/latest"
  } >> "$report"

  append_section "$report" "BACKUP_INCLUDED_ROOTS"
  sed 's/^/  /' "$include" >> "$report"

  append_section "$report" "BACKUP_TAR_CONTENTS"
  tar --quoting-style=literal -tf "$tarball" >> "$report"

  ln -sfn "$ts" "$BASE/local_only/latest"
  rm -f "$include"

  log "Backup complete."
  echo "Backup directory: $dir"
  echo "Tarball: $tarball"
  echo "Report: $report"
}

is_text_candidate() {
  local p="$1"
  [[ "$p" =~ \.(conf|cnf|ini|env|service|timer|socket|target|php|py|js|json|yml|yaml|xml|html|css|sh|txt|sql|rb|pl|cgi|java|properties)$ ]] && return 0
  [[ "$p" == etc/* || "$p" == var/www/* || "$p" == srv/* ]] && return 0
  return 1
}

tar_has_path_prefix() {
  local paths_file="$1"
  local root="$2"
  awk -v r="$root" '$0 == r || index($0, r "/") == 1 {found=1} END {exit found ? 0 : 1}' "$paths_file"
}

build_compare_scope() {
  local paths_file="$1"
  local scope_file="$2"

  : > "$scope_file"

  local roots=(
    "etc/nginx"
    "etc/apache2"
    "etc/httpd"
    "etc/caddy"
    "etc/php"
    "etc/php-fpm.d"
    "etc/ssh"
    "etc/systemd/system"
    "etc/sssd"
    "etc/krb5.conf"
    "etc/samba/smb.conf"
    "etc/ufw"
    "etc/iptables"
    "etc/firewalld"
    "etc/nftables.conf"
    "var/www"
    "srv"
    "opt"
    "usr/local/bin"
    "usr/local/sbin"
    "root/.ssh"
  )

  local r
  for r in "${roots[@]}"; do
    if tar_has_path_prefix "$paths_file" "$r"; then
      echo "$r" >> "$scope_file"
    fi
  done

  awk '
    $0 ~ /^home\/[^/]+\/\.ssh($|\/)/ {
      split($0, a, "/");
      print a[1] "/" a[2] "/" a[3];
    }
  ' "$paths_file" >> "$scope_file"

  sort -u "$scope_file" -o "$scope_file"
}

scan_live_scope() {
  local scope_file="$1"
  local live_file="$2"

  : > "$live_file"

  while IFS= read -r root; do
    [[ -n "$root" ]] || continue

    if [[ -f "/$root" || -L "/$root" ]]; then
      echo "$root" >> "$live_file"
    elif [[ -d "/$root" ]]; then
      find "/$root" \
        \( -path "*/ecitadel_www_repo/*" \
           -o -path "*/local_only/*" \
           -o -path "/opt/VBoxGuestAdditions-*" \) -prune -o \
        \( -type f -o -type l \) -print 2>/dev/null \
        | sed 's#^/##' >> "$live_file" || true
    fi
  done < "$scope_file"

  sort -u "$live_file" -o "$live_file"
}

compare_cmd() {
  need_root
  resolve_tar_path

  local report ts all_paths backup_files backup_regular_files live_files scope_file changed_files changed_text_files missing_files new_live_files suspicious_new_files binary_changed tar_raw
  report="$(report_path_for_tar)"
  ts="$(date +%F_%H%M%S)"

  all_paths="$(mktemp)"
  backup_files="$(mktemp)"
  backup_regular_files="$(mktemp)"
  live_files="$(mktemp)"
  scope_file="$(mktemp)"
  changed_files="$(mktemp)"
  changed_text_files="$(mktemp)"
  missing_files="$(mktemp)"
  new_live_files="$(mktemp)"
  suspicious_new_files="$(mktemp)"
  binary_changed="$(mktemp)"
  tar_raw="$(mktemp)"

  tar_list "$TAR_PATH" | sort -u > "$all_paths"
  tar_list "$TAR_PATH" | grep -Ev '/$' | sort -u > "$backup_files" || true
  tar_regular_files "$TAR_PATH" | sort -u > "$backup_regular_files" || true

  build_compare_scope "$all_paths" "$scope_file"
  scan_live_scope "$scope_file" "$live_files"

  tar --quoting-style=literal -C / -df "$TAR_PATH" > "$tar_raw" 2>&1 || true

  comm -23 "$backup_files" "$live_files" > "$missing_files" || true
  comm -13 "$backup_files" "$live_files" > "$new_live_files" || true

  grep -Ei '(\.php|\.phtml|\.jsp|\.war|\.py|\.sh|\.pl|\.cgi|\.so|\.service|\.timer|authorized_keys|\.env|\.bak|\.old|\.save|\.sql|\.db|\.sqlite|\.sqlite3)$' \
    "$new_live_files" > "$suspicious_new_files" || true

  : > "$changed_files"
  : > "$changed_text_files"
  : > "$binary_changed"

  while IFS= read -r p; do
    [[ -f "/$p" ]] || continue

    if ! cmp -s <(tar -xOf "$TAR_PATH" "$p" 2>/dev/null) "/$p"; then
      echo "$p" >> "$changed_files"

      if is_text_candidate "$p" && file -b --mime-type "/$p" 2>/dev/null | grep -Eq 'text|json|xml|x-shellscript|javascript|x-php|x-python'; then
        echo "$p" >> "$changed_text_files"
      else
        echo "$p" >> "$binary_changed"
      fi
    fi
  done < "$backup_regular_files"

  log "Compare complete."
  echo "Tarball: $TAR_PATH"
  echo "Report: $report"
  echo
  echo "Changed files:"
  if [[ -s "$changed_files" ]]; then
    cat "$changed_files"
  else
    echo "  none"
  fi

  append_section "$report" "COMPARE_${ts}_SUMMARY"
  {
    echo "tarball=$TAR_PATH"
    echo "changed_files=$(wc -l < "$changed_files")"
    echo "changed_text_files=$(wc -l < "$changed_text_files")"
    echo "missing_files=$(wc -l < "$missing_files")"
    echo "new_live_files=$(wc -l < "$new_live_files")"
    echo "suspicious_new_files=$(wc -l < "$suspicious_new_files")"
  } >> "$report"

  append_section "$report" "COMPARE_${ts}_SCOPE_ROOTS"
  cat "$scope_file" >> "$report"

  append_section "$report" "COMPARE_${ts}_CHANGED_FILES"
  if [[ -s "$changed_files" ]]; then cat "$changed_files" >> "$report"; else echo "none" >> "$report"; fi

  append_section "$report" "COMPARE_${ts}_CHANGED_TEXT_FILES"
  if [[ -s "$changed_text_files" ]]; then cat "$changed_text_files" >> "$report"; else echo "none" >> "$report"; fi

  append_section "$report" "COMPARE_${ts}_BINARY_OR_UNREADABLE_CHANGED_FILES"
  if [[ -s "$binary_changed" ]]; then cat "$binary_changed" >> "$report"; else echo "none" >> "$report"; fi

  append_section "$report" "COMPARE_${ts}_MISSING_FILES"
  if [[ -s "$missing_files" ]]; then cat "$missing_files" >> "$report"; else echo "none" >> "$report"; fi

  append_section "$report" "COMPARE_${ts}_NEW_LIVE_FILES"
  if [[ -s "$new_live_files" ]]; then cat "$new_live_files" >> "$report"; else echo "none" >> "$report"; fi

  append_section "$report" "COMPARE_${ts}_SUSPICIOUS_NEW_LIVE_FILES"
  if [[ -s "$suspicious_new_files" ]]; then cat "$suspicious_new_files" >> "$report"; else echo "none" >> "$report"; fi

  append_section "$report" "COMPARE_${ts}_TAR_COMPARE_RAW"
  if [[ -s "$tar_raw" ]]; then cat "$tar_raw" >> "$report"; else echo "none" >> "$report"; fi

  append_section "$report" "COMPARE_${ts}_TEXT_DIFFS"
  if [[ -s "$changed_text_files" ]]; then
    while IFS= read -r p; do
      echo
      echo "----------------------------------------------------------------"
      echo "DIFF: $p"
      echo "----------------------------------------------------------------"
      diff -u <(tar -xOf "$TAR_PATH" "$p" 2>/dev/null) "/$p" || true
    done < "$changed_text_files" >> "$report"
  else
    echo "none" >> "$report"
  fi

  rm -f "$all_paths" "$backup_files" "$backup_regular_files" "$live_files" "$scope_file" "$changed_files" "$changed_text_files" "$missing_files" "$new_live_files" "$suspicious_new_files" "$binary_changed" "$tar_raw"
}

make_pre_restore_backup() {
  local report="$1"
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
    echo "$safety_tar" >> "$report"
  else
    echo "No existing live files found for pre-restore backup." >> "$report"
  fi

  rm -f "$tmp_list"
}

restore_cmd() {
  need_root
  resolve_tar_path

  local report ts p
  local normalized=()
  report="$(report_path_for_tar)"
  ts="$(date +%F_%H%M%S)"

  for p in "${RESTORE_PATHS[@]}"; do
    p="$(relpath "$p")"
    safe_restore_path "$p"
    tar_member_exists "$TAR_PATH" "$p" || die "Not found in tarball: $p"
    normalized+=("$p")
  done
  RESTORE_PATHS=("${normalized[@]}")

  append_section "$report" "RESTORE_${ts}_PLAN"
  {
    echo "tarball=$TAR_PATH"
    if [[ "${#RESTORE_PATHS[@]}" -eq 0 ]]; then
      echo "scope=whole tarball"
    else
      echo "scope=selected paths"
      printf '  %s\n' "${RESTORE_PATHS[@]}"
    fi
    echo
    echo "pre_restore_backup:"
  } >> "$report"

  make_pre_restore_backup "$report"

  log "Restoring. Backup tarball will not be deleted."
  if [[ "${#RESTORE_PATHS[@]}" -eq 0 ]]; then
    tar --xattrs --acls --selinux --numeric-owner -C / -xpf "$TAR_PATH"
  else
    tar --xattrs --acls --selinux --numeric-owner -C / -xpf "$TAR_PATH" "${RESTORE_PATHS[@]}"
  fi

  append_section "$report" "RESTORE_${ts}_RESULT"
  {
    echo "restore_status=completed"
    echo "completed=$(date -Is)"
  } >> "$report"

  log "Restore complete."
  echo "Report: $report"
}

latest_cmd() {
  local latest="$BASE/local_only/latest"
  [[ -e "$latest" ]] || die "No latest backup found at $latest"
  readlink -f "$latest"
}

list_cmd() {
  resolve_tar_path
  tar --quoting-style=literal -tf "$TAR_PATH"
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
