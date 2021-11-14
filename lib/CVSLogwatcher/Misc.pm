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
  extract_hostname
);

#------------------------------------------------------------------------------
# Try to extract hostname from configuration file; caller must supply a regex
# for the matching/extraction
sub extract_hostname ($file, $regex)
{
  # read the new file
  open my $fh, $file or die "Could not open file '$file'";
  chomp( my @new_file = <$fh> );
  close $fh;

  # try to find and extract hostname
  foreach (@new_file) {
    if(/$regex/) { return $1 }
  }

  # nothing was found
  return undef;
}

1;
