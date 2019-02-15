module server;

import sig;
import common;
import socket;
import utils;
import std.stdio : stderr, writefln;
import core.stdc.string : strerror;
import core.stdc.errno;
import core.stdc.stdlib : exit;

void main() {
	init_signal_handlers();
	Socket stdio_sock = Socket();
	Socket listen_sock = Socket(CoreProtocol.IPv4, TransportProtocol.TCP);
	const int accept_ret = listen_sock.listen(5555);
	if (accept_ret < 0) {
		stderr.writefln("Listen mode failed: %s", strerror(errno));
		exit(1);
	}
	listen_sock.read(stdio_sock);
}
