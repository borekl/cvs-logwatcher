#==============================================================================
# This implements the --match command-line option functionality.
#==============================================================================

package CVSLogwatcher::TestMatch;

use v5.36;
use Moo;

use CVSLogwatcher::Config;
use CVSLogwatcher::Stash;

#------------------------------------------------------------------------------
# function implementing the --match commad-line option; if there is log id in
# the arguments, then the matching is constrained only to that log
sub test_match ($self, $match, $log=undef)
{
  my $cfg = CVSLogwatcher::Config->instance;
  my $stash = CVSLogwatcher::Stash->instance;
  my $matches = $cfg->config->{matches};

  foreach my $match_id (sort keys %$matches) {

    # skip if logfile constrain is used and the current match is not applied for
    # specified log
    my @logfiles = $cfg->logfiles_with_matchid($match_id);
    next if $log && !grep { $log eq $_->id} @logfiles;

    # perform work when there's a match
    my $regex = $matches->{$match_id};
    if($regex && $match =~ /$regex/) {
      my (%re, @info);
      push(@info, 'matchid=' . $match_id);
      push(@info, 'logs=' . join('|', map { $_->id } @logfiles));
      $re{$_} = $+{$_} foreach (keys %+);
      my $target = $cfg->find_target($match_id, $re{host});
      push(@info, 'target=' . $target->id) if ref $target;
      foreach (keys %re) { push(@info, sprintf('+%s=%s', $_, $re{$_}) ) }

      printf("--- MATCH (%s)\n", join(', ', @info));

    } else {
      printf("--- NO MATCH (matchid=%s)\n", $match_id);
    }
  }
}

1;
