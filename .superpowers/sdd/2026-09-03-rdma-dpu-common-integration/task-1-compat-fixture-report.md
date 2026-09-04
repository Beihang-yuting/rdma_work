# Task 1 compatibility fixture migration

Migrated CMQ engine fixtures that mutate legacy Function mirrors before
rebuilding owner handles to call explicit identity synchronization. Forged
UID/object/BDF cases remain unsynchronized to preserve rejection coverage.

`git diff --check` passed; VCS execution is coordinated by the parent agent.
