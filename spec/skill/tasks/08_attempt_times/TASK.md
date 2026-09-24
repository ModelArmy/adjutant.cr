Write `attempt_times(n, action)`.

`action` is a lambda taking no arguments. Call it and return its value. If it raises, call it again, up to `n` calls in total. If the last call also raises, let that error out of `attempt_times`.

Example: with `n = 3` and an action that raises twice and then returns `"ok"`, `attempt_times(3, action)` returns `"ok"` after three calls.
