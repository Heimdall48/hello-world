USE [PRIZ]
GO
/****** Object:  StoredProcedure [dbo].[tmln_SetCurrentContractForecast_Inner]    Script Date: 21.05.2021 11:26:59 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[tmln_SetCurrentContractForecast_Inner]
(
  @CardCode nvarchar(100), --код карточки закупки
  @Account nvarchar(255),
  @ErrorMessage nvarchar(1000) OUTPUT
)
AS
/****************************************************************************
Автор: Нелюбин
Дата создания: 23.03.2021
Описание: Метод загрузки dbo.[ActivityForecastHistory] по одной закупке, 
          который возвращает сообщение об ошибке, но исключение не генерирует
	  !xxx!
****************************************************************************/
BEGIN
	SET NOCOUNT ON;

    DECLARE @ActivityId bigint = NULL
    DECLARE @ContractTypeId int = NULL,
			@PlacingMethodId int = NULL,
			@DeterminationMethodId int = NULL,
			@BaseSingleSupplierId int = NULL,
			@chreq_ChangeRequestId bigint = NULL,
			@WhosePGIsIncludedId int = NULL,

			@FactID int = 3,
			@PrognozID int = 2,
			@PlanID int = 1,

			@EndDate smalldatetime = NULL,
			@PrognozBeginDate date = NULL,
			@NewEstimateDate date = NULL,
			@PlanDate date = NULL,

			@CurrentCardId int = NULL,
			@IsThereBackOfficeManagerId int = null,
			@rc int = NULL,
			@CardUrl nvarchar(max) = NULL,
			@ContractState nvarchar(256) = NULL,
			@ChReqState nvarchar(256) = NULL,
			@Delta int = NULL,
  		    @CardVersionId int = NULL,
			@ContractTypeGroupId int = NULL,
			@LastConfigSysName nvarchar(256) = NULL,
			@Value decimal(32,8) = NULL,
			@IndicationTypeId int = NULL,
			@DeviationInDays int = NULL,
			@IsApprovedPlan bit = NULL,
		    @FinanceIMPPlanValue decimal(32,8) = NULL
			
	SET @ErrorMessage = NULL

	--1.закупка опубликована в ПГ ранее предыдущего года, т.е. закупка связана с план-графиком PlanGraph у которого период действия YEAR (EndDate) < YEAR (GETDATE)-1
	select @ActivityId = a.ActivityId,  @ContractTypeId = c.ContractTypeId, 
	       @PlacingMethodId = ISNULL(c.PlacingMethodId,0), 
		   @EndDate = B.EndDate,
		   @IsThereBackOfficeManagerId = c.IsThereBackOfficeManagerId,
		   @DeterminationMethodId = c.DeterminationMethodId,
		   @BaseSingleSupplierId = C.BaseSingleSupplierId,
		   @ContractState = vaar.[SysName],
		   @WhosePGIsIncludedId = c.WhosePGIsIncludedId,
		   @ContractTypeGroupId = c.ContractTypeGroupId,
		   @IsApprovedPlan = c.IsApprovedPlan
	from Activity a INNER JOIN dbo.Contract2014 c
		                           ON c.Contract2014Id = a.ActivityId
					OUTER APPLY 
	                          (SELECT TOP 1 AR.ChildId as Contract2014Id, PG.EndDate
	                           FROM dbo.ActivityRelation AR INNER JOIN dbo.PlanGraph PG
																ON PG.PlanGraphId = AR.ParentId
														    INNER JOIN dbo.Activity A --для EndDate
														        ON A.ActivityId = PG.PlanGraphId
							    WHERE AR.ChildId = c.Contract2014Id
						 	  ) as B
					INNER JOIN ViewActualActivityRecord AS vaar 
									ON vaar.ActivityId = a.ActivityId 
	where a.Code = @CardCode

	if @ActivityId IS NULL
	BEGIN
		SET @ErrorMessage = N'Карточка закупки с кодом "'+@CardCode+'" не найдена!'
	    goto on_error;	  
	END

	IF @ContractTypeId IN (34,41,42,43,44,45,46) OR @PlacingMethodId IN (8,9,10,16,17) OR YEAR(@EndDate) < 2021
     	goto on_end;
   
   --Проверка на показатели
   IF EXISTS(SELECT * 
             FROM dbo.FinancialValue fv INNER JOIN dbo.FinancialConfig fc
			                                       ON fc.FinancialConfigId = fv.FinancialConfigId
			 WHERE fv.ActivityId = @ActivityId and fc.[SysName] IN (N'FinanceIMPPlan', N'FinanceForecastPrice')) AND
	  EXISTS(SELECT * 
	         FROM [dbo].[ActivityRecord] AR INNER JOIN dbo.[State] S 
			                                           ON S.StateId = AR.StateId
			 WHERE AR.ActivityId = @ActivityId and AR.IsLast = 1 and S.[SysName] IN (N'StateBasket', N'StateCancelPurchase') 
			)
	  goto on_end;

   IF NOT EXISTS(SELECT * 
                 FROM dbo.FinancialValue fv INNER JOIN dbo.FinancialConfig fc
			                                       ON fc.FinancialConfigId = fv.FinancialConfigId
	    		 WHERE fv.ActivityId = @ActivityId and fc.[SysName] IN (N'FinanceIMPPlan', N'FinanceForecastPrice') 
				 ) 
   BEGIN
     --то добавить в таблицу ActivityForecastHistory справочную карточку tmln_ForecastCardId=5 и на выход
	 IF NOT EXISTS(SELECT * FROM dbo.ActivityForecastHistory A WHERE A.ActivityId = @ActivityId and A.tmln_ForecastCardId = 5)
			INSERT INTO [dbo].[ActivityForecastHistory]([ActivityId] , [VersionId] ,[tmln_ForecastCardId])
			VALUES(@ActivityId, 1, 5)
	 goto on_end;
   END
   
   --Начало отсчёта для прогноза
   /*SELECT TOP 1 @PrognozBeginDate = cast(FVL.[Date] as date)
   FROM PrizLogs.dbo.[FinancialValueLog] FVL CROSS APPLY FVL.NewValue.nodes('/FinancialValue/FinancialConfigId') AS configs(pref)
                                             INNER JOIN dbo.FinancialConfig fc 
											                                ON fc.FinancialConfigId =  pref.value('(text())[1]', 'int') and
																			   fc.IsDeleted = 0
   WHERE FVL.ActivityId = @ActivityId and FVL.Operation IN (N'u',N'i') and fc.[SysName] IN (N'FinanceIMPPlan', N'FinanceForecastPrice')
   ORDER BY FVL.Date DESC*/

   SELECT TOP 1 @PrognozBeginDate = cast(FVL.ChangeDate as date)
   FROM dbo.[FinancialValue] FVL INNER JOIN dbo.FinancialConfig fc 
			                                ON fc.FinancialConfigId = FVL.FinancialConfigId and
											   fc.IsDeleted = 0
   WHERE FVL.ActivityId = @ActivityId and fc.[SysName] IN (N'FinanceIMPPlan', N'FinanceForecastPrice')
   ORDER BY FVL.ChangeDate DESC

   IF @PrognozBeginDate IS NULL
      goto on_end;
   
   --Последний добавленный фин. показатель
   SET @LastConfigSysName = [dbo].[GetActualFinancialConfigSysName](@CardCode)
   IF  @LastConfigSysName IS NULL
       SET @LastConfigSysName = N'FinanceForecastPrice';

   ------------------------------------------------------Пошло по карточкам-------------------------------------------------------
   --SET @CurrentVersionID = NULL
   SET @CurrentCardId = 1
   SET @NewEstimateDate = NULL

   SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
   FROM dbo.[ActivityLog] L 
   WHERE L.ActivityId = @ActivityId and L.ActivityTypeId = 27 and L.ElementIdentifier = 'StateId' and 
         L.ElementId = 1022 and L.OldValue = '413'
   ORDER BY L.[Date] DESC
   
   IF @NewEstimateDate IS NOT NULL
   BEGIN
     -------------------------------------------Факт-----------------------------------------------
     EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, NULL,  @IndicationTypeId,  @DeviationInDays 
	 if @rc <> 0
	 BEGIN
	   SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
	   goto on_error;
	 END
	 ----------------------------------------------------------------------------------------------
   END
     ELSE
   BEGIN
		-----------------------------------Прогноз-Вставляем если нет факта-----------------------------
			--Рассчитали дату для прогноза
		IF [dbo].[ADDWORKDAYS_1](3,@PrognozBeginDate) <= cast(GetDate() as date)
		SET @NewEstimateDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date));
		ELSE
		SET @NewEstimateDate = [dbo].[ADDWORKDAYS_1](3, @PrognozBeginDate);

		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, NULL, @IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
			SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
			goto on_error;
		END
		---------------------------------------------------------------------------------------------
   END

   SET @CurrentCardId = 2
   SET @NewEstimateDate = NULL

   IF @IsThereBackOfficeManagerId = 1 AND ISNULL(@ContractTypeId,0) NOT IN (20,35,36,47)
   BEGIN
      SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
	  FROM dbo.[ActivityLog] L 
      WHERE L.ActivityId = @ActivityId and L.ActivityTypeId = 27 and L.ElementIdentifier = 'StateId' and 
            L.ElementId = 1022 and L.OldValue = '931' and ISNULL(L.NewValue,'') <> '413'
      ORDER BY L.[Date] DESC

	  IF @NewEstimateDate IS NOT NULL
	  BEGIN
		 -------------------------------------------Факт-----------------------------------------------
		 EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, NULL,@IndicationTypeId,  @DeviationInDays
		 if @rc <> 0
		 BEGIN
		   SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		   goto on_error;
		 END
	  END
	    ELSE
	  BEGIN
	    ------------------------------Грузим прогноз если нет факта-------------------------------------
   	    SET @PrognozBeginDate = NULL

		--Определяем опорную дату от предыдущей карточки - сначала факт потом прогноз	
		SELECT TOP 1 @PrognozBeginDate = AFH.EstimatedDate
		FROM dbo.ActivityForecastHistory AFH 
		WHERE AFH.ActivityId = @ActivityId and AFH.tmln_DateTypeId = @FactID and AFH.tmln_ForecastCardId = 1
		ORDER BY AFH.VersionId DESC

		IF @PrognozBeginDate IS NULL
			SELECT TOP 1 @PrognozBeginDate = AFH.EstimatedDate
			FROM dbo.ActivityForecastHistory AFH 
			WHERE AFH.ActivityId = @ActivityId and AFH.tmln_DateTypeId = @PrognozID and AFH.tmln_ForecastCardId = 1
			ORDER BY AFH.VersionId DESC

		IF @PrognozBeginDate IS NULL
		BEGIN
		SET @ErrorMessage = N'Не обнаружена прогнозная дата (1). CardID = '+cast(@CurrentCardId as nvarchar)
		goto on_error;
		END

    	  IF [dbo].[ADDWORKDAYS_1](7,@PrognozBeginDate) <= cast(GetDate() as date)
			SET @NewEstimateDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date));
		ELSE
			SET @NewEstimateDate = [dbo].[ADDWORKDAYS_1](7,@PrognozBeginDate);

		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, NULL, @IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
		  SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		  goto on_error;
		END
	  END
   END

   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 3
   SET @NewEstimateDate = NULL

   IF ISNULL(@ContractTypeId,0) IN (20,35,36,47) AND 
      EXISTS(SELECT * 
	         FROM dbo.[ActivityLog] AL 
			 WHERE AL.ActivityId = @ActivityId and AL.ElementIdentifier='StateId'and AL.NewValue='1299' and ElementId=1022)
   BEGIN

	  SELECT TOP 1 @CardUrl = N'https://spu.mos.ru' + [dbo].[GetFormUrlByCode](ach.Code) 
      FROM ActivityRelation AS ar JOIN Activity AS apar ON apar.ActivityId = ar.ParentId
									JOIN chreq_ChangeRequest AS ccr ON ar.ChildId=ccr.chreq_ChangeRequestId
									JOIN chreq_ReviewThread AS crt ON crt.chreq_ReviewThreadId = ccr.ReviewThreadId AND crt.[SysName]='ApprovalChainTZforCP' AND crt.IsDeleted = 0
									JOIN Activity AS ach ON ach.ActivityId = ccr.chreq_ChangeRequestId
									JOIN ViewActualActivityRecord AS vaar ON vaar.ActivityId = ach.ActivityId AND vaar.[SysName] NOT IN ('StateCanceled','StateRejected')
      WHERE apar.Code=@CardCode
	  ORDER BY ach.ActivityId DESC

	  SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
	  FROM dbo.[ActivityLog] L 
      WHERE L.ActivityId = @ActivityId and L.ElementIdentifier = 'StateId' and 
            L.ElementId = 1022 and L.OldValue = '1301'
      ORDER BY L.[Date] DESC

	  IF @NewEstimateDate IS NOT NULL
	  BEGIN
		 -------------------------------------------Факт-----------------------------------------------
		 EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		 if @rc <> 0
		 BEGIN
		   SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		   goto on_error;
		 END
	  END
	    ELSE
	  BEGIN
	    ------------------------------Грузим прогноз если нет факта-------------------------------------
		SELECT TOP 1 @PrognozBeginDate = cast(AL.[Date] as date)
        FROM dbo.[ActivityLog] AL 
        WHERE  AL.ActivityId = @ActivityId and AL.ElementIdentifier='StateId'and AL.NewValue='1299' and ElementId=1022
		ORDER BY AL.Date DESC

		IF @PrognozBeginDate IS NULL
		BEGIN
		SET @ErrorMessage = N'Не обнаружена прогнозная дата (2). CardID = '+cast(@CurrentCardId as nvarchar)
		goto on_error;
		END

    	IF @PrognozBeginDate <= cast(GetDate() as date)
			SET @NewEstimateDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date));
		ELSE
			SET @NewEstimateDate = [dbo].[ADDWORKDAYS_1](5,@PrognozBeginDate);

		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
		  SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		  goto on_error;
		END
	  END
   END

   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 4
   SET @NewEstimateDate = NULL
 
   SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
	  FROM dbo.[ActivityLog] L 
      WHERE L.ActivityId = @ActivityId and L.ElementIdentifier='IsKPGZChecked' and LOWER(L.NewValue) IN ('true', '1') and
		    L.UserAccount in (select u.Account 
			                  from GroupMember gm join [Group] g 
							                                  on g.GroupId=gm.GroupId AND g.GroupId in (61,62,63)
												  join [User] u 
												              on u.UserId=gm.UserId and LOWER(u.IsDeleted) not in ('1', 'true'))
      ORDER BY L.[Date] DESC

	IF @NewEstimateDate IS NOT NULL
	BEGIN
		 -------------------------------------------Факт-----------------------------------------------
	  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
      if @rc <> 0
	  BEGIN
		 SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		 goto on_error;
	  END
	END
	  ELSE
	BEGIN
	  IF EXISTS(SELECT * 
	            FROM dbo.ActivityRecord AR INNER JOIN dbo.[State] S 
				                                      ON S.StateId = AR.StateId
				WHERE AR.ActivityId = @ActivityId and AR.IsLast = 1 and S.[SysName] = 'StateCheckClassificatorsCodes')
		 SELECT TOP 1 @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(AL.[Date] as date)) 
         FROM dbo.[ActivityLog] AL 
         WHERE  AL.ActivityId = @ActivityId and AL.ElementIdentifier='StateId'and AL.NewValue='709'
		 ORDER BY AL.Date DESC
	  ELSE
	    BEGIN
		  IF @IsThereBackOfficeManagerId = 1 AND ISNULL(@ContractTypeId,0) NOT IN (20,35,36,47) 
		    SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 2)
		    ELSE
		  BEGIN
		     IF ISNULL(@ContractTypeId,0) IN (20,35,36,47) AND EXISTS(SELECT * FROM dbo.[ActivityLog] AL 
																	  WHERE  AL.ActivityId = @ActivityId and AL.ElementIdentifier='StateId'and 
																	         AL.NewValue='1299') 
				SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 3)
			 ELSE
				SET @PrognozBeginDate =  [dbo].[ADDWORKDAYS_1](1, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 1)) 
		  END
		END

		IF @PrognozBeginDate IS NULL
		BEGIN
			SET @ErrorMessage = N'Не обнаружена прогнозная дата (3). CardID = '+cast(@CurrentCardId as nvarchar)
			goto on_error;
		END
		
		IF @PrognozBeginDate <= cast(GetDate() as date)
			SET @NewEstimateDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date));
		ELSE
			SET @NewEstimateDate = @PrognozBeginDate  ;

		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, NULL, @IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
		  SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		  goto on_error;
		END
	END

   --Справочная информация
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 5
   SET @NewEstimateDate = NULL

   IF NOT EXISTS(SELECT * FROM dbo.ActivityForecastHistory A WHERE A.ActivityId = @ActivityId and A.tmln_ForecastCardId = @CurrentCardId)
				INSERT INTO [dbo].[ActivityForecastHistory]([ActivityId] , [VersionId] ,[tmln_ForecastCardId])
				VALUES(@ActivityId, 1, @CurrentCardId)

   --------------------------------Согласование ОНЦ---------------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 6
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL
   SET @chreq_ChangeRequestId = NULL

   SELECT @FinanceIMPPlanValue = SUM(fv.[Value]) 
   FROM dbo.FinancialValue fv INNER JOIN dbo.FinancialConfig fc 
	                                                          ON fc.FinancialConfigId = fv.FinancialConfigId
   WHERE fc.[SysName] = N'FinanceIMPPlan' and fc.IsDeleted = 0 and fv.ActivityId = @ActivityId
   
   IF @DeterminationMethodId <> 3 AND  
     (
	  @PlacingMethodId <> 7 OR 
      (@PlacingMethodId = 7 AND  @BaseSingleSupplierId IN (3,6,9,11,12,18,22,23,30,301,31,32))
	 )
	 AND 
     @FinanceIMPPlanValue > 3000000
   BEGIN
      --Нахожу последний согл для закупки
   	  SELECT TOP 1 @CardUrl = N'https://spu.mos.ru' + [dbo].[GetFormUrlByCode](ach.Code) , @NewEstimateDate = SS.[Date]
      FROM ActivityRelation AS ar JOIN chreq_ChangeRequest AS ccr 
	                                ON ar.ChildId=ccr.chreq_ChangeRequestId and ar.ParentId = @ActivityId
								  JOIN chreq_ReviewThread AS crt 
								    ON crt.chreq_ReviewThreadId = ccr.ReviewThreadId AND crt.[SysName]='ApprovalChainONC' and crt.IsDeleted = 0
								  JOIN Activity AS ach 
								    ON ach.ActivityId = ccr.chreq_ChangeRequestId
								  JOIN ViewActualActivityRecord AS vaar 
									ON vaar.ActivityId = ccr.chreq_ChangeRequestId AND vaar.[SysName] = 'StateAgreed'
								  CROSS APPLY ( SELECT TOP 1 L.[Date]
												FROM dbo.[ActivityLog] L 
												WHERE L.ActivityId = ccr.chreq_ChangeRequestId and L.ActivityTypeId=37 and L.ElementIdentifier='StateId' AND L.NewValue='999'
											    ORDER BY L.[Date] DESC) as SS
	  ORDER BY ccr.chreq_ChangeRequestId DESC

	  IF @NewEstimateDate IS NOT NULL
	  BEGIN
	  	 -------------------------------------------Факт-----------------------------------------------
		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl,@IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
			 SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
			goto on_error;
		END
	  END
	    ELSE
	  BEGIN --Прогноз
		 SELECT TOP 1 @chreq_ChangeRequestId = ccr.chreq_ChangeRequestId, @CardUrl = N'https://spu.mos.ru' + [dbo].[GetFormUrlByCode](ach.Code) , @ChReqState = vaar.[SysName]
         FROM ActivityRelation AS ar JOIN chreq_ChangeRequest AS ccr 
	                                ON ar.ChildId=ccr.chreq_ChangeRequestId and ar.ParentId = @ActivityId
								  JOIN chreq_ReviewThread AS crt 
								    ON crt.chreq_ReviewThreadId = ccr.ReviewThreadId AND crt.[SysName]='ApprovalChainONC' and crt.IsDeleted = 0
								  JOIN Activity AS ach 
								    ON ach.ActivityId = ccr.chreq_ChangeRequestId
								  JOIN ViewActualActivityRecord AS vaar 
									ON vaar.ActivityId = ccr.chreq_ChangeRequestId 
        ORDER BY ach.ActivityId DESC 

	    IF @chreq_ChangeRequestId IS NULL
		BEGIN--Согл не существует
		  IF @ContractState = N'StateMatchingJIP'
		    SELECT TOP 1 @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](6, cast(AL.[Date] as date))
            FROM dbo.[ActivityLog] AL 
            WHERE  AL.ActivityId = @ActivityId and AL.ElementIdentifier='StateId'and AL.NewValue='419' and ElementId=1022
		    ORDER BY AL.[Date] DESC
				ELSE
            --Закупка не в состоянии
			SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](6, [dbo].[tmln_GetLastEstimateDate](@ActivityId, case when  @IsThereBackOfficeManagerId = 1 AND 
			                                                                                                          ISNULL(@ContractTypeId,0) NOT IN (20,35,36,47) then 2 
			                                                                                                    else 4
																			                               end))
		END --Согл не существует
		  ELSE
		BEGIN--Согл существует
		  IF @ChReqState = 'StateInitiation'
		  BEGIN
			SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](5, cast(GetDate() as date))
			SET @NewEstimateDate = @PrognozBeginDate
		  END
     	     /*SELECT TOP 1 @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](5, cast(AL.[Date] as date))
             FROM dbo.[ActivityLog] AL 
             WHERE  AL.ActivityId = @chreq_ChangeRequestId and AL.ElementIdentifier='StateId'and AL.NewValue='971' and ElementId=1022
		     ORDER BY AL.[Date] DESC*/

		  IF @ChReqState IN (N'StateOnAgreement',N'StateCheckFixRemarks')
		     SELECT TOP 1 @PrognozBeginDate = cast(f.LimitDate as date)
			 FROM ChangeRequestReviewer f 
			 WHERE f.ChangeRequestId = @chreq_ChangeRequestId and f.ChangeRequestStateId >=0 and f.IsDeleted = 0 and f.LimitDate IS NOT NULL
			 ORDER BY f.OrderNumberApproval DESC, f.LimitDate DESC

		  IF @ChReqState IN ('StatePaused', 'StateAgreedWithComments')
		  BEGIN
			SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](2, cast(GetDate() as date))
			SET @NewEstimateDate = @PrognozBeginDate
		  END
    	    /*SELECT TOP 1 @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](2, cast(AL.[Date] as date))
            FROM dbo.[ActivityLog] AL 
            WHERE  AL.ActivityId = @chreq_ChangeRequestId and AL.ElementIdentifier='StateId'and AL.NewValue=case when @ChReqState = 'StatePaused' then  '982' 
			                                                                                                     else '978'
																											end and ElementId=1022
		    ORDER BY AL.[Date] DESC*/
		END--Согл существует

		IF @PrognozBeginDate IS NULL
		BEGIN
			SET @ErrorMessage = N'Не обнаружена прогнозная дата (4). CardID = '+cast(@CurrentCardId as nvarchar)
			goto on_error;
		END

		IF @NewEstimateDate IS NULL
		BEGIN
		  IF @PrognozBeginDate <= cast(GetDate() as date)
			 SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GETDATE() as date))

		  SET @NewEstimateDate = @PrognozBeginDate
		END

		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl,@IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
			SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
			goto on_error;
		END
	  END--Прогноз	  
   END

   ------------------------------------Согласование КД------------------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 7
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL
   SET @chreq_ChangeRequestId = NULL
   SET @ChReqState = NULL
   
   --Взяли последнее согласование
   SELECT TOP 1 @chreq_ChangeRequestId = ccr.chreq_ChangeRequestId, @CardUrl = N'https://spu.mos.ru' + [dbo].[GetFormUrlByCode](ach.Code) , @ChReqState = vaar.[SysName]
         FROM ActivityRelation AS ar JOIN chreq_ChangeRequest AS ccr 
	                                ON ar.ChildId=ccr.chreq_ChangeRequestId and ar.ParentId = @ActivityId
								  JOIN chreq_ReviewThread AS crt 
								    ON crt.chreq_ReviewThreadId = ccr.ReviewThreadId AND crt.[SysName]='ApprovalChainSetOfDocuments' and crt.IsDeleted = 0
								  JOIN Activity AS ach 
								    ON ach.ActivityId = ccr.chreq_ChangeRequestId
								  JOIN ViewActualActivityRecord AS vaar 
									ON vaar.ActivityId = ccr.chreq_ChangeRequestId 
        ORDER BY ach.ActivityId DESC 
  
	IF @WhosePGIsIncludedId = 37 OR (ISNULL(dbo.[GetActualFinancialConfigValuePlan] (@CardCode),0) < 3000000)
	BEGIN
	    IF @ChReqState = 'StateAgreed' 
			SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
			FROM dbo.[ActivityLog] L 
			WHERE L.ActivityId = @chreq_ChangeRequestId and L.ElementIdentifier='StateId' AND L.NewValue='999'
			ORDER BY L.[Date] DESC
	END 
		ELSE
	BEGIN
		IF NOT EXISTS(SELECT * 
		              FROM ChangeRequestReviewer crr 
					  WHERE crr.ChangeRequestId = @chreq_ChangeRequestId and crr.ChangeRequestStateId = -1 and crr.IsDeleted = 0)
			SELECT TOP 1 @NewEstimateDate = cast(crr.ApprovedDate as date)
			FROM ChangeRequestReviewer crr 
			WHERE crr.ChangeRequestId = @chreq_ChangeRequestId and crr.ChangeRequestStateId = 1 and crr.ApprovedDate IS NOT NULL and crr.IsDeleted = 0
			ORDER BY crr.ApprovedDate DESC
		ELSE
			SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
			FROM dbo.[ActivityLog] L 
			WHERE L.ActivityId = @chreq_ChangeRequestId and L.ElementIdentifier='StateId' AND L.NewValue='999'
			ORDER BY L.[Date] DESC
	END
  

   IF @NewEstimateDate IS NOT NULL
   BEGIN
	 -------------------------------------------Факт-----------------------------------------------
	 EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl,@IndicationTypeId,  @DeviationInDays
	 if @rc <> 0
	 BEGIN
	   SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
	   goto on_error;
  	 END
   END
	  ELSE
   BEGIN
     -----------------------------------------Прогноз-------------------------------------------------
	 SET @Delta  = case when @WhosePGIsIncludedId IN (37, 257) then 9 
			                 else 7
				   end
     IF @chreq_ChangeRequestId IS NULL
	 BEGIN 
	    --Согл не существует
	   IF @ContractState = N'StatePrepareSetOfDocuments'
			SELECT TOP 1 @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](case when @WhosePGIsIncludedId IN (37, 257) then 9 
			                                                            else 7
																   end, cast(AL.[Date] as date))
            FROM dbo.[ActivityLog] AL 
            WHERE  AL.ActivityId = @ActivityId and AL.ElementIdentifier='StateId'and AL.NewValue='420' and ElementId=1022
		    ORDER BY AL.[Date] DESC
		ELSE
		 BEGIN
		    --6 карточка
			SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 6))
			--2 карточка
			IF @PrognozBeginDate IS NULL
				SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 2))
			--3 карточка
			IF @PrognozBeginDate IS NULL
        	   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 3))
			--4 карточка
			IF @PrognozBeginDate IS NULL
			   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 4))
		 END
	 END
	 ELSE
	 BEGIN
		----Согл существует------------
		IF @ChReqState = N'StateInitiation'
		   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta - 1, cast(GetDate() as date))
		IF @ChReqState = 'StateOnAgreement'
		BEGIN
		   SELECT TOP 1 @PrognozBeginDate = cast(f.LimitDate as date)
		   FROM ChangeRequestReviewer f 
		   WHERE f.ChangeRequestId = @chreq_ChangeRequestId and f.ChangeRequestStateId >=0 and f.IsDeleted = 0 and f.LimitDate IS NOT NULL
		   ORDER BY f.OrderNumberApproval DESC, f.LimitDate DESC
		   IF @PrognozBeginDate <= cast(GetDate() as date)
		      SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta - 3, cast(GetDate() as date))
		   ELSE
		      SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta - 3, @PrognozBeginDate)
		END

   	    IF @ChReqState IN ('StatePaused', 'StateAgreedWithComments')
		   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta - 3, cast(GetDate() as date))
   	    IF @ChReqState IN ('StateFinalDecision')
		BEGIN
		   DECLARE @Y int = NULL 
		   SELECT @Y = COUNT(DISTINCT f.OrderNumberApproval)
		   FROM ChangeRequestReviewer f 
		   WHERE f.ChangeRequestId = @chreq_ChangeRequestId and f.IsDeleted = 0 and f.LimitDate IS NULL

		   SELECT TOP 1 @PrognozBeginDate = cast(f.LimitDate as date)
		   FROM ChangeRequestReviewer f 
		   WHERE f.ChangeRequestId = @chreq_ChangeRequestId and f.ChangeRequestStateId >=0 and f.IsDeleted = 0 and f.LimitDate IS NOT NULL
		   ORDER BY f.OrderNumberApproval DESC, f.LimitDate DESC
    	   IF @PrognozBeginDate <= cast(GetDate() as date)
		     SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Y*2, cast(GetDate() as date))
		   ELSE
		     SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Y*2, cast(@PrognozBeginDate as date))
		END
	 END  ----Согл существует------------

	 IF @PrognozBeginDate IS NULL
	 BEGIN
		SET @ErrorMessage = N'Не обнаружена прогнозная дата (5). CardID = '+cast(@CurrentCardId as nvarchar)
		goto on_error;
	 END

	 IF @PrognozBeginDate <= cast(GetDate() as date)
		SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GETDATE() as date))

	 SET @NewEstimateDate = @PrognozBeginDate

	 EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl,@IndicationTypeId,  @DeviationInDays
	 if @rc <> 0
	 BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	 END
	 -------------------------------------------Прогноз-----------------------------------------------
   END

   ------------------------------------Согласование РГ ГРБС------------------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 8
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL
   SET @chreq_ChangeRequestId = NULL
   SET @ChReqState = NULL

   IF @WhosePGIsIncludedId <> 37 AND 
    (SELECT SUM(fv.[Value]) 
	 FROM dbo.FinancialValue fv INNER JOIN dbo.FinancialConfig fc 
	                                                          ON fc.FinancialConfigId = fv.FinancialConfigId
	 WHERE fc.[SysName] = N'FinanceIMPTEOWithoutReductionFactor' and fc.IsDeleted = 0 and fv.ActivityId = @ActivityId
	) >= 3000000
	BEGIN
	  SELECT TOP 1 @chreq_ChangeRequestId = ccr.chreq_ChangeRequestId, @CardUrl = N'https://spu.mos.ru' + [dbo].[GetFormUrlByCode](ach.Code), @ChReqState = vaar.[SysName]
      FROM ActivityRelation AS ar JOIN chreq_ChangeRequest AS ccr 
	                                ON ar.ChildId=ccr.chreq_ChangeRequestId and ar.ParentId = @ActivityId
								  JOIN chreq_ReviewThread AS crt 
								    ON crt.chreq_ReviewThreadId = ccr.ReviewThreadId AND crt.[SysName]=N'ApprovalChainSetOfDocuments' and crt.IsDeleted = 0
								  JOIN Activity AS ach 
								    ON ach.ActivityId = ccr.chreq_ChangeRequestId
								  JOIN ViewActualActivityRecord AS vaar 
									ON vaar.ActivityId = ccr.chreq_ChangeRequestId 
      ORDER BY ach.ActivityId DESC 

	  SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
	  FROM dbo.[ActivityLog] L 
	  WHERE L.ActivityId = @ActivityId and L.ElementIdentifier='StateId' AND L.OldValue = '991' AND L.NewValue='999' AND L.UserAccount = N'HQ\pimenovaev3' AND L.ActivityTypeId = 37
	  ORDER BY L.[Date] DESC

	  IF @NewEstimateDate IS NOT NULL
	  BEGIN
		-------------------------------------------Факт-----------------------------------------------
		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
			SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
			goto on_error;
  		END
		-------------------------------------------Факт-----------------------------------------------
	  END
	    ELSE
	  BEGIN
		 -----------------------------------------Прогноз--------------------------------------------
		 IF @chreq_ChangeRequestId IS NULL
		 BEGIN  --Согл не существует
		   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](2, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 7))
		   IF @PrognozBeginDate <= cast(GetDate() as date)
              SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))
		 END    --Согл не существует
		   ELSE
		 BEGIN --Согл существует
		   IF @ChReqState = N'StateFinalDecision' AND 
		      NOT EXISTS(SELECT * 
						 FROM dbo.ChangeRequestReviewer R 
			             WHERE R.ChangeRequestId = @chreq_ChangeRequestId and R.ChangeRequestStateId < 0 and R.IsDeleted = 0 AND 
						       R.OrderNumberApproval = (SELECT MAX(R1.OrderNumberApproval) 
							                            FROM dbo.ChangeRequestReviewer R1 
														WHERE R1.ChangeRequestId = R.ChangeRequestId and R.IsDeleted = 0 )
						)
			BEGIN --StateFinalDecision
				SELECT TOP 1 @PrognozBeginDate = cast(f.LimitDate as date)
				FROM ChangeRequestReviewer f 
				WHERE f.ChangeRequestId = @chreq_ChangeRequestId and f.ChangeRequestStateId >=0 and f.IsDeleted = 0 and f.LimitDate IS NOT NULL
				ORDER BY f.OrderNumberApproval DESC, f.LimitDate DESC

				IF @PrognozBeginDate <= cast(GetDate() as date)
				   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](2, cast(GetDate() as date))
				ELSE
				  SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](2, @PrognozBeginDate)
			END --StateFinalDecision
			  ELSE
            BEGIN
				IF @ChReqState = N'StateVoteRG'
				BEGIN --StateVoteRG
				  SELECT TOP 1 @PrognozBeginDate = cast(MAX(VL.LimitDate) as date) FROM dbo.chreq_ChangeRequestVoteList VL WHERE VL.ChangeRequestId = @chreq_ChangeRequestId
				  IF @PrognozBeginDate <= cast(GetDate() as date)
					SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))
				END   --StateVoteRG
				  ELSE
				BEGIN
					SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](2, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 7))
					IF @PrognozBeginDate <= cast(GetDate() as date)
						SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))
				END
			END
		 END   --Согл существует

		 IF @PrognozBeginDate IS NULL
		 BEGIN
			SET @ErrorMessage = N'Не обнаружена прогнозная дата (6). CardID = '+cast(@CurrentCardId as nvarchar)
			goto on_error;
		 END

		 SET @NewEstimateDate = @PrognozBeginDate

		 EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		 if @rc <> 0
		 BEGIN
			SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
			goto on_error;
		 END
		 -----------------------------------------Прогноз--------------------------------------------
	  END
	END
   ------------------------------------Запрос на измененение------------------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 12
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL
   SET @chreq_ChangeRequestId = NULL
   SET @ChReqState = NULL
   --Количество дней
   SET @Delta = 2 
   SET @DeviationInDays = NULL

    SELECT TOP 1 @chreq_ChangeRequestId = ccr.chreq_ChangeRequestId, @CardUrl = N'https://spu.mos.ru' + [dbo].[GetFormUrlByCode](ach.Code), @ChReqState = vaar.[SysName],
	             @CardVersionId = ach.CardVersionId, 
				 @PrognozBeginDate = cast(ach.CreationDate as date)
    FROM ActivityRelation AS ar JOIN chreq_ChangeRequest AS ccr 
	                                ON ar.ChildId=ccr.chreq_ChangeRequestId and ar.ParentId = @ActivityId
								  JOIN chreq_ReviewThread AS crt 
								    ON crt.chreq_ReviewThreadId = ccr.ReviewThreadId AND crt.[SysName]=N'zni24' and crt.IsDeleted = 0
								  JOIN Activity AS ach 
								    ON ach.ActivityId = ccr.chreq_ChangeRequestId
								  JOIN ViewActualActivityRecord AS vaar 
									ON vaar.ActivityId = ccr.chreq_ChangeRequestId 
     ORDER BY ach.ActivityId DESC 
	 
	 IF @ChReqState = N'StateAgreed'
	 BEGIN
		SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
		FROM dbo.[ActivityLog] L 
		WHERE L.ActivityId = @chreq_ChangeRequestId and L.ElementIdentifier='StateId' AND L.NewValue='999'
		ORDER BY L.[Date] DESC

		IF @NewEstimateDate IS NULL
		BEGIN
		  SET @ErrorMessage = N'Для карточки ID=12 не обнаружена дата перевода ЗНИ в "согласовано"'
		  goto on_error;
		END
		-------------------------------------------Факт-----------------------------------------------
		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
			SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
			goto on_error;
  		END
		-------------------------------------------Факт-----------------------------------------------
	 END
	   ELSE
	 BEGIN
		--Если ЗНИ нет то карточку не вставляем
		IF @ChReqState IS NOT NULL
		BEGIN
			--Если существуют параллельные незавершённые соглы не зни
			IF EXISTS(SELECT *
				 FROM ActivityRelation AS ar JOIN chreq_ChangeRequest AS ccr 
												ON ar.ChildId=ccr.chreq_ChangeRequestId and ar.ParentId = @ActivityId
												JOIN chreq_ReviewThread AS crt 
												ON crt.chreq_ReviewThreadId = ccr.ReviewThreadId AND crt.[SysName]<>N'zni24' and crt.IsDeleted = 0
												JOIN Activity AS ach 
												ON ach.ActivityId = ccr.chreq_ChangeRequestId 
												JOIN ViewActualActivityRecord AS vaar 
												ON vaar.ActivityId = ccr.chreq_ChangeRequestId 
				 WHERE ccr.chreq_ChangeRequestId <> @chreq_ChangeRequestId and vaar.[SysName] NOT IN (N'StateCanceled', N'StateRejected', N'StateAgreed')
				)
			SET @Delta = 1

		 IF @ChReqState = N'StateInitiation' and @CardVersionId = 1
		 BEGIN
		   IF @PrognozBeginDate <= cast(GetDate() as date)
		      SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta, cast(GetDate() as date))
		   ELSE
		      SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta, @PrognozBeginDate)
		 END
		   ELSE
		 BEGIN
			IF @ChReqState = N'StateOnAgreement'
			BEGIN
			   SELECT TOP 1 @PrognozBeginDate = cast(f.LimitDate as date)
			   FROM ChangeRequestReviewer f 
			   WHERE f.ChangeRequestId = @chreq_ChangeRequestId and f.ChangeRequestStateId >=0 and f.IsDeleted = 0 and f.LimitDate IS NOT NULL
			   ORDER BY f.OrderNumberApproval DESC, f.LimitDate DESC
			   IF @PrognozBeginDate <= cast(GetDate() as date)
				  SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))

			END
			ELSE
			  BEGIN
				IF @ChReqState = N'StateInitiation' and @CardVersionId > 1
				   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta, cast(GetDate() as date))
			  END
		 END

		 IF @PrognozBeginDate IS NULL
		 BEGIN
			SET @ErrorMessage = N'Не обнаружена прогнозная дата (7). CardID = '+cast(@CurrentCardId as nvarchar)
			goto on_error;
		 END

		 SET @NewEstimateDate = @PrognozBeginDate

		 EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		 if @rc <> 0
		 BEGIN
			SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
			goto on_error;
		 END
	 END
   END

   ---------------------------------------------Акцепт руководства----------------------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 9
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL
   SET @chreq_ChangeRequestId = NULL
   SET @ChReqState = NULL
   IF EXISTS(SELECT * FROM dbo.Contract2014 c WHERE c.Contract2014Id = @ActivityId and (c.IsApprovedAVE = 1 OR c.IsApprovedCurator = 1))
		  SELECT TOP 1 @NewEstimateDate = cast(AL.[Date] as date) 
		  FROM dbo.[ActivityLog] AL 
		  WHERE  AL.ActivityId = @ActivityId and AL.ElementIdentifier IN (N'IsApprovedCurator',N'IsApprovedAVE') and AL.NewValue IN ('1', 'true')
		  ORDER BY AL.Date DESC
   IF @NewEstimateDate IS NOT NULL
   BEGIN
     -------------------------------------------Факт-----------------------------------------------
     EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
     if @rc <> 0
     BEGIN
	   SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
	   goto on_error;
     END
     -------------------------------------------Факт-----------------------------------------------
   END
	ELSE
   BEGIN
	-----------------------------------------Прогноз--------------------------------------------
    SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 12)
	SET @NewEstimateDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 8)
	IF @PrognozBeginDate IS NOT NULL
	BEGIN
	  IF @NewEstimateDate IS NULL
	     SET @NewEstimateDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 7)
	    IF @PrognozBeginDate < @NewEstimateDate 
		   SET @PrognozBeginDate = @NewEstimateDate 
	END
	  ELSE
	BEGIN
	  IF @NewEstimateDate IS NOT NULL
        SET @PrognozBeginDate = @NewEstimateDate 
      ELSE
		SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 7)
	END
	 
    IF @PrognozBeginDate IS NULL
	BEGIN
	  SET @ErrorMessage = N'Не обнаружена прогнозная дата (8). CardID = '+cast(@CurrentCardId as nvarchar)
      goto on_error;
    END

    IF @PrognozBeginDate <= cast(GetDate() as date)
	   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))

    SET @NewEstimateDate = @PrognozBeginDate

	EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	if @rc <> 0
	BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	END
	-----------------------------------------Прогноз--------------------------------------------
   END

   -------------------------------------Включение в слепок ПГ------------------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 10
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL
   IF EXISTS(SELECT * FROM dbo.Contract2014 c WHERE c.Contract2014Id = @ActivityId and c.IsApprovedPlanPurchase = 1)
		  SELECT TOP 1 @NewEstimateDate = cast(AL.[Date] as date) 
		  FROM dbo.[ActivityLog] AL 
		  WHERE AL.ActivityId = @ActivityId and AL.ElementIdentifier = N'IsApprovedPlanPurchase' and AL.NewValue IN ('1', 'true') and
    		  (
		        AL.UserAccount IN (N'HQ\vyazemskayaes', N'HQ\semenovns2', N'HQ\goloveshkinsv', N'HQ\beznosmv', N'HQ\olnevann') OR
				AL.UserAccount IN (SELECT u.Account
								   FROM   dbo.GroupMember gm JOIN dbo.[Group] g 
																  ON g.GroupId = gm.GroupId AND g.GroupId IN (42)
															 JOIN dbo.[User] u 
															      ON u.UserId = gm.UserId AND u.IsDeleted <> '1'
								  )
			  )
		  ORDER BY AL.Date DESC

   IF @NewEstimateDate IS NOT NULL
   BEGIN
     -------------------------------------------Факт-----------------------------------------------
     EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
     if @rc <> 0
     BEGIN
	   SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
	   goto on_error;
     END
     -------------------------------------------Факт-----------------------------------------------
   END
    ELSE
   BEGIN
     -----------------------------------------Прогноз--------------------------------------------
	 SELECT @PrognozBeginDate = MAX(A.F)
	 FROM 
	 (
		 SELECT [dbo].[tmln_GetLastEstimateDate](@ActivityId, 12) as F
		 UNION
		 SELECT [dbo].[tmln_GetLastEstimateDate](@ActivityId, 8) as F
		 UNION
		 SELECT [dbo].[tmln_GetLastEstimateDate](@ActivityId, 7) as F
		 UNION
		 SELECT [dbo].[tmln_GetLastEstimateDate](@ActivityId, 9) as F
	 ) as A
	 WHERE A.F IS NOT NULL

     IF @PrognozBeginDate IS NULL
	 BEGIN
	   SET @ErrorMessage = N'Не обнаружена прогнозная дата (9). CardID = '+cast(@CurrentCardId as nvarchar)
       goto on_error;
     END

	  IF @PrognozBeginDate <= cast(GetDate() as date)
	   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))

    SET @NewEstimateDate = @PrognozBeginDate

	 EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	 if @rc <> 0
	 BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	 END
	  -----------------------------------------Прогноз--------------------------------------------
   END

    -------------------------------------Выгрузка в ЕАИСТ------------------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 11
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL

   SELECT @NewEstimateDate = le.EntityCreationDate
   FROM PRIZ_Catalog.dbo.LotExport AS le INNER JOIN dbo.Contract2014 c
                                                    ON c.LotEAISTid = le.IdEntityLot
   WHERE c.Contract2014Id = @ActivityId

   IF @NewEstimateDate IS NOT NULL
   BEGIN
     -------------------------------------------Факт-----------------------------------------------
     EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
     if @rc <> 0
     BEGIN
	   SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
	   goto on_error;
     END
     -------------------------------------------Факт-----------------------------------------------
   END
    ELSE
   BEGIN
     -----------------------------------------Прогноз--------------------------------------------
	 SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 10))

     IF @PrognozBeginDate IS NULL
	 BEGIN
	   SET @ErrorMessage = N'Не обнаружена прогнозная дата (10). CardID = '+cast(@CurrentCardId as nvarchar)
       goto on_error;
     END

	 IF @PrognozBeginDate <= cast(GetDate() as date)
	    SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))

    SET @NewEstimateDate = @PrognozBeginDate

	 EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	 if @rc <> 0
	 BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	 END
	 -----------------------------------------Прогноз--------------------------------------------
   END

   CREATE TABLE #GetCurrentForecast (tmln_ForecastTabId int, TabPosition int, TabName nvarchar(256), tmln_ForecastCardTypeId int, tmln_ForecastCardId int,
                                     ForecastCardName nvarchar(256),IsActiveDate bit, DatePosition nvarchar(20),DateTypeId int, 
    								 VersionId int, EstimatedDate date, StateId int, IndicationTypeId int, DeviationInDays int, 
									 IndicationTooltip nvarchar(256), CardURL nvarchar(max),  Comments nvarchar(max) ,CreationDate datetime)

   -------------------АМиПМ	Аппарат Мэра и правительства Москвы	--------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 14
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL

    SET @Value = (SELECT SUM(fv.[Value]) 
				  FROM dbo.FinancialValue fv INNER JOIN dbo.FinancialConfig fc 
	                                                          ON fc.FinancialConfigId = fv.FinancialConfigId
				  WHERE fc.[SysName] = @LastConfigSysName and fc.IsDeleted = 0 and fv.ActivityId = @ActivityId)


   IF (@ContractTypeGroupId IN (1,2) and @PlacingMethodId  <> 7)
      OR
	  (@ContractTypeGroupId NOT IN (1,2) and @PlacingMethodId <> 7 and @Value >= 3000000)
   BEGIN
     SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 11) 

	 IF @PrognozBeginDate IS NOT NULL
	 BEGIN
	   --Определили понедельник
	   SELECT @Delta = DATEPART(dw, @PrognozBeginDate)
	   SET @PrognozBeginDate = DATEADD(day,7-@Delta+1,@PrognozBeginDate)
	   IF NOT EXISTS(SELECT * 
					 FROM dbo.WorkingTimeCalendar_new W 
					 WHERE W.[Date] = @PrognozBeginDate and W.[Date] = W.WorkingTime)
		 --Дата выпала на праздник
		  SELECT TOP 1 @PrognozBeginDate = W.[Date]
	   		  FROM dbo.WorkingTimeCalendar_new W 
				  WHERE W.[Date] > @PrognozBeginDate and W.[Date] = W.WorkingTime
					ORDER BY W.[Date] 
	 END

	 IF @PrognozBeginDate IS NULL
	 BEGIN
	   SET @ErrorMessage = N'Не обнаружена прогнозная дата (11). CardID = '+cast(@CurrentCardId as nvarchar)
       goto on_error;
     END

	 INSERT INTO #GetCurrentForecast EXECUTE @rc = [dbo].[tmln_GetCurrentForecast]  @CardCode  ,@Account

	 if @rc <> 0
	 BEGIN
       SET @ErrorMessage = N'Ошибка вызова [dbo].[tmln_GetCurrentForecast] '
       goto on_error;
	 END

	 SET @Delta = @PrognozID
	 IF (
	     @PrognozBeginDate = cast(GetDate() as date) and 
	     EXISTS(SELECT * FROM #GetCurrentForecast WHERE tmln_ForecastCardId = @CurrentCardId and StateId = 2)
		) OR 
		(@PrognozBeginDate < cast(GetDate() as date))
	 SET @Delta = @FactID

	 SET @NewEstimateDate = @PrognozBeginDate

	 EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @Delta,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	 if @rc <> 0
	 BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	 END

   END
   --------------------------------------------Главконтроль и Тендерный комитет ДКП-----------------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 15
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL

   IF @BaseSingleSupplierId = 9 and @PlacingMethodId = 7
   BEGIN
	 SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](2, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 11))

	 IF @PrognozBeginDate IS NULL
	 BEGIN
	   SET @ErrorMessage = N'Не обнаружена прогнозная дата (12). CardID = '+cast(@CurrentCardId as nvarchar)
       goto on_error;
     END

	 IF NOT EXISTS(SELECT * FROM #GetCurrentForecast)
	 BEGIN
		 INSERT INTO #GetCurrentForecast EXECUTE @rc = [dbo].[tmln_GetCurrentForecast]  @CardCode  ,@Account

		 if @rc <> 0
		 BEGIN
		   SET @ErrorMessage = N'Ошибка вызова [dbo].[tmln_GetCurrentForecast] '
		   goto on_error;
		 END
	 END

	 SET @Delta = @PrognozID
	 IF (
	     @PrognozBeginDate = cast(GetDate() as date) and 
	     EXISTS(SELECT * FROM #GetCurrentForecast WHERE tmln_ForecastCardId = @CurrentCardId and StateId = 2)
		) OR 
		(@PrognozBeginDate < cast(GetDate() as date))
	 SET @Delta = @FactID

	 SET @NewEstimateDate = @PrognozBeginDate

	 EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @Delta,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	 if @rc <> 0
	 BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	 END
   END

   -------------------------------------16--ГАУИ--------------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 16
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL
   SET @IndicationTypeId = NULL

   IF @Value >= 10000000
   BEGIN
	   SELECT TOP 1
			@NewEstimateDate = lnmce_c.CunclusionDate
		FROM PRIZ_Catalog.dbo.LotNMCExamination AS lnmce
			JOIN PRIZ_Catalog.dbo.LotExport le ON le.IdLot = lnmce.IdLot
			JOIN PRIZ.dbo.Contract2014 c ON c.LotEAISTid = le.IdEntityLot
			JOIN PRIZ_Catalog.dbo.LotNMCExamConclusion lnmce_c ON lnmce.Id = lnmce_c.IdLotNMCExamination
		WHERE c.Contract2014Id = @ActivityId and lnmce_c.CunclusionDate is not null
		ORDER BY lnmce_c.CunclusionDate DESC
		
		SELECT TOP 1 @IndicationTypeId = case when s.StatusId = 643 then 1
		                                      else NULL
										 end
		FROM PRIZ_Catalog.dbo.LotNMCExamination AS lnmce
			JOIN PRIZ_Catalog.dbo.LotExport le ON le.IdLot = lnmce.IdLot
			JOIN PRIZ.dbo.Contract2014 c ON c.LotEAISTid = le.IdEntityLot
			LEFT OUTER JOIN PRIZ_Catalog.dbo.[Status] s ON lnmce.IdStatus = s.IdStatus AND s.IdCategory = 100
		WHERE c.Contract2014Id = @ActivityId 
		ORDER BY lnmce.ExpectExaminationEndDate DESC

		IF @NewEstimateDate IS NOT NULL
		BEGIN
		  -------------------------------------------Факт-----------------------------------------------
		  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		  if @rc <> 0
		  BEGIN
		    SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		    goto on_error;
		  END
		  -------------------------------------------Факт-----------------------------------------------
		END
		  ELSE
		BEGIN
		  IF @PlacingMethodId = 7
			SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](case when @Value < 50000000 then 7
			                                                   else 13
														  end, [dbo].[tmln_GetLastEstimateDate](@ActivityId, case when @BaseSingleSupplierId = 9 then 15
														                                                          else 11
																											 end))
		    ELSE
		  BEGIN
		    IF @ContractTypeGroupId IN (1,2) or @Value >= 100000000
			   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](case when @Value < 50000000 then 7
			                                                      else 13
					      								     end, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 14))
			  ELSE
			BEGIN
			   IF @Value >= 10000000 and @Value < 100000000
			   BEGIN
			     --Попытка загрузки по 17 карточке
			     EXEC @rc = dbo.[tmln_RGMRG_Insert] @ActivityId, @ContractTypeGroupId, @Value ,  @Account, @PlacingMethodId , @ErrorMessage OUTPUT
				 if @rc <> 0
				 BEGIN
					SET @ErrorMessage = ISNULL(@ErrorMessage, N'Ошибка 1 при вызове dbo.[tmln_RGMRG_Insert]')
					goto on_error;
				 END

			     SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](case when @Value < 50000000 then 7
			                                                   else 13
				        								       end, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 17))
			   END
			END
		  END

		  IF @PrognozBeginDate IS NULL
		  BEGIN
			SET @ErrorMessage = N'Не обнаружена прогнозная дата (13). CardID = '+cast(@CurrentCardId as nvarchar)
			goto on_error;
		  END

		  IF @PrognozBeginDate <= cast(GetDate() as date)
			 SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))

		  SET @NewEstimateDate = @PrognozBeginDate

		  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		  if @rc <> 0
		  BEGIN
			SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
			goto on_error;
		  END

		END
   END

   ---------------------------------------------------17. РГ МРГ--------------------------------------------------------
   EXEC @rc = dbo.[tmln_RGMRG_Insert] @ActivityId, @ContractTypeGroupId, @Value ,  @Account, @PlacingMethodId , @ErrorMessage OUTPUT
   if @rc <> 0
   BEGIN
	 SET @ErrorMessage = ISNULL(@ErrorMessage, N'Ошибка при вызове dbo.[tmln_RGMRG_Insert]')
	 goto on_error;
   END

   ----------------------------------------------------18. МРГ--------------------------------------------------------------
   EXEC @rc = dbo.[tmln_MRG_Insert] @ActivityId, @ContractTypeGroupId, @Value ,  @Account, @PlacingMethodId , @ErrorMessage OUTPUT
   if @rc <> 0
   BEGIN
	 SET @ErrorMessage = ISNULL(@ErrorMessage, N'Ошибка при вызове dbo.[tmln_MRG_Insert]')
	 goto on_error;
   END
   ---------------------------------------------------19. Мэр--------------------------------------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 19
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL
   SET @IndicationTypeId = NULL

   IF @Value > 500000000
   BEGIN
      SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
	  FROM dbo.[ActivityLog] L 
      WHERE L.ActivityId = @ActivityId and L.ElementIdentifier = N'IsApprovedPlan' and L.NewValue IN ('1', 'true')
      ORDER BY L.[Date] DESC

	  IF @NewEstimateDate IS NOT NULL
	  BEGIN
		-------------------------------------------Факт-----------------------------------------------
		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
		END
		-------------------------------------------Факт-----------------------------------------------
	  END
		ELSE
	  BEGIN
	     --от MRG + 14
	     SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](14, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 18))
		 IF @PrognozBeginDate IS NULL
		  BEGIN
			SET @ErrorMessage = N'Не обнаружена прогнозная дата для Мэра. CardID = '+cast(@CurrentCardId as nvarchar)
			goto on_error;
		  END

		  IF @PrognozBeginDate <= cast(GetDate() as date)
			 SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))

		  SET @NewEstimateDate = @PrognozBeginDate

		  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		  if @rc <> 0
		  BEGIN
			SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
			goto on_error;
		  END
	  END
   END
   -----------------------------------------20 ЗНИ---------------------------------------------------
   SET @PrognozBeginDate = NULL
   SET @CurrentCardId = 20
   SET @NewEstimateDate = NULL
   SET @CardUrl = NULL
   SET @chreq_ChangeRequestId = NULL
   SET @ChReqState = NULL
   SET @DeviationInDays = NULL
   SET @IndicationTypeId = NULL

   SELECT TOP 1 @chreq_ChangeRequestId = ccr.chreq_ChangeRequestId, @CardUrl = N'https://spu.mos.ru' + [dbo].[GetFormUrlByCode](ach.Code), @ChReqState = vaar.[SysName],
	             @CardVersionId = ach.CardVersionId, 
				 @PrognozBeginDate = cast(ach.CreationDate as date)
   FROM ActivityRelation AS ar JOIN chreq_ChangeRequest AS ccr 
	                                ON ar.ChildId=ccr.chreq_ChangeRequestId and ar.ParentId = @ActivityId
	        				   JOIN chreq_ReviewThread AS crt 
								    ON crt.chreq_ReviewThreadId = ccr.ReviewThreadId AND crt.[SysName] IN (N'zni34', N'zniExpert34Negative', N'zniExpert34Positive', N'zni34Otmena') and crt.IsDeleted = 0
							   JOIN Activity AS ach 
								    ON ach.ActivityId = ccr.chreq_ChangeRequestId
							   JOIN ViewActualActivityRecord AS vaar 
									ON vaar.ActivityId = ccr.chreq_ChangeRequestId 
   ORDER BY ach.ActivityId DESC 

   IF @ChReqState = N'StateAgreed'
   BEGIN
	  SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
	  FROM dbo.[ActivityLog] L 
	  WHERE L.ActivityId = @chreq_ChangeRequestId and L.ElementIdentifier='StateId' AND L.NewValue='999'
	  ORDER BY L.[Date] DESC

	  IF @NewEstimateDate IS NULL
	  BEGIN
		SET @ErrorMessage = N'Для карточки ID=20 не обнаружена дата перевода ЗНИ в "согласовано"'
	    goto on_error;
	  END
	  -------------------------------------------Факт-----------------------------------------------
	  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	  if @rc <> 0
	  BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
  	  END
	  -------------------------------------------Факт-----------------------------------------------
	END
	--Если ЗНИ нет то карточку не вставляем
    ELSE IF @ChReqState IS NOT NULL
	BEGIN
		 IF @ChReqState = N'StateInitiation' and @CardVersionId = 1
		 BEGIN
		   IF @PrognozBeginDate <= cast(GetDate() as date)
		      SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](2, cast(GetDate() as date))
		   ELSE
		      SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](2, @PrognozBeginDate)
		 END
		   ELSE
		 BEGIN
			IF @ChReqState = N'StateOnAgreement'
			BEGIN
			   SELECT TOP 1 @PrognozBeginDate = cast(f.LimitDate as date)
			   FROM ChangeRequestReviewer f 
			   WHERE f.ChangeRequestId = @chreq_ChangeRequestId and f.ChangeRequestStateId >=0 and f.IsDeleted = 0 and f.LimitDate IS NOT NULL
			   ORDER BY f.OrderNumberApproval DESC, f.LimitDate DESC
			   IF @PrognozBeginDate <= cast(GetDate() as date)
				  SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))

			END
			ELSE
			  BEGIN
				IF @ChReqState = N'StateInitiation' and @CardVersionId > 1
				   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](2, cast(GetDate() as date))
			  END
		 END

		 IF @PrognozBeginDate IS NULL
		 BEGIN
			SET @ErrorMessage = N'Не обнаружена прогнозная дата (7). CardID = '+cast(@CurrentCardId as nvarchar)
			goto on_error;
		 END

		 SET @NewEstimateDate = @PrognozBeginDate

		 EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		 if @rc <> 0
		 BEGIN
			SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
			goto on_error;
		 END
	END

  -------------------------------------------------21 Справочная информация----------------------------------------------------------
  SET @PrognozBeginDate = NULL
  SET @CurrentCardId = 21
  SET @NewEstimateDate = NULL
  SET @CardUrl = NULL
  SET @chreq_ChangeRequestId = NULL
  SET @ChReqState = NULL
  SET @DeviationInDays = NULL
  SET @IndicationTypeId = NULL

  IF EXISTS(SELECT * 
            FROM dbo.ActivityForecastHistory afh INNER JOIN dbo.tmln_ForecastCard c 
			                                                ON afh.tmln_ForecastCardId = c.tmln_ForecastCardId
			WHERE afh.ActivityId = @ActivityId and c.tmln_ForecastTabId = 3 and c.IsDeleted = 0) AND
	 NOT EXISTS(SELECT * FROM dbo.ActivityForecastHistory A WHERE A.ActivityId = @ActivityId and A.tmln_ForecastCardId = @CurrentCardId)
			INSERT INTO [dbo].[ActivityForecastHistory]([ActivityId] , [VersionId] ,[tmln_ForecastCardId])
			VALUES(@ActivityId, 1, @CurrentCardId)

  --------------------------------------22 Публикация закупки в ПГ в ЕИС-------------------------------------------------------------
  SET @PrognozBeginDate = NULL
  SET @CurrentCardId = 22
  SET @NewEstimateDate = NULL
  SET @CardUrl = NULL
  SET @chreq_ChangeRequestId = NULL
  SET @ChReqState = NULL
  SET @DeviationInDays = NULL
  SET @IndicationTypeId = NULL

  IF @IsApprovedPlan = 1
  BEGIN
	  SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
	  FROM dbo.[ActivityLog] L 
	  WHERE L.ActivityId = @ActivityId and L.ElementIdentifier = N'IsApprovedPlan' and L.NewValue IN ('1', 'true') --and @IsApprovedPlan = 1
	  ORDER BY L.[Date] DESC

	  IF @NewEstimateDate IS NULL
	  BEGIN
	    SET @ErrorMessage = N'При расчёте карточки №22 произошла ошибка. Обратитесь в техническую поддержку!'
		goto on_error;
	  END
  END

  IF @NewEstimateDate IS NOT NULL
  BEGIN
	-------------------------------------------Факт-----------------------------------------------
	EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	if @rc <> 0
	BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	END
	-------------------------------------------Факт-----------------------------------------------
  END
	ELSE
  BEGIN
    -------------------------------------------Прогноз-------------------------------------------
    IF @Value >= 10000000
    SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 16) 
	  ELSE
	BEGIN
	  IF @PlacingMethodId = 7 AND @BaseSingleSupplierId=9
		SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 15) 
      ELSE
	  BEGIN
	    IF  @Value >= 3000000
		BEGIN
		  IF @ContractTypeGroupId IN (1,2)
		    SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 14) 
    	  ELSE
			SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 17) 
		END
		  ELSE
        SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 11) 
	  END
	END

	IF @PrognozBeginDate IS NOT NULL
	BEGIN
	  -----------------------------------Доп обработка даты---------------------------------
	  SET @Delta = DAY(@PrognozBeginDate)
	  IF @Delta >= 15
	  BEGIN
	    SET @PrognozBeginDate = DATEADD(month, 1, @PrognozBeginDate)
	    SET @Delta = DAY(@PrognozBeginDate)
	    SET @PrognozBeginDate = DATEADD(day, 1-@Delta, @PrognozBeginDate)
	  END
	  ELSE 
		SET @PrognozBeginDate = DATEADD(day, 15-@Delta, @PrognozBeginDate)
	  ---------------------------------Проверка на рабочий день-----------------------------
	  IF NOT EXISTS(SELECT * 
					 FROM dbo.WorkingTimeCalendar_new W 
					 WHERE W.[Date] = @PrognozBeginDate and W.[Date] = W.WorkingTime)
		  SELECT TOP 1 @PrognozBeginDate = W.[Date]
	   		  FROM dbo.WorkingTimeCalendar_new W 
				  WHERE W.[Date] > @PrognozBeginDate and W.[Date] = W.WorkingTime
					ORDER BY W.[Date] 
	END

    IF @PrognozBeginDate IS NULL
	BEGIN
	  SET @ErrorMessage = N'Не обнаружена прогнозная дата. CardID = '+cast(@CurrentCardId as nvarchar)
	  goto on_error;
    END
	--Три рабочих дня добавляем
	SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](3, @PrognozBeginDate)

    IF @PrognozBeginDate <= cast(GetDate() as date)
	   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))
	
	IF @PrognozBeginDate IS NULL
	BEGIN
	  SET @ErrorMessage = N'Не обнаружена прогнозная дата. CardID = '+cast(@CurrentCardId as nvarchar)
	  goto on_error;
	END

	SET @NewEstimateDate = @PrognozBeginDate

	EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	if @rc <> 0
	BEGIN
	  SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
	  goto on_error;
	END
    -------------------------------------------Прогноз-------------------------------------------
  END
  -----------------------------23 -- Публикация извещения о закупке в ЕИС-----------------------
  SET @PrognozBeginDate = NULL
  SET @CurrentCardId = 23
  SET @NewEstimateDate = NULL
  SET @CardUrl = NULL
  SET @chreq_ChangeRequestId = NULL
  SET @ChReqState = NULL
  SET @DeviationInDays = NULL
  SET @IndicationTypeId = NULL

  IF @PlacingMethodId <> 7
  BEGIN
    --Определяем и заносим плановую дату
	SELECT @NewEstimateDate = c.LimitDate, @PrognozBeginDate = c.PublishingDate FROM dbo.Contract2014 c WHERE c.Contract2014Id = @ActivityId

	IF @NewEstimateDate IS NULL
	BEGIN
	  SET @ErrorMessage = N'Не обнаружена плановая дата. CardID = '+cast(@CurrentCardId as nvarchar)
	  goto on_error;
	END

	EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PlanID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	if @rc <> 0
	BEGIN
	  SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert] для плана'
	  goto on_error;
	END

	IF @PrognozBeginDate IS NOT NULL
	BEGIN
	  ---Вычисление IndicationTypeId и DeviationInDays
      IF @PrognozBeginDate > @NewEstimateDate  
	  SET @IndicationTypeId = 2
		ELSE
	  SET @IndicationTypeId = 3

	  SET @DeviationInDays = ABS(DATEDIFF(day, @NewEstimateDate, @PrognozBeginDate))

	  SET @NewEstimateDate = @PrognozBeginDate
	  -------------------------------------------Факт-----------------------------------------------
	  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	  if @rc <> 0
	  BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	  END
      -------------------------------------------Факт-----------------------------------------------
	END
	  ELSE
	BEGIN --Прогноз
	   IF @Value > 500000000
	     SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](6, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 19))
	   ELSE
	     BEGIN
		   IF @Value < 3000000
		      SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](6, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 22))
		   ELSE
			 BEGIN
		 	   SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 18)
			   SET @NewEstimateDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 22)

			   IF @PrognozBeginDate < @NewEstimateDate
			      SET @PrognozBeginDate = @NewEstimateDate

    		   IF @Value < 100000000 AND @Value >= 50000000
			   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](10, @PrognozBeginDate)
				  ELSE
    		   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](6, @PrognozBeginDate)
			 END
		 END

	     IF @PrognozBeginDate IS NULL
		 BEGIN
	       SET @ErrorMessage = N'Не обнаружена прогнозная дата. CardID = '+cast(@CurrentCardId as nvarchar)
	       goto on_error;
         END
	
		IF @PrognozBeginDate <= cast(GetDate() as date)
			SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))
	
		IF @PrognozBeginDate IS NULL
		BEGIN
		  SET @ErrorMessage = N'Не обнаружена прогнозная дата. CardID = '+cast(@CurrentCardId as nvarchar)
		  goto on_error;
		END

		SET @NewEstimateDate = @PrognozBeginDate

		SELECT @PrognozBeginDate = c.LimitDate FROM dbo.Contract2014 c WHERE c.Contract2014Id = @ActivityId

		IF @NewEstimateDate > @PrognozBeginDate
		SET @IndicationTypeId = 2
			ELSE
		SET @IndicationTypeId = 3

		SET @DeviationInDays = ABS(DATEDIFF(day, @NewEstimateDate, @PrognozBeginDate))

		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
		  SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		  goto on_error;
		END
	END   --Прогноз

  END
  -------------------------------------------------25 Справочная информация----------------------------------------------------------
  SET @PrognozBeginDate = NULL
  SET @CurrentCardId = 25
  SET @NewEstimateDate = NULL
  SET @CardUrl = NULL
  SET @chreq_ChangeRequestId = NULL
  SET @ChReqState = NULL
  SET @DeviationInDays = NULL

  IF NOT EXISTS(SELECT * FROM dbo.ActivityForecastHistory A WHERE A.ActivityId = @ActivityId and A.tmln_ForecastCardId = @CurrentCardId)
	INSERT INTO [dbo].[ActivityForecastHistory]([ActivityId] , [VersionId] ,[tmln_ForecastCardId])
	      		VALUES(@ActivityId, 1, @CurrentCardId)

 --------------------------------------------26 Окончание приема заявок	название и расчеты по процедуре еще обсуждаются-------------------------------------
  SET @PrognozBeginDate = NULL
  SET @CurrentCardId = 26
  SET @NewEstimateDate = NULL
  SET @CardUrl = NULL
  SET @chreq_ChangeRequestId = NULL
  SET @ChReqState = NULL
  SET @DeviationInDays = NULL
  SET @IndicationTypeId = NULL

  IF @PlacingMethodId IN (2,14)
  BEGIN
	SELECT TOP 1 @PrognozBeginDate = te.RequestEndDate
	FROM Contract2014 AS c INNER JOIN PRIZ_Catalog.dbo.LotExport AS le ON le.IdEntityLot = c.LotEAISTid
						   INNER JOIN PRIZ_Catalog.dbo.TenderExport AS te ON te.IdTender = le.IdTender
	WHERE c.Contract2014Id = @ActivityId

	IF @PrognozBeginDate IS NOT NULL
	BEGIN
	  SET @NewEstimateDate = @PrognozBeginDate
	  -------------------------------------------Факт-----------------------------------------------
	  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	  if @rc <> 0
	  BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	  END
      -------------------------------------------Факт-----------------------------------------------
	END
	  ELSE
	BEGIN --------------------------------------Прогноз---------------------------------------------
		SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](15, [dbo].[tmln_GetLastEstimateDate](@ActivityId, 23))

		IF @PrognozBeginDate IS NULL
		BEGIN
		  SET @ErrorMessage = N'Не обнаружена прогнозная дата. CardID = '+cast(@CurrentCardId as nvarchar)
		  goto on_error;
        END

		IF @PrognozBeginDate <= cast(GetDate() as date)
			SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))

		SET @NewEstimateDate = @PrognozBeginDate

		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
			SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
			goto on_error;
		END
	END  --------------------------------------Прогноз---------------------------------------------

	---------------------------------27	Публикация итогового протокола---------------------------
	SET @PrognozBeginDate = NULL
	SET @CurrentCardId = 27
	SET @NewEstimateDate = NULL
	SET @CardUrl = NULL
	SET @chreq_ChangeRequestId = NULL
	SET @ChReqState = NULL
	SET @DeviationInDays = NULL
	SET @IndicationTypeId = NULL

	SELECT TOP 1 @PrognozBeginDate = c.DatePublicationFinalProtocol
	FROM Contract2014 AS c 
	WHERE c.Contract2014Id = @ActivityId

	IF @PrognozBeginDate IS NOT NULL
	BEGIN
	  SET @NewEstimateDate = @PrognozBeginDate
	  -------------------------------------------Факт-----------------------------------------------
	  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	  if @rc <> 0
	  BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	  END
      -------------------------------------------Факт-----------------------------------------------
	END
	  ELSE
	BEGIN
	  -------------------------------------------Прогноз-----------------------------------------------
	  SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, 26)

	  IF @PrognozBeginDate IS NULL
	  BEGIN
		SET @ErrorMessage = N'Не обнаружена прогнозная дата по 26 карточке. CardID = '+cast(@CurrentCardId as nvarchar)
		goto on_error;
      END

	  IF @PlacingMethodId = 14
	  BEGIN
		 IF @FinanceIMPPlanValue IS NULL
			 SELECT @FinanceIMPPlanValue = SUM(fv.[Value]) 
			 FROM dbo.FinancialValue fv INNER JOIN dbo.FinancialConfig fc 
																  ON fc.FinancialConfigId = fv.FinancialConfigId
			 WHERE fc.[SysName] = N'FinanceForecastPrice' and fc.IsDeleted = 0 and fv.ActivityId = @ActivityId

		IF @FinanceIMPPlanValue > 1000000
			SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](9, @PrognozBeginDate)
		ELSE
			SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](3, @PrognozBeginDate)
	  END
	    ELSE
		SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](7, @PrognozBeginDate)
	  
	  IF @PrognozBeginDate <= cast(GetDate() as date)
		 SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))

	  IF @PrognozBeginDate IS NULL
	  BEGIN
		SET @ErrorMessage = N'Не обнаружена прогнозная дата. CardID = '+cast(@CurrentCardId as nvarchar)
		goto on_error;
      END

      SET @NewEstimateDate = @PrognozBeginDate

	  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	  if @rc <> 0
	  BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	  END
	  -------------------------------------------Прогноз-----------------------------------------------
	END

	-------------------------------------------Справочная карточка------------------------------------
    SET @CurrentCardId = 28

    IF NOT EXISTS(SELECT * FROM dbo.ActivityForecastHistory A WHERE A.ActivityId = @ActivityId and A.tmln_ForecastCardId = @CurrentCardId)
	  INSERT INTO [dbo].[ActivityForecastHistory]([ActivityId] , [VersionId] ,[tmln_ForecastCardId])
	      		VALUES(@ActivityId, 1, @CurrentCardId)
  END

  --29------------------------------------Согласование проекта ГК -------------------------------------
  IF @PlacingMethodId IN (2,14, 7)
  BEGIN
    SET @PrognozBeginDate = NULL
    SET @CurrentCardId = 29
    SET @NewEstimateDate = NULL
    SET @CardUrl = NULL
    SET @chreq_ChangeRequestId = NULL
    SET @ChReqState = NULL
    SET @DeviationInDays = NULL
    SET @IndicationTypeId = NULL

   SELECT TOP 1 @chreq_ChangeRequestId = ccr.chreq_ChangeRequestId, 
               @ChReqState = vaar.[SysName]	             
   FROM ActivityRelation AS ar JOIN chreq_ChangeRequest AS ccr 
	                                ON ar.ChildId=ccr.chreq_ChangeRequestId and ar.ParentId = @ActivityId
	        				   JOIN chreq_ReviewThread AS crt 
								    ON crt.chreq_ReviewThreadId = ccr.ReviewThreadId AND crt.[SysName] IN (N'zni45ProektGk', N'zni45ProektGkDisagreements', N'zniEP34') and crt.IsDeleted = 0
							   JOIN Activity AS ach 
								    ON ach.ActivityId = ccr.chreq_ChangeRequestId
							   JOIN ViewActualActivityRecord AS vaar 
									ON vaar.ActivityId = ccr.chreq_ChangeRequestId 
   ORDER BY ach.ActivityId DESC 

   IF @ChReqState = N'StateAgreed'
   BEGIN
	  SELECT TOP 1 @NewEstimateDate = cast(L.[Date] as date)
	  FROM dbo.[ActivityLog] L 
	  WHERE L.ActivityId = @chreq_ChangeRequestId and L.ElementIdentifier='StateId' AND L.NewValue='999'
	  ORDER BY L.[Date] DESC

	  IF @NewEstimateDate IS NULL
	  BEGIN
		SET @ErrorMessage = N'Для карточки ID='+cast(@CurrentCardId as nvarchar)+' не обнаружена дата перевода в "согласовано"'
	    goto on_error;
	  END
	  -------------------------------------------Факт-----------------------------------------------
	  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	  if @rc <> 0
	  BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
  	  END
	  -------------------------------------------Факт-----------------------------------------------
	END
	  ELSE
	BEGIN
	 -------------------------------------------Прогноз-----------------------------------------------
		SET @chreq_ChangeRequestId = NULL
		SET @ChReqState = NULL
		SET @Delta = 27
		SET @rc = 2

		IF @PlacingMethodId = 7
		BEGIN
		  SET @Delta = 22
		  SET @rc = 1
		END

		SELECT TOP 1 @chreq_ChangeRequestId = ccr.chreq_ChangeRequestId, @CardUrl = N'https://spu.mos.ru' + [dbo].[GetFormUrlByCode](ach.Code), @ChReqState = vaar.[SysName],
					@CardVersionId = ach.CardVersionId, 
					@PrognozBeginDate = cast(ach.CreationDate as date)
		FROM ActivityRelation AS ar JOIN chreq_ChangeRequest AS ccr 
									ON ar.ChildId=ccr.chreq_ChangeRequestId and ar.ParentId = @ActivityId
	        					JOIN chreq_ReviewThread AS crt 
									ON crt.chreq_ReviewThreadId = ccr.ReviewThreadId and crt.IsDeleted = 0
								JOIN Activity AS ach 
									ON ach.ActivityId = ccr.chreq_ChangeRequestId
								JOIN ViewActualActivityRecord AS vaar 
									ON vaar.ActivityId = ccr.chreq_ChangeRequestId 
		WHERE (@PlacingMethodId = 7 and crt.[SysName] = N'zniEP34') OR  
		      (@PlacingMethodId IN (2,14) and crt.[SysName] IN (N'zni45ProektGk', N'zni45ProektGkDisagreements'))
		ORDER BY ach.ActivityId DESC 

		IF @chreq_ChangeRequestId IS NOT NULL
		BEGIN
			IF @ChReqState = N'StateInitiation' AND @CardVersionId = 1
			BEGIN
				IF @PrognozBeginDate <= cast(GetDate() as date)
					SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@rc, cast(GetDate() as date))
				ELSE
				BEGIN
				  SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@rc, @PrognozBeginDate)
    			  IF @PrognozBeginDate <= cast(GetDate() as date)
 					SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))
				END
			END
			ELSE IF @ChReqState = N'StateOnAgreement'
			BEGIN
				SELECT TOP 1 @PrognozBeginDate = cast(f.LimitDate as date)
				FROM ChangeRequestReviewer f 
				WHERE f.ChangeRequestId = @chreq_ChangeRequestId and f.ChangeRequestStateId >=0 and f.IsDeleted = 0 and f.LimitDate IS NOT NULL
				ORDER BY f.OrderNumberApproval DESC, f.LimitDate DESC
    			IF @PrognozBeginDate <= cast(GetDate() as date)
 				   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))
			END
			ELSE IF @ChReqState = N'StateInitiation' AND @CardVersionId > 1
				SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@rc, cast(GetDate() as date))
		END
			ELSE
		BEGIN
			SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](IIF(@Delta = 27, @rc+1, @rc), [dbo].[tmln_GetLastEstimateDate](@ActivityId, @Delta))
			IF @PrognozBeginDate <= cast(GetDate() as date)
			   SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))
		END

        IF @PrognozBeginDate IS NULL
	    BEGIN
		  SET @ErrorMessage = N'Не обнаружена прогнозная дата. CardID = '+cast(@CurrentCardId as nvarchar)
		  goto on_error;
        END

        SET @NewEstimateDate = @PrognozBeginDate

	    EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	    if @rc <> 0
	    BEGIN
		  SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		  goto on_error;
	    END
	 -------------------------------------------Прогноз-----------------------------------------------
	END

	--30---------------------------------------Заключение ГК------------------------------------------
	SET @PrognozBeginDate = NULL
    SET @CurrentCardId = 30
    SET @NewEstimateDate = NULL
    SET @CardUrl = NULL
    SET @chreq_ChangeRequestId = NULL
    SET @ChReqState = NULL
    SET @DeviationInDays = NULL
    SET @IndicationTypeId = NULL

	SELECT @PrognozBeginDate = c.FinishDate
	FROM Contract2014 AS c 
	WHERE c.Contract2014Id = @ActivityId

	IF @PrognozBeginDate IS NOT NULL
	BEGIN
	  SET @NewEstimateDate = @PrognozBeginDate
	  -------------------------------------------Факт-----------------------------------------------
	  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	  if @rc <> 0
	  BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	  END
      -------------------------------------------Факт-----------------------------------------------
	END
	  ELSE
	BEGIN
	  -------------------------------------------Прогноз-----------------------------------------------
	  SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](11, [dbo].[tmln_GetLastEstimateDate](@ActivityId, IIF(@PlacingMethodId = 7, 22, 27)))
      IF @PrognozBeginDate <= cast(GetDate() as date)
		 SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](1, cast(GetDate() as date))

	  IF @PrognozBeginDate IS NULL
      BEGIN
	    SET @ErrorMessage = N'Не обнаружена прогнозная дата. CardID = '+cast(@CurrentCardId as nvarchar)
		goto on_error;
      END

      SET @NewEstimateDate = @PrognozBeginDate

	  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PrognozID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	  if @rc <> 0
	  BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	  END
      -------------------------------------------Прогноз-----------------------------------------------
    END

	-------------------------------------------Справочная карточка------------------------------------
	SET @PrognozBeginDate = NULL
    SET @CurrentCardId = 31
    SET @NewEstimateDate = NULL
    SET @CardUrl = NULL
    SET @chreq_ChangeRequestId = NULL
    SET @ChReqState = NULL
    SET @DeviationInDays = NULL

    IF NOT EXISTS(SELECT * FROM dbo.ActivityForecastHistory A WHERE A.ActivityId = @ActivityId and A.tmln_ForecastCardId = @CurrentCardId)
	  INSERT INTO [dbo].[ActivityForecastHistory]([ActivityId] , [VersionId] ,[tmln_ForecastCardId])
	      		VALUES(@ActivityId, 1, @CurrentCardId)

	-----------------------------------------32 Исполнение ГК-----------------------------------------
	SET @PrognozBeginDate = NULL
    SET @CurrentCardId = 32
    SET @NewEstimateDate = NULL
    SET @CardUrl = N'https://spu.mos.ru' + [dbo].[GetFormUrlByCode](@CardCode)+N'?view=ContractCalendarPlanView'
    SET @chreq_ChangeRequestId = NULL
    SET @ChReqState = NULL
    SET @DeviationInDays = NULL
    SET @IndicationTypeId = NULL
    
	--------------------------Определяем и заносим плановую дату------------------------------
	SELECT @NewEstimateDate = c.ExecutionDate, @PrognozBeginDate = c.ExecutionGKDate, 
	       @Delta = c.DurationContract, @chreq_ChangeRequestId = c.CalendarId 
	FROM dbo.Contract2014 c 
	WHERE c.Contract2014Id = @ActivityId

	IF @NewEstimateDate IS NULL
	BEGIN
	  SET @ErrorMessage = N'Не обнаружена плановая дата. CardID = '+cast(@CurrentCardId as nvarchar)
	  goto on_error;
	END

	EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PlanID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
	if @rc <> 0
	BEGIN
	  SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert] для плана'
	  goto on_error;
	END
	--Сохранили плановую дату
	SET @PlanDate = @NewEstimateDate

	DECLARE @PointTab TABLE (PointId bigint, FactDate date, PlanDate date)

	INSERT INTO @PointTab (PointId, FactDate, PlanDate)
	--Контрольные точки этапов
	SELECT P.PointId, P.FactDate, P.PlanDate
	FROM dbo.ActivityRelation AR INNER JOIN dbo.Point P ON AR.ChildId = P.PointId
	                             INNER JOIN dbo.Stage S ON S.StageId = AR.ParentId
								 INNER JOIN dbo.ActivityRelation AR1
								                        ON AR1.ChildId = Ar.ParentId
	WHERE AR1.ParentId = @ActivityId and P.PointTemplateId=50
	UNION ALL
	--Контрольные точки подэтапов
	SELECT P.PointId, P.FactDate, P.PlanDate
	FROM dbo.ActivityRelation AR 
	                             INNER JOIN dbo.Stage S 
	                                        ON S.StageId = AR.ParentId
                                 INNER JOIN dbo.ActivityRelation ARContract
								                        ON ARContract.ChildId = AR.ParentId
								 INNER JOIN dbo.Stage SS 
								                       ON SS.StageId = AR.ChildId 
								INNER JOIN dbo.ActivityRelation ARP
								                       ON ARP.ParentId = AR.ChildId
								INNER JOIN dbo.Point P
								                       ON P.PointId = ARP.ChildId
	WHERE ARContract.ParentId = @ActivityId and P.PointTemplateId=50

	IF EXISTS(SELECT * FROM @PointTab) AND NOT EXISTS(SELECT * FROM @PointTab WHERE FactDate IS NULL)  
	BEGIN 
	  -------------------------------------------Факт-----------------------------------------------
	  SELECT TOP 1 @NewEstimateDate = FactDate FROM @PointTab ORDER BY FactDate DESC

	  SET @IndicationTypeId = IIF(@NewEstimateDate > @PlanDate, 2,3)
	  SET @DeviationInDays = ABS(DATEDIFF(day, @NewEstimateDate, @PlanDate))
	  
	  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @FactID,  @CurrentCardId, NULL, @IndicationTypeId,  @DeviationInDays
	  if @rc <> 0
	  BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	  END
      -------------------------------------------Факт-----------------------------------------------
	END
	  ELSE
	BEGIN
	  -------------------------------------------Прогноз-----------------------------------------------
	  IF @PrognozBeginDate IS NOT NULL
	  BEGIN
	    SET @NewEstimateDate = @PrognozBeginDate
		SET @PrognozBeginDate = NULL
		--Сохранили плановую дату
	    SET @PlanDate = @NewEstimateDate
	    ----------------------Опять план----------------------
		EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId,  @NewEstimateDate,  @PlanID,  @CurrentCardId, @CardUrl, @IndicationTypeId,  @DeviationInDays
		if @rc <> 0
		BEGIN
		  SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert] для плана'
		  goto on_error;
		END
		-----------------------Прогнозная дата-------------------------
		SELECT TOP 1 @PrognozBeginDate = PlanDate FROM @PointTab WHERE PlanDate IS NOT NULL ORDER BY PlanDate DESC
	  END
	    ELSE
	  BEGIN
  		 IF @chreq_ChangeRequestId IS NULL
		 BEGIN
  		  SET @ErrorMessage = N'Не обнаружена CalendarId для CardID = '+cast(@CurrentCardId as nvarchar)
		  goto on_error;
		 END

		 SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId,30)
		 IF @chreq_ChangeRequestId = 1
			SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](@Delta, @PrognozBeginDate)
 		 ELSE
		    SET @PrognozBeginDate = DATEADD(day, @Delta,@PrognozBeginDate)
	  END

	  IF @PrognozBeginDate IS NULL
      BEGIN
	    SET @ErrorMessage = N'Не обнаружена прогнозная дата. CardID = '+cast(@CurrentCardId as nvarchar)
		goto on_error;
      END

      SET @NewEstimateDate = @PrognozBeginDate

	  SET @IndicationTypeId = IIF(@NewEstimateDate > @PlanDate, 2,3)
	  SET @DeviationInDays = ABS(DATEDIFF(day, @NewEstimateDate, @PlanDate))

	  EXEC @rc = [dbo].[tmln_ActivityForecastHistory_Insert] @ActivityId, @NewEstimateDate,  @PrognozID,  @CurrentCardId, NULL, @IndicationTypeId,  @DeviationInDays
	  if @rc <> 0
	  BEGIN
		SET @ErrorMessage = N'Ошибка при вызове [tmln_ActivityForecastHistory_Insert]'
		goto on_error;
	  END
	  -------------------------------------------Прогноз-----------------------------------------------
	END

  END

on_end:
  return 0
on_error:
  return -1
END

