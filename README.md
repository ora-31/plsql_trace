# $(1:Project Name} - trace
PLSQL Trace Utility

## Installation
1. Edit the trcs.sql file and update the connections
2. Execute trcs.sql to grant all the necessary privileges as SYS
3. Connect as the owner schema
4. Execute trch.sql to compile the package header
5. Execute trcb.sql to compile the package body
6. Create a local directory on the filesystem
7. Map the directory to a database directory using the CREATE DIRECTORY command in Oracle
8. Update the directory name in the TRACE_CONFIG table

## Usage

You must have a session running the trace listener.  Simply open a SQL\*Plus window and execute:
`exec trace.listener`

### To start a Trace
Open a new session and start a trace
`exec trace.start_trace(&app_name, &prg_name);`
*app_name* is your application name as specified in the TRACE_CONFIG table
*prg_name* is your program name as specified in the TRACE_CONFIG table

### To send a debug/trace message
`exec trace.it('Hello World!');`
Make sure the trace_level in TRACE_CONFIG is set to 9

### To stop a Trace
`exec trace.stop_trace`

Check your directory and a trace file should have been created with the message **Hello World!**
