#!/usr/bin/python

# License:
# The MIT License (MIT)
#
# Copyright (c) 2013-2017 Brian Almeida <bma@thunderkeys.net>
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

# Modules
import tempfile
import hashlib
import shutil
import email
import sys
import cgi
import re
import os
from subprocess import call

# Globals
debug           = True
papersize       = 'A4'
wkhtmltopdf_bin = '/usr/local/bin/wkhtmltopdf'
tmpdir          = '/var/tmp'

# Process input file(s)
input_files=[]
for arg in sys.argv[1:]:
  # if it's a directory, process all files in the directory that match .eml
  if os.path.isdir(arg):
    for filename in os.listdir(arg):
      if filename.endswith(".eml"):
        input_files.append(os.path.join(arg, filename))
  else:
    if os.path.isfile(arg):
      input_files.append(arg)

for input_filename in input_files:
  if debug:
    print("Processing file: %s" % input_filename)
  i = open(input_filename, 'r+b')
  if not i:
    print("Unable to open input file '%s', skipping." % input_filename)
    continue

  data = i.read()
  i.close()

  # Create an output directory
  temp_output_dir = tempfile.mkdtemp(prefix='pdfconvert.', dir=tmpdir)
  if not temp_output_dir:
    print("Unable to create temporary directory - skipping this file.")
    continue
  
  # Parse the message
  msg = email.message_from_string(data)
  
  body=''
  inline_images=[]
  append_images=[]
  for part in msg.walk():
    content_type = part.get_content_type()
    filename     = part.get_filename()
    content_id   = part.get('Content-ID')
    content_enc  = part.get('Content-Transfer-Encoding')
  
    # Always use an HTML body if there is one
    if content_type == 'text/html':
      body = part.get_payload(decode=True)
    # If there is a plaintext body and we haven't found an HTML specific body,
    # use that, but escape it and wrap it in <pre>
    elif content_type == 'text/plain' and body == '':
      body      = '<pre>' + cgi.escape(part.get_payload(decode=True)) + '</pre>'
    # Handle image attachments (inline or otherwise)
    else:
      m = re.match('^image/(\S+)', content_type)
      if m:
        image_extension = m.group(1)
        if content_id == None:
          content_id = filename 
        filename_hash = hashlib.sha256(content_id).hexdigest() + '.' + image_extension
  
        image_entry = { 'cid': content_id, 'filename': filename_hash }
        if part.get('Content-Id'):
           inline_images.append(image_entry)
        else:
           append_images.append(image_entry)
        
        # Write out the attached image
        f = open(temp_output_dir + '/' + filename_hash, 'w')
        if f:
          f.write(part.get_payload(decode=True))
          f.close()
  
  # Setup headers
  headers = '<p><table>'
  headers += "<tr><th valign='top' align='left'>From:</th><td valign='top' align='left'>" + cgi.escape(msg['from']) + "</td></tr>"
  headers += "<tr><th valign='top' align='left'>To:</th><td valign='top' align='left'>" + cgi.escape(msg['to']) + "</td></tr>"
  headers += "<tr><th valign='top' align='left'>Subject:</th><td valign='top' align='left'>" + cgi.escape(msg['subject']) + "</td></tr>"
  headers += "<tr><th valign='top' align='left'>Date:</th><td valign='top' align='left'>" + cgi.escape(msg['date']) + "</td></tr>"
  headers += '</table>'
  headers += '</p>'
  headers += '<hr>'
  
  # Fix inline image references
  if len(inline_images) > 0:
    pattern=re.compile(r'src\s*=\s*"?cid:([^"\s]+)\s*"?')
    for cid in re.findall(pattern, body):
      for image in inline_images:
        filename = image['filename']
        if re.search(cid, image['cid']):
          body = body.replace('cid:' + cid, filename)
  
  # Append any attached images to the end if they exist
  for image in append_images:
    body = body + '<img src="' + image['filename']  + '"><p>'
  
  # Write out the HTML file for wkthmltopdf
  html_tempfile = tempfile.NamedTemporaryFile(suffix = '.html', dir=temp_output_dir, delete=False)
  if html_tempfile:
    html_tempfile.write(headers + body)
    html_tempfile.close()
  
  # Run the PDF conversion
  pdf_output_file = tempfile.NamedTemporaryFile(suffix = '.pdf', dir=temp_output_dir, delete=False)
  call([wkhtmltopdf_bin, '-s', papersize, '--encoding', 'utf-8', '--title', msg['subject'], '-q', html_tempfile.name, pdf_output_file.name])
  
  final_output_filename=os.path.join(os.path.dirname(input_filename), os.path.basename(os.path.splitext(input_filename)[0] + '.pdf'))
  shutil.copyfile(pdf_output_file.name, final_output_filename)
  if debug:
    print("Output PDF file: %s" % final_output_filename)
  
  # Clean up temporary directory
  shutil.rmtree(temp_output_dir)
