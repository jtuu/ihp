module client;

import common;
import socket;
import utils;
import std.stdio;
import std.string;
import std.conv;
import core.stdc.string : strerror;
import core.stdc.errno;
import core.stdc.stdlib : exit;
import std.concurrency;
import gtk.Application;
import gtk.ApplicationWindow;
import gtk.VBox;
import gtk.Notebook;
import gtk.Table;
import gtk.Frame;
import gtk.Button;
import gtk.Entry;
import gtk.EditableIF;
import gobject.Signals;

class NumericEntry : Entry {
    this() {
        super();
        this.addOnInsertText(&this.filter);
    }

    void filter(string text, int _len, void *_pos, EditableIF _editable) {
        foreach (c; text) {
            if (c < '0' || c > '9') {
                Signals.stopEmissionByName(this, "insert-text");
                return;
            }
        }
    }
}

class ClientWindow : ApplicationWindow {
    Tid worker_id;

    this(Application app) {
        super(app);
        this.worker_id = spawn(&controller);
        this.setTitle("test");
        this.setup();
        this.showAll();
    }

    void setup() {
        VBox main_box = new VBox(false, 0);
        Notebook notebook = new Notebook();
        main_box.packStart(notebook, true, true, 0);
        this.add(main_box);
        Table table = new Table(2, 12, 0);
        Entry address_entry = new Entry();
        NumericEntry port_entry = new NumericEntry();
        Button button = new Button("Connect");
        void doConnect(T)(T _) {
            ushort port;
            try {
                port = to!ushort(port_entry.getText());
            } catch (ConvException ex) {
                stderr.writeln("Invalid port");
                return;
            }
            send(this.worker_id, ConnectMessage(
                address_entry.getText(),
                port
            ));
        }
        address_entry.addOnActivate(&doConnect!Entry);
        port_entry.addOnActivate(&doConnect!Entry);
        button.addOnClicked(&doConnect!Button);
        table.attach(address_entry, 0, 1, 12, 13, AttachOptions.FILL, AttachOptions.FILL, 4, 4);
        table.attach(port_entry, 1, 2, 12, 13, AttachOptions.FILL, AttachOptions.FILL, 4, 4);
        table.attach(button, 2, 3, 12, 13, AttachOptions.FILL, AttachOptions.FILL, 4, 4);
        notebook.appendPage(new Frame(table, "Connect"), "Connect");
    }
}

struct ConnectMessage {
    string address_name;
    ushort port_num;
}

void controller() {
    while (true) {
        receive (
            (ConnectMessage opts) {
                errno = 0;
                Socket sock = Socket(CoreProtocol.IPv4, TransportProtocol.TCP);
                const int connect_ret = sock.connect(opts.address_name, opts.port_num);
                if (connect_ret < 0) {
                    if (errno == 0) {
                        stderr.writefln("Connect failed: Invalid argument");
                    } else {
                        stderr.writefln("Connect failed: %s", fromStringz(strerror(errno)));
                    }
                } else {
                    writeln("Connected");
                }
            }
        );
    }
}

void main(string[] args) {
    Application application = new Application("moe.esc.ihp_client", GApplicationFlags.FLAGS_NONE);
	application.addOnActivate(delegate void(_) { new ClientWindow(application); });
    application.run(args);
}
