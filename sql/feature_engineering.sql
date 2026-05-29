USE olist_dump;

-- =========================================================
-- ADVANCED CHURN PREDICTION DATASET
-- 365-DAY SNAPSHOT + STRONG FEATURE ENGINEERING
-- =========================================================

WITH snapshot AS (
    SELECT
        MAX(order_purchase_timestamp) AS max_dt,
        MAX(order_purchase_timestamp) - INTERVAL 365 DAY AS snapshot_date
    FROM orders
),

-- =========================================================
-- PAYMENT AGGREGATION
-- =========================================================
payment_agg AS (
    SELECT
        order_id,
        SUM(payment_value) AS total_payment,
        AVG(payment_installments) AS avg_installments
    FROM order_payments
    GROUP BY order_id
),

-- =========================================================
-- REVIEW AGGREGATION
-- =========================================================
review_agg AS (
    SELECT
        order_id,
        AVG(review_score) AS avg_review_score
    FROM order_reviews
    GROUP BY order_id
),

-- =========================================================
-- ITEM AGGREGATION
-- =========================================================
item_agg AS (
    SELECT
        oi.order_id,
        COUNT(*) AS total_items,
        COUNT(DISTINCT oi.product_id) AS unique_products,
        COUNT(DISTINCT p.product_category_name) AS unique_categories
    FROM order_items oi
    LEFT JOIN products p 
        ON oi.product_id = p.product_id
    GROUP BY oi.order_id
),

-- =========================================================
-- ORDER LEVEL TABLE (ONE ROW = ONE ORDER)
-- =========================================================
order_level AS (
    SELECT
        o.order_id,
        o.customer_id,
        o.order_purchase_timestamp,
        o.order_delivered_customer_date,
        o.order_estimated_delivery_date,
        COALESCE(pa.total_payment, 0) AS payment_value,
        COALESCE(pa.avg_installments, 0) AS avg_installments,
        COALESCE(ra.avg_review_score, 0) AS review_score,
        COALESCE(ia.total_items, 0) AS total_items,
        COALESCE(ia.unique_products, 0) AS unique_products,
        COALESCE(ia.unique_categories, 0) AS unique_categories,
        DATEDIFF(o.order_delivered_customer_date, o.order_estimated_delivery_date) AS delivery_delay
    FROM orders o
    LEFT JOIN payment_agg pa ON o.order_id = pa.order_id
    LEFT JOIN review_agg ra  ON o.order_id = ra.order_id
    LEFT JOIN item_agg ia    ON o.order_id = ia.order_id
    WHERE o.order_status = 'delivered'
),

-- =========================================================
-- CUSTOMER FEATURES (ONLY PAST DATA BEFORE SNAPSHOT)
-- =========================================================
customer_features AS (
    SELECT
        c.customer_unique_id,

        -- Basic RFM
        DATEDIFF(MAX(s.snapshot_date), MAX(o.order_purchase_timestamp)) AS recency,
        COUNT(DISTINCT o.order_id) AS frequency,
        SUM(o.payment_value) AS monetary,

        -- Customer Time Features
        MIN(o.order_purchase_timestamp) AS first_order_date,
        MAX(o.order_purchase_timestamp) AS last_order_date,
        DATEDIFF(MAX(o.order_purchase_timestamp), MIN(o.order_purchase_timestamp)) AS customer_lifetime_days,
        DATEDIFF(MAX(s.snapshot_date), MIN(o.order_purchase_timestamp)) AS days_since_first_purchase,

        -- Recent Activity Windows
        COUNT(DISTINCT CASE WHEN o.order_purchase_timestamp > s.snapshot_date - INTERVAL 7 DAY THEN o.order_id END) AS orders_last_7_days,
        COUNT(DISTINCT CASE WHEN o.order_purchase_timestamp > s.snapshot_date - INTERVAL 30 DAY THEN o.order_id END) AS orders_last_30_days,
        COUNT(DISTINCT CASE WHEN o.order_purchase_timestamp > s.snapshot_date - INTERVAL 90 DAY THEN o.order_id END) AS orders_last_90_days,
        COUNT(DISTINCT CASE WHEN o.order_purchase_timestamp > s.snapshot_date - INTERVAL 180 DAY THEN o.order_id END) AS orders_last_180_days,

        -- Recent Spending
        SUM(CASE WHEN o.order_purchase_timestamp > s.snapshot_date - INTERVAL 30 DAY THEN o.payment_value ELSE 0 END) AS monetary_last_30_days,
        SUM(CASE WHEN o.order_purchase_timestamp > s.snapshot_date - INTERVAL 90 DAY THEN o.payment_value ELSE 0 END) AS monetary_last_90_days,

        -- Order Value Features
        AVG(o.payment_value) AS avg_order_value,
        MAX(o.payment_value) AS max_order_value,
        MIN(o.payment_value) AS min_order_value,

        -- Product Features
        SUM(o.total_items) AS total_items,
        AVG(o.total_items) AS avg_items_per_order,
        SUM(o.unique_products) AS total_unique_products,
        SUM(o.unique_categories) AS total_unique_categories,

        -- Review Features
        AVG(o.review_score) AS avg_review_score,
        MIN(o.review_score) AS min_review_score,
        COUNT(CASE WHEN o.review_score <= 2 THEN 1 END) * 1.0 / NULLIF(COUNT(o.order_id), 0) AS low_review_ratio,

        -- Delivery Features
        AVG(o.delivery_delay) AS avg_delivery_delay,
        MAX(o.delivery_delay) AS max_delivery_delay,
        COUNT(CASE WHEN o.delivery_delay > 0 THEN 1 END) * 1.0 / NULLIF(COUNT(o.order_id), 0) AS late_delivery_ratio,

        -- Payment Features
        AVG(o.avg_installments) AS avg_installments,

        -- Behavior Features
        COUNT(CASE WHEN WEEKDAY(o.order_purchase_timestamp) IN (5, 6) THEN 1 END) * 1.0 / NULLIF(COUNT(o.order_id), 0) AS weekend_order_ratio

    FROM customers c
    CROSS JOIN snapshot s
    LEFT JOIN order_level o 
        ON c.customer_id = o.customer_id
        AND o.order_purchase_timestamp <= s.snapshot_date
    GROUP BY c.customer_unique_id
    HAVING COUNT(DISTINCT o.order_id) > 0
),

-- =========================================================
-- ADVANCED DERIVED FEATURES
-- =========================================================
advanced_features AS (
    SELECT
        *,
        -- Avg Days Between Orders
        CASE 
            WHEN frequency > 1 THEN customer_lifetime_days * 1.0 / (frequency - 1)
            ELSE NULL 
        END AS avg_days_between_orders,

        -- Purchase Velocity
        CASE 
            WHEN customer_lifetime_days > 0 THEN frequency * 30.0 / customer_lifetime_days
            ELSE frequency 
        END AS orders_per_month,

        -- Spending Velocity
        CASE 
            WHEN customer_lifetime_days > 0 THEN monetary * 30.0 / customer_lifetime_days
            ELSE monetary 
        END AS spend_per_month,

        -- Recency Ratio
        CASE 
            WHEN customer_lifetime_days > 0 THEN recency * 1.0 / customer_lifetime_days
            ELSE NULL 
        END AS recency_ratio,

        -- Purchase Acceleration / Ratios
        orders_last_30_days * 1.0 / NULLIF(frequency, 0) AS purchase_acceleration,
        monetary_last_30_days * 1.0 / NULLIF(monetary, 0) AS recent_spend_ratio,
        monetary * 1.0 / NULLIF(total_items, 0) AS monetary_per_item
    FROM customer_features
),

-- =========================================================
-- CHURN LABEL (1 = CHURNED, 0 = ACTIVE)
-- =========================================================
churn_labels AS (
    SELECT
        c.customer_unique_id,
        CASE 
            WHEN COUNT(DISTINCT o.order_id) = 0 THEN 1
            ELSE 0 
        END AS churn_label
    FROM customers c
    CROSS JOIN snapshot s
    LEFT JOIN orders o 
        ON c.customer_id = o.customer_id
        AND o.order_status = 'delivered'
        AND o.order_purchase_timestamp > s.snapshot_date
        AND o.order_purchase_timestamp <= s.max_dt
    GROUP BY c.customer_unique_id
)

-- =========================================================
-- FINAL DATASET ASSEMBLY
-- =========================================================
SELECT
    af.*,
    cl.churn_label
FROM advanced_features af
JOIN churn_labels cl 
    ON af.customer_unique_id = cl.customer_unique_id;