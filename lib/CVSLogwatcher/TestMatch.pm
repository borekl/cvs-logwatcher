package CVSLogwatcher::TestMatch;

# helper class that provides core functionality for the --match and
# --match-stdin command-line options

use v5.36;
use Moo;

use CVSLogwatcher::Host;
use CVSLogwatcher::Stash;

has config => ( is => 'ro', required => 1 );
has stash => ( is => 'ro', required => 1 );

#------------------------------------------------------------------------------
# match a single line against the battery of configured regular expressions and
# return list where first value is match status and the rest is user readable
# output consisting of one line per regex
sub test_match ($self, $line, $log=undef)
{
  my $cfg = $self->config;
  my $matches = $cfg->config->{matches};
  my @output;
  my $matched = 0;

  foreach my $match_id (sort keys %$matches) {

    # skip if logfile constrain is used and the current match is not applied for
    # specified log
    my @logfiles = $cfg->logfiles_with_matchid($match_id);
    next if $log && !grep { $log eq $_->id} @logfiles;

    # perform work when there's a match
    my $regex = $matches->{$match_id};
    if($regex && $line =~ /$regex/) {
      $matched = 1;

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
        stash => $self->stash,
      );

      # invoke custom action
      if(ref $target && $target->action->can('invoke')) {
        $target->action->invoke($host);
      }

      # get capture groups info
      foreach (keys %re) { push(@info, sprintf('+%s=%s', $_, $re{$_}) ) }

      # get commit info
      my ($user, $msg) = $target->commit_info(\%re, $self->stash);
      push(@info, '%user=' . $user) if $user;
      push(@info, '%message=' . $msg) if $msg;

      # render and output string
      push(@output, sprintf("--- MATCH (%s)", join(', ', @info)));

    } else {
      push(@output, sprintf("--- NO MATCH (matchid=%s)", $match_id));
    }
  }

  return ($matched, @output);
}

1;
