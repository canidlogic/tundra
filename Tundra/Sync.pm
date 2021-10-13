package Tundra::Sync;
use strict;
use parent qw(Exporter);

use Fcntl 'O_RDONLY';
use Tundra::Invoke;
use File::Spec;
use Tie::File;

# Symbols to export from this module
#
our @EXPORT = qw(
                tundra_sync_build
                tundra_sync_load
                tundra_sync_src
                tundra_sync_begin
                tundra_sync_mix
                tundra_sync_end);

=head1 NAME

Tundra::Sync - Module for synchronizing audio to a created video.

=head1 SYNOPSIS

  use Tundra::Sync;
  
  # Establish the build directory
  #
  tundra_sync_build('build/dir');
  
  # Load the frame map and establish timing data
  #
  tundra_sync_load('example.map', 48000, 30000/1001);
  
  # Set the source directory for WAVE file assets
  #
  tundra_sync_src('audio/dir', 'wav');
  
  # Create a mixing buffer with two channels
  #
  tundra_sync_begin('audio.ktb', 2);
  
  # Mix in asset wave_file for video_asset in the video
  #
  tundra_sync_mix('wave_file', 'video_asset');
  
  # Normalize and mix all the audio
  #
  tundra_sync_end('result.wav', 20000);

=head1 DESCRIPTION

The C<Tundra::Sync> module allows audio files that were recorded with
original video assets to be synchronized with an edited video file.

Use the C<Tundra::Ingest> module to get all the audio assets from the
original sources.  Make sure that all have a consistent sampling rate.
All assets should either be from a corresponding video recording, or
synchronized with a video recording.

Use the C<Tundra::Film> module to build a movie along with a map file
for synchronization.

This module can then read the map file and automatically synchronize
audio assets into an audio track.  Audio fades are also synchronized
with the fades in the map.

=head1 ABSTRACT

The first task is to establish the build directory with
C<tundra_sync_build()> and load the map file from that directory along
with timing information using C<tundra_sync_load()>.

Everything is mixed together within a Kaltag buffer file.  Begin the
mixing process with C<tundra_sync_begin()>, which creates the Kaltag
buffer file.

To mix in assets, you must establish a source directory with the
function C<tundra_sync_src()> and then mix in audio assets from this
directory with C<tundra_sync_mix()>.  There may be multiple source
directories which are switched with multiple calls to the function
C<tundra_sync_src()>.

Each mix call maps a WAV file asset to a specific video asset within the
map.  Tundra assumes that the WAV file in the source directory is
synchronized with the original video asset it is mapped to (before any
editing was applied).  Tundra will use Kaltag to mix the audio asset
with proper synchronization into the Kaltag buffer.  If more than one
WAVE file is mapped to a single video asset, the result is all mixed
together.

Finally, use C<tundra_sync_end()> to output the Kaltag buffer to a full
WAV file that contains all the properly synchronized audio.

=cut

# State variables
# ===============

# The path components of the build directory, or an empty array if the
# build directory has not been set yet.
#
my @build_comp = ();

# The sampling rate in samples per second for all audio, and the exact
# frame rate in frames per second of the final video that the audio will
# be synchronized to.
#
# Both are zero if timing data hasn't been loaded yet.  These may be
# floating-point values.
#
my $samp_rate = 0;
my $frame_rate = 0;

# The total duration in seconds of the video map.
#
# This is -1 until the map is loaded.
#
my $total_dur = -1;

# The video map.
#
# This is only loaded if the $total_dur variable has been set.
#
# The string keys are video asset names from the map file.  The values
# are array references.  Each of these array references is an array of
# arrays, where the subarrays have the following elements:
#
# (1) [Float] Starting time in seconds within the edited video
# (2) [Float] Starting time in seconds within the original asset
# (3) [Float] Duration in seconds of the edited clip
# (4) [Float] Fade-in value in seconds
# (5) [Float] Fade-out value in seconds
#
# If the same video asset appears multiple times in the map, it will
# have one entry per appearance in the main array.  Assets that only
# appear once will only have one entry in the main array.
#
my %video_map;

# The path components of the current source directory, or an empty array
# if the source directory has not been set yet.
#
my @src_comp = ();

# The file extension (without the opening dot) to use for audio files in
# the current source directory, or zero if this hasn't been set yet.
#
my $src_ext = 0;

# The path to the Kaltag buffer file and the number of channels in the
# buffer file.
#
# The channels value is zero if this has not been set yet.
#
my $buf_channels = 0;
my $buf_path = 0;

=head1 METHODS

=over 4

=item B<tundra_sync_build(dir)>

Set the build directory for the audio.  This can only be called before
the map and timing data has been loaded.

B<dir> is the directory, relative to the current directory, holding the
video clips.  It must consist of a sequence of one or more lowercase
ASCII letters, ASCII decimal digits, ASCII underscores, and/or ASCII
forward slashes.  Forward slash may neither be first nor last character,
and forward slash may not directly precede or follow another forward
slash.  The directory must already exist.

The forward slash in the directory name will be changed to the
platform-specific directory separator if necessary.

=cut

sub tundra_sync_build {
  # Should have exactly one argument
  ($#_ == 0) or die "Wrong number of arguments, stopped";
  
  # Get the argument
  my $arg_dir  = shift;
  
  # Set argument types
  $arg_dir  = "$arg_dir";
  
  # Check arguments
  (($arg_dir =~ /^[a-z0-9_\/]+$/a) and not (
    ($arg_dir =~ /^\//a) or
    ($arg_dir =~ /\/$/a) or
    ($arg_dir =~ /\/\//a)
  )) or
    die "Directory name '$arg_dir' invalid, stopped";
  
  # Check state
  ($samp_rate == 0) or
    die "Can't change build directory after loading map, stopped";
  
  # Split the directory name
  @build_comp = split /\//, $arg_dir;
  
  # Get the system-specific name of the directory
  my $dname;
  if ($#build_comp > 0) {
    $dname = File::Spec->catdir(@build_comp);
  } else {
    $dname = $build_comp[0];
  }
  
  # Make sure directory exists
  (-d $dname) or
    die "Directory '$dname' does not exist, stopped";
}

=item B<tundra_sync_load(map, srate, frate)>

Load the map and timing information.  This can only be called after the
build directory has been loaded.  It may only be called once.

B<map> is the name of the map file within the build directory.  It must
consist of a sequence of one or more lowercase ASCII letters, ASCII
decimal digits, ASCII underscores, and/or ASCII dots.  Dots may neither
be first nor last character, and dot may not directly precede or follow
another dot.

The map file has one line per entry in the video map, and it must have
at least one content line.  Blank lines at the end are ignored.  The
lines declare the contents of the edited video in the order they appear.
There are five fields, separated by spaces.  The first field is the name
of the original video asset.  The second field is the starting frame
within the original video asset.  The third field is the number of
frames.  The fourth and fifth fields are the number of frames for a
fade-in and a fade-out, respectively.  All field values after the first
are unsigned decimal integers.

The map file format matches the maps produced by C<Tundra::Film>.

B<srate> is the sampling rate to use and assume for all audio, in
samples per second.  It must be greater than zero.  It can be a
floating-point value.

B<frate> is the frame rate to assume for all video, in frames per
second.  It must be greater than zero.  It can be a floating-point
value.

=cut

sub tundra_sync_load {
  # Should have exactly three arguments
  ($#_ == 2) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_map   = shift;
  my $arg_srate = shift;
  my $arg_frate = shift;
  
  # Set argument types
  $arg_map   = "$arg_map";
  $arg_srate = ($arg_srate + 0);
  $arg_frate = ($arg_frate + 0);
  
  # Check arguments
  (($arg_map =~ /^[a-z0-9_\.]+$/a) and not (
    ($arg_map =~ /^\./a) or
    ($arg_map =~ /\.$/a) or
    ($arg_map =~ /\.\./a)
  )) or
    die "Map name '$arg_map' invalid, stopped";
  
  ($arg_srate > 0) or
    die "Sample rate must be greater than zero, stopped";
  
  ($arg_frate > 0) or
    die "Frame rate must be greater than zero, stopped";
  
  # Check state
  ($#build_comp >= 0) or
    die "Must set build directory first, stopped";
  
  ($samp_rate == 0) or
    die "Can't reload map, stopped";
  
  # Load the map file
  my @mfile;
  tie @mfile, 'Tie::File',
      File::Spec->catfile(@build_comp, $arg_map), mode => O_RDONLY or
    die "Failed to tie map file, stopped";
  
  ($mfile[0] =~ /\S/a) or
    die "Map file first line is blank, stopped";
  
  my $t = 0;
  for my $c (@mfile) {
    # If line is blank, we are done
    if ($c =~ /^\s*$/a) {
      last;
    }
    
    # Parse into fields
    my @fields = split " ", $c;
    ($#fields == 4) or
      die "Wrong number of map record fields, stopped";
    
    # Check fields
    ($fields[0] =~ /^[a-z0-9_]+$/a) or
      die "Asset name in map file invalid, stopped";
    
    ($fields[1] =~ /^[0-9]+$/a) or
      die "Numeric field in map file invalid, stopped";
    
    ($fields[2] =~ /^[0-9]+$/a) or
      die "Numeric field in map file invalid, stopped";
    
    ($fields[3] =~ /^[0-9]+$/a) or
      die "Numeric field in map file invalid, stopped";
    
    ($fields[4] =~ /^[0-9]+$/a) or
      die "Numeric field in map file invalid, stopped";
    
    # Get the fields
    my $f_name = $fields[0];
    my $f_start = int($fields[1]);
    my $f_count = int($fields[2]);
    my $f_fade_in = int($fields[3]);
    my $f_fade_out = int($fields[4]);
    
    # Convert to seconds values
    $f_start = $f_start / $arg_frate;
    $f_count = $f_count / $arg_frate;
    $f_fade_in = $f_fade_in / $arg_frate;
    $f_fade_out = $f_fade_out / $arg_frate;
    
    # If the name is not yet in the map, add it with an empty array
    unless (exists $video_map{$f_name}) {
      $video_map{$f_name} = [];
    }
    
    # Set the subarray for this entry
    my $subarr = [$t, $f_start, $f_count, $f_fade_in, $f_fade_out];
    
    # Add to the video map
    push @{$video_map{$f_name}}, $subarr;
    
    # Update the time count
    $t = $t + $f_count;
  }
  
  untie @mfile;
  
  # Store the timing information
  $total_dur = $t;
  $samp_rate = $arg_srate;
  $frame_rate = $arg_frate;
}

=item B<tundra_sync_src(dir, ext)>

Set the source directory for the audio.  This can be called at any time.

B<dir> is the directory, relative to the current directory, holding the
audio files.  It must consist of a sequence of one or more lowercase
ASCII letters, ASCII decimal digits, ASCII underscores, and/or ASCII
forward slashes.  Forward slash may neither be first nor last character,
and forward slash may not directly precede or follow another forward
slash.  The directory must already exist.

The forward slash in the directory name will be changed to the
platform-specific directory separator if necessary.

C<ext> is the file extension of the audio files, not including the
opening dot.  It must consist of a sequence of one or more lowercase
ASCII letters, ASCII decimal digits, ASCII underscores, and/or ASCII
dots.  Dots may neither be first nor last character, and dot may not
directly precede or follow another dot.

=cut

sub tundra_sync_src {
  # Should have exactly two arguments
  ($#_ == 1) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_dir = shift;
  my $arg_ext = shift;
  
  # Set argument types
  $arg_dir = "$arg_dir";
  $arg_ext = "$arg_ext";
  
  # Check arguments
  (($arg_dir =~ /^[a-z0-9_\/]+$/a) and not (
    ($arg_dir =~ /^\//a) or
    ($arg_dir =~ /\/$/a) or
    ($arg_dir =~ /\/\//a)
  )) or
    die "Directory name '$arg_dir' invalid, stopped";
  
  (($arg_ext =~ /^[a-z0-9_\.]+$/a) and not (
    ($arg_ext =~ /^\./a) or
    ($arg_ext =~ /\.$/a) or
    ($arg_ext =~ /\.\./a)
  )) or
    die "Extension name '$arg_ext' invalid, stopped";
  
  # Split the directory name
  @src_comp = split /\//, $arg_dir;
  
  # Store the extension
  $src_ext = $arg_ext;
}

=item B<tundra_sync_begin(name, channels)>

Create the mixing buffer to begin the mixing process.  This can only be
called once after the map has been loaded.

B<name> is the name of the buffer file to create within the build
directory.  It must consist of a sequence of one or more lowercase ASCII
letters, ASCII decimal digits, ASCII underscores, and/or ASCII dots.
Dots may neither be first nor last character, and dot may not directly
precede or follow another dot.

B<channels> is the number of channels in this mixing buffer.  It must be
either 1 or 2.

=cut

sub tundra_sync_begin {
  # Should have exactly two arguments
  ($#_ == 1) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_name     = shift;
  my $arg_channels = shift;
  
  # Set argument types
  $arg_name     = "$arg_name";
  $arg_channels = int($arg_channels);
  
  # Check arguments
  (($arg_name =~ /^[a-z0-9_\.]+$/a) and not (
    ($arg_name =~ /^\./a) or
    ($arg_name =~ /\.$/a) or
    ($arg_name =~ /\.\./a)
  )) or
    die "Buffer name '$arg_name' invalid, stopped";
  
  (($arg_channels == 1) or ($arg_channels == 2)) or
    die "Invalid number of channels, stopped";
  
  # Check state
  ($total_dur >= 0) or
    die "Must load map before beginning, stopped";
  ($buf_channels == 0) or
    die "Can't begin sync another time, stopped";
  
  # Determine total sample count
  my $samp_count = int($total_dur * $samp_rate);
  if ($samp_count < 1) {
    $samp_count = 1;
  }
  
  # Determine the path to the buffer and store channel count
  $buf_path = File::Spec->catfile(@build_comp, $arg_name);
  $buf_channels = $arg_channels;
  
  # Invoke ktblank to create the buffer
  invoke_ktblank($arg_channels, $samp_count, $buf_path) or
    die "ktblank invocation failed, stopped";
}

=item B<tundra_sync_mix(wav, video)>

Mix in and synchronize an audio asset.  This can only be called after
the mixing buffer has been created with C<tundra_sync_begin()>.  A
source directory must be currently loaded.

B<wav> is the name of an audio file, without the extension, within the
currently loaded source directory.  It must be a sequence of one or more
lowercase ASCII letters, ASCII decimal digits, and/or ASCII underscores.

B<video> is the name of a video asset within the loaded map.  It must
exist within the map.

=cut

sub tundra_sync_mix {
  # Should have exactly two arguments
  ($#_ == 1) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_wav   = shift;
  my $arg_video = shift;
  
  # Set argument types
  $arg_wav   = "$arg_wav";
  $arg_video = "$arg_video";
  
  # Check arguments
  ($arg_wav =~ /^[a-z0-9_]+$/a) or
    die "Asset name '$arg_wav' is invalid, stopped";
  
  # Check state
  ($buf_channels > 0) or
    die "Can't mix until buffer file created, stopped";
  ($#src_comp >= 0) or
    die "Can't mix unless source directory loaded, stopped";
  
  # Check that video argument exists
  (exists $video_map{$arg_video}) or
    die "Can't find video asset '$arg_video' in map, stopped";
  
  # Get the source audio path
  my $a_path = File::Spec->catfile(@src_comp, $arg_wav);
  $a_path = $a_path . '.' . $src_ext;
  
  # Go through each instance of the video asset in the map
  for my $va (@{$video_map{$arg_video}}) {
    
    # Extract video asset fields
    my $f_dest_t   = $va->[0];
    my $f_src_t    = $va->[1];
    my $f_dur      = $va->[2];
    my $f_fade_in  = $va->[3];
    my $f_fade_out = $va->[4];
    
    # Convert times into sample counts
    $f_dest_t   = int($f_dest_t * $samp_rate);
    $f_src_t    = int($f_src_t * $samp_rate);
    $f_dur      = int($f_dur * $samp_rate);
    $f_fade_in  = int($f_fade_in * $samp_rate);
    $f_fade_out = int($f_fade_out * $samp_rate);
    
    # Duration must be at least one
    if ($f_dur < 1) {
      $f_dur = 1;
    }
    
    # Fade durations may not exceed full duration
    if ($f_fade_in > $f_dur) {
      $f_fade_in = $f_dur;
    }
    if ($f_fade_out > $f_dur) {
      $f_fade_out = $f_dur;
    }
    
    # Error if fades combined exceed duration
    ($f_fade_in + $f_fade_out <= $f_dur) or
      die "Fades exceed duration, stopped";
    
    # Invoke Kaltag to mix
    invoke_ktmix($a_path, $f_src_t, $f_dur, $f_dest_t,
                $f_fade_in, $f_fade_out, $buf_path) or
      die "ktmix invocation failed, stopped";
  }
}

=item B<tundra_sync_end(name, level)>

Render the mixing buffer to a WAV file.  This can only be called after
the mixing buffer has been created with C<tundra_sync_begin()>.  It can
actually be called more than once, but it is usual to just call it once.

B<name> is the name of the WAV file to create within the build
directory.  It must consist of a sequence of one or more lowercase ASCII
letters, ASCII decimal digits, ASCII underscores, and/or ASCII dots.
Dots may neither be first nor last character, and dot may not directly
precede or follow another dot.

B<level> is the target audio level after normalization.  It must be in
range [0, 32767].

=cut

sub tundra_sync_end {
  # Should have exactly two arguments
  ($#_ == 1) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_name  = shift;
  my $arg_level = shift;
  
  # Set argument types
  $arg_name  = "$arg_name";
  $arg_level = int($arg_level);
  
  # Check arguments
  (($arg_name =~ /^[a-z0-9_\.]+$/a) and not (
    ($arg_name =~ /^\./a) or
    ($arg_name =~ /\.$/a) or
    ($arg_name =~ /\.\./a)
  )) or
    die "Output name '$arg_name' invalid, stopped";
  
  (($arg_level >= 0) and ($arg_level <= 32767)) or
    die "Invalid level target, stopped";
  
  # Check state
  ($buf_channels > 0) or
    die "Can't render until buffer file created, stopped";
  
  # Invoke Kaltag to render the buffer
  invoke_ktwav($buf_path, $arg_level, $samp_rate,
                File::Spec->catfile(@build_comp, $arg_name)) or
    die "ktwav invocation failed, stopped";
}

=back

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
