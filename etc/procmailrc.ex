LOGFILE=/home/pdfconvert/log/procmail.log
LOGABSTRACT=all

:0
* webconvert@yourdomainhere.com
| /usr/local/bin/pdfconvertme.pl --force-url

:0
* (md|markdown)@yourdomainhere.com
| /usr/local/bin/pdfconvertme.pl --force-markdown

:0
* attachconvert@yourdomainhere.com
| /usr/local/bin/pdfconvertme.pl --convert-attachment

:0
* noheaders@yourdomainhere.com
| /usr/local/bin/pdfconvertme.pl --no-headers

:0
* rssconvert@yourdomainhere.com
| /usr/local/bin/pdfconvertme.pl --force-rss-url

:0
| /usr/local/bin/pdfconvertme.pl
