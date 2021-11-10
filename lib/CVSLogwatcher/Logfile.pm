#==============================================================================
# Logfiles configuration and handling
#==============================================================================

package CVSLogwatcher::Logfile;

use Moo;
use warnings;
use strict;
use experimental 'signatures';

has id => ( is => 'ro', required => 1 );
has file => ( is => 'ro', required => 1 );
has matchre => ( is => 'ro', required => 1 );

sub match ($self, $l)
{
  my $re = $self->matchre;
  $l =~ /$re/;
  return ($+{host}, $+{user}, $+{msg});
}

1;
