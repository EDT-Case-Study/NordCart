"""Load the CSVs into SQLite and run the SQL files.

Open this file and press the Run button at the top right.
The same SQL can be pasted into a SQLite editor in the browser after the
six CSVs have been imported as customers, products, campaigns, orders,
order_items, and support_tickets. Run sql/01_cleaning.sql first, then
sql/02_campaign_result.sql, in the same session.
"""

import csv
import os
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SQL_FILES = [
    ROOT / "sql" / "01_cleaning.sql",
    ROOT / "sql" / "02_campaign_result.sql",
]
TABLES = {
    "customers": ROOT / "data" / "customers.csv",
    "products": ROOT / "data" / "products.csv",
    "campaigns": ROOT / "data" / "campaigns.csv",
    "orders": ROOT / "data" / "orders.csv",
    "order_items": ROOT / "data" / "order_items.csv",
    "support_tickets": ROOT / "data" / "support_tickets.csv",
}


# Load one CSV into a table and stop if any data row is missing.
def load_csv(connection, table_name, path):
    with path.open(newline="") as handle:
        reader = csv.reader(handle)
        header = next(reader)
        rows = [row for row in reader if row]
        columns = ", ".join(f'"{name}" TEXT' for name in header)
        placeholders = ", ".join(["?"] * len(header))
        connection.execute(f"DROP TABLE IF EXISTS {table_name}")
        connection.execute(f"CREATE TABLE {table_name} ({columns})")
        connection.executemany(
            f"INSERT INTO {table_name} VALUES ({placeholders})",
            rows,
        )
    loaded = connection.execute(f"SELECT COUNT(*) FROM {table_name}").fetchone()[0]
    if loaded != len(rows):
        raise RuntimeError(
            f"{table_name}: loaded {loaded} rows from {len(rows)} CSV rows"
        )
    print(f"{table_name}: {loaded} rows loaded")


# Split a script on semicolons, leaving comments and quoted text intact.
def split_sql(text):
    statements = []
    current = []
    in_string = False
    in_comment = False
    index = 0
    while index < len(text):
        character = text[index]
        if in_comment:
            current.append(character)
            if character == "\n":
                in_comment = False
            index += 1
            continue
        if in_string:
            current.append(character)
            if character == "'":
                if index + 1 < len(text) and text[index + 1] == "'":
                    current.append("'")
                    index += 2
                    continue
                in_string = False
            index += 1
            continue
        if character == "-" and index + 1 < len(text) and text[index + 1] == "-":
            in_comment = True
            current.append(character)
            index += 1
            continue
        if character == "'":
            in_string = True
            current.append(character)
            index += 1
            continue
        if character == ";":
            statement = "".join(current).strip()
            if statement:
                statements.append(statement)
            current = []
            index += 1
            continue
        current.append(character)
        index += 1
    tail = "".join(current).strip()
    if tail:
        statements.append(tail)
    return statements


# Run every statement and print each full result table.
def run_file(connection, path):
    print("=" * 60)
    print(path.relative_to(ROOT))
    text = path.read_text().strip()
    if not text:
        print("This file is empty. Add a query, then press Run again.")
        return

    statements = split_sql(text)
    if not statements:
        print("No query found in this file.")
        return

    printed_table = False
    for number, statement in enumerate(statements, start=1):
        cursor = connection.execute(statement)
        if cursor.description is None:
            continue
        columns = [column[0] for column in cursor.description]
        rows = cursor.fetchall()
        if not rows:
            continue
        printed_table = True
        print(f"Query {number}: {len(rows)} rows")
        print(" | ".join(columns))
        for row in rows:
            print(" | ".join("" if value is None else str(value) for value in row))

    if not printed_table:
        print("Ran. No result table to show.")


# Load all six CSVs, then run cleaning and the campaign results on that data.
def main():
    os.chdir(ROOT)
    connection = sqlite3.connect(":memory:")
    for table_name, path in TABLES.items():
        load_csv(connection, table_name, path)
    for path in SQL_FILES:
        run_file(connection, path)
    connection.close()


if __name__ == "__main__":
    main()
