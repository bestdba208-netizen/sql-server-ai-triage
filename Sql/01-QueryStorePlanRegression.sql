USE StackOverflow2013;
GO

DECLARE @MinExecutionsPerPlan int = 1;
DECLARE @MinDurationMultiplier decimal(10,2) = 2.0;
DECLARE @MinWorstDurationMs decimal(18,2) = 100.0;

WITH PlanStats AS
(
    SELECT
        qsq.query_id,
        qsp.plan_id,
        qt.query_sql_text,

        SUM(rs.count_executions) AS executions,

        SUM(rs.avg_duration * rs.count_executions)
            / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_duration_ms,

        SUM(rs.avg_cpu_time * rs.count_executions)
            / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS avg_cpu_ms,

        SUM(rs.avg_logical_io_reads * rs.count_executions)
            / NULLIF(SUM(rs.count_executions), 0) AS avg_logical_reads,

        MIN(rsi.start_time) AS first_seen,
        MAX(rsi.end_time) AS last_seen
    FROM sys.query_store_query AS qsq
    JOIN sys.query_store_query_text AS qt
        ON qsq.query_text_id = qt.query_text_id
    JOIN sys.query_store_plan AS qsp
        ON qsq.query_id = qsp.query_id
    JOIN sys.query_store_runtime_stats AS rs
        ON qsp.plan_id = rs.plan_id
    JOIN sys.query_store_runtime_stats_interval AS rsi
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rs.count_executions > 0
    GROUP BY
        qsq.query_id,
        qsp.plan_id,
        qt.query_sql_text
    HAVING SUM(rs.count_executions) >= @MinExecutionsPerPlan
),
RankedPlans AS
(
    SELECT
        *,
        ROW_NUMBER() OVER
        (
            PARTITION BY query_id
            ORDER BY avg_duration_ms ASC
        ) AS best_plan_rank,

        ROW_NUMBER() OVER
        (
            PARTITION BY query_id
            ORDER BY avg_duration_ms DESC
        ) AS worst_plan_rank
    FROM PlanStats
),
BestPlan AS
(
    SELECT *
    FROM RankedPlans
    WHERE best_plan_rank = 1
),
WorstPlan AS
(
    SELECT *
    FROM RankedPlans
    WHERE worst_plan_rank = 1
),
Regressions AS
(
    SELECT
        w.query_id,

        b.plan_id AS best_plan_id,
        b.executions AS best_plan_executions,
        b.avg_duration_ms AS best_avg_duration_ms,
        b.avg_cpu_ms AS best_avg_cpu_ms,
        b.avg_logical_reads AS best_avg_logical_reads,
        b.first_seen AS best_first_seen,
        b.last_seen AS best_last_seen,

        w.plan_id AS worst_plan_id,
        w.executions AS worst_plan_executions,
        w.avg_duration_ms AS worst_avg_duration_ms,
        w.avg_cpu_ms AS worst_avg_cpu_ms,
        w.avg_logical_reads AS worst_avg_logical_reads,
        w.first_seen AS worst_first_seen,
        w.last_seen AS worst_last_seen,

        w.avg_duration_ms / NULLIF(b.avg_duration_ms, 0) AS duration_multiplier,
        w.avg_cpu_ms / NULLIF(b.avg_cpu_ms, 0) AS cpu_multiplier,
        w.avg_logical_reads / NULLIF(b.avg_logical_reads, 0) AS reads_multiplier,

        w.query_sql_text
    FROM WorstPlan AS w
    JOIN BestPlan AS b
        ON w.query_id = b.query_id
    WHERE w.plan_id <> b.plan_id
      AND w.avg_duration_ms >= @MinWorstDurationMs
      AND w.avg_duration_ms >= b.avg_duration_ms * @MinDurationMultiplier
),
TopRegression AS
(
    SELECT TOP (1) *
    FROM Regressions
    ORDER BY
        duration_multiplier DESC,
        reads_multiplier DESC,
        worst_avg_duration_ms DESC
)
SELECT
(
    SELECT
        query_id,

        best_plan_id AS [best_plan.plan_id],
        best_plan_executions AS [best_plan.executions],
        best_avg_duration_ms AS [best_plan.avg_duration_ms],
        best_avg_cpu_ms AS [best_plan.avg_cpu_ms],
        best_avg_logical_reads AS [best_plan.avg_logical_reads],
        best_first_seen AS [best_plan.first_seen],
        best_last_seen AS [best_plan.last_seen],

        worst_plan_id AS [worst_plan.plan_id],
        worst_plan_executions AS [worst_plan.executions],
        worst_avg_duration_ms AS [worst_plan.avg_duration_ms],
        worst_avg_cpu_ms AS [worst_plan.avg_cpu_ms],
        worst_avg_logical_reads AS [worst_plan.avg_logical_reads],
        worst_first_seen AS [worst_plan.first_seen],
        worst_last_seen AS [worst_plan.last_seen],

        duration_multiplier AS [regression.duration_multiplier],
        cpu_multiplier AS [regression.cpu_multiplier],
        reads_multiplier AS [regression.reads_multiplier],

        LEFT(query_sql_text, 4000) AS query_sql_text
    FROM TopRegression
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
) AS JsonOutput;