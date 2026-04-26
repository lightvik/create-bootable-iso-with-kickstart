#!/usr/bin/env bash
set -euo pipefail

WORK_DIR="/workdir"

# Выходные переменные, устанавливаемые в prepare_cfg и используемые в build_iso
GRUB_CFG=""
ISOLINUX_CFG=""

# ── утилиты ───────────────────────────────────────────────────────────────────

die() { echo "ОШИБКА: $*" >&2; exit 1; }

ask() {
  local prompt="${1}" default="${2}" answer
  printf '%s [%s]: ' "${prompt}" "${default}" >&2
  read -r answer
  printf '%s' "${answer:-${default}}"
}

section() { echo; echo "─── $* ───"; }

# ── шаг 1: входной ISO ───────────────────────────────────────────────────────

detect_label() {
  xorriso -indev "${1}" 2>&1 \
    | sed -n "s/.*Volume id[[:space:]]*: '\\(.*\\)'.*/\\1/p" \
    | head -1
}

select_input_iso() {
  if [[ -n "${INPUT_ISO_FILENAME:-}" ]]; then
    local p="${WORK_DIR}/${INPUT_ISO_FILENAME}"
    [[ -f "${p}" ]] || die "INPUT_ISO_FILENAME: файл не найден: ${p}"
    echo "${p}"; return
  fi

  local -a isos
  mapfile -t isos < <(find "${WORK_DIR}" -maxdepth 1 -name '*.iso' | sort)
  [[ ${#isos[@]} -gt 0 ]] || die "*.iso файлы не найдены в ${WORK_DIR}"

  if [[ ${#isos[@]} -eq 1 ]]; then
    printf 'Найден: %s\n' "$(basename "${isos[0]}")" >&2
    echo "${isos[0]}"; return
  fi

  printf 'Найдено несколько ISO файлов:\n' >&2
  local i
  for i in "${!isos[@]}"; do
    printf '  %d) %s\n' "$((i+1))" "$(basename "${isos[i]}")" >&2
  done

  local choice
  choice=$(ask "Выберите ISO" "1")
  [[ "${choice}" =~ ^[0-9]+$ ]] || die "Неверный выбор: ${choice}"
  (( choice >= 1 && choice <= ${#isos[@]} )) || die "Неверный выбор: ${choice}"

  echo "${isos[$((choice-1))]}"
}

# ── шаг 2: выходной файл ─────────────────────────────────────────────────────

select_output_iso() {
  if [[ -n "${OUTPUT_ISO_FILENAME:-}" ]]; then
    echo "${WORK_DIR}/${OUTPUT_ISO_FILENAME}"; return
  fi

  local base ext
  base=$(basename "${1}")
  ext="${base##*.}"
  local default="${base%.*}_kickstart.${ext}"

  local answer
  answer=$(ask "Имя выходного файла" "${default}")
  echo "${WORK_DIR}/${answer}"
}

# ── шаг 3: источник kickstart ────────────────────────────────────────────────

select_ks_source() {
  if [[ -n "${KS_SOURCE:-}" ]]; then
    echo "${KS_SOURCE}"; return
  fi

  printf 'Источник Kickstart:\n' >&2
  printf '  1) cdrom:/ks.cfg  (ks.cfg должен лежать в /workdir)\n' >&2
  printf '  2) HTTP URL\n' >&2

  local choice
  choice=$(ask "Выберите" "1")
  case "${choice}" in
    1)
      [[ -f "${WORK_DIR}/ks.cfg" ]] || die "ks.cfg не найден в ${WORK_DIR}"
      echo "cdrom:/ks.cfg" ;;
    2)
      ask "HTTP URL" "http://192.168.1.1/ks.cfg" ;;
    *)
      die "Неверный выбор: ${choice}" ;;
  esac
}

# ── шаг 4: параметры загрузки ────────────────────────────────────────────────

setup_boot_params() {
  if [[ -z "${BOOT_TIMEOUT:-}" ]]; then
    BOOT_TIMEOUT=$(ask "Таймаут загрузки, секунды" "5")
  fi
  [[ "${BOOT_TIMEOUT}" =~ ^[0-9]+$ ]] \
    || die "BOOT_TIMEOUT должен быть неотрицательным целым числом"

  if [[ -z "${BOOT_DEFAULT:-}" ]]; then
    BOOT_DEFAULT=$(ask "Индекс пункта меню по умолчанию" "0")
  fi
  [[ "${BOOT_DEFAULT}" =~ ^[0-9]+$ ]] \
    || die "BOOT_DEFAULT должен быть неотрицательным целым числом"
}

# ── шаг 5: патчинг cfg ───────────────────────────────────────────────────────

extract_from_iso() {
  local iso_path="${1}" iso_file="${2}" local_path="${3}"
  osirrox -indev "${iso_path}" -extract "${iso_file}" "${local_path}" \
    || die "Не удалось извлечь ${iso_file} из ISO"
  chmod u+w "${local_path}"
}

patch_grub_cfg() {
  local file="${1}" boot_default="${2}" boot_timeout="${3}" ks_source="${4}"
  local rc=0

  # пункт по умолчанию
  if grep -q 'set default=' "${file}"; then
    sed -i "s/set default=.*/set default=\"${boot_default}\"/" "${file}"
  elif grep -q 'set timeout=' "${file}"; then
    sed -i "/set timeout=/i set default=\"${boot_default}\"" "${file}"
  else
    printf '  WARN: не удалось задать default — паттерн "set default=" не найден\n' >&2
    rc=1
  fi

  # таймаут
  if grep -q 'set timeout=' "${file}"; then
    sed -i "s/set timeout=.*/set timeout=${boot_timeout}/" "${file}"
  else
    printf '  WARN: не удалось задать timeout — паттерн "set timeout=" не найден\n' >&2
    rc=1
  fi

  # inst.ks в первую строку linuxefi
  if grep -q 'inst\.ks' "${file}"; then
    printf '  INFO: inst.ks уже присутствует в grub.cfg\n' >&2
  elif grep -q 'linuxefi' "${file}"; then
    awk -v ks="${ks_source}" '
      !done && /linuxefi / { printf "%s inst.ks=%s\n", $0, ks; done=1; next }
      { print }
    ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  else
    printf '  WARN: не удалось добавить inst.ks — "linuxefi" не найден\n' >&2
    rc=1
  fi

  return "${rc}"
}

patch_isolinux_cfg() {
  local file="${1}" boot_default="${2}" boot_timeout="${3}" ks_source="${4}"
  local rc=0
  local isolinux_timeout
  isolinux_timeout=$(( boot_timeout * 10 ))

  # menu default: убираем все вхождения, добавляем после нужного menu label
  if grep -q 'menu label' "${file}"; then
    awk -v target="${boot_default}" '
      BEGIN { count=-1; added=0 }
      /[[:space:]]*menu default/ { next }
      {
        print
        if (/[[:space:]]*menu label/) {
          count++
          if (count == target+0 && !added) { print "  menu default"; added=1 }
        }
      }
    ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  else
    printf '  WARN: не удалось задать default — "menu label" не найден\n' >&2
    rc=1
  fi

  # таймаут (единица isolinux = 1/10 секунды)
  if grep -q '^timeout ' "${file}"; then
    sed -i "s/^timeout .*/timeout ${isolinux_timeout}/" "${file}"
  else
    printf '  WARN: не удалось задать timeout — "^timeout" не найден\n' >&2
    rc=1
  fi

  # inst.ks в первую строку append
  if grep -q 'inst\.ks' "${file}"; then
    printf '  INFO: inst.ks уже присутствует в isolinux.cfg\n' >&2
  elif grep -q 'append ' "${file}"; then
    awk -v ks="${ks_source}" '
      !done && /append / { printf "%s inst.ks=%s\n", $0, ks; done=1; next }
      { print }
    ' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
  else
    printf '  WARN: не удалось добавить inst.ks — "append" не найден\n' >&2
    rc=1
  fi

  return "${rc}"
}

prepare_cfg() {
  local iso_path="${1}" ks_source="${2}" tmp_dir="${3}"
  local failed=false

  if [[ -f "${WORK_DIR}/grub.cfg" ]]; then
    printf '  grub.cfg:     используется /workdir/grub.cfg (автопатчинг пропущен)\n'
    GRUB_CFG="${WORK_DIR}/grub.cfg"
  else
    GRUB_CFG="${tmp_dir}/grub.cfg"
    printf '  grub.cfg:     извлекаем из ISO...\n'
    extract_from_iso "${iso_path}" /EFI/BOOT/grub.cfg "${GRUB_CFG}"
    if patch_grub_cfg "${GRUB_CFG}" "${BOOT_DEFAULT}" "${BOOT_TIMEOUT}" "${ks_source}"; then
      printf '  grub.cfg:     патч применён\n'
    else
      printf '  grub.cfg:     ОШИБКА — положите grub.cfg вручную в /workdir и повторите запуск\n' >&2
      failed=true
    fi
  fi

  if [[ -f "${WORK_DIR}/isolinux.cfg" ]]; then
    printf '  isolinux.cfg: используется /workdir/isolinux.cfg (автопатчинг пропущен)\n'
    ISOLINUX_CFG="${WORK_DIR}/isolinux.cfg"
  else
    ISOLINUX_CFG="${tmp_dir}/isolinux.cfg"
    printf '  isolinux.cfg: извлекаем из ISO...\n'
    if osirrox -indev "${iso_path}" -extract /isolinux/isolinux.cfg "${ISOLINUX_CFG}" >/dev/null 2>&1; then
      chmod u+w "${ISOLINUX_CFG}"
      if patch_isolinux_cfg "${ISOLINUX_CFG}" "${BOOT_DEFAULT}" "${BOOT_TIMEOUT}" "${ks_source}"; then
        printf '  isolinux.cfg: патч применён\n'
      else
        printf '  isolinux.cfg: ОШИБКА — положите isolinux.cfg вручную в /workdir и повторите запуск\n' >&2
        failed=true
      fi
    else
      printf '  isolinux.cfg: отсутствует в ISO (только EFI-загрузка), пропущено\n' >&2
      ISOLINUX_CFG=""
    fi
  fi

  [[ "${failed}" == false ]]
}

# ── шаг 7: сборка ────────────────────────────────────────────────────────────

build_iso() {
  local orig_iso="${1}" new_iso="${2}" iso_label="${3}" ks_source="${4}"

  local -a cmd=(
    xorriso
    -indev  "${orig_iso}"
    -outdev "${new_iso}"
    -volid  "${iso_label}"
    -boot_image any replay
    -map "${GRUB_CFG}" /EFI/BOOT/grub.cfg
  )
  [[ -n "${ISOLINUX_CFG}" ]] && cmd+=(-map "${ISOLINUX_CFG}" /isolinux/isolinux.cfg)
  [[ "${ks_source}" == cdrom:* ]] && cmd+=(-map "${WORK_DIR}/ks.cfg" /ks.cfg)

  rm -f "${new_iso}"
  "${cmd[@]}"
  implantisomd5 "${new_iso}"
  chmod a+rw "${new_iso}"
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
  local tmp_dir
  tmp_dir=$(mktemp -d "${WORK_DIR}/.tmp.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp_dir}'" EXIT

  section "Шаг 1: Входной ISO"
  local orig_iso iso_label
  orig_iso=$(select_input_iso)
  printf 'Выбран:   %s\n' "$(basename "${orig_iso}")"

  iso_label="${ISO_LABEL:-}"
  if [[ -z "${iso_label}" ]]; then
    iso_label=$(detect_label "${orig_iso}")
    [[ -n "${iso_label}" ]] || die "Не удалось определить метку тома ISO"
    printf 'Метка:    %s\n' "${iso_label}"
  else
    printf 'Метка:    %s (из переменной окружения)\n' "${iso_label}"
  fi

  section "Шаг 2: Выходной файл"
  local new_iso
  new_iso=$(select_output_iso "${orig_iso}")
  printf 'Файл:     %s\n' "$(basename "${new_iso}")"

  section "Шаг 3: Источник Kickstart"
  local ks_source
  ks_source=$(select_ks_source)
  printf 'Источник: %s\n' "${ks_source}"

  section "Шаг 4: Параметры загрузки"
  setup_boot_params
  printf 'Таймаут:  %sс  |  Пункт по умолчанию: %s\n' "${BOOT_TIMEOUT}" "${BOOT_DEFAULT}"

  section "Шаг 5: Подготовка cfg файлов"
  prepare_cfg "${orig_iso}" "${ks_source}" "${tmp_dir}" \
    || die "Автопатчинг не удался. Положите проблемные cfg файлы в /workdir и повторите запуск."

  section "Шаг 6: Сводка"
  printf '  %-18s %s\n' "Входной ISO:"       "$(basename "${orig_iso}")"
  printf '  %-18s %s\n' "Метка ISO:"         "${iso_label}"
  printf '  %-18s %s\n' "Выходной ISO:"      "$(basename "${new_iso}")"
  printf '  %-18s %s\n' "Источник KS:"       "${ks_source}"
  printf '  %-18s %s\n' "Таймаут:"           "${BOOT_TIMEOUT}с"
  printf '  %-18s %s\n' "Пункт по умолч.:"   "${BOOT_DEFAULT}"
  echo

  local confirm
  confirm=$(ask "Продолжить?" "Y")
  [[ "${confirm}" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }

  section "Шаг 7: Сборка ISO"
  build_iso "${orig_iso}" "${new_iso}" "${iso_label}" "${ks_source}"

  echo
  printf 'Готово: %s\n' "$(basename "${new_iso}")"
}

main "$@"
