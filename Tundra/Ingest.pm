package Tundra::Ingest;
use strict;
use parent qw(Exporter);

use Tundra::Invoke;
use File::Spec;

# Symbols to export from this module
#
our @EXPORT = qw(
                tundra_ingest_add_res
                tundra_ingest_add_audio
                tundra_ingest_set_flag
                tundra_ingest_clear_flag
                tundra_ingest_set_res
                tundra_ingest);

=head1 NAME

Tundra::Ingest - Functions for ingesting raw media assets.

=head1 SYNOPSIS

  use Tundra::Ingest;
  
  # Declare resolution profiles and audio directory
  #
  tundra_ingest_add_res(
      'full', 'mp4',
      '-c:v libx264 -preset medium -crf 17',
      1920, 1080);
  
  tundra_ingest_add_res(
      'hd720', 'mp4',
      '-c:v libx264 -preset medium -crf 17',
      1280, 720);
  
  tundra_ingest_add_res(
      'preview', 'mp4',
      '-c:v libx264 -preset veryfast -crf 23',
      640, 360);
  
  tundra_ingest_add_audio('audio', 'wav', '');
  
  # Use mode flags to determine how to ingest assets
  #
  tundra_ingest_set_flag('video');
  tundra_ingest_clear_flag('audio');
  
  # Set the resolution registers to determine resolution of assets
  #
  tundra_ingest_set_res(1920, 1080);
  
  # Ingest assets using the established mode flags and resolution
  # register values
  #
  tundra_ingest('asset_name', '/path/to/asset.MOV') or
    die "Ingest asset operation failed, stopped";

=head1 DESCRIPTION

The C<Tundra::Ingest> module allows raw assets to be ingested into a
project for further editing.  This module uses C<Tundra::Invoke> to run
the appropriate FFMPEG commands for converting raw assets as necessary.

=head1 ABSTRACT

=head2 Establishing profiles

Before ingesting the first asset, you must establish any resolution
profiles and the audio directory.  One or more resolution profiles are
required if there will be at least one asset that has video, while an
audio directory is required if there will be at least one asset that has
audio.

See the C<tundra_ingest_add_res()> function for how to establish
resolution profiles.  See the C<tundra_ingest_add_audio()> function for
how to establish an audio directory.

=head2 Setting flags

The way in which an asset is ingested is controlled by a set of flags.
Each flag has a name and a boolean value that is either set or cleared.

Use C<tundra_ingest_set_flag()> to set a specific flag, and use the
function C<tundra_ingest_clear_flag()> to clear a specific flag.  See
those functions for further information.

The state of flags is kept constant until changed by one of those two
functions, so flag configurations can be used for groups of similar
assets without having to change the flags each time.

=head2 Setting resolution

The resolution of a raw asset is determined by the resolution register,
which stores a width and height.  The resolution register is only
consulted for assets that have video, and it is used to determine
whether scaling is required.

Use C<tundra_ingest_set_res()> to set a specific value in the resolution
register.  The resolution register keeps its value until it is changed,
so the same value can be used for groups of similar assets without
having to change the resolution each time.  See the function
documentation for further information.

=head2 Ingesting assets

Each asset is ingested using C<tundra_ingest()>.  The type of asset and
the conversions necessary are determined from the current setting of the
flags, resolution register, and established resolution profiles.  See
the functiond documentation for further information.

Assets that have audio will have their audio extracted into an audio
file in the audio directory.

Assets that have video will have their video extracted into each
resolution profile directory.  The resolution profile directory each
contain a different copy of the extracted video at a different
resolution.  This can be used, for example, to have fast preview
versions while editing, and only saving the full quality for final
rendering.

=cut

# State variables
# ===============

# Flag that is set when the first asset is ingested.
#
my $first_asset = 0;

# Hash table of resolution profiles.
#
# Each key is the name of the resolution profile.  Each value is a
# reference to an array storing the following values:
#
#   (1) [String ] File extension, not including the opening dot
#   (2) [String ] FFMPEG encoding options
#   (3) [Integer] Width in pixels
#   (4) [Integer] Height in pixels
#
my %res_profile;

# Array storing the audio directory.
#
# If this array is empty, then the audio directory has not been
# established.
#
# Otherwise, the array has the following elements:
#
#   (1) [String] Audio directory name
#   (2) [String] File extension, not including the opening dot
#   (3) [String] FFMPEG encoding options
#
my @audio_dir = ();

# Hash table of flags.
#
# This is initialized with each flag having its default value of either
# zero or one.
#
# The "video" flag is set if assets include a video stream.
#
# The "audio" flag is set if assets include an audio stream.
#
# The "fps25" flag only applies to assets that include a video stream.
# If set, it means that the video stream has a fixed frame rate of
# exactly 25 frames per second.  If clear, it means that the ingest
# process will change the frame rate while importing.  The frame rate is
# changed so that all frames remain the same but the speed of video is
# changed to a constant 25fps.
#
# The "direct" flag only applies to assets that include a video AND that
# have the "fps25" flag set.  In this case, the "direct" flag means that
# a (very fast!) stream copy can be done for video data if the 
# resolution profile has the same resolution as the raw asset.  If
# clear, the video must always be re-encoded.  Note that FFMPEG video
# encoding options set for the resolution profile will be ignored if a
# stream copy is done.
#
my %asset_flags = (
  video  => 0,
  audio  => 0,
  fps25  => 0,
  direct => 0
);

# The resolution register.
#
# This is an array of two integers, storing the width and the height.
#
# The array is empty if the resolution register has not been set yet.
#
my @res_reg = ();

=head1 METHODS

=over 4

=item B<tundra_ingest_add_res(name, ext, opt, w, h)>

Declare a new resolution profile.  This function can only be called
before the first asset is ingested.

B<name> is the name of the resolution profile.  It must consist of a
sequence of one or more lowercase ASCII letters, ASCII decimal digits,
ASCII underscores, and/or ASCII forward slashes.  Forward slash may
neither be first nor last character, and forward slash may not directly
precede or follow another forward slash.  The name must not already be
defined.

The name of the resolution profile forms a directory path relative to
the current working directory.  The forward slash will be changed to the
platform-specific directory separator if necessary.

B<ext> is the file extension to give to ingested assets, not including
the opening dot of the file extension.  It must consist of a sequence
of one or more lowercase ASCII letters, ASCII decimal digits, ASCII
underscores, and/or ASCII dots.  Dots may neither be first nor last
character, and dot may not directly precede or follow another dot.

B<opt> is FFMPEG encoding options.  If an empty string, there are no
encoding options.  Otherwise, the string is split with whitespace
separators and passed as options before the output file when invoking
FFMPEG.

B<w> and B<h> are the width and height in pixels.  Both must be integers
that are greater than zero.

=cut

sub tundra_ingest_add_res {
  # Should have exactly five arguments
  ($#_ == 4) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_name = shift;
  my $arg_ext  = shift;
  my $arg_opt  = shift;
  my $arg_w    = shift;
  my $arg_h    = shift;
  
  # Set argument types
  $arg_name = "$arg_name";
  $arg_ext  = "$arg_ext";
  $arg_opt  = "$arg_opt";
  
  $arg_w = int($arg_w);
  $arg_h = int($arg_h);
  
  # Check arguments
  (($arg_name =~ /^[a-z0-9_\/]+$/a) and not (
    ($arg_name =~ /^\//a) or
    ($arg_name =~ /\/$/a) or
    ($arg_name =~ /\/\//a)
  )) or
    die "Resolution name '$arg_name' invalid, stopped";
  
  (($arg_ext =~ /^[a-z0-9_\.]+$/a) and not (
    ($arg_ext =~ /^\./a) or
    ($arg_ext =~ /\.$/a) or
    ($arg_ext =~ /\.\./a)
  )) or
    die "Extension name '$arg_ext' invalid, stopped";
  
  (($arg_w > 0) and ($arg_h > 0)) or
    die "Dimensions out of range for $arg_name, stopped";
  
  # Check that nothing has been ingested yet
  if ($first_asset) {
    die "Can't declare profile after ingesting asset, stopped";
  }
  
  # Check that resolution profile not already defined
  if (exists $res_profile{$arg_name}) {
    die "Can't redeclare profile '$arg_name', stopped";
  }
  
  # Add the resolution profile to the hash
  $res_profile{$arg_name} = [$arg_ext, $arg_opt, $arg_w, $arg_h];
}

=item B<tundra_ingest_add_audio(name, ext, opt)>

Set the audio directory.  This function can only be called before the
first asset is ingested, and it can only be called once.

B<name> is the name of the audio directory.  It must consist of a
sequence of one or more lowercase ASCII letters, ASCII decimal digits,
ASCII underscores, and/or ASCII forward slashes.  Forward slash may
neither be first nor last character, and forward slash may not directly
precede or follow another forward slash.

The name of the audio directory forms a directory path relative to
the current working directory.  The forward slash will be changed to the
platform-specific directory separator if necessary.

The audio directory may be the same as a resolution profile directory,
in which case audio files will be added into that resolution profile
directory.

B<ext> is the file extension to give to ingested assets, not including
the opening dot of the file extension.  It must consist of a sequence
of one or more lowercase ASCII letters, ASCII decimal digits, ASCII
underscores, and/or ASCII dots.  Dots may neither be first nor last
character, and dot may not directly precede or follow another dot.

B<opt> is FFMPEG encoding options.  If an empty string, there are no
encoding options.  Otherwise, the string is split with whitespace
separators and passed as options before the output file when invoking
FFMPEG.

=cut

sub tundra_ingest_add_audio {
  # Should have exactly three arguments
  ($#_ == 2) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_name = shift;
  my $arg_ext  = shift;
  my $arg_opt  = shift;
  
  # Set argument types
  $arg_name = "$arg_name";
  $arg_ext  = "$arg_ext";
  $arg_opt  = "$arg_opt";
  
  # Check arguments
  (($arg_name =~ /^[a-z0-9_\/]+$/a) and not (
    ($arg_name =~ /^\//a) or
    ($arg_name =~ /\/$/a) or
    ($arg_name =~ /\/\//a)
  )) or
    die "Audio directory '$arg_name' invalid, stopped";
  
  (($arg_ext =~ /^[a-z0-9_\.]+$/a) and not (
    ($arg_ext =~ /^\./a) or
    ($arg_ext =~ /\.$/a) or
    ($arg_ext =~ /\.\./a)
  )) or
    die "Extension name '$arg_ext' invalid, stopped";
  
  # Check that nothing has been ingested yet
  if ($first_asset) {
    die "Can't declare audio directory after ingesting asset, stopped";
  }
  
  # Check that audio directory not already defined
  if ($#audio_dir >= 0) {
    die "Can't redeclare audio directory, stopped";
  }
  
  # Add the audio directory
  @audio_dir = ($arg_name, $arg_ext, $arg_opt);
}

=item B<tundra_ingest_set_flag(name)>

Set one of the mode flags.

B<name> is the name of the flag to set.  It must be one of the
following:

=over

=item *

C<video> - Set this flag if subsequent assets that are ingested have a
video stream.

=item *

C<audio> - Set this flag if subsequent assets that are ingested have an
audio stream.

=item *

C<fps25> - Set this flag if subsequent assets that are ingested already
have a constant frame rate of exactly 25 frames per second and do not
need any frame rate conversion.  This flag has no effect unless the
video flag is also set.

=item *

C<direct> - Set this flag if direct stream copies are possible between
the raw asset and the ingested asset.  Direct stream copies are very
fast.  Encoding options are ignored when a direct stream copy is
performed.  This flag has no effect unless the video flag is set and the
fps25 flag is set and the resolution in the resolution register matches
the resolution of the current profile.

=back

Flag settings are maintained between asset calls and can be changed at
any time.  Use C<tundra_ingest_clear_flag()> to clear the flags.

=cut

sub tundra_ingest_set_flag {
  # Should have exactly one argument
  ($#_ == 0) or die "Wrong number of arguments, stopped";
  
  # Get the argument
  my $arg_name = shift;
  
  # Set argument type
  $arg_name = "$arg_name";
  
  # Check argument
  (exists $asset_flags{$arg_name}) or
    die "Ingest flag '$arg_name' is not recognized, stopped";
  
  # Set the flag
  $asset_flags{$arg_name} = 1;
}

=item B<tundra_ingest_clear_flag(name)>

Clear one of the mode flags.

B<name> is the name of the flag to set.  It must be one of the
following:

=over

=item *

C<video> - Clear this flag if subsequent assets that are ingested do not
have a video stream.

=item *

C<audio> - Clear this flag if subsequent assets that are ingested do not
have an audio stream.

=item *

C<fps25> - Clear this flag if subsequent assets that are ingested do not
have a constant frame rate of exactly 25 frames per second.  This flag
has no effect unless the video flag is also set.  When this flag is
clear, the frame rate will be converted to 25 frames per second by
changing the speed of the video such that the frames are the same but
the duration of each frame is set to a constant 25fps.

=item *

C<direct> - Clear this flag if direct stream copies are not possible
between the raw asset and the ingested asset.  Direct stream copies are
very fast, but can only be done if the raw asset has the same video type
as the ingested asset.  Encoding options are ignored when a direct
stream copy is performed.  This flag has no effect unless the video flag
is set and the fps25 flag is set and the resolution in the resolution
register matches the resolution of the current profile.  Clearing this
flag prevents any direct stream copies.

=back

Flag settings are maintained between asset calls and can be changed at
any time.  Use C<tundra_ingest_set_flag()> to set the flags.

=cut

sub tundra_ingest_clear_flag {
  # Should have exactly one argument
  ($#_ == 0) or die "Wrong number of arguments, stopped";
  
  # Get the argument
  my $arg_name = shift;
  
  # Set argument type
  $arg_name = "$arg_name";
  
  # Check argument
  (exists $asset_flags{$arg_name}) or
    die "Ingest flag '$arg_name' is not recognized, stopped";
  
  # Clear the flag
  $asset_flags{$arg_name} = 0;
}

=item B<tundra_ingest_set_res(width, height)>

Set the resolution register.

B<width> is the width in pixels.  B<height> is the height in pixels.
Both must be integers that are greater than zero.

The resolution register is only consulted for assets that have a video
stream.  In this case, the value in resolution register is assumed to be
the resolution of the frame in the raw asset.  You must call this
function to set the register before ingesting any assets that have video
streams.

The resolution register value is maintained between asset calls and can
be changed at any time.

=cut

sub tundra_ingest_set_res {
  # Should have exactly two arguments
  ($#_ == 1) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_w = shift;
  my $arg_h = shift;
  
  # Set argument types
  $arg_w = int($arg_w);
  $arg_h = int($arg_h);
  
  # Check arguments
  (($arg_w > 0) and ($arg_h > 0)) or
    die "Resolution arguments must be greater than zero, stopped";
  
  # Set the register
  @res_reg = ($arg_w, $arg_h);
}

=item B<tundra_ingest(name, path)>

Ingest an asset.

B<name> is the name of the asset.  It must be a sequence of one or more
lowercase ASCII letters, ASCII decimal digits, and/or ASCII underscores.

B<path> is the path to the asset in the local file system.  No
conversion is done on this path, so it is platform-specific.

Any resolution profiles must already have been added using the function
C<tundra_ingest_add_res()> and any audio directory must already have
been added using C<tundra_ingest_add_audio()> before calling this
function.  After the first asset is ingested, no further changes may be
made to profiles and audio directories.

The current state of the ingestion flags will be used with the ingest
call.  Use C<tundra_ingest_set_flag()> and C<tundra_ingest_clear_flag()>
before calling this function to set the flags appropriately.  The only
restriction is the video and audio flags are not both allowed to be
clear.  (By default, both are clear, so you must change this before
calling this function.)

If the video flag is on for the current asset, then the resolution
register must have a valid value, which indicates the resolution of the
asset that is being imported.  Use C<tundra_ingest_set_res()> to set the
value of this resolution register.

If the video flag is on for the current asset, there must be at least
one resolution profile defined.  If the audio flag is on for the current
asset, the audio directory must be defined.

Video streams will be exported to each of the resolution profile
directories, appropriately scaled if necessary.  Audio streams will be
exported to the audio directory.  If files already exist in the target
location within the resolution profile or audio directory, the file is
removed before ingesting.

The C<Tundra::Invoke> module will be used to invoke ffmpeg appropriately
to ingest the asset.

=cut

sub tundra_ingest {
  
  # Should have exactly two arguments
  ($#_ == 1) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_name = shift;
  my $arg_path = shift;
  
  # Set argument types
  $arg_name = "$arg_name";
  $arg_path = "$arg_path";
  
  # Check arguments
  ($arg_name =~ /^[a-z0-9_]+$/a) or
    die "Asset name '$arg_name' is invalid, stopped";
  
  # Set the first_asset flag
  $first_asset = 1;
  
  # Get the current flags
  my $flag_video  = $asset_flags{'video'};
  my $flag_audio  = $asset_flags{'audio'};
  my $flag_fps25  = $asset_flags{'fps25'};
  my $flag_direct = $asset_flags{'direct'};
  
  # Make sure either video or audio flag is set
  ($flag_video or $flag_audio) or
    die "video and audio flags may not both be clear, stopped";
  
  # Export audio if present
  if ($flag_audio) {
    # Make sure audio directory is present
    ($#audio_dir >= 0) or
      die "Must set audio directory before audio ingest, stopped";
    
    # Get audio directory variables
    my $a_name = $audio_dir[0];
    my $a_ext  = $audio_dir[1];
    my $a_opt  = $audio_dir[2];
    
    # Split audio directory name around "/" and rebuild appropriately
    # for the current platform
    my @a_name_comp = split /\//, $a_name;
    $a_name = File::Spec->catfile(@a_name_comp, $arg_name);
    
    # Add the appropriate extension
    $a_name = "$a_name.$a_ext";
    
    # Extract audio options
    my @a_olist = ();
    if (length $a_opt > 0) {
      @a_olist = split " ", $a_opt;
    }
    
    # Build ffmpeg command
    my @a_cmd = ('-i', $arg_path, '-map', '0:a:0');
    push @a_cmd, @a_olist;
    push @a_cmd, ($a_name);
    
    # If asset file already exists, remove it
    if (-f $a_name) {
      unlink($a_name);
    }
    
    # Invoke ffmpeg
    invoke_ffmpeg(@a_cmd) or
      die "Audio ingestion for $arg_name failed, stopped";
  }
  
  # Export video if present
  if ($flag_video) {
    # Get all resolution profile name keys
    my @vps = keys %res_profile;
    
    # Make sure at least one profile
    ($#vps >= 0) or
      die "Must set resolution profiles before video ingest, stopped";
    
    # Make sure resolution register filled
    ($#res_reg >= 0) or
      die "Must set resolution register before video ingest, stopped";
    
    # Get resolution of input video
    my $input_w = $res_reg[0];
    my $input_h = $res_reg[1];
    
    # Export to each profile
    for my $vp (@vps) {
      # Get parameters for this profile
      my $v_ext = $res_profile{$vp}->[0];
      my $v_opt = $res_profile{$vp}->[1];
      my $v_w   = $res_profile{$vp}->[2];
      my $v_h   = $res_profile{$vp}->[3];
      
      # Split profile directory name around "/" and rebuild
      # appropriately for the current platform
      my @v_name_comp = split /\//, $vp;
      my $v_name = File::Spec->catfile(@v_name_comp, $arg_name);
      
      # Add the appropriate extension
      $v_name = "$v_name.$v_ext";
      
      # Extract video options
      my @v_olist = ();
      if (length $v_opt > 0) {
        @v_olist = split " ", $v_opt;
      }
      
      # Begin building ffmpeg command
      my @v_cmd = ();
      
      # Unless fps25 flag specified, we need to add a rate change prefix
      # to the command
      unless ($flag_fps25) {
        push @v_cmd, ('-r', '25');
      }
      
      # Add the input file
      push @v_cmd, ('-i', $arg_path, '-map', '0:v:0');
      
      # If resolution is not the same, add scaling to output
      unless (($v_w == $input_w) and ($v_h == $input_h)) {
        push @v_cmd, ('-filter', "scale=w=$v_w:h=$v_h");
      }
      
      # Add either stream copy or encoding options
      if ($flag_fps25 and $flag_direct and
            ($v_w == $input_w) and ($v_h == $input_h)) {
        # Perform a stream copy
        push @v_cmd, ('-c:v', 'copy');
        
      } else {
        # Regular encoding options
        push @v_cmd, @v_olist;
      }
      
      # Add the output file
      push @v_cmd, ($v_name);
      
      # If asset file already exists, remove it
      if (-f $v_name) {
        unlink($v_name);
      }
      
      # Invoke ffmpeg
      invoke_ffmpeg(@v_cmd) or
        die "Video ingestion for $arg_name failed, stopped";
    }
  }
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
