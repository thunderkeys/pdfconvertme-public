#!/bin/bash

INPUTFILE=$1
OUTPUTFILE=$2
PDFVERSION=$3

gs -sDEVICE=pdfwrite -dNOPAUSE -dBATCH -dSAFER -dCompatibilityLevel="$PDFVERSION" -sOutputFile="$OUTPUTFILE" "$INPUTFILE"
