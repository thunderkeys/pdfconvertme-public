#!/bin/bash

OUTPUTFILE=$1
SUBJECT=$2
SOURCEFILE=$3

if [ -z $OUTPUTFILE ]; then
   echo "Usage: $0 <outputfilename>"
   exit 1
else
   if [ -f "$SOURCEFILE" ]; then
      SOURCEDIR=`dirname "$SOURCEFILE"`
      cd "$SOURCEDIR"
      /usr/local/bin/wkhtmltopdf --encoding utf-8 --title "$SUBJECT" -q $SOURCEFILE $OUTPUTFILE
   else
      /usr/local/bin/wkhtmltopdf --encoding utf-8 --title "$SUBJECT" -q - $OUTPUTFILE
   fi
fi
