#!/bin/bash

OUTPUTFILE=$1

if [ -z $OUTPUTFILE ]; then
   echo "Usage: $0 <outputfilename>"
   exit 1
else
   a2ps -q -1 -R --header= -o - | ps2pdf - $OUTPUTFILE
fi
