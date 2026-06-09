# Section parity operation matrix

Both scripts/emacs-section-snapshot.el and scripts/organ-section-snapshot.lua
apply EXACTLY these ops, in this order, to a copy of each seed, then print the
resulting file text. Fixed timestamps make output deterministic.

Pinned clock: 2026-05-04 12:00:00 UTC. Clock-out (where used): 2026-05-04 13:30 UTC.

| seed                 | ops (in order)                                                              | question answered |
|----------------------|----------------------------------------------------------------------------|-------------------|
| 01-close.org         | mark DONE                                                                   | where does CLOSED: go |
| 02-plan.org          | set SCHEDULED 2026-05-06; set DEADLINE 2026-05-07; mark DONE                | planning sub-order + CLOSED vs SCHEDULED/DEADLINE |
| 03-prop-then-plan.org| set SCHEDULED 2026-05-06                                                    | planning vs an existing property drawer |
| 04-logbook.org       | log state TODO->DONE into drawer; clock in then out into drawer             | note-vs-clock order inside :LOGBOOK: |
| 05-full.org          | set SCHEDULED 2026-05-06; set DEADLINE 2026-05-07; set property FOO=bar; log state TODO->DONE; clock in/out; mark DONE | full canonical stack |

Logging config (both tools): state changes AND clocks go INTO the :LOGBOOK: drawer.
- Emacs: `org-log-into-drawer` = t, `org-clock-into-drawer` = t, DONE keyword logs via `!`.
- organ: the equivalent log-into-drawer config.
