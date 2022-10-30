#!/bin/bash

OUTPUTFILE=$1
PDF=$2
OUTPUTDIR=`mktemp -d --tmpdir=/data/pdfconvert/tmp`
TEMPFILE=`mktemp --tmpdir="$OUTPUTDIR"`

if [ -z "$PDF" ]; then
    echo "Usage: $0 <pdf> <outputfilename>"
    exit 1
else
    if [ -d "$OUTPUTDIR" ]; then
        cd "$OUTPUTDIR"
        /usr/bin/convert -density 300 "$PDF" pdf-page-%02d.jpg
        rm -f $TEMPFILE && zip $TEMPFILE  pdf-page-*.jpg
        if [ -s "$TEMPFILE" ]; then
            cp "$TEMPFILE" "$OUTPUTFILE"
        fi
    else
        exit 1
    fi
fi

exit 0
