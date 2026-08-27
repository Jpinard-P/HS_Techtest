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
from code_editor import code_editor

DB_PATH = Path("data/dev.duckdb")

# Preset queries, written against the marts the way an analyst would write
# them. The first three are the brief's business problems, named as the brief
# names them, and mirror analyses/01-03; the SQL is repeated here rather than
# read from target/compiled so the app has no dbt dependency. Dict order is
# display order: the three problems first, everything else below a divider.
PRESETS = {
    "1 — Amenity Revenue": """\
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
    "2 — Neighborhood Pricing": """\
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
    "3 — Long Stay / Picky Renter": """\
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

# Per-preset chart defaults: sensible starting axes so each business problem
# opens already charted the way it reads best. None means table-first -- the
# preset's answer is a number to look up, not a shape to see -- and the chart
# section stays hidden for it.
CHART_DEFAULTS = {
    "1 — Amenity Revenue": {"x": "month", "y": "pct_of_month_revenue", "series": "ac_segment"},
    "2 — Neighborhood Pricing": {"x": "neighborhood", "y": "avg_price_increase", "series": "(none)"},
    "3 — Long Stay / Picky Renter": None,
}


def run_query(sql: str) -> pd.DataFrame:
    """Execute one statement on a short-lived read-only connection."""
    with duckdb.connect(str(DB_PATH), read_only=True) as con:
        return con.execute(sql).df()


# The editor's Run button: commits the editor text back to the app, which
# then executes it. Everything else (chart tweaks, preset browsing) reruns
# the last committed SQL, so half-typed queries never execute.
RUN_BUTTON = {
    "name": "Run",
    "feather": "Play",
    "primary": True,
    "hasText": True,
    "showWithIcon": True,
    "commands": ["submit"],
    "style": {"bottom": "0.44rem", "right": "0.4rem"},
}


@st.cache_data
def schema_completions() -> list[dict]:
    """Autocomplete entries derived from the live schema: every table and
    column name, so the editor completes listing_days and
    has_air_conditioning, not just SQL keywords. Cached per session -- a
    schema change shows up on app restart."""
    cols = run_query("""
        select table_schema, table_name, column_name
        from information_schema.columns
        order by 1, 2, ordinal_position
    """)

    completions = [
        {"caption": s, "value": s, "meta": "schema", "score": 500}
        for s in cols["table_schema"].unique()
    ]
    for (schema, table), grp in cols.groupby(["table_schema", "table_name"], sort=False):
        completions.append(
            {"caption": table, "value": table, "meta": schema, "score": 450}
        )
    # One entry per distinct column name: listing_id exists on nine tables,
    # and nine identical popup rows help nobody. The meta names the table
    # where the name is unique to one, and counts them where it is not.
    by_name = cols.groupby("column_name")["table_name"].unique()
    for name, tables in by_name.items():
        meta = tables[0] if len(tables) == 1 else f"{len(tables)} tables"
        completions.append({"caption": name, "value": name, "meta": meta, "score": 400})
    return completions


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
    problem_presets = list(PRESETS)[:3]
    extra_presets = list(PRESETS)[3:]
    divider = "─" * 24
    preset = st.selectbox(
        "Preset",
        problem_presets + [divider] + extra_presets + ["(custom)"],
    )
    st.header("Tables")
    st.caption("`main` is the analyst contract; the other schemas are the "
               "layers behind it.")
    try:
        st.dataframe(list_tables(), hide_index=True, height=310)
    except Exception as exc:  # the DB may be mid-rebuild
        st.warning(f"Could not list tables: {exc}")

# ---- main: editor, results, chart ------------------------------------------
default_sql = PRESETS.get(preset, "select * from main.listing_days limit 100")
st.caption("SQL on a read-only connection. Autocomplete knows the live schema's "
           "tables and columns — Ctrl+Space or just type; **Run** (in the editor) "
           "executes.")
response = code_editor(
    default_sql,
    lang="sql",
    height=[10, 18],
    completions=schema_completions(),
    options={"enableBasicAutocompletion": True, "enableLiveAutocompletion": True, "wrap": True},
    buttons=[RUN_BUTTON],
    key=f"editor-{preset}",
)
sql = (response.get("text") or "").strip() or default_sql

if sql:
    try:
        df = run_query(sql)
    except Exception as exc:
        st.error(str(exc))
        st.stop()

    st.caption(f"{len(df):,} rows × {len(df.columns)} columns")
    st.dataframe(df, hide_index=True, width="stretch")
    st.download_button("Download CSV", df.to_csv(index=False), "result.csv", "text/csv")

    numeric_cols = [c for c in df.columns if pd.api.types.is_numeric_dtype(df[c])]
    defaults = CHART_DEFAULTS.get(preset, {})
    if defaults is None:
        st.caption("This preset is read from the table — no chart by default. "
                   "Switch preset or edit the SQL to chart it.")
    elif not df.empty and numeric_cols:
        st.subheader("Chart")

        def default_index(options, wanted):
            return options.index(wanted) if wanted in options else 0

        # Keys carry the preset and the result's columns, so defaults
        # re-apply when either changes instead of stale selections lingering.
        key_suffix = f"{preset}-{'|'.join(df.columns)}"
        x_options = list(df.columns)
        series_options = ["(none)"] + list(df.columns)

        c1, c2, c3, c4 = st.columns(4)
        chart_type = c1.selectbox("Type", list(CHART_TYPES), key=f"type-{key_suffix}")
        x_col = c2.selectbox("X", x_options,
                             index=default_index(x_options, defaults.get("x")),
                             key=f"x-{key_suffix}")
        y_col = c3.selectbox("Y", numeric_cols,
                             index=default_index(numeric_cols, defaults.get("y")),
                             key=f"y-{key_suffix}")
        color_col = c4.selectbox("Series", series_options,
                                 index=default_index(series_options, defaults.get("series", "(none)")),
                                 key=f"series-{key_suffix}")

        encoding = {
            "x": alt.X(x_col, sort=None),
            "y": alt.Y(y_col),
            "tooltip": list(df.columns),
        }
        if color_col != "(none)":
            encoding["color"] = alt.Color(color_col)

        mark = getattr(alt.Chart(df), f"mark_{CHART_TYPES[chart_type]}")()
        st.altair_chart(mark.encode(**encoding), use_container_width=True)
