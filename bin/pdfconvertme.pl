#!/usr/bin/perl

# License:
# The MIT License (MIT)
#
# Copyright (c) 2013-2022 Brian Almeida <bma@thunderkeys.net>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

use strict;
use warnings;

# Modules
use English qw(-no_match_vars);
use Getopt::Long;
use Digest::SHA qw(sha256_hex);
use Email::MIME;
use Email::Address;
use HTML::ExtractMain qw(extract_main_html);
use HTML::FormatText;
use HTML::HeadParser;
use HTML::FromText;
use HTML::Entities;
use File::Basename;
use Text::Markdown qw(markdown);
use File::Slurp;
use Text::Iconv;
use File::Temp qw(tempdir);
use File::Path;
use URI::Escape;
use IPC::Open2;
use XML::Feed;
use POSIX;
use Carp;

# Globals
my $attachments_enabled    = 1;
my $converter_threshold    = 2;
my $prevent_mail_loops     = 1;
my $loop_domain            = 'yourdomainhere.com';
my $email_result           = 0;                                           ### CHANGE ME ###
my $email_domain           = 'yourdomainhere.com';
my $mail_attachment_cmd    = '/usr/local/bin/mail_attachment.sh';
my $mailgun_attachment_cmd = '/usr/local/bin/mail_attachment_mailgun.sh';
my $convert_version_cmd    = '/usr/local/bin/convert_pdf_version.sh';
my $blurb_file             = '/usr/local/etc/pdfconvertme.blurb';
my $blurb_file_new         = undef;
my $logfile                = '/var/tmp/pdfconvert.log';
my $log_verbosity          = 2; # 2 for more detailed debug info
my $log_fh;
my $tmpdir                 = '/var/tmp';
my $failed                 = 0;
my @created_files;
my %options;
my %opts = (
   'force-url'          => \$options{'force-url'},
   'force-rss-url'      => \$options{'force-rss-url'},
   'force-content-url'  => \$options{'force-content-url'},
   'force-markdown'     => \$options{'force-markdown'},
   'no-javascript'      => \$options{'no-javascript'},
   'no-headers'         => \$options{'no-headers'},
   'all-headers'        => \$options{'all-headers'},
   'no-subject-prefix'  => \$options{'no-subject-prefix'},
   'blurb-file=s'       => \$options{'blurb-file'},
   'convert-attachment' => \$options{'convert-attachment'},
   'papersize=s'        => \$options{'papersize'},
   'landscape'          => \$options{'landscape'},
   'pdf-to-text'        => \$options{'pdf-to-text'},
   'pdf-to-word'        => \$options{'pdf-to-word'},
   'pdf-to-html'        => \$options{'pdf-to-html'},
   'pdf-to-zip'         => \$options{'pdf-to-zip'},
   'ignore-reply-to'    => \$options{'ignore-reply-to'},
   'force-from=s'       => \$options{'force-from'},
   'force-reply-to=s'   => \$options{'force-reply-to'},
   'blurb-include-orig' => \$options{'blurb-include-orig'},
   'strip-subject-tags' => \$options{'strip-subject-tags'},
   'no-ccs'             => \$options{'no-ccs'},
   'translate=s'        => \$options{'translate'},
   'use-mailgun'        => \$options{'use-mailgun'},
   'skip-images'        => \$options{'skip-images'},
   'debug'              => \$options{'debug'},
);
my %converters = (
   'attachment-pdftext' => '/usr/local/bin/pdf2text.sh',
   'attachment-pdfword' => '/usr/local/bin/pdf2word.sh',
   'attachment-pdfhtml' => '/usr/local/bin/pdf2html.sh',
   'attachment-pdfzip'  => '/usr/local/bin/pdf2zip.sh',
   'attachment-pdfpng'  => '/usr/local/bin/pdf2png.sh',
   'attachment'         => '/usr/local/bin/attachment2pdf.sh',
   'text'               => '/usr/local/bin/text2pdf.sh',
   'html'               => '/usr/local/bin/html2pdf.sh',
   'url'                => '/usr/local/bin/url2pdf.sh',
   'merge'              => '/usr/local/bin/merge_pdfs.sh',
);
my @papersizes = qw(
   A0 A1 A2 A3 A4 A5 A6 A7 A8 A9
   B0 B1 B2 B3 B4 B5 B6 B7 B8 B9
   B10 C5E Comm10E DLE Executive Folio
   Ledger Legal Letter Tabloid
);
my @languages = qw(
    af hi pa sq hmn otq am mww ro ar hu ru hy is sm
    az ig gd eu id sr-Cyrl be ga sr-Latn bn it
    st bs ja sn bg jv sd yue kn si ca kk sk ceb
    km sl ny tlh so zh-CN tlh-Qaak es zh-TW ko
    su co ku sw hr ky sv cs lo ty da la tg nl
    lv ta en lt tt eo lb te et mk th fj mg to tl
    ms tr fi ml udm fr mt uk fy mi ur gl mr uz ka
    mn vi de my cy el ne xh gu no yi ht ps yo ha fa
    yua haw pl zu he pt
);
my $default_papersize   = 'A4';
my $orientation         = 'Portrait';

# ---------------------------------------------------
sub logmsg {
   my ($msg, $loglevel) = @_;

   # If loglevel not specifed, assume the lowest
   $loglevel //= 1;

   if (!defined $log_fh) {
      open($log_fh, '>>', $logfile) or croak "Can't append to logfile: $OS_ERROR\n";
   }

   my $ts = strftime("%Y-%m-%d %H:%M:%S", localtime());

   if ($options{'debug'}) {
      print STDERR "$ts [$$] $msg\n";
   }
   if ($log_verbosity >= $loglevel) {
      print {$log_fh} "$ts [$$] $msg\n";
   }

   return;
}

sub convert_to_pdf {
   my ($message, $format, $tempdir, @converter_args) = @_;
   my $suffix;
   if ($format eq 'attachment-pdftext') {
      $suffix = '.txt';
      $blurb_file          = '/usr/local/etc/pdfconvertme_txt.blurb';
   }
   elsif ($format eq 'attachment-pdfword') {
      $suffix = '.docx';
      $blurb_file          = '/usr/local/etc/pdfconvertme_docx.blurb';
   }
   elsif ($format eq 'attachment-pdfhtml') {
      $suffix = '.html';
      $blurb_file          = '/usr/local/etc/pdfconvertme_html.blurb';
   }
   elsif ($format eq 'attachment-pdfzip') {
      $suffix = '.zip';
      $blurb_file          = '/usr/local/etc/pdfconvertme_zip.blurb';
   }
   elsif ($format eq 'attachment-pdfpng') {
      $suffix = '.png';
      $blurb_file          = '/usr/local/etc/pdfconvertme_png.blurb';
   }
   else {
       $suffix = '.pdf';
   }
   if (! -d "$tempdir") {
       logmsg("ERROR: Temporary directory '$tempdir' is not a directory!");
   }
   my $pdf_tempfile = File::Temp->new(
      TEMPLATE => 'pdfconvertme.XXXXXX',
      DIR      => $tempdir,
      SUFFIX   => $suffix,
   ) or croak $OS_ERROR;
   $pdf_tempfile->unlink_on_destroy(0);
   push @created_files, $pdf_tempfile->filename;
   my $fh;

   my $converter = $converters{$format};
   if (!defined $converter) {
      print "Undefined format $format!";
      exit 1;
   }

   local $SIG{'PIPE'} = 'IGNORE';
   if (open($fh, '|-', $converter, $pdf_tempfile, @converter_args)) {
      logmsg("Starting conversion from $format to PDF ($converter $pdf_tempfile " . join(' ', @converter_args) . "...", 2);
      print {$fh} $message;
      close($fh) or logmsg("Unable to close converter: $CHILD_ERROR");
      logmsg("Conversion completed.", 2);
   }
   else {
      logmsg("Failed to spawn converter '|$converter $pdf_tempfile "
           . join(' ', @converter_args)
           . "'");
      unlink $pdf_tempfile;
      $pdf_tempfile = '';
   }

   if (exists $options{'pdf_version'}) {
      my $new_pdf_tempfile = File::Temp->new(
         TEMPLATE => 'pdfconvertme.XXXXXX',
         DIR      => $tempdir,
         SUFFIX   => $suffix,
      ) or croak $OS_ERROR;
      $new_pdf_tempfile->unlink_on_destroy(0);
      push @created_files, $new_pdf_tempfile->filename;
      my $rc = system($convert_version_cmd, $pdf_tempfile, $new_pdf_tempfile, $options{'pdf_version'});
      if ($rc == -1) {
         logmsg("failed to execute pdf version conversion $OS_ERROR");
         exit 1;
      }
      elsif ($rc & 127) {
         logmsg(sprintf "child died with signal %d, %s coredump", ($rc & 127),  ($rc & 128) ? 'with' : 'with    out');
         exit 1;
      }
      elsif ($rc >> 8 != 0) {
         logmsg(sprintf("child exited with value %d", $rc >> 8), 2);
      }
      else {
         if (-s $new_pdf_tempfile) {
             logmsg("Conversion to PDF version " . $options{'pdf_version'} . " succeeded.", 2);
             unlink($pdf_tempfile);
             $pdf_tempfile = $new_pdf_tempfile;
         }
      }
   }

   return $pdf_tempfile->filename;
}

sub unpack_multipart {
   my ($in_part, $depth) = @_;
   my @unpacked_parts;

   if ($depth > 20) {
      logmsg("Too deep of recursion on multiparts, giving up.");
      exit 1;
   }

   foreach my $part ($in_part->parts) {
      if ($part->content_type =~ m~^multipart/~xms) {
         logmsg("Unpacking another level of parts at depth $depth", 2);
         @unpacked_parts = unpack_multipart($part, $depth + 1);
      }
      else {
         push @unpacked_parts, $part;
      }
   }

   return @unpacked_parts;
}

sub get_message_parts {
   my ($parsed) = @_;
   my @real_parts;

   my @parts       = $parsed->parts;
   my $parts_count = scalar(@parts);
   logmsg("Message has $parts_count initial part" . ($parts_count == 1 ? '' : 's'), 2);

   foreach my $part (@parts) {
      if ($part->content_type =~ m~^multipart/~xms) {
         logmsg("Found additional multipart body, unpacking it and appending to total list of parts", 2);
         push @real_parts, unpack_multipart($part, 1);
      }
      else {
         push @real_parts, $part;
      }
   }

   return @real_parts;
}

sub convert_to_utf8 {
   my ($body, $encoding) = @_;

   my $converter = Text::Iconv->new($encoding, 'utf-8');
   my $new_body = $converter->convert($body);

   # Sometimes Text::Iconv can be fussy - try with standalone iconv if it failed
   if (!defined $new_body || $new_body eq '') {
      logmsg("Original encoding conversion failed, trying with iconv -c...", 2);
      my ($iconv_fh_in, $iconv_fh_out);
      my $pid =
        open2($iconv_fh_out, $iconv_fh_in, '/usr/bin/iconv', '-f', $encoding,
         '-t', 'utf-8', '-c');
      if ($pid) {
         print {$iconv_fh_in} $body;
         my $result = close($iconv_fh_in);
         if ($result == 0) {
            $new_body = '';
            while (my $line = <$iconv_fh_out>) {
               $new_body .= $line;
            }
            waitpid $pid, 0;
            close($iconv_fh_out) or carp 'Unable to close iconv output handle';
         }
      }
   }

   return $new_body;
}

sub convert_plain_to_html {
   my ($body, $encoding) = @_;
   my $new_body;

   if ($encoding ne 'utf-8') {
      $new_body =
        text2html($body,
         (urls => 1, email => 1, lines => 1, paras => 1, metachars => 0));
   }
   else {
      $new_body =
        text2html($body, (urls => 1, email => 1, lines => 1, paras => 1));
   }

   return $new_body;
}

sub translate_body {
   my ($body, $target_lang) = @_;
   my $new_body;

   my $translate_input_temp = File::Temp->new(
      TEMPLATE => 'pdfconvertme_translate_in.XXXXXX',
      DIR      => $tmpdir,
      SUFFIX   => '.txt',
   ) or croak $OS_ERROR;
   my $translate_output_temp = File::Temp->new(
      TEMPLATE => 'pdfconvertme_translate_out.XXXXXX',
      DIR      => $tmpdir,
      SUFFIX   => '.txt',
   ) or croak $OS_ERROR;

   write_file($translate_input_temp, $body);

   logmsg('Attempting to translate body text to ' . $target_lang, 2);
   my @translate_cmd = ('/usr/bin/trans', '-b',
         ':' . $target_lang,
         '-i', $translate_input_temp,
         '-o', $translate_output_temp
   );
   my $rc = system(@translate_cmd);
   if ($rc == -1) {
      logmsg("failed to execute translate: $OS_ERROR");
      exit 1;
   }
   elsif ($rc & 127) {
      logmsg(sprintf "child died with signal %d, %s coredump", ($rc & 127),  ($rc & 128) ? 'with' : 'with    out');
      exit 1;
   }
   else {
      logmsg(sprintf("child exited with value %d", $rc >> 8), 2);
   }

   if (-s $translate_output_temp) {
     $new_body = read_file($translate_output_temp);
     return $new_body;
   }

   return $body;
}

sub handle_url {
   my ($url) = @_;
   my $body;
   my $format;

   if ($options{'force-url'}) {
     $format  = 'url';
     $url     = clean_url($url);
   }
   elsif ($options {'force-rss-url'}) {
     $format = 'html';
     $body   = get_rss_feed_body($url);
   }
   elsif ($options {'force-content-url'}) {
     $format = 'html';
     $body   = get_content_body($url);
   }

   return ($url, $format, $body);
}

sub clean_url {
   my ($url) = @_;

   # remove any extra newlines
   $url     =~ s/[\r\n]//xms;

   # Don't shorten or modify google search URLs - sends back to homepage
   return $url if $url =~ m~google\.com/search~xms;

   # clean up url
   my $uri = URI->new($url);
   $url = $uri->as_string;

   # attempt to unshorten it
   my $url_new = LWP::UserAgent->new->get($url)->request->uri;
   if (defined $url_new && $url_new ne '' && $url ne $url_new) {
     logmsg("URL translated/unshortened from $url to $url_new", 2);
     $url = $url_new;
   }

   return $url;
}

sub validate_translate_lang {
   my ($target_lang_test) = @_;

   my $target_lang = 'en';
   if (grep(/^$target_lang_test$/, @languages)) {
      $target_lang = $target_lang_test;
   }
   else {
      logmsg("Unable to validate target language $target_lang_test, falling back to $target_lang");
   }

   return $target_lang;
}

sub get_rss_feed_body {
   my ($url) = @_;

   my $feed    = XML::Feed->parse(URI->new($url)) or croak XML::Feed->errstr;
   my $entry   = ($feed->entries)[0];
   my $content = $entry->content;

   return $content->body;
}

sub get_content_body {
   my ($url) = @_;
   my $body;

   my $ua = LWP::UserAgent->new;

   my $req = HTTP::Request->new(GET => $url);
   my $res = $ua->request($req);

   if ($res->is_success) {
      my $content = $res->decoded_content;
      my $parser  = HTML::HeadParser->new;
      $parser->parse($content);
      my $title = $parser->header('Title');
      my $main_html = extract_main_html($content, output_type => 'html');

      $body = '<html><head>';
      $body .= '<title>' . $title . '</title>';
      $body .= '</head><body>';
      $body .= '<h2><a href="' . $url . '">'
             . $title . '</a></h2>';
      $body .= $main_html;
      $body .= '</body></html>';
   }

   return $body;
}

sub check_options {
   my ($to_addr) = @_;

   logmsg("Checking for implicit options against '$to_addr'", 2);
   # First, check for options implicitly defined in the to address
   $options{'convert-attachment'} = 1 if ($to_addr =~ /attachconvert/ixms);
   $options{'force-url'}          = 1 if ($to_addr =~ /webconvert/ixms);
   $options{'force-rss-url'}      = 1 if ($to_addr =~ /rssconvert/ixms);
   $options{'force-url-content'}  = 1 if ($to_addr =~ /webconvert.*content/ixms);
   $options{'force-markdown'}     = 1 if ($to_addr =~ /markdown|md/ixms);
   $options{'strip-subject-tags'} = 1 if ($to_addr =~ /striptags/ixms);
   $options{'no-headers'}         = 1 if ($to_addr =~ /noheaders/ixms);
   $options{'all-headers'}        = 1 if ($to_addr =~ /allheaders/ixms);
   $options{'ignore-reply-to'}    = 1 if ($to_addr =~ /noreplyto/ixms);
   $options{'no-javascript'}      = 1 if ($to_addr =~ /nojs/ixms);
   $options{'pdf-to-word'}        = 1 if ($to_addr =~ /pdftoword/ixms);
   $options{'pdf-to-html'}        = 1 if ($to_addr =~ /pdftohtml/ixms);
   $options{'pdf-to-text'}        = 1 if ($to_addr =~ /pdftotext/ixms);
   $options{'pdf-to-zip'}         = 1 if ($to_addr =~ /pdftozip/ixms);
   $options{'pdf-to-png'}         = 1 if ($to_addr =~ /pdftopng/ixms);
   $options{'landscape'}          = 1 if ($to_addr =~ /landscape/ixms);
   $options{'no-ccs'}             = 1 if ($to_addr =~ /noccs/ixms);
   $options{'skip-images'}        = 1 if ($to_addr =~ /skipimages/ixms);
   $options{'papersize'}          = 'letter' if ($to_addr =~ /letter/ixms);
   $options{'papersize'}          = 'legal'  if ($to_addr =~ /legal/ixms);
   if ($to_addr =~ /translate-([a-z]{2,3})/ixms) {
       $options{'translate'} = $1;
   }

   if (defined $options{'translate'}) {
       $options{'translate'} = validate_translate_lang($options{'translate'});
   }

   if ($options{'pdf-to-word'} || $options{'pdf-to-html'} || $options{'pdf-to-text'} || $options{'pdf-to-zip'} || $options{'pdf-to-png'}) {
       $options{'convert-attachment'} = 1;
       $options{'skip-images'}        = 1;
   }
  
   if ($options{'papersize'}) {
      if ( ! grep { lc $_ eq lc $options{'papersize'} } @papersizes) {
         logmsg("Ignoring unknown papersize '" . $options{'papersize'} . "'");
         $options{'papersize'} = $default_papersize;
      }
      else {
         logmsg("Using defined papersize '" . $options{'papersize'} . "'", 2);
      }
   }
   else {
      $options{'papersize'} = $default_papersize;
   }

   if ($options{'landscape'}) {
      $orientation = 'Landscape';
   }

   if ($options{'force-url'}) {
      logmsg("force-url enabled.", 2);
   }

   if ($options{'force-rss-url'} || $options{'force-content-url'}) {
      logmsg("force-rss-url/force-content-url enabled, implies no-headers.", 2);
      $options{'no-headers'} = 1;
   }

   if ($options{'force-markdown'}) {
      if ($to_addr =~ /withheaders/ixms) {
         logmsg("force-markdown enabled, but withheaders specified.", 2);
         $options{'no-headers'} = 0;
      }
      else {
         logmsg("force-markdown enabled, implies no-headers.", 2);
         $options{'no-headers'} = 1;
      }
   }

   if ($options{'blurb-file'} && -f $options{'blurb-file'}) {
      $blurb_file = $options{'blurb-file'};
   }
   if ($options{'blurb-include-orig'}) {
      $blurb_file_new = File::Temp->new(
         TEMPLATE => 'pdfconvertme.XXXXXX',
         DIR      => $tmpdir,
         SUFFIX   => '.blurb',
      ) or croak $OS_ERROR;
   }
   if ($options{'strip-subject-tags'}) {
      $options{'no-subject-prefix'} = 1;
   }
}

# -------------------------- main ----------------------

logmsg("Starting pdfconvert");

my @processes = `/bin/ps -f`;
my $wkhtmlcount = 0;
foreach my $process (@processes) {
    $wkhtmlcount++ if ($process =~ /wkhtmltopdf/xms);
}
if ($wkhtmlcount > $converter_threshold) {
    my $rand = int(rand(30))+1;
    logmsg("More than $converter_threshold wkhtmltopdf processes running ($wkhtmlcount), sleeping for $rand seconds...");
    sleep($rand);
}

logmsg("Parsing options", 2);
if (!GetOptions(%opts)) {
   logmsg("Failed to parse options: $OS_ERROR");
   exit 1;
}

my $email_input_tmp = File::Temp->new(
   TEMPLATE => 'pdfconvertme.XXXXXX',
   DIR      => $tmpdir,
   SUFFIX   => '.msg'
) or croak $OS_ERROR;
# Don't unlink the file when we go out of scope
$email_input_tmp->unlink_on_destroy(0);
push @created_files, $email_input_tmp->filename;

if (!$email_input_tmp) {
   logmsg("Unable to create tempfile for storing email: $OS_ERROR");
   exit 1;
}

# Read in email soure message and save to disk
while (my $line = <>) {
   print {$email_input_tmp} $line;
}
if (!close($email_input_tmp)) {
   logmsg("Unable to close() on $email_input_tmp: $OS_ERROR");
}
logmsg("Message stored on filesystem.", 2);

# Parse the message
my $text;
{
   local $INPUT_RECORD_SEPARATOR = undef;
   $text = read_file($email_input_tmp->filename);
}
logmsg("Message read.", 2);

$Email::MIME::ContentType::STRICT_PARAMS = 0;
my $parsed = Email::MIME->new($text);
if (!$parsed) {
   logmsg("ERROR: Message failed to parse. Error: $OS_ERROR");
   exit 1;
}
else {
   logmsg("Message parsed.", 2);
}

my $to      = $parsed->header('To');
my @tos     = Email::Address->parse($to);
my $to_addr;
if (@tos == 0) {
   $to_addr = 'pdfconvert@' . $email_domain;
}
else {
   $to_addr = $tos[0]->address;
}

my $orig_to      = $parsed->header('X-Original-To');
my @orig_tos     = Email::Address->parse($orig_to);
if (@orig_tos == 1) {
   my $orig_to_addr = $orig_tos[0]->address;
   if ($orig_to_addr ne $to_addr && $orig_to_addr =~ /\@${email_domain}$/xms) {
      logmsg("Using $orig_to_addr (X-Original-To) instead of $to_addr (To)", 2);
      $to_addr = $orig_to_addr;
   }
}

logmsg("to_addr=$to_addr", 2);
my $from      = $parsed->header('From');
my $from_orig = $from;
my $from_raw_orig = $from;

if (!defined $from) {
   logmsg("ERROR: No 'From:' header, aborting!");
   exit 1;
}
if ($from_orig eq 'pdfconvert@' . $loop_domain) {
   logmsg("ERROR: seems to be from ourselves, skipping");
   exit 0;
}

check_options($to_addr);

foreach my $alt_header (qw(X-Forwarded-For Reply-To Resent-From)) {
   next if $alt_header eq 'Reply-To' && $options{'ignore-reply-to'};
   my $alternate_from = $parsed->header($alt_header);
   if (defined $alternate_from && $alternate_from !~ /^\s*$/xms) {
      my @froms_alt     = Email::Address->parse($alternate_from);
      my $from_alt_addr = $froms_alt[0]->address;
      my @froms_orig     = Email::Address->parse($from_orig);
      my $from_orig_addr = $froms_orig[0]->address;
      if (defined $from_alt_addr && $from_alt_addr !~ /^\s*$/xms && $from_alt_addr !~ /^(?:donot|no-?)reply\@/xms && $from_alt_addr ne $from_orig_addr) {
         logmsg("Found $alt_header header with value '$from_alt_addr', using that as from address instead of '$from_orig_addr'", 2);
         $from = $alternate_from;
         last;
      }
   }
}

if ($from =~ /^(?:donot|no)reply\@/xms) {
   logmsg("Message is from '$from' which appears to be a do not reply account - skipping conversion");
   exit 0;
}

logmsg("Message is from: $from", 2);

if ($to_addr =~ m/.*?\+(.*)\@/xms) {
   my $encoded_to = $1;
   my $new_from;

   $encoded_to =~ s/=/\@/xms;
   if (defined $encoded_to && $encoded_to !~ /^\s*$/xms) {
      $new_from   = (Email::Address->parse($encoded_to))[0]->address;
      if (defined $new_from && $new_from !~ /^\s*$/xms) {
         logmsg("Found alternate delivery address '$encoded_to' encoded in '$to_addr', using it", 2);
         $from = $new_from; 
      }
   }
}

my $subject   = $parsed->header('Subject');
my @froms     = Email::Address->parse($from);
my $from_addr = $froms[0]->address;

if ($options{'use-mailgun'}) {
   $mail_attachment_cmd = $mailgun_attachment_cmd;
}

if (defined $from_addr) {
   logmsg("Email address only portion of from is: $from_addr", 2);
}
else {
   logmsg("Unable to determine a valid from address from '$from', aborting!");
   exit 0;
}

if ($prevent_mail_loops) {
   my $in_reply_to       = $parsed->header('In-Reply-To');
   my $loop_domain_regex = qr{$loop_domain};
   if (defined $in_reply_to && $in_reply_to =~ /$loop_domain_regex/xms) {
      logmsg("Detected a mail loop via header 'In-Reply-To: $in_reply_to'");
      exit 0;
   }
   if ($subject =~ /Converted: Convert failed:/) {
      logmsg("Detected a conversion fail loop via subject ($subject)");
      exit 0;
   }
}

my $date = $parsed->header('Date');
my $body;
my $format;
my $headers;
my $url;

my @cc_emails = ();
if (!$options{'no-ccs'}) {
   my $cc_raw    = $parsed->header('Cc');
   if (defined $cc_raw) {
      my @ccs       = Email::Address->parse($cc_raw);
      logmsg("Cc header = $cc_raw", 2);
      foreach my $cc (@ccs) {
          my $domain_regex = qr/\@$email_domain$/ixms;
          next if $cc =~ $domain_regex; # skip my own addresses
          logmsg('Adding ' . $cc->address . ' to the list of recipients per the Cc: header', 2);
          push @cc_emails, $cc->address;
      }
   }
}

my @parts       = get_message_parts($parsed);
my $parts_count = scalar(@parts);
logmsg("Message now has $parts_count part" . ($parts_count == 1 ? '' : 's'), 2);

my $attachment_file;
my @attachment_files;
my @inline_images;
my @append_images;
my @merge_pdfs;
my $tempdir = tempdir(DIR => $tmpdir);
my $html_tempfile = File::Temp->new(DIR => $tempdir, SUFFIX => '.html')
   or croak $OS_ERROR;
my $encoding = 'utf-8';

if ($options{'convert-attachment'} && !$attachments_enabled) {
         exit 1;
}

$html_tempfile->unlink_on_destroy(0);
push @created_files, $html_tempfile->filename;

# Look for attachments if that is our mission
foreach my $part (@parts) {
   if (defined $part->filename && $part->filename ne '') {
      if ($options{'convert-attachment'}) {
         $format = 'attachment';
         $body   = '';
      }

      # Skip any image parts if told to
      next if ($part->header('Content-Type') =~ m~image/~ixms && $options{'skip-images'});

      my $suffix;
      if ($part->filename =~ /(\.[^\.]+)$/xms) {
         $suffix = $1;
         $suffix =~ s/[^\w]$//xms;
         $suffix =~ tr/A-Z/a-z/;

         # Don't try to process signature, rar or zip attachments...
         if ($suffix =~ /^\.(p7s|rar|zip)$/ixms) {
            undef $format;
            next;
         }
         # for .eml attachments, process as a regular html conversion
         elsif ($suffix =~ /^\.eml$/ixms && $options{'convert-attachment'}) {
            $format = 'eml';
         }
         # PDF can be unconverted using pdftotext/pdftoword/pdftohtml
         elsif ($suffix =~ /^\.pdf$/ixms && $options{'convert-attachment'}) {
            if ($options{'pdf-to-text'}) {
               $format = 'attachment-pdftext';
            }
            elsif ($options{'pdf-to-word'}) {
               $format = 'attachment-pdfword';
            }
            elsif ($options{'pdf-to-html'}) {
               $format = 'attachment-pdfhtml';
            }
            elsif ($options{'pdf-to-zip'}) {
               $format = 'attachment-pdfzip';
            }
            elsif ($options{'pdf-to-png'}) {
               $format = 'attachment-pdfpng';
            }
         }
      }
      if (defined $suffix) {
         $attachment_file = File::Temp->new(
            TEMPLATE => 'pdfconvertme_attachment.XXXXXX',
            DIR      => $tempdir,
            SUFFIX   => $suffix
         ) or croak $OS_ERROR;
         $attachment_file->unlink_on_destroy(0);
         push @created_files, $attachment_file->filename;
         my $attach_fh;
         if (!open($attach_fh, '>', $attachment_file)) {
            logmsg("Unable to write to '$attachment_file': $OS_ERROR");
            exit 1;
         }
         print {$attach_fh} $part->body;
         close($attach_fh);

         if (!$options{'convert-attachment'} && $part->header('Content-Type') !~ m~(text|image)/~ixms) {
            logmsg("Found attachment $attachment_file, adding to queue", 2);
            push @attachment_files, $attachment_file;
         }
      }
      last if $options{'convert-attachment'};
   }
}

if (!$options{'convert-attachment'} ||
    !$options{'pdf-to-text'} ||
    !$options{'pdf-to-word'} ||
    !$options{'pdf-to-html'} ||
    !$options{'pdf-to-zip'} ||
    !$options{'pdf-to-png'} ||
    !defined $format ||
    $format eq 'eml') {
   # Special handling for .eml attachments
   if (defined $format && $format eq 'eml') {
      $options{'convert-attachment'} = 0;
      undef $body;

      logmsg("Found .eml attachment $attachment_file, re-parsing", 2);
      $format = 'html';

      # (Re-)parse the message
      {
         local $INPUT_RECORD_SEPARATOR = undef;
         $text = read_file($attachment_file);
      }
      $parsed = Email::MIME->new($text);
      @parts  = get_message_parts($parsed);

      $from    = $parsed->header('From');
      $to      = $parsed->header('To');
      $date    = $parsed->header('Date');
      $subject = $parsed->header('Subject');
   }

   # Look for HTML parts first
   foreach my $part (@parts) {
      if ($part->content_type =~ m~^text/html~xms &&
          !defined $body &&
          !$options{'pdf-to-text'} &&
          !$options{'pdf-to-word'} &&
          !$options{'pdf-to-html'} &&
          !$options{'pdf-to-zip'} &&
          !$options{'pdf-to-png'}
         ) {
         logmsg("Found an HTML body", 2);
         $body   = $part->body;
         $format = 'html';
         if ($part->content_type =~ m~charset="?(\S+)"?~xms) {
            $encoding = $1;
         }
         # RFC 2045 forbids = as last character, remove it
         if ($part->header('Content-Transfer-Encoding') eq 'quoted-printable') {
            $body =~ s/=$//;
         }
      }
      elsif ($part->content_type =~ m~image/(\S+)~xms && !$options{'skip-images'}) {
         my $image_extension = $1;
         my $cid             = $part->header('Content-ID') || basename($part->filename);
         my $image_filename  = sha256_hex($cid) . '.' . $image_extension;
         logmsg("Found an image attachment (". $part->content_type . ")", 2);

         my %inline_image;
         $inline_image{'cid'}      = $cid;
         $inline_image{'filename'} = $image_filename;
         if (!defined $part->header('Content-ID')) {
            logmsg("Found an image to append:" . $inline_image{'filename'}, 2);
            push @append_images, \%inline_image;
         }
         else {
            logmsg("Found an inline image: cid:" . $inline_image{'cid'} . ' / ' . $inline_image{'filename'}, 2);
            push @inline_images, \%inline_image;
         }
         my $img_fh;
         my $destfile = sprintf("%s/%s", $tempdir, $inline_image{'filename'});
         open($img_fh, '>', $destfile) or croak "$OS_ERROR";
         print {$img_fh} $part->body;
         close($img_fh);
      }
   }


   # Fallback to plain text if no HTML or if we are in force-url mode (where we prefer plain text)
   if (($options{'force-url'} ||
        $options{'force-rss-url'} ||
        $options{'force-content-url'} ||
        !defined $body
       ) &&
       !$options{'pdf-to-text'} &&
       !$options{'pdf-to-word'} &&
       !$options{'pdf-to-html'} &&
       !$options{'pdf-to-zip'} &&
       !$options{'pdf-to-png'}
      ) {
      foreach my $part (@parts) {
         if ($part->content_type =~ m~^text/plain~xms) {
            $body = $part->body;
            if ($part->content_type =~ m~charset="?(\S+)"?~xms) {
               $encoding = $1;
            }

            # Check if this is lazy HTML mail
            if ($body =~ /<html>/ixms) {
               $format = 'html';
            }
            elsif (($options{'force-url'} ||
                    $options{'force-rss-url'} ||
                    $options{'force-content-url'}
                   ) && $body =~ m~\s*(https?://\S+)\s*~ixms) {
               ($url, $format, $body) = handle_url($1);
            }
            else {
               if ($options{'force-markdown'}) {
                  $format = 'markdown';
               }
               else {
                  $format = 'plain2html';
               }
            }

            last;
         }
      }
   }
}

$encoding =~ tr/A-Z/a-z/;
$encoding =~ s/"$//xms;

if ($format eq 'url') {
   if ($url =~ /\.(png|jpg|gif|jpeg)$/igxms) {
      logmsg("Converting raw image URL request to be wrapped in HTML body", 2);
      $format = 'html';
      $options{'no-headers'} = 1;
      $body = '<html><body><img src="' . $url . '"></body></html>';
   }
}

# If it's a URL convert request and the body is empty, check for a URL in the
# subject
if ($body =~ /^\s*$/xms &&
    ($options{'force-url'} ||
      $options{'force-rss-url'} ||
      $options{'force-content-url'}
     ) && $subject =~ m~\s*(https?://\S+)\s*~ixms) {
  ($url, $format, $body) = handle_url($1);
}

logmsg("Format=$format,Encoding=$encoding", 2);
if (!defined $format) {
  logmsg( "Unable to determine format of email, giving up!");
  exit 1;
}


if ($encoding eq 'us-ascii') {
   # US-ASCII overlaps with UTF-8
   $encoding = 'utf-8';
}

if ($encoding ne 'utf-8') {
   logmsg("Converting body from $encoding to utf-8", 2);
   $body = convert_to_utf8($body, $encoding);
}

# If we got a plaintext message, pretty it up by HTML-ifying it
if ($format eq 'plain2html') {
   if (defined $options{'translate'}) {
      $body = translate_body($body, $options{'translate'});
   }
   $body = convert_plain_to_html($body, $encoding);
   $format = 'html';
}

if ($format eq 'markdown') {
   $body   = markdown($body);
   $format = 'html';
}

if (defined $format && $format eq 'html' && scalar(@inline_images) > 0) {
   logmsg("Replacing inline images with real paths...", 2);
   my $max_images  = 100;
   my $image_count = 0;
   while ($body =~ m/src\s*=\s*"?cid:([^"\s]+)\s*"?/ixms) {
      my $cid = $1;
      last if $image_count++ > $max_images;
      foreach my $inline_image (@inline_images) {
      my $file = $inline_image->{'filename'};
         if (grep { /$cid/xms } $inline_image->{'cid'}) {
            logmsg("Replacing cid:$cid with $file", 2);
            $body =~ s/cid:$cid/$file/ixms;
         }
      }
   }

   # If we didn't find any images just use them as appends
   if ($image_count == 0) {
      logmsg("Didn't find any inline images, using them as appends instead", 2);
      push @append_images, @inline_images;
   }
}

if (defined $format && $format eq 'html' && scalar(@append_images) > 0) {
   logmsg("Appending attached images...", 2);
   foreach my $append_image (@append_images) {
      my $file = $append_image->{'filename'};
      logmsg("Appending image file $file to body", 2);
      $body .= '<img src="' . $file . '"><p>';
   }
}

if ($format eq 'text') {
   $headers =<<EOF_EOF;
From: $from_raw_orig
To: $to
Subject: $subject
Date: $date

EOF_EOF
}
elsif ($format eq 'html' || $format eq 'url' || $format =~ /^attachment/xms) {
   my $align = 'valign="top" align="left"';
   $headers = '<p><table>';
   if ($options{'all-headers'}) {
      my @headers = $parsed->headers;
      foreach my $header (@headers) {
         my @values = $parsed->header($header);
         foreach my $value (@values) {
            $headers .= "<tr><th $align>$header:</th><td $align>"
              . encode_entities($value)
              . "</td></tr>";
         }
      }
   }
   else {
      $headers .=
         "<tr><th $align>From:</th><td $align>"
        . encode_entities($from_raw_orig)
        . "</td></tr>";
      $headers .=
         "<tr><th $align>To:</th><td $align>" . encode_entities($to) . "</td></tr>";
      $headers .=
          "<tr><th $align>Subject:</th><td $align>"
        . encode_entities($subject)
        . "</td></tr>";
      $headers .=
          "<tr><th $align>Date:</th><td $align>"
        . encode_entities($date)
        . "</td></tr>";
   }
   $headers .= '</table>';
   $headers .= '</p>';
   $headers .= '<hr>';
}
else {
   logmsg("Unknown format '$format', giving up!");
   exit 1;
}

if ($options{'no-headers'}) {
   $headers = '';
}

my $message        = $headers . $body;
my @converter_args = ();

if ($format eq 'url') {
   push @converter_args, $url;
   my @args = ();
   if ($options{'no-javascript'}) {
      push @args, '-n';
   }
   push @args, '--load-error-handling ignore';
   push @args, '-s ' . $options{'papersize'} if defined $options{'papersize'};
   push @args, '-O ' . $orientation;
   push @converter_args, join(' ', @args);
}
elsif ($format =~ /^attachment/xms && defined $attachment_file && $options{'convert-attachment'}) {
   push @converter_args, $attachment_file;
}
else {
   $format = 'html' if $format =~ /^attachment/xms;
   push @converter_args, $subject;
   push @converter_args, $options{'papersize'};
   push @converter_args, $orientation;
}

if ($format eq 'html' && (@inline_images > 0 || @append_images > 0)) {
   print {$html_tempfile} $headers;
   print {$html_tempfile} $body;
   close($html_tempfile);
   push @converter_args, $html_tempfile;
}

logmsg('Sending to converter...', 2);
my $pdf_filename = convert_to_pdf($message, $format, $tempdir, @converter_args);
chomp $pdf_filename;

# Get all attachments converted to PDF next and append to @merge_pdfs
foreach my $temp_attachment (@attachment_files) {
   logmsg("Converting $temp_attachment to PDF...", 2);
   my $temp_pdf = convert_to_pdf($message, 'attachment', $tempdir, $temp_attachment);
   if (-s $temp_pdf) {
      logmsg("Successful, appending $temp_pdf to \@merge_pdfs...", 2);
      push @merge_pdfs, $temp_pdf;
   }
}

$failed = 1;
if (-s $pdf_filename) {
   if (@merge_pdfs > 0) {
      my $new_pdf_filename = convert_to_pdf($message, 'merge', $tempdir, $pdf_filename, @merge_pdfs);
      if (-s $new_pdf_filename) {
         $failed = 0;
         logmsg("PDF merge successful. Making $pdf_filename $new_pdf_filename", 2);
         $pdf_filename = $new_pdf_filename;
      }
   }
   else {
      $failed = 0;
   }

   my $response_subject_prefix = 'Converted: ';
   if ($options{'no-subject-prefix'}) {
      $response_subject_prefix = '';
   }

   if (-f $blurb_file && $options{'blurb-include-orig'} &&
       defined $body && $body ne '') {
      my $blurb_content = read_file($blurb_file);
      my $orig_body_plaintext = HTML::FormatText->format_string(
                                  $body,
                                  leftmargin => 0, rightmargin => 50
                                );
      $blurb_content .= "\n----- Body of conversion request below -----\n";
      $blurb_content .= $orig_body_plaintext;
      my $new_blurb_fh;
      open($new_blurb_fh, '>', $blurb_file_new) or croak $OS_ERROR;
      print {$new_blurb_fh} $blurb_content . "\n";
      close($new_blurb_fh);
      $blurb_file = $blurb_file_new->filename;
   }

   if ($email_result) {
      my $recipients = join(',', $from_addr, @cc_emails);
      my @args = ('-s', "${response_subject_prefix}${subject}",
                  '-a', $pdf_filename,
                  '-t', $recipients,
                  '-b', $blurb_file);
      if ($options{'force-from'}) {
         push @args, ('-f', $options{'force-from'});
      }
      if ($options{'force-reply-to'}) {
         push @args, ('-r', $options{'force-reply-to'});
      }
      if ($options{'strip-subject-tags'}) {
         push @args, ('-T');
      }

      logmsg("Sending attachment with: $mail_attachment_cmd " . join(' ', @args));
      my $rc = system $mail_attachment_cmd, @args;

      if ($rc == -1) {
         logmsg("failed to execute: $OS_ERROR");
         exit 1;
      }
      elsif ($rc & 127) {
         logmsg(sprintf "child died with signal %d, %s coredump", ($rc & 127),  ($rc & 128) ? 'with' : 'without');
         exit 1;
      }
      else {
         logmsg(sprintf("child exited with value %d", $rc >> 8), 2);
      }
   }

   # Remove the file
   logmsg("Removing email input file $email_input_tmp", 2);
   unlink $email_input_tmp;

}
else {
   $failed = 1;

   logmsg("Error: conversion failed ($pdf_filename).");
   unlink $email_input_tmp;
   unlink $pdf_filename;
   rmtree([$tempdir]);
   exit 1;
}

# Don't remove resulting PDF if we are in no-email mode
if (!$email_result) {
   print "PDF stored as: $pdf_filename\n";
   exit 0;
}

# Other cleanup
unlink $email_input_tmp;
unlink $pdf_filename;

END {
   if (!$failed) {
      if (defined $email_input_tmp && -f $email_input_tmp->filename) {
         logmsg("Removing email input file " . $email_input_tmp->filename, 2);
         unlink $email_input_tmp->filename;
      }
      if (defined $attachment_file && -f $attachment_file->filename) {
         logmsg("Removing attachment file" . $attachment_file->filename, 2);
         unlink $attachment_file->filename;
      }
      if (defined $tempdir && -d $tempdir) {
         # Remove the temporary directory for inline stuff
         rmtree([$tempdir]);
      }

      # Delete any remaining created files
      foreach my $created_file (@created_files) {
         if (-f $created_file) {
            unlink $created_file;
         }
      }
   }

   logmsg("Ending pdconvert.");
   close($log_fh);
}
