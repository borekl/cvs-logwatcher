#==============================================================================
# Logfiles configuration and handling
#==============================================================================

package CVSLogwatcher::Logfile;

use Moo;
use warnings;
use strict;
use experimental 'signatures';

use IO::Async::FileStream;

has id => ( is => 'ro', required => 1 );
has file => ( is => 'ro', required => 1 );
has matchre => ( is => 'ro', required => 1 );

#-------------------------------------------------------------------------------
# Match a single log line against a regular expression specified by match id and
# return a hash reference to named capture groups that matched. The 'host' key
# is mandatory: the caller should consider the match valid only if it is
# present. Other keys are optional.
sub match ($self, $l, $matchid)
{
  my %re;
  my $regex = $self->matchre->{$matchid};

  if($l =~ /$regex/) { $re{$_} =$+{$_} foreach (keys %+) }
  return \%re;
}

#-------------------------------------------------------------------------------
# attach a logfile watcher to an IO::Async event loop (supplied in the argument)
sub watch ($self, $loop, $cmd, $callback)
{
  my $logid = $self->id;
  my $cfg = CVSLogwatcher::Config->instance;
  my $logger = $cfg->logger;

  # open logfile for reading
  open my $logh,  '<', $self->file or die "Cannot open logfile '$logid' ($!)";

  # create new FileStream instance
  my $fs = IO::Async::FileStream->new(

    read_handle => $logh,
    filename => $self->file,

    on_initial => sub {
      my ($self2) = @_;
      $self2->seek_to_last( "\n" );
    },

    on_read => sub {
      my ($self2, $buffref) = @_;
      while( $$buffref =~ s/^(.*\n)// ) {
        my $l = $1;

        # if --watchonly is active, display the line
        $logger->info("[cvs/$logid] $l") if $cmd->watchonly;

        # iterate over possible matches
        for my $match_id (keys $self->matchre->%*) {

          # match line
          my $match = $self->match($l, $match_id);
          next unless $match->{host};
          my $host = $match->{host};
          my $user = $match->{user} // undef;
          my $msg = $match->{msg} // undef;

          # find target
          my $target = $cfg->find_target($match_id, $host);

          # invoke callback for 'user' and 'msg' fields, if defined
          my $stash = CVSLogwatcher::Stash->instance->host($host);
          if($target && $target->config->{commit}) {
            if($target->config->{commit}{user}) {
              $user = $target->config->{commit}{user}->($stash, $match)
            }
            if($target->config->{commit}{msg}) {
              $msg = $target->config->{commit}{msg}->($stash, $match)
            }
          }

          # log info when watching and then finish
          if($cmd->watchonly) {
            $logger->info(sprintf('[cvs/%s] | host: %s', $logid, $host ));
            $logger->info(sprintf('[cvs/%s] | user: %s', $logid, $user // '-' ));
            $logger->info(sprintf('[cvs/%s] | mesg: %s', $logid, $msg // '-' ));
            $logger->info(sprintf(
              '[cvs/%s] | target: %s, match_id: %s', $logid, $target->id, $match_id
            )) if $target;
            next;
          }

          # finish if no target
          if(!$target) {
            $logger->warn(
              "[cvs] No target found for match from '$host' in source '$logid/$match_id'"
            );
            next;
          }

          # finish when --onlyuser specified and not matched
          if($cmd->onlyuser && $cmd->onlyuser ne $user) {
            $logger->info("[cvs/$logid] Skipping user $user\@$host (--onlyuser)");
            next;
          }

          # invoke callback with Host instance
          $callback->(
            CVSLogwatcher::Host->new(
              target => $target,
              name => $host,
              msg => $msg // undef,
              who => $user // 'unknown',
              cmd => $cmd,
              data => $match,
            )
          );
        }
      }
      return 0;
    }
  );

  # attatch to event loop
  $loop->add($fs);
  $logger->info(
    sprintf('[cvs] Started observing %s (%s)', $self->file, $logid)
  );
}

1;
