-- ============================================================================
--  Hierarchical Queries Tutorial -- SETUP SCRIPT  (MySQL 8+ / 9.x)
--
--  Run with:  mysql -uroot -p < 01_setup.sql
--
--  Creates three playgrounds in database `hierarchical_db`:
--    1. employees      : a classic org chart          (a TREE, adjacency list)
--    2. parts + bom    : a bill of materials          (a DAG, edge table)
--    3. legacy_routes  : a deliberately broken graph  (contains a CYCLE)
-- ============================================================================

CREATE DATABASE IF NOT EXISTS hierarchical_db;
USE hierarchical_db;

DROP TABLE IF EXISTS bom;
DROP TABLE IF EXISTS parts;
DROP TABLE IF EXISTS employees;
DROP TABLE IF EXISTS legacy_routes;

-- ----------------------------------------------------------------------------
-- DOMAIN 1: ORG CHART
-- The "adjacency list" model: every row stores a pointer to its own parent.
-- ----------------------------------------------------------------------------
CREATE TABLE employees (
    emp_id      INT           PRIMARY KEY,
    emp_name    VARCHAR(60)   NOT NULL,
    job_title   VARCHAR(60)   NOT NULL,
    department  VARCHAR(40)   NOT NULL,
    manager_id  INT           NULL,          -- NULL => this person is a root
    salary      DECIMAL(10,2) NOT NULL,
    hire_date   DATE          NOT NULL,
    CONSTRAINT fk_emp_mgr FOREIGN KEY (manager_id) REFERENCES employees(emp_id)
);

CREATE INDEX ix_employees_manager ON employees(manager_id);   -- essential for speed

INSERT INTO employees
    (emp_id, emp_name,            job_title,                 department,    manager_id, salary,    hire_date) VALUES
    (1,  'Ada Lovelace',      'Chief Executive Officer', 'Executive',   NULL, 320000.00, '2014-01-06'),
    (2,  'Grace Hopper',      'Chief Technology Officer','Engineering', 1,    260000.00, '2014-03-17'),
    (3,  'Katherine Johnson', 'Chief Financial Officer', 'Finance',     1,    250000.00, '2014-05-02'),
    (4,  'Linus Pauling',     'VP Engineering',          'Engineering', 2,    210000.00, '2015-07-20'),
    (5,  'Barbara Liskov',    'VP Data',                 'Data',        2,    205000.00, '2015-09-14'),
    (6,  'Alan Turing',       'Engineering Manager',     'Engineering', 4,    175000.00, '2016-02-29'),
    (7,  'Margaret Hamilton', 'Engineering Manager',     'Engineering', 4,    178000.00, '2016-04-11'),
    (8,  'Tim Berners-Lee',   'Senior Engineer',         'Engineering', 6,    150000.00, '2017-06-05'),
    (9,  'Radia Perlman',     'Senior Engineer',         'Engineering', 6,    148000.00, '2017-08-21'),
    (10, 'Ken Thompson',      'Engineer',                'Engineering', 8,    120000.00, '2019-01-14'),
    (11, 'Dennis Ritchie',    'Engineer',                'Engineering', 8,    122000.00, '2019-03-25'),
    (12, 'Brian Kernighan',   'Engineer',                'Engineering', 9,    118000.00, '2020-10-12'),
    (13, 'Jean Bartik',       'Senior Engineer',         'Engineering', 7,    145000.00, '2018-05-07'),
    (14, 'Frances Allen',     'Engineer',                'Engineering', 13,   119000.00, '2021-02-01'),
    (15, 'Donald Knuth',      'Data Scientist',          'Data',        5,    160000.00, '2018-11-19'),
    (16, 'Edgar Codd',        'Data Engineer',           'Data',        5,    158000.00, '2018-12-03'),
    (17, 'Jim Gray',          'Data Analyst',            'Data',        16,   112000.00, '2022-07-18'),
    (18, 'Shafi Goldwasser',  'Senior Accountant',       'Finance',     3,    105000.00, '2017-09-11'),
    (19, 'Mary Jackson',      'Accountant',              'Finance',     3,    103000.00, '2020-06-15'),
    (20, 'Hedy Lamarr',       'Office Manager',          'Operations',  1,     98000.00, '2016-08-08');

-- The shape you just created (6 levels deep):
--
--   Ada Lovelace (CEO)
--   |-- Grace Hopper (CTO)
--   |   |-- Linus Pauling (VP Engineering)
--   |   |   |-- Alan Turing (Eng Manager)
--   |   |   |   |-- Tim Berners-Lee (Senior Eng)
--   |   |   |   |   |-- Ken Thompson (Engineer)
--   |   |   |   |   `-- Dennis Ritchie (Engineer)
--   |   |   |   `-- Radia Perlman (Senior Eng)
--   |   |   |       `-- Brian Kernighan (Engineer)
--   |   |   `-- Margaret Hamilton (Eng Manager)
--   |   |       `-- Jean Bartik (Senior Eng)
--   |   |           `-- Frances Allen (Engineer)
--   |   `-- Barbara Liskov (VP Data)
--   |       |-- Donald Knuth (Data Scientist)
--   |       `-- Edgar Codd (Data Engineer)
--   |           `-- Jim Gray (Data Analyst)
--   |-- Katherine Johnson (CFO)
--   |   |-- Shafi Goldwasser (Senior Accountant)
--   |   `-- Mary Jackson (Accountant)
--   `-- Hedy Lamarr (Office Manager)

-- ----------------------------------------------------------------------------
-- DOMAIN 2: BILL OF MATERIALS
-- The "edge table" model: the hierarchy lives in its OWN table, so a child
-- can have many parents and every edge can carry data (here: quantity).
-- ----------------------------------------------------------------------------
CREATE TABLE parts (
    part_id    INT           PRIMARY KEY,
    part_name  VARCHAR(60)   NOT NULL,
    part_type  VARCHAR(10)   NOT NULL,   -- 'assembly' (has children) or 'buy' (purchased)
    unit_cost  DECIMAL(10,2) NULL,       -- NULL for assemblies: their cost is rolled up
    uom        VARCHAR(10)   NOT NULL    -- unit of measure
);

CREATE TABLE bom (                        -- "which part contains which part, how many"
    assembly_id  INT           NOT NULL,
    component_id INT           NOT NULL,
    quantity     DECIMAL(10,3) NOT NULL,
    PRIMARY KEY (assembly_id, component_id),
    CONSTRAINT fk_bom_assembly  FOREIGN KEY (assembly_id)  REFERENCES parts(part_id),
    CONSTRAINT fk_bom_component FOREIGN KEY (component_id) REFERENCES parts(part_id)
);

CREATE INDEX ix_bom_component ON bom(component_id);   -- for "where-used" (upward) queries

INSERT INTO parts (part_id, part_name, part_type, unit_cost, uom) VALUES
    (100, 'Road Bicycle',             'assembly', NULL,  'ea'),
    (200, 'Mountain Bicycle',         'assembly', NULL,  'ea'),
    (110, 'Frame Assembly',           'assembly', NULL,  'ea'),
    (111, 'Frame Tubing Set',         'buy',      85.00, 'set'),
    (112, 'Rigid Fork Assembly',      'assembly', NULL,  'ea'),
    (113, 'Fork Tube',                'buy',      22.00, 'ea'),
    (114, 'Fork Crown',               'buy',       9.50, 'ea'),
    (120, 'Wheel Assembly',           'assembly', NULL,  'ea'),
    (121, 'Rim',                      'buy',      18.00, 'ea'),
    (122, 'Spoke',                    'buy',       0.35, 'ea'),
    (123, 'Hub Assembly',             'assembly', NULL,  'ea'),
    (124, 'Hub Shell',                'buy',       6.00, 'ea'),
    (125, 'Bearing',                  'buy',       1.20, 'ea'),
    (126, 'Tire',                     'buy',      24.00, 'ea'),
    (127, 'Inner Tube',               'buy',       6.50, 'ea'),
    (130, 'Drivetrain Assembly',      'assembly', NULL,  'ea'),
    (131, 'Crankset',                 'buy',      95.00, 'ea'),
    (132, 'Chain',                    'buy',      28.00, 'ea'),
    (133, 'Cassette',                 'buy',      42.00, 'ea'),
    (134, 'Rear Derailleur',          'buy',      60.00, 'ea'),
    (140, 'Brake Assembly',           'assembly', NULL,  'ea'),
    (141, 'Brake Caliper',            'buy',      32.00, 'ea'),
    (142, 'Brake Lever',              'buy',      18.00, 'ea'),
    (143, 'Brake Cable',              'buy',       4.00, 'ea'),
    (150, 'Cockpit Assembly',         'assembly', NULL,  'ea'),
    (151, 'Handlebar',                'buy',      30.00, 'ea'),
    (152, 'Stem',                     'buy',      25.00, 'ea'),
    (153, 'Grip',                     'buy',       6.00, 'ea'),
    (160, 'Seat Assembly',            'assembly', NULL,  'ea'),
    (161, 'Saddle',                   'buy',      45.00, 'ea'),
    (162, 'Seatpost',                 'buy',      28.00, 'ea'),
    (170, 'Suspension Fork Assembly', 'assembly', NULL,  'ea'),
    (171, 'Stanchion',                'buy',      48.00, 'ea'),
    (172, 'Damper Cartridge',         'buy',      65.00, 'ea'),
    (999, 'Bolt M5',                  'buy',       0.20, 'ea');

INSERT INTO bom (assembly_id, component_id, quantity) VALUES
    -- Road Bicycle
    (100, 110,  1), (100, 120,  2), (100, 130, 1), (100, 140, 2), (100, 150, 1), (100, 160, 1),
    -- Mountain Bicycle (reuses wheels, drivetrain, brakes, cockpit and seat)
    (200, 170,  1), (200, 120,  2), (200, 130, 1), (200, 140, 2), (200, 150, 1), (200, 160, 1),
    -- Frame Assembly
    (110, 111,  1), (110, 112,  1), (110, 999, 4),
    -- Rigid Fork Assembly
    (112, 113,  1), (112, 114,  1),
    -- Wheel Assembly
    (120, 121,  1), (120, 122, 32), (120, 123, 1), (120, 126, 1), (120, 127, 1),
    -- Hub Assembly
    (123, 124,  1), (123, 125,  2),
    -- Drivetrain Assembly
    (130, 131,  1), (130, 132,  1), (130, 133, 1), (130, 134, 1), (130, 999, 6),
    -- Brake Assembly
    (140, 141,  1), (140, 142,  1), (140, 143, 1), (140, 999, 2),
    -- Cockpit Assembly
    (150, 151,  1), (150, 152,  1), (150, 153, 2), (150, 999, 4),
    -- Seat Assembly
    (160, 161,  1), (160, 162,  1), (160, 999, 1),
    -- Suspension Fork Assembly
    (170, 171,  2), (170, 172,  1), (170, 999, 2);

-- ----------------------------------------------------------------------------
-- DOMAIN 3: A BROKEN GRAPH, on purpose -- for the lesson on CYCLES.
-- Flight legs where somebody fat-fingered the data into a loop.
-- ----------------------------------------------------------------------------
CREATE TABLE legacy_routes (
    route_id  INT         PRIMARY KEY,
    origin    VARCHAR(10) NOT NULL,
    dest      VARCHAR(10) NOT NULL
);

INSERT INTO legacy_routes (route_id, origin, dest) VALUES
    (1, 'BLR', 'DXB'),
    (2, 'DXB', 'LHR'),
    (3, 'LHR', 'JFK'),
    (4, 'JFK', 'BLR'),   -- <-- closes the loop: BLR -> DXB -> LHR -> JFK -> BLR -> ...
    (5, 'DXB', 'SIN'),
    (6, 'SIN', 'SYD');

SELECT 'employees'     AS table_name, COUNT(*) AS rows_loaded FROM employees
UNION ALL SELECT 'parts',         COUNT(*) FROM parts
UNION ALL SELECT 'bom',           COUNT(*) FROM bom
UNION ALL SELECT 'legacy_routes', COUNT(*) FROM legacy_routes;
