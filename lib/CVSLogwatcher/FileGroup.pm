#=============================================================================
# Operations on groups of files // This module encapsulates multiple files
# and performs configured actions on them. Note, that most of the time we are
# handling single file, but it is possible to retrieve more than one.
#=============================================================================

package CVSLogwatcher::FileGroup;

use Moo;
use warnings;
use strict;
use experimental 'signatures', 'postderef';

# attributes
has files => ( is => 'ro', required => 1 );
has host => ( is => 'ro', required => 1 );

#-------------------------------------------------------------------------------
# return number of files associated with this instance
sub count ($self) { scalar($self->files->@*) }

#-------------------------------------------------------------------------------
# perform check in and related file mangling operations according to the
# configuration
sub process ($self)
{
  # shortcut variables
  my $cfg = CVSLogwatcher::Config->instance;
  my $logger = $cfg->logger;
  my $cmd = $self->host->cmd;
  my $tag = $self->host->tag;
  my $target = $self->host->target;
  my $host_nodomain = $self->host->host_nodomain;

  # iterate over the files
  foreach my $file ($self->files->@*) {

    # basic info
    $logger->info(sprintf(
      '[%s] File %s received, %d bytes',
      $tag, $file->file->stringify, $file->size
    ));

    # convert line endings to local representation
    if($cmd->mangle && $target->has_option('normeol')) {
      $logger->debug(sprintf(
        '[%s] %d bytes stripped (normeol)', $tag, $file->normalize_eol
      ));
    }

    # filter out junk at the start and the end ("validrange" option)
    if($cmd->mangle && defined (my $diff = $file->validrange)) {
      $logger->debug(sprintf(
        '[%s] %d bytes stripped (validrange)', $tag, $diff
      ))
    }

    # filter out lines anywhere in the configuration ("filter" option)
    if($cmd->mangle && defined (my $diff = $file->filter)) {
      $logger->debug(sprintf(
        '[%s] %d bytes stripped (filter)', $tag, $diff
      ))
    }

    # validate the configuration
    if(my @failed = $file->validate) {
      $logger->warn("[$tag] Validation required but failed, aborting check in");
      $logger->debug(
        "[$tag] Failed validation expressions: ",
        join(', ', map { "'$_'" } @failed)
      );
      next;
    }

    # extract hostname from the configuration and set the extracted hostname
    # as the new filename
    if(my $confname = $file->extract_hostname) {
      $host_nodomain =  $confname;
      $tag = "cvs/$confname";
      $logger->info("[$tag] Changing file name");
      $file->set_filename($confname);
    }

    # filename transform, user configurable filename transformation (currently
    # only uppercasing or lowercasing)
    $file->set_filename($target->mangle_hostname($file->file->basename));

    # compare to the last revision
    my $repo = CVSLogwatcher::File->new(
      file => $cfg->repodir('rcs')->child($self->host->admin_group, $file->file->basename . ',v'),
      target => $target
    );
    if(!$file->is_changed($repo)) {
      if($cmd->force) {
        $logger->info("[$tag] No change to current revision, but --force in effect");
      } else {
        $logger->info("[$tag] No change to current revision, skipping check-in");
        next;
      }
    }

    # create a new revision (RCS)
    if(!defined $cmd->nocheckin) {
      $file->rcs_check_in(
        repo => $repo->file->parent,
        host => $host_nodomain,
        msg => $self->host->msg,
        who => $self->host->who
      );
      $logger->info("[$tag] CVS check-in completed successfully");
    }

    # command-line option --nocheckin in effect, but no directory or file
    # specified
    elsif($cmd->nocheckin eq '') {
      $logger->info("[$tag] CVS check-in inhibited, file not saved");
      next;
    }

    # command-line option --nocheckin in effect and directory/file specified
    else {
      my $dst = path $cmd->nocheckin;
      $dst = $cfg->tempdir->child($dst) if $dst->is_relative;
      $dst = $dst->child($host_nodomain) if $dst->is_dir;
      $file->file($dst);
      $file->save;
      $logger->info("[$tag] CVS check-in inhibited, file goes to ", $dst);
    }

  }
}

1;
