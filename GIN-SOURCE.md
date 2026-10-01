# GIN: что нужно для одного закона (triConsistent)

Источник: master `ad36e3608c8`.  Только то, что нужно закону
«доверенный ответ triConsistent совпадает со всеми доопределениями».

## Контракт (gin.sgml, раздел про support-функции)

- `triConsistent(check[], n, query, nkeys, extra_data[], queryKeys[],
  nullFlags[]) → GIN_FALSE | GIN_TRUE | GIN_MAYBE`.  `GIN_MAYBE` во входе:
  присутствие ключа неизвестно.  Вернуть `GIN_TRUE` — только если запись
  совпадает при любом присутствии MAYBE-ключей; `GIN_FALSE` — только если
  не совпадает при любом; если ответ зависит от MAYBE — обязан вернуть
  `GIN_MAYBE`.  Без MAYBE во входе `GIN_MAYBE` в ответе равен recheck
  булевой функции.
- Документация требует только надёжности: `GIN_MAYBE` разрешён всегда.
  Точности (определённый ответ, когда все доопределения согласны) не
  требует.
- `consistent(check[], n, query, nkeys, extra_data[], &recheck,
  queryKeys[], nullFlags[]) → bool`: `false` — точно нет; `true` без
  recheck — точно да; `true` с recheck — может быть.

Исполняемая форма того же закона есть в ядре: `shimTriConsistentFn`
(ginlogic.c:148) строит triConsistent из consistent перебором
доопределений (не более 4 MAYBE): TRUE — если все доопределения true без
recheck, FALSE — если все false, иначе MAYBE.

## Что передаёт ядро (ginlogic.c:65–105, ginscan.c:158–230)

| | что | для закона |
|---|---|---|
| `extractQuery` | ключи запроса, `nkeys`, `extra_data`, `nullFlags`, `pmatch`, `searchMode` | нужен: `nkeys` задаёт длину check[], остальное передаётся дальше как есть |
| `check[]` | `GinTernaryValue[nkeys]`; для булевого consistent — тот же массив со значениями 0/1 | генерируется |
| `nkeys` | `nuserentries` = число ключей из extractQuery; скрытая запись режима поиска в consistent **не** передаётся | — |
| `searchMode` | DEFAULT / INCLUDE_EMPTY / ALL; ALL при запросе без обязательных положительных совпадений (например `!a`) | не влияет на check[]; не нужен |
| `queryKeys[]`, `nullFlags[]` | ключи; вместо nullFlags ядро передаёт `queryCategories` | передаются как есть |
| `extra_data[]` | у tsvector_ops — карта «номер элемента запроса → номер ключа» | передаётся как есть, без интерпретации |
| `recheck` | ядро ставит `true` до вызова consistent («безопасное допущение», ginlogic.c:69–71) | повторить |
| `extractValue`, `compare`, `comparePartial`, `pmatch` | ключи записи, порядок ключей, частичное совпадение | **не нужны** этому закону |

Закон не касается записей индекса: в нём участвуют только запрос и
вектор присутствия ключей.

Отсюда роль `query_context` (ROLE-MODEL.md):

    query_context(q) -> { nkeys, keys, extra_data, null_categories }

Закон использует только `nkeys`.  `keys`, `extra_data`,
`null_categories` — непрозрачный контекст: протокол `key_vector`
передаёт их в `consistent`/`triConsistent` как есть.  Спецификации
достаточно знать, что такой контекст существует и должен быть передан;
его содержание (у tsvector_ops — карта операндов) ей не нужно.

## Выбранный opclass: tsvector_ops (@@, @@@)

- `extractQuery` = `gin_extract_tsquery`: по ключу на каждый операнд tsquery;
  `extra_data` — карта операндов; внешнего состояния нет.
- `consistent` = `gin_tsquery_consistent`, `triConsistent` =
  `gin_tsquery_triconsistent`: оба вызывают `TS_execute_ternary` на
  check[] (tsginidx.c:216–310).  Вес у операнда или фразовый оператор
  превращают TRUE в MAYBE (`checkcondition_gin`, `TS_EXEC_PHRASE_NO_POS`).
- Значения: литералы tsquery (`a & !b`, `a <-> b`, `a:A`).
- Без префиксных операндов (`a:*`): им нужен comparePartial, закону — нет.

`array_ops` не подходит этому движку: вход `anyarray`, выборку массивов
нельзя передать как массив значений (массив массивов становится
двумерным).

## Закон в терминах K3

    approx(p, q)       = triConsistent(p)            p ∈ {F, T, M}^nkeys
    trusted            = ответ ≠ MAYBE
    reference(c, q)    = consistent(c), c — доопределение p:
                         false → F, true без recheck → T, true с recheck → «не знаю»
    trusted ⇒ ответ = reference(c)   для каждого доопределения c

Доверенный ответ должен быть подтверждён точным эталоном; эталон «не
знаю» доверенный ответ не подтверждает.
