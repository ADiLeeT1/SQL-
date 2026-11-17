-- =====================================================================
--  НАГРУЗОЧНЫЕ ДАННЫЕ ДЛЯ ЧАСТИ 5 (EXPLAIN ANALYZE)
--  Файл: perf_data.sql
--  Запускать в ОТДЕЛЬНОЙ базе:
--     createdb food_perf
--     psql -d food_perf -f schema.sql -f triggers.sql -f perf_data.sql
--
--  На 26 заказах из data.sql индексы бесполезны: PostgreSQL быстрее
--  прочитает всю маленькую таблицу. Поэтому для замеров генерируем
--  объём, похожий на реальный сервис:
--    200 ресторанов, 6 000 блюд, 50 000 клиентов, 500 курьеров,
--    300 000 заказов за год, ~750 000 позиций, ~1,7 млн записей истории,
--    ~110 000 отзывов.
--  Генерация занимает 15–40 секунд.
-- =====================================================================

-- Отключаем триггеры и проверки FK на время массовой загрузки
-- (иначе 300 000 заказов проходили бы через все проверки — долго).
-- Требуются права суперпользователя.
SET session_replication_role = replica;

-- setseed — фиксируем «случайность», чтобы при каждом запуске
-- получались одинаковые данные
DO $$ BEGIN PERFORM setseed(0.42); END $$;

-- Рестораны
INSERT INTO restaurants (name, address, is_open, created_at)
SELECT 'Ресторан ' || i,
       'Алматы, ул. Тестовая, ' || i,
       random() > 0.1,                        -- ~90 % открыты
       now() - interval '2 years'
FROM generate_series(1, 200) AS i;

-- Блюда: по 30 на ресторан, dish_id = (restaurant_id − 1) * 30 + k
INSERT INTO dishes (restaurant_id, name, price, weight_grams, category)
SELECT r, 'Блюдо ' || k,
       (500 + floor(random() * 40) * 100)::DECIMAL(10, 2),   -- 500–4400 ₸
       100 + floor(random() * 400)::INTEGER,
       (ARRAY['salad', 'soup', 'hot', 'dessert', 'drink']::dish_category[])[1 + k % 5]
FROM generate_series(1, 200) AS r,
     generate_series(1, 30)  AS k
ORDER BY r, k;

-- Клиенты и по одному адресу (address_id = client_id)
INSERT INTO clients (full_name, phone, email, created_at)
SELECT 'Клиент ' || i,
       '+7700' || lpad(i::TEXT, 7, '0'),
       'user' || i || '@test.kz',
       now() - interval '2 years'
FROM generate_series(1, 50000) AS i;

INSERT INTO client_addresses (client_id, street)
SELECT i, 'ул. Клиентская, ' || i
FROM generate_series(1, 50000) AS i;

-- Курьеры + их статистика (триггеры выключены — создаём вручную)
INSERT INTO couriers (full_name, phone, transport, is_on_shift)
SELECT 'Курьер ' || i,
       '+7705' || lpad(i::TEXT, 7, '0'),
       (ARRAY['walk', 'bicycle', 'motorcycle', 'car']::transport_type[])[1 + i % 4],
       random() < 0.3
FROM generate_series(1, 500) AS i;

INSERT INTO courier_stats (courier_id)
SELECT courier_id FROM couriers;

-- Заказы за последний год: ~92 % доставлены, ~8 % отменены
INSERT INTO orders (client_id, restaurant_id, address_id, courier_id, status, created_at, updated_at)
SELECT c, r, c,
       CASE WHEN s = 'cancelled' THEN NULL ELSE 1 + floor(random() * 500)::INTEGER END,
       s,
       t, t
FROM (
    SELECT 1 + floor(random() * 50000)::INTEGER AS c,
           1 + floor(random() * 200)::INTEGER   AS r,
           CASE WHEN random() < 0.08 THEN 'cancelled' ELSE 'delivered' END::order_status AS s,
           now() - random() * interval '365 days' AS t
    FROM generate_series(1, 300000)
) AS g;

-- Позиции: 1–4 разных блюда того же ресторана
INSERT INTO order_items (order_id, dish_id, quantity, price_at_order)
SELECT o.order_id, d.dish_id, 1 + floor(random() * 3)::INTEGER, d.price
FROM orders o
CROSS JOIN LATERAL generate_series(1, 1 + (o.order_id % 4)) AS k
JOIN dishes d
  ON d.dish_id = (o.restaurant_id - 1) * 30 + ((o.order_id + k * 7) % 30) + 1;

-- Суммы заказов
UPDATE orders o
SET subtotal = s.total,
    total_amount = s.total
FROM (SELECT order_id, SUM(price_at_order * quantity) AS total
      FROM order_items GROUP BY order_id) s
WHERE s.order_id = o.order_id;

-- История статусов: у доставленных 6 этапов, у отменённых 2
INSERT INTO order_status_history (order_id, status, changed_at)
SELECT o.order_id, st.status,
       o.created_at + st.minutes * interval '1 minute' * (0.7 + random() * 0.6)
FROM orders o
JOIN (VALUES ('created'::order_status, 0), ('accepted', 3), ('cooking', 7),
             ('ready', 25), ('delivering', 30), ('delivered', 55)) AS st(status, minutes)
  ON o.status = 'delivered'
UNION ALL
SELECT o.order_id, st.status, o.created_at + st.minutes * interval '1 minute'
FROM orders o
JOIN (VALUES ('created'::order_status, 0), ('cancelled', 5)) AS st(status, minutes)
  ON o.status = 'cancelled';

-- Время доставки в orders.updated_at
UPDATE orders o
SET updated_at = h.changed_at
FROM order_status_history h
WHERE h.order_id = o.order_id AND h.status = 'delivered';

-- Отзывы: ~40 % доставленных заказов, через 1–24 часа после доставки
INSERT INTO reviews (order_id, restaurant_rating, courier_rating, created_at)
SELECT o.order_id,
       1 + floor(random() * 5)::INTEGER,
       CASE WHEN random() < 0.7 THEN 1 + floor(random() * 5)::INTEGER END,
       LEAST(o.updated_at + random() * interval '24 hours', now())
FROM orders o
WHERE o.status = 'delivered'
  AND random() < 0.4;

-- Рейтинги ресторанов
UPDATE restaurants r
SET rating = s.avg_rating
FROM (SELECT o.restaurant_id, ROUND(AVG(rv.restaurant_rating), 1) AS avg_rating
      FROM reviews rv JOIN orders o ON o.order_id = rv.order_id
      GROUP BY o.restaurant_id) s
WHERE s.restaurant_id = r.restaurant_id;

-- Включаем триггеры обратно
SET session_replication_role = DEFAULT;

-- Обновляем статистику планировщика (сколько строк, какие значения)
VACUUM ANALYZE;
