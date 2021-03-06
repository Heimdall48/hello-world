USE [PRIZ]
GO
/****** Object:  StoredProcedure [dbo].[tmln_GetCurrentForecast]    Script Date: 21.05.2021 11:28:33 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[tmln_GetCurrentForecast]
(
  	 @CardCode nvarchar(100), --код карточки закупки
	 @Account nvarchar(255)
)
AS
/****************************************************************************
Автор: Нелюбин
Дата создания: 26.02.2021
Описание:  метод, возвращающий актуальные вкладки трекера «TimeLine» с необходимой индикацией и прогнозные данные по карточкам на этих вкладках
Изменена: 24/03/2020 сортировка
****************************************************************************/
BEGIN
	SET NOCOUNT ON;

    DECLARE @ActivityId bigint = NULL
    DECLARE @ErrorMessage nvarchar(1000), 
	        @ResponsibleName nvarchar(256) = NULL, 
			@DeputyCuratorName nvarchar(256), 
			@ProductResponsibleName nvarchar(4000)='',
			@LotRegNumber nvarchar(256) = NULL,
			@EaistCompetitionNumber nvarchar(256) = NULL,
			@ProcEAISTState nvarchar(256) = NULL,
			@ContragentName nvarchar(256) = NULL,
			@DopSogl nvarchar(4000) = '',
			@PretWork nvarchar(4000) = '',
			@ContractTypeId int = NULL,
			@PlacingMethodId int = NULL,
			@Br nvarchar(50) = '</BR>';

    BEGIN TRY  
		select @ActivityId = a.ActivityId, @LotRegNumber = ISNULL(c.LotNumber,''),
		       @EaistCompetitionNumber = ISNULL(c.EaistCompetitionNumber,''), @ContragentName = ISNULL(B.Name,'') ,
			   @ContractTypeId = c.ContractTypeId, @PlacingMethodId = c.PlacingMethodId
		from Activity a INNER JOIN dbo.Contract2014 c
		                           ON c.Contract2014Id = a.ActivityId
      				   LEFT OUTER JOIN 
	                          (SELECT AR.ChildId as Contract2014Id, A.Name
	                           FROM dbo.ActivityRelation AR INNER JOIN dbo.Contractor Cn
																ON cn.ContractorId = AR.ParentId
														    INNER JOIN dbo.Activity A --для названия контрагента
														        ON A.ActivityId = cn.ContractorId
						 	  ) as B
								 ON c.Contract2014Id = B.Contract2014Id
		where a.Code = @CardCode

		if @ActivityId IS NULL
		BEGIN
		  SET @ErrorMessage = N'Карточка закупки с кодом "'+@CardCode+'" не найдена!'
		  raiserror(@ErrorMessage, 16, 1)
		  return -1
		END

		CREATE TABLE #OutputTable ([ActivityForecastHistoryId] bigint PRIMARY KEY IDENTITY(1,1), 
		                           tmln_ForecastTabId int ,TabPosition int ,TabName nvarchar(256), StateId int, VersionId int, 
		                           CardURL nvarchar(max), CreationDate datetime, tmln_ForecastCardTypeId int,
		                           tmln_ForecastCardId int, ForecastCardName nvarchar(256), DeviationInDays int, DateTypeId int, 
								   EstimatedDate date, DatePosition nvarchar(20),  Comments nvarchar(max), IsActiveDate bit, 
								   IndicationTypeId int, IndicationTooltip nvarchar(256))

		IF @ContractTypeId IN (34,41,42,43,44,45,46) OR @PlacingMethodId IN (8,9,10,16,17)
			goto on_end;
		-------------------------------------Пользователи-------------------------------------------
		SET @ResponsibleName = ISNULL((select TOP 1 u.ShortName 
									  from ActivityRole arl join dbo.Role rl 
										 on rl.RoleId = arl.RoleId and rl.Identifier = 'Responsible'
																   and arl.ActivityId = @ActivityId
															join dbo.[User] u on u.UserId = arl.UserId),'')

		SET @DeputyCuratorName = ISNULL((select TOP 1 u.ShortName
										 from ActivityRole arl join dbo.Role rl 
												on rl.RoleId = arl.RoleId and rl.Identifier = 'DeputyCurator'
													and arl.ActivityId = @ActivityId
																join dbo.[User] u on u.UserId = arl.UserId),'') 

		select @ProductResponsibleName += u.ShortName + ';' 
		from ActivityRole arl join dbo.Role rl 
		                               on rl.RoleId = arl.RoleId and rl.Identifier = 'ProductResponsible'
					                      and arl.ActivityId = @ActivityId
							  join dbo.[User] u on u.UserId = arl.UserId
  	    order by u.FullName

		SET @ProductResponsibleName = ISNULL(@ProductResponsibleName, '')
        -------------------------------------Состояние процедуры-------------------------------------------
		SET @ProcEAISTState = ISNULL((SELECT TOP 1 s.NameStatus
								  	  FROM Contract2014 AS c 
											INNER JOIN PRIZ_Catalog.dbo.LotExport AS le ON le.IdEntityLot=c.LotEAISTid
											INNER JOIN PRIZ_Catalog.dbo.TenderExport AS te ON te.IdTender = le.IdTender
											INNER JOIN PRIZ_Catalog.dbo.[Status] AS s ON s.IdStatus=te.IdTenderStatus AND s.IdCategory = 16
									  WHERE c.Contract2014Id = @ActivityId),'') 
		-----------------------------------Доп. соглашения контракта---------------------------------------
		SELECT  @DopSogl += ISNULL('ДС №'+cast(EP.Number as nvarchar(256))+' от '+cast(EP.FinishDate as nvarchar(256))+';','')
		FROM dbo.Contract2014 c INNER JOIN dbo.ActivityRelation ar 
		                                                        ON ar.ParentId = c.Contract2014Id 
		                        INNER JOIN dbo.ExtraPact EP 
								                                ON EP.ExtraPactId = ar.ChildId
								INNER JOIN ViewActualActivityRecord AS vaar 
								                                ON vaar.ActivityId = EP.ExtraPactId
		WHERE c.Contract2014Id = @ActivityId and vaar.[SysName] = 'StateExtraPactIncorporated'
		IF ISNULL(TRIM(@DopSogl), '')<>''
			SET @DopSogl = ISNULL(@Br + @DopSogl, '')
		---------------------------------Претензионные работы-----------------------------------------------
		SELECT @PretWork += ISNULL('ПР № '+ cast(Ctrl.[Value] as nvarchar(256)) +' от '+cast(Ctrl1.[Value] as nvarchar(256))+';','')
		FROM dbo.Contract2014 c INNER JOIN dbo.ActivityRelation ar 
		                                                        ON ar.ParentId = c.Contract2014Id 
		                        INNER JOIN dbo.ptw_PretensionWork EP 
								                                ON EP.ptw_PretensionWorkId = ar.ChildId
								INNER JOIN ViewActualActivityRecord AS vaar 
								                                ON vaar.ActivityId = EP.ptw_PretensionWorkId
								INNER JOIN dbo.Activity A 
								                         ON A.ActivityId = EP.ptw_PretensionWorkId
								INNER JOIN [dbo].[ver_Controls] Ctrl
								                   ON Ctrl.ActivityId = EP.ptw_PretensionWorkId and
												      Ctrl.VersionId = A.CardVersionId
   							    INNER JOIN dbo.Field F1
								                  ON Ctrl.FieldId = F1.FieldId and
												     F1.FieldName = 'NumberOutgoingClaimLetter'
								INNER JOIN [dbo].[ver_Controls] Ctrl1
								                   ON Ctrl1.ActivityId = EP.ptw_PretensionWorkId and
												      Ctrl1.VersionId = A.CardVersionId
								INNER JOIN dbo.Field F2
								                  ON Ctrl1.FieldId = F2.FieldId and
												     F2.FieldName = 'DateOutgoingClaimLetter'
		WHERE c.Contract2014Id = @ActivityId and vaar.[SysName] <> 'StateBasket'

		IF ISNULL(TRIM(@PretWork), '')<>''
			SET @PretWork = ISNULL(@Br+@PretWork,'')
		-------------------------------------------------------------------------------------------------------
		--По каждой карточке и типу выводятся данные по максимальной версии
		;WITH MaxDataVersion (ActivityForecastHistoryId, CardURL, CreationDate, DatePosition, DeviationInDays, 
  		                      EstimatedDate, IndicationTypeId, tmln_DateTypeId, tmln_ForecastCardId, VersionId)
		AS
		(
		  SELECT AF.ActivityForecastHistoryId, AF.CardURL, AF.CreationDate, AF.DatePosition, AF.DeviationInDays, 
  		        AF.EstimatedDate, AF.IndicationTypeId, AF.tmln_DateTypeId, AF.tmln_ForecastCardId, AF.VersionId
		  FROM dbo.[ActivityForecastHistory] AF INNER JOIN 
		       (
			     SELECT A.tmln_ForecastCardId, A.[tmln_DateTypeId], MAX(A.[VersionId]) as MaxVersionId
		         FROM dbo.[ActivityForecastHistory] A LEFT OUTER JOIN dbo.[tmln_DateType] D
				                                                 ON D.tmln_DateTypeId = A.tmln_DateTypeId
													  INNER JOIN dbo.[tmln_ForecastCard] Cr
													             ON Cr.tmln_ForecastCardId = A.tmln_ForecastCardId and
																    Cr.IsDeleted = 0
		         WHERE A.ActivityId = @ActivityId and ISNULL(D.IsDeleted,0) = 0
		         GROUP BY A.tmln_ForecastCardId, A.[tmln_DateTypeId]
			   ) as V
			     ON AF.tmln_ForecastCardId = V.tmln_ForecastCardId and
				    ISNULL(AF.tmln_DateTypeId,0) = ISNULL(V.tmln_DateTypeId,0) and
				    AF.VersionId = V.MaxVersionId
		  WHERE AF.ActivityId = @ActivityId
		)
		
		INSERT INTO #OutputTable (tmln_ForecastTabId, TabPosition, VersionId, CardURL, CreationDate, tmln_ForecastCardTypeId, tmln_ForecastCardId, ForecastCardName, StateId,
								  DeviationInDays, DateTypeId, EstimatedDate, DatePosition, IsActiveDate, IndicationTypeId, IndicationTooltip, Comments
		                         )
		--Основной запрос
		SELECT Tab.[tmln_ForecastTabId] , Tab.TabPosition, A.VersionId, A.CardURL, A.CreationDate, A.tmln_ForecastCardTypeId,
		       A.tmln_ForecastCardId, A.ForecastCardName, A.ForecastCardStateId, A.DeviationInDays, A.DateTypeId, A.EstimatedDate, A.DatePosition,
			   case when A.ForecastCardStateId IN (2,31,32) OR A.DateTypeId = 1 then 1
			        when A.tmln_ForecastCardTypeId = 2 then NULL
			        else 0
			   end as IsActiveDate, A.IndicationTypeId, 
			   case when A.IndicationTypeId = 1 then 'В согласовании вынесены замечания, которые необходимо устранить!'
			        when A.IndicationTypeId = 2 then 'Превышены нормативные сроки окончания процедуры!'
					when A.IndicationTypeId = 3 then 'Указанное количество дней имеется в запасе до завершения процедуры по нормативным срокам'
			   end as CardIndicationTooltip,
			   case when A.tmln_ForecastCardId = 5 then 
			        case when NOT EXISTS(SELECT * 
										 FROM FinancialValue AS fv JOIN FinancialConfig AS fc 
										                                ON fc.FinancialConfigId = fv.FinancialConfigId AND 
																		   fc.[SysName]='FinanceIMPPlan' AND fv.ActivityId = @ActivityId) and
							  NOT EXISTS(SELECT * 
										 FROM FinancialValue AS fv JOIN FinancialConfig AS fc 
										                                ON fc.FinancialConfigId = fv.FinancialConfigId AND 
																		   fc.[SysName]='FinanceForecastPrice' AND fv.ActivityId = @ActivityId) 
						 then N'Для расчета прогноза публикации и исполнения закупки введите значение финансового показателя "НМЦ контракта - план"  или "Прогнозная цена"!'
						 else IIF(ISNULL(TRIM(@DeputyCuratorName),'') <> '' or ISNULL(TRIM(@ResponsibleName),'')<>'' or ISNULL(TRIM(@ProductResponsibleName),'') <> '', N'Куратор закупки - '+@DeputyCuratorName+';'+@Br+'Ответственный за закупку - '+@ResponsibleName+';'+@Br+'Руководитель продукта - '+@ProductResponsibleName, NULL)
                    end 
			        when A.tmln_ForecastCardId = 21 and ISNULL(TRIM(@LotRegNumber),'') <> '' then N'Реестровый номер лота в ЕАИСТ - '+@LotRegNumber
					when A.tmln_ForecastCardId = 25 and ISNULL(TRIM(@EaistCompetitionNumber),'')<>'' then N'Реестровый номер закупки в ЕИС - '+@EaistCompetitionNumber
					when A.tmln_ForecastCardId = 28 and ISNULL(TRIM(@ProcEAISTState),'')<>'' then N'Состояние процедуры в ЕАИСТ - '+@ProcEAISTState
					when A.tmln_ForecastCardId = 31 and (ISNULL(TRIM(@ContragentName),'')<>'' OR ISNULL(TRIM(@DopSogl),'')<>'' OR ISNULL(TRIM(@PretWork),'')<>'') then N'Контрагент - '+@ContragentName+@DopSogl + @PretWork
					--when A.tmln_ForecastCardId = 33 then @DopSogl + @PretWork
			   end as Comments
		FROM 
		    [dbo].[tmln_ForecastTab] Tab 
			OUTER APPLY (SELECT MAX(S.TabPosition) as TabPosition
						 FROM dbo.tmln_ForecastTab S 
        				 WHERE S.IsDeleted = 0 and S.TabPosition < Tab.TabPosition ) as MaxTabPosition
			CROSS APPLY 
			(SELECT Cart.tmln_ForecastCardId, Cart.[Name] as ForecastCardName , Cart.tmln_ForecastCardTypeId,
					MDV.CardURL, MDV.tmln_DateTypeId as DateTypeId, MDV.EstimatedDate, MDV.DatePosition, MDV.DeviationInDays, 
					MDV.CreationDate, MDV.VersionId, MDV.IndicationTypeId,
			 --Расчёт ForecastCardStateId
			 case when Cart.tmln_ForecastCardTypeId = 2 or MDV.tmln_DateTypeId = 1 then NULL
					   --Для факта смотрим поле IndicationTypeId 
			      when MDV.tmln_DateTypeId = 3 and ISNULL(MDV.IndicationTypeId,0) NOT IN (1,2) then 31
			      when MDV.tmln_DateTypeId = 3 and ISNULL(MDV.IndicationTypeId,0) IN (1,2) then 32
				  --Для прогноза
				  when MDV.tmln_DateTypeId = 2 and 
					   --Есть расчётные карточки на предыдущей закладке
					 (
					 (EXISTS(SELECT * 
							  FROM  dbo.[tmln_ForecastCard] JJ INNER JOIN dbo.tmln_ForecastTab TT
							                                              ON TT.tmln_ForecastTabId = JJ.tmln_ForecastTabId
															   INNER JOIN MaxDataVersion J
															              ON JJ.tmln_ForecastCardId = J.tmln_ForecastCardId
							  WHERE TT.TabPosition = MaxTabPosition.TabPosition	and JJ.IsDeleted = 0 and JJ.tmln_ForecastCardTypeId = 1)
					   AND
					   --и у них всех есть факты
					   NOT EXISTS(SELECT * 
								  FROM  dbo.[tmln_ForecastCard] JJ INNER JOIN MaxDataVersion MDV
															              ON JJ.tmln_ForecastCardId = MDV.tmln_ForecastCardId
                                                                   INNER JOIN dbo.tmln_ForecastTab TT
							                                              ON TT.tmln_ForecastTabId = JJ.tmln_ForecastTabId
																   LEFT OUTER JOIN MaxDataVersion J
							                                                   ON JJ.tmln_ForecastCardId = J.tmln_ForecastCardId and
																			      J.tmln_DateTypeId = 3
								  WHERE TT.TabPosition = MaxTabPosition.TabPosition and JJ.IsDeleted = 0 and 
								        JJ.tmln_ForecastCardTypeId = 1 and J.ActivityForecastHistoryId IS NULL
        	   			         ) 
					 ) OR MaxTabPosition.TabPosition IS NULL)
					 AND
					    --Минимальная дата на закладке среди прогнозных карточек, но прогнозные могут и не выводиться если есть фактические, поэтому последние надо отсеять
					    MDV.EstimatedDate = (SELECT MIN(M1.EstimatedDate) 
					                          FROM MaxDataVersion M1 INNER JOIN dbo.[tmln_ForecastCard] FC1 
											                                         ON M1.tmln_ForecastCardId = FC1.tmln_ForecastCardId
																	 LEFT OUTER JOIN MaxDataVersion M2
																	                 ON M2.tmln_ForecastCardId = M1.tmln_ForecastCardId and 
																					    M2.tmln_DateTypeId = 3
											  WHERE FC1.tmln_ForecastTabId = Tab.tmln_ForecastTabId and M1.tmln_DateTypeId = 2 and  
											        FC1.tmln_ForecastCardTypeId = 1 and M2.ActivityForecastHistoryId IS NULL
											 ) then 2
                    else 1
             end as ForecastCardStateId
			 FROM [dbo].[tmln_ForecastCard] Cart INNER JOIN MaxDataVersion MDV
			                                              ON MDV.tmln_ForecastCardId = Cart.tmln_ForecastCardId
												 --Для каждой карточки ищем соспоставление фактической, чтобы потом отсеять
												 LEFT OUTER JOIN MaxDataVersion MDVV
												          ON MDV.tmln_ForecastCardId = MDVV.tmln_ForecastCardId and
														     MDVV.tmln_DateTypeId = 3
			 WHERE Cart.IsDeleted = 0 and Cart.tmln_ForecastTabId = Tab.tmln_ForecastTabId and
			       (
			       --1. план и справочную карточку выводим всегда и последнюю версию
			       (MDV.tmln_DateTypeId = 1) or (Cart.tmln_ForecastCardTypeId = 2) OR
				    --2. если факт то выводим факт
				   (MDV.tmln_DateTypeId = 3) OR
				   --3. Прогноз выводим только если нет факта
				   (MDV.tmln_DateTypeId = 2 and MDVV.ActivityForecastHistoryId IS NULL)
   				   )
			) as A
		WHERE Tab.[IsDeleted] = 0
		
		--По закладкам
		INSERT INTO #OutputTable ( tmln_ForecastTabId, TabPosition ,TabName, StateId, IndicationTypeId, DeviationInDays)
		SELECT Tab.[tmln_ForecastTabId], Tab.TabPosition, Tab.Name,
		       case      --если на вкладке нет данных
			        when NOT EXISTS(SELECT * FROM #OutputTable T WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId) then 4
					     -- на вкладке есть расчётные карточки и все они DateType = 3
			        when EXISTS(SELECT * FROM #OutputTable T WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId and T.tmln_ForecastCardTypeId = 1) AND 
					     NOT EXISTS(SELECT * FROM #OutputTable T WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId and T.tmln_ForecastCardTypeId = 1 and T.DateTypeId NOT IN (1,3) /*<> 3*/ ) then 3  --12.04.2021 Залина: внесла небольшую правку - плановую дату учитывать не нужно
					    --если на вкладке есть хоть одна карточка tmln_ForecastCardId с состоянием ForecastCardState=2 
				    when EXISTS(SELECT * FROM #OutputTable T WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId and ISNULL(T.StateId,0) = 2 ) OR
						--или на вкладке есть единственная карточка tmln_ForecastCardId=5
						 (
						  EXISTS(SELECT * FROM #OutputTable T WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId and T.tmln_ForecastCardId = 5) AND
						  NOT EXISTS(SELECT * FROM #OutputTable T WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId and T.tmln_ForecastCardId <> 5)
						  ) then 2
						-- если на вкладке нет карточек с ForecastCardState=2 (current) 
                    when NOT EXISTS(SELECT * FROM #OutputTable T WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId and ISNULL(T.StateId,0) = 2 ) AND 
					    --Существует хотя бы одна расчётная карточка DateTypeId != 3
						 EXISTS(SELECT * FROM #OutputTable T WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId and T.DateTypeId <> 3 and T.tmln_ForecastCardTypeId = 1) then 1
			   end as ForecastTabStateId,
			   case when EXISTS(SELECT * FROM #OutputTable T WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId and T.IndicationTypeId = 1 ) then 1
				    when EXISTS(SELECT * 
					            FROM #OutputTable T 
								WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId and T.tmln_ForecastCardId IN (23,32) and T.IndicationTypeId = 2 ) then 2
					when EXISTS(SELECT * 
					            FROM #OutputTable T 
								WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId and T.tmln_ForecastCardId IN (23,32) and T.IndicationTypeId = 3 ) then 3
			   end as TabIndicationTypeId,
			   (SELECT TOP 1 T.DeviationInDays FROM #OutputTable T WHERE T.tmln_ForecastTabId = Tab.tmln_ForecastTabId and T.tmln_ForecastCardId IN (23,32) and T.DateTypeId IN (2,3)) as DeviationInDays
		FROM [dbo].[tmln_ForecastTab] Tab
		WHERE Tab.[IsDeleted] = 0

    END TRY
    BEGIN CATCH
      SET @ErrorMessage = cast(ERROR_MESSAGE() as nvarchar(1000))
	  raiserror(@ErrorMessage, 16, 1)
      return -1
    END CATCH

on_end:

    SELECT  tmln_ForecastTabId, TabPosition, TabName, tmln_ForecastCardTypeId , tmln_ForecastCardId ,ForecastCardName ,IsActiveDate , DatePosition ,DateTypeId , 
	    	VersionId, EstimatedDate , StateId , IndicationTypeId , DeviationInDays , 
			case when tmln_ForecastCardId IS NOT NULL then IndicationTooltip
			     else case when IndicationTypeId = 1 then 'В согласованиях вынесены замечания, которые необходимо устранить!'
				           when IndicationTypeId = 2 then 'Превышены нормативные сроки окончания процедуры на вкладке!'
						   when IndicationTypeId = 3 then 'Указанное количество дней имеется в запасе до завершения процедуры по нормативным срокам'
					  end
			end as IndicationTooltip, CardURL ,  Comments ,CreationDate     
	FROM #OutputTable 
	--Не выводим справочные карточки, если там нет комментария
	WHERE ISNULL(tmln_ForecastCardTypeId, 1) = 1 OR (tmln_ForecastCardTypeId = 2 AND ISNULL(TRIM(Comments),'') <> '')
	ORDER BY TabPosition, tmln_ForecastCardTypeId, /*DateTypeId,*/ EstimatedDate

END