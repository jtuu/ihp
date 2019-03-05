module client;

import common;
import socket;
import utils;
import std.stdio;
import std.string;
import core.stdc.string : strerror;
import core.stdc.errno;
import core.stdc.stdlib : exit;

void main() {
    Socket sock = Socket(CoreProtocol.IPv4, TransportProtocol.TCP);
    const int connect_ret = sock.connect("localhost", 5555);
    if (connect_ret < 0) {
        stderr.writefln("Connect failed: %s", fromStringz(strerror(errno)));
        exit(1);
    }
}
