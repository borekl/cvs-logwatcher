#===============================================================================
# Host handling code
#===============================================================================

package CVSLogwatcher::Host;

use Moo;
use warnings;
use strict;
use experimental 'signatures';

use Path::Tiny qw(path);
use Feature::Compat::Try;
use CVSLogwatcher::File;
use CVSLogwatcher::Misc;
use CVSLogwatcher::Stash;

# hostname
has name => ( required => 1, is => 'ro' );

# command-line parameters
has cmd => ( required => 1, is => 'ro' );

# user/message parsed from log or specified on the command-line
has who => ( is => 'lazy', default => sub ($s) { $s->cmd->user // ''} );
has msg => ( is => 'lazy', default => sub ($s) { $s->cmd->msg // '' } );

# target
has target => ( required => 1, is => 'ro' );

# additional data, this contains %+, ie. named capture groups matched via regexp
# from log entries
has data => ( is => 'ro', required => 1 );

#-----------------------------------------------------------------------------
# This method encapsulates all of the processing of a single host. It
# downloads a config from a host, processes it and checks it into
# a repository.
sub process ($self)
{
  # shortcut variables
  my $cfg = CVSLogwatcher::Config->instance;
  my $logger = $cfg->logger;
  my $host = $self->name;
  my $target = $self->target;
  my $cmd = $self->cmd;

  # these two are either parsed from the logfile or supplied by the user when
  # manually triggering an action
  my $who = $self->who // $cmd->user // '';
  my $msg = $self->msg // $cmd->msg // '';

  # get base hostname (without domain name) and set up % tokens
  my $host_nodomain = host_strip_domain($self->name);
  my $repl = $cfg->repl->add_value(
    '%H' => $host_nodomain,
    '%h' => $self->name
  );

  # get logging tag
  my $tag = "cvs/$host_nodomain";

  # log some basic information
  $logger->info("[$tag] Source host: $host (from syslog)");
  $logger->info("[$tag] Message:     ", $msg);
  $logger->info("[$tag] User:        ", $who) if $who;

  # skip if ignored user
  if($who && $cfg->is_ignored_user($who)) {
    $logger->info(qq{[$tag] Ignored user, skipping processing});
    return;
  }

  # skip if ignored host
  if($cfg->is_ignored_host($host_nodomain)) {
    $logger->info(qq{[$tag] Ignored host, skipping processing});
    return;
  }

  # if custom action is configured, perform it
  if($target->config->{action}) {
    $logger->debug(qq{[$tag] Invoking action callback});
    $target->config->{action}->(
      CVSLogwatcher::Stash->instance->host($self->name),
      $self->data
    );
  }

  # following code is only relevant for targets with 'expect' configuration,
  # ie. those that perform actual configuration retrieval
  return unless exists $target->config->{expect};

  # get admin group
  my $group = $cfg->admin_group($host_nodomain) // $target->defgroup;
  if($group) {
    $logger->info(qq{[$tag] Admin group: $group});
  } else {
    $logger->error(qq{[$tag] No admin group for $host_nodomain, skipping});
    return;
  }

  # ensure reachability
  if($cfg->ping && system($repl->replace($cfg->ping)) >> 8) {
    $logger->error(qq{[$tag] Host $host_nodomain unreachable, skipping});
    return;
  }

  try {

    # run expect chat sequence, either the one specified on the command line
    # or the default one defined with 'deftask' key
    my (@files) = $target->expect->run_task($host, $cmd->task);

    # add explicitly defined files
    $target->add_files(\@files);

    # if no files received, finish
    die 'No files received, nothing to do' unless @files;

    # iterate over files received
    foreach my $file (@files) {

      # check for file's existence, abort if it does not exist
      $logger->info(sprintf(
        '[%s] File %s received, %d bytes',
        $tag, $file->file->stringify, -s $file->file
      ));

      # load the file into memory and remove it from the disk
      $file->remove;

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
        $host_nodomain = $confname;
        $tag = "cvs/$confname";
        $logger->info("[$tag] Changing file name");
        $file->set_filename($confname);
      }

      # filename transform, user configurable filename transformation (currently
      # only uppercasing or lowercasing)
      $file->set_filename($target->mangle_hostname($file->file->basename));

      # compare to the last revision
      my $repo = CVSLogwatcher::File->new(
        file => $cfg->repodir->child($group, $file->file->basename . ',v'),
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

      # create a new revision
      if(!defined $cmd->nocheckin) {
        $file->rcs_check_in(
          repo => $repo->file->parent,
          host => $host_nodomain,
          msg => $msg,
          who => $who
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
  } catch($err) {
    $logger->error("[$tag] Processing failed, ", $err);
  }
}

1;
