CREATE OR REPLACE PACKAGE trace is

  ------------
  --  OVERVIEW
  --  This package provides tracing utility using the Oracle DBMS_PIPE
  --  and UTL_FILE utilities. Messages will be sent over the pipes.
  --  Pipes are memory structures used by sessions to exchange information
  --  quickly with very little overhead. A pipe listener is running and
  --  waiting to receive information from database sessions.  When a
  --  message is received, it is decoded and processed (in most cases
  --  the message is a trace statement to be sent to a trace file) in 
  --  real-time.  This allows a developer to visualize the execution
  --  of a stored procedure as it is running.

  -----------------------
  --  SPECIAL NOTES
  --  In order to compile this package, the SELECT privilege must be granted
  --  on the following dynamic views:
  --    v_$session, v_$mystat, v_$statname, v$sesstat, v$process
  --  In addition the EXECUTE privilege must be granted on the DBMS_PIPE
  --  and UTL_FILE Oracle provided packages.

  -----------------------
  --  Revisions
  --  Name         Date       Comments
  --  ------------ ---------- ----------------------------------------------
  --#  comes       11/14/1999 created
  --#  comes       11/21/2002 added PROCEDURE close_listener_process
  --#  comes       08/25/2002 added statistics delta
  --#  gledford    12/29/2008 performance enhancement
  --#  comes       01/28/2010 adding "in-memory" tracing with new dump PROCEDURE
  --#  comes       11/15/2016 clean-up
  -----------------------
  -- EXCEPTIONS

  -----------------------
  -- PUBLIC CONSTANTS

  DEFAULT_PIPE_NAME  CONSTANT   VARCHAR2(16)     := 'DEBUG';
  FATAL              CONSTANT   PLS_INTEGER      := 0;
  WARNING            CONSTANT   PLS_INTEGER      := 1;
  INFO               CONSTANT   PLS_INTEGER      := 2;
  GREETING           CONSTANT   PLS_INTEGER      := 3;
  ERROR              CONSTANT   PLS_INTEGER      := 4;
  B4_LOOP            CONSTANT   PLS_INTEGER      := 5;
  IN_LOOP            CONSTANT   PLS_INTEGER      := 7;
  DEBUG              CONSTANT   PLS_INTEGER      := 9;
  -----------------------
  -- GLOBAL VARIABLES

  TYPE sesstat_table IS TABLE OF NUMBER(38) INDEX BY BINARY_INTEGER;

  -- main record type to hold information about the tracing
  TYPE trace_type IS RECORD (
         tracing                   BOOLEAN := FALSE,
         trace_id                  trace_logs.trace_id%TYPE := 0,
         sid                       trace_logs.session_id%TYPE := 0,
         serial_number             NUMBER  := 0,
         process_id                trace_logs.process_id%TYPE,
         trace_level               trace_config.trace_level%TYPE := 9,
         trace_flag                trace_config.trace_flag%TYPE,
         pipe_name                 VARCHAR2(16) := DEFAULT_PIPE_NAME,
         commit_interval           trace_config.commit_interval%TYPE ,
         flush_interval            trace_config.flush_interval%TYPE ,
         application_name          trace_config.application_name%TYPE,
         program_name              trace_config.program_name%TYPE,
         directory_name            trace_config.directory_name%TYPE,
         file_prefix               trace_config.file_prefix%TYPE,
         filename                  VARCHAR2 ( 64 ),
         debug_mode                trace_config.debug_mode%TYPE,
         sesstat                   sesstat_table,
         tag                       varchar2 ( 16 ),
         listener_count            number
         );

  u_trace                  trace_type;

  listener_id              utl_file.file_type;

  n_trace_commit_interval  trace_config.commit_interval%TYPE ;
  n_trace_flush_interval   trace_config.flush_interval%TYPE ;
  n_last_time              NUMBER;

  TYPE msg_table IS TABLE OF VARCHAR2 ( 256 ) INDEX BY BINARY_INTEGER;

  TYPE trace_message_record IS RECORD (
      trace_id             trace_logs.trace_id%TYPE,
      message              VARCHAR2 ( 256 ),
      message_timestamp    TIMESTAMP,
      application_name     trace_config.application_name%TYPE,
      program_name         trace_config.program_name%TYPE,
      trace_seq_no         NUMBER,
      trace_level          trace_config.trace_level%TYPE
      );

  TYPE trace_message_table IS TABLE OF trace_message_record INDEX BY BINARY_INTEGER;

   --t_trace_messages trace_message_table;

  CURSOR c_stat(cp_sid IN  NUMBER) IS
    SELECT statistic#, value
      FROM v$sesstat ss, v$session se
     WHERE ss.sid = se.sid
       AND se.sid||se.serial# = cp_sid;

  -----------------------
  -- PUBLIC FUNCTIONS / PROCEDURES

  -- Procedure to initialize the trace
  PROCEDURE init;

  -- Procedure to dump current messages in memory (in case of an exception)
  PROCEDURE dump;

  -- Returns the current trace level
  FUNCTION get_trace_level
    RETURN NUMBER;

  -- Returns the current module index
  FUNCTION get_current_module_index
    RETURN BINARY_INTEGER;

  -- Sets the current module index
  PROCEDURE set_current_module_index (p_current_module_index IN BINARY_INTEGER);

  -- Returns the current module executed
  FUNCTION get_current_module_name
    RETURN VARCHAR2;

  -- Sets the current module
  PROCEDURE set_current_module_name (p_current_module_name IN VARCHAR2);

  -- Returns the last debug message (used in unhandled exceptions)
  FUNCTION get_last_debug_message
    RETURN VARCHAR2;

  -- Send the message through the pipe
  --  Common Procedure to send message to the Listner.
  PROCEDURE send_message (
               p_msg_type        IN     NUMBER,
               p_message         IN     VARCHAR2 DEFAULT NULL,
               p_pipe_name       IN     VARCHAR2 DEFAULT DEFAULT_PIPE_NAME);

  -- Start a new trace in the session
  --  Procedure to set the tracing ON by sending Start signal to the Listner
  PROCEDURE start_trace(
               p_application_name  IN trace_config.application_name%TYPE,
               p_program_name      IN trace_config.program_name%TYPE,
               p_trace_level       IN NUMBER DEFAULT 9,
               p_tag_name          in VARCHAR2 DEFAULT NULL,
               p_pipe_name         IN VARCHAR2 DEFAULT DEFAULT_PIPE_NAME,
               p_debug_mode        IN VARCHAR2 DEFAULT 'N' );

  -- Stop tracing
  --  Procedure to Stop tracing by sending Stop signal to the Listner.
  PROCEDURE stop_trace;

  -- Resets the current session statistics
  PROCEDURE reset_stats;
  -- Dumps the current session statistics
  --  Useful to dump stats after execution of a costly SQL to peek into its
  --  execution without having to resort to TkProf during runtime.
  PROCEDURE dump_stats;

  PROCEDURE app ( p_debug_msg        IN     VARCHAR2 );

  -- Send a trace message
  PROCEDURE it (
              p_debug_msg        IN     VARCHAR2,
              p_trace_level      IN     PLS_INTEGER DEFAULT 9,
              p_trace_now        IN     BOOLEAN DEFAULT FALSE);

  -- Send a particular session level stat to the trace file
  --  Overloading Procedure to send the statistics information to the Listner.
  --  This will be used specifically for tunning purpose.
  PROCEDURE it(
               p_debug_stat      IN     NUMBER,
               p_trace_level     IN     PLS_INTEGER DEFAULT 1,
               p_trace_now       IN     BOOLEAN DEFAULT FALSE);


  --  Procedure to start the requested listener i.e. to open the requested pipe.
  --  This PROCEDURE also checks for the open listener. If the requested
  --   listener is already open this will give warning message.
  PROCEDURE listener(
               p_pipe_name       IN     VARCHAR2 DEFAULT DEFAULT_PIPE_NAME,
               p_silent_mode     IN     VARCHAR2 DEFAULT 'FALSE',
               p_debug_mode      IN     VARCHAR2 DEFAULT 'N' );

  --  Procedure to stop the requested listener.
  PROCEDURE stop_listener(
               p_pipe_name       IN     VARCHAR2 DEFAULT DEFAULT_PIPE_NAME);

  --  Procedure to close all files, remove the pipes and client_info entry
  PROCEDURE close_listener_process(
               p_pipe_name       IN     VARCHAR2);

  -- DEPRECATED
  --* vmandalika - 11/29/2006 - Added 3 new PROCEDUREs enter_module, exit_module and
  --* log_error to enhance the functionality of trace package
  PROCEDURE enter_module ( p_module_name IN VARCHAR2 );
  PROCEDURE exit_module  ( p_module_name IN VARCHAR2 := NULL );
  PROCEDURE log_error ( p_module_name IN VARCHAR2 );

END trace;
/
sho err
