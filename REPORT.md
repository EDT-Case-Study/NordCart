# What I did, and why

## How I worked

1. I read the question first: should next year's campaign budget stay as it is.
2. I then looked through the dataset for data-quality problems, the columns that join the tables, and the changes needed to answer the question. I wrote those points down before writing any queries.
3. I gave the task, the CSV files, and that full analysis to an AI assistant, and asked it to say what I had missed or got wrong. It corrected a few points, and it flagged quality issues that are easy to skip while scanning the files, such as spaces in `EUR` and negative ages.
4. I went back to the data, checked those issues myself, and wrote the queries. I used the AI again to tighten some of them and to fix a few syntax points.
5. I ran the queries in an online SQL editor, checked the outputs there, and exported the results from that editor (https://kitolity.com/widgets/sqlite-playground).
6. `run_sql.py` was written entirely by the AI, so the recruitment team can rerun the queries without setup problems.

The figures in `ANSWER.md` come from those queries.

The question is whether next year's campaign budget should stay as it is. I answered it from completed orders linked to each campaign, not from how many people signed up.

## Profit

For a completed order, revenue is the item lines after discount:

`unit price × quantity × (1 − discount / 100)`

Supplier cost is today's `unit_cost_eur` times quantity, not the cost on the day of the order. Profit is revenue minus that cost. The campaign result is that profit minus `budget_eur`, once per campaign.

Cancelled orders are excluded. Returned orders are excluded from the main result and shown beside it. Their amounts in the file are still positive, so the status is what says the money came back.

`orders.total_amount` is checked against the lines and then set aside. Where the header matches, the lines are the same number. Where the header is the line total with the sign flipped, the positive line total is used. Where they still disagree, the lines are used.

## Cleaning

`sql/01_cleaning.sql` builds the views. The rules are:

- Customers: one row per id. Signup dates in `2024-07-01`, `01.07.2024`, and `07/01/2024` are all read. Age outside 10–100, including blanks, −1, 0, 132, and 999, is cleared. Country labels such as DE, Deutschland, and Holland are mapped to one name.
- Products: a blank category is filled from the name prefix (`HOME-` is Home).
- Orders: exact duplicate headers are collapsed. Orders dated `2019-01-01` are outside the July 2024–June 2026 export and some carry a 2025 campaign id, so they are removed. Currency spellings are all treated as EUR. A campaign tag whose order date falls outside that campaign is cleared.
- Lines: quantity of 0 or below is dropped. Two identical lines on one order are kept, because the order header equals the sum of both.
- Support tickets stay available for a side check. Blank resolution times are left empty.

Favourite colour and zodiac sign are on the customer file and are not used. They do not inform the budget.

## Campaign queries

`sql/02_campaign_result.sql` reads those views.

- Campaign totals, and each campaign's result.
- Return rate, discount rate, and whether the order was the customer's first order. Discount rate is discount euros divided by the value before discount, so a cheap line does not count the same as an expensive one.
- Completed sales in the same dates with no campaign tag. Those dates overlap, so that column is not added up across campaigns.
- The repeated campaigns: Back to Uni, Black Friday, and the two spring campaigns.
- The largest category on each campaign.
- Tickets per 100 orders.

The rates and the result (`profit − budget`) are calculated once, on `campaign_result`, and the later queries only read them.

## Tools

Python 3 and SQLite, both already on the machine. No extra packages. `run_sql.py` loads every row of the six CSVs, then runs `sql/01_cleaning.sql` and `sql/02_campaign_result.sql`.
