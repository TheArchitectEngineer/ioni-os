CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11 -D_POSIX_C_SOURCE=200809L
PROGS = init ionish

all: $(PROGS)

init: init.c
	$(CC) $(CFLAGS) -o $@ init.c

ionish: ionish.c
	$(CC) $(CFLAGS) -o $@ ionish.c

install: all
	mkdir -p $(DESTDIR)/sbin $(DESTDIR)/bin
	cp init $(DESTDIR)/sbin/init
	cp ionish $(DESTDIR)/bin/sh

clean:
	rm -f $(PROGS)

.PHONY: all install clean
