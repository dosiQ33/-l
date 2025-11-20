--create table loan_temp_allocations_full as 
with your_table as (
select
	T.DATE_ID,
	T.CLIENT_ID,
	t.iin,
	t.PRODUCT_ID_LEVEL4_ID,
	t.RESP_UNIT_LEVEL6_ID,
	t.pl_account_level5_id,
	COUNT(case when T.IIN <> '-1' then 1 end) over (
    partition by T.DATE_ID,
	T.PRODUCT_ID_LEVEL4_ID,
	T.RESP_UNIT_LEVEL6_ID
  ) as client_count,
	SUM(case when t.pl_account_level5_id = 1547 then -T.REST_EQ_REP else 0 end) as allocation
from
	TO_CUBE_FM_FP_SDL_2024_M T
where
	1 = 1
	and T.subject_kind_id = 'ФЛ'
	--and t.year_id = 2024
group by
	T.DATE_ID,
	t.iin,
	T.CLIENT_ID,
	t.RESP_UNIT_LEVEL6_ID,
	t.pl_account_level5_id,
	t.PRODUCT_ID_LEVEL4_ID
	),
alloc_amount as (
select
	t.DATE_ID,
	t.PRODUCT_ID_LEVEL4_ID,
	t.RESP_UNIT_LEVEL6_ID,
	t.pl_account_level5_id,
	coalesce(SUM(t.allocation / nullif(t.CLIENT_COUNT, 0)), 0) as allocated_amount
from
	your_table t
group by
	t.DATE_ID,
	t.PRODUCT_ID_LEVEL4_ID,
	t.pl_account_level5_id,
	t.RESP_UNIT_LEVEL6_ID
	)
select
	t.*,
	ta.iin,
	ta.CLIENT_ID,
	ta.client_count
from
	your_table ta
join alloc_amount t
on
	t.DATE_ID = ta.DATE_ID
	and t.PRODUCT_ID_LEVEL4_ID = ta.PRODUCT_ID_LEVEL4_ID
	and t.RESP_UNIT_LEVEL6_ID = ta.RESP_UNIT_LEVEL6_ID
	and t.pl_account_level5_id = ta.pl_account_level5_id
where
	ta.iin != '-1'
	and ta.client_count > 1
