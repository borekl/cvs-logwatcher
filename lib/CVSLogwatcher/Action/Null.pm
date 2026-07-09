#==============================================================================
# Null action
#==============================================================================

package CVSLogwatcher::Action::Null;

use v5.36;
use Moo;

has target => ( is => 'ro', required => 1 );

sub run ($self, $host, @rest) { return; }

1;
