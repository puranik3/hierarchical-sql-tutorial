# Hierarchical Queries in Modern SQL

A practical tutorial built around two datasets you can query immediately: a
company org chart and a bicycle bill of materials.

Everything in this file was run against **MySQL 9.7.1**, database
`hierarchical_db`. The outputs shown are real output, not illustrations.

```bash
mysql -uroot -p < 01_setup.sql          # create and load hierarchical_db
mysql -uroot -p --table < 02_queries.sql   # run every query in this tutorial
```

---

## 1. What makes data "hierarchical"

Hierarchical data is data where **rows point at other rows in the same table**,
forming parent/child chains of a depth you do not know in advance:

- an employee has a manager, who has a manager, who has a manager...
- a part is made of parts, which are made of parts...
- a comment replies to a comment, a folder contains folders, a category has
  subcategories, an account rolls up into a parent account, a flight connects
  to a flight.

The defining property is that **the depth is data, not schema**. Add one more
layer of management and no table changes — but every query that walks the
hierarchy must cope with the new level automatically.

## 2. How hierarchies get stored

Two storage models cover almost everything, and this tutorial uses one of each.

### Adjacency list — `employees`

Each row carries a pointer to its own parent. `NULL` means "I am a root".

```
emp_id  emp_name            manager_id
1       Ada Lovelace        NULL        <- root
2       Grace Hopper        1
4       Linus Pauling       2
6       Alan Turing         4
```

Cheap to write (moving a subtree = one `UPDATE`), and the natural default.

### Edge table — `parts` + `bom`

The hierarchy lives in its **own table**, one row per parent/child link:

```
assembly_id  component_id  quantity
100          120           2          <- a Road Bicycle has 2 Wheel Assemblies
120          122           32         <- a Wheel Assembly has 32 Spokes
```

Use this when a child can have **several parents** (a Wheel Assembly goes into
both bicycles) or when the *relationship itself* carries data (the quantity).
This makes the structure a **DAG** — a directed acyclic graph — rather than a
tree, and that difference shows up in Q13.

### The others, in one line each

| Model | Idea | Trade-off |
|---|---|---|
| Closure table | Store every ancestor/descendant pair | Fast reads, expensive writes, O(n·depth) rows |
| Path enumeration | Store `'/1/2/4/6/'` in a column | Easy subtree reads via `LIKE`, fragile on moves |
| Nested sets | Store `left`/`right` numbers per node | Very fast subtree reads, brutal writes |

With recursive CTEs available, the adjacency list plus a good index is the right
default. The other models are optimisations you reach for when profiling says so.

## 3. Why ordinary SQL cannot do this

To get an employee's manager you self-join once:

```sql
FROM employees e JOIN employees m ON m.emp_id = e.manager_id
```

For the grandmanager you join again. For the great-grandmanager, again. **Each
join buys exactly one level**, so a query with three joins answers "three
levels" and nothing else. Since the depth lives in the data, there is no
correct number of joins to write.

You need a query that can apply the same join *an unknown number of times* and
stop when it runs out of rows. That is the recursive CTE.

## 4. The recursive CTE

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, manager_id      -- (1) ANCHOR MEMBER
    FROM employees
    WHERE emp_name = 'Linus Pauling'

    UNION ALL                                -- (2) always UNION ALL (see below)

    SELECT e.emp_id, e.emp_name, e.manager_id  -- (3) RECURSIVE MEMBER
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id      --     ^ refers to itself
)
SELECT * FROM org;                           -- (4) the outer query
```

Three pieces and one rule:

1. **Anchor member** — the starting rows. Runs exactly once. Contains no
   reference to the CTE.
2. **Recursive member** — references the CTE by name. Expresses **one single
   step** of the walk: "given rows I already have, give me their children".
3. **`UNION ALL`** joins them. (`UNION` would deduplicate, which costs a sort
   on every iteration and silently throws away legitimately repeated rows —
   e.g. the same part reached by two different paths.)

### How the engine actually runs it

This is the part worth internalising, because it explains every surprise:

1. Run the anchor member. Its rows go into the result **and** into a *working
   table*.
2. Run the recursive member **with the CTE standing for the working table only**
   — not for everything accumulated so far.
3. Its output rows are appended to the result and **become the new working
   table**.
4. Repeat from 2 until an iteration produces zero rows.
5. The outer query then runs over the accumulated result.

Tracing Q2 (`Linus Pauling`, `emp_id = 4`):

| Iteration | Working table going in | Rows produced |
|---|---|---|
| anchor | — | Linus Pauling (4) |
| 1 | Linus | Alan Turing (6), Margaret Hamilton (7) |
| 2 | Alan, Margaret | Tim Berners-Lee (8), Radia Perlman (9), Jean Bartik (13) |
| 3 | Tim, Radia, Jean | Ken Thompson (10), Dennis Ritchie (11), Brian Kernighan (12), Frances Allen (14) |
| 4 | Ken, Dennis, Brian, Frances | *none* → stop |

Accumulated: 10 rows. The recursion is **breadth-first by construction** — one
whole level per iteration. That is why a `depth` counter is simply
`parent_depth + 1`, and why termination depends entirely on the recursive member
eventually finding no matching rows.

### The six moves

Essentially every hierarchical query is a combination of these:

| Move | How |
|---|---|
| Walk **down** (descendants) | `JOIN child ON child.parent_id = cte.id` |
| Walk **up** (ancestors) | `JOIN parent ON parent.id = cte.parent_id` |
| Track **depth** | carry `depth + 1` |
| Track **path** | carry `CONCAT(path, ' > ', name)` |
| **Prune** | `WHERE` inside the recursive member |
| **Aggregate** a subtree | anchor at every node, then `GROUP BY` the anchor |

---

# Part A — Org chart

## Q1. Who reports directly to whom?

The baseline, with no recursion — and precisely what does not generalise.

```sql
SELECT e.emp_name AS employee, m.emp_name AS manager
FROM employees e
LEFT JOIN employees m ON m.emp_id = e.manager_id
ORDER BY (m.emp_name IS NULL) DESC, m.emp_name, e.emp_name;
```

```text
+-------------------+-------------------+
| employee          | manager           |
+-------------------+-------------------+
| Ada Lovelace      | NULL              |
| Grace Hopper      | Ada Lovelace      |
| Hedy Lamarr       | Ada Lovelace      |
| Katherine Johnson | Ada Lovelace      |
| Radia Perlman     | Alan Turing       |
| Tim Berners-Lee   | Alan Turing       |
| ...               | ...               |
+-------------------+-------------------+
```

One level, one join. Note `LEFT JOIN` so the root survives.

## Q2. Everybody in Linus Pauling's organisation, at any depth

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, job_title, manager_id
    FROM employees
    WHERE emp_name = 'Linus Pauling'

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.job_title, e.manager_id
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
)
SELECT emp_id, emp_name, job_title
FROM org
WHERE emp_name <> 'Linus Pauling'
ORDER BY emp_id;
```

```text
+--------+-------------------+---------------------+
| emp_id | emp_name          | job_title           |
+--------+-------------------+---------------------+
|      6 | Alan Turing       | Engineering Manager |
|      7 | Margaret Hamilton | Engineering Manager |
|      8 | Tim Berners-Lee   | Senior Engineer     |
|      9 | Radia Perlman     | Senior Engineer     |
|     10 | Ken Thompson      | Engineer            |
|     11 | Dennis Ritchie    | Engineer            |
|     12 | Brian Kernighan   | Engineer            |
|     13 | Jean Bartik       | Senior Engineer     |
|     14 | Frances Allen     | Engineer            |
+--------+-------------------+---------------------+
```

The starting row is dropped in the **outer** query, not the anchor — the
recursion needs it in order to find anything at all.

## Q3. How many levels below the CEO is each employee?

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, manager_id, 1 AS depth
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.manager_id, o.depth + 1
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
)
SELECT depth, emp_name FROM org ORDER BY depth, emp_name;
```

```text
+-------+-------------------+
| depth | emp_name          |
+-------+-------------------+
|     1 | Ada Lovelace      |
|     2 | Grace Hopper      |
|     2 | Hedy Lamarr       |
|     2 | Katherine Johnson |
|     3 | Barbara Liskov    |
|     3 | Linus Pauling     |
|     3 | Mary Jackson      |
|     3 | Shafi Goldwasser  |
|     4 | Alan Turing       |
|     ... (20 rows)        |
|     6 | Ken Thompson      |
+-------+-------------------+
```

`WHERE manager_id IS NULL` anchors at **all** roots. Multiple roots cost
nothing — a forest works exactly like a tree.

## Q4. Print the whole org chart as an indented tree

Two tricks together: a `sort_path` so children sort directly under their parent,
and indentation from `depth`.

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, job_title, manager_id,
           1 AS depth,
           CAST(emp_name AS CHAR(1000)) AS sort_path
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.job_title, e.manager_id,
           o.depth + 1,
           CAST(CONCAT(o.sort_path, ' > ', e.emp_name) AS CHAR(1000))
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
)
SELECT CONCAT(REPEAT('   ', depth - 1), emp_name) AS org_chart, job_title, depth
FROM org
ORDER BY sort_path;
```

```text
+--------------------------------+--------------------------+-------+
| org_chart                      | job_title                | depth |
+--------------------------------+--------------------------+-------+
| Ada Lovelace                   | Chief Executive Officer  |     1 |
|    Grace Hopper                | Chief Technology Officer |     2 |
|       Barbara Liskov           | VP Data                  |     3 |
|          Donald Knuth          | Data Scientist           |     4 |
|          Edgar Codd            | Data Engineer            |     4 |
|             Jim Gray           | Data Analyst             |     5 |
|       Linus Pauling            | VP Engineering           |     3 |
|          Alan Turing           | Engineering Manager      |     4 |
|             Radia Perlman      | Senior Engineer          |     5 |
|                Brian Kernighan | Engineer                 |     6 |
|             Tim Berners-Lee    | Senior Engineer          |     5 |
|                Dennis Ritchie  | Engineer                 |     6 |
|                Ken Thompson    | Engineer                 |     6 |
|          Margaret Hamilton     | Engineering Manager      |     4 |
|             Jean Bartik        | Senior Engineer          |     5 |
|                Frances Allen   | Engineer                 |     6 |
|    Hedy Lamarr                 | Office Manager           |     2 |
|    Katherine Johnson           | Chief Financial Officer  |     2 |
|       Mary Jackson             | Accountant               |     3 |
|       Shafi Goldwasser         | Senior Accountant        |     3 |
+--------------------------------+--------------------------+-------+
```

**`ORDER BY sort_path` is the whole technique.** A recursive CTE returns rows
breadth-first and you cannot rely on that order anyway; sorting by the
accumulated path is what produces depth-first "reading order". Two caveats:

- Sorting on a *name* path breaks if names collide. For stable output, build the
  path from zero-padded ids: `LPAD(emp_id, 6, '0')`, so `'000004'` sorts
  correctly against `'000020'`.
- `CAST(... AS CHAR(1000))` appears in **both** members deliberately. See
  gotcha 2.

## Q5. The full chain of command above Jim Gray

Walking up is the same pattern with the join condition flipped.

```sql
WITH RECURSIVE chain AS (
    SELECT emp_id, emp_name, job_title, manager_id, 0 AS levels_up
    FROM employees
    WHERE emp_name = 'Jim Gray'

    UNION ALL

    SELECT m.emp_id, m.emp_name, m.job_title, m.manager_id, c.levels_up + 1
    FROM employees m
    JOIN chain c ON c.manager_id = m.emp_id     -- child -> parent
)
SELECT levels_up, emp_name, job_title FROM chain ORDER BY levels_up;
```

```text
+-----------+----------------+--------------------------+
| levels_up | emp_name       | job_title                |
+-----------+----------------+--------------------------+
|         0 | Jim Gray       | Data Analyst             |
|         1 | Edgar Codd     | Data Engineer            |
|         2 | Barbara Liskov | VP Data                  |
|         3 | Grace Hopper   | Chief Technology Officer |
|         4 | Ada Lovelace   | Chief Executive Officer  |
+-----------+----------------+--------------------------+
```

Compare the two join conditions side by side — this is the single most useful
thing to memorise:

```sql
JOIN org o ON e.manager_id = o.emp_id   -- DOWN: "whose manager is a row I have?"
JOIN chain c ON c.manager_id = m.emp_id -- UP:   "who is the manager of a row I have?"
```

An upward walk from one node visits one row per level, so it is cheap and
bounded by the depth of the tree.

## Q6. Breadcrumbs, plus manager vs individual contributor

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, CAST(emp_name AS CHAR(1000)) AS breadcrumb
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT e.emp_id, e.emp_name,
           CAST(CONCAT(o.breadcrumb, ' > ', e.emp_name) AS CHAR(1000))
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
)
SELECT o.emp_name,
       CASE WHEN EXISTS (SELECT 1 FROM employees r WHERE r.manager_id = o.emp_id)
            THEN 'manager' ELSE 'individual contributor' END AS role_kind,
       o.breadcrumb
FROM org o
ORDER BY o.breadcrumb;
```

```text
+-------------------+------------------------+------------------------------------------------------------+
| emp_name          | role_kind              | breadcrumb                                                 |
+-------------------+------------------------+------------------------------------------------------------+
| Ada Lovelace      | manager                | Ada Lovelace                                               |
| Grace Hopper      | manager                | Ada Lovelace > Grace Hopper                                |
| Barbara Liskov    | manager                | Ada Lovelace > Grace Hopper > Barbara Liskov               |
| Donald Knuth      | individual contributor | Ada Lovelace > Grace Hopper > Barbara Liskov > Donald Knuth|
| ...               | ...                    | ...                                                        |
+-------------------+------------------------+------------------------------------------------------------+
```

"Is this a leaf?" needs no recursion at all — `EXISTS` on one level answers it.
Don't reach for a recursive CTE when a plain predicate will do.

## Q7. Direct reports, total reports, and subtree salary cost per manager

This is the most important technique in the tutorial: **the anchor does not have
to be a single row.** Anchor at *every* employee and the CTE produces one row
per (ancestor, descendant) pair — a **transitive closure** — which turns
per-subtree aggregation into an ordinary `GROUP BY`.

```sql
WITH RECURSIVE closure AS (
    SELECT emp_id AS root_id, emp_id AS node_id, 0 AS dist
    FROM employees                            -- every employee is its own root

    UNION ALL

    SELECT c.root_id, e.emp_id, c.dist + 1
    FROM closure c
    JOIN employees e ON e.manager_id = c.node_id
)
SELECT r.emp_name                                    AS manager,
       SUM(CASE WHEN c.dist = 1 THEN 1 ELSE 0 END)   AS direct_reports,
       SUM(CASE WHEN c.dist > 0 THEN 1 ELSE 0 END)   AS total_reports,
       SUM(e.salary)                                 AS org_salary_cost
FROM closure c
JOIN employees r ON r.emp_id = c.root_id
JOIN employees e ON e.emp_id = c.node_id
GROUP BY r.emp_id, r.emp_name
HAVING total_reports > 0
ORDER BY org_salary_cost DESC;
```

```text
+-------------------+----------------+---------------+-----------------+
| manager           | direct_reports | total_reports | org_salary_cost |
+-------------------+----------------+---------------+-----------------+
| Ada Lovelace      |              3 |            19 |      3256000.00 |
| Grace Hopper      |              2 |            14 |      2380000.00 |
| Linus Pauling     |              2 |             9 |      1485000.00 |
| Alan Turing       |              2 |             5 |       833000.00 |
| Barbara Liskov    |              2 |             3 |       635000.00 |
| Katherine Johnson |              2 |             2 |       458000.00 |
| Margaret Hamilton |              1 |             2 |       442000.00 |
| Tim Berners-Lee   |              2 |             2 |       392000.00 |
| Edgar Codd        |              1 |             1 |       270000.00 |
| Radia Perlman     |              1 |             1 |       266000.00 |
| Jean Bartik       |              1 |             1 |       264000.00 |
+-------------------+----------------+---------------+-----------------+
```

Reading the trick: `dist = 0` is the manager themselves, `dist = 1` their
direct reports, `dist > 0` their entire subtree. `org_salary_cost` includes the
manager's own salary (because `dist = 0` rows are kept); add `WHERE c.dist > 0`
to exclude it. Aggregates and `GROUP BY` are illegal *inside* the recursive
member — so aggregate in the outer query, always.

(`HAVING total_reports > 0` reuses a `SELECT` alias. That is a MySQL
convenience; strict ANSI, PostgreSQL included, wants the full expression
repeated.)

## Q8. Everyone at most 2 levels below the CTO

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, manager_id, 0 AS depth
    FROM employees
    WHERE emp_name = 'Grace Hopper'

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.manager_id, o.depth + 1
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
    WHERE o.depth < 2            -- <<< the brake pedal
)
SELECT depth, emp_name FROM org ORDER BY depth, emp_name;
```

```text
+-------+-------------------+
| depth | emp_name          |
+-------+-------------------+
|     0 | Grace Hopper      |
|     1 | Barbara Liskov    |
|     1 | Linus Pauling     |
|     2 | Alan Turing       |
|     2 | Donald Knuth      |
|     2 | Edgar Codd        |
|     2 | Margaret Hamilton |
+-------+-------------------+
```

Putting `WHERE depth <= 2` in the outer query returns the same rows but walks
the **entire** subtree first and throws most of it away. Prune inside the
recursive member and the engine never visits level 3. On a deep tree that is the
difference between a fast query and a timeout.

## Q9. Lowest common manager of Ken Thompson and Frances Allen

```sql
WITH RECURSIVE ancestors AS (
    SELECT emp_id AS start_id, emp_id AS node_id, manager_id, 0 AS levels_up
    FROM employees
    WHERE emp_name IN ('Ken Thompson', 'Frances Allen')   -- two anchors at once

    UNION ALL

    SELECT a.start_id, m.emp_id, m.manager_id, a.levels_up + 1
    FROM employees m
    JOIN ancestors a ON a.manager_id = m.emp_id
)
SELECT e.emp_name AS lowest_common_manager,
       MAX(a.levels_up) AS hops_from_furthest_employee
FROM ancestors a
JOIN employees e ON e.emp_id = a.node_id
GROUP BY a.node_id, e.emp_name
HAVING COUNT(DISTINCT a.start_id) = 2      -- reachable from BOTH
ORDER BY hops_from_furthest_employee ASC   -- fewest hops = lowest in the tree
LIMIT 1;
```

```text
+-----------------------+-----------------------------+
| lowest_common_manager | hops_from_furthest_employee |
+-----------------------+-----------------------------+
| Linus Pauling         |                           3 |
+-----------------------+-----------------------------+
```

Both chains are walked in one CTE, with `start_id` remembering which employee
each row came from. The common ancestors here are Linus (3 hops), Grace (4) and
Ada (5); fewest hops wins because ancestors form a chain, so distance grows
monotonically as you climb.

## Q10. How tall is the org chart?

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, manager_id, 1 AS depth,
           CAST(emp_name AS CHAR(1000)) AS chain
    FROM employees WHERE manager_id IS NULL
    UNION ALL
    SELECT e.emp_id, e.emp_name, e.manager_id, o.depth + 1,
           CAST(CONCAT(o.chain, ' > ', e.emp_name) AS CHAR(1000))
    FROM employees e JOIN org o ON e.manager_id = o.emp_id
)
SELECT depth AS org_height, emp_name AS deepest_employee, chain
FROM org
WHERE depth = (SELECT MAX(depth) FROM org)
ORDER BY emp_name;
```

```text
+------------+------------------+----------------------------------------------------------------+
| org_height | deepest_employee | chain                                                          |
+------------+------------------+----------------------------------------------------------------+
|          6 | Brian Kernighan  | Ada Lovelace > ... > Alan Turing > Radia Perlman > Brian Kern...|
|          6 | Dennis Ritchie   | Ada Lovelace > ... > Alan Turing > Tim Berners-Lee > Dennis R...|
|          6 | Frances Allen    | Ada Lovelace > ... > Margaret Hamilton > Jean Bartik > Franc...|
|          6 | Ken Thompson     | Ada Lovelace > ... > Alan Turing > Tim Berners-Lee > Ken Thom...|
+------------+------------------+----------------------------------------------------------------+
```

The CTE is referenced twice in the outer query (once in the subquery). That is
allowed and the recursion is evaluated once; only the *recursive member* is
restricted to a single self-reference.

---

# Part B — Bill of materials

`parts` holds the things; `bom` holds the parent/child edges with a quantity.
A Wheel Assembly is used by both bicycles, and Bolt M5 is used by five
different assemblies — so this is a DAG, and the same part legitimately appears
many times in one explosion.

## Q11. What goes directly into a Road Bicycle?

```sql
SELECT c.part_name AS component, b.quantity, c.part_type
FROM bom b
JOIN parts c ON c.part_id = b.component_id
WHERE b.assembly_id = 100
ORDER BY c.part_name;
```

```text
+---------------------+----------+-----------+
| component           | quantity | part_type |
+---------------------+----------+-----------+
| Brake Assembly      |    2.000 | assembly  |
| Cockpit Assembly    |    1.000 | assembly  |
| Drivetrain Assembly |    1.000 | assembly  |
| Frame Assembly      |    1.000 | assembly  |
| Seat Assembly       |    1.000 | assembly  |
| Wheel Assembly      |    2.000 | assembly  |
+---------------------+----------+-----------+
```

Six rows, all of them assemblies — useless to a purchasing team. They need the
leaves.

## Q12. Fully explode the Road Bicycle

The new idea: **quantities multiply along the path.** 2 wheels × 32 spokes = 64
spokes per bicycle.

```sql
WITH RECURSIVE explosion AS (
    SELECT b.component_id                     AS part_id,
           CAST(b.quantity AS DECIMAL(20,3))  AS qty_per_bike,
           1                                  AS lvl,
           CAST(p.part_name AS CHAR(1000))    AS path
    FROM bom b
    JOIN parts p ON p.part_id = b.component_id
    WHERE b.assembly_id = 100

    UNION ALL

    SELECT b.component_id,
           CAST(x.qty_per_bike * b.quantity AS DECIMAL(20,3)),   -- <<< multiply
           x.lvl + 1,
           CAST(CONCAT(x.path, ' / ', p.part_name) AS CHAR(1000))
    FROM explosion x
    JOIN bom b   ON b.assembly_id = x.part_id
    JOIN parts p ON p.part_id     = b.component_id
)
SELECT x.lvl,
       CONCAT(REPEAT('   ', x.lvl - 1), p.part_name) AS part,
       x.qty_per_bike, p.part_type
FROM explosion x
JOIN parts p ON p.part_id = x.part_id
ORDER BY x.path;
```

```text
+------+------------------------+--------------+-----------+
| lvl  | part                   | qty_per_bike | part_type |
+------+------------------------+--------------+-----------+
|    1 | Brake Assembly         |        2.000 | assembly  |
|    2 |    Bolt M5             |        4.000 | buy       |   <- 2 brakes x 2 bolts
|    2 |    Brake Cable         |        2.000 | buy       |
|    2 |    Brake Caliper       |        2.000 | buy       |
|    2 |    Brake Lever         |        2.000 | buy       |
|    1 | Cockpit Assembly       |        1.000 | assembly  |
|    2 |    Bolt M5             |        4.000 | buy       |
|    2 |    Grip                |        2.000 | buy       |
|    2 |    Handlebar           |        1.000 | buy       |
|    2 |    Stem                |        1.000 | buy       |
|    1 | Drivetrain Assembly    |        1.000 | assembly  |
|    2 |    Bolt M5             |        6.000 | buy       |
|    2 |    Cassette            |        1.000 | buy       |
|    2 |    Chain               |        1.000 | buy       |
|    2 |    Crankset            |        1.000 | buy       |
|    2 |    Rear Derailleur     |        1.000 | buy       |
|    1 | Frame Assembly         |        1.000 | assembly  |
|    2 |    Bolt M5             |        4.000 | buy       |
|    2 |    Frame Tubing Set    |        1.000 | buy       |
|    2 |    Rigid Fork Assembly |        1.000 | assembly  |
|    3 |       Fork Crown       |        1.000 | buy       |
|    3 |       Fork Tube        |        1.000 | buy       |
|    1 | Seat Assembly          |        1.000 | assembly  |
|    2 |    Bolt M5             |        1.000 | buy       |
|    2 |    Saddle              |        1.000 | buy       |
|    2 |    Seatpost            |        1.000 | buy       |
|    1 | Wheel Assembly         |        2.000 | assembly  |
|    2 |    Hub Assembly        |        2.000 | assembly  |
|    3 |       Bearing          |        4.000 | buy       |   <- 2 wheels x 1 hub x 2
|    3 |       Hub Shell        |        2.000 | buy       |
|    2 |    Inner Tube          |        2.000 | buy       |
|    2 |    Rim                 |        2.000 | buy       |
|    2 |    Spoke               |       64.000 | buy       |   <- 2 wheels x 32
|    2 |    Tire                |        2.000 | buy       |
+------+------------------------+--------------+-----------+
```

Two details that matter:

- `x.qty_per_bike * b.quantity` carries the running product down. Adding instead
  of multiplying is the classic BOM bug.
- `CAST(... AS DECIMAL(20,3))` in both members. The anchor's `quantity` is
  `DECIMAL(10,3)`; without widening the type, repeated multiplication overflows
  the column the CTE inferred from the anchor. Same lesson as the path column.

## Q13. Shopping list for one Road Bicycle

Now filter to purchased parts, and **sum across paths** — because the DAG
reaches Bolt M5 five separate ways.

```sql
WITH RECURSIVE explosion AS (
    SELECT component_id AS part_id, CAST(quantity AS DECIMAL(20,3)) AS qty
    FROM bom WHERE assembly_id = 100
    UNION ALL
    SELECT b.component_id, CAST(x.qty * b.quantity AS DECIMAL(20,3))
    FROM explosion x JOIN bom b ON b.assembly_id = x.part_id
)
SELECT p.part_name, SUM(x.qty) AS qty_needed, p.unit_cost,
       SUM(x.qty) * p.unit_cost AS line_cost
FROM explosion x
JOIN parts p ON p.part_id = x.part_id
WHERE p.part_type = 'buy'
GROUP BY p.part_id, p.part_name, p.unit_cost
ORDER BY line_cost DESC;
```

```text
+------------------+------------+-----------+-----------+
| part_name        | qty_needed | unit_cost | line_cost |
+------------------+------------+-----------+-----------+
| Crankset         |      1.000 |     95.00 |  95.00000 |
| Frame Tubing Set |      1.000 |     85.00 |  85.00000 |
| Brake Caliper    |      2.000 |     32.00 |  64.00000 |
| Rear Derailleur  |      1.000 |     60.00 |  60.00000 |
| Tire             |      2.000 |     24.00 |  48.00000 |
| Saddle           |      1.000 |     45.00 |  45.00000 |
| Cassette         |      1.000 |     42.00 |  42.00000 |
| Rim              |      2.000 |     18.00 |  36.00000 |
| Brake Lever      |      2.000 |     18.00 |  36.00000 |
| Handlebar        |      1.000 |     30.00 |  30.00000 |
| Chain            |      1.000 |     28.00 |  28.00000 |
| Seatpost         |      1.000 |     28.00 |  28.00000 |
| Stem             |      1.000 |     25.00 |  25.00000 |
| Spoke            |     64.000 |      0.35 |  22.40000 |
| Fork Tube        |      1.000 |     22.00 |  22.00000 |
| Inner Tube       |      2.000 |      6.50 |  13.00000 |
| Hub Shell        |      2.000 |      6.00 |  12.00000 |
| Grip             |      2.000 |      6.00 |  12.00000 |
| Fork Crown       |      1.000 |      9.50 |   9.50000 |
| Brake Cable      |      2.000 |      4.00 |   8.00000 |
| Bearing          |      4.000 |      1.20 |   4.80000 |
| Bolt M5          |     19.000 |      0.20 |   3.80000 |
+------------------+------------+-----------+-----------+
```

**Bolt M5 = 19** is the payoff: 4 (frame) + 6 (drivetrain) + 4 (two brakes) +
4 (cockpit) + 1 (seat). This is exactly why `UNION ALL` matters — `UNION` would
have collapsed those five rows into one and under-ordered bolts by 15.

Conversely, when you want "how many *distinct* parts", say so explicitly with
`COUNT(DISTINCT part_id)`, as in Q14.

## Q14. Rolled-up cost of every assembly

Anchor at every assembly at once; `root_id` keeps the explosions from mixing.

```sql
WITH RECURSIVE explosion AS (
    SELECT p.part_id AS root_id, b.component_id AS part_id,
           CAST(b.quantity AS DECIMAL(20,3)) AS qty
    FROM parts p
    JOIN bom b ON b.assembly_id = p.part_id
    WHERE p.part_type = 'assembly'

    UNION ALL

    SELECT x.root_id, b.component_id, CAST(x.qty * b.quantity AS DECIMAL(20,3))
    FROM explosion x JOIN bom b ON b.assembly_id = x.part_id
)
SELECT r.part_name               AS assembly,
       COUNT(DISTINCT x.part_id) AS distinct_parts_used,
       SUM(CASE WHEN p.part_type = 'buy' THEN x.qty * p.unit_cost ELSE 0 END)
                                 AS rolled_up_cost
FROM explosion x
JOIN parts r ON r.part_id = x.root_id
JOIN parts p ON p.part_id = x.part_id
GROUP BY r.part_id, r.part_name
ORDER BY rolled_up_cost DESC;
```

```text
+--------------------------+---------------------+----------------+
| assembly                 | distinct_parts_used | rolled_up_cost |
+--------------------------+---------------------+----------------+
| Mountain Bicycle         |                  28 |      773.60000 |
| Road Bicycle             |                  30 |      729.50000 |
| Drivetrain Assembly      |                   5 |      226.20000 |
| Suspension Fork Assembly |                   3 |      161.40000 |
| Frame Assembly           |                   5 |      117.30000 |
| Seat Assembly            |                   3 |       73.20000 |
| Wheel Assembly           |                   7 |       68.10000 |
| Cockpit Assembly         |                   4 |       67.80000 |
| Brake Assembly           |                   4 |       54.40000 |
| Rigid Fork Assembly      |                   2 |       31.50000 |
| Hub Assembly             |                   2 |        8.40000 |
+--------------------------+---------------------+----------------+
```

The `CASE` confines costing to `'buy'` parts — assemblies have `NULL` unit cost
because their value is precisely what this query computes. Counting
`'assembly'` rows in the cost would double-count their contents.

## Q15. Where-used: what contains a Bearing?

The purchasing question is "what's in it"; the engineering-change question is
the reverse — "if this part is recalled, what do I have to rework?" Same CTE,
flipped join.

```sql
WITH RECURSIVE used_in AS (
    SELECT b.assembly_id, 1 AS levels_up
    FROM bom b
    JOIN parts p ON p.part_id = b.component_id
    WHERE p.part_name = 'Bearing'

    UNION ALL

    SELECT b.assembly_id, u.levels_up + 1
    FROM used_in u
    JOIN bom b ON b.component_id = u.assembly_id    -- child -> parent
)
SELECT p.part_name AS used_in, MIN(u.levels_up) AS nearest_level
FROM used_in u
JOIN parts p ON p.part_id = u.assembly_id
GROUP BY p.part_id, p.part_name
ORDER BY nearest_level, used_in;
```

```text
+------------------+---------------+
| used_in          | nearest_level |
+------------------+---------------+
| Hub Assembly     |             1 |
| Wheel Assembly   |             2 |
| Mountain Bicycle |             3 |
| Road Bicycle     |             3 |
+------------------+---------------+
```

Going up a DAG can reach the same assembly by several routes, so `MIN` picks
the nearest and `GROUP BY` collapses duplicates. The `ix_bom_component` index
created in the setup script is what makes this direction fast.

## Q16. Production run: 50 road bikes + 30 mountain bikes

Multiple roots, each with its own starting multiplier, fed in from a plain
non-recursive CTE.

```sql
WITH RECURSIVE build_order AS (
    SELECT 100 AS part_id, CAST(50 AS DECIMAL(20,3)) AS qty
    UNION ALL
    SELECT 200,            CAST(30 AS DECIMAL(20,3))
),
explosion AS (
    SELECT b.component_id AS part_id,
           CAST(o.qty * b.quantity AS DECIMAL(20,3)) AS qty
    FROM build_order o
    JOIN bom b ON b.assembly_id = o.part_id

    UNION ALL

    SELECT b.component_id, CAST(x.qty * b.quantity AS DECIMAL(20,3))
    FROM explosion x JOIN bom b ON b.assembly_id = x.part_id
)
SELECT p.part_name, SUM(x.qty) AS qty_to_purchase,
       SUM(x.qty) * p.unit_cost AS line_cost
FROM explosion x
JOIN parts p ON p.part_id = x.part_id
WHERE p.part_type = 'buy'
GROUP BY p.part_id, p.part_name, p.unit_cost
ORDER BY line_cost DESC;
```

```text
+------------------+-----------------+------------+
| part_name        | qty_to_purchase | line_cost  |
+------------------+-----------------+------------+
| Crankset         |          80.000 | 7600.00000 |
| Brake Caliper    |         160.000 | 5120.00000 |
| Rear Derailleur  |          80.000 | 4800.00000 |
| Frame Tubing Set |          50.000 | 4250.00000 |
| Tire             |         160.000 | 3840.00000 |
| ...              |                 |            |
| Spoke            |        5120.000 | 1792.00000 |
| Bearing          |         320.000 |  384.00000 |
| Bolt M5          |        1460.000 |  292.00000 |
+------------------+-----------------+------------+
```

Sanity check: 80 bikes × 2 wheels × 32 spokes = 5120 spokes. Bolts are
50 × 19 + 30 × 17 = 950 + 510 = 1460. Frame Tubing Set is 50, not 80, because
only the road bike uses the rigid frame — the explosion naturally keeps
product-specific parts product-specific.

Mixing both products into one `build_order` means the shared sub-assemblies are
walked once per product and summed at the end, which is exactly what a
purchasing report needs.

---

# Part C — Cycles

A tree cannot loop. Real data loops constantly: a bad manager update, a
circular BOM where a part contains itself, a route graph. `legacy_routes`
contains `BLR → DXB → LHR → JFK → BLR`.

## Q17. Where can I fly starting from BLR?

Naive version first:

```sql
WITH RECURSIVE reachable AS (
  SELECT 'BLR' AS airport, 0 AS hops
  UNION ALL
  SELECT r.dest, rc.hops + 1
  FROM reachable rc JOIN legacy_routes r ON r.origin = rc.airport
) SELECT COUNT(*) FROM reachable;
```

```text
ERROR 3636 (HY000): Recursive query aborted after 1001 iterations.
Try increasing @@cte_max_recursion_depth to a larger value.
```

MySQL's `cte_max_recursion_depth` (default **1000**) caught it. PostgreSQL and
SQLite have no such limit and will run until they exhaust memory or you cancel.
**Never raise the limit to "fix" this** — the limit is the smoke alarm, not the
fire.

The portable fix is to carry the visited set and refuse to re-enter it:

```sql
WITH RECURSIVE reachable AS (
    SELECT CAST('BLR'   AS CHAR(10))   AS airport,
           0                            AS hops,
           CAST('>BLR>' AS CHAR(1000)) AS visited

    UNION ALL

    SELECT CAST(r.dest AS CHAR(10)),
           rc.hops + 1,
           CAST(CONCAT(rc.visited, r.dest, '>') AS CHAR(1000))
    FROM reachable rc
    JOIN legacy_routes r ON r.origin = rc.airport
    WHERE rc.visited NOT LIKE CONCAT('%>', r.dest, '>%')   -- <<< cycle guard
      AND rc.hops < 10                                     -- belt and braces
)
SELECT hops, airport, visited AS route_taken
FROM reachable
ORDER BY hops, airport;
```

```text
+------+---------+-------------------+
| hops | airport | route_taken       |
+------+---------+-------------------+
|    0 | BLR     | >BLR>             |
|    1 | DXB     | >BLR>DXB>         |
|    2 | LHR     | >BLR>DXB>LHR>     |
|    2 | SIN     | >BLR>DXB>SIN>     |
|    3 | JFK     | >BLR>DXB>LHR>JFK> |
|    3 | SYD     | >BLR>DXB>SIN>SYD> |
+------+---------+-------------------+
```

Why the delimiters matter: searching for `'%DXB%'` would also match a city code
embedded in another, so each entry is wrapped — `>BLR>DXB>` — and the test
looks for `>DXB>`. Always add the hard depth cap as well; it turns a hang into
an answer even if the guard has a bug.

PostgreSQL 14+ can do this declaratively, and returns exactly the same six
rows (verified on PostgreSQL 18.4):

```sql
WITH RECURSIVE reach(airport, hops) AS (
  SELECT 'BLR', 0
  UNION ALL
  SELECT r.dest, rc.hops + 1 FROM reach rc JOIN routes r ON r.origin = rc.airport
) CYCLE airport SET is_cycle USING path
SELECT airport, hops FROM reach WHERE NOT is_cycle ORDER BY hops, airport;
```

### Cycles hide differently in an adjacency list

In `employees` every row has exactly one parent, so a cycle **cannot be reached
from a root** — it breaks off as a disconnected island. Create
`4 → 14 → 13 → 7 → 4` with
`UPDATE employees SET manager_id = 14 WHERE emp_id = 4` and the two directions
fail in opposite ways:

| Query | Result with the cycle present |
|---|---|
| Q3, top-down from `manager_id IS NULL` | **10 rows instead of 20** — and no error at all |
| Q5-style upward walk from Frances Allen | `ERROR 3636: Recursive query aborted after 1001 iterations` |

The loud failure is the lucky one. A top-down report that silently drops half
the company is the dangerous case, and no cycle guard will catch it, because the
walk never enters the cycle. What catches it is an audit for rows unreachable
from any root:

```sql
WITH RECURSIVE reachable AS (
    SELECT emp_id FROM employees WHERE manager_id IS NULL
    UNION ALL
    SELECT e.emp_id FROM employees e JOIN reachable r ON e.manager_id = r.emp_id
)
SELECT emp_id, emp_name, manager_id
FROM employees
WHERE emp_id NOT IN (SELECT emp_id FROM reachable)
ORDER BY emp_id;
```

```text
+--------+-------------------+------------+
| emp_id | emp_name          | manager_id |
+--------+-------------------+------------+
|      4 | Linus Pauling     |         14 |
|      6 | Alan Turing       |          4 |
|      7 | Margaret Hamilton |          4 |
|      8 | Tim Berners-Lee   |          6 |
|      9 | Radia Perlman     |          6 |
|     10 | Ken Thompson      |          8 |
|     11 | Dennis Ritchie    |          8 |
|     12 | Brian Kernighan   |          9 |
|     13 | Jean Bartik       |          7 |
|     14 | Frances Allen     |         13 |
+--------+-------------------+------------+
```

Run that on a schedule against any user-editable hierarchy. In the `bom` edge
table the risk is the reverse: a cycle there *is* reachable, so every explosion
loops — which is why Q12-Q16 would all need the visited guard if `bom` were not
known to be acyclic.

---

## Gotchas, with the actual error each one produces

**1. Forgetting `RECURSIVE`.** The CTE name is then simply unknown inside
itself:

```text
ERROR 1146 (42S02): Table 'hierarchical_db.org' doesn't exist
```

MySQL, PostgreSQL and SQLite all require the keyword. SQL Server and Oracle do
not have it — writing `WITH RECURSIVE` there is a syntax error.

**2. Not casting the accumulated column — the single most common failure.** The
CTE's column types are inferred from the **anchor member** only. Build the path
from a `VARCHAR(60)` name and the first concatenation overflows it:

```sql
SELECT emp_id, emp_name, manager_id, emp_name AS path ...   -- no CAST
```

```text
ERROR 1406 (22001): Data too long for column 'path' at row 1
```

PostgreSQL words it differently but means the same thing:

```text
ERROR: recursive query "t" column 2 has type character varying(20)
       in non-recursive term but type character varying overall
HINT:  Cast the output of the non-recursive term to the correct type.
```

The rule: **cast every accumulated column in both members, to a type wide
enough for the deepest row** — `CHAR(1000)` for paths, `DECIMAL(20,3)` for
running products.

**3. `UNION` instead of `UNION ALL`.** Deduplicates every iteration: slower,
and in a DAG it silently loses rows (Bolt M5 would have come out as 4 instead
of 19).

**4. Filtering in the outer query instead of the recursive member.** Correct
results, wasted work — see Q8.

**5. Aggregates inside the recursive member.** Not allowed; MySQL rejects it
outright. Build the rows recursively, aggregate in the outer query.

**6. No cycle guard.** See Part C. Any hierarchy that users can edit will
eventually contain a loop.

**7. Assuming output order.** A recursive CTE has no guaranteed row order. If
you want tree order, carry a sort path and `ORDER BY` it.

## Performance

- **Index the parent column.** `employees(manager_id)` for downward walks,
  `bom(component_id)` for where-used. Both are in the setup script. Without
  them each iteration is a full table scan — and there is one iteration per
  level.
- **Anchor as narrowly as you can.** Starting from one employee and walking down
  touches the subtree; the full-closure form in Q7 touches
  O(nodes × depth) rows. Use the closure form when you genuinely need every
  subtree, not to answer a question about one.
- **Prune inside the recursive member**, always.
- **Select only the columns you carry.** Every column in the CTE is materialised
  once per row per level; dragging a wide `TEXT` column through the recursion is
  pure cost.
- **Cap the depth** even when you trust the data.
- If a hierarchy is read constantly and written rarely, consider materialising a
  closure table (or a path column) maintained by triggers. That is the standard
  escape hatch when a recursive CTE is genuinely too slow — but measure first.

## Dialect cheat sheet

| | MySQL 8+ | PostgreSQL | SQLite | SQL Server | Oracle |
|---|---|---|---|---|---|
| Keyword | `WITH RECURSIVE` | `WITH RECURSIVE` | `WITH RECURSIVE` | `WITH` (no `RECURSIVE`) | `WITH` (no `RECURSIVE`) |
| Concatenate | `CONCAT(a,b)` | `a \|\| b` | `a \|\| b` | `a + b` | `a \|\| b` |
| Path cast | `CAST(x AS CHAR(1000))` | `CAST(x AS TEXT)` | `CAST(x AS TEXT)` | `CAST(x AS VARCHAR(1000))` | `CAST(x AS VARCHAR2(1000))` |
| Repeat a string | `REPEAT(s,n)` | `repeat(s,n)` | *none* — use `substr` of a blank string | `REPLICATE(s,n)` | `LPAD(' ',n)` |
| `NULL`s last in sort | `ORDER BY (x IS NULL) DESC, x` | `ORDER BY x NULLS LAST` | `ORDER BY x NULLS LAST` | `ORDER BY CASE WHEN x IS NULL...` | `ORDER BY x NULLS LAST` |
| Depth limit | `@@cte_max_recursion_depth` (1000) | none | none | `OPTION (MAXRECURSION n)`, default **100** | none |
| Built-in cycle detection | no | `CYCLE` clause (14+) | no | no | `CONNECT BY NOCYCLE`, or `CYCLE` |
| Tree ordering helper | no | `SEARCH DEPTH FIRST BY ...` (14+) | no | no | `ORDER SIBLINGS BY` |

Two traps worth repeating: SQL Server's default `MAXRECURSION` of **100** will
truncate a deep hierarchy with an error, and PostgreSQL's *lack* of any limit
means an unguarded cycle runs until something breaks.

### Oracle's legacy `CONNECT BY`

Oracle had hierarchical queries decades before the standard, and you will meet
this syntax in older code:

```sql
SELECT LEVEL,
       LPAD(' ', (LEVEL-1)*3) || emp_name AS org_chart,
       SYS_CONNECT_BY_PATH(emp_name, ' > ') AS path,
       CONNECT_BY_ROOT emp_name AS top_manager,
       CONNECT_BY_ISLEAF AS is_leaf
FROM employees
START WITH manager_id IS NULL        -- the anchor
CONNECT BY PRIOR emp_id = manager_id -- the recursive step
ORDER SIBLINGS BY emp_name;
```

`START WITH` is the anchor, `CONNECT BY PRIOR` the recursive member, `LEVEL` the
depth. It is compact and Oracle-only. Oracle also supports standard recursive
CTEs, so write those in new code.

## Where to go next

- Rewrite Q4 with an id-based `sort_path` (`LPAD(emp_id, 6, '0')`) and confirm
  the order is identical but no longer name-dependent.
- Reproduce the cycle experiment above, then write the upward walk from Frances
  Allen *with* a visited guard so it terminates and shows the loop. Undo with
  `UPDATE employees SET manager_id = 2 WHERE emp_id = 4`.
- Add a third bicycle model that reuses existing assemblies and re-run Q14 and
  Q15 — nothing in the queries should need to change.

Then try `04_exercises.md`.
