-- =====================================================================
--  СЕРВИС ДОСТАВКИ ЕДЫ — ТРИГГЕРЫ
--  Файл: triggers.sql   (запускать после schema.sql)
--
--  Задание 3.1 (обязательные):
--    Триггер 1  trg_check_order_item      — проверка позиции заказа
--    Триггер 2  trg_recalc_order_total    — пересчёт суммы заказа
--    Триггер 3  trg_update_ratings        — пересчёт рейтинга ресторана
--  Задание 3.2 (выбран Вариант A — контроль статуса заказа):
--    trg_check_status_change              — запрет «обратных» переходов
--    trg_log_status_insert / _update      — запись времени каждого статуса
--  Вспомогательные:
--    trg_check_new_order                  — новый заказ только в статусе 'created'
--    trg_apply_promo                      — скидка по промокоду (бонус)
--    trg_check_review                     — отзыв только на доставленный заказ
--    trg_create_courier_stats             — строка статистики для нового курьера
--    trg_update_courier_stats             — доставки и чаевые курьера
-- =====================================================================


-- =====================================================================
--  ТРИГГЕР 1: ПРОВЕРКА ПОЗИЦИИ ЗАКАЗА
--  Когда: BEFORE INSERT / UPDATE / DELETE на order_items
--  Проверяет:
--    • заказ существует и ещё не принят рестораном (status = 'created');
--    • блюдо существует и доступно (is_available = TRUE);
--    • блюдо из того же ресторана, что и заказ.
--      Ресторан хранится в orders.restaurant_id, поэтому все позиции
--      автоматически оказываются из одного ресторана.
--  Дополнительно (бонус «история цен»): подставляет price_at_order —
--  цену блюда в момент добавления в заказ.
-- =====================================================================
CREATE OR REPLACE FUNCTION check_order_item()
RETURNS TRIGGER AS $$
DECLARE
    v_order_status      order_status;
    v_order_restaurant  INTEGER;
    v_dish_name         VARCHAR(200);
    v_dish_restaurant   INTEGER;
    v_dish_available    BOOLEAN;
    v_dish_price        DECIMAL(10, 2);
BEGIN
    -- ---------- Удаление позиции ----------
    IF TG_OP = 'DELETE' THEN
        SELECT status INTO v_order_status
        FROM orders WHERE order_id = OLD.order_id;

        -- FOUND = TRUE, если SELECT нашёл строку.
        -- Если заказа уже нет (удаляется целиком через CASCADE) — разрешаем.
        IF FOUND AND v_order_status <> 'created' THEN
            RAISE EXCEPTION 'Нельзя убрать блюдо из заказа №%: заказ уже в статусе "%"',
                OLD.order_id, v_order_status;
        END IF;
        RETURN OLD;          -- для DELETE возвращаем OLD
    END IF;

    -- ---------- Добавление / изменение позиции ----------
    -- 1. Информация о заказе
    SELECT status, restaurant_id
      INTO v_order_status, v_order_restaurant
    FROM orders
    WHERE order_id = NEW.order_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Заказ №% не существует', NEW.order_id;
    END IF;

    IF v_order_status <> 'created' THEN
        RAISE EXCEPTION 'Нельзя менять состав заказа №%: заказ уже в статусе "%"',
            NEW.order_id, v_order_status;
    END IF;

    -- 2. Информация о блюде
    SELECT name, restaurant_id, is_available, price
      INTO v_dish_name, v_dish_restaurant, v_dish_available, v_dish_price
    FROM dishes
    WHERE dish_id = NEW.dish_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Блюдо №% не существует', NEW.dish_id;
    END IF;

    -- 3. Блюдо доступно?
    IF NOT v_dish_available THEN
        RAISE EXCEPTION 'Блюдо "%" сейчас недоступно для заказа', v_dish_name;
    END IF;

    -- 4. Блюдо из того же ресторана, что и заказ?
    IF v_dish_restaurant <> v_order_restaurant THEN
        RAISE EXCEPTION 'Блюдо "%" из другого ресторана. В одном заказе могут быть блюда только одного ресторана (ресторан заказа: №%, ресторан блюда: №%)',
            v_dish_name, v_order_restaurant, v_dish_restaurant;
    END IF;

    -- 5. Фиксируем цену на момент заказа
    --    (при изменении только количества цена остаётся прежней)
    IF TG_OP = 'INSERT' OR NEW.dish_id <> OLD.dish_id THEN
        NEW.price_at_order := v_dish_price;
    END IF;

    RETURN NEW;              -- BEFORE-триггер обязан вернуть строку
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_order_item
BEFORE INSERT OR UPDATE OR DELETE ON order_items
FOR EACH ROW
EXECUTE FUNCTION check_order_item();


-- =====================================================================
--  ТРИГГЕР 2: РАСЧЁТ СУММЫ ЗАКАЗА
--  Когда: AFTER INSERT / UPDATE / DELETE на order_items
--  Что делает: subtotal = Σ (цена на момент заказа × количество)
--  Скидку и итог (total_amount) затем считает trg_apply_promo на orders.
--  Бесконечного цикла нет: триггер на order_items обновляет ДРУГУЮ
--  таблицу (orders).
-- =====================================================================
CREATE OR REPLACE FUNCTION recalc_order_total()
RETURNS TRIGGER AS $$
BEGIN
    -- Пересчитываем заказ, к которому относится новая/изменённая строка
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        UPDATE orders
        SET subtotal = (
                SELECT COALESCE(SUM(price_at_order * quantity), 0)   -- COALESCE: если позиций нет → 0
                FROM order_items
                WHERE order_id = NEW.order_id
            )
        WHERE order_id = NEW.order_id;
    END IF;

    -- Пересчитываем заказ, из которого строка ушла
    -- (при DELETE или если позицию перенесли в другой заказ)
    IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.order_id <> NEW.order_id) THEN
        UPDATE orders
        SET subtotal = (
                SELECT COALESCE(SUM(price_at_order * quantity), 0)
                FROM order_items
                WHERE order_id = OLD.order_id
            )
        WHERE order_id = OLD.order_id;
    END IF;

    RETURN NULL;   -- для AFTER-триггера возвращаемое значение не используется
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_recalc_order_total
AFTER INSERT OR UPDATE OR DELETE ON order_items
FOR EACH ROW
EXECUTE FUNCTION recalc_order_total();


-- =====================================================================
--  БОНУС: ПРОМОКОДЫ — скидка и итог заказа
--  Когда: BEFORE INSERT или UPDATE OF subtotal, promo_id на orders
--  Что делает:
--    • при назначении промокода проверяет: активен, срок не истёк,
--      лимит использований не исчерпан;
--    • считает discount_amount и total_amount = subtotal − discount.
--    Если сумма блюд меньше min_order_amount — скидка 0 (без ошибки,
--    клиент ещё может добавить блюда).
--    После того как ресторан принял заказ, суммы ЗАФИКСИРОВАНЫ:
--    например, удаление промокода (ON DELETE SET NULL обнулит promo_id)
--    не должно менять чек уже оплаченного заказа.
-- =====================================================================
CREATE OR REPLACE FUNCTION apply_promo()
RETURNS TRIGGER AS $$
DECLARE
    v_promo       promo_codes%ROWTYPE;   -- переменная = целая строка таблицы
    v_used_count  INTEGER;
BEGIN
    -- Заказ уже принят рестораном → суммы не пересчитываем
    IF TG_OP = 'UPDATE' AND OLD.status <> 'created' THEN
        IF NEW.promo_id IS NOT NULL AND NEW.promo_id IS DISTINCT FROM OLD.promo_id THEN
            RAISE EXCEPTION 'Промокод можно применить только до того, как ресторан принял заказ (заказ №% в статусе "%")',
                OLD.order_id, OLD.status;
        END IF;
        NEW.subtotal        := OLD.subtotal;
        NEW.discount_amount := OLD.discount_amount;
        NEW.total_amount    := OLD.total_amount;
        RETURN NEW;
    END IF;

    NEW.discount_amount := 0;

    IF NEW.promo_id IS NOT NULL THEN
        SELECT * INTO v_promo FROM promo_codes WHERE promo_id = NEW.promo_id;

        -- Проверяем промокод только в момент его применения,
        -- чтобы скидка не пропала, если срок промокода истечёт во время доставки
        IF TG_OP = 'INSERT' OR NEW.promo_id IS DISTINCT FROM OLD.promo_id THEN
            IF NOT v_promo.is_active THEN
                RAISE EXCEPTION 'Промокод % не активен', v_promo.code;
            END IF;

            IF NEW.created_at < v_promo.valid_from
               OR (v_promo.valid_until IS NOT NULL AND NEW.created_at > v_promo.valid_until) THEN
                RAISE EXCEPTION 'Промокод % недействителен на дату заказа', v_promo.code;
            END IF;

            IF v_promo.max_uses IS NOT NULL THEN
                SELECT COUNT(*) INTO v_used_count
                FROM orders
                WHERE promo_id = NEW.promo_id
                  AND status <> 'cancelled'
                  AND order_id <> NEW.order_id;

                IF v_used_count >= v_promo.max_uses THEN
                    RAISE EXCEPTION 'Промокод % исчерпан (лимит: % использований)',
                        v_promo.code, v_promo.max_uses;
                END IF;
            END IF;
        END IF;

        -- Скидка действует, только если набрана минимальная сумма
        IF NEW.subtotal >= v_promo.min_order_amount THEN
            NEW.discount_amount := ROUND(NEW.subtotal * v_promo.discount_percent / 100.0, 2);
        END IF;
    END IF;

    NEW.total_amount := NEW.subtotal - NEW.discount_amount;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_promo
BEFORE INSERT OR UPDATE OF subtotal, promo_id ON orders
FOR EACH ROW
EXECUTE FUNCTION apply_promo();


-- =====================================================================
--  ТРИГГЕР 3: ОБНОВЛЕНИЕ РЕЙТИНГА РЕСТОРАНА (и курьера)
--  Когда: AFTER INSERT / UPDATE / DELETE на reviews
--  Что делает: rating ресторана = среднее restaurant_rating по всем
--  отзывам на его заказы, округлённое до 0.1. Заодно пересчитывает
--  среднюю оценку курьера в courier_stats.
-- =====================================================================
CREATE OR REPLACE FUNCTION update_ratings()
RETURNS TRIGGER AS $$
DECLARE
    v_order_id       INTEGER;
    v_restaurant_id  INTEGER;
    v_courier_id     INTEGER;
BEGIN
    -- Для DELETE строки NEW нет, берём OLD
    IF TG_OP = 'DELETE' THEN
        v_order_id := OLD.order_id;
    ELSE
        v_order_id := NEW.order_id;
    END IF;

    -- Ресторан и курьер берём через заказ
    SELECT restaurant_id, courier_id
      INTO v_restaurant_id, v_courier_id
    FROM orders
    WHERE order_id = v_order_id;

    -- Заказ уже удалён (отзыв удаляется каскадом) — пересчитывать нечего
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Рейтинг ресторана
    UPDATE restaurants
    SET rating = COALESCE((
            SELECT ROUND(AVG(rv.restaurant_rating), 1)
            FROM reviews rv
            JOIN orders o ON o.order_id = rv.order_id
            WHERE o.restaurant_id = v_restaurant_id
        ), 0.0)                     -- отзывов не осталось → 0.0
    WHERE restaurant_id = v_restaurant_id;

    -- Рейтинг курьера (оценка курьеру необязательна → AVG пропускает NULL)
    IF v_courier_id IS NOT NULL THEN
        UPDATE courier_stats
        SET avg_rating = COALESCE((
                SELECT ROUND(AVG(rv.courier_rating), 1)
                FROM reviews rv
                JOIN orders o ON o.order_id = rv.order_id
                WHERE o.courier_id = v_courier_id
            ), 0.0)
        WHERE courier_id = v_courier_id;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_ratings
AFTER INSERT OR UPDATE OR DELETE ON reviews
FOR EACH ROW
EXECUTE FUNCTION update_ratings();


-- ---------------------------------------------------------------------
--  Проверка отзыва: оставить можно только на доставленный заказ
--  («Клиент может оставлять отзывы о выполненных заказах»)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_review()
RETURNS TRIGGER AS $$
DECLARE
    v_status order_status;
BEGIN
    SELECT status INTO v_status FROM orders WHERE order_id = NEW.order_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Заказ №% не существует', NEW.order_id;
    END IF;

    IF v_status <> 'delivered' THEN
        RAISE EXCEPTION 'Отзыв можно оставить только на доставленный заказ (заказ №% в статусе "%")',
            NEW.order_id, v_status;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_review
BEFORE INSERT OR UPDATE OF order_id ON reviews
FOR EACH ROW
EXECUTE FUNCTION check_review();


-- =====================================================================
--  ЗАДАНИЕ 3.2 — ВАРИАНТ A: КОНТРОЛЬ СТАТУСА ЗАКАЗА
-- =====================================================================

-- ---------------------------------------------------------------------
--  Новый заказ: только в статусе 'created' и только в открытый ресторан
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_new_order()
RETURNS TRIGGER AS $$
DECLARE
    v_is_open BOOLEAN;
BEGIN
    IF NEW.status <> 'created' THEN
        RAISE EXCEPTION 'Новый заказ создаётся только в статусе "created" (передан "%")', NEW.status;
    END IF;

    SELECT is_open INTO v_is_open FROM restaurants WHERE restaurant_id = NEW.restaurant_id;

    IF v_is_open = FALSE THEN
        RAISE EXCEPTION 'Ресторан №% временно закрыт, заказ оформить нельзя', NEW.restaurant_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_new_order
BEFORE INSERT ON orders
FOR EACH ROW
EXECUTE FUNCTION check_new_order();


-- ---------------------------------------------------------------------
--  Проверка перехода статуса
--  Разрешённые переходы (только на один шаг вперёд):
--    created → accepted → cooking → ready → delivering → delivered
--  Отмена:  created → cancelled,  accepted → cancelled
--           (по условию — только до статуса «готовится»)
--  Всё остальное (назад, через шаг, из завершённого) — ошибка.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_status_change()
RETURNS TRIGGER AS $$
DECLARE
    v_next order_status;   -- единственный допустимый следующий статус
BEGIN
    -- Заказ завершён — менять статус нельзя
    IF OLD.status IN ('delivered', 'cancelled') THEN
        RAISE EXCEPTION 'Заказ №% уже завершён (статус "%"), изменить статус нельзя',
            OLD.order_id, OLD.status;
    END IF;

    -- Отмена
    IF NEW.status = 'cancelled' THEN
        IF OLD.status NOT IN ('created', 'accepted') THEN
            RAISE EXCEPTION 'Заказ №% нельзя отменить: он уже в статусе "%". Отмена возможна только до статуса "cooking" (готовится)',
                OLD.order_id, OLD.status;
        END IF;
        NEW.updated_at := CURRENT_TIMESTAMP;
        RETURN NEW;
    END IF;

    -- Обратный переход (порядок значений ENUM = порядок этапов)
    IF NEW.status < OLD.status THEN
        RAISE EXCEPTION 'Обратный переход статуса запрещён: "%" → "%" (заказ №%)',
            OLD.status, NEW.status, OLD.order_id;
    END IF;

    -- Перескакивать этапы нельзя
    v_next := CASE OLD.status
                  WHEN 'created'    THEN 'accepted'
                  WHEN 'accepted'   THEN 'cooking'
                  WHEN 'cooking'    THEN 'ready'
                  WHEN 'ready'      THEN 'delivering'
                  WHEN 'delivering' THEN 'delivered'
              END;

    IF NEW.status <> v_next THEN
        RAISE EXCEPTION 'Нельзя перескочить этап: из "%" можно перейти только в "%" (заказ №%)',
            OLD.status, v_next, OLD.order_id;
    END IF;

    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- WHEN: триггер срабатывает, только если статус действительно изменился
CREATE TRIGGER trg_check_status_change
BEFORE UPDATE OF status ON orders
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION check_status_change();


-- ---------------------------------------------------------------------
--  Автоматическая запись времени каждого статуса в историю
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION log_status_change()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Первый этап — время создания заказа
        INSERT INTO order_status_history (order_id, status, changed_at)
        VALUES (NEW.order_id, NEW.status, NEW.created_at);
    ELSE
        INSERT INTO order_status_history (order_id, status, changed_at)
        VALUES (NEW.order_id, NEW.status, NEW.updated_at);
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_log_status_insert
AFTER INSERT ON orders
FOR EACH ROW
EXECUTE FUNCTION log_status_change();

CREATE TRIGGER trg_log_status_update
AFTER UPDATE OF status ON orders
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION log_status_change();


-- =====================================================================
--  СТАТИСТИКА КУРЬЕРА («Система отслеживает статистику курьера»)
-- =====================================================================

-- Новый курьер → сразу создаём ему пустую строку статистики (1:1)
CREATE OR REPLACE FUNCTION create_courier_stats()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO courier_stats (courier_id) VALUES (NEW.courier_id);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_create_courier_stats
AFTER INSERT ON couriers
FOR EACH ROW
EXECUTE FUNCTION create_courier_stats();


-- Заказ доставлен → +1 доставка и чаевые курьеру.
-- Чаевые добавили после доставки → прибавляем разницу.
CREATE OR REPLACE FUNCTION update_courier_stats()
RETURNS TRIGGER AS $$
BEGIN
    -- Заказ только что стал доставленным
    IF NEW.status = 'delivered' AND OLD.status <> 'delivered' THEN
        UPDATE courier_stats
        SET total_deliveries = total_deliveries + 1,
            total_tips       = total_tips + NEW.tip_amount,
            last_delivery_at = NEW.updated_at
        WHERE courier_id = NEW.courier_id;

    -- Заказ уже был доставлен, а клиент изменил чаевые
    ELSIF NEW.status = 'delivered' AND NEW.tip_amount <> OLD.tip_amount THEN
        UPDATE courier_stats
        SET total_tips = total_tips + (NEW.tip_amount - OLD.tip_amount)
        WHERE courier_id = NEW.courier_id;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_courier_stats
AFTER UPDATE OF status, tip_amount ON orders
FOR EACH ROW
EXECUTE FUNCTION update_courier_stats();
