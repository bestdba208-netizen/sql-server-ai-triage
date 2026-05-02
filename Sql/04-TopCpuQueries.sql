/*
    Detector: Top CPU Queries

    Purpose:
    Finds high-CPU queries from Query Store.

    Output:
    One row with one column: JsonOutput
*/

SET NOCOUNT ON;

DECLARE @LookbackHours int = 24;
DECLARE @TopN int = 25;

DECLARE @MinTotalCpuMs decimal(18,2) = 1000.0; -- 1 second total CPU
DECLARE @MinAvgCpuMs   decimal(18,2) = 100.0;  -- 100 ms average CPU
DECLARE @MinExecutions bigint = 5;

DECLARE @StartTime datetimeoffset = DATEADD(HOUR, -@LookbackHours, SYSDATETIMEOFFSET());

;WITH CpuStats AS
(
    SELECT
        qsq.query_id,
        qsp.plan_id,
        qst.query_sql_text,

        executions =
            SUM(CONVERT(bigint, rs.count_executions)),

        avg_cpu_ms =
            CONVERT(decimal(18,2),
                SUM(CONVERT(decimal(38,4), rs.avg_cpu_time) * rs.count_executions)
                / NULLIF(SUM(CONVERT(decimal(38,4), rs.count_executions)), 0)
                / 1000.0
            ),

        total_cpu_ms =
            CONVERT(decimal(18,2),
                SUM(CONVERT(decimal(38,4), rs.avg_cpu_time) * rs.count_executions)
                / 1000.0
            ),

        avg_duration_ms =
            CONVERT(decimal(18,2),
                SUM(CONVERT(decimal(38,4), rs.avg_duration) * rs.count_executions)
                / NULLIF(SUM(CONVERT(decimal(38,4), rs.count_executions)), 0)
                / 1000.0
            ),

        total_duration_ms =
            CONVERT(decimal(18,2),
                SUM(CONVERT(decimal(38,4), rs.avg_duration) * rs.count_executions)
                / 1000.0
            ),

        avg_logical_reads =
            CONVERT(decimal(18,2),
                SUM(CONVERT(decimal(38,4), rs.avg_logical_io_reads) * rs.count_executions)
                / NULLIF(SUM(CONVERT(decimal(38,4), rs.count_executions)), 0)
            ),

        max_cpu_ms =
            CONVERT(decimal(18,2), MAX(rs.max_cpu_time) / 1000.0),

        first_seen =
            MIN(rsi.start_time),

        last_seen =
            MAX(rsi.end_time)
    FROM sys.query_store_query AS qsq
    JOIN sys.query_store_query_text AS qst
        ON qsq.query_text_id = qst.query_text_id
    JOIN sys.query_store_plan AS qsp
        ON qsq.query_id = qsp.query_id
    JOIN sys.query_store_runtime_stats AS rs
        ON qsp.plan_id = rs.plan_id
    JOIN sys.query_store_runtime_stats_interval AS rsi
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE
        rsi.end_time >= @StartTime
    GROUP BY
        qsq.query_id,
        qsp.plan_id,
        qst.query_sql_text
),
Issues AS
(
    SELECT TOP (@TopN)
        issue_type = 'TOP_CPU_QUERY',
        query_id,
        plan_id,
        executions,
        avg_cpu_ms,
        total_cpu_ms,
        max_cpu_ms,
        avg_duration_ms,
        total_duration_ms,
        avg_logical_reads,
        cpu_ms_per_execution = avg_cpu_ms,
        first_seen,
        last_seen,
        query_sql_text =
            LEFT(
                REPLACE(REPLACE(query_sql_text, CHAR(13), ' '), CHAR(10), ' '),
                4000
            )
    FROM CpuStats
    WHERE
        executions >= @MinExecutions
        AND
        (
            total_cpu_ms >= @MinTotalCpuMs
            OR avg_cpu_ms >= @MinAvgCpuMs
        )
    ORDER BY
        total_cpu_ms DESC
)
SELECT
    JsonOutput =
    (
        SELECT *
        FROM Issues
        FOR JSON PATH
    )
WHERE EXISTS (SELECT 1 FROM Issues);