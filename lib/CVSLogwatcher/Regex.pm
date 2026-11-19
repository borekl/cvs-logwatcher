package CVSLogwatcher::Regex;

# this module contains one configured regex (as configured in 'matches' section
# in main config) and encapsulates also matching logic

use Moo;
use v5.36;

has id    => ( is => 'ro', required => 1 );
has regex => ( is => 'ro', required => 1 );

#-------------------------------------------------------------------------------
# match regex against a single line of input, return hash of capture groups;
# empty hash means there was no match
sub match ($self, $l)
{
  my %capture_groups;
  my $regex = $self->regex;

  if($l =~ /$regex/) {
    $capture_groups{$_} = $+{$_} foreach (keys %+)
  }

  return %capture_groups;
}

1;
