# ROLE-MODEL: законы opclass как вид закона + таблица ролей

Вопрос D1: можно ли один и тот же закон плюс таблицу смысловых ролей
превратить в проверки разных opclass без AM-специфичного кода проверки.

## Из чего собирается проверка

    semantic law        вид закона K1–K6 и его экземпляр (что должно выполняться)
  + role binding        какая функция или оператор играет роль (таблица ролей)
  + call protocol       как её вызвать, если SQL-вызова недостаточно (адаптер)
  + value source        значения нужных типов (G: выборка, касты, генераторы)
  = generated check

Так устроена реализация (`d1laws/`): закон и движок не знают ни AM, ни
номеров; таблица ролей не знает соглашений о вызове; адаптер не знает
смысла оператора; источник значений не знает закона.

## Роли

Роль — смысл функции или оператора, а не номер.  Роль имеет форму
(что возвращает) и протокол вызова.

| роль | форма | что значит |
|---|---|---|
| comparator | cmp: `(a,b) → int`, знак | трёхзначное сравнение |
| equality | rel: `(a,b) → bool` | отношение эквивалентности |
| ordering_operator(r) | rel | оператор отношения `r ∈ {lt, le, eq, ge, gt}` |
| alternate_comparator | cmp | другая реализация того же сравнения |
| approximate_comparator | cmp с «не знаю» | приближение сравнения, 0 = не знаю |
| image_equivalence | guard: `() → bool` | утверждение opclass «равные по cmp — равны по образу» |
| range_predicate | `(val, base, offset, sub, less) → bool` | «val в пределах offset от base» |
| successor | `a → a'`, границы домена | следующий/предыдущий элемент порядка |
| hash | value: `a → int4` | хеш |
| extended_hash | value: `(a, seed) → int8` | хеш с солью |
| consistent | approx rel: `(entry, q) → (bool, recheck)` | «может ли запись удовлетворять q» |
| entry_transform | `a → entry` | как значение превращается в запись индекса |
| reference_predicate(s) | rel | оператор стратегии `s`, эталонное отношение |
| query_context | arity: `q → {nkeys, keys, extra_data, null_categories}` | контекст запроса; закон использует только `nkeys` (длина вектора присутствия), остальное протокол переносит непрозрачно |
| tri_consistent | approx: `(p ∈ {F,T,M}^n, q) → (answer, unknown)` | троичная проверка по вектору присутствия ключей |
| search_strategy | strategy | номера поисковых стратегий семейства (без смысла) |

Протокол вызова: `plain` — обычная SQL-вызываемая функция или оператор;
иначе — имя адаптера для функций с `internal`-сигнатурой
(`sortsupport`, `abbrev`, `skipsupport`, `entry_consistent`,
`key_vector`, `key_vector_tri`, `key_vector_bool`).  Адаптер знает соглашение о вызове (например,
`GISTENTRY`), но не знает AM.

Протокол может нести непрозрачный контекст.  `key_vector` получает от
`query_context` четыре части, закону отдаёт `nkeys`, а `keys`,
`extra_data`, `null_categories` передаёт в `consistent`/`triConsistent`
без интерпретации.  Общий движок `extra_data` не видит.

## Таблица ролей

Строка: AM, семейство (пусто = любое семейство этого AM), роль, откуда
(`proc` N / `op` стратегия S / `op` любая стратегия поиска), протокол,
атрибут роли (например, `r` у ordering_operator).  Номера живут только
здесь.  Для btree и hash таблица задаётся на уровне AM (номера
фиксированы), для GiST — на уровне семейства (смысл стратегий задаёт
opclass).

## Экземпляр закона

    law        идентификатор (O1…, H1…, G1…)
    kind       K1…K6
    roles      какие роли в каких местах
    direction  для одностороннего закона: какой ответ доверенный
    relation   ожидаемое отношение (same_sign, equal, implies, low32_equal, …)
    operands   типы операндов (из opclass; другой тип — вход G)
    collation  из выборки
    strategy   для закона над reference_predicate: какие стратегии

## Виды законов

| вид | форма | роли |
|---|---|---|
| K1 | свойство отношения: reflexive, antisymmetric (cmp) / symmetric (rel), transitive | comparator или equality |
| K2 | две реализации согласованы: `relation(A(x), B(x))` | comparator × ordering_operator(r): знак ↔ r; comparator × alternate_comparator: same_sign; hash × extended_hash(seed 0): low32_equal |
| K3 | приближение: если ответ **доверенный**, он совпадает с эталоном | approximate_comparator × comparator, доверенный = ненулевой; consistent∘entry_transform × reference_predicate(s), доверенный = `false` или `recheck = false`; tri_consistent(вектор) × consistent(каждое доопределение), доверенный = не MAYBE |
| K4 | конгруэнтность: посылка ⇒ совпадение значений | comparator = 0 ⇒ образы равны (при guard image_equivalence); equality ⇒ hash равен |
| K5 | монотонность предиката по заданному порядку | range_predicate × comparator |
| K6 | перечисление: successor — ближайший больший, границы, overflow | successor × comparator |

K3 записывается одинаково для двух разных механизмов:

    approx(x, y)  → (answer, trusted)
    trusted       ⇒ answer ≍ reference(x, y)

Для abbreviated key `answer` — знак, `trusted = answer ≠ 0`, `≍` —
совпадение знака.  Для GiST consistent `answer` — bool,
`trusted = ¬answer ∨ ¬recheck`, `≍` — равенство.  Обе стороны —
«преобразовать значения, затем бинарный предикат».  Для GIN
triConsistent вход — вектор присутствия ключей `p ∈ {F,T,M}^n`, эталон —
булевый consistent на каждом доопределении `p`.

Эталон тоже может быть приближённым (consistent с recheck).  Тогда он
отвечает «не знаю», и такой ответ доверенный ответ не подтверждает:

    trusted ⇒ answer IS NOT DISTINCT FROM reference

Для точных эталонов (comparator, оператор) это то же самое, что `=`.

Источник значений для K3: пары из выборки (abbrev, GiST) или все векторы
F/T/M длины `nkeys` вместе с их доопределениями (GIN; `nkeys` даёт роль
query_context, длина не больше 4).  Проверяются **все** доопределения:
ответ, верный только для первого (все M → F), — отказ закона
(контроль `tri_first_completion`).

## Отсутствующая роль

Если роли нет в каталоге для этого семейства и типа, закон — `n/a`, не
FAIL.  Если guard (image_equivalence) говорит «нет», закон K4 для
образа — `n/a` с тем, что показывает выборка.
