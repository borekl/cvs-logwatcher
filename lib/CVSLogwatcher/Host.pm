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
use CVSLogwatcher::FileGroup;
use CVSLogwatcher::Misc;
use CVSLogwatcher::Stash;

# hostname
has name => ( required => 1, is => 'ro' );

# hostname with domain stripped
has host_nodomain => ( is => 'lazy' );

# admin group
has admin_group => ( is => 'lazy' );

# command-line parameters
has cmd => ( required => 1, is => 'ro' );

# user/message parsed from log or specified on the command-line
has who => ( is => 'lazy', default => sub ($s) { $s->cmd->user // ''} );
has msg => ( is => 'lazy', default => sub ($s) { $s->cmd->msg // '' } );

# target
has target => ( required => 1, is => 'ro' );

# logging tag
has tag => ( required => 1, is => 'ro' );

# additional data, this contains %+, ie. named capture groups matched via regexp
# from log entries
has data => ( is => 'ro', required => 1 );

#-----------------------------------------------------------------------------
sub _build_host_nodomain ($self) { host_strip_domain($self->name) }

#-----------------------------------------------------------------------------
# admin group associated with the host; this might result in undef if no
# matching group was found
sub _build_admin_group ($self)
{
  CVSLogwatcher::Config->instance->admin_group($self->host_nodomain)
  // $self->target->defgroup // undef;
}

#-----------------------------------------------------------------------------
# This method encapsulates retrieval of configuration from remote device; when
# successful, this returns CVSLogwatcher::FileGroup instance; NB that even
# if no files are retrieved, the return value still must FileGroup instance
sub process ($self)
{
  # shortcut variables
  my $cfg = CVSLogwatcher::Config->instance;
  my $logger = $cfg->logger;
  my $host = $self->name;
  my $target = $self->target;
  my $cmd = $self->cmd;
  my $empty = CVSLogwatcher::FileGroup->new(
    files => [], host => $self, target => $target, cmd => $cmd
  );

  # get base hostname (without domain name) and set up % tokens
  my $host_nodomain = $self->host_nodomain;
  my $repl = $cfg->repl->add_value(
    '%H' => $host_nodomain,
    '%h' => $self->name
  );

  # get logging tag
  my $tag = $self->tag;

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
  return $empty unless exists $target->config->{expect};

  # ensure reachability
  if($cfg->ping && system($repl->replace($cfg->ping)) >> 8) {
    $logger->error(qq{[$tag] Host $host_nodomain unreachable, skipping});
    return $empty;
  }

  # run expect chat sequence, either the one specified on the command line
  # or the default one defined with 'deftask' key
  my (@files) = $target->expect->run_task($self, $cmd->task);

  # add explicitly defined files
  $target->add_files(\@files);

  # warn if no files received
  if(!@files) {
    $logger->warn("[$tag] No files received, nothing to do");
    return $empty
  }

  # iterate over files received
  foreach my $file (@files) { $file->remove }

  # wrap the resulting files in a file group and finish
  return CVSLogwatcher::FileGroup->new(
    files => \@files,
    host => $self,
    target => $target,
    cmd => $cmd,
  );
}

1;
