# Library QA B

Temporary Official Script Library test. It draws its version and saved marker and
writes one startup INFO log. It has no gameplay actions.

Version 1.1.0 requires hidden **Library QA Shared 1.0.0**. Its label and startup log
show the loaded shared version. Version 1.0.0 remains selectable and has no
dependencies. Settings schema stays 1.

Keep QA B enabled at 1.0.0 while testing QA A's upgrade and version switches. Then
update B to 1.1.0 and check both labels report shared 1.0.0 with their distinct
Saved markers preserved. Shared libraries stay installed when an older script
version no longer uses them.
