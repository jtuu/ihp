module server;

import sig;
import common;
import socket;
import utils;
import std.stdio : stderr, writefln, writeln;
import std.concurrency;
import core.time;
import core.atomic : atomicOp, cas;
import core.sys.posix.poll;
import core.stdc.string : strerror;
import core.stdc.errno;
import core.stdc.stdio : perror;
import core.stdc.stdlib : exit;

// quick and dirty way to store the sockets
immutable int MAX_SOCKS = 128;
shared int num_socks = 0;
__gshared Socket[MAX_SOCKS] socks = void;
__gshared pollfd[MAX_SOCKS] pfds = void;

struct StopMessage {}
struct SocketAddedMessage {}

// listen for new sockets
void listener_worker(Tid parent) {
    debug (1) { writeln("Listener started"); }
    while (true) {
        while (num_socks < MAX_SOCKS) {
            const int num_socks_now = num_socks;
            Socket listen_sock = Socket(CoreProtocol.IPv4, TransportProtocol.TCP);
            const int accept_ret = listen_sock.listen(5555);
            if (accept_ret < 0) {
                stderr.writefln("Listen failed: %s", strerror(errno));
                exit(1);
            }
            socks[num_socks_now] = listen_sock;
            pfds[num_socks_now] = pollfd(listen_sock.get_fd(), POLLIN, 0);
            num_socks.atomicOp!"+="(1);
            send(parent, SocketAddedMessage());
        }
        debug (2) { writefln("Listener: %d/%d sockets, attempting to make space", num_socks, MAX_SOCKS); }
        // socket storage filled up
        // check if there are any closed sockets that can be removed
        // find continuous ranges of closed sockets and replace them with the next sockets
        int total_removed = 0;
        int move_len = 0;
        for (int i = 0; i < MAX_SOCKS - 1; i++) {
            const bool cur_closed = socks[i].is_closed();
            const bool next_closed = socks[i + 1].is_closed();
            // range continues
            if (cur_closed) {
                move_len++;
            }
            // range ends at current index
            if (cur_closed && !next_closed) {
                // move next sockets backwards
                for (int j = i + 1; j < MAX_SOCKS; j++) {
                    socks[j - move_len] = socks[j];
                    pfds[j - move_len] = pfds[j];
                }
                total_removed += move_len;
                i++; // next one can be skipped because we know it's not closed
                move_len = 0;
            }
        }
        // all closed
        if (move_len == MAX_SOCKS - 1) {
            total_removed = MAX_SOCKS;
        }
        num_socks.atomicOp!"-="(total_removed);
        debug (2) { writefln("Listener: %d closed socket(s) removed", total_removed); }
        if (total_removed == 0) { break; } // TODO: do something smarter than just stop
    }
    debug (1) { writeln("Listener stopped"); }
}

// read/write from/to sockets
void readwrite_worker(Tid parent) {
    const int poll_timeout = 10; // ms
    const Duration socket_wait_timeout = poll_timeout.msecs;
    handle_signals = false; // prevent exit so that we can close the sockets gracefully
    Buffer msg_buf = Buffer();
    // loop through all sockets forever
    while (true) {
        const int num_socks_now = num_socks;
        int num_closed = 0;
        const bool stopping = got_sigint || got_sigterm; // should all sockets be closed
        // wait for sockets if there are none
        if (num_socks_now == 0) {
            receiveTimeout(socket_wait_timeout, (SocketAddedMessage _) {});
        } else {
            int poll_ret = poll(&pfds[0], num_socks_now, poll_timeout); // find out which sockets can be read
            debug (3) { writefln("poll(readwrite) = %d", poll_ret); }
            if (poll_ret < 0) {
                perror("poll(readwrite)");
                exit(1);
            }
            // loop through sockets if at least one socket has something to read or we are stopping
            else if (poll_ret > 0 || stopping) {
                for (int i = 0; i < num_socks_now; i++) {
                    Socket *sock = &socks[i];
                    // try read from socket if we're not stopping and socket can be read
                    if (stopping) {
                        sock.close();
                    } else if (sock.is_closed()) {
                        num_closed++;
                    } else if (pfds[i].revents & POLLIN) {
                        // if something was read then write it to all other sockets
                        if (sock.read(msg_buf)) {
                            for (int j = 0; j < num_socks_now; j++) {
                                Socket *other = &socks[j];
                                // don't echo
                                if (j != i && !other.is_closed()) {
                                    other.write(msg_buf);
                                }
                            }
                            msg_buf.clear();
                        }
                    }
                }
            }
            // all sockets are closed which means we can free all of them
            cas(&num_socks, num_closed, 0);
        }
        if (stopping) { break; }
    }
    handle_signals = true;
    send(parent, StopMessage());
}

void main() {
    init_signal_handlers();
    spawn(&listener_worker, thisTid);
    Tid readwrite = spawn(&readwrite_worker, thisTid); // this thread handles signals because it needs to exit gracefully
    while (true) {
        receive (
            (StopMessage _) {
                exit(1);
            },
            (SocketAddedMessage msg) {
                send(readwrite, msg);
            }
        );
    }
}
