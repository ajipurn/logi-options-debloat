#!/bin/zsh
# Logi Options+ debloat for macOS 12+. No downloads or third-party dependencies.
emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
umask 077

readonly SCRIPT_VERSION=1.0.0
readonly LPS_DOMAIN=com.logi.lps.settings
readonly LPS_KEY=enable_lps_in_background
readonly AGENT_LABEL=com.logi.cp-dev-mgr
readonly AGENT_PLIST=/Library/LaunchAgents/com.logi.optionsplus.plist
readonly -a OPTIONAL_FLAGS=(analytics flow sso logivoice aipromptbuilder device_recommendation smartactions actions_ring)

fail() { print -u2 -- "ERROR: $*"; return 1; }
bool_value() { /usr/bin/plutil -extract "$2.value" raw -expect bool -o - "$1" 2>/dev/null; }

validate_policy() {
  local policy_file=$1 flag flag_type seen=0
  [[ -f "$policy_file" && ! -L "$policy_file" ]] || { fail "File kebijakan tidak valid: $policy_file"; return 1; }
  /usr/bin/plutil -convert json -o - "$policy_file" >/dev/null || return 1
  for flag in "${OPTIONAL_FLAGS[@]}"; do
    if flag_type=$(/usr/bin/plutil -type "$flag" "$policy_file" 2>/dev/null); then
      [[ "$flag_type" == dictionary ]] && bool_value "$policy_file" "$flag" >/dev/null || {
        fail "Skema '$flag.value' berubah; tidak ada perubahan diterapkan."; return 1
      }
      (( seen += 1 ))
    fi
  done
  (( seen > 0 )) || { fail 'Tidak menemukan fitur yang dikenal pada versi ini.'; return 1; }
}

# Work on a staging file. Unknown fields and absent optional flags stay untouched.
stage_policy() {
  local operation=$1 current_file=$2 before_file=$3 output_file=$4 flag previous_value
  validate_policy "$current_file" || return 1
  [[ "$operation" != restore ]] || validate_policy "$before_file" || return 1
  /bin/cp "$current_file" "$output_file" || return 1
  for flag in "${OPTIONAL_FLAGS[@]}"; do
    if bool_value "$current_file" "$flag" >/dev/null; then
      if [[ "$operation" == restore ]]; then
        if ! previous_value=$(bool_value "$before_file" "$flag"); then continue; fi
      else
        previous_value=false
      fi
      /usr/bin/plutil -replace "$flag.value" -bool "$previous_value" "$output_file" || return 1
    fi
  done
  /usr/bin/plutil -convert json -r "$output_file" || return 1
}

discover_policy() {
  local candidate canonical
  local -a matches=()
  for candidate in \
    '/Library/Application Support/Logitech.localized/LogiOptionsPlus/app_permissions.json' \
    '/Library/Application Support/Logitech/LogiOptionsPlus/app_permissions.json' \
    '/Library/Application Support/Logi/LogiOptionsPlus/app_permissions.json'; do
    if [[ -f "$candidate" ]]; then
      [[ ! -L "$candidate" ]] || { fail "File kebijakan berupa symlink: $candidate"; return 1; }
      canonical=${candidate:A}
      (( ${matches[(Ie)$canonical]} )) || matches+=("$canonical")
    fi
  done
  (( ${#matches} == 1 )) || { fail 'Instalasi tidak ditemukan atau ada beberapa file kebijakan. Tidak ada perubahan diterapkan.'; return 1; }
  print -r -- "$matches[1]"
}

lps_value() {
  local value_type raw_value
  if value_type=$(/usr/bin/defaults read-type "$LPS_DOMAIN" "$LPS_KEY" 2>/dev/null); then
    [[ "$value_type" == 'Type is boolean' ]] || { fail 'Tipe preferensi Plugin Service tidak dikenal.'; return 1; }
    raw_value=$(/usr/bin/defaults read "$LPS_DOMAIN" "$LPS_KEY") || return 1
    [[ "$raw_value" == 0 || "$raw_value" == 1 ]] || return 1
    print -r -- "$raw_value"
  else
    print missing
  fi
}

show_policy() {
  local policy_file=$1 flag value
  for flag in "${OPTIONAL_FLAGS[@]}" update dfu backlight; do
    if value=$(bool_value "$policy_file" "$flag"); then
      printf '  %-24s %s\n' "$flag" "$value"
    fi
  done
}

# Replace atomically and flush to disk, retaining the destination's owner/mode.
# sudo is limited to the system install utility and this one policy file.
write_policy() {
  local staged_file=$1 target_file=$2 file_mode file_owner file_group
  [[ -f "$target_file" && ! -L "$target_file" ]] || { fail 'File target berubah atau hilang; hentikan.'; return 1; }
  file_mode=$(/usr/bin/stat -f %Lp "$target_file") || return 1
  file_owner=$(/usr/bin/stat -f %u "$target_file") || return 1
  file_group=$(/usr/bin/stat -f %g "$target_file") || return 1
  if [[ -w "${target_file:h}" && "$file_owner" == "$EUID" ]]; then
    /usr/bin/install -S -m "$file_mode" -o "$file_owner" -g "$file_group" "$staged_file" "$target_file"
  else
    print 'macOS memerlukan password administrator untuk file kebijakan Logitech.'
    /usr/bin/sudo /usr/bin/install -S -m "$file_mode" -o "$file_owner" -g "$file_group" "$staged_file" "$target_file"
  fi
}

verify_policy() {
  local expected_file=$1 actual_file=$2 flag expected_value actual_value
  validate_policy "$actual_file" || return 1
  for flag in "${OPTIONAL_FLAGS[@]}" update dfu backlight; do
    if expected_value=$(bool_value "$expected_file" "$flag"); then
      actual_value=$(bool_value "$actual_file" "$flag") || { fail "Field '$flag' hilang saat verifikasi."; return 1; }
      [[ "$actual_value" == "$expected_value" ]] || { fail "Verifikasi '$flag' gagal."; return 1; }
    fi
  done
}

stop_components() {
  local component=$1 pid command_path
  while read -r pid command_path; do
    [[ -n "$pid" ]] || continue
    if [[ "$component" == frontend ]]; then
      case "$command_path" in
        /Applications/logioptionsplus.app/Contents/MacOS/logioptionsplus|'/Applications/Logi Options+.app/Contents/MacOS/logioptionsplus')
          /bin/kill -TERM "$pid" 2>/dev/null || true ;;
      esac
    else
      case "$command_path" in
        /Applications/Utilities/LogiPluginService.app/Contents/*|/Applications/LogiPluginService.app/Contents/*)
          /bin/kill -TERM "$pid" 2>/dev/null || true ;;
      esac
    fi
  done < <(/bin/ps -axo pid=,comm=)
}

reload_agent() {
  local gui_domain="gui/$(/usr/bin/id -u)" attempt agent_pid agent_command
  if /bin/launchctl print "$gui_domain/$AGENT_LABEL" >/dev/null 2>&1; then
    /bin/launchctl kickstart -k "$gui_domain/$AGENT_LABEL" >/dev/null 2>&1 || true
  fi
  for attempt in {1..15}; do
    if ! /bin/launchctl print "$gui_domain/$AGENT_LABEL" >/dev/null 2>&1; then
      /bin/launchctl bootstrap "$gui_domain" "$AGENT_PLIST" >/dev/null 2>&1 || true
    fi
    agent_pid=$(/bin/launchctl print "$gui_domain/$AGENT_LABEL" 2>/dev/null | /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }') || agent_pid=''
    if [[ "$agent_pid" == <-> ]]; then
      agent_command=$(/bin/ps -p "$agent_pid" -o comm= 2>/dev/null) || agent_command=''
      if [[ "$agent_command" == */logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent ]]; then
        print -- "Agent perangkat aktif (PID $agent_pid)."
        return 0
      fi
    fi
    /bin/sleep 1
  done
  fail 'Agent belum aktif. Buka Logi Options+ dan periksa perangkat sebelum melanjutkan.'
}

restore_lps() {
  case "$1" in
    missing) /usr/bin/defaults delete "$LPS_DOMAIN" "$LPS_KEY" 2>/dev/null || true ;;
    0) /usr/bin/defaults write "$LPS_DOMAIN" "$LPS_KEY" -bool false ;;
    1) /usr/bin/defaults write "$LPS_DOMAIN" "$LPS_KEY" -bool true ;;
    *) fail 'Nilai cadangan Plugin Service tidak valid.'; return 1 ;;
  esac
}

main() {
  local operation=${1:---apply} restore_dir=${2:-} policy_file state_root lps_bundle='' old_lps lps_touched=false
  local backup_dir manifest staged_file flag value changes=0 gui_domain version='unknown'
  case "$operation" in
    --help|-h)
      print 'LogiOptions-Debloat.command [--apply | --dry-run | --status | --restore [FOLDER_CADANGAN]]'
      print 'Default: --apply. macOS 12+, akun desktop biasa; sudo hanya jika file memerlukannya.'
      return 0 ;;
    --apply|--dry-run|--status|--restore) ;;
    *) fail "Opsi tidak dikenal: $operation"; return 1 ;;
  esac
  if (( $# > 1 )); then
    [[ $# -eq 2 && "$operation" == --restore ]] || { fail 'Argumen tidak valid. Gunakan --help.'; return 1; }
  fi
  [[ "$(/usr/bin/uname -s)" == Darwin ]] || { fail 'Skrip ini khusus macOS.'; return 1; }
  (( $(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1) >= 12 )) || { fail 'Memerlukan macOS 12 atau lebih baru.'; return 1; }
  (( EUID != 0 )) || { fail 'Jangan jalankan seluruh skrip dengan sudo. Jalankan sebagai pengguna desktop biasa.'; return 1; }
  policy_file=$(discover_policy) || return 1
  validate_policy "$policy_file" || return 1
  old_lps=$(lps_value) || return 1
  for value in /Applications/Utilities/LogiPluginService.app /Applications/LogiPluginService.app; do
    if [[ -d "$value" ]]; then lps_bundle=$value; break; fi
  done
  [[ -z "$lps_bundle" && "$old_lps" == missing ]] || lps_touched=true
  if [[ -f /Applications/logioptionsplus.app/Contents/Info.plist ]]; then
    version=$(/usr/bin/plutil -extract CFBundleVersion raw -o - /Applications/logioptionsplus.app/Contents/Info.plist)
  fi
  print -- "Logi Options+ $version / Debloat $SCRIPT_VERSION"
  print -- "Kebijakan: $policy_file"
  show_policy "$policy_file"
  print -- "  Plugin Service background: $old_lps (missing = belum disetel)"
  if [[ "$operation" == --status || "$operation" == --dry-run ]]; then
    [[ "$operation" != --dry-run ]] || print 'Rencana: delapan fitur opsional di atas menjadi false; LPS background nonaktif bila terpasang. Update/DFU/backlight dipertahankan. Tidak ada perubahan dilakukan.'
    return 0
  fi
  gui_domain="gui/$(/usr/bin/id -u)"
  /bin/launchctl print "$gui_domain" >/dev/null 2>&1 || { fail 'Jalankan dari sesi desktop macOS yang sedang login.'; return 1; }
  [[ -f "$AGENT_PLIST" && "$(/usr/bin/plutil -extract Label raw -o - "$AGENT_PLIST")" == "$AGENT_LABEL" ]] || {
    fail 'LaunchAgent Logitech tidak ditemukan atau skemanya berbeda. Tidak ada perubahan diterapkan.'; return 1
  }
  state_root="$HOME/Library/Application Support/LogiOptionsDebloat"
  if [[ "$operation" == --restore ]]; then
    if [[ -z "$restore_dir" ]]; then
      local -a backups=("$state_root"/backups/*(N/om))
      (( ${#backups} > 0 )) || { fail 'Belum ada cadangan di akun ini.'; return 1; }
      restore_dir=$backups[1]
    fi
    manifest="$restore_dir/manifest.plist"
    [[ -f "$manifest" ]] || { fail 'Manifest cadangan tidak ditemukan.'; return 1; }
    [[ "$(/usr/bin/plutil -extract uid raw -o - "$manifest")" == "$(/usr/bin/id -u)" && "$(/usr/bin/plutil -extract policy_path raw -o - "$manifest")" == "$policy_file" ]] || {
      fail 'Cadangan berasal dari akun atau lokasi instalasi berbeda.'; return 1
    }
    old_lps=$(/usr/bin/plutil -extract lps_before raw -o - "$manifest")
    lps_touched=$(/usr/bin/plutil -extract lps_touched raw -expect bool -o - "$manifest")
    [[ "$old_lps" == missing || "$old_lps" == 0 || "$old_lps" == 1 ]] || { fail 'Preferensi cadangan tidak valid.'; return 1; }
    staged_file=$(/usr/bin/mktemp "$restore_dir/restore.XXXXXX")
    stage_policy restore "$policy_file" "$restore_dir/app_permissions.before.json" "$staged_file" || return 1
    stop_components frontend
    write_policy "$staged_file" "$policy_file" || return 1
    [[ "$lps_touched" != true ]] || restore_lps "$old_lps"
    reload_agent || return 1
    verify_policy "$staged_file" "$policy_file" || return 1
    [[ "$lps_touched" != true || "$(lps_value)" == "$old_lps" ]] || { fail 'Pemulihan preferensi Plugin Service gagal.'; return 1; }
    [[ "$lps_touched" != true || "$old_lps" != 1 || -z "$lps_bundle" ]] || /usr/bin/open -g "$lps_bundle"
    print 'Nilai fitur awal dipulihkan. Profil perangkat tidak diubah.'
    return 0
  fi
  for flag in "${OPTIONAL_FLAGS[@]}"; do
    if value=$(bool_value "$policy_file" "$flag") && [[ "$value" == true ]]; then (( changes += 1 )); fi
  done
  if (( changes == 0 )) && [[ "$lps_touched" == false || "$old_lps" == 0 ]]; then
    print 'Sudah dirampingkan. Tidak membuat cadangan baru atau mengubah pengaturan.'
    return 0
  fi
  /bin/mkdir -p "$state_root/backups"
  backup_dir=$(/usr/bin/mktemp -d "$state_root/backups/$(/bin/date +%Y%m%dT%H%M%S).XXXXXX")
  /bin/cp "$policy_file" "$backup_dir/app_permissions.before.json"
  manifest="$backup_dir/manifest.plist"
  /usr/bin/plutil -create xml1 "$manifest"
  /usr/bin/plutil -insert uid -integer "$(/usr/bin/id -u)" "$manifest"
  /usr/bin/plutil -insert policy_path -string "$policy_file" "$manifest"
  /usr/bin/plutil -insert lps_before -string "$old_lps" "$manifest"
  /usr/bin/plutil -insert lps_touched -bool "$lps_touched" "$manifest"
  /usr/bin/plutil -insert app_version -string "$version" "$manifest"
  staged_file="$backup_dir/app_permissions.after.json"
  stage_policy apply "$policy_file" '' "$staged_file" || return 1
  print -- "Cadangan: $backup_dir"
  stop_components frontend
  /usr/bin/cmp -s "$policy_file" "$backup_dir/app_permissions.before.json" || { fail 'Kebijakan berubah ketika skrip berjalan; jalankan ulang setelah update selesai.'; return 1; }
  write_policy "$staged_file" "$policy_file" || return 1
  [[ "$lps_touched" != true ]] || /usr/bin/defaults write "$LPS_DOMAIN" "$LPS_KEY" -bool false
  stop_components plugins
  if ! reload_agent; then
    print -u2 -- "Cadangan tersedia: $backup_dir. Jalankan skrip dengan --restore untuk membatalkan pengaturan."
    return 1
  fi
  verify_policy "$staged_file" "$policy_file" || return 1
  for flag in "${OPTIONAL_FLAGS[@]}"; do
    if value=$(bool_value "$policy_file" "$flag"); then
      [[ "$value" == false ]] || { fail "Verifikasi '$flag' gagal. Cadangan: $backup_dir"; return 1; }
    fi
  done
  [[ "$lps_touched" != true || "$(lps_value)" == 0 ]] || { fail 'Verifikasi Plugin Service gagal.'; return 1; }
  print 'Selesai. Fitur opsional nonaktif; agent perangkat tetap aktif.'
  print 'Update, firmware, backlight, dan profil tombol/scroll tidak diubah.'
  print 'Antarmuka Electron tetap digunakan saat Options+ dibuka.'
  print -- "Pemulihan: jalankan skrip ini dengan --restore. Cadangan: $backup_dir"
}

# Sourcing only defines functions, so policy transformations can be tested offline.
if [[ "$ZSH_EVAL_CONTEXT" == toplevel ]]; then main "$@"; fi
