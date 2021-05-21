DECLARE @ChreqCode nvarchar(50) = '976-813',
        @xml xml = null

SELECT TOP 1 @xml = cD.ConcordData
FROM  dbo.chreq_ChangeRequest c_chreq INNER JOIN dbo.Activity aChreq
                                                 ON aChreq.ActivityId = c_chreq.chreq_ChangeRequestId
									  INNER JOIN dbo.chreq_ConcordDataDocuments cD
									             ON cD.ChangeRequestId = aChreq.ActivityId and
												    cD.DocumentId = -2
WHERE aChreq.Code = @ChreqCode

IF @xml IS NULL
	goto on_end;

DECLARE @Tab TABLE (ID int identity(1,1), Code nvarchar(100), [Name] nvarchar(1000), [Year] nvarchar(256), Val nvarchar(256), Color nvarchar(256), ValueType smallint)
INSERT INTO @Tab (Code, [Name], [Year], Val, Color, ValueType)
SELECT SS.Code, SS.[Name], SS.[Year], SS.Val, SS.Color, SS.ValueType
FROM 
(
SELECT  
       r.value('(PerfIndicatorCode/text())[1]', 'nvarchar(100)') as Code,
	   r.value('(PerfIndicatorName/text())[1]', 'nvarchar(1000)') as [Name],
	   V.value('(Year/text())[1]', 'nvarchar(50)') as [Year], 
	   V.value('(Val/text())[1]', 'nvarchar(50)') as Val,
	   V.value('(Color/text())[1]', 'nvarchar(50)') as Color,
	   1 as ValueType
FROM @xml.nodes('/GetChangeRequestPerfIndicatorsResultClass/PerfIndicatorClass') as t(r)
OUTER APPLY t.r.nodes('FinancialConfigs/FinancialConfigClass/CurrentValue/Values/ValueGridClass') as R(V)
UNION ALL
SELECT  
       r.value('(PerfIndicatorCode/text())[1]', 'nvarchar(100)') as Code,
	   r.value('(PerfIndicatorName/text())[1]', 'nvarchar(1000)') as [Name],
	   V.value('(Year/text())[1]', 'nvarchar(50)') as [Year], 
	   V.value('(Val/text())[1]', 'nvarchar(50)') as Val,
	   V.value('(Color/text())[1]', 'nvarchar(50)') as Color,
	   2 as ValueType
FROM @xml.nodes('/GetChangeRequestPerfIndicatorsResultClass/PerfIndicatorClass') as t(r)
OUTER APPLY 
t.r.nodes('FinancialConfigs/FinancialConfigClass/ChangedValue/Values/ValueGridClass') as R(V)
UNION ALL
SELECT  
       r.value('(PerfIndicatorCode/text())[1]', 'nvarchar(100)') as Code,
	   r.value('(PerfIndicatorName/text())[1]', 'nvarchar(1000)') as [Name],
	   V.value('(Year/text())[1]', 'nvarchar(50)') as [Year], 
	   V.value('(Val/text())[1]', 'nvarchar(50)') as Val,
	   V.value('(Color/text())[1]', 'nvarchar(50)') as Color,
	   3 as ValueType
FROM @xml.nodes('/GetChangeRequestPerfIndicatorsResultClass/PerfIndicatorClass') as t(r)
OUTER APPLY 
t.r.nodes('FinancialConfigs/FinancialConfigClass/DifferenceValue/Values/ValueGridClass') as R(V)
) as SS

--Отсекаю лишние года (мусор) по порядку следования
DELETE A 
FROM @Tab A INNER JOIN 
(SELECT SS.ID, ROW_NUMBER() OVER(PARTITION BY SS.Code, SS.ValueType, SS.[Year] ORDER BY SS.ID ASC) as RowNumber FROM @Tab SS) as B
ON A.ID = B.ID and B.RowNumber <> 1

SELECT @ChreqCode as Activity_Code, Y.Year, Cd.Code, Cd.[Name], CurrentColor.Color as CurrentColor , CurrentVal.Val as CurrentVal, ChangeColor.Color as ChangeColor, ChangeVal.Val as ChangeVal, DiffColor.Color as DiffColor,  DiffVal.Val as DiffVal
FROM 
  (SELECT DISTINCT [Year] FROM @Tab)  as Y --Все года
  CROSS JOIN 
  (SELECT DISTINCT Code, Name FROM @Tab) as Cd --все карточки
  OUTER APPLY 
  (SELECT T.Color FROM @Tab T WHERE T.Year = Y.Year and T.Code = Cd.Code and T.ValueType = 1) as CurrentColor
  OUTER APPLY 
  (SELECT T.Val FROM @Tab T WHERE T.Year = Y.Year and T.Code = Cd.Code and T.ValueType = 1) as CurrentVal
  OUTER APPLY 
  (SELECT T.Color FROM @Tab T WHERE T.Year = Y.Year and T.Code = Cd.Code and T.ValueType = 2) as ChangeColor
  OUTER APPLY 
  (SELECT T.Val FROM @Tab T WHERE T.Year = Y.Year and T.Code = Cd.Code and T.ValueType = 2) as ChangeVal
  OUTER APPLY 
  (SELECT T.Color FROM @Tab T WHERE T.Year = Y.Year and T.Code = Cd.Code and T.ValueType = 3) as DiffColor
  OUTER APPLY 
  (SELECT T.Val FROM @Tab T WHERE T.Year = Y.Year and T.Code = Cd.Code and T.ValueType = 3) as DiffVal
 ORDER BY Y.Year, Cd.Code


on_end:
	PRINT 'Конец делу венец'









