# PROTOCOL-MODEL: что D2 добавляет к InterfaceSpec v0

v0 (`e88eac6`) описывает, что значит результат: закон + роль + протокол
вызова + источник значений.  D2 описывает, когда callback можно
вызвать, что он меняет и сколько живёт его результат.  Машиночитаемая
форма — `protocolspec-v0.yaml`, отдельный файл поверх v0; v0 не
менялся.

## Схема

    protocolspec-v0.yaml
          |  engine.py: obligations, domains, effects, expectations
          v
    state machine (per scan)
          |  bounded enumeration, depth 1..N, отсечение по obligation и domain
          v
    histories  ──>  d2_run: вызовы через indexam.c
                          |
                    real IndexAmRoutine
                          |  observer (копия IndexAmRoutine, только ABI и IndexScanDesc)
                          v
                    events  ──>  сравнение с expect  ──>  результат
                                 (и replay трафика executor'а через obligation и domain)

## Сущности

Только те, без которых не выражался один из S4, S5-local, S7, S8.

| сущность | поля | кто потребовал | есть ли в v0 |
|---|---|---|---|
| state | поля и начальные значения, на один скан | S4 (позиция), S5 (метка), S8 (фаза) | нет — **новое** |
| operation | callback, args (домен), requires (capability), contract | все | частично: v0 binding (callback) + v0 capability |
| obligation | документированное требование к вызывающему; нарушение — вина вызывающего | S4 (первый Backward только при `amcanorder`; смена направления только при `amcanbackward`), S8 | нет — **новое** |
| domain | где интерфейс определяет ожидаемое поведение, не формулируя требования к вызывающему; вне его истории не генерируются и не проверяются, а вызывающий, оказавшийся там, не обвиняется | S4 (повтор направления после `false`), S5 (mark только на выданной записи; restore только после mark) | нет — **новое** |
| guard | обязательство над аргументами, проверяемое на границе до передачи вызова | S8 | нет — **новое** |
| expect | постусловие: что должно показать наблюдение | S4, S5 | аналог v0 law, но над историей |
| effect | новое значение полей state | S4, S5, S8 | нет — **новое** |
| observable | produced_by, fields, when, lifetime_ends | S7 | нет — **новое** (время жизни) |
| reference | forward_pass, сверенный с seqscan | S4, S5 | v0 D0 reference (seqscan), новый вид |
| generation | scans, prologue, alphabet, depth | S7 (два скана), все | нет — **новое** |

Не понадобились и не добавлены:

| предлагавшаяся сущность | почему не нужна |
|---|---|
| transition (from, op, to) | выражается obligation + effect над полем `phase` |
| sequence constraint (before/after/repeatable) | выражается obligation/domain над полями state: «restore после mark» — domain `s.mark is not None`; «не повторять направление после false» — domain над `ran_off` |
| resource (acquire/release) | нужна для S11; S11 в этом шаге не реализован |
| precondition как одно понятие | разделилось на obligation и domain.  Первая версия D2 записала всё отсекаемое как obligation и тем самым превратила недокументированное поведение nbtree/hash и соглашения executor'а в нормативный контракт; разделение понадобилось |

## Отношение к сущностям v0

| v0 | в D2 |
|---|---|
| capability | используется как есть: `requires`, `cap.amcanorder`, `cap.amcanbackward` |
| binding | вырожден: callback связан по имени поля IndexAmRoutine, номера и семейства не нужны |
| role, law, value_source | не используются; законы значений D1 остаются отдельным слоем |
| protocol (call protocol) | в v0 — соглашение о вызове одной функции; в D2 `protocols.index_scan` — порядок вызовов на одном объекте (скане).  Разные понятия под одним словом; в v1 их надо развести |

Ответ на вопрос «D2 — новый язык или protocol + state»: protocol +
state + время жизни наблюдаемого + генерация.  Закон D2 (expect) по
форме тот же, что в D1 (наблюдение совпадает с эталоном), но эталон
вычисляется моделью по истории, а не функцией по значениям.

## Выражения

obligation, domain, let, expect, effect — выражения Python над `s` (состояние
скана), `arg`, `cap`, `L`, `n`, `ok`.  Это не DSL: движок вычисляет их
`eval` в пустом окружении.  `ok` — «запись выдана»: ожидаемое при
генерации, наблюдённое при replay.  При replay трафика executor'а `L` и
`n` неизвестны; поля, зависящие от них, получают значение «неизвестно»,
и obligation/domain их не используют (так построен spec: они не зависят
от эталона).

## Перехват

Наблюдатель — копия `IndexAmRoutine` индекса, установленная в
`rel->rd_indam` на время одного SQL-вызова (`d2_run`, `d2_observe`,
`d2_observe_cursor`) и снимаемая в `PG_FINALLY`.  Перехватываются
`ambeginscan`, `amrescan`, `amgettuple`, `amendscan`, `ammarkpos`,
`amrestrpos` (последние три — если AM их задаёт).  Наблюдатель не
меняет аргументы и результат; единственное исключение — guard: вызов,
нарушающий обязательство, не передаётся AM (в `d2_run` записывается и
обрывает историю, на трафике executor'а — ERROR).

Из spec наблюдатель получает только два списка (`d2_configure`):
callbacks, завершающие время жизни данных, и guards вида
`<callback>.<arg> <= | = <callback>.<arg>` для `nkeys`/`norderbys`.

Контрольные отказы — отдельные слои (`d2_ctl.c`): под наблюдателем
(«неверный AM»: itup_shared, dir_from_start, restore_once) и над ним
(«неверный вызывающий»: caller_more_keys).
