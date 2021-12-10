#==============================================================================
# Some code that doesn't belong to the main classes.
#==============================================================================

package CVSLogwatcher::Misc;
require Exporter;

use strict;
use warnings;
use experimental 'signatures';

our @ISA = qw(Exporter);
our @EXPORT = qw(
  host_strip_domain
);

#------------------------------------------------------------------------------
# Return hostname stripped of its domain name
sub host_strip_domain ($host) { $host =~ s/\..*$//gr }

1;
