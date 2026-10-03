#!/usr/bin/env python3
"""GTK4 entry that traces its committed text for the IBus desktop harness."""
import sys

import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk  # noqa: E402


def activate(app):
    window = Gtk.ApplicationWindow(application=app, title='NeLisp IBus Probe')
    entry = Gtk.Entry()
    entry.connect('changed', lambda widget: print('TEXT: ' + widget.get_text(), flush=True))
    window.set_child(entry)
    window.present()
    entry.grab_focus()
    print('APP_READY', flush=True)


app = Gtk.Application(application_id='org.nelisp.IBusProbe')
app.connect('activate', activate)
sys.exit(app.run([]))
