# Library QA A

Temporary Official Script Library test. It draws its version and saved marker and
writes one startup INFO log. It has no gameplay actions.

Version 1.1.0 requires hidden **Library QA Shared 1.0.0**. Core installs the missing
dependency automatically. The label and startup log show the loaded shared version.
Version 1.0.0 remains selectable and has no dependencies. Settings schema stays 1.

Keep QA A enabled and upgrade it to 1.1.0 while QA B remains at 1.0.0. Check the
shared version and Saved marker, then switch A to 1.0.0 and back to 1.1.0. Settings,
enabled state and script order should survive every successful change.
