# Meepo — Project Rules

## Custom Commands

- `/plan` — планирование перед реализацией (исследование → архитектура → фазы)
- `/investigate` — структурированная отладка бага (root cause → fix → verify)
- `/simplify` — code review: reuse, quality, efficiency (встроен)
- `/qa` — QA-тестирование через браузер/симулятор
- `/security` — аудит безопасности (OWASP)
- `/ship` — сборка, тесты, коммит, push (только по явной просьбе)
- `/retro` — ретроспектива сессии
- `/sync` — актуализация memory
- `/updates` — проверка обновлений Claude Code / Anthropic

Subagents: `code-reviewer`, `security-auditor`.

## Workflow

**Think → Plan → Build → Review → Ship**

1. Перед большой задачей: `/plan`
2. Реализация по фазам
3. После кода: `/simplify` или `code-reviewer`
4. Если баг: `/investigate`
5. Перед push: `/ship`
6. В конце дня: `/retro`

## Spec

Полное ТЗ: [`SPEC.md`](SPEC.md). Модули собираются строго по порядку (раздел 6), каждый: `/plan` → подтверждение → реализация → `/qa` → `/ship` → `/sync`.

## Stack

- Swift + SwiftUI, macOS 14+ (`MenuBarExtra` для строки меню)
- SwiftTerm — встроенные терминалы
- SQLite через GRDB
- Локальный HTTP-сервер на `127.0.0.1` (Network.framework) — приём событий хуков
- WidgetKit — виджет (последний модуль)
- Внешние CLI: `claude`, `git`, `gh`, `ssh`, `docker`

## Build

Проект описан в `project.yml` (XcodeGen); `Meepo.xcodeproj` генерируется и не коммитится.

- Генерация: `xcodegen generate` (после изменения `project.yml` или добавления файлов)
- Сборка: `xcodebuild -project Meepo.xcodeproj -scheme Meepo -skipPackagePluginValidation build`
- Тесты: `xcodebuild -project Meepo.xcodeproj -scheme Meepo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation test`
- `-skipPackagePluginValidation` — у SwiftTerm build-плагин (генерирует build info); в Xcode GUI нажать «Trust & Enable»
- SwiftTerm содержит Metal-шейдеры: один раз `xcodebuild -downloadComponent MetalToolchain`
- `claude` запускается через `$SHELL -l -i -c` — чтобы подхватить PATH из `.zshrc` (nvm)
- База: `~/.meepo/meepo.sqlite` (миграции в `Meepo/Storage/AppDatabase.swift`)
- Цвета — только через `Meepo/Design/Tokens.swift`

## Project Structure

<!-- TODO: заполнить, когда появится код -->

## Conventions

- Коммиты на английском: feat/fix/chore prefix; коммит/push — только по явной просьбе
- UI на английском (решение 2026-09-23: пиксельный шрифт Silkscreen без кириллицы); общение с пользователем — по-русски
- Следуй правилам из `~/.claude/CLAUDE.md` (simplicity, surgical changes)
