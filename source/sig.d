module sig;

import std.stdio;
import core.sys.posix.signal;
import core.stdc.stdlib : exit;

__gshared bool handle_signals = true;
__gshared bool got_sigterm = false;
__gshared bool got_sigint = false;

extern (C) void handle_sigint(int) {
    if (!got_sigint) { stderr.writeln("Exiting"); }
    debug (2) { writefln("SIGINT (handle_signals=%s)", handle_signals); }
    got_sigint = true;
    if (handle_signals) { exit(1); }
}

extern (C) void handle_sigterm(int) {
    if (!got_sigterm) { stderr.writeln("Terminated"); }
    debug (2) { writefln("SIGTERM (handle_signals=%s)", handle_signals); }
    got_sigterm = true;
    if (handle_signals) { exit(1); }
}

void init_signal_handlers() {
    sigaction_t sv;
    sigemptyset(&sv.sa_mask);
    sv.sa_flags = 0;
    sv.sa_handler = &handle_sigint;
    sigaction(SIGINT, &sv, null);
    sv.sa_handler = &handle_sigterm;
    sigaction(SIGTERM, &sv, null);
}
