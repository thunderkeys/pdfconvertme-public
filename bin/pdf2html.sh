#!/bin/bash

OUTPUTFILE=$1
INPUTFILE=$2
INPUTBASEFILE=`basename "$INPUTFILE" .pdf`

if [ -z "$INPUTFILE" -o -z "$OUTPUTFILE" ]; then
   echo "Usage: $0 <outputfilename> <inputfilename>"
   exit 1
fi

/usr/local/bin/pdf2htmlEX "$INPUTFILE"
sleep 1
cp "$INPUTBASEFILE".html "$OUTPUTFILE"
