# NordCart

The recommendation for the Head of Marketing is in [ANSWER.md](ANSWER.md). How the figures were produced is in [REPORT.md](REPORT.md).

## Run

Python 3 is enough. No packages to install.

```bash
python3 run_sql.py
```

That loads the six CSVs in `data/` and runs `sql/01_cleaning.sql`, then `sql/02_campaign_result.sql`.
