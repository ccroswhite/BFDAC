---
trigger: always_on
description: Detach long-running Vivado/xsim jobs; never poll
---
For long-running processes (Vivado synth/route, xsim runs > ~5 min): start them
detached (Start-Process, log to file), report the log path, and STOP. Do not poll
or sleep-wait. The user will say when the run has finished.