package Tundra::Film;
use strict;
use parent qw(Exporter);

use Tundra::Invoke;

use Fcntl 'O_RDONLY';
use File::Copy;
use File::Spec;
use Tie::File;

# Symbols to export from this module
#
our @EXPORT = qw(
                tundra_film_src
                tundra_film_clip
                tundra_film_clean
                tundra_film_build);

=head1 NAME

Tundra::Film - Functions for assembling video clips into a single video.

=head1 SYNOPSIS

  use Tundra::Film;
  
  # Declare where the video clips are stored
  #
  tundra_film_src('clip/dir', 'mp4', 'clip');
  
  # Add each clip to the movie, with optional fades
  #
  tundra_film_clip('first_clip', 25, 0);
  tundra_film_clip('second_clip', 0, 0);
  tundra_film_clip('third_clip', 0, 25);
  
  # Build the full movie
  #
  tundra_film_build(
      'movie/dir', 'full_movie', 'i_', 'mp4', 'map',
      '-c:v libx264 -preset medium -crf 17', 8);
  
  # Clear intermediate files from a directory
  #
  tundra_film_clean('dir/path', 'i_', 'mp4');

=head1 DESCRIPTION

The C<Tundra::Film> module allows a sequence of video clips to be
assembled into a single movie.  Each clip may optionally have a fade-in
and/or a fade-out.

Use the C<Tundra::Clip> module to generate all the video clips first.
This module uses C<Tundra::Invoke> to run the appropriate FFMPEG
commands for assembling clips.  All clips are assumed to have the same
format with a single video stream and a frame rate of 25 frames per
second.

=head1 ABSTRACT

=head2 Establishing source directory

Before declaring any clips, you must establish the source directory that
holds all the video clips.  This directory may not be changed after the
first video clip has been declared.  See the C<tundra_film_src> function
for further information.

=head2 Declaring clips

After the source directory has been established, you declare a sequence
of one or more clips to add into the assembled movie, with each clip
being declared by a C<tundra_film_clip()> call.

=head2 Building the movie

Once all the film clips have been declared, you may build the assembled
movie with the C<tundra_film_build()> command.

This module recursively breaks the assembly process into multiple ffmpeg
invocations if necesary to keep the total number of clips assembled in
each ffmpeg invocation below a limit given as a parameter to the
function C<tundra_film_build()>.  This allows an arbitrarily large
number of clips to be assembled, without worrying about overloading the
ffmpeg command invocation.

On a successful build, intermediate files will be automatically cleaned.
To clean them explicitly, use C<tundra_film_clean()>.

=cut

# State variables
# ===============

# Array storing the source directory information.
#
# If this is empty, then no source directory is decalred.  Otherwise, it
# has the following elements:
#
# (1) [String] The source directory name
# (2) [String] File extension used for video clip files
# (3) [String] File extension used for clip descriptor files
#
my @src_dir = ();

# Array storing the clips in the assembled movie.
#
# Each clip is an element in this array.  Each element in this array is
# a reference to another array that has the following information:
#
# (1) [String ] The name of the video clip
# (2) [String ] The name of the asset that this clip was taken from
# (3) [Integer] The starting frame offset in the asset the clip is from
# (4) [Integer] The number of frames in this clip
# (5) [Integer] Number of frames for a fade-in
# (6) [Integer] Number of frames for a fade-out
#
my @movie = ();

# Concatenate a sequence of videos together.
#
# The first argument is a string that specifies FFMPEG encoding options
# for the concatenated video.  (Empty if no options required.)
#
# The second argument is the path to the output video.  The file at this
# path will be deleted if it already exists.
#
# All arguments after the second are paths to the video files to
# concatenate.  There must be at least two video paths in this list.
#
sub cat_video {
  
  # Make sure at least four parameters
  ($#_ >= 3) or
    die "Must pass at least four arguments, stopped";
  
  # Grab the fixed parameters
  my $arg_opt = shift;
  my $arg_out = shift;
  
  # Make sure all remaining parameters point to existing files
  for my $f (@_) {
    (-f $f) or
      die "File '$f' does not exist, stopped";
  }
  
  # Delete output file if it already exists
  if (-f $arg_out) {
    unlink($arg_out);
  }
  
  # Extract video encoding options
  my @v_olist = ();
  if (length $arg_opt > 0) {
    @v_olist = split " ", $arg_opt;
  }
  
  # Build filter chain
  my $fchain = '';
  for (my $i = 0; $i <= $#_; $i++) {
    if ($i > 0) {
      $fchain = $fchain . ' ';
    }
    $fchain = $fchain . "[$i:0]";
  }
  my $seg_count = $#_ + 1;
  $fchain = $fchain . " concat=n=$seg_count:v=1:a=0 [v]";
  
  # Build ffmpeg command
  my @v_cmd = ();
  for my $f (@_) {
    push @v_cmd, ('-i', $f);
  }
  
  push @v_cmd, (  '-filter_complex', $fchain,
                  '-map', '[v]',
                  $arg_out);
  
  # Invoke ffmpeg
  invoke_ffmpeg(@v_cmd) or
    die "Clip concatenation failed, stopped";
}

=head1 METHODS

=over 4

=item B<tundra_film_src(dir, vext, dext)>

Set the source directory for video clips.  This can only be called
before the first clip has been declared with C<tundra_film_clip()>.

B<dir> is the directory, relative to the current directory, holding the
video clips.  It must consist of a sequence of one or more lowercase
ASCII letters, ASCII decimal digits, ASCII underscores, and/or ASCII
forward slashes.  Forward slash may neither be first nor last character,
and forward slash may not directly precede or follow another forward
slash.  The directory must already exist.

The forward slash in the directory name will be changed to the
platform-specific directory separator if necessary.

B<vext> and B<dext> are the file extensions of video clip files and clip
descriptor files in the clip directory, not including the opening dot of
the file extension.  They must consist of a sequence of one or more
lowercase ASCII letters, ASCII decimal digits, ASCII underscores, and/or
ASCII dots.  Dots may neither be first nor last character, and dot may
not directly precede or follow another dot.  The two extensions may not
be the same.

The video descriptor file is a text file containing a single line of
text that has the asset name the clip came from, the starting frame
index of the clip, and the number of frames in the clip.  The numeric
parameters are unsigned decimal integers and each field is separated by
a space.

=cut

sub tundra_film_src {
  # Should have exactly three arguments
  ($#_ == 2) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_dir  = shift;
  my $arg_vext = shift;
  my $arg_dext = shift;
  
  # Set argument types
  $arg_dir  = "$arg_dir";
  $arg_vext = "$arg_vext";
  $arg_dext = "$arg_dext";
  
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
  
  # Check that no clips have been declared yet
  ($#movie < 0) or
    die "Can't change clip directory after first clip, stopped";
  
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
  
  # Store the new source directory
  @src_dir = ($sname, $arg_vext, $arg_dext);
}

=item B<tundra_film_clip(name, fade_in, fade_out)>

Declare a clip that should be added to the end of the current movie.

The source directory must already be set with C<tundra_film_src()>
before calling this function.  After this function has been called for
the first time, the source directory can no longer be changed.

B<name> is the name of the clip asset.  It must be a sequence of one or
more lowercase ASCII letters, ASCII decimal digits, and/or ASCII
underscores.  It does NOT include the extension.  The specified asset
must exist in the clip source directory, both as a video file and as a
clip descriptor file.

B<fade_in> and B<fade_out> are the number of frames for a fade-in and a
fade-out, respectively, to apply to the clip when assembled into the
movie.  Both must be integer values that are zero or greater.  A value
of zero disables the respective fade, and specifying zero values for
both completely disables any fading effects.  The sum of the two fade
frame counts must not exceed the total number of frames in the clip, as
determined by the frame count in the video descriptor file for the clip.

=cut

sub tundra_film_clip {
  # Should have exactly three arguments
  ($#_ == 2) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_name     = shift;
  my $arg_fade_in  = shift;
  my $arg_fade_out = shift;
  
  # Set argument types
  $arg_name  = "$arg_name";
  $arg_fade_in  = int($arg_fade_in);
  $arg_fade_out = int($arg_fade_out);
  
  # Check arguments
  ($arg_name =~ /^[a-z0-9_]+$/a) or
    die "Asset name '$arg_name' is invalid, stopped";
  
  (($arg_fade_in >= 0) and ($arg_fade_out >= 0)) or
    die "Fade frame counts must not be negative, stopped";
  
  # Check that source directory has been declared
  ($#src_dir >= 0) or
    die "Declare clip source directory before adding clips, stopped";
  
  # Get paths to the descriptor and video files
  my @c_comp = split /\//, $src_dir[0];
  my $base_path = File::Spec->catfile(@c_comp, $arg_name);
  
  my $dpath = $base_path . '.' . $src_dir[2];
  my $vpath = $base_path . '.' . $src_dir[1];
  
  # Make sure descriptor and video files exist
  (-f $vpath) or
    die "Video file '$vpath' does not exist, stopped";
  (-f $dpath) or
    die "Descriptor file '$dpath' does not exist, stopped";
  
  # Read the first line from the descriptor file, making sure that there
  # is exactly one line at the start of the file and any subsequent
  # lines are blank
  my @dfile;
  tie @dfile, 'Tie::File', $dpath, mode => O_RDONLY or
    die "Failed to tie descriptor file '$dpath', stopped";
  
  ($#dfile >= 0) or
    die "Descriptor file '$dpath' is empty, stopped";
  
  if ($#dfile > 0) {
    for (my $i = 1; $i <= $#dfile; $i++) {
      ($dfile[$i] =~ /^\s*$/a) or
        die "Descriptor file '$dpath' has multiple lines, stopped";
    }
  }
  
  my $dline = $dfile[0];
  untie @dfile;
  
  # Split the first line of the descriptor file and get exactly three
  # field values
  my @dfields = split " ", $dline;
  ($#dfields == 2) or
    die "Descriptor '$dpath' has invalid syntax, stopped";
  
  my $df_name  = $dfields[0];
  my $df_start = $dfields[1];
  my $df_count = $dfields[2];
  
  # Check descriptor fields values
  ($df_name =~ /^[a-z0-9_]+$/a) or
    die "Descriptor '$dpath' contains invalid name, stopped";
  (($df_start =~ /^[0-9]+$/a) and ($df_count =~ /^[0-9]+$/a)) or
    die "Descriptor '$dpath' contains invalid integers, stopped";
  
  # Convert integer values and check range
  $df_start = int($df_start);
  $df_count = int($df_count);
  ($df_count > 0) or
    die "Descriptor '$dpath' contains invalid count, stopped";
  
  # Check that frame count in descriptor is at least as large as the sum
  # of the fade frames
  ($df_count >= $arg_fade_in + $arg_fade_out) or
    die "Clip '$arg_name' has too much fading, stopped";
  
  # Add the clip to the movie
  push @movie, ([
                  $arg_name,
                  $df_name,
                  $df_start,
                  $df_count,
                  $arg_fade_in,
                  $arg_fade_out]);
}

=item B<tundra_film_clean(dir, prfx, ext)>

Remove any intermediate files from a given directory.

B<dir> is the directory, relative to the current directory, that should
be cleaned.  It must consist of a sequence of one or more lowercase
ASCII letters, ASCII decimal digits, ASCII underscores, and/or ASCII
forward slashes.  Forward slash may neither be first nor last character,
and forward slash may not directly precede or follow another forward
slash.  The directory must already exist.

The forward slash in the directory name will be changed to the
platform-specific directory separator if necessary.

B<prfx> is the prefix that was used for naming intermediate files that
should be cleaned.  Intermediate video files will have names that are
this prefix concatenated with a sequence of one or more decimal digits.
The prefix must be a sequence of one or more lowercase ASCII letters,
ASCII decimal digits, and/or ASCII underscores.

B<ext> is the file extension of the intermediate files, not including
the opening dot of the file extension.  It must consist of a sequence of
one or more lowercase ASCII letters, ASCII decimal digits, ASCII
underscores, and/or ASCII dots.  Dots may neither be first nor last
character, and dot may not directly precede or follow another dot.

This function will iterate through all files in the given directory.
This iteration is not recursive, so subdirectories are not entered.  Any
iterated files that are regular files and have the given prefix followed
by one or more decimal digits followed by the given file extension will
be deleted by this function.

=cut

sub tundra_film_clean {
  # Should have exactly three arguments
  ($#_ == 2) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_dir  = shift;
  my $arg_prfx = shift;
  my $arg_ext  = shift;
  
  # Set argument types
  $arg_dir  = "$arg_dir";
  $arg_prfx = "$arg_prfx";
  $arg_ext  = "$arg_ext";
  
  # Check arguments
  (($arg_dir =~ /^[a-z0-9_\/]+$/a) and not (
    ($arg_dir =~ /^\//a) or
    ($arg_dir =~ /\/$/a) or
    ($arg_dir =~ /\/\//a)
  )) or
    die "Directory name '$arg_dir' invalid, stopped";
  
  ($arg_prfx =~ /^[a-z0-9_]+$/a) or
    die "Prefix name '$arg_prfx' is invalid, stopped";
  
  (($arg_ext =~ /^[a-z0-9_\.]+$/a) and not (
    ($arg_ext =~ /^\./a) or
    ($arg_ext =~ /\.$/a) or
    ($arg_ext =~ /\.\./a)
  )) or
    die "Extension name '$arg_ext' invalid, stopped";
  
  # If there is any "/" character in the directory name, split by
  # separator and rebuild appropriately for platform
  my @dir_comp = split /\//, $arg_dir;
  if ($#dir_comp > 0) {
    $arg_dir = File::Spec->catdir(@dir_comp);
  }
  
  # Make sure directory exists
  (-d $arg_dir) or
    die "Directory '$arg_dir' does not exist, stopped";
  
  # Iterate through directory and build a list of all intermediate file
  # names
  my @ilist = ();
  my $dh;
  opendir($dh, $arg_dir) or
    die "Can't iterate directory '$arg_dir', stopped";
  
  for my $f (readdir $dh) {
    if ($f =~ /^$arg_prfx[0-9]+\.$arg_ext$/) {
      push @ilist, ($f);
    }
  }
  
  closedir $dh;
  
  # Delete any intermediate files
  for my $i (@ilist) {
    
    # Build path to this file
    my $ipath = File::Spec->catfile(@dir_comp, $i);
    
    # If intermediate file exists as regular file, delete it
    if (-f $ipath) {
      unlink($ipath);
    }
  }
}

=item B<tundra_film_build(dir, name, prfx, vext, mext, opt, maxc)>

Assemble a full movie video from the declared clips.

You must declare at least one clip with C<tundra_film_clip()> before
calling this function.

B<dir> is the directory, relative to the current directory, in which the
assembled video file will be built.  It must consist of a sequence of
one or more lowercase ASCII letters, ASCII decimal digits, ASCII
underscores, and/or ASCII forward slashes.  Forward slash may neither be
first nor last character, and forward slash may not directly precede or
follow another forward slash.  The directory must already exist.

B<name> is the name of the assembled video file to build.  It must be a
sequence of one or more lowercase ASCII letters, ASCII decimal digits,
and/or ASCII underscores.  It does NOT include the extension.

B<prfx> is the prefix to use for naming intermediate video files.
Intermediate video files will have names that are this prefix
concatenated with a sequence of one or more decimal digits.  The prefix
must be a sequence of one or more lowercase ASCII letters, ASCII decimal
digits, and/or ASCII underscores.  It should be such that a generated
intermediate name will never conflict with the assembled video file
name.

B<vext> and B<mext> are the file extensions of video files and the map
file to generate in the build directory, not including the opening dot
of the file extension.  They must consist of a sequence of one or more
lowercase ASCII letters, ASCII decimal digits, ASCII underscores, and/or
ASCII dots.  Dots may neither be first nor last character, and dot may
not directly precede or follow another dot.  The two extensions may not
be the same.

B<opt> is FFMPEG encoding options.  If an empty string, there are no
encoding options.  Otherwise, the string is split with whitespace
separators and passed as options before the output file when invoking
FFMPEG.

B<maxc> is the maximum number of video clips that will be joined
together in a single ffmpeg invocation.  It must be an integer that is
two or greater.  The build function will split the assembly process into
multiple ffmpeg invocations if necessary to stay underneath this limit.
Intermediate files will be created as necessary using the prefix given
by B<prfx> along with a unique index.

Intermediate files that already exist will be deleted at the start of
this operation and at the end.  However, if an error occurs,
intermediate files may be left over.

The final video file will be deleted if it already exists at the start
of the call, as will the map file.

The map file is a text file containing one line for each clip in the
assembled movie.  The line contains five fields, separated by spaces.
The first field is the name of the asset that the clip was taken from.
The second field is the starting frame offset within the source asset.
The third field is the number of frames in the clip.  The fourth and
fifth fields are the number of frames for a fade-in and a fade-out that
were applied, respectively.  All fields after the first one are unsigned
decimal integers.

The map file is intended to make it possible to synchronize audio from
the original clips with the generated full movie.

=cut

sub tundra_film_build {
  # Should have exactly seven arguments
  ($#_ == 6) or die "Wrong number of arguments, stopped";
  
  # Get the arguments
  my $arg_dir  = shift;
  my $arg_name = shift;
  my $arg_prfx = shift;
  my $arg_vext = shift;
  my $arg_mext = shift;
  my $arg_opt  = shift;
  my $arg_maxc = shift;
  
  # Set argument types
  $arg_dir  = "$arg_dir";
  $arg_name = "$arg_name";
  $arg_prfx = "$arg_prfx";
  $arg_vext = "$arg_vext";
  $arg_mext = "$arg_mext";
  $arg_opt  = "$arg_opt";
  $arg_maxc = int($arg_maxc);
  
  # Check arguments
  (($arg_dir =~ /^[a-z0-9_\/]+$/a) and not (
    ($arg_dir =~ /^\//a) or
    ($arg_dir =~ /\/$/a) or
    ($arg_dir =~ /\/\//a)
  )) or
    die "Directory name '$arg_dir' invalid, stopped";
  
  ($arg_name =~ /^[a-z0-9_]+$/a) or
    die "Asset name '$arg_name' is invalid, stopped";
  
  ($arg_prfx =~ /^[a-z0-9_]+$/a) or
    die "Prefix name '$arg_prfx' is invalid, stopped";
  
  (($arg_vext =~ /^[a-z0-9_\.]+$/a) and not (
    ($arg_vext =~ /^\./a) or
    ($arg_vext =~ /\.$/a) or
    ($arg_vext =~ /\.\./a)
  )) or
    die "Extension name '$arg_vext' invalid, stopped";
  
  (($arg_mext =~ /^[a-z0-9_\.]+$/a) and not (
    ($arg_mext =~ /^\./a) or
    ($arg_mext =~ /\.$/a) or
    ($arg_mext =~ /\.\./a)
  )) or
    die "Extension name '$arg_mext' invalid, stopped";
  
  ($arg_vext ne $arg_mext) or
    die "Video and descriptor extensions must be different, stopped";
  
  ($arg_maxc >= 2) or
    die "Concat limit must be at least two, stopped";
  
  # Check that at least one clip has been declared
  ($#movie >= 0) or
    die "Must declare at least one clip before building, stopped";
  
  # Store the original directory name
  my $dir_name = $arg_dir;
  
  # If there is any "/" character in the directory name, split by
  # separator and rebuild appropriately for platform
  my @dir_comp = split /\//, $arg_dir;
  if ($#dir_comp > 0) {
    $arg_dir = File::Spec->catdir(@dir_comp);
  }
  
  # Check that build directory exists
  (-d $arg_dir) or
    die "Build directory '$arg_dir' does not exist, stopped";
  
  # Clean the directory of intermediate files
  tundra_film_clean($dir_name, $arg_prfx, $arg_vext);
  
  # Determine paths to final video file and map file
  my $final_base = File::Spec->catfile(@dir_comp, $arg_name);
  my $final_video = $final_base . '.' . $arg_vext;
  my $final_map = $final_base . '.' . $arg_mext;
  
  # Delete final video and map if they exist
  if (-f $final_video) {
    unlink($final_video);
  }
  if (-f $final_map) {
    unlink($final_map);
  }
  
  # Generate the map file
  my @mfile;
  tie @mfile, 'Tie::File', $final_map or
    die "Failed to tie map file '$final_map', stopped";
  
  $#mfile = -1;
  for my $c (@movie) {
    my $mline = $c->[1] .
                  ' ' . $c->[2] .
                  ' ' . $c->[3] .
                  ' ' . $c->[4] .
                  ' ' . $c->[5];
    push @mfile, ($mline);
  }
  
  untie @mfile;
  
  # Start the intermediate file counter at zero
  my $ifcount = 0;
  
  # Get the source directory components
  my @src_comp = split /\//, $src_dir[0];
  
  # Extract video encoding options
  my @v_olist = ();
  if (length $arg_opt > 0) {
    @v_olist = split " ", $arg_opt;
  }
  
  # Build a list of all clips that have to be concatenated; any clips
  # that have any sort of fading will generate an intermediate file with
  # fading during this operation, and any clips that do not have fading
  # but are a duplicate of a clip that was already used will be copied
  # to an intermediate file (to prevent any single file from being used
  # more than once in any ffmpeg invocation)
  my @clips = ();
  my %clip_names;
  for my $c (@movie) {
    # Get the path to the source clip
    my $cpath = File::Spec->catfile(@src_comp, $c->[0]);
    $cpath = $cpath . '.' . $src_dir[1];
    
    # Check for cases
    if (($c->[4] > 0) or ($c->[5] > 0)) {
      # Fading effects present -- increment intermediate file counter to
      # get an ID for the new intermediate file
      $ifcount++;
      
      # Get the path to the intermediate file
      my $ipath = File::Spec->catfile(@dir_comp, $arg_prfx);
      $ipath = $ipath . "$ifcount." . $arg_vext;
      
      # Determine duration strings in 25fps for applicable fades
      my $fade_in_dur    = 0;
      my $fade_out_start = 0;
      my $fade_out_dur   = 0;
      
      if ($c->[4] > 0) {
        my $fade_in_dur_i = int($c->[4] / 25);
        my $fade_in_dur_f = int($c->[4] % 25) * 4;
        if ($fade_in_dur_f < 10) {
          $fade_in_dur = "$fade_in_dur_i.0$fade_in_dur_f";
        } else {
          $fade_in_dur = "$fade_in_dur_i.$fade_in_dur_f";
        }
      }
      
      if ($c->[5] > 0) {
        my $fade_out_start_i = int(($c->[3] - $c->[5]) / 25);
        my $fade_out_start_f = int(($c->[3] - $c->[5]) % 25) * 4;
        
        my $fade_out_dur_i = int($c->[5] / 25);
        my $fade_out_dur_f = int($c->[5] % 25) * 4;
        
        if ($fade_out_start_f < 10) {
          $fade_out_start = "$fade_out_start_i.0$fade_out_start_f";
        } else {
          $fade_out_start = "$fade_out_start_i.$fade_out_start_f";
        }
        
        if ($fade_out_dur_f < 10) {
          $fade_out_dur = "$fade_out_dur_i.0$fade_out_dur_f";
        } else {
          $fade_out_dur = "$fade_out_dur_i.$fade_out_dur_f";
        }
      }
      
      # Build the FFMPEG filter chain for fading
      my $fchain_fade = '';
      if ($c->[4] > 0) {
        $fchain_fade = 'fade=t=in:d=' . $fade_in_dur;
      }
      if ($c->[5] > 0) {
        if (length $fchain_fade > 0) {
          $fchain_fade = $fchain_fade . ', ';
        }
        $fchain_fade = $fchain_fade . 'fade=t=out:st='
                        . $fade_out_start . ':d=' . $fade_out_dur;
      }
      
      # Build ffmpeg command
      my @f_cmd = (
                    '-i'     , $cpath,
                    '-filter', $fchain_fade);
      push @f_cmd, @v_olist;
      push @f_cmd, ($ipath);
      
      # Invoke ffmpeg
      invoke_ffmpeg(@f_cmd) or
        die "Fading invocation failed, stopped";
      
      # Add the intermediate file path to the clip list
      push @clips, ($ipath);
      
    } elsif (exists $clip_names{$c->[0]}) {
      # No fades, but clip already used -- increment intermediate file
      # counter to get an ID for the new intermediate file
      $ifcount++;
      
      # Get the path to the target intermediate file
      my $tpath = File::Spec->catfile(@dir_comp, $arg_prfx);
      $tpath = $tpath . "$ifcount." . $arg_vext;
      
      # Copy from source clip to target intermediate file
      copy($cpath, $tpath) or
        die "Intermediate file copy $cpath -> $tpath failed, stopped";
      
      # Add the intermediate file path to the clip list
      push @clips, ($tpath);
      
    } else {
      # No fades and clip not already used, so begin by adding it to the
      # hash so further use of the clip will trigger a copy
      $clip_names{$c->[0]} = 1;
      
      # Add the path to the clip to the list
      push @clips, ($cpath);
    }
  }
  
  # Perform merge passes until everything has been merged down to a
  # single clip
  while ($#clips > 0) {
    
    # Make a new merged list
    my @new_clips;
    while ($#clips >= 0) {
      # Check how many clips remain
      if ($#clips < 1) {
        # Only a single clip remains, so just add it to the new clip
        # list
        push @new_clips, (shift @clips);
        
      } elsif ($#clips < $arg_maxc) {
        # Multiple clips remain but they are within the merge limit, so
        # concatenate all the of them into a new intermediate file
        $ifcount++;
        
        my $ipath = File::Spec->catfile(@dir_comp, $arg_prfx);
        $ipath = $ipath . "$ifcount." . $arg_vext;
        
        cat_video($arg_opt, $ipath, @clips);
        push @new_clips, ($ipath);
        @clips = ();
        
      } else {
        # More clips remain than the merge limit, so merge together a
        # block the size of the merge limit
        my @m_clips = ();
        for (my $i = 0; $i < $arg_maxc; $i++) {
          push @m_clips, (shift @clips);
        }
        
        $ifcount++;
        
        my $ipath = File::Spec->catfile(@dir_comp, $arg_prfx);
        $ipath = $ipath . "$ifcount." . $arg_vext;
        
        cat_video($arg_opt, $ipath, @m_clips);
        push @new_clips, ($ipath);
      }
    }
    
    # Transfer all the new merged clips into the clip list
    push @clips, @new_clips;
  }
  
  # Move the remaining clip into the final video path
  move($clips[0], $final_video);
  
  # Clean the directory of intermediate files
  tundra_film_clean($dir_name, $arg_prfx, $arg_vext);
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
