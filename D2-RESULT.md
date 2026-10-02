# D2: протокол callback'ов как данные → истории → реальные callbacks

Вопрос: что минимально надо добавить к InterfaceSpec v0 (`e88eac6`),
чтобы из машиночитаемого описания получить state machine, истории
вызовов и проверку реальных callback'ов, без знания AM в движке.

Модель: PROTOCOL-MODEL.md.  Инвентарь и сверка с источниками:
D2-INVENTORY.md.  Spec: `protocolspec-v0.yaml`.  Код: `d2proto/`
(наблюдатель, драйвер, контрольные слои), `protocolspec/` (движок,
данные, стенд `run_d2.sh`).  Master `ad36e3608c8`, cassert.

## Result

Да для S7, S8, S4 и S5-local.  Одна spec, один движок, один
наблюдатель; в движке, наблюдателе и драйвере нет имён AM (grep пуст).
Прогон на btree, hash, GiST:

| subject | профиль | историй | callbacks | итог |
|---|---|---|---|---|
| btree text, `k > 'k05'`, index-only | single, depth 6 | 7880 | 70920 | **FAIL S7** — R8 ниже |
| | interleaved (2 скана), depth 4 | 216 | 2160 | pass |
| btree text, без ключей (nkeys 0) | single, depth 4 | 366 | 2562 | pass |
| hash int4, `k = 2` | single, depth 5 | 366 | 2928 | pass |
| GiST point, `p <@ box`, index-only | single, depth 5 | 243 | 1944 | pass |
| | interleaved, depth 4 | 16 | 160 | pass |

Трафик executor'а через тот же наблюдатель (обязательства вызывающего, domain и
время жизни данных):

| запрос | callbacks | итог |
|---|---|---|
| btree, scroll cursor (forward, backward, absolute ±1, all) | get 24, rescan 2 | pass |
| btree, nested loop | get 96, rescan 24 | pass |
| btree, merge join (mark/restore) | get 19, mark 9, restore 9 | **FAIL S7** — та же R8 |
| hash, nested loop | get 120, rescan 24 | pass |
| GiST, nested loop, index-only (два скана одного индекса) | get 64, rescan 10 | pass |

Какой AM что проверил: S4 — btree (упорядоченный, первый Backward) и
hash (неупорядоченный, `amcanbackward`, первый Backward запрещён
обязательством); GiST — только Forward (`amcanbackward = false`, всё
Backward отсечено обязательством).  S7 — btree (`xs_itup`) и GiST
(`xs_hitup`).  S8 — все три.  S5 — только btree: `ammarkpos` есть
только у него среди in-core AM (у hash, GiST, SP-GiST — NULL); второго
AM для S5 нет.

## Evidence

### Находки

| | что | наблюдение | источник |
|---|---|---|---|
| R7 | sgml: `amrescan` с nkeys ≤ begin; ядро: `Assert(nkeys == scan->numberOfKeys)` (indexam.c:421); in-core AM копируют `scan->numberOfKeys` ключей | вывод из кода; историю «меньше ключей» не исполнял — недопустимое для ядра ABI-состояние | D2-INVENTORY.md |
| R8 | btree `amrestrpos` со сменой страницы переписывает `currTuples` (nbtree.c:553–558): данные, возвращённые предыдущим `amgettuple`, меняются до следующего `amgettuple`; sgml (741–743) обещает их до next amgettuple/amrescan/amendscan | минимальная история ниже; то же на merge join | измерено |
| — | после `false` повтор того же направления: nbtree и hash перезапускают скан (возвращают первую запись снова); sgml молчит; executor так не вызывает | проба P3; трафик executor'а остаётся в domain | измерено; в spec — domain, не obligation |

R8, минимальная история (из `expected/d2_none.out`):

    begin
    rescan(given)
    get(forward)   -> (1,2)
    get(forward)   -> (1,3)
    mark                          метка на последней записи первой листовой страницы
    get(forward)   -> (2,1)       переход на следующую страницу, данные (2,1) выданы
    restore                       memcpy markTuples -> currTuples
    get(forward)                  на входе: данные (2,1) изменены

    expected: returned data unchanged
    observed: returned data changed

Последствия для executor'а не нашёл: merge join после restore берёт
внутреннюю запись из `mj_MarkedTupleSlot` (копия), а не из слота
index-only scan; результат запроса верный (18 строк = эталон).  Это
расхождение документации и реализации, не ошибка результата.  Что
исправлять — sgml (добавить `amrestrpos` в список) или nbtree — не
предлагаю.

### Контрольные отказы

Каждый — отдельный слой (`d2_ctl.c`), ломает одно свойство:

| отказ | где | ловится | минимальная история |
|---|---|---|---|
| itup_shared: данные в одном буфере на все сканы | под наблюдателем | S7 только в профиле с двумя сканами (btree, GiST); single — pass | `A.get -> (1,2); B.get(backward) -> (2,3); A.get` → данные A изменены |
| dir_from_start: смена направления перезапускает скан | под наблюдателем | S4 на btree и hash; GiST — pass (Backward не вызывается) | `get(forward) -> (1,2); get(backward) -> (2,3)`, ожидалось false |
| restore_once: работает только первый restore после mark | под наблюдателем | S5 на btree (depth 6); при depth 5 — нет (нужно 6 операций тела) | `get; mark; restore; get -> (1,3); restore; get -> (2,1)`, ожидалось (1,3) |
| caller_more_keys: `amrescan` с nkeys + 1 | над наблюдателем | S8 на всех AM с ключами; AM вызов не получает | `begin; rescan` → `refused: amrescan.nkeys <= ambeginscan.nkeys (2 vs 1)`; на трафике executor'а — ERROR |

### Красные пробы (мутация движка или spec, одноразовая копия)

| проба | итог стенда |
|---|---|
| P1 движок не проверяет время жизни | красный: none, itup_shared, dir_from_start, restore_once |
| P2 `next` всегда от начала скана (модель без позиции) | красный везде |
| P3 движок генерирует истории вне domain (отсекает только по obligation) | красный везде: генерируются повторы направления после false, btree/hash перезапускают скан |
| P4 движок игнорирует refused | красный: caller_more_keys |
| P5 движок не сравнивает expect | красный: dir_from_start, restore_once |
| P6 spec: пустой `lifetime_ends` | красный везде |

### Охрана от пустых проверок

- Строка покрытия на каждый профиль: сколько раз выполнена каждая
  операция с аргументами.  Так найдена ошибка: YAML 1.1 читал поле
  состояния `on` как `true`, условие mark не выполнялось ни
  разу, и S5 проходил пусто (mark=0).  Поле переименовано в
  `positioned`.
- Эталон L — прямой проход того же AM без контрольных слоёв, сверенный
  с seqscan (множество TID) и, при `amcanorder`, с ORDER BY (порядок
  значений).
- Глубина важна: на этих данных (3 записи на листовую страницу) R8
  видна с depth 5 (тогда — на `amendscan`), restore_once — только с
  depth 6.  Стенд использует depth 6.

### Obligation и domain

Первая версия spec записала все отсечения генератора как обязательства
вызывающего.  Три из них документацией не требуются: повтор направления
после `false`, mark без выданной записи, restore без mark.  Это
соглашения executor'а и наблюдаемое поведение nbtree/hash, а не
контракт интерфейса.  Они вынесены в `domain`: вне его истории не
генерируются и не проверяются, а вызывающий, оказавшийся там, не
считается нарушителем (на трафике это печатается как «outside domain»,
не FAIL).  В obligation остались только документированные требования:
первый Backward при `amcanorder`, смена направления при
`amcanbackward`, nkeys/norderbys не больше, чем в begin.  Множество
сгенерированных историй от этого не изменилось; стенд 5/5 и пробы
P1–P6 повторены.  Трафик executor'а в этих запросах за domain не
выходит, поэтому путь «outside domain» в replay не исполнялся.

## Consequence

| | |
|---|---|
| выразимо | S4, S5-local, S7, S8: обязательства вызывающего, область определённого поведения (domain), постусловия AM, время жизни возвращённых данных, обязательства над аргументами |
| потребовало новой информации | state, obligation, domain, guard, effect, observable с lifetime, reference «forward pass», профиль генерации (PROTOCOL-MODEL.md).  Из v0 использованы только capabilities |
| перенесено в D3 | S5-concurrent (согласованность позиции и метки при конкурентных insert/delete) |
| не сделано в этом шаге | S11 (нужна сущность resource), V1, V7, U4 (другая точка перехвата: `ambulkdelete`, `amvacuumcleanup`, `aminsert`), O13 (перехват support-функций через fmgr) |
| сущности, добавленные к v0 | state, obligation, domain, guard, effect, observable.lifetime, reference.forward_pass, generation — в отдельном `protocolspec-v0.yaml`; v0 не изменён.  Слово «protocol» в v0 (соглашение о вызове) и в D2 (порядок вызовов) — разные понятия |

Трафик executor'а проверяет обязательства вызывающего, domain и время жизни, но
не результат: результат — дело D0 (S1-ext).  Поэтому dir_from_start на
scroll cursor не виден в replay, а виден в сгенерированных историях.

## Next step

Гейт перед D3.  D2 не закоммичен.
