#!/bin/bash

OUTPUTFILE=$1
URL=$2

if [ -z $OUTPUTFILE ]; then
   echo "Usage: $0 <outputfilename>"
   exit 1
else
   /usr/local/bin/wkhtmltopdf --load-error-handling ignore --title "$URL" -q "$URL" $OUTPUTFILE

   # hacky fix for http://code.google.com/p/wkhtmltopdf/issues/detail?id=463
   perl -pi -e 's/(Dests <<.*?)(#00)(.*?>>)/$1$3/s' $OUTPUTFILE
fi
