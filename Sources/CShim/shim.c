#include "CShim.h"

#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

extern char **environ;

int swish_wifexited(int status) { return WIFEXITED(status); }
int swish_wexitstatus(int status) { return WEXITSTATUS(status); }
int swish_wifsignaled(int status) { return WIFSIGNALED(status); }
int swish_wtermsig(int status) { return WTERMSIG(status); }
int swish_wifstopped(int status) { return WIFSTOPPED(status); }

static volatile sig_atomic_t interrupted = 0;

static void on_interrupt(int signal) {
    (void)signal;
    interrupted = 1;
}

void swish_catch_interrupts(void) {
    struct sigaction action = {0};
    action.sa_handler = on_interrupt;
    action.sa_flags = SA_RESTART;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
}

int swish_take_interrupt(void) {
    int was = interrupted;
    interrupted = 0;
    return was;
}

pid_t swish_spawn(const char *path, char *const argv[], pid_t pgid,
                  const int *targets, const int *sources, int count, int tty) {
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int err = posix_spawnattr_init(&attr);
    if (err) return -err;
    err = posix_spawn_file_actions_init(&actions);
    if (err) {
        posix_spawnattr_destroy(&attr);
        return -err;
    }

    // The interactive shell ignores job-control signals; children get the
    // defaults back and start with nothing blocked.
    sigset_t defaults, empty;
    sigemptyset(&defaults);
    int reset[] = {SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD, SIGPIPE};
    for (unsigned i = 0; i < sizeof reset / sizeof *reset; i++) sigaddset(&defaults, reset[i]);
    sigemptyset(&empty);
    posix_spawnattr_setsigdefault(&attr, &defaults);
    posix_spawnattr_setsigmask(&attr, &empty);

    short flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
    if (pgid >= 0) {
        flags |= POSIX_SPAWN_SETPGROUP;
        posix_spawnattr_setpgroup(&attr, pgid);
    }

    // The child must own the terminal before it can read from it, or it gets
    // SIGTTIN. Traditional shells call tcsetpgrp in the child between fork and
    // exec; with posix_spawn we start it suspended, hand over the terminal,
    // then let it run.
    int handoff = tty >= 0 && pgid == 0;
#ifdef __APPLE__
    if (handoff) flags |= POSIX_SPAWN_START_SUSPENDED;
#endif
    posix_spawnattr_setflags(&attr, flags);

    for (int i = 0; i < count; i++) posix_spawn_file_actions_adddup2(&actions, sources[i], targets[i]);

    pid_t pid = 0;
    err = posix_spawn(&pid, path, &actions, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (err) return -err;

    if (handoff) {
        tcsetpgrp(tty, pid);
#ifdef __APPLE__
        kill(pid, SIGCONT);
#endif
        // Elsewhere there's a small window where the child can touch the
        // terminal first; glibc's posix_spawn_file_actions_addtcsetpgrp_np
        // closes it and is the thing to use when Linux support lands.
    }
    return pid;
}
