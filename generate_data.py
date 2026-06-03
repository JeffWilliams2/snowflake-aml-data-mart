import random
import datetime as dt
import pandas as pd
from faker import Faker

fake = Faker()
random.seed(42)
Faker.seed(42)

N_CUSTOMERS = 500
START = dt.date(2025, 1, 1)
DAYS = 150

# --- customers ---
customers = []
for cid in range(1, N_CUSTOMERS + 1):
    customers.append({
        "customer_id": cid,
        "full_name": fake.name(),
        "ssn": fake.ssn(),
        "dob": fake.date_of_birth(minimum_age=18, maximum_age=85),
        "country": fake.country_code(),
        "branch_id": random.randint(1, 12),
        "kyc_status": random.choice(["VERIFIED", "VERIFIED", "VERIFIED", "PENDING"]),
        "last_modified": fake.date_time_between(start_date="-30d"),
    })

# plant one sanctioned-name match for the watchlist join
customers[0]["full_name"] = "Viktor Petrov"

# --- accounts (1-2 per customer) ---
accounts = []
aid = 1
for c in customers:
    for _ in range(random.randint(1, 2)):
        accounts.append({
            "account_id": aid,
            "customer_id": c["customer_id"],
            "account_type": random.choice(["CHECKING", "SAVINGS"]),
            "open_date": fake.date_between(start_date="-3y"),
            "last_modified": c["last_modified"],
        })
        aid += 1

# --- transactions ---
txns = []
tid = 1

def add_txn(acc, day, amount, ttype, direction):
    global tid
    txns.append({
        "txn_id": tid,
        "account_id": acc,
        "txn_date": START + dt.timedelta(days=day),
        "amount": round(amount, 2),
        "txn_type": ttype,
        "direction": direction,
        "last_modified": dt.datetime.now(),
    })
    tid += 1

for a in accounts:
    for _ in range(random.randint(20, 60)):
        add_txn(
            a["account_id"],
            random.randint(0, DAYS),
            random.uniform(10, 4000),
            random.choice(["CARD", "ACH", "WIRE", "CASH"]),
            random.choice(["DEBIT", "CREDIT"]),
        )

# structuring pattern: 5 cash deposits of ~$2,500 on the same day for a few accounts
for a in random.sample(accounts, 6):
    day = random.randint(0, DAYS)
    for _ in range(5):
        add_txn(a["account_id"], day, random.uniform(2200, 2900), "CASH", "CREDIT")

# --- OFAC-style watchlist ---
watchlist = pd.DataFrame([
    {"name": "Viktor Petrov", "list_source": "OFAC SDN"},
    {"name": "Acme Shell Corp", "list_source": "OFAC SDN"},
])

# --- write parquet files ---
df_customers = pd.DataFrame(customers)
df_accounts = pd.DataFrame(accounts)
df_txns = pd.DataFrame(txns)

df_customers.to_parquet("customers.parquet", index=False)
df_accounts.to_parquet("accounts.parquet", index=False)
df_txns.to_parquet("transactions.parquet", index=False)
watchlist.to_parquet("watchlist.parquet", index=False)

print(f"{len(df_customers)} customers")
print(f"{len(df_accounts)} accounts")
print(f"{len(df_txns)} transactions")
print(f"{len(watchlist)} watchlist entries")
print("Files written: customers.parquet, accounts.parquet, transactions.parquet, watchlist.parquet")
