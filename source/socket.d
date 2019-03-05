module socket;

import sig;
import common;
import utils;
import std.stdio : stderr, writeln, writefln;
import std.string;
import core.sys.posix.netinet.in_;
import core.sys.posix.unistd : os_write = write, os_read = read, os_close = close;
import core.sys.posix.sys.select;
import core.sys.posix.poll;
import core.sys.linux.sys.socket : os_socket = socket, PF_INET;
import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
import core.stdc.errno;
import core.stdc.stdio : perror;
import core.stdc.stdlib : abort, malloc, free, exit;
import core.stdc.string : memset, memcpy, strerror;

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
    sock = os_socket(sys_core_prtcl, sys_sock_type, 0);
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
        debug (1) { writefln("Connection received (new fd=%d)", new_sock); }
        return new_sock;
    }
    timeout_init = false;
    errno = ETIMEDOUT;
    return -1;
}

int socket_new_connect(
    CoreProtocol core_prtcl,
    TransportProtocol trans_prtcl,
    const in_addr *addr,
    in_port_t port,
    const in_addr *local_addr,
    in_port_t local_port) {
    assert(addr != null);
    const int my_family = AF_INET;
    int sock, ret;
    sockaddr_in rem_addr;
    debug (1) { writefln("socket_new_connect(addr=%x, port=%d, local_addr=%x, local_port=%x)",
                    cast(void *) &addr, ntohs(port), cast(void *) &local_addr, ntohs(local_port)); }
    rem_addr.sin_family = my_family;
    rem_addr.sin_port = port;
    memcpy(&rem_addr.sin_addr, addr, rem_addr.sin_addr.sizeof);
    sock = socket_new(core_prtcl, trans_prtcl);
    if (sock < 0) { return sock; }
    // bind to local address if specified
    if (local_addr != null || local_port) {
        sockaddr_in my_addr;
        my_addr.sin_family = my_family;
        my_addr.sin_port = local_port;
        if (local_addr != null) {
            memcpy(&my_addr.sin_addr, local_addr, my_addr.sin_addr.sizeof);
        }
        ret = bind(sock, cast(sockaddr *) &my_addr, my_addr.sizeof);
        if (ret < 0) {
            ret = -3;
            goto err;
        }
    }
    // set nonblocking
    if ((ret = fcntl(sock, F_GETFL, 0)) >= 0) {
        ret = fcntl(sock, F_SETFL, ret | O_NONBLOCK);
    }
    if (ret < 0) {
        ret = -4;
        goto err;
    }
    // should instantly return EINPROGRESS because of nonblocking
    ret = connect(sock, cast(sockaddr *) &rem_addr, rem_addr.sizeof);
    if (ret < 0 && errno != EINPROGRESS) {
        ret = -5;
        goto err;
    }
    return sock;

    err: {
        // close sock, restore errno
        const int saved_errno = errno,
            temp_ret = os_close(sock);
        assert(temp_ret >= 0);
        errno = saved_errno;
    }
    return ret;
}

struct Socket {
public:
    CoreProtocol core_prtcl;
    TransportProtocol trans_prtcl;
    pollfd *pfd = null;
protected:
    int fd;
    int timeout;
    Host local;
    Port local_port;
    Host remote;
    Port port;
    Buffer sendq;
    Buffer recvq;
    bool closed;
    
    int tcp_listen() {
        int sock_listen, sock_accept;
        debug (2) { writefln("tcp_listen(sock=%x)", cast(void *) &this); }
        sock_listen = socket_new_listen(this.core_prtcl, &this.local, &this.local_port);
        if (sock_listen < 0) {
            stderr.writefln("Couldn't setup listening socket (err=%d): %s", sock_listen, fromStringz(strerror(errno)));
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

    int tcp_connect() {
        int ret, sock;
        timeval timest;
        fd_set outs;
        debug (2) { writefln("tcp_connect(sock=%x)", cast(void *) &this); }
        // create sock
        sock = socket_new_connect(
            this.core_prtcl,
            this.trans_prtcl,
            &this.remote.host.iaddrs[0],
            this.port.netnum,
            this.local.host.iaddrs[0].s_addr ?
                &this.local.host.iaddrs[0] :
                null,
            this.local_port.netnum);
        if (sock < 0) {
            stderr.writefln("Couldn't create connection (err=%d): %s", sock, fromStringz(strerror(errno)));
            exit(1);
        }
        // wait for something to happen
        FD_ZERO(&outs);
        FD_SET(sock, &outs);
        timest.tv_sec = this.timeout;
        timest.tv_usec = 0;
        ret = select(sock + 1, null, &outs, null, this.timeout > 0 ? &timest : null);
        if (ret > 0) {
            // check socket errors
            int get_ret;
            uint get_len = get_ret.sizeof;
            assert(FD_ISSET(sock, &outs));
            ret = getsockopt(sock, SOL_SOCKET, SO_ERROR, &get_ret, &get_len);
            if (ret < 0) {
                stderr.writefln("Critical system request failed: %s", fromStringz(strerror(errno)));
                exit(1);
            }
            assert(get_len == get_ret.sizeof);
            debug (2) { writefln("Connection returned errcode=%d (%s)", get_ret, fromStringz(strerror(get_ret))); }
            if (get_ret > 0) {
                // expecting eof
                byte temp;
                ret = cast(int) os_read(sock, &temp, 1);
                assert(ret == 0);
                this.close();
                errno = get_ret;
                return -1;
            }
            // success
            debug (1) { writefln("%s open", strid(this.remote, this.port)); }
            return sock;
        }
        // select failed
        else if (ret < 0) {
            if (errno != EINTR) { stderr.writefln("Critical system request failed: %s", fromStringz(strerror(errno))); }
            exit(1);
        }
        // select timed out
        this.close();
        errno = ETIMEDOUT;
        return -1;
    }

    int set_nonblocking() {
        const int flags = fcntl(this.fd, F_GETFL);
        if (flags < 0) { return flags; }
        return fcntl(this.fd, F_SETFL, flags | O_NONBLOCK);
    }

public:
    this(CoreProtocol core_prtcl_, TransportProtocol trans_prtcl_) {
        this.core_prtcl = core_prtcl_;
        this.trans_prtcl = trans_prtcl_;
    }

    bool is_closed() {
        return this.closed;
    }

    int get_fd() {
        return this.fd;
    }

    int listen(ushort port_num) {
        get_port(this.local_port, "", port_num);
        switch (this.trans_prtcl) {
            case TransportProtocol.TCP:
                const int listen_ret = this.tcp_listen();
                if (listen_ret < 0) { return listen_ret; }
                this.fd = listen_ret;
                return listen_ret;
            default:
                abort();
        }
        return -1;
    }

    int connect(const string hostname, ushort port_num) {
        if (!resolve_host(this.remote, hostname) || !get_port(this.port, "", port_num)) {
            return -1;
        }
        switch (this.trans_prtcl) {
            case TransportProtocol.TCP:
                const int connect_ret = this.tcp_connect();
                if (connect_ret < 0) { return connect_ret; }
                this.fd = connect_ret;
                return connect_ret;
            default:
                abort();
        }
        return -1;
    }

    // returns true if something was read
    bool read(ref Buffer output) {
        static ubyte[1024] buf;
        debug (3) { writefln("socket.read(main=%x)", cast(void *) &this); }
        assert(!this.closed);
        assert(this.fd >= 0);
        bool was_read = false;
        int read_ret = cast(int) os_read(this.fd, cast(void *) buf, buf.sizeof);
        debug (3) { writefln("read(sock) = %d", read_ret); }
        if (read_ret < 0) {
            perror("read(sock)");
            this.close();
            return false;
        } else if (read_ret == 0) {
            debug (1) { writefln("EOF received from the socket"); }
            this.close();
            return false;
        } else {
            // something was read
            this.recvq.len = read_ret;
            this.recvq.head = null;
            this.recvq.pos = &buf[0];
            was_read = true;
        }
        // copy read data if any to output
        if (this.recvq.len > 0) {
            Buffer *my_recvq = &this.recvq;
            if (output.len == 0) {
                memcpy(&output, my_recvq, output.sizeof);
                memset(my_recvq, 0, (*my_recvq).sizeof);
            } else if (my_recvq.head == null) {
                my_recvq.head = cast(ubyte *) malloc(my_recvq.len);
                memcpy(my_recvq.head, my_recvq.pos, my_recvq.len);
                my_recvq.pos = my_recvq.head;
            }
        }
        return was_read;
    }

    // write data to this socket
    void write(ref Buffer input) {
        if (input.len > 0) {
            ubyte *data = input.pos;
            int data_len = input.len;
            int write_ret = cast(int) os_write(this.fd, data, data_len);
            debug (2) { writefln("write(sock) = %d", write_ret); }
            if (write_ret < 0) {
                perror("write(sock)");
                exit(1);
            }
            assert(write_ret > 0 && write_ret <= data_len);
            if (write_ret < data_len) {
                debug (1) { writefln("Only %d out of %d bytes were written to socket", data_len, write_ret); }
            }
        }
    }

    void close() {
        shutdown(this.fd, SHUT_RDWR);
        os_close(this.fd);
        this.fd = -1;
        if (this.pfd != null) {
            // poll will skip negative fd
            this.pfd.fd = -1;
        }
        this.closed = true;
    }
}
