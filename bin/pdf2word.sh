#!/bin/bash

OUTPUTFILE=$1
INPUTFILE=$2
INPUTBASEFILE=`basename "$INPUTFILE" .pdf`
OUTPUT_TEMPDIR=`mktemp -d`

if [ -d "$OUTPUT_TEMPDIR" ]; then
  cd "$OUTPUT_TEMPDIR"

  pdftohtml -s "$INPUTFILE" "$INPUTBASEFILE".html
  sleep 1
  pandoc -s -r html "$INPUTBASEFILE"-html.html -o "$OUTPUTFILE"

  rm -fr "$OUTPUT_TEMPDIR"
fi
