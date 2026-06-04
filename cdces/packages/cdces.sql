CREATE OR REPLACE PACKAGE CDCes
   CREATE TYPE cdces.part_details AS (
         agrid numeric(12,3),
         part numeric(4,0),
         pdbeg date,
         pdend date,
         ppi numeric(20,14),
         ppfa numeric(20,14),
         ppfi numeric(20,14),
         pmsum numeric(16,2),
         pmi numeric(16,2),
         pmo numeric(16,2),
         pmoi numeric(16,2),
         pmfa numeric(16,2),
         pmfi numeric(16,2),
         pmi2 numeric(16,2),
         pmoi2 numeric(16,2),
         pmc numeric(16,2),
         pnndo numeric(4,0),
         pnndoi numeric(4,0),
         ppio numeric(20,14),
         pnndoio numeric(4,0),
         pisprol bpchar(1),
         pniclc numeric(16,2),
         ppfi2 numeric(20,14)
   )


CREATE FUNCTION __init__()
   RETURNS void
AS
$init$
DECLARE
 
c_Const_Prefix  CONSTANT VARCHAR := ML2.GetText ('cdces.c_Const_Prefix', 'CD Учет приобретения прав требования'); 
c_Error_Code    CONSTANT VARCHAR := '50200'; 
cVersion        CONSTANT VARCHAR := ' $Id: cdces.sql 65189 2024-11-02 11:38:59Z ant $';
cPkg_Name       CONSTANT VARCHAR := 'CDCes';

-- Lora
isCDE           VARCHAR(10);  -- Флаг для ядра, показывает что удаление проводки инициировано кредитным модулем
isDBMS          BOOLEAN          := true;
ci_SUCCESS      constant integer := 0; -- успешное завершение
ci_OTHER_ERROR  constant integer := 8192;  -- прочая ошибка (неизвестной природы)

ActivMode       char(1) := 'R'; -- локальный флаг формирования действий "реально/декларативно"

BEGIN
   RAISE DEBUG 'Package "%" - % - initialized', cPkg_Name, cVersion;
END;
$init$


/* */
CREATE PROCEDURE BA2Cus2BA2 (  
   IN ba2num numeric, 
   IN cusnum numeric, 
  OUT newba2 numeric, 
  OUT errmsg varchar
)
AS
$procedure$
   #package
DECLARE 
  NewBA1 NUMERIC;
  GStr   VARCHAR;
BEGIN

   raise debug 'BA2Cus2BA2 started with CusNum = % and with old BA2 = %', $2::varchar, $1::varchar; 

   CALL cdces.CusCG2BA1( CusNum, NewBA1, ErrMsg, GStr);

   IF NewBA1 IS NOT NULL THEN 
      IF SUBSTR(GStr,0,2) = '11' THEN
         $3 :=
            CASE $1
               WHEN 47801 THEN NewBA1*100+11
               WHEN 47802 THEN NewBA1*100+11
               WHEN 47804 THEN NewBA1*100+15
               WHEN 47805 THEN NewBA1*100+23
               WHEN 47806 THEN NewBA1*100+24
            END;
      ELSIF SUBSTR(GStr,0,2) = '12' THEN
         $3 :=
            CASE $1
               WHEN 47801 THEN NewBA1*100+11
               WHEN 47802 THEN NewBA1*100+11
               WHEN 47804 THEN NewBA1*100+15
               WHEN 47805 THEN NewBA1*100+13
               WHEN 47806 THEN NewBA1*100+14
            END;
      ELSE
         $3 :=
            CASE $1
               WHEN 47801 THEN NewBA1*100+11
               WHEN 47802 THEN NewBA1*100+11
               WHEN 47804 THEN NewBA1*100+15
               WHEN 47805 THEN NewBA1*100+16
               WHEN 47806 THEN NewBA1*100+17
            END;
      END IF;
   END IF;

   IF $3 IS NULL THEN
      $3 :=0;
      ErrMsg := 'Не найден новый БС2 для настроек групп из кат. 15,7,1,8 у клиента '|| $2::varchar ||' и БС2 ' ||$1::varchar;
   END IF;

END;
$procedure$


/* Расчет сумм cdi для сверки сумм процентов */
CREATE PROCEDURE calc_CDIsum( 
   IN agrId numeric
)
AS
$procedure$
   #package
declare 
   
   CalcSum  numeric;
   Err      numeric;
   curDate  DATE;
   fdate    DATE;
   cda2isum numeric;

   Get_Imps cursor( p_agrId numeric )
   for
      SELECT * FROM xxi.cd_imps WHERE CCDIMPTYPE='PC' and NCDIAGRID=p_agrId FOR UPDATE;

   Get_CDA CURSOR 
   for 
      SELECT * FROM xxi."CDA" left join xxi.CDA2 on ncdaAGRID = $1 and ncda2AGRID = ncdaAGRID;

   CDA_Terms record;

BEGIN

   select CD.get_LSdate() into curDate;

   OPEN Get_CDA; 
      FETCH Get_CDA INTO CDA_Terms; 
         CLOSE Get_CDA;

   IF CDA_Terms.icdastatus = 2 THEN 
      call CDINTEREST.Recalc_Interest( $1, 'R', TRUE, FALSE ); 
   END IF;
   
   IF CDA_Terms.icdastatus IN (0,1) THEN
      call CDInterest.Recalc_Interest( $1, 'T', TRUE, FALSE );
   END IF;

   FOR Cur_Imps IN Get_Imps($1) 
   LOOP
      BEGIN
         -- CalcSum:=Get_SumCDI(Cur_Imps.ncdiAgrid,Cur_Imps.dcdidate);
         SELECT SUM(mcditotal) INTO CalcSum FROM v_cdi WHERE ncdiagrid = Cur_Imps.ncdiAgrid and dcdito=Cur_Imps.dcdidate;

         UPDATE xxi.cd_imps 
            SET
                mcdisumxxi = calcSum,
                mcdisumcrt = null,
                icdistatus = 1
          WHERE 
                CURRENT OF Get_Imps;

      EXCEPTION 
         WHEN NO_DATA_FOUND THEN
              Err:=1;
          UPDATE xxi.cd_imps 
             SET
                 MCDISUMXXI=null,
                 MCDISUMCRT=null,
                 ICDISTATUS=0
          WHERE
                CURRENT OF Get_Imps;
      END;
   END LOOP;

   begin

      select sum(mcdq2i_c) 
             into cda2isum strict 
        from xxi.cdq2 
       where ncdq2agrid=$1;

      select min(DCDSINTCALCDATE) 
             into fdate strict 
        from xxi.cds 
       where ncdsagrid=$1;

      update xxi.cd_imps set MCDISUMXXI=MCDISUMXXI+cda2isum where DCDIDATE=fdate and ncdiagrid=$1;

    exception
      WHEN OTHERS THEN 
           raise debug '%', SQLERRM;
   end;
   
   -- COMMIT;

END;
$procedure$


/* */
CREATE PROCEDURE calc_CorrSum_Pc ( 
   IN agrId numeric 
)
AS
$procedure$
   #package
DECLARE
   
   CorrSum numeric;

   Get_Imps cursor( p_AgrID numeric) 
   for 
     SELECT * 
       FROM xxi.cd_imps 
      WHERE CCDIMPTYPE = 'PC' and NCDIAGRID = p_AgrID
      ORDER 
         BY DCDIDATE
        FOR UPDATE;
BEGIN

    FOR Cur_Imps IN Get_Imps($1) 
    LOOP
        CorrSum:=0;
        CorrSum:=Cur_Imps.MCDISUM-Cur_Imps.MCDISUMXXI;

        UPDATE xxi.cd_imps 
           SET MCDISUMCRT=CorrSum, ICDISTATUS=2
        WHERE CURRENT OF Get_Imps;

    END LOOP;

END;
$procedure$


/* */
CREATE PROCEDURE cap_Message( IN msg text, VARIADIC prms varchar[] DEFAULT NULL::varchar[] )
AS
$procedure$
   #package
   #private
begin
   INSERT INTO CAP( ccapMESSAGE ) VALUES($1);
end;
$procedure$


/* */
CREATE PROCEDURE cdt2Trn( 
   OUT outmsg varchar, 
   OUT outcnt numeric, 
   OUT outret integer
)
AS
$procedure$
   #package
   #private
declare 
  ErMs         VARCHAR(1500);
  EM           VARCHAR(1500);
  EvErMsg      VARCHAR(1500);
  EvEM         VARCHAR(1500);

  TRNNUM       NUMERIC(12);
  evSUM        NUMERIC := 0;
  evCUR        CHAR(3);
  evNAME       VARCHAR(100);
  SubOp_Type   NUMERIC(2);
  NBalEM       NUMERIC;
  --ConvEM       NUMERIC;
  ACCV_TR      NUMERIC;
  ACCV         NUMERIC;
  CountErr     NUMERIC:=0;
  CountAcs     NUMERIC:=0;
  CurV         CHAR(3);
  SumV         NUMERIC;
  --  NxtCtrl      CHAR(1);
  SessID       VARCHAR(32):=UserEnv('SessionID');
  l_retTrn     MO.T_RetCode1;
BEGIN

   OutCnt:=0::numeric;

   CALL cdces.cap_Message(CONCAT(TO_CHAR(current_timestamp,'DD.MM.YY HH24:MI:SS'),CHR(10), 'Кредиты XXI. Портфели ПРОДАЖ.',CHR(10), 'Протокол формирования документопроводок.'));

   DECLARE
      Get_CDT CURSOR FOR 
        SELECT *
        FROM CDT
        WHERE ccdtSESSIONID = SessId AND icdtTRNNUM IS NULL
        ORDER BY ccdtTYPE_LABEL;

   BEGIN
   
      FOR Cur_CDT IN Get_CDT 
      LOOP
         BEGIN
            CALL cdces.cap_Message(CONCAT('Портфель № ', Cur_CDT.ncdtAGRID::varchar));

            evSUM:= Cur_CDT.mcdtEVTSUM; 
            evCUR:= Cur_CDT.ccdtEVTCUR;

            CALL cdces.cap_Message(CONCAT(COALESCE(evNAME,'???'), TO_CHAR(evSUM,'fm99999999999990d00'),' ',evCUR));

            -- Определение SubOp_Type
            IF Cur_CDT.icdtTOP=20 AND Cur_CDT.icdtSOP IS NULL THEN
               SubOp_Type:=0;
            ELSIF Cur_CDT.icdtTOP=35 AND Cur_CDT.icdtSOP IS NULL THEN
               SubOp_Type:=0;
            ELSE
               SubOp_Type:=Cur_CDT.icdtSOP;
            END IF;
      
            RAISE DEBUG 'CDCes.cdt2trn.ActivMode = %', ActivMode;
      
            -- Декларативные действия
            IF ActivMode = 'D' THEN
               CALL cdces.cap_Message(' Формирование декларативного действия ');        
               RAISE DEBUG 'CDCes.cdt2trn.ActivMode = D';
    
               CALL cdces.Reg_SLEevent(EvErMsg, Cur_CDT.ncdtAGRID, Cur_CDT.ccdtTYPE_LABEL::NUMERIC, Cur_CDT.dcdtACTION, evSUM, NULL, TRNNUM,0);
                                    
               IF EvErMsg='Ok' THEN
                  CALL cdces.cap_Message(' Действие зарегистрировано.');
               ELSE
                  CALL cdces.cap_Message(CONCAT(EvErMsg,' ',EvEM));
                  CountErr := CountErr + 1;
               END IF;

            ELSE -- Реальные проводки
               IF Cur_CDT.icdtTOP IN (1,20,35) THEN
                  IF Cur_CDT.icdtTOP =1 THEN
                     l_retTrn := MO.register(
                         DebitAcc       => Cur_CDT.ccdtACCD::varchar,
                         DebitCur       => Cur_CDT.ccdtCURD::varchar,
                         CreditAcc      => Cur_CDT.ccdtACCC::varchar,
                         CreditCur      => Cur_CDT.ccdtCURC::varchar,
                         DebitSum       => Cur_CDT.mcdtSUMD::numeric,
                         CreditSum      => Cur_CDT.mcdtSUMC::numeric,
                         OpType         => Cur_CDT.icdtTOP::numeric,
                         --turnovers      => 'ART1'::varchar,
                         SubOpType      => SubOp_Type::numeric,
                         RegDate        => Cur_CDT.dcdtCREATE::date,
                         DocDate        => Cur_CDT.dcdtDOC::date,
                         DocNum         => Cur_CDT.icdtDOCNUM::numeric,
                         BatNum         => Cur_CDT.icdtBATNUM::numeric,
                         Debtor_Name    => null::varchar,
                         Debtor_INN     => null::varchar,
                         Creditor_Name  => null::varchar,
                         Creditor_INN   => null::varchar,
                         Purpose        => Cur_CDT.ccdtPURP::varchar,
                         IgnoreRB       => FALSE::boolean,
                         CtrlDebAcc     => 'Y'::varchar,
                         CtrlCredAcc    => 'Y'::varchar,
                         Vo             => Cur_CDT.Ccdtvo::varchar
                     );
                  ELSIF Cur_CDT.icdtTOP IN (20,35) THEN
                     l_retTrn := MO.register( 
                         DebitAcc       => Cur_CDT.ccdtACCD::varchar,
                         DebitCur       => Cur_CDT.ccdtCURD::varchar,
                         CreditAcc      => Cur_CDT.ccdtACCC::varchar,
                         CreditCur      => Cur_CDT.ccdtCURC::varchar,
                         DebitSum       => Cur_CDT.mcdtSUMD::numeric,
                         CreditSum      => Cur_CDT.mcdtSUMC::numeric,
                         OpType         => Cur_CDT.icdtTOP::numeric,
                         --turnovers      => 'ART1'::varchar,
                         SubOpType      => SubOp_Type::numeric,
                         RegDate        => Cur_CDT.dcdtCREATE::date,
                         DocDate        => Cur_CDT.dcdtDOC::date,
                         DocNum         => Cur_CDT.icdtDOCNUM::numeric,
                         BatNum         => Cur_CDT.icdtBATNUM::numeric,
                         Debtor_Name    => null::varchar,
                         Debtor_INN     => null::varchar,
                         Creditor_Name  => null::varchar,
                         Creditor_INN   => null::varchar,
                         Purpose        => Cur_CDT.ccdtPURP::varchar,
                         Vo             => Cur_CDT.Ccdtvo::varchar
                     );
                  END IF;
             
                  RAISE DEBUG 'l_retTrn = %', l_retTrn;

                  IF (l_retTrn).cRetCode ='Ok' THEN
                     CALL cdces.cap_Message(' Документ сформирован.');
                     
                     TRNNUM := (l_retTrn).id_trn.num::numeric;

                     BEGIN
                        UPDATE CDT
                        SET icdtTRNNUM=TRNNUM
                        WHERE icdtID=Cur_CDT.icdtID;
                     EXCEPTION
                        WHEN OTHERS THEN
                           CountErr:=CountErr+1;
                           CALL cdces.cap_Message(' Идентификатор проводки не прописывается в реестр.');  
                           CONTINUE;
                     END;

                     CountAcs:=CountAcs+1; 
                     OutCnt:=CountAcs;

                     CALL cdces.Reg_SLEevent(EvErMsg, Cur_CDT.ncdtAGRID, Cur_CDT.ccdtTYPE_LABEL::numeric, Cur_CDT.dcdtACTION, evSUM, NULL, TRNNUM, 0);

                     IF EvErMsg='Ok' THEN
                        CALL cdces.cap_Message(' Действие зарегистрировано.');  

                        IF cdces.RESET_MLINK_TRN(EM, TRNNUM, 0)!='OK' THEN
                           CountErr:=CountErr + 1;
                           CALL cdces.cap_Message(CONCAT(' Не изменился статус проводки - ', EM)); 
                        END IF;

                        CALL cdces.cap_Message(' Проводка привязана полностью.');
                     ELSE
                        CountErr := CountErr + 1;
                        CALL cdces.cap_Message(CONCAT(EvEM, ' Требуется идентификация.')); 
                     END IF;

                  ELSE
                     CountErr:=CountErr + 1;
                     CALL cdces.cap_Message(CONCAT('Ошибка MO.register1: ', (l_retTrn).cRetCode));
                  END IF;

               ELSIF Cur_CDT.icdtTOP IN (7,8) THEN
                  IF Cur_CDT.icdtTOP = 7 THEN
                     ACCV:=Cur_CDT.ccdtACCD;
                     ACCV_TR:=Cur_CDT.ccdtACCC;
                     CurV := Cur_CDT.ccdtCURD;
                     SumV := Cur_CDT.mcdtSUMD;

                     IF( SUBSTR(ACCV,1,3) = '999') OR (SUBSTR(ACCV_TR,1,3) = '913') OR (ACCV IS NULL) THEN
                        ACCV := Cur_CDT.ccdtACCC;
                        ACCV_TR := Cur_CDT.ccdtACCD;
                        CurV := Cur_CDT.ccdtCURC;
                        SumV := Cur_CDT.mcdtSUMC;
                     END IF;
                  ELSE
                     ACCV:=Cur_CDT.ccdtACCC;
                     ACCV_TR:=Cur_CDT.ccdtACCD;
                     CurV := Cur_CDT.ccdtCURC;
                     SumV := Cur_CDT.mcdtSUMC;

                     IF (SUBSTR(ACCV,1,3) = '999') OR (SUBSTR(ACCV_TR,1,3) = '913') OR (ACCV IS NULL) THEN
                        ACCV := Cur_CDT.ccdtACCD;
                        ACCV_TR := Cur_CDT.ccdtACCC;
                        CurV := Cur_CDT.ccdtCURD;
                        SumV := Cur_CDT.mcdtSUMD;
                     END IF;
                  END IF;

                  NBalEM:= NBALANCE.Make_Order(
                     Cur_CDT.icdtTOP,
                     Cur_CDT.icdtDOCNUM,
                     ACCV,
                     ACCV_TR,
                     CurV,
                     Cur_CDT.dcdtCREATE,
                     NULL,
                     NULL,
                     NULL,
                     SumV,
                     Cur_CDT.ccdtPURP,
                     NULL,
                     NULL,
                     NULL,
                     NULL,
                     SubOp_Type,
                     Cur_CDT.icdtBATNUM
                  );

                  IF NBalEM=0 THEN
                     CALL cdces.cap_Message(' Документ сформирован.');   
                     
                     TRNNUM := (l_retTrn).id_trn.num::numeric;

                     BEGIN
                        UPDATE CDT
                        SET icdtTRNNUM=TRNNUM
                        WHERE icdtID=Cur_CDT.icdtID;
                     EXCEPTION
                        WHEN OTHERS THEN 
                           CountErr:=CountErr+1;
                           CALL cdces.cap_Message(' Идентификатор проводки не прописывается в реестр.');   
                           CONTINUE;
                     END;

                     CountAcs:=CountAcs+1; 
                     OutCnt:=CountAcs;

                     CALL cdces.Reg_SLEevent(EvErMsg, Cur_CDT.ncdtAgrID, Cur_CDT.ccdtTYPE_LABEL::numeric, Cur_CDT.dcdtACTION, evSUM, NULL, TRNNUM, 0);

                     IF EvErMsg='Ok' THEN
                        CALL cdces.cap_Message(' Действие зарегистрировано.');   

                        IF cdces.RESET_MLINK_TRN(EM, TRNNUM, 0) != 'OK' THEN
                           CountErr:=CountErr+1;
                           CALL cdces.cap_Message(CONCAT(' Не изменился статус проводки - ', EM));   
                        END IF;

                        CALL cdces.cap_Message(' Проводка привязана полностью.');   
                     ELSE
                        CountErr:=CountErr+1;
                        CALL cdces.cap_Message(CONCAT(EvEM, ' Требуется идентификация.'));  
                     END IF;
                  ELSE
                     CountErr:=CountErr + 1;
                     CALL cdces.cap_Message(CONCAT('Ошибка NBALANCE.Make_Order: ', NBalEM::text));  
                  END IF;
               ELSE
                  CountErr:=CountErr + 1;
                  CALL cdces.cap_Message(CONCAT('Неподдерживаемый тип операции: ', Cur_CDT.icdtTOP::text));
               END IF;
            END IF;

         EXCEPTION
            WHEN OTHERS THEN
               CountErr := CountErr + 1;
               CALL cdces.cap_Message(CONCAT('Ошибка обработки записи: ', SQLERRM));
               CONTINUE;
         END;
      END LOOP;
   END;

   CALL cdces.cap_Message('***');
   DELETE FROM CDD WHERE ccddSESSIONID = SessID;
   CALL cdces.cap_Message('*');

   OutRet := CountErr;

EXCEPTION
   WHEN OTHERS THEN
      OutMsg := SQLERRM;
      OutRet := -1;
      OutCnt := 0;
      CALL cdces.cap_Message(CONCAT('Критическая ошибка: ', SQLERRM));
END;
$procedure$


/* */
CREATE FUNCTION check_dscrstBdo( 
   in p_agrid numeric
)
   RETURNS 
      boolean
AS
$function$
   #package
   #private
   declare
  isRest    BOOLean := FALSE;
  DscRstBdO NUMERIC := 0;
begin

   select sum(mcdesum) 
          into DscRstBdO 
     from cde 
    where ncdeAgrid=$1 
      and icdetype = 810 and icdesubtype in( 721, 725, 755, 771, 775 );

   IF DscRstBdO > 0  THEN
      isRest:=TRUE;
   END IF;

   RETURN isRest;

end;
$function$


/* */
CREATE FUNCTION check_monoAgrsl( 
   in saleId numeric
)
RETURNS
   boolean
AS 
$function$
   #package
   #private
declare
   cnt int4;
BEGIN
   SELECT Count(NCDAAGRID) INTO Cnt from CDA_LINK_CDSALE where ICDSALEID=$1;
   IF Cnt = 1 THEN 
      RETURN TRUE; 
   ELSE 
      RETURN FALSE;
   END IF;
END;
$function$


/* */
CREATE FUNCTION check_SLStatus( 
   in saleid numeric 
)
RETURNS 
   numeric
AS
$function$
   #package
   #private
declare
   Status NUMERIC := 1; --  2 - исполняемый, 3 - завершенный
   rec_CDA  record;
   SaleName varchar;

   Agr_Sale CURSOR 
   for 
   SELECT NCDAAGRID 
      from CDA_LINK_CDSALE 
         where ICDSALEID=$1;
BEGIN
  
   select ccdsalenum 
      into SaleName 
   from cdsale 
      where icdsaleid = $1;

   call CDENV.SaveMess( TO_CHAR(SYSDATE,'DD.MM.YY HH:MI:SS')||CHR(10) ||'Кредиты XXI.'||CHR(10) ||'Протокол проверки статуса Портфеля продаж/покупок'||CHR(10) ||'Номер контракта: '||SaleName||', ID контракта: '||SaleID, 'I' );

   FOR CurAgr IN Agr_Sale LOOP
      call CDENV.SaveMess(concat('Обработка договора ',CurAgr.NCDAAGRID),'I');
      SELECT * INTO rec_CDA FROM CDA WHERE ncdaAGRID = CurAgr.NCDAAGRID;
   END LOOP;  

   Return Status;

END;
$function$


/* */
CREATE PROCEDURE clear_shdl_pc_from(
   IN agrid     numeric, 
   IN datefrom  date, 
   IN do_commit boolean DEFAULT true
)
AS
$procedure$
   #package
   #private
BEGIN
  DELETE FROM xxi.cds WHERE dcdsintcalcdate >= $2 AND ncdsAgrID=$1;
  --IF $3 THEN COMMIT; END IF;
END;
$procedure$


/* */
CREATE FUNCTION close_sale( 
   saleid numeric
)
RETURNS
   integer
AS 
$function$
   #package
   #private
declare
   Base_Cur     CHAR(3);
   SaleName     cdsale.ccdsalenum%TYPE;
   Sale_Terms   CDSale%ROWTYPE;
   CDA_Terms    CDA%ROWTYPE;
   Sale_Acc_Rst NUMERIC := 0;
   Obl_Acc_Rst  NUMERIC := 0;
   Req_Acc_Rst  NUMERIC := 0;
   Date_Act     DATE := CD.Get_LSDate();
   Err          integer := 1; -- 0 - сделка успешно завершена, 1 - ошибки в протоколе
   closedate    acc.DACCCLOSE%TYPE;-- xxi.acc.DACCCLOSE%TYPE;
   cntClsAcc    NUMERIC := 0;
   EM           VARCHAR;
    AgrID        cda.ncdaagrid%TYPE;
    hasActiveAgreement BOOLEAN := FALSE;

   Get_Sale CURSOR 
   IS
      SELECT CDSale.* FROM CDSale WHERE icdsaleID = saleid;

   Get_CDA CURSOR (AgrID NUMERIC)  
   is 
     SELECT CDA.* FROM CDA WHERE ncdaAgrID = AgrID;

    -- Курсор для получения всех договоров, связанных со сделкой
    Get_Linked_Agreements CURSOR
    IS
    SELECT NCDAAGRID FROM CDA_LINK_CDSALE WHERE ICDSALEID = saleid;

BEGIN

   select ccdsalenum 
      into SaleName from cdsale 
         where icdsaleid = saleid;

   INSERT INTO CAP(ccapMESSAGE) VALUES(TO_CHAR(current_timestamp,'DD.MM.YY HH:MI:SS')||CHR(10)|| 'Кредиты XXI. Портфели ПРОДАЖ.'||CHR(10)|| 'Протокол процедуры закрытия Портфеля продаж/покупок.'||CHR(10)|| 'Номер контракта: '||SaleName||', ID контракта: '||saleid||CHR(10));
  
   Base_Cur:= UTIL.Get_Base_Cur();

    -- Проверка статусов всех связанных договоров
    hasActiveAgreement := FALSE;
    FOR linked_agr IN Get_Linked_Agreements LOOP
        AgrID := linked_agr.NCDAAGRID;
        
        OPEN Get_CDA(AgrID);
        FETCH Get_CDA INTO CDA_Terms;
        
        IF FOUND THEN
            IF CDA_Terms.icdastatus != 3 THEN
                INSERT INTO CAP(ccapMESSAGE) VALUES(concat('Сделка не завершена, договор ',AgrID,' имеет статус "', 
                    CASE CDA_Terms.icdastatus 
                        WHEN 0 THEN 'Черновик'
                        WHEN 1 THEN 'Условный' 
                        WHEN 2 THEN 'Действующий'
                        WHEN 6 THEN 'Продажа'
                        ELSE ''
                    END , '". Договор должен быть в статусе "Завершенный".' , CHR(10)));
                hasActiveAgreement := TRUE;
            END IF;
        END IF;
        CLOSE Get_CDA;
    END LOOP;
    
    -- Если хотя бы один договор не завершен, прерываем выполнение
    IF hasActiveAgreement THEN
        RETURN Err;
    END IF;

   OPEN Get_Sale;
      FETCH Get_Sale INTO Sale_Terms;
         CLOSE Get_Sale;

   IF Sale_Terms.CCDSALEOBLACC IS NOT NULL THEN
      Obl_Acc_Rst:= ABS(UTIL_DM2.Acc_Ost( 0, Sale_Terms.CCDSALEOBLACC,Sale_Terms.CCDSALEOBLCUR,Date_Act+1,'V') );
      INSERT INTO CAP(ccapMESSAGE) VALUES('Счет обязательств '||Sale_Terms.CCDSALEOBLACC||' остаток '||to_char(Obl_Acc_Rst)||CHR(10));
   END IF;
 
   IF Sale_Terms.CCDSALEACC IS NOT NULL THEN
      Sale_Acc_Rst := UTIL_DM2.Acc_Ost(0,Sale_Terms.CCDSALEACC,Sale_Terms.CCDSALECUR,Date_Act+1,'V');
      INSERT INTO CAP(ccapMESSAGE) VALUES('Счет продажи '||Sale_Terms.CCDSALEACC||' остаток '||to_char(Sale_Acc_Rst)||CHR(10));
   END IF;
 
  IF Sale_Terms.CCDSALEREQACC IS NOT NULL THEN
    Req_Acc_Rst := ABS(UTIL_DM2.Acc_Ost(0,Sale_Terms.CCDSALEREQACC,Sale_Terms.CCDSALEREQCUR,Date_Act+1,'V'));
    INSERT INTO CAP(ccapMESSAGE) VALUES('Счет требований '||Sale_Terms.CCDSALEREQACC||' остаток '||to_char(Req_Acc_Rst)||CHR(10));
  END IF; 
  
   IF Obl_Acc_Rst+ABS(Sale_Acc_Rst)+Req_Acc_Rst > 0 THEN
      INSERT INTO CAP(ccapMESSAGE) VALUES('Сделка не завершена, есть остатки на счетах'||CHR(10));
      Return Err;
   ELSE
      select CD.get_lsdate() + CURRENT_TIME
                     --1/86400 
                  into closeDate;
    -- Счет обязательств 
   IF Sale_Terms.CCDSALEOBLACC IS NOT NULL AND ACC_INFO.get_accprizn(Sale_Terms.CCDSALEOBLACC, Sale_Terms.CCDSALEOBLCUR) <> 'З' THEN

     /* IF NOT(ACCOUNT2.change_acc_state(Sale_Terms.CCDSALEOBLACC,
                                       Sale_Terms.CCDSALEOBLCUR,
                                       'З',
                                       'Закрытие Портфеля продаж/покупок Номер контракта: '||SaleName||', ID контракта: '||$1,
                                       closedate ,EM)) THEN*/
         EM := NULL;
         CALL ACCOUNT2.change_acc_state(
                                       EM,  -- OUT параметр (вернет ошибку)
                                       Sale_Terms.CCDSALEOBLACC::varchar,
                                       Sale_Terms.CCDSALEOBLCUR::varchar, 
                                       'З'::varchar,
                                       (concat('Закрытие Портфеля продаж/покупок Номер контракта: ',SaleName,', ID контракта: ',saleid))::varchar,
                                       closedate::timestamp
                                       );

    IF EM IS NOT NULL THEN
        INSERT INTO CAP(ccapMESSAGE) VALUES('Счет обязательств - '||Sale_Terms.CCDSALEOBLACC||' - '||EM||CHR(10));
        cntclsacc := cntclsacc + 1;                         
      ELSE
        INSERT INTO CAP(ccapMESSAGE) VALUES('Счет обязательств - '||Sale_Terms.CCDSALEOBLACC||' - закрыт'||CHR(10));
      END IF;
    END IF;  
    -- Счет продажи 
    IF Sale_Terms.CCDSALEACC IS NOT NULL AND ACC_INFO.get_accprizn(Sale_Terms.CCDSALEACC, Sale_Terms.CCDSALECUR) <> 'З' THEN
   
  /* IF NOT(ACCOUNT2.change_acc_state(Sale_Terms.CCDSALEACC,
                                       Sale_Terms.CCDSALECUR,
                                       'З',
                                       'Закрытие Портфеля продаж/покупок Номер контракта: '||SaleName||', ID контракта: '||$1,
                                       closedate ,EM)) THEN*/
         EM := NULL;
         CALL ACCOUNT2.change_acc_state(
                                       EM,  -- OUT параметр (вернет ошибку)
                                       Sale_Terms.CCDSALEACC::varchar,
                                       Sale_Terms.CCDSALECUR::varchar,
                                       'З'::varchar,
                                       (concat('Закрытие Портфеля продаж/покупок Номер контракта: ',SaleName,', ID контракта: ',saleid))::varchar,
                                       closedate::timestamp
                                       );

    IF EM IS NOT NULL THEN
        INSERT INTO CAP(ccapMESSAGE) VALUES('Счет продажи - '||Sale_Terms.CCDSALEACC||' - '||EM||CHR(10));
        cntclsacc := cntclsacc + 1;                         
      ELSE 
        INSERT INTO CAP(ccapMESSAGE) VALUES('Счет продажи - '||Sale_Terms.CCDSALEACC||' - закрыт'||CHR(10));
      END IF;
    END IF;    
    -- Счет требований 
    IF Sale_Terms.CCDSALEREQACC IS NOT NULL AND ACC_INFO.get_accprizn(Sale_Terms.CCDSALEREQACC, Sale_Terms.CCDSALEREQCUR) <> 'З' THEN

    /*  IF NOT(ACCOUNT2.change_acc_state(Sale_Terms.CCDSALEREQACC,
                                       Sale_Terms.CCDSALEREQCUR,
                                       'З',
                                       'Закрытие Портфеля продаж/покупок Номер контракта: '||SaleName||', ID контракта: '||$1,
                                       closedate ,EM)) THEN*/
         EM := NULL;
         CALL ACCOUNT2.change_acc_state(
                                       EM,  -- OUT параметр (вернет ошибку)
                                       Sale_Terms.CCDSALEREQACC::varchar,
                                       Sale_Terms.CCDSALEREQCUR::varchar, 
                                       'З'::varchar,
                                       (concat('Закрытие Портфеля продаж/покупок Номер контракта: ',SaleName,', ID контракта: ',saleid))::varchar,
                                       closedate::timestamp
                                       );
 
      IF EM IS NOT NULL THEN
        INSERT INTO CAP(ccapMESSAGE) VALUES('Счет требований - '||Sale_Terms.CCDSALEREQACC||' - '||EM||CHR(10));                         
        cntclsacc := cntclsacc + 1;
      ELSE
        INSERT INTO CAP(ccapMESSAGE) VALUES('Счет требований - '||Sale_Terms.CCDSALEREQACC||' - закрыт'||CHR(10));
      END IF;  
    END IF;            
  END IF;

  IF cntclsacc > 0 THEN 
    INSERT INTO CAP(ccapMESSAGE) VALUES('Сделка не завершена, ошибки при закрытии счетов'||CHR(10));
    Err := 1;
  ELSE
    UPDATE cdsale SET icdsalestatus = 3 where icdsaleid = saleid;
    INSERT INTO CAP(ccapMESSAGE) VALUES(concat('Портфеля продаж/покупок Номер контракта: ',SaleName,', ID контракта: ',saleid,' - в статусе Завершенный',CHR(10)));  
    Err := 0; -- Успешное закрытие
  END IF;
RETURN Err;
END;
$function$


/* */
CREATE PROCEDURE corr_intCalcsum ( 
   IN p_agrId numeric, 
   IN bdate   date, 
  OUT retval  boolean, 
  OUT errmsg  character varying
)
AS
$procedure$
   #package
   #private
   declare 
   intCalcSum NUMERIC:= 0;
   intSum     NUMERIC:= 0;
   fintSum    NUMERIC:= 0;
   SumEvt31   NUMERIC:= 0;
   CorrSum    NUMERIC:= 0;
   evID       NUMERIC;
   evDATE     DATE;
   ErM        VARCHAR;

   All_Parts CURSOR
   for 
      SELECT icdqPART Num 
         FROM CDQ 
            WHERE ncdqAGRID=$1 
               ORDER BY Num;

   Get_CDA CURSOR
   for 
      SELECT * 
        FROM CDA inner join CDA2 on CDA.ncdaagrid = CDA2.ncda2agrid and ncdaAGRID = $1;

   CDA_Terms record;

BEGIN

   if BDate is null then 
      ErM := 'Не задана дата покупки'; 
      --dbms_output.put_line(ErM);
      raise debug '%', erM;  
      ErrMsg :=  ErM;    
      retVal := FALSE; 
      RETURN; 
   end if; 

   evDATE := $2;
     
   FOR Cur_Part IN All_Parts 
   LOOP
      
      select MCDQ2ICALC_C, MCDQ2I_C into intcalcsum, intsum from xxi.cdq2 where ncdq2agrid=$1 and icdq2part = Cur_Part.Num;

      if intcalcsum is null or intcalcsum = 0 then 
         ErM := 'Не задана расчетная сумма процентов на интервале, включающем дату покупки';
raise debug '%', erM;  
         ErrMsg :=  ErM;   
         retVal := TRUE; RETURN; 
      end if;
    
      if intsum is null or intsum = 0 then 
         ErM := 'Не задана сумма выкупленных текущих процентов'; 
raise debug '%', erM;  
         -- dbms_output.put_line(ErM); 
         ErrMsg :=  ErM;    
         retVal := FALSE; RETURN; 
      end if;
    
      OPEN Get_CDA;
         FETCH Get_CDA INTO CDA_Terms; 
            CLOSE Get_CDA;
    
      IF CDA_Terms.icdastatus = 2 THEN
         call CDINTEREST.Recalc_Interest( $1,'R',TRUE,FALSE); 
      END IF;

      IF CDA_Terms.icdastatus IN (0,1) THEN
         call CDINTEREST.Recalc_Interest( $1,'T',TRUE,FALSE); 
      END IF;
    
      begin 
            select mcditotal into fintSum 
               from v_cdi 
                  where ncdiAgrID = $1 and icdipart = Cur_Part.Num and ccdirt = decode(CDA_Terms.icdastatus, 2, 'R','T') 
                    and dcdito = (select min(dcdsintcalcdate) from xxi.cds where ncdsAgrID = $1); 
      exception
         when others then 
            ErM :='Ошибка при получении суммы процентов рассчитанных на первом интервале';
raise debug '%', erM;  
            ErrMsg :=  ErM;      
            retVal := FALSE; RETURN; 
      end;
    
      CorrSum := intcalcsum - intsum - ( fintSum + CDState.Get_Evt_Sum( $1, Cur_Part.Num, 31, evDATE) );

raise debug 'intcalcsum=% intsum=% fintSum=% CDState.Get_Evt_Sum=%', intcalcsum::varchar, intsum::varchar, fintSum::varchar, CDState.Get_Evt_Sum($1, Cur_Part.Num, 31, evDATE)::varchar;  

      -- dbms_output.put_line('intcalcsum='||intcalcsum||' intsum='||intsum||' fintSum='||fintSum||' CDState.Get_Evt_Sum='||CDState.Get_Evt_Sum($1, Cur_Part.Num, 31, evDATE));      
    
      IF CorrSum != 0 THEN

         -- dbms_output.put_line('Часть '||Cur_Part.Num||'. Сумма коррекции процентов '||CorrSum);
         raise debug 'Часть %. Сумма коррекции процентов %', Cur_Part.Num::varchar,  CorrSum::varchar;  
      
         INSERT INTO CDE (ncdeAGRID, icdePART, icdeTYPE, icdeSUBTYPE, dcdeDATE, mcdeSUM, ccdeREM, icdeTRNNUMF, icdeTRNANUMF, ncdeczo, icdeswpnum, icdesourceid, icdetargetid, CCDEEXTID)
                  VALUES (       $1,        1,       31,           0,   evDATE, CorrSum, 'Коррекция первого интервала под расчет цедента', null, null, null, null, null, null, null);

         -- commit;

         -- dbms_output.put_line('Действие Начет процентов на сумму '||CorrSum||' зарегистрировано'); 
         raise debug 'Действие Начет процентов на сумму % зарегистрировано', CorrSum::varchar;  

         CorrSum := 0;

      END IF;

   END LOOP;
  
   retVal := true; 

END;
$procedure$


/* */
CREATE PROCEDURE corrsum_pc (
   IN agrid numeric, 
   IN datefrom date
)
AS 
$procedure$
   #package
   #private
BEGIN
   DELETE FROM CDE WHERE ncdeAGRID=$1 AND icdeTYPE=31 and dcdedate >=$2 AND icdeSUBTYPE=0;
   call CDCes.Calc_CDISUM($1);
   call CDCes.Calc_CorrSum_PC($1);
   call CDCes.Set_CorrSum_PC($1, $2);
END;
$procedure$


/* */
CREATE PROCEDURE create_acc ( 
   OUT ret boolean, 
    IN agrid numeric, 
    IN bs2 numeric, 
    OUT newacc acc, 
    OUT retinfo character varying
)
AS
$procedure$
   #package
   #private
declare

   c_getMask CURSOR 
   for
      SELECT cd2.icd2maskcode, cda.ccdacuriso, cda.icdaclient, cda.icdabranch
        FROM cd2, cda
       WHERE cd2.ncd2agrid = $2
         AND cda.ncdaagrid = $2;

   r_getMask record;
   l_errorInfo VARCHAR(2000);
-- маска из cd2, тип счета 2
-- через ядро - > Account2.Ins_Account
BEGIN

   OPEN c_getMask; 
      FETCH c_getMask INTO r_getMask; 
         CLOSE c_getMask;

   IF NOT
      Account2.Ins_Account(
          NewAcc,
          p_Currency => r_getMask.cCdaCurISO,
          p_Customer => r_getMask.iCdaClient,
          p_Bs2      => $3,
          p_Prizn    => 'О',
          p_otd      => r_getMask.iCdaBranch,
          p_Dopen    => CURRENT_TIMESTAMP,
          p_Name     => 'Текущий счет для договора ' || $2,
          p_Mask_Id  => r_getMask.iCd2MaskCode,
          p_Err      => l_errorInfo
      )
   THEN
      $5 := 'Ошибка заведения текущего счета: ' || l_errorInfo;
   else  
      $5 :=  'Заведен счет: ' || NewAcc;
      $1 := TRUE;
   END IF;
END;
$procedure$


/* */
CREATE PROCEDURE cdces.cuscg2ba1( 
    IN cusnum numeric, 
   OUT newba1 numeric, 
   OUT errmsg character varying, 
   OUT grpstr character varying
)
AS
$procedure$
   #package
   #private
DECLARE

   Get_CG  CURSOR
   FOR 
   SELECT  coalesce(a,'x') || coalesce(b,'x') || coalesce(c,'x') || coalesce(d,'x' ) CGStr
     FROM( SELECT
           (SELECT igcsnum::varchar FROM gcs WHERE igcscat = 15 AND igcscus = $1) a,
           (SELECT igcsnum::varchar FROM gcs WHERE igcscat =  7 AND igcscus = $1) b,
           (SELECT igcsnum::varchar FROM gcs WHERE igcscat =  1 AND igcscus = $1) c,
           (SELECT igcsnum::varchar FROM gcs WHERE igcscat =  8 AND igcscus = $1) d
         );

   CurCus_CG RECORD;

BEGIN

   $2 := null;

   RAISE debug 'Cus2BA1 started with $1 = %', $1::varchar;

   OPEN Get_CG; 
      FETCH Get_CG INTO CurCus_CG; 
         CLOSE Get_CG;

   IF CurCus_CG.CGStr = 'xxxx' THEN
      $3 := 'Не найдены настройки для клиента ' || $1::varchar;
      RETURN;
   END IF;

   -- DBMS_OUTPUT.PUT_LINE( 'Настройки для клиента ' ||$1)||'  '||CurCus_CG.CGStr );
   RAISE debug 'Настройки для клиента % %', $1::varchar, CurCus_CG.CGStr;

   $4 := CurCus_CG.CGStr;

   IF SUBSTR(CurCus_CG.CGStr,0,2) = '11' THEN $2 := 455;
   ELSIF SUBSTR(CurCus_CG.CGStr,0,2) = '12' THEN $2 := 457;
   ELSIF SUBSTR(CurCus_CG.CGStr,0,2) = '41' THEN $2 := 454;
   ELSIF SUBSTR(CurCus_CG.CGStr,0,2) = '22' THEN $2 := 456;
   ELSE
      $2 :=
       CASE CurCus_CG.CGStr
       --WHEN '11xx' THEN 455  -- закомментировать или удалить при выносе в IF
       --WHEN '12xx' THEN 457
       --WHEN '41xx' THEN 454
       --WHEN '22xx' THEN 456
          WHEN '2153' THEN 453
          WHEN '2152' THEN 452
          WHEN '7151' THEN 451
          WHEN '2143' THEN 450
          WHEN '2142' THEN 449
          WHEN '7141' THEN 448
          WHEN '2133' THEN 447
          WHEN '2132' THEN 446
          WHEN '7131' THEN 445
          WHEN '2124' THEN 444
          WHEN '2114' THEN 443
          WHEN '2121' THEN 442
          WHEN '211x' THEN 441
       END;
   END IF;

   IF $2 IS NULL THEN
      $3 := 'Нет нового БС1 для настроек групп из кат. 15,7,1,8 = ' || CurCus_CG.CGStr ||' у клиента '|| $1::varchar;
   END IF;

END;
$procedure$


/* */
CREATE FUNCTION def_finres ( 
   defdate date DEFAULT cd.get_lsdate()
)
RETURNS 
   character varying
AS
$function$
   #package
DECLARE

   Cur_LST CURSOR 
   for 
     select ncdaccagrid, icdacctype, ccdaccacc, ccdacccur, cda.* 
       from cd_acc, cda 
      where ncdaccagrid=ncdaagrid and icdacctype=702 and icdaces=1 and icdastatus=2;

   GET_CMA CURSOR (Tmplt_NUM NUMERIC) 
   for
      SELECT CMA.*, caccCUR ccmaCUR
      FROM CMA, ACC
      WHERE icmaMAK = Tmplt_NUM
        AND icmaTPDEF=3 AND caccACC=ccmaACC
        ;

   recCDT record;
   ErrMsg VARCHAR(2000);
   EM     VARCHAR(2000);
   IncACC acc.caccACC%TYPE;
   IncCUR acc.caccCUR%TYPE;
   OutACC acc.caccACC%TYPE;
   OutCUR acc.caccCUR%TYPE;
   CorrSum CDT.mcdtSUMD%TYPE;
   EvErMsg VARCHAR(2000);
   EvEM    VARCHAR(2000);
   TRNNUM trn.itrnnum%TYPE;

BEGIN

   call CDOPER.Process_SaveMess( pErrMess => 'Определение финансового результата. Дата '||DefDate||'.', pErrTp => 'I', pErrId => 'CES01');

  FOR Cur_Rec IN Cur_LST LOOP

   CorrSum := cdbalance.get_cred(Cur_Rec.ncdaagrid, 702) - cdbalance.get_deb(Cur_Rec.ncdaagrid, 702);

   IF CorrSum!=0 THEN

      recCDT.mcdtSUMD := ABS(CorrSum);

      FOR Cur_CMA IN Get_CMA(Cur_Rec.icdatemplate) 
      LOOP
        IF Cur_CMA.icmaTPPRM = 798 THEN
          IncACC:=Cur_CMA.ccmaACC; IncCUR:=Cur_CMA.ccmaCUR;
        ELSIF Cur_CMA.icmaTPPRM = 799 THEN
          OutACC:=Cur_CMA.ccmaACC; OutCUR:=Cur_CMA.ccmaCUR;
        END IF;
      END LOOP;

      IF CorrSum>0 THEN
         recCDT.ccdttype_label := 798;
         recCDT.ccdtpurp := 'Списание-обнуление счета выбытия и погашения приобретенных прав ';
         recCDT.ccdtACCD := Cur_REC.ccdaccacc;
         recCDT.ccdtACCC := IncACC;
      ELSE
         recCDT.ccdttype_label := 799;
         recCDT.ccdtpurp := 'Начисление-обнуление счета выбытия и погашения приобретенных прав ';
         recCDT.ccdtACCD := OutACC;
         recCDT.ccdtACCC := Cur_REC.ccdaccacc;
      END IF;

      recCDT.icdttop := 1;
      recCDT.ncdtagrid := Cur_Rec.ncdaagrid;
      recCDT.dcdtCREATE :=  DefDate;

      call cd2trn.ControlDocType_2( recCDT.ncdtagrid, recCDT.icdttop, recCDT.icdtsop, recCDT.ccdtpurp, recCDT.ccdttype_label,NULL,NULL, Cur_REC.icdamd2num, NULL, recCDT );

      recCDT.Icdtdocnum := CDSTATE2.Prepare_DocNumCD(recCDT.icdttop, recCDT.dcdtCREATE, Cur_REC.ncdaagrid);

      ErrMsg:=IDOC_REG.Register ( ErrorMsg      =>  EM,                   -- Сообщение об ошибке для возврата
                              OpType        =>  recCDT.icdtTOP,      -- Тип операции 1-го порядка
                              RegDate       =>  recCDT.dcdtCREATE,   -- Дата регистрации
                              PayerAcc      =>  recCDT.ccdtACCD,     -- Счет плательщика
                              RecipientAcc  =>  recCDT.ccdtACCC,       --  Счет получателя
                              Summa         =>  recCDT.mcdtSUMD,     -- Сумма операции
                              DocDate       =>  recCDT.dcdtCREATE,      -- Дата документа
                              Purpose       =>  recCDT.ccdtpurp,     -- Назначение платежа
                              DocNum        =>  recCDT.Icdtdocnum,   -- Номер документа
                              BatNum        =>  recCDT.icdtBATNUM,   -- Номер пачки
                              ValDate       =>  recCDT.dcdtCREATE,      -- Дата платежа (валютирования)
                              --Priority      =>  Cur_CDT.icdtPRIORITY, -- Очередность платежа
                              SubOpType     =>  recCDT.icdtSOP,      -- Тип операции 2-го порядка
                                  --CorAccO       =>  NULL,                 -- Наш корсчет
                                  --MFOa          =>  NULL,                 -- Код МФО/МСО/КУ Банка-корреспондента
                                  --CorAccA       =>  NULL,                 -- Кор.Счет Банка-корреспондента
                                  --CorAccAName   =>  NULL,                 -- Название Банка-корреспондента

                              --DeliveryWay   =>  Cur_CDT.ccdtDWAY,     -- Способ доставки платежа (почта/телеграф/?л.платеж)

                                  --SBCodeA       =>  NULL,                 -- Код участника (СБ РФ) корреспондента
                              cDocCurrency  =>  recCDT.ccdtCURD,     -- Валюта документа
                              cVO           =>  recCDT.ccdtVO       -- Вид операции
                                  --bIgnoreRB     =>  FALSE,                -- Флаг: игнорировать возникновение красного сальдо
                                  --cEditComms    =>  'NO',                 -- Флаг: генерировать ошибку при требовании редактирования комиссий
                                  --dShadow       =>  NULL,                 -- Дата поступления документа в банк
                            --cCondPay      =>  recCDT.ccdtc -- Условия оплаты документа (mv 08.04.04)
                                  );
--dbms_output.put_line('ERROR IN Ins_CD1_TMP: '||recCDT.ccdtACCD||' ->  '||);
      IF ErrMsg='Ok' 
      THEN
      TRNNUM:= IDOC_REG.GetLastDocID;
      call CDOPER.Process_SaveMess(pErrMess => 'По договору №'||Cur_REC.ncdaagrid||' сформировано действие:'||recCDT.ccdtpurp||' на сумму '||recCDT.mcdtSUMD,
                              pErrTp => 'I',
                              pErrId => 'CES01');

      EvErMsg:=CDEvents.Reg_Event( EvEM,
                                   recCDT.ncdtagrid,
                                   1,
                                   recCDT.ccdttype_label,
                                   null,
                                   DefDate,
                                   recCDT.mcdtSUMD,
                                   NULL,
                                   TRNNUM,
                                   0,
                                   FALSE,
                                   NULL,
                                   NULL,
                                   FALSE,
                                   NULL,
                                   NULL,
                                   NULL);
      IF EvErMsg='OK' THEN
        call CDOPER.Process_SaveMess(pErrMess => 'По договору №'||Cur_REC.ncdaagrid||' зарегистрировано действие:'||recCDT.ccdttype_label||' на сумму '||recCDT.mcdtSUMD,
                                pErrTp => 'I',
                                pErrId => 'CES01');

        IF CDEVENTS.RESET_LINK_TRN(EM, TRNNUM, 0)!='OK' THEN

          call CDOPER.Process_SaveMess(pErrMess => ' Не изменился статус проводки - '||TRNNUM||' - '||EM,
                                pErrTp => 'E',
                                pErrId => 'CES01');

        END IF;
      ELSE
        call CDOPER.Process_SaveMess(pErrMess => 'По договору №'||Cur_REC.ncdaagrid||' действие не зарегистрировано:'||recCDT.ccdttype_label||' суммa '||recCDT.mcdtSUMD||' Ошибка CDEvents.Reg_Event:'||EvErMsg,
                              pErrTp => 'E',
                              pErrId => 'CES01');

      END IF;

    ELSE
      call CDOPER.Process_SaveMess(pErrMess => 'Договор №'||Cur_REC.ncdaagrid||' D/'||recCDT.ccdtACCD||' C/'||recCDT.ccdtACCC||' '||recCDT.mcdtSUMD||' :'||EM, pErrTp => 'E', pErrId => 'CES01');

    END IF;

    END IF;
   END LOOP;

   return 'OK';
END;
$function$


/* */
CREATE PROCEDURE del_doc_logical(IN itrnnmum_in numeric, IN itrn_anum_in numeric, OUT pi_result_out integer, OUT pc_errmsg_out character varying)
AS 
$procedure$
   #package
DECLARE
    cc_OK_DElDoc constant varchar(2) := 'Ok';
    EM Varchar := 'Em'; --cd_types.TErrorString;
    ErrMsg Varchar := 'ErrMsg'; --cd_types.TErrorString;

    ret ts.t_retCode;

BEGIN

    isCDE := 'CDSLE'; 

    if isDBMS Then 
       call cd_utl2s.TxtOut('cdces.Del_Doc_Logical.95.1');
    End IF;

    ret := Doc_del.delete_Logical( itrnnmum_in, itrn_anum_in);  -- recCDE.ICDETRNNUM,recCDE.ICDETRNANUM);

--raise debug 'Doc_del.delete_Logical: %', ret.cErrorMsg;
--raise debug 'Doc_del.delete_Logical: %', ret.cRetCode;
    if isDBMS Then 
       call cd_utl2s.TxtOut('cdces.Del_Doc_Logical.95.2');

       call cd_utl2s.TxtOut('Doc_del.delete_Logical.ret-code: ' || coalesce(ret.cRetCode, '<null>' ) );
       call cd_utl2s.TxtOut( concat( 'Doc_del.delete_Logical.ret-msg : ', ret.cErrorMsg ) );
       
    End if;

    isCDE := NULL; -- (180385)

    IF ret.cRetCode = cc_OK_DElDoc THEN
       pi_result_out := ci_SUCCESS;   
       pc_ERRMSG_out := Null;
    ELSE
         pi_result_out := ci_OTHER_ERROR;      
      -- pc_ERRMSG_out := substr('cdeve_fpkg.Del_Doc_Logical.42: -> проводка ('||itrnnmum_in||','||itrn_anum_in||') не удалена - '||ErrMsg,1,2000);
      -- Vct 24.05.2021
         pc_ERRMSG_out := cd_errsupport.mk_ml2_etext_2000
                           ( pc_source_id => 'cdces.Del_Doc_Logical.95.3:'  -- символьный идентификатор места возникновения ошибки... (общая длина не более 100 символов)
                           , pText  => ' -> проводка ( %1 , %2 ) не удалена - %3 '  -- текст сообщения, подлежащий переводу
                           , pc_prm1  => cd_utl2s.num_to_str_dot(itrnnmum_in )
                           , pc_prm2  => cd_utl2s.num_to_str_dot(itrn_anum_in)
                           , pc_prm3  => ErrMsg );

      call cd_utl2s.txtOut( pc_ERRMSG_out );      

      -- call CDENV.SaveMessA( pc_ERRMSG_out,'E', userenv('SESSIONID'::varchar)::varchar, 'trn'::varchar, itrnnmum_in ); 

   end if;  
end;
$procedure$


/* */
CREATE PROCEDURE delete_event(IN pi_cde_evid numeric, IN pi_delwith_trn integer, OUT itotalerrors integer, OUT iresult_out integer, OUT vc_errmsg_out character varying)
AS
$procedure$
   #package
declare
   j_icdsletrnnum  numeric; -- идентификатор удаляемого документа (проводки) в ядре
   j_icdsletrnanum numeric;
   iresult_local   Integer := ci_SUCCESS;
   vc_EM_local     varchar; -- cd_types.TErrorString;
 begin

   If isDBMS then
      call cd_utl2s.TxtOut( 'CDces.Delete_Event.204: pi_cde_evid='||pi_cde_evid ||' pi_delwith_trn='||pi_delwith_trn );
   end if;

   IF pi_delWith_trn = 1 THEN
      begin
          Select CD_sle.icdsletrnnum, CD_sle.icdsletrnanum
            Into j_icdsletrnnum, j_icdsletrnanum 
            From CD_sle
           Where
                 CD_sle.icdsleeventid = pi_cde_Evid;
      exception
         when others then 
                iresult_out := ci_OTHER_ERROR;
              vc_ERRMSG_out := cd_errsupport.mk_ml2_etext_2000 ( 
                                    pc_source_id => 'CDces.Delete_Event.281:',  -- символьный идентификатор места возникновения ошибки... (общая длина не более 100 символов)
                                    pText => 'Ошибка: действие не найдено (возможно удалено другим пользователем): %1', 
                                    pc_prm1 => cd_errsupport.format_ora_errorstack );
         return;
       End;
   END IF;  
   
   delete from CD_sle where icdsleeventid = pi_cde_evid;
      
   IF pi_delwith_trn = 1 THEN --:is_del.is_trn=1 THEN -- "Включая удаление TRN-проводок"      
      
     If isDbms Then 
        call cd_utl2s.TxtOut('CDces.Delete_Event.227: before Del_Doc_Logical: j_icdsletrnnum='||j_icdsletrnnum ||' j_icdsletrnanum='||j_icdsletrnanum );     
     End If;
                  
     call CDces.del_Doc_Logical(
                  itrnnmum_in => j_icdsletrnnum--| идентификатор удаляемого документа (проводки) в ядре
                , itrn_anum_in => j_icdsletrnanum  --|
                , pi_result_out => iresult_local
                , pc_ERRMSG_out => vc_EM_local   -- текст сообщения об ошибке
          );
  
     If isDbms Then
        call cd_utl2s.TxtOut( concat('CDces.Delete_Event.240: after Del_Doc_Logical: iresult_local=', iresult_local::text,' vc_EM_local=', substr(vc_EM_local,1,2000) ) );
     End IF; 

   END IF;  

   iTotalErrors := 0;--CDENV.Get_CNTMess();

   IF iresult_local = ci_SUCCESS THEN  
      iresult_out := ci_SUCCESS;
   ELSE
      iresult_out   := ci_OTHER_ERROR;
      vc_ERRMSG_out := substr(vc_EM_local,1,2000);      
   END IF;

 Exception 
/*
   WHEN cd_errsupport.e_RBEVENT THEN
     iresult_out := ci_OTHER_ERROR;  
     iTotalErrors := CDENV.Get_CNTMess();
     vc_ERRMSG_out := substr(cd_errsupport.format_ora_errorstack(True),1,2000);  
*/
   WHEN OTHERS THEN
/*
      iTotalErrors := CDENV.Get_CNTMess();
      iresult_out  := ci_OTHER_ERROR;  
      vc_ERRMSG_out := cd_errsupport.mk_ml2_etext_2000( pc_source_id => 'cdeve_fpkg.Delete_Event.281:', pText => ' Ошибка при удалении действия: %1', pc_prm1  => cd_errsupport.format_ora_errorstack(true) );
*/
      DECLARE
         ex TS.T_StackedDiagnostics;
         cErrorMsg varchar := '';
      BEGIN
         GET STACKED DIAGNOSTICS 
          ex.RETURNED_SQLSTATE   = RETURNED_SQLSTATE, 
          ex.MESSAGE_TEXT        = MESSAGE_TEXT,
          ex.PG_EXCEPTION_DETAIL = PG_EXCEPTION_DETAIL,
          ex.PG_EXCEPTION_HINT   = PG_EXCEPTION_HINT,
          ex.PG_EXCEPTION_CONTEXT= PG_EXCEPTION_CONTEXT;
          cerrormsg := TS.WhenOthersError ('CDces.Delete_Event', ex);
          --call cdeve_fpkg.dbms_put('cdeve_fpkg.Delete_Event >> ОШИБКА: '||cerrormsg);  
          iresult_out   := ci_OTHER_ERROR;
          iTotalErrors  := CDENV.Get_CNTMess();
          vc_ERRMSG_out := substr(cerrormsg,1,2000);
      end;
END;
$procedure$


/* */
CREATE PROCEDURE generate_acc_cd2(IN key20_cb character, IN icd2otd numeric, IN icd2ter numeric, IN consacc character, IN cd2_list cd2[], IN rid_list character varying[])
AS 
$procedure$
declare
    l_cd2     CD2;
    l_ridList _varchar := $6;
    l_digits  numeric(10);
    l_consAcc varchar(250);

   l_tabParam _varchar;
   i int4 :=1;
 
    l_Ok boolean := false;

BEGIN

   raise debug 'generate_Acc: cnt=%', array_length($5,1);

    -- dbms_output.put_line('generate_Acc: cnt=' || l_cd2List.Count );
    if $1 = 'Y' then
      l_digits := 20;
    else
      l_digits := 0;
    end if;

    FOREACH l_cd2 IN ARRAY $5 
    LOOP
        l_ok  := false;
        -- l_cd2 := l_cd2List(i);
        if l_cd2.icd2BS2 is null then
           l_consAcc := 'Не задан БС2';
        elsif l_cd2.ccd2CUR IS NULL THEN
           l_consAcc := 'Не задана валюта';
        ELSIF l_cd2.ICD2CLIENT IS NULL THEN
           l_consAcc := 'Не задан номер клиента';
        ELSIF l_cd2.icd2FLAG = 0 THEN
            IF $4 = 'Y' THEN
               IF l_ConsAcc IS NULL THEN
                  l_ConsAcc := Account.Acc_By_Mask( l_cd2.ICD2MASKCODE,l_cd2.icd2BS2,l_cd2.ccd2CUR,$2,$3,NULL,NULL,NULL,l_cd2.ICD2CLIENT,NULL,NULL,NULL,NULL,NULL,NULL,l_digits,l_tabParam);
                END IF;
            ELSE
                l_ConsAcc := Account.Acc_By_Mask( l_cd2.ICD2MASKCODE,l_cd2.icd2BS2,l_cd2.ccd2CUR,$2,$3,NULL,NULL,NULL,l_cd2.ICD2CLIENT,NULL,NULL,NULL,NULL,NULL,NULL,l_digits,l_tabParam );
            END IF;
            l_ok := true;
        END IF;
        if l_ok then
           update cd2 set ccd2ACC = l_ConsAcc where cd2.rowid = $6[i];
        else
           update cd2 set ccd2COMMENT = l_ConsAcc where cd2.rowid = $6[i];
        end if;

      i := i + 1;

    END LOOP;
END;
$procedure$


/* */
CREATE FUNCTION get_delayrst(agrid numeric, part numeric, evdate date)
RETURNS 
   numeric
AS
$function$
   #package
-- Определить остаток отложенных
DECLARE
  RET date;
  Rst numeric := 0::numeric;
  SumDPmtDue numeric := 0::numeric;
  d_evDate date;
BEGIN

  SumDPmtDue := 0;

  d_evDate := coalesce(evDate,cd.Get_LsDate());

  SELECT SUM(mcdsSUM) INTO SumDPmtDue
  FROM CDSAS
  WHERE ncdsAGRID=AgrID AND icdsPART=Part AND ccdsTYPE IN('C')
        AND dcdsDATE <= d_evDate; 

  Rst := 0;  
  Rst := SumDPmtDue-CDState.Get_Evt_Sum(AgrID, Part, 734, d_evDate, null)-CDState.Get_Evt_Sum(AgrID, Part, 752, d_evDate, null); 

  IF Rst > 0 THEN
    RETURN Rst;
  ELSE
    RETURN 0;
  END IF;
END;
$function$


CREATE FUNCTION get_isces(p_agrid numeric)
 RETURNS boolean
 
AS $function$#package

declare
  Get_CDA CURSOR IS SELECT * FROM CDA WHERE ncdaAGRID=p_AgrID;
  CDA_Terms record; --Get_CDA%ROWTYPE;
  isCes BOOLEAN DEFAULT FALSE;
BEGIN
  OPEN Get_CDA; FETCH Get_CDA INTO CDA_Terms; CLOSE Get_CDA;
  IF CDA_Terms.icdaCes = 1::numeric THEN
    isCes:=TRUE;
  END IF;
RETURN isCes;
END;
$function$


/* */
CREATE FUNCTION get_isconsgpay(p_agrid numeric)
   RETURNS 
      numeric
AS
$function$
   #package
declare
   isConsGPay numeric := 0::numeric;
  --isPSKFBD   NUMBER := 0;
BEGIN
  /*SELECT NVL(SUM(mcda2agrsum),0), NVL(SUM(ncda2pskfbd_c),0) INTO isConsGPay, isPSKFBD
  FROM cda2
  WHERE ncda2agrid = p_AgrID;
  IF isConsGPay > 0 and cdState.Get_CD0_Params(137)=0 THEN -- было до 225575
    RETURN 1;
  ELSIF isPSKFBD=1 THEN
    RETURN 1;
  ELSE
    RETURN 0;
  END IF;*/
  isConsGPay := cdState.Get_CD0_Params(137)::numeric;
   
RETURN coalesce(isConsGPay,0::numeric);
END;
$function$


/* */
CREATE FUNCTION get_ispskfbd(p_agrid numeric)
   RETURNS 
      numeric
AS
$function$
   #package
declare
  isPSKFBD   numeric := 0;
BEGIN
  IF NOT cdces.Get_IsCes(p_AgrID) THEN RETURN 1::numeric; END IF; -- для выданных рассчитывать ПСК от даты выдачи=покупки   
  SELECT coalesce(ncda2pskfbd_c,0::numeric) INTO isPSKFBD
  FROM cda2
  WHERE ncda2agrid = p_AgrID;
  IF isPSKFBD = 1::numeric THEN
    RETURN 1::numeric;
  ELSE
    RETURN 0::numeric;
  END IF;
RETURN 0::numeric;
END;
$function$

CREATE FUNCTION cdces.get_monoagrnum(saleid numeric)
 RETURNS numeric
 
AS $function$
#package
declare
  AgrNum numeric:=0;
BEGIN
  IF cdces.Check_MonoAgrSl(SaleID) THEN SELECT NCDAAGRID INTO AgrNum from CDA_LINK_CDSALE where ICDSALEID=SALEID; END IF;
  Return AgrNum;  
END;
$function$


/* */
CREATE FUNCTION new_ces( 
      agrid numeric, 
      cd_sum numeric, 
      pay_sum numeric DEFAULT NULL::numeric, 
      mda_num numeric DEFAULT NULL::numeric, 
      CurCliNum numeric DEFAULT NULL::numeric, 
      curcliacc character varying DEFAULT NULL::character varying, 
      curstatus numeric DEFAULT 0, 
      pzid numeric DEFAULT NULL::numeric, 
      pdend date DEFAULT NULL::date, 
      pagrmnt character varying DEFAULT NULL::character varying, 
      pnumarchiv character varying DEFAULT NULL::character varying, 
      pdsign date DEFAULT NULL::date, 
      pdpurch date DEFAULT NULL::date, 
      pmpurch numeric DEFAULT NULL::numeric, 
      pdfirstpay date DEFAULT NULL::date, 
      pmfirstpay numeric DEFAULT NULL::numeric, 
      pdfirstpay_a date DEFAULT NULL::date, 
      pntimey numeric DEFAULT NULL::numeric, 
      pntimem numeric DEFAULT NULL::numeric, 
      pntimed numeric DEFAULT NULL::numeric, 
      pmisum numeric DEFAULT NULL::numeric, 
      pmosum numeric DEFAULT NULL::numeric, 
      pmoisum numeric DEFAULT NULL::numeric, 
      pmfasum numeric DEFAULT NULL::numeric, 
      pmfisum numeric DEFAULT NULL::numeric, 
      pmi2sum numeric DEFAULT NULL::numeric, 
      pmoi2sum numeric DEFAULT NULL::numeric, 
      pmbonsum numeric DEFAULT NULL::numeric, 
      pncestype numeric DEFAULT NULL::numeric, 
      pnkd numeric DEFAULT NULL::numeric, 
      
      pcowd character varying DEFAULT NULL::character varying,
      pcfr  character varying DEFAULT NULL::character varying,

      pprc numeric DEFAULT NULL::numeric, 
      pndtn_a numeric DEFAULT NULL::numeric, 
      pdoutfd date DEFAULT NULL::date
   )
RETURNS 
   character varying
AS 
   $function$
declare
   ErrMsg       VARCHAR :='OK';
   New_AgrZ_Res VARCHAR;
   cAnn  CDTERMS3.T_Ann_Calc;
   CheckSum     NUMERIC;
   DltSum       NUMERIC;
   CheckFrstSum NUMERIC;
   Cur_Act      VARCHAR(32);
   dEnd         DATE := PDEnd;
   NextPart     NUMERIC;
   AgrSUM       NUMERIC;
   ppDSign      DATE;
   NameAgr      VARCHAR(50);
   CheckIns     NUMERIC; 

   Get_MDA CURSOR 
   for  
      SELECT * FROM CD_MDA WHERE imdaNUM = MDA_NUM;

   -- MDA_Terms Get_MDA%ROWTYPE;
   MDA_Terms record;

BEGIN

   raise debug 'Starting New_Ces. with LSDate %, pDFirstPay_A=%', pDPurch::varchar, pDFirstPay_A::varchar;

   CheckIns := 0;

   call CD.Set_LSDate(pDPurch); -- для заявк и 136155

   ppDSign := coalesce( pDSign, CD.Get_LSDate() );

   IF NVL(pNTimeD,0)=0 AND NVL(pNTimeY,0)=0 AND NVL(pNTimeM,0)=0 THEN
      NULL;--dEnd := NULL;
   ELSIF NVL(pNTimeD,0)=0 THEN
      dEnd := ADD_MONTHS(ppDSign,NVL(pNTimeY,0)*12+NVL(pNTimeM,0));
   ELSE
      dEnd := ADD_MONTHS(ppDSign,NVL(pNTimeY,0)*12+NVL(pNTimeM,0))+ (pNTimeD - 1*cdEnv.Is_Include_EndDate);
   END IF;

  -- dbms_output.put_line('dEnd = '||dEnd);
   raise debug 'dEnd = %', dEnd::varchar;

   OPEN Get_MDA; 
      FETCH Get_MDA INTO MDA_Terms; 
         CLOSE Get_MDA;

   select case MDA_Terms.imdalinetype when 3 then CD_Sum when 4 then CD_Sum else pMPurch end into AgrSUM;
  
   if pMPurch = 0 /*and pMOSum > 0 */ then -- покупка полной просрочки по ОД
      AgrSUM := 1;
   end if;
   -- CDTerms.NewAgrZ( ... )
   New_AgrZ_Res := cdagr.NewAgrZ (AgrID, AgrSUM, Pay_Sum, MDA_Num, CurCliNum, CurCliAcc, CurStatus, pZID, dEnd, pAGRMNT, pNUMARCHIV, pPRC );

   --dbms_output.put_line('New_AgrZ_Res = '||New_AgrZ_Res);
   raise debug 'New_AgrZ_Res = %', New_AgrZ_Res;

   --  pMOSum приходит пустая, в формате есть суммы просрочки только по частям, общей нет  ---
   IF pMPurch = 0 /*AND pMOSum > 0*/ THEN AgrSUM :=1; END IF; -- для покупки полной просрочки по ОД

   if New_AgrZ_Res = 'OK' then
     update cda set /*dcdasigndate=pDPurch, mcdatotal=pMPurch,*/ icdaCes=1 where ncdaagrid=AgrID;
     -- commit work; Замена на autoCommit

   if MDA_Terms.imdalinetype in (3,4) then
      update cda set dcdalineend=pDEnd where ncdaagrid=AgrID;
      update cdh set ccdhCVAL=TO_CHAR(pDEnd,'DD.MM.YYYY') where ncdhagrid=AgrID AND ccdhTERM='DEND';
      -- commit work;
   end if;
  
   update cda2 set MCDA2SUM=pMPurch, MCDA2ISUM=pMISum, MCDA2OSUM=pMOSum, MCDA2OISUM=pMOISum, MCDA2FASUM=pMFASum, MCDA2FISUM=pMFISum, MCDA2I2SUM=pMI2Sum, MCDA2OI2SUM=pMOI2Sum,
                  MCDA2BONSUM=pMBONSum, CCDA2OWD_L=pCOWD, MCDA2AGRSUM=CD_Sum, DCDA2AGRDATE=pDSign,
                  ICDA2SUMFR=NVL(SUBSTR(pcFR,1,1),0), ICDA2IFR=NVL(SUBSTR(pcFR,3,1),0), ICDA2OFR=NVL(SUBSTR(pcFR,2,1),0), ICDA2OIFR=NVL(SUBSTR(pcFR,4,1),0), ICDA2I2FR=NVL(SUBSTR(pcFR,5,1),0), 
                  ICDA2OI2FR=NVL(SUBSTR(pcFR,6,1),0), ICDA2FAFR=NVL(SUBSTR(pcFR,7,1),0), ICDA2FIFR=NVL(SUBSTR(pcFR,8,1),0), ICDA2CFR=NVL(SUBSTR(pcFR,9,1),0),
                  NCDA2DTN_A=pNDTN_A, 
                  DCDA2OUTFDATE_C=pDOUTFD  
                  where ncda2agrid=AgrID;

   IF pNCesType IN(1,2) THEN call CD.Update_History(AgrID::numeric, 1::numeric, 'DISCRATE', pDPurch, NULL::numeric, pNKD::numeric, pNCesType, NULL::varchar, null::int8 ); END IF;
        --IF NVL(pMBONSum,0)>0 THEN CD.Update_History(AgrID, 1, 'DISCRATE', pDPurch, NULL, NULL, 2, NULL); END IF;
        -- commit work;
   
     --(20 0324)
      if pAGRMNT is null then
         NameAgr := cdterms.ResetNameAgr(AgrID);
         update cda set ccdaagrmnt = NameAgr where ncdaagrid=AgrID;
         -- commit work;
      end if;
     --end(20 0324)
                        
      if pMPurch = 0 /*and pMOSum > 0 */ then -- покупка полной просрочки по ОД
         
         update cdp_i set mcdpsum = 0  where ncdpAgrID = AgrID;
         delete from cdr_i  where ncdrAgrID = AgrID;

         insert into cdr_i(ncdragrid, icdrpart, mcdrsum, dcdrdate, dcdrexist) values(AgrID, 1, 0, to_date(pDPurch), to_date('01.01.1901') ) ;

         update cda set mcdatotal=0, dcdalineend=pDPurch where ncdaagrid=AgrID;
         update cdh set ccdhCVAL=TO_CHAR(pDPurch,'DD.MM.YYYY') where ncdhagrid=AgrID AND ccdhTERM='DEND';
         --commit work;
      end IF;
     
     -- dbms_output.put_line('Finished New_Ces. New Agreement N='||AgrID);
      raise debug 'Finished New_Ces. New Agreement N=%', AgrID;

      return New_AgrZ_Res;

   else

      -- dbms_output.put_line(' ERROR - '||SQLERRM);
      raise debug ' ERROR - %', 'SQLERRM';

      if New_AgrZ_Res is NULL then

         --dbms_output.put_line(' Функция CDTerms.NewAgrZ вернула ПУСТОЕ значение!');
         raise debug 'Функция CDTerms.NewAgrZ вернула ПУСТОЕ значение!';
       
         begin
            select ncdaagrid into CheckIns from cda where ncdaagrid = AgrID;
            -- dbms_output.put_line(' Договор New Agreement N='||AgrID||' есть в базе'); 
            raise debug ' Договор New Agreement N=% есть в базе', AgrID;

            update cda set /*dcdasigndate=pDPurch, mcdatotal=pMPurch,*/ icdaCes=1 where ncdaagrid=AgrID;
            IF pNCesType IN(1,2) THEN call CD.Update_History(AgrID, 1, 'DISCRATE', pDPurch, NULL, pNKD, pNCesType, NULL); END IF; -- 246922
            -- commit work;
         exception 
            when no_data_found then 
                 null;
         end;
   
         if CheckIns > 0 then 
            -- dbms_output.put_line(' Договор New Agreement N='||AgrID||' помечен как приобретение прав');  
            raise debug ' Договор New Agreement N=% помечен как приобретение прав', AgrID;
            return 'OK';
         else
            return 'Пустое значение от NewAgrZ';  
         end if;  
      end if; 

     return New_AgrZ_Res; 

   end if;

END;
$function$


/* */
CREATE FUNCTION new_ces_part(newpart cdces.part_details)
 RETURNS character varying
 
AS $function$
   #package
declare

   ErrMsg VARCHAR(256);
   ErM    VARCHAR(256);
   ErTxt  VARCHAR(20);
   IsLine NUMERIC;

   Get_CDA CURSOR 
   FOR 
   SELECT * FROM CDA join CDA2 on cda.ncdaAGRID = cda2.ncdaAGRID WHERE cda.ncdaAGRID=NewPart.Agrid;

   CDA_Terms Record;

BEGIN
   
   ErM := 'OK';

   OPEN Get_CDA; 
      FETCH Get_CDA INTO CDA_Terms; 
         CLOSE Get_CDA;

   raise debug 'Обработка части № %', NewPart.Part;

   IF ( (coalesce(NewPart.pMSum,0)+coalesce(NewPart.pMI,0)+coalesce(NewPart.pMO,0)+coalesce(NewPart.pMOI,0)+coalesce(NewPart.pMFA,0)+coalesce(NewPart.pMFI,0)+coalesce(NewPart.pMI2,0)+coalesce(NewPart.pMOI2,0)+coalesce(NewPart.pMC,0) > 0)
     or 
     NewPart.pISPROL = 1) 
   THEN --(21 0921)

      if NewPart.Part>1 then
         if  NewPart.pDbeg is null then return 'Не задана дата начала части';
         elsif NewPart.pDend is null then return 'Не задана дата окончания части';
         elsif NewPart.pMSum is null then return 'Не задана сумма части';
      end if;

     ErM:= CDAgr.Create_New_Part( NewPart.Agrid, -- договор
                                  NewPart.Part,  -- номер нового транша
                                  NewPart.pMSum, -- сумма
                                  NewPart.pDbeg, -- дата открытия
                                  NewPart.pDend, -- дата возврата
                                  ErrMsg,        -- сообщение об ошибке
                                  null, -- флаг "Вставлять дату окончания в график уплаты %" 0 - нет, 1 - да, null - по параметру договора
                                  NewPart.pPI,   -- индивидуальная ставка по траншу
                                  NewPart.pISPROL  -- флаг "транш-пролонгция"  --(21 0921)
                                   );
      IF ErM = 'OK' THEN
         RAISE DEBUG 'Часть № % создана', NewPart.Part;
      ELSE
         RETURN coalesce(nullif(ErrMsg, ''), ErM);
      END IF;

   end if;

   if NewPart.Part=1 and CDA_Terms.icdaIsLine in(3,4) then

      INSERT INTO  CDP_I ( NCDPAGRID, ICDPPART, DCDPDATE, MCDPSUM )
                   VALUES(NewPart.Agrid, 1, NewPart.pDbeg, NewPart.pMSum);
        INSERT INTO  CDR_I ( NCDRAGRID, ICDRPART , DCDRDATE, DCDRLATEST, MCDRSUM )
                   VALUES(NewPart.Agrid, 1, NewPart.pDend, NewPart.pDend, NewPart.pMSum);

   end if;

     IF ErM = 'OK' THEN

       raise debug 'NewPart.Agrid=%, NewPart.Part=%, NewPart.pMSum=%, NewPart.pMI=%, NewPart.pMO=%, NewPart.pMOI=%, NewPart.pMFA=%, NewPart.pMFI=%, NewPart.pMI2=%, NewPart.pMOI2=%, NewPart.pMC=%, NewPart.pNNDO=%',
                    NewPart.Agrid, NewPart.Part, NewPart.pMSum, NewPart.pMI, NewPart.pMO, NewPart.pMOI, NewPart.pMFA, NewPart.pMFI, NewPart.pMI2, NewPart.pMOI2, NewPart.pMC, NewPart.pNNDO;

       INSERT INTO xxi.cdq2(  ncdq2agrid,     icdq2part,    mcdq2sum_c,    mcdq2i_c,    mcdq2o_c,    mcdq2oi_c,    mcdq2fa_c,    mcdq2fi_c,    mcdq2i2_c,    mcdq2oi2_c,    mcdq2c_c,    ncdq2ndo_c,    ncdq2ndoi_c,    ncdq2ndoio_c,   mcdq2icalc_c)
                 VALUES(NewPart.Agrid, NewPart.Part, NewPart.pMSum, NewPart.pMI, NewPart.pMO, NewPart.pMOI, NewPart.pMFA, NewPart.pMFI, NewPart.pMI2, NewPart.pMOI2, NewPart.pMC, NewPart.pNNDO, NewPart.pNNDOI, NewPart.pNNDOIO, NewPart.pNICLC );

       -- commit work;

       if NewPart.pPI is not null then
           --UPDATE CDH SET PCDHPVAL=NewPart.pPI
             --WHERE NCDHAGRID=NewPart.Agrid and ICDHPART=NewPart.Part and DCDHDATE=NewPart.pDbeg and CCDHTERM='INTRATE';
         call CDTerms.Update_History(NewPart.Agrid,NewPart.Part,'INTRATE',NewPart.pDbeg,NULL,NewPart.pPI,NULL,NULL,NULL);
         end if;
       if NewPart.pPFA is not null then
           --UPDATE CDH SET PCDHPVAL=NewPart.pPFA
             --WHERE NCDHAGRID=NewPart.Agrid and ICDHPART=NewPart.Part and DCDHDATE=NewPart.pDbeg and CCDHTERM='LOANFINE';
         call CDTerms.Update_History(NewPart.Agrid,NewPart.Part,'LOANFINE',NewPart.pDbeg,NULL,NewPart.pPFA,NULL,NULL,NULL);
         end if;
       if NewPart.pPFI is not null then
           --UPDATE CDH SET PCDHPVAL=NewPart.pPFI
             --WHERE NCDHAGRID=NewPart.Agrid and ICDHPART=NewPart.Part and DCDHDATE=NewPart.pDbeg and CCDHTERM='INTFINE';
         call CDTerms.Update_History(NewPart.Agrid,NewPart.Part,'INTFINE',NewPart.pDbeg,NULL,NewPart.pPFI,NULL,NULL,NULL);
         end if;
       if NewPart.pPFI2 is not null then
         call CDTerms.Update_History(NewPart.Agrid,NewPart.Part,'INTFINE2',NewPart.pDbeg,NULL,NewPart.pPFI2,NULL,NULL,NULL);
         end if;  
       if NewPart.pPIO is not null then
           call CDTerms.Update_History(NewPart.Agrid,NewPart.Part,'OVDRATE',NewPart.pDbeg,NULL,NewPart.pPIO,NULL,NULL,NULL);
         end if;
       
        --commit work;

     ELSE 
         RETURN ErrMsg;
     END IF;
   ELSE
      raise debug 'Часть № % нет выкупленных сумм', NewPart.Part;
      -- dbms_output.put_line('Часть №'||NewPart.Part||' нет выкупленных сумм');
   END IF;

   RETURN 'OK';

END;
$function$


/* */
CREATE FUNCTION normalize_date( p_dateStr character varying )
   RETURNS 
      character varying
AS
$function$
   #package
declare
   l_dateStr VARCHAR(20) := trim  ($1);
   l_len     INT4        := LENGTH(l_dateStr);
   l_dt      DATE;
BEGIN

   BEGIN

      IF l_dateStr IS NULL THEN
         RETURN NULL;
      END IF;

      IF l_len > 10 THEN
         l_dateStr := SUBSTR( l_dateStr, 1, 10 );
         l_len     := LENGTH( l_dateStr );
      END IF;

      IF l_len NOT IN (10,8) THEN
         RAISE exception data_exception;
      END IF;

      IF l_len = 10 THEN

         IF REGEXP_LIKE( l_dateStr, '\d{4}-\d{2}-\d{2}' ) THEN
            l_dt := TO_DATE( l_dateStr, 'YYYY-MM-DD' );
         ELSIF REGEXP_LIKE( l_dateStr, '\d{2}\.\d{2}\.\d{4}' ) THEN
            l_dt := TO_DATE( l_dateStr, 'DD.MM.YYYY' );
         END IF;

      ELSE
         IF REGEXP_LIKE( l_dateStr, '\d{2}-\d{2}-\d{2}' ) THEN
            l_dt := TO_DATE( l_dateStr, 'YY-MM-DD' );
         ELSIF REGEXP_LIKE( l_dateStr, '\d{2}\.\d{2}\.\d{2}' ) THEN
            l_dt := TO_DATE( l_dateStr, 'DD.MM.YY' );
         END IF;
      END IF;

      IF l_dt IS NULL THEN
         RAISE exception data_exception;
      END IF;

      RETURN TO_CHAR( l_dt, 'DD.MM.YYYY' );

   EXCEPTION
      WHEN OTHERS THEN
         raise debug 'Error in normalize_Date, bad value for input "dateStr" parameter: "%. %',  $1 , SQLERRM;
      RAISE;
   END;
END;
$function$


/* */
CREATE PROCEDURE populate_cdt(OUT ret character varying, OUT errmsg character varying, IN docdate date, IN regdate date, IN valdate date, IN saleid numeric)
AS
$procedure$
   #package
declare 
   PURP       VARCHAR(1024);
   PP         VARCHAR(20);
   retMsg     VARCHAR(20) := 'OK';        
   Base_Cur   CHAR(3);
   ACCC       VARCHAR;
   ACCD       acc.caccACC%TYPE;
   CURD       acc.caccCUR%TYPE;
   CURC       acc.caccCUR%TYPE;
   CusNAME    cus.ccusname%TYPE;
   SUMD       NUMERIC;
   SUMC       NUMERIC;
   Op_Type    NUMERIC(2);
   SubOp_Type NUMERIC(2);

   rec_CDT   CDT; 

   Get_Act CURSOR 
   for 
      -- SELECT LEVEL Type_Act FROM DUAL CONNECT BY LEVEL < 6;
      SELECT generate_series(1,5) Type_Act;

   Get_Sale CURSOR  
   for 
      SELECT CDSale.* FROM CDSale WHERE icdsaleID = $6;

   Sale_Terms record;

   Get_CDA CURSOR (AgrID NUMERIC) 
   for 
      SELECT CDA.* FROM CDA,CUS  WHERE ncdaAgrID = AgrID;

  CDA_Terms record;

  Date_Act DATE  := CD.Get_LSDate();

  SumAct1 NUMERIC := 0;
  SumAct2 NUMERIC := 0;
  SumAct5 NUMERIC := 0;

  Sale_Acc_Rst NUMERIC := 0;
  Obl_Acc_Rst NUMERIC := 0;
  Req_Acc_Rst NUMERIC := 0;

BEGIN

   call CDCes.cap_Message( TO_CHAR(CURRENT_TIMESTAMP,'DD.MM.YY HH:MI:SS')||CHR(10)|| 'Кредиты XXI. Портфели ПРОДАЖ.'||CHR(10)|| 'Протокол заполнения реестра возможных документопроводок.'||CHR(10)|| 'Портфель '||SaleID||CHR(10) );

   PP:=concat(' по портфелю №',SaleID);

   Base_Cur := UTIL.Get_Base_Cur();
    
   OPEN Get_Sale;
      FETCH Get_Sale INTO Sale_Terms;
         CLOSE Get_Sale;
    
   SELECT coalesce(sum(mcdsleSUM), 0) INTO SumAct1 FROM CD_SLE WHERE icdsleTYPE = 1 AND icdsleID = SaleID;
   SELECT coalesce(sum(mcdsleSUM), 0) INTO SumAct2 FROM CD_SLE WHERE icdsleTYPE = 2 AND icdsleID = SaleID;
   SELECT coalesce(sum(mcdsleSUM), 0) INTO SumAct5 FROM CD_SLE WHERE icdsleTYPE = 5 AND icdsleID = SaleID;
  
   IF Sale_Terms.CCDSALEOBLACC IS NOT NULL THEN
      Obl_Acc_Rst:= ABS(UTIL_DM2.Acc_Ost(0,Sale_Terms.CCDSALEOBLACC,Sale_Terms.CCDSALEOBLCUR,Date_Act+1,'V'));
      -- INSERT INTO CAP(ccapMESSAGE) VALUES('Счет обязательств '||Sale_Terms.CCDSALEOBLACC||' остаток '||to_char(Obl_Acc_Rst)||CHR(10));
      call CDCes.cap_Message( 'Счет обязательств % остаток %'::varchar, Sale_Terms.CCDSALEOBLACC, to_char(Obl_Acc_Rst) );
   END IF; 

   IF Sale_Terms.CCDSALEACC IS NOT NULL THEN
      Sale_Acc_Rst := UTIL_DM2.Acc_Ost(0,Sale_Terms.CCDSALEACC,Sale_Terms.CCDSALECUR,Date_Act+1,'V');
      -- INSERT INTO CAP(ccapMESSAGE) VALUES('Счет продажи '||Sale_Terms.CCDSALEACC||' остаток '||to_char(Sale_Acc_Rst)||CHR(10));
      call CDCes.cap_Message( 'Счет продажи '||Sale_Terms.CCDSALEACC||' остаток '||to_char(Sale_Acc_Rst)||CHR(10) );
   END IF; 

   IF Sale_Terms.CCDSALEREQACC IS NOT NULL THEN
      Req_Acc_Rst := ABS(UTIL_DM2.Acc_Ost(0,Sale_Terms.CCDSALEREQACC,Sale_Terms.CCDSALEREQCUR,Date_Act+1,'V'));
      -- INSERT INTO CAP(ccapMESSAGE) VALUES('Счет требований '||Sale_Terms.CCDSALEREQACC||' остаток '||to_char(Req_Acc_Rst)||CHR(10));
      call CDCes.cap_Message( 'Счет требований '||Sale_Terms.CCDSALEREQACC||' остаток '||to_char(Req_Acc_Rst)||CHR(10) );
   END IF;  

   IF Sale_Terms.mcdsaleWSUM IS NOT NULL THEN
      -- INSERT INTO CAP(ccapMESSAGE) VALUES('Ожидаемая от контрагента сумма '||to_char(Sale_Terms.mcdsaleWSUM)||CHR(10));
      call CDCes.cap_Message( 'Ожидаемая от контрагента сумма '||to_char(Sale_Terms.mcdsaleWSUM)||CHR(10) );
   ELSE  
      -- INSERT INTO CAP(ccapMESSAGE) VALUES('Ожидаемая от контрагента сумма не задана.'||CHR(10));  
      call CDCes.cap_Message( 'Ожидаемая от контрагента сумма не задана.'||CHR(10) );
   END IF;
 
   FOR Cur_Act IN Get_Act LOOP
    
      CusNAME := NULL;
    
      IF Cur_Act.Type_Act = 1 
      THEN -- 'Уступка прав требования на счет обязательств'

         ACCD:=NULL; CURD:=NULL; ACCC:=NULL; CURC:=NULL; PURP:=NULL; SUMD:=0; SUMC:=0;
         rec_CDT.mcdtEVTSUM:= 0;

         SELECT ccusNAME INTO CusNAME FROM CUS WHERE icusNUM = Sale_Terms.icdSALECUS;

         PURP := concat('Уступка прав требования по Договору уступки прав требования(Цессии), заключенному с ',CusNAME,' №',Sale_Terms.CCDSALENUM,' от',Sale_Terms.DCDSALEDATE,'г.');--'Уступка прав требования на счет обязательств'||PP;

      IF cdces.Check_MonoAgrSl(SaleID) 
      THEN 
         OPEN Get_CDA(cdces.Get_MonoAgrNum(SaleID)); 
            FETCH Get_CDA INTO CDA_Terms; 
               CLOSE Get_CDA;
        IF CDA_Terms.icdaCES = 1 THEN
          CusNAME := NULL;
          SELECT ccusNAME INTO CusNAME FROM CUS WHERE icusNUM = CDA_Terms.icdaCLIENT;
          PURP := concat('Уступка прав требования по Договору обратного выкупа (купли-продажи) № ',Sale_Terms.CCDSALENUM,' от ',Sale_Terms.DCDSALEDATE,' закладной ',CusNAME,' договор № ',CDA_Terms.ccdaAGRMNT,' от ',CDA_Terms.dcdaSIGNDATE,' г.') ;
        END IF;
      END IF;

      ACCD:= Sale_Terms.CCDSALEOBLACC; CURD:= Sale_Terms.CCDSALEOBLCUR;
      ACCC:= Sale_Terms.CCDSALEACC; CURC:= Sale_Terms.CCDSALECUR;
      IF SumAct1 = 0 AND SumAct2 = 0 THEN  
        IF Obl_Acc_Rst > 0 THEN 
          IF coalesce(PREF.Get_Preference(USER::varchar,'CHECKWSUM'),'FALSE')='FALSE' THEN 
            SUMD:= Obl_Acc_Rst; SUMC:= SUMD;
            rec_CDT.mcdtEVTSUM:= SUMD; rec_CDT.ccdtEVTCUR:=CURD;
          ELSE

            IF  Obl_Acc_Rst >= Sale_Terms.mcdsaleWSUM THEN -- 234980
              SUMD:= Sale_Terms.mcdsaleWSUM; SUMC:= SUMD;  -- 237218
              rec_CDT.mcdtEVTSUM:= SUMD; rec_CDT.ccdtEVTCUR:=CURD;
            ELSE
              -- INSERT INTO CAP(ccapMESSAGE) VALUES(PURP||' - остаток на счете обязательств меньше ожидаемой от контрагента суммы'||CHR(10));
               call CDCes.cap_Message( PURP ||' - остаток на счете обязательств меньше ожидаемой от контрагента суммы'||CHR(10) );
               retMsg := 'ERROR';

            END IF;    

          END IF;

        END IF;

      END IF;    
      
   ELSIF Cur_Act.Type_Act = 2 
   THEN  -- 'Уступка прав требования на счет требований'
      ACCD:=NULL; CURD:=NULL; ACCC:=NULL; CURC:=NULL; PURP:=NULL; SUMD:=0; SUMC:=0;
      rec_CDT.mcdtEVTSUM:= 0;
      SELECT ccusNAME INTO CusNAME FROM CUS WHERE icusNUM = Sale_Terms.icdSALECUS; 
      PURP := 'Уступка прав требования по Договору уступки прав требования(Цессии), заключенному с '||CusNAME||' №'||Sale_Terms.CCDSALENUM||' от'||Sale_Terms.DCDSALEDATE||'г.';--'Уступка прав требования на счет требований'||PP;
      ACCD:= Sale_Terms.CCDSALEREQACC; CURD:= Sale_Terms.CCDSALEREQCUR;
      ACCC:= Sale_Terms.CCDSALEACC; CURC:= Sale_Terms.CCDSALECUR;
      IF SumAct2 = 0 AND SumAct1 = 0 THEN  
        IF Sale_Terms.mcdsaleWSUM > 0 AND Sale_Terms.mcdsaleWSUM > Obl_Acc_Rst THEN -- 237260
          SUMD:= Sale_Terms.mcdsaleWSUM; SUMC:= SUMD; 
          rec_CDT.mcdtEVTSUM:= SUMD; rec_CDT.ccdtEVTCUR:=CURD;
        END IF; 
      END IF;   
      
    ELSIF Cur_Act.Type_Act IN (3,4) THEN 
      ACCD:=NULL; CURD:=NULL; ACCC:=NULL; CURC:=NULL; PURP:=NULL; SUMD:=0; SUMC:=0;
      rec_CDT.mcdtEVTSUM:= 0;
      IF CDCes.Check_MonoAgrSl(SaleID) THEN
        OPEN Get_CDA(CDCes.Get_MonoAgrNum(SaleID)); FETCH Get_CDA INTO CDA_Terms; CLOSE Get_CDA;
        SELECT ccusNAME INTO CusNAME FROM CUS WHERE icusNUM = CDA_Terms.icdaCLIENT;
        PURP := 'Финансовый результат на основании договора обратного выкупа (купли-продажи) №'||Sale_Terms.CCDSALENUM||' от '||Sale_Terms.DCDSALEDATE||' (закладной '||CusNAME||' договор № '||CDA_Terms.ccdaAGRMNT||' от '||CDA_Terms.dcdaSIGNDATE||' г.)';
      ELSE
        SELECT ccusNAME INTO CusNAME FROM CUS WHERE icusNUM = Sale_Terms.icdSALECUS;
        PURP := 'Финансовый результат от уступки прав требования по Договору уступки прав требования(Цессии), заключенному с '||CusNAME||' №'||Sale_Terms.CCDSALENUM||' от'||Sale_Terms.DCDSALEDATE||'г.';--'Отражение финансового результата'||PP;   
      END IF;
     -- IF Cur_Act.Type_Act = 3 THEN PURP := PURP||' (доход)'; END IF;
     -- IF Cur_Act.Type_Act = 4 THEN PURP := PURP||' (расход)'; END IF;
      
      ACCD:= Sale_Terms.CCDSALEACC; ACCC:= Sale_Terms.CCDSALEACC;
      
      IF SumAct1 + SumAct2 > 0 THEN
                        
        IF Sale_Acc_Rst < 0 AND Cur_Act.Type_Act = 3 THEN 
          ACCD:= Sale_Terms.CCDSALEACC; CURD:= Sale_Terms.CCDSALECUR;
          ACCC:= Sale_Terms.CCDSALEINACC; CURC:= Sale_Terms.CCDSALEINCUR;
          SUMD:= - Sale_Acc_Rst; SUMC:= SUMD;
          rec_CDT.mcdtEVTSUM:= SUMD; rec_CDT.ccdtEVTCUR:=CURD;
        ELSIF Sale_Acc_Rst > 0  AND Cur_Act.Type_Act = 4 THEN
          ACCD:= Sale_Terms.CCDSALEOUTACC; CURD:= Sale_Terms.CCDSALEOUTCUR;
          ACCC:= Sale_Terms.CCDSALEACC; CURC:= Sale_Terms.CCDSALECUR;
          SUMD:= Sale_Acc_Rst; SUMC:= SUMD;
          rec_CDT.mcdtEVTSUM:= SUMC; rec_CDT.ccdtEVTCUR:=CURC;
        END IF;  
      END IF;  
    ELSIF Cur_Act.Type_Act = 5 THEN
      ACCD:=NULL; CURD:=NULL; ACCC:=NULL; CURC:=NULL; PURP:=NULL; SUMD:=0; SUMC:=0;
      rec_CDT.mcdtEVTSUM:= 0; 
      PURP := 'Урегулирование парных счетов'||PP;
      ACCD:= Sale_Terms.CCDSALEOBLACC; CURD:= Sale_Terms.CCDSALEOBLCUR;
      ACCC:= Sale_Terms.CCDSALEREQACC; CURC:= Sale_Terms.CCDSALEREQCUR;
       
      IF SumAct2 > 0 AND Sale_Terms.mcdsaleWSUM > 0  AND Obl_Acc_Rst > 0 AND SumAct5 = 0 THEN
         IF Obl_Acc_Rst = Sale_Terms.mcdsaleWSUM THEN
          rec_CDT.mcdtEVTSUM:= Obl_Acc_Rst;
          SUMD:= rec_CDT.mcdtEVTSUM; SUMC:= SUMD;
         ELSE
          --  INSERT INTO CAP(ccapMESSAGE) VALUES(PURP||' - остаток на счете обязательств не совпадает с ожидаемой от контрагента суммой'||CHR(10));
            call CDCes.cap_Message( PURP||' - остаток на счете обязательств не совпадает с ожидаемой от контрагента суммой'||CHR(10) );
            retMsg := 'ERROR';
         END IF;    
      END IF;   
   END IF;
  
      IF ACCD IS NULL THEN
        -- INSERT INTO CAP(ccapMESSAGE) VALUES(PURP||' - не найден счет дебета!!!'||CHR(10));
         call CDCes.cap_Message( PURP||' - не найден счет дебета!!!'||CHR(10) );
         retMsg := 'ERROR';
      ELSIF ACCC IS NULL THEN
         --INSERT INTO CAP(ccapMESSAGE) VALUES(PURP||' - не найден счет кредита!!!'||CHR(10));
         call CDCes.cap_Message( PURP||' - не найден счет кредита!!!'||CHR(10) );
         retMsg := 'ERROR';
      ELSIF rec_CDT.mcdtEVTSUM = 0 THEN
         -- INSERT INTO CAP(ccapMESSAGE) VALUES(PURP||' - нет остатка для формирования действия!!!'||CHR(10));
         call CDCes.cap_Message( PURP||' - нет остатка для формирования действия!!!'||CHR(10) );
         retMsg := 'ERROR';
      ELSE

      rec_CDT := null;
      rec_CDT.ccdtaccd := ACCD;
      rec_CDT.ccdtaccc := ACCC;
      rec_CDT.Icdtbatnum  := 0;
      rec_CDT.Icdtsubtype := NULL;
      --rec_CDT.Dcdtdfrom := ;
      --rec_CDT.Dcdtdto := ;
      rec_CDT.Ccdttype_Label := Cur_Act.Type_Act;
        
      Op_Type    := 1;
      SubOp_Type := NULL;
        
      ------------->>
      INSERT INTO CDT ( ncdtAGRID, icdtPART, ccdtTYPE_LABEL, icdtSUBTYPE,
                       ccdtACCD, ccdtCURD, ccdtACCC, ccdtCURC, mcdtSUMD, mcdtSUMC, mcdtEVTSUM, ccdtEVTCUR, icdtTOP, icdtSOP,
                       icdtBATNUM, icdtDOCNUM, icdtPRIORITY, ccdtDWAY,
                       ccdtPURP,
                       ccdtMFOA, ccdtCORACCA, ccdtBNAMEA, ccdtACCA, ccdTOWNA, ccdtINNA,
                       dcdtDOC, dcdtCREATE, dcdtVAL, dcdtACTION, NCDTCZO,
                       Ccdtvo -- (143324)
                       )
              VALUES ( SaleID, 1, Cur_Act.Type_Act, NULL,
                       ACCD, CURD, ACCC, CURC, SUMD, SUMC, /*rec_CDT.mcdtEVTSUM*/SUMD, rec_CDT.ccdtEVTCUR, Op_Type, SubOp_Type,
                       rec_CDT.icdtbatnum, SaleID, null, null,
                       Purp/*||TO_CHAR(Cur_CD1.ncd1AGRID)*/,
                       null, null, null, null, null, null,
                       DocDate, RegDate, ValDate, RegDate/*Date_Act 243522*/, NULL,
                       rec_CDT.Ccdtvo
                       );
      END IF;

   END LOOP;

   --COMMIT;

   $1 := retMsg;

END;
$procedure$


/* */
CREATE PROCEDURE recalc_cdoces(IN agrid numeric, IN datefrom date, IN do_commit boolean DEFAULT true)
AS 
   $procedure$
DECLARE
    NewOvd   NUMERIC :=0;
    RestPmnt NUMERIC :=0;

    All_Parts CURSOR 
    for
    SELECT icdqPART Num
        FROM xxi.CDQ
            WHERE ncdqAGRID=$1
                ORDER BY Num;

    A_Pmnt CURSOR (vPart NUMERIC) 
    for
    SELECT dcdedate, mcdesum 
        FROM xxi.CDE 
            WHERE ncdeAgrID=$1 AND icdePart=vPart AND icdeTYPE=722 
                order by dcdedate;

    I_Pmnt CURSOR (vPart NUMERIC)
    FOR
    SELECT dcdedate, mcdesum 
        FROM xxi.CDE 
            WHERE ncdeAgrID=$1 AND icdePart=vPart  AND icdeTYPE=726 
                order by dcdedate;

    O_Pmnt CURSOR (vPart NUMERIC) 
    FOR
    SELECT dcdedate, mcdesum 
        FROM xxi.CDE 
            WHERE ncdeAgrID=$1 AND icdePart=vPart AND icdeTYPE=736 
                order by dcdedate;

    Get_CDOCES CURSOR (O_Type CHAR,vPart NUMERIC) 
    FOR
    SELECT * FROM xxi.CD_CDO_CES O1
        WHERE ncdocesAGRID=AgrID AND icdocesPART=vPart AND ccdocesTYPE=O_Type 
          AND dcdocesDATE = (SELECT MAX(dcdocesDATE) FROM CD_CDO_CES O2 WHERE O2.ncdocesAGRID=O1.ncdocesAGRID AND O2.icdocesPART=O1.icdocesPART AND O2.dcdocesSTART=O1.dcdocesSTART AND O2.ccdocesTYPE=O1.ccdocesTYPE )
          AND mcdocesOVERDUE > 0
            ORDER BY dcdocesSTART;
BEGIN

    DELETE FROM CD_CDO_CES WHERE ncdocesAGRID=$1 AND dcdocesDATE>$2;

    FOR Cur_Part IN All_Parts 
    LOOP

        RestPmnt := 0;

        FOR Cur_Pmnt IN A_Pmnt(Cur_Part.Num) 
        LOOP

-- DBMS_OUTPUT.put_line('!!! CD_CDO_CES !!! Cur_Pmnt.Mcdesum = '||Cur_Pmnt.Mcdesum||' Cur_Pmnt.dcdedate = '||Cur_Pmnt.dcdedate );
RAISE DEBUG '!!! CD_CDO_CES !!! Cur_Pmnt.Mcdesum = %,  Cur_Pmnt.dcdedate = % ', Cur_Pmnt.Mcdesum::varchar, Cur_Pmnt.dcdedate::varchar; 

            RestPmnt := Cur_Pmnt.Mcdesum;
            FOR Cur_Ovd IN Get_CDOCES('A',Cur_Part.Num) 
            LOOP
        
        -- DBMS_OUTPUT.put_line('!!! CD_CDO_CES !!! Cur_Ovd.Mcdocesoverdue = '||Cur_Ovd.Mcdocesoverdue );
        
                NewOvd := GREATEST(0,Cur_Ovd.Mcdocesoverdue - RestPmnt);
                RestPmnt := RestPmnt - Cur_Ovd.Mcdocesoverdue;
        
        --DBMS_OUTPUT.put_line('!!! CD_CDO_CES !!! NewOvd = '||NewOvd );
                RAISE DEBUG '!!! CD_CDO_CES !!! NewOvd = %', NewOvd::varchar; 
        
                INSERT INTO xxi.CD_CDO_CES(ncdocesagrid,  icdocespart,         dcdocesstart,       dcdocesdate, ccdocestype, mcdocesoverdue )
                    VALUES( $1, Cur_Part.Num, Cur_Ovd.dcdocesSTART, Cur_Pmnt.dcdeDate+1,         'A',         NewOvd );
        
                EXIT WHEN RestPmnt <=0;
    
            END LOOP;
        END LOOP;

        RestPmnt := 0;
    
        FOR Cur_Pmnt IN I_Pmnt(Cur_Part.Num) 
        LOOP
    
            RestPmnt := Cur_Pmnt.Mcdesum;
    
            FOR Cur_Ovd IN Get_CDOCES('I',Cur_Part.Num) 
            LOOP
    
                NewOvd   := GREATEST( 0, Cur_Ovd.Mcdocesoverdue - RestPmnt);
                RestPmnt := RestPmnt - Cur_Ovd.Mcdocesoverdue;
    
                INSERT INTO xxi.CD_CDO_CES( ncdocesagrid, icdocespart, dcdocesstart, dcdocesdate, ccdocestype, mcdocesoverdue )
                    VALUES( $1, Cur_Part.Num, Cur_Ovd.dcdocesSTART, Cur_Pmnt.dcdeDate+1, 'I', NewOvd );
    
                EXIT WHEN RestPmnt <=0;
    
            END LOOP;
    
        END LOOP;

        RestPmnt := 0;
    
        FOR Cur_Pmnt IN O_Pmnt(Cur_Part.Num) 
        LOOP
    
            RestPmnt := Cur_Pmnt.Mcdesum;
    
            FOR Cur_Ovd IN Get_CDOCES('O',Cur_Part.Num) 
            LOOP
                NewOvd := GREATEST(0,Cur_Ovd.Mcdocesoverdue - RestPmnt);
                RestPmnt := RestPmnt - Cur_Ovd.Mcdocesoverdue;
    
                INSERT INTO xxi.CD_CDO_CES(ncdocesagrid,  icdocespart,         dcdocesstart,       dcdocesdate, ccdocestype, mcdocesoverdue )
                      VALUES( $1, Cur_Part.Num, Cur_Ovd.dcdocesSTART, Cur_Pmnt.dcdeDate+1, 'O',         NewOvd );
    
                EXIT WHEN RestPmnt <=0;
    
            END LOOP;
        END LOOP;

    END LOOP;

  -- IF $3 THEN COMMIT work; END IF;

END;
$procedure$


CREATE PROCEDURE cdces.reg_sleevent(OUT error_msg character varying, IN magrid numeric, IN evtype numeric, IN evdate date, IN evsum numeric, IN evrem character varying, IN trnnum numeric DEFAULT NULL::numeric, IN trnanum numeric DEFAULT NULL::numeric)
AS 
   $procedure$
BEGIN
   -- dbms_output.put_line('Reg_SLEvent function called on #'||MAgrID||'.');
   raise debug 'Reg_SLEvent function called on #%', MAgrID::varchar;
   -- dbms_output.put_line('  Event details are: TYPE '||evTYPE||', DATE '||evDATE||', SUM '||evSUM||', COMMENT "'||evREM||'"...');
   raise debug '  Event details are: TYPE %, DATE %, SUM % , COMMENT "%"...', evTYPE::varchar, evDATE::varchar, evSUM::varchar, evREM;
  -- insert event record
   INSERT INTO CD_SLE (icdsleID, icdsleTYPE, dcdsleDATE, mcdsleSUM, ccdsleREM, icdsleTRNNUM, icdsleTRNANUM)
   VALUES             (MAgrID,   evTYPE,     evDATE,     evSUM,     evREM,     TrnNum,       TrnANum );

   -- COMMIT; 

   raise debug '  COMMIT OK!';

   Error_Msg := 'OK';
END;
$procedure$



CREATE PROCEDURE cdces.remove_to_status_2(IN saleid numeric)
 
AS $procedure$#package

declare
  recCDA    CDA%ROWTYPE;
  acc200    cd2.CCD2ACC%TYPE;
  acc200cur cd2.CCD2CUR%TYPE;
  v_rec_acc ACC%ROWTYPE;
  acc200_closedate acc.DACCCLOSE%TYPE;
  SaleName  cdsale.ccdsalenum%TYPE;
  Cnt NUMERIC := 0;
  CntAll NUMERIC := 0;
  CntSucx NUMERIC := 0;

  EM VARCHAR(2000);

  AgrSale CURSOR 
  for 
  SELECT NCDAAGRID from CDA_LINK_CDSALE where ICDSALEID=$1;

  Get_cd2 CURSOR (AgrNum NUMERIC) 
  for  
  select ccd2acc, ccd2cur from cd2 where ncd2agrid = AgrNum and icd2type = 200;

BEGIN

   select ccdsalenum 
      into SaleName 
    from cdsale 
   where icdsaleid = $1;

   select count(NCDAAGRID) 
      into CntAll 
    from CDA_LINK_CDSALE 
   where ICDSALEID=$1;

   call CDENV.SaveMess(TO_CHAR(SYSDATE,'DD.MM.YY HH:MI:SS')||CHR(10) ||'Кредиты XXI.'||CHR(10) ||'Протокол процедуры отката договоров пакета в статусе Предпродажный '||CHR(10) ||'Номер контракта: '||SaleName||', ID контракта: '||$1,'I');
  
   FOR CurAgr IN AgrSale 
   LOOP
      call CDENV.SaveMess(concat('Обработка договора ',CurAgr.NCDAAGRID),'I');
      
      SELECT * INTO recCDA FROM CDA WHERE ncdaAGRID = CurAgr.NCDAAGRID;

      IF recCDA.ICDASTATUS <> 6 THEN
            call CDENV.SaveMess(concat('Статус договора ',CurAgr.NCDAAGRID,' отличен от Предпродажный'),'I');
      ELSIF 
         recCDA.ICDASTATUS = 6 THEN
            BEGIN 
         FOR CurCD2 IN Get_cd2(CurAgr.NCDAAGRID) LOOP

            acc200 := CurCD2.ccd2acc; acc200cur := CurCD2.ccd2cur;
            Cnt := Cnt + 1;

              IF acc200 is not null and ACC_INFO.get_accprizn(acc200, acc200cur) <> 'З' THEN
           -- закрытие счета
               SELECT * INTO v_rec_acc FROM ACC WHERE caccacc=acc200 AND cacccur=acc200cur;
          
               acc200_closedate := CD.get_lsdate +1/86400 /*(136319)*/;
          
                  IF v_rec_acc.daccclose IS NOT NULL THEN
                     call CDENV.SaveMess ( 'Счет №'||acc200||' признак счета '||v_rec_acc.CACCPRIZN||' - хранится дата закрытия счета '||to_char(v_rec_acc.daccclose,'dd.mm.yyyy hh:mm:ss'));
                     IF TRUNC(v_rec_acc.daccclose) = TRUNC(CD.get_lsdate) THEN 
                        acc200_closedate := v_rec_acc.daccclose +1/86400; /*(234778)*/
                     END IF;
                  END IF;  
          
                  IF NOT( ACCOUNT2.change_acc_state(acc200, acc200cur, 'З', 'Откат в статус Исполняемый договора №'||CurAgr.NCDAAGRID, acc200_closedate ,EM)) THEN
                     call CDENV.SaveMess ( 'Счет №'||acc200||' - '||EM);
               ELSE
                     call CDENV.SaveMess ( 'Счет №'||acc200||' - закрыт','I');

                     -- откат в статус Исполняемый
                   update cda set icdacurrenttype = 0,
                              icdastatus = 2,
                                 CCDACURRENTACC  = (select caddacc from cda_acc where naddagrid = CurAgr.NCDAAGRID and naddtype = 2 /*and rownum = 1*/ limit 1 )
                         where 
                        ncdaagrid = CurAgr.NCDAAGRID;
   
                     delete from cd2 where ncd2agrid = CurAgr.NCDAAGRID and icd2type = 200;
   
                     call CDENV.SaveMess('Счет продажи отвязан от договора '||CurAgr.NCDAAGRID,'I');
   
                   update cda2 set ccda2comm = replace (ccda2comm,'Договор подготовлен к продаже!') where ncda2Agrid = CurAgr.NCDAAGRID;
   
                     delete from cda_acc where naddagrid = CurAgr.NCDAAGRID and naddtype = 2;
                   call CDENV.SaveMess('Статус договора '||CurAgr.NCDAAGRID||' - Исполняемый','I');
   
                     -- COMMIT; перенесено в autoCommit
   
                   CntSucx := CntSucx + 1;

               END IF; -- not

            ELSIF acc200 is not null and ACC_INFO.get_accprizn(acc200, acc200cur) = 'З' THEN

               call CDENV.SaveMess ( 'Счет продажи №'||acc200||' - уже закрыт','I');
                 call CDENV.SaveMess ( 'Откат в статус Исполняемый','I');

                -- откат в статус Исполняемый
                  update cda 
                  set icdacurrenttype = 0, 
                     icdastatus = 2,
                         CCDACURRENTACC = (select caddacc from cda_acc where naddagrid = CurAgr.NCDAAGRID and naddtype = 2  /*and rownum = 1*/ limit 1 )
                   where 
                     ncdaagrid = CurAgr.NCDAAGRID;

                  delete from cd2 where ncd2agrid = CurAgr.NCDAAGRID and icd2type = 200;

                call CDENV.SaveMess('Счет продажи отвязан от договора '||CurAgr.NCDAAGRID,'I');

                  update cda2 set ccda2comm = replace (ccda2comm,'Договор подготовлен к продаже!') where ncda2Agrid = CurAgr.NCDAAGRID;

                delete from cda_acc where naddagrid = CurAgr.NCDAAGRID and naddtype = 2;

                  call CDENV.SaveMess('Статус договора '||CurAgr.NCDAAGRID||' - Исполняемый','I');
            
                -- COMMIT;  перенесено в autoCommit

                  CntSucx := CntSucx + 1;

            ELSIF acc200 is null THEN
                  call CDENV.SaveMess('Для договора '||CurAgr.NCDAAGRID||' отсутствует транзитный счет для продажи','I');
            END IF;
         END LOOP;

         if Cnt = 0 then
               call CDENV.SaveMess('Не найден счет продажи для договора '||CurAgr.NCDAAGRID,'I');
         end if;

      EXCEPTION
         when others then
            call CDENV.SaveMess('Ошибка при обработке договора '||CurAgr.NCDAAGRID||' '||SQLERRM,'I');
      END;

    END IF;

    IF CntSucx = CntAll THEN
      call CDENV.SaveMess('Все договоры из портфеля '||$1||' в статусе ИСПОЛНЯЕМЫЙ, счет продажи закрыт','I');
      update cdsale set ccdsaleacc = NULL, ccdsalecur = NULL where icdsaleid = $1;
      -- commit work;  перенесено в autoCommit
      call CDENV.SaveMess('Счет продажи отвязан от портфеля','I');
    END IF;

  END LOOP;

END;
$procedure$


/* */
CREATE PROCEDURE cdces.reset_mlink_trn(OUT ret_value character varying, OUT error_msg character varying, IN trnnum numeric, IN trnanum numeric)
AS 
$procedure$
   #package
   #private
declare

   DebSt      CHAR;
   CredSt     CHAR;
   CME_Sum_T  NUMERIC;
   
   cr_LINK CURSOR
   for
      SELECT
          MTRNSUM,
          MTRNSUMC,
          SUM(MCMESUMD) MCMESUMD,
          SUM(MCMESUMC) MCMESUMC,
          ROUND(SUM(MCMESUMD*REVAL.Cur_Rate(CCMECUR,DTRNDATE)/REVAL.Cur_Rate(CTRNCUR,DTRNDATE)) ,2) MCMESUM_s,
          ROUND(SUM(MCMESUMC*REVAL.Cur_Rate(CCMECUR,DTRNDATE)/REVAL.Cur_Rate(CTRNCURC,DTRNDATE)),2) MCMESUMC_s,
          MIN(ICD4EVENT) ICD4EVENT, AVG((REVAL.Cur_Rate(CTRNCUR,DTRNDATE)/REVAL.Cur_Rate(CCMECUR,DTRNDATE) )) inv_rate,
          AVG((REVAL.Cur_Rate(CTRNCURC,DTRNDATE)/REVAL.Cur_Rate(CCMECUR,DTRNDATE) )) inv_rateC
      from (
         select
            ICMENUM,
            ICMETYPE,
            DCMEDATE,
            ICMETRNNUM,
            ICMETRNANUM,
            coalesce( dtrnTRAN, dtrnVAL) DTRNDATE,
            CTRNCUR,  mtrnsum,
            CTRNCURC, mtrnsumc,
            ICD4EVENT,

            -- DECODE( ICD4CURTYPE, 1, 'RUR', 2, CCZOCUR, 3, coalesce(CCMFCUR,CCDLCURISO), CCDLCURISO ) CCMECUR,
            case ICD4CURTYPE
               when 1 then 'RUR'
               when 2 then CCZOCUR
               when 3 then coalesce(CCMFCUR,CCDLCURISO)
               else CCDLCURISO 
            end CCMECUR,

            -- DECODE( ICD4ACCD, null, 0, MCMESUM) MCMESUMD,
            case
               when ICD4ACCD is null then 0
               else MCMESUM
            end MCMESUMD, 

            -- DECODE( ICD4ACCC, null, 0, MCMESUM) MCMESUMC,
            case
               when ICD4ACCC is null then 0
               else MCMESUM
            end MCMESUMC, 
            '*'
         from CME inner join CDL on CDL.ICDLNUM = CME.ICMENUM 
                   left join czo on czo.ICZO = CME.NCMECZO 
                   left join trn on trn.ITRNNUM = cme.ICMETRNNUM and tfn.ITRNANUM = cme.ICMETRNANUM 
                   left join cmf on cmf.ICMFID= cme.iCMESUBTYPE
                   left join (select ICD4EVENT, MIN(ICD4CURTYPE) ICD4CURTYPE, SUM(ICD4ACCD) ICD4ACCD, SUM(ICD4ACCC) ICD4ACCC from cd4 group by ICD4EVENT ) C
                             on C.ICD4EVENT = cme.ICMETYPE
         
/*
         where
            ICDLNUM=ICMENUM 
        and ICZO (+) = NCMECZO 
        and ICMFID (+) = iCMESUBTYPE 
        and ITRNNUM (+) = ICMETRNNUM 
        and ITRNANUM (+) = ICMETRNANUM 
        and C.ICD4EVENT (+) = ICMETYPE
*/
      )
      where
         ICMETRNNUM=$3 and ICMETRNANUM=$3
      group by
          MTRNSUM,
          MTRNSUMC,
          DTRNDATE
         ;
BEGIN

   -- dbms_output.put_line('RESET_LINK_TRN called with TrnNum='||TrnNum||'/'||TrnANum);
   raise debug 'RESET_LINK_TRN called with TrnNum = % / %', $3::varchar, $4::varchar;

   FOR RecLINK IN cr_LINK 
   LOOP
      IF RecLINK.MCMESUM_s = 0 THEN                  
         DebSt:=0;
      ELSIF RecLINK.MCMESUM_s<RecLINK.MTRNSUM THEN
         DebSt:=2;
      ELSIF RecLINK.MCMESUM_s=RecLINK.MTRNSUM 
         THEN  DebSt:=1;
      ELSE  --перерасход -->  проверка на ошибку конвертирования
        -- приведение к курсу суммы действия
        CME_Sum_T:= ROUND( RecLINK.MTRNSUM*RecLINK.inv_rate,2 );
        IF CME_Sum_T = RecLINK.MCMESUMD THEN 
           DebSt:=1;
        ELSE
            IF isDBMS THEN
               -- dbms_output.put_line('Рассогласование эквивалентов сумм при идентификации действия ');
               -- dbms_output.put_line(' DebSt='||DebSt);
               -- dbms_output.put_line(' ТRN  '||RecLINK.MTRNSUM||'*'||RecLINK.inv_rate||'-=->'||CME_Sum_T);
               -- dbms_output.put_line(' CME  '||RecLINK.MCMESUMD||'/'||RecLINK.inv_rate||'-=->'||RecLINK.MCMESUM_s);

               raise debug 'Рассогласование эквивалентов сумм при идентификации действия ';
               raise debug ' DebSt=%', DebSt;
               raise debug ' ТRN % * % -=-> %', RecLINK.MTRNSUM::varchar, RecLINK.inv_rate::varchar, CME_Sum_T::varchar;
               raise debug ' CME % / % -=-> %', RecLINK.MCMESUMD::varchar, RecLINK.inv_rate::varchar, RecLINK.MCMESUM_s::varchar;

            END IF;

            Error_Msg:='Рассогласование эквивалентов сумм при идентификации действия';

            $1 := 'ERROR1';
            return;

        END IF;

   END IF;

   IF RecLINK.MCMESUMC_s = 0 THEN
      CredSt:=0;
   ELSIF RecLINK.MCMESUMC_s<RecLINK.MTRNSUMC THEN    
      CredSt:=2;
   ELSIF RecLINK.MCMESUMC_s=RecLINK.MTRNSUMC THEN   
      CredSt:=1;
   ELSE  --перерасход -->  проверка на ошибку конвертирования
        -- приведение к курсу суммы действия
        CME_Sum_T:= ROUND(RecLINK.MTRNSUMC*RecLINK.inv_rateC,2);
        IF CME_Sum_T = RecLINK.MCMESUMC THEN             
            CredSt:=1;
        ELSE

            IF isDBMS THEN
               raise debug 'Рассогласование эквивалентов сумм при идентификации действия ';
               raise debug ' CredSt=%', CredSt;
               raise debug ' ТRN % * % -=-> %', RecLINK.MTRNSUMC, RecLINK.inv_rateC, CME_Sum_T;
               raise debug ' CME % * % -=-> %', RecLINK.MCMESUMC, RecLINK.inv_rateC, RecLINK.MCMESUMC_s;
            END IF;

            Error_Msg:='Рассогласование эквивалентов сумм при идентификации действия';

            $1 := 'ERROR2';
            return;

        END IF;

   END IF;

   IF DebSt=0 and CredSt=0 and RecLINK.ICD4EVENT is null 
   THEN
      Error_Msg:='Не определены правила бухучета по действию ';
      $1 := 'ERROR3';
      return;
   END IF;

   -- dbms_output.put_line('DEB: '||DebSt||'('||RecLINK.MTRNSUM||'/'||RecLINK.MCMESUM_s||')');
   -- dbms_output.put_line('CRED: '||CredSt||'('||RecLINK.MTRNSUMC||'/'||RecLINK.MCMESUMC_s||')');

   call CDEVENTS.SET_LINK_TRN( TrnNum, TrnANum, DebSt, CredSt );

   $1 := 'OK';
   return;
 
   END LOOP;

   --dbms_output.put_line(' 0/0 -> delete link');
   call CDEVENTS.SET_LINK_TRN( TrnNum, TrnANum, 0, 0 );

   $1 := 'OK';

END;
$procedure$


/* */
CREATE PROCEDURE set_activmode(IN cur_mode character)
AS
$procedure$
   #package
BEGIN
    IF CurMode in ('R','D') THEN 
      ActivMode := CurMode;
    ELSE                         
      ActivMode := 'R';
    END IF;
END;
$procedure$



CREATE PROCEDURE set_corrsum_pc(IN agrid numeric, IN datefrom date)
AS $procedure$
DECLARE

    evId NUMERIC;

    Get1_Imps CURSOR (p_agrId NUMERIC) 
    FOR
    SELECT * 
     FROM xxi.cd_imps 
    WHERE CCDIMPTYPE='PC' and NCDIAGRID=p_agrId and dcdidate >=$2 and MCDISUMCRT!=0 and ICDISTATUS=2
    ORDER BY DCDIDATE
      FOR UPDATE;
BEGIN

  --DELETE FROM CDE WHERE ncdeAGRID=AgrID AND icdeTYPE=31 and dcdedate >=Datefrom AND icdeSUBTYPE=0;
    FOR Cr_Imps IN Get1_Imps($1) 
    LOOP
    --CDEVENTS.Reg_Event(Cr_Imps.NCDIAGRID, 1, 31, null, Cr_Imps.DCDIDATE, Cr_Imps.MCDISUMCRT, null, null);
   -- SELECT S_icdeEVENTID.NEXTVAL INTO evID FROM DUAL; -- rem Vct 31.08.2022 переводим на автозаполнение. z.225345

        INSERT INTO CDE -- (icdeEVENTID, -- rem Vct 31.08.2022 переводим на автозаполнение. z.225345
                    (ncdeAGRID, icdePART, icdeTYPE, icdeSUBTYPE, dcdeDATE, mcdeSUM, ccdeREM, icdeTRNNUMF, icdeTRNANUMF, ncdeczo,icdeswpnum, icdesourceid, icdetargetid, CCDEEXTID)
        VALUES      --    (evID,     -- rem Vct 31.08.2022 переводим на автозаполнение. z.225345
                    (    AgrID,        1,       31,        0, Cr_Imps.DCDIDATE, Cr_Imps.MCDISUMCRT, 'Коррекция при загрузке' ,   null,     null, null,null,null,null,null)         
        Returning 
            icdeEVENTID 
                  INTO evID;

        UPDATE xxi.cd_imps SET ICDISTATUS=3, ICDISIDCRT=evID WHERE CURRENT OF Get1_Imps;

    END LOOP;
    -- COMMIT work;
END;
$procedure$


CREATE FUNCTION cdces.set_saleacc_2cd2(saleid numeric)
 RETURNS integer
 
AS $function$
   #package
declare
   Cnt integer :=0;
   SaleAcc acc.CACCACC%TYPE;
   SaleCur acc.CACCCUR%TYPE;
   OldSaleAcc  acc.CACCACC%TYPE;
   OldSaleCur  acc.CACCCUR%TYPE;

   CURRENTTYPE integer;
   CURISO      acc.CACCCUR%TYPE;

   CURRENTACC  acc.CACCACC%TYPE;
   SaleCus cus.icusnum%TYPE;
   nError  integer;
   Err integer;

   AgrSale CURSOR 
   for  
      SELECT NCDAAGRID 
        from CDA_LINK_CDSALE where ICDSALEID=$1;
BEGIN

   Cnt:=0;

   raise debug 'STARTED Set_saleacc_2cd2 SaleID = %', $1;

   call cdces.cap_Message('Кредиты XXI. Привязка счета продажи к договорам портфеля SaleID = ' || $1 );

   Select ccdsaleacc, ccdsalecur, icdsalecus 
     into 
          SaleAcc, SaleCur, SaleCus 
     from cdsale 
    where 
          icdsaleid = $1;

  -- dbms_output.put_line('SaleAcc = '||SaleAcc||' SaleCur = '||SaleCur);
   raise debug 'SaleAcc = %, SaleCur =%', SaleAcc, SaleCur; 
  
   IF SaleAcc IS NULL THEN
      call cap_Message('Счет продажи не задан.');
   END IF;
  
   IF SaleCur IS NULL THEN
      call cap_Message('Не задана валюта счета продажи.');
   END IF;

   IF SaleAcc IS NOT NULL AND SaleCur IS NOT NULL 
   THEN
      FOR CurAgr IN AgrSale 
      LOOP
         nError := 0; Err := 0;
         BEGIN

            SELECT MIN(CCD2CUR), MIN(CCD2ACC) INTO OldSaleCur, OldSaleAcc FROM CD2 WHERE NCD2AGRID = CurAgr.NCDAAGRID AND ICD2TYPE = 200;
   
            IF OldSaleAcc IS NOT NULL 
            THEN
               call CDENV.SaveMess('Договор '||CurAgr.NCDAAGRID||' уже имеет транзитный счет для продажи '||OldSaleAcc||' '||OldSaleCur);
               -- dbms_output.put_line('Договор '||CurAgr.NCDAAGRID||' уже имеет транзитный счет для продажи '||OldSaleAcc||' '||OldSaleCur);
               raise debug 'Договор % уже имеет транзитный счет для продажи % %', CurAgr.NCDAAGRID::varchar, OldSaleAcc, OldSaleCur; 

            ELSIF OldSaleAcc IS NULL 
            THEN
               INSERT INTO CD2(NCD2AGRID, ICD2BS2, CCD2CUR, CCD2ACC, ICD2MASKCODE, ICD2TYPE, ICD2FLAG, CCD2COMMENT, ICD2CLIENT)
                    VALUES(CurAgr.NCDAAGRID,SUBSTR(SaleAcc,1,5)::numeric,SaleCur,SaleAcc,1,200,1,'Привязка счета продажи из контракта',SaleCus);
            END IF;
         EXCEPTION
            WHEN unique_violation THEN 
                 NULL;
            WHEN OTHERS THEN
                 nError := nError + 1;
                 call CDENV.SaveMess('Договор '||CurAgr.NCDAAGRID||' -> nError IN INSERT INTO CDA_ACC: '||SQLERRM);
                 --dbms_output.put_line('nError IN INSERT INTO CDA_ACC: '||SQLERRM);
                 raise debug 'Error IN INSERT INTO CDA_ACC:  %', SQLERRM; 
         END;

      BEGIN

        SELECT ICDACURRENTTYPE,ccdaCURISO,CCDACURRENTACC
          INTO
               CURRENTTYPE, CURISO, CURRENTACC
          FROM CDA 
         WHERE 
               CDA.ncdaagrid = CurAgr.NCDAAGRID;

         IF( CURRENTACC IS NOT NULL) AND (CURRENTTYPE = 0) AND Err = 0 THEN

            BEGIN
                INSERT INTO 
                     CDA_ACC(naddagrid,caddcuriso,naddtype,caddacc)
                VALUES
                     (CurAgr.NCDAAGRID,coalesce(CDTERMS.Get_ACCcur(CURRENTACC),CURISO),2,CURRENTACC);
               EXCEPTION
                  WHEN unique_violation THEN 
                      NULL;
                  WHEN OTHERS THEN
                    nError := nError + 1;
                    call CDENV.SaveMess('Договор '||CurAgr.NCDAAGRID||' -> nError IN INSERT INTO CDA_ACC: '||SQLERRM);
                    --dbms_output.put_line('nError IN INSERT INTO CDA_ACC: '||SQLERRM);
                    raise debug 'Error IN INSERT INTO CDA_ACC:  %', SQLERRM; 
               END;
         ELSIF CURRENTACC IS NULL THEN
           call CDENV.SaveMess('Договор '||CurAgr.NCDAAGRID||' отсутствует текущий счет');
           raise debug 'Договор: %  отсутствует текущий счет', CurAgr.NCDAAGRID; 
           -- dbms_output.put_line('Договор '||CurAgr.NCDAAGRID||' отсутствует текущий счет');
           -- nError := nError + 1; -- по заявке 232901 разрешать без текущего счета, 235506
           -- IF OldSaleAcc IS NULL THEN DELETE FROM CD2 WHERE NCD2AGRID = CurAgr.NCDAAGRID AND ICD2TYPE = 200; END IF;
         ELSE
           nError := nError + 1;
         END IF;
           IF (nError = 0) AND (CURRENTTYPE = 0) THEN
             BEGIN
               INSERT INTO CDA2(NCDA2AGRID,CCDA2COMM)
                        VALUES (CurAgr.NCDAAGRID,'Договор подготовлен к продаже!');
               EXCEPTION   
            WHEN unique_violation THEN
                 UPDATE CDA2 SET
                   CCDA2COMM = CCDA2COMM||' Договор подготовлен к продаже!'
                  WHERE CDA2.ncda2agrid = CurAgr.NCDAAGRID;
             END;

            UPDATE CDA SET
              ICDACURRENTTYPE = 1,
              ICDASTATUS      = 6,
              CCDACURRENTACC  = SaleAcc
            WHERE CDA.ncdaagrid = CurAgr.NCDAAGRID;

            Cnt := Cnt + 1;
           ELSIF CURRENTTYPE = 1 THEN
             call CDENV.SaveMess('Договор '||CurAgr.NCDAAGRID||' -> Уже имеет транзитный счет');
           END IF;
         EXCEPTION WHEN OTHERS THEN
           call CDENV.SaveMess('Договор '||CurAgr.NCDAAGRID||' -> '||SQLERRM);
           -- dbms_output.put_line('Error IN CDSLACC.FMB: '||SQLERRM);
           raise debug 'Error IN CDSLACC.FMB: %', SQLERRM; 
      END;
      END LOOP;

   END IF;

   Return Cnt;

END;
$function$

-- end_Of_Package
;