#==============================================================================
# This implements the --match command-line option functionality.
#==============================================================================

package CVSLogwatcher::TestMatch;

use v5.36;
use Moo;

use CVSLogwatcher::Config;
use CVSLogwatcher::Cmdline;
use CVSLogwatcher::Stash;
use CVSLogwatcher::Host;
use Data::Dumper;

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

      # basic info
      my (%re, @info);
      push(@info, 'matchid=' . $match_id);
      push(@info, 'logs=' . join('|', map { $_->id } @logfiles));

      # matched named groups
      $re{$_} = $+{$_} foreach (keys %+);

      # target
      my $target = $cfg->find_target($match_id, $re{host});
      push(@info, 'target=' . $target->id) if ref $target;

      # make a Host instance
      my $host = CVSLogwatcher::Host->new(
        target => $target,
        name => $re{host},
        msg => $re{msg} // undef,
        who => $re{user} // 'unknown',
        cmd => CVSLogwatcher::Cmdline->dummy,
        data => \%re,
        tag => undef,
      );

      # invoke custom action
      $target->action($host) if ref $target;

      # get capture groups info
      foreach (keys %re) { push(@info, sprintf('+%s=%s', $_, $re{$_}) ) }

      # get commit info
      my ($user, $msg) = $target->commit_info(\%re);
      push(@info, '%user=' . $user) if $user;
      push(@info, '%message=' . $msg) if $msg;

      # render and output string
      printf("--- MATCH (%s)\n", join(', ', @info));

    } else {
      printf("--- NO MATCH (matchid=%s)\n", $match_id);
    }
  }
}

1;
