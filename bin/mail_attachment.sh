#!/bin/bash 

# Globals
SUBJECT=undefined
ATTACHMENT=
ADDRESS=
BLURB_FILE=
FROM="pdfconvert@yourdomainhere.com"
REPLY_TO="no-reply@yourdomainhere.com"

while getopts :s:a:t:b:f:r: FLAG; do
    case $FLAG in
        s) SUBJECT=$OPTARG
           ;;
        t) ADDRESS=$OPTARG
           ;;
        f) FROM=$OPTARG
           ;;
        b) BLURB_FILE=$OPTARG
           ;;
        a) ATTACHMENT=$OPTARG
           ;;
       \?) #unrecognized option - show help
           echo "Option -$OPTARG not allowed."
           exit 1
           ;;
   esac
done

ATTACHOLDFILE=`basename "$ATTACHMENT"`
# Strip out quotes and funky UTF-8 characters from filename
ATTACHNEWFILE=`echo "$SUBJECT"|sed -e 's/^Converted: //' -e 's/"/%22/g' -e 's/\xe2\x80\x8b//g'`

MAIL_HEAD=`mktemp`
MAIL_BODY=`mktemp`

rm $MAIL_BODY

if [ -f $BLURB_FILE ]; then
   BLURB="-d $BLURB_FILE"
fi

echo "To: $ADDRESS" >$MAIL_HEAD
echo "From: $FROM" >>$MAIL_HEAD
echo "Reply-To: $REPLY_TO" >>$MAIL_HEAD

filebase=`basename "$ATTACHOLDFILE"`
extension=${filebase##*.}
lowerextension=`echo "$extension"|tr A-Z a-z`

mpack -a $BLURB -s "$SUBJECT" -o $MAIL_BODY "$ATTACHMENT"

if [ ! -z "$ATTACHNEWFILE" ]; then
   # If subject is not empty, replace attachment filename with <subject>.<extension>
   perl -pi -e "s~$ATTACHOLDFILE~${ATTACHNEWFILE}.${lowerextension}~g" $MAIL_BODY
fi

if [ -s $MAIL_BODY -a -s $MAIL_HEAD ]; then
   cat $MAIL_HEAD $MAIL_BODY | /usr/lib/sendmail -i -t
else
   echo "Error assembling message - empty body or header"
   exit 1
fi
rm $MAIL_HEAD $MAIL_BODY
