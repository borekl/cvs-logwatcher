#==============================================================================
# Global data stash
#==============================================================================

package CVSLogwatcher::Stash;

use v5.36;
use Moo;
with 'MooX::Singleton';

has _stash => ( is => 'ro', default => sub {{}} );

#-------------------------------------------------------------------------------
sub host ($self, $host)
{
  if(exists $self->_stash->{uc($host)}) {
    return $self->_stash->{uc($host)};
  } else {
    return $self->_stash->{uc($host)} = {};
  }
}

1;