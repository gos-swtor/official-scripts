# Library QA Shared

Hidden dependency for the temporary Official Script Library tests. It exports
its version through `require("library_qa.shared")`. It has no gameplay
actions, callbacks or standalone script entry.

QA A/B 1.2.0 require version 1.1.0; QA A/B 1.1.0 require version 1.0.0. The linked
update must replace the loaded module for both enabled consumers together.
This package stays hidden in the Library list and is retained when consumers
are removed or switched to versions that do not need it.
