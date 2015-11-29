#!/bin/bash

OUTPUTFILE=$1
SUBJECT=$2
PAPERSIZE=$3
SOURCEFILE=$4

if [ -z $OUTPUTFILE ]; then
   echo "Usage: $0 <outputfilename>"
   exit 1
else
   if [ -f "$SOURCEFILE" ]; then
      SOURCEDIR=`dirname "$SOURCEFILE"`
      cd "$SOURCEDIR"
      /usr/local/bin/wkhtmltopdf -s "$PAPERSIZE" --encoding utf-8 --title "$SUBJECT" -q $SOURCEFILE $OUTPUTFILE
   else
      /usr/local/bin/wkhtmltopdf -s "$PAPERSIZE" --encoding utf-8 --title "$SUBJECT" -q - $OUTPUTFILE
   fi
fi
