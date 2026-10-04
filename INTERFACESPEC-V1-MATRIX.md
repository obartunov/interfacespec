# InterfaceSpec v1: откуда взялась каждая сущность

`+` — понадобилась и исполнена; `·` — используется как есть из предыдущего
шага; `—` — не нужна.  Обоснования — INTERFACESPEC-V1-REVIEW.md.

| entity | D0 | D1 | D2 | S6 | S5 | V5 | semantic / harness | keep in v1? |
|---|---|---|---|---|---|---|---|---|
| interface | + | · | · | · | · | · | semantic | да |
| capability | + (флаги, callback'и) | · | + (`requires`) | · | + (n/a hash/GiST) | · | semantic | да |
| claim (D1 guard `image_equivalence`) | — | + (O7) | — | — | — | — | semantic | да, слить с capability (n/a) |
| role | — | + | — | — | — | — | semantic | да |
| binding | — | + (am / opfamily) | вырожден (имя поля) | — | — | — | semantic | да |
| invocation (D1 «protocol») | — | + | — | — | — | — | semantic | да, переименовать |
| law | + (эталон D0) | + (K1–K6) | + (`expect`) | + (outcomes) | · | + (видимость) | semantic | да |
| allowed outcomes | — | + (K3 trusted / unknown) | — | + (must/may/must_not, gap) | · (+ DOMAIN исхода) | — (точное равенство) | semantic | да, как форма law; общность — открытый вопрос |
| obligation | — | — | + | · | · | — | semantic | да |
| D2 guard | — | — | + (S8) | — | — | — | semantic | нет как сущность: часть obligation |
| domain | — | — | + | · | + (исход) | — | semantic | да |
| state | — | — | + | · | + (gap) | — | semantic | да |
| operation | — | — | + | · | · | — | semantic | да |
| effect | — | — | + | · | · | — | semantic | да |
| observable | + (строки SQL) | — | + (TID, данные) | · | · | + (строки исполнителя) | semantic | да |
| lifetime | — | — | + (S7, R8) | — | — | — | semantic | да, атрибут observable |
| observation boundary | неявно (SQL) | неявно (функция) | неявно (callback) | неявно | неявно | + (исполнитель) | semantic | да, атрибут observable / actor |
| actor | — | — | два скана одной сессии (S7) | + (B) | · | + (A2) | semantic | да |
| reference (нормативный) | + | + (роль-эталон, «не знаю») | + | + (множество при начале A) | · | + (видимое снимку) | semantic | да |
| oracle | + (seqscan) | — (эталон — роль) | + (forward pass) | + (свежий скан индекса) | · | + (seqscan под снимком A2) | harness | да, отдельно от reference |
| value source | + (колонка) | + (sample, cast, generated, completions) | — | — | — | — | harness; completions — квантор закона | да, в harness |
| generation profile | — | — | + | + | + (`order`) | + (`epilogue`) | harness | да |
| identity | — | — | — (TID) | BOUNDARY по TID | · | логический `id` в данных | harness / атрибут observable | нет как сущность |
| operation state (completed / blocked) | — | — | — | + (планирование) | · | · | harness (Q6) | нет; пересмотреть для U2 |
| coverage requirement | `empty` | — | строка покрытия (YAML `on`) | + (4 класса) | + (18 классов) | + (eligible) | harness | да, рядом с generation profile |
| evidence | — | — | — | + | + | + (pin, wait) | harness | да, вне вердикта |
| controls / red probes | + (M1–M7) | + | + (P1–P6) | + (Q1–Q6) | + (Q1–Q6) | + (P1, P2) | harness (метапроверка) | да |
| verdict vocabulary | pass, empty, n/a, BOUNDARY, METADATA, UNRESOLVED | n/a, BOUNDARY | refused, outside domain | BOUNDARY | DOMAIN, n/a | none, NOT tested, known violation | — | да, единый словарь (REVIEW §10) |
| transition, sequence constraint | — | — | не понадобились | — | — | — | — | нет |
| resource | — | — | S11 не исполнен | — | — | — | — | отложено |
| page, buffer, pin, LSN | — | — | — | evidence | evidence | evidence | refinement | нет |
