#!/bin/bash

OUTPUTFILE=$1
URL=$2
STDERR=`mktemp`

if [ ! -f "$STDERR" ]; then
   echo "Error creating tempfile, aborting"
   exit 1
fi

if [ -z $OUTPUTFILE ]; then
   echo "Usage: $0 <outputfilename>"
   exit 1
else
   /usr/local/bin/wkhtmltopdf --title "$URL" "$URL" $OUTPUTFILE 2>"$STDERR"
   grep -q 'Failed loading page' "$STDERR"
   # If page load failed, try it without javascript
   if [ $? -eq 0 ]; then
       /usr/local/bin/wkhtmltopdf -n --title "$URL" "$URL" $OUTPUTFILE 2>"$STDERR"
   fi
   rm -f "$STDERR"
   # hacky fix for http://code.google.com/p/wkhtmltopdf/issues/detail?id=463
   perl -pi -e 's/(Dests <<.*?)(#00)(.*?>>)/$1$3/s' $OUTPUTFILE
fi
