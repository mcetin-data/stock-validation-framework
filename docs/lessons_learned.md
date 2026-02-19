# Lessons Learned - Stock Validation Project

**Project:** BIPROD to Azure Migration Validation  
**Author:** Mehmet Cetin  
**Date:** February 2026  

---

## Introduction

This document captures key technical insights, best practices, and hard-learned lessons from validating a large-scale data migration. These lessons are applicable to future migration projects, data validation initiatives, and general data engineering work.

---

## Table of Contents

1. [SQL & Data Extraction](#sql--data-extraction)
2. [Power Query & Data Transformation](#power-query--data-transformation)
3. [Power BI & Visualization](#power-bi--visualization)
4. [Data Validation Methodology](#data-validation-methodology)
5. [Project Management](#project-management)
6. [Communication & Stakeholder Management](#communication--stakeholder-management)
7. [What I Would Do Differently](#what-i-would-do-differently)

---

## SQL & Data Extraction

### Lesson 1: Always Use DISTINCT When Joining to Dimension Tables

**What Happened:**
- Joined fact table to Product dimension on `itemid`
- Product has 3 rows per itemid (one per size: S, M, L)
- Result: 48,000 fact rows became 144,000 rows (3x multiplication!)

**Root Cause:**
- Dimension tables often have multiple rows per natural key
- Without DISTINCT, join creates cartesian product

**Solution:**
```sql
LEFT JOIN (
    SELECT DISTINCT itemid, shopcode, Seasoncode
    FROM DIM.Product
) p ON v.ITEM = p.itemid
```

**Takeaway:** 
> **Always check row counts before and after joins. If rows multiply unexpectedly, investigate the dimension table granularity.**

---

### Lesson 2: Natural Keys Are More Migration-Safe Than Surrogate Keys

**What Happened:**
- Initially tried joining on `PRODUCT_WID` (system-generated ID)
- Azure regenerated PRODUCT_WID during migration
- Same product had different PRODUCT_WID in Azure vs BIPROD
- Comparison failed completely

**Solution:**
- Switched to natural keys: `barcode`, `itemid + inventcolorid`
- These remain consistent across systems

**Comparison:**

| Key Type | Example | Migration-Safe? |
|----------|---------|-----------------|
| Surrogate | PRODUCT_WID = 123456 | ❌ No - regenerated |
| Natural | barcode = "5400582807632" | ✅ Yes - business identifier |
| Composite Natural | itemid + inventcolorid | ✅ Yes - stable across systems |

**Takeaway:**
> **For cross-system comparisons, always use natural/business keys. Surrogate keys are system-specific and unreliable for migration validation.**

---

### Lesson 3: Include Entity Identifiers in GROUP BY

**What Happened:**
- Aggregated stock by `barcode + STOREID`
- Differences mysteriously canceled out at aggregate level
- Root cause: Same barcode existed in both JBC and GF entities
- Opposite-signed quantities canceled each other (JBC: +100, GF: -100 = 0)

**Solution:**
```sql
GROUP BY 
    barcode, 
    STOREID,
    AX_DATAAREAID  -- Entity identifier
```

**Takeaway:**
> **Always include entity/company identifiers in groupings when dealing with multi-entity systems. Otherwise, cross-entity records can mask real differences.**

---

### Lesson 4: Filter Early, Join Late

**Performance Discovery:**
```sql
-- Slow: 45 seconds ❌
SELECT ... 
FROM LargeFactTable v
LEFT JOIN Product p ON v.PRODUCT_WID = p.PRODUCT_WID
WHERE v.DATE_WID = 20260131

-- Fast: 5 seconds ✅
SELECT ... 
FROM (
    SELECT * FROM LargeFactTable 
    WHERE DATE_WID = 20260131
) v
LEFT JOIN Product p ON v.PRODUCT_WID = p.PRODUCT_WID
```

**Why:** Filtering before join reduces rows processed in the join operation

**Takeaway:**
> **Apply filters as early as possible in the query. Use subqueries or CTEs to filter before expensive joins.**

---

## Power Query & Data Transformation

### Lesson 5: Table.Distinct() Is Not Optional - It's Essential

**The Bug:**
- Power Query merge created 356,000 rows from 48,000 source rows
- Even though SQL queries used DISTINCT, Power Query still multiplied rows
- Root cause: Data type mismatches, trailing spaces, or caching issues

**The Fix:**
```m
// ALWAYS do this before merging
Azure_Distinct = Table.Distinct(Azure_Renamed, {"barcode", "STOREID"}),
BIPROD_Distinct = Table.Distinct(BIPROD_Renamed, {"barcode", "STOREID"}),

Merged = Table.NestedJoin(
    Azure_Distinct,  // Not Azure_Renamed!
    BIPROD_Distinct,
    ...
)
```

**Performance Cost:** ~2-3 seconds for 1M rows

**Takeaway:**
> **Always apply Table.Distinct() on join keys BEFORE merging, even if you think the source data is unique. It's cheap insurance against catastrophic row multiplication.**

---

### Lesson 6: Null Semantics Are Critical - Never Convert Null to Zero Prematurely

**The Problem:**
- Initial approach: `Total_QTY_Diff = SUM(QTY_Diff column)`
- Returned -28,649
- But actual difference was -112,698
- **Gap of 84,049 units!**

**Root Cause:**
- `QTY_Diff` column had `null` for Azure_Only and BIPROD_Only records
- `SUM()` ignores nulls
- Only counted Mismatch records, missed one-sided records

**The Fix:**
```m
// In Power Query - PRESERVE nulls
QTY_Diff = if [Azure_QTY] <> null and [BIPROD_QTY] <> null
           then [Azure_QTY] - [BIPROD_QTY]
           else null  // Don't convert to 0!

// In DAX - Handle nulls explicitly
Total_QTY_Diff = SUMX(
    Table,
    COALESCE([Azure_QTY], 0) - COALESCE([BIPROD_QTY], 0)
)
```

**Takeaway:**
> **Null means "missing data" and zero means "zero value" - they are NOT the same. Preserve nulls throughout the pipeline and only convert to zero when absolutely necessary for calculations.**

---

### Lesson 7: Full Outer Join Is Usually What You Need for Validation

**Why Not Inner Join?**
```
Scenario:
- Azure has 100 new products (not in BIPROD yet)
- BIPROD has 50 discontinued products (removed from Azure)

INNER JOIN: Returns 0 rows for these 150 products ❌
            Silently hides migration gaps

FULL OUTER: Returns all 150 products ✅
            Tags as "Azure_Only" or "BIPROD_Only"
            Enables complete validation
```

**When to Use Each:**

| Join Type | Use Case |
|-----------|----------|
| INNER | When you only care about matching records |
| LEFT | When one system is "source of truth" |
| RIGHT | Rare (same as LEFT with reversed tables) |
| FULL OUTER | **Validation/comparison between two systems** ✅ |

**Takeaway:**
> **For data validation and migration comparison, default to FULL OUTER JOIN. It's the only join type that captures all records from both sides.**

---

### Lesson 8: Power Query Can Handle Way More Data Than Excel Worksheets

**Discovery:**
- Power Query processed 1.8M rows in memory without issues
- But Excel worksheet limit = 1,048,576 rows
- Power Query comparison completed successfully, Excel rendering failed

**Workflow:**
```
SQL Query (1.8M rows) 
→ Power Query Merge (1.8M rows - works fine ✅)
→ Load to Excel (fails - too many rows ❌)
→ Load to Power BI (works fine ✅)
```

**Takeaway:**
> **Power Query's in-memory engine can process millions of rows. The bottleneck is the visualization layer (Excel vs Power BI), not the transformation engine.**

**Best Practice:**
- Excel: Use for datasets <500K rows
- Power BI: Use for datasets >500K rows

---

## Power BI & Visualization

### Lesson 9: DAX Variables Prevent Redundant Calculations

**Bad Pattern:**
```dax
Alignment_Pct = [Match_Count] / ([Match_Count] + [Mismatch_Count] + [Azure_Only_Count] + [BIPROD_Only_Count])
```

**Problem:** Each measure reference triggers a separate calculation

**Good Pattern:**
```dax
Alignment_Pct = 
VAR Matches = [Match_Count]
VAR Mismatches = [Mismatch_Count]
VAR AzureOnly = [Azure_Only_Count]
VAR BIPRODOnly = [BIPROD_Only_Count]
VAR Total = Matches + Mismatches + AzureOnly + BIPRODOnly
RETURN DIVIDE(Matches, Total, 0)
```

**Performance Improvement:** 3-5x faster on large datasets

**Takeaway:**
> **Use VAR to store intermediate calculations in DAX. It makes measures more readable AND faster.**

---

### Lesson 10: Match Status Should Be a Column, Not a Measure

**What I Tried First:**
```dax
// As a measure ❌
Match_Status = 
IF([Azure_QTY] = BLANK(), "BIPROD_Only",
IF([BIPROD_QTY] = BLANK(), "Azure_Only",
IF([QTY_Diff] = 0, "Match", "Mismatch")))
```

**Problems:**
- Doesn't work in filter context
- Can't use as slicer
- Recalculates on every cell

**Better Approach:**
```m
// As a column in Power Query ✅
Match_Status = 
  if [Azure_QTY] = null then "BIPROD_Only"
  else if [BIPROD_QTY] = null then "Azure_Only"
  else if [QTY_Diff] = 0 then "Match"
  else "Mismatch"
```

**Benefits:**
- Works as slicer
- Pre-calculated (faster)
- Consistent across all visuals

**Takeaway:**
> **Categorical labels that don't change should be calculated columns (Power Query), not measures (DAX). Use measures only for dynamic aggregations.**

---

### Lesson 11: Start with Aggregated View, Drill Down Later

**Initial Mistake:**
- Built detail-level table first (barcode + STOREID granularity)
- 1.8M rows, slow to render
- Hard to see overall picture

**Better Approach:**
```
Page 1: Executive Summary (grand totals only)
Page 2: Store Level (aggregated by store)
Page 3: Barcode Level (aggregated by barcode)
Page 4: Full Detail (barcode + store - for drilling)
```

**Benefits:**
- Fast load times for high-level pages
- Progressive disclosure (don't overwhelm users)
- Easier to spot trends at aggregate level

**Takeaway:**
> **Design dashboards top-down: Start with KPIs and aggregates, provide drill-down paths to details. Don't dump a 1M row table on users.**

---

## Data Validation Methodology

### Lesson 12: Validate at Multiple Granularity Levels

**Why This Matters:**

Example discovered during project:
```
Grand Total Level:
Azure:  3,733,779 units
BIPROD: 3,744,240 units
Difference: -10,461 units (looks small - 0.28%)

Store Level:
Store 001: Azure 45,100 | BIPROD 45,230 | Diff: -130 ✅
Store 002: Azure 41,900 | BIPROD 42,100 | Diff: -200 ✅
...looks aligned

Barcode Level:
Barcode ABC: Azure 1,200 | BIPROD 800 | Diff: +400 ❌
Barcode XYZ: Azure 500 | BIPROD 900 | Diff: -400 ❌
...opposite differences cancel out!
```

**The Paradox:** Differences can cancel out at higher levels

**Solution:** Always validate at:
1. **Grand total** (quick sanity check)
2. **Store/region level** (geographic patterns)
3. **Product/barcode level** (specific items)
4. **Most granular level** (catch everything)

**Takeaway:**
> **Never rely on aggregate-level validation alone. Always validate at the most granular level possible, then roll up. Differences hide in aggregations.**

---

### Lesson 13: Document "Expected Differences" Separately from "Errors"

**The Issue:**
- Found -10,461 unit gap between Azure and BIPROD
- Initially flagged as potential data loss
- After investigation: Azure contains recent negative stock adjustments (returns, damages)
- This is **expected behavior**, not an error

**Better Approach:**

Categorize findings:
```
✅ Expected Differences:
- Timing differences (Azure more current)
- Negative adjustments in Azure, not yet in BIPROD
- Partial historical data (by design)

❌ Actual Errors:
- 155 duplicate records in Azure (ETL bug)
- 92% missing data in CKS view (incomplete load)
```

**Communication Impact:**
- Stakeholders understand the difference
- Reduces false alarms
- Builds trust in validation process

**Takeaway:**
> **Not all differences are errors. Clearly distinguish between expected variances and actual data quality issues in your reporting.**

---

### Lesson 14: One Example Is Worth a Thousand Rows

**Before:**
"Azure has 155 duplicate records affecting 8 barcodes"

**After:**
```
Example duplicate:
barcode: 5400582807632
STOREID: 001
DATE_WID: 20260131
Occurrences: 98 rows (should be 1)

All 98 rows have:
- Same keys
- Different QTY values (ranging from 5 to 150)
- Suggests ETL job inserted same record 98 times with different data
```

**Impact:** Engineering team immediately understood the problem

**Takeaway:**
> **Always include specific examples when reporting data issues. Abstract numbers don't communicate as clearly as concrete cases.**

---

## Project Management

### Lesson 15: Build a Template First, Then Scale

**What I Did:**
1. Built validation for ONE view (STOCK_ONLINE_AVAILABLE)
2. Tested thoroughly
3. Fixed all bugs (cartesian product, null handling, etc.)
4. Created reusable template
5. Applied template to remaining 5 views

**Time Saved:**
- First view: 8 hours
- Views 2-6: 1 hour each = 5 hours
- Total: 13 hours vs 48 hours (6 × 8) if built from scratch each time

**Takeaway:**
> **Invest time upfront to build a high-quality template. The ROI comes when you replicate it across multiple use cases.**

---

### Lesson 16: Automate Early, Even for "Temporary" Projects

**Initial Plan:**
"This is just a 1-month validation project, not worth automating"

**Reality:**
- Manager asked for twice-weekly updates
- Manual refresh + email = 30 mins × 2/week × 4 weeks = 4 hours
- Building automation = 3 hours
- **Net savings: 1 hour + eliminated human error**

**Bonus:**
- Automation became portfolio piece
- Shows initiative and engineering thinking
- Reusable for future projects

**Takeaway:**
> **Even "temporary" work benefits from automation. If you'll do it more than 3 times, automate it. The time investment pays off quickly.**

---

### Lesson 17: Version Control Your Queries, Not Just Code

**What I Wish I Had Done:**
- Git repo from day 1
- Commit after each working query
- Tag stable versions

**What Actually Happened:**
- Query evolution scattered across SSMS, Excel, notepad files
- Hard to track what changed when
- Difficult to roll back when a "fix" broke something

**Better Approach:**
```
git/
├── sql/
│   ├── v1_initial_query.sql
│   ├── v2_added_distinct.sql
│   ├── v3_fixed_join_keys.sql
│   └── final_query.sql
├── powerquery/
│   └── comparison_logic_v1.m
└── dax/
    └── measures.dax
```

**Takeaway:**
> **SQL queries, M code, and DAX are code. Treat them like code - use version control, even for "quick" projects.**

---

## Communication & Stakeholder Management

### Lesson 18: Visualize the Problem, Don't Just Report Numbers

**Weak Communication:**
"Azure and BIPROD have a difference of 10,461 units across 1.8M records"

**Strong Communication:**
```
[Power BI Dashboard Screenshot]

✅ 99.2% of records match perfectly
⚠️ 0.6% have minor differences (-10,461 units total)
❌ 0.2% exist only in one system

Drill-down shows:
- Most differences in Store 045 (investigate supply chain)
- Seasonal products 25WW and 26ZZ account for 80% of gap
```

**Impact:** Manager understood immediately where to focus

**Takeaway:**
> **Turn data into insights. Use visuals, percentages, and specific examples. Don't just dump numbers on stakeholders.**

---

### Lesson 19: Flag Issues Early, Don't Wait for Perfect Analysis

**Mistake I Made:**
- Discovered CKS view had only 1,000 rows (vs 13,629 expected)
- Spent 2 hours investigating before reporting
- Turned out to be simple: incomplete ETL load
- Engineering team could have started fix immediately if I'd flagged it early

**Better Approach:**
```
Day 1, 10:00 AM: "Found potential issue - CKS view missing 92% of data"
Day 1, 10:30 AM: Engineering starts investigating
Day 1, 2:00 PM: Root cause found and fix in progress
```

vs
```
Day 1, 10:00 AM: Find issue
Day 1, 12:00 PM: Still analyzing
Day 1, 2:00 PM: Finally report "CKS view missing 92% of data"
Day 1, 2:30 PM: Engineering starts investigating
Day 2: Fix completed (1 day delay)
```

**Takeaway:**
> **Flag critical issues immediately, even if you don't fully understand the root cause. Let the appropriate team investigate while you continue your work.**

---

### Lesson 20: Document As You Go, Not at the End

**What Happened:**
- Built 6 validations over 3 weeks
- Took detailed notes... in my head
- At end of project: "How did I fix that cartesian product issue again?"
- Spent 4 hours reconstructing the solution for documentation

**Better Approach:**
- Keep a `NOTES.md` file open
- After each bug fix, write 3 sentences:
  - What was the problem?
  - What was the root cause?
  - What was the solution?

**Example Notes:**
```markdown
## 2026-02-10: Fixed Cartesian Product

Problem: 48K rows became 356K after merge
Cause: Product table has 3 rows per itemid (sizes)
Solution: Added Table.Distinct() before join

Code:
Azure_Distinct = Table.Distinct(Azure, {"ITEM", "COLOR"})
```

**Takeaway:**
> **Document while the context is fresh in your mind. Future-you will thank present-you. End-of-project documentation is painful and incomplete.**

---

## What I Would Do Differently

### If I Started This Project Today...

1. **Set up Git repo on Day 1**
   - Track all SQL, M, and DAX code
   - Commit after each working solution

2. **Build one complete validation end-to-end first**
   - SQL → Power Query → Power BI → Automation
   - Then scale to other views
   - (I actually did this - keep doing it!)

3. **Create a validation checklist**
```
   ☐ Row count: Source vs Result
   ☐ Null handling verified
   ☐ Join keys unique in both tables
   ☐ Aggregation at multiple levels
   ☐ Sample records manually verified
```

4. **Build the Power BI dashboard earlier**
   - I waited until Excel validations were done
   - Should have built dashboard in parallel
   - Would have caught issues earlier through visualization

5. **Write documentation incrementally**
   - Not as a final "project deliverable"
   - But as living notes throughout the project

6. **Ask for IT support sooner**
   - Spent 2 days trying to work around VPN restrictions
   - Should have escalated on day 1
   - (Even though IT said no, having it documented helps)

7. **Build the Fabric automation from the start**
   - Even if not deployed
   - Good to have as proof-of-concept
   - Easier to build while context is fresh

---

## Key Takeaways Summary

### Technical
1. ✅ Always use `Table.Distinct()` before merges
2. ✅ Preserve null semantics throughout the pipeline
3. ✅ Use natural keys for cross-system comparisons
4. ✅ Validate at multiple granularity levels
5. ✅ Full outer join for validation scenarios

### Process
6. ✅ Build template first, then scale
7. ✅ Automate early, even for temporary work
8. ✅ Document as you go, not at the end
9. ✅ Version control everything (SQL, M, DAX)
10. ✅ Flag critical issues immediately

### Communication
11. ✅ Visualize problems, don't just report numbers
12. ✅ Distinguish expected differences from errors
13. ✅ Include specific examples in reports
14. ✅ Start with aggregates, drill down to details

---

## Closing Thoughts

This project taught me that **data validation is as much about understanding business context as it is about technical skills**. 

The hardest problems weren't the SQL queries or Power Query transformations - those are solvable with documentation and practice. 

The real challenges were:
- Understanding when a difference is an "error" vs "expected behavior"
- Communicating technical findings to non-technical stakeholders
- Balancing thoroughness with time constraints
- Building solutions that outlive my contract (handover documentation)

**Most importantly:** Always question your assumptions. When row counts don't match, when nulls appear unexpectedly, when aggregations look "too good" - dig deeper. The bug is usually in your mental model, not the data.

---

**Document Version:** 1.0  
**Last Updated:** February 18, 2026  
**Author:** Mehmet Cetin  
**GitHub:** https://github.com/mcetin-data
