-- Drop the result views so this file can be run again after cleaning.
DROP VIEW IF EXISTS campaign_result;
DROP VIEW IF EXISTS orders_with_first_flag;

-- Mark each customer's earliest kept order, of any status.

CREATE VIEW orders_with_first_flag AS
SELECT
    orders.*,
    CASE
        WHEN row_number() OVER (
            PARTITION BY customer_id
            ORDER BY order_date, order_id
        ) = 1 THEN 1
        ELSE 0
    END AS is_first_order
FROM orders_clean AS orders;


-- Profit after supplier cost, minus the campaign budget once. Completed orders only.

CREATE VIEW campaign_result AS
WITH order_stats AS (
    SELECT
        campaign_id,
        sum(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) AS completed_orders,
        sum(CASE WHEN status = 'returned' THEN 1 ELSE 0 END) AS returned_orders,
        sum(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END) AS cancelled_orders,
        coalesce(sum(CASE WHEN status = 'completed' THEN line_revenue_eur END), 0) AS revenue_eur,
        coalesce(sum(CASE WHEN status = 'completed' THEN line_cost_eur END), 0) AS product_cost_eur,
        coalesce(sum(CASE WHEN status = 'completed' THEN line_contribution_eur END), 0) AS contribution_eur,
        coalesce(sum(CASE WHEN status IN ('completed', 'returned') THEN line_contribution_eur END), 0) AS contribution_including_returns_eur,
        sum(CASE WHEN status = 'completed' AND is_first_order = 1 THEN 1 ELSE 0 END) AS first_completed_orders,
        sum(CASE WHEN status = 'completed' AND is_first_order = 0 THEN 1 ELSE 0 END) AS later_completed_orders
    FROM orders_with_first_flag
    GROUP BY campaign_id
),
-- Discount euros on completed lines, weighted by the value before discount.
discount_stats AS (
    SELECT
        orders.campaign_id,
        coalesce(sum(lines.unit_price_eur * lines.quantity), 0) AS list_value_eur,
        coalesce(sum(lines.unit_price_eur * lines.quantity * lines.discount_pct / 100.0), 0) AS discount_eur
    FROM order_lines_clean AS lines
    JOIN orders_clean AS orders
        ON orders.order_id = lines.order_id
    WHERE orders.status = 'completed'
    GROUP BY orders.campaign_id
),
-- Completed revenue in each campaign's dates that carries no campaign tag.
window_stats AS (
    SELECT
        campaigns.campaign_id,
        coalesce(sum(unattributed.line_revenue_eur), 0) AS other_completed_revenue_eur
    FROM campaigns_clean AS campaigns
    LEFT JOIN orders_clean AS unattributed
        ON unattributed.campaign_id IS NULL
       AND unattributed.status = 'completed'
       AND unattributed.order_date BETWEEN campaigns.start_date AND campaigns.end_date
    GROUP BY campaigns.campaign_id
),
-- One row per campaign: budget, orders, discount, and untagged revenue in the same dates.
per_campaign AS (
    SELECT
        'campaign' AS row_type,
        campaigns.campaign_id,
        campaigns.campaign_name,
        campaigns.channel,
        campaigns.start_date,
        campaigns.end_date,
        campaigns.budget_eur,
        coalesce(order_stats.completed_orders, 0) AS completed_orders,
        coalesce(order_stats.returned_orders, 0) AS returned_orders,
        coalesce(order_stats.cancelled_orders, 0) AS cancelled_orders,
        coalesce(order_stats.revenue_eur, 0) AS revenue_eur,
        coalesce(order_stats.product_cost_eur, 0) AS product_cost_eur,
        coalesce(order_stats.contribution_eur, 0) AS contribution_eur,
        coalesce(order_stats.contribution_including_returns_eur, 0) AS contribution_including_returns_eur,
        coalesce(order_stats.first_completed_orders, 0) AS first_completed_orders,
        coalesce(order_stats.later_completed_orders, 0) AS later_completed_orders,
        coalesce(discount_stats.discount_eur, 0) AS discount_eur,
        coalesce(discount_stats.list_value_eur, 0) AS list_value_eur,
        coalesce(window_stats.other_completed_revenue_eur, 0) AS other_completed_revenue_during_campaign_eur
    FROM campaigns_clean AS campaigns
    LEFT JOIN order_stats
        ON order_stats.campaign_id = campaigns.campaign_id
    LEFT JOIN discount_stats
        ON discount_stats.campaign_id = campaigns.campaign_id
    LEFT JOIN window_stats
        ON window_stats.campaign_id = campaigns.campaign_id
),
-- Add one total row for all campaigns, and one row for orders with no campaign tag.
combined AS (
    SELECT * FROM per_campaign

    UNION ALL

    SELECT
        'all_campaigns' AS row_type,
        'ALL' AS campaign_id,
        'All campaigns' AS campaign_name,
        NULL AS channel,
        NULL AS start_date,
        NULL AS end_date,
        sum(budget_eur) AS budget_eur,
        sum(completed_orders) AS completed_orders,
        sum(returned_orders) AS returned_orders,
        sum(cancelled_orders) AS cancelled_orders,
        sum(revenue_eur) AS revenue_eur,
        sum(product_cost_eur) AS product_cost_eur,
        sum(contribution_eur) AS contribution_eur,
        sum(contribution_including_returns_eur) AS contribution_including_returns_eur,
        sum(first_completed_orders) AS first_completed_orders,
        sum(later_completed_orders) AS later_completed_orders,
        sum(discount_eur) AS discount_eur,
        sum(list_value_eur) AS list_value_eur,
        NULL AS other_completed_revenue_during_campaign_eur
    FROM per_campaign

    UNION ALL

    SELECT
        'no_campaign' AS row_type,
        NULL AS campaign_id,
        'No campaign' AS campaign_name,
        NULL AS channel,
        NULL AS start_date,
        NULL AS end_date,
        0 AS budget_eur,
        coalesce(order_stats.completed_orders, 0) AS completed_orders,
        coalesce(order_stats.returned_orders, 0) AS returned_orders,
        coalesce(order_stats.cancelled_orders, 0) AS cancelled_orders,
        coalesce(order_stats.revenue_eur, 0) AS revenue_eur,
        coalesce(order_stats.product_cost_eur, 0) AS product_cost_eur,
        coalesce(order_stats.contribution_eur, 0) AS contribution_eur,
        coalesce(order_stats.contribution_including_returns_eur, 0) AS contribution_including_returns_eur,
        coalesce(order_stats.first_completed_orders, 0) AS first_completed_orders,
        coalesce(order_stats.later_completed_orders, 0) AS later_completed_orders,
        coalesce(discount_stats.discount_eur, 0) AS discount_eur,
        coalesce(discount_stats.list_value_eur, 0) AS list_value_eur,
        NULL AS other_completed_revenue_during_campaign_eur
    FROM order_stats
    LEFT JOIN discount_stats
        ON discount_stats.campaign_id IS NULL
       AND order_stats.campaign_id IS NULL
    WHERE order_stats.campaign_id IS NULL
),
-- Result is profit minus budget. A rate of 0.10 means 10 percent.
scored AS (
    SELECT
        combined.*,
        contribution_eur - budget_eur AS result_eur,
        contribution_including_returns_eur - budget_eur AS result_if_returns_counted_eur,
        returned_orders * 1.0 / nullif(completed_orders + returned_orders, 0) AS return_rate,
        discount_eur * 1.0 / nullif(list_value_eur, 0) AS discount_rate,
        first_completed_orders * 1.0 / nullif(completed_orders, 0) AS first_order_share,
        contribution_eur * 1.0 / nullif(budget_eur, 0) AS contribution_per_eur_spent
    FROM combined
)
SELECT
    scored.*,
    CASE
        WHEN row_type = 'no_campaign' THEN 'base business, no campaign budget'
        WHEN result_eur >= 0 THEN 'attributed contribution covers the budget'
        ELSE 'attributed contribution is below the budget'
    END AS budget_result,
    CASE
        WHEN row_type = 'no_campaign' THEN NULL
        WHEN result_eur >= 0 AND result_if_returns_counted_eur >= 0 THEN 'still covers the budget'
        WHEN result_eur < 0 AND result_if_returns_counted_eur < 0 THEN 'still below the budget'
        ELSE 'the answer versus the budget changes'
    END AS if_returns_are_counted
FROM scored;


-- All campaigns next to orders with no campaign tag.

SELECT
    campaign_name,
    round(budget_eur, 2) AS budget_eur,
    completed_orders,
    round(revenue_eur, 2) AS revenue_eur,
    round(product_cost_eur, 2) AS product_cost_eur,
    round(contribution_eur, 2) AS contribution_eur,
    round(result_eur, 2) AS result_eur,
    budget_result
FROM campaign_result
WHERE row_type IN ('all_campaigns', 'no_campaign')
ORDER BY row_type;


-- Each campaign, worst result first. Profit per euro below 1 does not cover the budget.

SELECT
    campaign_id,
    campaign_name,
    channel,
    start_date,
    end_date,
    round(budget_eur, 2) AS budget_eur,
    completed_orders,
    round(revenue_eur, 2) AS revenue_eur,
    round(product_cost_eur, 2) AS product_cost_eur,
    round(contribution_eur, 2) AS contribution_eur,
    round(result_eur, 2) AS result_eur,
    round(contribution_per_eur_spent, 2) AS contribution_per_eur_spent,
    budget_result
FROM campaign_result
WHERE row_type = 'campaign'
ORDER BY result_eur;


-- Return rate, discount rate, and the share of completed orders that were a customer's first order.

SELECT
    campaign_id,
    campaign_name,
    completed_orders,
    returned_orders,
    round(return_rate, 4) AS return_rate,
    round(discount_rate, 4) AS discount_rate,
    first_completed_orders,
    later_completed_orders,
    round(first_order_share, 4) AS first_order_share,
    round(result_if_returns_counted_eur, 2) AS result_if_returns_counted_eur,
    if_returns_are_counted
FROM campaign_result
WHERE row_type IN ('campaign', 'no_campaign', 'all_campaigns')
ORDER BY
    CASE row_type
        WHEN 'all_campaigns' THEN 0
        WHEN 'no_campaign' THEN 1
        ELSE 2
    END,
    campaign_id;


-- Tagged completed revenue beside untagged completed revenue in the same dates.

SELECT
    campaign_id,
    campaign_name,
    start_date,
    end_date,
    round(revenue_eur, 2) AS tagged_completed_revenue_eur,
    round(other_completed_revenue_during_campaign_eur, 2) AS untagged_completed_revenue_in_the_same_dates_eur
FROM campaign_result
WHERE row_type = 'campaign'
ORDER BY start_date;


-- Back to Uni, Black Friday, and the two spring campaigns, compared across years.

SELECT
    pairs.series_name,
    result.campaign_id,
    result.campaign_name,
    substr(result.start_date, 1, 4) AS season_year,
    round(result.budget_eur, 2) AS budget_eur,
    result.completed_orders,
    round(result.contribution_eur, 2) AS contribution_eur,
    round(result.result_eur, 2) AS result_eur,
    round(result.return_rate, 4) AS return_rate
FROM (
    SELECT 'Back to Uni' AS series_name, 'C01' AS campaign_id
    UNION ALL
    SELECT 'Back to Uni', 'C10'
    UNION ALL
    SELECT 'Black Friday', 'C02'
    UNION ALL
    SELECT 'Black Friday', 'C11'
    UNION ALL
    SELECT 'Spring', 'C05'
    UNION ALL
    SELECT 'Spring', 'C12'
) AS pairs
JOIN campaign_result AS result
    ON result.campaign_id = pairs.campaign_id
ORDER BY pairs.series_name, result.start_date;


-- Category with the most completed revenue on each campaign.

SELECT
    campaign_name,
    category,
    round(category_revenue_eur, 2) AS category_revenue_eur,
    round(category_revenue_eur * 1.0 / nullif(campaign_revenue_eur, 0), 4) AS share_of_campaign_revenue
FROM (
    SELECT
        coalesce(campaigns.campaign_name, 'No campaign') AS campaign_name,
        lines.category,
        sum(lines.line_revenue_eur) AS category_revenue_eur,
        sum(sum(lines.line_revenue_eur)) OVER (
            PARTITION BY orders.campaign_id
        ) AS campaign_revenue_eur,
        row_number() OVER (
            PARTITION BY orders.campaign_id
            ORDER BY sum(lines.line_revenue_eur) DESC
        ) AS category_rank
    FROM order_lines_clean AS lines
    JOIN orders_clean AS orders
        ON orders.order_id = lines.order_id
    LEFT JOIN campaigns_clean AS campaigns
        ON campaigns.campaign_id = orders.campaign_id
    WHERE orders.status = 'completed'
    GROUP BY orders.campaign_id, campaigns.campaign_name, lines.category
) AS ranked_categories
WHERE category_rank = 1
ORDER BY campaign_name;


-- Tickets per 100 orders and average satisfaction, including orders with no campaign.

SELECT
    coalesce(campaigns.campaign_name, 'No campaign') AS campaign_name,
    count(DISTINCT orders.order_id) AS orders,
    count(tickets.ticket_id) AS tickets,
    round(
        count(tickets.ticket_id) * 100.0 / nullif(count(DISTINCT orders.order_id), 0),
        1
    ) AS tickets_per_100_orders,
    round(avg(tickets.satisfaction_score), 2) AS avg_satisfaction
FROM orders_clean AS orders
LEFT JOIN support_tickets_clean AS tickets
    ON tickets.order_id = orders.order_id
LEFT JOIN campaigns_clean AS campaigns
    ON campaigns.campaign_id = orders.campaign_id
GROUP BY orders.campaign_id, campaigns.campaign_name
ORDER BY campaign_name;
