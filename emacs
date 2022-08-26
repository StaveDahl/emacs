#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

srcdir=$(dirname "$(readlink -f "$0")")

function usage {
  echo "Usage: $0 [OPTIONS]"
  echo
  echo "This program records attendance as complete for any classes"
  echo "in the current month up to today."
  echo
  echo "The password can be entered from a terminal or piped in."
  echo "(The password can have most symbols, but not newlines.)"
  echo
  echo "Options:"
  echo "  -u name  Use name for USNA login (default \$USER)"
  echo "  -m mon   Use month like APR instead of the current month"
  echo "  -b file  Skip login and instead use cookie stored in this file"
  echo "  -c file  Save the login cookie to this file"
  echo "  -h       Show this help page and exit"
  [[ $# -eq 1 ]] && exit $1
}

function err {
  echo "$1" >&2
  [[ $# -ge 2 ]] && exit $2 || exit 1
}

args=$(getopt 'u:m:b:c:h' "$@") || usage 1
eval set -- "$args"

tdir=$(mktemp -d "${TMPDIR:-/tmp}/attendance.XXXXXXXX")
cookie1="$tdir/cookie1.txt"
cookie2="$tdir/cookie2.txt"

function cleanup {
  rm -rf "$tdir"
  return 0
}
trap cleanup EXIT

username=$USER
login=true

hasmonth=0

while true; do
  case "$1" in
    -u)
      username=$2
      shift
      ;;
    -b)
      cookie2=$2
      shift
      login=false
      ;;
    -m)
      hasmonth=1
      month=$2
      shift
      ;;
    -c)
      cookie2=$2
      shift
      ;;
    -h) usage 0 ;;
    --)
      shift
      break
      ;;
    *) err "ERROR: unexpectedly got '$1' from getopt" 10 ;;
  esac
  shift
done

if [[ $# -gt 0 ]]; then
  echo "ERROR: unrecognized argument '$1'"
  usage 1
fi

if curl --fail --max-time 2 --silent 'https://mids.usna.edu' >/dev/null; then
  echo "Intranet detected; will connect to mids.usna.edu"
  calurl='https://mids.usna.edu/ITSD/mids/dacwu006$.startup'
else
  echo "mids.usna.edu not found; will try midsweb.usna.edu"
  calurl='https://midsweb.usna.edu/ITSD/midsw/dacwu006$.startup'
fi

cookie1="$tdir/cookie1.txt"
logpage="$tdir/logpage.html"
calpage="$tdir/calpage.html"
attpage="$tdir/attpage.html"
recpage="$tdir/recpage.html"
missing="$tdir/missing.txt"

if (( hasmonth )); then
  modata=$(python3 - "$username" "$month" <<'EOF'
import sys
from urllib.parse import urlencode
user, month = sys.argv[1:]
assert len(month) == 3
data = {
    'P_LOGIN_IN': user.upper(),
    'P_MONTH_IN': month.upper(),
    'P_BUTTON_IN': 'Change Month',
}
print(urlencode(data))
EOF
)
else
  modata=''
fi

if $login; then
  if [[ -t 0 && -t 2 ]]; then
    read -s -p "Enter the USNA MIDS password for $username: " pw
    echo >&2
  else
    read -s pw
  fi

  if ! logurl=$(curl -Ls -c "$cookie1" -o "$logpage" -w '%{url_effective}' "$calurl") \
    || ! grep -q 'Username:' "$logpage"
  then
    err "ERROR loading login page"
  fi

  proc1=$(python3 - "$logurl" "$logpage" "$username" <<'EOF'
import sys
from html.parser import HTMLParser
from urllib.parse import urljoin, urlencode

formurl, formfile, username = sys.argv[1:]

class ParseLoginForm(HTMLParser):
    def __init__(self):
        super().__init__()
        self._action = None
        self._within = False
        self._fields = {}

    def handle_starttag(self, tag, attrs):
        global username
        adict = dict(attrs)
        if self._within:
            if tag == 'input':
                if adict['type'] == 'submit' or adict['name'] == 'password':
                    return
                elif adict['type'] == 'hidden':
                    self._fields[adict['name']] = adict['value']
                elif adict['name'] == 'username':
                    self._fields[adict['name']] = username
                else:
                    raise RuntimeError('unexpected input in form: ' + str(adict))
            elif tag == 'select':
                if adict['name'] == 'Languages':
                    self._fields[adict['name']] = ''
                else:
                    raise RuntimeError('unexpected select in form: ' + str(adict))
        elif tag == 'form' and adict['name'] == 'loginData':
            assert self._action is None
            self._action = adict['action']
            self._within = True

    def handle_endtag(self, tag):
        if self._within and tag == 'form':
            self._within = False

    def gotit(self):
        return self._action is not None and not self._within

    def url(self):
        global formurl
        assert self.gotit()
        return urljoin(formurl, self._action)
        # return urljoin(formurl, '/oam/usna/pages/login.jsp')

    def data(self):
        assert self.gotit()
        return urlencode(self._fields)


parser = ParseLoginForm()
with open(formfile, 'r') as ffin:
    parser.feed(ffin.read())

print('{}|{}'.format(parser.url(), parser.data()))
EOF
)
  suburl=${proc1%%|*}
  subdata=${proc1#*|}

  echo -n "$pw" | curl -sL -b "$cookie1" -c "$cookie2" -o "$calpage" -d "$subdata" -d "$modata" --data-urlencode password@- "$suburl" || true
else
  curl -sL -b "$cookie2" -o "$calpage" -d "$modata" "$calurl" || true
fi

if ! grep -q 'Ac Yr Ending' "$calpage"; then
  echo "ERROR loading 'Absences - Enter' page" >&2
  exit 1
fi

echo "Login successful."

python3 - "$calurl" "$calpage" >"$missing" <<'EOF'
import sys
from html.parser import HTMLParser
from urllib.parse import urljoin, urlencode

formurl, formfile = sys.argv[1:]

class ParseLoginForm(HTMLParser):
    def __init__(self):
        super().__init__()
        self._links = []
        self._within_href = None
        self._within_b = False

    def handle_data(self, data):
        if self._within_b:
            self._links.append((data, self._within_href))

    def handle_starttag(self, tag, attrs):
        adict = dict(attrs)
        if tag == 'a':
            self._within_href = adict.get('href', None)
        elif tag == 'b' and self._within_href is not None:
            self._within_b = True

    def handle_endtag(self, tag):
        if tag == 'a':
            self._within_href = None
        elif tag == 'b':
            self._within_b = False

    def links(self):
        return self._links


parser = ParseLoginForm()
with open(formfile, 'r') as ffin:
    parser.feed(ffin.read())

for name, href in parser.links():
    print('{}|{}'.format(name, urljoin(formurl,href)))
EOF

exec 4<"$missing"
while IFS='|' read -u4 name href; do
  atturl=$(curl -sL -b "$cookie2" -o "$attpage" -w '%{url_effective}' "$href")

  proc3=$(python3 - "$atturl" "$attpage" <<'EOF'
import sys
from html.parser import HTMLParser
from urllib.parse import urljoin, urlencode

formurl, formfile = sys.argv[1:]

class ParseLoginForm(HTMLParser):
    def __init__(self):
        super().__init__()
        self._action = None
        self._within = False
        self._gotsubmit = False
        self._fields = []

    def handle_starttag(self, tag, attrs):
        adict = dict(attrs)
        if self._within:
            if tag == 'input':
                if adict['type'] == 'submit':
                    if adict['value'] == 'Record Absences':
                        if not self._gotsubmit:
                            self._fields.append((adict['name'], adict['value']))
                            self._gotsubmit = True
                    else:
                        raise RuntimeError('unexpected submit in form: ' + str(adict))
                elif adict['type'] == 'hidden':
                    self._fields.append((adict['name'], adict['value']))
                else:
                    raise RuntimeError('unexpected input in form: ' + str(adict))
            elif tag == 'select':
                self._fields.append((adict['name'], ''))
        elif tag == 'form':
            assert self._action is None
            self._action = adict['action']
            self._within = True

    def handle_endtag(self, tag):
        if self._within and tag == 'form':
            self._within = False

    def gotit(self):
        return self._action is not None and not self._within

    def url(self):
        global formurl
        assert self.gotit()
        return urljoin(formurl, self._action)

    def data(self):
        assert self.gotit()
        #return '&'.join('{}={}'.format(a,b) for (a,b) in self._fields)
        return urlencode(self._fields)


parser = ParseLoginForm()
with open(formfile, 'r') as ffin:
    parser.feed(ffin.read())

print('{}|{}'.format(parser.url(), parser.data()))
EOF
)
  recurl=${proc3%%|*}
  recdata=${proc3#*|}

  if ! curl -sL -o "$recpage" -b "$cookie2" -d "$recdata" "$recurl" \
    || ! grep -q 'Absence record.*created' "$recpage"
  then
    err "ERROR recording attendance for $name"
  fi

  echo "Attendance recorded for $name"
done
exec 4<&-

echo "All attendance is up to date!"

:
