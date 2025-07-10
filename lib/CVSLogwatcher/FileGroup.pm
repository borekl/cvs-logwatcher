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

use Path::Tiny;

# attributes
has files => ( is => 'ro', required => 1 );
has host => ( is => 'ro', required => 1 );
has target => ( is => 'ro', required => 1 );
has cmd => ( is => 'ro' );

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

    $logger->debug(sprintf('[%s] Processing %s', $tag, $file->file));

    # basic info
    $logger->info(sprintf(
      '[%s] File %s received, %d bytes',
      $tag, $file->file->stringify, $file->size
    ));

    # enforce minimum file size
    if(
      $target->config->{minsize}
      && $target->config->{minsize} > $file->size)
    {
      $logger->warn(sprintf(
        '[%s] File below minimum size, aborting check in', $tag
      ));
      next;
    }

    # convert line endings to local representation
    if($cmd->mangle && $target->has_option('normeol')) {
      $logger->debug(sprintf(
        '[%s] %d bytes stripped (normeol)', $tag, $file->normalize_eol
      ));
    }

    # filter out junk at the start and the end ("validrange" option)
    if(
      $cmd->mangle
      && $target->config->{validrange}
      && defined (my $diff = $file->validrange($target->config->{validrange}->@*))
    ) {
      $logger->debug(sprintf(
        '[%s] %d bytes stripped (validrange)', $tag, $diff
      ))
    }

    # filter out lines anywhere in the configuration ("filter" option)
    if($cmd->mangle && defined (my $diff = $file->filter($target->config->{filter}->@*))) {
      $logger->debug(sprintf(
        '[%s] %d bytes stripped (filter)', $tag, $diff
      ))
    }

    # validate the configuration
    if($target->config->{validate}) {
      if(my @failed = $file->validate($target->config->{validate}->@*)) {
        $logger->warn("[$tag] Validation required but failed, aborting check in");
        $logger->debug(
          "[$tag] Failed validation expressions: ",
          join(', ', map { "'$_'" } @failed)
        );
        next;
      }
    }

    # extract hostname from the configuration and set the extracted hostname
    # as the new filename
    if($target->config->{hostname}) {
      my $regex = $target->config->{hostname};
      $regex = [ $regex ] unless ref $regex;
      if(my $confname = $file->extract_hostname(@$regex)) {
        $host_nodomain = $confname;
        $logger->info("[$tag] Changing file name to " . $confname);
        $file->set_filename($confname);
      }
    }

    # filename transform, user configurable filename transformation (currently
    # only uppercasing or lowercasing)
    $file->set_filename($target->mangle_hostname($file->file->basename));

    # --nocheckin command-line option; this inhibits the received file being
    # actually checked into any repositories; when the option is specified with
    # a path, then the resulting file is copied there; otherwise nothing is done
    # and the file abandoned
    if($self->cmd && defined $self->cmd->nocheckin) {
      if(my $save_to = $self->cmd->nocheckin ne '') {
        my $f = $file->save($self->cmd->nocheckin);
        $logger->info("[$tag] Check-in inhibited, file saved to " . $f);
      } else {
        $logger->info("[$tag] Check-in inhibited, file dropped");
      }
      next;
    }

    # commit file to configured repositories
    foreach my $repo ($cfg->repos->@*) {
      my $group = $self->host->admin_group;
      $logger->debug("[$tag] Processing repo type " . ref($repo));
      $logger->debug(
        "[$tag] Target file is "
        . $repo->base->child($group, $file->file->basename)
      );

      # see if the file exists in the repository already
      if($repo->is_repo_file($file, $group)) {
        $logger->debug("[$tag] File exists in repository");
        my $repo_file = $repo->checkout_file($file, $group);
        if(
          $repo_file
          && $repo_file->is_changed($file, sub ($l) { $target->is_ignored($l) })
        ) {
          $logger->debug("[$tag] File changed, commiting");
          $repo->commit_file(
            $file, $group,
            host => $host_nodomain,
            msg => $self->host->msg,
            who => $self->host->who,
          );
        } else {
          if($cmd->force) {
            $logger->debug("[$tag] File did not change but --force in effect");
            $repo->commit_file(
              $file, $group,
              host => $host_nodomain,
              msg => $self->host->msg,
              who => $self->host->who,
            );
          } else {
            $logger->debug("[$tag] File did not change");
          }
        }
      } else {
        $logger->debug("[$tag] File is new in repository");
        $repo->commit_file(
          $file, $group,
          host => $host_nodomain,
          msg => $self->host->msg,
          who => $self->host->who,
        );
      }
    }

    # FIXME: Implement --nocheckin option

  }
}

1;
