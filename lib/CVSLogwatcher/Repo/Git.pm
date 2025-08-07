package CVSLogwatcher::Repo::Git;

# handling git repositories

use v5.36;
use Moo;
extends 'CVSLogwatcher::Repo';

use Feature::Compat::Try;
use Path::Tiny;
use Git::Raw;

use CVSLogwatcher::File;

# Git::Raw instance
has git => ( is => 'lazy' );
has name => ( is => 'ro', default => 'CVS' );
has email => ( is => 'ro', default => 'none@none' );

#-------------------------------------------------------------------------------
# initialize or open git repository
sub _build_git ($self)
{
  # check that the base directory exists
  my $base = $self->base;
  die "Git repository directory '$base' not found" unless -d $base;

  # open git repository, initialize if needed
  my $git;
  try {
    $git = Git::Raw::Repository->open($base);
  } catch ($e) {
    if($e =~ /^could not find repository/i) {
      $git = Git::Raw::Repository->init($base, 0);
    } else {
      die $e;
    }
  }

  # finish
  return $git;
};

#-------------------------------------------------------------------------------
# returns true when 'file' exists in directory specified by 'dir_in_repo'; only
# filename is used from 'file', any path is ignored
sub is_repo_file ($self, $file, $dir_in_repo='.')
{
  # process arguments
  $file = $file->file if $file->isa('CVSLogwatcher::File');
  $file = path($file)->basename;
  $dir_in_repo = $self->get_relative($dir_in_repo);

  # the repository is empty, the file cannot be part of it
  return undef if $self->git->is_empty;

  # evaluate
  my $file_git = $dir_in_repo->child($file);
  my ($commit) = $self->git->revparse('HEAD');
  my $tree = $commit->tree;
  my $entry = $tree->entry_bypath($file_git) || return undef;
  my $object = $entry->object;
  if($object && $object->is_blob) {
    return $object;
  } else {
    return undef;
  }
}

#-------------------------------------------------------------------------------
# commit supplied file (must be CVSL::File instance) to the repository;
# target_dir must be a relative directory and is where the file is put; 'host'
# 'msg' and 'who' arguments must be provided
sub commit_file ($self, $file, $target_dir, %arg)
{
  my $cfg = CVSLogwatcher::Config->instance;
  my $logger = $cfg->logger;
  my $is_new = $self->is_repo_file($file, $target_dir);

  # supplied file must be CVSLogwatcher::File instance
  die 'Argument to commit_file must be a CVSL::File instance'
    unless $file->isa('CVSLogwatcher::File');

  # verify validity of target_dir
  $target_dir = path($target_dir);
  die "Target dir must be relative"
    unless $target_dir->is_relative;
  die "Target dir '$target_dir' not found in '" . $self->base . "'"
    unless $self->base->child($target_dir)->is_dir;

  # get filename
  my $base = $file->file->basename;
  my $target_file = $self->base->child($target_dir, $base);

  # write the target file
  my $target_in_repo = $target_dir->child($base);
  $target_file->spew($file->content->@*);

  # get commit message
  my $commit_message = sprintf(
    '%s: %s',
    $arg{host} // 'no host',
    $arg{msg} // 'no message'
  );

  # perform git commit
  my $index = $self->git->index;
  $index->add($target_in_repo->stringify);
  $index->write;
  my $tree_id = $index->write_tree;
  my $tree = $self->git->lookup($tree_id);
  my $me = Git::Raw::Signature->now($self->name, $self->email);
  my @parents = $self->git->head->target if !$self->git->is_empty;
  my $commit = $self->git->commit(
    $commit_message, $me, $me, \@parents, $tree
  );

  # run post-update hook if present, this is required so that serving the
  # repository on dumb server works
  my $post_update_hook = $self->base->child('.git', 'hooks', 'post-update');
  system($post_update_hook->stringify) if $post_update_hook->is_file;
}

#-------------------------------------------------------------------------------
# check out a file 'file' from the repository direction 'dir_in_repo'; returns
# a CVSLogwatcher::File instance; the 'file' argument only applies bare basename,
# any path is ignored
sub checkout_file($self, $file, $dir_in_repo='.')
{
  # process arguments
  $dir_in_repo = $self->get_relative($dir_in_repo);
  $file = $file->file if $file->isa('CVSLogwatcher::File');
  $file = path $file;

  # empty repository
  die 'Cannot checkout file, empty repo (git)' if $self->git->is_empty;

  # try to get git blob
  my $git_blob = $self->is_repo_file($file, $dir_in_repo);
  die "'$file' is not a git repository file" unless $git_blob;

  # perform checkout, the regex splits the content into lines without gobbling
  # up the EOL markers
  my @fc = split(/(?<=\R)/, $git_blob->content);
  return CVSLogwatcher::File->new(content => \@fc, file => $file);
}

1;
