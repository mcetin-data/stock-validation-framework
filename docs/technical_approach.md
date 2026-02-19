# Technical Approach - Stock Validation Framework

**Author:** Mehmet Cetin  
**Project:** BIPROD to Azure Migration Validation  
**Date:** February 2026  

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Data Extraction Layer](#data-extraction-layer)
3. [Transformation & Comparison Logic](#transformation--comparison-logic)
4. [Visualization & Reporting](#visualization--reporting)
5. [Automation & Scheduling](#automation--scheduling)
6. [Technical Challenges & Solutions](#technical-challenges--solutions)
7. [Performance Optimization](#performance-optimization)

---

## Architecture Overview

### System Diagram
```
┌─────────────────────────────────────────────────────────────────┐
│                        DATA SOURCES                             │
├──────────────────────────────┬──────────────────────────────────┤
│         BIPROD               │          Azure                   │
│    (On-Premise SQL)          │    (SQL Managed Instance)        │
│                              │                                  │
│  • VW_BOARD_STOCK_*          │  • VW_BOARD_STOCK_*              │
│  • VW_BOARD_SC_*             │  • VW_BOARD_SC_*                 │
│  • DIM.Product               │  • DIM.Product                   │
│  • DIM.Organisation          │  • DIM.Organisation              │
└──────────────────────────────┴──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    EXTRACTION LAYER (SQL)                        │
├─────────────────────────────────────────────────────────────────┤
│  • Join views with dimension tables                             │
│  • Add shopcode, Seasoncode enrichment                          │
│  • Filter to relevant data (if needed)                          │
│  • Return tabular results                                       │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│              TRANSFORMATION LAYER (Power Query M)                │
├─────────────────────────────────────────────────────────────────┤
│  • Full Outer Join on natural keys                              │
│  • Table.Distinct() to prevent cartesian products               │
│  • COALESCE logic for unified columns                           │
│  • Null-safe difference calculations                            │
│  • Match status categorization                                  │
└─────────────────────────────────────────────────────────────────┘
                               │
                       ┌───────┴────────┐
                       │                │
                       ▼                ▼
              ┌─────────────┐  ┌─────────────┐
              │    Excel    │  │  Power BI   │
              │ Validations │  │  Dashboard  │
              │  (6 views)  │  │             │
              └─────────────┘  └──────┬──────┘
                                      │
                                      ▼
                           ┌──────────────────┐
                           │ Fabric Notebook  │
                           │ (Automation)     │
                           │                  │
                           │ • DAX Queries    │
                           │ • Email Gen      │
                           │ • Graph API      │
                           └──────────────────┘
```

---

## Data Extraction Layer

### SQL Query Pattern

**Purpose:** Extract data from source systems and enrich with dimensional attributes

**Standard Template:**
```sql
-- Pattern used across all 6 views
SELECT 
    -- View columns (fact data)
    v.COLUMN1,
    v.COLUMN2,
    v.QTY,
    v.COSTS,
    
    -- Dimensional enrichment
    p.shopcode,
    p.Seasoncode,
    p.ARTICLE_CODE
    
FROM [DATABASE_NAME].[dbo].[VIEW_NAME] v

-- Join with Product dimension
LEFT JOIN (
    -- DISTINCT prevents cartesian product from multiple sizes
    SELECT DISTINCT 
        itemid,          -- or barcode, depending on view
        inventcolorid,
        shopcode,
        Seasoncode,
        ARTICLE_CODE
    FROM [DATABASE_NAME].[DIM].[Product]
) p 
    ON v.ITEM = p.itemid           -- Join key varies by view
    AND v.COLOR = p.inventcolorid  -- Some views use additional keys
```

### Key Design Decisions

#### 1. Why LEFT JOIN instead of INNER JOIN?

**Decision:** Use `LEFT JOIN` to Product dimension

**Rationale:**
- Ensures all fact records are included even if dimension lookup fails
- Allows detection of orphaned records (facts without matching dimension)
- `shopcode` and `Seasoncode` are enrichment, not filtering criteria

**Alternative Considered:** INNER JOIN  
**Why Rejected:** Would silently drop records with missing dimension data

---

#### 2. Why DISTINCT on Product Dimension?

**Decision:** Wrap Product table in `SELECT DISTINCT`

**Rationale:**
- Product dimension has multiple rows per `itemid + inventcolorid` (one per size)
- Without DISTINCT, join would create **cartesian product**
- Example: 1 fact row × 3 size variants = 3 rows in result ❌

**Performance Impact:** 
- DISTINCT adds ~200ms overhead
- Acceptable trade-off vs 3x row multiplication

**Example:**
```sql
-- WITHOUT DISTINCT - WRONG! ❌
FROM View v
LEFT JOIN Product p ON v.ITEM = p.itemid
-- Result: 48,000 rows become 144,000 rows (3x multiplication)

-- WITH DISTINCT - CORRECT ✅
LEFT JOIN (
    SELECT DISTINCT itemid, shopcode, Seasoncode 
    FROM Product
) p ON v.ITEM = p.itemid
-- Result: 48,000 rows stay 48,000 rows
```

---

#### 3. Join Key Selection

**Challenge:** Some views use `barcode`, others use `ITEM` (itemid)

| View | Primary Key | Join to Product |
|------|-------------|-----------------|
| STOCK_ONLINE_AVAILABLE | barcode | `v.barcode = p.barcode` |
| STOCK_ONLINE_SKU | barcode | `v.barcode = p.barcode` |
| ONLINESTOCKSIZECOUNTERS | ITEM, COLOR | `v.ITEM = p.itemid AND v.COLOR = p.inventcolorid` |

**Key Insight:** 
- `barcode` is unique (1:1 with product variant)
- `itemid` is not unique (1:many with sizes) → requires COLOR to make it unique
- `itemid + inventcolorid` combination identifies a product-color, shared across sizes

---

## Transformation & Comparison Logic

### Power Query M Code Architecture

**Core Operations:**
```m
let
    // 1. LOAD SOURCES
    Azure = Source_Azure,
    BIPROD = Source_BIPROD,
    
    // 2. RENAME COLUMNS (prevent conflicts)
    Azure_Renamed = Table.RenameColumns(Azure, {{"QTY", "Azure_QTY"}}),
    BIPROD_Renamed = Table.RenameColumns(BIPROD, {{"QTY", "BIPROD_QTY"}}),
    
    // 3. REMOVE DUPLICATES (critical fix!)
    Azure_Distinct = Table.Distinct(Azure_Renamed, {"barcode", "STOREID"}),
    BIPROD_Distinct = Table.Distinct(BIPROD_Renamed, {"barcode", "STOREID"}),
    
    // 4. FULL OUTER JOIN
    Merged = Table.NestedJoin(
        Azure_Distinct, {"barcode", "STOREID"},
        BIPROD_Distinct, {"barcode", "STOREID"},
        "BIPROD", JoinKind.FullOuter
    ),
    
    // 5. EXPAND NESTED TABLE
    Expanded = Table.ExpandTableColumn(Merged, "BIPROD", {...}),
    
    // 6. COALESCE KEY COLUMNS
    Unified_Barcode = Table.AddColumn(
        Expanded, "Final_barcode",
        each if [barcode] <> null then [barcode] else [BIPROD.barcode]
    ),
    
    // 7. CALCULATE DIFFERENCES (null-safe)
    QTY_Diff = Table.AddColumn(
        Unified_Barcode, "QTY_Diff",
        each if [Azure_QTY] <> null and [BIPROD_QTY] <> null
             then [Azure_QTY] - [BIPROD_QTY]
             else null
    ),
    
    // 8. CATEGORIZE MATCH STATUS
    Match_Status = Table.AddColumn(
        QTY_Diff, "Match_Status",
        each if [Azure_QTY] = null then "BIPROD_Only"
             else if [BIPROD_QTY] = null then "Azure_Only"
             else if [QTY_Diff] = 0 then "Match"
             else "Mismatch"
    )
in
    Match_Status
```

---

### Critical Design Patterns

#### Pattern 1: Full Outer Join

**Why Full Outer Join?**
```
INNER JOIN:  Only records in BOTH systems ❌
LEFT JOIN:   All Azure + matching BIPROD ❌
RIGHT JOIN:  All BIPROD + matching Azure ❌
FULL OUTER:  All records from BOTH systems ✅
```

**Example Scenario:**
```
Azure has:    barcode=ABC (new product)
BIPROD has:   barcode=XYZ (discontinued product)

INNER JOIN result: 0 rows ❌ (misses both!)
FULL OUTER result: 2 rows ✅ (captures both as Azure_Only and BIPROD_Only)
```

**Implementation:**
```m
Table.NestedJoin(
    LeftTable, JoinKeys,
    RightTable, JoinKeys,
    "RightTableName",
    JoinKind.FullOuter  // ← Key parameter
)
```

---

#### Pattern 2: COALESCE for Unified Columns

**Problem:** After full outer join, key columns exist on both sides:
```
[barcode]         = "ABC123"  (from Azure)
[BIPROD.barcode]  = null      (BIPROD doesn't have this record)
```

**Solution:** Create unified column using COALESCE logic:
```m
Table.AddColumn(
    Source, "Final_barcode",
    each if [barcode] <> null 
         then [barcode]           // Use Azure value if exists
         else [BIPROD.barcode],   // Otherwise use BIPROD value
    type text
)
```

**Result:**
```
[Final_barcode] = "ABC123"  // Unified, always has a value
```

**Why This Matters:**
- Sorting/grouping requires non-null keys
- Downstream visualizations need single barcode column
- Simplifies final table structure

---

#### Pattern 3: Null-Safe Difference Calculation

**Wrong Approach:** ❌
```m
// This creates false zeros!
Added_Diff = Table.AddColumn(
    Source, "QTY_Diff",
    each [Azure_QTY] - [BIPROD_QTY]  // null - 100 = null (converted to 0)
)
```

**Problem:**
- `null - 100` evaluates to `null`
- Power Query often converts `null` to `0` in numeric context
- Result: Missing data looks like "zero difference" (false match!)

**Correct Approach:** ✅
```m
Added_Diff = Table.AddColumn(
    Source, "QTY_Diff",
    each if [Azure_QTY] <> null and [BIPROD_QTY] <> null
         then [Azure_QTY] - [BIPROD_QTY]  // Only calculate if both exist
         else null,                        // Preserve null for missing data
    type number
)
```

**Result:**
- `null` stays `null` (indicates missing data)
- `0` means actual zero difference (perfect match)
- Distinction preserved for accurate Match Status

---

#### Pattern 4: Table.Distinct() Before Join

**The Cartesian Product Bug:**

**Scenario:** Source query returns duplicates due to:
- Data type mismatch (trailing spaces in text)
- Multiple rows with same key (data quality issue)
- Power Query internal caching behavior

**Without Table.Distinct():**
```
Azure has:    barcode="ABC", STOREID="001" (appears 2x due to duplicate)
BIPROD has:   barcode="ABC", STOREID="001" (appears 1x)

Join result:  2 rows (cartesian product: 2 × 1 = 2)
```

**Multiply across 50K records → 100K rows!** ❌

**With Table.Distinct():**
```m
Azure_Distinct = Table.Distinct(Azure, {"barcode", "STOREID"}),
BIPROD_Distinct = Table.Distinct(BIPROD, {"barcode", "STOREID"}),

Merged = Table.NestedJoin(
    Azure_Distinct,   // Guaranteed 1 row per key
    BIPROD_Distinct,  // Guaranteed 1 row per key
    ...
)
```

**Result:** 1:1 join, no multiplication ✅

**Performance:** Adds ~2-3 seconds for 1M rows, prevents hours of debugging

---

## Visualization & Reporting

### Power BI Dashboard Architecture

**Data Model:**
```
Stock_Comparison (fact table)
├── barcode (key)
├── STOREID (key)
├── shopcode
├── Seasoncode
├── Azure_QTY
├── BIPROD_QTY
├── QTY_Diff
├── Azure_COSTS
├── BIPROD_COSTS
├── COSTS_Diff
└── Match_Status

(No dimension tables - denormalized for simplicity)
```

**Why Denormalized?**
- Single fact table already enriched with dimensional attributes
- Simplifies DAX measure creation
- Faster query performance (no joins at runtime)
- Alignment validation doesn't need star schema

---

### DAX Measure Patterns

#### Pattern 1: Conditional Aggregation
```dax
Azure_Total_QTY = 
CALCULATE(
    SUM(Stock_Comparison[Azure_QTY]),
    NOT ISBLANK(Stock_Comparison[Azure_QTY])  // Only sum non-null
)
```

**Why the filter?**
- Without it, `BLANK()` values might interfere with aggregation
- Explicit filter ensures only actual values are summed
- Makes measure behavior predictable

---

#### Pattern 2: Null-Safe Total Difference

**Wrong:** ❌
```dax
// This understates the true difference!
Total_QTY_Diff = SUM(Stock_Comparison[QTY_Diff])
```

**Problem:** 
- Ignores Azure_Only and BIPROD_Only records (where QTY_Diff = null)
- Only sums Mismatch rows
- Example: Misses 84,000 units of difference!

**Correct:** ✅
```dax
Total_QTY_Diff_Correct = 
SUMX(
    Stock_Comparison,
    IF(
        NOT ISBLANK([Azure_QTY]) || NOT ISBLANK([BIPROD_QTY]),
        COALESCE([Azure_QTY], 0) - COALESCE([BIPROD_QTY], 0),
        0
    )
)
```

**How it works:**
- `SUMX` iterates row-by-row (instead of simple SUM)
- Checks if either side has a value
- Converts null to 0 only for calculation (doesn't modify source)
- Captures full difference including one-sided records

---

#### Pattern 3: Alignment Percentage
```dax
Alignment_Pct = 
DIVIDE(
    CALCULATE(
        COUNTROWS(Stock_Comparison),
        Stock_Comparison[Match_Status] = "Match"
    ),
    COUNTROWS(Stock_Comparison),
    0  // Return 0 if denominator is zero
)
```

**Format:** Percentage with 1 decimal (99.2%)

---

#### Pattern 4: Health Status Logic
```dax
Health_Status = 
VAR AlignPct = [Alignment_Pct]
RETURN
    IF(AlignPct >= 0.99, "✅ Excellent (>99%)",
    IF(AlignPct >= 0.95, "⚠️ Good (95-99%)",
    IF(AlignPct >= 0.90, "🔶 Moderate (90-95%)",
    "❌ Poor (<90%)")))
```

**Business Logic:**
- >99% = migration target achieved
- 95-99% = acceptable with documentation
- 90-95% = requires investigation
- <90% = blocks production cutover

---

## Automation & Scheduling

### Fabric Notebook Architecture

**Execution Flow:**
```python
# 1. AUTHENTICATE
token = mssparkutils.credentials.getToken('https://graph.microsoft.com')

# 2. QUERY POWER BI
results = fabric.evaluate_dax(
    dataset="Stock_Validation",
    dax_string="EVALUATE ROW(...)"
)

# 3. EXTRACT KPIs
kpis = pd.DataFrame(results).iloc[0]

# 4. BUILD EMAIL
email_html = f"""<html>..."""

# 5. SEND VIA GRAPH API
requests.post(
    "https://graph.microsoft.com/v1.0/me/sendMail",
    headers={"Authorization": f"Bearer {token}"},
    json=email_payload
)
```

---

### Key Technical Components

#### 1. DAX Query Execution
```python
dax_query = """
EVALUATE
ROW(
    "Azure_Records", [Azure_Records],
    "BIPROD_Records", [BIPROD_Records],
    ...
)
"""

results = fabric.evaluate_dax(
    dataset=DATASET_NAME,
    workspace=WORKSPACE_NAME,
    dax_string=dax_query
)
```

**How it works:**
- `fabric.evaluate_dax()` executes DAX against published PBI dataset
- Returns result as Python dictionary
- All DAX measures calculated at execution time (live data)

---

#### 2. HTML Email Generation

**F-String Template:**
```python
email_body = f"""
<table>
    <tr>
        <td>Total QTY</td>
        <td>{kpis['[Azure_Total_QTY]']:,.0f}</td>  <!-- Format: 1,234,567 -->
        <td>{kpis['[BIPROD_Total_QTY]']:,.0f}</td>
        <td class="{'diff-positive' if kpis['[QTY_Diff]'] > 0 else 'diff-negative'}">
            {kpis['[QTY_Diff]']:+,.0f}  <!-- Format: +1,234 or -5,678 -->
        </td>
    </tr>
</table>
"""
```

**Python Format Specifiers:**
- `:,.0f` = thousand separator, no decimals (1,234,567)
- `:+,.0f` = show sign (+/-), thousand separator (+ 1,234)
- `:.1%` = percentage with 1 decimal (99.2%)
- `:.2f` = 2 decimal places (123.45)

---

#### 3. Microsoft Graph API Integration

**Authentication:**
```python
# Fabric provides automatic token retrieval
token = mssparkutils.credentials.getToken('https://graph.microsoft.com')
```

**Email Payload Structure:**
```python
email_payload = {
    "message": {
        "subject": "Stock Validation Report - 18/02/2026",
        "body": {
            "contentType": "HTML",  # ← Enables rich formatting
            "content": email_body
        },
        "toRecipients": [
            {"emailAddress": {"address": "manager@company.com"}}
        ],
        "importance": "normal"  # Options: low, normal, high
    },
    "saveToSentItems": True  # ← Save copy in Sent folder
}
```

**API Call:**
```python
response = requests.post(
    "https://graph.microsoft.com/v1.0/me/sendMail",
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    },
    json=email_payload
)

# Status code 202 = Accepted (email queued for delivery)
if response.status_code == 202:
    print("✅ Email sent successfully")
```

---

## Technical Challenges & Solutions

### Challenge 1: Cartesian Product Explosion

**Problem:** 48K rows became 356K rows after Power Query merge

**Root Cause:** 
- Product dimension has 3 rows per `itemid` (one per size)
- Join without DISTINCT multiplied rows: 48K × 3 = 144K

**Solution:** 
```sql
-- In SQL query
LEFT JOIN (
    SELECT DISTINCT itemid, shopcode, Seasoncode
    FROM Product
) p ...
```
```m
-- In Power Query (additional safety)
Azure_Distinct = Table.Distinct(Azure, {"ITEM", "COLOR"})
```

**Result:** 48K rows stay 48K rows ✅

---

### Challenge 2: Null vs Zero Ambiguity

**Problem:** Can't distinguish between:
- Missing data (`null`)
- Actual zero (`0`)
- False zero (null converted to 0)

**Impact:**
```
Azure_QTY = null, BIPROD_QTY = 100
If null converted to 0: Difference = -100 (looks like Mismatch)
If null preserved: Difference = null (correctly identified as BIPROD_Only)
```

**Solution:** Preserve nulls throughout pipeline:
```m
// Power Query
QTY_Diff = if [Azure_QTY] <> null and [BIPROD_QTY] <> null
           then [Azure_QTY] - [BIPROD_QTY]
           else null  // ← Preserve null
```
```dax
// DAX
Total_Diff = SUMX(
    Table,
    COALESCE([Azure_QTY], 0) - COALESCE([BIPROD_QTY], 0)
    // Convert to 0 only for calculation, not in source
)
```

---

### Challenge 3: Historical Data Date Alignment

**Problem:** Azure and BIPROD have different historical date ranges

**Example:**
```
BIPROD: 2025-12-01 to 2026-02-18 (78 days)
Azure:  2026-01-15 to 2026-02-18 (34 days)
```

**Naive Approach:** ❌
```sql
-- This fails: tries to join non-overlapping dates
WHERE DATE_WID = 20251201
-- Azure has no data for this date!
```

**Solution:** ✅
1. Identify overlapping date range
2. Validate within overlap (2026-01-15 to 2026-02-18)
3. Document partial history as expected behavior
4. Report non-overlap separately (not as Mismatch)
```m
// Power Query
Filtered_Overlap = Table.SelectRows(
    Source,
    each [DateSnapshot] >= #date(2026, 1, 15)  // Overlap start
)
```

---

### Challenge 4: Excel Row Limit

**Problem:** Historical view has 185K rows, Excel limit is 1,048,576

**But:** Power Query comparison created 1,048,576 rows (Excel maxed out!)

**Root Cause:** Cartesian product from duplicates

**Solution:**
1. Fix cartesian product (Table.Distinct)
2. Use Power BI for >1M row datasets
3. Excel only for <1M row views

**Lesson:** Power Query can handle millions of rows in memory, but Excel worksheets have hard limits

---

## Performance Optimization

### SQL Query Performance

**Optimization 1: Filter Early**
```sql
-- Bad: Join first, filter later ❌
SELECT ... FROM View v
LEFT JOIN Product p ON ...
WHERE v.DATE_WID = 20260131

-- Good: Filter before join ✅
SELECT ... FROM (
    SELECT * FROM View
    WHERE DATE_WID = 20260131  -- Reduces rows before join
) v
LEFT JOIN Product p ON ...
```

**Impact:** 10x faster on large fact tables

---

**Optimization 2: Index Join Keys**
```sql
-- Ensure indexes exist on join columns
CREATE INDEX IX_Product_ItemID_ColorID 
ON Product(itemid, inventcolorid)
INCLUDE (shopcode, Seasoncode)
```

**Impact:** 5-10x faster joins

---

### Power Query Performance

**Optimization 1: Query Folding**

**Concept:** Push transformations to SQL Server (faster) instead of Power Query (slower)

**Check if query folds:**
- Right-click query step → View Native Query
- If shows SQL, it's folding ✅
- If error "cannot be folded", it's in-memory ❌

**Best Practices:**
- Do filtering/sorting in SQL query
- Do complex logic (COALESCE, Match_Status) in Power Query

---

**Optimization 2: Disable Unnecessary Steps**
```m
// Disable auto-type detection (saves ~30%)
Source = Sql.Database(
    "server",
    "database",
    [Query="SELECT ...", 
     EnableTypePromotion = false]  // ← Skip auto-typing
)
```

---

### Power BI Performance

**Optimization 1: Disable Auto Date/Time**
```
File → Options → Data Load
☐ Auto Date/Time for new files
```

**Why:** Creates hidden date tables consuming memory

---

**Optimization 2: Use Variables in DAX**
```dax
// Bad: Calculates Match_Count 3 times ❌
Alignment_Pct = [Match_Count] / ([Match_Count] + [Mismatch_Count])

// Good: Calculate once, reuse ✅
Alignment_Pct = 
VAR Matches = [Match_Count]
VAR Mismatches = [Mismatch_Count]
RETURN DIVIDE(Matches, Matches + Mismatches, 0)
```

---

## Technology Stack Summary

| Layer | Technology | Purpose |
|-------|------------|---------|
| **Source** | SQL Server, Azure SQL MI | Data storage |
| **Extraction** | SQL (T-SQL) | Query and enrich data |
| **Transformation** | Power Query (M Language) | Join, compare, categorize |
| **Storage** | Excel, Power BI Dataset | Validated results |
| **Visualization** | Power BI Desktop | Interactive dashboards |
| **Calculation** | DAX | KPIs and metrics |
| **Automation** | Python (Fabric Notebook) | Scheduled reporting |
| **Delivery** | Microsoft Graph API | Email distribution |

---

**Document Version:** 1.0  
**Last Updated:** February 18, 2026  
**Author:** Mehmet Cetin
