# Answers

Runnable versions of everything below are in `05_answers.sql`. All outputs were
produced on MySQL 9.7.1 against `hierarchical_db`.

---

## E1. Alan Turing's organisation, with levels below him

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, manager_id, 0 AS levels_below
    FROM employees
    WHERE emp_name = 'Alan Turing'

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.manager_id, o.levels_below + 1
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
)
SELECT levels_below, emp_name
FROM org
WHERE levels_below > 0          -- exclude Alan in the OUTER query
ORDER BY levels_below, emp_name;
```

```text
+--------------+-----------------+
| levels_below | emp_name        |
+--------------+-----------------+
|            1 | Radia Perlman   |
|            1 | Tim Berners-Lee |
|            2 | Brian Kernighan |
|            2 | Dennis Ritchie  |
|            2 | Ken Thompson    |
+--------------+-----------------+
```

The only subtlety is `WHERE levels_below > 0` sitting in the outer query. Put it
in the recursive member and the recursion kills its own starting point and
returns nothing.

---

## E2. Which division does each employee sit in?

```sql
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, manager_id, 1 AS depth,
           CAST('(the CEO herself)' AS CHAR(60)) AS division_head
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.manager_id, o.depth + 1,
           -- at depth 2 the employee IS the division head; deeper, inherit it
           CAST(CASE WHEN o.depth = 1 THEN e.emp_name
                     ELSE o.division_head END AS CHAR(60))
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
)
SELECT division_head, depth, emp_name
FROM org
ORDER BY division_head, depth, emp_name;
```

```text
+-------------------+-------+-------------------+
| division_head     | depth | emp_name          |
+-------------------+-------+-------------------+
| (the CEO herself) |     1 | Ada Lovelace      |
| Grace Hopper      |     2 | Grace Hopper      |
| Grace Hopper      |     3 | Barbara Liskov    |
| Grace Hopper      |     3 | Linus Pauling     |
| Grace Hopper      |     4 | Alan Turing       |
| Grace Hopper      |     4 | Donald Knuth      |
| Grace Hopper      |     4 | Edgar Codd        |
| Grace Hopper      |     4 | Margaret Hamilton |
| Grace Hopper      |     5 | Jean Bartik       |
| Grace Hopper      |     5 | Jim Gray          |
| Grace Hopper      |     5 | Radia Perlman     |
| Grace Hopper      |     5 | Tim Berners-Lee   |
| Grace Hopper      |     6 | Brian Kernighan   |
| Grace Hopper      |     6 | Dennis Ritchie    |
| Grace Hopper      |     6 | Frances Allen     |
| Grace Hopper      |     6 | Ken Thompson      |
| Hedy Lamarr       |     2 | Hedy Lamarr       |
| Katherine Johnson |     2 | Katherine Johnson |
| Katherine Johnson |     3 | Mary Jackson      |
| Katherine Johnson |     3 | Shafi Goldwasser  |
+-------------------+-------+-------------------+
```

**The idea to take away:** a recursive CTE can carry *inherited* values down the
tree, not just counters and paths. The `CASE` fires only at the transition from
depth 1 to depth 2 — after that, every level copies what its parent held. This
is how you propagate any "nearest ancestor of kind X" attribute: a cost centre,
an owning team, a permission inherited from a parent folder.

Note the `CAST(... AS CHAR(60))` on a column whose anchor value is a literal.
Without it the CTE infers the type from `'(the CEO herself)'` — 17 characters —
and the first real name that is longer fails with *Data too long*.

---

## E3. Bolt M5 per Mountain Bicycle

```sql
WITH RECURSIVE explosion AS (
    SELECT component_id AS part_id, CAST(quantity AS DECIMAL(20,3)) AS qty
    FROM bom
    WHERE assembly_id = 200

    UNION ALL

    SELECT b.component_id, CAST(x.qty * b.quantity AS DECIMAL(20,3))
    FROM explosion x
    JOIN bom b ON b.assembly_id = x.part_id
)
SELECT p.part_name, SUM(x.qty) AS bolts_per_bike
FROM explosion x
JOIN parts p ON p.part_id = x.part_id
WHERE p.part_name = 'Bolt M5'
GROUP BY p.part_id, p.part_name;
```

```text
+-----------+----------------+
| part_name | bolts_per_bike |
+-----------+----------------+
| Bolt M5   |         17.000 |
+-----------+----------------+
```

Checked by hand: Suspension Fork 2 + Drivetrain 6 + Brakes (2 assemblies × 2) 4
+ Cockpit 4 + Seat 1 = **17**. Two things had to be right — multiplying the
quantity down each path (the brakes contribute 4, not 2) and summing across the
five paths that reach the bolt.

Filtering `part_name = 'Bolt M5'` in the *outer* query is deliberate. Put it in
the recursive member and you cut the walk off before it ever descends into the
assemblies that contain bolts.

---

## E4. In the Road Bicycle but not the Mountain Bicycle

```sql
WITH RECURSIVE explosion AS (
    SELECT b.assembly_id AS product_id, b.component_id AS part_id
    FROM bom b
    WHERE b.assembly_id IN (100, 200)        -- both products, one walk

    UNION ALL

    SELECT x.product_id, b.component_id      -- product_id is carried, not re-derived
    FROM explosion x
    JOIN bom b ON b.assembly_id = x.part_id
)
SELECT DISTINCT p.part_name, p.part_type
FROM explosion x
JOIN parts p ON p.part_id = x.part_id
WHERE x.product_id = 100
  AND x.part_id NOT IN (SELECT part_id FROM explosion WHERE product_id = 200)
ORDER BY p.part_name;
```

```text
+---------------------+-----------+
| part_name           | part_type |
+---------------------+-----------+
| Fork Crown          | buy       |
| Fork Tube           | buy       |
| Frame Assembly      | assembly  |
| Frame Tubing Set    | buy       |
| Rigid Fork Assembly | assembly  |
+---------------------+-----------+
```

Exactly the rigid-frame branch. Everything else — wheels, drivetrain, brakes,
cockpit, seat, and the bolts — is shared, which is what the setup data was built
to show.

The technique is the `product_id` column tagging each row with the root it came
from, which is the same trick as `root_id` in Q14. One recursion answers both
sides of the comparison, and the CTE is referenced twice in the outer query.

---

## E5. Average subtree salary per manager, excluding themselves

```sql
WITH RECURSIVE closure AS (
    SELECT emp_id AS root_id, emp_id AS node_id, 0 AS dist
    FROM employees

    UNION ALL

    SELECT c.root_id, e.emp_id, c.dist + 1
    FROM closure c
    JOIN employees e ON e.manager_id = c.node_id
)
SELECT r.emp_name              AS manager,
       r.salary                AS own_salary,
       COUNT(*)                AS subtree_headcount,
       ROUND(AVG(e.salary), 2) AS avg_subtree_salary
FROM closure c
JOIN employees r ON r.emp_id = c.root_id
JOIN employees e ON e.emp_id = c.node_id
WHERE c.dist > 0               -- <<< the whole answer is this line
GROUP BY r.emp_id, r.emp_name, r.salary
ORDER BY avg_subtree_salary DESC;
```

```text
+-------------------+------------+-------------------+--------------------+
| manager           | own_salary | subtree_headcount | avg_subtree_salary |
+-------------------+------------+-------------------+--------------------+
| Ada Lovelace      |  320000.00 |                19 |          154526.32 |
| Grace Hopper      |  260000.00 |                14 |          151428.57 |
| Barbara Liskov    |  205000.00 |                 3 |          143333.33 |
| Linus Pauling     |  210000.00 |                 9 |          141666.67 |
| Margaret Hamilton |  178000.00 |                 2 |          132000.00 |
| Alan Turing       |  175000.00 |                 5 |          131600.00 |
| Tim Berners-Lee   |  150000.00 |                 2 |          121000.00 |
| Jean Bartik       |  145000.00 |                 1 |          119000.00 |
| Radia Perlman     |  148000.00 |                 1 |          118000.00 |
| Edgar Codd        |  158000.00 |                 1 |          112000.00 |
| Katherine Johnson |  250000.00 |                 2 |          104000.00 |
+-------------------+------------+-------------------+--------------------+
```

`WHERE c.dist > 0` does two jobs at once: it excludes each manager from their own
average, and it drops individual contributors from the report entirely (their
only closure row is `dist = 0`), so no `HAVING` is needed.

Compare against Q7, where `dist = 0` rows were kept on purpose so that
`org_salary_cost` included the manager's own salary. Deciding whether the root
belongs in its own aggregate is the recurring judgement call in subtree
reporting — and the only thing that changes is this one predicate.

---

## C1. Capstone — span-of-control and cost report

```sql
WITH RECURSIVE
-- (1) Grace Hopper's organisation: depth, and a path for org-chart ordering.
eng_org AS (
    SELECT emp_id, emp_name, manager_id, 0 AS depth,
           CAST(emp_name AS CHAR(1000)) AS sort_path
    FROM employees
    WHERE emp_name = 'Grace Hopper'

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.manager_id, o.depth + 1,
           CAST(CONCAT(o.sort_path, ' > ', e.emp_name) AS CHAR(1000))
    FROM employees e
    JOIN eng_org o ON e.manager_id = o.emp_id
),
-- (2) Ancestor/descendant pairs, so each subtree can be aggregated.
closure AS (
    SELECT emp_id AS root_id, emp_id AS node_id, 0 AS dist
    FROM employees

    UNION ALL

    SELECT c.root_id, e.emp_id, c.dist + 1
    FROM closure c
    JOIN employees e ON e.manager_id = c.node_id
),
-- (3) The full path from the CEO, for the readable report column.
from_ceo AS (
    SELECT emp_id, manager_id, CAST(emp_name AS CHAR(1000)) AS ceo_path
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT e.emp_id, e.manager_id,
           CAST(CONCAT(f.ceo_path, ' > ', e.emp_name) AS CHAR(1000))
    FROM employees e
    JOIN from_ceo f ON e.manager_id = f.emp_id
)
SELECT o.emp_name                                  AS manager,
       o.depth                                     AS depth_below_cto,
       SUM(CASE WHEN c.dist = 1 THEN 1 ELSE 0 END) AS direct_reports,
       COUNT(*)                                    AS subtree_headcount,
       SUM(e.salary)                               AS subtree_salary,
       f.ceo_path                                  AS reporting_line
FROM eng_org o
JOIN closure   c ON c.root_id = o.emp_id AND c.dist > 0   -- descendants only
JOIN employees e ON e.emp_id = c.node_id
JOIN from_ceo  f ON f.emp_id = o.emp_id
GROUP BY o.emp_id, o.emp_name, o.depth, o.sort_path, f.ceo_path
ORDER BY o.sort_path;
```

```text
+-------------------+-----------------+----------------+-------------------+----------------+-------------------------------------------------------------------------------+
| manager           | depth_below_cto | direct_reports | subtree_headcount | subtree_salary | reporting_line                                                                |
+-------------------+-----------------+----------------+-------------------+----------------+-------------------------------------------------------------------------------+
| Grace Hopper      |               0 |              2 |                14 |     2120000.00 | Ada Lovelace > Grace Hopper                                                   |
| Barbara Liskov    |               1 |              2 |                 3 |      430000.00 | Ada Lovelace > Grace Hopper > Barbara Liskov                                  |
| Edgar Codd        |               2 |              1 |                 1 |      112000.00 | Ada Lovelace > Grace Hopper > Barbara Liskov > Edgar Codd                     |
| Linus Pauling     |               1 |              2 |                 9 |     1275000.00 | Ada Lovelace > Grace Hopper > Linus Pauling                                   |
| Alan Turing       |               2 |              2 |                 5 |      658000.00 | Ada Lovelace > Grace Hopper > Linus Pauling > Alan Turing                     |
| Radia Perlman     |               3 |              1 |                 1 |      118000.00 | Ada Lovelace > Grace Hopper > Linus Pauling > Alan Turing > Radia Perlman     |
| Tim Berners-Lee   |               3 |              2 |                 2 |      242000.00 | Ada Lovelace > Grace Hopper > Linus Pauling > Alan Turing > Tim Berners-Lee   |
| Margaret Hamilton |               2 |              1 |                 2 |      264000.00 | Ada Lovelace > Grace Hopper > Linus Pauling > Margaret Hamilton               |
| Jean Bartik       |               3 |              1 |                 1 |      119000.00 | Ada Lovelace > Grace Hopper > Linus Pauling > Margaret Hamilton > Jean Bartik |
+-------------------+-----------------+----------------+-------------------+----------------+-------------------------------------------------------------------------------+
```

9 rows. Walking through the design decisions, because each one was a place to go
wrong:

**Three CTEs, three different jobs.** It is tempting to try to do this with one
recursion. You cannot, because the three pieces are anchored differently:
`eng_org` anchors at Grace Hopper and walks down (that is what defines "in the
CTO's organisation" and supplies `depth_below_cto`); `closure` anchors at every
employee (that is what makes per-subtree aggregation a `GROUP BY`); `from_ceo`
anchors at the CEO (because `reporting_line` must start above Grace). A single
`WITH RECURSIVE` can hold all three — the keyword appears once, and
non-recursive and recursive CTEs can be mixed freely in the list.

**`AND c.dist > 0` in the join, not in a `WHERE`.** This is what makes both
aggregates exclude the manager themselves, and it is also what filters out
individual contributors: someone with no reports has no closure row with
`dist > 0`, so the inner join eliminates them and no `HAVING COUNT(*) > 0` is
needed. Had this been `WHERE c.dist > 0` after a `LEFT JOIN`, the two would not
be equivalent.

**`COUNT(*)` is safe here** precisely because `dist > 0` is already applied —
every surviving row is a strict descendant, so counting rows counts the
subtree.

**Both `sort_path` and `ceo_path` are in the `GROUP BY`.** They are
functionally dependent on `o.emp_id`, but MySQL runs with `ONLY_FULL_GROUP_BY`
enabled by default and will reject a bare `SELECT` of either. PostgreSQL would
accept grouping by the primary key alone.

**`ORDER BY o.sort_path`, not by name or headcount.** That is what makes the
report read like an org chart: Barbara Liskov's subtree is finished before
Linus Pauling's begins, and `Margaret Hamilton` sorts after
`Alan Turing` *under the same parent* rather than globally. For production use,
build `sort_path` from `LPAD(emp_id, 6, '0')` instead of names so that duplicate
or re-spelled names cannot reorder the report.

### Checking the numbers by hand

Grace Hopper's `subtree_salary` of 2,120,000 excludes her own 260,000 — the
14 people under her sum to 2,120,000, and Q7's `org_salary_cost` for Grace was
2,380,000, which is 2,120,000 + 260,000. The two queries agree, which is the
cheap way to validate a closure query: compute the same figure with and without
the root and check the difference is exactly the root's own value.

---

## Self-check answers

1. **`UNION ALL` vs `UNION`** — `UNION` deduplicates on every iteration, which
   costs a sort and, in a DAG, silently discards rows that legitimately repeat.
   Bolt M5 would have come out as 4 per bicycle instead of 19.
2. **Descendants → ancestors** — flip the join condition.
   `JOIN employees e ON e.manager_id = cte.emp_id` walks down;
   `JOIN employees m ON cte.manager_id = m.emp_id` walks up. Nothing else changes.
3. **Why `CAST` in both members** — the CTE's column types are inferred from the
   anchor member alone. A path seeded from a `VARCHAR(60)` name gets a 60-char
   column, and the first concatenation overflows it (`ERROR 1406: Data too long`).
   Same reason `DECIMAL(20,3)` is needed for a running product.
4. **Where a depth filter belongs** — inside the recursive member. In the outer
   query it returns identical rows but only after walking the whole subtree and
   discarding most of it.
5. **No `SUM()` in the recursive member** — the recursive member is evaluated once
   per iteration against only the previous iteration's rows, so an aggregate
   there has no well-defined meaning; the standard forbids it and MySQL rejects
   it. Accumulate rows recursively, aggregate in the outer query.
6. **Why a cycle returns too few rows** — in an adjacency list each row has exactly
   one parent, so a cycle forms a component with no root in it. A top-down walk
   anchored at `manager_id IS NULL` can never enter the cycle, so it never
   loops; it just silently omits every row trapped in or below it. Only a walk
   that starts inside the cycle, or one anchored at every row, hits the
   recursion limit.
