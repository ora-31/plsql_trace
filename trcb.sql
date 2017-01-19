CREATE OR REPLACE PACKAGE BODY trace IS

  --
  --  Procedure to start a new trace session.
  --    When the listener receives a start_trace request, it will get information
  --    for the program to trace from trace_info and enable the tracing.
  --    If there is a problem sending messages to the listener, the tracing will be
  --    automatically disabled in the session to avoid clogging the pipe and affect
  --    performance.
  --
  --    Additionally, the SQL*Trace event 10046 can be set.  Simply set the EVENT_NUMBER
  --    and the EVENT_LEVEL in the TRACE_INFO table.
  --
  -- jyang    10/04/05   commented out commit in start_trace() and add timeout 1 sec in send_message()
  -- comes    10/17/05   read status from programs table instead of trace_info.
  -- scome    11/22/05   removed the logging of "stop trace".
  -- jyang    01/10/06   Bug 64: Chg start_trace() to send trace_level for each session to the listener,
  --                             Chg listener() to print "close trace" info  base on trace_level.
  --                             commented out some loggings in listener().
  --                     Chg stop_trace() to send type 1 msg to listener only if u_trace.tracing = true
  -- comes    08/13/07   Cleared the trace file handler explicitely after sporadic INVALID OEPRATION
  --                     exception raised under Oracle 10gR2.
  -- comes    09/27/07   Added "last_message" sent
  -- mandalv  03/06/08   Added get_current_module_index, set_current_module_index,
  --                     get_current_module_name and set_current_module_name routines
  -- mandalv  07/17/08   In IT procedure, Changed pv_current_module_index to
  --                     LEAST(pv_current_module_index,4), so indentation doesn't
  --                     run into more than 3 levels (and doesnt't take up more 12 char)
  -- gledford 12/29/2008 Performance enhancement
  -- comes    01/28/2010 Added trace "init" and "dump" to report exceptions
  -- comes    02/03/2010 Added exception handling when dumping cjis.info
  -- comes    11/27/2013 Added return code on pipe when problem with trace

  --* Package Variables
  pv_current_module_index   NUMBER := 1;
  pv_current_module_name    VARCHAR2(200) := '';
  pv_start_time             TIMESTAMP ( 6 );
  pv_app_name               VARCHAR2 ( 32 );
  pv_prg_name               VARCHAR2 ( 64 );
  pv_msg_id                 VARCHAR2 ( 64 );

  TYPE trace_module_rec IS RECORD (
     module_name VARCHAR2(100),
     start_time  TIMESTAMP,
     end_time    TIMESTAMP
     --level       NUMBER
     --error_count NUMBER
     );

  TYPE trace_module_tab IS TABLE OF trace_module_rec
  INDEX BY BINARY_INTEGER;

  tmt trace_module_tab;

  --* routine
  TYPE trace_file_rec IS RECORD (
     application_name VARCHAR2(50),
     program_name     VARCHAR2(50),
     start_time       DATE,
     end_time         DATE
     );

  TYPE trace_file_tab IS TABLE OF trace_file_rec
  INDEX BY BINARY_INTEGER;

  trace_file_list TRACE_FILE_TAB;
  msgs            msg_table;
  t_msgs          trace_message_table;

  -- Type and variables added for GlobalContext Trace modification
  TYPE gctt_rectyp IS RECORD (
     ci_list   VARCHAR2(250),
     t_start   DATE,
     t_end     DATE
  );

  -- table of trace contexts index by app | mke | ori | mne
  TYPE gctt_tabtyp IS TABLE OF gctt_rectyp INDEX BY VARCHAR2(50);

  gctt gctt_tabtyp;

  -- counters for the trace context -- added 9/29/2011
  gctt_allowed_msgs  PLS_INTEGER;
  gctt_stopped_msgs  PLS_INTEGER;

  TYPE trace_stats_tab IS TABLE OF NUMBER INDEX BY VARCHAR2(128);
  gv_trace_stats    trace_stats_tab;

  FUNCTION get_trace_level
    RETURN NUMBER 
  IS
  BEGIN
    RETURN u_trace.trace_level;
  END get_trace_level;

  FUNCTION get_current_module_index
    RETURN BINARY_INTEGER
  IS
  BEGIN
     RETURN pv_current_module_index;
  END get_current_module_index;

  PROCEDURE set_current_module_index (p_current_module_index IN BINARY_INTEGER)
  IS
  BEGIN
     pv_current_module_index := p_current_module_index;
  END set_current_module_index;

  FUNCTION get_current_module_name
    RETURN VARCHAR2
  IS
  BEGIN
     RETURN pv_current_module_name;
  END get_current_module_name;

  PROCEDURE set_current_module_name (p_current_module_name IN VARCHAR2)
  IS
  BEGIN
     pv_current_module_name := p_current_module_name;
  END set_current_module_name;
 
  PROCEDURE say ( p_text   IN VARCHAR2 )
    IS
    BEGIN
      IF ( u_trace.debug_mode = 'Y' ) THEN
        dbms_output.put_line ( p_text );
      END IF;
    END say;

  FUNCTION get_last_debug_message
    RETURN VARCHAR2
    IS
    BEGIN
      --RETURN pv_last_message;
      RETURN t_msgs(t_msgs.COUNT).message;
    END get_last_debug_message;

  FUNCTION elapsed_time_formatted (
     p_start_timestamp IN DATE,
     p_end_timestamp   IN DATE
     )
    RETURN VARCHAR2
  IS

     v_elapsed_time           VARCHAR2(200);
     v_elapsed_time_formatted VARCHAR2(200);
     v_hr                     NUMBER;
     v_min                    NUMBER;
     v_sec                    NUMBER;


  BEGIN

     v_elapsed_time := SUBSTR(
                          p_end_timestamp - p_start_timestamp,
                          INSTR( p_end_timestamp - p_start_timestamp, ' ', 1 )+1
                          );

     v_hr  := TO_NUMBER ( SUBSTR ( v_elapsed_time, 1, INSTR ( v_elapsed_time,':', 1 ) -1 ) );
     v_min := TO_NUMBER ( SUBSTR ( v_elapsed_time, INSTR ( v_elapsed_time,':',1,1 ) +1, INSTR (v_elapsed_time,':',1,2 ) -INSTR ( v_elapsed_time,':',1,1)-1 ) );
     v_sec := TO_NUMBER ( SUBSTR ( v_elapsed_time, INSTR ( v_elapsed_time,':',1,2 ) +1 ) );

     v_sec := ( v_hr*3600 ) + ( v_min*60 ) + ( v_sec );
     v_elapsed_time_formatted := v_sec|| ' sec';

     RETURN v_elapsed_time_formatted;

  END elapsed_time_formatted;

  ------------------------------------------------------------------------------
  -- Start a trace
  --   This procedure is called by a program that wants to enable the trace for
  --   its current session.  The procedure will check that a trace listener is
  --   active before enabling the trace.  If a trace listener is not active,
  --   the session will not enable the trace.
  ------------------------------------------------------------------------------
  PROCEDURE start_trace(
              p_application_name  IN trace_config.application_name%TYPE,
              p_program_name      IN trace_config.program_name%TYPE,
              p_trace_level       IN NUMBER DEFAULT 9,
              p_tag_name          IN VARCHAR2 DEFAULT NULL,
              p_pipe_name         IN VARCHAR2 DEFAULT DEFAULT_PIPE_NAME,
              p_debug_mode        IN VARCHAR2 DEFAULT 'N' )
    IS

      v_app_name          VARCHAR2(16) := 'BREEZE';  -- default app name
      v_file_index        NUMBER;

    BEGIN

      --* re-setting the module name and index
      IF ( pv_current_module_index IS NULL ) THEN
         pv_current_module_index := 1;
         pv_current_module_name  := '';
         tmt.DELETE;
      END IF;

      --* override the current debug mode
      u_trace.debug_mode := p_debug_mode;
 
      --* vmandalika - 12/01/2006 - If there are no OPEN trace files trace_file_list
      --* array, add the new AppName/PgmName trace file as the first element of the
      --* array. If there are already some open trace file names in the array, add
      --* this file name as the last element of the list.
      IF ( trace_file_list.COUNT = 0 ) THEN
         --* initialize the index at 1
         v_file_index := 1;
      ELSE
         v_file_index := trace_file_list.LAST + 1;
      END IF;

      trace_file_list ( v_file_index ).application_name := p_application_name;
      trace_file_list ( v_file_index ).program_name     := p_program_name;
      trace_file_list ( v_file_index ).start_time       := SYSDATE;

      --* Only executes if the current session is not already in trace mode.
      --* If currentlty tracing, ignore this step (redundant)
      IF ( NOT ( u_trace.tracing ) OR
           ( u_trace.application_name <> NVL ( p_application_name, 'NULL' ) OR
             u_trace.program_name     <> NVL ( p_program_name, 'NULL' )  )  ) THEN

        --* capture current time
        n_last_time := dbms_utility.get_time();

        say ( 'start_trace called' );

        u_trace.application_name  := p_application_name;  -- set the application name
        u_trace.program_name      := p_program_name;      -- set the program name
        u_trace.trace_level       := p_trace_level;       -- set the trace level (1-9)
        u_trace.pipe_name         := p_pipe_name;         -- set the pipe to use for messages
        u_trace.tag               := p_tag_name;          -- set a tag name

        -- Get the tracing information for this application/program
        --  The matching combination is not case sensitive
        say ( 'application_name='|| p_application_name );

        SELECT NVL ( trace_level, p_trace_level ) trace_level
             , UPPER ( trace_flag ) trace_flag
             , directory_name
             , file_prefix
             , flush_interval
             , DECODE ( UPPER( p_debug_mode ), 'Y', 'Y', debug_mode )
          INTO u_trace.trace_level
             , u_trace.trace_flag
             , u_trace.directory_name
             , u_trace.file_prefix
             , u_trace.flush_interval
             , u_trace.debug_mode
          FROM trace_config
         WHERE application_name = p_application_name 
           AND program_name = p_program_name
           AND ROWNUM = 1;

        IF ( u_trace.trace_flag = 'Y' ) THEN

          --* trace flag set to Yes 
          say ( 'trace_level='|| u_trace.trace_level );

          -- get the current sid and serial# from the v$session view
          u_trace.sid := sys_context ( 'USERENV', 'SID' );

          u_trace.filename := p_application_name ||'_'|| p_program_name||
                              '_'|| TO_CHAR ( SYSDATE, 'MMDD' ) ||'.trc';
                              --'_'|| u_trace.sid ||'.trc';

          -- gledford 12/29/2008 - don't execute query if already tracing to improve performance
          IF ( NOT ( u_trace.tracing ) ) THEN

             --* Check if listener is running for this pipe
             SELECT COUNT(*)
               INTO u_trace.listener_count
               FROM v$session
              WHERE client_info = u_trace.pipe_name;

             IF ( u_trace.listener_count = 1 ) THEN
               u_trace.tracing := TRUE;
             END IF;

          END IF;

          SELECT trace_seq.NEXTVAL
            INTO u_trace.trace_id
            FROM dual;

          -- send the message to the listener that trace started for this session
          IF ( u_trace.tracing ) THEN
            send_message(3);
           END IF;

        ELSE
          u_trace.tracing := FALSE;
        END IF;

      END IF;

    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        NULL;
      WHEN OTHERS THEN
        say ( SQLERRM|| ' In start trace' );

    END start_trace; -- Start_trace

  PROCEDURE send_message (
              p_msg_type         IN     NUMBER,
              p_message          IN     VARCHAR2 DEFAULT NULL,
              p_pipe_name        IN     VARCHAR2 DEFAULT DEFAULT_PIPE_NAME)
 
    IS
      n_return                NUMBER := 0;
      v_trace_message_no      VARCHAR2 ( 128 );
      v_application_name      VARCHAR2 ( 128 );
      v_program_name          VARCHAR2 ( 128 );

    BEGIN

      IF ( u_trace.tracing ) THEN

        say ( 'sending msg type '|| p_msg_type ||' '|| p_message );

        -- Message Types
        --   0  => debug message
        --   1  => stop trace
        --   2  => kill listener
        --   3  => start trace
        --   4  => application specific
 
        dbms_pipe.pack_message ( p_msg_type );
        dbms_pipe.pack_message ( u_trace.sid );

        IF ( p_msg_type = 0 ) THEN
          dbms_pipe.pack_message ( p_message );
          dbms_pipe.pack_message ( v_trace_message_no );
          dbms_pipe.pack_message ( u_trace.trace_level );

        ELSIF ( p_msg_type = 3 ) THEN
          dbms_pipe.pack_message ( u_trace.trace_id );
          dbms_pipe.pack_message ( u_trace.filename );
          dbms_pipe.pack_message ( u_trace.application_name );
          dbms_pipe.pack_message ( u_trace.program_name );
          dbms_pipe.pack_message ( u_trace.trace_level );
          dbms_pipe.pack_message ( u_trace.directory_name );
          dbms_pipe.pack_message ( u_trace.debug_mode );
          dbms_pipe.pack_message ( u_trace.tag );

        ELSIF ( p_msg_type = 4 ) THEN
          dbms_pipe.pack_message ( p_message );

        END IF;

        say('Message packed!');

        n_return := dbms_pipe.send_message ( NVL ( p_pipe_name, u_trace.pipe_name ), 1 );
        IF ( n_return <> 0 ) THEN
          -- problem with the pipe, abort the trace!
          say ( 'problem with the pipe, abort the trace! ret='|| n_return );
          u_trace.tracing := FALSE;
        END IF;

        say ( 'message sent...' );

      END IF;

    EXCEPTION
      WHEN OTHERS THEN
        say(sqlerrm ||' in send_message()' );
        u_trace.tracing := FALSE;
    END;

  PROCEDURE stop_trace
    IS

    BEGIN

       IF ( u_trace.tracing ) THEN
         send_message ( 1 );
         u_trace.tracing := FALSE;
       END IF;

       --* vmandalika - 12/01/2006 - When STOP_TRACE() is called, we need to stop adding trace log entries to
       --* the most current AppName/PgmName trace file, and start writing log entries to the previous AppName/PgmName
       --* trace file.
       --* So, we are deleting the last AppName/PgmName added to trace_file_list array, and if the array
       --* still retains an OPEN AppName/PgmName trace file, tracing control is returned to that file.
       IF ( trace_file_list.COUNT > 0 ) THEN

          trace_file_list.DELETE ( trace_file_list.LAST );

          IF ( trace_file_list.COUNT > 0 ) THEN
             trace.start_trace (
                trace_file_list ( trace_file_list.LAST ).application_name,
                trace_file_list ( trace_file_list.LAST ).program_name
                );
          END IF;

       END IF;

    EXCEPTION
      WHEN OTHERS THEN
         say(sqlerrm ||' in stop_trace()' );

    END stop_trace;  -- Stop_trace

  PROCEDURE reset_stats
    IS
    BEGIN

      FOR rec IN ( SELECT st.name, ss.value
                     FROM v$sesstat ss, v$statname st
                    WHERE st.statistic# = ss.statistic#
                      AND ss.sid = SYS_CONTEXT('USERENV','SID')
                      AND st.statistic# IN (9,84,88,94,194,630,631,632,640,641)
                 )
      LOOP
        gv_trace_stats(rec.name) := rec.value;
      END LOOP;

    END reset_stats;

  PROCEDURE dump_stats
    IS
    BEGIN

      FOR rec IN ( SELECT st.name, ss.value
                     FROM v$sesstat ss, v$statname st
                    WHERE st.statistic# = ss.statistic#
                      AND ss.sid = SYS_CONTEXT('USERENV','SID')
                      AND st.statistic# IN (9,84,88,94,194,630,631,632,640,641)
                    ORDER BY st.statistic# ASC
                 )
      LOOP
        IF ( rec.value - gv_trace_stats(rec.name) > 0 ) THEN
          it(to_char(rec.value - gv_trace_stats(rec.name),'999,999,999') ||' '|| rec.name,5);
        END IF;
      END LOOP;
    END dump_stats;

  PROCEDURE it (
              p_debug_stat       IN     NUMBER,
              p_trace_level      IN     PLS_INTEGER DEFAULT 1,
              p_trace_now        IN     BOOLEAN DEFAULT FALSE )
    IS

      n_value      v$sesstat.value%TYPE;
      n_delta      NUMBER ( 38 );
      v_message    VARCHAR2 ( 256 );

    BEGIN

      IF ( u_trace.tracing ) THEN

        SELECT a.value, b.name
          INTO n_value, v_message
          FROM v$mystat a, v$statname b
         WHERE a.statistic# = b.statistic#
           AND a.statistic# = TO_NUMBER ( p_debug_stat );

         BEGIN
           n_delta := n_value - u_trace.sesstat ( p_debug_stat );
           v_message := 'Stat: '|| n_delta ||'/'|| n_value ||' => '|| v_message;
         EXCEPTION
           WHEN NO_DATA_FOUND THEN
              v_message := 'Stat: '|| n_value ||' => '|| v_message;
         END;
         u_trace.sesstat ( p_debug_stat ) := n_value;

         IF ( p_trace_level <= u_trace.trace_level ) THEN
            send_message ( 0, v_message );
            say('trace_level '||u_trace.trace_level);
         END IF;

      END IF;

    EXCEPTION
      WHEN OTHERS THEN
        say ( SQLERRM ||'In Debug Statistics' );

    END it;


  PROCEDURE app ( p_debug_msg        IN     VARCHAR2 )
    IS
    BEGIN
      IF ( u_trace.tracing ) THEN
        send_message(4, p_debug_msg);
      END IF;
    END app;
          
  PROCEDURE it (
              p_debug_msg        IN     VARCHAR2,
              p_trace_level      IN     PLS_INTEGER DEFAULT 9,
              p_trace_now        IN     BOOLEAN DEFAULT FALSE )
    IS

      msg    trace_message_record;

      PROCEDURE store_debug_msg_in_memory ( p_debug_msg IN VARCHAR2 ) IS
        BEGIN
          --* store the first 256 characters of p_debug_msg in memory
          msg.message_timestamp := SYSTIMESTAMP;
          msg.message := SUBSTR ( p_debug_msg, 1, 256 );
          t_msgs ( t_msgs.COUNT +1 ) := msg;
        END;

    BEGIN

      IF ( t_msgs.COUNT > 5000 ) THEN
        init;
      END IF;

         BEGIN

            --pv_last_message := substr(p_debug_msg,1,254);
            IF ( u_trace.tracing ) THEN
              IF ( p_trace_level <= u_trace.trace_level ) THEN

                   say ( p_debug_msg );
                   IF ( TRIM ( pv_current_module_name ) IS NOT NULL ) THEN
                      send_message(
                        0,
                        SUBSTR ( LPAD (' ', 4*( LEAST ( pv_current_module_index, 4 ) -1 ), '.' )||
                                '('|| pv_current_module_name ||'): '|| p_debug_msg, 1, 250
                                )
                        );
                   ELSE
                      send_message(
                        0,
                        SUBSTR ( LPAD(' ', 4*( LEAST ( pv_current_module_index, 4 ) -1 ), '.')||
                                p_debug_msg, 1, 250
                                )
                        );
                   END IF;
              ELSE
                 store_debug_msg_in_memory ( p_debug_msg );
              END IF;
            ELSE
               store_debug_msg_in_memory ( p_debug_msg );
            END IF;

            EXCEPTION
              WHEN OTHERS THEN
              dump;
              say ( 'In Debug Msg session_id:'|| u_trace.sid ||'--'|| p_debug_msg ||'--'|| SQLERRM );

         END;

    END;

  PROCEDURE stop_listener(
              p_pipe_name        IN      VARCHAR2 DEFAULT DEFAULT_PIPE_NAME)
    IS

    BEGIN
       send_message ( 2, null, p_pipe_name );
    END stop_listener;

  PROCEDURE listener (
              p_pipe_name        IN      VARCHAR2 DEFAULT DEFAULT_PIPE_NAME,
              p_silent_mode      IN      VARCHAR2 DEFAULT 'FALSE',
              p_debug_mode       IN      VARCHAR2 DEFAULT 'N'
      )
   IS

      n_count                  PLS_INTEGER    := 0;
      n_file_record_count      NUMBER ( 38 )  := 0; --record count for file
      n_table_record_count     PLS_INTEGER    := 0; --record count for table
      n_msg_type               PLS_INTEGER    := 0;
      n_return                 PLS_INTEGER;
      n_sid                    PLS_INTEGER;

      v_time                   VARCHAR2 ( 24 );
      v_directory              VARCHAR2 ( 128 );   --The file location
      v_message                VARCHAR2 ( 1024 );
      v_dbg                    VARCHAR2 ( 80 );
      v_filemode               VARCHAR2 ( 1 ) := 'A';

      b_exists                 BOOLEAN;
      n_file_length            NUMBER;
      n_blocksize              NUMBER;
      v_tmp_handler            utl_file.file_type;

      LISTENER_ALREADY_RUNNING EXCEPTION;

      PRAGMA EXCEPTION_INIT ( LISTENER_ALREADY_RUNNING, -20008 );

      file_id                  utl_file.file_type;

      TYPE trace_table IS TABLE OF trace_type INDEX BY BINARY_INTEGER;
      trace_tab    trace_table;

      TYPE file_table IS TABLE OF utl_file.file_type INDEX BY BINARY_INTEGER;

      file_tab                 file_table;
      v_message_id             VARCHAR2 ( 128 );
      v_trace_message_no       VARCHAR2 ( 128 );
      v_application_name       VARCHAR2 ( 128 );
      v_program_name           VARCHAR2 ( 128 );
      n_trace_level            NUMBER;

    BEGIN
  
      u_trace.debug_mode       := UPPER ( p_debug_mode );
      u_trace.commit_interval  := 10;
      u_trace.flush_interval   := 1;


      say ( 'starting listener...' );
      -- check to see if no other listener is running
      SELECT COUNT(*) 
        INTO n_count
        FROM v$session
       WHERE client_info = UPPER ( p_pipe_name );

      IF ( n_count > 0 ) THEN
        say ( 'Found '|| n_count ||' instance(s) of Listener running!' );
        RAISE LISTENER_ALREADY_RUNNING;
      ELSE
        -- set the listner name
        say ( 'No listener running' );
        n_return := dbms_pipe.create_pipe ( p_pipe_name, 32768, FALSE );
        dbms_application_info.set_client_info ( UPPER ( p_pipe_name ) );
      END IF;

      --* Start the listener trace
      v_directory := 'MYDIR';
      say ( 'opening listener trace in '|| v_directory );
      listener_id := utl_file.fopen ( v_directory, 'listener_'|| p_pipe_name ||
                                      '_'|| TO_CHAR ( SYSDATE, 'YYYYMMDDHH24MI' ) ||'.trc', 'W' );
      -- start the listner in an infinite loop
      LOOP  <<main_loop>>

        BEGIN

          v_dbg := 'wait for message';
          say ( v_dbg );
          n_return := dbms_pipe.receive_message ( p_pipe_name );
          say ( 'received msg '|| n_return );
          v_time := SUBSTR ( TO_CHAR ( SYSTIMESTAMP, 'MM/DD/YY HH24:MI:SS.FF' ), 1, 21 );
          say ( v_time );
 
          IF ( n_return = 0 ) THEN
            --* received a message
            dbms_pipe.unpack_message ( n_msg_type );
            v_dbg := 'unpack n_msg_type';
            say ( 'unpacked msg_type='|| n_msg_type );

            --* extract the SID
            dbms_pipe.unpack_message ( n_sid );
            v_dbg := 'unpack n_sid';
            say ( v_dbg );

            IF ( n_msg_type = 0 ) THEN

              -- normal debug message
              dbms_pipe.unpack_message ( v_message );
              dbms_pipe.unpack_message ( v_trace_message_no );
              dbms_pipe.unpack_message ( n_trace_level );

              v_dbg := 'unpack '|| LENGTH ( v_message );
              say ( 'unpacked msg len='|| LENGTH ( v_message ) );
              say ( v_message );

              BEGIN

                  utl_file.put_line ( file_tab ( n_sid ), v_time ||' ['|| n_sid ||
                                      ']['|| trace_tab ( n_sid ).program_name ||
                                      ']['||  trace_tab ( n_sid ).tag ||'] '||
                                      SUBSTR ( v_message, 1, 250 ) );
                  v_dbg := 'utl_filed';
                  n_file_record_count := n_file_record_count+1 ;

              EXCEPTION
                WHEN NO_DATA_FOUND THEN
                  -- ignore the message
                  --utl_file.put_line(listener_id,v_time||'no trc('||n_sid||'): '||substr(v_message,1,200));
                  NULL;
              END;

            ELSIF ( n_msg_type = 4 ) THEN
              dbms_pipe.unpack_message ( v_message );
              BEGIN
                  utl_file.put_line ( file_tab ( n_sid ), v_time ||' ['|| n_sid ||
                                      ']['|| trace_tab ( n_sid ).program_name ||
                                      ']['||  trace_tab ( n_sid ).tag ||'] >>'||
                                      SUBSTR ( v_message, 1, 250 ) );
                  n_file_record_count := n_file_record_count+1 ;
              EXCEPTION
                WHEN NO_DATA_FOUND THEN
                  NULL;
              END;

            ELSIF ( n_msg_type = 1 ) THEN

              -- stop tracing for current session
              -- utl_file.put_line(listener_id,v_time||' stop trace for '||n_sid);
              BEGIN

                  IF ( utl_file.is_open ( file_tab ( n_sid ) ) ) THEN
                    IF ( trace_tab ( n_sid ).trace_level = 9 ) THEN
                      utl_file.put_line ( file_tab ( n_sid ), v_time ||' close trace file' );
                    END IF;

                    utl_file.fflush ( file_tab ( n_sid ) );
                    utl_file.fclose ( file_tab ( n_sid ) );
                    -- added the next line after experiencing sporadic invalid operations
                    -- under 10g.
                    file_tab ( n_sid ) := null;
                    --u.say('stopped trace--'|| 'after closing file');

                    IF ( trace_tab ( n_sid ).trace_level = 9 ) THEN
                       utl_file.put_line ( listener_id, v_time ||' file closed' );
                    END IF;
                  END IF;

                say('about to update trace_logs');
                --utl_file.put_line(listener_id,v_time||' update trace_logs');

                UPDATE trace_logs
                   SET end_time = SYSDATE
                 WHERE trace_id = trace_tab ( n_sid ).trace_id;
                --utl_file.put_line(listener_id,v_time||
                --                 ' updated '||sql%rowcount||' row(s) in trace_logs');

                trace_tab.DELETE ( n_sid );
                --utl_file.put_line(listener_id,v_time||
                --                  ' removed '||n_sid||' from trace_tab');
                COMMIT;

              EXCEPTION
                WHEN NO_DATA_FOUND THEN
                  -- ignore the message
                  --utl_file.put_line(listener_id,v_time||
                  --                  ' no data found here...');
                  NULL;

              END;

            ELSIF ( n_msg_type = 2 ) THEN

               --  kill the listner process
              utl_file.put_line ( listener_id, v_time ||
                                  ' kill message received. shuting down listener!' );
              WHILE ( trace_tab.count > 0 ) LOOP
                n_sid := trace_tab.last;

                IF ( trace_tab ( n_sid ).trace_level = 9 ) THEN
                   utl_file.put_line ( listener_id, v_time ||'closing sid# '|| n_sid );
                END IF;

                  IF ( utl_file.is_open ( file_tab ( n_sid ) ) ) THEN
                    IF ( trace_tab ( n_sid ).trace_level = 9 ) THEN
                      utl_file.put_line ( file_tab ( n_sid ), v_time ||' listener closing trace file' );
                    END IF;
                    trace_tab.delete ( n_sid );
                    utl_file.put_line ( listener_id, v_time ||' close ok!' );
                  END IF;

              END LOOP;

              close_listener_process ( p_pipe_name );
              dbms_application_info.set_client_info(null);
              COMMIT;
              EXIT;  -- Exit from the loop

            ELSIF ( n_msg_type = 3 ) THEN

              --* Start message received

              trace_tab ( n_sid ).sid := n_sid;
              say ( 'start tracing session '|| n_sid ||', tracing a total of '|| file_tab.count ||' sessions' );

              dbms_pipe.unpack_message ( trace_tab ( n_sid ).trace_id );
              dbms_pipe.unpack_message ( trace_tab ( n_sid ).filename );
              dbms_pipe.unpack_message ( trace_tab ( n_sid ).application_name );
              dbms_pipe.unpack_message ( trace_tab ( n_sid ).program_name );
              dbms_pipe.unpack_message ( trace_tab ( n_sid ).trace_level );
              dbms_pipe.unpack_message ( trace_tab ( n_sid ).directory_name );
              dbms_pipe.unpack_message ( trace_tab ( n_sid ).debug_mode );
              dbms_pipe.unpack_message ( trace_tab ( n_sid ).tag );

              v_dbg := 'unpacked message successful';
              say ( v_dbg );

              v_dbg := 'tracing into file for '|| n_sid;
              utl_file.put_line ( listener_id, v_time ||' opening '||
                                  trace_tab ( n_sid ).directory_name ||
                                  '/'|| trace_tab ( n_sid ).filename );

              utl_file.fgetattr ( trace_tab ( n_sid ).directory_name
                                , trace_tab ( n_sid ).filename
                                , b_exists, n_file_length, n_blocksize );

              IF ( b_exists ) THEN
                v_filemode := 'A';
                say ( 'file exists, open in A mode, len='|| n_file_length ||', blocksize='|| n_blocksize );
              ELSE
                v_filemode := 'W';
                say ( 'file not found, open in W mode');
              END IF;

              --* check if file already registered from a previous session
              BEGIN
                v_tmp_handler := file_tab ( n_sid );
                say ( 'humm... handler still there.  closing the file');
                utl_file.fclose ( v_tmp_handler );
                file_tab ( n_sid ) := null;
              EXCEPTION
                WHEN NO_DATA_FOUND THEN
                  NULL;
                  --debug(listener_id, 'NO HANDLER found');
              END;

              v_dbg := 'about to open file '||trace_tab(n_sid).filename;
              say ( v_dbg );
              file_tab ( n_sid ) := utl_file.fopen ( trace_tab ( n_sid ).directory_name
                                                   , trace_tab ( n_sid ).filename
                                                   , v_filemode );
              IF ( trace_tab ( n_sid ).trace_level = 9 ) THEN
                utl_file.put_line ( file_tab ( n_sid ), v_time ||' start tracing' );
              END IF;

            END IF;  -- n_msg_type

          END IF;  -- return

        EXCEPTION
          WHEN UTL_FILE.INVALID_PATH THEN
            say ( n_sid ||' Problem in listener - Invalid Path' );

          WHEN UTL_FILE.INVALID_MODE THEN
            say ( n_sid ||' Problem in listener - Invalid Mode' );

          WHEN UTL_FILE.INVALID_FILEHANDLE THEN
            say ( n_sid ||' Problem in listener - Invalid FILEHANDLE' );

          WHEN UTL_FILE.INVALID_OPERATION THEN
            say ( n_sid ||' Problem in listener - Invalid OPERATION' );

          WHEN UTL_FILE.READ_ERROR THEN
            say ( n_sid ||' Problem in listener - READ_ERROR ' );

          WHEN UTL_FILE.WRITE_ERROR THEN
            say ( n_sid ||' Problem in listener - WRITE_ERROR' );

          WHEN UTL_FILE.INTERNAL_ERROR THEN
            say ( n_sid ||' Problem in listener - INTERNAL_ERROR ' );

          WHEN OTHERS then
            NULL;
            say('Listener INTERNAL_ERROR '|| SQLCODE );
        END;


        IF ( n_file_record_count >= u_trace.flush_interval ) THEN
          utl_file.fflush ( file_tab ( n_sid ) );
          n_file_record_count := 0;
        END IF;

        utl_file.fflush ( listener_id );

      END LOOP;

    EXCEPTION
      WHEN LISTENER_ALREADY_RUNNING THEN
        IF ( p_silent_mode = 'FALSE' ) THEN
          say ( 'Listener already running!' );
        END IF;

      WHEN OTHERS THEN
        close_listener_process ( p_pipe_name );
        dbms_application_info.set_client_info(null);
        say ( v_dbg );
        say ( 'listener: '|| SQLERRM );
    END;

  PROCEDURE close_listener_process (
               p_pipe_name       IN     VARCHAR2 )
    IS

      n_return       PLS_INTEGER;

    BEGIN
      utl_file.fclose_all; -- Close all Open files
      n_return := dbms_pipe.remove_pipe ( p_pipe_name );
      dbms_application_info.set_client_info ( NULL );
    END;

  --* vmandalika - 11/29/2006 - Added procedure enter_module()
  PROCEDURE enter_module ( p_module_name IN VARCHAR2 )
  IS
     v_index NUMBER;
  BEGIN

     IF tmt.COUNT = 0
     THEN

        v_index := 1;
        trace.it( RPAD('=',80,'=') );

     ELSE

        v_index := tmt.LAST+1;

     END IF;

     pv_current_module_index  := v_index;
     pv_current_module_name   := p_module_name;

     tmt(v_index).module_name := p_module_name;
     tmt(v_index).start_time  := SYSTIMESTAMP;

     trace.it('Entering '||p_module_name);

  END enter_module;


  --* vmandalika - 11/29/2006 - Added procedure exit_module()
  PROCEDURE exit_module ( p_module_name IN VARCHAR2 := NULL )
  IS

     v_index NUMBER;
     v_elapsed_time VARCHAR2(100);
     v_elapsed_time_formatted VARCHAR2(200);

   BEGIN

      IF tmt.EXISTS(pv_current_module_index)
      THEN

         tmt(pv_current_module_index).end_time  := SYSTIMESTAMP;
         trace.it('Exiting '||p_module_name||'; Elapsed Time = '||
                  elapsed_time_formatted( tmt(pv_current_module_index).start_time, tmt(pv_current_module_index).end_time)
                  );

         tmt.DELETE(pv_current_module_index);

         IF tmt.COUNT > 0
         THEN
            pv_current_module_index := tmt.LAST;
            pv_current_module_name := tmt(pv_current_module_index).module_name;
         END IF;

     END IF;

  END exit_module;

  PROCEDURE log_error ( p_module_name IN VARCHAR2 )
  IS
     v_index NUMBER;
  BEGIN

     trace.it('Oracle Error. SQLCode = '||SQLCODE||'; SQL Error Msg = '|| SUBSTR(SQLERRM,1,200) );
     trace.exit_module( p_module_name );

  END log_error;

  PROCEDURE init
    IS
      msg     trace_message_record;
    BEGIN

      --* initialize the message in memory
      t_msgs.DELETE;
      pv_start_time         := SYSTIMESTAMP;
      msg.trace_id          := 0;
      msg.message           := 'Initialize trace...';
      msg.message_timestamp := SYSTIMESTAMP;
      msg.trace_seq_no      := 0;
      msg.trace_level       := 0;
      t_msgs(1) := msg;

    END init;

  PROCEDURE dump
    IS
      v_directory        trace_config.directory_name%TYPE;
      v_filename         VARCHAR2 ( 32 );
      v_app_name         trace_config.application_name%TYPE;
      v_now              VARCHAR2 ( 24 );
      v_end_time         TIMESTAMP ( 6 );
      v_interval         INTERVAL DAY TO SECOND;

      v_filemode         VARCHAR2 (  1 );
      v_fh               utl_file.file_type;

      my_info            VARCHAR ( 64 );

      b_exists           BOOLEAN;
      n_file_len         NUMBER;
      n_blocksize        NUMBER;
      v_error_msg        VARCHAR2 ( 256 );

    BEGIN

      say ( 'DUMP CALLED' );
      --* dump current memory information to trace

      v_now          := TO_CHAR ( SYSDATE, 'YYYYMMDD' );
      v_end_time     := SYSTIMESTAMP;
      v_interval     := v_end_time - pv_start_time;

      v_directory := NVL ( u_trace.directory_name, 'MYDIR' );
      say ( v_directory );

      v_filename     := 'E_'|| v_now ||'.trc';
      say ( v_filename );

      trace.it ( 'opening file '|| v_filename ||' in '||v_directory );
      utl_file.fgetattr ( v_directory, v_filename, b_exists, n_file_len, n_blocksize );

      IF ( b_exists ) THEN
        v_filemode := 'A';
      ELSE
        v_filemode := 'W';
      END IF;

      say ( 'about to open file '|| v_filename );
      v_fh := utl_file.fopen ( v_directory, v_filename, v_filemode );

      --* title
      it ( 'Trace Dump ' );
      it ( '------------------------------------------------------------------------------' );
      it ( 'Dump time: '|| TO_CHAR ( SYSDATE, 'DD-MON-YY HH24:MI:SS' ) ||'   Elapsed time: '|| v_interval );
      it ( ' ' );

      it ( 'Client Info:    '|| SYS_CONTEXT ( 'USERENV', 'CLIENT_INFO' ) );
      it ( 'Oracle ID:      '|| SYS_CONTEXT ( 'USERENV', 'SID' ) );
      it ( ' ' );
      it ( 'Trace stack' );
      it ( '------------------------------------------------------------------------------' );
      v_end_time := pv_start_time;
      FOR msg IN t_msgs.FIRST..t_msgs.LAST LOOP
        v_interval := v_end_time - t_msgs ( msg ).message_timestamp;
        it ( SUBSTR ( t_msgs ( msg ).message_timestamp, 11, 12 ) ||
            ' ['|| SUBSTR ( v_interval, -8 ) ||'] '||
            t_msgs ( msg ).message );
        v_end_time := t_msgs ( msg ).message_timestamp;
      END LOOP;

      -- clear out the messages from memory
      --t_msgs.DELETE;
      utl_file.fclose ( v_fh );

    EXCEPTION
      WHEN OTHERS THEN
        it ( 'PROBLEM WITH TRACE.DUMP!!' );
        say ( 'PROBLEM WITH TRACE.DUMP!!' );
    END dump;

END trace;
/
sho err

