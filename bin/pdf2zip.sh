#!/bin/bash

OUTPUTFILE=$1
INPUTFILE=$2

if [ -z "$INPUTFILE" -o -z "$OUTPUTFILE" ]; then
   echo "Usage: $0 <outputfilename> <inputfilename>"
   exit 1
fi

#cp -rv "`dirname $OUTPUTFILE`" /tmp/debug

OUTPUTDIR=`mktemp -d --tmpdir=/data/pdfconvert/tmp`
CONVERTED_FILE=`mktemp --tmpdir=/data/pdfconvert/tmp`.zip
if [ -d $OUTPUTDIR ]; then
   rm -f "$OUTPUTFILE"
   pdfseparate "$INPUTFILE" "$OUTPUTDIR/page-%02d.pdf"

   zip -qrj "$CONVERTED_FILE" "$OUTPUTDIR"
   if [ ! -s "$CONVERTED_FILE" ]; then
      echo "Conversion of '$INPUTFILE' to '$CONVERTED_FILE'failed!"
      exit 1
   fi

   cp "$CONVERTED_FILE" "$OUTPUTFILE"

   rm -fr "$OUTPUTDIR"
else
   echo "Unable to create temporary directory, giving up!"
   exit 1
fi

exit 0
