#=============================================================================
# File operations
#=============================================================================

package CVSLogwatcher::File;

use Moo;
use warnings;
use strict;
use experimental 'signatures';

use Path::Tiny;

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

1;
