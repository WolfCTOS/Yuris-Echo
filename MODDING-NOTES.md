# RA2/YR (CnCNet) — как правильно менять юниты и арт

Документ для агентов/людей, которые продолжат работу с этой установкой:
`D:\Games\Red Alert 2 LuaAPI` (RA2/YR + клиент CnCNet + Syringe/LuaAPI + Ares + Phobos).

Инструмент для работы с mix-файлами лежит рядом: `C:\Users\cynet\.config\opencode\tools\xmix\`
(`xmix.py` — CLI, `xmcp.py` — MCP-сервер, `xmix_bf.py` — Blowfish/RSA для зашифрованных mix).

---

## 0. TL;DR — правила, которые нельзя нарушать

1. **Арт-файлы (.vxl/.hva/.shp) движок ищет ВНУТРИ mix-архивов** по Westwood-ID.
   Файл, просто положенный в корень игры, **не подхватывается никогда**.
   Симптом: юнит невидим, в сайдбаре вместо иконки надпись **«MISSING CAMEO»**.
2. **Добавление файлов в mix требует синхронизации `local mix database.dat` (LMD)**
   (в нём лежит счётчик файлов). Если не обновить — клиент CnCNet считает архив
   неконсистентным и **не пускает в игру**.
3. **Правки INI обязаны сохранять окончания строк исходного файла** (CRLF или LF).
   Смешивание даёт «висячий CR» внутри значения (`Owner=...Alliance\r`) — значение
   перестаёт совпадать с именем дома.
4. Любая запись в mix — **только через бэкап** и только с последующей проверкой
   round-trip (пересборка без изменений должна дать побайтово тот же файл).
5. Перед тем как «чинить» игру, **откатывайся на бэкап** и проверяй вход в CnCNet.

---

## 1. Что где лежит в этой установке

| Что | Где | Кто читает |
|---|---|---|
| Правила режима (Map Code) | `INI\Map Code\*.ini` (18 файлов) | клиент CnCNet → сводит в `spawnmap.ini` |
| Опции лобби | `INI\Game Options\*.ini` | клиент (галочка в лобби) |
| Итоговые правила | `spawnmap.ini` (генерируется клиентом) | движок |
| Правила мода | `cncnet.mix` → `rulesmd.ini` + `rules_cncnet.ini` | движок |
| Арт (описания) | `cncnet.mix` → `artmd.ini` + `art_cncnet.ini` | движок |
| **Файлы арта (картинки)** | **внутри `cncnet.mix`** | движок (по ID) |
| Мод-скрипты | `scripts\init.lua`, `scripts\mods\<id>\main.lua`, `scripts\active_mods.txt` | LuaAPI.dll |
| Логи | `LuaAPI.log`, `debug\debug.log`, `injector_log.txt` | — |

Внимание: «loose» `rulesmd.ini` / `artmd.ini` в корне игры **движком не читаются**
(это подтверждено экспериментом: правка Grizzly Tank Cost=1 в loose-файле не дала
эффекта). Работают только копии внутри `cncnet.mix`.

Базовые mix-файлы игры (`ra2.mix`, `ra2md.mix`, `expandmd01.mix`, `multimd.mix`,
`wdt.mix`, `maps*.mix`, `language.mix`) — **зашифрованы** (Blowfish + RSA-предикт).
`cncnet.mix` и `ra2mode.mix` — обычные (не зашифрованные).

---

## 2. Формат MIX (RA2 / Westwood)

### 2.1 Обычный (незашифрованный) архив — вариант CnCNet
```
+0x00  u32   flags (0)
+0x04  u16   count
+0x06  u32   dataSize
+0x0A  index: count × { u32 id, u32 offset, u32 size }     ← id, offset, size!
+      payload (файлы)
+      name blob: имена файлов, NUL-разделённые, по алфавиту, до конца файла
```
* **offset в индексе ОТНОСИТЕЛЬНЫЙ** — отсчитывается от конца индекса
  (`body_start = 10 + 12·count`; в `cncnet.mix` это 5878).
  Абсолютная позиция файла = `body_start + offset`.
  ⚠️ Если считать offset абсолютным, архив «разбирается» (имена сходятся по ID),
  но **payload окажется сдвинут** → файлы читаются как мусор → игра падает
  (Access Violation) или не грузит арт. Именно так я ломал игру дважды.
* Последний регион (XCC-база `local mix database.dat`) **перекрывает** начало
  name blob: его заявленный размер больше фактического содержимого.
* Регионы (уникальные `(offset,size)`) плотно укладываются без дыр.
* У зашифрованных mix (§2.2) offset тоже относительный (база = конец индекса).

### 2.2 Зашифрованный архив (базовая игра)
```
+0x00  u32   flags (0x00030000 = encrypted|checksum)
+0x04  80    key source  →  RSA-публичная операция → 56-байтный Blowfish-ключ
+0x54  8     зашифрованный заголовок: count u16, dataSize u32, +2 байта
+0x5C  ...   зашифрованный индекс (кратен 8)
+      payload, +20 байт контрольной суммы в конце
```
Ключ получается так (XCC `mix_decode.cpp`):
1. base64-строка публичного ключа → 40-байтный модуль `n` (big-endian), `e = 0x10001`.
2. key source (80 байт) режется на блоки по 40 байт; каждый блок — little-endian число.
3. `out = pow(chunk, e, n)`, в ответ берутся младшие 39 байт; первые 56 байт — ключ Blowfish.
4. Blowfish — **стандартный**, блоки 8 байт читаются как big-endian u32 (XCC делает
   это через `reverse()` = byte-swap).

### 2.3 Westwood ID имени (по нему игра ищет файл)
```
name → UPPERCASE, '/' → '\'
длина не кратна 4 → дописать chr(len % 4), затем дописать (3 - len%4) копий байта name[len & ~3]
CRC-32 (IEEE, как zlib.crc32) по итоговому буферу
```
Проверено: 489/489 имён `cncnet.mix` и 51/51 `ra2mode.mix` совпали с ID в индексе.

### 2.4 LMD (`local mix database.dat`) — ловушка
Внутри `cncnet.mix` и `ra2mode.mix` лежит служебная база XCC. Её последние
**28 байт** (трейлер) стоят непосредственно перед name blob:

```
-28..-20  8 байт сигнатуры
-20..-16  u32  размер самой LMD-записи
-16..-8   8 нулей
-8..-4     u32  константа 5
-4..0      u32  КОЛИЧЕСТВО ФАЙЛОВ В АРХИВЕ   ← обновлять при добавлении
```
Плюс: её регион **перекрывается** с name blob (заявленный размер больше её фактического
содержимого). При пересборке это сохраняется автоматически, если правильно считать
размер её содержимого.

**Правило:** после любого добавления/удаления файла в mix с LMD — обновить счётчик
в трейлере (иначе клиент/игра считают архив битым).

### 2.5 Пересборка архива (как делает `xmix`)
Порядок: header → index → payload (регионы в физическом порядке) → gap → name blob.
Регион, перекрывающий name blob, обрезается по `names_start`; его заявленный размер
корректируется на дельту длины содержимого. LMD-трейлер обновляется.

---

## 3. Как игра грузит правила и арт

### 3.1 Правила
`INI\Map Code\<режим>.ini` → клиент сводит их в `spawnmap.ini` → движок читает
`rulesmd.ini` из `cncnet.mix` (вместе с `rules_cncnet.ini` через `$Include`).

Новый тип юнита:
```
[VehicleTypes]
29=HUMVEE          ← ключ только метка; значение — имя типа

[HUMVEE]
Name=Humvee
Image=Humveet
Prerequisite=GAWEAP          ← ВСЕ здания из списка должны быть построены!
Primary=HumveeCannon
Strength=1000
Category=AFV
Armor=wood
Turret=yes
Crusher=yes
TechLevel=1
Owner=British,French,Germans,Americans,Alliance
```
* Свободные слоты в стоковом `[VehicleTypes]`: 29, 31, 71, 72 (в стоке они
  закомментированы: `;29=CARRIERB`, `;31=DREDB`).
* `Owner` — **строго по фракциям**: Альянсы `British,French,Germans,Americans,Alliance`,
  Советы `Russians,Confederation,Africans,Arabs`. Список «всех» отдаёт юнит и Советам.
* `Prerequisite` требует **все** перечисленные здания: `GAWEAP,NAWEAP` = «нужен
  и альянсовский, и советский War Factory» = юнит не строится НИ У КОГО.
* Оружие — отдельная секция (`[HumveeCannon] Damage=50` = 2× урон GI).

### 3.2 Арт
Секция art-INI = **имя картинки** (image), а не имя юнита:
```
[Humveet]
Voxel=yes
Remapable=yes
Cameo=MTNKICON
AltCameo=MTNKUICO
PrimaryFireFLH=210,0,130
```
Движок по `Image=` ищет:
* `<IMAGE>.VXL` — воксельная модель (RA2-формат, см. §4);
* `<IMAGE>TUR.VXL` — башня (подключается правилом `Turret=yes`, в art-INI отдельного
  ключа не нужно — см. [HTNK], [TTNK]);
* `<Cameo>.SHP` — иконка в сайдбаре (`Cameo=`, `AltCameo=`).

Все три файла должны лежать **в mix** (см. §0 п.1).

### 3.3 Формат RA2-VXL (`.vxl`)
```
[0x000..0x022)  заголовок 802 байт:
                 0x00 char[16] "Voxel Animation\0"
                 0x10 u32 palette_count (1)
                 0x14 u32 limb_count
                 0x18 u32 tailer_count
                 0x1C u32 body_size
                 0x20 u16 remap_start
                 0x22 u16 remap_end
                 0x24..0x322 палитра 256×RGB (768 байт)
[limb headers]   limb_count × 28 байт:
                   0x00 char[8]  имя конечности ("DUMMY01", "CYLINDER1" …)
                   0x08 u16/u16/u8/u8/u16  ПЕР-МОДЕЛЬНЫЕ МЕТАДАННЫЕ
                   0x10 u32  номер конечности
                   0x14 u32  ещё одно поле
                 (всегда 28 байт; у разных моделей значения разные!)
[body data]      body_size байт: упакованные span-ы вокселей
[limb tailers]   tailer_count × 92 байт:
                   u32 span_start_offset, u32 span_end_offset, u32 span_data_offset,
                   f32 det, f32[12] матрица 3×4, f32[3] bbox_min, f32[3] bbox_max,
                   u8 size_x, u8 size_y, u8 size_z, u8 normals_mode
```
Проверка целостности: `802 + 28·limbs + body_size + 92·tailers == размер файла` ✓
(проверено на штатном игровом VXL: 802+28+29926+92 = 30848 ✓).

**Критично:** в 8 байтах метаданных после имени конечности у моделей лежат
**индивидуальные** значения (у штатных: `02 00 02 00 03 01 08 00`,
`03 00 02 00 03 01 08 00`, `00 c0 00 00 …`, `50 34 c9 06 …` — разные).
Проверка `802 + 28·limbs + body_size + 92·tailers == размер файла` проходит
и для «с нулями» — значит одного `xmix fileinfo` мало, нужно сравнивать
с живым игровым VXL.

### 3.4 Формат RA2-HVA (`.hva`)
```
[0x00..0x18)  24 байта: char[16] имя файла, u32 num_frames, u32 num_sections
[sections]    num_sections × 16 байт: имена костей ("Body", ...)
[matrices]    num_frames × num_sections × 48 байт: 12 float (3×4 матрица)
```
Проверка: `24 + 16·sections + 48·frames·sections == размер файла` ✓
(для 1 кадра / 1 кость = 88 байт ✓ как в паках).

### 3.5 Где лежит штатный арт игры
Базовые mix-файлы (`ra2.mix`, `ra2md.mix`) **зашифрованы**, а внутри них лежат
**вложенные зашифрованные mix** и **BIG-архивы** (формат XCC `Cbig_file`):
```
header: u32 id ('BIGF'/'4GIB'), u32 size, u32 c_files, u32 cb_header
index : c_files × { u32 offset, u32 size, char name[] }   ← имена файлов тут!
```
Благодаря вложенным архивам имена базового арта (например `RTNK.VXL`) доступны
только через парсер BIG/вложенных mix — прямой поиск по ID в верхнем уровне их
не находит.

### 3.6 Ловушка форматов
Магия `"Voxel Animation\0"` одинакова у **C&C-HVA** и **RA2-VXL**, но раскладка
полей разная. Формат пака (`rtnk.vxl` = 108 007 байт) — это **RA2-VXL** ✓:
802 + 28 + 107085 + 92 = 108 007 ✓, а `.hva` (88 байт) = **RA2-HVA** ✓
(24 + 16 + 48 = 88 ✓). Не делай вывод о формате по одной магии — сверяй суммы размеров.

---

### 3.5 Сайдбар-иконка (Cameo) и почему «MISSING CAMEO»
В **artmd.ini** у каждой арт-секции есть:
```
[GTNK]   ; Grizzly Medium Tank
Voxel=yes
Remapable=yes
Cameo=GTNKICON          <- иконка в сайдбаре = файл GTNKICON.SHP
AltCameo=GTNKUICO
PrimaryFireFLH=170,0,112    <- точка выстрела (x,y,z) в модели
SecondaryFireFLH=170,0,112
ElitePrimaryFireFLH=170,0,112
EliteSecondaryFireFLH=170,0,112
```
* `Cameo=` -> файл `<имя>ICON.SHP` **в mix**. Если его нет - в сайдбаре «MISSING CAMEO».
* `AltCameo=` -> `<имя>UICO.SHP` (иконка в меню покупки).
* `*FLH=` - координаты дула; без них выстрелы идут из центра модели.
* Башня называется `<имя>tur.vxl` (+ `.hva`) - конвенция, а не отдельная секция.

### 3.6 Имя арта = ID: коллизии
ID файла = CRC32 от имени, значит **имя арта обязано быть уникальным**.
Штатные имена уже заняты: `GTNK` (Grizzly), `RTNK` (Mirage Tank), `gtnk.tur`, `rtnk.tur`.
Если пак хочет заменить штатный арт, а не добавить новый:
* «замена в лоб» = та же запись/ID, но в базовых mix (ra2.mix/ra2md.mix) файл
  лежит раньше по порядку загрузки -> победит штатный вариант;
* надежно = **новое имя** (`MRTNK`) + `Image=MRTNK` в rules + своя секция в artmd.ini
  + копия башенки под новым именем (`MRTNKTUR`) + `Cameo=` от старого арта.

### 3.7 Формат базовых (зашифрованных) mix - как добраться до штатных файлов
```
ra2.mix / ra2md.mix  -> зашифрованы (flags 0x00030000)
   запись -> mix с флагом 0x00010000 (обычный, но с SHA-1 хвостом):
        [0:4]  u32 flags (0x00010000)
        [4:6]  u16 c_files
        [8:12] u32 size
        [12:..] индекс: count x {u32 id, u32 offset (относительный!), u32 size}
        +20 байт SHA-1 в конце
```
* В базовых mix **нет имён файлов** - только ID (имени знает игра).
* Штатный `rulesmd.ini` лежит под ID `8218F9F4` (= ww_id("rulesmd.ini")),
  `artmd.ini` - под ID `B53EECDE`.
* Правила, положенные **в корень игры**, перекрывают mix - это штатное поведение
  (в самом стоковом файле написано "If placed in game directory, it will override...").

## 4. Инструмент `xmix`

CLI: `C:\Users\cynet\.config\opencode\tools\xmix\xmix.bat <команда> ...`
MCP: сервер `xmix` уже прописан в `C:\Users\cynet\.config\opencode\opencode.jsonc`
(локальный stdio-сервер, 13 инструментов).

```
xmix info      <mix>                     заголовок, размеры, границы
xmix verify    <mix> [--strict]          согласованность: gaps/overlaps/имена/LMD
xmix list      <mix> [--filter S] [--sort name|offset|size|id] [--json]
xmix cat       <mix> <имя>               вывести файл из архива
xmix extract   <mix> <имя|*> [-o путь]    извлечь (все — в каталог)
xmix find      <mix> --text|--hex        поиск по содержимому архива
xmix patch     <mix> <имя> --file F      замена IN-PLACE (только та же длина!)
xmix replace   <mix> <имя> --file F      замена с пересборкой (размер может меняться)
xmix inject    <mix> <имя> --file F      добавить файл (пересборка + синхронизация LMD)
xmix ini-get   <mix> <имя> [--section S] [--key K] [--sections-only]
xmix ini-set   <mix> <имя> --set-key K --value V --section S | --set-section S --file F
xmix id        <имя>                     посчитать Westwood ID
xmix fileinfo  <файл>                    разбор .vxl/.hva/прочих
```

MCP-инструменты: `mix_info`, `mix_verify`, `mix_list`, `mix_cat`, `mix_extract`,
`mix_patch`, `mix_replace`, `mix_inject`, `mix_ini_get`, `mix_ini_set`, `mix_find`,
`mix_id`, `art_info`.

### 4.1 Безопасный порядок работ
```powershell
# 1) снять копию
Copy-Item cncnet.mix cncnet.mix.bak
# 2) править на копии, проверять
xmix verify <копия>          # -> ok=True, named=N/N, gaps=0, overlaps=0
# 3) применить, снова проверить
xmix verify cncnet.mix
# 4) в игре: юнит виден? иконка на месте? нет «MISSING CAMEO»?
```

### 4.2 Контрольные проверки после записи в mix
```python
# LMD синхронен?
struct.unpack_from("<I", lmd_content[-28:], 24)[0] == m.count
# round-trip стабилен?
Mix.load(path).build() == Mix.load(path).data
```

---

## 5. Ошибки, которые я уже совершил (не повторять)

| Симптом | Причина | Правило |
|---|---|---|
| Юнит невидим, в сайдбаре «MISSING CAMEO» | арт лежал в корне игры; движок ищет только в mix | класть `.vxl/.hva/.shp` в mix |
| «не могу зайти в CnCNet» | в mix добавлены файлы, но не обновлён счётчик в LMD → архив неконсистентен | обновлять LMD-трейлер (count) |
| Игра падает (Access Violation) / не грузится арт / «PCX file not found» | **payload сдвинут**: offset в индексе относительный, а считался как абсолютный → файлы читаются как мусор | offset = `body_start + stored`; проверять СОДЕРЖИМОЕ, а не только имена |
| `verify` показывает OK, а игра падает | verify проверял имена/ID и укладку регионов, но не содержимое файлов | в verify добавлена сверка сигнатур по расширению (`content_problems`) |
| Владелец юнита «у советов» | `Owner` со списком всех фракций | `Owner` = только нужные фракции |
| Юнит не строится вообще | `Prerequisite=GAWEAP,NAWEAP` (требуются оба завода) | `Prerequisite=GAWEAP` |
| Значение `Owner=...Alliance\r` | правка INI писала CRLF в LF-файл | сохранять окончания строк файла |
| Юнит «сам» сдвигается на клетку при старте | тест-мод вызывал `MoveTo()` | в мод-ах не двигать юниты |
| Вывод «формат пака не RA2» | магия `"Voxel Animation"` одинакова у C&C-HVA и RA2-VXL | сверять суммы размеров, а не магию |
| Арт не нашёлся поиском по ID | поиск шёл только по верхнему уровню mix | обходить вложенные mix и BIG-архивы |
| «MISSING CAMEO» в сайдбаре | в artmd.ini у секции юнита нет `Cameo=` либо файла `<имя>ICON.SHP` нет в mix | класть SHP-иконку в mix и прописать `Cameo=` |
| У чужого юнита пропала модель | правка правил попала в чужую секцию (напр. `Image=` в `[MTNK]`) | после правки всегда диффить с ЭТАЛОНОМ (стоковым rulesmd.ini) |
| Юнит показывает чужую модель | ID арта = хеш имени, а имя уже занято штатным (RTNK) | давать арту уникальное имя + менять `Image=` в rules |
| `xmix verify` показывает дубль ID | в архиве два файла с одинаковым ID | проверять duplicate_ids (добавлено в verify) |

### 5.1 Как диагностировать краш
1. `debug\debug.log` — последние строки перед падением (часто видно фазу загрузки).
2. `debug\snapshot-<дата-время>\except.txt` — дамп от Ares: код исключения, EIP, стек.
3. `injector_log.txt` — клиент: успел ли он запустить игру и сделать инъекцию.
4. `syringe.log` — код возврата процесса игры (например `C0000005`).

Код `C0000005` = Access Violation. Если он появляется сразу после строки
`[Phobos] Replacing image for …` — падение в загрузке/разборе арта.

---

## 6. Чек-листы

### Новый юнит
1. Правила: секция типа + запись в `[VehicleTypes]` (свободный слот) + оружие.
   `Owner` — по фракциям, `Prerequisite` — только свои здания.
2. Арт: подготовить `.vxl`/`.hva` (+`.tur`) в формате RA2 (§3.3–3.4), проверить суммы размеров.
3. Секция в art-INI: `<Image>` → `Voxel=yes`, `Cameo=< existing>.SHP`, `AltCameo=`, FLH-координаты.
4. Положить арт-файлы в `cncnet.mix` под именами `<IMAGE>.VXL`, `<IMAGE>.HVA`, `<IMAGE>TUR.VXL`
   (`xmix inject`), файлы cameo — либо уже есть в mix, либо тоже добавить.
5. Проверить: `xmix verify` → ok; в игре — юнит в меню завода, модель видна, иконка на месте.

### Замена существующего арта
1. Взять стоковый арт (по ID: `xmix id <имя>`), положить рядом.
2. Новые файлы → `xmix inject cncnet.mix <NAME>.VXL --file ...` (LMD обновится сам).
3. При необходимости поправить секцию art-INI (`xmix ini-set ... --set-key`).
4. `xmix verify` → ok; в игре — модель новая, «MISSING CAMEO» нет.

---

## 7. Полезные факты по текущей установке

* `cncnet.mix` — 489 файлов; art INI = `artmd.ini` (1598 секций),
  правила = `rulesmd.ini` (1541 секция). `ra2mode.mix` — 51 файл, тоже с LMD.
* Свободные слоты `[VehicleTypes]`: 29, 31, 71, 72.
* Стоковые иконки машин в миксах ищутся по ID, но **в зашифрованных базовых mix
  имена не хранятся** — поэтому «по имени» их найти нельзя, только по ID;
  сами файлы лежат во **вложенных mix и BIG-архивах** (см. §3.5).
* LuaAPI-мод Humvee (`scripts\mods\humvee\main.lua`) спавнит юнит у базы и **не двигает его**;
  отключается пустым `scripts\active_mods.txt`.
* **Состояние на сейчас**: арт установлен и проверен —
  `cncnet.mix` = 497 файлов (добавлены `HUMVEET.VXL/.HVA`,
  `HUMVEETTUR.VXL/.HVA`, `RTNK.VXL/.HVA`, `DMRTNK.VXL/.HVA`),
  `verify` → ok, `content_problems` = 0, LMD-счётчик = 497, round-trip побайтово
  идентичен. Изменён `[RTNK] PrimaryFireFLH=210,0,130` (по `flh.txt` пака).

## 8. Что делать дальше (по приоритету)

1. **Проверить в игре**: Humvee (иконка/модель), Mirage Tank (модель ремейка).
2. Если Mirage Tank не изменился — скорее всего, штатный `RTNK.VXL` лежит
   в базовых миксах и имеет **тот же ID** (ID = хеш имени) → тогда надо
   заменять содержимое существующей записи, а не добавлять новую.
3. Дальше — остальные юниты из `Asssets` (Rhino, GTNK, Hovercraft, A-railgun,
   Allied Armaments, «Armaments similar to Yuri's») — по той же схеме:
   `xmix inject cncnet.mix <NAME>.VXL --file …` + секция в artmd.ini.
