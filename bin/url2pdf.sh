#!/bin/bash

OUTPUTFILE=$1
URL=$2
ARGS="$3"
STDERR=`mktemp`
PROXY=""

if [ ! -f "$STDERR" ]; then
   echo "Error creating tempfile, aborting"
   exit 1
fi

if [ -z $OUTPUTFILE ]; then
   echo "Usage: $0 <outputfilename>"
   exit 1
else
   if [ -z "$ARGS" ]; then
      if [[ "$URL" =~ \.[Pp][Dd][Ff]$ ]]; then
         wget -qO "$OUTPUTFILE" "$URL"
         exit 0
      else
         /usr/local/bin/wkhtmltopdf $PROXY --title "$URL" "$URL" $OUTPUTFILE 2>"$STDERR"
         grep -q 'Failed loading page' "$STDERR"
         # If page load failed, try it without javascript
         if [ $? -eq 0 ]; then
             /usr/local/bin/wkhtmltopdf $PROXY -n --title "$URL" "$URL" $OUTPUTFILE 2>"$STDERR"
         fi
         rm -f "$STDERR"
      fi
   else
      if [[ "$URL" =~ \.[Pp][Dd][Ff]$ ]]; then
         wget -qO "$OUTPUTFILE" "$URL"
         exit 0
      else
         /usr/local/bin/wkhtmltopdf $PROXY $ARGS --title "$URL" "$URL" $OUTPUTFILE
      fi
   fi

   # hacky fix for http://code.google.com/p/wkhtmltopdf/issues/detail?id=463
   /usr/bin/perl -pi -e 's/(Dests <<.*?)(#00)(.*?>>)/$1$3/s' $OUTPUTFILE
fi
