# Library QA B

Temporary Official Script Library test. It draws its version and saved marker and
writes one startup INFO log. It has no gameplay actions.

Version 1.2.0 requires hidden **Library QA Shared 1.1.0**. Its label and startup log
show the actual loaded shared version. Version 1.1.0 requires shared 1.0.0;
version 1.0.0 has no dependencies. Settings schema stays 1 for every version.

Updating A or B to 1.2.0 while both run at 1.1.0 must propose one linked plan for
both scripts and shared 1.1.0. After confirmation, check both fresh startup logs
and labels match those versions with Saved markers, enablement and order retained.

An incompatible single-script downgrade must fail without silently downgrading
the other script. Remove B while enabled, switch A to 1.1.0, then explicitly
install B 1.1.0. Newly installed B starts disabled; its saved marker is retained.
Re-enable B before the final coordinated update and removal checks.
