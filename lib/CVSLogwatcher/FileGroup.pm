#=============================================================================
# Operations on groups of files // This module encapsulates multiple files
# and performs configured actions on them. Note, that most of the time we are
# handling single file, but it is possible to retrieve more than one.
#=============================================================================

package CVSLogwatcher::FileGroup;

use v5.36;
use Moo;

use Path::Tiny;
use CVSLogwatcher::Logger;

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
  my $logger = CVSLogwatcher::Logger->instance->prefix($self->host->tag);
  my $cmd = $self->host->cmd;
  my $target = $self->host->target;
  my $host_nodomain = $self->host->host_nodomain;

  # iterate over the files
  foreach my $file ($self->files->@*) {

    my @mangle;
    $logger->debug('Processing %s', $file->file);

    # basic info
    $logger->info(
      'File %s received, %d bytes', $file->file->stringify, $file->size
    );

    # enforce minimum file size
    if(
      $target->config->{minsize}
      && $target->config->{minsize} > $file->size)
    {
      $logger->warn('File below minimum size, aborting check in');
      next;
    }

    # convert line endings to local representation
    if($cmd->mangle && $target->has_option('normeol')) {
      my $diff;
      $logger->debug(
        '%d bytes stripped (normeol)', $diff = $file->normalize_eol
      );
      push(@mangle, sprintf("normeol=%d", $diff));
    }

    # filter out junk at the start and the end ("validrange" option)
    if(
      $cmd->mangle
      && exists $target->config->{validrange}
      && ref $target->config->{validrange}
      && $target->config->{validrange}->@*
    ) {
      my $diff = $file->validrange($target->config->{validrange}->@*);
      $logger->debug('%d bytes stripped (validrange)', $diff);
      push(@mangle, sprintf("validrange=%d", $diff));
    }

    # filter out lines anywhere in the configuration ("filter" option)
    if(
      $cmd->mangle
      && exists $target->config->{filter}
      && ref $target->config->{filter}
      && $target->config->{filter}->@*
    ) {
      my $diff = $file->filter($target->config->{filter}->@*);
      $logger->debug('%d bytes stripped (filter)', $diff);
      push(@mangle, sprintf("filter=%d", $diff));
    }

    # log mangling summary
    $logger->info('Mangle summary: %s', join(', ', @mangle)) if @mangle;

    # validate the configuration
    if($target->config->{validate}) {
      if(my @failed = $file->validate($target->config->{validate}->@*)) {
        $logger->warn('Validation required but failed, aborting check in');
        $logger->debug(
          'Failed validation expressions: %s',
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
        $logger->info('Changing file name to %s', $confname);
        $file->set_filename($confname);
      }
    }

    # convert hostname to uppercase
    if($target->has_option('uchostname')) {
      if($file->set_uc_filename) {
        $logger->info('Changing file name to %s', $file->file->basename);
      }
    }

    # --nocheckin command-line option; this inhibits the received file being
    # actually checked into any repositories; when the option is specified with
    # a path, then the resulting file is copied there; otherwise nothing is done
    # and the file abandoned
    if($self->cmd && defined $self->cmd->nocheckin) {
      if(my $save_to = $self->cmd->nocheckin ne '') {
        my $f = $file->save($self->cmd->nocheckin);
        $logger->info('Check-in inhibited, file saved to %s', $f);
      } else {
        $logger->info('Check-in inhibited, file dropped');
      }
      next;
    }

    # commit file to configured repositories
    foreach my $repo ($cfg->repos->@*) {
      my $group = $self->host->admin_group;
      $logger->info('Processing repo type %s', ref($repo));
      $logger->debug(
        "Target file is %s",
        $repo->base->child($group, $file->file->basename)
      );

      # see if the file exists in the repository already
      if($repo->is_repo_file($file, $group)) {
        $logger->debug('File exists in repository');
        my $repo_file = $repo->checkout_file($file, $group);
        if(
          $repo_file
          && $repo_file->is_changed($file, sub ($l) { $target->is_ignored($l) })
        ) {
          $logger->info('File changed, committing');
          $repo->commit_file(
            $file, $group,
            host => $host_nodomain,
            msg => $self->host->msg,
            who => $self->host->who,
          );
        } else {
          if($cmd->force) {
            $logger->info('File did not change but --force in effect');
            $repo->commit_file(
              $file, $group,
              host => $host_nodomain,
              msg => $self->host->msg,
              who => $self->host->who,
            );
          } else {
            $logger->info('File did not change');
          }
        }
      } else {
        $logger->info('File is new in repository');
        $repo->commit_file(
          $file, $group,
          host => $host_nodomain,
          msg => $self->host->msg,
          who => $self->host->who,
        );
      }
    }

  }
}

1;
