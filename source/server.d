module server;

import sig;
import common;
import socket;
import utils;
import std.stdio : stderr, writefln;
import std.concurrency;
import core.stdc.string : strerror;
import core.stdc.errno;
import core.stdc.stdlib : exit;

// quick and dirty way to store the sockets
immutable int MAX_SOCKS = 128;
__gshared int num_socks = 0;
__gshared Socket[MAX_SOCKS] socks = void;

struct StopMessage {}

// listen for new sockets
void listener_worker() {
	while (num_socks < MAX_SOCKS) {
		Socket listen_sock = Socket(CoreProtocol.IPv4, TransportProtocol.TCP);
		const int accept_ret = listen_sock.listen(5555);
		if (accept_ret < 0) {
			stderr.writefln("Listen failed: %s", strerror(errno));
			exit(1);
		}
		socks[num_socks] = listen_sock;
		num_socks++;
	}
}

// read/write from/to sockets
void readwrite_worker(Tid parent) {
	handle_signals = false; // prevent exit so that we can close the sockets gracefully
	Socket slave = Socket(); // slave is just used to hold the readwrite buffer
	// loop through all sockets forever
	// this is a very busy loop because we use nonblocking read
	while (true) {
		const bool stopping = got_sigint || got_sigterm; // should all sockets be closed
		for (int i = 0; i < num_socks; i++) {
			Socket *sock = &socks[i];
			// try read from socket if we're not stopping and socket is not closed
			if (stopping) {
				sock.close();
			} else if (!sock.is_closed()) {
				// if something was read then write it to all other sockets
				if (sock.read(slave)) {
					for (int j = 0; j < num_socks; j++) {
						Socket *other = &socks[j];
						// don't echo
						if (j != i && !other.is_closed()) {
							other.write(slave);
						}
					}
					slave.clear();
				}
			}
		}
		if (stopping) { break; }
	}
	handle_signals = true;
	send(parent, StopMessage());
}

void main() {
	init_signal_handlers();
	spawn(&listener_worker);
	spawn(&readwrite_worker, thisTid); // this thread handles signals because it needs to exit gracefully
	receive (
		(StopMessage _) {
			exit(1);
		}
	);
}
