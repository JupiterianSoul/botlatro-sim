CC ?= gcc
CFLAGS ?= -O2
CFLAGS += -ffp-contract=off -fno-fast-math -fPIC -Wall -Wextra

libbotsim.so: scan.c
	$(CC) $(CFLAGS) -shared -o $@ $< -lm

clean:
	rm -f libbotsim.so
