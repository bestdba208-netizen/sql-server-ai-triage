/*
    Detector: Memory Grant / RESOURCE_SEMAPHORE

    Purpose:
    Finds active queries that are either:
    - Waiting for a query memory grant
    - Holding very large memory grants
    - Wasting granted memory
    - Involved in RESOURCE_SEMAPHORE waits

    Output:
    One row with one column: JsonOutput
*/

SET NOCOUNT ON;

DECLARE @MinRequestedMemoryMB decimal(18,2) = 512.0;
DECLARE @MinGrantedMemoryMB   decimal(18,2) = 512.0;
DECLARE @MinWaitSeconds       decimal(18,2) = 5.0;
DECLARE @MinWastePercent      decimal(18,2) = 75.0;

;WITH MemoryGrantIssues AS
(
    SELECT TOP (25)
        issue_type =
            CASE
                WHEN mg.grant_time IS NULL THEN 'WAITING_FOR_MEMORY_GRANT'
                WHEN wt.wait_type = 'RESOURCE_SEMAPHORE' THEN 'RESOURCE_SEMAPHORE_WAIT'
                WHEN mg.granted_memory_kb >= (@MinGrantedMemoryMB * 1024)
                     AND mg.max_used_memory_kb > 0
                     AND ((mg.granted_memory_kb - mg.max_used_memory_kb) * 100.0 / NULLIF(mg.granted_memory_kb, 0)) >= @MinWastePercent
                    THEN 'EXCESSIVE_MEMORY_GRANT_WASTE'
                ELSE 'LARGE_MEMORY_GRANT'
            END,

        session_id = mg.session_id,
        request_id = mg.request_id,
        database_name = DB_NAME(er.database_id),

        login_name = es.login_name,
        host_name = es.host_name,
        program_name = es.program_name,

        status = er.status,
        command = er.command,

        wait_type = COALESCE(wt.wait_type, er.wait_type),
        wait_seconds = CONVERT(decimal(18,2), COALESCE(wt.wait_duration_ms, er.wait_time, 0) / 1000.0),

        requested_memory_mb = CONVERT(decimal(18,2), mg.requested_memory_kb / 1024.0),
        granted_memory_mb = CONVERT(decimal(18,2), mg.granted_memory_kb / 1024.0),
        required_memory_mb = CONVERT(decimal(18,2), mg.required_memory_kb / 1024.0),
        used_memory_mb = CONVERT(decimal(18,2), mg.used_memory_kb / 1024.0),
        max_used_memory_mb = CONVERT(decimal(18,2), mg.max_used_memory_kb / 1024.0),

        memory_waste_mb =
            CONVERT(decimal(18,2),
                CASE
                    WHEN mg.granted_memory_kb > mg.max_used_memory_kb
                    THEN (mg.granted_memory_kb - mg.max_used_memory_kb) / 1024.0
                    ELSE 0
                END
            ),

        memory_waste_percent =
            CONVERT(decimal(18,2),
                CASE
                    WHEN mg.granted_memory_kb > 0 AND mg.max_used_memory_kb >= 0
                    THEN ((mg.granted_memory_kb - mg.max_used_memory_kb) * 100.0 / mg.granted_memory_kb)
                    ELSE 0
                END
            ),

        dop = mg.dop,
        queue_id = mg.queue_id,
        resource_semaphore_id = mg.resource_semaphore_id,

        request_time = mg.request_time,
        grant_time = mg.grant_time,

        total_elapsed_seconds = CONVERT(decimal(18,2), er.total_elapsed_time / 1000.0),
        cpu_seconds = CONVERT(decimal(18,2), er.cpu_time / 1000.0),
        logical_reads = er.logical_reads,
        reads = er.reads,
        writes = er.writes,

        blocking_session_id = er.blocking_session_id,

        query_text =
            LEFT(
                REPLACE(REPLACE(st.text, CHAR(13), ' '), CHAR(10), ' '),
                4000
            )
    FROM sys.dm_exec_query_memory_grants AS mg
    LEFT JOIN sys.dm_exec_requests AS er
        ON mg.session_id = er.session_id
       AND mg.request_id = er.request_id
    LEFT JOIN sys.dm_exec_sessions AS es
        ON mg.session_id = es.session_id
    LEFT JOIN sys.dm_os_waiting_tasks AS wt
        ON mg.session_id = wt.session_id
    OUTER APPLY sys.dm_exec_sql_text(mg.sql_handle) AS st
    WHERE
        (
            mg.grant_time IS NULL
            OR wt.wait_type = 'RESOURCE_SEMAPHORE'
            OR mg.requested_memory_kb >= (@MinRequestedMemoryMB * 1024)
            OR mg.granted_memory_kb >= (@MinGrantedMemoryMB * 1024)
            OR COALESCE(wt.wait_duration_ms, er.wait_time, 0) >= (@MinWaitSeconds * 1000)
            OR
            (
                mg.granted_memory_kb > 0
                AND mg.max_used_memory_kb > 0
                AND ((mg.granted_memory_kb - mg.max_used_memory_kb) * 100.0 / NULLIF(mg.granted_memory_kb, 0)) >= @MinWastePercent
            )
        )
        AND mg.session_id <> @@SPID
    ORDER BY
        CASE WHEN mg.grant_time IS NULL THEN 0 ELSE 1 END,
        COALESCE(wt.wait_duration_ms, er.wait_time, 0) DESC,
        mg.requested_memory_kb DESC,
        mg.granted_memory_kb DESC
)
SELECT
    JsonOutput =
    (
        SELECT
            issue_type,
            session_id,
            request_id,
            database_name,
            login_name,
            host_name,
            program_name,
            status,
            command,
            wait_type,
            wait_seconds,
            requested_memory_mb,
            granted_memory_mb,
            required_memory_mb,
            used_memory_mb,
            max_used_memory_mb,
            memory_waste_mb,
            memory_waste_percent,
            dop,
            queue_id,
            resource_semaphore_id,
            request_time,
            grant_time,
            total_elapsed_seconds,
            cpu_seconds,
            logical_reads,
            reads,
            writes,
            blocking_session_id,
            query_text
        FROM MemoryGrantIssues
        FOR JSON PATH
    )
WHERE EXISTS (SELECT 1 FROM MemoryGrantIssues);