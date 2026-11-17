-- =====================================================================
--  ПРОВЕРКА ТРИГГЕРОВ (необязательный файл — для защиты и самопроверки)
--  Запуск: psql -d <база> -f tests.sql   (после data.sql)
--  Каждый тест — «плохая» операция. Ошибку ловим (EXCEPTION WHEN OTHERS)
--  и печатаем её текст через RAISE NOTICE. База при этом не меняется.
-- =====================================================================

DO $$
BEGIN
    -- Тест 1.1: недоступное блюдо (Наполеон, id 34) в новый заказ ресторана 5
    INSERT INTO orders (client_id, restaurant_id, address_id) VALUES (5, 5, 7);
    INSERT INTO order_items (order_id, dish_id, quantity) VALUES (currval('orders_order_id_seq'), 34, 1);
    RAISE NOTICE 'Тест 1.1 НЕ пройден: ошибки не было';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест 1.1 (недоступное блюдо): %', SQLERRM;
END $$;

DO $$
BEGIN
    -- Тест 1.2: блюдо из другого ресторана (Пицца, id 10) в заказ №23 (Дастархан)
    INSERT INTO order_items (order_id, dish_id, quantity) VALUES (23, 10, 1);
    RAISE NOTICE 'Тест 1.2 НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест 1.2 (другой ресторан): %', SQLERRM;
END $$;

DO $$
BEGIN
    -- Тест 1.3: добавить блюдо в уже доставленный заказ №1
    INSERT INTO order_items (order_id, dish_id, quantity) VALUES (1, 2, 1);
    RAISE NOTICE 'Тест 1.3 НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест 1.3 (заказ уже доставлен): %', SQLERRM;
END $$;

DO $$
BEGIN
    -- Тест 1.4: количество 0 (срабатывает CHECK, а не триггер)
    INSERT INTO order_items (order_id, dish_id, quantity) VALUES (23, 2, 0);
    RAISE NOTICE 'Тест 1.4 НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест 1.4 (количество 0): %', SQLERRM;
END $$;

-- Тест 2: пересчёт суммы. Меняем количество в заказе №23 и смотрим сумму.
BEGIN;
SELECT order_id, subtotal, total_amount AS "сумма до" FROM orders WHERE order_id = 23;
UPDATE order_items SET quantity = 3 WHERE order_id = 23 AND dish_id = 7;   -- чай: 1 → 3 (+1000)
SELECT order_id, subtotal, total_amount AS "сумма после (+1000)" FROM orders WHERE order_id = 23;
DELETE FROM order_items WHERE order_id = 23 AND dish_id = 4;              -- убрали бешбармак (−3500)
SELECT order_id, subtotal, total_amount AS "после удаления (−3500)" FROM orders WHERE order_id = 23;
ROLLBACK;   -- откатываем, чтобы не портить тестовые данные

-- Тест 3: рейтинг ресторана после нового отзыва
BEGIN;
SELECT name, rating AS "рейтинг до" FROM restaurants WHERE restaurant_id = 5;
INSERT INTO reviews (order_id, restaurant_rating) VALUES (15, 2);          -- заказ 15 — Coffee & Cake
SELECT name, rating AS "рейтинг после оценки 2" FROM restaurants WHERE restaurant_id = 5;
ROLLBACK;

DO $$
BEGIN
    -- Тест 3.1: отзыв на недоставленный заказ
    INSERT INTO reviews (order_id, restaurant_rating) VALUES (21, 5);
    RAISE NOTICE 'Тест 3.1 НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест 3.1 (отзыв на заказ в пути): %', SQLERRM;
END $$;

DO $$
BEGIN
    -- Тест 3.2: второй отзыв на тот же заказ (UNIQUE)
    INSERT INTO reviews (order_id, restaurant_rating) VALUES (1, 1);
    RAISE NOTICE 'Тест 3.2 НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест 3.2 (второй отзыв): %', SQLERRM;
END $$;

DO $$
BEGIN
    -- Тест A.1: обратный переход delivered → cooking
    UPDATE orders SET status = 'cooking' WHERE order_id = 1;
    RAISE NOTICE 'Тест A.1 НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест A.1 (обратный переход): %', SQLERRM;
END $$;

DO $$
BEGIN
    -- Тест A.2: перескок этапа accepted → ready (заказ 25)
    UPDATE orders SET status = 'ready' WHERE order_id = 25;
    RAISE NOTICE 'Тест A.2 НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест A.2 (перескок этапа): %', SQLERRM;
END $$;

DO $$
BEGIN
    -- Тест A.3: отмена заказа, который уже готовится (заказ 22)
    UPDATE orders SET status = 'cancelled' WHERE order_id = 22;
    RAISE NOTICE 'Тест A.3 НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест A.3 (отмена после "готовится"): %', SQLERRM;
END $$;

DO $$
BEGIN
    -- Тест A.4: «в пути» без курьера (заказ 22: cooking → ready → delivering, курьера нет)
    UPDATE orders SET status = 'ready' WHERE order_id = 22;
    UPDATE orders SET status = 'delivering' WHERE order_id = 22;
    RAISE NOTICE 'Тест A.4 НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест A.4 (в пути без курьера): %', SQLERRM;
END $$;

-- Тест A.5: нормальный переход пишет время в историю
BEGIN;
UPDATE orders SET status = 'cooking' WHERE order_id = 25;
SELECT order_id, status, changed_at FROM order_status_history WHERE order_id = 25 ORDER BY changed_at;
ROLLBACK;

DO $$
BEGIN
    -- Тест: заказ в закрытый ресторан (№6)
    INSERT INTO orders (client_id, restaurant_id, address_id) VALUES (1, 6, 1);
    RAISE NOTICE 'Тест закрытого ресторана НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест (закрытый ресторан): %', SQLERRM;
END $$;

DO $$
BEGIN
    -- Тест: доставка на чужой адрес (адрес 3 принадлежит клиенту 2)
    INSERT INTO orders (client_id, restaurant_id, address_id) VALUES (1, 1, 3);
    RAISE NOTICE 'Тест чужого адреса НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест (чужой адрес): %', SQLERRM;
END $$;

DO $$
BEGIN
    -- Тест: просроченный промокод SUMMER15
    INSERT INTO orders (client_id, restaurant_id, address_id, promo_id) VALUES (1, 1, 1, 3);
    RAISE NOTICE 'Тест промокода НЕ пройден';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Тест (неактивный промокод): %', SQLERRM;
END $$;

-- Тест промокода: удаление промокода не меняет чек принятого заказа
BEGIN;
DELETE FROM promo_codes WHERE promo_id = 1;     -- WELCOME10, применён в заказе №8
SELECT order_id, promo_id, subtotal, discount_amount, total_amount AS "чек заказа 8 (должен остаться 9270)"
FROM orders WHERE order_id = 8;
ROLLBACK;

-- Бонус «история цен»: Лагман сейчас 2700, а в старых заказах — 2500
SELECT d.name, d.price AS "цена сейчас", oi.order_id, oi.price_at_order AS "цена в заказе"
FROM order_items oi
JOIN dishes d ON d.dish_id = oi.dish_id
WHERE d.dish_id = 3
ORDER BY oi.order_id;
