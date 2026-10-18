#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_ARGS 64
#define MAX_LINE 4096

extern char **environ;

static char *args[MAX_ARGS + 1];

static char **split(char *line)
{
	size_t n = 0;
	char *p = line;

	while (*p && n < MAX_ARGS) {
		while (*p == ' ' || *p == '\t' || *p == '\n')
			p++;
		if (!*p)
			break;
		args[n++] = p;
		while (*p && *p != ' ' && *p != '\t' && *p != '\n')
			p++;
		if (*p)
			*p++ = '\0';
	}
	args[n] = NULL;
	return args;
}

static void run_builtin(char **a)
{
	if (strcmp(a[0], "exit") == 0)
		exit(a[1] ? atoi(a[1]) : 0);
	if (strcmp(a[0], "cd") == 0) {
		const char *d = a[1] ? a[1] : getenv("HOME");

		if (!d)
			d = "/";
		if (chdir(d) != 0)
			fprintf(stderr, "cd: %s: %s\n", d, strerror(errno));
		return;
	}
	if (strcmp(a[0], "pwd") == 0) {
		char buf[PATH_MAX];

		if (getcwd(buf, sizeof buf))
			printf("%s\n", buf);
		return;
	}
	if (strcmp(a[0], "echo") == 0) {
		int nl = 1;
		char **v = a + 1;

		if (*v && strcmp(*v, "-n") == 0) {
			nl = 0;
			v++;
		}
		while (*v) {
			fputs(*v, stdout);
			if (*++v)
				putchar(' ');
		}
		if (nl)
			putchar('\n');
		return;
	}
	if (strcmp(a[0], "env") == 0) {
		for (char **e = environ; *e; e++)
			printf("%s\n", *e);
		return;
	}
}

static int is_builtin(const char *cmd)
{
	return !strcmp(cmd, "exit") || !strcmp(cmd, "cd") ||
	       !strcmp(cmd, "pwd") || !strcmp(cmd, "echo") ||
	       !strcmp(cmd, "env");
}

static void run_line(char *line)
{
	char *hash = strchr(line, '#');

	if (hash)
		*hash = '\0';
	char **a = split(line);

	if (!a[0])
		return;
	if (is_builtin(a[0])) {
		run_builtin(a);
		return;
	}
	pid_t pid = fork();

	if (pid == 0) {
		execvp(a[0], a);
		fprintf(stderr, "ionish: %s: %s\n", a[0], strerror(errno));
		_exit(127);
	}
	if (pid < 0) {
		fprintf(stderr, "ionish: fork: %s\n", strerror(errno));
		return;
	}
	int status;

	waitpid(pid, &status, 0);
	if (WIFEXITED(status) && WEXITSTATUS(status) != 0 && WEXITSTATUS(status) != 127)
		return;
	if (WIFSIGNALED(status))
		fprintf(stderr, "ionish: %s: killed by signal %d\n", a[0], WTERMSIG(status));
}

int main(int argc, char **argv)
{
	if (argc >= 3 && strcmp(argv[1], "-c") == 0) {
		run_line(argv[2]);
		return 0;
	}

	char line[MAX_LINE];

	for (;;) {
		fputs("ioni$ ", stdout);
		fflush(stdout);
		if (!fgets(line, sizeof line, stdin)) {
			putchar('\n');
			return 0;
		}
		run_line(line);
	}
}
