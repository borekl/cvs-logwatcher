package CVSLogwatcher::Repo;

# base class for implementing actual repository types

use Moo;
use warnings;
use strict;
use experimental 'signatures', 'postderef';

use Path::Tiny qw(path);

# repository's base directory
has base => (
  is => 'ro', required  => 1,
  coerce => sub ($f) { ref $f ? $f : path($f) },
);

#-------------------------------------------------------------------------------
# returns true if the specified file is within the repository directory tree;
# the 'file' argument can be either plain pathname or CVSLogwatcher::File
# instance; this is just rewrapped 'subsumes' method from Path::Tiny
sub subsumes($self, $file)
{
  $file = $file->file if $file->isa('CVSLogwatcher::File');
  $file = path $file unless $file->isa('Path::Tiny');
  die q{Relative path in 'subsumes'} unless $file->is_absolute;
  return $self->base->subsumes($file);
}

#-------------------------------------------------------------------------------
# return file's path relative to the repository base directory
sub get_relative($self, $file)
{
  $file = $file->file if $file->isa('CVSLogwatcher::File');
  $file = path $file unless $file->isa('Path::Tiny');

  # if file already is relative, there's nothing to do
  return $file if $file->is_relative;

  # make sure the file is under a repository base
  die 'Not a repository file' unless $self->subsumes($file);

  # return relative path
  return $file->relative($self->base);
}

1;
