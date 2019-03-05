module utils;

import common;
import std.stdio;
import std.string;
import std.conv;
import std.uni;
import core.stdc.string : memcpy, memcmp;
import core.sys.posix.netdb;
import core.sys.posix.arpa.inet;

bool str_eq_i(string s1, string s2) {
    if (s1.length != s2.length) {
        return false;
    }
    const ulong min_len = s1.length < s2.length ? s1.length : s2.length;
    for (size_t i = 0; i < min_len; i++) {
        if (toLower(s1[i]) != toLower(s2[i])) {
            return false;
        }
    }
    return true;
}

bool resolve_host(ref Host dst, const string name) {
    int ret;
    immutable char *namez = toStringz(name);
    hostent *hostent;
    in_addr res_addr;
    assert(!empty(name));
    debug (2) { writefln("resolve_host(dst=%x, name=\"%s\")", cast(void *) &dst, name); }
    dst = Host.init;
    ret = inet_pton(AF_INET, namez, &res_addr);
    // pton failed, check if it's a name
    if (ret == 0) {
        bool host_auth_taken = false;
        // lookup name
        if ((hostent = gethostbyname(namez)) == null) { return false; }
        string h_name = to!string(fromStringz(hostent.h_name));
        // returned name (CNAME) might be different from what the user actually gave
        // prefer the user given name
        debug (2) { writefln("resolve_host: lookup=\"%s\", official=\"%s\" (should match)", name, h_name); }
        dst.host.name = name;
        // save addresses in dst
        for (int i = 0; hostent.h_addr_list[i] != null && i < MAX_INET_ADDRS; i++) {
            memcpy(&dst.host.iaddrs[i], hostent.h_addr_list[i], dst.host.iaddrs[0].sizeof);
            dst.host.addrs[i] = ntop(dst.host.iaddrs[i]);
        }
        // do inverse lookup to double check that everything is correct
        inverse_lookup_loop:
        for (int i = 0; dst.host.iaddrs[i].s_addr && i < MAX_INET_ADDRS; i++) {
            hostent = gethostbyaddr(cast(void *) &dst.host.iaddrs[i], dst.host.iaddrs[0].sizeof, AF_INET);
            if (hostent == null || hostent.h_name == null) {
                stderr.writeln("Inverse name lookup failed for %s", dst.host.addrs[i]);
                continue;
            }
            h_name = to!string(fromStringz(hostent.h_name));
            // case might differ, prefer the user given case
            // check if given name and inverse lookup name differ
            if (!str_eq_i(dst.host.name, h_name)) {
                string saved_host = h_name.dup;
                hostent = gethostbyname(toStringz(saved_host));
                if (hostent == null) { continue; }
                // check if original addresses match
                for (int j = 0; hostent.h_addr_list[j] != null && j < MAX_INET_ADDRS; j++) {
                    if (memcmp(&dst.host.iaddrs[i], hostent.h_addr_list[j], dst.host.iaddrs[0].sizeof) == 0) {
                        // found real host
                        debug (2) { writefln("Real hostname for %s [%s] is %s",
                                        dst.host.name, dst.host.addrs[j], saved_host); }
                        continue inverse_lookup_loop;
                    }
                }
                debug (2) { writefln("This host's reverse DNS doesn't match: %s != %s",
                                fromStringz(hostent.h_name), dst.host.name); }
            } else if (!host_auth_taken) {
                // name match, use it
                dst.host.name = h_name;
                host_auth_taken = true;
            }
        }
    }
    // given name is a numeric address?
    else {
        memcpy(&dst.host.iaddrs[0], &res_addr, dst.host.iaddrs[0].sizeof);
        dst.host.addrs[0] = ntop(res_addr);
        // reverse lookup, doesn't matter if it fails
        hostent = gethostbyaddr(&res_addr, res_addr.sizeof, AF_INET);
        if (hostent == null) {
            debug (2) { writefln("Inverse name loookup failed for %s", name); }
        } else {
            dst.host.name = to!string(fromStringz(hostent.h_name));
            hostent = gethostbyname(toStringz(dst.host.name.dup));
            if (hostent == null || hostent.h_addr_list[0] == null) {
                debug (1) { writefln("Host %s isn't authoritative (direct lookup failed)", dst.host.addrs[0]); }
                dst.host.name = "";
            } else {
                for (int i = 0; hostent.h_addr_list[i] != null && i < MAX_INET_ADDRS; i++) {
                    if (!memcmp(&dst.host.iaddrs[0], hostent.h_addr_list[i], dst.host.iaddrs[0].sizeof)) {
                        return true;
                    }
                    debug (1) {
                        writefln("Host %s isn't authoritative (direct lookup mismatch)", dst.host.addrs[0]);
                        writefln("  %s -> %s  BUT  %s -> %s",
                            dst.host.addrs[0], dst.host.name, dst.host.name, ntop(hostent.h_addr_list[0]));
                    }
                }
            }
        }
    }
    return true;
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

char[127] ntop_dst;

string ntop(const char *src) {
    const char *ret = inet_ntop(AF_INET, cast(void *) src, &ntop_dst[0], cast(uint) ntop_dst.sizeof);
    return fromStringz(ret).idup;
}

string ntop(ref in_addr src) {
    const char *ret = inet_ntop(AF_INET, cast(void *) &src, &ntop_dst[0], cast(uint) ntop_dst.sizeof);
    return fromStringz(ret).idup;
}
