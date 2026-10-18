-- ============================================================================
--  Hierarchical Queries Tutorial -- THE QUERIES   (MySQL 8+ / 9.x)
--  Run 01_setup.sql first, then:  mysql -uroot -p --table < 02_queries.sql
-- ============================================================================
USE hierarchical_db;

-- ############################################################################
-- PART A -- ORG CHART (table: employees)
-- ############################################################################

-- @@Q1
-- Q1. Who reports directly to whom?
--     No recursion needed. This is the baseline -- and precisely the thing
--     that does NOT extend to "at any depth".
SELECT e.emp_name AS employee, m.emp_name AS manager
FROM employees e
LEFT JOIN employees m ON m.emp_id = e.manager_id
ORDER BY (m.emp_name IS NULL) DESC, m.emp_name, e.emp_name;

-- @@Q2
-- Q2. List everybody in Linus Pauling's organisation, at any depth.
--     The core pattern: anchor member + recursive member, glued by UNION ALL.
WITH RECURSIVE org AS (
    -- ANCHOR MEMBER: where the walk starts. Runs once.
    SELECT emp_id, emp_name, job_title, manager_id
    FROM employees
    WHERE emp_name = 'Linus Pauling'

    UNION ALL

    -- RECURSIVE MEMBER: one step down. Re-applied until it returns no rows.
    SELECT e.emp_id, e.emp_name, e.job_title, e.manager_id
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
)
SELECT emp_id, emp_name, job_title
FROM org
WHERE emp_name <> 'Linus Pauling'      -- drop the starting row itself
ORDER BY emp_id;

-- @@Q3
-- Q3. How many levels below the CEO is each employee?
--     Carry a counter down the recursion.
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, manager_id, 1 AS depth
    FROM employees
    WHERE manager_id IS NULL                      -- every root

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.manager_id, o.depth + 1
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
)
SELECT depth, emp_name
FROM org
ORDER BY depth, emp_name;

-- @@Q4
-- Q4. Print the whole org chart as an indented tree, in correct reading order.
--     Two tricks: a sortable PATH string, and indentation driven by depth.
--     Note the CAST in BOTH members -- see the dialect notes in the tutorial.
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
SELECT CONCAT(REPEAT('   ', depth - 1), emp_name) AS org_chart,
       job_title,
       depth
FROM org
ORDER BY sort_path;

-- @@Q5
-- Q5. What is the full chain of command above Jim Gray?
--     The same pattern walked UPWARDS: just flip the join condition.
WITH RECURSIVE chain AS (
    SELECT emp_id, emp_name, job_title, manager_id, 0 AS levels_up
    FROM employees
    WHERE emp_name = 'Jim Gray'

    UNION ALL

    SELECT m.emp_id, m.emp_name, m.job_title, m.manager_id, c.levels_up + 1
    FROM employees m
    JOIN chain c ON c.manager_id = m.emp_id        -- flipped: child -> parent
)
SELECT levels_up, emp_name, job_title
FROM chain
ORDER BY levels_up;

-- @@Q6
-- Q6. Give every employee their full breadcrumb, and say whether they are a
--     manager or an individual contributor.
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

-- @@Q7
-- Q7. For every manager: direct reports, total reports at any depth, and the
--     total salary cost of their whole organisation.
--     KEY IDEA: the anchor need not be one row. Anchor at EVERY employee and
--     you get an (ancestor, descendant) pair for the entire tree -- a
--     "transitive closure", which is what makes per-subtree aggregation easy.
WITH RECURSIVE closure AS (
    SELECT emp_id AS root_id, emp_id AS node_id, 0 AS dist
    FROM employees

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

-- @@Q8
-- Q8. Everyone at most 2 levels below the CTO (Grace Hopper).
--     Prune inside the recursive member -- that is the brake pedal.
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, manager_id, 0 AS depth
    FROM employees
    WHERE emp_name = 'Grace Hopper'

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.manager_id, o.depth + 1
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
    WHERE o.depth < 2                      -- <<< stop here, not in the outer query
)
SELECT depth, emp_name
FROM org
ORDER BY depth, emp_name;

-- @@Q9
-- Q9. Who is the lowest common manager of Ken Thompson and Frances Allen?
--     Collect both ancestor chains, keep the nodes reached from both,
--     and take the one closest to the starting employees.
WITH RECURSIVE ancestors AS (
    SELECT emp_id AS start_id, emp_id AS node_id, manager_id, 0 AS levels_up
    FROM employees
    WHERE emp_name IN ('Ken Thompson', 'Frances Allen')

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
HAVING COUNT(DISTINCT a.start_id) = 2      -- reachable from BOTH employees
ORDER BY hops_from_furthest_employee ASC   -- fewest hops = lowest in the tree
LIMIT 1;

-- @@Q10
-- Q10. How tall is the org chart, and who sits at the end of the longest chain?
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, manager_id, 1 AS depth,
           CAST(emp_name AS CHAR(1000)) AS chain
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.manager_id, o.depth + 1,
           CAST(CONCAT(o.chain, ' > ', e.emp_name) AS CHAR(1000))
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
)
SELECT depth AS org_height, emp_name AS deepest_employee, chain
FROM org
WHERE depth = (SELECT MAX(depth) FROM org)
ORDER BY emp_name;

-- ############################################################################
-- PART B -- BILL OF MATERIALS (tables: parts + bom)
-- The hierarchy lives in its own EDGE table, so a part can have many parents
-- and each edge carries a quantity. This is a DAG, not a tree.
-- ############################################################################

-- @@Q11
-- Q11. What goes directly into a Road Bicycle? (one level, no recursion)
SELECT c.part_name AS component, b.quantity, c.part_type
FROM bom b
JOIN parts c ON c.part_id = b.component_id
WHERE b.assembly_id = 100
ORDER BY c.part_name;

-- @@Q12
-- Q12. Fully explode the Road Bicycle: every part at every level, with the
--      quantity needed for ONE bicycle.
--      KEY IDEA: quantities MULTIPLY down the path (2 wheels x 32 spokes = 64).
WITH RECURSIVE explosion AS (
    SELECT b.component_id                          AS part_id,
           CAST(b.quantity AS DECIMAL(20,3))       AS qty_per_bike,
           1                                       AS lvl,
           CAST(p.part_name AS CHAR(1000))          AS path
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
       x.qty_per_bike,
       p.part_type
FROM explosion x
JOIN parts p ON p.part_id = x.part_id
ORDER BY x.path;

-- @@Q13
-- Q13. Shopping list: how many of each PURCHASED part for one Road Bicycle?
--      Because this is a DAG the same part appears on several paths
--      (Bolt M5 lives in 5 different assemblies), so the paths must be SUMmed.
WITH RECURSIVE explosion AS (
    SELECT component_id AS part_id, CAST(quantity AS DECIMAL(20,3)) AS qty
    FROM bom
    WHERE assembly_id = 100

    UNION ALL

    SELECT b.component_id, CAST(x.qty * b.quantity AS DECIMAL(20,3))
    FROM explosion x
    JOIN bom b ON b.assembly_id = x.part_id
)
SELECT p.part_name,
       SUM(x.qty)                 AS qty_needed,
       p.unit_cost,
       SUM(x.qty) * p.unit_cost   AS line_cost
FROM explosion x
JOIN parts p ON p.part_id = x.part_id
WHERE p.part_type = 'buy'         -- only things we actually order
GROUP BY p.part_id, p.part_name, p.unit_cost
ORDER BY line_cost DESC;

-- @@Q14
-- Q14. Rolled-up material cost of EVERY assembly, cheapest query first:
--      anchor at all assemblies at once, then aggregate per root.
WITH RECURSIVE explosion AS (
    SELECT p.part_id AS root_id, b.component_id AS part_id,
           CAST(b.quantity AS DECIMAL(20,3)) AS qty
    FROM parts p
    JOIN bom b ON b.assembly_id = p.part_id
    WHERE p.part_type = 'assembly'

    UNION ALL

    SELECT x.root_id, b.component_id, CAST(x.qty * b.quantity AS DECIMAL(20,3))
    FROM explosion x
    JOIN bom b ON b.assembly_id = x.part_id
)
SELECT r.part_name                      AS assembly,
       COUNT(DISTINCT x.part_id)        AS distinct_parts_used,
       SUM(CASE WHEN p.part_type = 'buy'
                THEN x.qty * p.unit_cost ELSE 0 END) AS rolled_up_cost
FROM explosion x
JOIN parts r ON r.part_id = x.root_id
JOIN parts p ON p.part_id = x.part_id
GROUP BY r.part_id, r.part_name
ORDER BY rolled_up_cost DESC;

-- @@Q15
-- Q15. WHERE-USED, the reverse question: which assemblies and finished
--      products contain a Bearing?
WITH RECURSIVE used_in AS (
    SELECT b.assembly_id, 1 AS levels_up
    FROM bom b
    JOIN parts p ON p.part_id = b.component_id
    WHERE p.part_name = 'Bearing'

    UNION ALL

    SELECT b.assembly_id, u.levels_up + 1
    FROM used_in u
    JOIN bom b ON b.component_id = u.assembly_id   -- flipped: child -> parent
)
SELECT p.part_name AS used_in, MIN(u.levels_up) AS nearest_level
FROM used_in u
JOIN parts p ON p.part_id = u.assembly_id
GROUP BY p.part_id, p.part_name
ORDER BY nearest_level, used_in;

-- @@Q16
-- Q16. Production run: 50 Road Bicycles + 30 Mountain Bicycles.
--      Several roots in the anchor, each with its own starting multiplier.
WITH RECURSIVE build_order AS (
    SELECT 100 AS part_id, CAST(50 AS DECIMAL(20,3)) AS qty
    UNION ALL
    SELECT 200,            CAST(30 AS DECIMAL(20,3))
),
explosion AS (
    SELECT b.component_id AS part_id, CAST(o.qty * b.quantity AS DECIMAL(20,3)) AS qty
    FROM build_order o
    JOIN bom b ON b.assembly_id = o.part_id

    UNION ALL

    SELECT b.component_id, CAST(x.qty * b.quantity AS DECIMAL(20,3))
    FROM explosion x
    JOIN bom b ON b.assembly_id = x.part_id
)
SELECT p.part_name,
       SUM(x.qty)               AS qty_to_purchase,
       SUM(x.qty) * p.unit_cost AS line_cost
FROM explosion x
JOIN parts p ON p.part_id = x.part_id
WHERE p.part_type = 'buy'
GROUP BY p.part_id, p.part_name, p.unit_cost
ORDER BY line_cost DESC;

-- ############################################################################
-- PART C -- CYCLES (table: legacy_routes)
-- ############################################################################

-- @@Q17
-- Q17. Where can I fly starting from BLR?
--      The data contains BLR -> DXB -> LHR -> JFK -> BLR. A naive recursion
--      never terminates. The fix: carry the visited path and refuse to
--      re-enter an airport already on it.
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
    WHERE rc.visited NOT LIKE CONCAT('%>', r.dest, '>%')   -- <<< the cycle guard
      AND rc.hops < 10                                     -- belt and braces
)
SELECT hops, airport, visited AS route_taken
FROM reachable
ORDER BY hops, airport;
