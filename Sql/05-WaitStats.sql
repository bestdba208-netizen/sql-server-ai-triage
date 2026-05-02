SET NOCOUNT ON;

DECLARE @MinimumTotalActiveWaitMs bigint = 30000; -- total active wait time across wait type
DECLARE @MinimumMaxWaitMs         bigint = 5000;  -- single task waiting at least this long
DECLARE @MinimumWaitingTasks      int    = 5;     -- number of tasks waiting on same wait type

;WITH ActiveWaits AS
(
    SELECT
        wt.session_id,
        wt.wait_type,
        wt.wait_duration_ms,
        wt.blocking_session_id,
        r.status,
        r.command,
        r.cpu_time,
        r.total_elapsed_time,
        r.logical_reads,
        r.reads,
        r.writes,
        DB_NAME(r.database_id) AS database_name,
        s.login_name,
        s.host_name,
        s.program_name,
        LEFT(REPLACE(REPLACE(st.text, CHAR(13), ' '), CHAR(10), ' '), 1000) AS sql_text,
        CASE
            WHEN wt.wait_type LIKE 'PAGEIOLATCH%' THEN 'Data file read IO'
            WHEN wt.wait_type LIKE 'WRITELOG%' THEN 'Transaction log IO'
            WHEN wt.wait_type LIKE 'LCK_M_%' THEN 'Blocking / locks'
            WHEN wt.wait_type LIKE 'RESOURCE_SEMAPHORE%' THEN 'Memory grant pressure'
            WHEN wt.wait_type LIKE 'CXPACKET%' OR wt.wait_type LIKE 'CXCONSUMER%' THEN 'Parallelism'
            WHEN wt.wait_type LIKE 'PAGELATCH%' THEN 'In-memory latch contention'
            WHEN wt.wait_type LIKE 'ASYNC_NETWORK_IO%' THEN 'Client/network consumption'
            WHEN wt.wait_type LIKE 'SOS_SCHEDULER_YIELD%' THEN 'CPU scheduler pressure'
            WHEN wt.wait_type LIKE 'THREADPOOL%' THEN 'Worker thread pressure'
            WHEN wt.wait_type LIKE 'HADR%' THEN 'Availability Group / HADR'
            ELSE 'Other'
        END AS wait_category
    FROM sys.dm_os_waiting_tasks AS wt
    LEFT JOIN sys.dm_exec_requests AS r
        ON wt.session_id = r.session_id
    LEFT JOIN sys.dm_exec_sessions AS s
        ON wt.session_id = s.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS st
    WHERE
        wt.session_id > 50
        AND wt.wait_type IS NOT NULL
        AND wt.wait_type NOT IN
        (
            'BROKER_RECEIVE_WAITFOR',
            'BROKER_TASK_STOP',
            'BROKER_TO_FLUSH',
            'BROKER_TRANSMITTER',
            'CHECKPOINT_QUEUE',
            'CLR_AUTO_EVENT',
            'CLR_MANUAL_EVENT',
            'DIRTY_PAGE_POLL',
            'DISPATCHER_QUEUE_SEMAPHORE',
            'FT_IFTS_SCHEDULER_IDLE_WAIT',
            'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
            'LAZYWRITER_SLEEP',
            'LOGMGR_QUEUE',
            'ONDEMAND_TASK_QUEUE',
            'REQUEST_FOR_DEADLOCK_SEARCH',
            'SLEEP_TASK',
            'SP_SERVER_DIAGNOSTICS_SLEEP',
            'SQLTRACE_BUFFER_FLUSH',
            'WAITFOR',
            'XE_DISPATCHER_WAIT',
            'XE_TIMER_EVENT'
        )
),
WaitSummary AS
(
    SELECT TOP (10)
        wait_type,
        wait_category,
        COUNT(*) AS waiting_task_count,
        SUM(CONVERT(bigint, wait_duration_ms)) AS total_active_wait_ms,
        MAX(CONVERT(bigint, wait_duration_ms)) AS max_wait_ms,
        COUNT(DISTINCT session_id) AS session_count,
        COUNT(DISTINCT NULLIF(blocking_session_id, 0)) AS blocking_session_count
    FROM ActiveWaits
    GROUP BY wait_type, wait_category
    ORDER BY
        SUM(CONVERT(bigint, wait_duration_ms)) DESC
),
TopIssue AS
(
    SELECT TOP (1)
        wait_type,
        wait_category,
        waiting_task_count,
        total_active_wait_ms,
        max_wait_ms,
        session_count,
        blocking_session_count,
        CONVERT(decimal(18,2),
            (total_active_wait_ms / 1000.0)
            + (max_wait_ms / 1000.0 * 2.0)
            + (waiting_task_count * 5.0)
            + (blocking_session_count * 20.0)
        ) AS severity_score
    FROM WaitSummary
    WHERE
        total_active_wait_ms >= @MinimumTotalActiveWaitMs
        OR max_wait_ms >= @MinimumMaxWaitMs
        OR waiting_task_count >= @MinimumWaitingTasks
    ORDER BY
        total_active_wait_ms DESC,
        max_wait_ms DESC,
        waiting_task_count DESC
)
SELECT
    (
        SELECT
            '05-WaitStats' AS DetectorName,
            'Active wait pressure detected' AS IssueTitle,
            CONCAT('05-WaitStats|wait_type=', ti.wait_type) AS IssueKey,
            ti.severity_score AS SeverityScore,
            ti.wait_type,
            ti.wait_category,
            ti.waiting_task_count,
            ti.total_active_wait_ms,
            ti.max_wait_ms,
            ti.session_count,
            ti.blocking_session_count,
            GETDATE() AS detected_at_local,

            JSON_QUERY((
                SELECT
                    wait_type,
                    wait_category,
                    waiting_task_count,
                    total_active_wait_ms,
                    max_wait_ms,
                    session_count,
                    blocking_session_count
                FROM WaitSummary
                ORDER BY total_active_wait_ms DESC
                FOR JSON PATH
            )) AS top_waits,

            JSON_QUERY((
                SELECT TOP (10)
                    session_id,
                    wait_type,
                    wait_category,
                    wait_duration_ms,
                    blocking_session_id,
                    database_name,
                    status,
                    command,
                    cpu_time,
                    total_elapsed_time,
                    logical_reads,
                    reads,
                    writes,
                    login_name,
                    host_name,
                    program_name,
                    sql_text
                FROM ActiveWaits
                WHERE wait_type = ti.wait_type
                ORDER BY wait_duration_ms DESC
                FOR JSON PATH
            )) AS sample_waiting_sessions

        FROM TopIssue AS ti
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ) AS JsonOutput
WHERE EXISTS (SELECT 1 FROM TopIssue);