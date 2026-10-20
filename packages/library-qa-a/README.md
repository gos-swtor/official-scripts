# Library QA A

Temporary Official Script Library test. It draws its version and saved marker and
writes one startup INFO log. It has no gameplay actions.

Version 1.2.0 requires hidden **Library QA Shared 1.1.0**. The label and startup log
show the actual loaded shared version. Version 1.1.0 requires shared 1.0.0;
version 1.0.0 has no dependencies. Settings schema stays 1 for every version.

Keep both QA scripts enabled at 1.1.0. Select A 1.2.0 and inspect Apply plan:
QA A, QA B and the shared library must update together. Both labels and fresh
startup logs must report script 1.2.0, shared 1.1.0 and the original Saved markers.
Settings, enabled state and script order should survive every successful change.

Switching A alone back to 1.1.0 while B stays at 1.2.0 must fail without changes.
Remove B, switch A to 1.1.0, then install B 1.1.0 explicitly to test a compatible
older pair. Remove retains shared libraries and user settings.
