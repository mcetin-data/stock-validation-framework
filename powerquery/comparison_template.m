/*
============================================================
Stock Validation - Comparison Template (Power Query M)
============================================================
Purpose: Full outer join Azure and BIPROD data sources with 
         comprehensive null handling and difference calculation

Key Features:
- COALESCE logic for unified key columns
- Null-safe difference calculations
- Match status categorization (Match/Mismatch/Azure_Only/BIPROD_Only)
- Table.Distinct() to prevent cartesian product multiplication
- Handles missing records on either side gracefully

Author: Mehmet Cetin
GitHub: https://github.com/mcetin-data
============================================================
*/

let
    // =====================================================
    // STEP 1: Load source queries
    // =====================================================
    // These should be named "Source_Azure" and "Source_BIPROD" 
    // in your Power Query connections
    Azure = Source_Azure,
    BIPROD = Source_BIPROD,
    
    // =====================================================
    // STEP 2: Rename quantity/value columns before merge
    // =====================================================
    // This prevents column name conflicts after the join
    Azure_Renamed = Table.RenameColumns(
        Azure,
        {{"QTY", "Azure_QTY"}, {"COSTS", "Azure_COSTS"}}
    ),
    
    BIPROD_Renamed = Table.RenameColumns(
        BIPROD,
        {{"QTY", "BIPROD_QTY"}, {"COSTS", "BIPROD_COSTS"}}
    ),
    
    // =====================================================
    // STEP 3: CRITICAL FIX - Remove duplicates before merge
    // =====================================================
    // Prevents cartesian product when joining tables
    // Ensures 1:1 matching on join keys
    Azure_Distinct = Table.Distinct(
        Azure_Renamed, 
        {"barcode", "STOREID"}  // Adjust join keys as needed
    ),
    
    BIPROD_Distinct = Table.Distinct(
        BIPROD_Renamed, 
        {"barcode", "STOREID"}  // Adjust join keys as needed
    ),
    
    // =====================================================
    // STEP 4: Full Outer Join
    // =====================================================
    // Captures records from both sources including:
    // - Records only in Azure (Azure_Only)
    // - Records only in BIPROD (BIPROD_Only)
    // - Records in both (Match or Mismatch)
    Merged = Table.NestedJoin(
        Azure_Distinct,
        {"barcode", "STOREID"},  // Join keys
        BIPROD_Distinct,
        {"barcode", "STOREID"},  // Join keys
        "BIPROD",
        JoinKind.FullOuter
    ),
    
    // =====================================================
    // STEP 5: Expand BIPROD columns
    // =====================================================
    Expanded = Table.ExpandTableColumn(
        Merged,
        "BIPROD",
        {"barcode", "STOREID", "BIPROD_QTY", "BIPROD_COSTS", 
         "shopcode", "Seasoncode", "ARTICLE_CODE"},
        {"BIPROD.barcode", "BIPROD.STOREID", "BIPROD_QTY", "BIPROD_COSTS",
         "BIPROD.shopcode", "BIPROD.Seasoncode", "BIPROD.ARTICLE_CODE"}
    ),
    
    // =====================================================
    // STEP 6: Create unified key columns (COALESCE logic)
    // =====================================================
    // If Azure value exists, use it; otherwise use BIPROD value
    // This ensures we have complete key information for all records
    Added_Barcode = Table.AddColumn(
        Expanded, 
        "Final_barcode", 
        each if [barcode] <> null then [barcode] else [BIPROD.barcode], 
        type text
    ),
    
    Added_STOREID = Table.AddColumn(
        Added_Barcode, 
        "Final_STOREID", 
        each if [STOREID] <> null then [STOREID] else [BIPROD.STOREID], 
        type text
    ),
    
    Added_shopcode = Table.AddColumn(
        Added_STOREID, 
        "Final_shopcode", 
        each if [shopcode] <> null then [shopcode] else [BIPROD.shopcode], 
        type text
    ),
    
    Added_Seasoncode = Table.AddColumn(
        Added_shopcode, 
        "Final_Seasoncode", 
        each if [Seasoncode] <> null then [Seasoncode] else [BIPROD.Seasoncode], 
        type text
    ),
    
    Added_ARTICLE_CODE = Table.AddColumn(
        Added_Seasoncode, 
        "Final_ARTICLE_CODE", 
        each if [ARTICLE_CODE] <> null then [ARTICLE_CODE] else [BIPROD.ARTICLE_CODE], 
        type text
    ),
    
    // =====================================================
    // STEP 7: Calculate differences (NULL-SAFE)
    // =====================================================
    // Only calculate difference when BOTH values exist
    // Otherwise, keep as null to distinguish from zero difference
    Added_QTY_Diff = Table.AddColumn(
        Added_ARTICLE_CODE,
        "QTY_Diff",
        each 
            if [Azure_QTY] <> null and [BIPROD_QTY] <> null 
            then [Azure_QTY] - [BIPROD_QTY]
            else null,
        type number
    ),
    
    Added_COSTS_Diff = Table.AddColumn(
        Added_QTY_Diff,
        "COSTS_Diff",
        each 
            if [Azure_COSTS] <> null and [BIPROD_COSTS] <> null 
            then [Azure_COSTS] - [BIPROD_COSTS]
            else null,
        type number
    ),
    
    // =====================================================
    // STEP 8: Add Match Status categorization
    // =====================================================
    Added_Match_Status = Table.AddColumn(
        Added_COSTS_Diff,
        "Match_Status",
        each
            // BIPROD only (Azure has null)
            if [Azure_QTY] = null and [BIPROD_QTY] <> null then "BIPROD_Only"
            
            // Azure only (BIPROD has null)
            else if [Azure_QTY] <> null and [BIPROD_QTY] = null then "Azure_Only"
            
            // Both exist and match perfectly
            else if [Azure_QTY] <> null and [BIPROD_QTY] <> null 
                 and [QTY_Diff] = 0 and [COSTS_Diff] = 0 then "Match"
            
            // Both exist but values differ
            else if [Azure_QTY] <> null and [BIPROD_QTY] <> null then "Mismatch"
            
            // Unexpected case
            else "Unknown",
        type text
    ),
    
    // =====================================================
    // STEP 9: Remove duplicate columns
    // =====================================================
    Removed_Duplicates = Table.RemoveColumns(
        Added_Match_Status,
        {"barcode", "STOREID", "shopcode", "Seasoncode", "ARTICLE_CODE",
         "BIPROD.barcode", "BIPROD.STOREID", "BIPROD.shopcode", 
         "BIPROD.Seasoncode", "BIPROD.ARTICLE_CODE"}
    ),
    
    // =====================================================
    // STEP 10: Rename final columns to clean names
    // =====================================================
    Renamed_Final = Table.RenameColumns(
        Removed_Duplicates,
        {
            {"Final_barcode", "barcode"},
            {"Final_STOREID", "STOREID"},
            {"Final_shopcode", "shopcode"},
            {"Final_Seasoncode", "Seasoncode"},
            {"Final_ARTICLE_CODE", "ARTICLE_CODE"}
        }
    ),
    
    // =====================================================
    // STEP 11: Reorder columns for readability
    // =====================================================
    Reordered = Table.ReorderColumns(
        Renamed_Final,
        {
            "barcode",
            "ARTICLE_CODE",
            "STOREID",
            "shopcode",
            "Seasoncode",
            "Azure_QTY",
            "BIPROD_QTY",
            "QTY_Diff",
            "Azure_COSTS",
            "BIPROD_COSTS",
            "COSTS_Diff",
            "Match_Status"
        }
    ),
    
    // =====================================================
    // STEP 12: Sort by key columns
    // =====================================================
    Sorted = Table.Sort(
        Reordered,
        {
            {"barcode", Order.Ascending},
            {"STOREID", Order.Ascending}
        }
    )
in
    Sorted
