-- =====================================================================
--  СЕРВИС ДОСТАВКИ ЕДЫ — ЗАПРОСЫ (Часть 4)
--  Файл: queries.sql   (запускать после data.sql)
--
--  «Активный заказ» во всех запросах = статус НЕ 'delivered' и НЕ 'cancelled'.
--  Отменённые заказы не учитываются в статистике продаж (запросы 4, 5).
-- =====================================================================


-- =====================================================================
--  ПРОСТЫЕ ЗАПРОСЫ
-- =====================================================================

-- ---------------------------------------------------------------------
-- Запрос 1. Все открытые рестораны, по рейтингу от высокого к низкому
-- ---------------------------------------------------------------------
SELECT
    restaurant_id,
    name,
    address,
    rating
FROM restaurants
WHERE is_open = TRUE
ORDER BY rating DESC,
         name;                 -- при равном рейтинге — по алфавиту


-- ---------------------------------------------------------------------
-- Запрос 2. Меню ресторана restaurant_id = 1, сгруппированное по категориям
-- ---------------------------------------------------------------------

-- 2а. Группировка: одна строка = одна категория
--     string_agg склеивает названия блюд категории в одну строку
SELECT
    category                                        AS категория,
    COUNT(*)                                        AS блюд,
    MIN(price)                                      AS цена_от,
    MAX(price)                                      AS цена_до,
    string_agg(name || ' — ' || price::INTEGER || ' ₸', '; ' ORDER BY price) AS блюда
FROM dishes
WHERE restaurant_id = 1
  AND is_available = TRUE        -- в меню показываем только доступные блюда
GROUP BY category
ORDER BY category;               -- порядок ENUM: салаты, супы, горячее, десерты, напитки

-- 2б. То же меню списком (как его видит клиент в приложении):
--     блюда идут подряд по категориям
SELECT
    category,
    name,
    description,
    price,
    weight_grams
FROM dishes
WHERE restaurant_id = 1
  AND is_available = TRUE
ORDER BY category, price;


-- ---------------------------------------------------------------------
-- Запрос 3. Активные заказы клиента client_id = 1 со статусом и суммой
-- ---------------------------------------------------------------------
SELECT
    o.order_id,
    r.name          AS restaurant,
    o.status,
    o.total_amount,
    o.created_at
FROM orders o
JOIN restaurants r ON r.restaurant_id = o.restaurant_id
WHERE o.client_id = 1
  AND o.status NOT IN ('delivered', 'cancelled')
ORDER BY o.created_at DESC;


-- =====================================================================
--  СРЕДНИЕ ЗАПРОСЫ
-- =====================================================================

-- ---------------------------------------------------------------------
-- Запрос 4. Топ-5 самых популярных блюд за последний месяц
--   Популярность = в скольких заказах встречалось блюдо.
--   При равенстве — по количеству проданных порций.
-- ---------------------------------------------------------------------
SELECT
    d.dish_id,
    d.name                       AS dish,
    r.name                       AS restaurant,
    COUNT(DISTINCT oi.order_id)  AS orders_count,   -- в скольких заказах
    SUM(oi.quantity)             AS portions_sold   -- сколько порций всего
FROM order_items oi
JOIN orders      o ON o.order_id      = oi.order_id
JOIN dishes      d ON d.dish_id       = oi.dish_id
JOIN restaurants r ON r.restaurant_id = d.restaurant_id
WHERE o.created_at >= now() - interval '1 month'
  AND o.status <> 'cancelled'
GROUP BY d.dish_id, d.name, r.name
ORDER BY orders_count DESC,
         portions_sold DESC
LIMIT 5;


-- ---------------------------------------------------------------------
-- Запрос 5. Средний чек по каждому ресторану (по убыванию)
--   Учитываем только доставленные заказы; чек = total_amount (со скидкой).
-- ---------------------------------------------------------------------
SELECT
    r.restaurant_id,
    r.name,
    COUNT(o.order_id)               AS delivered_orders,
    ROUND(AVG(o.total_amount), 2)   AS avg_check
FROM restaurants r
JOIN orders o ON o.restaurant_id = r.restaurant_id
WHERE o.status = 'delivered'
GROUP BY r.restaurant_id, r.name
ORDER BY avg_check DESC;


-- ---------------------------------------------------------------------
-- Запрос 6. Курьеры на смене без активного заказа (свободные)
--   NOT EXISTS: «не существует активного заказа этого курьера»
-- ---------------------------------------------------------------------
SELECT
    c.courier_id,
    c.full_name,
    c.phone,
    c.transport
FROM couriers c
WHERE c.is_on_shift = TRUE
  AND NOT EXISTS (
        SELECT 1
        FROM orders o
        WHERE o.courier_id = c.courier_id
          AND o.status NOT IN ('delivered', 'cancelled')
      )
ORDER BY c.courier_id;


-- =====================================================================
--  СЛОЖНЫЕ ЗАПРОСЫ
-- =====================================================================

-- ---------------------------------------------------------------------
-- Запрос 7. Среднее время доставки по ресторанам
--   Время доставки = момент статуса 'delivered' (из истории статусов)
--   минус момент создания заказа. Разность двух TIMESTAMP даёт INTERVAL.
--   EXTRACT(EPOCH FROM интервал) переводит его в секунды, /60 → минуты.
--
--   Как устроен запрос (так быстрее, см. optimization.md):
--   1) во вложенном запросе считаем среднее по restaurant_id —
--      одно AVG по интервалу на каждую строку;
--   2) к готовым 5 (или 200) строкам присоединяем названия ресторанов.
-- ---------------------------------------------------------------------
SELECT
    r.restaurant_id,
    r.name,
    s.delivered_orders,
    ROUND(EXTRACT(EPOCH FROM s.avg_time) / 60, 1)  AS avg_delivery_minutes,
    date_trunc('second', s.avg_time)               AS avg_delivery_time   -- чч:мм:сс
FROM (
    SELECT
        o.restaurant_id,
        COUNT(*)                         AS delivered_orders,
        AVG(h.changed_at - o.created_at) AS avg_time
    FROM orders o
    JOIN order_status_history h
           ON h.order_id = o.order_id
          AND h.status   = 'delivered'
    GROUP BY o.restaurant_id
) AS s
JOIN restaurants r ON r.restaurant_id = s.restaurant_id
ORDER BY avg_delivery_minutes;


-- ---------------------------------------------------------------------
-- Запрос 8. Клиенты, которые не заказывали более 30 дней, но заказывали раньше
--   JOIN оставляет только клиентов с заказами («делали раньше»),
--   HAVING отбирает тех, у кого последний заказ старше 30 дней.
-- ---------------------------------------------------------------------
SELECT
    c.client_id,
    c.full_name,
    c.phone,
    COUNT(o.order_id)                    AS total_orders,
    MAX(o.created_at)                    AS last_order_at,
    now()::DATE - MAX(o.created_at)::DATE AS days_since_last_order
FROM clients c
JOIN orders o ON o.client_id = c.client_id
GROUP BY c.client_id, c.full_name, c.phone
HAVING MAX(o.created_at) < now() - interval '30 days'
ORDER BY last_order_at;


-- ---------------------------------------------------------------------
-- Запрос 9. Рестораны, у которых рейтинг за текущий месяц ниже, чем за прошлый
--   Средние оценки считаются по отзывам, оставленным в этом месяце.
--   AVG(...) FILTER (WHERE ...) — среднее только по строкам, подходящим
--   под условие; так оба месяца считаются за один проход.
--   Если в одном из месяцев отзывов нет, AVG = NULL и сравнение
--   не выполняется → ресторан в результат не попадает (сравнивать не с чем).
-- ---------------------------------------------------------------------
WITH monthly AS (
    SELECT
        o.restaurant_id,
        AVG(rv.restaurant_rating) FILTER (
            WHERE rv.created_at >= date_trunc('month', now())
        ) AS current_month_avg,
        AVG(rv.restaurant_rating) FILTER (
            WHERE rv.created_at <  date_trunc('month', now())
        ) AS previous_month_avg
    FROM reviews rv
    JOIN orders o ON o.order_id = rv.order_id
    -- берём отзывы с начала прошлого месяца
    WHERE rv.created_at >= date_trunc('month', now()) - interval '1 month'
    GROUP BY o.restaurant_id
)
SELECT
    r.restaurant_id,
    r.name,
    ROUND(m.previous_month_avg, 2)                          AS previous_month,
    ROUND(m.current_month_avg, 2)                           AS current_month,
    ROUND(m.current_month_avg - m.previous_month_avg, 2)    AS change
FROM monthly m
JOIN restaurants r ON r.restaurant_id = m.restaurant_id
WHERE m.current_month_avg < m.previous_month_avg
ORDER BY change;            -- сначала те, у кого рейтинг упал сильнее
