import std.stdio : stderr, writeln, writefln;
import std.format;
import std.string;
import std.conv;
import core.sys.posix.arpa.inet;
import core.sys.posix.netinet.in_;
import core.sys.posix.unistd : os_write = write, os_read = read, os_close = close, STDOUT_FILENO;
import core.sys.posix.netdb;
import core.sys.posix.sys.select;
import core.sys.posix.sys.time;
import core.sys.linux.sys.socket;
import core.stdc.errno;
import core.stdc.stdio : perror;
import core.stdc.stdlib : abort, malloc, free, exit;
import core.stdc.string : memset, memcpy, strerror;

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

int socket_new(CoreProtocol core_prtcl, TransportProtocol trans_prtcl) {
	int sock, ret, sys_core_prtcl, sys_sock_type, sock_opt;
	linger fix_linger;
	// set protocols
	switch (core_prtcl) {
		case CoreProtocol.IPv4:
			sys_core_prtcl = PF_INET;
			break;
		version (USE_IPV6) {
		case CoreProtocol.IPv6:
			sys_core_prtcl = PF_INET;
			break;
		}
		default:
			abort();
	}
	switch (trans_prtcl) {
		case TransportProtocol.TCP:
			sys_sock_type = SOCK_STREAM;
			break;
		case TransportProtocol.UDP:
			sys_sock_type = SOCK_DGRAM;
			break;
		default:
			abort();
	}
	// create socket
	sock = socket(sys_core_prtcl, sys_sock_type, 0);
	if (sock < 0) { return -1; }
	// disable linger
	fix_linger.l_onoff = 1;
	fix_linger.l_linger = 0;
	ret = setsockopt(sock, SOL_SOCKET, SO_LINGER, &fix_linger, fix_linger.sizeof);
	if (ret < 0) {
		os_close(sock);
		return -2;
	}
	// enable reuse address
	sock_opt = 1;
	ret = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &sock_opt, sock_opt.sizeof);
	if (ret < 0) {
		os_close(sock);
		return -2;
	}
	return sock;
}

int socket_new_listen(CoreProtocol core_prtcl, const Host *addr, const Port *port) {
	const int backlog = 4;
	int sock, ret;
	ushort my_family;
	sockaddr *my_addr = null;
	uint my_addr_len;
	debug (1) { writefln("socket_new_listen(addr=%x, port=%d)", cast(void*) addr, port.num); }
	// create socket
	sock = socket_new(core_prtcl, TransportProtocol.TCP);
	if (sock < 0) { return sock; }
	// setup address
	switch (core_prtcl) {
		case CoreProtocol.IPv4:
			my_family = AF_INET;
			sockaddr_in *my4_addr = cast(sockaddr_in *) malloc((sockaddr_in).sizeof);
			my_addr = cast(sockaddr *) my4_addr;
			my_addr_len = (*my4_addr).sizeof;
			memset(my4_addr, 0, (*my4_addr).sizeof);
			my4_addr.sin_family = my_family;
			my4_addr.sin_port = port.netnum;
			// if addr is not provided it will default to INADDR_ANY
			if (addr != null) {
				memcpy(&my4_addr.sin_addr, &addr.host.iaddrs[0], my4_addr.sin_addr.sizeof);
			}
			break;
		version (USE_IPV6) {
		case CoreProtocol.IPv6:
			my_family = AF_INET6;
			sockaddr_in6 *my6_addr = cast(sockaddr_in6 *) malloc((sockaddr_in6).sizeof);
			my_addr = cast(sockaddr *) my6_addr;
			my_addr_len = (*my6_addr).sizeof;
			memset(my6_addr, 0, (*my6_addr).sizeof);
			my6_addr.sin6_family = my_family;
			my6_addr.sin6_port = port.netnum;
			if (addr != null) {
				memcpy(&my6_addr.sin6_addr, &addr.host6.iaddrs[0], my6_addr.sin6_addr.sizeof);
			}
			break;
		}
		default:
			ret = -1;
			goto err;
	}
	// bind address to socket
	ret = bind(sock, my_addr, my_addr_len);
	free(my_addr);
	if (ret < 0) {
		ret = -3;
		goto err;
	}
	// make listen
	ret = listen(sock, backlog);
	if (ret < 0) {
		ret = -4;
		goto err;
	}
	return sock;

	err: {
		// close socket, restore errno
		const int saved_errno = errno,
			temp_ret = os_close(sock);
		assert(temp_ret >= 0);
		errno = saved_errno;
	}
	return ret;
}

int socket_accept(int s, int timeout) {
	fd_set set;
	int ret;
	static bool timeout_init = false;
	static timeval timest;
	debug (1) { writefln("socket_accept(s=%d, timeout=%d)", s, timeout); }
	FD_ZERO(&set);
	FD_SET(s, &set);
	if (timeout > 0) {
		timest.tv_sec = timeout;
		timest.tv_usec = 0;
		timeout_init = true;
	} else if (timeout && !timeout_init) {
		timeout = 0;
	}
	do {
		ret = select(s + 1, &set, null, null, timeout ? &timest : null);
		if (ret < 0 && errno != EINTR) {
			perror("select(socket_accept");
			exit(1);
		}
	} while (ret < 0);
	if (FD_ISSET(s, &set)) {
		int new_sock = accept(s, null, null);
		debug (1) { writefln("Connection received (new df=%d)", new_sock); }
		return new_sock;
	}
	timeout_init = false;
	errno = ETIMEDOUT;
	return -1;
}

bool get_port(ref Port dst, string port_name, ushort port_num) {
	immutable char *get_proto = toStringz("tcp");
	servent *my_servent;
	debug (2) { writefln("get_port(dst=%x, port_name=\"%s\", port_num=%d)", cast(void *) &dst, port_name, port_num); }
	dst = Port.init;
	if (empty(port_name)) {
		if (port_num == 0) {
			return false;
		}
		dst.num = port_num;
		dst.netnum = htons(port_num);
		my_servent = getservbyport(cast(int) dst.netnum, get_proto);
		if (my_servent != null) {
			assert(dst.netnum == my_servent.s_port);
			dst.name = fromStringz(my_servent.s_name).idup;
		}
	} else {
		long port;
		try {
			port = to!long(port_name);
		} catch (ConvException ex) {}
		if (port > 0 && port < 65536) {
			return get_port(dst, null, cast(in_port_t) port);
		}
		my_servent = getservbyname(toStringz(port_name), get_proto);
		if (my_servent != null) {
			dst.name = fromStringz(my_servent.s_name).idup;
			dst.netnum = cast(ushort) my_servent.s_port;
			dst.num = ntohs(dst.netnum);
		} else {
			return false;
		}
	}
	dst.ascnum = format("%d", dst.num);
	return true;
}

string strid(const ref Host host, const ref Port port) {
	string host_part = void;
	if (host.host.iaddrs[0].s_addr != 0) {
		if (empty(host.host.name)) {
			host_part = format("%s", host.host.addrs[0]);
		} else {
			host_part = format("%s [%s]", host.host.name, host.host.addrs[0]);
		}
	} else {
		host_part = "any";
	}
	if (empty(port.name)) {
		return host_part ~ format(":(%s)", port.name);
	} else {
		return host_part ~ format(":%s", port.ascnum);
	}
}

string ntop(ref in_addr src) {
	static char[127] dst;
	const char *ret = inet_ntop(AF_INET, cast(void *) &src, &dst[0], cast(uint) dst.sizeof);
	return fromStringz(ret).idup;
}

struct Socket {
	int fd;
	int timeout;
	CoreProtocol core_prtcl;
	TransportProtocol trans_prtcl;
	Host local;
	Port local_port;
	Host remote;
	Port port;
	Buffer sendq;
	Buffer recvq;
	
	int tcp_listen() {
		int sock_listen, sock_accept;
		debug (2) { writefln("tcp_listen(sock=%x)", cast(void *) &this); }
		sock_listen = socket_new_listen(this.core_prtcl, &this.local, &this.local_port);
		if (sock_listen < 0) {
			stderr.writefln("Couldn't setup listening socket (err=%d): %s", sock_listen, strerror(errno));
			exit(1);
		}
		// use random port if 0
		if (this.local_port.num == 0) {
			int ret;
			sockaddr_in findport;
			uint findport_len = findport.sizeof;
			ret = getsockname(sock_listen, cast(sockaddr *) &findport, &findport_len);
			if (ret < 0) {
				os_close(sock_listen);
				return -1;
			}
			get_port(this.local_port, "", ntohs(findport.sin_port));
		}
		debug (1) { writefln("Listening on %s", strid(this.local, this.local_port)); }
		sockaddr_in my_addr;
		uint my_addr_len = my_addr.sizeof;
		sock_accept = socket_accept(sock_listen, this.timeout);
		if (sock_accept < 0) { return -1; }
		getpeername(sock_accept, cast(sockaddr *) &my_addr, &my_addr_len);
		get_port(this.port, null, ntohs(my_addr.sin_port));
		debug (1) { writefln("Connection from %s:%d", ntop(my_addr.sin_addr), this.port.num); }
		os_close(sock_listen);
		return sock_accept;
	}

	int listen() {
		switch(this.trans_prtcl) {
			case TransportProtocol.TCP:
				return this.fd = this.tcp_listen();
			default:
				abort();
		}
		return -1;
	}

	int read(ref Socket slave) {
		int fd_stdout, fd_sock;
		fd_set ins_set;
		ubyte[1024] buf;
		bool inloop = true;
		debug (2) { writefln("socket.read(main=%x, slave=%x)", cast(void *) &this, cast(void *) &slave); }
		fd_sock = this.fd;
		assert(fd_sock >= 0);
		fd_stdout = STDOUT_FILENO;
		while (inloop) {
			bool call_select = true;
			FD_ZERO(&ins_set);
			if (this.recvq.len == 0) {
				debug (2) { writeln("Main recvq is empty"); }
				FD_SET(fd_sock, &ins_set);
			} else {
				call_select = false;
			}
			if (call_select && FD_ISSET(fd_sock, &ins_set)) {
				int read_ret = cast(int) os_read(fd_sock, cast(void *) buf, buf.sizeof);
				debug (2) { writefln("read(net) = %d", read_ret); }
				if (read_ret < 0) {
					perror("read(net)");
					exit(1);
				} else if (read_ret == 0) {
					debug (1) { writefln("EOF received from the net"); }
					inloop = false;
				} else {
					this.recvq.len = read_ret;
					this.recvq.head = null;
					this.recvq.pos = &buf[0];
				}
				if (this.recvq.len > 0) {
					Buffer *my_recvq = &this.recvq;
					Buffer *rem_sendq = &slave.sendq;
					if (my_recvq.len > 0) {
						if (rem_sendq.len == 0) {
							memcpy(rem_sendq, my_recvq, (*rem_sendq).sizeof);
							memset(my_recvq, 0, (*my_recvq).sizeof);
						} else if (my_recvq.head == null) {
							my_recvq.head = cast(ubyte *) malloc(my_recvq.len);
							memcpy(my_recvq.head, my_recvq.pos, my_recvq.len);
							my_recvq.pos = my_recvq.head;
						}
					}
				}
				if (slave.sendq.len > 0) {
					ubyte *data = slave.sendq.pos;
					int data_len = slave.sendq.len;
					Buffer * my_sendq = &slave.sendq;
					int write_ret = cast(int) os_write(fd_stdout, data, data_len);
					debug (2) { writefln("write(stdout) = %d", write_ret); }
					if (write_ret < 0) {
						perror("write(stdout)");
						exit(1);
					}
					assert(write_ret > 0 && write_ret <= data_len);
					if (write_ret < data_len) {
						debug (1) { writefln("Only %d out of %d bytes were written to stdout", data_len, write_ret); }
						data_len = write_ret;
					}
					my_sendq.len -= data_len;
					my_sendq.pos += data_len;
					debug (1) { writefln("%d bytes left in the queue", my_sendq.len); }
					if (my_sendq.len == 0) {
						free(my_sendq.head);
						memset(my_sendq, 0, (*my_sendq).sizeof);
					} else if (my_sendq.head == null) {
						my_sendq.head = cast(ubyte *) malloc(my_sendq.len);
						memcpy(my_sendq.head, my_sendq.pos, my_sendq.len);
						my_sendq.pos = my_sendq.head;
					}
				}
			}
		}
		shutdown(fd_sock, SHUT_RDWR);
		os_close(fd_sock);
		this.fd = -1;
		slave.fd = -1;
		return 0;
	}
}

void main() {
	Socket stdio_sock = Socket();
	Socket listen_sock = Socket();
	Port *local_port = &listen_sock.local_port;
	listen_sock.core_prtcl = CoreProtocol.IPv4;
	listen_sock.trans_prtcl = TransportProtocol.TCP;
	get_port(*local_port, "", 5555);
	const int accept_ret = listen_sock.listen();
	if (accept_ret < 0) {
		stderr.writefln("Listen mode failed: %s", strerror(errno));
		exit(1);
	}
	listen_sock.read(stdio_sock);
}
