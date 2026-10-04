# BT-INV: контракты btree Index AM

Цель: какие обязательства Index AM сегодня существуют только в документации
или реализации, какие из них можно описать явно и какие проверки можно
автоматически получить из такого описания.  Этот файл — только каталог для
btree.  Общность разобрана в INTERFACE-GENERALITY.md.

База: PostgreSQL master `ad36e3608c8` (20devel).  Номера строк — по этой
ревизии; для nbtree/README указан раздел.

## Легенда

**Носитель** — где контракт записан сейчас:
`IF` поле/указатель `IndexAmRoutine` · `DOC` sgml/README/комментарий заголовка ·
`CODE` только поведение реализации или предположение потребителя ·
`AMCHK` проверка в contrib/amcheck.

**Соблюдение** — что происходит при нарушении:
`assert` · `error` · `validate` (amvalidate) · `check` (amcheck по запросу) · `—` ничего.

**Наблюдение** — где нарушение видно:
`SQL` результат запроса против эталона результата ·
`CB` граница callback'а (`indexam.c`, `IndexScanDesc`) ·
`CAT` каталог + прямой вызов support-функций ·
`INT` внутреннее состояние страниц/буферов · `CRASH` после рестарта/replay.

**Проверка** — какой вид проверки выводится:
`P` свойство на значениях · `D` сравнение с эталоном результата ·
`H` история/конечный автомат · `S` обход структуры.
✔ — есть в прототипе `opclass_laws/`.

## A. Возможности и handler

| ID | Контракт | Источник | Носитель | Собл. | Набл. | Пров. |
|---|---|---|---|---|---|---|
| A1 | 11 обязательных callback'ов не NULL | amapi.c:46 | IF | assert | CAT | — |
| A2 | есть хотя бы один из `amgettuple`, `amgetbitmap` | indexam.sgml:1064; plancat.c:312 | DOC | — | CAT | P |
| A3 | `amcanorder` ⇒ `ammarkpos` и `amrestrpos` | indexam.sgml:1013 | DOC | — | CAT | P |
| A4 | `amcanorder` ⇒ btree-совместимые номера стратегий | indexam.sgml:978; plancat.c:346 | DOC+CODE | — | CAT | P |
| A5 | Backward-скан бывает только при `amcanorder` | indexam.sgml:1001–1009; execAmi.c:620 | DOC | — | CB | P |
| A6 | `amoptionalkey` ⇒ AM индексирует NULL; при `amcanmulticol` NULL в не первых колонках индексируется всегда | indexam.sgml:243–252 | DOC | — | SQL | D |
| A7 | `amcaninclude` ⇒ `amcanreturn` true для INCLUDE-колонок; INCLUDE-колонки допускают NULL | indexam.sgml:269, 474 | DOC | — | CB | D |
| A8 | *снято при сверке*: parallel-callback'и необязательны и при `amcanparallel` (indexam.sgml:862, 880, 890; indexam.c:528, 565, 589) — импликации нет | | | | | |
| A9 | `amcanunique` ⇒ `aminsert` соблюдает режимы `IndexUniqueCheck` (раздел U) | indexam.sgml:1191 | DOC | — | SQL | D/H |
| A10 | `amsearcharray`/`amsearchnulls` ⇒ AM сам вычисляет SAOP / IS [NOT] NULL; «так же, как квалификатор» выведено из S1 | amapi.h:265, 267; indexam.sgml:255 (только nulls), 949 | IF (флаг) | — | SQL | D |
| A11 | handler возвращает постоянную структуру, ядро считает её const | indexam.sgml:74–81 | DOC | — | CAT | — |

## O. Законы opclass (исполняемая часть — `opclass_laws/`)

`btvalidate` (nbtvalidate.c:40) проверяет номера, сигнатуры и полноту набора
операторов и функций.  Поведение не проверяет никто: контрольный opclass
с нарушенными законами проходит `amvalidate` (тест `control_opclass`).

| ID | Контракт | Источник | Носитель | Собл. | Набл. | Пров. |
|---|---|---|---|---|---|---|
| O1 | cmp рефлексивен | btree.sgml:86, 154; cmp: 215–236 | DOC | — | CAT | P ✔ |
| O2 | cmp антисимметричен: sgn cmp(a,b) = −sgn cmp(b,a) | btree.sgml:95, 154 | DOC | — | CAT | P ✔ |
| O3 | ≤ по cmp транзитивно (вместе с O1/O2: `=` эквивалентность, `<` строгий порядок) | btree.sgml:105, 134 | DOC | — | CAT | P ✔ |
| O4 | операторы стратегий 1–5 согласованы с cmp | btree.sgml:167, 215–236 | DOC | — | CAT | P ✔ |
| O5 | компаратор sortsupport совпадает с cmp | sortsupport.h, заголовок | DOC | — | CAT | P ✔ |
| O6 | ненулевой результат abbreviated-компаратора — надёжный знак cmp; `abbrev_full_comparator` ≡ cmp | sortsupport.h:125 | DOC | — | CAT | P ✔ |
| O7 | equalimage=true ⇒ (cmp=0 ⇔ `datum_image_eq`) для этой collation | btree.sgml:516 | DOC | частично: amcheck сверяет только флаг метастраницы (verify_nbtree.c:344) | CAT | P ✔ |
| O8 | in_range монотонен по val и по base при фиксированных offset, sub | btree.sgml:391 | DOC | — | CAT | P ✔ |
| O8b | определение in_range: val ≤/≥ base ± offset, верно и при переполнении | btree.sgml:319–390 | DOC | — | CAT | P |
| O9 | skip support: low/high — границы домена, inc/dec — соседние элементы, overflow ровно на границе | skipsupport.h:64 и далее | DOC | — | CAT | P ✔ |
| O10 | законы O1–O4 для значений разных типов внутри семейства | btree.sgml:172 | DOC | validate проверяет только наличие cross-type операторов (nbtvalidate.c:272) | CAT | P |
| O11 | неявные и binary-coercion касты внутри семейства не меняют порядок | btree.sgml:189 | DOC | — | CAT | P |
| O12 | cmp стабилен во времени (версия collation, IMMUTABLE) | pg_collation.collversion; неявно | CODE | предупреждение о версии collation | INT (amcheck) | P на старом и новом окружении |
| O13 | AM не вызывает support-функции с NULL и сам упорядочивает NULL | skipsupport.h; sortsupport.h | DOC | — | CB | — |

## S. Протокол скана

| ID | Контракт | Источник | Носитель | Собл. | Набл. | Пров. |
|---|---|---|---|---|---|---|
| S1 | без recheck результат равен в точности множеству подходящих записей; btree ставит `xs_recheck=false` | indexam.sgml:949, 715 | DOC | — | SQL | D |
| S2 | в пределах скана каждая запись возвращается не более одного раза (SAOP, skip scan, parallel) | indexam.sgml:1031–1033, 830; nbtpreprocesskeys.c:2732 (`_bt_sort_array_elements`) | DOC (parallel), CODE (SAOP) | — | SQL | D |
| S3 | при `amcanorder` порядок выдачи — порядок opclass в заданном направлении; в parallel — внутри каждого воркера | indexam.sgml:970, 836 | DOC | — | SQL | D |
| S4 | первый вызов Backward ⇒ последнее совпадение; дальше движение в любую сторону от последней выданной записи | indexam.sgml:1001–1009 | DOC | — | CB | H |
| S5 | mark/restore: одна метка, повторные restore; позиция согласована при конкурентных insert/delete | indexam.sgml:1013–1024 | DOC | — | CB | H |
| S6 | допустимая неопределённость: свежая вставка может появиться или нет, в том числе после rescan или шага назад; конкурентное удаление — так же | indexam.sgml:1026 | DOC | — | SQL | задаёт **интервал** эталона результата |
| S7 | `xs_want_itup` ⇒ исходные значения в `xs_itup`/`xs_hitup`, валидны до следующего вызова | indexam.sgml:729–741 | DOC | — | CB | H |
| S8 | `amrescan`: nkeys/norderbys не больше, чем в `ambeginscan` | indexam.sgml:694 | DOC (обязательство вызывающего) | — | CB | H |
| S9 | `amgetbitmap` даёт объединение результатов `amgettuple` | indexam.sgml:1051 | DOC | — | SQL | D |
| S10 | `kill_prior_tuple` — только подсказка; не может скрыть видимую запись | README «Simple deletion»; nbtree.c:255; nbtutils.c:238–245; heapam_indexscan.c:548–566 | CODE | — | SQL | H |
| S11 | `amendscan` освобождает pin'ы, lock'и, память | indexam.sgml:787–795 | DOC | предупреждения resowner | CB | H |
| S12 | предикат частичного индекса AM не перепроверяет | indexam.sgml:721 | DOC | — | — | — |
| S13 | parallel: объединение выдач воркеров равно последовательному скану | indexam.sgml:830 | DOC | — | SQL | D |
| S14 | L&Y: move-right при сплите; обратный скан через удалённые/half-dead страницы (`_bt_lock_and_validate_left`) | README «Lehman & Yao», «Page deletion and backwards scans»; nbtsearch.c:1982 | CODE | — | INT | H (прошлая nbtree-машина) |

S1 и S9 состоят из двух частей.  Внешняя проекция (**S1-ext**, **S9-ext**):
результат исполнения через индекс равен эталону — видна в SQL.
Внутренний callback-контракт: при `xs_recheck = false` выдача точная
(S1); `amgetbitmap` эквивалентен объединению `amgettuple` (S9) — видна
только на границе callback'ов.  Для AM с recheck это разные утверждения:
внешняя проекция выполняется и тогда, когда AM полагается на recheck.

## V. VACUUM и жизнь TID

| ID | Контракт | Источник | Носитель | Собл. | Набл. | Пров. |
|---|---|---|---|---|---|---|
| V1 | после возврата `ambulkdelete` ни одна запись индекса не ссылается на TID, для которого callback вернул true | indexam.sgml:407–420 | DOC | — | CB | H |
| V2 | записи индекса удаляются раньше, чем heap-запись | indexam.sgml:1121 | DOC (ядро) | — | — | — |
| V3 | **interlock**: скан держит pin на странице последней выданной записи — **или** btree снимает pin при MVCC-like снапшоте, `!xs_want_itup` и `heapRelation != NULL` | indexam.sgml:1126 против nbtree.c:419; README «Making concurrent TID recycling safe» | DOC ≠ CODE | — | INT | H |
| V4 | после снятия pin LP_DEAD ставится только при неизменном LSN страницы (для unlogged — fake LSN) | nbtutils.c:238–245; README там же | CODE | — | INT | H |
| V5 | index-only scan никогда не снимает pin | README там же; nbtree.c:419 | CODE | — | INT | H |
| V6 | удалённая страница переиспользуется только после того, как safexid стал старше всех снапшотов | nbtree.h:292 `BTPageIsRecyclable`; README «Placing deleted pages in the FSM» | CODE | — | INT | H (AMSpec retire/reuse) |
| V7 | `amvacuumcleanup`: NULL или palloc'нутая статистика; вызывается и без bulkdelete | indexam.sgml:438–455 | DOC | — | CB | H |
| V8 | сканы на standby согласованы с replay удалений и сплитов | README «Scans during Recovery» | CODE | — | CRASH | H |

## U. Уникальность

| ID | Контракт | Источник | Носитель | Собл. | Набл. | Пров. |
|---|---|---|---|---|---|---|
| U1 | семантика `UNIQUE_CHECK_NO/YES/PARTIAL/EXISTING` | indexam.sgml:1281–1330 | DOC | — | SQL | D |
| U2 | конфликт с незавершённой транзакцией ⇒ ждать её исхода; «живая» запись определяется по heap | indexam.sgml:1224–1234; nbtinsert.c:411 | DOC | — | SQL | H |
| U3 | NULLS NOT DISTINCT | nbtutils.c:143 (`_bt_mkscankey`) | CODE+DOC | — | SQL | D |
| U4 | `indexUnchanged` — подсказка, не условие корректности | indexam.sgml:365 | DOC | — | — | H |
| U5 | в индексе нет двух видимых равных ключей | verify_nbtree.c:904 | AMCHK | check | INT | S |

## T. Структура (nbtree-internal; сейчас это amcheck)

| ID | Контракт | Источник | Носитель | Собл. |
|---|---|---|---|---|
| T1 | записи на странице упорядочены | verify_nbtree.c:1632 | AMCHK | check |
| T2 | high key ≥ всех записей страницы | verify_nbtree.c:1586 | AMCHK | check |
| T3 | порядок сохраняется при переходе к правому соседу | verify_nbtree.c:1749 | AMCHK | check |
| T4 | нижняя граница downlink; ключ в родителе совпадает с high key ребёнка | verify_nbtree.c:2535, 2354 | AMCHK | check |
| T5 | левая и правая ссылки соседей согласованы; нет циклов | verify_nbtree.c:1195, 792, 2246 | AMCHK | check |
| T6 | уровни согласованы | verify_nbtree.c:778 | AMCHK | check |
| T7 | у каждой некорневой живой страницы есть downlink | verify_nbtree.c:2627 | AMCHK | check |
| T8 | TID в posting list отсортированы и уникальны | verify_nbtree.c:1426 | AMCHK | check |
| T9 | размер записи ≤ 1/3 страницы | btree.sgml:19; README «Other Things»; verify_nbtree.c:1479 | DOC+AMCHK | error при вставке |
| T10 | инварианты suffix truncation: у non-pivot есть heap TID, pivot/non-pivot на своих местах | README «Notes about suffix truncation»; verify_nbtree.c:3561 | AMCHK | check |
| T11 | в записи индекса нет внешних varlena | verify_nbtree.c:2889 | AMCHK | check |
| T12 | флаг allequalimage в метастранице ⇔ все opclass'ы индекса дают equalimage=true | nbtutils.c:1175 `_bt_allequalimage`; verify_nbtree.c:344 | AMCHK | check |
| T13 | half-dead бывает только лист; FULLXID только у удалённых страниц | verify_nbtree.c:3424, 3441 | AMCHK | check |
| T14 | heapallindexed: каждая индексируемая heap-запись есть в индексе | verify_nbtree.c:2801 | AMCHK | check |
| T15 | rootdescend: каждая запись находится поиском от корня | verify_nbtree.c:1397 | AMCHK | check |
| T16 | каждое структурное изменение атомарно в пределах WAL-записи; незавершённый сплит восстанавливается | README «WAL Considerations» | CODE | — |

## Расхождения (выведено из кода и документации)

- **R1 (A3).** Документация: упорядоченный AM *обязан* поддерживать
  mark/restore.  Код: `plancat.c:315` выводит `amcanmarkpos` из наличия
  указателей; без них планировщик строит merge join с Material над
  внутренней стороной (execAmi.c:434 → costsize.c:4163–4165).  Документ
  строже кода.
- **R2 (V3).** Документация даёт одно правило (держать pin).  Реализация
  btree использует более слабое условие: pin **или** MVCC-снапшот плюс
  LSN-гейт для kill.  Этот ослабленный контракт принадлежит только nbtree и
  интерфейсу неизвестен.
- **R3 (A5).** Документация: backward только при `amcanorder`.
  `IndexSupportsBackwardScan` (execAmi.c:604, 620) смотрит только на
  `amcanbackward`.
  Нужна ли импликация `amcanbackward ⇒ amcanorder` — открытый вопрос.
- **R4 (O*).** `amvalidate` принимает opclass, нарушающий любой из законов
  O1–O9.  Показано на контрольном opclass.
- **R5 (O7, наблюдаемое поведение).** Список типов, для которых дедупликация
  небезопасна (btree.sgml, раздел про дедупликацию), неполон: у
  `interval_ops` нет equalimage (`'1 day'` и `'24 hours'` равны по cmp, но
  различаются по образу), и на индексе по interval `bt_metap().allequalimage = f`.
  В перечне interval не упомянут, хотя отказ от equalimage для interval
  намеренный: amcheck знает про interval-индексы, построенные до 2023-11,
  с неверным флагом (verify_nbtree.c:336–347).

- **R9 (V2/V3/V5, наблюдаемое поведение).**  Интерфейсная документация
  неполна относительно index-only scan.  indexam.sgml:1157–1167 допускает
  асинхронный скан (TID'ы собраны, pin снят) при MVCC-снимке;
  :1036–1043 — VM «no concern of the access method's».  Для plain index scan
  это верно: heap-визит отвергает строку снимком.  Для index-only — нет:
  исполнитель не идёт в heap, если VACUUM успел убрать записи, сделать слоты
  LP_UNUSED и поставить all-visible (heapam_indexscan.c:358–398,
  vacuumlazy.c:2771–2849).  Нужен interlock между выдачей TID и проверкой
  VM; btree даёт его pin'ом (V5, nbtree.c:403–421, README:461–472), GiST —
  нет (gistget.c:546, gistvacuum.c:332).  На ad36e36 GiST index-only scan
  выдаёт строки, удалённые до начала скана (D3-V5-RESULT.md,
  `d3v5_gist_known_violation`).  Известно upstream (pgsql-hackers:
  Geoghegan 2021-11-03; патч van de Meent 2025, не закоммичен).  В отличие
  от R1–R8, меняет результат запроса.

## Покрытие прототипом

Исполняемо сейчас: O1–O9 (кроме O8b), на значениях и в выбранной collation.
Не покрыто: O8b, O10, O11 (cross-type и касты требуют двух выборок и
знания кастов), O12 (две среды).

Ограничения прототипа.  Проверка идёт на выборке, а не на всей колонке:
попарные законы — O(n²) вызовов компаратора, O3 и O8 — O(n³); используются
первые `max_n` значений (по умолчанию 1000; для in_range — 50), усечение
видно в колонке `detail`.  Замер без ограничения: n=3000 — 0.9 с для int4,
7.3 с для text в ICU.  Выборку с живой таблицы брать через TABLESAMPLE.
Skip support вызывается с `rel = NULL`: встроенные реализации `rel` не
используют, `skipsupport.h` этого не обещает.

## Покрытие в ванили

Есть ли в ванильном дереве тест, который проверяет *именно этот контракт*.
Смотрел `src/test/{regress,isolation,modules,recovery}` и `contrib/amcheck`:
поиск по ключевым словам плюс чтение заголовков найденных тестов.  Это
вывод из поиска, а не полный аудит; пропуски возможны.

`прямо` — тест нацелен на контракт · `косв.` — путь исполняется, но контракт
не утверждается (примеры, итог запроса) · `нет` — теста не нашёл.

| ID | Ваниль | Чем |
|---|---|---|
| A1 | косв. | `Assert` при любой загрузке AM |
| A2–A7, A9–A11 | нет | импликации флагов не проверяет никто; `dummy_index_am` тестирует только reloptions |
| O1–O4 | нет | `opr_sanity.sql` проверяет форму каталога (сигнатуры, volatility :822, имена стратегий :1123), не поведение |
| O5 | нет | согласие sortsupport с cmp не сравнивается |
| O6 | косв. | `tuplesort.sql` исполняет abbreviation и abort; согласие с cmp не утверждается |
| O7 | нет | `opr_sanity.sql` перечисляет opclass'ы без `btequalimage` (там есть interval — только как факт каталога); `check_btree.sql` сверяет флаг метастраницы; сам закон — нет |
| O8, O8b | косв. | `window.sql:570–690` — примеры in_range, переполнение, бесконечности; монотонность как закон — нет |
| O9 | косв. | `btree_index.sql` — skip scan; границы/successor/overflow не утверждаются |
| O10, O11 | нет | `opr_sanity.sql` проверяет полноту cross-type операторов, не законы |
| O12, O13 | нет | |
| S1–S3 | косв. | итоги запросов в regress (`btree_index.sql`, `create_index.sql`: SAOP, skip, порядок) |
| S4 | косв. | обратные сканы в `btree_index.sql`, scroll-курсоры в `portals.sql` |
| S5 | косв. | merge join в `join.sql`; согласованность метки при конкуренции — нет |
| S6 | **нет** | допустимая неопределённость при конкуренции не проверяется |
| S7, S9, S11, S13 | косв. | index-only, bitmap, `select_parallel.sql`, предупреждения resowner |
| S8, S12 | нет | |
| S10 | прямо, частично | `modules/index/specs/killtuples.spec` — сам пишет, что «not sufficient» |
| S14 | прямо | `modules/nbtree/specs/backwards-scan-concurrent-splits.spec` + injection points `nbtree-walk-left*` |
| V1–V4 | **нет** | interlock pin / dropPin / LSN-гейт для kill не покрыт ни одним тестом (курсор + VACUUM на btree — не нашёл) |
| V5 | нет | `index-only-bitmapscan.spec` — про снятую bitmap-оптимизацию, не про btree IOS |
| V6 | косв. | `nbtree_half_dead_pages.sql`, многоуровневое удаление в `btree_index.sql`; горизонт safexid — нет |
| V7 | косв. | любой VACUUM |
| V8 | нет | amcheck `t/005_pitr.pl` — структура после PITR, не сканы на standby |
| U1, U3 | прямо | `constraints.sql`, `create_index.sql` (DEFERRABLE, NULLS NOT DISTINCT) |
| U2 | прямо | isolation `insert-conflict-*`, `read-write-unique*` |
| U4 | нет | |
| U5 | прямо | amcheck `checkunique` (`check_btree.sql`, `t/004`) |
| T1–T15 | прямо | amcheck `check_btree.sql` — но на небольших индексах регресса |
| T13 | прямо | + `modules/nbtree/sql/nbtree_half_dead_pages.sql` |
| T16 | прямо | `modules/nbtree/sql/nbtree_incomplete_splits.sql` (injection points) |

Итог по 67 контрактам: прямо — 22, косвенно — 16, **нет — 29**.

Без теста в ванили остаются целиком: импликации флагов (A), законы opclass
как поведение (O, кроме примеров), интервал допустимой неопределённости (S6)
и interlock VACUUM/TID (V1–V4) — последний включает ослабленное правило
nbtree из R2.  Из них O1–O9 теперь исполняемы прототипом `opclass_laws`.
