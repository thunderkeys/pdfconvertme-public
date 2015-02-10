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
use HTML::FromText;
use HTML::Entities;
use File::Basename;
use Text::Markdown qw(markdown);
use Getopt::Long;
use Email::MIME;
use File::Slurp;
use Text::Iconv;
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use File::Path;
use IPC::Open2;
use English qw(-no_match_vars);
use XML::Feed;
use POSIX;
use Carp;

# Globals
my $email_result        = 0;                                   ### CHANGE ME ###
my $mail_attachment_cmd = 'mail_attachment.sh';
my $blurb_file          = '/usr/local/etc/pdfconvertme.blurb';
my $tmpdir              = '/var/tmp';
my $failed              = 0;
my %options;
my %opts = (
   'force-url'          => \$options{'force-url'},
   'force-rss-url'      => \$options{'force-rss-url'},
   'force-markdown'     => \$options{'force-markdown'},
   'no-headers'         => \$options{'no-headers'},
   'convert-attachment' => \$options{'convert-attachment'},
   'no-subject-prefix'  => \$options{'no-subject-prefix'},
   'blurb-file=s'       => \$options{'blurb-file'},
);
my %converters = (
   'attachment' => '/usr/local/bin/attachment2pdf.sh',
   'html'       => '/usr/local/bin/html2pdf.sh',
   'url'        => '/usr/local/bin/url2pdf.sh',
);

# ---------------------------------------------------
sub logmsg {
   my ($msg) = @_;

   my $ts = strftime("%Y-%m-%d %H:%M:%S", localtime());

   print "$ts [$PID] $msg\n";

   return;
}

sub convert_to_pdf {
   my ($message, $format, @converter_args) = @_;
   my $pdf_tempfile = File::Temp->new(
      TEMPLATE => 'pdfconvertme.XXXXXX',
      DIR      => $tmpdir,
      SUFFIX   => '.pdf'
   );
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
      unlink($pdf_tempfile);
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

# -------------------------- main ----------------------

if (!GetOptions(%opts)) {
   croak "Failed to parse options: $OS_ERROR";
}

if ($options{'force-rss-url'}) {
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
);
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
my $alternate_from = $parsed->header('Reply-to');
if (defined $alternate_from && $alternate_from !~ /^\s*$/xms) {
   $from = $alternate_from;
}
else {
   $alternate_from = $parsed->header('Resent-from');
   if (defined $alternate_from && $alternate_from !~ /^\s*$/xms) {
      $from = $alternate_from;
   }
}

my $subject   = $parsed->header('Subject');
my @froms     = Email::Address->parse($from);
my $from_addr = $froms[0]->address;

if (!defined $from_addr) {
   croak "Unable to determine a valid from address from '$from', aborting!";
}

my $in_reply_to = $parsed->header('In-Reply-To');
if (defined $in_reply_to && $in_reply_to !~ /^\s*$/xms) {
   croak
     "Detected a mail loop via header 'In-Reply-To: $in_reply_to', aborting!";
}

my $to   = $parsed->header('To');
my $date = $parsed->header('Date');
my $body;
my $format;
my $headers;
my $url;

my @parts       = get_message_parts($parsed);
my $parts_count = scalar(@parts);

my $attachment_file;
my @inline_images;
my @append_images;
my $tempdir = tempdir(DIR => $tmpdir);
my $html_tempfile = File::Temp->new(DIR => $tempdir, SUFFIX => '.html');
my $encoding = 'utf-8';

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
         }
         if (defined $suffix) {
            $attachment_file = File::Temp->new(
               TEMPLATE => 'pdfconvertme_attachment.XXXXXX',
               DIR      => $tmpdir,
               SUFFIX   => $suffix
            );
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

if (!$options{'convert-attachment'} || !defined $format || $format eq 'eml') {

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
      unlink($attachment_file);
      $parsed = Email::MIME->new($text);
      @parts  = get_message_parts($parsed);

      $from    = $parsed->header('From');
      $to      = $parsed->header('To');
      $date    = $parsed->header('Date');
      $subject = $parsed->header('Subject');
   }

   # Look for HTML parts first
   foreach my $part (@parts) {
      if ($part->content_type =~ m~^text/html~xms && !defined $body) {
         $body   = $part->body;
         $format = 'html';
         if ($part->content_type =~ m~charset="?(\S+)"?~xms) {
            $encoding = $1;
         }
      }
      elsif ($part->content_type =~ m~image/(\S+)~xms) {
         my $image_extension = $1;
         my $cid = $part->header('Content-ID') || basename($part->filename);
         my $image_filename = sha256_hex($cid) . '.' . $image_extension;

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
   if ($options{'force-url'} || $options{'force-rss-url'} || !defined $body) {
      foreach my $part (@parts) {
         if ($part->content_type =~ m~^text/plain~xms) {
            $body = $part->body;
            if ($part->content_type =~ m~charset="?(\S+)"?~xms) {
               $encoding = $1;
               $encoding =~ tr/A-Z/a-z/;
            }

            # Check if this is lazy HTML mail
            if ($body =~ /<html>/ixms) {
               $format = 'html';
            }
            elsif (($options{'force-url'} || $options{'force-rss-url'})
               && $body =~ m~\s*(https?://\S+)\s*~ixms)
            {
               $url = $1;

               if ($options{'force-url'}) {
                  $format = 'url';

                  # remove any extra newlines
                  $url =~ s/[\r\n]//xms;

                  # encode any special html characters
                  $url = encode_entities($url);
               }
               elsif ($options{'force-rss-url'}) {
                  $format = 'html';
                  my $feed = XML::Feed->parse(URI->new($url))
                    or die XML::Feed->errstr;
                  my $entry   = ($feed->entries)[0];
                  my $content = $entry->content;

                  $body = $content->body;
               }
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

if ($format eq 'html' || $format eq 'url' || $format eq 'attachment') {
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
}
elsif ($format eq 'attachment' && defined $attachment_file) {
   push @converter_args, $attachment_file;
}
else {
   if ($format eq 'attachment') {
      $format = 'html';
   }
   push @converter_args, $subject;
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
   my @args = (
      "${response_subject_prefix}${subject}",
      $pdf_filename, $from_addr, $blurb_file
   );

   if ($email_result) {
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
