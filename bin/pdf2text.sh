#!/bin/bash

OUTPUTFILE=$1
PDF=$2

if [ -z "$PDF" ]; then
   echo "Usage: $0 <pdf> <outputfilename>"
   exit 1
else
   /usr/bin/pdftotext -eol dos "$PDF" "$OUTPUTFILE"
fi
