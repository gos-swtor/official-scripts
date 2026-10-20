# Library QA Shared

Hidden dependency for the temporary Official Script Library tests. Version 1.0.0
exports its version through `require("library_qa.shared")`. It has no gameplay
actions, callbacks or standalone script entry.

Core installs this exact dependency automatically with QA A/B 1.1.0. It stays
hidden in the Library list and is retained when switching a consumer to an older
version that does not need it.
