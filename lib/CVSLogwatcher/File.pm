#=============================================================================
# File operations // This module loads given text file into memory upon
# instantiation and then offers a set of operations that can be performed on the
# file.
#=============================================================================

package CVSLogwatcher::File;

use Moo;
use warnings;
use strict;
use experimental 'signatures', 'postderef';

use Feature::Compat::Try;
use Path::Tiny qw(path tempdir);

# file to be handled; either Path::Tiny instance or scalar pathname that gets
# converted into Path::Tiny instance
has file => (
  is => 'rw', required => 1,
  coerce => sub ($f) { ref $f ? $f : path($f) },
);

# contents of the file as an array of text lines, this will be automatically
# lazy-loaded from the specified file; this automatic load can be inhibited
# by specifying the content explicitly
has content => ( is => 'rwp', lazy => 1, builder => 1 );

# size of the file before any of the transform operations
has prev_size => ( is => 'rwp', default => 0 );

#------------------------------------------------------------------------------
# Load file content into memory. If the file is RCS/git file, the head is
# checked out and read instead of just reading it.
sub _build_content ($self)
{
  my $cfg = CVSLogwatcher::Config->instance;
  my $f = $self->file->stringify;
  my @fc;

  # plain gzipped file
  if($self->is_gzip_file) {
    open(my $fh, '-|', "gzip -cdk $f") or die "Could not read gzipped file '$f' ($!)";
    @fc = <$fh>;
    close($fh);
  }

  # plain file
  else {
    open(my $fh, '<', $f) or die "Could not read plain file '$f' ($!)";
    @fc = <$fh>;
    close($fh);
  }

  return \@fc;
}

#------------------------------------------------------------------------------
# Set new filename (only filename, not path)
sub set_filename ($self, $filename)
{
  $filename = path($filename)->basename;
  $self->file($self->file->sibling($filename));
}

#------------------------------------------------------------------------------
# Set location of the file (filename itself remains unchanged); this function
# is complementary to set_filename.
sub set_path ($self, $path)
{
  $self->file(
    path($path)->child($self->file->basename)
  );
}

#------------------------------------------------------------------------------
# Return true if our file is a GZIP
sub is_gzip_file ($self)
{
  return undef if !$self->file;
  $self->file->basename =~ /\.gz$/;
}

#------------------------------------------------------------------------------
# Return number of lines of text in the file
sub count ($self) { scalar @{$self->content} }

#------------------------------------------------------------------------------
# Return size of the file in bytes
sub size ($self, $set = 0)
{
  use bytes;
  my $size = 0;
  foreach my $l ($self->content->@*) { $size += length($l) }
  $self->_set_prev_size($size) if $set;
  return $size;
}

#------------------------------------------------------------------------------
# Return size change compared to last saved size (size decrease is positive,
# increase is negative)
sub size_change ($self) { return $self->prev_size - $self->size }

#------------------------------------------------------------------------------
# Extract hostname if regex defined, otherwise return undef;
sub extract_hostname ($self, @regexes)
{
  foreach my $re (@regexes) {
    foreach (@{$self->content}) {
      if(/$re/) { return $1 }
    }
  }
  return undef;
}

#------------------------------------------------------------------------------
# Convert EOLs to local representation
sub normalize_eol ($self)
{
  $self->size(1);
  foreach my $l ($self->content->@*) {
    $l =~ s/\R//;
    $l = $l . "\n";
  }
  return $self->size_change;
}

#------------------------------------------------------------------------------
# implement 'validrange' option, that is strip junk outside of a range of
# two regexes; the matching lines themselves are not removed
sub validrange ($self, $in, $out=undef)
{
  # initialize
  my @new;
  my $in_range = defined $in ? 0 : 1;
  $self->size(1);

  # iterate over lines of content
  foreach my $l (@{$self->content}) {
    $in_range = 1 if $in_range == 0 && $l =~ /$in/;
    push(@new, $l) if $in_range == 1;
    $in_range = 2 if $in_range == 1 && $out && $l =~ /$out/;
  }

  # finish
  $self->_set_content(\@new);
  return $self->size_change;
}

#------------------------------------------------------------------------------
# This function implements the 'filter' option, which throws out any line that
# matches any of the list of regexes
sub filter ($self, @filters)
{
  # init
  my @new;
  $self->size(1);

  # iterate over lines of content
  foreach my $l ($self->content->@*) {
    push(@new, $l) unless grep { $l =~ /$_/ } @filters;
  }

  # finish
  $self->_set_content(\@new);
  return $self->size_change;
}

#------------------------------------------------------------------------------
# This function implements the 'validate' option and returns true only when
# each of the regexes in the list are matched at least once. If the list is
# not defined or empty, this function returns true as well.
sub validate ($self, @regexes)
{
  # implicitly valid: return true when the list is empty
  return 1 if !@regexes;

  # match every line against all prefixes, remove from the list on match;
  foreach my $l ($self->content->@*) {
    @regexes = grep { $l !~ /$_/ } @regexes;
    last if !@regexes;
  }

  # finish
  return !@regexes;
}

#-------------------------------------------------------------------------------
# content iterator factory for the purpose of comparison of contents; it accepts
# callback which can be used to exclude certain lines from comparison
sub content_iter_factory ($self, $ignore_cb=undef)
{
  my $i = 0;

  return sub {
    # return undef if the iteration is over
    return undef unless $i < $self->content->@*;
    # skip ignored lines
    $i++ while
    (
      $i < $self->content->@*
      && $ignore_cb
      && $ignore_cb->($self->content->[$i])
    );

    # if the while loop skipped all the way to the end
    return undef unless $i < $self->content->@*;

    # return non-ignored line
    return $self->content->[$i++];
  }
}

#------------------------------------------------------------------------------
# Compare content of this file with another file (passed in as CVSL::File
# instance)
sub is_changed ($this_file, $other_file)
{
  # the files have unequal line counts, return 'changed'
  return 1 if $this_file->count != $other_file->count;

  # get iterators
  my $it_this = $this_file->content_iter_factory;
  my $it_other = $other_file->content_iter_factory;

  # go through the files' content and compare each line
  while(1) {
    my $l1 = $it_this->();
    my $l2 = $it_other->();
    return undef unless defined $l1 && defined $l2;
    return 1 if $l1 ne $l2;
  }
}

#------------------------------------------------------------------------------
# Save the current content into a file. Either current file is used, but
# different target can optionally be specified. This is only for saving plain
# files, not RCS repositories; use 'check_in' method instead.
sub save ($self, $dest_file = undef)
{
  # no gzip files at the moment
  die 'Gzip files not supported for saving' if $self->is_gzip_file;

  # get the destination file
  $dest_file = $dest_file ? path $dest_file : $self->file;

  # write target file
  open(my $fh, '>', "$dest_file.$$")
  or die "Could not open $dest_file for writing";
  foreach ($self->content->@*) { print $fh $_ }
  close($fh);
  rename("$dest_file.$$", $dest_file)
  or "die Failed to rename file $dest_file";
}

#------------------------------------------------------------------------------
# Delete the file
sub remove ($self)
{
  # make sure the content is loaded from the file before removing
  $self->content;

  # remove the source file
  $self->file->remove
}

1;
