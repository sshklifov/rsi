#!/usr/bin/env python3
"""Milliseconds since the last input event, one line per poll.

Vim's own events stop at the edge of its window, so they cannot tell an hour
spent reading in a browser from an hour spent away from the desk. The X screen
saver extension counts every key and every mouse move on the display, whoever
they were meant for.

Whoever they were meant for is the catch. A desk bumped while the session is
locked is input the display reports as gladly as any other, and it is nobody's
work: it arrives at the lock screen, not at us. A poll that finds the screen
locked says so instead of counting, and the reader ignores every line that is
not a number.
"""
import ctypes
import sys
import time

try:
    import dbus
except ImportError:
    dbus = None

# Asked in this order until one of them answers. A name on the bus proves
# nothing -- the freedesktop one is only an inhibit API on some desktops -- so
# the probe is a GetActive that returns.
SAVERS = [
    "org.cinnamon.ScreenSaver",
    "org.gnome.ScreenSaver",
    "org.freedesktop.ScreenSaver",
]


class XScreenSaverInfo(ctypes.Structure):
    _fields_ = [
        ("window", ctypes.c_ulong),
        ("state", ctypes.c_int),
        ("kind", ctypes.c_int),
        ("til_or_since", ctypes.c_ulong),
        ("idle", ctypes.c_ulong),
        ("event_mask", ctypes.c_ulong),
    ]


def lock_query():
    """The bound GetActive of whichever screen saver answers, or None if none do."""
    if dbus is None:
        return None
    try:
        bus = dbus.SessionBus()
    except dbus.DBusException:
        return None

    for name in SAVERS:
        try:
            proxy = bus.get_object(name, "/" + name.replace(".", "/"))
            query = proxy.get_dbus_method("GetActive", name)
            query()
        except dbus.DBusException:
            continue
        return query
    return None


def locked(query):
    """A saver that cannot be reached is not one holding the screen: when in
    doubt we count the input, so a stray blip stays visible in the day instead
    of real work going quietly missing."""
    if query is None:
        return False
    try:
        return bool(query())
    except dbus.DBusException:
        return False


def main(interval):
    x11 = ctypes.CDLL("libX11.so.6")
    xss = ctypes.CDLL("libXss.so.1")
    # Pointers are wider than the int ctypes assumes, so every one of them has
    # to be spelled out or the display comes back truncated.
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    xss.XScreenSaverAllocInfo.restype = ctypes.POINTER(XScreenSaverInfo)
    xss.XScreenSaverQueryInfo.argtypes = [
        ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XScreenSaverInfo)
    ]

    display = x11.XOpenDisplay(None)
    if not display:
        return "no display to ask"
    root = x11.XDefaultRootWindow(display)
    info = xss.XScreenSaverAllocInfo()
    query = lock_query()

    while True:
        if not xss.XScreenSaverQueryInfo(display, root, info):
            return "the display stopped answering"
        print("locked" if locked(query) else info.contents.idle, flush=True)
        time.sleep(interval)


sys.exit(main(float(sys.argv[1])))
