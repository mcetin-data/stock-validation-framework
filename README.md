# Stock Validation Framework - Azure Migration Validation

![Status](https://img.shields.io/badge/Status-Complete-success)
![Tools](https://img.shields.io/badge/Tools-Power%20BI%20%7C%20Excel%20%7C%20SQL%20%7C%20Power%20Query%20%7C%20Python-blue)
![Skills](https://img.shields.io/badge/Skills-Data%20Validation%20%7C%20ETL%20%7C%20Automation-orange)

> End-to-end data validation framework for Azure cloud migration, ensuring data integrity across 6 critical business views with automated monitoring and reporting.

---

## 📋 Table of Contents
- [Project Overview](#-project-overview)
- [Business Problem](#-business-problem)
- [Solution Architecture](#-solution-architecture)
- [Technologies Used](#-technologies-used)
- [Key Features](#-key-features)
- [Results & Impact](#-results--impact)
- [Project Structure](#-project-structure)
- [Technical Highlights](#-technical-highlights)
- [Lessons Learned](#-lessons-learned)

---

## 🎯 Project Overview

Built a comprehensive data validation framework to monitor stock data integrity during a legacy-to-cloud migration project. The solution validates **6 critical business views** containing **1.8M+ records**, comparing BIPROD (on-premise) against Azure (cloud) to ensure migration accuracy.

**Project Duration:** 4 weeks  
**Validation Scope:** 6 business-critical views  
**Data Volume:** 1.8M+ records validated  
**Automation:** Twice-weekly automated reporting  

---

## 💼 Business Problem

The company was migrating stock management systems from on-premise BIPROD to Azure cloud infrastructure. **Critical challenge:** Ensure zero data loss and maintain data integrity across multiple complex views during migration.

**Risks without validation:**
- Inventory discrepancies leading to stockouts or overstock
- Financial reporting errors
- Business intelligence dashboard inaccuracies
- Loss of trust in the new Azure system

**Requirements:**
- Validate data at multiple granularity levels (total, store, barcode)
- Track differences over time (historical validation)
- Automate reporting to reduce manual effort
- Provide actionable insights for data engineering team

---

## 🏗️ Solution Architecture
```
┌─────────────────┐         ┌─────────────────┐
│   BIPROD        │         │     Azure       │
│  (On-Premise)   │         │    (Cloud)      │
└────────┬────────┘         └────────┬────────┘
         │                           │
         │    SQL Queries            │
         │    (Extract Data)         │
         ▼                           ▼
┌──────────────────────────────────────────┐
│          Power Query M Code              │
│    (Full Outer Join + Null Handling)    │
└────────────────┬─────────────────────────┘
                 │
                 ▼
        ┌────────────────┐
        │  Comparison    │
        │    Tables      │
        └────────┬───────┘
                 │
         ┌───────┴────────┐
         │                │
         ▼                ▼
  ┌──────────┐    ┌─────────────┐
  │  Excel   │    │  Power BI   │
  │  (6 views)│   │  Dashboard  │
  └──────────┘    └──────┬──────┘
                         │
                         ▼
                ┌────────────────┐
                │ Fabric Notebook│
                │ (Auto Email)   │
                └────────────────┘
```

---

## 🛠️ Technologies Used

| Category | Technologies |
|----------|-------------|
| **Databases** | SQL Server (BIPROD), Azure SQL Managed Instance |
| **Data Processing** | Power Query (M Language), SQL |
| **Visualization** | Power BI Desktop, Excel |
| **Automation** | Microsoft Fabric, Python, Microsoft Graph API |
| **Languages** | SQL, M (Power Query), DAX, Python |

---

## ✨ Key Features

### 1. **Multi-Level Data Validation**
- **6 business-critical views** validated:
  - Stock Online Availability (current + historical)
  - Stock Online SKU (online/offline inventory)
  - Online Stock Size Counters (current + historical)
  - CKS-specific size counters
- **Multiple granularity levels**: Total → Store → Barcode → Barcode+Store+Size

### 2. **Robust Comparison Logic**
- **Full outer join** to capture records existing in either or both systems
- **Null-safe calculations** to distinguish missing data from zero differences
- **COALESCE pattern** for unified key columns
- **Match status categorization**: Match | Mismatch | Azure_Only | BIPROD_Only

### 3. **Power BI Interactive Dashboard**
- Real-time KPI monitoring (Records, Unique Barcodes, Total QTY, Total COGS)
- Dynamic filtering by Season, Shop Code, Store ID, Article Code
- Drill-down capability from totals to granular barcode-store level
- Visual health indicators (alignment %, difference trends)

### 4. **Automated Reporting**
- **Fabric notebook** orchestrates email generation
- **DAX queries** extract KPIs from Power BI dataset
- **HTML email** with professional formatting and conditional coloring
- **Scheduled delivery** twice weekly via Microsoft Graph API

---

## 📊 Results & Impact

### Data Quality Discoveries

| Finding | Impact | Resolution |
|---------|--------|------------|
| **155 duplicate records in Azure** | Data quality issue affecting 8 unique barcodes | Documented for engineering team |
| **10,461 unit QTY gap** | Traced to negative stock adjustments in Azure | Validated as expected behavior (Azure more current) |
| **99% alignment at granular level** | Migration successful after corrections | Approved for production cutover |
| **1 view with 92% missing data** | Azure incomplete for CKS view | Flagged for immediate engineering attention |

### Technical Achievements

✅ **Prevented cartesian product explosion** - Fixed Power Query join that multiplied 48K rows → 356K rows  
✅ **Solved null handling bug** - Corrected false "Mismatch" status by preserving null semantics  
✅ **Automated validation process** - Reduced manual effort from 8 hours/week → 0 hours/week  
✅ **Built reusable framework** - Template applicable to future migration projects  

---

## 📁 Project Structure
```
stock-validation-framework/
│
├── README.md                          # This file
│
├── screenshots/
│   ├── excel/                         # Excel validation results
│   │   ├── stock_online_available.png
│   │   ├── stock_online_available_history.png
│   │   ├── stock_online_sku.png
│   │   ├── onlinestocksizecounters.png
│   │   └── onlinestocksizecounters_history.png
│   │
│   └── powerbi/                       # Power BI dashboard pages
│       ├── page1_executive_summary.png
│       ├── page2_store_level.png
│       ├── page3_barcode_level.png
│       └── page4_detail_view.png
│
├── sql/
│   └── example_query.sql              # Sample validation query
│
├── powerquery/
│   └── comparison_template.m          # Reusable M code template
│
├── automation/
│   └── email_notification.ipynb       # Fabric notebook for automated emails
│
└── docs/
    ├── validation_findings.md         # Detailed validation results
    ├── technical_approach.md          # Technical deep-dive
    └── lessons_learned.md             # Key insights & best practices
```

---

## 🔧 Technical Highlights

### Power Query M Code
```m
// Prevent cartesian product with Table.Distinct()
Azure_Distinct = Table.Distinct(Azure_Renamed, {"barcode", "STOREID"}),
BIPROD_Distinct = Table.Distinct(BIPROD_Renamed, {"barcode", "STOREID"}),

// Full outer join to capture all records
Merged = Table.NestedJoin(
    Azure_Distinct, {"barcode", "STOREID"},
    BIPROD_Distinct, {"barcode", "STOREID"},
    "BIPROD", JoinKind.FullOuter
)
```

### SQL Query Pattern
```sql
-- Join view with Product dimension for enrichment
SELECT 
    v.STOREID, v.ITEM, v.COLOR,
    v.SIZECOUNTER_STOCK, v.SIZECOUNTER_ORDERS,
    p.shopcode, p.Seasoncode
FROM [DATABASE_NAME].[dbo].[ONLINESTOCKSIZECOUNTERS] v
LEFT JOIN (
    SELECT DISTINCT itemid, inventcolorid, shopcode, Seasoncode
    FROM [DATABASE_NAME].[DIM].[Product]
) p ON v.ITEM = p.itemid AND v.COLOR = p.inventcolorid
```

### DAX Measures
```dax
// Null-safe total difference calculation
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

---

## 🎓 Lessons Learned

### Technical Insights

1. **Cartesian Product Prevention**
   - Always use `Table.Distinct()` before joins when dealing with potential duplicates
   - Validate row counts at each transformation step

2. **Null Semantics Matter**
   - Distinguish between `null` (missing) and `0` (zero)
   - Converting `null → 0` creates false positives in difference detection

3. **Join Key Selection**
   - Natural keys (barcode, STOREID) more reliable than surrogate keys (PRODUCT_WID)
   - Always include business entity identifiers (AX_DATAAREAID) in groupings

4. **Aggregation Level Paradoxes**
   - Differences can cancel out at higher aggregation levels
   - Always validate at the most granular level first

### Process Insights

1. **Start Simple, Add Complexity**
   - Began with single-view validation, then scaled to 6 views
   - Built reusable template after understanding patterns

2. **Automate Early**
   - Manual validation unsustainable for ongoing monitoring
   - Automation freed up time for deeper analysis

3. **Document Data Issues Objectively**
   - Separate data problems from migration logic problems
   - Provide actionable recommendations for engineering team

---

## 🚀 Getting Started

### Prerequisites
- SQL Server Management Studio (SSMS)
- Power BI Desktop
- Excel with Power Query
- (Optional) Microsoft Fabric workspace for automation

### Quick Start
1. Clone this repository
2. Review `sql/example_query.sql` for validation query pattern
3. Adapt `powerquery/comparison_template.m` for your data sources
4. Build Power BI dashboard using DAX measures in documentation
5. (Optional) Deploy `automation/email_notification.ipynb` to Fabric

---

## 📞 Contact

**Mehmet Cetin**  
Data Analyst | BI Developer  

[![LinkedIn](https://img.shields.io/badge/LinkedIn-Connect-blue)](https://www.linkedin.com/in/mehmet-cetin-461674a4/)
[![GitHub](https://img.shields.io/badge/GitHub-Follow-black)](https://github.com/mcetin-data)

---

## 📄 License

This project is available for educational and portfolio purposes.


