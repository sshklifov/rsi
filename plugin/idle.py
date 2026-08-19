#!/usr/bin/env python3
"""Milliseconds since the last input event, one line per poll.

Vim's own events stop at the edge of its window, so they cannot tell an hour
spent reading in a browser from an hour spent away from the desk. The X screen
saver extension counts every key and every mouse move on the display, whoever
they were meant for.
"""
import ctypes
import sys
import time


class XScreenSaverInfo(ctypes.Structure):
    _fields_ = [
        ("window", ctypes.c_ulong),
        ("state", ctypes.c_int),
        ("kind", ctypes.c_int),
        ("til_or_since", ctypes.c_ulong),
        ("idle", ctypes.c_ulong),
        ("event_mask", ctypes.c_ulong),
    ]


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

    while True:
        if not xss.XScreenSaverQueryInfo(display, root, info):
            return "the display stopped answering"
        print(info.contents.idle, flush=True)
        time.sleep(interval)


sys.exit(main(float(sys.argv[1])))
