module utils;

import common;
import std.stdio;
import std.string;
import std.conv;
import core.sys.posix.netdb;

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
