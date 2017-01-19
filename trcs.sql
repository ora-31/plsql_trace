prompt "Connecting as SYSDBA to grant privileges"
CONNECT SYS AS SYSDBA

GRANT SELECT ON v_$session  TO isscome;
GRANT SELECT ON v_$process  TO isscome;
GRANT SELECT ON v_$mystat   TO isscome;
GRANT SELECT ON v_$statname TO isscome;
GRANT SELECT ON v_$sesstat  TO isscome;
GRANT EXECUTE ON dbms_pipe  TO isscome;
GRANT EXECUTE ON dbms_utility TO isscome;
GRANT EXECUTE ON dbms_application_info TO isscome;

prompt "Connecting as ISSCOME"
CONNECT ISSCOME

CREATE TABLE trace_logs
( trace_id              NUMBER
, application_name      VARCHAR2 ( 32 )
, program_name          VARCHAR2 ( 32 )
, process_id            NUMBER
, session_id            NUMBER
, destination_type      CHAR ( 1 )
, destination_name      VARCHAR2 ( 64 )
, start_time            DATE
, end_time              DATE
);

CREATE TABLE trace_config
( application_name      VARCHAR2 ( 32 )
, program_name          VARCHAR2 ( 32 )
, directory_name        VARCHAR2 ( 32 )
, file_prefix           VARCHAR2 ( 32 )
, trace_flag            CHAR ( 1 )
, trace_level           NUMBER ( 1 )
, commit_interval       NUMBER ( 5 ) DEFAULT 10
, flush_interval        NUMBER ( 5 ) DEFAULT 10
, debug_mode            CHAR ( 1 )   DEFAULT 'N'
, tag_name              VARCHAR2 ( 16 )
);

INSERT INTO trace_config VALUES ( 'myapp', 'all',     'DBA_TOOLS', 'tr', 'Y', 9, 1, 1, 'N', null );
INSERT INTO trace_config VALUES ( 'myapp', 'trigger', 'DBA_TOOLS', 'tr', 'Y', 9, 1, 1, 'Y', null );
INSERT INTO trace_config VALUES ( 'myapp', 'changes', 'DBA_TOOLS', 'tr', 'Y', 9, 1, 1, 'Y', null );
COMMIT;

CREATE SEQUENCE trace_seq nocache;

