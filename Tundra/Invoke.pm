package Tundra::Invoke;
use strict;
use parent qw(Exporter);

# Symbols to export from this module
#
our @EXPORT = qw(
                invoke_ffmpeg
                invoke_ktblank
                invoke_ktmix
                invoke_ktwav);

=head1 NAME

Tundra::Invoke - Perl interface for invoking ffmpeg and Kaltag.

=head1 SYNOPSIS

  use Tundra::Invoke;
  
  invoke_ffmpeg('-i', 'input.MOV', 'output.mp4') or
    die "ffmpeg invocation failed, stopped";
  
  invoke_ktblank($channels, $samples, 'test.ktb') or
    die "ktblank invocation failed, stopped";
  
  invoke_ktmix('src.wav', $src_i, $count, $dest_i,
                $fade_in, $fade_out, 'test.ktb') or
    die "ktmix invocation failed, stopped";
  
  invoke ktwav('test.ktb', $level, $rate, 'target.wav') or
    die "ktwav invocation failed, stopped";

=head1 DESCRIPTION

The C<Tundra::Invoke> module allows FFMPEG and Kaltag to be used as if
they were Perl functions.

For FFMPEG, use the exported C<invoke_ffmpeg> function, passing a
variable number of arguments that will be passed as command-line
parameters to FFMPEG.  (This argument list does not include the arg0
name of the program to invoke.)

For Kaltag, use the relevant functions, which have the same calling
syntax as the Kaltag programs.

The call to the functions will be implemented by creating an external
process, waiting for it to run, and returning a value that evaluates to
true if everything worked or false if invocation failed or an error
status was returned.  Standard I/O streams will be shared with the
external process, so the process will write its messages to the same
location as the calling program.

You must set the appropriate path to the FFMPEG and Kaltag programs on
this specific system in the variable given below in this script's
source file, but only if they are not installed in one of the system's
PATH directories.

=cut

# The path to the ffmpeg program on this system, or "ffmpeg" if the
# program is installed in one of the system's PATH directories.
#
my $FFMPEG_PATH = 'ffmpeg';

# The path to the Kaltag programs, or just their names if the programs
# are installed in one of the system's PATH directories.
#
my $KTBLANK_PATH = "ktblank";
my $KTMIX_PATH = "ktmix";
my $KTWAV_PATH = "ktwav";

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

# The Perl function wrapper around ktblank.
#
sub invoke_ktblank {
  
  # Make sure three parameters
  ($#_ == 2) or
    die "Wrong number of arguments, stopped";
  
  # Grab the parameters
  my $arg_ch     = shift;
  my $arg_count  = shift;
  my $arg_target = shift;
  
  # Set parameter types */
  $arg_ch     = int($arg_ch);
  $arg_count  = int($arg_count);
  $arg_target = "$arg_target";
  
  # Check parameters
  (($arg_ch == 1) or ($arg_ch == 2)) or
    die "Channel count must be one or two, stopped";
  
  ($arg_count > 0) or
    die "Sample count must be greater than zero, stopped";
  
  # Call through to ktblank
  my $retval = system($KTBLANK_PATH, $arg_ch, $arg_count, $arg_target);
  
  # Invert return value
  if ($retval == 0) {
    $retval = 1;
  } else {
    $retval = 0;
  }
  
  # Return inverted return value
  return $retval;
}

# The Perl function wrapper around ktmix.
#
sub invoke_ktmix {
  
  # Make sure seven parameters
  ($#_ == 6) or
    die "Wrong number of arguments, stopped";
  
  # Grab the parameters
  my $arg_source   = shift;
  my $arg_src_i    = shift;
  my $arg_count    = shift;
  my $arg_dest_i   = shift;
  my $arg_fade_in  = shift;
  my $arg_fade_out = shift;
  my $arg_buf      = shift;
  
  # Set parameter types */
  $arg_source   = "$arg_source";
  $arg_src_i    = int($arg_src_i);
  $arg_count    = int($arg_count);
  $arg_dest_i   = int($arg_dest_i);
  $arg_fade_in  = int($arg_fade_in);
  $arg_fade_out = int($arg_fade_out);
  $arg_buf      = "$arg_buf";
  
  # Check parameters
  ($arg_count >= 0) or
    die "Sample count must be zero or greater, stopped";
  
  (($arg_fade_in >= 0) and ($arg_fade_out >= 0)) or
    die "Fade counts must be zero or greater, stopped";
  
  ($arg_fade_in + $arg_fade_out <= $arg_count) or
    die "Fades are too long, stopped";
  
  # Call through to ktmix
  my $retval = system(
                  $KTMIX_PATH,
                  $arg_source,
                  $arg_src_i,
                  $arg_count,
                  $arg_dest_i,
                  $arg_fade_in,
                  $arg_fade_out,
                  $arg_buf);
  
  # Invert return value
  if ($retval == 0) {
    $retval = 1;
  } else {
    $retval = 0;
  }
  
  # Return inverted return value
  return $retval;
}

# The Perl function wrapper around ktwav.
#
sub invoke_ktwav {
  
  # Make sure four parameters
  ($#_ == 3) or
    die "Wrong number of arguments, stopped";
  
  # Grab the parameters
  my $arg_source = shift;
  my $arg_level  = shift;
  my $arg_rate   = shift;
  my $arg_target = shift;
  
  # Set parameter types */
  $arg_source = "$arg_source";
  $arg_level  = int($arg_level);
  $arg_rate   = int($arg_rate);
  $arg_target = "$arg_target";
  
  # Check parameters
  (($arg_level >= 0) and ($arg_level <= 32767)) or
    die "Level target is out of range, stopped";
  
  (($arg_rate >= 1024) and ($arg_rate <= 192000)) or
    die "Sample rate is out of range, stopped";
  
  # Call through to ktwav
  my $retval = system(
                $KTWAV_PATH,
                $arg_source, $arg_level, $arg_rate, $arg_target);
  
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
