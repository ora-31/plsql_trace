set serveroutput on 
exec trace.start_trace('BREEZE','ALL',9,'DEBUG','Y');
exec trace.it('testing');
exec trace.stop_trace;
exec trace.stop_listener;
