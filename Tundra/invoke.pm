package Tundra::Invoke;
use strict;
use parent qw(Exporter);

# Symbols to export from this module
#
our @EXPORT = qw(invoke_ffmpeg);

=head1 NAME

Tundra::Invoke - Perl interface for invoking ffmpeg.

=head1 SYNOPSIS

  use Tundra::Invoke;
  
  invoke_ffmpeg('-i', 'input.MOV', 'output.mp4') or
    die "ffmpeg invocation failed, stopped";

=head1 DESCRIPTION

The C<Tundra::Invoke> module allows FFMPEG to be used as if it were a
Perl function.  Use the exported C<invoke_ffmpeg> function, passing a
variable number of arguments that will be passed as command-line
parameters to FFMPEG.  (This argument list does not include the arg0
name of the program to invoke.)

The call to the function will be implemented by creating an FFMPEG
process, waiting for it to run, and returning a value that evaluates to
true if everything worked or false if invocation failed or FFMPEG
returned an error status.  Standard I/O streams will be shared with the
FFMPEG process, so the process will write its messages to the same
location as the calling program.

You must set the appropriate path to the FFMPEG program on this specific
system in the variable given below in this script's source file, but
only if C<ffmpeg> is not installed in one of the system's PATH
directories.

=cut

# The path to the ffmpeg program on this system, or "ffmpeg" if the
# program is installed in one of the system's PATH directories.
#
my $FFMPEG_PATH = 'ffmpeg';

# The Perl function wrapper around ffmpeg.
#
sub invoke_ffmpeg {
  
  # Call through to ffmpeg
  my $retval = system($FFMPEG_PATH, @_);
  
  # Invert return value
  if ($retval == 0) {
    $retval = 1;
  } else {
    $retval = 0;
  }
  
  # Return inverted return value
  return $retval;
}

=head1 AUTHOR

Noah Johnson, C<noah.johnson@loupmail.com>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2021 Multimedia Data Technology Inc.

MIT License:

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files
(the "Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be included
in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=cut

# Module ends with expression that evaluates to true
#
1;
