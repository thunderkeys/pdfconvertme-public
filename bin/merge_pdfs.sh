#!/bin/bash

OUTPUTFILE=$1
shift

if [ -z "$*" -o -z "$OUTPUTFILE" ]; then
   echo "Usage: $0 <outputfilename> [inputfilename1 [inputfilename2] ...]"
   exit 1
fi

OUTPUTDIR=`dirname "$OUTPUTFILE"`

if [ -d $OUTPUTDIR ]; then
   /usr/bin/pdfunite "$@" "$OUTPUTFILE"

   if [ ! -s "$OUTPUTFILE" ]; then
      echo "Conversion of '$*' to '$OUTPUTFILE' failed!"
      exit 1
   fi
else
   echo "Unable to create temporary directory, giving up!"
   exit 1
fi

exit 0
