SELECT
(
    SELECT TOP (1)
        'Blocking' AS issue_type,
        GETDATE() AS collected_at,
        DB_NAME() AS database_name,
        r.session_id,
        r.blocking_session_id,
        r.wait_type,
        r.wait_time,
        r.wait_resource,
        r.status,
        r.command,
        s.login_name,
        s.host_name,
        s.program_name,
        txt.text AS sql_text
    FROM sys.dm_exec_requests AS r
    JOIN sys.dm_exec_sessions AS s
        ON r.session_id = s.session_id
    OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS txt
    WHERE r.blocking_session_id <> 0
    ORDER BY r.wait_time DESC
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
) AS JsonOutput;