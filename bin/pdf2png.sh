#!/bin/bash

OUTPUTFILE=$1
PDF=$2
OUTPUTDIR=`mktemp -d --tmpdir=/data/pdfconvert/tmp`

if [ -z "$PDF" ]; then
    echo "Usage: $0 <pdf> <outputfilename>"
    exit 1
else
    if [ -d "$OUTPUTDIR" ]; then
        cd "$OUTPUTDIR"
        /usr/bin/convert -density 400 "$PDF" pdf-page-%02d.jpg
        /usr/bin/convert -append pdf-page-*.jpg "$OUTPUTFILE"
        cd -
        rm -fr "$OUTPUTDIR"
    else
        exit 1
    fi
fi

exit 0
