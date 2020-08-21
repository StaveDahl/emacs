# Electronic Mids Attendance Collection System (emacs)

This tool will help you record attendance in MIDS.

## Prerequisites

`bash`, `getopt`, `curl`, `grep`, `python3`

You probably have this already, but if not:

    $ sudo apt install curl util-linux python3 emacs-

## Installation

    $ git clone https://github.com/StaveDahl/emacs
    $ sudo cp -b emacs/emacs /usr/local/bin/
    $ sudo chmod a+rX /usr/local/bin/emacs

## Usage

    $ emacs -h
    Usage: emacs [OPTIONS]

    This program records attendance as complete for any classes
    in the current month up to today.

    The password can be entered from a terminal or piped in.
    (The password can have most symbols, but not newlines.)

    Options:
      -u name  Use name for USNA login (default $USER)
      -b file  Skip login and instead use cookie stored in this file
      -c file  Save the login cookie to this file
