pdfconvertme-public
===================

A stripped down, open-source version of [pdfconvert.me](http://pdfconvert.me)
for self-hosting in environments where privacy/security is a concern.

By default, it will generate the PDF but not return it via email.
To change this, make sure you have a working MTA and edit
`bin/pdfconvertme.pl`, set `$email_result = 1`

Required packages (available in Ubuntu 12.04/14.04):
- libhtml-fromtext-perl
- libemail-mime-perl
- libfile-slurp-perl
- mpack
- A copy of a compiled wkhtmltopdf binary (I use [this version](https://code.google.com/p/wkhtmltopdf/downloads/detail?name=wkhtmltopdf-0.10.0_rc2-static-amd64.tar.bz2&can=2&q=))

For attachment conversions:
- libreoffice (requires `universe` in sources.list)
- libgxps-utils (for .xps files)
- imagemagick (for images)

Installation/Usage:
- Copy bin/ and etc/ to /usr/local/
- Pipe an email message to pdfconvertme.pl over stdin (I use procmail)
- Options to pdfconvertme.pl:
  - `--no-headers` - Don't include email headers at top of converted PDF (From/To/Subject/Date)
  - `--convert-attachment` - Attempt to convert the first valid attachment found in an email
  - `--force-url` - Convert the first URL found in a message body
