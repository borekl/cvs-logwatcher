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
has inode => ( is => 'rwp' );

# array of pairs (matchid, regex)
has matchre => ( is => 'ro', required => 1 );

#-------------------------------------------------------------------------------
# Match a single log line against a regular expression specified by match id and
# return a hash reference to named capture groups that matched. The 'host' key
# is mandatory: the caller should consider the match valid only if it is
# present. Other keys are optional.
sub match ($self, $l, $matchid)
{
  # get configuration for single match entry specified by $matchid; if multiple
  # are found, it is a sign of misconfiguration
  my ($match_cfg_entry) = grep { $_->[0] eq $matchid } $self->matchre->@*;

  # if there is a match, copy named capture groups to new hash to make them
  # scoped
  my %re;
  my $regex = $match_cfg_entry->[1];
  if($regex && $l =~ /$regex/) { $re{$_} = $+{$_} foreach (keys %+) }

  # return the capture groups; if there was no match, this will be an empty hash
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

  # record inode, this is used to detect file being changed (e.g. when rotating
  # logs)
  my @stat = stat($self->file);
  $self->_set_inode($stat[1]);

  # create new FileStream instance
  my $fs = IO::Async::FileStream->new(

    read_handle => $logh,

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
        for my $match_cfg_entry ($self->matchre->@*) {

          # match line
          my $match_id = $match_cfg_entry->[0];
          my $match = $self->match($l, $match_id);
          next unless $match->{host};
          my $host = $match->{host};
          my $user = $match->{user} // undef;
          my $msg = $match->{msg} // undef;

          # find target
          my $target = $cfg->find_target($match_id, $host);

          # assign logging tag
          my $tag = "cvs/$host";

          # log match information
          $logger->info(sprintf(
            '[%s] --- Match %s@%s -> %s ---',
            $tag, $match_id, $logid, $target->id // '?'
          ));

          $logger->debug(sprintf(
            '[%s] Capture groups: %s', $tag,
            join(', ', map {sprintf('%s=%s', $_, $match->{$_}) } keys %$match)
          ));

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
            $logger->info(sprintf('[%s] | host: %s', $tag, $host ));
            $logger->info(sprintf('[%s] | user: %s', $tag, $user // '-' ));
            $logger->info(sprintf('[%s] | mesg: %s', $tag, $msg // '-' ));
            last;
          }

          # finish if no target
          if(!$target) {
            $logger->warn(
              "[cvs] No target found for match from '$host' in source '$logid/$match_id'"
            );
            last;
          }

          # finish when --onlyuser specified and not matched
          if($cmd->onlyuser && $cmd->onlyuser ne $user) {
            $logger->info("[cvs/$logid] Skipping user $user\@$host (--onlyuser)");
            last;
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
              tag => $tag,
            )
          );
        }
        last;
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

#-------------------------------------------------------------------------------
# Return true if the file seems to have changed (ie. the filename is the same,
# but refers to different inode)
sub is_rotated ($self)
{
  my @stat = stat($self->file) if $self->file->is_file;
  return $self->inode && $self->file->is_file && $self->inode != $stat[1];
}

1;
