#!/bin/bash

OUTPUTFILE=$1
INPUTFILE=$2

if [ -z "$INPUTFILE" -o -z "$OUTPUTFILE" ]; then
   echo "Usage: $0 <outputfilename> <inputfilename>"
   exit 1
fi

OUTPUTDIR=`dirname "$OUTPUTFILE"`

if [ -d $OUTPUTDIR ]; then
   /usr/local/bin/Markdown.pl "$INPUTFILE" > "$OUTPUTFILE".html

   if [ ! -s "$OUTPUTFILE".html ]; then
      echo "Conversion of '$INPUTFILE' to '$OUTPUTFILE'failed!"
      exit 1
   fi

   /usr/local/bin/html2pdf.sh "$OUTPUTFILE" "" "$OUTPUTFILE".html
else
   echo "Unable to create temporary directory, giving up!"
   exit 1
fi

exit 0
