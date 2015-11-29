pdfconvertme-public
===================

A simplified, open-source version of [pdfconvert.me](http://pdfconvert.me)
for self-hosting in environments where privacy/security is a concern.

By default, it will generate the PDF but not return it via email.
To change this, make sure you have a working MTA and edit
`bin/pdfconvertme.pl`, set `$email_result = 1`

Required packages (available in Ubuntu 12.04/14.04):
- libtext-markdown-perl
- libhtml-fromtext-perl
- libemail-mime-perl
- libfile-slurp-perl
- libxml-feed-perl
- mpack
- poppler-utils (for pdf2text conversions)
- A copy of a compiled wkhtmltopdf binary (I have used [this version](https://code.google.com/p/wkhtmltopdf/downloads/detail?name=wkhtmltopdf-0.10.0_rc2-static-amd64.tar.bz2&can=2&q=) in the
past, but now compile my own as described
[here](https://github.com/wkhtmltopdf/wkhtmltopdf/blob/master/INSTALL.md))

The following Perl modules need to be installed from CPAN:
- [HTML::ExtractMain](http://search.cpan.org/~anirvan/HTML-ExtractMain/)
- [HTML::HeadParser](http://search.cpan.org/~gaas/HTML-Parser/)

For attachment conversions:
- libreoffice (requires `universe` in sources.list)
- libgxps-utils (for .xps files)
- imagemagick (for images)

Other optional packages:
- a2ps (raw text2pdf, no HTML-ification) - not enabled by default

Installation/Usage:
- Copy bin/ and etc/ to /usr/local/
- Pipe an email message to pdfconvertme.pl over stdin (I use procmail)
- Options to pdfconvertme.pl:
  - `--no-headers` - Don't include email headers at top of converted PDF (From/To/Subject/Date)
  - `--convert-attachment` - Attempt to convert the first valid attachment found in an email
  - `--force-url` - Convert the first URL found in a message body
  - `--force-rss-url` - Treat the first URL found in a message body an an RSS feed and convert the body found in the fist entry
  - `--force-content-url` - Only retrieve the main content of the URL, similar to Readability
  - `--no-javascript` - Will perform web conversion requests with javascript disabled
  - `--papersize <size>` - Change the papersize on the resulting PDF (defaults to A4)
  - `--pdf-to-text` - Attempts to convert a PDF back to text only
  - `--force-from <address>` - Force the response to come from a specific address
  - `--force-markdown` - Treat inline text as [Markdown](http://daringfireball.net/projects/markdown/syntax), implies --no-headers
