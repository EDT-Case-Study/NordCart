-- Drop existing views so this file can be run again in the same session.
DROP VIEW IF EXISTS support_tickets_clean;
DROP VIEW IF EXISTS order_lines_clean;
DROP VIEW IF EXISTS orders_clean;
DROP VIEW IF EXISTS order_items_clean;
DROP VIEW IF EXISTS orders_base;
DROP VIEW IF EXISTS campaign_result;
DROP VIEW IF EXISTS orders_with_first_flag;
DROP VIEW IF EXISTS campaigns_clean;
DROP VIEW IF EXISTS products_clean;
DROP VIEW IF EXISTS customers_clean;

-- One row per customer. Read all three signup-date formats, map country labels, and clear ages outside 10–100.
CREATE VIEW customers_clean AS
SELECT
    customer_id,
    signup_date AS signup_date_raw,
    CASE
        WHEN length(signup_date) = 10 AND substr(signup_date, 5, 1) = '-'
            THEN signup_date
        WHEN length(signup_date) = 10 AND substr(signup_date, 3, 1) = '.'
            THEN substr(signup_date, 7, 4) || '-' || substr(signup_date, 4, 2) || '-' || substr(signup_date, 1, 2)
        WHEN length(signup_date) = 10 AND substr(signup_date, 3, 1) = '/'
            THEN substr(signup_date, 7, 4) || '-' || substr(signup_date, 1, 2) || '-' || substr(signup_date, 4, 2)
    END AS signup_date,
    country AS country_raw,
    CASE trim(country)
        WHEN 'Germany' THEN 'Germany'
        WHEN 'germany' THEN 'Germany'
        WHEN 'DE' THEN 'Germany'
        WHEN 'Deutschland' THEN 'Germany'
        WHEN 'GER' THEN 'Germany'
        WHEN 'Austria' THEN 'Austria'
        WHEN 'austria' THEN 'Austria'
        WHEN 'Österreich' THEN 'Austria'
        WHEN 'AT' THEN 'Austria'
        WHEN 'Netherlands' THEN 'Netherlands'
        WHEN 'Holland' THEN 'Netherlands'
        WHEN 'NL' THEN 'Netherlands'
        WHEN 'France' THEN 'France'
        WHEN 'FR' THEN 'France'
        WHEN 'Switzerland' THEN 'Switzerland'
        WHEN 'Schweiz' THEN 'Switzerland'
        WHEN 'CH' THEN 'Switzerland'
        WHEN 'Poland' THEN 'Poland'
        WHEN 'PL' THEN 'Poland'
        WHEN '' THEN NULL
        ELSE nullif(trim(country), '')
    END AS country,
    age AS age_raw,
    CASE
        WHEN trim(coalesce(age, '')) <> ''
         AND CAST(age AS REAL) BETWEEN 10 AND 100
            THEN CAST(age AS REAL)
    END AS age,
    segment,
    acquisition_channel,
    newsletter_opt_in,
    favorite_color,
    zodiac_sign,
    preferred_language
FROM (
    SELECT DISTINCT *
    FROM customers
) AS customers;

-- Fill a blank category from the product-name prefix, and store prices as numbers.

CREATE VIEW products_clean AS
SELECT
    product_id,
    product_name,
    category AS category_raw,
    CASE
        WHEN category IS NOT NULL AND trim(category) <> '' THEN category
        WHEN substr(product_name, 1, instr(product_name, '-') - 1) = 'BEAU' THEN 'Beauty'
        WHEN substr(product_name, 1, instr(product_name, '-') - 1) = 'ELEC' THEN 'Electronics'
        WHEN substr(product_name, 1, instr(product_name, '-') - 1) = 'FASH' THEN 'Fashion'
        WHEN substr(product_name, 1, instr(product_name, '-') - 1) = 'HOME' THEN 'Home'
        WHEN substr(product_name, 1, instr(product_name, '-') - 1) = 'SPOR' THEN 'Sports'
        WHEN substr(product_name, 1, instr(product_name, '-') - 1) = 'TOYS' THEN 'Toys'
    END AS category,
    supplier_id,
    CAST(price_eur AS REAL) AS price_eur,
    CAST(unit_cost_eur AS REAL) AS unit_cost_eur,
    weight_g,
    color,
    launch_date
FROM products;

-- Store each campaign budget as a number. The budget is subtracted once later, not once per order.

CREATE VIEW campaigns_clean AS
SELECT
    campaign_id,
    campaign_name,
    channel,
    start_date,
    end_date,
    CAST(budget_eur AS REAL) AS budget_eur
FROM campaigns;


-- One row per order from July 2024 to June 2026. Drop duplicate headers and 2019-01-01 rows, and clear a campaign tag outside its dates.

CREATE VIEW orders_base AS
WITH distinct_orders AS (
    SELECT DISTINCT *
    FROM orders
),
one_row_per_order AS (
    SELECT *
    FROM (
        SELECT
            distinct_orders.*,
            row_number() OVER (
                PARTITION BY order_id
                ORDER BY order_id
            ) AS duplicate_rank
        FROM distinct_orders
    ) AS ranked
    WHERE duplicate_rank = 1
      AND order_date >= '2024-07-01'
      AND order_date <= '2026-06-30'
)
SELECT
    one_row_per_order.order_id,
    one_row_per_order.customer_id,
    one_row_per_order.order_date,
    nullif(trim(one_row_per_order.campaign_id), '') AS campaign_id_raw,
    CASE
        WHEN nullif(trim(one_row_per_order.campaign_id), '') IS NULL THEN NULL
        WHEN one_row_per_order.order_date < campaigns.start_date
          OR one_row_per_order.order_date > campaigns.end_date THEN NULL
        ELSE one_row_per_order.campaign_id
    END AS campaign_id,
    CASE
        WHEN nullif(trim(one_row_per_order.campaign_id), '') IS NOT NULL
         AND (
            campaigns.campaign_id IS NULL
            OR one_row_per_order.order_date < campaigns.start_date
            OR one_row_per_order.order_date > campaigns.end_date
         ) THEN 1
        ELSE 0
    END AS campaign_outside_window,
    nullif(trim(one_row_per_order.payment_method), '') AS payment_method,
    one_row_per_order.device,
    one_row_per_order.browser,
    one_row_per_order.status,
    one_row_per_order.shipping_country,
    CAST(one_row_per_order.total_amount AS REAL) AS header_amount_raw,
    one_row_per_order.currency AS currency_raw,
    CASE
        WHEN upper(replace(trim(one_row_per_order.currency), '€', 'EUR')) = 'EUR' THEN 'EUR'
        ELSE upper(trim(one_row_per_order.currency))
    END AS currency
FROM one_row_per_order
LEFT JOIN campaigns_clean AS campaigns
    ON campaigns.campaign_id = nullif(trim(one_row_per_order.campaign_id), '');

-- Keep lines with quantity above zero. Revenue is the price after discount. Contribution is revenue minus supplier cost.

CREATE VIEW order_items_clean AS
SELECT
    priced.*,
    priced.line_revenue_eur - priced.line_cost_eur AS line_contribution_eur
FROM (
    SELECT
        lines.*,
        lines.unit_price_eur * lines.quantity * (1 - lines.discount_pct / 100.0) AS line_revenue_eur,
        lines.unit_cost_eur * lines.quantity AS line_cost_eur
    FROM (
        SELECT
            items.order_id,
            items.product_id,
            products.product_name,
            products.category,
            CAST(items.quantity AS REAL) AS quantity,
            CAST(items.unit_price_eur AS REAL) AS unit_price_eur,
            CAST(items.discount_pct AS REAL) AS discount_pct,
            products.unit_cost_eur
        FROM order_items AS items
        JOIN products_clean AS products
            ON products.product_id = items.product_id
        WHERE CAST(items.quantity AS REAL) > 0
    ) AS lines
) AS priced;


-- Add each order's line totals, and flag whether the header amount matches those lines.

CREATE VIEW orders_clean AS
SELECT
    orders.order_id,
    orders.customer_id,
    orders.order_date,
    orders.campaign_id_raw,
    orders.campaign_id,
    orders.campaign_outside_window,
    orders.payment_method,
    orders.device,
    orders.browser,
    orders.status,
    orders.shipping_country,
    orders.header_amount_raw,
    orders.currency_raw,
    orders.currency,
    CASE
        WHEN line_totals.order_id IS NULL THEN 'no_valid_lines'
        WHEN abs(line_totals.line_revenue_eur - orders.header_amount_raw) <= 0.05 THEN 'match'
        WHEN orders.header_amount_raw < 0
         AND abs(line_totals.line_revenue_eur - abs(orders.header_amount_raw)) <= 0.05 THEN 'sign_flip'
        ELSE 'mismatch'
    END AS amount_check,
    coalesce(line_totals.line_revenue_eur, 0) AS line_revenue_eur,
    coalesce(line_totals.line_cost_eur, 0) AS line_cost_eur,
    coalesce(line_totals.line_contribution_eur, 0) AS line_contribution_eur
FROM orders_base AS orders
LEFT JOIN (
    SELECT
        order_id,
        sum(line_revenue_eur) AS line_revenue_eur,
        sum(line_cost_eur) AS line_cost_eur,
        sum(line_contribution_eur) AS line_contribution_eur
    FROM order_items_clean
    GROUP BY order_id
) AS line_totals
    ON line_totals.order_id = orders.order_id;

-- Item lines that belong to an order kept above, with category attached.

CREATE VIEW order_lines_clean AS
SELECT
    items.order_id,
    items.product_id,
    items.product_name,
    items.category,
    items.quantity,
    items.unit_price_eur,
    items.discount_pct,
    items.line_revenue_eur,
    items.unit_cost_eur,
    items.line_cost_eur,
    items.line_contribution_eur
FROM order_items_clean AS items
JOIN orders_clean AS orders
    ON orders.order_id = items.order_id;

-- Keep every ticket. A blank resolution time stays empty and is left out of any average.

CREATE VIEW support_tickets_clean AS
SELECT
    tickets.ticket_id,
    tickets.customer_id,
    tickets.order_id,
    tickets.created_at,
    tickets.topic,
    tickets.channel,
    tickets.agent_id,
    CAST(nullif(trim(tickets.resolution_hours), '') AS REAL) AS resolution_hours,
    CAST(tickets.satisfaction_score AS REAL) AS satisfaction_score,
    CASE WHEN orders.order_id IS NOT NULL THEN 1 ELSE 0 END AS order_in_clean_orders
FROM support_tickets AS tickets
LEFT JOIN orders_clean AS orders
    ON orders.order_id = tickets.order_id;