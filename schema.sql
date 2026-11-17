-- =====================================================================
--  СЕРВИС ДОСТАВКИ ЕДЫ — СХЕМА БАЗЫ ДАННЫХ
--  Файл: schema.sql
--  СУБД: PostgreSQL 14+ (проверено на PostgreSQL 16)
--  Запуск: psql -d <имя_базы> -f schema.sql
--
--  Порядок файлов:
--    1) schema.sql   — типы, таблицы, индексы
--    2) triggers.sql — функции и триггеры
--    3) data.sql     — тестовые данные
--    4) queries.sql  — запросы
-- =====================================================================

-- Чтобы файл можно было запускать повторно, сначала удаляем старые объекты.
-- CASCADE удаляет и всё, что от них зависит (FK, триггеры, индексы).
DROP TABLE IF EXISTS reviews              CASCADE;
DROP TABLE IF EXISTS order_status_history CASCADE;
DROP TABLE IF EXISTS order_items          CASCADE;
DROP TABLE IF EXISTS orders               CASCADE;
DROP TABLE IF EXISTS promo_codes          CASCADE;
DROP TABLE IF EXISTS courier_stats        CASCADE;
DROP TABLE IF EXISTS couriers             CASCADE;
DROP TABLE IF EXISTS client_addresses     CASCADE;
DROP TABLE IF EXISTS clients              CASCADE;
DROP TABLE IF EXISTS dishes               CASCADE;
DROP TABLE IF EXISTS restaurant_hours     CASCADE;
DROP TABLE IF EXISTS restaurants          CASCADE;

DROP TYPE IF EXISTS order_status   CASCADE;
DROP TYPE IF EXISTS dish_category  CASCADE;
DROP TYPE IF EXISTS transport_type CASCADE;


-- =====================================================================
--  ENUM-ТИПЫ
--  ENUM = фиксированный список допустимых значений.
--  Используем там, где список значений задан условием задачи и почти
--  никогда не меняется.
-- =====================================================================

-- Статусы заказа. Порядок значений важен: он совпадает с жизненным
-- циклом заказа, поэтому статусы можно сравнивать через < и >.
CREATE TYPE order_status AS ENUM (
    'created',      -- создан
    'accepted',     -- принят рестораном
    'cooking',      -- готовится
    'ready',        -- готов
    'delivering',   -- курьер в пути
    'delivered',    -- доставлен
    'cancelled'     -- отменён (особый статус, не часть «прямой» цепочки)
);

-- Категории блюд (по условию — ровно пять)
CREATE TYPE dish_category AS ENUM (
    'salad',        -- салаты
    'soup',         -- супы
    'hot',          -- горячее
    'dessert',      -- десерты
    'drink'         -- напитки
);

-- Транспорт курьера
CREATE TYPE transport_type AS ENUM (
    'walk',         -- пешком
    'bicycle',      -- велосипед
    'motorcycle',   -- мотоцикл
    'car'           -- автомобиль
);


-- =====================================================================
--  УРОВЕНЬ 1: ТАБЛИЦЫ БЕЗ ВНЕШНИХ КЛЮЧЕЙ
-- =====================================================================

-- ================================================
-- Таблица: РЕСТОРАНЫ
-- Описание: Информация о зарегистрированных ресторанах
-- ================================================
CREATE TABLE restaurants (
    restaurant_id  SERIAL PRIMARY KEY,

    name           VARCHAR(200) NOT NULL,
    address        VARCHAR(500) NOT NULL,

    -- Средний рейтинг 0.0–5.0. 0.0 = отзывов пока нет.
    -- Заполняется автоматически триггером при добавлении отзыва.
    rating         DECIMAL(2, 1) NOT NULL DEFAULT 0.0,

    -- Открыт / временно закрыт
    is_open        BOOLEAN NOT NULL DEFAULT TRUE,

    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT valid_restaurant_rating CHECK (rating >= 0 AND rating <= 5),
    CONSTRAINT restaurant_name_not_empty CHECK (length(trim(name)) > 0)
);

COMMENT ON TABLE  restaurants               IS 'Зарегистрированные рестораны';
COMMENT ON COLUMN restaurants.restaurant_id IS 'Уникальный идентификатор ресторана';
COMMENT ON COLUMN restaurants.name          IS 'Название ресторана';
COMMENT ON COLUMN restaurants.address       IS 'Физический адрес ресторана';
COMMENT ON COLUMN restaurants.rating        IS 'Средний рейтинг на основе отзывов (0.0 — отзывов нет), считается триггером';
COMMENT ON COLUMN restaurants.is_open       IS 'TRUE — работает, FALSE — временно закрыт';
COMMENT ON COLUMN restaurants.created_at    IS 'Дата регистрации в сервисе';


-- ================================================
-- Таблица: КЛИЕНТЫ
-- ================================================
CREATE TABLE clients (
    client_id   SERIAL PRIMARY KEY,

    full_name   VARCHAR(150) NOT NULL,
    phone       VARCHAR(20)  NOT NULL UNIQUE,   -- по телефону входят в приложение
    email       VARCHAR(255) NOT NULL UNIQUE,

    created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Телефон: необязательный «+», затем 10–15 цифр
    CONSTRAINT valid_client_phone CHECK (phone ~ '^\+?[0-9]{10,15}$'),
    -- Простая проверка email: что-то@что-то.что-то
    CONSTRAINT valid_client_email CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

COMMENT ON TABLE  clients           IS 'Клиенты сервиса';
COMMENT ON COLUMN clients.full_name IS 'Имя клиента';
COMMENT ON COLUMN clients.phone     IS 'Телефон (уникальный, формат +77011234567)';
COMMENT ON COLUMN clients.email     IS 'Email (уникальный)';


-- ================================================
-- Таблица: КУРЬЕРЫ
-- ================================================
CREATE TABLE couriers (
    courier_id   SERIAL PRIMARY KEY,

    full_name    VARCHAR(150)   NOT NULL,
    phone        VARCHAR(20)    NOT NULL UNIQUE,
    transport    transport_type NOT NULL,

    -- На смене = доступен для заказов
    is_on_shift  BOOLEAN NOT NULL DEFAULT FALSE,

    created_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT valid_courier_phone CHECK (phone ~ '^\+?[0-9]{10,15}$')
);

COMMENT ON TABLE  couriers             IS 'Курьеры';
COMMENT ON COLUMN couriers.transport   IS 'Транспорт: walk / bicycle / motorcycle / car';
COMMENT ON COLUMN couriers.is_on_shift IS 'TRUE — на смене и может брать заказы';


-- ================================================
-- Таблица: ПРОМОКОДЫ (бонусное задание +5)
-- ================================================
CREATE TABLE promo_codes (
    promo_id          SERIAL PRIMARY KEY,

    code              VARCHAR(30) NOT NULL UNIQUE,
    discount_percent  SMALLINT    NOT NULL,                 -- скидка в процентах
    min_order_amount  DECIMAL(10, 2) NOT NULL DEFAULT 0,    -- минимальная сумма заказа
    valid_from        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    valid_until       TIMESTAMP,                            -- NULL = бессрочный
    max_uses          INTEGER,                              -- NULL = без лимита
    is_active         BOOLEAN NOT NULL DEFAULT TRUE,

    CONSTRAINT promo_code_upper      CHECK (code = upper(code)),
    CONSTRAINT valid_discount        CHECK (discount_percent BETWEEN 1 AND 100),
    CONSTRAINT valid_min_amount      CHECK (min_order_amount >= 0),
    CONSTRAINT valid_promo_period    CHECK (valid_until IS NULL OR valid_until > valid_from),
    CONSTRAINT valid_max_uses        CHECK (max_uses IS NULL OR max_uses > 0)
);

COMMENT ON TABLE  promo_codes                  IS 'Промокоды на скидку (бонус)';
COMMENT ON COLUMN promo_codes.code             IS 'Текст промокода, только заглавные буквы';
COMMENT ON COLUMN promo_codes.discount_percent IS 'Скидка в % от суммы блюд (1–100)';
COMMENT ON COLUMN promo_codes.min_order_amount IS 'Скидка действует, если сумма блюд не меньше этого значения';
COMMENT ON COLUMN promo_codes.valid_until      IS 'Срок действия; NULL — бессрочный';
COMMENT ON COLUMN promo_codes.max_uses         IS 'Сколько раз всего можно использовать; NULL — без ограничений';


-- =====================================================================
--  УРОВЕНЬ 2: ТАБЛИЦЫ, КОТОРЫЕ ССЫЛАЮТСЯ НА УРОВЕНЬ 1
-- =====================================================================

-- ================================================
-- Таблица: ВРЕМЯ РАБОТЫ РЕСТОРАНА
-- Одна строка = один день недели. Нет строки = в этот день выходной.
-- ================================================
CREATE TABLE restaurant_hours (
    restaurant_id  INTEGER  NOT NULL
                   REFERENCES restaurants (restaurant_id) ON DELETE CASCADE,

    day_of_week    SMALLINT NOT NULL,     -- 1 = понедельник ... 7 = воскресенье
    open_time      TIME     NOT NULL,
    close_time     TIME     NOT NULL,     -- если меньше open_time — работает после полуночи

    -- Составной первичный ключ: у ресторана одна запись на день недели
    PRIMARY KEY (restaurant_id, day_of_week),

    CONSTRAINT valid_day_of_week CHECK (day_of_week BETWEEN 1 AND 7),
    CONSTRAINT valid_work_time   CHECK (open_time <> close_time)
);

COMMENT ON TABLE  restaurant_hours             IS 'Расписание работы ресторанов по дням недели';
COMMENT ON COLUMN restaurant_hours.day_of_week IS '1 — пн, 2 — вт, ..., 7 — вс (как ISODOW в PostgreSQL)';
COMMENT ON COLUMN restaurant_hours.close_time  IS 'Время закрытия; если меньше open_time — ресторан работает после полуночи';


-- ================================================
-- Таблица: БЛЮДА (меню)
-- Меню ресторана = все его блюда, отдельная таблица «меню» не нужна.
-- ================================================
CREATE TABLE dishes (
    dish_id        SERIAL PRIMARY KEY,

    restaurant_id  INTEGER NOT NULL
                   REFERENCES restaurants (restaurant_id) ON DELETE CASCADE,

    name           VARCHAR(200)   NOT NULL,
    description    TEXT,
    price          DECIMAL(10, 2) NOT NULL,       -- текущая цена в тенге
    weight_grams   INTEGER        NOT NULL,
    category       dish_category  NOT NULL,

    -- Временно недоступно (например, закончились ингредиенты)
    is_available   BOOLEAN NOT NULL DEFAULT TRUE,

    created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT positive_price  CHECK (price > 0),
    CONSTRAINT positive_weight CHECK (weight_grams > 0),
    -- В одном ресторане не может быть двух блюд с одинаковым названием
    CONSTRAINT unique_dish_name_per_restaurant UNIQUE (restaurant_id, name)
);

COMMENT ON TABLE  dishes              IS 'Блюда; меню ресторана = все его блюда';
COMMENT ON COLUMN dishes.price        IS 'Текущая цена, тенге (> 0)';
COMMENT ON COLUMN dishes.weight_grams IS 'Вес порции в граммах (> 0)';
COMMENT ON COLUMN dishes.category     IS 'Категория: salad / soup / hot / dessert / drink';
COMMENT ON COLUMN dishes.is_available IS 'FALSE — блюдо временно нельзя заказать';


-- ================================================
-- Таблица: АДРЕСА КЛИЕНТОВ
-- ================================================
CREATE TABLE client_addresses (
    address_id    SERIAL PRIMARY KEY,

    client_id     INTEGER NOT NULL
                  REFERENCES clients (client_id) ON DELETE CASCADE,

    label         VARCHAR(50),                        -- «Дом», «Работа»
    city          VARCHAR(100) NOT NULL DEFAULT 'Алматы',
    street        VARCHAR(300) NOT NULL,              -- улица и дом
    apartment     VARCHAR(20),                        -- квартира / офис
    comment       TEXT,                               -- «домофон не работает»
    created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Нужен для составного внешнего ключа из orders:
    -- гарантирует, что заказ едет на адрес именно ЭТОГО клиента.
    CONSTRAINT unique_address_client UNIQUE (address_id, client_id)
);

COMMENT ON TABLE  client_addresses        IS 'Сохранённые адреса доставки клиентов (у клиента их может быть несколько)';
COMMENT ON COLUMN client_addresses.label  IS 'Название адреса: Дом, Работа и т.п.';
COMMENT ON COLUMN client_addresses.street IS 'Улица и номер дома';


-- ================================================
-- Таблица: СТАТИСТИКА КУРЬЕРА (связь 1:1 с couriers)
-- Обновляется триггерами, вручную не заполняется.
-- ================================================
CREATE TABLE courier_stats (
    -- PK одновременно является FK → у курьера ровно одна строка статистики
    courier_id        INTEGER PRIMARY KEY
                      REFERENCES couriers (courier_id) ON DELETE CASCADE,

    total_deliveries  INTEGER        NOT NULL DEFAULT 0,
    total_tips        DECIMAL(12, 2) NOT NULL DEFAULT 0,
    avg_rating        DECIMAL(2, 1)  NOT NULL DEFAULT 0.0,
    last_delivery_at  TIMESTAMP,

    CONSTRAINT non_negative_deliveries CHECK (total_deliveries >= 0),
    CONSTRAINT non_negative_tips       CHECK (total_tips >= 0),
    CONSTRAINT valid_courier_rating    CHECK (avg_rating >= 0 AND avg_rating <= 5)
);

COMMENT ON TABLE  courier_stats                  IS 'Статистика курьера (1:1 с couriers), ведётся триггерами';
COMMENT ON COLUMN courier_stats.total_deliveries IS 'Сколько заказов доставлено';
COMMENT ON COLUMN courier_stats.total_tips       IS 'Сумма полученных чаевых';
COMMENT ON COLUMN courier_stats.avg_rating       IS 'Средняя оценка курьера из отзывов (0.0 — оценок нет)';


-- =====================================================================
--  УРОВЕНЬ 3: ЗАКАЗЫ
-- =====================================================================

-- ================================================
-- Таблица: ЗАКАЗЫ
-- ================================================
CREATE TABLE orders (
    order_id         SERIAL PRIMARY KEY,

    client_id        INTEGER NOT NULL
                     REFERENCES clients (client_id) ON DELETE RESTRICT,

    -- Ресторан хранится в заказе → все позиции обязаны быть из него
    -- (проверяет триггер check_order_item).
    restaurant_id    INTEGER NOT NULL
                     REFERENCES restaurants (restaurant_id) ON DELETE RESTRICT,

    address_id       INTEGER NOT NULL,

    -- NULL, пока курьер не назначен
    courier_id       INTEGER
                     REFERENCES couriers (courier_id) ON DELETE RESTRICT,

    -- NULL, если промокод не применялся
    promo_id         INTEGER
                     REFERENCES promo_codes (promo_id) ON DELETE SET NULL,

    status           order_status NOT NULL DEFAULT 'created',

    -- Денежные поля заполняет триггер пересчёта суммы
    subtotal         DECIMAL(10, 2) NOT NULL DEFAULT 0,   -- сумма блюд
    discount_amount  DECIMAL(10, 2) NOT NULL DEFAULT 0,   -- скидка по промокоду
    total_amount     DECIMAL(10, 2) NOT NULL DEFAULT 0,   -- к оплате = subtotal − discount
    tip_amount       DECIMAL(10, 2) NOT NULL DEFAULT 0,   -- чаевые курьеру

    comment          TEXT,
    created_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Составной FK: пара (адрес, клиент) должна существовать в client_addresses.
    -- Так нельзя оформить доставку на чужой адрес.
    CONSTRAINT fk_order_address
        FOREIGN KEY (address_id, client_id)
        REFERENCES client_addresses (address_id, client_id)
        ON DELETE RESTRICT,

    CONSTRAINT non_negative_subtotal CHECK (subtotal >= 0),
    CONSTRAINT valid_discount_amount CHECK (discount_amount >= 0 AND discount_amount <= subtotal),
    CONSTRAINT valid_total_amount    CHECK (total_amount = subtotal - discount_amount),
    CONSTRAINT non_negative_tip      CHECK (tip_amount >= 0),
    -- Везти заказ без курьера нельзя
    CONSTRAINT courier_required CHECK (
        status NOT IN ('delivering', 'delivered') OR courier_id IS NOT NULL
    ),
    -- Чаевые можно оставить только если есть курьер
    CONSTRAINT tip_needs_courier CHECK (tip_amount = 0 OR courier_id IS NOT NULL)
);

COMMENT ON TABLE  orders                 IS 'Заказы клиентов (все блюда заказа — из одного ресторана)';
COMMENT ON COLUMN orders.restaurant_id   IS 'Ресторан заказа; все позиции должны быть из него';
COMMENT ON COLUMN orders.address_id      IS 'Адрес доставки — один из адресов этого клиента (составной FK)';
COMMENT ON COLUMN orders.courier_id      IS 'Назначенный курьер; NULL — ещё не назначен';
COMMENT ON COLUMN orders.promo_id        IS 'Применённый промокод; NULL — без промокода';
COMMENT ON COLUMN orders.status          IS 'Текущий статус; история переходов — в order_status_history';
COMMENT ON COLUMN orders.subtotal        IS 'Сумма блюд, считается триггером: Σ(цена × количество)';
COMMENT ON COLUMN orders.discount_amount IS 'Скидка по промокоду, считается триггером';
COMMENT ON COLUMN orders.total_amount    IS 'Итог к оплате = subtotal − discount_amount';
COMMENT ON COLUMN orders.tip_amount      IS 'Чаевые курьеру';


-- =====================================================================
--  УРОВЕНЬ 4: ТАБЛИЦЫ, ЗАВИСЯЩИЕ ОТ ЗАКАЗОВ
-- =====================================================================

-- ================================================
-- Таблица: ПОЗИЦИИ ЗАКАЗА (связующая M:N между orders и dishes)
-- ================================================
CREATE TABLE order_items (
    order_id        INTEGER NOT NULL
                    REFERENCES orders (order_id) ON DELETE CASCADE,
    dish_id         INTEGER NOT NULL
                    REFERENCES dishes (dish_id) ON DELETE RESTRICT,

    quantity        INTEGER NOT NULL DEFAULT 1,

    -- Цена блюда на момент заказа (бонус «история цен»).
    -- Если цену блюда потом поменяют, старые заказы не «поедут».
    price_at_order  DECIMAL(10, 2) NOT NULL,

    -- Составной PK: одно блюдо входит в заказ одной строкой,
    -- количество порций — в quantity
    PRIMARY KEY (order_id, dish_id),

    CONSTRAINT positive_quantity    CHECK (quantity > 0),
    CONSTRAINT positive_order_price CHECK (price_at_order > 0)
);

COMMENT ON TABLE  order_items                IS 'Позиции заказа: какое блюдо и сколько порций (связь M:N заказов и блюд)';
COMMENT ON COLUMN order_items.quantity       IS 'Количество порций (> 0)';
COMMENT ON COLUMN order_items.price_at_order IS 'Цена блюда на момент заказа; подставляется триггером';


-- ================================================
-- Таблица: ИСТОРИЯ СТАТУСОВ ЗАКАЗА
-- Здесь фиксируется время каждого этапа. Заполняется триггером.
-- ================================================
CREATE TABLE order_status_history (
    order_id    INTEGER      NOT NULL
                REFERENCES orders (order_id) ON DELETE CASCADE,
    status      order_status NOT NULL,
    changed_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Каждый статус заказ проходит не больше одного раза
    PRIMARY KEY (order_id, status)
);

COMMENT ON TABLE  order_status_history            IS 'Время каждого этапа заказа (заполняется триггером)';
COMMENT ON COLUMN order_status_history.changed_at IS 'Когда заказ перешёл в этот статус';


-- ================================================
-- Таблица: ОТЗЫВЫ
-- Один отзыв на один заказ (связь 1:1 с orders).
-- Клиент и ресторан берутся через заказ — дублировать их не нужно (3НФ).
-- ================================================
CREATE TABLE reviews (
    review_id          SERIAL PRIMARY KEY,

    order_id           INTEGER NOT NULL UNIQUE
                       REFERENCES orders (order_id) ON DELETE CASCADE,

    restaurant_rating  SMALLINT NOT NULL,   -- оценка ресторану 1–5
    courier_rating     SMALLINT,            -- оценка курьеру 1–5, необязательна
    comment            TEXT,

    created_at         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT valid_restaurant_rating_review CHECK (restaurant_rating BETWEEN 1 AND 5),
    CONSTRAINT valid_courier_rating_review    CHECK (courier_rating IS NULL OR courier_rating BETWEEN 1 AND 5)
);

COMMENT ON TABLE  reviews                   IS 'Отзывы клиентов о выполненных заказах (1 заказ — максимум 1 отзыв)';
COMMENT ON COLUMN reviews.order_id          IS 'Заказ, на который оставлен отзыв (UNIQUE → связь 1:1)';
COMMENT ON COLUMN reviews.restaurant_rating IS 'Оценка ресторану 1–5';
COMMENT ON COLUMN reviews.courier_rating    IS 'Оценка курьеру 1–5 (может отсутствовать)';


-- =====================================================================
--  ИНДЕКСЫ (Часть 5.1)
--  PostgreSQL сам создаёт индексы только для PRIMARY KEY и UNIQUE.
--  Для внешних ключей и фильтров в запросах индексы создаём вручную.
--  Номера запросов — из queries.sql.
-- =====================================================================

-- Индекс для запроса №1 (открытые рестораны по рейтингу)
-- Ускоряет: WHERE is_open = TRUE ORDER BY rating DESC
-- Почему эти колонки: сортировка идёт по rating — индекс уже хранит его по убыванию
-- Тип: ЧАСТИЧНЫЙ (WHERE is_open) — закрытые рестораны в индекс не попадают,
--      индекс меньше и сразу отдаёт строки в нужном порядке
CREATE INDEX idx_restaurants_open_rating
    ON restaurants (rating DESC)
    WHERE is_open;

-- Индекс для запроса №2 (меню ресторана по категориям)
-- Ускоряет: WHERE restaurant_id = 1 ... GROUP BY / ORDER BY category
-- Почему эти колонки: сначала фильтр по ресторану, затем группировка по категории
-- Тип: СОСТАВНОЙ (restaurant_id, category)
-- Также используется для FK dishes.restaurant_id (удаление ресторана)
CREATE INDEX idx_dishes_restaurant_category
    ON dishes (restaurant_id, category);

-- Индекс для FK client_addresses.client_id (адреса клиента, удаление клиента)
-- Тип: обычный. UNIQUE (address_id, client_id) тут не помогает —
--      в нём client_id стоит вторым.
CREATE INDEX idx_client_addresses_client
    ON client_addresses (client_id);

-- Индекс для запросов №3 и №8 (заказы клиента, последний заказ клиента)
-- Ускоряет: WHERE client_id = 1;  MAX(created_at) ... GROUP BY client_id
-- Почему эти колонки: поиск по клиенту + внутри клиента заказы уже
--      отсортированы по дате, MAX(created_at) берётся с «края» индекса
-- Тип: СОСТАВНОЙ
CREATE INDEX idx_orders_client_created
    ON orders (client_id, created_at);

-- Индекс для запросов №4 (заказы за последний месяц)
-- Ускоряет: WHERE created_at >= now() - interval '1 month'
-- Почему эта колонка: фильтр по диапазону дат
-- Тип: обычный B-tree (подходит для диапазонов >, <, BETWEEN)
CREATE INDEX idx_orders_created_at
    ON orders (created_at);

-- Индекс для запросов №7 и №9 (заказ → ресторан) и для FK orders.restaurant_id
-- Ускоряет: в №7 и №9 из orders нужны только order_id, restaurant_id
--      и created_at — все они лежат в индексе, поэтому PostgreSQL читает
--      компактный индекс (Index Only Scan) вместо всей таблицы заказов
-- Почему эти колонки: restaurant_id — ключ (FK, группировка);
--      order_id и created_at — в INCLUDE (хранятся, но не сортируются)
-- Тип: ПОКРЫВАЮЩИЙ (INCLUDE)
CREATE INDEX idx_orders_restaurant
    ON orders (restaurant_id) INCLUDE (order_id, created_at);

-- Индекс для запроса №6 (курьеры без активного заказа)
-- Ускоряет: NOT EXISTS (... WHERE courier_id = c.courier_id AND статус активный)
-- Почему эта колонка: ищем заказы конкретного курьера
-- Тип: ЧАСТИЧНЫЙ — в индекс попадают только активные заказы с курьером.
--      Их всегда единицы, а завершённых — тысячи, поэтому индекс крошечный.
CREATE INDEX idx_orders_courier_active
    ON orders (courier_id)
    WHERE courier_id IS NOT NULL
      AND status NOT IN ('delivered', 'cancelled');

-- Индекс для FK order_items.dish_id и запроса №4 (популярные блюда)
-- Ускоряет: JOIN order_items → dishes, проверку при удалении блюда
-- Тип: обычный. PK (order_id, dish_id) по dish_id не помогает — он второй.
CREATE INDEX idx_order_items_dish
    ON order_items (dish_id);

-- Индекс для запроса №7 (среднее время доставки)
-- Ускоряет: JOIN order_status_history ... WHERE status = 'delivered'
-- Почему эти колонки: соединяем по order_id, а changed_at нужен в расчёте —
--      INCLUDE кладёт его прямо в индекс (Index Only Scan, без чтения таблицы)
-- Тип: ЧАСТИЧНЫЙ + покрывающий — хранит только строки 'delivered'
--      (примерно 1/6 таблицы истории)
CREATE INDEX idx_status_history_delivered
    ON order_status_history (order_id) INCLUDE (changed_at)
    WHERE status = 'delivered';

-- Индекс для запроса №9 (рейтинг за текущий и прошлый месяц)
-- Ускоряет: WHERE reviews.created_at >= начало прошлого месяца
-- Почему эти колонки: фильтр по дате; order_id в INCLUDE — для JOIN с orders
--      без чтения таблицы reviews; restaurant_rating — для AVG
-- Тип: покрывающий B-tree (Index Only Scan)
CREATE INDEX idx_reviews_created_at
    ON reviews (created_at) INCLUDE (order_id, restaurant_rating);
