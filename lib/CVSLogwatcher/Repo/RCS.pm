package CVSLogwatcher::Repo::RCS;

# handling RCS repositories; note that RCS repository is simply a directory of
# individual RCS files, RCS doesn't really have a concept of repository, that's
# what CVS is for

use Moo;
extends 'CVSLogwatcher::Repo';
use experimental 'signatures';

use Path::Tiny;

#-------------------------------------------------------------------------------
# returns true when 'file' exists in directory specified by 'dir_in_repo'; only
# filename is used from 'file', any path is ignored
sub is_repo_file ($self, $file, $dir_in_repo='.')
{
  # process arguments
  $file = $file->file if $file->isa('CVSLogwatcher::File');
  $file = path($file)->basename(',v');
  $dir_in_repo = $self->get_relative($dir_in_repo);

  # evaluate
  my $file_rcs = $self->base->child($dir_in_repo, $file . ',v');
  return undef unless $file_rcs->is_file;
  return 1;
}

#-------------------------------------------------------------------------------
# commit supplied file (must be CVSL::File instance) to the repository;
# target_dir must be a relative directory and is where the file is put; 'host'
# 'msg' and 'who' arguments must be provided
sub commit_file ($self, $file, $target_dir, %arg)
{
  my $cfg = CVSLogwatcher::Config->instance;
  my $is_new = !$self->is_repo_file($file, $target_dir);

  # supplied file must be CVSLogwatcher::File instance
  die 'Argument to commit_file must be a CVSL::File instance'
    unless $file->isa('CVSLogwatcher::File');
  my $file_target = $file->file;

  # verify validity of target_dir
  $target_dir = path($target_dir);
  die "Target dir must be relative"
    unless $target_dir->is_relative;
  die "Target dir '$target_dir' not found in '" . $self->base . "'"
    unless $self->base->child($target_dir)->is_dir;

  # get bare filename
  my $base = $file->file->basename(',v');

  # get temporary file (in temporary directory) since rcs cannot commit from
  # pipe or memory buffer
  my $tempdir = Path::Tiny->tempdir;
  my $tempfile = $tempdir->child($base);
  $tempfile->spew_raw($file->content->@*);

  # target file, ie. the file in the repository
  $file_target = $self->base->child($target_dir, $base);

  # execute RCS ci to check-in new commit
  my @exec = (
    $cfg->rcs('rcsci'),
    '-q',                  # quiet mode
    '-w' . $arg{who},      # commiter name
    '-m' . $arg{msg},      # commit message
    '-t-' . $arg{host},    # "descriptive text"
    $tempfile,             # source file
    $file_target . ',v'    # RCS file
  );
  my $rv = system(@exec);
  die "RCS check-in failed ($rv)" if $rv;

  # set soft-locking mode if the file is new (initial commit)
  if($is_new) {
    @exec = (
      $cfg->rcs('rcsctl'),
      '-q', '-U',
      $file_target
    );
    $rv = system(@exec);
    die "Failed to set RCS locking mode ($rv)" if $rv;
  }
}

#-------------------------------------------------------------------------------
# check out a file from the repo; returns a CVSLogwatcher::File instance; the
# 'file' can be relative pathname, in which case it is taken to be relative to
# the repository base path
sub checkout_file($self, $file, $dir_in_repo='.')
{
  my $cfg = CVSLogwatcher::Config->instance;
  $file = $file->file if $file->isa('CVSLogwatcher::File');

  # verify
  die "'$file' not a repository file, cannot check out"
    unless $self->is_repo_file($file, $dir_in_repo);

  # perform checkout
  my $file_rcs = $self->base->child($dir_in_repo, $file->basename);
  my $exec = sprintf('%s -q -p %s', $cfg->rcs('rcsco'), $file_rcs);
  open(my $fh, '-|', "$exec 2>/dev/null")
  or die "Could not get latest revision from '$exec'";
  my @fc = <$fh>;
  close($fh);
  return CVSLogwatcher::File->new(file => $file, content => \@fc);
}

1;
