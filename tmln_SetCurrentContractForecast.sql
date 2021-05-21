USE [PRIZ]
GO
/****** Object:  StoredProcedure [dbo].[tmln_SetCurrentContractForecast]    Script Date: 21.05.2021 11:30:29 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[tmln_SetCurrentContractForecast]
(
  @CardCode nvarchar(100), --код карточки закупки
  @Account nvarchar(255)
)
AS
/****************************************************************************
Автор: Нелюбин
Дата создания: 23.03.2021
Описание: Метод загрузки dbo.[ActivityForecastHistory] по одной закупке.
          Возвращает исключение
	  Второй Update
****************************************************************************/
BEGIN
	SET NOCOUNT ON;

	DECLARE @ErrorMessage nvarchar(1000) ,
	        @rc int = NULL

	EXEC @rc = [dbo].[tmln_SetCurrentContractForecast_Inner] @CardCode,   @Account,  @ErrorMessage OUTPUT

	if @rc <> 0
	BEGIN
	  SET @ErrorMessage = ISNULL(@ErrorMessage, N'Ошибка при вызове [dbo].[tmln_SetCurrentContractForecast_Inner]')
	  goto on_error;
	END

  return 0
on_error:
  raiserror(@ErrorMessage, 16, 1)
  return -1
END

