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
	if (n == MAX_ARGS && *p)
		fprintf(stderr, "ionish: too many arguments, dropped after %s\n", args[MAX_ARGS - 1]);
	return args;
}

static void strip_comment(char *line)
{
	char *p = line;

	while (*p) {
		if (*p == '#' && (p == line || p[-1] == ' ' || p[-1] == '\t')) {
			*p = '\0';
			return;
		}
		p++;
	}
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

static int run_line(char *line)
{
	int rc = 0;

	strip_comment(line);
	char **a = split(line);

	if (!a[0])
		return 0;
	if (is_builtin(a[0])) {
		run_builtin(a);
		return 0;
	}
	pid_t pid = fork();

	if (pid == 0) {
		execvp(a[0], a);
		fprintf(stderr, "ionish: %s: %s\n", a[0], strerror(errno));
		_exit(127);
	}
	if (pid < 0) {
		fprintf(stderr, "ionish: fork: %s\n", strerror(errno));
		return 1;
	}
	int status;

	if (waitpid(pid, &status, 0) < 0)
		return 1;
	if (WIFSIGNALED(status)) {
		fprintf(stderr, "ionish: %s: killed by signal %d\n", a[0], WTERMSIG(status));
		rc = 128 + WTERMSIG(status);
	} else if (WIFEXITED(status)) {
		rc = WEXITSTATUS(status);
	} else {
		rc = 1;
	}
	return rc;
}

int main(int argc, char **argv)
{
	if (argc >= 3 && strcmp(argv[1], "-c") == 0)
		return run_line(argv[2]);

	char line[MAX_LINE];

	for (;;) {
		int c;
		size_t len;

		fputs("ioni$ ", stdout);
		fflush(stdout);
		if (!fgets(line, sizeof line, stdin)) {
			putchar('\n');
			return 0;
		}
		len = strlen(line);
		if (len > 0 && line[len - 1] != '\n') {
			c = fgetc(stdin);
			if (c != EOF && c != '\n') {
				while (c != EOF && c != '\n')
					c = fgetc(stdin);
				fprintf(stderr, "ionish: line too long (max %d), dropped\n", MAX_LINE - 1);
				continue;
			}
		}
		run_line(line);
	}
}
