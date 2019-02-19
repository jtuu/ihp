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

immutable int MAX_SOCKS = 128;
__gshared int num_socks = 0;
__gshared Socket[MAX_SOCKS] socks = void;

struct StopMessage {}

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

void reader_worker(Tid parent) {
	handle_signals = false;
	Socket stdio_sock = Socket();
	while (true) {
		const bool stopping = got_sigint || got_sigterm;
		for (int i = 0; i < num_socks; i++) {
			Socket *sock = &socks[i];
			if (stopping) {
				sock.close();
			} else if (!sock.is_closed()) {
				sock.read(stdio_sock);
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
	spawn(&reader_worker, thisTid);
	receive (
		(StopMessage _) {
			exit(1);
		}
	);
}
