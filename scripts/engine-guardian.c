// Keeps the engine's PID unchanged, but adds a tiny watcher that stops it if Hearth crashes.
// No networking or file access. kqueue tracks process identity, avoiding PID-reuse polling.
#include <sys/event.h>
#include <sys/types.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) return 64;
    pid_t app = getppid(), engine = getpid();
    int ready[2];
    if (pipe(ready) < 0) return 70;
    pid_t watcher = fork();
    if (watcher < 0) return 70;
    if (watcher == 0) {
        close(ready[0]);
        // kqueue descriptors are not inherited across fork; create this in the watcher.
        int queue = kqueue();
        struct kevent changes[2];
        EV_SET(&changes[0], app, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
        EV_SET(&changes[1], engine, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
        if (queue < 0 || kevent(queue, changes, 2, NULL, 0, NULL) < 0) {
            kill(engine, SIGTERM); _exit(70);
        }
        if (write(ready[1], "1", 1) != 1) { kill(engine, SIGTERM); _exit(70); }
        close(ready[1]);
        struct kevent event;
        int result = kevent(queue, NULL, 0, &event, 1, NULL);
        if (result > 0 && event.ident == (uintptr_t)app) {
            kill(engine, SIGTERM);
            struct timespec timeout = {2, 0};
            result = kevent(queue, NULL, 0, &event, 1, &timeout);
            if (result == 0) kill(engine, SIGKILL);
        }
        close(queue);
        _exit(0);
    }
    close(ready[1]);
    char acknowledgement = 0;
    if (read(ready[0], &acknowledgement, 1) != 1 || acknowledgement != '1') return 70;
    close(ready[0]);
    execv(argv[1], argv + 1);
    perror("Hearth: could not start local engine");
    return 70;
}
