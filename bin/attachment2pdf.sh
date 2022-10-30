#!/bin/bash

OUTPUTFILE=$1
INPUTFILE=$2

if [ -z "$INPUTFILE" -o -z "$OUTPUTFILE" ]; then
   echo "Usage: $0 <outputfilename> <inputfilename>"
   exit 1
fi

OUTPUTDIR=`dirname "$OUTPUTFILE"`

if [ -d $OUTPUTDIR ]; then
   filebase=`basename "$INPUTFILE"`
   extension=${filebase##*.}
   lowerextension=`echo "$extension"|tr A-Z a-z`

   # Determine what the file type/extension/converter to use is
   case "$lowerextension" in
      doc|docx|dotm|odt|rtf|wpd)
         converter='/usr/bin/lowriter'
         ;;
      xls|xlsx|xlsm|ods|tsv|csv)
         converter='/usr/bin/localc'
         ;;
      ppt|pptx|pptm|pps|ppsx|odp)
         converter='/usr/bin/loimpress'
         ;;
      vsd)
         converter='/usr/bin/lodraw'
         ;;
      xps|opxs) converter='/usr/bin/xpstopdf'
         extension=xps
         ;;
      md|markdown) converter='/usr/local/bin/markdown2pdf.sh'
         extension=markdown
         ;;
      epub) converter='/usr/local/bin/epub2pdf.sh'
         extension=other
         ;;
      pdf) converter='/bin/cp'
         ;;
      mov|mp3|mp4|m4v) converter='/bin/false'
         ;;
      *) converter='/usr/local/bin/image2pdf.sh'
         extension=other
         ;;
   esac

   if [ "x$extension" = "xother" ]; then
      $converter "$OUTPUTFILE" "$INPUTFILE"
   elif [ "x$extension" = "xmarkdown" ]; then
      $converter "$OUTPUTFILE" "$INPUTFILE"
   elif [ "x$extension" = "xxps" -o "x$extension" = "xpdf" ]; then
      $converter "$INPUTFILE" "$OUTPUTFILE"
   else
      CONVERTED_FILE=$OUTPUTDIR/`basename "$INPUTFILE" .$extension`.pdf

      echo "Converting '$INPUTFILE' to '$OUTPUTFILE' using $converter"

      $converter --headless --convert-to pdf:writer_pdf_Export --outdir "$OUTPUTDIR" "$INPUTFILE"

      # LibreOffice can be wierd
      if [ -s "$CONVERTED_FILE" -a "x$CONVERTED_FILE" != "x$OUTPUTFILE" ]; then
         cp "$CONVERTED_FILE" "$OUTPUTFILE"
      fi

      rm -f "$CONVERTED_FILE"
   fi

   if [ ! -s "$OUTPUTFILE" ]; then
      echo "Conversion of '$INPUTFILE' to '$OUTPUTFILE' failed!"
      exit 1
   fi
else
   echo "Unable to create temporary directory, giving up!"
   exit 1
fi

exit 0
