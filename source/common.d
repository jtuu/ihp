module common;

import core.sys.posix.netinet.in_;

const MAX_INET_ADDRS = 6;

enum CoreProtocol {
	Unspecified,
	IPv4,
	IPv6
}

enum TransportProtocol {
	Unspecified,
	TCP,
	UDP
}

struct Host4 {
	string name;
	string[] addrs;
	in_addr[MAX_INET_ADDRS] iaddrs;
}

struct Host6 {
	string name;
	string[] addrs;
	in6_addr[MAX_INET_ADDRS] iaddrs;
}

union Host {
	Host4 host;
	Host6 host6;
}

struct Port {
	string name;
	string ascnum;
	ushort num;
	in_port_t netnum;
}

struct Buffer {
	ubyte *head;
	ubyte *pos;
	int len;
}
