# SQL Schema Notes

This document summarizes the relational structure and the feature-engineering logic used to build the customer retention dataset.

## Core Source Tables

The SQL pipeline in `feature_engineering.sql` relies on the following Olist tables:

- `customers` — maps each customer to a unique customer identifier
- `orders` — contains order timestamps, status, and delivery dates
- `order_items` — links orders to products and quantities
- `products` — stores product category details
- `order_payments` — stores payment amounts and payment installment information
- `order_reviews` — stores review scores for delivered orders

## Feature Engineering Flow

1. Build order-level aggregates
   - payment totals
   - average installment count
   - review score averages
   - item counts and product diversity

2. Create a 365-day customer snapshot
   - uses the latest purchase timestamp as the business cutoff
   - only uses historical information available before the snapshot date

3. Generate customer-level features
   - RFM-style behavior: recency, frequency, monetary
   - recency windows: last 7, 30, 90, 180 days
   - delivery quality: late delivery ratio, average delay, max delay
   - review quality: average review score, low review ratio
   - purchase velocity and spend velocity measures

4. Create the retention target
   - `churn_label = 1` if the customer places no future delivered order in the observation window
   - `churn_label = 0` otherwise

## Important Design Decisions

- Only delivered orders are included in the order-level feature table.
- The snapshot uses a rolling historical window to avoid data leakage.
- Customer features are aggregated at the customer-unique-id level.
- The downstream dataset is stored as `data/processed/customer_features.csv`.

## Suggested Interpretation

The most important business signals are usually:

- recency and frequency
- recent spending trends
- late delivery ratio
- average review score
- customer lifetime span

These variables are highly relevant for retention campaigns because they capture both customer engagement and service quality.
