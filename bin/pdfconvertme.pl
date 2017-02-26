#!/usr/bin/perl

# License:
# The MIT License (MIT)
#
# Copyright (c) 2013-2014 Brian Almeida <bma@thunderkeys.net>
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
my $attachments_enabled = 1;
my $converter_threshold = 2;
my $prevent_mail_loops  = 1;
my $loop_domain         = 'yourdomainhere.com';
my $max_per_hour        = 30;
my $email_result        = 0;                                   ### CHANGE ME ###
my $email_domain        = 'yourdomainhere.com';
my $mail_attachment_cmd = '/usr/local/bin/mail_attachment.sh';
my $blurb_file          = '/usr/local/etc/pdfconvertme.blurb';
my $blurb_file_new      = undef;
my $tmpdir              = '/var/tmp';
my $failed              = 0;
my %options;
my %opts = (
   'force-url'          => \$options{'force-url'},
   'force-rss-url'      => \$options{'force-rss-url'},
   'force-content-url'  => \$options{'force-content-url'},
   'force-markdown'     => \$options{'force-markdown'},
   'no-javascript'      => \$options{'no-javascript'},
   'no-headers'         => \$options{'no-headers'},
   'no-subject-prefix'  => \$options{'no-subject-prefix'},
   'blurb-file=s'       => \$options{'blurb-file'},
   'convert-attachment' => \$options{'convert-attachment'},
   'papersize=s'        => \$options{'papersize'},
   'pdf-to-text'        => \$options{'pdf-to-text'},
   'pdf-to-word'        => \$options{'pdf-to-word'},
   'force-from=s'       => \$options{'force-from'},
   'blurb-include-orig' => \$options{'blurb-include-orig'},
   'debug'              => \$options{'debug'},
);
my %converters = (
   'attachment-pdftext' => '/usr/local/bin/pdf2text.sh',
   'attachment-pdfword' => '/usr/local/bin/pdf2word.sh',
   'attachment'         => '/usr/local/bin/attachment2pdf.sh',
   'text'               => '/usr/local/bin/text2pdf.sh',
   'html'               => '/usr/local/bin/html2pdf.sh',
   'url'                => '/usr/local/bin/url2pdf.sh',
);
my @papersizes = qw(
   A0 A1 A2 A3 A4 A5 A6 A7 A8 A9
   B0 B1 B2 B3 B4 B5 B6 B7 B8 B9
   B10 C5E Comm10E DLE Executive Folio
   Ledger Legal Letter Tabloid
);
my $default_papersize   = 'A4';

# ---------------------------------------------------
sub logmsg {
   my ($msg) = @_;

   my $ts = strftime("%Y-%m-%d %H:%M:%S", localtime());

   if ($options{'debug'}) {
      print STDERR "$ts [$$] $msg\n";
   }

   return;
}

sub convert_to_pdf {
   my ($message, $format, @converter_args) = @_;
   my $suffix;
   if ($format eq 'attachment-pdftext') {
      $suffix = '.txt';
   }
   elsif ($format eq 'attachment-pdfword') {
      $suffix = '.docx';
   }
   else {
       $suffix = '.pdf';
   }
   my $pdf_tempfile = File::Temp->new(
      TEMPLATE => 'pdfconvertme.XXXXXX',
      DIR      => $tmpdir,
      SUFFIX   => $suffix,
   ) or croak $OS_ERROR;
   $pdf_tempfile->unlink_on_destroy(0);
   my $fh;

   my $converter = $converters{$format};
   if (!defined $converter) {
      croak 'Undefined format ' . $format . '!';
   }

   local $SIG{'PIPE'} = 'IGNORE';
   if (open($fh, '|-', $converter, $pdf_tempfile, @converter_args)) {
      print {$fh} $message;
      close($fh) or carp "Unable to close converter: $CHILD_ERROR";
   }
   else {
      logmsg("Failed to spawn converter '|$converter $pdf_tempfile "
           . join(' ', @converter_args)
           . "'");
      unlink $pdf_tempfile;
      $pdf_tempfile = '';
   }

   return $pdf_tempfile;
}

sub unpack_multipart {
   my ($in_part, $depth) = @_;
   my @unpacked_parts;

   if ($depth > 20) {
      croak 'Too deep of recursion on multiparts, giving up.';
   }

   foreach my $part ($in_part->parts) {
      if ($part->content_type =~ m~^multipart/~xms) {
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

   foreach my $part (@parts) {
      if ($part->content_type =~ m~^multipart/~xms) {
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
      logmsg("Original encoding conversion failed, trying with iconv -c...");
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

   # encode any special html characters
   $url     = encode_entities($url);

   # attempt to unshorten it
   my $url_new = LWP::UserAgent->new->get($url)->request->uri;
   if (defined $url_new && $url_new ne '' && $url ne $url_new) {
     logmsg("URL translated/unshortened from $url to $url_new");
     $url = $url_new;
   }

   return $url;
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

# -------------------------- main ----------------------

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

if (!GetOptions(%opts)) {
   croak "Failed to parse options: $OS_ERROR";
}

if ($options{'papersize'}) {
   if ( ! grep { lc $_ eq lc $options{'papersize'} } @papersizes) {
      $options{'papersize'} = $default_papersize;
   }
}
else {
   $options{'papersize'} = $default_papersize;
}

if ($options{'force-rss-url'} || $options{'force-content-url'}) {
   $options{'no-headers'} = 1;
}

if ($options{'force-markdown'}) {
   $options{'no-headers'} = 1;
}

if ($options{'blurb-file'} && -f $options{'blurb-file'}) {
   $blurb_file = $options{'blurb-file'};
}

my $email_input_tmp = File::Temp->new(
   TEMPLATE => 'pdfconvertme.XXXXXX',
   DIR      => $tmpdir,
   SUFFIX   => '.msg'
) or croak $OS_ERROR;
# Don't unlink the file when we go out of scope
$email_input_tmp->unlink_on_destroy(0);

if (!$email_input_tmp) {
   croak "Unable to create tempfile for storing email: $OS_ERROR";
}

# Read in email soure message and save to disk
while (my $line = <>) {
   print {$email_input_tmp} $line;
}
if (!close($email_input_tmp)) {
   logmsg("Unable to close() on $email_input_tmp: $OS_ERROR");
}

# Parse the message
my $text;
{
   local $INPUT_RECORD_SEPARATOR = undef;
   $text = read_file($email_input_tmp->filename);
}

my $parsed = Email::MIME->new($text);
if (!$parsed) {
   croak "ERROR: Message failed to parse. Error: $OS_ERROR";
}

my $from      = $parsed->header('From');
my $from_orig = $from;
if (!defined $from) {
   croak "ERROR: No 'From:' header, aborting!";
}

foreach my $alt_header (qw(X-Forwarded-For Reply-To Resent-From)) {
   my $alternate_from = $parsed->header($alt_header);
   if (defined $alternate_from && $alternate_from !~ /^\s*$/xms && $alternate_from !~ /^(?:donot|no)reply\@/xms) {
      $from = $alternate_from;
      last;
   }
}

if ($from =~ /^(?:donot|no)reply\@/xms) {
   exit 0;
}

my $subject   = $parsed->header('Subject');
my @froms     = Email::Address->parse($from);
my $from_addr = $froms[0]->address;

if (!defined $from_addr) {
   croak "Unable to determine a valid from address from '$from', aborting!";
}

if ($prevent_mail_loops) {
   my $in_reply_to       = $parsed->header('In-Reply-To');
   my $loop_domain_regex = qr{$loop_domain}xms;
   if (defined $in_reply_to && $in_reply_to =~ /$loop_domain_regex/xms) {
      croak
        "Detected a mail loop via header 'In-Reply-To: $in_reply_to', aborting!";
   }
}

my $to   = $parsed->header('To');
my $date = $parsed->header('Date');
my $body;
my $format;
my $headers;
my $url;

my $cc_raw    = $parsed->header('Cc');
my @cc_emails = ();
if (defined $cc_raw) {
    my @ccs       = Email::Address->parse($cc_raw);
    logmsg("Cc header = $cc_raw");
    foreach my $cc (@ccs) {
        my $domain_regex = qr/\@$email_domain$/ixms;
        next if $cc =~ $domain_regex; # skip my own addresses
        push @cc_emails, $cc->address;
    }
}

my @parts       = get_message_parts($parsed);
my $parts_count = scalar(@parts);

my $attachment_file;
my @inline_images;
my @append_images;
my $tempdir = tempdir(DIR => $tmpdir);
my $html_tempfile = File::Temp->new(DIR => $tempdir, SUFFIX => '.html')
   or croak $OS_ERROR;
my $encoding = 'utf-8';

if ($options{'convert-attachment'} && !$attachments_enabled) {
   croak 'Attachment conversion is disabled';
}
if ($options{'blurb-include-orig'}) {
   $blurb_file_new = File::Temp->new(
      TEMPLATE => 'pdfconvertme.XXXXXX',
      DIR      => $tmpdir,
      SUFFIX   => '.blurb',
   ) or croak $OS_ERROR;
}

$html_tempfile->unlink_on_destroy(0);

# Look for attachments if that is our mission
if ($options{'convert-attachment'}) {
   foreach my $part (@parts) {
      if (defined $part->filename && $part->filename ne '') {
         $format = 'attachment';
         $body   = '';
         my $suffix;
         if ($part->filename =~ /(\.[^\.]+)$/xms) {
            $suffix = $1;

            # Don't try to process signature, rar or zip attachments...
            if ($suffix =~ /^\.(p7s|rar|zip)$/ixms) {
               undef $format;
               next;
            }
            # for .eml attachments, process as a regular html conversion
            elsif ($suffix =~ /^\.eml$/ixms) {
               $format = 'eml';
            }
            # PDF can be unconverted using pdftotext/pdftoword
            elsif ($suffix =~ /^\.pdf$/ixms) {
               if ($options{'pdf-to-text'}) {
                  $format = 'attachment-pdftext';
               }
               elsif ($options{'pdf-to-word'}) {
                  $format = 'attachment-pdfword';
               }
            }
         }
         if (defined $suffix) {
            $attachment_file = File::Temp->new(
               TEMPLATE => 'pdfconvertme_attachment.XXXXXX',
               DIR      => $tmpdir,
               SUFFIX   => $suffix
            ) or croak $OS_ERROR;
            $attachment_file->unlink_on_destroy(0);
            my $attach_fh;
            if (!open($attach_fh, '>', $attachment_file)) {
               croak "Unable to write to '$attachment_file': $OS_ERROR";
            }
            print {$attach_fh} $part->body;
            close($attach_fh) or carp 'Unable to close attachment filehandle';
         }
         last;
      }
   }
}

if (!$options{'convert-attachment'} ||
    !$options{'pdf-to-text'} ||
    !$options{'pdf-to-word'} ||
    !defined $format ||
    $format eq 'eml') {
   # Special handling for .eml attachments
   if (defined $format && $format eq 'eml') {
      $options{'convert-attachment'} = 0;
      undef $body;

      $format = 'html';

      # (Re-)parse the message
      {
         local $INPUT_RECORD_SEPARATOR = undef;
         $text = read_file($attachment_file);
      }
      unlink $attachment_file;
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
          !$options{'pdf-to-word'}
         ) {
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
      elsif ($part->content_type =~ m~image/(\S+)~xms) {
         my $image_extension = $1;
         my $cid             = $part->header('Content-ID') || basename($part->filename);
         my $image_filename  = sha256_hex($cid) . '.' . $image_extension;

         my %inline_image;
         $inline_image{'cid'}      = $cid;
         $inline_image{'filename'} = $image_filename;
         if (!defined $part->header('Content-ID')) {
            push @append_images, \%inline_image;
         }
         else {
            push @inline_images, \%inline_image;
         }
         my $img_fh;
         my $destfile = sprintf("%s/%s", $tempdir, $inline_image{'filename'});
         open($img_fh, '>', $destfile) or croak "$OS_ERROR";
         print {$img_fh} $part->body;
         close($img_fh) or carp 'Unable to close file handle';
      }
   }

   if (defined $format && $format eq 'html' && scalar(@inline_images) > 0) {
      my $max_images  = 100;
      my $image_count = 0;
      while ($body =~ m/src\s*=\s*"?cid:([^"\s]+)\s*"?/ixms) {
         my $cid = $1;
         last if $image_count++ > $max_images;
         foreach my $inline_image (@inline_images) {
            my $file = $inline_image->{'filename'};
            if (grep { /$cid/xms } $inline_image->{'cid'}) {
               $body =~ s/cid:$cid/$file/ixms;
            }
         }
      }
   }

   # Fallback to plain text if no HTML or if we are in force-url mode (where we prefer plain text)
   if (($options{'force-url'} ||
        $options{'force-rss-url'} ||
        $options{'force-content-url'} ||
        !defined $body
       ) &&
       !$options{'pdf-to-text'} &&
       !$options{'pdf-to-word'}
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

if (!defined $format) {
   croak "Unable to determine format of email, giving up!";
}

if ($encoding ne 'utf-8') {
   $body = convert_to_utf8($body, $encoding);
}

# If we got a plaintext message, pretty it up by HTML-ifying it
if ($format eq 'plain2html') {
   $body = convert_plain_to_html($body, $encoding);
   $format = 'html';
}

if ($format eq 'markdown') {
   $body   = markdown($body);
   $format = 'html';
}

if (defined $format && $format eq 'html' && scalar(@append_images) > 0) {
   foreach my $append_image (@append_images) {
      my $file = $append_image->{'filename'};
      $body .= '<img src="' . $file . '"><p>';
   }
}

if ($format eq 'text') {
   $headers =<<"EOF_EOF";
From: $from_orig
To: $to
Subject: $subject
Date: $date

EOF_EOF
}
elsif ($format eq 'html' || $format eq 'url' || $format =~ /^attachment/xms) {
   my $align = 'valign="top" align="left"';
   $headers = '<p><table>';
   $headers .=
       "<tr><th $align>From:</th><td $align>"
     . encode_entities($from)
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
   $headers .= '</table>';
   $headers .= '</p>';
   $headers .= '<hr>';
}
else {
   croak "Unknown format '$format', giving up!";
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
   push @converter_args, join(' ', @args);
}
elsif ($format =~ /^attachment/xms && defined $attachment_file) {
   push @converter_args, $attachment_file;
}
else {
   $format = 'html' if $format =~ /^attachment/xms;
   push @converter_args, $subject;
   push @converter_args, $options{'papersize'};
}

if ($format eq 'html' && (@inline_images > 0 || @append_images > 0)) {
   print {$html_tempfile} $headers;
   print {$html_tempfile} $body;
   close($html_tempfile) or carp 'Unable to close filehandle';
   push @converter_args, $html_tempfile;
}

my $pdf_filename = convert_to_pdf($message, $format, @converter_args);
chomp $pdf_filename;

if (-s $pdf_filename) {
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
      my $rc = system $mail_attachment_cmd, @args;
      if ($rc == -1) {
         croak "failed to execute: $OS_ERROR";
      }
      elsif ($rc & 127) {
         croak sprintf "child died with signal %d, %s coredump", ($rc & 127),
           ($rc & 128) ? 'with' : 'without';
      }
   }

   # Remove attachment file if it existed
   if (defined $attachment_file && -f $attachment_file) {
      unlink $attachment_file;
   }
}
else {
   $failed = 1;

   unlink $email_input_tmp;
   unlink $pdf_filename;
   rmtree([$tempdir]);
   croak 'Error: conversion failed';
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
         unlink $email_input_tmp->filename;
      }
      if (defined $attachment_file && -f $attachment_file->filename) {
         unlink $attachment_file->filename;
      }
      if (defined $tempdir && -d $tempdir) {

         # Remove the temporary directory for inline stuff
         rmtree([$tempdir]);
      }
   }
}
