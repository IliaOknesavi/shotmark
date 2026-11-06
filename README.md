# Shotmark

Скриншоты с разметкой для macOS в духе ShareX, целиком управляемые через MCP. Приложение живёт в строке меню.

## Сборка

```bash
scripts/build.sh          # SwiftPM, без Xcode; кладёт ~/Applications/Shotmark.app
open ~/Applications/Shotmark.app
```

Нужен macOS 15+. Подпись ad-hoc: после каждой пересборки macOS заново спрашивает разрешение на запись экрана. Стабильная подпись: `CODESIGN_ID="имя сертификата" scripts/build.sh`.

## Сочетания

| Клавиши | Действие |
|---|---|
| ⌘⇧3 | весь монитор под курсором сразу в буфер обмена и историю |
| ⌘⇧4 | экран замирает: рисуешь прямо на нём, инструмент «Область» (C) — тянуть область или кликнуть окно; ↩/⌘C — копировать, ⌘S — на рабочий стол, ⌘E — в редактор, Esc — отмена |
| ⌘⇧5 | запись области или окна в MP4 (~/Movies/Shotmark); повторно — стоп |

Пока включены системные ⌘⇧3/4/5, их перехватывает macOS. В меню Shotmark есть пункт «Отключить системные сочетания скриншотов» (и «Вернуть»).

Инструменты (одной клавишей): область C, стрелка A, линия L, прямоугольник R, эллипс E, перо P, маркер M, текст T, выноска O, шаг N, размытие B, пикселизация X, лупа Z. Shift — ровные углы и квадраты. ⌘Z / ⌘⇧Z. Обычный редактор открывается для старых снимков и картинок из файлов.

## MCP

Сервер внутри приложения: `http://127.0.0.1:47830/mcp` (Streamable HTTP), токен в `~/Library/Application Support/Shotmark/token`. Подключение к Claude Code — пункт меню «Скопировать команду подключения MCP».

Инструменты: `list_displays`, `list_windows`, `capture_screen`, `capture_area`, `capture_window`, `capture_app`, `ask_user_capture`, `open_image`, `open_editor`, `annotate`, `get_annotations`, `remove_annotations`, `undo`, `redo`, `crop`, `export`, `history`, `get_image`, `start_recording`, `stop_recording`.

Снимки и их разметка: `~/Library/Application Support/Shotmark/shots/<id>.png|json`.
