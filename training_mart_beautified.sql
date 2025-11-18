-- ============================================================
-- 01_oracle_training_mart.sql
-- Builds CLTV training feature store (no leakage) and target.
-- History up to 2025-08-31; training rows end at 2025-07-31.
-- ============================================================

-- Params
--DEFINE TRAIN_START_DATE      = '2023-01-01';
--DEFINE TRAIN_END_DATE        = '2025-07-31';  -- last available month in history
--DEFINE MIN_MONTHS_HISTORY    = 13;

-- Clean old table if exists (optional)
BEGIN
  EXECUTE IMMEDIATE 'DROP TABLE CLTV_UL_TRAIN_MART PURGE';
EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

-- =======================
-- Base monthly P&L (agg)
-- =======================
CREATE TABLE CLTV_UL_TRAIN_MART AS
WITH base_data AS (
  SELECT
    T.CLIENT_ID,
    TO_DATE(T.DATE_ID, 'YYYYMMDD') AS MONTH_END,
    SUM(CASE WHEN cr.r_index_1_code != '2' THEN T.REST_EQ_REP ELSE 0 END) AS MARGIN,
    STATS_MODE(T.BUS_SECTOR_ID) AS SEGMENT_ID,
    STATS_MODE(T.QUALITY_CODE) AS QUALITY_CODE,
    STATS_MODE(T.SUBJECT_KIND_ID) AS SUBJECT_KIND_ID,
    STATS_MODE(T.EC_SECTOR_ID) AS EC_SECTOR_ID
  FROM TO_CUBE_FM_FP_M T
    LEFT JOIN TO_SB_SUBJECTS_OLTP_M s ON (
      s.id = t.client_id
      AND s.dfrom <= CURRENT_DATE
      AND s.dto > CURRENT_DATE
    )
    LEFT JOIN TO_MA_BANK_PRODUCTSSH1STRAD_M MBPS ON (
      MBPS.LEVEL_4 = T.PRODUCT_ID_LEVEL4_ID
    )
    LEFT JOIN TO_MA_BANK_PRODUCTS_M P1 ON (
      P1.ID = MBPS.LEVEL_1
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') >= P1.DFROM
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') < P1.DTO
    )
    LEFT JOIN TO_MA_BANK_PRODUCTS_M P2 ON (
      P2.ID = MBPS.LEVEL_2
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') >= P2.DFROM
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') < P2.DTO
    )
    LEFT JOIN TO_MA_BANK_PRODUCTS_M P3 ON (
      P3.ID = MBPS.LEVEL_3
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') >= P3.DFROM
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') < P3.DTO
    )
    LEFT JOIN TO_MA_BANK_PRODUCTS_M P4 ON (
      P4.ID = MBPS.LEVEL_4
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') >= P4.DFROM
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') < P4.DTO
    )
    LEFT JOIN TO_MA_PL_STATEMENTSH1STRAD_M M ON (
      M.LEVEL_5 = T.PL_ACCOUNT_LEVEL5_ID
    )
    LEFT JOIN TO_MA_PL_STATEMENT_M M5 ON (
      M5.ID = M.LEVEL_5
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') >= M5.DFROM
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') < M5.DTO
    )
    LEFT JOIN TO_MA_PL_STATEMENT_M M4 ON (
      M4.ID = M.LEVEL_4
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') >= M4.DFROM
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') < M4.DTO
    )
    LEFT JOIN TO_MA_PL_STATEMENT_M M3 ON (
      M3.ID = M.LEVEL_3
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') >= M3.DFROM
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') < M3.DTO
    )
    LEFT JOIN TO_MA_PL_STATEMENT_M M2 ON (
      M2.ID = M.LEVEL_2
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') >= M2.DFROM
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') < M2.DTO
    )
    LEFT JOIN TO_MA_PL_STATEMENT_M M1 ON (
      M1.ID = M.LEVEL_1
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') >= M1.DFROM
      AND TO_DATE(T.DATE_ID, 'yyyymmdd') < M1.DTO
    )
    LEFT JOIN CLTV_SPR_OPU_INDEX CR ON (
      CR.R_INDEX_CODE = TO_CHAR(EDWMSB.F_REP_ST_ID(
        3, -1, -1, -1, '-1', '-1', 
        M1.ID, M2.ID, M5.ID, M5.CODE, 
        P2.ID, P3.ID, P3.CODE
      ))
    )
  WHERE P1.ID = 1000 and T.SUBJECT_KIND_ID IN ('ЮЛ','ИП')
    AND T.IIN NOT IN ('-1','000000000000')
    AND t.subject_kind_id != 'Наш Банк'
    AND s.is_bank != 'Д'
    AND TO_DATE(T.DATE_ID,'YYYYMMDD') BETWEEN DATE '&TRAIN_START_DATE' AND DATE '&TRAIN_END_DATE'
  GROUP BY T.CLIENT_ID, TO_DATE(T.DATE_ID,'YYYYMMDD')
),

-- Month spine to ensure continuity
months AS (
  SELECT LAST_DAY(ADD_MONTHS(DATE '&TRAIN_START_DATE', LEVEL-1)) AS MONTH_END
  FROM DUAL
  CONNECT BY LAST_DAY(ADD_MONTHS(DATE '&TRAIN_START_DATE', LEVEL-1)) <= DATE '&TRAIN_END_DATE'
),

clients AS (
  SELECT DISTINCT CLIENT_ID FROM base_data
),

spine AS (
  SELECT c.CLIENT_ID, m.MONTH_END
  FROM clients c 
  CROSS JOIN months m
),

-- Zero-fill margin; forward-fill segment and quality if missing
base_filled AS (
  SELECT
    s.CLIENT_ID,
    s.MONTH_END,
    NVL(b.MARGIN, 0) AS MARGIN,
    COALESCE(
      b.SEGMENT_ID,
      LAG(b.SEGMENT_ID IGNORE NULLS) OVER (PARTITION BY s.CLIENT_ID ORDER BY s.MONTH_END)
    ) AS SEGMENT_ID,
    COALESCE(
      b.QUALITY_CODE,
      LAG(b.QUALITY_CODE IGNORE NULLS) OVER (PARTITION BY s.CLIENT_ID ORDER BY s.MONTH_END)
    ) AS QUALITY_CODE,
    COALESCE(
      b.SUBJECT_KIND_ID,
      LAG(b.SUBJECT_KIND_ID IGNORE NULLS) OVER (PARTITION BY s.CLIENT_ID ORDER BY s.MONTH_END)
    ) AS SUBJECT_KIND_ID,
    COALESCE(
      b.EC_SECTOR_ID,
      LAG(b.EC_SECTOR_ID IGNORE NULLS) OVER (PARTITION BY s.CLIENT_ID ORDER BY s.MONTH_END)
    ) AS EC_SECTOR_ID
  FROM spine s
    LEFT JOIN base_data b ON (
      b.CLIENT_ID = s.CLIENT_ID 
      AND b.MONTH_END = s.MONTH_END
    )
),

filtered_clients AS (
  SELECT CLIENT_ID
  FROM base_filled 
  WHERE MARGIN != 0  -- Only months with actual activity
  GROUP BY CLIENT_ID
  HAVING COUNT(*) >= &MIN_MONTHS_HISTORY
),

-- Tenure along filled timeline
client_tenure AS (
  SELECT
    CLIENT_ID,
    MONTH_END,
    ROW_NUMBER() OVER (PARTITION BY CLIENT_ID ORDER BY MONTH_END) AS TENURE_MONTHS
  FROM base_filled
),

-- Historical (non-leaky) features
historical_features AS (
  SELECT
    bf.CLIENT_ID,
    bf.MONTH_END,
    bf.SEGMENT_ID,
    bf.QUALITY_CODE,
    bf.SUBJECT_KIND_ID,
    bf.EC_SECTOR_ID,
    bf.MARGIN,

    -- Point lags
    LAG(bf.MARGIN,1) OVER (PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END) AS MARGIN_LAG1,
    LAG(bf.MARGIN,2) OVER (PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END) AS MARGIN_LAG2,
    LAG(bf.MARGIN,3) OVER (PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END) AS MARGIN_LAG3,

    -- Short rolling avgs (end at 1 PRECEDING)
    AVG(bf.MARGIN) OVER (
      PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END
      ROWS BETWEEN 1 PRECEDING AND 1 PRECEDING
    ) AS MARGIN_AVG_1M_LAG,

    AVG(bf.MARGIN) OVER (
      PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END
      ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING
    ) AS MARGIN_AVG_2M_LAG,

    AVG(bf.MARGIN) OVER (
      PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END
      ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
    ) AS MARGIN_AVG_3M_LAG,

    -- Medium / Long rolling avgs
    AVG(bf.MARGIN) OVER (
      PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END
      ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING
    ) AS MARGIN_AVG_6M_LAG,

    AVG(bf.MARGIN) OVER (
      PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END
      ROWS BETWEEN 11 PRECEDING AND 1 PRECEDING
    ) AS MARGIN_AVG_12M_LAG,

    -- Volatility
    STDDEV(bf.MARGIN) OVER (
      PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END
      ROWS BETWEEN 11 PRECEDING AND 1 PRECEDING
    ) AS MARGIN_STDDEV_12M_LAG,

    -- Momentum (3m vs prior 3m)
    (
      AVG(bf.MARGIN) OVER (
        PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END
        ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING
      )
      -
      AVG(bf.MARGIN) OVER (
        PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END
        ROWS BETWEEN 5 PRECEDING AND 3 PRECEDING
      )
    ) / NULLIF(ABS(
      AVG(bf.MARGIN) OVER (
        PARTITION BY bf.CLIENT_ID ORDER BY bf.MONTH_END
        ROWS BETWEEN 5 PRECEDING AND 3 PRECEDING
      )
    ),0) AS MARGIN_GROWTH_RATE_3M,

    -- Seasonality
    EXTRACT(MONTH FROM bf.MONTH_END) AS MONTH_OF_YEAR,
    TO_NUMBER(TO_CHAR(bf.MONTH_END, 'Q')) AS QUARTER_OF_YEAR,

    ct.TENURE_MONTHS
  FROM base_filled bf
    INNER JOIN filtered_clients fc ON fc.CLIENT_ID = bf.CLIENT_ID  -- Only keep qualified clients
    JOIN client_tenure ct ON (
      ct.CLIENT_ID = bf.CLIENT_ID 
      AND ct.MONTH_END = bf.MONTH_END
    )
  WHERE bf.MARGIN != 0
),

-- Segment benchmarks (contemporaneous)
segment_benchmarks AS (
  SELECT
    SEGMENT_ID,
    MONTH_END,
    AVG(MARGIN) AS SEGMENT_AVG_MARGIN,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY MARGIN) AS SEGMENT_MEDIAN_MARGIN
  FROM base_filled
  GROUP BY SEGMENT_ID, MONTH_END
),

-- Assemble features and next-month target (exclude last month where target is NULL)
assembled AS (
  SELECT
    hf.CLIENT_ID,
    hf.MONTH_END,
    hf.SEGMENT_ID,
    hf.QUALITY_CODE,
    hf.SUBJECT_KIND_ID,
    hf.EC_SECTOR_ID,

    hf.MARGIN,
    hf.MARGIN_LAG1, hf.MARGIN_LAG2, hf.MARGIN_LAG3,
    hf.MARGIN_AVG_1M_LAG, hf.MARGIN_AVG_2M_LAG, hf.MARGIN_AVG_3M_LAG,
    hf.MARGIN_AVG_6M_LAG, hf.MARGIN_AVG_12M_LAG,
    hf.MARGIN_STDDEV_12M_LAG,
    hf.MARGIN_GROWTH_RATE_3M,

    hf.MONTH_OF_YEAR, hf.QUARTER_OF_YEAR,
    hf.TENURE_MONTHS,

    sb.SEGMENT_AVG_MARGIN,
    sb.SEGMENT_MEDIAN_MARGIN,

    -- Target: next-month margin (non-leaky)
    LEAD(hf.MARGIN,1) OVER (PARTITION BY hf.CLIENT_ID ORDER BY hf.MONTH_END) AS TARGET_NEXT_MARGIN
  FROM historical_features hf
    LEFT JOIN segment_benchmarks sb ON (
      sb.SEGMENT_ID = hf.SEGMENT_ID 
      AND sb.MONTH_END = hf.MONTH_END
    )
)
SELECT *
FROM assembled
WHERE MONTH_END < DATE '&TRAIN_END_DATE'     -- ensures TARGET_NEXT_MARGIN exists
  AND TARGET_NEXT_MARGIN IS NOT NULL
  AND TENURE_MONTHS >= &MIN_MONTHS_HISTORY
/

-- Indexes
CREATE INDEX IDX_CLTV_UL_TRAIN_CLIENT ON CLTV_UL_TRAIN_MART (CLIENT_ID);
CREATE INDEX IDX_CLTV_UL_TRAIN_MONTH  ON CLTV_UL_TRAIN_MART (MONTH_END);