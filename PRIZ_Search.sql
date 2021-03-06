USE [PRIZ]
GO
/****** Object:  StoredProcedure [dbo].[srch_SearchResult]    Script Date: 21.05.2021 11:41:11 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- EXEC  [dbo].[srch_SearchResult] @Search='панченко', @RestrictCountRowAll=1000000
-- EXEC [dbo].[srch_SearchResult] @Search = 'Оказание комплексных услуг по технической поддержке и адаптационному сопровождению Комплексной информационной системы «Государственные услуги в сфере образования в электронном виде» (КИС ГУСОЭВ) в части АИС «Зачисление в ОУ», АИС «Зачисление в Профтех», АИС «ЕГЭ», АИС «Олимпиады», АИС «ОП ЭОМ», АИС «ЭЖД», ИС «ГУО», АИС «Зачисление в УДО»', @RestrictCountRowAll=1000000
ALTER PROCEDURE [dbo].[srch_SearchResult]
	@Search nvarchar(1000)
	,@RestrictCountRowAll INT
AS 
  SET NOCOUNT ON;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  BEGIN
  --DECLARE @ConstSearch NVARCHAR(4000) = '"*' + (REPLACE(@Search,'"','')) + '*"'
  DECLARE @ConstSearch NVARCHAR(4000) = '"' + (REPLACE(@Search,'"','')) + '*"'
	
	DECLARE @ResTableSorted TABLE 
	(
		ActivityType VARCHAR(250), 
		Code VARCHAR(50), 
		Name VARCHAR(max), 
		[Url] VARCHAR(250),
		[State] VARCHAR(250), 
		ActivityId INT, 
		ActivityTypeId INT, 
		TableOrder INT, 
		[Rank] INT,
		ActivityTypeName VARCHAR(250)
	)
	IF (LEN(@Search)<1)
		BEGIN
			SELECT ActivityType, Code, Name, [Url], [State], ActivityId, ActivityTypeId, ActivityTypeName FROM @ResTableSorted
			RETURN
		END
	-- Указываем общее количество возвращаемых строк, если значение не указано
	IF(@RestrictCountRowAll IS NULL)
		SET @RestrictCountRowAll=100000
	-- Указываем общее количество возвращаемых строк по каждой сущности при полнотекстовом поиске
	DECLARE @RestrictCountRowEntity INT=1000
	-- Обявляем и заполняем таблицу для сортировки по сущностям
	DECLARE @TableActivity TABLE
	(
		TableName varchar(50),
		TableValue INT
	)
	INSERT INTO @TableActivity (TableName, TableValue) 
	SELECT 'Event', 1
	UNION ALL SELECT 'Project', 2
	UNION ALL SELECT 'Contract', 3
	UNION ALL SELECT 'Contract2014', 4
	UNION ALL SELECT 'Agreement', 5
	UNION ALL SELECT 'InformationSystem', 6
	UNION ALL SELECT 'Activity', 7
	UNION ALL SELECT 'PlanGraph', 8
	UNION ALL SELECT 'User', 9

	DECLARE @ActivitiForSelect TABLE (ActivityId INT,[Rank] INT)
	SET @Search=TRIM(@Search)

	-- Если @Search является числом и имеет в составе знак "-", тогда ищем по коду карты в Activity, 
	-- иначе ищем по всем предопределенным полям за исключением поля Code в таблице Activity
	DECLARE @SeparatePosition INT = CHARINDEX('-',@Search,0)
	IF (ISNUMERIC(REPLACE(@Search,'-',''))=1 AND (@SeparatePosition=3 OR @SeparatePosition=4))
	BEGIN
		INSERT INTO @ActivitiForSelect(ActivityId,[Rank])
			SELECT ActivityId as ActivityId, 1 as [Rank] FROM Activity WHERE Code LIKE '%'+ @Search +'%'
	END
	ELSE
	BEGIN
		IF (@@ROWCOUNT<1)
		BEGIN
			INSERT INTO @ActivitiForSelect(ActivityId,[Rank])
				-- Поиск по карточкам тип которых = Event
				SELECT TOP (@RestrictCountRowEntity) FT_TBL.EventId as ActivityId, KEY_TBL.RANK as [Rank] FROM Event AS FT_TBL 
					INNER JOIN CONTAINSTABLE(Event, (Number), @ConstSearch, LANGUAGE N'Russian', 5) AS KEY_TBL ON FT_TBL.EventId = KEY_TBL.[KEY] WHERE KEY_TBL.RANK >= 30
				-- Поиск по карточкам тип которых = Project
				UNION ALL
				SELECT TOP (@RestrictCountRowEntity) FT_TBL.ProjectId as ActivityId, KEY_TBL.RANK as [Rank] FROM Project AS FT_TBL 
					INNER JOIN CONTAINSTABLE(Project, (Number), @ConstSearch, LANGUAGE N'Russian', 5) AS KEY_TBL ON FT_TBL.ProjectId = KEY_TBL.[KEY] WHERE KEY_TBL.RANK >= 30
				-- Поиск по карточкам тип которых = Contract
				UNION ALL
				SELECT TOP (@RestrictCountRowEntity) FT_TBL_Contract.ContractId as ActivityId, KEY_TBL_Contract.RANK as [Rank] FROM Contract AS FT_TBL_Contract
					INNER JOIN CONTAINSTABLE(Contract, (DescriptionExpectation, FinSupplyRequirements, Contractor, MinContractRequirements, EaistCompetitionNumber, EaistReestrNumber, Number), @ConstSearch, LANGUAGE N'Russian', 5) AS KEY_TBL_Contract ON FT_TBL_Contract.ContractId = KEY_TBL_Contract.[KEY] WHERE KEY_TBL_Contract.RANK >= 30
				-- Поиск по карточкам тип которых = Contract2014
				UNION ALL
				SELECT TOP (@RestrictCountRowEntity) FT_TBL_Contract2014.Contract2014Id as ActivityId, KEY_TBL_Contract2014.RANK as [Rank] FROM Contract2014 AS FT_TBL_Contract2014
					INNER JOIN CONTAINSTABLE(Contract2014, (FinSupplyRequirements, Contractor, MinContractRequirements, PurchaseJustification, EaistCompetitionNumber, EaistReestrNumber, Number), @ConstSearch, LANGUAGE N'Russian', 5) AS KEY_TBL_Contract2014 ON FT_TBL_Contract2014.Contract2014Id = KEY_TBL_Contract2014.[KEY] WHERE KEY_TBL_Contract2014.RANK >= 30
				-- Поиск по карточкам тип которых = Agreement
				UNION ALL
				SELECT TOP (@RestrictCountRowEntity) FT_TBL.AgreementId as AgreementId, KEY_TBL.RANK as [Rank] FROM Agreement AS FT_TBL 
					INNER JOIN CONTAINSTABLE(Agreement, (Contractor, MinContractRequirements, Number), @ConstSearch, LANGUAGE N'Russian', 5) AS KEY_TBL ON FT_TBL.AgreementId = KEY_TBL.[KEY] WHERE KEY_TBL.RANK >= 30
				-- Поиск по карточкам тип которых = InformationSystem
				UNION ALL
				SELECT TOP (@RestrictCountRowEntity) FT_TBL_InformationSystem.InformationSystemId as ActivityId, KEY_TBL_InformationSystem.RANK as [Rank] FROM InformationSystem AS FT_TBL_InformationSystem 
					INNER JOIN CONTAINSTABLE(InformationSystem, (FullName, Purpose, RIRSRegNum), @ConstSearch, LANGUAGE N'Russian', 5) AS KEY_TBL_InformationSystem ON FT_TBL_InformationSystem.InformationSystemId = KEY_TBL_InformationSystem.[KEY] WHERE KEY_TBL_InformationSystem.RANK >= 30
				-- Поиск по карточкам тип которых = Activity
				UNION ALL
				SELECT TOP (@RestrictCountRowEntity) FT_TBL.ActivityId as ActivityId, KEY_TBL.RANK as [Rank] FROM Activity AS FT_TBL 
					INNER JOIN CONTAINSTABLE(Activity, (Name, Description, Comment, SearchTags, Responsible, ShortName), @ConstSearch, LANGUAGE N'Russian', 5) AS KEY_TBL ON FT_TBL.ActivityId = KEY_TBL.[KEY] WHERE KEY_TBL.RANK >= 30
				-- Add 09.04.2020
				UNION ALL
				--SELECT TOP (@RestrictCountRowEntity*6) FT_TBL_ActivityRole.ActivityId as ActivityId, KEY_TBL_User.RANK as [Rank] FROM ActivityRole AS FT_TBL_ActivityRole
				--INNER JOIN [Role] r ON r.RoleId=FT_TBL_ActivityRole.RoleId
				--INNER JOIN Activity a on a.ActivityId=FT_TBL_ActivityRole.ActivityId
				--INNER JOIN [Form] f ON f.FormId=a.ActivityTypeId 
				--	--AND (f.SysName IN ('Product','Subproduct','Contract2014','ExtraPact','chreq_ChangeRequest','Payment')  AND r.Identifier in ('DeputyCurator','Responsible','ProductResponsible'))
				--	--OR (f.SysName IN ('Project')  AND r.Identifier in ('Manager','Curator'))
				--	AND (f.SysName IN (	'Project','Product','Subproduct','Contract2014','ExtraPact','chreq_ChangeRequest','Payment')  
				--	AND r.Identifier in ('Responsible','Manager','DeputyCurator'))
				--INNER JOIN CONTAINSTABLE([User], (FullName), @ConstSearch, LANGUAGE N'Russian', 5) AS KEY_TBL_User ON FT_TBL_ActivityRole.UserId = KEY_TBL_User.[KEY]
				--WHERE KEY_TBL_User.RANK >= 30 AND ISNULL(r.IsDeleted,0) = 0
				SELECT TOP (@RestrictCountRowEntity*6) FT_TBL_ActivityRole.ActivityId as ActivityId, KEY_TBL_User.RANK as [Rank]
				FROM Activity AS a
				JOIN ActivityType AS at ON at.ActivityTypeId = a.ActivityTypeId
				JOIN ActivityRole AS FT_TBL_ActivityRole ON FT_TBL_ActivityRole.ActivityId = a.ActivityId
				JOIN [Role] AS r ON r.RoleId = FT_TBL_ActivityRole.RoleId AND r.Identifier IN ('Responsible','Manager','DeputyCurator') AND ISNULL(r.IsDeleted,0) = 0
				JOIN [User] AS u ON u.UserId = FT_TBL_ActivityRole.UserId AND ISNULL(u.IsDeleted,0) = 0
				INNER JOIN CONTAINSTABLE([User], (FullName), @ConstSearch, LANGUAGE N'Russian', 5) AS KEY_TBL_User ON FT_TBL_ActivityRole.UserId = KEY_TBL_User.[KEY]
				WHERE at.ActivityTableName IN ('Project','Product','Contract2014','Agreement','ptw_PretensionWork')
				-- End Add 09.04.2020
		END
	END
	;WITH PResTable AS (
		SELECT
			TOP (@RestrictCountRowAll) -- Ограничение по количеству строк
			ati.ActivityTableName AS ActivityType -- Тип катрочки
			, a.Code AS Code --  Код карточки
			, a.Name AS Name -- Наименование карточки
			--, fi.FieldName AS [Field] -- Наименование поля
			, (SELECT dbo.GetCreateNewFormUrl(f.FormId, a.Code, DEFAULT)) as [Url] -- Ссылка на карточку
			, vaar.Name AS [State] -- Наименование состояния
			, a.ActivityId AS ActivityId -- Id Карточки
			, a.ActivityTypeId AS ActivityTypeId -- Id Типа карточки
			, CASE WHEN ta.TableValue IS NULL THEN 9999 ELSE ta.TableValue END AS TableOrder -- Служебная сортировка по таблице
			, -AFS.[Rank] AS [Rank] -- вес при FullSearch поиске
			, ati.Name AS ActivityTypeName
		FROM Activity a
			INNER JOIN ActivityType ati ON ati.ActivityTypeId=a.ActivityTypeId
			INNER JOIN [Form] f ON f.ActivityTypeId=a.ActivityTypeId
			--INNER JOIN Field fi ON fi.FormId=f.FormId
			LEFT JOIN @TableActivity ta ON ati.ActivityTableName=ta.TableName
			INNER JOIN ViewActualActivityRecord vaar ON vaar.ActivityId=a.ActivityId
			INNER JOIN @ActivitiForSelect afs ON afs.ActivityId=a.ActivityId
		WHERE ISNULL(f.IsDeleted, 0) = 0 AND ISNULL(ati.IsDeleted, 0) = 0 AND ISNULL(a.IsDisable, 0) = 0
		-- Add 09.04.2020
		ORDER BY afs.ActivityId desc -- Для отображения вначале более свежих карточек
		-- End Add 09.04.2020
		)

	INSERT @ResTableSorted 
	(
		ActivityType, 
		Code, 
		Name, 
		[Url],
		[State], 
		ActivityId, 
		ActivityTypeId, 
		TableOrder, 
		[Rank],
		ActivityTypeName
	)
	SELECT DISTINCT 
		prt.ActivityType
		, prt.Code
		, prt.Name
		, prt.[Url]
		, prt.[State]
		, prt.ActivityId
		, prt.ActivityTypeId
		, prt.TableOrder
		, prt.[Rank]
		, prt.ActivityTypeName
	FROM PResTable AS prt ORDER BY prt.TableOrder, prt.Rank ASC

	SELECT
		rts.ActivityType
		, rts.Code
		, rts.Name
		, rts.[Url]
		, rts.[State]
		, rts.ActivityId
		, rts.ActivityTypeId
		, rts.ActivityTypeName
	FROM @ResTableSorted AS rts 
	-- Add 09.04.2020
	ORDER BY rts.TableOrder,rts.Code DESC
	-- End Add 09.04.2020
END