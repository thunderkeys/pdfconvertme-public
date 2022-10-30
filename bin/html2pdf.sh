#!/bin/bash

OUTPUTFILE=$1
SUBJECT=$2
PAPERSIZE=$3
ORIENTATION=$4
SOURCEFILE=$5

if [ -z "$SOURCEFILE" -a ! -z "$ORIENTATION" ]; then
   SOURCEFILE="$ORIENTATION"
fi

if [ -z $OUTPUTFILE ]; then
   echo "Usage: $0 <outputfilename>"
   exit 1
else
   if [ -f "$SOURCEFILE" ]; then
      SOURCEDIR=`dirname "$SOURCEFILE"`
      cd "$SOURCEDIR"
      /usr/local/bin/wkhtmltopdf -O "$ORIENTATION" -s "$PAPERSIZE" --encoding utf-8 --title "$SUBJECT" -q $SOURCEFILE $OUTPUTFILE
   else
      /usr/local/bin/wkhtmltopdf -O "$ORIENTATION" -s "$PAPERSIZE" --encoding utf-8 --title "$SUBJECT" -q - $OUTPUTFILE
   fi
fi
