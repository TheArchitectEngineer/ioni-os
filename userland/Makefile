CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11 -D_POSIX_C_SOURCE=200809L
HARDEN = -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wformat -Wformat-security
SAN = -fsanitize=address,undefined -fno-omit-frame-pointer -ftrivial-auto-var-init=pattern -g
PROGS = init ionish

all: $(PROGS)

init: init.c
	$(CC) $(CFLAGS) $(HARDEN) -o $@ init.c

ionish: ionish.c
	$(CC) $(CFLAGS) $(HARDEN) -o $@ ionish.c

hunt: clean
	$(CC) $(CFLAGS) $(SAN) -o init init.c
	$(CC) $(CFLAGS) $(SAN) -o ionish ionish.c

install: all
	mkdir -p $(DESTDIR)/sbin $(DESTDIR)/bin
	cp init $(DESTDIR)/sbin/init
	cp ionish $(DESTDIR)/bin/sh

clean:
	rm -f $(PROGS)

.PHONY: all install clean hunt
