#=============================================================================
# File operations
#=============================================================================

package CVSLogwatcher::File;

use Moo;
use warnings;
use strict;
use experimental 'signatures', 'postderef';

use Path::Tiny qw(path tempdir);

# file to be handled; either Path::Tiny instance or scalar pathname that gets
# converted into Path::Tiny instance
has file => (
  is => 'ro', required => 1,
  coerce => sub ($f) { ref $f ? $f : path $f },
);

# CVSLogwatcher::Target instance
has target => ( is => 'ro', required => 1 );

# contents of the file as an array of text lines, this will be automatically
# lazy-loaded from the specified file
has content => ( is => 'rwp', lazy => 1, builder => 1 );

#------------------------------------------------------------------------------
# Load file content into memory. If the file is RCS file, the head is checked
# out and read instead of just reading it
sub _build_content ($self)
{
  my $cfg = CVSLogwatcher::Config->instance;
  my $f = $self->file->stringify;
  my $fh;

  if($self->is_rcs_file) {
    my $exec = sprintf('%s -q -p %s', $cfg->rcs('rcsco'), $f);
    open($fh, '-|', "$exec 2>/dev/null")
    or die "Could not get latest revision from '$exec'";
  } else {
    open($fh, '<', $f) or die "Could not open file '$f'"
    or die "Could not open file '$f'";
  }
  my @fc = <$fh>;
  close($fh);

  return \@fc;
}

#------------------------------------------------------------------------------
# Return true if our file is an RCS file
sub is_rcs_file ($self) { $self->file->basename =~ /,v$/ }

#------------------------------------------------------------------------------
# Return number of lines of text in the file
sub count ($self) { scalar @{$self->content} }

#------------------------------------------------------------------------------
# Extract hostname if regex defined, otherwise return undef;
sub extract_hostname ($self)
{
  # get extraction regex
  my $re = $self->target->config->{hostname} // undef;
  return undef unless $re;

  # try to find and extract hostname
  foreach (@{$self->content}) {
    if(/$re/) { return $1 }
  }

  # nothing was found
  return undef;
}

#------------------------------------------------------------------------------
# Convert EOLs to local representation
sub normalize_eol ($self)
{
  foreach my $l (@{$self->content}) {
    $l =~ s/\R//;
    $l = $l . "\n";
  }
}

#------------------------------------------------------------------------------
# Implement 'validrange' option, that is strip junk outside of a range of
# two regexes.
sub validrange ($self)
{
  my @new;

  # do nothing unless 'validrange' option is properly specified
  return $self unless
    exists $self->target->config->{validrange}
    && ref $self->target->config->{validrange}
    && @{$self->target->config->{validrange}} == 2;

  # initialize
  my ($in, $out) = @{$self->target->config->{validrange}};
  my $in_range = defined $in ? 0 : 1;

  # iterate over lines of content
  foreach my $l (@{$self->content}) {
    $in_range = 1 if $in_range == 0 && $l =~ /$in/;
    push(@new, $l) if $in_range == 1;
    $in_range = 2 if $in_range == 1 && $out && $l =~ /$out/;
  }

  # finish
  $self->_set_content(\@new);
  return $self;
}

#------------------------------------------------------------------------------
# This function implements the 'filter' option, which throws out any line that
# matches any of the list of regexes
sub filter ($self)
{
  my @new;

  # do nothing unless 'filter' option is properly specified
  return $self unless
    exists $self->target->config->{filter}
    && ref $self->target->config->{filter}
    && @{$self->target->config->{filter}};

  # filter list
  my @filters = @{$self->target->config->{filter}};

  # iterate over lines of content
  foreach my $l (@{$self->content}) {
    push(@new, $l) unless grep { $l =~ /$_/ } @filters;
  }

  # finish
  $self->_set_content(\@new);
  return $self;
}

#------------------------------------------------------------------------------
# This function implements the 'validate' option and returns true only when
# each of the regexes in the list are matched at least once. If the list is
# not defined or empty, this function returns true as well.
sub validate ($self)
{
  # implicit success if 'filter' option is not properly specified
  return 1 unless
    exists $self->target->config->{validate}
    && ref $self->target->config->{validate}
    && @{$self->target->config->{validate}};

  # list of validation regexes
  my @regexes = @{$self->target->config->{validate}};

  # iterate over lines of content
  foreach my $l (@{$self->content}) {
    @regexes = grep { $l !~ /$_/ } @regexes;
    last if !@regexes;
  }

  # finish
  return @regexes == 0;
}

#------------------------------------------------------------------------------
# Content iterator factory for the purpose of comparison of contents. It honors
# the 'ignoreline' argument and skips ignored lines
sub content_iter_factory ($self)
{
  my $i = 0;

  return sub {
    return undef unless $i < @{$self->content};
    $i++ while $self->target->is_ignored($self->content->[$i]);
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
  # not valid for RCS files
  die 'Cannot save into RCS repostiory' if $self->is_rcs_file;

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
# Check the curent file into an RCS file. Since RCS does not allow us take the
# input file from stdin, we must go through a file in temporary directory.
sub rcs_check_in ($self, %arg)
{
  my $cfg = CVSLogwatcher::Config->instance;
  my $logger = $cfg->logger;
  my $tid = $self->target->id;

  # get base filename
  my $base = $self->file->basename(',v');

  # get temporary file (in temporary directory)
  my $tempdir = tempdir;
  my $tempfile = $tempdir->child($base);
  $tempfile->spew_raw($self->content->@*);

  # get repo filename
  my $repo = path($arg{repo})->child($base . ',v');
  my $is_new = !$repo->exists;

  # execute RCS ci to check-in new commit
  my @exec = (
    $cfg->rcs('rcsci'),
    '-q',                  # quiet mode
    '-w' . $arg{who},      # commiter name
    '-m' . $arg{msg},      # commit message
    '-t-' . $arg{host},    # "descriptive text"
    $tempfile->stringify,  # source file
    $repo->stringify       # RCS file
  );
  $logger->debug("[cvs/$tid] Cmd: ", join(' ', @exec));
  my $rv = system(@exec);
  die "RCS check-in failed ($rv)" if $rv;

  # set soft-locking mode if the file is new (initial commit)
  if($is_new) {
    @exec = (
      $cfg->rcs('rcsctl'),
      '-q', '-U',
      $repo->stringify
    );
    $logger->debug("[cvs/$tid] Cmd: ", join(' ', @exec));
    $rv = system(@exec);
    die "Failed to set RCS locking mode ($rv)" if $rv;
  }
}

#------------------------------------------------------------------------------
# Delete the file
sub remove ($self) { $self->file->remove }

1;
