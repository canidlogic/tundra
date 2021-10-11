package Tundra::Clip;
use strict;
use parent qw(Exporter);

use Tundra::Invoke;
use File::Spec;
use Tie::File;

# Symbols to export from this module
#
our @EXPORT = qw(
                tundra_clip_src
                tundra_clip_dest
                tundra_clip_load
                tundra_clip_seek
                tundra_clip_skip
                tundra_clip_read);

=head1 NAME

Tundra::Clip - Functions for extracting video clips from ingested
assets.

=head1 SYNOPSIS

  use Tundra::Clip;
  
  # Declare where the ingested video clips are stored
  #
  tundra_clip_src('preview', 'mp4');
  
  # Declare where generated clips will be stored
  #
  tundra_clip_dest(
      'clip', 'mp4', 'clip',
      '-c:v libx264 -preset medium -crf 17');
  
  # Load a specific asset for extracting a clip
  #
  tundra_clip_load('asset');
  
  # Seek to a specific frame in the loaded asset
  #
  tundra_clip_seek(5 * 25);
  
  # Adjust current position in loaded asset by one
  #
  tundra_clip_skip(1);
  
  # Read a certain number of frames into a clip
  #
  tundra_clip_read('clip', 2 * 25);

=head1 DESCRIPTION

The C<Tundra::Clip> module allows video clips to be extracted from
ingested assets.  Use the C<Tundra::Ingest> module to ingest assets.
This clip module assumes that assets have a frame rate of 25 frames per
second.  This module uses C<Tundra::Invoke> to run the appropriate
FFMPEG commands for extracting clips.

=head1 ABSTRACT

=head2 Establishing source and destination

Before extracting any clips, you must establish the source and
destination directories.  These directories may be changed at any time,
and they may point at the same directory.

Use C<tundra_clip_src()> to set the source directory, and use the
function C<tundra_clip_dest()> to set the destination directory and the
encoding options for the generated clip.  See those functions for
further information.

=head2 Loading assets

Once source and destination directories are set up, you must load a
specific asset using C<tundra_clip_load()>.  The asset remains loaded
until a different asset is loaded or the source directory is changed.
See the loading function for further information.

There is no need to explicitly unload assets.

=head2 Seeking within assets

Once an asset is loaded, you may seek to different frame positions
within the asset using C<tundra_clip_seek()>.  Ingested assets always
have a frame rate of 25 frames per second.  See the seek function for
further information.

The seek function always sets absolute positions.  You may adjust the
position relatively using the C<tundra_clip_skip()> function, which
takes a frame displacement that may be positive or negative.

=head2 Extracting clips

Once an asset is loaded and the destination directory is established,
you may extract clips using the C<tundra_clip_read()> function.  This
function takes the name of the clip asset to generate in the destination
directory and also the number of frames that should be transferred into
this new asset.

The reading function adjusts the current position within the clip so
that it references the next frame after the end of the clip that was
just read.

=cut

# State variables
# ===============

# Array storing the source directory information.
#
# If this is empty, then no source directory is loaded.  Otherwise, it
# has the following elements:
#
# (1) [String] The source directory name
# (2) [String] File extension used for ingested assets in directory
#
my @src_dir = ();

# Array storing the destination directory information.
#
# If this is empty, then no destination directory is loaded.  Otherwise,
# it has the following elements:
#
# (1) [String] The destination directory name
# (2) [String] Video file extension used for clips in directory
# (3) [String] Descriptor file extension used for clips in directory
# (4) [String] Video encoding options
#
my @dest_dir = ();

# Currently loaded asset within the source directory.
#
# If this is empty, then no asset is loaded.  Otherwise, it has the
# following elements:
#
# (1) [String ] The name of the asset
# (2) [String ] The path to the asset
# (3) [Integer] The current frame position within the asset
#
my @asset = ();

=head1 METHODS

=over 4

=item B<tundra_clip_src(dir, ext)>

Set the current source directory for ingested assets.  This can be
called at any time.

B<dir> is the directory, relative to the current directory, holding the
ingested assets.  It must consist of a sequence of one or more lowercase
ASCII letters, ASCII decimal digits, ASCII underscores, and/or ASCII
forward slashes.  Forward slash may neither be first nor last character,
and forward slash may not directly precede or follow another forward
slash.  The directory must already exist.

The forward slash in the directory name will be changed to the
platform-specific directory separator if necessary.

B<ext> is the file extension of ingested assets, not including the
opening dot of the file extension.  It must consist of a sequence of one
or more lowercase ASCII letters, ASCII decimal digits, ASCII
underscores, and/or ASCII dots.  Dots may neither be first nor last
character, and dot may not directly precede or follow another dot.

Changing the source directory will automatically unload any currently
loaded asset.

=cut

sub tundra_clip_src {
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
  
  # Save the directory argument as the name
  my $sname = $arg_dir;
  
  # If there is any "/" character in the directory name, split by
  # separator and rebuild appropriately for platform
  if ($arg_dir =~ /\//) {
    my @dir_comp = split /\//, $arg_dir;
    $arg_dir = File::Spec->catdir(@dir_comp);
  }
  
  # Make sure directory exists
  (-d $arg_dir) or
    die "Directory $arg_dir does not exist, stopped";
  
  # Unload any currently loaded asset
  @asset = ();
  
  # Store the new source directory
  @src_dir = ($sname, $arg_ext);
}

=item B<tundra_clip_dest(dir, vext, dext, opt)>

Set the current destination directory for generated clips.  This can be
called at any time.

B<dir> is the directory, relative to the current directory, for the
generated clips.  It must consist of a sequence of one or more lowercase
ASCII letters, ASCII decimal digits, ASCII underscores, and/or ASCII
forward slashes.  Forward slash may neither be first nor last character,
and forward slash may not directly precede or follow another forward
slash.  The directory must already exist.

The forward slash in the directory name will be changed to the
platform-specific directory separator if necessary.

B<vext> and B<dext> are the file extensions for generated video clips
and generated video clip descriptors, not including the opening dot of
the file extension.  They must both consist of a sequence of one or more
lowercase ASCII letters, ASCII decimal digits, ASCII underscores, and/or
ASCII dots.  Dots may neither be first nor last character, and dot may
not directly precede or follow another dot.  Furthermore, the two
extensions may not be the same.

B<opt> is FFMPEG encoding options.  If an empty string, there are no
encoding options.  Otherwise, the string is split with whitespace
separators and passed as options before the output file when invoking
FFMPEG.

=cut

sub tundra_clip_dest {
  # Should have exactly four arguments
  ($#_ == 3) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_dir  = shift;
  my $arg_vext = shift;
  my $arg_dext = shift;
  my $arg_opt  = shift;
  
  # Set argument types
  $arg_dir  = "$arg_dir";
  $arg_vext = "$arg_vext";
  $arg_dext = "$arg_dext";
  $arg_opt  = "$arg_opt";
  
  # Check arguments
  (($arg_dir =~ /^[a-z0-9_\/]+$/a) and not (
    ($arg_dir =~ /^\//a) or
    ($arg_dir =~ /\/$/a) or
    ($arg_dir =~ /\/\//a)
  )) or
    die "Directory name '$arg_dir' invalid, stopped";
  
  (($arg_vext =~ /^[a-z0-9_\.]+$/a) and not (
    ($arg_vext =~ /^\./a) or
    ($arg_vext =~ /\.$/a) or
    ($arg_vext =~ /\.\./a)
  )) or
    die "Extension name '$arg_vext' invalid, stopped";
  
  (($arg_dext =~ /^[a-z0-9_\.]+$/a) and not (
    ($arg_dext =~ /^\./a) or
    ($arg_dext =~ /\.$/a) or
    ($arg_dext =~ /\.\./a)
  )) or
    die "Extension name '$arg_dext' invalid, stopped";
  
  ($arg_vext ne $arg_dext) or
    die "Video and descriptor extensions must be different, stopped";
  
  # Store the directory as the name
  my $dname = $arg_dir;
  
  # If there is any "/" character in the directory name, split by
  # separator and rebuild appropriately for platform
  if ($arg_dir =~ /\//) {
    my @dir_comp = split /\//, $arg_dir;
    $arg_dir = File::Spec->catdir(@dir_comp);
  }
  
  # Make sure directory exists
  (-d $arg_dir) or
    die "Directory $arg_dir does not exist, stopped";
  
  # Store the new destination directory
  @dest_dir = ($dname, $arg_vext, $arg_dext, $arg_opt);
}

=item B<tundra_clip_load(name)>

Load an ingested asset and seek to the first frame.

The source directory must already be loaded with C<tundra_clip_src()>
before using this function.  Changing the source directory will
automatically unload any currently loaded asset.

Assets do not need to be explicitly unloaded.

B<name> is the name of the asset to load.  It must be a sequence of one
or more lowercase ASCII letters, ASCII decimal digits, and/or ASCII
underscores.  It does NOT include the extension.  The specified asset
must exist in the source directory.

=cut

sub tundra_clip_load {
  # Should have exactly one argument
  ($#_ == 0) or die "Wrong number of arguments, stopped";
  
  # Get the argument
  my $arg_name  = shift;
  
  # Set argument type
  $arg_name  = "$arg_name";
  
  # Check argument
  ($arg_name =~ /^[a-z0-9_]+$/a) or
    die "Asset name '$arg_name' is invalid, stopped";
  
  # Check that source directory is loaded
  ($#src_dir >= 0) or
    die "Load source directory before loading assets, stopped";
  
  # Form the complete path to the asset
  my @s_comp = split /\//, $src_dir[0];
  my $a_path = File::Spec->catfile(@s_comp, $arg_name);
  $a_path = $a_path . '.' . $src_dir[1];
  
  # Make sure asset exists
  (-f $a_path) or
    die "File $a_path does not exist, stopped";
  
  # Store the new asset
  @asset = ($arg_name, $a_path, 0);
}

=item B<tundra_clip_seek(pos)>

Seek to an absolute frame within a currently loaded asset.

An asset must currently be loaded with C<tundra_clip_load()> before
using this function.

The given position can be any integer value, including negative values.
The position is not actually used or checked until the clip is exported
with C<tundra_clip_read()>.

This function sets an absolute frame position, ignoring the current
position within the clip.  To set a relative position, see the function
C<tundra_clip_skip()>.

The first frame has position zero.  When assets are loaded, their
current position always starts out at position zero.

=cut

sub tundra_clip_seek {
  # Should have exactly one argument
  ($#_ == 0) or die "Wrong number of arguments, stopped";
  
  # Get the argument
  my $arg_pos  = shift;
  
  # Set argument type
  $arg_pos  = int($arg_pos);
  
  # Check that asset is loaded
  ($#asset >= 0) or
    die "Load asset before seeking, stopped";
  
  # Update the asset position
  $asset[2] = $arg_pos;
}

=item B<tundra_clip_skip(rel)>

Seek relative to the current frame within a currently loaded asset.

An asset must currently be loaded with C<tundra_clip_load()> before
using this function.

The relative seek can be any integer value, including negative values
and zero.  The result of the relative seek can be anywhere, including
negative frame positions.  The position is not actually used or checked
until the clip is exported with C<tundra_clip_read()>.

To set an absolute frame position, see C<tundra_clip_seek()>.

=cut

sub tundra_clip_skip {
  # Should have exactly one argument
  ($#_ == 0) or die "Wrong number of arguments, stopped";
  
  # Get the argument
  my $arg_rel  = shift;
  
  # Set argument type
  $arg_rel  = int($arg_rel);
  
  # Check that asset is loaded
  ($#asset >= 0) or
    die "Load asset before seeking, stopped";
  
  # Update the asset position
  $asset[2] = $asset[2] + $arg_rel;
}

=item B<tundra_clip_read(name, count)>

Read and export a clip from the currently loaded asset.

An asset must currently be loaded with C<tundra_clip_load()> before
using this function.  Reading will start at the current position within
the asset.  The only check done by this function is that the current
position is zero or greater.  After the function completes, the current
position within the loaded asset will be updated to be at the frame
immediately following the clip that was just exported.

The destination directory must also be loaded with C<tundra_clip_dest()>
before using this function.  It determines where the generated clip will
be written to.

B<name> is the name of the clip to generate.  It must be a sequence of
one or more lowercase ASCII letters, ASCII decimal digits, and/or ASCII
underscores.  It does NOT include the extension.

B<count> is the number of frames to export from the currently loaded
asset to the generated clip.  It must be an integer that is greater than
zero.

This function will generate two different files in the destination
directory.  If either or both of the files already exist, they will be
deleted and then recreated.  The first file is a descriptor file, which
is the asset name with the descriptor extension defined by the function
C<tundra_clip_dest()>.  This is a text file that contains a single line
of text with name of the asset the clip came from, the starting frame
index of the clip within that asset, and the count of frames within the
clip.  The numeric values are stored as unsigned decimal integers and
all three values are separated by spaces.

The other file generated will be the actual video clip, which will have
the video extension defined by C<tundra_clip_dest()>.

The C<Tundra::Invoke> module will be used to invoke ffmpeg appropriately
to generate the clip from the source asset.

This function assumes that the source asset has been properly ingested
with the C<Tundra::Ingest> module.  In particular, the ingested asset
must have a constant frame rate of 25 frames per second and should only
have a single video channel.

=cut

sub tundra_clip_read {
  # Should have exactly two arguments
  ($#_ == 1) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_name  = shift;
  my $arg_count = shift;
  
  # Set argument types
  $arg_name  = "$arg_name";
  $arg_count = int($arg_count);
  
  # Check arguments
  ($arg_name =~ /^[a-z0-9_]+$/a) or
    die "Clip name '$arg_name' is invalid, stopped";
  
  ($arg_count > 0) or
    die "Clip frame count must be greater than zero, stopped";
  
  # Check that asset is loaded
  ($#asset >= 0) or
    die "Load asset before seeking, stopped";
  
  # Check that loaded asset has position of zero or greater
  ($asset[2] >= 0) or
    die "Asset position must be zero or greater, stopped";
  
  # Check that destination directory is loaded
  ($#dest_dir >= 0) or
    die "Destination clip directory must be loaded, stopped";

  # Determine the paths to the descriptor file and video file for the
  # clip
  my @c_comp = split /\//, $dest_dir[0];
  my $base_path = File::Spec->catfile(@c_comp, $arg_name);
  
  my $dpath = $base_path . '.' . $dest_dir[2];
  my $vpath = $base_path . '.' . $dest_dir[1];
  
  # If clip file(s) already exists, remove them
  if (-f $dpath) {
    unlink($dpath);
  }
  if (-f $vpath) {
    unlink($vpath);
  }
  
  # Print the descriptor information
  my @dfile;
  tie @dfile, 'Tie::File', $dpath or
    die "Failed to tie descriptor file '$dpath', stopped";
  
  $#dfile = -1;
  my $dline = $asset[0] . ' ' . $asset[2] . ' ' . $arg_count;
  push @dfile, ($dline);
  
  untie @dfile;
  
  # Extract video encoding options
  my @v_olist = ();
  if (length $dest_dir[3] > 0) {
    @v_olist = split " ", $dest_dir[3];
  }
  
  # Determine starting time at 25 fps as a string
  my $start_i = int($asset[2] / 25);
  my $start_f = int($asset[2] % 25) * 4;
  if ($start_f < 10) {
    $start_f = "0$start_f";
  } else {
    $start_f = "$start_f";
  }
  my $start = "$start_i.$start_f";
  
  # Determine duration at 25 fps as a string
  my $dur_i = int($arg_count / 25);
  my $dur_f = int($arg_count % 25) * 4;
  if ($dur_f < 10) {
    $dur_f = "0$dur_f";
  } else {
    $dur_f = "$dur_f";
  }
  my $dur = "$dur_i.$dur_f";

  # Build ffmpeg command
  my @v_cmd = (
                '-ss', $start,
                '-t' , $dur,
                '-i' , $asset[1]);
  push @v_cmd, @v_olist;
  push @v_cmd, ($vpath);
  
  # Invoke ffmpeg
  invoke_ffmpeg(@v_cmd) or
    die "Clip extraction for '$dline' failed, stopped";
  
  # Update current position
  $asset[2] = $asset[2] + $arg_count;
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
