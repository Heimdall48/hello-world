USE [PRIZ]
GO
/****** Object:  StoredProcedure [dbo].[tmln_ActivityForecastHistory_Insert]    Script Date: 21.05.2021 11:31:10 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[tmln_ActivityForecastHistory_Insert]
(
  @ActivityId bigint,
  @EstimateDate date,
  @DateTypeId int,
  @CurrentCardId int,
  @CardURL nvarchar(max),
  @IndicationTypeId int = NULL,
  @DeviationInDays int = NULL
)
AS
BEGIN
	SET NOCOUNT ON;
	DECLARE @CurrentVersionID int = NULL,
		    @LastEstimateDate date = null,
		    @ErrorMessage nvarchar(1000) ,
			@DatePosition nvarchar(20) = NULL

	BEGIN TRY  

	 SET @DatePosition =case when @DateTypeId = 1 then 'left' 
	                         else dbo.[tmln_GetDatePosition](@ActivityId,@CurrentCardId)
						end

	 SELECT TOP 1 @CurrentVersionID = AFH.VersionId, @LastEstimateDate = AFH.EstimatedDate 
     FROM dbo.ActivityForecastHistory AFH 
	 WHERE AFH.ActivityId = @ActivityId and AFH.tmln_DateTypeId = @DateTypeId and AFH.tmln_ForecastCardId = @CurrentCardId 
	 ORDER BY AFH.VersionId DESC

     IF @CurrentVersionID IS NULL
 	     SET @CurrentVersionID = 1
 	 ELSE
	 BEGIN
	   IF @EstimateDate <> @LastEstimateDate
	     SET @CurrentVersionID += 1
	   ELSE
	     SET @CurrentVersionID = NULL
	 END

	 IF @CurrentVersionID IS NOT NULL
	 BEGIN
		INSERT INTO [dbo].[ActivityForecastHistory] ([ActivityId] ,[CreationDate]  ,[VersionId]  ,[tmln_ForecastCardId]  ,[CardURL]  ,[tmln_DateTypeId]  ,[EstimatedDate]
		     										  ,[DatePosition] ,[IndicationTypeId] ,[DeviationInDays])
		VALUES (@ActivityId, GetDate(), @CurrentVersionID, @CurrentCardId  ,@CardURL  ,@DateTypeId ,@EstimateDate ,@DatePosition ,@IndicationTypeId ,@DeviationInDays)
	 END
	END TRY
    BEGIN CATCH
      SET @ErrorMessage = cast(ERROR_MESSAGE() as nvarchar(1000))
	  goto on_error;
    END CATCH	 

 return 0
on_error:
  raiserror(@ErrorMessage, 16, 1)
  return -1
END
