#ifndef SWISH_CSHIM_H
#define SWISH_CSHIM_H

#include <sys/types.h>

// The wait-status macros don't import into Swift.
int swish_wifexited(int status);
int swish_wexitstatus(int status);
int swish_wifsignaled(int status);
int swish_wtermsig(int status);
int swish_wifstopped(int status);

/// Spawns `path` with `argv` and the current environment.
///
/// `pgid` < 0 keeps the shell's process group, 0 starts a new group led by
/// the child, and > 0 joins that group. `fd_in`/`fd_out` are dup'd onto
/// stdin/stdout when >= 0; other fds should be close-on-exec.
/// When `tty` >= 0 and the child leads a new group, the terminal is handed to
/// that group before the child runs any code.
///
/// Returns the child's pid, or -errno on failure.
pid_t swish_spawn(const char *path, char *const argv[], pid_t pgid,
                  int fd_in, int fd_out, int tty);

/// Makes SIGINT set a flag instead of being ignored, so ^C can stop code
/// running in the shell itself, like a `while true {}` loop.
void swish_catch_interrupts(void);

/// Whether SIGINT arrived since the last call, clearing the flag.
int swish_take_interrupt(void);

#endif
