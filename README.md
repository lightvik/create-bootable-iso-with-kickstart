<div align="center">
  <img src="logo-dark.svg#gh-dark-mode-only" alt="create-bootable-iso-with-kickstart" width="570">
  <img src="logo-light.svg#gh-light-mode-only" alt="create-bootable-iso-with-kickstart" width="570">
</div>

## Описание

Инструмент автоматически патчит `grub.cfg` и `isolinux.cfg` внутри ISO образа и добавляет файл `ks.cfg` для автоматической установки Oracle Linux.

## Использование

### 1. Скачать ISO образ

[Oracle Linux ISO](https://yum.oracle.com/oracle-linux-isos.html)

### 2. Подготовить ks.cfg (при необходимости)

Если планируется встраивать `ks.cfg` внутрь образа — положить его рядом с ISO.

Рекомендуется взять за основу `/root/anaconda-ks.cfg` из уже установленной системы.  
Пример: [examples/ks.cfg](examples/ks.cfg)  
Документация: [Kickstart](https://pykickstart.readthedocs.io/en/latest/kickstart-docs.html)

### 3. Запустить контейнер

```bash
docker run \
  --interactive \
  --tty \
  --rm \
  --volume "${PWD}:/workdir" \
  ghcr.io/lightvik/create-bootable-iso-with-kickstart:1.0.0
```

Контейнер запустится в интерактивном режиме и задаст вопросы:

- **Входной ISO** — если в каталоге один файл `.iso`, выбирается автоматически
- **Выходной файл** — по умолчанию `<имя>_kickstart.iso`
- **Источник Kickstart** — `cdrom:/ks.cfg` (встроить в образ) или HTTP URL
- **Таймаут загрузки** — в секундах, по умолчанию `5`
- **Пункт меню по умолчанию** — индекс с нуля, по умолчанию `0`

### 4. Неинтерактивный режим

Все параметры можно передать через переменные окружения:

| Переменная | Описание | Пример |
| --- | --- | --- |
| `INPUT_ISO_FILENAME` | Имя входного ISO | `OracleLinux-R10-U1-x86_64-dvd.iso` |
| `OUTPUT_ISO_FILENAME` | Имя выходного ISO | `OracleLinux-R10-U1-x86_64-dvd_kickstart.iso` |
| `ISO_LABEL` | Метка тома (определяется автоматически) | `OL-10-1-0-BaseOS-x86_64` |
| `KS_SOURCE` | Источник Kickstart | `cdrom:/ks.cfg` или `http://192.168.1.1/ks.cfg` |
| `BOOT_TIMEOUT` | Таймаут в секундах | `5` |
| `BOOT_DEFAULT` | Индекс пункта меню | `0` |

Пример:

```bash
docker run \
  --interactive \
  --tty \
  --rm \
  --volume "${PWD}:/workdir" \
  --env "INPUT_ISO_FILENAME=OracleLinux-R10-U1-x86_64-dvd.iso" \
  --env "KS_SOURCE=cdrom:/ks.cfg" \
  --env "BOOT_TIMEOUT=5" \
  --env "BOOT_DEFAULT=0" \
  ghcr.io/lightvik/create-bootable-iso-with-kickstart:1.0.0
```

### Ручное управление cfg файлами

Если автоматический патчинг не подходит — положить `grub.cfg` и/или `isolinux.cfg` рядом с ISO в `/workdir`. Контейнер использует их напрямую без изменений.

## Разработка ks.cfg

```bash
docker run \
  --interactive \
  --tty \
  --rm \
  --volume "${PWD}:/workdir" \
  ghcr.io/lightvik/create-bootable-iso-with-kickstart:1.0.0
```

Для разработки `ks.cfg` удобно использовать HTTP:

```bash
python3 -m http.server
```

И собрать образ с `KS_SOURCE=http://<ip>:8000/ks.cfg`
