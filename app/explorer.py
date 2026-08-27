"""Rental analytics explorer.

A local web app over data/dev.duckdb: run SQL against the built project and
chart the result. Spin up from the repo root (the staging views resolve the
CSVs relative to the working directory):

    pip install -r app/requirements.txt
    streamlit run app/explorer.py

Connections are opened read-only and per query, so the app cannot write to
the database and only holds the file lock for the duration of a query --
`dbt build` keeps working while the app is open, as long as they don't run
in the same instant.
"""

from pathlib import Path

import altair as alt
import duckdb
import pandas as pd
import streamlit as st

DB_PATH = Path("data/dev.duckdb")

# Preset queries, written against the marts the way an analyst would write
# them. The first three mirror analyses/01-03; the SQL is repeated here
# rather than read from target/compiled so the app has no dbt dependency.
PRESETS = {
    "Monthly revenue by air conditioning (problem 1)": """\
select
    strftime(month_start_date, '%Y-%m') as month,
    case when has_air_conditioning then 'With AC' else 'Without AC' end as ac_segment,
    sum(revenue) as revenue,
    round(
        100.0 * sum(revenue) / sum(sum(revenue)) over (partition by month_start_date),
        1
    ) as pct_of_month_revenue,
    any_value(is_complete_month) as is_complete_month
from main.listing_days
group by month_start_date, has_air_conditioning
order by month, ac_segment
""",
    "Neighborhood price increase (problem 2)": """\
with listing_endpoints as (
    select
        listing_id,
        neighborhood,
        max(case when calendar_date = date '2021-07-12' then nightly_price end) as price_at_start,
        max(case when calendar_date = date '2022-07-11' then nightly_price end) as price_at_end
    from main.listing_days
    where has_listing_record
    group by 1, 2
)
select
    neighborhood,
    count(*) as listings,
    round(avg(price_at_end - price_at_start), 2) as avg_price_increase
from listing_endpoints
where price_at_start is not null and price_at_end is not null
group by 1
order by avg_price_increase desc
""",
    "Longest possible stay: lockbox + first aid kit (problem 3)": """\
select
    listing_id,
    any_value(neighborhood) as neighborhood,
    max(max_bookable_nights) as longest_possible_stay_nights
from main.listing_days
where has_lockbox and has_first_aid_kit and max_bookable_nights is not null
group by 1
order by longest_possible_stay_nights desc
""",
    "Monthly revenue and occupancy": """\
select
    strftime(month_start_date, '%Y-%m') as month,
    sum(revenue) as revenue,
    round(100.0 * avg(is_reserved::int), 1) as occupancy_pct,
    any_value(is_complete_month) as is_complete_month
from main.listing_days
group by month_start_date
order by month
""",
    "Revenue and occupancy by neighborhood": """\
select
    neighborhood,
    count(distinct listing_id) as listings,
    sum(revenue) as revenue,
    round(100.0 * avg(is_reserved::int), 1) as occupancy_pct
from main.listing_days
group by 1
order by revenue desc
""",
    "Stays: length and revenue per booking": """\
select
    listing_id, reservation_id, neighborhood,
    first_night, reservation_nights, weekend_nights,
    reservation_revenue, average_nightly_price, is_truncated_by_calendar
from main.reservations
order by reservation_nights desc
""",
    "Host portfolios": """\
select
    host_id, host_name, listings_count, neighborhoods_count,
    neighborhoods, occupancy_rate, revenue_in_calendar, average_review_score
from main.hosts
order by revenue_in_calendar desc
""",
    "Listings overview": """\
select
    listing_id, listing_name, neighborhood, property_type, room_type,
    accommodates, price_at_calendar_start, price_currency, amenity_count,
    has_air_conditioning, has_lockbox, has_first_aid_kit,
    nights_reserved, revenue_in_calendar
from main.listings
order by revenue_in_calendar desc
""",
}

CHART_TYPES = {"Bar": "bar", "Line": "line", "Area": "area", "Scatter": "circle"}


def run_query(sql: str) -> pd.DataFrame:
    """Execute one statement on a short-lived read-only connection."""
    with duckdb.connect(str(DB_PATH), read_only=True) as con:
        return con.execute(sql).df()


def list_tables() -> pd.DataFrame:
    return run_query("""
        select table_schema as schema, table_name as name,
               case table_type when 'BASE TABLE' then 'table' else 'view' end as type
        from information_schema.tables
        order by schema != 'main', schema, name
    """)


st.set_page_config(page_title="Rental analytics explorer", page_icon="🏠", layout="wide")
st.title("Rental analytics explorer")

if not DB_PATH.exists():
    st.error("`data/dev.duckdb` not found. Run `dbt build` from the repo root first.")
    st.stop()
if not Path("data/LISTINGS.csv").exists():
    st.error("Start the app from the repo root: the staging views resolve the CSVs "
             "relative to the working directory.")
    st.stop()

# ---- sidebar: presets and schema browser -----------------------------------
with st.sidebar:
    st.header("Queries")
    preset = st.selectbox("Preset", ["(custom)"] + list(PRESETS))
    st.header("Tables")
    st.caption("`main` is the analyst contract; the other schemas are the "
               "layers behind it.")
    try:
        st.dataframe(list_tables(), hide_index=True, height=310)
    except Exception as exc:  # the DB may be mid-rebuild
        st.warning(f"Could not list tables: {exc}")

# ---- main: editor, results, chart ------------------------------------------
default_sql = PRESETS.get(preset, "select * from main.listing_days limit 100")
sql = st.text_area("SQL (read-only connection)", value=default_sql, height=220)

if st.button("Run", type="primary") or sql.strip():
    try:
        df = run_query(sql)
    except Exception as exc:
        st.error(str(exc))
        st.stop()

    st.caption(f"{len(df):,} rows × {len(df.columns)} columns")
    st.dataframe(df, hide_index=True, width="stretch")
    st.download_button("Download CSV", df.to_csv(index=False), "result.csv", "text/csv")

    numeric_cols = [c for c in df.columns if pd.api.types.is_numeric_dtype(df[c])]
    if not df.empty and numeric_cols:
        st.subheader("Chart")
        c1, c2, c3, c4 = st.columns(4)
        chart_type = c1.selectbox("Type", list(CHART_TYPES))
        x_col = c2.selectbox("X", list(df.columns))
        y_col = c3.selectbox("Y", numeric_cols)
        color_col = c4.selectbox("Series", ["(none)"] + list(df.columns))

        encoding = {
            "x": alt.X(x_col, sort=None),
            "y": alt.Y(y_col),
            "tooltip": list(df.columns),
        }
        if color_col != "(none)":
            encoding["color"] = alt.Color(color_col)

        mark = getattr(alt.Chart(df), f"mark_{CHART_TYPES[chart_type]}")()
        st.altair_chart(mark.encode(**encoding), use_container_width=True)
