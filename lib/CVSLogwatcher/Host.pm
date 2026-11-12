#===============================================================================
# Host handling code
#===============================================================================

package CVSLogwatcher::Host;

use v5.36;
use Moo;
with 'CVSLogwatcher::Roles::Logger';

use Path::Tiny qw(path);
use CVSLogwatcher::File;
use CVSLogwatcher::FileGroup;
use CVSLogwatcher::Misc;
use CVSLogwatcher::Logger;

# hostname
has name => ( required => 1, is => 'ro' );

# hostname with domain stripped
has host_nodomain => ( is => 'lazy' );

# admin group
has admin_group => ( is => 'lazy' );

# command-line parameters
has cmd => ( required => 1, is => 'ro' );

# user/message parsed from log or specified on the command-line
has who => ( is => 'lazy', default => sub { '' } );
has msg => ( is => 'lazy', default => sub { '' } );

# target
has target => ( required => 1, is => 'ro' );

# logging tag, if left undefined no logging will be done
has tag => ( is => 'ro' );

# additional data, this contains %+, ie. named capture groups matched via regexp
# from log entries
has data => ( is => 'ro', required => 1, default => sub {{}} );

#-----------------------------------------------------------------------------
# name, who, msg and tag are taken from ::Comandline instance unless provided
# explicitly
around BUILDARGS => sub ($orig, $class, %args)
{
  if($args{cmd}) {
    $args{name} = $args{cmd}->host
      if !exists $args{name} && $args{cmd}->host;
    $args{who} = $args{cmd}->user
      if !exists $args{who} && $args{cmd}->user;
    $args{msg} = $args{cmd}->msg
      if !exists $args{msg} && $args{cmd}->msg;
    $args{tag} = ('cvs/' . $args{cmd}->host)
      if !exists $args{tag} && $args{cmd}->host;
  }

  return $class->$orig(%args);
};

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
# return a FileGroup instance
sub _fg ($self, @files)
{
  CVSLogwatcher::FileGroup->new(
    files =>  \@files,
    host =>   $self,
    target => $self->target,
    cmd =>    $self->cmd,
    logger => $self->logger,
  )
}

#-----------------------------------------------------------------------------
# This method encapsulates retrieval of configuration from remote device; when
# successful, this returns CVSLogwatcher::FileGroup instance; NB that even
# if no files are retrieved, the return value still must FileGroup instance
sub process ($self)
{
  # shortcut variables
  my $cfg = CVSLogwatcher::Config->instance;
  my $logger = $self->logger->prefix($self->tag) if $self->tag;
  my $host = $self->name;
  my $target = $self->target;
  my $cmd = $self->cmd;

  # get base hostname (without domain name) and set up % tokens
  my $host_nodomain = $self->host_nodomain;
  my $repl = $cfg->repl->add_value(
    '%H' => $host_nodomain,
    '%h' => $self->name
  );

  $logger->debug(
    'Host processing commenced, action is %s', ref($target->action)
  ) if $logger;

  # if custom action is configured, perform it
  $target->custom_action($self);

  # ensure reachability, FIXME: this should probably be part of the action
  # itself, so that we don't need to special-case it here
  unless ($target->action->isa('CVSLogwatcher::Action::Null')) {
    if($cfg->ping && system($repl->replace($cfg->ping)) >> 8) {
      $logger->error('Host $host_nodomain unreachable, skipping') if $logger;
      return $self->_fg;
    }
  }

  # run expect chat sequence, either the one specified on the command line
  # or the default one defined with 'deftask' key
  my (@files) = $target->action->run($self, $cmd->task);

  # add explicitly defined files
  $target->add_files(\@files);

  # warn if no files received
  if($logger && !@files && $target->has_retrieval) {
    $logger->warn('No files received, nothing to do');
  }

  # iterate over files received
  foreach my $file (@files) { $file->remove }

  # wrap the resulting files in a file group and finish
  return $self->_fg(@files);
}

1;
