#==============================================================================
# Some code that doesn't belong to the main classes.
#==============================================================================

package CVSLogwatcher::Misc;
require Exporter;

use v5.36;

our @ISA = qw(Exporter);
our @EXPORT = qw(
  host_strip_domain
);

#------------------------------------------------------------------------------
# Return hostname stripped of its domain name; if the supplied hostname looks
# like a decimal IP address, convert it into a form with dashes instead of dots
sub host_strip_domain ($host)
{
  my @ip = grep { /\d+/ } split(/\./, $host);
  if(@ip == 4) {
    $host = join('-', @ip);
  } else {
    $host =~ s/\..*$//gr
  }
}

1;
