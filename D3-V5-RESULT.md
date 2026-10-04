# D3, V5: index-only scan under concurrent VACUUM

PostgreSQL: ad36e3608c8.  Метки: DOC — документация, CODE — код или
комментарий в коде/README, derived — выведено из DOC+CODE, hypothesis —
не проверено.

## Question

Может ли конкурентный VACUUM заставить index-only scan вернуть строку,
которой нет в его MVCC-снимке, или иначе нарушить наблюдаемый контракт
скана?  Какое внешнее обязательство обеспечивает V5 («index-only scan
никогда не снимает pin», BT-INV, CODE/INT), выражается ли оно в
InterfaceSpec/D3 и хватает ли для его проверки чередований на границе
callback'ов.

## Source contracts

| # | утверждение | где | метка |
|---|---|---|---|
| 1 | любой скан таблицы проверяет, что каждая выданная строка видима MVCC-снимку запроса; для index-only это делается через visibility map, без heap | indices.sgml:1204–1218 | DOC |
| 2 | V2: перед удалением heap-записи VACUUM'ом все её записи индекса удаляются | indexam.sgml:1117–1121 | DOC |
| 3 | V3: скан держит pin на странице последней выданной записи; `ambulkdelete` не удаляет записи со страниц под чужим pin'ом | indexam.sgml:1124–1131 | DOC |
| 4 | зачем V3: читатель может увидеть запись индекса, затем VACUUM удалит её и heap-запись, затем третья сессия переиспользует слот; при MVCC-снимке новый жилец «certain to be too new to pass the snapshot test» | indexam.sgml:1133–1155 | DOC |
| 5 | «асинхронный» скан (собрать TID'ы, к heap позже) допустим для MVCC-снимка | indexam.sgml:1157–1167 | DOC |
| 6 | index-only: VM — «no concern of the access method's» | indexam.sgml:1036–1043 | DOC |
| 7 | VACUUM: индексы чистятся до второго прохода по heap; LP_DEAD → LP_UNUSED только во втором проходе («no extant index tuple can ever ... point to an LP_UNUSED line pointer») | vacuumlazy.c:1250–1265, `lazy_vacuum` 2382, `lazy_vacuum_heap_page` 2771 | CODE |
| 8 | тот же второй проход ставит странице all-visible в VM, если после очистки все строки видимы всем | vacuumlazy.c:2801 (`heap_page_would_be_all_visible`), 2849 (`visibilitymap_set`) | CODE |
| 9 | освобождённый line pointer переиспользуется следующей вставкой на эту страницу | bufpage.c:185–200 (`PageAddItemExtended`: «first one that is both unused and deallocated») | CODE |
| 10 | index-only исполнитель: если VM говорит all-visible, строка берётся из `xs_itup` без heap; иначе проверка heap-кортежа | heapam_indexscan.c:358–398 | CODE |
| 11 | btree: скан снимает pin листа, только если `!xs_want_itup`, MVCC-like снимок и есть heap: «We cannot safely drop leaf page pins during index-only scans due to a race condition involving VACUUM setting pages all-visible in the VM» | nbtree.c:403–421; nbtsearch.c:50–75 | CODE |
| 12 | btree VACUUM берёт cleanup lock на каждом листе | nbtree.c:1534–1539 | CODE |
| 13 | README: MVCC-снимок защищает plain index scan, но index-only «never drop their buffer pin»: они смотрят только VM и не заметят, что TID стал LP_UNUSED, а страница all-visible | nbtree/README:456–472 | CODE |
| 14 | GiST: лист читается целиком и pin снимается (`UnlockReleaseBuffer`), в том числе для index-only; VACUUM GiST берёт обычный exclusive lock | gistget.c:413–418, 546; gistvacuum.c:332 | CODE |

pgsql-hackers: та же гонка для GiST/SP-GiST описана P. Geoghegan
(2021-11-03, «Why doesn't GiST VACUUM require a super-exclusive lock, like
nbtree VACUUM?»), с isolation-тестами и патчем M. van de Meent (2025-03-07,
2025-04-25; новый `table_index_vischeck_tuples()` и cleanup lock в VACUUM
GiST/SP-GiST).  В ad36e36 этого исправления нет (`vischeck` в дереве не
найден; п. 14).

## Mechanism vs observable contract

Причинная цепочка:

1. AM выдаёт TID (и для index-only — данные записи). DOC.
2. Строка удалена и мертва для всех (удаление закоммичено до снимка A,
   снимок A не держит её). VACUUM удаляет записи индекса, затем в
   том же VACUUM помечает heap-слот LP_UNUSED. DOC (п. 2) + CODE (п. 7).
3. Слот может быть переиспользован новой строкой. CODE (п. 9).
4. Plain index scan с MVCC-снимком не спутает: heap-визит видит пустой слот
   или новую строку, «too new to pass the snapshot test». DOC (п. 4–5).
5. Index-only scan heap не посещает, если VM говорит all-visible; VACUUM
   ставит all-visible в том же втором проходе (п. 8).  Если AM выдаёт TID,
   прочитанный до VACUUM, после этого прохода, исполнитель вернёт данные
   строки, невидимой снимку. derived (п. 7, 8, 10).
6. btree закрывает окно, держа pin листа во время index-only scan: VACUUM
   не может взять cleanup lock на этом листе, значит не доходит до второго
   прохода по heap, пока скан не ушёл со страницы. CODE (п. 11–13); это V5.
7. Документация интерфейса этого не говорит: п. 5 разрешает асинхронный
   скан при MVCC, п. 6 называет VM заботой не AM. Для index-only п. 5
   неверен. derived (DOC п. 5–6 против CODE п. 10, 13).

Переиспользование TID (п. 3) в этой цепочке не нужно: опасен шаг 5 (VM),
а не путаница идентичности.  После переиспользования вставка снимает бит
all-visible, исполнитель идёт в heap и находит строку, невидимую снимку A.
derived, проверяется ниже.

Значит, наблюдаемый контракт — п. 1 (index-only scan выдаёт ровно строки,
видимые его снимку), а pin в V5 — его механизм в nbtree.  Уровень A (какие
записи вправе вернуть AM) этого не выражает: по S6 запись удаляемой строки
скан может выдать или не выдать, и выдача удалённой записи — допустимый
исход S6.  Нарушение видно только на уровне C: исполнитель, получивший TID
и данные записи, плюс VM.

## Why index-only is different

Plain index scan после каждого TID идёт в heap и проверяет кортеж своим
снимком: пустой слот или новый жилец отвергаются (DOC п. 4).  Index-only
scan идёт в heap, только если VM не говорит all-visible (CODE п. 10).
VACUUM ставит all-visible после того, как убрал записи индекса и сделал
слоты LP_UNUSED (CODE п. 7–8).  Если AM выдаёт TID, прочитанный до этого,
heap уже не проверяется.  Разница — в том, кто проверяет видимость, а не в
наборе записей, которые AM вправе выдать.

Измерено: один и тот же контрольный слой (`collect_all`, ниже) на одном и
том же индексе даёт FAIL для index-only и pass для plain index scan.

## History

A2 — курсор в транзакции REPEATABLE READ (один снимок для A2 и эталона).
FETCH — шаг A2; B действует только между FETCH'ами, то есть между
callback'ами.  Профиль `v5` (`concurrencyspec-v0.yaml`): пролог
`A2.fetch(1)`, тело глубины 3 из `A2.fetch(1)`, `A2.fetch(500)`,
`B.remove` (≤ 1), `B.insert` (≤ 1), эпилог `A2.fetch(all)`; 44 истории на
субъект.

Данные (`subjects_v5.yaml`): 2000 строк `(id, k, pad)`, fillfactor 10,
covering btree `(k) INCLUDE (id)`; reset: вставка, VACUUM (VM all-visible),
затем удаление каждой третьей строки.  Запрос A2: `SELECT k, id ... WHERE
k > 0 ORDER BY k`.  План проверяется EXPLAIN в транзакции A2 в каждой
истории: Index Only Scan 44/44; на данных без удалений `Heap Fetches: 0`.
Сравнительный субъект — тот же индекс, plain Index Scan (запрос берёт
`pad`).

MVCC-хореография одной истории:

| строка | удаление закоммичено | снимок A2 | VACUUM может убрать heap-кортеж | запись индекса | слот переиспользуется |
|---|---|---|---|---|---|
| удалённая (`id % 3 = 0`) | до BEGIN A2 | после | да: xmax старше xmin A2 | да, в первой фазе VACUUM | после второго прохода, следующей вставкой на эту страницу |
| живая | — | видит | — | остаётся | — |
| вставленная B | после снимка A2 | не видит | — | новая запись | занимает освобождённый слот |

Снимок A2 не держит удалённые строки: удаление закоммичено до его начала.
Поэтому VACUUM доходит до LP_UNUSED и all-visible, пока A2 открыт.
Вставленные B строки невидимы A2.  Пока жив снимок A2, VACUUM не может
снова поставить all-visible странице с такой строкой.

## Identity model

Строка идентифицируется неизменяемым логическим `id` из INCLUDE, не TID.
A2 TID не видит (index-only запрос не возвращает ctid).  Переиспользование
TID фиксируется на стороне B: ctid вставленной строки ∈ ctid удалённых.
Guard S6 (TID reuse → BOUNDARY) здесь не применяется.

Измерено: переиспользование было в 6 историях на субъект (plain index scan;
index-only с контролем).  Строк новой логической строки через старый TID —
0.  Удалённых строк, выданных после того, как их TID переиспользовала
вставка, — 0 во всех прогонах, включая контроль и GiST.  Вставка на
страницу снимает с неё all-visible, исполнитель идёт в heap и отвергает
новую строку снимком.  Путаница идентичности при MVCC-снимке A2 в этих
историях недостижима, переиспользование её маскирует.  derived + measured.

## Reference / oracle

Эталон — тот же запрос последовательным сканом в той же транзакции A2
(тот же снимок), после закрытия курсора.  Вердикт: строки A2 = эталонные
(по порядку, если запрос упорядочен).  Лишняя строка = строка, невидимая
снимку A2.  Pin, VM, блоки, LSN в вердикте не участвуют.

## Result

Eligible history: B.remove завершился, и свежий скан индекса (из третьей
сессии) не находит записей удалённых строк — очистка наблюдалась.  Сколько
таких историй будет, зависит от xmin чужих сессий, поэтому число —
evidence.  Сравниваемый вывод (`expected/d3v5_*.out`) — инварианты: план
в каждой истории; eligible-истории есть или нет; вердикт; под контролем —
падает ли каждая eligible-история и есть ли отказы вне них.

| субъект | без контроля | `collect_all` |
|---|---|---|
| btree `(k) INCLUDE (id)`, index-only | pass; eligible нет (VACUUM ждёт pin) | FAIL в каждой eligible-истории, вне них — нет |
| btree, тот же индекс, plain index scan | pass; eligible есть | pass; eligible есть |

Один прогон без помех (evidence): под контролем eligible 24 из 44, все 24
падают.  Под периодическим чужим снимком (REPEATABLE READ, 0.3 с из каждой
секунды): eligible 16, падают 16, остальные проходят.  Сравниваемый вывод
в обоих случаях одинаков.

Минимальная падающая история (контроль, index-only):

    A2.fetch(1) -> 1 rows
    A2.fetch(1) -> 1 rows
    A2.fetch(1) -> 1 rows
    B.remove -> completed
    A2.fetch(all) -> 1996 rows
    reference: 1334 rows; A2 returned 1999
    665 rows A2's snapshot cannot see, 665 of them deleted before A2 began

Все лишние строки — строки, удалённые до начала A2.  Ни одной строки,
которой не было бы в индексе при начале A2.

Known violation (`subjects_v5_known.yaml`, отдельная проверка
`d3v5_gist_known_violation`): реальный GiST `(p) INCLUDE (id)` index-only
без контрольного слоя.  Семантический вердикт — FAIL; проверка нормализует
его до «reproduced»: хотя бы одна eligible-история нарушает оракул.  Если
upstream исправит ошибку, проверка покажет «NOT reproduced», и ожидание
пора снять.  Evidence: 23 из 44 историй без помех (533–540 строк за прогон,
все удалены до A2), 15 из 16 eligible под чужим снимком.  Совпадает с
открытой проблемой pgsql-hackers (Source contracts); BT-INV R9.

Стенд `check_d3_v5.sh` ~5 с.  Все четыре гейта прогнаны три серии подряд
и одну под чужим снимком: сравниваемый вывод одинаков.

## Controls

`collect_all` (`d2_ctl.c`, слой под исполнителем, ставится на индекс на
время транзакции через `d2_ctl_install`): первый `amgettuple` после
`amrescan` читает все записи (TID, данные, recheck) и дальше выдаёт их из
памяти.  AM ничего не держит в индексе между выдачами — модель AM без
interlock'а скан/VACUUM, как GiST.  Ломает наблюдаемый результат
(невидимые снимку строки), а не pin-инвариант как таковой.  Красный на
index-only, зелёный на plain index scan.

Второй контроль «данные новой строки через старую идентичность» не сделан:
при MVCC-снимке A2 это ненаблюдаемо (Identity model).  Контроль, который
подменял бы данные, проверял бы сам себя.

## Red probes

Новая модель минимальна — эталон по снимку A2 и сравнение строк.  Пробы на
копии `d3.py`:

| проба | что доказывает | результат |
|---|---|---|
| P1 эталон в новой транзакции (другой снимок) | эталон обязан разделять снимок A2 | none: pass → FAIL (ложные отказы на обоих субъектах) |
| P2 удалённые до A2 строки не считаются (правило S6 «removed: may» на уровне исполнителя) | закон строже S6 | collect_all: FAIL → pass; GiST known violation: reproduced → NOT reproduced |

Пробы Q1–Q2 из задания (TID как идентичность) неприменимы: вердикт не
использует TID.

## Evidence about pins / waiting

`results/d3_v5_evidence.txt`, зависит от планирования, не сравнивается:

| субъект | B.remove завершился сразу | заблокирован A2 |
|---|---|---|
| btree index-only, без контроля | 0 | 24 (`Buffer/BufferCleanup`) |
| btree plain index scan | 24 | 0 |
| btree index-only, `collect_all` | 24 | 0 |
| GiST index-only | 24 | 0 |

Заблокированный VACUUM (btree index-only) — проявление V5: VACUUM не может
взять cleanup lock на листе A2 и не доходит до второго прохода по heap.
Поэтому без контроля в этих историях B.insert после remove не выполнялся
(B ждёт), и переиспользования у btree index-only нет (0).

## Boundaries

- Окно внутри одного вызова исполнителя (между возвратом `amgettuple` и
  проверкой VM в `heapam_index_getnext_slot`) не проверено: оно ниже
  границы callback'ов.  Для btree и для `collect_all` опасное окно — между
  `amgettuple` (AM читает лист целиком раньше, чем выдаёт записи), то есть
  на границе.  AM, который не буферизует записи между вызовами, этим
  срезом не покрыт: BOUNDARY, requires AM→executor handoff interleaving.
- Non-MVCC снимки (SnapshotAny, dirty) не проверялись; для них DOC п. 4
  требует синхронного скана и pin'а и для plain index scan.
- Только forward, один VACUUM, ≤ 1 вставка.
- R8 не затрагивается: данные строки копирует исполнитель при FETCH,
  lifetime `xs_itup` не наблюдается.
- Сколько историй eligible (S6: сколько BOUNDARY), зависит от xmin чужих
  сессий.  Измерено: под периодическим чужим снимком S6 BOUNDARY на btree
  40 → 32, V5 eligible 24 → 16.  Поэтому эти числа — evidence, а гейт
  проверяет инварианты.  Если чужой снимок держится весь прогон, eligible
  не будет, и V5-гейт покажет «none» вместо «yes»: история без очистки
  ничего не проверяет.  Измерено с чужим снимком на весь прогон: оба
  V5-вывода показывают «none», known violation — «NOT tested: no history
  with an observed cleanup» (не «NOT reproduced»).

## Consequence

B, с уточнением.  V5 — механизм nbtree, реализующий наблюдаемый закон,
который уже документирован: index-only scan выдаёт только строки, видимые
его MVCC-снимку (indices.sgml:1204–1218).  Нового закона InterfaceSpec V5
не даёт.

Но этот закон не выражается на уровне AM (протокол + S6): по S6 выдача
записи удалённой строки — допустимый исход, и ошибочным его делает только
исполнитель (данные из индекса + VM вместо heap).  Для проверки
понадобились actor-исполнитель (A2, курсор) и эталон «тот же запрос по
снимку A2».  Это расширение существующих сущностей actor и reference, не
новая сущность.  Identity по логическому id нужна стенду, но закону нет:
при MVCC-снимке путаница TID не наблюдается.

Документация интерфейса неполна: indexam.sgml:1157–1167 разрешает
асинхронный скан при MVCC, :1036–1043 называет VM заботой не AM, но
index-only scan без interlock'а возвращает удалённые строки.  Это показано
контролем на btree и реальным GiST на ad36e36.  Кандидат в расхождения
BT-INV (DOC ≠ CODE), как R2.
