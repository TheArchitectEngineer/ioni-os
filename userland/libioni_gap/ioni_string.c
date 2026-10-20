#include <stdint.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <utmpx.h>
#include <utmp.h>
#include <string.h>
#include <math.h>
#include <fenv.h>
#include <mach/mach_time.h>
#include <corecrypto/ccrng.h>

int
ffs(int mask)
{
	int bit;

	if (mask == 0) {
		return 0;
	}
	for (bit = 1; !(mask & 1); bit++) {
		mask >>= 1;
	}
	return bit;
}

int
flsl(long mask)
{
	int bit;

	if (mask == 0) {
		return 0;
	}
	for (bit = sizeof(long) * 8; !(mask & ((long)1 << (sizeof(long) * 8 - 1))); bit--) {
		mask <<= 1;
	}
	return bit;
}

char *
index(const char *s, int c)
{
	return strchr(s, c);
}

void
getutmpx(const struct utmp *u, struct utmpx *ux)
{
	memset(ux, 0, sizeof(*ux));
	memcpy(ux->ut_user, u->ut_name, sizeof(u->ut_name));
	ux->ut_user[sizeof(u->ut_name)] = 0;
	memcpy(ux->ut_line, u->ut_line, sizeof(u->ut_line));
	ux->ut_line[sizeof(u->ut_line)] = 0;
	memcpy(ux->ut_host, u->ut_host, sizeof(u->ut_host));
	ux->ut_host[sizeof(u->ut_host)] = 0;
	ux->ut_tv.tv_sec = u->ut_time;
	ux->ut_tv.tv_usec = 0;
	ux->ut_pid = getpid();
}

double
fma(double x, double y, double z)
{
	return (double)((long double)x * (long double)y + (long double)z);
}

int
fegetround(void)
{
	return FE_TONEAREST;
}

int
fegetenv(fenv_t *envp)
{
	(void)envp;
	return 0;
}

int
fesetenv(const fenv_t *envp)
{
	(void)envp;
	return 0;
}

int
getentropy(void *buffer, size_t size)
{
	int fd;
	size_t done = 0;

	if (size > 256) {
		return -1;
	}
	fd = open("/dev/urandom", O_RDONLY);
	if (fd < 0) {
		return -1;
	}
	while (done < size) {
		ssize_t n = read(fd, (char *)buffer + done, size - done);
		if (n <= 0) {
			close(fd);
			return -1;
		}
		done += (size_t)n;
	}
	close(fd);
	return 0;
}

static uint64_t ioni_rng_state;

struct ccrng_state *
ccrng(int *error)
{
	static struct ccrng_state ioni_ccrng_state;

	if (ioni_rng_state == 0) {
		ioni_rng_state = mach_absolute_time() | 1;
	}
	if (error) {
		*error = 0;
	}
	return &ioni_ccrng_state;
}

int
ccrng_uniform(struct ccrng_state *rng, uint64_t bound, uint64_t *uniform)
{
	uint64_t value;

	(void)rng;
	if (bound == 0) {
		*uniform = 0;
		return 0;
	}
	do {
		int i;

		for (i = 0; i < 8; i++) {
			ioni_rng_state ^= ioni_rng_state << 13;
			ioni_rng_state ^= ioni_rng_state >> 7;
			ioni_rng_state ^= ioni_rng_state << 17;
		}
		value = ioni_rng_state;
	} while (value >= UINT64_MAX - UINT64_MAX % bound);
	*uniform = value % bound;
	return 0;
}
