USE [PRIZ]
GO
/****** Object:  StoredProcedure [dbo].[tmln_RGMRG_Insert]    Script Date: 21.05.2021 11:29:10 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[tmln_RGMRG_Insert]
(
  @ActivityId bigint,
  @ContractTypeGroupId int,
  @Value decimal(32,8),
  @Account nvarchar(255),
  @PlacingMethodId int,
  @ErrorMessage nvarchar(1000) OUTPUT
)
AS
/****************************************************************************
Автор: Нелюбин
Дата создания: 20.04.2021
Описание: Загрузка по RG MRG  - 17 card
****************************************************************************/
BEGIN
   SET NOCOUNT ON;
	
   DECLARE @PrognozBeginDate date = NULL
   DECLARE @CurrentCardId int = 17
   DECLARE @NewEstimateDate date = NULL
   DECLARE @CardUrl nvarchar(max) = NULL
   DECLARE @IndicationTypeId int = NULL
   DECLARE @rc int = 0
   DECLARE @FactID int = 3,
		   @PrognozID int = 2
   DECLARE @DeviationInDays int = NULL
   DECLARE @Delta int = NULL

   SET @ErrorMessage = NULL
   
   IF NOT(
           (@PlacingMethodId <> 7 and @ContractTypeGroupId in (1,2))
		   OR
		   (@ContractTypeGroupId not in (1,2) and @PlacingMethodId <> 7 and @Value >= 3000000 )
         )
      goto on_end;

	SELECT TOP 1 @NewEstimateDate = A.RGMRGMeetingDate, 
	             @IndicationTypeId = case when A.FinalDecision = 2 then 1
				                          else NULL
									 end
	FROM
	(
	SELECT 	mb.RGMRGMeetingDate, mb.FinalDecision
		FROM PRIZ_Catalog.dbo.MrgBid AS mb
			JOIN PRIZ_Catalog.dbo.LotExport le ON le.IdEntityLot = mb.LotId --and le.IdTender is null
			JOIN PRIZ.dbo.Contract2014 c ON c.LotEAISTid = le.IdEntityLot
		WHERE c.Contract2014Id = @ActivityId and mb.Type=1 --and mbo.MrgBidId is null 
			  and mb.[MrgAgendaId] is not NULL and mb.[StatusId] not in (8,17,18) and 
			  mb.RGMRGMeetingDate IS NOT NULL and mb.FinalDecision IS NOT NULL
		UNION ALL
	SELECT 	mb.RGMRGMeetingDate, mb.FinalDecision
		FROM PRIZ_Catalog.dbo.MrgBid AS mb
			JOIN PRIZ_Catalog.dbo.TenderExport te ON te.IdTenderEntity = mb.ProcedureId
			JOIN PRIZ_Catalog.dbo.LotExport le ON le.IdTender = te.IdTender --and le.IdTender is not null
			JOIN PRIZ.dbo.Contract2014 c ON c.LotEAISTid = le.IdEntityLot
		WHERE c.Contract2014Id = @ActivityId and mb.Type=2 --and mbo.MrgBidId is null 
			  and mb.[MrgAgendaId] is not NULL and mb.[StatusId] not in (8,17,18)  
			  and mb.RGMRGMeetingDate IS NOT NULL and mb.FinalDecision IS NOT NULL
	) as A
	ORDER BY A.RGMRGMeetingDate DESC
	
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
		SET @PrognozBeginDate = [dbo].[tmln_GetLastEstimateDate](@ActivityId, case when @ContractTypeGroupId in (1,2) OR @Value >= 100000000 then 16
			                                                                        else 14
																				end)
        IF @PrognozBeginDate IS NOT NULL
		BEGIN
			--Определили четверг
			SELECT @Delta = DATEPART(dw, @PrognozBeginDate)

			--Четверг
			SET @rc = 4
			SET @PrognozBeginDate = DATEADD(day,case when @Delta < @rc then @rc-@Delta
			                                         else 7-@Delta+@rc
												end, @PrognozBeginDate)
			--Проверка на праздник
			IF NOT EXISTS(SELECT * 
							FROM dbo.WorkingTimeCalendar_new W 
							WHERE W.[Date] = @PrognozBeginDate and W.[Date] = W.WorkingTime)
			--Если праздник то берём следующий первый рабочий
				SELECT TOP 1 @PrognozBeginDate = W.[Date]
	   				FROM dbo.WorkingTimeCalendar_new W 
						WHERE W.[Date] > @PrognozBeginDate and W.[Date] = W.WorkingTime
						ORDER BY W.[Date] 
		END

    	IF @PrognozBeginDate IS NULL
	    BEGIN
	        SET @ErrorMessage = N'Не обнаружена прогнозная дата (14). CardID = '+cast(@CurrentCardId as nvarchar)
            goto on_error;
        END

   		SET @PrognozBeginDate = [dbo].[ADDWORKDAYS_1](case when (@ContractTypeGroupId in (1,2) OR @Value >= 100000000) then 7
			                                                else 2
														end, @PrognozBeginDate)

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

on_end:
  return 0
on_error:
  return -1
END

