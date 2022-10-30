#!/bin/bash 

# Globals
SUBJECT=undefined
ATTACHMENT=
ADDRESS=
BLURB_FILE=
FROM=you@yourdomainhere.com
REPLY_TO="no-reply@yourdomainhere.com"
STRIP_TAGS=0
MAILGUN_AU=yourmailgunapiuserhere
MAILGUN_AP=yourmailgunapikeyhere

while getopts :s:a:t:b:f:r:D:R:dT FLAG; do
    case $FLAG in
        s) SUBJECT=$OPTARG
           ;;
        t) ADDRESS=$OPTARG
           ;;
        f) FROM=$OPTARG
           ;;
        r) REPLY_TO=$OPTARG
           ;;
        b) BLURB_FILE=$OPTARG
           ;;
        a) ATTACHMENT=$OPTARG
           ;;
        T) STRIP_TAGS=1
           ;;
       \?) #unrecognized option - show help
           echo "Option -$OPTARG not allowed."
           exit 1
           ;;
   esac
done

ATTACHOLDFILE=`basename "$ATTACHMENT"`
# Strip out quotes and funky UTF-8 characters from filename
# if requested, also remove tags (@tag and #tag) from the filename
if [ "x$STRIP_TAGS" = "x1" ]; then
   ATTACHNEWFILE=`echo "$SUBJECT"|sed -e 's/^Converted: //' -e 's/"/%22/g' -e 's/:/_/g' -e 's/\xe2\x80\x8b//g' -e 's:[@#][^[:space:]]*::g' -e 's:[[:space:]]*$::' -e 's/–/-/g'`
else
   ATTACHNEWFILE=`echo "$SUBJECT"|sed -e 's/^Converted: //' -e 's/"/%22/g' -e 's/:/_/g' -e 's/\xe2\x80\x8b//g' -e 's/–/-/g' -e 's:/:_:g' |sed -e 's/^-/_/g'`
fi

filebase=`basename "$ATTACHOLDFILE"`
extension=${filebase##*.}
lowerextension=`echo "$extension"|tr A-Z a-z`

MAIL_HEAD=`mktemp`
MAIL_BODY=`mktemp`

rm $MAIL_BODY

if [ -f $BLURB_FILE ]; then
   BLURB="-d $BLURB_FILE"
fi

echo "To: $ADDRESS" >$MAIL_HEAD
echo "From: $FROM" >>$MAIL_HEAD
echo "Reply-To: $REPLY_TO" >>$MAIL_HEAD

mpack -a $BLURB -s "$SUBJECT" -o $MAIL_BODY "$ATTACHMENT"

if [ ! -z "$ATTACHNEWFILE" ]; then
   # If subject is not empty, replace attachment filename with <subject>.<extension>
   perl -pi -e "s~$ATTACHOLDFILE~${ATTACHNEWFILE}.${lowerextension}~g" $MAIL_BODY
fi

if [ -s $MAIL_BODY -a -s $MAIL_HEAD ]; then
   /usr/local/bin/swaks --auth \
        -n \
        --server smtp.mailgun.org \
        --au "$MAILGUN_AU" \
        --ap "$MAILGUN_AP" \
        --to "$ADDRESS" \
        --h-From: "$FROM" \
        --h-Reply-To "$REPLY_TO" \
        --h-Subject: "$SUBJECT" \
        --attach-name "${ATTACHNEWFILE}.${lowerextension}" \
        --attach "$ATTACHMENT" \
        --body "`cat \"$BLURB_FILE\"`"
else
   echo "mailattachment.sh: Error assembling message!"
   exit 1
fi
rm $MAIL_HEAD $MAIL_BODY
