#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define IONI_SHELL_PATH "/bin/ionish"

static int console(void)
{
	int fd = open("/dev/console", O_RDWR);

	if (fd < 0)
		fd = open("/dev/null", O_RDWR);
	if (fd < 0)
		return -1;
	dup2(fd, 0);
	dup2(fd, 1);
	dup2(fd, 2);
	if (fd > 2)
		close(fd);
	return 0;
}

static int reap(int child)
{
	int status;

	for (;;) {
		pid_t w = wait(&status);
		if (w == child)
			return status;
		if (w < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
	}
}

int main(int argc, char **argv)
{
	const char *shell;

	if (argc > 1 && strcmp(argv[1], "-V") == 0) {
		printf("init (Ioni) 0.1\n");
		return 0;
	}

	shell = getenv("IONI_SHELL");
	if (!shell)
		shell = IONI_SHELL_PATH;

	while (console() != 0)
		sleep(1);
	setsid();
	signal(SIGINT, SIG_IGN);
	signal(SIGHUP, SIG_IGN);

	for (;;) {
		int status;
		pid_t pid = fork();

		if (pid == 0) {
			signal(SIGINT, SIG_DFL);
			signal(SIGHUP, SIG_DFL);
			execl(shell, shell, (char *)0);
			fprintf(stderr, "init: exec %s: %s\n", shell, strerror(errno));
			_exit(1);
		}
		if (pid < 0) {
			fprintf(stderr, "init: fork: %s\n", strerror(errno));
			sleep(2);
			continue;
		}
		status = reap(pid);
		fprintf(stderr, "init: shell exited (%d), respawning\n", status);
		sleep(1);
	}
}
