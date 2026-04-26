# План улучшений

## CI

- Создать `.github/workflows/ci.yml`
- Шаги: `hadolint/hadolint-action` (Dockerfile) + `ludeeus/action-shellcheck` (entrypoint.sh)
- Триггеры: push + pull_request
