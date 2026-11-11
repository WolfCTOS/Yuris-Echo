using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace LuaApiLauncher;

/// <summary>
/// Launcher UI language. Russian strings are the keys; English is the default
/// and is looked up from the dictionary below.
/// </summary>
public static class L10n
{
    public const string English = "en";
    public const string Russian = "ru";

    /// <summary>Pre-launch warning for the two mods that fight over the same AI units.</summary>
    public const string AiModConflictMessage =
        "ВНИМАНИЕ: Sector и Smart AI включены одновременно — они конкурируют за одни юниты. Отключите один из модов.";

    public static string Current { get; private set; } = English;

    public static string Normalize(string? code) =>
        string.Equals(code, Russian, StringComparison.OrdinalIgnoreCase) ? Russian : English;

    public static void SetLanguage(string? code) => Current = Normalize(code);

    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, byte> _untranslatedLogged = new(StringComparer.Ordinal);
    private static volatile bool _auditEnabled;
    private static string? _auditLogPath;

    /// <summary>Enable runtime audit logging of untranslated EN strings (via --l10n-audit or L10N_AUDIT=1).</summary>
    public static void EnableAudit(string? logPath = null)
    {
        _auditEnabled = true;
        _auditLogPath = logPath ?? System.IO.Path.Combine(AppContext.BaseDirectory, "l10n-audit.log");
    }

    public static string T(string ru)
    {
        if (Current == Russian) return ru;
        if (En.TryGetValue(ru, out var en)) return en;
        LogUntranslated(ru);
        return ru;
    }

    [System.Diagnostics.Conditional("DEBUG")]
    private static void LogUntranslatedDebug(string ru)
    {
        System.Diagnostics.Debug.WriteLine("[L10N-MISSING-EN] " + ru);
    }

    private static void LogUntranslated(string ru)
    {
        if (Current != English) return;
        if (!System.Text.RegularExpressions.Regex.IsMatch(ru, "[\u0400-\u04FF]")) return;
        if (_untranslatedLogged.TryAdd(ru, 0))
        {
            LogUntranslatedDebug(ru);
            if (_auditEnabled)
            {
                try
                {
                    var path = _auditLogPath ?? System.IO.Path.Combine(AppContext.BaseDirectory, "l10n-audit.log");
                    System.IO.File.AppendAllText(path, "[L10N-MISSING-EN] " + ru + System.Environment.NewLine, System.Text.Encoding.UTF8);
                }
                catch { }
            }
        }
    }

    public static string F(string ru, params object?[] args) => string.Format(T(ru), args);

    // Keyed by the exact Russian text; values are English.
    private static readonly Dictionary<string, string> En = new(StringComparer.Ordinal)
    {
        // ---- main menu ----
        ["ГЛАВНОЕ МЕНЮ"] = "MAIN MENU",
        ["Скирмиш"] = "Skirmish",
        ["СКИРМИШ"] = "SKIRMISH",
        ["Играть"] = "Play",
        ["ЗАГРУЗИТЬ ИГРУ"] = "LOAD GAME",
        ["Кампания"] = "Campaign",
        ["КАМПАНИЯ"] = "CAMPAIGN",
        ["ВЫБОР МИССИИ"] = "MISSION SELECT",
        ["КАМПАНИЯ / СТОРОНА"] = "CAMPAIGN / SIDE",
        ["СТОРОНА"] = "SIDE",
        ["МИССИИ"] = "MISSIONS",
        ["ОПИСАНИЕ МИССИИ"] = "MISSION DESCRIPTION",
        ["СЛОЖНОСТЬ"] = "DIFFICULTY",
        ["ЗАПУСТИТЬ МИССИЮ"] = "START MISSION",
        ["Альянс"] = "Allied",
        ["Советский Союз"] = "Soviet Union",
        ["Учебный лагерь"] = "Boot Camp",
        ["Опции"] = "Options",
        ["ОПЦИИ"] = "OPTIONS",
        ["Статистика"] = "Statistics",
        ["СТАТИСТИКА"] = "STATISTICS",
        ["Редактор карт"] = "Map Editor",
        ["РЕДАКТОР КАРТ"] = "MAP EDITOR",
        ["Выход"] = "Exit",
        ["ВЫХОД"] = "EXIT",
        ["Готов"] = "Ready",
        ["ГОТОВ"] = "READY",
        ["НЕТ"] = "NO",

        // ---- skirmish ----
        ["КАРТЫ"] = "MAPS",
        ["РЕЖИМ ИГРЫ"] = "GAME MODE",
        ["Все карты"] = "All maps",
        ["Прочие"] = "Other",
        ["Ничего не найдено в режиме {0}. Искать во всех?"] = "Nothing found in {0} mode. Search in all?",
        ["Искать во всех"] = "Search in all",
        ["Превью нет"] = "No preview",
        ["МОДЫ"] = "MODS",
        ["МОДЫ {0}/{1}"] = "MODS {0}/{1}",
        ["НАБОР МОДОВ"] = "MOD SET",
        ["ПОИСК МОДА..."] = "SEARCH MODS...",
        ["Будет загружено модов: {0}"] = "Mods to load: {0}",
        ["Сохранить текущий выбор как набор «Мой набор»"] = "Save the current selection as “My set”",
        ["LMM не нужен: лаунчер сам применяет active_mods.txt и запускает игру с LuaAPI."] =
            "No mod manager needed: the launcher writes active_mods.txt and starts the game with LuaAPI.",
        ["Ванильный"] = "Vanilla",
        ["Мой набор"] = "My set",
        ["Баланс"] = "Balance",
        ["ИИ"] = "AI",
        ["Контент"] = "Content",
        ["Показывать dev-моды"] = "Show dev mods",
        ["Моды не найдены."] = "No mods found.",
        ["Выберите мод"] = "Select a mod",
        ["не указан"] = "not specified",
        ["Включён конфликт с: {0}"] = "Enabled conflict with: {0}",
        ["КОНФЛИКТЫ: "] = "CONFLICTS: ",
        ["Конфликт с включённым модом: {0}"] = "Conflict with enabled mod: {0}",
        ["НАСТРОЙКИ"] = "SETTINGS",
        ["ИГРОКИ"] = "PLAYERS",
        ["ПОИСК КАРТЫ..."] = "SEARCH MAPS...",
        ["МЕНЕДЖЕР МОДОВ"] = "MOD MANAGER",
        ["Порядок загрузки"] = "Load order",
        ["Открыть папку модов"] = "Open mods folder",
        ["№"] = "#",
        ["ИМЯ"] = "NAME",
        ["ФРАКЦИЯ"] = "FACTION",
        ["ЦВЕТ"] = "COLOR",
        ["КОМ."] = "TEAM",
        ["СТАРТ"] = "START",
        ["+ ИИ-СЛОТ"] = "+ AI SLOT",
        ["Случайно"] = "Random",
        ["Удалить слот"] = "Remove slot",
        ["Минимум 2 слота"] = "At least two slots",
        ["КОМАНДА"] = "TEAM",
        ["СЛОТ"] = "SLOT",
        ["ИГРОК"] = "PLAYER",
        ["ИИ {0}"] = "AI {0}",
        ["Команда {0}"] = "Team {0}",
        ["авто"] = "auto",
        ["поз. {0}"] = "pos. {0}",
        ["Позиции карты не определены"] = "Map start positions could not be determined",
        ["Карта рассчитана на {0} игроков"] = "This map supports up to {0} players",
        ["На этой карте максимум {0} игроков, сейчас {1}. Удалите лишние слоты."] =
            "This map supports up to {0} players, but {1} slots are set. Remove extra slots.",
        ["Одна стартовая позиция выбрана у двух игроков."] =
            "The same start position is selected for two players.",
        ["ИГРОВЫЕ ОПЦИИ"] = "GAME OPTIONS",
        ["ПРАВИЛА"] = "RULES",
        ["СТАРТОВЫЕ ДЕНЬГИ"] = "STARTING CREDITS",
        ["СКОРОСТЬ ИГРЫ"] = "GAME SPEED",
        ["СТАРТОВЫЕ ВОЙСКА"] = "STARTING UNITS",
        ["СУПЕРООРУЖИЕ"] = "SUPER WEAPONS",
        ["Все"] = "All",
        ["Стратегические"] = "Strategic",
        ["Тактические"] = "Tactical",
        ["Нет"] = "None",
        ["Короткая игра"] = "Short game",
        ["Автопочинка"] = "Auto repair",
        ["Мульти-инженер"] = "Multi engineer",
        ["Разрушаемые мосты"] = "Destroyable bridges",
        ["Строительство у союзников"] = "Build by ally",
        ["MCV-паки"] = "MCV repacks",
        ["Союзы в игре"] = "Ingame allying",
        ["Ящики с бонусами"] = "Crates appear",
        ["Победа, когда все вражеские постройки уничтожены."] = "Players win when all enemy buildings are destroyed.",
        ["Здания чинят себя сами."] = "Buildings automatically repair themselves.",
        ["Для захвата сооружения нужны три инженера вместо одного."] = "Capturing a structure requires three Engineers instead of one.",
        ["Низкие мосты можно разрушить выстрелом."] = "Low bridges can be destroyed by force-firing on them.",
        ["Разрешить строить рядом с базами союзников."] = "Allow players to build near their allies' construction yards.",
        ["Командный центр можно переместить после развёртывания."] = "Players can move their command center after it is deployed.",
        ["Игроки могут создавать и разрывать союзы."] = "Players can form and break alliances in game.",
        ["На карте появляются ящики с бонусами."] = "Random power-up crates appear on the map.",
        ["Опции применяются при запуске игры через спавнер (кампания). Скорость игры действует сразу."] =
            "The options apply when the game is started through the spawner (campaign). Game speed applies right away.",
        ["По фильтру «{0}» ничего не найдено."] = "Nothing found for the filter \"{0}\".",
        ["Мод Yuri's Echo и остальные включены здесь. Лаунчер применяет active_mods.txt и запускает игру с LuaAPI — LMM не нужен."] =
            "The Yuri's Echo mod and the others are enabled here. The launcher applies active_mods.txt and starts the game with LuaAPI - LMM is not needed.",
        ["MODS — ФАЙЛЫ МОДОВ"] = "MODS — MOD FILES",
        ["ЗАПУСТИТЬ СКИРМИШ"] = "START SKIRMISH",
        ["НАЗАД"] = "BACK",

        // ---- options / tabs ----
        ["НАСТРОЙКИ"] = "SETTINGS",
        ["ГРАФИКА"] = "GRAPHICS",
        ["ЗВУК"] = "SOUND",
        ["ИГРА"] = "GAME",
        ["ХРАНИЛИЩЕ"] = "STORAGE",
        ["ОБНОВЛЕНИЯ"] = "UPDATES",
        ["КОМПОНЕНТЫ"] = "COMPONENTS",

        // ---- graphics ----
        ["Разрешение в игре"] = "In-game resolution",
        ["Детализация"] = "Detail level",
        ["Враппер/Отрисовщик"] = "Renderer",
        ["Оконный режим"] = "Windowed mode",
        ["Безрамочный оконный режим"] = "Borderless windowed mode",
        ["Запасной буфер в видеопамяти"] = "Back buffer in video memory",
        ["Разр. клиента"] = "Client resolution",
        ["Полноэкранный клиент"] = "Fullscreen client",
        ["Целочисленное масштабирование"] = "Integer scaled client",
        ["Язык"] = "Language",
        ["Низкая"] = "Low",
        ["Средняя"] = "Medium",
        ["Высокая"] = "High",
        ["Легко"] = "Easy",
        ["Нормально"] = "Normal",
        ["Сложно"] = "Hard",
        ["Английский"] = "English",
        ["Русский"] = "Russian",

        // ---- sound ----
        ["Громкость музыки"] = "Music volume",
        ["Громкость звука"] = "Sound volume",
        ["Громкость голоса"] = "Voice volume",
        ["Громкость клиента"] = "Client volume",
        ["Разрешить насмешки"] = "Allow taunts",
        ["Значения 0–10, как в CnCNet-клиенте: тяните ползунок или впишите число. В RA2MD.INI сохраняется доля 0–1."] =
            "Values 0–10 as in the CnCNet client: drag the slider or type a number. RA2MD.INI stores the 0–1 fraction.",

        // ---- game ----
        ["Скорость"] = "Game speed",
        ["Сложность"] = "Difficulty",
        ["Быстрый выход"] = "Quick exit",
        ["Подсказки"] = "Tooltips",
        ["Разрешить чат"] = "Allow chat",
        ["Пропускать таблицу результатов"] = "Skip score screen",
        ["Записывать реплеи"] = "Record replays",
        ["Массовое выделение: только боевые"] = "Mass selection: combat units only",
        ["Показывать дельту энергии"] = "Show power delta",
        ["Счётчик рудокопов"] = "Show harvester counter",
        ["Предпросмотр здания при постройке"] = "Show building placement preview",
        ["ЗАПУСК"] = "LAUNCH",
        ["Аргументы"] = "Arguments",

        // ---- storage ----
        ["ЗАНЯТО НА ДИСКЕ"] = "DISK USAGE",
        ["ДИСК"] = "DISK",
        ["ОТКРЫТЬ ПАПКУ ИГРЫ"] = "OPEN GAME FOLDER",
        ["Кнопка только открывает папку в проводнике; она ничего не удаляет."] =
            "This button only opens the folder in Explorer; it does not delete anything.",

        // ---- updates ----
        ["КАНАЛ ОБНОВЛЕНИЙ"] = "UPDATE CHANNEL",
        ["Канал"] = "Channel",
        ["ОБНОВЛЕНИЕ КЛИЕНТА"] = "CLIENT UPDATE",
        ["Каналы Pre-release и Dev нужны для тестирования будущих версий: возможны неожиданные ошибки. О проблемах сообщайте в Discord, указывая выбранный канал."] =
            "Pre-release and Dev channels are for testing upcoming versions: unexpected errors are possible. Report issues on Discord and mention the selected channel.",
        ["ПОДДЕРЖКА (DISCORD)"] = "SUPPORT (DISCORD)",
        ["Файлы обновляет апдейтер CnCNet-клиента; лаунчер только переключает канал."] =
            "The CnCNet client updater handles files; the launcher only switches the channel.",

        // ---- components ----
        ["КОМПОНЕНТЫ КЛИЕНТА"] = "CLIENT COMPONENTS",
        ["Недостающие компоненты скачивает апдейтер CnCNet-клиента; лаунчер их не загружает и не удаляет."] =
            "The CnCNet client updater downloads missing components; the launcher does not download or delete them.",

        ["ВИДЕО И ЗВУК"] = "VIDEO & SOUND",
        ["Игра"] = "Game",
        ["Клиент"] = "Client",
        ["Звук"] = "Sound",
        ["Интерфейс"] = "Interface",
        ["Полноэкранный"] = "Fullscreen",
        ["Оконный"] = "Windowed",
        ["Безрамочный"] = "Borderless",
        ["Есть несохранённые изменения"] = "Unsaved changes",
        ["Сбросить по умолчанию"] = "Reset to defaults",
        ["Сбросить настройки этого экрана к значениям по умолчанию?"] = "Reset this screen's settings to default values?",
        ["Отменить изменения?"] = "Discard changes?",
        ["Значения 0-10, как в CnCNet-клиенте. В RA2MD.INI хранится дробь 0-1."] = "Values 0-10 as in the CnCNet client. RA2MD.INI stores the 0-1 fraction.",
        ["Пользовательский канал"] = "Custom channel",
        ["Нет файла канала: "] = "Channel file not found: ",
        ["Неизвестный канал: "] = "Unknown channel: ",
        ["Режим экрана"] = "Display mode",
        ["Применится после перезапуска"] = "Takes effect after restart",

        // ---- footer ----
        ["СОХРАНИТЬ"] = "SAVE",
        ["ОТМЕНА"] = "CANCEL",

        // ---- mods manager window ----
        ["МЕНЕДЖЕР МОДОВ"] = "MOD MANAGER",
        ["ПОРЯДОК ЗАГРУЗКИ"] = "LOAD ORDER",
        ["ПОРЯДОК ЗАГРУЗКИ: {0}"] = "LOAD ORDER: {0}",
        ["Порядок загрузки"] = "Load order",
        ["ОТКРЫТЬ ПАПКУ МОДОВ"] = "OPEN MODS FOLDER",
        ["Открыть папку модов"] = "Open mods folder",
        ["СПИСОК МОДОВ"] = "MOD LIST",
        ["ДЕТАЛИ"] = "DETAILS",
        ["ФАЙЛЫ .LUA / .JSON"] = "FILES .LUA / .JSON",
        ["ВКЛЮЧИТЬ ВСЕ"] = "ENABLE ALL",
        ["ВЫКЛЮЧИТЬ ВСЕ"] = "DISABLE ALL",
        ["ОБНОВИТЬ"] = "REFRESH",
        ["ЗАКРЫТЬ"] = "CLOSE",
        ["ВЫБЕРИТЕ МОД"] = "SELECT A MOD",
        ["ЗАГЛУШКА"] = "PLACEHOLDER",
        [AiModConflictMessage] =
            "WARNING: Sector and Smart AI are both enabled — they compete for the same units. Disable one of them.",

        // ---- dynamic / notices ----
        ["ОШИБКА"] = "ERROR",
        ["ОШИБКА ЗАПУСКА"] = "LAUNCH ERROR",
        ["ОБНОВЛЕНИЯ"] = "UPDATES",
        ["СОХРАНЕНО"] = "SAVED",
        ["Редактор карт не найден"] = "Map editor not found",
        ["Редактор карт не найден в Tools\\Map Editor."] = "Map editor not found in Tools\\Map Editor.",
        ["Запускает игру с модом Yuri's Echo и LuaAPI; карта и сохранение выбираются в меню игры."] =
            "Starts the game with the Yuri's Echo mod and LuaAPI; map and save are chosen in the game menu.",
        ["Запускает игру с LuaAPI; кампания выбирается в меню игры."] =
            "Starts the game with LuaAPI; the campaign is chosen in the game menu.",
        ["YURI'S ECHO"] = "YURI'S ECHO",
        ["Выберите миссию из списка."] =
            "Select a mission from the list.",
        ["Выберите миссию кампании; сложность берётся из опций."] =
            "Select a campaign mission; the difficulty comes from Options.",
        ["Список кампаний пуст: не найден INI\\Battle.ini или в нём нет миссий."] =
            "Campaign list is empty: INI\\Battle.ini was not found or contains no missions.",
        ["Выберите миссию."] = "Select a mission.",
        ["Запуск миссии: {0} ({1})."] = "Launching mission: {0} ({1}).",
        ["Миссия запущена: {0}."] = "Mission started: {0}.",
        ["Игра не запустилась."] = "The game did not start.",
        ["Игра упала при загрузке миссии."] = "The game crashed while loading the mission.",
        ["Для запуска миссии через Syringe не найден gamemd-spawn.exe или CnCNet-Spawner.dll."] =
            "Cannot launch mission via Syringe: gamemd-spawn.exe or CnCNet-Spawner.dll was not found.",
        ["CnCNet client"] = "CnCNet client",
        ["Открывает клиент CnCNet (онлайн и LAN)."] = "Opens the CnCNet client (online and LAN).",
        ["Карты не найдены в корне игры и в Maps\\."] = "No maps found in the game root or Maps\\.",
        ["Превью нет: рядом с картой не найден .png"] = "No preview: no .png found next to the map",
        ["Превью не читается"] = "Preview cannot be read",
        ["Папка mods\\ пуста."] = "The mods\\ folder is empty.",
        ["В папке мода нет файлов .lua или .json."] = "The mod folder has no .lua or .json files.",
        ["МОДОВ: {0}   |   АКТИВНО: {1}   |   .lua: {2}   |   .json: {3}"] = "MODS: {0}   |   ACTIVE: {1}   |   .lua: {2}   |   .json: {3}",
        ["(нет описания)"] = "(no description)",
        ["(ошибка чтения mod.json)"] = "(error reading mod.json)",
        ["Конфликты: "] = "Conflicts: ",
        ["Зависимости: "] = "Dependencies: ",
        ["ВЕРСИЯ: "] = "VERSION: ",
        ["АВТОР: "] = "AUTHOR: ",
        ["ПАПКА: mods\\"] = "FOLDER: mods\\",
        ["ФАЙЛОВ ВСЕГО: {0}   |   .lua: {1}   |   .json: {2}"] = "TOTAL FILES: {0}   |   .lua: {1}   |   .json: {2}",
        ["СТАТУС: "] = "STATUS: ",
        ["ВКЛЮЧЁН"] = "ENABLED",
        ["ВЫКЛЮЧЕН"] = "DISABLED",
        ["MODE: LuaAPI"] = "MODE: LuaAPI",
        ["СОХРАНЕНО: {0} активно"] = "SAVED: {0} active",
        ["ОШИБКА СОХРАНЕНИЯ: "] = "SAVE ERROR: ",
        ["Запуск: {0}. Карта и бой — в скирмиш-меню игры."] =
            "Launching: {0}. Map and battle setup are in the game's skirmish menu.",
        ["Не удалось загрузить LuaAPI.dll в игру."] = "Failed to load LuaAPI.dll into the game.",
        ["gamemd.exe не запустился: LuaAPI не загружен."] = "gamemd.exe did not start: LuaAPI was not loaded.",
        ["МОДОВ: {0}   |   АКТИВНО: {1}   |   .lua: {2}   .json: {3}"] = "MODS: {0}   |   ACTIVE: {1}   |   .lua: {2}   .json: {3}",
        ["LUAAPI: {0} из {1} модов будут загружены при старте."] = "LUAAPI: {0} of {1} mods will be loaded on start.",
        ["МОДОВ: {0}   |   АКТИВНО: {1}"] = "MODS: {0}   |   ACTIVE: {1}",
        ["МОДЫ: {0}   |   АКТИВНО: {1}"] = "MODS: {0}   |   ACTIVE: {1}",
        ["{0}; LuaAPI-моды не применятся"] = "{0}; LuaAPI mods will not be applied",
        ["OPEN MODS FOLDER"] = "OPEN MODS FOLDER",
        ["Сейчас: {0}. Смена канала перезаписывает updateconfig.ini (как в клиенте) и требует перезапуска."] =
            "Current: {0}. Changing the channel overwrites updateconfig.ini (as in the client) and requires a restart.",
        ["updateconfig.ini указывает на канал, которого нет в Resources/Config."] =
            "updateconfig.ini points to a channel that is missing from Resources/Config.",
        ["Канал обновлений: {0} (updateconfig.ini, нужен перезапуск клиента)."] =
            "Update channel: {0} (updateconfig.ini, client restart required).",
        ["Настройки сохранены, но канал сменить не удалось:\n"] = "Settings saved, but the channel could not be changed:\n",
        ["Настройки игры: RA2MD.INI\nПараметры лаунчера: launcher_config.json"] =
            "Game settings: RA2MD.INI\nLauncher settings: launcher_config.json",
        ["Клиент CnCNet не найден: {0}"] = "CnCNet client not found: {0}",
        ["Выбранное разрешение не поддерживается монитором. Использовано {0}."] =
            "The selected resolution is not supported by the monitor. Using {0}.",
        ["Разрешение клиента"] = "Client resolution",
        ["Разрешение в игре"] = "In-game resolution",

        // ---- storage / disk report ----
        ["Карты"] = "Maps",
        ["Моды LuaAPI"] = "LuaAPI mods",
        ["Ресурсы клиента"] = "Client resources",
        ["Сохранения"] = "Saved Games",
        ["Реплеи"] = "Replays",
        ["Вся папка игры"] = "Whole game folder",
        ["нет данных"] = "no data",
        ["Диск не определён."] = "Drive could not be determined.",
        ["Свободно: {0}\nВсего: {1}\nДиск {2}"] = "Free: {0}\nTotal: {1}\nDrive {2}",
        ["Диск недоступен: "] = "Drive unavailable: ",

        // ---- components ----
        ["видео кампании RA2"] = "RA2 campaign videos",
        ["видео кампании YR"] = "YR campaign videos",
        ["музыка Firestorm"] = "Firestorm music",
        ["музыка Tiberian Sun"] = "Tiberian Sun music",
        ["контент CnCNet"] = "CnCNet content",
        ["установлено"] = "installed",
        ["НЕ УСТАНОВЛЕНО"] = "NOT INSTALLED",

        // ---- statistics ----
        ["УСТАНОВКА"] = "INSTALLATION",
        ["путь"] = "path",
        ["есть"] = "yes",
        ["нет"] = "no",
        ["найдено"] = "found",
        ["активно"] = "active",
        ["файлов"] = "files",
        ["список"] = "list",
        ["статус"] = "status",
        ["разработка мультиплеера ещё не начата"] = "multiplayer development has not started yet",
        ["изменён"] = "modified",
        ["размер"] = "size",
        ["нет файла"] = "file missing",
        ["Модов нет."] = "No mods.",
        ["—"] = "—",
        ["путь не задан"] = "path not set",
        [" не найден"] = " not found",
        ["Не найден: "] = "Not found: ",
        ["Б"] = "B",
        ["КБ"] = "KB",
        ["МБ"] = "MB",
        ["Менеджер модов"] = "MOD MANAGER",
        ["Настройки"] = "SETTINGS",
        ["КЛИЕНТ"] = "Client",
        ["ИНТЕРФЕЙС"] = "Interface",
        ["Кнопка только открывает папку в Проводнике; она ничего не удаляет."] = "This button only opens the folder in Explorer; it does not delete anything.",
        ["НАСТРОЙКА БОЯ"] = "BATTLE SETUP",
        ["Рендерер"] = "Renderer",
        ["Массовое выделение: только бойцы"] = "Mass selection: combat units only",
        ["Показывать прирост энергии"] = "Show power delta",
        ["Счётчик комбайнов"] = "Show harvester counter",
        ["Каналы Pre-release и Dev нужны для тестирования новых версий: возможны неожиданные ошибки. О проблемах сообщайте в Discord, указывая выбранный канал."] = "Pre-release and Dev channels are for testing upcoming versions: unexpected errors are possible. Report issues on Discord and mention the selected channel.",
        ["Файлы обновляет updater CnCNet-клиента; лаунчер только переключает канал."] = "Files are updated by the CnCNet client updater; the launcher only switches the channel.",
        ["Отсутствующие компоненты скачивает updater CnCNet-клиента; лаунчер их не загружает и не удаляет."] = "Missing components are downloaded by the CnCNet client updater; the launcher does not download or delete them.",
        ["Звуки интерфейса"] = "Interface sounds",
        ["ОТКРЫТЬ ЖУРНАЛ"] = "OPEN LOG",
        ["Не удалось запустить лаунчер."] = "Failed to start the launcher.",
        ["Произошла непредвиденная ошибка."] = "An unexpected error occurred.",
        ["Журнал: "] = "Log: ",
        ["Открыть журнал сейчас?"] = "Open the log now?",
        ["Ошибка"] = "Error",
        ["Не удалось открыть журнал. Путь: "] = "Failed to open the log. Path: ",
        ["Не удалось инициализировать лаунчер."] = "Failed to initialize the launcher.",
        ["Произошла ошибка."] = "An error occurred.",
        ["Не удалось сохранить настройки."] = "Failed to save settings.",
        ["Не удалось запустить игру."] = "Failed to start the game.",
        ["Не удалось запустить миссию."] = "Failed to start the mission.",
        ["Не удалось запустить клиент CnCNet."] = "Failed to start the CnCNet client.",
        ["Не удалось запустить редактор карт."] = "Failed to start the map editor.",
        ["Не удалось открыть папку."] = "Failed to open the folder.",
        ["Не удалось открыть ссылку."] = "Failed to open the link.",
        ["Не удалось сменить канал обновлений."] = "Failed to change the update channel.",
        ["Нет доступа к файлу. Проверьте права и не заблокирован ли файл другим приложением."] = "Cannot access the file. Check permissions and whether it is locked by another application.",
        ["Файл занят другим процессом. Закройте программы, которые могут его использовать, и попробуйте снова."] = "The file is in use by another process. Close programs that may be using it and try again.",
        ["Ошибка чтения или записи файла. Подробности записаны в журнал лаунчера."] = "Failed to read or write the file. Details were written to the launcher log.",
        ["Файл настроек повреждён или имеет неверный формат. Подробности записаны в журнал лаунчера."] = "The settings file is corrupted or has an invalid format. Details were written to the launcher log.",
        ["Неверный формат данных в файле настроек."] = "Invalid data format in the settings file.",
        ["Не найден необходимый файл или папка."] = "A required file or folder was not found.",
        ["Произошла ошибка. Подробности записаны в журнал лаунчера."] = "An error occurred. Details were written to the launcher log.",
    };

    private static readonly ConditionalWeakTable<DependencyObject, string> Keys = new();

    /// <summary>
    /// Translates every static text element in the visual tree. Only text that is
    /// an exact dictionary key is captured, so views that are realized later (for
    /// example the Options tab) are translated on first display, while dynamic
    /// text assigned by code is left alone.
    /// </summary>
    public static void Apply(DependencyObject root) => Walk(root);

    private static void Walk(DependencyObject node)
    {
        switch (node)
        {
            case TextBlock tb when !string.IsNullOrWhiteSpace(tb.Text) && !IsPresenterContent(tb):
                tb.Text = Translate(tb, tb.Text);
                break;
            case Button b when b.Content is string s && s.Length > 0:
                b.Content = Translate(b, s);
                break;
            case System.Windows.Controls.Primitives.ToggleButton b when b.Content is string ts && ts.Length > 0:
                b.Content = Translate(b, ts);
                break;
            case CheckBox c when c.Content is string s && s.Length > 0:
                c.Content = Translate(c, s);
                break;
            case MenuActionButton m when !string.IsNullOrWhiteSpace(m.Text):
                m.Text = Translate(m, m.Text);
                break;
            case TabItem t when t.Header is string hs && hs.Length > 0:
                t.Header = Translate(t, hs);
                break;
        }

        if (node is FrameworkElement fe && fe.ToolTip is string tip && tip.Length > 0)
            fe.ToolTip = TranslateTooltip(fe, tip);

        if (node is Window w && !string.IsNullOrWhiteSpace(w.Title))
            w.Title = TranslateWindowTitle(w, w.Title);

        var count = VisualTreeHelper.GetChildrenCount(node);
        for (var i = 0; i < count; i++) Walk(VisualTreeHelper.GetChild(node, i));
    }

    private static readonly ConditionalWeakTable<DependencyObject, string> TooltipKeys = new();
    private static readonly ConditionalWeakTable<Window, string> TitleKeys = new();

    private static string TranslateTooltip(DependencyObject node, string text)
    {
        if (TooltipKeys.TryGetValue(node, out var key)) return T(key);
        if (!En.ContainsKey(text)) return text;
        TooltipKeys.Add(node, text);
        return T(text);
    }

    private static string TranslateWindowTitle(Window w, string text)
    {
        if (TitleKeys.TryGetValue(w, out var key)) return T(key);
        // exact key match preferred; also allow titles that contain marker suffix
        if (En.ContainsKey(text)) { TitleKeys.Add(w, text); return T(text); }
        return text;
    }

    /// <summary>
    /// A TextBlock generated by a ContentPresenter is bound to the control's
    /// Content. Writing into it directly would replace that binding and freeze
    /// the visible text, so it is translated through Button/CheckBox.Content instead.
    /// </summary>
    private static bool IsPresenterContent(TextBlock tb) =>
        VisualTreeHelper.GetParent(tb) is ContentPresenter;

    private static string Translate(DependencyObject node, string text)
    {
        if (Keys.TryGetValue(node, out var key)) return T(key);
        if (!En.ContainsKey(text)) return text;
        Keys.Add(node, text);
        return T(text);
    }

    /// <summary>Localized language entries for the selector (English and Russian only).</summary>
    public static List<KeyValuePair<string, string>> Languages() =>
    [
        new(English, T("Английский")),
        new(Russian, T("Русский")),
    ];
}
