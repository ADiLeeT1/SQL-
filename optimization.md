# Отчёт по оптимизации (Часть 5)

## 1. Как проводились замеры

| Параметр | Значение |
|---|---|
| СУБД | PostgreSQL 16.15, настройки по умолчанию (shared_buffers = 128MB, work_mem = 4MB, до 2 параллельных процессов) |
| Машина | 2 vCPU, Linux |
| Данные | `perf_data.sql`: 200 ресторанов, 6 000 блюд, 50 000 клиентов, 500 курьеров, **300 000 заказов** за год, 750 000 позиций, **1 704 256** записей истории статусов, **110 266** отзывов |
| «ДО» | удалены все индексы `idx_*` из `schema.sql` (индексы первичных ключей и UNIQUE остаются — они часть таблиц) |
| «ПОСЛЕ» | созданы все индексы из `schema.sql`, выполнен `VACUUM ANALYZE` |
| Время | 1 прогрев + 11 запусков `EXPLAIN (ANALYZE, BUFFERS)`, в отчёте — **медиана** (разброс между запусками на этой машине ±15–20 %) |

Почему не на `data.sql`: в нём 26 заказов. Такая таблица занимает одну страницу диска, и PostgreSQL прочитает её целиком быстрее, чем пойдёт в индекс, — планировщик индекс даже не выберет. Чтобы увидеть эффект, нужен реалистичный объём.

Как повторить:

```bash
createdb food_perf
psql -d food_perf -f schema.sql -f triggers.sql -f perf_data.sql
# «ДО»: удалить индексы idx_* (DROP INDEX ...), затем ANALYZE
# EXPLAIN (ANALYZE, BUFFERS) <запрос>;
# «ПОСЛЕ»: создать индексы из schema.sql, ANALYZE, повторить EXPLAIN
```

Как читать план:
- `Seq Scan` — чтение всей таблицы подряд;
- `Index Only Scan` — все нужные данные берутся прямо из индекса, таблица не читается (`Heap Fetches: 0`);
- `Hash Join` — соединение через хеш-таблицу в памяти;
- `Buffers: shared hit=N` — сколько страниц по 8 КБ прочитано (`hit` — из кэша, `read` — с диска);
- `rows=100000 loops=3` — у параллельных узлов строки указаны на один процесс, всего = rows × loops.

Для анализа выбраны два самых сложных запроса: **№7** (соединение с историей статусов из 1,7 млн строк и агрегация) и **№9** (CTE, условная агрегация `FILTER`, три таблицы).

---

## 2. Запрос №7: Среднее время доставки по ресторанам

### ДО ОПТИМИЗАЦИИ

```
Sort  (cost=33636.45..33636.95 rows=200 width=80) (actual time=208.116..210.383 rows=200 loops=1)
  Sort Key: (round((EXTRACT(epoch FROM (avg((h.changed_at - o.created_at)))) / '60'::numeric), 1))
  Sort Method: quicksort  Memory: 41kB
  Buffers: shared hit=11663 read=7783
  ->  Hash Join  (cost=33572.10..33628.80 rows=200 width=80) (actual time=207.564..210.284 rows=200 loops=1)
        Hash Cond: (o.restaurant_id = r.restaurant_id)
        Buffers: shared hit=11660 read=7783
        ->  Finalize GroupAggregate  (cost=33561.60..33613.77 rows=200 width=28) (actual time=207.472..210.079 rows=200 loops=1)
              Group Key: o.restaurant_id
              Buffers: shared hit=11654 read=7783
              ->  Gather Merge  (cost=33561.60..33608.27 rows=400 width=44) (actual time=207.455..209.849 rows=600 loops=1)
                    Workers Planned: 2
                    Workers Launched: 2
                    Buffers: shared hit=11654 read=7783
                    ->  Sort  (cost=32561.57..32562.07 rows=200 width=44) (actual time=200.067..200.085 rows=200 loops=3)
                          Sort Key: o.restaurant_id
                          Sort Method: quicksort  Memory: 43kB
                          Buffers: shared hit=11654 read=7783
                          Worker 0:  Sort Method: quicksort  Memory: 43kB
                          Worker 1:  Sort Method: quicksort  Memory: 43kB
                          ->  Partial HashAggregate  (cost=32551.93..32553.93 rows=200 width=44) (actual time=199.981..200.003 rows=200 loops=3)
                                Group Key: o.restaurant_id
                                Batches: 1  Memory Usage: 64kB
                                Buffers: shared hit=11640 read=7783
                                Worker 0:  Batches: 1  Memory Usage: 64kB
                                Worker 1:  Batches: 1  Memory Usage: 64kB
                                ->  Parallel Hash Join  (cost=19578.48..31360.61 rows=119132 width=20) (actual time=87.787..165.129 rows=92021 loops=3)
                                      Hash Cond: (o.order_id = h.order_id)
                                      Buffers: shared hit=11640 read=7783
                                      ->  Parallel Seq Scan on orders o  (cost=0.00..11454.00 rows=125000 width=16) (actual time=3.702..17.559 rows=100000 loops=3)
                                            Buffers: shared hit=9714 read=490
                                      ->  Parallel Hash  (cost=18089.33..18089.33 rows=119132 width=12) (actual time=82.248..82.249 rows=92021 loops=3)
                                            Buckets: 524288  Batches: 1  Memory Usage: 17088kB
                                            Buffers: shared hit=1920 read=7293
                                            ->  Parallel Seq Scan on order_status_history h  (cost=0.00..18089.33 rows=119132 width=12) (actual time=0.023..50.124 rows=92021 loops=3)
                                                  Filter: (status = 'delivered'::order_status)
                                                  Rows Removed by Filter: 476064
                                                  Buffers: shared hit=1920 read=7293
        ->  Hash  (cost=8.00..8.00 rows=200 width=24) (actual time=0.068..0.070 rows=200 loops=1)
              Buckets: 1024  Batches: 1  Memory Usage: 20kB
              Buffers: shared hit=6
              ->  Seq Scan on restaurants r  (cost=0.00..8.00 rows=200 width=24) (actual time=0.012..0.036 rows=200 loops=1)
                    Buffers: shared hit=6
Planning:
  Buffers: shared hit=197
Planning Time: 0.762 ms
Execution Time: 210.553 ms
```

**Время выполнения: 210,6 ms**

**Проблема:** два `Parallel Seq Scan`:
- `order_status_history` читается целиком (1,7 млн строк), из которых нужны только 276 тыс. со статусом `delivered`: `Rows Removed by Filter` ≈ 476 тыс. на каждый из 3 процессов;
- `orders` читается целиком (300 тыс. строк со всеми колонками), хотя нужны только 3 колонки.

Всего прочитано **19 446** страниц (≈ 152 МБ).

### СОЗДАННЫЕ ИНДЕКСЫ

```sql
-- Частичный покрывающий индекс: только строки 'delivered' (1/6 таблицы),
-- changed_at лежит прямо в индексе → таблицу истории читать не нужно
CREATE INDEX idx_status_history_delivered
    ON order_status_history (order_id) INCLUDE (changed_at)
    WHERE status = 'delivered';

-- Покрывающий индекс по ресторану: в нём есть всё, что запросу нужно из orders
CREATE INDEX idx_orders_restaurant
    ON orders (restaurant_id) INCLUDE (order_id, created_at);
```

Кроме индексов, запрос переписан (окончательный вариант — в `queries.sql`):
- сначала группируем по `restaurant_id`, и только потом присоединяем 200 названий ресторанов (раньше к названиям присоединялись все 276 тыс. строк);
- одно `AVG` по интервалу вместо двух средних (раньше для каждой строки ещё отдельно считалось `EXTRACT(EPOCH ...)` в типе NUMERIC — это медленно).

### ПОСЛЕ ОПТИМИЗАЦИИ

```
Sort  (cost=18198.01..18198.51 rows=200 width=80) (actual time=192.032..193.534 rows=200 loops=1)
  Sort Key: (round((EXTRACT(epoch FROM (avg((h.changed_at - o.created_at)))) / '60'::numeric), 1))
  Sort Method: quicksort  Memory: 41kB
  Buffers: shared hit=2248
  ->  Hash Join  (cost=18133.66..18190.37 rows=200 width=80) (actual time=191.698..193.439 rows=200 loops=1)
        Hash Cond: (o.restaurant_id = r.restaurant_id)
        Buffers: shared hit=2245
        ->  Finalize GroupAggregate  (cost=18123.16..18175.33 rows=200 width=28) (actual time=191.550..193.215 rows=200 loops=1)
              Group Key: o.restaurant_id
              Buffers: shared hit=2239
              ->  Gather Merge  (cost=18123.16..18169.83 rows=400 width=44) (actual time=191.537..193.083 rows=417 loops=1)
                    Workers Planned: 2
                    Workers Launched: 2
                    Buffers: shared hit=2239
                    ->  Sort  (cost=17123.14..17123.64 rows=200 width=44) (actual time=183.671..183.683 rows=139 loops=3)
                          Sort Key: o.restaurant_id
                          Sort Method: quicksort  Memory: 35kB
                          Buffers: shared hit=2239
                          Worker 0:  Sort Method: quicksort  Memory: 41kB
                          Worker 1:  Sort Method: quicksort  Memory: 37kB
                          ->  Partial HashAggregate  (cost=17113.49..17115.49 rows=200 width=44) (actual time=183.581..183.617 rows=139 loops=3)
                                Group Key: o.restaurant_id
                                Batches: 1  Memory Usage: 64kB
                                Buffers: shared hit=2225
                                Worker 0:  Batches: 1  Memory Usage: 64kB
                                Worker 1:  Batches: 1  Memory Usage: 64kB
                                ->  Parallel Hash Join  (cost=8246.85..15956.97 rows=115652 width=20) (actual time=64.177..147.229 rows=92021 loops=3)
                                      Hash Cond: (o.order_id = h.order_id)
                                      Buffers: shared hit=2225
                                      ->  Parallel Index Only Scan using idx_orders_restaurant on orders o  (cost=0.42..7382.42 rows=125000 width=16) (actual time=0.050..16.123 rows=100000 loops=3)
                                            Heap Fetches: 0
                                            Buffers: shared hit=1156
                                      ->  Parallel Hash  (cost=6800.78..6800.78 rows=115652 width=12) (actual time=61.337..61.338 rows=92021 loops=3)
                                            Buckets: 524288  Batches: 1  Memory Usage: 17120kB
                                            Buffers: shared hit=1063
                                            ->  Parallel Index Only Scan using idx_status_history_delivered on order_status_history h  (cost=0.42..6800.78 rows=115652 width=12) (actual time=0.027..16.918 rows=92021 loops=3)
                                                  Heap Fetches: 0
                                                  Buffers: shared hit=1063
        ->  Hash  (cost=8.00..8.00 rows=200 width=24) (actual time=0.120..0.121 rows=200 loops=1)
              Buckets: 1024  Batches: 1  Memory Usage: 20kB
              Buffers: shared hit=6
              ->  Seq Scan on restaurants r  (cost=0.00..8.00 rows=200 width=24) (actual time=0.017..0.062 rows=200 loops=1)
                    Buffers: shared hit=6
Planning:
  Buffers: shared hit=307
Planning Time: 1.639 ms
Execution Time: 193.767 ms
```

**Время выполнения: 193,8 ms**

### Сравнение

| | ДО | ПОСЛЕ | Изменение |
|---|---|---|---|
| Чтение `order_status_history` | Seq Scan, 1,7 млн строк | Index Only Scan, 276 тыс. строк | в 6 раз меньше строк |
| Чтение `orders` | Seq Scan (вся таблица) | Index Only Scan (3 колонки) | — |
| Прочитано страниц | 19 446 | 2 248 | **в 8,7 раз меньше** |
| Время, только индексы (новый запрос) | 210,6 ms | 193,8 ms | **в 1,1 раза** |
| Время, старый текст запроса без индексов → новый с индексами | 282,5 ms | 193,8 ms | **в 1,5 раза** |

**Вывод (честно):** индексы сработали — планировщик перешёл на `Index Only Scan`, объём читаемых данных упал почти в 9 раз. Но **время почти не изменилось** (разница на уровне разброса замеров). Причина: запрос считает среднее по **всем** 276 тыс. доставленных заказов за всю историю. Индекс ускоряет *поиск* нужных строк, а здесь нужны все строки — основное время уходит на Hash Join и агрегацию 276 тыс. строк (≈ 165 из 194 мс по плану «после»), а не на чтение. Ощутимый выигрыш дал не индекс, а переписанный запрос (в 1,34 раза).

Что реально ускорит этот запрос в 5–10 раз (не делалось, чтобы не менять схему):
1. ограничить период — «за последние 30 дней» (аналитика обычно так и строится), тогда сработает индекс по `created_at`;
2. хранить готовое время доставки в `orders` (колонка `delivered_at`, заполняется тем же триггером статусов) — уйдёт соединение с историей из 1,7 млн строк. Это денормализация: быстрее чтение ценой дублирования данных.

---

## 3. Запрос №9: Рестораны, у которых рейтинг за текущий месяц ниже, чем за прошлый

### ДО ОПТИМИЗАЦИИ

```
Sort  (cost=16086.90..16087.07 rows=67 width=120) (actual time=94.113..97.363 rows=82 loops=1)
  Sort Key: (round((m.current_month_avg - m.previous_month_avg), 2))
  Sort Method: quicksort  Memory: 30kB
  Buffers: shared hit=12342
  ->  Hash Join  (cost=16075.66..16084.87 rows=67 width=120) (actual time=93.996..97.312 rows=82 loops=1)
        Hash Cond: (r.restaurant_id = m.restaurant_id)
        Buffers: shared hit=12339
        ->  Seq Scan on restaurants r  (cost=0.00..8.00 rows=200 width=24) (actual time=0.014..0.032 rows=200 loops=1)
              Buffers: shared hit=6
        ->  Hash  (cost=16074.82..16074.82 rows=67 width=68) (actual time=93.964..97.208 rows=82 loops=1)
              Buckets: 1024  Batches: 1  Memory Usage: 13kB
              Buffers: shared hit=12333
              ->  Subquery Scan on m  (cost=16020.98..16074.82 rows=67 width=68) (actual time=93.670..97.184 rows=82 loops=1)
                    Buffers: shared hit=12333
                    ->  Finalize GroupAggregate  (cost=16020.98..16074.15 rows=67 width=68) (actual time=93.668..97.176 rows=82 loops=1)
                          Group Key: o.restaurant_id
                          Filter: (avg(rv.restaurant_rating) FILTER (WHERE (rv.created_at >= date_trunc('month'::text, now()))) < avg(rv.restaurant_rating) FILTER (WHERE (rv.created_at < date_trunc('month'::text, now()))))
                          Rows Removed by Filter: 118
                          Buffers: shared hit=12333
                          ->  Gather Merge  (cost=16020.98..16067.65 rows=400 width=68) (actual time=93.644..96.963 rows=600 loops=1)
                                Workers Planned: 2
                                Workers Launched: 2
                                Buffers: shared hit=12333
                                ->  Sort  (cost=15020.96..15021.46 rows=200 width=68) (actual time=89.353..89.364 rows=200 loops=3)
                                      Sort Key: o.restaurant_id
                                      Sort Method: quicksort  Memory: 45kB
                                      Buffers: shared hit=12333
                                      Worker 0:  Sort Method: quicksort  Memory: 45kB
                                      Worker 1:  Sort Method: quicksort  Memory: 45kB
                                      ->  Partial HashAggregate  (cost=15011.32..15013.32 rows=200 width=68) (actual time=89.250..89.278 rows=200 loops=3)
                                            Group Key: o.restaurant_id
                                            Batches: 1  Memory Usage: 96kB
                                            Buffers: shared hit=12319
                                            Worker 0:  Batches: 1  Memory Usage: 96kB
                                            Worker 1:  Batches: 1  Memory Usage: 96kB
                                            ->  Hash Join  (cost=3091.67..14873.80 rows=6112 width=14) (actual time=51.441..86.923 rows=4839 loops=3)
                                                  Hash Cond: (o.order_id = rv.order_id)
                                                  Buffers: shared hit=12319
                                                  ->  Parallel Seq Scan on orders o  (cost=0.00..11454.00 rows=125000 width=8) (actual time=2.165..14.277 rows=100000 loops=3)
                                                        Buffers: shared hit=10204
                                                  ->  Hash  (cost=2908.32..2908.32 rows=14668 width=14) (actual time=48.579..48.580 rows=14518 loops=3)
                                                        Buckets: 16384  Batches: 1  Memory Usage: 866kB
                                                        Buffers: shared hit=2109
                                                        ->  Seq Scan on reviews rv  (cost=0.00..2908.32 rows=14668 width=14) (actual time=0.028..46.221 rows=14518 loops=3)
                                                              Filter: (created_at >= (date_trunc('month'::text, now()) - '1 mon'::interval))
                                                              Rows Removed by Filter: 95748
                                                              Buffers: shared hit=2109
Planning:
  Buffers: shared hit=196
Planning Time: 0.860 ms
Execution Time: 97.578 ms
```

**Время выполнения: 97,6 ms**

**Проблема:**
- `Seq Scan on reviews` — читаются все 110 тыс. отзывов, чтобы найти 14,5 тыс. за последние 2 месяца (`Rows Removed by Filter` ≈ 95 тыс. на процесс; этот шаг занимает ≈ 46 мс);
- `Parallel Seq Scan on orders` — вся таблица заказов читается ради двух колонок (`order_id`, `restaurant_id`).

### СОЗДАННЫЕ ИНДЕКСЫ

```sql
-- Диапазон по дате + нужные колонки в INCLUDE → Index Only Scan
CREATE INDEX idx_reviews_created_at
    ON reviews (created_at) INCLUDE (order_id, restaurant_rating);

-- Тот же покрывающий индекс, что и для №7: order_id + restaurant_id без чтения таблицы
CREATE INDEX idx_orders_restaurant
    ON orders (restaurant_id) INCLUDE (order_id, created_at);
```

### ПОСЛЕ ОПТИМИЗАЦИИ

```
Sort  (cost=9571.11..9571.27 rows=67 width=120) (actual time=51.241..51.392 rows=82 loops=1)
  Sort Key: (round((m.current_month_avg - m.previous_month_avg), 2))
  Sort Method: quicksort  Memory: 30kB
  Buffers: shared hit=1375
  ->  Hash Join  (cost=9559.87..9569.07 rows=67 width=120) (actual time=51.125..51.349 rows=82 loops=1)
        Hash Cond: (r.restaurant_id = m.restaurant_id)
        Buffers: shared hit=1372
        ->  Seq Scan on restaurants r  (cost=0.00..8.00 rows=200 width=24) (actual time=0.014..0.039 rows=200 loops=1)
              Buffers: shared hit=6
        ->  Hash  (cost=9559.03..9559.03 rows=67 width=68) (actual time=51.093..51.240 rows=82 loops=1)
              Buckets: 1024  Batches: 1  Memory Usage: 13kB
              Buffers: shared hit=1366
              ->  Subquery Scan on m  (cost=9505.19..9559.03 rows=67 width=68) (actual time=50.872..51.214 rows=82 loops=1)
                    Buffers: shared hit=1366
                    ->  Finalize GroupAggregate  (cost=9505.19..9558.36 rows=67 width=68) (actual time=50.871..51.205 rows=82 loops=1)
                          Group Key: o.restaurant_id
                          Filter: (avg(rv.restaurant_rating) FILTER (WHERE (rv.created_at >= date_trunc('month'::text, now()))) < avg(rv.restaurant_rating) FILTER (WHERE (rv.created_at < date_trunc('month'::text, now()))))
                          Rows Removed by Filter: 118
                          Buffers: shared hit=1366
                          ->  Gather Merge  (cost=9505.19..9551.86 rows=400 width=68) (actual time=50.846..51.044 rows=380 loops=1)
                                Workers Planned: 2
                                Workers Launched: 2
                                Buffers: shared hit=1366
                                ->  Sort  (cost=8505.17..8505.67 rows=200 width=68) (actual time=44.135..44.145 rows=127 loops=3)
                                      Sort Key: o.restaurant_id
                                      Sort Method: quicksort  Memory: 36kB
                                      Buffers: shared hit=1366
                                      Worker 0:  Sort Method: quicksort  Memory: 38kB
                                      Worker 1:  Sort Method: quicksort  Memory: 38kB
                                      ->  Partial HashAggregate  (cost=8495.52..8497.52 rows=200 width=68) (actual time=44.068..44.094 rows=127 loops=3)
                                            Group Key: o.restaurant_id
                                            Batches: 1  Memory Usage: 64kB
                                            Buffers: shared hit=1352
                                            Worker 0:  Batches: 1  Memory Usage: 64kB
                                            Worker 1:  Batches: 1  Memory Usage: 64kB
                                            ->  Hash Join  (cost=651.93..8362.05 rows=5932 width=14) (actual time=3.972..42.124 rows=4839 loops=3)
                                                  Hash Cond: (o.order_id = rv.order_id)
                                                  Buffers: shared hit=1352
                                                  ->  Parallel Index Only Scan using idx_orders_restaurant on orders o  (cost=0.42..7382.42 rows=125000 width=8) (actual time=0.020..18.302 rows=100000 loops=3)
                                                        Heap Fetches: 0
                                                        Buffers: shared hit=1155
                                                  ->  Hash  (cost=473.56..473.56 rows=14236 width=14) (actual time=3.857..3.859 rows=14518 loops=3)
                                                        Buckets: 16384  Batches: 1  Memory Usage: 866kB
                                                        Buffers: shared hit=191
                                                        ->  Index Only Scan using idx_reviews_created_at on reviews rv  (cost=0.42..473.56 rows=14236 width=14) (actual time=0.057..2.045 rows=14518 loops=3)
                                                              Index Cond: (created_at >= (date_trunc('month'::text, now()) - '1 mon'::interval))
                                                              Heap Fetches: 0
                                                              Buffers: shared hit=191
Planning:
  Buffers: shared hit=315
Planning Time: 1.235 ms
Execution Time: 51.616 ms
```

**Время выполнения: 51,6 ms**

### Сравнение

| | ДО | ПОСЛЕ | Изменение |
|---|---|---|---|
| Поиск отзывов за 2 месяца | Seq Scan, ≈ 46 мс | Index Only Scan по диапазону дат, ≈ 2 мс | ≈ в 20 раз |
| Чтение `orders` | Seq Scan | Index Only Scan | — |
| Прочитано страниц | 12 342 | 1 375 | **в 9,0 раз меньше** |
| Время выполнения | 97,6 ms | 51,6 ms | **в 1,9 раза быстрее** |

**Вывод:** здесь индекс работает так, как задумано: условие `created_at >= начало прошлого месяца` отбирает ≈ 13 % отзывов, и B-tree индекс сразу находит начало диапазона и читает только его. Оставшееся время — соединение с 300 тыс. заказов (`Hash Join`): PostgreSQL посчитал, что прочитать покрывающий индекс заказов целиком дешевле, чем делать 14,5 тыс. отдельных поисков по первичному ключу. Проверка с принудительным Nested Loop (`SET enable_hashjoin = off; SET enable_mergejoin = off;`) дала медиану ≈ 53 мс — практически то же самое, так что выбор планировщика оправдан.

---

## 4. Сводная таблица по всем замеренным запросам

| Запрос | Что делает | ДО, ms | ПОСЛЕ, ms | Ускорение | Индекс |
|---|---|---|---|---|---|
| №4 | Топ-5 блюд за месяц | 175,3 | 148,8 | ×1,2 | `idx_orders_created_at`, `idx_order_items_dish` |
| №6 | Свободные курьеры на смене | 28,4 | 0,2 | **×134** | `idx_orders_courier_active` (частичный) |
| №7 | Среднее время доставки | 210,6 | 193,8 | ×1,1 | `idx_status_history_delivered`, `idx_orders_restaurant` |
| №8 | Клиенты без заказов > 30 дней | 306,8 | 305,4 | ×1,0 | `idx_orders_client_created` |
| №9 | Рейтинг: этот месяц vs прошлый | 97,6 | 51,6 | **×1,9** | `idx_reviews_created_at`, `idx_orders_restaurant` |

- **№6 — самый яркий пример частичного индекса.** В индекс попадают только активные заказы с курьером (в нагрузочных данных их нет, в реальности — десятки), поэтому он занимает 8 КБ, а проверка «есть ли у курьера активный заказ» стала мгновенной вместо чтения 300 тыс. заказов.
- **№8 не ускоряется** по той же причине, что и №7: нужно найти последний заказ *каждого* из 50 тыс. клиентов, то есть прочитать все заказы. Индекс `idx_orders_client_created` пригодится для запроса №3 (заказы одного клиента), где нужен поиск, а не полный проход.
- **№4** ускорился умеренно: за месяц попадает ≈ 25 тыс. заказов из 300 тыс., и дальше основное время — соединение с 750 тыс. позиций.

## 5. Общие выводы

1. Индекс ускоряет **поиск небольшой части строк** (фильтр, диапазон, JOIN по ключу). Если запрос всё равно обрабатывает почти всю таблицу (средние «за всю историю»), индекс почти не помогает — это видно по №7 и №8.
2. **Частичный индекс** (`WHERE ...`) — лучший выбор, когда в запросах участвует небольшая и постоянно одна и та же часть таблицы (активные заказы, статус `delivered`).
3. **Покрывающий индекс** (`INCLUDE`) позволяет вообще не читать таблицу (`Index Only Scan`, `Heap Fetches: 0`) — объём чтения в №7 и №9 упал в 9 раз.
4. Индексы не бесплатны: 10 индексов на нагрузочной базе занимают ≈ 42 МБ и замедляют каждый INSERT/UPDATE. Поэтому индекс создаётся под конкретный запрос, а не «на все колонки».
5. Иногда переписать запрос полезнее, чем добавить индекс (№7: −25 % только за счёт порядка группировки и одного агрегата).
