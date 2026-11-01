# Живая проверка выделенного хоста (ветка `multilevel`) — 2026-11-01

Что проверяем: `docs/DEDICATED_HOST.md`. Юнит-тесты покрывают ключи, строки консоли и выбор сейва; всё ниже может доказать только игра. Запускает ведущая, в игре действует владелец, логи и окно сервера читает ведущая.

Порядок: шаг 0 обязателен, он про безоконный режим вообще. Дальше А, Б, В, Г. Следующий шаг не начинать, пока предыдущий не прошёл.

Подготовка:
1. Стенд из рабочего профиля MO2: `tools\deploy.ps1 -Profile "G.A.M.M.A original 920" -TestRoot E:\AnomalyCoopML -SkipGameBin`. Профиль `G.A.M.M.A` неполный, на нём падает любой запуск (нет `ssfx_001_mcm`).
2. Движок и `gamedata` одной ветки `multilevel`. Протокол 20: с опубликованной b39 не соединится.
3. `deploy.ps1` кладёт на стенд `fsgame_server.ltx` и `appdata_server\`.
4. Свободно: сервер ~2,5 ГБ commit, каждый Mk ещё 2–3 ГБ на GAMMA.

Команды запуска:

```powershell
cd E:\AnomalyCoopML
.\bin\AnomalyCoopDX11AVX.exe -fsltx fsgame_server.ltx -coop_dedicated 27960 -coop_new
.\bin\AnomalyCoopDX11AVX.exe -fsltx fsgame_server.ltx -coop_dedicated 27960 -coop_load last
powershell -File D:\Projects\ForEverything\multilevel\tools\launch.ps1 b -GameDir E:\AnomalyCoopML -Connect 127.0.0.1
```

Логи: `appdata_server\logs` (сервер), `appdata_ms<k>\logs` (Mk рядом с папкой сервера), `appdata_b\logs` (клиент).

| # | Действие | Ждём | Если не так |
|---|---|---|---|
| 0.1 | Mk без хоста: `-coop_mapserver 1 0 27961 test -fsltx fsgame_ms1.ltx -noprefetch -start server(<сейв>/single/alife/load) client(localhost)` | Лог: `WARP device`, `Starting Main Loop`, загрузка карты, через 60 с `coop_mapserver_stats:`, `frames` около 1800. Окна нет, `MainWindowHandle` 0 | `drx_da_main` и `db.actor`: спавн отложен, см. `Level.cpp` `spawn_antifreeze`. Следующую ошибку Lua разбирать тем же порядком: `HEADLESS_AUDIT.md` §10 |
| 0.2 | Сравнить со строкой статистики | `private` 1,5–3 ГБ, `avg` меньше 33 мс, `Modules` без `nvwgf2umx`, с `d3d10warp` | Записать замер в vault: план §1.8 обещал 1,5–2,5 ГБ |
| А1 | Запуск с `-coop_new` | Окно консоли с заголовком `RayLink: dedicated host, port 27960`, в нём строки `[coop]`, нет окна игры, нет заставки | Окна нет: `AllocConsole`. Падение: окно закрылось, смотреть `appdata_server\logs` |
| А2 | Мир поднялся | `[coop] dedicated: a new world`, `the ghost stands on 'fake_start'`, затем `[coop] ... hosting`. Смены карты нет: нет `ChangeLevel`, нет второй загрузки | Актёр ушёл на другую карту: `character_creation`, `new_game_map` |
| А3 | `coop_status`, `coop_players`, `coop_time` в окне | Сводка, `0 player(s)`, время и множитель. Стрелка вверх возвращает прошлую строку | Строки не доходят: поток чтения, `coop_console::next_line` |
| А4 | `coop_time 21:30`, затем `coop_time` | Время вперёд до 21:30 | |
| А5 | `coop_autosave_now`, `coop_restore` | `autosave: coop_auto_...`, список с номером 1 | `skipped`: `can_write`, `survival::life_of(0)` |
| А6 | `quit` | `the world is saved`, последний сейв, окно закрывается, код 0 | |
| А7 | `-coop_load last` | Тот же мир, тот же `game id`, снова `the ghost stands on 'fake_start'` | |
| А8 | Запуск без мира, потом `coop_world list`, `coop_world last` | Окно ждёт, список сейвов, мир грузится | |
| А9 | Закрыть окно крестиком на работающем мире | Сейв успевает (до 4,5 с), процесс завершился, Mk нет | Сейв не успел: строка в логе, замерить длительность |
| Б1 | Клиент входит | Сервер: `peer N joined`, `levels: ...`, для карты игрока `map server 1 starts`. Клиент держится на загрузке, пока `map server 1 leads level M`, затем входит | Клиент на `fake_start`: `host_player_loads`, `bring_proxy_to_level` |
| Б2 | Новый игрок | Появляется на базе своей группировки | У «хоста» быть не должен: на `fake_start` никому нельзя |
| Б3 | В игре | NPC и монстры живые, время идёт, погода меняется и не `indoor`, нет аватара хоста, нет метки хоста, в списке группы только игроки | Погода с `fake_start`: `coop_worldstate` отдаёт цикл служебной карты |
| Б4 | `coop_players` | Клиент: ник, его карта, пинг | |
| Б5 | Второй клиент на другой карте | Второй Mk, `coop_players` показывает обе карты, заголовок окна 2 игрока, 2 сервера | |
| Б6 | Первый клиент уходит через выход на другую карту | Mk новой карты, старый гаснет через `coop_mapserver_linger` | |
| Б7 | Сон, смерть, возрождение, выброс | Никто не ждёт хоста, голосований с хостом нет | Зависает на «все согласны»: аудит §6 |
| В1 | `coop_kick <ник> test` | Клиент видит причину, персонаж остаётся, вход снова в него | |
| В2 | `coop_restore`, затем `coop_restore 1` | `world replaced`, все перезагрузились на своих картах, призрак снова на `fake_start`, Mk запущены заново | |
| В3 | `/go` при группе у выхода на карту «вместе» | Группа идёт, хост никого не держит | `no pending transition` при ждущих: `board_lead_known` |
| В4 | `say привет` | Строка у всех игроков, кириллица цела, в окне тоже | Кракозябры: cp1251 в `coop_host_console.cpp` |
| В5 | Падение Mk: завершить процесс | `map server ... is gone`, игроки карты перезагружаются, новый запуск | |
| Г1 | Лаунчер: «Сервер на этом ПК», новый мир | Окно сервера, `RayLinkServer.exe` в диспетчере, карточка «Сервер работает» | |
| Г2 | Лаунчер: «Войти в игру» | Игра с `-coop_connect 127.0.0.1:<порт>`, вход обычным клиентом, отказа «закройте игру» нет | `stand::game_processes` не исключил имя сервера |
| Г3 | Лаунчер: «Сохранить и остановить» | Сейв, процесс и Mk исчезли, карточка снова с выбором мира, сейв в списке | |
| Г4 | Закрыть лаунчер при работающем сервере, открыть | Сервер жив, карточка «Сервер работает»; кнопка остановки честно говорит про окно сервера | |
| Г5 | Обновление игры при работающем сервере | Лаунчер просит закрыть процессы стенда | |

Что отдельно смотреть в логе сервера: ошибки Lua в `motivator_binder`, `actor_on_update`, всё со словами `db.actor` и `nil`. Это логика игры без игрока рядом; каждая такая строка кандидат на правку.

Память: на каждом шаге `coop_mapserver_stats` и `Get-Process | Select PM, WS`. Запись в vault: `10 Projects/Anomaly Coop/Выделенный хост`.
