SELECT 
    v.STOREID,
    v.ITEM,
    v.COLOR,
    v.SIZECOUNTER_STOCK,
    v.SIZECOUNTER_ORDERS,
    v.SHORTAGEOFSIZE,
    v.SHORTAGECOUNTER,
    p.shopcode,
    p.Seasoncode
FROM [DATABASE_NAME].[dbo].[ONLINESTOCKSIZECOUNTERS] v
LEFT JOIN (
    SELECT DISTINCT 
        itemid,
        inventcolorid,
        shopcode,
        Seasoncode
    FROM [DATABASE_NAME].[DIM].[Product]
) p 
    ON v.ITEM = p.itemid 
    AND v.COLOR = p.inventcolorid
