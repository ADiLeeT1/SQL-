-- =====================================================================
--  СЕРВИС ДОСТАВКИ ЕДЫ — ТЕСТОВЫЕ ДАННЫЕ
--  Файл: data.sql   (запускать после schema.sql и triggers.sql)
--
--  Объём: 6 ресторанов (1 закрыт), 38 блюд, 10 клиентов, 14 адресов,
--         6 курьеров, 3 промокода, 26 заказов (64 позиции), 17 отзывов.
--
--  Все даты считаются от now() (текущего момента), поэтому запросы
--  «за последний месяц», «более 30 дней» работают в любой день запуска.
--
--  Заказы проходят через настоящие триггеры: создаём в статусе
--  'created', добавляем блюда, затем шаг за шагом двигаем статусы.
-- =====================================================================

-- Очищаем таблицы и сбрасываем счётчики SERIAL, чтобы id шли с 1
-- Всё в одной транзакции: если где-то ошибка — не загрузится ничего
BEGIN;

TRUNCATE restaurants, clients, couriers, promo_codes RESTART IDENTITY CASCADE;


-- ---------------------------------------------------------------------
--  РЕСТОРАНЫ
-- ---------------------------------------------------------------------
INSERT INTO restaurants (name, address, is_open, created_at) VALUES
    ('Дастархан',     'Алматы, ул. Абая, 52',              TRUE,  now() - interval '200 days'),  -- 1
    ('Пицца Миа',     'Алматы, пр. Достык, 105',           TRUE,  now() - interval '180 days'),  -- 2
    ('Суши Сан',      'Алматы, ул. Жандосова, 58',         TRUE,  now() - interval '150 days'),  -- 3
    ('Burger House',  'Алматы, ул. Толе би, 101',          TRUE,  now() - interval '120 days'),  -- 4
    ('Coffee & Cake', 'Алматы, пр. Аль-Фараби, 77/8',      TRUE,  now() - interval '100 days'),  -- 5
    ('Вок Экспресс',  'Алматы, ул. Сатпаева, 30',          FALSE, now() - interval '20 days');   -- 6 (временно закрыт)


-- ---------------------------------------------------------------------
--  ВРЕМЯ РАБОТЫ  (1 = пн ... 7 = вс)
--  generate_series(1, 7) выдаёт числа 1..7 — по строке на каждый день
-- ---------------------------------------------------------------------
INSERT INTO restaurant_hours (restaurant_id, day_of_week, open_time, close_time)
-- ::TIME — приведение текста к типу TIME (в UNION тип берётся из первого SELECT)
SELECT 1, d, '10:00'::TIME, '23:00'::TIME FROM generate_series(1, 7) AS d  -- ежедневно 10–23
UNION ALL
SELECT 2, d, '11:00', '23:00' FROM generate_series(1, 7) AS d          -- ежедневно 11–23
UNION ALL
SELECT 3, d, '12:00', '02:00' FROM generate_series(1, 7) AS d          -- 12–02 (после полуночи)
UNION ALL
SELECT 4, d, '10:00', '22:00' FROM generate_series(1, 5) AS d          -- пн–пт 10–22
UNION ALL
SELECT 4, d, '11:00', '00:00' FROM generate_series(6, 7) AS d          -- сб–вс 11–00
UNION ALL
SELECT 5, d, '08:00', '20:00' FROM generate_series(1, 6) AS d          -- пн–сб, вс выходной
UNION ALL
SELECT 6, d, '11:00', '21:00' FROM generate_series(1, 5) AS d;         -- пн–пт


-- ---------------------------------------------------------------------
--  БЛЮДА  (цены в тенге)
-- ---------------------------------------------------------------------
INSERT INTO dishes (restaurant_id, name, description, price, weight_grams, category, is_available) VALUES
    -- Дастархан (id 1–7)
    (1, 'Салат «Ачичук»',        'Помидоры, лук, перец',               900, 250, 'salad',   TRUE),   -- 1
    (1, 'Шорпа',                 'Бульон из баранины с овощами',      1800, 400, 'soup',    TRUE),   -- 2
    (1, 'Лагман',                'Тянутая лапша с говядиной',         2500, 450, 'hot',     TRUE),   -- 3
    (1, 'Бешбармак',             'Конина, тесто, лук',                3500, 500, 'hot',     TRUE),   -- 4
    (1, 'Манты (5 шт.)',         'Говядина с тыквой',                 2200, 350, 'hot',     TRUE),   -- 5
    (1, 'Баурсаки с мёдом',      NULL,                                 900, 200, 'dessert', TRUE),   -- 6
    (1, 'Чай с молоком',         'Чайник 0,5 л',                       500, 500, 'drink',   TRUE),   -- 7
    -- Пицца Миа (id 8–14)
    (2, 'Цезарь с курицей',      NULL,                                2400, 250, 'salad',   TRUE),   -- 8
    (2, 'Томатный суп',          'С базиликом',                       1700, 300, 'soup',    TRUE),   -- 9
    (2, 'Пицца Маргарита',       '30 см',                             3200, 550, 'hot',     TRUE),   -- 10
    (2, 'Пицца Пепперони',       '30 см',                             3600, 580, 'hot',     TRUE),   -- 11
    (2, 'Паста Карбонара',       NULL,                                2900, 350, 'hot',     TRUE),   -- 12
    (2, 'Тирамису',              NULL,                                1900, 150, 'dessert', TRUE),   -- 13
    (2, 'Домашний лимонад',      '0,4 л',                             1100, 400, 'drink',   TRUE),   -- 14
    -- Суши Сан (id 15–21)
    (3, 'Салат чука',            'Водоросли, кунжут',                 1500, 150, 'salad',   TRUE),   -- 15
    (3, 'Мисо-суп',              NULL,                                1200, 300, 'soup',    TRUE),   -- 16
    (3, 'Рамен с курицей',       NULL,                                2900, 500, 'soup',    TRUE),   -- 17
    (3, 'Запечённый ролл с лососем', '8 шт.',                         3200, 260, 'hot',     TRUE),   -- 18
    (3, 'Вок с курицей',         'Лапша удон, овощи',                 2600, 350, 'hot',     TRUE),   -- 19
    (3, 'Моти',                  '3 шт.',                             1300, 120, 'dessert', TRUE),   -- 20
    (3, 'Зелёный чай',           'Чайник 0,4 л',                       700, 400, 'drink',   TRUE),   -- 21
    -- Burger House (id 22–28)
    (4, 'Коулслоу',              NULL,                                 900, 200, 'salad',   TRUE),   -- 22
    (4, 'Грибной крем-суп',      NULL,                                1600, 300, 'soup',    TRUE),   -- 23
    (4, 'Чизбургер',             NULL,                                2300, 300, 'hot',     TRUE),   -- 24
    (4, 'Двойной бургер',        NULL,                                3300, 420, 'hot',     TRUE),   -- 25
    (4, 'Картофель фри',         NULL,                                 900, 150, 'hot',     TRUE),   -- 26
    (4, 'Чизкейк',               NULL,                                1700, 140, 'dessert', TRUE),   -- 27
    (4, 'Кола 0,5',              NULL,                                 600, 500, 'drink',   TRUE),   -- 28
    -- Coffee & Cake (id 29–36)
    (5, 'Салат с киноа',         NULL,                                2100, 220, 'salad',   TRUE),   -- 29
    (5, 'Тыквенный суп-пюре',    NULL,                                1500, 300, 'soup',    TRUE),   -- 30
    (5, 'Сэндвич с индейкой',    NULL,                                2000, 250, 'hot',     TRUE),   -- 31
    (5, 'Сырники',               'Со сметаной',                       1800, 230, 'hot',     TRUE),   -- 32
    (5, 'Медовик',               NULL,                                1500, 150, 'dessert', TRUE),   -- 33
    (5, 'Наполеон',              NULL,                                1600, 160, 'dessert', FALSE),  -- 34 (недоступен)
    (5, 'Капучино',              '0,3 л',                             1100, 300, 'drink',   TRUE),   -- 35
    (5, 'Латте',                 '0,35 л',                            1200, 350, 'drink',   TRUE),   -- 36
    -- Вок Экспресс (id 37–38), ресторан закрыт
    (6, 'Удон с говядиной',      NULL,                                2700, 380, 'hot',     TRUE),   -- 37
    (6, 'Том ям',                NULL,                                3100, 400, 'soup',    TRUE);   -- 38


-- ---------------------------------------------------------------------
--  КЛИЕНТЫ И АДРЕСА
-- ---------------------------------------------------------------------
INSERT INTO clients (full_name, phone, email, created_at) VALUES
    ('Айгерим Садыкова',   '+77011112201', 'aigerim.s@mail.kz',     now() - interval '120 days'),  -- 1
    ('Данияр Ахметов',     '+77011112202', 'daniyar.a@gmail.com',   now() - interval '110 days'),  -- 2
    ('Мария Ким',          '+77011112203', 'maria.kim@mail.ru',     now() - interval '100 days'),  -- 3
    ('Ерлан Жумабаев',     '+77011112204', 'erlan.zh@gmail.com',    now() - interval '90 days'),   -- 4
    ('Алина Петрова',      '+77011112205', 'alina.p@yandex.kz',     now() - interval '85 days'),   -- 5
    ('Нурлан Оспанов',     '+77011112206', 'nurlan.o@gmail.com',    now() - interval '80 days'),   -- 6
    ('Сауле Бекова',       '+77011112207', 'saule.b@mail.kz',       now() - interval '75 days'),   -- 7
    ('Тимур Исаев',        '+77011112208', 'timur.i@gmail.com',     now() - interval '70 days'),   -- 8
    ('Дана Мухамедова',    '+77011112209', 'dana.m@mail.ru',        now() - interval '30 days'),   -- 9
    ('Арман Серикбаев',    '+77011112210', 'arman.s@gmail.com',     now() - interval '20 days');   -- 10

INSERT INTO client_addresses (client_id, label, street, apartment, comment) VALUES
    (1,  'Дом',    'мкр. Самал-2, д. 58',          '14',  NULL),                         -- 1
    (1,  'Работа', 'пр. Аль-Фараби, 17',           '305', 'БЦ «Нурлы Тау», блок 4Б'),    -- 2
    (2,  'Дом',    'ул. Розыбакиева, 247',         '87',  NULL),                         -- 3
    (2,  'Работа', 'ул. Фурманова, 50',            NULL,  NULL),                         -- 4
    (3,  'Дом',    'мкр. Орбита-1, д. 12',         '45',  'Домофон не работает, позвонить'), -- 5
    (4,  'Дом',    'ул. Сейфуллина, 410',          '3',   NULL),                         -- 6
    (5,  'Дом',    'ул. Тимирязева, 42',           '101', NULL),                         -- 7
    (6,  'Дом',    'мкр. Аксай-4, д. 9',           '22',  NULL),                         -- 8
    (6,  'Мама',   'ул. Жарокова, 189',            '7',   NULL),                         -- 9
    (7,  'Дом',    'ул. Байзакова, 280',           '56',  NULL),                         -- 10
    (8,  'Дом',    'мкр. Мамыр-1, д. 29',          '8',   NULL),                         -- 11
    (9,  'Дом',    'ул. Навои, 208',               '134', NULL),                         -- 12
    (10, 'Дом',    'мкр. Жетысу-3, д. 61',         '19',  NULL),                         -- 13
    (10, 'Работа', 'ул. Кунаева, 77',              NULL,  'Офис на 2 этаже');            -- 14


-- ---------------------------------------------------------------------
--  КУРЬЕРЫ  (строка в courier_stats создаётся триггером автоматически)
-- ---------------------------------------------------------------------
INSERT INTO couriers (full_name, phone, transport, is_on_shift, created_at) VALUES
    ('Асхат Нуров',        '+77075550101', 'car',        TRUE,  now() - interval '150 days'),  -- 1
    ('Бекзат Алиев',       '+77075550102', 'motorcycle', TRUE,  now() - interval '140 days'),  -- 2
    ('Виктор Ли',          '+77075550103', 'bicycle',    TRUE,  now() - interval '130 days'),  -- 3
    ('Гульнара Темирова',  '+77075550104', 'car',        TRUE,  now() - interval '100 days'),  -- 4
    ('Дмитрий Орлов',      '+77075550105', 'walk',       FALSE, now() - interval '90 days'),   -- 5 (не на смене)
    ('Ербол Касымов',      '+77075550106', 'bicycle',    TRUE,  now() - interval '5 days');    -- 6 (новичок)


-- ---------------------------------------------------------------------
--  ПРОМОКОДЫ (бонус)
-- ---------------------------------------------------------------------
INSERT INTO promo_codes (code, discount_percent, min_order_amount, valid_from, valid_until, max_uses, is_active) VALUES
    ('WELCOME10',  10,     0, now() - interval '90 days',  NULL,                      1000, TRUE),  -- 1
    ('BIGORDER20', 20, 10000, now() - interval '90 days',  now() + interval '30 days', NULL, TRUE),  -- 2
    ('SUMMER15',   15,  5000, now() - interval '200 days', now() - interval '100 days', NULL, FALSE); -- 3 (истёк)


-- ---------------------------------------------------------------------
--  ЗАКАЗЫ  (создаются в статусе 'created')
--  created_at задаём явно, чтобы заказы были «размазаны» по времени
-- ---------------------------------------------------------------------
INSERT INTO orders (client_id, restaurant_id, address_id, promo_id, comment, created_at) VALUES
    (1,  1, 1,  NULL, NULL,                    now() - interval '65 days'),     -- 1
    (7,  2, 10, NULL, NULL,                    now() - interval '60 days'),     -- 2
    (8,  3, 11, NULL, 'Без васаби',            now() - interval '55 days'),     -- 3
    (2,  1, 3,  NULL, NULL,                    now() - interval '50 days'),     -- 4
    (3,  4, 5,  NULL, NULL,                    now() - interval '45 days'),     -- 5
    (7,  1, 10, NULL, NULL,                    now() - interval '42 days'),     -- 6
    (8,  5, 11, NULL, NULL,                    now() - interval '40 days'),     -- 7
    (4,  2, 6,  1,    NULL,                    now() - interval '38 days'),     -- 8  (WELCOME10)
    (5,  3, 7,  NULL, NULL,                    now() - interval '36 days'),     -- 9
    (6,  4, 8,  NULL, NULL,                    now() - interval '35 days'),     -- 10 (будет отменён)
    (1,  2, 2,  NULL, 'Доставить к обеду',     now() - interval '25 days'),     -- 11
    (2,  3, 4,  NULL, NULL,                    now() - interval '20 days'),     -- 12
    (3,  1, 5,  NULL, NULL,                    now() - interval '15 days'),     -- 13
    (9,  4, 12, 2,    'Большой заказ на офис', now() - interval '12 days'),     -- 14 (BIGORDER20)
    (10, 5, 13, NULL, NULL,                    now() - interval '10 days'),     -- 15
    (4,  1, 6,  NULL, NULL,                    now() - interval '7 days'),      -- 16
    (5,  2, 7,  NULL, NULL,                    now() - interval '5 days'),      -- 17
    (6,  3, 9,  NULL, NULL,                    now() - interval '3 days'),      -- 18
    (1,  4, 1,  NULL, NULL,                    now() - interval '2 days'),      -- 19 (будет отменён)
    (2,  1, 3,  NULL, NULL,                    now() - interval '1 day'),       -- 20
    (9,  2, 12, NULL, NULL,                    now() - interval '45 minutes'),  -- 21 (в пути)
    (1,  5, 1,  NULL, NULL,                    now() - interval '50 minutes'),  -- 22 (готовится)
    (1,  1, 2,  NULL, 'Позвонить за 5 минут',  now() - interval '20 minutes'),  -- 23 (создан)
    (3,  2, 5,  NULL, NULL,                    now() - interval '40 minutes'),  -- 24 (готов)
    (10, 4, 14, NULL, NULL,                    now() - interval '10 minutes'),  -- 25 (принят)
    (5,  3, 7,  NULL, NULL,                    now() - interval '55 minutes');  -- 26 (в пути)


-- ---------------------------------------------------------------------
--  ПОЗИЦИИ ЗАКАЗОВ
--  price_at_order не указываем — его подставляет триггер (текущая цена блюда),
--  а сумму заказа пересчитывает триггер trg_recalc_order_total.
-- ---------------------------------------------------------------------
INSERT INTO order_items (order_id, dish_id, quantity) VALUES
    (1, 3, 2), (1, 7, 2), (1, 1, 1),
    (2, 10, 1), (2, 14, 2),
    (3, 18, 2), (3, 16, 1), (3, 21, 2),
    (4, 4, 1), (4, 6, 1), (4, 7, 1),
    (5, 24, 2), (5, 26, 2), (5, 28, 2),
    (6, 5, 2), (6, 2, 1),
    (7, 35, 2), (7, 33, 1),
    (8, 11, 1), (8, 12, 1), (8, 13, 2),
    (9, 17, 1), (9, 19, 1),
    (10, 25, 1), (10, 28, 1),
    (11, 10, 2), (11, 8, 1),
    (12, 18, 3), (12, 15, 1),
    (13, 3, 1), (13, 5, 1), (13, 7, 2),
    (14, 25, 3), (14, 24, 1), (14, 26, 3), (14, 27, 1), (14, 28, 3),
    (15, 31, 1), (15, 35, 1), (15, 36, 1),
    (16, 4, 2), (16, 6, 2),
    (17, 11, 1), (17, 14, 1),
    (18, 18, 1), (18, 20, 1), (18, 21, 1),
    (19, 24, 1),
    (20, 3, 2), (20, 1, 2),
    (21, 10, 1), (21, 13, 1),
    (22, 30, 2), (22, 35, 2),
    (23, 4, 1), (23, 7, 1), (23, 3, 1),
    (24, 12, 1), (24, 9, 1),
    (25, 25, 2), (25, 26, 1),
    (26, 19, 2), (26, 16, 2), (26, 18, 1);


-- ---------------------------------------------------------------------
--  ДВИЖЕНИЕ ПО СТАТУСАМ (каждый шаг проверяет триггер Варианта A)
--  Итог:  доставлены — 1–9, 11–18, 20;  отменены — 10, 19;
--         в пути — 21, 26;  готов — 24;  готовится — 22;
--         принят — 25;  создан — 23
-- ---------------------------------------------------------------------
UPDATE orders SET status = 'accepted'
WHERE order_id NOT IN (19, 23);

UPDATE orders SET status = 'cancelled'          -- 10: из 'accepted', 19: из 'created'
WHERE order_id IN (10, 19);

UPDATE orders SET status = 'cooking'
WHERE order_id NOT IN (10, 19, 23, 25);

UPDATE orders SET status = 'ready'
WHERE order_id NOT IN (10, 19, 22, 23, 25);

-- Назначаем курьеров заказам, которые готовы к отправке
UPDATE orders
SET courier_id = CASE
        WHEN order_id IN (1, 4, 11, 16, 21) THEN 1
        WHEN order_id IN (2, 7, 12, 17, 24) THEN 2
        WHEN order_id IN (3, 8, 13, 18, 26) THEN 3
        WHEN order_id IN (5, 9, 14, 20)     THEN 4
        WHEN order_id IN (6, 15)            THEN 5
    END
WHERE status = 'ready';

UPDATE orders SET status = 'delivering'
WHERE status = 'ready' AND order_id <> 24;

UPDATE orders SET status = 'delivered'
WHERE status = 'delivering' AND order_id NOT IN (21, 26);

-- Чаевые после доставки (статистика курьера обновится триггером)
UPDATE orders
SET tip_amount = CASE order_id
        WHEN 1  THEN 300
        WHEN 3  THEN 500
        WHEN 6  THEN 200
        WHEN 12 THEN 400
        WHEN 16 THEN 300
        WHEN 20 THEN 500
    END
WHERE order_id IN (1, 3, 6, 12, 16, 20);


-- ---------------------------------------------------------------------
--  КОРРЕКТИРОВКА ДАТ
--  Триггер записал время смены статусов = «сейчас» (все UPDATE выше
--  выполнились за доли секунды). Для правдоподобной истории сдвигаем
--  время этапов относительно created_at заказа:
--    принят +2..5 мин, готовится +6..9, готов +20..29,
--    в пути +25..34, доставлен +40..69, отменён +4..8
-- ---------------------------------------------------------------------
UPDATE order_status_history h
SET changed_at = o.created_at + CASE h.status
        WHEN 'created'    THEN interval '0 minutes'
        WHEN 'accepted'   THEN make_interval(mins => 2  + o.order_id % 4)
        WHEN 'cooking'    THEN make_interval(mins => 6  + o.order_id % 4)
        WHEN 'ready'      THEN make_interval(mins => 20 + o.order_id % 10)
        WHEN 'delivering' THEN make_interval(mins => 25 + o.order_id % 10)
        WHEN 'delivered'  THEN make_interval(mins => 40 + (o.order_id * 7) % 30)
        WHEN 'cancelled'  THEN make_interval(mins => 4  + o.order_id % 5)
    END
FROM orders o
WHERE o.order_id = h.order_id;

-- updated_at заказа = время последнего этапа
UPDATE orders o
SET updated_at = (SELECT MAX(changed_at) FROM order_status_history h WHERE h.order_id = o.order_id);

-- Время последней доставки курьера
UPDATE courier_stats cs
SET last_delivery_at = (
        SELECT MAX(h.changed_at)
        FROM orders o
        JOIN order_status_history h ON h.order_id = o.order_id AND h.status = 'delivered'
        WHERE o.courier_id = cs.courier_id
    );


-- ---------------------------------------------------------------------
--  ОТЗЫВЫ  (только на доставленные заказы — проверяет триггер)
--  Рейтинги ресторанов и курьеров пересчитает триггер trg_update_ratings.
--  Отзывы на старые заказы датируем ПРОШЛЫМ месяцем,
--  на свежие — текущим моментом (текущий месяц). Это нужно для запроса №9.
-- ---------------------------------------------------------------------
INSERT INTO reviews (order_id, restaurant_rating, courier_rating, comment, created_at) VALUES
    -- прошлый месяц
    (1, 5, 5,    'Лагман как у бабушки!',      date_trunc('month', now()) - interval '3 days'),
    (4, 5, 4,    NULL,                         date_trunc('month', now()) - interval '3 days'),
    (6, 4, NULL, 'Манты немного остыли',       date_trunc('month', now()) - interval '3 days'),
    (2, 4, 5,    NULL,                         date_trunc('month', now()) - interval '3 days'),
    (8, 5, 4,    'Отличная пепперони',         date_trunc('month', now()) - interval '3 days'),
    (3, 5, 5,    NULL,                         date_trunc('month', now()) - interval '3 days'),
    (9, 4, 4,    NULL,                         date_trunc('month', now()) - interval '3 days'),
    (5, 3, 3,    'Картошка пришла холодной',   date_trunc('month', now()) - interval '3 days'),
    (7, 5, NULL, NULL,                         date_trunc('month', now()) - interval '3 days'),
    -- текущий месяц
    (13, 3, 4,   'Лагман пересолен',           now()),
    (16, 4, 5,   NULL,                         now()),
    (20, 3, 5,   'Долго готовили',             now()),
    (11, 5, 5,   NULL,                         now()),
    (17, 5, 4,   NULL,                         now()),
    (12, 3, 3,   'Роллы развалились',          now()),
    (18, 4, 5,   NULL,                         now()),
    (14, 5, 5,   'Всё горячее, спасибо!',      now());


-- ---------------------------------------------------------------------
--  ИСТОРИЯ ЦЕН (бонус): Лагман подорожал после всех заказов.
--  В старых заказах осталась цена 2500 (price_at_order),
--  а в меню теперь 2700.
-- ---------------------------------------------------------------------
UPDATE dishes SET price = 2700 WHERE dish_id = 3;

COMMIT;
