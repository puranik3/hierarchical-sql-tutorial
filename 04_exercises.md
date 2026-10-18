# Exercises — test your learning

Work against `hierarchical_db` (load `01_setup.sql` first). Try each one before
looking at `05_answers.md`; the runnable answers are in `05_answers.sql`.

```bash
mysql -uroot -p --table
mysql> USE hierarchical_db;
```

The reference diagrams are in the comments at the top of `01_setup.sql` — the
org chart shape and the full BOM edge list. Use them to check your answers by
hand before you trust the query.

---

## Warm-ups

**E1.** List everybody in **Alan Turing's** organisation, showing how many
levels below him each person sits. Exclude Alan himself.
*You should get 5 people across 2 levels.*

**E2.** Every employee belongs to a "division" headed by one of the CEO's direct
reports. For each employee, show that **division head's name** alongside their
own, plus their depth. Ada Lovelace has no division head — label her row
something sensible.
*Hint: the division head is the employee's ancestor at depth 2. Carry it down
the recursion instead of looking it up afterwards.*

**E3.** How many **Bolt M5** does a single **Mountain Bicycle** require?
*One row. Count it by hand from the BOM comments first — getting the
multiplication right is the whole point.*

**E4.** Which parts go into the **Road Bicycle** but **not** into the Mountain
Bicycle, at any level?
*Hint: explode both products in one CTE, keeping a `product_id` column, then
compare the two sets.*

**E5.** For every manager, show their own salary, their subtree headcount
(excluding themselves) and the **average salary of their subtree, excluding
themselves**. Order by that average, highest first.
*Hint: this is the Q7 closure pattern with one extra predicate.*

---

## Capstone question

**C1. Span-of-control and cost report for the CTO's organisation.**

Produce one row for **every employee in Grace Hopper's organisation, including
Grace herself, who manages at least one person**. Each row must show:

| Column | Meaning |
|---|---|
| `manager` | the employee's name |
| `depth_below_cto` | 0 for Grace Hopper, 1 for her direct reports, and so on |
| `direct_reports` | how many people report to them directly |
| `subtree_headcount` | everyone below them at any depth, excluding themselves |
| `subtree_salary` | total salary of that subtree, excluding their own salary |
| `reporting_line` | their full path from the CEO, e.g. `Ada Lovelace > Grace Hopper > Linus Pauling` |

Order the result so it reads like an org chart — each manager immediately
followed by their own subordinate managers, not sorted alphabetically or by
headcount.

*You should get 9 rows. Grace Hopper's `subtree_headcount` is 14.*

This one deliberately needs three ideas at once: a subtree walk anchored at one
node (depth + sort path), a closure for the per-subtree aggregates, and a
separate downward walk from the root for the `reporting_line`. Getting the
"excluding themselves" boundary right in both aggregate columns is the part most
people get wrong on the first attempt.

---

## Self-check

If you can do these without looking things up, you have the concept:

1. Why `UNION ALL` and not `UNION`?
2. What single change turns a descendants query into an ancestors query?
3. Why must the path column be `CAST` in **both** members of the CTE?
4. Where does a depth filter belong, and why does it matter?
5. Why can't you put `SUM()` inside the recursive member?
6. Why does a cycle in `employees` make a top-down query return *too few* rows
   rather than hang?
