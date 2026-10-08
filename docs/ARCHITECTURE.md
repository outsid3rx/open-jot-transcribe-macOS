# Архитектура Jot

Jot — нативное приложение строки меню macOS. `App` содержит окна, меню, HUD и связывание компонентов; локальный Swift Package `JotCore` — основные сервисы и тесты. Настройка сборки находится в [project.yml](../project.yml); зависимости — в [Package.swift](../JotCore/Package.swift).

## Модули

| Область | Ответственность |
| --- | --- |
| [AppDelegate](../App/Sources/AppDelegate.swift) | Запуск, единственный экземпляр, миграции и URL-схема |
| [DictationController](../App/Sources/DictationController.swift) | Сервисы, горячие клавиши, HUD, окна и уведомления |
| [SessionCoordinator](../JotCore/Sources/SessionCoordinator/DictationCoordinator.swift) | Жизненный цикл сеанса и сохранение его состояния |
| [HotkeyEngine](../JotCore/Sources/HotkeyEngine/EventTapEngine.swift) | CGEventTap и жесты клавиши диктовки |
| [AudioEngine](../JotCore/Sources/AudioEngine/AudioCaptureEngine.swift) | Захват звука, CAF, уровни и смена устройства |
| [TranscriptionService](../JotCore/Sources/TranscriptionClient/TranscriptionService.swift) | Выбор API, подготовка аудио, распознавание и очистка |
| [FormattingPipeline](../JotCore/Sources/FormattingPipeline/ValidationGate.swift) | Инструкции, проверка результата и словарные замены |
| [InsertionEngine](../JotCore/Sources/InsertionEngine/InsertionCoordinator.swift) | Вставка через Accessibility, paste и буфер обмена |
| [HistoryStore](../JotCore/Sources/HistoryStore/HistoryStore.swift) | Индекс GRDB, поиск и статистика |
| [RetryQueue](../JotCore/Sources/HistoryStore/RetryQueue.swift) | Последовательные повторы с сохранёнными параметрами |
| [Settings](../JotCore/Sources/Settings/SettingsStore.swift) | UserDefaults, конфигурация API и язык интерфейса |
| [KeychainStore](../JotCore/Sources/Support/KeychainStore.swift) | Ключи API в macOS Keychain |

## Сеанс диктовки

Основной поток: ожидание → запуск захвата → запись → завершение файла → распознавание → вставка → результат. Параллельно сохраняется `meta.json`: UUID, статус, целевое приложение, длительность, тексты, ошибки и копия конфигурации API. Асинхронные завершения проверяют UUID сеанса.

CAF — основной аудиофайл для восстановления. Для запроса вне главного потока готовится WAV или FLAC. Исходная расшифровка записывается до необязательной очистки. [Описание адаптеров](design/external-transcription-providers-plan.md) раскрывает маршруты и ограничения.

Координатор управляет одним активным сеансом. Очередь истории обрабатывает записи последовательно и сохраняет результаты без вставки в потерянный фокус. Восстановление при запуске использует файлы сеансов; полученный ранее текст восстанавливается без повторной отправки аудио.

## Вставка и защищённый ввод

Порядок вставки: Accessibility → контролируемая вставка из буфера → текст в буфере для ручного paste. Смена целевого приложения учитывается; защищённый ввод блокирует начало записи либо удерживает уже полученный текст в истории. Содержимое окружающего текста и снимки экрана не отправляются.

## Хранение и зависимости

`~/Library/Application Support/Jot/recordings/` содержит папки сеансов. `meta.json` и аудиофайлы служат исходными данными, база GRDB — восстанавливаемым индексом. Срок хранения аудио настраивается отдельно от текста; удаление аудио ограничивает повторное распознавание.

Текущие сторонние Swift-зависимости — GRDB и Sauce. Sparkle, KeyboardShortcuts, локальное распознавание, FTS5-поиск и система удалённых асинхронных заданий не входят в эту реализацию. Поиск истории использует запросы к индексу SQLite.

## Интерфейс, сборка и проверка

Русский используется по умолчанию, English выбирается в общих настройках и применяется после перезапуска. Пользовательские строки находятся в ресурсах `JotCore/Sources/Resources/{ru,en}.lproj`; ключи, модели и текст диктовки не переводятся.

URL-схема из `AppDelegate` поддерживает `jot://settings/general` (также `dictation`, `privacy`, `advanced`, `about`), `jot://history`, `jot://dictionary`, `jot://onboarding`, `jot://start-hands-free` и `jot://stop`. Ссылки `start` и `toggle` из старого плана не реализованы. В Debug дополнительно доступен `jot://set/<key>/<true|false>` для поддерживаемых переключателей.

Приложение собирается через XcodeGen/Xcode или локальный CLT-скрипт. [CI](../.github/workflows/ci.yml) запускает XCTest и проверку сборки; релизы публикуются вручную. Контрактные проверки API работают с URLProtocol, временной историей и синтетическим аудио. Они не подтверждают работу оборудования или качество облачной модели.

[Исторические планы](README.md#исторические-материалы-исходного-проекта) сохранены отдельно от актуального описания. При расхождении приоритет имеют код, конфигурация и проверенные результаты текущей версии.
