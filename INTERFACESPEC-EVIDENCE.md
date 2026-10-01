# InterfaceSpec: что потребовалось на самом деле

Не пересказ тестов.  Только то, без чего D0 и D1 не работали, и на
каких AM это получено.  Подробности: D0-RESULT.md, D1-RESULT.md,
D1-GIN-RESULT.md, ROLE-MODEL.md.

## D0: existing metadata + reference result

    существующие метаданные (IndexAmRoutine, amproperty, pg_amop/pg_amproc)
  + эталон (тот же запрос через seqscan)
  = проверка

Один генератор `d0gen` без имён AM; 12 контрактов (A1, A2, A4, A6, A7,
A9, A10, S1-ext, S2, S3, S9-ext, S13).

| AM | pass | FAIL | граница |
|---|---|---|---|
| btree | 92 | 0 | — |
| hash | 15 | 0 | — |
| GiST | 111 | 0 | BOUNDARY 1 (G: значения другого типа), METADATA 1 (R6) |

Больше ничего не понадобилось: ни таблиц ролей, ни адаптеров.

## D1: semantic law + role binding + call protocol + value source

| часть | что это | где живёт |
|---|---|---|
| semantic law | вид K1–K6 и отношение | движок `d1laws--0.1.sql` |
| role binding | какая support-функция/стратегия играет роль | данные (`role_tables.sql`, теперь `interfacespec-v0.yaml`) |
| call protocol | соглашение о вызове `internal`-функций; непрозрачный контекст | адаптеры `d1laws.c` |
| value source | sample, cast, generated, completions | движок по виду закона |

Каждая часть понадобилась хотя бы одному AM:

| AM | законы | что потребовало |
|---|---|---|
| btree | O1–O9 | binding на уровне AM; протоколы sortsupport, abbrev, skipsupport; value source cast (K5), generated (K6) |
| hash | H1–H6 | binding на уровне AM; generated (seed) |
| GiST poly_ops | G1 | binding на уровне opfamily (смысл стратегий у opclass); протокол entry_consistent; operator как эталон |
| GIN tsvector_ops | N1 | протокол key_vector с непрозрачным контекстом; value source completions; эталон «не знаю» |

Для btree итог D1 совпал с отдельным btree-проверяльщиком `opclass_laws`
закон за законом (5 opclass/collation, 11 контрольных отказов).

## K3 отдельно

Три независимых механизма — один закон:

    approx(x, q)  → (answer, unknown)
    trusted        = не unknown
    trusted ⇒ answer IS NOT DISTINCT FROM reference

| механизм | unknown | эталон |
|---|---|---|
| btree abbreviated key | сравнение = 0 | comparator (true/false) |
| GiST consistent | true + recheck | оператор стратегии (true/false) |
| GIN triConsistent | GIN_MAYBE | consistent на каждом доопределении: false / true / **unknown** (true + recheck) |

Определённый ответ должен подтверждаться эталоном.  Эталон бывает true,
false или unknown; unknown ничего не подтверждает.  Для точных эталонов
это совпадает с `=`.

Контроли, которые ловит только эта форма: `tri_exact_claim` (ловится
только эталоном unknown); `tri_first_completion` (ловится только при
проверке всех доопределений; проверка одного первого даёт неверный итог
pass).

## InterfaceSpec v0 как данные

`interfacespec-v0.yaml` — сущности, каждую из которых потребовал
эксперимент:

| сущность | кто потребовал |
|---|---|
| interface, capability | D0 (флаги и callback'и IndexAmRoutine, эталон seqscan) |
| role (name, shape) | D1, все четыре AM |
| binding (scope am/opfamily; source support_proc/strategy/operator; number/selector; protocol) | btree/hash (am), GiST (opfamily), GiST/GIN (operator) |
| protocol (input, output, opaque) | btree (sortsupport, abbrev, skipsupport), GiST (entry_consistent), GIN (key_vector) |
| value_source (sample, cast, generated, completions) | K5 (cast), K6/hash (generated), GIN (completions) |
| law (kind, roles, relation, trusted, guard, reference) | K1–K6 |

Обратное направление (`interfacespec/check_v0.sh`):

    interfacespec-v0.yaml → load_v0.py → d1_role/d1_law → d1laws (без изменений) → expected

| проверка | итог |
|---|---|
| сгенерированные строки против `role_tables.sql`, нормализованно (сортировка, params как jsonb) | совпадают, 38 строк (21 binding, 17 законов) |
| формы ролей и имена протоколов против словаря движка (`d1_role_vocab`, `d1_protocol`) | совпадают |
| неизменённый `d1_laws.sql` на сгенерированных строках против неизменённого `expected/d1_laws.out` | совпадает (402 строки; исключены 57 строк — эхо текста `role_tables.sql`, их точность проверяется отдельно) |

Красные пробы (мутация YAML): O6 trusted → false_or_exact; GIN consistent
4 → 6; H6 seed 0 → 1; N1 без completions; удалён G1 — каждая даёт
расхождение и в таблицах, и в выводе теста.

Знание о d1 в загрузчике: только кодировка params (отношение K1 →
`property`, K2 → `relation`, K4 `image_equal` → `consequence: image`;
completions → `source: ternary_completions`).  D0-часть YAML (capability)
не загружается: d0gen читает её из IndexAmRoutine во время работы.

## Границы v0

Не выражается в v0 и не входит в следующий коммит:

| граница | почему вне v0 |
|---|---|
| concurrency / histories | закону нужна модель конкуренции (вход K), не значения |
| callback lifecycle (ambeginscan → amrescan → amgettuple → amendscan, markpos) | порядок вызовов, состояние скана; D2 (callback proxy) |
| internal page state | инварианты страницы и дерева; не видны через SQL и роли |
| WAL / recovery | нужен прогон redo и сравнение с исходным состоянием |
| standby | то же плюс hot standby feedback / конфликты |
| value generation с domain knowledge | interval-смещения для date (BOUNDARY), anyelement range, префиксы tsquery |
| протоколы с полным Relation/page context | v0 подставляет фальшивую leaf-страницу и `rel = NULL` (entry_consistent); consistent на внутренних страницах, picksplit, penalty, union требуют настоящего индекса |
