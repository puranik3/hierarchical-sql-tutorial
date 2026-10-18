USE hierarchical_db;

-- @@E1
-- E1. Everyone in Alan Turing's organisation, with how many levels below him.
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
WHERE levels_below > 0
ORDER BY levels_below, emp_name;

-- @@E2
-- E2. Which C-level division does each employee sit in?
--     The answer is their ancestor at depth 2 -- so carry it down the recursion.
WITH RECURSIVE org AS (
    SELECT emp_id, emp_name, manager_id, 1 AS depth,
           CAST('(the CEO herself)' AS CHAR(60)) AS division_head
    FROM employees
    WHERE manager_id IS NULL

    UNION ALL

    SELECT e.emp_id, e.emp_name, e.manager_id, o.depth + 1,
           -- at depth 2 the employee IS the division head; deeper, inherit it
           CAST(CASE WHEN o.depth = 1 THEN e.emp_name ELSE o.division_head END AS CHAR(60))
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id
)
SELECT division_head, depth, emp_name
FROM org
ORDER BY division_head, depth, emp_name;

-- @@E3
-- E3. How many Bolt M5 does ONE Mountain Bicycle need?
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

-- @@E4
-- E4. Which parts go into a Road Bicycle but NOT into a Mountain Bicycle?
WITH RECURSIVE explosion AS (
    SELECT b.assembly_id AS product_id, b.component_id AS part_id
    FROM bom b
    WHERE b.assembly_id IN (100, 200)

    UNION ALL

    SELECT x.product_id, b.component_id
    FROM explosion x
    JOIN bom b ON b.assembly_id = x.part_id
)
SELECT DISTINCT p.part_name, p.part_type
FROM explosion x
JOIN parts p ON p.part_id = x.part_id
WHERE x.product_id = 100
  AND x.part_id NOT IN (SELECT part_id FROM explosion WHERE product_id = 200)
ORDER BY p.part_name;

-- @@E5
-- E5. Every manager with the average salary of their subtree, excluding themselves.
WITH RECURSIVE closure AS (
    SELECT emp_id AS root_id, emp_id AS node_id, 0 AS dist
    FROM employees

    UNION ALL

    SELECT c.root_id, e.emp_id, c.dist + 1
    FROM closure c
    JOIN employees e ON e.manager_id = c.node_id
)
SELECT r.emp_name                    AS manager,
       r.salary                      AS own_salary,
       COUNT(*)                      AS subtree_headcount,
       ROUND(AVG(e.salary), 2)       AS avg_subtree_salary
FROM closure c
JOIN employees r ON r.emp_id = c.root_id
JOIN employees e ON e.emp_id = c.node_id
WHERE c.dist > 0                     -- exclude the manager from their own average
GROUP BY r.emp_id, r.emp_name, r.salary
ORDER BY avg_subtree_salary DESC;

-- @@CAP
-- CAPSTONE. Span-of-control and cost report for Grace Hopper's organisation.
WITH RECURSIVE
-- (1) Grace Hopper's organisation, with depth and a sortable path.
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
SELECT o.emp_name                                          AS manager,
       o.depth                                             AS depth_below_cto,
       SUM(CASE WHEN c.dist = 1 THEN 1 ELSE 0 END)         AS direct_reports,
       COUNT(*)                                            AS subtree_headcount,
       SUM(e.salary)                                       AS subtree_salary,
       f.ceo_path                                          AS reporting_line
FROM eng_org o
JOIN closure  c ON c.root_id = o.emp_id AND c.dist > 0     -- descendants only
JOIN employees e ON e.emp_id = c.node_id
JOIN from_ceo f ON f.emp_id = o.emp_id
GROUP BY o.emp_id, o.emp_name, o.depth, o.sort_path, f.ceo_path
ORDER BY o.sort_path;
