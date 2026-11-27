package CVSLogwatcher::Action::Custom;

# custom action wrapper; this simply invokes user-configured coderef

use v5.36;
use Moo;
with 'CVSLogwatcher::Roles::Logger';

has target => ( is => 'ro', required => 1 );
has coderef => ( is => 'ro', required => 1 );

#-------------------------------------------------------------------------------
sub invoke($self, $host)
{
  my $logger = $self->logger->prefix($host->tag) if $host->tag;
  my $stash = $host->stash->host($host->name);
  $self->logger->debug('Invoking action callback');
  $self->coderef->($stash, $host->data);
}

1;