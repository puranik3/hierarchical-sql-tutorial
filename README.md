# Hierarchical Queries in Modern SQL — a tutorial

Target engine: **MySQL 8+** (written and verified on MySQL 9.7.1).
Everything lives in a database called `hierarchical_db`.

## Files, in order

| File | What it is |
|---|---|
| `01_setup.sql` | Creates `hierarchical_db` and loads three datasets. Run this first. |
| `03_tutorial.md` | **Start here.** The concepts, then 17 worked question-and-answer queries with real output. |
| `02_queries.sql` | Every query from the tutorial, runnable. |
| `04_exercises.md` | 5 warm-up exercises plus one capstone question. No answers. |
| `05_answers.md` | Worked answers with output and the reasoning behind each. |
| `05_answers.sql` | The answers, runnable. |

## Getting started

```bash
mysql -uroot -p < 01_setup.sql             # load the data
mysql -uroot -p --table < 02_queries.sql   # see all 17 queries run
```

Then read `03_tutorial.md` alongside an interactive session:

```bash
mysql -uroot -p --table
mysql> USE hierarchical_db;
```

`--table` matters when piping from a file — without it MySQL prints
tab-separated output rather than the bordered tables shown in the tutorial.

## The three datasets

- **`employees`** — a 20-person org chart, 6 levels deep. An *adjacency list*:
  each row stores its own `manager_id`. A tree.
- **`parts` + `bom`** — a bicycle bill of materials across two products. An
  *edge table*: the hierarchy is its own table, so a part can have several
  parents and every link carries a quantity. A DAG.
- **`legacy_routes`** — six flight legs containing a deliberate loop
  (`BLR → DXB → LHR → JFK → BLR`), for the lesson on cycles.

ASCII diagrams of the org chart and the full BOM edge list are in the comments
at the top of `01_setup.sql` — handy for checking answers by hand.

## What the tutorial covers

Recursive CTEs (`WITH RECURSIVE`): the execution model, walking down and up,
depth and path columns, indented tree output, pruning, subtree aggregation via
a transitive closure, quantity roll-ups that multiply along the path,
where-used queries, cycle guards, the seven common mistakes with the exact error
each one produces, indexing and performance, a five-dialect cheat sheet
(MySQL / PostgreSQL / SQLite / SQL Server / Oracle), and Oracle's legacy
`CONNECT BY`.
